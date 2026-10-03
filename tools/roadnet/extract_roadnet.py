#!/usr/bin/env python3
"""
从游戏大地图提取【矢量路网】—— 检查点系统的原料。

用户 2026-10-03：
  「你把大地图提出来不就行了」「提取出路网…网上打满点做成一个个检查点」

★ 关键发现（2026-10-03 实测）：
  bigworldmap-13056.jpg 里 **路面是亮的（≈68-80），背景是暗的（0-16）**，
  图标是 80+。此前本脚本用局部对比度是**方向性错误**，实测走弯路两次。
  生产资产 road_prior_2048_t70_fixed.png 与它完全对齐（路面处亮度 68.7，
  非路处 9.6），是同一张图抽的。
  阈值 >50 时：前景 2.42%、连通分量仅 15 个、最大分量占 98.5% —— 路网连通。

输入：models/bigworldmap-13056.jpg（13056²，与 kCalib* 标定对齐的底图）
输出：tools/roadnet/road_graph.json
"""
import sys, json, math
import numpy as np
import cv2
from scipy import ndimage

MAP = sys.argv[1] if len(sys.argv) > 1 else 'models/bigworldmap-13056.jpg'
OUT = sys.argv[2] if len(sys.argv) > 2 else 'tools/roadnet/road_graph.json'
SCALE = 4
THRESH = 50

print(f"═══ 读取 {MAP} ═══")
img = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
H, W = img.shape[0] // SCALE, img.shape[1] // SCALE
g = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
print(f"  {img.shape[1]}x{img.shape[0]} → {W}x{H} ({SCALE}x)")

# ── ① 路面 = 亮 ──
m = (g > THRESH).astype(np.uint8)
print(f"  ① 阈值>{THRESH} → 路面 {m.mean()*100:.2f}%")

# ── ② 闭运算补路口断口 ──
k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, k, iterations=2)
print(f"  ② 闭运算后 {m.mean()*100:.2f}%")

# ── ③ 去小块 ──
lab, n = ndimage.label(m)
sz = ndimage.sum(m, lab, range(1, n + 1))
keep = np.isin(lab, [i for i, s in enumerate(sz, 1) if s >= 300]).astype(np.uint8)
lab2, n2 = ndimage.label(keep)
sz2 = sorted(ndimage.sum(keep, lab2, range(1, n2 + 1)), reverse=True)
print(f"  ③ 分量 {n} → {n2}；最大占比 {sz2[0]/keep.sum()*100:.1f}%")

# ── ④ 骨架化 ──
if hasattr(cv2, 'ximgproc'):
    sk = cv2.ximgproc.thinning(keep * 255)
    print(f"  ④ 骨架像素 {int((sk>0).sum())}（ximgproc）")
else:
    sk = np.zeros_like(keep); tmp = keep.copy()
    el = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))
    while cv2.countNonZero(tmp):
        er = cv2.erode(tmp, el); op = cv2.dilate(er, el)
        sk = cv2.bitwise_or(sk, cv2.subtract(tmp, op)); tmp = er
    print(f"  ④ 骨架像素 {int((sk>0).sum())}（形态学细化）")

S = (sk > 0).astype(np.uint8)
nb = cv2.filter2D(S, -1, np.ones((3, 3), np.uint8), borderType=cv2.BORDER_CONSTANT) - S
deg = nb * S
is_node = (((deg == 1) | (deg >= 3)) & (S == 1)).astype(np.uint8)
nl, nn = ndimage.label(is_node, structure=np.ones((3, 3)))
centers = ndimage.center_of_mass(is_node, nl, range(1, nn + 1))
print(f"  ⑤ 节点（路口+端点）: {nn}")

neigh = [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)]
edges = []; seen = set()
ys, xs = np.nonzero(S)
for y0, x0 in zip(ys.tolist(), xs.tolist()):
    if nl[y0, x0] == 0: continue
    for dy, dx in neigh:
        y, x = y0 + dy, x0 + dx
        if not (0 <= y < H and 0 <= x < W) or not S[y, x] or nl[y, x] != 0: continue
        if (y0, x0, y, x) in seen: continue
        path = [(y0, x0), (y, x)]; seen.add((y0, x0, y, x))
        cy, cx, ly, lx = y, x, y0, x0
        while True:
            if nl[cy, cx] != 0: break
            nxt = None
            for ddy, ddx in neigh:
                ny, nx2 = cy + ddy, cx + ddx
                if not (0 <= ny < H and 0 <= nx2 < W) or not S[ny, nx2]: continue
                if (ny, nx2) == (ly, lx) or (ny, nx2) in path[-4:]: continue
                nxt = (ny, nx2); break
            if nxt is None: break
            path.append(nxt); ly, lx = cy, cx; cy, cx = nxt
        if len(path) < 3: continue
        ey, ex = path[-1]
        if nl[ey, ex] == 0 or nl[y0, x0] == 0: continue
        seen.add((ey, ex, path[-2][0], path[-2][1]))
        seg = np.array(path, float)
        L = float(np.hypot(*(np.diff(seg, axis=0).T)).sum())
        step = max(1, len(path) // 24)
        edges.append({'a': int(nl[y0, x0]), 'b': int(nl[ey, ex]),
                      'len_px': round(L, 1),
                      'poly': [[int(p[1]), int(p[0])] for p in path[::step]]})

tot = sum(e['len_px'] for e in edges)
print(f"  ⑥ 边数 {len(edges)}  总长 {tot:.0f}px = {tot*SCALE*0.61/1000:.1f} km")

out = {'meta': {'source': MAP, 'scale': SCALE, 'size': [W, H],
                'meters_per_px': SCALE * 0.61, 'threshold': THRESH,
                'nodes': nn, 'edges': len(edges),
                'total_len_px': round(tot, 1)},
       'nodes': [{'id': i + 1, 'x': int(round(centers[i][1])), 'y': int(round(centers[i][0]))} for i in range(nn)],
       'edges': edges}
json.dump(out, open(OUT, 'w'))
np.save('/tmp/road_skel.npy', S)
print(f"\n  ✓ {OUT}")
