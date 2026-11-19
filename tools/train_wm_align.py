#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""train_wm_align.py — 冻结两个主干，只训练对齐层的投影头

================================================================================
运行方式（务必走构建锁串行化，机器是 16GB / 8 核，动态模型训练可能还在跑）
================================================================================
    # 冒烟（1~2 分钟，验证整条流水线）
    bash scripts/build-lock.sh run "wm-align 冒烟" -- \
        /usr/local/bin/python3.11 tools/train_wm_align.py --limit 64 --epochs 20

    # 正式训练 + 评测
    bash scripts/build-lock.sh run "wm-align 正式训练" -- \
        /usr/local/bin/python3.11 tools/train_wm_align.py --epochs 300

    # 已缓存特征时跳过缓存阶段，只重训头（消融用）
    /usr/local/bin/python3.11 tools/train_wm_align.py --reuse-cache --future-weight 0

    # 只导出 CoreML（训练完成后）
    /usr/local/bin/python3.11 tools/train_wm_align.py --export-only

================================================================================
为什么先缓存主干特征、再用大 batch 训头（这是本脚本最重要的工程决定）
================================================================================
    实测（MPS，batch=32，一次跑完两侧 encode + 两侧 predict_next）：
        126 ms / 32 帧 = 3.9 ms/帧
    其中主干前向占了绝大部分，两个投影头的前向只占微秒级。

    这意味着两种做法：
      甲：每个 step 都读图 + 跑主干 —— 8000 样本跑 300 epoch 要 3.9ms×8000×300
          ≈ 2.6 小时，且 CPU 上 JPEG 解码与 MPS 计算互相等待，实际更慢。
      乙：主干只跑一遍缓存成 [N,256]，训头时在缓存上做 —— 主干成本 N×3.9ms
          ≈ 52 秒（一次性），之后每个 epoch 只是矩阵乘，可把 batch 开到 512。

    选乙。而且这不只是快：**大 batch 是 InfoNCE 质量的直接来源**。
    batch=512 时每个正样本有 511 个 in-batch 负样本，batch=32 时只有 31 个；
    负样本越少，「把所有样本映成常数」这条塌缩捷径越难被惩罚
    （见 src/wm_align.py docstring §2a）。所以缓存不是偷懒，是为了让
    训练条件本身更好。

    代价说清楚：缓存的是**主干冻结时**的特征。若要解开主干微调，
    这份缓存在第一步之后就不再有效，必须改回做法甲。本任务明确要求冻主干，
    所以这个代价为零。

================================================================================
数据与评测协议（防止「用测试集调参」这类软作弊）
================================================================================
    全部 7 段 clip 里，1 段只有 11 帧（clip_20261104_213233，不足以凑 horizon+1），
    实际可用 6 段。按**整段 clip** 划分（绝不能按帧随机切：相邻帧几乎相同，
    随机切会让训练集和测试集共享同一段运动，指标虚高）：

        ALIGN_TRAIN : 131750, 132750, 211247, 212247     ← 训投影头
        ALIGN_VAL   : 212945                             ← 选模型（早停）
        PROBE_TEST  : 213945                             ← 只做最终评测

    为什么评测必须按 clip 分开：投影头是在 ALIGN_TRAIN 上学的，若在同一个 clip
    的其它帧上测得好看，那只能说明「它记住了这段赛道」，不能说明对齐有效。
    PROBE_TEST 这段 clip 从头到尾没参与训练，任何指标才是可泛化的证据。

    锚点抽样 stride 默认 6 帧（0.4 秒）：帧间相关性极强，stride=1 会让
    「相邻两帧几乎一样」把检索命中率抬到接近 1（那是数据泄漏，不是对齐成功）。

================================================================================
评测指标：三个口径，全部给出对齐前 / 对齐后
================================================================================
    (1) 跨模型检索命中率（top-1）
        「用静态视图去检索同帧的动态视图」。对齐前 = 两侧原始 latent 直接比余弦
        （实测约 0，即完全检索不到）；对齐后 = 共享空间里比。
        随机基线 = 1/N，必须和结果一起报，否则容易把 1/N 误当成功。

    (2) 线性探针：用静态表征预测按键（诊断上用，**不能**当「学到动作因果」的证据）
        在录制帧上，用 ALIGN_TRAIN 的静态表征训一个线性分类器，在 PROBE_TEST 上测。
        报两个口径：
            · 预测「当前帧」按键  —— 泄漏风险高：录制画面带 UI，按键状态可能直接
              画在 HUD 上（速度条/氮气条/按键高亮），模型看到 UI 就能猜。
            · 预测「t+h 帧」按键 —— 泄漏风险低：UI 只反映**当前**按键，t 帧画面里
              没有 t+h 帧的按键状态。这个口径更接近「从场景预估即将发生的操作」。

    (3) 表征健康度：逐维 std / 死维 / 有效秩
        必须两侧分别报，用来证明「没有一侧塌缩去迎合另一侧」。
        有效秩的口径与 task-1/task-2 一致（奇异值熵的指数，见
        wm_dynamic.latent_diagnostics），但注意它被 batch 大小封顶
        （min(B,256)），所以报数时必须同时写 batch。

================================================================================
UI 泄漏对照实验（--hud-mask）
================================================================================
    把 HUD 区域涂成中性灰后再走同一条流水线，重测探针准确率。
    判读方式（这是关键，不要读反）：
        · 遮掉 HUD 后准确率**明显下降** ⇒ 原准确率里相当部分是「读到 UI」，
          不能当成「模型理解场景」的证据；
        · 遮掉 HUD 后准确率**基本不变** ⇒ 模型看的是画面内容而不是 UI 数字，
          那才是较强的证据。
    无论结果如何都如实写进 report.md，不用它来撑漂亮结论。

================================================================================
本脚本不做什么
================================================================================
    · 不微调主干（明确要求冻结；也不写「可选微调」的开关，避免有人误开）。
    · 不把动作消融的改善归功于对齐层。动作信号强弱由 task-2 决定，本层只搬运。
    · 不在 src/ 里再抄一份归一化常数（见 normalize 契约断言的说明）。
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
import warnings
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))
sys.path.insert(0, str(_ROOT / "tools"))

from PIL import Image  # noqa: E402

from wm_align import (  # noqa: E402
    IMAGE_HEIGHT,
    IMAGE_WIDTH,
    LATENT_DIM,
    AlignConfig,
    AlignedWorldModel,
    ExportWrapper,
    alignment_loss,
    build_aligned_model,
)
from wm_dynamic import latent_diagnostics  # noqa: E402  只读复用诊断口径，避免两套算法
from train_wm_static import PIXEL_MEAN, PIXEL_STD  # noqa: E402  归一化契约**同源**

#: 动作列顺序，必须与 controls.csv 一致（也是 src/wm_dynamic.py 的 ACTION_DIM 契约）。
ACTION_KEYS = ["w", "a", "s", "d", "shift", "space", "super_brake", "ultimate_brake"]

#: 只对这 6 个**原子键**做探针。super_brake = shift∧space、
#: ultimate_brake = shift∧space∧s 是这三个键的确定性函数，
#: 对它们做探针只会得到「原子键探针结果的代数组合」，不是独立信息，
#: 报出来会让读者误以为模型多预测了 2 个量。
PROBE_KEYS = ["w", "a", "s", "d", "shift", "space"]

DEFAULT_CLIPS_DIR = _ROOT / "data" / "lean_clips"
DEFAULT_OUT_DIR = _ROOT / "data" / "wm_align"
DEFAULT_STATIC_CKPT = _ROOT / "data/wm_static/ckpt_last.pt"
DEFAULT_DYNAMIC_CKPT = _ROOT / "data/wm_dynamic/checkpoints/best.pt"

#: 按整段 clip 划分，理由见模块 docstring「数据与评测协议」。
ALIGN_TRAIN_CLIPS = ["clip_20261104_131750", "clip_20261104_132750",
                     "clip_20261104_211247", "clip_20261104_212247"]
ALIGN_VAL_CLIPS = ["clip_20261105_212945"]
PROBE_TEST_CLIPS = ["clip_20261105_213945"]

#: 期望的静态侧归一化常数。**这不是第二份真值**，而是防漂移哨兵：
#: 真正的值从 train_wm_static.py import，这里只断言它与记录值一致。
#: 若训练侧改了常数，本脚本会在启动时立刻失败，而不是静默用错分布训出一个
#: 看起来正常、实际全错的投影头（详见 src/wm_align.py docstring §4）。
_EXPECTED_PIXEL_MEAN = (0.2717, 0.3074, 0.3251)
_EXPECTED_PIXEL_STD = (0.2099, 0.1870, 0.1888)

#: HUD 遮罩区域（归一化坐标 x1,y1,x2,y2），用于 UI 泄漏对照实验。
#: 区域是**看着真实帧标出来的**（data/lean_clips 的 384x224 录制帧）：
#:   左上小地图 + 任务文字、顶部中央图标、右上图标条、左下聊天/状态、
#:   底部中央速度数字 + 速度/氮气条、右侧按键说明面板。
#: 刻意标得比实际 HUD 更宽：宁可多遮，也不要漏遮导致「以为没泄漏」的假阴性。
HUD_MASK_REGIONS: Tuple[Tuple[float, float, float, float], ...] = (
    (0.00, 0.00, 0.26, 0.46),
    (0.26, 0.00, 0.72, 0.20),
    (0.68, 0.00, 1.00, 0.30),
    (0.00, 0.60, 0.26, 1.00),
    (0.22, 0.70, 0.54, 1.00),
    (0.74, 0.36, 1.00, 1.00),
)

#: 遮罩填充色：取近似「画面平均亮度」的中性灰，而不是纯黑。
#: 纯黑会把大片区域变成主干从未见过的极端值，那是**引入**一个新的分布外因素，
#: 会污染「遮 UI 的影响」这个结论本身。
_MASK_FILL = (0.28, 0.30, 0.32)


# ============================================================================
# 基础工具
# ============================================================================


def select_device(allow_cpu: bool) -> torch.device:
    """挑设备。MPS 优先（用户硬要求「用 GPU 别用 CPU 硬练」）。"""
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if not allow_cpu:
        raise SystemExit(
            "[wm-align] ❌ MPS 不可用。本任务要求用 GPU（M3 上即 MPS）训练；"
            "若确实要跑 CPU，显式加 --allow-cpu。"
        )
    print("[wm-align] ⚠️  MPS 不可用，回退 CPU（--allow-cpu 已显式指定）")
    return torch.device("cpu")


def assert_normalize_contract() -> None:
    """归一化契约哨兵：import 进来的常数必须等于记录值，否则立刻炸。

    为什么需要它：`PIXEL_MEAN/STD` 是 task-1 训练侧的事实来源。若将来有人改了
    tools/train_wm_static.py 的常数（比如换了数据集重新统计），而本脚本仍按旧值
    推理，喂进静态主干的张量就是分布外的 —— 投影头照样能训出下降的 loss，
    只有下游指标会莫名其妙地差。这类错配**不报错、只掉点**，是最难排查的一类。
    """
    if tuple(PIXEL_MEAN) != _EXPECTED_PIXEL_MEAN or tuple(PIXEL_STD) != _EXPECTED_PIXEL_STD:
        raise SystemExit(
            "[wm-align] ❌ 归一化常数漂移！\n"
            f"  train_wm_static 里现在是 mean={PIXEL_MEAN} std={PIXEL_STD}\n"
            f"  本脚本记录的是     mean={_EXPECTED_PIXEL_MEAN} std={_EXPECTED_PIXEL_STD}\n"
            "若确认训练侧是刻意改的，请同步更新本脚本的记录值并重跑评测；"
            "否则说明有人误改了常数。"
        )
    print(f"[wm-align] 归一化契约 ✅ 静态侧 (x−{PIXEL_MEAN})/{PIXEL_STD}，动态侧仅 /255")


def load_frame01(path: Path, hud_mask: bool) -> np.ndarray:
    """读一帧 → [3,H,W] float32，值域 [0,1]（**不含**任何 mean/std 归一化）。

    为什么这里只做 /255：mean/std 是**静态主干专属**的，动态主干只用 /255。
    把 /255 固化成「图像通用预处理」、把 mean/std 留给 AlignedWorldModel 内部，
    两种归一化就不会在调用方被混用或重复施加。
    """
    with Image.open(path) as im:
        arr = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    if arr.shape[0] != IMAGE_HEIGHT or arr.shape[1] != IMAGE_WIDTH:
        raise ValueError(
            f"{path} 尺寸 {arr.shape[:2]} 与契约 ({IMAGE_HEIGHT},{IMAGE_WIDTH}) 不符"
        )
    if hud_mask:
        h, w = arr.shape[:2]
        for x1, y1, x2, y2 in HUD_MASK_REGIONS:
            arr[int(y1 * h):int(y2 * h), int(x1 * w):int(x2 * w), :] = _MASK_FILL
    return np.transpose(arr, (2, 0, 1)).copy()


def read_controls(csv_path: Path) -> List[Dict[str, str]]:
    """读 controls.csv。第 j 行 ⟷ frames/{j:06d}.jpg（严格对应，不做任何重排）。"""
    import csv

    with csv_path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ValueError(f"{csv_path} 没有数据行")
    return rows


def row_bits(row: Dict[str, str]) -> List[float]:
    """取一行的 8 个按键位（0/1）。空值视为 0。"""
    return [1.0 if str(row.get(k, "0")).strip() not in ("", "0", "0.0") else 0.0
            for k in ACTION_KEYS]


# ============================================================================
# 锚点收集
# ============================================================================


def collect_anchors(
    clips_dir: Path,
    clip_names: Sequence[str],
    horizon: int,
    stride: int,
    limit: int | None,
) -> List[Tuple[str, int]]:
    """收集可用的 (clip 名, t) 锚点：要求 t..t+horizon 每一帧都真实存在。

    为什么逐帧校验存在性而不信 n-horizon 的算术：数据是分批录制的，
    中间可能缺帧。缺帧时仍按 t 取下标的做法会静默读到**不连续**的画面，
    却仍然算出「很合理」的表征 —— 这是最隐蔽的数据污染。
    """
    anchors: List[Tuple[str, int]] = []
    for name in clip_names:
        clip = clips_dir / name
        if not clip.is_dir():
            print(f"[锚点] ⚠️  跳过 {name}（目录不存在）")
            continue
        frames = clip / "frames"
        rows = read_controls(clip / "controls.csv")
        n = len(rows)
        if n < horizon + 1:
            print(f"[锚点] ⚠️  跳过 {name}（仅 {n} 帧，不足 horizon+1={horizon + 1}）")
            continue
        kept = 0
        for t in range(0, n - horizon, stride):
            if all((frames / f"{t + k:06d}.jpg").exists() for k in range(horizon + 1)):
                anchors.append((name, t))
                kept += 1
                if limit is not None and len(anchors) >= limit:
                    print(f"[锚点] 已到 --limit {limit}，提前停止")
                    return anchors
        print(f"[锚点] {name}: {n} 帧 → {kept} 个锚点（stride={stride}）")
    if not anchors:
        raise RuntimeError("一个锚点都没收集到 —— 检查 clips 目录与 horizon 设置")
    return anchors


# ============================================================================
# 特征缓存
# ============================================================================


@torch.no_grad()
def build_feature_cache(
    model: AlignedWorldModel,
    anchors: Sequence[Tuple[str, int]],
    clips_dir: Path,
    horizon: int,
    hud_mask: bool,
    device: torch.device,
    batch_size: int,
    tag: str,
) -> Dict[str, torch.Tensor]:
    """跑一遍主干，把训练/评测要用的全部特征缓存下来。

    存什么（全部 float32、CPU 侧保存以省 MPS 内存）：
        z_static / z_dynamic            : t 帧两侧原始 latent [N,256]
        z_static_next / z_dynamic_next  : 两侧各自预测的 t+h latent [N,256]
        action_block                    : t..t+h−1 动作 [N, horizon*8]
        action_now / action_future      : t 与 t+h 帧的按键 [N,8]（探针标签）
        clip_id / t                     : 溯源用

    为什么把两侧 predict_next 也算进缓存：它们是「未来一致性」项的输入，
    而那一项在训练中每个 epoch 都要用。若每次重算，等于为了一个
    [N,256]→[N,256] 的 MLP 付主干前向的钱，在 16GB 机器上没有必要。
    """
    keys = ["z_static", "z_dynamic", "z_static_next", "z_dynamic_next",
            "action_block", "action_now", "action_future"]
    store: Dict[str, List[torch.Tensor]] = {k: [] for k in keys}
    clip_ids: List[int] = []
    starts: List[int] = []

    action_block_dim = model.dynamic_model.cfg.action_block_dim
    if action_block_dim != horizon * len(ACTION_KEYS):
        raise ValueError(
            f"动态主干动作块宽度 {action_block_dim} ≠ horizon({horizon})×8 —— 契约不一致"
        )

    # 按 clip 分组，避免同一个 controls.csv 被反复读取解析（每帧读一次 CSV 太浪费）。
    by_clip: Dict[str, List[int]] = {}
    for idx, (name, t) in enumerate(anchors):
        by_clip.setdefault(name, []).append(t)

    total = len(anchors)
    done = 0
    t_start = time.time()
    for clip_index, (name, t_list) in enumerate(by_clip.items()):
        clip = clips_dir / name
        frames = clip / "frames"
        rows = read_controls(clip / "controls.csv")
        bits = np.array([row_bits(r) for r in rows], dtype=np.float32)
        for cursor in range(0, len(t_list), batch_size):
            chunk = t_list[cursor:cursor + batch_size]
            images = np.stack([
                load_frame01(frames / f"{t:06d}.jpg", hud_mask) for t in chunk
            ])
            image = torch.from_numpy(images).to(device)
            blocks = np.stack([
                bits[t:t + horizon].reshape(-1) for t in chunk
            ])
            action_block = torch.from_numpy(blocks).to(device)

            z_static, z_dynamic = model.encode_backbones(image)
            z_static_next = model.static_model.predict_next(z_static)
            z_dynamic_next = model.dynamic_model.predict_next(z_dynamic, action_block)

            store["z_static"].append(z_static.cpu())
            store["z_dynamic"].append(z_dynamic.cpu())
            store["z_static_next"].append(z_static_next.cpu())
            store["z_dynamic_next"].append(z_dynamic_next.cpu())
            store["action_block"].append(action_block.cpu())
            store["action_now"].append(torch.from_numpy(bits[chunk]))
            store["action_future"].append(
                torch.from_numpy(bits[[t + horizon for t in chunk]])
            )
            clip_ids.extend([clip_index] * len(chunk))
            starts.extend(int(t) for t in chunk)

            done += len(chunk)
            if done % (batch_size * 10) < batch_size or done == total:
                elapsed = time.time() - t_start
                rate = done / elapsed if elapsed > 0 else 0.0
                eta = (total - done) / rate if rate > 0 else float("nan")
                print(f"[缓存:{tag}] {done}/{total} 帧  {rate:.1f} 帧/s  剩余约 {eta:.0f}s")

    cache: Dict[str, torch.Tensor] = {k: torch.cat(v, dim=0) for k, v in store.items()}
    cache["clip_id"] = torch.tensor(clip_ids, dtype=torch.long)
    cache["t"] = torch.tensor(starts, dtype=torch.long)
    cache["hud_mask"] = torch.tensor([1.0 if hud_mask else 0.0])
    cache["horizon"] = torch.tensor([horizon])

    if cache["z_static"].shape[1] != LATENT_DIM:
        raise ValueError(
            f"静态 latent 维度 {cache['z_static'].shape[1]} ≠ {LATENT_DIM}（契约）"
        )
    if cache["z_dynamic"].shape[1] != LATENT_DIM:
        raise ValueError(
            f"动态 latent 维度 {cache['z_dynamic'].shape[1]} ≠ {LATENT_DIM}（契约）"
        )
    print(f"[缓存:{tag}] 完成 {total} 帧，耗时 {time.time() - t_start:.1f}s")
    return cache


# ============================================================================
# 头训练
# ============================================================================


def l2norm(x: torch.Tensor) -> torch.Tensor:
    """L2 归一化。两侧主干输出均**未归一化**（契约明确说了），所以比较前必须做。"""
    return F.normalize(x.float(), dim=-1)


def train_heads(
    model: AlignedWorldModel,
    train_cache: Dict[str, torch.Tensor],
    val_cache: Dict[str, torch.Tensor] | None,
    cfg: AlignConfig,
    device: torch.device,
    epochs: int,
    batch_size: int,
    lr: float,
    weight_decay: float,
    patience: int,
    log_path: Path,
    seed: int = 0,
) -> Tuple[AlignedWorldModel, List[Dict[str, float]]]:
    """在缓存特征上训练两个投影头（主干完全不参与）。

    为什么用 AdamW 而不是 SGD：本任务的损失是「对比 + 两个分布正则」的混合，
    各项梯度尺度差别大（InfoNCE 的 logit 梯度可到 10^1，cov 项在健康时接近 0），
    Adam 的自适应缩放天然适应这种混合；SGD 需要为每一项单独调 lr，不划算。
    投影头只有 0.53M 参数、训几千步，Adam 的泛化劣势在这个规模上无从体现。

    为什么用余弦退火 + warmup 而不是固定 lr：对比学习在早期表征还随机时，
    梯度方向噪声大；warmup 让模型先小幅试探。后期退火让 InfoNCE 在
    负样本边界上稳定下来（这阶段 loss 对 lr 很敏感）。

    为什么这里要显式固定随机种子：本函数的输出数字会原样写进 report.md 作为证据。
    不固定种子时，每次重跑（哪怕代码一字未改）都会得到略有差异的曲线，
    报告里的数字就与仓库文件对不上 —— 复核的人无法判断是「复现失败」还是「报告写错」。
    投影头初始化与 batch 顺序都受种子控制，固定后同机同参数可复现。
    """
    # 固定种子（理由见 docstring 末段）。放在建优化器之前，
    # 让投影头的初始化也落在同一条确定性路径上。
    torch.manual_seed(seed)
    np.random.seed(seed)
    params = list(model.trainable_parameters())
    if not params:
        raise RuntimeError("没有可训练参数 —— 投影头没被正确注册")
    optimizer = torch.optim.AdamW(params, lr=lr, weight_decay=weight_decay)

    n_train = train_cache["z_static"].shape[0]
    if n_train < batch_size:
        # 小样本时（--limit 冒烟）把 batch 夹到样本数，否则 InfoNCE 一个 batch
        # 都没有负样本 —— 那是「正样本全对、负样本为空」，损失会恒为 0，
        # 让人误以为对齐得完美。
        print(f"[训练] 样本数 {n_train} < batch {batch_size}，batch 夹到 {n_train}")
        batch_size = max(2, n_train)

    steps_per_epoch = max(1, n_train // batch_size)
    total_steps = steps_per_epoch * epochs
    warmup = max(1, int(total_steps * 0.05))

    def lr_at(step: int) -> float:
        if step < warmup:
            return lr * float(step + 1) / float(warmup)
        progress = (step - warmup) / max(1, total_steps - warmup)
        return lr * 0.5 * (1.0 + np.cos(np.pi * min(1.0, progress)))

    # 只搬投影头真正需要的四个 latent 张量。
    # action_block **不**在这里：它已经被主干 consume 进 z_dynamic_next 了，
    # 训头阶段再带上它只会让人误以为损失里还有一项在用动作。
    needed = ("z_static", "z_dynamic", "z_static_next", "z_dynamic_next")
    train_tensors = {k: train_cache[k].to(device) for k in needed}
    val_tensors = None
    if val_cache is not None:
        val_tensors = {k: val_cache[k].to(device) for k in needed}

    history: List[Dict[str, float]] = []
    best_score = -float("inf")
    best_state: Dict[str, torch.Tensor] | None = None
    epochs_without_gain = 0
    log_handle = log_path.open("w", encoding="utf-8")
    global_step = 0
    # current_lr 先给初值：steps_per_epoch 可能因样本少而退化成 1，
    # 甚至某个 epoch 内所有 idx.numel()<2 被跳过 —— 那时循环体不执行，
    # 若在循环外引用就会 UnboundLocalError。
    current_lr = lr
    t_start = time.time()

    try:
        for epoch in range(epochs):
            model.train()  # 注意：AlignedWorldModel.train() 内部强制主干 eval
            order = torch.randperm(n_train, device=device)
            epoch_losses: List[float] = []
            epoch_diag: Dict[str, List[float]] = {}

            for step in range(steps_per_epoch):
                idx = order[step * batch_size:(step + 1) * batch_size]
                if idx.numel() < 2:
                    continue
                current_lr = lr_at(global_step)
                for group in optimizer.param_groups:
                    group["lr"] = current_lr

                u_static, u_dynamic = model.heads_from_latents(
                    train_tensors["z_static"][idx], train_tensors["z_dynamic"][idx]
                )
                u_static_next, u_dynamic_next = model.heads_from_latents(
                    train_tensors["z_static_next"][idx],
                    train_tensors["z_dynamic_next"][idx],
                )

                loss, details = alignment_loss(
                    u_static, u_dynamic, cfg,
                    u_static_next=u_static_next if cfg.future_weight > 0 else None,
                    u_dynamic_next=u_dynamic_next if cfg.future_weight > 0 else None,
                )

                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                # 梯度裁剪：对比损失的早期梯度偶尔会尖峰，裁剪比调小 lr 更不影响收敛速度。
                grad_norm = nn.utils.clip_grad_norm_(params, max_norm=5.0)
                optimizer.step()

                epoch_losses.append(details["loss"])
                for key in ("nce", "retrieval_acc", "pos_cos", "share_state",
                            "share_var", "share_cov", "static_std_min",
                            "dynamic_std_min", "static_dead_dims_lt_0.01",
                            "dynamic_dead_dims_lt_0.01"):
                    if key in details:
                        epoch_diag.setdefault(key, []).append(float(details[key]))
                global_step += 1

                if global_step % 20 == 1:
                    record = {"type": "step", "epoch": epoch, "step": global_step,
                              "lr": current_lr, "grad_norm": float(grad_norm),
                              **{k: float(v) for k, v in details.items()}}
                    log_handle.write(json.dumps(record, ensure_ascii=False) + "\n")

            train_loss = float(np.mean(epoch_losses)) if epoch_losses else float("nan")
            epoch_record: Dict[str, float] = {
                "type": "epoch", "epoch": epoch, "global_step": global_step,
                "lr": current_lr, "train_loss": train_loss,
            }
            for key, values in epoch_diag.items():
                epoch_record[f"train_{key}"] = float(np.mean(values))

            # ---- 验证：只在 val clip 上算 loss 与检索命中率 ----
            score = -train_loss  # 无 val 时的兜底选择标准
            if val_tensors is not None:
                model.eval()
                with torch.no_grad():
                    vs, vd = model.heads_from_latents(
                        val_tensors["z_static"], val_tensors["z_dynamic"]
                    )
                    vsn, vdn = model.heads_from_latents(
                        val_tensors["z_static_next"], val_tensors["z_dynamic_next"]
                    )
                    val_loss, val_details = alignment_loss(
                        vs, vd, cfg,
                        u_static_next=vsn if cfg.future_weight > 0 else None,
                        u_dynamic_next=vdn if cfg.future_weight > 0 else None,
                    )
                epoch_record["val_loss"] = float(val_loss)
                epoch_record["val_retrieval_acc"] = val_details["retrieval_acc"]
                epoch_record["val_pos_cos"] = val_details["pos_cos"]
                if "retrieval_acc_future" in val_details:
                    epoch_record["val_retrieval_acc_future"] = val_details["retrieval_acc_future"]
                # 选模型用检索命中率（它才是任务真正关心的量），loss 只作参考。
                score = float(val_details["retrieval_acc"])

            epoch_record["score"] = score
            history.append(epoch_record)
            log_handle.write(json.dumps(epoch_record, ensure_ascii=False) + "\n")
            log_handle.flush()

            print(
                f"[ep {epoch:03d}] step {global_step:5d} loss={train_loss:.4f} "
                f"nce={epoch_record.get('train_nce', float('nan')):.4f} "
                f"acc={epoch_record.get('train_retrieval_acc', float('nan')):.4f} "
                f"cos={epoch_record.get('train_pos_cos', float('nan')):+.4f} "
                f"| std_min={epoch_record.get('train_static_std_min', float('nan')):.4f}/"
                f"{epoch_record.get('train_dynamic_std_min', float('nan')):.4f} "
                + (f"| val_acc={epoch_record['val_retrieval_acc']:.4f} " if val_tensors else "")
                + f"| {time.time() - t_start:.0f}s"
            )

            if score > best_score + 1e-6:
                best_score = score
                epochs_without_gain = 0
                best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}
            else:
                epochs_without_gain += 1
                if epochs_without_gain >= patience:
                    print(f"[训练] 验证指标连续 {patience} 轮无提升，早停于 epoch {epoch}")
                    break
    finally:
        log_handle.close()

    if best_state is not None:
        model.load_state_dict(best_state)
        print(f"[训练] 已恢复到最佳轮（score={best_score:.4f}）")
    model.eval()
    return model, history


# ============================================================================
# 评测
# ============================================================================


@torch.no_grad()
def retrieval_metrics(
    u_a: torch.Tensor,
    u_b: torch.Tensor,
    tag: str,
    t_positions: torch.Tensor | None = None,
    min_gap_frames: int = 0,
) -> Dict[str, float]:
    """对称跨模型检索：A→B 与 B→A 的 top-1 / top-5 命中率。

    为什么要在**整个测试集**上算、而不是分 batch 算再平均：
        分 batch 时正样本只在本 batch 内竞争，命中率会随 batch 大小变化，
        不可比；而且 batch 小的时候随机基线 1/B 很大。
        整集算的前 5 名也更严格（N 大）。

    ── min_gap_frames：为什么必须有一个「排除时间近邻」的严格口径 ──────────
        测试集是同一段连续录制，锚点 stride=6 帧（0.4 秒）。0.4 秒内画面
        几乎不变，于是「用帧 t 的静态视图去检索同帧的动态视图」时，
        真正的答案会被 t−6、t+6 这些**几乎一样**的候选挤掉名次 ——
        这时的 top-1 既可能虚高（随便撞上一个近邻就算命中），也可能虚低
        （被近邻抢走），两种方向都让数字不可解释。
        把候选集中 |t_i − t_j| < min_gap_frames 的样本屏蔽掉（但**保留真值本身**，
        它必然满足 |Δt|=0），剩下的都是「几秒之外的不同场景」，
        这时命中才真正意味着「认出了同一画面」而不是「认出了同一时刻附近」。
        两个口径都报（宽松 + 严格），不用严格口径去替换宽松口径 —— 替换等于
        藏掉一半事实。
    """
    n = u_a.shape[0]
    a = l2norm(u_a)
    b = l2norm(u_b)
    sim = a @ b.t()
    labels = torch.arange(n, device=sim.device)

    if min_gap_frames > 0:
        if t_positions is None:
            raise ValueError("min_gap_frames>0 时必须提供 t_positions，否则无法判断时间间隔")
        # 时间戳来自 CPU 侧的缓存（缓存刻意存在 CPU 以省 MPS 内存），
        # 而 sim 在计算设备上。掩码必须与 sim 同设备才能 masked_fill，
        # 所以在这里统一搬 —— 收在函数内部，避免每个调用点各自记得搬。
        t = t_positions.to(sim.device).reshape(-1, 1)
        gap = (t - t.t()).abs()
        blocked = gap < min_gap_frames
        # 屏蔽近邻，但绝不屏蔽真值（对角线是 |Δt|=0，按定义要保留）。
        blocked.fill_diagonal_(False)
        sim = sim.masked_fill(blocked, float("-inf"))

    def _topk(matrix: torch.Tensor) -> Tuple[float, float]:
        top1 = float((matrix.argmax(dim=1) == labels).float().mean())
        k = min(5, matrix.shape[1])
        top5 = float(
            (matrix.topk(k, dim=1).indices == labels.unsqueeze(1)).any(dim=1).float().mean()
        )
        return top1, top5

    a2b_1, a2b_5 = _topk(sim)
    b2a_1, b2a_5 = _topk(sim.t())
    return {
        f"{tag}_top1": 0.5 * (a2b_1 + b2a_1),
        f"{tag}_top5": 0.5 * (a2b_5 + b2a_5),
        f"{tag}_top1_a2b": a2b_1,
        f"{tag}_top1_b2a": b2a_1,
        # 严格口径下的随机基线不再是 1/N（候选集被判掉一部分），
        # 这里保守地仍按 1/N 报，作为「下限参考」。
        f"{tag}_random_top1": 1.0 / n,
        f"{tag}_pos_cos": float((a * b).sum(dim=-1).mean()),
        f"{tag}_n": float(n),
    }


def linear_probe(
    features_train: torch.Tensor,
    labels_train: torch.Tensor,
    features_test: torch.Tensor,
    labels_test: torch.Tensor,
    tag: str,
) -> Dict[str, float]:
    """线性探针：用某一侧表征预测按键（二分类，逐键）。

    为什么用 sklearn 的 LogisticRegression 而不是自己写：
        这是**诊断工具**、不是交付模型，用成熟实现可以避免「探针本身写错」
        变成一个新的可疑变量；且它不进 CoreML、不影响交付物。
        正则强度固定 C=1.0、不调参 —— 探针调参会让「对齐前/后」的比较失去意义
        （两边用不同 C 时，差异可能来自超参而不是表征）。

    为什么用 balanced accuracy 作为主指标：
        各键正例率差别很大（录制数据里 w 约 73%、s 约 5%）。普通 accuracy
        在 w 这种高基线上会虚高，「全猜按下」就有 73%；balanced accuracy
        扣掉类别不均衡，才反映真实判别力。两个都报，但不拿普通 accuracy 讲故事。
    """
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import accuracy_score, balanced_accuracy_score
    from sklearn.preprocessing import StandardScaler

    x_train = features_train.detach().float().cpu().numpy()
    x_test = features_test.detach().float().cpu().numpy()
    y_train = labels_train.detach().cpu().numpy().astype(np.int64)
    y_test = labels_test.detach().cpu().numpy().astype(np.int64)

    # ⚠️ 必须逐维标准化，否则「对齐前 vs 对齐后」的比较是无效的。
    # 原因：对齐前的原始 latent 范数约 10.6，对齐后的共享向量是单位球向量
    # （逐维 std 约 0.06），两者尺度差近 100 倍。LogisticRegression 的 C
    # 惩罚的是权重本身，特征尺度差 100 倍 ⇒ 等效正则强度也差 100 倍，
    # 于是「哪个探针准确率高」会混进尺度效应，而不是表征质量差异。
    # 标准化后两者都在同一尺度上，C 才可比，差异才只能归因于表征本身。
    # 注意 scaler 只在训练集上 fit、在测试集上 transform（否则测试集信息泄漏）。
    scaler = StandardScaler().fit(x_train)
    x_train = scaler.transform(x_train)
    x_test = scaler.transform(x_test)

    out: Dict[str, float] = {}
    balanced_scores: List[float] = []
    accuracy_scores: List[float] = []
    for key_idx, key in enumerate(PROBE_KEYS):
        yt, ys = y_train[:, key_idx], y_test[:, key_idx]
        out[f"{tag}_{key}_pos_rate"] = float(ys.mean())
        # 单类标签（该 clip 里某键从未按下/从未松开）无法训分类器，标 NaN
        # 而不是伪造一个 0.5 —— 伪造会让宏观平均悄悄偏向中间值。
        if len(np.unique(yt)) < 2 or len(np.unique(ys)) < 2:
            out[f"{tag}_{key}_bal_acc"] = float("nan")
            out[f"{tag}_{key}_acc"] = float("nan")
            continue
        clf = LogisticRegression(max_iter=500, C=1.0)
        clf.fit(x_train, yt)
        pred = clf.predict(x_test)
        bal = float(balanced_accuracy_score(ys, pred))
        acc = float(accuracy_score(ys, pred))
        out[f"{tag}_{key}_bal_acc"] = bal
        out[f"{tag}_{key}_acc"] = acc
        balanced_scores.append(bal)
        accuracy_scores.append(acc)

    out[f"{tag}_macro_bal_acc"] = float(np.mean(balanced_scores)) if balanced_scores else float("nan")
    out[f"{tag}_macro_acc"] = float(np.mean(accuracy_scores)) if accuracy_scores else float("nan")
    out[f"{tag}_n_keys"] = float(len(balanced_scores))
    return out


@torch.no_grad()
def health_metrics(z: torch.Tensor, tag: str) -> Dict[str, float]:
    """表征健康度：复用 wm_dynamic.latent_diagnostics 的口径（不自己写第二套）。

    为什么必须复用而不是重写：task-1/task-2 的「有效秩 16.9 / 13」这些数字
    都是用这个函数算的。若本层换一套算法，读者会无法把三份报告的数字放在一起比。

    ⚠️ 但 latent_diagnostics **不返回死维数**，只返回 std_min/std_mean。
    这里补两个阈值的死维计数，不是重复造轮子，而是因为本任务两侧的阈值不同：
        · 0.05 是仓库既有口径（注释写明「std<0.05 视为塌缩」），用于**原始 latent**
          （task-1 实测 std_mean 0.57，0.05 下约 1 个数量级，合理）；
        · 0.01 才适合**单位球**表征（共享空间逐维 std 期望仅 1/√256≈0.0625，
          用 0.05 会把「偏低但仍有信息」的维度误判成死维）。
    两个都报，让读者能按自己的口径复算，而不是我们替他选一个。
    """
    diag = latent_diagnostics(z, prefix=f"{tag}_")
    zf = z.detach().float().cpu()
    std = zf.std(dim=0, unbiased=False)
    # 注意分隔符：latent_diagnostics 的键形如 "<tag>_std_mean"（prefix 自带下划线），
    # 这里必须与之保持一致，否则摘要按带下划线的名字取值会 KeyError。
    diag[f"{tag}_dead_dims_lt_0.05"] = float((std < 0.05).sum())
    diag[f"{tag}_dead_dims_lt_0.01"] = float((std < 0.01).sum())
    return {k: float(v) for k, v in diag.items()}


def evaluate_all(
    model: AlignedWorldModel,
    train_cache: Dict[str, torch.Tensor],
    test_cache: Dict[str, torch.Tensor],
    cfg: AlignConfig,
    device: torch.device,
) -> Dict[str, float]:
    """对齐前 / 对齐后 的完整对比（验收项 b、c 的全部数字来源）。

    三个表征版本，全部在 PROBE_TEST clip 上测：
        raw_static / raw_dynamic : 主干原始 latent（对齐前，只做 L2 归一化）
        ali_static / ali_dynamic : 共享空间向量（对齐后）
    """
    metrics: Dict[str, float] = {}

    def to_dev(key: str) -> torch.Tensor:
        return test_cache[key].to(device)

    with torch.no_grad():
        u_static_tr, u_dynamic_tr = model.heads_from_latents(
            train_cache["z_static"].to(device), train_cache["z_dynamic"].to(device)
        )
        u_static_te, u_dynamic_te = model.heads_from_latents(
            to_dev("z_static"), to_dev("z_dynamic")
        )

    # ---- (1) 跨模型检索：对齐前 vs 对齐后（宽松 + 严格两个口径）----
    # 严格口径用 min_gap=horizon*4（32 帧≈2.1 秒）：候选集里屏蔽掉与真值时间上
    # 过近的锚点，避免「0.4 秒内画面几乎一样」把命中率变成碰运气的近邻匹配。
    # 两个口径都报，理由见 retrieval_metrics 的 docstring。
    test_t = test_cache["t"]
    min_gap = int(test_cache["horizon"].item()) * 4
    for prefix, a, b in (
        ("retrieval_before", to_dev("z_static"), to_dev("z_dynamic")),
        ("retrieval_after", u_static_te, u_dynamic_te),
    ):
        metrics.update(retrieval_metrics(a, b, prefix))
        metrics.update(retrieval_metrics(
            a, b, f"{prefix}_strict", t_positions=test_t, min_gap_frames=min_gap
        ))
    metrics["retrieval_min_gap_frames"] = float(min_gap)

    # ---- (3) 健康度：两侧、对齐前后都要报 ----
    metrics.update(health_metrics(to_dev("z_static"), "health_before_static"))
    metrics.update(health_metrics(to_dev("z_dynamic"), "health_before_dynamic"))
    metrics.update(health_metrics(u_static_te, "health_after_static"))
    metrics.update(health_metrics(u_dynamic_te, "health_after_dynamic"))

    # ---- 对齐后的对齐损失（含未来项），与训练日志同口径 ----
    with torch.no_grad():
        u_static_next_te, u_dynamic_next_te = model.heads_from_latents(
            to_dev("z_static_next"), to_dev("z_dynamic_next")
        )
        test_loss, test_details = alignment_loss(
            u_static_te, u_dynamic_te, cfg,
            u_static_next=u_static_next_te if cfg.future_weight > 0 else None,
            u_dynamic_next=u_dynamic_next_te if cfg.future_weight > 0 else None,
        )
    metrics["test_loss"] = float(test_loss)
    for key, value in test_details.items():
        metrics[f"test_{key}"] = float(value)

    # ---- (2) 线性探针：静态表征 → 按键，对齐前 vs 对齐后 ----
    # 训练用 ALIGN_TRAIN 的缓存，测试用 PROBE_TEST（该 clip 从未参与训练）。
    for horizon_tag, cache_key in (("now", "action_now"), ("future", "action_future")):
        labels_tr = train_cache[cache_key]
        labels_te = test_cache[cache_key]
        metrics.update(linear_probe(
            train_cache["z_static"], labels_tr,
            to_dev("z_static"), labels_te,
            tag=f"probe_static_raw_{horizon_tag}",
        ))
        metrics.update(linear_probe(
            u_static_tr, labels_tr,
            u_static_te, labels_te,
            tag=f"probe_static_aligned_{horizon_tag}",
        ))
    return metrics


# ============================================================================
# CoreML 导出
# ============================================================================


def export_coreml(
    model: AlignedWorldModel,
    out_path: Path,
    device: torch.device,
) -> Dict[str, float]:
    """把两个投影头导出成一张 CoreML 图（两个输入、两个输出）。

    为什么只导出头、不导出整个组合模型：主干已经分别是 .mlmodelc，
    再打一遍等于交付 40MB+ 的重复模型，且推理时会白算一遍卷积。
    Swift 侧串联方式见下面报告里打印的说明。

    为什么用 trace 不用 script：两个投影头都是纯前馈
    （Linear → LayerNorm → GELU → Linear → LayerNorm → L2 归一化），
    没有控制流，trace 足够且更稳（script 对 F.normalize 的编译支持不如 trace 直接）。

    为什么导出后必须用 Swift 原生运行时读回：coremltools 9.0 **无法加载
    .mlmodelc**（只吃 .mlpackage），而 .mlmodelc 才是交付物。
    「编译没报错」不等于「系统能加载」。
    """
    import warnings as _warnings
    _warnings.filterwarnings("ignore")
    import coremltools as ct

    from export_wm_static import verify_compiled_with_swift, dir_size_mb

    wrapper = ExportWrapper(model).eval()

    z_s = torch.zeros(1, LATENT_DIM, device=device)
    z_d = torch.zeros(1, LATENT_DIM, device=device)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (z_s, z_d))

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="z_static", shape=(1, LATENT_DIM), dtype=np.float32),
            ct.TensorType(name="z_dynamic", shape=(1, LATENT_DIM), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="u_static", dtype=np.float32),
            ct.TensorType(name="u_dynamic", dtype=np.float32),
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        # 与 tools/export_wm_static.py 保持同一部署目标，避免两个交付物的
        # 最低系统版本要求不一致（那种不一致会在旧机器上表现为「一个能跑一个不能」）。
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.short_description = (
        "wm_align 投影头：把静态/动态世界模型的 256 维 latent 映到共享空间 "
        "(单位球)。主干不包含在本模型中，需先在 Swift 侧各自推理后串联。"
    )

    # mlpackage 在整个函数期间都保留（数值对比要用它）：coremltools 的
    # ct.models.MLModel 只吃 .mlpackage，而 .mlmodelc 要用 Swift 运行时校验。
    # 用 mkdtemp 而不是 TemporaryDirectory，是为了让 package 在 with 块外仍然
    # 可读；退出时在 finally 里清掉，避免在 models/ 里留下临时目录。
    work_dir = Path(tempfile.mkdtemp(prefix="wm_align_export_"))
    package = work_dir / "wm_align.mlpackage"
    try:
        mlmodel.save(str(package))
        print(f"[导出] mlpackage 已生成：{package}")

        if out_path.exists():
            # 覆盖前备份，防止一次失败的导出把上一版可用模型毁掉
            # （与 export_wm_static.py 的做法一致）。
            backup = out_path.with_name(out_path.name + ".bak")
            if backup.exists():
                shutil.rmtree(backup)
            shutil.move(str(out_path), str(backup))
            print(f"[导出] 已备份旧模型到 {backup}")

        out_path.parent.mkdir(parents=True, exist_ok=True)
        compile_result = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", str(package), str(out_path.parent)],
            capture_output=True,
            text=True,
        )
        if compile_result.returncode != 0:
            raise RuntimeError(
                "coremlcompiler 编译失败：\n"
                f"stdout={compile_result.stdout[:1200]}\n"
                f"stderr={compile_result.stderr[:1200]}"
            )
        # coremlcompiler 会在目标目录下生成 <name>.mlmodelc
        produced = out_path.parent / (package.stem + ".mlmodelc")
        if produced != out_path:
            if out_path.exists():
                shutil.rmtree(out_path)
            shutil.move(str(produced), str(out_path))
        print(f"[导出] mlmodelc 已生成：{out_path}")

        # ---- ① 数值一致性：PyTorch vs CoreML（用 mlpackage 读回）----
        # 判定用余弦而不是绝对误差：部署关心「方向对不对」，fp16 的尺度误差不影响下游。
        coreml_model = ct.models.MLModel(str(package))
        rng = np.random.default_rng(0)
        max_abs, min_cos = 0.0, 1.0
        for _ in range(3):
            zs = rng.standard_normal((1, LATENT_DIM)).astype(np.float32)
            zd = rng.standard_normal((1, LATENT_DIM)).astype(np.float32)
            # 必须显式搬到 device：torch.from_numpy 产出的张量固定在 CPU，
            # 而 wrapper 的投影头权重在 MPS 上，直接喂会报
            # 「Tensor for argument input is on cpu but expected on mps」。
            with torch.no_grad():
                t_s, t_d = wrapper(
                    torch.from_numpy(zs).to(device), torch.from_numpy(zd).to(device)
                )
            coreml_out = coreml_model.predict({"z_static": zs, "z_dynamic": zd})
            for name, torch_out in (("u_static", t_s), ("u_dynamic", t_d)):
                # .cpu() 不能省：MPS 张量不能直接 .numpy()
                a = torch_out.detach().float().cpu().numpy().ravel().astype(np.float64)
                b = np.asarray(coreml_out[name]).ravel().astype(np.float64)
                max_abs = max(max_abs, float(np.abs(a - b).max()))
                cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
                min_cos = min(min_cos, cos)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    if not out_path.exists():
        raise RuntimeError(f"编译结束但没找到产物 {out_path}")

    # ---- ② 编译产物能否被系统 CoreML 运行时加载（coremltools 读不了 .mlmodelc）----
    runtime = verify_compiled_with_swift(out_path)
    summary = {
        "out": str(out_path),
        "size_mb": dir_size_mb(out_path),
        "inputs": runtime["inputs"],
        "outputs": runtime["outputs"],
        "dtype": runtime["dtype"],
        "torch_vs_coreml_max_abs_diff": max_abs,
        "torch_vs_coreml_min_cosine": min_cos,
    }
    print(
        f"[导出] ✅ {out_path}  {summary['size_mb']:.3f} MB  "
        f"输入 {summary['inputs']} → 输出 {summary['outputs']}  dtype={summary['dtype']}"
    )
    print(
        f"[导出] 数值一致性：max_abs_diff={max_abs:.2e}  min_cosine={min_cos:.8f}"
    )
    print(
        "\n[导出] Swift 侧串联顺序（主干各自推理后把头接上）：\n"
        "  1) wm_static  .predict(image 归一化输入) → latent, next_latent\n"
        "  2) wm_dynamic .predict(image /255 输入, action_block[1,64]) → z_next\n"
        "  3) wm_align   .predict({z_static: static.latent,\n"
        "                          z_dynamic: dynamic.latent}) → u_static, u_dynamic\n"
        "  ★ 两侧归一化不同：static 用 (x−PIXEL_MEAN)/PIXEL_STD，dynamic 只用 x/255。\n"
        "  ★ u_static / u_dynamic 已在单位球上，点积即为余弦相似度。"
    )
    return summary


# ============================================================================
# 入口
# ============================================================================


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="训练静态/动态世界模型的对齐层（冻结主干，只训投影头）"
    )
    parser.add_argument("--clips-dir", type=str, default=str(DEFAULT_CLIPS_DIR))
    parser.add_argument("--out-dir", type=str, default=str(DEFAULT_OUT_DIR))
    parser.add_argument("--static-ckpt", type=str, default=str(DEFAULT_STATIC_CKPT))
    parser.add_argument("--dynamic-ckpt", type=str, default=str(DEFAULT_DYNAMIC_CKPT))
    parser.add_argument("--epochs", type=int, default=300)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--patience", type=int, default=50)
    parser.add_argument("--stride", type=int, default=6,
                        help="锚点抽样间隔（帧）。太小会让相邻帧泄漏，指标虚高")
    parser.add_argument("--limit", type=int, default=None,
                        help="每个数据集最多取多少锚点（冒烟用）")
    parser.add_argument("--future-weight", type=float, default=0.5,
                        help="未来一致性项权重；0 = 消融掉该项")
    parser.add_argument("--temperature", type=float, default=0.10)
    parser.add_argument("--hud-mask", action="store_true",
                        help="把 HUD 区域涂成中性灰（UI 泄漏对照实验）")
    parser.add_argument("--reuse-cache", action="store_true",
                        help="复用已保存的特征缓存（只重训头，用于消融）")
    parser.add_argument("--cache-dir", type=str, default=None,
                        help="缓存目录；默认 <out-dir>/cache")
    parser.add_argument("--export-only", action="store_true",
                        help="跳过训练，直接从已保存的投影头权重导出 CoreML")
    parser.add_argument("--export-out", type=str,
                        default=str(_ROOT / "models/wm_align.mlmodelc"))
    parser.add_argument("--allow-cpu", action="store_true")
    parser.add_argument("--tag", type=str, default=None,
                        help="本次运行的标签（用于缓存/日志文件名；"
                             "不指定时正式跑用 full、--limit 冒烟用 smoke）")
    parser.add_argument("--seed", type=int, default=0,
                        help="随机种子。默认 0 使训练曲线可复现 —— 报告里的数字"
                             "必须能从仓库文件复算，随机种子不固定就会对不上")
    return parser


def main(argv=None) -> int:
    warnings.filterwarnings("ignore")
    args = build_parser().parse_args(argv)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = Path(args.cache_dir) if args.cache_dir else out_dir / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    # tag 决定证据文件名（metrics_<tag>.json / train_log_<tag>.jsonl / heads_<tag>.pt）。
    # ⚠️ 冒烟必须落在独立 tag 上，不能复用 "full"：否则一次 `--limit 32` 的冒烟
    # 会覆盖正式训练的 metrics_full.json / train_log_full.jsonl / heads_full.pt，
    # 而它们正是 report.md 引用的证据 —— 覆盖后报告里的数字与仓库文件对不上，
    # 且这种错位不会报错，只会在复核时被当成「报告造假」。
    # （这条是实测踩到的：一次回归冒烟就把正式证据换成了 2 epoch / limit=32 的数据。）
    if args.tag:
        tag = args.tag
    elif args.limit:
        tag = "smoke" + ("_hudmask" if args.hud_mask else "")
    else:
        tag = "hudmask" if args.hud_mask else "full"
    if args.limit:
        print(f"[提示] --limit {args.limit} 为冒烟模式，证据写入 tag={tag}（不覆盖正式证据）")

    print("=" * 78)
    print("wm_align — 冻结主干，训练对齐层投影头")
    print("=" * 78)

    assert_normalize_contract()
    device = select_device(args.allow_cpu)
    print(f"[设备] {device}")

    # 种子必须在**构建模型之前**固定：投影头的权重初始化发生在
    # build_aligned_model() 里，若只在 train_heads() 内部设种子，
    # 初始化已经用掉了不确定的 RNG 状态，重跑仍会得到不同曲线。
    # 报告里的数字要能从仓库文件复算，这一条是前提。
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    print(f"[随机种子] {args.seed}（使训练曲线可复现）")

    cfg = AlignConfig(
        # 常数从 train_wm_static.py 同源导入，不在这里硬抄（见模块 docstring）。
        static_pixel_mean=tuple(PIXEL_MEAN),
        static_pixel_std=tuple(PIXEL_STD),
        temperature=args.temperature,
        future_weight=args.future_weight,
    )
    cfg.validate()

    # ---- 导出模式：不需要重建主干以外的任何东西 ----
    if args.export_only:
        weight_path = out_dir / f"heads_{tag}.pt"
        if not weight_path.exists():
            raise SystemExit(
                f"--export-only 需要 {weight_path}，但它不存在。\n"
                f"先跑正式训练（不加 --limit），或显式指定 --tag 指向已有的权重。"
            )
        model = build_aligned_model(cfg, args.static_ckpt, args.dynamic_ckpt, device)
        saved = torch.load(weight_path, map_location=device, weights_only=False)
        model.static_head.load_state_dict(saved["static_head"])
        model.dynamic_head.load_state_dict(saved["dynamic_head"])
        model.eval()
        summary = export_coreml(model, Path(args.export_out), device)
        (out_dir / "export_summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return 0

    from wm_dynamic import WMConfig
    dynamic_cfg = WMConfig(**{
        k: tuple(v) if isinstance(v, list) else v
        for k, v in torch.load(args.dynamic_ckpt, map_location="cpu",
                               weights_only=False)["config"].items()
    })
    horizon = dynamic_cfg.horizon
    print(f"[配置] horizon={horizon} 动作块宽度={dynamic_cfg.action_block_dim} "
          f"stride={args.stride} limit={args.limit}")

    # ---- 锚点 ----
    train_anchors = collect_anchors(
        Path(args.clips_dir), ALIGN_TRAIN_CLIPS, horizon, args.stride, args.limit
    )
    val_anchors = collect_anchors(
        Path(args.clips_dir), ALIGN_VAL_CLIPS, horizon, args.stride, args.limit
    )
    test_anchors = collect_anchors(
        Path(args.clips_dir), PROBE_TEST_CLIPS, horizon, args.stride, args.limit
    )
    print(f"[数据] 训练 {len(train_anchors)} / 验证 {len(val_anchors)} / "
          f"测试 {len(test_anchors)} 个锚点")

    model = build_aligned_model(cfg, args.static_ckpt, args.dynamic_ckpt, device)

    # ---- 特征缓存（可复用）----
    cache_paths = {name: cache_dir / f"{tag}_{name}.pt"
                   for name in ("train", "val", "test")}
    anchor_sets = {"train": train_anchors, "val": val_anchors, "test": test_anchors}
    caches: Dict[str, Dict[str, torch.Tensor]] = {}
    for name, path in cache_paths.items():
        if args.reuse_cache and path.exists():
            caches[name] = torch.load(path, map_location="cpu", weights_only=False)
            print(f"[缓存:{name}] 复用 {path}（{caches[name]['z_static'].shape[0]} 个锚点）")
            continue
        caches[name] = build_feature_cache(
            model, anchor_sets[name], Path(args.clips_dir), horizon,
            args.hud_mask, device, batch_size=32, tag=f"{name}/{tag}",
        )
        torch.save(caches[name], path)
        print(f"[缓存:{name}] 已保存 {path}")

    # ---- 训练 ----
    log_path = out_dir / f"train_log_{tag}.jsonl"
    model, history = train_heads(
        model, caches["train"], caches["val"], cfg, device,
        epochs=args.epochs, batch_size=args.batch_size, lr=args.lr,
        weight_decay=args.weight_decay, patience=args.patience, log_path=log_path,
        seed=args.seed,
    )
    print(f"[训练] 日志 {log_path}")

    # ---- 评测（对齐前 vs 对齐后）----
    metrics = evaluate_all(model, caches["train"], caches["test"], cfg, device)
    metrics["hud_mask"] = float(args.hud_mask)
    metrics["future_weight"] = float(args.future_weight)
    metrics["stride"] = float(args.stride)
    metrics["limit"] = float(args.limit or 0)
    metrics["n_train"] = float(caches["train"]["z_static"].shape[0])
    metrics["n_test"] = float(caches["test"]["z_static"].shape[0])
    metrics["epochs_run"] = float(len(history))

    metrics_path = out_dir / f"metrics_{tag}.json"
    metrics_path.write_text(json.dumps(metrics, ensure_ascii=False, indent=2),
                            encoding="utf-8")
    print(f"[评测] 指标已写入 {metrics_path}")

    # ---- 保存头权重 ----
    # 为什么文件名带 tag、且 --limit 时不写规范名 heads.pt：
    # 冒烟产出的是「只训了几十步」的半成品，若它覆盖了 heads.pt，
    # 之后一次 --export-only 就会把这个半成品导出成交付物，
    # 而交付物看起来完全正常（形状对、能加载）—— 这是最难发现的一类事故。
    payload = {
        "static_head": model.static_head.state_dict(),
        "dynamic_head": model.dynamic_head.state_dict(),
        "cfg": {
            "static_pixel_mean": cfg.static_pixel_mean,
            "static_pixel_std": cfg.static_pixel_std,
            "latent_dim": cfg.latent_dim,
            "hidden": cfg.hidden,
            "proj_dim": cfg.proj_dim,
            "temperature": cfg.temperature,
            "future_weight": cfg.future_weight,
            "var_weight": cfg.var_weight,
            "cov_weight": cfg.cov_weight,
            "var_gamma": cfg.var_gamma,
        },
        "metrics": metrics,
    }
    heads_path = out_dir / f"heads_{tag}.pt"
    torch.save(payload, heads_path)
    print(f"[保存] 投影头权重 {heads_path}")
    # 规范名 heads.pt / models/wm_align.mlmodelc 只由正式训练（tag=full 且无 --limit）写入。
    # 否则一次消融（例如 --tag abl_fw0 --future-weight 0）会把交付物覆盖成
    # 「为做对照而刻意关掉某一项」的模型 —— 而那个模型形状完全正常、能加载、能出数，
    # 事后极难发现。这是本脚本里唯一一处「宁可多写一行判断」的防呆。
    is_canonical = (tag == "full" and not args.limit)
    if is_canonical:
        torch.save(payload, out_dir / "heads.pt")
        print(f"[保存] 规范名副本 {out_dir / 'heads.pt'}（正式训练产物）")

    # ---- 结论摘要 ----
    print("\n" + "=" * 78)
    print("对齐前 vs 对齐后（PROBE_TEST clip，从未参与训练）")
    print("=" * 78)
    print(f"跨模型检索 top-1  对齐前 {metrics['retrieval_before_top1']:.4f}  →  "
          f"对齐后 {metrics['retrieval_after_top1']:.4f}   "
          f"(随机 {metrics['retrieval_before_random_top1']:.5f})")
    print(f"跨模型检索 top-5  对齐前 {metrics['retrieval_before_top5']:.4f}  →  "
          f"对齐后 {metrics['retrieval_after_top5']:.4f}")
    print(f"正样本对余弦      对齐前 {metrics['retrieval_before_pos_cos']:+.4f}  →  "
          f"对齐后 {metrics['retrieval_after_pos_cos']:+.4f}")
    for horizon_tag, label in (("now", "当前帧按键"), ("future", "t+h 帧按键")):
        before = metrics[f"probe_static_raw_{horizon_tag}_macro_bal_acc"]
        after = metrics[f"probe_static_aligned_{horizon_tag}_macro_bal_acc"]
        print(f"线性探针({label}) 对齐前 {before:.4f}  →  对齐后 {after:.4f}")
    print(f"静态侧有效秩      对齐前 {metrics['health_before_static_effective_rank']:.2f}"
          f"  →  对齐后 {metrics['health_after_static_effective_rank']:.2f}"
          f"  (batch 上限 {metrics['health_after_static_batch']:.0f})")
    print(f"动态侧有效秩      对齐前 {metrics['health_before_dynamic_effective_rank']:.2f}"
          f"  →  对齐后 {metrics['health_after_dynamic_effective_rank']:.2f}")
    print(f"死维(<0.01)       静态 {metrics['health_after_static_dead_dims_lt_0.01']:.0f}/256  "
          f"动态 {metrics['health_after_dynamic_dead_dims_lt_0.01']:.0f}/256")

    # 只让正式训练（tag=full 且无 --limit）写交付物。消融跑（--tag abl_* / hudmask）
    # 若也导出，会用一个「刻意关掉某项或遮掉 UI」的模型覆盖 models/wm_align.mlmodelc，
    # 而它形状正常、能加载、能出数，事后极难发现。
    if args.export_out and is_canonical:
        print("\n[导出] 开始导出 CoreML")
        export_summary = export_coreml(model, Path(args.export_out), device)
        (out_dir / "export_summary.json").write_text(
            json.dumps(export_summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    elif args.export_out:
        print(f"\n[导出] 跳过 CoreML 导出（tag={tag}，非正式训练产物，避免覆盖交付物）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
