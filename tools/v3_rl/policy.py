"""Pure-numpy discrete policy, critic, and PPO/BC maths for V3 RL.

Kept dependency-free (numpy only) so the whole training objective and its gradient
flow can be unit tested deterministically on CPU without a checkpoint or GPU. The
production policy in the deployed model is the V3 output head; this lightweight
head is trained on top of the frozen V3 state-token features and is what the RL
loop optimises here.

Policy factorisation: two independent categorical heads (vertical over {W,NONE,S},
horizontal over {A,NONE,D}), mirroring the V3 output head's factorisation.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Tuple

import numpy as np

NUM_V = 3
NUM_H = 3


def softmax(z: np.ndarray) -> np.ndarray:
    z = z - z.max(axis=-1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)


def log_softmax(z: np.ndarray) -> np.ndarray:
    z = z - z.max(axis=-1, keepdims=True)
    return z - np.log(np.exp(z).sum(axis=-1, keepdims=True))


@dataclass
class DiscretePolicy:
    """Two linear categorical heads: logits = X W + b."""

    feat_dim: int
    v_w: np.ndarray = field(default=None)  # [F, NUM_V]
    v_b: np.ndarray = field(default=None)  # [NUM_V]
    h_w: np.ndarray = field(default=None)  # [F, NUM_H]
    h_b: np.ndarray = field(default=None)  # [NUM_H]

    @classmethod
    def from_dim(cls, feat_dim: int, seed: int = 0) -> "DiscretePolicy":
        rng = np.random.default_rng(seed)
        scale = 1.0 / np.sqrt(feat_dim)
        return cls(
            feat_dim=feat_dim,
            v_w=rng.normal(0, scale, (feat_dim, NUM_V)).astype(np.float32),
            v_b=np.zeros(NUM_V, dtype=np.float32),
            h_w=rng.normal(0, scale, (feat_dim, NUM_H)).astype(np.float32),
            h_b=np.zeros(NUM_H, dtype=np.float32),
        )

    # -- forward ---------------------------------------------------------
    def v_logits(self, X: np.ndarray) -> np.ndarray:
        return X @ self.v_w + self.v_b

    def h_logits(self, X: np.ndarray) -> np.ndarray:
        return X @ self.h_w + self.h_b

    def v_probs(self, X: np.ndarray) -> np.ndarray:
        return softmax(self.v_logits(X))

    def h_probs(self, X: np.ndarray) -> np.ndarray:
        return softmax(self.h_logits(X))

    def act(self, X: np.ndarray, rng: np.random.Generator = None) -> Tuple[np.ndarray, np.ndarray]:
        vp = self.v_probs(X)
        hp = self.h_probs(X)
        rng = rng or np.random.default_rng()
        va = np.array([rng.choice(NUM_V, p=p) for p in vp])
        ha = np.array([rng.choice(NUM_H, p=p) for p in hp])
        return va, ha


@dataclass
class LinearCritic:
    w: np.ndarray = field(default=None)  # [F, 1]
    b: float = 0.0

    @classmethod
    def from_dim(cls, feat_dim: int, seed: int = 0) -> "LinearCritic":
        rng = np.random.default_rng(seed)
        return cls(w=rng.normal(0, 1.0 / np.sqrt(feat_dim), (feat_dim, 1)).astype(np.float32),
                   b=0.0)

    def predict(self, X: np.ndarray) -> np.ndarray:
        return (X @ self.w + self.b).ravel()

    def sgd_update(self, grads: Dict[str, np.ndarray], lr: float) -> None:
        self.w -= lr * grads["w"]
        self.b -= lr * float(grads["b"])


def _accumulate_linear_grads(
    X: np.ndarray, dlogits: np.ndarray
) -> Tuple[np.ndarray, np.ndarray]:
    """Return (dW [F,K], db [K]) for a linear layer logits = X W + b, given
    dL/dlogits [N,K]."""
    dW = X.T @ dlogits
    db = dlogits.sum(axis=0)
    return dW, db


# ---------------------------------------------------------------------------
# BC (imitation) loss + grads
# ---------------------------------------------------------------------------
def bc_loss_and_grads(
    policy: DiscretePolicy,
    X: np.ndarray,
    v_target: np.ndarray,
    h_target: np.ndarray,
) -> Tuple[float, Dict[str, np.ndarray]]:
    """Cross-entropy imitation loss over both heads.

    Returns (scalar_loss, grads) with grads keys v_w, v_b, h_w, h_b.
    """
    n = X.shape[0]
    v_logits = policy.v_logits(X)
    h_logits = policy.h_logits(X)
    v_logp = log_softmax(v_logits)
    h_logp = log_softmax(h_logits)
    idx = np.arange(n)
    loss = -(v_logp[idx, v_target].mean() + h_logp[idx, h_target].mean())

    # dL/dlogits = (softmax - onehot) / N  per head
    v_p = np.exp(v_logp)
    h_p = np.exp(h_logp)
    dv = v_p.copy()
    dv[idx, v_target] -= 1.0
    dv /= n
    dh = h_p.copy()
    dh[idx, h_target] -= 1.0
    dh /= n

    v_dW, v_db = _accumulate_linear_grads(X, dv)
    h_dW, h_db = _accumulate_linear_grads(X, dh)
    grads = {"v_w": v_dW, "v_b": v_db, "h_w": h_dW, "h_b": h_db}
    return float(loss), grads


# ---------------------------------------------------------------------------
# PPO loss + grads (with behaviour-regularising imitation term)
# ---------------------------------------------------------------------------
def normalize_advantages(adv: np.ndarray, eps: float = 1e-8) -> np.ndarray:
    if adv.size == 0:
        return adv
    mean = adv.mean()
    std = adv.std()
    return (adv - mean) / (std + eps)


def ppo_loss_and_grads(
    policy: DiscretePolicy,
    critic: LinearCritic,
    X: np.ndarray,
    v_action: np.ndarray,
    h_action: np.ndarray,
    advantages: np.ndarray,
    value_targets: np.ndarray,
    old_v_probs: np.ndarray,
    old_h_probs: np.ndarray,
    clip_eps: float = 0.2,
    lambda_imitation: float = 0.0,
    is_human: np.ndarray = None,
    vf_coef: float = 0.5,
) -> Tuple[float, Dict[str, np.ndarray], Dict[str, np.ndarray]]:
    """PPO clipped surrogate + value regression + behaviour-regularising BC term.

    Imitation term is applied ONLY on human frames (is_human True), matching the
    "learn from human on their frames, explore on AI frames" split. The caller
    decays lambda over epochs.

    Returns (loss, policy_grads, critic_grads).
    """
    n = X.shape[0]
    idx = np.arange(n)
    v_logits = policy.v_logits(X)
    h_logits = policy.h_logits(X)
    v_logp = log_softmax(v_logits)
    h_logp = log_softmax(h_logits)
    v_p = np.exp(v_logp)
    h_p = np.exp(h_logp)

    # π_θ/π_old = softmax_θ(a) / softmax_old(a) = exp(logp_θ - logp_old)
    old_v_a = old_v_probs[idx, v_action].clip(1e-8, 1.0)
    old_h_a = old_h_probs[idx, h_action].clip(1e-8, 1.0)
    cur_v_a = v_p[idx, v_action].clip(1e-8, 1.0)
    cur_h_a = h_p[idx, h_action].clip(1e-8, 1.0)
    ratio_v = cur_v_a / old_v_a
    ratio_h = cur_h_a / old_h_a
    ratio = ratio_v * ratio_h  # independence => product of ratios

    adv = advantages
    unclipped = ratio * adv
    clipped = np.clip(ratio, 1.0 - clip_eps, 1.0 + clip_eps) * adv
    # PPO minimises -min(unclipped, clipped)
    surr = np.minimum(unclipped, clipped)
    policy_loss = -surr.mean()

    # --- value loss (MSE) ---
    values = critic.predict(X)
    v_err = values - value_targets
    value_loss = 0.5 * np.mean(v_err ** 2)

    # --- imitation term on human frames ---
    bc_term = 0.0
    dv_bc = np.zeros_like(v_logits)
    dh_bc = np.zeros_like(h_logits)
    if lambda_imitation > 0.0 and is_human is not None and is_human.any():
        hmask = is_human.astype(np.float32)
        nh = hmask.sum()
        v_ce = -(v_logp[idx, v_action] * hmask).sum() / nh
        h_ce = -(h_logp[idx, h_action] * hmask).sum() / nh
        bc_term = v_ce + h_ce
        # grads: (softmax - onehot) * mask / nh
        dv_bc = v_p.copy(); dv_bc[idx, v_action] -= 1.0
        dv_bc *= (hmask / nh)[:, None]
        dh_bc = h_p.copy(); dh_bc[idx, h_action] -= 1.0
        dh_bc *= (hmask / nh)[:, None]

    total = policy_loss + vf_coef * value_loss + lambda_imitation * bc_term

    # --- gradients ---
    # dL/dratio for the PPO term: depends on which branch (unclipped vs clipped)
    # selected by min(). Gradient flows only when unclipped is the min.
    use_unclipped = (unclipped <= clipped).astype(np.float32)
    d_surr = -(adv * use_unclipped) / n          # d(-surr.mean)/d(ratio)
    d_ratio = d_surr
    # ratio = cur_v_a/old_v_a * cur_h_a/old_h_a; old is constant.
    # d log cur_a / d logits[j] = onehot(j==a) - softmax_j  (per head, per row).
    # Build the class-dim onehot properly: [N, NUM] where [n,j] = (j == action[n]).
    classes_v = np.arange(NUM_V)[None, :]
    classes_h = np.arange(NUM_H)[None, :]
    v_onehot = (classes_v == v_action[:, None]).astype(np.float64)
    h_onehot = (classes_h == h_action[:, None]).astype(np.float64)
    dv = d_ratio[:, None] * ratio[:, None] * (v_onehot - v_p)
    dh = d_ratio[:, None] * ratio[:, None] * (h_onehot - h_p)
    # add imitation grads
    dv = dv + lambda_imitation * dv_bc
    dh = dh + lambda_imitation * dh_bc

    v_dW, v_db = _accumulate_linear_grads(X, dv)
    h_dW, h_db = _accumulate_linear_grads(X, dh)
    policy_grads = {"v_w": v_dW, "v_b": v_db, "h_w": h_dW, "h_b": h_db}

    # critic grads: total loss has vf_coef * 0.5 * mean(err^2).
    # d/dW = vf_coef * X^T (err / N); db likewise scaled by vf_coef.
    c_err = (vf_coef * v_err / n)[:, None]
    critic_grads = {"w": X.T @ c_err, "b": float(vf_coef * v_err.mean())}
    return float(total), policy_grads, critic_grads


def sgd_update(policy: DiscretePolicy, grads: Dict[str, np.ndarray], lr: float) -> None:
    policy.v_w -= lr * grads["v_w"]
    policy.v_b -= lr * grads["v_b"]
    policy.h_w -= lr * grads["h_w"]
    policy.h_b -= lr * grads["h_b"]


def evaluate_accuracy(policy: DiscretePolicy, X: np.ndarray,
                      v_target: np.ndarray, h_target: np.ndarray) -> Dict[str, float]:
    vp = policy.v_probs(X).argmax(1)
    hp = policy.h_probs(X).argmax(1)
    return {
        "vertical_acc": float((vp == v_target).mean()) if len(v_target) else 0.0,
        "horizontal_acc": float((hp == h_target).mean()) if len(h_target) else 0.0,
    }
