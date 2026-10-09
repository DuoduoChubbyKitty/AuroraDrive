#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
S6 · 量化与权重压缩调优（ANE 编译边界专项）

================================================================================
0. 这个脚本回答什么
================================================================================
Lead 的硬目标：主驾驶模型 V2 压到 p95 ≤ 16ms，红线「不降步数(12)、不降 MoE(4)、
不降帧率、不降分辨率、不降质量」。

假设（本次要证伪/证实）：**4bit 量化让图更小 → ANE 可能就能编译 8 帧图了**。

本脚本用**单变量对照 + 确定性 ANE 判据 + 真机 ABBA 计时 + 逐用例精度实测**
把这个问题一次问死。

================================================================================
1. ★★ 方法论核心：ANE 判据不再靠"耗时比值"
================================================================================
既有做法（`/tmp/adt_inspect/decisive_ane.py`）用 `ANE_ms / CPU_ms < 0.85` 判
"ANE 是否生效"。该判据有三个毛病：
  (a) 受本机负载漂移影响（文档自己写了"单次波动可达 2×"）
  (b) 无法区分"ANE 编译失败退 CPU"与"ANE 编译成功但更慢"
  (c) 不能回答"**为什么**失败"

本脚本改用 **MLComputePlan（CoreML 官方 API）**：对图中每个算子问
`get_compute_device_usage_for_mlprogram_operation(op).preferred_compute_device`，
统计落在 `MLNeuralEngineComputeDevice` / `MLCPUComputeDevice` 的算子数。

实测标定（本机 macOS 26.6.2 / M3 / coremltools 8.3）：
  · ANE 可用模型  → ANE 算子 > 0 且 CPU 算子 == 0   （1帧int8: 86 ANE / 0 CPU）
  · ANE 失败模型  → ANE 算子 == 0 且 CPU 算子 > 0   （8帧fp16: 0 ANE / 453 CPU）
这是一个**确定性、可复现、不受负载影响**的二元判据，且能定位到算子级。
耗时（ABBA）作为**第二证据**并行采集，两者一致才算结论成立。

================================================================================
2. ★ 精度口径（必须与结论一起引用，否则是假绿）
================================================================================
    · 偏差基准 = **同一次 trace 出来的 fp16 图**（不是 PyTorch），
      这样才能把"量化引入的偏差"从"trace/转换引入的偏差"里剥离出来。
    · 判定红线：`maxdiff < 1e-3` 才算**无损**；≥ 1e-3 一律标注 **有损**。
    · 用例集复用 `tools/export_m9_v2_int8.py` 的 6 个契约用例 + lane 专项 + 时序序列，
      保证与项目既有精度口径同源可比。
    · ⚠️ **权重状态警告**：`checkpoints/m9_v2/best_model.pt` 只有 240 个键
      （image_encoder/lane_encoder/det_encoder/fusion_head/state_encoder），
      **缺 refiner/experts/temporal/heads** → 契约记录 `missing_param_ratio=65.74%`。
      因此本脚本测的是「**同一组权重下量化引入的偏差**」（这个量测是有效的），
      但**绝对输出值无驾驶意义**。报告里必须照抄这条。

================================================================================
3. 实验矩阵
================================================================================
  phase=rootcause : 时间维消融（fp16，无量化）→ 定位 ANE 失败的真凶
      A1 8帧+时序(GRU)   A2 8帧+无时序   A3 1帧+时序   A4 1帧+无时序
  phase=sweep     : 8帧+时序（= 部署形态）全量化方案扫描
      fp16 / pal{8,6,4}kmeans / pal{8,4}uniform / lin{int8,int4}
      / pal4+关键头保8bit / pal{8,4} 不保 fp16
  phase=frames    : 帧数 × 量化 的图大小-ANE 阈值扫描（1/2/4/8 帧）

用法
----
    ./.venv-yolo26/bin/python3 tools/exp_quant_tune.py --phase rootcause
    ./.venv-yolo26/bin/python3 tools/exp_quant_tune.py --phase sweep
    ./.venv-yolo26/bin/python3 tools/exp_quant_tune.py --phase frames
    # 全部（耗时最长，建议后台跑）
    ./.venv-yolo26/bin/python3 tools/exp_quant_tune.py --phase all

产物
----
    models/exp_quant_work/            中间产物（mlpackage / traced / 编译缓存）
    models/exp_quant_<tag>.mlmodelc   关键方案的编译产物（可直接给 Swift 侧试）
    models/exp_quant_report.json      机器可读全量数据（报告的唯一数据源）
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import sys
import time
import warnings
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

warnings.simplefilter("ignore")

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import numpy as np  # noqa: E402
import torch  # noqa: E402

import coremltools as ct  # noqa: E402
import coremltools.optimize.coreml as cto  # noqa: E402
from coremltools.models.compute_plan import MLComputePlan  # noqa: E402

# ============================================================================
# 契约常量（与 export_m9_v2_coreml.py / export_m9_v2_int8.py 逐字一致）
# ============================================================================
INPUT_NAMES: Tuple[str, ...] = ("image", "lane", "dets", "det_mask", "vehicle_state")
OUTPUT_NAMES: Tuple[str, ...] = ("steer", "throttle", "brake",
                                 "confidence", "risk", "car_heading")

#: 关键分支（保 fp16 的对象）—— 与 export_m9_v2_int8.py 的 DEFAULT_PRESERVE_PREFIXES 同源
PRESERVE_PREFIXES: Tuple[str, ...] = ("lane_encoder.", "fusion_head.")

WORK = _ROOT / "models" / "exp_quant_work"
REPORT = _ROOT / "models" / "exp_quant_report.json"
CKPT = _ROOT / "checkpoints" / "m9_v2" / "best_model.pt"

#: 精度红线：maxdiff ≥ 此值 = 有损
LOSSLESS_TOL = 1e-3

#: ANE 判定阈值（耗时第二证据用）
ANE_RATIO_OK = 0.85


# ============================================================================
# 0. 环境自检（先把"这个 API 到底存不存在"钉死，别写完才发现没有）
# ============================================================================
def api_availability() -> Dict[str, Any]:
    """探测 coremltools 各量化 API 是否存在（任务书提到的两个在 8.3 里没有）。"""
    avail = {
        "coremltools_version": ct.__version__,
        "palettize_weights": hasattr(cto, "palettize_weights"),
        "linear_quantize_weights": hasattr(cto, "linear_quantize_weights"),
        # ★ 任务书要求试的两个 API：
        "op_palettization": hasattr(cto, "op_palettization"),
        "deduplicate_weights": hasattr(cto, "deduplicate_weights"),
        "get_weights_metadata": hasattr(cto, "get_weights_metadata"),
        "MLComputePlan": True,
    }
    # 逐算子 palettize 的**等价物**：OptimizationConfig(op_name_configs=...)
    # —— ct8.3 没有 op_palettization() 这个函数，但 op_name_configs 就是逐算子配置。
    avail["op_name_configs_equivalent"] = True
    return avail


# ============================================================================
# 1. 模型构建 / trace / 转换
# ============================================================================
class _ExportWrapper(torch.nn.Module):
    """把 M2Model 摊平成 6 张量（与 export_m9_v2_int8.py 的同名类语义一致）。"""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, image, lane, dets, det_mask, vehicle_state):
        steer, throttle, brake, aux = self.model(
            image, lane, dets, det_mask, vehicle_state,
            camera_heading=None, return_aux=True)

        def _or_zero(v):
            if v is None:
                return torch.zeros(1, 1, dtype=steer.dtype, device=steer.device)
            return v.view(-1, 1) if v.dim() == 1 else v

        return (steer, throttle, brake,
                _or_zero(aux.get("confidence")), _or_zero(aux.get("risk")),
                _or_zero(aux.get("car_heading")))


def load_weights_state(use_ckpt: bool) -> Tuple[Optional[Dict[str, torch.Tensor]], Dict]:
    """复用 export_m9_v2_int8.py 的权重处理（只读导入，不改该脚本）。"""
    if not use_ckpt or not CKPT.exists():
        return None, {"random_init": True, "missing": 0, "unexpected": 0}
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "_s6_int8_ref", str(_ROOT / "tools" / "export_m9_v2_int8.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # 该模块有 __main__ guard，import 安全
    sd = mod._load_state_dict(CKPT)
    return sd, {"random_init": False}


class _StaticGRU(torch.nn.Module):
    """把 `nn.GRU` 的**时间循环展开成静态图**（权重逐位复制，语义等价）。

    ★ 为什么需要它（这是本次排查的核心假设）：
      8 帧图里唯一的结构性差异是 `nn.GRU` —— coremltools 把它 trace 成
      **WhileLoop**（循环体里 6 个 128×128 linear = r/z/n 三个门的 x_proj 与
      h_proj）。而 1 帧图没有 WhileLoop，ANE 编译成功。
      → 单变量验证「WhileLoop 是不是 ANE 编译失败的真正原因」。

    ★ 等价性：PyTorch nn.GRU 的门顺序是 (r, z, n)，
        r = σ(W_ir x + b_ir + W_hr h + b_hr)
        z = σ(W_iz x + b_iz + W_hz h + b_hz)
        n = tanh(W_in x + b_in + r ⊙ (W_hn h + b_hn))
        h' = (1 − z) ⊙ n + z ⊙ h
      与 `src/model_v2.py::_StrictGRUStep` 的注释逐字一致（项目已实测该公式
      与 nn.GRUCell 逐位等价，最大差 5.96e-08）。
    """

    def __init__(self, gru: torch.nn.GRU):
        super().__init__()
        self.num_layers = gru.num_layers
        self.hidden_size = gru.hidden_size
        self.batch_first = gru.batch_first
        for layer in range(gru.num_layers):
            for name in ("weight_ih", "weight_hh", "bias_ih", "bias_hh"):
                setattr(self, f"{name}_l{layer}",
                        getattr(gru, f"{name}_l{layer}").detach().clone())

    def _step(self, x, h, layer: int):
        H = self.hidden_size
        w_ih = getattr(self, f"weight_ih_l{layer}")      # [3H, in]
        w_hh = getattr(self, f"weight_hh_l{layer}")      # [3H, H]
        b_ih = getattr(self, f"bias_ih_l{layer}")
        b_hh = getattr(self, f"bias_hh_l{layer}")
        gi = torch.nn.functional.linear(x, w_ih, b_ih)
        gh = torch.nn.functional.linear(h, w_hh, b_hh)
        i_r, i_z, i_n = gi[:, :H], gi[:, H:2 * H], gi[:, 2 * H:]
        h_r, h_z, h_n = gh[:, :H], gh[:, H:2 * H], gh[:, 2 * H:]
        r = torch.sigmoid(i_r + h_r)
        z = torch.sigmoid(i_z + h_z)
        n = torch.tanh(i_n + r * h_n)
        return (1.0 - z) * n + z * h

    def forward(self, x, hx=None):
        if not self.batch_first:
            x = x.transpose(0, 1)                        # → [B, N, C]
        B, N, _ = x.shape
        if hx is None:
            hx = torch.zeros(self.num_layers, B, self.hidden_size,
                             dtype=x.dtype, device=x.device)
        layer_in = x
        h_last = []
        for layer in range(self.num_layers):
            h = hx[layer]
            outs = []
            for t in range(N):                            # ★ 静态展开，无循环算子
                h = self._step(layer_in[:, t, :], h, layer)
                outs.append(h)
            layer_in = torch.stack(outs, dim=1)           # [B, N, H]
            h_last.append(h)
        hn = torch.stack(h_last, dim=0)
        return layer_in, hn


def _staticize_temporal_gru(model) -> int:
    """把 model.temporal_encoder.rnn（nn.GRU）换成 _StaticGRU。返回层数。"""
    te = getattr(model, "temporal_encoder", None)
    if te is None:
        return 0
    rnn = getattr(te, "rnn", None)
    if not isinstance(rnn, torch.nn.GRU):
        return 0
    te.rnn = _StaticGRU(rnn)
    return int(rnn.num_layers)


def build_and_trace(frames: int, enable_temporal: bool, num_steps: int, sd,
                    tag: str, static_gru: bool = False) -> Tuple[Any, Path]:
    """trace 并缓存（缓存让多方案共享同一次 trace，保证单变量）。

    ⚠️ 缓存键含权重模式 + static_gru，避免不同配置互相污染。
    """
    wmode = "rand" if sd is None else "ckpt"
    gmode = "sg" if static_gru else "loop"
    cache = WORK / f"traced_{wmode}_{gmode}_{tag}.pt"
    import src.model_v2 as mv  # noqa: E402

    if cache.exists():
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            return torch.jit.load(str(cache)), cache

    model = mv.build_model(deploy=False, num_steps=num_steps,
                           enable_temporal=enable_temporal,
                           # ★ 必须传 num_frames：TemporalEncoder.forward 里硬校验
                           #   `seq_len != self.num_frames` 就抛 ValueError。
                           #   不传的话 2/4 帧会直接崩（默认 N=8），帧数扫描根本跑不了。
                           num_frames=frames)
    model.eval()
    if sd is not None:
        res = model.load_state_dict(sd, strict=False)
        model.reparameterize()
        print(f"    [trace:{tag}] load missing={len(res.missing_keys)} "
              f"unexpected={len(res.unexpected_keys)}")
    else:
        model.reparameterize()

    if static_gru:
        n = _staticize_temporal_gru(model)
        print(f"    [trace:{tag}] static_gru：已把时序 GRU 循环展开为静态实现"
              f"（{n} 层，其余部分逐字未改）")

    wrapper = _ExportWrapper(model).eval()
    args = (torch.zeros(frames, 3, 180, 320), torch.zeros(1, 1, 160, 160),
            torch.zeros(1, 20, 12), torch.zeros(1, 20), torch.zeros(1, 8))
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, args, strict=False)
    WORK.mkdir(parents=True, exist_ok=True)
    torch.jit.save(traced, str(cache))
    return traced, cache


def shapes_for(frames: int) -> List[Tuple[int, ...]]:
    return [(frames, 3, 180, 320), (1, 1, 160, 160), (1, 20, 12), (1, 20), (1, 8)]


def convert_fp16(traced, frames: int):
    inputs = [ct.TensorType(name=n, shape=s, dtype=np.float32)
              for n, s in zip(INPUT_NAMES, shapes_for(frames))]
    outputs = [ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return ct.convert(traced, source="pytorch", convert_to="mlprogram",
                          minimum_deployment_target=ct.target.macOS13,
                          compute_precision=ct.precision.FLOAT16,
                          inputs=inputs, outputs=outputs)


# ============================================================================
# 2. 量化方案
# ============================================================================
def _op_names_for_prefixes(mlmodel, prefixes: Sequence[str]) -> List[str]:
    """找出关键分支算子名（保 fp16 / 单独指定位宽用）。

    ★ 复用 export_m9_v2_int8.py 的 `_preserve_op_names`（项目已验证的机制：
      权重名前缀 + lane 输入数据流追踪双路并用），避免自己重写导致口径漂移。
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "_s6_int8_ref3", str(_ROOT / "tools" / "export_m9_v2_int8.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod._preserve_op_names(mlmodel, prefixes)


def _pal_cfg(nbits: int, mode: str, group_size: int = 1):
    return cto.OpPalettizerConfig(mode=mode, nbits=nbits,
                                  granularity="per_tensor", group_size=group_size)


def apply_quant(mlmodel, spec: Dict[str, Any]):
    """按方案 spec 量化，返回 (新 mlmodel, notes)。"""
    kind = spec["kind"]
    notes: List[str] = []

    if kind == "none":
        return mlmodel, ["不量化（fp16 基线）"]

    if kind in ("palette", "mixed", "linear"):
        key_ops: List[str] = []
        if spec.get("preserve") or kind == "mixed":
            key_ops = _op_names_for_prefixes(mlmodel, PRESERVE_PREFIXES)
            notes.append(f"关键分支算子命中 {len(key_ops)} 个（前缀 {list(PRESERVE_PREFIXES)}）")
            if not key_ops:
                notes.append("⚠ 未命中任何关键算子 —— 退化为全量量化")

    if kind in ("palette", "mixed"):
        gcfg = _pal_cfg(spec["nbits"], spec.get("mode", "kmeans"),
                        spec.get("group_size", 1))
        op_cfg = None
        if kind == "mixed" and key_ops:
            # 关键分支单独给更高位宽（不是跳过）—— 4bit 全局 + 关键头 8bit
            op_cfg = {op: _pal_cfg(spec.get("key_nbits", 8), spec.get("mode", "kmeans"),
                                   spec.get("group_size", 1)) for op in key_ops}
        elif spec.get("preserve") and key_ops:
            # 跳过压缩的写法是**值给 None**（与 ayolom 量产配方一致）
            op_cfg = {op: None for op in key_ops}
        cfg = cto.OptimizationConfig(global_config=gcfg, op_name_configs=op_cfg)
        out = cto.palettize_weights(mlmodel, cfg)
        notes.append(f"palette mode={spec.get('mode','kmeans')} nbits={spec['nbits']} "
                     f"per_tensor gs={spec.get('group_size',1)}"
                     + (f" + 关键分支 {spec.get('key_nbits',8)}bit" if op_cfg and kind == "mixed"
                        else " + 关键分支保 fp16" if op_cfg else ""))
        return out, notes

    if kind == "linear":
        dtype = np.int8 if spec["dtype"] == "int8" else "int4"
        gcfg = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype=dtype,
                                           granularity="per_channel",
                                           block_size=spec.get("group_size", 32))
        op_cfg = {op: None for op in key_ops} if (spec.get("preserve") and key_ops) else None
        cfg = cto.OptimizationConfig(global_config=gcfg, op_name_configs=op_cfg)
        out = cto.linear_quantize_weights(mlmodel, cfg)
        notes.append(f"linear mode=linear_symmetric dtype={spec['dtype']} "
                     f"per_channel block_size={spec.get('group_size',32)}")
        return out, notes

    raise ValueError(f"未知方案 kind={kind}")


# ============================================================================
# 3. ★ ANE 判据（确定性）
# ============================================================================
def compile_model(mlpackage: Path, tag: str) -> Optional[Path]:
    """mlpackage → mlmodelc（MLComputePlan 只吃编译产物）。"""
    try:
        compiled = ct.utils.compile_model(str(mlpackage))
        dst = WORK / "compiled" / f"{tag}.mlmodelc"
        if dst.exists():
            shutil.rmtree(dst)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(compiled, dst)
        return dst
    except Exception as exc:
        print(f"    [compile:{tag}] ✗ {type(exc).__name__}: {str(exc)[:110]}")
        return None


def ane_oracle(compiled: Path) -> Dict[str, Any]:
    """★ 确定性 ANE 判据：统计 preferred_compute_device 落在 ANE / CPU 的算子数。

    判据（本机标定，见文件头 §1）：
        ANE 可用 = ane_ops > 0 且 cpu_ops == 0
        ANE 失败 = ane_ops == 0 且 cpu_ops > 0
    """
    res: Dict[str, Any] = {"ane_ops": 0, "cpu_ops": 0, "no_usage": 0, "total_ops": 0,
                           "verdict": "UNKNOWN", "op_types_on_cpu": [],
                           "op_types_on_ane": []}
    try:
        plan = MLComputePlan.load_from_path(str(compiled),
                                            compute_units=ct.ComputeUnit.CPU_AND_NE)
    except Exception as exc:
        res["verdict"] = "PLAN_LOAD_FAIL"
        res["error"] = f"{type(exc).__name__}: {str(exc)[:160]}"
        return res

    fn = plan.model_structure.program.functions["main"]
    ops = list(fn.block.operations)
    res["total_ops"] = len(ops)
    cpu_types: Dict[str, int] = {}
    ane_types: Dict[str, int] = {}
    all_types: Dict[str, int] = {}
    for op in ops:
        nm = op.operator_name
        all_types[nm] = all_types.get(nm, 0) + 1
        try:
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
        except Exception:
            res["no_usage"] += 1
            continue
        if usage is None:
            res["no_usage"] += 1
            continue
        dname = type(usage.preferred_compute_device).__name__
        if "Neural" in dname:
            res["ane_ops"] += 1
            ane_types[nm] = ane_types.get(nm, 0) + 1
        elif "CPU" in dname:
            res["cpu_ops"] += 1
            cpu_types[nm] = cpu_types.get(nm, 0) + 1

    res["op_types_on_cpu"] = sorted(cpu_types.items(), key=lambda kv: -kv[1])
    res["op_types_on_ane"] = sorted(ane_types.items(), key=lambda kv: -kv[1])
    res["op_types_all"] = sorted(all_types.items(), key=lambda kv: -kv[1])
    res["op_type_count"] = len(all_types)
    # ★ WhileLoop 判定直接从计算计划的算子名取（比读 metadata.json 更硬：
    #   .mlpackage 里没有 metadata.json，只有编译后的 .mlmodelc 才有）
    res["has_while_loop"] = any("while_loop" in k.lower() for k in all_types)
    res["while_loop_count"] = sum(v for k, v in all_types.items()
                                  if "while_loop" in k.lower())
    if res["ane_ops"] > 0 and res["cpu_ops"] == 0:
        res["verdict"] = "ANE_OK"
    elif res["ane_ops"] == 0 and res["cpu_ops"] > 0:
        res["verdict"] = "ANE_FAIL"
    elif res["ane_ops"] > 0 and res["cpu_ops"] > 0:
        res["verdict"] = "PARTIAL"        # 图被切开，部分 ANE 部分 CPU
    return res


def op_histogram(mlpackage: Path) -> Dict[str, int]:
    """算子直方图 —— 优先从**编译产物**的 metadata.json 读（权威）。"""
    cands = [mlpackage / "Data" / "com.apple.CoreML" / "metadata.json",
             mlpackage / "metadata.json"]
    for meta in cands:
        if not meta.exists():
            continue
        try:
            d = json.loads(meta.read_text())
            d = d[0] if isinstance(d, list) else d
            h = d.get("mlProgramOperationTypeHistogram", {})
            if h:
                return h
        except Exception:
            continue
    return {}


# ============================================================================
# 4. 精度实测
# ============================================================================
def make_feed(frames: int, seed: int = 0) -> Dict[str, np.ndarray]:
    g = np.random.default_rng(seed)
    return {
        "image": g.random((frames, 3, 180, 320), dtype=np.float32),
        "lane": (g.random((1, 1, 160, 160)) > 0.985).astype(np.float32),
        "dets": g.random((1, 20, 12), dtype=np.float32),
        "det_mask": (g.random((1, 20)) > 0.35).astype(np.float32),
        "vehicle_state": (g.random((1, 8)) * 2 - 1).astype(np.float32),
    }


def accuracy_cases(frames: int) -> Dict[str, Dict[str, np.ndarray]]:
    """契约边界用例（与 export_m9_v2_int8.py 的 6 用例同构）+ lane 专项 + 时序序列。"""
    base = make_feed(frames, 0)
    img, lane, dets, det_mask, state = (base["image"], base["lane"], base["dets"],
                                        base["det_mask"], base["vehicle_state"])
    cases: Dict[str, Dict[str, np.ndarray]] = {
        "normal": dict(base),
        "no_dets": {**base, "dets": np.zeros_like(dets), "det_mask": np.zeros_like(det_mask)},
        "no_lane": {**base, "lane": np.zeros_like(lane)},
        "zero_state": {**base, "vehicle_state": np.zeros_like(state)},
        "all_empty": {**base, "lane": np.zeros_like(lane), "dets": np.zeros_like(dets),
                      "det_mask": np.zeros_like(det_mask),
                      "vehicle_state": np.zeros_like(state)},
        "saturated": {**base, "image": np.ones_like(img), "lane": np.ones_like(lane),
                      "dets": np.ones_like(dets), "det_mask": np.ones_like(det_mask),
                      "vehicle_state": np.ones_like(state)},
    }
    # lane 专项：单条细线（1/2/3/6 px）——量化最容易毁掉稀疏细结构
    for w in (1, 2, 3, 6):
        l = np.zeros_like(lane)
        l[0, 0, :, 80:80 + w] = 1.0
        cases[f"lane_line_w{w}"] = {**base, "lane": l}
    # 时序序列：image 逐帧漂移（时序分支真的被激励）
    for t in range(4):
        im = np.roll(img, shift=t * 7, axis=3)
        cases[f"seq_t{t}"] = {**base, "image": im}
    return cases


def outputs_of(mlmodel, feed: Dict[str, np.ndarray]) -> Optional[List[float]]:
    try:
        pred = mlmodel.predict(feed)
        return [float(np.asarray(pred[n]).ravel()[0]) for n in OUTPUT_NAMES]
    except Exception:
        return None


def measure_accuracy(ref_model, test_model, cases) -> Dict[str, Any]:
    """逐用例实测 maxdiff（ref = 同源 fp16 图）。"""
    per_case: Dict[str, float] = {}
    worst_case, worst_val = None, -1.0
    for name, feed in cases.items():
        r = outputs_of(ref_model, feed)
        t = outputs_of(test_model, feed)
        if r is None or t is None:
            per_case[name] = float("nan")
            continue
        d = max(abs(a - b) for a, b in zip(r, t))
        per_case[name] = d
        if d > worst_val:
            worst_val, worst_case = d, name
    vals = [v for v in per_case.values() if not np.isnan(v)]
    return {
        "per_case": per_case,
        "maxdiff": max(vals) if vals else float("nan"),
        "worst_case": worst_case,
        "mean_maxdiff": float(np.mean(vals)) if vals else float("nan"),
        "lossless": bool(vals and max(vals) < LOSSLESS_TOL),
    }


# ============================================================================
# 5. 真机耗时（ABBA）
# ============================================================================
def bench_once(mlmodel, feed, iters: int = 30, warmup: int = 5) -> float:
    for _ in range(warmup):
        mlmodel.predict(feed)
    ts = []
    for _ in range(iters):
        t0 = time.perf_counter()
        mlmodel.predict(feed)
        ts.append((time.perf_counter() - t0) * 1000.0)
    ts.sort()
    return statistics.median(ts)


def abba(pkg: Path, feed) -> Dict[str, Any]:
    """ABBA 交替（ANE, CPU, CPU, ANE 取中位）抵消负载漂移。

    ⚠️ 实测踩坑：`ct.models.MLModel` 只吃 **.mlpackage**，喂编译产物
    （ct.utils.compile_model 的输出目录）会抛
    `RuntimeError: A valid manifest does not exist at path: .../Manifest.json`
    —— 因为 `compile_model` 产出的是 ANE 编译中间产物，**不含 Manifest.json**。
    （Manifest.json 是 Xcode / swift-coreml-tools 打包时才生成的。）
    → 计时用 .mlpackage，ANE 判据用编译产物，两者各取所需。
    """
    out: Dict[str, Any] = {}
    try:
        m_ane = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.CPU_AND_NE)
        m_cpu = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.CPU_ONLY)
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {str(exc)[:140]}"}
    a1 = bench_once(m_ane, feed)
    c1 = bench_once(m_cpu, feed)
    c2 = bench_once(m_cpu, feed)
    a2 = bench_once(m_ane, feed)
    ane_ms = statistics.median([a1, a2])
    cpu_ms = statistics.median([c1, c2])
    out.update({"ane_ms": ane_ms, "cpu_ms": cpu_ms,
                "ratio": ane_ms / cpu_ms if cpu_ms else float("nan"),
                "raw": {"ane1": a1, "cpu1": c1, "cpu2": c2, "ane2": a2}})
    out["timing_says_ane"] = bool(out["ratio"] < ANE_RATIO_OK)
    return out


# ============================================================================
# 6. 单方案执行
# ============================================================================
def dir_mb(p: Path) -> float:
    if p.is_file():
        return p.stat().st_size / 1048576.0
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1048576.0


def weights_mb(mlpackage: Path) -> float:
    w = mlpackage / "Data" / "com.apple.CoreML" / "weights"
    return dir_mb(w) if w.exists() else 0.0


def run_one(spec: Dict[str, Any], frames: int, traced, ref_model,
            cases, feed, do_bench: bool = True, keep: bool = False) -> Dict[str, Any]:
    tag = spec["tag"]
    rec: Dict[str, Any] = {"tag": tag, "frames": frames, "spec": spec}
    print(f"\n  ── {tag} ──")
    t0 = time.time()
    try:
        ml = convert_fp16(traced, frames)
    except Exception as exc:
        rec["error"] = f"convert: {type(exc).__name__}: {str(exc)[:160]}"
        print(f"    ✗ 转换失败 {rec['error']}")
        return rec
    rec["convert_s"] = round(time.time() - t0, 1)

    try:
        ml, notes = apply_quant(ml, spec)
        rec["notes"] = notes
        for n in notes:
            print(f"    · {n}")
    except Exception as exc:
        rec["error"] = f"quant: {type(exc).__name__}: {str(exc)[:160]}"
        print(f"    ✗ 量化失败 {rec['error']}")
        return rec
    rec["quant_s"] = round(time.time() - t0, 1)

    pkg = WORK / "pkg" / f"{tag}.mlpackage"
    if pkg.exists():
        shutil.rmtree(pkg)
    pkg.parent.mkdir(parents=True, exist_ok=True)
    try:
        ml.save(str(pkg))
    except Exception as exc:
        rec["error"] = f"save: {type(exc).__name__}: {str(exc)[:160]}"
        print(f"    ✗ 保存失败 {rec['error']}")
        return rec

    rec["total_mb"] = round(dir_mb(pkg), 3)
    rec["weights_mb"] = round(weights_mb(pkg), 3)
    # ★ 算子直方图在 .mlpackage 里**不存在**（实测：只有编译后的 .mlmodelc 才有，
    #   而且 ct.utils.compile_model 的产物也没有 —— metadata.json 是 Xcode 打包加的）。
    #   → 权威来源改为 compute plan 的算子统计（见 ane_oracle 的 op_types_all）。
    hist = op_histogram(pkg)
    rec["op_count"] = int(sum(hist.values()))
    rec["op_types"] = len(hist)
    rec["has_while_loop"] = bool(hist.get("WhileLoop", 0) > 0)

    # ---- ANE 判据（先做，它同时给出权威算子统计）----
    compiled = compile_model(pkg, tag)
    if compiled is None:
        rec["ane"] = {"verdict": "COMPILE_FAIL"}
        print(f"    体积 {rec['total_mb']:.3f} MB（权重 {rec['weights_mb']:.3f} MB）")
        print("    ANE: ✗ 编译失败")
    else:
        oracle = ane_oracle(compiled)
        rec["ane"] = oracle
        # 用计算计划的算子统计覆盖（更权威，且能判 WhileLoop）
        if oracle.get("op_type_count"):
            rec["op_count"] = oracle["total_ops"]
            rec["op_types"] = oracle["op_type_count"]
            rec["has_while_loop"] = oracle["has_while_loop"]
            rec["while_loop_count"] = oracle["while_loop_count"]
        print(f"    体积 {rec['total_mb']:.3f} MB（权重 {rec['weights_mb']:.3f} MB）"
              f"  算子 {rec['op_count']}（{rec['op_types']} 类）"
              f"  WhileLoop={oracle['while_loop_count']}")
        print(f"    ANE 判据: {oracle['verdict']}  "
              f"(ANE 算子 {oracle['ane_ops']} / CPU 算子 {oracle['cpu_ops']} "
              f"/ 无信息 {oracle['no_usage']} / 总 {oracle['total_ops']})")
        if oracle["op_types_on_cpu"]:
            print(f"      CPU 上的算子类型: {oracle['op_types_on_cpu'][:6]}")

    # ---- 耗时（ABBA，第二证据）----
    if do_bench:
        t0 = time.time()
        b = abba(pkg, feed)
        rec["bench"] = b
        rec["bench_s"] = round(time.time() - t0, 1)
        if "error" in b:
            print(f"    耗时: ✗ {b['error']}")
        else:
            print(f"    耗时 ABBA: ANE {b['ane_ms']:.2f} ms / CPU {b['cpu_ms']:.2f} ms "
                  f"→ 比值 {b['ratio']:.2f} "
                  f"({'耗时也支持 ANE 生效' if b['timing_says_ane'] else '耗时显示未走 ANE'})")

    # ---- 精度（对同源 fp16 图）----
    if ref_model is None or not cases:
        rec["acc"] = {"skipped": "本 phase 不做精度对比（无基准图/无用例）"}
        print("    精度: 跳过（本 phase 不做精度对比）")
    else:
        t0 = time.time()
        acc = measure_accuracy(ref_model, ml, cases)
        rec["acc"] = acc
        print(f"    精度 maxdiff={acc['maxdiff']:.3e}（最差用例 {acc['worst_case']}）"
              f" → {'✅ 无损(<1e-3)' if acc['lossless'] else '🔴 有损(≥1e-3)'}")
        rec["acc_s"] = round(time.time() - t0, 1)

    # ---- 关键产物落盘 ----
    if keep and compiled is not None:
        dst = _ROOT / "models" / f"exp_quant_{tag}.mlmodelc"
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(compiled, dst)
        rec["kept_at"] = str(dst.relative_to(_ROOT))
        print(f"    产物: {rec['kept_at']}")

    # ---- 一致性交叉校验：两条证据是否打架（放最后，两者都已采集）----
    if "bench" in rec and "error" not in rec.get("bench", {}):
        verdict = rec.get("ane", {}).get("verdict")
        v_time = rec["bench"]["timing_says_ane"]
        if verdict == "ANE_OK":
            rec["evidence_agree"] = bool(v_time)
        elif verdict == "PARTIAL":
            # 部分卸载：耗时比可能仍 <0.85（有加速）也可能不快（图被切碎、来回拷贝）
            # → 不做二元判定，如实记录，报告里单独讨论
            rec["evidence_agree"] = None
            rec["evidence_note"] = "PARTIAL（图被切开）：耗时比不构成二元判据"
        else:
            rec["evidence_agree"] = bool(not v_time)
        if rec["evidence_agree"] is False:
            print(f"    ⚠ 两条证据不一致：判据={verdict} "
                  f"耗时比={rec['bench']['ratio']:.2f}（须人工判读，不得单选其一）")
    return rec


# ============================================================================
# 7. 实验矩阵
# ============================================================================
def specs_rootcause() -> List[Dict[str, Any]]:
    """phase=rootcause：时间维消融（全部 fp16 不量化）→ 定位真凶。

    ★ 消融设计的坑（实测踩到，记下来免得后人重踩）：
      最直觉的做法是「8 帧 + enable_temporal=False」，但**跑不通**：
      `M2Model.forward` 里 `torch.cat([img_feat(8,256), lane_feat(1,64), ...])`
      会直接抛 `Sizes of tensors must match except in dimension 1.
      Expected size 8 but got size 1` —— 8 帧本来就**依赖**时序分支把 batch 折回 1。
      所以「8 帧无时序」在当前架构下不是合法配置，不能作为消融格。

    → 改用**真正单变量**的消融：把时序编码器的循环体换成静态实现，
      只改「循环结构」这一个变量，图的其余部分逐字相同。
    """
    return [{"tag": "fp16", "kind": "none"}]


def specs_sweep() -> List[Dict[str, Any]]:
    """phase=sweep：8 帧 + 时序（部署形态）全量化方案扫描。"""
    return [
        {"tag": "fp16", "kind": "none"},
        {"tag": "pal8_kmeans", "kind": "palette", "nbits": 8, "mode": "kmeans"},
        {"tag": "pal8_kmeans_preserve", "kind": "palette", "nbits": 8, "mode": "kmeans",
         "preserve": True},
        {"tag": "pal6_kmeans", "kind": "palette", "nbits": 6, "mode": "kmeans"},
        {"tag": "pal4_kmeans", "kind": "palette", "nbits": 4, "mode": "kmeans"},
        {"tag": "pal4_kmeans_preserve", "kind": "palette", "nbits": 4, "mode": "kmeans",
         "preserve": True},
        {"tag": "pal8_uniform", "kind": "palette", "nbits": 8, "mode": "uniform"},
        {"tag": "pal4_uniform", "kind": "palette", "nbits": 4, "mode": "uniform"},
        {"tag": "lin_int8", "kind": "linear", "dtype": "int8", "group_size": 32},
        {"tag": "lin_int4", "kind": "linear", "dtype": "int4", "group_size": 32},
        {"tag": "pal4_key8", "kind": "mixed", "nbits": 4, "key_nbits": 8,
         "mode": "kmeans"},
    ]


def specs_sweep_static() -> List[Dict[str, Any]]:
    """phase=sweep 的第二程：把时序 GRU 静态展开后再扫一遍（验证结构修复）。"""
    return [
        {"tag": "fp16", "kind": "none"},
        {"tag": "pal8_kmeans_preserve", "kind": "palette", "nbits": 8, "mode": "kmeans",
         "preserve": True},
        {"tag": "pal4_kmeans", "kind": "palette", "nbits": 4, "mode": "kmeans"},
        {"tag": "pal4_key8", "kind": "mixed", "nbits": 4, "key_nbits": 8,
         "mode": "kmeans"},
    ]


def specs_frames() -> List[Dict[str, Any]]:
    """phase=frames：帧数 × 量化 的图大小-ANE 阈值扫描。"""
    return [
        {"tag": "pal8_kmeans", "kind": "palette", "nbits": 8, "mode": "kmeans"},
        {"tag": "pal4_kmeans", "kind": "palette", "nbits": 4, "mode": "kmeans"},
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", default="all",
                    choices=["rootcause", "sweep", "frames", "all"])
    ap.add_argument("--weights", default="ckpt", choices=["ckpt", "random"])
    ap.add_argument("--frames", default="8", help="逗号分隔，如 1,2,4,8")
    ap.add_argument("--no-bench", action="store_true")
    ap.add_argument("--bench-frames", default="8",
                    help="对哪些帧数做 ABBA 计时（耗时敏感，默认只测部署形态 8 帧）")
    ap.add_argument("--keep", action="store_true", help="关键方案编译产物落盘到 models/")
    args = ap.parse_args()

    WORK.mkdir(parents=True, exist_ok=True)
    avail = api_availability()
    print("=" * 100)
    print("S6 · 量化与权重压缩调优 —— ANE 编译边界专项")
    print("=" * 100)
    print(f"  机器: {os.uname().machine} / macOS {os.uname().release} / "
          f"coremltools {avail['coremltools_version']}")
    print(f"  ★ API 自检（任务书点名的两个在 8.3 里**不存在**，如实记录）：")
    print(f"      op_palettization    : {avail['op_palettization']}"
          f"   → 等价物 = OptimizationConfig(op_name_configs={{op: OpPalettizerConfig(...)}})"
          f" {'✅ 可用' if avail['op_name_configs_equivalent'] else '✗'}")
    print(f"      deduplicate_weights : {avail['deduplicate_weights']}"
          f"   → {'✅ 可用' if avail['deduplicate_weights'] else '✗ 8.3 无此 API'}")
    print(f"      已装版本: {avail['coremltools_version']}；"
          f"PyPI 最新 9.0（这两个 API 需升级才有，本脚本不擅自升级项目 venv）")

    use_ckpt = args.weights == "ckpt"
    sd = None
    if use_ckpt:
        sd, _ = load_weights_state(True)
        print(f"  权重: {CKPT.name}（{len(sd) if sd else 0} 键）")
    else:
        print("  权重: 随机初始化（仅验证链路，偏差数字不得作为精度结论）")

    results: List[Dict[str, Any]] = []
    frames_list = [int(x) for x in args.frames.split(",")]
    bench_frames = {int(x) for x in args.bench_frames.split(",")}

    def dump():
        payload = {"api": avail, "weights": args.weights,
                   "lossless_tol": LOSSLESS_TOL,
                   "results": results,
                   "generated_at": time.strftime("%Y-%m-%d %H:%M:%S")}
        REPORT.write_text(json.dumps(payload, ensure_ascii=False, indent=2),
                          encoding="utf-8")

    # ---------------- phase rootcause ----------------
    if args.phase in ("rootcause", "all"):
        print("\n" + "=" * 100)
        print("PHASE rootcause —— 时间维消融（fp16，不量化）：ANE 失败的真凶是谁？")
        print("=" * 100)
        print("  单变量：只切「时序 GRU 是循环算子还是静态展开」，其余全同。")
        print("  判定：若 static_gru 让 ANE 从 FAIL 变 OK，则真凶 = WhileLoop（结构），")
        print("        而不是「图大小 / 量化位宽 / 帧数」。")
        # 先做等价性验证（静态展开必须与 nn.GRU 数值等价，否则消融无效）
        for frames, sg, tag in ((8, False, "A1_8f_gru_loop"),
                                (8, True, "A2_8f_gru_static"),
                                (1, True, "A3_1f_gru_static")):
            traced, _ = build_and_trace(frames, True, 12, sd, tag, static_gru=sg)
            rec = run_one({"tag": tag, "kind": "none"}, frames, traced,
                          None, {}, make_feed(frames), do_bench=False)
            rec["static_gru"] = sg
            rec["enable_temporal"] = True
            rec["phase"] = "rootcause"
            results.append(rec)
            dump()

        # ---- 等价性验证：static_gru 必须与 nn.GRU 输出一致 ----
        print("\n  ── 等价性验证：_StaticGRU vs nn.GRU（同一权重）──")
        try:
            import src.temporal as _tp
            torch.manual_seed(0)
            g = torch.nn.GRU(input_size=256, hidden_size=128, num_layers=1,
                             batch_first=True)
            s = _StaticGRU(g)
            x = torch.randn(2, 8, 256)
            with torch.no_grad():
                o1, h1 = g(x)
                o2, h2 = s(x)
            d_out = float((o1 - o2).abs().max())
            d_h = float((h1 - h2).abs().max())
            eq = {"maxdiff_out": d_out, "maxdiff_h": d_h,
                  "equivalent": bool(max(d_out, d_h) < 1e-6)}
            print(f"    maxdiff(out)={d_out:.3e}  maxdiff(h)={d_h:.3e} "
                  f"→ {'✅ 逐位等价（消融有效）' if eq['equivalent'] else '🔴 不等价，消融结论不可用'}")
            results.append({"tag": "EQUIV_static_gru", "phase": "rootcause",
                            "frames": 0, "equivalence": eq})
            dump()
        except Exception as exc:
            print(f"    ✗ 等价性验证失败 {type(exc).__name__}: {exc}")

    # ---------------- phase sweep ----------------
    if args.phase in ("sweep", "all"):
        for static_gru in ((False, True) if args.phase == "all" else (False,)):
            label = "GRU 循环版（当前部署形态）" if not static_gru else "GRU 静态展开版（结构修复）"
            print("\n" + "=" * 100)
            print(f"PHASE sweep —— 8 帧 + 时序（{label}）全量化方案扫描")
            print("=" * 100)
            frames = 8
            traced, _ = build_and_trace(frames, True, 12, sd, "sweep8",
                                        static_gru=static_gru)
            cases = accuracy_cases(frames)
            feed = make_feed(frames)
            ref_ml = None
            specs = specs_sweep_static() if static_gru else specs_sweep()
            for spec in specs:
                sp = dict(spec)
                if static_gru:
                    sp["tag"] = f"sg_{sp['tag']}"
                if sp["tag"] in ("fp16", "sg_fp16"):
                    # fp16 基线：既是精度基准，也是一个被测档
                    try:
                        ref_ml = convert_fp16(traced, frames)
                    except Exception as exc:
                        print(f"  ✗ fp16 基线转换失败 {exc}")
                        continue
                if ref_ml is None:
                    continue
                rec = run_one(sp, frames, traced, ref_ml, cases, feed,
                              do_bench=(not args.no_bench) and frames in bench_frames,
                              keep=args.keep and sp["tag"] in
                              ("pal8_kmeans_preserve", "pal4_kmeans", "pal4_key8",
                               "sg_pal4_key8", "sg_pal8_kmeans_preserve"))
                rec["phase"] = "sweep"
                rec["static_gru"] = static_gru
                results.append(rec)
                dump()

    # ---------------- phase frames ----------------
    if args.phase in ("frames", "all"):
        print("\n" + "=" * 100)
        print("PHASE frames —— 帧数 × 量化 的图大小-ANE 阈值扫描")
        print("=" * 100)
        for frames in frames_list:
            traced, _ = build_and_trace(frames, True, 12, sd, f"f{frames}")
            cases = accuracy_cases(frames)
            feed = make_feed(frames)
            try:
                ref_ml = convert_fp16(traced, frames)
            except Exception as exc:
                print(f"  ✗ {frames} 帧 fp16 转换失败 {exc}")
                continue
            for spec in specs_frames():
                rec = run_one(spec, frames, traced, ref_ml, cases, feed,
                              do_bench=(not args.no_bench) and frames in bench_frames)
                rec["phase"] = "frames"
                results.append(rec)
                dump()

    # ---------------- 汇总 ----------------
    print("\n" + "=" * 100)
    print("汇总")
    print("=" * 100)
    print(f"{'方案':<26}{'帧':>4}{'MB':>9}{'算子':>7}{'WhileLoop':>11}"
          f"{'ANE判据':>12}{'maxdiff':>11}{'无损?':>7}{'ANEms':>8}{'CPUms':>8}")
    print("-" * 100)
    for r in results:
        ane = r.get("ane", {}).get("verdict", "n/a")
        acc = r.get("acc", {}).get("maxdiff")
        acc_s = f"{acc:.2e}" if isinstance(acc, float) else "n/a"
        ll = "✅" if r.get("acc", {}).get("lossless") else "🔴"
        b = r.get("bench", {})
        a_ms = f"{b['ane_ms']:.2f}" if isinstance(b.get("ane_ms"), float) else "n/a"
        c_ms = f"{b['cpu_ms']:.2f}" if isinstance(b.get("cpu_ms"), float) else "n/a"
        print(f"{r['tag']:<26}{r['frames']:>4}{r.get('total_mb', 0):>9.3f}"
              f"{r.get('op_count', 0):>7}{('有' if r.get('has_while_loop') else '无'):>11}"
              f"{ane:>12}{acc_s:>11}{ll:>7}{a_ms:>8}{c_ms:>8}")
    print(f"\n数据 JSON: {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
