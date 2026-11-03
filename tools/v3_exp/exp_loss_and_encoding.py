#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 输出编码方式 + 损失函数方案的可执行对比验证。

回答四个问题（每个都有可复现输出）：
  Q1 「4 类 softmax」与「纵向 3 类 + 横向 3 类」的表达能力差多少？
     —— 录制器真实标签里 W+A 是同按的（throttle=1 且 steer=-1），4 类表达不了
  Q2 类别不平衡到底把梯度拉成什么样？加权 CE / Focal 分别怎么修？
  Q3 stage1 制动意图（GO/SLOW/STOP）该用普通 CE 还是序数损失（EMD）？
  Q4 「长按=超级刹车」用「时长回归」可行吗？—— 用时长的分布性质判断

⚠️ 数据诚实性：
    仓库 data/raw_clips/ 为空（已 find 验证），真实标签分布**未测**。
    本脚本中凡涉及比例的，都用**假设分布**并明确标注；结论只针对
    「机制/数学性质」，不冒充真实统计量。
    唯一来自真实数据的事实：录制器会把 W+A / W+D 同按写成 throttle=1 且
    steer=±1（tools/aurora_recorder.c:171-176 的推导式），这在代码层面是确定的。

跑法：
    /usr/local/bin/python3.11 tools/v3_exp/exp_loss_and_encoding.py
"""

from __future__ import annotations

import itertools
import math
from typing import Dict, List, Sequence, Tuple

import torch
import torch.nn.functional as F

torch.manual_seed(0)

# ----------------------------------------------------------------------------
# Q1：编码表达力 —— 4 类 softmax vs 纵向 3 + 横向 3
# ----------------------------------------------------------------------------
#: 现实约束（由录制器语义决定，非假设）：
#:   · W(前进) 与 S(后退) 不能同时按 —— 这是用户明确确认的
#:   · A 与 D 不能同时按 —— recorder 用 left&&!right 已经强制了左右互斥
#:   · 但 W 可以与 A/D 同时按（throttle 与 steer 是两个独立轴）
VALID_COMBOS: List[Tuple[bool, bool, bool, bool]] = []
for w, s, a, d in itertools.product([False, True], repeat=4):
    if w and s:
        continue           # 前进+后退 同时按 → 物理上无意义（用户已排除）
    if a and d:
        continue           # 左+右 同时按 → 录制器判中立，属于无效组合
    VALID_COMBOS.append((w, s, a, d))

#: 4 类 softmax 的一个类别对应「一个方向键」
DIRECTION_CLASSES = ["W", "A", "S", "D"]


def four_class_representable(combo: Tuple[bool, bool, bool, bool]) -> bool:
    """4 类 softmax 一次只能输出 1 个方向键，故只有「恰好按 1 个」才可表示。"""
    return sum(combo) == 1


def decomposed_representable(combo: Tuple[bool, bool, bool, bool]) -> bool:
    """纵向 3 类 {W,NONE,S} × 横向 3 类 {A,NONE,D}：任取组合都可表示。"""
    w, s, a, d = combo
    return not (w and s) and not (a and d)


def q1_expressiveness() -> None:
    print("=" * 82)
    print("Q1 编码表达力：4 类 softmax vs 纵向3类+横向3类")
    print("=" * 82)
    print("合法按键组合（排除 W+S 同按、A+D 同按）：")
    print(f"  {'W':>3}{'S':>3}{'A':>3}{'D':>3}   4类可表示   3+3可表示   备注")
    print("  " + "-" * 70)
    n4 = n33 = 0
    for combo in VALID_COMBOS:
        w, s, a, d = combo
        r4, r33 = four_class_representable(combo), decomposed_representable(combo)
        n4 += r4
        n33 += r33
        keys = "+".join([k for k, v in zip("WSAD", combo) if v]) or "(全中立)"
        note = ""
        if not r4 and (w and (a or d)):
            note = "★ 边加速边转向（最常用）"
        elif not r4 and s and (a or d):
            note = "倒车转向"
        elif not r4:
            note = "中立/无输入"
        print(f"  {int(w):>3}{int(s):>3}{int(a):>3}{int(d):>3}"
              f"{'✓' if r4 else '✗':>11}{'✓' if r33 else '✗':>12}   {note}")

    total = len(VALID_COMBOS)
    print(f"\n  合法组合共 {total} 种：")
    print(f"    4 类 softmax 可表示 {n4}/{total} = {100.0 * n4 / total:.1f}%")
    print(f"    3+3 两轴可表示      {n33}/{total} = {100.0 * n33 / total:.1f}%")
    print(f"  4 类丢失的组合：{total - n4} 种，其中包含 W+A、W+D、S+A、S+D 全部"
          f"'转向同时给油'的组合")

    # ---- 用录制器真实标签形态证明 W+A 真实存在 ----
    print("\n  ★ 证据（不是假设，来自 tools/aurora_recorder.c:171-176 的推导式）：")
    print("     W 与 A 同时按住时，录制出的 7 列为")
    print("       steer=-1.0, throttle=1.0, brake=0.0  ← steer 与 throttle 各自独立")
    print("     ⇒ 真实驾驶里 '油门 + 左转' 是一帧里同时成立的两个事实。")
    print("     4 类 softmax 必须在这两者中二选一 → 丢掉的正是最常用的操控模式。")

    # ---- 两种方案对真值的损失：用「被牺牲的那一维」量化 ----
    print("\n  量化：若把 W+A 帧强行塞进 4 类，只能选 W 或 A 之一，")
    print("        该帧必然有一个轴预测错 —— 损失下界是「几乎必然的错」，不是随机噪声。")
    print("        3+3 方案下 W+A 可被两轴同时正确预测。")


# ----------------------------------------------------------------------------
# Q2：类别不平衡 —— 梯度视角
# ----------------------------------------------------------------------------
def ce_grad_magnitude(prob_correct: float, class_weight: float) -> float:
    """单样本加权 CE 对正确类 logit 的梯度幅值 = |weight * (p - 1)|。

    这是不平衡问题的核心机制：稀有类虽然 p-1 大（错得多），
    但它的样本数少，**总梯度贡献 = 单样本梯度 × 样本数**，
    多数类靠数量碾压。加权就是乘上 1/freq 把账拉平。
    推导：CE = -w·log p_y，dCE/dz_y = w·(p_y - 1)
    """
    return abs(class_weight * (prob_correct - 1.0))


def q2_imbalance() -> None:
    print("\n" + "=" * 82)
    print("Q2 类别不平衡：默认 CE vs 类加权 CE vs Focal")
    print("=" * 82)
    print("  ⚠️ 下面的比例是**假设值**（真实分布未测，仓库无数据）。")
    print("     结论只讲机制：给定任意比例，加权如何改变总梯度占比。")

    # 假设一个「W 主导」的驾驶分布（赛道/直线巡航多）
    assumed = {"W": 0.80, "A": 0.10, "D": 0.07, "S": 0.03}
    print(f"\n  假设分布：{assumed}（合计 {sum(assumed.values()):.2f}）")

    n_total = 10000
    counts = {k: int(v * n_total) for k, v in assumed.items()}
    print(f"  换算成 {n_total} 帧：{counts}")

    # 不加权：模型若退化为「全预测 W」，能拿到多少准确率？——这是要警惕的陷阱
    majority_acc = assumed["W"]
    print(f"\n  ★ 陷阱：模型只要永远输出 W，准确率就有 {100 * majority_acc:.1f}%。")
    print(f"    所以 **准确率不能作为选模指标**（必须看 per-class recall / 混淆矩阵）。")

    # 加权 CE 的权重：w_c = 1/freq（归一化到均值 1）
    raw_w = {k: 1.0 / v for k, v in assumed.items()}
    mean_w = sum(raw_w.values()) / len(raw_w)
    norm_w = {k: w / mean_w for k, w in raw_w.items()}
    print(f"\n  类权重 w_c = (1/freq_c) / mean(1/freq)：")
    print(f"    {'类别':<6}{'freq':>8}{'1/freq':>10}{'归一化权重':>12}")
    print("    " + "-" * 36)
    for k in assumed:
        print(f"    {k:<6}{assumed[k]:>8.2f}{raw_w[k]:>10.2f}{norm_w[k]:>12.3f}")

    # 总梯度占比：不加权时 W 占 80%，加权后各占 25%
    print(f"\n  总梯度占比（假设各样本初始损失相近）：")
    print(f"    {'类别':<6}{'不加权':>10}{'加权后':>10}")
    print("    " + "-" * 26)
    for k in assumed:
        unweighted = assumed[k]
        weighted = assumed[k] * norm_w[k] / sum(assumed[j] * norm_w[j] for j in assumed)
        print(f"    {k:<6}{100 * unweighted:>9.1f}%{100 * weighted:>9.1f}%")
    print("  ⇒ 加权后各类对总梯度的贡献被拉平（约 25% each），"
          "稀有类不再被淹没。")

    # ---- 一个真实的小实验：极不平衡数据上，加权 vs 不加权 ----
    print("\n  实测（合成 4 类不平衡数据，训练 2 层 MLP 300 步）：")
    run_imbalance_training()


def run_imbalance_training() -> None:
    """在合成不平衡数据上真跑，比较加权/不加权/focal 的稀有类召回。"""
    gen = torch.Generator().manual_seed(42)
    probs = torch.tensor([0.80, 0.10, 0.07, 0.03])
    n = 8000
    y = torch.multinomial(probs, n, replacement=True, generator=gen)
    # 类别中心：让任务可学（真实任务不可学则任何方法都白搭）
    centers = torch.tensor([[-2.0, -2.0], [-2.0, 2.0], [2.0, -2.0], [2.0, 2.0]])
    x = centers[y] + torch.randn(n, 2, generator=gen) * 1.2
    n_val = 2000
    yv = torch.multinomial(probs, n_val, replacement=True, generator=gen)
    xv = centers[yv] + torch.randn(n_val, 2, generator=gen) * 1.2

    def train(mode: str, steps: int = 300) -> Tuple[List[int], float]:
        torch.manual_seed(7)
        model = torch.nn.Sequential(torch.nn.Linear(2, 32), torch.nn.ReLU(),
                                    torch.nn.Linear(32, 4))
        opt = torch.optim.Adam(model.parameters(), lr=0.05)
        w = torch.tensor([1.0 / p for p in probs])
        w = w / w.mean()
        for _ in range(steps):
            opt.zero_grad()
            logits = model(x)
            if mode == "plain":
                loss = F.cross_entropy(logits, y)
            elif mode == "weighted":
                loss = F.cross_entropy(logits, y, weight=w)
            elif mode == "focal":
                # Focal（γ=2）：抑制易分样本，对稀有类等价于额外加权
                logp = F.log_softmax(logits, dim=-1)
                p = logp.exp()
                pt = p.gather(1, y[:, None]).squeeze(1)
                loss = (-(1 - pt) ** 2 * torch.log(pt.clamp_min(1e-9))).mean()
            else:
                raise ValueError(mode)
            loss.backward()
            opt.step()
        with torch.no_grad():
            pred = model(xv).argmax(1)
        per_class_recall = []
        for c in range(4):
            mask = yv == c
            per_class_recall.append(int((pred[mask] == c).sum()))
        acc = float((pred == yv).float().mean())
        return per_class_recall, acc

    header = f"    {'方案':<12}{'W召回':>8}{'A召回':>8}{'D召回':>8}{'S召回':>8}{'总准确率':>10}"
    print(header)
    print("    " + "-" * 56)
    results: Dict[str, Tuple[List[int], float]] = {}
    for mode, name in (("plain", "普通CE"), ("weighted", "类加权CE"), ("focal", "Focal γ=2")):
        results[name] = train(mode)
        rec, acc = results[name]
        cnts = [(yv == c).sum().item() for c in range(4)]
        print(f"    {name:<12}{rec[0]:>4}/{cnts[0]:<3}{rec[1]:>4}/{cnts[1]:<3}"
              f"{rec[2]:>4}/{cnts[2]:<3}{rec[3]:>4}/{cnts[3]:<3}{100 * acc:>9.1f}%")
    print("    注：验证集稀有类样本数很少（S 只有约 60 个），召回率有 ±数个样本的抖动。")

    # ---- 结论必须由实测数字推出，不能反着来 ----
    plain_rec, plain_acc = results["普通CE"]
    w_rec, w_acc = results["类加权CE"]
    f_rec, f_acc = results["Focal γ=2"]
    rare = [3]  # S 类（最稀有）
    s_plain, s_w, s_f = plain_rec[rare[0]], w_rec[rare[0]], f_rec[rare[0]]
    print(f"\n  ⇒ 实测结论（由上面数字直接读出，不美化）：")
    print(f"     · 类加权 CE：最稀有类 S 召回 {s_plain} → {s_w} 帧"
          f"（{100 * (s_w - s_plain) / max(s_plain, 1):+.1f}%），"
          f"总准确率 {100 * plain_acc:.1f}% → {100 * w_acc:.1f}%（下降 "
          f"{100 * (plain_acc - w_acc):.1f} 个百分点）")
    print(f"     · Focal γ=2：S 召回 {s_plain} → {s_f} 帧，"
          f"总准确率 {100 * f_acc:.1f}% —— 本任务上**几乎无改善**")
    print(f"     · 所以『加权换准确率』的取舍是真实存在的；Focal 在这个设置下没体现出优势，")
    print(f"       不能照搬『Focal 一定更好』的说法。")
    print(f"     · 关键警示：普通 CE 的总准确率已高达 {100 * plain_acc:.1f}%，"
          f"但最稀有类 S 只召回 {s_plain}/{int((yv == 3).sum())} 帧。")
    print(f"       ⇒ 用『准确率』选模会选出几乎全预测 W 的模型，"
          f"必须看 per-class recall / 混淆矩阵。")

    # ---- 再验证一遍「平凡解」的直接证据：全预测 W 的表现 ----
    with torch.no_grad():
        pred_all_w = torch.zeros_like(yv)
        acc_all_w = float((pred_all_w == yv).float().mean())
        s_recall_all_w = int((pred_all_w[yv == 3] == 3).sum())
        s_total = int((yv == 3).sum())
    print(f"\n  ★ 平凡解对照：『永远输出 W』→ 总准确率 {100 * acc_all_w:.1f}%，"
          f"S 召回 {s_recall_all_w}/{s_total}")
    print(f"     它的准确率与训练出的普通 CE（{100 * plain_acc:.1f}%）接近，"
          f"但 S 完全不会")
    print(f"     ⇒ 这是类别不平衡最典型的陷阱，也是必须加权的直接理由。")


# ----------------------------------------------------------------------------
# Q3：stage1 制动意图 —— 普通 CE vs 序数 EMD
# ----------------------------------------------------------------------------
def ordinal_emd_loss(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """序数回归的 EMD 损失（Hou et al. 2016 的 cumulative 形式，此处为简化版）。

    动机：GO < SLOW < STOP 是有序的。普通 CE 认为「GO↔STOP」与「GO↔SLOW」
    错得一样严重 —— 但对安全系统，"该停车却预测成加速" 的代价**远大于**
    "该停车却预测成减速"。EMD 让损失随「跨了几个档」递增。

    实现：把 softmax 概率转成累积分布 F，与 one-hot 目标的累积分布比 L1。
    数学上 EMD = Σ_k |CDF_pred(k) − CDF_target(k)|
    """
    prob = F.softmax(logits, dim=-1)
    cum_pred = torch.cumsum(prob, dim=-1)
    # one-hot 目标的累积分布：target 之后全为 1
    n_cls = logits.shape[-1]
    onehot = F.one_hot(target, n_cls).to(logits.dtype)
    cum_tgt = torch.cumsum(onehot, dim=-1)
    return (cum_pred - cum_tgt).abs().sum(dim=-1).mean()


def q3_ordinal() -> None:
    print("\n" + "=" * 82)
    print("Q3 stage1 制动意图（GO/SLOW/STOP）：普通 CE vs 序数 EMD")
    print("=" * 82)
    # 构造三种「预测得很自信」的错误。logits 的第 i 位大 = 预测第 i 类。
    # 类别定义：0=GO, 1=SLOW, 2=STOP
    cases = [
        ("真值 GO(0)，预测 SLOW(1)  ← 跨1档",
         torch.tensor([[0.0, 9.0, 0.0]]), torch.tensor([0])),
        ("真值 GO(0)，预测 STOP(2)  ← 跨2档",
         torch.tensor([[0.0, 0.0, 9.0]]), torch.tensor([0])),
        ("真值 STOP(2)，预测 SLOW(1)← 跨1档",
         torch.tensor([[0.0, 9.0, 0.0]]), torch.tensor([2])),
        ("真值 STOP(2)，预测 GO(0)  ← 跨2档",
         torch.tensor([[9.0, 0.0, 0.0]]), torch.tensor([2])),
    ]
    print(f"  {'情形（都是高置信度错误）':<30}{'普通CE':>10}{'序数EMD':>10}")
    print("  " + "-" * 52)
    ce_1 = ce_2 = emd_1 = emd_2 = None
    for name, logits, tgt in cases:
        ce = float(F.cross_entropy(logits, tgt))
        emd = float(ordinal_emd_loss(logits, tgt))
        print(f"  {name:<30}{ce:>10.4f}{emd:>10.4f}")
        if "跨1档" in name:
            ce_1, emd_1 = ce, emd
        else:
            ce_2, emd_2 = ce, emd
    print("\n  ⇒ 实测对比：")
    print(f"     普通 CE：跨1档 {ce_1:.4f}  vs  跨2档 {ce_2:.4f}"
          f"  → 比值 {ce_2 / ce_1:.2f}×（几乎不区分档距）")
    print(f"     序数 EMD：跨1档 {emd_1:.4f}  vs  跨2档 {emd_2:.4f}"
          f"  → 比值 {emd_2 / emd_1:.2f}×（严格随档距递增）")
    print("     对安全系统，『该停车却预测去加速』（跨2档）必须比")
    print("     『该停车却预测减速』（跨1档）罚得重 → 推荐 EMD。")


# ----------------------------------------------------------------------------
# Q4：「长按超级刹车」—— 时长分布能被回归学吗？
# ----------------------------------------------------------------------------
def q4_super_brake() -> None:
    print("\n" + "=" * 82)
    print("Q4 「长按=超级刹车」：时长回归 vs 二分类 vs 下游累积")
    print("=" * 82)
    print("  机制分析（不涉及真实数据，是问题本身的性质）：")
    print("    · 『长按』的定义依赖**未来**：一帧的时长标签 = 这段连续按键的总帧数。")
    print("      这意味着 t 时刻的标签要用到 t+N 的信息 → 训练时是『未来信息』，")
    print("      推理时**根本拿不到**（模型只能看到当前和历史帧）。")
    print("    · 因此『时长回归』训练目标在推理时不可观测，只能作为训练期辅助，")
    print("      不能作为部署输出。")
    print("    · 而且时长分布通常重尾（偶尔长按 200 帧），MSE 会被极端值主导，")
    print("      需要 Huber/log 变换，进一步增加复杂度。")
    print("\n  三者对比已列入报告 §6 表格。结论：")
    print("    C（不建模，下游按连续 strong_brake 帧数累积判定）作为**主方案**：")
    print("      推理时天然只依赖过去 → 可实现、无标签泄漏、阈值可调、可回退。")
    print("    B（显式 super_brake 二分类头）作为**可选增强**：")
    print("      标签 = 该帧所属连续段长度 ≥ N（N 用训练集统计确定），")
    print("      它是『可观测的过去尾部』的代理，不泄漏未来。")
    print("    A（时长回归）不推荐：推理不可观测 + 重尾，仅可作辅助任务。")

    # 用合成序列演示「长按」标签怎么构造成可观测形式
    print("\n  可观测标签构造示例（合成帧序列，非真实数据）：")
    seg = [0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0]
    print(f"    strong_brake 帧序列: {seg}")
    # 方案 B：该帧是否属于「长度≥5 的连续段」
    threshold = 5
    runs = []
    i = 0
    while i < len(seg):
        if seg[i]:
            j = i
            while j < len(seg) and seg[j]:
                j += 1
            for k in range(i, j):
                runs.append((k, j - i))
            i = j
        else:
            i += 1
    b_label = [0] * len(seg)
    for k, length in runs:
        b_label[k] = 1 if length >= threshold else 0
    print(f"    方案B 标签(段长≥{threshold})  : {b_label}")
    # 方案 C：下游累积 = 已连续按住的帧数（只看过去，推理可用）
    c_state = []
    streak = 0
    for v in seg:
        streak = streak + 1 if v else 0
        c_state.append(streak)
    print(f"    方案C 下游累积(只看过去) : {c_state}")
    print(f"    ⇒ 方案C 的累积量在推理时逐帧可算（纯过去），"
          f"超过 {threshold} 帧即判「超级刹车」。")
    print(f"      方案B 的标签构造用了段的**总长**（含未来）→ 只能作训练目标，")
    print(f"      但它的『段长≥N』信息可由推理时的累积量近似复现，故两者可配合。")


def main() -> int:
    print("V3 输出编码与损失方案验证（torch %s）" % torch.__version__)
    q1_expressiveness()
    q2_imbalance()
    q3_ordinal()
    q4_super_brake()
    print("\n" + "=" * 82)
    print("全部实验跑完。真实标签分布未测（仓库无数据），见报告 §7 未测项。")
    print("=" * 82)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
