"""Exhaustive tests for reward.py pure functions."""

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reward as R  # noqa: E402
from tests import _harness as H  # noqa: E402


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

    # ── decel_term ──────────────────────────────────────────────────────
    H.check_close(R.decel_term(80.0, 80.0, True), 0.0, msg="no change -> 0")
    H.check_close(R.decel_term(80.0, 90.0, True), 0.0, msg="accel -> 0")
    H.check_close(R.decel_term(80.0, 65.0, True), 0.5, msg="15 km/h drop -> 0.5")
    H.check_close(R.decel_term(80.0, 40.0, True), 1.0, msg="40 km/h drop -> saturate")
    H.check_close(R.decel_term(80.0, 40.0, False), 0.0, msg="invalid -> 0")
    H.check_close(R.decel_term(float("nan"), 40.0, True), 0.0, msg="NaN prev -> 0")
    H.check_close(R.decel_term(80.0, float("inf"), True), 0.0, msg="inf cur -> 0")

    # ── lane_term ───────────────────────────────────────────────────────
    H.check_close(R.lane_term(0.0), 0.0, msg="centred -> 0")
    H.check_close(R.lane_term(0.5), 0.5, msg="half offset -> 0.5")
    H.check_close(R.lane_term(-0.5), 0.5, msg="symmetric (abs)")
    H.check_close(R.lane_term(1.5), 1.0, msg="clamped to 1")
    H.check_close(R.lane_term(float("nan")), 0.0, msg="NaN -> 0")

    # ── dense_reward composition ────────────────────────────────────────
    w = R.DEFAULT_WEIGHTS
    # perfect frame: moving at 100, centred, no collision
    r_perfect = R.dense_reward(100.0, True, 100.0, 0.0, False)
    H.check_close(r_perfect, w.speed, msg="perfect frame = +speed weight")
    # stopped frame
    r_stuck = R.dense_reward(0.0, True, 0.0, 0.0, False)
    H.check_close(r_stuck, -w.stuck, msg="stuck frame = -stuck weight")
    # collision moving
    r_coll = R.dense_reward(100.0, True, 100.0, 0.0, True)
    H.check_close(r_coll, w.speed - w.collision, msg="collision subtracts")
    # offset
    r_off = R.dense_reward(100.0, True, 100.0, 0.8, False)
    H.check_close(r_off, w.speed - w.lane * 0.8, msg="lane offset subtracts")
    # invalid speed: no progress, not stuck
    r_inv = R.dense_reward(0.0, False, 0.0, 0.0, False)
    H.check_close(r_inv, 0.0, msg="invalid speed -> 0 dense")
    # custom weights respected
    w2 = R.RewardWeights(speed=2.0, stuck=3.0, lane=1.0)
    H.check_close(R.dense_reward(100.0, True, 50.0, 0.5, False, w2),
                  2.0 - 1.0 * 0.5 - 1.0 * (50 - 100 > 0 and 0 or 0),  # no decel (accel)
                  msg="custom weights")
    # decel path
    r_dec = R.dense_reward(40.0, True, 80.0, 0.0, False)
    H.check_close(r_dec, w.speed * 0.4 - w.decel * (40.0 / 30.0 if (40.0/30.0) < 1 else 1.0),
                  msg="decel included")

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

    # ── backfill_human_scores ───────────────────────────────────────────
    # fps=10, judge_window=0.5s -> 5 frames. Press at t=1.0 (frame 10).
    ev = [R.HumanEvent(press_t=1.0, score=1.0)]
    sc = R.backfill_human_scores(ev, num_frames=20, fps=10.0,
                                 judge_window_s=0.5, timeout_s=0.5)
    H.check_eq(len(sc), 20, "backfill length")
    # frames 6..10 should carry +1 (backward). frame 10 = press frame.
    H.check_close(float(sc[6]), 1.0, msg="frame 6 judged")
    H.check_close(float(sc[10]), 1.0, msg="press frame judged")
    H.check_close(float(sc[5]), 0.0, msg="frame 5 before window -> 0")
    H.check_close(float(sc[11]), 0.0, msg="frame 11 AFTER press -> 0 (no forward smear)")
    H.check_close(float(sc[0]), 0.0, msg="frame 0 -> 0")
    H.check_close(float(sc[19]), 0.0, msg="last frame -> 0")

    # negative score
    sc_neg = R.backfill_human_scores([R.HumanEvent(1.0, -1.0)], 20, 10.0)
    H.check_close(float(sc_neg[8]), -1.0, msg="negative backfilled")

    # two events overlap: later wins
    ev2 = [R.HumanEvent(0.5, 1.0), R.HumanEvent(0.9, -1.0)]
    sc2 = R.backfill_human_scores(ev2, 20, 10.0)
    # event at frame 9 window 5..9 = -1 overwrites frame 5..9
    H.check_close(float(sc2[9]), -1.0, msg="later event wins")
    H.check_close(float(sc2[5]), -1.0, msg="overlap region = later value")

    # empty events -> all zeros
    sc_empty = R.backfill_human_scores([], 15, 10.0)
    H.check(np.allclose(sc_empty, 0.0), "empty events -> all zero")
    H.check_eq(len(sc_empty), 15, "empty events length")

    # edge: fps <= 0 -> zeros, correct length
    sc_bad = R.backfill_human_scores([R.HumanEvent(1.0, 1.0)], 5, 0.0)
    H.check_eq(len(sc_bad), 5, "fps=0 length preserved")
    H.check(np.allclose(sc_bad, 0.0), "fps=0 -> zeros")

    # edge: press beyond range clamped
    sc_far = R.backfill_human_scores([R.HumanEvent(100.0, 1.0)], 10, 10.0)
    H.check_close(float(sc_far[9]), 1.0, msg="press clamped to last frame")

    # negative press time clamped to 0
    sc_neg_t = R.backfill_human_scores([R.HumanEvent(-5.0, 1.0)], 10, 10.0)
    H.check_close(float(sc_neg_t[0]), 1.0, msg="negative press clamped to frame 0")

    # invalid score (NaN) event skipped
    sc_nan = R.backfill_human_scores([R.HumanEvent(1.0, float("nan"))], 10, 10.0)
    H.check(np.allclose(sc_nan, 0.0), "NaN score event skipped")

    # ── compose_frame_reward ────────────────────────────────────────────
    H.check_close(R.compose_frame_reward(1.0, 0.5, False), 1.5,
                  msg="dense + human")
    H.check_close(R.compose_frame_reward(1.0, 0.0, True), 1.0 - w.takeover,
                  msg="takeover folded in")
    H.check_close(R.compose_frame_reward(0.0, 2.0, False), 1.0,
                  msg="human score clamped before use")

    # ── compute_episode_rewards ─────────────────────────────────────────
    frames = [
        R.FrameSignals(50.0, True, 0.0, False, False),
        R.FrameSignals(50.0, True, 0.0, False, False),
        R.FrameSignals(0.0, True, 0.0, False, True),  # stuck + takeover
    ]
    evs = [R.HumanEvent(press_t=0.0, score=1.0)]
    rew = R.compute_episode_rewards(frames, evs, fps=10.0)
    H.check_eq(len(rew), 3, "episode reward length")
    # frame0: speed 0.5 + human 1.0 = 1.5
    H.check_close(float(rew[0]), 0.5 + 1.0, msg="episode frame0")
    # frame2: from 50->0 = hard decel(saturate -2) + stuck(-0.5) + takeover(-10)
    H.check_close(float(rew[2]), -0.5 - w.decel * 1.0 - w.takeover,
                  msg="episode frame2 takeover+stuck+decel")

    # empty episode
    rew_empty = R.compute_episode_rewards([], [], fps=10.0)
    H.check_eq(len(rew_empty), 0, "empty episode -> empty array")

    # prev_speed tracking: decel from 80 to 40 penalised
    frames2 = [R.FrameSignals(80.0, True, 0.0, False, False),
               R.FrameSignals(40.0, True, 0.0, False, False)]
    rew2 = R.compute_episode_rewards(frames2, [], fps=10.0)
    H.check_close(float(rew2[0]), 0.8, msg="frame0 no decel")
    H.check_close(float(rew2[1]), 0.4 - w.decel * 1.0, msg="frame1 hard decel")

    # ── discounted_returns ──────────────────────────────────────────────
    g = R.discounted_returns([1.0, 1.0, 1.0], gamma=0.5)
    # G2=1, G1=1+0.5=1.5, G0=1+0.5*1.5=1.75
    H.check_close(float(g[2]), 1.0, msg="return t2")
    H.check_close(float(g[1]), 1.5, msg="return t1")
    H.check_close(float(g[0]), 1.75, msg="return t0")
    H.check_eq(len(R.discounted_returns([], 0.99)), 0, "empty returns")

    # ── gae_advantages ──────────────────────────────────────────────────
    # constant reward=1, values=0, gamma=0.9, lam=0.8
    adv, vt = R.gae_advantages([1.0, 1.0, 1.0], [0.0, 0.0, 0.0], gamma=0.9, lam=0.8)
    H.check_eq(len(adv), 3, "gae length")
    # t2: delta=1, adv=1
    H.check_close(float(adv[2]), 1.0, msg="gae t2")
    # t1: delta=1, adv=1+0.72*1=1.72
    H.check_close(float(adv[1]), 1.0 + 0.9 * 0.8 * 1.0, msg="gae t1")
    # value_targets = adv + values(0) = adv
    H.check_close(float(vt[2]), 1.0, msg="vt t2")
    H.check_close(float(vt[0]), float(adv[0]), msg="vt=adv when values 0")

    # gae with nonzero values
    adv2, vt2 = R.gae_advantages([0.0, 0.0], [0.5, 0.2], gamma=0.9, lam=0.9)
    # t1: delta=0+0-0.2=-0.2, adv=-0.2
    H.check_close(float(adv2[1]), -0.2, msg="gae t1 with value")
    H.check_close(float(vt2[1]), -0.2 + 0.2, tol=1e-6, msg="vt t1 = adv+value")
    # empty
    a, v = R.gae_advantages([], [], 0.99, 0.95)
    H.check_eq(len(a), 0, "empty gae adv")
    H.check_eq(len(v), 0, "empty gae vt")

    # weights dataclass immutability / defaults sanity
    H.check_eq(R.DEFAULT_WEIGHTS.speed, 1.0, "default speed weight")
    H.check_eq(R.DEFAULT_WEIGHTS.takeover, 10.0, "default takeover weight")
