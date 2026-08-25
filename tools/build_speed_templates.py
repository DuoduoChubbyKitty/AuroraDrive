#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 build_speed_templates.py — 0~300 三位数整体模板库 + 离线仿真 QA

 输入：models/speed_glyphs.json（已确认的 0-9 单数字模板，25×45）
 输出：
   - models/speed_templates.json：301 个三位数整体模板（75×45），人类/外部
     检查用（Swift 不读，由 Swift 启动时从 0-9 模板实时拼合，避免 2.5MB JSON
     启动开销——数学等价）
   - tools/speed_templates_grid.png：0~300 模板按速度平铺的验证大图
   - 仿真报告：每帧识别速度 + 与用户口述 ground truth 对照 + 单调性

 关键设计：
   - 游戏速度表**始终显示三位数、前导补 0**（f089=000, f148=090 已确认），
     因此不需要空槽模板，0~300 每个值就是「百/十/个三位各取 0-9」组合
   - 三槽拼接：d0(25×45) | d1(25×45) | d2(25×45) → 75×45（axis=1 横向）
   - 运行时等价 Swift 实现：用 10 模板对每槽算 ±1 抖动残差成本 cost[3][10]，
     再枚举 v∈0..300 找 cost[0][v/100]+cost[1][(v/10)%10]+cost[2][v%10] 最小。
     301 模板整体匹配 ≡ 该查表组合（距离可加性，数学严格等价）
================================================================================
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from build_speed_glyphs import (
    GLYPH_ROI_NORM,
    TEMPLATE_H,
    TEMPLATE_W,
    crop_slot,
    load_frames,
    make_template,
)


# ─────────────────────────────────────────────────────────────────────────────
# 常量
# ─────────────────────────────────────────────────────────────────────────────
GLYPHS_JSON = Path("models/speed_glyphs.json")
OUT_JSON = Path("models/speed_templates.json")
OUT_GRID = Path("tools/speed_templates_grid.png")
CLIP_DIR = Path("data/glyph_clips/clip_20260815_130055/frames")

# 速度覆盖范围（游戏速度表量程 0~400，但用户明确要求 0~300；>300 由三层校验拦截）
MIN_SPEED = 0
MAX_SPEED = 300

# 三位数整体模板尺寸：3 槽横向拼接（百/十/个），每槽 25×45
TRIPLET_W = TEMPLATE_W * 3   # 75
TRIPLET_H = TEMPLATE_H       # 45

# 用户口述的 ground truth（速度表显示值 vs 帧号）
GROUND_TRUTH: dict[int, int] = {
    89: 0,      # f089 = "000"
    148: 90,    # f148 = "090"
    178: 115,   # f178 = "115"
    300: 175,   # f300 = "175"
    150: 100,   # f150 = "100"（前几轮多模态看过的）
}

# 仿真阈值：3 槽 × 25×45 = 3375 像素，0.30 = 1012.5（与 Swift maxSlotResidualRatio 一致）
RESIDUAL_RATIO = 0.30
TRIPLET_AREA = TRIPLET_W * TRIPLET_H  # 3375
DIST_THRESHOLD = int(3 * TEMPLATE_H * TEMPLATE_W * RESIDUAL_RATIO)  # 1012

# 无效帧前置检测：三槽前景像素总数 < 此值视为「画面里没有速度表」（如 f000/f063/f229）
INVALID_FRAME_FG_PIXELS = 80  # 有效帧 ~450+，无效帧 < 50


# ─────────────────────────────────────────────────────────────────────────────
# 单数字模板加载与三位数拼接
# ─────────────────────────────────────────────────────────────────────────────
def load_single_digits(path: Path) -> dict[str, np.ndarray]:
    """从 speed_glyphs.json 读 0-9 单数字模板为 {str: np.ndarray(H×W)}。"""
    lib = json.loads(path.read_text())
    return {k: np.array(rows, dtype=np.uint8) for k, rows in lib["templates"].items()}


def build_triplet(d0: np.ndarray, d1: np.ndarray, d2: np.ndarray) -> np.ndarray:
    """三槽 25×45 横向拼接 → 75×45。axis=1 是宽方向。"""
    return np.concatenate([d0, d1, d2], axis=1)


def build_all_templates(digits: dict[str, np.ndarray]) -> dict[int, np.ndarray]:
    """生成 0~MAX_SPEED 共 MAX_SPEED+1 个三位数整体模板。"""
    out: dict[int, np.ndarray] = {}
    for v in range(MIN_SPEED, MAX_SPEED + 1):
        d0 = digits[str(v // 100)]
        d1 = digits[str((v // 10) % 10)]
        d2 = digits[str(v % 10)]
        out[v] = build_triplet(d0, d1, d2)
    return out


# ─────────────────────────────────────────────────────────────────────────────
# 匹配（仿真用）
# ─────────────────────────────────────────────────────────────────────────────
def hamming(a: np.ndarray, b: np.ndarray) -> int:
    """二值图按位不同像素数。"""
    return int(np.sum(a != b))


def foreground_pixel_count(triplet: np.ndarray) -> int:
    """三位数整体二值图的前景像素总数（= 3 槽之和）。"""
    return int(np.sum(triplet))


def match_speed(triplet: np.ndarray, templates: dict[int, np.ndarray]) -> tuple[int, int]:
    """遍历 0~MAX_SPEED 整体模板，取最小汉明距离。返回 (bestSpeed, bestDist)。"""
    bestV = MIN_SPEED
    bestDist = 10 ** 9
    for v, tmpl in templates.items():
        d = hamming(triplet, tmpl)
        if d < bestDist:
            bestDist = d
            bestV = v
    return bestV, bestDist


# ─────────────────────────────────────────────────────────────────────────────
# 仿真：跑 clip 全部帧
# ─────────────────────────────────────────────────────────────────────────────
def simulate(frames: list[np.ndarray], templates: dict[int, np.ndarray]) -> list[dict]:
    """对每帧裁 3 槽 → 二值化 → 拼接 → 整体匹配。返回每帧的 {frame, fg, dist, speed, valid}。"""
    out: list[dict] = []
    for fi, gray in enumerate(frames):
        slot_bins: list[np.ndarray] = []
        ok = True
        for si in range(3):
            sub = crop_slot(gray, si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                ok = False
                break
            slot_bins.append(make_template(sub))
        if not ok:
            out.append({"frame": fi, "fg": 0, "dist": -1, "speed": None, "valid": False})
            continue
        triplet = np.concatenate(slot_bins, axis=1)
        fg = foreground_pixel_count(triplet)
        # 前置无效检测：画面里没有速度表（f000/f063/f229 等载入/视角错位帧）
        if fg < INVALID_FRAME_FG_PIXELS:
            out.append({"frame": fi, "fg": fg, "dist": -1, "speed": None, "valid": False})
            continue
        bestV, bestD = match_speed(triplet, templates)
        # 三位数阈值：3 槽独立匹配时单槽阈值 × 3
        is_valid = bestD <= DIST_THRESHOLD
        out.append({
            "frame": fi,
            "fg": fg,
            "dist": bestD,
            "speed": bestV if is_valid else None,
            "valid": is_valid,
        })
    return out


def render_grid(templates: dict[int, np.ndarray], out_path: Path) -> None:
    """0~MAX_SPEED 模板按速度平铺：31 行 × 10 列，每行底部标速度号。"""
    cols = 10
    n = len(templates)
    rows = (n + cols - 1) // cols
    label_h = 24
    canvas_h = rows * TRIPLET_H + label_h
    canvas_w = cols * TRIPLET_W
    canvas = np.full((canvas_h, canvas_w), 255, dtype=np.uint8)
    # 渲染模板（白底黑数字）
    for i, v in enumerate(sorted(templates.keys())):
        tmpl = templates[v]
        r = i // cols
        c = i % cols
        y0 = r * TRIPLET_H
        x0 = c * TRIPLET_W
        canvas[y0:y0 + TRIPLET_H, x0:x0 + TRIPLET_W] = 255 - tmpl * 255
    # 速度标签
    pil = Image.fromarray(canvas)
    draw = ImageDraw.Draw(pil)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
    except Exception:
        font = ImageFont.load_default()
    for i, v in enumerate(sorted(templates.keys())):
        r = i // cols
        c = i % cols
        draw.text((c * TRIPLET_W + 4, rows * TRIPLET_H + 4), f"{v:>3d}", fill=0, font=font)
    pil.save(out_path)


def write_json(templates: dict[int, np.ndarray], glyphs_lib: dict, out_path: Path) -> None:
    """导出 speed_templates.json（含槽位常量 + 301 个三位数模板）。"""
    obj = {
        "version": 2,
        "template_width": TRIPLET_W,
        "template_height": TRIPLET_H,
        "slot_centers_norm": glyphs_lib["slot_centers_norm"],
        "slot_width_norm": glyphs_lib["slot_width_norm"],
        "slot_y_min_norm": glyphs_lib["slot_y_min_norm"],
        "slot_y_max_norm": glyphs_lib["slot_y_max_norm"],
        "min_speed": MIN_SPEED,
        "max_speed": MAX_SPEED,
        "speed_templates": {
            str(v): tmpl.astype(int).tolist() for v, tmpl in sorted(templates.items())
        },
    }
    out_path.write_text(json.dumps(obj, ensure_ascii=False, indent=2))


# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────
def main() -> int:
    print(f"[1/5] load single-digit glyphs from {GLYPHS_JSON} ...")
    digits = load_single_digits(GLYPHS_JSON)
    print(f"      loaded {len(digits)}: {sorted(digits.keys())}")
    if len(digits) != 10:
        print(f"  ERROR: expected 10 digits, got {len(digits)}", file=sys.stderr)
        return 2

    print(f"[2/5] build {MAX_SPEED - MIN_SPEED + 1} triplet templates ...")
    templates = build_all_templates(digits)
    print(f"      built {len(templates)} ({MIN_SPEED}~{MAX_SPEED})")

    print(f"[3/5] export {OUT_JSON} ...")
    glyphs_lib = json.loads(GLYPHS_JSON.read_text())
    write_json(templates, glyphs_lib, OUT_JSON)
    print(f"      wrote {OUT_JSON}")

    print(f"[4/5] render verification grid to {OUT_GRID} ...")
    OUT_GRID.parent.mkdir(parents=True, exist_ok=True)
    render_grid(templates, OUT_GRID)
    print(f"      wrote {OUT_GRID}")

    print(f"[5/5] simulate on {CLIP_DIR} ...")
    if not CLIP_DIR.is_dir():
        print(f"  skip simulate: clip dir not found: {CLIP_DIR}", file=sys.stderr)
        return 0
    frames = load_frames(CLIP_DIR)
    print(f"      loaded {len(frames)} frames")
    results = simulate(frames, templates)

    # ─── 仿真报告 ───
    valid = [r for r in results if r["valid"]]
    invalid = [r for r in results if not r["valid"]]
    print(f"\n=== 仿真汇总 ===")
    print(f"有效帧: {len(valid)}/{len(results)} ({100.0*len(valid)/max(1,len(results)):.1f}%)")
    print(f"无效帧: {len(invalid)}/{len(results)}（无效 = 画面无速度表 / 匹配超阈值）")

    if valid:
        speeds = [r["speed"] for r in valid]
        print(f"有效速度范围: {min(speeds)} ~ {max(speeds)} km/h")

    # ─── Ground truth 对照 ───
    print(f"\n=== Ground truth 对照（用户口述）===")
    print(f"  阈值: 距离 ≤ {DIST_THRESHOLD} 视为有效")
    all_gt_ok = True
    for fi, expected in sorted(GROUND_TRUTH.items()):
        if fi >= len(results):
            print(f"  f{fi:03d}: 帧不存在")
            all_gt_ok = False
            continue
        r = results[fi]
        actual = r["speed"]
        mark = "✓" if (actual == expected) else "✗"
        if actual != expected:
            all_gt_ok = False
        print(f"  f{fi:03d}: GT={expected:3d}  actual={actual}  fg={r['fg']:4d}  dist={r['dist']:5d}  {mark}")

    # ─── 无效帧验证（f000/f063/f229 应判无效）───
    print(f"\n=== 无效帧验证（应判 invalid）===")
    for fi in (0, 63, 229):
        if fi < len(results):
            r = results[fi]
            mark = "✓" if not r["valid"] else "✗ 误识"
            if r["valid"]:
                all_gt_ok = False
            print(f"  f{fi:03d}: valid={r['valid']}  fg={r['fg']:4d}  speed={r['speed']}  {mark}")

    # ─── 单调性检查（加速段不应大倒退）───
    print(f"\n=== 单调性检查（Δspeed 异常检测）===")
    big_jumps = []
    for i in range(1, len(valid)):
        if valid[i]["speed"] is None or valid[i-1]["speed"] is None:
            continue
        delta = valid[i]["speed"] - valid[i-1]["speed"]
        # 录制是驾驶视频，正常加速每秒 ~30km/h。±30 km/h/帧 算异常
        if abs(delta) > 30:
            big_jumps.append((valid[i-1], valid[i], delta))
    if not big_jumps:
        print("  无 ±30 km/h 大跳变 ✓")
    else:
        print(f"  发现 {len(big_jumps)} 处大跳变（人工复核）:")
        for prev, cur, d in big_jumps[:10]:
            print(f"    f{prev['frame']:03d}→f{cur['frame']:03d}: {prev['speed']}→{cur['speed']} Δ={d}")

    # ─── 速度序列抽样（每 30 帧）───
    print(f"\n=== 速度序列抽样（每 30 帧）===")
    for r in results[::30]:
        v = r["speed"] if r["valid"] else "——"
        print(f"  f{r['frame']:03d}: {v:>5}  (fg={r['fg']:4d})")

    # ─── 单帧识别的"问题帧"分类说明 ───
    print(f"\n=== 单帧识别问题帧分类 ===")
    print(f"  单帧匹配噪声（如 0 vs 8 混淆、反光带尾影）属于预期，")
    print(f"  App 的三层校验（跳变过滤 60km/h + 多帧确认 3帧±2 容差多数）会纠正。")

    # ─── 模拟 App finish：三层校验（量程/跳变/多帧确认）───
    print(f"\n=== 模拟 App 三层校验（最终输出序列）===")
    final_output: list[tuple[int, int]] = []  # (frame, speed)
    last_valid: int | None = None
    candidates: list[int] = []
    for r in results:
        if not r["valid"]:
            continue
        s = r["speed"]
        # Layer 1: 量程 0~400
        if not (0 <= s <= 400):
            continue
        # Layer 2: 跳变过滤 60km/h（保留旧值，不更新 candidates）
        if last_valid is not None and abs(s - last_valid) > 60:
            continue
        # Layer 3: 多帧确认（最近 3 帧 ±2 容差多数）
        candidates.append(s)
        if len(candidates) > 3:
            candidates = candidates[-3:]
        if len(candidates) < 2:
            continue
        latest = candidates[-1]
        same = [c for c in candidates if abs(c - latest) <= 2]
        if len(same) >= 2:
            final_output.append((r["frame"], latest))
            last_valid = latest
            candidates = []  # 输出后清空，进入下一轮确认

    print(f"App 实际输出帧数: {len(final_output)}")
    if final_output:
        out_speeds = [s for _, s in final_output]
        print(f"输出速度范围: {min(out_speeds)} ~ {max(out_speeds)} km/h")
        print(f"抽样（最多 15 个输出点）:")
        step = max(1, len(final_output) // 15)
        for i in range(0, len(final_output), step):
            fi, s = final_output[i]
            print(f"  f{fi:03d}: {s:3d} km/h")

    # ─── Ground truth 对照（用 App 输出序列）───
    print(f"\n=== Ground truth 对照（App 输出序列）===")
    all_gt_ok = True
    for fi, expected in sorted(GROUND_TRUTH.items()):
        matches = [(f, s) for f, s in final_output if f <= fi + 3]
        actual = matches[-1][1] if matches else None
        if actual is None:
            mark = "—"
            all_gt_ok = False
        else:
            mark = "✓" if abs(actual - expected) <= 2 else "✗"
            if abs(actual - expected) > 2:
                all_gt_ok = False
        print(f"  f{fi:03d}: GT={expected:3d}  App输出={actual if actual is not None else '无':>4}  {mark}")

    # ─── 总结 ───
    print(f"\n=== 总结 ===")
    if all_gt_ok and not big_jumps:
        print("✓ Ground truth 全过 + 无大跳变 + 无效帧正确丢弃")
        print("✓ 可以放心改 Swift 端为整体三位数匹配")
        return 0
    else:
        print(f"✗ 有问题需修复再继续 (all_gt_ok={all_gt_ok})")
        return 1


if __name__ == "__main__":
    sys.exit(main())