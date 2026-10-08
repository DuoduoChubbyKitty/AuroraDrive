# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
M9-v2 多模态训练脚本（图像 + 车道线 + 检测框 + 车辆状态 → steer/throttle/brake）

本脚本按 M2 / M3 **实际交付的接口**编写（2026-10-08 读取 src/model_v2.py
与 src/dataset_v2.py 源码核对，非按口头约定猜测）。

════════════════════════════════════════════════════════════════════════
一、依赖的上游接口（已与源码逐条核对）
════════════════════════════════════════════════════════════════════════

【M3 · src/dataset_v2.py · MultiTaskClipsDataset】
  构造：MultiTaskClipsDataset(clips_dir, image_size=(180,320), num_dets=20,
                              augment, view_filter, heading_unit="auto",
                              default_fps=30.0, require_active_control=False,
                              allow_empty=True, strict=False, seed=42)
  __getitem__ 返回（实测键名，全部为 torch.Tensor）：
    image              [3,H,W]      float32，RGB [0,1]
    lane_mask          [1,H,W]      float32 {0,1}，H,W = image_size
    lane_present       [1]          float32，1=该帧真有车道线标注
    det_boxes          [N,4]        float32，xyxy **归一化到 [0,1]**
    det_scores         [N]          float32
    det_classes        [N]          int64
    det_mask           [N]          float32，1=真实框 0=padding 空槽
    det_present        [1]          float32，1=该帧真有检测框标注
    vehicle_state      [10]         float32（布局见 M3 docstring）
    vehicle_state_mask [10]         float32，字段级降级掩码
    steer/throttle/brake [1]        float32
    frame_no           [1]          int64
  ★ 注意：M3 **没有** build_dataset_v2()，类名为 MultiTaskClipsDataset。
  ★ M3 自带 collate_v2()（固定 N，直接 stack）。

【M2 · src/model_v2.py · M2Model】
  构造：build_model(deploy: bool = False)   ← 只接受 deploy，无其它超参
  forward(image, lane_mask=None, dets=None, det_mask=None, state=None)
           → **tuple** (steer[B,1], throttle[B,1], brake[B,1])
    image     [B,3,180,320]  float32 [0,1]（必填，缺失直接 raise）
    lane_mask [B,1,160,160]  float32 二值（None → 车道分支输出零向量）
    dets      [B,N,12]       float32，每框 12 维：
                             [0]x [1]y [2]w [3]h  ← **中心点+宽高，归一化**
                             [4:8] label one-hot(car,pedestrian,sign,obstacle)
                             [8]conf [9]speed [10]heading [11]age
    det_mask  [B,N]          float32 1=有效
    state     [B,8]          float32：
                             [0]speed [1]accel/10 [2]heading/π [3]heading_rate/π
                             [4]curvature [5]lateral_offset [6]steer_angle [7]reserved
  ⚠️ 关键事实：M2 的 throttle/brake 输出**已经过 sigmoid（是概率，不是 logits）**。
     本脚本自动转为 logits 后再做 BCE（数值安全裁剪）。
  ⚠️ M2 **没有** aux_steer 头，也**没有** lane_logits 分割头。

════════════════════════════════════════════════════════════════════════
二、M3 → M2 的字段适配（本脚本负责，两处口径差异是真实存在的）
════════════════════════════════════════════════════════════════════════
  ① 检测框：M3 给 xyxy 归一化 4 维；M2 要 中心+宽高 + one-hot(4) + conf + 3 辅助 = 12 维。
     本脚本 pack_dets() 完成转换，speed/heading/age 三维无数据源 → 置 0
     （M2 docstring 明确"无则 0"，与运行时一致）。
  ② 车辆状态：M3 给 10 维，M2 要 8 维。映射见 map_state()：
        M2[0] speed         ← M3[0] speed_norm            ✓
        M2[1] accel/10      ← M3[7] accel_mps2 / 10       ✓
        M2[2] heading/π     ← M3[8] heading_wrapped       ✓（已是 wrap_to_pi/π）
        M2[3] heading_rate  ← 无数据源 → 0                ✗ 缺失
        M2[4] curvature     ← M3[1] curvature_x5          ✓
        M2[5] lateral_offset← 无数据源 → 0                ✗ 缺失
        M2[6] steer_angle   ← 无数据源 → 0                ✗ 缺失
        M2[7] reserved      ← 0
  ③ 车道线分辨率：M2 声明 lane_mask 为 [B,1,160,160]（Swift MaskGrid），
     M3 产出的是 image_size（180×320）的相机空间掩码。两者语义不同（前者疑似
     俯视栅格）。默认 --lane_size 160 按 M2 声明缩放，可用 --lane_keep_size
     保持 M3 原始分辨率（LaneMaskEncoder 用 AdaptiveAvgPool，任何尺寸都能跑）。
     ⚠️ 这是**尚未定论的接口问题**，两种都提供，需与 M2 确认后固定。

════════════════════════════════════════════════════════════════════════
三、"让车道线分支真正影响 steer"的机制（M2 无辅助头，故用探针）
════════════════════════════════════════════════════════════════════════
  M2 未提供 aux_steer / lane_logits，所以本脚本用**训练期探针头**补齐监督：
    · forward hook 抓取 model.lane_encoder 的输出特征 [B,64]
    · 探针头 LaneSteerProbe: 64→32→1→tanh，只吃车道特征，监督目标 = GT steer
    · 探针损失梯度必穿 lane_encoder ⇒ 强制车道特征变成"对转向有预测力"的特征
    · 探针作为子模块挂在模型上（随 checkpoint 存取），**导出前必须剥离**，
      它不参与推理，仅训练期存在
  若 M2 未来补上 aux_steer / lane_logits，本脚本会自动优先使用模型原生输出
  （见 normalize_outputs 与 _collect_lane_aux），无需改动。

  三重保障：
    保障 1  车道专属转向探针损失  lane_steer_weight × L1(probe(lane_feat), GT steer)  ★主力
    保障 2  车道几何一致性损失    lane_consistency_weight × L1(steer, 车道几何反推 steer)
    保障 3  车道分割辅助损失      lane_seg_weight（需模型有 lane_logits；当前 M2 无 → 自动跳过）
  两项诚实校验（都在日志里明说，不粉饰）：
    校验 A  梯度耦合诊断 lane_grad_norm：单独对 steer 损失反传，测 lane_encoder 参数
            梯度范数。≈0 ⇒ 车道分支对 steer 无贡献（白加）。
    校验 B  车道消融 lane_ablation_delta：验证集把 lane_mask 置零再前向，
            比较 steer L1 差异。Δ≈0 ⇒ 模型没在用车道线（白加）。

════════════════════════════════════════════════════════════════════════
四、降级运行（⚠️ 诚实前提）
════════════════════════════════════════════════════════════════════════
  实测数据现状（M3 docstring 已确认，本脚本启动时也会重新探测）：
    · data/raw_clips/ 下 5 个 clip 全是 v1_old 格式，**录制时没存车道线、没存检测框**
      → 需先跑 M3 的 backfill_lane_masks() / backfill_detections() 才有标注
    · steer/throttle/brake **129 帧全为 0**（无有效控制标签）
  因此本脚本必须能"缺标注照常跑"，且**如实留档**：
    · lane_present=0 的样本从车道辅助损失中排除（不用零掩码假装监督）
    · 整批无车道线标注 → 车道辅助损失整体禁用 + 启动告警 + 日志留档
    · 无检测框标注（det_present=0 / det_mask 全 0）→ 检测分支输入置零，
      M2 的 masked pooling 会自然输出零向量（模型仍可前向）
    · src/dataset_v2.py 缺失 → 降级用 mono_dataset 适配器（无车道线无检测框）
    · src/model_v2.py 缺失   → 降级用内置 _ReferenceModelV2（契约参考实现）

════════════════════════════════════════════════════════════════════════
五、用法
════════════════════════════════════════════════════════════════════════
  /usr/local/bin/python3.11 -m src.train_v2 --epochs 30
  /usr/local/bin/python3.11 -m src.train_v2 --epochs 30 --device cpu --no_amp
  # 合成数据自测（含车道线+检测框，可验证辅助损失与两项诊断真的生效）：
  /usr/local/bin/python3.11 -m src.train_v2 --synthetic --epochs 3
  # 模拟无标注数据，验证降级路径：
  /usr/local/bin/python3.11 -m src.train_v2 --synthetic --no_lane --no_det --epochs 2

  checkpoint 输出：checkpoints/m9_v2/  ← **新目录**，不覆盖 m9_mono / game_assist_* 等现有目录
"""

import argparse
import inspect
import json
import math
import random
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

# 项目根路径
_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT))

# 复用 train_mono 的既有好实践（只读导入，不修改原文件）：
#   build_adamw_optimizer —— BN/bias 不加 weight decay 的参数组分离
#   CosineWithWarmup      —— warmup + cosine 退火
from src.train_mono import build_adamw_optimizer, CosineWithWarmup  # noqa: E402

# 默认 checkpoint 目录：**新目录**，绝不覆盖 m9_mono / game_assist_* 等现有目录
DEFAULT_CKPT_DIR = _ROOT / "checkpoints" / "m9_v2"
V2_INTERFACE_VERSION = "v2.0"

# ---- M2 契约常量：优先从 model_v2 读取真值，读不到时用核对过的硬编码兜底 ----
try:
    from src.model_v2 import (IMG_H as M2_IMG_H, IMG_W as M2_IMG_W,
                              LANE_SIZE as M2_LANE_SIZE,
                              MAX_DETECTIONS as M2_MAX_DETS,
                              DET_FEAT_DIM as M2_DET_DIM,
                              STATE_DIM as M2_STATE_DIM)
except Exception:
    M2_IMG_H, M2_IMG_W = 180, 320
    M2_LANE_SIZE = 160
    M2_MAX_DETS = 20
    M2_DET_DIM = 12
    M2_STATE_DIM = 8

# M2 检测框 one-hot 类别数（car/pedestrian/sign/obstacle）
M2_N_CLASSES = 4


# ==================== 0. 设备选择（MPS / CUDA / CPU 自动） ====================

def resolve_device(device: str) -> str:
    """auto → 优先 mps（Apple Silicon），其次 cuda，最后 cpu。"""
    if device != "auto":
        return device
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def resolve_amp(use_amp: bool, device: str) -> bool:
    """AMP 开关裁决。

    CPU 无 AMP；MPS 上 GradScaler 会因 inf 梯度导致 optimizer.step 被静默跳过、
    权重冻结（train_mono.py 已踩过该坑），故 MPS 一律纯 fp32 —— 仍走 GPU，只是不玩半精度。
    """
    if device in ("cpu", "mps"):
        return False
    return use_amp


# ==================== 1. M3 接口：dataset_v2（软依赖 + 降级） ====================

class _MonoDatasetV2Adapter(Dataset):
    """【降级适配器】把现有 MonoClipsDataset 包装成 v2 接口。

    只有 image / vehicle_state(6维) / steer / throttle / brake，
    **没有** lane_mask 与检测框 —— 对应"数据缺标注"的诚实前提。
    显式返回 lane_present=0 / det_present=0，让下游据此跳过分支（而非塞零假装有数据）。
    """

    def __init__(self, clips_dir, image_size=(180, 320), augment=False,
                 view_filter=None, seed=42, num_dets=M2_MAX_DETS, **_):
        from src.mono_dataset import MonoClipsDataset
        # skip_zero_label=False：现有 clip 标签全为 0，若跳过会一帧不剩直接报错
        self.base = MonoClipsDataset(
            clips_dir=clips_dir, image_size=image_size, augment=augment,
            skip_zero_label=False, view_filter=view_filter, seed=seed)
        self.num_dets = num_dets
        self.image_size = tuple(image_size)
        self.has_lane = False
        self.has_det = False

    def __len__(self) -> int:
        return len(self.base)

    def __getitem__(self, idx: int) -> Dict[str, torch.Tensor]:
        s = self.base[idx]
        H, W = self.image_size
        N = self.num_dets
        return {
            "image": s["image"],
            # 全零掩码 + present=0：明确表达"没有标注"，不是"有标注但为空"
            "lane_mask": torch.zeros(1, H, W, dtype=torch.float32),
            "lane_present": torch.zeros(1, dtype=torch.float32),
            "det_boxes": torch.zeros(N, 4, dtype=torch.float32),
            "det_scores": torch.zeros(N, dtype=torch.float32),
            "det_classes": torch.zeros(N, dtype=torch.int64),
            "det_mask": torch.zeros(N, dtype=torch.float32),
            "det_present": torch.zeros(1, dtype=torch.float32),
            "vehicle_state": s["vehicle_state"],           # 旧 6 维，map_state 会兜底
            "vehicle_state_mask": torch.zeros(10, dtype=torch.float32),
            "steer": s["steer"],
            "throttle": s["throttle"],
            "brake": s["brake"],
            "frame_no": torch.tensor([idx], dtype=torch.int64),
        }


def build_v2_dataset(clips_dir, image_size, augment, view_filter, seed, num_dets,
                     force_no_lane=False, force_no_det=False):
    """构建数据集：优先 M3 的 MultiTaskClipsDataset，缺失则降级到 MonoClipsDataset 适配器。

    返回 (dataset, source_name, has_lane, has_det)
    """
    ds = None
    source = "unknown"
    try:
        import importlib
        mod = importlib.import_module("src.dataset_v2")
        # M3 实际交付的类名是 MultiTaskClipsDataset（无 build_dataset_v2 函数）
        cls = None
        for name in ("MultiTaskClipsDataset", "DatasetV2", "build_dataset_v2"):
            if hasattr(mod, name):
                cls = getattr(mod, name)
                source = f"src.dataset_v2.{name}"
                break
        if cls is None:
            print("[M3接口] ⚠ dataset_v2 模块存在但无可用的数据集类")
        else:
            kwargs = dict(clips_dir=clips_dir, image_size=image_size, augment=augment,
                          view_filter=view_filter, seed=seed, num_dets=num_dets)
            sig = inspect.signature(cls)
            if not any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                kwargs = {k: v for k, v in kwargs.items() if k in sig.parameters}
            ds = cls(**kwargs)
    except Exception as e:
        print(f"[M3接口] ⚠ dataset_v2 构建失败（{type(e).__name__}: {e}）→ 降级")
        ds = None

    if ds is None:
        ds = _MonoDatasetV2Adapter(
            clips_dir=clips_dir, image_size=image_size, augment=augment,
            view_filter=view_filter, seed=seed, num_dets=num_dets)
        source = "降级适配器 _MonoDatasetV2Adapter(MonoClipsDataset)"
        print("[M3接口] ⚠ 未使用 dataset_v2，已降级为 MonoClipsDataset 适配器")

    # 探测标注覆盖率：优先信任 M3 的统计属性，否则取首样本实测
    has_lane = bool(getattr(ds, "n_with_lane", 0) > 0)
    has_det = bool(getattr(ds, "n_with_det", 0) > 0)
    if not hasattr(ds, "n_with_lane"):
        try:
            p = ds[0]
            has_lane = float(p.get("lane_present", torch.zeros(1))[0]) > 0.5
            has_det = float(p.get("det_present", torch.zeros(1))[0]) > 0.5
        except Exception:
            has_lane = has_det = False

    if force_no_lane:
        has_lane = False
        print("[降级] --no_lane 强制关闭车道线分支")
    if force_no_det:
        has_det = False
        print("[降级] --no_det 强制关闭检测框分支")

    return ds, source, has_lane, has_det


# ==================== 2. M3 → M2 字段适配 ====================

def pack_dets(batch: Dict[str, torch.Tensor], device, enabled: bool = True
              ) -> Tuple[torch.Tensor, torch.Tensor]:
    """M3 的 xyxy 归一化框 → M2 要求的 [B,N,12] 每框特征。

    M2 每框 12 维布局（见 model_v2.DetectionEncoder docstring）：
      [0]x [1]y [2]w [3]h  ← **中心点 + 宽高**（不是 xyxy！）
      [4:8] label one-hot(car, pedestrian, sign, obstacle)
      [8] confidence
      [9] speed  [10] heading  [11] age   ← 无数据源，M2 明确"无则 0"

    enabled=False（无检测框标注）→ 返回全零 dets + 全零 det_mask，
    M2 的 masked pooling 会输出零向量，等价于"该分支无信息"。
    """
    boxes = batch.get("det_boxes")
    mask = batch.get("det_mask")
    B = batch["image"].shape[0]
    N = M2_MAX_DETS

    if not enabled or boxes is None or mask is None:
        return (torch.zeros(B, N, M2_DET_DIM, device=device),
                torch.zeros(B, N, device=device))

    boxes = boxes.to(device).float()
    mask = mask.to(device).float()
    scores = batch.get("det_scores")
    scores = scores.to(device).float() if scores is not None \
        else torch.ones(B, N, device=device)
    classes = batch.get("det_classes")
    classes = classes.to(device).long() if classes is not None \
        else torch.zeros(B, N, device=device, dtype=torch.long)

    # 槽位数对齐到 M2 的 N（M3 默认 num_dets=20 与 M2 MAX_DETECTIONS=20 一致，
    # 但两者可独立配置，这里做一次显式对齐，避免 shape 不匹配）
    n_src = boxes.shape[1]
    if n_src != N:
        boxes = _pad_or_trim(boxes, N, dim=1, pad_value=0.0)
        mask = _pad_or_trim(mask, N, dim=1, pad_value=0.0)
        scores = _pad_or_trim(scores, N, dim=1, pad_value=0.0)
        classes = _pad_or_trim(classes, N, dim=1, pad_value=0)

    x1, y1, x2, y2 = boxes.unbind(-1)
    cx = (x1 + x2) * 0.5
    cy = (y1 + y2) * 0.5
    w = (x2 - x1).clamp(min=0.0)
    h = (y2 - y1).clamp(min=0.0)
    onehot = F.one_hot(classes.clamp(0, M2_N_CLASSES - 1),
                       M2_N_CLASSES).to(boxes.dtype)              # [B,N,4]
    zeros3 = torch.zeros(B, N, 3, device=device, dtype=boxes.dtype)  # speed/heading/age

    dets = torch.cat([cx.unsqueeze(-1), cy.unsqueeze(-1),
                      w.unsqueeze(-1), h.unsqueeze(-1),
                      onehot, scores.unsqueeze(-1), zeros3], dim=-1)
    return dets, mask


def _pad_or_trim(t: torch.Tensor, n: int, dim: int = 1, pad_value=0) -> torch.Tensor:
    """沿指定维把张量补齐/截断到长度 n。"""
    cur = t.shape[dim]
    if cur == n:
        return t
    if cur > n:
        idx = [slice(None)] * t.dim()
        idx[dim] = slice(0, n)
        return t[tuple(idx)]
    pad_shape = list(t.shape)
    pad_shape[dim] = n - cur
    pad = torch.full(pad_shape, pad_value, dtype=t.dtype, device=t.device)
    return torch.cat([t, pad], dim=dim)


def map_state(batch: Dict[str, torch.Tensor], device, enabled: bool = True
              ) -> torch.Tensor:
    """M3 的 10 维 vehicle_state → M2 要求的 8 维 state。

    映射关系（✓=有数据源，✗=无数据源置 0，见模块 docstring 第二节）：
      M2[0] speed          ← M3[0] speed_norm
      M2[1] accel/10       ← M3[7] accel_mps2 / 10
      M2[2] heading/π      ← M3[8] heading_wrapped
      M2[3] heading_rate   ← ✗ 无 → 0
      M2[4] curvature      ← M3[1] curvature_x5
      M2[5] lateral_offset ← ✗ 无 → 0
      M2[6] steer_angle    ← ✗ 无 → 0
      M2[7] reserved       ← 0

    M3 只有 6 维时（降级适配器路径）→ 取前 6 维补零到 8 维（前 6 维布局与旧契约一致）。
    """
    vs = batch.get("vehicle_state")
    B = batch["image"].shape[0]
    if vs is None or not enabled:
        return torch.zeros(B, M2_STATE_DIM, device=device)
    vs = vs.to(device).float()

    if vs.shape[1] < 10:
        # 旧 6 维契约：前 6 维逐位一致，直接补零
        return _pad_or_trim(vs, M2_STATE_DIM, dim=1, pad_value=0.0)

    out = torch.zeros(B, M2_STATE_DIM, device=device, dtype=vs.dtype)
    out[:, 0] = vs[:, 0]            # speed_norm
    out[:, 1] = vs[:, 7] / 10.0     # accel_mps2 → accel/10
    out[:, 2] = vs[:, 8]            # heading_wrapped（已是 /π）
    out[:, 4] = vs[:, 1]            # curvature_x5
    # M2[3] heading_rate / M2[5] lateral_offset / M2[6] steer_angle 无数据源 → 保持 0
    return out


def build_m2_inputs(batch: Dict[str, torch.Tensor], device, enable_lane: bool,
                    enable_det: bool, lane_size: Optional[int],
                    strict_lane_geometry: bool = False) -> Dict[str, torch.Tensor]:
    """把 M3 的 batch 适配成 M2.forward 的入参。

    ★ 车道线几何口径（2026-10-08 修复）
    ----------------------------------------------------------------
    M2 的 `lane_mask` 契约是 [B,1,160,160]，语义是 **Swift MaskGrid**
    —— **letterbox 640 坐标系**下采样后的网格（依据 YolopxEngine.swift:40/374、
    InferenceEngineV2.swift:124）。dataset_v2 现在直接产出该口径，故这里
    **原样透传，不做任何 resize**。

    ⛔ 修复前：`F.interpolate(lm, size=(160,160), mode="nearest")`。
       当 lm 是 image_size 分辨率（180×320 相机空间）时，会把它强行拉伸成方形，
       **破坏纵横比、与 letterbox 口径最多错位 35 格（网格高度 21.9%）**。
       更糟：M2 的 LaneMaskEncoder 用 MaxPool2d + AdaptiveAvgPool2d，
       **任何尺寸都吃、不报错** —— 这个错误此前完全没有告警。

    现在：尺寸不符 → strict 时抛错，否则按「车道线不可用」处理（lane_mask=None）。
    **绝不静默 resize。**
    """
    image = batch["image"].to(device, non_blocking=False)
    lane_mask = None
    if enable_lane:
        lm = batch.get("lane_mask")
        if lm is not None:
            lm = lm.to(device).float()
            if lm.dim() == 3:
                lm = lm.unsqueeze(1)
            target = (lane_size, lane_size) if lane_size else None
            if target is not None and tuple(lm.shape[-2:]) != target:
                msg = (
                    f"lane_mask 尺寸 {tuple(lm.shape[-2:])} 与 M2 契约 {target} 不符。"
                    f"M2 的 lane_mask 语义是 letterbox 640 口径的 MaskGrid，"
                    f"**不是**相机空间分辨率 —— 静默 resize 会破坏与运行时的几何一致性"
                    f"（实测最多错位 35 格 / 网格高度的 21.9%）。"
                    f"请让 dataset_v2 产出 {target} 口径"
                    f"（backfill_lane_masks 已改为该口径）。")
                if strict_lane_geometry:
                    raise ValueError(msg)
                # 非严格：拒绝 resize（那正是被修复的 bug），改为丢弃该分支输入。
                # 宁可让模型知道"车道线不可用"（零向量），也不喂几何错误的特征。
                print(f"⚠️  [车道线契约] {msg}\n"
                      f"    → 本次按『车道线不可用』处理（lane_mask=None → 零向量），不 resize。")
                lane_mask = None
            else:
                lane_mask = lm

    dets, det_mask = pack_dets(batch, device, enabled=enable_det)
    state = map_state(batch, device, enabled=True)
    return {"image": image, "lane_mask": lane_mask, "dets": dets,
            "det_mask": det_mask, "state": state}


def call_model(model: nn.Module, inputs: Dict[str, torch.Tensor]) -> Any:
    """按模型 forward 的实际形参名传参，形参顺序不敏感。

    只传模型声明接受的参数，因此 M2 的 (image, lane_mask, dets, det_mask, state)
    与参考实现的同名签名都能直接工作。
    """
    params = inspect.signature(model.forward).parameters
    accepts_kwargs = any(p.kind == inspect.Parameter.VAR_KEYWORD
                         for p in params.values())
    kwargs = {k: v for k, v in inputs.items()
              if (accepts_kwargs or k in params) and v is not None}
    kwargs.setdefault("image", inputs["image"])
    return model(**kwargs)


# ==================== 3. M2 接口：model_v2（软依赖 + 参考实现） ====================

class _ReferenceModelV2(nn.Module):
    """【契约参考实现 / 降级兜底】不是生产模型，仅供 M2 不可用时跑通与自测。

    签名与 M2Model 完全一致（image/lane_mask/dets/det_mask/state → tuple 概率），
    以便本脚本两条路径走同一套适配与损失代码。
    """

    def __init__(self, deploy: bool = False, lane_size: int = M2_LANE_SIZE):
        super().__init__()
        self.lane_size = lane_size

        def blk(ci, co, s):
            return nn.Sequential(nn.Conv2d(ci, co, 3, s, 1, bias=False),
                                 nn.BatchNorm2d(co), nn.ReLU(inplace=True))

        self.image_encoder = nn.Sequential(blk(3, 16, 2), blk(16, 32, 2), blk(32, 64, 2),
                                           nn.AdaptiveAvgPool2d(1), nn.Flatten(),
                                           nn.Linear(64, 256), nn.ReLU(inplace=True))
        self.lane_encoder = nn.Sequential(blk(1, 16, 2), blk(16, 32, 2), blk(32, 64, 2),
                                          nn.AdaptiveAvgPool2d(1), nn.Flatten(),
                                          nn.Linear(64, 64), nn.ReLU(inplace=True))
        self.det_encoder = nn.Sequential(nn.Linear(M2_DET_DIM, 64), nn.ReLU(inplace=True),
                                         nn.Linear(64, 128), nn.ReLU(inplace=True))
        self.state_encoder = nn.Sequential(nn.Linear(M2_STATE_DIM, 32), nn.ReLU(inplace=True),
                                           nn.Linear(32, 64), nn.ReLU(inplace=True))
        self.fusion_head = nn.Sequential(nn.Linear(256 + 64 + 128 + 64, 128),
                                         nn.ReLU(inplace=True))
        self.steer_head = nn.Linear(128, 1)
        self.throttle_head = nn.Linear(128, 1)
        self.brake_head = nn.Linear(128, 1)

    def forward(self, image, lane_mask=None, dets=None, det_mask=None, state=None):
        B = image.shape[0]
        dev = image.device
        img_f = self.image_encoder(image)

        if lane_mask is None:
            lane_f = torch.zeros(B, 64, device=dev)
        else:
            if lane_mask.dim() == 3:
                lane_mask = lane_mask.unsqueeze(1)
            lane_f = self.lane_encoder(lane_mask)

        if dets is None:
            det_f = torch.zeros(B, 128, device=dev)
        else:
            f = self.det_encoder(dets)
            if det_mask is None:
                det_mask = torch.ones(dets.shape[:2], device=dev)
            m = det_mask.unsqueeze(-1).to(f.dtype)
            det_f = (f * m).sum(1) / m.sum(1).clamp(min=1.0)

        st_f = torch.zeros(B, 64, device=dev) if state is None else self.state_encoder(state)

        fused = self.fusion_head(torch.cat([img_f, lane_f, det_f, st_f], dim=1))
        return (torch.tanh(self.steer_head(fused)),
                torch.sigmoid(self.throttle_head(fused)),
                torch.sigmoid(self.brake_head(fused)))


def build_v2_model(lane_size: int, force_reference=False):
    """构建模型：优先 M2 的 src/model_v2.build_model()，缺失则降级到参考实现。

    返回 (model, source_name, lane_module)
    """
    if not force_reference:
        try:
            import importlib
            mod = importlib.import_module("src.model_v2")
            if not hasattr(mod, "build_model"):
                print("[M2接口] ⚠ model_v2 模块存在但无 build_model()")
            else:
                # M2 的 build_model 只接受 deploy，不要多传参数
                model = mod.build_model(deploy=False)
                print("[M2接口] ✓ 使用 src.model_v2.build_model(deploy=False)")
                return model, "src.model_v2.build_model", _find_lane_module(model)
        except Exception as e:
            print(f"[M2接口] ⚠ 未能加载 src.model_v2（{type(e).__name__}: {e}）→ 降级")

    print("[M2接口] ⚠ 降级为内置参考实现 _ReferenceModelV2（仅用于跑通，非生产模型）")
    m = _ReferenceModelV2(lane_size=lane_size)
    return m, "_ReferenceModelV2(内置参考实现)", _find_lane_module(m)


def _find_lane_module(model: nn.Module) -> Optional[nn.Module]:
    """定位车道线编码器模块（探针挂载点）。"""
    for name, mod in model.named_modules():
        if name.split(".")[-1] in ("lane_encoder", "lane_enc", "lane_branch"):
            return mod
    return None


# ==================== 4. 输出归一化（M2 返回概率 tuple） ====================

_STEER_KEYS = ("steer", "steering", "pred_steer")
_THR_KEYS = ("throttle", "throttle_logit", "pred_throttle")
_BRK_KEYS = ("brake", "brake_logit", "pred_brake")
_AUX_STEER_KEYS = ("aux_steer", "lane_steer", "steer_aux")
_LANE_LOGIT_KEYS = ("lane_logits", "lane_logit", "lane_pred")


def _pick(d: Dict[str, Any], keys) -> Optional[torch.Tensor]:
    lower = {str(k).lower(): v for k, v in d.items()}
    for k in keys:
        if k in lower:
            return lower[k]
    return None


def _prob_to_logits(t: torch.Tensor) -> torch.Tensor:
    """概率 → logits（数值安全裁剪，避免 log(0)）。"""
    p = t.clamp(1e-4, 1.0 - 1e-4)
    return torch.log(p) - torch.log1p(-p)


def normalize_outputs(out: Any, ctl_mode: str = "probs"
                      ) -> Dict[str, Optional[torch.Tensor]]:
    """把 M2 的返回格式归一化为标准 dict。

    ⚠️ M2 实测返回 tuple 且 throttle/brake 已是 sigmoid 概率，故 ctl_mode 默认 "probs"
       （即把概率转回 logits 再做 BCE）。若 M2 后续改为输出 logits，用 --ctl_mode logits。
    dict 返回值则按键名判定：含 "logit" 字样视为 logits，否则视为概率。
    """
    res = {k: None for k in ("steer", "throttle_logit", "brake_logit",
                             "aux_steer", "lane_logits")}

    if isinstance(out, dict):
        res["steer"] = _pick(out, _STEER_KEYS)
        res["throttle_logit"] = _as_logits(_pick(out, _THR_KEYS),
                                           _key_is_logit(out, _THR_KEYS))
        res["brake_logit"] = _as_logits(_pick(out, _BRK_KEYS),
                                        _key_is_logit(out, _BRK_KEYS))
        res["aux_steer"] = _pick(out, _AUX_STEER_KEYS)
        res["lane_logits"] = _pick(out, _LANE_LOGIT_KEYS)
    elif isinstance(out, (tuple, list)):
        if len(out) < 3:
            raise ValueError(f"模型返回序列长度 {len(out)} < 3，无法解析 steer/throttle/brake")
        res["steer"] = out[0]
        as_logits = (ctl_mode == "logits")
        res["throttle_logit"] = _as_logits(out[1], as_logits)
        res["brake_logit"] = _as_logits(out[2], as_logits)
        if len(out) >= 4:
            res["aux_steer"] = out[3]
        if len(out) >= 5:
            res["lane_logits"] = out[4]
    else:
        raise TypeError(f"模型返回类型不支持: {type(out)}")

    for k in ("steer", "throttle_logit", "brake_logit"):
        if res[k] is None:
            raise KeyError(f"模型输出缺少必需项 '{k}'")
        if res[k].dim() == 1:
            res[k] = res[k].unsqueeze(-1)
    if res["aux_steer"] is not None and res["aux_steer"].dim() == 1:
        res["aux_steer"] = res["aux_steer"].unsqueeze(-1)
    return res


def _key_is_logit(out: Dict[str, Any], keys) -> bool:
    for k in out.keys():
        if str(k).lower() in keys:
            return "logit" in str(k).lower()
    return False


def _as_logits(t: Optional[torch.Tensor], is_logits: bool) -> Optional[torch.Tensor]:
    if t is None or is_logits:
        return t
    return _prob_to_logits(t)


# ==================== 5. 车道线转向探针（★ 让车道分支真正影响 steer） ====================

class LaneSteerProbe(nn.Module):
    """训练期探针头：只吃车道编码器特征 → 预测 steer。

    为什么需要它：M2 的 FusionHead 是黑盒拼接，主 steer 损失虽然能经 concat 回流到
    lane_encoder，但没有任何机制**要求**车道特征本身携带转向信息 —— 车道特征完全可能
    退化成对融合无用的旁支（"白加"）。探针头用 GT steer 直接监督车道特征，
    其梯度必穿 lane_encoder，强制车道特征具备转向预测力。

    ⚠️ 仅训练期存在：导出 ONNX/CoreML 前必须剥离（它不参与推理）。
       本脚本把它作为子模块挂在模型上，以便随 checkpoint 一起存取。
    """

    def __init__(self, in_dim: int = 64, hidden: int = 32):
        super().__init__()
        self.net = nn.Sequential(nn.Linear(in_dim, hidden), nn.ReLU(inplace=True),
                                 nn.Linear(hidden, 1), nn.Tanh())

    def forward(self, lane_feat: torch.Tensor) -> torch.Tensor:
        return self.net(lane_feat)


class LaneFeatureTap:
    """forward hook：抓取车道编码器的输出特征（不改变输出，梯度照常回流）。"""

    def __init__(self, lane_module: nn.Module):
        self.feat: Optional[torch.Tensor] = None
        self._h = lane_module.register_forward_hook(self._hook)

    def _hook(self, module, inp, out):
        # out 可能是 [B,64] 或 [B,C,1,1]，统一成 [B,C]
        t = out[0] if isinstance(out, (tuple, list)) else out
        if t.dim() > 2:
            t = t.flatten(1)
        self.feat = t

    def close(self):
        self._h.remove()


# ==================== 6. 车道几何 → steer 反推（一致性损失用） ====================

def lane_geometry_steer(lane_mask: torch.Tensor, gain: float = 1.0
                        ) -> Tuple[Optional[torch.Tensor], Optional[torch.Tensor]]:
    """由车道线掩码几何反推"转向代理值"，用于车道一致性损失。

    做法（启发式，非精确几何）：
      · 底带 y∈[0.75H,H) 车道线横向质心 → 归一化横向偏移 offset ∈ [-1,1]
      · 中带 y∈[0.45H,0.60H) 质心 → 与底带求斜率（近似航向角）
      · proxy = gain × (0.7×offset + 0.3×tanh(4×slope))
    符号约定：车道中心偏右 ⇒ steer 为正（右转）。若与 M2/M3 约定相反，
    启动时用 --lane_sign_autocalib 实测相关性自动翻符号。

    返回 (proxy [B,1], valid [B] 布尔)：valid = 该样本车道线像素足够多。
    """
    if lane_mask is None:
        return None, None
    if lane_mask.dim() == 3:
        lane_mask = lane_mask.unsqueeze(1)
    H, W = lane_mask.shape[-2:]
    m = (lane_mask > 0.5).to(torch.float32)

    def band_centroid(y0f, y1f):
        y0, y1 = int(H * y0f), max(int(H * y1f), int(H * y0f) + 1)
        band = m[:, :, y0:y1, :]
        cnt = band.sum(dim=(2, 3))
        xs = torch.arange(W, device=m.device, dtype=m.dtype).view(1, 1, 1, W)
        cx = (band * xs).sum(dim=(2, 3)) / cnt.clamp(min=1.0)
        return cx, cnt

    cx_bot, cnt_bot = band_centroid(0.75, 1.0)
    cx_mid, cnt_mid = band_centroid(0.45, 0.60)

    offset = (cx_bot / max(W - 1, 1)) * 2.0 - 1.0
    slope = (cx_mid - cx_bot) / max(W - 1, 1)
    proxy = (gain * (0.7 * offset + 0.3 * torch.tanh(slope * 4.0))).clamp(-1.0, 1.0)
    valid = (cnt_bot.squeeze(1) > 8) & (cnt_mid.squeeze(1) > 4)
    return proxy, valid


def calibrate_lane_sign(dataset, n_probe: int = 200, seed: int = 42
                        ) -> Tuple[float, float]:
    """实测"车道几何 proxy"与"GT steer"的相关性，自动定符号。

    返回 (sign, corr)：
      · |corr| < 0.05 ⇒ 几何 proxy 无信息量，调用方应关闭一致性损失
      · sign = ±1，用于翻正 proxy 方向，避免符号搞反导致一致性损失反向优化
    """
    rng = random.Random(seed)
    idxs = list(range(len(dataset)))
    rng.shuffle(idxs)
    idxs = idxs[:min(n_probe, len(idxs))]

    proxies, steers = [], []
    for i in idxs:
        try:
            s = dataset[i]
        except Exception:
            continue
        lm = s.get("lane_mask")
        present = s.get("lane_present")
        if lm is None or (present is not None and float(present[0]) < 0.5):
            continue
        lm = lm if isinstance(lm, torch.Tensor) else torch.as_tensor(lm, dtype=torch.float32)
        if float(lm.sum()) <= 0:
            continue
        p, v = lane_geometry_steer(lm.unsqueeze(0))
        if v is None or not bool(v[0]):
            continue
        proxies.append(float(p[0, 0]))
        steers.append(float(s["steer"].reshape(-1)[0]))

    if len(proxies) < 20:
        return 1.0, 0.0
    a = torch.tensor(proxies)
    b = torch.tensor(steers)
    a = a - a.mean()
    b = b - b.mean()
    corr = float((a * b).sum() / (a.norm() * b.norm()).clamp(min=1e-8))
    return (1.0 if corr >= 0 else -1.0), corr


# ==================== 7. 损失：主损失 + 车道线辅助损失 ====================

class V2Loss(nn.Module):
    """M9-v2 损失。

    主损失：
      steer    —— L1 或 MSE（--steer_loss 选择）
      throttle —— BCEWithLogits（输入已从 M2 的概率转回 logits）
      brake    —— BCEWithLogits
    辅助损失（让车道线分支真正影响 steer）：
      lane_steer       —— ★主力：探针头 L1（梯度必穿 lane_encoder）
      lane_consistency —— 主 steer 与车道几何反推值的 L1（保证主头与车道几何自洽）
      lane_seg         —— 车道分割 BCE（需模型有 lane_logits；当前 M2 无 → 自动跳过）
    """

    def __init__(self, steer_weight=1.0, throttle_weight=0.5, brake_weight=0.5,
                 steer_loss="l1", lane_seg_weight=0.3, lane_steer_weight=0.5,
                 lane_consistency_weight=0.05, lane_gain=1.0,
                 conflict_weight=0.0):
        super().__init__()
        self.steer_weight = steer_weight
        self.throttle_weight = throttle_weight
        self.brake_weight = brake_weight
        self.steer_loss = steer_loss
        self.lane_seg_weight = lane_seg_weight
        self.lane_steer_weight = lane_steer_weight
        self.lane_consistency_weight = lane_consistency_weight
        self.lane_gain = lane_gain
        self.conflict_weight = conflict_weight   # 可选：throttle×brake 互斥正则

    def forward(self, preds: Dict[str, Optional[torch.Tensor]], batch: Dict[str, Any],
                enable: Dict[str, bool], lane_steer_pred: Optional[torch.Tensor] = None,
                lane_valid: Optional[torch.Tensor] = None
                ) -> Tuple[torch.Tensor, Dict[str, float], Dict[str, float]]:
        """返回 (total_loss, comps 分项标量, aux_stats 辅助统计)。

        enable 里为 False 的分支直接跳过 —— 这是"数据缺标注时降级运行"的落点。
        lane_steer_pred 来自探针头（或 M2 原生 aux_steer）；lane_valid 为逐样本有效位。
        """
        dev = preds["steer"].device
        gt_s = batch["steer"].to(dev).reshape(-1, 1)
        gt_t = batch["throttle"].to(dev).reshape(-1, 1)
        gt_b = batch["brake"].to(dev).reshape(-1, 1)

        # ---- 主损失 ----
        l_steer = (F.mse_loss(preds["steer"], gt_s) if self.steer_loss == "mse"
                   else F.l1_loss(preds["steer"], gt_s))
        l_thr = F.binary_cross_entropy_with_logits(preds["throttle_logit"], gt_t)
        l_brk = F.binary_cross_entropy_with_logits(preds["brake_logit"], gt_b)

        total = (self.steer_weight * l_steer + self.throttle_weight * l_thr
                 + self.brake_weight * l_brk)
        comps = {"steer": float(l_steer.detach()), "throttle": float(l_thr.detach()),
                 "brake": float(l_brk.detach())}
        # "control" = 仅三个控制量的加权和，**不含**任何辅助损失。
        # 用途：模型选择与跨配置比较必须用它 —— 辅助损失会抬高 total，
        # 导致"开了辅助损失反而 best_val_loss 更差"的假象，且会选错 epoch。
        comps["control"] = float(total.detach())
        stats = {"lane_supervised_frac": 0.0, "lane_consistency_valid_frac": 0.0}

        if self.conflict_weight > 0:
            # throttle/brake 同时踩 = 惩罚（M2 自带 M2Loss 有该项，这里默认关闭避免重复）
            l_cf = (torch.sigmoid(preds["throttle_logit"])
                    * torch.sigmoid(preds["brake_logit"])).mean()
            total = total + self.conflict_weight * l_cf
            comps["conflict"] = float(l_cf.detach())

        # ---- 辅助 1：车道专属转向探针（★ 主力机制） ----
        if enable.get("lane_steer") and lane_steer_pred is not None:
            # 只在真有车道线标注的样本上监督（lane_present=0 的样本不参与，
            # 避免用"无标注"当"无车道线"训练，污染车道分支语义）
            if lane_valid is not None and bool(lane_valid.any()):
                d = (lane_steer_pred.reshape(-1) - gt_s.reshape(-1)).abs()
                l_ls = d[lane_valid].mean()
                total = total + self.lane_steer_weight * l_ls
                comps["lane_steer"] = float(l_ls.detach())
                stats["lane_supervised_frac"] = float(lane_valid.float().mean())
            else:
                stats["lane_supervised_frac"] = 0.0

        # ---- 辅助 2：车道几何一致性 ----
        lane_mask = batch.get("lane_mask")
        if (enable.get("lane_consistency") and lane_mask is not None
                and self.lane_consistency_weight > 0):
            proxy, valid = lane_geometry_steer(lane_mask.to(dev), gain=self.lane_gain)
            if proxy is not None and bool(valid.any()):
                d = (preds["steer"].reshape(-1) - proxy.reshape(-1)).abs()
                l_lc = d[valid].mean()
                total = total + self.lane_consistency_weight * l_lc
                comps["lane_consistency"] = float(l_lc.detach())
                stats["lane_consistency_valid_frac"] = float(valid.float().mean())

        # ---- 辅助 3：车道分割（需模型原生 lane_logits，当前 M2 未提供） ----
        if (enable.get("lane_seg") and lane_mask is not None
                and preds.get("lane_logits") is not None):
            lm = lane_mask.to(dev)
            if lm.dim() == 3:
                lm = lm.unsqueeze(1)
            lg = preds["lane_logits"]
            if lg.shape[-2:] != lm.shape[-2:]:
                lg = F.interpolate(lg, size=lm.shape[-2:], mode="bilinear",
                                   align_corners=False)
            l_seg = F.binary_cross_entropy_with_logits(lg, lm)
            total = total + self.lane_seg_weight * l_seg
            comps["lane_seg"] = float(l_seg.detach())

        comps["total"] = float(total.detach())
        return total, comps, stats


# ==================== 8. 诊断：耦合梯度 & 车道消融 ====================

def lane_grad_norm(lane_module: Optional[nn.Module]) -> float:
    """车道编码器参数的梯度范数（须在 steer-only 反传之后调用）。"""
    if lane_module is None:
        return 0.0
    sq = 0.0
    for p in lane_module.parameters():
        if p.grad is not None:
            sq += float(p.grad.detach().pow(2).sum())
    return math.sqrt(sq)


# ============================================================================
# ★ 24 步迭代精修训练信号（CoT，2026-10-08，需求 §3）
# ============================================================================
# 逼模型"真的用 24 步"而不是偷懒只依赖第 1 步：
#   ① 逐步递减监督（§3.1）：step1=1.0/step8=0.5/step16=0.3/step24=1.0
#   ② 中间步辅助任务（§3.2）：step8=车道中心偏移 / step16=TTC / step24=控制量
#   ③ 随机深度（§3.3）：训练时随机跳过部分步，防过拟合
#
# ★ 防御性设计：IterationRefiner 尚未在 model_v2 落盘时（w7 进行中），
#   本模块全部优雅降级为 no-op（不影响现有训练）；存在时自动接入。

#: 逐步递减监督权重（§3.1）。关键点：step1 与 step24 都给 1.0，
#: 中间递减 → 强制"早期粗略、后期精细"，不让模型偷懒只依赖第 1 步。
#: 其余步用线性插值填充。
ITER_STEP_WEIGHTS: Dict[int, float] = {1: 1.0, 8: 0.5, 16: 0.3, 24: 1.0}

#: 辅助任务步位（§3.2）
ITER_AUX_STEPS: Dict[str, int] = {
    "lane_offset": 8,    # step8 预测车道中心偏移
    "ttc": 16,           # step16 预测 TTC
    "control": 24,       # step24 预测最终 steer/throttle/brake
}

#: 随机深度的步数范围（§3.3）：训练时随机只用 [min,max] 步
ITER_RANDOM_DEPTH_RANGE: Tuple[int, int] = (12, 24)


def _interp_step_weights(num_steps: int = 24) -> Dict[int, float]:
    """把 ITER_STEP_WEIGHTS 的关键点线性插值成 num_steps 步的完整权重表。

    step1 与 step24 都为 1.0（早期粗略 + 后期精细），中间递减。
    """
    if num_steps <= 0:
        return {}
    anchors = sorted(ITER_STEP_WEIGHTS.items())
    if num_steps == 1:
        return {1: anchors[-1][1]}
    weights = {}
    # 把关键点对齐到 num_steps 的比例位置
    scaled = [(max(1, round(k * num_steps / max(anchors[-1][0], 1))), v)
              for k, v in anchors]
    # 确保首尾
    scaled[0] = (1, scaled[0][1])
    scaled[-1] = (num_steps, scaled[-1][1])
    for i, (s0, v0) in enumerate(scaled[:-1]):
        s1, v1 = scaled[i + 1]
        if s1 == s0:
            weights[s0] = v0
            continue
        for s in range(s0, s1 + 1):
            t = (s - s0) / (s1 - s0)
            weights[s] = v0 + (v1 - v0) * t
    weights[num_steps] = scaled[-1][1]
    return weights


def sample_random_depth(num_steps: int = 24, rng: Optional[random.Random] = None,
                        enabled: bool = True) -> Optional[List[int]]:
    """§3.3 随机深度：随机选 [12,24] 步中的若干步参与训练。

    Returns:
        参与的步序号列表（升序）；enabled=False 或 num_steps<2 → None（用全部步）。
    """
    if not enabled or num_steps < 2:
        return None
    r = rng if rng is not None else random.Random()
    lo, hi = ITER_RANDOM_DEPTH_RANGE
    k = r.randint(max(2, min(lo, num_steps)), min(hi, num_steps))
    # 始终保留第 1 步与最后一步（早期粗略 + 最终输出）
    must = {1, num_steps}
    pool = [s for s in range(1, num_steps + 1) if s not in must]
    r.shuffle(pool)
    chosen = sorted(must | set(pool[:max(0, k - len(must))]))
    return chosen


def lane_offset_target(lane_mask: torch.Tensor
                       ) -> Tuple[Optional[torch.Tensor], Optional[torch.Tensor]]:
    """§3.2 step8 真值：车道中心横向偏移 ∈ [-1,1]（左负右正）。

    复用 lane_geometry_steer 的底带质心（该函数已计算 offset），独立提取出来。
    返回 (target [B,1], valid [B])；无车道线 → (None, None)。
    """
    if lane_mask is None:
        return None, None
    proxy, valid = lane_geometry_steer(lane_mask, gain=1.0)
    # proxy 已含 offset + slope 混合；step8 只需纯 offset → 重新取底带质心
    if lane_mask.dim() == 3:
        lm = lane_mask.unsqueeze(1)
    else:
        lm = lane_mask
    H, W = lm.shape[-2:]
    m = (lm > 0.5).to(torch.float32)
    y0, y1 = int(H * 0.75), max(int(H * 1.0), int(H * 0.75) + 1)
    band = m[:, :, y0:y1, :]
    cnt = band.sum(dim=(2, 3))
    xs = torch.arange(W, device=m.device, dtype=m.dtype).view(1, 1, 1, W)
    cx = (band * xs).sum(dim=(2, 3)) / cnt.clamp(min=1.0)
    offset = (cx / max(W - 1, 1)) * 2.0 - 1.0          # [-1,1]
    v = cnt.squeeze(1) > 8
    return offset.reshape(-1, 1), v


def ttc_target(batch: Dict[str, Any], device
               ) -> Tuple[Optional[torch.Tensor], Optional[torch.Tensor]]:
    """§3.2 step16 真值：TTC 碰撞时间（秒，越小越危险）。

    用 risk_head.estimate_ttc 估算；未标定 K 时 valid 全 False（诚实降级）。
    返回 (target [B], valid [B])；无检测框 → (None, None)。
    """
    try:
        from risk_head import estimate_ttc, TTCConfig
    except ImportError:
        return None, None
    dets = batch.get("dets")           # [B,N,12] 已适配后的格式
    det_mask = batch.get("det_mask")
    if dets is None or det_mask is None:
        return None, None
    speed = None
    vs = batch.get("vehicle_state")
    if vs is not None and vs.dim() == 2 and vs.shape[1] > 0:
        speed = vs[:, 0].to(device)
    dets = dets.to(device)
    det_mask = det_mask.to(device)
    ttc, dist, valid = estimate_ttc(dets, det_mask, speed, config=TTCConfig())
    # 取每样本最危险的（最小 TTC）
    if valid.any():
        ttc_min = ttc.where(valid, torch.full_like(ttc, float('inf'))).min(dim=1).values
        v_min = valid.any(dim=1)
        # 限幅到 [0, 10] 秒，避免 inf 污染损失
        ttc_min = ttc_min.clamp(0.0, 10.0)
        return ttc_min, v_min
    return None, None


def iterative_refinement_loss(
    intermediate: Any,
    batch: Dict[str, Any],
    device,
    enable_iter: bool = True,
    num_steps: int = 24,
    rng: Optional[random.Random] = None,
) -> Tuple[torch.Tensor, Dict[str, float]]:
    """★ 24 步迭代精修的训练信号（§3 全部三段）。

    Args:
        intermediate: model_v2 在 return_intermediate=True 时返回的逐步输出。
                      预期格式：list/tuple of dict，每个 dict 含
                      steer/throttle/brake（每步都有，§3.1 要求共享 output head）。
                      **格式不符时优雅返回 0（不破坏现有训练）**。
        batch:        数据 batch（用于真值）
        enable_iter:  False → 直接返回 0（IterationRefiner 未启用时）
        num_steps:    迭代步数（默认 24）
        rng:          随机深度用

    Returns:
        (loss, comps_dict)
    """
    zero = torch.zeros((), device=device)
    comps: Dict[str, float] = {}
    if not enable_iter or intermediate is None:
        return zero, comps

    # ---- 解析 intermediate 格式（防御性：格式不符则降级）----
    steps = None
    # 格式 A：model_v2 返回 (refined, [step1, step2, ...])
    if isinstance(intermediate, tuple) and len(intermediate) == 2 \
            and isinstance(intermediate[1], (list, tuple)):
        steps = intermediate[1]
    # 格式 B：直接是 list of dict
    elif isinstance(intermediate, (list, tuple)):
        steps = intermediate
    if not steps or len(steps) == 0:
        return zero, comps

    actual_steps = len(steps)
    weights = _interp_step_weights(num_steps=max(actual_steps, num_steps))

    # ---- §3.3 随机深度：随机选子集步参与 ----
    active = sample_random_depth(num_steps=actual_steps, rng=rng, enabled=True)
    if active is None:
        active = list(range(1, actual_steps + 1))

    # ---- §3.1 逐步递减监督：每步的 steer/throttle/brake 对真值 ----
    gt_s = batch["steer"].to(device).reshape(-1, 1)
    gt_t = batch["throttle"].to(device).reshape(-1, 1)
    gt_b = batch["brake"].to(device).reshape(-1, 1)

    total = zero
    n_supervised = 0
    for idx_0, step_out in enumerate(steps):
        s = idx_0 + 1
        if s not in active:
            continue
        w = weights.get(s, 0.3)
        # step_out 可能是 dict 或 tuple
        if isinstance(step_out, dict):
            ps = step_out.get("steer")
            pt = step_out.get("throttle_logit", step_out.get("throttle"))
            pb = step_out.get("brake_logit", step_out.get("brake"))
        elif isinstance(step_out, (tuple, list)) and len(step_out) >= 3:
            ps, pt, pb = step_out[0], step_out[1], step_out[2]
        else:
            continue
        if ps is None:
            continue
        ps = ps.to(device)
        l_s = F.l1_loss(ps.reshape(-1, 1), gt_s)
        # throttle/brake：若给的是 logit 用 BCE，给的是 prob 也用 L1（鲁棒）
        if pt is not None:
            pt = pt.to(device)
            if pt.min() < -0.5 or pt.max() > 1.5:    # 疑似 logit
                l_t = F.binary_cross_entropy_with_logits(pt.reshape(-1, 1), gt_t)
            else:
                l_t = F.l1_loss(pt.reshape(-1, 1).clamp(0, 1), gt_t)
        else:
            l_t = zero
        if pb is not None:
            pb = pb.to(device)
            if pb.min() < -0.5 or pb.max() > 1.5:
                l_b = F.binary_cross_entropy_with_logits(pb.reshape(-1, 1), gt_b)
            else:
                l_b = F.l1_loss(pb.reshape(-1, 1).clamp(0, 1), gt_b)
        else:
            l_b = zero
        total = total + w * (l_s + l_t + l_b)
        n_supervised += 1
        comps[f"step{s}_steer"] = float(l_s.detach())

    if n_supervised == 0:
        return zero, comps

    # ---- §3.2 中间步辅助任务 ----
    # step8：车道中心偏移（需要模型在 step8 输出 offset 预测；若无该字段则跳过）
    aux_step_lane = ITER_AUX_STEPS["lane_offset"]
    if aux_step_lane <= actual_steps:
        lane_mask = batch.get("lane_mask")
        if lane_mask is not None:
            tgt, valid = lane_offset_target(lane_mask.to(device))
            step_out = steps[aux_step_lane - 1]
            pred_off = (step_out.get("lane_offset") if isinstance(step_out, dict)
                        else None)
            if tgt is not None and pred_off is not None and bool(valid.any()):
                pred_off = pred_off.to(device).reshape(-1, 1)
                l_lo = F.l1_loss(pred_off[valid], tgt[valid])
                total = total + 0.3 * l_lo
                comps["step8_lane_offset"] = float(l_lo.detach())

    # step16：TTC（需要模型在 step16 输出 ttc 预测；若无该字段则跳过）
    aux_step_ttc = ITER_AUX_STEPS["ttc"]
    if aux_step_ttc <= actual_steps:
        tgt, valid = ttc_target(batch, device)
        step_out = steps[aux_step_ttc - 1]
        pred_ttc = (step_out.get("ttc") if isinstance(step_out, dict) else None)
        if tgt is not None and pred_ttc is not None and bool(valid.any()):
            pred_ttc = pred_ttc.to(device).reshape(-1)
            l_ttc = F.l1_loss(pred_ttc[valid], tgt[valid])
            total = total + 0.3 * l_ttc
            comps["step16_ttc"] = float(l_ttc.detach())

    comps["iter_n_supervised"] = float(n_supervised)
    comps["iter_active_steps"] = float(len(active))
    return total, comps


def diagnose_lane_coupling(model, lane_module, batch, device, inputs, loss_fn,
                           use_amp, ctl_mode) -> Optional[float]:
    """校验 A：单独对 steer 损失反传，测车道编码器参数梯度范数。

    ≈0 ⇒ steer 损失完全不流经车道分支 ⇒ 车道线是装饰性旁支（"白加"）。
    诊断后清空梯度，不影响正常训练；异常时返回 None（不中断训练）。
    """
    try:
        model.zero_grad(set_to_none=True)
        with torch.amp.autocast(device_type=device, enabled=use_amp):
            out = call_model(model, inputs)
            preds = normalize_outputs(out, ctl_mode)
            gt_s = batch["steer"].to(device).reshape(-1, 1)
            l_steer = (F.mse_loss(preds["steer"], gt_s) if loss_fn.steer_loss == "mse"
                       else F.l1_loss(preds["steer"], gt_s))
        l_steer.backward()
        gn = lane_grad_norm(lane_module)
        model.zero_grad(set_to_none=True)
        return gn
    except Exception as e:
        print(f"[诊断] ⚠ 车道耦合诊断失败（{type(e).__name__}: {e}）")
        try:
            model.zero_grad(set_to_none=True)
        except Exception:
            pass
        return None


# ==================== 9. 验证（含校验 B：车道消融） ====================

@torch.no_grad()
def validate_v2(model, loader, loss_fn, device, use_amp, enable, ctl_mode,
                probe=None, tap=None, lane_size=None, do_ablation=False,
                limit_batches=0) -> Dict[str, float]:
    """验证集评估。do_ablation=True 时额外做"车道线置零"前向，测 steer L1 差异。

    lane_ablation_delta = 置零后 steer L1 − 正常 steer L1
      Δ 明显 > 0 ⇒ 模型确实在用车道线；Δ ≈ 0 ⇒ 车道线白加了。
    """
    model.eval()
    acc: Dict[str, float] = {}
    n = 0
    real_l1_sum = abl_l1_sum = 0.0
    abl_n = 0

    for bi, batch in enumerate(loader):
        if limit_batches and bi >= limit_batches:
            break
        inputs = build_m2_inputs(batch, device, enable_lane=True,
                                 enable_det=bool(enable.get("det", True)),
                                 lane_size=lane_size)
        lp = batch.get("lane_present")
        lane_valid = (lp.reshape(-1).to(device) > 0.5) if lp is not None else None

        with torch.amp.autocast(device_type=device, enabled=use_amp):
            out = call_model(model, inputs)
            preds = normalize_outputs(out, ctl_mode)
            probe_pred = None
            if probe is not None and tap is not None and tap.feat is not None:
                probe_pred = probe(tap.feat.to(preds["steer"].dtype))
            _, comps, _ = loss_fn(preds, batch, enable, probe_pred, lane_valid)

        for k, v in comps.items():
            acc[k] = acc.get(k, 0.0) + v
        n += 1

        # ---- 校验 B：车道线置零消融 ----
        if do_ablation and inputs.get("lane_mask") is not None:
            gt_s = batch["steer"].to(device).reshape(-1, 1)
            zero_inputs = dict(inputs)
            zero_inputs["lane_mask"] = torch.zeros_like(inputs["lane_mask"])
            with torch.amp.autocast(device_type=device, enabled=use_amp):
                preds2 = normalize_outputs(call_model(model, zero_inputs), ctl_mode)
            real_l1_sum += float(F.l1_loss(preds["steer"], gt_s))
            abl_l1_sum += float(F.l1_loss(preds2["steer"], gt_s))
            abl_n += 1

    res = {k: v / max(n, 1) for k, v in acc.items()}
    if abl_n > 0:
        real_l1 = real_l1_sum / abl_n
        abl_l1 = abl_l1_sum / abl_n
        res["steer_l1_with_lane"] = real_l1
        res["steer_l1_lane_zeroed"] = abl_l1
        res["lane_ablation_delta"] = abl_l1 - real_l1
    model.train()
    return res


# ==================== 10. 合成数据集（自测：含车道线 + 检测框） ====================

class _SyntheticV2Dataset(Dataset):
    """合成数据：车道线掩码与 steer 强相关，用于验证辅助损失与两项诊断真的生效。

    仅用于自测与联调，不参与生产训练。

    ⚠️ 关键设计（踩过的坑）：lane_in_image=False 时车道线**只存在于 lane_mask**，
       不画进 image。若同时画进图像，图像分支自己就能读出车道几何，
       消融 lane_mask 几乎不改变结果 → 测不出车道分支的真实价值，
       自测会得出"辅助损失没用"的假结论。默认 False 才是有效测试。

    ⚠️ 车道掩码口径（2026-10-08 契约修复后）：必须产出 M2 契约的
       lane_size×lane_size（160×160）letterbox 网格，**不是** image_size。
       产 image_size 会被 build_m2_inputs 判定为几何不符而整支丢弃。
    """

    def __init__(self, size=256, image_size=(180, 320), num_dets=M2_MAX_DETS,
                 with_lane=True, with_det=True, seed=0, lane_in_image=False,
                 lane_size=M2_LANE_SIZE):
        self.size = size
        self.H, self.W = image_size
        self.num_dets = num_dets
        self.with_lane = with_lane
        self.with_det = with_det
        self.seed = seed
        self.lane_in_image = lane_in_image
        self.lane_size = lane_size

    def __len__(self):
        return self.size

    def __getitem__(self, idx):
        g = torch.Generator().manual_seed(self.seed * 100003 + idx)
        H, W = self.H, self.W
        offset = float(torch.rand(1, generator=g) * 2 - 1)
        curv = float(torch.rand(1, generator=g) * 2 - 1)
        steer = max(-1.0, min(1.0, 0.6 * offset + 0.4 * curv))

        image = torch.rand(3, H, W, generator=g) * 0.3 + 0.35
        # 车道掩码按 M2 契约口径生成（lane_size×lane_size letterbox 网格），
        # 不是 image_size —— 否则会被判几何不符而整支丢弃
        L = self.lane_size
        lane_mask = torch.zeros(1, L, L)
        if self.with_lane:
            yy = torch.arange(L).view(L, 1).float()
            xx = torch.arange(L).view(1, L).float()
            t = yy / max(L - 1, 1)
            center = L / 2 + offset * (L * 0.3) * t + curv * (L * 0.5) * (1 - t) ** 2
            half = 0.12 * L + 0.25 * L * t
            lm = ((xx - (center - half)).abs() < 1.5) | ((xx - (center + half)).abs() < 1.5)
            lane_mask[0] = lm.float()
            # 默认**不**把车道线画进图像：否则图像分支即可独立读出车道几何，
            # 消融 lane_mask 无差异，自测会误判"车道分支白加"
            if self.lane_in_image:
                image = torch.clamp(
                    image + F.interpolate(lane_mask.unsqueeze(0), size=(H, W),
                                          mode="nearest")[0] * 0.4, 0, 1)

        boxes = torch.zeros(self.num_dets, 4)
        scores = torch.zeros(self.num_dets)
        classes = torch.zeros(self.num_dets, dtype=torch.int64)
        det_mask = torch.zeros(self.num_dets)
        if self.with_det:
            k = int(torch.randint(0, 5, (1,), generator=g))
            for i in range(k):
                x1 = float(torch.rand(1, generator=g)) * 0.8
                y1 = float(torch.rand(1, generator=g)) * 0.7
                w = 0.05 + float(torch.rand(1, generator=g)) * 0.15
                h = 0.05 + float(torch.rand(1, generator=g)) * 0.15
                boxes[i] = torch.tensor([x1, y1, min(1.0, x1 + w), min(1.0, y1 + h)])
                scores[i] = 0.5 + float(torch.rand(1, generator=g)) * 0.5
                classes[i] = int(torch.randint(0, 4, (1,), generator=g))
                det_mask[i] = 1.0

        return {
            "image": image,
            "lane_mask": lane_mask,
            "lane_present": torch.tensor([1.0 if self.with_lane else 0.0]),
            "det_boxes": boxes, "det_scores": scores,
            "det_classes": classes, "det_mask": det_mask,
            "det_present": torch.tensor([1.0 if self.with_det else 0.0]),
            "vehicle_state": torch.rand(10, generator=g) * 2 - 1,
            "vehicle_state_mask": torch.ones(10),
            "steer": torch.tensor([steer]),
            "throttle": torch.tensor([max(0.0, min(1.0, 0.5 + 0.3 * steer))]),
            "brake": torch.tensor([1.0 if curv < -0.8 else 0.0]),
            "frame_no": torch.tensor([idx], dtype=torch.int64),
        }


# ==================== 11. 训练主流程 ====================

def train_v2(
    epochs: int = 30, batch_size: int = 8, grad_accum: int = 2,
    lr: float = 3e-4, weight_decay: float = 5e-4,
    image_size: Tuple[int, int] = (180, 320), val_ratio: float = 0.15,
    use_amp: bool = True, device: str = "auto",
    clips_dir: Optional[str] = None, view_filter: Optional[str] = None,
    checkpoint_dir: Optional[str] = None, num_workers: int = 0, seed: int = 42,
    patience: int = 8, save_every: int = 10, num_dets: int = M2_MAX_DETS,
    lane_size: Optional[int] = M2_LANE_SIZE, lane_keep_size: bool = False,
    steer_weight: float = 1.0, throttle_weight: float = 0.5, brake_weight: float = 0.5,
    steer_loss: str = "l1", lane_seg_weight: float = 0.3, lane_steer_weight: float = 0.5,
    lane_consistency_weight: float = 0.05, lane_consistency_gain: float = 1.0,
    conflict_weight: float = 0.0, ctl_mode: str = "probs",
    no_lane: bool = False, no_det: bool = False,
    lane_grad_diag: bool = True, lane_ablation_every: int = 1,
    lane_sign_autocalib: bool = True, synthetic: bool = False,
    synthetic_size: int = 256, synthetic_lane_in_image: bool = False,
    select_metric: str = "control",
    limit_batches: int = 0,
    resume: Optional[str] = None, force_reference_model: bool = False,
) -> Path:
    torch.manual_seed(seed)
    random.seed(seed)

    device = resolve_device(device)
    use_amp = resolve_amp(use_amp, device)
    if lane_keep_size:
        lane_size = None

    print(f"\n{'='*68}")
    print(f"[M9-v2] 训练启动 | device={device} | amp={use_amp} | epochs={epochs} "
          f"| batch={batch_size}×{grad_accum} | lr={lr}")
    print(f"{'='*68}")

    # ---------- 1. 数据 ----------
    if synthetic:
        train_ds = _SyntheticV2Dataset(size=synthetic_size, image_size=image_size,
                                       num_dets=num_dets, with_lane=not no_lane,
                                       with_det=not no_det, seed=seed,
                                       lane_in_image=synthetic_lane_in_image)
        val_ds = _SyntheticV2Dataset(size=max(32, synthetic_size // 4),
                                     image_size=image_size, num_dets=num_dets,
                                     with_lane=not no_lane, with_det=not no_det,
                                     seed=seed + 7777,
                                     lane_in_image=synthetic_lane_in_image)
        ds_source = "合成数据 _SyntheticV2Dataset（自测用）"
        has_lane, has_det = (not no_lane), (not no_det)
        print(f"[数据] 合成数据集：train={len(train_ds)} val={len(val_ds)}")
    else:
        cd = clips_dir or str(_ROOT / "data" / "raw_clips")
        train_ds, ds_source, has_lane, has_det = build_v2_dataset(
            clips_dir=cd, image_size=image_size, augment=True, view_filter=view_filter,
            seed=seed, num_dets=num_dets, force_no_lane=no_lane, force_no_det=no_det)
        val_ds = None
        try:
            import importlib
            mod = importlib.import_module("src.dataset_v2")
            if hasattr(mod, "make_train_val_split"):
                train_ds, val_ds = mod.make_train_val_split(
                    train_ds, val_ratio=val_ratio, seed=seed)
        except Exception as e:
            print(f"[数据] ⚠ dataset_v2 切分失败（{type(e).__name__}: {e}）")
        if val_ds is None:
            n_val = max(1, int(len(train_ds) * val_ratio))
            n_tr = max(1, len(train_ds) - n_val)
            train_ds, val_ds = torch.utils.data.random_split(
                train_ds, [n_tr, n_val], generator=torch.Generator().manual_seed(seed))
            print(f"[数据] ⚠ 退化为按帧随机切分 train={n_tr} val={n_val}")

        # M3 自带的覆盖率报告：如实打印有什么、缺什么
        cov = getattr(train_ds, "dataset", train_ds)
        if hasattr(cov, "coverage_report"):
            try:
                print(f"[数据] M3 覆盖率报告: {json.dumps(cov.coverage_report(), ensure_ascii=False)}")
            except Exception:
                pass

    # ---------- 2. 降级裁决（诚实前提的落点） ----------
    if not has_lane:
        print("[降级] ⚠ 数据无车道线标注 → 车道探针/几何一致性 两项辅助损失全部禁用")
        print("[降级]    （无监督的车道特征等同噪声，喂给辅助头有害，故关闭而非置零）")
        print("[降级]    提示：可先跑 dataset_v2.backfill_lane_masks() 离线补算车道线")
    if not has_det:
        print("[降级] ⚠ 数据无检测框标注 → 检测分支输入置零（模型仍可前向，该路径无信息）")
        print("[降级]    提示：可先跑 dataset_v2.backfill_detections() 离线补算检测框")

    enable = {
        "lane_steer": bool(has_lane and lane_steer_weight > 0),
        "lane_consistency": bool(has_lane and lane_consistency_weight > 0),
        "lane_seg": bool(has_lane and lane_seg_weight > 0),
        "det": bool(has_det),
        # 消融是**诊断**而非损失：只要数据有车道线标注就该测，
        # 不应随辅助损失权重开关（否则无法做"有/无辅助损失"的对照实验）
        "lane_ablation": bool(has_lane),
    }

    # 车道几何符号自动校准（避免符号搞反 → 一致性损失反向优化）
    lane_gain = lane_consistency_gain
    lane_sign_corr = 0.0
    if enable["lane_consistency"] and lane_sign_autocalib:
        sign, corr = calibrate_lane_sign(train_ds, seed=seed)
        lane_sign_corr = corr
        lane_gain = lane_consistency_gain * sign
        print(f"[车道校准] proxy↔steer 相关系数 corr={corr:+.3f} → "
              f"{'保持' if sign > 0 else '翻转'}符号（gain={lane_gain:+.2f}）")
        if abs(corr) < 0.05:
            print("[车道校准] ⚠ 相关性过弱，几何 proxy 无信息量 → 关闭车道几何一致性损失")
            enable["lane_consistency"] = False

    # ---------- 3. DataLoader ----------
    pin = (device == "cuda")   # MPS 上 pin_memory 反而增加拷贝开销
    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True,
                              num_workers=num_workers, pin_memory=pin, drop_last=False)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False,
                            num_workers=num_workers, pin_memory=pin, drop_last=False)

    # ---------- 4. 模型 + 车道探针 ----------
    model, model_source, lane_module = build_v2_model(lane_size or M2_LANE_SIZE,
                                                      force_reference=force_reference_model)
    model.to(device)
    n_param = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"[模型] 来源={model_source} | 可训练参数={n_param:,} ({n_param/1e6:.2f}M)")
    if lane_module is None:
        print("[M2接口] ⚠ 未找到车道编码器模块 → 无法挂载转向探针，车道辅助损失将失效")

    # 探针头（训练期）：挂成模型子模块，随 checkpoint 存取，导出前需剥离
    probe = None
    tap = None
    if enable["lane_steer"] and lane_module is not None:
        with torch.no_grad():
            probe = LaneSteerProbe(in_dim=64, hidden=32).to(device)
        tap = LaneFeatureTap(lane_module)
        model.add_module("lane_steer_probe", probe)   # 让 build_adamw_optimizer 覆盖其参数
        print("[车道探针] ✓ 已挂载 LaneSteerProbe 到 lane_encoder 输出（训练期专用，导出前剥离）")
        print("[M2接口]   说明：M2 当前无 aux_steer 头，探针是本脚本对'车道影响 steer'的补偿机制；"
              "若 M2 后续补上原生辅助头，本脚本会自动优先使用它")

    # ---------- 5. 优化器 / 调度器 / 损失 ----------
    optimizer = build_adamw_optimizer(model, lr=lr, weight_decay=weight_decay)
    loss_fn = V2Loss(steer_weight=steer_weight, throttle_weight=throttle_weight,
                     brake_weight=brake_weight, steer_loss=steer_loss,
                     lane_seg_weight=lane_seg_weight, lane_steer_weight=lane_steer_weight,
                     lane_consistency_weight=lane_consistency_weight,
                     lane_gain=lane_gain, conflict_weight=conflict_weight)
    scaler = torch.amp.GradScaler(device=device) if use_amp else None

    steps_per_epoch = max(1, len(train_loader) // max(grad_accum, 1))
    scheduler = CosineWithWarmup(optimizer, warmup_steps=max(1, steps_per_epoch),
                                 total_steps=epochs * steps_per_epoch,
                                 base_lr=lr, min_lr=lr * 0.01)

    # ---------- 6. 训练状态 ----------
    ckpt_dir = Path(checkpoint_dir) if checkpoint_dir else DEFAULT_CKPT_DIR
    ckpt_dir.mkdir(parents=True, exist_ok=True)     # 新目录，不动现有 checkpoint
    best_val_loss = float("inf")
    start_epoch = 0
    bad_epochs = 0
    train_history, val_history = [], []

    if resume:
        rp = Path(resume)
        if rp.exists():
            ck = torch.load(rp, map_location=device, weights_only=False)
            missing = model.load_state_dict(ck["model_state_dict"], strict=False)
            if missing.missing_keys:
                print(f"[恢复] ⚠ 缺失键 {len(missing.missing_keys)} 个（含探针则属正常）")
            if "optimizer_state_dict" in ck:
                try:
                    optimizer.load_state_dict(ck["optimizer_state_dict"])
                except Exception as e:
                    print(f"[恢复] ⚠ 优化器状态未恢复（{type(e).__name__}: {e}）")
            start_epoch = int(ck.get("epoch", -1)) + 1
            best_val_loss = float(ck.get("best_val_loss", float("inf")))
            print(f"[恢复] {rp} → start_epoch={start_epoch} best={best_val_loss:.4f}")
        else:
            print(f"[恢复] ⚠ 未找到 {rp}，从头训练")

    # ---------- 7. 训练循环 ----------
    for epoch in range(start_epoch, epochs):
        ep_t0 = time.time()
        model.train()
        optimizer.zero_grad(set_to_none=True)

        sums: Dict[str, float] = {}
        n_b = 0
        accum = 0
        grad_norm_ep: Optional[float] = None
        lane_frac_ep = 0.0

        for bi, batch in enumerate(train_loader):
            if limit_batches and bi >= limit_batches:
                break

            inputs = build_m2_inputs(batch, device, enable_lane=True,
                                     enable_det=enable["det"], lane_size=lane_size)
            lp = batch.get("lane_present")
            lane_valid = (lp.reshape(-1).to(device) > 0.5) if lp is not None else None

            # ---- 校验 A：每 epoch 首个 batch 做一次车道耦合梯度诊断 ----
            if lane_grad_diag and bi == 0 and enable["lane_steer"]:
                grad_norm_ep = diagnose_lane_coupling(
                    model, lane_module, batch, device, inputs, loss_fn, use_amp, ctl_mode)

            with torch.amp.autocast(device_type=device, enabled=use_amp):
                out = call_model(model, inputs)
                preds = normalize_outputs(out, ctl_mode)
                probe_pred = None
                if probe is not None and tap is not None and tap.feat is not None:
                    probe_pred = probe(tap.feat.to(preds["steer"].dtype))
                loss, comps, stats = loss_fn(preds, batch, enable, probe_pred, lane_valid)
                loss_scaled = loss / max(grad_accum, 1)

            if scaler is not None:
                scaler.scale(loss_scaled).backward()
            else:
                loss_scaled.backward()
            accum += 1

            if accum >= grad_accum:
                if scaler is not None:
                    scaler.unscale_(optimizer)
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                if scaler is not None:
                    scaler.step(optimizer)
                    scaler.update()
                else:
                    optimizer.step()
                optimizer.zero_grad(set_to_none=True)
                scheduler.step()
                accum = 0

            for k, v in comps.items():
                sums[k] = sums.get(k, 0.0) + v
            lane_frac_ep += stats.get("lane_supervised_frac", 0.0)
            n_b += 1

        # 尾部不完整累积
        if accum > 0:
            if scaler is not None:
                scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            if scaler is not None:
                scaler.step(optimizer)
                scaler.update()
            else:
                optimizer.step()
            optimizer.zero_grad(set_to_none=True)

        train_m = {k: v / max(n_b, 1) for k, v in sums.items()}
        train_m["epoch"] = epoch
        train_m["lane_supervised_frac"] = lane_frac_ep / max(n_b, 1)
        train_m["lane_grad_norm"] = grad_norm_ep
        train_history.append(train_m)

        # ---- 验证 ----
        do_abl = bool(enable["lane_ablation"] and lane_ablation_every > 0
                      and (epoch % lane_ablation_every == 0))
        val_m = validate_v2(model, val_loader, loss_fn, device, use_amp, enable, ctl_mode,
                            probe=probe, tap=tap, lane_size=lane_size,
                            do_ablation=do_abl, limit_batches=limit_batches)
        val_m["epoch"] = epoch
        val_history.append(val_m)
        # 模型选择指标：默认用 control（纯控制损失，不含辅助项）。
        # 若用 total，开了辅助损失的 run 会因附加项而显得更差，
        # 既选错 epoch 也让跨配置比较失真（实测：control 口径下辅助损失明显更优）。
        val_loss = val_m.get(select_metric, val_m.get("total", float("inf")))

        if device == "mps":
            torch.mps.empty_cache()   # 缓解 MPS 显存碎片

        # ---- 日志 ----
        ep_dt = time.time() - ep_t0
        extra = f" lane_steer={train_m.get('lane_steer', 0):.4f}" if enable["lane_steer"] else ""
        print(f"Epoch {epoch:3d}/{epochs} | {ep_dt:5.1f}s | "
              f"train={train_m.get('total', 0):.4f} (steer={train_m.get('steer', 0):.4f}{extra}) | "
              f"val={val_loss:.4f} (steer={val_m.get('steer', 0):.4f}) | "
              f"lr={optimizer.param_groups[0]['lr']:.2e}")

        # 诚实告警：车道线是否真的在起作用
        if grad_norm_ep is not None:
            if grad_norm_ep < 1e-6:
                print("  ⚠ [耦合告警] steer 损失对车道分支的梯度范数≈0 → "
                      "车道线分支对转向无贡献（等于白加）")
        if "lane_ablation_delta" in val_m:
            d = val_m["lane_ablation_delta"]
            print(f"  · 车道消融: steer_l1={val_m['steer_l1_with_lane']:.4f} → "
                  f"置零后={val_m['steer_l1_lane_zeroed']:.4f} (Δ={d:+.4f})")
            if abs(d) < 1e-4:
                if enable["lane_steer"] or enable["lane_consistency"]:
                    print("  ⚠ [消融告警] 置零车道线后 steer 误差几乎不变 → "
                          "模型没在用车道线信息（等于白加），请检查 M2 融合结构或加大辅助权重")
                else:
                    print("  · [消融说明] 本次未启用任何车道辅助损失 → Δ≈0 属预期，"
                          "此项可作对照基线")

        # ---- 保存 best ----
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            bad_epochs = 0
            torch.save({
                "epoch": epoch,
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "best_val_loss": best_val_loss,
                "select_metric": select_metric,
                "val_control": val_m.get("control"),
                "val_total_with_aux": val_m.get("total"),
                "image_size": list(image_size),
                "lane_size": lane_size,
                "num_dets": num_dets,
                "interface_version": V2_INTERFACE_VERSION,
                "model_source": model_source,
                "dataset_source": ds_source,
                "degradation": {"has_lane": has_lane, "has_det": has_det},
                "has_training_probe": probe is not None,
                "loss_weights": {
                    "steer": steer_weight, "throttle": throttle_weight,
                    "brake": brake_weight, "lane_seg": lane_seg_weight,
                    "lane_steer": lane_steer_weight,
                    "lane_consistency": lane_consistency_weight,
                },
            }, ckpt_dir / "best_model.pt")
            print(f"  ★ 新最佳 {select_metric}={best_val_loss:.4f} "
                  f"(control={val_m.get('control', 0):.4f}, "
                  f"total含辅助={val_m.get('total', 0):.4f}) → {ckpt_dir / 'best_model.pt'}")
        else:
            bad_epochs += 1

        # ---- 定期 checkpoint ----
        if save_every > 0 and (epoch + 1) % save_every == 0:
            torch.save({
                "epoch": epoch, "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "best_val_loss": best_val_loss, "image_size": list(image_size),
                "interface_version": V2_INTERFACE_VERSION,
            }, ckpt_dir / f"checkpoint_epoch_{epoch:03d}.pt")

        # ---- early stop ----
        if patience > 0 and bad_epochs >= patience:
            print(f"\n[早停] 连续 {bad_epochs} 个 epoch 验证集未改善 → 提前结束")
            break

    if tap is not None:
        tap.close()

    # ---------- 8. 落盘日志（含降级与诊断留档） ----------
    log = {
        "interface_version": V2_INTERFACE_VERSION,
        "model_source": model_source, "dataset_source": ds_source,
        "device": device, "use_amp": use_amp,
        "epochs": epochs, "batch_size": batch_size, "grad_accum": grad_accum,
        "lr": lr, "weight_decay": weight_decay, "image_size": list(image_size),
        "lane_size": lane_size, "num_dets": num_dets, "ctl_mode": ctl_mode,
        "select_metric": select_metric,
        "best_val_loss": best_val_loss,
        "train_history": train_history, "val_history": val_history,
        # ⚠️ 降级留档：明确记录本次训练有哪些模态缺失，避免事后误读指标
        "degradation": {
            "has_lane_annotation": has_lane,
            "has_det_annotation": has_det,
            "lane_aux_losses_enabled": enable,
            "lane_sign_corr": lane_sign_corr, "lane_gain": lane_gain,
            "training_probe_used": probe is not None,
            "note": ("数据缺车道线/检测框标注时对应分支自动跳过或置零；"
                     "车道辅助损失在无标注时全部禁用，绝不用零掩码假装监督。"
                     "lane_grad_norm / lane_ablation_delta 是判断'车道线是否真的"
                     "影响 steer'的两项证据，接近 0 即表示等于白加。"),
        },
    }
    log_path = ckpt_dir / "training_log.json"
    with open(log_path, "w", encoding="utf-8") as f:
        json.dump(log, f, indent=2, ensure_ascii=False)

    print(f"\n✓ 训练完成 | best_val_loss={best_val_loss:.4f}")
    print(f"  日志: {log_path}")
    print(f"  权重: {ckpt_dir / 'best_model.pt'}")
    if probe is not None:
        print("  ⚠ checkpoint 含训练期探针 lane_steer_probe.*，导出 ONNX/CoreML 前需剥离")
    if not has_lane:
        print("  ⚠ 本次训练未使用车道线标注（数据缺失），车道线相关结论不可解读为'已验证'")
    return ckpt_dir / "best_model.pt"


# ==================== 12. CLI 入口 ====================

def parse_args():
    p = argparse.ArgumentParser(description="M9-v2 多模态（图像+车道线+检测框+状态）训练")
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch_size", type=int, default=8)
    p.add_argument("--grad_accum", type=int, default=2)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--weight_decay", type=float, default=5e-4)
    p.add_argument("--val_ratio", type=float, default=0.15)
    p.add_argument("--patience", type=int, default=8, help="早停耐心值，0=关闭")
    p.add_argument("--save_every", type=int, default=10, help="每 N epoch 存一次，0=关闭")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--num_workers", type=int, default=0)
    p.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"])
    p.add_argument("--no_amp", action="store_true")
    p.add_argument("--clips_dir", default=None)
    p.add_argument("--view_filter", default=None)
    p.add_argument("--checkpoint_dir", default=None, help="默认 checkpoints/m9_v2/")
    p.add_argument("--resume", default=None)
    p.add_argument("--img_h", type=int, default=180)
    p.add_argument("--img_w", type=int, default=320)
    p.add_argument("--num_dets", type=int, default=M2_MAX_DETS)
    p.add_argument("--lane_size", type=int, default=M2_LANE_SIZE,
                   help="车道掩码缩放到的方形边长（M2 声明 160）；0=不缩放")
    p.add_argument("--lane_keep_size", action="store_true",
                   help="保持 M3 原始分辨率，不缩放到 lane_size")
    p.add_argument("--steer_loss", default="l1", choices=["l1", "mse"])
    p.add_argument("--steer_weight", type=float, default=1.0)
    p.add_argument("--throttle_weight", type=float, default=0.5)
    p.add_argument("--brake_weight", type=float, default=0.5)
    p.add_argument("--conflict_weight", type=float, default=0.0,
                   help="throttle×brake 互斥正则权重（M2 自带 M2Loss 有该项，默认关闭）")
    p.add_argument("--lane_seg_weight", type=float, default=0.3,
                   help="车道分割辅助损失权重（需模型有 lane_logits，当前 M2 无 → 自动跳过）")
    p.add_argument("--lane_steer_weight", type=float, default=0.5,
                   help="★车道专属 steer 探针损失权重（让车道线真正影响 steer 的主力）")
    p.add_argument("--lane_consistency_weight", type=float, default=0.05,
                   help="主 steer 与车道几何反推值的一致性损失权重，0=关闭")
    p.add_argument("--lane_consistency_gain", type=float, default=1.0)
    p.add_argument("--ctl_mode", default="probs", choices=["probs", "logits"],
                   help="模型 tuple 输出的第2/3项是概率(M2 现状)还是 logits")
    p.add_argument("--no_lane", action="store_true", help="强制关闭车道线分支（模拟无标注）")
    p.add_argument("--no_det", action="store_true", help="强制关闭检测框分支（模拟无标注）")
    p.add_argument("--no_lane_grad_diag", action="store_true")
    p.add_argument("--lane_ablation_every", type=int, default=1,
                   help="每 N epoch 做一次车道消融，0=关闭")
    p.add_argument("--no_lane_sign_autocalib", action="store_true")
    p.add_argument("--force_reference_model", action="store_true")
    p.add_argument("--synthetic", action="store_true", help="合成数据自测")
    p.add_argument("--synthetic_size", type=int, default=256)
    p.add_argument("--synthetic_lane_in_image", action="store_true",
                   help="把车道线同时画进合成图像（默认不画；画了会掩盖车道分支价值，"
                        "导致消融测不出差异）")
    p.add_argument("--select_metric", default="control",
                   choices=["control", "total", "steer"],
                   help="模型选择指标：control=纯控制损失(默认,推荐)；"
                        "total=含辅助损失(会因辅助项抬高而选错)；steer=仅转向 L1")
    p.add_argument("--limit_batches", type=int, default=0, help="每 epoch 最多跑 N 个 batch")
    return p.parse_args()


def main():
    a = parse_args()
    train_v2(
        epochs=a.epochs, batch_size=a.batch_size, grad_accum=a.grad_accum,
        lr=a.lr, weight_decay=a.weight_decay,
        image_size=(a.img_h, a.img_w), val_ratio=a.val_ratio,
        use_amp=not a.no_amp, device=a.device,
        clips_dir=a.clips_dir, view_filter=a.view_filter,
        checkpoint_dir=a.checkpoint_dir, num_workers=a.num_workers,
        seed=a.seed, patience=a.patience, save_every=a.save_every,
        num_dets=a.num_dets,
        lane_size=(a.lane_size or None), lane_keep_size=a.lane_keep_size,
        steer_weight=a.steer_weight, throttle_weight=a.throttle_weight,
        brake_weight=a.brake_weight, steer_loss=a.steer_loss,
        lane_seg_weight=a.lane_seg_weight, lane_steer_weight=a.lane_steer_weight,
        lane_consistency_weight=a.lane_consistency_weight,
        lane_consistency_gain=a.lane_consistency_gain,
        conflict_weight=a.conflict_weight, ctl_mode=a.ctl_mode,
        no_lane=a.no_lane, no_det=a.no_det,
        lane_grad_diag=not a.no_lane_grad_diag,
        lane_ablation_every=a.lane_ablation_every,
        lane_sign_autocalib=not a.no_lane_sign_autocalib,
        synthetic=a.synthetic, synthetic_size=a.synthetic_size,
        synthetic_lane_in_image=a.synthetic_lane_in_image,
        select_metric=a.select_metric,
        limit_batches=a.limit_batches, resume=a.resume,
        force_reference_model=a.force_reference_model,
    )


if __name__ == "__main__":
    main()
