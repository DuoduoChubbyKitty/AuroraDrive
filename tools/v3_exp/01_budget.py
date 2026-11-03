#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 时序模块算力/参数量估算（可复现）。

目的：为 docs/v3-design/02-temporal.md 的 §5 提供**真实测量**而非手算。
方法：真实 nn.Module + forward hook 逐层累加 MACs（乘加次数），
      参数量用 sum(p.numel())。

口径说明
--------
* MACs ≠ FLOPs。本文所有"算力"均指 MACs（1 MAC = 1 乘 + 1 加 = 2 FLOPs）。
  报告里统一写 MACs，避免和论文的 FLOPs 口径混淆。
* 只统计 Conv2d / Conv1d / Linear（含 depthwise，按实际 kernel 面积算）。
  BN/激活/pooling 的逐元素开销不计入 MACs（ANE 上它们不是瓶颈，但会占算子数）。
* batch=1（真机单帧推理口径）。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/01_budget.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import torch
import torch.nn as nn

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from src.model_v2 import ImageEncoder  # noqa: E402


# ----------------------------------------------------------------------------
# 计数器
# ----------------------------------------------------------------------------
class MacCounter:
    """给模块挂 forward hook，累加 Conv/Linear 的 MACs。"""

    def __init__(self, module: nn.Module):
        self.macs = 0
        self.by_type: dict[str, int] = {}
        self._handles = []
        for m in module.modules():
            if isinstance(m, (nn.Conv2d, nn.Conv1d, nn.Linear)):
                self._handles.append(m.register_forward_hook(self._hook))

    def _hook(self, module, inputs, output):
        if isinstance(module, nn.Conv2d):
            out = output.shape
            k = module.kernel_size[0] * module.kernel_size[1]
            macs = out[0] * out[1] * out[2] * out[3] * (module.in_channels // module.groups) * k
            name = "Conv2d"
        elif isinstance(module, nn.Conv1d):
            out = output.shape
            k = module.kernel_size[0]
            macs = out[0] * out[1] * out[2] * (module.in_channels // module.groups) * k
            name = "Conv1d"
        else:
            out = output.shape
            macs = out[0] * out[-1] * module.in_features
            name = "Linear"
        self.macs += int(macs)
        self.by_type[name] = self.by_type.get(name, 0) + int(macs)

    def close(self):
        for h in self._handles:
            h.remove()
        self._handles.clear()


def count(module: nn.Module, *args, **kwargs):
    """返回 (macs, params, by_type)。"""
    module.eval()
    counter = MacCounter(module)
    with torch.no_grad():
        module(*args, **kwargs)
    counter.close()
    params = sum(p.numel() for p in module.parameters())
    return counter.macs, params, counter.by_type


# ----------------------------------------------------------------------------
# 低清轻量编码器（候选方案 B 的核心）
# ----------------------------------------------------------------------------
class LowResEncoder(nn.Module):
    """低清帧专用轻量编码器：depthwise-separable 卷积栈。

    为什么不用同一个 ImageEncoder：
      ImageEncoder 的 stage3 是 6 个 96→192 的 3×3 密集卷积（≈1.8M 参数、
      占骨干 72% 算力），对"只看运动趋势"的低清帧是严重浪费；
      且它的固定 stride 结构对 112×192 输入会输出 7×12，仍要过 GAP。

    结构（112×192 输入）：
        stem  Conv 3→C1 k3 s2            → 56×96
        block Conv C1→C2 k3 s2 (dw+pw)   → 28×48
        block Conv C2→C3 k3 s2 (dw+pw)   → 14×24
        block Conv C3→C4 k3 s2 (dw+pw)   → 7×12
        GAP → C4
    """

    def __init__(self, channels: tuple[int, int, int, int] = (16, 32, 64, 96),
                 out_dim: int | None = None):
        super().__init__()
        c1, c2, c3, c4 = channels
        self.stem = nn.Sequential(
            nn.Conv2d(3, c1, 3, stride=2, padding=1, bias=False),
            nn.BatchNorm2d(c1), nn.ReLU(inplace=True),
        )

        def _dw_block(cin, cout, stride=2):
            return nn.Sequential(
                nn.Conv2d(cin, cin, 3, stride=stride, padding=1, groups=cin, bias=False),
                nn.BatchNorm2d(cin), nn.ReLU(inplace=True),
                nn.Conv2d(cin, cout, 1, bias=False),
                nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
            )

        self.block1 = _dw_block(c1, c2)
        self.block2 = _dw_block(c2, c3)
        self.block3 = _dw_block(c3, c4)
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))
        self.out_dim = out_dim or c4

    def forward(self, x):
        x = self.stem(x)
        x = self.block1(x)
        x = self.block2(x)
        x = self.block3(x)
        x = self.global_pool(x)
        return x.flatten(1)


# ----------------------------------------------------------------------------
# 时序融合候选（全部静态展开，无 while_loop）
# ----------------------------------------------------------------------------
class _GRUStep(nn.Module):
    """单步 GRU（与 src/temporal.py 的 _StrictGRUCell 同款数学）。"""

    def __init__(self, input_dim, hidden_dim):
        super().__init__()
        self.x_r = nn.Linear(input_dim, hidden_dim)
        self.h_r = nn.Linear(hidden_dim, hidden_dim)
        self.x_z = nn.Linear(input_dim, hidden_dim)
        self.h_z = nn.Linear(hidden_dim, hidden_dim)
        self.x_n = nn.Linear(input_dim, hidden_dim)
        self.h_n = nn.Linear(hidden_dim, hidden_dim)

    def forward(self, x, h):
        r = torch.sigmoid(self.x_r(x) + self.h_r(h))
        z = torch.sigmoid(self.x_z(x) + self.h_z(h))
        n = torch.tanh(self.x_n(x) + r * self.h_n(h))
        return (1.0 - z) * n + z * h


class V1_UnrollGRU(nn.Module):
    """V1：24 步静态展开 GRU（共享 cell，单层）。"""

    def __init__(self, in_dim=128, hidden=128, steps=24, layers=1):
        super().__init__()
        self.steps, self.hidden = steps, hidden
        self.in_proj = nn.Linear(in_dim, hidden)
        self.cells = nn.ModuleList([_GRUStep(hidden, hidden) for _ in range(layers)])
        self.out_norm = nn.LayerNorm(hidden)

    def forward(self, x):              # x: [B,T,C]
        x = self.in_proj(x)                       # [B,T,H]
        # ★ 坑：写 `B, T, _ = x.shape` + x.new_zeros(B, H) 会被 torch.jit.trace
        #   固化成 **int 算子**，coremltools 9.0 转换直接报
        #   "converting 'int' op ... only 0-dimensional arrays can be converted"。
        #   用 zeros_like 从张量切片派生零状态 → 纯张量算子，导出干净。
        h = [torch.zeros_like(x[:, 0, :]) for _ in self.cells]
        for t in range(self.steps):
            inp = x[:, t, :]
            for i, cell in enumerate(self.cells):
                h[i] = cell(inp, h[i])
                inp = h[i]
        return self.out_norm(h[-1])


class V2_TCN(nn.Module):
    """V2：因果膨胀 1D 卷积（TCN），末端取最后一帧。"""

    def __init__(self, in_dim=128, hidden=128, steps=24, layers=4, kernel=3):
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
        self.out_norm = nn.LayerNorm(hidden)

    def forward(self, x):
        x = self.in_proj(x).transpose(1, 2)      # [B,H,T]
        for conv, pad in zip(self.layers, self.pads):
            x = self.act(conv(nn.functional.pad(x, (pad, 0))))
        return self.out_norm(x[:, :, -1])


class V3_TemporalAttn(nn.Module):
    """V3：时间维 self-attention（2 层，4 头，FFN ratio 2），加可学习时间位置编码。"""

    def __init__(self, in_dim=128, d_model=128, steps=24, layers=2, heads=4, ffn_ratio=2):
        super().__init__()
        self.in_proj = nn.Linear(in_dim, d_model)
        self.pos = nn.Parameter(torch.zeros(1, steps, d_model))
        enc = nn.TransformerEncoderLayer(
            d_model=d_model, nhead=heads, dim_feedforward=d_model * ffn_ratio,
            dropout=0.0, batch_first=True, norm_first=True)
        self.encoder = nn.TransformerEncoder(enc, num_layers=layers, enable_nested_tensor=False)
        self.out_norm = nn.LayerNorm(d_model)

    def forward(self, x):
        # self.pos 的 T 与输入 T 固定一致（CoreML 固定 shape）→ 直接广播相加
        x = self.encoder(self.in_proj(x) + self.pos)
        return self.out_norm(x[:, -1, :])


class V4_Hierarchical(nn.Module):
    """V4：层级融合 —— 先组内（3 帧）卷积，再组间 TCN。

    24 帧 = 8 组 × 3 帧（1 高清 + 2 低清）。组内 Conv1d(k=3, stride=3) 生成
    8 个组 token；组间 3 层因果膨胀卷积（dilation 1,2,4，感受野 15 组 ≥ 8）。
    """

    def __init__(self, in_dim=128, hidden=128, steps=24, group=3, layers=3, kernel=3):
        super().__init__()
        self.group = group
        self.n_groups = steps // group
        self.in_proj = nn.Linear(in_dim, hidden)
        self.intra = nn.Conv1d(hidden, hidden, kernel, stride=group)
        self.layers = nn.ModuleList()
        self.pads = []
        d = 1
        for _ in range(layers):
            self.layers.append(nn.Conv1d(hidden, hidden, kernel, dilation=d))
            self.pads.append((kernel - 1) * d)
            d *= 2
        self.act = nn.ReLU()
        self.out_norm = nn.LayerNorm(hidden)

    def forward(self, x):
        x = self.in_proj(x).transpose(1, 2)          # [B,H,T]
        x = self.act(self.intra(x))                  # [B,H,8]
        for conv, pad in zip(self.layers, self.pads):
            x = self.act(conv(nn.functional.pad(x, (pad, 0))))
        return self.out_norm(x[:, :, -1])


class V5_HierGRU(nn.Module):
    """V5：组内卷积 + 组间 8 步静态展开 GRU（层级 + 低步数递推）。"""

    def __init__(self, in_dim=128, hidden=128, steps=24, group=3):
        super().__init__()
        self.group, self.hidden = group, hidden
        self.n_groups = steps // group
        self.in_proj = nn.Linear(in_dim, hidden)
        self.intra = nn.Conv1d(hidden, hidden, group, stride=group)
        self.cell = _GRUStep(hidden, hidden)
        self.out_norm = nn.LayerNorm(hidden)

    def forward(self, x):
        x = self.in_proj(x).transpose(1, 2)
        x = torch.relu(self.intra(x)).transpose(1, 2)   # [B,8,H]
        h = torch.zeros_like(x[:, 0, :])                # 见 V1 的同款 int-op 坑
        for t in range(x.shape[1]):
            h = self.cell(x[:, t, :], h)
        return self.out_norm(h)


# ----------------------------------------------------------------------------
def fmt(n: int) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)


def main() -> int:
    results = {}

    print("=" * 78)
    print("A. 图像骨干 ImageEncoder（真实模块，batch=1）")
    print("=" * 78)
    img_rows = []
    for name, (h, w) in {
        "180x320（现有基线）": (180, 320),
        "224x384（V3 高清）": (224, 384),
        "112x192（V3 低清）": (112, 192),
    }.items():
        enc = ImageEncoder(deploy=True)
        x = torch.zeros(1, 3, h, w)
        macs, params, _ = count(enc, x)
        img_rows.append((name, h, w, macs, params))
        print(f"  {name:22s} MACs={fmt(macs):>10s}  params={fmt(params):>8s}")
    results["image_encoder"] = [
        {"name": n, "h": h, "w": w, "macs": m, "params": p} for n, h, w, m, p in img_rows
    ]

    print()
    print("=" * 78)
    print("B. 低清专用轻量编码器 LowResEncoder（batch=1, 112x192）")
    print("=" * 78)
    lo_rows = []
    for tag, ch in {
        "tiny(16,32,64,96)": (16, 32, 64, 96),
        "mid(24,48,96,128)": (24, 48, 96, 128),
    }.items():
        enc = LowResEncoder(ch)
        x = torch.zeros(1, 3, 112, 192)
        macs, params, _ = count(enc, x)
        lo_rows.append((tag, macs, params))
        print(f"  {tag:20s} MACs={fmt(macs):>10s}  params={fmt(params):>8s}")
    results["low_res_encoder"] = [
        {"name": t, "macs": m, "params": p} for t, m, p in lo_rows
    ]

    print()
    print("=" * 78)
    print("C. 时序融合候选（24 帧，in_dim=128，hidden=128，batch=1）")
    print("=" * 78)
    variants = {
        "V1 unroll-GRU x24 (1层)": V1_UnrollGRU(128, 128, 24, 1),
        "V1b unroll-GRU x24 (2层)": V1_UnrollGRU(128, 128, 24, 2),
        "V2 TCN 4层 d=1,2,4,8": V2_TCN(128, 128, 24, 4),
        "V3 temporal-attn 2层/4头": V3_TemporalAttn(128, 128, 24, 2, 4),
        "V4 hierarchical 组内3+TCN3层": V4_Hierarchical(128, 128, 24, 3, 3),
        "V5 hierarchical 组内3+GRU8步": V5_HierGRU(128, 128, 24, 3),
    }
    t_rows = []
    for name, mod in variants.items():
        x = torch.zeros(1, 24, 128)
        macs, params, by = count(mod, x)
        t_rows.append((name, macs, params, by))
        print(f"  {name:32s} MACs={fmt(macs):>10s}  params={fmt(params):>9s}  {by}")
    results["temporal_variants"] = [
        {"name": n, "macs": m, "params": p, "by_type": b} for n, m, p, b in t_rows
    ]

    print()
    print("=" * 78)
    print("D. 端到端图像侧组合（24 帧：3 高清 + 21 低清）")
    print("=" * 78)
    hi = ImageEncoder(deploy=True)
    lo = LowResEncoder((16, 32, 64, 96))
    m_hi, p_hi, _ = count(hi, torch.zeros(3, 3, 224, 384))
    m_lo, p_lo, _ = count(lo, torch.zeros(21, 3, 112, 192))
    base = ImageEncoder(deploy=True)
    m_base, p_base, _ = count(base, torch.zeros(24, 3, 180, 320))
    print(f"  基线：24 帧全 180x320 过同一骨干       MACs={fmt(m_base):>10s}")
    print(f"  混合：3 帧 224x384 过 ImageEncoder     MACs={fmt(m_hi):>10s}")
    print(f"        21 帧 112x192 过 LowResEncoder   MACs={fmt(m_lo):>10s}")
    print(f"        合计                              MACs={fmt(m_hi+m_lo):>10s}"
          f"   （基线 {m_hi+m_lo and round((m_hi+m_lo)/m_base*100,1)}%）")
    print(f"  参数量：ImageEncoder={fmt(p_hi)}  LowResEncoder={fmt(p_lo)}  "
          f"合计={fmt(p_hi+p_lo)}")
    results["e2e_image"] = {
        "baseline_24f_180x320_macs": m_base,
        "hybrid_hi3_macs": m_hi, "hybrid_lo21_macs": m_lo,
        "hybrid_total_macs": m_hi + m_lo,
        "ratio_vs_baseline": round((m_hi + m_lo) / m_base, 4),
        "image_encoder_params": p_hi, "low_res_encoder_params": p_lo,
    }

    print()
    print("=" * 78)
    print("E. 其它配置：8 高清 + 16 低清（若按用户原话字面「每三针一针」）")
    print("=" * 78)
    m_hi8, _, _ = count(ImageEncoder(deploy=True), torch.zeros(8, 3, 224, 384))
    m_lo16, _, _ = count(LowResEncoder((16, 32, 64, 96)), torch.zeros(16, 3, 112, 192))
    print(f"  8×224x384 + 16×112x192  MACs={fmt(m_hi8+m_lo16):>10s}"
          f"  （相对 3+21 的 {(m_hi8+m_lo16)/(m_hi+m_lo):.2f}×）")
    results["e2e_8hi16lo"] = {"macs": m_hi8 + m_lo16,
                              "ratio_vs_3hi21lo": round((m_hi8 + m_lo16) / (m_hi + m_lo), 4)}

    out = Path(__file__).resolve().parent / "01_budget_result.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
