"""Evaluation utilities for the V3 RL policy.

The product-relevant question is "does the model dare to take the corner?" -- not
aggregate accuracy. So we report, per clip:

  * corner entry hesitation rate: fraction of frames where a human took a turn
    (horizontal != NONE) but the frozen V3 policy predicts NONE (i.e. it chickened
    out of steering into the corner).
  * corner brake-stop rate: fraction of human-turning frames where the policy
    predicts vertical == S (braking/stopping instead of carrying speed through).
  * action agreement with the human on vertical / horizontal.

These are computed from recorded labels only; no position data needed.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import numpy as np

_VERT_NONE = 1
_HORIZ_NONE = 1
_VERT_S = 2


def _bit(row: Dict[str, str], k: str) -> int:
    return 1 if str(row.get(k, "0")).strip() not in ("", "0", "False") else 0


def load_labels(clip_dir: Path):
    """Return (vertical[N], horizontal[N]) *human* labels from controls.csv."""
    clip_dir = Path(clip_dir)
    with open(clip_dir / "controls.csv", newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    v = np.zeros(len(rows), dtype=np.int64)
    h = np.zeros(len(rows), dtype=np.int64)
    for i, r in enumerate(rows):
        w, a, s, d = _bit(r, "w"), _bit(r, "a"), _bit(r, "s"), _bit(r, "d")
        v[i] = 0 if w else (_VERT_S if s else _VERT_NONE)
        h[i] = 0 if a else (2 if d else _HORIZ_NONE)
    return v, h


@dataclass
class CornerEval:
    turning_frames: int
    hesitant_frames: int       # human turned, model said NONE
    brake_stop_frames: int     # human turned, model said S
    vertical_agree: int
    horizontal_agree: int
    total: int

    def to_dict(self) -> Dict[str, float]:
        t = max(self.total, 1)
        turn = max(self.turning_frames, 1)
        return {
            "total_frames": self.total,
            "turning_frames": self.turning_frames,
            "hesitation_rate": self.hesitant_frames / turn,
            "brake_stop_rate": self.brake_stop_frames / turn,
            "vertical_agreement": self.vertical_agree / t,
            "horizontal_agreement": self.horizontal_agree / t,
        }


def evaluate_predictions(
    pred_v: np.ndarray, pred_h: np.ndarray,
    label_v: np.ndarray, label_h: np.ndarray,
) -> CornerEval:
    """Compare policy predictions against human labels (same-length arrays)."""
    pred_v = np.asarray(pred_v); pred_h = np.asarray(pred_h)
    label_v = np.asarray(label_v); label_h = np.asarray(label_h)
    n = len(label_v)
    if not (len(pred_v) == len(pred_h) == n):
        raise ValueError("evaluate_predictions: length mismatch")
    turning = label_h != _HORIZ_NONE
    hesitant = turning & (pred_h == _HORIZ_NONE)
    brake_stop = turning & (pred_v == _VERT_S)
    return CornerEval(
        turning_frames=int(turning.sum()),
        hesitant_frames=int(hesitant.sum()),
        brake_stop_frames=int(brake_stop.sum()),
        vertical_agree=int((pred_v == label_v).sum()),
        horizontal_agree=int((pred_h == label_h).sum()),
        total=int(n),
    )


def evaluate_clip_with_policy(clip_dir: Path, policy_vertical_fn, policy_horizontal_fn) -> CornerEval:
    """Evaluate a clip given two callables that map a feature row to a class.

    ``policy_vertical_fn`` / ``policy_horizontal_fn`` take an ``EncodedEpisodes``
    and return predicted class arrays. This indirection keeps eval decoupled from
    the exact policy implementation.
    """
    from tools.v3_rl.train_rl import load_episodes_from_controls

    ep = load_episodes_from_controls(Path(clip_dir))
    pv = policy_vertical_fn(ep)
    ph = policy_horizontal_fn(ep)
    lv, lh = load_labels(Path(clip_dir))
    return evaluate_predictions(pv, ph, lv, lh)


def format_report(name: str, ce: CornerEval) -> str:
    d = ce.to_dict()
    return (
        f"[eval] {name}: frames={d['total_frames']} turning={d['turning_frames']} "
        f"hesitation={d['hesitation_rate']*100:.1f}% brake_stop={d['brake_stop_rate']*100:.1f}% "
        f"v_agree={d['vertical_agreement']*100:.1f}% h_agree={d['horizontal_agreement']*100:.1f}%"
    )
