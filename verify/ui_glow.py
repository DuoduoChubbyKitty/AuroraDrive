#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 3 续修：辉光直接读亮度剖面 + 对比度修正"""
import numpy as np
from PIL import Image

P = "/tmp"; S = 2.0
def load(n):
    return np.asarray(Image.open(f"{P}/aurora_mc_quest_card_{n}.png").convert("RGB"), dtype=np.int16)
on, off, nr = load("on"), load("off"), load("noroute")
H, W, _ = on.shape
CY0, CY1 = 154, 245
CARD_X0, CARD_X1 = 647*2, 823*2      # 1294 .. 1646

print("=" * 78)
print("1) 辉光：沿水平线读亮度剖面（卡片左右外侧应有渐降的亮环）")
print("=" * 78)
ymid = (CY0 + CY1)//2
prof_on = on[ymid, :, :].mean(axis=1)
prof_off = off[ymid, :, :].mean(axis=1)
print("  行 y=%d，卡片外框 x=%d..%d" % (ymid, CARD_X0, CARD_X1))
print()
print("  x(px)   x(pt)    on亮度   off亮度   on-off")
for x in list(range(CARD_X0-120, CARD_X0+10, 10)) + list(range(CARD_X1-10, CARD_X1+130, 10)):
    if 0 <= x < W:
        print("  %6d %7.1f %9.1f %9.1f %8.1f" % (x, x/S, prof_on[x], prof_off[x], prof_on[x]-prof_off[x]))

print()
print("  判据：若卡片有辉光，紧贴外框的像素应比远处背景更亮（on 图自身剖面呈凸起）")
# 用 on 图自身：比较紧邻外框 vs 更远处
for side, near, far in [("左", CARD_X0-6, CARD_X0-120), ("右", CARD_X1+6, CARD_X1+120)]:
    n_on = prof_on[near-3:near+3].mean(); f_on = prof_on[far-3:far+3].mean()
    print("    %s侧: 紧邻(%.1fpt)=%.1f  远处(%.1fpt)=%.1f  差=%.1f" % (
        side, near/S, n_on, far/S, f_on, n_on-f_on))

print()
print("=" * 78)
print("2) 辉光：垂直剖面（卡片上下外侧）")
print("=" * 78)
xmid = (CARD_X0 + CARD_X1)//2
col_on = on[:, xmid, :].mean(axis=1)
col_off = off[:, xmid, :].mean(axis=1)
print("  x=%d，卡片外框 y=%d..%d" % (xmid, CY0, CY1))
print("  y(px)   y(pt)    on亮度   off亮度   on-off")
for y in list(range(CY0-60, CY0+5, 5)) + list(range(CY1-5, CY1+70, 5)):
    if 0 <= y < H:
        print("  %6d %7.1f %9.1f %9.1f %8.1f" % (y, y/S, col_on[y], col_off[y], col_on[y]-col_off[y]))

print()
print("=" * 78)
print("3) 辉光色相：是否「银白」（中性，B−R 接近 0）")
print("=" * 78)
# 外框外 2~40px 的环带
ring = []
for (y0,y1,x0,x1) in [(CY0,CY1,CARD_X0-40,CARD_X0-2), (CY0,CY1,CARD_X1+2,CARD_X1+40),
                      (CY0-30,CY0-2,CARD_X0,CARD_X1), (CY1+2,CY1+40,CARD_X0,CARD_X1)]:
    ring.append(on[max(0,y0):y1, max(0,x0):x1, :].reshape(-1,3))
ring = np.vstack(ring)
# 取环带里最亮的 5%（辉光核心）
lum = ring.mean(axis=1)
th = np.percentile(lum, 95)
core = ring[lum >= th]
mean_core = core.mean(axis=0)
print("  环带像素数: %d ; 最亮5%% 均值 RGB = %s" % (len(ring), np.round(mean_core,1)))
print("  B−R = %.1f ; max−min = %.1f" % (mean_core[2]-mean_core[0], mean_core.max()-mean_core.min()))
print("  → %s" % ("✅ 中性偏银（|B−R| < 10）" if abs(mean_core[2]-mean_core[0]) < 10 else "⚠️ 有偏色"))
print("  ui 报辉光峰值 RGB≈(144,146,150) B−R=−3")

print()
print("=" * 78)
print("4) off 图卡片区域：是否 100% 游戏画面")
print("=" * 78)
y0,y1 = CY0-30, CY1+30
x0,x1 = CARD_X0-40, CARD_X1+40
reg_off = off[y0:y1, x0:x1, :].astype(int)
reg_on = on[y0:y1, x0:x1, :].astype(int)
d = np.abs(reg_on - reg_off).sum(axis=2)
npx = d.shape[0]*d.shape[1]
print("  区域 %dx%d = %d px" % (d.shape[0], d.shape[1], npx))
print("  on/off 差异 >30 的像素: %d (%.2f%%)" % ((d>30).sum(), 100.0*(d>30).sum()/npx))
# off 图内部是否还有卡片描边
inner_off = reg_off[CY0-y0:CY1-y0, CARD_X0-x0:CARD_X1-x0, :]
mx = inner_off.max(axis=2); mn = inner_off.min(axis=2)
stroke = (mx-mn < 28) & (mx > 120)
print("  off 图【外框内部】银白描边像素: %d / %d" % (stroke.sum(), stroke.size//3))
print("  → %s" % ("✅ 卡片完全消失，无空框残留" if stroke.sum()==0 else "❌ 残留 %d 像素" % stroke.sum()))

print()
print("=" * 78)
print("5) 对比度（WCAG 2.x 公式，独立计算）")
print("=" * 78)
def rel_lum(rgb):
    def f(c):
        c = float(c)/255.0
        return c/12.92 if c <= 0.03928 else ((c+0.055)/1.055)**2.4
    r,g,b = rgb
    return 0.2126*f(r) + 0.7152*f(g) + 0.0722*f(b)
def contrast(c1, c2):
    l1, l2 = rel_lum(c1), rel_lum(c2)
    hi, lo = max(l1,l2), min(l1,l2)
    return (hi+0.05)/(lo+0.05)

name_row = on[170:195, CARD_X0+40:CARD_X1-40, :]
flat = name_row.reshape(-1,3); lum = flat.mean(axis=1)
th = np.percentile(lum, 99.5)
tx = flat[lum >= th].mean(axis=0)
bg_row = on[CY0+5:CY0+15, CARD_X0+10:CARD_X1-10, :]
bgc = np.median(bg_row.reshape(-1,3), axis=0)
print("  文字色(最亮0.5%%均值) = %s" % np.round(tx,1))
print("  实测卡片底色(中位)     = %s" % np.round(bgc,1))
c_meas = contrast(tuple(tx), tuple(bgc))
print("  WCAG 对比度(实测底色)  = %.2f : 1  → %s" % (c_meas, "✅ 过 AA(4.5)" if c_meas>=4.5 else "❌"))
print()
print("  半透明合成模型（scrim=0x05080F, alpha=0.78）:")
scrim = np.array([5.0,8.0,15.0]); a = 0.78
for nm, bg in [("纯黑(0,0,0)",(0,0,0)), ("游戏暗部(60,60,60)",(60,60,60)),
               ("灰(128,128,128)",(128,128,128)), ("游戏亮部(200,200,200)",(200,200,200)),
               ("纯白(255,255,255)",(255,255,255)), ("真机黄底(241,195,15)",(241,195,15))]:
    comp = np.array(bg, dtype=float)*(1-a) + scrim*a
    c = contrast(tuple(tx), tuple(comp))
    print("    %-22s 合成=%-22s 对比度=%5.2f:1  %s" % (nm, str(np.round(comp,1)), c, "✅" if c>=4.5 else "❌"))

print()
print("  ui 报：深底 11.1 / 亮底 9.2 / 真机黄底 8.5")
print("  验证方实测：见上（数值口径可能因取样点不同略有差异）")
