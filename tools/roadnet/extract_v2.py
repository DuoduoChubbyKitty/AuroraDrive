#!/usr/bin/env python3
"""
路网提取 v2 —— 全域路网（含小道、郊野细路）

用户 2026-10-03 反馈（v1 的问题）：
  「你这个些点真的太少太少了」「时不时密一下稀一下」
  「还有很多道路都没打上，有些小道都没打上」
  「还有一些弯道上没有点，模型可能会冲飞出去」

v1 失败根因（本脚本修正）：
  ① 单阈值 >50 → 只留最亮干道，亮度 20-40 的小道/郊野细路全丢。
     实测城区亮度是多峰：0-2 背景 / 16-26 郊野地面 / 40-47 中路 / 82+ 主干。
  ② 用形态学细化 → 弯道产生毛刺与断点（「弯道没有点」的直接原因）。
     改用 skimage.morphology.skeletonize（标准算法，弯道连续）。
  ③ 全局阈值无法同时适配城区（亮实心面）与郊野（暗细线）。

v2 方案：
  · 基底：高阈值 >40 抓城区路面 + 主干（亮实心面/亮线）
  · 补充：低阈值 >18 抓郊野，再用形态学开运算**分离大色块(地形)与细线(道路)**
          —— 道路的特征是「细」，地形/郊野地面是「大片」
  · 骨架：skimage.skeletonize（弯道不断）
  · 建图：节点/边 + 合并度=2 假节点 + RDP 抽稀平滑
"""
import sys, json, math
import numpy as np
import cv2
from scipy import ndimage
from skimage.morphology import skeletonize

MAP   = 'models/bigworldmap-13056.jpg'
OUTG  = 'tools/roadnet/road_graph.json'
SCALE = 2                 # 1px = 1.22m
T_HIGH = 40
T_LOW  = 18
BLOB_K = 21               # 大于此尺度的连通亮区视为地形而非道路
PRUNE_M = 12.0
RDP_EPS_PX = 2.0

A, B   = 0.016394586684750773, 5.693519256055879e-08
TX, TY = 6526.474380746091, 5210.664390686138
M_PER_PX_MAP = 0.61
PX_PER_M = SCALE * M_PER_PX_MAP

print(f"═══ ① 读取 {MAP} ═══")
img = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
H, W = img.shape[0] // SCALE, img.shape[1] // SCALE
g = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
del img
print(f"  {W}x{H}  1px = {PX_PER_M:.2f} m")

print("═══ ② 多尺度路面提取 ═══")
high = (g > T_HIGH).astype(np.uint8)
low = (g > T_LOW).astype(np.uint8)
el = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (BLOB_K, BLOB_K))
blob = cv2.morphologyEx(low, cv2.MORPH_OPEN, el)
thin = cv2.subtract(low, blob)
print(f"  高阈值>{T_HIGH}: {high.mean()*100:5.2f}%  （城区路面 + 主干）")
print(f"  低阈值>{T_LOW}: {low.mean()*100:5.2f}%")
print(f"  其中大色块(地形): {blob.mean()*100:5.2f}%   细线(小道): {thin.mean()*100:5.2f}%")

road = np.maximum(high, thin)
print(f"  ★ 合并路面: {road.mean()*100:.2f}%")

print("═══ ③ 清噪 + 补断口 ═══")
road = cv2.morphologyEx(road, cv2.MORPH_CLOSE,
                        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)), iterations=1)
lab, n = ndimage.label(road)
sz = ndimage.sum(road, lab, range(1, n + 1))
minpx = max(8, int(200 / (PX_PER_M * PX_PER_M)))
road = np.isin(lab, [i for i, s in enumerate(sz, 1) if s >= minpx]).astype(np.uint8)
lab2, n2 = ndimage.label(road)
sz2 = sorted(ndimage.sum(road, lab2, range(1, n2 + 1)), reverse=True)
print(f"  分量 {n} → {n2}；最大占 {sz2[0]/road.sum()*100:.1f}%")

print("═══ ④ 骨架化（skimage，弯道连续）═══")
sk = skeletonize(road > 0).astype(np.uint8)
print(f"  骨架 {int(sk.sum())} px = {sk.sum()*PX_PER_M/1000:.1f} km")

print("═══ ⑤ 建图 ═══")
S = sk
nb = cv2.filter2D(S, -1, np.ones((3, 3), np.uint8), borderType=cv2.BORDER_CONSTANT) - S
deg = nb * S
is_node = (((deg == 1) | (deg >= 3)) & (S == 1)).astype(np.uint8)
nl, nn = ndimage.label(is_node, structure=np.ones((3, 3)))
cent = ndimage.center_of_mass(is_node, nl, range(1, nn + 1))
print(f"  原始节点 {nn}")

neigh = [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)]
edges = []; seen = set()
for y0, x0 in zip(*np.nonzero(S)):
    y0 = int(y0); x0 = int(x0)
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
        if len(path) < 2: continue
        ey, ex = path[-1]
        seen.add((ey, ex, path[-2][0], path[-2][1]))
        edges.append({'a': int(nl[y0, x0]),
                      'b': int(nl[ey, ex]) if nl[ey, ex] else 0,
                      'path': path})
print(f"  原始边 {len(edges)}")

print("═══ ⑥ 合并度=2 假节点（把被切碎的直路接回来）═══")
for _ in range(200):
    degc = {}
    for e in edges:
        degc[e['a']] = degc.get(e['a'], 0) + 1
        if e['b']: degc[e['b']] = degc.get(e['b'], 0) + 1
    # 找度为 2 的节点
    fake = {nid for nid, d in degc.items() if d == 2 and nid != 0}
    if not fake: break
    merged = 0; newedges = []; used = set()
    byn = {}
    for i, e in enumerate(edges):
        for end in ('a', 'b'):
            byn.setdefault(e[end], []).append(i)
    for nid in fake:
        idxs = [i for i in byn.get(nid, []) if i not in used]
        if len(idxs) != 2: continue
        i, j = idxs
        if i == j: continue
        e1, e2 = edges[i], edges[j]
        # 拼接（保证 e1 的 b 端是 nid）
        if e1['b'] != nid: e1 = {'a': e1['b'], 'b': e1['a'], 'path': e1['path'][::-1]}
        if e2['a'] != nid: e2 = {'a': e2['b'], 'b': e2['a'], 'path': e2['path'][::-1]}
        if e1['b'] != nid or e2['a'] != nid: continue
        used.add(i); used.add(j)
        newedges.append({'a': e1['a'], 'b': e2['b'], 'path': e1['path'] + e2['path'][1:]})
        merged += 1
    for i, e in enumerate(edges):
        if i not in used: newedges.append(e)
    edges = newedges
    if merged == 0: break
print(f"  合并后 边 {len(edges)}")

print("═══ ⑦ 剪枝（<%.0fm 悬挂枝）═══" % PRUNE_M)
prune_px = PRUNE_M / PX_PER_M
for _ in range(50):
    degc = {}
    for e in edges:
        degc[e['a']] = degc.get(e['a'], 0) + 1
        if e['b']: degc[e['b']] = degc.get(e['b'], 0) + 1
    keep = []; rm = 0
    for e in edges:
        L = len(e['path'])
        hang = degc.get(e['a'], 0) == 1 or degc.get(e['b'], 0) == 1
        if hang and L < prune_px: rm += 1
        else: keep.append(e)
    edges = keep
    if rm == 0: break
print(f"  剪枝后 边 {len(edges)}")

print("═══ ⑧ RDP 抽稀平滑 + 输出 ═══")
out_nodes = {}
out_edges = []
for e in edges:
    p = np.array([[q[1], q[0]] for q in e['path']], np.float32)  # (x,y)
    if len(p) < 2: continue
    approx = cv2.approxPolyDP(p.reshape(-1, 1, 2), RDP_EPS_PX, False).reshape(-1, 2)
    if len(approx) < 2: continue
    a, b = e['a'], e['b']
    if a not in out_nodes:
        out_nodes[a] = {'id': a, 'x': int(cent[a-1][1]), 'y': int(cent[a-1][0])}
    if b and b not in out_nodes:
        out_nodes[b] = {'id': b, 'x': int(cent[b-1][1]), 'y': int(cent[b-1][0])}
    L = float(np.hypot(*(np.diff(p, axis=0).T)).sum())
    out_edges.append({'a': a, 'b': b, 'len_px': round(L, 1),
                      'len_m': round(L * PX_PER_M, 1),
                      'poly': [[float(q[0]), float(q[1])] for q in approx]})

tot_px = sum(e['len_px'] for e in out_edges)
print(f"  节点 {len(out_nodes)}  边 {len(out_edges)}")
print(f"  总长 {tot_px*PX_PER_M/1000:.1f} km   （v1 是 87.2 km）")

json.dump({'meta': {'source': MAP, 'scale': SCALE, 'size': [W, H],
                    'px_per_m': PX_PER_M, 't_high': T_HIGH, 't_low': T_LOW,
                    'blob_k': BLOB_K, 'prune_m': PRUNE_M,
                    'nodes': len(out_nodes), 'edges': len(out_edges),
                    'total_km': round(tot_px*PX_PER_M/1000, 1)},
           'nodes': list(out_nodes.values()),
           'edges': out_edges}, open(OUTG, 'w'))
np.save('/tmp/sk_v2.npy', S)
print(f"\n  ✓ {OUTG}")
