#!/usr/bin/env python3
"""把 m9_mono.onnx (E2E 端到端控制模型) 转成 CoreML (.mlpackage + .mlmodelc)。

背景：与 convert_yolo_to_coreml.py 同路线（coremltools 9.0 无 ONNX frontend）：
      onnx --(onnx2torch)--> torch --(jit.trace+freeze)--> coremltools

模型规格（来自 InferenceEngine.swift / tools/export_game_assist_coreml.py）：
  输入 image:         [1, 3, 180, 320]  Float32, CHW, 归一化 [0,1], RGB
                      （InferenceEngine.preprocessImage 已做 RGB 提取 + /255，
                        所以 CoreML 这里用纯 TensorType，不做颜色/归一化转换）
  输入 vehicle_state: [1, 6]            Float32  [speed, rpm, gear, speed_norm, gear_norm, reserved]
  输出 steer:         [1] tanh   ∈ [-1,1]
  输出 throttle:      [1] sigmoid ∈ [0,1]
  输出 brake:         [1] sigmoid ∈ [0,1]

注意：InferenceEngine 已自行完成图像预处理（RGB CHW /255），因此 CoreML 输入
采用 TensorType 直接吃 [1,3,180,320] Float32，与 App 实际喂入的数据严格一致。
"""
import argparse
import sys
import shutil
import tempfile
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import numpy as np
import onnx
import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent
MODELS = _ROOT / "models"

INPUT_H, INPUT_W = 180, 320


# ---------------------------------------------------------------- opset 降级
def downgrade_opset(src: Path, dst: Path) -> None:
    """与 YOLO 转换一致：去掉 Reshape 的 allowzero、Resize 的不支持属性，降到 opset13。

    额外处理 ReduceMean：opset13+ 把 axes 作为第二输入（动态），而 onnx2torch 的
    OnnxReduceStaticAxes 期望 axes 作为属性。这里把第二输入（必为常量 initializer）
    抽成 axes 属性并删除该输入，使 onnx2torch 正确匹配静态轴版本。
    """
    m = onnx.load(str(src))
    inits = {i.name: i for i in m.graph.initializer}
    for n in m.graph.node:
        if n.op_type == "Reshape":
            keep = [a for a in n.attribute if a.name != "allowzero"]
            del n.attribute[:]
            n.attribute.extend(keep)
        elif n.op_type == "Resize":
            keep = [a for a in n.attribute
                    if a.name not in ("antialias", "keep_aspect_ratio_policy")]
            del n.attribute[:]
            n.attribute.extend(keep)
        elif n.op_type == "ReduceMean":
            # axes 作为第二输入（opset13+）-> 抽成 axes 属性
            if len(n.input) > 1 and n.input[1] in inits:
                axes_arr = onnx.numpy_helper.to_array(inits[n.input[1]])
                axes = [int(x) for x in axes_arr.flatten().tolist()]
                n.attribute.append(onnx.helper.make_attribute("axes", axes))
                del n.input[1]
    del m.opset_import[:]
    m.opset_import.extend([onnx.helper.make_opsetid("", 13)])
    m.ir_version = 8
    # 跳过严格 checker：opset13 下 Shape 的 `end` 属性在某些 onnx 版本会被
    # checker 误报，但 onnx2torch 读取时不严格，且降到 13 后语义等价。
    onnx.save(m, str(dst), save_as_external_data=True,
              location=dst.name + ".data", all_tensors_to_one_file=True,
              size_threshold=1024)


class E2EWrapper(nn.Module):
    """把 onnx2torch 模型的双输入 forward 固定为 (image, vehicle_state) 签名，
    便于 jit.trace。forward 内部直接透传两个位置参数给底层模型。"""

    def __init__(self, backbone: nn.Module):
        super().__init__()
        self.backbone = backbone

    def forward(self, image: torch.Tensor, vehicle_state: torch.Tensor):
        return self.backbone(image, vehicle_state)


# ---------------------------------------------------------------- 主流程
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", default=str(MODELS / "m9_mono.onnx"))
    ap.add_argument("--out", default=str(MODELS / "m9_mono.mlpackage"))
    args = ap.parse_args()

    src = Path(args.onnx)
    if not src.exists():
        print(f"✗ 找不到 {src}")
        return 1

    # 1. opset 降级（与 YOLO 一致，规避 allowzero / Resize opset 问题）
    tmp = Path(tempfile.mkdtemp()) / "m9_op13.onnx"
    print("[1/4] 降级 opset18 -> 13 …")
    try:
        downgrade_opset(src, tmp)
    except Exception as e:
        print(f"⚠ opset 降级跳过（模型可能已兼容）: {e}")
        tmp = src

    # 2. onnx -> torch
    print("[2/4] onnx -> torch …")
    from onnx2torch import convert
    backbone = convert(str(tmp)).eval()
    x_img = torch.rand(1, 3, INPUT_H, INPUT_W)
    x_state = torch.rand(1, 6)
    model = E2EWrapper(backbone).eval()
    with torch.no_grad():
        out = model(x_img, x_state)
    if isinstance(out, (tuple, list)):
        print("      输出:", [tuple(o.shape) for o in out])
    else:
        print("      输出:", tuple(out.shape))

    # 3. trace + freeze（冻结会把动态 shape 运算常量折叠，避免 coremltools 的 aten::Int 问题）
    print("[3/4] trace + freeze …")
    traced = torch.jit.trace(model, (x_img, x_state), strict=False).eval()
    traced = torch.jit.freeze(traced)
    with torch.no_grad():
        _ = traced(x_img, x_state)
        _ = traced(x_img, x_state)

    # 4. torch -> CoreML
    print("[4/4] torch -> CoreML …")
    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="image", shape=(1, 3, INPUT_H, INPUT_W)),
            ct.TensorType(name="vehicle_state", shape=(1, 6)),
        ],
        outputs=[
            ct.TensorType(name="steer"),
            ct.TensorType(name="throttle"),
            ct.TensorType(name="brake"),
        ],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "E2E 控制模型 m9_mono (image + vehicle_state -> steer/throttle/brake)"
    mlmodel.author = "AuroraDrive"

    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out) if out.is_dir() else out.unlink()
    mlmodel.save(str(out))
    print(f"\n✓ 已导出 {out}")

    # 编译成 .mlmodelc，App 加载更快
    mlmodelc = out.with_suffix(".mlmodelc")
    try:
        if mlmodelc.exists():
            shutil.rmtree(mlmodelc)
        compiled = ct.utils.compile_model(str(out))
        cpath = Path(compiled.path if hasattr(compiled, "path") else str(compiled))
        if cpath.resolve() != mlmodelc.resolve():
            shutil.move(str(cpath), str(mlmodelc))
        print(f"✓ 已编译 {mlmodelc}")
    except Exception as e:
        print(f"⚠ mlmodelc 编译失败（App 会回退直接加载 .mlpackage）: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
