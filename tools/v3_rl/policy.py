"""Torch policy/value heads on top of the REAL V3 frozen features.

Design (chosen to be auditable and safe):
  * We reuse the actual V3 `output_head` submodules. The policy distribution is
    exactly the V3 vertical/horizontal classification heads:
        h       = output_head.trunk(state_token)      # frozen trunk (dropout off)
        v_logits = output_head.vertical(h)            # TRAINABLE
        h_logits = output_head.horizontal(h)          # TRAINABLE
  * Only `output_head.vertical`, `output_head.horizontal` and a new `value_head`
    receive gradients. The backbone, trunk, and ALL safety heads (handbrake,
    brake, confidence, risk) stay byte-identical -> we can assert this in tests.
  * This is fine-tuning of the two decision heads on genuine V3 state tokens; it
    is NOT a from-scratch toy policy, and there is no current-action leak.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

NUM_V = 3
NUM_H = 3


class TorchPolicy(nn.Module):
    """Wraps a (frozen) V3 model and trains only vertical/horizontal + value."""

    def __init__(self, v3_model: nn.Module, state_dim: int = 256,
                 value_hidden: int = 128):
        super().__init__()
        self.v3 = v3_model
        # freeze everything
        for p in self.v3.parameters():
            p.requires_grad_(False)
        # unfreeze ONLY the two decision heads
        for p in self.v3.output_head.vertical.parameters():
            p.requires_grad_(True)
        for p in self.v3.output_head.horizontal.parameters():
            p.requires_grad_(True)
        self.value_head = nn.Sequential(
            nn.Linear(state_dim, value_hidden), nn.ReLU(inplace=True),
            nn.Linear(value_hidden, 1))
        # value head starts at 0 output
        nn.init.zeros_(self.value_head[-1].weight)
        nn.init.zeros_(self.value_head[-1].bias)

    def trainable_parameters(self):
        return [p for p in self.parameters() if p.requires_grad]

    def forward(self, state_token: torch.Tensor):
        h = self.v3.output_head.trunk(state_token)
        v_logits = self.v3.output_head.vertical(h)
        h_logits = self.v3.output_head.horizontal(h)
        value = self.value_head(state_token).squeeze(-1)
        return v_logits, h_logits, value

    @torch.no_grad()
    def probs(self, state_token: torch.Tensor):
        self.eval()
        v_logits, h_logits, value = self.forward(state_token)
        return (F.softmax(v_logits, -1), F.softmax(h_logits, -1), value)

    # -- head weight checkpointing (only the small trainable tensors) --------
    def head_state_dict(self) -> Dict[str, torch.Tensor]:
        sd = {}
        for name, p in self.v3.output_head.vertical.named_parameters():
            sd[f"vertical.{name}"] = p.detach().cpu().clone()
        for name, p in self.v3.output_head.horizontal.named_parameters():
            sd[f"horizontal.{name}"] = p.detach().cpu().clone()
        for name, p in self.value_head.named_parameters():
            sd[f"value.{name}"] = p.detach().cpu().clone()
        return sd

    def load_head_state_dict(self, sd: Dict[str, torch.Tensor]) -> None:
        with torch.no_grad():
            self.v3.output_head.vertical.weight.copy_(sd["vertical.weight"])
            self.v3.output_head.vertical.bias.copy_(sd["vertical.bias"])
            self.v3.output_head.horizontal.weight.copy_(sd["horizontal.weight"])
            self.v3.output_head.horizontal.bias.copy_(sd["horizontal.bias"])
            self.value_head[0].weight.copy_(sd["value.0.weight"])
            self.value_head[0].bias.copy_(sd["value.0.bias"])
            self.value_head[2].weight.copy_(sd["value.2.weight"])
            self.value_head[2].bias.copy_(sd["value.2.bias"])


def _masked_mean(x: torch.Tensor, mask: torch.Tensor, eps: float = 1e-8) -> torch.Tensor:
    m = mask.float()
    return (x * m).sum() / (m.sum() + eps)


def bc_loss(policy: TorchPolicy, state_token: torch.Tensor,
            v_action: torch.Tensor, h_action: torch.Tensor,
            frame_mask: Optional[torch.Tensor] = None) -> torch.Tensor:
    """Cross-entropy imitation on the vertical/horizontal heads (masked)."""
    v_logits, h_logits, _ = policy(state_token)
    ce_v = F.cross_entropy(v_logits, v_action, reduction="none")
    ce_h = F.cross_entropy(h_logits, h_action, reduction="none")
    ce = ce_v + ce_h
    if frame_mask is None:
        return ce.mean()
    return _masked_mean(ce, frame_mask)


def ppo_loss(
    policy: TorchPolicy,
    state_token: torch.Tensor,
    v_action: torch.Tensor,
    h_action: torch.Tensor,
    old_v_prob: torch.Tensor,
    old_h_prob: torch.Tensor,
    advantages: torch.Tensor,
    value_targets: torch.Tensor,
    ai_mask: torch.Tensor,
    human_mask: torch.Tensor,
    clip_eps: float = 0.2,
    lambda_imitation: float = 0.0,
    vf_coef: float = 0.5,
    ent_coef: float = 0.0,
    value_mask: Optional[torch.Tensor] = None,
) -> Tuple[torch.Tensor, Dict[str, float]]:
    """PPO clipped surrogate (AI frames only) + value regression (all) + imitation
    (human frames only). Human rescue actions are NEVER under the policy-gradient
    term, so takeover penalties never push down human actions.
    """
    v_logits, h_logits, value = policy(state_token)
    v_prob = F.softmax(v_logits, -1)
    h_prob = F.softmax(h_logits, -1)
    ar = torch.arange(state_token.shape[0])
    cur_va = v_prob[ar, v_action].clamp(1e-8, 1.0)
    cur_ha = h_prob[ar, h_action].clamp(1e-8, 1.0)
    old_va = old_v_prob[ar, v_action].clamp(1e-8, 1.0)
    old_ha = old_h_prob[ar, h_action].clamp(1e-8, 1.0)
    ratio = (cur_va / old_va) * (cur_ha / old_ha)

    surr1 = ratio * advantages
    surr2 = torch.clamp(ratio, 1.0 - clip_eps, 1.0 + clip_eps) * advantages
    pg_elem = -torch.min(surr1, surr2)
    pg_loss = _masked_mean(pg_elem, ai_mask)

    # Value regression: only on frames with a usable target (AI + HUMAN). UNKNOWN
    # frames have no reliable action/control, so they must not train the critic
    # (Codex round-3 ③). value_mask=None keeps the legacy "all frames" behaviour.
    if value_mask is None:
        v_loss = 0.5 * F.mse_loss(value, value_targets)
    else:
        v_loss = 0.5 * _masked_mean((value - value_targets) ** 2, value_mask)

    ent_v = -(v_prob * torch.log(v_prob + 1e-8)).sum(-1).mean()
    ent_h = -(h_prob * torch.log(h_prob + 1e-8)).sum(-1).mean()
    entropy = ent_v + ent_h

    bc = bc_loss(policy, state_token, v_action, h_action, frame_mask=human_mask)

    total = pg_loss + vf_coef * v_loss + lambda_imitation * bc - ent_coef * entropy
    stats = {
        "pg_loss": float(pg_loss.detach()), "v_loss": float(v_loss.detach()),
        "bc": float(bc.detach()), "entropy": float(entropy.detach()),
        "ratio_mean": float(ratio.detach().mean()),
    }
    return total, stats


def make_optimizer(policy: TorchPolicy, lr: float):
    return torch.optim.Adam(policy.trainable_parameters(), lr=lr)
