#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Measure actual digit slot positions from glyph-mode ROI frames.

For each frame we binarize, find the three largest tall bright blobs (the digits),
assign them left/middle/right by x-order, and accumulate center x / width / y
statistics. Output recommended normalized slot constants that avoid overlap and
center the digits tightly.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import label, measurements

sys.path.insert(0, str(Path(__file__).parent))
from build_speed_glyphs import GLYPH_ROI_NORM, load_frames


def measure_digits(gray: np.ndarray) -> list[dict] | None:
    """Return up to 3 digit blobs as dicts {cx, cy, w, h, area} sorted by cx."""
    # Fixed threshold: digits are bright white (~200+) on dark background.
    binary = (gray > 170).astype(np.uint8)
    # Remove tiny specks
    labeled, num = label(binary)
    if num == 0:
        return None
    slices = measurements.find_objects(labeled)
    objects = []
    for region_id, slc in enumerate(slices, start=1):
        ys, xs = np.where(labeled == region_id)
        area = len(ys)
        x0, x1 = int(xs.min()), int(xs.max()) + 1
        y0, y1 = int(ys.min()), int(ys.max()) + 1
        w = x1 - x0
        h = y1 - y0
        # Keep tall-ish bright blobs; ignore wide flat KM/H strips and tiny noise.
        if h < 20 or w < 5 or area < 150:
            continue
        if w / h > 1.1:
            continue
        objects.append({
            "cx": (x0 + x1) / 2.0,
            "cy": (y0 + y1) / 2.0,
            "w": w,
            "h": h,
            "y0": y0,
            "y1": y1,
            "area": area,
        })
    if len(objects) < 3:
        return None
    # Take the 3 largest by area and sort by cx
    objects = sorted(objects, key=lambda o: o["area"], reverse=True)[:3]
    objects.sort(key=lambda o: o["cx"])
    return objects


def main() -> int:
    clip_dir = Path("data/glyph_clips/clip_20260815_130055/frames")
    frames = load_frames(clip_dir)
    print(f"loaded {len(frames)} frames")

    stats: list[list[float]] = [[], [], []]  # per-slot cx
    widths: list[list[float]] = [[], [], []]
    ys0: list[list[float]] = [[], [], []]
    ys1: list[list[float]] = [[], [], []]
    cys: list[list[float]] = [[], [], []]
    good = 0

    for fi, gray in enumerate(frames):
        blobs = measure_digits(gray)
        if blobs is None:
            continue
        good += 1
        for si, b in enumerate(blobs):
            stats[si].append(b["cx"])
            widths[si].append(b["w"])
            ys0[si].append(b["y0"])
            ys1[si].append(b["y1"])
            cys[si].append(b["cy"])

    print(f"good frames with 3 digits: {good}/{len(frames)}")
    if good == 0:
        return 2

    h, w = frames[0].shape
    rx, ry, rw, rh = GLYPH_ROI_NORM

    print("\nROI-frame pixel statistics (median):")
    centers_roi = []
    half_widths = []
    for si in range(3):
        cx = float(np.median(stats[si]))
        width = float(np.median(widths[si]))
        y0 = float(np.median(ys0[si]))
        y1 = float(np.median(ys1[si]))
        cy = float(np.median(cys[si]))
        centers_roi.append(cx)
        half_widths.append(width / 2.0)
        print(f"  slot {si}: cx={cx:.1f}, width={width:.1f}, y0={y0:.1f}, y1={y1:.1f}, cy={cy:.1f}")

    # Convert to full-screen normalized constants
    centers_norm = [rx + (cx / w) * rw for cx in centers_roi]
    slot_width_norm = max((hw * 2.0 / w) * rw for hw in half_widths)  # use uniform width = max
    y_min_norm = ry + (min(np.median(ys0[si]) for si in range(3)) / h) * rh
    y_max_norm = ry + (max(np.median(ys1[si]) for si in range(3)) / h) * rh

    print("\nRecommended full-screen normalized constants:")
    print(f"  SLOT_CENTERS_NORM = ({centers_norm[0]:.4f}, {centers_norm[1]:.4f}, {centers_norm[2]:.4f})")
    print(f"  SLOT_WIDTH_NORM   = {slot_width_norm:.4f}")
    print(f"  SLOT_Y_MIN_NORM   = {y_min_norm:.4f}")
    print(f"  SLOT_Y_MAX_NORM   = {y_max_norm:.4f}")

    # Render overlay on a few frames using measured centers and tight widths
    idxs = [0, len(frames) // 5, len(frames) // 2, len(frames) * 4 // 5, len(frames) - 1]
    cell_w, cell_h = w, h
    canvas = Image.new("RGB", (len(idxs) * cell_w, cell_h + 20), (40, 40, 40))
    for ci, idx in enumerate(idxs):
        im = Image.fromarray(frames[idx]).convert("RGB")
        draw = ImageDraw.Draw(im)
        for si in range(3):
            cx = centers_roi[si]
            hw = half_widths[si] * 1.15  # 15% margin
            x0 = int(round(cx - hw))
            x1 = int(round(cx + hw))
            y0m = int(round(np.median(ys0[si])))
            y1m = int(round(np.median(ys1[si])))
            draw.rectangle([x0, y0m, x1, y1m], outline=(0, 255, 0), width=2)
            draw.text((x0 + 2, y0m + 2), str(si), fill=(0, 255, 0))
        canvas.paste(im, (ci * cell_w, 0))
        draw = ImageDraw.Draw(canvas)
        draw.text((ci * cell_w + 2, cell_h + 2), f"f{idx:03d}", fill=(255, 255, 255))
    out_path = Path("tools/measure_slot_overlay.png")
    canvas.save(out_path)
    print(f"\noverlay saved to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
