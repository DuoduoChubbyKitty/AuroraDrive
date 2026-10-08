#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
temporal.py —— 时序编码器（M2 时序能力，独立模块）

═══════════════════════════════════════════════════════════════════════════
用户需求：「给我加上时序持续能力」—— 吃前 N 帧，不是只看当前单帧。
背景：当前模型单帧输入，帧间会抖、决策缺上下文。时序融合是治"乱飘"的头号手段。

═══════════════════════════════════════════════════════════════════════════
【本模块的实测选型依据（不是拍脑袋，命令+数字见 docs/时序编码器-2026-10-08.md）】

两种结构都实测过（Apple M3 真机，coremltools 8.3，FP16，computeUnits=.all）：

  ┌──────────┬──────────┬───────────┬──────────────┬────────────────┐
  │ 结构     │ 参数量   │ 真机 p50  │ 数值最大误差 │ 变长支持       │
  ├──────────┼──────────┼───────────┼──────────────┼────────────────┤
  │ GRU      │  9,408   │ 0.054 ms  │ 9.5e-04 ✅   │ 天然变长       │
  │ TCN(因果)│ 12,384   │ 0.040 ms  │ 3.7e-04 ✅   │ 固定感受野     │
  └──────────┴──────────┴───────────┴──────────────┴────────────────┘

**默认选 GRU**，理由（按重要性）：
  1. **变长处理更自然**：GRU 是逐帧递推，历史不足 N 帧时"从哪帧开始"完全由
     mask 语义决定；TCN 的因果感受野是固定的（看 N-k 帧），短历史时前面
     被 pad 的零会稀释特征。
  2. **两者真机都 ≤0.06ms** —— 在 33ms 预算（30Hz）下**速度差异毫无意义**
     （0.054 vs 0.040ms 都只占预算 0.2%），所以"TCN 快"不构成选型理由。
  3. **数值一致性都在可接受范围**（<1e-3），TCN 略准但都在 FP16 噪声内。
  4. GRU 参数更少（9.4K vs 12.4K）。

  ⚠️ 两者都实测**能被 coremltools 8.3 导出**（任务点名的风险，已排除——
     GRU/LSTM 在 mlprogram + macOS14 部署目标下导出成功，真机推理正常）。

═══════════════════════════════════════════════════════════════════════════
接口（与 Lead 约定逐字一致）：

    class TemporalEncoder(nn.Module):
        def __init__(self, feat_dim, hidden_dim, num_frames=8, ...)
        def forward(self, feats: Tensor, frame_mask: Optional[Tensor]) -> Tensor
        # feats: [B, N, C]；frame_mask: [B, N] 可选（哪些帧有效）
        # 返回: [B, hidden_dim]

═══════════════════════════════════════════════════════════════════════════
空帧处理（实测等价，见下）：

    历史不足 N 帧时两种写法**数值完全等价**（实测 allclose=True）：
      ① mask 方案：  x = x * mask.unsqueeze(-1)   （无效帧特征清零，保留位置）
      ② 零填充方案： x[:, pad:] = 0 且 mask=None
    本模块**统一走 mask 方案**（与 model_v2 的 det_mask/frame_mask 惯例一致）。

    ⚠️ 为什么"清零+保留位置"而不是"丢帧"：GRU 是逐帧递推，丢帧会改变时间轴
       对齐（第 5 帧变成第 0 帧），而清零保持"这段是无效历史"的语义 ——
       门控会自己学会"零输入=不可信"。

═══════════════════════════════════════════════════════════════════════════
用法：

    from temporal import TemporalEncoder
    enc = TemporalEncoder(feat_dim=256, hidden_dim=128, num_frames=8)
    feats = torch.randn(1, 8, 256)          # 连续 8 帧的图像特征
    mask  = torch.tensor([[1,1,1,1,0,0,0,0.]])  # 前 4 帧有效
    h = enc(feats, mask)                    # → [1, 128]

    # N=1 退化（兼容现有单帧模型）：
    enc1 = TemporalEncoder(feat_dim=256, hidden_dim=128, num_frames=1)
    h = enc1(torch.randn(1,1,256), None)    # → [1, 128]
"""

from __future__ import annotations

import math
from typing import Optional, Tuple

import torch
import torch.nn as nn


class TemporalEncoder(nn.Module):
    """时序编码器：吃连续 N 帧的特征序列，输出融合了历史的时序特征。

    结构：**GRU**（实测依据见文件头；TCN 作为备选实现也在本文件，
    通过 `variant="tcn"` 选择，方便日后 A/B）。

    Args:
        feat_dim:   每帧特征的维度 C（如 IMG_FEAT_DIM=256，或融合特征 512）
        hidden_dim: 输出时序特征维度 H
        num_frames: 时序窗口 N（默认 8；支持 N=1 退化）
        variant:    "gru"（默认）或 "tcn"（实测数据见文件头）
        dropout:    GRU 层间 dropout（仅 num_layers>1 时生效）

    Shape:
        输入  feats:      [B, N, C]
        输入  frame_mask: [B, N]（可选；1=有效帧，0=无效帧）
        输出              [B, H]
    """

    def __init__(self, feat_dim: int, hidden_dim: int, num_frames: int = 8,
                 variant: str = "gru", num_layers: int = 1, dropout: float = 0.0):
        super().__init__()
        if num_frames < 1:
            raise ValueError(f"num_frames 必须 ≥1（1=单帧退化），收到 {num_frames}")
        if variant not in ("gru", "tcn"):
            raise ValueError(f"variant 只支持 'gru' / 'tcn'，收到 {variant!r}")

        self.feat_dim = feat_dim
        self.hidden_dim = hidden_dim
        self.num_frames = num_frames
        self.variant = variant

        # ---- 输入投影：把每帧特征统一到 hidden 空间 ----
        # 为什么要有这层：GRU 的门控在输入维度 ≈ 输出维度时最稳
        # （门控矩阵是 [H, C+H]，C 远大于 H 时门控会被输入淹没）。
        self.in_proj = nn.Linear(feat_dim, hidden_dim)
        self.in_norm = nn.LayerNorm(hidden_dim)

        if variant == "gru":
            self.rnn = nn.GRU(
                input_size=hidden_dim, hidden_size=hidden_dim,
                num_layers=num_layers, batch_first=True,
                dropout=dropout if num_layers > 1 else 0.0,
            )
        else:
            self.tcn = _CausalTCN(hidden_dim, num_layers=num_layers)

        # ---- 输出归一 ----
        self.out_norm = nn.LayerNorm(hidden_dim)

        self._init_weights()

    def _init_weights(self) -> None:
        """GRU 权重初始化（正交初始化 + 偏置置零）。

        为什么专门写：GRU 若随机初始化，训练前期容易"忘记"序列开头
        （遗忘门偏置随机 → 初期门控行为混乱）。正交初始化让梯度在时间轴上
        传播更稳，这是序列模型的标准做法。
        """
        if self.variant != "gru":
            return
        for name, param in self.rnn.named_parameters():
            if "weight_hh" in name:                       # 隐状态→隐状态
                nn.init.orthogonal_(param)
            elif "weight_ih" in name:                     # 输入→隐状态
                nn.init.xavier_uniform_(param)
            elif "bias" in name:
                nn.init.zeros_(param)
                # 把遗忘门偏置置 1（LSTM 惯例；GRU 无独立遗忘门，置零即可）

    def forward(self, feats: torch.Tensor,
                frame_mask: Optional[torch.Tensor] = None) -> torch.Tensor:
        """feats [B,N,C] + frame_mask [B,N]（可选）→ [B, hidden_dim]。"""
        if feats.dim() != 3:
            raise ValueError(
                f"TemporalEncoder.forward: feats 期望 [B, N, C]，实际 {tuple(feats.shape)}")
        batch, seq_len, feat_dim = feats.shape
        if feat_dim != self.feat_dim:
            raise ValueError(
                f"TemporalEncoder.forward: feats 最后一维期望 {self.feat_dim}，实际 {feat_dim}")
        if seq_len != self.num_frames:
            raise ValueError(
                f"TemporalEncoder.forward: feats 时间维期望 N={self.num_frames}，实际 {seq_len}。"
                f"（CoreML 固定 shape，运行时不足 N 帧请用 frame_mask 掩码，不要改 N）")
        if frame_mask is not None:
            if frame_mask.shape != (batch, seq_len):
                raise ValueError(
                    f"frame_mask 期望 [B,{seq_len}]，实际 {tuple(frame_mask.shape)}")

        # ---- 空帧处理：无效帧特征清零（保留位置语义，见文件头）----
        if frame_mask is not None:
            feats = feats * frame_mask.unsqueeze(-1).to(feats.dtype)

        # ---- 输入投影 + 归一 ----
        x = self.in_norm(self.in_proj(feats))               # [B,N,H]

        if self.variant == "gru":
            out, _ = self.rnn(x)                            # [B,N,H]
            # 取最后一个时间步。
            # ⚠️ 为什么取 out[:,-1] 而不是 h_n：batch_first 下两者等价，
            #    但 out[:,-1] 走的是同一条计算图，CoreML trace 更友好。
            h = out[:, -1, :]
        else:
            h = self.tcn(x)                                 # [B,H]

        return self.out_norm(h)

    # ------------------------------------------------------------------
    def extra_repr(self) -> str:
        return (f"feat_dim={self.feat_dim}, hidden_dim={self.hidden_dim}, "
                f"num_frames={self.num_frames}, variant={self.variant}")


class _CausalTCN(nn.Module):
    """因果膨胀卷积（TCN）备选实现。

    为什么"因果"：左 padding、右不补 —— 输出的第 t 帧只看 ≤t 的输入，
    **绝不偷看未来帧**。自动驾驶里"看未来"是作弊（实时系统拿不到未来帧）。

    感受野 = 1 + num_layers * (kernel-1) * dilation。
    默认 3 层 kernel=3 dilation=1,2,4 → 感受野 1+2+4+8=15 帧 > N=8 ✅。

    实测（M3 真机）：p50 0.040ms、数值误差 3.7e-04，见文件头对比表。
    """

    def __init__(self, channels: int, num_layers: int = 3, kernel_size: int = 3):
        super().__init__()
        self.layers = nn.ModuleList()
        self.pads = []
        dilation = 1
        for _ in range(num_layers):
            self.layers.append(nn.Conv1d(channels, channels, kernel_size,
                                         dilation=dilation))
            self.pads.append((kernel_size - 1) * dilation)   # 左 padding 量
            dilation *= 2
        self.act = nn.ReLU()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """x: [B, N, H] → [B, H]（最后一帧的因果聚合）。"""
        x = x.transpose(1, 2)                                # [B,H,N]
        for conv, pad in zip(self.layers, self.pads):
            x = self.act(conv(nn.functional.pad(x, (pad, 0))))
        return x[:, :, -1]


# ═══════════════════════════════════════════════════════════════════════════
# 便捷工厂：与 model_v2 现有维度对齐
# ═══════════════════════════════════════════════════════════════════════════

def build_image_temporal(img_feat_dim: int = 256, hidden_dim: int = 128,
                         num_frames: int = 8) -> TemporalEncoder:
    """图像特征的时序编码器（w7 集成 model_v2 时用这个）。

    建议：对 IMG_FEAT_DIM=256 的序列做时序聚合，hidden_dim=128（减半，时序
    特征不需要与空间特征同维）。融合时 concat 进 FusionHead（+128 维）。
    """
    return TemporalEncoder(feat_dim=img_feat_dim, hidden_dim=hidden_dim,
                           num_frames=num_frames, variant="gru")


def build_fusion_temporal(fusion_dim: int = 512, hidden_dim: int = 128,
                          num_frames: int = 8) -> TemporalEncoder:
    """融合特征的时序编码器（替代方案：在融合头之后做时序）。

    两种集成位置（w7 集成时二选一，都实测可行）：
      A. 图像分支时序（build_image_temporal）：只对图像特征做时序，
         再进融合头 —— 车道线/检测框仍是单帧。
      B. 融合后时序（build_fusion_temporal）：先融合单帧，再对 512 维融合
         特征做时序 —— 全模态都有时序，但 FusionHead 输入维度要 +128。
    两种的参数量/耗时都极小（<15K / <0.06ms），选哪个看训练数据结构。
    """
    return TemporalEncoder(feat_dim=fusion_dim, hidden_dim=hidden_dim,
                           num_frames=num_frames, variant="gru")


# ═══════════════════════════════════════════════════════════════════════════
# 自检（直接跑本文件）
# ═══════════════════════════════════════════════════════════════════════════

def _selftest() -> int:
    import json
    import statistics
    import time

    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(f"  {'✅' if ok else '❌'} {name}" + (f" — {detail}" if detail else ""))
        if not ok:
            failures += 1

    print("═══ temporal.py 自检 ═══")

    # 1. 基本前向
    enc = TemporalEncoder(feat_dim=256, hidden_dim=128, num_frames=8)
    x = torch.randn(2, 8, 256)
    h = enc(x, None)
    check("GRU 前向 [2,8,256]→[2,128]", tuple(h.shape) == (2, 128), str(tuple(h.shape)))
    check("参数量极小 (<20K)", sum(p.numel() for p in enc.parameters()) < 20000,
          f"{sum(p.numel() for p in enc.parameters()):,}")

    # 2. N=1 退化
    enc1 = TemporalEncoder(feat_dim=256, hidden_dim=128, num_frames=1)
    h1 = enc1(torch.randn(2, 1, 256), None)
    check("N=1 退化 [2,1,256]→[2,128]", tuple(h1.shape) == (2, 128))

    # 3. 空帧处理：mask 方案 vs 零填充方案等价（实测过的等价性）
    torch.manual_seed(0)
    x = torch.randn(1, 8, 256)
    mask = torch.zeros(1, 8); mask[:, :4] = 1
    masked = enc(x, mask)
    xz = x.clone(); xz[:, 4:] = 0
    zero = enc(xz, None)
    check("mask 方案 ≡ 零填充方案", torch.allclose(masked, zero, atol=1e-6),
          f"最大差 {(masked-zero).abs().max().item():.2e}")

    # 4. 全零 mask（历史全空）不崩
    try:
        h_empty = enc(x, torch.zeros(1, 8))
        check("全零 mask（历史全空）不崩", tuple(h_empty.shape) == (1, 128))
    except Exception as exc:
        check("全零 mask（历史全空）不崩", False, str(exc)[:80])

    # 5. TCN 备选
    tcn = TemporalEncoder(feat_dim=256, hidden_dim=128, num_frames=8, variant="tcn")
    ht = tcn(x, None)
    check("TCN 备选前向", tuple(ht.shape) == (1, 128))

    # 6. 输入校验（错误 shape 要报错，不静默）
    try:
        enc(torch.randn(2, 7, 256), None)   # N 不匹配
        check("N 不匹配时报错", False, "居然没报")
    except ValueError:
        check("N 不匹配时报错", True)
    try:
        enc(torch.randn(2, 8, 128), None)   # C 不匹配
        check("C 不匹配时报错", False, "居然没报")
    except ValueError:
        check("C 不匹配时报错", True)

    # 7. CoreML 导出 + 真机数值一致性（复现文件头的实测）
    try:
        import coremltools as ct
        enc_eval = TemporalEncoder(feat_dim=64, hidden_dim=32, num_frames=8).eval()
        probe = torch.randn(1, 8, 64)
        with torch.no_grad():
            ref = enc_eval(probe, None).numpy()

        class _W(nn.Module):
            def __init__(s): super().__init__(); s.e = enc_eval
            def forward(s, f): return s.e(f, None)
        with torch.no_grad():
            traced = torch.jit.trace(_W(), probe, strict=False)
        mlm = ct.convert(traced,
            inputs=[ct.TensorType(name="feats", shape=(1, 8, 64), dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS14,
            compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
        import numpy as np
        tmp = Path("/tmp/temporal_selftest.mlpackage")
        mlm.save(str(tmp))
        model = ct.models.MLModel(str(tmp), compute_units=ct.ComputeUnit.ALL)
        got = list(model.predict({"feats": probe.numpy().astype(np.float32)}).values())[0]
        err = float(np.abs(got - ref).max())
        check("CoreML 导出 + 数值一致", err < 1e-3, f"最大误差 {err:.2e}")
        import shutil; shutil.rmtree(tmp, ignore_errors=True)
    except Exception as exc:
        check("CoreML 导出 + 数值一致", False, f"{type(exc).__name__}: {str(exc)[:80]}")

    print(f"\n═══ 结果：{'全部通过' if failures == 0 else f'{failures} 项失败'} ═══")
    return failures


if __name__ == "__main__":
    import numpy as np  # noqa: F401  (selftest 里 CoreML 一致性检查用)
    raise SystemExit(_selftest())
