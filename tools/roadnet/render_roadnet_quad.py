#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render_roadnet_quad.py —— 把路网渲染成 4 块（2x2），看连通性

输出: /tmp/roadnet_q/{q1,q2,q3,q4}.png + _overview.png
每块上:
  - 灰色细线 = 边的折线（道路）
  - 红点 = 节点
  - 绿圈 = 度>=3 的路口
  - 黄圈 = 度1 的悬挂端点（疑似断头）
"""
import json, os, math
from PIL import Image, ImageDraw

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
OUT = "/tmp/roadnet_q"
os.makedirs(OUT, exist_ok=True)

d = json.load(open(f"{ROOT}/models/route_graph.json", encoding="utf-8"))
MAP = d["meta"]["map_size"]
nodes = d["nodes"]      # [id, x, y]
edges = d["edges"]      # [a, b, len, poly]

xs = [n[1] for n in nodes]; ys = [n[2] for n in nodes]
X0, X1 = min(xs), max(xs); Y0, Y1 = min(ys), max(ys)
print("节点 %d  边 %d" % (len(nodes), len(edges)))
print("范围 x %.0f~%.0f  y %.0f~%.0f" % (X0, X1, Y0, Y1))

# 度数
deg = {}
for e in edges:
    deg[e[0]] = deg.get(e[0], 0) + 1
    deg[e[1]] = deg.get(e[1], 0) + 1
npos = {n[0]: (n[1], n[2]) for n in nodes}

def draw_region(x0, y0, x1, y1, W, H, title):
    """把世界矩形 [x0,x1]x[y0,y1] 画到 W×H 画布"""
    im = Image.new("RGB", (W, H), (10, 10, 14))
    dr = ImageDraw.Draw(im)
    sx = W / (x1 - x0); sy = H / (y1 - y0)
    def P(x, y):
        return ((x - x0) * sx, (y - y0) * sy)

    # 边
    for e in edges:
        a, b, L, poly = e[0], e[1], e[2], e[3]
        pts = [P(px, py) for px, py in poly]
        # 只画与本区域相交的
        if not any(x0 <= px <= x1 and y0 <= py <= y1 for px, py in poly):
            continue
        dr.line(pts, fill=(120, 160, 200), width=2)

    # 节点
    for n in nodes:
        x, y = n[1], n[2]
        if not (x0 <= x <= x1 and y0 <= y <= y1): continue
        px, py = P(x, y)
        dg = deg.get(n[0], 0)
        if dg == 0:
            dr.ellipse([px-4, py-4, px+4, py+4], outline=(255, 0, 255), width=2)   # 孤立
        elif dg == 1:
            dr.ellipse([px-4, py-4, px+4, py+4], outline=(255, 220, 0), width=2)   # 悬挂
        elif dg >= 3:
            dr.ellipse([px-4, py-4, px+4, py+4], outline=(0, 255, 120), width=2)   # 路口
        else:
            dr.ellipse([px-2, py-2, px+2, py+2], fill=(255, 80, 80))               # 普通
    dr.text((8, 8), title, fill=(255, 255, 255))
    return im

W = H = 1100
mx = (X1 - X0) * 0.06; my = (Y1 - Y0) * 0.06
X0e, X1e = X0 - mx, X1 + mx
Y0e, Y1e = Y0 - my, Y1 + my
cx = (X0e + X1e) / 2; cy = (Y0e + Y1e) / 2

quads = [
    ("q1_左上", X0e, Y0e, cx, cy),
    ("q2_右上", cx, Y0e, X1e, cy),
    ("q3_左下", X0e, cy, cx, Y1e),
    ("q4_右下", cx, cy, X1e, Y1e),
]
imgs = []
for name, x0, y0, x1, y1 in quads:
    im = draw_region(x0, y0, x1, y1, W, H, "%s  x%.0f~%.0f y%.0f~%.0f" % (name, x0, x1, y0, y1))
    p = f"{OUT}/{name}.png"
    im.save(p)
    imgs.append(im)
    print("  ->", p)

# 总览
ov = draw_region(X0e, Y0e, X1e, Y1e, 1600, 1600, "overview  节点%d 边%d" % (len(nodes), len(edges)))
ov.save(f"{OUT}/_overview.png")
print("  ->", f"{OUT}/_overview.png")

# 2x2 拼图
sheet = Image.new("RGB", (W*2+8, H*2+8), (0, 0, 0))
for i, im in enumerate(imgs):
    sheet.paste(im, ((i % 2) * (W+8), (i//2) * (H+8)))
sheet.thumbnail((1500, 1500))
sheet.save(f"{OUT}/_sheet.png")
print("  ->", f"{OUT}/_sheet.png", sheet.size)

# 连通性统计
print()
print("=== 连通性统计 ===")
adj = {}
for e in edges:
    adj.setdefault(e[0], set()).add(e[1])
    adj.setdefault(e[1], set()).add(e[0])
seen = set(); comps = []
for n in npos:
    if n in seen: continue
    stack = [n]; comp = set()
    while stack:
        c = stack.pop()
        if c in comp: continue
        comp.add(c); seen.add(c)
        for nb in adj.get(c, ()):
            if nb not in comp: stack.append(nb)
    comps.append(comp)
comps.sort(key=len, reverse=True)
print("  连通分量数: %d" % len(comps))
for i, c in enumerate(comps[:12]):
    print("    #%d  %d 个节点 (%.0f%%)" % (i+1, len(c), len(c)/len(npos)*100))
if len(comps) > 12: print("    ... 还有 %d 个" % (len(comps)-12))
print("  最大分量占比: %.1f%%" % (len(comps[0])/len(npos)*100))
print()
print("  悬挂端点(度1): %d" % sum(1 for v in deg.values() if v == 1))
print("  孤立节点(度0): %d" % (len(npos) - len(deg)))
