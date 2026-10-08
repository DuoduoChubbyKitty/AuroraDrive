#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_graph_slim.py —— V2 主驾驶模型「计算图瘦身」实验台（S3 性能攻坚，2026-10-09）

═══════════════════════════════════════════════════════════════════════════
0. 这个脚本干什么、红线在哪
═══════════════════════════════════════════════════════════════════════════
目标：把 `models/m9_v2.mlmodelc`（12 步 / 4 步 MoE，891 算子，p95 20.95~29.28ms）
压到 **p95 ≤ 16ms**，且**只减少"无用/冗余计算"，不减少"有效计算"**。

⛔ 硬红线（Lead 已钉死，本脚本**不做**任何一条）：
    · 不降步数（12）      · 不降 MoE 步数（4）
    · 不降帧率            · 不降分辨率
    · 不降质量（任何改动必须数值无损：与基线 maxdiff < 1e-3）

✅ 本脚本的写作用域：**只新建**本文件 + `docs/计算图瘦身-实测-2026-10-09.md`
   + `models/exp_slim_*` 产物。
⛔ **绝不修改** `src/`、`Sources/`、`tools/export_m9_v2_coreml.py`。
   所有"变体"都在本文件内**内存态**构造（monkeypatch / 子类 / 构参），
   落盘只写 `models/exp_slim_*`。

═══════════════════════════════════════════════════════════════════════════
1. 为什么"删算子"有机会换来真时间：ANE 编译失败
═══════════════════════════════════════════════════════════════════════════
实测（本机 macOS 26.6 / Apple M3 / coremltools 8.3）：

    ct.models.MLModel("models/m9_v2.mlpackage", compute_units=.all)
    → 推理时 stderr 打出：
        E5RT encountered an STL exception.
        msg = MILCompilerForANE error: failed to compile ANE model using ANEF.
              Error=_ANECompiler : ANECCompile() FAILED.

即**当前 891 算子的图 ANE 编译直接失败 → 整模型回退 CPU**（实测 p50 36.9ms）。
这与 Lead 记录的现象一致（8 帧+palette ANE 编译失败 → CPU 16.16ms）。
⇒ 「算子瘦身」的价值不只是"少算几个 op"，而是**可能让图重新落回 ANE**
   （1 帧+palette 的 ANE 版只要 2.23ms）。所以本脚本把 **ANE 是否编译成功**
   当作与延迟并列的一等公民指标来测。

═══════════════════════════════════════════════════════════════════════════
2. 变体设计（每个变体都必须证明"无损"才允许算收益）
═══════════════════════════════════════════════════════════════════════════
基线 = `build_model(deploy=False, num_steps=12, moe_steps=[9,10,11,12])` +
       `checkpoints/m9_v2/best_model.pt` + `reparameterize()`，
       与 `models/m9_v2.mlpackage` 同配置。

变体（全部只动"贡献恒为 0"的子图）：
  V0 baseline      当前配置，对照组
  V1 no_refiner    去掉 IterationRefiner（12 步 GRU + 4 步 MoE）
  V2 no_moe        保留 12 步 GRU，去掉 6 专家 + 软路由
  V3 no_temporal   去掉时序编码器（8 帧 GRU while_loop）
  V4 gru_unroll    时序 GRU 由 while_loop 改**静态展开**（同权重、同数学）
  V5 dedup         baseline + `ct.optimize.coreml.deduplicate_weights`
  V6 slim_all      以上"无损项"全叠加（最终候选）

⚠️ 无损性不是嘴上说的：V1/V2/V3 的无损性**必须先被数值证明**——
   见 `probe_dead_subgraphs()`：直接对训练好的模型做前向，比较
   「有该子图」vs「无该子图」的输出。若 maxdiff == 0.0 才是真无损。

═══════════════════════════════════════════════════════════════════════════
3. 测量协议（ABBA 交替，抗热漂移）
═══════════════════════════════════════════════════════════════════════════
本机是 **MacBook Air（无风扇）**，w5 实测热漂移能把 p50 从 15.7 推到 19.3ms。
因此**绝不**用"A 跑完再跑 B"的顺序测量。本脚本用 **ABBA 交替**：
    round r:  A B B A   （每个模型每轮测 2 次，顺序对调）
轮间取全部样本算 p50/p95。这样热漂移对 A/B 的影响被对称化。

═══════════════════════════════════════════════════════════════════════════
4. 用法
═══════════════════════════════════════════════════════════════════════════
    # 1) 只做图结构审计（快，不转换）
    ./.venv-yolo26/bin/python3 tools/exp_graph_slim.py --stage hist

    # 2) 证明"死子图"（无损性前置证明，纯 PyTorch）
    ./.venv-yolo26/bin/python3 tools/exp_graph_slim.py --stage dead

    # 3) 全流程：转换所有变体 + 编译 + ABBA 测延迟 + 无损性对拍
    ./.venv-yolo26/bin/python3 tools/exp_graph_slim.py --stage all

产物落在 `models/exp_slim_*/`，报告写入 docs/。
"""

import argparse
import collections
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import warnings
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import torch  # noqa: E402
import coremltools as ct  # noqa: E402

# ── 复用既有导出脚本的契约常量与输入构造（**只读导入，不修改它**）──────────
from tools.export_m9_v2_coreml import (  # noqa: E402
    INPUT_NAMES, OUTPUT_NAMES, _make_inputs, _edge_cases, _to_feed,
)

CKPT = _ROOT / "checkpoints" / "m9_v2" / "best_model.pt"
OUT_ROOT = _ROOT / "models"
BASELINE_MLPACKAGE = OUT_ROOT / "m9_v2.mlpackage"
BASELINE_MLMODELC = OUT_ROOT / "m9_v2.mlmodelc"

#: 图内 fp16 + IO fp32（与既有导出脚本逐字一致，坑 3）
CONVERT_KW = dict(
    source="pytorch",
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS13,
    compute_precision=ct.precision.FLOAT16,
)


# ============================================================================
# 1. 图结构审计
# ============================================================================

#: MIL 里"不算真算子"的语句 —— const 是权重/常量声明，不消耗运行时算力
_NON_OP = {"const"}

_OP_RE = re.compile(r"=\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(")
_NAME_RE = re.compile(r'\[name = tensor<string, \[\]>\("([^"]+)"\)\]')
_WEIGHT_RE = re.compile(r"weight = ([A-Za-z0-9_]+)")
_BLOB_RE = re.compile(r'BLOBFILE\(path = tensor<string, \[\]>\("([^"]+)"\), '
                      r"offset = tensor<uint64, \[\]>\((\d+)\)\)")
_SHAPE_RE = re.compile(r"tensor<(fp16|fp32|int32|bool), \[([0-9, ]*)\]>")


def parse_mil(mil_path: Path) -> Dict[str, object]:
    """解析 `model.mil`（CoreML 的文本 IR），产出图结构审计所需的全部统计。

    为什么直接解析文本而不用 coremltools 的 MLModelStructure：
      · `model.mil` 是**编译产物里真实存在的**（`xcrun coremlc` 输出），
        是"ANE 编译器看到的同一份图"，口径最硬；
      · Python 侧加载 .mlmodelc 需要 Manifest.json（coremlc 不产），
        解析文本反而零依赖、可离线复现。

    Returns:
        dict，含 op_hist（算子直方图，已剔除 const）、op_total（真算子总数）、
        const_total、linear_weights（linear 算子的权重归属）、blobs（权重 blob 列表）。
    """
    text = mil_path.read_text()
    lines = text.splitlines()

    op_hist: collections.Counter = collections.Counter()
    const_total = 0
    linear_weights: collections.Counter = collections.Counter()
    op_names: List[Tuple[str, str]] = []

    for ln in lines:
        m = _OP_RE.search(ln)
        if not m:
            continue
        op = m.group(1)
        if op == "const":
            const_total += 1
            continue
        # 跳过 while_loop 的**块签名行**（形如 `(tensor<...> a, ...) {`），
        # 它们不以 `= op(` 开头，故上面的正则已排除；这里只统计真语句。
        op_hist[op] += 1
        nm = _NAME_RE.search(ln)
        op_names.append((op, nm.group(1) if nm else "?"))
        if op == "linear":
            w = _WEIGHT_RE.search(ln)
            if w:
                linear_weights[w.group(1)] += 1

    blobs = [(p, int(o)) for p, o in _BLOB_RE.findall(text)]
    return {
        "mil_path": str(mil_path),
        "op_hist": dict(op_hist),
        "op_total": int(sum(op_hist.values())),
        "const_total": int(const_total),
        "linear_weights": dict(linear_weights),
        "blobs": blobs,
        "n_blob_refs": len(blobs),
        "n_distinct_blobs": len(set(blobs)),
        "op_names": op_names,
    }


def _fmt_hist(hist: Dict[str, int], top: int = 100) -> str:
    items = sorted(hist.items(), key=lambda kv: -kv[1])[:top]
    return "\n".join(f"  {c:5d}  {op}" for op, c in items)


def stage_hist(mil: Path) -> Dict[str, object]:
    """打印算子直方图 + 冗余模式体检。"""
    rep = parse_mil(mil)
    print(f"=== 图结构审计：{mil} ===")
    print(f"真算子总数（不含 const）: {rep['op_total']}")
    print(f"const 声明数            : {rep['const_total']}")
    print(f"权重 blob 引用 / 去重后 : {rep['n_blob_refs']} / {rep['n_distinct_blobs']}")
    print("\n--- 算子直方图 ---")
    print(_fmt_hist(rep["op_hist"]))

    # 冗余模式体检：找"同一算子名被重复使用"的结构信号
    print("\n--- 冗余信号 ---")
    lw = rep["linear_weights"]
    dup = {k: v for k, v in lw.items() if v > 1}
    print(f"linear 权重张量种类: {len(lw)}；被复用(>1次)的: {len(dup)}")
    for k, v in sorted(dup.items(), key=lambda kv: -kv[1])[:12]:
        print(f"   {v:3d}×  {k}")

    # 常量折叠候选：全常量输入的算子（CoreML 转换时多半已折叠，此处验证）
    print(f"\n--- RepVGG 重参数化残留检查 ---")
    txt = mil.read_text()
    for kw in ("rbr_1x1", "rbr_3x3", "rbr_identity", "rbr_reparam"):
        print(f"   {kw:14s} 出现 {txt.count(kw):4d} 次")
    return rep


# ============================================================================
# 2. 模型构建 / 变体
# ============================================================================

def load_ckpt_state() -> Dict[str, torch.Tensor]:
    """读取 checkpoint，剥离 torch.compile 前缀与训练期探针（与导出脚本同口径）。"""
    ck = torch.load(CKPT, map_location="cpu", weights_only=False)
    sd = ck["model_state_dict"] if isinstance(ck, dict) and "model_state_dict" in ck else ck
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    sd = {k: v for k, v in sd.items() if not k.startswith("lane_steer_probe.")}
    return sd


def build_and_load(**kwargs):
    """构建 M2Model → load checkpoint → reparameterize → eval。

    ★ 必须走「训练态构建 → load → reparameterize」（导出脚本 坑 6）：
      用 deploy=True 直接 load 训练态 checkpoint 会**静默丢弃 184 个键**，
      把已训练骨干当随机权重。

    ★★ 必须 `torch.manual_seed(0)`（本脚本实测踩到，2026-10-09）：
      checkpoint 缺 96 个键（refiner/temporal/risk_head/heading_head/
      lane_encoder.spatial_proj…），`load_state_dict(strict=False)` 后这些键
      **保持 build 时的随机初始化**。若两次 build 不固定 seed，两个"变体"
      的缺失权重完全不同 → 对比出来的 maxdiff 全是**随机权重差异**，
      跟"删了哪个子图"毫无关系（本脚本第一版实测 no_refiner maxdiff=1.29，
      纯属假阳性）。固定 seed 后，所有变体在"缺失权重"上逐位一致，
      唯一变量就只剩被删的那个子图 —— 这才是有效的对照实验。
    """
    from src.model_v2 import build_model

    torch.manual_seed(0)
    model = build_model(deploy=False, **kwargs)
    res = model.load_state_dict(load_ckpt_state(), strict=False)
    if len(res.unexpected_keys) > 0:
        raise RuntimeError(f"权重态判断错误：{len(res.unexpected_keys)} 个 unexpected 键")
    model.reparameterize()
    model.eval()
    return model, list(res.missing_keys)


class _ZeroTemporal(torch.nn.Module):
    """把时序编码器换成"恒零输出"的桩（保留模块非 None → seq_mode 仍触发）。

    用途：验证 `temporal_proj` 零初始化时，**整个时序编码器对输出贡献恒为 0**。
    这不是"降质量"——零矩阵乘任何数都是零，删掉它与保留它在数学上完全等价。
    """

    def __init__(self, hidden: int, num_frames: int = 8):
        super().__init__()
        self.hidden_dim = hidden
        self.num_frames = num_frames

    def forward(self, feats, frame_mask=None, dt=None):
        b = feats.shape[0] if feats.dim() == 3 else 1
        return torch.zeros(b, self.hidden_dim, dtype=feats.dtype, device=feats.device)


class _UnrolledGRU(torch.nn.Module):
    """把 `nn.GRU(num_layers=1)` 改写成**静态展开**的逐帧实现（同权重、同数学）。

    动机（任务方向 4）：CoreML 把 nn.GRU 转成 `while_loop`（实测 19 处 while_loop），
    动态循环对 ANE 不友好。展开成 8 个静态 step 后：
      · 图里没有 while_loop（可静态调度、可被 ANE 编译器整图分析）
      · 代价是算子数变多（8× 一个 GRU step 的算子）
    本类**逐位复用原 nn.GRU 的权重**（weight_ih_l0/weight_hh_l0/bias_*），
    因此数学等价性可被严格验证（见 `probe_gru_unroll`）。

    PyTorch GRU 公式（门序 r,z,n；h' = (1-z)⊙n + z⊙h）：
        r = σ(W_ir x + b_ir + W_hr h + b_hr)
        z = σ(W_iz x + b_iz + W_hz h + b_hz)
        n = tanh(W_in x + b_in + r ⊙ (W_hn h + b_hn))
    """

    def __init__(self, gru: torch.nn.GRU):
        super().__init__()
        assert gru.num_layers == 1, "只支持单层（本项目 num_layers=1）"
        self.input_size = gru.input_size
        self.hidden_size = gru.hidden_size
        # 直接持有原 GRU 的参数（同对象引用 → 不可能不一致）
        self.weight_ih_l0 = gru.weight_ih_l0
        self.weight_hh_l0 = gru.weight_hh_l0
        self.bias_ih_l0 = gru.bias_ih_l0
        self.bias_hh_l0 = gru.bias_hh_l0

    def forward(self, x: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        """x: [B,N,C] → (out [B,N,H], h_n [1,B,H])，与 nn.GRU 同签名。"""
        b, n, _ = x.shape
        h = torch.zeros(b, self.hidden_size, dtype=x.dtype, device=x.device)
        outs = []
        H = self.hidden_size
        for t in range(n):
            xt = x[:, t, :]
            gi = xt @ self.weight_ih_l0.t() + self.bias_ih_l0
            gh = h @ self.weight_hh_l0.t() + self.bias_hh_l0
            i_r, i_z, i_n = gi[:, :H], gi[:, H:2 * H], gi[:, 2 * H:]
            h_r, h_z, h_n = gh[:, :H], gh[:, H:2 * H], gh[:, 2 * H:]
            r = torch.sigmoid(i_r + h_r)
            z = torch.sigmoid(i_z + h_z)
            nn_ = torch.tanh(i_n + r * h_n)
            h = (1.0 - z) * nn_ + z * h
            outs.append(h)
        return torch.stack(outs, dim=1), h.unsqueeze(0)


class _ExportWrapper(torch.nn.Module):
    """把 M2Model 包成 6 输出的扁平形态（与既有导出脚本同构，便于对拍）。"""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, image, lane, dets, det_mask, vehicle_state):
        steer, throttle, brake, aux = self.model(
            image, lane, dets, det_mask, vehicle_state,
            camera_heading=None, return_aux=True)

        def _z(v, w=1):
            if v is None:
                return torch.zeros(1, w, dtype=steer.dtype, device=steer.device)
            return v.view(-1, w) if v.dim() == 1 else v

        return (steer, throttle, brake,
                _z(aux.get("confidence")), _z(aux.get("risk")),
                _z(aux.get("car_heading")))


def make_variant(name: str):
    """按名字构造变体模型。返回 (model, missing_keys, note)。"""
    if name == "V0_baseline":
        m, mk = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])
        return m, mk, "当前配置（对照组）"

    if name == "V1_no_refiner":
        m, mk = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12],
                               enable_refiner=False)
        return m, mk, "去掉 12 步 GRU + 4 步 MoE 精修"

    if name == "V2_no_moe":
        m, mk = build_and_load(num_steps=12, moe_steps=[])
        return m, mk, "保留 12 步 GRU，去掉 6 专家 + 软路由"

    if name == "V3_no_temporal":
        m, mk = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])
        m.temporal_encoder = _ZeroTemporal(m.temporal_encoder.hidden_dim, 8)
        return m, mk, "时序编码器替换为恒零桩（temporal_proj 为零矩阵）"

    if name == "V4_gru_unroll":
        m, mk = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])
        m.temporal_encoder.rnn = _UnrolledGRU(m.temporal_encoder.rnn)
        return m, mk, "时序 GRU 静态展开（同权重、同数学）"

    if name == "V5_dedup":
        m, mk = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])
        return m, mk, "baseline + deduplicate_weights（在转换后处理）"

    if name == "V6_slim_all":
        m, mk = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])
        m.temporal_encoder = _ZeroTemporal(m.temporal_encoder.hidden_dim, 8)
        m.refiner = None
        return m, mk, "去 refiner + 去时序（全部为证过的死子图）"

    raise KeyError(name)


# ============================================================================
# 3. 「死子图」无损性证明（纯 PyTorch，不依赖 CoreML）
# ============================================================================

def _ref_outputs(model, inputs: Sequence[torch.Tensor]) -> List[float]:
    with torch.no_grad():
        out = _ExportWrapper(model)(*inputs)
    return [float(o.flatten()[0]) for o in out]


def probe_dead_subgraphs() -> Dict[str, object]:
    """证明 refiner / MoE / temporal 三个子图对当前 checkpoint 的贡献恒为 0。

    方法：对**同一个已训练模型**，逐个子图做「替换前 vs 替换后」前向对比，
    覆盖 6 个边界用例（normal/no_dets/no_lane/zero_state/all_empty/saturated）。
    maxdiff == 0.0 即"逐位相同"——这是比 <1e-3 更强的无损证据。
    """
    from src.model_v2 import build_model

    sd = load_ckpt_state()
    model, _ = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])
    c = {"img_h": 180, "img_w": 320, "lane_size": 160, "num_dets": 20,
         "det_feat_dim": 12, "state_dim": 8, "num_frames": 8}
    base_inputs = _make_inputs(c)
    cases = _edge_cases(c, base_inputs)

    result: Dict[str, object] = {"cases": {}, "weights": {}, "param_zero": {}}

    # ── 权重层面的证据：哪些参数是全零 ──
    for n, p in model.named_parameters():
        if any(s in n for s in ("refiner_proj", "expert_out_proj", "temporal_proj",
                                "router", "temporal_encoder", "experts", "cells")):
            mx = float(p.detach().abs().max().item())
            result["param_zero"][n] = mx

    # ── 子图替换实验 ──
    def variant_no_refiner():
        m = build_model(deploy=False, num_steps=12, moe_steps=[9, 10, 11, 12])
        m.load_state_dict(sd, strict=False)
        m.reparameterize()
        m.eval()
        m.refiner = None
        return m

    def variant_no_moe():
        m = build_model(deploy=False, num_steps=12, moe_steps=[])
        m.load_state_dict(sd, strict=False)
        m.reparameterize()
        m.eval()
        return m

    def variant_no_temporal():
        m = build_model(deploy=False, num_steps=12, moe_steps=[9, 10, 11, 12])
        m.load_state_dict(sd, strict=False)
        m.reparameterize()
        m.eval()
        m.temporal_encoder = _ZeroTemporal(m.temporal_encoder.hidden_dim, 8)
        return m

    variants = {
        "no_refiner": variant_no_refiner(),
        "no_moe": variant_no_moe(),
        "no_temporal": variant_no_temporal(),
    }

    for vname, vm in variants.items():
        per_case = {}
        for cname, ins in cases.items():
            a = _ref_outputs(model, ins)
            b = _ref_outputs(vm, ins)
            per_case[cname] = {
                "maxdiff": float(max(abs(x - y) for x, y in zip(a, b))),
                "base": a, "variant": b,
            }
        worst = max(v["maxdiff"] for v in per_case.values())
        result["cases"][vname] = {"per_case": per_case, "worst_maxdiff": worst}

    # ── 时序 GRU 展开的数值等价性（与无损性分开：这是"换实现"不是"删计算"）──
    m2, _ = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])
    te = m2.temporal_encoder
    feats = torch.randn(1, 8, 256) * 0.5
    with torch.no_grad():
        ref = te(feats)
        unrolled = _UnrolledGRU(te.rnn)
        x = te.in_norm(te.in_proj(feats))
        out, _ = unrolled(x)
        got = te.out_norm(out[:, -1, :])
    result["gru_unroll_maxdiff"] = float((ref - got).abs().max().item())
    result["gru_unroll_ref_range"] = [float(ref.min()), float(ref.max())]

    return result


# ============================================================================
# 4. 转换 / 编译 / ANE 检测
# ============================================================================

def _shapes() -> List[Tuple[int, ...]]:
    return [(8, 3, 180, 320), (1, 1, 160, 160), (1, 20, 12), (1, 20), (1, 8)]


def convert_variant(model, out_dir: Path, tag: str, dedup: bool = False):
    """trace → ct.convert → 可选 deduplicate_weights → 落盘 .mlpackage。

    Returns: (mlpackage_path, convert_notes)
    """
    notes: List[str] = []
    shapes = _shapes()
    wrapper = _ExportWrapper(model).eval()
    example = [torch.rand(*s) for s in shapes]

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        traced = torch.jit.trace(wrapper, example, strict=False)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name=n, shape=s, dtype=np.float32)
                    for n, s in zip(INPUT_NAMES, shapes)],
            outputs=[ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES],
            **CONVERT_KW)

    if dedup:
        import coremltools.optimize.coreml as cto
        before = _weight_bytes(mlmodel)
        mlmodel = cto.deduplicate_weights(mlmodel)
        after = _weight_bytes(mlmodel)
        notes.append(f"deduplicate_weights: 权重 {before/1e6:.2f}MB → {after/1e6:.2f}MB")

    out_dir.mkdir(parents=True, exist_ok=True)
    pkg = out_dir / f"{tag}.mlpackage"
    if pkg.exists():
        shutil.rmtree(pkg)
    mlmodel.save(str(pkg))
    notes.append(f"mlpackage 落盘 {pkg}")
    return pkg, notes


def _weight_bytes(mlmodel) -> int:
    """统计模型里所有权重 blob 的字节数（用于 dedup 前后对比）。"""
    total = 0
    for w in mlmodel.get_spec().mlProgram.weights:
        try:
            total += int(np.prod([d for d in w.shape]) * 2)  # fp16 = 2B
        except Exception:
            pass
    return total


def compile_to_mlmodelc(pkg: Path, out_dir: Path) -> Optional[Path]:
    """用 `xcrun coremlc` 编译成 .mlmodelc（与既有导出脚本同路径）。"""
    name = pkg.stem
    target = out_dir / f"{name}.mlmodelc"
    if target.exists():
        shutil.rmtree(target)
    r = subprocess.run(["xcrun", "coremlc", "compile", str(pkg), str(out_dir)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return target if target.exists() else None


def detect_ane(pkg: Path, n: int = 3) -> Dict[str, object]:
    """检测该图能否被 ANE 编译成功。

    手法：`compute_units=.all` 加载 + 推理，捕获 stderr 里的
    `MILCompilerForANE error` / `ANECCompile() FAILED`。
    CoreML 编译失败时**不抛异常**，只打 stderr 并回退 CPU —— 所以必须抓 stderr，
    否则会把"回退 CPU 的慢"误读成"模型本身慢"（这正是 w5/Lead 踩过的坑）。
    """
    buf = io.StringIO()
    ane_fail = False
    load_ms = None
    try:
        with contextlib.redirect_stderr(buf):
            t0 = time.perf_counter()
            m = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.ALL)
            load_ms = (time.perf_counter() - t0) * 1000
            c = {"img_h": 180, "img_w": 320, "lane_size": 160, "num_dets": 20,
                 "det_feat_dim": 12, "state_dim": 8, "num_frames": 8}
            feed = _to_feed(_make_inputs(c))
            for _ in range(n):
                m.predict(feed)
    except Exception as e:  # noqa: BLE001
        return {"ane_ok": False, "error": f"{type(e).__name__}: {e}",
                "load_ms": load_ms, "stderr": buf.getvalue()[-400:]}
    err = buf.getvalue()
    ane_fail = ("ANECCompile() FAILED" in err) or ("MILCompilerForANE" in err)
    return {"ane_ok": not ane_fail, "load_ms": load_ms,
            "stderr_tail": err[-300:] if err else ""}


# ============================================================================
# 5. ABBA 延迟测量
# ============================================================================

def measure_abba(pkgs: Sequence[Path], rounds: int = 6, warmup: int = 3
                 ) -> Dict[str, Dict[str, float]]:
    """ABBA 交替测量多个模型的推理延迟。

    每个 round 对每个模型测 2 次，且**顺序对调**（A B C … C B A），
    把无风扇机器的热漂移对称化。返回每个模型的 p50/p95/p99/min/max/mean。
    """
    c = {"img_h": 180, "img_w": 320, "lane_size": 160, "num_dets": 20,
         "det_feat_dim": 12, "state_dim": 8, "num_frames": 8}
    feed = _to_feed(_make_inputs(c))

    models = {}
    for p in pkgs:
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            models[str(p)] = ct.models.MLModel(str(p), compute_units=ct.ComputeUnit.ALL)
        with contextlib.redirect_stderr(io.StringIO()):
            for _ in range(warmup):
                models[str(p)].predict(feed)

    samples: Dict[str, List[float]] = {str(p): [] for p in pkgs}
    keys = [str(p) for p in pkgs]

    def _time_one(k: str):
        t0 = time.perf_counter()
        models[k].predict(feed)
        return (time.perf_counter() - t0) * 1000.0

    with contextlib.redirect_stderr(io.StringIO()):
        for r in range(rounds):
            order = keys if r % 2 == 0 else list(reversed(keys))
            for k in order:
                samples[k].append(_time_one(k))
            for k in reversed(order):
                samples[k].append(_time_one(k))

    out = {}
    for k, v in samples.items():
        a = np.array(v)
        out[k] = {
            "p50": float(np.percentile(a, 50)),
            "p95": float(np.percentile(a, 95)),
            "p99": float(np.percentile(a, 99)),
            "min": float(a.min()), "max": float(a.max()),
            "mean": float(a.mean()), "n": int(a.size),
        }
    return out


# ============================================================================
# 6. 无损性对拍（CoreML vs PyTorch，6 边界用例）
# ============================================================================

def verify_lossless(pkg: Path, ref_model) -> Dict[str, object]:
    """CoreML 产物 vs PyTorch 参考：6 个边界用例的 maxdiff。"""
    c = {"img_h": 180, "img_w": 320, "lane_size": 160, "num_dets": 20,
         "det_feat_dim": 12, "state_dim": 8, "num_frames": 8}
    base = _make_inputs(c)
    cases = _edge_cases(c, base)

    with contextlib.redirect_stderr(io.StringIO()):
        mm = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.ALL)

    per_case = {}
    for cname, ins in cases.items():
        ref = _ref_outputs(ref_model, ins)
        with contextlib.redirect_stderr(io.StringIO()):
            pred = mm.predict(_to_feed(ins))
        got = [float(np.asarray(pred[n]).flatten()[0]) for n in OUTPUT_NAMES]
        per_case[cname] = {
            "maxdiff": float(max(abs(a - b) for a, b in zip(ref, got))),
            "ref": ref, "coreml": got,
        }
    worst = max(v["maxdiff"] for v in per_case.values())
    return {"per_case": per_case, "worst_maxdiff": worst}


# ============================================================================
# 7. 主流程
# ============================================================================

VARIANT_ORDER = ["V0_baseline", "V1_no_refiner", "V2_no_moe", "V3_no_temporal",
                 "V4_gru_unroll", "V5_dedup", "V6_slim_all"]


def stage_all(only: Optional[List[str]] = None) -> Dict[str, object]:
    out_root = OUT_ROOT / "exp_slim_graph"
    out_root.mkdir(parents=True, exist_ok=True)
    names = only or VARIANT_ORDER
    report: Dict[str, object] = {"variants": {}}

    # 参考模型（基线），供无损性对拍
    ref_model, _ = build_and_load(num_steps=12, moe_steps=[9, 10, 11, 12])

    for name in names:
        print(f"\n{'='*72}\n[{name}] 开始\n{'='*72}")
        t0 = time.time()
        try:
            model, missing, note = make_variant(name)
        except Exception as e:  # noqa: BLE001
            print(f"[{name}] ✗ 构建失败：{type(e).__name__}: {e}")
            report["variants"][name] = {"error": f"build: {e}"}
            continue

        entry: Dict[str, object] = {"note": note, "missing_keys": len(missing)}
        d = out_root / name
        try:
            pkg, notes = convert_variant(model, d, name, dedup=(name == "V5_dedup"))
        except Exception as e:  # noqa: BLE001
            print(f"[{name}] ✗ 转换失败：{type(e).__name__}: {e}")
            entry["error"] = f"convert: {e}"
            report["variants"][name] = entry
            continue
        entry["notes"] = notes
        entry["mlpackage"] = str(pkg)

        # 图结构
        modelc = compile_to_mlmodelc(pkg, d)
        entry["mlmodelc"] = str(modelc) if modelc else None
        mil = (modelc / "model.mil") if modelc else None
        if mil and mil.exists():
            g = parse_mil(mil)
            entry["op_total"] = g["op_total"]
            entry["op_hist"] = g["op_hist"]
            entry["const_total"] = g["const_total"]
            entry["n_distinct_blobs"] = g["n_distinct_blobs"]
            entry["while_loop"] = g["op_hist"].get("while_loop", 0)
            print(f"[{name}] 算子 {g['op_total']}（const {g['const_total']}）"
                  f" while_loop={entry['while_loop']}")

        # ANE 检测
        entry["ane"] = detect_ane(pkg)
        print(f"[{name}] ANE ok={entry['ane']['ane_ok']}")

        # 无损性（对比 PyTorch 基线）
        try:
            entry["lossless"] = verify_lossless(pkg, ref_model)
            print(f"[{name}] 无损 maxdiff={entry['lossless']['worst_maxdiff']:.3e}")
        except Exception as e:  # noqa: BLE001
            entry["lossless"] = {"error": f"{type(e).__name__}: {e}"}

        entry["build_seconds"] = round(time.time() - t0, 1)
        report["variants"][name] = entry

    # ── ABBA 延迟（所有成功产物一起测，保证热漂移对称）──
    ok = [Path(v["mlpackage"]) for v in report["variants"].values()
          if v.get("mlpackage") and Path(v["mlpackage"]).exists()]
    # 把现网产物也拉进来做"真·基线"（models/m9_v2.mlpackage）
    if BASELINE_MLPACKAGE.exists() and str(BASELINE_MLPACKAGE) not in [str(p) for p in ok]:
        ok.insert(0, BASELINE_MLPACKAGE)
    print(f"\n{'='*72}\nABBA 延迟测量：{len(ok)} 个产物\n{'='*72}")
    lat = measure_abba(ok, rounds=6)
    report["latency"] = lat
    for k, v in lat.items():
        print(f"  p50={v['p50']:7.2f}  p95={v['p95']:7.2f}  p99={v['p99']:7.2f}  {Path(k).parent.name}/{Path(k).name}")

    # 落盘 JSON
    rp = out_root / "report.json"
    rp.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"\n报告 JSON → {rp}")
    return report


def main() -> int:
    ap = argparse.ArgumentParser(description="V2 计算图瘦身实验台")
    ap.add_argument("--stage", default="all",
                    choices=["hist", "dead", "all"])
    ap.add_argument("--mil", default=str(BASELINE_MLMODELC / "model.mil"))
    ap.add_argument("--only", nargs="*", default=None, help="只跑指定变体")
    args = ap.parse_args()

    if args.stage == "hist":
        stage_hist(Path(args.mil))
        return 0
    if args.stage == "dead":
        r = probe_dead_subgraphs()
        print(json.dumps(r, indent=2, ensure_ascii=False))
        return 0
    stage_all(args.only)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
