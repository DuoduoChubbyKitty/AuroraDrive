#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 3.2 复验（修正量法）：
  · 用「增量色」(on−off) 判辉光颜色，而不是选最亮像素（后者会选中背景）
  · 用「游戏画面实际范围」限制取样（预览框上沿 y=134px，上方是黑色控制台，无辉光）
"""
import numpy as np
from PIL import Image

pre_on  = np.asarray(Image.open('/tmp/run2_on.png').convert('RGB'), dtype=np.float64)
pre_off = np.asarray(Image.open('/tmp/run2_off.png').convert('RGB'), dtype=np.float64)
on      = np.asarray(Image.open('/tmp/post_fix_on.png').convert('RGB'), dtype=np.float64)
off     = np.asarray(Image.open('/tmp/post_fix_off.png').convert('RGB'), dtype=np.float64)
H, W, _ = on.shape
X0, X1, Y0, Y1 = 1294, 1646, 154, 245
GAME_TOP = 134      # 预览框（游戏画面）上沿，由前次实测确定
GAME_L   = 26
GAME_R   = 2913

print("=" * 78)
print("0) 修正：预览框上沿 y=%d，其上方是黑色控制台 → 该区域无辉光（被裁切）" % GAME_TOP)
print("=" * 78)
d_pre  = on*0 + (pre_on - pre_off)
d_post = on - off
for nm,(y0,y1) in [("上方 y104-134（控制台黑区）",(104,134)), ("上方 y134-154（游戏区内）",(134,154))]:
    a = d_post[y0:y1, X0:X1]
    print("  %-26s Δ均值 %+.2f  (修复前 %+.2f)" % (nm, a.mean(), d_pre[y0:y1, X0:X1].mean()))

print()
print("=" * 78)
print("1) 辉光颜色 = 增量色 (on−off) 的均值（这才是「加进来的光」）")
print("=" * 78)
def delta_color(arr, y0,y1,x0,x1):
    d = arr[y0:y1, x0:x1].reshape(-1,3)
    # 只取确有增量的像素
    lum = d.mean(axis=1)
    sel = d[lum > np.percentile(lum, 80)]
    return sel.mean(axis=0)

regions = {
    "上 (y134-152)":  (GAME_TOP, Y0-2, X0, X1),
    "左 (x1234-1292)": (Y0, Y1, X0-60, X0-2),
    "右 (x1648-1706)": (Y0, Y1, X1+2, X1+60),
    "下 (y247-305)":   (Y1+2, Y1+60, X0, X1),
}
print("  %-18s %-24s %-9s %-9s %s" % ("区域", "增量色 RGB", "B−R", "max−min", "判定"))
for nm,(y0,y1,x0,x1) in regions.items():
    c = delta_color(d_post, y0,y1,x0,x1)
    neu = abs(c[2]-c[0]) < 12 and (c.max()-c.min()) < 15
    print("  %-18s %-24s %+8.1f %9.1f  %s" % (
        nm, str(np.round(c,1)), c[2]-c[0], c.max()-c.min(),
        "✅ 中性（银白）" if neu else "⚠️ 偏色"))
print()
print("  代码声明: glowNear 0xF2F4F8 (242,244,248) B−R=+6 ; glowFar 0xE8ECF2 (232,236,242) B−R=+10")
print("  → 增量色应接近该族（中性、B 略高于 R）")

print()
print("=" * 78)
print("2) 三面净变亮（限制在游戏画面内，避开控制台黑区）")
print("=" * 78)
print("  %-18s %-16s %-16s %s" % ("区域", "修复前Δ", "修复后Δ", "修复后 变亮/变暗"))
print("  " + "-" * 72)
for nm,(y0,y1,x0,x1) in regions.items():
    a = d_pre[y0:y1,x0:x1].mean(axis=2)
    b = d_post[y0:y1,x0:x1].mean(axis=2)
    up, dn = (b>2).sum(), (b<-2).sum()
    print("  %-18s %+8.2f        %+8.2f         %6d / %-6d %s" % (
        nm, a.mean(), b.mean(), up, dn, "✅净变亮" if b.mean()>0 else "❌净变暗"))

print()
print("=" * 78)
print("3) 全环带总览（游戏区内，排除控制台）")
print("=" * 78)
ring = np.zeros((H,W), bool)
ring[GAME_TOP:Y0, X0:X1] = True
ring[Y0:Y1, X0-60:X0] = True
ring[Y0:Y1, X1+1:X1+61] = True
ring[Y1+1:Y1+61, X0:X1] = True
for nm, arr in [("修复前", d_pre.mean(axis=2)), ("修复后", d_post.mean(axis=2))]:
    v = arr[ring]
    print("  %s: Δ均值 %+.2f  变亮(>2) %5d  变暗(<-2) %5d  中性 %5d" % (
        nm, v.mean(), (v>2).sum(), (v<-2).sum(), (np.abs(v)<=2).sum()))

print()
print("=" * 78)
print("4) 下方为何仍偏暗？—— 逐行看增量")
print("=" * 78)
print("  y(px)  y(pt)   背景RGB(off)        Δ均值     Δ_R    Δ_G    Δ_B")
for y in range(Y1+1, Y1+80, 6):
    bg = off[y, X0:X1].mean(axis=0)
    dd = d_post[y, X0:X1].mean(axis=0)
    print("  %5d %6.1f  %-18s %+7.2f %+7.1f %+7.1f %+7.1f" % (
        y, y/2, str(np.round(bg,0).astype(int)), dd.mean(), dd[0], dd[1], dd[2]))

print()
print("=" * 78)
print("5) 对比度回归 + 几何回归")
print("=" * 78)
def rel_lum(rgb):
    def f(c):
        c=float(c)/255.0
        return c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
    r,g,b=rgb
    return 0.2126*f(r)+0.7152*f(g)+0.0722*f(b)
def contrast(c1,c2):
    l1,l2=rel_lum(c1),rel_lum(c2); hi,lo=max(l1,l2),min(l1,l2)
    return (hi+0.05)/(lo+0.05)
def brightest(reg, pct=99.0):
    flat=reg.reshape(-1,3); lum=flat.mean(axis=1)
    th=np.percentile(lum,pct); return flat[lum>=th].mean(axis=0)
for tag, img in [("修复前", pre_on), ("修复后", on)]:
    t = brightest(img[168:198, X0+30:X1-30, :])
    b1 = np.median(img[Y0+3:Y0+10, X0+20:X1-20, :].reshape(-1,3), axis=0)
    b2 = np.median(img[Y1-8:Y1-3, X0+20:X1-20, :].reshape(-1,3), axis=0)
    print("  %s: 文字vs顶底=%.2f:1  文字vs底底=%.2f:1  (文字色 %s)" % (
        tag, contrast(tuple(t),tuple(b1)), contrast(tuple(t),tuple(b2)), np.round(t,1)))
def silver_rows(img):
    mx=img.max(axis=2); mn=img.min(axis=2); sm=(mx-mn<28)&(mx>120)
    rows=[]
    for y in range(H):
        run=0;best=0
        for x in range(W):
            if sm[y,x]: run+=1; best=max(best,run)
            else: run=0
        if best>200: rows.append(y)
    return rows
print("  银白外框行: 修复前 %s / 修复后 %s → %s" % (
    silver_rows(pre_on), silver_rows(on),
    "✅未变" if silver_rows(pre_on)==silver_rows(on) else "⚠️变"))
