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
    因此本脚本按 **macro recall（各类召回的算术平均）** 选最佳 epoch，
    并在日志里打印逐类召回与混淆矩阵对角。

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
import json
import math
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

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
    vertical_from_keys,
)
from model_v3 import V3Loss, build_v3_model  # noqa: E402

# 复用 train_mono 的既有实现（只读导入，不修改原文件）
from src.train_mono import CosineWithWarmup, build_adamw_optimizer  # noqa: E402

#: 默认 checkpoint 目录：**新目录**，绝不覆盖 m9_mono / m9_v2 等现有目录
DEFAULT_CKPT_DIR = _ROOT / "checkpoints" / "v3"


# ----------------------------------------------------------------------------
# 设备 / AMP
# ----------------------------------------------------------------------------

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
    权重冻结（train_mono.py 已踩过该坑），故 MPS 一律纯 fp32。
    """
    if device in ("cpu", "mps"):
        return False
    return use_amp


# ----------------------------------------------------------------------------
# 类权重（必须由真实数据统计得到，不允许拍脑袋）
# ----------------------------------------------------------------------------

def compute_class_stats(dataset: V3KeyDataset) -> Dict[str, object]:
    """遍历数据集，统计各头正负样本数与方向类别分布。

    为什么必须有这一步：`03-output-head.md` §5 实测「永远输出 W」准确率 80.8%，
    但 S 类一帧不输出。类权重与 pos_weight 必须按真实比例算，否则模型会坍缩到
    多数类，而总准确率看起来还很高。

    Returns:
        dict: vertical_counts[3] / horizontal_counts[3] / 各键正例率
    """
    vert = [0, 0, 0]
    horiz = [0, 0, 0]
    positives = {k: 0 for k in ("shift", "space", "super_brake", "ultimate_brake")}
    total = 0

    for clip, frame_idx in dataset.index:
        row = dataset._rows_cache[clip][frame_idx]
        w, a, s, d = (_bit(row, k) for k in ("w", "a", "s", "d"))
        vert[vertical_from_keys(w, s)] += 1
        horiz[horizontal_from_keys(a, d)] += 1
        for k in positives:
            positives[k] += _bit(row, k)
        total += 1

    if total == 0:
        raise RuntimeError("数据集为空，无法统计类权重")

    return {"vertical": vert, "horizontal": horiz,
            "positives": positives, "total": total}


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

@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, crit: V3Loss,
             device: str) -> Tuple[float, Dict[str, float]]:
    """验证集评估：返回 (总损失, 指标 dict)。

    指标里最重要的是 `vertical_recall` / `horizontal_recall`（macro recall）——
    模型选择看它，不看准确率。理由见模块 docstring。
    """
    model.eval()
    totals = {"loss": 0.0, "n": 0}
    # 方向头的混淆计数：[3,3]
    conf_v = torch.zeros(3, 3, dtype=torch.long)
    conf_h = torch.zeros(3, 3, dtype=torch.long)

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

        pv = out["vertical"].argmax(-1).cpu()
        tv = batch["vertical"].cpu()
        for t, p in zip(tv.tolist(), pv.tolist()):
            conf_v[t, p] += 1

        ph = out["horizontal"].argmax(-1).cpu()
        th = batch["horizontal"].cpu()
        for t, p in zip(th.tolist(), ph.tolist()):
            conf_h[t, p] += 1

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
    metrics["select"] = (metrics["vertical_recall"] + metrics["horizontal_recall"]) / 2
    # 逐类召回（日志用；某类 support=0 时记 -1 表示本次验证集无该类）
    for c, name in enumerate(("W", "NONE", "S")):
        sup = int(conf_v[c].sum())
        metrics[f"recall_v_{name}"] = float(conf_v[c, c]) / sup if sup else -1.0
    for c, name in enumerate(("A", "NONE", "D")):
        sup = int(conf_h[c].sum())
        metrics[f"recall_h_{name}"] = float(conf_h[c, c]) / sup if sup else -1.0
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
    val_ratio: float = 0.1,
    device: str = "auto",
    num_workers: int = 0,
    ckpt_dir: Optional[str] = None,
    limit: Optional[int] = None,
    seed: int = 42,
    warmup_ratio: float = 0.05,
) -> Dict[str, object]:
    """训练 V3 模型。

    Args:
        clips_dir:  `data/raw_clips` 之类，内含 clip_*/frames + controls.csv
        epochs:     训练轮数
        batch_size: 批大小（MPS 内存有限，默认 8）
        lr:         学习率（沿用项目 3e-4）
        weight_decay: AdamW 权重衰减（沿用项目 5e-4）
        val_ratio:  验证集比例（按 clip 划分）
        device:     auto / mps / cuda / cpu
        num_workers: DataLoader 进程数（0 = 主进程，MPS 下更稳）
        ckpt_dir:   checkpoint 目录（默认 checkpoints/v3）
        limit:      只取前 N 个样本（冒烟测试用，None = 全量）
        seed:       随机种子
        warmup_ratio: warmup 占总步数的比例

    Returns:
        汇总 dict（含 best 指标与 checkpoint 路径）
    """
    torch.manual_seed(seed)
    dev = resolve_device(device)
    print(f"[V3Train] 设备={dev}")

    base = V3KeyDataset(clips_dir)
    if limit is not None and limit < len(base):
        # 冒烟测试：**原地截断 index**，不包 Subset。
        # 为什么不用 Subset：make_train_val_split 与 compute_class_stats 都读
        # `dataset.index`，Subset 没有该属性，包一层就得分叉出两套代码路径
        # —— 第一版正是这么写的，结果 --limit 实际没生效（日志说 40 个样本，
        #    划分出来却是全量 153 个）。截断 index 只改一处，三处消费方全一致。
        del base.index[limit:]
        print(f"[V3Train] ⚠ 冒烟模式：只用前 {limit} 个样本")

    train_ds, val_ds = make_train_val_split(base, val_ratio=val_ratio, seed=seed)

    # 类别统计与权重（在**训练集**上统计，避免用验证集信息选权重）
    stats = compute_class_stats(base)
    print(f"[V3Train] 类分布: vertical={stats['vertical']} "
          f"horizontal={stats['horizontal']} "
          f"正例率={ {k: round(v / stats['total'], 4) for k, v in stats['positives'].items()} }")

    v_w = _inverse_freq_weights(stats["vertical"])
    h_w = _inverse_freq_weights(stats["horizontal"])
    pos = stats["positives"]
    n = stats["total"]

    # ⚠️ 零正例检查：某些键可能在整批数据里一次都没按过（例如用户还没用过
    #    超级刹车）。此时 pos_weight = n/1 很大，但**没有正例可学**，该头训练后
    #    必然永远输出 0，loss 却看起来"很正常"。这属于必须显式报警的静默失效，
    #    不能让人以为这个头已经训好了。
    dead_heads = [k for k, v in pos.items() if v == 0]
    if dead_heads:
        print("=" * 72)
        print(f"[V3Train] 🚨 以下输出头在训练数据中**没有任何正例**，无法学习：{dead_heads}")
        print("           它们训练后将永远输出 0（loss 正常但功能不存在）。")
        print("           若这不是预期，请补录包含这些按键（Shift+空格 / Shift+空格+S）的数据。")
        print("=" * 72)

    print(f"[V3Train] vertical 类权重={v_w.tolist()}  horizontal 类权重={h_w.tolist()}")
    print(f"[V3Train] pos_weight: handbrake={_pos_weight(pos['shift'], n):.2f} "
          f"brake={_pos_weight(pos['space'], n):.2f} "
          f"super={_pos_weight(pos['super_brake'], n):.2f} "
          f"ultimate={_pos_weight(pos['ultimate_brake'], n):.2f}")

    crit = V3Loss(
        vertical_weights=v_w.to(dev),
        horizontal_weights=h_w.to(dev),
        pos_weight_handbrake=_pos_weight(pos["shift"], n),
        pos_weight_brake=_pos_weight(pos["space"], n),
        pos_weight_super=_pos_weight(pos["super_brake"], n),
        pos_weight_ultimate=_pos_weight(pos["ultimate_brake"], n),
        enable_ccm=False,   # ⚠️ 见模块 docstring：模型 forward 不返回 ccm
        enable_intent=True,
    )
    # ⚠️ 必须整体搬设备：V3Loss 的类权重与 4 个 pos_weight 都是 register_buffer
    #    （model_v3.py:1218-1233）。只把预测搬到 MPS 而判据留在 CPU，会在
    #    BCEWithLogits 里报 "Expected all tensors to be on the same device"
    #    —— 冒烟实跑抓到的第一个崩溃就是这个。.to() 会一并搬运所有 buffer。
    crit = crit.to(dev)

    model = build_v3_model(deploy=False).to(dev)
    print(f"[V3Train] 参数量: {sum(p.numel() for p in model.parameters()):,}")

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

        print(f"[{epoch:3d}/{epochs}] train={train_loss:.4f} val={val_loss:.4f} "
              f"macroR(v/h)={vm['vertical_recall']:.3f}/{vm['horizontal_recall']:.3f} "
              f"select={vm['select']:.4f} | "
              f"S召回={vm['recall_v_S']:.2f} D召回={vm['recall_h_D']:.2f} "
              f"A召回={vm['recall_h_A']:.2f} | {elapsed:.0f}s")
        # 安全项单独一行。⚠️ 缺席时打印「未计算」而不是 0.0：
        #   两者含义完全不同（0 = 算出来就是 0，没有任何违规；未计算 = 这一项没参与训练），
        #   混为一谈会让人误以为防侧翻约束在工作。
        n_batches = max(len(train_loader), 1)
        coh_txt = (f"{run_parts['coh'] / n_batches:.4f}"
                   if "coh" in run_parts else "未计算(无四键头)")
        roll_txt = (f"{run_parts['rollover'] / n_batches:.4f}"
                    if "rollover" in run_parts else "未计算(无车速)")
        print(f"          安全项 L_coh={coh_txt} L_rollover={roll_txt}")

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
                "config": {"dim": 256, "heads": 8, "stage1_depth": 5, "stage2_depth": 6},
            }, ckpt_path / "best_model.pt")
            print(f"  ★ 新最佳 macro_recall={best_select:.4f} → {ckpt_path / 'best_model.pt'}")

    summary = {
        "device": dev, "epochs": epochs, "best_epoch": best_epoch,
        "best_select": best_select, "ckpt": str(ckpt_path / "best_model.pt"),
        "class_stats": stats, "history": history,
    }
    (ckpt_path / "train_v3_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[完成] 最佳 epoch={best_epoch} macro_recall={best_select:.4f} "
          f"→ {ckpt_path / 'best_model.pt'}")
    return summary


def main() -> None:
    ap = argparse.ArgumentParser(description="V3 离散按键模型训练")
    ap.add_argument("--clips", required=True, help="录制数据目录（含 clip_* 子目录）")
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--weight-decay", type=float, default=5e-4)
    ap.add_argument("--val-ratio", type=float, default=0.1)
    ap.add_argument("--device", default="auto", choices=["auto", "mps", "cuda", "cpu"])
    ap.add_argument("--num-workers", type=int, default=0)
    ap.add_argument("--ckpt-dir", default=None)
    ap.add_argument("--limit", type=int, default=None, help="只取前 N 个样本（冒烟测试）")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    train(
        clips_dir=args.clips, epochs=args.epochs, batch_size=args.batch_size,
        lr=args.lr, weight_decay=args.weight_decay, val_ratio=args.val_ratio,
        device=args.device, num_workers=args.num_workers, ckpt_dir=args.ckpt_dir,
        limit=args.limit, seed=args.seed,
    )


if __name__ == "__main__":
    main()
