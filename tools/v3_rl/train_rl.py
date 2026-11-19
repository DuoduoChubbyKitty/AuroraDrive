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
  * No codrive.csv for a clip AND require_codrive=False -> the caller explicitly
    opted into "whole clip is a plain HUMAN demonstration".
  * No codrive.csv AND require_codrive=True -> hard error (a missing sidecar is
    ambiguous: it may be a co-drive session whose sidecar failed and was downgraded
    to plain recording). Never silently relabel a downgraded capture as human.
  * codrive.csv present -> per frame: source=AI -> AI; source=HUMAN -> HUMAN;
    frame absent from codrive -> UNKNOWN (excluded from PPO and imitation sets).

Known limitations (honest scope -- do NOT overclaim "faithful PPO"):
  * PPO "old probs" are the base checkpoint's softmax, not logged stochastic
    behaviour-policy probabilities (deployment acts argmax). Treat --stage ppo as
    an approximate OFFLINE fine-tune on recorded AI frames, not standard on-policy
    PPO (Codex round-2 #3).
  * The per-frame action label comes from controls.csv (the keys that were pressed).
    For frames the deployed driver produced, that equals the executed action; but
    the offline replay cannot perfectly reconstruct control overrides. Frames with
    no reliable action should use a separate "executed action" channel (not yet
    captured) -- see docs/v3-design/06 (Codex round-2 #2).
"""

from __future__ import annotations

import argparse
import csv
import logging
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

_log = logging.getLogger(__name__)


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


def _load_human_scores(path: Path) -> List[R.HumanEvent]:
    """Parse a clip's ``human_scores.csv`` (columns ``t,score``; t in seconds,
    score in [-1, 1]) into timestamped HumanEvents.

    The file is the only real source of human judgement; we never fabricate it.
    Rows with a non-numeric ``t`` or ``score`` are skipped and the row number is
    logged. Out-of-range scores are clamped later by reward.clamp_human_score.
    """
    events: List[R.HumanEvent] = []
    with open(path, newline="", encoding="utf-8") as f:
        for line_no, row in enumerate(csv.DictReader(f), start=2):
            try:
                t = float(str(row.get("t", "")).strip())
                score = float(str(row.get("score", "")).strip())
            except (TypeError, ValueError):
                _log.warning("[rl] %s 第 %d 行字段非法，已跳过: %r", path, line_no, row)
                continue
            if not (np.isfinite(t) and np.isfinite(score)):
                _log.warning("[rl] %s 第 %d 行非有限值，已跳过: %r", path, line_no, row)
                continue
            events.append(R.HumanEvent(t=t, score=score))
    return events


def build_clip_tensors(cache: "F.ClipCache", clip_path: Path,
                       weights: R.RewardWeights = R.DEFAULT_WEIGHTS,
                       human_score_path: Optional[Path] = None,
                       require_codrive: bool = False) -> ClipTensors:
    """Build per-frame tensors for one clip.

    ``human_score_path`` is optional and defaults to None, in which case the
    human term stays 0 exactly as before (no behaviour change). When the path
    exists, ``human_scores.csv`` (t, score) is parsed into HumanEvents and fed to
    ``compute_episode_rewards``; when it is absent a clear log states the human
    term is 0 (data is never invented).

    ``require_codrive`` controls the meaning of a *missing* ``codrive.csv``.
    Codrive is a per-frame annotation; a missing file is ambiguous (it can mean a
    pure expert demo, OR a co-drive session whose sidecar failed and was
    downgraded to plain recording). We must NOT silently treat every clip without
    codrive as a human demonstration, or a downgraded capture would be
    mislabelled as human. So:
      * require_codrive=True  -> a missing codrive.csv is a hard error for a
        co-drive training run; the caller must not pretend it is human data.
      * require_codrive=False -> the caller explicitly opted into "clip without
        codrive is a plain expert demonstration", so every frame is HUMAN.
    """
    n = cache.vertical.shape[0]
    co = _load_codrive(clip_path)
    is_ai = np.zeros(n, dtype=bool)
    is_human = np.zeros(n, dtype=bool)
    took_over = np.zeros(n, dtype=bool)
    collided = np.zeros(n, dtype=bool)
    lane_off = np.zeros(n, dtype=np.float64)
    if co is None:
        if require_codrive:
            raise FileNotFoundError(
                f"共驾训练缺少 codrive.csv: {Path(clip_path)} —— 可能是旁路录制失败后被"
                f"降级为普通录制，不能当作人类示范；请剔除该 clip 或改用普通示范模式。")
        # Explicitly opted into "no codrive == plain expert demonstration".
        is_human[:] = True
    else:
        # Look up codrive by the row's REAL frame id, not its compacted position.
        # The dataset skips frames, so position i != frame number; using i would
        # misalign source/took_over/collided/lane_offset (Codex round-2 #4).
        frame_ids = (np.asarray(cache.frame_ids, dtype=np.int64)
                     if getattr(cache, "frame_ids", None) is not None
                     else np.arange(n, dtype=np.int64))
        if frame_ids.shape[0] != n:
            raise ValueError(f"{cache.clip}: frame_ids 长度 {frame_ids.shape[0]} != 行数 {n}")
        for i in range(n):
            row = co.get(int(frame_ids[i]))
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

    # Per-episode rewards. Human scores come only from a real human_scores.csv;
    # with no events the human term is exactly 0 (never fabricated).
    human_events: List[R.HumanEvent] = []
    if human_score_path is not None and Path(human_score_path).exists():
        human_events = _load_human_scores(Path(human_score_path))
        if human_events:
            print(f"[rl] {cache.clip} 载入人工分 {len(human_events)} 条 ← {human_score_path}")
        else:
            print(f"[rl] {cache.clip} human_scores.csv 无可解析行，human 项为 0")
    else:
        print(f"[rl] {cache.clip} 无人工分，human 项为 0")
    frames = [R.FrameSignals(speed_kmh=float(cache.speed_kmh[i]),
                             speed_valid=bool(cache.speed_valid[i]),
                             lane_offset=float(lane_off[i]),
                             collided=bool(collided[i]),
                             took_over=bool(took_over[i])) for i in range(n)]
    rewards = R.compute_episode_rewards(frames, human_events, list(cache.frame_times),
                                        weights=weights)
    return ClipTensors(cache.clip, cache.state_token, cache.orig_vlogit,
                       cache.orig_hlogit, cache.vertical, cache.horizontal,
                       is_ai, is_human, took_over, rewards)


def assemble(cache_dir: Path, use_human_scores: bool = False,
             require_codrive: bool = False
             ) -> Tuple[List[ClipTensors], np.ndarray]:
    """Load caches + codrive -> list of ClipTensors and episode_ends array.

    When ``use_human_scores`` is True, each clip looks for
    ``<clip>/human_scores.csv`` next to its codrive and feeds it into the reward.
    Default False keeps reward identical to the no-human-score behaviour.
    ``require_codrive`` (see ``build_clip_tensors``) makes a missing codrive.csv
    a hard error instead of "whole clip is a human demo" -- use it for co-drive
    training so a downgraded capture is never silently labelled as human.
    """
    caches = F.load_cached_clips(cache_dir)
    if not caches:
        raise FileNotFoundError(f"{cache_dir} 下没有 clip_*.npz（先跑 features 抽取）")
    clips: List[ClipTensors] = []
    for c in caches:
        clip_path = Path(c.clip)
        human_score_path = (clip_path / "human_scores.csv") if use_human_scores else None
        clips.append(build_clip_tensors(c, clip_path, human_score_path=human_score_path,
                                        require_codrive=require_codrive))
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
    init_from: Optional[Path] = None,
    use_human_scores: bool = False,
    require_codrive: bool = False,
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

    clips, _ends = assemble(Path(cache_dir), use_human_scores=use_human_scores,
                            require_codrive=require_codrive)
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
    # UNKNOWN = neither AI nor HUMAN (no reliable action / V3 not in control).
    is_unknown = ~(is_ai | is_human)
    valid = is_ai | is_human
    # GAE must not propagate reward/bootstrap ACROSS an UNKNOWN segment (Codex round-3 ③).
    # Single source of truth lives in reward.compute_episode_ends (so tests bind to the
    # real logic, not a copy): it cuts at UNKNOWN frames AND at the last valid frame
    # before an UNKNOWN run (backward GAE would otherwise leak the unknown reward in).
    ends = R.compute_episode_ends(valid, clip_ends=ends)
    print(f"[rl] stage={stage} frames={n} ai={int(is_ai.sum())} human={int(is_human.sum())} "
          f"unknown={int(is_unknown.sum())} device={device}")

    # Real V3 model + trainable heads
    from tools.v3_rl.policy import (TorchPolicy, bc_loss, ppo_loss, make_optimizer)
    v3 = F.load_v3_model(Path(ckpt), str(device))
    policy = TorchPolicy(v3, state_dim=st.shape[1]).to(device)
    policy.v3.eval()  # backbone/trunk frozen; heads still get grads
    # BC -> PPO hand-off: load the head_state_dict saved by `--stage bc`.
    if init_from is not None:
        init_path = Path(init_from)
        if not init_path.exists():
            raise FileNotFoundError(f"--init-from 指定的头权重不存在: {init_path}")
        blob = torch.load(init_path, map_location=device, weights_only=True)
        head_sd = blob.get("head_state_dict") if isinstance(blob, dict) else None
        if not isinstance(head_sd, dict):
            raise ValueError(
                f"--init-from 文件缺少 head_state_dict（应由 --stage bc --out-ckpt 产出）: {init_path}")
        policy.load_head_state_dict(head_sd)
        print(f"[rl] 已从 {init_path} 载入 BC 头权重并继续 {stage}"
              f"（源自 stage={blob.get('stage')}）")
    opt = make_optimizer(policy, lr)

    ST = torch.tensor(st, dtype=torch.float32, device=device)
    OVL = torch.tensor(ovl, dtype=torch.float32, device=device)
    OHL = torch.tensor(ohl, dtype=torch.float32, device=device)
    Vl = torch.tensor(vlab, dtype=torch.long, device=device)
    Hl = torch.tensor(hlab, dtype=torch.long, device=device)
    AI = torch.tensor(is_ai, dtype=torch.bool, device=device)
    HU = torch.tensor(is_human, dtype=torch.bool, device=device)
    VALID = torch.tensor(is_ai | is_human, dtype=torch.bool, device=device)  # value-loss frames (exclude UNKNOWN)

    # Behaviour-policy probabilities (pi_0) for the PPO importance ratio.
    #
    # IMPORTANT LIMITATION (Codex round-2 #3): these are the ORIGINAL checkpoint's
    # softmax outputs on each frame -- NOT the probabilities of a logged stochastic
    # behaviour policy. The deployed driver acts argmax (deterministic) plus control
    # overrides, so it never sampled actions from this softmax. Consequently the
    # ratio pi_theta/pi_0 here only measures "how far the heads drifted from the
    # base model's softmax"; it is NOT a valid off-policy correction for standard
    # PPO. Treat `--stage ppo` as an approximate offline fine-tune over recorded AI
    # frames, not a theoretically-faithful on-policy PPO. For a faithful PPO you must
    # record (action, logprob, model/version, override flags) from a stochastic
    # behaviour policy at capture time; that capture plumbing does not exist yet.
    OLD_V = torch.softmax(OVL, -1)
    OLD_H = torch.softmax(OHL, -1)
    if stage == "ppo":
        _log.warning(
            "[rl] PPO 的 old_probs 取自原始 checkpoint 的 softmax，不是采集时的随机行为策略概率；"
            "视为离线近似微调，不是严格 on-policy PPO（详见代码注释 / 文档限制）。")

    # per-episode GAE
    with torch.no_grad():
        _, _, values = policy(ST)
    adv, vtarget = R.gae_advantages(rewards, values.detach().cpu().numpy(),
                                    episode_ends=ends, gamma=gamma, lam=lam)
    # PPO advantage normalisation must use ONLY the frames that actually enter the
    # policy gradient (AI frames). Normalising over all frames lets unrelated
    # HUMAN/UNKNOWN frames shift the mean/std -- adding human-demo clips could even
    # flip the sign of AI advantages. BC stage ignores advantages, so the global
    # path there is harmless.
    if stage == "ppo" and is_ai.any():
        normalized = np.zeros_like(adv, dtype=np.float32)
        normalized[is_ai] = R.normalize_advantages(adv[is_ai])
        adv = normalized
    else:
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
                    clip_eps=clip_eps, lambda_imitation=lam_now, value_mask=VALID[bi])
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
    ap.add_argument("--init-from", default=None,
                    help="BC 阶段产出的 head_state_dict .pt；PPO 载入后继续（BC→PPO 入口）")
    ap.add_argument("--use-human-scores", action="store_true",
                    help="读取每个 clip 目录下的 human_scores.csv（t,score）计入 human 项")
    ap.add_argument("--require-codrive", action="store_true",
                    help="共驾训练：缺少 codrive.csv 视为错误（不默认整段当人类示范），"
                         "防止旁路失败降级的数据被误当人类数据")
    return ap.parse_args(argv)


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    a = _parse_args(argv)
    train(cache_dir=Path(a.cache_dir), stage=a.stage, ckpt=Path(a.ckpt),
          device=a.device, epochs=a.epochs, lr=a.lr, batch_size=a.batch_size,
          lambda_imitation=a.lambda_imitation, lambda_decay=a.lambda_decay,
          clip_eps=a.clip_eps, gamma=a.gamma, lam=a.lam, seed=a.seed,
          out_ckpt=Path(a.out_ckpt) if a.out_ckpt else None, limit=a.limit,
          init_from=Path(a.init_from) if a.init_from else None,
          use_human_scores=a.use_human_scores, require_codrive=a.require_codrive)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
