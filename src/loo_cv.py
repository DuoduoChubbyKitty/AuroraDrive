#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""loo_cv.py — V3 留一交叉验证（Leave-One-Clip-Out），用于**估计泛化能力**。

定位（务必分清）：
    · 本脚本**不是**生产训练入口。生产训练用 `src/train_v3.py`。
    · 本脚本的产物是「泛化估计」：每个 clip 轮流做一次验证集，其余 10 个训练，
      跑短轮（默认 4 轮），汇总 11 折的 macro recall / S 召回 / 误刹车帧数。
      它回答的是「这个模型架构/配置在**没见过的驾驶片段**上大概什么水平」，
      而不是「上线该用哪一版权重」。

为什么值得单独写（而不是复用 train_v3.py 的固定划分）：
    固定 0.2 划分只留 2 个 clip 做验证，一次划分的方差很大（抽到哪两个片段
    全看运气）。留一交叉验证让 11 个 clip 每个都当一次验证，数据利用率更高、
    估计更稳 —— 这正是 Lead 指出的「泛化估计的主要依据」。

为什么用短轮（默认 4 轮）而不是训到收敛：
    11 折 × 收敛轮数在本地 CPU/MPS 上要跑很久。这里要的是「相对泛化水平」
    的估计，不是最终模型；短轮足以暴露「是否严重过拟合 / 是否某类召回崩掉」。
    若要更准，可用 --epochs 调大，但请自觉保证单折训练能跑完。

用法：
    # 只看计划（11 折怎么分、每折验证集类分布），不训练
    python3 src/loo_cv.py --clips data/lean_clips --dry-run

    # 本地 CPU 快速冒烟：只跑前 2 折、每折每集最多 64 样本、1 轮
    python3 src/loo_cv.py --clips data/lean_clips --device cpu --epochs 1 \
        --limit 64 --folds 2 --batch-size 4 --num-workers 0

    # 完整 11 折（耗时，按需在 GPU/MPS 上跑）
    python3 src/loo_cv.py --clips data/lean_clips --device mps --epochs 4

⚠️ `data/lean_clips` 是符号链接（指向外置卷）。V3KeyDataset 用 Path.iterdir() 读，
   会跟随符号链接，无需 `find -L`；本脚本也不自己遍历文件系统，一律走 Dataset。

⚠️ 关于逐帧 mask（modifier_valid）：
   pos_weight 与制动指标都只在 modifier_valid=1 的可信帧上统计（与 train_v3.py、
   model_v3.V3Loss 的口径一致）。卡键段的 shift/space 是录制故障值，不能当真值。
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import torch
from torch.utils.data import DataLoader, Subset

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))
sys.path.insert(0, str(_ROOT))

from dataset_v3 import (  # noqa: E402
    ATOMIC_KEYS,
    V3KeyDataset,
    _bit,
    horizontal_from_keys,
    vertical_from_keys,
)
from model_v3 import V3Loss, build_v3_model  # noqa: E402
# 复用 train_v3 的既有实现（只读导入，不改它）：
#   · compute_class_stats      —— 训练子集 + modifier_valid 过滤后的类统计（本次任务 1 的成果）
#   · _sqrt_inverse_freq_weights / _pos_weight —— 权重口径与生产训练一致
#   · evaluate                 —— 六键指标（macro recall / S 召回 / 误刹车 / 漏刹车）
#   · resolve_device           —— 设备选择
from train_v3 import (  # noqa: E402
    _pos_weight,
    _sqrt_inverse_freq_weights,
    compute_class_stats,
    evaluate,
    resolve_device,
)
# 复用 train_mono 的既有实现（只读导入）
from src.train_mono import CosineWithWarmup, build_adamw_optimizer  # noqa: E402


def _clip_sample_counts(dataset: V3KeyDataset) -> Dict[Path, int]:
    counts: Dict[Path, int] = {}
    for clip, _ in dataset.index:
        counts[clip] = counts.get(clip, 0) + 1
    return counts


def _clip_vertical_counts(dataset: V3KeyDataset, clip: Path) -> List[int]:
    """某 clip 的 vertical 三类样本数 [W, NONE, S]（判断该折验证集是否覆盖各类）。"""
    counts = [0, 0, 0]
    for c, frame_idx in dataset.index:
        if c != clip:
            continue
        row = dataset._rows_cache[c][frame_idx]
        counts[vertical_from_keys(_bit(row, "w"), _bit(row, "s"))] += 1
    return counts


def build_loo_folds(dataset: V3KeyDataset) -> List[Dict[str, object]]:
    """构造留一交叉验证的各折计划（纯数据，不训练）。

    每折 = 1 个 held-out 验证 clip + 其余全部训练 clip。
    index 里出现的 clip 就是「有效 clip」（空壳 clip 因无样本不在 index 中）。
    """
    counts = _clip_sample_counts(dataset)
    clips = sorted(counts)
    folds: List[Dict[str, object]] = []
    for held in clips:
        train_idx = [i for i, (c, _) in enumerate(dataset.index) if c != held]
        val_idx = [i for i, (c, _) in enumerate(dataset.index) if c == held]
        folds.append({
            "held_out": held,
            "train_idx": train_idx,
            "val_idx": val_idx,
            "train_samples": len(train_idx),
            "val_samples": len(val_idx),
            "val_vertical": _clip_vertical_counts(dataset, held),
        })
    return folds


def _print_fold_plan(folds: List[Dict[str, object]]) -> None:
    print(f"[LOO] 共 {len(folds)} 折（每折留 1 个 clip 做验证，其余训练）")
    print(f"{'fold':>4}  {'held-out clip':26s} {'val':>6} {'train':>7}  "
          f"{'val W/NONE/S':>16}  告警")
    for i, f in enumerate(folds, 1):
        w, n, s = f["val_vertical"]
        warns = []
        if s == 0:
            warns.append("验证集无 S（S 召回不可估）")
        elif s < 50:
            warns.append(f"验证集 S 仅 {s}（召回方差大）")
        if n < 50:
            warns.append(f"验证集 NONE 仅 {n}")
        print(f"{i:>4}  {f['held_out'].name:26s} {f['val_samples']:>6} "
              f"{f['train_samples']:>7}  {w:>6}/{n}/{s}")
        if warns:
            print(f"        ⚠ {'；'.join(warns)}")


def _train_one_fold(
    dataset: V3KeyDataset,
    fold: Dict[str, object],
    epochs: int,
    batch_size: int,
    lr: float,
    weight_decay: float,
    device: str,
    num_workers: int,
    seed: int,
    warmup_ratio: float,
    limit: Optional[int],
) -> Dict[str, object]:
    """在一折上训练短轮并返回该折的验证指标。

    为什么这里复制一小段训练循环，而不去调用 train_v3.train()：
        train_v3.train() 内部固定调用分层划分、保存 best_model.pt、训练后回滚，
        这些对「生产训练」是对的，但 LOO 每折的验证 clip 是**外部指定**的、
        且不应覆盖 checkpoint。把 train() 改造成「可注入划分」会动到生产主路径
        （还牵连 --vram-cache 分支），风险大于收益。故此处保留一个小而清晰的
        循环，只复用真正无副作用的部件（统计/权重/evaluate/建模）。
    """
    torch.manual_seed(seed)
    dev = resolve_device(device)

    train_idx = list(fold["train_idx"])
    val_idx = list(fold["val_idx"])
    if limit is not None:
        # --limit 只用于本地冒烟：每折每集各截断到 N 个样本（不打乱，取前 N）。
        # 为什么 val 也截断：某些验证 clip 有几千帧，CPU 上逐帧解码很慢。
        train_idx = train_idx[:limit]
        val_idx = val_idx[:limit]

    train_ds = Subset(dataset, train_idx)
    val_ds = Subset(dataset, val_idx)

    # 统计与权重：只在**本折训练子集**上、且 pos_weight 只数 modifier_valid=1 的帧
    stats = compute_class_stats(
        dataset, samples=[dataset.index[i] for i in train_idx])
    n_valid = stats["modifier_valid_total"]
    positives = stats["positives"]
    if n_valid == 0:
        raise RuntimeError(
            f"折 {fold['held_out'].name}: 训练子集没有有效帧（modifier_valid=1），无法训练")

    v_w = _sqrt_inverse_freq_weights(stats["vertical"]).to(dev)
    h_w = _sqrt_inverse_freq_weights(stats["horizontal"]).to(dev)
    crit = V3Loss(
        vertical_weights=v_w,
        horizontal_weights=h_w,
        pos_weight_handbrake=_pos_weight(positives["handbrake"], n_valid),
        pos_weight_brake=_pos_weight(positives["brake"], n_valid),
        pos_weight_super=_pos_weight(positives["super_brake"], n_valid),
        pos_weight_ultimate=_pos_weight(positives["ultimate"], n_valid),
        enable_ccm=False,
        enable_intent=True,
    ).to(dev)

    model = build_v3_model(deploy=False).to(dev)
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

    last_metrics: Dict[str, float] = {}
    for epoch in range(1, epochs + 1):
        model.train()
        for batch in train_loader:
            batch = {k: v.to(dev) for k, v in batch.items()}
            optimizer.zero_grad(set_to_none=True)
            out = model(image_hi=batch["image_hi"], image_lo=batch["image_lo"],
                        lane=batch["lane"], dets=batch["dets"],
                        det_mask=batch["det_mask"],
                        vehicle_state=batch["vehicle_state"], return_intent=True)
            loss, _ = crit(out, batch)
            if not torch.isfinite(loss):
                raise RuntimeError(
                    f"折 {fold['held_out'].name} 第 {epoch} 轮出现非有限损失 {loss.item()}")
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()
            sched.step()
        _, last_metrics = evaluate(model, val_loader, crit, dev)

    return {"metrics": last_metrics, "train_samples": len(train_ds),
            "val_samples": len(val_ds), "valid_train_frames": n_valid}


def _mean_std(values: List[float]) -> Tuple[float, float, int]:
    """返回 (均值, 标准差, 有效样本数)；跳过 NaN 与 -1 哨兵（无法估计的折）。"""
    usable = [v for v in values if v is not None and not math.isnan(v) and v != -1.0]
    if not usable:
        return float("nan"), float("nan"), 0
    if len(usable) == 1:
        return usable[0], 0.0, 1
    return statistics.mean(usable), statistics.stdev(usable), len(usable)


def run_loo(
    clips_dir: str,
    epochs: int = 4,
    batch_size: int = 8,
    lr: float = 3e-4,
    weight_decay: float = 5e-4,
    device: str = "auto",
    num_workers: int = 0,
    seed: int = 42,
    warmup_ratio: float = 0.1,
    limit: Optional[int] = None,
    max_folds: Optional[int] = None,
    out_path: Optional[str] = None,
    dry_run: bool = False,
    keep_all_zero: bool = False,
) -> Dict[str, object]:
    # keep_all_zero=True → 不剔除六键全零帧，与 train_v3.py 的同名开关口径一致。
    # 默认 False 保持历史行为（训练/LOO 都剔除全零帧）。
    base = V3KeyDataset(clips_dir, skip_all_zero=not keep_all_zero)
    folds = build_loo_folds(base)
    if max_folds is not None:
        folds = folds[:max_folds]

    if dry_run:
        _print_fold_plan(folds)
        print("\n[LOO] --dry-run：只打印计划，不训练、不建模型。")
        return {"dry_run": True, "n_folds": len(folds)}

    print(f"[LOO] 设备={resolve_device(device)}  折数={len(folds)}  "
          f"每折轮数={epochs}  每集上限={limit}")
    results: List[Dict[str, object]] = []
    t0 = time.time()
    for i, fold in enumerate(folds, 1):
        fs = time.time()
        r = _train_one_fold(
            base, fold, epochs=epochs, batch_size=batch_size, lr=lr,
            weight_decay=weight_decay, device=device, num_workers=num_workers,
            seed=seed, warmup_ratio=warmup_ratio, limit=limit)
        m = r["metrics"]
        rec = {
            "fold": i,
            "held_out": fold["held_out"].name,
            "val_samples": r["val_samples"],
            "train_samples": r["train_samples"],
            "macro_recall": m["macro_recall"],
            "s_recall": m["s_recall"],
            "s_false_pos": m["s_false_pos"],
            "s_false_neg": m["s_false_neg"],
            "space_false_pos": m["space_false_pos"],
            "brake_quality": m["brake_quality"],
            "select": m["select"],
            "val_vertical": fold["val_vertical"],
            "elapsed_s": round(time.time() - fs, 1),
        }
        results.append(rec)
        # 不可估的分量（-1.0 哨兵：该折验证集无 S / 无 Space 正例）打印成「不可估」
        bq_txt = "不可估" if m["brake_quality"] < 0 else f"{m['brake_quality']:.3f}"
        sr_txt = "不可估" if m["s_recall"] < 0 else f"{m['s_recall']:.3f}"
        print(f"[fold {i:2d}/{len(folds)}] {fold['held_out'].name:26s} "
              f"macroR={m['macro_recall']:.3f} S召回={sr_txt} "
              f"S假阳性={m['s_false_pos']:5d} 漏刹车={m['s_false_neg']:5d} "
              f"brakeQ={bq_txt} ({rec['elapsed_s']}s)")

    # ── 汇总：均值 ± 标准差（跨折），跳过无法估计的折 ──
    def col(key):
        return [r[key] for r in results]

    summary = {}
    for key in ("macro_recall", "s_recall", "s_false_pos", "s_false_neg",
                "space_false_pos", "brake_quality", "select"):
        mu, sd, k = _mean_std([float(x) for x in col(key)])
        summary[key] = {"mean": mu, "std": sd, "n_folds_used": k}

    print("\n" + "=" * 72)
    print("[LOO] 交叉验证汇总（跨折均值 ± 标准差）")
    for key, label in (("macro_recall", "方向 macro recall"),
                       ("s_recall", "S 召回"),
                       ("s_false_pos", "S 假阳性帧数"),
                       ("s_false_neg", "漏刹车帧数"),
                       ("space_false_pos", "Space 假阳性帧数"),
                       ("brake_quality", "制动质量 brakeQ"),
                       ("select", "综合 select")):
        v = summary[key]
        if v["n_folds_used"] == 0:
            print(f"  {label:20s} = 无法估计（所有折该类 support=0）")
        else:
            print(f"  {label:20s} = {v['mean']:.4f} ± {v['std']:.4f} "
                  f"(用 {v['n_folds_used']}/{len(results)} 折)")
    print("=" * 72)
    print(f"[LOO] 总耗时 {time.time() - t0:.0f}s")

    out = {"device": resolve_device(device), "epochs": epochs,
           "limit": limit, "folds": results, "summary": summary}
    if out_path:
        Path(out_path).write_text(
            json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[LOO] 结果已写入 {out_path}")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="V3 留一交叉验证（泛化估计，非生产训练）")
    ap.add_argument("--clips", required=True, help="录制数据目录（含 clip_* 子目录）")
    ap.add_argument("--epochs", type=int, default=4, help="每折训练轮数（短轮，默认 4）")
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--weight-decay", type=float, default=5e-4)
    ap.add_argument("--device", default="auto", choices=["auto", "mps", "cuda", "npu", "cpu"])
    ap.add_argument("--num-workers", type=int, default=0)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--warmup-ratio", type=float, default=0.1)
    ap.add_argument("--limit", type=int, default=None,
                    help="每折每集截断到前 N 个样本（本地 CPU 冒烟用）")
    ap.add_argument("--folds", type=int, default=None,
                    help="只跑前 K 折（冒烟用，默认全部）")
    ap.add_argument("--out", default=None, help="汇总 JSON 输出路径")
    ap.add_argument("--keep-all-zero", action="store_true",
                    help="不剔除六键全零帧（默认剔除）。与 train_v3.py 同名开关一致，"
                         "用于评估「把部署时真实出现的全零帧纳入训练」的效果")
    ap.add_argument("--dry-run", action="store_true",
                    help="只打印计划不训练（验证脚本本身用）")
    args = ap.parse_args()

    run_loo(
        clips_dir=args.clips, epochs=args.epochs, batch_size=args.batch_size,
        lr=args.lr, weight_decay=args.weight_decay, device=args.device,
        num_workers=args.num_workers, seed=args.seed, warmup_ratio=args.warmup_ratio,
        limit=args.limit, max_folds=args.folds, out_path=args.out,
        dry_run=args.dry_run,
        keep_all_zero=args.keep_all_zero,
    )


if __name__ == "__main__":
    main()
