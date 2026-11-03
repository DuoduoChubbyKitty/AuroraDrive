#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 01-backbone.md 所需的表格（全部为实测输出，供直接粘贴）

三张表：
  T1  推荐配置的模块级结构表：模块名 / 类型 / 输入形状 / 输出形状 / 参数量 / 累计
  T2  逐算子类型 × 设备派发表（fp16 与 int4 各一份）——用于 §5 ANE 风险清单
  T3  量化后 ANE 派发的**正确口径**统计（排除非计算算子）

⚠️ 关于 ANE 占比的正确口径（本脚本要修正的一个错误）：
   MLComputePlan 的 operations 里混有三类非计算条目：
     - `const`                     ：权重常量，没有设备概念
     - `ios16.constexpr_lut_to_dense`：palettization 的 LUT→稠密权重解压，
                                      用来在模型内部还原量化权重，不是"掉到 CPU 的计算"
   若把它们计入分母，会把 4-bit 模型的 ANE 占比错误地算成 78.7%。
   正确做法是只对**真正参与前向计算的算子**统计派发。

用法：
    /usr/local/bin/python3.11 tools/v3_exp/measure_report_tables.py
"""
from __future__ import annotations

import sys
import warnings
from collections import Counter
from pathlib import Path

warnings.filterwarnings("ignore")

import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROOT))

from tools.v3_exp.backbone_v3 import (          # noqa: E402
    BackboneConfig,
    TransformerBlock,
    build_v3_backbone,
)

# 非计算算子：不参与前向数值计算，不应计入 ANE 派发分母
NON_COMPUTE_OPS = {"const", "ios16.constexpr_lut_to_dense"}


# ═══════════════════════════════════════════════════════════════════════════
# T1：模块级结构表
# ═══════════════════════════════════════════════════════════════════════════

def module_shape_table(cfg: BackboneConfig) -> list[dict]:
    """用 forward hook 记录每个模块的输入/输出形状与参数量。"""
    torch.manual_seed(0)
    model = build_v3_backbone(cfg, deploy=True).eval()
    image = torch.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w)
    state = torch.randn(1, cfg.state_dim)

    records: dict[str, dict] = {}

    targets = {
        "backbone": model.backbone,
        "token_proj": model.token_proj,
        "state_lift": model.state_lift,
        "stage1": model.stage1,
        "stage2": model.stage2,
        "stop_go_head": model.stop_go_head,
        "ctrl_head": model.ctrl_head,
    }
    # 逐个 TransformerBlock 也记录（depth×2 个）
    for i, blk in enumerate(model.stage1.blocks):
        targets[f"stage1.blocks.{i}"] = blk
    for i, blk in enumerate(model.stage2.blocks):
        targets[f"stage2.blocks.{i}"] = blk

    handles = []
    for name, mod in targets.items():
        def make_hook(n):
            def hook(m, inp, out):
                in_shape = tuple(inp[0].shape) if isinstance(inp[0], torch.Tensor) else None
                if isinstance(out, torch.Tensor):
                    out_shape = tuple(out.shape)
                elif isinstance(out, (tuple, list)) and out and isinstance(out[0], torch.Tensor):
                    out_shape = tuple(out[0].shape)
                else:
                    out_shape = None
                records[n] = {
                    "name": n,
                    "type": type(m).__name__,
                    "in_shape": in_shape,
                    "out_shape": out_shape,
                    "params": sum(p.numel() for p in m.parameters()),
                }
            return hook
        handles.append(mod.register_forward_hook(make_hook(name)))

    with torch.no_grad():
        model(image, state)
    for h in handles:
        h.remove()

    order = ["backbone", "token_proj", "state_lift"]
    rows = [records[n] for n in order if n in records]
    for stage in ("stage1", "stage2"):
        if stage in records:
            rows.append(records[stage])
    rows += [records[n] for n in ("stop_go_head", "ctrl_head") if n in records]

    cum = 0
    for r in rows:
        cum += r["params"]
        r["cumulative"] = cum
    return rows


def print_module_table(cfg: BackboneConfig) -> None:
    rows = module_shape_table(cfg)
    print(f"\n{'=' * 116}")
    print(f"T1 模块级结构表（deploy 态；D={cfg.dim}, depth/stage={cfg.depth_per_stage}, "
          f"tokens={cfg.num_visual_tokens()}={cfg.token_grid()[0]}×{cfg.token_grid()[1]}）")
    print("=" * 116)
    print(f"{'模块':<30} {'类型':<26} {'输入形状':<24} {'输出形状':<24} {'参数量':>10} {'累计':>11}")
    print("-" * 116)
    for r in rows:
        print(f"{r['name']:<30} {r['type']:<26} {str(r['in_shape']):<24} "
              f"{str(r['out_shape']):<24} {r['params']:>10,} {r['cumulative']:>11,}")
    print("-" * 116)
    print(f"合计 {rows[-1]['cumulative']:,} 参数"
          f"（该合计含 backbone/token_proj/state_lift/两 stage/两个头；"
          f"不含 pos_emb 与 ccm）")

    # 位置编码与 CCM 单独列出（它们不是子模块调用，或被 hook 漏掉）
    torch.manual_seed(0)
    m = build_v3_backbone(cfg, deploy=True)
    print(f"  pos_emb（可学习位置编码）: {m.pos_emb.numel():,} 参数")
    print(f"  ccm（训练期正则，不进部署图）: "
          f"{sum(p.numel() for p in m.ccm.parameters()):,} 参数")
    print(f"  模型总参数（含 pos_emb + ccm）: "
          f"{sum(p.numel() for p in m.parameters()):,}")


# ═══════════════════════════════════════════════════════════════════════════
# T2 / T3：逐算子类型 × 设备派发
# ═══════════════════════════════════════════════════════════════════════════

def op_type_device_table(mlmodelc_path: str) -> dict:
    """读 .mlmodelc 的派发计划，按算子类型汇总设备分布。"""
    import coremltools as ct
    from coremltools.models.compute_plan import MLComputePlan

    plan = MLComputePlan.load_from_path(mlmodelc_path, compute_units=ct.ComputeUnit.ALL)
    fn = plan.model_structure.program.functions["main"]

    per_type: dict[str, Counter] = {}
    compute_total = 0
    compute_ane = 0
    for op in fn.block.operations:
        name = op.operator_name
        du = plan.get_compute_device_usage_for_mlprogram_operation(op)
        pd = du.preferred_compute_device if du else None
        dev = type(pd).__name__ if pd is not None else "NONE"

        per_type.setdefault(name, Counter())[dev] += 1
        if name not in NON_COMPUTE_OPS:
            compute_total += 1
            if dev == "MLNeuralEngineComputeDevice":
                compute_ane += 1

    return {
        "per_type": {k: dict(v) for k, v in sorted(per_type.items())},
        "compute_total": compute_total,
        "compute_ane": compute_ane,
        "compute_ane_ratio": round(compute_ane / compute_total, 4) if compute_total else 0.0,
    }


def print_op_table(label: str, path: str) -> dict:
    res = op_type_device_table(path)
    print(f"\n{'=' * 96}")
    print(f"T2 逐算子类型 × 设备派发 —— {label}")
    print("=" * 96)
    print(f"{'算子类型':<34} {'ANE':>6} {'GPU':>6} {'CPU':>6} {'NONE':>6} {'合计':>6}")
    print("-" * 96)
    for op, devs in res["per_type"].items():
        ane = devs.get("MLNeuralEngineComputeDevice", 0)
        gpu = devs.get("MLGPUComputeDevice", 0)
        cpu = devs.get("MLCPUComputeDevice", 0)
        none_ = devs.get("NONE", 0)
        tot = ane + gpu + cpu + none_
        mark = "" if op in NON_COMPUTE_OPS else ""
        print(f"{op + mark:<34} {ane:>6} {gpu:>6} {cpu:>6} {none_:>6} {tot:>6}")
    print("-" * 96)
    print(f"计算算子（排除 const / constexpr_lut_to_dense）: "
          f"ANE {res['compute_ane']} / 共 {res['compute_total']} "
          f"= {res['compute_ane_ratio'] * 100:.1f}%")
    return res


def main() -> int:
    cfg = BackboneConfig()          # 推荐：D=192, depth 4, 336 token

    print_module_table(cfg)

    fp16_c = "/tmp/v3_bb_measure/D192_t336_d4x2.mlmodelc"
    int4_c = "/tmp/v3_quant/v3_int4.mlmodelc"
    for label, path in (("fp16（D=192, 336 token）", fp16_c),
                        ("int4 palettized（同一模型）", int4_c)):
        if Path(path).exists():
            print_op_table(label, path)
        else:
            print(f"\n⚠ 缺少 {path}，请先运行 measure_backbone_v3.py / measure_quant_v3.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
