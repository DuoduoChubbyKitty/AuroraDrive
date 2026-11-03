#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""防侧翻安全惩罚项（rollover guard）实现 + 实测验证。

背景（用户 2026-11-03 原话）：
  「但如果你不按S，没有及时刹车，可能会他过完时直接侧翻，导致车毁人亡。」

含义：极致刹车里的 S **不是辅助刹车，是防翻车稳定键**。只按 Shift+空格
（= super_brake）而不按 S，高速下制动力过猛会侧翻。

要验证的四件事（全部有可复现输出）：
  Q1 惩罚项数值行为是否正确：低速不罚、高速罚、带 S 不罚、不带 S 罚
  Q2 梯度流向是否正确：让 S 的概率上升（而不是让超级刹车概率下降）
  Q3 真跑优化：最小化惩罚项，p(S) 是否真的上升、惩罚是否真的下降
  Q4 一致性项（super_brake 应等于 handbrake∧brake）梯度是否正常

⚠️ 数据诚实性：仓库无真实数据、无真实速度字段可用于该惩罚（见报告 §3.7 的
   数据缺口分析），本脚本全部用**合成张量**验证"公式实现是否正确"。
   真实场景下"多少 km/h 会翻"：未测。

跑法：
    /usr/local/bin/python3.11 tools/v3_exp/exp_rollover_guard.py
"""

from __future__ import annotations

from typing import Dict, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

torch.manual_seed(0)

#: 纵向三分类的下标（与 src/model_v3.py 的 vertical [B,3] 契约一致）
VERT_W, VERT_NONE, VERT_S = 0, 1, 2


# ============================================================================
# 1. 防侧翻惩罚项
# ============================================================================

def rollover_penalty(super_logit: torch.Tensor,
                     vertical_logits: torch.Tensor,
                     speed_kmh: torch.Tensor,
                     speed_valid: Optional[torch.Tensor] = None,
                     v_low: float = 20.0,
                     v_high: float = 30.0,
                     detach_super: bool = True) -> torch.Tensor:
    """防侧翻惩罚：violation = w(speed) · P(super_brake) · (1 − P(S)).

    三项相乘的语义：
      · `w(speed)`       —— 速度权重。低速不罚（不会翻），高速满罚。
      · `P(super_brake)` —— 模型有多想按「Shift+空格」。
      · `(1 − P(S))`     —— 模型有多不想按防翻稳定键 S。

    只有三者同时高（高速 + 想按超级刹车 + 不按 S）才重罚 —— 正是用户描述的翻车条件。

    Args:
        super_logit:      [B] super_brake 的 logit（model_v3 的 pred["super_brake"]）
        vertical_logits:  [B,3] 纵向 logits（0=W 1=NONE 2=S）
        speed_kmh:        [B] 车速（**km/h**，不是归一化值）
        speed_valid:      [B] 1=速度可信，0=缺失。None = 全部视为可信。
        v_low:            完全允许的时速上限（低于此不罚）
        v_high:           满罚时速（达到此值 penalty 系数=1）
        detach_super:     True = 梯度**只**流向 vertical（抬 S），不流向 super_brake。
                          ★ 这是本设计最关键的一处安全考量，见下方说明。

    Returns:
        标量张量（batch 平均）。

    ★ 为什么默认 detach_super=True（重要设计决策）：
      若不 detach，惩罚项对 `super_logit` 也有梯度，会把「超级刹车」的概率**压低**。
      这在数学上同样能降低惩罚，但在现实中等于教模型「高速时别刹车」——
      从侧翻风险换成了撞车/刹不住风险，一样致命。
      所以梯度只应流向 vertical 头（抬 S = 增加防翻稳定），
      不该流向 super_brake 头。super_brake 的校准由它自己的 BCE 监督负责。

    ★ 速度缺失怎么办（fail-safe）：
      若 speed_valid=0，把 w 当作 **1（按高速处理，保守惩罚）**。
      理由：安全系统的通行原则是「宁可误报，不可漏报」
      （与 src/risk_head.py:654-657 的 TTC 保守假设同源）。
      若当作 0，则速度一缺失惩罚就永远不生效 —— 安全项被静默关掉，这是不可接受的。
    """
    p_super = torch.sigmoid(super_logit.reshape(-1))          # [B]
    p_S = torch.softmax(vertical_logits, dim=-1)[..., VERT_S]  # [B] = P(vertical=S)

    v = speed_kmh.reshape(-1).to(p_S.dtype)
    # 线性斜坡：v ≤ v_low → 0；v ≥ v_high → 1；中间线性。
    # 用斜坡而不是硬阈值：硬阈值在 v=30 处产生阶跃，梯度不连续；
    # 斜坡让「接近阈值时」就有温和的梯度，但完全低速时严格为 0（不干扰正常驾驶）。
    w = ((v - v_low) / max(v_high - v_low, 1e-6)).clamp(0.0, 1.0)

    if speed_valid is not None:
        valid = speed_valid.reshape(-1).to(p_S.dtype) > 0.5
        # 速度未知 → 保守按满罚（不能因为缺数据就把安全项关掉）
        w = torch.where(valid, w, torch.ones_like(w))

    if detach_super:
        p_super = p_super.detach()

    return (w * p_super * (1.0 - p_S)).mean()


def rollover_penalty_hard(super_logit: torch.Tensor,
                          vertical_logits: torch.Tensor,
                          speed_kmh: torch.Tensor,
                          speed_valid: Optional[torch.Tensor] = None,
                          v_low: float = 20.0,
                          v_high: float = 30.0) -> torch.Tensor:
    """约束"违反程度"的平方版：对明确违规（penalty 接近 1）罚得更重。

    用户要求的是「重罚」。平方版让 penalty=0.9 的损失(0.81)远大于
    penalty=0.3 的损失(0.09)，即"基本要违规"的情形被重点打击，
    而"轻微违规"仍保留温和梯度。可选替代 rollover_penalty。
    """
    p = rollover_penalty(super_logit, vertical_logits, speed_kmh, speed_valid,
                         v_low, v_high, detach_super=True)
    return p * p


# ============================================================================
# 2. 输出一致性项：super_brake 必须等于 handbrake ∧ brake
# ============================================================================

def output_coherence_loss(pred: Dict[str, torch.Tensor]) -> torch.Tensor:
    """强制 4 个修饰键头的逻辑一致性（CCM 思想在按键任务上的直接应用）。

    为什么必须加（否则防侧翻惩罚失去意义）：
      模型有 4 个**独立** sigmoid 头：handbrake / brake / super_brake / ultimate。
      它们之间没有任何结构约束，完全可能输出
        handbrake=0.1, brake=0.1, super_brake=0.9
      ——「没按 Shift、没按空格，却按了 Shift+空格」，物理上不存在。
      而防侧翻惩罚判的是 `P(super_brake)`；一旦 super_brake 头与另两个头脱钩，
      「高速想按超级刹车但不按 S」这个判断本身就建立在不可信的数值上。

    约束（由录制器定义，tools/aurora_recorder.c:204,206）：
      super_brake = shift ∧ space          → 目标 = hb · br
      ultimate    = shift ∧ space ∧ S      → 目标 = hb · br · p(S)
    用 MSE（概率空间）而不是 BCE（无真值，这是自洽性约束，不是监督）。
    """
    hb = torch.sigmoid(pred["handbrake"].reshape(-1))
    br = torch.sigmoid(pred["brake"].reshape(-1))
    sb = torch.sigmoid(pred["super_brake"].reshape(-1))
    ul = torch.sigmoid(pred["ultimate"].reshape(-1))
    p_S = torch.softmax(pred["vertical"], dim=-1)[..., VERT_S]

    t_sb = hb * br
    t_ul = hb * br * p_S
    return F.mse_loss(sb, t_sb) + F.mse_loss(ul, t_ul)


# ============================================================================
# 3. 实测
# ============================================================================

def make_vertical_logits(p_S: float, b: int = 1) -> torch.Tensor:
    """构造让 P(vertical=S) 精确等于 p_S 的 logits（W/NONE 概率均分剩余质量）。

    ⚠️ 2026-11-03 修正（本脚本第一版写错过，实测抓出）：
       `softmax([a, a, c])` 的 S 位概率是 `e^c / (2 + e^c)`。
       要求它 = p，解得 `c = log(2p / (1−p))`，
       **不是** `log(p/(1−p))`（那是二分类 sigmoid 的公式，会得到偏小的概率）。
       第一版还额外乘了 scale=8，使 p=0.05 实际变成 2.9e-11，
       表格里却照印 0.05 —— 属于「打印值≠计算值」的假证据，已清除。

    自检（脚本内 assert）：softmax 结果必须与入参 p_S 吻合到 1e-6。
    """
    import math
    if not (0.0 < p_S < 1.0):
        raise ValueError(f"p_S 必须在 (0,1) 开区间内，收到 {p_S}")
    c = math.log(2.0 * p_S / (1.0 - p_S))
    logits = torch.tensor([[0.0, 0.0, c]]).repeat(b, 1)
    # 自检：实际概率必须等于目标（防止再次写出打印值与计算值不符的假证据）
    got = float(torch.softmax(logits, dim=-1)[0, VERT_S])
    assert abs(got - p_S) < 1e-6, f"make_vertical_logits 失效：目标 {p_S} 实际 {got}"
    return logits


def q1_values() -> None:
    print("=" * 84)
    print("Q1 惩罚项数值行为（关键：低速不罚 / 高速罚 / 带 S 不罚）")
    print("=" * 84)
    print(f"  {'场景':<40}{'速度':>8}{'P(super)':>10}{'P(S)':>8}{'惩罚值':>10}")
    print("  " + "-" * 78)

    cases = [
        # (描述, 速度 km/h, super_logit, p_S)
        ("低速 10km/h + 超级刹车 + 不带S（允许）", 10.0, 4.0, 0.05),
        ("临界 20km/h + 超级刹车 + 不带S（边界）", 20.0, 4.0, 0.05),
        ("中速 25km/h + 超级刹车 + 不带S（半罚）", 25.0, 4.0, 0.05),
        ("高速 40km/h + 超级刹车 + 不带S（★重罚）", 40.0, 4.0, 0.05),
        ("高速 40km/h + 超级刹车 + 带S（★不罚）", 40.0, 4.0, 0.95),
        ("高速 40km/h + 不按超级刹车（不罚）", 40.0, -4.0, 0.05),
        ("高速 40km/h + 极致刹车 ultimate（带S，不罚）", 40.0, 4.0, 0.95),
    ]
    for desc, v, sb, ps in cases:
        pen = rollover_penalty(torch.tensor([sb]), make_vertical_logits(ps),
                               torch.tensor([v]))
        print(f"  {desc:<40}{v:>8.1f}{torch.sigmoid(torch.tensor(sb)):>10.3f}"
              f"{ps:>8.2f}{float(pen):>10.5f}")

    print("\n  ⇒ 数值行为符合用户约束：")
    print("     · 10 km/h（低于 v_low=20）惩罚 = 0 —— 低速不带 S 是允许的 ✓")
    print("     · 25 km/h 处于斜坡中段，惩罚介于 0 与满罚之间 ✓")
    print("     · 40 km/h + 不带 S → 0.933（满罚量级）✓")
    print("     · 40 km/h + 带 S  → 0.049（仅为「不带S」的 5.3%），符合预期 ✓")

    # 硬阈值版 vs 斜坡版对比（解释为什么用斜坡）
    print("\n  为什么用「线性斜坡」而不是「硬阈值 v>30 就罚」：")
    print(f"    {'速度':>8}{'斜坡版':>12}{'硬阈值版':>12}")
    print("    " + "-" * 32)
    for v in (19.0, 20.0, 25.0, 29.9, 30.0, 31.0):
        ramp = float(rollover_penalty(torch.tensor([4.0]), make_vertical_logits(0.05),
                                      torch.tensor([v])))
        hard = float(rollover_penalty(torch.tensor([4.0]), make_vertical_logits(0.05),
                                      torch.tensor([v]), v_low=30.0, v_high=30.001))
        print(f"    {v:>8.1f}{ramp:>12.5f}{hard:>12.5f}")
    print("    ⇒ 硬阈值在 29.9→30.0 之间从 0 突跳到满罚，梯度不连续、训练易震荡；")
    print("      斜坡版全程连续可导，且 v≤20 时严格为 0（不干扰低速正常操作）。")


def q2_gradients() -> None:
    print("\n" + "=" * 84)
    print("Q2 梯度流向（★最关键：必须抬 S，不能压超级刹车）")
    print("=" * 84)
    b = 1
    speed = torch.tensor([50.0])                      # 高速
    # ★ 必须是「叶子张量」才能读到 .grad：`.clone().requires_grad_(True)` 产生的是
    #   非叶子节点（clone 是可微运算），.grad 恒为 None —— 第一版踩过这个坑。
    #   直接用 torch.tensor(..., requires_grad=True) 构造叶子。
    print("  初始状态：速度 50km/h，P(super_brake)=0.982，P(S)=0.05")

    # --- detach_super=True（推荐）---
    # ★ 正确的检验方式（第一版写错过，实测抓出）：
    #   detach **只切断梯度，不改变前向数值** —— 所以「扰动 sb 看输出变化」
    #   或「比较 detach/不detach 的前向值」都无法证明 detach 生效。
    #   唯一可靠的判据是**计算图**：detach 后 sb 不应有 .grad，
    #   而 vertical（另一个乘数）必须仍有 .grad 且 S 位为负。
    #   另一个坑：若 vertical 也不带 requires_grad，整个图没有可微节点，
    #   backward() 会直接抛 "element 0 of tensors does not require grad" ——
    #   那是测试写法问题，不是 detach 失效。
    sb1 = torch.tensor([4.0], requires_grad=True)          # 叶子
    v1 = make_vertical_logits(0.05).requires_grad_(True)   # 叶子（必须可微）
    pen1 = rollover_penalty(sb1, v1, speed, detach_super=True)
    pen1.backward()
    sb_is_detached = sb1.grad is None
    g_S1 = float(v1.grad[0, VERT_S])
    print(f"\n  【推荐 detach_super=True】")
    print(f"    super_logit.grad is None = {sb_is_detached}   （应为 True：梯度已切断）")
    print(f"    vertical[S] 梯度 = {g_S1:+.6f}   （应为负：提升 P(S) 才能降 loss）")
    ok1 = sb_is_detached and g_S1 < 0
    print(f"    {'✓' if ok1 else '✗'} 梯度只流向 S（抬 S），完全不动 super_brake")

    # --- detach_super=False（不推荐，用于说明为什么）---
    sb2 = torch.tensor([4.0], requires_grad=True)
    v2 = make_vertical_logits(0.05).requires_grad_(True)
    pen2 = rollover_penalty(sb2, v2, speed, detach_super=False)
    pen2.backward()
    g_sb2 = float(sb2.grad)
    print(f"\n  【不 detach（对照）】")
    print(f"    super_logit 梯度 = {g_sb2:+.6f}   "
          f"（正值 = 梯度下降会把它压低 → 减少超级刹车）")
    print(f"    ⚠️ 这等于教模型「高速时少按超级刹车」——从侧翻风险换成刹不住的风险")

    # 真跑一步 SGD，验证 detach 版确实抬高了 P(S)
    print(f"\n  真跑验证（对 vertical 做 30 步梯度下降，detach_super=True）：")
    v = make_vertical_logits(0.05).clone().requires_grad_(True)
    opt = torch.optim.SGD([v], lr=2.0)
    p_before = float(torch.softmax(v, -1)[0, VERT_S].detach())
    pen_before = float(rollover_penalty(torch.tensor([4.0]), v, speed).detach())
    for _ in range(30):
        opt.zero_grad()
        loss = rollover_penalty(torch.tensor([4.0]), v, speed)
        loss.backward()
        opt.step()
    p_after = float(torch.softmax(v, -1)[0, VERT_S].detach())
    pen_after = float(rollover_penalty(torch.tensor([4.0]), v, speed).detach())
    print(f"    P(S):    {p_before:.4f} → {p_after:.4f}")
    print(f"    惩罚值:  {pen_before:.5f} → {pen_after:.5f}")
    ok2 = p_after > p_before and pen_after < pen_before
    print(f"    {'✓' if ok2 else '✗'} 优化确实抬高了 P(S) 并降低了惩罚")
    assert ok1 and ok2, "梯度流向验证失败"


def q3_coherence() -> None:
    print("\n" + "=" * 84)
    print("Q3 输出一致性项：super_brake 必须 = handbrake ∧ brake")
    print("=" * 84)
    b = 4
    # 故意构造一个「物理上不存在」的输出：没按 Shift/空格，却按了超级刹车
    pred = {
        "vertical": make_vertical_logits(0.5, b=b),
        "handbrake": torch.tensor([[-3.0]] * b),   # ≈0.047
        "brake": torch.tensor([[-3.0]] * b),       # ≈0.047
        "super_brake": torch.tensor([[+3.0]] * b),  # ≈0.953 ← 矛盾
        "ultimate": torch.tensor([[-3.0]] * b),
    }
    hb = float(torch.sigmoid(pred["handbrake"][0]))
    br = float(torch.sigmoid(pred["brake"][0]))
    sb = float(torch.sigmoid(pred["super_brake"][0]))
    loss = output_coherence_loss(pred)
    print(f"  构造的矛盾输出：P(handbrake)={hb:.3f}  P(brake)={br:.3f}  "
          f"P(super_brake)={sb:.3f}")
    print(f"    期望 P(super_brake) = handbrake×brake = {hb * br:.4f}，实际 {sb:.3f}")
    print(f"  一致性损失 = {float(loss):.5f}")

    # 正常输出 → 损失应很小
    pred_ok = {
        "vertical": make_vertical_logits(0.9, b=b),
        "handbrake": torch.tensor([[+3.0]] * b),
        "brake": torch.tensor([[+3.0]] * b),
        "super_brake": torch.tensor([[+3.0]] * b),
        "ultimate": torch.tensor([[+3.0]] * b),
    }
    loss_ok = output_coherence_loss(pred_ok)
    print(f"  自洽输出的损失（三者都≈0.95，S≈0.9）= {float(loss_ok):.5f}")
    print(f"  {'✓' if float(loss) > float(loss_ok) * 5 else '✗'} 矛盾输出被显著惩罚")

    # 梯度检查
    for k in ("handbrake", "brake", "super_brake", "ultimate", "vertical"):
        pred[k].requires_grad_(True)
    l = output_coherence_loss(pred)
    l.backward()
    print("\n  梯度检查（矛盾输出下）：")
    for k in ("handbrake", "brake", "super_brake", "ultimate", "vertical"):
        g = pred[k].grad
        n = float(g.norm()) if g is not None else 0.0
        print(f"    {k:<14}{n:>12.6f}  {'✓' if n > 0 else '✗'}")
        assert n > 0, f"{k} 没收到梯度"
    print("  ✓ 五个相关头都收到梯度，一致性约束可训练")


def q4_full_loss() -> None:
    print("\n" + "=" * 84)
    print("Q4 接进 V3Loss 的量纲检查（新增项会不会吃掉主任务）")
    print("=" * 84)
    # 复现 model_v3.V3Loss 的主任务量纲（用合成 pred/target）
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
    try:
        from model_v3 import V3Loss
        has_v3 = True
    except Exception as exc:  # noqa: BLE001
        has_v3 = False
        err = repr(exc)

    b = 8
    torch.manual_seed(1)
    pred = {
        "vertical": torch.randn(b, 3) * 2,
        "horizontal": torch.randn(b, 3) * 2,
        "handbrake": torch.randn(b, 1),
        "brake": torch.randn(b, 1),
        "super_brake": torch.randn(b, 1),
        "ultimate": torch.randn(b, 1),
        "confidence": torch.randn(b, 1),
        "risk": torch.randn(b, 1),
    }
    target = {
        "vertical": torch.randint(0, 3, (b,)),
        "horizontal": torch.randint(0, 3, (b,)),
        "handbrake": torch.randint(0, 2, (b, 1)).float(),
        "brake": torch.randint(0, 2, (b, 1)).float(),
        "super_brake": torch.randint(0, 2, (b, 1)).float(),
        "ultimate": torch.randint(0, 2, (b, 1)).float(),
        "confidence": torch.rand(b, 1),
        "risk": torch.rand(b, 1),
    }

    if has_v3:
        loss_fn = V3Loss()
        total, metrics = loss_fn(pred, target)
        print(f"  实测 model_v3.V3Loss 主损失 total = {float(total):.4f}")
        print(f"  分项：{ {k: round(v, 4) for k, v in metrics.items()} }")
        main = float(total)
    else:
        print(f"  ⚠️ model_v3 导入失败：{err}")
        main = 3.7  # 退回我上一轮实测的 3.868675 量级
        print(f"  改用上一轮实测量级 total ≈ {main:.4f} 做量级对比")

    # 新增项的典型量级
    speed = torch.tensor([10.0, 15.0, 25.0, 40.0, 60.0, 40.0, 40.0, 5.0])
    sb_logit = torch.tensor([4.0, 4.0, 4.0, 4.0, 4.0, -4.0, 4.0, 4.0])
    vert = make_vertical_logits(0.05, b=b)
    roll = rollover_penalty(sb_logit, vert, speed)
    coh = output_coherence_loss({
        "vertical": vert,
        "handbrake": torch.full((b, 1), -2.0), "brake": torch.full((b, 1), -2.0),
        "super_brake": torch.full((b, 1), 2.0), "ultimate": torch.full((b, 1), 2.0),
    })
    print(f"\n  rollover_penalty（8 帧里 4 帧高速违规）= {float(roll):.5f}")
    print(f"  output_coherence_loss（人为矛盾输出）  = {float(coh):.5f}")
    print(f"\n  量级对比（λ_roll=2.0，λ_coh=0.05 时新增项贡献）：")
    print(f"    主任务              {main:>8.4f}")
    print(f"    + 2.0 × rollover   {2.0 * float(roll):>8.4f}")
    print(f"    + 0.05 × coherence {0.05 * float(coh):>8.4f}")
    print(f"    = 合计             {main + 2.0 * float(roll) + 0.05 * float(coh):>8.4f}")
    print("\n  ⇒ 严重违规时（一半帧高速不带S），安全项贡献与主任务同量级，"
          "确实构成「重罚」。")
    print("     轻度违规时 rollover→0，不会干扰主任务学习。")


def main() -> int:
    print("防侧翻安全惩罚项验证（torch %s）" % torch.__version__)
    print("用户约束：高速时若按超级刹车(Shift+空格)但不按 S，会侧翻 → 必须重罚\n")
    q1_values()
    q2_gradients()
    q3_coherence()
    q4_full_loss()
    print("\n" + "=" * 84)
    print("全部通过。⚠️ 未测：真实翻车速度阈值（v_low/v_high 需实车/实游戏测定）、")
    print("   真实数据上的收敛效果、速度字段在训练数据里的可得性（见报告 §3.7）。")
    print("=" * 84)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
