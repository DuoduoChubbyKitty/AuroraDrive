#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 3.2 复验：辉光修复（lead 用 plusLighter 加法混合 + 删投影）
独立复量：三面净变亮 / 色相中性 / 对比度未退化
"""
import numpy as np
from PIL import Image

pre_on  = np.asarray(Image.open('/tmp/run2_on.png').convert('RGB'), dtype=np.float64)
pre_off = np.asarray(Image.open('/tmp/run2_off.png').convert('RGB'), dtype=np.float64)
on      = np.asarray(Image.open('/tmp/post_fix_on.png').convert('RGB'), dtype=np.float64)
off     = np.asarray(Image.open('/tmp/post_fix_off.png').convert('RGB'), dtype=np.float64)
H, W, _ = on.shape
X0, X1, Y0, Y1 = 1294, 1646, 154, 245

print("=" * 78)
print("0) 前置：修复前/后 off 图是否一致（确保对比基线公平）")
print("=" * 78)
d_off = np.abs(pre_off - off).max()
print("  修复前 off vs 修复后 off 最大像素差: %.0f → %s" % (
    d_off, "完全一致 ✅（off 无卡片，本就不该变）" if d_off == 0 else "有差异 ⚠️"))

print()
print("=" * 78)
print("1) 先定位「纯黄底」区域（避开红/黄圆弧交界）—— 不照抄 lead 的区间")
print("=" * 78)
# 在 off 图上扫描卡片四周，找背景均匀（标准差小）的区域
def region_stats(y0, y1, x0, x1):
    r = off[y0:y1, x0:x1]
    return r.reshape(-1,3).mean(axis=0), r.reshape(-1,3).std(axis=0).mean()
cands = {
    "上 5-15px":   (Y0-15, Y0-5,  X0, X1),
    "上 20-50px":  (Y0-50, Y0-20, X0, X1),
    "左 5-15px":   (Y0, Y1, X0-15, X0-5),
    "左 20-50px":  (Y0, Y1, X0-50, X0-20),
    "右 5-15px":   (Y0, Y1, X1+5, X1+15),
    "右 20-50px":  (Y0, Y1, X1+20, X1+50),
    "下 5-15px":   (Y1+5, Y1+15, X0, X1),
    "下 20-50px":  (Y1+20, Y1+50, X0, X1),
    "下 60-90px":  (Y1+60, Y1+90, X0, X1),
}
print("  %-14s %-24s %s" % ("区域", "背景均值RGB", "均匀度(std)"))
pure = []
for nm,(y0,y1,x0,x1) in cands.items():
    m, s = region_stats(y0,y1,x0,x1)
    tag = "✅纯色" if s < 12 else ("⚠️有过渡" if s < 40 else "❌圆弧/剧变")
    print("  %-14s %-24s %6.1f  %s" % (nm, str(np.round(m,1)), s, tag))
    if s < 40: pure.append((nm, y0,y1,x0,x1))

print()
print("=" * 78)
print("2) 三面净变亮复验（on−off，仅取背景均匀区域）")
print("=" * 78)
dl_pre  = pre_on.mean(axis=2) - pre_off.mean(axis=2)
dl_post = on.mean(axis=2) - off.mean(axis=2)
print("  %-14s %-18s %-22s %s" % ("区域", "修复前 Δ均值", "修复后 Δ均值", "修复后 变亮/变暗"))
print("  " + "-" * 74)
results = {}
for nm,(y0,y1,x0,x1) in cands.items():
    a = dl_pre[y0:y1, x0:x1]; b = dl_post[y0:y1, x0:x1]
    up = (b > 2).sum(); dn = (b < -2).sum()
    verdict = "✅净变亮" if b.mean() > 0 else "❌仍变暗"
    print("  %-14s %+8.2f           %+8.2f             %6d / %-6d %s" % (
        nm, a.mean(), b.mean(), up, dn, verdict))
    results[nm] = (a.mean(), b.mean(), up, dn)

print()
print("  lead 报（20~50px 环带）：上 +14.21 / 左 +5.64 / 右 +5.42")
print("  验证方实测：上 %+.2f / 左 %+.2f / 右 %+.2f" % (
    results["上 20-50px"][1], results["左 20-50px"][1], results["右 20-50px"][1]))

print()
print("=" * 78)
print("3) 修复前 vs 修复后 总览（卡片四周 60px 环带，排除圆弧）")
print("=" * 78)
ring = np.zeros((H,W), bool)
ring[Y0-60:Y0, X0:X1] = True          # 上
ring[Y0:Y1, X0-60:X0] = True          # 左
ring[Y0:Y1, X1+1:X1+61] = True        # 右
for nm, arr in [("修复前", dl_pre), ("修复后", dl_post)]:
    v = arr[ring]
    print("  %s: Δ均值 %+.2f  变亮(>2) %5d  变暗(<-2) %5d" % (nm, v.mean(), (v>2).sum(), (v<-2).sum()))

print()
print("=" * 78)
print("4) 环带色相：是否仍中性银白（B−R 个位数）")
print("=" * 78)
def halo_color(img, arr, y0,y1,x0,x1, pct=90):
    reg = img[y0:y1, x0:x1].reshape(-1,3)
    a = arr[y0:y1, x0:x1].reshape(-1)
    sel = reg[a >= np.percentile(a, pct)]
    return sel.mean(axis=0)
# 用上方区域（背景最均匀）
pts = [("上 5-15px", Y0-15,Y0-5, X0,X1), ("左 5-15px", Y0,Y1, X0-15,X0-5),
       ("右 5-15px", Y0,Y1, X1+5,X1+15)]
print("  %-14s %-22s %-10s %-10s" % ("区域", "辉光最强10% RGB", "B−R", "max−min"))
for nm,y0,y1,x0,x1 in pts:
    c = halo_color(on, dl_post, y0,y1,x0,x1)
    print("  %-14s %-22s %+8.1f %10.1f" % (nm, str(np.round(c,1)), c[2]-c[0], c.max()-c.min()))
print()
print("  AuroraSilver.glowNear = 0xF2F4F8 (242,244,248) → B−R = +6（个位数，中性偏冷银）")
print("  AuroraSilver.glowFar  = 0xE8ECF2 (232,236,242) → B−R = +10")

print()
print("=" * 78)
print("5) 卡片本体对比度：删投影后是否退化")
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
    name = brightest(img[168:198, X0+30:X1-30, :])
    bg1 = np.median(img[Y0+3:Y0+10, X0+20:X1-20, :].reshape(-1,3), axis=0)
    bg2 = np.median(img[Y1-8:Y1-3, X0+20:X1-20, :].reshape(-1,3), axis=0)
    print("  %s: 文字色=%s 顶底=%s 底底=%s" % (tag, np.round(name,1), np.round(bg1,1), np.round(bg2,1)))
    print("        对比度 文字vs顶底=%.2f:1  文字vs底底=%.2f:1" % (
        contrast(tuple(name),tuple(bg1)), contrast(tuple(name),tuple(bg2))))

print()
print("=" * 78)
print("6) 卡片几何是否因修复而变动（回归）")
print("=" * 78)
def silver_rows(img):
    mx = img.max(axis=2); mn = img.min(axis=2)
    sm = (mx-mn < 28) & (mx > 120)
    rows=[]
    for y in range(H):
        run=0; best=0
        for x in range(W):
            if sm[y,x]: run+=1; best=max(best,run)
            else: run=0
        if best>200: rows.append(y)
    return rows
r_pre, r_post = silver_rows(pre_on), silver_rows(on)
print("  修复前银白长横线行: %s" % r_pre)
print("  修复后银白长横线行: %s" % r_post)
print("  → %s" % ("✅ 卡片外框位置未变" if r_pre == r_post else "⚠️ 位置有变"))
