#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify glyph-mode slot crop alignment against recorded ROI frames.

Reads clip_20260815_130055 glyph frames (236x96 speedometer slice), draws the
current slot rectangles on sample frames, and renders enlarged raw/binary crops
so a human can verify the three digit slots are centered and fully captured.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from build_speed_glyphs import (
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


def _slot_rect(si: int, w: int, h: int) -> tuple[int, int, int, int]:
    """Return (x0, y0, x1, y1) for slot si in ROI-frame pixels."""
    rx, ry, rw, rh = GLYPH_ROI_NORM
    cx_norm = (SLOT_CENTERS_NORM[si] - rx) / rw
    half_w_norm = (SLOT_WIDTH_NORM / 2.0) / rw
    y0_norm = (SLOT_Y_MIN_NORM - ry) / rh
    y1_norm = (SLOT_Y_MAX_NORM - ry) / rh
    cx = int(round(cx_norm * w))
    half_w = int(round(half_w_norm * w))
    y0 = int(round(y0_norm * h))
    y1 = int(round(y1_norm * h))
    return cx - half_w, y0, cx + half_w, y1


def overlay_image(frames: list[np.ndarray], indices: list[int], out_path: Path) -> None:
    """Draw red slot rectangles on selected frames and concatenate horizontally."""
    h, w = frames[0].shape[:2]
    margin = 4
    label_h = 16
    cell_h = h + label_h + margin * 2
    canvas = Image.new("RGB", (len(indices) * w, cell_h), (40, 40, 40))
    for ci, idx in enumerate(indices):
        im = Image.fromarray(frames[idx]).convert("RGB")
        draw = ImageDraw.Draw(im)
        for si in range(3):
            x0, y0, x1, y1 = _slot_rect(si, w, h)
            draw.rectangle([x0, y0, x1, y1], outline=(255, 0, 0), width=2)
            draw.text((x0 + 2, y0 + 2), str(si), fill=(255, 255, 0))
        # paste onto canvas with frame label
        canvas.paste(im, (ci * w, margin))
        label = ImageDraw.Draw(canvas)
        label.text((ci * w + 2, h + margin + 2), f"f{idx:03d}", fill=(255, 255, 255))
    canvas.save(out_path)


def raw_crop_grid(frames: list[np.ndarray], indices: list[int], out_path: Path, scale: int = 4) -> None:
    """Grid of enlarged raw grayscale crops (rows=frames, cols=slots)."""
    cell_w = TEMPLATE_W * scale
    cell_h = TEMPLATE_H * scale
    canvas = np.full((len(indices) * cell_h, 3 * cell_w), 255, dtype=np.uint8)
    for ri, idx in enumerate(indices):
        for si in range(3):
            sub = crop_slot(frames[idx], si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            # nearest-neighbor enlarge to fixed cell size
            sh, sw = sub.shape
            rs = np.linspace(0, sh - 1, cell_h).astype(np.int64)
            cs = np.linspace(0, sw - 1, cell_w).astype(np.int64)
            big = sub[rs[:, None], cs[None, :]]
            canvas[ri * cell_h : (ri + 1) * cell_h, si * cell_w : (si + 1) * cell_w] = big
    Image.fromarray(canvas).save(out_path)


def binary_crop_grid(frames: list[np.ndarray], indices: list[int], out_path: Path, scale: int = 4) -> None:
    """Grid of enlarged binary templates (rows=frames, cols=slots)."""
    cell_w = TEMPLATE_W * scale
    cell_h = TEMPLATE_H * scale
    canvas = np.full((len(indices) * cell_h, 3 * cell_w), 255, dtype=np.uint8)
    for ri, idx in enumerate(indices):
        for si in range(3):
            sub = crop_slot(frames[idx], si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            big = np.kron(tmpl, np.ones((scale, scale), dtype=np.uint8)) * 255
            canvas[ri * cell_h : (ri + 1) * cell_h, si * cell_w : (si + 1) * cell_w] = 255 - big
    Image.fromarray(canvas).save(out_path)


def main() -> int:
    clip_dir = Path("data/glyph_clips/clip_20260815_130055/frames")
    if not clip_dir.is_dir():
        print(f"clip dir not found: {clip_dir}", file=sys.stderr)
        return 2
    frames = load_frames(clip_dir)
    print(f"loaded {len(frames)} frames")
    if not frames:
        return 2

    # Pick frames across the clip, skipping the first/last transitions where HUD
    # may be off-screen.
    n = 10
    idxs = np.linspace(max(0, len(frames) // 20), min(len(frames) - 1, len(frames) * 19 // 20), n).astype(int).tolist()
    out_dir = Path("tools")
    out_dir.mkdir(parents=True, exist_ok=True)

    overlay_image(frames, idxs, out_dir / "verify_slot_overlay.png")
    raw_crop_grid(frames, idxs, out_dir / "verify_slot_raw.png")
    binary_crop_grid(frames, idxs, out_dir / "verify_slot_binary.png")
    print("saved verify_slot_overlay.png, verify_slot_raw.png, verify_slot_binary.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
