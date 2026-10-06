#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 1c：坐标系交叉验证
把 DT_TeleportPoint.json 的世界坐标代入换算，检查落到哪张地图范围内。
同时用 models/map_locations.json（1777 条 world+map 双坐标）反解公式符号。
"""
import json, math, os, sys

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
A  = 0.016394586684750773
B  = 5.693519256055879e-08
TX = 6526.474380746091
TY = 5210.664390686138

SIZES = [11264, 13056, 22528, 26112]

def f_swift(wx, wy):      # Swift: x = a*x - b*y + tx ; y = b*x + a*y + ty
    return (A*wx - B*wy + TX, B*wx + A*wy + TY)

def f_doc(wx, wy):        # map_locations.json 注释: px = A*wx + B*wy + TX ; py = A*wy - B*wx + TY
    return (A*wx + B*wy + TX, A*wy - B*wx + TY)

print("=" * 78)
print("步骤 0：先确定「哪个符号约定是真的」——用 map_locations.json 的 1777 条双坐标反解")
print("=" * 78)
ml = json.load(open(f"{ROOT}/models/map_locations.json", encoding="utf-8"))
locs = ml["locations"]
err_swift = err_doc = 0.0
worst_swift = worst_doc = (0, None)
n = 0
for l in locs:
    wx, wy = l.get("worldX"), l.get("worldY")
    mx, my = l.get("mapX"), l.get("mapY")
    if None in (wx, wy, mx, my): continue
    n += 1
    sx, sy = f_swift(wx, wy)
    dx, dy = f_doc(wx, wy)
    es = math.hypot(sx - mx, sy - my)
    ed = math.hypot(dx - mx, dy - my)
    err_swift += es; err_doc += ed
    if es > worst_swift[0]: worst_swift = (es, l["id"])
    if ed > worst_doc[0]:   worst_doc   = (ed, l["id"])
print("参与比对条数            : %d" % n)
print("Swift 约定 平均误差(px) : %.6f   最大 %.6f  (%s)" % (err_swift/n, worst_swift[0], worst_swift[1]))
print("文档 约定 平均误差(px)  : %.6f   最大 %.6f  (%s)" % (err_doc/n,   worst_doc[0],   worst_doc[1]))
FORMULA = f_swift if err_swift <= err_doc else f_doc
NAME = "Swift(CoordinateCapture/NetworkLocator)" if err_swift <= err_doc else "map_locations.json 注释"
print("→ 采用: %s" % NAME)
print("  （B 项极小，两式差异仅 %.4f px 量级，但以零误差者为真）" % (abs(err_swift - err_doc)/n))

print()
print("=" * 78)
print("步骤 1：map_locations.json 自身覆盖范围（1777 个已知地图点，13056 系）")
print("=" * 78)
xs = [l["mapX"] for l in locs if l.get("mapX") is not None]
ys = [l["mapY"] for l in locs if l.get("mapY") is not None]
print("mapX 范围: %.1f .. %.1f   (跨度 %.1f)" % (min(xs), max(xs), max(xs)-min(xs)))
print("mapY 范围: %.1f .. %.1f   (跨度 %.1f)" % (min(ys), max(ys), max(ys)-min(ys)))
print("声明 mapPixels = %d" % ml["mapPixels"])

print()
print("=" * 78)
print("步骤 2：DT_TeleportPoint.json 传送点世界坐标 → 代入换算 → 落点")
print("=" * 78)
tp = json.load(open(f"{ROOT}/tools/nte_datatables/DataTable/DT_TeleportPoint.json", encoding="utf-8"))
if isinstance(tp, list): tp = tp[0]
rows = tp["Rows"]
pts = []
for k, v in rows.items():
    tr = ((v or {}).get("Transform") or {}).get("Translation") or {}
    x, y, z = tr.get("X"), tr.get("Y"), tr.get("Z")
    if x is None or y is None: continue
    pts.append((k, x, y, z, str(v.get("TeleportPointType") or "").split("::")[-1]))
print("传送点总数: %d" % len(pts))

out = []
for k, x, y, z, t in pts:
    mx, my = FORMULA(x, y)
    out.append((k, x, y, z, mx, my, t))

mx_all = [o[4] for o in out]; my_all = [o[5] for o in out]
print("换算后 mapX 范围: %.1f .. %.1f" % (min(mx_all), max(mx_all)))
print("换算后 mapY 范围: %.1f .. %.1f" % (min(my_all), max(my_all)))
print()
print("%-34s %12s %12s | %10s %10s" % ("传送点", "worldX", "worldY", "mapX", "mapY"))
print("-" * 88)
for o in out[:8]:
    print("%-34s %12.1f %12.1f | %10.1f %10.1f" % (o[0][:34], o[1], o[2], o[4], o[5]))
print("... (%d 条)" % len(out))

print()
print("=" * 78)
print("步骤 3：4 个候选地图尺寸 —— 落点是否在范围内")
print("=" * 78)
print("%-8s %-12s %-12s %-12s %-10s" % ("尺寸", "X内点数", "Y内点数", "XY都在内", "结论"))
print("-" * 78)
results = {}
for S in SIZES:
    inx = sum(1 for o in out if 0 <= o[4] <= S)
    iny = sum(1 for o in out if 0 <= o[5] <= S)
    inxy = sum(1 for o in out if 0 <= o[4] <= S and 0 <= o[5] <= S)
    ok = (inxy == len(out))
    results[S] = (inx, iny, inxy)
    print("%-8d %-12s %-12s %-12s %-10s" % (
        S, "%d/%d" % (inx, len(out)), "%d/%d" % (iny, len(out)),
        "%d/%d" % (inxy, len(out)), "全部落内 ✅" if ok else "溢出 ❌"))
print()

# 用 map_locations 的 1777 点做同样的尺寸判别（更强的样本）
print("--- 同样用 map_locations.json 的 %d 个真实地图点复核 ---" % n)
print("%-8s %-14s %-14s %-10s" % ("尺寸", "X内点数", "Y内点数", "结论"))
print("-" * 60)
for S in SIZES:
    inx = sum(1 for v in xs if 0 <= v <= S)
    iny = sum(1 for v in ys if 0 <= v <= S)
    print("%-8d %-14s %-14s %-10s" % (S, "%d/%d" % (inx, n), "%d/%d" % (iny, n),
          "可行" if (inx == n and iny == n) else "溢出 %d" % (n - min(inx, iny))))

print()
print("=" * 78)
print("步骤 4：quest_index 坐标同系验证")
print("=" * 78)
qi = json.load(open(f"{ROOT}/models/quest_index.json", encoding="utf-8"))
qs = []
for bucket in ("exact", "core", "byname"):
    for k, v in qi[bucket].items():
        for e in v:
            if e.get("x") is not None and e.get("y") is not None:
                qs.append((e["x"], e["y"]))
print("quest_index 带坐标条目(含重复): %d" % len(qs))
qx = [p[0] for p in qs]; qy = [p[1] for p in qs]
print("world X 范围: %.1f .. %.1f" % (min(qx), max(qx)))
print("world Y 范围: %.1f .. %.1f" % (min(qy), max(qy)))
print("world Z 见下（单独）")
qmx = [FORMULA(p[0], p[1])[0] for p in qs]
qmy = [FORMULA(p[0], p[1])[1] for p in qs]
print("换算后 mapX 范围: %.1f .. %.1f" % (min(qmx), max(qmx)))
print("换算后 mapY 范围: %.1f .. %.1f" % (min(qmy), max(qmy)))
print()
for S in SIZES:
    inxy = sum(1 for i in range(len(qs)) if 0 <= qmx[i] <= S and 0 <= qmy[i] <= S)
    print("  尺寸 %-6d : %d/%d 任务坐标落在图内 (%.2f%%)" % (S, inxy, len(qs), 100.0*inxy/len(qs)))

print()
print("=" * 78)
print("步骤 5：任务点是否落在 map_locations 已知区域附近（最近邻距离，13056 系）")
print("=" * 78)
import bisect
grid = {}
for l in locs:
    if l.get("mapX") is None: continue
    grid.setdefault((int(l["mapX"])//500, int(l["mapY"])//500), []).append((l["mapX"], l["mapY"], l["name"]))
def nearest(px, py):
    best = None
    gx, gy = int(px)//500, int(py)//500
    for dx in (-1,0,1):
        for dy in (-1,0,1):
            for (lx, ly, nm) in grid.get((gx+dx, gy+dy), []):
                d = math.hypot(lx-px, ly-py)
                if best is None or d < best[0]: best = (d, nm, lx, ly)
    return best
sample = out[:10]
for o in sample:
    nb = nearest(o[4], o[5])
    if nb:
        print("%-30s map(%.0f,%.0f) → 最近已知点 %-16s 距离 %.0f px" % (o[0][:30], o[4], o[5], nb[1][:16], nb[0]))
    else:
        print("%-30s map(%.0f,%.0f) → 附近 1500px 内无已知点" % (o[0][:30], o[4], o[5]))
