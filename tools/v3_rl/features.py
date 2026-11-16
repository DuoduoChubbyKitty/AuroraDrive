"""Extract REAL V3 features for RL: frozen-backbone state_token + behaviour probs.

This is the honest bridge between the recording data and the training loop:

  * We load the actual trained V3 checkpoint (real weights, strict=True).
  * We freeze the visual backbone and run each recorded frame through V3 to obtain
    the stage-2 `state_token` [256] -- the exact input the real V3 output head
    consumes. These are the features the policy/value heads are trained on. This
    means training operates on genuine V3 representations, not hand-built
    kinematics, and there is NO leak of the current action into the input
    (state_token is derived from images + lane + dets + t-1 vehicle_state only).
  * We also store the ORIGINAL model's vertical/horizontal probabilities on each
    frame. Those are the behaviour-policy probabilities pi_0(a|s) that generated
    the recorded actions, so PPO's importance ratio pi_theta/pi_0 is meaningful
    (off-policy correction relative to the pre-RL model).

Output: one .npz per clip under the cache dir + a manifest.json.
"""

from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import numpy as np


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_v3_model(ckpt: Path, device: str):
    """Load the REAL V3 model (strict) on `device`, frozen, eval mode."""
    root = _repo_root()
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    exp = root / "tools" / "v3_exp"
    if str(exp) not in sys.path:
        sys.path.insert(0, str(exp))
    import torch
    import export_v3_checkpoint_int4 as E
    model, _cfg = E.load_trained_model(Path(ckpt))
    model = model.to(device).eval()
    for p in model.parameters():
        p.requires_grad_(False)
    return model


def _frame_times(controls_path: Path, frame_ids: Optional[np.ndarray] = None) -> np.ndarray:
    """Read real ``t_sec`` for each frame, indexed by the frame's REAL frame number.

    The dataset skips windows broken by a missing frame, so the cached rows are NOT
    guaranteed contiguous in frame number. We must therefore look up each row's
    time by its true frame id (``frame_ids``), not by its compacted position ``i``
    -- otherwise a dropped frame shifts every later timestamp and corrupts codrive
    / human-score alignment (Codex round-2 #4).

    Falls back to ``i/15`` ONLY when controls.csv is unavailable/short; a real
    lookup that runs past the table is an error (no silent fake timestamps).
    """
    import csv
    if frame_ids is None:
        frame_ids = np.arange(0, dtype=np.int64)
    frame_ids = np.asarray(frame_ids, dtype=np.int64)
    try:
        with open(controls_path, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        if rows:
            t_all = np.array([float(r.get("t_sec", i / 15.0)) for i, r in enumerate(rows)],
                             dtype=np.float64)
            if frame_ids.size and int(frame_ids.max()) < t_all.shape[0] and int(frame_ids.min()) >= 0:
                return t_all[frame_ids]
            if frame_ids.size:
                raise IndexError(
                    f"{controls_path} 只有 {t_all.shape[0]} 行，但帧号最大 {int(frame_ids.max())}，"
                    f"帧号越界——拒绝伪造时间戳")
    except (FileNotFoundError, KeyError, TypeError, ValueError, IndexError) as exc:
        # Missing/short controls: fall back to nominal 15Hz, but surface it loudly.
        import sys as _sys
        print(f"[feat][warn] {controls_path} 无法按真实帧号取 t_sec：{exc}；回退 i/15", file=_sys.stderr)
    return frame_ids.astype(np.float64) / 15.0


@dataclass
class ClipCache:
    state_token: np.ndarray     # [N,256]
    orig_vlogit: np.ndarray     # [N,3]
    orig_hlogit: np.ndarray     # [N,3]
    vertical: np.ndarray        # [N] human label
    horizontal: np.ndarray      # [N] human label
    speed_kmh: np.ndarray       # [N]
    speed_valid: np.ndarray     # [N] bool
    frame_times: np.ndarray     # [N]
    clip: str
    frame_ids: Optional[np.ndarray] = None   # [N] real frame numbers

    def _frame_ids(self) -> np.ndarray:
        if self.frame_ids is None:
            return np.arange(self.vertical.shape[0], dtype=np.int64)
        return np.asarray(self.frame_ids, dtype=np.int64)

    def save(self, path: Path) -> None:
        np.savez_compressed(path,
                            state_token=self.state_token,
                            orig_vlogit=self.orig_vlogit,
                            orig_hlogit=self.orig_hlogit,
                            vertical=self.vertical,
                            horizontal=self.horizontal,
                            speed_kmh=self.speed_kmh,
                            speed_valid=self.speed_valid,
                            frame_times=self.frame_times,
                            frame_ids=self._frame_ids(),
                            clip=self.clip)

    @classmethod
    def load(cls, path: Path) -> "ClipCache":
        d = np.load(path, allow_pickle=False)
        frame_ids = d["frame_ids"] if "frame_ids" in d.files else None
        return cls(
            state_token=d["state_token"], orig_vlogit=d["orig_vlogit"],
            orig_hlogit=d["orig_hlogit"], vertical=d["vertical"],
            horizontal=d["horizontal"], speed_kmh=d["speed_kmh"],
            speed_valid=d["speed_valid"], frame_times=d["frame_times"],
            clip=str(d["clip"]), frame_ids=frame_ids,
        )


def extract_clip(model, ds, global_indices: List[int], clip_name: str,
                 device: str, batch_size: int = 32) -> ClipCache:
    """Run one clip's frames through frozen V3 -> state_token + behaviour probs.

    Also records each row's REAL frame number (``ds.index[gi][1]``) so downstream
    codrive / human-score lookups by frame are exact even when the dataset skipped
    frames (Codex round-2 #4).
    """
    import torch
    from torch.utils.data import DataLoader, Subset

    sub = Subset(ds, global_indices)
    loader = DataLoader(sub, batch_size=batch_size, num_workers=0)
    sts, ovl, ohl, vs, hs, sps, svs = [], [], [], [], [], [], []
    # Real frame ids, in the SAME order the loader yields the subset.
    frame_ids = np.array([int(ds.index[gi][1]) for gi in global_indices], dtype=np.int64)
    with torch.no_grad():
        for b in loader:
            inp = {k: b[k].float().to(device)
                   for k in ("image_hi", "image_lo", "lane", "dets",
                             "det_mask", "vehicle_state")}
            out = model(**inp, return_state_token=True)
            sts.append(out["state_token"].float().cpu().numpy())
            ovl.append(out["vertical"].float().cpu().numpy())
            ohl.append(out["horizontal"].float().cpu().numpy())
            vs.append(b["vertical"].long().numpy())
            hs.append(b["horizontal"].long().numpy())
            sps.append(b["speed_kmh"].float().numpy().reshape(-1))
            svs.append((b["speed_valid"].float().numpy().reshape(-1) >= 0.5))
    st_all = np.concatenate(sts, 0)
    if st_all.shape[0] != frame_ids.shape[0]:
        raise RuntimeError(
            f"{clip_name}: 抽取得到 {st_all.shape[0]} 行但记录到 {frame_ids.shape[0]} 个帧号，数量不一致")
    controls = Path(clip_name) / "controls.csv"
    frame_times = _frame_times(controls, frame_ids)
    return ClipCache(
        state_token=st_all,
        orig_vlogit=np.concatenate(ovl, 0),
        orig_hlogit=np.concatenate(ohl, 0),
        vertical=np.concatenate(vs, 0),
        horizontal=np.concatenate(hs, 0),
        speed_kmh=np.concatenate(sps, 0),
        speed_valid=np.concatenate(svs, 0),
        frame_times=frame_times,
        clip=str(clip_name),
        frame_ids=frame_ids,
    )


def extract_all(clips_dir: Path, ckpt: Path, cache_dir: Path, device: str = "auto",
                batch_size: int = 32, limit_per_clip: Optional[int] = None,
                max_total: Optional[int] = None) -> Dict[str, object]:
    """Extract and cache features for every clip in `clips_dir`.

    Returns a manifest dict. Reuses existing cached clips (skips re-extraction).
    """
    import torch
    from src.dataset_v3 import V3KeyDataset

    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    cache_dir = Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    ds = V3KeyDataset(str(clips_dir), skip_all_zero=False, augment=False,
                      decode_workers=4)
    # group global indices by clip
    by_clip: Dict[str, List[int]] = {}
    order: List[str] = []
    for gi, (clip, _frame) in enumerate(ds.index):
        key = str(clip)
        if key not in by_clip:
            by_clip[key] = []
            order.append(key)
        by_clip[key].append(gi)

    model = load_v3_model(Path(ckpt), device)
    manifest = {"clips": [], "device": device}
    total = 0
    t0 = time.time()
    for key in order:
        name = Path(key).name
        out_npz = cache_dir / f"{name}.npz"
        idx = by_clip[key]
        if limit_per_clip is not None:
            idx = idx[:limit_per_clip]
        if max_total is not None:
            remain = max_total - total
            if remain <= 0:
                break
            idx = idx[:remain]
        if out_npz.exists():
            n = int(np.load(out_npz)["vertical"].shape[0])
            manifest["clips"].append({"clip": name, "frames": n, "cached": True})
            total += n
            continue
        cache = extract_clip(model, ds, idx, key, device, batch_size)
        cache.save(out_npz)
        n = cache.vertical.shape[0]
        manifest["clips"].append({"clip": name, "frames": n, "cached": False})
        total += n
        print(f"[feat] {name}: {n} 帧  累计 {total}  用时 {time.time()-t0:.0f}s")
    manifest["total_frames"] = total
    (cache_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


def load_cached_clips(cache_dir: Path) -> List[ClipCache]:
    cache_dir = Path(cache_dir)
    out: List[ClipCache] = []
    for npz in sorted(cache_dir.glob("clip_*.npz")):
        out.append(ClipCache.load(npz))
    return out
