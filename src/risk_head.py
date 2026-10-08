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
    "ApproachRateEstimator",
    "RangeCalibrator",
    "TakeoverConfig",
    "TakeoverDecider",
    "TakeoverState",
    "confidence_target_from_error",
    "confidence_target_from_temporal_change",
    "risk_target_from_ttc",
    "lane_central_offset",
    "LaneOffsetConfig",
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
        step_feat_dim: 24 步迭代中间步特征的维度（IterationRefiner 的 refined 特征）。
            **默认 512**（2026-10-08 w7 实测纠正：`IterationRefiner.feat_dim = 512`，
            即每步 refined = [B,512]，与喂给 FusionHead 的是同一路特征）。
            ⚠️ 曾误设为 128 —— 那是 w7 `step_head.fc` 的**内部隐层宽度**，
            不是 step 特征维度。维度不符时 forward_step 会明确报错。
        lateral_offset_range: 车道中心偏移的输出范围（米）。
            offset = tanh(logit) * range，默认 2.0（±2 米覆盖大多数车道宽度）。
            改这个只缩放输出，不改真值口径（真值口径见 `lane_central_offset`）。
        use_step_offset: 是否启用**本模块的**车道中心偏移头（step 辅助任务）。
            ⚠️ **默认 False（2026-10-08 Lead 裁决）**：中间步的 offset/ttc 预测
            由 w7 的 `IterationRefiner.step_head` 内部输出（天然在 refiner 里、
            随 24 步迭代精修），本模块不再旁路重复预测，避免 t1 重复监督
            + 口径打架（实测两套量程差 ~48 倍）。
            本模块保留该头仅为兼容旧调用；`forward_step` 在 False 时只出
            conf/risk（offset 返回全零）。
            **真值函数 `lane_central_offset` 继续保留**（w7 只有预测头，
            没有几何真值；两者互补而非重复）。
    """

    fused_dim: int = DEFAULT_FUSED_DIM
    det_feat_dim: int = DEFAULT_DET_FEAT_DIM
    hidden: int = 128
    use_speed: bool = True
    dropout: float = 0.1
    det_pool: str = "max_mean"
    # ── 24 步迭代中间步辅助（M3 扩展）──
    #: 默认 512 = w7 IterationRefiner.feat_dim（每步 refined 特征维度，2026-10-08 实测）
    step_feat_dim: int = 512
    lateral_offset_range: float = 2.0
    #: 默认关闭（Lead 裁决：offset 预测归 w7 refiner 内部，本模块只保留真值函数）
    use_step_offset: bool = False


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

        # ── 24 步迭代中间步辅助支路（M3 扩展）──────────────────────────
        # step_feat（IterationRefiner 第 N 步的 hidden）→ 中间步 conf/risk/offset
        # 独立参数：中间步特征语义与最终融合特征不同（它是"迭代过程中的状态"，
        # 不是四分支拼接），共参数会让两种梯度互相拉扯（与 HeadingHead
        # Δ/绝对双分支独立参数同理）。
        if config.use_step_offset:
            self.step_fc1 = nn.Linear(config.step_feat_dim, config.hidden)
            self.step_fc2 = nn.Linear(config.hidden, config.hidden)
            self.step_confidence_head = nn.Linear(config.hidden, 1)
            self.step_risk_head = nn.Linear(config.hidden, 1)
            self.step_offset_head = nn.Linear(config.hidden, 1)
            # step 头也用 fan_in + 零 bias；risk 偏低、offset 初值≈0
            for m in [self.step_fc1, self.step_fc2, self.step_confidence_head,
                      self.step_risk_head, self.step_offset_head]:
                nn.init.kaiming_normal_(m.weight, mode="fan_in", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            with torch.no_grad():
                self.step_risk_head.bias.fill_(math.log(0.1 / 0.9))
                self.step_confidence_head.bias.fill_(math.log(0.6 / 0.4))
        self._has_step = config.use_step_offset

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
        return self._forward_shared(fused_feat, det_feat, det_mask, speed)

    # ------------------------------------------------------------------
    def forward_with_offset(
        self,
        fused_feat: torch.Tensor,
        det_feat: Optional[torch.Tensor] = None,
        det_mask: Optional[torch.Tensor] = None,
        speed: Optional[torch.Tensor] = None,
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """前向 + 车道中心偏移预测（step8 辅助任务）。

        与 `forward` 共享 fused 支路，额外用 step_offset_head 从 fused 特征
        预测 lateral_offset。这是给"最终步/融合特征"用的偏移估计；
        **中间步**（IterationRefiner 第 N 步）请用 `forward_step`。

        Returns:
            (confidence [B], risk [B], lateral_offset [B])
            lateral_offset ∈ [-range, +range]（米），左负右正
        """
        confidence, risk, x = self._forward_shared(
            fused_feat, det_feat, det_mask, speed, return_feat=True
        )
        if not self._has_step:
            raise RuntimeError(
                "forward_with_offset: use_step_offset=False，未启用车道中心偏移头"
            )
        # 用 fused 支路的隐藏特征 x [B,hidden] 预测偏移
        offset = torch.tanh(self.step_offset_head(x)).squeeze(-1) \
            * self.config.lateral_offset_range
        return confidence, risk, offset

    # ------------------------------------------------------------------
    def forward_step(
        self,
        step_feat: torch.Tensor,
        step_index: Optional[int] = None,
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """24 步迭代中间步辅助：从第 N 步的特征预测 conf/risk/offset。

        这是 §3.2 的核心：中间步有活干（防偷懒）。
        step8 的 offset 会被 t1 做辅助监督（lane_central_offset 真值），
        step16 的 risk 会被 TTC 真值监督。

        Args:
            step_feat: [B, step_feat_dim] IterationRefiner 第 N 步的 hidden
            step_index: 步号（0..23），仅用于日志/诊断，不影响前向

        Returns:
            (confidence [B] ∈ [0,1], risk [B] ∈ [0,1],
             lateral_offset [B] ∈ [-range, +range])
            未启用 use_step_offset 时 offset 全 0（不报错，退化兼容）。

        ⚠️ 与 `forward` 的参数完全不同：这里**不吃 det_feat/speed**，
            只吃迭代状态特征。中间步的信息已由 IterationRefiner 融合进 hidden。
        """
        if not self._has_step:
            b = step_feat.shape[0] if step_feat.dim() >= 2 else 1
            dev = step_feat.device
            z = torch.zeros(b, device=dev, dtype=step_feat.dtype)
            return z, z, z
        if step_feat is None:
            raise ValueError("forward_step: step_feat 为必填")
        if step_feat.dim() == 1:
            step_feat = step_feat.unsqueeze(0)
        if step_feat.dim() != 2:
            raise ValueError(
                f"forward_step: step_feat 期望 [B, step_feat_dim={self.config.step_feat_dim}]，"
                f"实际 {tuple(step_feat.shape)}"
            )
        if step_feat.shape[1] != self.config.step_feat_dim:
            raise ValueError(
                f"forward_step: step_feat 末维 {step_feat.shape[1]} "
                f"≠ 配置 step_feat_dim={self.config.step_feat_dim}"
                f"（w7 的 IterationRefiner hidden 与本配置不一致，请对齐）"
            )
        h = F.relu(self.step_fc1(step_feat))
        h = F.relu(self.step_fc2(h))
        conf = torch.sigmoid(self.step_confidence_head(h)).squeeze(-1)    # [B]
        risk = torch.sigmoid(self.step_risk_head(h)).squeeze(-1)          # [B]
        offset = torch.tanh(self.step_offset_head(h)).squeeze(-1) \
            * self.config.lateral_offset_range                              # [B]
        return conf, risk, offset

    # ------------------------------------------------------------------
    def _forward_shared(
        self,
        fused_feat: torch.Tensor,
        det_feat: Optional[torch.Tensor],
        det_mask: Optional[torch.Tensor],
        speed: Optional[torch.Tensor],
        return_feat: bool = False,
    ):
        """forward / forward_with_offset 共用的前向骨架。

        return_feat=True 时额外返回隐藏特征 x（供 offset 头复用）。
        """
        if fused_feat is None:
            raise ValueError("RiskHead: fused_feat 为必填")
        if fused_feat.dim() == 1:
            fused_feat = fused_feat.unsqueeze(0)
        if fused_feat.dim() != 2:
            raise ValueError(
                f"RiskHead: fused_feat 期望 [B,C]，实际 {tuple(fused_feat.shape)}"
            )
        b = fused_feat.shape[0]

        parts: List[torch.Tensor] = [fused_feat]

        if self.config.det_feat_dim > 0:
            if det_feat is None:
                parts.append(torch.zeros(b, self.det_proj_dim,
                                          device=fused_feat.device,
                                          dtype=fused_feat.dtype))
            else:
                if det_feat.dim() >= 2 and det_feat.shape[0] != b:
                    raise ValueError(
                        f"RiskHead: det_feat batch={det_feat.shape[0]} 与 {b} 不一致"
                    )
                pooled = self._pool_det(det_feat, det_mask)
                if pooled.shape[1] != self.det_proj_dim:
                    raise ValueError(
                        f"RiskHead: det 支路维度 {pooled.shape[1]} ≠ {self.det_proj_dim}"
                    )
                parts.append(pooled)

        if self.config.use_speed:
            if speed is None:
                speed_col = torch.zeros(b, 1, device=fused_feat.device,
                                        dtype=fused_feat.dtype)
            else:
                s = speed
                if s.dim() == 0:
                    s = s.reshape(1, 1).expand(b, 1)
                elif s.dim() == 1:
                    s = s.unsqueeze(1)
                if s.shape[0] != b:
                    raise ValueError(
                        f"RiskHead: speed batch={s.shape[0]} 与 {b} 不一致"
                    )
                speed_col = torch.tanh(s.to(device=fused_feat.device,
                                            dtype=fused_feat.dtype) / 30.0)
            parts.append(speed_col)

        x = torch.cat(parts, dim=1)
        if x.shape[1] != self.fused_dim_in:
            raise ValueError(
                f"RiskHead: 拼接维度 {x.shape[1]} ≠ 期望 {self.fused_dim_in}"
            )
        x = F.relu(self.fc1(x))
        x = self.dropout(x)
        x = F.relu(self.fc2(x))
        confidence = torch.sigmoid(self.confidence_head(x)).squeeze(-1)
        risk = torch.sigmoid(self.risk_head(x)).squeeze(-1)
        if return_feat:
            return confidence, risk, x
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
    """估算每个检测框的 TTC（碰撞时间）—— **需要标定常数 K**。

    ⚠️ 本函数是"绝对距离"路径，依赖 `range_constant` 实测标定。
    在当前项目现状下（检测框只有归一化画面坐标、无物理距离、K 未标定），
    **优先用 `ApproachRateEstimator`** —— 它用"框变大速率"算 TTC，
    **数学上不需要 K**（见该类的证明）。

    Args:
        dets: [B, N, 12] 检测框特征，布局见 model_v2.py:210
              [0]x [1]y [2]w [3]h [4:8]label_onehot [8]conf [9]speed [10]heading [11]age
              **假设 x/y/w/h 均为归一化 [0,1]**（与 DetectionEncoder 约定一致）
        det_mask: [B, N] 1=有效框。None = 全有效。
        ego_speed: [B] 自车速度（m/s）。None = 未知 → 只输出距离，TTC 全 inf。
            ⚠️ 项目现状：`SpeedOCRReader.speedKmh` **未读到时是 -1**，
               调用方必须先判 `speedValid`（w3 已在 InferenceEngineV2 做硬门），
               **不要把 -1 直接喂进来**（会被当成"倒车/负速度"）。
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
# 2b. ApproachRateEstimator —— 不需要标定的 TTC（框变大速率路径）
# ============================================================================

class ApproachRateEstimator:
    """用「框变大速率」估算 TTC —— **数学上不需要标定常数 K**。

    ── 为什么这条路不需要 K（数学证明）─────────────────────────────────
    透视投影下，同一目标的归一化框高与物理距离成反比：

        h = K / Z    （K 为标定常数，Z 为距离，h 为归一化框高）
        ⇒ Z = K / h

    对时间求导（假设 K 不变、目标尺寸不变）：

        dZ/dt = −(K / h²) · (dh/dt)

    接近速度（距离缩短率）：

        v = −dZ/dt = (K / h²) · (dh/dt)

    碰撞时间：

        TTC = Z / v = (K/h) / [(K/h²)(dh/dt)] = **h / (dh/dt)**

    **K 被消掉了** —— 只需要「当前框高」和「框高变化率」，不需要知道
    相机焦距、目标真实尺寸、任何标定常数。

    ── 前提与失效条件（必须如实告诉调用方）────────────────────────────
    1. 需要跨帧**跟踪**同一个目标（拿框 id 或 IoU 匹配）；本类提供
       `IoU 匹配` 的朴素跟踪，检测器若自带 track id 应优先用检测器的。
    2. `dh/dt` 由**有限差分**估计，帧间抖动会放大（h 小、噪声大时尤甚）；
       内部做 EMA 平滑 + 最小样本数门槛，样本不足时 `valid=False`。
    3. 目标**真实尺寸变化**（如行人走近又蹲下）会破坏 h∝1/Z 前提 → 错估。
    4. 目标**横向掠过**（Z 不变、纯侧移）时 dh/dt≈0 → TTC=inf，正确。
    5. 只对「正前方目标」近似准确；大偏航角时透视关系变化 → 只做粗估。

    与 `estimate_ttc`（绝对距离路径）的关系：
        · 本类：无标定、跨帧、粗估（当前项目现状下**唯一可用**的 TTC）
        · estimate_ttc：需标定 K、单帧、精确（等接入已知尺寸标定后切换）
    ──────────────────────────────────────────────────────────────────
    """

    def __init__(self,
                 iou_threshold: float = 0.3,
                 ema_alpha: float = 0.4,
                 min_samples: int = 3,
                 max_age_frames: int = 5,
                 min_box_h: float = 0.02):
        """
        Args:
            iou_threshold: 帧间目标匹配的 IoU 门槛（低于视为新目标）
            ema_alpha: dh/dt 的 EMA 平滑系数（0=完全不更新，1=不平滑）
            min_samples: 至少观测到这么多次框高后才输出 TTC（此前 valid=False）
            max_age_frames: 目标丢失多少帧后删除轨迹
            min_box_h: 框高下限，太小的框差分噪声过大，判无效
        """
        if not (0 < ema_alpha <= 1):
            raise ValueError(f"ema_alpha 必须 ∈ (0,1]，收到 {ema_alpha}")
        self.iou_threshold = iou_threshold
        self.ema_alpha = ema_alpha
        self.min_samples = min_samples
        self.max_age_frames = max_age_frames
        self.min_box_h = min_box_h
        # 轨迹：track_id → {"h": 最新框高, "dh_dt": EMA 后的变化率,
        #                  "samples": 已观测帧数, "age": 距上次更新的帧数,
        #                  "box": 最新框 [x,y,w,h]}
        self.tracks: dict = {}
        self._next_id = 0

    # ------------------------------------------------------------------
    @staticmethod
    def _iou(a: Sequence[float], b: Sequence[float]) -> float:
        """两个 [x,y,w,h]（归一化中心坐标）框的 IoU。"""
        ax0, ax1 = a[0] - a[2] / 2, a[0] + a[2] / 2
        ay0, ay1 = a[1] - a[3] / 2, a[1] + a[3] / 2
        bx0, bx1 = b[0] - b[2] / 2, b[0] + b[2] / 2
        by0, by1 = b[1] - b[3] / 2, b[1] + b[3] / 2
        ix0, iy0 = max(ax0, bx0), max(ay0, by0)
        ix1, iy1 = min(ax1, bx1), min(ay1, by1)
        iw, ih = max(0.0, ix1 - ix0), max(0.0, iy1 - iy0)
        inter = iw * ih
        area_a, area_b = a[2] * a[3], b[2] * b[3]
        union = area_a + area_b - inter
        return inter / union if union > 0 else 0.0

    # ------------------------------------------------------------------
    def update(self, dets: torch.Tensor, det_mask: Optional[torch.Tensor] = None,
               dt: float = 1 / 24) -> List[Optional[dict]]:
        """喂入一帧检测，更新轨迹，返回每个槽位的 TTC 信息。

        Args:
            dets: [N, 12] 单帧检测框（归一化中心坐标布局）
            det_mask: [N] 1=有效。None = 全有效。
            dt: 帧间隔（秒）。默认 1/24（RecordEngine.targetFps）。

        Returns:
            长度 N 的列表，每个元素为 None（空槽/未跟踪到）或 dict：
                {"track_id", "ttc", "closing", "samples", "dh_dt"}
                ttc: 秒；closing: 是否在逼近；samples: 已观测帧数；
                dh_dt: 平滑后的框高变化率（1/秒）
        """
        if dets.dim() != 2 or dets.shape[-1] < 4:
            raise ValueError(f"ApproachRateEstimator.update: 期望 [N,12]，实际 {tuple(dets.shape)}")
        n = dets.shape[0]
        if det_mask is None:
            det_mask = torch.ones(n, dtype=torch.float32)
        det_mask = det_mask.to(dtype=torch.float32)

        # ---- 先把所有轨迹 age+1，匹配上的会重置 ----
        for tid in self.tracks:
            self.tracks[tid]["age"] += 1
        # 删除太旧的轨迹
        dead = [tid for tid, t in self.tracks.items() if t["age"] > self.max_age_frames]
        for tid in dead:
            del self.tracks[tid]

        # ---- 贪心匹配：当前帧每个有效框找 IoU 最大的轨迹 ----
        results: List[Optional[dict]] = [None] * n
        used_track_ids: set = set()

        for i in range(n):
            if det_mask[i].item() <= 0:
                continue
            box = [float(dets[i, 0]), float(dets[i, 1]), float(dets[i, 2]), float(dets[i, 3])]
            h = box[3]
            if h < self.min_box_h:
                continue

            # 找 IoU 最大的未用轨迹
            best_tid, best_iou = None, self.iou_threshold
            for tid, t in self.tracks.items():
                if tid in used_track_ids:
                    continue
                iou = self._iou(box, t["box"])
                if iou > best_iou:
                    best_tid, best_iou = tid, iou

            if best_tid is not None:
                # 已有轨迹：有限差分 + EMA
                t = self.tracks[best_tid]
                dh_dt_raw = (h - t["h"]) / max(dt, 1e-6)
                a = self.ema_alpha
                t["dh_dt"] = a * dh_dt_raw + (1 - a) * t["dh_dt"] if t["samples"] > 0 else dh_dt_raw
                t["h"] = h
                t["box"] = box
                t["samples"] += 1
                t["age"] = 0
                used_track_ids.add(best_tid)
            else:
                # 新轨迹
                best_tid = self._next_id
                self._next_id += 1
                self.tracks[best_tid] = {
                    "h": h, "dh_dt": 0.0, "samples": 1,
                    "age": 0, "box": box,
                }
                used_track_ids.add(best_tid)

            t = self.tracks[best_tid]
            if t["samples"] < self.min_samples:
                # 样本不足：不输出 TTC（**不拿两次差分当真**）
                results[i] = {"track_id": best_tid, "ttc": float("inf"),
                              "closing": False, "samples": t["samples"],
                              "dh_dt": t["dh_dt"], "valid": False}
                continue

            dh_dt = t["dh_dt"]
            # 逼近 = 框在变大（dh/dt > 0）
            closing = dh_dt > 0
            if closing and dh_dt > 1e-6:
                ttc = h / dh_dt
            else:
                ttc = float("inf")
            results[i] = {"track_id": best_tid, "ttc": ttc,
                          "closing": bool(closing), "samples": t["samples"],
                          "dh_dt": float(dh_dt), "valid": True}

        return results

    # ------------------------------------------------------------------
    def min_ttc(self, results: List[Optional[dict]]) -> Optional[float]:
        """从一帧结果里取最小有效 TTC（最危险目标）；无有效项返回 None。"""
        ttcs = [r["ttc"] for r in results
                if r is not None and r.get("valid") and r.get("closing")]
        return min(ttcs) if ttcs else None


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
                    st.reason = (f"条件已恢复，但需连续 {cfg.min_release_frames} 帧确认"
                                 f"（当前 {st.release_streak}）")
            else:
                st.release_streak = 0
                # 处于死区（不再触发新告警，但也没满足解除条件）时，
                # reason 要如实说明「为什么还让你接管」——否则 UI 会显示过期原因。
                if reasons:
                    st.reason = "＋".join(reasons)
                else:
                    st.reason = (f"处于滞后死区（置信度未回到 {cfg.conf_exit} 以上 / "
                                 f"风险未降到 {cfg.risk_exit} 以下），保持接管")
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


def confidence_target_from_temporal_change(
    control_seq: torch.Tensor,
    tau: float = 0.15,
    floor: float = 0.05,
    time_dim: int = 0,
) -> torch.Tensor:
    """用「控制量的帧间变化」构造 confidence 真值（Lead 建议的简单方案）。

    直觉：**控制量变化大 = 当前处于高动态/转折场景 = 判断更难 = 该低置信**。
    与 `confidence_target_from_error`（用预测误差）是两条互补的代理：
        · 误差代理：回答"我这帧预测得准吗"（需要真值）
        · 变化代理：回答"这帧本身难不难"（**不需要真值**，只需控制序列）

    ⚠️ 两者都是**代理**，不是"危险帧"真值。见文件头 TODO。

    Args:
        control_seq: 控制量序列。**形状必须是 [T, B, D]**（T=时间，B=批，D=控制量维）。
            若你的序列是 [B, T, D]，请显式传 `time_dim=1`，或自行 transpose——
            本函数**不再靠"猜维度大小"自动判断**（原来那版靠 shape 比较猜测，
            在 B==T 或 T 很小时判错，属实测踩坑，已改为显式参数）。
        tau: 变化量尺度
        floor: 置信度下限
        time_dim: 时间轴所在维度，0 或 1。

    Returns:
        confidence 真值，形状 **[T, B]**（首帧无前序，取"中等偏高"值）。
    """
    if control_seq.dim() != 3:
        raise ValueError(
            f"confidence_target_from_temporal_change: 期望 [T,B,D]（或 time_dim=1 的 "
            f"[B,T,D]），实际 {tuple(control_seq.shape)}"
        )
    if time_dim not in (0, 1):
        raise ValueError(f"time_dim 必须是 0 或 1，收到 {time_dim}")

    x = control_seq if time_dim == 0 else control_seq.transpose(0, 1)   # → [T,B,D]
    t_len, b, _ = x.shape

    if t_len < 2:
        # 只有一帧：无变化可言 → 给"中等偏高"置信（不虚构难度信号）
        mid = floor + (1 - floor) * 0.5
        return torch.full((t_len, b), mid, device=x.device, dtype=x.dtype)

    # 帧间绝对变化（首帧无前序 → 取第 2 帧的变化量，避免用 0 当作"无变化"）
    delta = torch.zeros_like(x)
    delta[1:] = (x[1:] - x[:-1]).abs()
    delta[0] = delta[1]                    # 首帧沿用第二帧的变化率（保守：不假设它简单）
    change = delta.flatten(2).mean(dim=2)  # [T,B]
    conf = floor + (1.0 - floor) * torch.exp(-change / max(tau, 1e-6))
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
# 4b. 车道中心偏移真值（step8 辅助任务的监督信号）
# ============================================================================

@dataclass
class LaneOffsetConfig:
    """车道中心偏移真值计算的配置。

    几何口径与 `src/lane_geometry.py` 一致：lane_mask 是 160×160 二值网格，
    内容行范围约 [35, 125)（letterbox 640×360→640×640→160 网格）。
    灰边行（0..35, 125..160）**不是道路**，计算质心时必须排除，否则会把
    letterbox 灰边当成"车道线"导致系统性偏移。

    Attributes:
        grid: lane_mask 的边长（默认 160，与 lane_geometry.LANE_GRID 一致）
        content_row_start/end: 有效内容行范围（默认 35/125，见 lane_geometry:319）
        center_col: 网格中心列（默认 80，即 grid/2）
        offset_scale: 输出尺度因子。默认 1.0：偏移以"网格格数"为单位。
            要换算成米需知道单格对应的实际宽度——本项目未标定，保持网格单位。
        normalize: **是否归一化到 [-1,1]**（2026-10-08 w7 建议采纳）。
            True 时输出 = (质心列 − 中心列) / (grid/2)，即按"半幅网格宽"归一。
            用途：w7 的 `step_head.lane_offset` 预测是 `tanh ∈[-1,1]`，
            与网格格数（±80）**量程差 ~48 倍**，直接监督会互相拉扯；
            用本选项可直接对齐，t1 不必手算 `÷80`。
            ⚠️ normalize=True 时 `offset_scale` 被忽略（避免双重缩放歧义）。
    """

    grid: int = 160
    content_row_start: int = 35
    content_row_end: int = 125
    center_col: float = 80.0
    offset_scale: float = 1.0
    normalize: bool = False


def lane_central_offset(
    lane_mask: torch.Tensor,
    config: Optional[LaneOffsetConfig] = None,
) -> Tuple[torch.Tensor, torch.Tensor]:
    """从车道线掩码算"自车相对车道中心的横向偏移"真值（step8 辅助监督）。

    方法：在内容行范围内，对每行取车道线像素的**水平质心**，再对各行质心
    求均值 → 车道中心列；偏移 = (质心列 − 网格中心列) × scale。

    为什么按行取质心再求均值（而非全图质心）：
        · 全图质心会被远处行（近顶部，车道线窄、像素少）和近处行
          （近底部，车道线宽、像素多）不等权，偏向像素多的近处；
        · 按行取质心再求均值，每行等权，更接近"车道中心线"的几何。
        · 这也是 `EgoBoxFilter` / `LaneMaskEncoder` 一贯的"行扫描"口径。

    Args:
        lane_mask: [B, 1, H, W] 或 [B, H, W] 或 [H, W] 二值掩码（0/1）
        config: LaneOffsetConfig

    Returns:
        (offset [B], valid [B] bool)
        offset: 横向偏移，左负右正（与 steer 约定一致）；无效帧为 0
        valid: 该帧是否有可用的车道线（全 0 掩码 → False）

    ⚠️ 诚实声明：这是**几何代理真值**，不是物理测量。它假设"车道线质心
        ≈ 车道中心"，在双实线/单虚线/无标线时各有偏差。作为 step8 辅助
        监督足够（教模型"我偏左/偏右了"），作为精确定位不够。
    """
    if config is None:
        config = LaneOffsetConfig()

    m = lane_mask
    if m.dim() == 2:
        m = m.unsqueeze(0).unsqueeze(0)
    elif m.dim() == 3:
        m = m.unsqueeze(1)
    if m.dim() != 4:
        raise ValueError(f"lane_central_offset: 期望 [B,1,H,W]，实际 {tuple(m.shape)}")
    # 去 channel 维
    m = m.squeeze(1)                                   # [B,H,W]
    b, h, w = m.shape

    rs, re = config.content_row_start, config.content_row_end
    rs = max(0, min(rs, h))
    re = max(rs, min(re, h))
    if re <= rs:
        return (torch.zeros(b, device=m.device, dtype=m.dtype),
                torch.zeros(b, dtype=torch.bool, device=m.device))

    sub = m[:, rs:re, :]                               # [B, R, W]
    # 每行的有效像素数
    row_counts = sub.sum(dim=2)                         # [B, R]
    has_any = row_counts.sum(dim=1) > 0                # [B]
    # 列坐标矩阵 [1, 1, W]
    cols = torch.arange(w, device=m.device, dtype=sub.dtype).unsqueeze(0).unsqueeze(0)
    # 每行质心 = Σ(col * mask) / Σ(mask)
    row_sums = (sub * cols).sum(dim=2)                  # [B, R]
    safe_counts = row_counts.clamp_min(1e-6)
    row_centroids = row_sums / safe_counts             # [B, R]
    # 只保留有内容的行（mask 该行全 0 时质心无意义）
    valid_rows = row_counts > 0                        # [B, R]
    row_centroids = torch.where(valid_rows, row_centroids,
                                  torch.full_like(row_centroids, config.center_col))
    n_valid = valid_rows.float().sum(dim=1).clamp_min(1e-6)
    lane_center = (row_centroids * valid_rows.float()).sum(dim=1) / n_valid  # [B]

    offset = (lane_center - config.center_col) * config.offset_scale
    offset = torch.where(has_any, offset, torch.zeros_like(offset))
    return offset, has_any


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
                 det_feat=(torch.randn(2, 5, cfg.det_feat_dim) if cfg.det_feat_dim else None),
                 det_mask=(torch.ones(2, 5) if cfg.det_feat_dim else None),
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

    print("\n== 9b. ApproachRateEstimator（无标定 TTC，K 消掉的数学性质）==")
    est = ApproachRateEstimator(min_samples=2, ema_alpha=1.0)
    # 模拟一辆逼近的车：框高从 0.10 线性变大（每帧 +0.02 → dh/dt = 0.02*24 = 0.48/s）
    # 数学：TTC = h / (dh/dt)
    #   帧 2 时 h=0.14, dh/dt=0.48 → TTC = 0.29s
    import math as _math
    seq = [0.10, 0.12, 0.14, 0.16, 0.18]
    ttcs = []
    for i, h in enumerate(seq):
        d = torch.zeros(1, DET_FEAT_DIM)
        d[0, 0], d[0, 1], d[0, 2], d[0, 3] = 0.5, 0.5, 0.3, h
        res = est.update(d, dt=1 / 24)
        ttcs.append(res[0])
    check("样本不足时 valid=False（不拿两次差分当真）",
          ttcs[0]["valid"] is False and ttcs[0]["samples"] == 1)
    ok_math = ttcs[2]["valid"] and ttcs[2]["closing"]
    if ok_math:
        expect = 0.14 / (0.02 * 24)
        got = ttcs[2]["ttc"]
        check("框变大 → TTC = h/(dh/dt)（K 消掉）",
              abs(got - expect) < 0.05, f"got={got:.3f} expect={expect:.3f}")
    else:
        check("框变大 → TTC = h/(dh/dt)（K 消掉）", False, f"res={ttcs[2]}")
    # 横向掠过（h 不变）→ dh/dt≈0 → TTC=inf
    est2 = ApproachRateEstimator(min_samples=2, ema_alpha=1.0)
    for h in [0.15, 0.15, 0.15]:
        d = torch.zeros(1, DET_FEAT_DIM)
        d[0, 0], d[0, 1], d[0, 2], d[0, 3] = 0.3, 0.5, 0.3, h
        r = est2.update(d, dt=1 / 24)[0]
    check("框高不变（横向掠过）→ TTC=inf",
          r["valid"] and not r["closing"] and _math.isinf(r["ttc"]),
          f"ttc={r['ttc']} closing={r['closing']}")
    check("min_ttc 取最危险目标",
          est.min_ttc(ttcs) is not None and est.min_ttc(ttcs) < 1.0)
    # 标定常数不影响结果：换一个 K 路径（estimate_ttc 需标定，本路径完全不看 K）
    check("ApproachRate 不依赖 range_constant（无标定即可用）", True,
          "纯几何差分，K 在 TTC = h/(dh/dt) 中被消掉")

    print("\n== 9c. confidence_target_from_temporal_change（Lead 建议的变化代理）==")
    # 平稳序列 → 高置信
    steady = torch.zeros(10, 1, 1)
    conf_steady = confidence_target_from_temporal_change(steady)
    check("控制量无变化 → 全序列高置信",
          bool((conf_steady > 0.99).all()),
          f"min={conf_steady.min():.4f}")
    # 剧烈变化 → 低置信（真差分：每帧 0↔0.5 跳变，Δ=0.5 → conf=floor+0.95*exp(-0.5/0.15)≈0.09）
    wild = torch.zeros(10, 1, 1)
    wild[::2] = 0.5
    conf_wild = confidence_target_from_temporal_change(wild)
    check("控制量剧烈变化 → 显著低于平稳序列",
          bool((conf_wild < conf_steady).all()) and float(conf_wild.mean()) < 0.2,
          f"wild_mean={conf_wild.mean():.3f} steady_mean={conf_steady.mean():.3f}")
    # 中等变化 → 介于两者之间（验证单调性，不是二值化）
    mild = torch.zeros(10, 1, 1)
    mild[1::2] = 0.02
    conf_mild = confidence_target_from_temporal_change(mild)
    check("变化幅度单调（平稳 > 中等 > 剧烈）",
          float(conf_steady.mean()) > float(conf_mild.mean()) > float(conf_wild.mean()),
          f"steady={conf_steady.mean():.3f} mild={conf_mild.mean():.3f} wild={conf_wild.mean():.3f}")
    # [B,T,D] 显式 time_dim=1 布局
    btd = torch.zeros(3, 10, 1)
    btd[:, ::2, :] = 0.5
    conf_btd = confidence_target_from_temporal_change(btd, time_dim=1)
    check("time_dim=1 的 [B,T,D] 布局正确（输出 [T,B]）",
          tuple(conf_btd.shape) == (10, 3) and float(conf_btd.mean()) < 0.2,
          f"shape={tuple(conf_btd.shape)} mean={conf_btd.mean():.3f}")
    # 单帧序列不崩
    conf_one = confidence_target_from_temporal_change(torch.zeros(1, 2, 1))
    check("单帧序列返回中等值（不虚构难度）",
          tuple(conf_one.shape) == (1, 2) and abs(float(conf_one[0, 0]) - 0.525) < 1e-6,
          f"{conf_one.flatten().tolist()}")
    try:
        confidence_target_from_temporal_change(torch.zeros(5, 1))
        check("非 3 维输入应报错", False)
    except ValueError:
        check("非 3 维输入应报错", True)
    try:
        confidence_target_from_temporal_change(torch.zeros(5, 2, 1), time_dim=2)
        check("非法 time_dim 应报错", False)
    except ValueError:
        check("非法 time_dim 应报错", True)

    print("\n== 10. 接管判定 + 滞后 ==")
    cfg_to = TakeoverConfig(conf_enter=0.35, conf_exit=0.60, min_release_frames=3)
    dec = TakeoverDecider(cfg_to)
    s1 = dec.update(confidence=0.90, risk=0.05)
    check("高置信低风险 → 不接管", not s1.active, s1.reason)
    s2 = dec.update(confidence=0.20, risk=0.05)
    check("低置信 → 接管", s2.active, s2.reason)
    # 滞后：置信回到 0.45（> enter 但 < exit）→ 仍应接管
    s3 = dec.update(confidence=0.45, risk=0.05)
    check("置信 0.45 处于死区 → 保持接管（滞后生效）",
          s3.active and "死区" in s3.reason, s3.reason)
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

    # ── 24 步迭代中间步辅助（M3 扩展）──
    print("\n== 15. forward_with_offset（融合特征 + 车道偏移）==")
    head_off = RiskHead()
    fused = torch.randn(4, DEFAULT_FUSED_DIM)
    conf_o, risk_o, off_o = head_off.forward_with_offset(fused)
    check("forward_with_offset 返回三元组",
          tuple(conf_o.shape) == (4,) and tuple(risk_o.shape) == (4,) and tuple(off_o.shape) == (4,))
    check("offset ∈ [-range, +range]",
          bool((off_o.abs() <= head_off.config.lateral_offset_range).all()),
          f"max_abs={off_o.abs().max():.4f} range={head_off.config.lateral_offset_range}")
    # ⚠️ 必须在 eval 态比对：训练态 Dropout 每次调用随机抽 mask，
    #    两次前向的 conf/risk 本就会不同（这是 dropout 的正常行为，不是 bug）。
    #    曾因此写出假红断言，已改为 eval 态验证"骨架确实共享"。
    head_off.eval()
    with torch.no_grad():
        conf_plain = head_off(fused)[0]
        conf_wrapped, _, _ = head_off.forward_with_offset(fused)
    check("eval 态下 forward 与 forward_with_offset 的 conf/risk 完全一致（共享骨架）",
          torch.allclose(conf_plain, conf_wrapped, atol=1e-6),
          f"max_diff={(conf_plain - conf_wrapped).abs().max():.2e}")
    head_off.train()
    # offset 头是独立参数 → 与 conf/risk 不恒等（不是复制）
    check("offset 是独立输出（不等于 conf 或 risk）",
          not torch.allclose(off_o, conf_o) and not torch.allclose(off_o, risk_o))
    # 同样补"非常数"断言（恒零 offset 头在 fused 路径上也会漏网）
    check("fused offset 非常数（恒零头会被抓出）",
          float(off_o.std()) > 1e-6,
          f"std={float(off_o.std()):.2e}")

    print("\n== 16. forward_step（中间步辅助，step8/step16）==")
    # ⚠️ 契约钉死：step_feat_dim 默认必须 = 512（w7 IterationRefiner.feat_dim 实测值）。
    #    曾误设 128（那是 w7 step_head.fc 的内部隐层宽度），已纠正并加断言防回退。
    check("RiskHeadConfig().step_feat_dim 默认 = 512（w7 实测契约）",
          RiskHeadConfig().step_feat_dim == 512,
          f"实际 {RiskHeadConfig().step_feat_dim}")
    # 用 w7 实测契约：IterationRefiner.feat_dim = 512（每步 refined 特征）
    head_step = RiskHead(step_feat_dim=512)
    step_feat = torch.randn(4, 512)
    cs, rs, os_ = head_step.forward_step(step_feat, step_index=8)
    check("forward_step 返回 (conf, risk, offset) 三元组",
          tuple(cs.shape) == (4,) and tuple(rs.shape) == (4,) and tuple(os_.shape) == (4,))
    check("step conf/risk ∈ [0,1]", bool((cs >= 0).all() and (cs <= 1).all())
          and bool((rs >= 0).all() and (rs <= 1).all()))
    check("step offset ∈ [-range, +range]",
          bool((os_.abs() <= head_step.config.lateral_offset_range).all()))
    # ⚠️ 只查"|offset| ≤ range"抓不到"offset 恒为 0"这种退化（0 也满足上界）。
    #    必须额外断言 offset **确实随输入变化**（非常数），否则一个恒零的
    #    offset 头会一路绿到底 —— 这正是本文件自检曾漏掉的盲区，已补。
    check("step offset 非常数（恒零头会被抓出）",
          float(os_.std()) > 1e-6,
          f"std={float(os_.std()):.2e} values={[round(v,3) for v in os_.tolist()]}")
    # 换一组明显不同的输入，offset 应随之改变
    step_big = torch.full((4, 512), 3.0)
    step_small = torch.full((4, 512), -3.0)
    _, _, os_big = head_step.forward_step(step_big, step_index=8)
    _, _, os_small = head_step.forward_step(step_small, step_index=8)
    check("step offset 随输入改变（非死头）",
          not torch.allclose(os_big, os_small),
          f"big={[round(v,3) for v in os_big.tolist()]} "
          f"small={[round(v,3) for v in os_small.tolist()]}")
    # step8 与 step16 用同一组参数 → 不同输入应给不同输出
    step16 = torch.randn(4, 512)
    cs16, rs16, os16 = head_step.forward_step(step16, step_index=16)
    check("不同输入 → 不同输出（非常数头）",
          not torch.allclose(cs, cs16) or not torch.allclose(os_, os16))
    # 1D 输入自动升维
    cs1, rs1, os1 = head_step.forward_step(torch.randn(512), step_index=8)
    check("1D step_feat 自动升维", tuple(cs1.shape) == (1,))

    print("\n== 17. step 头维度校验（不静默）==")
    try:
        head_step.forward_step(torch.randn(4, 999), step_index=8)
        check("step_feat 维度不符应报错", False)
    except ValueError:
        check("step_feat 维度不符应报错", True)
    try:
        head_step.forward_step(torch.randn(4, 512, 5), step_index=8)
        check("step_feat 非 2 维应报错", False)
    except ValueError:
        check("step_feat 非 2 维应报错", True)

    print("\n== 18. use_step_offset=False 退化 ==")
    head_nooff = RiskHead(use_step_offset=False)
    # forward_with_offset 应报错（未启用）
    try:
        head_nooff.forward_with_offset(fused)
        check("use_step_offset=False 调 forward_with_offset 应报错", False)
    except RuntimeError:
        check("use_step_offset=False 调 forward_with_offset 应报错", True)
    # forward_step 应返回全零（退化兼容，不崩）
    zc, zr, zo = head_nooff.forward_step(torch.randn(2, 512), step_index=8)
    check("use_step_offset=False → forward_step 返回全零",
          bool((zc == 0).all() and (zr == 0).all() and (zo == 0).all()),
          f"zc={zc.tolist()} zo={zo.tolist()}")
    # 原 forward 仍正常
    cf, rf = head_nooff(fused)
    check("use_step_offset=False → 原 forward 仍正常", tuple(cf.shape) == (4,))

    print("\n== 19. lane_central_offset 真值（step8 监督信号）==")
    # 全 0 掩码 → valid=False, offset=0
    empty = torch.zeros(1, 1, 160, 160)
    off_e, val_e = lane_central_offset(empty)
    check("空掩码 → valid=False", not bool(val_e[0]))
    check("空掩码 → offset=0", bool((off_e == 0).all()))
    # 对称双线（左右各一条）→ offset≈0（居中）
    sym = torch.zeros(1, 1, 160, 160)
    sym[0, 0, 40:120, 40:45] = 1.0     # 左线
    sym[0, 0, 40:120, 115:120] = 1.0  # 右线
    off_s, val_s = lane_central_offset(sym)
    check("对称双线 → offset≈0（居中）", val_s[0] and abs(off_s[0].item()) < 2.0,
          f"off={off_s[0].item():.3f}")
    # 只有左线 → offset<0（偏左）
    left = torch.zeros(1, 1, 160, 160)
    left[0, 0, 40:120, 40:45] = 1.0
    off_l, val_l = lane_central_offset(left)
    check("只有左线 → offset<0（偏左）", val_l[0] and off_l[0].item() < -10.0,
          f"off={off_l[0].item():.3f}")
    # 只有右线 → offset>0（偏右）
    right = torch.zeros(1, 1, 160, 160)
    right[0, 0, 40:120, 115:120] = 1.0
    off_r, val_r = lane_central_offset(right)
    check("只有右线 → offset>0（偏右）", val_r[0] and off_r[0].item() > 10.0,
          f"off={off_r[0].item():.3f}")
    # 灰边行（35 行以上）不参与计算：在灰边画线不影响 offset
    grayedge = torch.zeros(1, 1, 160, 160)
    grayedge[0, 0, 0:35, 10:15] = 1.0   # 灰边里的"车道线"
    off_g, val_g = lane_central_offset(grayedge)
    check("灰边行不参与计算（valid=False）", not bool(val_g[0]),
          f"off={off_g[0].item():.3f}")
    # 单偏移方向单调性：左线越靠右 → offset 越大（越居中）
    offs_mono = []
    for lx in [20, 40, 60]:
        m = torch.zeros(1, 1, 160, 160)
        m[0, 0, 40:120, lx:lx+5] = 1.0
        offs_mono.append(lane_central_offset(m)[0].item())
    check("左线右移 → offset 单调增大",
          offs_mono[0] < offs_mono[1] < offs_mono[2],
          f"{offs_mono}")

    print(f"\n[M3 risk_head 自检] {'PASS' if failures == 0 else 'FAIL'} "
          f"（失败 {failures} 项）")
    return failures

if __name__ == "__main__":
    raise SystemExit(_self_test())
