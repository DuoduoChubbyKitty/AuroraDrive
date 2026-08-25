#!/usr/bin/env python3
"""导出 YOLOv26s → CoreML（w8a16：INT8 权重 + FP16 激活，NMS-free 端到端）。

背景：
  检测模型从 Yolo-FastestV2 升级为 YOLOv26s。本脚本走 Ultralytics 官方 .pt 直转
  CoreML 路线（无需 onnx / onnx2torch），量化用 quantize="w8a16"（权重 8-bit、
  激活 FP16），NMS 已在模型内部（NMS-free 端到端）。

依赖：torch / ultralytics / coremltools。
环境：本机 python3.11 框架（/usr/local/bin/python3.11，含 torch 2.13 + coremltools 9.0）
      + .venv-yolo26（--system-site-packages，补装了 ultralytics 8.4.x）。

用法：
    source .venv-yolo26/bin/activate
    python tools/export_yolo26s_coreml.py

产物：
    models/yolo26s.mlpackage   （CoreML 包，可被 App 直接加载）
    models/yolo26s.mlmodelc    （编译产物，加速首次加载；用 xcrun coremlcompiler 生成）
"""
import shutil
from pathlib import Path

import coremltools as ct
from ultralytics import YOLO

_ROOT = Path(__file__).resolve().parent.parent
MODELS = _ROOT / "models"
PT_PATH = _ROOT / "yolo26s.pt"


def main() -> int:
    MODELS.mkdir(exist_ok=True)

    # 1) 加载权重（首次自动下载 yolo26s.pt，约 19MB）
    print("[1/4] 加载权重（首次会下载 yolo26s.pt）…")
    model = YOLO(str(PT_PATH))

    # 2) 导出 CoreML：640 输入、w8a16（INT8 权重 + FP16 激活）、NMS-free
    print("[2/4] 导出 CoreML（quantize=w8a16, nms=False, imgsz=640）…")
    exported = model.export(
        format="coreml",
        imgsz=640,
        quantize="w8a16",
        nms=False,
        device="cpu",   # 导出用 CPU 更稳（转换不依赖 GPU；MPS 曾致 8.3.0 挂死）
    )

    # 3) 移动到 models/（export 默认存到 .pt 同目录，即项目根）
    src = Path(exported)
    dst = MODELS / src.name
    if dst.exists():
        shutil.rmtree(dst) if dst.is_dir() else dst.unlink()
    shutil.move(str(src), str(dst))
    print(f"[3/4] mlpackage 已就位 -> {dst}")

    # 4) 打印输入/输出 spec（Swift 集成依据：输出张量名/形状/dtype）
    spec = ct.models.MLModel(str(dst)).get_spec()
    print("\n=== 输入 spec ===")
    for i in spec.description.input:
        kind = i.type.WhichOneof("Type")
        print(f"  name={i.name}  [{kind}]")
        if kind == "imageType":
            print(f"    shape 1x3x{i.type.imageType.width}x{i.type.imageType.height}"
                  f"  colorSpace={i.type.imageType.colorSpace}")
    print("=== 输出 spec ===")
    for o in spec.description.output:
        kind = o.type.WhichOneof("Type")
        print(f"  name={o.name}  [{kind}]")
        if kind == "multiArrayType":
            ma = o.type.multiArrayType
            print(f"    shape={list(ma.shape)}  dtype={ma.dataType}")
    print("\n[4/4] 完成。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
