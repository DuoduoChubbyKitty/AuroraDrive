#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 骨干实测：参数量 / FLOPs / 逐层表 / 重参数化等价性 / ANE 逐算子派发

所有数字都来自本机实跑（Apple M3，16GB，macOS 27.0.1，torch 2.13.0，
coremltools 9.0）。**不联网、不启动 App、不建窗口。**

用法：
    /usr/local/bin/python3.11 tools/v3_exp/measure_backbone_v3.py            # 全部
    /usr/local/bin/python3.11 tools/v3_exp/measure_backbone_v3.py --no-ane   # 跳过 CoreML 编译

产出结果直接贴进 docs/v3-design/01-backbone.md。
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import warnings
from dataclasses import asdict
from pathlib import Path

warnings.filterwarnings("ignore")

import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROOT))

from tools.v3_exp.backbone_v3 import (          # noqa: E402
    BackboneConfig,
    build_v3_backbone,
)

OUT_DIR = Path("/tmp/v3_bb_measure")


# ═══════════════════════════════════════════════════════════════════════════
# 基础统计
# ═══════════════════════════════════════════════════════════════════════════

def count_params(model: nn.Module) -> int:
    """实测参数总量（只数 requires_grad 与否无关，全部参数）。"""
    return sum(p.numel() for p in model.parameters())


def section_params(model: nn.Module) -> dict:
    """按子模块分组统计参数量（用于 §4 参数分配表）。"""
    groups = {
        "backbone": model.backbone,
        "token_proj": model.token_proj,
        "state_lift": model.state_lift,
        "stage1": model.stage1,
        "stage2": model.stage2,
        "heads": nn.ModuleList([model.stop_go_head, model.ctrl_head]),
        "ccm": model.ccm,
        "pos_emb": None,      # 单独算
    }
    out = {}
    for name, mod in groups.items():
        if mod is None:
            out[name] = model.pos_emb.numel()
        else:
            out[name] = sum(p.numel() for p in mod.parameters())
    out["total"] = count_params(model)
    return out


def measure_flops(model: nn.Module, image: torch.Tensor, state: torch.Tensor) -> int:
    """用 torch 官方 FlopCounterMode 实测前向 FLOPs（macs×2）。

    FlopCounterMode 只统计 matmul/conv 类算子（不统计 elementwise），
    这是学术界通行口径；报告里需注明。
    """
    from torch.utils.flop_counter import FlopCounterMode

    model.eval()
    counter = FlopCounterMode(display=False)
    with torch.no_grad(), counter:
        model(image, state)
    return int(counter.get_total_flops())


def measure_latency(model: nn.Module, args: tuple, device: str,
                    warmup: int = 5, iters: int = 20) -> float:
    """本机耗时（ms/次）。device 只能是 'cpu' 或 'mps'。

    ⚠️ 这是**本机 M3 + PyTorch** 的参考值，不是 CoreML/ANE 真机延迟。
       它的用途是相对比较（哪个配置更重）；CoreML 真机延迟见 ane_probe()。
    """
    model = model.to(device).eval()
    dev_args = tuple(a.to(device) for a in args)
    with torch.no_grad():
        for _ in range(warmup):
            model(*dev_args)
        if device == "mps":
            torch.mps.synchronize()
        import time
        t0 = time.perf_counter()
        for _ in range(iters):
            model(*dev_args)
        if device == "mps":
            torch.mps.synchronize()
        dt = (time.perf_counter() - t0) / iters
    model.to("cpu")
    return dt * 1000.0


# ═══════════════════════════════════════════════════════════════════════════
# 重参数化等价性（训练态 vs 部署态必须数值一致）
# ═══════════════════════════════════════════════════════════════════════════

def check_reparam_equivalence(cfg: BackboneConfig) -> dict:
    """验证 reparameterize() 折叠前后输出一致。

    ⚠️ 必须对**同一个模型**做「折叠前 → 折叠后」对拍，否则是伪测试：
       如果分别造一个 train 态和一个 deploy 态再拷贝权重，两边权重天然相同，
       误差必然为 0，什么也没验证到。这里改成原地折叠、前后各跑一次前向。

    另外 BN 在 eval 模式下才是纯仿射变换（用 running_mean/var）；train 模式会用
    batch 统计量，折叠公式不成立。所以必须先 .eval() 再对拍——这也是导出到
    CoreML 的真实场景（推理永远走 eval）。
    """
    torch.manual_seed(0)
    model = build_v3_backbone(cfg, deploy=False).eval()
    image = torch.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w)
    state = torch.randn(1, cfg.state_dim)

    # BN 的 running stats 默认是 0/1，随机初始化的 BN 折叠后差异不易暴露；
    # 手动打乱成非平凡值，让测试真正覆盖 γ/β/μ/σ 的折叠数学。
    with torch.no_grad():
        for m in model.modules():
            if isinstance(m, nn.BatchNorm2d):
                m.running_mean.normal_(0, 0.5)
                m.running_var.uniform_(0.5, 2.0)
                m.weight.normal_(1.0, 0.2)
                m.bias.normal_(0.0, 0.2)

    with torch.no_grad():
        before = model(image, state)

    params_before = count_params(model)
    n_bn = sum(1 for m in model.modules() if isinstance(m, nn.BatchNorm2d))

    model.reparameterize()
    params_after = count_params(model)

    with torch.no_grad():
        after = model(image, state)

    errs = {}
    rels = {}
    for name, x, y in (("stop_go", before[0], after[0]), ("ctrl", before[1], after[1])):
        errs[name] = float((x - y).abs().max())
        denom = float(x.abs().max()) or 1.0
        rels[name] = float((x - y).abs().max() / denom)

    n_conv_after = sum(1 for m in model.modules() if isinstance(m, nn.Conv2d))
    return {
        "max_abs_err": errs,
        "max_rel_err": rels,
        "params_before_fold": params_before,
        "params_after_fold": params_after,
        "bn_layers_folded": n_bn,
        "conv_layers_after_fold": n_conv_after,
    }


# ═══════════════════════════════════════════════════════════════════════════
# ANE 逐算子派发（真实测量，非估算）
# ═══════════════════════════════════════════════════════════════════════════

def coreml_latency(pkg_path: str, cfg: BackboneConfig,
                   warmup: int = 10, iters: int = 50) -> dict[str, float]:
    """在已转换的 .mlpackage 上实测 CoreML 推理延迟（ms），ANE 与 CPU 各一遍。

    为什么必须单独测这一项：PyTorch 的 MPS 耗时完全不能代表 ANE 延迟——
    MPS 走的是 GPU，而部署目标是 Neural Engine。只有让 CoreML 以
    compute_units=.all（允许 ANE）和 .cpuOnly 各跑一遍，比较两者才有意义。

    ⚠️ 用 .mlpackage 而不是 .mlmodelc 来跑延迟：本机 macOS 27 上
       `compile_model` 产出的 .mlmodelc **没有 Manifest.json**
       （只有 coremldata.bin + model.mil），ct.models.MLModel 加载会报
       "A valid manifest does not exist"。.mlpackage 由 CoreML 内部完成编译，
       可正常推理。（该 .mlmodelc 仍可用于 MLComputePlan 读派发，两者互不影响。）

    ⚠️ 这是本机 Apple M3 实测（与部署目标芯片一致），但仍不是真机 App 内
       端到端耗时（不含图像预处理/拷贝/调度开销）。
    """
    import coremltools as ct
    import numpy as np
    import time

    image = np.random.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w).astype(np.float32)
    state = np.random.randn(1, cfg.state_dim).astype(np.float32)

    out: dict[str, float] = {}
    for unit_name, unit in (("ane_all", ct.ComputeUnit.ALL),
                            ("cpu_only", ct.ComputeUnit.CPU_ONLY)):
        try:
            m = ct.models.MLModel(pkg_path, compute_units=unit)
            # 输入名从模型 spec 读，不硬编码：CoreML 会把保留名 `state` 静默
            # 改写成 `state_workaround`（本机实测），硬编码必然 KeyError。
            # _fd_spec 是 protobuf repeated 容器，要逐元素取 .name（没有 .keys()）
            names = [f.name for f in m.input_description._fd_spec]
            img_name = "image" if "image" in names else names[0]
            st_candidates = [n for n in names if n != img_name]
            st_name = st_candidates[0] if st_candidates else "vehicle_state"
            inputs = {img_name: image, st_name: state}

            for _ in range(warmup):
                m.predict(inputs)
            t0 = time.perf_counter()
            for _ in range(iters):
                m.predict(inputs)
            out[unit_name] = round((time.perf_counter() - t0) / iters * 1000.0, 2)
            out[unit_name + "_input_names"] = sorted(names)   # 便于核对改名现象
        except Exception as exc:      # 如实记录失败原因，不静默填 0
            out[unit_name + "_error"] = f"{type(exc).__name__}: {exc}"
    return out


def ane_probe(model: nn.Module, cfg: BackboneConfig, tag: str) -> dict:
    """把模型转成 CoreML mlprogram，编译成 .mlmodelc，用 MLComputePlan 读
    **每个算子最终被派发到哪个设备**。

    这是唯一能给出真实 ANE/CPU 派发的手段（coremltools 9.0 + macOS 27 实测可用，
    见 01-backbone.md §5 的方法学说明）。const 节点不计入（无计算）。
    """
    import coremltools as ct
    from coremltools.models.utils import compile_model
    from coremltools.models.compute_plan import MLComputePlan
    from collections import Counter

    model = model.eval()
    image = torch.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w)
    state = torch.randn(1, cfg.state_dim)

    class ExportWrapper(nn.Module):
        """只导出部署前向（不含 CCM），并把 tuple 输出拆成具名输出。"""

        def __init__(self, inner: nn.Module):
            super().__init__()
            self.inner = inner

        def forward(self, image: torch.Tensor, vehicle_state: torch.Tensor):
            stop_go, ctrl = self.inner(image, vehicle_state)
            return stop_go, ctrl

    wrapper = ExportWrapper(model).eval()
    traced = torch.jit.trace(wrapper, (image, state), strict=False)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    pkg = OUT_DIR / f"{tag}.mlpackage"
    mlc = OUT_DIR / f"{tag}.mlmodelc"
    for p in (pkg, mlc):
        if p.exists():
            shutil.rmtree(p)

    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="image", shape=(1, cfg.in_channels, cfg.image_h, cfg.image_w)),
            ct.TensorType(name="vehicle_state", shape=(1, cfg.state_dim)),
        ],
        outputs=[
            ct.TensorType(name="stop_go"),
            ct.TensorType(name="ctrl"),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.save(str(pkg))
    compile_model(str(pkg), str(mlc))

    plan = MLComputePlan.load_from_path(str(mlc), compute_units=ct.ComputeUnit.ALL)
    fn = plan.model_structure.program.functions["main"]

    dev = Counter()
    op_dev: dict[str, Counter] = {}
    for op in fn.block.operations:
        name = op.operator_name
        if name == "const":
            continue
        du = plan.get_compute_device_usage_for_mlprogram_operation(op)
        pd = du.preferred_compute_device if du else None
        d = type(pd).__name__ if pd is not None else "NONE"
        dev[d] += 1
        op_dev.setdefault(name, Counter())[d] += 1

    total = sum(dev.values())
    ane = dev.get("MLNeuralEngineComputeDevice", 0)
    cpu = dev.get("MLCPUComputeDevice", 0)
    gpu = dev.get("MLGPUComputeDevice", 0)
    none_ = dev.get("NONE", 0)

    # 只列"有算子掉 CPU/GPU"的类型，方便直接进 §5 风险清单
    offenders = {
        op: dict(c) for op, c in op_dev.items()
        if c.get("MLCPUComputeDevice", 0) or c.get("MLGPUComputeDevice", 0)
    }

    return {
        "tag": tag,
        "device_counts": dict(dev),
        "total_ops": total,
        "ane_ops": ane,
        "cpu_ops": cpu,
        "gpu_ops": gpu,
        "none_ops": none_,
        "ane_ratio": round(ane / total, 4) if total else 0.0,
        "offenders": offenders,
        "package_path": str(mlc),
        "package_size_mb": round(_dir_size_mb(mlc), 2),
        "coreml_latency_ms": coreml_latency(str(pkg), cfg),
    }


def _dir_size_mb(path: Path) -> float:
    if path.is_file():
        return path.stat().st_size / 1e6
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1e6


# ═══════════════════════════════════════════════════════════════════════════
# 主流程：多个候选配置对比
# ═══════════════════════════════════════════════════════════════════════════

def candidate_configs() -> list[tuple[str, BackboneConfig]]:
    """候选配置。核心变量：主干宽度 D、深度、token 网格。

    336 token 来自 4 次 stride-2（224/16=14，384/16=24）。
    另一组用 extra_downsample=True 得到 5 次 stride-2（7×12=84 token），
    骨干通道数与主干宽度**保持不变**，让 token 数成为唯一变量。
    """
    cands: list[tuple[str, BackboneConfig]] = []

    # ── 主候选：D 从 128/160/192，token 固定 336（4 次下采样）──
    for d, heads in ((128, 4), (160, 5), (192, 6)):
        cands.append((
            f"D{d}_t336_d4x2",
            BackboneConfig(dim=d, heads=heads, depth_per_stage=4),
        ))

    # ── 深度候选：D=192 但每 stage 深度 4 → 3 / 5 ──
    cands.append(("D192_t336_d3x2", BackboneConfig(dim=192, heads=6, depth_per_stage=3)))
    cands.append(("D192_t336_d5x2", BackboneConfig(dim=192, heads=6, depth_per_stage=5)))

    # ── token 数消融：只加一次 stride-2（7×12=84 token），其它一切不变 ──
    cands.append((
        "D192_t84_d4x2",
        BackboneConfig(dim=192, heads=6, depth_per_stage=4, extra_downsample=True),
    ))

    return cands


def run_one(tag: str, cfg: BackboneConfig, do_ane: bool, verbose: bool) -> dict:
    torch.manual_seed(0)
    model = build_v3_backbone(cfg, deploy=True).eval()
    image = torch.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w)
    state = torch.randn(1, cfg.state_dim)

    total = count_params(model)
    sec = section_params(model)
    flops = measure_flops(model, image, state)

    with torch.no_grad():
        stop_go, ctrl = model(image, state)

    lat_cpu = measure_latency(model, (image, state), "cpu", warmup=3, iters=10)
    lat_mps = measure_latency(model, (image, state), "mps", warmup=5, iters=20)

    row = {
        "tag": tag,
        "dim": cfg.dim,
        "heads": cfg.heads,
        "depth_per_stage": cfg.depth_per_stage,
        "tokens": cfg.num_visual_tokens(),
        "token_grid": list(cfg.token_grid()),
        "total_params": total,
        "total_params_M": round(total / 1e6, 3),
        "flops_G": round(flops / 1e9, 3),
        "sections": sec,
        "sections_M": {k: round(v / 1e6, 3) for k, v in sec.items()},
        "out_stop_go": list(stop_go.shape),
        "out_ctrl": list(ctrl.shape),
        "latency_cpu_ms": round(lat_cpu, 2),
        "latency_mps_ms": round(lat_mps, 2),
    }

    if verbose:
        print(f"\n{'=' * 74}")
        print(f"[{tag}]  D={cfg.dim} heads={cfg.heads} depth/stage={cfg.depth_per_stage} "
              f"tokens={row['tokens']} grid={row['token_grid']}")
        print(f"  参数量 = {total:,}  ({row['total_params_M']} M)")
        print(f"  FLOPs  = {flops / 1e9:.3f} GFLOPs")
        print(f"  forward out: stop_go={tuple(stop_go.shape)} ctrl={tuple(ctrl.shape)}")
        print(f"  本机耗时: CPU {lat_cpu:.2f} ms | MPS {lat_mps:.2f} ms  (非 ANE)")
        print(f"  分区参数: " + " ".join(
            f"{k}={v / 1e6:.3f}M" for k, v in sec.items() if k != "total"))

    if do_ane:
        try:
            ane = ane_probe(model, cfg, tag)
            row["ane"] = ane
            if verbose:
                dc = ane["device_counts"]
                print(f"  ANE 派发: ANE={ane['ane_ops']} CPU={ane['cpu_ops']} "
                      f"GPU={ane['gpu_ops']} NONE={ane['none_ops']} "
                      f"/ 总 {ane['total_ops']}  (ANE 占比 {ane['ane_ratio'] * 100:.1f}%)")
                print(f"  体积: {ane['package_size_mb']} MB (fp16 mlprogram)")
                lat = ane.get("coreml_latency_ms", {})
                if "ane_all" in lat and "cpu_only" in lat:
                    speedup = lat["cpu_only"] / lat["ane_all"] if lat["ane_all"] else 0
                    print(f"  CoreML 实测延迟: ANE(ALL) {lat['ane_all']} ms | "
                          f"CPU-only {lat['cpu_only']} ms | ANE 加速 {speedup:.2f}×")
                else:
                    print(f"  CoreML 延迟: {lat}")
                if ane["offenders"]:
                    print(f"  ⚠ 有算子未上 ANE: {json.dumps(ane['offenders'], ensure_ascii=False)}")
        except Exception as exc:      # 转换/编译失败必须如实记录，不能静默跳过
            row["ane_error"] = f"{type(exc).__name__}: {exc}"
            if verbose:
                print(f"  ⚠ ANE 探测失败（如实记录为未测）: {type(exc).__name__}: {exc}")

    return row


def print_layer_table(cfg: BackboneConfig) -> None:
    """打印推荐配置的逐层参数表（进 §3）。"""
    torch.manual_seed(0)
    model = build_v3_backbone(cfg, deploy=True).eval()
    rows = model.layer_table()
    print(f"\n{'=' * 100}")
    print(f"逐层参数表（deploy 态，D={cfg.dim}, depth/stage={cfg.depth_per_stage}）")
    print(f"{'层名':<52} {'形状':<26} {'参数量':>10} {'累计':>12}")
    print("-" * 100)
    for r in rows:
        print(f"{r['name']:<52} {str(r['shape']):<26} {r['params']:>10,} {r['cumulative']:>12,}")
    print("-" * 100)
    print(f"{'合计':<52} {'':<26} {rows[-1]['cumulative']:>10,}")
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-ane", action="store_true", help="跳过 CoreML/ANE 实测（很快）")
    ap.add_argument("--out", default="/tmp/v3_bb_measure.json", help="结果落盘路径")
    args = ap.parse_args()

    print("=" * 74)
    print("V3 骨干实测  环境：", sys.version.split()[0], "| torch", torch.__version__)
    print("设备：", "MPS 可用" if torch.backends.mps.is_available() else "MPS 不可用")
    print("=" * 74)

    # ── 0. 论文原始骨干参数量复现（作为差异对照的基线）──
    paper_layers = [(3, 24, 5), (24, 36, 5), (36, 48, 5), (48, 64, 3), (64, 64, 3)]
    paper_conv = sum(i * o * k * k for i, o, k in paper_layers)
    print(f"\n[0] 论文原始骨干（§IV.D）卷积参数 = {paper_conv:,} ({paper_conv / 1e6:.4f} M)")
    print("    （本项为按原文通道/kernel 逐层相乘的推算，非论文自报数字）")

    # ── 1. 重参数化等价性 ──
    cfg0 = BackboneConfig()
    eq = check_reparam_equivalence(cfg0)
    print(f"\n[1] 重参数化等价性检查（同一模型原地折叠前后对拍）")
    print(f"    最大绝对误差: stop_go={eq['max_abs_err']['stop_go']:.3e}  "
          f"ctrl={eq['max_abs_err']['ctrl']:.3e}")
    print(f"    最大相对误差: stop_go={eq['max_rel_err']['stop_go']:.3e}  "
          f"ctrl={eq['max_rel_err']['ctrl']:.3e}")
    print(f"    折叠前参数 {eq['params_before_fold']:,} → 折叠后 {eq['params_after_fold']:,} "
          f"（减少 {eq['params_before_fold'] - eq['params_after_fold']:,}）")
    print(f"    折叠掉 BN 层 {eq['bn_layers_folded']} 个；折叠后图中 Conv2d 共 "
          f"{eq['conv_layers_after_fold']} 个（应等于 RepVGGBlock 数量）")

    # ── 2. 候选配置对比 ──
    print(f"\n[2] 候选配置实测（{'含' if not args.no_ane else '不含'} ANE 派发）")
    results = []
    for tag, cfg in candidate_configs():
        results.append(run_one(tag, cfg, do_ane=not args.no_ane, verbose=True))

    # ── 3. 汇总表 ──
    print(f"\n{'=' * 118}")
    print("【汇总】候选配置对比")
    print(f"{'tag':<18} {'D':>4} {'tok':>5} {'depth':>5} {'参数量':>11} {'M':>8} "
          f"{'GFLOPs':>8} {'CPU ms':>8} {'MPS ms':>8} {'ANE占比':>8}")
    print("-" * 118)
    for r in results:
        ane = r.get("ane")
        ane_s = f"{ane['ane_ratio'] * 100:.1f}%" if ane else "未测"
        print(f"{r['tag']:<18} {r['dim']:>4} {r['tokens']:>5} {r['depth_per_stage']:>5} "
              f"{r['total_params']:>11,} {r['total_params_M']:>8.3f} "
              f"{r['flops_G']:>8.3f} {r['latency_cpu_ms']:>8.2f} "
              f"{r['latency_mps_ms']:>8.2f} {ane_s:>8}")
    print("-" * 118)
    print("注：CPU/MPS 列是**本机 PyTorch** 参考耗时，不代表 CoreML/ANE 真机延迟。")

    # ── 4. 推荐配置逐层表 ──
    print_layer_table(cfg0)

    # ── 5. 落盘 ──
    payload = {
        "env": {
            "python": sys.version.split()[0],
            "torch": torch.__version__,
            "mps_available": bool(torch.backends.mps.is_available()),
        },
        "paper_conv_params": paper_conv,
        "reparam_equivalence": eq,
        "candidates": results,
    }
    Path(args.out).write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    print(f"\n结果已落盘: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
