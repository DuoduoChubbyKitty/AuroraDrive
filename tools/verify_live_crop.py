#!/usr/bin/env python3
# ============================================================================
# verify_live_crop.py — 一比一复刻 AuroraDrive/SpeedOCRReader.cropSlots 的
# 「实跑全屏直裁」逻辑，用于在不重跑游戏的前提下，定位实跑 OCR 为什么读不到速度表。
#
# 关键：Swift 侧用的是 CIImage（原点左下、y 向上），cropSlots 做了 y 镜像
#   ciRect.y = sh - yMax，等价于 PIL（原点左上、y 向下）直接裁视觉区域
#   [yMin, yMax]（从顶部数）。本脚本用 PIL 左上方直接裁同一视觉区域，
#   与 Swift 产出的像素完全一致（已用合成全屏图 + 模板匹配自测验证）。
#
# 用法：
#   python3 tools/verify_live_crop.py --selftest
#       生成合成全屏图（速度表画在标定位置），跑完整识别，应读对。
#   python3 tools/verify_live_crop.py /path/to/fullscreen.png
#       对你发来的全屏截图跑实跑裁切，输出 3 个槽位裁图 + fg 计数 + 识别速度。
#       裁图存到 /tmp/aurora_ocr_crop_slot{0,1,2}.png，可肉眼看裁到没裁到。
# ============================================================================
import json
import math
import os
import sys
from PIL import Image, ImageDraw

# ── 与 SpeedOCRReader.swift 完全一致的槽位常量 ──
SLOT_CENTERS_NORM = [0.479, 0.496, 0.512]
SLOT_WIDTH_NORM = 0.014
SLOT_Y_MIN_NORM = 0.897
SLOT_Y_MAX_NORM = 0.932
TEMPLATE_H = 45
TEMPLATE_W = 25

MODELS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models")
GLYPH_JSON = os.path.join(MODELS_DIR, "speed_glyphs.json")


def round_even(x: float) -> int:
    # Swift 的 .rounded(.toNearestOrEven) == Python round()（银行家舍入）
    return int(round(x))


def load_glyphs():
    if not os.path.exists(GLYPH_JSON):
        print(f"✗ 找不到字模库 {GLYPH_JSON}")
        return {}
    with open(GLYPH_JSON) as f:
        lib = json.load(f)
    out = {}
    for k, rows in lib["templates"].items():
        flat = [1 if v else 0 for row in rows for v in row]
        if len(flat) == TEMPLATE_H * TEMPLATE_W:
            out[k] = flat
    return out


def otsu_binary(gray):
    """灰度(0-255 list) → 二值 0/1 list；gray>thr 视为前景(亮=笔画)。与 Swift binarizeOtsu 一致。"""
    hist = [0] * 256
    for v in gray:
        hist[v] += 1
    total = len(gray)
    levels = sum(1 for h in hist if h > 0)
    if levels < 2:
        return [0] * total
    sum_all = sum(i * hist[i] for i in range(256))
    sum_b = w_b = var_max = thr = 0
    for t in range(256):
        w_b += hist[t]
        if w_b == 0:
            continue
        w_f = total - w_b
        if w_f == 0:
            break
        sum_b += t * hist[t]
        m_b = sum_b / w_b
        m_f = (sum_all - sum_b) / w_f
        v = w_b * w_f * (m_b - m_f) ** 2
        if v > var_max:
            var_max = v
            thr = t
    return [1 if g > thr else 0 for g in gray]


def resize_nearest(src, sh, sw, dh, dw):
    """最近邻缩放（与 Swift resizeNearest 同源：linspace 取整）。src row-major。"""
    out = []
    for y in range(dh):
        sy = 0 if dh == 1 else (sh - 1 if y == dh - 1 else int(y * (sh - 1) / (dh - 1)))
        for x in range(dw):
            sx = 0 if dw == 1 else (sw - 1 if x == dw - 1 else int(x * (sw - 1) / (dw - 1)))
            out.append(src[sy * sw + sx])
    return out


def crop_slots_pil(img: Image.Image):
    """复刻 Swift cropSlots（无 roiNorm 的实跑路径）。返回 [PIL.Image]×3 + [fg]×3。
    PIL 原点左上，直接裁视觉区域 [yMin,yMax]（从顶部数），等价 Swift 的 y 镜像裁切。"""
    W, H = img.size
    gray_img = img.convert("L")
    slots = []
    fgs = []
    for ci in range(3):
        cx = round_even(SLOT_CENTERS_NORM[ci] * W)
        half_w = round_even(SLOT_WIDTH_NORM / 2.0 * W)
        y_min = round_even(SLOT_Y_MIN_NORM * H)
        y_max = round_even(SLOT_Y_MAX_NORM * H)
        left = cx - half_w
        right = cx + half_w
        top = y_min
        bottom = y_max
        # 防御：越界则整体返回 None（与 Swift 行为一致）
        if left < 0 or top < 0 or right > W or bottom > H or right <= left or bottom <= top:
            return None
        crop = gray_img.crop((left, top, right, bottom))
        slots.append(crop)
        g = list(crop.getdata())
        binv = otsu_binary(g)
        fgs.append(sum(binv))
    return slots, fgs


def match_speed(slot_binaries, glyphs):
    """0~300 三位数整体匹配（与 Swift matchSpeed 同源：±1 抖动投票 + 残差和最小）。"""
    def cost_slot(bin_src):
        best = []
        for d in range(10):
            tmpl = glyphs.get(str(d))
            if tmpl is None:
                best.append(float("inf"))
                continue
            local = float("inf")
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    local = min(local, residual_shifted(bin_src, tmpl, dy, dx))
            best.append(local)
        return best

    cost = [cost_slot(b) for b in slot_binaries]
    best_speed = 0
    best_dist = float("inf")
    for v in range(0, 301):
        d0, d1, d2 = v // 100, (v // 10) % 10, v % 10
        dist = cost[0][d0] + cost[1][d1] + cost[2][d2]
        if dist < best_dist:
            best_dist = dist
            best_speed = v
    area = TEMPLATE_H * TEMPLATE_W * 3
    limit = 0.30 * area
    if best_dist > limit:
        return None, best_dist
    return best_speed, best_dist


def residual_shifted(bin_src, tmpl, dy, dx):
    h = w = TEMPLATE_H  # 模板为 25×45，但本简化按 H=W=45? 实际 45×25
    # 注意：模板是 TEMPLATE_H(45) 行 × TEMPLATE_W(25) 列
    H, W = TEMPLATE_H, TEMPLATE_W
    r0 = max(0, -dy); r1 = min(H, H - dy)
    c0 = max(0, -dx); c1 = min(W, W - dx)
    if r1 <= r0 or c1 <= c0:
        return H * W
    diff = 0
    for r in range(r0, r1):
        br = r * W + c0
        tr = (r + dy) * W + c0 + dx
        for k in range(c1 - c0):
            if bin_src[br + k] != tmpl[tr + k]:
                diff += 1
    return diff


def make_synthetic_fullframe(speed_str: str, glyphs, W=2940, H=1912):
    """合成全屏图：黑底，在标定槽位画亮色数字（亮=前景，匹配游戏 HUD）。"""
    img = Image.new("L", (W, H), 0)
    draw = ImageDraw.Draw(img)
    for ci, ch in enumerate(speed_str):
        tmpl = glyphs.get(ch)
        if tmpl is None:
            continue
        # 槽位像素盒（与 crop_slots_pil 完全一致）
        cx = round_even(SLOT_CENTERS_NORM[ci] * W)
        half_w = round_even(SLOT_WIDTH_NORM / 2.0 * W)
        y_min = round_even(SLOT_Y_MIN_NORM * H)
        y_max = round_even(SLOT_Y_MAX_NORM * H)
        left, right = cx - half_w, cx + half_w
        top, bottom = y_min, y_max
        cw, chh = right - left, bottom - top
        # 把 25×45 模板最近邻放大到 (cw, chh)
        for y in range(chh):
            sy = 0 if chh == 1 else int(y * (TEMPLATE_H - 1) / (chh - 1))
            for x in range(cw):
                sx = 0 if cw == 1 else int(x * (TEMPLATE_W - 1) / (cw - 1))
                if tmpl[sy * TEMPLATE_W + sx] == 1:
                    draw.point((left + x, top + y), fill=255)
    return img


def run_on_image(img: Image.Image, label=""):
    res = crop_slots_pil(img)
    if res is None:
        print(f"[{label}] ✗ 裁切越界（槽位常量与图尺寸不匹配）")
        return
    slots, fgs = res
    fg_total = sum(fgs)
    print(f"[{label}] 原生尺寸={img.size[0]}x{img.size[1]}  "
          f"3槽前景像素 fg={fgs} 合计={fg_total}  "
          f"无效阈值=80 {'→ 判无效(画面无速度表)' if fg_total < 80 else '→ 进入匹配'}")
    for ci, s in enumerate(slots):
        s.save(f"/tmp/aurora_ocr_crop_slot{ci}.png")
    if fg_total < 80:
        print(f"[{label}] 裁到的不是数字（落在暗部/桌面），裁图见 /tmp/aurora_ocr_crop_slot*.png")
        return
    slot_bin = []
    for s in slots:
        g = list(s.getdata())
        b = otsu_binary(g)
        slot_bin.append(resize_nearest(b, s.size[1], s.size[0], TEMPLATE_H, TEMPLATE_W))
    speed, dist = match_speed(slot_bin, load_glyphs())
    if speed is None:
        print(f"[{label}] 残差={dist:.0f} 超阈值，无法识别")
    else:
        print(f"[{label}] ✓ 识别速度={speed:03d} 残差={dist:.0f}")


def main():
    glyphs = load_glyphs()
    if not glyphs:
        print("字模库为空，无法匹配（仅能看裁切位置）")
    args = sys.argv[1:]
    if args and args[0] == "--selftest":
        print("== 合成全屏自测（速度表画在标定位置）==")
        for sp in ["000", "055", "016", "175", "300"]:
            img = make_synthetic_fullframe(sp, glyphs)
            run_on_image(img, f"合成 {sp}")
        return
    if not args:
        print("用法: verify_live_crop.py [--selftest | /path/to/fullscreen.png]")
        return
    path = args[0]
    if not os.path.exists(path):
        print(f"✗ 文件不存在: {path}")
        return
    img = Image.open(path).convert("RGB").convert("L")
    run_on_image(img, os.path.basename(path))


if __name__ == "__main__":
    main()
