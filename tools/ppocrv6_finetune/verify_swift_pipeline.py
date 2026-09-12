#!/usr/bin/env python3
"""Swift 集成逻辑的离线一致性验证（不启动 app）。

验证 1：复刻 Swift bilinearResizeGray（像素中心对齐 + clamp）vs cv2.INTER_LINEAR，
        在训练裁片 51×18 → 48×136 上逐像素对比，max diff 应 ≤ 1（u8 舍入差）。
验证 2：模拟运行时高分辨率 ROI 帧：51×18 → 放大到 235×96（2940 全屏的 ROI 尺寸）
        → 按 Swift 同款流程（灰度 → 双线性 48×136 → 归一化 → 3 通道）→ ONNX 推理
        → CTC 解码 → 后 3 位规则 → 与标签比对，期望精度仍 ≈99.9%。
"""
import numpy as np, cv2, os, onnxruntime as ort

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
DS = f"{ROOT}/tools/ppocrv6_finetune/dataset"
ONNX = f"{ROOT}/tools/ppocrv6_finetune/output/v6tiny_ft_infer/v6tiny_ft.onnx"

# ---------- 验证 1：插值一致性 ----------
def swift_bilinear(src, dstH, dstW):
    """逐行复刻 SpeedOCRReader.bilinearResizeGray"""
    srcH, srcW = src.shape
    out = np.zeros((dstH, dstW), dtype=np.uint8)
    xR, yR = srcW / dstW, srcH / dstH
    for y in range(dstH):
        sy = (y + 0.5) * yR - 0.5
        y0 = min(max(int(np.floor(sy)), 0), srcH - 1)
        y1 = min(y0 + 1, srcH - 1)
        fy = max(0.0, min(sy - y0, 1.0))
        for x in range(dstW):
            sx = (x + 0.5) * xR - 0.5
            x0 = min(max(int(np.floor(sx)), 0), srcW - 1)
            x1 = min(x0 + 1, srcW - 1)
            fx = max(0.0, min(sx - x0, 1.0))
            p00, p01 = float(src[y0, x0]), float(src[y0, x1])
            p10, p11 = float(src[y1, x0]), float(src[y1, x1])
            top = p00 + (p01 - p00) * fx
            bot = p10 + (p11 - p10) * fx
            out[y, x] = np.uint8(np.round(top + (bot - top) * fy))
    return out

lines = open(f"{DS}/val.txt", encoding="utf-8").read().splitlines()
imgs = []
for line in lines[:150]:
    rel = line.split("\t")[0]
    g = cv2.imread(os.path.join(DS, rel), cv2.IMREAD_GRAYSCALE)
    imgs.append(g)

diffs = []
for g in imgs:
    a = swift_bilinear(g, 48, 136)
    b = cv2.resize(g, (136, 48), interpolation=cv2.INTER_LINEAR)  # u8
    diffs.append(int(np.abs(a.astype(int) - b.astype(int)).max()))
print(f"[验证1] Swift双线性 vs cv2.INTER_LINEAR：{len(imgs)} 张，max diff = {max(diffs)}（u8 舍入级 ≤1 即等价）")

# ---------- 验证 2：高分辨率 ROI 模拟全链路 ----------
with open(f"{DS}/dict.txt", "rb") as f:
    dict_lines = [l.decode("utf-8").strip("\n").strip("\r\n") for l in f]
idx2char = ["blank"] + dict_lines + [" "]

def decode(logits):
    pred = logits.argmax(axis=-1)
    chars, prev = [], -1
    for idx in pred:
        if idx != 0 and idx != prev:
            chars.append(idx2char[idx] if idx < len(idx2char) else "?")
        prev = idx
    digits = "".join(c for c in "".join(chars) if c.isdigit())
    if len(digits) < 2:
        return None
    return digits[-3:].zfill(3)

sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
iname = sess.get_inputs()[0].name

n_ok = n = 0
for line in lines[:800]:
    rel, label = line.split("\t")
    g = cv2.imread(os.path.join(DS, rel), cv2.IMREAD_GRAYSCALE)
    # 模拟运行时：低分辨率裁片内容出现在高分辨率 ROI 帧上（235×96 @2940 全屏）
    roi_frame = cv2.resize(g, (235, 96), interpolation=cv2.INTER_LINEAR)
    # Swift 同款：双线性 → 48×136 → 归一化 → 3 通道
    resized = swift_bilinear(roi_frame, 48, 136).astype(np.float32)
    x = ((resized / 255.0 - 0.5) / 0.5)[None, None]          # [1,1,48,136]
    x = np.repeat(x, 3, axis=1)                                # [1,3,48,136]
    logits = sess.run(None, {iname: x})[0][0]
    pred = decode(logits)
    n += 1
    if pred == label:
        n_ok += 1
print(f"[验证2] 高分 ROI 模拟（800 张）：{n_ok}/{n} = {n_ok/n*100:.4f}%")
