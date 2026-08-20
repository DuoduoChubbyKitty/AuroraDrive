#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Diagnostic: render cluster templates with their indices."""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from build_speed_glyphs import (
    GLYPH_ROI_NORM,
    TEMPLATE_H,
    TEMPLATE_W,
    cluster_by_hamming,
    crop_slot,
    load_frames,
    make_template,
)


def render(clusters, samples, out_path, top_n=30, scale=6):
    rows = min(top_n, len(clusters))
    cell_w = TEMPLATE_W * scale
    cell_h = TEMPLATE_H * scale
    label_w = 80
    canvas = np.full((rows * cell_h, label_w + cell_w), 255, dtype=np.uint8)
    for ri, cl in enumerate(clusters[:rows]):
        y0 = ri * cell_h
        label = Image.new("L", (label_w, cell_h), 240)
        draw = ImageDraw.Draw(label)
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
        except Exception:
            font = ImageFont.load_default()
        fg = int(cl.template.sum()) if cl.template is not None else 0
        draw.text((4, cell_h // 2 - 8), f"C{ri}\nN={len(cl.members)}\ns={fg}", fill=0, font=font)
        canvas[y0:y0+cell_h, 0:label_w] = np.array(label)
        if cl.template is not None:
            big = np.kron(cl.template, np.ones((scale, scale), dtype=np.uint8)) * 255
            canvas[y0:y0+cell_h, label_w:label_w+cell_w] = 255 - big
    Image.fromarray(canvas).save(out_path)


def main():
    clip_dir = Path("data/glyph_clips/clip_20260815_130055/frames")
    frames = load_frames(clip_dir)
    samples = []
    for gray in frames:
        for si in range(3):
            sub = crop_slot(gray, si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            fg = int(tmpl.sum())
            if fg < 50 or fg > 1000:
                continue
            samples.append(tmpl)
    clusters = cluster_by_hamming(samples, threshold=120)
    render(clusters, samples, Path("tools/diag_clusters30.png"), top_n=30)
    print(f"rendered {len(clusters)} clusters; top 30 sizes: {[len(c.members) for c in clusters[:30]]}")

if __name__ == "__main__":
    main()
