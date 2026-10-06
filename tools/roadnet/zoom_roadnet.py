#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""zoom_roadnet.py —— 放大看指定区域的路网（诊断分叉/断头）"""
import json, os, math, sys
from PIL import Image, ImageDraw

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
OUT = "/tmp/roadnet_zoom"
os.makedirs(OUT, exist_ok=True)

d = json.load(open(f"{ROOT}/models/route_graph.json", encoding="utf-8"))
nodes = {n[0]: (n[1], n[2]) for n in d["nodes"]}
edges = d["edges"]
deg = {}
for e in edges:
    deg[e[0]] = deg.get(e[0], 0) + 1
    deg[e[1]] = deg.get(e[1], 0) + 1

def render(cx, cy, half, name, W=1000):
    x0, x1 = cx - half, cx + half
    y0, y1 = cy - half, cy + half
    im = Image.new("RGB", (W, W), (8, 8, 12))
    dr = ImageDraw.Draw(im)
    sx = W / (x1 - x0)
    def P(x, y): return ((x - x0) * sx, (y - y0) * sx)
    for i, e in enumerate(edges):
        poly = e[3]
        if not any(x0 <= px <= x1 and y0 <= py <= y1 for px, py in poly): continue
        pts = [P(px, py) for px, py in poly]
        dr.line(pts, fill=(140, 180, 220), width=2)
        # 标边号
        mid = poly[len(poly)//2]
        if x0 <= mid[0] <= x1 and y0 <= mid[1] <= y1:
            dr.text(P(mid[0], mid[1]), "e%d" % i, fill=(90, 110, 140))
    for n, (x, y) in nodes.items():
        if not (x0 <= x <= x1 and y0 <= y <= y1): continue
        px, py = P(x, y)
        dg = deg.get(n, 0)
        col = (255, 0, 255) if dg == 0 else ((255, 220, 0) if dg == 1 else ((0, 255, 120) if dg >= 3 else (255, 90, 90)))
        r = 5
        dr.ellipse([px-r, py-r, px+r, py+r], outline=col, width=2)
        dr.text((px+7, py-6), "n%d" % n, fill=col)
    dr.text((8, 8), "%s  center(%.0f,%.0f) ±%.0f  " % (name, cx, cy, half), fill=(255,255,255))
    p = f"{OUT}/{name}.png"
    im.save(p)
    return p

# 选几个区域：断头密集区 + 重复边所在
targets = [
    (4501, 6884, 900, "A_断头密集区"),
    (4800, 8100, 900, "B_断头密集区2"),
    (2300, 5400, 700, "C_重复边55-59"),
    (4600, 7600, 900, "D_重复边403-417"),
    (3900, 7300, 900, "E_偏远断头区"),
    (6500, 7800, 900, "F_急弯区"),
]
for cx, cy, half, name in targets:
    print("  ->", render(cx, cy, half, name))
