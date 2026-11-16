"""Reward shaping + GAE for V3 human-in-the-loop RL.

Pure numpy, no I/O, fully unit-testable.

Hard constraints (agreed with product owner + code review):
  * NO world-position dependency. Reward uses only signals available in the cloud:
    speed (speedometer OCR), collision / hard-decel, visual lane offset, takeover.
  * Human scores (~2 Hz) are applied BACKWARD to the frames the human was judging,
    matched by real frame timestamps (not `round(press_t*fps)` which can score a
    future frame). Events are sorted and out-of-range presses are dropped.
  * GAE is computed per episode; independent clips MUST NOT leak reward across.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Sequence

import numpy as np

SPEED_NORM_KMH = 100.0
STUCK_SPEED_KMH = 1.0


@dataclass(frozen=True)
class RewardWeights:
    speed: float = 1.0
    stuck: float = 0.5
    collision: float = 5.0
    decel: float = 2.0
    lane: float = 0.5
    takeover: float = 10.0
    human: float = 1.0


DEFAULT_WEIGHTS = RewardWeights()


def speed_term(speed_kmh: float, speed_valid: bool) -> float:
    if not speed_valid or not np.isfinite(speed_kmh) or speed_kmh <= 0.0:
        return 0.0
    return float(min(speed_kmh, SPEED_NORM_KMH) / SPEED_NORM_KMH)


def is_stuck(speed_kmh: float, speed_valid: bool) -> bool:
    return bool(speed_valid and np.isfinite(speed_kmh) and speed_kmh < STUCK_SPEED_KMH)


def decel_term(prev_speed: float, speed_kmh: float, cur_valid: bool,
               prev_valid: bool = True) -> float:
    """Hard-deceleration magnitude in [0,1].

    Requires BOTH readings valid: across an OCR gap ``prev_speed`` may be a stale
    value from before the gap, so comparing it to a fresh reading after the gap
    would fabricate a huge one-frame decel. ``prev_valid`` guards that.
    """
    if not (cur_valid and prev_valid):
        return 0.0
    if not (np.isfinite(prev_speed) and np.isfinite(speed_kmh)):
        return 0.0
    drop = prev_speed - speed_kmh
    if drop <= 0.0:
        return 0.0
    return float(min(drop / 30.0, 1.0))


def lane_term(lane_offset: float) -> float:
    if not np.isfinite(lane_offset):
        return 0.0
    return float(min(abs(lane_offset), 1.0))


def dense_reward(speed_kmh, speed_valid, prev_speed, lane_offset, collided,
                 weights: RewardWeights = DEFAULT_WEIGHTS,
                 prev_valid: bool = True) -> float:
    r = 0.0
    r += weights.speed * speed_term(speed_kmh, speed_valid)
    if is_stuck(speed_kmh, speed_valid):
        r -= weights.stuck
    if collided:
        r -= weights.collision
    r -= weights.decel * decel_term(prev_speed, speed_kmh, speed_valid, prev_valid)
    r -= weights.lane * lane_term(lane_offset)
    return float(r)


def takeover_reward(took_over: bool, weights: RewardWeights = DEFAULT_WEIGHTS) -> float:
    return float(-weights.takeover) if took_over else 0.0


def clamp_human_score(score: float) -> float:
    if not np.isfinite(score):
        return 0.0
    return float(max(-1.0, min(1.0, score)))


@dataclass
class HumanEvent:
    t: float       # press time (seconds since episode start)
    score: float


def backfill_human_scores(
    events: Sequence[HumanEvent],
    frame_times: Sequence[float],
    judge_window_s: float = 0.5,
) -> np.ndarray:
    """Apply human scores BACKWARD onto the frames the human was judging.

    A press at time ``t`` rates the frames whose timestamp lies in
    ``(t - judge_window_s, t]`` -- the recent past, never the future. Frames are
    matched by their real timestamps, so a press at 0.15s with frames at
    0,0.1,0.2,... affects only frames 0 and 0.1 (NOT 0.2). Events are sorted by
    time; presses outside the clip are dropped; overlapping windows let the LATER
    press win. Unjudged frames stay at neutral 0 (there is no forward smear, so
    "timeout -> 0" holds by construction).
    """
    ft = np.asarray(frame_times, dtype=np.float64)
    n = ft.shape[0]
    scores = np.zeros(n, dtype=np.float32)
    if n == 0:
        return scores
    # Sort events by time so later presses overwrite earlier overlapping ones.
    evs = sorted(((e.t, e.score) for e in events
                  if np.isfinite(e.t) and np.isfinite(e.score)), key=lambda x: x[0])
    for t, sc in evs:
        # frames with timestamp in (t - window, t]
        lo = t - judge_window_s
        sel = (ft > lo) & (ft <= t + 1e-9)
        if not sel.any():
            continue
        scores[sel] = clamp_human_score(sc)
    return scores


def compose_frame_reward(dense, human_score, took_over,
                         weights: RewardWeights = DEFAULT_WEIGHTS) -> float:
    return float(dense + weights.human * clamp_human_score(human_score)
                 + takeover_reward(took_over, weights))


@dataclass
class FrameSignals:
    speed_kmh: float = 0.0
    speed_valid: bool = False
    lane_offset: float = 0.0
    collided: bool = False
    took_over: bool = False


def compute_episode_rewards(
    frames: Sequence[FrameSignals],
    human_events: Sequence[HumanEvent],
    frame_times: Sequence[float],
    weights: RewardWeights = DEFAULT_WEIGHTS,
    judge_window_s: float = 0.5,
) -> np.ndarray:
    n = len(frames)
    if len(frame_times) != n:
        raise ValueError("compute_episode_rewards: frame_times 与 frames 长度不一致")
    human = backfill_human_scores(human_events, frame_times, judge_window_s)
    out = np.zeros(n, dtype=np.float32)
    prev_speed = 0.0
    prev_valid = False
    for i, f in enumerate(frames):
        d = dense_reward(f.speed_kmh, f.speed_valid, prev_speed, f.lane_offset,
                         f.collided, weights, prev_valid=prev_valid)
        out[i] = compose_frame_reward(d, float(human[i]), f.took_over, weights)
        prev_speed = f.speed_kmh if f.speed_valid else prev_speed
        prev_valid = f.speed_valid
    return out


def normalize_advantages(adv: np.ndarray, eps: float = 1e-8) -> np.ndarray:
    """Standardise advantages. Returns 0 for non-finite input (never NaN)."""
    adv = np.asarray(adv, dtype=np.float64)
    if adv.size == 0:
        return adv.astype(np.float32)
    if not np.all(np.isfinite(adv)):
        return np.zeros_like(adv, dtype=np.float32)
    mean = adv.mean()
    std = adv.std()
    if std < eps:
        return np.zeros_like(adv, dtype=np.float32)
    return ((adv - mean) / (std + eps)).astype(np.float32)


def gae_advantages(
    rewards: Sequence[float],
    values: Sequence[float],
    episode_ends: Optional[Sequence[bool]] = None,
    gamma: float = 0.99,
    lam: float = 0.95,
) -> tuple:
    """GAE computed **per episode**.

    ``episode_ends[i] == True`` means frame i is the last of its episode: the
    bootstrap from i+1 is set to 0 and the running GAE is reset. This prevents
    reward leaking across independent clips that happen to be concatenated.

    Returns (advantages, value_targets) with value_targets = advantages + values.
    """
    r = np.asarray(rewards, dtype=np.float64)
    v = np.asarray(values, dtype=np.float64)
    n = r.shape[0]
    if v.shape[0] != n:
        raise ValueError("gae_advantages: rewards/values 长度不一致")
    if episode_ends is None:
        ends = np.zeros(n, dtype=bool)
        if n:
            ends[-1] = True
    else:
        ends = np.asarray(episode_ends, dtype=bool)
    adv = np.zeros(n, dtype=np.float64)
    last = 0.0
    for t in range(n - 1, -1, -1):
        terminal = bool(ends[t]) or (t == n - 1)
        next_v = 0.0 if terminal else v[t + 1]
        delta = r[t] + gamma * next_v - v[t]
        last = delta + gamma * lam * (0.0 if terminal else last)
        adv[t] = last
    value_targets = adv + v
    return adv.astype(np.float32), value_targets.astype(np.float32)
