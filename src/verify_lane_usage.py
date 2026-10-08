#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later

"""
verify_lane_usage.py — 车道线有效性验证（T7 · 2026-10-08）

目标：回答一个具体问题 —— **模型到底有没有在用车道线？**

用户痛点（原话）：现在的模型"不会跟车道线，会直接开出车道线"。
这等价于问：把车道线从输入里拿走（或改动它），模型输出的 steer 会不会变？
如果不变，说明模型把车道分支当成了"装饰性旁支"，车道上车即失效。

本脚本**不依赖真实车道线数据**（见下方【铁证】——当前训练集根本没有车道线标注），
而是**自造合成车道线掩码**来测"模型对车道线输入的敏感度"。
这恰好是任务书要求的"加载 checkpoint + 自己构造输入"的验证方式。

三个实验（互为正交，可交叉印证）：

【实验 1 · 消融】 有车道线 vs 车道线全零（None），对比 steer 输出差 Δ_ablation
    判断标准：|Δ_ablation| 明显 > 噪声底 ⇒ 模型确实用了车道线；≈0 ⇒ 白加。

【实验 2 · 扰动】 车道线整体左移/右移 N 格（或左右镜像），看 steer 输出变化 Δ_perturb
    判断标准：敏感度 |Δ_perturb / 移动量| 大 ⇒ 车道位置信息真的进入了 steer。

【实验 3 · 梯度】 对 steer 输出反传，测 lane_encoder 参数的梯度范数 ‖g_lane‖
                    同时测 image_encoder 的梯度范数 ‖g_img‖ 作参照
    判断标准：‖g_lane‖ / ‖g_img‖ 的量级；若 ‖g_lane‖≈0 ⇒ steer 不流经车道分支。

用法：
    python3.11 src/verify_lane_usage.py                          # 用默认 checkpoint
    python3.11 src/verify_lane_usage.py --ckpt PATH --seed 42   # 指定 checkpoint 与种子
    python3.11 src/verify_lane_usage.py --json                  # 输出机器可读 JSON

【铁证 · 为什么当前 checkpoint 大概率对车道线不敏感】
    1. checkpoints/m9_v2/best_model.pt 的 degradation = {"has_lane": False} —— 训练时无车道线
    2. training_log.json 里 lane_supervised_frac 三个 epoch 全是 0.0 —— 车道辅助损失从未生效
    3. lane_encoder.bn*.running_mean 全为 0 / bn*.weight 全为 1 —— BN 从未在非零输入上激活
    4. 全仓找不到任何 lane_masks.npz / lane_mask/ / lanes.json —— 训练数据里根本没有车道线标注
    本脚本会在输出里复核这些事实（重新从 checkpoint 读，而非只听我说的）。

写作用域：本文件（T7 唯一新增源码）；不修改 train_v2.py / model_v2.py / dataset_v2.py。
"""

import argparse
import json
import math
import os
import random
import sys
from pathlib import Path

import numpy as np
import torch

# 允许以 `python src/verify_lane_usage.py` 或 `python -m ...` 运行时都能 import 仓库模块
_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from src.model_v2 import build_model, LANE_SIZE, LANE_FEAT_DIM  # noqa: E402


# ============================================================================
# 1. 合成车道线生成（自造输入，不碰真实数据）
# ============================================================================

def make_lane_mask(pattern: str, shift: int = 0, flip: bool = False,
                   grid: int = LANE_SIZE) -> np.ndarray:
    """生成一个 [1, grid, grid] 二值车道线掩码。

    pattern:
      "straight"  — 两条竖直亮线（左右车道线），位于 x=0.55*grid 与 x=0.35*grid 附近
      "curve"     — 左车道线随 y 弯曲（底部在左，顶部在右），模拟弯道
      "left"      — 仅左车道线（单线，用于测左右敏感度）
      "right"     — 仅右车道线
      "double"    — 两条亮线间距更窄（高速）
    shift: 横向平移的格数（扰动实验用；正 = 右移）
    flip:  True = 左右镜像（扰动实验的强扰动）
    """
    g = grid
    mask = np.zeros((g, g), dtype=np.float32)
    ys = np.arange(g)  # 0 = 顶部，g-1 = 底部

    if pattern == "curve":
        # 左线：底部 x≈0.30g，顶部 x≈0.65g，随 y 线性偏移 → 一条明显弯道
        x_left = (0.30 + 0.35 * (ys / g)).astype(int)
        x_right = (0.70 + 0.15 * (ys / g)).astype(int)
        for y in range(g):
            for dx in (-1, 0, 1):  # 3 格线宽，贴合 MaskGrid 里 1~2 格的线宽并稍加余量
                xi = x_left[y] + dx
                if 0 <= xi < g:
                    mask[y, xi] = 1.0
                xi = x_right[y] + dx
                if 0 <= xi < g:
                    mask[y, xi] = 1.0
    elif pattern == "left":
        x = (np.full(g, 0.38 * g)).astype(int)
        for y in range(g):
            for dx in (-1, 0, 1):
                xi = x[y] + dx
                if 0 <= xi < g:
                    mask[y, xi] = 1.0
    elif pattern == "right":
        x = (np.full(g, 0.62 * g)).astype(int)
        for y in range(g):
            for dx in (-1, 0, 1):
                xi = x[y] + dx
                if 0 <= xi < g:
                    mask[y, xi] = 1.0
    elif pattern == "double":
        xl = (np.full(g, 0.45 * g)).astype(int)
        xr = (np.full(g, 0.55 * g)).astype(int)
        for y in range(g):
            for x in (xl[y], xr[y]):
                for dx in (-1, 0, 1):
                    xi = x + dx
                    if 0 <= xi < g:
                        mask[y, xi] = 1.0
    else:  # "straight"
        xl = (np.full(g, 0.38 * g)).astype(int)
        xr = (np.full(g, 0.62 * g)).astype(int)
        for y in range(g):
            for x in (xl[y], xr[y]):
                for dx in (-1, 0, 1):
                    xi = x + dx
                    if 0 <= xi < g:
                        mask[y, xi] = 1.0

    if shift != 0:
        mask = np.roll(mask, shift, axis=1)
        if shift > 0:
            mask[:, :shift] = 0.0
        elif shift < 0:
            mask[:, shift:] = 0.0

    if flip:
        mask = mask[:, ::-1].copy()

    return mask[None, ...]  # [1, g, g]


def make_dummy_image(b: int, h: int = 180, w: int = 320, seed: int = 0) -> torch.Tensor:
    """造一张恒定（确定性）的图像输入 [B,3,H,W] ∈ [0,1]。

    用固定种子保证三次实验里图像完全一致，从而任何 steer 差异只能来自 lane_mask。
    """
    gen = torch.Generator().manual_seed(seed)
    return torch.rand(b, 3, h, w, generator=gen, dtype=torch.float32)


def make_dummy_dets(b: int, num_dets: int = 20) -> (torch.Tensor, torch.Tensor):
    """造空检测框（dets=None 会让 det_encoder 走零向量，等价于 queue 无目标）。

    这里直接用 None（模型 forward 已支持），保持"只有车道线一个变量"的干净剥离。
    """
    return None, None


def make_dummy_state(b: int, state_dim: int = 8) -> torch.Tensor:
    """造零状态 [B,8]。同样为保持"只有车道线一个变量"。"""
    return torch.zeros(b, state_dim, dtype=torch.float32)


# ============================================================================
# 2. 加载 checkpoint（复用真实权重）
# ============================================================================

def load_checkpoint(ckpt_path: Path):
    """加载 checkpoint，返回 (model, meta)。

    兼容 train_v2.py 的 checkpoint 格式：顶层 dict，含 model_state_dict。
    训练期探针 lane_steer_probe 若存在会剥离（本验证只在推理侧跑，不用 probe）。
    """
    if not ckpt_path.exists():
        raise FileNotFoundError(f"checkpoint 不存在：{ckpt_path}")

    ck = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
    sd = ck["model_state_dict"] if "model_state_dict" in ck else ck

    # 剥离训练期探针（验证侧不需要；也避免 strict load 报错）
    sd = {k: v for k, v in sd.items() if "lane_steer_probe" not in k}

    model = build_model(deploy=False)
    # strict=False：T7 修复后 LaneMaskEncoder 新增了 spatial_proj 层，
    # 旧 checkpoint 没有该层 → 纳入 missing（随机初始化），其余卷积权重照常加载。
    # 这样验证能复现「改架构后旧权重 + 随机投影」的真实训练起点。
    missing, unexpected = model.load_state_dict(sd, strict=False)
    model.eval()
    meta = {
        "epoch": ck.get("epoch"),
        "best_val_loss": ck.get("best_val_loss"),
        "degradation": ck.get("degradation"),
        "has_training_probe": ck.get("has_training_probe"),
        "interface_version": ck.get("interface_version"),
        "loading_missing_keys": missing,
        "loading_unexpected_keys": unexpected,
    }
    return model, meta


# ============================================================================
# 3. 三个实验
# ============================================================================

@torch.no_grad()
def forward_steer(model, image, lane_mask):
    """单次前向，返回 steer 标量张量 [B,1]。"""
    out = model(image=image, lane_mask=lane_mask, dets=None, det_mask=None,
                vehicle_state=None)
    # out 可能是 (steer, throttle, brake) 三元组
    steer = out[0] if isinstance(out, (tuple, list)) else out
    return steer


def experiment_ablation(model, image, lane_mask, patterns, seed):
    """实验 1：消融。同一张图，有车道线 vs 无车道线（None），量 steer 差。"""
    B = image.shape[0]
    results = []
    for pat in patterns:
        lm = torch.from_numpy(make_lane_mask(pat)).unsqueeze(0)  # [1,1,g,g]
        lm = lm.expand(B, -1, -1, -1).contiguous()               # [B,1,g,g]
        s_on = forward_steer(model, image, lm)
        s_off = forward_steer(model, image, None)
        delta = float((s_on - s_off).abs().mean())
        results.append({
            "pattern": pat,
            "steer_with_lane": float(s_on.mean()),
            "steer_without_lane": float(s_off.mean()),
            "abs_delta": delta,
        })
    return results


def experiment_perturb(model, image, patterns, shifts, flip_test=True, seed=42):
    """实验 2：扰动。车道线平移/镜像，量 steer 变化斜率。"""
    B = image.shape[0]
    results = []
    for pat in patterns:
        base_lm = torch.from_numpy(make_lane_mask(pat)).unsqueeze(0)\
                      .expand(B, -1, -1, -1).contiguous()
        s_base = float(forward_steer(model, image, base_lm).mean())

        for sh in shifts:
            lm_shift = torch.from_numpy(make_lane_mask(pat, shift=sh)).unsqueeze(0)\
                           .expand(B, -1, -1, -1).contiguous()
            s_shift = float(forward_steer(model, image, lm_shift).mean())
            results.append({
                "pattern": pat, "kind": "shift", "shift": sh,
                "steer_base": s_base, "steer_after": s_shift,
                "delta": s_shift - s_base,
                "sensitivity_per_grid": (s_shift - s_base) / sh if sh else 0.0,
            })

        if flip_test:
            lm_flip = torch.from_numpy(make_lane_mask(pat, flip=True)).unsqueeze(0)\
                          .expand(B, -1, -1, -1).contiguous()
            s_flip = float(forward_steer(model, image, lm_flip).mean())
            results.append({
                "pattern": pat, "kind": "flip", "shift": 0,
                "steer_base": s_base, "steer_after": s_flip,
                "delta": s_flip - s_base,
                "sensitivity_per_grid": None,
            })
    return results


def experiment_gradient(model, image, lane_mask, pattern):
    """实验 3：梯度。对 steer 反传，测 lane_encoder vs image_encoder 梯度范数。

    关键：用 torch.no_grad 关闭时梯度为 None，所以这里显式启用梯度；
    只对 steer 输出做 sum() 反传，不留续用梯度（用完即清）。
    """
    model.train()  # 让 BN 用 batch 统计（但我们的 BN 未训练，影响一致即可）
    for p in model.parameters():
        p.requires_grad_(True)

    B = image.shape[0]
    lm = torch.from_numpy(make_lane_mask(pattern)).unsqueeze(0)\
            .expand(B, -1, -1, -1).contiguous()  # [B,1,g,g]
    image.requires_grad_(True)
    lm.requires_grad_(True)

    out = model(image=image, lane_mask=lm, dets=None, det_mask=None, vehicle_state=None)
    steer = out[0] if isinstance(out, (tuple, list)) else out
    steer.squeeze().sum().backward()

    def _norm(module):
        sq = 0.0
        for p in module.parameters():
            if p.grad is not None:
                sq += float(p.grad.detach().pow(2).sum())
        return math.sqrt(sq)

    glane = _norm(model.lane_encoder)
    gimg = _norm(model.image_encoder)
    gfusion = _norm(model.fusion_head)

    model.zero_grad(set_to_none=True)
    model.eval()
    return {
        "pattern": pattern,
        "grad_lane_encoder": glane,
        "grad_image_encoder": gimg,
        "grad_fusion_head": gfusion,
        "grad_lane_over_image": (glane / gimg) if gimg > 1e-12 else float("inf"),
    }


def experiment_position_invariance(model, image, x_fracs=(0.1, 0.3, 0.5, 0.7, 0.9)):
    """实验 4：位置不变性（★ 本任务的核心发现）。

    两个层面测「车道线位置信息是否被保留」：

    A. 编码器层（无歧义铁证）：
       单线位置 x1 vs x2，取 LaneMaskEncoder 在 GAP **之前**（10×10 空间特征图）
       与 GAP **之后**（64 维向量）各算一次差异。
       GAP = AdaptiveAvgPool2d((1,1)) 全局平均池化，对空间求平均 → 平移不变。
       若 GAP 前有差、GAP 后差=0 ⇒ 位置信息在 GAP 处被抹掉（架构缺陷，铁证）。

    B. 端到端 steer（会被图像分支稀释，仅作参考）：
       完整 forward，steer 的 spread。
    """
    B = image.shape[0]
    g = LANE_SIZE
    enc = model.lane_encoder

    # ---- A. 编码器层：GAP 前后差异 ----
    def feat_before_gap(lm_1):
        x = enc.downsample(lm_1)
        x = torch.relu(enc.bn1(enc.conv1(x)))
        x = torch.relu(enc.bn2(enc.conv2(x)))
        x = torch.relu(enc.bn3(enc.conv3(x)))
        return x  # [B,64,10,10]

    def lane_mask_at(x):
        mask = np.zeros((1, 1, g, g), dtype=np.float32)
        mask[:, :, max(0, x - 1):x + 2] = 1.0
        return torch.from_numpy(mask)

    xs = [int(xf * g) for xf in x_fracs]
    with torch.no_grad():
        before, after = [], []
        for x in xs:
            lm = lane_mask_at(x)
            fb = feat_before_gap(lm)              # [1,64,10,10]
            ga = enc.global_pool(fb).flatten(1)   # [1,64]
            before.append(fb)
            after.append(ga)
        # GAP 前：相邻位置特征图差异（位置信息应保留）
        d_before = [float((before[i] - before[i + 1]).abs().mean()) for i in range(len(before) - 1)]
        # GAP 后：相邻位置向量差异（GAP 若抹平 → 全 0）
        d_after = [float((after[i] - after[i + 1]).abs().mean()) for i in range(len(after) - 1)]

    # ---- B. 端到端 steer spread（仅参考） ----
    outs = []
    with torch.no_grad():
        for x in xs:
            lm = lane_mask_at(x).expand(B, -1, -1, -1).contiguous()
            s = float(forward_steer(model, image, lm).mean())
            outs.append(s)
    spread = float(max(outs) - min(outs)) if outs else 0.0

    gap_before_mean = float(sum(d_before) / len(d_before)) if d_before else 0.0
    gap_after_mean = float(sum(d_after) / len(d_after)) if d_after else 0.0
    # 位置是否被保留：GAP 后差异远小于 GAP 前（比如 < 1%）即判定被抹平
    erased = gap_after_mean < gap_before_mean * 0.01 and gap_before_mean > 1e-3

    # ---- C. ★「左 vs 右」精确断言（Lead 指定的修复判据） ----
    # 直接测完整编码器输出（含 spatial_proj）在「线在左」与「线在右」时的差。
    # GAP(1,1) 时代该值严格 = 0.000000；修复后应显著 > 0。
    with torch.no_grad():
        f_left = enc(lane_mask_at(int(0.30 * g)), 1, torch.zeros(1))
        f_right = enc(lane_mask_at(int(0.70 * g)), 1, torch.zeros(1))
        left_right_diff = float((f_left - f_right).abs().mean())

    return {
        "scan": [{"x_frac": xf, "x_px": x, "steer": s} for xf, x, s in zip(x_fracs, xs, outs)],
        "steer_spread": spread,
        "position_sensitive": not erased,
        "gap_before_mean_diff": gap_before_mean,
        "gap_after_mean_diff": gap_after_mean,
        "gap_erased_position": erased,
        "left_vs_right_diff": left_right_diff,
        "left_vs_right_ok": left_right_diff > 1e-3,
        "note": (f"GAP 前特征图差异={gap_before_mean:.6f} → GAP 后向量差异={gap_after_mean:.6f}；"
                 f"左 vs 右差={left_right_diff:.6f}；"
                 f"{'位置被 GAP 抹平（铁证）' if erased else '位置保留（GAP 未抹平）'}"),
    }


# ============================================================================
# 4. 审计复核（从 checkpoint 重读事实，不空口背书）
# ============================================================================

def audit_checkpoint(ckpt_path: Path, model):
    """从 checkpoint 与模型权重里重读"车道线是否被训练过"的铁证。"""
    ck = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
    sd = ck["model_state_dict"] if "model_state_dict" in ck else ck

    bn1_rm = sd.get("lane_encoder.bn1.running_mean")
    bn1_w = sd.get("lane_encoder.bn1.weight")
    facts = {
        "degradation_has_lane": ck.get("degradation", {}).get("has_lane"),
        "degradation_has_det": ck.get("degradation", {}).get("has_det"),
        "lane_encoder_bn1_running_mean_max_abs":
            None if bn1_rm is None else float(bn1_rm.abs().max()),
        "lane_encoder_bn1_weight_max_abs":
            None if bn1_w is None else float((bn1_w - 1.0).abs().max()),
    }
    # training_log 里的 lane_supervised_frac
    log_path = ckpt_path.parent / "training_log.json"
    if log_path.exists():
        try:
            log = json.loads(log_path.read_text())
            facts["lane_supervised_frac_history"] = [
                float(h.get("lane_supervised_frac", -1)) for h in log.get("train_history", [])
            ]
        except Exception:
            facts["lane_supervised_frac_history"] = None
    return facts


# ============================================================================
# 5. 汇总与判定
# ============================================================================

def verdict(results: dict, noise_floor: float = 1e-3) -> dict:
    """给一个可读结论：模型是否真的在用车道线（基于实测数字，不拍脑袋）。

    关键区分三层（三者缺一不可，任一缺失都会导致"不会跟线"）：
      层 1 · 梯度可达：steer 损失能否回流传到 lane_encoder（架构上有没有一条路）
      层 2 · 位置敏感：车道线的**位置**变化能否改变输出（GAP 可能把这层抹掉）
      层 3 · 语义学会：权重是否真的在训练里被 carlen 监督过
    """
    abl_deltas = [r["abs_delta"] for r in results["ablation"]]
    perturb_deltas = [abs(r["delta"]) for r in results["perturb"] if r["kind"] == "shift"]
    flip_deltas = [abs(r["delta"]) for r in results["perturb"] if r["kind"] == "flip"]
    grad = results["gradient"][0] if results["gradient"] else {}
    gli = grad.get("grad_lane_encoder", 0.0)
    gim = grad.get("grad_image_encoder", 0.0)
    pos = results.get("position", {})

    max_abl = max(abl_deltas) if abl_deltas else 0.0
    mean_perturb = float(np.mean(perturb_deltas)) if perturb_deltas else 0.0
    mean_flip = float(np.mean(flip_deltas)) if flip_deltas else 0.0
    spread = pos.get("steer_spread", 0.0)
    gap_erased = pos.get("gap_erased_position", False)

    # 层2 "位置敏感" 的准确定义：端到端 spread 或 GAP 未抹平位置。
    # 严格判定用 GAP 前后差异（无歧义铁证），因为端到端 spread 会被图像分支稀释。
    layer2_sensitive = pos.get("position_sensitive", spread > noise_floor)

    signals = {
        "梯度可达（层1）": gli > noise_floor,
        "消融敏感（层2 佐证）": max_abl > noise_floor,
        "扰动敏感（层2 佐证）": mean_perturb > noise_floor,
        "位置敏感（层2 核心）": layer2_sensitive,
    }

    # 层 3（语义学会）取决于 checkpoint 事实，不在这里判（由 audit 事实给出）
    # 判定：层1 与 层2 都过才算"在用"；层2 挂掉（位置不敏感）= GAP 抹掉位置，必然不会跟线
    layer1_ok = signals["梯度可达（层1）"]
    layer2_ok = signals["位置敏感（层2 核心）"]
    using_lane = layer1_ok and layer2_ok

    if not layer1_ok:
        conclusion = ("❌ 层1 失败：steer 梯度不流经车道分支（车道线是装饰性旁支）"
                      "—— 模型内部无路可走，自然「不会跟线」")
    elif not layer2_ok:
        conclusion = ("⚠️ 层1 通过（梯度可达）但 层2 失败（位置不敏感，GAP 抹掉位置）："
                      "车道线位置信息在全局平均池化处丢失——模型「看得见」车道线却"
                      "「分不清左右」，这正是「会开出车道线」的架构根源")
    else:
        conclusion = ("✅ 层1 + 层2 均通过：车道线既进得去 steer 梯度，又保留位置语义。"
                      "（层3 语义是否学会，另看 checkpoint 的 has_lane 事实）")

    return {
        "signals": signals,
        "layer1_grad_reaches": layer1_ok,
        "layer2_position_sensitive": layer2_ok,
        "max_ablation_delta": max_abl,
        "mean_perturb_delta": mean_perturb,
        "mean_flip_delta": mean_flip,
        "position_spread": spread,
        "grad_lane_vs_image": (gli / gim) if gim > 1e-12 else None,
        "conclusion": conclusion,
    }


# ============================================================================
# 6. main
# ============================================================================

def main():
    ap = argparse.ArgumentParser(description="车道线有效性验证（消融/扰动/梯度）")
    ap.add_argument("--ckpt", type=Path,
                    default=_ROOT / "checkpoints" / "m9_v2" / "best_model.pt",
                    help="checkpoint 路径")
    ap.add_argument("--seed", type=int, default=42, help="图像/模型确定性种子")
    ap.add_argument("--patterns", nargs="+",
                    default=["straight", "curve", "left", "right"],
                    help="合成车道线图案")
    ap.add_argument("--shifts", nargs="+", type=int, default=[-8, -4, 4, 8],
                    help="扰动平移格数")
    ap.add_argument("--noise-floor", type=float, default=1e-3,
                    help="判定敏感的 steer 差异阈值")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    random.seed(args.seed)

    print("=" * 70)
    print("车道线有效性验证（T7 · 2026-10-08）")
    print(f"checkpoint: {args.ckpt}")
    print(f"torch: {torch.__version__}")
    print("=" * 70)

    # ---- 加载 checkpoint ----
    model, meta = load_checkpoint(args.ckpt)
    print(f"\n[checkpoint] epoch={meta['epoch']} best_val_loss={meta['best_val_loss']}"
          f" degradation={meta['degradation']} has_training_probe={meta['has_training_probe']}")

    # ---- 审计复核 ----
    facts = audit_checkpoint(args.ckpt, model)
    print("\n[审计复核] 车道线是否被训练过（从 checkpoint 重读的事实）：")
    print(f"  degradation.has_lane            = {facts['degradation_has_lane']}")
    print(f"  degradation.has_det             = {facts['degradation_has_det']}")
    print(f"  lane_encoder.bn1.running_mean   = "
          f"{'全 0（BN 从未激活）' if facts['lane_encoder_bn1_running_mean_max_abs'] == 0 else '非零'}"
          f" (max|.|={facts['lane_encoder_bn1_running_mean_max_abs']})")
    print(f"  lane_encoder.bn1.weight 偏 1.0   = {facts['lane_encoder_bn1_weight_max_abs']:.6f}")
    hist = facts.get("lane_supervised_frac_history")
    print(f"  lane_supervised_frac_history    = {hist}")

    # ---- 造输入 ----
    B = 4
    image = make_dummy_image(B, seed=args.seed)

    # ---- 实验 1：消融 ----
    print("\n" + "─" * 70)
    print("[实验 1 · 消融] 有车道线 vs 无车道线（None），steer 差异")
    abl = experiment_ablation(model, image, None, args.patterns, args.seed)
    for r in abl:
        print(f"  {r['pattern']:9s}  with={r['steer_with_lane']:+.4f}  "
              f"without={r['steer_without_lane']:+.4f}  |Δ|={r['abs_delta']:.6f}")

    # ---- 实验 2：扰动 ----
    print("\n" + "─" * 70)
    print("[实验 2 · 扰动] 车道线平移/镜像，steer 变化")
    pert = experiment_perturb(model, image, args.patterns, args.shifts, flip_test=True)
    for r in pert:
        sens = f"{r['sensitivity_per_grid']:.6f}" if r['sensitivity_per_grid'] is not None else "--"
        print(f"  {r['pattern']:9s} {r['kind']:6s}"
              f" (shift={r['shift']:+3d})  base={r['steer_base']:+.4f} "
              f" after={r['steer_after']:+.4f}  Δ={r['delta']:+.6f}  "
              f"每格敏感度={sens}")

    # ---- 实验 3：梯度 ----
    print("\n" + "─" * 70)
    print("[实验 3 · 梯度] steer 反传，测分支梯度范数")
    grads = [experiment_gradient(model, image, None, p) for p in args.patterns[:2]]
    for g in grads:
        print(f"  {g['pattern']:9s}  ‖g_lane‖={g['grad_lane_encoder']:.6f}  "
              f"‖g_img‖={g['grad_image_encoder']:.6f}  "
              f"‖g_fusion‖={g['grad_fusion_head']:.6f}  "
              f"lane/img={g['grad_lane_over_image']:.6f}")

    # ---- 实验 4：位置不变性（★ 核心） ----
    print("\n" + "─" * 70)
    print("[实验 4 · 位置不变性] 单线横向扫过掩码，测 GAP 是否抹掉位置信息")
    pos = experiment_position_invariance(model, image)
    for r in pos["scan"]:
        print(f"  线 x={r['x_px']:3d} ({r['x_frac']:.1f}g)  → steer={r['steer']:+.6f}")
    print(f"  端到端 steer 极差（spread）={pos['steer_spread']:.6f}")
    print(f"  GAP 前特征图平均差异 ={pos['gap_before_mean_diff']:.6f}")
    print(f"  GAP 后向量平均差异   ={pos['gap_after_mean_diff']:.6f}")
    print(f"  → {pos['note']}")

    # ---- 判定 ----
    vd = verdict({"ablation": abl, "perturb": pert, "gradient": grads,
                  "position": pos},
                 noise_floor=args.noise_floor)
    print("\n" + "=" * 70)
    print("[判定]")
    for k, v in vd["signals"].items():
        print(f"  {k}: {'✅' if v else '❌'}")
    print(f"  消融最大|Δ|={vd['max_ablation_delta']:.6f}")
    print(f"  扰动平均|Δ|={vd['mean_perturb_delta']:.6f}")
    print(f"  镜像平均|Δ|={vd['mean_flip_delta']:.6f}")
    print(f"  位置极差={vd['position_spread']:.6f}")
    print(f"  梯度 lane/img={vd['grad_lane_vs_image']}")
    print(f"\n  ⇒ {vd['conclusion']}")
    print("=" * 70)

    if args.json:
        payload = {
            "meta": meta, "facts": facts,
            "ablation": abl, "perturb": pert, "gradient": grads,
            "position": pos, "verdict": vd,
        }
        print("\n[JSON]")
        print(json.dumps(payload, ensure_ascii=False, indent=2))

    return vd


if __name__ == "__main__":
    main()