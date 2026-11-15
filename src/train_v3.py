#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""train_v3.py — V3 离散按键模型训练入口

设计前提（对应用户需求「模型直接输出标签，不要油门」）：
    V3 的监督目标就是**原始按键**（w/a/s/d/shift/space）导出的 8 个头，
    数据流是 `controls.csv(纯按键) → dataset_v3 → 8 头 target → V3Loss`。
    本文件里**不存在任何连续量（steer/throttle/brake）到按键的转换**。

与 train_v2.py 的关系：
    · 复用其 `build_adamw_optimizer`（BN/bias 不做 weight decay）与
      `CosineWithWarmup`（warmup + cosine）——本项目既有实现，不另造一套。
    · 不复用其数据管线：V2 读连续量，V3 读纯按键，两者的 target 语义不同。

⚠️ CCM 在训练中**默认关闭**（实测依据）：
    `V3Model.forward` 返回的键是 ['brake','confidence','handbrake','horizontal',
    'intent','risk','super_brake','ultimate','vertical'] —— **不含 ccm**。
    而 `V3Loss` 只有在同时传入 `ccm_pred` 与 `ccm_target` 时才计算 CCM 项，
    否则静默跳过（不报错、不留痕迹）。所以这里必须显式 `enable_ccm=False`，
    让「CCM 未启用」成为一个**明示的决定**，而不是一个被悄悄跳过的配置。
    启用条件：模型 forward 需要先接出 ccm 输出（训练期专用分支）。

⚠️ 模型选择禁用总准确率（03-output-head.md §5 实测）：
    一个「永远输出 W」的平凡解总准确率就有 80.8%，但 S 类一帧都不会。
    2026-11-08 之前本脚本只按「vertical/horizontal 两个方向头的 macro recall」
    选最佳 epoch，实测 best_epoch=1（15 轮里第 1 轮就"到顶"），而部署后暴露的
    是**修饰键头乱触发**（多余地踩 S/Shift/Space）—— 方向头指标对此完全不敏感。
    现改为综合指标 select（同时看方向头与最终六键的误刹车/漏刹车/Space 假阳性）：
        select = 0.5 * macro_recall + 0.5 * brake_quality
        brake_quality = (S纵向平衡acc + Space键平衡acc) / 2
    依据与公式细节见 `evaluate()` 的 docstring；公式同时写入 train_v3_summary.json。
    日志逐轮打印方向头逐类召回、六键 S 假阳性/漏刹车/Space 假阳性。

⚠️ 验证集划分按**方向类分布分层**选 clip（见 make_stratified_train_val_split）：
    11 个有效 clip 的 W/NONE/S 分布极不均衡（单 clip 可能整段没有某类），
    随机抽 clip 会抽到偏斜片段 → 验证指标剧烈摆动。现保证验证集每类样本
    ≥ MIN_VAL_CLASS_SUPPORT(200)，做不到时显式告警并给出实际数。

用法：
    # 先看数据分布（决定类权重，不必手工填）
    python3 src/dataset_v3.py --stats data/raw_clips

    # 训练
    python3 src/train_v3.py --clips data/raw_clips --epochs 30 --batch-size 8

    # 只跑通流程（2 个 epoch、小 batch）
    python3 src/train_v3.py --clips data/raw_clips --epochs 2 --batch-size 2 --limit 30
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import random
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import torch
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))
sys.path.insert(0, str(_ROOT))

from dataset_v3 import (  # noqa: E402
    ATOMIC_KEYS,
    V3KeyDataset,
    _bit,
    horizontal_from_keys,
    make_train_val_split,
    modifier_valid_from_rows,
    vertical_from_keys,
)
from model_v3 import V3Loss, build_v3_model  # noqa: E402
from npu_compat import device_available, is_npu_available  # noqa: E402

# 复用 train_mono 的既有实现（只读导入，不修改原文件）
from src.train_mono import CosineWithWarmup, build_adamw_optimizer  # noqa: E402

#: 默认 checkpoint 目录：**新目录**，绝不覆盖 m9_mono / m9_v2 等现有目录
DEFAULT_CKPT_DIR = _ROOT / "checkpoints" / "v3"


# ----------------------------------------------------------------------------
# 设备 / AMP
# ----------------------------------------------------------------------------

def resolve_device(device: str) -> str:
    """auto → 优先 Ascend NPU，其次 Apple MPS（仅 macOS），再次 cuda，最后 cpu。

    为什么 NPU 排在 MPS 之前：NPU 只可能出现在装好 torch_npu 的训练机；而
    MPS 判断必须加 is_available()（而非只看平台），否则在 Linux 上会因
    torch.backends.mps 模块存在而误选不可用的 MPS，训练直接崩在第一个张量。
    """
    if device != "auto":
        return device
    if is_npu_available():
        return "npu"
    if sys.platform == "darwin" and torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def resolve_amp(use_amp: bool, device: str) -> bool:
    """AMP 开关裁决。

    CPU 无 AMP；MPS 上 GradScaler 会因 inf 梯度导致 optimizer.step 被静默跳过、
    权重冻结（train_mono.py 已踩过该坑），故 MPS 一律纯 fp32。
    """
    if device in ("cpu", "mps"):
        return False
    return use_amp


# ----------------------------------------------------------------------------
# 类权重（必须由真实数据统计得到，不允许拍脑袋）
# ----------------------------------------------------------------------------

#: 统计时要求验证集里每个方向类至少有的样本数（见 make_stratified_train_val_split）。
#: 为什么是 200：500 样本时一个类的召回率标准误约 sqrt(0.5*0.5/500)≈2.2%，
#: 200 样本约 3.5%。低于 200 时单折召回率的抖动会盖过模型之间的真实差距，
#: 「best_epoch=1」正是这种噪声导致的假象（15 轮里第 1 轮就"到顶"）。
MIN_VAL_CLASS_SUPPORT = 200


def _modifier_valid_timeline(dataset: V3KeyDataset, clip: Path) -> Sequence[bool]:
    """取某 clip 逐帧的「修饰键标签是否可信」布尔序列（False = 卡键段）。

    为什么统计阶段要自己算一遍并回写缓存：
        `__getitem__` 是**惰性**计算 `_modifier_valid_cache` 的（只有真取过样本
        的 clip 才有缓存）。类权重统计发生在建 loader 之前，此时缓存必然是空的，
        直接读会拿到空列表 → 静默把卡键帧当成有效正例（正是本次要修的缺陷）。
        这里调用 dataset_v3 的同一个纯函数 `modifier_valid_from_rows` 并写回缓存，
        使「统计口径」与「loss 实际使用的 mask」来自**同一份判定**。
    """
    # 对队友正在改的字段一律用 getattr 防御：`_modifier_valid_cache` 若被重命名，
    # 这里退化为「每次重算」而不是 AttributeError 中断训练。
    cache = getattr(dataset, "_modifier_valid_cache", None)
    if cache is not None:
        cached = cache.get(clip)
        if cached is not None:
            return cached
    rows = dataset._rows_cache[clip]
    valid = modifier_valid_from_rows(rows)
    if cache is not None:
        cache[clip] = valid
    return valid


def compute_class_stats(dataset: V3KeyDataset,
                        samples: Optional[Sequence[Tuple[Path, int]]] = None,
                        ) -> Dict[str, object]:
    """统计各头正负样本数与方向类别分布。

    为什么必须有这一步：`03-output-head.md` §5 实测「永远输出 W」准确率 80.8%，
    但 S 类一帧不输出。类权重与 pos_weight 必须按真实比例算，否则模型会坍缩到
    多数类，而总准确率看起来还很高。

    ⚠️ 2026-11-08 修复两个口径缺陷（本次任务 1）：

    【缺陷 1】pos_weight 的分子分母必须与 BCE 实际见到的样本一致。
        `V3Loss._masked_bce`（model_v3.py:1249-1266）对 handbrake/brake/
        super_brake/ultimate **四个头都按 `modifier_valid` 逐帧过滤**：
        mask=0 的帧不进梯度，也不进分母。旧实现却对全量 `base.index` 统计，
        把 1739 帧卡键段的 shift/space 当成有效正例算进了比例 →
        实测 super_brake=19.32 / ultimate=58.42，而按「训练子集 + 有效帧」
        应为 59.37 / 258.32（正例 799 / 186，分母 48,234）。
        pos_weight 少算 3~4 倍 → 正例梯度被大幅低估，模型倾向「永远输出 0」。

    【缺陷 2】组合键必须从原子键重新派生，不能读 CSV 的组合列。
        `super_brake`/`ultimate_brake` 是录制器**冗余存储**的派生列
        （dataset_v3.validate_row 只校验一致性）。data-clean 正在把 ultimate
        改成派生目标，届时该列可能不再存在或语义改变。而 BCE 的真实目标是
        `_bit(row,'shift') ∧ _bit(row,'space')`（× mvalid），所以统计必须按
        同一公式派生 —— 这样统计值与监督值**构造性一致**，不依赖列是否存在。

    Args:
        dataset: V3KeyDataset（提供 `_rows_cache`）。
        samples: 要统计的 (clip, frame_idx) 序列；None = 全量 `dataset.index`。
                 训练侧必须传入**排除验证集后**的训练样本，否则验证标签会参与
                 类权重计算（缺陷 2：验证集不再独立）。

    Returns:
        dict:
            vertical[3] / horizontal[3]：方向类别样本数（**全部**帧，不受 mask 影响）
            positives：四个修饰键头在**有效帧**上的正例数
            total：参与统计的帧数
            modifier_valid_total：修饰键标签可信的帧数（= BCE 的样本数）
            masked：被卡键 mask 屏蔽的帧数
    """
    if samples is None:
        samples = dataset.index

    vert = [0, 0, 0]
    horiz = [0, 0, 0]
    # 键名与 V3Loss 的 4 个 pos_weight buffer 一一对应
    positives = {"handbrake": 0, "brake": 0, "super_brake": 0, "ultimate": 0}
    total = 0
    valid_total = 0
    masked = 0

    # 逐 clip 取掩码序列：一次算、全部帧复用（逐帧重算会是 O(N²)）
    valid_by_clip: Dict[Path, Sequence[bool]] = {}

    for clip, frame_idx in samples:
        rows = dataset._rows_cache[clip]
        row = rows[frame_idx]
        w, a, s, d = (_bit(row, k) for k in ("w", "a", "s", "d"))

        # 方向头不受 mask 影响：卡键只坏 shift/space，玩家当时是否给油/打方向仍可信
        vert[vertical_from_keys(w, s)] += 1
        horiz[horizontal_from_keys(a, d)] += 1
        total += 1

        valid = valid_by_clip.get(clip)
        if valid is None:
            valid = _modifier_valid_timeline(dataset, clip)
            valid_by_clip[clip] = valid

        # 用 .get() 而非硬索引：保持与本文件其它地方一致的防御式读取习惯
        if not valid[frame_idx]:
            masked += 1
            continue
        valid_total += 1

        shift, space = _bit(row, "shift"), _bit(row, "space")
        positives["handbrake"] += shift
        positives["brake"] += space
        # 组合键从原子键派生（与 dataset_v3.__getitem__ 的监督目标同公式）
        super_brake = shift and space
        positives["super_brake"] += int(super_brake)
        positives["ultimate"] += int(super_brake and s)

    if total == 0:
        raise RuntimeError("数据集为空，无法统计类权重")

    return {"vertical": vert, "horizontal": horiz,
            "positives": positives, "total": total,
            "modifier_valid_total": valid_total, "masked": masked}


def _clip_vertical_counts(dataset: V3KeyDataset,
                          clips: Sequence[Path]) -> Dict[Path, List[int]]:
    """统计每个 clip 的 vertical 三类样本数 [W, NONE, S]。"""
    counts = {c: [0, 0, 0] for c in clips}
    for clip, frame_idx in dataset.index:
        if clip not in counts:
            continue
        row = dataset._rows_cache[clip][frame_idx]
        counts[clip][vertical_from_keys(_bit(row, "w"), _bit(row, "s"))] += 1
    return counts


def make_stratified_train_val_split(
    dataset: V3KeyDataset,
    val_ratio: float = 0.2,
    seed: int = 42,
    fixed_val_clips: Optional[List[str]] = None,
) -> Tuple[torch.utils.data.Dataset, torch.utils.data.Dataset, List[Path]]:
    """按 clip 边界划分训练/验证集，并**按方向头的类分布选出验证 clip**。

    为什么不能纯随机抽 clip（本次任务的关键修正）：
        11 个有效 clip 的方向类分布极不均衡 —— 实测单 clip 就可能整段没有某类：
            clip_20261104_132750  NONE 仅 7 个
            clip_20261107_110446  S 正例 0 个、NONE 仅 39 个
            clip_20261107_115514  NONE 仅 124 个
        随机抽 1~2 个 clip 做验证时，很容易抽到「某类样本≈0」的偏斜片段：
        该类的 macro recall 要么退化成 `-1.0`（support=0 不参与），要么由个位数
        样本决定 —— 验证指标随种子剧烈摆动。旧实现在 seed=42、val_ratio=0.1 时
        只留 1 个 clip（6889 样本），于是 `best_epoch=1`（15 轮里第 1 轮就"到顶"），
        选出来的其实是噪声的最大值，而不是更好的模型。

    选择规则（确定性，不依赖随机流的运气）：
        1. 枚举所有大小为 `n_val` 的 clip 组合（11 选 2 = 55 组，可全枚举）；
        2. 先按「验证集 W/NONE/S 三类的最小样本数 ≥ MIN_VAL_CLASS_SUPPORT」
           过滤 —— 保证每一类的召回率都有统计意义；
        3. 在通过的组合里，选验证样本数最接近 `total × val_ratio` 的一组
           （避免验证集过小导致方差大，或过大导致训练样本不足）；
        4. 同分时取三类最小样本数更大者（更均衡），仍同分则按 clip 名排序，
           保证同一 seed / 同一数据下结果完全可复现。
        若没有任何组合能通过第 2 步（clip 数太少或数据太偏斜），**不静默降级**：
        打印告警并给出实际各类样本数，然后退回「最小类样本数最大」的组合。

    为什么 n_val 由 val_ratio 决定而不是固定值：
        训练样本量是主要瓶颈（56,862 总样本）。val_ratio=0.2 → 约 2 个 clip、
        11.4k 验证样本、训练 45.5k；若取 0.3 则训练降到 37.4k（-18%），
        会加剧过拟合，与「扩验证集以便发现过拟合」的目的相反。

    Args:
        dataset: V3KeyDataset
        val_ratio: 验证集目标占比（按样本数，实际取最接近的整数个 clip）
        seed: 未参与 clip 选择（选择是确定性的），保留以保持调用签名与
              `make_train_val_split` 一致、便于调用方无差别切换。

    Returns:
        (train_subset, val_subset, val_clips)
    """
    clip_counts: Dict[Path, int] = {}
    for clip, _ in dataset.index:
        clip_counts[clip] = clip_counts.get(clip, 0) + 1
    active_clips = sorted(c for c, n in clip_counts.items() if n > 0)
    n_active = len(active_clips)

    if n_active < 4:
        # 与 dataset_v3.make_train_val_split 的策略一致：clip 太少时按 clip 切
        # 无法保证验证集覆盖各类，退化按帧划分并由其日志显式标注不可信。
        print(f"[V3Train] ⚠ clip 数 {n_active} < 4，无法按 clip 分层划分，"
              "退化为按帧划分（验证指标不可信，仅用于跑通流程）")
        train_ds, val_ds = make_train_val_split(dataset, val_ratio=val_ratio, seed=seed)
        return train_ds, val_ds, []

    total_samples = sum(clip_counts.values())
    target_val = total_samples * val_ratio
    # 至少 1 个、至多 n_active-1 个 clip 做验证（必须给训练集留下 clip）
    n_val = max(1, min(int(round(n_active * val_ratio)), n_active - 1))

    vertical_by_clip = _clip_vertical_counts(dataset, active_clips)

    if fixed_val_clips:
        # ── 显式指定验证 clip（--val-clips）──
        # 用途：需要一个「与旧模型可直接比较」的固定留出集。
        # 本项目线上模型 C 是以 clip_20261107_110525 为验证集训练出来的，
        # 因此只有新模型同样留出 110525 时，两者在该片段上的指标才可比
        # （双方都没在这段上训练过）。自动分层无法保证这一点。
        want = [str(x) for x in fixed_val_clips]
        by_name = {c.name: c for c in active_clips}
        missing = [n for n in want if n not in by_name]
        if missing:
            raise ValueError(
                f"--val-clips 指定的 clip 不在数据集中: {missing}；"
                f"可用 clip: {sorted(by_name)}")
        chosen_clips = tuple(by_name[n] for n in want)
        if len(chosen_clips) >= n_active:
            raise ValueError(
                f"--val-clips 指定了 {len(chosen_clips)} 个 clip，"
                f"但活跃 clip 只有 {n_active} 个，训练集将为空")
        cls_counts = [sum(vertical_by_clip[c][k] for c in chosen_clips) for k in range(3)]
        chosen = {
            "clips": chosen_clips,
            "class_counts": cls_counts,
            "total": sum(cls_counts),
            "min_support": min(cls_counts),
        }
        print(f"[V3Train] 使用 --val-clips 指定验证集: {[c.name for c in chosen_clips]}"
              f"（跳过自动分层选择）")
    else:
        candidates = []
        for combo in itertools.combinations(active_clips, n_val):
            cls_counts = [sum(vertical_by_clip[c][k] for c in combo) for k in range(3)]
            combo_total = sum(cls_counts)
            min_support = min(cls_counts)
            candidates.append({
                "clips": combo,
                "class_counts": cls_counts,
                "total": combo_total,
                "min_support": min_support,
                # 一轮排序键：先满足最小类样本下限，再贴近目标验证量，再更均衡
                "key": (min_support < MIN_VAL_CLASS_SUPPORT, abs(combo_total - target_val),
                        -min_support, tuple(c.name for c in combo)),
            })

        candidates.sort(key=lambda x: x["key"])
        chosen = candidates[0]

    if chosen["min_support"] < MIN_VAL_CLASS_SUPPORT:
        # 不静默降级：明确告知「验证集某类样本不足」，并给出实际数字，
        # 让读日志的人知道该折的该类召回率不可信（而不是以为它没问题）。
        print("=" * 72)
        print(f"[V3Train] 🚨 验证集分层不达标：仅 {n_active} 个 clip 时，"
              f"没有任何组合能让 W/NONE/S 每类都 ≥ {MIN_VAL_CLASS_SUPPORT} 个样本。")
        print(f"           选中组合 {[c.name for c in chosen['clips']]} 实际为 "
              f"W/NONE/S={chosen['class_counts']}。")
        print("           其中样本数 < "
              f"{MIN_VAL_CLASS_SUPPORT} 的类别，其验证召回率方差很大，")
        print("           不能作为模型选择的唯一依据；泛化估计请以 loo_cv.py 的留一交叉验证为准。")
        print("=" * 72)

    val_clip_set = set(chosen["clips"])
    train_idx = [i for i, (clip, _) in enumerate(dataset.index) if clip not in val_clip_set]
    val_idx = [i for i, (clip, _) in enumerate(dataset.index) if clip in val_clip_set]
    if not val_idx or not train_idx:  # 纯兜底，理论上不可达
        raise RuntimeError(
            f"分层划分产生空集合：train={len(train_idx)} val={len(val_idx)}")

    print(f"[V3Train] 分层划分: train={len(train_idx)} val={len(val_idx)} "
          f"({len(val_idx) / total_samples:.1%})")
    print(f"[V3Train] 验证集 {len(val_clip_set)}/{n_active} 个 clip: "
          f"{[c.name for c in chosen['clips']]}")
    print(f"[V3Train] 验证集类分布 W/NONE/S={chosen['class_counts']} "
          f"（每类下限要求 {MIN_VAL_CLASS_SUPPORT}）")
    train_clips = [c.name for c in active_clips if c not in val_clip_set]
    print(f"[V3Train] 训练集 {len(train_clips)} 个 clip: {train_clips}")

    return (torch.utils.data.Subset(dataset, train_idx),
            torch.utils.data.Subset(dataset, val_idx),
            list(chosen["clips"]))


def _inverse_freq_weights(counts: List[int], mean_normalize: bool = True) -> torch.Tensor:
    """逆频率类权重（Softmax 用途），可归一化到均值 1。

    为什么归一化到均值 1：不归一化会让总损失量纲随类别数放大，
    把 λ 的实际效果改变（03 文档 §3.5 的权重敏感性实测用的是归一化口径）。
    """
    raw = torch.tensor([total := sum(counts)] * len(counts), dtype=torch.float32)
    raw = raw / torch.tensor([max(c, 1) for c in counts], dtype=torch.float32)
    if mean_normalize:
        raw = raw / raw.mean()
    return raw


def _sqrt_inverse_freq_weights(counts: List[int], mean_normalize: bool = True) -> torch.Tensor:
    """**平方根**逆频率类权重（Softmax 用途），可归一化到均值 1。

    为什么不用纯逆频率（`_inverse_freq_weights`）：
        实测 56,862 样本里 vertical 分布 W/NONE/S = 48637/3859/4366
        （W 占 85.5%）。纯逆频率给出的权重是 [0.121, 1.528, 1.351] ——
        「真值 W 判成 NONE」的代价只有「判对 W」的 **12.6 倍**，
        但 W 类本身的正确与否在损失里几乎无足轻重（权重 0.121，
        是 NONE 的 1/12.6）。实测后果（2026-11-08 两版权重对比）：
        模型把 113 帧真 W 里的 85 帧统一压成 NONE —— 它学会了「拿不准就报中间类」，
        因为没有学对 W 的动力。

    为什么是平方根：
        纯逆频率 → W/NONE 赔率 12.6x（W 学不动）
        平方根   → W/NONE 赔率  3.6x（W=[0.380, 1.350, 1.269]）
        对数量级较重的长尾分布，平方根是常用的折中：既不让多数类淹没少数类，
        也不把多数类的梯度压到失效。避免用「永远输出 W」的捷径（那会占 85.5%
        准确率但 S 召回为 0，是 V3 明确的禁区，见 03-output-head.md §5）。

    注意：本函数**只改损失权重，不动数据**。W 帧一帧不少。
    """
    raw = torch.tensor([math.sqrt(total := sum(counts) / max(c, 1))
                        for c in counts], dtype=torch.float32)
    if mean_normalize:
        raw = raw / raw.mean()
    return raw


def _pos_weight(n_pos: int, n_total: int) -> float:
    """BCEWithLogits 的 pos_weight = 负样本数 / 正样本数。

    正例极罕见时（如 ultimate_brake）该值会很大，这是有意的：
    不放大正例梯度，模型会直接学到「永远输出 0」而 loss 很低。
    """
    n_neg = n_total - n_pos
    return float(n_neg) / max(n_pos, 1)


# ----------------------------------------------------------------------------
# 评估：macro recall（禁用总准确率做模型选择）
# ----------------------------------------------------------------------------

# S（纵向刹车）误报率预算：用户明确要求「不要凭空刹车」。
# 选模时超过该预算的轮次会被强罚，避免「用无穷多刹车换召回」的平凡解。
#
# ⚠️ 必须放在 `@torch.no_grad()` 装饰器**之前**：装饰器与被装饰函数之间
#    不能插入其它语句，否则 SyntaxError（首次应用时踩过）。
S_FPR_BUDGET = 0.05


@torch.no_grad()
def _argmax3(logits: torch.Tensor) -> torch.Tensor:
    """三分类 argmax：**平局取第一个最大值**，与部署端及 `np.argmax` 一致。

    部署端 `InferenceEngineV3.parseDecision.argmax3` 的现行实现是：
        var bestIndex = 0
        for i in 1..<a.count where a[i] > a[bestIndex] { bestIndex = i }
        return bestIndex
    严格 `>` 比较 → 平局保留更早下标 → **首个最大值胜出**，与 `np.argmax` 同义。

    ⚠️ 历史 bug（2026-11-09 修复）：本函数此前复刻的是**旧版** Swift 规则
    （「NONE 仅在严格大于两侧时才赢，否则 W 优先」）。Swift 侧改规则后此处未同步，
    导致平局帧离线评估与线上解码分叉 —— 实测 logits=[0,1,1] 时：
        旧实现 → 2(S)；Swift/argmax → 1(NONE)
    后果是离线指标（macro recall、混淆矩阵、选模）系统性偏离上车行为，
    属「注释声称已复刻、实际复刻了错的版本」。
    这类分叉必须靠「与 np.argmax 全量对照」的测试锁死，不能靠肉眼比对注释。

    显式两两比较而非直接 torch.argmax：torch 在部分后端不保证平局取首个，
    而这里的语义必须与 np.argmax / Swift 严格一致。
    """
    a0, a1, a2 = logits[:, 0], logits[:, 1], logits[:, 2]
    # 首个最大值：a0 是最大值则取 0（含并列）；否则 a1 >= a2 取 1，其余取 2
    case0 = (a0 >= a1) & (a0 >= a2)
    case1 = (~case0) & (a1 >= a2)
    return torch.where(case0, torch.zeros_like(a0, dtype=torch.long),
                       torch.where(case1, torch.ones_like(a0, dtype=torch.long),
                                   torch.full_like(a0, 2, dtype=torch.long)))


@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, crit: V3Loss,
             device: str) -> Tuple[float, Dict[str, float]]:
    """验证集评估：返回 (总损失, 指标 dict)。

    ⚠️ 2026-11-08 重做选模型口径（本次任务 3）。旧实现 `select` 只取
    vertical/horizontal 两个方向头的 macro recall 平均，结果 `best_epoch=1`
    （15 轮里第 1 轮就"到顶"），而真实部署暴露的是**修饰键头乱触发**
    （多余地踩 S/Shift/Space）。方向头指标对这类故障完全不敏感 —— 它们测的是
    「转向/给油分类对不对」，而乱触发发生在 handbrake/brake/super/ultimate
    四个头以及它们的最终合成上。

    所以这里额外按**生产链路**（`InferenceEngineV3.swift:847` 的 ultimate 强制
    S + `AuroraDriveApp.swift:9405-9407` 的 needShift/needSpace 推导）计算最终
    六键，并统计三类安全关键错误：
        · S 假阳性帧数   ：真值无 S 却输出 S（最危险：无故急刹）
        · Space 假阳性帧数：真值不需要 Space（brake/super/ultimate 都为 0）却输出 Space
        · 漏刹车帧数     ：真值有 S 却不输出 S

    新 select 公式与依据（写进 history 可审计）：
        macro_recall = (vertical_recall + horizontal_recall) / 2
        # 纵向 S（含 ultimate 强制覆盖）
        s_balanced_acc   = 1 − (S误刹车率 + S漏刹车率) / 2
        # Space 键（need_space 推导后逐键判断）—— 直接度量「修饰键乱触发」
        space_balanced_acc = 1 − (Space误触发率 + Space漏触发率) / 2
        brake_quality = (s_balanced_acc + space_balanced_acc) / 2
        select = 0.5 * macro_recall + 0.5 * brake_quality

    依据：
      1) 方向头仍占 50%：转向/给油判错则整体控制不可用，不能像旧版一样被削弱到 0；
         但它不再是**唯一**依据（旧版问题的根源）。
      2) brake_quality 纳入 **S 纵向 + Space 键**两路，各用「误报率与漏报率的平均」
         折算：单看 (1−误报率) 会被「永不输出」的平凡解刷满（永不刹车 → 假阳性 0
         → 该术语=1），而这恰恰是要防的「漏刹车」。取平均后：永不输出 → 0.5；
         永远输出 → 0.5；只有既不误报又不漏报 → 趋近 1，平凡解拿不到高分。
      3) 为什么要单独看 Space 键、而不只看纵向 S：实测冒烟已暴露——模型的
         Space 假阳性可以很高（10 帧），但若验证集恰好缺 S 类，纵向 S 的平衡
         acc 仍是 1.0，只看 S 会把「修饰键乱触发」整个漏掉。Space 键级指标补上
         这一块（本任务缺陷正是「修饰键头乱触发」）。
      4) 全部制动指标只在 `modifier_valid=1` 的**可信帧**上统计 —— 卡键段的
         shift/space 是录制故障值，用它当"真值"评判会产生系统性偏差。

    返回的 metrics 会在 history 里逐轮落盘（见 train_v3_summary.json）。
    """
    model.eval()
    totals = {"loss": 0.0, "n": 0}
    # 方向头的混淆计数：[3,3]
    conf_v = torch.zeros(3, 3, dtype=torch.long)
    conf_h = torch.zeros(3, 3, dtype=torch.long)
    # 六键制动计数（仅 modifier_valid=1 的帧）
    #   s_*      ：纵向最终 S（含 ultimate 强制覆盖）的 tp/fp/fn
    #   space_*  ：Space 键（need_space 推导）的 tp/fp/fn
    brake = {"s_tp": 0, "s_fp": 0, "s_fn": 0,
             "space_tp": 0, "space_fp": 0, "space_fn": 0, "n_valid": 0}
    # 「回退到自派生」告警只打一次（见下方 .get() 说明）。
    warned_head_fallback = False

    for batch in loader:
        batch = {k: v.to(device) for k, v in batch.items()}
        out = model(image_hi=batch["image_hi"], image_lo=batch["image_lo"],
                    lane=batch["lane"], dets=batch["dets"],
                    det_mask=batch["det_mask"],
                    vehicle_state=batch["vehicle_state"], return_intent=True)
        loss, _ = crit(out, batch)

        bs = batch["image_hi"].shape[0]
        totals["loss"] += float(loss) * bs
        totals["n"] += bs

        # ── 方向头（生产 argmax 平局规则）──
        pv = _argmax3(out["vertical"]).cpu()
        ph = _argmax3(out["horizontal"]).cpu()
        tv = batch["vertical"].cpu()
        th = batch["horizontal"].cpu()
        for t, p in zip(tv.tolist(), pv.tolist()):
            conf_v[t, p] += 1
        for t, p in zip(th.tolist(), ph.tolist()):
            conf_h[t, p] += 1

        # ── 六键（复刻生产链路）──
        # 正常路径读模型输出头 out['super_brake'] / out['ultimate']（=data-clean
        # 现把这两个头做成派生真 logit），与部署端 parseDecision 的 `xxRaw > 0`
        # **逐帧严格同构**（生产读的就是这两个输出，不是 Swift 侧自派生）。
        #
        # .get() 只作安全网：若未来 forward 不再返回这两个键，回退到
        # 「handbrake∧brake(∧S) 派生」。⚠️ 注意两条路径**不完全等价**
        # （输出头判据是 p_hb·p_br(·p_S) > 0.5；自派生是 p_hb>0.5 且 p_br>0.5 且
        #  pS>0.5，条件更强），所以一旦走到回退必须显式告警，绝不静默用近似值。
        # ⚠️【设备统一】预测侧布尔量必须与 pv/tv 同设备（都是 CPU）。
        #   2026-11-09 云端训练崩溃实录：
        #     RuntimeError: Expected all tensors to be on the same device,
        #     but found at least two devices, cuda:0 and cpu!
        #     v_final_p = torch.where(ul_p, torch.full_like(pv, 2), pv)
        #   原因：pv/tv 在下面被 .cpu() 搬到 CPU，而 ul_p 来自 CUDA 输出张量。
        #   torch.where 要求条件与两个分支同设备 → 直接抛错。
        #   ⚠️ 本地 --device cpu 冒烟**发现不了**这个缺陷（全在 CPU，设备天然一致），
        #   只有 cuda/mps 才暴露 —— 所以云端一跑就崩、白烧 16 算力点。
        #   修法：在布尔量诞生处就 .cpu()，使六键推导全程在 CPU 完成。
        zero = torch.zeros(bs, device="cpu")
        hb_logit = out.get("handbrake")
        br_logit = out.get("brake")
        # 预测侧：logit>0 等价于 sigmoid>0.5，与 parseDecision 的 `xx > 0` 一致
        hb_p = ((hb_logit.reshape(-1) > 0).cpu()
                if hb_logit is not None else zero.bool())
        br_p = ((br_logit.reshape(-1) > 0).cpu()
                if br_logit is not None else zero.bool())
        ul_out = out.get("ultimate")
        sb_out = out.get("super_brake")
        if (ul_out is None or sb_out is None) and not warned_head_fallback:
            warned_head_fallback = True
            print("[V3Train] ⚠ evaluate 未取到 super_brake/ultimate 输出头，"
                  "回退为 handbrake∧brake(∧S) 自派生 —— 该判据与生产(读输出头)"
                  "**不完全等价**，离线六键指标可能偏离上车行为，请核查模型输出契约。")
        # super_brake：优先输出头；缺失才回退 handbrake∧brake 派生
        sb_p = ((sb_out.reshape(-1) > 0).cpu() if sb_out is not None
                else (hb_p & br_p))
        # ultimate：优先输出头；缺失才回退 handbrake∧brake∧(纵向=S) 派生
        ul_p = ((ul_out.reshape(-1) > 0).cpu() if ul_out is not None
                else (hb_p & br_p & (pv == 2)))
        # ultimate 强制纵向为 S（InferenceEngineV3.swift:847）
        v_final_p = torch.where(ul_p, torch.full_like(pv, 2), pv)
        # needShift = 任一修饰键头为 1；needSpace = brake|super|ultimate（AuroraDriveApp.swift:9405-9407）
        need_shift_p = hb_p | sb_p | ul_p
        need_space_p = br_p | sb_p | ul_p

        # 真值侧（dataset 里组合键已按 mvalid 置 0；同样用 .get() 防御）
        ul_t_raw = batch.get("ultimate")
        sb_t_raw = batch.get("super_brake")
        br_t = (batch["brake"].reshape(-1) > 0.5).cpu()
        hb_t = (batch["handbrake"].reshape(-1) > 0.5).cpu()
        sb_t = ((sb_t_raw.reshape(-1) > 0.5).cpu() if sb_t_raw is not None
                else (hb_t & br_t))
        ul_t = ((ul_t_raw.reshape(-1) > 0.5).cpu() if ul_t_raw is not None
                else (hb_t & br_t & (tv == 2)))
        v_final_t = torch.where(ul_t, torch.full_like(tv, 2), tv)
        need_shift_t = hb_t | sb_t | ul_t
        need_space_t = br_t | sb_t | ul_t
        mvalid = (batch["modifier_valid"].reshape(-1) > 0.5).cpu()

        m = mvalid.cpu()
        pred_s = (v_final_p == 2).cpu()
        true_s = (v_final_t == 2).cpu()
        brake["s_tp"] += int((m & pred_s & true_s).sum())
        brake["s_fp"] += int((m & pred_s & ~true_s).sum())
        brake["s_fn"] += int((m & ~pred_s & true_s).sum())
        # Space 键三格（need_space 推导后的键级判断）
        ns_p = need_space_p.cpu()
        ns_t = need_space_t.cpu()
        brake["space_tp"] += int((m & ns_p & ns_t).sum())
        brake["space_fp"] += int((m & ns_p & ~ns_t).sum())
        brake["space_fn"] += int((m & ~ns_p & ns_t).sum())
        brake["n_valid"] += int(m.sum())

    n = max(totals["n"], 1)
    metrics = {"loss": totals["loss"] / n}

    def _macro_recall(conf: torch.Tensor) -> float:
        recalls = []
        for c in range(conf.shape[0]):
            support = int(conf[c].sum())
            if support > 0:
                recalls.append(float(conf[c, c]) / support)
        return sum(recalls) / len(recalls) if recalls else 0.0

    metrics["vertical_recall"] = _macro_recall(conf_v)
    metrics["horizontal_recall"] = _macro_recall(conf_h)
    metrics["macro_recall"] = (metrics["vertical_recall"] + metrics["horizontal_recall"]) / 2

    # 逐类召回（日志/审计用；某类 support=0 时记 -1 表示本次验证集无该类）
    for c, name in enumerate(("W", "NONE", "S")):
        sup = int(conf_v[c].sum())
        metrics[f"recall_v_{name}"] = float(conf_v[c, c]) / sup if sup else -1.0
    for c, name in enumerate(("A", "NONE", "D")):
        sup = int(conf_h[c].sum())
        metrics[f"recall_h_{name}"] = float(conf_h[c, c]) / sup if sup else -1.0

    # 制动六键指标
    #
    # ⚠️「无正例」必须判为**不可估**，不能默认算成 1.0（实测踩到过）：
    #    200 样本冒烟里验证集 S 支持=0、Space 正例=0，若按 `分母为 0 → 比率记 0`
    #    的写法，误刹车率=0、漏刹车率=0 → brakeQ=1.000，select 直接飙到 0.96。
    #    这与本任务要修的病完全同类：指标在「没有数据」时给出满分，然后被选模
    #    逻辑当成「这轮很好」。故不可估的分量记 -1.0 哨兵，从平均里剔除；
    #    两路都不可估时 brake_quality 记 -1.0，由 select 退回纯方向指标并在日志告警。
    s_tp, s_fp, s_fn = brake["s_tp"], brake["s_fp"], brake["s_fn"]
    denom_true = s_tp + s_fn
    n_brake_valid = brake["n_valid"]
    # ⚠️ 误报率必须是 FP/(FP+TN)，**不是** FP/(TP+FP)。
    #   历史 bug（2026-11-09 修复）：此处曾写成 1−精确率。稀有类上两者差一个数量级 ——
    #   训练历史 epoch7 记录「误刹车率 24.61%」，而同一权重实测真实误报率仅 1.34%
    #   （放大 18.3 倍，15 轮全部 14~19 倍）。后果：select 被系统性推向
    #   「少预测稀有类」以抬高精确率，导致 W/S/Space 召回全面下降。
    #   这是 v4b 相对线上模型退步的机制性原因，不是模型容量问题。
    s_tn = n_brake_valid - (s_tp + s_fp + s_fn)
    over_brake_rate = (s_fp / (s_fp + s_tn)) if (s_fp + s_tn) > 0 else -1.0
    missed_brake_rate = (s_fn / denom_true) if denom_true > 0 else -1.0
    # 平衡准确率：只有 FPR 与 FNR 都可比时才等于 1-(FPR+FNR)/2（这正是此处定义）
    if denom_true > 0 and over_brake_rate >= 0:
        s_balanced = 1.0 - (over_brake_rate + missed_brake_rate) / 2.0
    else:
        s_balanced = -1.0
    # Space 键：同样用误报率口径（键级 FP/(FP+TN)），不是 1−精确率
    sp_tp, sp_fp, sp_fn = brake["space_tp"], brake["space_fp"], brake["space_fn"]
    space_denom_true = sp_tp + sp_fn
    sp_tn = n_brake_valid - (sp_tp + sp_fp + sp_fn)
    if space_denom_true > 0 and (sp_fp + sp_tn) > 0:
        space_over = sp_fp / (sp_fp + sp_tn)
        space_miss = sp_fn / space_denom_true
        space_balanced = 1.0 - (space_over + space_miss) / 2.0
    else:
        space_over = -1.0
        space_miss = -1.0
        space_balanced = -1.0
    # brake_quality = 可估分量的平均（两路都不可估时记 -1.0）
    available = [v for v in (s_balanced, space_balanced) if v >= 0]
    brake_quality = (sum(available) / len(available)) if available else -1.0
    metrics["select_brake_available"] = 1.0 if available else 0.0
    metrics["s_true_pos"] = s_tp
    metrics["s_false_pos"] = s_fp
    metrics["s_false_neg"] = s_fn
    metrics["space_true_pos"] = sp_tp
    metrics["space_false_pos"] = sp_fp
    metrics["space_false_neg"] = sp_fn
    metrics["space_over_rate"] = space_over
    metrics["n_brake_eval"] = brake["n_valid"]
    metrics["over_brake_rate"] = over_brake_rate
    metrics["missed_brake_rate"] = missed_brake_rate
    metrics["s_balanced_acc"] = s_balanced
    metrics["space_balanced_acc"] = space_balanced
    metrics["space_miss_rate"] = space_miss
    metrics["s_recall"] = (s_tp / denom_true) if denom_true > 0 else -1.0
    metrics["brake_quality"] = brake_quality
    # select：制动可估时按 0.5/0.5 加权；两路都不可估时**退回纯方向指标**。
    # 为什么不直接 0.5*macro + 0.5*(-1.0)：那会得出 0.5*macro−0.5，
    # 把「验证集没有制动样本」的轮次**罚**下去 —— 同样是让"有没有数据"决定
    # 选模结果，只是方向反过来。没有数据时唯一诚实的做法是不用这一项。
    if available:
        metrics["select"] = 0.5 * metrics["macro_recall"] + 0.5 * brake_quality
    else:
        metrics["select"] = metrics["macro_recall"]

    # ── 选模口径：直接优化「用户可见成本」，不用代理指标 ──
    # 为什么换掉上面的 select：macro_recall/balanced_acc 都是代理，
    #   与真实诉求（该给油要给油、不要凭空刹车、该刹车要刹）不完全同向，
    #   且代理指标在稀有类上对样本波动极敏感。
    #   权重依据：W漏判=第一诉求；S误报=第二诉求；S漏判/Space漏报=安全底线；Space误报=体验。
    #   `select` 越大越好（与旧逻辑同向），故取负成本。
    #   S 误报超预算时强罚，防止「用无穷多刹车换召回」的平凡解。
    w_miss_rate = (1.0 - metrics["recall_v_W"]) if metrics["recall_v_W"] >= 0 else -1.0
    # ⚠️ W误报（凭空给油）是 2026-11-09 补入的**关键缺项**：
    #   此前成本只罚「该给油不给油」，不罚其对称面「不该给油却给油」。
    #   实测某配置 W漏判 4.07%→1.73%（改善）但 W误报 28.29%→39.10%（751→1038 帧，p=0.0000），
    #   即「漏给油」被换成「乱给油」，而旧成本会把它判为改进 → 选模可能挑中危险轮次。
    #   必须与上线判定器 decide.py 的口径保持一致，否则「训练选轮」与「上线裁定」会打架。
    # W误报率 = 真值非W 却判 W。分母是「非W 帧数」，由混淆矩阵直接得到。
    n_nonw = int(conf_v[1].sum()) + int(conf_v[2].sum())
    w_fp_rate = ((int(conf_v[1, 0]) + int(conf_v[2, 0])) / n_nonw) if n_nonw > 0 else -1.0
    metrics["w_false_pos_rate"] = w_fp_rate
    if w_miss_rate >= 0 and w_fp_rate >= 0 and over_brake_rate >= 0 and missed_brake_rate >= 0:
        user_cost = (2.0 * w_miss_rate
                     + 2.0 * w_fp_rate
                     + 1.5 * over_brake_rate
                     + 1.5 * missed_brake_rate)
        if space_over >= 0:
            user_cost += 1.0 * space_over
        if space_miss >= 0:
            user_cost += 1.5 * space_miss
        if over_brake_rate > S_FPR_BUDGET:
            user_cost += (over_brake_rate - S_FPR_BUDGET) * 20.0
        metrics["user_cost"] = user_cost
        metrics["select"] = -user_cost
    else:
        metrics["user_cost"] = -1.0
        metrics["select"] = metrics["macro_recall"]
    return metrics["loss"], metrics


# ----------------------------------------------------------------------------
# 训练主流程
# ----------------------------------------------------------------------------

def train(
    clips_dir: str,
    epochs: int = 30,
    batch_size: int = 8,
    lr: float = 3e-4,
    weight_decay: float = 5e-4,
    val_ratio: float = 0.2,
    device: str = "auto",
    num_workers: int = 0,
    ckpt_dir: Optional[str] = None,
    limit: Optional[int] = None,
    seed: int = 42,
    warmup_ratio: float = 0.1,
    s_boost: float = 1.0,
    none_boost: float = 1.0,
    lambda_safe: float = 0.1,
    fixed_val_clips: Optional[List[str]] = None,
    use_vram_cache: bool = False,
    vram_decode_threads: int = 8,
    vram_gpu_decode: str = "auto",
    keep_all_zero: bool = False,
    init_from: Optional[str] = None,
    freeze_calib_heads: bool = False,
) -> Dict[str, object]:
    """训练 V3 模型。

    Args:
        clips_dir:  `data/raw_clips` 之类，内含 clip_*/frames + controls.csv
        epochs:     训练轮数
        batch_size: 批大小（MPS 内存有限，默认 8）
        lr:         学习率（沿用项目 3e-4）
        weight_decay: AdamW 权重衰减（沿用项目 5e-4）
        val_ratio:  验证集比例（按 clip 划分）
        device:     auto / npu / mps / cuda / cpu
        num_workers: DataLoader 进程数（0 = 主进程，MPS 下更稳）
        ckpt_dir:   checkpoint 目录（默认 checkpoints/v3）
        limit:      只取前 N 个样本（冒烟测试用，None = 全量）
        seed:       随机种子
        warmup_ratio: warmup 占总步数的比例
        lambda_safe: confidence/risk 安全头的损失权重（V3Loss 原默认 0.1）。
            设 0 可**完全去掉这两项损失**。为什么要能关掉：实测（2026-11-09）
            这两个头的代理真值极度偏向常数（confidence 多数帧恒为 1.0、
            risk 无制动帧恒为 0.1），BCE 会把 logit 推向饱和；而且梯度经
            **共享主干**回传，即使冻结末层参数，conf logit 仍从 3.77 涨到 11.97
            （ft_freeze2 实测）。后果是引擎 T6 自检（黑/白帧输出须有差异）失败。
            这两头**不参与任何控制决策**（只进共享内存/UI 诊断），关掉损失最干净。
        freeze_calib_heads: True 时冻结 confidence/risk 两个末层校准头（不参与梯度）。
            为什么需要：这两头的代理真值极度偏向 1.0（`_confidence_targets`
            在控制量不变的帧上恒为 1.0，约占多数帧），BCE 会把 logit 无界推向
            正无穷 → 微调后 conf logit 从 ~5 涨到 10~22，sigmoid 饱和。
            实测后果：引擎 T6 自检（黑/白帧输出须有差异）失败。
            这两个头**不参与任何控制决策**（只进共享内存与 UI 诊断），
            冻结它们既能保住 ep15 的校准、又不动决策头，是对症的最小改动。
        init_from: 从已有 checkpoint 初始化权重（预热微调）。strict=True 校验键名，
            不匹配即报错（避免 silent drop —— 那正是此前基准测错的根源）。
        keep_all_zero: True 时**不剔除六键全零帧**（默认 False，保持与历史训练一致）。
            为什么需要它：部署时引擎会看到菜单/停车/滑行等全零帧（110525 中占 19.4%，
            真值 100% 为 NONE），而默认训练把它们全部剔除 → 模型在这些输入上属分布外，
            实测 S误报 83%、W误报 68%、Space误报 76% 都落在这些帧上。

    Returns:
        汇总 dict（含 best 指标与 checkpoint 路径）
    """
    torch.manual_seed(seed)
    dev = resolve_device(device)
    print(f"[V3Train] 设备={dev}")

    # ⚠️ keep_all_zero=True → skip_all_zero=False，把全零帧纳入训练。
    #   默认 False 保持历史行为（训练/LOO 一致剔除全零帧）。
    base = V3KeyDataset(clips_dir, skip_all_zero=not keep_all_zero)
    if limit is not None and limit < len(base):
        # 冒烟测试：**原地截断 index**，不包 Subset。
        # 为什么不用 Subset：make_train_val_split 与 compute_class_stats 都读
        # `dataset.index`，Subset 没有该属性，包一层就得分叉出两套代码路径
        # —— 第一版正是这么写的，结果 --limit 实际没生效（日志说 40 个样本，
        #    划分出来却是全量 153 个）。截断 index 只改一处，三处消费方全一致。
        del base.index[limit:]
        print(f"[V3Train] ⚠ 冒烟模式：只用前 {limit} 个样本")

    train_ds, val_ds, val_clips = make_stratified_train_val_split(
        base, val_ratio=val_ratio, seed=seed, fixed_val_clips=fixed_val_clips)

    # ── 显存帧缓存：把全部帧一次性预解码进显存 ─────────────────────────
    # 为什么放在 make_train_val_split 之后：缓存挂到 base（被 Subset 共享），
    # 训练/验证两个 loader 都能取到，无需复制。
    # ⚠️ 快速失败，不回退：构建或自检失败立即抛异常退出。
    #    宁可任务在几分钟内死掉重来，也不要慢速硬跑几小时烧掉算力点。
    if use_vram_cache:
        if num_workers > 0:
            # CUDA 张量无法跨进程传给 DataLoader worker，开了必崩。
            # 与其让任务崩在第一个 batch，不如启动时立刻报错退出。
            raise RuntimeError(
                f"--vram-cache 与 --num-workers={num_workers} 互斥："
                "显存缓存路径必须在主进程取数（worker=0）。")
        from vram_cache import V3VRAMFrameCache
        # ⚠️ 必须先确认加速器真实可见再开缓存：20.5 GiB 的预解码如果落在
        # CPU 内存上，会把容器的 16 GB RAM 直接打爆，死得又慢又难看。
        # 用 device.type 而不是字符串前缀，npu/cuda 一视同仁。
        dev_type = torch.device(dev).type
        if dev_type in ("cuda", "npu") and not device_available(dev_type):
            raise RuntimeError(
                f"device={dev} 但 {dev_type} 不可用。"
                "--vram-cache 需要加速器；请检查镜像/设备配置。")
        dev_for_cache = torch.device(dev) if dev_type in ("cuda", "npu", "mps") \
            else "cpu"
        cache = V3VRAMFrameCache(
            base,
            device=dev_for_cache,
            decode_threads=vram_decode_threads,
            # GPU 解码走的是 CUDA nvJPEG，NPU 上没有对等通路；只在 cuda 下开启，
            # 其余回落到 CPU 多线程 PIL（与原集群实测路径一致）。
            use_gpu_decode=vram_gpu_decode if dev_type == "cuda" else "false",
        )
        # 自检：随机抽 32 个样本与原解码路径逐像素比对。
        # 任何不一致都意味着加速改变了训练数据 → 立即中止。
        #
        # 容差 1e-6 而非 0：像素（uint8）必须完全相同，但 /255 的实现不同
        # （原始路径 numpy 真除法，缓存路径 torch 在 CUDA 上按倒数乘法），
        # 实测最大 1 ULP = 5.96e-08 的舍入噪声。真实改变 1 个像素的最小差是
        # 1/255≈3.9e-3，比 1e-6 大 3900 倍 —— 判定依然严格。
        #
        # ⚠️ 必须先挂载再自检：verify_against_direct 的做法是"临时摘掉缓存跑
        #    原始路径、再装回来跑缓存路径"。若挂载顺序颠倒，两条路径都会是
        #    原始解码，比对必然为 0 —— 那是一个永远通过的假自检。
        base.vram_cache = cache
        rng = random.Random(seed)
        probe_indices = rng.sample(range(len(base.index)), min(32, len(base.index)))
        max_diff = cache.verify_against_direct(base, probe_indices, tol=1e-6)
        print(f"[V3Train] 显存缓存自检通过：最大差 {max_diff}（容差 1e-6）")


    # 类别统计与权重：**只在训练子集**上统计，且 pos_weight 只数 modifier_valid=1
    # 的有效帧。为什么必须排除验证集：验证标签参与类权重/pos_weight 计算，会让
    # 验证集不再独立 —— 等于用验证集信息调损失函数，选出的指标偏乐观（缺陷 2）。
    # 为什么 pos_weight 只用有效帧：V3Loss._masked_bce 对四个修饰键头都按
    # modifier_valid 过滤，分母就是有效帧数；用全量分母会把卡键段的 1739 帧
    # 算进比例，使 super/ultimate 的 pos_weight 少算 3~4 倍（缺陷 1）。
    train_samples = [base.index[i] for i in train_ds.indices]
    stats = compute_class_stats(base, samples=train_samples)
    n = stats["modifier_valid_total"]   # BCE 实际见到的有效帧数（pos_weight 分母）
    print(f"[V3Train] 类分布(训练子集): vertical={stats['vertical']} "
          f"horizontal={stats['horizontal']} 样本={stats['total']} "
          f"有效帧(modifier_valid=1)={n} 屏蔽帧={stats['masked']}")
    print(f"[V3Train] 正例数(有效帧): " +
          ", ".join(f"{k}={v}" for k, v in stats["positives"].items()))

    # ⚠️ 2026-11-08 改为平方根逆频率（见 _sqrt_inverse_freq_weights 的说明）：
    #   纯逆频率把 W 压到 0.121，导致「真W判成NONE」几乎不付代价，
    #   实测模型把 113 帧真 W 里的 85 帧压成 NONE。平方根把它压到 0.380。
    v_w = _sqrt_inverse_freq_weights(stats["vertical"])
    h_w = _sqrt_inverse_freq_weights(stats["horizontal"])

    # ── S 类加权（--s-boost，单变量实验）──
    # 依据（2026-11-09 实测，验证集 stride=5，n=2616）：
    #   派生头版本把「凭空刹车」4.53%→2.75%（改善），
    #   但 vertical 头自身 S 召回 64.29%→58.57%（退步），S漏刹车 41.43% 未达 40% 门槛。
    # 只调 S 类权重，不动数据、不改其它变量。
    # ⚠️ 打印顺序必须先"平方根基准"再"S类放大"：否则「(平方根)」那行会印出
    #   放大后的值，日志读者会误以为放大没生效 / 或误读基准权重。
    print(f"[V3Train] vertical 类权重(平方根基准)=["
          + ", ".join(f"{x:.4f}" for x in v_w.tolist()) + "]"
          + f"  (原纯逆频率=["
          + ", ".join(f"{x:.4f}" for x in _inverse_freq_weights(stats['vertical']).tolist()) + "])")
    # ── NONE 类加权（--none-boost，单变量实验）──
    # 依据（2026-11-09 oracle 替换实测，LOO 口径 n=6889）：
    #   把 NONE 类判对（oracle）→ macro 0.8803（≥0.85 可达）
    #   把 S 判对 → 0.8563；把 W 判对 → 0.7739（**不够**）
    #   → NONE 是唯一瓶颈，故提供单独放大其权重的开关（与 --s-boost 同构）。
    # 只调类权重，不动数据、不改其它变量；默认 1.0 = 行为完全不变。
    # 注意：与 --s-boost 顺序执行时，两次归一化保持各类相对比例，等价于
    #       「两者同时放大后再归一」，不会互相抵消。
    if none_boost != 1.0:
        v_w = v_w.clone()
        v_w[1] = v_w[1] * none_boost
        v_w = v_w / v_w.mean()      # 保持均值，避免等效学习率漂移
        print(f"[V3Train] 应用 NONE类放大 x{none_boost} → 实际 vertical 类权重=["
              + ", ".join(f"{x:.4f}" for x in v_w.tolist()) + "]")

    if s_boost != 1.0:
        v_w = v_w.clone()
        v_w[2] = v_w[2] * s_boost
        v_w = v_w / v_w.mean()      # 保持均值，避免等效学习率漂移
        print(f"[V3Train] 应用 S类放大 x{s_boost} → 实际 vertical 类权重=["
              + ", ".join(f"{x:.4f}" for x in v_w.tolist()) + "]")
    pos = stats["positives"]
    # 注意：n 已在上面定义为**有效帧数**（modifier_valid_total）。这里绝不能再写
    # `n = stats["total"]` —— 那会用「全部帧」当 pos_weight 分母，重新引入缺陷 1。

    # ⚠️ 零正例检查：某些键可能在整批数据里一次都没按过（例如用户还没用过
    #    超级刹车）。此时 pos_weight = n/1 很大，但**没有正例可学**，该头训练后
    #    必然永远输出 0，loss 却看起来"很正常"。这属于必须显式报警的静默失效，
    #    不能让人以为这个头已经训好了。
    #    检查对象必须是**过滤后**（modifier_valid=1）的正例数 —— 否则卡键段里
    #    被屏蔽的 shift/space 会让一个「其实没有有效正例」的头看起来有正例。
    dead_heads = [k for k, v in pos.items() if v == 0]
    if dead_heads:
        print("=" * 72)
        print(f"[V3Train] 🚨 以下输出头在训练数据中**没有任何有效正例**，无法学习：{dead_heads}")
        print("           它们训练后将永远输出 0（loss 正常但功能不存在）。")
        print("           若这不是预期，请补录包含这些按键（Shift+空格 / Shift+空格+S）的数据。")
        print("=" * 72)

    print(f"[V3Train] vertical 类权重={v_w.tolist()}  horizontal 类权重={h_w.tolist()}")
    print(f"[V3Train] pos_weight(分母=有效帧 {n}): handbrake={_pos_weight(pos['handbrake'], n):.2f} "
          f"brake={_pos_weight(pos['brake'], n):.2f} "
          f"super={_pos_weight(pos['super_brake'], n):.2f} "
          f"ultimate={_pos_weight(pos['ultimate'], n):.2f}")

    crit = V3Loss(
        vertical_weights=v_w.to(dev),
        horizontal_weights=h_w.to(dev),
        pos_weight_handbrake=_pos_weight(pos["handbrake"], n),
        pos_weight_brake=_pos_weight(pos["brake"], n),
        pos_weight_super=_pos_weight(pos["super_brake"], n),
        pos_weight_ultimate=_pos_weight(pos["ultimate"], n),
        enable_ccm=False,   # ⚠️ 见模块 docstring：模型 forward 不返回 ccm
        enable_intent=True,
        lambda_safe=lambda_safe,
    )
    if lambda_safe != 0.1:
        print(f"[V3Train] 安全头损失权重 lambda_safe={lambda_safe}"
              + ("（已关闭 confidence/risk 损失，校准头保持 init 状态）"
                 if lambda_safe == 0.0 else ""))
    # ⚠️ 必须整体搬设备：V3Loss 的类权重与 4 个 pos_weight 都是 register_buffer
    #    （model_v3.py:1218-1233）。只把预测搬到 MPS 而判据留在 CPU，会在
    #    BCEWithLogits 里报 "Expected all tensors to be on the same device"
    #    —— 冒烟实跑抓到的第一个崩溃就是这个。.to() 会一并搬运所有 buffer。
    crit = crit.to(dev)

    model = build_v3_model(deploy=False).to(dev)
    print(f"[V3Train] 参数量: {sum(p.numel() for p in model.parameters()):,}")

    # ── 预热微调：从已有 checkpoint 初始化（可选）──
    # 为什么用 strict=True：本项目此前因 `load_state_dict(strict=False)` 静默丢弃
    #   独立 super_brake/ultimate 头，导致基准模型测错（见 LEDGER）。这里宁可
    #   立刻报错，也不要得到一个"看起来能跑、实际少了一半头"的模型。
    if init_from:
        ip = Path(init_from)
        if not ip.is_file():
            raise FileNotFoundError(f"--init-from 不存在: {ip}")
        ick = torch.load(ip, map_location="cpu", weights_only=False)
        state = ick["model"] if isinstance(ick, dict) and "model" in ick else ick
        try:
            model.load_state_dict(state, strict=True)
        except RuntimeError as e:
            raise RuntimeError(
                f"--init-from 权重与本模型结构不匹配（拒绝 strict=False 静默丢弃）: {e}"
            ) from e
        print(f"[V3Train] ✓ 已从 {ip.name} 初始化权重"
              f"（epoch={ick.get('epoch') if isinstance(ick, dict) else '?'}）")

    # ── 冻结 confidence/risk 校准头（可选）──
    # 必须在 build_adamw_optimizer 之前设置 requires_grad；
    # 该优化器已内置「跳过 requires_grad=False」的逻辑（train_mono.py）。
    if freeze_calib_heads:
        frozen = []
        for name, param in model.named_parameters():
            if name.startswith(("output_head.confidence.", "output_head.risk.")):
                param.requires_grad = False
                frozen.append(name)
        if not frozen:
            raise RuntimeError(
                "--freeze-calib-heads 指定了，但没找到 output_head.confidence/risk 参数"
                "（参数名可能已变，拒绝静默跳过）")
        n_frozen = sum(p.numel() for n, p in model.named_parameters()
                       if not p.requires_grad)
        print(f"[V3Train] ✓ 已冻结校准头 {len(frozen)} 个参数张量"
              f"（{n_frozen} 个数值），决策头照常训练：{frozen}")

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True,
                              num_workers=num_workers, drop_last=False)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False,
                            num_workers=num_workers)

    steps_per_epoch = max(1, math.ceil(len(train_ds) / batch_size))
    total_steps = steps_per_epoch * epochs
    warmup_steps = max(1, int(total_steps * warmup_ratio))
    optimizer = build_adamw_optimizer(model, lr=lr, weight_decay=weight_decay)
    sched = CosineWithWarmup(optimizer, warmup_steps=warmup_steps,
                             total_steps=total_steps, base_lr=lr, min_lr=1e-6)

    ckpt_path = Path(ckpt_dir) if ckpt_dir else DEFAULT_CKPT_DIR
    ckpt_path.mkdir(parents=True, exist_ok=True)

    best_select = -float("inf")
    best_epoch = -1
    history: List[Dict[str, float]] = []
    t0 = time.time()

    for epoch in range(1, epochs + 1):
        model.train()
        run_loss = 0.0
        run_n = 0
        # 安全项分项累计（coh / rollover）—— 不打印就无法确认防侧翻约束是否真的生效：
        # 速度列缺失时 L_rollover 会关闭，只有这里能看出来（而不是以为它在工作）。
        run_parts: dict = {}

        for batch in train_loader:
            batch = {k: v.to(dev) for k, v in batch.items()}
            optimizer.zero_grad(set_to_none=True)
            out = model(image_hi=batch["image_hi"], image_lo=batch["image_lo"],
                        lane=batch["lane"], dets=batch["dets"],
                        det_mask=batch["det_mask"],
                        vehicle_state=batch["vehicle_state"], return_intent=True)
            loss, lm = crit(out, batch)
            for part in ("coh", "rollover"):
                if part in lm:
                    run_parts[part] = run_parts.get(part, 0.0) + float(lm[part])

            if not torch.isfinite(loss):
                raise RuntimeError(
                    f"第 {epoch} 轮出现非有限损失 {loss.item()}，"
                    "训练已中止（继续跑只会污染权重）")

            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()
            sched.step()

            bs = batch["image_hi"].shape[0]
            run_loss += float(loss.detach()) * bs
            run_n += bs

        train_loss = run_loss / max(run_n, 1)
        val_loss, vm = evaluate(model, val_loader, crit, dev)
        elapsed = time.time() - t0

        history.append({"epoch": epoch, "train_loss": train_loss,
                        "val_loss": val_loss, **{k: v for k, v in vm.items() if k != "loss"}})

        # user_cost 必须与 select 同时打印：select = -user_cost 是新选模口径，
        # 只打印 select 会让「这轮为什么被选中」无法审计（历史 bug 正是口径不可见导致误读）。
        # 不可估时 user_cost 记 -1.0，与「成本真的是 -1」区分开。
        cost_show = ("不可估" if vm.get("user_cost", -1.0) < 0
                     else f"{vm['user_cost']:.4f}")
        # W误报必须可见：它是 user_cost 的第二大项，且曾因「漏罚」导致选模偏向乱给油。
        wfp = vm.get("w_false_pos_rate", -1.0)
        wfp_show = ("不可估" if wfp < 0 else f"{wfp * 100:.2f}%")
        print(f"[{epoch:3d}/{epochs}] train={train_loss:.4f} val={val_loss:.4f} "
              f"macroR(v/h)={vm['vertical_recall']:.3f}/{vm['horizontal_recall']:.3f} "
              f"macroR={vm['macro_recall']:.3f} select={vm['select']:.4f} "
              f"user_cost={cost_show} W误报={wfp_show} | "
              f"S召回={vm['recall_v_S']:.2f} D召回={vm['recall_h_D']:.2f} "
              f"A召回={vm['recall_h_A']:.2f} | {elapsed:.0f}s")
        # 制动六键指标单独一行：误刹车/漏刹车是本次选模口径与安全的核心，
        # 必须逐轮可见（旧版只看方向头，把「修饰键乱触发」完全漏掉了）。
        # 不可估的分量（-1.0 哨兵）打印成「不可估」，而不是一个看起来正常的数字。
        def _fmt_rate(x: float) -> str:
            return "不可估" if x < 0 else f"{x:.3f}"

        print(f"          六键: S假阳性={vm['s_false_pos']} 漏刹车={vm['s_false_neg']} "
              f"Space假阳性={vm['space_false_pos']} 误报率={_fmt_rate(vm['over_brake_rate'])} "
              f"漏刹车率={_fmt_rate(vm['missed_brake_rate'])} "
              f"brakeQ={_fmt_rate(vm['brake_quality'])} (有效帧={vm['n_brake_eval']})")
        # 安全项单独一行。⚠️ 缺席时打印「未计算」而不是 0.0：
        #   两者含义完全不同（0 = 算出来就是 0，没有任何违规；未计算 = 这一项没参与训练），
        #   混为一谈会让人误以为防侧翻约束在工作。
        n_batches = max(len(train_loader), 1)
        coh_txt = (f"{run_parts['coh'] / n_batches:.4f}"
                   if "coh" in run_parts else "未计算(无四键头)")
        roll_txt = (f"{run_parts['rollover'] / n_batches:.4f}"
                    if "rollover" in run_parts else "未计算(无车速)")
        print(f"          安全项 L_coh={coh_txt} L_rollover={roll_txt}")

        # 每轮存档：只存 best_model.pt 曾导致更优轮次永久丢失
        # （实测用户成本最优是 epoch1，比被选中的 epoch7 低 22.9%，但权重已丢失 → 白烧 80 点）。
        # 50MB/轮 × 15 轮 ≈ 750MB，云盘 30GB 足够；离线可按任意口径复选，无需重训。
        torch.save({
            "model": model.state_dict(),
            "epoch": epoch,
            "select_metric": vm["select"],
            "val_loss": val_loss,
            "val_metrics": vm,
            "class_stats": stats,
            "val_clips": [str(c) for c in val_clips],
            "config": {"dim": 256, "heads": 8, "stage1_depth": 5, "stage2_depth": 6},
        }, ckpt_path / f"epoch_{epoch:02d}.pt")

        if vm["select"] > best_select:
            best_select = vm["select"]
            best_epoch = epoch
            torch.save({
                "model": model.state_dict(),
                "epoch": epoch,
                "select_metric": best_select,
                "val_loss": val_loss,
                "val_metrics": vm,
                "class_stats": stats,
                "val_clips": [str(c) for c in val_clips],
                "config": {"dim": 256, "heads": 8, "stage1_depth": 5, "stage2_depth": 6},
            }, ckpt_path / "best_model.pt")
            bq_show = ("不可估" if vm["brake_quality"] < 0
                       else f"{vm['brake_quality']:.3f}")
            print(f"  ★ 新最佳 select={best_select:.4f} "
                  f"(macroR={vm['macro_recall']:.3f} brakeQ={bq_show}) "
                  f"→ {ckpt_path / 'best_model.pt'}")

    # 训练结束后回滚到最优 epoch 的权重。
    # 为什么要回滚：30 轮 + cosine 退火时，最后几轮的验证指标往往已被过拟合拉低
    # （本项目 8 轮实测：best 停在 epoch 4，epoch 8 的 val_loss 反而更高）。
    # 若调用方直接使用训练结束时留在显存里的权重，拿到的不是最好那一版。
    # 这里把内存中的模型显式恢复成 best_model.pt，使"训练结束后的模型状态"
    # 与"磁盘上的 best_model.pt"严格一致 —— 后续评估/导出不必再关心回滚。
    best_ckpt_path = ckpt_path / "best_model.pt"
    if best_epoch > 0 and best_ckpt_path.exists():
        best_ckpt = torch.load(best_ckpt_path, map_location="cpu", weights_only=False)
        model.load_state_dict(best_ckpt["model"])
        model.to(dev)
        print(f"[回滚] 已恢复 epoch {best_epoch} 的最优权重"
              f"（select={best_select:.4f}）")
    else:
        print("[回滚] 未产生 best_model.pt，跳过回滚（本轮无有效验证指标）")

    summary = {
        "device": dev, "epochs": epochs, "best_epoch": best_epoch,
        "best_select": best_select, "ckpt": str(ckpt_path / "best_model.pt"),
        "val_ratio": val_ratio, "val_clips": [str(c) for c in val_clips],
        "select_formula": "select = -user_cost（越大越好）; "
                          "user_cost = 2.0*W漏判率 + 2.0*W误报率 + 1.5*S误报率 "
                          "+ 1.5*S漏报率 + 1.0*Space误报率 + 1.5*Space漏报率 "
                          "+ 20*(S误报率-0.05 if 超预算); "
                          "误报率定义 = FP/(FP+TN)（不是 1-精确率，后者曾导致选模偏差）; "
                          "W误报率 = 真值非W却判W / 非W帧数"
                          "（漏罚此项会把「乱给油」误判为改进）",
        "class_stats": stats, "history": history,
    }
    (ckpt_path / "train_v3_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[完成] 最佳 epoch={best_epoch} select={best_select:.4f} "
          f"→ {ckpt_path / 'best_model.pt'}")
    return summary


def main() -> None:
    ap = argparse.ArgumentParser(description="V3 离散按键模型训练")
    ap.add_argument("--clips", required=True, help="录制数据目录（含 clip_* 子目录）")
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--weight-decay", type=float, default=5e-4)
    ap.add_argument("--val-ratio", type=float, default=0.2,
                    help="验证集目标占比（按样本数，取最接近的整数个 clip；默认 0.2）")
    ap.add_argument("--device", default="auto", choices=["auto", "mps", "cuda", "npu", "cpu"])
    ap.add_argument("--num-workers", type=int, default=0)
    ap.add_argument("--ckpt-dir", default=None)
    ap.add_argument("--limit", type=int, default=None, help="只取前 N 个样本（冒烟测试）")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--val-clips", nargs="+", default=None, metavar="CLIP",
                    help="显式指定验证集 clip 名（覆盖自动分层）。用于与旧模型对比时"
                         "固定同一个留出片段，例如 --val-clips clip_20261107_110525")
    ap.add_argument("--lambda-safe", type=float, default=0.1,
                    help="confidence/risk 安全头损失权重（默认 0.1，与 V3Loss 原值一致）。"
                         "设 0 可关闭该损失：微调会经共享主干把 conf logit 推向饱和，"
                         "导致引擎 T6 自检失败；这两头不参与驾驶决策")
    ap.add_argument("--none-boost", type=float, default=1.0,
                    help="vertical 的 NONE 类权重放大系数（1.0=不放大）。"
                         "依据 oracle 替换实测：NONE 是 vMacro 的唯一瓶颈"
                         "（NONE 判对→0.8803；W 判对仅 0.7739）")
    ap.add_argument("--s-boost", type=float, default=1.0,
                    help="vertical 的 S 类权重放大系数（1.0=不放大）；只改权重不改数据")
    ap.add_argument("--warmup-ratio", type=float, default=0.1,
                    help="warmup 占总步数比例（默认 0.1）")
    ap.add_argument("--vram-cache", action="store_true",
                    help="全部帧预解码进显存（构建/自检失败立即中止，不回退）")
    ap.add_argument("--vram-decode-threads", type=int, default=8)
    ap.add_argument("--vram-gpu-decode", default="auto", choices=["auto", "true", "false"])
    ap.add_argument("--freeze-calib-heads", action="store_true",
                    help="冻结 confidence/risk 校准头（代理真值恒定→微调会把它推到饱和，"
                         "导致引擎 T6 自检失败；这两头不参与驾驶决策，冻结可保住原校准）")
    ap.add_argument("--init-from", default=None, metavar="CKPT",
                    help="从已有 checkpoint 初始化权重（预热微调）；strict=True 校验键名")
    ap.add_argument("--keep-all-zero", action="store_true",
                    help="不剔除六键全零帧（默认剔除）。全零帧在部署时真实出现"
                         "（菜单/停车/滑行，110525 占 19.4%% 且真值全为 NONE），"
                         "纳入训练可修复模型在分布外帧上的误报")
    args = ap.parse_args()

    train(
        clips_dir=args.clips, epochs=args.epochs, batch_size=args.batch_size,
        lr=args.lr, weight_decay=args.weight_decay, val_ratio=args.val_ratio,
        device=args.device, num_workers=args.num_workers, ckpt_dir=args.ckpt_dir,
        limit=args.limit, seed=args.seed, warmup_ratio=args.warmup_ratio,
        s_boost=args.s_boost,
        none_boost=args.none_boost,
        lambda_safe=args.lambda_safe,
        fixed_val_clips=args.val_clips,
        use_vram_cache=args.vram_cache,
        vram_decode_threads=args.vram_decode_threads,
        vram_gpu_decode=args.vram_gpu_decode,
        keep_all_zero=args.keep_all_zero,
        init_from=args.init_from,
        freeze_calib_heads=args.freeze_calib_heads,
    )


if __name__ == "__main__":
    main()
