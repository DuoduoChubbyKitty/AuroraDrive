#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 最终方案 · 混合分辨率端到端实测（第六组实验，收官）。

这是**本报告推荐的架构**在真实 CoreML 图上的实测：
  输入  x_hi: [3, 3, 224, 384]   最近 3 帧高清
        x_lo: [21, 3, 112, 192]  前 21 帧低清
        s_t1: [1, 4]             t-1 四标量（steer/throttle/brake/speed）
  处理  高清 → 完整 ImageEncoder（共享骨干）      → [3,256]
        低清 → 共享骨干前 2 层 + GAP + proj      → [21,256]
        拼接时间序 [t-1..t-24]                    → [1,24,256] → [1,24,128]
        层级时序（3 段 × 8 帧，组内 Conv + 组间 TCN）→ 历史摘要 [1,128]
        state token = Linear(cat[t-1 四标量, 历史摘要]) → [1,128]
        当前帧特征 + 历史摘要残差注入               → [1,256]
        小输出头 → steer/throttle/brake
  测量  参数量 / MACs / 算子数与 ANE 派发 / 真机延迟（ALL vs CPU_ONLY）

对照：24 帧全部过完整骨干（已测 4.931ms / 21.7 GMACs）。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/07_hybrid_e2e.py
"""

from __future__ import annotations

import json
import statistics
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import coremltools as ct  # noqa: E402
from src.model_v2 import ImageEncoder  # noqa: E402
from importlib import import_module  # noqa: E402

_budget = import_module("01_budget")
MacCounter = _budget.MacCounter


# ----------------------------------------------------------------------------
class SharedTruncatedBackbone(nn.Module):
    """复用 ImageEncoder 的前 stages 层（**同一个 nn.Module 实例，真共享**）。

    与 06 脚本里的 TruncatedBackbone 区别：这里直接持有一个 ImageEncoder，
    低清路径只调它的 stage0/stage1 —— 权重真共享，参数量只算一次。
    新增参数 = 只有最后的 proj（out_ch → 256）。
    """

    def __init__(self, base: ImageEncoder, stages: int = 2, out_dim: int = 256):
        super().__init__()
        self.base = base                     # 共享骨干
        self.stages = stages
        self.out_ch = {1: 48, 2: 48, 3: 96, 4: 192, 5: out_dim}[stages]
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))
        self.proj = nn.Linear(self.out_ch, out_dim)

    def forward(self, x):
        h = self.base.stage0(x)
        h = self.base.stage1(h)
        if self.stages >= 3:
            h = self.base.stage2(h)
        h = self.global_pool(h).flatten(1)
        return self.proj(h)


class HierTemporalTCN(nn.Module):
    """层级时序：3 段 × 8 帧，组内 Conv1d(k=8,s=8) → 3 组 token → 组间因果 TCN。"""

    def __init__(self, in_dim: int = 256, hidden: int = 128, steps: int = 24,
                 group: int = 8, inter_layers: int = 2, kernel: int = 3):
        super().__init__()
        self.group = group
        self.n_groups = steps // group
        self.in_proj = nn.Linear(in_dim, hidden)
        self.intra = nn.Conv1d(hidden, hidden, kernel_size=group, stride=group)
        self.layers = nn.ModuleList()
        self.pads = []
        d = 1
        for _ in range(inter_layers):
            self.layers.append(nn.Conv1d(hidden, hidden, kernel, dilation=d))
            self.pads.append((kernel - 1) * d)
            d *= 2
        self.act = nn.ReLU()
        self.norm = nn.LayerNorm(hidden)

    def forward(self, seq):                  # [1,24,256]
        x = self.in_proj(seq).transpose(1, 2)          # [1,128,24]
        x = self.act(self.intra(x))                    # [1,128,3]
        for conv, pad in zip(self.layers, self.pads):
            x = self.act(conv(nn.functional.pad(x, (pad, 0))))
        return self.norm(x[:, :, -1])                  # [1,128]


class HybridV3Model(nn.Module):
    """V3 推荐架构（混合分辨率 + 层级时序 + 论文式 state token 增强）。"""

    def __init__(self, hi_frames: int = 3, lo_frames: int = 21,
                 trunc_stages: int = 2, hidden: int = 128, img_dim: int = 256):
        super().__init__()
        self.hi_frames, self.lo_frames = hi_frames, lo_frames
        self.img_dim = img_dim
        # 共享骨干：高清走完整，低清只走前 trunc_stages 层
        self.backbone = ImageEncoder(deploy=True, out_dim=img_dim)
        self.lo_branch = SharedTruncatedBackbone(self.backbone, stages=trunc_stages,
                                                 out_dim=img_dim)
        # 层级时序
        self.temporal = HierTemporalTCN(in_dim=img_dim, hidden=hidden,
                                        steps=hi_frames + lo_frames, group=8,
                                        inter_layers=2)
        # state token：t-1 四标量 + 历史摘要 → hidden
        self.state_token = nn.Linear(4 + hidden, hidden)
        # 历史摘要 → 图像特征维度的残差注入（**零初始化**，沿用项目 temporal_proj 教训：
        # 随机初始化会 7.8~50 倍淹没主干）
        self.hist_proj = nn.Linear(hidden, img_dim)
        nn.init.zeros_(self.hist_proj.weight)
        nn.init.zeros_(self.hist_proj.bias)
        # 输出头
        self.head = nn.Sequential(
            nn.Linear(img_dim, 128), nn.ReLU(),
            nn.Linear(128, 3),
        )
        # 供 aux 输出（让 state token 参与计算，避免被 DCE 删除）
        self.state_out = nn.Linear(hidden, 1)

    def forward(self, x_hi, x_lo, s_t1):
        # ① 高清 3 帧 → [3,256]
        f_hi = self.backbone(x_hi)
        # ② 低清 21 帧 → [21,256]（共享骨干前 2 层）
        f_lo = self.lo_branch(x_lo)
        # ③ 按时间序拼：t-1..t-3 高清，t-4..t-24 低清 → [1,24,256]
        seq = torch.cat([f_hi, f_lo], dim=0).unsqueeze(0)
        # ④ 层级时序 → 历史摘要 [1,128]
        hist = self.temporal(seq)
        # ⑤ state token（论文式：t-1 四标量 + 历史摘要）
        state_token = self.state_token(torch.cat([s_t1, hist], dim=-1))   # [1,128]
        # ⑥ 当前帧（最近高清）特征 + 历史摘要残差注入（零初始化 → 起步为 0）
        cur = f_hi[-1:, :]                                              # [1,256]
        fused = cur + self.hist_proj(hist)
        # ⑦ 输出
        ctrl = self.head(fused)                                         # [1,3]
        return ctrl, state_token


def _dev_key(usage):
    if usage is None:
        return "const"
    dev = getattr(usage, "preferred_compute_device", None)
    if dev is None:
        return "const"
    cls = type(dev).__name__
    if "NeuralEngine" in cls:
        return "neuralEngine"
    if "GPU" in cls:
        return "gpu"
    if "CPU" in cls:
        return "cpu"
    return cls


def count_macs(module, input_shapes):
    """用 forward hook 统计 MACs（Conv2d/Conv1d/Linear）。"""
    counter = MacCounter(module)
    module.eval()
    with torch.no_grad():
        module(*[torch.zeros(*s) for s in input_shapes])
    counter.close()
    return counter.macs


def bench(pkg, inputs: dict, units, warmup=15, runs=80):
    model = ct.models.MLModel(pkg, compute_units=units)
    for _ in range(warmup):
        model.predict(inputs)
    ts = []
    for _ in range(runs):
        t0 = time.perf_counter()
        model.predict(inputs)
        ts.append((time.perf_counter() - t0) * 1000)
    ts.sort()
    return {"p50": round(statistics.median(ts), 4),
            "p95": round(ts[int(len(ts) * 0.95) - 1], 4),
            "min": round(ts[0], 4)}


def main() -> int:
    tmpdir = Path(tempfile.mkdtemp(prefix="v3_hybrid_"))
    results = {}

    shapes = {
        "x_hi": (3, 3, 224, 384),
        "x_lo": (21, 3, 112, 192),
        "s_t1": (1, 4),
    }
    inputs_np = {k: np.zeros(s, dtype=np.float32) for k, s in shapes.items()}

    print("=" * 86)
    print("V3 推荐架构：3 高清(224x384) + 21 低清(112x192) + 层级时序 + state token")
    print("=" * 86)

    model = HybridV3Model().eval()
    total_params = sum(p.numel() for p in model.parameters())
    backbone_params = sum(p.numel() for p in model.backbone.parameters())
    print(f"  总参数量          {total_params:>10,}")
    print(f"    其中共享骨干     {backbone_params:>10,}（高清/低清共用，**不重复计**）")
    print(f"    时序模块新增     {sum(p.numel() for p in model.temporal.parameters()):>10,}")
    print(f"    低清新增(proj)   {sum(p.numel() for p in model.lo_branch.parameters()) - backbone_params:>10,}")
    print(f"    state token      {sum(p.numel() for p in model.state_token.parameters()):>10,}")
    print(f"    历史注入+输出头   "
          f"{sum(p.numel() for p in model.hist_proj.parameters()) + sum(p.numel() for p in model.head.parameters()):>10,}")

    macs = count_macs(model, [shapes["x_hi"], shapes["x_lo"], shapes["s_t1"]])
    print(f"  总 MACs           {macs/1e9:>10.2f} G")
    print(f"  对照 24 帧全骨干   21.67 G（已实测）→ 本方案为其 {macs/21668.29e6:.1%}")

    results["params"] = {
        "total": total_params,
        "backbone_shared": backbone_params,
        "temporal_new": sum(p.numel() for p in model.temporal.parameters()),
        "lo_branch_new": sum(p.numel() for p in model.lo_branch.parameters()) - backbone_params,
        "state_token": sum(p.numel() for p in model.state_token.parameters()),
        "hist_proj_and_head": (sum(p.numel() for p in model.hist_proj.parameters())
                              + sum(p.numel() for p in model.head.parameters())),
    }
    results["macs"] = {"hybrid": macs, "ratio_vs_24f_full": round(macs / 21668.29e6, 4)}

    # ---- 导出 ----
    with torch.no_grad():
        traced = torch.jit.trace(
            model,
            (torch.zeros(*shapes["x_hi"]), torch.zeros(*shapes["x_lo"]),
             torch.zeros(*shapes["s_t1"])),
            strict=False)
    mlm = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="x_hi", shape=shapes["x_hi"], dtype=np.float32),
            ct.TensorType(name="x_lo", shape=shapes["x_lo"], dtype=np.float32),
            ct.TensorType(name="s_t1", shape=shapes["s_t1"], dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    pkg = str(tmpdir / "hybrid_v3.mlpackage")
    mlm.save(pkg)
    print(f"\n  导出成功：{pkg}")

    # ---- 算子级派发 ----
    from coremltools.models.compute_plan import MLComputePlan
    mm = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
    plan = MLComputePlan.load_from_path(mm.get_compiled_model_path(),
                                        compute_units=ct.ComputeUnit.ALL)
    ops = list(plan.model_structure.program.functions["main"].block.operations)
    counts = {}
    for op in ops:
        k = _dev_key(plan.get_compute_device_usage_for_mlprogram_operation(op))
        counts[k] = counts.get(k, 0) + 1
    analyzed = sum(v for k, v in counts.items() if k != "const")
    print(f"  算子总数 {len(ops)}（const {counts.get('const',0)} / 可分析 {analyzed}）")
    print(f"  派发 {counts}  → ANE 占比 {counts.get('neuralEngine',0)/max(analyzed,1):.1%}")
    results["dispatch"] = {"total_ops": len(ops), "by_device": counts,
                           "analyzed": analyzed,
                           "ane_ratio": round(counts.get("neuralEngine", 0) / max(analyzed, 1), 4)}

    # ---- 延迟 ----
    print()
    all_u = bench(pkg, inputs_np, ct.ComputeUnit.ALL)
    cpu_u = bench(pkg, inputs_np, ct.ComputeUnit.CPU_ONLY)
    speedup = round(cpu_u["p50"] / max(all_u["p50"], 1e-9), 2)
    print(f"  ALL      p50={all_u['p50']:.3f}ms p95={all_u['p95']:.3f}ms min={all_u['min']:.3f}ms")
    print(f"  CPU_ONLY p50={cpu_u['p50']:.3f}ms p95={cpu_u['p95']:.3f}ms")
    print(f"  ANE 加速 {speedup}×")
    results["timing"] = {"ALL": all_u, "CPU_ONLY": cpu_u, "speedup": speedup}

    # ---- 真机试跑：数值合理性 ----
    out = mm.predict(inputs_np)
    for k, v in out.items():
        arr = np.asarray(v)
        print(f"  输出 {k}: shape={arr.shape} finite={np.isfinite(arr).all()}")

    # 对照：24 帧全骨干（数字来自 04_timing 实测）
    print()
    print("  对照（04_timing.py 实测，同一测量口径）：")
    print("    24 帧全 180x320 过同一完整骨干  4.931ms p50 / 5.532ms p95 / 21.67 GMACs")
    print(f"    本方案                          {all_u['p50']:.3f}ms p50 / "
          f"{all_u['p95']:.3f}ms p95 / {macs/1e9:.2f} GMACs")
    print(f"    延迟比 {4.931/max(all_u['p50'],1e-9):.2f}× 更快，算力为其 {macs/21668.29e6:.1%}")

    out_path = Path(__file__).resolve().parent / "07_hybrid_e2e_result.json"
    out_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out_path}")
    print(f"临时目录：{tmpdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
