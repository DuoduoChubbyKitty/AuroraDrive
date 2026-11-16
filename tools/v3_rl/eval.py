"""Corner-behaviour evaluation for the V3 RL policy.

The product question is "does the model dare to take the corner?" -- so we report,
on HUMAN-driven frames only:
  * hesitation rate: human turned (horizontal != NONE) but policy said NONE.
  * brake-stop rate: human turned but model said S (braking/stopping).
  * agreement with the human on vertical / horizontal.

All inputs are validated (same length, 1-D, in-range classes). Zero turning
frames -> rates are reported as N/A (None), not a misleading 0%.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import numpy as np

VERT_NONE, VERT_S = 1, 2
HORIZ_NONE = 1


def _bit(row: Dict[str, str], k: str) -> int:
    return 1 if str(row.get(k, "0")).strip() not in ("", "0", "False") else 0


def load_labels(clip_dir: Path):
    """Human labels (vertical, horizontal) from controls.csv."""
    with open(Path(clip_dir) / "controls.csv", newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    n = len(rows)
    v = np.zeros(n, dtype=np.int64)
    h = np.zeros(n, dtype=np.int64)
    for i, r in enumerate(rows):
        w, a, s, d = _bit(r, "w"), _bit(r, "a"), _bit(r, "s"), _bit(r, "d")
        v[i] = 0 if w else (VERT_S if s else VERT_NONE)
        h[i] = 0 if a else (2 if d else HORIZ_NONE)
    return v, h


def load_human_mask(clip_dir: Path) -> Optional[np.ndarray]:
    """True where codrive.csv says the frame is a human (rescue) demonstration.
    Returns None when there is no codrive.csv (treat the whole clip as human)."""
    co = Path(clip_dir) / "codrive.csv"
    if not co.exists():
        return None
    with open(co, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    d: Dict[int, bool] = {}
    for r in rows:
        try:
            fr = int(str(r.get("frame", "")).strip())
        except ValueError:
            continue
        d[fr] = str(r.get("source", "")).strip().upper() == "HUMAN"
    n_ctrl = sum(1 for _ in open(Path(clip_dir) / "controls.csv", encoding="utf-8")) - 1
    mask = np.zeros(max(n_ctrl, 0), dtype=bool)
    for fr, is_h in d.items():
        if 0 <= fr < mask.shape[0]:
            mask[fr] = is_h
    return mask


def _validate(name: str, a: np.ndarray, num_classes: int) -> np.ndarray:
    a = np.asarray(a)
    if a.ndim != 1:
        raise ValueError(f"{name} 必须是一维数组，实际 shape={a.shape}")
    if a.size and not np.issubdtype(a.dtype, np.integer):
        raise ValueError(f"{name} 必须是整数类别数组，实际 dtype={a.dtype}")
    if a.size and (a.min() < 0 or a.max() >= num_classes):
        raise ValueError(f"{name} 含越界类别（应在 [0,{num_classes})），min={a.min()},max={a.max()}")
    return a


@dataclass
class CornerEval:
    turning_frames: int
    hesitant_frames: int
    brake_stop_frames: int
    vertical_agree: int
    horizontal_agree: int
    total: int

    def to_dict(self) -> Dict[str, Optional[float]]:
        t = max(self.total, 1)
        turn = self.turning_frames
        return {
            "total_frames": self.total,
            "turning_frames": self.turning_frames,
            "hesitation_rate": (self.hesitant_frames / turn) if turn else None,
            "brake_stop_rate": (self.brake_stop_frames / turn) if turn else None,
            "vertical_agreement": self.vertical_agree / t,
            "horizontal_agreement": self.horizontal_agree / t,
        }


def evaluate_predictions(pred_v, pred_h, label_v, label_h) -> CornerEval:
    pred_v = _validate("pred_v", pred_v, 3)
    pred_h = _validate("pred_h", pred_h, 3)
    label_v = _validate("label_v", label_v, 3)
    label_h = _validate("label_h", label_h, 3)
    n = label_v.shape[0]
    if not (pred_v.shape[0] == pred_h.shape[0] == label_h.shape[0] == n):
        raise ValueError(
            f"evaluate_predictions: 四个输入长度必须一致，"
            f"实际 {pred_v.shape[0]},{pred_h.shape[0]},{label_v.shape[0]},{label_h.shape[0]}")
    turning = label_h != HORIZ_NONE
    hesitant = turning & (pred_h == HORIZ_NONE)
    brake_stop = turning & (pred_v == VERT_S)
    return CornerEval(
        turning_frames=int(turning.sum()),
        hesitant_frames=int(hesitant.sum()),
        brake_stop_frames=int(brake_stop.sum()),
        vertical_agree=int((pred_v == label_v).sum()),
        horizontal_agree=int((pred_h == label_h).sum()),
        total=int(n),
    )


def evaluate_clip_with_policy(clip_dir: Path, policy_v_fn, policy_h_fn) -> CornerEval:
    """Evaluate a clip, restricted to HUMAN frames when codrive.csv exists.

    ``policy_v_fn`` / ``policy_h_fn`` map the human label arrays to predicted
    vertical/horizontal classes (callers bind a trained policy); this indirection
    keeps the metric unit-testable without a model.
    """
    lv, lh = load_labels(clip_dir)
    pv = np.asarray(policy_v_fn(lv))
    ph = np.asarray(policy_h_fn(lh))
    mask = load_human_mask(clip_dir)
    if mask is not None and mask.shape[0] == lv.shape[0] and mask.any():
        lv, lh = lv[mask], lh[mask]
        pv, ph = pv[mask], ph[mask]
    return evaluate_predictions(pv, ph, lv, lh)


def format_report(name: str, ce: CornerEval) -> str:
    d = ce.to_dict()
    def pct(x):
        return "N/A" if x is None else f"{x*100:.1f}%"
    return (f"[eval] {name}: frames={d['total_frames']} turning={d['turning_frames']} "
            f"hesitation={pct(d['hesitation_rate'])} brake_stop={pct(d['brake_stop_rate'])} "
            f"v_agree={pct(d['vertical_agreement'])} h_agree={pct(d['horizontal_agreement'])}")
