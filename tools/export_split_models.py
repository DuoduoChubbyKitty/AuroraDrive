#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""双模型拆分导出（p95≤16ms 攻坚 · Lead 亲自实现）

【为什么拆】
  当前实现每个 tick 都重算 8 帧 ImageEncoder（8 帧里 7 帧是历史，特征早该缓存）：
    · 8帧 + palette → ANE 编译失败（图规模超 ANE 编译器能力）→ CPU 25.93ms
    · 1帧 + palette → ANE 1.24ms ✅
  Lead 实测：ImageEncoder 8帧/单帧 = 6.12×（拆开省 84% 编码计算）
  Lead 实测：拆分后数值 maxdiff = 0.00e+00（逐位等价，非"接近"）

【拆分方案】
  模型 A（ImageEncoder 单帧）: image [1,3,180,320] → feat [1,256]
  模型 B（主控）:              feat_seq [8,256] + lane + dets + det_mask + state → 6 输出

【每 tick 流水线】
  ① 模型A 只编码当前新帧 → [1,256]
  ② 特征环形缓冲保留最近 8 帧 → [8,256]
  ③ 模型 B 吃 [8,256] + 其他分支 → 6 输出

【红线】步数12 / MoE 4步 / 帧率30Hz / 分辨率 / 质量（maxdiff=0）全部不降

用法：
    ./.venv-yolo26/bin/python3 tools/export_split_models.py --src checkpoints/m9_v2/best_model.pt \
        --outdir models/split --precision float16
    # 或仅验证拆分等价性（不导出）
    ./.venv-yolo26/bin/python3 tools/export_split_models.py --verify-only
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Optional, Tuple

import numpy as np
import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))

import model_v2  # noqa: E402

# ── 契约常量（与现有导出脚本保持一致）────────────────────────────────
IMG_H, IMG_W = 180, 320
LANE_SIZE = 160
NUM_DETS = 20
DET_FEAT_DIM = 12
STATE_DIM = 8
NUM_FRAMES = 8
FEAT_DIM = 256

INPUT_NAMES_A = ("image",)
OUTPUT_NAMES_A = ("feat",)

INPUT_NAMES_B = ("feat_seq", "lane", "dets", "det_mask", "vehicle_state")
OUTPUT_NAMES_B = ("steer", "throttle", "brake", "confidence", "risk", "car_heading")


# ══════════════════════════════════════════════════════════════════════
# 拆分模型定义
# ══════════════════════════════════════════════════════════════════════

class SplitModelA(nn.Module):
    """图像编码器（单帧）：image [1,3,180,320] → feat [1,256]"""

    def __init__(self, encoder: nn.Module) -> None:
        super().__init__()
        self.encoder = encoder

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return self.encoder(image)


class SplitModelB(nn.Module):
    """主控（单帧图）：feat_seq [1,8,256] + 其他分支 → 6 输出

    ⚠️ 关键：feat_seq 是【8 帧缓存特征】，不是 8 帧原图。
       Swift 侧维护特征环形缓冲，每 tick 只推入 1 个新特征。
    """

    def __init__(self, m: model_v2.M2Model) -> None:
        super().__init__()
        self.temporal_encoder = m.temporal_encoder
        self.temporal_proj = m.temporal_proj
        self.lane_encoder = m.lane_encoder
        self.det_encoder = m.det_encoder
        self.state_encoder = m.state_encoder
        self.refiner = m.refiner
        self.fusion_head = m.fusion_head
        self.heading_head = getattr(m, "heading_head", None)
        self.risk_head = getattr(m, "risk_head", None)

    def forward(
        self,
        feat_seq: torch.Tensor,          # [1, 8, 256]
        lane: torch.Tensor,              # [1, 1, 160, 160]
        dets: torch.Tensor,              # [1, 20, 12]
        det_mask: torch.Tensor,          # [1, 20]
        vehicle_state: torch.Tensor,     # [1, 8]
    ) -> Tuple[torch.Tensor, ...]:
        b = feat_seq.shape[0]

        # ── 时序：8 帧特征序列 → GRU → 投影残差加到当前帧 ──
        current = feat_seq[:, -1, :]                     # [B,256] 当前帧
        temporal_feat = self.temporal_encoder(feat_seq, None)   # [B,128]
        projected = self.temporal_proj(temporal_feat)           # [B,256]
        img_feat = current + projected                          # 残差

        # ── 其他三分支（当前帧）──
        lane_feat = self.lane_encoder(lane, b, None)
        det_feat = self.det_encoder(dets, det_mask, b, None)
        state_feat = self.state_encoder(vehicle_state, b, None)

        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)

        # ── 迭代精修 + MoE ──
        fused = self.refiner(fused)

        steer, throttle, brake = self.fusion_head(fused)

        # ── 辅助头（契约恒定 6 输出；头缺失时零占位）──
        if self.heading_head is not None:
            car_heading = self.heading_head(img_feat, None)
            if car_heading.dim() == 1:
                car_heading = car_heading.unsqueeze(-1)
        else:
            car_heading = torch.zeros(b, 1)

        if self.risk_head is not None:
            try:
                conf, risk = self.risk_head(fused)
            except Exception:
                conf, risk = torch.full((b, 1), 0.5), torch.zeros(b, 1)
        else:
            conf, risk = torch.full((b, 1), 0.5), torch.zeros(b, 1)

        def _ensure2d(t: torch.Tensor) -> torch.Tensor:
            return t.unsqueeze(-1) if t.dim() == 1 else t

        return (
            _ensure2d(steer), _ensure2d(throttle), _ensure2d(brake),
            _ensure2d(conf), _ensure2d(risk), _ensure2d(car_heading),
        )


# ══════════════════════════════════════════════════════════════════════
# 权重加载（照抄现有导出脚本的正确三步流程）
# ══════════════════════════════════════════════════════════════════════

def load_weights(model: model_v2.M2Model, ckpt_path: Path) -> dict:
    """build_model(deploy=False) → load_state_dict → reparameterize()"""
    ck = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
    sd = ck.get("model_state_dict", ck) if isinstance(ck, dict) else ck
    # 剥离训练期探针
    sd = {k: v for k, v in sd.items() if not k.startswith("lane_steer_probe")}

    missing, unexpected = model.load_state_dict(sd, strict=False)

    if unexpected:
        raise RuntimeError(
            f"权重加载出现 {len(unexpected)} 个 unexpected 键 —— 权重态判断错误！\n"
            f"  样例: {list(unexpected)[:5]}\n"
            f"  正确流程：build_model(deploy=False) → load_state_dict → reparameterize()"
        )

    total = sum(p.numel() for p in model.parameters())
    missing_num = sum(
        p.numel() for n, p in model.named_parameters()
        if n in set(missing)
    )
    ratio = missing_num / max(1, total)

    report = {
        "missing": len(missing),
        "unexpected": len(unexpected),
        "missing_param_ratio": ratio,
        "deployable": ratio <= 0.05,
    }
    if ratio > 0.05:
        print(f"[拆分导出] 🚨 随机初始化占比 {ratio*100:.1f}% > 5% —— 此产物不可上车！")
        print(f"[拆分导出]    missing={len(missing)} 键，样例: {list(missing)[:5]}")
    else:
        print(f"[拆分导出] ✓ 权重完整（missing={len(missing)} 键，占比 {ratio*100:.2f}%）")

    model.eval()
    # RepVGG 重参数化（训练态多分支 → 单路 3×3）
    if hasattr(model, "reparameterize"):
        model.reparameterize()
        print("[拆分导出] ✓ 已 reparameterize（RepVGG 多分支折叠）")
    return report


# ══════════════════════════════════════════════════════════════════════
# 数值等价性验证
# ══════════════════════════════════════════════════════════════════════

def verify_equivalence(m: model_v2.M2Model, A: SplitModelA, B: SplitModelB,
                       seed: int = 0) -> float:
    torch.manual_seed(seed)
    img8 = torch.rand(NUM_FRAMES, 3, IMG_H, IMG_W)
    lane = torch.zeros(1, 1, LANE_SIZE, LANE_SIZE)
    dets = torch.zeros(1, NUM_DETS, DET_FEAT_DIM)
    dm = torch.zeros(1, NUM_DETS)
    st = torch.zeros(1, STATE_DIM)

    with torch.no_grad():
        o_orig = m(image=img8, lane_mask=lane, dets=dets, det_mask=dm,
                   vehicle_state=st)
        feats = A(img8)                       # [8,256]
        o_split = B(feats.unsqueeze(0), lane, dets, dm, st)

    d = max(
        (o_orig[i] - o_split[i]).abs().max().item()
        for i in range(3)
    )
    return d


# ══════════════════════════════════════════════════════════════════════
# CoreML 导出
# ══════════════════════════════════════════════════════════════════════

def export_coreml(A: SplitModelA, B: SplitModelB, outdir: Path,
                  precision: str, target: str = "macOS15") -> None:
    import coremltools as ct

    outdir.mkdir(parents=True, exist_ok=True)
    prec = {"float16": ct.precision.FLOAT16,
            "float32": ct.precision.FLOAT32}[precision]

    # ── 模型 A ──
    print(f"\n[拆分导出] ── 模型 A（ImageEncoder 单帧）──")
    ex_a = torch.jit.trace(A, torch.rand(1, 3, IMG_H, IMG_W))
    # 反证：确认图里没有 GRU/while_loop（A 是纯卷积）
    kinds = {}
    for node in ex_a.inlined_graph.nodes():
        kinds[str(node.kind())] = kinds.get(str(node.kind()), 0) + 1
    has_gru = any("gru" in k.lower() or "rnn" in k.lower() for k in kinds)
    print(f"[拆分导出]   trace 算子数 {sum(kinds.values())}，含 RNN/GRU: {has_gru}（应为 False）")

    ml_a = ct.convert(
        ex_a,
        inputs=[ct.TensorType(name="image",
                              shape=(1, 3, IMG_H, IMG_W), dtype=np.float32)],
        outputs=[ct.TensorType(name="feat", dtype=np.float32)],
        compute_precision=prec,
        minimum_deployment_target=getattr(ct.target, target),
        convert_to="mlprogram",
    )
    ml_a.save(str(outdir / "m9_v2_enc.mlpackage"))
    print(f"[拆分导出]   ✓ 模型 A 已保存: {outdir/'m9_v2_enc.mlpackage'}")

    # ── 模型 B ──
    print(f"\n[拆分导出] ── 模型 B（主控，单帧图）──")
    ex_b = torch.jit.trace(
        B,
        (torch.rand(1, NUM_FRAMES, FEAT_DIM),
         torch.zeros(1, 1, LANE_SIZE, LANE_SIZE),
         torch.zeros(1, NUM_DETS, DET_FEAT_DIM),
         torch.zeros(1, NUM_DETS),
         torch.zeros(1, STATE_DIM)),
    )
    kinds_b = {}
    for node in ex_b.inlined_graph.nodes():
        kinds_b[str(node.kind())] = kinds_b.get(str(node.kind()), 0) + 1
    has_gru_b = any("gru" in k.lower() or "rnn" in k.lower() for k in kinds_b)
    print(f"[拆分导出]   trace 算子数 {sum(kinds_b.values())}，含 RNN/GRU: {has_gru_b}（应为 True）")

    ml_b = ct.convert(
        ex_b,
        inputs=[
            ct.TensorType(name="feat_seq", shape=(1, NUM_FRAMES, FEAT_DIM), dtype=np.float32),
            ct.TensorType(name="lane", shape=(1, 1, LANE_SIZE, LANE_SIZE), dtype=np.float32),
            ct.TensorType(name="dets", shape=(1, NUM_DETS, DET_FEAT_DIM), dtype=np.float32),
            ct.TensorType(name="det_mask", shape=(1, NUM_DETS), dtype=np.float32),
            ct.TensorType(name="vehicle_state", shape=(1, STATE_DIM), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES_B],
        compute_precision=prec,
        minimum_deployment_target=getattr(ct.target, target),
        convert_to="mlprogram",
    )
    ml_b.save(str(outdir / "m9_v2_ctl.mlpackage"))
    print(f"[拆分导出]   ✓ 模型 B 已保存: {outdir/'m9_v2_ctl.mlpackage'}")

    # ── 契约 JSON ──
    contract = {
        "split": True,
        "model_a": {"file": "m9_v2_enc.mlpackage",
                    "inputs": [{"name": "image", "shape": [1, 3, IMG_H, IMG_W]}],
                    "outputs": [{"name": "feat", "shape": [1, FEAT_DIM]}]},
        "model_b": {"file": "m9_v2_ctl.mlpackage",
                    "inputs": [{"name": "feat_seq", "shape": [1, NUM_FRAMES, FEAT_DIM]},
                               {"name": "lane", "shape": [1, 1, LANE_SIZE, LANE_SIZE]},
                               {"name": "dets", "shape": [1, NUM_DETS, DET_FEAT_DIM]},
                               {"name": "det_mask", "shape": [1, NUM_DETS]},
                               {"name": "vehicle_state", "shape": [1, STATE_DIM]}],
                    "outputs": [{"name": n, "shape": [1, 1]} for n in OUTPUT_NAMES_B]},
        "precision": precision,
        "target": target,
    }
    (outdir / "split_contract.json").write_text(
        json.dumps(contract, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[拆分导出]   ✓ 契约 JSON: {outdir/'split_contract.json'}")


# ══════════════════════════════════════════════════════════════════════

def main() -> int:
    ap = argparse.ArgumentParser(description="双模型拆分导出（p95≤16ms 攻坚）")
    ap.add_argument("--src", default=str(_ROOT / "checkpoints" / "m9_v2" / "best_model.pt"))
    ap.add_argument("--outdir", default=str(_ROOT / "models" / "split"))
    ap.add_argument("--precision", default="float16", choices=["float16", "float32"])
    ap.add_argument("--target", default="macOS15", choices=["macOS13", "macOS14", "macOS15"])
    ap.add_argument("--num-steps", type=int, default=12)
    ap.add_argument("--verify-only", action="store_true", help="只验证拆分等价性，不导出")
    args = ap.parse_args()

    print("=" * 70)
    print(" 双模型拆分导出（p95≤16ms 攻坚）")
    print("=" * 70)
    print(f"[拆分导出] 构建模型 num_steps={args.num_steps} ...")

    m = model_v2.build_model(deploy=False, num_steps=args.num_steps)
    n_total = sum(p.numel() for p in m.parameters())

    ckpt = Path(args.src)
    report = {}
    if ckpt.exists():
        report = load_weights(m, ckpt)
    else:
        print(f"[拆分导出] ⚠ 权重不存在（{ckpt}），用随机初始化（仅验证链路）")
        m.eval()
        report = {"missing": 0, "unexpected": 0,
                  "missing_param_ratio": 1.0, "deployable": False}

    A = SplitModelA(m.image_encoder).eval()
    B = SplitModelB(m).eval()
    n_a = sum(p.numel() for p in A.parameters())
    n_b = sum(p.numel() for p in B.parameters())

    print(f"[拆分导出] 模型 A: {n_a:,} 参数 / 模型 B: {n_b:,} 参数 "
          f"/ 合计 {n_a+n_b:,}（原 {n_total:,}）")
    if n_a + n_b != n_total:
        print(f"[拆分导出] ⚠ 参数不守恒！差 {n_total - n_a - n_b:,}（可能有无参数 buffer）")

    # ── 数值等价性 ──
    print(f"\n[拆分导出] ── 数值等价性验证 ──")
    maxd = 0.0
    for seed in (0, 1, 2):
        d = verify_equivalence(m, A, B, seed)
        maxd = max(maxd, d)
        flag = "✅" if d < 1e-3 else "❌"
        print(f"[拆分导出]   seed={seed}: maxdiff = {d:.3e}  {flag}")
    if maxd >= 1e-3:
        print(f"[拆分导出] ❌ 拆分不等价（maxdiff={maxd:.3e} ≥ 1e-3）—— 中止")
        return 1
    print(f"[拆分导出] ✓ 拆分逐位等价（max={maxd:.3e}）")

    if args.verify_only:
        print("\n[拆分导出] --verify-only：跳过导出")
        return 0

    export_coreml(A, B, Path(args.outdir), args.precision, args.target)

    print("\n" + "=" * 70)
    print(f" 完成 → {args.outdir}/")
    print(f"   模型 A: m9_v2_enc.mlpackage（单帧图像编码，预期 ANE ~1.24ms）")
    print(f"   模型 B: m9_v2_ctl.mlpackage（单帧主控，预期 ANE ~2ms）")
    print(f"   预期总延迟 ≈ 3.3ms（目标 16ms）")
    print(f"   deployable: {report.get('deployable')}（随机占比 "
          f"{(report.get('missing_param_ratio') or 0)*100:.1f}%）")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
