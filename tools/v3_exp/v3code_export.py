#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 model_v3.py 的 CoreML 导出实测（体积 / ANE 派发 / 延迟）。

为什么单独成脚本、不写进 `src/model_v3.py`：
  `export_coreml()` 是给训练管线调用的导出函数；本脚本是**测量**脚本，
  要额外做 4-bit 量化、整编译、逐算子派发统计、延迟采样 —— 这些属于验证，
  不属于模型定义（仓库既有约定：`model_v3_experiments.py` 同理）。

测量口径（全部实跑，不估算）：
  · .mlpackage 体积 = 目录递归求和（`du -sk` 同口径），不是参数量换算
  · ANE 派发 = `MLComputePlan` 逐算子读 `preferred_compute_device` 的类名
    ⚠️ 必须用 `.mlmodelc` 路径加载（coremltools 9.0 对 .mlpackage 直接 load 会 C++ abort）
    ⚠️ 必须按**类名**判断设备（`MLComputeDevice` 没有 `.type` 属性）
    ⚠️ 必须剔除 `const` / `constexpr_lut_to_dense` 等非计算条目，否则占比算错
  · 延迟 = `MLModel.predict` 计时，warmup 后取 p50/p95

用法：
    /usr/local/bin/python3.11 tools/v3_exp/v3code_export.py            # 全流程
    /usr/local/bin/python3.11 tools/v3_exp/v3code_export.py --skip-quant   # 跳过 4-bit
    /usr/local/bin/python3.11 tools/v3_exp/v3code_export.py --skip-latency # 跳过延迟

退出码：0=成功；3=CoreML 转换失败（会打印真实错误）。
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import torch  # noqa: E402
import torch.nn as nn  # noqa: E402

from src.model_v3 import V3Config, build_v3_model  # noqa: E402

#: 输出目录（放 /tmp，不污染仓库）
OUT_DIR = Path("/tmp/v3_model_code")
#: 输出名顺序（与 forward 返回 dict 的键一致）
OUTPUT_NAMES: Tuple[str, ...] = (
    "vertical", "horizontal", "handbrake", "brake",
    "super_brake", "ultimate", "confidence", "risk",
)


class _ExportWrapper(nn.Module):
    """把 forward 的 dict 输出转成 tuple，供 `torch.jit.trace` + `ct.convert` 使用。

    为什么要包一层：`torch.jit.trace` 对 dict 返回值的处理在 coremltools 侧
    不稳定（输出名无法可靠绑定），tuple 是 V2 已验证可用的形态
    （`model_v2.export_coreml` 的 forward 直接返回 tuple）。
    """

    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model

    def forward(self, image_hi: torch.Tensor, image_lo: torch.Tensor,
                lane: torch.Tensor, dets: torch.Tensor,
                det_mask: torch.Tensor, vehicle_state: torch.Tensor):
        out = self.model(
            image_hi=image_hi, image_lo=image_lo, lane=lane,
            dets=dets, det_mask=det_mask, vehicle_state=vehicle_state)
        return tuple(out[name] for name in OUTPUT_NAMES)


def dir_size_mb(path: Path) -> float:
    """目录递归求和（MB，1024 进制）。"""
    total = 0
    for p in path.rglob("*"):
        if p.is_file():
            total += p.stat().st_size
    return total / (1024 * 1024)


def build_dummy_inputs(cfg: V3Config, batch: int = 1) -> Tuple[torch.Tensor, ...]:
    """按输入契约构造 dummy 输入（与 `V3Model.forward` 的签名顺序一致）。"""
    return (
        torch.zeros(batch, cfg.num_hi_frames, 3, cfg.image_hi_h, cfg.image_hi_w),
        torch.zeros(batch, cfg.num_lo_frames, 3, cfg.image_lo_h, cfg.image_lo_w),
        torch.zeros(batch, 1, cfg.lane_size, cfg.lane_size),
        torch.zeros(batch, cfg.max_detections, cfg.det_feat_dim),
        torch.zeros(batch, cfg.max_detections),
        torch.zeros(batch, cfg.state_dim),
    )


def count_dispatch(mlmodel_path: Path) -> Dict[str, object]:
    """逐算子统计 CoreML 计算设备的派发结果。

    关键实现要点（都是踩过的坑，见 `02-temporal.md` §5.1）：
      1. `MLComputePlan.load_from_path(.mlpackage)` 在 coremltools 9.0 上会 C++ abort
         （新布局没有 coremldata.bin）→ 必须先 compile 拿到 `.mlmodelc` 路径。
      2. `MLComputeDevice` **没有** `.type` 属性，只能按**类名**判断设备。
         用 `getattr(dev, 'type', str(dev))` 会统计出"ANE 0%"的假象。
      3. `operations` 里混有 `const`（权重常量）与 `constexpr_lut_to_dense`
         （4-bit 量化的 LUT 解压，不是掉 CPU 的计算）→ 必须剔除，否则占比算错。
    """
    import coremltools as ct
    from coremltools.models.compute_plan import MLComputePlan

    mlmodel = ct.models.MLModel(str(mlmodel_path))
    compiled_path = mlmodel.get_compiled_model_path()
    plan = MLComputePlan.load_from_path(
        compiled_path, compute_units=ct.ComputeUnit.ALL)

    counts: Dict[str, int] = {"ANE": 0, "GPU": 0, "CPU": 0, "const": 0, "other": 0}
    examples: List[str] = []

    program = plan.model_structure.program
    for fname in program.functions:
        fn = program.functions[fname]
        block = fn.block
        for op in block.operations:
            op_name = getattr(op, "operator_name", "") or ""
            # 剔除非计算条目。两类都必须剔除，否则 ANE 占比会被严重错算：
            #   ① `const` —— 权重常量，不是算子
            #   ② `constexpr_lut_to_dense` —— 4-bit palettize 的 **LUT→稠密权重解压**，
            #      模型加载/内部还原权重时用，不是参与前向的计算算子。
            #      01-backbone.md §5.1 明确警告过：若计入分母，4-bit 模型的
            #      ANE 占比会被错算成 78.7%（我第一版实测正是 79.4%，踩同一个坑）。
            if op_name.startswith("const") or "lut_to_dense" in op_name:
                counts["const"] += 1
                continue
            try:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
                dev = usage.preferred_compute_device
                cls = type(dev).__name__
            except Exception as exc:      # 少数算子拿不到 usage，如实归 other
                counts["other"] += 1
                if len(examples) < 8:
                    examples.append(f"{op_name}: {type(exc).__name__}")
                continue
            if "NeuralEngine" in cls:
                counts["ANE"] += 1
            elif "GPU" in cls:
                counts["GPU"] += 1
            elif "CPU" in cls:
                counts["CPU"] += 1
            else:
                counts["other"] += 1
                if len(examples) < 8:
                    examples.append(f"{op_name}: {cls}")

    compute_total = counts["ANE"] + counts["GPU"] + counts["CPU"] + counts["other"]
    ratio = counts["ANE"] / compute_total if compute_total else 0.0
    return {
        "by_device": counts,
        "compute_ops": compute_total,
        "ane_ratio": ratio,
        "unrecognized_examples": examples,
    }


def bench_latency(mlmodel_path: Path, cfg: V3Config, iters: int = 40,
                  warmup: int = 10) -> Dict[str, float]:
    """实测 `MLModel.predict` 延迟（p50 / p95 / min / mean，毫秒）。

    ⚠️ 口径：用 0 输入而非随机输入 —— 本模型在 eval 态是确定性的，
       输入数值不影响耗时；用 0 输入可避免 Python 侧构造开销混入。
    """
    import numpy as np
    import coremltools as ct

    mlmodel = ct.models.MLModel(str(mlmodel_path))
    # CoreML 输入名 → numpy 数组（NHWC 之外的维度顺序由 TensorType shape 决定，
    # 这里与导出时的 shape 完全一致，故直接按同一 shape 构造）
    feed = {
        "image_hi": np.zeros((1, cfg.num_hi_frames, 3, cfg.image_hi_h, cfg.image_hi_w),
                             dtype=np.float32),
        "image_lo": np.zeros((1, cfg.num_lo_frames, 3, cfg.image_lo_h, cfg.image_lo_w),
                             dtype=np.float32),
        "lane": np.zeros((1, 1, cfg.lane_size, cfg.lane_size), dtype=np.float32),
        "dets": np.zeros((1, cfg.max_detections, cfg.det_feat_dim), dtype=np.float32),
        "det_mask": np.zeros((1, cfg.max_detections), dtype=np.float32),
        "vehicle_state": np.zeros((1, cfg.state_dim), dtype=np.float32),
    }
    for _ in range(warmup):
        mlmodel.predict(feed)
    samples: List[float] = []
    for _ in range(iters):
        t0 = time.perf_counter()
        mlmodel.predict(feed)
        samples.append((time.perf_counter() - t0) * 1000.0)
    samples_sorted = sorted(samples)
    p95_idx = max(0, int(round(0.95 * (len(samples_sorted) - 1))))
    return {
        "p50_ms": statistics.median(samples),
        "p95_ms": samples_sorted[p95_idx],
        "min_ms": min(samples),
        "mean_ms": statistics.fmean(samples),
        "iters": iters,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="V3 CoreML 导出实测")
    parser.add_argument("--skip-quant", action="store_true", help="跳过 4-bit palettize")
    parser.add_argument("--skip-latency", action="store_true", help="跳过延迟采样")
    parser.add_argument("--skip-ane", action="store_true", help="跳过逐算子派发统计")
    parser.add_argument("--ios", type=int, default=17, choices=[17, 18],
                        help="minimum_deployment_target（4-bit 量化要求 iOS18，默认 17）")
    parser.add_argument("--quant-mode", type=str, default="palettize",
                        choices=["palettize", "linear"],
                        help="4-bit 量化方式：palettize（LUT，实测 ANE 派发保持 100%%）/ "
                             "linear（体积更小但实测 ANE 掉到 66%%、延迟反而变慢）")
    args = parser.parse_args()

    import coremltools as ct
    print(f"coremltools {ct.__version__} / torch {torch.__version__}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    cfg = V3Config()
    report: Dict[str, object] = {}

    # ── 1. 构建 + 折叠 + trace ────────────────────────────────────────
    print("\n[1/6] 构建模型（训练态）→ reparameterize → trace")
    model = build_v3_model(deploy=False, cfg=cfg)
    # ⚠️ 必须训练态构建后 reparameterize；直接 deploy=True 构建会把多分支权重丢掉
    model.reparameterize()
    model.eval()
    counts = model.get_param_count()
    report["params_deploy"] = counts["deploy_total"]
    report["params_train_with_tmp"] = counts["total"]
    print(f"  部署态参数 = {counts['deploy_total']:,} ({counts['deploy_total']/1e6:.3f}M)")

    wrapper = _ExportWrapper(model).eval()
    dummy = build_dummy_inputs(cfg, batch=1)
    t0 = time.perf_counter()
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, dummy, strict=False)
    report["trace_seconds"] = time.perf_counter() - t0
    print(f"  trace 完成 ({report['trace_seconds']:.1f}s)")

    # ── 2. 转 CoreML（fp16）──────────────────────────────────────────
    # ⚠️ 4-bit palettize 要求 iOS18 起步（实测：iOS17 目标会抛
    #    "The 4-bit quantization is supported since iOS18"）。
    #    因此用 --ios 18 时 fp16/int4 都是 iOS18 目标，便于同口径比较体积。
    deploy_target = ct.target.iOS18 if args.ios >= 18 else ct.target.iOS17
    print(f"\n[2/6] 转 CoreML（fp16 / mlprogram / iOS{args.ios}）")
    fp16_path = OUT_DIR / f"v3_fp16_ios{args.ios}.mlpackage"
    if fp16_path.exists():
        shutil.rmtree(fp16_path)
    t0 = time.perf_counter()
    try:
        mlmodel_fp16 = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="image_hi",
                              shape=(1, cfg.num_hi_frames, 3, cfg.image_hi_h, cfg.image_hi_w)),
                ct.TensorType(name="image_lo",
                              shape=(1, cfg.num_lo_frames, 3, cfg.image_lo_h, cfg.image_lo_w)),
                ct.TensorType(name="lane", shape=(1, 1, cfg.lane_size, cfg.lane_size)),
                ct.TensorType(name="dets", shape=(1, cfg.max_detections, cfg.det_feat_dim)),
                ct.TensorType(name="det_mask", shape=(1, cfg.max_detections)),
                ct.TensorType(name="vehicle_state", shape=(1, cfg.state_dim)),
            ],
            outputs=[ct.TensorType(name=n) for n in OUTPUT_NAMES],
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=deploy_target,
            convert_to="mlprogram",
        )
    except Exception as exc:
        print(f"  ❌ CoreML 转换失败：{type(exc).__name__}: {exc}")
        report["fp16_error"] = f"{type(exc).__name__}: {exc}"
        (OUT_DIR / "report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        return 3
    report["fp16_convert_seconds"] = time.perf_counter() - t0
    mlmodel_fp16.save(str(fp16_path))
    report["fp16_size_mb"] = dir_size_mb(fp16_path)
    print(f"  ✅ fp16 导出成功：{report['fp16_size_mb']:.2f} MB "
          f"（{report['fp16_convert_seconds']:.1f}s）")

    # ── 3. 4-bit 量化 ────────────────────────────────────────────────
    if not args.skip_quant:
        print(f"\n[3/6] 4-bit 量化（mode={args.quant_mode}）")
        int4_path = OUT_DIR / f"v3_int4_{args.quant_mode}_ios{args.ios}.mlpackage"
        if int4_path.exists():
            shutil.rmtree(int4_path)
        try:
            from coremltools.optimize.coreml import OptimizationConfig
            t0 = time.perf_counter()
            if args.quant_mode == "palettize":
                # ★ 推荐路径：4-bit **palettization**（LUT 查表）。
                # 为什么不用 linear_quantize_weights：实测 4-bit 线性量化会把权重
                # 拆成 `constexpr_blockwise_shift_scale` 之类的算子，整图 ANE 派发
                # 从 100% 掉到 66%（64 个算子落 GPU），延迟反而 4.30ms→6.67ms。
                # palettization 保留单个 LUT 常量，计算算子仍是原生的 conv/linear。
                from coremltools.optimize.coreml import (
                    OpPalettizerConfig, palettize_weights)
                op_config = OpPalettizerConfig(
                    mode="kmeans", nbits=4, granularity="per_tensor")
                config = OptimizationConfig(global_config=op_config)
                quantized = palettize_weights(mlmodel_fp16, config)
            else:
                # 对照路径：4-bit 线性量化（体积更小，但 ANE 派发可能变差）
                from coremltools.optimize.coreml import (
                    OpLinearQuantizerConfig, linear_quantize_weights)
                op_config = OpLinearQuantizerConfig(
                    mode="linear_symmetric", dtype="int4", granularity="per_channel")
                config = OptimizationConfig(global_config=op_config)
                quantized = linear_quantize_weights(mlmodel_fp16, config)
            quantized.save(str(int4_path))
            report["int4_size_mb"] = dir_size_mb(int4_path)
            report["int4_quant_seconds"] = time.perf_counter() - t0
            report["int4_mode"] = args.quant_mode
            print(f"  ✅ 4-bit 量化成功：{report['int4_size_mb']:.2f} MB "
                  f"（{report['int4_size_mb']/report['fp16_size_mb']:.2f}× 压缩）")
        except Exception as exc:
            # 量化失败不掩盖：如实记录，fp16 结果仍然有效
            print(f"  ⚠ 4-bit 量化失败：{type(exc).__name__}: {exc}")
            report["int4_error"] = f"{type(exc).__name__}: {exc}"
            int4_path = None
    else:
        int4_path = None

    target_path = int4_path if int4_path is not None and int4_path.exists() else fp16_path

    # ── 4. 逐算子 ANE 派发 ──────────────────────────────────────────
    if not args.skip_ane:
        print(f"\n[4/6] 逐算子 ANE 派发统计（{target_path.name}）")
        try:
            dispatch = count_dispatch(target_path)
            report["dispatch"] = dispatch
            bd = dispatch["by_device"]
            print(f"  计算算子 {dispatch['compute_ops']} 个："
                  f"ANE={bd['ANE']} GPU={bd['GPU']} CPU={bd['CPU']} other={bd['other']}；"
                  f"const/非计算 {bd['const']} 个")
            print(f"  ANE 占比 = {dispatch['ane_ratio']*100:.1f}%")
            if dispatch["unrecognized_examples"]:
                print(f"  未识别设备样例：{dispatch['unrecognized_examples']}")
        except Exception as exc:
            print(f"  ⚠ 派发统计失败：{type(exc).__name__}: {exc}")
            report["dispatch_error"] = f"{type(exc).__name__}: {exc}"
    else:
        print("\n[4/6] 跳过 ANE 派发统计（--skip-ane）")

    # ── 5. 延迟 ─────────────────────────────────────────────────────
    if not args.skip_latency:
        print(f"\n[5/6] 延迟实测（{target_path.name}）")
        try:
            lat = bench_latency(target_path, cfg)
            report["latency"] = lat
            print(f"  p50 = {lat['p50_ms']:.3f} ms，p95 = {lat['p95_ms']:.3f} ms，"
                  f"min = {lat['min_ms']:.3f} ms（{lat['iters']} 次）")
        except Exception as exc:
            print(f"  ⚠ 延迟实测失败：{type(exc).__name__}: {exc}")
            report["latency_error"] = f"{type(exc).__name__}: {exc}"
    else:
        print("\n[5/6] 跳过延迟实测（--skip-latency）")

    # ── 6. 数值一致性（CoreML vs PyTorch）───────────────────────────
    print("\n[6/6] 数值一致性（CoreML fp16 vs PyTorch fp32，全零输入）")
    try:
        import numpy as np
        ml = ct.models.MLModel(str(fp16_path))
        feed = {
            "image_hi": np.zeros((1, cfg.num_hi_frames, 3, cfg.image_hi_h, cfg.image_hi_w),
                                 dtype=np.float32),
            "image_lo": np.zeros((1, cfg.num_lo_frames, 3, cfg.image_lo_h, cfg.image_lo_w),
                                 dtype=np.float32),
            "lane": np.zeros((1, 1, cfg.lane_size, cfg.lane_size), dtype=np.float32),
            "dets": np.zeros((1, cfg.max_detections, cfg.det_feat_dim), dtype=np.float32),
            "det_mask": np.zeros((1, cfg.max_detections), dtype=np.float32),
            "vehicle_state": np.zeros((1, cfg.state_dim), dtype=np.float32),
        }
        cm_out = ml.predict(feed)
        with torch.no_grad():
            pt_out = model(**{
                "image_hi": torch.zeros(1, cfg.num_hi_frames, 3, cfg.image_hi_h, cfg.image_hi_w),
                "image_lo": torch.zeros(1, cfg.num_lo_frames, 3, cfg.image_lo_h, cfg.image_lo_w),
                "lane": torch.zeros(1, 1, cfg.lane_size, cfg.lane_size),
                "dets": torch.zeros(1, cfg.max_detections, cfg.det_feat_dim),
                "det_mask": torch.zeros(1, cfg.max_detections),
                "vehicle_state": torch.zeros(1, cfg.state_dim),
            })
        consistency = {}
        for name in OUTPUT_NAMES:
            a = cm_out[name].astype("float32").ravel()
            b = pt_out[name].numpy().ravel()
            abs_diff = float(abs(a - b).max())
            denom = float(abs(b).max())
            consistency[name] = {
                "abs_diff_max": abs_diff,
                "rel_diff_max": (abs_diff / denom) if denom > 0 else abs_diff,
            }
        report["consistency"] = consistency
        worst = max(v["abs_diff_max"] for v in consistency.values())
        print(f"  最大绝对误差 = {worst:.3e}（fp16 量化正常量级 <1e-2）")
    except Exception as exc:
        print(f"  ⚠ 一致性检查失败：{type(exc).__name__}: {exc}")
        report["consistency_error"] = f"{type(exc).__name__}: {exc}"

    # ── 保存报告 ────────────────────────────────────────────────────
    (OUT_DIR / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n报告已写入 {OUT_DIR / 'report.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
