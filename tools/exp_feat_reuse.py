#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_feat_reuse.py —— S5「特征复用流水线」实验脚本（性能攻坚）

================================================================================
0. 要解决的问题
================================================================================
主驾驶模型 V2 当前部署形态：`image` 输入 = [8,3,180,320]（8 帧时序窗口），
模型内部对这 8 帧**各跑一遍完整 ImageEncoder** → 8×256 特征 → GRU → 融合
→ 12 步 refiner → 6 输出。

实测（Lead / t1，真机 M3）：
    · 1 帧 + palette INT8  → ANE  2.23 ms  ✅
    · 8 帧 + palette INT8  → ANE 编译失败 → CPU 16.16 ms  🔴
    · **8 帧时序窗口是 ANE 失败根因**（t1 四格对照定案）

硬红线：不降步数(12)、不降 MoE(4步)、不降帧率、不降分辨率、不降质量。

================================================================================
1. ★ 本实验的核心洞察（已实测坐实，见 --stage equiv）
================================================================================
**`ImageEncoder` 是逐帧独立的纯函数**：无跨帧状态、无 BN 跨样本统计（eval 态）、
无 batch 间交互。实测：

    enc(imgs[0:8])  ==  cat([enc(imgs[i:i+1]) for i in range(8)])   逐位相同 (maxdiff = 0.0)
    乱序逐帧调用                                                       逐位相同 (maxdiff = 0.0)

⟹ **每帧的特征可以被缓存并复用，且数学上严格无损**（不是近似，是逐位相等）。
   代价从「每帧 8 次编码」降到「每帧 1 次编码」。

这与「降帧率 / 降分辨率 / 降质量」有本质区别：
    · 降帧率 = 改变模型看到的输入序列
    · 特征复用 = **不改变任何一帧的编码结果**，只是不再重复计算同一个值

================================================================================
2. 两条候选流水线（本脚本实测对比）
================================================================================
【F1 · 双模型：特征提取器 + 主控】
    Swift 侧维护 8 帧特征环形缓冲（滑窗）。
      · 模型 A（特征提取器）：image[1,3,180,320] → feat[1,256]      ← 纯单帧卷积
      · 模型 B（主控）：feats[8,256] + lane + dets + det_mask + vehicle_state → 6 输出
    每帧只需：A 跑 1 次（新帧）+ B 跑 1 次。
    B 图内**没有任何卷积主干** → 绕开「8 帧卷积」这个 ANE 失败根因。

【F2 · 单模型：1 帧图 + 7 帧缓存特征】
    image[1,3,180,320] + hist_feats[7,256] + lane + dets + det_mask + vehicle_state → 6 输出
    模型内部：enc(image) → [1,256]，与 hist_feats 拼成 [8,256] → 原时序路径。
    图内只有 **1 帧**卷积（而非 8 帧）。
    部署更简单（单模型、单次调用），但卷积仍在图内。

两条路线的数值路径与完整 8 帧模型**逐位等价**（前提：hist_feats 由同一模型产出）。

【对照 · 证伪项】
    · 光流 warp 复用（用 warp 代替重新编码）—— 预期不满足 <1e-3，本脚本量化其误差
    · 早期帧降精度（fp16/int8 量化历史帧特征）—— 在**非零时序权重**下测真实影响

================================================================================
3. 测量纪律
================================================================================
    · ABBA 交替（ANE, CPU, CPU, ANE 取中位）抵消本机负载漂移
    · 每档 5 次 warmup + 30 次计时
    · ANE 是否生效：ratio = ANE/CPU < 0.85 → 生效（与 t1 口径一致）；
      并用 Swift `MLComputePlan` 取**直接证据**（见 --stage plan）
    · 无损性判据：maxdiff < 1e-3（与「每帧完整编码」对比）
    · 量化误差与复用误差**分离报告**（单变量对照）

================================================================================
4. 用法
================================================================================
    ./.venv-yolo26/bin/python3 tools/exp_feat_reuse.py --stage equiv
    ./.venv-yolo26/bin/python3 tools/exp_feat_reuse.py --stage ane  --models f1a,f1b,f2,base8
    ./.venv-yolo26/bin/python3 tools/exp_feat_reuse.py --stage all

产物落 `models/exp_reuse_*`（写作用域内），不触碰 `src/model_v2.py` / `Sources/`。
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import tempfile
import time
import warnings
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import torch  # noqa: E402
import torch.nn as nn  # noqa: E402
import coremltools as ct  # noqa: E402
import coremltools.optimize.coreml as cto  # noqa: E402
import src.model_v2 as mv  # noqa: E402

warnings.simplefilter("ignore")

CKPT_DEFAULT = "checkpoints/m9_v2/best_model.pt"
IMG_SHAPE = (3, 180, 320)
FEAT_DIM = 256
FRAMES = 8
HIST = FRAMES - 1            # 7 帧缓存特征

#: 无损性判据（与任务书一致）
TOL_MAXDIFF = 1e-3
#: ANE 生效判据（与 t1 四格对照同口径）
ANE_RATIO_OK = 0.85


# ============================================================================
# 1. 模型加载
# ============================================================================

def load_state_dict(src: str) -> Dict[str, torch.Tensor]:
    """读 checkpoint，剥离 torch.compile 前缀与训练期探针（与导出脚本同款）。"""
    ck = torch.load(src, map_location="cpu", weights_only=False)
    sd = ck["model_state_dict"] if isinstance(ck, dict) and "model_state_dict" in ck else ck
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    for k in [k for k in sd if k.startswith("lane_steer_probe.")]:
        del sd[k]
    return sd


def build_loaded(src: Optional[str], steps: int = 12, seed: int = 0):
    """训练态构建 → load → reparameterize（唯一正确顺序，见 model_v2.reparameterize 文档）。"""
    torch.manual_seed(seed)
    m = mv.build_model(deploy=False, num_steps=steps)
    report = {"missing": 0, "unexpected": 0, "random_init": True}
    if src and Path(src).exists():
        sd = load_state_dict(src)
        missing, unexpected = m.load_state_dict(sd, strict=False)
        report = {"missing": len(missing), "unexpected": len(unexpected),
                  "random_init": False,
                  "missing_sample": missing[:6]}
    m.eval()
    m.reparameterize()
    return m, report


def make_feed(frames: int = FRAMES, seed: int = 42, batch_lane: bool = True):
    """构造一组固定输入（固定 seed → 可复现对拍）。"""
    g = lambda s: torch.Generator().manual_seed(s)
    imgs = torch.rand(frames, *IMG_SHAPE, generator=g(seed))
    lane = (torch.rand(1, 1, 160, 160, generator=g(seed + 1)) > 0.985).float()
    dets = torch.rand(1, 20, 12, generator=g(seed + 2))
    dmask = (torch.rand(1, 20, generator=g(seed + 3)) > 0.35).float()
    vs = torch.rand(1, 8, generator=g(seed + 4)) * 2 - 1
    return {"image": imgs, "lane": lane, "dets": dets, "det_mask": dmask,
            "vehicle_state": vs}


# ============================================================================
# 2. 复用核心：逐字复刻 M2Model.forward 的 seq_mode 路径
# ============================================================================

def _flatten6(out6) -> Tuple[torch.Tensor, ...]:
    """把 (steer, throttle, brake, confidence, risk, car_heading) 里的 None 换成零张量。

    与 tools/export_m9_v2_coreml.py::_ExportWrapper 同款处理：
    CoreML 的 6 输出契约必须恒定，None 用零占位。
    """
    steer = out6[0]
    vals = []
    for v in out6:
        if v is None:
            vals.append(torch.zeros(1, 1, dtype=steer.dtype, device=steer.device))
        elif v.dim() == 1:
            vals.append(v.view(-1, 1))
        else:
            vals.append(v)
    return tuple(vals)


class ReuseCore(nn.Module):
    """从 **8 帧特征** + 辅助输入 → 6 输出。

    ⚠️ 逐字复刻 `M2Model.forward` 的 seq_mode 分支（src/model_v2.py:1442-1511），
       本类**不改动** src/model_v2.py 一行；等价性由 `--stage equiv` 逐位验证。
    """

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, feats, lane, dets, det_mask, vehicle_state):
        m = self.model
        # ---- 时序聚合（与 model_v2 seq_mode 逐字一致）----
        current_img_feat = feats[-1:]                                # [1,256]
        temporal_feat = m.temporal_encoder(feats.unsqueeze(0), None)  # [1,128]
        projected = m.temporal_proj(temporal_feat)                   # [1,256]
        img_feat = current_img_feat + projected                      # [1,256]

        # ---- 其余三分支（batch=1）----
        lane_feat = m.lane_encoder(lane, 1, feats)
        det_feat = m.det_encoder(dets, det_mask, 1, feats)
        state_feat = m.state_encoder(vehicle_state, 1, feats)

        # ---- 融合 + 迭代精修 ----
        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)  # [1,512]
        if m.refiner is not None:
            fused = m.refiner(fused)
        steer, throttle, brake = m.fusion_head(fused)

        # ---- 辅助头（与 model_v2 同序、同 fail-safe）----
        car_heading = None
        if m.heading_head is not None:
            try:
                car_heading = m.heading_head(img_feat, None)
            except Exception:
                car_heading = None
        confidence = risk = None
        if m.risk_head is not None:
            try:
                confidence, risk = m.risk_head(
                    fused, det_feat=det_feat, det_mask=det_mask,
                    speed=(vehicle_state[:, 0] if vehicle_state is not None
                           and vehicle_state.dim() == 2 and vehicle_state.shape[1] > 0
                           else None))
            except Exception:
                confidence = risk = None
        return steer, throttle, brake, confidence, risk, car_heading


class F1A(nn.Module):
    """F1 模型 A：单帧图像 → 256 维特征（特征提取器）。"""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image):
        return self.model.image_encoder(image)


class F1B(nn.Module):
    """F1 模型 B：8 帧缓存特征 + 辅助输入 → 6 输出（主控，无卷积主干）。"""

    def __init__(self, model):
        super().__init__()
        self.core = ReuseCore(model)

    def forward(self, feats, lane, dets, det_mask, vehicle_state):
        return _flatten6(self.core(feats, lane, dets, det_mask, vehicle_state))


class F2(nn.Module):
    """F2：1 帧图 + 7 帧缓存特征 + 辅助输入 → 6 输出（单模型）。"""

    def __init__(self, model):
        super().__init__()
        self.model = model
        self.core = ReuseCore(model)

    def forward(self, image, hist_feats, lane, dets, det_mask, vehicle_state):
        cur = self.model.image_encoder(image)                 # [1,256]
        feats = torch.cat([hist_feats, cur], dim=0)           # [8,256]
        return _flatten6(self.core(feats, lane, dets, det_mask, vehicle_state))


class Base8(nn.Module):
    """基线：完整 8 帧模型（6 输出摊平，与导出脚本同款）。"""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image, lane, dets, det_mask, vehicle_state):
        steer, throttle, brake, aux = self.model(
            image, lane, dets, det_mask, vehicle_state,
            camera_heading=None, return_aux=True)
        return _flatten6((steer, throttle, brake,
                          aux.get("confidence"), aux.get("risk"),
                          aux.get("car_heading")))


# ============================================================================
# 3. Stage equiv —— PyTorch 侧等价性 / 无损性（快，无 CoreML）
# ============================================================================

def _maxdiff(a: Sequence[torch.Tensor], b: Sequence[torch.Tensor]) -> float:
    return max(float((x - y).abs().max().item()) for x, y in zip(a, b))


def _quant_fp16(t: torch.Tensor) -> torch.Tensor:
    """模拟 fp16 量化（round-trip）。"""
    return t.half().float()


def _quant_int8(t: torch.Tensor) -> torch.Tensor:
    """模拟 per-tensor 对称 int8 量化（round-trip）。"""
    scale = t.abs().max().item() / 127.0
    if scale <= 0:
        return t.clone()
    return (t / scale).round().clamp(-127, 127) * scale


def _make_temporal_nonzero(model) -> None:
    """把 temporal_proj 从零初始化改成非零，模拟**训练后**的真实状态。

    【为什么必须做这一步】
    当前 checkpoint（checkpoints/m9_v2/best_model.pt）**没有 temporal_proj 权重**
    → 加载后保持零初始化 → 时序修正恒为 0 → 8 帧输出与单帧输出**逐位相同**。
    在这种「时序分支被零权重旁路」的状态下，任何特征复用/降精度误差都会被
    完全吸收 → 测出来的 maxdiff = 0 是**假象**，不能作为无损性证据。

    故本函数给 temporal_proj 与 refiner 填入非零权重，让时序路径真正参与计算，
    再验证复用无损性 —— 这才是能外推到训练后模型的结论。
    """
    with torch.no_grad():
        nn.init.normal_(model.temporal_proj.weight, std=0.05)
        nn.init.normal_(model.temporal_proj.bias, std=0.01)
        for p in model.refiner.parameters():
            if p.dim() >= 2:
                nn.init.normal_(p, std=0.03)
            else:
                nn.init.normal_(p, std=0.01)
        for head in (model.heading_head, model.risk_head):
            if head is not None:
                for p in head.parameters():
                    if p.dim() >= 2:
                        nn.init.normal_(p, std=0.03)


def stage_equiv(args) -> Dict:
    print("=" * 100)
    print("STAGE EQUIV —— PyTorch 侧等价性 / 无损性（判据 maxdiff < %.0e）" % TOL_MAXDIFF)
    print("=" * 100)

    model, rep = build_loaded(args.src, steps=args.steps)
    print(f"[模型] checkpoint={args.src}  missing={rep['missing']} unexpected={rep['unexpected']}"
          f"  random_init={rep['random_init']}")
    print(f"       参数量(部署态) = {sum(p.numel() for p in model.parameters()):,}")
    # 时序分支状态（决定后续实验的有效性）
    tp = model.temporal_proj.weight
    print(f"       temporal_proj |max| = {tp.abs().max().item():.6e} "
          f"→ {'★零初始化（时序被旁路，误差会被吸收）' if tp.abs().max().item() < 1e-12 else '非零（时序生效）'}")

    feed = make_feed(FRAMES, seed=args.seed)
    imgs = feed["image"]
    enc = model.image_encoder

    out: Dict = {"checkpoint": str(args.src), "missing": rep["missing"],
                 "unexpected": rep["unexpected"], "results": {}}

    # ---------------- 实验 1：ImageEncoder 逐帧独立性 ----------------
    print()
    print("─" * 100)
    print("实验 1 ★ ImageEncoder 逐帧独立性（所有复用方案的数学基础）")
    print("─" * 100)
    with torch.no_grad():
        f_batch = enc(imgs)                                            # 一次 batch=8
        f_loop = torch.cat([enc(imgs[i:i + 1]) for i in range(FRAMES)], 0)   # 逐帧 8 次
        order = [3, 7, 0, 5, 1, 6, 2, 4]
        f_perm = torch.empty_like(f_loop)
        for i in order:                                                # 乱序逐帧
            f_perm[i] = enc(imgs[i:i + 1])
    d_batch_loop = float((f_batch - f_loop).abs().max().item())
    d_loop_perm = float((f_loop - f_perm).abs().max().item())
    scale = float(f_batch.abs().max().item())
    print(f"  batch=8  vs loop×8   maxdiff = {d_batch_loop:.3e}   (特征量级 {scale:.4f})")
    print(f"  loop     vs 乱序loop maxdiff = {d_loop_perm:.3e}")
    print(f"  逐位相同 (torch.equal) = {torch.equal(f_batch, f_loop)}")
    indep_ok = d_batch_loop < 1e-6 and d_loop_perm < 1e-6
    print(f"  → 逐帧独立：{'✅ 是（无跨帧状态，特征可安全缓存复用）' if indep_ok else '🔴 否'}")
    out["results"]["exp1_frame_independence"] = {
        "batch_vs_loop_maxdiff": d_batch_loop, "loop_vs_perm_maxdiff": d_loop_perm,
        "bitwise_equal": bool(torch.equal(f_batch, f_loop)), "independent": indep_ok,
        "feat_scale": scale}

    # ---------------- 实验 2：复用管线 vs 完整 8 帧（当前 checkpoint）----------------
    print()
    print("─" * 100)
    print("实验 2 复用管线 vs 完整 8 帧（**当前 checkpoint**：时序零权重）")
    print("─" * 100)
    core = ReuseCore(model).eval()
    base = Base8(model).eval()
    with torch.no_grad():
        ref_full = base(imgs, feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"])
        # 复用路径：前 7 帧用「缓存特征」，第 8 帧现算
        cached = f_loop[:HIST]                     # 模拟 Swift 侧缓存
        cur = enc(imgs[-1:])
        feats_reuse = torch.cat([cached, cur], 0)
        reuse = _flatten6(core(feats_reuse, feed["lane"], feed["dets"],
                               feed["det_mask"], feed["vehicle_state"]))
        # 对照：全部重新编码
        feats_full = enc(imgs)
        reenc = _flatten6(core(feats_full, feed["lane"], feed["dets"],
                               feed["det_mask"], feed["vehicle_state"]))
    d_reuse = _maxdiff(ref_full, reuse)
    d_cache = float((cached - enc(imgs[:HIST])).abs().max().item())
    print(f"  缓存特征 vs 重新编码 maxdiff = {d_cache:.3e}  ← 缓存本身是否失真")
    print(f"  复用输出 vs 完整8帧  maxdiff = {d_reuse:.3e}")
    print(f"  6 输出 = {[f'{float(v):.6f}' for v in ref_full]}")
    print(f"  → {'✅ 无损' if d_reuse < TOL_MAXDIFF else '🔴 超差'}"
          f"（注意：当前 temporal_proj=0，时序被旁路，此项**不足以证明**训练后无损）")
    out["results"]["exp2_reuse_zero_temporal"] = {
        "cache_vs_reencode_maxdiff": d_cache, "reuse_vs_full_maxdiff": d_reuse,
        "outputs": [float(v) for v in ref_full],
        "caveat": "temporal_proj 零初始化 → 时序旁路，误差被吸收，需看实验 3"}

    # ---------------- 实验 3 ★：非零时序权重下的复用无损性 ----------------
    print()
    print("─" * 100)
    print("实验 3 ★ 非零时序权重下的复用无损性（模拟训练后模型）")
    print("─" * 100)
    _make_temporal_nonzero(model)
    tp2 = model.temporal_proj.weight.abs().max().item()
    print(f"  注入非零 temporal_proj：|max| = {tp2:.6e}（原为 0）")
    with torch.no_grad():
        # 先确认时序真的生效：改早期帧应改变输出
        ref_full2 = base(imgs, feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"])
        imgs_c = imgs.clone()
        imgs_c[0] = torch.rand(*IMG_SHAPE, generator=torch.Generator().manual_seed(777))
        pert = base(imgs_c, feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"])
        early_influence = _maxdiff(ref_full2, pert)
        # 单帧 vs 8 帧（时序总贡献）
        single = base(imgs[-1:], feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"])
        temporal_gain = _maxdiff(ref_full2, single)
        # ★ 复用路径（缓存 7 帧 + 现算 1 帧）
        f_all = enc(imgs)
        reuse2 = _flatten6(core(torch.cat([f_all[:HIST], enc(imgs[-1:])], 0),
                                feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"]))
        full2 = _flatten6(core(f_all, feed["lane"], feed["dets"],
                               feed["det_mask"], feed["vehicle_state"]))
    d_reuse2 = _maxdiff(ref_full2, reuse2)
    print(f"  时序真的生效吗：改第 1 帧 → 输出变化 {early_influence:.3e}"
          f"  {'✅ 生效' if early_influence > 1e-6 else '🔴 仍被旁路'}")
    print(f"  时序总贡献（8帧 vs 单帧） = {temporal_gain:.3e}")
    print(f"  ★ 复用输出 vs 完整8帧  maxdiff = {d_reuse2:.3e}")
    print(f"  6 输出(完整) = {[f'{float(v):.6f}' for v in ref_full2]}")
    print(f"  6 输出(复用) = {[f'{float(v):.6f}' for v in reuse2]}")
    print(f"  → {'✅ 无损（严格等价，与下游权重无关）' if d_reuse2 < TOL_MAXDIFF else '🔴 超差'}")
    out["results"]["exp3_reuse_nonzero_temporal"] = {
        "temporal_proj_absmax": tp2, "early_frame_influence": early_influence,
        "temporal_total_gain": temporal_gain,
        "reuse_vs_full_maxdiff": d_reuse2, "lossless": d_reuse2 < TOL_MAXDIFF}

    # ---------------- 实验 4：早期帧降精度的影响（非零时序下）----------------
    print()
    print("─" * 100)
    print("实验 4 对照·早期帧降精度的影响（非零时序权重下，才看得出真实影响）")
    print("─" * 100)
    with torch.no_grad():
        rows = []
        for name, q in (("fp16 量化前7帧", _quant_fp16), ("int8 量化前7帧", _quant_int8),
                        ("零化前7帧", lambda t: torch.zeros_like(t))):
            fq = torch.cat([q(f_all[:HIST]), f_all[-1:]], 0)
            o = _flatten6(core(fq, feed["lane"], feed["dets"],
                               feed["det_mask"], feed["vehicle_state"]))
            d = _maxdiff(ref_full2, o)
            rows.append({"variant": name, "maxdiff": d, "pass": d < TOL_MAXDIFF})
            print(f"  {name:<18} maxdiff = {d:.3e}  {'✅ <1e-3' if d < TOL_MAXDIFF else '🔴 超差'}")
        # 每帧都量化（全 8 帧）
        fq8 = _quant_fp16(f_all)
        o8 = _flatten6(core(fq8, feed["lane"], feed["dets"],
                            feed["det_mask"], feed["vehicle_state"]))
        d8 = _maxdiff(ref_full2, o8)
        print(f"  {'fp16 量化全8帧':<18} maxdiff = {d8:.3e}  {'✅ <1e-3' if d8 < TOL_MAXDIFF else '🔴 超差'}")
        rows.append({"variant": "fp16 量化全8帧", "maxdiff": d8, "pass": d8 < TOL_MAXDIFF})
    out["results"]["exp4_early_frame_precision"] = rows

    # ---------------- 实验 5：光流 warp 复用（证伪）----------------
    print()
    print("─" * 100)
    print("实验 5 对照·光流 warp 复用（用 warp 代替重新编码 —— 预期证伪）")
    print("─" * 100)
    print("  ⚠️ 本实验只做「误差量级」判断：即便用**真实运动**做 warp，特征空间")
    print("     也不是平移等变的（GAP 之后是全局向量，空间位移不可用线性 warp 复原）。")
    with torch.no_grad():
        # 用「上一帧特征 + 相邻帧特征差」的线性外推，作为 warp 的最佳情况上界
        delta = (f_all[-1] - f_all[-2]).mean(dim=0, keepdim=True)      # 平均帧间增量
        warp_pred = f_all[-1:] + delta                                  # 线性外推「下一帧」
        true_next = enc(imgs[-1:])                                      # 真值（同一帧，恒等）
        # 更公平：拿 f_all[-2] 线性外推去逼近 f_all[-1]
        warp_est = f_all[-2:-1] + delta
        warp_err = float((warp_est - f_all[-1:]).abs().max().item())
        feat_scale = float(f_all.abs().max().item())
        # 直接把 warp 特征当第 8 帧喂进去 → 端到端误差
        feats_warp = torch.cat([f_all[:HIST], warp_est], 0)
        o_warp = _flatten6(core(feats_warp, feed["lane"], feed["dets"],
                                feed["det_mask"], feed["vehicle_state"]))
        d_warp = _maxdiff(ref_full2, o_warp)
    print(f"  线性外推 warp 特征误差     = {warp_err:.3e}  (特征量级 {feat_scale:.3f}，"
          f"相对 {warp_err / max(feat_scale, 1e-9):.2%})")
    print(f"  warp 特征 → 端到端 maxdiff = {d_warp:.3e}  "
          f"{'✅' if d_warp < TOL_MAXDIFF else '🔴 超差 → 证伪'}")
    print(f"  → 结论：warp 路线{'可用' if d_warp < TOL_MAXDIFF else '**不满足 <1e-3 无损判据，不予采用**'}")
    out["results"]["exp5_flow_warp"] = {
        "warp_feat_err": warp_err, "feat_scale": feat_scale,
        "e2e_maxdiff": d_warp, "pass": d_warp < TOL_MAXDIFF}

    # ---------------- 实验 6：F1 拆分的数值等价（A+B == 完整模型）----------------
    print()
    print("─" * 100)
    print("实验 6 F1 双模型拆分的数值等价（A∘B 串联 vs 完整 8 帧）")
    print("─" * 100)
    with torch.no_grad():
        f1a = F1A(model).eval()
        f1b = F1B(model).eval()
        feats_ab = torch.cat([f1a(imgs[i:i + 1]) for i in range(FRAMES)], 0)   # A 逐帧
        out_ab = f1b(feats_ab, feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"])
    d_ab = _maxdiff(ref_full2, out_ab)
    print(f"  A(逐帧) → B  vs  完整8帧  maxdiff = {d_ab:.3e}")
    print(f"  → {'✅ 拆分无损' if d_ab < TOL_MAXDIFF else '🔴 超差'}")
    out["results"]["exp6_f1_split_equiv"] = {"maxdiff": d_ab, "lossless": d_ab < TOL_MAXDIFF}

    # ---------------- 实验 7：F2 单模型等价 ----------------
    print()
    print("─" * 100)
    print("实验 7 F2 单模型（1 帧图 + 7 帧缓存特征）vs 完整 8 帧")
    print("─" * 100)
    with torch.no_grad():
        f2 = F2(model).eval()
        out_f2 = f2(imgs[-1:], f_all[:HIST], feed["lane"], feed["dets"],
                    feed["det_mask"], feed["vehicle_state"])
    d_f2 = _maxdiff(ref_full2, out_f2)
    print(f"  F2  vs  完整8帧  maxdiff = {d_f2:.3e}")
    print(f"  → {'✅ 无损' if d_f2 < TOL_MAXDIFF else '🔴 超差'}")
    out["results"]["exp7_f2_equiv"] = {"maxdiff": d_f2, "lossless": d_f2 < TOL_MAXDIFF}

    # ---------------- 汇总 ----------------
    print()
    print("=" * 100)
    print("EQUIV 汇总")
    print("=" * 100)
    print(f"  ① 逐帧独立（可缓存）        : {'✅' if indep_ok else '🔴'} maxdiff={d_batch_loop:.2e}")
    print(f"  ② 复用无损（非零时序权重）  : {'✅' if d_reuse2 < TOL_MAXDIFF else '🔴'} maxdiff={d_reuse2:.2e}")
    print(f"  ③ F1 拆分等价               : {'✅' if d_ab < TOL_MAXDIFF else '🔴'} maxdiff={d_ab:.2e}")
    print(f"  ④ F2 单模型等价             : {'✅' if d_f2 < TOL_MAXDIFF else '🔴'} maxdiff={d_f2:.2e}")
    print(f"  ⑤ 光流 warp 对照            : {'✅ 可用' if d_warp < TOL_MAXDIFF else '🔴 证伪'} maxdiff={d_warp:.2e}")
    out["summary"] = {
        "frame_independent": indep_ok,
        "reuse_lossless": d_reuse2 < TOL_MAXDIFF,
        "f1_split_lossless": d_ab < TOL_MAXDIFF,
        "f2_lossless": d_f2 < TOL_MAXDIFF,
        "warp_viable": d_warp < TOL_MAXDIFF,
    }
    return out


# ============================================================================
# 4. Stage ane —— CoreML 导出 + ABBA 实测
# ============================================================================

def _shapes(model_key: str) -> Tuple[List[str], List[tuple], List[str]]:
    """返回 (输入名列表, 输入 shape 列表, 输出名列表)。"""
    outs = ["steer", "throttle", "brake", "confidence", "risk", "car_heading"]
    if model_key == "base8":
        return (["image", "lane", "dets", "det_mask", "vehicle_state"],
                [(FRAMES, 3, 180, 320), (1, 1, 160, 160), (1, 20, 12), (1, 20), (1, 8)], outs)
    if model_key == "f1a":
        return (["image"], [(1, 3, 180, 320)], ["feat"])
    if model_key == "f1b":
        return (["feats", "lane", "dets", "det_mask", "vehicle_state"],
                [(FRAMES, FEAT_DIM), (1, 1, 160, 160), (1, 20, 12), (1, 20), (1, 8)], outs)
    if model_key == "f2":
        return (["image", "hist_feats", "lane", "dets", "det_mask", "vehicle_state"],
                [(1, 3, 180, 320), (HIST, FEAT_DIM), (1, 1, 160, 160), (1, 20, 12),
                 (1, 20), (1, 8)], outs)
    raise ValueError(f"未知模型 {model_key!r}")


def _example_inputs(model_key: str, feed: Dict, feats: torch.Tensor):
    if model_key == "base8":
        return (feed["image"], feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"])
    if model_key == "f1a":
        return (feed["image"][-1:],)
    if model_key == "f1b":
        return (feats, feed["lane"], feed["dets"], feed["det_mask"], feed["vehicle_state"])
    if model_key == "f2":
        return (feed["image"][-1:], feats[:HIST], feed["lane"], feed["dets"],
                feed["det_mask"], feed["vehicle_state"])
    raise ValueError(model_key)


def _build_wrapper(model_key: str, model):
    return {"base8": Base8, "f1a": F1A, "f1b": F1B, "f2": F2}[model_key](model).eval()


def export_one(model_key: str, model, feed: Dict, feats: torch.Tensor,
               quant: str, out_dir: Path, target):
    """导出一个模型 → 返回 (.mlpackage 路径, 元信息)。"""
    names, shapes, outs = _shapes(model_key)
    wrapper = _build_wrapper(model_key, model)
    ex = _example_inputs(model_key, feed, feats)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, ex, strict=False)

    inputs = [ct.TensorType(name=n, shape=s, dtype=np.float32) for n, s in zip(names, shapes)]
    outputs = [ct.TensorType(name=n, dtype=np.float32) for n in outs]
    ml = ct.convert(
        traced, inputs=inputs, outputs=outputs,
        convert_to="mlprogram", minimum_deployment_target=target,
        compute_precision=ct.precision.FLOAT16, source="pytorch")

    if quant == "palette":
        cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
            mode="kmeans", nbits=8, granularity="per_tensor", group_size=1))
        ml = cto.palettize_weights(ml, cfg)

    out_dir.mkdir(parents=True, exist_ok=True)
    pkg = out_dir / f"exp_reuse_{model_key}_{quant}.mlpackage"
    if pkg.exists():
        import shutil
        shutil.rmtree(pkg)
    ml.save(str(pkg))
    return pkg, {"inputs": names, "shapes": shapes, "outputs": outs}


def _dir_size_mb(p: Path) -> float:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1024 / 1024


def _to_feed(names: Sequence[str], ex: Sequence[torch.Tensor]) -> Dict[str, np.ndarray]:
    return {n: t.detach().cpu().numpy().astype(np.float32) for n, t in zip(names, ex)}


def bench_once(pkg: Path, feed: Dict[str, np.ndarray], cu, iters: int, warmup: int) -> float:
    mm = ct.models.MLModel(str(pkg), compute_units=cu)
    for _ in range(warmup):
        mm.predict(feed)
    t0 = time.perf_counter()
    for _ in range(iters):
        mm.predict(feed)
    return (time.perf_counter() - t0) / iters * 1000.0


def abba(pkg: Path, feed: Dict[str, np.ndarray], iters: int, warmup: int) -> Tuple[float, float]:
    """ABBA：ANE, CPU, CPU, ANE → 各自取中位。"""
    a1 = bench_once(pkg, feed, ct.ComputeUnit.CPU_AND_NE, iters, warmup)
    c1 = bench_once(pkg, feed, ct.ComputeUnit.CPU_ONLY, iters, warmup)
    c2 = bench_once(pkg, feed, ct.ComputeUnit.CPU_ONLY, iters, warmup)
    a2 = bench_once(pkg, feed, ct.ComputeUnit.CPU_AND_NE, iters, warmup)
    return statistics.median([a1, a2]), statistics.median([c1, c2])


def stage_ane(args) -> Dict:
    print("=" * 100)
    print("STAGE ANE —— CoreML 导出 + ABBA 实测（真机 %s）" % os.uname().machine)
    print("=" * 100)
    target = {"macos13": ct.target.macOS13, "macos14": ct.target.macOS14}[args.target]

    model, rep = build_loaded(args.src, steps=args.steps)
    _make_temporal_nonzero(model)      # 用非零时序权重导出（图结构更真实：GRU 真参与）
    feed = make_feed(FRAMES, seed=args.seed)
    with torch.no_grad():
        feats = model.image_encoder(feed["image"])

    keys = [k.strip() for k in args.models.split(",") if k.strip()]
    out_dir = Path(args.out_dir)
    rows = []
    print(f"{'模型':>6} {'体积MB':>9} {'ANE ms':>9} {'CPU ms':>9} {'ANE/CPU':>9} {'判定':>14} {'30Hz余量':>9}")
    print("-" * 100)
    for k in keys:
        try:
            pkg, meta = export_one(k, model, feed, feats, args.quant, out_dir, target)
            names = meta["inputs"]
            ex = _example_inputs(k, feed, feats)
            cf = _to_feed(names, ex)
            a, c = abba(pkg, cf, args.iters, args.warmup)
            r = a / c
            ok = r < ANE_RATIO_OK
            mb = _dir_size_mb(pkg)
            rows.append({"model": k, "pkg": str(pkg), "mb": mb, "ane_ms": a, "cpu_ms": c,
                         "ratio": r, "ane_ok": ok, "budget_x": 33.0 / a,
                         "inputs": names, "shapes": [list(s) for s in meta["shapes"]]})
            print(f"{k:>6} {mb:>9.3f} {a:>9.2f} {c:>9.2f} {r:>9.2f} "
                  f"{'✅ ANE 生效' if ok else '🔴 退化 CPU':>14} {33.0/a:>8.1f}x")
        except Exception as exc:
            print(f"{k:>6} {'—':>9} {'—':>9} {'—':>9} {'—':>9} "
                  f"{'✗ ' + type(exc).__name__:>14}  {str(exc)[:40]}")
            rows.append({"model": k, "error": f"{type(exc).__name__}: {str(exc)[:200]}"})

    # ---- 组合延迟 ----
    print()
    print("=" * 100)
    print("组合延迟（每帧成本）")
    print("=" * 100)
    by = {r["model"]: r for r in rows if "ane_ms" in r}
    combos = []
    if "f1a" in by and "f1b" in by:
        tot_a = by["f1a"]["ane_ms"] + by["f1b"]["ane_ms"]
        tot_c = by["f1a"]["cpu_ms"] + by["f1b"]["cpu_ms"]
        combos.append(("F1 双模型（A+B 串行）", tot_a, tot_c,
                       by["f1a"]["ane_ok"] and by["f1b"]["ane_ok"]))
    if "f2" in by:
        combos.append(("F2 单模型（1帧图+7帧特征）", by["f2"]["ane_ms"], by["f2"]["cpu_ms"],
                       by["f2"]["ane_ok"]))
    if "base8" in by:
        combos.append(("基线 完整 8 帧", by["base8"]["ane_ms"], by["base8"]["cpu_ms"],
                       by["base8"]["ane_ok"]))
    for name, a, c, ok in combos:
        print(f"  {name:<30} ANE {a:>7.2f} ms | CPU {c:>7.2f} ms | "
              f"{'✅ ANE 生效' if ok else '🔴 退化'} | 30Hz 余量 {33.0/a:.1f}x")
    print()
    if "base8" in by:
        b = by["base8"]
        for name, a, c, ok in combos:
            if name.startswith("基线"):
                continue
            print(f"  ★ {name} 相对基线：ANE 路径 {b['ane_ms']/a:.2f}× 提速，"
                  f"CPU 路径 {b['cpu_ms']/c:.2f}×")
    return {"checkpoint": str(args.src), "missing": rep["missing"], "quant": args.quant,
            "target": args.target, "rows": rows, "combos": [
                {"name": n, "ane_ms": a, "cpu_ms": c, "ane_ok": ok} for n, a, c, ok in combos]}


# ============================================================================
# 5. Stage e2e —— 端到端数值一致性（CoreML vs PyTorch）
# ============================================================================

def stage_e2e(args) -> Dict:
    print("=" * 100)
    print("STAGE E2E —— 端到端数值一致性（复用流水线 CoreML 输出 vs PyTorch 完整 8 帧）")
    print("=" * 100)
    target = {"macos13": ct.target.macOS13, "macos14": ct.target.macOS14}[args.target]
    model, _ = build_loaded(args.src, steps=args.steps)
    _make_temporal_nonzero(model)
    feed = make_feed(FRAMES, seed=args.seed)
    core = ReuseCore(model).eval()
    with torch.no_grad():
        feats = model.image_encoder(feed["image"])
        ref = _flatten6(core(feats, feed["lane"], feed["dets"],
                             feed["det_mask"], feed["vehicle_state"]))
        ref = [float(v) for v in ref]
    print(f"  PyTorch 参考 6 输出 = {[f'{v:.6f}' for v in ref]}")

    out_dir = Path(args.out_dir)
    results = {}
    # F1：A → B 串联
    try:
        pkg_a, meta_a = export_one("f1a", model, feed, feats, args.quant, out_dir, target)
        pkg_b, meta_b = export_one("f1b", model, feed, feats, args.quant, out_dir, target)
        ma = ct.models.MLModel(str(pkg_a), compute_units=ct.ComputeUnit.ALL)
        mb = ct.models.MLModel(str(pkg_b), compute_units=ct.ComputeUnit.ALL)
        # ★ 逐帧过 A（模拟 Swift 每帧一次），缓存后过 B
        feats_cml = []
        for i in range(FRAMES):
            o = ma.predict(_to_feed(meta_a["inputs"], (feed["image"][i:i + 1],)))
            feats_cml.append(np.asarray(o["feat"]).reshape(1, FEAT_DIM))
        feats_cml = np.concatenate(feats_cml, 0).astype(np.float32)
        d_feat = float(np.abs(feats_cml - feats.numpy()).max())
        ex_b = (torch.from_numpy(feats_cml), feed["lane"], feed["dets"],
                feed["det_mask"], feed["vehicle_state"])
        pred_b = mb.predict(_to_feed(meta_b["inputs"], ex_b))
        got_b = [float(np.asarray(pred_b[n]).flatten()[0]) for n in meta_b["outputs"]]
        d_b = max(abs(a - b) for a, b in zip(ref, got_b))
        print(f"  F1-A 特征 vs PyTorch   maxdiff = {d_feat:.3e}")
        print(f"  F1-B 输出 vs PyTorch   maxdiff = {d_b:.3e}   {[f'{v:.6f}' for v in got_b]}")
        results["f1"] = {"feat_maxdiff": d_feat, "output_maxdiff": d_b,
                         "pass": d_b < TOL_MAXDIFF, "pred": got_b}
    except Exception as exc:
        print(f"  F1 失败：{type(exc).__name__}: {str(exc)[:120]}")
        results["f1"] = {"error": f"{type(exc).__name__}: {str(exc)[:200]}"}

    # F2：单模型
    try:
        pkg2, meta2 = export_one("f2", model, feed, feats, args.quant, out_dir, target)
        m2 = ct.models.MLModel(str(pkg2), compute_units=ct.ComputeUnit.ALL)
        ex2 = (feed["image"][-1:], feats[:HIST], feed["lane"], feed["dets"],
               feed["det_mask"], feed["vehicle_state"])
        pred2 = m2.predict(_to_feed(meta2["inputs"], ex2))
        got2 = [float(np.asarray(pred2[n]).flatten()[0]) for n in meta2["outputs"]]
        d2 = max(abs(a - b) for a, b in zip(ref, got2))
        print(f"  F2 输出 vs PyTorch     maxdiff = {d2:.3e}   {[f'{v:.6f}' for v in got2]}")
        results["f2"] = {"output_maxdiff": d2, "pass": d2 < TOL_MAXDIFF, "pred": got2}
    except Exception as exc:
        print(f"  F2 失败：{type(exc).__name__}: {str(exc)[:120]}")
        results["f2"] = {"error": f"{type(exc).__name__}: {str(exc)[:200]}"}

    print()
    print("  ⚠️ 口径说明：本 stage 的误差 = **复用误差 + CoreML fp16/palette 量化误差**。")
    print("     复用本身的无损性已由 --stage equiv 在 PyTorch 侧单独证明（纯复用，无量化）。")
    return {"reference": ref, "results": results, "quant": args.quant}


# ============================================================================
# 6. main
# ============================================================================

def main() -> int:
    ap = argparse.ArgumentParser(description="S5 特征复用流水线实验")
    ap.add_argument("--stage", default="equiv", choices=["equiv", "ane", "e2e", "all"])
    ap.add_argument("--src", default=CKPT_DEFAULT)
    ap.add_argument("--steps", type=int, default=12, help="refiner 步数（红线：不降）")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--quant", default="palette", choices=["palette", "fp16"])
    ap.add_argument("--target", default="macos13", choices=["macos13", "macos14"])
    ap.add_argument("--models", default="f1a,f1b,f2,base8")
    ap.add_argument("--out-dir", default="models")
    ap.add_argument("--iters", type=int, default=30)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--json-out", default="")
    args = ap.parse_args()

    report: Dict = {"stage": args.stage, "steps": args.steps, "quant": args.quant}
    t0 = time.time()
    if args.stage in ("equiv", "all"):
        report["equiv"] = stage_equiv(args)
    if args.stage in ("ane", "all"):
        report["ane"] = stage_ane(args)
    if args.stage in ("e2e", "all"):
        report["e2e"] = stage_e2e(args)
    report["elapsed_s"] = time.time() - t0

    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\n[JSON] 已写入 {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
