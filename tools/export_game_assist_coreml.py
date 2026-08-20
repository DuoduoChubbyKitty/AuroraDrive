#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将 game_assist_control 的 PyTorch 权重导出为 CoreML .mlmodelc 部署格式。

独立脚本：仅依赖 src.model + torch + coremltools，不依赖 train_mono 的重依赖，
可放在 python3.12 venv 中使用（项目主 venv 是 py3.14，coremltools 无可用轮子）。

★ 修复原 convert_torch_to_coreml 的致命 bug：
  训练存档是「训练态」权重（RepVGG 多分支：rbr_3x3 / rbr_1x1 / rbr_identity）。
  若用 build_m9_mono(deploy=True) 直接 load_state_dict(strict=False)，
  融合态结构只有 rbr_reparam 键，多分支权重全部被静默丢弃 → 导出随机权重模型。
  正确做法：deploy=False 构建 → load → model.reparameterize() 融合 → trace。
  本脚本自动检测权重态并选择正确路径。

量化(--precision)：
  float32  默认，无量化
  float16  半精度浮点：体积减半、ANE/GPU 原生加速、精度几乎无损（推荐常规档）
  int8     weights-only 8 位权重量化（linear_symmetric / per_channel）：体积更小、更激进；
           控制模型输出为连续回归量，量化误差可能引入转向抖动，需验证差异

用法：
  ./venv312/bin/python3 tools/export_game_assist_coreml.py \
      --src checkpoints/game_assist_control/best_model.pt \
      --out models/game_assist_control.mlmodelc \
      --precision int8
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
import coremltools.optimize.coreml as cto
from coremltools.optimize.coreml import OptimizationConfig, OpLinearQuantizerConfig

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT))
from src.model import build_m9_mono


def _load_sd(src: Path):
    ckpt = torch.load(src, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    # 剥离 torch.compile 包装前缀
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    return sd


def main():
    ap = argparse.ArgumentParser(description="game_assist_control → CoreML .mlmodelc 导出")
    ap.add_argument("--src", default=str(_ROOT / "checkpoints" / "game_assist_control" / "best_model.pt"),
                    help="PyTorch 存档 (.pt)，含 model_state_dict")
    ap.add_argument("--out", default=str(_ROOT / "models" / "game_assist_control.mlmodelc"),
                    help="输出 .mlmodelc 目录路径")
    ap.add_argument("--img_h", type=int, default=180)
    ap.add_argument("--img_w", type=int, default=320)
    ap.add_argument("--precision", choices=["float32", "float16", "int8"], default="float32",
                    help="量化精度: float32(默认) / float16(半精度,体积减半) / int8(权重8位,更激进)")
    args = ap.parse_args()

    src = Path(args.src)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    print(f"[导出] 读取权重: {src}")
    sd = _load_sd(src)

    # —— 正确加载（修复 bug 的核心）——
    has_reparam = any("rbr_reparam" in k for k in sd.keys())
    if has_reparam:
        print("[导出] 权重为融合态(rbr_reparam) → deploy=True 构建直接 load")
        model = build_m9_mono(deploy=True)
        res = model.load_state_dict(sd, strict=False)
    else:
        print("[导出] 权重为训练态(rbr_3x3 多分支) → deploy=False 构建 + reparameterize 融合")
        model = build_m9_mono(deploy=False)
        res = model.load_state_dict(sd, strict=False)
        model.reparameterize()  # 多分支 → 纯 3x3
    print(f"[导出] load_state_dict: missing={len(res.missing_keys)} unexpected={len(res.unexpected_keys)}")
    model.eval()

    # —— 参考推理（sanity）——
    dummy_img = torch.zeros(1, 3, args.img_h, args.img_w)
    dummy_vs = torch.zeros(1, 6)
    with torch.no_grad():
        ref = model(dummy_img, dummy_vs)
    ref_vals = [float(r.flatten()[0]) for r in ref]
    print(f"[导出] 参考输出 steer/throttle/brake = {ref_vals}")

    # —— jit.trace 固化 ——
    with torch.no_grad():
        traced = torch.jit.trace(model, (dummy_img, dummy_vs))
    print("[导出] ✓ jit.trace 成功")

    # —— CoreML 转换 ——
    convert_kwargs = dict(
        source="pytorch",
        convert_to="neuralnetwork",
        minimum_deployment_target=ct.target.macOS11,
        inputs=[
            ct.TensorType(name="image", shape=(1, 3, args.img_h, args.img_w)),
            ct.TensorType(name="vehicle_state", shape=(1, 6)),
        ],
        outputs=[
            ct.TensorType(name="steer"),
            ct.TensorType(name="throttle"),
            ct.TensorType(name="brake"),
        ],
    )
    if args.precision == "float16":
        convert_kwargs["compute_precision"] = ct.precision.FLOAT16
    mlmodel = ct.convert(traced, **convert_kwargs)
    if args.precision == "int8":
        print("[导出] 应用 weights-only int8 量化 (linear_symmetric / per_channel)...")
        config = OptimizationConfig(
            op_linear_quantizer_config=OpLinearQuantizerConfig(dtype=np.int8)
        )
        mlmodel = cto.linear_quantize_weights(mlmodel, config)
        print("[导出] ✓ int8 权重量化完成")

    spec = mlmodel.get_spec()
    spec.description.metadata.shortDescription = "AuroraDrive 游戏辅助控制模型 (game_assist_control)"
    spec.description.metadata.author = "AuroraDrive"
    spec.description.metadata.versionString = f"1.0-{args.precision}"

    mlpackage = out.with_suffix(".mlpackage")
    if mlpackage.exists():
        shutil.rmtree(mlpackage)
    mlmodel.save(str(mlpackage))
    print(f"[导出] ✓ 源模型: {mlpackage}")

    # —— 编译 .mlpackage → .mlmodelc ——
    if out.exists():
        shutil.rmtree(out)
    cmd = ["xcrun", "coremlc", "compile", str(mlpackage), str(out.parent)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        print(f"[导出] ✓ 编译 (xcrun): {out}")
    else:
        print(f"[导出] xcrun 失败（{r.stderr.strip()[:80]}），退到 ct.utils.compile_model")
        compiled = ct.utils.compile_model(str(mlpackage))
        cp = Path(compiled.path if hasattr(compiled, "path") else str(compiled))
        if cp != out:
            if out.exists():
                shutil.rmtree(out)
            shutil.move(str(cp), str(out))
        print(f"[导出] ✓ 编译 (ct.utils): {out}")

    # —— 验证一致性 ——
    # 优先用 .mlpackage 源（未编译也可 CPU 推理）；若 .mlmodelc 完整
    # （真机 xcrun 编译）则用它。沙箱无 Xcode 时 ct.utils 编译的 .mlmodelc
    # 可能缺 Manifest.json，此时用 mlpackage 兜底验证转换正确性。
    verify_path = mlpackage if mlpackage.exists() else out
    loaded = ct.models.MLModel(str(verify_path))
    pred = loaded.predict({
        "image": dummy_img.numpy(),
        "vehicle_state": dummy_vs.numpy(),
    })
    cm_vals = [float(pred["steer"].flatten()[0]),
               float(pred["throttle"].flatten()[0]),
               float(pred["brake"].flatten()[0])]
    print(f"[导出] mlmodelc 验证输出 = {cm_vals}")
    tol = 1e-3 if args.precision in ("float32", "float16") else 5e-2
    diff = max(abs(a - b) for a, b in zip(ref_vals, cm_vals))
    print(f"[导出] 与参考最大差异 = {diff:.6f}  {'✓ 可接受' if diff < tol else '⚠ 超阈值(请评估量化失真)'}")
    print(f"[导出] 完成 → {out}  (precision={args.precision})")


if __name__ == "__main__":
    main()
