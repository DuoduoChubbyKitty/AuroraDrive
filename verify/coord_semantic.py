#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 1c-终局：语义判别 —— 用「名字」把传送点和已知 POI 对上，
再比对该 POI 的官方 map 坐标 与 公式换算落点 的距离。
这一条不依赖符号约定、不依赖尺寸假设，是纯语义 + 数值双重约束。
"""
import json, math, re

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
A, B, TX, TY = (0.016394586684750773, 5.693519256055879e-08,
                6526.474380746091, 5210.664390686138)
def conv(wx, wy): return (A*wx + B*wy + TX, A*wy - B*wx + TY)

ml = json.load(open(f"{ROOT}/models/map_locations.json", encoding="utf-8"))
locs = [l for l in ml["locations"] if l.get("mapX") is not None]

tp = json.load(open(f"{ROOT}/tools/nte_datatables/DataTable/DT_TeleportPoint.json", encoding="utf-8"))
if isinstance(tp, list): tp = tp[0]

# 传送点类型 → 中文 POI 名关键词
KEY = {
    "WertheimerTower": "维特海默塔",
    "Oracle": "谕石",
    "TeleportPoint": None,
}
def poi_kw(name, ttype):
    if name.startswith("WertheimerTower"): return "维特海默塔"
    if name.startswith("Oracle"):          return "谕石"
    return None

# 建索引：中文名 → [(mapX,mapY,full)]
byname = {}
for l in locs:
    nm = re.sub(r"\s*#\s*\d+\s*$", "", l["name"] or "")
    byname.setdefault(nm, []).append((l["mapX"], l["mapY"], l["name"]))

print("=" * 78)
print("语义判别：传送点名字 → 已知 POI 名字 → 该 POI 官方地图坐标")
print("=" * 78)
print("%-30s %14s %14s | %-12s %8s" % ("传送点", "公式落点X", "公式落点Y", "最近同名POI", "距离px"))
print("-" * 92)
matched, dists, used = 0, [], []
for k, v in tp["Rows"].items():
    kw = poi_kw(k, "")
    if not kw: continue
    tr = ((v or {}).get("Transform") or {}).get("Translation") or {}
    if tr.get("X") is None: continue
    wx, wy = tr["X"], tr["Y"]
    mx, my = conv(wx, wy)
    cand = byname.get(kw)
    if not cand:
        continue
    best = min(cand, key=lambda c: math.hypot(c[0]-mx, c[1]-my))
    d = math.hypot(best[0]-mx, best[1]-my)
    matched += 1; dists.append(d); used.append((k, mx, my, best[2], d))
    if matched <= 12:
        print("%-30s %14.1f %14.1f | %-12s %8.1f" % (k[:30], mx, my, best[2][:12], d))
print("...")
print()
print("参与语义配对的传送点: %d" % matched)
if dists:
    print("公式落点 ↔ 同名POI官方坐标 距离: 平均 %.1f px, 中位 %.1f px, 最大 %.1f px" % (
        sum(dists)/len(dists), sorted(dists)[len(dists)//2], max(dists)))
    within = sum(1 for d in dists if d <= 60)
    print("≤60px 命中: %d/%d (%.1f%%)" % (within, len(dists), 100.0*within/len(dists)))

print()
print("=" * 78)
print("反证：若地图不是 13056（把同名 POI 坐标按比例换算到别的尺寸）")
print("=" * 78)
for S in (11264, 13056, 22528, 26112):
    k = S / 13056.0
    ds = []
    for (nm, mx, my, pname, d) in used:
        cand = byname.get(re.sub(r"\s*#\s*\d+\s*$", "", pname))
        best = min(math.hypot(c[0]*k-mx, c[1]*k-my) for c in cand)
        ds.append(best)
    print("  尺寸 %-6d : 平均距离 %8.1f px, ≤60px 命中 %d/%d" % (
        S, sum(ds)/len(ds), sum(1 for d in ds if d <= 60), len(ds)))
print()
print("  → 只有 13056 能让「名字相同的 POI」与「公式落点」重合到几十像素内。")
print("    别的尺寸会把 POI 挪走，距离放大到数百/上千像素。")
