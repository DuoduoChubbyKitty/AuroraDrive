#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 时序模块 ANE 派发实测 · 第二轮（决定性测量）。

第一轮（02_ane_dispatch.py）踩到的两个坑与结论：
  1. 设备识别不能用 `.type`（不存在），要按**类名**判断 → 已修。
  2. `nn.TransformerEncoderLayer` 在 coremltools 9.0 **无法转换**
     （NotImplementedError: op '_transformer_encoder_layer_fwd'）
     → 必须在报告里明确：时间维 attention 必须**手写**，不能用高层 API。

本轮回答三个问题：
  Q1 真实 ImageEncoder（2.52M）在 224x384 / 180x320 / 112x192 上的 ANE 派发？
     → 决定"低清帧走同一骨干"是否可行。
  Q2 手写 attention 版时序模块能否导出、能否上 ANE？
  Q3 "骨干 + 时序"拼成一个图（真实部署形状）后，时序算子还留在 ANE 吗？

用法：
    /usr/local/bin/python3.11 tools/v3_exp/03_ane_decisive.py
"""

from __future__ import annotations

import json
import sys
import tempfile
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
V4_Hierarchical = _budget.V4_Hierarchical
V5_HierGRU = _budget.V5_HierGRU


# ----------------------------------------------------------------------------
class ManualMHSA(nn.Module):
    """手写多头自注意力（替代 nn.MultiheadAttention / TransformerEncoderLayer）。

    ★ 为什么必须手写（coremltools 9.0 实测）：
      `nn.TransformerEncoderLayer` 会被 trace 成 `_transformer_encoder_layer_fwd`
      这一个不透明算子，coremltools **没有对应 convert 实现** → 导出直接
      NotImplementedError。`nn.MultiheadAttention` 同理有风险。
      拆成 Linear + matmul + softmax 后全是 CoreML 原生算子。
    """

    def __init__(self, d_model: int, heads: int, ffn_ratio: int = 2):
        super().__init__()
        assert d_model % heads == 0
        self.d_model, self.heads = d_model, heads
        self.dk = d_model // heads
        self.qkv = nn.Linear(d_model, d_model * 3)
        self.proj = nn.Linear(d_model, d_model)
        self.norm1 = nn.LayerNorm(d_model)
        self.norm2 = nn.LayerNorm(d_model)
        self.ffn = nn.Sequential(
            nn.Linear(d_model, d_model * ffn_ratio),
            nn.ReLU(),
            nn.Linear(d_model * ffn_ratio, d_model),
        )

    def forward(self, x):                      # x: [B,T,D]
        B, T, D = x.shape
        qkv = self.qkv(x)                      # [B,T,3D]
        q, k, v = qkv.chunk(3, dim=-1)
        # [B,T,D] → [B,heads,T,dk]：reshape 后转置，避免 view 依赖动态 shape
        q = q.reshape(B, T, self.heads, self.dk).transpose(1, 2)
        k = k.reshape(B, T, self.heads, self.dk).transpose(1, 2)
        v = v.reshape(B, T, self.heads, self.dk).transpose(1, 2)
        scale = float(self.dk) ** -0.5
        # 注意：不用 k.transpose(-2,-1).matmul，用显式 permute + matmul 更稳
        attn = torch.softmax(
            torch.matmul(q * scale, k.permute(0, 1, 3, 2)), dim=-1)   # [B,H,T,T]
        out = torch.matmul(attn, v)                                  # [B,H,T,dk]
        out = out.transpose(1, 2).reshape(B, T, D)
        x = self.norm1(x + self.proj(out))
        x = self.norm2(x + self.ffn(x))
        return x


class V3_ManualAttn(nn.Module):
    """V3'：时间维 self-attention（手写版，可导出）。"""

    def __init__(self, in_dim=128, d_model=128, steps=24, layers=2, heads=4, ffn_ratio=2):
        super().__init__()
        self.in_proj = nn.Linear(in_dim, d_model)
        self.pos = nn.Parameter(torch.zeros(1, steps, d_model))
        self.layers = nn.ModuleList([
            ManualMHSA(d_model, heads, ffn_ratio) for _ in range(layers)
        ])
        self.out_norm = nn.LayerNorm(d_model)

    def forward(self, x):
        x = self.in_proj(x) + self.pos
        for layer in self.layers:
            x = layer(x)
        return self.out_norm(x[:, -1, :])


class BackbonePlusTemporal(nn.Module):
    """真实部署形状：ImageEncoder → 特征序列 → 时序模块 → 输出向量。

    对应 V3 方案 A（共享骨干）：N 帧图像一次 batch 过骨干，得到 [N,256]，
    再视作 [1,N,256] 喂时序模块。
    """

    def __init__(self, temporal: nn.Module, frames: int, in_dim: int = 256,
                 temporal_in: int = 128, mode: str = "gru"):
        super().__init__()
        self.backbone = ImageEncoder(deploy=True, out_dim=256)
        self.frames = frames
        self.mode = mode
        if in_dim != temporal_in:
            self.dim_proj = nn.Linear(in_dim, temporal_in)
        else:
            self.dim_proj = nn.Identity()
        self.temporal = temporal

    def forward(self, x):                      # x: [frames,3,H,W]
        f = self.backbone(x)                   # [frames,256]
        seq = f.unsqueeze(0)                   # [1,frames,256]（batch 维=1）
        seq = self.dim_proj(seq)
        return self.temporal(seq)


# ----------------------------------------------------------------------------
DEVICE_MAP = {"neuralEngine": "ANE", "cpu": "CPU", "gpu": "GPU", "const": "const"}


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


def measure(module: nn.Module, input_shape: tuple, tag: str, tmpdir: Path) -> dict:
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

    from coremltools.models.compute_plan import MLComputePlan
    mm = ct.models.MLModel(pkg)
    plan = MLComputePlan.load_from_path(mm.get_compiled_model_path(),
                                        compute_units=ct.ComputeUnit.ALL)
    ops = list(plan.model_structure.program.functions["main"].block.operations)
    counts: dict[str, int] = {}
    for op in ops:
        k = _dev_key(plan.get_compute_device_usage_for_mlprogram_operation(op))
        counts[k] = counts.get(k, 0) + 1

    total = sum(counts.values())
    analyzed = total - counts.get("const", 0)
    ane = counts.get("neuralEngine", 0)
    res = {
        "tag": tag, "input_shape": list(input_shape),
        "total_ops": total, "const_ops": counts.get("const", 0),
        "analyzed_ops": analyzed,
        "ane": ane, "cpu": counts.get("cpu", 0), "gpu": counts.get("gpu", 0),
        "by_device": {DEVICE_MAP.get(k, k): v for k, v in counts.items()},
        "ane_ratio": round(ane / max(analyzed, 1), 4),
    }
    # 真机试跑（确认可执行 + 输出有限）
    try:
        out = mm.predict({"x": np.zeros(input_shape, dtype=np.float32)})
        arr = np.asarray(out[list(out.keys())[0]])
        res["out_shape"] = list(arr.shape)
        res["finite"] = bool(np.isfinite(arr).all())
    except Exception as exc:
        res["run_error"] = f"{type(exc).__name__}: {exc}"
    return res


def main() -> int:
    tmpdir = Path(tempfile.mkdtemp(prefix="v3_ane2_"))
    results: dict[str, dict] = {}

    print("=" * 82)
    print("Q1 真实 ImageEncoder（2.52M 参数）在不同分辨率下的 ANE 派发")
    print("=" * 82)
    for tag, (h, w, n) in {
        "ImageEncoder_1x224x384": (224, 384, 1),
        "ImageEncoder_3x224x384": (224, 384, 3),
        "ImageEncoder_1x180x320": (180, 320, 1),
        "ImageEncoder_21x112x192": (112, 192, 21),
        "ImageEncoder_1x112x192": (112, 192, 1),
    }.items():
        try:
            st = measure(ImageEncoder(deploy=True), (n, 3, h, w), tag, tmpdir)
            results[tag] = st
            print(f"  {tag:26s} 算子={st['total_ops']:4d} 派发={st['by_device']} "
                  f"ANE占比={st['ane_ratio']:.1%}")
        except Exception as exc:
            results[tag] = {"error": f"{type(exc).__name__}: {exc}"}
            print(f"  {tag:26s} ❌ {type(exc).__name__}: {exc}")

    print()
    print("=" * 82)
    print("Q2 手写 attention 版 V3'（对比第一轮失败的 nn.TransformerEncoderLayer）")
    print("=" * 82)
    try:
        st = measure(V3_ManualAttn(128, 128, 24, 2, 4), (1, 24, 128),
                     "V3p_ManualAttn_2layer", tmpdir)
        results["V3p_ManualAttn_2layer"] = st
        print(f"  算子={st['total_ops']:4d} 派发={st['by_device']} ANE占比={st['ane_ratio']:.1%} "
              f"out={st.get('out_shape')}")
    except Exception as exc:
        results["V3p_ManualAttn_2layer"] = {"error": f"{type(exc).__name__}: {exc}"}
        print(f"  ❌ {type(exc).__name__}: {exc}")

    print()
    print("=" * 82)
    print("Q3 真实部署形状：骨干 + 时序拼成一个图")
    print("=" * 82)
    combos = {
        "BB+V1gru24_3frames_224": (
            BackbonePlusTemporal(V1_UnrollGRU(128, 128, 3), 3), (3, 3, 224, 384)),
        "BB+V5hier24_3frames_224": (
            BackbonePlusTemporal(V5_HierGRU(128, 128, 3), 3), (3, 3, 224, 384)),
        "BB+V4tcn_3frames_224": (
            BackbonePlusTemporal(V4_Hierarchical(128, 128, 3, 1, 3), 3), (3, 3, 224, 384)),
        "BB+V1gru24_8frames_180": (
            BackbonePlusTemporal(V1_UnrollGRU(128, 128, 8), 8), (8, 3, 180, 320)),
    }
    for tag, (mod, shape) in combos.items():
        try:
            st = measure(mod, shape, tag, tmpdir)
            results[tag] = st
            print(f"  {tag:26s} 算子={st['total_ops']:4d} 派发={st['by_device']} "
                  f"ANE占比={st['ane_ratio']:.1%}")
        except Exception as exc:
            results[tag] = {"error": f"{type(exc).__name__}: {exc}"}
            print(f"  {tag:26s} ❌ {type(exc).__name__}: {exc}")

    out = Path(__file__).resolve().parent / "03_ane_decisive_result.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out}")
    print(f"临时目录：{tmpdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
