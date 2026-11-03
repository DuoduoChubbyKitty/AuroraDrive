#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 时序模块真实延迟测量（M3 真机，coremltools 9.0）。

为什么需要这一份：
  compute plan 给出的是 **planner 的偏好设备**，不等于真实耗时。本脚本用
  `MLModel.predict` 实测延迟，并**与 CPU_ONLY 对照**：
  · 若 ALL 明显快于 CPU_ONLY → 证明 ANE 真在干活（不是 planner 标错）
  · 若两者相同 → 说明实际没走 ANE，compute plan 的"100% ANE"要打引号

测量口径（必须在报告里写清）：
  · Python `MLModel.predict` 含解释器/绑定开销（约 0.1~0.3ms），
    所以**绝对值偏大**，但同一口径下横向对比有效。
  · 报告 p50/p95（不含首次编译预热），warmup 20 次 + 计时 100 次。
  · 单线程、batch=1、FLOAT16。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/04_timing.py
"""

from __future__ import annotations

import json
import statistics
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import coremltools as ct  # noqa: E402
from src.model_v2 import ImageEncoder  # noqa: E402
from importlib import import_module  # noqa: E402

_budget = import_module("01_budget")
V1_UnrollGRU = _budget.V1_UnrollGRU
V5_HierGRU = _budget.V5_HierGRU
V4_Hierarchical = _budget.V4_Hierarchical
LowResEncoder = _budget.LowResEncoder
# 03_ane_decisive.py 文件名以数字开头 → 不能直接 import，用 importlib 指路径加载。
# 这两个类（手写 attention / 骨干+时序整图）只定义在那一份里，避免重复定义漂移。
import importlib.util as _ilu  # noqa: E402

_spec = _ilu.spec_from_file_location(
    "v3_ane_decisive", Path(__file__).resolve().parent / "03_ane_decisive.py")
_mod = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
V3_ManualAttn = _mod.V3_ManualAttn
BackbonePlusTemporal = _mod.BackbonePlusTemporal


def _bench(model_path: str, shape: tuple, units, warmup: int = 20, runs: int = 100):
    """返回 p50/p95/mean（毫秒）。"""
    model = ct.models.MLModel(model_path, compute_units=units)
    x = np.zeros(shape, dtype=np.float32)
    # 预热（含首次编译/图加载）
    for _ in range(warmup):
        model.predict({"x": x})
    times = []
    for _ in range(runs):
        t0 = time.perf_counter()
        model.predict({"x": x})
        times.append((time.perf_counter() - t0) * 1000.0)
    times.sort()
    return {
        "p50_ms": round(statistics.median(times), 4),
        "p95_ms": round(times[int(len(times) * 0.95) - 1], 4),
        "mean_ms": round(statistics.mean(times), 4),
        "min_ms": round(times[0], 4),
    }


def _convert(module: nn.Module, shape: tuple, tag: str, tmpdir: Path) -> str:
    module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(module, torch.zeros(*shape), strict=False)
    mlm = ct.convert(
        traced,
        inputs=[ct.TensorType(name="x", shape=shape, dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    pkg = str(tmpdir / f"{tag}.mlpackage")
    mlm.save(pkg)
    return pkg


class HybridImageSide(nn.Module):
    """混合分辨率图像侧：3 帧高清过 ImageEncoder，21 帧低清过 LowResEncoder。

    真实部署形状是**两个输入**（高清批、低清批），这里拼成单图便于测量：
      输入 x: [3,3,224,384]（高清）
             y: [21,3,112,192]（低清）
    输出：高清特征 [3,256] + 低清特征 [21,96]
    """

    def __init__(self):
        super().__init__()
        self.hi = ImageEncoder(deploy=True, out_dim=256)
        self.lo = LowResEncoder((16, 32, 64, 96))

    def forward(self, x, y):
        return self.hi(x), self.lo(y)


class TwoInputWrapper(nn.Module):
    """把双输入模型包成可 trace 的固定签名。"""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x, y):
        a, b = self.m(x, y)
        return a, b


def main() -> int:
    tmpdir = Path(tempfile.mkdtemp(prefix="v3_timing_"))
    results: dict[str, dict] = {}

    def report(tag: str, pkg: str, shape: tuple, extra: dict | None = None):
        try:
            all_u = _bench(pkg, shape, ct.ComputeUnit.ALL)
            cpu_u = _bench(pkg, shape, ct.ComputeUnit.CPU_ONLY)
            speedup = round(cpu_u["p50_ms"] / max(all_u["p50_ms"], 1e-9), 2)
            row = {"ALL": all_u, "CPU_ONLY": cpu_u, "speedup_cpu_over_all": speedup}
            if extra:
                row.update(extra)
            results[tag] = row
            print(f"  {tag:34s} ALL p50={all_u['p50_ms']:7.3f}ms p95={all_u['p95_ms']:7.3f}ms | "
                  f"CPU p50={cpu_u['p50_ms']:7.3f}ms | 加速 {speedup:.1f}×")
        except Exception as exc:
            results[tag] = {"error": f"{type(exc).__name__}: {exc}"}
            print(f"  {tag:34s} ❌ {type(exc).__name__}: {exc}")

    print("=" * 84)
    print("T1 单帧骨干（不同分辨率）—— 决定 24 帧要不要全过 ImageEncoder")
    print("=" * 84)
    for tag, shape in {
        "BB_1x180x320": (1, 3, 180, 320),
        "BB_1x224x384": (1, 3, 224, 384),
        "BB_1x112x192": (1, 3, 112, 192),
        "BB_3x224x384": (3, 3, 224, 384),
        "BB_21x112x192": (21, 3, 112, 192),
        "BB_24x180x320(全帧过骨干)": (24, 3, 180, 320),
    }.items():
        pkg = _convert(ImageEncoder(deploy=True), shape, tag.replace("(", "_").replace(")", ""), tmpdir)
        report(tag, pkg, shape)

    print()
    print("=" * 84)
    print("T2 低清专用编码器（112x192）")
    print("=" * 84)
    for tag, shape in {
        "LowRes_1x112x192": (1, 3, 112, 192),
        "LowRes_21x112x192": (21, 3, 112, 192),
    }.items():
        pkg = _convert(LowResEncoder((16, 32, 64, 96)), shape, tag, tmpdir)
        report(tag, pkg, shape)

    print()
    print("=" * 84)
    print("T3 时序模块独立延迟（24 帧输入 [1,24,128]）")
    print("=" * 84)
    for tag, mod in {
        "V1_unrollGRU_24steps": V1_UnrollGRU(128, 128, 24, 1),
        "V5_hier_conv+gru8": V5_HierGRU(128, 128, 24, 3),
        "V4_hier_conv only": V4_Hierarchical(128, 128, 24, 3, 3),
        "V3p_manualAttn_2layer": V3_ManualAttn(128, 128, 24, 2, 4),
    }.items():
        pkg = _convert(mod, (1, 24, 128), tag, tmpdir)
        report(tag, pkg, (1, 24, 128))

    print()
    print("=" * 84)
    print("T4 整图：骨干 + 时序（真实部署形状）")
    print("=" * 84)
    for tag, (mod, shape) in {
        "E2E_BB+GRU_8frames_180x320": (
            BackbonePlusTemporal(V1_UnrollGRU(128, 128, 8), 8), (8, 3, 180, 320)),
        "E2E_BB+GRU_24frames_180x320": (
            BackbonePlusTemporal(V1_UnrollGRU(128, 128, 24), 24), (24, 3, 180, 320)),
        "E2E_BB+GRU_3frames_224x384": (
            BackbonePlusTemporal(V1_UnrollGRU(128, 128, 3), 3), (3, 3, 224, 384)),
    }.items():
        pkg = _convert(mod, shape, tag, tmpdir)
        report(tag, pkg, shape)

    out = Path(__file__).resolve().parent / "04_timing_result.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out}")
    print(f"临时目录：{tmpdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
