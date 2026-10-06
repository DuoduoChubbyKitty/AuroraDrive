#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_road_prior_t70.py — 从游戏大地图底图生成「干净路网先验位图」

【为什么需要这个脚本 / 2026-09-30 复盘】
  上一版用阈值 45 生成先验，导致弯道打点 83% 落在非路面（等高线/建筑纹理）上。
  真实灰度分布（13056 底图全图实测）：
      0 ~ 8   47.6%   纯黑（地图外/海）
     16 ~ 24  45.0%   暗背景（空地）
     24 ~ 56   4.8%   建筑纹理 + **等高线**
     80 ~ 88   1.95%  **真·道路（唯一）**
  ⟹ 阈值 45 会额外抓 16.1% 的等高线噪声（实测 677,265 像素），
     阈值 80 道路开始断裂（连通性从 87.8% 掉到 37.1%）。
  ⟹ **阈值 70 是正确答案**：连通性 87.8%，无等高线。

【输出】models/road_prior_2048_t70.png  (2048², 二值)
  1 格 = 13056 / 2048 px = 6.375 px ≈ 3.89 m

用法: python3 models/tools/make_road_prior_t70.py
"""
import numpy as np
from PIL import Image

SRC = 'models/bigworldmap-13056.jpg'
OUT = 'models/road_prior_2048_t70.png'
THRESHOLD = 70          # ★ 关键参数：见上文的灰度实测依据
GRID = 2048

Image.MAX_IMAGE_PIXELS = None

def main():
    gray = np.asarray(Image.open(SRC).convert('L'))
    print(f"输入 {SRC}  尺寸 {gray.shape}")

    road = (gray > THRESHOLD).astype(np.uint8) * 255
    print(f"阈值 {THRESHOLD}: 道路占比 {road.mean()/255*100:.2f}%")

    H, W = road.shape
    ch, cw = H // GRID, W // GRID
    # 最大池化：保留窄路（均值池化会把 4 格宽的路抹掉）
    small = road[:GRID*ch, :GRID*cw].reshape(GRID, ch, GRID, cw).max(axis=(1, 3))
    Image.fromarray(small, mode='L').save(OUT)

    cov = (small > 0).mean() * 100
    print(f"输出 {OUT}  {GRID}²  道路占比 {cov:.2f}%  1格={13056/GRID*0.61:.2f}m")
    import os
    print(f"文件大小 {os.path.getsize(OUT)/1024:.1f} KB")

if __name__ == '__main__':
    main()
