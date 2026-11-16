"""Tests for policy.py TorchPolicy / bc_loss / ppo_loss.

Uses a tiny SYNTHETIC V3 backbone (`_FakeV3`) and random state_token tensors --
no real checkpoint is loaded and no real model is ever run. This keeps the whole
suite CPU-only and fast while still exercising the real policy code paths.

Key regressions:
  * only the vertical/horizontal decision heads + value head are trainable;
  * bc_loss frame_mask charges loss ONLY on human frames;
  * ppo_loss policy-gradient term is masked to AI frames only, so human rescue
    actions never enter the policy gradient;
  * value_targets are consumed as the (adv + value) regression target;
  * the PPO clipped surrogate uses min(surr1, surr2) (both branches).
"""

import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import policy as P  # noqa: E402
from tests import _harness as H  # noqa: E402

_STATE_DIM = 6


class _Head(nn.Module):
    """Mimics V3 output_head: .trunk/.vertical/.horizontal."""

    def __init__(self, d: int = _STATE_DIM, hidden: int = 8):
        super().__init__()
        self.trunk = nn.Linear(d, hidden)
        self.vertical = nn.Linear(hidden, 3)
        self.horizontal = nn.Linear(hidden, 3)


class _FakeV3(nn.Module):
    def __init__(self, d: int = _STATE_DIM):
        super().__init__()
        self.output_head = _Head(d)
        self.backbone = nn.Linear(d, d)  # stand-in for the frozen visual backbone


def _make_policy(d: int = _STATE_DIM) -> P.TorchPolicy:
    return P.TorchPolicy(_FakeV3(d), state_dim=d)


def _gmax(pol: P.TorchPolicy) -> float:
    mx = 0.0
    for p in pol.trainable_parameters():
        if p.grad is not None:
            mx = max(mx, float(p.grad.abs().max()))
    return mx


def run() -> None:
    torch.manual_seed(0)
    np.random.seed(0)

    N = 7
    d = _STATE_DIM
    tok = torch.randn(N, d)
    vlab = torch.randint(0, 3, (N,))
    hlab = torch.randint(0, 3, (N,))

    # ── forward shapes ──────────────────────────────────────────────────
    pol = _make_policy(d)
    v_logits, h_logits, value = pol(tok)
    H.check_eq(tuple(v_logits.shape), (N, 3), "vertical logits shape")
    H.check_eq(tuple(h_logits.shape), (N, 3), "horizontal logits shape")
    H.check_eq(tuple(value.shape), (N,), "value shape")

    # probs() returns valid simplex distributions + a value vector
    vp, hp, val = pol.probs(tok)
    H.check(np.allclose(vp.sum(1).detach().numpy(), 1.0), "probs vertical simplex")
    H.check(np.allclose(hp.sum(1).detach().numpy(), 1.0), "probs horizontal simplex")
    H.check(bool((vp >= 0).all() and (vp <= 1).all()), "probs vertical range")
    H.check_eq(tuple(val.shape), (N,), "probs value shape")

    # ── only the two decision heads + value head are trainable ──────────
    for p in pol.v3.output_head.vertical.parameters():
        H.check(p.requires_grad, "vertical head trainable")
    for p in pol.v3.output_head.horizontal.parameters():
        H.check(p.requires_grad, "horizontal head trainable")
    for p in pol.value_head.parameters():
        H.check(p.requires_grad, "value head trainable")
    for p in pol.v3.output_head.trunk.parameters():
        H.check(not p.requires_grad, "trunk frozen")
    for p in pol.v3.backbone.parameters():
        H.check(not p.requires_grad, "backbone frozen")
    # 2 (vertical) + 2 (horizontal) + 4 (value sequential) = 8 trainable tensors
    H.check_eq(len(pol.trainable_parameters()), 8, "exactly 8 trainable tensors")

    # optimizer only sees trainable params
    opt = P.make_optimizer(pol, 1e-3)
    n_opt = sum(len(g["params"]) for g in opt.param_groups)
    H.check_eq(n_opt, len(pol.trainable_parameters()), "optimizer only trainable params")

    # ── head_state_dict keys + round-trip through load_head_state_dict ──
    sd = pol.head_state_dict()
    expected = {"vertical.weight", "vertical.bias", "horizontal.weight",
                "horizontal.bias", "value.0.weight", "value.0.bias",
                "value.2.weight", "value.2.bias"}
    H.check_eq(set(sd.keys()), expected, "head_state_dict keys")
    pol2 = _make_policy(d)
    with torch.no_grad():  # perturb so the load is observable
        for p in pol2.v3.output_head.vertical.parameters():
            p.add_(1.0)
    pol2.load_head_state_dict(sd)
    for k in expected:
        H.check(torch.allclose(sd[k], pol2.head_state_dict()[k]), f"head round-trip {k}")

    # ── bc_loss: frame_mask charges loss only on human frames ───────────
    mask = torch.tensor([True, False, True, False, True, False, True])
    loss_masked = P.bc_loss(pol, tok, vlab, hlab, frame_mask=mask)
    # manual masked mean of per-frame CE
    v_logits, h_logits, _ = pol(tok)
    ce = (F.cross_entropy(v_logits, vlab, reduction="none")
          + F.cross_entropy(h_logits, hlab, reduction="none"))
    manual = (ce * mask.float()).sum() / (mask.float().sum())
    H.check_close(float(loss_masked.detach()), float(manual.detach()), tol=1e-6,
                  msg="bc_loss masked mean matches manual human-frame mean")
    # frame_mask=None -> plain mean over all frames
    loss_all = P.bc_loss(pol, tok, vlab, hlab)
    H.check_close(float(loss_all.detach()), float(ce.mean().detach()), tol=1e-6,
                  msg="bc_loss no mask -> mean all frames")
    # changing labels on NON-human frames must not change the masked loss
    vlab_mod = vlab.clone()
    vlab_mod[~mask] = (vlab_mod[~mask] + 1) % 3
    loss_masked2 = P.bc_loss(pol, tok, vlab_mod, hlab, frame_mask=mask)
    H.check_close(float(loss_masked.detach()), float(loss_masked2.detach()), tol=1e-6,
                  msg="bc_loss ignores non-human frames")
    # empty mask -> finite, exactly 0 (no NaN from division)
    empty_mask = torch.zeros(N, dtype=torch.bool)
    loss_empty = P.bc_loss(pol, tok, vlab, hlab, frame_mask=empty_mask)
    H.check(torch.isfinite(loss_empty).item(), "bc_loss empty mask finite")
    H.check_close(float(loss_empty.detach()), 0.0, msg="bc_loss empty mask -> 0")

    # ── ppo_loss: value_targets consumed as (adv + value) regression target
    with torch.no_grad():
        _, _, value0 = pol(tok)  # value head starts at exactly 0
    H.check_close(float(value0.abs().max()), 0.0, msg="value head init = 0")
    adv_vec = torch.tensor([2.0, -1.0, 0.5, -2.0, 1.0, 0.3, -0.7])
    value_targets = adv_vec + value0  # == adv + value
    old_vp = torch.full((N, 3), 1.0 / 3.0)
    old_hp = torch.full((N, 3), 1.0 / 3.0)
    ai_all = torch.ones(N, dtype=torch.bool)
    hu_none = torch.zeros(N, dtype=torch.bool)
    total, stats = P.ppo_loss(pol, tok, vlab, hlab, old_vp, old_hp, adv_vec,
                              value_targets, ai_mask=ai_all, human_mask=hu_none,
                              clip_eps=0.2, lambda_imitation=0.0, ent_coef=0.0)
    expected_v = 0.5 * float(F.mse_loss(value0, value_targets))
    H.check_close(stats["v_loss"], expected_v, tol=1e-6,
                  msg="v_loss = 0.5*MSE(value, adv+value)")
    # total reconstruction: pg + vf*v_loss + lambda*bc - ent*entropy
    recon = stats["pg_loss"] + 0.5 * stats["v_loss"] + 0.0 * stats["bc"]
    H.check_close(float(total.detach()), recon, tol=1e-5, msg="total = pg + vf*v + lambda*bc")

    # ── PPO clipped surrogate uses min(surr1, surr2), both branches ─────
    eps = 0.2
    v_logits, h_logits, _ = pol(tok)
    vp_c = F.softmax(v_logits, -1)
    hp_c = F.softmax(h_logits, -1)
    ar = torch.arange(N)
    cur = ((vp_c[ar, vlab] / old_vp[ar, vlab].clamp(1e-8, 1.0))
           * (hp_c[ar, hlab] / old_hp[ar, hlab].clamp(1e-8, 1.0)))
    surr1 = cur * adv_vec
    surr2 = torch.clamp(cur, 1.0 - eps, 1.0 + eps) * adv_vec
    pg_manual = (-torch.min(surr1, surr2)).mean()
    total_c, stats_c = P.ppo_loss(pol, tok, vlab, hlab, old_vp, old_hp, adv_vec,
                                  value_targets, ai_mask=ai_all, human_mask=hu_none,
                                  clip_eps=eps, lambda_imitation=0.0, ent_coef=0.0)
    H.check_close(stats_c["pg_loss"], float(pg_manual.detach()), tol=1e-5,
                  msg="ppo pg_loss = mean(-min(surr1,surr2))")
    # clipping must actually bite for at least one frame -> two-branch behaviour
    pg_unclipped = (-surr1).mean()
    H.check(not np.isclose(float(pg_manual.detach()), float(pg_unclipped.detach()),
                           atol=1e-6),
            "clip branch changes pg (min(surr1,surr2) active)")
    H.check(bool(((cur < 1.0 - eps) | (cur > 1.0 + eps)).any()),
            "ratios fall outside [1-eps,1+eps] for some frames")

    # ── KEY regression: human rescue actions not under policy gradient ──
    # All-human batch (ai_mask all False) with only the PG term active -> the
    # policy gradient must be exactly zero (rescue frames are masked out).
    pol_h = _make_policy(d)
    with torch.no_grad():
        vh, hh, _ = pol_h(tok)
        ovh = torch.softmax(vh, -1)
        ohh = torch.softmax(hh, -1)
    _, st_h = P.ppo_loss(pol_h, tok, vlab, hlab, ovh, ohh, adv_vec, value_targets,
                         ai_mask=torch.zeros(N, dtype=torch.bool),
                         human_mask=torch.ones(N, dtype=torch.bool),
                         clip_eps=0.2, lambda_imitation=0.0, vf_coef=0.0, ent_coef=0.0)
    H.check_close(st_h["pg_loss"], 0.0, msg="human-only batch -> pg_loss 0")
    # same setup but AI frames: pg gradient is nonzero
    pol_a = _make_policy(d)
    with torch.no_grad():
        va_, ha_, _ = pol_a(tok)
        ova = torch.softmax(va_, -1)
        oha = torch.softmax(ha_, -1)
    total_a, st_a = P.ppo_loss(pol_a, tok, vlab, hlab, ova, oha, adv_vec, value_targets,
                               ai_mask=torch.ones(N, dtype=torch.bool),
                               human_mask=torch.zeros(N, dtype=torch.bool),
                               clip_eps=0.2, lambda_imitation=0.0, vf_coef=0.0,
                               ent_coef=0.0)
    total_a.backward()
    H.check(_gmax(pol_a) > 0.0, "AI batch -> nonzero policy gradient")
    # and in the human-only case the gradient is exactly zero
    total_h, _ = P.ppo_loss(pol_h, tok, vlab, hlab, ovh, ohh, adv_vec, value_targets,
                            ai_mask=torch.zeros(N, dtype=torch.bool),
                            human_mask=torch.ones(N, dtype=torch.bool),
                            clip_eps=0.2, lambda_imitation=0.0, vf_coef=0.0,
                            ent_coef=0.0)
    total_h.backward()
    H.check_close(_gmax(pol_h), 0.0, msg="human-only batch -> zero policy gradient")

    # ── empty ai/human masks -> finite total, no NaN ────────────────────
    total_e, st_e = P.ppo_loss(pol, tok, vlab, hlab, old_vp, old_hp, adv_vec,
                               value_targets,
                               ai_mask=torch.zeros(N, dtype=torch.bool),
                               human_mask=torch.zeros(N, dtype=torch.bool))
    H.check(torch.isfinite(total_e).item(), "ppo_loss empty masks finite")
    H.check(np.isfinite(st_e["pg_loss"]) and np.isfinite(st_e["bc"]),
            "ppo_loss empty masks stats finite")
