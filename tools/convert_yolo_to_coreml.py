#!/usr/bin/env python3
"""把 Yolo-FastestV2 的 game_assist_yolo.onnx 转成 CoreML（.mlpackage）。

背景：本机 coremltools 9.0 已彻底移除 ONNX frontend，无法 onnx->coreml 直转。
路线：onnx --(onnx2torch)--> torch --(torch.jit.trace)--> coremltools

关键处理：
  1. ONNX 是 opset18，onnx2torch 只支持到 Resize-13 / 不支持 Reshape allowzero=1。
     本图 Resize 是纯 2x nearest 上采样、Reshape 的 shape 里没有 0，
     因此降级到 opset13 语义完全等价。
  2. 原始 ONNX 输出的是两个尺度的裸特征图（reg/obj/cls 已经过 sigmoid/softmax），
     还需要 grid + anchor 解码。这里把解码逻辑包进 torch 模块一起转，
     让 CoreML 直接吐出归一化 xyxy 框 + 分数 + 类别，Swift 端只做阈值和 NMS。

模型规格（Yolo-FastestV2 COCO 官方预训练）：
  输入   1x3x352x352，BGR，[0,1]
  尺度0  22x22 stride16  anchors (12.64,19.39) (37.88,51.48) (55.71,138.31)
  尺度1  11x11 stride32  anchors (126.91,78.23) (131.57,214.55) (279.92,258.87)
  通道   95 = reg 12 (3anchor x 4) + obj 3 + cls 80
"""
import argparse
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import numpy as np
import onnx
import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent
MODELS = _ROOT / "models"

INPUT_SIZE = 352
NUM_CLASSES = 80
ANCHOR_NUM = 3
# 来自 Yolo-FastestV2/data/coco.data
ANCHORS = np.array(
    [12.64, 19.39, 37.88, 51.48, 55.71, 138.31,
     126.91, 78.23, 131.57, 214.55, 279.92, 258.87],
    dtype=np.float32,
).reshape(2, ANCHOR_NUM, 2)


# ---------------------------------------------------------------- opset 降级
def downgrade_opset(src: Path, dst: Path) -> None:
    m = onnx.load(str(src))
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
    del m.opset_import[:]
    m.opset_import.extend([onnx.helper.make_opsetid("", 13)])
    m.ir_version = 8
    onnx.checker.check_model(m, full_check=False)
    onnx.save(m, str(dst), save_as_external_data=True,
              location=dst.name + ".data", all_tensors_to_one_file=True,
              size_threshold=1024)


# ---------------------------------------------------------------- 解码封装
class YoloDecodeWrapper(nn.Module):
    """在骨干网络后接 Yolo-FastestV2 官方解码，输出可直接用的框。

    输出：
      boxes   [1, 1815, 4]  归一化 xyxy（0~1，相对 352x352 输入）
      scores  [1, 1815]     obj * max(cls)
      labels  [1, 1815]     argmax(cls)，COCO 80 类索引
    """

    GRIDS = (22, 11)   # 固定网格尺寸，绝不从 tensor.shape 读（会产生 coremltools 处理不了的 aten::Int）

    def __init__(self, backbone: nn.Module):
        super().__init__()
        self.backbone = backbone
        for i, grid_n in enumerate(self.GRIDS):
            stride = INPUT_SIZE / grid_n
            # grid: [G, G, 3, 2]，最后一维是 (gx, gy) —— 对应官方 stack((wv, hv), 2)
            gy, gx = torch.meshgrid(torch.arange(grid_n), torch.arange(grid_n),
                                    indexing="ij")
            grid = torch.stack((gx, gy), 2).float()               # [G,G,2]
            grid = grid.unsqueeze(2).repeat(1, 1, ANCHOR_NUM, 1)  # [G,G,3,2]
            self.register_buffer(f"grid{i}", grid, persistent=False)
            self.register_buffer(f"stride{i}", torch.tensor(stride), persistent=False)
            self.register_buffer(f"anchor{i}",
                                 torch.from_numpy(ANCHORS[i]).view(1, 1, ANCHOR_NUM, 2),
                                 persistent=False)

    def _decode(self, feat: torch.Tensor, i: int):
        # feat: [1, G, G, 95]，reg/obj 已 sigmoid，cls 已 softmax（ONNX 导出时做的）
        g = self.GRIDS[i]
        reg = feat[..., 0:12].reshape(1, g, g, ANCHOR_NUM, 4)
        obj = feat[..., 12:15].reshape(1, g, g, ANCHOR_NUM)
        cls = feat[..., 15:].reshape(1, g, g, 1, NUM_CLASSES) \
                            .expand(1, g, g, ANCHOR_NUM, NUM_CLASSES)

        grid = getattr(self, f"grid{i}").unsqueeze(0)      # [1,G,G,3,2]
        stride = getattr(self, f"stride{i}")
        anchor = getattr(self, f"anchor{i}").unsqueeze(0)  # [1,1,1,3,2]

        cxcy = ((reg[..., 0:2] * 2.0 - 0.5) + grid) * stride
        wh = (reg[..., 2:4] * 2.0) ** 2 * anchor

        half = wh * 0.5
        xyxy = torch.cat([cxcy - half, cxcy + half], dim=-1) / float(INPUT_SIZE)

        cls_score, cls_id = cls.max(dim=-1)
        score = obj * cls_score

        n = g * g * ANCHOR_NUM
        return (xyxy.reshape(1, n, 4),
                score.reshape(1, n),
                cls_id.reshape(1, n).float())

    def forward(self, x):
        f0, f1 = self.backbone(x)
        b0, s0, l0 = self._decode(f0, 0)
        b1, s1, l1 = self._decode(f1, 1)
        return (torch.cat([b0, b1], 1),
                torch.cat([s0, s1], 1),
                torch.cat([l0, l1], 1))


# ---------------------------------------------------------------- 主流程
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", default=str(MODELS / "game_assist_yolo.onnx"))
    ap.add_argument("--out", default=str(MODELS / "game_assist_yolo.mlpackage"))
    args = ap.parse_args()

    src = Path(args.onnx)
    if not src.exists():
        print(f"✗ 找不到 {src}")
        return 1

    import tempfile
    tmp = Path(tempfile.mkdtemp()) / "yolo_op13.onnx"
    print(f"[1/4] 降级 opset18 -> 13 …")
    downgrade_opset(src, tmp)

    print(f"[2/4] onnx -> torch …")
    from onnx2torch import convert
    backbone = convert(str(tmp)).eval()

    model = YoloDecodeWrapper(backbone).eval()
    x = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        boxes, scores, labels = model(x)
    print(f"      boxes={tuple(boxes.shape)} scores={tuple(scores.shape)} "
          f"labels={tuple(labels.shape)}")

    print(f"[3/4] trace + freeze …")
    traced = torch.jit.trace(model, x, strict=False).eval()
    # onnx2torch 会保留一堆由 Gather/Reshape 推出来的动态 shape 运算，
    # coremltools 的 aten::Int 处理不了非标量。freeze 会把它们常量折叠掉。
    traced = torch.jit.freeze(traced)
    with torch.no_grad():
        _ = traced(x)  # 触发 freeze 后的优化 pass
        _ = traced(x)

    print(f"[4/4] torch -> CoreML …")
    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
            scale=1.0 / 255.0,
            bias=[0.0, 0.0, 0.0],
            color_layout=ct.colorlayout.BGR,   # Yolo-FastestV2 用 cv2 训练，输入是 BGR
        )],
        outputs=[ct.TensorType(name="boxes"),
                 ct.TensorType(name="scores"),
                 ct.TensorType(name="labels")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "Yolo-FastestV2 COCO80 @352 (含 anchor 解码)"
    mlmodel.author = "AuroraDrive"

    import shutil
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out) if out.is_dir() else out.unlink()
    mlmodel.save(str(out))
    print(f"\n✓ 已导出 {out}")

    # 编译成 .mlmodelc，App 加载更快（否则每次启动都要现场编译 mlpackage）
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
