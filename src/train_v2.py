# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
M9-v2 多模态训练脚本（图像 + 车道线 + 检测框 + 车辆状态 → steer/throttle/brake）

════════════════════════════════════════════════════════════════════════
一、依赖的上游接口（M2 / M3 契约，均由本脚本"软依赖"，缺失时自动降级）
════════════════════════════════════════════════════════════════════════

【M3 · src/dataset_v2.py】—— 数据集
  必须提供以下二者之一：
    (a) 函数  build_dataset_v2(**kwargs) -> torch.utils.data.Dataset
    (b) 类    DatasetV2(**kwargs)
  kwargs 由本脚本传入：clips_dir / image_size / augment / view_filter / seed
  __getitem__(idx) 返回 dict（键名固定，缺键 = 该模态缺失）：
    ┌───────────────┬──────────────────┬──────────────────────────────────────┐
    │ key           │ shape            │ 说明                                 │
    ├───────────────┼──────────────────┼──────────────────────────────────────┤
    │ image         │ [3,H,W] float32  │ 必填，RGB 已归一化 [0,1]             │
    │ vehicle_state │ [6]   float32    │ 必填，与 m9_mono 同布局              │
    │ steer         │ [1]   float32    │ 必填，[-1,1]                         │
    │ throttle      │ [1]   float32    │ 必填，[0,1]                          │
    │ brake         │ [1]   float32    │ 必填，[0,1]                          │
    │ lane_mask     │ [1,H,W] float32  │ 选填，{0,1} 二值车道线掩码           │
    │ detections    │ [N,6] float32    │ 选填，x1,y1,x2,y2,conf,cls（坐标    │
    │               │                  │ 归一化到 [0,1]；N 可变，collate 补齐）│
    │ det_valid     │ [N]   bool/float │ 选填，检测框有效位（不填则 conf>0）  │
    └───────────────┴──────────────────┴──────────────────────────────────────┘

【M2 · src/model_v2.py】—— 模型
  必须提供  build_model(**kwargs) -> torch.nn.Module
  kwargs 由本脚本传入：lane_in_channels / max_dets / state_dim / det_feat_dim
  forward 至少接受 image / vehicle_state，并按需接受 lane_mask / detections / det_valid
  （本脚本用 inspect.signature 探测形参名，按关键字传参，因此形参顺序不敏感）

  返回 dict（键名大小写不敏感，允许别名），本脚本会自动归一化：
    ┌────────────────┬──────────┬────────────────────────────────────────────┐
    │ key            │ shape    │ 说明                                       │
    ├────────────────┼──────────┼────────────────────────────────────────────┤
    │ steer          │ [B,1]    │ 必填，主 steer 预测，tanh → [-1,1]         │
    │ throttle_logit │ [B,1]    │ 必填，BCE 前 logits（无 sigmoid）          │
    │ brake_logit    │ [B,1]    │ 必填，BCE 前 logits                        │
    │ aux_steer      │ [B,1]    │ 选填★，**仅由车道线分支特征**预测的 steer  │
    │ lane_logits    │ [B,1,H,W]│ 选填，车道分割辅助头（BCE 监督）           │
    └────────────────┴──────────┴────────────────────────────────────────────┘
    ★ aux_steer 是"车道线真正影响 steer"的主力机制，强烈建议 M2 暴露该头：
      它只吃车道分支特征，其损失梯度必须穿过车道编码器，
      从而强制车道特征变成"对转向有预测力"的特征（而非装饰性旁支）。
    也允许返回 tuple/list：(steer, throttle, brake[, ...])，由 --ctl_mode 指定
    第 2/3 项是 logits 还是概率。

════════════════════════════════════════════════════════════════════════
二、"车道线分支真正影响 steer"的三重保障 + 两项诚实校验
════════════════════════════════════════════════════════════════════════
  保障 1  车道分割辅助损失   lane_seg_weight   × BCE(lane_logits, lane_mask)
  保障 2  车道专属转向辅助损失 lane_steer_weight × L1(aux_steer, steer)   ← 主力
  保障 3  车道几何一致性损失  lane_consistency_weight × L1(steer, 车道几何反推 steer)
  校验 A  梯度耦合诊断：单独对 steer 损失反传，测车道分支参数梯度范数
          （lane_grad_norm ≈ 0 ⇒ 车道分支对 steer 无贡献，日志会明确告警）
  校验 B  车道消融实验：验证集上把 lane_mask 置零再前向，
          比较 steer L1 差异 lane_ablation_delta
          （Δ ≈ 0 ⇒ 模型根本没在用车道线，加了等于白加，日志会明确告警）

════════════════════════════════════════════════════════════════════════
三、降级运行（⚠️ 诚实前提）
════════════════════════════════════════════════════════════════════════
  现状：data/raw_clips/*/controls.csv 只有 steer/throttle/brake，
        仓库内**没有**车道线掩码与检测框标注文件。
  因此本脚本必须能"缺字段时照常跑"：
    · 样本缺 lane_mask 或该 batch 掩码全零 → 车道分割/一致性损失跳过，
      车道专属转向辅助损失也一并禁用（无监督的车道特征 = 噪声，喂给辅助头有害）
    · 样本缺 detections        → 检测分支输入置零（det_valid 全 False）
    · 缺失情况逐 epoch 统计并在 training_log.json 的 degradation 段留档，
      同时启动时打印醒目告警。绝不静默假装有数据。
    · 若 src/dataset_v2.py 不存在 → 自动降级用 MonoClipsDataset 适配器
      （只有 image/state/标签，无车道线无检测框）
    · 若 src/model_v2.py 不存在 → 自动降级用内置 _ReferenceModelV2
      （契约参考实现，仅用于跑通/自测，不是生产模型）

════════════════════════════════════════════════════════════════════════
四、用法
════════════════════════════════════════════════════════════════════════
  /usr/local/bin/python3.11 -m src.train_v2 --epochs 30
  /usr/local/bin/python3.11 -m src.train_v2 --epochs 30 --device cpu --no_amp
  # 用合成数据自测（含车道线+检测框，可验证辅助损失与耦合诊断真的生效）：
  /usr/local/bin/python3.11 -m src.train_v2 --synthetic --epochs 3
  # 强制降级（模拟无标注数据）：
  /usr/local/bin/python3.11 -m src.train_v2 --no_lane --no_det

  checkpoint 输出：checkpoints/m9_v2/  ← 新目录，不覆盖 checkpoints/m9_mono/ 等现有目录
"""

import argparse
import inspect
import json
import math
import os
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

# 接口契约版本，写入 checkpoint 便于运行时判断兼容性
V2_INTERFACE_VERSION = "v2.0"

# 默认检测框数量上限（detections 变长时 collate 补齐到该值）
DEFAULT_MAX_DETS = 20


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
    if device == "cpu":
        return False
    if device == "mps":
        return False
    return use_amp


# ==================== 1. M3 接口：dataset_v2（软依赖 + 降级） ====================

def _load_dataset_v2_module():
    """尝试导入 M3 的 src/dataset_v2.py；不存在返回 None（走降级适配器）。"""
    try:
        import importlib
        mod = importlib.import_module("src.dataset_v2")
        return mod
    except Exception as e:  # ImportError / 模块内异常
        print(f"[M3接口] ⚠ 未能加载 src.dataset_v2（{type(e).__name__}: {e}）")
        return None


class _MonoDatasetV2Adapter(Dataset):
    """【降级适配器】把现有 MonoClipsDataset 包装成 v2 接口。

    只有 image / vehicle_state / steer / throttle / brake，
    **没有** lane_mask 与 detections —— 对应"数据缺车道线/检测框标注"的诚实前提。
    此时车道线与检测框分支自动跳过（本类显式返回 None，由 collate 与损失层识别）。
    """

    def __init__(self, clips_dir, image_size=(180, 320), augment=False,
                 view_filter=None, seed=42, max_dets=DEFAULT_MAX_DETS):
        from src.mono_dataset import MonoClipsDataset
        # skip_zero_label=False：现有 clip 标签全为 0，若跳过会一帧不剩直接报错
        self.base = MonoClipsDataset(
            clips_dir=clips_dir, image_size=image_size, augment=augment,
            skip_zero_label=False, view_filter=view_filter, seed=seed)
        self.max_dets = max_dets
        self.has_lane = False   # 本适配器无车道线标注
        self.has_det = False    # 本适配器无检测框标注

    def __len__(self) -> int:
        return len(self.base)

    def __getitem__(self, idx: int) -> Dict[str, Any]:
        s = self.base[idx]
        return {
            "image": s["image"],
            "vehicle_state": s["vehicle_state"],
            "steer": s["steer"],
            "throttle": s["throttle"],
            "brake": s["brake"],
            # 显式 None：表示该模态缺失，下游据此跳过分支（而非塞零假装有数据）
            "lane_mask": None,
            "detections": None,
            "det_valid": None,
        }


def build_v2_dataset(clips_dir, image_size, augment, view_filter, seed,
                     max_dets, force_no_lane=False, force_no_det=False):
    """构建数据集：优先 M3 的 dataset_v2，缺失则降级到 MonoClipsDataset 适配器。

    返回 (dataset, source_name, has_lane, has_det)
    """
    mod = _load_dataset_v2_module()
    ds = None
    source = "unknown"

    if mod is not None:
        kwargs = dict(clips_dir=clips_dir, image_size=image_size, augment=augment,
                      view_filter=view_filter, seed=seed, max_dets=max_dets)
        try:
            if hasattr(mod, "build_dataset_v2"):
                ds = mod.build_dataset_v2(**kwargs)
                source = "src.dataset_v2.build_dataset_v2"
            elif hasattr(mod, "DatasetV2"):
                # 只传构造函数真正接受的参数，避免 TypeError
                sig = inspect.signature(mod.DatasetV2.__init__)
                ds = mod.DatasetV2(**{k: v for k, v in kwargs.items()
                                      if k in sig.parameters})
                source = "src.dataset_v2.DatasetV2"
            else:
                print("[M3接口] ⚠ dataset_v2 模块存在但既无 build_dataset_v2 也无 DatasetV2")
        except Exception as e:
            print(f"[M3接口] ⚠ dataset_v2 构建失败（{type(e).__name__}: {e}）→ 降级")
            ds = None

    if ds is None:
        ds = _MonoDatasetV2Adapter(
            clips_dir=clips_dir, image_size=image_size, augment=augment,
            view_filter=view_filter, seed=seed, max_dets=max_dets)
        source = "降级适配器 _MonoDatasetV2Adapter(MonoClipsDataset)"
        print("[M3接口] ⚠ 未使用 dataset_v2，已降级为 MonoClipsDataset 适配器")

    # 探测数据集是否真的带车道线/检测框标注（优先信任显式属性，否则取首样本实测）
    has_lane = bool(getattr(ds, "has_lane", True))
    has_det = bool(getattr(ds, "has_det", True))
    if not hasattr(ds, "has_lane") or not hasattr(ds, "has_det"):
        try:
            probe = ds[0]
            has_lane = probe.get("lane_mask") is not None
            has_det = probe.get("detections") is not None
        except Exception:
            has_lane = has_det = False

    if force_no_lane:
        has_lane = False
        print("[降级] --no_lane 强制关闭车道线分支")
    if force_no_det:
        has_det = False
        print("[降级] --no_det 强制关闭检测框分支")

    return ds, source, has_lane, has_det


# ==================== 2. collate：变长检测框补齐 + 缺键容错 ====================

def collate_v2(batch: List[Dict[str, Any]], max_dets: int = DEFAULT_MAX_DETS) -> Dict[str, Any]:
    """自定义 collate。

    处理两件默认 collate 搞不定的事：
      1. detections 变长 [N_i,6] → 补齐到 max(N_i, max_dets)，并生成 det_valid 有效位
      2. 样本间键不一致（部分样本有车道线、部分没有）→ 只保留全体样本共有的键，
         缺失键整批视为缺失，交由损失层跳过该分支（降级路径）
    """
    out: Dict[str, Any] = {}
    if not batch:
        return out

    # 全体样本都非 None 的键才保留
    keys = [k for k in batch[0].keys()
            if all(s.get(k) is not None for s in batch)]

    for k in keys:
        if k == "detections":
            continue  # 单独处理
        vals = [s[k] for s in batch]
        if isinstance(vals[0], torch.Tensor):
            try:
                out[k] = torch.stack(vals)
            except RuntimeError:
                # 形状不一致（例如车道线掩码分辨率不同）→ 跳过该键，视为缺失
                print(f"[collate] ⚠ 键 {k} 形状不一致，整批跳过该模态")
        else:
            out[k] = vals

    # ---- detections 补齐 ----
    if "detections" in keys:
        dets = [s["detections"] for s in batch]
        dets = [d if isinstance(d, torch.Tensor) else torch.as_tensor(d, dtype=torch.float32)
                for d in dets]
        # 统一到 [N,6]
        dets = [d.reshape(-1, 6) if d.numel() > 0 else d.new_zeros((0, 6)) for d in dets]
        n_max = max(max_dets, max(d.shape[0] for d in dets))
        padded = dets[0].new_zeros((len(dets), n_max, 6))
        valid = torch.zeros((len(dets), n_max), dtype=torch.bool)
        for i, d in enumerate(dets):
            n = d.shape[0]
            if n:
                padded[i, :n] = d
                # 有效位：优先用样本自带 det_valid，否则按 conf>0 判定
                v = batch[i].get("det_valid")
                if v is not None:
                    v = torch.as_tensor(v).reshape(-1).bool()[:n]
                    valid[i, :n] = v
                else:
                    valid[i, :n] = d[:, 4] > 0
        out["detections"] = padded
        out["det_valid"] = valid

    return out


# ==================== 3. M2 接口：model_v2（软依赖 + 参考实现） ====================

class _ReferenceModelV2(nn.Module):
    """【契约参考实现 / 降级兜底】不是生产模型，仅供 M2 交付前跑通与自测。

    结构：轻量 CNN 主干 + 车道线编码分支 + 检测框编码分支 + 状态 MLP → 融合头
      · 主干      Conv(3→16,s2) → Conv(16→32,s2) → Conv(32→64,s2)
      · 车道分支  Conv(1→16,s2) → Conv(16→32,s2) → Conv(32→64,s2) → GAP → lane_vec[64]
      · 检测分支  [B,N,6] 逐框 MLP + 掩码均值池化 → det_vec[32]
      · 状态分支  Linear(6→32)
      · 融合头    cat(64+32+32) → Linear(128→64) → ReLU → steer/throttle/brake
      · 辅助头    aux_steer：**只吃 lane_vec** → steer（车道线影响 steer 的主力机制）
      · 辅助头    lane_logits：Conv(64→1) 上采样回原图（车道分割辅助监督）
    """

    def __init__(self, lane_in_channels: int = 1, max_dets: int = DEFAULT_MAX_DETS,
                 state_dim: int = 6, det_feat_dim: int = 32):
        super().__init__()
        self.max_dets = max_dets

        def blk(ci, co, s):
            return nn.Sequential(nn.Conv2d(ci, co, 3, s, 1, bias=False),
                                 nn.BatchNorm2d(co), nn.ReLU(inplace=True))

        # 图像主干
        self.trunk = nn.Sequential(blk(3, 16, 2), blk(16, 32, 2), blk(32, 64, 2))
        # 车道线分支（输入为 lane_mask）
        self.lane_enc = nn.Sequential(blk(lane_in_channels, 16, 2), blk(16, 32, 2),
                                      blk(32, 64, 2))
        self.lane_pool = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Flatten(),
                                       nn.Linear(64, 64), nn.ReLU(inplace=True))
        # 车道分割辅助头
        self.lane_seg = nn.Conv2d(64, 1, 1)
        # 车道专属转向辅助头（只吃车道特征 → 强制车道特征具备转向预测力）
        self.lane_steer_head = nn.Sequential(nn.Linear(64, 32), nn.ReLU(inplace=True),
                                             nn.Linear(32, 1), nn.Tanh())
        # 检测框分支：逐框 MLP + 掩码池化
        self.det_mlp = nn.Sequential(nn.Linear(6, 32), nn.ReLU(inplace=True),
                                     nn.Linear(32, det_feat_dim), nn.ReLU(inplace=True))
        # 状态分支
        self.state_mlp = nn.Sequential(nn.Linear(state_dim, 32), nn.ReLU(inplace=True))
        # 融合头
        self.fuse = nn.Sequential(nn.Linear(64 + det_feat_dim + 32, 64),
                                  nn.ReLU(inplace=True))
        self.head_steer = nn.Linear(64, 1)
        self.head_throttle = nn.Linear(64, 1)   # 输出 logits
        self.head_brake = nn.Linear(64, 1)      # 输出 logits

    def forward(self, image, vehicle_state, lane_mask=None, detections=None,
                det_valid=None, **kwargs):
        B = image.shape[0]
        dev = image.device
        H, W = image.shape[-2:]

        # 车道分支：缺 lane_mask 时置零（模型仍可跑，但该路径无信息 → 辅助损失会被跳过）
        if lane_mask is None:
            lane_mask = torch.zeros(B, 1, H, W, device=dev, dtype=image.dtype)
        if lane_mask.dim() == 3:
            lane_mask = lane_mask.unsqueeze(1)

        lane_fmap = self.lane_enc(lane_mask)
        lane_vec = self.lane_pool(lane_fmap)                       # [B,64]
        lane_logits = self.lane_seg(lane_fmap)                     # [B,1,h,w]
        lane_logits = F.interpolate(lane_logits, size=(H, W), mode="bilinear",
                                    align_corners=False)
        aux_steer = self.lane_steer_head(lane_vec)                 # [B,1]

        # 检测框分支：缺检测框时用零张量（det_valid 全 False → 池化输出 0）
        if detections is None:
            detections = torch.zeros(B, self.max_dets, 6, device=dev, dtype=image.dtype)
            det_valid = torch.zeros(B, self.max_dets, device=dev, dtype=torch.bool)
        if det_valid is None:
            det_valid = detections[..., 4] > 0
        det_feat = self.det_mlp(detections)                        # [B,N,32]
        m = det_valid.unsqueeze(-1).to(det_feat.dtype)             # [B,N,1]
        det_vec = (det_feat * m).sum(1) / m.sum(1).clamp(min=1.0)  # [B,32]

        img_vec = self.trunk(image).mean(dim=(2, 3))               # [B,64]
        st_vec = self.state_mlp(vehicle_state)                     # [B,32]

        fused = self.fuse(torch.cat([img_vec, det_vec, st_vec], dim=1))
        return {
            "steer": torch.tanh(self.head_steer(fused)),           # [-1,1]
            "throttle_logit": self.head_throttle(fused),           # logits
            "brake_logit": self.head_brake(fused),                 # logits
            "aux_steer": aux_steer,                                # 车道专属 steer
            "lane_logits": lane_logits,                            # 车道分割辅助
            "lane_feat": lane_vec,
        }


def build_v2_model(image_size, max_dets, force_reference=False):
    """构建模型：优先 M2 的 src/model_v2.build_model()，缺失则降级到参考实现。

    返回 (model, source_name)
    """
    if not force_reference:
        try:
            import importlib
            mod = importlib.import_module("src.model_v2")
            if not hasattr(mod, "build_model"):
                print("[M2接口] ⚠ model_v2 模块存在但无 build_model()")
            else:
                kwargs = dict(lane_in_channels=1, max_dets=max_dets, state_dim=6,
                              det_feat_dim=32, image_size=image_size)
                sig = inspect.signature(mod.build_model)
                accepts_kwargs = any(p.kind == inspect.Parameter.VAR_KEYWORD
                                     for p in sig.parameters.values())
                if not accepts_kwargs:
                    kwargs = {k: v for k, v in kwargs.items() if k in sig.parameters}
                model = mod.build_model(**kwargs)
                print(f"[M2接口] ✓ 使用 src.model_v2.build_model()")
                return model, "src.model_v2.build_model"
        except Exception as e:
            print(f"[M2接口] ⚠ 未能加载 src.model_v2（{type(e).__name__}: {e}）→ 降级")

    print("[M2接口] ⚠ 降级为内置参考实现 _ReferenceModelV2（仅用于跑通，非生产模型）")
    return _ReferenceModelV2(max_dets=max_dets), "_ReferenceModelV2(内置参考实现)"


# ==================== 4. 模型输出归一化（兼容 dict / tuple / 别名） ====================

_STEER_KEYS = ("steer", "steering", "pred_steer", "steer_pred")
_THR_KEYS = ("throttle_logit", "throttle", "pred_throttle", "throttle_pred")
_BRK_KEYS = ("brake_logit", "brake", "pred_brake", "brake_pred")
_AUX_STEER_KEYS = ("aux_steer", "lane_steer", "steer_aux", "aux_steering")
_LANE_LOGIT_KEYS = ("lane_logits", "lane_logit", "lane_pred", "lane_mask_logits")
_LANE_FEAT_KEYS = ("lane_feat", "lane_features", "lane_vec")


def _pick(d: Dict[str, Any], keys) -> Optional[torch.Tensor]:
    """按键名别名取值（大小写不敏感）。"""
    lower = {str(k).lower(): v for k, v in d.items()}
    for k in keys:
        if k in lower:
            return lower[k]
    return None


def normalize_outputs(out: Any, ctl_mode: str = "auto") -> Dict[str, Optional[torch.Tensor]]:
    """把 M2 模型的任意返回格式归一化为标准 dict。

    ctl_mode: auto|logits|probs —— 仅作用于 tuple/list 返回值，
              决定第 2/3 项是 BCE 前 logits 还是已 sigmoid 的概率。
              dict 返回值以键名判定（含 _logit 后缀 = logits，否则按概率处理）。
    """
    res = {k: None for k in ("steer", "throttle_logit", "brake_logit",
                             "aux_steer", "lane_logits", "lane_feat")}

    if isinstance(out, dict):
        res["steer"] = _pick(out, _STEER_KEYS)
        thr = _pick(out, _THR_KEYS)
        brk = _pick(out, _BRK_KEYS)
        # dict 分支：键名带 _logit 视为 logits，否则视为概率 → 转 logits
        res["throttle_logit"] = _to_logits(thr, is_logits=_key_is_logit(out, _THR_KEYS))
        res["brake_logit"] = _to_logits(brk, is_logits=_key_is_logit(out, _BRK_KEYS))
        res["aux_steer"] = _pick(out, _AUX_STEER_KEYS)
        res["lane_logits"] = _pick(out, _LANE_LOGIT_KEYS)
        res["lane_feat"] = _pick(out, _LANE_FEAT_KEYS)
    elif isinstance(out, (tuple, list)):
        if len(out) < 3:
            raise ValueError(f"模型返回序列长度 {len(out)} < 3，无法解析 steer/throttle/brake")
        res["steer"] = out[0]
        as_logits = (ctl_mode != "probs")
        res["throttle_logit"] = _to_logits(out[1], is_logits=as_logits)
        res["brake_logit"] = _to_logits(out[2], is_logits=as_logits)
        if len(out) >= 4:
            res["aux_steer"] = out[3]
        if len(out) >= 5:
            res["lane_logits"] = out[4]
    else:
        raise TypeError(f"模型返回类型不支持: {type(out)}")

    for k in ("steer", "throttle_logit", "brake_logit"):
        if res[k] is None:
            raise KeyError(f"模型输出缺少必需项 '{k}'；请对照 train_v2.py 顶部 M2 接口契约")
        if res[k].dim() == 1:
            res[k] = res[k].unsqueeze(-1)
    if res["aux_steer"] is not None and res["aux_steer"].dim() == 1:
        res["aux_steer"] = res["aux_steer"].unsqueeze(-1)
    return res


def _key_is_logit(out: Dict[str, Any], keys) -> bool:
    """dict 输出中，键名含 'logit' 视为 BCE 前 logits。"""
    for k in out.keys():
        lk = str(k).lower()
        if lk in keys:
            return "logit" in lk
    return False


def _to_logits(t: Optional[torch.Tensor], is_logits: bool) -> Optional[torch.Tensor]:
    """概率 → logits 转换（数值安全裁剪，避免 log(0)）。"""
    if t is None or is_logits:
        return t
    p = t.clamp(1e-4, 1.0 - 1e-4)
    return torch.log(p) - torch.log1p(-p)


# ==================== 5. 前向调用（按形参名传参，兼容 M2 各种签名） ====================

def call_model(model: nn.Module, image, vehicle_state, lane_mask=None,
               detections=None, det_valid=None) -> Any:
    """按模型 forward 的实际形参名传参，形参顺序不敏感。

    只传模型声明接受的参数；模型不接受 lane_mask/detections 时自动不传（该模态被忽略）。
    """
    sig = inspect.signature(model.forward)
    params = sig.parameters
    accepts_kwargs = any(p.kind == inspect.Parameter.VAR_KEYWORD
                         for p in params.values())
    avail = {"image": image, "vehicle_state": vehicle_state,
             "lane_mask": lane_mask, "detections": detections, "det_valid": det_valid}
    kwargs = {k: v for k, v in avail.items() if (accepts_kwargs or k in params) and v is not None}
    # 必填项兜底：即使模型把 image/state 写成位置参数也要给上
    for k in ("image", "vehicle_state"):
        kwargs.setdefault(k, avail[k])
    return model(**kwargs)


# ==================== 6. 车道线几何 → steer 反推（一致性损失用） ====================

def lane_geometry_steer(lane_mask: torch.Tensor, gain: float = 1.0) -> Tuple[torch.Tensor, torch.Tensor]:
    """由车道线掩码几何反推"转向代理值"，用于车道一致性损失。

    做法（启发式，非精确几何）：
      · 底带 y∈[0.75H,H) 车道线横向质心 → 归一化横向偏移 offset ∈ [-1,1]
      · 中带 y∈[0.45H,0.60H) 质心 → 与底带求斜率 slope（近似航向角）
      · proxy = gain × (0.7×offset + 0.3×tanh(slope))
    符号约定：车道中心偏右 ⇒ steer 为正（右转）。若与 M2/M3 约定相反，
    本脚本会在启动时用 --lane_sign_autocalib 自动测相关并翻符号。

    返回 (proxy [B,1], valid [B] 布尔)：有效 = 该样本车道线像素足够多。
    """
    if lane_mask is None:
        return None, None
    if lane_mask.dim() == 3:
        lane_mask = lane_mask.unsqueeze(1)
    B, _, H, W = lane_mask.shape
    m = (lane_mask > 0.5).to(torch.float32)

    def band_centroid(y0f, y1f):
        y0, y1 = int(H * y0f), max(int(H * y1f), int(H * y0f) + 1)
        band = m[:, :, y0:y1, :]                                  # [B,1,h,W]
        cnt = band.sum(dim=(2, 3))                                # [B,1]
        xs = torch.arange(W, device=m.device, dtype=m.dtype).view(1, 1, 1, W)
        cx = (band * xs).sum(dim=(2, 3)) / cnt.clamp(min=1.0)      # [B,1]
        return cx, cnt

    cx_bot, cnt_bot = band_centroid(0.75, 1.0)
    cx_mid, cnt_mid = band_centroid(0.45, 0.60)

    # 像素 → 归一化 [-1,1]（以图像中心为 0）
    offset = (cx_bot / max(W - 1, 1)) * 2.0 - 1.0                 # [B,1]
    slope = (cx_mid - cx_bot) / max(W - 1, 1)                     # 上带相对底带位移
    proxy = gain * (0.7 * offset + 0.3 * torch.tanh(slope * 4.0))
    valid = (cnt_bot.squeeze(1) > 8) & (cnt_mid.squeeze(1) > 4)
    return proxy.clamp(-1.0, 1.0), valid


def calibrate_lane_sign(dataset, device, n_probe: int = 200, seed: int = 42) -> Tuple[float, float]:
    """用训练集实测"车道几何 proxy"与"GT steer"的相关性，自动定符号。

    返回 (sign, corr)：
      · corr 绝对值很小（<0.05）⇒ 几何 proxy 无信息量，调用方应关闭一致性损失
      · sign = ±1，用于翻正 proxy 方向，避免符号约定搞反导致一致性损失反向优化
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
        if lm is None:
            continue
        lm = lm if isinstance(lm, torch.Tensor) else torch.as_tensor(lm, dtype=torch.float32)
        if float(lm.sum()) <= 0:
            continue
        p, v = lane_geometry_steer(lm.unsqueeze(0).to(device))
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
    denom = (a.norm() * b.norm()).clamp(min=1e-8)
    corr = float((a * b).sum() / denom)
    return (1.0 if corr >= 0 else -1.0), corr


# ==================== 7. 损失：主损失 + 车道线辅助损失 ====================

class V2Loss(nn.Module):
    """M9-v2 损失。

    主损失：
      steer      —— L1 或 MSE（--steer_loss 选择）
      throttle   —— BCEWithLogits
      brake      —— BCEWithLogits
    辅助损失（让车道线分支真正影响 steer）：
      lane_seg         —— 车道分割 BCE（监督车道编码器）
      lane_steer       —— 车道专属 steer 头 L1（★ 主力：梯度必穿车道编码器）
      lane_consistency —— 主 steer 与"车道几何反推 steer"的 L1（保证主头与车道几何自洽）
    """

    def __init__(self, steer_weight=1.0, throttle_weight=0.5, brake_weight=0.5,
                 steer_loss="l1", lane_seg_weight=0.3, lane_steer_weight=0.5,
                 lane_consistency_weight=0.05, lane_gain=1.0,
                 pos_weight_lane: Optional[float] = None):
        super().__init__()
        self.steer_weight = steer_weight
        self.throttle_weight = throttle_weight
        self.brake_weight = brake_weight
        self.steer_loss = steer_loss
        self.lane_seg_weight = lane_seg_weight
        self.lane_steer_weight = lane_steer_weight
        self.lane_consistency_weight = lane_consistency_weight
        self.lane_gain = lane_gain
        self.pos_weight_lane = pos_weight_lane

    def forward(self, preds: Dict[str, Optional[torch.Tensor]], batch: Dict[str, Any],
                enable: Dict[str, bool]) -> Tuple[torch.Tensor, Dict[str, float], Dict[str, float]]:
        """返回 (total_loss, comps 各分项标量, aux_stats 辅助统计)。

        enable 里为 False 的分支直接跳过 —— 这是"数据缺标注时降级运行"的落点。
        """
        dev = preds["steer"].device
        gt_s = batch["steer"].to(dev).reshape(-1, 1)
        gt_t = batch["throttle"].to(dev).reshape(-1, 1)
        gt_b = batch["brake"].to(dev).reshape(-1, 1)

        # ---- 主损失 ----
        if self.steer_loss == "mse":
            l_steer = F.mse_loss(preds["steer"], gt_s)
        else:
            l_steer = F.l1_loss(preds["steer"], gt_s)
        l_thr = F.binary_cross_entropy_with_logits(preds["throttle_logit"], gt_t)
        l_brk = F.binary_cross_entropy_with_logits(preds["brake_logit"], gt_b)

        total = (self.steer_weight * l_steer + self.throttle_weight * l_thr
                 + self.brake_weight * l_brk)
        comps = {"steer": float(l_steer.detach()), "throttle": float(l_thr.detach()),
                 "brake": float(l_brk.detach())}
        stats = {"lane_supervised_frac": 0.0, "lane_consistency_valid_frac": 0.0}

        # ---- 辅助 1：车道分割 BCE ----
        lane_mask = batch.get("lane_mask")
        if enable.get("lane_seg") and lane_mask is not None and preds["lane_logits"] is not None:
            lm = lane_mask.to(dev)
            if lm.dim() == 3:
                lm = lm.unsqueeze(1)
            lg = preds["lane_logits"]
            if lg.shape[-2:] != lm.shape[-2:]:
                lg = F.interpolate(lg, size=lm.shape[-2:], mode="bilinear",
                                   align_corners=False)
            pw = None
            if self.pos_weight_lane is not None:
                pw = torch.tensor([self.pos_weight_lane], device=dev)
            l_seg = F.binary_cross_entropy_with_logits(lg, lm, pos_weight=pw)
            total = total + self.lane_seg_weight * l_seg
            comps["lane_seg"] = float(l_seg.detach())
            stats["lane_supervised_frac"] = 1.0

        # ---- 辅助 2：车道专属 steer 头（★ 主力机制） ----
        if enable.get("lane_steer") and preds["aux_steer"] is not None:
            l_ls = F.l1_loss(preds["aux_steer"], gt_s)
            total = total + self.lane_steer_weight * l_ls
            comps["lane_steer"] = float(l_ls.detach())

        # ---- 辅助 3：车道几何一致性 ----
        if (enable.get("lane_consistency") and lane_mask is not None
                and self.lane_consistency_weight > 0):
            proxy, valid = lane_geometry_steer(lane_mask.to(dev), gain=self.lane_gain)
            if proxy is not None and bool(valid.any()):
                d = (preds["steer"].reshape(-1) - proxy.reshape(-1)).abs()
                l_lc = d[valid].mean()
                total = total + self.lane_consistency_weight * l_lc
                comps["lane_consistency"] = float(l_lc.detach())
                stats["lane_consistency_valid_frac"] = float(valid.float().mean())

        comps["total"] = float(total.detach())
        return total, comps, stats


# ==================== 8. 耦合诊断（校验 A：车道分支对 steer 有无梯度贡献） ====================

def lane_param_norm(model: nn.Module, keyword: str = "lane") -> float:
    """车道分支参数的梯度范数（须在 steer-only 反传之后调用）。"""
    sq = 0.0
    for n, p in model.named_parameters():
        if keyword in n.lower() and p.grad is not None:
            sq += float(p.grad.detach().pow(2).sum())
    return math.sqrt(sq)


def diagnose_lane_coupling(model, batch, device, loss_fn, use_amp, keyword="lane") -> Optional[float]:
    """单独对 steer 损失反传，测车道分支参数梯度范数。

    ≈ 0 说明 steer 损失完全不流经车道分支 ⇒ 车道线是装饰性旁支（"白加"）。
    诊断后清空梯度，不影响正常训练。异常时返回 None（不中断训练）。
    """
    try:
        model.zero_grad(set_to_none=True)
        img = batch["image"].to(device)
        vs = batch["vehicle_state"].to(device)
        lm = batch.get("lane_mask")
        lm = lm.to(device) if lm is not None else None
        det = batch.get("detections")
        det = det.to(device) if det is not None else None
        dv = batch.get("det_valid")
        dv = dv.to(device) if dv is not None else None

        with torch.amp.autocast(device_type=device, enabled=use_amp):
            out = call_model(model, img, vs, lm, det, dv)
            preds = normalize_outputs(out)
            gt_s = batch["steer"].to(device).reshape(-1, 1)
            l_steer = (F.mse_loss(preds["steer"], gt_s) if loss_fn.steer_loss == "mse"
                       else F.l1_loss(preds["steer"], gt_s))
        l_steer.backward()
        gn = lane_param_norm(model, keyword)
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
def validate_v2(model, loader, loss_fn, device, use_amp, enable,
                do_ablation=False) -> Dict[str, float]:
    """验证集评估。do_ablation=True 时额外做一次"车道线置零"前向，测 steer L1 差异。

    lane_ablation_delta = 置零后的 steer L1 − 正常 steer L1
      Δ 明显 > 0 ⇒ 模型确实在用车道线；Δ ≈ 0 ⇒ 车道线白加了。
    """
    model.eval()
    acc: Dict[str, float] = {}
    n = 0
    abl_l1_sum, real_l1_sum, abl_n = 0.0, 0.0, 0
    lane_frac_sum = 0.0

    for batch in loader:
        img = batch["image"].to(device)
        vs = batch["vehicle_state"].to(device)
        lm = batch.get("lane_mask")
        lm = lm.to(device) if lm is not None else None
        det = batch.get("detections")
        det = det.to(device) if det is not None else None
        dv = batch.get("det_valid")
        dv = dv.to(device) if dv is not None else None

        with torch.amp.autocast(device_type=device, enabled=use_amp):
            out = call_model(model, img, vs, lm, det, dv)
            preds = normalize_outputs(out)
            _, comps, stats = loss_fn(preds, batch, enable)

        for k, v in comps.items():
            acc[k] = acc.get(k, 0.0) + v
        lane_frac_sum += stats.get("lane_supervised_frac", 0.0)
        n += 1

        # ---- 校验 B：车道线置零消融 ----
        if do_ablation and lm is not None:
            gt_s = batch["steer"].to(device).reshape(-1, 1)
            zero_lm = torch.zeros_like(lm)
            with torch.amp.autocast(device_type=device, enabled=use_amp):
                out2 = call_model(model, img, vs, zero_lm, det, dv)
                preds2 = normalize_outputs(out2)
            real_l1_sum += float(F.l1_loss(preds["steer"], gt_s))
            abl_l1_sum += float(F.l1_loss(preds2["steer"], gt_s))
            abl_n += 1

    res = {k: v / max(n, 1) for k, v in acc.items()}
    res["lane_supervised_frac"] = lane_frac_sum / max(n, 1)
    if abl_n > 0:
        real_l1 = real_l1_sum / abl_n
        abl_l1 = abl_l1_sum / abl_n
        res["steer_l1_with_lane"] = real_l1
        res["steer_l1_lane_zeroed"] = abl_l1
        res["lane_ablation_delta"] = abl_l1 - real_l1
    model.train()
    return res


# ==================== 10. 合成数据集（自测用：含车道线 + 检测框） ====================

class _SyntheticV2Dataset(Dataset):
    """合成数据：车道线掩码与 steer 强相关，用于验证辅助损失/耦合诊断真的生效。

    仅用于自测与 M2/M3 联调，不参与生产训练。
    """

    def __init__(self, size=256, image_size=(180, 320), max_dets=DEFAULT_MAX_DETS,
                 with_lane=True, with_det=True, seed=0):
        self.size = size
        self.H, self.W = image_size
        self.max_dets = max_dets
        self.with_lane = with_lane
        self.with_det = with_det
        self.seed = seed

    def __len__(self):
        return self.size

    def __getitem__(self, idx):
        g = torch.Generator().manual_seed(self.seed * 100003 + idx)
        H, W = self.H, self.W
        offset = float(torch.rand(1, generator=g) * 2 - 1)    # 车道横向偏移
        curv = float(torch.rand(1, generator=g) * 2 - 1)      # 车道曲率
        steer = max(-1.0, min(1.0, 0.6 * offset + 0.4 * curv))

        image = torch.rand(3, H, W, generator=g) * 0.3 + 0.35
        lane_mask = torch.zeros(1, H, W)
        if self.with_lane:
            yy = torch.arange(H).view(H, 1).float()
            xx = torch.arange(W).view(1, W).float()
            t = yy / max(H - 1, 1)
            center = W / 2 + offset * (W * 0.3) * t + curv * (W * 0.5) * (1 - t) ** 2
            half = 20 + 45 * t
            lm = ((xx - (center - half)).abs() < 2.0) | ((xx - (center + half)).abs() < 2.0)
            lane_mask[0] = lm.float()
            image = torch.clamp(image + lane_mask * 0.4, 0, 1)

        if self.with_det:
            n = int(torch.randint(0, 5, (1,), generator=g))
            det = torch.zeros(self.max_dets, 6)
            dv = torch.zeros(self.max_dets, dtype=torch.bool)
            for i in range(n):
                x1 = float(torch.rand(1, generator=g))
                y1 = float(torch.rand(1, generator=g)) * 0.7
                w = 0.05 + float(torch.rand(1, generator=g)) * 0.2
                h = 0.05 + float(torch.rand(1, generator=g)) * 0.2
                det[i] = torch.tensor([x1, y1, min(1.0, x1 + w), min(1.0, y1 + h),
                                       0.5 + float(torch.rand(1, generator=g)) * 0.5,
                                       float(torch.randint(0, 3, (1,), generator=g))])
                dv[i] = True
        else:
            det, dv = None, None

        return {
            "image": image,
            "vehicle_state": torch.rand(6, generator=g) * 2 - 1,
            "steer": torch.tensor([steer]),
            "throttle": torch.tensor([max(0.0, min(1.0, 0.5 + 0.3 * steer))]),
            "brake": torch.tensor([1.0 if curv < -0.8 else 0.0]),
            "lane_mask": lane_mask if self.with_lane else None,
            "detections": det,
            "det_valid": dv,
        }


# ==================== 11. 训练主流程 ====================

def train_v2(
    epochs: int = 30,
    batch_size: int = 8,
    grad_accum: int = 2,
    lr: float = 3e-4,
    weight_decay: float = 5e-4,
    image_size: Tuple[int, int] = (180, 320),
    val_ratio: float = 0.15,
    use_amp: bool = True,
    device: str = "auto",
    clips_dir: Optional[str] = None,
    view_filter: Optional[str] = None,
    checkpoint_dir: Optional[str] = None,
    num_workers: int = 0,
    seed: int = 42,
    patience: int = 8,
    save_every: int = 10,
    max_dets: int = DEFAULT_MAX_DETS,
    # 损失权重
    steer_weight: float = 1.0,
    throttle_weight: float = 0.5,
    brake_weight: float = 0.5,
    steer_loss: str = "l1",
    lane_seg_weight: float = 0.3,
    lane_steer_weight: float = 0.5,
    lane_consistency_weight: float = 0.05,
    lane_consistency_gain: float = 1.0,
    # 降级 / 诊断开关
    no_lane: bool = False,
    no_det: bool = False,
    lane_grad_diag: bool = True,
    lane_ablation_every: int = 1,
    lane_sign_autocalib: bool = True,
    synthetic: bool = False,
    synthetic_size: int = 256,
    limit_batches: int = 0,
    resume: Optional[str] = None,
    force_reference_model: bool = False,
) -> Path:
    torch.manual_seed(seed)
    random.seed(seed)

    device = resolve_device(device)
    use_amp = resolve_amp(use_amp, device)

    print(f"\n{'='*66}")
    print(f"[M9-v2] 训练启动 | device={device} | amp={use_amp} | epochs={epochs} "
          f"| batch={batch_size}×{grad_accum} | lr={lr}")
    print(f"{'='*66}")

    # ---------- 1. 数据 ----------
    if synthetic:
        train_ds = _SyntheticV2Dataset(size=synthetic_size, image_size=image_size,
                                       max_dets=max_dets, with_lane=not no_lane,
                                       with_det=not no_det, seed=seed)
        val_ds = _SyntheticV2Dataset(size=max(32, synthetic_size // 4), image_size=image_size,
                                     max_dets=max_dets, with_lane=not no_lane,
                                     with_det=not no_det, seed=seed + 7777)
        ds_source = "合成数据 _SyntheticV2Dataset（自测用）"
        has_lane, has_det = (not no_lane), (not no_det)
        print(f"[数据] 使用合成数据集：train={len(train_ds)} val={len(val_ds)}")
    else:
        cd = clips_dir or str(_ROOT / "data" / "raw_clips")
        train_ds, ds_source, has_lane, has_det = build_v2_dataset(
            clips_dir=cd, image_size=image_size, augment=True, view_filter=view_filter,
            seed=seed, max_dets=max_dets, force_no_lane=no_lane, force_no_det=no_det)
        # 验证集不增强，且按 clip 边界切分（避免同 clip 帧跨 split 泄漏）
        val_ds = None
        try:
            from src.mono_dataset import make_train_val_split
            if hasattr(train_ds, "index"):          # 降级适配器路径
                train_ds, val_ds = make_train_val_split(train_ds, val_ratio=val_ratio, seed=seed)
            elif hasattr(train_ds, "base") and hasattr(train_ds.base, "index"):
                tr, va = make_train_val_split(train_ds.base, val_ratio=val_ratio, seed=seed)
                train_ds.base, val_ds = tr, _MonoDatasetV2Adapter.__new__(_MonoDatasetV2Adapter)
                val_ds.base, val_ds.max_dets = va, max_dets
                val_ds.has_lane, val_ds.has_det = False, False
        except Exception as e:
            print(f"[数据] ⚠ 自动切分失败（{type(e).__name__}: {e}）")
        if val_ds is None:
            # 兜底：按帧随机切分
            n_val = max(1, int(len(train_ds) * val_ratio))
            n_tr = max(1, len(train_ds) - n_val)
            train_ds, val_ds = torch.utils.data.random_split(
                train_ds, [n_tr, n_val], generator=torch.Generator().manual_seed(seed))
            print(f"[数据] ⚠ 退化为按帧随机切分 train={n_tr} val={n_val}")

    # ---------- 2. 降级裁决（诚实前提的落点） ----------
    if not has_lane:
        print("[降级] ⚠ 数据无车道线标注 → 车道分割/车道专属steer/几何一致性 三项辅助损失全部禁用")
        print("[降级]    （无监督的车道特征等同噪声，喂给辅助头有害，故一并关闭而非置零）")
    if not has_det:
        print("[降级] ⚠ 数据无检测框标注 → 检测分支输入置零（模型仍可前向，该路径无信息）")

    enable = {
        "lane_seg": bool(has_lane and lane_seg_weight > 0),
        "lane_steer": bool(has_lane and lane_steer_weight > 0),
        "lane_consistency": bool(has_lane and lane_consistency_weight > 0),
    }

    # 车道几何符号自动校准（避免符号约定搞反 → 一致性损失反向优化）
    lane_gain = lane_consistency_gain
    lane_sign_corr = 0.0
    if enable["lane_consistency"] and lane_sign_autocalib:
        sign, corr = calibrate_lane_sign(train_ds, "cpu", seed=seed)
        lane_sign_corr = corr
        lane_gain = lane_consistency_gain * sign
        print(f"[车道校准] proxy↔steer 相关系数 corr={corr:+.3f} → 符号 {'保持' if sign > 0 else '翻转'}"
              f"（gain={lane_gain:+.2f}）")
        if abs(corr) < 0.05:
            print("[车道校准] ⚠ 相关性过弱，几何 proxy 无信息量 → 关闭车道几何一致性损失")
            enable["lane_consistency"] = False

    # ---------- 3. DataLoader ----------
    pin = (device == "cuda")   # MPS 上 pin_memory 反而增加拷贝开销
    coll = lambda b: collate_v2(b, max_dets=max_dets)  # noqa: E731
    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True,
                              num_workers=num_workers, pin_memory=pin, collate_fn=coll,
                              drop_last=False)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False,
                            num_workers=num_workers, pin_memory=pin, collate_fn=coll,
                            drop_last=False)

    # ---------- 4. 模型 ----------
    model, model_source = build_v2_model(image_size, max_dets,
                                         force_reference=force_reference_model)
    model.to(device)
    n_param = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"[模型] 来源={model_source} | 可训练参数={n_param:,} ({n_param/1e6:.2f}M)")

    # 检查模型是否支持车道输入（不支持则辅助损失无意义）
    fwd_params = set(inspect.signature(model.forward).parameters.keys())
    model_accepts_lane = "lane_mask" in fwd_params or any(
        p.kind == inspect.Parameter.VAR_KEYWORD
        for p in inspect.signature(model.forward).parameters.values())
    if enable["lane_steer"] and not model_accepts_lane:
        print("[M2接口] ⚠ 模型 forward 不接受 lane_mask → 车道线输入无法进入模型，"
              "相关辅助损失虽开但无实际作用，请在 M2 侧对齐契约")
    if enable["lane_steer"] and not model_source.startswith("src.model_v2"):
        print("[M2接口] ⚠ 未使用生产模型；参考实现自带 aux_steer 头，辅助损失可正常验证")

    # ---------- 5. 优化器 / 调度器 / 损失 ----------
    optimizer = build_adamw_optimizer(model, lr=lr, weight_decay=weight_decay)
    loss_fn = V2Loss(steer_weight=steer_weight, throttle_weight=throttle_weight,
                     brake_weight=brake_weight, steer_loss=steer_loss,
                     lane_seg_weight=lane_seg_weight, lane_steer_weight=lane_steer_weight,
                     lane_consistency_weight=lane_consistency_weight, lane_gain=lane_gain)
    scaler = torch.amp.GradScaler(device=device) if use_amp else None

    steps_per_epoch = max(1, len(train_loader) // max(grad_accum, 1))
    total_steps = epochs * steps_per_epoch
    scheduler = CosineWithWarmup(optimizer, warmup_steps=max(1, steps_per_epoch),
                                 total_steps=total_steps, base_lr=lr, min_lr=lr * 0.01)

    # ---------- 6. 训练状态 ----------
    ckpt_dir = Path(checkpoint_dir) if checkpoint_dir else DEFAULT_CKPT_DIR
    ckpt_dir.mkdir(parents=True, exist_ok=True)     # 新目录，不动现有 checkpoint
    best_val_loss = float("inf")
    start_epoch = 0
    train_history, val_history = [], []
    bad_epochs = 0

    if resume:
        rp = Path(resume)
        if rp.exists():
            ck = torch.load(rp, map_location=device, weights_only=False)
            model.load_state_dict(ck["model_state_dict"], strict=False)
            if "optimizer_state_dict" in ck:
                try:
                    optimizer.load_state_dict(ck["optimizer_state_dict"])
                except Exception as e:
                    print(f"[恢复] ⚠ 优化器状态未恢复（{type(e).__name__}: {e}）")
            start_epoch = int(ck.get("epoch", -1)) + 1
            best_val_loss = float(ck.get("best_val_loss", float("inf")))
            print(f"[恢复] 从 {rp} 继续，start_epoch={start_epoch} best_val_loss={best_val_loss:.4f}")
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
        lane_grad_norm_ep: Optional[float] = None
        lane_frac_ep = 0.0

        for bi, batch in enumerate(train_loader):
            if limit_batches and bi >= limit_batches:
                break

            img = batch["image"].to(device, non_blocking=pin)
            vs = batch["vehicle_state"].to(device, non_blocking=pin)
            lm = batch.get("lane_mask")
            lm = lm.to(device, non_blocking=pin) if lm is not None else None
            det = batch.get("detections")
            det = det.to(device, non_blocking=pin) if det is not None else None
            dv = batch.get("det_valid")
            dv = dv.to(device, non_blocking=pin) if dv is not None else None

            # ---- 校验 A：每 epoch 首个 batch 做一次车道耦合梯度诊断 ----
            if lane_grad_diag and bi == 0 and enable["lane_steer"]:
                lane_grad_norm_ep = diagnose_lane_coupling(
                    model, batch, device, loss_fn, use_amp)

            with torch.amp.autocast(device_type=device, enabled=use_amp):
                out = call_model(model, img, vs, lm, det, dv)
                preds = normalize_outputs(out)
                loss, comps, stats = loss_fn(preds, batch, enable)
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
        train_m["lane_grad_norm"] = lane_grad_norm_ep
        train_history.append(train_m)

        # ---- 验证 ----
        do_abl = bool(enable["lane_steer"] and lane_ablation_every > 0
                      and (epoch % lane_ablation_every == 0))
        val_m = validate_v2(model, val_loader, loss_fn, device, use_amp, enable,
                            do_ablation=do_abl)
        val_m["epoch"] = epoch
        val_history.append(val_m)
        val_loss = val_m["loss"]

        if device == "mps":
            torch.mps.empty_cache()   # 缓解 MPS 显存碎片

        # ---- 日志 ----
        ep_dt = time.time() - ep_t0
        extra = f" lane_steer={train_m.get('lane_steer', 0):.4f}" if enable["lane_steer"] else ""
        print(f"Epoch {epoch:3d}/{epochs} | {ep_dt:5.1f}s | "
              f"train={train_m['total']:.4f} (steer={train_m['steer']:.4f}{extra}) | "
              f"val={val_loss:.4f} (steer={val_m['steer']:.4f}) | "
              f"lr={optimizer.param_groups[0]['lr']:.2e}")

        # 诚实告警：车道线是否真的在起作用
        if lane_grad_norm_ep is not None:
            if lane_grad_norm_ep < 1e-6:
                print("  ⚠ [耦合告警] steer 损失对车道分支的梯度范数≈0 → "
                      "车道线分支对转向无贡献（等于白加），请检查 M2 的 aux_steer/融合结构")
        if "lane_ablation_delta" in val_m:
            d = val_m["lane_ablation_delta"]
            print(f"  · 车道消融: steer_l1={val_m['steer_l1_with_lane']:.4f} → "
                  f"置零后={val_m['steer_l1_lane_zeroed']:.4f} (Δ={d:+.4f})")
            if d < 1e-4:
                print("  ⚠ [消融告警] 置零车道线后 steer 误差几乎不变 → "
                      "模型没在用车道线信息（等于白加）")

        # ---- 保存 best ----
        is_best = val_loss < best_val_loss
        if is_best:
            best_val_loss = val_loss
            bad_epochs = 0
            torch.save({
                "epoch": epoch,
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "best_val_loss": best_val_loss,
                "image_size": list(image_size),
                "interface_version": V2_INTERFACE_VERSION,
                "model_source": model_source,
                "dataset_source": ds_source,
                "degradation": {"has_lane": has_lane, "has_det": has_det},
                "loss_weights": {
                    "steer": steer_weight, "throttle": throttle_weight,
                    "brake": brake_weight, "lane_seg": lane_seg_weight,
                    "lane_steer": lane_steer_weight,
                    "lane_consistency": lane_consistency_weight,
                },
            }, ckpt_dir / "best_model.pt")
            print(f"  ★ 新最佳 val_loss={best_val_loss:.4f} → {ckpt_dir / 'best_model.pt'}")
        else:
            bad_epochs += 1

        # ---- 定期 checkpoint ----
        if save_every > 0 and (epoch + 1) % save_every == 0:
            torch.save({
                "epoch": epoch,
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "best_val_loss": best_val_loss,
                "image_size": list(image_size),
                "interface_version": V2_INTERFACE_VERSION,
            }, ckpt_dir / f"checkpoint_epoch_{epoch:03d}.pt")

        # ---- early stop ----
        if patience > 0 and bad_epochs >= patience:
            print(f"\n[早停] 连续 {bad_epochs} 个 epoch 验证集未改善 → 提前结束")
            break

    # ---------- 8. 落盘日志（含降级与诊断留档） ----------
    log = {
        "interface_version": V2_INTERFACE_VERSION,
        "model_source": model_source,
        "dataset_source": ds_source,
        "device": device, "use_amp": use_amp,
        "epochs": epochs, "batch_size": batch_size, "grad_accum": grad_accum,
        "lr": lr, "weight_decay": weight_decay, "image_size": list(image_size),
        "best_val_loss": best_val_loss,
        "train_history": train_history,
        "val_history": val_history,
        # ⚠️ 降级留档：明确记录本次训练有哪些模态缺失，避免事后误读指标
        "degradation": {
            "has_lane_annotation": has_lane,
            "has_det_annotation": has_det,
            "lane_aux_losses_enabled": enable,
            "lane_sign_corr": lane_sign_corr,
            "lane_gain": lane_gain,
            "note": ("数据缺车道线/检测框标注时，对应分支自动跳过或置零；"
                     "车道辅助损失在无标注时全部禁用，绝不用零掩码假装监督"),
        },
    }
    log_path = ckpt_dir / "training_log.json"
    with open(log_path, "w", encoding="utf-8") as f:
        json.dump(log, f, indent=2, ensure_ascii=False)

    print(f"\n✓ 训练完成 | best_val_loss={best_val_loss:.4f}")
    print(f"  日志: {log_path}")
    print(f"  权重: {ckpt_dir / 'best_model.pt'}")
    if not has_lane:
        print("  ⚠ 本次训练未使用车道线标注（数据缺失），车道线相关指标不可解读为'已验证'")
    return ckpt_dir / "best_model.pt"


# ==================== 12. CLI 入口 ====================

def parse_args():
    p = argparse.ArgumentParser(description="M9-v2 多模态（图像+车道线+检测框+状态）训练")
    # 训练超参
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch_size", type=int, default=8)
    p.add_argument("--grad_accum", type=int, default=2)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--weight_decay", type=float, default=5e-4)
    p.add_argument("--val_ratio", type=float, default=0.15)
    p.add_argument("--patience", type=int, default=8, help="早停耐心值，0=关闭")
    p.add_argument("--save_every", type=int, default=10, help="每 N epoch 存一次 checkpoint，0=关闭")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--num_workers", type=int, default=0)
    # 设备
    p.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"])
    p.add_argument("--no_amp", action="store_true")
    # 路径
    p.add_argument("--clips_dir", default=None)
    p.add_argument("--view_filter", default=None)
    p.add_argument("--checkpoint_dir", default=None, help="默认 checkpoints/m9_v2/")
    p.add_argument("--resume", default=None)
    p.add_argument("--img_h", type=int, default=180)
    p.add_argument("--img_w", type=int, default=320)
    p.add_argument("--max_dets", type=int, default=DEFAULT_MAX_DETS)
    # 损失
    p.add_argument("--steer_loss", default="l1", choices=["l1", "mse"])
    p.add_argument("--steer_weight", type=float, default=1.0)
    p.add_argument("--throttle_weight", type=float, default=0.5)
    p.add_argument("--brake_weight", type=float, default=0.5)
    p.add_argument("--lane_seg_weight", type=float, default=0.3,
                   help="车道分割辅助损失权重")
    p.add_argument("--lane_steer_weight", type=float, default=0.5,
                   help="★车道专属 steer 头辅助损失权重（让车道线真正影响 steer 的主力）")
    p.add_argument("--lane_consistency_weight", type=float, default=0.05,
                   help="主 steer 与车道几何反推值的一致性损失权重，0=关闭")
    p.add_argument("--lane_consistency_gain", type=float, default=1.0,
                   help="几何 proxy 增益；符号约定相反时可取负值")
    p.add_argument("--ctl_mode", default="auto", choices=["auto", "logits", "probs"],
                   help="模型返回 tuple 时第2/3项是 logits 还是概率")
    # 降级 / 诊断
    p.add_argument("--no_lane", action="store_true", help="强制关闭车道线分支（模拟无标注）")
    p.add_argument("--no_det", action="store_true", help="强制关闭检测框分支（模拟无标注）")
    p.add_argument("--no_lane_grad_diag", action="store_true", help="关闭车道耦合梯度诊断")
    p.add_argument("--lane_ablation_every", type=int, default=1,
                   help="每 N epoch 做一次车道消融，0=关闭")
    p.add_argument("--no_lane_sign_autocalib", action="store_true")
    p.add_argument("--force_reference_model", action="store_true",
                   help="强制使用内置参考模型（联调/自测用）")
    # 自测
    p.add_argument("--synthetic", action="store_true", help="用合成数据自测（含车道线+检测框）")
    p.add_argument("--synthetic_size", type=int, default=256)
    p.add_argument("--limit_batches", type=int, default=0, help="每 epoch 最多跑 N 个 batch（调试）")
    return p.parse_args()


def main():
    args = parse_args()
    train_v2(
        epochs=args.epochs, batch_size=args.batch_size, grad_accum=args.grad_accum,
        lr=args.lr, weight_decay=args.weight_decay,
        image_size=(args.img_h, args.img_w), val_ratio=args.val_ratio,
        use_amp=not args.no_amp, device=args.device,
        clips_dir=args.clips_dir, view_filter=args.view_filter,
        checkpoint_dir=args.checkpoint_dir, num_workers=args.num_workers,
        seed=args.seed, patience=args.patience, save_every=args.save_every,
        max_dets=args.max_dets,
        steer_weight=args.steer_weight, throttle_weight=args.throttle_weight,
        brake_weight=args.brake_weight, steer_loss=args.steer_loss,
        lane_seg_weight=args.lane_seg_weight, lane_steer_weight=args.lane_steer_weight,
        lane_consistency_weight=args.lane_consistency_weight,
        lane_consistency_gain=args.lane_consistency_gain,
        no_lane=args.no_lane, no_det=args.no_det,
        lane_grad_diag=not args.no_lane_grad_diag,
        lane_ablation_every=args.lane_ablation_every,
        lane_sign_autocalib=not args.no_lane_sign_autocalib,
        synthetic=args.synthetic, synthetic_size=args.synthetic_size,
        limit_batches=args.limit_batches, resume=args.resume,
        force_reference_model=args.force_reference_model,
    )


if __name__ == "__main__":
    main()
