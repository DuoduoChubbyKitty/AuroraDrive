"""Tests for reward.py pure functions against the CURRENT implementation.

The reward module is pure numpy: speed/stuck/decel/lane dense terms, backward
human-score backfill by real timestamps, per-episode GAE, advantage
standardisation. No fps/num_frames legacy args, and no discounted-return helper
(that function was removed).
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reward as R  # noqa: E402
from tests import _harness as H  # noqa: E402


def _times(n: int, fps: float = 10.0) -> np.ndarray:
    return np.arange(n, dtype=np.float64) / fps


def run() -> None:
    # ── speed_term ──────────────────────────────────────────────────────
    H.check_close(R.speed_term(0.0, True), 0.0, msg="speed 0 -> 0")
    H.check_close(R.speed_term(50.0, True), 0.5, msg="speed 50 -> 0.5")
    H.check_close(R.speed_term(100.0, True), 1.0, msg="speed 100 -> 1.0")
    H.check_close(R.speed_term(200.0, True), 1.0, msg="speed 200 clamped to 1.0")
    H.check_close(R.speed_term(-5.0, True), 0.0, msg="negative speed -> 0")
    H.check_close(R.speed_term(float("nan"), True), 0.0, msg="NaN speed -> 0")
    H.check_close(R.speed_term(float("inf"), True), 0.0, msg="inf speed -> 0")
    H.check_close(R.speed_term(50.0, False), 0.0, msg="invalid -> 0 (not penalty)")
    H.check_close(R.speed_term(0.5, True), 0.005, msg="small positive speed")

    # ── is_stuck ────────────────────────────────────────────────────────
    H.check(R.is_stuck(0.0, True) is True, "0 km/h valid -> stuck")
    H.check(R.is_stuck(0.9, True) is True, "0.9 km/h valid -> stuck")
    H.check(R.is_stuck(1.0, True) is False, "1.0 km/h -> not stuck (boundary)")
    H.check(R.is_stuck(5.0, True) is False, "5 km/h -> not stuck")
    H.check(R.is_stuck(0.0, False) is False, "0 km/h invalid -> not stuck")
    H.check(R.is_stuck(float("nan"), True) is False, "NaN -> not stuck")

    # ── decel_term (incl. prev_valid OCR-gap guard) ─────────────────────
    H.check_close(R.decel_term(80.0, 80.0, True), 0.0, msg="no change -> 0")
    H.check_close(R.decel_term(80.0, 90.0, True), 0.0, msg="accel -> 0")
    H.check_close(R.decel_term(80.0, 65.0, True), 0.5, msg="15 km/h drop -> 0.5")
    H.check_close(R.decel_term(80.0, 40.0, True), 1.0, msg="40 km/h drop -> saturate")
    H.check_close(R.decel_term(80.0, 40.0, False), 0.0, msg="invalid cur -> 0")
    H.check_close(R.decel_term(float("nan"), 40.0, True), 0.0, msg="NaN prev -> 0")
    H.check_close(R.decel_term(80.0, float("inf"), True), 0.0, msg="inf cur -> 0")
    # prev_valid=False must NOT fabricate decel across an OCR gap
    H.check_close(R.decel_term(80.0, 40.0, True, prev_valid=False), 0.0,
                  msg="prev invalid (OCR gap) -> no fabricated decel")
    H.check_close(R.decel_term(80.0, 40.0, True, prev_valid=True), 1.0,
                  msg="prev valid -> decel counted")

    # ── lane_term ───────────────────────────────────────────────────────
    H.check_close(R.lane_term(0.0), 0.0, msg="centred -> 0")
    H.check_close(R.lane_term(0.5), 0.5, msg="half offset -> 0.5")
    H.check_close(R.lane_term(-0.5), 0.5, msg="symmetric (abs)")
    H.check_close(R.lane_term(1.5), 1.0, msg="clamped to 1")
    H.check_close(R.lane_term(float("nan")), 0.0, msg="NaN -> 0")

    # ── dense_reward composition ────────────────────────────────────────
    w = R.DEFAULT_WEIGHTS
    r_perfect = R.dense_reward(100.0, True, 100.0, 0.0, False)
    H.check_close(r_perfect, w.speed, msg="perfect frame = +speed weight")
    r_stuck = R.dense_reward(0.0, True, 0.0, 0.0, False)
    H.check_close(r_stuck, -w.stuck, msg="stuck frame = -stuck weight")
    r_coll = R.dense_reward(100.0, True, 100.0, 0.0, True)
    H.check_close(r_coll, w.speed - w.collision, msg="collision subtracts")
    r_off = R.dense_reward(100.0, True, 100.0, 0.8, False)
    H.check_close(r_off, w.speed - w.lane * 0.8, msg="lane offset subtracts")
    r_inv = R.dense_reward(0.0, False, 0.0, 0.0, False)
    H.check_close(r_inv, 0.0, msg="invalid speed -> 0 dense")
    # decel path: 80 -> 40 is a 40 km/h drop, saturates decel at 1.0
    r_dec = R.dense_reward(40.0, True, 80.0, 0.0, False)
    H.check_close(r_dec, w.speed * 0.4 - w.decel * 1.0, msg="decel included")
    # prev_valid=False suppresses the decel term in dense_reward
    r_gap = R.dense_reward(40.0, True, 80.0, 0.0, False, prev_valid=False)
    H.check_close(r_gap, w.speed * 0.4, msg="dense: prev invalid -> no decel")

    # ── takeover_reward ─────────────────────────────────────────────────
    H.check_close(R.takeover_reward(False), 0.0, msg="no takeover -> 0")
    H.check_close(R.takeover_reward(True), -w.takeover, msg="takeover -> -weight")
    H.check_close(R.takeover_reward(True, R.RewardWeights(takeover=3.0)), -3.0,
                  msg="custom takeover weight")

    # ── clamp_human_score ───────────────────────────────────────────────
    H.check_close(R.clamp_human_score(0.5), 0.5, msg="in range")
    H.check_close(R.clamp_human_score(2.0), 1.0, msg="clamp high")
    H.check_close(R.clamp_human_score(-2.0), -1.0, msg="clamp low")
    H.check_close(R.clamp_human_score(float("nan")), 0.0, msg="NaN -> 0")

    # ── backfill_human_scores (timestamp matching, backward only) ───────
    ft = _times(20, 10.0)  # 0.0 .. 1.9 s
    # press at t=1.0, window 0.5 -> frames with t in (0.5, 1.0] -> idx 6..10
    sc = R.backfill_human_scores([R.HumanEvent(t=1.0, score=1.0)], ft, judge_window_s=0.5)
    H.check_eq(len(sc), 20, "backfill length")
    H.check_close(float(sc[10]), 1.0, msg="press frame (t=1.0) judged")
    H.check_close(float(sc[6]), 1.0, msg="t=0.6 inside window judged")
    H.check_close(float(sc[5]), 0.0, msg="t=0.5 exactly at lower bound -> excluded")
    H.check_close(float(sc[11]), 0.0, msg="t=1.1 after press -> 0 (no forward smear)")
    H.check_close(float(sc[0]), 0.0, msg="frame 0 -> 0")
    H.check_close(float(sc[19]), 0.0, msg="last frame -> 0")

    # negative score backfilled as-is (clamped)
    sc_neg = R.backfill_human_scores([R.HumanEvent(t=1.0, score=-1.0)], ft)
    H.check_close(float(sc_neg[8]), -1.0, msg="negative score backfilled")

    # out-of-range score clamped to [-1,1]
    sc_clamp = R.backfill_human_scores([R.HumanEvent(t=1.0, score=5.0)], ft)
    H.check_close(float(sc_clamp[9]), 1.0, msg="score >1 clamped to 1")

    # two overlapping events: later press wins in the overlap
    ev2 = [R.HumanEvent(t=0.5, score=1.0), R.HumanEvent(t=0.9, score=-1.0)]
    sc2 = R.backfill_human_scores(ev2, ft)
    H.check_close(float(sc2[9]), -1.0, msg="later event wins on its press frame")
    H.check_close(float(sc2[5]), -1.0, msg="overlap region -> later value")

    # unsorted input: still later-time press wins (impl sorts internally)
    sc_unsorted = R.backfill_human_scores(
        [R.HumanEvent(t=0.9, score=-1.0), R.HumanEvent(t=0.5, score=1.0)], ft)
    H.check_close(float(sc_unsorted[5]), -1.0, msg="unsorted events -> later time wins")

    # empty events -> all zeros, length preserved
    sc_empty = R.backfill_human_scores([], ft[:15])
    H.check(np.allclose(sc_empty, 0.0), "empty events -> all zero")
    H.check_eq(len(sc_empty), 15, "empty events length")

    # press beyond clip -> dropped (no frame in window), not clamped
    sc_far = R.backfill_human_scores([R.HumanEvent(t=100.0, score=1.0)], ft[:10])
    H.check(np.allclose(sc_far, 0.0), "press beyond clip dropped -> all zero")

    # negative press time -> dropped (no frame in window)
    sc_neg_t = R.backfill_human_scores([R.HumanEvent(t=-5.0, score=1.0)], ft[:10])
    H.check(np.allclose(sc_neg_t, 0.0), "negative press dropped -> all zero")

    # NaN score event skipped
    sc_nan = R.backfill_human_scores([R.HumanEvent(t=1.0, score=float("nan"))], ft[:10])
    H.check(np.allclose(sc_nan, 0.0), "NaN score event skipped")

    # empty frame_times -> empty array
    H.check_eq(R.backfill_human_scores([R.HumanEvent(t=0.0, score=1.0)], []).shape, (0,),
               "empty frame_times -> empty")

    # ── compose_frame_reward ────────────────────────────────────────────
    H.check_close(R.compose_frame_reward(1.0, 0.5, False), 1.5, msg="dense + human")
    H.check_close(R.compose_frame_reward(1.0, 0.0, True), 1.0 - w.takeover,
                  msg="takeover folded in")
    H.check_close(R.compose_frame_reward(0.0, 2.0, False), 1.0,
                  msg="human score clamped before use")

    # ── compute_episode_rewards (frame_times based) ─────────────────────
    frames = [
        R.FrameSignals(speed_kmh=50.0, speed_valid=True, lane_offset=0.0,
                       collided=False, took_over=False),
        R.FrameSignals(speed_kmh=50.0, speed_valid=True, lane_offset=0.0,
                       collided=False, took_over=False),
        R.FrameSignals(speed_kmh=0.0, speed_valid=True, lane_offset=0.0,
                       collided=False, took_over=True),
    ]
    times3 = _times(3, 10.0)
    evs = [R.HumanEvent(t=0.0, score=1.0)]  # window (-0.5,0] -> frame0 only
    rew = R.compute_episode_rewards(frames, evs, times3)
    H.check_eq(len(rew), 3, "episode reward length")
    H.check_close(float(rew[0]), 0.5 + 1.0, msg="episode frame0 = speed + human")
    H.check_close(float(rew[2]), -0.5 - w.decel * 1.0 - w.takeover,
                  msg="episode frame2 takeover+stuck+decel")

    # empty episode
    H.check_eq(len(R.compute_episode_rewards([], [], [])), 0, "empty episode -> empty array")

    # length mismatch raises
    H.check_raises(lambda: R.compute_episode_rewards(frames, [], [0.0]),
                   ValueError, "frame_times/frames length mismatch raises")

    # prev_speed tracking: 80 -> 40 penalised on frame1
    frames2 = [
        R.FrameSignals(speed_kmh=80.0, speed_valid=True),
        R.FrameSignals(speed_kmh=40.0, speed_valid=True),
    ]
    rew2 = R.compute_episode_rewards(frames2, [], _times(2, 10.0))
    H.check_close(float(rew2[0]), 0.8, msg="frame0 no decel")
    H.check_close(float(rew2[1]), 0.4 - w.decel * 1.0, msg="frame1 hard decel")

    # prev_valid across an OCR gap: middle frame invalid -> no fake decel after it
    frames_gap = [
        R.FrameSignals(speed_kmh=80.0, speed_valid=True),
        R.FrameSignals(speed_kmh=0.0, speed_valid=False),
        R.FrameSignals(speed_kmh=10.0, speed_valid=True),
    ]
    rew_gap = R.compute_episode_rewards(frames_gap, [], _times(3, 10.0))
    H.check_close(float(rew_gap[2]), 0.1, msg="frame after OCR gap: no fabricated decel")

    # ── normalize_advantages ────────────────────────────────────────────
    na = R.normalize_advantages(np.array([1.0, 2.0, 3.0, 4.0]))
    H.check_close(float(na.mean()), 0.0, tol=1e-5, msg="normalized mean 0")
    H.check_close(float(na.std()), 1.0, tol=1e-5, msg="normalized std 1")
    H.check_eq(len(R.normalize_advantages(np.array([]))), 0, "normalize empty")
    H.check(np.allclose(R.normalize_advantages(np.array([5.0, 5.0, 5.0])), 0.0),
            "constant advantages (std 0) -> all zero")
    z_nan = R.normalize_advantages(np.array([np.nan, 1.0, np.inf]))
    H.check(np.all(z_nan == 0.0), "non-finite advantages -> all zero (never NaN)")
    H.check(np.all(np.isfinite(z_nan)), "non-finite input result is finite")

    # ── gae_advantages (per episode) ────────────────────────────────────
    # constant reward=1, values=0, single episode gamma=0.9 lam=0.8
    adv, vt = R.gae_advantages([1.0, 1.0, 1.0], [0.0, 0.0, 0.0], gamma=0.9, lam=0.8)
    H.check_eq(len(adv), 3, "gae length")
    H.check_close(float(adv[2]), 1.0, msg="gae t2")
    H.check_close(float(adv[1]), 1.0 + 0.9 * 0.8 * 1.0, msg="gae t1 accumulates")
    H.check_close(float(vt[2]), 1.0, msg="vt t2")
    H.check_close(float(vt[0]), float(adv[0]), msg="vt = adv when values 0")

    # KEY per-episode regression: two independent single frames r=0/10 with
    # episode_ends=[T,T] must yield [0,10] -- NOT [9.405,10] (no cross-clip leak).
    adv_e, vt_e = R.gae_advantages([0.0, 10.0], [0.0, 0.0], episode_ends=[True, True])
    H.check_close(float(adv_e[0]), 0.0, msg="episode0 isolated: adv 0 (no leak from ep1)")
    H.check_close(float(adv_e[1]), 10.0, msg="episode1 terminal: adv 10")
    H.check_close(float(vt_e[0]), 0.0, msg="episode0 value_target 0")

    # nonzero values: value_targets = advantages + values
    adv2, vt2 = R.gae_advantages([0.0, 0.0], [0.5, 0.2], gamma=0.9, lam=0.9)
    H.check_close(float(adv2[1]), -0.2, msg="gae t1 with value")
    H.check_close(float(vt2[1]), float(adv2[1]) + 0.2, tol=1e-6, msg="vt = adv + value")
    H.check_close(float(vt2[0]), float(adv2[0]) + 0.5, tol=1e-6, msg="vt0 = adv0 + value0")

    # empty
    a_empty, v_empty = R.gae_advantages([], [])
    H.check_eq(len(a_empty), 0, "empty gae adv")
    H.check_eq(len(v_empty), 0, "empty gae vt")

    # length mismatch raises
    H.check_raises(lambda: R.gae_advantages([1.0], [1.0, 2.0]), ValueError,
                   "gae rewards/values length mismatch raises")

    # weights dataclass defaults sanity
    H.check_eq(R.DEFAULT_WEIGHTS.speed, 1.0, "default speed weight")
    H.check_eq(R.DEFAULT_WEIGHTS.takeover, 10.0, "default takeover weight")
    H.check_eq(R.DEFAULT_WEIGHTS.human, 1.0, "default human weight")

    # ── REGRESSION (Codex round-2 #9): out-of-range press must be dropped, ──
    # not smeared onto the nearest (last) frame.
    ft_clip = np.array([0.0, 0.1, 0.2])
    sc_after = R.backfill_human_scores([R.HumanEvent(t=0.3, score=1.0)], ft_clip)
    H.check(np.array_equal(sc_after, [0.0, 0.0, 0.0]),
            "press after last frame (t=.3 > .2) -> dropped, no frame scored")
    # narrow window (0.05s): only the frame exactly at .2 lies in (.15,.2]
    sc_at_last = R.backfill_human_scores([R.HumanEvent(t=0.2, score=1.0)], ft_clip, judge_window_s=0.05)
    H.check(np.array_equal(sc_at_last, [0.0, 0.0, 1.0]),
            "press at last frame (narrow window) -> only that frame scored")
    sc_far_before = R.backfill_human_scores([R.HumanEvent(t=-5.0, score=1.0)], ft_clip)
    H.check(np.array_equal(sc_far_before, [0.0, 0.0, 0.0]),
            "press far before first frame -> dropped")
