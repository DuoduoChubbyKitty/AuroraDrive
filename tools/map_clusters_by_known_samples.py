#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Map clusters to digits by matching against manually-verified sample frames.

For each known (frame_idx, slot_idx, digit_label) triple, we extract the slot
sample and find the nearest cluster template. The cluster that contains the
sample is then labeled with that digit. This removes ambiguity from visual
inspection of tiny thumbnails.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from build_speed_glyphs import (
    GLYPH_ROI_NORM,
    TEMPLATE_H,
    TEMPLATE_W,
    cluster_by_hamming,
    crop_slot,
    hamming,
    load_frames,
    make_template,
)

# Manually verified (frame_idx, slot_idx, digit_label) from reading the speedometer.
# These are clear frames where the speed is unambiguous.
KNOWN_SAMPLES: list[tuple[int, int, str]] = [
    (83, 0, "0"), (83, 1, "0"), (83, 2, "0"),
    (150, 0, "1"), (150, 1, "0"), (150, 2, "0"),
    (191, 0, "0"), (191, 1, "3"), (191, 2, "6"),
    (210, 0, "0"), (210, 1, "6"), (210, 2, "9"),
    (258, 0, "0"), (258, 1, "8"), (258, 2, "2"),
    (282, 0, "1"), (282, 1, "5"), (282, 2, "4"),
    (306, 0, "1"), (306, 1, "2"), (306, 2, "4"),
    (329, 0, "0"), (329, 1, "8"), (329, 2, "0"),
    (353, 0, "0"), (353, 1, "0"), (353, 2, "5"),
    (377, 0, "0"), (377, 1, "7"), (377, 2, "9"),
    (401, 0, "1"), (401, 1, "4"), (401, 2, "5"),
]


def main() -> int:
    clip_dir = Path("data/glyph_clips/clip_20260815_130055/frames")
    frames = load_frames(clip_dir)

    samples: list[np.ndarray] = []
    sample_meta: list[tuple[int, int]] = []  # (frame_idx, slot_idx) for each sample
    for fi, gray in enumerate(frames):
        for si in range(3):
            sub = crop_slot(gray, si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            fg = int(tmpl.sum())
            if fg < 50 or fg > 1000:
                continue
            samples.append(tmpl)
            sample_meta.append((fi, si))

    print(f"loaded {len(frames)} frames, {len(samples)} valid slot samples")
    clusters = cluster_by_hamming(samples, threshold=120)
    print(f"{len(clusters)} clusters total")

    # For each known sample, find its cluster and the residual to that cluster's template.
    cluster_to_labels: dict[int, list[str]] = {}
    for fi, si, label in KNOWN_SAMPLES:
        # Find sample index
        try:
            idx = sample_meta.index((fi, si))
        except ValueError:
            print(f"  sample f{fi}s{si} not found (filtered out)", file=sys.stderr)
            continue
        sample = samples[idx]
        # Find which cluster this sample belongs to
        found = False
        for ci, cl in enumerate(clusters):
            if idx in cl.members:
                cluster_to_labels.setdefault(ci, []).append(label)
                resid = hamming(sample, cl.template) if cl.template is not None else -1
                print(f"  f{fi:03d}s{si} -> C{ci:2d} (N={len(cl.members):3d}) label='{label}' resid={resid}")
                found = True
                break
        if not found:
            print(f"  f{fi:03d}s{si} not in any cluster", file=sys.stderr)

    # Determine the dominant label per cluster
    print("\nCluster label votes:")
    for ci in sorted(cluster_to_labels):
        labels = cluster_to_labels[ci]
        from collections import Counter
        cnt = Counter(labels)
        dominant = cnt.most_common(1)[0]
        print(f"  C{ci:2d}: {dict(cnt)} -> dominant '{dominant[0]}' ({dominant[1]}/{len(labels)})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
