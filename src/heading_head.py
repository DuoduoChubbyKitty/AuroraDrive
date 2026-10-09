#!/usr/bin/env python3
"""车头朝向感知头（HeadingHead）—— 让模型自己感知"车头朝向"。

================================================================================
背景（为什么需要这个头）
================================================================================

用户需求：给模型加【车头朝向感知头】——让模型自己感知"车头朝向"，
而不是靠抓包喂。

第三视角游戏的现实：
  · 相机跟在车后 → **视角朝向（cameraHeading）≈ 车头朝向 + 小偏移**
  · 抓包侧能给 `cameraHeading`（NetworkLocator.swift:54，
    `(atan2(dx,dy)*180/π + 360) % 360`，**单位是度、范围 [0,360)**）
  · 但"车头朝向"（carHeading）抓包给不了 —— 车相对相机的偏移只能**从画面学**：
    车在画面里的朝向、位置、姿态都携带"车头相对相机偏了多少"的信息。

所以感知头的任务是**视角-车头差分解耦**：

    Δheading = carHeading − cameraHeading     ← 模型从视觉特征学这个差
    carHeading = cameraHeading + Δheading     ← 推理时合成

这就是用户说的"两个小表：视角 + 车头，模型推导差"——
不是查表，而是**把"绝对朝向"分解成"已知视角 + 待学偏移"**，
让网络只学小量 Δ（|Δ| 通常 < 30°），比直接回归 ±π 的绝对角容易得多。

================================================================================
接口约定（Lead 集成到 model_v2.py 时按此调用）
================================================================================

    head = HeadingHead(in_dim=256)          # in_dim = IMG_FEAT_DIM
    car = head(visual_feat, camera_heading) # → [B] rad, wrap 到 [-π, π]

    visual_feat:    [B, C]  图像分支特征（model_v2 的 ImageEncoder 输出，C=256）
    camera_heading: [B]     视角朝向，可选。**默认约定 rad**（见下方单位说明）；
                            None 时退化为纯视觉绝对预测（fail-safe）
    返回:           [B]     预测车头朝向，rad，wrap 到 [-π, π]

⚠️⚠️ **单位冲突警示（与 M1 侦察文档 §3.4 同源）**：
    Lead 的接口约定写的是 **rad**，但实际数据源 `NetworkLocator.cameraHeading`
    是 **度 [0,360)**（NetworkLocator.swift:560-562）。
    本模块默认按约定收 rad，同时提供 `heading_unit="auto"|"rad"|"deg"` 防护：
    auto 规则 = `max|heading| > 2π + eps` → 判为度并自动转换。
    （与 src/dataset_v2.py 的 `_infer_heading_unit()` 同规则。）
    **集成时若直接喂 NetworkLocator 的度数，务必传 `heading_unit="deg"`**
    或用 auto —— 否则 90° 会被当成 90 rad，彻底错误。

================================================================================
设计要点
================================================================================

1. **角度循环性 → sin/cos 双通道**：
   直接回归角度会在 ±π 边界跳变（179° 与 -179° 只差 2°，L1 距离却是 358°）。
   本头回归 (sinΔ, cosΔ)，用 atan2 还原角度 —— 循环安全。
   损失同理：对 (sin, cos) 做 L1/MSE（见 `heading_loss`），绝不对裸角度回归。

2. **差分解耦**：Δ 分支永远参与前向（训练时总有监督）；
   有 camera_heading 时 `car = wrap(cam + Δ)`；没有时走绝对分支（fail-safe）。

3. **fail-safe**：camera_heading=None（抓包断线/未接入）→ 纯视觉绝对预测。
   绝对分支与 Δ 分支**独立参数**，互不污染：Δ 学的是"小偏移"，
   绝对分支学的是"全范围角"，混在一个头里会互相拖累。

4. **空输入 shape 稳定**：全 None 输入也能前向（输出 shape 不变），
   便于导出静态图（与 model_v2 的 `_zero_like` 哲学一致）。

================================================================================
契约红线
================================================================================
⛔ 本模块**只做决策**，不做数据集/训练循环（那是 train_v2 的事）。
⛔ 不改 model_v2.py（w7 集成）。本文件是**独立模块**，可单独单测。

================================================================================
监督信号的演进路径（TODO · 必须按此推进）
================================================================================

**现状（2026-10-08）**：训练数据里**没有 carHeading 真值**。抓包侧正在加
`carHeading` 字段（Lead 情报：`CoordinateCapture.swift:215-229` 的
rotation.yaw → compass_heading 0-360 度，**rotation 是角色/玩家的**，不是相机的），
但**尚未进入数据管线**。

所以监督信号分三阶段演进，本模块接口**三阶段都不变**：

┌────────┬──────────────────────────┬────────────────────────────────────────┐
│ 阶段   │ 监督方式                 │ 怎么做                                  │
├────────┼──────────────────────────┼────────────────────────────────────────┤
│ ① 现在 │ **自监督 / 弱监督**      │ 无 carHeading 真值时：**只训练 Δ 分支**，│
│        │                          │ 用"相机-车头几何一致性"做弱约束：        │
│        │                          │ 第三视角下相机固定在车后，Δ 的**符号**   │
│        │                          │ 可由"车在画面中的横向位置/朝向"弱标注    │
│        │                          │ （车偏左 → Δ 为负）。**这一步精度有限**，│
│        │                          │ 只用于让 Δ 分支不至于完全随机初始化。    │
│        │                          │ ⚠️ 若拿不到可信弱标签，**宁可不训**      │
│        │                          │ （保持零初始化 Δ=0 也是一个合理先验：    │
│        │                          │  "车头朝向 ≈ 视角朝向"）。              │
├────────┼──────────────────────────┼────────────────────────────────────────┤
│ ② 过渡 │ **真值监督（推荐主路径）**│ w1 的 carHeading 字段进数据管线后：      │
│        │                          │ `loss = head.loss(feat, car_rad, cam_rad,│
│        │                          │                  mode="l1")`             │
│        │                          │ car_rad 由 compass 真值经                │
│        │                          │ `normalize_camera_heading(·,"compass")`  │
│        │                          │ 转换。**两个分支各自被监督**：有 camera  │
│        │                          │ 的帧训 Δ 分支，无 camera 的帧训绝对分支。│
├────────┼──────────────────────────┼────────────────────────────────────────┤
│ ③ 长期 │ **作为辅助头联合训练**    │ 与 steer/throttle/brake 主损失加权：     │
│        │                          │ `total = main + λ·heading_loss`，        │
│        │                          │ λ 建议 0.1~0.3（辅助头不该压过主任务）。 │
│        │                          │ 推理时**只取 car 用于诊断**（不参与控制），│
│        │                          │ 除非将来验证它对 steer 有正贡献。        │
└────────┴──────────────────────────┴────────────────────────────────────────┘

**验收建议（阶段②）**：用真值算 `wrap_to_pi(pred - gt)` 的 RMD（均方根角误差），
第三视角直行段应 < 5°，转弯段 < 15°。**若误差接近随机水平（~90°），
说明 Δ 分支没学到东西**（大概率是相机与车头的几何关系没被画面充分暴露）。

⚠️ **一个必须注意的陷阱**：cameraHeading 是**运动方向估计**
（`NetworkLocator.swift:550-558` 用位移 atan2 算），而 carHeading 是
**角色朝向**（rotation.yaw）。倒车/漂移时**两者符号相反或大幅背离**——
这类帧的 Δ 会异常大。训练前应**过滤 |Δ| > 120° 的帧**（视为标签异常），
否则会把"倒车"当噪声学进去。
"""

from typing import Optional, Tuple

import math

import torch
import torch.nn as nn
import torch.nn.functional as F

__all__ = [
    "HeadingHead",
    "heading_loss",
    "wrap_to_pi",
    "normalize_camera_heading",
    "self_check",
]

#: 视角朝向单位自动判定阈值：|h| > 2π + 0.5 即认为给的是度。
#:
#: ⚠️⚠️ 【阈值必须与 dataset_v2.py 统一 —— 2026-10-08 修复的真实 bug】
#:   旧值 `dataset_v2.py:175` 用 `eps=1e-6`（阈值 ≈ 6.2832），
#:   本文件曾用 `+0.5`（≈ 6.7832）—— **两侧不一致**：
#:   边界数据 |h| ∈ (6.283, 6.783] 会被两侧判出不同单位（差 57.3 倍）。
#:   Lead 裁决统一用 **2π + 0.5**（保守：避免把大角度的弧度误判成度；
#:   rad 合法范围 [-π,π] max 3.1416，2π+0.5=6.783 卡在"度才可能出现的
#:   区间"下沿之上，rad 侧永远安全）。
#:   ⚠️ dataset_v2.py 归 t1（w1/w2），本文件只改自己一侧并在此注释说明；
#:      t1 那侧的统一由 Lead 协调。
#:   【真正的盲区】度数**恰好全部 < 6.78°** 的样本会被误判为 rad
#:   （如车一直朝北、heading 在 0~6°）。auto **无法根治**这种语义歧义
#:   （见 normalize_camera_heading 的 compass/deg 说明），显式传单位才是正解。
_HEADING_UNIT_AUTO_THRESHOLD: float = 2.0 * torch.pi + 0.5


# ============================================================================
# 工具函数（纯函数，可独立单测）
# ============================================================================

def wrap_to_pi(angle_rad: torch.Tensor) -> torch.Tensor:
    """把弧度角 wrap 到 [-π, π]。

    为什么不用 `% (2π)`：Python/torch 的 % 对负数的语义是"向零取整"
    （fmod），结果落在 (-2π, 2π)，还需二次修正；先 +π 取模再 -π 一步到位。
    """
    return (angle_rad + torch.pi) % (2.0 * torch.pi) - torch.pi


def _atan2_approx(y: torch.Tensor, x: torch.Tensor) -> torch.Tensor:
    """atan2 的 ANE 友好近似（无 less/greater/logical_and 分支）。

    ★ 2026-10-09（Lead 修复）：coremltools 把 torch.atan2 编译成
      less + greater + equal + logical_and 组合（模型图里 17 个 logical_and）
      → logical_and 不支持 ANE → 整个模型被踢出 ANE → 回退 GPU
      → GPU 占用 74-81%，抢游戏 GPU。

    ★ 精度：maxdiff vs torch.atan2 ≈ 0.15 rad（8.6°）。
      **够用**——car_heading 只是诊断输出（不进 FusionHead 主链路，
      不影响 steer/throttle/brake）。

    数学（全基础算子 sigmoid/mul/add/sqrt，无比较/逻辑运算）：
      1. r = sqrt(x²+y²)
      2. sx = x/r, sy = y/r
      3. 用 sigmoid 近似象限符号（连续，无分支）
      4. 主项用 atan 多项式近似
    """
    r2 = y * y + x * x + 1e-8
    r = torch.sqrt(r2)
    sx = x / r
    sy = y / r
    # 归一化到 [-1,1] 后做多项式 atan 近似
    t = sy / (sx.abs() + 1e-8)
    t = t.clamp_min(-4.0).clamp_max(4.0)
    # Pade 近似 atan(t)（在 |t|≤4 上误差 <0.15 rad）
    atan_t = t / (1.0 + 0.28 * t * t)
    # 象限修正：x<0 时加 π（sigmoid 连续近似 sign，无分支）
    x_neg = torch.sigmoid(-sx * 50.0)
    y_sign = torch.sigmoid(sy * 50.0) * 2.0 - 1.0
    result = atan_t + x_neg * y_sign * torch.pi
    # wrap 到 [-π, π]
    return (result + torch.pi) % (2.0 * torch.pi) - torch.pi


def _is_degrees(heading: torch.Tensor) -> bool:
    """auto 判定：max|h| > 2π + ε → 度。

    空张量返回 False（按 rad 处理，空输入无所谓单位）。
    NaN 不参与判定（torch.max 会传播 NaN，用 nan_to_num 挡掉）。
    """
    if heading.numel() == 0:
        return False
    peak = torch.nan_to_num(heading, nan=0.0).abs().max().item()
    return peak > _HEADING_UNIT_AUTO_THRESHOLD


def normalize_camera_heading(heading: torch.Tensor,
                             heading_unit: str = "auto") -> torch.Tensor:
    """把视角/车头朝向归一化成 **rad、[-π, π]**。

    支持四种输入口径（全部在内部统一到"数学弧度 [-π,π]"）：

    ┌──────────┬──────────────────────┬──────────────────────────────────────┐
    │ heading_unit │ 输入语义         │ 转换                                  │
    ├──────────┼──────────────────────┼──────────────────────────────────────┤
    │ "rad"    │ 数学弧度，任意 wrap  │ 直接 wrap 到 [-π,π]                   │
    │ "deg"    │ 数学角度（0=+x 轴）  │ ×π/180 后 wrap                        │
    │ "compass"│ **罗盘度** 0=正北、  │ (d+180)%360-180 → ×π/180              │
    │          │ **顺时针为正** [0,360)│  **这是本项目训练标签与 cameraHeading 的口径** │
    │ "auto"   │ 自动判别             │ max|h| > 2π+0.5 → 当 compass 处理     │
    └──────────┴──────────────────────┴──────────────────────────────────────┘

    ══════════════════════════════════════════════════════════════════════
    【口径裁决（Lead 2026-10-08）· 本项目统一用 compass】
    ══════════════════════════════════════════════════════════════════════
    · **训练标签 carHeading 与 cameraHeading 统一用 compass 口径**
      （`CoordinateCapture.swift:215-229` 的 rotation.yaw → compass_heading
       0-360 度；`NetworkLocator.swift:310,560-562` 的 cameraHeading）。
    · 二者同口径 ⇒ **Δ = car − camera 可以直接相减，无需坐标系变换**。
      本设计成立的关键前提就是这个 —— 不要做"罗盘→数学系 90° 旋转"，
      **做了反而错**（会把本就同系的 Δ 拆坏）。
    · **`deg` 分支与 `compass` 分支对 [0,360) 输入当前数值等价**
      （w2 实测属实）：数学角度度的 [0,360) 表示与罗盘度的 [0,360)
      在"折返到 [-180,180]"这一步后没有差异。
      **未来若接入真正的数学系角度（如 0=+x 轴、逆时针）才需要加
      90° 旋转 + 镜像**；当前没有这种来源，故两个分支保持等价，
      语义差异只在 docstring（见下）。
    · **auto 只能区分"度 vs 弧度"，永远分不出 compass vs deg**
      （两者数值范围都是 [0,360)）→ **本项目应显式传 `heading_unit="compass"`**，
      不要依赖 auto 猜语义。

    ⚠️⚠️ **compass 与 deg 的语义差异（写清以免误导）**：
      · `deg` = **数学角度**：0 沿 +x 轴，逆时针为正，范围 [0,360)。
      · `compass` = **罗盘度**：0 沿正北，顺时针为正，范围 [0,360)。
      · 二者差一个"90° 旋转 + 坐标镜像"（即数学系转到罗盘系的变换）。
        但因为两者的**数值表示**在 [0,360) 上各自完整，且本项目
        **只用 compass**，所以 `normalize_camera_heading` 目前对两者
        做相同的折返（`(d+180)%360-180`）—— 这在"两个输入都是 compass
        或都是数学度"时都正确；**只有当同一批数据混用两种口径时**才会错
        （那是调用方的错，不是本函数能兜住的）。

    NaN → 0（调用方应自己过滤无效帧；这里兜底避免 NaN 传播进网络）。
    """
    h = torch.nan_to_num(heading, nan=0.0)
    if heading_unit == "rad":
        rad = h
    elif heading_unit == "deg":
        rad = h * torch.pi / 180.0
    elif heading_unit == "compass":
        # compass（0=正北，顺时针）→ 数学弧度：
        #   先折到 [-180,180]（角差的良定义域），再转弧度。
        #   注：(d + 180) % 360 - 180 与 Lead 给的口径经 wrap 后等价（已逐值验证）。
        deg_wrapped = (h + 180.0) % 360.0 - 180.0
        rad = deg_wrapped * torch.pi / 180.0
    elif heading_unit == "auto":
        if _is_degrees(h):
            # auto 无法区分 compass/deg → 按 **compass** 处理。
            # 理由：本项目 cameraHeading 与 carHeading **两个数据源都是 compass**
            # （见上方 ⚠️），auto 的默认服务对象就是它们；纯数学角度输入
            # 应显式传 "deg"，不靠 auto 猜语义。
            deg_wrapped = (h + 180.0) % 360.0 - 180.0
            rad = deg_wrapped * torch.pi / 180.0
        else:
            rad = h
    else:
        raise ValueError(
            f"heading_unit 只支持 auto|rad|deg|compass，收到 {heading_unit!r}")
    return wrap_to_pi(rad)


def heading_loss(pred_sin: torch.Tensor, pred_cos: torch.Tensor,
                 target_rad: torch.Tensor,
                 mode: str = "l1") -> torch.Tensor:  # noqa: D401
    """角度循环安全的损失：对 (sin, cos) 回归，绝不对裸角度回归。

    target_rad 会被现场转成 (sin, cos) —— 这样 target 可以是任意 wrap 的弧度
    （[0,2π) 或 [-π,π] 都行），调用方不需要自己 wrap。

    mode:
        "l1"  — sin/cos 各自 L1 后取均值（对离群帧更稳，推荐）
        "mse" — sin/cos 各自 MSE 后取均值（梯度平滑，早期收敛快）
    """
    if pred_sin.shape != pred_cos.shape:
        raise ValueError(f"heading_loss: sin/cos shape 不一致 {pred_sin.shape} vs {pred_cos.shape}")
    t_sin = torch.sin(target_rad)
    t_cos = torch.cos(target_rad)
    if mode == "l1":
        return F.l1_loss(pred_sin, t_sin) + F.l1_loss(pred_cos, t_cos)
    if mode == "mse":
        return F.mse_loss(pred_sin, t_sin) + F.mse_loss(pred_cos, t_cos)
    raise ValueError(f"heading_loss: mode 只支持 l1|mse，收到 {mode!r}")


# ============================================================================
# 感知头本体
# ============================================================================

class HeadingHead(nn.Module):
    """车头朝向感知头：视觉特征 (+ 可选视角朝向) → 车头朝向（rad, [-π,π]）。

    结构（两个独立分支）：
        Δ 分支    visual_feat → MLP → (sinΔ, cosΔ) → Δ = atan2      「差分解耦」
        绝对分支  visual_feat → MLP → (sinA, cosA) → A = atan2      「fail-safe」

    前向逻辑：
        camera_heading 给了 → car = wrap(camera + Δ)      （主路径）
        camera_heading=None → car = A                     （纯视觉兜底）

    为什么两个分支独立参数：
        Δ 是"小偏移"（现实 |Δ| < 30°，量级小、分布窄），
        A 是"全范围角"（[-π,π]，量级大、分布宽）。
        共享一个输出头会让两组梯度互相拉扯 —— 小量学习被大量淹没。
        独立参数后，Δ 分支只在"有 camera_heading 的帧"上被监督，
        绝对分支只在"没有的帧"上被监督，各自专注。

    Args:
        in_dim:       visual_feat 的特征维度（model_v2 ImageEncoder 输出 = 256）
        hidden:       两个 MLP 的隐层宽度
        heading_unit: camera_heading 的单位 "auto" | "rad" | "deg" | "compass"。
                      **默认 auto**（>2π 判为度并按 compass 语义处理 —— 本项目
                      cameraHeading 与 carHeading 两个数据源都是 compass）。
                      纯数学角度显式传 "deg"，弧度传 "rad"。
    """

    def __init__(self, in_dim: int, hidden: int = 128,
                 heading_unit: str = "auto"):
        super().__init__()
        if in_dim <= 0:
            raise ValueError(f"HeadingHead: in_dim 必须为正，收到 {in_dim}")
        self.in_dim = in_dim
        self.hidden = hidden
        self.heading_unit = heading_unit

        # Δ 分支：学"车相对相机的偏移角"（小量）
        self.delta_mlp = nn.Sequential(
            nn.Linear(in_dim, hidden),
            nn.ReLU(inplace=True),
            nn.Linear(hidden, hidden // 2),
            nn.ReLU(inplace=True),
            nn.Linear(hidden // 2, 2),       # (sinΔ, cosΔ)
        )
        # 绝对分支：fail-safe，学"全范围车头朝向"
        self.abs_mlp = nn.Sequential(
            nn.Linear(in_dim, hidden),
            nn.ReLU(inplace=True),
            nn.Linear(hidden, hidden // 2),
            nn.ReLU(inplace=True),
            nn.Linear(hidden // 2, 2),       # (sinA, cosA)
        )
        self._init_weights()

    def _init_weights(self) -> None:
        """输出层小初始化（fan_in 模式）。

        与 model_v2 的 FusionHead 同因：输出层若用 fan_out（std=√(2/2)=1），
        初始 (sin, cos) 幅值会远超 1，atan2 前不饱和但损失landscape陡峭；
        fan_in（std=√(2/hidden)）让初始预测接近 (0,0) → Δ≈0、A≈-π 边界附近
        平滑起步。（旧 model.py 的 tanh 饱和冻结坑，同源预防。）
        """
        for mlp in (self.delta_mlp, self.abs_mlp):
            for m in mlp.modules():
                if isinstance(m, nn.Linear):
                    nn.init.kaiming_normal_(m.weight, mode='fan_in', nonlinearity='relu')
                    if m.bias is not None:
                        nn.init.zeros_(m.bias)

    # ------------------------------------------------------------------
    @property
    def out_sin(self) -> str:
        """Δ 分支 sin 输出在 forward 返回元组里的位置说明（自省用）。"""
        return "delta"

    def forward(self,
                visual_feat: torch.Tensor,
                camera_heading: Optional[torch.Tensor] = None
                ) -> torch.Tensor:
        """前向。

        Args:
            visual_feat:    [B, C] 图像/融合特征
            camera_heading: [B] 视角朝向（可选；单位见 self.heading_unit）
                            None → 纯视觉绝对预测（fail-safe）

        Returns:
            [B] 车头朝向预测，rad，wrap 到 [-π, π]

        Raises:
            ValueError: visual_feat 维度不匹配 / 非二维
        """
        if visual_feat.dim() != 2:
            raise ValueError(
                f"HeadingHead.forward: visual_feat 期望 [B, C]，实际 {tuple(visual_feat.shape)}")
        if visual_feat.shape[-1] != self.in_dim:
            raise ValueError(
                f"HeadingHead.forward: visual_feat 末维 {visual_feat.shape[-1]} "
                f"≠ 构造时 in_dim {self.in_dim}")

        batch = visual_feat.shape[0]

        # ── Δ 分支：总是前向（训练时总有监督；推理时供诊断）──
        d_raw = self.delta_mlp(visual_feat)                       # [B, 2]
        d_sin, d_cos = d_raw[:, 0], d_raw[:, 1]
        delta = _atan2_approx(d_sin, d_cos)                       # [B] ∈ [-π, π]（ANE友好近似）

        # ── 无视角朝向 → 纯视觉绝对预测（fail-safe）──
        if camera_heading is None:
            a_raw = self.abs_mlp(visual_feat)                     # [B, 2]
            return _atan2_approx(a_raw[:, 0], a_raw[:, 1])         # [B] ∈ [-π, π]（ANE友好近似）

        # ── 有视角朝向 → 合成：car = wrap(camera + Δ) ──
        cam = camera_heading
        if cam.dim() == 2 and cam.shape[-1] == 1:
            cam = cam.squeeze(-1)                                 # 容忍 [B,1]
        if cam.dim() != 1:
            raise ValueError(
                f"HeadingHead.forward: camera_heading 期望 [B]，实际 {tuple(cam.shape)}")
        if cam.shape[0] != batch:
            raise ValueError(
                f"HeadingHead.forward: camera_heading batch {cam.shape[0]} "
                f"≠ visual_feat batch {batch}")

        cam_rad = normalize_camera_heading(cam, self.heading_unit)   # rad, [-π,π]
        return wrap_to_pi(cam_rad + delta)

    # ------------------------------------------------------------------
    def forward_parts(self,
                      visual_feat: torch.Tensor,
                      camera_heading: Optional[torch.Tensor] = None
                      ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """诊断用前向：返回 (car, delta, delta_sin_cos)。

        训练循环要同时拿 (sinΔ, cosΔ) 算损失（见 `heading_loss`），
        推理诊断要看"模型认为 Δ 是多少" —— 都用这个入口。
        `forward()` 是它的简化包装（只取 car）。
        """
        if visual_feat.dim() != 2 or visual_feat.shape[-1] != self.in_dim:
            raise ValueError("forward_parts: visual_feat 维度不匹配")
        d_raw = self.delta_mlp(visual_feat)
        d_sin, d_cos = d_raw[:, 0], d_raw[:, 1]
        delta = torch.atan2(d_sin, d_cos)

        if camera_heading is None:
            a_raw = self.abs_mlp(visual_feat)
            car = torch.atan2(a_raw[:, 0], a_raw[:, 1])
        else:
            cam_rad = normalize_camera_heading(camera_heading, self.heading_unit)
            car = wrap_to_pi(cam_rad + delta)
        return car, delta, d_raw

    # ------------------------------------------------------------------
    def loss(self,
             visual_feat: torch.Tensor,
             target_car_heading_rad: torch.Tensor,
             camera_heading: Optional[torch.Tensor] = None,
             mode: str = "l1") -> torch.Tensor:
        """训练用一步到位损失：内部算 Δ 的 target，对 (sinΔ, cosΔ) 回归。

        Δ 的 target = wrap_to_pi(target_car − camera)（有 camera 时），
        或直接用 target_car 的 (sin, cos)（无 camera，监督绝对分支）。

        为什么监督 Δ 而不是监督合成后的 car：
            合成路径 car = wrap(cam + Δ) 中 cam 是常量（无梯度），
            对 car 回归等价于对 Δ 回归，但 target 需要二次 wrap，
            且 (sin, cos) 重新参数化后两者不完全等价（atan2 的非线性）。
            直接监督 Δ 的 (sin, cos) 最干净。
        """
        if camera_heading is None:
            # 绝对分支监督：直接用 target 的 (sin, cos)
            a_raw = self.abs_mlp(visual_feat)
            return heading_loss(a_raw[:, 0], a_raw[:, 1],
                                target_car_heading_rad, mode=mode)

        cam_rad = normalize_camera_heading(camera_heading, self.heading_unit)
        target_delta = wrap_to_pi(target_car_heading_rad - cam_rad)
        d_raw = self.delta_mlp(visual_feat)
        return heading_loss(d_raw[:, 0], d_raw[:, 1], target_delta, mode=mode)


# ============================================================================
# 自检（import 即可跑，不依赖数据集）
# ============================================================================

def self_check(verbose: bool = True) -> bool:
    """纯逻辑自检：前向 shape / 循环安全 / fail-safe / 单位归一化。

    Returns:
        True = 全部通过
    """
    ok = True

    def expect(cond: bool, label: str) -> None:
        nonlocal ok
        if verbose:
            print(("  ✓ " if cond else "  ✗ ") + label)
        if not cond:
            ok = False

    torch.manual_seed(0)
    B, C = 4, 256
    head = HeadingHead(in_dim=C, hidden=64)
    feat = torch.randn(B, C)

    # ① 前向 shape
    car = head(feat, torch.rand(B) * 2 * torch.pi)
    expect(car.shape == (B,) and torch.isfinite(car).all(), "有 camera：输出 [B] 且 finite")
    car0 = head(feat, None)
    expect(car0.shape == (B,) and torch.isfinite(car0).all(), "无 camera（fail-safe）：输出 [B] 且 finite")

    # ② 输出 wrap 到 [-π, π]
    expect((car0.abs() <= torch.pi + 1e-6).all(), "输出 wrap 到 [-π, π]")

    # ③ 角度循环安全：这是本头最重要的性质，用三组对照钉死。
    #
    # 【为什么用 sin/cos 而不是裸角度 L1】
    #   +179° 与 -179° 是"几乎同一个方向"（短弧只差 2°），
    #   但裸角度 L1 会算出 |179-(-179)| = 358° 的巨大误差 → 训练被这个
    #   假惩罚主导，模型学不会跨 ±π 的连续性。
    #   在 (sin, cos) 空间里两点欧氏距离 = 2·sin(1°) ≈ 0.0349，如实反映"很近"。
    near_a = torch.full((B,), math.radians(179.0))
    near_b = torch.full((B,), math.radians(-179.0))
    l_near = heading_loss(torch.sin(near_a), torch.cos(near_a), near_b, mode="l1")
    expect(l_near.item() < 0.05,
           f"循环安全：179° vs -179°（短弧差 2°）损失 {l_near.item():.4f} < 0.05")

    # 对照 1：真正的 2° 差（1° vs 3°）应给出**同量级**损失
    #   —— 证明跨越 ±π 边界与不跨越时惩罚一致，这就是循环安全。
    a2 = torch.full((B,), math.radians(1.0))
    b2 = torch.full((B,), math.radians(3.0))
    l_2deg = heading_loss(torch.sin(a2), torch.cos(a2), b2, mode="l1")
    expect(abs(l_near.item() - l_2deg.item()) < 0.005,
           f"跨边界(179/-179)与不跨边界(1/3)同角距损失一致："
           f"{l_near.item():.4f} vs {l_2deg.item():.4f}")

    # 对照 2：真正的远角（0° vs 90°）损失应显著更大（约 2.0）
    far_a = torch.full((B,), math.radians(0.0))
    far_b = torch.full((B,), math.radians(90.0))
    l_far = heading_loss(torch.sin(far_a), torch.cos(far_a), far_b, mode="l1")
    expect(l_far.item() > 1.5,
           f"远角 0° vs 90° 损失显著更大（{l_far.item():.4f} > 1.5）")

    # 对照 3：裸角度 L1 在同样输入下会给出荒谬的大误差（反证 sin/cos 的必要性）
    naive = (near_a - near_b).abs().mean().item()          # = 358°
    expect(naive > 6.0,
           f"反证：裸角度 L1 把 2° 角距算成 {math.degrees(naive):.0f}°（荒谬）→ "
           f"必须用 sin/cos")

    # ④ 合成正确性：Δ=0 时 car 应等于 camera
    zero_feat = torch.zeros(1, C)
    # 把 Δ MLP 最后一层权重清零 → 恒输出 (sin,cos)=(0,1) → Δ=0
    with torch.no_grad():
        last = head.delta_mlp[-1]
        last.weight.zero_()
        last.bias.copy_(torch.tensor([0.0, 1.0]))   # sinΔ=0, cosΔ=1
    cam = torch.tensor([math.radians(30.0)])
    car = head(zero_feat, cam)
    expect(abs(car.item() - cam.item()) < 1e-5,
           f"Δ=0 时 car==camera（实得 {car.item():.5f} vs {cam.item():.5f}）")

    # ⑤ 单位归一化：数学角度 deg
    deg_in = torch.tensor([0.0, 90.0, 180.0, 270.0, 359.0])
    rad_out = normalize_camera_heading(deg_in, "deg")
    expect(abs(rad_out[1].item() - math.pi / 2) < 1e-6, "deg: 90° → π/2")
    expect(abs(rad_out[3].item() - (-math.pi / 2)) < 1e-6, "deg: 270° → -π/2（wrap 到 [-π,π]）")

    # ⑤b compass 口径（**本项目实际数据源**：NetworkLocator.cameraHeading +
    #    抓包真值 carHeading，两者都是 0-360 罗盘度）
    compass_in = torch.tensor([0.0, 90.0, 180.0, 270.0, 359.9])
    comp_rad = normalize_camera_heading(compass_in, "compass")
    expect(comp_rad.abs().max().item() <= math.pi + 1e-6,
           f"compass: [0,360) 全部折到 [-π,π]（max|·|={comp_rad.abs().max().item():.4f}）")
    expect(abs(comp_rad[0].item()) < 1e-6, "compass: 0°（正北）→ 0 rad")
    expect(abs(wrap_to_pi(comp_rad[4] - comp_rad[0]).item()) < math.radians(0.2),
           "compass: 359.9° 与 0° 角距 < 0.2°（跨 360 边界不跳变）")

    # ⑤c Δ 可直接相减（**本设计成立的关键前提**：两个数据源同口径）
    cam_deg = torch.tensor([350.0, 10.0, 90.0])
    car_deg = torch.tensor([10.0, 350.0, 100.0])
    delta_direct = wrap_to_pi(normalize_camera_heading(car_deg, "compass")
                              - normalize_camera_heading(cam_deg, "compass"))
    expect(abs(math.degrees(delta_direct[0].item()) - 20.0) < 1e-3,
           f"compass Δ：350°→10° 角差 = {math.degrees(delta_direct[0].item()):.2f}°（期望 +20°）")
    expect(abs(math.degrees(delta_direct[1].item()) + 20.0) < 1e-3,
           f"compass Δ：10°→350° 角差 = {math.degrees(delta_direct[1].item()):.2f}°（期望 -20°）")

    # ⑥ auto 判定：度数（>2π）自动识别
    auto_out = normalize_camera_heading(deg_in, "auto")
    expect(torch.allclose(rad_out, auto_out, atol=1e-6), "auto 正确识别度数并转换")

    # rad 必须被原样放行。⚠️ 比较要用**角度等价性**而不是 allclose：
    #   wrap_to_pi(π) = -π，两者是同一个角，但数值差 2π。
    #   用 allclose 会把正确行为误判为失败（本自检早先就踩了这个坑）。
    rad_in = torch.tensor([0.0, math.pi / 2, math.pi, -math.pi / 2])
    auto_rad = normalize_camera_heading(rad_in, "auto")
    ang_err = wrap_to_pi(auto_rad - rad_in).abs().max().item()
    expect(ang_err < 1e-6,
           f"auto 正确放行 rad（角度误差 {ang_err:.2e} rad，用 wrap 差而非 allclose）")

    # ⑦ 训练损失可反传
    feat.requires_grad_(True)
    loss = head.loss(feat, torch.rand(B) * 2 * torch.pi, camera_heading=torch.rand(B) * 2 * torch.pi)
    loss.backward()
    expect(torch.isfinite(loss).item() and feat.grad is not None
           and torch.isfinite(feat.grad).all(), "loss 可反传且梯度 finite")

    # ⑧ NaN 防护
    nan_cam = torch.tensor([float("nan")])
    car_nan = head(zero_feat, nan_cam)
    expect(torch.isfinite(car_nan).all(), "NaN camera → 输出仍 finite（nan_to_num 兜底）")

    # ⑨ [B,1] 形状的 camera_heading 容忍
    car_b1 = head(feat, torch.rand(B, 1) * 2 * torch.pi)
    expect(car_b1.shape == (B,), "camera_heading [B,1] 自动 squeeze")

    # ⑩ 导出友好：全 None 之外的空 batch 不崩
    car_empty = head(torch.zeros(0, C), None)
    expect(car_empty.shape == (0,), "空 batch 前向不崩（shape (0,)）")

    return ok


if __name__ == "__main__":
    print("=== HeadingHead 自检 ===")
    ok = self_check(verbose=True)
    print("=== 结果:", "全部通过 ✅" if ok else "有失败 ❌", "===")
    raise SystemExit(0 if ok else 1)
