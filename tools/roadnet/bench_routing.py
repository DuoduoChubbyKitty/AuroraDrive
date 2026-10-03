#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 V5 矢量图上实测几种寻路算法的性能与最优性"""
import json, math, heapq, random, time
from collections import defaultdict, deque

d = json.load(open('tools/roadnet/v5_graph.json'))
N = {n['id']: n for n in d['nodes']}
M_PER_PX = d['meta']['m_per_px']

adj = defaultdict(list)
for e in d['edges']:
    w = e['len_m']
    adj[e['a']].append((e['b'], w, e))
    adj[e['b']].append((e['a'], w, e))

def h(a, b):
    return math.hypot(N[a]['x'] - N[b]['x'], N[a]['y'] - N[b]['y']) * M_PER_PX

def astar(s, t, weight=1.0):
    g = {s: 0.0}; f = {s: h(s, t) * weight}
    pq = [(f[s], s)]; closed = set(); prev = {}
    while pq:
        _, u = heapq.heappop(pq)
        if u in closed: continue
        closed.add(u)
        if u == t: break
        for v, w, _ in adj[u]:
            ng = g[u] + w
            if ng < g.get(v, 1e18):
                g[v] = ng; prev[v] = u
                f[v] = ng + h(v, t) * weight
                heapq.heappush(pq, (f[v], v))
    return g.get(t), prev, len(closed)

def dijkstra(s, t):
    g = {s: 0.0}; pq = [(0.0, s)]; done = set(); prev = {}
    while pq:
        du, u = heapq.heappop(pq)
        if u in done: continue
        done.add(u)
        if u == t: break
        for v, w, _ in adj[u]:
            nd = du + w
            if nd < g.get(v, 1e18):
                g[v] = nd; prev[v] = u
                heapq.heappush(pq, (nd, v))
    return g.get(t), prev, len(done)

def bfs(s, t):
    q = deque([s]); prev = {s: None}; seen = {s}
    while q:
        u = q.popleft()
        if u == t: break
        for v, _, _ in adj[u]:
            if v not in seen:
                seen.add(v); prev[v] = u; q.append(v)
    return (0 if t in seen else None), prev, len(seen)

def bidij(s, t):
    gf = {s: 0.0}; gb = {t: 0.0}
    pf = [(0.0, s)]; pb = [(0.0, t)]
    df = set(); db = set(); prevf = {}; prevb = {}
    best = 1e18
    while pf or pb:
        if pf:
            du, u = heapq.heappop(pf)
            if u not in df:
                df.add(u)
                for v, w, _ in adj[u]:
                    nd = du + w
                    if nd < gf.get(v, 1e18):
                        gf[v] = nd; prevf[v] = u; heapq.heappush(pf, (nd, v))
        if pb:
            du, u = heapq.heappop(pb)
            if u not in db:
                db.add(u)
                for v, w, _ in adj[u]:
                    nd = du + w
                    if nd < gb.get(v, 1e18):
                        gb[v] = nd; prevb[v] = u; heapq.heappush(pb, (nd, v))
        for u in df:
            if u in gb:
                best = min(best, gf[u] + gb[u])
        if best < 1e18 and pf and pb and pf[0][0] + pb[0][0] >= best:
            break
    return best if best < 1e18 else None, len(df) + len(db)

def bidastar(s, t):
    gf = {s: 0.0}; gb = {t: 0.0}
    pf = [(h(s, t), s)]; pb = [(0.0, t)]
    df = set(); db = set(); prevf = {}; prevb = {}
    best = 1e18; expanded = 0
    while pf and pb:
        if pf[0][0] < pb[0][0]:
            _, u = heapq.heappop(pf)
            if u in df: continue
            df.add(u); expanded += 1
            for v, w, _ in adj[u]:
                nd = gf[u] + w
                if nd < gf.get(v, 1e18):
                    gf[v] = nd; prevf[v] = u
                    heapq.heappush(pf, (nd + h(v, t), v))
        else:
            _, u = heapq.heappop(pb)
            if u in db: continue
            db.add(u); expanded += 1
            for v, w, _ in adj[u]:
                nd = gb[u] + w
                if nd < gb.get(v, 1e18):
                    gb[v] = nd; prevb[v] = u
                    heapq.heappush(pb, (nd + h(v, s), v))
        for u in (df & set(gb)):
            best = min(best, gf[u] + gb[u])
        if best < 1e18 and pf and pb and pf[0][0] + pb[0][0] >= best:
            break
    return best if best < 1e18 else None, expanded

random.seed(11)
ids = list(N)
pairs = []
while len(pairs) < 300:
    a, b = random.choice(ids), random.choice(ids)
    if a != b and abs(N[a]['x'] - N[b]['x']) + abs(N[a]['y'] - N[b]['y']) > 2000:
        pairs.append((a, b))

print(f'图: 节点 {len(N)}  边 {sum(len(v) for v in adj.values())//2}')
print(f'采样 {len(pairs)} 对相距较远的起终点')
print()
print(f'{"算法":<22} {"中位耗时":>10} {"P95耗时":>10} {"平均展开":>10} {"路径长中位":>12} {"最优性":>8}')
print('-' * 78)

# 统一测：每个算法返回 (dist, expanded)
def run(name, fn, has_expanded=True):
    ts = []; exps = []; ds = []
    for s, t in pairs:
        a = time.perf_counter()
        r = fn(s, t)
        ts.append((time.perf_counter() - a) * 1000)
        dist, prev, exp = r
        exps.append(exp)
        ds.append(dist)
    ts.sort()
    ts_sorted = ts
    med = ts_sorted[len(ts_sorted)//2]
    p95 = ts_sorted[int(len(ts_sorted)*0.95)]
    valid = [x for x in ds if x is not None]
    print(f'{name:<22} {med:>8.2f}ms {p95:>8.2f}ms {sum(exps)/len(exps):>10.1f} '
          f'{sum(valid)/len(valid):>10.0f}m {len(valid)}/{len(ds)}')
    return valid

# 参考最优解
print('先算 Dijkstra 作基准…')
base = run('Dijkstra (基准)', dijkstra)

print()
for name, fn in (('BFS (跳数最少)', bfs),
                 ('双向 Dijkstra', bidij),
                 ('双向 A*', bidastar)):
    ts = []; exps = []; ds = []
    for s, t in pairs:
        a = time.perf_counter()
        r = fn(s, t)
        ts.append((time.perf_counter() - a) * 1000)
        if name.startswith('双向'):
            dist, exp = r
        else:
            dist, prev, exp = r
        exps.append(exp); ds.append(dist)
    ts.sort()
    med = ts[len(ts)//2]; p95 = ts[int(len(ts)*0.95)]
    valid = [x for x in ds if x is not None]
    print(f'{name:<22} {med:>8.2f}ms {p95:>8.2f}ms {sum(exps)/len(exps):>10.1f} '
          f'{sum(valid)/len(valid):>10.0f}m {len(valid)}/{len(ds)}')

# A* 权重对比（次优性）
print()
print('A* 启发权重 → 速度/最优性权衡：')
for wgt in (1.0, 1.05, 1.2, 1.5, 2.0):
    ts = []; exps = []; devs = []
    for s, t in pairs:
        a = time.perf_counter()
        dist, prev, exp = astar(s, t, wgt)
        ts.append((time.perf_counter() - a) * 1000)
        exps.append(exp)
        di, _, _ = dijkstra(s, t)
        if dist and di:
            devs.append((dist - di) / di * 100)
    ts.sort()
    print(f'  w={wgt:<4} 中位 {ts[len(ts)//2]:>6.2f}ms  展开 {sum(exps)/len(exps):>6.1f}  '
          f'比最优长 {sum(devs)/len(devs):>5.2f}%')
