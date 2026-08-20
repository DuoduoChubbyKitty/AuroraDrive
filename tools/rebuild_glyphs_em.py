#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 rebuild_glyphs_em.py — 用「新录 clip」EM 自标定重建速度表字模库

 背景：models/speed_glyphs.json 是在旧分辨率/旧渲染下训练出来的。游戏渲染
       更新后（新 clip 与旧 clip 槽位几何一致，但笔画形态不同），旧字模与
       新帧残差系统性抬高（0 尚能匹配 ~1-3，4/6/7/9 类残差均值 120~210，
       必然造成 089→018、001→082 这类单帧大跳变误读）。

 方案（EM 自标定，无需人工打标）：
   Step 1  用旧字模作为初始模板，对新 clip 每个槽位样本做最近邻分配。
   Step 2  每个数字 = 分配给它的样本按位多数投票，得到新模板。
   Step 3  用新模板重新分配样本 → 再投票，迭代直至标签变化为 0。
   Step 4  收敛后输出 models/speed_glyphs.json（与 Swift 加载格式一致）。

 关键约束：
   - 槽位几何不变（ROI-relative 中心 / 宽度 / y 范围与当前常量一致），
     因此 JSON 里的 slot_* 字段原样保留。
   - 样本质量过滤：前景像素过少(<50)/过多(>1000) 的过渡帧/反光帧丢弃。
   - 初始模板只用于引导，多数投票会自行纠正偏移样本；若某个数字在新
     clip 里从未出现（例如整段没超 100 → 无“1”），该数字沿用旧模板，
     避免字模缺失导致三位数组合残差无穷大。
   - 收敛判据：连续两轮每个样本的标签完全相同。

 输出：models/speed_glyphs.json（EM 收敛后的 0-9 模板）。
 用法：
   .venv-yolo26/bin/python tools/rebuild_glyphs_em.py \
       --clip data/glyph_clips/clip_20260820_011758/frames \
       --out models/speed_glyphs.json
================================================================================
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from build_speed_glyphs import (  # noqa: E402
    GLYPH_ROI_NORM,
    SLOT_CENTERS_NORM,
    SLOT_WIDTH_NORM,
    SLOT_Y_MAX_NORM,
    SLOT_Y_MIN_NORM,
    TEMPLATE_H,
    TEMPLATE_W,
    crop_slot,
    load_frames,
    make_template,
)

# 样本质量过滤（与 build_labeled_glyphs.py 一致）
MIN_FG = 50
MAX_FG = 1000

# EM 最大迭代轮数；一般 3~5 轮即可收敛
MAX_ITER = 20


def load_initial_templates(path: Path) -> dict[str, np.ndarray]:
    """读旧字模 JSON 为 {digit: H×W uint8}。"""
    lib = json.loads(path.read_text())
    return {k: np.array(rows, dtype=np.uint8) for k, rows in lib["templates"].items()}


def majority_vote(samples: list[np.ndarray]) -> np.ndarray:
    """按位多数投票：>= 半数样本为 1 → 1，否则 0。"""
    arr = np.stack(samples, axis=0)
    half = arr.shape[0] / 2
    return (arr.sum(axis=0) >= half).astype(np.uint8)


def assign(samples: list[np.ndarray], templates: dict[str, np.ndarray]) -> list[str]:
    """每个样本 → 最近模板的数字标签（汉明距离最小）。"""
    keys = sorted(templates.keys())
    arr = np.stack([templates[k] for k in keys], axis=0)  # [10, H, W]
    labels: list[str] = []
    for s in samples:
        dists = np.sum(s != arr, axis=(1, 2))  # 汉明距离
        labels.append(keys[int(dists.argmin())])
    return labels


def main() -> int:
    ap = argparse.ArgumentParser(description="EM 自标定重建速度表字模库")
    ap.add_argument("--clip", required=True, help="新录 clip 的 frames 目录")
    ap.add_argument("--out", default="models/speed_glyphs.json",
                    help="字模库 JSON 输出路径")
    ap.add_argument("--initial", default="models/speed_glyphs.json",
                    help="初始字模 JSON（EM 引导模板）")
    args = ap.parse_args()

    clip_dir = Path(args.clip)
    out_path = Path(args.out)
    init_path = Path(args.initial)

    print(f"[1/4] load frames from {clip_dir} ...")
    frames = load_frames(clip_dir)
    if not frames:
        print("no frames loaded", file=sys.stderr)
        return 2
    print(f"      loaded {len(frames)} frames")

    print("[2/4] crop slots + binarize + resize + quality filter ...")
    samples: list[np.ndarray] = []
    for fi, gray in enumerate(frames):
        for si in range(3):
            sub = crop_slot(gray, si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            fg = int(tmpl.sum())
            if fg < MIN_FG or fg > MAX_FG:
                continue
            samples.append(tmpl)
    print(f"      {len(samples)} valid slot samples")

    print("[3/4] load initial templates + EM ...")
    templates = load_initial_templates(init_path)
    missing = [d for d in "0123456789" if d not in templates]
    if missing:
        print(f"  WARNING: initial glyphs missing {missing}", file=sys.stderr)
    print(f"      initial digits: {sorted(templates.keys())}")

    prev_labels: list[str] | None = None
    for it in range(1, MAX_ITER + 1):
        labels = assign(samples, templates)
        # 按标签分组，多数投票出新模板
        groups: dict[str, list[np.ndarray]] = {d: [] for d in "0123456789"}
        for s, lab in zip(samples, labels):
            groups[lab].append(s)
        changed = 0
        for d in "0123456789":
            members = groups[d]
            if not members:
                continue  # 该数字在新 clip 未出现 → 保留旧模板
            new_tmpl = majority_vote(members)
            if d in templates and not np.array_equal(new_tmpl, templates[d]):
                changed += 1
            templates[d] = new_tmpl
        if prev_labels is not None:
            n_changed = sum(a != b for a, b in zip(prev_labels, labels))
            print(f"      iter {it}: label_changes={n_changed} template_changes={changed}")
            if n_changed == 0:
                break
        else:
            print(f"      iter {it}: label_changes=— template_changes={changed}")
        prev_labels = labels
    else:
        print(f"      EM 未在 {MAX_ITER} 轮内完全收敛（沿用最后一轮结果）", file=sys.stderr)

    # 每个数字的最终模板摘要
    for d in "0123456789":
        if d in templates:
            print(f"      final '{d}': sum={int(templates[d].sum())} "
                  f"bbox={np.argwhere(templates[d]==1).min(0).tolist()}.."
                  f"{np.argwhere(templates[d]==1).max(0).tolist()}")
        else:
            print(f"      final '{d}': MISSING (沿用旧模板?)")

    print("[4/4] write glyph library ...")
    glyph = {
        "version": 1,
        "template_width": TEMPLATE_W,
        "template_height": TEMPLATE_H,
        "slot_centers_norm": list(SLOT_CENTERS_NORM),
        "slot_width_norm": SLOT_WIDTH_NORM,
        "slot_y_min_norm": SLOT_Y_MIN_NORM,
        "slot_y_max_norm": SLOT_Y_MAX_NORM,
        "templates": {d: templates[d].astype(int).tolist()
                      for d in "0123456789" if d in templates},
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(glyph, ensure_ascii=False, indent=2))
    print(f"      → {out_path} (digits: {sorted(glyph['templates'].keys())})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
