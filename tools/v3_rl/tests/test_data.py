"""Tests for train_rl data loading / encoding using tiny synthetic clips."""

import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import train_rl as T  # noqa: E402
from tests import _harness as H  # noqa: E402

_CSV_HEADER = "t_sec,frame,speed_kmh,w,a,s,d,shift,space,super_brake,ultimate_brake\n"


def _write_csv(path: Path, rows):
    with open(path, "w", encoding="utf-8") as f:
        f.write(_CSV_HEADER)
        for r in rows:
            f.write(",".join(str(x) for x in r) + "\n")


def run() -> None:
    # ── action helpers ──────────────────────────────────────────────────
    H.check_eq(T.joint_action(2, 1), 7, "joint action 2,1")
    H.check_eq(T.split_action(7), (2, 1), "split action 7")
    for v in range(3):
        for h in range(3):
            H.check_eq(T.split_action(T.joint_action(v, h)), (v, h), f"roundtrip {v},{h}")
    H.check(np.array_equal(T.onehot_vertical(1), [0, 1, 0]), "onehot vertical 1")
    H.check(np.array_equal(T.onehot_horizontal(2), [0, 0, 1]), "onehot horizontal 2")

    # ── encode_kinematics ───────────────────────────────────────────────
    speeds = [0.0, 50.0, 120.0]
    valid = [1.0, 1.0, 0.0]
    keys = [
        {"w": 1, "a": 0, "s": 0, "d": 0, "shift": 0, "space": 0},
        {"w": 0, "a": 1, "s": 0, "d": 0, "shift": 1, "space": 0},
        {"w": 0, "a": 0, "s": 1, "d": 0, "shift": 0, "space": 1},
    ]
    feats = T.encode_kinematics(speeds, valid, keys)
    H.check_eq(feats.shape, (3, 18), "encode shape")
    H.check_close(float(feats[0, 0]), 0.0, msg="speed0 normalized")
    H.check_close(float(feats[1, 0]), 0.5, msg="speed50 -> 0.5")
    H.check_close(float(feats[2, 0]), 0.0, msg="invalid speed -> 0 feature")
    H.check_close(float(feats[2, 1]), 0.0, msg="invalid flag 0")
    H.check_close(float(feats[1, 1]), 1.0, msg="valid flag 1")
    H.check_close(float(feats[0, 2]), 1.0, msg="stuck flag (0 km/h valid)")
    H.check_close(float(feats[1, 2]), 0.0, msg="not stuck at 50")
    # keys at cols 3..8 (w,a,s,d,shift,space)
    H.check_close(float(feats[0, 3]), 1.0, msg="row0 w set")
    H.check_close(float(feats[1, 4]), 1.0, msg="row1 a set")
    H.check_close(float(feats[1, 7]), 1.0, msg="row1 shift set")
    H.check_close(float(feats[2, 8]), 1.0, msg="row2 space set")
    # no prev keys -> has_prev=0, cos heading=1
    H.check_close(float(feats[0, 9]), 0.0, msg="no prev")
    H.check_close(float(feats[0, 17]), 1.0, msg="cos0=1")
    # length mismatch raises
    H.check_raises(lambda: T.encode_kinematics([1.0], [], keys), ValueError, "len mismatch raises")

    # with prev keys
    pk = [None, keys[0], keys[1]]
    feats2 = T.encode_kinematics(speeds, valid, keys, prev_keys=pk)
    H.check_close(float(feats2[1, 9]), 1.0, msg="row1 has prev")
    H.check_close(float(feats2[1, 10]), 1.0, msg="row1 prev w set (from row0)")
    H.check_close(float(feats2[2, 11]), 1.0, msg="row2 prev a set (from row1)")

    # ── build_encoded_episodes ──────────────────────────────────────────
    ep = T.build_encoded_episodes(
        speeds, valid, keys, [0, 2, 1], [1, 0, 2], [True, False, True],
        [1.0, -2.0, 0.5])
    H.check_eq(len(ep), 3, "episodes len")
    H.check(np.array_equal(ep.vertical, [0, 2, 1]), "episodes vertical")
    H.check(np.array_equal(ep.horizontal, [1, 0, 2]), "episodes horizontal")
    H.check(np.array_equal(ep.has_human, [True, False, True]), "episodes has_human")
    H.check_close(float(ep.reward[1]), -2.0, msg="episode reward passthrough")

    # ── load_episodes_from_controls (synthetic clip) ───────────────────
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_000"
        clip.mkdir()
        rows = [
            # t, frame, speed, w,a,s,d,shift,space,super,ult
            (0.000, 0, 50.0, 1, 0, 0, 0, 0, 0, 0, 0),
            (0.067, 1, 50.0, 0, 1, 0, 0, 0, 0, 0, 0),
            (0.133, 2, "", 0, 0, 1, 0, 0, 0, 0, 0),
        ]
        _write_csv(clip / "controls.csv", rows)
        ep3 = T.load_episodes_from_controls(clip)
        H.check_eq(len(ep3), 3, "controls clip len")
        H.check(np.array_equal(ep3.vertical, [0, 1, 2]), "controls vertical labels")
        H.check(np.array_equal(ep3.horizontal, [1, 0, 1]), "controls horizontal labels")
        # all human by default
        H.check(np.all(ep3.has_human), "all human default")
        # speed validity: row2 empty speed -> invalid
        H.check_close(float(ep3.features[2, 1]), 0.0, msg="row2 invalid speed")

        # now add codrive.csv overriding source/takeover
        _write_csv(clip / "codrive.csv", rows)  # dummy, we will overwrite with custom
        with open(clip / "codrive.csv", "w", encoding="utf-8") as f:
            f.write("frame,source,took_over,collided,lane_offset\n")
            f.write("0,ai,0,0,0.0\n")
            f.write("1,human,0,0,0.2\n")
            f.write("2,ai,1,0,0.0\n")
        ep4 = T.load_episodes_from_controls(clip)
        H.check(np.array_equal(ep4.has_human, [False, True, False]), "codrive source split")
        # row2 takeover -> strong negative reward
        H.check(ep4.reward[2] < -5.0, f"takeover reward strongly negative ({ep4.reward[2]:.2f})")

    # missing controls.csv raises
    with tempfile.TemporaryDirectory() as tmp2:
        H.check_raises(lambda: T.load_episodes_from_controls(Path(tmp2)), FileNotFoundError,
                       "missing controls raises")

    # ── load_v3_state_dict guarded (missing file -> None) ───────────────
    H.check(T.load_v3_state_dict(None) is None, "None ckpt -> None")
    H.check(T.load_v3_state_dict(Path("/nonexistent/xx.pt")) is None, "missing ckpt -> None")

    # ── train() end to end on synthetic clips (bc + ppo) ───────────────
    with tempfile.TemporaryDirectory() as tmp:
        for ci in range(2):
            clip = Path(tmp) / f"clip_{ci:03d}"
            clip.mkdir()
            rows = []
            for i in range(40):
                sp = 40.0 + i
                rows.append((i * 0.067, i, sp, 1, 0, 0, 0, 0, 0, 0, 0))
            _write_csv(clip / "controls.csv", rows)
        res_bc = T.train(Path(tmp), stage="bc", epochs=2, batch_size=16, seed=1)
        H.check_eq(res_bc["stage"], "bc", "bc stage result")
        H.check(res_bc["frames"] == 80, f"bc frames={res_bc['frames']}")
        H.check(len(res_bc["history"]) == 2, "bc history len")
        res_ppo = T.train(Path(tmp), stage="ppo", epochs=2, batch_size=16, seed=1)
        H.check_eq(res_ppo["stage"], "ppo", "ppo stage result")
        H.check(len(res_ppo["history"]) == 2, "ppo history len")
        # lambda decays over epochs
        lam0 = res_ppo["history"][0]["lambda_imitation"]
        lam1 = res_ppo["history"][1]["lambda_imitation"]
        H.check(lam1 < lam0, f"lambda decays ({lam0}->{lam1})")
        # snapshots recorded
        H.check(len(res_ppo["snapshots"]) == 2, "ppo snapshots recorded")
