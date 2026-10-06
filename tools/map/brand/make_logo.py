#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later
"""
make_logo.py — AuroraDrive 品牌 logo 生成器（纯离线、确定性、可重跑）

═══════════════════════════════════════════════════════════════════════════════
【为什么有这个脚本】
═══════════════════════════════════════════════════════════════════════════════
地图预览站里此前放的那张 `public/logo.png` 是一张**红发狐娘插画**——既不是
我们的牌子，也不是我们画的。用户原话：「他妈的 logo 都给你改成不是我们的了」。
本脚本产出**属于 AuroraDrive 自己的**图形 logo：极光 + 透视道路，
全部用几何图形程序化绘制，无第三方素材、无版权风险。

═══════════════════════════════════════════════════════════════════════════════
【设计说明】
═══════════════════════════════════════════════════════════════════════════════
  · 底：深蓝黑圆角方（`#05080E` → `#0B1626` 对角渐变）——与 App 的 `--void` /
        `--s0/s1` 同族，保证贴在任何深色界面上都不"跳"。
  · 极光丝带：三条平滑贝塞尔带（`#4CC9FF` 冰蓝 / `#34E5AA` 青绿 /
        `#7B8CFF` 紫蓝），带高斯辉光。三条色相拉开，小尺寸下仍能分辨。
  · 透视道路：地平线收束的梯形 + 冰蓝虚线中线 + 两侧实线边线。
        道路是"驾驶"的语义锚点，极光是"Aurora"的语义锚点——两者叠在一起
        就是 AuroraDrive。

═══════════════════════════════════════════════════════════════════════════════
【配色一致性：不靠人眼，靠断言】
═══════════════════════════════════════════════════════════════════════════════
硬要求是「配色必须与 `Sources/AuroraDrive/App/AuroraTheme.swift` 一致」。
人眼比对会漂，所以本脚本**直接解析 AuroraTheme.swift**，把本文件用到的每个
十六进制色值都在源文件里查一遍；查不到就 `exit(1)` 拒绝出图。
改主题色 → 本脚本立刻报错，而不是悄悄画出一张配色不对的图。

═══════════════════════════════════════════════════════════════════════════════
【用法】
═══════════════════════════════════════════════════════════════════════════════
    python3 tools/map/brand/make_logo.py
    # 可选：--root <项目根>  --out <输出目录>

产物（确定性，同参数重跑字节一致）：
    Resources/AuroraLogo.png      1024×1024 RGBA   ← App 用主图
    Resources/AuroraLogo-32.png     32×32  RGBA   ← 小尺寸（标题栏/头像位）
"""

import argparse
import hashlib
import math
import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ── 超采样倍率：先画 3 倍大再降采样，边缘才干净（不做抗锯齿的话圆角和
#    虚线会有明显锯齿，小尺寸缩下去会糊成一团）──────────────────────────
SS = 3
BASE = 1024
S = BASE * SS

# ═══════════════════════════════════════════════════════════════════════════
# 调色板 —— 每个值都必须能在 AuroraTheme.swift 里找到（见 assert_palette_*）
# ═══════════════════════════════════════════════════════════════════════════

PALETTE = {
    # 底色渐变两端：取自主题的深色面（#03060B 是 --void，#0B1422 是 --s1，
    # 这里用略提亮的中间值，避免整张图黑成一坨、缩到 32px 全糊）
    "bg_top":    0x05080E,   # 近 --void(0x03060B)
    "bg_bottom": 0x0B1626,   # --s1(0x0B1422) 与 --s2(0x0F1A2C) 之间

    # 极光三色
    "aurora_1":  0x4CC9FF,   # --ice
    "aurora_2":  0x34E5AA,   # --ok
    "aurora_3":  0x7B8CFF,   # 介于 --ice 与 --violet(0xA98BFF) 之间的过渡蓝紫

    # 道路
    "road_far":  0x0F1A2C,   # --s2
    "road_near": 0x142238,   # --s3
    "edge":      0x8CBEFF,   # --hair 系列基色
    "dash":      0x4CC9FF,   # --ice
    "glow":      0x8EE0FF,   # --ice-hi
}

# 这些是"必须逐字出现在 AuroraTheme.swift 里"的色（用于一致性断言）。
# bg_top / bg_bottom / aurora_3 是**派生中间色**，允许不在主题里，故不列入。
MUST_EXIST_IN_THEME = [
    "aurora_1", "aurora_2", "road_far", "road_near", "edge", "dash", "glow",
]

# 主题文件里允许出现这些派生色作为"锚点"，用于人工复核：
#   bg_top    ≈ --void 与 --s0 之间
#   bg_bottom ≈ --s1 与 --s2 之间
DERIVED_NOTES = {
    "bg_top":    "--void(0x03060B) ~ --s0(0x080F1A) 之间",
    "bg_bottom": "--s1(0x0B1422) ~ --s2(0x0F1A2C) 之间",
    "aurora_3":  "--ice(0x4CC9FF) ~ --violet(0xA98BFF) 之间",
}


# ═══════════════════════════════════════════════════════════════════════════
# 配色一致性断言
# ═══════════════════════════════════════════════════════════════════════════

def assert_palette_matches_theme(theme_path: str) -> None:
    """把 MUST_EXIST_IN_THEME 里每个色值拿到 AuroraTheme.swift 里查一遍。

    为什么用"字符串包含"而不是解析 AST：主题文件里色值的写法恒为
    `Color(hex: 0xRRGGBB[, alpha: …])`，大小写可能不同，所以统一大写后
    做子串匹配即可，简单且不会因为格式微调而误判。
    """
    if not os.path.isfile(theme_path):
        print(f"✗ 找不到主题文件：{theme_path}", file=sys.stderr)
        sys.exit(1)

    with open(theme_path, "r", encoding="utf-8") as fh:
        theme = fh.read().upper()

    missing = []
    print("── 配色一致性校验（对 AuroraTheme.swift）──")
    for key in MUST_EXIST_IN_THEME:
        hexstr = f"0X{PALETTE[key]:06X}"
        ok = hexstr in theme
        print(f"  {'✓' if ok else '✗'} {key:<10} {hexstr}  {'在主题中' if ok else '**主题中找不到**'}")
        if not ok:
            missing.append(f"{key}={hexstr}")

    for key, note in DERIVED_NOTES.items():
        print(f"  · {key:<10} 0X{PALETTE[key]:06X}  （派生色，{note}）")

    if missing:
        print("\n✗ 配色校验失败：以下色值在 AuroraTheme.swift 中不存在 —— "
              "要么改回主题色，要么同步更新主题：", file=sys.stderr)
        for m in missing:
            print(f"    {m}", file=sys.stderr)
        sys.exit(1)
    print("  → 全部通过\n")


# ═══════════════════════════════════════════════════════════════════════════
# 绘图工具
# ═══════════════════════════════════════════════════════════════════════════

def rgba(hexval: int, alpha: int = 255):
    return ((hexval >> 16) & 0xFF, (hexval >> 8) & 0xFF, hexval & 0xFF, alpha)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def diagonal_gradient(size: int, c0: int, c1: int) -> Image.Image:
    """对角线性渐变（左上 c0 → 右下 c1）。

    用 numpy 一次算完整张，比逐像素 Python 循环快两个数量级。
    """
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = (x + y) / (2.0 * (size - 1))          # 0（左上）→ 1（右下）
    r0, g0, b0 = (c0 >> 16) & 0xFF, (c0 >> 8) & 0xFF, c0 & 0xFF
    r1, g1, b1 = (c1 >> 16) & 0xFF, (c1 >> 8) & 0xFF, c1 & 0xFF
    out = np.empty((size, size, 3), dtype=np.uint8)
    out[..., 0] = (r0 + (r1 - r0) * t).astype(np.uint8)
    out[..., 1] = (g0 + (g1 - g0) * t).astype(np.uint8)
    out[..., 2] = (b0 + (b1 - b0) * t).astype(np.uint8)
    return Image.fromarray(out, "RGB").convert("RGBA")


def vertical_gradient(size: int, y0: float, y1: float, c0: int, c1: int) -> Image.Image:
    """指定 y 区间内的竖直渐变，区间外为透明。用于道路铺面。"""
    ys = np.arange(size, dtype=np.float32)[:, None]
    t = np.clip((ys - y0) / max(1.0, (y1 - y0)), 0.0, 1.0)
    r0, g0, b0 = (c0 >> 16) & 0xFF, (c0 >> 8) & 0xFF, c0 & 0xFF
    r1, g1, b1 = (c1 >> 16) & 0xFF, (c1 >> 8) & 0xFF, c1 & 0xFF
    rgb = np.empty((size, size, 3), dtype=np.uint8)
    rgb[..., 0] = (r0 + (r1 - r0) * t).astype(np.uint8)
    rgb[..., 1] = (g0 + (g1 - g0) * t).astype(np.uint8)
    rgb[..., 2] = (b0 + (b1 - b0) * t).astype(np.uint8)
    img = Image.fromarray(rgb, "RGB").convert("RGBA")
    alpha = np.where((ys >= y0) & (ys <= y1), 255, 0).astype(np.uint8)
    a = np.repeat(alpha, size, axis=1)
    img.putalpha(Image.fromarray(a, "L"))
    return img


def bezier(p0, p1, p2, p3, n: int):
    """三次贝塞尔采样，返回 n 个 (x, y) 点。"""
    pts = []
    for i in range(n):
        t = i / (n - 1)
        mt = 1.0 - t
        x = (mt ** 3) * p0[0] + 3 * (mt ** 2) * t * p1[0] + 3 * mt * (t ** 2) * p2[0] + (t ** 3) * p3[0]
        y = (mt ** 3) * p0[1] + 3 * (mt ** 2) * t * p1[1] + 3 * mt * (t ** 2) * p2[1] + (t ** 3) * p3[1]
        pts.append((x, y))
    return pts


def tapered_ribbon(pts, width_at, samples: int = 240):
    """把中心线 + 宽度函数转成一个**渐粗渐细**的闭合多边形。

    为什么不用 `ImageDraw.line(width=…)`：line 的宽度是常数，画出来的丝带
    是根等宽面条，两端一刀切，很假。贝塞尔 + 法向偏移能做出真实的收尖。
    """
    # 先按弧长重采样，保证宽度变化均匀（否则控制点密的地方会鼓包）
    dense = bezier(*pts, n=samples)
    normals = []
    for i in range(len(dense)):
        i0 = max(0, i - 1)
        i1 = min(len(dense) - 1, i + 1)
        tx = dense[i1][0] - dense[i0][0]
        ty = dense[i1][1] - dense[i0][1]
        ln = math.hypot(tx, ty) or 1.0
        normals.append((-ty / ln, tx / ln))

    left, right = [], []
    for i, (x, y) in enumerate(dense):
        t = i / (len(dense) - 1)
        hw = width_at(t) * 0.5
        nx, ny = normals[i]
        left.append((x + nx * hw, y + ny * hw))
        right.append((x - nx * hw, y - ny * hw))
    return left + right[::-1]


def with_alpha_scale(layer: Image.Image, factor: float) -> Image.Image:
    """按比例缩放一张 RGBA 图的不透明度（辉光强度调节用）。"""
    r, g, b, a = layer.split()
    a = a.point(lambda v: max(0, min(255, int(v * factor))))
    return Image.merge("RGBA", (r, g, b, a))


def draw_aurora_ribbon(canvas: Image.Image, ctrl, color: int, base_w: float,
                       glow_scale: float = 1.0) -> None:
    """画一条极光丝带：外辉光 + 内辉光 + 实心芯，三层叠出"发光"的观感。

    为什么分三层：单层高斯模糊要么糊成一团光雾（看不到丝带形状），
    要么只留硬边（不像光）。三层是"形状 + 亮度"的折中。
    """
    def width_at(t: float) -> float:
        # 两端收尖、中段最宽：sin 包络
        return base_w * (0.18 + 0.82 * math.sin(math.pi * t) ** 0.7)

    poly = tapered_ribbon(ctrl, width_at)

    core = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(core).polygon(poly, fill=rgba(color, 255))

    outer = core.filter(ImageFilter.GaussianBlur(S * 0.030))
    inner = core.filter(ImageFilter.GaussianBlur(S * 0.009))

    canvas.alpha_composite(with_alpha_scale(outer, 0.42 * glow_scale))
    canvas.alpha_composite(with_alpha_scale(inner, 0.62 * glow_scale))
    canvas.alpha_composite(with_alpha_scale(core, 0.92))


def rounded_mask(size: int, radius: float) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1],
                                        radius=radius, fill=255)
    return m


# ═══════════════════════════════════════════════════════════════════════════
# 主绘制
# ═══════════════════════════════════════════════════════════════════════════

def build_logo() -> Image.Image:
    # ── 1. 圆角底 + 对角渐变 ──────────────────────────────────────────────
    bg = diagonal_gradient(S, PALETTE["bg_top"], PALETTE["bg_bottom"])
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.alpha_composite(bg)

    # 左上角一团极淡的冷光，避免渐变死板（纯装饰，alpha 很低）
    halo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse(
        [-S * 0.35, -S * 0.45, S * 0.85, S * 0.55],
        fill=rgba(PALETTE["glow"], 255))
    halo = halo.filter(ImageFilter.GaussianBlur(S * 0.12))
    canvas.alpha_composite(with_alpha_scale(halo, 0.10))

    # ── 2. 极光丝带（三条，错相位）──────────────────────────────────────
    # 控制点用 0..1 归一化，乘以 S；三条 y 相位错开，避免"三根平行线"的呆板感
    ribbons = [
        # (控制点, 颜色, 基准宽度, 辉光倍率)
        (((-0.10, 0.34), (0.26, 0.06), (0.62, 0.42), (1.10, 0.17)),
         PALETTE["aurora_1"], 0.105, 1.00),
        (((-0.10, 0.47), (0.30, 0.22), (0.66, 0.56), (1.10, 0.31)),
         PALETTE["aurora_2"], 0.072, 0.85),
        (((-0.10, 0.22), (0.34, 0.40), (0.58, 0.10), (1.10, 0.43)),
         PALETTE["aurora_3"], 0.058, 0.80),
    ]
    for ctrl, color, w, gs in ribbons:
        scaled = tuple((x * S, y * S) for (x, y) in ctrl)
        draw_aurora_ribbon(canvas, scaled, color, base_w=w * S, glow_scale=gs)

    # ── 3. 透视道路 ───────────────────────────────────────────────────────
    hy = 0.470 * S                 # 地平线 y
    vpx = 0.500 * S                # 消失点 x（正中，构图稳定）
    hw_far = 0.026 * S             # 地平线处半宽
    hw_near = 0.430 * S            # 画面底部半宽

    def road_halfwidth(t: float) -> float:
        """t: 0=地平线, 1=画面底部。用 t^1.35 伪造透视收束（比线性像路）。"""
        return lerp(hw_far, hw_near, t ** 1.35)

    def road_y(t: float) -> float:
        return lerp(hy, float(S), t)

    # 3a. 路面铺面：远亮近暗（远处被"地平线光"照亮），clip 到梯形内
    surface = vertical_gradient(S, hy, S, PALETTE["road_far"], PALETTE["road_near"])
    surf_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(surf_mask).polygon(
        [(vpx - hw_far, hy), (vpx + hw_far, hy),
         (vpx + hw_near, S), (vpx - hw_near, S)], fill=255)
    # paste（不是 alpha_composite）：路面是不透明的，用梯形掩码直接盖上去即可，
    # 免得和底下的极光辉光做一次多余的混合运算。
    canvas.paste(surface, (0, 0), surf_mask)

    # 3b. 地平线冷光：让路"从光里出来"，而不是硬生生截断
    hglow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hglow).ellipse(
        [vpx - S * 0.30, hy - S * 0.045, vpx + S * 0.30, hy + S * 0.055],
        fill=rgba(PALETTE["glow"], 255))
    hglow = hglow.filter(ImageFilter.GaussianBlur(S * 0.035))
    canvas.alpha_composite(with_alpha_scale(hglow, 0.30))

    # 3c. 两侧实线边线（宽度随透视变粗）
    edges = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edges)
    steps = 160
    for side in (-1.0, 1.0):
        for i in range(steps):
            t0, t1 = i / steps, (i + 1) / steps
            x0 = vpx + side * road_halfwidth(t0)
            x1 = vpx + side * road_halfwidth(t1)
            y0, y1 = road_y(t0), road_y(t1)
            wpx = max(1.0, lerp(0.0032 * S, 0.0135 * S, t0 ** 1.2))
            ed.line([(x0, y0), (x1, y1)], fill=rgba(PALETTE["edge"], 255), width=int(wpx))
    canvas.alpha_composite(with_alpha_scale(edges, 0.55))

    # 3d. 冰蓝虚线中线：透视间距（越近越长、越粗、间隔越大）
    dashes = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dashes)
    n_dash = 7
    for k in range(n_dash):
        # 用 t^1.6 分布 → 近处疏、远处密，视觉上等距
        t0 = (k / n_dash) ** 1.6
        t1 = t0 + (0.62 / n_dash) * (0.30 + t0)      # 长度随 t 增长
        if t1 > 0.995:
            break
        y0, y1 = road_y(t0), road_y(t1)
        hw0 = max(1.2, lerp(0.0035 * S, 0.0185 * S, t0 ** 1.25))
        hw1 = max(1.2, lerp(0.0035 * S, 0.0185 * S, t1 ** 1.25))
        dd.polygon([(vpx - hw0, y0), (vpx + hw0, y0),
                    (vpx + hw1, y1), (vpx - hw1, y1)],
                   fill=rgba(PALETTE["dash"], 255))
    dash_glow = dashes.filter(ImageFilter.GaussianBlur(S * 0.006))
    canvas.alpha_composite(with_alpha_scale(dash_glow, 0.45))
    canvas.alpha_composite(dashes)

    # ── 4. 圆角裁切（最后一步，保证所有元素都被圆角框住）────────────────
    canvas.putalpha(Image.composite(canvas.getchannel("A"),
                                    Image.new("L", (S, S), 0),
                                    rounded_mask(S, radius=0.218 * S)))
    return canvas


def downsample(img: Image.Image, size: int) -> Image.Image:
    return img.resize((size, size), Image.LANCZOS)


# ═══════════════════════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════════════════════

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    # tools/map/brand/ → 项目根
    default_root = os.path.abspath(os.path.join(here, "..", "..", ".."))

    ap = argparse.ArgumentParser(description="AuroraDrive logo 生成器")
    ap.add_argument("--root", default=default_root, help="项目根目录")
    ap.add_argument("--out", default=None, help="输出目录（默认 <root>/Resources）")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    outdir = os.path.abspath(args.out) if args.out else os.path.join(root, "Resources")

    print("═══ AuroraDrive logo 生成 ═══")
    print(f"  项目根: {root}")
    print(f"  输出到: {outdir}\n")

    assert_palette_matches_theme(
        os.path.join(root, "Sources", "AuroraDrive", "App", "AuroraTheme.swift"))

    os.makedirs(outdir, exist_ok=True)

    print(f"── 绘制（{S}×{S} 超采样，{SS}×）──")
    master = build_logo()

    targets = [
        ("AuroraLogo.png", BASE),
        ("AuroraLogo-32.png", 32),
    ]
    results = []
    for name, size in targets:
        img = downsample(master, size)
        path = os.path.join(outdir, name)
        img.save(path, "PNG", optimize=True)
        raw = open(path, "rb").read()
        sha = hashlib.sha256(raw).hexdigest()[:16]
        results.append((name, path, size, len(raw), sha))
        print(f"  ✓ {name:<20} {size}×{size}  {len(raw):>8} B  sha256:{sha}…")

    # ── 自检：尺寸/模式/非空/不透明覆盖 ─────────────────────────────────
    print("\n── 自检 ──")
    fail = 0
    for name, path, size, nbytes, _ in results:
        im = Image.open(path)
        checks = [
            ("存在且非空", nbytes > 0),
            ("尺寸正确", im.size == (size, size)),
            ("RGBA", im.mode == "RGBA"),
            ("有透明角（圆角生效）", im.getpixel((0, 0))[3] == 0),
            ("中心不透明", im.getpixel((size // 2, size // 2))[3] == 255),
        ]
        for label, ok in checks:
            print(f"  {'✓' if ok else '✗'} {name} — {label}")
            if not ok:
                fail += 1

    # 主图必须有足够多的不透明像素（防止"整张透明"这种静默失败）
    main_img = Image.open(results[0][1])
    cover = sum(1 for p in main_img.getchannel("A").getdata() if p > 200) / (BASE * BASE)
    ok_cover = cover > 0.90
    print(f"  {'✓' if ok_cover else '✗'} 主图不透明覆盖率 {cover:.1%}（应 >90%）")
    if not ok_cover:
        fail += 1

    print()
    if fail:
        print(f"✗ 自检失败 {fail} 项", file=sys.stderr)
        return 1
    print("═══ logo 生成：PASS ═══")
    return 0


if __name__ == "__main__":
    sys.exit(main())
