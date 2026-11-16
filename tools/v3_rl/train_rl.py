"""Human-in-the-loop RL trainer for the real V3 model (BC warm-up + PPO).

Pipeline (all on genuine V3 features, no action leak):
  1. features.extract_all(...) caches per-clip state_token + original behaviour
     probabilities (the pre-RL model = behaviour policy pi_0).
  2. This module loads those caches + codrive.csv, splits frames into AI vs HUMAN,
     computes per-episode rewards (reward.py) and per-episode GAE (no cross-clip
     leak).
  3. Loads the REAL V3 model, wraps it in TorchPolicy (only the vertical/horizontal
     heads + a value head are trainable), and runs:
       --stage bc  : imitation on HUMAN frames only.
       --stage ppo : PPO on AI frames + imitation on HUMAN frames (lambda decays).
  4. Saves the trained head weights (vertical/horizontal/value) so the export /
     deploy pipeline can fold them back into the model.

Semantics for codrive.csv (fix for "missing row == human demo"):
  * No codrive.csv for a clip  -> whole clip is a HUMAN demonstration (all human).
  * codrive.csv present        -> per frame: source=AI -> AI; source=HUMAN -> HUMAN;
                                  frame absent from codrive -> UNKNOWN (excluded
                                  from both the PPO and imitation sets).
"""

from __future__ import annotations

import argparse
import csv
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

_ROOT = Path(__file__).resolve().parents[2]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from tools.v3_rl import features as F  # noqa: E402
from tools.v3_rl import reward as R  # noqa: E402


@dataclass
class ClipTensors:
    clip: str
    state_token: np.ndarray   # [N,256]
    orig_vlogit: np.ndarray   # [N,3]
    orig_hlogit: np.ndarray   # [N,3]
    vertical: np.ndarray      # [N] human label (the action actually taken)
    horizontal: np.ndarray
    is_ai: np.ndarray         # [N] bool
    is_human: np.ndarray      # [N] bool
    took_over: np.ndarray     # [N] bool
    rewards: np.ndarray       # [N]


def _bit(row: Dict[str, str], k: str) -> int:
    return 1 if str(row.get(k, "0")).strip() not in ("", "0", "False") else 0


def _load_codrive(clip_path: Path) -> Optional[Dict[int, Dict[str, str]]]:
    co = clip_path / "codrive.csv"
    if not co.exists():
        return None
    with open(co, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    out: Dict[int, Dict[str, str]] = {}
    for r in rows:
        try:
            fr = int(str(r.get("frame", "")).strip())
        except ValueError:
            continue
        out[fr] = r
    return out


def build_clip_tensors(cache: "F.ClipCache", clip_path: Path,
                       weights: R.RewardWeights = R.DEFAULT_WEIGHTS) -> ClipTensors:
    n = cache.vertical.shape[0]
    co = _load_codrive(clip_path)
    is_ai = np.zeros(n, dtype=bool)
    is_human = np.zeros(n, dtype=bool)
    took_over = np.zeros(n, dtype=bool)
    collided = np.zeros(n, dtype=bool)
    lane_off = np.zeros(n, dtype=np.float64)
    if co is None:
        # No codrive at all -> pure human demonstration.
        is_human[:] = True
    else:
        for i in range(n):
            row = co.get(i)
            if row is None:
                continue  # UNKNOWN frame: neither AI nor human
            src = str(row.get("source", "")).strip().upper()
            if src == "AI":
                is_ai[i] = True
            elif src == "HUMAN":
                is_human[i] = True
            took_over[i] = str(row.get("took_over", "0")).strip() not in ("", "0")
            collided[i] = str(row.get("collided", "0")).strip() not in ("", "0")
            lo = str(row.get("lane_offset", "")).strip()
            if lo not in ("", "None"):
                try:
                    lane_off[i] = float(lo)
                except ValueError:
                    lane_off[i] = 0.0

    # Per-episode rewards (no human score events supplied by CLI -> 0 human term;
    # the reward still uses speed/stuck/collision/decel/lane + takeover).
    frames = [R.FrameSignals(speed_kmh=float(cache.speed_kmh[i]),
                             speed_valid=bool(cache.speed_valid[i]),
                             lane_offset=float(lane_off[i]),
                             collided=bool(collided[i]),
                             took_over=bool(took_over[i])) for i in range(n)]
    rewards = R.compute_episode_rewards(frames, [], list(cache.frame_times),
                                        weights=weights)
    return ClipTensors(cache.clip, cache.state_token, cache.orig_vlogit,
                       cache.orig_hlogit, cache.vertical, cache.horizontal,
                       is_ai, is_human, took_over, rewards)


def assemble(cache_dir: Path) -> Tuple[List[ClipTensors], np.ndarray]:
    """Load caches + codrive -> list of ClipTensors and episode_ends array."""
    caches = F.load_cached_clips(cache_dir)
    if not caches:
        raise FileNotFoundError(f"{cache_dir} 下没有 clip_*.npz（先跑 features 抽取）")
    clips: List[ClipTensors] = []
    for c in caches:
        clip_path = Path(c.clip)
        clips.append(build_clip_tensors(c, clip_path))
    ends = []
    for c in clips:
        e = np.zeros(c.state_token.shape[0], dtype=bool)
        if e.shape[0]:
            e[-1] = True
        ends.append(e)
    return clips, np.concatenate(ends)


def _torch():
    import torch
    return torch


def train(
    cache_dir: Path,
    stage: str,
    ckpt: Path,
    device: str = "auto",
    epochs: int = 5,
    lr: float = 7e-4,
    batch_size: int = 256,
    lambda_imitation: float = 0.5,
    lambda_decay: float = 0.7,
    clip_eps: float = 0.2,
    gamma: float = 0.99,
    lam: float = 0.95,
    seed: int = 42,
    out_ckpt: Optional[Path] = None,
    limit: Optional[int] = None,
) -> Dict[str, object]:
    torch = _torch()
    if batch_size <= 0:
        raise ValueError("batch_size 必须 > 0")
    if epochs < 0:
        raise ValueError("epochs 不能为负")
    torch.manual_seed(seed)
    np.random.seed(seed)
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    device = torch.device(device)

    clips, _ends = assemble(Path(cache_dir))
    # concatenate with episode_ends
    st = np.concatenate([c.state_token for c in clips], 0)
    ovl = np.concatenate([c.orig_vlogit for c in clips], 0)
    ohl = np.concatenate([c.orig_hlogit for c in clips], 0)
    vlab = np.concatenate([c.vertical for c in clips], 0)
    hlab = np.concatenate([c.horizontal for c in clips], 0)
    is_ai = np.concatenate([c.is_ai for c in clips], 0)
    is_human = np.concatenate([c.is_human for c in clips], 0)
    rewards = np.concatenate([c.rewards for c in clips], 0)
    ends = np.zeros(st.shape[0], dtype=bool)
    off = 0
    for c in clips:
        n = c.state_token.shape[0]
        if n:
            ends[off + n - 1] = True
        off += n
    if limit is not None:
        st, ovl, ohl, vlab, hlab = st[:limit], ovl[:limit], ohl[:limit], vlab[:limit], hlab[:limit]
        is_ai, is_human, rewards, ends = is_ai[:limit], is_human[:limit], rewards[:limit], ends[:limit]
        if len(ends):
            ends[-1] = True
    n = st.shape[0]
    if n == 0:
        raise ValueError("无可用帧")
    print(f"[rl] stage={stage} frames={n} ai={int(is_ai.sum())} human={int(is_human.sum())} "
          f"unknown={int((~is_ai & ~is_human).sum())} device={device}")

    # Real V3 model + trainable heads
    from tools.v3_rl.policy import (TorchPolicy, bc_loss, ppo_loss, make_optimizer)
    v3 = F.load_v3_model(Path(ckpt), str(device))
    policy = TorchPolicy(v3, state_dim=st.shape[1]).to(device)
    policy.v3.eval()  # backbone/trunk frozen; heads still get grads
    opt = make_optimizer(policy, lr)

    ST = torch.tensor(st, dtype=torch.float32, device=device)
    OVL = torch.tensor(ovl, dtype=torch.float32, device=device)
    OHL = torch.tensor(ohl, dtype=torch.float32, device=device)
    Vl = torch.tensor(vlab, dtype=torch.long, device=device)
    Hl = torch.tensor(hlab, dtype=torch.long, device=device)
    AI = torch.tensor(is_ai, dtype=torch.bool, device=device)
    HU = torch.tensor(is_human, dtype=torch.bool, device=device)

    # behaviour-policy probabilities (pi_0) for PPO importance ratio
    OLD_V = torch.softmax(OVL, -1)
    OLD_H = torch.softmax(OHL, -1)

    # per-episode GAE
    with torch.no_grad():
        _, _, values = policy(ST)
    adv, vtarget = R.gae_advantages(rewards, values.detach().cpu().numpy(),
                                    episode_ends=ends, gamma=gamma, lam=lam)
    adv = R.normalize_advantages(adv)
    ADV = torch.tensor(adv, dtype=torch.float32, device=device)
    VT = torch.tensor(vtarget, dtype=torch.float32, device=device)

    hist: List[Dict[str, float]] = []
    lam_now = float(lambda_imitation)
    idx_all = np.arange(n)
    for ep in range(epochs):
        np.random.shuffle(idx_all)
        stats_acc: Dict[str, List[float]] = {}
        for start in range(0, n, batch_size):
            bidx = idx_all[start:start + batch_size]
            bi = torch.tensor(bidx, dtype=torch.long, device=device)
            if stage == "bc":
                # imitation on human frames only
                mask = HU[bi]
                if not mask.any():
                    continue
                loss = bc_loss(policy, ST[bi], Vl[bi], Hl[bi], frame_mask=mask)
                st_dict = {"bc": float(loss.detach())}
            elif stage == "ppo":
                loss, st_dict = ppo_loss(
                    policy, ST[bi], Vl[bi], Hl[bi], OLD_V[bi], OLD_H[bi],
                    ADV[bi], VT[bi], ai_mask=AI[bi], human_mask=HU[bi],
                    clip_eps=clip_eps, lambda_imitation=lam_now)
            else:
                raise ValueError(f"未知 stage: {stage}")
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(policy.trainable_parameters(), 1.0)
            opt.step()
            for k, v in st_dict.items():
                stats_acc.setdefault(k, []).append(v)
        row = {"epoch": ep}
        for k, vs in stats_acc.items():
            row[k] = float(np.mean(vs)) if vs else float("nan")
        row["lambda_imitation"] = lam_now
        hist.append(row)
        print(f"[rl][{stage}] ep{ep} " +
              " ".join(f"{k}={v:.4f}" for k, v in row.items() if k != "epoch"))
        if stage == "ppo":
            lam_now *= lambda_decay

    head_sd = policy.head_state_dict()
    if out_ckpt is not None:
        out_ckpt = Path(out_ckpt)
        out_ckpt.parent.mkdir(parents=True, exist_ok=True)
        torch.save({"head_state_dict": head_sd, "stage": stage,
                    "frames": n, "history": hist}, out_ckpt)
        print(f"[rl] 已保存头权重 → {out_ckpt}")
    return {"stage": stage, "frames": n, "history": hist,
            "head_state_dict": head_sd}


def _parse_args(argv=None):
    ap = argparse.ArgumentParser(description="V3 人机共驾 RL 训练（真模型 BC/PPO）")
    ap.add_argument("--cache-dir", required=True, help="features.extract_all 产出的缓存目录")
    ap.add_argument("--ckpt", required=True, help="V3 checkpoint（真加载，冻结主干）")
    ap.add_argument("--stage", required=True, choices=["bc", "ppo"])
    ap.add_argument("--device", default="auto")
    ap.add_argument("--epochs", type=int, default=5)
    ap.add_argument("--lr", type=float, default=7e-4)
    ap.add_argument("--batch-size", type=int, default=256)
    ap.add_argument("--lambda-imitation", type=float, default=0.5)
    ap.add_argument("--lambda-decay", type=float, default=0.7)
    ap.add_argument("--clip-eps", type=float, default=0.2)
    ap.add_argument("--gamma", type=float, default=0.99)
    ap.add_argument("--lam", type=float, default=0.95)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out-ckpt", default=None)
    ap.add_argument("--limit", type=int, default=None)
    return ap.parse_args(argv)


def main(argv=None) -> int:
    a = _parse_args(argv)
    train(cache_dir=Path(a.cache_dir), stage=a.stage, ckpt=Path(a.ckpt),
          device=a.device, epochs=a.epochs, lr=a.lr, batch_size=a.batch_size,
          lambda_imitation=a.lambda_imitation, lambda_decay=a.lambda_decay,
          clip_eps=a.clip_eps, gamma=a.gamma, lam=a.lam, seed=a.seed,
          out_ckpt=Path(a.out_ckpt) if a.out_ckpt else None, limit=a.limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
