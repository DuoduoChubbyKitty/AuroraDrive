#!/usr/bin/env python3
"""
路网 → 可寻路图（routing graph）+ 拓扑清洗

用户 2026-10-03：
  「弄完路网之后，再想那种位置规划，还有寻路算法」

v4 的边是**骨架片段**（度=2 的假节点也当成节点），直接拿去寻路会有：
  · 节点数量虚高（2319 个，多数是折线拐点）
  · 路口被拆成多个相近节点（3x3 连通判定，一个十字路口可能 4 个节点）
寻路要的是**拓扑图**：节点 = 真路口/端点，边 = 一段可通行的路。

本脚本：
  ① 合并度=2 假节点 → 把碎折线缝成长路
  ② 路口聚类（半径内节点合并成一个路口）
  ③ 建邻接表，输出 routing.json
  ④ Dijkstra 自检：随机取点对算路，验证连通性
"""
import json, math, heapq, random
import numpy as np
from collections import defaultdict

IN  = 'tools/roadnet/road_graph_v4.json'
OUT = 'tools/roadnet/routing.json'
PX_PER_M = 1.22
JUNCTION_MERGE_PX = 6.0     # 6px ≈ 7.3m，路口内节点聚类半径

print(f"═══ ① 读入 {IN} ═══")
d = json.load(open(IN))
edges = d['edges']
nodes = {n['id']: (n['x'], n['y']) for n in d['nodes']}
print(f"  原始: 节点 {len(nodes)}  边 {len(edges)}")

# ── ② 合并度=2 假节点 ──
print("═══ ② 合并度=2 假节点（缝长路）═══")
E = [{'a': e['a'], 'b': e['b'], 'poly': [list(p) for p in e['poly']]}
     for e in edges if len(e['poly']) >= 2]

for _ in range(400):
    deg = defaultdict(int)
    for e in E:
        deg[e['a']] += 1
        if e['b']: deg[e['b']] += 1
    fake = {k for k, v in deg.items() if v == 2 and k != 0}
    if not fake: break
    byn = defaultdict(list)
    for i, e in enumerate(E):
        byn[e['a']].append(i)
        if e['b']: byn[e['b']].append(i)
    used = set(); NE = []
    for nid in fake:
        idx = [i for i in byn.get(nid, []) if i not in used]
        if len(idx) != 2: continue
        i, j = idx
        e1, e2 = E[i], E[j]
        if e1['b'] != nid: e1 = {'a': e1['b'], 'b': e1['a'], 'poly': e1['poly'][::-1]}
        if e2['a'] != nid: e2 = {'a': e2['b'], 'b': e2['a'], 'poly': e2['poly'][::-1]}
        if e1['b'] != nid or e2['a'] != nid: continue
        used.add(i); used.add(j)
        NE.append({'a': e1['a'], 'b': e2['b'], 'poly': e1['poly'] + e2['poly'][1:]})
    for i, e in enumerate(E):
        if i not in used: NE.append(e)
    if len(NE) == len(E): break
    E = NE
deg = defaultdict(int)
for e in E:
    deg[e['a']] += 1
    if e['b']: deg[e['b']] += 1
print(f"  合并后 边 {len(E)}  真节点(度≠2) {sum(1 for v in deg.values() if v != 2)}")

# ── ③ 路口聚类 ──
print("═══ ③ 路口聚类（%.1fpx 内的节点合并）═══" % JUNCTION_MERGE_PX)
ids = sorted(nodes.keys())
used = {}          # 旧 id → 新 id
clusters = []
for nid in ids:
    if nid in used: continue
    x, y = nodes[nid]
    grp = [nid]
    used[nid] = None
    for other in ids:
        if other in used: continue
        ox, oy = nodes[other]
        if math.hypot(ox-x, oy-y) <= JUNCTION_MERGE_PX:
            grp.append(other); used[other] = None
    # 簇坐标 = 质心
    cx = sum(nodes[g][0] for g in grp) / len(grp)
    cy = sum(nodes[g][1] for g in grp) / len(grp)
    nid_new = len(clusters) + 1
    for g in grp: used[g] = nid_new
    clusters.append({'id': nid_new, 'x': round(cx, 1), 'y': round(cy, 1), 'merged': len(grp)})
print(f"  节点 {len(ids)} → {len(clusters)} 个路口")
big = [c for c in clusters if c['merged'] > 1]
print(f"  其中合并了多个原始节点的路口 {len(big)} 个，最大合并 {max((c['merged'] for c in big), default=1)} 个")

# ── ④ 邻接表 ──
print("═══ ④ 建邻接表 ═══")
adj = defaultdict(list)
Eout = []
for i, e in enumerate(E):
    a = used.get(e['a'], 0); b = used.get(e['b'], 0)
    if not a or not b: continue
    poly = e['poly']
    L = sum(math.hypot(poly[k+1][0]-poly[k][0], poly[k+1][1]-poly[k][1])
            for k in range(len(poly)-1))
    if L < 1: continue
    Eout.append({'i': i, 'a': a, 'b': b, 'len_px': round(L, 1),
                 'len_m': round(L*PX_PER_M, 1), 'poly': poly})
    adj[a].append((b, i, L))
    adj[b].append((a, i, L))
print(f"  边 {len(Eout)}   孤立路口(度0) {sum(1 for c in clusters if not adj.get(c['id']))}")

# ── ⑤ Dijkstra 自检 ──
print("═══ ⑤ 寻路自检（Dijkstra）═══")
def dijkstra(src, dst):
    if src == dst: return 0.0, []
    dist = {src: 0.0}; prev = {}
    pq = [(0.0, src)]
    while pq:
        dcur, u = heapq.heappop(pq)
        if dcur > dist.get(u, 1e18): continue
        if u == dst: break
        for v, ei, L in adj.get(u, []):
            nd = dcur + L
            if nd < dist.get(v, 1e18):
                dist[v] = nd; prev[v] = (u, ei)
                heapq.heappush(pq, (nd, v))
    if dst not in dist: return None, []
    path = []; cur = dst
    while cur != src:
        u, ei = prev[cur]; path.append(ei); cur = u
    return dist[dst], path[::-1]

ids_deg = [c['id'] for c in clusters if adj.get(c['id'])]
random.seed(42)
ok = 0; fail = 0; lens = []
for _ in range(200):
    a, b = random.sample(ids_deg, 2)
    L, p = dijkstra(a, b)
    if L is None: fail += 1
    else: ok += 1; lens.append(L*PX_PER_M)
lens.sort()
print(f"  随机 200 对: 可达 {ok}  不可达 {fail}  ({ok/200*100:.1f}%)")
if lens:
    print(f"  路径长度: p50={lens[len(lens)//2]:.0f}m  p90={lens[int(len(lens)*0.9)]:.0f}m  max={lens[-1]:.0f}m")

json.dump({'meta': {'source': IN, 'px_per_m': PX_PER_M,
                    'nodes': len(clusters), 'edges': len(Eout),
                    'reachable_pct': round(ok/200*100, 1),
                    'junction_merge_px': JUNCTION_MERGE_PX},
           'nodes': clusters,
           'edges': Eout}, open(OUT, 'w'))
print(f"\n  ✓ {OUT}")
