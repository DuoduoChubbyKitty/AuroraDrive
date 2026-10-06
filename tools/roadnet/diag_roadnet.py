#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
diag_roadnet.py —— 路网完整体检：断头分类 + 重复边 + 孤线 + 锐角

输出 /tmp/roadnet_diag/report.json + 控制台摘要
"""
import json, os, math, collections

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
OUT = "/tmp/roadnet_diag"
os.makedirs(OUT, exist_ok=True)

d = json.load(open(f"{ROOT}/models/route_graph.json", encoding="utf-8"))
M_PER_PX = d["meta"]["m_per_px"]
nodes = {n[0]: (n[1], n[2]) for n in d["nodes"]}
edges = d["edges"]           # [a, b, len, poly]

def dist(p, q):
    return math.hypot(p[0]-q[0], p[1]-q[1])

# ---------- 1. 度数 ----------
deg = collections.Counter()
inc = collections.defaultdict(list)
for i, e in enumerate(edges):
    deg[e[0]] += 1; deg[e[1]] += 1
    inc[e[0]].append(i); inc[e[1]].append(i)

dangling = [n for n, k in deg.items() if k == 1]
print("=" * 72)
print("  1. 断头端点（度=1）: %d 个" % len(dangling))
print("=" * 72)

# ---------- 2. 每个断头：到最近「非自身边」的距离 ----------
def seg_point_dist(p, a, b):
    """点到线段距离"""
    ax, ay = a; bx, by = b
    dx, dy = bx-ax, by-ay
    L2 = dx*dx + dy*dy
    if L2 == 0: return dist(p, a), 0.0
    t = max(0.0, min(1.0, ((p[0]-ax)*dx + (p[1]-ay)*dy) / L2))
    proj = (ax + t*dx, ay + t*dy)
    return dist(p, proj), t

def poly_dist(p, poly):
    best = (1e18, None)
    for k in range(len(poly)-1):
        dd, t = seg_point_dist(p, poly[k], poly[k+1])
        if dd < best[0]: best = (dd, k)
    return best

# 建立边索引加速：只用包围盒筛
bbox = []
for e in edges:
    poly = e[3]
    xs = [q[0] for q in poly]; ys = [q[1] for q in poly]
    bbox.append((min(xs), min(ys), max(xs), max(ys)))

results = []
for n in dangling:
    p = nodes[n]
    own = set(inc[n])
    best = (1e18, None, None)
    for i, e in enumerate(edges):
        if i in own: continue
        bx0, by0, bx1, by1 = bbox[i]
        # 包围盒粗筛（放宽 5px）
        if p[0] < bx0-5 or p[0] > bx1+5 or p[1] < by0-5 or p[1] > by1+5: continue
        dd, k = poly_dist(p, e[3])
        if dd < best[0]: best = (dd, i, k)
    results.append(dict(node=n, x=p[0], y=p[1], near_edge=best[1],
                        near_dist_px=best[0], near_dist_m=best[0]*M_PER_PX,
                        own_edges=sorted(own)))

results.sort(key=lambda r: r["near_dist_px"])
print("\n最近的 20 个断头：")
print("%-6s %-10s %-10s %-10s %s" % ("节点","x","y","距最近路(m)","判定"))
for r in results[:20]:
    dm = r["near_dist_m"]
    verdict = "✅ 可吸附(<5m)" if dm < 5 else ("⚠️ 中等(5~30m)" if dm < 30 else "❌ 偏远(>30m)")
    print("%-6d %-10.0f %-10.0f %-10.1f %s" % (r["node"], r["x"], r["y"], dm, verdict))

print("\n距离分布：")
buckets = collections.Counter()
for r in results:
    dm = r["near_dist_m"]
    if dm < 1: buckets["<1m"] += 1
    elif dm < 5: buckets["1~5m"] += 1
    elif dm < 15: buckets["5~15m"] += 1
    elif dm < 30: buckets["15~30m"] += 1
    elif dm < 100: buckets["30~100m"] += 1
    else: buckets[">100m"] += 1
for k in ["<1m","1~5m","5~15m","15~30m","30~100m",">100m"]:
    if buckets[k]: print("  %-10s %d" % (k, buckets[k]))

# ---------- 3. 重复边（同两端点）----------
print()
print("=" * 72)
print("  2. 重复边（同一对端点之间有多条边）")
print("=" * 72)
pair = collections.Counter()
for e in edges:
    k = tuple(sorted((e[0], e[1])))
    pair[k] += 1
dup = {k: v for k, v in pair.items() if v > 1}
print("  重复端点对数: %d" % len(dup))
for k, v in list(dup.items())[:10]:
    Ls = [e[2] for e in edges if tuple(sorted((e[0], e[1]))) == k]
    print("    %s × %d  边长=%s" % (k, v, [round(x) for x in Ls]))

# ---------- 4. 零长/极短边 ----------
print()
print("=" * 72)
print("  3. 极短边（可能是碎片）")
print("=" * 72)
short = [(i, e) for i, e in enumerate(edges) if e[2] < 5]
print("  长度 < 5m 的边: %d" % len(short))
for i, e in short[:10]:
    print("    边%d  %d→%d  %.1fm  poly点=%d" % (i, e[0], e[1], e[2], len(e[3])))

# ---------- 5. 折线自交 / 回折（一条路伸两个出口的嫌疑）----------
print()
print("=" * 72)
print("  4. 边的折线是否原地打转（首尾接近但路径很长）")
print("=" * 72)
weird = []
for i, e in enumerate(edges):
    poly = e[3]
    if len(poly) < 3: continue
    straight = dist(poly[0], poly[-1])
    if straight < 1e-6:
        weird.append((i, e, "首尾重合"))
    elif e[2] > 3 * straight * M_PER_PX and e[2] > 50:
        weird.append((i, e, "绕行比%.1f" % (e[2] / (straight * M_PER_PX))))
print("  可疑边: %d" % len(weird))
for i, e, why in weird[:12]:
    print("    边%-4d %d→%d  %.0fm  %s" % (i, e[0], e[1], e[2], why))

# ---------- 6. 锐角（一条路突然拐弯 > 120°）----------
print()
print("=" * 72)
print("  5. 急弯（相邻折线段夹角 > 120°）")
print("=" * 72)
sharp = 0
worst = []
for i, e in enumerate(edges):
    poly = e[3]
    for k in range(1, len(poly)-1):
        a, b, c = poly[k-1], poly[k], poly[k+1]
        v1 = (b[0]-a[0], b[1]-a[1]); v2 = (c[0]-b[0], c[1]-b[1])
        n1 = math.hypot(*v1); n2 = math.hypot(*v2)
        if n1 < 1e-6 or n2 < 1e-6: continue
        cosv = max(-1, min(1, (v1[0]*v2[0]+v1[1]*v2[1])/(n1*n2)))
        ang = math.degrees(math.acos(cosv))
        if ang > 120:
            sharp += 1
            worst.append((ang, i, k, b))
worst.sort(reverse=True)
print("  急弯点: %d" % sharp)
for ang, i, k, b in worst[:10]:
    print("    边%-4d 点%d  夹角%.0f°  位置(%.0f, %.0f)" % (i, k, ang, b[0], b[1]))

# ---------- 保存 ----------
json.dump(dict(
    dangling=results,
    dup_pairs={str(k): v for k, v in dup.items()},
    short_edges=len(short),
    weird_edges=[dict(edge=i, a=e[0], b=e[1], len=e[2], why=w) for i, e, w in weird],
    sharp_count=sharp,
), open(f"{OUT}/report.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print()
print("报告已存: %s/report.json" % OUT)
