#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 1c-广谱：任务面板文字里出现 POI 名 → 该任务坐标 是否落在同名 POI 附近。
样本比 6 个传送点大得多，同样不依赖尺寸/符号假设。"""
import json, math, re, collections

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
A, B, TX, TY = (0.016394586684750773, 5.693519256055879e-08,
                6526.474380746091, 5210.664390686138)
def conv(wx, wy): return (A*wx + B*wy + TX, A*wy - B*wx + TY)

ml = json.load(open(f"{ROOT}/models/map_locations.json", encoding="utf-8"))
locs = [l for l in ml["locations"] if l.get("mapX") is not None]
# 只取名字足够独特、且可在地图上定位的 POI（长度>=4，去掉编号后缀）
pois = []
for l in locs:
    nm = re.sub(r"\s*#\s*\d+\s*$", "", l["name"] or "").strip()
    if len(nm) >= 4:
        pois.append((nm, l["mapX"], l["mapY"]))

qi = json.load(open(f"{ROOT}/models/quest_index.json", encoding="utf-8"))
# 收集 (文字, worldX, worldY) 去重
seen = set(); entries = []
for bucket in ("exact", "core", "byname"):
    for k, v in qi[bucket].items():
        for e in v:
            if e.get("x") is None or e.get("y") is None: continue
            sig = (k, e["x"], e["y"])
            if sig in seen: continue
            seen.add(sig); entries.append((k, e["x"], e["y"], e.get("quest") or ""))
print("候选 (文字,worldX,worldY) 组合: %d" % len(entries))

# 建 POI 名字索引（按前 2 字分桶加速）
buck = collections.defaultdict(list)
for nm, mx, my in pois:
    buck[nm[:2]].append((nm, mx, my))

hits = []
for text, wx, wy, qn in entries:
    if len(text) < 4: continue
    mx, my = conv(wx, wy)
    for nm, px, py in buck.get(text[:2], []):
        if nm in text or text in nm:
            d = math.hypot(px-mx, py-my)
            hits.append((text, nm, d, mx, my, px, py, qn))
            break

print("文字与 POI 名匹配上的样本: %d" % len(hits))
if hits:
    ds = sorted(h[2] for h in hits)
    print("距离分布: min %.0f / p25 %.0f / 中位 %.0f / p75 %.0f / max %.0f" % (
        ds[0], ds[len(ds)//4], ds[len(ds)//2], ds[3*len(ds)//4], ds[-1]))
    for th in (30, 60, 100, 200, 500):
        c = sum(1 for d in ds if d <= th)
        print("  ≤%-4dpx : %5d / %d  (%.1f%%)" % (th, c, len(ds), 100.0*c/len(ds)))
    print()
    print("示例（距离最近的 10 条）:")
    print("%-26s %-16s %10s %10s %10s %10s %8s" % ("面板文字","POI名","任务mapX","任务mapY","POImapX","POImapY","距离px"))
    for h in sorted(hits, key=lambda x: x[2])[:10]:
        print("%-26s %-16s %10.0f %10.0f %10.0f %10.0f %8.0f" % (
            h[0][:26], h[1][:16], h[3], h[4], h[5], h[6], h[2]))
    print()
    print("示例（距离最远的 5 条 —— 检查是否有系统性偏移）:")
    for h in sorted(hits, key=lambda x: -x[2])[:5]:
        print("%-26s %-16s %10.0f %10.0f %10.0f %10.0f %8.0f" % (
            h[0][:26], h[1][:16], h[3], h[4], h[5], h[6], h[2]))

    print()
    print("=" * 78)
    print("反证：POI 坐标按别的地图尺寸缩放后，同一批样本的距离")
    print("=" * 78)
    for S in (11264, 13056, 22528, 26112):
        k = S/13056.0
        ds2 = [math.hypot(h[5]*k-h[3], h[6]*k-h[4]) for h in hits]
        m = sum(ds2)/len(ds2)
        c60 = sum(1 for d in ds2 if d <= 60)
        print("  尺寸 %-6d : 平均距离 %9.1f px, ≤60px %d/%d" % (S, m, c60, len(ds2)))
