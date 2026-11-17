"""Tests for train_rl data-loading against the CURRENT implementation.

The legacy numpy-only helpers no longer exist and are not tested here. We cover
what is real:
  * _bit        : truthy string coercion;
  * _load_codrive: parses codrive.csv keyed by frame, None when absent;
  * build_clip_tensors: source split (AI/HUMAN/UNKNOWN), and the human-score
                        wiring (human_scores.csv present vs absent);
  * _load_human_scores : t,score parsing with bad rows skipped.

All inputs are tiny synthetic ClipCaches + CSV files -- no real clips, no model.
"""

import sys
import tempfile
from pathlib import Path

import numpy as np

_HERE = Path(__file__).resolve()
sys.path.insert(0, str(_HERE.parents[1]))   # tools/v3_rl
sys.path.insert(0, str(_HERE.parents[3]))   # repo root
import train_rl as T  # noqa: E402
from tests import _harness as H  # noqa: E402

# Use train_rl's OWN module objects for features/reward so ClipCache and
# HumanEvent are the exact same classes train_rl constructs internally (avoids
# the top-level `features` vs `tools.v3_rl.features` dual-module identity trap).
F = T.F
R = T.R


def _fake_cache(n: int = 4, speed: float = 10.0) -> "F.ClipCache":
    return F.ClipCache(
        state_token=np.zeros((n, 8), dtype=np.float32),
        orig_vlogit=np.zeros((n, 3), dtype=np.float32),
        orig_hlogit=np.zeros((n, 3), dtype=np.float32),
        vertical=np.zeros(n, dtype=np.int64),
        horizontal=np.zeros(n, dtype=np.int64),
        speed_kmh=np.full(n, speed, dtype=np.float32),
        speed_valid=np.ones(n, dtype=bool),
        frame_times=np.arange(n, dtype=np.float64) / 10.0,
        clip="clip_demo",
    )


def run() -> None:
    # ── _bit ────────────────────────────────────────────────────────────
    H.check_eq(T._bit({"x": "1"}, "x"), 1, "_bit '1' -> 1")
    H.check_eq(T._bit({"x": "0"}, "x"), 0, "_bit '0' -> 0")
    H.check_eq(T._bit({"x": ""}, "x"), 0, "_bit '' -> 0")
    H.check_eq(T._bit({"x": "False"}, "x"), 0, "_bit 'False' -> 0")
    H.check_eq(T._bit({}, "x"), 0, "_bit missing -> 0")
    H.check_eq(T._bit({"x": "true"}, "x"), 1, "_bit 'true' -> 1")

    # ── _load_codrive ───────────────────────────────────────────────────
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_a"
        clip.mkdir()
        H.check(T._load_codrive(clip) is None, "no codrive.csv -> None")
        with open(clip / "codrive.csv", "w", encoding="utf-8") as f:
            f.write("frame,source,took_over,collided,lane_offset\n")
            f.write("0,AI,0,0,0.0\n")
            f.write("1,HUMAN,0,0,0.0\n")
            f.write("bad,AI,0,0,0.0\n")  # non-int frame -> skipped
        co = T._load_codrive(clip)
        H.check(co is not None, "codrive.csv present -> dict")
        H.check_eq(set(co.keys()), {0, 1}, "codrive keyed by valid int frames")
        H.check_eq(co[1]["source"], "HUMAN", "codrive row content preserved")

    # ── build_clip_tensors: no codrive -> whole clip is HUMAN ───────────
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_hum"
        clip.mkdir()
        cache = _fake_cache(4)
        ct = T.build_clip_tensors(cache, clip)
        H.check(np.all(ct.is_human), "no codrive -> all human")
        H.check(not np.any(ct.is_ai), "no codrive -> no AI frames")
        H.check_eq(ct.state_token.shape, (4, 8), "state_token passthrough shape")
        H.check_eq(len(ct.rewards), 4, "rewards length == frames")

    # ── build_clip_tensors: source split with UNKNOWN frames ────────────
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_mix"
        clip.mkdir()
        with open(clip / "codrive.csv", "w", encoding="utf-8") as f:
            f.write("frame,source,took_over,collided,lane_offset\n")
            f.write("0,AI,0,0,0.0\n")
            f.write("1,HUMAN,0,0,0.2\n")
            # frame 2 absent -> UNKNOWN (neither AI nor HUMAN)
            f.write("3,AI,1,1,0.5\n")
        ct = T.build_clip_tensors(_fake_cache(4), clip)
        H.check(np.array_equal(ct.is_ai, [True, False, False, True]),
                "AI frames flagged from source=AI")
        H.check(np.array_equal(ct.is_human, [False, True, False, False]),
                "HUMAN frames flagged from source=HUMAN")
        # KEY regression: an absent frame must NOT be coerced to HUMAN
        H.check_eq(bool(ct.is_human[2]), False, "missing codrive row -> NOT human")
        H.check_eq(bool(ct.is_ai[2]), False, "missing codrive row -> NOT ai (UNKNOWN)")
        H.check_eq(bool(ct.took_over[3]), True, "took_over parsed on frame3")
        H.check_eq(bool(ct.took_over[0]), False, "took_over default 0 on frame0")

    # ── build_clip_tensors: human_scores.csv present vs absent ──────────
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_score"
        clip.mkdir()
        cache = _fake_cache(4, speed=10.0)  # constant speed=10 -> speed_term(10)=-(100-10)/100=-0.9 per frame
        base = T.build_clip_tensors(cache, clip)  # no human_scores.csv
        H.check(np.allclose(base.rewards, -0.9), "no human_scores -> base reward only (speed(10)=-0.9)")
        # explicit human_score_path to a missing file behaves like None
        missing = T.build_clip_tensors(cache, clip, human_score_path=clip / "nope.csv")
        H.check(np.allclose(missing.rewards, base.rewards),
                "missing human_score_path == no-human behaviour")
        # now write a real human_scores.csv: press at t=0.25 -> frames 0,0.1,0.2
        with open(clip / "human_scores.csv", "w", encoding="utf-8") as f:
            f.write("t,score\n0.25,1.0\nbad,0.5\n")  # bad row skipped
        scored = T.build_clip_tensors(cache, clip, human_score_path=clip / "human_scores.csv")
        diff = np.round(scored.rewards - base.rewards, 5)
        H.check(np.array_equal(diff, [1.0, 1.0, 1.0, 0.0]),
                "human score backfilled to (t-window, t] frames only")
        H.check_eq(len(scored.rewards), 4, "scored rewards length")

    # ── _load_human_scores: parsing + bad-row skip ──────────────────────
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "human_scores.csv"
        with open(p, "w", encoding="utf-8") as f:
            f.write("t,score\n0.1,0.5\n0.4,-1.0\nnotanumber,0.3\n0.9,nan\n")
        ev = T._load_human_scores(p)
        H.check_eq(len(ev), 2, "bad/non-finite rows skipped")
        H.check_close(ev[0].t, 0.1, msg="event t parsed")
        H.check_close(ev[0].score, 0.5, msg="event score parsed")
        H.check(isinstance(ev[0], R.HumanEvent), "parsed into reward.HumanEvent")
        H.check_close(ev[1].score, -1.0, msg="negative score preserved")

    # ── assemble: discovers human_scores.csv only when asked ────────────
    # (uses load_cached_clips; skip if no npz cache dir -- just assert the
    #  empty-dir error path is explicit, not a silent empty list.)
    with tempfile.TemporaryDirectory() as tmp:
        H.check_raises(lambda: T.assemble(Path(tmp)), FileNotFoundError,
                       "assemble empty cache dir raises FileNotFoundError")

    # ── REGRESSION (Codex round-2 #6): missing codrive must NOT be defaulted ──
    # to "whole clip is human demo" when require_codrive=True.
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_nocodrive"
        clip.mkdir()
        cache = _fake_cache(4, speed=10.0)
        # default (require_codrive=False): whole clip treated as human demo
        ct_expert = T.build_clip_tensors(cache, clip, require_codrive=False)
        H.check(bool(np.all(ct_expert.is_human)), "no codrive + not required -> all HUMAN (expert demo)")
        # require_codrive=True: must raise, not silently label as human
        H.check_raises(lambda: T.build_clip_tensors(cache, clip, require_codrive=True),
                       FileNotFoundError, "no codrive + require_codrive -> raise (no silent HUMAN)")

    # ── REGRESSION (Codex round-2 #4): codrive looked up by REAL frame id, ──
    # not compacted position. Simulate a dataset that skipped frames 1,3,4.
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_gap"
        clip.mkdir()
        # real frame numbers present: 0, 2, 5, 6 (gaps at 1,3,4)
        ids = [0, 2, 5, 6]
        cache = F.ClipCache(
            state_token=np.zeros((4, 8), dtype=np.float32),
            orig_vlogit=np.zeros((4, 3), dtype=np.float32),
            orig_hlogit=np.zeros((4, 3), dtype=np.float32),
            vertical=np.zeros(4, dtype=np.int64),
            horizontal=np.zeros(4, dtype=np.int64),
            speed_kmh=np.full(4, 10.0, dtype=np.float32),
            speed_valid=np.ones(4, dtype=bool),
            frame_times=np.array([0.0, 0.2, 0.5, 0.6]),
            clip="clip_gap",
            frame_ids=np.array(ids, dtype=np.int64),
        )
        with open(clip / "codrive.csv", "w", encoding="utf-8") as f:
            f.write("frame,source,took_over,collided,lane_offset\n")
            f.write("0,ai,0,0,0.0\n")
            f.write("2,human,1,0,0.0\n")   # real frame 2 == position 1
            f.write("5,ai,0,0,0.0\n")      # real frame 5 == position 2
            f.write("6,human,0,0,0.0\n")   # real frame 6 == position 3
        ct = T.build_clip_tensors(cache, clip)
        H.check(np.array_equal(ct.is_human, [False, True, False, True]),
                "codrive mapped by real frame id (gap-safe), not position")
        H.check(np.array_equal(ct.is_ai, [True, False, True, False]),
                "AI flags mapped by real frame id (gap-safe)")
        H.check(np.array_equal(ct.took_over, [False, True, False, False]),
                "took_over mapped by real frame id (gap-safe)")

    # ── REGRESSION (Codex round-2 B3): old cache without frame_ids must be rejected ──
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "clip_old.npz"
        np.savez_compressed(p,
            state_token=np.zeros((2, 8), np.float32), orig_vlogit=np.zeros((2, 3), np.float32),
            orig_hlogit=np.zeros((2, 3), np.float32), vertical=np.zeros(2, np.int64),
            horizontal=np.zeros(2, np.int64), speed_kmh=np.zeros(2, np.float32),
            speed_valid=np.ones(2, bool), frame_times=np.array([0.0, 0.1]), clip="clip_old")
        H.check_raises(lambda: F.ClipCache.load(p), ValueError,
                       "old cache (no frame_ids) rejected, not silently reindexed")

    # ── REGRESSION (Codex round-2 B2): source=UNKNOWN frames excluded from AI & HUMAN ──
    with tempfile.TemporaryDirectory() as tmp:
        clip = Path(tmp) / "clip_unknown"
        clip.mkdir()
        cache = _fake_cache(3)
        with open(clip / "codrive.csv", "w", encoding="utf-8") as f:
            f.write("frame,source,took_over,collided,lane_offset\n")
            f.write("0,AI,0,0,0.0\n")
            f.write("1,UNKNOWN,0,0,0.0\n")
            f.write("2,HUMAN,1,0,0.0\n")
        ct = T.build_clip_tensors(cache, clip)
        H.check(np.array_equal(ct.is_ai, [True, False, False]), "UNKNOWN not counted as AI")
        H.check(np.array_equal(ct.is_human, [False, False, True]), "UNKNOWN not counted as HUMAN")
