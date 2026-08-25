#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Inspect the top N glyph clusters with large labeled thumbnails.

Output: tools/topN_clusters.png — one row per cluster, showing the majority-vote
template plus representative samples. Intended for human (multimodal) labeling.
"""
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


def render_top_clusters(
    samples: list[np.ndarray],
    clusters: list,
    out_path: Path,
    top_n: int = 20,
    thumbs: int = 8,
    scale: int = 6,
) -> None:
    rows = min(top_n, len(clusters))
    cell_w = TEMPLATE_W * scale
    cell_h = TEMPLATE_H * scale
    label_w = 80
    cols = 1 + thumbs
    canvas = np.full((rows * cell_h, label_w + cols * cell_w), 255, dtype=np.uint8)

    for ri, cl in enumerate(clusters[:rows]):
        y0 = ri * cell_h
        # label column
        label_img = Image.new("L", (label_w, cell_h), 240)
        draw = ImageDraw.Draw(label_img)
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
        except Exception:
            font = ImageFont.load_default()
        draw.text((4, cell_h // 2 - 8), f"C{ri}\nN={len(cl.members)}", fill=0, font=font)
        canvas[y0 : y0 + cell_h, 0:label_w] = np.array(label_img)

        # template column
        if cl.template is not None:
            big = np.kron(cl.template, np.ones((scale, scale), dtype=np.uint8)) * 255
            canvas[y0 : y0 + cell_h, label_w : label_w + cell_w] = 255 - big

        # sample thumbnails
        for ti, mi in enumerate(cl.members[:thumbs]):
            big = np.kron(samples[mi], np.ones((scale, scale), dtype=np.uint8)) * 255
            x0 = label_w + (ti + 1) * cell_w
            canvas[y0 : y0 + cell_h, x0 : x0 + cell_w] = 255 - big

    Image.fromarray(canvas).save(out_path)


def main() -> int:
    clip_dir = Path("data/glyph_clips/clip_20260815_130055/frames")
    frames = load_frames(clip_dir)
    print(f"loaded {len(frames)} frames")

    # Use all frames (no max-frames) for the most stable clusters
    samples: list[np.ndarray] = []
    for gray in frames:
        for si in range(3):
            sub = crop_slot(gray, si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            # Basic quality filter: require some foreground and reasonable aspect
            fg = int(tmpl.sum())
            if fg < 50 or fg > 1000:
                continue
            samples.append(tmpl)
    print(f"{len(samples)} valid slot samples after basic filtering")

    clusters = cluster_by_hamming(samples, threshold=120)
    print(f"{len(clusters)} clusters total; top 20 sizes: {[len(c.members) for c in clusters[:20]]}")

    out_dir = Path("tools")
    out_dir.mkdir(parents=True, exist_ok=True)
    render_top_clusters(samples, clusters, out_dir / "top20_clusters.png", top_n=20)
    print("saved tools/top20_clusters.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
