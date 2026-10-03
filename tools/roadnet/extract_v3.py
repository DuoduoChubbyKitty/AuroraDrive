#!/usr/bin/env python3
"""
路网提取 v3 —— 原生分辨率（修正 v1/v2 的分辨率损失）

★★★ 2026-10-03 用生产资产 road_prior_2048_t70_fixed.png 做真值，量化出
      本问题此前所有版本的根因（这一步此前从未做过，全靠肉眼猜，故反复走偏）：

    阈值    召回率   精确率    IoU
    >40     87.2%    77.6%    69.7%
    >45     83.7%    99.6%    83.4%   ← 生产资产用的就是这一档
    >50     80.3%   100.0%    80.3%

  ① road_prior_2048 是从 bigworldmap-13056 用「>45」抽出后**降到 2048** 的。
     也就是说：**生产资产自己就丢了 16.3% 的路**（召回率 83.7%）。
  ② 更致命的是**降采样**：原图 13056² → 2048²，缩了 6.4 倍。
     原图上 1px 宽的细路，降到 2048 后只剩 0.15px，**直接消失**。
     这就是用户说的「小道没打上」的物理原因 —— 不是算法阈值问题，是分辨率。
  ③ v1/v2 在 1/4、1/2 上做同样的事，犯了同一个错：INTER_AREA 把
     「83 的细路 + 1 的暗背景」平均成 ~42，**刚好落在阈值 45 以下**，
     于是细路被自己的降采样抹掉。

  v3 的做法：**在 13056 原生分辨率上做阈值**（保住 1px 细路），
  再用 **max-pooling**（而非 INTER_AREA）降到 1/2 做骨架 ——
  max 保留细路，area 抹掉细路，这一字之差就是「有没有路」的区别。

输出：tools/roadnet/road_graph_v3.json
      tools/roadnet/road_mask_v3.png   （原生分辨率路面掩码，可肉眼验收）
"""
import json
import numpy as np
import cv2
from scipy import ndimage
from skimage.morphology import skeletonize

MAP = 'models/bigworldmap-13056.jpg'
OUTG = 'tools/roadnet/road_graph_v3.json'
OUTM = 'tools/roadnet/road_mask_v3.png'
THRESH = 45
MIN_PX_NATIVE = 15          # ★ 实测：60 会删掉细路碎片（召回 83.7%→80.0%），15 才不伤路
PRUNE_M = 10.0
RDP_EPS = 2.0

A, B = 0.016394586684750773, 5.693519256055879e-08
TX, TY = 6526.474380746091, 5210.664390686138
M_PER_PX_MAP = 0.61

print(f"═══ ① 原生分辨率读取 {MAP} ═══")
img = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
NH, NW = img.shape
print(f"  {NW}x{NH}  （这是 kCalib* 标定对齐的底图）")

print("═══ ② 原生阈值（保住 1px 细路）═══")
mask = (img > THRESH).astype(np.uint8)
print(f"  >{THRESH} → {mask.mean()*100:.2f}%  ({int(mask.sum())} px)")

print("═══ ③ 去噪（原生清除小连通块）═══")
lab, n = ndimage.label(mask)
sz = ndimage.sum(mask, lab, range(1, n + 1))
keep_ids = np.nonzero(sz >= MIN_PX_NATIVE)[0] + 1
mask = np.isin(lab, keep_ids).astype(np.uint8)
del lab
print(f"  分量 {n} → {len(keep_ids)}；前景 {mask.mean()*100:.2f}%")
cv2.imwrite(OUTM, mask * 255)

print("═══ ④ max-pooling 降到 1/2（★ 不能用 INTER_AREA，那会抹掉细路）═══")
SC = 2
H2, W2 = NH // SC, NW // SC
m2 = mask[:H2*SC, :W2*SC].reshape(H2, SC, W2, SC).max(axis=(1, 3))
PX_PER_M = SC * M_PER_PX_MAP
print(f"  {W2}x{H2}  1px = {PX_PER_M:.2f} m  前景 {m2.mean()*100:.2f}%")

print("═══ ⑤ 骨架化（skimage，弯道连续）═══")
sk = skeletonize(m2 > 0).astype(np.uint8)
print(f"  骨架 {int(sk.sum())} px = {sk.sum()*PX_PER_M/1000:.1f} km")

print("═══ ⑥ 建图 ═══")
S = sk
deg_map = cv2.filter2D(S, -1, np.ones((3, 3), np.uint8), borderType=cv2.BORDER_CONSTANT) - S
deg_map = deg_map * S
is_node = (((deg_map == 1) | (deg_map >= 3)) & (S == 1)).astype(np.uint8)
nl, nn = ndimage.label(is_node, structure=np.ones((3, 3)))
cent = ndimage.center_of_mass(is_node, nl, range(1, nn + 1))
print(f"  原始节点 {nn}")

neigh = [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)]
edges = []
seen = set()
ys, xs = np.nonzero(S)
for y0, x0 in zip(ys.tolist(), xs.tolist()):
    if nl[y0, x0] == 0:
        continue
    for dy, dx in neigh:
        y, x = y0 + dy, x0 + dx
        if not (0 <= y < H2 and 0 <= x < W2) or not S[y, x] or nl[y, x]:
            continue
        if (y0, x0, y, x) in seen:
            continue
        path = [(y0, x0), (y, x)]
        seen.add((y0, x0, y, x))
        cy, cx, ly, lx = y, x, y0, x0
        while True:
            if nl[cy, cx]:
                break
            nxt = None
            for ddy, ddx in neigh:
                ny, nx2 = cy + ddy, cx + ddx
                if not (0 <= ny < H2 and 0 <= nx2 < W2) or not S[ny, nx2]:
                    continue
                if (ny, nx2) == (ly, lx) or (ny, nx2) in path[-4:]:
                    continue
                nxt = (ny, nx2)
                break
            if nxt is None:
                break
            path.append(nxt)
            ly, lx = cy, cx
            cy, cx = nxt
        if len(path) < 2:
            continue
        ey, ex = path[-1]
        seen.add((ey, ex, path[-2][0], path[-2][1]))
        edges.append({'a': int(nl[y0, x0]),
                      'b': int(nl[ey, ex]) if nl[ey, ex] else 0,
                      'path': path})
print(f"  原始边 {len(edges)}")

print("═══ ⑦ 合并度=2 假节点（拼接被切碎的直路）═══")
for _ in range(300):
    degc = {}
    for e in edges:
        degc[e['a']] = degc.get(e['a'], 0) + 1
        if e['b']:
            degc[e['b']] = degc.get(e['b'], 0) + 1
    fake = {k for k, v in degc.items() if v == 2 and k != 0}
    if not fake:
        break
    byn = {}
    for i, e in enumerate(edges):
        byn.setdefault(e['a'], []).append(i)
        if e['b']:
            byn.setdefault(e['b'], []).append(i)
    used = set()
    newedges = []
    for nid in fake:
        idxs = [i for i in byn.get(nid, []) if i not in used]
        if len(idxs) != 2:
            continue
        i, j = idxs
        e1, e2 = edges[i], edges[j]
        if e1['b'] != nid:
            e1 = {'a': e1['b'], 'b': e1['a'], 'path': e1['path'][::-1]}
        if e2['a'] != nid:
            e2 = {'a': e2['b'], 'b': e2['a'], 'path': e2['path'][::-1]}
        if e1['b'] != nid or e2['a'] != nid:
            continue
        used.add(i)
        used.add(j)
        newedges.append({'a': e1['a'], 'b': e2['b'], 'path': e1['path'] + e2['path'][1:]})
    for i, e in enumerate(edges):
        if i not in used:
            newedges.append(e)
    if len(newedges) == len(edges):
        break
    edges = newedges
print(f"  合并后 边 {len(edges)}")

print("═══ ⑧ 剪枝 <%.0fm 悬挂枝 ═══" % PRUNE_M)
prune_px = PRUNE_M / PX_PER_M
for _ in range(60):
    degc = {}
    for e in edges:
        degc[e['a']] = degc.get(e['a'], 0) + 1
        if e['b']:
            degc[e['b']] = degc.get(e['b'], 0) + 1
    keep = []
    rm = 0
    for e in edges:
        hang = degc.get(e['a'], 0) == 1 or degc.get(e['b'], 0) == 1
        if hang and len(e['path']) < prune_px:
            rm += 1
        else:
            keep.append(e)
    edges = keep
    if rm == 0:
        break
print(f"  剪枝后 边 {len(edges)}")

print("═══ ⑨ RDP 抽稀 + 输出 ═══")
out_nodes = {}
out_edges = []
for e in edges:
    p = np.array([[q[1], q[0]] for q in e['path']], np.float32)
    if len(p) < 2:
        continue
    ap = cv2.approxPolyDP(p.reshape(-1, 1, 2), RDP_EPS, False).reshape(-1, 2)
    if len(ap) < 2:
        continue
    a, b = e['a'], e['b']
    if a not in out_nodes:
        out_nodes[a] = {'id': a, 'x': int(cent[a-1][1]), 'y': int(cent[a-1][0])}
    if b and b not in out_nodes:
        out_nodes[b] = {'id': b, 'x': int(cent[b-1][1]), 'y': int(cent[b-1][0])}
    L = float(np.hypot(*(np.diff(p, axis=0).T)).sum())
    out_edges.append({'a': a, 'b': b,
                      'len_px': round(L, 1), 'len_m': round(L * PX_PER_M, 1),
                      'poly': [[float(q[0]), float(q[1])] for q in ap]})

tot = sum(e['len_px'] for e in out_edges)
print(f"  节点 {len(out_nodes)}  边 {len(out_edges)}")
print(f"  总长 {tot*PX_PER_M/1000:.1f} km")
print(f"  （v1 = 87.2 km @1/4, v2 = 233.4 km @1/2 含噪声, v3 = 本值）")

json.dump({'meta': {'source': MAP, 'scale': SC, 'size': [W2, H2],
                    'native_size': [NW, NH],
                    'thresh_native': THRESH, 'px_per_m': PX_PER_M,
                    'nodes': len(out_nodes), 'edges': len(out_edges),
                    'total_km': round(tot * PX_PER_M / 1000, 1)},
           'nodes': list(out_nodes.values()),
           'edges': out_edges}, open(OUTG, 'w'))
np.save('/tmp/sk_v3.npy', S)
print(f"\n  ✓ {OUTG}\n  ✓ {OUTM}")
