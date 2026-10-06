#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fix_roadnet.py —— 路网修复（断头吸附 + 分叉合并 + 重复边 + 自环 + 加粗）

修复策略（保守，只修该修的）：
  1. 自环边（a==b）→ 删
  2. 极短边（<2m 且首尾同点）→ 删
  3. 断头吸附：度=1 且距最近路 < ADSORB_MAX_M 的端点 → 沿原方向延伸并吸附
     ⚠️ 距离 > FAR_KEEP_M 的断头一律**保留**（用户明确说：那是之后的地图）
  4. 分叉合并：两个度=1 节点连到同一个度>=3 节点，且两点很近 → 合并成一条边
  5. 重复边：同一对端点、长度接近（比值 0.8~1.25）→ 保留长的，删短的

输出: models/route_graph_fixed.json（不覆盖原文件）
      models/route_graph_fixed_diag.json（修复明细）
"""
import json, os, math, collections, sys

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
SRC  = f"{ROOT}/models/route_graph.json"
DST  = f"{ROOT}/models/route_graph_fixed.json"
DIAG = f"{ROOT}/models/route_graph_fixed_diag.json"

ADSORB_MAX_M = 30.0     # 断头吸附上限（米）
FAR_KEEP_M   = 100.0    # 超过这个距离的断头 = 之后的地图，保留
MERGE_DUP_RATIO = (0.8, 1.25)   # 重复边长度比区间
MIN_EDGE_M   = 2.0      # 短于此且首尾同点 → 删

d = json.load(open(SRC, encoding="utf-8"))
M_PER_PX = d["meta"]["m_per_px"]
print("原始: 节点 %d  边 %d  (%.3f m/px)" % (len(d["nodes"]), len(d["edges"]), M_PER_PX))

nodes = {n[0]: [n[1], n[2]] for n in d["nodes"]}    # id -> [x,y]
edges = [dict(a=e[0], b=e[1], len=e[2], poly=[list(p) for p in e[3]]) for e in d["edges"]]

diag = dict(removed_selfloop=[], removed_short=[], adsorbed=[], merged_fork=[],
            removed_dup=[], kept_far=[])

def dist(p, q): return math.hypot(p[0]-q[0], p[1]-q[1])

def seg_point_dist(p, a, b):
    ax, ay = a; bx, by = b
    dx, dy = bx-ax, by-ay
    L2 = dx*dx + dy*dy
    if L2 == 0: return dist(p, a), 0.0
    t = max(0.0, min(1.0, ((p[0]-ax)*dx + (p[1]-ay)*dy) / L2))
    return dist(p, (ax+t*dx, ay+t*dy)), t

# ── 1. 删自环 / 极短边 ──
keep = []
for i, e in enumerate(edges):
    if e["a"] == e["b"]:
        diag["removed_selfloop"].append(dict(idx=i, node=e["a"], len_m=e["len"]))
        continue
    if e["len"] < MIN_EDGE_M and dist(e["poly"][0], e["poly"][-1]) < 1e-6:
        diag["removed_short"].append(dict(idx=i, a=e["a"], b=e["b"], len_m=e["len"]))
        continue
    keep.append(e)
edges = keep
print("删自环 %d, 删极短 %d → 剩 %d 边" % (
    len(diag["removed_selfloop"]), len(diag["removed_short"]), len(edges)))

# ── 2. 重复边 ──
pair = collections.defaultdict(list)
for i, e in enumerate(edges):
    pair[tuple(sorted((e["a"], e["b"])))].append(i)
drop = set()
for k, idxs in pair.items():
    if len(idxs) < 2: continue
    lens = [edges[i]["len"] for i in idxs]
    lo, hi = min(lens), max(lens)
    if lo > 0 and MERGE_DUP_RATIO[0] <= lo/hi <= MERGE_DUP_RATIO[1]:
        # 长度接近 → 判重复，保留最长的
        keep_i = idxs[lens.index(hi)]
        for i in idxs:
            if i != keep_i:
                drop.add(i)
                diag["removed_dup"].append(dict(idx=i, a=edges[i]["a"], b=edges[i]["b"],
                                                len_m=edges[i]["len"], kept_len_m=hi))
edges = [e for i, e in enumerate(edges) if i not in drop]
print("删重复边 %d → 剩 %d 边" % (len(diag["removed_dup"]), len(edges)))

# ── 3. 分叉合并：两个度=1 节点连到同一个度>=3 节点 ──
def build_deg():
    dg = collections.Counter(); inc = collections.defaultdict(list)
    for i, e in enumerate(edges):
        dg[e["a"]] += 1; dg[e["b"]] += 1
        inc[e["a"]].append(i); inc[e["b"]].append(i)
    return dg, inc
deg, inc = build_deg()

forks = 0
used = set()
for hub, idxs in list(inc.items()):
    if deg[hub] < 3: continue
    leaves = []
    for i in idxs:
        e = edges[i]
        other = e["b"] if e["a"] == hub else e["a"]
        if deg[other] == 1: leaves.append((i, other))
    if len(leaves) < 2: continue
    # 两两配对：叶子之间距离 < ADSORB_MAX_M 才合并
    for x in range(len(leaves)):
        for y in range(x+1, len(leaves)):
            i1, n1 = leaves[x]; i2, n2 = leaves[y]
            if n1 in used or n2 in used: continue
            p1, p2 = nodes[n1], nodes[n2]
            if dist(p1, p2) * M_PER_PX > ADSORB_MAX_M: continue
            # 合并：删掉两条叶子边，加一条 n1->n2 的边（把两条折线接起来）
            e1, e2 = edges[i1], edges[i2]
            poly1 = e1["poly"] if e1["a"] == n1 else list(reversed(e1["poly"]))
            poly2 = e2["poly"] if e2["b"] == n2 else list(reversed(e2["poly"]))
            # poly1: n1→hub ; poly2: hub→n2  → 合成 n1→n2
            newpoly = poly1 + poly2[1:]
            L = sum(dist(newpoly[k], newpoly[k+1]) for k in range(len(newpoly)-1)) * M_PER_PX
            edges.append(dict(a=n1, b=n2, len=L, poly=newpoly))
            used.add(n1); used.add(n2)
            diag["merged_fork"].append(dict(hub=hub, leaf1=n1, leaf2=n2,
                                            dist_m=dist(p1, p2)*M_PER_PX, new_len_m=L))
            forks += 1
print("分叉合并 %d 处" % forks)

# 重建（分叉合并会引入新边，需要重算度数再吸附）
deg, inc = build_deg()

# ── 4. 断头吸附（真正的拓扑连接：在目标边上切开并插入节点）──
def nearest_road(p, own_idx):
    best = (1e18, None, None, None)
    for i, e in enumerate(edges):
        if i in own_idx: continue
        poly = e["poly"]
        for k in range(len(poly)-1):
            dd, t = seg_point_dist(p, poly[k], poly[k+1])
            if dd < best[0]: best = (dd, i, k, t)
    return best

def poly_len(poly):
    return sum(dist(poly[k], poly[k+1]) for k in range(len(poly)-1)) * M_PER_PX

dangling = [n for n, k in deg.items() if k == 1]
print("当前断头 %d 个，开始吸附（阈值 %.0fm，>%.0fm 保留）" % (len(dangling), ADSORB_MAX_M, FAR_KEEP_M))

# ⚠️ 2026-10-06 修复：吸附会在目标边上切开并插入新节点，
#    新节点本身可能又是度=1（新边的一端）→ 必须**迭代到收敛**。
#    原实现只跑一轮，导致 26 个「距离≈0 但没连上」的残留断头。
adsorbed = 0
next_nid = max(nodes.keys()) + 1
for round_no in range(1, 11):
    deg, inc = build_deg()
    dangling = sorted(n for n, k in deg.items() if k == 1)
    if not dangling:
        print("  第 %d 轮：无断头，收敛" % round_no)
        break
    round_ads = 0
    for n in dangling:
        p = nodes[n]
        own = set(inc[n])
        dd, ei, seg_k, t = nearest_road(p, own)
        dm = dd * M_PER_PX
        if ei is None: continue
        if dm > ADSORB_MAX_M:
            if round_no == 1:
                diag["kept_far"].append(dict(node=n, x=p[0], y=p[1], dist_m=dm,
                                             reason="远端(之后的地图)" if dm > FAR_KEEP_M else ">吸附阈值"))
            continue

        target = edges[ei]
        tp = target["poly"]
        q = [tp[seg_k][0] + t*(tp[seg_k+1][0]-tp[seg_k][0]),
             tp[seg_k][1] + t*(tp[seg_k+1][1]-tp[seg_k][1])]

        # ① 叶子边端点移到落点
        for i in own:
            e = edges[i]
            if e["a"] == n: e["poly"][0] = list(q)
            else:           e["poly"][-1] = list(q)
            e["len"] = poly_len(e["poly"])

        # ② 在目标边上切开，建立真正的拓扑连接
        at_vertex = (dist(q, tp[seg_k]) < 0.5) or (dist(q, tp[seg_k+1]) < 0.5)
        if at_vertex:
            v = seg_k if dist(q, tp[seg_k]) < 0.5 else seg_k+1
            hit = None
            for nid, (nx, ny) in nodes.items():
                if abs(nx - tp[v][0]) < 0.5 and abs(ny - tp[v][1]) < 0.5:
                    hit = nid; break
            if hit is None:
                hit = next_nid; next_nid += 1
                nodes[hit] = list(tp[v])
            L = dist(nodes[n], nodes[hit]) * M_PER_PX
            edges.append(dict(a=n, b=hit, len=L, poly=[list(nodes[n]), list(nodes[hit])]))
            diag["adsorbed"].append(dict(round=round_no, node=n, dist_m=dm, to_edge=ei, mode="vertex", hub=hit))
        else:
            a0, b0 = target["a"], target["b"]
            left = tp[:seg_k+1] + [list(q)]
            right = [list(q)] + tp[seg_k+1:]
            nid = next_nid; next_nid += 1
            nodes[nid] = list(q)
            # 保留原方向
            if dist(left[0], nodes.get(a0, left[0])) <= dist(left[0], nodes.get(b0, left[0])):
                target["poly"] = left; target["b"] = nid; other_end = b0
            else:
                target["poly"] = list(reversed(left))
                target["a"], target["b"] = b0, nid; other_end = a0
            target["len"] = poly_len(target["poly"])
            rp = right if target["a"] == a0 else list(reversed(right))
            edges.append(dict(a=nid, b=other_end, len=poly_len(rp), poly=rp))
            L = dist(nodes[n], nodes[nid]) * M_PER_PX
            edges.append(dict(a=n, b=nid, len=L, poly=[list(nodes[n]), list(nodes[nid])]))
            diag["adsorbed"].append(dict(round=round_no, node=n, dist_m=dm, to_edge=ei, mode="split", new_node=nid))
        adsorbed += 1
        round_ads += 1
    print("  第 %d 轮：断头 %d → 吸附 %d" % (round_no, len(dangling), round_ads))
    if round_ads == 0:
        print("  收敛（无可吸附项）")
        break

print("吸附 %d 个断头（迭代收敛），保留 %d 个远端断头（之后的地图）" % (adsorbed, len(diag["kept_far"])))

# ── 输出 ──
out = dict(
    meta=dict(d["meta"], fixed_by="tools/roadnet/fix_roadnet.py",
              fixed_at="2026-10-06",
              policy="断头吸附<%.0fm；>%.0fm 保留(之后的地图)；自环/重复边删除" % (ADSORB_MAX_M, FAR_KEEP_M)),
    nodes=[[n, nodes[n][0], nodes[n][1]] for n in sorted(nodes)],
    edges=[[e["a"], e["b"], e["len"], e["poly"]] for e in edges],
)
json.dump(out, open(DST, "w", encoding="utf-8"), ensure_ascii=False)
json.dump(diag, open(DIAG, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

print()
print("=" * 60)
print("  修复汇总")
print("=" * 60)
print("  原: 节点 %d  边 %d" % (len(d["nodes"]), len(d["edges"])))
print("  新: 节点 %d  边 %d" % (len(out["nodes"]), len(out["edges"])))
print("  删自环      %d" % len(diag["removed_selfloop"]))
print("  删极短边    %d" % len(diag["removed_short"]))
print("  删重复边    %d" % len(diag["removed_dup"]))
print("  分叉合并    %d" % len(diag["merged_fork"]))
print("  断头吸附    %d" % len(diag["adsorbed"]))
print("  保留远端    %d  ← 之后的地图，不动" % len(diag["kept_far"]))
print()
print("  输出: %s" % DST)
print("  明细: %s" % DIAG)
