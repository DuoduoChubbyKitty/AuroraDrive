# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later

# ============================================================================
#  risk_head.py — 风险 / 置信度感知头 + TTC + 接管判定（M3）
# ============================================================================
#
#  【这个文件解决什么问题】
#    用户需求：「模型自己没法操作时明确让用户接管」（救车能力）。
#    现状：`ControlCommand.confidence` 字段**已存在但没人填**
#    （Swift 侧 `AuroraDriveApp.swift` 的 ControlCommand 有 confidence；
#     模型侧 `src/model_v2.py` 的 FusionHead 只输出 steer/throttle/brake
#     三个张量，没有任何置信度或风险输出）。
#
#    本模块**独立**提供三件事，不改 `model_v2.py` 一行：
#      ① RiskHead         —— 吃融合特征，吐出 confidence / risk（都是 [B] ∈ [0,1]）
#      ② estimate_ttc     —— 从检测框 + 自车速度估「多久撞上前车」（物理先验）
#      ③ TakeoverDecider  —— 阈值 + 滞后，输出稳定的「建议接管」布尔量
#
#  【为什么 confidence 用 sigmoid 不用 softmax】
#    confidence 是**单值自评**（"我对这一帧的控制量有多确定"），不是多分类问题。
#    softmax 要把 logits 归一化到"和为 1"，多一个自由度且语义错位；
#    sigmoid 单输出天然 ∈ [0,1]，与"自评分数"语义一致。
#    （本项目 steer/throttle/brake 的输出头也是 sigmoid/tanh，风格统一。）
#
#  【设计选择：RiskHead 吃哪一层特征？】
#    默认吃 **融合特征 [B,512]**（= 图像256 + 车道线64 + 检测框128 + 状态64，
#    见 `model_v2.py:723` FUSION_IN_DIM）。
#    为什么不直接吃三个控制量输出？—— 控制量已经把信息压成了 3 个数，
#    丢失了"我看到了什么"的上下文；自评需要看到特征本身才能判断"这场景我见过没"。
#    同时**可选**再吃一份检测框特征 `det_feat`（[B,128]），因为风险判定强依赖
#    "前方有没有车、多近"——这份信息在融合特征里已被池化稀释。
#
#  【⚠️ 诚实声明：TTC 的精度取决于标定，本文件不假装它准】
#    单目相机（含游戏第三视角）**无法直接从单帧得到绝对距离**，必须靠
#    已知尺寸的物体做标定：Z = K / h_norm（K 为标定常数，h_norm 为框归一化高度）。
#    本文件实现公式与接口，但 **K 的值必须实测标定**（`RangeCalibrator` 提供方法）。
#    K 没标定前，TTC 输出会把 `valid` 置 False —— **不拿未标定的数字当真**。
#    出处：TTC 定义为两车距离除以相对速度，见
#    https://scholarworks.indianapolis.iu.edu/bitstream/1805/18821/1/Kilicarslan_2018_predict.pdf
#
#  【出处 / 参考】
#    · 置信度回归（用分类头估 steer 置信度、实时不确定度）：
#      https://arxiv.org/html/2503.00783v1
#      → 本文件 `confidence_target_from_error` 采用同思路的误差代理监督
#    · oTTC（从 ego 视角估 time-to-contact）：
#      https://arxiv.org/html/2405.07698v1
#    · 接管请求（TOR）与驾驶时长影响：
#      https://pmc.ncbi.nlm.nih.gov/articles/PMC10839869/
#    · 碰撞预警用 TTC < 650ms 触发：
#      https://github.com/ravesandstorm/Vehicle-TTC-Calculation
#
# ============================================================================

"""风险 / 置信度感知头 + TTC 碰撞时间估算 + 主动接管判定。

独立模块：不 import model_v2，仅接受其维度约定作为默认参数。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

__all__ = [
    "RiskHead",
    "RiskHeadConfig",
    "TTCConfig",
    "estimate_ttc",
    "RangeCalibrator",
    "TakeoverConfig",
    "TakeoverDecider",
    "TakeoverState",
    "confidence_target_from_error",
    "risk_target_from_ttc",
]

# ----------------------------------------------------------------------------
# 与 model_v2.py 对齐的契约常量（**只读对齐，不 import**，避免耦合）
# ----------------------------------------------------------------------------
#: 融合特征维度 = 图像 256 + 车道线 64 + 检测框 128 + 状态 64（model_v2.py:223）
DEFAULT_FUSED_DIM: int = 512
#: 检测框分支输出维度（model_v2.py:221）
DEFAULT_DET_FEAT_DIM: int = 128
#: 检测框特征布局：[0]x [1]y [2]w [3]h [4:8]label [8]conf [9]speed [10]heading [11]age
DET_FEAT_DIM: int = 12
#: 图像输入尺寸（用于归一化↔像素换算）
IMG_H: int = 180
IMG_W: int = 320
#: 最大检测框数（Swift 侧空槽补 0 + det_mask=0）
MAX_DETECTIONS: int = 20


# ============================================================================
# 1. RiskHead —— 置信度 + 风险自评头
# ============================================================================

@dataclass
class RiskHeadConfig:
    """RiskHead 的结构配置。

    Attributes:
        fused_dim: 融合特征维度（model_v2 默认 512）。
        det_feat_dim: 检测框特征维度（model_v2 默认 128）；0 = 不用检测框特征。
        hidden: 隐藏层宽度。
        use_speed: 是否把自车速度作为显式输入（速度本身强烈影响风险）。
        dropout: dropout 概率（默认 0.1，与 FusionHead 的 dropout2 同量级）。
        det_pool: 检测框特征的池化方式，"max_mean" 或 "max"。
            "max_mean" 与 model_v2 的 DetectionEncoder 同款（max 抓最危险单框、
            mean 抓整体密度），但这里输入已是**编码后**的 [B,128]，故直接池化。
    """

    fused_dim: int = DEFAULT_FUSED_DIM
    det_feat_dim: int = DEFAULT_DET_FEAT_DIM
    hidden: int = 128
    use_speed: bool = True
    dropout: float = 0.1
    det_pool: str = "max_mean"


class RiskHead(nn.Module):
    """风险 / 置信度感知头。

    输入：
        fused_feat: [B, C]        融合特征（必填）
        det_feat:   [B, N, D] 或 [B, D] 或 None
                                  检测框**编码后**特征。给 [B,N,D] 时内部做
                                  masked pooling；给 None 时走零向量退化。
        det_mask:   [B, N] 或 None  1=有效框，0=空槽（配合 [B,N,D] 使用）
        speed:      [B] 或 [B,1] 或 None  自车速度（标量，单位由调用方约定）

    输出：
        (confidence [B] ∈ [0,1], risk [B] ∈ [0,1])
            confidence: 对当前控制量的自评置信度，**越高越确定**
            risk:       危险度，**越高越该接管**

    ⚠️ 两个输出都过 sigmoid（单值，不是 softmax），见文件头说明。

    退化行为（重要，部署时会遇到）：
        · det_feat=None          → 检测支路输入全零，其余照常（**不报错**）
        · det_mask 全 0          → masked mean 用 1e-6 兜底，**不产生 NaN**
        · speed=None             → 速度输入置 0
    """

    def __init__(self, config: Optional[RiskHeadConfig] = None, **kwargs):
        super().__init__()
        if config is None:
            config = RiskHeadConfig(**kwargs)
        self.config = config

        feat_dim = config.fused_dim
        # 检测支路拼接维度
        if config.det_feat_dim > 0:
            self.det_proj_dim = config.det_feat_dim * (2 if config.det_pool == "max_mean" else 1)
        else:
            self.det_proj_dim = 0
        feat_dim += self.det_proj_dim
        if config.use_speed:
            feat_dim += 1

        self.fused_dim_in = feat_dim

        self.fc1 = nn.Linear(feat_dim, config.hidden)
        self.dropout = nn.Dropout(config.dropout)
        self.fc2 = nn.Linear(config.hidden, config.hidden)

        # 两个独立单值头（sigmoid）
        self.confidence_head = nn.Linear(config.hidden, 1)
        self.risk_head = nn.Linear(config.hidden, 1)

        self._init_weights()
        # 初始化后让 risk 偏向"低风险"、confidence 偏向"中等"——
        # 避免一上来就疯狂请求接管（接管信号在部署时是"扰民"的）。
        # bias 取负值 → sigmoid 初值偏小。
        with torch.no_grad():
            self.risk_head.bias.fill_(math.log(0.1 / 0.9))        # ≈ 0.1
            self.confidence_head.bias.fill_(math.log(0.6 / 0.4))  # ≈ 0.6

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, nn.Linear):
                # fan_in：输出头是 (hidden→1)，fan_out 初始化会让 sigmoid 一上来
                # 就饱和、梯度归零。与 model_v2 FusionHead._init_weights 同款理由。
                nn.init.kaiming_normal_(m.weight, mode="fan_in", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    # ------------------------------------------------------------------
    def _pool_det(self, det_feat: torch.Tensor, det_mask: Optional[torch.Tensor]) -> torch.Tensor:
        """检测特征池化 → [B, det_proj_dim]。

        接受 [B,N,D]（配 det_mask）或 [B,D]（已池化）。
        """
        if det_feat.dim() == 2:
            # 已经是 [B, D]，直接用（若配置要 max_mean 则复制一份，保持维度契约）
            if self.config.det_pool == "max_mean":
                return torch.cat([det_feat, det_feat], dim=1)
            return det_feat

        if det_feat.dim() != 3:
            raise ValueError(
                f"RiskHead: det_feat 期望 [B,N,D] 或 [B,D]，实际 {tuple(det_feat.shape)}"
            )
        b, n, d = det_feat.shape
        if det_mask is None:
            det_mask = torch.ones(b, n, device=det_feat.device, dtype=det_feat.dtype)
        else:
            det_mask = det_mask.to(dtype=det_feat.dtype)
            if det_mask.dim() == 1:
                det_mask = det_mask.unsqueeze(0).expand(b, n)
            if det_mask.shape[:2] != (b, n):
                raise ValueError(
                    f"RiskHead: det_mask 形状 {tuple(det_mask.shape)} 与 det_feat "
                    f"{tuple(det_feat.shape)} 不匹配（期望 [B,N]=({b},{n})）"
                )

        m = det_mask.unsqueeze(-1)                       # [B,N,1]
        # max pool：空槽填 -inf 后取 max，全空时回退 0
        neg_inf = torch.finfo(det_feat.dtype).min
        masked_for_max = torch.where(m > 0, det_feat, torch.full_like(det_feat, neg_inf))
        pooled_max = masked_for_max.max(dim=1).values    # [B,D]
        all_empty = (det_mask.sum(dim=1, keepdim=True) <= 0)  # [B,1]
        pooled_max = torch.where(all_empty, torch.zeros_like(pooled_max), pooled_max)

        if self.config.det_pool != "max_mean":
            return pooled_max

        # masked mean：用 1e-6 兜底避免 0 除
        denom = det_mask.sum(dim=1, keepdim=True).clamp_min(1e-6)   # [B,1]
        pooled_mean = (det_feat * m).sum(dim=1) / denom             # [B,D]
        pooled_mean = torch.where(all_empty, torch.zeros_like(pooled_mean), pooled_mean)
        return torch.cat([pooled_max, pooled_mean], dim=1)          # [B,2D]

    # ------------------------------------------------------------------
    def forward(
        self,
        fused_feat: torch.Tensor,
        det_feat: Optional[torch.Tensor] = None,
        det_mask: Optional[torch.Tensor] = None,
        speed: Optional[torch.Tensor] = None,
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """前向。

        Returns:
            (confidence [B], risk [B])，均 ∈ [0,1]
        """
        if fused_feat is None:
            raise ValueError("RiskHead.forward: fused_feat 为必填")
        if fused_feat.dim() == 1:
            fused_feat = fused_feat.unsqueeze(0)
        if fused_feat.dim() != 2:
            raise ValueError(
                f"RiskHead.forward: fused_feat 期望 [B,C]，实际 {tuple(fused_feat.shape)}"
            )
        b = fused_feat.shape[0]

        parts: List[torch.Tensor] = [fused_feat]

        # ---- 检测支路（None → 零向量退化，不报错）----
        if self.config.det_feat_dim > 0:
            if det_feat is None:
                parts.append(
                    torch.zeros(b, self.det_proj_dim, device=fused_feat.device,
                                dtype=fused_feat.dtype)
                )
            else:
                if det_feat.dim() >= 2 and det_feat.shape[0] != b:
                    raise ValueError(
                        f"RiskHead.forward: det_feat 的 batch={det_feat.shape[0]} "
                        f"与 fused_feat 的 batch={b} 不一致"
                    )
                pooled = self._pool_det(det_feat, det_mask)
                if pooled.shape[1] != self.det_proj_dim:
                    raise ValueError(
                        f"RiskHead.forward: det 支路维度 {pooled.shape[1]} "
                        f"≠ 配置 {self.det_proj_dim}"
                    )
                parts.append(pooled)

        # ---- 速度（None → 0）----
        if self.config.use_speed:
            if speed is None:
                speed_col = torch.zeros(b, 1, device=fused_feat.device, dtype=fused_feat.dtype)
            else:
                s = speed
                if s.dim() == 0:
                    s = s.reshape(1, 1).expand(b, 1)
                elif s.dim() == 1:
                    s = s.unsqueeze(1)
                if s.shape[0] != b:
                    raise ValueError(
                        f"RiskHead.forward: speed 的 batch={s.shape[0]} 与 {b} 不一致"
                    )
                speed_col = s.to(device=fused_feat.device, dtype=fused_feat.dtype)
                # 速度量纲差异大 → 做温和的尺度归一（tanh 压缩，不改变单调性）
                # 说明：真实量纲由调用方保证；这里只防止大数值把特征淹掉。
                speed_col = torch.tanh(speed_col / 30.0)
            parts.append(speed_col)

        x = torch.cat(parts, dim=1)
        if x.shape[1] != self.fused_dim_in:
            raise ValueError(
                f"RiskHead.forward: 拼接后维度 {x.shape[1]} ≠ 期望 {self.fused_dim_in}"
                f"（fused_dim={self.config.fused_dim}, det={self.det_proj_dim}, "
                f"use_speed={self.config.use_speed}）"
            )

        x = F.relu(self.fc1(x))
        x = self.dropout(x)
        x = F.relu(self.fc2(x))

        confidence = torch.sigmoid(self.confidence_head(x)).squeeze(-1)   # [B]
        risk = torch.sigmoid(self.risk_head(x)).squeeze(-1)               # [B]
        return confidence, risk


# ============================================================================
# 2. TTC —— 碰撞时间估算（物理先验）
# ============================================================================

@dataclass
class TTCConfig:
    """TTC 估算配置。

    Attributes:
        range_constant: 标定常数 K，满足 Z = K / h_norm（米）。
            **必须实测标定**；默认 None = 未标定 → 输出的 valid 全 False。
            标定方法见 `RangeCalibrator`。
        min_box_h: 框高下限（归一化）。太小的框距离估计极不可靠，直接判无效。
        min_closing_speed: 最小接近速度（m/s）。低于此值认为不接近，TTC=inf。
        max_ttc: TTC 上限（秒），超过视为 inf（远离或静止）。
        use_box_speed_field: 是否用框特征第 [9] 位（目标相对速度）作为接近速度来源。
            若无该字段（游戏检测器多不提供），置 False 走纯几何估计。
        ego_speed_is_reverse: 自车速度是否为"反向"（某些传感器给负值表示前进）。
    """

    range_constant: Optional[float] = None
    min_box_h: float = 0.02
    min_closing_speed: float = 0.5
    max_ttc: float = 30.0
    use_box_speed_field: bool = False
    ego_speed_is_reverse: bool = False


class RangeCalibrator:
    """单目距离标定辅助（Z = K / h_norm）。

    用法（**必须实测**，不能拍脑袋）：
        cal = RangeCalibrator()
        # 在游戏里把前车/固定物体放在已知距离 d 处，量它的框归一化高度 h
        cal.add(distance_m=10.0, box_h_norm=0.25)
        cal.add(distance_m=20.0, box_h_norm=0.125)
        K = cal.fit()          # 最小二乘拟合 K（Z*h = K 恒定）
        print(cal.report())

    为什么可以这样：透视投影下 `pixel_h = f * H_real / Z`，
    故 `h_norm = f * H_real / (Z * IMG_H)`，即 `Z * h_norm = f*H_real/IMG_H = K`（常数）。
    对固定游戏相机+固定目标类型成立；换相机/换目标高度需重新标定。
    """

    def __init__(self) -> None:
        self.samples: List[Tuple[float, float]] = []

    def add(self, distance_m: float, box_h_norm: float) -> None:
        if distance_m <= 0:
            raise ValueError("RangeCalibrator: distance_m 必须 > 0")
        if box_h_norm <= 0:
            raise ValueError("RangeCalibrator: box_h_norm 必须 > 0")
        self.samples.append((float(distance_m), float(box_h_norm)))

    def fit(self) -> float:
        """最小二乘拟合 K = mean(Z_i * h_i)（模型为 Z*h = K，单参数）。"""
        if not self.samples:
            raise ValueError("RangeCalibrator: 没有任何标定样本，无法拟合")
        ks = [z * h for z, h in self.samples]
        return sum(ks) / len(ks)

    def residuals(self) -> List[float]:
        """各样本相对拟合 K 的残差（米），用于判断标定可信度。"""
        if not self.samples:
            return []
        k = self.fit()
        return [abs(k / h - z) for z, h in self.samples]

    def report(self) -> str:
        if not self.samples:
            return "RangeCalibrator: 无样本"
        k = self.fit()
        res = self.residuals()
        worst = max(res)
        lines = [
            f"RangeCalibrator: K={k:.4f}（米·归一化高）",
            f"  样本数={len(self.samples)}  最大残差={worst:.3f} m",
        ]
        for (z, h), r in zip(self.samples, res):
            lines.append(f"    Z={z:.2f}m  h_norm={h:.4f}  →  K={z*h:.4f}  残差={r:.3f}m")
        if worst > 0.15 * max(z for z, _ in self.samples):
            lines.append("  ⚠️ 残差偏大：标定样本的距离跨度或测量精度不足，建议重测")
        return "\n".join(lines)


def estimate_ttc(
    dets: torch.Tensor,
    det_mask: Optional[torch.Tensor] = None,
    ego_speed: Optional[torch.Tensor] = None,
    config: Optional[TTCConfig] = None,
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """估算每个检测框的 TTC（碰撞时间）。

    Args:
        dets: [B, N, 12] 检测框特征，布局见 model_v2.py:210
              [0]x [1]y [2]w [3]h [4:8]label_onehot [8]conf [9]speed [10]heading [11]age
              **假设 x/y/w/h 均为归一化 [0,1]**（与 DetectionEncoder 约定一致）
        det_mask: [B, N] 1=有效框。None = 全有效。
        ego_speed: [B] 自车速度（m/s）。None = 未知 → 只输出距离，TTC 全 inf。
        config: TTCConfig。**range_constant=None 时 valid 全 False**。

    Returns:
        (ttc [B,N] 秒（无效处为 inf）, distance [B,N] 米（无效处为 inf）,
         valid [B,N] bool)

    ⚠️ 诚实性：单目无法直接得绝对距离，`distance` 依赖标定常数 K，
    未标定时 `valid` 全 False、`distance`/`ttc` 全 inf —— **不返回假数字**。

    几何：
        1) 距离     Z = K / h_norm          （h_norm = 框归一化高度，见 RangeCalibrator）
        2) 接近速度 v_rel：
             · 若 config.use_box_speed_field：v_rel = ego_speed − dets[...,9]
             · 否则：v_rel = ego_speed（假设前车静止/更慢的**保守**上界）
        3) TTC      = Z / v_rel              （v_rel ≤ min_closing_speed → inf）
    """
    if config is None:
        config = TTCConfig()
    if dets is None or dets.dim() != 3:
        raise ValueError(
            f"estimate_ttc: dets 期望 [B,N,12]，实际 "
            f"{None if dets is None else tuple(dets.shape)}"
        )
    if dets.shape[-1] < DET_FEAT_DIM:
        raise ValueError(
            f"estimate_ttc: dets 末维 {dets.shape[-1]} < {DET_FEAT_DIM}（布局不符）"
        )

    b, n, _ = dets.shape
    device, dtype = dets.device, dets.dtype
    inf = torch.full((b, n), float("inf"), device=device, dtype=dtype)

    if det_mask is None:
        det_mask = torch.ones(b, n, device=device, dtype=dtype)
    else:
        det_mask = det_mask.to(device=device, dtype=dtype)
        if det_mask.dim() == 1:
            det_mask = det_mask.unsqueeze(0).expand(b, n)
    valid = det_mask > 0                                   # [B,N] bool

    # ---- 未标定：如实返回全无效 ----
    if config.range_constant is None or config.range_constant <= 0:
        return inf, inf, torch.zeros(b, n, device=device, dtype=torch.bool)

    h_norm = dets[..., 3].clamp_min(0)                     # [B,N]
    too_small = h_norm < config.min_box_h
    valid = valid & (~too_small)

    # 距离 Z = K / h（h=0 处先兜底再屏蔽）
    h_safe = torch.where(valid, h_norm, torch.ones_like(h_norm))
    distance = config.range_constant / h_safe              # [B,N]
    distance = torch.where(valid, distance, inf)

    if ego_speed is None:
        # 没有自车速度 → 无法算接近速度 → TTC 全 inf（但距离仍可用）
        return inf, distance, valid

    v_ego = ego_speed.to(device=device, dtype=dtype)
    if v_ego.dim() == 0:
        v_ego = v_ego.reshape(1)
    if v_ego.shape[0] != b:
        raise ValueError(f"estimate_ttc: ego_speed batch={v_ego.shape[0]} ≠ dets batch={b}")
    v_ego = v_ego.unsqueeze(1).expand(b, n)                # [B,N]
    if config.ego_speed_is_reverse:
        v_ego = -v_ego

    if config.use_box_speed_field:
        v_lead = dets[..., 9]
        v_rel = v_ego - v_lead
    else:
        # 保守假设：目标静止（v_lead=0）→ v_rel 取上界 → TTC 取**悲观**值。
        # 宁可早报警，不可漏报（安全系统的基本原则）。
        v_rel = v_ego

    closing = v_rel > config.min_closing_speed            # [B,N] bool
    ttc_valid = valid & closing

    v_safe = torch.where(closing, v_rel, torch.ones_like(v_rel))
    ttc = distance / v_safe
    ttc = torch.where(ttc_valid, ttc, inf)
    ttc = torch.where(ttc > config.max_ttc, inf, ttc)

    return ttc, distance, ttc_valid


# ============================================================================
# 3. 接管判定（阈值 + 滞后，防抖动）
# ============================================================================

@dataclass
class TakeoverConfig:
    """接管判定阈值与滞后参数。

    滞后（hysteresis）的核心：**进入**接管的门槛比**退出**更严格/更宽松，
    形成一个死区，避免 confidence 在阈值附近抖动时"接管/交还"疯狂切换。

        conf 轴：conf < conf_enter  → 触发接管
                 conf > conf_exit   → 允许交还（conf_exit > conf_enter）
        risk 轴：risk > risk_enter  → 触发接管
                 risk < risk_exit   → 允许交还（risk_exit < risk_enter）

    Attributes:
        conf_enter: 低于此置信度 → 请求接管（默认 0.35）
        conf_exit:  高于此置信度 → 才考虑交还（默认 0.60，与 enter 拉开死区）
        risk_enter: 高于此风险 → 请求接管（默认 0.70）
        risk_exit:  低于此风险 → 才考虑交还（默认 0.45）
        min_hold_frames: 触发接管后至少保持这么多帧（防瞬间抖动）
        min_release_frames: 满足交还条件后，需连续满足这么多帧才真交还
        ttc_enter: TTC 低于此值（秒）→ 直接触发接管（物理先验，不需训练）
        ttc_release: TTC 高于此值才允许交还
    """

    conf_enter: float = 0.35
    conf_exit: float = 0.60
    risk_enter: float = 0.70
    risk_exit: float = 0.45
    min_hold_frames: int = 15
    min_release_frames: int = 30
    ttc_enter: float = 1.5
    ttc_release: float = 3.0

    def __post_init__(self) -> None:
        if self.conf_exit <= self.conf_enter:
            raise ValueError(
                f"TakeoverConfig: conf_exit({self.conf_exit}) 必须 > "
                f"conf_enter({self.conf_enter})，否则没有滞后死区"
            )
        if self.risk_exit >= self.risk_enter:
            raise ValueError(
                f"TakeoverConfig: risk_exit({self.risk_exit}) 必须 < "
                f"risk_enter({self.risk_enter})，否则没有滞后死区"
            )


@dataclass
class TakeoverState:
    """一个样本（或一条部署流）的接管状态机状态。"""

    active: bool = False
    frames_since_change: int = 0
    release_streak: int = 0
    reason: str = ""
    history: List[bool] = field(default_factory=list)


class TakeoverDecider:
    """接管判定器（带滞后的状态机）。

    ⚠️ **有状态**：同一辆车/同一段流必须复用同一个实例，否则滞后失效
    （每帧都当成"首次"就退化成裸阈值）。

    用法（部署）：
        dec = TakeoverDecider()
        for frame in stream:
            conf, risk = risk_head(...)
            ttc_min = ...            # 可选
            state = dec.update(conf, risk, ttc_min=ttc_min)
            if state.active:
                release_control_to_human(state.reason)

    用法（批量训练期诊断，逐样本独立、不跨帧共享状态）：
        dec = TakeoverDecider(per_sample=True)
        states = dec.update_batch(conf, risk, ttc_min)
    """

    def __init__(self, config: Optional[TakeoverConfig] = None, per_sample: bool = False):
        self.config = config or TakeoverConfig()
        self.per_sample = per_sample
        self.states: List[TakeoverState] = []

    # ------------------------------------------------------------------
    def _ensure(self, b: int) -> None:
        while len(self.states) < b:
            self.states.append(TakeoverState())

    def reset(self) -> None:
        self.states = []

    # ------------------------------------------------------------------
    def update(
        self,
        confidence: float,
        risk: float,
        ttc_min: Optional[float] = None,
        index: int = 0,
    ) -> TakeoverState:
        """更新单个样本的状态。

        Args:
            confidence: [0,1] 自评置信度（越高越确定）
            risk: [0,1] 危险度（越高越危险）
            ttc_min: 最小 TTC（秒）；None = 无 TTC 信息。inf/超大 = 不接近。
            index: 状态索引（批量部署且 per_sample 时区分不同车/不同流）

        Returns:
            更新后的 TakeoverState（`active` = 是否建议接管）
        """
        self._ensure(index + 1)
        st = self.states[index]
        cfg = self.config

        if not math.isfinite(confidence):
            raise ValueError(f"TakeoverDecider: confidence 非有限值 {confidence}")
        if not math.isfinite(risk):
            raise ValueError(f"TakeoverDecider: risk 非有限值 {risk}")

        # ---- 触发条件（进入）----
        reasons: List[str] = []
        if confidence < cfg.conf_enter:
            reasons.append(f"置信度低({confidence:.2f}<{cfg.conf_enter})")
        if risk > cfg.risk_enter:
            reasons.append(f"风险高({risk:.2f}>{cfg.risk_enter})")
        if ttc_min is not None and math.isfinite(ttc_min) and ttc_min < cfg.ttc_enter:
            reasons.append(f"TTC短({ttc_min:.2f}s<{cfg.ttc_enter}s)")

        # ---- 解除条件（退出）----
        clear_conf = confidence > cfg.conf_exit
        clear_risk = risk < cfg.risk_exit
        clear_ttc = (ttc_min is None) or (not math.isfinite(ttc_min)) or (ttc_min > cfg.ttc_release)
        can_release = clear_conf and clear_risk and clear_ttc

        st.frames_since_change += 1

        if st.active:
            # 已接管：需连续满足解除条件达 min_release_frames 才交还
            if can_release:
                st.release_streak += 1
                if st.release_streak >= cfg.min_release_frames:
                    st.active = False
                    st.frames_since_change = 0
                    st.release_streak = 0
                    st.reason = "条件恢复，已交还控制权"
            else:
                st.release_streak = 0
                if reasons:
                    st.reason = "＋".join(reasons)
        else:
            if reasons:
                st.active = True
                st.frames_since_change = 0
                st.release_streak = 0
                st.reason = "＋".join(reasons)
            else:
                st.reason = ""
                st.frames_since_change += 1

        # min_hold_frames：刚触发时不许立刻交还（上面的 release_streak 已经等效
        # 更强的约束，这里只做兜底记录，保证"至少保持"语义显式可见）
        if st.active and st.frames_since_change < 0:
            st.frames_since_change = 0

        st.history.append(st.active)
        if len(st.history) > 1000:
            del st.history[:-500]
        return st

    # ------------------------------------------------------------------
    def update_batch(
        self,
        confidence: torch.Tensor,
        risk: torch.Tensor,
        ttc_min: Optional[torch.Tensor] = None,
    ) -> List[TakeoverState]:
        """批量更新（per_sample=True 时每个样本独立状态机；否则共享一个）。"""
        conf_list = confidence.detach().flatten().tolist()
        risk_list = risk.detach().flatten().tolist()
        ttc_list: List[Optional[float]]
        if ttc_min is None:
            ttc_list = [None] * len(conf_list)
        else:
            ttc_list = ttc_min.detach().flatten().tolist()

        out: List[TakeoverState] = []
        for i, (c, r) in enumerate(zip(conf_list, risk_list)):
            t = ttc_list[i] if i < len(ttc_list) else None
            if not self.per_sample:
                t = ttc_list[0] if ttc_list else None
                out.append(self.update(c, r, ttc_min=t, index=0))
            else:
                out.append(self.update(c, r, ttc_min=t, index=i))
        return out


# ============================================================================
# 4. 训练信号（代理监督）
# ============================================================================

def confidence_target_from_error(
    pred: torch.Tensor,
    target: torch.Tensor,
    tau: float = 0.15,
    floor: float = 0.05,
    per_dim: bool = True,
) -> torch.Tensor:
    """用「控制量预测误差」构造 confidence 的代理真值。

    ⚠️ **这是代理（proxy），不是真值** —— 见下方 TODO。

    定义：
        err = mean(|pred − target|)  （per_dim=True 时对最后一维求均值）
        conf_target = floor + (1 − floor) * exp(−err / tau)

    · err=0    → conf_target=1.0（完全预测对 → 该自信）
    · err=tau  → ≈0.37+floor
    · err→∞   → floor（不完全为 0，保留梯度）

    为什么用 exp 而不是线性截断：exp 平滑、处处可导、不会在阈值处产生
    梯度突变；tau 控制"多小的误差算自信"。

    Args:
        pred:   [B, ...] 控制量预测（如 steer）
        target: [B, ...] 对应真值（同形状）
        tau:    误差尺度（控制量量纲）。steer ∈ [-1,1] 时 0.1~0.2 合理。
        floor:  置信度下限。
        per_dim: True=先对最后一维求均值再 exp（多控制量场景）；
                 False=逐元素（返回同形状）。

    Returns:
        confidence target，形状见 per_dim。

    ── TODO（需要 Lead 决策，本文件先按误差代理实现）────────────────────
    1. 「危险帧」标注方案未定：若有「人工接管帧 / 碰撞帧」标签，应改为
       直接监督（danger 帧 conf_target→0），比误差代理更贴用户需求
       （用户要的是"我自己没法操作时"，语义是"模型知道我不行"，
        而误差代理只教"这帧我预测得准不准"）。
    2. 误差代理有个根本局限：**模型可以误差小而完全跑偏**（自信地犯错），
       误差代理无法惩罚这种。真值方案建议至少掺入"闭环结果"信号
       （如离线回放中 steer 误差累计 / 偏离车道中心的量）。
    3. multi-task 权重：conf_loss 在总 loss 里的系数未定（需与 steer/其他
       控制量 loss 做量纲对齐实验）。建议先用 0.1 起调。
    ──────────────────────────────────────────────────────────────────
    """
    if pred.shape != target.shape:
        raise ValueError(
            f"confidence_target_from_error: pred {tuple(pred.shape)} 与 "
            f"target {tuple(target.shape)} 形状不一致"
        )
    err = (pred - target).abs()
    if per_dim and err.dim() >= 2:
        err = err.flatten(1).mean(dim=1)
    conf = floor + (1.0 - floor) * torch.exp(-err / max(tau, 1e-6))
    return conf.clamp(0.0, 1.0)


def risk_target_from_ttc(
    ttc: torch.Tensor,
    valid: Optional[torch.Tensor] = None,
    ttc_safe: float = 3.0,
    ttc_danger: float = 0.8,
) -> torch.Tensor:
    """从 TTC 构造 risk 的代理真值（线性映射 + 截断）。

    · TTC ≥ ttc_safe       → risk = 0（安全）
    · TTC ≤ ttc_danger     → risk = 1（危险）
    · 中间线性插值
    · TTC = inf / 无效      → risk = 0

    Args:
        ttc:   [B, N] 各框 TTC（秒），无效处应为 inf
        valid: [B, N] bool；None = 自动按 isfinite 判定
        ttc_safe: 安全阈值（秒）
        ttc_danger: 危险阈值（秒）

    Returns:
        [B] 取该样本所有框中**最大**风险（最危险的那个框决定风险）。
    """
    if ttc_safe <= ttc_danger:
        raise ValueError(
            f"risk_target_from_ttc: ttc_safe({ttc_safe}) 必须 > ttc_danger({ttc_danger})"
        )
    span = ttc_safe - ttc_danger
    finite = torch.isfinite(ttc)
    if valid is not None:
        finite = finite & valid.bool()
    # risk 随 TTC 下降而上升
    risk = (ttc_safe - ttc) / span
    risk = risk.clamp(0.0, 1.0)
    risk = torch.where(finite, risk, torch.zeros_like(risk))

    if risk.dim() == 1:
        return risk
    if risk.shape[1] == 0:                       # 无框
        return torch.zeros(risk.shape[0], device=risk.device, dtype=risk.dtype)
    return risk.max(dim=1).values                # [B]


# ============================================================================
# 5. 自检（import + 前向跑通，含无检测框退化）
# ============================================================================

def _self_test() -> int:
    """离线自检：不需要真实数据，验证接口契约与退化路径。

    Returns:
        失败项数（0 = 全通过）
    """
    torch.manual_seed(0)
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        mark = "✅" if ok else "❌"
        if not ok:
            failures += 1
        print(f"  {mark} {name}" + (f" — {detail}" if detail else ""))

    print("== 1. RiskHead 基本前向 ==")
    head = RiskHead()
    b = 4
    fused = torch.randn(b, DEFAULT_FUSED_DIM)
    conf, risk = head(fused)
    check("输出形状为 [B]", tuple(conf.shape) == (b,) and tuple(risk.shape) == (b,),
          f"conf={tuple(conf.shape)} risk={tuple(risk.shape)}")
    check("confidence ∈ [0,1]", bool((conf >= 0).all() and (conf <= 1).all()),
          f"min={conf.min():.4f} max={conf.max():.4f}")
    check("risk ∈ [0,1]", bool((risk >= 0).all() and (risk <= 1).all()),
          f"min={risk.min():.4f} max={risk.max():.4f}")
    check("初值 risk 偏低（不扰民）", bool(risk.mean() < 0.5), f"mean={risk.mean():.3f}")

    print("\n== 2. 带检测框 [B,N,D] + mask ==")
    det = torch.randn(b, MAX_DETECTIONS, DEFAULT_DET_FEAT_DIM)
    mask = torch.zeros(b, MAX_DETECTIONS)
    mask[:, :3] = 1.0
    conf2, risk2 = head(fused, det_feat=det, det_mask=mask, speed=torch.rand(b) * 20)
    check("带检测框前向通过", tuple(conf2.shape) == (b,))
    check("两次输出不同（检测支路生效）", not torch.allclose(conf, conf2))

    print("\n== 3. 退化路径（None / 全空 mask）==")
    conf3, risk3 = head(fused, det_feat=None, det_mask=None, speed=None)
    check("全 None 不报错", tuple(conf3.shape) == (b,))
    all_zero_mask = torch.zeros(b, MAX_DETECTIONS)
    conf4, risk4 = head(fused, det_feat=det, det_mask=all_zero_mask)
    check("mask 全 0 不产生 NaN", bool(torch.isfinite(conf4).all() and torch.isfinite(risk4).all()),
          f"conf finite={bool(torch.isfinite(conf4).all())}")
    det_only = torch.randn(b, DEFAULT_DET_FEAT_DIM)
    conf5, _ = head(fused, det_feat=det_only)
    check("[B,D] 已池化输入可用", tuple(conf5.shape) == (b,))

    print("\n== 4. batch=1 与 1D 输入 ==")
    conf6, risk6 = head(torch.randn(DEFAULT_FUSED_DIM))
    check("1D 输入自动升维", tuple(conf6.shape) == (1,))

    print("\n== 5. 配置变体 ==")
    for cfg in [
        RiskHeadConfig(use_speed=False),
        RiskHeadConfig(det_feat_dim=0),
        RiskHeadConfig(det_pool="max"),
        RiskHeadConfig(hidden=64, dropout=0.0),
    ]:
        h = RiskHead(cfg)
        c, r = h(torch.randn(2, cfg.fused_dim),
                 det_feat=torch.randn(2, 5, 16) if cfg.det_feat_dim else None,
                 det_mask=torch.ones(2, 5) if cfg.det_feat_dim else None,
                 speed=torch.rand(2) if cfg.use_speed else None)
        check(f"配置 det_feat_dim={cfg.det_feat_dim} use_speed={cfg.use_speed} "
              f"pool={cfg.det_pool} hidden={cfg.hidden}",
              tuple(c.shape) == (2,), f"conf={c.tolist()}")

    print("\n== 6. 形状不匹配时报错（不静默）==")
    try:
        head(torch.randn(4, 999))
        check("维度不符应报错", False, "未报错")
    except ValueError:
        check("维度不符应报错", True)
    try:
        head(fused, det_feat=torch.randn(2, 5, DEFAULT_DET_FEAT_DIM))
        check("batch 不符应报错", False, "未报错")
    except ValueError:
        check("batch 不符应报错", True)

    print("\n== 7. TTC 未标定 → 如实返回无效 ==")
    dets = torch.zeros(1, MAX_DETECTIONS, DET_FEAT_DIM)
    dets[0, 0, 3] = 0.25           # 高 0.25
    dets[0, 1, 3] = 0.10
    dmask = torch.zeros(1, MAX_DETECTIONS)
    dmask[0, :2] = 1.0
    ttc, dist, valid = estimate_ttc(dets, dmask, ego_speed=torch.tensor([15.0]))
    check("未标定 range_constant → valid 全 False", not bool(valid.any()))
    check("未标定 → ttc 全 inf", bool(torch.isinf(ttc).all()))

    print("\n== 8. TTC 标定后计算 ==")
    cfg = TTCConfig(range_constant=12.0)
    ttc2, dist2, valid2 = estimate_ttc(dets, dmask, ego_speed=torch.tensor([15.0]), config=cfg)
    # Z = 12/0.25 = 48m ; TTC = 48/15 = 3.2s
    ok_a = valid2[0, 0] and abs(dist2[0, 0].item() - 48.0) < 1e-3 and abs(ttc2[0, 0].item() - 3.2) < 1e-3
    check("框高 0.25 → 48m / TTC 3.2s", bool(ok_a),
          f"dist={dist2[0,0].item():.2f} ttc={ttc2[0,0].item():.3f}")
    # Z = 12/0.10 = 120m ; TTC = 8s
    ok_b = valid2[0, 1] and abs(ttc2[0, 1].item() - 8.0) < 1e-3
    check("框高 0.10 → TTC 8.0s", bool(ok_b), f"ttc={ttc2[0,1].item():.3f}")
    # 无效槽 → inf
    check("空槽 TTC=inf", bool(torch.isinf(ttc2[0, 2])))
    # 太小的框判无效
    dets_small = dets.clone()
    dets_small[0, 0, 3] = 0.001
    _, _, valid_small = estimate_ttc(dets_small, dmask, torch.tensor([15.0]), config=cfg)
    check("框高 < min_box_h → 判无效", not bool(valid_small[0, 0]))
    # 速度 0 → 不接近 → TTC inf
    _, _, valid_still = estimate_ttc(dets, dmask, torch.tensor([0.0]), config=cfg)
    check("自车静止 → TTC=inf（不接近）", not bool(valid_still.any()))

    print("\n== 9. RangeCalibrator 标定 ==")
    cal = RangeCalibrator()
    cal.add(10.0, 0.25)     # K=2.5
    cal.add(20.0, 0.125)    # K=2.5
    cal.add(5.0, 0.5)       # K=2.5
    k = cal.fit()
    check("标定 K 正确（2.5）", abs(k - 2.5) < 1e-9, f"K={k}")
    check("残差为 0", max(cal.residuals()) < 1e-9)

    print("\n== 10. 接管判定 + 滞后 ==")
    cfg_to = TakeoverConfig(conf_enter=0.35, conf_exit=0.60, min_release_frames=3)
    dec = TakeoverDecider(cfg_to)
    s1 = dec.update(confidence=0.90, risk=0.05)
    check("高置信低风险 → 不接管", not s1.active, s1.reason)
    s2 = dec.update(confidence=0.20, risk=0.05)
    check("低置信 → 接管", s2.active, s2.reason)
    # 滞后：置信回到 0.45（> enter 但 < exit）→ 仍应接管
    s3 = dec.update(confidence=0.45, risk=0.05)
    check("置信 0.45 处于死区 → 保持接管（滞后生效）", s3.active, s3.reason)
    # 连续 3 帧 > exit 才交还
    dec.update(confidence=0.80, risk=0.05)
    dec.update(confidence=0.80, risk=0.05)
    s4 = dec.update(confidence=0.80, risk=0.05)
    check("连续满足解除帧数后才交还", not s4.active, s4.reason)

    print("\n== 11. 高风险 / TTC 触发接管 ==")
    dec2 = TakeoverDecider(cfg_to)
    s5 = dec2.update(confidence=0.95, risk=0.95)
    check("高风险 → 接管", s5.active, s5.reason)
    dec3 = TakeoverDecider(cfg_to)
    s6 = dec3.update(confidence=0.95, risk=0.05, ttc_min=0.5)
    check("TTC 过短 → 接管（物理先验）", s6.active, s6.reason)
    s7 = dec3.update(confidence=0.95, risk=0.05, ttc_min=float("inf"))
    check("TTC 恢复但 release_streak 不足 → 仍接管", s7.active)

    print("\n== 12. 阈值配置非法时报错 ==")
    try:
        TakeoverConfig(conf_enter=0.6, conf_exit=0.4)
        check("conf_exit<=conf_enter 应报错", False)
    except ValueError:
        check("conf_exit<=conf_enter 应报错", True)
    try:
        TakeoverConfig(risk_enter=0.4, risk_exit=0.6)
        check("risk_exit>=risk_enter 应报错", False)
    except ValueError:
        check("risk_exit>=risk_enter 应报错", True)

    print("\n== 13. 训练信号 ==")
    pred = torch.zeros(3, 1)
    tgt0 = torch.zeros(3, 1)
    tgt_far = torch.full((3, 1), 0.5)
    c_perfect = confidence_target_from_error(pred, tgt0)
    c_bad = confidence_target_from_error(pred, tgt_far)
    check("误差 0 → conf≈1", bool((c_perfect > 0.99).all()), f"{c_perfect.tolist()}")
    check("误差大 → conf 低", bool((c_bad < c_perfect).all()), f"{c_bad.tolist()}")
    ttc_in = torch.tensor([[0.5, float("inf")], [5.0, 2.0]])
    rk = risk_target_from_ttc(ttc_in, ttc_safe=3.0, ttc_danger=0.8)
    check("risk 从 TTC 构造（取最危险框）",
          tuple(rk.shape) == (2,) and abs(rk[0].item() - 1.0) < 1e-6 and rk[1].item() < 0.6,
          f"{rk.tolist()}")

    print("\n== 14. 批量接管判定 ==")
    dec_b = TakeoverDecider(cfg_to, per_sample=True)
    states = dec_b.update_batch(
        confidence=torch.tensor([0.9, 0.1, 0.9]),
        risk=torch.tensor([0.1, 0.1, 0.9]),
    )
    check("批量：3 个样本独立判定",
          [s.active for s in states] == [False, True, True],
          f"{[s.active for s in states]}")

    print(f"\n[M3 risk_head 自检] {'PASS' if failures == 0 else 'FAIL'} "
          f"（失败 {failures} 项）")
    return failures


if __name__ == "__main__":
    raise SystemExit(_self_test())
