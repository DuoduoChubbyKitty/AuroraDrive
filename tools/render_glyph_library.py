#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Render two verification images from the final glyph library:

1. tools/glyphs_final.png — clean 0-9 templates with labels.
2. tools/grid_15frames.png — 15 representative frames × 3 cropped slots
   (enlarged binary templates, NOT raw game screenshots).

These are the images shown to the user for final confirmation.
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


def render_glyph_templates(json_path: Path, out_path: Path, scale: int = 8) -> None:
    """Render a single row of 0-9 templates with labels."""
    data = json.loads(json_path.read_text())
    templates = data["templates"]
    cell_w = TEMPLATE_W * scale
    cell_h = TEMPLATE_H * scale
    label_h = 40
    canvas = np.full((cell_h + label_h, 10 * cell_w), 255, dtype=np.uint8)

    for d in range(10):
        key = str(d)
        rows = templates[key]
        tmpl = np.array(rows, dtype=np.uint8)
        big = np.kron(tmpl, np.ones((scale, scale), dtype=np.uint8)) * 255
        x0 = d * cell_w
        canvas[0:cell_h, x0 : x0 + cell_w] = 255 - big

    # Add labels below each cell
    pil = Image.fromarray(canvas)
    draw = ImageDraw.Draw(pil)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 24)
    except Exception:
        font = ImageFont.load_default()
    for d in range(10):
        x0 = d * cell_w
        bbox = draw.textbbox((0, 0), str(d), font=font)
        tw = bbox[2] - bbox[0]
        draw.text((x0 + (cell_w - tw) // 2, cell_h + 6), str(d), fill=0, font=font)
    pil.save(out_path)


def render_15frame_grid(frames: list[np.ndarray], out_path: Path, scale: int = 5) -> None:
    """Render 15 frames × 3 slots of enlarged binary templates."""
    n = 15
    idxs = np.linspace(0, len(frames) - 1, n).astype(int).tolist()
    cell_w = TEMPLATE_W * scale
    cell_h = TEMPLATE_H * scale
    label_h = 24
    canvas = np.full((n * cell_h + label_h, 3 * cell_w), 255, dtype=np.uint8)

    for ri, idx in enumerate(idxs):
        for si in range(3):
            sub = crop_slot(frames[idx], si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            big = np.kron(tmpl, np.ones((scale, scale), dtype=np.uint8)) * 255
            y0 = ri * cell_h
            x0 = si * cell_w
            canvas[y0 : y0 + cell_h, x0 : x0 + cell_w] = 255 - big

    pil = Image.fromarray(canvas)
    draw = ImageDraw.Draw(pil)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
    except Exception:
        font = ImageFont.load_default()
    # Column labels
    for si in range(3):
        bbox = draw.textbbox((0, 0), f"slot{si}", font=font)
        tw = bbox[2] - bbox[0]
        draw.text((si * cell_w + (cell_w - tw) // 2, n * cell_h + 4), f"slot{si}", fill=0, font=font)
    # Row labels
    for ri, idx in enumerate(idxs):
        y0 = ri * cell_h
        draw.text((4, y0 + 4), f"f{idx:03d}", fill=0, font=font)
    pil.save(out_path)


def main() -> int:
    glyph_json = Path("models/speed_glyphs.json")
    clip_dir = Path("data/glyph_clips/clip_20260815_130055/frames")

    if not glyph_json.exists():
        print(f"glyph json not found: {glyph_json}", file=sys.stderr)
        return 2
    if not clip_dir.is_dir():
        print(f"clip dir not found: {clip_dir}", file=sys.stderr)
        return 2

    frames = load_frames(clip_dir)
    print(f"loaded {len(frames)} frames")

    out_dir = Path("tools")
    out_dir.mkdir(parents=True, exist_ok=True)
    render_glyph_templates(glyph_json, out_dir / "glyphs_final.png")
    render_15frame_grid(frames, out_dir / "grid_15frames.png")
    print("saved tools/glyphs_final.png and tools/grid_15frames.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
