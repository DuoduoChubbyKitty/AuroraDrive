#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 1c-补充：图像空间判别 —— 13056 底图是否真的覆盖所有换算后落点。
这是**与公式无关**的判别：直接看底图哪些像素是有效地图内容。"""
import json
from PIL import Image
import numpy as np

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
A  = 0.016394586684750773
B  = 5.693519256055879e-08
TX = 6526.474380746091
TY = 5210.664390686138

def conv(wx, wy):
    return (A*wx + B*wy + TX, A*wy - B*wx + TY)

print("=" * 78)
print("底图 bigworldmap-13056.jpg 的有效内容范围")
print("=" * 78)
im = Image.open(f"{ROOT}/models/bigworldmap-13056.jpg").convert("L")
print("尺寸: %s  模式已转 L" % (im.size,))
arr = np.asarray(im, dtype=np.uint8)
print("亮度: min=%d max=%d mean=%.2f" % (arr.min(), arr.max(), arr.mean()))
# 有效地图内容判定：非纯黑（>8）
mask = arr > 8
rows = np.where(mask.any(axis=1))[0]
cols = np.where(mask.any(axis=0))[0]
print("有效内容 Y 范围: %d .. %d" % (rows.min(), rows.max()))
print("有效内容 X 范围: %d .. %d" % (cols.min(), cols.max()))
print("有效像素占比: %.2f%%" % (100.0 * mask.sum() / mask.size))

def in_content(mx, my):
    x = int(round(mx)); y = int(round(my))
    if not (0 <= x < arr.shape[1] and 0 <= y < arr.shape[0]): return False, None
    return bool(mask[y, x]), int(arr[y, x])

print()
print("=" * 78)
print("A) 传送点 124 个：换算落点处底图是否有内容")
print("=" * 78)
tp = json.load(open(f"{ROOT}/tools/nte_datatables/DataTable/DT_TeleportPoint.json", encoding="utf-8"))
if isinstance(tp, list): tp = tp[0]
pts = []
for k, v in tp["Rows"].items():
    tr = ((v or {}).get("Transform") or {}).get("Translation") or {}
    if tr.get("X") is None: continue
    pts.append((k, tr["X"], tr["Y"]))
hit = 0
detail = []
for k, wx, wy in pts:
    mx, my = conv(wx, wy)
    ok, lum = in_content(mx, my)
    if ok: hit += 1
    detail.append((k, mx, my, ok, lum))
print("落点在有内容区域: %d / %d" % (hit, len(pts)))
for d in detail[:6]:
    print("  %-32s map(%.0f,%.0f) 内容=%s 亮度=%s" % (d[0][:32], d[1], d[2], d[3], d[4]))

print()
print("=" * 78)
print("B) 控制实验：把同一批世界坐标分别按 4 种尺寸**假设**缩放后的落点")
print("   （公式本身输出 13056 像素；这里检验“若地图其实是别的尺寸，会怎样”）")
print("=" * 78)
for S in (11264, 13056, 22528, 26112):
    k = S / 13056.0
    cnt = 0
    for _, wx, wy in pts:
        mx, my = conv(wx, wy)
        ok, _l = in_content(mx * k, my * k)
        if ok: cnt += 1
    print("  假定地图 %-6d (缩放 ×%.4f) → 落点命中内容 %d/%d" % (S, k, cnt, len(pts)))
print()
print("  说明：只有 13056（k=1）与底图真实像素一一对应；")
print("        11264/22528/26112 都会把同一个 13056 像素值当作别的尺度去取样，")
print("        属于“拿错尺子”，即使部分点偶然落在内容上也不构成正确性证据。")
print("        真正的一票否决来自 map_locations.json 的 1777 个真实点：")
print("        其 mapY 最大 11393.5 > 11264，11264 装不下（5 个点出界）。")
