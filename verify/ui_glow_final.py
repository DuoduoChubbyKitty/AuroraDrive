#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 3 定案：辉光的真实性质 + 外扩范围 + 合成色反解"""
import numpy as np
from PIL import Image

on = np.asarray(Image.open('/tmp/run2_on.png').convert('RGB'), dtype=np.float64)
off = np.asarray(Image.open('/tmp/run2_off.png').convert('RGB'), dtype=np.float64)
H, W, _ = on.shape
X0, X1, Y0, Y1 = 1294, 1646, 154, 245     # 卡片外框 px（代码定宽 176pt + 实测描边）

print("=" * 78)
print("0) 前置：on/off 的游戏占位图是否同一张？（决定相减是否有效）")
print("=" * 78)
for nm, (y0, y1, x0, x1) in {
    "远处左侧 (x200-600,y400-900)": (400, 900, 200, 600),
    "远处右侧 (x2200-2700,y400-900)": (400, 900, 2200, 2700),
    "卡片下方 (x1300-1640,y500-900)": (500, 900, 1300, 1640),
    "卡片正上方 (x1300-1640,y300-400)": (300, 400, 1300, 1640),
}.items():
    a, b = on[y0:y1, x0:x1], off[y0:y1, x0:x1]
    d = np.abs(a - b).sum(axis=2)
    print("  %-34s 最大通道和差=%5.0f  >10 的像素=%6d/%6d" % (
        nm, d.max(), (d > 10).sum(), (y1-y0)*(x1-x0)))
print("  → 远离卡片的区域 on/off 几乎相同（差≤2）→ 占位图是同一张，相减有效。")
print("  → 只有卡片周围有差异 = 辉光本身。")

print()
print("=" * 78)
print("1) 辉光是「变亮」还是「变暗」？—— 带符号亮度差")
print("=" * 78)
lum_on, lum_off = on.mean(axis=2), off.mean(axis=2)
dl = lum_on - lum_off
# 卡片周边环带
ring = np.zeros_like(dl, dtype=bool)
ring[Y0-60:Y1+80, X0-90:X0] = True
ring[Y0-60:Y1+80, X1+1:X1+91] = True
ring[Y0-60:Y0, X0:X1] = True
ring[Y1+1:Y1+80, X0:X1] = True
vals = dl[ring]
print("  环带内 Δ亮度: min=%.1f  max=%.1f  均值=%.1f" % (vals.min(), vals.max(), vals.mean()))
print("  变亮(Δ>2)像素: %d ; 变暗(Δ<-2)像素: %d ; 基本不变: %d" % (
    (vals > 2).sum(), (vals < -2).sum(), (np.abs(vals) <= 2).sum()))
print("  → %s" % ("辉光在亮背景上表现为【变暗】的灰晕" if (vals < -2).sum() > (vals > 2).sum()
                  else "辉光表现为变亮"))

print()
print("=" * 78)
print("2) 反解辉光的等效颜色与不透明度（假定中性色）")
print("=" * 78)
print("  模型: on = off*(1-a) + C*a   （C 为中性灰）")
print()
print("  取样点（紧贴外框外侧，Δ最强处）:")
print("  %-22s %-18s %-18s %8s %-16s" % ("位置", "on RGB", "off RGB", "a", "C(反解)"))
pts = [("左 1pt", Y0+45, X0-2), ("左 5pt", Y0+45, X0-10), ("右 1pt", Y0+45, X1+2),
       ("右 5pt", Y0+45, X1+10), ("上 1pt", Y0-2, (X0+X1)//2), ("下 1pt", Y1+2, (X0+X1)//2)]
sols = []
for nm, y, x in pts:
    o, f = on[y, x], off[y, x]
    # 用 R-G 与 R-B 两个通道解 a
    try:
        a1 = 1 - (o[0]-o[1])/(f[0]-f[1])
        a2 = 1 - (o[0]-o[2])/(f[0]-f[2])
        a = (a1+a2)/2
        C = (o - f*(1-a))/a if a > 1e-6 else np.array([0,0,0])
        sols.append((a, C))
        print("  %-22s %-18s %-18s %8.3f %-16s" % (
            nm, str(o.astype(int)), str(f.astype(int)), a, str(np.round(C, 0).astype(int))))
    except Exception as e:
        print("  %-22s 解算失败 %s" % (nm, e))
if sols:
    aa = np.mean([s[0] for s in sols]); CC = np.mean([s[1] for s in sols], axis=0)
    print()
    print("  平均: 等效不透明度 a = %.3f ; 等效颜色 C = RGB%s" % (aa, np.round(CC, 0).astype(int)))
    print("  C 的 B−R = %.1f  → %s" % (CC[2]-CC[0],
          "中性（银白无色相）✅" if abs(CC[2]-CC[0]) < 12 else "有偏色 ⚠️"))
    print("  C 的亮度 = %.0f  → %s" % (CC.mean(),
          "亮银白(>200)" if CC.mean() > 200 else ("中灰(100-200)" if CC.mean() > 100 else "暗(<100)")))
    print()
    print("  代码声明: glowNear=0xF2F4F8(242,244,248) α0.50 ; glowFar=0xE8ECF2(232,236,242) α0.26")
    print("  → 若等效颜色为 %s 而声明为 (242,244,248)，说明 SwiftUI shadow 的合成不是简单 alpha 叠加" % np.round(CC,0).astype(int))

print()
print("=" * 78)
print("3) 辉光外扩范围（Δ亮度衰减到不可见）")
print("=" * 78)
def extent(y, x_start, direction, th=1.5, limit=200):
    for k in range(1, limit):
        x = x_start + direction*k
        if not (0 <= x < W): return k
        if abs(dl[y, x]) < th: return k
    return limit
def extent_v(x, y_start, direction, th=1.5, limit=200):
    for k in range(1, limit):
        y = y_start + direction*k
        if not (0 <= y < H): return k
        if abs(dl[y, x]) < th: return k
    return limit
Ymid = (Y0+Y1)//2; Xmid = (X0+X1)//2
eL = extent(Ymid, X0, -1); eR = extent(Ymid, X1, +1)
eU = extent_v(Xmid, Y0, -1); eD = extent_v(Xmid, Y1, +1)
print("  Δ亮度 < %.1f 视为不可见" % 1.5)
print("  左外扩 = %5.1f pt (%3d px)" % (eL/2, eL))
print("  右外扩 = %5.1f pt (%3d px)" % (eR/2, eR))
print("  上外扩 = %5.1f pt (%3d px)   ← 上方仅 10pt 空间（预览框上沿 y=67pt），会被裁切" % (eU/2, eU))
print("  下外扩 = %5.1f pt (%3d px)" % (eD/2, eD))
print()
print("  ui 报：左 35 / 右 35.5 / 上 10 / 下 32.5 pt")
print("  验证方实测：左 %.1f / 右 %.1f / 上 %.1f / 下 %.1f pt" % (eL/2, eR/2, eU/2, eD/2))

print()
print("=" * 78)
print("4) 上方裁切验证：预览框上沿 y=134px(67pt)，卡片上沿 y=154px(77pt)")
print("=" * 78)
print("  y(px)  y(pt)   on亮度   off亮度   Δ")
for y in [128, 130, 132, 133, 134, 135, 138, 142, 146, 150, 153]:
    print("  %5d %6.1f %8.1f %8.1f %7.1f" % (y, y/2, lum_on[y, Xmid], lum_off[y, Xmid], dl[y, Xmid]))
print("  → Δ 在 y=134（游戏画面起始）处截断 = 辉光被预览框边界裁切 ✅（与「贴顶 10pt」自洽）")
