"""Property / invariant tests for the CURRENT reward + torch policy code.

Randomised coverage, but every assertion is a genuine invariant -- there are NO
constant-true placeholder assertions. The old numpy-only helpers no longer exist
and are not referenced. Policy paths use a tiny synthetic backbone (no real
checkpoint, no real model).
"""

import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

_HERE = Path(__file__).resolve()
sys.path.insert(0, str(_HERE.parents[1]))   # tools/v3_rl
sys.path.insert(0, str(_HERE.parents[3]))   # repo root
import reward as R  # noqa: E402
import policy as P  # noqa: E402
from tests import _harness as H  # noqa: E402


class _Head(nn.Module):
    def __init__(self, d: int = 6, hidden: int = 8):
        super().__init__()
        self.trunk = nn.Linear(d, hidden)
        self.vertical = nn.Linear(hidden, 3)
        self.horizontal = nn.Linear(hidden, 3)


class _FakeV3(nn.Module):
    def __init__(self, d: int = 6):
        super().__init__()
        self.output_head = _Head(d)
        self.backbone = nn.Linear(d, d)


def _pol(d: int = 6) -> P.TorchPolicy:
    return P.TorchPolicy(_FakeV3(d), state_dim=d)


def _ref_backfill(events, ft, window):
    """Independent brute-force reimplementation of the backward backfill."""
    n = len(ft)
    out = np.zeros(n, dtype=np.float32)
    evs = sorted(((e.t, e.score) for e in events
                  if np.isfinite(e.t) and np.isfinite(e.score)), key=lambda x: x[0])
    for t, sc in evs:
        for j in range(n):
            if (ft[j] > t - window) and (ft[j] <= t + 1e-9):
                out[j] = max(-1.0, min(1.0, sc))
    return out


def run() -> None:
    rng = np.random.default_rng(123)

    # ── reward 三段速度 / 边界 ───────────────────────────────────────────
    # speed_term 三段式：v<100 负、100≤v≤160 线性正、v>160 负。单调上升只在 [0,160] 成立。
    prev = -2.0
    for sp in range(0, 161, 5):
        st = R.speed_term(float(sp), True)
        H.check(st >= prev - 1e-9, f"speed_term 上升段单调（0..160）at {sp}")
        prev = st
    # 在 [0,160] 上取值有界 [-1, +1]；v>160 为按超出扣的负分（无下界，越高越负）。
    for _ in range(50):
        sp = float(rng.uniform(0, 160))
        st = R.speed_term(sp, True)
        H.check(-1.0 - 1e-9 <= st <= 1.0 + 1e-9, "speed_term 在 [0,160] 上界 [-1,1]")
    prev_over = 0.0
    for sp in [161.0, 200.0, 300.0, 400.0]:
        st = R.speed_term(sp, True)
        H.check(st < 0.0, f"speed_term v>160 为负 at {sp}")
        H.check(st <= prev_over + 1e-12, f"speed_term v>160 越高越负（不回升）at {sp}")
        prev_over = st
    # 三段正确性 + 100 处连续（两端点都恰为 0）；160 处是设计跳变（160 为甜点上限最大正，
    # 一旦越过立刻变负），故**不**断言 160 处连续。
    H.check_close(R.speed_term(99.0, True), -0.01, msg="speed 99 -> -0.01")
    H.check_close(R.speed_term(100.0, True), 0.0, msg="speed 100 -> 0（下分界）")
    H.check_close(R.speed_term(130.0, True), 0.5, msg="speed 130 -> +0.5")
    H.check_close(R.speed_term(160.0, True), 1.0, msg="speed 160 -> +1.0（甜点上限最大正）")
    H.check_close(R.speed_term(161.0, True), -1.0 / 60.0, msg="speed 161 -> -1/60（越过即小负）")
    H.check_close(R.speed_term(100.0 - 1e-6, True),
                  R.speed_term(100.0 + 1e-6, True), tol=1e-6,
                  msg="speed 在 100 处左右连续")
    for _ in range(50):
        off = float(rng.uniform(-3, 3))
        H.check(0.0 <= R.lane_term(off) <= 1.0, "lane_term in [0,1]")
    for _ in range(50):
        a = float(rng.uniform(0, 200)); b = float(rng.uniform(0, 200))
        H.check(0.0 <= R.decel_term(a, b, True) <= 1.0, "decel_term in [0,1]")

    fast = R.dense_reward(100.0, True, 100.0, 0.0, False)
    for _ in range(20):
        slow_sp = float(rng.uniform(0, 30))
        slow = R.dense_reward(slow_sp, True, slow_sp, 0.0, False)
        H.check(fast > slow, "fast & centred beats stopped")

    for _ in range(20):
        sp = float(rng.uniform(0, 100))
        d = R.dense_reward(sp, True, sp, 0.0, False)
        H.check(R.compose_frame_reward(d, 0.0, True) < R.compose_frame_reward(d, 0.0, False),
                "takeover strictly lowers reward")

    # ── backfill vs brute-force reference, range, no NaN ────────────────
    fps = 15.0
    n = 300
    ft = np.arange(n, dtype=np.float64) / fps
    for _ in range(20):
        events = [R.HumanEvent(float(rng.uniform(0, n / fps)), float(rng.uniform(-1, 1)))
                  for _ in range(int(rng.integers(1, 8)))]
        sc = R.backfill_human_scores(events, ft)
        H.check(sc.shape == (n,), "backfill shape")
        H.check(np.all(sc >= -1.0) and np.all(sc <= 1.0), "backfill in [-1,1]")
        H.check(not np.any(np.isnan(sc)), "backfill no NaN")
        H.check(np.allclose(sc, _ref_backfill(events, ft, 0.5), atol=1e-6),
                "backfill matches brute-force reference")

    ev = [R.HumanEvent(1.0, 0.7)]
    a1 = R.backfill_human_scores(ev, ft)
    a2 = R.backfill_human_scores(ev, ft)
    H.check(np.array_equal(a1, a2), "backfill deterministic")

    # no forward smear: single event, every frame AFTER the press stays 0
    scf = R.backfill_human_scores([R.HumanEvent(1.0, 1.0)], ft)
    after = np.where(ft > 1.0)[0]
    H.check(np.all(scf[after] == 0.0), "no forward smear after press")
    inside = np.where((ft > 0.5) & (ft <= 1.0))[0]
    H.check(np.allclose(scf[inside], 1.0), "all in-window frames scored")

    # ── gae invariants ──────────────────────────────────────────────────
    adv_lo, _ = R.gae_advantages([1.0] * 4, [0.0] * 4, gamma=0.5, lam=0.95)
    adv_hi, _ = R.gae_advantages([1.0] * 4, [0.0] * 4, gamma=0.9, lam=0.95)
    H.check(float(adv_hi[0]) > float(adv_lo[0]), "higher gamma -> higher advantage")

    adv0, vt0 = R.gae_advantages([0.0] * 3, [0.0] * 3)
    H.check(np.allclose(adv0, 0.0), "gae zero rewards -> zero adv")
    H.check(np.allclose(vt0, 0.0), "gae zero rewards -> zero value target")

    advp, _ = R.gae_advantages([0.0, 10.0], [0.0, 0.0], episode_ends=[True, True])
    H.check_close(float(advp[0]), 0.0, msg="per-episode: ep0 isolated (no leak)")
    H.check_close(float(advp[1]), 10.0, msg="per-episode: ep1 terminal adv 10")

    # ── normalize_advantages ────────────────────────────────────────────
    for _ in range(10):
        adv = rng.normal(size=50)
        na = R.normalize_advantages(adv)
        H.check(np.isfinite(na).all(), "norm adv finite")
        H.check_close(float(na.mean()), 0.0, tol=1e-4, msg="norm adv mean 0")
        H.check_close(float(na.std()), 1.0, tol=1e-4, msg="norm adv std 1")
    bad = R.normalize_advantages(np.array([np.nan, 1.0, np.inf, -np.inf]))
    H.check(np.all(bad == 0.0), "non-finite advantages -> all zero")

    # ── policy: probability simplex over random inits ───────────────────
    d, N = 6, 8
    tok = torch.randn(N, d)
    for s in range(10):
        torch.manual_seed(s)
        pol = _pol(d)
        vp, hp, val = pol.probs(tok)
        H.check(np.allclose(vp.sum(1).detach().numpy(), 1.0), "v probs simplex")
        H.check(np.allclose(hp.sum(1).detach().numpy(), 1.0), "h probs simplex")
        H.check(bool((vp >= 0).all() and (vp <= 1).all()), "v prob range")
        H.check(bool((hp >= 0).all() and (hp <= 1).all()), "h prob range")
        H.check_eq(tuple(val.shape), (N,), "value shape")

    # ── bc_loss >= 0 across random policies/labels ──────────────────────
    for s in range(20):
        torch.manual_seed(s)
        pol = _pol(d)
        X = torch.randn(12, d)
        vt = torch.randint(0, 3, (12,))
        ht = torch.randint(0, 3, (12,))
        loss = P.bc_loss(pol, X, vt, ht)
        H.check(float(loss.detach()) >= 0.0, "BC loss non-negative")

    # bc loss near zero on confident-correct prediction
    pol = _pol(d)
    with torch.no_grad():
        pol.v3.output_head.vertical.weight.zero_()
        pol.v3.output_head.vertical.bias.copy_(torch.tensor([50.0, -50.0, -50.0]))
        pol.v3.output_head.horizontal.weight.zero_()
        pol.v3.output_head.horizontal.bias.copy_(torch.tensor([50.0, -50.0, -50.0]))
    X = torch.randn(3, d)
    loss = P.bc_loss(pol, X, torch.zeros(3, dtype=torch.long), torch.zeros(3, dtype=torch.long))
    H.check(float(loss.detach()) < 1e-3, "BC loss near zero on confident-correct")

    # ── PPO: ratio == 1 when old == current, loss reconstruct ───────────
    pol = _pol(d)
    X = torch.randn(6, d)
    va = torch.randint(0, 3, (6,)); ha = torch.randint(0, 3, (6,))
    adv = torch.randn(6); vt = torch.randn(6)
    vp, hp, _ = pol.probs(X)
    ai = torch.ones(6, dtype=torch.bool)
    hu = torch.zeros(6, dtype=torch.bool)
    total, st = P.ppo_loss(pol, X, va, ha, vp, hp, adv, vt, ai_mask=ai, human_mask=hu,
                           clip_eps=0.2, lambda_imitation=0.0, ent_coef=0.0)
    H.check(np.isfinite(float(total.detach())), "ppo loss finite")
    H.check_close(st["ratio_mean"], 1.0, tol=1e-5, msg="ratio == 1 when old==current")
    H.check_close(float(total.detach()), -float(adv.mean()) + 0.5 * st["v_loss"],
                  tol=1e-4, msg="PPO total = -mean(adv) + vf*MSE at ratio 1")

    # ── PPO clip: ratio far above 1+eps -> clipped branch caps pg ────────
    pol = _pol(d)
    X = torch.randn(6, d)
    va = torch.zeros(6, dtype=torch.long); ha = torch.zeros(6, dtype=torch.long)
    with torch.no_grad():
        pol.v3.output_head.vertical.weight.zero_()
        pol.v3.output_head.vertical.bias.copy_(torch.tensor([10.0, -10.0, -10.0]))
        pol.v3.output_head.horizontal.weight.zero_()
        pol.v3.output_head.horizontal.bias.copy_(torch.tensor([10.0, -10.0, -10.0]))
    old = torch.full((6, 3), 1.0 / 3.0)
    advp = torch.full((6,), 2.0)
    _, stc = P.ppo_loss(pol, X, va, ha, old, old, advp, torch.zeros(6),
                        ai_mask=torch.ones(6, dtype=torch.bool),
                        human_mask=torch.zeros(6, dtype=torch.bool),
                        clip_eps=0.2, lambda_imitation=0.0, ent_coef=0.0)
    H.check(stc["ratio_mean"] > 1.2, "ratio exceeds clip upper bound")
    H.check_close(stc["pg_loss"], -1.2 * 2.0, tol=1e-4,
                  msg="clipped branch caps pg at -(1+eps)*adv")

    # ── lambda_imitation scales the bc term linearly ────────────────────
    pol = _pol(d)
    X = torch.randn(6, d)
    va = torch.randint(0, 3, (6,)); ha = torch.randint(0, 3, (6,))
    adv = torch.randn(6); vt = torch.randn(6); vp, hp, _ = pol.probs(X)
    ai = torch.ones(6, dtype=torch.bool); hu = torch.ones(6, dtype=torch.bool)
    t0, _ = P.ppo_loss(pol, X, va, ha, vp, hp, adv, vt, ai_mask=ai, human_mask=hu,
                       clip_eps=0.2, lambda_imitation=0.0)
    t1, _ = P.ppo_loss(pol, X, va, ha, vp, hp, adv, vt, ai_mask=ai, human_mask=hu,
                       clip_eps=0.2, lambda_imitation=0.1)
    t2, _ = P.ppo_loss(pol, X, va, ha, vp, hp, adv, vt, ai_mask=ai, human_mask=hu,
                       clip_eps=0.2, lambda_imitation=0.2)
    H.check_close(float((t2 - t1).detach()), float((t1 - t0).detach()), tol=1e-5,
                  msg="imitation term linear in lambda")

    # ── full pipeline: rewards -> gae -> value head regression lowers MSE ─
    fr = [R.FrameSignals(speed_kmh=float(s), speed_valid=True) for s in range(30, 80)]
    ft2 = np.arange(50, dtype=np.float64) / 15.0
    rewards = R.compute_episode_rewards(fr, [], ft2)
    H.check_eq(len(rewards), 50, "pipeline rewards len")
    pol = _pol(d)
    Xp = torch.randn(50, d)
    with torch.no_grad():
        _, _, vals = pol(Xp)
    adv2, vtarget2 = R.gae_advantages(rewards, vals.detach().numpy(), gamma=0.99, lam=0.95)
    H.check_eq(len(adv2), 50, "pipeline adv len")
    VT = torch.tensor(vtarget2, dtype=torch.float32)
    opt = torch.optim.Adam(pol.value_head.parameters(), lr=0.05)
    with torch.no_grad():
        _, _, v0 = pol(Xp)
        before = float(((v0 - VT) ** 2).mean())
    for _ in range(100):
        opt.zero_grad()
        _, _, v = pol(Xp)
        ((v - VT) ** 2).mean().backward()
        opt.step()
    with torch.no_grad():
        _, _, v1 = pol(Xp)
        after = float(((v1 - VT) ** 2).mean())
    H.check(after < before, f"value regression lowers MSE ({before:.3f}->{after:.3f})")
