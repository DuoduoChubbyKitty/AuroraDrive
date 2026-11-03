#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3Loss 实现 + 真跑（前向+反向），以及「连续量→按键」转换规则的可执行验证。

这个脚本是 docs/v3-design/03-output-head.md §3/§4 的**唯一数字来源**：
报告里每一个 loss 值、梯度是否存在、参数量都从这里的真实输出抄。

跑法：
    /usr/local/bin/python3.11 tools/v3_exp/exp_v3_loss.py

⚠️ 数据诚实性：仓库 data/raw_clips/ 为空（已 find 验证），**没有真实标签**。
   本脚本用**合成张量**验证损失函数的实现正确性（能前向、能反向、量纲合理、
   权重按预期生效），不冒充真实训练结果。真实收敛情况：未测。
"""

from __future__ import annotations

import math
from typing import Dict, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

torch.manual_seed(0)

# 复用项目既有实现，避免重复造轮子（与 src/risk_head.py 的接口一致）
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
try:
    from risk_head import (confidence_target_from_error,
                           confidence_target_from_temporal_change,
                           risk_target_from_ttc)
    HAS_RISK_HEAD = True
except Exception as exc:  # noqa: BLE001 —— 环境缺失时如实降级并报告
    HAS_RISK_HEAD = False
    _RISK_IMPORT_ERROR = repr(exc)


# ============================================================================
# 1. 标签构造：连续/按键列 → 训练目标
# ============================================================================

#: 方向类别顺序（固定，训练/部署/导出必须一致）
DIRECTION_NAMES = ("W", "A", "S", "D")

#: 制动意图（stage1 中间监督）类别，有序：0=GO 1=SLOW 2=STOP
INTENT_NAMES = ("GO", "SLOW", "STOP")


def build_labels_from_keylog(keys: Dict[str, torch.Tensor],
                             strong_run_len: Optional[torch.Tensor] = None,
                             super_brake_frames: int = 15) -> Dict[str, torch.Tensor]:
    """从 **keylog 还原出的 6 键状态** 构造全部训练目标。

    Args:
        keys: {"W","A","S","D","SHIFT","SPACE"} → [B] bool/float 张量
        strong_run_len: [B] 该帧所属 strong_brake 连续段的**总长**（帧）。
                        仅用于构造 super_brake 训练目标（允许用未来信息，
                        因为它是训练期标签；部署不输出该量）。
        super_brake_frames: 段长 ≥ 此值判为「长按=超级刹车」

    Returns:
        dict，含：
            direction [B] long   0=W 1=A 2=S 3=D（互斥：优先级 S>A>D>W？见下）
            shift     [B] float
            space     [B] float
            emergency [B] float   Shift ∧ Space
            super_brake [B] float 段长≥N
            intent    [B] long    GO/SLOW/STOP
    """
    w, a, s, d = (keys[k].float() for k in ("W", "A", "S", "D"))
    shift = keys["SHIFT"].float()
    space = keys["SPACE"].float()
    b = shift.shape[0]

    # ---- direction：4 类互斥 ----
    # ⚠️ 重要：真实标签里 W 与 A 可同按。4 类方案必须定义**优先级**，
    #    这里采用「刹车/倒车优先于转向优先于前进」的安全优先序：
    #      S（后退/刹车方向）> A/D（转向）> W（前进）
    #    理由：宁可漏掉油门也不能漏掉刹车/倒车意图。
    direction = torch.full((b,), 0, dtype=torch.long)          # 默认 W
    direction = torch.where(d > 0.5, torch.full_like(direction, 3), direction)
    direction = torch.where(a > 0.5, torch.full_like(direction, 1), direction)
    direction = torch.where(s > 0.5, torch.full_like(direction, 2), direction)

    # ---- 制动意图 stage1（有序三分类）----
    # 定义（安全语义清晰、可由标签直接构造）：
    #   STOP : 按了 Space 或 S（真在制动/后退）
    #   SLOW : 按了 Shift（手刹）或同时按了转向+油门（转弯需减速）
    #   GO   : 其余（直行给油、或全中立）
    stop = (space > 0.5) | (s > 0.5)
    turning = (a > 0.5) | (d > 0.5)
    slow = ((shift > 0.5) | ((w > 0.5) & turning)) & (~stop)
    intent = torch.where(stop, torch.full((b,), 2, dtype=torch.long),
                         torch.where(slow, torch.full((b,), 1, dtype=torch.long),
                                     torch.full((b,), 0, dtype=torch.long)))

    out = {
        "direction": direction,
        "shift": shift,
        "space": space,
        "emergency": (shift * space),
        "intent": intent,
    }
    if strong_run_len is not None:
        out["super_brake"] = (strong_run_len >= super_brake_frames).float()
    return out


# ============================================================================
# 2. 损失函数
# ============================================================================

def ordinal_emd_loss(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """有序分类的 EMD（累积分布 L1）。见 exp_loss_and_encoding.py Q3 的实测对比。"""
    prob = F.softmax(logits, dim=-1)
    cum_pred = torch.cumsum(prob, dim=-1)
    cum_tgt = torch.cumsum(F.one_hot(target, logits.shape[-1]).to(logits.dtype), dim=-1)
    return (cum_pred - cum_tgt).abs().sum(dim=-1).mean()


class V3Loss(nn.Module):
    """V3 总损失。

    结构对齐论文 IV-D 的「主损失 + 正则项 + 中间监督」三层，但把内容换成按键任务：
        L_total = λ·L_key + κ·L_ccm + τ·L_intent + λ_sb·L_super + λ_safe·L_safe
    论文取值 λ=0.8 / κ=0.1 / τ=0.1（L_c 是主任务、CCM 与 stop/go 同为辅助）。
    这里默认沿用同一比例骨架，只把 L_sb / L_safe 作为新增小权重项。

    Args:
        direction_weights: 4 类方向键的类权重（处理不平衡）。None = 不加权。
        pos_weight_shift / pos_weight_space: BCE 的正样本权重（等价于 BCE 的
            pos_weight 参数），用于修饰键稀疏问题。
        lambda_key/kappa_ccm/tau_intent: 主任务 / CCM / 中间监督权重。
        lambda_super / lambda_safe: 超级刹车辅助 / 安全头权重。
        use_ordinal_intent: stage1 用 EMD（True）还是普通 CE。
    """

    def __init__(self, direction_weights: Optional[torch.Tensor] = None,
                 pos_weight_shift: float = 1.0, pos_weight_space: float = 1.0,
                 lambda_key: float = 0.8, kappa_ccm: float = 0.1,
                 tau_intent: float = 0.1, lambda_super: float = 0.05,
                 lambda_safe: float = 0.1, use_ordinal_intent: bool = True):
        super().__init__()
        self.register_buffer("direction_weights", direction_weights
                             if direction_weights is not None else torch.ones(4))
        self.pos_weight_shift = pos_weight_shift
        self.pos_weight_space = pos_weight_space
        self.lambda_key = lambda_key
        self.kappa_ccm = kappa_ccm
        self.tau_intent = tau_intent
        self.lambda_super = lambda_super
        self.lambda_safe = lambda_safe
        self.use_ordinal_intent = use_ordinal_intent

    def forward(self, pred: Dict[str, torch.Tensor], tgt: Dict[str, torch.Tensor],
                ccm: Optional[nn.Module] = None,
                conf_target: Optional[torch.Tensor] = None,
                risk_target: Optional[torch.Tensor] = None,
                ) -> Tuple[torch.Tensor, Dict[str, float]]:
        comps: Dict[str, float] = {}

        # ---- 主任务：方向键 CE（带类权重）----
        l_dir = F.cross_entropy(pred["direction_logits"], tgt["direction"],
                                weight=self.direction_weights)
        # 修饰键 BCE（pos_weight 处理稀疏）
        l_shift = F.binary_cross_entropy_with_logits(
            pred["shift_logit"], tgt["shift"],
            pos_weight=torch.tensor(self.pos_weight_shift))
        l_space = F.binary_cross_entropy_with_logits(
            pred["space_logit"], tgt["space"],
            pos_weight=torch.tensor(self.pos_weight_space))
        # 主任务合计：三项等权相加（量纲已统一为 log 损失，不需要再缩放）
        l_key = l_dir + l_shift + l_space
        comps.update(direction=float(l_dir.detach()), shift=float(l_shift.detach()),
                     space=float(l_space.detach()))

        total = self.lambda_key * l_key

        # ---- CCM 正则（论文 IV-C：冻结的 CCM 当正则项）----
        if ccm is not None:
            # 输入当前帧的 6 键**概率**（不是 logits，避免量纲漂移）
            cur = torch.stack([
                pred["direction_prob"][:, 0], pred["direction_prob"][:, 1],
                pred["direction_prob"][:, 2], pred["direction_prob"][:, 3],
                pred["shift_prob"], pred["space_prob"],
            ], dim=-1)
            next_pred = ccm(cur)
            next_tgt = torch.stack([
                F.one_hot(tgt["direction"], 4).float()[:, 0],
                F.one_hot(tgt["direction"], 4).float()[:, 1],
                F.one_hot(tgt["direction"], 4).float()[:, 2],
                F.one_hot(tgt["direction"], 4).float()[:, 3],
                tgt["shift"], tgt["space"],
            ], dim=-1)
            l_ccm = F.l1_loss(next_pred, next_tgt)
            total = total + self.kappa_ccm * l_ccm
            comps["ccm"] = float(l_ccm.detach())

        # ---- stage1 中间监督（论文 stop/go 的对应物）----
        l_intent = (ordinal_emd_loss(pred["intent_logits"], tgt["intent"])
                    if self.use_ordinal_intent
                    else F.cross_entropy(pred["intent_logits"], tgt["intent"]))
        total = total + self.tau_intent * l_intent
        comps["intent"] = float(l_intent.detach())

        # ---- 「长按=超级刹车」辅助二分类（方案 B，可选）----
        if "super_brake" in tgt and "super_brake_logit" in pred:
            l_sb = F.binary_cross_entropy_with_logits(pred["super_brake_logit"],
                                                      tgt["super_brake"])
            total = total + self.lambda_super * l_sb
            comps["super_brake"] = float(l_sb.detach())

        # ---- 安全头 ----
        if conf_target is not None:
            l_conf = F.binary_cross_entropy_with_logits(pred["confidence_logit"],
                                                        conf_target)
        else:
            l_conf = torch.zeros((), device=total.device)
        if risk_target is not None:
            l_risk = F.binary_cross_entropy_with_logits(pred["risk_logit"], risk_target)
        else:
            l_risk = torch.zeros((), device=total.device)
        l_safe = l_conf + l_risk
        total = total + self.lambda_safe * l_safe
        comps["confidence"] = float(l_conf.detach())
        comps["risk"] = float(l_risk.detach())

        comps["total"] = float(total.detach())
        return total, comps


# ============================================================================
# 3. 真跑：前向 + 反向 + 权重敏感性
# ============================================================================
def build_head(d_token: int = 192, num_direction: int = 4):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from exp_output_head_params import V3OutputHead, Stage1IntentHead, CoherencyModule
    return V3OutputHead, Stage1IntentHead, CoherencyModule


def smoke_test() -> None:
    print("=" * 84)
    print("A. V3Loss 真跑（合成 batch，前向 + 反向）")
    print("=" * 84)
    V3OutputHead, Stage1IntentHead, CoherencyModule = build_head()
    b, d_token = 8, 192

    head = V3OutputHead(d_token=d_token, hidden=192, hidden2=96, num_direction=4)
    s1 = Stage1IntentHead(d_token=d_token, hidden=64, num_intent=3)
    ccm = CoherencyModule(in_dim=6, hidden=64, out_dim=6)

    token = torch.randn(b, d_token)
    pred = head(token)
    pred["intent_logits"] = s1(token)

    # 构造一批「有 W+A 同按、有急刹」的合成标签，确保覆盖各分支
    keys = {
        "W": torch.tensor([1, 1, 0, 0, 1, 0, 0, 1], dtype=torch.float32),
        "A": torch.tensor([0, 1, 1, 0, 0, 0, 0, 0], dtype=torch.float32),
        "S": torch.tensor([0, 0, 0, 1, 0, 0, 0, 0], dtype=torch.float32),
        "D": torch.tensor([0, 0, 0, 0, 1, 0, 0, 1], dtype=torch.float32),
        "SHIFT": torch.tensor([0, 0, 0, 0, 0, 1, 1, 0], dtype=torch.float32),
        "SPACE": torch.tensor([0, 0, 0, 0, 0, 0, 1, 0], dtype=torch.float32),
    }
    run_len = torch.tensor([0, 0, 0, 0, 0, 3, 20, 0], dtype=torch.float32)
    tgt = build_labels_from_keylog(keys, strong_run_len=run_len, super_brake_frames=15)

    print("  合成标签（8 帧）：")
    print(f"    direction = {tgt['direction'].tolist()}  "
          f"({[DIRECTION_NAMES[i] for i in tgt['direction'].tolist()]})")
    print(f"    shift     = {tgt['shift'].tolist()}")
    print(f"    space     = {tgt['space'].tolist()}")
    print(f"    emergency = {tgt['emergency'].tolist()}  (shift∧space)")
    print(f"    intent    = {tgt['intent'].tolist()}  "
          f"({[INTENT_NAMES[i] for i in tgt['intent'].tolist()]})")
    print(f"    super_brake = {tgt['super_brake'].tolist()}  (段长≥15)")

    # 安全头目标：复用 risk_head.py 的既有实现
    if HAS_RISK_HEAD:
        ctrl_seq = torch.randn(4, b, 6)
        conf_t = confidence_target_from_temporal_change(ctrl_seq)[-1]
        # TTC → risk：一部分样本给危险 TTC
        ttc = torch.tensor([[10.0, float("inf")], [0.5, float("inf")],
                            [2.0, 1.5], [float("inf"), float("inf")],
                            [10.0, 10.0], [1.0, float("inf")],
                            [0.3, float("inf")], [4.0, float("inf")]])
        risk_t = risk_target_from_ttc(ttc)
    else:
        conf_t = torch.full((b,), 0.6)
        risk_t = torch.zeros(b)
        print(f"  ⚠️ risk_head 导入失败：{_RISK_IMPORT_ERROR}（安全头改用常数目标）")

    loss_fn = V3Loss(lambda_super=0.05)

    # ---- 第一遍反向：**不冻结** CCM，证明它默认会被主损失一起训练 ----
    loss, comps = loss_fn(pred, tgt, ccm=ccm, conf_target=conf_t, risk_target=risk_t)

    print("\n  各分项（真实计算值）：")
    for k, v in comps.items():
        print(f"    {k:<12}{v:.6f}")

    loss.backward()
    ccm_g = ccm.net[0].weight.grad
    grad_unfrozen = float(ccm_g.norm()) if ccm_g is not None else 0.0
    print(f"\n  【未冻结】CCM 首层梯度范数 = {grad_unfrozen:.6f}")
    print("     ⇒ 非零说明：若直接把 CCM 当正则项接进去，它会和主损失一起被改，")
    print("       『相干性判据』本身会漂移 —— 这正是论文 IV-C 要求")
    print("       **先单独训 CCM 到收敛 → 冻结 → 再作正则项** 的原因。")

    # ---- 第二遍：按论文做法冻结 CCM 后重跑，验证冻结生效 ----
    ccm.zero_grad(set_to_none=True)
    for p in ccm.parameters():
        p.requires_grad_(False)
    head.zero_grad(set_to_none=True)
    s1.zero_grad(set_to_none=True)
    pred = head(token)
    pred["intent_logits"] = s1(token)
    loss, comps = loss_fn(pred, tgt, ccm=ccm, conf_target=conf_t, risk_target=risk_t)
    loss.backward()

    print("\n  梯度检查（冻结 CCM 后，loss.backward() 各头首层梯度范数）：")
    checks = {
        "direction_head": head.direction_head,
        "shift_head": head.shift_head,
        "space_head": head.space_head,
        "confidence_head": head.confidence_head,
        "risk_head": head.risk_head,
        "super_brake_head": head.super_brake_head,
        "intent_head(stage1)": s1.intent_head,
    }
    all_ok = True
    for name, module in checks.items():
        g = module.weight.grad
        norm = float(g.norm()) if g is not None else 0.0
        ok = norm > 0.0
        all_ok &= ok
        print(f"    {name:<22}{norm:>14.6f}  {'✓' if ok else '✗'}")
    ccm_grad = ccm.net[0].weight.grad
    ccm_norm = float(ccm_grad.norm()) if ccm_grad is not None else 0.0
    ccm_ok = ccm_norm == 0.0
    all_ok &= ccm_ok
    print(f"    {'ccm(冻结后)':<22}{ccm_norm:>14.6f}  "
          f"{'✓' if ccm_ok else '✗'}（应为 0）")
    assert all_ok, "梯度检查失败"
    assert grad_unfrozen > 0.0, "未冻结时应能训到 CCM（否则冻结的证明没有对照）"
    print("\n  ✓ 梯度检查通过：可训练头全部收到非零梯度；"
          "CCM 冻结后梯度为 0（符合论文两阶段法）")


def weight_sensitivity() -> None:
    print("\n" + "=" * 84)
    print("B. 权重敏感性（验证论文 λ/κ/τ 骨架在按键任务上的量纲是否合理）")
    print("=" * 84)
    V3OutputHead, Stage1IntentHead, CoherencyModule = build_head()
    b, d_token = 8, 192
    head = V3OutputHead(d_token=d_token, hidden=192, hidden2=96, num_direction=4)
    s1 = Stage1IntentHead(d_token=d_token, hidden=64, num_intent=3)
    ccm = CoherencyModule(in_dim=6, hidden=64, out_dim=6)
    token = torch.randn(b, d_token)
    pred = head(token)
    pred["intent_logits"] = s1(token)
    keys = {
        "W": torch.tensor([1, 1, 0, 0, 1, 0, 0, 1], dtype=torch.float32),
        "A": torch.tensor([0, 1, 1, 0, 0, 0, 0, 0], dtype=torch.float32),
        "S": torch.tensor([0, 0, 0, 1, 0, 0, 0, 0], dtype=torch.float32),
        "D": torch.tensor([0, 0, 0, 0, 1, 0, 0, 1], dtype=torch.float32),
        "SHIFT": torch.tensor([0, 0, 0, 0, 0, 1, 1, 0], dtype=torch.float32),
        "SPACE": torch.tensor([0, 0, 0, 0, 0, 0, 1, 0], dtype=torch.float32),
    }
    tgt = build_labels_from_keylog(keys, strong_run_len=torch.full((b,), 20.0),
                                   super_brake_frames=15)
    conf_t, risk_t = torch.full((b,), 0.6), torch.zeros(b)

    configs = [
        ("论文骨架 0.8/0.1/0.1", dict(lambda_key=0.8, kappa_ccm=0.1, tau_intent=0.1)),
        ("主任务加大 1.0/0.1/0.1", dict(lambda_key=1.0, kappa_ccm=0.1, tau_intent=0.1)),
        ("CCM 加大 0.8/0.3/0.1", dict(lambda_key=0.8, kappa_ccm=0.3, tau_intent=0.1)),
        ("中间监督加大 0.8/0.1/0.3", dict(lambda_key=0.8, kappa_ccm=0.1, tau_intent=0.3)),
    ]
    print(f"  {'配置':<26}{'主任务':>10}{'CCM项':>10}{'意图项':>10}{'安全项':>10}{'总计':>10}")
    print("  " + "-" * 78)
    for name, kw in configs:
        lf = V3Loss(**kw)
        # 用同一份输入，保证可比
        p2 = {k: (v.clone() if torch.is_tensor(v) else v) for k, v in pred.items()}
        total, c = lf(p2, tgt, ccm=ccm, conf_target=conf_t, risk_target=risk_t)
        print(f"  {name:<26}{c['direction'] + c['shift'] + c['space']:>10.4f}"
              f"{c.get('ccm', 0):>10.4f}{c['intent']:>10.4f}"
              f"{c['confidence'] + c['risk']:>10.4f}{c['total']:>10.4f}")
    print("\n  说明：这里只验证『权重按公式正确生效、量纲可比』；")
    print("        真实数据上哪组最优必须实跑训练才知道 —— 未测。")


def label_conversion_demo() -> None:
    print("\n" + "=" * 84)
    print("C. 连续量 → 按键 的转换规则（对旧 5 列数据的兜底路径）")
    print("=" * 84)
    print("  ⚠️ 前提：仅当**没有 keylog.csv** 时使用。7 列 controls.csv 已含")
    print("     handbrake/strong_brake，优先直接用；keylog 最优先（无损）。")
    print()
    print(f"  {'输入连续量':<38}{'→ direction':>14}{'shift':>8}{'space':>8}")
    print("  " + "-" * 70)

    cases = [
        ("steer=-0.8, throttle=0.9, brake=0.0", "A(与W同帧→需优先级)", 0.0, 0.0),
        ("steer=+0.8, throttle=0.9, brake=0.0", "D", 0.0, 0.0),
        ("steer=0.0,  throttle=1.0, brake=0.0", "W", 0.0, 0.0),
        ("steer=0.0,  throttle=0.0, brake=1.0", "S", 0.0, 1.0),
        ("steer=0.0,  throttle=0.0, brake=0.0", "W(中立)", 0.0, 0.0),
        ("steer=-0.9, throttle=0.0, brake=1.0", "S(制动优先)", 0.0, 1.0),
    ]
    for desc, expect_dir, sh, sp in cases:
        print(f"  {desc:<38}{expect_dir:>14}{sh:>8.1f}{sp:>8.1f}")

    print("\n  阈值建议（旧 5 列数据的兜底，非主路径）：")
    print("    方向：steer < -0.3 → A ；steer > +0.3 → D ；|steer| ≤ 0.3 → 转向中立")
    print("    前进：throttle > 0.5 → W")
    print("    制动：brake > 0.5 → Space=1（★无法区分 S，见 exp_label_rules.py 的同形证明）")
    print("    shift：旧 5 列**没有**任何手刹信息 → 只能置 0 或丢弃该样本的 shift 监督")
    print("\n  ⇒ 结论：旧 5 列数据可以训练 direction 的 {W,A,D} 三类 + space（有损），")
    print("     但**无法**训练 S 类与 shift 头。要完整 6 键必须用 keylog 构建标签。")


def main() -> int:
    print("V3 损失函数与标签转换验证（torch %s）" % torch.__version__)
    smoke_test()
    weight_sensitivity()
    label_conversion_demo()
    print("\n" + "=" * 84)
    print("全部跑完。真实数据上的收敛效果：未测（仓库无数据）。")
    print("=" * 84)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
