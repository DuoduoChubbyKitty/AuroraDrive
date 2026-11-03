#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 时序模块 ANE 派发实测（可复现）。

背景（项目实测教训）
--------------------
* 含 while_loop 的 GRU loop 版 → ANE_FAIL（891 算子中 453 掉 CPU、ANE 可用 0）
* 改 static/unroll 后 → PARTIAL（609 ANE / 52 CPU）

本脚本用 coremltools 9.0 + `MLComputePlan`（macOS 26+ 真机）对**每种候选时序
结构**做算子级派发统计，把上面两条历史结论变成可复现的测量，而不是口口相传。

关键 API 坑（本机实测）
-----------------------
`MLComputePlan.load_from_path()` 直接吃 `.mlpackage` 会 **C++ abort**
（libc++abi: Failed to open ... coremldata.bin，coremltools 9.0 新布局没有该文件）。
必须：`ct.models.MLModel(pkg).get_compiled_model_path()` → 用 `.mlmodelc` 路径加载。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/02_ane_dispatch.py
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib import import_module

_budget = import_module("01_budget")
V1_UnrollGRU = _budget.V1_UnrollGRU
V2_TCN = _budget.V2_TCN
V3_TemporalAttn = _budget.V3_TemporalAttn
V4_Hierarchical = _budget.V4_Hierarchical
V5_HierGRU = _budget.V5_HierGRU
LowResEncoder = _budget.LowResEncoder

import coremltools as ct  # noqa: E402


def _device_name(usage) -> str:
    """把 MLComputeDevice 转成可读字符串。

    ★ 坑（本机实测）：MLComputeDevice **没有** `.type` 属性，只能靠**类名**
      区分（MLNeuralEngineComputeDevice / MLCPUComputeDevice /
      MLGPUComputeDevice）。用 getattr(dev, "type", str(dev)) 会把所有算子
      都归成同一个字符串，统计出"ANE 占比 0%"的假象 —— 第一版就踩了这个坑。
    """
    if usage is None:
        return "const"
    dev = getattr(usage, "preferred_compute_device", None)
    if dev is None:
        return "unknown"
    cls = type(dev).__name__
    if "NeuralEngine" in cls:
        return "neuralEngine"
    if "GPU" in cls:
        return "gpu"
    if "CPU" in cls:
        return "cpu"
    return cls


def dispatch_stats(mlpackage_path: str, input_name: str, input_shape: tuple) -> dict:
    """导出后统计算子级 ANE/GPU/CPU 派发。"""
    model = ct.models.MLModel(mlpackage_path, compute_units=ct.ComputeUnit.ALL)
    compiled = model.get_compiled_model_path()

    from coremltools.models.compute_plan import MLComputePlan
    plan = MLComputePlan.load_from_path(compiled, compute_units=ct.ComputeUnit.ALL)
    fn = plan.model_structure.program.functions["main"]
    ops = list(fn.block.operations)

    counts: dict[str, int] = {}
    for op in ops:
        usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
        name = _device_name(usage)
        counts[name] = counts.get(name, 0) + 1

    total = sum(counts.values())
    analyze = total - counts.get("const", 0)
    return {
        "total_ops": total,
        "const_ops": counts.get("const", 0),
        "analyzed_ops": analyze,
        "by_device": counts,
        "ane_ops": counts.get("neuralEngine", 0),
        "gpu_ops": counts.get("gpu", 0),
        "cpu_ops": counts.get("cpu", 0),
        "ane_ratio_of_analyzed": round(counts.get("neuralEngine", 0) / max(analyze, 1), 4),
    }


def convert_and_measure(module: nn.Module, input_shape: tuple, tag: str,
                        tmpdir: Path) -> dict:
    """trace → convert → 统计派发 + 试跑推理。"""
    module.eval()
    example = torch.zeros(*input_shape)
    with torch.no_grad():
        traced = torch.jit.trace(module, example, strict=False)

    mlm = ct.convert(
        traced,
        inputs=[ct.TensorType(name="x", shape=input_shape, dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    pkg = str(tmpdir / f"{tag}.mlpackage")
    mlm.save(pkg)

    stats = dispatch_stats(pkg, "x", input_shape)

    # 真机推理：确认能跑且数值合理（不是 NaN/Inf）
    model = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
    out = model.predict({"x": np.zeros(input_shape, dtype=np.float32)})
    out_key = list(out.keys())[0]
    out_arr = np.asarray(out[out_key])
    stats["out_shape"] = list(out_arr.shape)
    stats["finite"] = bool(np.isfinite(out_arr).all())
    return stats


def main() -> int:
    tmpdir = Path(tempfile.mkdtemp(prefix="v3_ane_"))
    results: dict[str, dict] = {}

    print("=" * 80)
    print("时序融合候选：24 帧、in_dim=128、hidden=128 的 ANE 派发实测")
    print("=" * 80)

    cases = {
        "V1_UnrollGRU24_1layer": (V1_UnrollGRU(128, 128, 24, 1), (1, 24, 128)),
        "V2_TCN_4layer": (V2_TCN(128, 128, 24, 4), (1, 24, 128)),
        "V3_TemporalAttn_2layer": (V3_TemporalAttn(128, 128, 24, 2, 4), (1, 24, 128)),
        "V4_Hierarchical_conv": (V4_Hierarchical(128, 128, 24, 3, 3), (1, 24, 128)),
        "V5_Hierarchical_gru8": (V5_HierGRU(128, 128, 24, 3), (1, 24, 128)),
    }

    for tag, (mod, shape) in cases.items():
        try:
            st = convert_and_measure(mod, shape, tag, tmpdir)
            results[tag] = st
            print(f"\n[{tag}]  input={shape}")
            print(f"  算子总数={st['total_ops']}（const {st['const_ops']} / 可分析 {st['analyzed_ops']}）")
            print(f"  派发: {st['by_device']}")
            print(f"  ANE 占比={st['ane_ratio_of_analyzed']:.1%}  "
                  f"out={st['out_shape']} finite={st['finite']}")
        except Exception as exc:
            results[tag] = {"error": f"{type(exc).__name__}: {exc}"}
            print(f"\n[{tag}] ❌ 失败: {type(exc).__name__}: {exc}")

    print()
    print("=" * 80)
    print("对照：LowResEncoder（低清轻量编码器，112x192）")
    print("=" * 80)
    try:
        st = convert_and_measure(LowResEncoder((16, 32, 64, 96)), (1, 3, 112, 192),
                                 "LowResEncoder", tmpdir)
        results["LowResEncoder"] = st
        print(f"  算子总数={st['total_ops']} 派发: {st['by_device']}  "
              f"ANE 占比={st['ane_ratio_of_analyzed']:.1%}")
    except Exception as exc:
        results["LowResEncoder"] = {"error": f"{type(exc).__name__}: {exc}"}
        print(f"  ❌ {type(exc).__name__}: {exc}")

    out = Path(__file__).resolve().parent / "02_ane_dispatch_result.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out}")
    print(f"临时 mlpackage 目录（可手查）：{tmpdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
