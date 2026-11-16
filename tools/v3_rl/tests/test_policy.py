"""Tests for policy.py: softmax, BC/PPO gradients (finite-difference), learning."""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import policy as P  # noqa: E402
from tests import _harness as H  # noqa: E402


def _as_f64(pol):
    for a in ("v_w", "v_b", "h_w", "h_b"):
        setattr(pol, a, getattr(pol, a).astype(np.float64))
    return pol


def run() -> None:
    rng = np.random.default_rng(0)

    # ── softmax ─────────────────────────────────────────────────────────
    z = np.array([[1.0, 2.0, 3.0], [0.0, 0.0, 0.0]])
    sm = P.softmax(z)
    H.check_close(float(sm.sum(axis=1)[0]), 1.0, msg="softmax sums to 1")
    H.check_close(float(sm.sum(axis=1)[1]), 1.0, msg="softmax rows sum 1")
    H.check(np.all(sm >= 0), "softmax non-negative")
    # uniform logits -> uniform probs
    H.check_close(float(sm[1, 0]), 1.0 / 3.0, msg="uniform softmax")
    # monotonic: higher logit -> higher prob
    H.check(sm[0, 2] > sm[0, 1] > sm[0, 0], "softmax monotonic")
    # stability with huge logits (no overflow)
    big = P.softmax(np.array([[1000.0, 1000.0, 1000.0]]))
    H.check(np.isfinite(big).all(), "softmax stable with big logits")
    H.check_close(float(big.sum()), 1.0, msg="big softmax sums 1")
    # log_softmax consistency
    lsm = P.log_softmax(z)
    H.check_close(float(np.exp(lsm).sum(axis=1)[0]), 1.0, tol=1e-6, msg="logsoftmax->softmax")
    H.check(np.all(lsm <= 1e-9), "log_softmax <= 0")

    # ── policy forward shapes ───────────────────────────────────────────
    F, N = 6, 5
    X = rng.normal(size=(N, F))
    pol = _as_f64(P.DiscretePolicy.from_dim(F, seed=1))
    H.check_eq(pol.v_probs(X).shape, (N, 3), "v_probs shape")
    H.check_eq(pol.h_probs(X).shape, (N, 3), "h_probs shape")
    H.check(np.allclose(pol.v_probs(X).sum(1), 1.0), "v_probs rows sum 1")
    H.check(np.allclose(pol.h_probs(X).sum(1), 1.0), "h_probs rows sum 1")
    # act returns valid class indices
    va, ha = pol.act(X, np.random.default_rng(3))
    H.check(((va >= 0) & (va < 3)).all(), "act vertical in range")
    H.check(((ha >= 0) & (ha < 3)).all(), "act horizontal in range")

    # ── BC gradient check ───────────────────────────────────────────────
    vt = rng.integers(0, 3, N); ht = rng.integers(0, 3, N)

    def bc_loss():
        return P.bc_loss_and_grads(pol, X, vt, ht)[0]

    _, g = P.bc_loss_and_grads(pol, X, vt, ht)
    d = 1e-7
    maxerr = 0.0
    for i in range(F):
        for j in range(3):
            old = pol.v_w[i, j]; pol.v_w[i, j] = old + d; lp = bc_loss()
            pol.v_w[i, j] = old - d; lm = bc_loss(); pol.v_w[i, j] = old
            maxerr = max(maxerr, abs((lp - lm) / (2 * d) - g["v_w"][i, j]))
            old = pol.h_w[i, j]; pol.h_w[i, j] = old + d; lp = bc_loss()
            pol.h_w[i, j] = old - d; lm = bc_loss(); pol.h_w[i, j] = old
            maxerr = max(maxerr, abs((lp - lm) / (2 * d) - g["h_w"][i, j]))
    H.check(maxerr < 1e-5, f"BC gradient matches numeric (maxerr={maxerr:.2e})")
    H.check_close(float(g["v_b"].sum()), 0.0, tol=1e-5, msg="BC grad sums to ~0 across classes")

    # ── PPO gradient check (with imitation) ─────────────────────────────
    va2 = rng.integers(0, 3, N); ha2 = rng.integers(0, 3, N)
    adv = rng.normal(size=N); vtarget = rng.normal(size=N)
    crit = P.LinearCritic.from_dim(F, seed=2); crit.w = crit.w.astype(np.float64)
    old_vp = pol.v_probs(X); old_hp = pol.h_probs(X)
    is_human = rng.random(N) > 0.4

    def ppo_loss():
        return P.ppo_loss_and_grads(pol, crit, X, va2, ha2, adv, vtarget,
                                    old_vp, old_hp, 0.2, 0.3, is_human)[0]

    _, pg, cg = P.ppo_loss_and_grads(pol, crit, X, va2, ha2, adv, vtarget,
                                     old_vp, old_hp, 0.2, 0.3, is_human)
    maxerr = 0.0
    for i in range(F):
        for j in range(3):
            old = pol.v_w[i, j]; pol.v_w[i, j] = old + d; lp = ppo_loss()
            pol.v_w[i, j] = old - d; lm = ppo_loss(); pol.v_w[i, j] = old
            maxerr = max(maxerr, abs((lp - lm) / (2 * d) - pg["v_w"][i, j]))
            old = pol.h_w[i, j]; pol.h_w[i, j] = old + d; lp = ppo_loss()
            pol.h_w[i, j] = old - d; lm = ppo_loss(); pol.h_w[i, j] = old
            maxerr = max(maxerr, abs((lp - lm) / (2 * d) - pg["h_w"][i, j]))
    H.check(maxerr < 1e-5, f"PPO policy gradient matches numeric (maxerr={maxerr:.2e})")

    maxerr_c = 0.0
    for i in range(F):
        old = crit.w[i, 0]; crit.w[i, 0] = old + d; lp = ppo_loss()
        crit.w[i, 0] = old - d; lm = ppo_loss(); crit.w[i, 0] = old
        maxerr_c = max(maxerr_c, abs((lp - lm) / (2 * d) - cg["w"][i, 0]))
    H.check(maxerr_c < 1e-5, f"PPO critic gradient matches numeric (maxerr={maxerr_c:.2e})")
    oldb = crit.b; crit.b = oldb + d; lp = ppo_loss(); crit.b = oldb - d; lm = ppo_loss(); crit.b = oldb
    H.check(abs((lp - lm) / (2 * d) - cg["b"]) < 1e-5, "PPO critic bias grad matches")

    # ── normalize_advantages ────────────────────────────────────────────
    a = np.array([1.0, 2.0, 3.0, 4.0])
    na = P.normalize_advantages(a)
    H.check_close(float(na.mean()), 0.0, tol=1e-5, msg="normalized mean 0")
    H.check_close(float(na.std()), 1.0, tol=1e-5, msg="normalized std 1")
    H.check_eq(len(P.normalize_advantages(np.array([]))), 0, "normalize empty")

    # ── BC actually learns (loss decreases) ─────────────────────────────
    pol2 = P.DiscretePolicy.from_dim(F, seed=5)
    # separable labels: class from sum of features
    X2 = rng.normal(size=(60, F))
    vt2 = (np.abs(X2[:, 0]) * 3).clip(0, 2).astype(int) % 3
    ht2 = (np.abs(X2[:, 1]) * 3).clip(0, 2).astype(int) % 3
    first = P.bc_loss_and_grads(pol2, X2, vt2, ht2)[0]
    for _ in range(200):
        _, gg = P.bc_loss_and_grads(pol2, X2, vt2, ht2)
        P.sgd_update(pol2, gg, 0.5)
    last = P.bc_loss_and_grads(pol2, X2, vt2, ht2)[0]
    H.check(last < first, f"BC loss decreases ({first:.3f}->{last:.3f})")
    acc = P.evaluate_accuracy(pol2, X2, vt2, ht2)
    H.check(acc["vertical_acc"] > 0.5, f"BC vertical acc improved ({acc['vertical_acc']:.2f})")
    H.check(acc["horizontal_acc"] > 0.5, f"BC horiz acc improved ({acc['horizontal_acc']:.2f})")

    # evaluate_accuracy on empty
    e = P.evaluate_accuracy(pol2, np.zeros((0, F)), np.zeros(0, int), np.zeros(0, int))
    H.check_close(e["vertical_acc"], 0.0, msg="empty eval acc 0")

    # sgd_update moves weights in the gradient direction
    w0 = pol2.v_w.copy()
    gg = {"v_w": np.ones_like(pol2.v_w), "v_b": np.zeros_like(pol2.v_b),
          "h_w": np.zeros_like(pol2.h_w), "h_b": np.zeros_like(pol2.h_b)}
    P.sgd_update(pol2, gg, 0.1)
    H.check(np.allclose(pol2.v_w, w0 - 0.1), "sgd_update subtracts lr*grad")

    # critic sgd update
    crit2 = P.LinearCritic.from_dim(F, seed=9)
    w0c = crit2.w.copy()
    crit2.sgd_update({"w": np.ones_like(crit2.w), "b": 0.0}, 0.1)
    H.check(np.allclose(crit2.w, w0c - 0.1), "critic sgd subtracts")
    H.check_close(crit2.b, 0.0, msg="critic bias unchanged with 0 grad")
