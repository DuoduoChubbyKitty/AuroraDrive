#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the final labeled speed_glyphs.json from clip_20260815_130055.

This version uses a semi-automatic seed-and-expand strategy:
  1. Start from a small set of manually-verified (frame, slot, digit) samples.
  2. For each digit, build a seed template by majority vote over its known samples.
  3. Expand the set by adding all samples whose Hamming distance to the seed
     template is below a per-digit threshold (loose enough to capture real
     variants, tight enough to exclude other digits).
  4. Recompute a final majority-vote template from the expanded set.
  5. Write models/speed_glyphs.json with all 0-9 templates.

The seed samples were read directly from the recorded ROI frames via multimodal
inspection; the expansion is deterministic and auditable.
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from build_speed_glyphs import (
    GLYPH_ROI_NORM,
    TEMPLATE_H,
    TEMPLATE_W,
    SLOT_CENTERS_NORM,
    SLOT_WIDTH_NORM,
    SLOT_Y_MAX_NORM,
    SLOT_Y_MIN_NORM,
    crop_slot,
    hamming,
    load_frames,
    make_template,
)

# Manually verified (frame_idx, slot_idx, digit_label) seeds.
# These were read directly from the 236x96 ROI frames.
SEED_SAMPLES: list[tuple[int, int, str]] = [
    # digit 0 (idle / low speed)
    (83, 0, "0"), (83, 1, "0"), (83, 2, "0"),
    (150, 1, "0"), (150, 2, "0"),
    (191, 0, "0"), (210, 0, "0"), (258, 0, "0"),
    (329, 0, "0"), (329, 2, "0"),
    (353, 0, "0"), (353, 1, "0"),
    (377, 0, "0"), (401, 0, "0"),
    # digit 1 (hundreds place at >=100 km/h)
    (150, 0, "1"), (282, 0, "1"), (306, 0, "1"), (401, 0, "1"),
    # digit 2
    (258, 2, "2"),
    # digit 3
    (191, 1, "3"),
    # digit 4
    (186, 2, "4"), (282, 2, "4"), (306, 2, "4"), (401, 1, "4"),
    # digit 5
    (282, 1, "5"), (353, 2, "5"), (401, 2, "5"),
    # digit 6
    (191, 2, "6"), (210, 1, "6"),
    # digit 7
    (377, 1, "7"),
    # digit 8
    (258, 1, "8"), (329, 1, "8"),
    # digit 9
    (210, 2, "9"), (377, 2, "9"),
]

# Expansion thresholds (Hamming distance). Tuned per digit based on visual
# diversity: 0/6/8/9 have hollow loops and can look similar, so kept tight.
EXPAND_THRESHOLDS: dict[str, int] = {
    "0": 120,
    "1": 100,
    "2": 100,
    "3": 100,
    "4": 100,
    "5": 100,
    "6": 120,
    "7": 100,
    "8": 120,
    "9": 120,
}


def majority_vote(samples: list[np.ndarray]) -> np.ndarray:
    """Bit-wise majority vote across samples."""
    arr = np.stack(samples, axis=0)
    counts = arr.sum(axis=0)
    return (counts >= (arr.shape[0] / 2)).astype(np.uint8)


def main() -> int:
    clip_dir = Path("data/glyph_clips/clip_20260815_130055/frames")
    out_path = Path("models/speed_glyphs.json")

    print(f"[1/3] load frames from {clip_dir} ...")
    frames = load_frames(clip_dir)
    print(f"      loaded {len(frames)} frames")

    print("[2/3] crop slots + binarize + resize + quality filter ...")
    samples: list[np.ndarray] = []
    sample_meta: list[tuple[int, int]] = []
    for fi, gray in enumerate(frames):
        for si in range(3):
            sub = crop_slot(gray, si, roi=GLYPH_ROI_NORM)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            fg = int(tmpl.sum())
            # Reject nearly-empty or over-full crops (transition frames / glare)
            if fg < 50 or fg > 1000:
                continue
            samples.append(tmpl)
            sample_meta.append((fi, si))
    print(f"      {len(samples)} valid slot samples")

    print("[3/3] seed + expand per digit ...")
    meta_index: dict[tuple[int, int], int] = {
        (fi, si): i for i, (fi, si) in enumerate(sample_meta)
    }

    digit_samples: dict[str, list[np.ndarray]] = defaultdict(list)

    # Seed templates from manually verified samples.
    seed_by_digit: dict[str, list[np.ndarray]] = defaultdict(list)
    for fi, si, label in SEED_SAMPLES:
        idx = meta_index[(fi, si)]
        seed_by_digit[label].append(samples[idx])

    seed_templates: dict[str, np.ndarray] = {}
    for label in "0123456789":
        seed_templates[label] = majority_vote(seed_by_digit[label])
        print(f"      seed '{label}': {len(seed_by_digit[label])} samples, sum={int(seed_templates[label].sum())}")

    # Expand: assign every sample to the nearest seed template if within threshold.
    for s in samples:
        best_label: str | None = None
        best_resid = 10_000
        for label, tmpl in seed_templates.items():
            r = hamming(s, tmpl)
            if r < best_resid:
                best_resid = r
                best_label = label
        if best_label is not None and best_resid <= EXPAND_THRESHOLDS[best_label]:
            digit_samples[best_label].append(s)

    # Build final templates from expanded sets.
    templates: dict[str, list[list[int]]] = {}
    for d in range(10):
        key = str(d)
        members = digit_samples[key]
        if not members:
            print(f"  warning: digit '{key}' has no samples", file=sys.stderr)
            continue
        tmpl = majority_vote(members)
        templates[key] = tmpl.astype(int).tolist()
        print(f"      final '{key}': n={len(members):3d} sum={int(tmpl.sum()):3d} "
              f"bbox={np.argwhere(tmpl==1).min(0).tolist()}..{np.argwhere(tmpl==1).max(0).tolist()}")

    glyph = {
        "version": 1,
        "template_width": TEMPLATE_W,
        "template_height": TEMPLATE_H,
        "slot_centers_norm": list(SLOT_CENTERS_NORM),
        "slot_width_norm": SLOT_WIDTH_NORM,
        "slot_y_min_norm": SLOT_Y_MIN_NORM,
        "slot_y_max_norm": SLOT_Y_MAX_NORM,
        "templates": templates,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(glyph, ensure_ascii=False, indent=2))
    print(f"\nfinal glyph library -> {out_path}")
    print(f"digits present: {sorted(templates.keys())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
