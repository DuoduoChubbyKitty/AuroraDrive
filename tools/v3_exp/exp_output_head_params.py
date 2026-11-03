#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 输出头参数量实测 + forward shape 验证（纯本地计算，不联网）。

用途：为 docs/v3-design/03-output-head.md §2 提供**实测**参数量，而不是拍脑袋估算。

跑法：
    /usr/local/bin/python3.11 tools/v3_exp/exp_output_head_params.py

设计取舍（与 src/model_v2.py 的 FusionHead 保持一致）：
  · 主干用 Linear + ReLU + Dropout 堆叠，输出头各自独立 Linear
  · 初始化用 fan_in（model_v2.py:856-859 明确记录：fan_out 会让 tanh/sigmoid
    一上来就饱和、梯度归零，旧 model.py 踩过这个坑）
  · forward 同时返回 logits 与概率：BCEWithLogits/CE 用 logits 数值更稳，
    部署侧要概率，两边都要，不能只给一种（train_v2.py 的 V2Loss 就是吃
    preds["throttle_logit"] 的）
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F

#: V3 总参数预算（task-8/11 已确认 12M）
TOTAL_BUDGET = 12_000_000


def count_params(module: nn.Module) -> int:
    return sum(p.numel() for p in module.parameters())


class V3OutputHead(nn.Module):
    """方向键 + 修饰键 + 安全头。

    基线（用户已确认）：direction 4 类 softmax（W/A/S/D 互斥）、shift/space 各自 sigmoid。
    num_direction=5 时是「加 NONE 类」的扩展方案；num_direction=6 用于
    分解式方案（longitudinal 3 + lateral 3，见报告 §9 冲突讨论）。
    """

    def __init__(self, d_token: int = 128, hidden: int = 128, hidden2: int = 64,
                 num_direction: int = 4, dropout: float = 0.1,
                 enable_cooc_aux: bool = True):
        super().__init__()
        self.trunk1 = nn.Linear(d_token, hidden)
        self.dropout = nn.Dropout(dropout)
        self.trunk2 = nn.Linear(hidden, hidden2)

        self.direction_head = nn.Linear(hidden2, num_direction)
        self.shift_head = nn.Linear(hidden2, 1)
        self.space_head = nn.Linear(hidden2, 1)
        self.confidence_head = nn.Linear(hidden2, 1)
        self.risk_head = nn.Linear(hidden2, 1)
        # 可选：紧急刹车（Shift∧Space）显式辅助头。默认只用乘积监督（更省），
        # 这里留开关用于对比实验。
        self.emergency_head = nn.Linear(hidden2, 1) if enable_cooc_aux else None
        # 可选：「长按=超级刹车」辅助头（报告 §6 方案 B）
        self.super_brake_head = nn.Linear(hidden2, 1)

        self._init_weights()

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, mode="fan_in", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
        # 安全头 bias 偏置：与 src/risk_head.py:207-209 同款理由——
        # risk 初值≈0.1（别一上来就疯狂请求接管）、confidence 初值≈0.6
        with torch.no_grad():
            self.risk_head.bias.fill_(-2.1972245773362196)      # log(0.1/0.9)
            self.confidence_head.bias.fill_(0.4054651081081644)  # log(0.6/0.4)

    def forward(self, state_token: torch.Tensor) -> dict[str, torch.Tensor]:
        x = F.relu(self.trunk1(state_token))
        x = self.dropout(x)
        x = F.relu(self.trunk2(x))
        out = {
            "direction_logits": self.direction_head(x),
            "shift_logit": self.shift_head(x).squeeze(-1),
            "space_logit": self.space_head(x).squeeze(-1),
            "confidence_logit": self.confidence_head(x).squeeze(-1),
            "risk_logit": self.risk_head(x).squeeze(-1),
            "super_brake_logit": self.super_brake_head(x).squeeze(-1),
        }
        out["direction_prob"] = F.softmax(out["direction_logits"], dim=-1)
        out["shift_prob"] = torch.sigmoid(out["shift_logit"])
        out["space_prob"] = torch.sigmoid(out["space_logit"])
        out["confidence"] = torch.sigmoid(out["confidence_logit"])
        out["risk"] = torch.sigmoid(out["risk_logit"])
        if self.emergency_head is not None:
            out["emergency_logit"] = self.emergency_head(x).squeeze(-1)
        return out


class Stage1IntentHead(nn.Module):
    """stage1 制动意图头（GO/SLOW/STOP 三分类 + 序数 EMD）。

    论文 stage1 是 stop/go 中间阶段；我们把它的监督接到「制动意图」上，
    输出**只用于训练**（推理时不进部署契约），信息通过 state token 传播给 stage2
    —— 与论文一致（论文 stage1 的 stop/go 也是训练信号 + 状态 token 传播）。
    """

    def __init__(self, d_token: int = 128, hidden: int = 64, num_intent: int = 3):
        super().__init__()
        self.fc1 = nn.Linear(d_token, hidden)
        self.intent_head = nn.Linear(hidden, num_intent)
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, mode="fan_in", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, state_token: torch.Tensor) -> torch.Tensor:
        return self.intent_head(F.relu(self.fc1(state_token)))


class CoherencyModule(nn.Module):
    """CCM 的按键版：预测下一帧键状态（论文 §IV-C 的结构，换监督目标）。

    论文：输入 (steer,throttle,brake,speed)@t → 预测 speed@t+1，3 层 MLP + ELU，
    先单独训到收敛、冻结、再做正则项。
    这里：输入 当前 6 键概率(@t) [+ 速度(可选)] → 预测下一帧 6 键真值(@t+1)。
    不用速度也能训（本项目 speed 数据是否可用：未测），用得上速度时拼进去即可。
    """

    def __init__(self, in_dim: int = 6, hidden: int = 64, out_dim: int = 6):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_dim, hidden), nn.ELU(),
            nn.Linear(hidden, hidden), nn.ELU(),
            nn.Linear(hidden, out_dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


def verify_forward(head: nn.Module, d_token: int, num_direction: int) -> None:
    """真实跑一次 forward，打印每个输出的 shape —— 未跑过不许写进报告。"""
    head.eval()
    with torch.no_grad():
        token = torch.randn(2, d_token)
        out = head(token)
    print(f"  forward 实测（batch=2, d_token={d_token}）:")
    for k, v in out.items():
        print(f"    {k:<20}{tuple(v.shape)}")
    # 形状契约断言：与 task-11 的输出契约对齐
    assert out["direction_logits"].shape == (2, num_direction), "direction 形状不符"
    for k in ("shift_prob", "space_prob", "confidence", "risk"):
        assert out[k].shape == (2,), f"{k} 形状应为 [B]"
    assert bool(((out["direction_prob"].sum(dim=-1) - 1).abs() < 1e-5).all()), \
        "direction softmax 未归一化"
    print("  ✓ 形状契约全部通过")


def main() -> int:
    print("=" * 78)
    print("V3 输出头参数量实测（torch %s）" % torch.__version__)
    print("=" * 78)

    rows = []
    # ---- 主输出头：D(state token) × hidden 若干组合 ----
    for d_token in (128, 192):
        for hidden, hidden2 in ((128, 64), (192, 96)):
            for num_dir, tag in ((4, "基线4类"), (5, "加NONE5类"), (6, "分解3+3")):
                head = V3OutputHead(d_token=d_token, hidden=hidden, hidden2=hidden2,
                                    num_direction=num_dir)
                rows.append({
                    "组件": f"主输出头 {tag}",
                    "D": d_token, "hidden": hidden, "hidden2": hidden2,
                    "参数量": count_params(head),
                })

    # ---- stage1 制动意图头 ----
    for d_token in (128, 192):
        s1 = Stage1IntentHead(d_token=d_token, hidden=64, num_intent=3)
        rows.append({"组件": "stage1 制动意图头", "D": d_token,
                     "hidden": 64, "hidden2": "-", "参数量": count_params(s1)})

    # ---- CCM（冻结，训练期正则；不计入部署参数）----
    for in_dim in (6, 7):
        ccm = CoherencyModule(in_dim=in_dim, hidden=64, out_dim=6)
        rows.append({"组件": f"CCM 按键版(in={in_dim})", "D": "-",
                     "hidden": 64, "hidden2": "-", "参数量": count_params(ccm)})

    print(f"{'组件':<22}{'D':>5}{'hidden':>8}{'hidden2':>9}{'参数量':>10}")
    print("-" * 78)
    for r in rows:
        print(f"{r['组件']:<22}{str(r['D']):>5}{str(r['hidden']):>8}"
              f"{str(r['hidden2']):>9}{r['参数量']:>10,}")

    # ---- 推荐组合的总账 ----
    print("\n" + "=" * 78)
    print("推荐组合总账（D=192, hidden=192/96）")
    print("=" * 78)
    d_token = 192
    main_head = V3OutputHead(d_token=d_token, hidden=192, hidden2=96, num_direction=4)
    s1_head = Stage1IntentHead(d_token=d_token, hidden=64, num_intent=3)
    ccm = CoherencyModule(in_dim=7, hidden=64, out_dim=6)
    p_main, p_s1, p_ccm = count_params(main_head), count_params(s1_head), count_params(ccm)
    deploy = p_main
    print(f"  主输出头（进部署图）      {p_main:>9,}")
    print(f"  stage1 意图头（仅训练）    {p_s1:>9,}")
    print(f"  CCM（冻结，仅训练）        {p_ccm:>9,}")
    print(f"  ---")
    print(f"  部署新增合计              {deploy:>9,}"
          f"  = {100.0 * deploy / TOTAL_BUDGET:.3f}% of 12M")
    print(f"  训练期额外（不导出）      {p_s1 + p_ccm:>9,}"
          f"  = {100.0 * (p_s1 + p_ccm) / TOTAL_BUDGET:.3f}% of 12M")
    print(f"  剩余给 骨干/时序/融合     {TOTAL_BUDGET - p_main:>9,}")

    # ---- forward 实测 ----
    print("\n" + "=" * 78)
    print("forward 实测")
    print("=" * 78)
    verify_forward(V3OutputHead(d_token=192, hidden=192, hidden2=96, num_direction=4), 192, 4)

    # ---- 头占预算比例的敏感性：12M 预算下这些头是否值得担心 ----
    # 注：这里全部用**上面实测到的变量**，不写死任何数字（写死会与实际配置脱节）
    print(f"\n结论：推荐主输出头实测 {p_main:,} 参数，占 12M 预算的 "
          f"{100.0 * p_main / TOTAL_BUDGET:.3f}%，不构成预算压力；")
    print(f"      4 类 / 5 类 / 6 类三种方案之间仅差 "
          f"{(count_params(V3OutputHead(d_token=d_token, hidden=192, hidden2=96, num_direction=6)) - p_main):,} 参数，")
    print(f"      ⇒「方向键怎么编码」应完全按**建模正确性**决定，"
          f"不要用参数预算当理由。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
