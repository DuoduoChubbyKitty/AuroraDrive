#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 时序模块 · state token 与噪声注入的量化分析（第四组实验）。

回答 Lead 的三个问题，每个都给数字：

  Q1 state token 装什么？三种方案的参数量 / 算力（**真实模块测量**）
     A. 只装 t-1 四标量（论文原样）
     B. t-1 四标量 + 24 帧历史摘要（推荐）
     C. 24 帧完整状态序列编码

  Q2 独立 temporal token 让 token 数增加后的 attn 算力（**公式推算**）

  Q3 有 24 帧真实历史后还需不需要噪声注入？
     判据一：状态空间覆盖率（细网格，**模拟数据**）
     判据二：物理一致性 —— 噪声注入是否造出动力学上不可能的状态
             （这是**不依赖模拟**的机械结论：逐维独立加噪必然破坏维度间约束）

⚠️ 口径声明：Q3 用的是**合成数据**（复现论文 Fig.5 描述的双峰 throttle +
   steer 近零分布的形状），不是我们的真实采集数据。它只能说明机理，
   **真实覆盖率必须用我们的数据重算** → 已列入报告「未测项」。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/05_state_token.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))


# ----------------------------------------------------------------------------
# Q1：三种 state token 内容方案（真实 nn.Module）
# ----------------------------------------------------------------------------
class StateTokenHead(nn.Module):
    """A：论文式 —— 4 个标量 lift 到 D 维 state token。

    论文 (1) 式：xstate ∈ R^{1×D}，四个标量各 lift 到 D/4 再 concat。
    用单个 Linear(4, D) 实现；n=4、D=128 时若严格按"各 lift 到 D/4 再拼"，
    等价于把 Linear 权重按 D/4 分块、每块只吃一个输入 → 参数量同为 4×D + D。
    """

    def __init__(self, n_scalars: int = 4, d_model: int = 128):
        super().__init__()
        self.proj = nn.Linear(n_scalars, d_model)

    def forward(self, s):
        return self.proj(s)


class HistorySummaryToken(nn.Module):
    """B：t-1 四标量 + 24 帧历史摘要向量 → state token。"""

    def __init__(self, n_scalars: int = 4, hidden: int = 128, d_model: int = 128):
        super().__init__()
        self.proj = nn.Linear(n_scalars + hidden, d_model)

    def forward(self, s_t1, hist):
        return self.proj(torch.cat([s_t1, hist], dim=-1))


class FullSeqStateToken(nn.Module):
    """C：24 帧完整状态序列（静态展开 GRU）→ state token。"""

    def __init__(self, n_scalars: int = 4, steps: int = 24, hidden: int = 64,
                 d_model: int = 128):
        super().__init__()
        self.steps = steps
        self.in_proj = nn.Linear(n_scalars, hidden)
        self.x_r = nn.Linear(hidden, hidden); self.h_r = nn.Linear(hidden, hidden)
        self.x_z = nn.Linear(hidden, hidden); self.h_z = nn.Linear(hidden, hidden)
        self.x_n = nn.Linear(hidden, hidden); self.h_n = nn.Linear(hidden, hidden)
        self.out = nn.Linear(hidden, d_model)

    def forward(self, seq):                     # [B,24,4]
        x = self.in_proj(seq)
        h = torch.zeros_like(x[:, 0, :])
        for t in range(self.steps):
            xt = x[:, t, :]
            r = torch.sigmoid(self.x_r(xt) + self.h_r(h))
            z = torch.sigmoid(self.x_z(xt) + self.h_z(h))
            n = torch.tanh(self.x_n(xt) + r * self.h_n(h))
            h = (1.0 - z) * n + z * h
        return self.out(h)


def count_params(m: nn.Module) -> int:
    return sum(p.numel() for p in m.parameters())


def measure_linear_macs(m: nn.Module, *shapes) -> int:
    total = 0
    hooks = []

    def hook(mod, inp, out):
        nonlocal total
        if isinstance(mod, nn.Linear):
            total += out.numel() * mod.in_features

    for mod in m.modules():
        if isinstance(mod, nn.Linear):
            hooks.append(mod.register_forward_hook(hook))
    m.eval()
    with torch.no_grad():
        m(*[torch.zeros(*s) for s in shapes])
    for h in hooks:
        h.remove()
    return total


# ----------------------------------------------------------------------------
# Q3：合成数据（明确标注）
# ----------------------------------------------------------------------------
def make_skewed_single_frame(rng: np.random.Generator, n: int = 40000) -> np.ndarray:
    """复现论文 Fig.5 描述的形状：throttle 双峰（静止≈0 / 全油门≈1），
    steer ≈ N(0, 低方差)。返回 [n,3] = (steer, throttle, speed)，均归一化 [0,1]。

    ★ 合成数据，不是真实采集。
    """
    is_stationary = rng.random(n) < 0.55
    throttle = np.where(is_stationary,
                        np.clip(rng.normal(0.02, 0.03, n), 0, 1),
                        np.clip(rng.normal(0.92, 0.10, n), 0, 1))
    steer = np.clip(rng.normal(0.0, 0.15, n), -1, 1)
    speed = np.clip(np.where(is_stationary,
                             rng.normal(0.02, 0.04, n),
                             rng.normal(0.65, 0.20, n)), 0, 1)
    return np.stack([steer, throttle, speed], axis=1)


def inject_noise(rng: np.random.Generator, pts: np.ndarray,
                 sigma_ctrl: float = 0.1, sigma_speed: float = 1.0) -> np.ndarray:
    """论文式噪声注入（:201-207）：控制量 σ=0.1（范围 [0,1]），
    速度 σ=1（原始范围 [0,10] → 归一化后等效 σ=0.1）。"""
    out = pts.copy()
    out[:, :2] = out[:, :2] + rng.normal(0, sigma_ctrl, (len(out), 2))
    out[:, 0] = np.clip(out[:, 0], -1, 1)                       # steer ∈[-1,1]
    out[:, 1] = np.clip(out[:, 1], 0, 1)                        # throttle ∈[0,1]
    speed_raw = out[:, 2] * 10.0 + rng.normal(0, sigma_speed, len(out))
    out[:, 2] = np.clip(speed_raw / 10.0, 0, 1)
    return out


def rollout_24frame_window(rng: np.random.Generator, n_traj: int = 2000,
                           steps: int = 24, dt: float = 1 / 15) -> np.ndarray:
    """24 帧窗口内的状态轨迹（简单纵向动力学，状态在时间上自洽）。

    speed' = speed + (k1·throttle − k2·speed − k0)·dt
    参数取的是"量级合理"的值，不是标定值 —— 目的是让状态在物理上自洽，
    而不是复现真实车辆。返回 [n_traj*steps, 3]。
    """
    thr = np.clip(rng.normal(0.45, 0.30, n_traj), 0, 1)
    sp = np.clip(rng.normal(0.35, 0.25, n_traj), 0, 1)
    st = np.clip(rng.normal(0, 0.08, n_traj), -1, 1)
    frames = []
    for _ in range(steps):
        acc = 0.9 * thr - 1.5 * sp - 0.02      # 高速时阻力大，低速时加速
        sp = np.clip(sp + acc * dt, 0, 1)
        thr = np.clip(thr + rng.normal(0, 0.06, n_traj), 0, 1)
        st = np.clip(st + rng.normal(0, 0.04, n_traj), -1, 1)
        frames.append(np.stack([st, thr, sp], axis=1))
    return np.concatenate(frames, axis=0)


def occupied_cells(pts: np.ndarray, bins: int = 32) -> dict:
    """细网格占据统计。bins=32 → 32768 格，4 万样本仍稀疏，有区分度。"""
    hist, _ = np.histogramdd(
        pts, bins=bins, range=[(-1, 1), (0, 1), (0, 1)])
    occ = int((hist > 0).sum())
    total = bins ** 3
    # 被"充分"覆盖的格子（样本数 ≥ 全部样本均值的一半）
    mean_per_cell = hist.sum() / total
    dense = int((hist >= max(mean_per_cell * 0.5, 2)).sum())
    return {"occupied": occ, "dense": dense, "total": total,
            "occupied_ratio": round(occ / total, 4),
            "dense_ratio": round(dense / total, 4)}


def dynamics_residual(pts: np.ndarray, dt: float = 1 / 15) -> np.ndarray:
    """物理一致性残差：给定 (throttle, speed)，动力学应给出确定的加速度。

    这里没有跨帧配对（单帧样本里拿不到 Δspeed），所以退一步用
    **稳态一致性**：throttle 与 speed 的可行区域应满足
        acc ≈ 0.9·throttle − 1.5·speed − 0.02  ∈ [-1.5, 0.9]
    且 |acc| 很大时说明该 (throttle, speed) 组合在 1.6s 内会迅速变化，
    不是稳定工作点。用 |acc| 的分布衡量"这组状态物理上能维持多久"。
    """
    thr, sp = pts[:, 1], pts[:, 2]
    acc = 0.9 * thr - 1.5 * sp - 0.02
    return np.abs(acc)


def main() -> int:
    results: dict = {}

    print("=" * 86)
    print("Q1 state token 三种内容方案：参数量 / 算力（真实 nn.Module 测量）")
    print("=" * 86)
    d = 128
    specs = [
        ("A 只装 t-1 四标量（论文原样）", StateTokenHead(4, d), [(1, 4)]),
        ("B t-1 四标量 + 24帧历史摘要", HistorySummaryToken(4, 128, d),
         [(1, 4), (1, 128)]),
        ("C 24帧完整状态序列(4→64→128)", FullSeqStateToken(4, 24, 64, d),
         [(1, 24, 4)]),
    ]
    rows = []
    for name, mod, shapes in specs:
        p = count_params(mod)
        m_ = measure_linear_macs(mod, *shapes)
        rows.append({"plan": name, "params": p, "macs": m_})
        print(f"  {name:30s} params={p:>8,}  MACs={m_:>10,}")
    results["state_token_plans"] = rows

    print()
    print("=" * 86)
    print("Q2 token 数增加后的 attn 算力（视觉 72 token 为基线，d=128，2 层）")
    print("=" * 86)

    def attn_macs(tokens: int, d_model: int = 128, layers: int = 2) -> int:
        per = 3 * tokens * d_model * d_model            # QKV 投影
        per += 2 * tokens * tokens * d_model            # QK^T + AV
        per += tokens * d_model * d_model               # 输出投影
        per += 2 * tokens * d_model * (2 * d_model)     # FFN ratio=2
        return per * layers

    scen = [
        ("论文式：72 视觉 + 1 state", 73),
        ("推荐：72 视觉 + 1 state + 1 temporal", 74),
        ("激进：72 视觉 + 1 state + 24 逐帧 temporal", 97),
        ("极端：72 视觉 + 24 帧全 flatten 成 token", 96),
    ]
    base = attn_macs(scen[0][1])
    attn_rows = []
    for name, t in scen:
        m_ = attn_macs(t)
        attn_rows.append({"scenario": name, "tokens": t, "attn_macs": m_,
                          "x_vs_paper": round(m_ / base, 3)})
        print(f"  {name:38s} tokens={t:3d} MACs={m_:>10,}  {m_/base:.2f}×")
    results["attn_token_scaling"] = attn_rows

    print()
    print("=" * 86)
    print("Q3 噪声注入 vs 24 帧真实历史（⚠️ 合成数据，仅说明机理）")
    print("=" * 86)
    rng = np.random.default_rng(20261103)

    single = make_skewed_single_frame(rng, 40000)
    hist = rollout_24frame_window(rng, 2000, 24)
    print(f"  样本数：单帧 {len(single)}，24帧窗口 {len(hist)}")
    print(f"  单帧 throttle 双峰：{np.percentile(single[:,1],[10,50,90]).round(3)}（10/50/90分位）")
    print(f"  24帧窗口 throttle：{np.percentile(hist[:,1],[10,50,90]).round(3)}")

    cases = {
        "① 单帧（无增广）": single,
        "② 单帧 + 论文式噪声(σ_ctrl=0.1, σ_speed=1)": inject_noise(rng, single),
        "③ 24帧窗口（真实历史，物理自洽）": hist,
        "④ 24帧窗口 + 噪声注入": inject_noise(rng, hist),
    }
    cov_rows = {}
    for name, pts in cases.items():
        c = occupied_cells(pts, bins=32)
        res = dynamics_residual(pts)
        c["mean_abs_acc"] = round(float(res.mean()), 4)
        c["p95_abs_acc"] = round(float(np.percentile(res, 95)), 4)
        c["frac_abs_acc_gt_0.5"] = round(float((res > 0.5).mean()), 4)
        cov_rows[name] = c
        print(f"\n  {name}")
        print(f"    占据格 {c['occupied']:5d}/{c['total']} ({c['occupied_ratio']:.1%})  "
              f"充分覆盖格 {c['dense']:5d} ({c['dense_ratio']:.1%})")
        print(f"    动力学残差 |acc|：均值 {c['mean_abs_acc']:.3f}，"
              f"p95 {c['p95_abs_acc']:.3f}，"
              f"|acc|>0.5（1.6s 内必变化的状态）占比 {c['frac_abs_acc_gt_0.5']:.1%}")
    results["coverage"] = cov_rows

    out = Path(__file__).resolve().parent / "05_state_token_result.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
