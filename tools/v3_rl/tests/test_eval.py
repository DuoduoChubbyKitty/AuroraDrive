"""Tests for eval.py corner-hesitation metrics."""

import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import eval as E  # noqa: E402
from tests import _harness as H  # noqa: E402

_CSV_HEADER = "t_sec,frame,speed_kmh,w,a,s,d,shift,space,super_brake,ultimate_brake\n"


def run() -> None:
    # ── evaluate_predictions on hand cases ──────────────────────────────
    # human: frame0 turn left(a), turn right(d), straight; vertical W,W,S
    label_v = np.array([0, 0, 2, 0])
    label_h = np.array([0, 2, 1, 1])   # a, d, NONE, NONE
    # model: hesitates (NONE) on the two real turns, straight agrees
    pred_v = np.array([0, 0, 1, 0])
    pred_h = np.array([1, 1, 1, 1])
    ce = E.evaluate_predictions(pred_v, pred_h, label_v, label_h)
    H.check_eq(ce.total, 4, "eval total")
    H.check_eq(ce.turning_frames, 2, "turning frames (frame0,1)")
    H.check_eq(ce.hesitant_frames, 2, "hesitant frames (model NONE on turns)")
    H.check_eq(ce.brake_stop_frames, 0, "no brake-stop")
    H.check_eq(ce.vertical_agree, 3, "vertical agree 3/4")
    H.check_eq(ce.horizontal_agree, 2, "horizontal agree 2/4 (both NONE frames)")
    d = ce.to_dict()
    H.check_close(d["hesitation_rate"], 1.0, msg="hesitation 100%")
    H.check_close(d["brake_stop_rate"], 0.0, msg="brake stop 0")
    H.check_close(d["vertical_agreement"], 0.75, msg="v agreement 0.75")
    H.check_close(d["horizontal_agreement"], 0.5, msg="h agreement 0.5")

    # ── brake-stop case: model says S on turns ──────────────────────────
    pred_v2 = np.array([2, 2, 1, 0])
    ce2 = E.evaluate_predictions(pred_v2, label_h, label_v, label_h)
    H.check_eq(ce2.brake_stop_frames, 2, "brake stop on both turns")
    H.check_close(ce2.to_dict()["brake_stop_rate"], 1.0, msg="brake stop rate 1")

    # ── no turns -> rates 0, no division by zero ────────────────────────
    ce3 = E.evaluate_predictions(np.array([0, 1]), np.array([1, 1]),
                                 np.array([0, 1]), np.array([1, 1]))
    H.check_eq(ce3.turning_frames, 0, "no turns")
    H.check_close(ce3.to_dict()["hesitation_rate"], 0.0, msg="no-turn hesitation safe")
    H.check_close(ce3.to_dict()["brake_stop_rate"], 0.0, msg="no-turn brake-stop safe")

    # ── length mismatch raises ──────────────────────────────────────────
    H.check_raises(lambda: E.evaluate_predictions(np.array([0]), np.array([0, 1]),
                                                  np.array([0]), np.array([0, 1])),
                   ValueError, "length mismatch raises")

    # ── load_labels from synthetic controls.csv ─────────────────────────
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_000"
        clip.mkdir()
        with open(clip / "controls.csv", "w", encoding="utf-8") as f:
            f.write(_CSV_HEADER)
            f.write("0.0,0,50,1,0,0,0,0,0,0,0\n")   # W, NONE
            f.write("0.1,1,50,0,1,0,0,0,0,0,0\n")   # NONE, A
            f.write("0.2,2,50,0,0,1,0,0,0,0,0\n")   # S, NONE
            f.write("0.3,3,50,0,0,0,1,0,0,0,0\n")   # NONE, D
        lv, lh = E.load_labels(clip)
        H.check(np.array_equal(lv, [0, 1, 2, 1]), "load_labels vertical")
        H.check(np.array_equal(lh, [1, 0, 1, 2]), "load_labels horizontal")

    # ── format_report returns a non-empty string with key tokens ────────
    rep = E.format_report("testclip", ce)
    H.check("hesitation" in rep and "brake_stop" in rep, "report contains keys")
    H.check("testclip" in rep, "report contains name")
