#!/usr/bin/env python3
"""A-YOLOM 单图推理 + 可视化（2026-10-02）

用法: infer_ayolom_image.py <图片> <输出前缀>
产出: <前缀>_overlay.jpg（叠加可视化）+ 控制台数值报告

三个头：
  det [1,5,8400]     cx,cy,w,h,cls   → NMS → 框
  da  [1,2,640,640]  可行驶区 logits  → argmax → 掩码
  ll  [1,2,640,640]  车道线 logits    → argmax → 掩码
"""
import sys, os, argparse
import numpy as np
import cv2
import coremltools as ct


def letterbox(im, size=640, color=114):
    h, w = im.shape[:2]
    r = min(size / h, size / w)
    nw, nh = int(round(w * r)), int(round(h * r))
    resized = cv2.resize(im, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((size, size, 3), color, dtype=np.uint8)
    dw, dh = (size - nw) // 2, (size - nh) // 2
    canvas[dh:dh + nh, dw:dw + nw] = resized
    return canvas, r, dw, dh


def to_input(canvas):
    x = canvas[:, :, ::-1].astype(np.float32) / 255.0
    return np.transpose(x, (2, 0, 1))[None]


def nms(boxes, scores, iou_thr=0.45):
    """boxes: [N,4] xyxy"""
    if len(boxes) == 0:
        return []
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = (x2 - x1) * (y2 - y1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w = np.maximum(0.0, xx2 - xx1)
        h = np.maximum(0.0, yy2 - yy1)
        inter = w * h
        iou = inter / (areas[i] + areas[order[1:]] - inter + 1e-9)
        inds = np.where(iou <= iou_thr)[0]
        order = order[inds + 1]
    return keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("out_prefix")
    ap.add_argument("--model", default="models/ayolom/ayolom_n_fp16.mlpackage")
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.45)
    a = ap.parse_args()

    m = ct.models.MLModel(a.model, compute_units=ct.ComputeUnit.ALL)
    inp = m.get_spec().description.input[0].name

    im = cv2.imread(a.image)
    H, W = im.shape[:2]
    canvas, r, dw, dh = letterbox(im)
    x = to_input(canvas)
    out = m.predict({inp: x})
    keys = list(out.keys())
    det = out[keys[0]][0]          # [5,8400]
    da = out[keys[1]]              # [1,2,640,640]
    ll = out[keys[2]]

    # ---- det：cxcywh → xyxy（640 letterbox 坐标系）----
    cx, cy, bw, bh = det[0], det[1], det[2], det[3]
    conf = det[4]
    sel = conf > a.conf
    print(f"\n=== 检测头 ===")
    print(f"  conf>{a.conf} 的候选框: {int(sel.sum())} / 8400")
    if sel.sum():
        print(f"  置信度 top10: {np.sort(conf[sel])[::-1][:10].round(3)}")

    boxes = np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], 1)[sel]
    scores = conf[sel]
    keep = nms(boxes, scores, a.iou)
    boxes, scores = boxes[keep], scores[keep]
    print(f"  NMS 后: {len(boxes)} 个框")

    # ---- 反 letterbox → 原图坐标 ----
    def unlb(px, py):
        return (px - dw) / r, (py - dh) / r

    vis = im.copy()
    # 可行驶区（绿色半透明）
    dam = (da[0].argmax(0) > 0).astype(np.uint8)
    llm = (ll[0].argmax(0) > 0).astype(np.uint8)
    # 裁掉灰边 → 缩回原图
    nh, nw = int(round(H * r)), int(round(W * r))
    dam_c = dam[dh:dh + nh, dw:dw + nw]
    llm_c = llm[dh:dh + nh, dw:dw + nw]
    dam_full = cv2.resize(dam_c, (W, H), interpolation=cv2.INTER_NEAREST)
    llm_full = cv2.resize(llm_c, (W, H), interpolation=cv2.INTER_NEAREST)

    overlay = vis.copy()
    overlay[dam_full > 0] = (0, 200, 0)
    vis = cv2.addWeighted(overlay, 0.30, vis, 0.70, 0)
    vis[llm_full > 0] = (0, 0, 255)          # 车道线红色实心

    # 框
    for (x1, y1, x2, y2), s in zip(boxes, scores):
        ax1, ay1 = unlb(x1, y1)
        ax2, ay2 = unlb(x2, y2)
        p1, p2 = (int(ax1), int(ay1)), (int(ax2), int(ay2))
        cv2.rectangle(vis, p1, p2, (0, 255, 255), 3)
        label = f"car {s:.2f}"
        cv2.putText(vis, label, (p1[0], max(20, p1[1] - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
        # 打印归一化中心（用于判断「是不是自车」）
        ncx = ((ax1 + ax2) / 2) / W
        ncy = ((ay1 + ay2) / 2) / H
        print(f"    框: 中心=({ncx:.3f},{ncy:.3f}) 归一化  尺寸=({(ax2-ax1):.0f}x{(ay2-ay1):.0f})px  conf={s:.3f}")

    # ---- 数值报告 ----
    print(f"\n=== 可行驶区 ===")
    print(f"  占比: {dam_full.mean()*100:.2f}%  （真值参考：R3 基线 26.19%）")
    print(f"=== 车道线 ===")
    print(f"  占比: {llm_full.mean()*100:.2f}%  （真值参考：R3 基线 8.042%）")

    # 自车判定：检查有没有框在画面正中且贴近底部
    hits = []
    for (x1, y1, x2, y2), s in zip(boxes, scores):
        ax1, ay1 = unlb(x1, y1)
        ax2, ay2 = unlb(x2, y2)
        ncx = ((ax1 + ax2) / 2) / W
        ncy = ((ay1 + ay2) / 2) / H
        if abs(ncx - 0.5) < 0.12 and ncy > 0.55:
            hits.append((ncx, ncy, s))
    print(f"\n=== 🚨 自车误检检查（中心 x≈0.5 且 y>0.55）===")
    if hits:
        for nc, ny, s in hits:
            print(f"  ⚠️ 可疑：中心=({nc:.3f},{ny:.3f}) conf={s:.3f}  ← 可能就是自车！")
    else:
        print(f"  ✅ 无（画面正中下部没有框）")

    cv2.imwrite(a.out_prefix + "_overlay.jpg", vis)
    print(f"\n已保存 {a.out_prefix}_overlay.jpg")


if __name__ == "__main__":
    main()
