#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 部署前提验证：4-bit palettization 后的体积 / ANE 派发 / 精度漂移

用户的部署前提是「4-bit 量化，约 6.5MB」。但量化会改变权重形态，
必须验证两件事，否则体积达标而上不了 ANE 就等于白做：

  V1  4-bit palettize 后体积是否真的降到 ~6.5MB 量级
  V2  4-bit palettize 后 ANE 派发是否仍保持 100%（不能为了体积丢掉 ANE）
  V3  量化带来的输出误差有多大（与 fp16 基线对比，给出最大绝对误差）

⚠️ 本实验只做**离线转换与对比**，不涉及训练，不联网、不启动 App、不建窗口。
"""
from __future__ import annotations

import json
import shutil
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import torch

_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROOT))

import coremltools as ct                        # noqa: E402
import coremltools.optimize.coreml as cto       # noqa: E402
import numpy as np                              # noqa: E402
from coremltools.models.compute_plan import MLComputePlan   # noqa: E402
from coremltools.models.utils import compile_model          # noqa: E402
from collections import Counter                             # noqa: E402

from tools.v3_exp.backbone_v3 import BackboneConfig, build_v3_backbone   # noqa: E402

OUT = Path("/tmp/v3_quant")


def dir_size_mb(p: Path) -> float:
    if p.is_file():
        return p.stat().st_size / 1e6
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e6


def export_fp16(cfg: BackboneConfig, pkg: Path):
    """导出 fp16 mlprogram，返回 (mlpackage 模型, 输入 dict)。"""
    import torch.nn as nn

    model = build_v3_backbone(cfg, deploy=True).eval()

    class W(nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, image, vehicle_state):
            return self.inner(image, vehicle_state)

    wrapper = W(model).eval()
    img = torch.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w)
    st = torch.randn(1, cfg.state_dim)
    traced = torch.jit.trace(wrapper, (img, st), strict=False)

    if pkg.exists():
        shutil.rmtree(pkg)
    ml = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="image", shape=(1, cfg.in_channels, cfg.image_h, cfg.image_w)),
            ct.TensorType(name="vehicle_state", shape=(1, cfg.state_dim)),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    ml.save(str(pkg))
    return ml


def dispatch_stats(pkg: Path, tag: str) -> dict:
    """编译 mlpackage → 用 MLComputePlan 统计逐算子派发。"""
    mlc = pkg.with_suffix(".mlmodelc")
    if mlc.exists():
        shutil.rmtree(mlc)
    compile_model(str(pkg), str(mlc))
    plan = MLComputePlan.load_from_path(str(mlc), compute_units=ct.ComputeUnit.ALL)
    fn = plan.model_structure.program.functions["main"]
    dev = Counter()
    for op in fn.block.operations:
        if op.operator_name == "const":
            continue
        du = plan.get_compute_device_usage_for_mlprogram_operation(op)
        pd = du.preferred_compute_device if du else None
        dev[type(pd).__name__ if pd is not None else "NONE"] += 1
    total = sum(dev.values())
    return {
        "tag": tag,
        "device_counts": dict(dev),
        "total_ops": total,
        "ane_ratio": round(dev.get("MLNeuralEngineComputeDevice", 0) / total, 4) if total else 0.0,
        "mlmodelc_size_mb": round(dir_size_mb(mlc), 2),
    }


def run() -> int:
    cfg = BackboneConfig()          # D=192, depth 4, 336 token
    OUT.mkdir(parents=True, exist_ok=True)

    print("=" * 78)
    print("V3 部署前提验证：4-bit palettization")
    print("=" * 78)

    fp16_pkg = OUT / "v3_fp16.mlpackage"
    ml_fp16 = export_fp16(cfg, fp16_pkg)
    fp16_mb = dir_size_mb(fp16_pkg)
    print(f"\n[1] fp16 基线: {fp16_pkg.name}  体积 {fp16_mb:.2f} MB")

    # fp16 参考输出（用 Python 端 MLModel 推理，作为精度对比基准）
    img = np.random.randn(1, 3, cfg.image_h, cfg.image_w).astype(np.float32)
    st = np.random.randn(1, cfg.state_dim).astype(np.float32)
    m16 = ct.models.MLModel(str(fp16_pkg))
    names = [f.name for f in m16.input_description._fd_spec]
    img_name = "image" if "image" in names else names[0]
    st_name = next((n for n in names if n != img_name), "vehicle_state")
    ref = m16.predict({img_name: img, st_name: st})

    results = [{"tag": "fp16", "size_mb": round(fp16_mb, 2)}]

    # ── 4-bit palettization（按 nbits 试 4 和 6 做对照）──
    for nbits in (4, 6):
        tag = f"int{nbits}"
        print(f"\n[{tag}] 尝试 {nbits}-bit palettize...")
        try:
            gcfg = cto.OpPalettizerConfig(mode="kmeans", nbits=nbits)
            ocfg = cto.OptimizationConfig(global_config=gcfg)
            ml_q = cto.palettize_weights(ml_fp16, ocfg)

            pkg_q = OUT / f"v3_{tag}.mlpackage"
            if pkg_q.exists():
                shutil.rmtree(pkg_q)
            ml_q.save(str(pkg_q))
            size_q = dir_size_mb(pkg_q)
            ratio = fp16_mb / size_q if size_q else 0
            print(f"  体积 {size_q:.2f} MB（fp16 的 1/{ratio:.2f}，压缩 {ratio:.2f}×）")

            row = {
                "tag": tag,
                "nbits": nbits,
                "size_mb": round(size_q, 2),
                "compression_x": round(ratio, 2),
            }

            # 派发统计
            try:
                ds = dispatch_stats(pkg_q, tag)
                row.update({
                    "ane_ratio": ds["ane_ratio"],
                    "device_counts": ds["device_counts"],
                    "total_ops": ds["total_ops"],
                })
                print(f"  ANE 派发: {ds['device_counts']}  → ANE {ds['ane_ratio']*100:.1f}%")
            except Exception as exc:
                row["dispatch_error"] = f"{type(exc).__name__}: {exc}"
                print(f"  ⚠ 派发统计失败: {exc}")

            # 精度对比
            try:
                mq = ct.models.MLModel(str(pkg_q))
                out_q = mq.predict({img_name: img, st_name: st})
                key = list(ref.keys())[0]
                a = np.array(ref[key]).reshape(-1)
                b = np.array(out_q[key]).reshape(-1)
                err = float(np.abs(a - b).max())
                row["max_abs_err_vs_fp16"] = err
                print(f"  与 fp16 最大绝对误差: {err:.5f}"
                      f"（输出范围约 [{a.min():.2f}, {a.max():.2f}]）")
            except Exception as exc:
                row["accuracy_error"] = f"{type(exc).__name__}: {exc}"
                print(f"  ⚠ 精度对比失败: {exc}")

            results.append(row)
        except Exception as exc:
            print(f"  ⚠ {nbits}-bit palettize 失败: {type(exc).__name__}: {exc}")
            results.append({"tag": tag, "nbits": nbits,
                            "error": f"{type(exc).__name__}: {exc}"})

    # ── 汇总 ──
    print(f"\n{'=' * 78}")
    print("【汇总】量化后体积与 ANE")
    print(f"{'tag':<8} {'体积MB':>9} {'压缩':>7} {'ANE%':>8} {'误差':>10}")
    print("-" * 78)
    for r in results:
        if "error" in r:
            print(f"{r['tag']:<8}  失败: {r['error'][:50]}")
            continue
        ane = f"{r['ane_ratio']*100:.1f}%" if "ane_ratio" in r else "未测"
        err = f"{r['max_abs_err_vs_fp16']:.5f}" if "max_abs_err_vs_fp16" in r else "未测"
        comp = f"{r['compression_x']:.2f}×" if "compression_x" in r else "-"
        print(f"{r['tag']:<8} {r['size_mb']:>9.2f} {comp:>7} {ane:>8} {err:>10}")
    print("-" * 78)
    print("注：体积为 mlpackage（含权重+模型描述）实测目录大小；")
    print("    ANE% 为 MLComputePlan 逐算子统计（const 不计）。")

    (OUT / "quant_report.json").write_text(
        json.dumps({"fp16_mb": round(fp16_mb, 2), "results": results},
                   ensure_ascii=False, indent=2))
    print(f"\n结果已落盘: {OUT / 'quant_report.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(run())
