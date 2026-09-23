#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
异环(NTE) 路面辅助线自动提取 —— 零人工标注的监督信号生成器

背景
----
FH6(ForzaHorizon6-VisionAI) 用游戏遥测的 NormalizedDrivingLine 字段当监督标签,
但异环没有遥测接口。所幸异环的辅助线是 "in-world driving line"(贴路面的 3D 条带),
它本身就画在像素里 —— 于是可以直接从画面分割出来当标签, 等价于 FH6 的 line_targets,
但完全不需要任何游戏接口。

实测特征(1920x1080 第三人称追车视角)
------------------------------------
  Hue  : 200.2° ± 2.9°   (范围 190–205)   ← 极窄, 这是可分割的关键
  Sat  : 0.47   ± 0.11
  Val  : 0.82   ± 0.14
  RGB  : (115, 178, 210)  → 青蓝色条带(横向条纹/阶梯状), 铺在路面上向远方延伸

用法
----
  # 单张图, 输出可视化
  python3 tools/extract_driving_line.py --image shot.png --vis out.png

  # 整个目录, 输出标签 CSV(每帧一行, 含 3 个前瞻点)
  python3 tools/extract_driving_line.py --dir frames/ --csv labels.csv

  # 调参(不同天气/昼夜)
  python3 tools/extract_driving_line.py --image shot.png --hue 195 208 --sat 0.35 0.75

输出标签约定(与 FH6 的 line_targets 对齐)
----------------------------------------
  line_now  : 最近处(y=NEAR_Y)的横向偏移, 归一化到 [-1, 1], 0 = 画面中心
  line_f1   : 中距离(y=MID_Y)的横向偏移
  line_f2   : 远处(y=FAR_Y)的横向偏移
  越往上(y 越小) = 看越远, 对应 FH6 的 now / +0.5s / +1.0s

  x_norm = (x_center - W/2) / (W/2)      # -1=最左, 0=正中, +1=最右

注意
----
  * 辅助线只在「设置了追踪路点(track destination)」时出现 —— 录制时必须先设路点。
  * 手动开车/自动驾驶(按 T) 都能看到这条线, 两种模式都可录。
  * 线是"贴地"的, 所以它天然编码了道路走向 → 也顺便给出了 waypoint 的空间几何。
"""

import argparse
import csv
import json
import os
import sys

import numpy as np
from PIL import Image

# ---- 实测基线阈值(1920x1080 晴天白天) ----
DEF_HUE = (190.0, 212.0)   # 实测 200.2±2.9, 两侧留余量
DEF_SAT = (0.30, 0.80)
DEF_VAL_MIN = 0.55

# 前瞻采样行(占画面高度比例)。越小 = 看得越远。
# 0.57 约在车头前方近处, 0.46 约在弯道入口处。
NEAR_Y, MID_Y, FAR_Y = 0.57, 0.515, 0.46

# 只在下半部分找线, 避免天空(蓝天 Hue 同样落在 200° 附近!)干扰
ROI_TOP = 0.40

# 自车掩膜: 第三人称视角下车体占据画面底部中央, 且车漆常为银/蓝(与线同色系) → 必须挖掉
EGO_BOTTOM = 0.62      # 该比例以下的中央区域视为车体
EGO_HALF_W = 0.30      # 中央 ±30% 宽


def ego_mask(shape, bottom=EGO_BOTTOM, half_w=EGO_HALF_W) -> np.ndarray:
    """生成自车(ego vehicle)遮挡掩膜。True = 该像素属于车体, 应排除。"""
    H, W = shape[:2]
    m = np.zeros((H, W), dtype=bool)
    y0 = int(bottom * H)
    x0 = int((0.5 - half_w) * W)
    x1 = int((0.5 + half_w) * W)
    m[y0:, x0:x1] = True
    return m


def longest_run(ys_sorted, max_gap=6):
    """从有效行里取最长的一段连续区间 —— 线的纵向连续性远好于噪声。"""
    if not ys_sorted:
        return []
    best, cur = [], [ys_sorted[0]]
    for y in ys_sorted[1:]:
        if y - cur[-1] <= max_gap:
            cur.append(y)
        else:
            if len(cur) > len(best):
                best = cur
            cur = [y]
    return best if len(best) >= len(cur) else cur


def auto_min_px(width: int) -> int:
    """按分辨率自适应每行最少像素数。

    实测: 1920px 宽时线宽约 17–68 px; 480px 宽的 B站快照帧上只有 3–25 px。
    固定阈值会把低分辨率帧全部误杀, 所以按宽度缩放(以 1920 宽 / 8px 为基准)。
    """
    return max(3, int(round(width * 8.0 / 1920.0)))


def rgb_to_hsv_np(rgb01: np.ndarray):
    """向量化 RGB->HSV。rgb01: (H,W,3) float in [0,1]。返回 h(0-360), s, v。"""
    mx = rgb01.max(axis=2)
    mn = rgb01.min(axis=2)
    d = mx - mn
    r, g, b = rgb01[:, :, 0], rgb01[:, :, 1], rgb01[:, :, 2]

    h = np.zeros_like(mx)
    m = d > 1e-6
    rm = m & (mx == r)
    gm = m & (mx == g) & ~rm
    bm = m & (mx == b) & ~rm & ~gm
    h[rm] = ((g[rm] - b[rm]) / d[rm]) % 6
    h[gm] = (b[gm] - r[gm]) / d[gm] + 2
    h[bm] = (r[bm] - g[bm]) / d[bm] + 4
    h *= 60.0

    s = np.where(mx > 1e-6, d / np.maximum(mx, 1e-6), 0.0)
    return h, s, mx


def segment_line(img: Image.Image, hue=DEF_HUE, sat=DEF_SAT, val_min=DEF_VAL_MIN):
    """分割出辅助线条带。返回布尔 mask(已排除天空与自车)。"""
    a = np.asarray(img.convert("RGB")).astype(np.float32) / 255.0
    h, s, v = rgb_to_hsv_np(a)
    H = a.shape[0]

    mask = (h >= hue[0]) & (h <= hue[1]) & (s >= sat[0]) & (s <= sat[1]) & (v >= val_min)
    mask[: int(ROI_TOP * H)] = False        # 排除天空/远景
    mask[ego_mask(a.shape)] = False          # 排除自车车体(同色银/蓝车漆是最大误检源)
    return mask


def row_centers(mask: np.ndarray, min_px: int = 8):
    """逐行提取线的横向中心。返回 {y: (xc, width, npix)}。"""
    H, W = mask.shape
    out = {}
    for y in range(H):
        xs = np.nonzero(mask[y])[0]
        if len(xs) >= min_px:
            out[y] = (float(xs.mean()), int(xs.max() - xs.min()), int(len(xs)))
    return out


def extract(img: Image.Image, hue=DEF_HUE, sat=DEF_SAT, val_min=DEF_VAL_MIN, min_px=None):
    """完整提取。返回标签 dict(找不到线时 found=False)。"""
    H, W = img.size[1], img.size[0]
    if min_px is None:
        min_px = auto_min_px(W)
    mask = segment_line(img, hue, sat, val_min)
    centers = row_centers(mask, min_px)

    # 只保留纵向最长连续段: 线的连续性远好于零散噪声(反光标线/车辆反光)
    keep = longest_run(sorted(centers))
    if keep:
        centers = {y: centers[y] for y in keep}
        # 同步清理 mask, 让可视化也干净
        drop = np.ones(mask.shape[0], dtype=bool)
        for y in keep:
            drop[y] = False
        mask[drop] = False

    # 低分辨率帧线很细, 至少要有 4 个有效行才算找到
    min_rows = 4 if W < 800 else 8
    if len(centers) < min_rows:
        centers = {}

    res = {
        "found": False,
        "n_pixels": int(mask.sum()),
        "n_rows": len(centers),
        "image_w": W,
        "image_h": H,
    }
    if not centers:
        return res, mask

    ys = sorted(centers)
    res["found"] = True
    res["y_range"] = [ys[0], ys[-1]]
    res["x_center_median"] = float(np.median([centers[y][0] for y in ys]))

    # --- 三个前瞻点: 取离目标比例行最近的有效行 ---
    for name, ratio in (("line_now", NEAR_Y), ("line_f1", MID_Y), ("line_f2", FAR_Y)):
        ty = int(ratio * H)
        # 容差随分辨率缩放(低分辨率帧有效行少, 固定 ±8 会大量漏标)
        tol = max(8, int(0.05 * H))
        cand = [y for y in ys if abs(y - ty) <= tol]
        if not cand:
            # 退化: 取最近的有效行(宁可外推也不丢标签)
            cand = sorted(ys, key=lambda v: abs(v - ty))[:1]
        if cand:
            y = min(cand, key=lambda v: abs(v - ty))
            xc = centers[y][0]
            res[name] = round((xc - W / 2.0) / (W / 2.0), 4)
            res[name + "_y"] = y
            # 标记该点是"精确命中目标行"还是"外推得到"
            res[name + "_exact"] = bool(abs(y - ty) <= tol)
        else:
            res[name] = None

    # --- 全行中心线(供拟合/可视化) ---
    res["centerline"] = [[y, round(centers[y][0], 2)] for y in ys]

    # --- 拟合二次曲线 x(y): 近端切线方向 ≈ 需要的转向 ---
    if len(ys) >= 5:
        yy = np.array(ys, dtype=np.float64)
        xx = np.array([centers[y][0] for y in ys], dtype=np.float64)
        # 归一化后拟合, 数值更稳
        yn = (yy - yy.mean()) / max(yy.std(), 1e-6)
        try:
            c2, c1, c0 = np.polyfit(yn, xx, 2)
            res["fit"] = {
                "c2_over_yn2": round(float(c2), 4),
                "c1_over_yn": round(float(c1), 4),
                "c0_px": round(float(c0), 2),
                # 近端斜率: dx/dy 在最近行的值(>0 = 线向右弯)
                "slope_near": round(float((2 * c2 * yn.min() + c1) / max(yy.std(), 1e-6)), 4),
            }
        except Exception:
            res["fit"] = None

    return res, mask


def visualize(img: Image.Image, mask: np.ndarray, res: dict, out_path: str):
    """把分割结果画成红色叠加图。"""
    vis = np.asarray(img.convert("RGB")).copy()
    vis[mask] = [255, 0, 0]
    # 标出三个前瞻点
    W, H = img.size
    for name, color in (("line_now", (255, 255, 0)),
                        ("line_f1", (0, 255, 0)),
                        ("line_f2", (255, 0, 255))):
        xv = res.get(name)
        yv = res.get(name + "_y")
        if xv is not None and yv is not None:
            x = int((xv * W / 2.0) + W / 2.0)
            vis[max(0, yv - 2):yv + 3, max(0, x - 12):x + 13] = color
    Image.fromarray(vis).save(out_path)


def main():
    ap = argparse.ArgumentParser(description="异环(NTE)路面辅助线自动提取")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--image", help="单张图片")
    src.add_argument("--dir", help="帧目录(递归找 png/jpg)")
    ap.add_argument("--vis", help="可视化输出路径(仅 --image)")
    ap.add_argument("--vis-dir", help="可视化输出目录(仅 --dir)")
    ap.add_argument("--csv", help="标签输出 CSV(仅 --dir)")
    ap.add_argument("--json", help="标签输出 JSON")
    ap.add_argument("--hue", nargs=2, type=float, default=list(DEF_HUE), metavar=("MIN", "MAX"))
    ap.add_argument("--sat", nargs=2, type=float, default=list(DEF_SAT), metavar=("MIN", "MAX"))
    ap.add_argument("--val-min", type=float, default=DEF_VAL_MIN)
    ap.add_argument("--min-px", type=int, default=None,
                    help="每行最少像素数(默认按分辨率自适应: 1920宽->8, 480宽->3)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    kw = dict(hue=tuple(args.hue), sat=tuple(args.sat), val_min=args.val_min, min_px=args.min_px)

    if args.image:
        img = Image.open(args.image)
        res, mask = extract(img, **kw)
        res["file"] = os.path.basename(args.image)
        if args.vis:
            visualize(img, mask, res, args.vis)
            res["vis"] = args.vis
        if args.json:
            with open(args.json, "w", encoding="utf-8") as f:
                json.dump(res, f, ensure_ascii=False, indent=2)
        if not args.quiet:
            print(json.dumps({k: v for k, v in res.items() if k != "centerline"},
                             ensure_ascii=False, indent=2))
            if res["found"]:
                print(f"\n  线像素 {res['n_pixels']}  有效行 {res['n_rows']}"
                      f"  y {res['y_range'][0]}–{res['y_range'][1]}")
                print(f"  line_now={res['line_now']}  line_f1={res['line_f1']}  line_f2={res['line_f2']}")
        return 0 if res["found"] else 2

    # --- 目录模式 ---
    exts = (".png", ".jpg", ".jpeg", ".bmp")
    files = []
    for root, _, names in os.walk(args.dir):
        for n in sorted(names):
            if n.lower().endswith(exts):
                files.append(os.path.join(root, n))
    files.sort()
    if not files:
        print(f"没找到图片: {args.dir}", file=sys.stderr)
        return 1

    if args.vis_dir:
        os.makedirs(args.vis_dir, exist_ok=True)

    rows, hits = [], 0
    for i, fp in enumerate(files, 1):
        try:
            img = Image.open(fp)
        except Exception as e:
            print(f"  跳过 {fp}: {e}", file=sys.stderr)
            continue
        res, mask = extract(img, **kw)
        if res["found"]:
            hits += 1
        if args.vis_dir:
            visualize(img, mask, res, os.path.join(args.vis_dir, os.path.basename(fp)))
        rows.append({
            "file": os.path.basename(fp),
            "found": int(res["found"]),
            "n_pixels": res["n_pixels"],
            "n_rows": res["n_rows"],
            "line_now": res.get("line_now"),
            "line_f1": res.get("line_f1"),
            "line_f2": res.get("line_f2"),
            "x_center_median": res.get("x_center_median"),
            "slope_near": (res.get("fit") or {}).get("slope_near"),
        })
        if not args.quiet and (i % 50 == 0 or i == len(files)):
            print(f"  {i}/{len(files)}  命中 {hits} ({hits / i * 100:.1f}%)")

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        if not args.quiet:
            print(f"\n  标签 CSV -> {args.csv}  ({len(rows)} 行)")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False, indent=2)

    if not args.quiet:
        print(f"\n  总帧数 {len(files)}  命中 {hits} ({hits / max(len(files), 1) * 100:.1f}%)")
        print("  提示: 命中率低说明录制时没设追踪路点, 或时段/天气导致色偏 —— 用 --hue 调阈值")
    return 0


if __name__ == "__main__":
    sys.exit(main())
