#!/usr/bin/env python3
"""E2E 模型转换 v2：改用 neuralnetwork 格式 + FLOAT32，规避 mlprogram 转换 bug。

现象：v1（convert_to='mlprogram', FLOAT16）在 CoreML 框架运行时输出恒为 0，
而 coremltools 自身 Python 求值器能算出非零 —— 典型 mlprogram 算子转换 bug。
neuralnetwork 老格式兼容性更好，配合 FLOAT32 避免精度塌缩。
"""
import sys
import shutil
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


def downgrade_opset(src: Path, dst: Path) -> None:
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
            if len(n.input) > 1 and n.input[1] in inits:
                axes_arr = onnx.numpy_helper.to_array(inits[n.input[1]])
                axes = [int(x) for x in axes_arr.flatten().tolist()]
                n.attribute.append(onnx.helper.make_attribute("axes", axes))
                del n.input[1]
    del m.opset_import[:]
    m.openset_import if False else None
    m.opset_import.extend([onnx.helper.make_opsetid("", 13)])
    m.ir_version = 8
    onnx.save(m, str(dst), save_as_external_data=True,
              location=dst.name + ".data", all_tensors_to_one_file=True,
              size_threshold=1024)


class E2EWrapper(nn.Module):
    def __init__(self, backbone: nn.Module):
        super().__init__()
        self.backbone = backbone

    def forward(self, image: torch.Tensor, vehicle_state: torch.Tensor):
        return self.backbone(image, vehicle_state)


def main() -> int:
    src = MODELS / "m9_mono.onnx"
    out = MODELS / "m9_mono_v3.mlmodel"
    tmp = Path("/tmp") / "m9_op13.onnx"
    downgrade_opset(src, tmp)

    from onnx2torch import convert
    backbone = convert(str(tmp)).eval()
    model = E2EWrapper(backbone).eval()
    x_img = torch.rand(1, 3, INPUT_H, INPUT_W)
    x_state = torch.rand(1, 6)
    traced = torch.jit.trace(model, (x_img, x_state), strict=False).eval()
    

    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="neuralnetwork",
        inputs=[
            ct.TensorType(name="image", shape=(1, 3, INPUT_H, INPUT_W)),
            ct.TensorType(name="vehicle_state", shape=(1, 6)),
        ],
        outputs=[
            ct.TensorType(name="steer"),
            ct.TensorType(name="throttle"),
            ct.TensorType(name="brake"),
        ],
        minimum_deployment_target=ct.target.macOS11,
    )
    if out.exists():
        out.unlink()
    mlmodel.save(str(out))
    print(f"OK saved {out}")

    # 数值自检（Python 端）
    import onnxruntime as ort
    img = np.random.randn(1, 3, INPUT_H, INPUT_W).astype(np.float32)
    st = np.random.randn(1, 6).astype(np.float32)
    co = mlmodel.predict({"image": img, "vehicle_state": st})
    se = ort.InferenceSession(str(src), providers=["CPUExecutionProvider"])
    oo = se.run(None, {"image": img, "vehicle_state": st})
    cs = [np.array(co[k]).reshape(-1) for k in ("steer", "throttle", "brake")]
    os_ = [o.reshape(-1) for o in oo]
    err = max(np.abs(cs[i] - os_[i]).max() for i in range(3))
    print("CoreML(py) steer/thr/brk:", cs[0], cs[1], cs[2])
    print("ONNX steer/thr/brk:", os_[0], os_[1], os_[2])
    print("MAX ABS ERR:", err)
    return 0


if __name__ == "__main__":
    sys.exit(main())
