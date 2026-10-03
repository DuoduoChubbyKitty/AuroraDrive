#!/usr/bin/env python3
"""
路网提取 v4 —— 用户引导补抽（user-guided）

背景：v3 用全局 >45，精确率 99.4% 但召回只有 80%。用户 2026-10-03 指出
      「非常非常淡的那条线断掉了」，并用配套网页（tools/roadnet/web/index.html）
      手动画出漏掉的路段，导出 road_patch_*.png。

本脚本把用户的笔画当作【提示区域】，在这些区域里用更低阈值（>18）把
真实的路抽出来 —— 比直接用手画线干净得多（用户手画是抖的，底图上的路是真的）。

    >45 全局                        → 城区主干 + 亮路
    + ROI(用户笔画膨胀61px) 内 >18   → 淡淡的小路

实测：骨架 85960 → 104849 px（+22%），总长 125.7 → 153.2 km。
     用户提示区内 >=45 的浓度 7.23%，是区外 2.95% 的 2.4 倍，
     证实用户指的区域确实是路（只是亮度主要在 18-22）。

用法：
    python3 extract_guided.py [user_patch.png]
"""
import sys, json
import numpy as np
import cv2
from scipy import ndimage
from skimage.morphology import skeletonize

MAP = 'models/bigworldmap-13056.jpg'
PATCH = sys.argv[1] if len(sys.argv) > 1 else 'tools/roadnet/user_patch.png'
OUT = 'tools/roadnet/road_graph_v4.json'
SCALE = 2
T_BASE = 45
T_ROI = 18
ROI_GROW = 61
PRUNE_M = 8.0
PX_PER_M = SCALE * 0.61

print(f"═══ ① 底图 {MAP} ═══")
img = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
H, W = img.shape[0] // SCALE, img.shape[1] // SCALE
g = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
del img

print(f"═══ ② 用户提示 {PATCH} ═══")
p = cv2.imread(PATCH, cv2.IMREAD_UNCHANGED)
if p is None or p.shape[0] != H:
    print(f"  ⚠️ 提示图缺失或尺寸不符（需 {H}x{W}），退化为纯自动提取")
    roi = np.zeros((H, W), np.uint8)
else:
    hint = (p[..., 3] > 60).astype(np.uint8)
    roi = cv2.dilate(hint, np.ones((ROI_GROW, ROI_GROW), np.uint8))
    print(f"  笔画 {int(hint.sum())} px → ROI {roi.mean()*100:.2f}%")

print("═══ ③ 混合阈值提取 ═══")
base = (g > T_BASE).astype(np.uint8)
extra = cv2.bitwise_and((g > T_ROI).astype(np.uint8), roi)
comb = cv2.bitwise_or(base, extra)
print(f"  >{T_BASE} {base.mean()*100:.2f}%  +ROI内>{T_ROI} → {comb.mean()*100:.2f}%")

lab, n = ndimage.label(comb)
sz = ndimage.sum(comb, lab, range(1, n + 1))
comb = np.isin(lab, np.where(sz >= 20)[0] + 1).astype(np.uint8)
print(f"  清噪(≥20px) {comb.mean()*100:.2f}%")

print("═══ ④ 骨架化 ═══")
sk = skeletonize(comb > 0).astype(np.uint8)
print(f"  {int(sk.sum())} px = {sk.sum()*PX_PER_M/1000:.1f} km")

print("═══ ⑤ 建图 ═══")
nb = cv2.filter2D(sk, -1, np.ones((3, 3), np.uint8), borderType=cv2.BORDER_CONSTANT) - sk
deg = nb * sk
is_node = (((deg == 1) | (deg >= 3)) & (sk == 1)).astype(np.uint8)
nl, nn = ndimage.label(is_node, structure=np.ones((3, 3)))
cent = ndimage.center_of_mass(is_node, nl, range(1, nn + 1))
neigh = [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)]
edges = []; seen = set()
for y0, x0 in zip(*np.nonzero(sk)):
    y0 = int(y0); x0 = int(x0)
    if nl[y0, x0] == 0: continue
    for dy, dx in neigh:
        y, x = y0+dy, x0+dx
        if not (0 <= y < H and 0 <= x < W) or not sk[y, x] or nl[y, x]: continue
        if (y0, x0, y, x) in seen: continue
        path = [(y0, x0), (y, x)]; seen.add((y0, x0, y, x))
        cy, cx, ly, lx = y, x, y0, x0
        while True:
            if nl[cy, cx]: break
            nxt = None
            for ddy, ddx in neigh:
                ny, nx2 = cy+ddy, cx+ddx
                if not (0 <= ny < H and 0 <= nx2 < W) or not sk[ny, nx2]: continue
                if (ny, nx2) == (ly, lx) or (ny, nx2) in path[-4:]: continue
                nxt = (ny, nx2); break
            if nxt is None: break
            path.append(nxt); ly, lx = cy, cx; cy, cx = nxt
        if len(path) < 3: continue
        ey, ex = path[-1]
        seen.add((ey, ex, path[-2][0], path[-2][1]))
        pxy = np.array([[q[1], q[0]] for q in path], np.float32)
        ap = cv2.approxPolyDP(pxy.reshape(-1,1,2), 2.0, False).reshape(-1,2)
        if len(ap) < 2: continue
        L = float(np.hypot(*(np.diff(pxy, axis=0).T)).sum())
        edges.append({'a': int(nl[y0,x0]),
                      'b': int(nl[ey,ex]) if nl[ey,ex] else 0,
                      'len_px': round(L,1), 'len_m': round(L*PX_PER_M,1),
                      'poly': [[float(q[0]), float(q[1])] for q in ap]})

tot = sum(e['len_px'] for e in edges) * PX_PER_M / 1000
print(f"  节点 {nn}  边 {len(edges)}  总长 {tot:.1f} km")
json.dump({'meta': {'source': MAP, 'scale': SCALE, 'size': [W, H],
                    't_base': T_BASE, 't_roi': T_ROI, 'roi_grow': ROI_GROW,
                    'px_per_m': PX_PER_M, 'edges': len(edges),
                    'total_km': round(tot, 1),
                    'user_guided': bool(roi.any())},
           'nodes': [{'id': i+1, 'x': int(cent[i][1]), 'y': int(cent[i][0])} for i in range(nn)],
           'edges': edges}, open(OUT, 'w'))
np.save('/tmp/sk_v4.npy', sk)
print(f"\n  ✓ {OUT}")
