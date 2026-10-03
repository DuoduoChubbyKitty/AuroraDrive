#!/usr/bin/env python3
"""阈值方案对比：找出能把【所有道路（含小道）】抽出来的方法。"""
import cv2, numpy as np

g = cv2.resize(cv2.imread('models/bigworldmap-13056.jpg', cv2.IMREAD_GRAYSCALE),
               (6528, 6528), interpolation=cv2.INTER_AREA)

AREAS = {
    '城区A': (2800, 2800, 3600, 3600),
    '城区B': (2600, 2700, 3200, 3150),
    '郊野':  (300, 300, 1100, 1100),
}

def render(tag):
    rows = []
    for name, (x0, y0, x1, y1) in AREAS.items():
        c = g[y0:y1, x0:x1]
        tiles = []
        # 1 原图
        orig = cv2.cvtColor(cv2.normalize(c, None, 0, 255, cv2.NORM_MINMAX), cv2.COLOR_GRAY2BGR)
        tiles.append(orig)
        # 2 全局 >50
        m = (c > 50).astype(np.uint8)
        t = orig.copy(); t[m > 0] = [0, 255, 255]; tiles.append(t)
        # 3 全局 >30
        m = (c > 30).astype(np.uint8)
        t = orig.copy(); t[m > 0] = [0, 255, 255]; tiles.append(t)
        # 4 自适应（亮线）
        a = cv2.adaptiveThreshold(c, 255, cv2.ADAPTIVE_THRESH_MEAN_C,
                                  cv2.THRESH_BINARY, 31, -8)
        t = orig.copy(); t[a > 0] = [0, 255, 255]; tiles.append(t)
        # 5 自适应（更宽）
        a2 = cv2.adaptiveThreshold(c, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                   cv2.THRESH_BINARY, 21, -5)
        t = orig.copy(); t[a2 > 0] = [0, 255, 255]; tiles.append(t)
        row = np.hstack([cv2.resize(x, (420, 420)) for x in tiles])
        cv2.putText(row, name, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 0), 2)
        rows.append(row)
    out = np.vstack(rows)
    labels = ['原图', '>50', '>30', '自适应31/-8', '自适应21/-5']
    for i, L in enumerate(labels):
        cv2.putText(out, L, (i * 420 + 10, 460), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 200, 255), 2)
    cv2.imwrite(f'/tmp/cmp_{tag}.png', out)
    print(f'  ✓ /tmp/cmp_{tag}.png  ({out.shape[1]}x{out.shape[0]})')

render('th')
print('  列含义: 原图 | 全局>50 | 全局>30 | 自适应MEAN 31/-8 | 自适应GAUSS 21/-5')
print('  行含义: 城区A / 城区B / 郊野')
