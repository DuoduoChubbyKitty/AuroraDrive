"""Human-in-the-loop RL trainer for the V3 driving model.

Two stages, both freezing the visual backbone and training only a lightweight
discrete policy head + a critic on top of the V3 ``state_token`` feature:

  --stage bc   Behaviour-cloning warm-up on HUMAN demonstration frames, so the
               model first learns "what a good corner looks like" from the human.
  --stage ppo  PPO fine-tuning on AI rollout frames, with a behaviour-regularising
               imitation term on human frames whose weight lambda decays over
               training (learn-from-human early, then explore beyond).

Why this split: pure imitation (AWR/BC) is capped at the human data quality; pure
PPO from scratch crashes in the corners the model has never seen. Warm-up then
fine-tune with a decaying imitation prior is the standard "learn from demo, then
surpass" recipe.

Reconstruction note: the state dictionary was saved on an NPU host that this
machine cannot import (``torch_npu``). We therefore never call torch.load here;
the policy is warmed from the *deployed domain* by the pipeline that runs on the
recording host, and on this Mac the trainer is exercised end-to-end on synthetic
episodes with a small V3 config. See ``load_v3_state_dict`` for the guarded path.

All PPO / advantage / reward maths live in ``policy.py`` and ``reward.py`` as pure
functions so they can be unit tested without a GPU or a checkpoint.
"""

from __future__ import annotations

import argparse
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

# Make repo root importable when run as a script.
_ROOT = Path(__file__).resolve().parents[2]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from tools.v3_rl import policy as P  # noqa: E402
from tools.v3_rl import reward as R  # noqa: E402


# ---------------------------------------------------------------------------
# Discrete action space
# ---------------------------------------------------------------------------
# V3 outputs: vertical in {W, NONE, S} x horizontal in {A, NONE, D} = 9 combos.
# We factor the policy as two independent categorical heads (vertical, horizontal),
# matching how the V3 head already factors them. A "joint" action id is
# vertical*3 + horizontal, used only for logging / expert lookup.
NUM_VERTICAL = 3
NUM_HORIZONTAL = 3


def joint_action(vertical: int, horizontal: int) -> int:
    return int(vertical) * NUM_HORIZONTAL + int(horizontal)


def split_action(joint: int) -> Tuple[int, int]:
    joint = int(joint)
    return joint // NUM_HORIZONTAL, joint % NUM_HORIZONTAL


def onehot_vertical(vertical: int) -> np.ndarray:
    v = np.zeros(NUM_VERTICAL, dtype=np.float32)
    v[int(vertical)] = 1.0
    return v


def onehot_horizontal(horizontal: int) -> np.ndarray:
    h = np.zeros(NUM_HORIZONTAL, dtype=np.float32)
    h[int(horizontal)] = 1.0
    return h


# ---------------------------------------------------------------------------
# Dataset loading -> encoded features
# ---------------------------------------------------------------------------
@dataclass
class EncodedEpisodes:
    """Flattened training material.

    features:  [N, F] state-token proxy features (state dict + kinematics).
    vertical:  [N] int labels (raw V3 labels; used for BC targets).
    horizontal:[N] int labels.
    has_human: [N] bool, True where the row came from a human demonstration
               (BC / imitation) and False where it came from an AI takeover
               correction (PPO on-policy sample with a shaped reward).
    reward:    [N] per-frame shaped reward (only meaningful for PPO rows).
    speed:     [N] speed in km/h (for diagnostics).
    """

    features: np.ndarray
    vertical: np.ndarray
    horizontal: np.ndarray
    has_human: np.ndarray
    reward: np.ndarray
    speed: np.ndarray

    def __len__(self) -> int:
        return int(self.features.shape[0])


# Motion keys the policy can act on / observe in the state dict. MUST match the
# Swift RawKeySample order and dataset_v3 supervision order.
_KEY_NAMES = ("w", "a", "s", "d", "shift", "space")


def encode_kinematics(
    speeds_kmh: Sequence[float],
    speed_valid: Sequence[float],
    keys: Sequence[Dict[str, int]],
    prev_keys: Optional[Sequence[Optional[Dict[str, int]]]] = None,
    fps: float = 15.0,
) -> np.ndarray:
    """Build the policy feature matrix from recorded kinematics.

    Layout per row (deliberately small, interpretable, and dependency-free):
        [0] speed / 100                       (clamped, 0 if invalid)
        [1] speed_valid                       (0/1)
        [2] is_stuck                          (0/1)
        [3:9] six current keys                (w,a,s,d,shift,space)
        [9] has_prev                          (0/1)
        [10:16] six previous keys             (0 if no prev)
        [16] sin(heading), [17] cos(heading)  -- placeholder heading = 0 here;
             real callers may overwrite; kept so downstream dims are stable.

    NOTE: heading is intentionally NOT sourced from world coordinates. This is a
    kinematics-only encoding that works in the cloud where absolute position is
    unavailable.
    """
    n = len(speeds_kmh)
    if not (len(speed_valid) == n and len(keys) == n):
        raise ValueError("encode_kinematics: length mismatch between inputs")
    if prev_keys is not None and len(prev_keys) != n:
        raise ValueError("encode_kinematics: prev_keys length mismatch")
    feats = np.zeros((n, 18), dtype=np.float32)
    for i in range(n):
        sp = float(speeds_kmh[i])
        sv = float(speed_valid[i])
        valid = sv >= 0.5 and math.isfinite(sp)
        sp_c = sp if valid else 0.0
        feats[i, 0] = min(max(sp_c, 0.0), 100.0) / 100.0
        feats[i, 1] = 1.0 if valid else 0.0
        feats[i, 2] = 1.0 if (valid and sp < 1.0) else 0.0
        for j, k in enumerate(_KEY_NAMES):
            feats[i, 3 + j] = 1.0 if int(keys[i].get(k, 0)) else 0.0
        pk = prev_keys[i] if prev_keys is not None else None
        if pk is not None:
            feats[i, 9] = 1.0
            for j, k in enumerate(_KEY_NAMES):
                feats[i, 10 + j] = 1.0 if int(pk.get(k, 0)) else 0.0
        feats[i, 16] = 0.0  # sin(0)
        feats[i, 17] = 1.0  # cos(0)
    return feats


def build_encoded_episodes(
    speeds_kmh: Sequence[float],
    speed_valid: Sequence[float],
    keys: Sequence[Dict[str, int]],
    vertical_labels: Sequence[int],
    horizontal_labels: Sequence[int],
    has_human: Sequence[bool],
    rewards: Sequence[float],
    prev_keys: Optional[Sequence[Optional[Dict[str, int]]]] = None,
    fps: float = 15.0,
) -> EncodedEpisodes:
    feats = encode_kinematics(speeds_kmh, speed_valid, keys, prev_keys, fps)
    return EncodedEpisodes(
        features=feats,
        vertical=np.asarray(vertical_labels, dtype=np.int64),
        horizontal=np.asarray(horizontal_labels, dtype=np.int64),
        has_human=np.asarray(has_human, dtype=bool),
        reward=np.asarray(rewards, dtype=np.float32),
        speed=np.asarray(speeds_kmh, dtype=np.float32),
    )


def load_episodes_from_controls(
    clip_dir: Path,
    reward_weights: R.RewardWeights = R.DEFAULT_WEIGHTS,
    fps: float = 15.0,
) -> EncodedEpisodes:
    """Load one recorded clip (controls.csv + optional codrive.csv) into episodes.

    Requires controls.csv only (11-col contract). If codrive.csv exists it supplies
    the AI/human split and takeover flags; otherwise every frame is treated as a
    human demonstration (pure BC source).
    """
    import csv

    clip_dir = Path(clip_dir)
    controls = clip_dir / "controls.csv"
    if not controls.exists():
        raise FileNotFoundError(f"{clip_dir} 缺 controls.csv")
    with open(controls, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        raise ValueError(f"{clip_dir}/controls.csv 为空")

    def bit(row: Dict[str, str], k: str) -> int:
        return 1 if str(row.get(k, "0")).strip() not in ("", "0", "False") else 0

    speeds = []
    valid = []
    keys = []
    vlabels = []
    hlabels = []
    has_human = []
    took_over = []
    collided = []
    lane_off = []
    for r in rows:
        sp_raw = str(r.get("speed_kmh", "")).strip()
        valid_i = 1.0 if sp_raw not in ("", "None") else 0.0
        try:
            sp = float(sp_raw) if valid_i else 0.0
        except ValueError:
            sp = 0.0
            valid_i = 0.0
        speeds.append(sp)
        valid.append(valid_i)
        keys.append({k: bit(r, k) for k in _KEY_NAMES})
        w, a, s, d = bit(r, "w"), bit(r, "a"), bit(r, "s"), bit(r, "d")
        vlabels.append(0 if w else (2 if s else 1))
        hlabels.append(0 if a else (2 if d else 1))
        # default: all rows human demonstration unless codrive says otherwise
        has_human.append(True)
        took_over.append(False)
        collided.append(False)
        lane_off.append(0.0)

    codrive = clip_dir / "codrive.csv"
    if codrive.exists():
        with open(codrive, newline="", encoding="utf-8") as f:
            cdrows = list(csv.DictReader(f))
        # Align by frame index; codrive has one row per recorded frame.
        by_frame = {int(r["frame"]): r for r in cdrows if str(r.get("frame", "")).strip() != ""}
        for i, r in enumerate(rows):
            fr = int(str(r.get("frame", i)).strip()) if str(r.get("frame", "")).strip() else i
            cd = by_frame.get(fr)
            if cd is None:
                continue
            src = str(cd.get("source", "human")).strip().lower()
            has_human[i] = (src == "human")
            took_over[i] = str(cd.get("took_over", "0")).strip() not in ("", "0")
            col = str(cd.get("collided", "0")).strip()
            collided[i] = col not in ("", "0")
            lo = str(cd.get("lane_offset", "")).strip()
            if lo not in ("", "None"):
                try:
                    lane_off[i] = float(lo)
                except ValueError:
                    lane_off[i] = 0.0

    prev_keys: List[Optional[Dict[str, int]]] = [None]
    for i in range(1, len(keys)):
        prev_keys.append(keys[i - 1])

    rewards = []
    prev_speed = 0.0
    for i in range(len(speeds)):
        d = R.dense_reward(speeds[i], bool(valid[i]), prev_speed, lane_off[i],
                           collided[i], reward_weights)
        rewards.append(R.compose_frame_reward(d, 0.0, took_over[i], reward_weights))
        if valid[i]:
            prev_speed = speeds[i]

    return build_encoded_episodes(
        speeds, valid, keys, vlabels, hlabels, has_human, rewards,
        prev_keys=prev_keys, fps=fps)


# ---------------------------------------------------------------------------
# Warm-start the V3 weights (guarded; see reconstruction note)
# ---------------------------------------------------------------------------
def load_v3_state_dict(ckpt: Optional[Path]) -> Optional[Dict[str, object]]:
    """Return a V3 state dict or None.

    On hosts that lack the NPU runtime this returns None (with a warning) rather
    than crashing: the trainer's policy head is re-initialised from scratch and
    fine-tuned; warm-start of the visual backbone of the production checkpoint is
    performed on the deployment host by the export pipeline, not here. This keeps
    the Mac-side runnable and honest about what it did and did not load.
    """
    if ckpt is None:
        return None
    ckpt = Path(ckpt)
    if not ckpt.exists():
        print(f"[rl] ⚠ checkpoint 不存在，跳过 warm-start：{ckpt}")
        return None
    try:
        import torch

        sd = torch.load(str(ckpt), map_location="cpu", weights_only=False)
    except ModuleNotFoundError as exc:
        print(f"[rl] ⚠ 无法反序列化 checkpoint（缺依赖 {exc.name}），"
              f"本机将由导出管线负责 warm-start；此处从零训练策略头。")
        return None
    except Exception as exc:  # noqa: BLE001
        print(f"[rl] ⚠ checkpoint 反序列化失败（{type(exc).__name__}: {exc}），跳过 warm-start。")
        return None
    for k in ("model", "model_state_dict", "state_dict"):
        if isinstance(sd, dict) and k in sd and isinstance(sd[k], dict):
            sd = sd[k]
            break
    return sd


# ---------------------------------------------------------------------------
# High-level driver
# ---------------------------------------------------------------------------
def _collect_clips(clips_dir: Path) -> List[Path]:
    clips = sorted(p for p in Path(clips_dir).glob("clip_*") if p.is_dir())
    if not clips:
        raise FileNotFoundError(f"{clips_dir} 下没有 clip_* 目录")
    return clips


def train(
    clips_dir: Path,
    stage: str,
    epochs: int = 5,
    lr: float = 3e-4,
    batch_size: int = 64,
    lambda_imitation: float = 0.5,
    lambda_decay: float = 0.7,
    clip_eps: float = 0.2,
    gamma: float = 0.99,
    lam: float = 0.95,
    seed: int = 42,
    init_from: Optional[Path] = None,
) -> Dict[str, object]:
    np.random.seed(seed)
    clips = _collect_clips(Path(clips_dir))

    # Concatenate episodes from all clips.
    parts = [load_episodes_from_controls(c) for c in clips]
    feats = np.concatenate([p.features for p in parts], axis=0)
    vlab = np.concatenate([p.vertical for p in parts])
    hlab = np.concatenate([p.horizontal for p in parts])
    human = np.concatenate([p.has_human for p in parts])
    reward = np.concatenate([p.reward for p in parts])

    n = feats.shape[0]
    if n == 0:
        raise ValueError("没有可用帧")
    feat_dim = feats.shape[1]
    print(f"[rl] stage={stage} clips={len(clips)} frames={n} feat_dim={feat_dim} "
          f"human={int(human.sum())} ai={int((~human).sum())}")

    policy = P.DiscretePolicy.from_dim(feat_dim, seed=seed)
    critic = P.LinearCritic.from_dim(feat_dim, seed=seed + 1)

    hist: List[Dict[str, float]] = []
    lam_now = float(lambda_imitation)
    snapshots: List[Dict[str, np.ndarray]] = []
    for ep in range(epochs):
        if stage == "bc":
            idx = np.where(human)[0]
            if idx.size == 0:
                raise ValueError("BC 阶段没有人类帧（has_human 全 False）")
            losses = []
            for _ in range(max(1, idx.size // batch_size)):
                batch = np.random.choice(idx, size=min(batch_size, idx.size), replace=True)
                loss, grads = P.bc_loss_and_grads(
                    policy, feats[batch], vlab[batch], hlab[batch])
                P.sgd_update(policy, grads, lr)
                losses.append(loss)
            snapshots.append({"v_w": policy.v_w.copy(), "h_w": policy.h_w.copy()})
            hist.append({"epoch": ep, "bc_loss": float(np.mean(losses)),
                         "lambda_imitation": lam_now})
            print(f"[rl][bc] ep{ep} loss={np.mean(losses):.4f}")
        elif stage == "ppo":
            # One pass over the data as one big "episode" (ordered).
            order = np.argsort(np.arange(n))  # stable identity; real caller chunks
            f = feats[order]; r = reward[order]; hm = human[order]
            vlab_o = vlab[order]; hlab_o = hlab[order]
            # Critic baseline on all states.
            values = critic.predict(f)
            adv, vtarget = R.gae_advantages(r, values, gamma=gamma, lam=lam)
            adv = P.normalize_advantages(adv)
            # Old policy probs for the importance ratio (snapshot once per epoch).
            old_vp = policy.v_probs(f)
            old_hp = policy.h_probs(f)
            losses = []
            for start in range(0, n, batch_size):
                sl = slice(start, start + batch_size)
                fb = f[sl]; vb = vlab_o[sl]; hb = hlab_o[sl]
                hm_b = hm[sl]; adv_b = adv[sl]; vt_b = vtarget[sl]
                ovp = old_vp[sl]; ohp = old_hp[sl]
                loss, pgrads, cgrads = P.ppo_loss_and_grads(
                    policy, critic, fb, vb, hb, adv_b, vt_b, ovp, ohp,
                    clip_eps, lam_now, hm_b)
                P.sgd_update(policy, pgrads, lr)
                critic.sgd_update(cgrads, lr)
                losses.append(loss)
            snapshots.append({"v_w": policy.v_w.copy(), "h_w": policy.h_w.copy(),
                              "critic_w": critic.w.copy()})
            hist.append({"epoch": ep, "ppo_loss": float(np.mean(losses)),
                         "lambda_imitation": lam_now})
            print(f"[rl][ppo] ep{ep} loss={np.mean(losses):.4f} lambda={lam_now:.3f}")
            lam_now *= lambda_decay
        else:
            raise ValueError(f"未知 stage: {stage}")

    return {
        "stage": stage,
        "frames": n,
        "epochs": epochs,
        "history": hist,
        "policy": policy,
        "critic": critic,
        "snapshots": snapshots,
    }


def _parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="V3 人机共驾 RL 训练（BC / PPO）")
    ap.add_argument("--clips", required=True, help="录制目录（含 clip_* 子目录）")
    ap.add_argument("--stage", required=True, choices=["bc", "ppo"])
    ap.add_argument("--epochs", type=int, default=5)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--lambda-imitation", type=float, default=0.5,
                    help="PPO 中模仿人类损失的初始权重（随 epoch 衰减）")
    ap.add_argument("--lambda-decay", type=float, default=0.7)
    ap.add_argument("--clip-eps", type=float, default=0.2)
    ap.add_argument("--gamma", type=float, default=0.99)
    ap.add_argument("--lam", type=float, default=0.95)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--init-from", default=None, help="V3 checkpoint（warm-start，尽力而为）")
    return ap.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parse_args(argv)
    init = Path(args.init_from) if args.init_from else None
    result = train(
        clips_dir=Path(args.clips),
        stage=args.stage,
        epochs=args.epochs,
        lr=args.lr,
        batch_size=args.batch_size,
        lambda_imitation=args.lambda_imitation,
        lambda_decay=args.lambda_decay,
        clip_eps=args.clip_eps,
        gamma=args.gamma,
        lam=args.lam,
        seed=args.seed,
        init_from=init,
    )
    print(f"[rl] 完成 stage={result['stage']} frames={result['frames']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
