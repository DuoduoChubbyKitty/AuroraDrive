#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 时序模块 · 与真实骨干（v3-backbone 的 backbone_v3.py）对齐后的实测。

为什么必须重测（而不是沿用 01~07 的数字）：
  v3-backbone 的骨干输出是 **[B, 256, 14, 24] = 336 token**，D=192。
  而我前面的时序实验用的是 in_dim=128、token 数 72~128 的假设。
  token 数从 72 变成 336 后：
    · 时间维 attention 的 QK^T 是 O(T²)——但 336 是**视觉** token，不是时间步，
      时间维仍是 24 步；真正变化的是"时序模块吃到的每帧特征维度"
      （256，而非 128）。
    · 若把 temporal token 插进 transformer 的 token 序列（336+N），
      2 层 attention 的算力会随 token 数**平方**增长 → 必须重算。
  所以本脚本用**真实骨干输出维度**重测，给 model_v3.py 可直接用的数字。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/08_align_backbone.py
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
from importlib import import_module  # noqa: E402

_budget = import_module("01_budget")
MacCounter = _budget.MacCounter
_GRUStep = _budget._GRUStep

# 真实骨干配置（与 v3-backbone 的 BackboneConfig 默认值一致）
BACKBONE_C = 256      # 骨干输出通道
D_MODEL = 192         # transformer 主干维度
N_VISUAL_TOKENS = 336  # 14*24
FEAT_PER_FRAME = BACKBONE_C


# ----------------------------------------------------------------------------
class HierTemporalForV3(nn.Module):
    """时序模块（对齐 V3 真实维度）：24 帧 × 256 维 → 历史摘要 192 维。

    结构 = 3 段 × 8 帧层级：
      段内：Conv1d(k=8, stride=8)  → 3 个段 token，每段由 1 高清 + 7 低清构成
      段间：2 层因果膨胀卷积（dilation 1,2）→ 感受野覆盖全部 3 段
      输出：LayerNorm → 历史摘要 [1, D]
    """

    def __init__(self, in_dim=FEAT_PER_FRAME, hidden=D_MODEL, steps=24, group=8,
                 inter_layers=2, kernel=3):
        super().__init__()
        self.group = group
        self.n_groups = steps // group
        self.in_proj = nn.Linear(in_dim, hidden)
        self.intra = nn.Conv1d(hidden, hidden, kernel_size=group, stride=group)
        self.layers = nn.ModuleList()
        self.pads = []
        d = 1
        for _ in range(inter_layers):
            self.layers.append(nn.Conv1d(hidden, hidden, kernel, dilation=d))
            self.pads.append((kernel - 1) * d)
            d *= 2
        self.act = nn.ReLU()
        self.norm = nn.LayerNorm(hidden)

    def forward(self, seq):                 # [1,24,256]
        x = self.in_proj(seq).transpose(1, 2)      # [1,192,24]
        x = self.act(self.intra(x))                # [1,192,3]
        for conv, pad in zip(self.layers, self.pads):
            x = self.act(conv(nn.functional.pad(x, (pad, 0))))
        return self.norm(x[:, :, -1])              # [1,192]


class HierTemporalGRUForV3(nn.Module):
    """时序模块（GRU 变体）：段内卷积 + 段间 3 步静态展开 GRU。"""

    def __init__(self, in_dim=FEAT_PER_FRAME, hidden=D_MODEL, steps=24, group=8):
        super().__init__()
        self.n_groups = steps // group
        self.in_proj = nn.Linear(in_dim, hidden)
        self.intra = nn.Conv1d(hidden, hidden, group, stride=group)
        self.cell = _GRUStep(hidden, hidden)
        self.norm = nn.LayerNorm(hidden)

    def forward(self, seq):
        x = self.in_proj(seq).transpose(1, 2)
        x = torch.relu(self.intra(x)).transpose(1, 2)    # [1,3,192]
        h = torch.zeros_like(x[:, 0, :])
        for t in range(self.n_groups):
            h = self.cell(x[:, t, :], h)
        return self.norm(h)


class UnrollGRUForV3(nn.Module):
    """对照：24 步逐帧静态展开 GRU（不分层）。"""

    def __init__(self, in_dim=FEAT_PER_FRAME, hidden=D_MODEL, steps=24):
        super().__init__()
        self.steps = steps
        self.hidden = hidden
        self.in_proj = nn.Linear(in_dim, hidden)
        self.cell = _GRUStep(hidden, hidden)
        self.norm = nn.LayerNorm(hidden)

    def forward(self, seq):
        x = self.in_proj(seq)
        h = torch.zeros_like(x[:, 0, :])
        for t in range(self.steps):
            h = self.cell(x[:, t, :], h)
        return self.norm(h)


class TCNForV3(nn.Module):
    """对照：4 层因果膨胀 TCN（不分层）。"""

    def __init__(self, in_dim=FEAT_PER_FRAME, hidden=D_MODEL, steps=24, layers=4, kernel=3):
        super().__init__()
        self.in_proj = nn.Linear(in_dim, hidden)
        self.layers = nn.ModuleList()
        self.pads = []
        d = 1
        for _ in range(layers):
            self.layers.append(nn.Conv1d(hidden, hidden, kernel, dilation=d))
            self.pads.append((kernel - 1) * d)
            d *= 2
        self.act = nn.ReLU()
        self.norm = nn.LayerNorm(hidden)

    def forward(self, seq):
        x = self.in_proj(seq).transpose(1, 2)
        for conv, pad in zip(self.layers, self.pads):
            x = self.act(conv(nn.functional.pad(x, (pad, 0))))
        return self.norm(x[:, :, -1])


# ----------------------------------------------------------------------------
def _dev_key(usage):
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


def params(m):
    return sum(p.numel() for p in m.parameters())


def macs_of(m, shape):
    c = MacCounter(m)
    m.eval()
    with torch.no_grad():
        m(torch.zeros(*shape))
    c.close()
    return c.macs


def bench_and_dispatch(module, shape, tag, tmpdir):
    module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(module, torch.zeros(*shape), strict=False)
    mlm = ct.convert(
        traced, inputs=[ct.TensorType(name="x", shape=shape, dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
    pkg = str(tmpdir / f"{tag}.mlpackage")
    mlm.save(pkg)

    from coremltools.models.compute_plan import MLComputePlan
    mm = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
    plan = MLComputePlan.load_from_path(mm.get_compiled_model_path(),
                                        compute_units=ct.ComputeUnit.ALL)
    ops = list(plan.model_structure.program.functions["main"].block.operations)
    c = {}
    for op in ops:
        k = _dev_key(plan.get_compute_device_usage_for_mlprogram_operation(op))
        c[k] = c.get(k, 0) + 1
    analyzed = sum(v for k, v in c.items() if k != "const")

    def run(units):
        model = ct.models.MLModel(pkg, compute_units=units)
        x = np.zeros(shape, dtype=np.float32)
        for _ in range(15):
            model.predict({"x": x})
        ts = []
        for _ in range(80):
            t0 = time.perf_counter()
            model.predict({"x": x})
            ts.append((time.perf_counter() - t0) * 1000)
        ts.sort()
        return {"p50": round(statistics.median(ts), 4),
                "p95": round(ts[int(len(ts) * 0.95) - 1], 4)}

    return {
        "params": params(module), "macs": macs_of(module, shape),
        "total_ops": len(ops), "by_device": c,
        "ane_ratio": round(c.get("neuralEngine", 0) / max(analyzed, 1), 4),
        "all": run(ct.ComputeUnit.ALL), "cpu": run(ct.ComputeUnit.CPU_ONLY),
    }


def attn_macs_with_temporal_tokens(n_visual: int, n_temporal: int, d_model: int,
                                   layers: int, mlp_ratio: float = 4.0) -> dict:
    """计算 transformer 主干在插入 temporal token 后的 attention 算力。

    论文式 token 序列：[state; visual...]。我们额外插 temporal token：
      [state; temporal(N); visual(336)]
    """
    def one(n: int) -> int:
        per = 3 * n * d_model * d_model              # QKV
        per += 2 * n * n * d_model                   # QK^T + AV
        per += n * d_model * d_model                 # out proj
        per += 2 * n * d_model * int(d_model * mlp_ratio)  # FFN
        return per * layers

    base = one(n_visual + 1)                          # 论文式：state + visual
    out = {"tokens_base": n_visual + 1, "macs_base": base}
    for nt in n_temporal:
        n = n_visual + 1 + nt
        m = one(n)
        out[f"tokens_with_{nt}_temporal"] = n
        out[f"macs_with_{nt}_temporal"] = m
        out[f"ratio_with_{nt}_temporal"] = round(m / base, 4)
    return out


def main() -> int:
    tmpdir = Path(tempfile.mkdtemp(prefix="v3_align_"))
    results = {}
    seq_shape = (1, 24, FEAT_PER_FRAME)      # [1,24,256] —— 真实骨干输出维度

    print("=" * 88)
    print(f"对齐真实骨干：每帧特征 {FEAT_PER_FRAME} 维，24 帧 → [1,24,{FEAT_PER_FRAME}]，D={D_MODEL}")
    print("=" * 88)
    temps = {
        "层级 3段×8帧 + TCN段间": HierTemporalForV3(),
        "层级 3段×8帧 + GRU3步": HierTemporalGRUForV3(),
        "24步逐帧 unroll GRU": UnrollGRUForV3(),
        "4层因果 TCN": TCNForV3(),
    }
    rows = {}
    for name, mod in temps.items():
        tag = "t" + str(abs(hash(name)) % 100000)
        r = bench_and_dispatch(mod, seq_shape, tag, tmpdir)
        rows[name] = r
        print(f"\n  {name}")
        print(f"    params={r['params']:>9,}  MACs={r['macs']:>11,}  "
              f"算子={r['total_ops']} 派发={r['by_device']} ANE={r['ane_ratio']:.0%}")
        print(f"    ALL p50={r['all']['p50']:.4f}ms p95={r['all']['p95']:.4f}ms  "
              f"CPU p50={r['cpu']['p50']:.4f}ms  "
              f"加速={r['cpu']['p50']/max(r['all']['p50'],1e-9):.2f}×")
    results["temporal_aligned"] = rows

    print()
    print("=" * 88)
    print(f"transformer 主干插入 temporal token 的算力代价（视觉 {N_VISUAL_TOKENS} token, D={D_MODEL}）")
    print("=" * 88)
    for n_temp in ([1], [3], [8], [24]):
        pass
    attn = attn_macs_with_temporal_tokens(N_VISUAL_TOKENS, [0, 1, 3, 8, 24],
                                          D_MODEL, layers=4 * 2, mlp_ratio=4.0)
    for k, v in attn.items():
        if isinstance(v, int) and k.startswith("macs"):
            print(f"  {k:32s} {v/1e9:>8.3f} G")
        elif isinstance(v, float):
            print(f"  {k:32s} {v:>8.3f}×")
        else:
            print(f"  {k:32s} {v}")
    results["attn_scaling"] = attn

    out = Path(__file__).resolve().parent / "08_align_backbone_result.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out}")
    print(f"临时目录：{tmpdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
