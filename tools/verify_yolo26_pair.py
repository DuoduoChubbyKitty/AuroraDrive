#!/usr/bin/env python3
"""P0-3 对拍：yolo26s Swift 自检 vs Python coremltools 基准。

目标：确认
  1. 通道序：模型声明 RGB；App 喂 32BGRA（BGR 字节序）；CoreML 是否正确转换？
  2. 坐标：输出 [1,300,6] 是像素 (0~640) 还是归一化 (0~1)？Swift parse() 除以 640 是否正确？

用法：
  .venv-yolo26/bin/python3 tools/verify_yolo26_pair.py --img /path/to/image.png
"""
import argparse
import sys
import warnings
warnings.filterwarnings("ignore")

import numpy as np
from PIL import Image

_ROOT = "/Users/dupi/Desktop/自动驾驶系统"
SIZE = 640

# Ultralytics COCO-80 顺序（来自模型 metadata userDefined.names）
COCO = ["person","bicycle","car","motorcycle","airplane","bus","train","truck","boat",
        "traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat",
        "dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack",
        "umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball",
        "kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket",
        "bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple",
        "sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake",
        "chair","couch","potted plant","bed","dining table","toilet","tv","laptop",
        "mouse","remote","keyboard","cell phone","microwave","oven","toaster","sink",
        "refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"]


def load_model():
    import coremltools as ct
    # 优先 .mlmodelc（编译产物，跑得更快），失败回退 .mlpackage
    for p in [f"{_ROOT}/models/yolo26s.mlmodelc", f"{_ROOT}/models/yolo26s.mlpackage"]:
        try:
            return ct.models.MLModel(p), p
        except Exception as e:
            print(f"  [load skip] {p}: {type(e).__name__}: {e}", file=sys.stderr)
    raise RuntimeError("无法加载模型")


def decode(arr: np.ndarray, conf_thr: float):
    """输出 [1,300,6] -> kept list，按置信度降序。"""
    arr = np.asarray(arr).reshape(1, 300, 6)
    out = []
    for i in range(arr.shape[1]):
        x1, y1, x2, y2, conf, cls = arr[0, i]
        if not np.isfinite(conf) or conf <= conf_thr:
            continue
        out.append((float(x1), float(y1), float(x2), float(y2),
                    float(conf), int(round(cls))))
    out.sort(key=lambda t: -t[4])
    return out


def fmt_dets(kept, mode: str):
    """mode: 'px' 输出像素 (x1,y1,x2,y2)；'norm' 转归一化 (cx,cy,w,h)。"""
    lines = []
    for (x1, y1, x2, y2, conf, cls) in kept[:12]:
        name = COCO[cls] if 0 <= cls < len(COCO) else f"cls{cls}"
        if mode == "px":
            lines.append(f"  [{cls:2d}] {name:<14} conf={conf:.4f}  "
                         f"px(x1,y1,x2,y2)=({x1:.1f},{y1:.1f},{x2:.1f},{y2:.1f})")
        else:
            cx, cy = (x1+x2)/2/640, (y1+y2)/2/640
            w, h = (x2-x1)/640, (y2-y1)/640
            lines.append(f"  [{cls:2d}] {name:<14} conf={conf:.4f}  "
                         f"norm(cx,cy,w,h)=({cx:.3f},{cy:.3f},{w:.3f},{h:.3f})")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", required=True)
    ap.add_argument("--conf", type=float, default=0.22)
    args = ap.parse_args()

    img_pil = Image.open(args.img).convert("RGB")
    w0, h0 = img_pil.size
    print(f"=== 样本图: {args.img}  原尺寸={w0}x{h0}  模型输入={SIZE}x{SIZE}\n")

    # 缩放为模型输入（与 Swift draw() 行为一致：整帧拉伸、无 letterbox）
    img_resized_rgb = img_pil.resize((SIZE, SIZE), Image.BILINEAR)
    rgb_np = np.asarray(img_resized_rgb, dtype=np.uint8)        # [H,W,3] RGB
    bgr_np = rgb_np[..., ::-1].copy()                            # [H,W,3] BGR 通道序

    # ── 加载模型 + 打 description ──
    model, used_path = load_model()
    print(f"=== 模型: {used_path}")
    spec = model.get_spec()
    for i in spec.description.input:
        kind = i.type.WhichOneof("Type")
        if kind == "imageType":
            cs = i.type.imageType.colorSpace
            print(f"  INPUT  {i.name}  {i.type.imageType.width}x{i.type.imageType.height}  "
                  f"colorSpace={cs}  (1=RGB 2=GRAYSCALE 3=BRG? 见 CoreML 枚举)")
    for o in spec.description.output:
        kind = o.type.WhichOneof("Type")
        if kind == "multiArrayType":
            ma = o.type.multiArrayType
            print(f"  OUTPUT {o.name}  shape={list(ma.shape)}  dtype={ma.dataType}")

    # ── 路径 A：PIL RGB（训练端标准路径：RGB → resize → 喂模型）──
    print("\n=== [A] PIL RGB 直喂（RGB 字节序 = 训练端约定） ===")
    out_a = model.predict({"image": img_resized_rgb})
    name_a = list(out_a.keys())[0]
    arr_a = np.asarray(out_a[name_a])
    print(f"  raw shape={arr_a.shape}  dtype={arr_a.dtype}  first3 rows (x1,y1,x2,y2,conf,cls):")
    for i in range(3):
        print(f"    {i}: {arr_a.reshape(-1,6)[i]}")
    kept_a = decode(arr_a, args.conf)
    print(f"  过 conf>{args.conf}  {len(kept_a)} 个（前 12）:")
    print(fmt_dets(kept_a, "px"))

    # ── 路径 B：numpy BGR（喂 BGR 字节序，模拟"如果模型没做转换、App 喂错"）──
    print("\n=== [B] numpy BGR 直喂（BGR 字节序 = App 32BGRA 缓冲的物理内存序） ===")
    print("    注意：imageType 输入走 coremltools 图像栈；观察它是否声明 colorSpace 转换")
    out_b = model.predict({"image": Image.fromarray(bgr_np)})   # PIL 也认 ndarray
    name_b = list(out_b.keys())[0]
    arr_b = np.asarray(out_b[name_b])
    print(f"  raw shape={arr_b.shape}  dtype={arr_b.dtype}  first3 rows:")
    for i in range(3):
        print(f"    {i}: {arr_b.reshape(-1,6)[i]}")
    kept_b = decode(arr_b, args.conf)
    print(f"  过 conf>{args.conf}  {len(kept_b)} 个（前 12）:")
    print(fmt_dets(kept_b, "px"))

    # ── 对比 A vs B：核心结论 ──
    print("\n=== [A vs B] 通道序敏感性 ===")
    if arr_a.shape != arr_b.shape:
        print(f"  ✗ shape 不同 {arr_a.shape} vs {arr_b.shape}")
    else:
        diff = np.abs(arr_a.astype(np.float32) - arr_b.astype(np.float32))
        print(f"  raw 输出 max|Δ|={diff.max():.6f}  mean|Δ|={diff.mean():.6f}")
        # 行级 top-1 类别是否一致
        cls_a = arr_a.reshape(-1, 6)[:, 5].astype(int)
        cls_b = arr_b.reshape(-1, 6)[:, 5].astype(int)
        cls_match = (cls_a == cls_b).mean()
        print(f"  top-1 class 逐行一致率 = {cls_match*100:.1f}%  ({int(cls_match*300)}/300)")

    # ── 坐标解读 ──
    print("\n=== [坐标] 原始输出是像素 (0~640) 还是归一化 (0~1)？===")
    # 如果是像素：x2-x1 应远大于 1（实物宽度几十~几百像素）；
    # 如果是归一化：所有值都在 [0,1] 内，x2-x1 应 < 1。
    sample = arr_a.reshape(-1, 6)
    valid = sample[sample[:, 4] > args.conf]
    if len(valid) > 0:
        widths_raw = valid[:, 2] - valid[:, 0]
        print(f"  [A] 过阈值框的 (x2-x1) 原始值范围: "
              f"min={widths_raw.min():.3f}  max={widths_raw.max():.3f}  "
              f"median={np.median(widths_raw):.3f}")
        if widths_raw.max() > 5:
            print(f"  ⇒ 原始值显著大于 1 → 模型输出为像素坐标 (0~640)；Swift parse() /640 正确")
        else:
            print(f"  ⇒ 原始值都在 [0,1] 附近 → 模型输出为归一化坐标；Swift parse() /640 错误（会再除一次）")

    # ── 输出 Swift 想要的对照格式 ──
    print("\n=== 给 Swift 自检对比的「归一化 (cx,cy,w,h) 与 conf」列表 ===")
    print("[A-RGB]  Python 基准（训练端 RGB 路径）:")
    print(fmt_dets(kept_a, "norm"))
    print("\n[B-BGR]  如果 App 不做通道转换会得到的结果:")
    print(fmt_dets(kept_b, "norm"))

    # ── 写文件供 Swift 端 .rawDump 对比 ──
    np.save("/tmp/yolo_py_rgb_raw.npy", arr_a)
    np.save("/tmp/yolo_py_bgr_raw.npy", arr_b)
    print("\n[已写] /tmp/yolo_py_rgb_raw.npy  /tmp/yolo_py_bgr_raw.npy  "
          "(供 Swift 端 rawDump 与 Python 对比)")


if __name__ == "__main__":
    main()