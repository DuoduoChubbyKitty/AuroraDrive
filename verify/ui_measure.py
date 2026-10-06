#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 3：UI 像素级独立复量（不照抄 ui 的数字）"""
import numpy as np
from PIL import Image
import json, sys

P = "/tmp"
S = 2.0   # scale = 2 → 1pt = 2px

def load(n):
    im = Image.open(f"{P}/aurora_mc_quest_card_{n}.png").convert("RGB")
    return np.asarray(im, dtype=np.int16), im.size

on, size = load("on")
off, _ = load("off")
nr, _ = load("noroute")
H, W, _ = on.shape
print("=" * 78)
print("尺寸: %dx%d px  =  %.1f x %.1f pt (scale=%.0f)" % (W, H, W/S, H/S, S))
print("=" * 78)

def silver_mask(a):
    """银白描边：中性色（max-min 小）且足够亮"""
    mx = a.max(axis=2); mn = a.min(axis=2)
    return (mx - mn < 28) & (mx > 120)

print()
print("── 1) 卡片外框定位：找银白描边的长横线（ui 提示的可靠量法）──")
sm = silver_mask(on)
rows = []
for y in range(H):
    run = 0; best = 0
    for x in range(W):
        if sm[y, x]:
            run += 1; best = max(best, run)
        else:
            run = 0
    if best > 200: rows.append((y, best))
if rows:
    ys = [r[0] for r in rows]
    print("  满足「单行银白连续 >200px」的行: %s" % ys)
    print("  → 上沿 y=%dpx = %.1fpt ; 下沿 y=%dpx = %.1fpt" % (min(ys), min(ys)/S, max(ys), max(ys)/S))
    print("  → 外框高度 = %.1f px = %.1f pt" % (max(ys)-min(ys), (max(ys)-min(ys))/S))
else:
    print("  ❌ 未找到长横线")

# 卡片横向范围：在描边行上找银白像素的 x 范围
if rows:
    ytop = min(ys); ybot = max(ys)
    ymid = (ytop + ybot) // 2
    xs = np.where(sm[ytop])[0]
    print("  上沿行的银白 x 范围: %d..%d px = %.1f..%.1f pt (宽 %.1f pt)" % (
        xs.min(), xs.max(), xs.min()/S, xs.max()/S, (xs.max()-xs.min())/S))

print()
print("── 2) 卡片区域（含辉光）：与 off 图差异定位真实卡片范围 ──")
diff = np.abs(on.astype(int) - off.astype(int)).sum(axis=2)
mask = diff > 30
# 只看卡片附近（排除其它 UI）
colsum = mask.sum(axis=0); rowsum = mask.sum(axis=1)
xs_nz = np.where(colsum > 0)[0]; ys_nz = np.where(rowsum > 0)[0]
print("  变化像素 x 范围: %d..%d px = %.1f..%.1f pt" % (xs_nz.min(), xs_nz.max(), xs_nz.min()/S, xs_nz.max()/S))
print("  变化像素 y 范围: %d..%d px = %.1f..%.1f pt" % (ys_nz.min(), ys_nz.max(), ys_nz.min()/S, ys_nz.max()/S))
print("  变化像素总数: %d (占全图 %.3f%%)" % (mask.sum(), 100.0*mask.sum()/mask.size))
print("  ⚠️ 注意：游戏画面是占位图，每次渲染不同 → 该范围含占位噪声")

print()
print("── 3) 预览框（游戏画面）上沿定位：远离卡片的列扫高饱和起始 ──")
def sat_start(a, x):
    col = a[:, x, :]
    mx = col.max(axis=1); mn = col.min(axis=1)
    sat = mx - mn
    for y in range(H):
        if sat[y] > 60: return y
    return None
for x in [400, 800, 2600, 2000]:
    y = sat_start(on, x)
    print("  x=%-5d → 游戏画面起始 y=%s px = %s pt" % (x, y, ("%.1f" % (y/S)) if y is not None else "n/a"))

print()
print("── 4) 水平居中检查 ──")
# 预览框 x 范围：用高饱和行判断
ymid_game = None
for x in [400]:
    ymid_game = sat_start(on, x)
if ymid_game:
    row = on[ymid_game + 100, :, :]
    mx = row.max(axis=1); mn = row.min(axis=1)
    game_x = np.where((mx - mn) > 60)[0]
    gx0, gx1 = game_x.min(), game_x.max()
    print("  预览框（游戏画面）x 范围: %d..%d px = %.1f..%.1f pt  中心 = %.1f pt" % (
        gx0, gx1, gx0/S, gx1/S, (gx0+gx1)/2/S))
    if rows:
        card_cx = (xs.min() + xs.max()) / 2
        print("  卡片中心 x = %.1f px = %.1f pt" % (card_cx, card_cx/S))
        print("  居中偏差 = %.2f pt" % ((card_cx - (gx0+gx1)/2)/S))
        print("  卡片上沿到预览框上沿 = %.1f pt" % ((ytop - ymid_game)/S))
        print("  卡片宽占预览框 = %.1f%%" % (100.0*(xs.max()-xs.min())/(gx1-gx0)))
