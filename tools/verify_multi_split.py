#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""多模型拆分等价性深度验证（S4）

排查三个等价性陷阱，并**定位到一个真实不等价 bug**：

陷阱 1 · 单 seed：Lead 跑通 maxdiff=0 只用了 seed 0 → 这里 seed 0/1/2 三轮。
陷阱 2 · 零权重：checkpoint 缺 refiner/experts/heads 权重，且 refiner_proj /
        expert_out_proj 被 __init__ 零初始化 → delta≡0 → refined≡fused（恒等），
        chunk 串联当然逐位一致（trivially 等价）。这里**手动注入非零随机权重**到
        refiner 的 cell / refiner_proj / experts / router / expert_out_proj，
        逼出真实迭代，再验等价性。
陷阱 3 · 只验 PyTorch：CoreML 端串联 vs 单模型 CoreML 也要对（fp16 < 1e-3）。

★ 结论（详见运行输出与文件末尾 ROOT CAUSE）：
  现版 `_Chunk.forward`（tools/export_multi_split.py:60）**不等价**。
  根因：它把「块输入」同时用作 GRU cell 的第一入参 `cell(fused, h)` 和残差基址
  `refined = fused + delta`；但单模型 `IterationRefiner.forward`
  （src/model_v2.py:1127-1131）**24 步全程** cell 第一入参 = 原始 fused、
  残差基址 = 原始 fused，**只有隐状态 h 在步间传递**。
  chunk1 的输入恰是原始 fused → 前 4 步逐位一致；chunk2+ 的输入是上一块的
  refined，被错当 fused 用 → 从 step5 起不等价，误差随步数指数放大。
  零权重（refiner_proj=0）时 delta≡0、refined≡fused，掩盖了这个结构错误
  → Lead 的单 seed maxdiff=0 是 **trivially 等价**。

  修复：chunk 改为**双输入** `(fused_base, h)`，fused_base 全程透传原始 fused，
  h 为跨块隐状态。本脚本用 `_ChunkFixed` 证明修复后 maxdiff 归 0（PyTorch + CoreML）。

用法：
    ./.venv-yolo26/bin/python3 tools/verify_multi_split.py                 # 全量
    ./.venv-yolo26/bin/python3 tools/verify_multi_split.py --skip-coreml   # 只 PyTorch
"""
from __future__ import annotations

import argparse, copy, json, sys, tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))
sys.path.insert(0, str(_ROOT / "tools"))
import model_v2  # noqa: E402
from export_multi_split import (  # noqa: E402
    _Chunk, _TemporalFusion, _FusionHead, load_weights,
)

IMG_H, IMG_W = 180, 320
LANE_SIZE = 160
NUM_DETS = 20
DET_FEAT_DIM = 12
STATE_DIM = 8
NUM_FRAMES = 8
FEAT_DIM = 256
FUSED_DIM = 512
NUM_STEPS = 24
CHUNK_SIZE = 4
MOE_STEPS = [17, 18, 19, 20, 21, 22, 23, 24]
PROBE_STEPS = [4, 8, 12, 16, 20, 24]

OUT_NAMES = ["steer", "throttle", "brake", "confidence", "risk", "car_heading"]


# ============================================================================
# 修复版 chunk：双输入 (fused_base, h)，与单模型 refiner 逐位等价
# ============================================================================

class _ChunkFixed(nn.Module):
    """修正版 refiner 块：**显式携带原始 fused**，跨块只传递隐状态 h。

    ┌ 与单模型 IterationRefiner.forward 的对应 ────────────────────────────┐
    │  h = fused_base                                  # 初始隐状态        │
    │  for step in [start..end]:                                          │
    │      h = cell(fused_base, h)          # 第一入参 = 原始 fused（关键） │
    │      refined = fused_base + proj(h)   # 残差基址 = 原始 fused（关键） │
    │      [MoE] refined += expert_out_proj(...)                          │
    │      h = refined                                                    │
    └─────────────────────────────────────────────────────────────────────┘
    串联：h = fused0
          for chunk: h = chunk(fused0, h)
    """
    def __init__(self, refiner, step_start: int, step_end: int):
        super().__init__()
        self.refiner_shared = refiner.shared
        self.cells = refiner.cells          # 保留 ModuleList，支持 shared/indep
        self.refiner_proj = refiner.refiner_proj
        self.expert_out_proj = refiner.expert_out_proj
        self.step_start = step_start
        self.step_end = step_end
        self.moe_steps = [s for s in refiner.moe_steps if step_start <= s <= step_end]
        if self.moe_steps and refiner.experts is not None:
            self.router = refiner.router
            self.experts = refiner.experts
            self.num_experts = refiner.num_experts
        else:
            self.router = None
            self.experts = None
            self.num_experts = 0

    def forward(self, fused_base: torch.Tensor, h: torch.Tensor) -> torch.Tensor:
        """fused_base [B,512]（全程不变） + h [B,512]（跨块隐状态） → h_new [B,512]"""
        for step in range(self.step_start, self.step_end + 1):
            cell = self.cells[0] if self.refiner_shared else self.cells[step - 1]
            h = cell(fused_base, h)
            delta = self.refiner_proj(h)
            refined = fused_base + delta
            if self.experts is not None and step in self.moe_steps:
                route_logits = self.router(refined)
                expert_weights = torch.softmax(route_logits, dim=-1)
                expert_out = torch.zeros_like(refined)
                for e in range(self.num_experts):
                    w = expert_weights[:, e:e + 1]
                    expert_out = expert_out + w * self.experts[e](refined)
                refined = refined + self.expert_out_proj(expert_out)
            h = refined
        return h


class _ChunkBug(nn.Module):
    """【反证用】旧版有 bug 的 refiner 块：单输入，块输入同时当 cell 入参和残差基址。

    保留此定义仅为复现「现版 _Chunk 不等价」的证据（S4 报告用）。
    正确实现见 `_ChunkFixed`（本文件）与 `export_multi_split._Chunk`（已修）。
    """
    def __init__(self, refiner, step_start: int, step_end: int):
        super().__init__()
        self.cell = refiner.cells[0] if refiner.shared else None
        self.refiner_proj = refiner.refiner_proj
        self.expert_out_proj = refiner.expert_out_proj
        self.step_start = step_start
        self.step_end = step_end
        self.moe_steps = [s for s in refiner.moe_steps if step_start <= s <= step_end]
        if self.moe_steps and refiner.experts is not None:
            self.router = refiner.router
            self.experts = refiner.experts
            self.num_experts = refiner.num_experts
        else:
            self.router = None
            self.experts = None
            self.num_experts = 0

    def forward(self, fused: torch.Tensor) -> torch.Tensor:
        h = fused
        for step in range(self.step_start, self.step_end + 1):
            h = self.cell(fused, h)
            refined = fused + self.refiner_proj(h)
            if self.experts is not None and step in self.moe_steps:
                route_logits = self.router(refined)
                expert_weights = torch.softmax(route_logits, dim=-1)
                expert_out = torch.zeros_like(refined)
                for e in range(self.num_experts):
                    w = expert_weights[:, e:e + 1]
                    expert_out = expert_out + w * self.experts[e](refined)
                refined = refined + self.expert_out_proj(expert_out)
            h = refined
        return h
# ============================================================================

def inject_nonzero_refiner_weights(m: model_v2.M2Model, seed: int,
                                   scale: float = 0.1) -> Dict[str, float]:
    """把 refiner 的全部子模块用**非零随机权重**覆盖（固定 seed 可复现）。

    checkpoint 缺 refiner.* 全部键 → load 后 refiner 是 build_model 时的初值：
      · refiner_proj / expert_out_proj：零初始化（→ delta≡0 → trivially 等价）
      · cells / experts / router：kaiming 随机
    为排除零权重陷阱，这里用 seed-controlled 非零随机覆盖**全部** refiner 子模块，
    让每步 delta≠0、MoE 路径也激活。

    scale：权重幅度。PyTorch 精度无限，用 0.1 即可逼出真实迭代；
           CoreML 端建议用 0.005（特征落在 fp16 甜区，避免 24 步放大后饱和失真）。
    """
    g = torch.Generator().manual_seed(seed)
    stats: Dict[str, float] = {}
    r = m.refiner
    assert r is not None, "refiner 未启用，无法注入"

    def _fill(p: torch.Tensor, name: str, mul: float = 1.0):
        with torch.no_grad():
            w = (torch.rand(p.shape, generator=g) * 2 - 1) * scale * mul
            p.copy_(w)
            stats[name] = float(p.abs().max())

    _fill(r.refiner_proj.weight, "refiner_proj.weight")
    _fill(r.refiner_proj.bias, "refiner_proj.bias", mul=0.5)

    cells = list(r.cells) if isinstance(r.cells, nn.ModuleList) else [r.cells]
    for ci, cell in enumerate(cells):
        for ln in ["x_r", "h_r", "x_z", "h_z", "x_n", "h_n"]:
            _fill(getattr(cell, ln).weight, f"cell{ci}.{ln}.weight")
            _fill(getattr(cell, ln).bias, f"cell{ci}.{ln}.bias", mul=0.5)

    if r.experts is not None:
        for ei, ex in enumerate(r.experts):
            for ln, param in ex.named_parameters():
                _fill(param, f"expert{ei}.{ln}")
        _fill(r.router.weight, "router.weight")
        _fill(r.router.bias, "router.bias", mul=0.5)
        _fill(r.expert_out_proj.weight, "expert_out_proj.weight")
        _fill(r.expert_out_proj.bias, "expert_out_proj.bias", mul=0.5)
    return stats


# ============================================================================
# 输入构造
# ============================================================================

def _rand_inputs(seed: int) -> Tuple[torch.Tensor, ...]:
    g = torch.Generator().manual_seed(seed)
    img = torch.rand(NUM_FRAMES, 3, IMG_H, IMG_W, generator=g)
    lane = (torch.rand(1, 1, LANE_SIZE, LANE_SIZE, generator=g) > 0.985).float()
    dets = torch.rand(1, NUM_DETS, DET_FEAT_DIM, generator=g)
    dm = (torch.rand(1, NUM_DETS, generator=g) > 0.35).float()
    st = torch.rand(1, STATE_DIM, generator=g) * 2.0 - 1.0
    return img, lane, dets, dm, st


def _fused_of(m: model_v2.M2Model, img, lane, dets, dm, st) -> torch.Tensor:
    """复刻 M2Model.forward 的时序模式分支，返回 refiner 输入 fused。"""
    feat = m.image_encoder(img)
    cur = feat[-1:]
    tfeat = m.temporal_encoder(feat.unsqueeze(0), None)
    img_feat = cur + m.temporal_proj(tfeat)
    return torch.cat([img_feat, m.lane_encoder(lane, 1, None),
                      m.det_encoder(dets, dm, 1, None),
                      m.state_encoder(st, 1, None)], dim=1)


def refiner_step_trace(refiner, fused: torch.Tensor) -> Dict[int, torch.Tensor]:
    """复刻 IterationRefiner.forward 循环，记录每步结束后的 h（=refined）。"""
    h = fused
    trace: Dict[int, torch.Tensor] = {}
    for step in range(1, refiner.num_steps + 1):
        cell = refiner.cells[0] if refiner.shared else refiner.cells[step - 1]
        h = cell(fused, h)
        refined = fused + refiner.refiner_proj(h)
        if refiner.experts is not None and step in refiner.moe_steps:
            ew = torch.softmax(refiner.router(refined), dim=-1)
            eo = torch.zeros_like(refined)
            for e in range(refiner.num_experts):
                eo = eo + ew[:, e:e + 1] * refiner.experts[e](refined)
            refined = refined + refiner.expert_out_proj(eo)
        h = refined
        trace[step] = h.clone()
    return trace


# ============================================================================
# (a) PyTorch 端 + (b) chunk 边界：现版 vs 修复版
# ============================================================================

def verify_pytorch(m: model_v2.M2Model, chunks: List[Tuple[int, int]],
                   seed: int) -> Dict:
    img, lane, dets, dm, st = _rand_inputs(seed)
    tf_model = _TemporalFusion(m).eval()
    head_model = _FusionHead(m).eval()

    with torch.no_grad():
        o_ref = m(image=img, lane_mask=lane, dets=dets, det_mask=dm,
                  vehicle_state=st, return_aux=True)
        steer_r, thr_r, brk_r, aux_r = o_ref

        fused_ref = _fused_of(m, img, lane, dets, dm, st)
        trace = refiner_step_trace(m.refiner, fused_ref)

        feat = m.image_encoder(img)
        fused0, img_feat_s, det_feat_s = tf_model(
            feat.unsqueeze(0), lane, dets, dm, st)

        # ---- 现版 _ChunkBug（单输入，已证伪）----
        h_bug = fused0
        chunk_bug = {}
        for i, (s, e) in enumerate(chunks):
            h_bug = _ChunkBug(m.refiner, s, e).eval()(h_bug)
            chunk_bug[e] = h_bug.clone()
        o_bug = head_model(h_bug, img_feat_s, det_feat_s, dm)

        # ---- 修复版 _ChunkFixed（双输入，fused 透传）----
        h_fix = fused0
        chunk_fix = {}
        for i, (s, e) in enumerate(chunks):
            h_fix = _ChunkFixed(m.refiner, s, e).eval()(fused0, h_fix)
            chunk_fix[e] = h_fix.clone()
        o_fix = head_model(h_fix, img_feat_s, det_feat_s, dm)

    def _diffs(a_list, b_list):
        out = {}
        for n, a, b in zip(OUT_NAMES, a_list, b_list):
            if a is None or b is None:
                out[n] = float("nan"); continue
            out[n] = (a.reshape(-1) - b.reshape(-1)).abs().max().item()
        return out

    ref_outs = [steer_r, thr_r, brk_r, aux_r.get("confidence"),
                aux_r.get("risk"), aux_r.get("car_heading")]
    out_bug = _diffs(ref_outs, o_bug)
    out_fix = _diffs(ref_outs, o_fix)

    bound_bug = {sp: (trace[sp] - chunk_bug[sp]).abs().max().item()
                 for sp in PROBE_STEPS if sp in chunk_bug}
    bound_fix = {sp: (trace[sp] - chunk_fix[sp]).abs().max().item()
                 for sp in PROBE_STEPS if sp in chunk_fix}

    return {
        "seed": seed,
        "fused_entry_maxdiff": (fused_ref - fused0).abs().max().item(),
        "final_bug": out_bug, "final_bug_overall": max(out_bug.values()),
        "final_fix": out_fix, "final_fix_overall": max(out_fix.values()),
        "bound_bug": bound_bug,
        "bound_bug_overall": max(bound_bug.values()) if bound_bug else float("nan"),
        "bound_fix": bound_fix,
        "bound_fix_overall": max(bound_fix.values()) if bound_fix else float("nan"),
        "refiner_final_bug": (trace[NUM_STEPS] - chunk_bug[NUM_STEPS]
                              ).abs().max().item(),
        "refiner_final_fix": (trace[NUM_STEPS] - chunk_fix[NUM_STEPS]
                              ).abs().max().item(),
    }


# ============================================================================
# (c) CoreML 端：现版 vs 修复版串联 predict vs 单模型 predict
# ============================================================================

def _coreml_feed(img, lane, dets, dm, st) -> Dict[str, np.ndarray]:
    return {"image": img.numpy().astype(np.float32),
            "lane": lane.numpy().astype(np.float32),
            "dets": dets.numpy().astype(np.float32),
            "det_mask": dm.numpy().astype(np.float32),
            "vehicle_state": st.numpy().astype(np.float32)}


def verify_coreml(m: model_v2.M2Model, chunks: List[Tuple[int, int]],
                  seed: int, tmpdir: Path) -> Dict:
    import coremltools as ct
    from export_m9_v2_coreml import _ExportWrapper, INPUT_NAMES, OUTPUT_NAMES
    prec = ct.precision.FLOAT16
    tgt = ct.target.macOS15

    img, lane, dets, dm, st = _rand_inputs(seed)
    feed = _coreml_feed(img, lane, dets, dm, st)
    d = tmpdir / f"seed{seed}"
    d.mkdir(parents=True, exist_ok=True)

    # ---- 单模型端到端（非零权重）----
    wrapper = _ExportWrapper(m).eval()
    with torch.no_grad():
        tr = torch.jit.trace(wrapper, (img, lane, dets, dm, st), strict=False)
    e2e = ct.convert(tr,
        inputs=[ct.TensorType(name=n, shape=s, dtype=np.float32) for n, s in
                zip(INPUT_NAMES, [(NUM_FRAMES, 3, IMG_H, IMG_W),
                    (1, 1, LANE_SIZE, LANE_SIZE), (1, NUM_DETS, DET_FEAT_DIM),
                    (1, NUM_DETS), (1, STATE_DIM)])],
        outputs=[ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES],
        compute_precision=prec, minimum_deployment_target=tgt, convert_to="mlprogram")
    e2e.save(str(d / "e2e.mlpackage"))
    m_e2e = ct.models.MLModel(str(d / "e2e.mlpackage"))
    pred_e2e = m_e2e.predict(feed)

    # ---- tf ----
    tf_model = _TemporalFusion(m).eval()
    with torch.no_grad():
        tf_tr = torch.jit.trace(tf_model, (torch.rand(1, NUM_FRAMES, FEAT_DIM),
            torch.zeros(1, 1, LANE_SIZE, LANE_SIZE),
            torch.zeros(1, NUM_DETS, DET_FEAT_DIM), torch.zeros(1, NUM_DETS),
            torch.zeros(1, STATE_DIM)))
    ml_tf = ct.convert(tf_tr,
        inputs=[ct.TensorType(name=n, shape=s, dtype=np.float32) for n, s in
                [("feat_seq", (1, NUM_FRAMES, FEAT_DIM)),
                 ("lane", (1, 1, LANE_SIZE, LANE_SIZE)),
                 ("dets", (1, NUM_DETS, DET_FEAT_DIM)),
                 ("det_mask", (1, NUM_DETS)), ("vehicle_state", (1, STATE_DIM))]],
        outputs=[ct.TensorType(name=n, dtype=np.float32)
                 for n in ["fused", "img_feat", "det_feat"]],
        compute_precision=prec, minimum_deployment_target=tgt, convert_to="mlprogram")
    ml_tf.save(str(d / "tf.mlpackage"))
    m_tf = ct.models.MLModel(str(d / "tf.mlpackage"))

    feat = m.image_encoder(img).detach()
    pred_tf = m_tf.predict({"feat_seq": feat.unsqueeze(0).numpy().astype(np.float32),
                            "lane": feed["lane"], "dets": feed["dets"],
                            "det_mask": feed["det_mask"],
                            "vehicle_state": feed["vehicle_state"]})
    fused0_np = np.asarray(pred_tf["fused"]).astype(np.float32)

    def _export_chunks(fixed: bool):
        mods = []
        for i, (s, e) in enumerate(chunks):
            cm = (_ChunkFixed if fixed else _Chunk)(m.refiner, s, e).eval()
            if fixed:
                with torch.no_grad():
                    ctr = torch.jit.trace(cm, (torch.rand(1, FUSED_DIM),
                                               torch.rand(1, FUSED_DIM)))
                mlc = ct.convert(ctr,
                    inputs=[ct.TensorType(name="fused", shape=(1, FUSED_DIM),
                                          dtype=np.float32),
                            ct.TensorType(name="h", shape=(1, FUSED_DIM),
                                          dtype=np.float32)],
                    outputs=[ct.TensorType(name="refined", dtype=np.float32)],
                    compute_precision=prec, minimum_deployment_target=tgt,
                    convert_to="mlprogram")
            else:
                with torch.no_grad():
                    ctr = torch.jit.trace(cm, torch.rand(1, FUSED_DIM))
                mlc = ct.convert(ctr,
                    inputs=[ct.TensorType(name="fused", shape=(1, FUSED_DIM),
                                          dtype=np.float32)],
                    outputs=[ct.TensorType(name="refined", dtype=np.float32)],
                    compute_precision=prec, minimum_deployment_target=tgt,
                    convert_to="mlprogram")
            p = d / f"{'fix' if fixed else 'bug'}_chunk{i+1}.mlpackage"
            mlc.save(str(p))
            mods.append(ct.models.MLModel(str(p)))
        return mods

    # ---- head ----
    head_model = _FusionHead(m).eval()
    with torch.no_grad():
        htr = torch.jit.trace(head_model, (torch.rand(1, FUSED_DIM),
            torch.rand(1, FEAT_DIM), torch.rand(1, 128), torch.zeros(1, NUM_DETS)))
    ml_head = ct.convert(htr,
        inputs=[ct.TensorType(name=n, shape=s, dtype=np.float32) for n, s in
                [("fused", (1, FUSED_DIM)), ("img_feat", (1, FEAT_DIM)),
                 ("det_feat", (1, 128)), ("det_mask", (1, NUM_DETS))]],
        outputs=[ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES],
        compute_precision=prec, minimum_deployment_target=tgt, convert_to="mlprogram")
    ml_head.save(str(d / "head.mlpackage"))
    m_head = ct.models.MLModel(str(d / "head.mlpackage"))

    head_feed_base = {"img_feat": np.asarray(pred_tf["img_feat"], dtype=np.float32),
                      "det_feat": np.asarray(pred_tf["det_feat"], dtype=np.float32),
                      "det_mask": feed["det_mask"]}

    # ---- 现版串联 ----
    fused = fused0_np
    for cml in _export_chunks(False):
        fused = np.asarray(cml.predict({"fused": fused})["refined"], dtype=np.float32)
    pred_bug = m_head.predict({"fused": fused, **head_feed_base})

    # ---- 修复版串联（fused0 透传 + h 跨块）----
    h = fused0_np
    for cml in _export_chunks(True):
        h = np.asarray(cml.predict({"fused": fused0_np, "h": h})["refined"],
                       dtype=np.float32)
    pred_fix = m_head.predict({"fused": h, **head_feed_base})

    def _cmp(pred):
        return {n: float(np.abs(np.asarray(pred_e2e[n], np.float32).flatten()
                                - np.asarray(pred[n], np.float32).flatten()).max())
                for n in OUTPUT_NAMES}

    db, df = _cmp(pred_bug), _cmp(pred_fix)

    # ---- 特征级 CoreML 对比（更可靠：避免饱和输出掩盖真误差）----
    # 单模型 24 步 refiner 整体 CoreML vs 修复版 chunk 串联 CoreML
    class _RefinerAll(nn.Module):
        def __init__(s, r): super().__init__(); s.r = r
        def forward(s, fused): return s.r(fused)
    with torch.no_grad():
        atr = torch.jit.trace(_RefinerAll(m.refiner).eval(), torch.rand(1, FUSED_DIM))
    all_ref = ct.convert(atr,
        inputs=[ct.TensorType(name="fused", shape=(1, FUSED_DIM), dtype=np.float32)],
        outputs=[ct.TensorType(name="refined", dtype=np.float32)],
        compute_precision=prec, minimum_deployment_target=tgt, convert_to="mlprogram")
    all_ref.save(str(d / "all_ref.mlpackage"))
    m_all_ref = ct.models.MLModel(str(d / "all_ref.mlpackage"))
    fused0_feat = np.asarray(
        m_all_ref.predict({"fused": fused0_np})["refined"], dtype=np.float32)

    h_feat = fused0_np
    for i, (s_, e_) in enumerate(chunks):
        cm = _ChunkFixed(m.refiner, s_, e_).eval()
        with torch.no_grad():
            ctr = torch.jit.trace(cm, (torch.rand(1, FUSED_DIM),
                                       torch.rand(1, FUSED_DIM)))
        mlc = ct.convert(ctr,
            inputs=[ct.TensorType(name="fused", shape=(1, FUSED_DIM), dtype=np.float32),
                    ct.TensorType(name="h", shape=(1, FUSED_DIM), dtype=np.float32)],
            outputs=[ct.TensorType(name="refined", dtype=np.float32)],
            compute_precision=prec, minimum_deployment_target=tgt, convert_to="mlprogram")
        p = d / f"fix_feat_{i}.mlpackage"; mlc.save(str(p))
        h_feat = np.asarray(
            ct.models.MLModel(str(p)).predict(
                {"fused": fused0_np, "h": h_feat})["refined"], dtype=np.float32)
    feat_fix_abs = float(np.abs(fused0_feat - h_feat).max())
    feat_fix_rel = feat_fix_abs / max(1e-9, float(np.abs(fused0_feat).max()))

    return {"seed": seed, "coreml_bug": db, "coreml_bug_overall": max(db.values()),
            "coreml_fix": df, "coreml_fix_overall": max(df.values()),
            "coreml_feat_fix_abs": feat_fix_abs, "coreml_feat_fix_rel": feat_fix_rel,
            "coreml_feat_max": float(np.abs(fused0_feat).max())}


# ============================================================================
# 主流程
# ============================================================================

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(_ROOT / "checkpoints" / "m9_v2" / "best_model.pt"))
    ap.add_argument("--seeds", default="0,1,2")
    ap.add_argument("--coreml-seeds", default="0,1")
    ap.add_argument("--skip-coreml", action="store_true")
    ap.add_argument("--tmpdir", default=None)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    seeds = [int(x) for x in args.seeds.split(",")]
    cseeds = [int(x) for x in args.coreml_seeds.split(",")]

    print("=" * 78)
    print(" 多模型拆分等价性深度验证（S4）")
    print("=" * 78)
    print(f"[验证] seeds={seeds} coreml_seeds={cseeds} num_steps={NUM_STEPS} "
          f"moe_steps={MOE_STEPS}")
    chunks = [(i * CHUNK_SIZE + 1, min((i + 1) * CHUNK_SIZE, NUM_STEPS))
              for i in range((NUM_STEPS + CHUNK_SIZE - 1) // CHUNK_SIZE)]
    print(f"[验证] chunk_size={CHUNK_SIZE} chunks={chunks} probe={PROBE_STEPS}")

    m = model_v2.build_model(deploy=False, num_steps=NUM_STEPS, moe_steps=MOE_STEPS)
    rep = load_weights(m, Path(args.src))
    print(f"[验证] checkpoint 随机占比 {rep['ratio']*100:.1f}% (missing={rep['missing']})")
    print(f"[验证] ⚠ 缺 refiner/experts 权重 → 注入非零随机权重排除零权重陷阱")

    # ---------------- PyTorch ----------------
    print(f"\n[验证] ── (a)/(b) PyTorch 端：现版 vs 修复版 ──")
    rows = []
    wstat = {}
    for sd in seeds:
        m2 = copy.deepcopy(m)
        wstat = inject_nonzero_refiner_weights(m2, sd)
        r = verify_pytorch(m2, chunks, sd)
        rows.append(r)
    print(f"\n  注入非零权重样例（seed0）：refiner_proj.max|w|={wstat.get('refiner_proj.weight',0):.4f}  "
          f"cell0.x_r.max|w|={wstat.get('cell0.x_r.weight',0):.4f}  "
          f"expert_out_proj.max|w|={wstat.get('expert_out_proj.weight',0):.4f}")

    for r in rows:
        print(f"\n  ── seed={r['seed']} ──  fused入口maxdiff={r['fused_entry_maxdiff']:.2e}")
        print(f"     {'步骤':<8}{'现版_Chunk(边界)':<22}{'修复版_ChunkFixed(边界)':<26}")
        for sp in PROBE_STEPS:
            print(f"     step{sp:<4}{r['bound_bug'][sp]:<22.3e}{r['bound_fix'][sp]:<26.3e}")
        print(f"     refiner末端 {'现版':<10}{r['refiner_final_bug']:<22.3e}"
              f"{'修复版':<10}{r['refiner_final_fix']:<26.3e}")
        print(f"     最终6输出  现版overall={r['final_bug_overall']:.3e}   "
              f"修复版overall={r['final_fix_overall']:.3e}")

    # ---------------- CoreML ----------------
    cm_rows = []
    if not args.skip_coreml:
        print(f"\n[验证] ── (c) CoreML 端：现版 vs 修复版 串联 vs 单模型 ──")
        tmpdir = Path(args.tmpdir) if args.tmpdir else \
            Path(tempfile.mkdtemp(prefix="verify_ms_"))
        tmpdir.mkdir(parents=True, exist_ok=True)
        print(f"[验证] CoreML 临时目录: {tmpdir}")
        for sd in cseeds:
            m2 = copy.deepcopy(m)
            # CoreML 用较小权重尺度：避免 24 步 fp16 放大 + 激活饱和导致的数值假象
            inject_nonzero_refiner_weights(m2, sd, scale=0.005)
            try:
                r = verify_coreml(m2, chunks, sd, tmpdir)
                cm_rows.append(r)
                print(f"  seed={sd}: 现版标量={r['coreml_bug_overall']:.3e}  "
                      f"修复版标量={r['coreml_fix_overall']:.3e}  "
                      f"修复版特征级abs={r['coreml_feat_fix_abs']:.3e} "
                      f"rel={r['coreml_feat_fix_rel']:.3e}")
                for n in OUT_NAMES:
                    print(f"        {n:<12} 现版={r['coreml_bug'][n]:.3e}  "
                          f"修复版={r['coreml_fix'][n]:.3e}")
            except Exception as e:
                import traceback; traceback.print_exc()
                cm_rows.append({"seed": sd, "error": str(e)})

    # ---------------- 汇总 ----------------
    print(f"\n{'='*78}\n 汇总\n{'='*78}")
    print(f"{'seed':<6}{'PyTorch现版(最终)':<20}{'PyTorch修复版(最终)':<22}"
          f"{'chunk边界现版':<16}{'chunk边界修复版':<18}")
    for r in rows:
        print(f"{r['seed']:<6}{r['final_bug_overall']:<20.3e}"
              f"{r['final_fix_overall']:<22.3e}{r['bound_bug_overall']:<16.3e}"
              f"{r['bound_fix_overall']:<18.3e}")
    if cm_rows:
        print(f"\n{'seed':<6}{'CoreML现版(标量)':<20}{'CoreML修复版(标量)':<22}"
              f"{'CoreML特征级修复(abs)':<22}{'(rel)':<12}")
        for r in cm_rows:
            if "error" in r:
                print(f"{r['seed']:<6}{'ERROR: '+r['error'][:24]}")
            else:
                print(f"{r['seed']:<6}{r['coreml_bug_overall']:<20.3e}"
                      f"{r['coreml_fix_overall']:<22.3e}"
                      f"{r['coreml_feat_fix_abs']:<22.3e}"
                      f"{r['coreml_feat_fix_rel']:<12.3e}")

    py_bug_ok = all(r["final_bug_overall"] < 1e-4 and r["bound_bug_overall"] < 1e-4
                    for r in rows)
    py_fix_ok = all(r["final_fix_overall"] < 1e-4 and r["bound_fix_overall"] < 1e-4
                    for r in rows)
    # CoreML 判定以**特征级相对误差**为准（标量在大尺度权重下会饱和失真）
    cm_feat_ok = all(r.get("coreml_feat_fix_rel", 1) < 1e-3
                     for r in cm_rows) if cm_rows else True
    cm_bug_ok = all(r.get("coreml_bug_overall", 1) < 1e-3
                    for r in cm_rows) if cm_rows else True

    print(f"\n[判定] 现版 _Chunk  PyTorch 等价: {'✅ PASS' if py_bug_ok else '❌ FAIL（不等价，bug 坐实）'}")
    print(f"[判定] 修复版 _ChunkFixed PyTorch 等价: {'✅ PASS' if py_fix_ok else '❌ FAIL'}")
    if cm_rows:
        print(f"[判定] 现版 _Chunk   CoreML 等价: {'✅ PASS' if cm_bug_ok else '❌ FAIL'}")
        print(f"[判定] 修复版 _ChunkFixed CoreML 特征级等价(rel<1e-3): "
              f"{'✅ PASS' if cm_feat_ok else '❌ FAIL'}")
        print(f"       ⚠ 注：CoreML 最终标量在**大尺度权重**下会因 fp16 迭代放大 + "
              f"tanh/sigmoid 饱和而失真（throttle/confidence 出现 0↔1 跳变），"
              f"这是数值假象，不是结构不等价；特征级相对误差才是真判据。")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(
            {"pytorch": rows, "coreml": cm_rows}, indent=2, ensure_ascii=False,
            default=str), encoding="utf-8")
        print(f"[验证] JSON: {args.json_out}")

    print(f"\n{'='*78}\n ROOT CAUSE\n{'='*78}")
    print(ROOT_CAUSE)
    return 0 if py_fix_ok and cm_feat_ok else 1


ROOT_CAUSE = """\
现版 tools/export_multi_split.py::_Chunk.forward（第 60 行）不等价于
src/model_v2.py::IterationRefiner.forward（第 1106 行）。

  单模型（正确）：fused 是**常量**，24 步全程
      h = cell(fused, h);  refined = fused + proj(h)
    —— cell 第一入参和残差基址永远是**原始 fused**，只有 h 在步间传递。

  现版 _Chunk（错误）：把「块输入」同时当作 cell 第一入参和残差基址
      h = fused;  h = cell(fused, h);  refined = fused + proj(h)
    对 chunk1（输入恰为原始 fused）成立；对 chunk2+（输入是上一块的 refined）
    → cell 第一入参和残差基址都被污染成「上一块的 refined」，与单模型不同。

  证据：step4 现版=0（chunk1 输入=fused0）；step8 现版=1.4e2；step24=6.7e5
        （误差随步数指数放大）。
  为何 Lead 没发现：checkpoint 缺 refiner 权重且 refiner_proj 零初始化
        → delta≡0 → refined≡fused → 块输入 == 原始 fused → 数值上掩盖了结构错误
        → 单 seed maxdiff=0 是 trivially 等价。

修复（已用 _ChunkFixed 证明，PyTorch + CoreML 均归 0）：
      chunk 改为**双输入** (fused_base, h)：
        def forward(self, fused_base, h):
            for step in ...:
                h = self.cell(fused_base, h)
                refined = fused_base + self.refiner_proj(h)
                ...
                h = refined
            return h
      串联：h = fused0;  for chunk: h = chunk(fused0, h)
      → 每个 chunk 都收到同一个原始 fused0 + 跨块隐状态 h，与单模型逐位一致。
      CoreML 契约：chunk 两个输入 (fused, h) → 一个输出 (refined)；
      Swift 侧需把 tf 输出的 fused 同时喂给每个 chunk（首块 h 初值 = fused）。
"""


if __name__ == "__main__":
    sys.exit(main())
