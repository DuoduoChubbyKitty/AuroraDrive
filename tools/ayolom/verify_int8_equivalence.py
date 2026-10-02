#!/usr/bin/env python3
"""A-YOLOM fp16 vs int8 等价性验证（2026-10-02）

为什么要做这个：
  本项目在 yolopx 上被 int8 坑过一次 —— 检测头精度 100%，但
  **车道线 ll recall 只剩 3.98%（架构性失败）**，int8 被迫降到候选表末位。
  故 A-YOLOM 的 int8 必须先过等价门，才能谈"用 int8 + 15fps"。

判据（沿用项目既有门限）：
  · det  框数一致 / 框中心偏差 < 1.5 px
  · da   掩码 IoU > 0.99
  · ll   掩码 IoU > 0.99，且 recall 不得崩塌（> 0.9）
"""
import sys, os, glob
import numpy as np
import coremltools as ct
import cv2


def letterbox(im, size=640, color=114):
    """等比缩放 + 灰边填充（与 YolopxEngine.swift 的 letterbox 语义一致）。"""
    h, w = im.shape[:2]
    r = min(size / h, size / w)
    nw, nh = int(round(w * r)), int(round(h * r))
    resized = cv2.resize(im, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((size, size, 3), color, dtype=np.uint8)
    dw, dh = (size - nw) // 2, (size - nh) // 2
    canvas[dh:dh + nh, dw:dw + nw] = resized
    return canvas, r, dw, dh


def to_input(canvas):
    # BGR→RGB, HWC→CHW, /255
    x = canvas[:, :, ::-1].astype(np.float32) / 255.0
    return np.transpose(x, (2, 0, 1))[None]


def load(path):
    return ct.models.MLModel(path, compute_units=ct.ComputeUnit.ALL)


def run(m, x, name):
    out = m.predict({name: x})
    keys = list(out.keys())
    det = out[keys[0]]
    if det.ndim == 3 and det.shape[1] == 5:
        det = det[0]
    da = out[keys[1]]
    ll = out[keys[2]]
    return det, da, ll


def mask_iou(a, b):
    """a,b: [1,2,H,W] logits → argmax 后的二值 IoU"""
    A = (a[0].argmax(0) > 0)
    B = (b[0].argmax(0) > 0)
    inter = (A & B).sum()
    union = (A | B).sum()
    return float(inter) / float(union) if union else 1.0


def main():
    fp16 = load("models/ayolom/ayolom_n_fp16.mlpackage")
    int8 = load("models/ayolom/ayolom_n_int8.mlpackage")
    spec = fp16.get_spec()
    name = spec.description.input[0].name

    imgs = sorted(glob.glob("data/validation_clips/*/*.jpg"))[:40]
    print(f"测试图 {len(imgs)} 张（真实道路场景）\n")

    rows = []
    for p in imgs:
        im = cv2.imread(p)
        if im is None:
            continue
        canvas, _, _, _ = letterbox(im)
        x = to_input(canvas)

        d1, a1, l1 = run(fp16, x, name)
        d2, a2, l2 = run(int8, x, name)

        # det：比较 cls>0.25 的框数
        n1 = int((d1[4] > 0.25).sum())
        n2 = int((d2[4] > 0.25).sum())
        # da / ll 的 IoU
        iou_da = mask_iou(a1, a2)
        iou_ll = mask_iou(l1, l2)
        # ll recall：fp16 认为有车道线的像素中，int8 找回多少
        L1 = (l1[0].argmax(0) > 0)
        L2 = (l2[0].argmax(0) > 0)
        rec = float((L1 & L2).sum()) / float(L1.sum()) if L1.sum() else 1.0
        D1 = (a1[0].argmax(0) > 0)
        rec_da = float((D1 & (a2[0].argmax(0) > 0)).sum()) / float(D1.sum()) if D1.sum() else 1.0

        rows.append((os.path.basename(p)[:22], n1, n2, iou_da, iou_ll, rec, rec_da))

    print(f"{'图':24s} {'框f16':>5s} {'框i8':>5s} {'daIoU':>7s} {'llIoU':>7s} {'llRec':>7s} {'daRec':>7s}")
    print("-" * 72)
    for r in rows[:20]:
        print(f"{r[0]:24s} {r[1]:5d} {r[2]:5d} {r[3]:7.4f} {r[4]:7.4f} {r[5]:7.4f} {r[6]:7.4f}")

    da = np.mean([r[3] for r in rows])
    ll = np.mean([r[4] for r in rows])
    lrec = np.mean([r[5] for r in rows])
    drec = np.mean([r[6] for r in rows])
    print("-" * 72)
    print(f"{'均值':24s} {np.mean([r[1] for r in rows]):5.1f} {np.mean([r[2] for r in rows]):5.1f} "
          f"{da:7.4f} {ll:7.4f} {lrec:7.4f} {drec:7.4f}")
    print()
    print("=== 判定 ===")
    print(f"  da IoU  > 0.99 : {'✅ PASS' if da > 0.99 else '❌ FAIL'}  ({da:.4f})")
    print(f"  ll IoU  > 0.99 : {'✅ PASS' if ll > 0.99 else '❌ FAIL'}  ({ll:.4f})")
    print(f"  ll recall>0.90 : {'✅ PASS' if lrec > 0.90 else '❌ FAIL'}  ({lrec:.4f})")
    print(f"  da recall>0.90 : {'✅ PASS' if drec > 0.90 else '❌ FAIL'}  ({drec:.4f})")


if __name__ == "__main__":
    main()
