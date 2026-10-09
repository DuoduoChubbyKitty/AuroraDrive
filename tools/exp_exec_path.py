#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_exec_path.py — S2「执行路径与配置调优」实验台（2026-10-09）

================================================================================
这个脚本干什么
================================================================================
按指定「导出侧旋钮」组合产出 `models/exp_exec_*.mlmodelc`，供
`tools/exp_exec_bench.swift`（Swift 原生计时）消费。

**它只做导出**，不做计时 —— CoreML 的延迟必须在 Swift 原生路径测
（Python `MLModel.predict` 每次都要 numpy→MLMultiArray 转换，数字不可用）。

⛔ 红线：**不修改** `tools/export_m9_v2_coreml.py`（以 import 复用其
   `_build_and_load` / `_make_inputs` / `_ExportWrapper` 等纯函数），
   **不修改** `src/`、`Sources/`。

================================================================================
旋钮清单（每一项都有对应 CLI）
================================================================================
  ① --precision float16|float32        ct.convert(compute_precision=...)
  ② --target macOS13|14|15             minimum_deployment_target
  ③ --pipeline <步骤列表>               ct.optimize.coreml.* 后处理流水线
        dedup[:N]      去重权重（需 coremltools ≥ 9.0；8.3 无此 API）
        palette[:N]    k-means 调色板量化（默认 4bit）
        int8[:N]       线性对称 int8 量化
     N = 参与该优化的最小权重元素数（默认 128，与 Apple 示例一致）
  ④ --preserve-io                      是否显式指定 IO dtype=fp32（默认 true，与主导出脚本同口径）

用法：
    ./.venv-yolo26/bin/python3 tools/exp_exec_path.py \
        --name dedup --pipeline dedup --target macOS13 --precision float16

    # coremltools 9.0 才能用 dedup（本机 8.3 没有）：
    /tmp/ct9venv/bin/python3 tools/exp_exec_path.py --name dedup --pipeline dedup
"""

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))
if str(_ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(_ROOT / "tools"))

import torch  # noqa: E402
import coremltools as ct  # noqa: E402

# ★ 复用主导出脚本的纯函数（**只读引用，不修改该文件**）
import export_m9_v2_coreml as base  # noqa: E402


def _parse_pipeline(spec: str):
    """'dedup:64,palette:4:128' → [('dedup', {...}), ('palette', {'nbits':4,...})]

    ★ 参数名核对（2026-10-09 实测 coremltools 8.3 / 9.0）：
        OpPalettizerConfig(mode, nbits, granularity, weight_threshold, ...)
        OpLinearQuantizerConfig(mode, dtype, granularity, block_size, weight_threshold, ...)
      —— 是 **weight_threshold**（元素数阈值），不是任务书里写的 min_weight_elements；
         `deduplicate_weights` / `OpWeightDeduplicatorConfig` 在 8.3 与 9.0 **均不存在**
         （已在两个版本的 site-packages 里全文 grep 确认）。
    """
    steps = []
    if not spec.strip():
        return steps
    for raw in spec.split(","):
        raw = raw.strip()
        if not raw:
            continue
        parts = raw.split(":")
        kind = parts[0]
        args = parts[1:]
        if kind == "dedup":
            steps.append(("dedup", {"min_elements": int(args[0]) if args else 128}))
        elif kind == "palette":
            nbits = int(args[0]) if args else 4
            thr = int(args[1]) if len(args) > 1 else 128
            steps.append(("palette", {"nbits": nbits, "threshold": thr}))
        elif kind == "int8":
            steps.append(("int8", {"threshold": int(args[0]) if args else 128}))
        else:
            raise SystemExit(f"未知 pipeline 步骤：{kind}（可选 dedup / palette / int8）")
    return steps


def _apply_pipeline(mlmodel, steps):
    """按顺序施加 ct.optimize.coreml.* 后处理。返回 (mlmodel, notes)。"""
    notes = []
    if not steps:
        return mlmodel, notes
    try:
        import coremltools.optimize.coreml as cto
    except ImportError as exc:  # pragma: no cover
        raise SystemExit(f"无法导入 coremltools.optimize.coreml：{exc}")

    for kind, kw in steps:
        t0 = time.time()
        if kind == "dedup":
            # ★ 如实记录：这个 API 在 coremltools 8.3 与 9.0 里**都不存在**。
            #   Apple 的 Core ML 在**编译期**（coremlc / ANE 编译器）会自行做权重去重，
            #   没有暴露给用户的 Python API。任务书里的 `ct.optimize.coreml.deduplicate_weights`
            #   是**不存在的函数名**，此处如实标记为"未验证/不可用"，绝不假装做过。
            if not hasattr(cto, "deduplicate_weights"):
                notes.append(
                    f"✗ dedup 不可用：coremltools {ct.__version__} 无 "
                    f"`optimize.coreml.deduplicate_weights`（8.3 与 9.0 均无此符号，"
                    f"已全文 grep 确认）→ 该旋钮**未验证**，不是「试过没用」")
                continue
            cfg = cto.OptimizationConfig(
                global_config=cto.OpWeightDeduplicatorConfig(
                    min_weight_elements=kw["min_elements"]))
            mlmodel = cto.deduplicate_weights(mlmodel, config=cfg)
            notes.append(f"✓ dedup（min_weight_elements={kw['min_elements']}）"
                         f" {time.time()-t0:.1f}s")
        elif kind == "palette":
            cfg = cto.OptimizationConfig(
                global_config=cto.OpPalettizerConfig(
                    nbits=kw["nbits"], mode="kmeans",
                    weight_threshold=kw["threshold"]))
            mlmodel = cto.palettize_weights(mlmodel, config=cfg)
            notes.append(f"✓ palette {kw['nbits']}bit kmeans"
                         f"（weight_threshold={kw['threshold']}） {time.time()-t0:.1f}s")
        elif kind == "int8":
            cfg = cto.OptimizationConfig(
                global_config=cto.OpLinearQuantizerConfig(
                    mode="linear_symmetric", dtype=np.int8,
                    weight_threshold=kw["threshold"]))
            mlmodel = cto.linear_quantize_weights(mlmodel, config=cfg)
            notes.append(f"✓ int8 linear_symmetric（weight_threshold="
                         f"{kw['threshold']}） {time.time()-t0:.1f}s")
    return mlmodel, notes


def _size_mb(p: Path) -> float:
    if not p.exists():
        return 0.0
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1048576


def main() -> int:
    ap = argparse.ArgumentParser(description="S2 执行路径调优：导出侧旋钮实验台")
    ap.add_argument("--name", required=True, help="实验名（产物 models/exp_exec_<name>.mlmodelc）")
    ap.add_argument("--out-dir", default=str(_ROOT / "models"), help="产物目录")
    ap.add_argument("--src", default=str(_ROOT / "checkpoints" / "m9_v2" / "best_model.pt"))
    ap.add_argument("--precision", choices=["float16", "float32"], default="float16")
    ap.add_argument("--target", choices=["macOS13", "macOS14", "macOS15"], default="macOS13")
    ap.add_argument("--pipeline", default="", help="后处理流水线，如 'dedup,palette:4'")
    ap.add_argument("--no-preserve-io", dest="preserve_io", action="store_false", default=True,
                    help="不显式指定 IO dtype=fp32（IO 会随 compute_precision 变 fp16）")
    ap.add_argument("--allow-partial", action="store_true",
                    help="允许随机初始化占比 >5% 的 checkpoint（本模型 65.74%，链路验证用）")
    ap.add_argument("--random-init", action="store_true",
                    help="完全用随机初始化权重（诊断用：只验证图结构能否编译，绝不可上车）")
    ap.add_argument("--num-frames", type=int, default=None,
                    help="覆盖时序窗口帧数（★ 仅诊断用，用来定位 ANE 编译失败的根因；"
                         "正式产物必须用默认 8 帧，红线不可降）")
    args = ap.parse_args()

    steps = _parse_pipeline(args.pipeline)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"exp_exec_{args.name}.mlmodelc"
    meta_path = out_dir / f"exp_exec_{args.name}.json"

    print("=" * 78)
    print(f" S2 导出实验：{args.name}")
    print(f"   precision={args.precision} target={args.target} pipeline={args.pipeline or '(无)'}")
    print(f"   coremltools={ct.__version__} torch={torch.__version__}")
    print("=" * 78)

    # ---- 权重 ----
    src = Path(args.src)
    if not src.exists():
        print(f"[导出] ✗ checkpoint 不存在：{src}", file=sys.stderr)
        return 2
    sd = base._load_state_dict(src)
    model, load_report = base._build_and_load(sd, src)
    if args.num_frames is not None:
        # ★ 诊断专用：换掉时序窗口帧数（正式产物绝不允许，红线）
        from src.model_v2 import build_model as _bm
        print(f"[导出] ⚠⚠ 诊断模式：num_frames={args.num_frames}（**非交付配置，仅定位 ANE 边界**）")
        torch.manual_seed(0)
        model = _bm(deploy=False, num_frames=args.num_frames)
        model.eval()
        model.reparameterize()
        load_report = {"random_init": True}
    if not load_report.get("random_init"):
        sd_now = model.state_dict()
        missing_param = sum(sd_now[k].numel() for k in load_report.get("all_missing_keys", [])
                            if k in sd_now)
        total_param = sum(p.numel() for p in model.parameters())
        ratio = missing_param / max(total_param, 1) * 100
        print(f"[导出] load_state_dict missing={load_report['missing']} "
              f"unexpected={load_report['unexpected']} → 随机初始化占比 {ratio:.2f}%（部署态口径）")
        if ratio > 5.0 and not args.allow_partial:
            print("[导出] ✗ 随机初始化占比 >5%，加 --allow-partial 才继续", file=sys.stderr)
            return 11
    total_params = sum(p.numel() for p in model.parameters())
    print(f"[导出] 参数量 = {total_params:,}（{total_params*2/1048576:.2f} MB @fp16）")

    # ---- 契约 + trace ----
    c = base._contract_from_model(model)
    base_inputs = base._make_inputs(c)
    export_model = base._ExportWrapper(model)
    export_model.eval()
    with torch.no_grad():
        traced = torch.jit.trace(export_model, tuple(base_inputs), strict=False)
    ref = base._torch_forward(export_model, base_inputs)
    print(f"[导出] ✓ trace 成功；PyTorch 参考输出 = {[round(v, 6) for v in ref]}")

    # ---- 转换 ----
    shapes = base._shapes(c)
    io_dtype = np.float32 if args.preserve_io else None
    inputs = [ct.TensorType(name=n, shape=s, dtype=io_dtype)
              for n, s in zip(base.INPUT_NAMES, shapes)]
    outputs = [ct.TensorType(name=n, dtype=io_dtype) for n in base.OUTPUT_NAMES]
    target = {"macOS13": ct.target.macOS13,
              "macOS14": ct.target.macOS14,
              "macOS15": ct.target.macOS15}[args.target]
    prec = ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32

    t0 = time.time()
    mlmodel = ct.convert(traced, source="pytorch", convert_to="mlprogram",
                         minimum_deployment_target=target,
                         compute_precision=prec, inputs=inputs, outputs=outputs)
    print(f"[导出] ✓ convert 完成 {time.time()-t0:.1f}s")

    # ---- 后处理流水线 ----
    mlmodel, notes = _apply_pipeline(mlmodel, steps)
    for n in notes:
        print(f"[导出]   · {n}")
    if steps and all(n.startswith("✗") for n in notes):
        print("[导出] ✗ 所有流水线步骤都未生效 —— 拒绝产出无意义产物", file=sys.stderr)
        return 12

    # ---- 落盘 + 编译（复用主脚本的 save_and_compile）----
    mlpackage, mlmodelc, save_notes = base.save_and_compile(mlmodel, out)
    for n in save_notes:
        print(f"[导出]   · {n}")

    # ---- 精度对拍（Python 侧，仅记录，不作为性能判据）----
    maxdiff = None
    try:
        pkg_model = ct.models.MLModel(str(mlpackage), compute_units=ct.ComputeUnit.CPU_ONLY)
        cases = base._edge_cases(c, base_inputs)
        worst = 0.0
        for cname, cin in cases.items():
            pred = pkg_model.predict(base._to_feed(cin))
            got = [float(np.asarray(pred[n]).flatten()[0]) for n in base.OUTPUT_NAMES]
            want = base._torch_forward(export_model, cin)
            d = max(abs(a - b) for a, b in zip(got, want))
            worst = max(worst, d)
            print(f"[精度] {cname:<10} maxdiff={d:.3e}")
        maxdiff = worst
        print(f"[精度] ★ 最差 maxdiff = {worst:.3e}")
    except Exception as exc:
        print(f"[精度] ⚠ 对拍失败（不影响性能结论）：{type(exc).__name__}: {exc}")

    # ---- 元数据 ----
    size_pkg = _size_mb(mlpackage)
    size_c = _size_mb(mlmodelc) if mlmodelc else 0.0
    meta = {
        "name": args.name, "out_mlmodelc": str(mlmodelc) if mlmodelc else None,
        "out_mlpackage": str(mlpackage),
        "precision": args.precision, "target": args.target,
        "pipeline": args.pipeline or "(无)", "pipeline_steps": [s[0] for s in steps],
        "pipeline_notes": notes,
        "coremltools": ct.__version__, "torch": torch.__version__,
        "preserve_io_fp32": args.preserve_io,
        "size_mlpackage_mb": round(size_pkg, 3),
        "size_mlmodelc_mb": round(size_c, 3),
        "maxdiff_vs_torch": maxdiff,
        "ref_outputs": ref,
        "random_init": bool(load_report.get("random_init")),
        "total_params": total_params,
        "created": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[导出] 元数据 → {meta_path}")
    print(f"[导出] 体积：mlpackage {size_pkg:.2f} MB / mlmodelc {size_c:.2f} MB")
    print(f"[导出] ✓ 完成：{mlmodelc if mlmodelc else mlpackage}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
