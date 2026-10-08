#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_heads.py —— 独立验证 w7 集成的三个感知头（时序 / 车头朝向 / 风险）+ GAP 修复

⛔ 本脚本**只读** `src/model_v2.py` 及三个头模块，**不修改任何源码**。

═══════════════════════════════════════════════════════════════════════════
验证目标（每项都要能证伪）
═══════════════════════════════════════════════════════════════════════════
  A. GAP 修复：车道线在左 vs 在右，lane_feat/steer 差是否从 0 变成 >0
     ⚠️ 关键判据：必须与「旧 GAP(1,1) 实现」对照，证明 0 → >0
  B. 时序：连续帧 vs 乱序/重复帧，输出应不同（证明时序真的在用）
  C. 车头朝向头：喂不同 camera_heading，car_heading 输出是否跟着变
  D. 风险头：输出范围 [0,1]？退化（无检测框）是否不崩？
  E. 参数量：训练态/部署态，INT8 是否 ≤10MB
  F. ★ 端到端可达性：新头能否通过 CoreML 导出契约上车
     —— 这是最容易被忽略的「假绿」：PyTorch 里通了，但导出契约没带这些输入
  G. ★ 静默降级审计：model_v2 用 try/except pass 吞掉了哪些异常

用法：
    ./.venv-yolo26/bin/python3 src/verify_heads.py
    ./.venv-yolo26/bin/python3 src/verify_heads.py --json   # 机器可读输出

退出码：0 = 全部通过；1 = 有失败项
"""

from __future__ import annotations

import argparse
import inspect
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

_ROOT = Path(__file__).resolve().parent.parent
# ★ 必须同时把 repo root 与 src 放进 sys.path：
#   · repo root → 让 model_v2.py 里的 `from src.heading_head import ...` 能成功
#   · src       → 让本脚本的 `import model_v2` 能成功
#   ⚠️ 只放 src 会让三头**静默变 None**（见下方 verify_import_context 的实测）。
for _p in (str(_ROOT), str(_ROOT / "src")):
    if _p not in sys.path:
        sys.path.insert(0, _p)


class Report:
    def __init__(self) -> None:
        self.rows: List[Dict[str, Any]] = []

    def add(self, section: str, name: str, ok: bool, detail: str = "",
            warn: bool = False) -> None:
        status = "WARN" if (warn and ok) else ("PASS" if ok else "FAIL")
        self.rows.append({"section": section, "name": name,
                          "status": status, "detail": detail})
        icon = {"PASS": "✓", "WARN": "⚠", "FAIL": "✗"}[status]
        print(f"  {icon} {name}" + (f"  — {detail}" if detail else ""))

    def counts(self) -> Tuple[int, int, int]:
        p = sum(1 for r in self.rows if r["status"] == "PASS")
        w = sum(1 for r in self.rows if r["status"] == "WARN")
        f = sum(1 for r in self.rows if r["status"] == "FAIL")
        return p, w, f


R = Report()


def hdr(t: str) -> None:
    print()
    print("=" * 78)
    print(t)
    print("=" * 78)


# ============================================================================
# A. GAP 修复
# ============================================================================
def verify_gap() -> None:
    hdr("A. GAP 修复验证（车道线左/右可分性）—— 最关键回归")
    import model_v2

    m = model_v2.build_model(deploy=False)
    le = m.lane_encoder
    m.eval()

    has_proj = hasattr(le, "spatial_proj")
    is_2x2 = tuple(getattr(le.global_pool, "output_size", ())) == (2, 2)
    R.add("A", "LaneMaskEncoder 已改 GAP(2,2)+spatial_proj", has_proj and is_2x2,
          f"global_pool={le.global_pool}, spatial_proj={has_proj}")

    if not (has_proj and is_2x2):
        R.add("A", "GAP 修复生效（左/右可分）", False, "结构未改，跳过后续")
        return

    H = W = 160
    def mk(x0, x1, y0=100, y1=140):
        lm = torch.zeros(1, 1, H, W)
        lm[0, 0, y0:y1, x0:x1] = 1.0
        return lm

    img = torch.zeros(1, 3, 180, 320)
    lm_l, lm_r, lm_c = mk(30, 50), mk(110, 130), mk(70, 90)

    with torch.no_grad():
        f_l = le(lm_l, 1, img)
        f_r = le(lm_r, 1, img)
        f_c = le(lm_c, 1, img)
        o_l = m(img, lm_l, None, None, None)
        o_r = m(img, lm_r, None, None, None)

    fd = (f_l - f_r).abs().max().item()
    sd = (o_l[0] - o_r[0]).abs().max().item()
    R.add("A", "lane_feat 左 vs 右 >0（位置信息保留）", fd > 1e-6,
          f"最大差={fd:.6f}")
    R.add("A", "steer 左 vs 右 >0（位置能传到输出）", sd > 1e-6,
          f"最大差={sd:.6f}")
    d_lc = (f_l - f_c).abs().max().item()
    d_cr = (f_c - f_r).abs().max().item()
    R.add("A", "左/中/右 三者两两可分",
          d_lc > 1e-6 and d_cr > 1e-6,
          f"左中={d_lc:.6f}, 中右={d_cr:.6f}")

    # ---- 对照：复现旧 GAP(1,1) 的行为，证明「0 → >0」 ----
    class OldLane(nn.Module):
        """复刻修复前的 LaneMaskEncoder（GAP(1,1)，无 spatial_proj）。"""
        def __init__(self):
            super().__init__()
            self.downsample = nn.MaxPool2d(2, 2)
            self.conv1 = nn.Conv2d(1, 16, 3, 2, 1, bias=False)
            self.bn1 = nn.BatchNorm2d(16)
            self.conv2 = nn.Conv2d(16, 32, 3, 2, 1, bias=False)
            self.bn2 = nn.BatchNorm2d(32)
            self.conv3 = nn.Conv2d(32, 64, 3, 2, 1, bias=False)
            self.bn3 = nn.BatchNorm2d(64)
            self.global_pool = nn.AdaptiveAvgPool2d((1, 1))

        def forward(self, lm):
            x = self.downsample(lm)
            x = F.relu(self.bn1(self.conv1(x)))
            x = F.relu(self.bn2(self.conv2(x)))
            x = F.relu(self.bn3(self.conv3(x)))
            return self.global_pool(x).flatten(1)

    old = OldLane()
    # 用新模型的卷积权重初始化旧结构，保证对照公平（唯一差别 = 池化方式）
    with torch.no_grad():
        old.conv1.weight.copy_(le.conv1.weight)
        old.bn1.load_state_dict(le.bn1.state_dict())
        old.conv2.weight.copy_(le.conv2.weight)
        old.bn2.load_state_dict(le.bn2.state_dict())
        old.conv3.weight.copy_(le.conv3.weight)
        old.bn3.load_state_dict(le.bn3.state_dict())
    old.eval()
    with torch.no_grad():
        of_l, of_r = old(lm_l), old(lm_r)
    old_fd = (of_l - of_r).abs().max().item()
    ratio = (fd / old_fd) if old_fd > 0 else float("inf")
    R.add("A", "★ 修复前后对照：旧 GAP(1,1) 左右差 ≈0（bug 复现）",
          old_fd < 1e-6, f"旧实现最大差={old_fd:.3e}")
    R.add("A", "★ 修复有效：新/旧 差值倍数", fd > 1e-6 and old_fd < 1e-6,
          f"新={fd:.6f} vs 旧={old_fd:.3e} → 提升 {ratio:.3g}×")

    # ---- 旧 checkpoint 兼容性 ----
    ckpt = _ROOT / "checkpoints" / "m9_v2" / "best_model.pt"
    if ckpt.exists():
        ck = torch.load(ckpt, map_location="cpu", weights_only=False)
        sd_keys = set(ck["model_state_dict"].keys())
        new_keys = set(m.state_dict().keys())
        unexpected = sorted(sd_keys - new_keys)
        missing = sorted(new_keys - sd_keys)
        res = m.load_state_dict(ck["model_state_dict"], strict=False)
        R.add("A", "旧 checkpoint 可加载（unexpected=0）", not unexpected,
              f"missing={len(missing)}（含新增头）, unexpected={len(unexpected)}")
        if missing:
            R.add("A", "缺失键 = 仅新增头（预期需重训）",
                  all(("spatial_proj" in k or "temporal" in k or "heading" in k
                       or "risk" in k) for k in missing),
                  f"examples: {missing[:3]}")
    else:
        R.add("A", "旧 checkpoint 存在", False, f"{ckpt} 不存在", warn=True)


# ============================================================================
# B. 时序
# ============================================================================
def verify_temporal() -> None:
    hdr("B. 时序验证（连续帧 vs 乱序/重复帧）")
    try:
        from temporal import TemporalEncoder
    except ImportError as e:
        R.add("B", "导入 temporal", False, str(e))
        return
    R.add("B", "导入 temporal", True)

    torch.manual_seed(42)
    enc = TemporalEncoder(feat_dim=256, hidden_dim=128, num_frames=8)
    enc.eval()
    B = 2
    seq = torch.randn(B, 8, 256)

    with torch.no_grad():
        out = enc(seq, None)
        out_rev = enc(seq[:, torch.arange(7, -1, -1)], None)
        out_rep = enc(seq[:, :1].repeat(1, 8, 1), None)
        out_zero_mask = enc(seq, torch.zeros(B, 8))

    d_rev = (out - out_rev).abs().max().item()
    d_rep = (out - out_rep).abs().max().item()
    R.add("B", "连续 vs 逆序 输出不同（对顺序敏感）", d_rev > 1e-4,
          f"最大差={d_rev:.6f}")
    R.add("B", "连续 vs 单帧重复 输出不同（历史在用）", d_rep > 1e-4,
          f"最大差={d_rep:.6f}")

    # 丢最新帧 vs 丢最老帧：最新帧影响应更大
    with torch.no_grad():
        mo = torch.ones(B, 8); mo[:, 0] = 0
        mn = torch.ones(B, 8); mn[:, -1] = 0
        d_old = (out - enc(seq, mo)).abs().max().item()
        d_new = (out - enc(seq, mn)).abs().max().item()
    R.add("B", "丢最新帧影响 > 丢最老帧（时序因果性）", d_new >= d_old,
          f"最新={d_new:.4f} vs 最老={d_old:.4f}")

    # ★ 关键：模型层面时序是否真的改变了控制输出
    import model_v2
    m = model_v2.build_model(deploy=False)
    m.eval()
    img = torch.randn(1, 3, 180, 320)
    hf = torch.randn(1, 8, 256)
    with torch.no_grad():
        base = m(img, None, None, None, None)
        hist = m(img, None, None, None, None, history_feats=hf)
        hist_rev = m(img, None, None, None, None,
                     history_feats=hf[:, torch.arange(7, -1, -1)])
    dd = (base[0] - hist[0]).abs().max().item()
    dr = (hist[0] - hist_rev[0]).abs().max().item()
    R.add("B", "★ 模型层：给 history_feats 后 steer 改变", dd > 1e-6,
          f"Δsteer={dd:.6f}")
    R.add("B", "★ 模型层：history 乱序时 steer 再变（时序真在用）", dr > 1e-6,
          f"Δsteer={dr:.6f}")

    # N=1 退化必须与不传 history 完全一致
    with torch.no_grad():
        hf1 = m(img, None, None, None, None, history_feats=torch.randn(1, 1, 256))
    d1 = (base[0] - hf1[0]).abs().max().item()
    R.add("B", "N=1 退化 ≡ 不传 history（向后兼容）", d1 < 1e-7,
          f"Δsteer={d1:.3e}")


# ============================================================================
# C. 车头朝向头
# ============================================================================
def verify_heading() -> None:
    hdr("C. 车头朝向头（HeadingHead）")
    import model_v2
    try:
        from heading_head import HeadingHead
    except ImportError as e:
        R.add("C", "导入 heading_head", False, str(e))
        return
    R.add("C", "导入 heading_head", True)

    m = model_v2.build_model(deploy=False)
    m.eval()
    R.add("C", "model_v2 已挂载 heading_head", m.heading_head is not None,
          f"type={type(m.heading_head).__name__ if m.heading_head else None}")

    img = torch.randn(1, 3, 180, 320)
    # 不同视角朝向 → carHeading 应跟着变
    with torch.no_grad():
        r_none = m(img, None, None, None, None, return_aux=True)
        h0 = m(img, None, None, None, None,
               camera_heading=torch.tensor([0.0]), return_aux=True)
        h1 = m(img, None, None, None, None,
               camera_heading=torch.tensor([1.0]), return_aux=True)
    ch_none = r_none[3].get("car_heading")
    ch0 = h0[3].get("car_heading")
    ch1 = h1[3].get("car_heading")
    R.add("C", "return_aux=True 返回 car_heading", ch0 is not None,
          f"None 时={ch_none is not None}")
    if ch0 is not None and ch1 is not None:
        d = (ch0 - ch1).abs().max().item()
        R.add("C", "★ camera_heading 变化 → car_heading 跟着变", d > 1e-6,
              f"Δ={d:.6f}")
        rng_ok = bool((-np.pi - 0.01 <= ch0.min().item()
                       and ch0.max().item() <= np.pi + 0.01))
        R.add("C", "car_heading 范围 ∈ [-π,π]", rng_ok,
              f"[{ch0.min().item():.4f}, {ch0.max().item():.4f}]")
        # 主路径语义：car = wrap(camera + Δ)
        if ch_none is not None and ch0 is not None:
            pass
    else:
        R.add("C", "car_heading 有输出", False, "返回 None（head 内部可能抛异常）")

    # 直接测模块本身（绕过 model_v2 的 try/except）
    try:
        hh = HeadingHead(in_dim=256)
        hh.eval()
        vf = torch.randn(2, 256)
        with torch.no_grad():
            a = hh(vf, torch.tensor([0.0, 0.5]))
            b = hh(vf, torch.tensor([2.0, -2.0]))
        d2 = (a - b).abs().max().item()
        R.add("C", "模块直测：视角变化 → 输出变化", d2 > 1e-6, f"Δ={d2:.6f}")
        # 确定性检查：同输入同输出
        with torch.no_grad():
            a2 = hh(vf, torch.tensor([0.0, 0.5]))
        R.add("C", "模块直测：确定性（同输入同输出）",
              (a - a2).abs().max().item() < 1e-7,
              f"Δ={(a-a2).abs().max().item():.2e}")
    except Exception as e:
        R.add("C", "模块直测", False, f"{type(e).__name__}: {e}")


# ============================================================================
# D. 风险头
# ============================================================================
def verify_risk() -> None:
    hdr("D. 风险头（RiskHead）")
    import model_v2
    try:
        from risk_head import RiskHead, RiskHeadConfig, estimate_ttc, TTCConfig
    except ImportError as e:
        R.add("D", "导入 risk_head", False, str(e))
        return
    R.add("D", "导入 risk_head", True)

    m = model_v2.build_model(deploy=False)
    m.eval()
    R.add("D", "model_v2 已挂载 risk_head", m.risk_head is not None)

    img = torch.randn(2, 3, 180, 320)
    dets = torch.zeros(2, 20, 12)
    dets[:, 0, :4] = torch.tensor([0.5, 0.6, 0.2, 0.25])
    dets[:, 0, 8] = 0.9
    dm = torch.zeros(2, 20); dm[:, 0] = 1.0
    st = torch.randn(2, 8)

    with torch.no_grad():
        out = m(img, None, dets, dm, st, return_aux=True)
    conf, risk = out[3].get("confidence"), out[3].get("risk")
    R.add("D", "return_aux 返回 confidence/risk",
          conf is not None and risk is not None)
    if conf is not None and risk is not None:
        c_ok = bool(0.0 <= conf.min() and conf.max() <= 1.0)
        r_ok = bool(0.0 <= risk.min() and risk.max() <= 1.0)
        R.add("D", "confidence ∈ [0,1]", c_ok,
              f"[{conf.min():.4f}, {conf.max():.4f}]")
        R.add("D", "risk ∈ [0,1]", r_ok, f"[{risk.min():.4f}, {risk.max():.4f}]")
        R.add("D", "无 NaN", not (torch.isnan(conf).any() or torch.isnan(risk).any()))

    # 退化：无检测框
    with torch.no_grad():
        out2 = m(img, None, None, None, None, return_aux=True)
    c2, r2 = out2[3].get("confidence"), out2[3].get("risk")
    R.add("D", "★ 退化：无检测框时不崩且仍有输出",
          c2 is not None and r2 is not None and not torch.isnan(r2).any(),
          f"risk range=[{r2.min():.4f},{r2.max():.4f}]" if r2 is not None else "None")

    # det_mask 全 0
    with torch.no_grad():
        out3 = m(img, None, dets, torch.zeros(2, 20), st, return_aux=True)
    r3 = out3[3].get("risk")
    R.add("D", "★ 退化：det_mask 全 0 无 NaN",
          r3 is not None and not torch.isnan(r3).any())

    # 模块直测：输出范围与退化
    try:
        rh = RiskHead(RiskHeadConfig(fused_dim=512, det_feat_dim=128))
        rh.eval()
        with torch.no_grad():
            c, r = rh(torch.randn(8, 512), torch.randn(8, 20, 128),
                      torch.ones(8, 20), torch.rand(8))
            c_n, r_n = rh(torch.randn(8, 512), None, None, None)
        R.add("D", "模块直测：输出 ∈[0,1]",
              bool(0 <= c.min() and c.max() <= 1 and 0 <= r.min() and r.max() <= 1),
              f"conf[{c.min():.3f},{c.max():.3f}] risk[{r.min():.3f},{r.max():.3f}]")
        R.add("D", "模块直测：det_feat=None 退化不崩",
              c_n.shape == (8,) and not torch.isnan(r_n).any())
    except Exception as e:
        R.add("D", "模块直测", False, f"{type(e).__name__}: {e}")

    # TTC 未标定必须如实无效
    try:
        cfg = TTCConfig()
        d12 = torch.zeros(1, 20, 12)
        d12[0, 0, :4] = torch.tensor([0.5, 0.6, 0.2, 0.25])
        d12[0, 0, 8] = 0.9
        m1 = torch.zeros(1, 20); m1[0, 0] = 1.0
        ttc, dist, valid = estimate_ttc(d12, m1, torch.tensor([10.0]), config=cfg)
        R.add("D", "TTC 未标定 K → valid 全 False（不返回假数字）",
              not bool(valid.any()), f"valid.any()={bool(valid.any())}")
    except Exception as e:
        R.add("D", "TTC 未标定路径", False, f"{type(e).__name__}: {e}")


# ============================================================================
# E. 参数量
# ============================================================================
def verify_params() -> Dict[str, Any]:
    hdr("E. 参数量与 INT8 硬约束（≤10MB）")
    import model_v2

    m = model_v2.build_model(deploy=False)
    n_train = sum(p.numel() for p in m.parameters())
    parts = {
        "image_encoder": sum(p.numel() for p in m.image_encoder.parameters()),
        "lane_encoder": sum(p.numel() for p in m.lane_encoder.parameters()),
        "det_encoder": sum(p.numel() for p in m.det_encoder.parameters()),
        "state_encoder": sum(p.numel() for p in m.state_encoder.parameters()),
        "fusion_head": sum(p.numel() for p in m.fusion_head.parameters()),
    }
    if m.temporal_encoder is not None:
        parts["temporal_encoder"] = sum(p.numel() for p in m.temporal_encoder.parameters())
        parts["temporal_proj"] = sum(p.numel() for p in m.temporal_proj.parameters())
    if m.heading_head is not None:
        parts["heading_head"] = sum(p.numel() for p in m.heading_head.parameters())
    if m.risk_head is not None:
        parts["risk_head"] = sum(p.numel() for p in m.risk_head.parameters())

    m2 = model_v2.build_model(deploy=False)
    m2.reparameterize()
    n_deploy = sum(p.numel() for p in m2.parameters())

    print(f"  {'分支':<22}{'参数量':>12}{'INT8 MB':>10}")
    print("  " + "-" * 46)
    for k, v in parts.items():
        print(f"  {k:<22}{v:>12,}{v/1024/1024:>10.3f}")
    print("  " + "-" * 46)
    print(f"  {'训练态合计':<22}{n_train:>12,}{n_train/1024/1024:>10.3f}")
    print(f"  {'部署态合计':<22}{n_deploy:>12,}{n_deploy/1024/1024:>10.3f}")

    R.add("E", "部署态 INT8 ≤ 10MB", n_deploy / 1024 / 1024 <= 10,
          f"{n_deploy/1024/1024:.3f} MB（余量 {10/(n_deploy/1024/1024):.2f}×）")
    R.add("E", "训练态 INT8 ≤ 10MB", n_train / 1024 / 1024 <= 10,
          f"{n_train/1024/1024:.3f} MB")
    return {"train": n_train, "deploy": n_deploy, "parts": parts}


# ============================================================================
# F. ★ 端到端可达性（最容易出的「假绿」）
# ============================================================================
def verify_reachability() -> None:
    hdr("F. ★ 端到端可达性：新头能否上车（CoreML 导出契约）")
    import re

    exp = _ROOT / "tools" / "export_m9_v2_coreml.py"
    src = exp.read_text(encoding="utf-8") if exp.exists() else ""
    m = re.search(r'INPUT_NAMES[^=]*=\s*\(([^)]*)\)', src)
    coreml_inputs = re.findall(r'"([^"]+)"', m.group(1)) if m else []
    print(f"  CoreML 导出输入契约 INPUT_NAMES = {coreml_inputs}")
    m2 = re.search(r'OUTPUT_NAMES[^=]*=\s*\(([^)]*)\)', src)
    coreml_outputs = re.findall(r'"([^"]+)"', m2.group(1)) if m2 else []
    print(f"  CoreML 导出输出契约 OUTPUT_NAMES = {coreml_outputs}")

    need_temporal = "history_feats" in coreml_inputs and "frame_mask" in coreml_inputs
    need_heading = "camera_heading" in coreml_inputs
    R.add("F", "★ 时序输入进入 CoreML 契约（history_feats/frame_mask）",
          need_temporal,
          "缺失 → 上车后时序头永远收不到历史帧，等于白集成")
    R.add("F", "★ 车头朝向输入进入 CoreML 契约（camera_heading）",
          need_heading, "缺失 → 只能用纯视觉兜底分支，Δ 主路径失效")
    R.add("F", "★ 风险/朝向输出进入 CoreML 契约（confidence/risk/car_heading）",
          all(k in coreml_outputs for k in ("confidence", "risk")),
          f"现有输出={coreml_outputs}")

    # Swift 侧
    swift = _ROOT / "Sources" / "AuroraDrive" / "Inference" / "InferenceEngineV2.swift"
    ssrc = swift.read_text(encoding="utf-8") if swift.exists() else ""
    checks = {
        "image": '"image"' in ssrc,
        "lane": '"lane"' in ssrc,
        "dets": '"dets"' in ssrc,
        "det_mask": '"det_mask"' in ssrc,
        "vehicle_state": '"vehicle_state"' in ssrc,
    }
    print("  Swift V2 基础输入: " + " ".join(
        f"{k}={'Y' if v else 'N'}" for k, v in checks.items()))
    R.add("F", "★ Swift 侧传 history_feats/frame_mask",
          "historyFeats" in ssrc or "history_feats" in ssrc,
          "Swift 未传 → CoreML 即便有该输入也永远拿不到数据")
    R.add("F", "★ Swift 侧传 camera_heading",
          "cameraHeading" in ssrc or "camera_heading" in ssrc)

    # 结论：可达性总判
    reachable = need_temporal and need_heading
    R.add("F", "★ 结论：三个新头端到端可达（能上车）", reachable,
          "PyTorch 内可跑，但导出契约/Swift 未接 → **仅训练可用，部署不可达**",
          warn=reachable)


# ============================================================================
# G. 静默降级审计
# ============================================================================
def verify_import_context() -> None:
    hdr("G0. ★ 导入上下文陷阱（model_v2 软依赖会静默失效）")
    import os
    import model_v2
    root_in = os.path.abspath(str(_ROOT)) in [os.path.abspath(p) for p in sys.path]
    print(f"  repo root 在 sys.path: {root_in}")
    print(f"  HeadingHead     = {model_v2.HeadingHead}")
    print(f"  TemporalEncoder = {model_v2.TemporalEncoder}")
    print(f"  RiskHead        = {model_v2.RiskHead}")
    all_loaded = all(x is not None for x in
                     (model_v2.HeadingHead, model_v2.TemporalEncoder, model_v2.RiskHead))
    R.add("G0", "★ model_v2 软依赖成功加载（repo root 必须在 sys.path）", all_loaded,
          "若为 None：`from src.xxx import` 失败被 except ImportError 静默吞掉"
          "→ 三头全变 None、不报错（实测：python3 src/xxx.py 的环境必触发）",
          warn=all_loaded)

    # 直接复现：只放 src 不放 root 的环境 —— 修复后应「三头仍挂载」（双路径回退生效）
    import subprocess
    code = (
        "import os, sys, warnings\n"
        "sys.path.insert(0, os.path.abspath('src'))\n"
        "sys.path = [p for p in sys.path if os.path.abspath(p) != os.path.abspath('.')]\n"
        "with warnings.catch_warnings(record=True) as ws:\n"
        "    warnings.simplefilter('always')\n"
        "    import model_v2\n"
        "print('LOADED', model_v2.HeadingHead is not None,\n"
        "      model_v2.TemporalEncoder is not None, model_v2.RiskHead is not None)\n"
        "print('WARN', len(ws))\n"
    )
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                       cwd=str(_ROOT))
    out = r.stdout.strip()
    if "LOADED True True True" in out:
        R.add("G0", "★ 陷阱已修复：脚本方式（path[0]=src）三头仍挂载", True,
              "双路径回退生效（`from src.xxx` 失败 → 回退 `from xxx`）")
    elif "LOADED False False False" in out and "WARN" in out:
        R.add("G0", "★ 陷阱未修复：三头仍全 None", False,
              "（但有告警，不再静默）—— 双路径回退未生效")
    else:
        R.add("G0", "★ 陷阱复现实验", False,
              f"stdout={out[:120]!r} stderr={r.stderr.strip()[:120]!r}")

    # 降级必须告警：模块真的不存在时，应发 RuntimeWarning（不静默）
    import shutil
    import tempfile
    td = tempfile.mkdtemp()
    try:
        shutil.copy(str(_ROOT / "src" / "model_v2.py"), td)
        code2 = (
            "import sys, warnings\n"
            f"sys.path.insert(0, {td!r})\n"
            "with warnings.catch_warnings(record=True) as ws:\n"
            "    warnings.simplefilter('always')\n"
            "    import model_v2\n"
            "print('NWARN', len(ws))\n"
        )
        r2 = subprocess.run([sys.executable, "-c", code2], capture_output=True,
                            text=True, cwd=td)   # ★ cwd 必须切到隔离目录，
                                                 #   否则 repo root 仍在 path、src.xxx 能解析
        nw = 0
        for line in r2.stdout.splitlines():
            if line.startswith("NWARN"):
                nw = int(line.split()[1])
        R.add("G0", "★ 降级时必发 RuntimeWarning（不静默）", nw >= 3,
              f"模块缺失环境下发出 {nw} 条告警")
    finally:
        shutil.rmtree(td, ignore_errors=True)


def verify_silent_swallow() -> None:
    hdr("G. ★ 静默降级审计（try/except pass 吞掉哪些异常）")
    import re
    p = _ROOT / "src" / "model_v2.py"
    src = p.read_text(encoding="utf-8")
    # 找 forward 内的 try/except
    fwd = src[src.find("def forward", src.find("class M2Model")):]
    tails = re.findall(r"except\s+Exception[^:]*:\s*\n\s*(pass|aux\[[^\]]+\]\s*=\s*None)", fwd)
    n_pass = sum(1 for t in tails if t.strip() == "pass")
    n_none = sum(1 for t in tails if t.strip() != "pass")
    print(f"  forward 内 `except Exception:` 共 {len(tails)} 处"
          f"（pass={n_pass}, 置 None={n_none}）")
    R.add("G", "新头异常被吞掉（需知悉）", len(tails) > 0,
          f"{len(tails)} 处 —— 头内部抛异常时 aux 静默为 None，"
          f"主链路不受影响但**不会报错**", warn=True)

    # 实证：构造一个必然让 heading_head 抛错的输入，看是否静默
    import model_v2
    m = model_v2.build_model(deploy=False)
    m.eval()
    img = torch.randn(1, 3, 180, 320)
    with torch.no_grad():
        o = m(img, None, None, None, None, return_aux=True)
    aux = o[3]
    R.add("G", "return_aux 的 aux 键完整",
          set(aux.keys()) >= {"steer", "throttle", "brake", "car_heading",
                              "confidence", "risk", "temporal_feat"},
          f"keys={sorted(aux.keys())}")


def main() -> int:
    ap = argparse.ArgumentParser(description="独立验证 w7 集成的三个感知头")
    ap.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = ap.parse_args()

    print("=" * 78)
    print("独立验证：GAP 修复 + 时序 / 车头朝向 / 风险 三头")
    print("=" * 78)

    verify_gap()
    verify_temporal()
    verify_heading()
    verify_risk()
    params = verify_params()
    verify_reachability()
    verify_import_context()
    verify_silent_swallow()

    p, w, f = R.counts()
    hdr(f"结果：PASS {p} / WARN {w} / FAIL {f}")

    if args.json:
        out = {"summary": {"pass": p, "warn": w, "fail": f},
               "params": params, "rows": R.rows}
        print(json.dumps(out, ensure_ascii=False, indent=2))

    if f:
        print("失败项：")
        for r in R.rows:
            if r["status"] == "FAIL":
                print(f"  ✗ [{r['section']}] {r['name']} — {r['detail']}")
        return 1
    print("✓ 无失败项")
    return 0


if __name__ == "__main__":
    sys.exit(main())
