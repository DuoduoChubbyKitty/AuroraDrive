"""Reward shaping for V3 human-in-the-loop reinforcement learning.

Design constraints (agreed with the product owner):
  * Absolutely NO world-position dependency. The cloud pipeline cannot obtain the
    vehicle's absolute position, so the reward must be computable from signals we
    DO have: speed (speedometer OCR), collision / hard-decel, a visual lane offset
    derived from the lane mask, and the human takeover signal.
  * Two reward sources are combined:
      - dense (automatic, per frame): progress / stuck / collision / lane offset.
      - sparse (human, ~2 Hz): a subjective "was that maneuver good?" score that is
        BACKFILLED to the frames the human was judging (never to future frames),
        and decays to neutral after a timeout.
  * "Takeover" is itself the strongest instantaneous signal: when the human grabs
    the controls, the frame is penalised heavily (the model just did something
    wrong) and the human action becomes an imitation label downstream.

All functions are pure (no I/O, no global state) so they can be unit tested
exhaustively. Source kept ASCII-only for portability across the Swift/Python repo.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence

import numpy as np

# Neutral speed used to normalise the progress term (km/h). Speeds above this are
# clamped to 1.0 so the reward does not encourage unbounded speeding.
_SPEED_NORM_KMH = 100.0
# A speed below this (km/h) with a valid reading counts as "not moving".
_STUCK_SPEED_KMH = 1.0


@dataclass(frozen=True)
class RewardWeights:
    """Weights for the dense reward. Kept as a dataclass so tests and CLIs can
    override individual terms without positional-argument mistakes."""

    speed: float = 1.0
    stuck: float = 0.5
    collision: float = 5.0
    decel: float = 2.0
    lane: float = 0.5
    takeover: float = 10.0
    human: float = 1.0


DEFAULT_WEIGHTS = RewardWeights()


def speed_term(speed_kmh: float, speed_valid: bool) -> float:
    """Normalised forward-progress reward in [0, 1]; 0 when speed is unknown.

    We deliberately return 0 (not a penalty) when ``speed_valid`` is False: an
    unreadable speedometer must not be turned into a "you are stopped" signal,
    otherwise OCR dropouts would teach the model to accelerate blindly.
    """
    if not speed_valid:
        return 0.0
    # Clamp negative / NaN / inf to 0 so a corrupted reading never yields reward.
    if not np.isfinite(speed_kmh) or speed_kmh <= 0.0:
        return 0.0
    return float(min(speed_kmh, _SPEED_NORM_KMH) / _SPEED_NORM_KMH)


def is_stuck(speed_kmh: float, speed_valid: bool) -> bool:
    """True when the car is (credibly) not moving this frame."""
    return bool(speed_valid and np.isfinite(speed_kmh) and speed_kmh < _STUCK_SPEED_KMH)


def decel_term(prev_speed: float, speed_kmh: float, speed_valid: bool) -> float:
    """Magnitude of a hard deceleration between consecutive frames, in [0, 1].

    Only meaningful when both readings are valid. A drop of >= 30 km/h in one
    frame saturates at 1.0 (a violent jolt / crash-like event).
    """
    if not speed_valid or not (np.isfinite(prev_speed) and np.isfinite(speed_kmh)):
        return 0.0
    drop = prev_speed - speed_kmh
    if drop <= 0.0:
        return 0.0
    return float(min(drop / 30.0, 1.0))


def lane_term(lane_offset: float) -> float:
    """Normalised lateral deviation penalty in [0, 1]; 0 = centred, 1 = at edge.

    ``lane_offset`` is the signed lateral position within the lane (negative=left,
    positive=right) normalised so +-1.0 is the lane boundary. Derived from the
    visual lane mask, NOT from world position.
    """
    if not np.isfinite(lane_offset):
        return 0.0
    return float(min(abs(lane_offset), 1.0))


def dense_reward(
    speed_kmh: float,
    speed_valid: bool,
    prev_speed: float,
    lane_offset: float,
    collided: bool,
    weights: RewardWeights = DEFAULT_WEIGHTS,
) -> float:
    """Per-frame automatic reward from the signals available in the cloud.

    reward =  + w.speed * progress
              - w.stuck * [not moving]
              - w.collision * [collision]
              - w.decel * hard_deceleration
              - w.lane * |lane_offset|
    """
    r = 0.0
    r += weights.speed * speed_term(speed_kmh, speed_valid)
    if is_stuck(speed_kmh, speed_valid):
        r -= weights.stuck
    if collided:
        r -= weights.collision
    r -= weights.decel * decel_term(prev_speed, speed_kmh, speed_valid)
    r -= weights.lane * lane_term(lane_offset)
    return float(r)


def takeover_reward(took_over: bool, weights: RewardWeights = DEFAULT_WEIGHTS) -> float:
    """Strong negative reward when the human had to grab the wheel this frame."""
    return float(-weights.takeover) if took_over else 0.0


def clamp_human_score(score: float) -> float:
    """Clamp a raw human score into [-1, 1]; NaN -> 0 (neutral)."""
    if not np.isfinite(score):
        return 0.0
    return float(max(-1.0, min(1.0, score)))


@dataclass
class HumanEvent:
    """A single human score press.

    The human pressed a button at time ``press_t`` (seconds since episode start)
    to rate a maneuver that JUST happened. The score therefore applies to the
    frames BEFORE the press (``judge_window`` seconds worth), never after.
    """

    press_t: float
    score: float


def backfill_human_scores(
    events: Sequence[HumanEvent],
    num_frames: int,
    fps: float,
    judge_window_s: float = 0.5,
    timeout_s: float = 0.5,
) -> np.ndarray:
    """Spread 2 Hz human presses back onto the frames they were judging.

    Semantics (this is the key correction to a naive hold-forward scheme):
      * A press at ``press_t`` rates the ~``judge_window_s`` seconds that ended at
        ``press_t`` -> those frames get the score (backward fill).
      * These are sparse: only frames inside a judged window receive a score.
      * Any stretch of frames with no fresh judgement decays to NEUTRAL 0 after
        ``timeout_s`` -- we must never let one stale score smear across unrelated
        driving.

    Returns an array shape (num_frames,) in [-1, 1]. Later events overwrite
    earlier ones where their windows overlap (most recent judgement wins).
    """
    if fps <= 0.0 or num_frames <= 0:
        return np.zeros(max(num_frames, 0), dtype=np.float32)
    scores = np.zeros(num_frames, dtype=np.float32)
    judged = np.zeros(num_frames, dtype=bool)
    window_frames = max(1, int(round(judge_window_s * fps)))
    timeout_frames = max(window_frames, int(round(timeout_s * fps)))

    for ev in events:
        if not (np.isfinite(ev.press_t) and np.isfinite(ev.score)):
            continue
        end = int(round(ev.press_t * fps))          # frame index of the press
        end = min(max(end, 0), num_frames - 1)
        start = max(0, end - window_frames + 1)
        val = clamp_human_score(ev.score)
        scores[start : end + 1] = val
        judged[start : end + 1] = True

    # Decay unjudged stretches beyond timeout: zero them (explicit, not implied).
    # Walk gaps; any unjudged run longer than timeout_frames stays neutral anyway
    # (already 0), so this is a no-op safety guarantee -- kept explicit so the
    # "timeout" contract is visible and testable.
    i = 0
    while i < num_frames:
        if not judged[i]:
            j = i
            while j < num_frames and not judged[j]:
                j += 1
            if (j - i) > timeout_frames:
                scores[i:j] = 0.0
            i = j
        else:
            i += 1
    return scores


def compose_frame_reward(
    dense: float,
    human_score: float,
    took_over: bool,
    weights: RewardWeights = DEFAULT_WEIGHTS,
) -> float:
    """Combine the dense automatic reward, the backfilled human score, and the
    takeover penalty into the final per-frame scalar."""
    return float(
        dense
        + weights.human * clamp_human_score(human_score)
        + takeover_reward(took_over, weights)
    )


@dataclass
class FrameSignals:
    """Everything needed to score one frame. Mirrors one row of codrive.csv plus
    the offline lane-offset / collision annotations."""

    speed_kmh: float = 0.0
    speed_valid: bool = False
    lane_offset: float = 0.0
    collided: bool = False
    took_over: bool = False


def compute_episode_rewards(
    frames: Sequence[FrameSignals],
    human_events: Sequence[HumanEvent],
    fps: float,
    weights: RewardWeights = DEFAULT_WEIGHTS,
    judge_window_s: float = 0.5,
    timeout_s: float = 0.5,
) -> np.ndarray:
    """Whole-episode reward vector."""
    n = len(frames)
    human = backfill_human_scores(
        human_events, n, fps, judge_window_s=judge_window_s, timeout_s=timeout_s
    )
    rewards = np.zeros(n, dtype=np.float32)
    prev_speed = 0.0
    for i, f in enumerate(frames):
        d = dense_reward(
            f.speed_kmh, f.speed_valid, prev_speed, f.lane_offset, f.collided, weights
        )
        rewards[i] = compose_frame_reward(d, float(human[i]), f.took_over, weights)
        if f.speed_valid and np.isfinite(f.speed_kmh):
            prev_speed = f.speed_kmh
    return rewards


def discounted_returns(rewards: Sequence[float], gamma: float = 0.99) -> np.ndarray:
    """Standard discounted return G_t = r_t + gamma * G_{t+1}."""
    out = np.zeros(len(rewards), dtype=np.float32)
    running = 0.0
    for t in range(len(rewards) - 1, -1, -1):
        running = float(rewards[t]) + gamma * running
        out[t] = running
    return out


def gae_advantages(
    rewards: Sequence[float],
    values: Sequence[float],
    gamma: float = 0.99,
    lam: float = 0.95,
) -> (np.ndarray, np.ndarray):
    """Generalised Advantage Estimation.

    Returns (advantages, value_targets) where value_targets = advantages + values
    (used as the regression target for the critic).
    """
    n = len(rewards)
    adv = np.zeros(n, dtype=np.float32)
    last = 0.0
    for t in range(n - 1, -1, -1):
        next_v = values[t + 1] if t + 1 < n else 0.0
        delta = float(rewards[t]) + gamma * float(next_v) - float(values[t])
        last = delta + gamma * lam * last
        adv[t] = last
    value_targets = adv + np.asarray(values, dtype=np.float32)
    return adv, value_targets
