#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 时序模块 · 分辨率融合与层级分组结构对比（第五组实验，收官）。

回答两个必须用数据回答的问题：

  Q1 低清帧编码器怎么选？四选一，全部实测（21 帧 @112x192）：
     A. 走同一个完整 ImageEncoder（共享权重，特征空间一致）
     B. 独立 depthwise-separable 轻量编码器（便宜，但特征异空间）
     C. **共享骨干但只走前几层**（stem+stage1+stage2）后池化 ← 折中，本组重点
     D. 低清帧完全不进 CNN，用极小的 patch 编码

  Q2 层级分组该按哪种拓扑？（24 帧 = 3 高清 + 21 低清）
     拓扑甲：8 组 × 3 帧（若按用户原话字面"每三针一针"→ 8 高清 + 16 低清）
     拓扑乙：**3 段 × 8 帧**（1 高清锚 + 7 低清，匹配"3 高清 + 21 低清"）
     两者的算力/参数/信息损失对比。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/06_arch_compare.py
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
LowResEncoder = _budget.LowResEncoder
_GRUStep = _budget._GRUStep


# ----------------------------------------------------------------------------
# A/B/C/D 四种低清编码器
# ----------------------------------------------------------------------------
class TruncatedBackbone(nn.Module):
    """C：复用 ImageEncoder 的前 k 个 stage（**共享权重**），再做 GAP。

    为什么这个方案值得测：共享权重 → 特征空间与高清帧一致（跨分辨率的
    语义对齐天然成立）；只走前几层 → 算力远低于完整骨干。
    代价：池化前的分辨率比完整骨干高，感受野更小（对"看运动趋势"够用）。
    """

    def __init__(self, stages: int = 3, out_dim: int = 256):
        super().__init__()
        base = ImageEncoder(deploy=True, out_dim=out_dim)
        self.stage0 = base.stage0
        self.stage1 = base.stage1
        self.stage2 = base.stage2 if stages >= 3 else None
        self.stage3 = base.stage3 if stages >= 4 else None
        self.stage4 = base.stage4 if stages >= 5 else None
        self.stages = stages
        # 前 k 层的输出通道数（决定池化后的特征维）
        self.out_ch = {1: 48, 2: 48, 3: 96, 4: 192, 5: out_dim}[stages]
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))
        # 投影到与完整骨干一致的 256 维（跨分辨率特征对齐）
        self.proj = nn.Linear(self.out_ch, out_dim)

    def forward(self, x):
        x = self.stage0(x)
        x = self.stage1(x)
        if self.stages >= 3:
            x = self.stage2(x)
        if self.stages >= 4:
            x = self.stage3(x)
        if self.stages >= 5:
            x = self.stage4(x)
        x = self.global_pool(x).flatten(1)
        return self.proj(x)


class PatchStatEncoder(nn.Module):
    """D：低清帧不进 CNN —— 直接对下采样像素做线性编码。

    极端的"便宜到底"方案：自适应池化到 p×p 网格 → flatten → Linear。
    用于验证"低清帧到底需不需要卷积特征"这个下限。
    """

    def __init__(self, grid: int = 4, out_dim: int = 256):
        super().__init__()
        self.grid = grid
        self.pool = nn.AdaptiveAvgPool2d((grid, grid))
        self.proj = nn.Linear(3 * grid * grid, out_dim)

    def forward(self, x):
        x = self.pool(x).flatten(1)
        return self.proj(x)


# ----------------------------------------------------------------------------
# 层级时序融合（两种拓扑）
# ----------------------------------------------------------------------------
class HierTemporal(nn.Module):
    """层级时序融合：组内池化 → 组间因果 TCN。

    group=3 → 8 组（拓扑甲）；group=8 → 3 组（拓扑乙）。
    组内用 Conv1d(kernel=group, stride=group) 把每组压成一个组 token，
    组间用 1~N 层因果膨胀卷积。
    """

    def __init__(self, in_dim=128, hidden=128, steps=24, group=3,
                 inter_layers=3, kernel=3):
        super().__init__()
        self.group = group
        self.n_groups = steps // group
        self.in_proj = nn.Linear(in_dim, hidden)
        self.intra = nn.Conv1d(hidden, hidden, kernel_size=group, stride=group)
        self.layers = nn.ModuleList()
        self.pads = []
        d = 1
        n_layers = max(1, min(inter_layers, max(1, self.n_groups - 1)))
        for _ in range(n_layers):
            self.layers.append(nn.Conv1d(hidden, hidden, kernel, dilation=d))
            self.pads.append((kernel - 1) * d)
            d *= 2
        self.act = nn.ReLU()
        self.out_norm = nn.LayerNorm(hidden)

    def forward(self, x):
        x = self.in_proj(x).transpose(1, 2)      # [B,H,T]
        x = self.act(self.intra(x))              # [B,H,n_groups]
        for conv, pad in zip(self.layers, self.pads):
            x = self.act(conv(nn.functional.pad(x, (pad, 0))))
        return self.out_norm(x[:, :, -1])


class HierTemporalGRU(nn.Module):
    """层级时序：组内卷积 + 组间静态展开 GRU（组数少 → 递推链短）。"""

    def __init__(self, in_dim=128, hidden=128, steps=24, group=3):
        super().__init__()
        self.n_groups = steps // group
        self.hidden = hidden
        self.in_proj = nn.Linear(in_dim, hidden)
        self.intra = nn.Conv1d(hidden, hidden, group, stride=group)
        self.cell = _GRUStep(hidden, hidden)
        self.out_norm = nn.LayerNorm(hidden)

    def forward(self, x):
        x = self.in_proj(x).transpose(1, 2)
        x = torch.relu(self.intra(x)).transpose(1, 2)     # [B,n_groups,H]
        h = torch.zeros_like(x[:, 0, :])
        for t in range(self.n_groups):
            h = self.cell(x[:, t, :], h)
        return self.out_norm(h)


# ----------------------------------------------------------------------------
def _dev_key(usage) -> str:
    if usage is None:
        return "const"
    dev = getattr(usage, "preferred_compute_device", None)
    if dev is None:
        return "const"
    cls = type(dev).__name__
    if "NeuralEngine" in cls:
        return "neuralEngine"
    if "GPU" in cls:
        return "gpu"
    if "CPU" in cls:
        return "cpu"
    return cls


def convert(module, shape, tag, tmpdir):
    module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(module, torch.zeros(*shape), strict=False)
    mlm = ct.convert(
        traced,
        inputs=[ct.TensorType(name="x", shape=shape, dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
    pkg = str(tmpdir / f"{tag}.mlpackage")
    mlm.save(pkg)
    return pkg


def bench(pkg, shape, units, warmup=15, runs=60):
    model = ct.models.MLModel(pkg, compute_units=units)
    x = np.zeros(shape, dtype=np.float32)
    for _ in range(warmup):
        model.predict({"x": x})
    ts = []
    for _ in range(runs):
        t0 = time.perf_counter()
        model.predict({"x": x})
        ts.append((time.perf_counter() - t0) * 1000)
    ts.sort()
    return {"p50": round(statistics.median(ts), 4),
            "p95": round(ts[int(len(ts) * 0.95) - 1], 4)}


def dispatch(pkg):
    from coremltools.models.compute_plan import MLComputePlan
    mm = ct.models.MLModel(pkg)
    plan = MLComputePlan.load_from_path(mm.get_compiled_model_path(),
                                        compute_units=ct.ComputeUnit.ALL)
    ops = list(plan.model_structure.program.functions["main"].block.operations)
    c = {}
    for op in ops:
        k = _dev_key(plan.get_compute_device_usage_for_mlprogram_operation(op))
        c[k] = c.get(k, 0) + 1
    analyzed = sum(v for k, v in c.items() if k != "const")
    return {"total": len(ops), "by": c,
            "ane_ratio": round(c.get("neuralEngine", 0) / max(analyzed, 1), 4)}


def params(m):
    return sum(p.numel() for p in m.parameters())


def main() -> int:
    tmpdir = Path(tempfile.mkdtemp(prefix="v3_arch_"))
    results = {}

    print("=" * 88)
    print("Q1 低清帧（21 帧 @112x192）编码器四方案对比")
    print("=" * 88)
    shape_lo = (21, 3, 112, 192)
    candidates = {
        "A 完整 ImageEncoder（共享权重）": ImageEncoder(deploy=True, out_dim=256),
        "B 独立 dw-sep 轻量编码器": LowResEncoder((16, 32, 64, 96)),
        "C 共享骨干前3层(stem+s1+s2)": TruncatedBackbone(stages=3, out_dim=256),
        "C2 共享骨干前2层(stem+s1)": TruncatedBackbone(stages=2, out_dim=256),
        "D 极简 patch 池化(4x4)": PatchStatEncoder(grid=4, out_dim=256),
    }
    rows = []
    for name, mod in candidates.items():
        tag = name.split()[0].replace("/", "_")
        pkg = convert(mod, shape_lo, f"lo_{tag}", tmpdir)
        sp = bench(pkg, shape_lo, ct.ComputeUnit.ALL)
        cpu = bench(pkg, shape_lo, ct.ComputeUnit.CPU_ONLY)
        d = dispatch(pkg)
        row = {"name": name, "params": params(mod),
               "p50_ms": sp["p50"], "p95_ms": sp["p95"],
               "cpu_p50_ms": cpu["p50"], "speedup": round(cpu["p50"] / max(sp["p50"], 1e-9), 2),
               "ane_ratio": d["ane_ratio"], "ops": d["total"]}
        rows.append(row)
        print(f"  {name:32s} params={row['params']:>9,} p50={row['p50_ms']:6.3f}ms "
              f"p95={row['p95_ms']:6.3f}ms ANE={d['ane_ratio']:.0%} 加速={row['speedup']}×")
    results["low_res_encoder_compare"] = rows

    # 3 帧高清基准（用于算 24 帧图像侧总耗时）
    print()
    print("  高清基准：3 帧 224x384 过完整 ImageEncoder")
    pkg_hi = convert(ImageEncoder(deploy=True, out_dim=256), (3, 3, 224, 384), "hi3", tmpdir)
    sp_hi = bench(pkg_hi, (3, 3, 224, 384), ct.ComputeUnit.ALL)
    print(f"    p50={sp_hi['p50']:.3f}ms p95={sp_hi['p95']:.3f}ms")
    results["hi3_ms"] = sp_hi

    # 24 帧图像侧总耗时（各方案）
    print()
    print("  24 帧图像侧总耗时 = 高清 3 帧 + 低清 21 帧")
    totals = {}
    for row in rows:
        total = round(sp_hi["p50"] + row["p50_ms"], 4)
        total_p95 = round(sp_hi["p95"] + row["p95_ms"], 4)
        totals[row["name"]] = {"p50_ms": total, "p95_ms": total_p95}
        print(f"    {row['name']:32s} 合计 p50={total:6.3f}ms p95={total_p95:6.3f}ms")
    results["image_side_totals"] = totals

    print()
    print("=" * 88)
    print("Q2 层级时序融合：两种分组拓扑")
    print("=" * 88)
    tshape = (1, 24, 128)
    temps = {
        "拓扑甲 8组×3帧 (TCN)": HierTemporal(128, 128, 24, group=3, inter_layers=3),
        "拓扑甲 8组×3帧 (GRU)": HierTemporalGRU(128, 128, 24, group=3),
        "拓扑乙 3段×8帧 (TCN)": HierTemporal(128, 128, 24, group=8, inter_layers=2),
        "拓扑乙 3段×8帧 (GRU)": HierTemporalGRU(128, 128, 24, group=8),
        "对照 无分组 TCN4层": _budget.V2_TCN(128, 128, 24, 4),
        "对照 无分组 GRU24步": _budget.V1_UnrollGRU(128, 128, 24, 1),
    }
    trows = []
    for name, mod in temps.items():
        tag = "t_" + str(abs(hash(name)) % 100000)
        pkg = convert(mod, tshape, tag, tmpdir)
        sp = bench(pkg, tshape, ct.ComputeUnit.ALL)
        cpu = bench(pkg, tshape, ct.ComputeUnit.CPU_ONLY)
        d = dispatch(pkg)
        row = {"name": name, "params": params(mod),
               "p50_ms": sp["p50"], "p95_ms": sp["p95"],
               "cpu_p50_ms": cpu["p50"], "ane_ratio": d["ane_ratio"], "ops": d["total"]}
        trows.append(row)
        print(f"  {name:28s} params={row['params']:>8,} p50={row['p50_ms']:6.3f}ms "
              f"p95={row['p95_ms']:6.3f}ms ANE={d['ane_ratio']:.0%} ops={d['total']}")
    results["temporal_compare"] = trows

    out = Path(__file__).resolve().parent / "06_arch_compare_result.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out}")
    print(f"临时目录：{tmpdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
