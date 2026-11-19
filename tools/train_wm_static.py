#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""train_wm_static.py — 训练静态世界模型（无动作标签，纯视频自监督 JEPA）

做什么
    从连续视频帧里学「世界如何演化」：给定第 t 帧，预测第 t+horizon 帧的潜表征。
    不需要任何按键/动作标签，因此训练数据就是两段无 UI 飙车视频的抽帧。

数据切分（为什么按时间切而不是随机切）
    p1 前 80% 帧 → 训练
    p1 后 20% 帧 → 验证（同源、但时间上不重叠）
    p2 全部帧    → 留出测试集（不同视频段落，最诚实的泛化检查）

    绝不能随机打散切分：15fps 下相邻帧几乎一模一样，随机切会让「第 t 帧在训练集、
    第 t+1 帧在验证集」，验证指标虚高到接近训练损失，等于什么都没验证。
    按时间切后，验证集是模型真正没见过的画面演化。

为什么要同时报「恒等基线」
    horizon=3 时 cos(z_t, z_{t+3}) 本来就很高（帧间相似）。如果只报一个高余弦，
    读者会误以为模型学到了动态，其实「什么都不做」也能拿到这个分数。
    所以每次评测都同时算：
        model      : cos(predictor(z_t), target(z_{t+h}))
        identity   : cos(z_t,              target(z_{t+h}))   ← 直接把当前表征当预测
        random     : cos(predictor(z_t),   target(随机另一帧)) ← 打乱配对的负基线
    只有 model 明显高于 identity，才说明 predictor 真的学到了「往哪变」。

设备
    强制走 MPS（Metal）。启动日志会打印实际设备，验收时可直接核对。
    MPS 上计时前必须 torch.mps.synchronize()，否则测到的是「提交任务的时间」。

内存
    16GB 统一内存，且与另一位队友的模型共用同一块 GPU。batch 默认 16（实测
    每步约 0.30s、显存 ~190MB），不必调大；长跑务必用
    scripts/build-lock.sh run "..." -- 串行化。

用法
    # 冒烟：60 步，验证管线通不通（几十秒）
    python3.11 tools/train_wm_static.py --limit 60

    # 正式训练（放到锁里跑）
    bash scripts/build-lock.sh run "wm-static 训练" -- \
        /usr/local/bin/python3.11 tools/train_wm_static.py --epochs 36

    # 断点续训
    python3.11 tools/train_wm_static.py --resume data/wm_static/ckpt_last.pt
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
import torch
from PIL import Image
from torch.utils.data import DataLoader, Dataset

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))

from wm_static import (  # noqa: E402  （必须在 sys.path 调整之后导入）
    StaticWmConfig,
    StaticWorldModel,
    build_model,
    jepa_loss,
)

# ---------------------------------------------------------------- 归一化契约
# 在 600 帧分层抽样上实测（p1/p2 各 300 帧，2026-11-06）：
#   均值 [0.2717, 0.3074, 0.3251]   标准差 [0.2099, 0.1870, 0.1888]
# 导出脚本与 iOS 侧必须用同一组常数，否则训练/推理分布不一致会静默掉点。
PIXEL_MEAN = (0.2717, 0.3074, 0.3251)
PIXEL_STD = (0.2099, 0.1870, 0.1888)

DATA_DIR = _ROOT / "data" / "video_frames"
OUT_DIR = _ROOT / "data" / "wm_static"


# ---------------------------------------------------------------- 数据集


class FramePairDataset(Dataset):
    """显式的 (当前帧, 目标帧) 帧对数据集。

    为什么数据集的接口是「帧对列表」而不是「帧列表 + horizon」：
        评测集必须跨时间等间隔抽样（否则负基线失效，见 subsample_pairs 注释），
        一旦抽样，列表下标就与真实帧号脱钩。如果还按 index+horizon 取配对，
        抽样间隔 60 就会让预测目标变成 60×8=480 帧（32 秒）后的画面，
        而训练时是 8 帧——评测和训练测的根本不是同一个任务，且**不会报错**。
        把配对在构造期一次性算好、显式传进来，这类错位就不可能发生。

    horizon 的语义（预测未来第几帧）在 make_pairs 里实现，本类只管按对读图。

    为什么不在 __getitem__ 里做随机裁剪/翻转增强：
        水平翻转会让画面「左右镜像」，对一个要学转弯方向的世界模型来说是**错的**
        监督信号（左弯变右弯）。而我们又严禁裁切（会丢画面边缘的障碍信息）。
        所以只用像素归一化，不做几何增强——这是与「不得裁切」约束一致的选择。
    """

    def __init__(
        self,
        pairs: Sequence[Tuple[Path, Path]],
        image_h: int,
        image_w: int,
        mean: Tuple[float, ...] = PIXEL_MEAN,
        std: Tuple[float, ...] = PIXEL_STD,
    ) -> None:
        if not pairs:
            raise ValueError("帧对列表为空 —— 检查数据目录与 horizon 设置")
        self.pairs = list(pairs)
        self.image_h = image_h
        self.image_w = image_w
        self._mean = torch.tensor(mean, dtype=torch.float32).view(3, 1, 1)
        self._std = torch.tensor(std, dtype=torch.float32).view(3, 1, 1)

    def __len__(self) -> int:
        return len(self.pairs)

    def _load(self, path: Path) -> torch.Tensor:
        """读一帧 JPEG → [3,H,W] 归一化浮点张量。

        尺寸校验放在这里而不是信任「数据已准备好」：一旦有人误改了数据目录
        （比如裁成 320x180），要立刻报错而不是让训练在一个错尺寸上跑几小时。
        """
        with Image.open(path) as img:
            arr = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
        if arr.shape[0] != self.image_h or arr.shape[1] != self.image_w:
            raise ValueError(
                f"{path.name} 尺寸 {arr.shape[:2]} 与契约 "
                f"({self.image_h},{self.image_w}) 不符 —— 检查是否有人对帧做了裁切"
            )
        # HWC → CHW，再按通道归一化
        return (torch.from_numpy(arr).permute(2, 0, 1) - self._mean) / self._std

    def __getitem__(self, index: int) -> Tuple[torch.Tensor, torch.Tensor]:
        if index < 0 or index >= len(self.pairs):
            raise IndexError(f"index {index} 超出范围 [0,{len(self.pairs)})")
        now_path, next_path = self.pairs[index]
        return self._load(now_path), self._load(next_path)


def make_pairs(frame_paths: Sequence[Path], horizon: int) -> List[Tuple[Path, Path]]:
    """把连续帧列表变成 (t, t+horizon) 帧对。

    末尾 horizon 帧没有配对的下文，直接排除，避免越界。
    """
    if horizon < 1:
        raise ValueError(f"horizon={horizon} 必须 ≥1")
    paths = list(frame_paths)
    if len(paths) <= horizon:
        raise ValueError(f"帧数 {len(paths)} 不足以构成 horizon={horizon} 的帧对")
    return [(paths[i], paths[i + horizon]) for i in range(len(paths) - horizon)]


def subsample_pairs(
    pairs: Sequence[Tuple[Path, Path]], stride: int, max_items: int = 0
) -> List[Tuple[Path, Path]]:
    """按固定间隔对**已成对的**样本抽样，让评测集跨时间铺开。

    为什么必须这么做（这是实测踩出来的坑，不是理论洁癖）：
        最初评测集直接取「p1 末尾连续 71 帧」≈ 4.7 秒，再用全局置换构造负基线时，
        配到的仍是几秒内的相似画面，于是
            cos_random == cos_model 精确相等（冒烟实测 0.8226/0.8226）
        负基线完全失去判别力，验收项「显著高于随机基线」根本立不住。
        跨时间等间隔抽样后，置换配到的是「几十秒外的另一个场景」，才是真负基线。

    为什么抽的是「对」而不是「帧」：见 FramePairDataset 的注释 —— 先配对再抽样，
    horizon 的物理含义（8 帧 = 0.53 秒）才不会被 stride 放大。

    stride 的选取：p1 验证段约 6000 帧（400 秒），stride=60 → 每 4 秒一个样本、
    约 100 个，既覆盖全时段又便宜（100 帧解码约 3 秒）。
    """
    if stride < 1:
        raise ValueError(f"stride={stride} 必须 ≥1")
    picked = list(pairs)[::stride]
    if max_items > 0:
        picked = picked[:max_items]
    return picked


def split_frame_paths(
    p1_dir: Path, p2_dir: Path, train_ratio: float = 0.8
) -> Tuple[List[Path], List[Path], List[Path]]:
    """按时间顺序切出 train / val / test 三段帧路径。

    返回 (train, val, test)。切分点按**帧比例**落在 p1 内部，
    这样验证集与训练集同源同分布，差异只来自「时间上更靠后」。
    """
    p1 = sorted(p1_dir.glob("*.jpg"))
    p2 = sorted(p2_dir.glob("*.jpg"))
    if not p1 or not p2:
        raise FileNotFoundError(
            f"帧目录为空：{p1_dir}({len(p1)}) / {p2_dir}({len(p2)})"
        )
    if not 0.0 < train_ratio < 1.0:
        raise ValueError(f"train_ratio={train_ratio} 必须在 (0,1)")

    cut = int(len(p1) * train_ratio)
    return p1[:cut], p1[cut:], p2


# ---------------------------------------------------------------- 评测指标


@torch.no_grad()
def evaluate(
    model: StaticWorldModel,
    loader: DataLoader,
    device: torch.device,
    max_batches: Optional[int] = None,
    var_coeff: float = 1.00,
    cov_coeff: float = 0.50,
    mean_coeff: float = 10.0,
    pred_weight: float = 1.0,
) -> Dict[str, float]:
    """在留出数据上算「预测质量」与「表征健康度」两组指标。

    预测质量（余弦，越接近 1 越好）。**原始余弦与去均值余弦都报**，但以去均值为准：
        cos_model / cos_model_c     预测表征 vs 真实未来帧表征
        cos_identity / cos_identity_c  把当前表征直接当预测（关键对照）
        cos_random / cos_random_c   预测表征 vs 置换后的目标表征（负基线）

    为什么必须同时报「去均值」版本（实测教训）：
        训练出的表征里所有帧共享一个很大的公共方向——实测 ||均值||=2.408，
        而单帧特征范数均值才 2.279，也就是「公共偏移」与「真实特征」一样大。
        结果任意两帧的**原始**余弦都 ≈0.93，连随机配对都有 0.93，负基线彻底失去
        判别力（验收项「显著高于随机基线」就变成了一句空话）。
        扣掉整个评测集的均值（参考均值由 now/next 合并估计）后，同一组数据的
        随机基线降到 ≈0.83，恒等基线 0.9995，指标才真正在度量「画面往哪变」。

    表征健康度（防塌缩证据）：
        mean_std     256 维各自 std 的平均值（塌缩 → 接近 0）
        dead_dims    std < 0.05 的维度数量（塌缩 → 接近 256）
        eff_rank     有效秩 = exp(熵(归一化奇异值))，塌缩 → 接近 1
        mean_norm    全局均值的范数 / 单帧范数（越接近 1 说明 DC 偏移越重）
    """
    model.eval()
    preds: List[torch.Tensor] = []
    nows: List[torch.Tensor] = []
    nexts: List[torch.Tensor] = []
    loss_sum = 0.0
    n_batch = 0
    n_loss = 0  # 参与 loss 平均的批次数（排除 batch<2 的尾批）

    for batch_index, (frame_t, frame_next) in enumerate(loader):
        if max_batches is not None and batch_index >= max_batches:
            break
        frame_t = frame_t.to(device, non_blocking=True)
        frame_next = frame_next.to(device, non_blocking=True)

        z_t = model.encode(frame_t)
        z_pred = model.predict_next(z_t)
        z_next = model.encode_target(frame_next)  # 已是 no_grad

        # 尾批可能只有 1 个样本：VICReg 的方差/协方差项需要 batch≥2 才能估计，
        # 这时**跳过 loss 累加**而不是放宽 src/wm_static.py 里的断言——那条断言在
        # 训练侧是必需的（batch=1 时方差恒为 0，损失会退化成常数，训不出东西）。
        # 余弦类指标不受 batch 大小影响，照常累加，所以不影响预测质量评测。
        if z_t.shape[0] >= 2:
            loss, _ = jepa_loss(
                z_t, z_pred, z_next, var_coeff, cov_coeff, mean_coeff, pred_weight
            )
            loss_sum += float(loss)
            n_loss += 1

        # 收集到 CPU，最后一次算完——负基线需要**跨整个评测集**置换，
        # 批内置换在连续视频帧上会退化成「几乎没打乱」（见下方注释）。
        preds.append(z_pred.float().cpu())
        nows.append(z_t.float().cpu())
        nexts.append(z_next.float().cpu())
        n_batch += 1

    if n_batch == 0:
        raise RuntimeError("评测一个 batch 都没跑 —— 检查数据集/limit 设置")

    all_pred = torch.cat(preds, dim=0)   # [N, D]
    all_now = torch.cat(nows, dim=0)     # [N, D]
    all_next = torch.cat(nexts, dim=0)   # [N, D]

    def _cos(a: torch.Tensor, b: torch.Tensor) -> float:
        return float(torch.nn.functional.cosine_similarity(a, b, dim=-1).mean())

    # 参考均值：用「当前帧 + 未来帧」一起估，避免偏向任一侧。
    # 扣掉它以后，余弦度量的是「相对场景平均状态的方向」，而不是被公共偏移主导。
    ref_mean = torch.cat([all_now, all_next], dim=0).mean(dim=0, keepdim=True)
    all_pred_c = all_pred - ref_mean
    all_now_c = all_now - ref_mean
    all_next_c = all_next - ref_mean

    metrics: Dict[str, float] = {
        # 所有批次都小于 2 时（极端情况）标 NaN，而不是除以 0 产生 inf。
        "loss": loss_sum / n_loss if n_loss else float("nan"),
        "cos_model": _cos(all_pred, all_next),
        "cos_identity": _cos(all_now, all_next),
        "cos_model_c": _cos(all_pred_c, all_next_c),
        "cos_identity_c": _cos(all_now_c, all_next_c),
    }

    # ---- 随机负基线：**全局**随机置换，而不是批内 roll ----
    # 为什么必须跨整个评测集：验证集是连续视频片段，相邻帧画面几乎相同。
    # 若只在 batch 内 roll 一位，配对的是「±1 帧」，本质仍是真配对，负基线会
    # 被抬高到和模型分数一模一样（冒烟实测两者精确相等 0.8226/0.8226）。
    # 全局置换 + 跨时间抽稀后，配对的是「几十秒外的另一个场景」，才是真负基线。
    if all_next.shape[0] > 1:
        perm = torch.randperm(all_next.shape[0], generator=torch.Generator().manual_seed(0))
        # 固定种子：基线必须可复现，否则每次评测的随机基线抖动会盖过真实差异。
        metrics["cos_random"] = _cos(all_pred, all_next[perm])
        metrics["cos_random_c"] = _cos(all_pred_c, all_next_c[perm])
    else:
        # 单条样本无法构造负基线，标 NaN 而不是伪造一个数。
        metrics["cos_random"] = float("nan")
        metrics["cos_random_c"] = float("nan")

    # ---- 表征健康度：在整个留出集上拼起来算，比按 batch 算再平均更稳 ----
    std_per_dim = all_now.std(dim=0)
    metrics["mean_std"] = float(std_per_dim.mean())
    metrics["min_std"] = float(std_per_dim.min())
    metrics["max_std"] = float(std_per_dim.max())
    metrics["dead_dims"] = int((std_per_dim < 0.05).sum())
    metrics["eff_rank"] = float(effective_rank(all_now))
    metrics["dim"] = int(all_now.shape[1])
    metrics["n_eval"] = int(all_now.shape[0])
    # 公共偏移有多重：||参考均值|| 与单帧范数的比值。接近 1 说明 DC 分量与真实
    # 特征同量级，原始余弦基本在量「公共方向」，必须以去均值版本为准。
    metrics["mean_norm_ratio"] = float(
        ref_mean.norm() / torch.cat([all_now, all_next], dim=0).norm(dim=-1).mean()
    )
    # 预测相对恒等基线的净增益（去均值版），这是「predictor 真学到东西」的判据。
    metrics["headroom_c"] = metrics["cos_model_c"] - metrics["cos_identity_c"]
    model.train()
    return metrics


def effective_rank(features: torch.Tensor) -> float:
    """有效秩 = exp( 熵(σ_i / Σσ) )。

    为什么用有效秩而不是「矩阵秩」：真实训练里几乎没有哪一维是**严格**恒定的，
    矩阵秩永远是 256，看不出塌缩。有效秩衡量的是「能量实际分布在多少个方向上」：
    若所有样本挤在一条线上，熵接近 0，有效秩接近 1；各向同性时接近 256。
    这是比方差更能揭示「维度退化成陪衬」的指标。
    """
    x = features - features.mean(dim=0, keepdim=True)
    # 用 SVD 的奇异值作为各方向能量。N 可能很大，用 GPU 反而更慢，这里 CPU 足够。
    s = torch.linalg.svdvals(x.double())
    s = s[s > 1e-12]
    if s.numel() <= 1:
        return 1.0
    p = s / s.sum()
    entropy = float(-(p * torch.log(p)).sum())
    return float(math.exp(entropy))


# ---------------------------------------------------------------- 训练主循环


def build_loader(
    dataset: Dataset,
    batch_size: int,
    shuffle: bool,
    num_workers: int,
    drop_last: bool = False,
) -> DataLoader:
    """DataLoader 统一入口。

    num_workers 取 3 而不是 0：JPEG 解码在 CPU（实测约 1900 帧/秒，单进程也能喂饱
    GPU），但解码与 MPS 计算并行能进一步压掉气泡；3 个 worker 在 8 核 M3 上
    不会与 Metal 抢得太过分。
    """
    return DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=shuffle,
        num_workers=num_workers,
        drop_last=drop_last,
        persistent_workers=num_workers > 0,
        prefetch_factor=2 if num_workers > 0 else None,
    )


def cosine_lr(step: int, total_steps: int, warmup: int, base_lr: float, min_lr: float) -> float:
    """线性 warmup + 余弦衰减。

    为什么需要 warmup：EMA target 在最初几百步还很弱，若一开始就用大学习率，
    online 表征剧烈跳动会把 target 带偏，早期的「锚」就失效了。
    """
    if step < warmup:
        return base_lr * (step + 1) / max(1, warmup)
    progress = (step - warmup) / max(1, total_steps - warmup)
    progress = min(1.0, progress)
    return min_lr + 0.5 * (base_lr - min_lr) * (1.0 + math.cos(math.pi * progress))


def ema_momentum(step: int, total_steps: int, start: float, end: float) -> float:
    """EMA momentum 从 start 线性升到 end。

    为什么要「先小后大」：初始 target 随机且弱，需要较快跟随 online 才不至于
    一开始就落后太多；收敛后逐渐变慢，让它成为稳定锚（越小越容易塌缩，越大越稳）。
    """
    progress = min(1.0, step / max(1, total_steps))
    return start + (end - start) * progress


def train(args: argparse.Namespace) -> int:
    # ---- 设备：强制 MPS（本机无 CUDA），并明确打印实际设备供验收 ----
    if torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        # 只有 MPS 完全不可用时才会走到这里（例如在 CI 的纯 CPU 机上做冒烟）。
        # 这不是「默认用 CPU」，而是「没有 GPU 时的兜底」，必须在日志里喊出来。
        device = torch.device("cpu")
        print("⚠️  MPS 不可用，回退 CPU —— 这不是正常训练路径，仅作冒烟兜底")

    seed_everything(args.seed)

    # 冒烟模式的产物写到独立子目录：--limit 只跑几十步，权重毫无价值。若写进
    # 正式目录，既会覆盖真实 checkpoint，也会让 train_log.jsonl 混入假数据，
    # 后面写 report 时无法分辨哪段日志是真的。
    out_dir = OUT_DIR / "smoke" if args.limit else OUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    cfg = StaticWmConfig(horizon=args.horizon)
    model = build_model(cfg).to(device)
    print(f"[设备] device = {device}  (mps_available={torch.backends.mps.is_available()})")
    print(f"[配置] input={cfg.image_h}x{cfg.image_w} latent={cfg.latent_dim} "
          f"horizon={cfg.horizon} batch={args.batch_size}")

    # ---- 数据 ----
    train_paths, val_paths, test_paths = split_frame_paths(
        DATA_DIR / "yt_p1", DATA_DIR / "yt_p2", args.train_ratio
    )
    if args.limit:
        # 冒烟模式：只截断**训练集**，评测集保持完整。
        # 为什么评测集不跟着截断：评测只要 150 对左右、耗时约 5 秒，代价很低；
        # 而一旦把评测集也砍成连续几十帧，抽样跨度会掉到 4 秒，负基线和
        # 「val/test 一致性」这两个核心检查就全都失效了——冒烟结论也就不可信了。
        keep = args.limit * args.batch_size + cfg.horizon + 4
        train_paths = train_paths[:keep]
        print(f"[冒烟] --limit {args.limit}：train 限制为 {len(train_paths)} 帧，"
              f"评测集不截断")

    # 先按连续帧造帧对，再对评测集做跨时间抽样（顺序不能反，见 subsample_pairs）。
    train_pairs = make_pairs(train_paths, cfg.horizon)
    val_pairs = make_pairs(val_paths, cfg.horizon)
    test_pairs = make_pairs(test_paths, cfg.horizon)

    # 训练集保持全部帧对（训练本来就需要密集样本）；
    # 评测集抽稀到跨时间铺开，让随机负基线有意义。
    val_pairs = subsample_pairs(val_pairs, args.eval_stride, args.eval_max)
    test_pairs = subsample_pairs(test_pairs, args.eval_stride, args.eval_max)

    print(f"[数据] train={len(train_pairs)} 对 val={len(val_pairs)} 对 "
          f"test={len(test_pairs)} 对 (p1 前 {args.train_ratio:.0%} / p1 后段 / p2 留出)")
    if val_pairs:
        # 打印首尾帧号，用于人工核对抽样确实跨了很长时间而不是挤在几秒内。
        span = int(val_pairs[-1][0].stem) - int(val_pairs[0][0].stem)
        print(f"[数据] val 抽样跨度 = {span} 帧 ≈ {span / 15:.0f} 秒")

    train_ds = FramePairDataset(train_pairs, cfg.image_h, cfg.image_w)
    val_ds = FramePairDataset(val_pairs, cfg.image_h, cfg.image_w)
    test_ds = FramePairDataset(test_pairs, cfg.image_h, cfg.image_w)

    train_loader = build_loader(
        train_ds, args.batch_size, shuffle=True, num_workers=args.num_workers, drop_last=True
    )
    val_loader = build_loader(
        val_ds, args.batch_size, shuffle=False, num_workers=args.num_workers
    )
    test_loader = build_loader(
        test_ds, args.batch_size, shuffle=False, num_workers=args.num_workers
    )

    steps_per_epoch = args.steps_per_epoch or len(train_loader)
    total_steps = steps_per_epoch * args.epochs

    optimizer = torch.optim.AdamW(
        model.trainable_parameters(), lr=args.lr, weight_decay=args.weight_decay
    )

    start_epoch = 0
    global_step = 0
    best_val = -1e9
    if args.resume:
        start_epoch, global_step, best_val = load_checkpoint(
            args.resume, model, optimizer, device
        )
        print(f"[续训] 从 {args.resume} 恢复：epoch={start_epoch} step={global_step}")

    log_path = out_dir / "train_log.jsonl"
    # 续训时追加，不截断——完整历史是「训练真的跑过」的证据链的一部分。
    log_file = log_path.open("a", encoding="utf-8")

    print(f"[计划] {args.epochs} epochs × {steps_per_epoch} steps = {total_steps} steps，"
          f"当前起点 step={global_step}")

    t_start = time.time()
    for epoch in range(start_epoch, args.epochs):
        model.train()
        epoch_losses: List[float] = []
        t_epoch = time.time()

        for batch_index, (frame_t, frame_next) in enumerate(train_loader):
            if batch_index >= steps_per_epoch:
                break

            lr = cosine_lr(global_step, total_steps, args.warmup, args.lr, args.min_lr)
            for group in optimizer.param_groups:
                group["lr"] = lr

            frame_t = frame_t.to(device, non_blocking=True)
            frame_next = frame_next.to(device, non_blocking=True)

            z_t = model.encode(frame_t)
            z_pred = model.predict_next(z_t)
            # stop-gradient：目标表征 detach 后才进损失，这是防塌缩的第一道闸。
            z_next = model.encode_target(frame_next).detach()

            loss, details = jepa_loss(
                z_t, z_pred, z_next, args.var_coeff, args.cov_coeff,
                args.mean_coeff, args.pred_weight,
            )
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            if args.clip_grad > 0:
                grad_norm = torch.nn.utils.clip_grad_norm_(
                    list(model.trainable_parameters()), args.clip_grad
                )
            else:
                grad_norm = torch.tensor(0.0)
            optimizer.step()

            momentum = ema_momentum(
                global_step, total_steps, args.ema_start, args.ema_end
            )
            model.update_target(momentum)

            epoch_losses.append(details["loss"])
            global_step += 1

            if global_step % args.log_every == 0:
                # 打日志前同步：MPS 是异步提交，不同步的话下一行 print 的耗时
                # 只反映「提交任务」，无法据此判断吞吐是否正常。
                if device.type == "mps":
                    torch.mps.synchronize()
                print(
                    f"[ep {epoch:02d}] step {global_step:6d}/{total_steps} "
                    f"loss={details['loss']:.4f} pred={details['pred']:.4f} "
                    f"cos={details['cos']:.4f} var={details['var']:.4f} "
                    f"cov={details['cov']:.4f} mean={details['mean']:.3f} "
                    f"std={details['mean_std']:.3f} "
                    f"|mu|={details['mean_norm']:.2f} dead={details['dead_dims']} lr={lr:.2e} "
                    f"ema={momentum:.4f} gnorm={float(grad_norm):.2f}"
                )
                log_file.write(json.dumps({
                    "type": "train", "epoch": epoch, "step": global_step,
                    "loss": details["loss"], "pred": details["pred"],
                    "cos": details["cos"], "var": details["var"],
                    "cov": details["cov"], "mean": details["mean"],
                    "mean_std": details["mean_std"],
                    "mean_norm": details["mean_norm"],
                    "dead_dims": details["dead_dims"],
                    "pred_share": details["pred_share"], "lr": lr,
                    "ema": momentum, "grad_norm": float(grad_norm),
                }, ensure_ascii=False) + "\n")
                log_file.flush()

            if args.limit and global_step >= args.limit:
                print(f"[冒烟] 达到 --limit {args.limit}，提前结束")
                break

        # ---- 每轮评测 ----
        metrics = evaluate(
            model, val_loader, device, max_batches=args.eval_batches or None,
            var_coeff=args.var_coeff, cov_coeff=args.cov_coeff,
            mean_coeff=args.mean_coeff, pred_weight=args.pred_weight,
        )
        elapsed = time.time() - t_epoch
        mean_loss = float(np.mean(epoch_losses)) if epoch_losses else float("nan")
        print(
            f"[val ep {epoch:02d}] loss={metrics['loss']:.4f} "
            f"cos_model={metrics['cos_model']:.4f} "
            f"cos_identity={metrics['cos_identity']:.4f} "
            f"cos_random={metrics['cos_random']:.4f} | "
            f"std={metrics['mean_std']:.4f} dead={metrics['dead_dims']} "
            f"eff_rank={metrics['eff_rank']:.1f}/{metrics['dim']} | {elapsed:.0f}s"
        )
        # 去均值版才是可信指标：原始余弦被所有帧共享的公共偏移抬到 0.93+，
        # 连随机配对都很高，无法区分「学到动态」与「什么都不做」。
        print(
            f"           [去均值] model={metrics['cos_model_c']:.4f} "
            f"identity={metrics['cos_identity_c']:.4f} "
            f"random={metrics['cos_random_c']:.4f} "
            f"headroom={metrics['headroom_c']:+.4f} "
            f"|mu|/|z|={metrics['mean_norm_ratio']:.2f}"
        )
        log_file.write(json.dumps({
            "type": "val", "epoch": epoch, "step": global_step,
            "train_loss_mean": mean_loss, **metrics,
            "epoch_seconds": round(elapsed, 1),
        }, ensure_ascii=False) + "\n")
        log_file.flush()

        # 用「超出恒等基线的幅度」选最优模型：单看 cos_model 会被「高基线」骗，
        # 真正有价值的是 predictor 相对「什么都不做」多出来的那部分。
        headroom = metrics["headroom_c"]
        is_best = headroom > best_val
        if is_best:
            best_val = headroom

        save_checkpoint(
            out_dir / "ckpt_last.pt", model, optimizer, epoch + 1, global_step,
            best_val, cfg, args,
        )
        if is_best:
            save_checkpoint(
                out_dir / "ckpt_best.pt", model, optimizer, epoch + 1, global_step,
                best_val, cfg, args,
            )
            print(f"  ↑ 新的最优（cos 超出恒等基线 {headroom:+.4f}）")

        # 每轮结束回收 MPS 缓存：16GB 统一内存要和另一位队友的模型共用，
        # 长时间训练里评测/训练的临时缓冲会累积，主动归还比减小 batch 更划算。
        if device.type == "mps":
            torch.mps.empty_cache()

        if args.limit and global_step >= args.limit:
            break

    # ---- 结束时在留出测试集（p2）上做最终评测 ----
    print("\n[最终] 在留出测试集 p2 上评测（模型从未见过这段视频）")
    final = evaluate(
        model, test_loader, device, max_batches=args.eval_batches or None,
        var_coeff=args.var_coeff, cov_coeff=args.cov_coeff,
        mean_coeff=args.mean_coeff, pred_weight=args.pred_weight,
    )
    print(
        f"[test] loss={final['loss']:.4f} "
        f"cos_model={final['cos_model']:.4f} "
        f"cos_identity={final['cos_identity']:.4f} "
        f"cos_random={final['cos_random']:.4f} | "
        f"std={final['mean_std']:.4f} dead={final['dead_dims']} "
        f"eff_rank={final['eff_rank']:.1f}/{final['dim']} n={final['n_eval']}"
    )
    print(
        f"       [去均值] model={final['cos_model_c']:.4f} "
        f"identity={final['cos_identity_c']:.4f} "
        f"random={final['cos_random_c']:.4f} "
        f"headroom={final['headroom_c']:+.4f} "
        f"|mu|/|z|={final['mean_norm_ratio']:.2f}"
    )
    log_file.write(json.dumps({"type": "test", **final}, ensure_ascii=False) + "\n")
    log_file.close()

    # 验证集与测试集指标都落盘，供 report.md 引用（不手抄数字，避免写错）。
    summary = {
        "device": str(device),
        "params_deploy": int(sum(p.numel() for p in model.online.parameters())
                             + sum(p.numel() for p in model.predictor.parameters())),
        "horizon": cfg.horizon,
        "global_step": global_step,
        "train_seconds": round(time.time() - t_start, 1),
        "best_headroom": best_val,
        "test": final,
    }
    (out_dir / "train_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n[完成] 总耗时 {(time.time() - t_start) / 60:.1f} 分钟，"
          f"摘要写入 {out_dir / 'train_summary.json'}")
    return 0


# ---------------------------------------------------------------- 存取


def save_checkpoint(
    path: Path,
    model: StaticWorldModel,
    optimizer: torch.optim.Optimizer,
    epoch: int,
    global_step: int,
    best_val: float,
    cfg: StaticWmConfig,
    args: argparse.Namespace,
) -> None:
    """保存断点。cfg 一起存，续训/导出时才能确认结构没被改过。"""
    torch.save(
        {
            "online": model.online.state_dict(),
            "predictor": model.predictor.state_dict(),
            "target": model.target.state_dict(),
            "optimizer": optimizer.state_dict(),
            "epoch": epoch,
            "global_step": global_step,
            "best_val": best_val,
            "cfg": asdict(cfg),
            "args": vars(args),
        },
        path,
    )


def load_checkpoint(
    path: Path,
    model: StaticWorldModel,
    optimizer: torch.optim.Optimizer,
    device: torch.device,
) -> Tuple[int, int, float]:
    """恢复断点，并校验结构超参一致。

    为什么要校验 cfg：如果续训时改了宽度或 horizon，state_dict 的键/形状会不匹配
    或语义错位（比如 horizon 变了但 target 还是按旧跨度学的），必须直接报错。
    """
    if not Path(path).exists():
        raise FileNotFoundError(f"断点不存在：{path}")
    ckpt = torch.load(path, map_location=device, weights_only=False)

    saved = StaticWmConfig(**{k: tuple(v) if isinstance(v, list) else v
                              for k, v in ckpt["cfg"].items()})
    current = model.cfg
    if saved != current:
        raise ValueError(
            f"断点结构 {saved} 与当前配置 {current} 不一致 —— 拒绝续训，"
            f"请用同样的超参或从零开始"
        )

    model.online.load_state_dict(ckpt["online"])
    model.predictor.load_state_dict(ckpt["predictor"])
    model.target.load_state_dict(ckpt["target"])
    optimizer.load_state_dict(ckpt["optimizer"])
    return int(ckpt["epoch"]), int(ckpt["global_step"]), float(ckpt["best_val"])


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    # MPS 的随机数由 torch.manual_seed 统一管理，无需额外设置。


# ---------------------------------------------------------------- CLI


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="训练静态世界模型（JEPA，无动作标签）")
    p.add_argument("--epochs", type=int, default=36, help="训练轮数")
    p.add_argument("--steps-per-epoch", type=int, default=400,
                   help="每轮步数（0=按数据集长度，通常太大）")
    p.add_argument("--batch-size", type=int, default=16,
                   help="16GB 统一内存下 16 是稳妥值；实测每步约 0.30s")
    p.add_argument("--lr", type=float, default=3e-4, help="峰值学习率")
    p.add_argument("--min-lr", type=float, default=1e-5, help="余弦衰减下界")
    p.add_argument("--warmup", type=int, default=300, help="线性 warmup 步数")
    p.add_argument("--weight-decay", type=float, default=0.05)
    p.add_argument("--clip-grad", type=float, default=5.0, help="梯度范数裁剪，0=关闭")
    p.add_argument("--ema-start", type=float, default=0.990)
    p.add_argument("--ema-end", type=float, default=0.999)
    p.add_argument("--var-coeff", type=float, default=1.00,
                   help="VICReg 方差项权重（实测反推，见 src/wm_static.py jepa_loss 注释）")
    p.add_argument("--cov-coeff", type=float, default=0.50,
                   help="VICReg 协方差项权重（治各维共线，实测 eff_rank 仅 3/256）")
    p.add_argument("--mean-coeff", type=float, default=10.0,
                   help="一阶矩（DC 偏移）约束权重；见 vicreg_terms 的 mean_coeff 说明")
    p.add_argument("--pred-weight", type=float, default=1.00,
                   help="预测项权重：实测 pred 原始量级远小于 var/cov，不放大就会被淹没")
    p.add_argument("--horizon", type=int, default=8,
                   help="预测未来第几帧（15fps）。默认 8≈0.53s，见 StaticWmConfig.horizon")
    p.add_argument("--train-ratio", type=float, default=0.8, help="p1 中训练集占比")
    p.add_argument("--num-workers", type=int, default=3)
    p.add_argument("--log-every", type=int, default=25, help="每隔多少步打一行日志")
    p.add_argument("--eval-batches", type=int, default=0, help="评测最多跑几个 batch（0=全部）")
    p.add_argument("--eval-stride", type=int, default=60,
                   help="评测集按帧对抽样间隔，让负基线跨时间（见 subsample_pairs）")
    p.add_argument("--eval-max", type=int, default=150,
                   help="评测集最多样本数（0=不限）")
    p.add_argument("--limit", type=int, default=0, help="冒烟模式：只跑 N 步")
    p.add_argument("--resume", type=str, default="", help="断点路径")
    p.add_argument("--seed", type=int, default=1234)
    args = p.parse_args(argv)

    if args.batch_size < 2:
        # VICReg 需要 batch≥2 才能估方差，batch=1 会直接抛错，提前拦下更清楚。
        p.error("--batch-size 必须 ≥2（VICReg 需要在 batch 内估方差）")
    if args.steps_per_epoch <= 0:
        args.steps_per_epoch = 0  # 交给主循环用 len(train_loader)
    return args


if __name__ == "__main__":
    sys.exit(train(parse_args()))
