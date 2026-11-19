#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""export_wm_static.py — 把静态世界模型导出成 CoreML（float16）并**读回校验**

导出什么
    只导出部署需要的两个子网，合成一张图、两个输出：
        input  image       [1, 3, 224, 384]  float32   RGB, CHW, 已归一化（见下）
        output latent      [1, 256]          float32/16 ← encode() 结果（task-3 契约维度）
        output next_latent [1, 256]          float32/16 ← predict_next() 结果
    EMA target 编码器是训练期的脚手架，**不导出**（它只用来生成被预测的目标）。

为什么一次前向给两个输出
    部署侧既要当前表征（供对齐层/规划用），又要未来表征（预判世界怎么变）。
    分两次调用等于把 encoder 的卷积算两遍；一张图两个输出最省。

输入为什么是 TensorType 而不是 CoreML 的 ImageType
    与仓库既有做法保持一致（tools/convert_e2e_to_coreml.py 的注释写明：Swift 侧
    InferenceEngine 已自行完成 RGB 提取 + /255，所以 CoreML 只吃纯 Tensor）。
    这里同理：**归一化在 Swift 侧做**，CoreML 只做「拿到 [1,3,224,384] 就出两个
    256 维向量」。归一化常数必须与训练时完全相同：
        mean = [0.2717, 0.3074, 0.3251]
        std  = [0.2099, 0.1870, 0.1888]
    这两个数组是 tools/train_wm_static.py 里的 PIXEL_MEAN/PIXEL_STD，本脚本从那里
    导入并打印到日志，避免「训练用一套、部署用另一套」的静默错配。

为什么用 float16
    M 系列芯片的 ANE/GPU 对 fp16 有原生支持，体积减半、带宽减半。代价是数值精度
    下降，所以导出后必须做**与 PyTorch 的逐点对比**（见 verify_*），而不是只看
    「转成功就算完」。

用法
    /usr/local/bin/python3.11 tools/export_wm_static.py \
        --ckpt data/wm_static/ckpt_best.pt --out models/wm_static.mlmodelc
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path
from typing import Dict, Tuple

import numpy as np
import torch

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))
sys.path.insert(0, str(_ROOT / "tools"))

from wm_static import (  # noqa: E402
    ExportWrapper,
    StaticWmConfig,
    StaticWorldModel,
)
from train_wm_static import PIXEL_MEAN, PIXEL_STD  # noqa: E402  归一化契约同源


def load_model(ckpt_path: Path, device: torch.device) -> Tuple[StaticWorldModel, Dict]:
    """从断点恢复模型，并校验超参没有被悄悄改过。

    为什么要校验：CoreML 的形状一旦和训练时不一致，Swift 侧会拿到全错误的张量，
    但训练/导出两个环节都不会报错——这是最难排查的一类线上事故。
    """
    if not ckpt_path.exists():
        raise FileNotFoundError(
            f"断点不存在：{ckpt_path}\n"
            f"请先训练：bash scripts/build-lock.sh run \"wm-static 训练\" -- "
            f"/usr/local/bin/python3.11 tools/train_wm_static.py"
        )
    ckpt = torch.load(ckpt_path, map_location=device, weights_only=False)

    saved_cfg = StaticWmConfig(**{
        k: tuple(v) if isinstance(v, list) else v for k, v in ckpt["cfg"].items()
    })
    model = StaticWorldModel(saved_cfg).to(device)
    model.online.load_state_dict(ckpt["online"])
    model.predictor.load_state_dict(ckpt["predictor"])
    model.target.load_state_dict(ckpt["target"])
    model.eval()
    return model, ckpt


def verify_torch_vs_coreml(
    torch_wrapper: ExportWrapper,
    coreml_model,
    cfg: StaticWmConfig,
    n_trials: int = 3,
) -> Dict[str, float]:
    """拿同一批输入分别喂 PyTorch 与 CoreML，比较两个输出的数值一致性。

    为什么必须做：float16 量化和图重写都可能改变数值。只看「转换没报错」不等于
    「转换正确」——如果某个算子被错误折叠，输出会是垃圾但形状完全正确。
    判定标准用「余弦相似度」而不是绝对误差：部署关心的是「方向对不对」，
    fp16 的尺度误差不影响下游，方向错了才是致命的。
    """
    max_abs = 0.0
    min_cos = 1.0

    for trial in range(n_trials):
        rng = np.random.default_rng(trial)
        image = rng.standard_normal(
            (1, cfg.in_ch, cfg.image_h, cfg.image_w)
        ).astype(np.float32)

        with torch.no_grad():
            t_latent, t_next = torch_wrapper(torch.from_numpy(image))
        t_latent = t_latent.numpy()
        t_next = t_next.numpy()

        out = coreml_model.predict({"image": image})
        c_latent = np.asarray(out["latent"]).reshape(1, -1)
        c_next = np.asarray(out["next_latent"]).reshape(1, -1)

        for a, b in ((t_latent, c_latent), (t_next, c_next)):
            max_abs = max(max_abs, float(np.abs(a - b).max()))
            a = a.ravel().astype(np.float64)
            b = b.ravel().astype(np.float64)
            cos = float(
                a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)
            )
            min_cos = min(min_cos, cos)

    return {"max_abs_diff": max_abs, "min_cosine": min_cos, "n_trials": float(n_trials)}


#: 用系统 CoreML 运行时读回编译产物的 Swift 小程序。
#: 为什么不用 coremltools：见 main() 里 ①/② 分层的注释（coremltools 读不了 .mlmodelc）。
#: dtype 65552 = Float16，65568 = Float32（CoreML 的 DataType 原始值）。
_SWIFT_PROBE = r"""
import Foundation
import CoreML

let url = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = .all
    let model = try MLModel(contentsOf: url, configuration: cfg)
    let d = model.modelDescription
    print("LOAD_OK")
    for (name, desc) in d.inputDescriptionsByName {
        if let a = desc.multiArrayConstraint {
            print("IN|\(name)|\(a.shape.map { $0.intValue }.map(String.init).joined(separator: ","))|\(a.dataType.rawValue)")
        } else { print("IN|\(name)|NOT_MULTIARRAY|\(desc.type)") }
    }
    for (name, desc) in d.outputDescriptionsByName {
        if let a = desc.multiArrayConstraint {
            print("OUT|\(name)|\(a.shape.map { $0.intValue }.map(String.init).joined(separator: ","))|\(a.dataType.rawValue)")
        } else { print("OUT|\(name)|NOT_MULTIARRAY|\(desc.type)") }
    }
} catch {
    print("LOAD_FAIL|\(error)")
    exit(1)
}
"""


def verify_compiled_with_swift(mlmodelc_path: Path) -> Dict:
    """用系统 CoreML 运行时加载编译后的 .mlmodelc，读回输入/输出形状与 dtype。

    为什么要绕到 Swift：coremltools 9.0 没有加载 .mlmodelc 的 API（只吃 .mlpackage），
    而 .mlmodelc 才是最终交付物。「编译没报错」不等于「能被系统加载」——比如权重格式
    不对、op 版本与部署目标不匹配，都是编译通过但加载失败。用真实运行时加载一次，
    才能确认这个产物在 iOS/macOS 侧真的可用。
    """
    probe_src = Path(tempfile.gettempdir()) / "wm_static_probe.swift"
    probe_bin = Path(tempfile.gettempdir()) / "wm_static_probe"
    probe_src.write_text(_SWIFT_PROBE, encoding="utf-8")

    # 只在二进制不存在或源码更新时才重编译，省掉每次 10~20 秒的 swiftc 开销。
    if not probe_bin.exists() or probe_bin.stat().st_mtime < probe_src.stat().st_mtime:
        compile_proc = subprocess.run(
            ["xcrun", "swiftc", "-O", str(probe_src), "-o", str(probe_bin)],
            capture_output=True,
            text=True,
        )
        if compile_proc.returncode != 0:
            raise RuntimeError(
                "Swift 探针编译失败（需要 Xcode 命令行工具）: "
                + compile_proc.stderr[:800]
            )

    proc = subprocess.run([str(probe_bin), str(mlmodelc_path)],
                          capture_output=True, text=True)
    if proc.returncode != 0 or "LOAD_OK" not in proc.stdout:
        raise RuntimeError(
            f"系统 CoreML 无法加载编译产物 {mlmodelc_path}：\n"
            f"stdout={proc.stdout}\nstderr={proc.stderr[:800]}"
        )

    inputs, outputs, dtype_value = [], [], None
    for line in proc.stdout.splitlines():
        parts = line.strip().split("|")
        if parts[0] == "IN":
            inputs.append([int(v) for v in parts[2].split(",")])
        elif parts[0] == "OUT":
            outputs.append([int(v) for v in parts[2].split(",")])
            dtype_value = int(parts[3])
    return {
        "inputs": inputs,
        "outputs": outputs,
        "dtype": {65552: "Float16", 65568: "Float32"}.get(dtype_value, str(dtype_value)),
    }


def dir_size_mb(path: Path) -> float:
    """递归统计目录体积（mlmodelc 是一个目录，里面有 model.mil / weights.bin 等）。"""
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            total += item.stat().st_size
    return total / 1024 / 1024


def main(argv=None) -> int:
    warnings.filterwarnings("ignore")  # coremltools 对 torch 2.13 有未测试警告，属正常

    parser = argparse.ArgumentParser(description="导出静态世界模型到 CoreML")
    parser.add_argument("--ckpt", type=str, default=str(_ROOT / "data/wm_static/ckpt_best.pt"))
    parser.add_argument("--out", type=str, default=str(_ROOT / "models/wm_static.mlmodelc"))
    parser.add_argument("--skip-verify", action="store_true", help="跳过数值一致性校验（不推荐）")
    args = parser.parse_args(argv)

    import coremltools as ct

    ckpt_path = Path(args.ckpt)
    out_path = Path(args.out)
    device = torch.device("cpu")  # 导出/校验用 CPU：结果确定性更好，且不占 GPU 锁资源

    print(f"[导出] 断点 {ckpt_path}")
    model, ckpt = load_model(ckpt_path, device)
    cfg = model.cfg
    wrapper = ExportWrapper(model).eval()

    print(f"[导出] 输入 image [1,{cfg.in_ch},{cfg.image_h},{cfg.image_w}] float32")
    print(f"[导出] 归一化契约 mean={PIXEL_MEAN} std={PIXEL_STD}（Swift 侧必须一致）")
    print(f"[导出] 断点 step={ckpt.get('global_step')} epoch={ckpt.get('epoch')}")

    # ---- trace：CoreML 走 TorchScript 路线，先 trace 再转换 ----
    example = torch.zeros(1, cfg.in_ch, cfg.image_h, cfg.image_w)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)

    # ---- 转 CoreML，fp16 ----
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, cfg.in_ch, cfg.image_h, cfg.image_w))],
        outputs=[
            ct.TensorType(name="latent"),
            ct.TensorType(name="next_latent"),
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
    )

    # ---- 先存 mlpackage，再用 xcrun 编译成 mlmodelc ----
    tmp_dir = Path(tempfile.mkdtemp(prefix="wm_static_export_"))
    package_path = tmp_dir / "wm_static.mlpackage"
    mlmodel.save(str(package_path))
    print(f"[导出] mlpackage 已生成：{package_path}")

    if out_path.exists():
        # 覆盖前先备份一份，防止一次失败的导出把上一版可用模型毁掉。
        backup = out_path.with_name(out_path.name + ".bak")
        if backup.exists():
            shutil.rmtree(backup)
        shutil.move(str(out_path), str(backup))
        print(f"[导出] 已备份旧模型到 {backup}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    compile_result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(package_path), str(out_path.parent)],
        capture_output=True,
        text=True,
    )
    if compile_result.returncode != 0:
        raise RuntimeError(
            "coremlcompiler 编译失败：\n"
            f"stdout={compile_result.stdout}\nstderr={compile_result.stderr}"
        )
    # coremlcompiler 会在目标目录下生成 <name>.mlmodelc
    produced = out_path.parent / (package_path.stem + ".mlmodelc")
    if produced != out_path:
        if out_path.exists():
            shutil.rmtree(out_path)
        shutil.move(str(produced), str(out_path))
    print(f"[导出] mlmodelc 已生成：{out_path}")

    # ---- 读回校验：形状 + 数值 + 体积（三项都要实测报数）----
    #
    # 这里有个容易踩的坑，必须写清楚：
    #   coremltools 9.0 的 ct.models.MLModel() **只能加载 .mlpackage**（它内部按
    #   mlpackage 解析，要求存在 Manifest.json）。对编译后的 .mlmodelc 直接调用会报
    #       RuntimeError: A valid manifest does not exist at path: .../Manifest.json
    #   这不是导出坏了 —— 拿仓库里已有的 models/_backup_m9_v2_ctl_20261015.mlmodelc
    #   做同样调用，报的是完全一样的错。
    # 所以校验分两层，各用各的正规工具：
    #   ① .mlpackage：用 coremltools 读规格 + 做 PyTorch 数值对比（这是转换产物，
    #      数值等价性在这一层验证才有效）；
    #   ② .mlmodelc ：用 Swift 原生 CoreML 运行时加载，读回输入/输出形状与 dtype
    #      （这是最终交付物，必须证明它真能被系统加载，而不只是"编译没报错"）。
    print("\n[校验] ① 读回 .mlpackage 规格并做数值对比")
    loaded = ct.models.MLModel(str(package_path))

    spec_inputs = [
        (str(i.name), list(i.type.multiArrayType.shape))
        for i in loaded.get_spec().description.input
    ]
    spec_outputs = [
        (str(o.name), list(o.type.multiArrayType.shape))
        for o in loaded.get_spec().description.output
    ]
    print(f"[校验] 输入 = {spec_inputs}")
    print(f"[校验] 输出 = {spec_outputs}")

    expected_in = [("image", [1, cfg.in_ch, cfg.image_h, cfg.image_w])]
    expected_out = [("latent", [1, cfg.latent_dim]), ("next_latent", [1, cfg.latent_dim])]
    if spec_inputs != expected_in:
        raise AssertionError(f"输入形状不符：{spec_inputs} != {expected_in}")
    if spec_outputs != expected_out:
        raise AssertionError(f"输出形状不符：{spec_outputs} != {expected_out}")
    print("[校验] ① .mlpackage 形状与设计一致 ✅")

    size_mb = dir_size_mb(out_path)
    print(f"[校验] 实测体积 = {size_mb:.2f} MB（{out_path}，编译后交付物）")

    result = {}
    if not args.skip_verify:
        print("[校验] PyTorch vs CoreML 数值一致性")
        result = verify_torch_vs_coreml(wrapper, loaded, cfg)
        print(
            f"[校验] max|Δ|={result['max_abs_diff']:.6f} "
            f"min_cosine={result['min_cosine']:.6f} "
            f"(n_trials={int(result['n_trials'])})"
        )
        # 阈值：余弦 >0.999 视为等价。fp16 下这已经是很严的要求；
        # 若达不到，说明导出有问题（而不是「精度正常损失」）。
        if result["min_cosine"] < 0.999:
            raise AssertionError(
                f"CoreML 与 PyTorch 输出不一致（min_cosine={result['min_cosine']:.6f}）"
                " —— 导出有误，不要直接交付"
            )
        print("[校验] ① 数值一致 ✅")

    # ---- ② 用 Swift 原生运行时加载编译后的 .mlmodelc ----
    # 为什么必须单独做这一步：coremltools 读不了 .mlmodelc，只验 mlpackage 等于
    # 没验最终交付物。这里调用 xcrun swiftc（Xcode 已装）现场编译一个小程序，
    # 让系统 CoreML 真的把模型加载起来并打印形状；失败就让整个导出失败。
    print("\n[校验] ② 用系统 CoreML 运行时加载 .mlmodelc")
    compiled_shapes = verify_compiled_with_swift(out_path)
    print(f"[校验] ② 编译产物可加载，输入={compiled_shapes['inputs']} "
          f"输出={compiled_shapes['outputs']} dtype={compiled_shapes['dtype']}")
    if compiled_shapes["inputs"] != [[1, cfg.in_ch, cfg.image_h, cfg.image_w]]:
        raise AssertionError(
            f"编译产物的输入形状不符：{compiled_shapes['inputs']}"
        )
    if compiled_shapes["outputs"] != [[1, cfg.latent_dim], [1, cfg.latent_dim]]:
        raise AssertionError(
            f"编译产物的输出形状不符：{compiled_shapes['outputs']}"
        )
    print("[校验] ② 编译产物形状与设计一致 ✅")

    # ---- 结果落盘，供 report.md 直接引用（不手抄数字）----
    import json

    summary = {
        "ckpt": str(ckpt_path),
        "out": str(out_path),
        "size_mb": round(size_mb, 3),
        "inputs": spec_inputs,
        "outputs": spec_outputs,
        "latent_dim": cfg.latent_dim,
        "horizon": cfg.horizon,
        "pixel_mean": list(PIXEL_MEAN),
        "pixel_std": list(PIXEL_STD),
        "compute_precision": "FLOAT16",
        "torch_vs_coreml": result,
        "compiled_runtime_check": compiled_shapes,
        "global_step": ckpt.get("global_step"),
    }
    summary_path = _ROOT / "data/wm_static/export_summary.json"
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n[完成] 摘要写入 {summary_path}")
    shutil.rmtree(tmp_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
