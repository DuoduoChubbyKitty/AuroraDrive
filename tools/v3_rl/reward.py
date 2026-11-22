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
# 速度三段奖励的分界（km/h）。必须与 Swift RewardConfig.speedLowKmh / speedHighKmh 一致。
SPEED_LOW_KMH = 100.0     # 下分界：v<速度这里为负、100≤v≤上分界为线性正
SPEED_HIGH_KMH = 160.0    # 上分界：v>这里为轻微扣分（-1/10 量级）
# 倒车判定（与 Swift RewardConfig.reverseSpeedLow/HighKmh、reverseConfirmFrames 一致）。
REVERSE_SPEED_LOW_KMH = 30.0
REVERSE_SPEED_HIGH_KMH = 40.0
REVERSE_CONFIRM_FRAMES = 3
# 碰撞判定（与 Swift RewardConfig.collisionMinPrevSpeedKmh / collisionSpeedDropKmh 一致）。
COLLISION_MIN_PREV_SPEED_KMH = 100.0
COLLISION_SPEED_DROP_KMH = 30.0


@dataclass(frozen=True)
class RewardWeights:
    # 2026-11-20 按极限竞速语义重做：删 lane（竞速走线本就该偏离车道）与 decel
    # （过弯掉速由「v<100 负分」直接覆盖）；新增 reverse（按 S 且速度 30~40 连续帧）。
    speed: float = 1.0
    stuck: float = 0.5
    collision: float = 5.0
    reverse: float = 1.5
    takeover: float = 10.0
    human: float = 1.0


DEFAULT_WEIGHTS = RewardWeights()


def speed_term(speed_kmh: float, speed_valid: bool) -> float:
    """速度三段奖励（归一化到 [-1, +1]）。与 Swift OnlineTrainer.speedTerm 同口径。

    * ``v < SPEED_LOW_KMH``（100）：负分，按差距扣 —— ``-(100 - v)/100``，v 越接近 100
      越接近 0（v=99≈-0.01），v=0 最负（-1.0）；
    * ``SPEED_LOW_KMH ≤ v ≤ SPEED_HIGH_KMH``（100..160）：线性递增正分 —— ``(v - 100)/60``，
      v=100 为 0，v=160 最大（+1.0）；
    * ``v > SPEED_HIGH_KMH``（160）：负分，按超出扣 —— ``-(v - 160)/600``（扣分仅为正向增益的 1/10 量级），v=161 略负，越高越负。

    注意 ``v == 160`` 属中间段（+1.0）；越过 160 立刻转负（按超出扣、无下界），这是「甜点区
    上限」的设计跳变，并不连续。``speed_valid=False`` 或速度非有限/为负 → 返回 0（不伪造奖励）。
    """
    if not speed_valid or not np.isfinite(speed_kmh) or speed_kmh < 0.0:
        return 0.0
    if speed_kmh < SPEED_LOW_KMH:
        # v<100：按差距扣。v=100 时此式恰为 0（与中间段起点连续）。
        return float(-(SPEED_LOW_KMH - speed_kmh) / SPEED_LOW_KMH)
    if speed_kmh <= SPEED_HIGH_KMH:
        # 100≤v≤160：线性递增正分，(v-100)/(160-100)。
        return float((speed_kmh - SPEED_LOW_KMH) / (SPEED_HIGH_KMH - SPEED_LOW_KMH))
    # v>160：**轻微**扣分，(v-160)/600。分母 600=60×10，扣得只有正向增益的 1/10 量级
    # （161≈-0.0017，200≈-0.067）。v=160 属上一段（+1.0）。
    return float(-(speed_kmh - SPEED_HIGH_KMH) / ((SPEED_HIGH_KMH - SPEED_LOW_KMH) * 10.0))


def is_stuck(speed_kmh: float, speed_valid: bool) -> bool:
    return bool(speed_valid and np.isfinite(speed_kmh) and speed_kmh < STUCK_SPEED_KMH)


def decel_term(prev_speed: float, speed_kmh: float, cur_valid: bool,
               prev_valid: bool = True) -> float:
    """Deprecated: 2026-11-20 起奖励不再含急减速项（过弯掉速由 v<100 负分覆盖）。

    保留函数体仅为兼容旧调用方；新代码不要使用。
    """
    return 0.0


def is_reverse_frame(v_class: int, speed_kmh: float, speed_valid: bool) -> bool:
    """倒车判据（单帧）：模型选了 S 键（vClass==2）且速度读数落在 [30,40]。

    依据：OCR 读不出倒挡（只显示正数）；正常前进时按 S 会瞬间刹停，不会
    稳定停在 30~40 —— 稳定在 30~40 且按 S 即倒车。连续确认（防抖）由
    Swift OnlineTrainingRuntime.reverseStreakFrames 维护，与 Swift
    OnlineTrainer.isReverseFrame 同口径。
    """
    if v_class != 2 or not speed_valid or not np.isfinite(speed_kmh):
        return False
    return REVERSE_SPEED_LOW_KMH <= speed_kmh <= REVERSE_SPEED_HIGH_KMH


def dense_reward(speed_kmh, speed_valid, prev_speed, lane_offset, collided,
                 weights: RewardWeights = DEFAULT_WEIGHTS,
                 prev_valid: bool = True,
                 v_class: int = 1,
                 reverse_confirmed: bool = False) -> float:
    """一帧密集奖励 = 速度段 − 卡死 − 碰撞 − 倒车。

    2026-11-20 重做：删 lane/decel（竞速走线本就该偏离车道；过弯掉速由
    v<100 负分直接覆盖）。`prev_speed`/`prev_valid`/`lane_offset` 参数保留
    仅为兼容旧调用方签名，不再参与计算。
    倒车惩罚由调用方防抖（连续 N 帧 is_reverse_frame）后经
    ``reverse_confirmed`` 传入，避免单帧噪声。
    """
    r = 0.0
    r += weights.speed * speed_term(speed_kmh, speed_valid)
    if is_stuck(speed_kmh, speed_valid):
        r -= weights.stuck
    if collided:
        r -= weights.collision
    if reverse_confirmed:
        r -= weights.reverse
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
    # Clip bounds: a press strictly after the last frame or far before the first
    # is out of range and must be dropped, not smeared onto the nearest frame.
    # (Without this, a press at t=.3 for frames [0,.1,.2] would still rate all
    # three frames, contradicting "out-of-range presses are dropped".)
    first_t = float(ft[0])
    last_t = float(ft[-1])
    # Sort events by time so later presses overwrite earlier overlapping ones.
    evs = sorted(((e.t, e.score) for e in events
                  if np.isfinite(e.t) and np.isfinite(e.score)), key=lambda x: x[0])
    for t, sc in evs:
        if t > last_t + 1e-9 or t < first_t - judge_window_s - 1e-9:
            continue  # out of this clip's time range
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
    lane_offset: float = 0.0   # 已废弃：奖励不再使用（保留字段兼容旧数据管线）
    collided: bool = False
    took_over: bool = False
    v_class: int = 1           # 模型本帧动作竖直类（0=油门 1=滑行 2=刹车/S）；用于倒车判定


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
    reverse_streak = 0  # 倒车防抖计数（与 Swift 运行时 reverseStreakFrames 同口径）
    for i, f in enumerate(frames):
        if is_reverse_frame(f.v_class, f.speed_kmh, f.speed_valid):
            reverse_streak += 1
        else:
            reverse_streak = 0
        reverse_confirmed = reverse_streak >= REVERSE_CONFIRM_FRAMES
        d = dense_reward(f.speed_kmh, f.speed_valid, prev_speed, f.lane_offset,
                         f.collided, weights, prev_valid=prev_valid,
                         v_class=f.v_class, reverse_confirmed=reverse_confirmed)
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
    if adv.size == 1:
        return adv.astype(np.float32)
    mean = adv.mean()
    std = adv.std()
    if std < eps:
        return np.zeros_like(adv, dtype=np.float32)
    return ((adv - mean) / (std + eps)).astype(np.float32)


def compute_episode_ends(is_valid: Sequence[bool], clip_ends: Optional[Sequence[bool]] = None
                         ) -> np.ndarray:
    """Build GAE episode-end flags that also cut at invalid (UNKNOWN) boundaries.

    A frame is an episode end when ANY of:
      * it is the last frame of its clip (``clip_ends``), or
      * it is itself invalid (an UNKNOWN frame has no reliable action/value and must
        reset the backward recursion), or
      * it is a valid frame immediately followed by an invalid frame -- because GAE
        runs backward, leaving the last valid frame open would let the following
        unknown segment's reward leak into its ``gamma*lam*last`` term.

    This is the SINGLE production definition (train_rl imports it), so tests bind to
    the real logic rather than re-implementing it.
    """
    valid = np.asarray(is_valid, dtype=bool)
    n = valid.shape[0]
    if clip_ends is None:
        ends = np.zeros(n, dtype=bool)
        if n:
            ends[-1] = True
    else:
        ends = np.asarray(clip_ends, dtype=bool).copy()
    if n == 0:
        return ends
    cut = np.zeros(n, dtype=bool)
    if n > 1:
        cut[:-1] = valid[:-1] & ~valid[1:]
    return ends | (~valid) | cut


def gae_advantages(
    rewards: Sequence[float],
    values: Sequence[float],
    episode_ends: Optional[Sequence[bool]] = None,
    gamma: float = 0.99,
    lam: float = 0.95,
    tail_bootstrap_value: Optional[float] = None,
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
        if n and tail_bootstrap_value is None:
            ends[-1] = True
    else:
        ends = np.asarray(episode_ends, dtype=bool)
    adv = np.zeros(n, dtype=np.float64)
    last = 0.0
    for t in range(n - 1, -1, -1):
        terminal = bool(ends[t])
        if terminal:
            next_v = 0.0
        elif t + 1 < n:
            next_v = v[t + 1]
        else:
            next_v = 0.0 if tail_bootstrap_value is None else tail_bootstrap_value
        delta = r[t] + gamma * next_v - v[t]
        last = delta + gamma * lam * (0.0 if terminal else last)
        adv[t] = last
    value_targets = adv + v
    return adv.astype(np.float32), value_targets.astype(np.float32)
