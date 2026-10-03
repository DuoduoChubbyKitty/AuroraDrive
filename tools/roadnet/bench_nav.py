#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导航实际场景实测：POI 吸附 / 最近 POI / 实时重规划 / 全图最短路"""
import json, math, heapq, random, time
from collections import defaultdict
import numpy as np

d = json.load(open('tools/roadnet/v5_graph.json'))
N = {n['id']: n for n in d['nodes']}
adj = defaultdict(list)
for e in d['edges']:
    adj[e['a']].append((e['b'], e['len_m']))
    adj[e['b']].append((e['a'], e['len_m']))
ids = list(N)
pois = json.load(open('/tmp/poi_13056.json'))
print(f'图 节点{len(N)} 边{sum(len(v) for v in adj.values())//2}   POI {len(pois)} 个')

# ── ① POI 吸附到最近边（navmesh 挂载）──
node_xy = np.array([[N[i]['x'], N[i]['y']] for i in sorted(N)], np.float64)
edge_seg = []
for e in d['edges']:
    p = e['poly']
    for k in range(len(p)-1):
        edge_seg.append((p[k][0], p[k][1], p[k+1][0], p[k+1][1], e['a'], e['b']))
SEG = np.array([[s[0], s[1], s[2], s[3]] for s in edge_seg], np.float64)
print(f'边折线段 {len(SEG)}')

def snap_batch(pts):
    """向量化：每个点找最近的折线段"""
    P = np.array(pts, np.float64)
    A = SEG[:, :2]; B = SEG[:, 2:4]
    AB = B - A
    L2 = (AB**2).sum(1); L2[L2 == 0] = 1e-9
    out = []
    for p in P:
        AP = p - A
        t = np.clip((AP*AB).sum(1)/L2, 0, 1)
        proj = A + t[:, None]*AB
        dd = ((proj - p)**2).sum(1)
        j = int(np.argmin(dd))
        out.append((math.sqrt(dd[j]), j, float(t[j])))
    return out

random.seed(5)
sample = random.sample(pois, 200)
t0 = time.perf_counter(); snap_batch([(p['x'], p['y']) for p in sample]); dt = time.perf_counter()-t0
print(f'① POI 吸附(200个): {dt*1000:.0f} ms  → 单个 {dt/200*1000:.2f} ms')
res = snap_batch([(p['x'], p['y']) for p in pois])
print(f'   1622 个全吸附: {sum(1 for r in res if r[0]<50)/len(res)*100:.1f}% 在 50px(30m) 内, '
      f'中位距离 {sorted(r[0] for r in res)[len(res)//2]:.0f}px = {sorted(r[0] for r in res)[len(res)//2]*0.61:.0f}m')

# ── ② 最近 POI 查询 ──
POIXY = np.array([[p['x'], p['y']] for p in pois], np.float64)
qs = random.sample(pois, 100)
t0 = time.perf_counter()
for p in qs:
    dd = ((POIXY - np.array([p['x'], p['y']]))**2).sum(1)
    k = np.argpartition(dd, 5)[:5]
print(f'② 最近5个POI查询(暴力): {(time.perf_counter()-t0)/100*1000:.3f} ms/次')

# ── ③ Dijkstra 全图最短路（一次到所有点）──
t0 = time.perf_counter()
for _ in range(20):
    s = random.choice(ids)
    g = {s: 0.0}; pq = [(0.0, s)]
    while pq:
        du, u = heapq.heappop(pq)
        if du > g.get(u, 1e18): continue
        for v, w in adj[u]:
            if du+w < g.get(v, 1e18):
                g[v] = du+w; heapq.heappush(pq, (du+w, v))
print(f'③ 单源全图最短路(612点): {(time.perf_counter()-t0)/20*1000:.2f} ms/次')

# ── ④ 实时重规划：堵一条边后重算 ──
def dij(s, t, ban=None):
    g = {s: 0.0}; pq = [(0.0, s)]
    while pq:
        du, u = heapq.heappop(pq)
        if du > g.get(u, 1e18): continue
        if u == t: return du
        for v, w in adj[u]:
            if ban and ((u, v) == ban or (v, u) == ban): continue
            if du+w < g.get(v, 1e18):
                g[v] = du+w; heapq.heappush(pq, (du+w, v))
    return None

pairs = [(random.choice(ids), random.choice(ids)) for _ in range(100)]
pairs = [(a, b) for a, b in pairs if a != b]
t0 = time.perf_counter()
base = [dij(a, b) for a, b in pairs]
print(f'④ 100 条路径规划: {(time.perf_counter()-t0)*1000:.0f} ms  ({(time.perf_counter()-t0)*1000/100:.2f} ms/条)')
# 随机堵边重算
blocked = random.sample([(e['a'], e['b']) for e in d['edges']], 50)
t0 = time.perf_counter()
ok = 0
for (a, b) in pairs[:50]:
    r = dij(a, b, ban=random.choice(blocked))
    if r: ok += 1
print(f'   堵边后重算 50 条: {(time.perf_counter()-t0)*1000:.0f} ms  仍可达 {ok}/50')
