#!/usr/bin/env python3
"""对拍验证 game_assist_yolo.mlpackage 与原始 ONNX 的一致性，并在真实游戏帧上出检测结果。

用法:
  python3.11 tools/verify_yolo_coreml.py --img recordings/xxx/frames/00001.png
"""
import argparse
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
MODELS = _ROOT / "models"
SIZE = 352

COCO = ("person bicycle car motorbike aeroplane bus train truck boat traffic-light "
        "fire-hydrant stop-sign parking-meter bench bird cat dog horse sheep cow "
        "elephant bear zebra giraffe backpack umbrella handbag tie suitcase frisbee "
        "skis snowboard sports-ball kite baseball-bat baseball-glove skateboard "
        "surfboard tennis-racket bottle wine-glass cup fork knife spoon bowl banana "
        "apple sandwich orange broccoli carrot hot-dog pizza donut cake chair sofa "
        "pottedplant bed diningtable toilet tvmonitor laptop mouse remote keyboard "
        "cell-phone microwave oven toaster sink refrigerator book clock vase scissors "
        "teddy-bear hair-drier toothbrush").split()

ANCHORS = np.array([12.64, 19.39, 37.88, 51.48, 55.71, 138.31,
                    126.91, 78.23, 131.57, 214.55, 279.92, 258.87],
                   dtype=np.float32).reshape(2, 3, 2)


def decode_raw(feats):
    """官方 Yolo-FastestV2 解码（reg/obj 已 sigmoid、cls 已 softmax）。"""
    boxes, scores, labels = [], [], []
    for i, f in enumerate(feats):                      # f: [1,G,G,95]
        g = f.shape[1]
        stride = SIZE / g
        reg = f[0, :, :, 0:12].reshape(g, g, 3, 4)
        obj = f[0, :, :, 12:15].reshape(g, g, 3)
        cls = f[0, :, :, 15:].reshape(g, g, 1, 80).repeat(3, axis=2)
        gx, gy = np.meshgrid(np.arange(g), np.arange(g))      # gx=列, gy=行
        grid = np.stack((gx, gy), -1)[:, :, None, :].astype(np.float32)
        cxcy = ((reg[..., 0:2] * 2.0 - 0.5) + grid) * stride
        wh = (reg[..., 2:4] * 2.0) ** 2 * ANCHORS[i][None, None, :, :]
        xy1, xy2 = cxcy - wh / 2, cxcy + wh / 2
        boxes.append(np.concatenate([xy1, xy2], -1).reshape(-1, 4) / SIZE)
        scores.append((obj * cls.max(-1)).reshape(-1))
        labels.append(cls.argmax(-1).reshape(-1))
    return np.concatenate(boxes), np.concatenate(scores), np.concatenate(labels)


def nms(boxes, scores, labels, thr=0.45):
    keep, order = [], scores.argsort()[::-1]
    while order.size:
        i = order[0]
        keep.append(i)
        if order.size == 1:
            break
        rest = order[1:]
        xx1 = np.maximum(boxes[i, 0], boxes[rest, 0])
        yy1 = np.maximum(boxes[i, 1], boxes[rest, 1])
        xx2 = np.minimum(boxes[i, 2], boxes[rest, 2])
        yy2 = np.minimum(boxes[i, 3], boxes[rest, 3])
        inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
        a = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        b = (boxes[rest, 2] - boxes[rest, 0]) * (boxes[rest, 3] - boxes[rest, 1])
        iou = inter / (a + b - inter + 1e-9)
        order = rest[(iou < thr) | (labels[rest] != labels[i])]
    return keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", default=None)
    ap.add_argument("--conf", type=float, default=0.25)
    args = ap.parse_args()

    from PIL import Image
    if args.img:
        img = Image.open(args.img).convert("RGB")
    else:
        cands = sorted((_ROOT / "recordings").rglob("frames/*.png"))
        if not cands:
            print("✗ 找不到测试帧")
            return 1
        args.img = str(cands[len(cands) // 2])
        img = Image.open(args.img).convert("RGB")
    print(f"测试图: {args.img}  原始尺寸={img.size}")

    resized = img.resize((SIZE, SIZE), Image.BILINEAR)
    rgb = np.asarray(resized, dtype=np.float32)                 # HWC RGB 0-255
    bgr_chw = rgb[:, :, ::-1].transpose(2, 0, 1)[None] / 255.0  # 1,3,H,W BGR 0-1
    bgr_chw = np.ascontiguousarray(bgr_chw, dtype=np.float32)

    # ---------- 基准：ONNX Runtime（若无则退回 onnx2torch） ----------
    ref = None
    try:
        import onnxruntime as ort
        sess = ort.InferenceSession(str(MODELS / "game_assist_yolo.onnx"),
                                    providers=["CPUExecutionProvider"])
        ref = sess.run(None, {sess.get_inputs()[0].name: bgr_chw})
        print("基准: onnxruntime")
    except Exception as e:
        print(f"onnxruntime 不可用({type(e).__name__})，退回 onnx2torch/PyTorch")
        import torch, tempfile
        sys.path.insert(0, str(_ROOT / "tools"))
        from convert_yolo_to_coreml import downgrade_opset
        tmp = Path(tempfile.mkdtemp()) / "y.onnx"
        downgrade_opset(MODELS / "game_assist_yolo.onnx", tmp)
        from onnx2torch import convert
        m = convert(str(tmp)).eval()
        with torch.no_grad():
            ref = [o.numpy() for o in m(torch.from_numpy(bgr_chw))]

    rb, rs, rl = decode_raw(ref)

    # ---------- 待测：CoreML ----------
    import coremltools as ct
    mlm = ct.models.MLModel(str(MODELS / "game_assist_yolo.mlpackage"))
    out = mlm.predict({"image": resized})           # PIL 图，CoreML 自己做 BGR + /255
    cb = np.asarray(out["boxes"]).reshape(-1, 4)
    cs = np.asarray(out["scores"]).reshape(-1)
    cl = np.asarray(out["labels"]).reshape(-1).astype(int)

    print("\n=== 逐元素误差（CoreML vs 基准解码）===")
    print(f"  boxes  max|Δ| = {np.abs(cb - rb).max():.6f}")
    print(f"  scores max|Δ| = {np.abs(cs - rs).max():.6f}")
    print(f"  labels 不一致数 = {int((cl != rl).sum())} / {len(cl)}")

    for tag, (b, s, l) in (("基准", (rb, rs, rl)), ("CoreML", (cb, cs, cl))):
        m_ = s > args.conf
        bb, ss, ll = b[m_], s[m_], l[m_]
        keep = nms(bb, ss, ll)
        print(f"\n=== {tag} 检测结果 (conf>{args.conf}) : {len(keep)} 个 ===")
        for i in keep[:15]:
            x1, y1, x2, y2 = bb[i]
            print(f"  {COCO[ll[i]]:<14} {ss[i]:.3f}  "
                  f"[{x1:.3f},{y1:.3f},{x2:.3f},{y2:.3f}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
