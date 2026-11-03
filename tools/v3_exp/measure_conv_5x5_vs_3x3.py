#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""5×5 单层卷积 vs 拆成两层 3×3 —— ANE 派发与延迟实测对比

为什么做这个实验：
  论文 §IV.D 的骨干用 24/36/48 个 **5×5** kernel。Lead 提出「5×5 在 ANE 上支持，
  但效率不如分解成两层 3×3」，要求实测对比而不是拍脑袋。本脚本回答它。

对比对象（**参数预算对齐**，否则比较无意义）：
  M1  5×5 单层     : Conv5×5(64→128, s2)              参数量 64·128·25 = 204,800
  M2  3×3 两层分解 : Conv3×3(64→118, s2) + Conv3×3(118→128, s1)
                     参数量 64·118·9 + 118·128·9 = 203,904（与 M1 相差 0.4%）

测量指标：参数量 / FLOPs / ANE 派发 / ABBA 中位延迟（ANE 与 CPU 各一遍）。

⚠️ 本地计算，不联网、不启动 App、不建窗口。
"""
from __future__ import annotations

import statistics
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROOT))

import coremltools as ct                                    # noqa: E402
import numpy as np                                          # noqa: E402
from collections import Counter                             # noqa: E402
from coremltools.models.compute_plan import MLComputePlan   # noqa: E402
from coremltools.models.utils import compile_model          # noqa: E402

import shutil                                               # noqa: E402
import time                                                 # noqa: E402

OUT = Path("/tmp/v3_conv_compare")
NON_COMPUTE = {"const", "ios16.constexpr_lut_to_dense"}

# 测量用输入分辨率：取 224×384 经过 3 次 stride-2 后的典型中间特征图 28×48
IN_C, IN_H, IN_W = 64, 28, 48


def build_m1() -> nn.Module:
    """5×5 单层卷积（论文风格）。"""
    return nn.Sequential(
        nn.Conv2d(IN_C, 128, kernel_size=5, stride=2, padding=2, bias=False),
        nn.BatchNorm2d(128),
        nn.ReLU(inplace=True),
    ).eval()


def build_m2() -> nn.Module:
    """两层 3×3 分解（参数量与 M1 对齐）。"""
    return nn.Sequential(
        nn.Conv2d(IN_C, 118, kernel_size=3, stride=2, padding=1, bias=False),
        nn.BatchNorm2d(118),
        nn.ReLU(inplace=True),
        nn.Conv2d(118, 128, kernel_size=3, stride=1, padding=1, bias=False),
        nn.BatchNorm2d(128),
        nn.ReLU(inplace=True),
    ).eval()


def count_params(m: nn.Module) -> int:
    return sum(p.numel() for p in m.parameters())


def flops(m: nn.Module, shape) -> int:
    from torch.utils.flop_counter import FlopCounterMode
    c = FlopCounterMode(display=False)
    with torch.no_grad(), c:
        m(torch.randn(*shape))
    return int(c.get_total_flops())


def export_and_probe(tag: str, model: nn.Module) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    x = torch.randn(1, IN_C, IN_H, IN_W)
    traced = torch.jit.trace(model, x, strict=False)

    pkg = OUT / f"{tag}.mlpackage"
    mlc = OUT / f"{tag}.mlmodelc"
    for p in (pkg, mlc):
        if p.exists():
            shutil.rmtree(p)

    ml = ct.convert(traced, source="pytorch", convert_to="mlprogram",
                    inputs=[ct.TensorType(name="x", shape=(1, IN_C, IN_H, IN_W))],
                    minimum_deployment_target=ct.target.iOS17,
                    compute_units=ct.ComputeUnit.ALL)
    ml.save(str(pkg))
    compile_model(str(pkg), str(mlc))

    plan = MLComputePlan.load_from_path(str(mlc), compute_units=ct.ComputeUnit.ALL)
    fn = plan.model_structure.program.functions["main"]
    per_type: dict[str, Counter] = {}
    compute_total = compute_ane = 0
    for op in fn.block.operations:
        du = plan.get_compute_device_usage_for_mlprogram_operation(op)
        pd = du.preferred_compute_device if du else None
        dev = type(pd).__name__ if pd is not None else "NONE"
        per_type.setdefault(op.operator_name, Counter())[dev] += 1
        if op.operator_name not in NON_COMPUTE:
            compute_total += 1
            compute_ane += int(dev == "MLNeuralEngineComputeDevice")

    # ABBA 延迟
    img = np.random.randn(1, IN_C, IN_H, IN_W).astype(np.float32)
    models = {}
    for key, unit in (("ane", ct.ComputeUnit.ALL), ("cpu", ct.ComputeUnit.CPU_ONLY)):
        m = ct.models.MLModel(str(pkg), compute_units=unit)
        names = [f.name for f in m.input_description._fd_spec]
        models[key] = (m, {names[0]: img})

    samples = {"ane": [], "cpu": []}

    def once(key, warmup=8, iters=40):
        m, d = models[key]
        for _ in range(warmup):
            m.predict(d)
        t0 = time.perf_counter()
        for _ in range(iters):
            m.predict(d)
        return (time.perf_counter() - t0) / iters * 1000.0

    for _ in range(5):
        samples["ane"].append(once("ane"))
        samples["cpu"].append(once("cpu"))
        samples["cpu"].append(once("cpu"))
        samples["ane"].append(once("ane"))

    return {
        "tag": tag,
        "compute_total": compute_total,
        "compute_ane": compute_ane,
        "ane_ratio": round(compute_ane / compute_total, 4) if compute_total else 0.0,
        "device_types": {k: dict(v) for k, v in per_type.items() if k not in NON_COMPUTE},
        "latency_ane_ms": round(statistics.median(samples["ane"]), 3),
        "latency_cpu_ms": round(statistics.median(samples["cpu"]), 3),
    }


def main() -> int:
    print("=" * 78)
    print("5×5 单层 vs 两层 3×3 分解（参数对齐）")
    print(f"输入 {IN_C}×{IN_H}×{IN_W}，输出通道均 128，stride 2")
    print("=" * 78)

    results = []
    for tag, builder in (("M1_conv5x5", build_m1), ("M2_conv3x3x2", build_m2)):
        m = builder()
        n = count_params(m)
        f = flops(m, (1, IN_C, IN_H, IN_W))
        print(f"\n[{tag}] 参数 {n:,} | {f/1e6:.3f} MFLOPs")
        r = export_and_probe(tag, m)
        r["params"] = n
        r["flops_M"] = round(f / 1e6, 3)
        r["speedup"] = round(r["latency_cpu_ms"] / r["latency_ane_ms"], 2) \
            if r["latency_ane_ms"] else None
        print(f"  ANE 派发: {r['compute_ane']}/{r['compute_total']} = {r['ane_ratio']*100:.1f}%")
        print(f"  算子设备分布: {r['device_types']}")
        print(f"  ABBA 延迟: ANE {r['latency_ane_ms']} ms | CPU {r['latency_cpu_ms']} ms "
              f"| 加速 {r['speedup']}×")
        results.append(r)

    print(f"\n{'=' * 88}")
    print("【对比】5×5 vs 3×3×2（参数已对齐）")
    print(f"{'方案':<16} {'参数':>10} {'MFLOPs':>9} {'ANE%':>8} {'ANE ms':>9} {'CPU ms':>9}")
    print("-" * 88)
    for r in results:
        print(f"{r['tag']:<16} {r['params']:>10,} {r['flops_M']:>9.3f} "
              f"{r['ane_ratio']*100:>7.1f}% {r['latency_ane_ms']:>9.3f} {r['latency_cpu_ms']:>9.3f}")
    print("-" * 88)

    a, b = results[0], results[1]
    print(f"\n结论数据：3×3×2 相对 5×5 —— "
          f"参数 {b['params']/a['params']:.4f}×，"
          f"FLOPs {b['flops_M']/a['flops_M']:.3f}×，"
          f"ANE 延迟 {b['latency_ane_ms']/a['latency_ane_ms']:.3f}×")

    import json
    (OUT / "conv_compare.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f"结果已落盘: {OUT / 'conv_compare.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
