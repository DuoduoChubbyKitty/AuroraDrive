#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补充实测：k短路 + 检查点排序(TSP) + 预计算加速(路标ALT)"""
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

def h(a, b): return math.hypot(N[a]['x']-N[b]['x'], N[a]['y']-N[b]['y'])*0.61

def dijkstra(s, t):
    g={s:0.0}; pq=[(0.0,s)]; done=set()
    while pq:
        du,u=heapq.heappop(pq)
        if u in done: continue
        done.add(u)
        if u==t: return du
        for v,w in adj[u]:
            if v not in done and du+w < g.get(v,1e18):
                g[v]=du+w; heapq.heappush(pq,(du+w,v))
    return None

# ── ① k 短路 (Yen) ──
def yen(s,t,K=3):
    first=[]
    g={s:0.0}; pq=[(0.0,s)]; prev={}
    while pq:
        du,u=heapq.heappop(pq)
        if du>g.get(u,1e18): continue
        if u==t:
            p=[t]
            while p[-1]!=s: p.append(prev[p[-1]])
            first.append(p[::-1]); break
        for v,w in adj[u]:
            if du+w<g.get(v,1e18):
                g[v]=du+w; prev[v]=u; heapq.heappush(pq,(du+w,v))
    if not first: return []
    A=[first[0]]
    for _ in range(K-1):
        for i in range(len(A[-1])-1):
            root=A[-1][:i+1]; spur=A[-1][i]
            rm=set()
            for p in A:
                if p[:i+1]==root: rm.add((p[i],p[i+1]))
            g={spur:0.0}; pq=[(0.0,spur)]; prev={}
            while pq:
                du,u=heapq.heappop(pq)
                if du>g.get(u,1e18): continue
                if u==t:
                    sp=[t]
                    while sp[-1]!=spur: sp.append(prev[sp[-1]])
                    A.append(root[:-1]+sp[::-1]); break
                for v,w in adj[u]:
                    if (u,v) in rm: continue
                    if du+w<g.get(v,1e18):
                        g[v]=du+w; prev[v]=u; heapq.heappush(pq,(du+w,v))
        A.sort(key=lambda p: sum(next(w for x,w in adj[p[k]] if x==p[k+1]) for k in range(len(p)-1)))
        A=A[:K]
    return A

random.seed(3)
pairs=[(random.choice(ids),random.choice(ids)) for _ in range(50)]
pairs=[(a,b) for a,b in pairs if a!=b]
t0=time.perf_counter()
for s,t in pairs: yen(s,t,3)
t_yen=(time.perf_counter()-t0)/len(pairs)*1000
print(f'① k短路 Yen(K=3):  中位 {t_yen:.2f} ms/次')

# ── ② 检查点排序 TSP ──
def tsp_nn2opt(pts, iters=200):
    n=len(pts)
    D=[[math.hypot(N[a]['x']-N[b]['x'],N[a]['y']-N[b]['y'])*0.61 for b in pts] for a in pts]
    order=list(range(n)); cur=order[:]
    best=[0]+list(range(1,n)); bl=sum(D[best[i]][best[i+1]] for i in range(n-1))
    for it in range(iters):
        i,j=sorted(random.sample(range(1,n),2))
        cur=best[:i]+best[i:j+1][::-1]+best[j+1:]
        l=sum(D[cur[k]][cur[k+1]] for k in range(n-1))
        if l<bl: best,bl=cur,l
    return bl

for k in (5,10,20):
    t0=time.perf_counter()
    for _ in range(20):
        pts=random.sample(ids,k)
        tsp_nn2opt(pts,200)
    print(f'    TSP {k:>2d} 点 (NN+2opt): 中位 {(time.perf_counter()-t0)/20*1000:.1f} ms')

# ── ③ ALT 路标预计算 ──
print()
print('③ 路标(ALT)预计算成本：')
for L in (8,16,32):
    lm=random.sample(ids,L)
    t0=time.perf_counter()
    dists=[]
    for l in lm:
        g={l:0.0}; pq=[(0.0,l)]
        while pq:
            du,u=heapq.heappop(pq)
            if du>g.get(u,1e18): continue
            for v,w in adj[u]:
                if du+w<g.get(v,1e18):
                    g[v]=du+w; heapq.heappush(pq,(du+w,v))
        dists.append(g)
    dt=time.perf_counter()-t0
    print(f'    路标 {L:>2d} 个: 预计算 {dt:.2f}s  内存约 {L*len(N)*8/1024:.0f} KB')

lm=random.sample(ids,16)
dists=[]
for l in lm:
    g={l:0.0}; pq=[(0.0,l)]
    while pq:
        du,u=heapq.heappop(pq)
        if du>g.get(u,1e18): continue
        for v,w in adj[u]:
            if du+w<g.get(v,1e18):
                g[v]=du+w; heapq.heappush(pq,(du+w,v))
    dists.append(g)

def halt_lb(u,t):
    return max(abs(dists[i].get(u,1e18)-dists[i].get(t,1e18)) for i in range(len(lm)))

def astar_alt(s,t):
    g={s:0.0}; f={s:halt_lb(s,t)}
    pq=[(f[s],s)]; closed=set()
    while pq:
        _,u=heapq.heappop(pq)
        if u in closed: continue
        closed.add(u)
        if u==t: return g[u],len(closed)
        for v,w in adj[u]:
            ng=g[u]+w
            if ng<g.get(v,1e18):
                g[v]=ng; f[v]=ng+halt_lb(v,t)
                heapq.heappush(pq,(f[v],v))
    return None,len(closed)

ts=[];ex=[]
for s,t in pairs:
    a=time.perf_counter(); r=astar_alt(s,t); ts.append((time.perf_counter()-a)*1000); ex.append(r[1])
ts.sort()
print(f'    A*+ALT(16路标): 中位 {ts[len(ts)//2]:.3f} ms  平均展开 {sum(ex)/len(ex):.0f} 个节点')
