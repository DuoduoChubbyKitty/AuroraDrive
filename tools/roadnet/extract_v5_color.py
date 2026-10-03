#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_v5.py —— 颜色（灰阶）提取版路网
用户指出：我标的暗黑路是灰阶 38，V3 阈值 >45 把它整条扔了。

策略：不做"阈值"，做"颜色桶"——把原图上指定灰阶的所有像素全捞出来，
按连通域 + 长度过滤，拼成一张白线图。
"""
import os, sys, json
import numpy as np
import cv2

MAP = 'models/bigworldmap-13056.jpg'
OUTDIR = 'docs/roadnet'
M_PER_PX = 0.61          # 原生 13056 分辨率下 1px ≈ 0.61m

# 灰阶桶定义：暗黑路系 / 亮白路系
BUCKETS = {
    'dark':  (36, 40),   # ★ 用户标的暗黑路：中心 38
    'dark2': (30, 40),   # 更宽的暗路系
    'bright': (80, 90),  # 亮白主干道
}


def conn_filter(mask, min_px):
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    keep = np.zeros(n, bool)
    keep[1:] = stats[1:, cv2.CC_STAT_AREA] >= min_px
    return keep[lab].astype(np.uint8)


def skeleton_len_px(mask):
    """骨架长度（px）—— cv2.ximgproc 没有就用形态学细化降级"""
    try:
        from skimage.morphology import skeletonize
        sk = skeletonize(mask > 0)
    except Exception:
        sk = cv2.ximgproc.thinning((mask * 255).astype(np.uint8)) > 0
    return int(sk.sum()), sk


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    print(f'═══ 读原生底图 {MAP} ═══', flush=True)
    g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    H, W = g.shape
    print(f'  {W}x{H}', flush=True)

    total = g.size
    result = {}
    for name, (lo, hi) in BUCKETS.items():
        m = ((g >= lo) & (g <= hi)).astype(np.uint8)
        raw_px = int(m.sum())
        if raw_px == 0:
            print(f'[{name}] {lo}-{hi}: 空')
            continue
        # 连通域过滤：原生 >= 15px 才留（和 V3 同标准）
        m = conn_filter(m, 15)
        px = int(m.sum())
        sk_px, sk = skeleton_len_px(m)
        km = sk_px * M_PER_PX / 1000.0
        n2, lab2, st2, _ = cv2.connectedComponentsWithStats(m, 8)
        areas = np.sort(st2[1:, cv2.CC_STAT_AREA])[::-1] if n2 > 1 else np.array([0])
        result[name] = dict(lo=lo, hi=hi, raw_px=raw_px, px=px, sk_px=sk_px,
                            km=round(km, 1), comps=int(n2 - 1),
                            largest=int(areas[0]) if len(areas) else 0)
        print(f'[{name}] 灰阶 {lo}-{hi}: 原像素 {raw_px} ({raw_px/total*100:.3f}%) '
              f'→ 过滤后 {px} 连通域 {n2-1} 最大 {result[name]["largest"]} '
              f'骨架 {sk_px}px = {km:.1f} km', flush=True)

    # ── 渲染：白线黑底 + 白线压底图 ──
    base_name = sys.argv[1] if len(sys.argv) > 1 else 'dark'
    lo, hi = BUCKETS[base_name]
    m = conn_filter(((g >= lo) & (g <= hi)).astype(np.uint8), 15)
    wh = (m * 255).astype(np.uint8)

    black = np.zeros((H, W, 3), np.uint8)
    black[m > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUTDIR}/v5_{base_name}_白线黑底.png', black)

    over = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    over[m > 0] = (0, 0, 255)          # BGR 红
    cv2.imwrite(f'{OUTDIR}/v5_{base_name}_红压原图.png', over)

    # 缩略总览
    s = 2
    cv2.imwrite(f'{OUTDIR}/v5_{base_name}_总览.png',
                cv2.resize(black, (W // s, H // s), interpolation=cv2.INTER_AREA))

    with open(f'{OUTDIR}/v5_report.json', 'w') as f:
        json.dump(result, f, indent=1, ensure_ascii=False)
    print('写出 →', OUTDIR, flush=True)


if __name__ == '__main__':
    main()
