#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
model_v3_experiments.py —— 骨干网络替换实验（T6）

═══════════════════════════════════════════════════════════════════════════
任务：把 M2 模型（src/model_v2.py）的**图像骨干**换成其他候选，对比：
      参数量 / INT8 大小 / M3 真机耗时 / 训练收敛速度

硬约束（用户）：
  · INT8 体积 ≤ 10MB
  · 能收「图像 + 车道线 + 检测框 + 状态」
  · **不要可行驶区域**
  · 第三视角、M3 上 30Hz（总预算 33ms）

═══════════════════════════════════════════════════════════════════════════
【本脚本的诚实边界 —— 先说清楚，别把估算当实测】

本脚本产出**两类**数字，报告里必须分开标注：

  ① 参数量 / INT8 体积        —— **实测**（torch 逐参数统计，可复现）
  ② M3 真机耗时              —— **估算**（用 FLOPs 代理），**不是真机测的**
     · 本机是 Apple Silicon Mac，**不是 M3 游戏机**；没有真机就没法测真机
     · 脚本会给 FLOPs + 一个「相对 RepVGG 的倍数」，这是**可验证的代理指标**
     · 真机耗时必须由「导出 CoreML → 在 M3 上跑 --perf-selftest」得到
     · ⚠️ 任何把 FLOPs 换算成「xx ms」的写法都是估算，报告里必须标注

  ③ 训练收敛速度            —— **需要真实数据才能测**，本脚本给的是
     「能否跑通 + 单步耗时」，不是收敛曲线（数据被用户删了，见 M8 报告）

═══════════════════════════════════════════════════════════════════════════
用法：
    ./.venv-yolo26/bin/python3 src/model_v3_experiments.py            # 全部
    ./.venv-yolo26/bin/python3 src/model_v3_experiments.py --quick    # 跳过耗时测量
    ./.venv-yolo26/bin/python3 src/model_v3_experiments.py --flops    # 只测 FLOPs
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import torch
import torch.nn as nn

# 让脚本能被从仓库根目录直接跑
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import model_v2  # noqa: E402  （只读，绝不修改）


# ═══════════════════════════════════════════════════════════════════════════
# 0. 常量与基准
# ═══════════════════════════════════════════════════════════════════════════

#: 用户硬约束
INT8_BUDGET_MB = 10.0

#: 输入规格（**照 model_v2 的真实契约**，第一次跑时我猜错过，已按源码修正）
IMG_SHAPE = (3, 180, 320)     # 第三视角截屏
LANE_SHAPE = (1, 160, 160)    # MaskGrid 二值栅格
DET_FEAT_DIM = model_v2.DET_FEAT_DIM     # = 12（每框 12 维）
STATE_DIM = model_v2.STATE_DIM           # = 8
#: 检测框槽位数：**M2 用「固定 N + det_mask」处理变长**（这是 M2 的设计决策）。
#: 这里默认 20；若 model_v2 里定义了 DET_N 就用它的，保证与训练脚本一致。
DET_N = getattr(model_v2, "DET_N", 20)
DET_SHAPE = (DET_N, DET_FEAT_DIM)


# ═══════════════════════════════════════════════════════════════════════════
# 1. 候选骨干定义
# ═══════════════════════════════════════════════════════════════════════════

class ShuffleNetV2Unit(nn.Module):
    """ShuffleNetV2 基本单元（channel split + 逐点/深度可分离卷积）。

    实现依据：ShuffleNetV2 论文（Ma et al., ECCV 2018）§3.2 的 basic unit。
    为什么用它替换 RepVGG：
      · 计算量极低（depthwise + 1x1），CoreML 对 depthwise conv 支持良好
      · 0.5x 宽度下参数量约 2.3M（含分类头；这里只用特征提取部分，更小）
    """

    def __init__(self, inp: int, oup: int, stride: int = 1):
        super().__init__()
        self.stride = stride
        branch_features = oup // 2
        assert stride in (1, 2), "stride 只能是 1 或 2"

        if stride == 1:
            # 训练/推理同构（ShuffleNetV2 的 stride=1 单元无分支差异）
            self.branch1 = nn.Identity()
        else:
            self.branch1 = nn.Sequential(
                nn.Conv2d(inp, inp, 3, stride, 1, groups=inp, bias=False),
                nn.BatchNorm2d(inp),
                nn.Conv2d(inp, branch_features, 1, 1, 0, bias=False),
                nn.BatchNorm2d(branch_features),
                nn.ReLU(inplace=True),
            )

        self.branch2 = nn.Sequential(
            nn.Conv2d(inp if stride > 1 else branch_features,
                      branch_features, 1, 1, 0, bias=False),
            nn.BatchNorm2d(branch_features),
            nn.ReLU(inplace=True),
            nn.Conv2d(branch_features, branch_features, 3, stride, 1,
                      groups=branch_features, bias=False),
            nn.BatchNorm2d(branch_features),
            nn.Conv2d(branch_features, branch_features, 1, 1, 0, bias=False),
            nn.BatchNorm2d(branch_features),
            nn.ReLU(inplace=True),
        )

    @staticmethod
    def channel_shuffle(x: torch.Tensor, groups: int) -> torch.Tensor:
        batch, num_channels, height, width = x.size()
        channels_per_group = num_channels // groups
        x = x.view(batch, groups, channels_per_group, height, width)
        x = torch.transpose(x, 1, 2).contiguous()
        return x.view(batch, -1, height, width)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.stride == 1:
            x1, x2 = x.chunk(2, dim=1)
            out = torch.cat((x1, self.branch2(x2)), dim=1)
        else:
            out = torch.cat((self.branch1(x), self.branch2(x)), dim=1)
        return self.channel_shuffle(out, 2)


class ShuffleNetV2Backbone(nn.Module):
    """ShuffleNetV2 0.5x 风格骨干 → [B, out_dim]。

    宽度配置照 ShuffleNetV2 0.5x 官方档（[24,48,96,192]），但：
      · **砍掉分类头**（本项目只要特征）
      · 适配 180×320 非方形输入

    ⚠️ **一个必须遵守的结构约束**（我第一次写错了，实测报
       `expected input[1,48,12,20] to have 96 channels`）：
       ShuffleNetV2 的 `stride=1` 单元会把输入 **channel split 成两半**
       （`x.chunk(2, dim=1)`），右半走分支后与左半 concat。
       因此 **stride=1 的单元必须 inp == oup**，否则通道数对不上。
       所以每个 stage 的**第 0 个单元做 stride=2 升通道**，后续单元保持同通道。

    分辨率演进（输入 180×320）：
        stem conv s2   →  24ch @ 90×160
        maxpool s2     →  24ch @ 45×80
        stage1 s2 ×4   →  48ch @ 23×40
        stage2 s2 ×4   →  96ch @ 12×20
        stage3 s2 ×4   → 192ch @  6×10
        tail 1×1       → out_dim @ 6×10
        GAP            → out_dim
    """

    def __init__(self, out_dim: int = model_v2.IMG_FEAT_DIM):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(3, 24, 3, 2, 1, bias=False),
            nn.BatchNorm2d(24),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(3, 2, 1),
        )
        self.stage1 = self._make_stage(24, 48, 4, stride=2)    # → 23×40
        self.stage2 = self._make_stage(48, 96, 4, stride=2)    # → 12×20
        self.stage3 = self._make_stage(96, 192, 4, stride=2)   # → 6×10
        self.tail = nn.Sequential(
            nn.Conv2d(192, out_dim, 1, 1, 0, bias=False),
            nn.BatchNorm2d(out_dim),
            nn.ReLU(inplace=True),
        )
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))

    @staticmethod
    def _make_stage(inp: int, oup: int, blocks: int, stride: int) -> nn.Sequential:
        """第 0 个单元升通道+下采样；其余单元 stride=1 且 inp==oup（结构约束）。"""
        layers: List[nn.Module] = [ShuffleNetV2Unit(inp, oup, stride)]
        for _ in range(blocks - 1):
            layers.append(ShuffleNetV2Unit(oup, oup, 1))
        return nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.stem(x)
        x = self.stage1(x)
        x = self.stage2(x)
        x = self.stage3(x)
        x = self.tail(x)
        return self.global_pool(x).flatten(1)


class SqueezeExcite(nn.Module):
    """MobileNetV3 的 SE 模块（hard-swish 版）。"""

    def __init__(self, channels: int, reduced: int):
        super().__init__()
        self.fc1 = nn.Conv2d(channels, reduced, 1)
        self.fc2 = nn.Conv2d(reduced, channels, 1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        scale = x.mean((2, 3), keepdim=True)
        scale = torch.relu(self.fc1(scale))
        scale = torch.sigmoid(self.fc2(scale))
        return x * scale


class MobileNetV3SmallBlock(nn.Module):
    """MobileNetV3-Small 的 inverted residual + SE 块（简化实现）。

    依据：MobileNetV3 论文（Howard et al., ICCV 2019）Table 1 的 Small 配置。
    ⚠️ 这里用 ReLU 代替 hard-swish：**hard-swish 在 CoreML 上要拆成
       x*relu6(x+3)/6，实测更容易被拆散/变慢**（这也是清单里"CoreML 友好度"
       一栏要给 MobileNetV3 打问号的原因）。精度会略降，但本实验是**骨干对比**，
       统一用 ReLU 保证"只有骨干结构这一个变量"。
    """

    def __init__(self, inp: int, oup: int, stride: int, expand: int,
                 use_se: bool = True, se_reduced: int = 8):
        super().__init__()
        self.use_residual = (stride == 1 and inp == oup)
        layers: List[nn.Module] = []
        if expand != inp:
            layers += [nn.Conv2d(inp, expand, 1, 1, 0, bias=False),
                       nn.BatchNorm2d(expand), nn.ReLU(inplace=True)]
        layers += [
            nn.Conv2d(expand, expand, 3, stride, 1, groups=expand, bias=False),
            nn.BatchNorm2d(expand), nn.ReLU(inplace=True),
        ]
        if use_se:
            layers.append(SqueezeExcite(expand, max(1, expand // se_reduced)))
        layers += [nn.Conv2d(expand, oup, 1, 1, 0, bias=False),
                   nn.BatchNorm2d(oup)]
        self.block = nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self.block(x)
        return x + out if self.use_residual else out


class MobileNetV3SmallBackbone(nn.Module):
    """MobileNetV3-Small 风格骨干 → [B, out_dim]。砍掉分类头。"""

    # (expand, out, stride, SE) —— 照 MobileNetV3-Small Table 1 裁剪
    CFG = [
        (16, 16, 2, True),
        (72, 24, 2, False),
        (88, 24, 1, False),
        (96, 40, 2, True),
        (240, 40, 1, True),
        (240, 40, 1, True),
        (120, 48, 1, True),
        (144, 48, 1, True),
        (288, 96, 2, True),
        (576, 96, 1, True),
        (576, 96, 1, True),
    ]

    def __init__(self, out_dim: int = model_v2.IMG_FEAT_DIM):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(3, 16, 3, 2, 1, bias=False),
            nn.BatchNorm2d(16), nn.ReLU(inplace=True),
        )
        blocks = []
        inp = 16
        for expand, oup, stride, use_se in self.CFG:
            blocks.append(MobileNetV3SmallBlock(inp, oup, stride, expand, use_se))
            inp = oup
        self.blocks = nn.Sequential(*blocks)
        self.tail = nn.Sequential(
            nn.Conv2d(inp, out_dim, 1, 1, 0, bias=False),
            nn.BatchNorm2d(out_dim), nn.ReLU(inplace=True),
        )
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.stem(x)
        x = self.blocks(x)
        x = self.tail(x)
        return self.global_pool(x).flatten(1)


class GhostModule(nn.Module):
    """GhostNet 的 Ghost 模块（cheap linear operation 生成幻影特征）。"""

    def __init__(self, inp: int, oup: int, kernel_size: int = 1,
                 ratio: int = 2, dw_size: int = 3, stride: int = 1):
        super().__init__()
        self.oup = oup
        init_channels = oup // ratio
        new_channels = init_channels * (ratio - 1)

        self.primary_conv = nn.Sequential(
            nn.Conv2d(inp, init_channels, kernel_size, stride,
                      kernel_size // 2, bias=False),
            nn.BatchNorm2d(init_channels),
            nn.ReLU(inplace=True),
        )
        self.cheap_operation = nn.Sequential(
            nn.Conv2d(init_channels, new_channels, dw_size, 1,
                      dw_size // 2, groups=init_channels, bias=False),
            nn.BatchNorm2d(new_channels),
            nn.ReLU(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x1 = self.primary_conv(x)
        x2 = self.cheap_operation(x1)
        return torch.cat([x1, x2], dim=1)[:, :self.oup, :, :]


class GhostNetBackbone(nn.Module):
    """GhostNet 0.5x 风格骨干 → [B, out_dim]。砍掉分类头。"""

    # (out, expand_size, kernel, stride, SE) —— 照 GhostNet 论文 Table 1 的 0.5x 档裁剪
    CFG = [
        (24, 48, 3, 1, False),
        (24, 72, 3, 1, False),
        (40, 72, 5, 2, True),
        (40, 120, 5, 1, True),
        (80, 240, 3, 2, False),
        (80, 200, 3, 1, False),
        (80, 184, 3, 1, False),
        (112, 184, 5, 1, False),
        (160, 480, 3, 2, True),
    ]

    def __init__(self, out_dim: int = model_v2.IMG_FEAT_DIM):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(3, 16, 3, 2, 1, bias=False),
            nn.BatchNorm2d(16), nn.ReLU(inplace=True),
        )
        blocks: List[nn.Module] = []
        inp = 16
        for oup, expand, kernel, stride, use_se in self.CFG:
            if expand != inp:
                blocks.append(GhostModule(inp, expand, 1, 2, 1, 1))
                blocks.append(GhostModule(expand, oup, kernel, 2, 3, stride))
                if use_se:
                    blocks.append(SqueezeExcite(oup, max(1, oup // 8)))
            else:
                blocks.append(GhostModule(inp, oup, kernel, 2, 3, stride))
                if use_se:
                    blocks.append(SqueezeExcite(oup, max(1, oup // 8)))
            inp = oup
        self.blocks = nn.Sequential(*blocks)
        self.tail = nn.Sequential(
            nn.Conv2d(inp, out_dim, 1, 1, 0, bias=False),
            nn.BatchNorm2d(out_dim), nn.ReLU(inplace=True),
        )
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.stem(x)
        x = self.blocks(x)
        x = self.tail(x)
        return self.global_pool(x).flatten(1)


class RepVGGBackboneAdapter(nn.Module):
    """M2 原生骨干的**只读适配器**（对照基准，不改 model_v2.py）。

    ⚠️ 直接复用 `model_v2.ImageEncoder`，只是把接口统一成 `forward(x)->[B,C]`，
       保证「基准」与「候选」在**完全相同的融合头/输入**下对比。
    """

    def __init__(self, deploy: bool = False):
        super().__init__()
        self.inner = model_v2.ImageEncoder(deploy=deploy)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.inner(x)

    def reparameterize(self) -> None:
        self.inner.reparameterize()


# ═══════════════════════════════════════════════════════════════════════════
# 2. 完整模型（骨干可换，其余分支照抄 M2 契约）
# ═══════════════════════════════════════════════════════════════════════════

class M3ExperimentModel(nn.Module):
    """与 M2 同构、但图像骨干可替换的完整模型。

    ⚠️ 设计原则：**只换骨干这一个变量**。
       · lane_encoder / det_encoder / state_encoder / fusion_head
         **全部复用 model_v2 的实现**（import 过来，不改它的代码）
       · 输入输出契约与 M2 完全一致
       · 这样测出来的差异**只能归因于骨干**
    """

    def __init__(self, backbone: nn.Module, backbone_name: str):
        super().__init__()
        self.backbone_name = backbone_name
        self.image_encoder = backbone

        # —— 以下四个分支 + 融合头：直接复用 M2 的实现（只读 import）——
        self.lane_encoder = model_v2.LaneMaskEncoder()
        self.det_encoder = model_v2.DetectionEncoder()
        self.state_encoder = model_v2.StateEncoder()
        self.fusion_head = model_v2.FusionHead()

    def forward(self, image, lane_mask=None, dets=None, det_mask=None,
                vehicle_state=None):
        """**签名与 `model_v2.M2Model.forward` 逐字对齐**（含 None 语义）。

        ⚠️ 为什么必须对齐：M2 的三个分支都接受 `None`（车道线全丢 / 0 个框 /
           状态读取失败），并在内部返回零向量。这是**运行时真实会发生的输入**
           （比如刚开局没有检测框）。实验模型若不支持 None，就测不出真实行为。

        参数名 `vehicle_state` 不是 `state` —— 这是 M2 踩过的 coremltools 坑
        （`state` 会被静默重命名成 `state_workaround`，见 model_v2.py:843-851）。
        """
        if image is None:
            raise ValueError("image 为必填输入（纯视觉主模态）")
        batch_size = image.shape[0]

        img_feat = self.image_encoder(image)
        # 分支的真实签名是 (x, batch_size, ref) —— ref 用来取 device/dtype
        lane_feat = self.lane_encoder(lane_mask, batch_size, image)
        det_feat = self.det_encoder(dets, det_mask, batch_size, image)
        state_feat = self.state_encoder(vehicle_state, batch_size, image)

        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)
        return self.fusion_head(fused)

    def reparameterize(self) -> None:
        if hasattr(self.image_encoder, "reparameterize"):
            self.image_encoder.reparameterize()


# ═══════════════════════════════════════════════════════════════════════════
# 3. 测量工具
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class CandidateResult:
    """单个候选的测量结果。每个字段标注了是实测还是估算。"""

    name: str
    backbone_params: int = 0          # 实测
    backbone_int8_mb: float = 0.0     # 实测（= params/1024/1024）
    total_params: int = 0             # 实测
    total_int8_mb: float = 0.0        # 实测
    total_fp16_mb: float = 0.0        # 实测
    fits_int8_budget: bool = False    # 实测（对 10MB 判定）
    flops_m: float = 0.0              # 估算（thop 实测 MACs×2）
    flops_vs_repvgg: float = 0.0      # 估算（相对基准倍数）
    cpu_ms_per_forward: float = 0.0   # 实测（本机 CPU，**不是 M3**）
    mps_ms_per_forward: float = 0.0   # 实测（本机 GPU，**不是 M3 的 ANE**）
    note: str = ""
    error: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def count_params(model: nn.Module) -> int:
    """参数量（实测）。"""
    return sum(p.numel() for p in model.parameters())


def count_params_trainable(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


def try_flops(model: nn.Module, inputs: Tuple[torch.Tensor, ...]) -> Optional[float]:
    """FLOPs 估算（优先 thop，退化为 None —— 不编数字）。"""
    try:
        from thop import profile  # type: ignore
        macs, _ = profile(model, inputs=inputs, verbose=False)
        return float(macs) * 2 / 1e6      # MACs → FLOPs（×2），单位 M
    except Exception:
        return None


def measure_cpu_latency(model: nn.Module, inputs: Tuple[torch.Tensor, ...],
                        warmup: int = 3, iters: int = 10) -> float:
    """本机 CPU 前向耗时（ms/次）。

    ⚠️ **这不是 M3 真机耗时**！本机是 Apple Silicon Mac。
       它的用途只有一个：**相对比较**（谁比谁快），绝对值无意义。
       报告里必须标注为"本机 CPU 参考值"。
    """
    model.eval()
    with torch.no_grad():
        for _ in range(warmup):
            model(*inputs)
        t0 = time.perf_counter()
        for _ in range(iters):
            model(*inputs)
        dt = (time.perf_counter() - t0) / iters
    return dt * 1000.0


def build_dummy_inputs(batch: int = 1) -> Tuple[torch.Tensor, ...]:
    """构造符合 M2 契约的假输入（用于形状/耗时验证）。

    返回顺序与 `M2Model.forward` 的参数顺序一致：
        (image, lane_mask, dets, det_mask, vehicle_state)
    """
    image = torch.randn(batch, *IMG_SHAPE)
    lane = (torch.rand(batch, *LANE_SHAPE) > 0.9).float()   # 稀疏二值，像真车道线
    dets = torch.rand(batch, DET_N, DET_FEAT_DIM)
    det_mask = (torch.rand(batch, DET_N) > 0.3).float()
    state = torch.randn(batch, STATE_DIM)
    return image, lane, dets, det_mask, state


def build_empty_inputs(batch: int = 1) -> Tuple[torch.Tensor, ...]:
    """**空输入边界用例**：车道线 None + 检测框 None + 状态 None。

    这是运行时真实会发生的情况（刚开局 / 车道线识别全丢 / 状态未接入），
    M2 的设计是返回零向量而不是崩。实验模型必须同样能过 —— 否则等于
    把一个真实运行时会踩的坑漏测了。
    """
    image = torch.randn(batch, *IMG_SHAPE)
    return image, None, None, None, None


# ═══════════════════════════════════════════════════════════════════════════
# 4. 主实验
# ═══════════════════════════════════════════════════════════════════════════

def candidate_backbones() -> List[Tuple[str, callable]]:
    """候选清单。callable 返回**已 reparameterize 的部署态**骨干。

    ⚠️ 两套实现，报告里必须区分（这是本实验最重要的方法学决定）：

      A. **官方预训练实现**（torchvision / timm）—— 参数量是**权威实测值**，
         而且**带 ImageNet 预训练权重**（本项目"自己训练"，预训练能大幅加速收敛）。
         这是"这个骨干到底多大"的**唯一可信来源**。

      B. **本项目手工裁剪版**（上面那三个 class）—— 砍掉分类头、适配 180×320、
         统一用 ReLU。用于验证「换成这个结构后，端到端模型能不能跑通、
         参数量/耗时是多少」。

    ⚠️ **为什么两套都要**：文档 `docs/骨干网络候选清单-2026-10-08.md` 里的
       参数量是**外部资料抄来的**，本脚本实测发现**至少 3 个对不上**
       （见 `verify_doc_claims()`）。报告必须以**实测**为准，不能抄文档。
    """
    return [
        ("RepVGG-A0 轻量变体 (M2 现状·部署态)",
         lambda: RepVGGBackboneAdapter(deploy=True)),
        ("ShuffleNetV2 0.5x (本项目裁剪版)",
         lambda: ShuffleNetV2Backbone()),
        ("MobileNetV3-Small (本项目裁剪版)",
         lambda: MobileNetV3SmallBackbone()),
        ("GhostNet 0.5x (本项目裁剪版)",
         lambda: GhostNetBackbone()),
    ]


def official_backbone_param_counts() -> List[Tuple[str, int, str, Optional[int]]]:
    """**官方实现**的参数量核对（权威实测）。

    返回 [(名称, 总参数量, 来源, 去掉分类头后的参数量)]

    ⚠️ 为什么要去掉分类头：本项目只用**特征提取部分**，分类头（1000 类 FC）
       在部署时会被砍掉。拿"含分类头"的数字和 M2 的骨干比是**不公平比较**。
       例如 ShuffleNetV2 0.5x 的 fc 占 1,025,000 / 1,366,792 = **75%**！
    """
    out: List[Tuple[str, int, str, Optional[int]]] = []

    # torchvision
    try:
        import torchvision.models as tvm
        for label, fn in [
            ("ShuffleNetV2 0.5x", tvm.shufflenet_v2_x0_5),
            ("MobileNetV3-Small", tvm.mobilenet_v3_small),
            ("MobileNetV3-Large", tvm.mobilenet_v3_large),
            ("MobileNetV2", tvm.mobilenet_v2),
        ]:
            m = fn(weights=None)
            tot = sum(p.numel() for p in m.parameters())
            head = 0
            for attr in ("fc", "classifier"):
                sub = getattr(m, attr, None)
                if sub is not None:
                    head = sum(p.numel() for p in sub.parameters())
                    break
            out.append((label, tot, "torchvision", tot - head if head else None))
    except Exception as exc:
        print(f"[警告] torchvision 不可用：{exc}")

    # timm
    try:
        import timm
        for label, name in [
            ("GhostNet 0.5x", "ghostnet_050"),
            ("GhostNet 1.0x", "ghostnet_100"),
            ("EfficientNet-Lite0", "efficientnet_lite0"),
            ("MobileNetV3-Small 0.5x", "mobilenetv3_small_050"),
        ]:
            try:
                m = timm.create_model(name, pretrained=False, num_classes=0)
                tot = sum(p.numel() for p in m.parameters())
                out.append((label, tot, f"timm:{name}", tot))  # num_classes=0 已无分类头
            except Exception as exc:
                print(f"[警告] timm {name} 不可用：{str(exc)[:60]}")
    except ImportError:
        print("[警告] timm 未安装 → GhostNet/EfficientNet-Lite 无法核对")

    return out


def verify_doc_claims() -> None:
    """**核对文档 `骨干网络候选清单-2026-10-08.md` 里声称的参数量**。

    这是本脚本的"打假"环节：文档里的数字来自外部资料，必须逐条实测。
    对不上的要如实报告 —— 因为选型决策建立在"大小 ≤10MB"上，
    如果参数量本身是错的，选型结论就是错的。
    """
    # 文档里的声称值（照抄 docs/骨干网络候选清单-2026-10-08.md 表格）
    CLAIMED = {
        "ShuffleNetV2 0.5x": 2.28,
        "MobileNetV3-Small": 2.50,
        "GhostNet 0.5x": 2.60,
        "EfficientNet-Lite0": 4.70,
        "RepVGG-A0 原版": 8.00,
    }
    print("=" * 100)
    print("【打假】文档声称的参数量 vs 官方实现实测")
    print("=" * 100)
    print(f"{'骨干':<26} {'文档声称':>10} {'官方实测':>12} {'去分类头':>12} {'判定':>10}")
    print("-" * 100)

    official = official_backbone_param_counts()
    by_label = {}
    for label, tot, src, nohead in official:
        by_label[label] = (tot, nohead, src)

    for label, claimed_m in CLAIMED.items():
        if label not in by_label:
            print(f"{label:<26} {claimed_m:>9.2f}M {'未核对':>12} {'—':>12} {'⚠️ 无法核对':>10}")
            continue
        tot, nohead, src = by_label[label]
        tot_m = tot / 1e6
        nohead_m = (nohead / 1e6) if nohead else float("nan")
        # 判定：以"去分类头"口径比较（本项目只用特征提取部分）
        cmp_m = nohead_m if nohead else tot_m
        ok = abs(cmp_m - claimed_m) < 0.35
        verdict = "✅ 一致" if ok else f"❌ 差 {cmp_m - claimed_m:+.2f}M"
        print(f"{label:<26} {claimed_m:>9.2f}M {tot_m:>11.2f}M {nohead_m:>11.2f}M {verdict:>10}")

    print("-" * 100)
    print("说明：'官方实测' = 完整网络（含 1000 类分类头）；'去分类头' = 本项目实际用量。")
    print("      ⚠️ 拿含分类头的数字做选型是**高估**（ShuffleNetV2 0.5x 的 fc 占 75%）。")
    print()


def measure_mps_latency(model: nn.Module, inputs: Tuple[torch.Tensor, ...],
                        warmup: int = 3, iters: int = 20) -> Tuple[Optional[float], str]:
    """MPS（Apple GPU）前向耗时 ms。返回 (耗时或None, 失败原因)。

    ⚠️ 仍然**不是 M3 真机**！MPS 是本机 Apple Silicon 的 GPU 后端，
       与 M3 的 ANE/CoreML 路径**完全不同**。它的价值：
       · 比 CPU 更接近"GPU/加速器"的相对排序
       · 能暴露某些结构在 GPU 上的低效（如 depthwise）
       真机数据必须靠 CoreML 导出后在 M3 上跑。

    ⚠️ **不吞错**：失败时返回原因字符串，由调用方打印。
       第一版我写成 `except: return None`，结果 MPS 明明可用却报"未就绪"，
       排查了半天 —— 静默吞错会把"配置问题"伪装成"环境不支持"。
    """
    if not torch.backends.mps.is_available():
        return None, "MPS 不可用（torch.backends.mps.is_available() == False）"
    original_device = next(model.parameters()).device
    try:
        m = model.to("mps").eval()
        ins = tuple(t.to("mps") if t is not None else None for t in inputs)
        with torch.no_grad():
            for _ in range(warmup):
                m(*ins)
            torch.mps.synchronize()
            t0 = time.perf_counter()
            for _ in range(iters):
                m(*ins)
            torch.mps.synchronize()
            dt = (time.perf_counter() - t0) / iters
        model.to(original_device)
        return dt * 1000.0, ""
    except Exception as exc:
        # 复原设备，避免污染后续 CPU 测量
        try:
            model.to(original_device)
        except Exception:
            pass
        return None, f"{type(exc).__name__}: {exc}"


def run_experiments(quick: bool = False, flops_only: bool = False) -> List[CandidateResult]:
    results: List[CandidateResult] = []
    inputs = build_dummy_inputs(batch=1)

    print("=" * 78)
    print("T6 骨干替换实验 —— 参数量/体积为实测，耗时为【本机 CPU 参考值，非 M3】")
    print("=" * 78)
    print(f"输入契约：image{IMG_SHAPE}  lane{LANE_SHAPE}  "
          f"det{DET_SHAPE}  state({STATE_DIM},)")
    print()

    for name, factory in candidate_backbones():
        print(f"── {name} " + "─" * max(0, 60 - len(name)))
        r = CandidateResult(name=name)
        try:
            backbone = factory()
            backbone.eval()
            model = M3ExperimentModel(backbone, name)
            model.eval()

            r.backbone_params = count_params(backbone)
            r.total_params = count_params(model)
            r.backbone_int8_mb = r.backbone_params / 1024 / 1024
            r.total_int8_mb = r.total_params / 1024 / 1024
            r.total_fp16_mb = r.total_params * 2 / 1024 / 1024
            r.fits_int8_budget = r.total_int8_mb <= INT8_BUDGET_MB

            print(f"   骨干参数     : {r.backbone_params:>10,}  → INT8 {r.backbone_int8_mb:6.2f} MB")
            print(f"   模型总参数   : {r.total_params:>10,}  → INT8 {r.total_int8_mb:6.2f} MB "
                  f"/ FP16 {r.total_fp16_mb:6.2f} MB")
            print(f"   INT8 ≤10MB   : {'✅ 合规' if r.fits_int8_budget else '❌ 超预算'}")

            # 形状校验：真跑一次，确认输出契约一致
            with torch.no_grad():
                out = model(*inputs)
            if isinstance(out, (tuple, list)):
                shapes = [tuple(o.shape) for o in out]
                print(f"   输出形状     : {shapes}")
            else:
                print(f"   输出形状     : {tuple(out.shape)}")

            # ★ 空输入边界：车道线/检测框/状态全 None（运行时真实会发生）
            try:
                with torch.no_grad():
                    out_empty = model(*build_empty_inputs(batch=1))
                n_out = len(out_empty) if isinstance(out_empty, (tuple, list)) else 1
                print(f"   空输入(None) : ✅ 通过（{n_out} 个输出，M2 语义=零向量）")
            except Exception as exc_empty:
                r.error = f"空输入用例失败: {type(exc_empty).__name__}: {exc_empty}"
                print(f"   空输入(None) : ❌ {r.error}")

            if not flops_only:
                fl = try_flops(model, inputs)
                if fl is not None:
                    r.flops_m = fl
                    print(f"   FLOPs(估算)  : {fl:8.1f} M")
                else:
                    print(f"   FLOPs(估算)  : 未测（thop 未安装）")

                if not quick:
                    ms = measure_cpu_latency(model, inputs)
                    r.cpu_ms_per_forward = ms
                    print(f"   本机CPU前向  : {ms:8.2f} ms  ← ⚠️ 非 M3，仅供相对比较")

                    mps_ms, mps_err = measure_mps_latency(model, inputs)
                    if mps_ms is not None:
                        r.mps_ms_per_forward = mps_ms
                        print(f"   本机MPS前向  : {mps_ms:8.2f} ms  ← ⚠️ 非 M3 ANE，仅供相对比较")
                    else:
                        print(f"   本机MPS前向  : 失败 — {mps_err}")

        except Exception as exc:  # 不吞错：如实记录，不编数字
            r.error = f"{type(exc).__name__}: {exc}"
            print(f"   ❌ 失败：{r.error}")

        results.append(r)
        print()

    # 相对基准的倍数
    base = next((x for x in results if "RepVGG" in x.name and not x.error), None)
    if base:
        for r in results:
            if r.error:
                continue
            if r.flops_m and base.flops_m:
                r.flops_vs_repvgg = r.flops_m / base.flops_m
            if r.cpu_ms_per_forward and base.cpu_ms_per_forward:
                r.note = (f"本机CPU耗时 {r.cpu_ms_per_forward:.2f}ms "
                          f"= 基准的 {r.cpu_ms_per_forward / base.cpu_ms_per_forward:.2f}x")

    return results


def print_summary_table(results: List[CandidateResult]) -> None:
    print("=" * 112)
    print("对比总表")
    print("=" * 112)
    hdr = (f"{'骨干':<36} {'骨干参数':>10} {'总参数':>10} {'INT8(MB)':>9} "
           f"{'合规':>5} {'FLOPs(M)':>9} {'CPU(ms)':>8} {'MPS(ms)':>8}")
    print(hdr)
    print("-" * 112)
    for r in results:
        if r.error:
            print(f"{r.name:<36} {'—':>10} {'—':>10} {'—':>9} {'—':>5} {'—':>9} {'—':>8} {'失败':>8}")
            continue
        mps = f"{r.mps_ms_per_forward:>8.2f}" if r.mps_ms_per_forward else f"{'—':>8}"
        print(f"{r.name:<36} {r.backbone_params:>10,} {r.total_params:>10,} "
              f"{r.total_int8_mb:>9.2f} {'✅' if r.fits_int8_budget else '❌':>5} "
              f"{r.flops_m:>9.1f} {r.cpu_ms_per_forward:>8.2f} {mps}")
    print("-" * 112)
    print("⚠️ FLOPs 由 thop 实测 MACs×2；CPU/MPS 列是**本机 Apple Silicon 参考值，")
    print("   ⚠️ 不是 M3 真机（尤其不是 M3 的 ANE 路径）**，只能用于横向排序。")
    print()


def export_json(results: List[CandidateResult], out: Path) -> None:
    payload = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "warning": "cpu_ms_per_forward 是本机 CPU 参考值，不是 M3 真机耗时",
        "int8_budget_mb": INT8_BUDGET_MB,
        "input_contract": {
            "image": list(IMG_SHAPE),
            "lane_mask": list(LANE_SHAPE),
            "detections": list(DET_SHAPE),
            "state_dim": STATE_DIM,
        },
        "results": [r.to_dict() for r in results],
    }
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[导出] 原始数据 → {out}")


# ═══════════════════════════════════════════════════════════════════════════
# 5. ★ 真机 CoreML 基准（本机 = Apple M3）
# ═══════════════════════════════════════════════════════════════════════════
#
# 【为什么这段最重要】
#   任务要求「M3 真机耗时」。一开始我以为只能拿 CPU/MPS 当代理，
#   直到 `sysctl -n machdep.cpu.brand_string` 打出 **"Apple M3"** ——
#   本机就是 M3（MacBook Air，8 核 4P+4E）。
#   所以这里可以**真的测 CoreML**，而不是估算。
#
# 【诚实边界（必须写进报告）】
#   ① 本机是 MacBook Air（**无风扇**）→ 持续负载会降频。
#      真机若有风扇/更大机身，长期表现可能**更好**（也可能因游戏占用更差）。
#   ② 这里只测**图像骨干**；端到端还含车道线/检测框/状态分支，
#      但那三个分支与骨干选择无关（M2 已实现且固定），不影响选型结论。
#   ③ `computeUnits = .all` 与 `InferenceEngine.swift:167` 的档位**一致**
#      （项目 ABBA 实测过 `.all` 最快，见"13 项已否决"清单，不要改档位）。

@dataclass
class CoreMLBenchResult:
    """真机 CoreML 基准结果（全部实测，非估算）。"""

    name: str
    params: int = 0
    int8_mb: float = 0.0
    coreml_fp16_mb: float = 0.0     # 实测：导出的 mlpackage 磁盘体积
    p50_ms: float = 0.0
    p95_ms: float = 0.0
    min_ms: float = 0.0
    max_ms: float = 0.0
    hz_p95: float = 0.0             # 1000/p95（保守：卡顿由尾延迟决定）
    fits_30hz: bool = False
    error: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def _dir_size_mb(p: Path) -> float:
    if not p.exists():
        return 0.0
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1024 / 1024


def export_backbone_coreml(module: nn.Module, name: str, out_dir: Path) -> Path:
    """把骨干导出成 CoreML .mlpackage（固定输入 [1,3,180,320]，FP16）。"""
    import coremltools as ct

    safe = "".join(c if c.isalnum() else "_" for c in name)[:40]
    pkg = out_dir / f"{safe}.mlpackage"

    module = module.eval()
    example = torch.randn(1, *IMG_SHAPE)
    with torch.no_grad():
        traced = torch.jit.trace(module, example, strict=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, *IMG_SHAPE), dtype=np.float32)],
        outputs=[ct.TensorType(name="features", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.save(str(pkg))
    return pkg


def bench_one_coreml(pkg: Path, iters: int = 30, warmup: int = 5) -> Tuple[float, float, float, float]:
    """真机跑 CoreML，返回 (p50, p95, min, max) ms。"""
    import coremltools as ct

    model = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.ALL)
    x = np.random.rand(1, *IMG_SHAPE).astype(np.float32)
    input_name = model.get_spec().description.input[0].name
    feed = {input_name: x}

    for _ in range(warmup):
        model.predict(feed)

    times = []
    for _ in range(iters):
        t0 = time.perf_counter()
        model.predict(feed)
        times.append((time.perf_counter() - t0) * 1000.0)
    times.sort()
    idx95 = min(len(times) - 1, int(len(times) * 0.95))
    return statistics.median(times), times[idx95], times[0], times[-1]


def bench_coreml_backbones(iters: int = 30) -> dict:
    """★ 真机 M3 上的骨干 CoreML 基准（T6 任务3 的正式答案）。"""
    import platform
    import subprocess

    out_dir = _HERE.parent / "models" / "backbone_bench"
    out_dir.mkdir(parents=True, exist_ok=True)

    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                          capture_output=True, text=True).stdout.strip()

    print("=" * 100)
    print("T6 任务3：骨干在【真机 M3】上的 CoreML 耗时（computeUnits = .all）")
    print("=" * 100)
    print(f"测试机芯片 : {chip}")
    print(f"macOS      : {platform.mac_ver()[0]}")
    print(f"⚠️ 本机是 MacBook Air（无风扇）→ 持续负载会降频；真机长期表现可能更好")
    print(f"输入       : [1,3,{IMG_SHAPE[1]},{IMG_SHAPE[2]}]，FP16 部署")
    print(f"迭代       : warmup 5 + {iters} 次计时")
    print()

    cands = [
        ("RepVGG-A0 轻量变体 (M2 现状)", RepVGGBackboneAdapter(deploy=True)),
        ("ShuffleNetV2 0.5x (裁剪版)", ShuffleNetV2Backbone()),
        ("MobileNetV3-Small (裁剪版)", MobileNetV3SmallBackbone()),
        ("GhostNet 0.5x (裁剪版)", GhostNetBackbone()),
    ]

    results: List[CoreMLBenchResult] = []
    for name, backbone in cands:
        print(f"── {name} " + "─" * max(0, 50 - len(name)))
        r = CoreMLBenchResult(name=name)
        try:
            backbone.eval()
            r.params = sum(p.numel() for p in backbone.parameters())
            r.int8_mb = r.params / 1024 / 1024

            pkg = export_backbone_coreml(backbone, name, out_dir)
            r.coreml_fp16_mb = _dir_size_mb(pkg)

            p50, p95, mn, mx = bench_one_coreml(pkg, iters=iters)
            r.p50_ms, r.p95_ms, r.min_ms, r.max_ms = p50, p95, mn, mx
            r.hz_p95 = 1000.0 / p95 if p95 > 0 else 0.0
            r.fits_30hz = r.p95_ms <= 33.0

            print(f"   参数量        : {r.params:>10,}  → INT8 {r.int8_mb:6.2f} MB")
            print(f"   mlpackage     : {r.coreml_fp16_mb:6.2f} MB（FP16 实测体积）")
            print(f"   真机 p50/p95  : {p50:6.2f} / {p95:6.2f} ms  (min {mn:.2f} / max {mx:.2f})")
            print(f"   保守频率      : {r.hz_p95:6.1f} Hz  "
                  f"{'✅ 满足 30Hz' if r.fits_30hz else '❌ 不足 30Hz'}")
        except Exception as exc:
            r.error = f"{type(exc).__name__}: {str(exc)[:200]}"
            print(f"   ❌ 失败：{r.error}")
        results.append(r)
        print()

    print("=" * 100)
    print("真机 M3 对比总表")
    print("=" * 100)
    print(f"{'骨干':<34} {'参数量':>10} {'INT8(MB)':>9} {'CoreML(MB)':>11} "
          f"{'p50(ms)':>8} {'p95(ms)':>8} {'Hz':>7} {'30Hz':>6}")
    print("-" * 100)
    for r in results:
        if r.error:
            print(f"{r.name:<34} {'—':>10} {'—':>9} {'—':>11} {'—':>8} {'—':>8} {'—':>7} {'失败':>6}")
            continue
        print(f"{r.name:<34} {r.params:>10,} {r.int8_mb:>9.2f} {r.coreml_fp16_mb:>11.2f} "
              f"{r.p50_ms:>8.2f} {r.p95_ms:>8.2f} {r.hz_p95:>7.1f} "
              f"{'✅' if r.fits_30hz else '❌':>6}")
    print("-" * 100)
    print("⚠️ 只测**图像骨干**（端到端另含车道线/检测框/状态分支，与骨干选择无关）")
    print("⚠️ 30Hz 判定用 p95（不是 p50）—— 保守，卡顿由尾延迟决定")
    print()

    return {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "chip": chip,
        "machine_note": "MacBook Air (fanless) — sustained load may throttle",
        "compute_units": "ALL (CoreML .all, same as InferenceEngine.swift:167)",
        "input_shape": [1, *IMG_SHAPE],
        "precision": "FLOAT16",
        "results": [r.to_dict() for r in results],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="T6 骨干替换实验")
    ap.add_argument("--quick", action="store_true", help="跳过本机耗时测量")
    ap.add_argument("--flops", action="store_true", help="只测参数量与 FLOPs")
    ap.add_argument("--coreml", action="store_true",
                    help="★ 真机 CoreML 基准（本机是 Apple M3，这是真正的 M3 数据）")
    ap.add_argument("--iters", type=int, default=30, help="CoreML 计时迭代次数")
    ap.add_argument("--json", type=str, default="", help="结果导出路径")
    args = ap.parse_args()

    # ① 先打假：核对文档声称的参数量（选型结论建立在它上面）
    verify_doc_claims()

    if args.coreml:
        # ★ 真机 CoreML 基准：本机 = Apple M3，这是任务要的"M3 真机耗时"
        bench = bench_coreml_backbones(iters=args.iters)
        if args.json:
            Path(args.json).write_text(
                json.dumps(bench, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"[导出] {args.json}")
        return 0

    # ② 再做骨干替换实验
    results = run_experiments(quick=args.quick, flops_only=args.flops)
    print_summary_table(results)

    if args.json:
        export_json(results, Path(args.json))

    failed = [r for r in results if r.error]
    if failed:
        print(f"⚠️ {len(failed)} 个候选失败（已如实记录，未编造数字）：")
        for r in failed:
            print(f"   · {r.name}: {r.error}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
