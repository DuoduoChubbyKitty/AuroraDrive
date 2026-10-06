#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 3 续：辉光像素 / off 消失 / TagChip 未挤动 / 对比度"""
import numpy as np
from PIL import Image

P = "/tmp"; S = 2.0
def load(n):
    return np.asarray(Image.open(f"{P}/aurora_mc_quest_card_{n}.png").convert("RGB"), dtype=np.int16)
on, off, nr = load("on"), load("off"), load("noroute")
H, W, _ = on.shape

# 卡片外框（验证方独立实测值）
CY0, CY1 = 154, 245      # px
CX0, CX1 = 1318, 1621    # 银白直段 x
CARD_X0, CARD_X1 = 647*2, 823*2   # 代码定宽 176pt 的外框
print("=" * 78)
print("1) 银白辉光：卡片外框外的环带是否有辉光（读像素）")
print("=" * 78)

def ring_stats(a, name):
    """外框外扩区域的中性亮像素统计"""
    out = {}
    for side, (y0,y1,x0,x1) in {
        "左": (CY0, CY1, CARD_X0-90, CARD_X0-2),
        "右": (CY0, CY1, CARD_X1+2, CARD_X1+90),
        "上": (CY0-40, CY0-2, CARD_X0, CARD_X1),
        "下": (CY1+2, CY1+80, CARD_X0, CARD_X1),
    }.items():
        y0=max(0,y0); y1=min(H,y1); x0=max(0,x0); x1=min(W,x1)
        reg = a[y0:y1, x0:x1, :]
        mx = reg.max(axis=2); mn = reg.min(axis=2)
        lum = reg.mean(axis=2)
        neutral_bright = ((mx-mn) < 30) & (mx > 100)
        out[side] = (int(neutral_bright.sum()), float(lum.max()), float(lum.mean()))
    return out

print("  区域           中性亮像素数   最大亮度   平均亮度")
ron = ring_stats(on, "on")
for k,(c,mx,mean) in ron.items():
    print("  %-6s %12d %10.0f %10.1f" % (k, c, mx, mean))

print()
print("  辉光是否存在判据：外框外环带应有「中性亮」像素（银白），且 on 图明显多于 off 图")
roff = ring_stats(off, "off")
print("  off 图对照：")
for k,(c,mx,mean) in roff.items():
    print("  %-6s %12d %10.0f %10.1f" % (k, c, mx, mean))
print()
tot_on = sum(v[0] for v in ron.values()); tot_off = sum(v[0] for v in roff.values())
print("  on 环带中性亮像素合计 = %d ; off = %d" % (tot_on, tot_off))
print("  → %s" % ("✅ 辉光存在（on 显著多于 off）" if tot_on > tot_off * 1.5 else "⚠️ 辉光证据不足"))

# 辉光外扩距离
print()
print("  辉光外扩范围（在卡片中心行/列上，找 on 比 off 亮的连续区）")
diff = (on.astype(int).mean(axis=2) - off.astype(int).mean(axis=2))
row = diff[(CY0+CY1)//2, :]
xs = np.where(row > 4)[0]
if len(xs):
    print("    中心行 y=%d: 变化 x = %d..%d px" % ((CY0+CY1)//2, xs.min(), xs.max()))
    print("    左外扩 = %.1f pt, 右外扩 = %.1f pt" % ((CARD_X0-xs.min())/S, (xs.max()-CARD_X1)/S))
col = diff[:, (CX0+CX1)//2]
ys = np.where(col > 4)[0]
if len(ys):
    print("    中心列 x=%d: 变化 y = %d..%d px" % ((CX0+CX1)//2, ys.min(), ys.max()))
    print("    上外扩 = %.1f pt, 下外扩 = %.1f pt" % ((CY0-ys.min())/S, (ys.max()-CY1)/S))

print()
print("=" * 78)
print("2) 任务为空时卡片必须消失（off 图卡片矩形内应 100% 游戏画面）")
print("=" * 78)
# 卡片矩形（含辉光外扩）区域：on 与 off 的差异
y0,y1 = CY0-30, CY1+30
x0,x1 = CARD_X0-40, CARD_X1+40
reg_on = on[y0:y1, x0:x1, :].astype(int)
reg_off = off[y0:y1, x0:x1, :].astype(int)
d = np.abs(reg_on - reg_off).sum(axis=2)
print("  卡片矩形(含辉光) 区域: x %d..%d, y %d..%d px" % (x0,x1,y0,y1))
print("  该区域 on/off 差异 >30 的像素: %d / %d (%.2f%%)" % ((d>30).sum(), d.size//3, 100.0*(d>30).sum()/(d.size//3)))
print("  最大差异: %d" % d.max())

# 更关键：off 图卡片内部是否还有银白描边（若有 = 空框残留）
sm_off = (reg_off.max(axis=2) - reg_off.min(axis=2) < 28) & (reg_off.max(axis=2) > 120)
# 只看严格外框内部
iy0,iy1,ix0,ix1 = CY0-y0, CY1-y0, CARD_X0-x0, CARD_X1-x0
inner = sm_off[iy0:iy1, ix0:ix1]
print("  off 图【卡片外框内部】中性亮像素(银白描边/文字): %d / %d" % (inner.sum(), inner.size))
print("  → %s" % ("✅ 卡片完全消失，无空框残留" if inner.sum() == 0 else "❌ 仍有残留 %d 像素" % inner.sum()))

print()
print("=" * 78)
print("3) 现有 TagChip 未被挤动（y=25..65px 亮块带逐像素比对）")
print("=" * 78)
band_on = on[25:65, :, :]; band_off = off[25:65, :, :]; band_nr = nr[25:65, :, :]
def cols_with_bright(a, th=60):
    mx = a.max(axis=2)
    return np.where((mx > th).any(axis=0))[0]
c_on = cols_with_bright(band_on); c_off = cols_with_bright(band_off); c_nr = cols_with_bright(band_nr)
print("  TagChip 带 y=25..65px 亮块列范围:")
print("    on     : %d..%d px" % (c_on.min(), c_on.max()) if len(c_on) else "    on     : 无")
print("    off    : %d..%d px" % (c_off.min(), c_off.max()) if len(c_off) else "    off    : 无")
print("    noroute: %d..%d px" % (c_nr.min(), c_nr.max()) if len(c_nr) else "    noroute: 无")
d2 = np.abs(band_on.astype(int) - band_off.astype(int)).sum(axis=2)
print("  on vs off 该带最大像素差(求和通道): %d ; 差异>10 的像素: %d" % (d2.max(), (d2>10).sum()))
d3 = np.abs(band_on.astype(int) - band_nr.astype(int)).sum(axis=2)
print("  on vs noroute 该带最大像素差: %d ; 差异>10 的像素: %d" % (d3.max(), (d3>10).sum()))

print()
print("=" * 78)
print("4) 对比度（WCAG 公式，独立计算）")
print("=" * 78)
def rel_lum(rgb):
    def f(c):
        c = c/255.0
        return c/12.92 if c <= 0.03928 else ((c+0.055)/1.055)**2.4
    r,g,b = rgb
    return 0.2126*f(r) + 0.7152*f(g) + 0.0722*f(b)
def contrast(c1, c2):
    l1, l2 = rel_lum(c1), rel_lum(c2)
    hi, lo = max(l1,l2), min(l1,l2)
    return (hi+0.05)/(lo+0.05)

# 取卡片文字实测色 与 卡片底实测色
# 任务名行（y≈180px）、距离行（y≈218px）在卡片内部
name_row = on[170:195, CARD_X0+40:CARD_X1-40, :]
dist_row = on[205:235, CARD_X0+40:CARD_X1-40, :]
bg_row   = on[CY0+5:CY0+15, CARD_X0+10:CARD_X1-10, :]
print("  任务名行最亮像素 RGB = %s" % (name_row.reshape(-1,3).max(axis=0),))
print("  距离行最亮像素   RGB = %s" % (dist_row.reshape(-1,3).max(axis=0),))
print("  卡片底(顶部)中位 RGB = %s" % (np.median(bg_row.reshape(-1,3),axis=0),))
# 取文字最亮 1% 与 底色中位
def brightest(a, pct=99.5):
    flat = a.reshape(-1,3)
    lum = flat.mean(axis=1)
    th = np.percentile(lum, pct)
    return flat[lum >= th].mean(axis=0)
tx = brightest(name_row); bgc = np.median(bg_row.reshape(-1,3), axis=0)
print()
print("  文字色(最亮0.5%%均值) = %s" % np.round(tx,1))
print("  底色(中位)           = %s" % np.round(bgc,1))
print("  WCAG 对比度 = %.2f : 1" % contrast(tuple(tx), tuple(bgc)))
print("  AA 正文门槛 4.5:1 → %s" % ("✅ 通过" if contrast(tuple(tx),tuple(bgc)) >= 4.5 else "❌ 不通过"))

# 真机黄底
print()
print("  真机黄底场景（ui 报 241,195,15）:")
yellow = (241,195,15)
# 卡片半透明 → 合成色 = bg*(1-a) + scrim*a，scrim=0x05080F a=0.78
scrim = np.array([5,8,15]); a = 0.78
comp = yellow*(1-a) + scrim*a
print("    合成底色 = %s" % np.round(comp,1))
print("    WCAG 对比度 = %.2f : 1 → %s" % (contrast(tuple(tx), tuple(comp)),
      "✅ 通过 AA" if contrast(tuple(tx),tuple(comp)) >= 4.5 else "❌"))
# 亮底/暗底
for nm, bg in [("纯白", (255,255,255)), ("纯黑", (0,0,0)), ("游戏亮部", (200,200,200))]:
    comp2 = np.array(bg)*(1-a) + scrim*a
    print("    %-8s 合成=%s  对比度=%.2f:1" % (nm, np.round(comp2,1), contrast(tuple(tx), tuple(comp2))))
