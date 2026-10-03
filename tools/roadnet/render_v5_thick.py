#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render_v5_thick.py —— V5 粗白线路网（能盖住车的那种）

用户 2026-10-03 16:1x：
  "给我明显一点的线，要大一点、粗一点，能把车盖到直接覆盖起来，
   就要白线不要红线"

做法：拿 V5 的 1px 中心线，按圆盘膨胀成路面带宽度。
  原生 13056 下 1px = 0.61 m。
  W=13px ≈ 7.9 m  → 双车道，正好是原图实测的路宽(10~14px)
  W=17px ≈ 10.4 m → 更粗，绝对显眼
  W=25px ≈ 15.3 m → 夸张粗，小比例尺也一眼看得见

输出 docs/roadnet/v5/粗白线/
  V5粗白线_W{宽}_黑底.png       全分辨率白线黑底
  V5粗白线_W{宽}_压原图.png     全分辨率白线压原图
  粗细对比.png                  4 档并排（缩略）
"""
import os, json
import numpy as np
import cv2

MAP = 'models/bigworldmap-13056.jpg'
OUT = 'docs/roadnet/v5/粗白线'
SK = 'docs/roadnet/v5/V5_line_全分辨率.png'
M_PER_PX = 0.61
os.makedirs(OUT, exist_ok=True)

WIDTHS = [int(x) for x in os.environ.get('V5_WIDTHS', '9,13,17,25').split(',')]

print('读 1px 中心线…', flush=True)
sk = (cv2.imread(SK, cv2.IMREAD_GRAYSCALE) > 0).astype(np.uint8)
H, Wd = sk.shape
print(f'  {Wd}x{H}  骨架 {int(sk.sum())}px = {sk.sum()*M_PER_PX/1000:.1f} km', flush=True)

print('读原图…', flush=True)
g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
base = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
del g

tiles = []
for w in WIDTHS:
    r = max(1, w // 2)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (w, w))
    thick = cv2.dilate(sk, k)
    del k
    px = int(thick.sum())
    print(f'  W={w:>3d}px ({w*M_PER_PX:>5.1f} m)  覆盖 {px} px  '
          f'= {px/(H*Wd)*100:.2f}% 图面', flush=True)

    black = np.zeros((H, Wd, 3), np.uint8)
    black[thick > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5粗白线_W{w}_黑底.png', black)

    over = base.copy()
    over[thick > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5粗白线_W{w}_压原图.png', over)
    del over

    tiles.append((w, black))
    del thick

# 粗细对比（缩略 1/5）
sc = 5
tw, th_ = Wd // sc, H // sc
panels = []
for w, black in tiles:
    t = cv2.resize(black, (tw, th_), interpolation=cv2.INTER_AREA)
    cv2.putText(t, f'{w}px  {w*M_PER_PX:.1f}m', (40, 110),
                cv2.FONT_HERSHEY_SIMPLEX, 3.4, (0, 90, 255), 10)
    panels.append(t)
    del black
del tiles
row = np.hstack(panels[:2])
row2 = np.hstack(panels[2:]) if len(panels) > 2 else None
grid = np.vstack([row, row2]) if row2 is not None else row
cv2.imwrite(f'{OUT}/粗细对比.png', grid)
print(f'  → {OUT}  对比图 {grid.shape}', flush=True)

# 顺便出一张"粗白线压原图"的缩略给聊天里看
for w in WIDTHS:
    p = f'{OUT}/V5粗白线_W{w}_压原图.png'
    im = cv2.imread(p)
    cv2.imwrite(f'{OUT}/预览_W{w}.png',
                cv2.resize(im, (Wd // 3, H // 3), interpolation=cv2.INTER_AREA))
    del im
print('  预览图 OK', flush=True)

json.dump({'widths': WIDTHS, 'm_per_px': M_PER_PX, 'km': round(int(sk.sum())*M_PER_PX/1000, 1)},
          open(f'{OUT}/report.json', 'w'), indent=1)
