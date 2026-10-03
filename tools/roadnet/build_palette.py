#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_palette.py —— 把原图 96 个灰阶各自做成一张 3264² 的"遮罩层"

用途：浏览器里点调色板任意一格 → 该灰阶在全图的分布立刻叠在原图上。
这就是"把地图中有这种颜色的全部提取出来，叠加到原图上"。

输出：
  tools/roadnet/web/palette/g{值}.png   3264² RGBA（白色 + alpha=遮罩）
  tools/roadnet/web/palette/index.json  [{v, share, px, lit}] 按占比降序
"""
import os, json
import numpy as np
import cv2

MAP = 'models/bigworldmap-13056.jpg'
OUT = 'tools/roadnet/web/palette'
D = 3264                      # 输出边长（world 6528 的一半）
os.makedirs(OUT, exist_ok=True)

print('读原生底图…', flush=True)
g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
H, W = g.shape
N = g.size
print(f'  {W}x{H}', flush=True)

hist = np.bincount(g.ravel(), minlength=256)
info = []
for v in range(256):
    share = hist[v] / N * 100
    if share < 0.005:          # 低于 0.005% 的忽略
        continue
    m = (g == v).astype(np.float32)
    d = cv2.resize(m, (D, D), interpolation=cv2.INTER_AREA)
    # 面积平均后又阈值 → 保住细线；再轻微膨胀防止缩略时消失
    a = (d > 0.08).astype(np.uint8)
    if a.sum():
        k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        a = cv2.dilate(a, k)
    rgba = np.zeros((D, D, 4), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = a * 255
    cv2.imwrite(f'{OUT}/g{v}.png', rgba)
    info.append({'v': int(v), 'share': round(share, 4),
                 'px': int(hist[v]), 'lit': int(a.sum())})
    del m, d, a, rgba
    print(f'  g{v:<3d} share {share:7.4f}%  px {hist[v]:>9d}', flush=True)

info.sort(key=lambda x: -x['share'])
json.dump(info, open(f'{OUT}/index.json', 'w'), indent=0, ensure_ascii=False)
print(f'★ 共 {len(info)} 个灰阶 → {OUT}', flush=True)
