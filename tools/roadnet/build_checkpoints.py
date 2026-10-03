#!/usr/bin/env python3
"""
路网矢量 + 检查点生成（1/2 分辨率）

用户 2026-10-03：
  「提取出路网…网上打满点就是全部打满点做成一个个的检查点」
  「一个检查点到另一个检查点一个个走过去」

★ 关键：5 米间距需要足够分辨率。1/4 降采样时 1px=2.44m，5m 只有 2px，撑不住。
  改用 1/2（6528²，1px=1.22m，5m≈4px）。

坐标：骨架像素 → 地图像素(13056系, ×SCALE) → 世界坐标(UE5厘米, kCalib 逆变换)
"""
import sys, json, math
import numpy as np
import cv2
from scipy import ndimage

MAP   = 'models/bigworldmap-13056.jpg'
OUTG  = 'tools/roadnet/road_graph.json'
OUTC  = 'tools/roadnet/checkpoints.json'
SCALE = 2
THRESH = 50
PRUNE_M = 15.0          # 剪掉短于 15m 的悬挂枝
SPACING_M = 5.0         # 检查点间距

# 生产同款标定（CoordinateCapture.kCalib*）
A, B  = 0.016394586684750773, 5.693519256055879e-08
TX, TY = 6526.474380746091, 5210.664390686138
M_PER_PX_MAP = 0.61

print(f"═══ ① 读取底图 {MAP} ═══")
img = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
H, W = img.shape[0] // SCALE, img.shape[1] // SCALE
g = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
del img
print(f"  {W}x{H}  1 像素 = {SCALE*M_PER_PX_MAP:.2f} m")

print("═══ ② 路面掩码 ═══")
m = (g > THRESH).astype(np.uint8)
m = cv2.morphologyEx(m, cv2.MORPH_CLOSE,
                     cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)), iterations=2)
lab, n = ndimage.label(m)
sz = ndimage.sum(m, lab, range(1, n + 1))
m = np.isin(lab, [i for i, s in enumerate(sz, 1) if s >= 2000]).astype(np.uint8)
print(f"  路面 {m.mean()*100:.2f}%  分量 {int((sz>=2000).sum())}")

print("═══ ③ 骨架化 ═══")
if hasattr(cv2, 'ximgproc'):
    sk = cv2.ximgproc.thinning(m * 255); print("  用 ximgproc")
else:
    sk = np.zeros_like(m); tmp = m.copy()
    el = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3)); it = 0
    while cv2.countNonZero(tmp):
        er = cv2.erode(tmp, el); op = cv2.dilate(er, el)
        sk = cv2.bitwise_or(sk, cv2.subtract(tmp, op)); tmp = er; it += 1
        if it % 20 == 0: print(f"    …{it} 轮")
    print(f"  形态学细化 {it} 轮")
S = (sk > 0).astype(np.uint8)
print(f"  骨架像素 {int(S.sum())}")

print("═══ ④ 建图 ═══")
nb = cv2.filter2D(S, -1, np.ones((3, 3), np.uint8), borderType=cv2.BORDER_CONSTANT) - S
deg = nb * S
is_node = (((deg == 1) | (deg >= 3)) & (S == 1)).astype(np.uint8)
nl, nn = ndimage.label(is_node, structure=np.ones((3, 3)))
cent = ndimage.center_of_mass(is_node, nl, range(1, nn + 1))
print(f"  节点 {nn}")

neigh = [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)]
edges = []; seen = set()
ys, xs = np.nonzero(S)
todo = list(zip(ys.tolist(), xs.tolist()))
for y0, x0 in todo:
    if nl[y0, x0] == 0: continue
    for dy, dx in neigh:
        y, x = y0 + dy, x0 + dx
        if not (0 <= y < H and 0 <= x < W) or not S[y, x] or nl[y, x]: continue
        if (y0, x0, y, x) in seen: continue
        path = [(y0, x0), (y, x)]; seen.add((y0, x0, y, x))
        cy, cx, ly, lx = y, x, y0, x0
        while True:
            if nl[cy, cx]: break
            nxt = None
            for ddy, ddx in neigh:
                ny, nx2 = cy+ddy, cx+ddx
                if not (0 <= ny < H and 0 <= nx2 < W) or not S[ny, nx2]: continue
                if (ny, nx2) == (ly, lx) or (ny, nx2) in path[-4:]: continue
                nxt = (ny, nx2); break
            if nxt is None: break
            path.append(nxt); ly, lx = cy, cx; cy, cx = nxt
        if len(path) < 3: continue
        ey, ex = path[-1]
        if not nl[ey, ex] or not nl[y0, x0]: continue
        seen.add((ey, ex, path[-2][0], path[-2][1]))
        seg = np.array(path, float)
        L = float(np.hypot(*(np.diff(seg, axis=0).T)).sum())
        edges.append({'a': int(nl[y0, x0]), 'b': int(nl[ey, ex]), 'len_px': L,
                      'path': path})
print(f"  边 {len(edges)}")

print("═══ ⑤ 剪枝（<%.0fm 悬挂枝）═══" % PRUNE_M)
px_per_m = SCALE * M_PER_PX_MAP
prune_px = PRUNE_M / px_per_m
for rnd in range(30):
    deg_cnt = {}
    for e in edges:
        deg_cnt[e['a']] = deg_cnt.get(e['a'], 0) + 1
        deg_cnt[e['b']] = deg_cnt.get(e['b'], 0) + 1
    keep = []
    removed = 0
    for e in edges:
        hang = deg_cnt.get(e['a'], 0) == 1 or deg_cnt.get(e['b'], 0) == 1
        if hang and e['len_px'] < prune_px:
            removed += 1
        else:
            keep.append(e)
    edges = keep
    if removed == 0: break
print(f"  剪枝后 边 {len(edges)}  剩余总长 {sum(e['len_px'] for e in edges)*px_per_m/1000:.1f} km")

print("═══ ⑥ 打检查点（每 %.0fm，路口加密到 2m）═══" % SPACING_M)
sp_px = SPACING_M / px_per_m
near_junc = set()
for e in edges:
    near_junc.add(e['a']); near_junc.add(e['b'])
junc_px = set()
for e in edges:
    if len(e['path']) > 3:
        junc_px.add(e['path'][2]); junc_px.add(e['path'][-3])

ckpts = []
for idx, e in enumerate(edges):
    p = np.array(e['path'], float)
    seglen = np.hypot(*(np.diff(p, axis=0).T))
    cum = np.concatenate([[0], np.cumsum(seglen)])
    total = cum[-1]
    if total < 1: continue
    # 位置处是否靠近路口 → 加密
    t = 0.0
    while t <= total:
        i = int(np.searchsorted(cum, t, 'right') - 1); i = max(0, min(len(p)-2, i))
        f = (t - cum[i]) / max(1e-9, seglen[i])
        y = p[i][0] + f * (p[i+1][0] - p[i][0])
        x = p[i][1] + f * (p[i+1][1] - p[i][1])
        # 朝向
        j = min(len(p)-1, i+1)
        hd = math.degrees(math.atan2(p[j][1]-p[i][1], -(p[j][0]-p[i][0]))) % 360
        # 地图像素 (13056系)
        mx, my = x * SCALE, y * SCALE
        # 世界坐标（逆变换）
        d = A*A + B*B
        wx = (A*(mx-TX) - B*(my-TY)) / d
        wy = (B*(mx-TX) + A*(my-TY)) / d
        ckpts.append({'i': len(ckpts), 'mapX': round(mx,1), 'mapY': round(my,1),
                      'x': round(wx,1), 'y': round(wy,1), 'h': round(hd,1), 'e': idx})
        # 靠近路口用 2m，否则 5m
        isJ = (i <= 2 or i >= len(p)-3)
        t += (2.0 if isJ else SPACING_M) / px_per_m
print(f"  ★ 检查点总数 {len(ckpts)}")
print(f"    平均间距 ≈ {sum(e['len_px'] for e in edges)*px_per_m/max(1,len(ckpts)):.2f} m")

json.dump({'meta': {'spacing_m': SPACING_M, 'prune_m': PRUNE_M, 'scale': SCALE,
                    'count': len(ckpts), 'px_per_m': px_per_m},
           'checkpoints': ckpts}, open(OUTC, 'w'))
json.dump({'meta': {'nodes': nn, 'edges': len(edges), 'scale': SCALE},
           'nodes': [{'id': i+1, 'x': int(round(cent[i][1])), 'y': int(round(cent[i][0]))}
                     for i in range(nn)],
           'edges': [{'a': e['a'], 'b': e['b'], 'len_px': round(e['len_px'],1),
                      'poly': [[int(q[1]), int(q[0])] for q in e['path'][::max(1,len(e['path'])//24)]]}
                     for e in edges]}, open(OUTG, 'w'))
np.save('/tmp/skel2.npy', S)
print(f"\n  ✓ {OUTG}\n  ✓ {OUTC}")
