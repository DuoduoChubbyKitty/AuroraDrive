#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_v5_final.py —— V5 最终版（亮路主干网 ∪ 用户标注的暗色车道线）

★ 教训（用户 2026-10-03 15:0x 骂的）：
  上一版 V5 最后一步写成"只留 >=60 的主干连通域"，
  等于把用户亲手标出来的灰阶 38 车道线又整条扔了。
  → V5 必须是【并集】：亮路主干网 + 暗色车道线。

分两路建层：
  A 亮路主干网 : >=60  → 连通域过滤 → 闭运算 → 最大连通域
  B 暗色车道线 : ==38  → 连通域过滤 → 骨架过滤（这条是用户标的那条）
  V5 = A ∪ B

颜色约定（和浏览器一致）：
  亮路  #ff4d4d 红
  暗线  #ffd400 黄
"""
import os, sys, json
import numpy as np
import cv2
from skimage.morphology import skeletonize

MAP = 'models/bigworldmap-13056.jpg'
OUT = 'docs/roadnet/v5'
M_PER_PX = 0.61

BRIGHT_LO = int(os.environ.get('V5_BRIGHT_LO', 60))
DARK_V = int(os.environ.get('V5_DARK_V', 38))
MIN_AREA = int(os.environ.get('V5_MIN_AREA', 15))
MIN_SKEL = int(os.environ.get('V5_MIN_SKEL', 25))
CLOSE_K = int(os.environ.get('V5_CLOSE_K', 7))
KEEP_MAIN = os.environ.get('V5_KEEP_MAIN', '1') == '1'

os.makedirs(OUT, exist_ok=True)


def skel_px(m):
    return int(skeletonize(m > 0).sum())


def clean(mask, name):
    n, lab, st, _ = cv2.connectedComponentsWithStats(mask, 8)
    keep = np.zeros(n, bool)
    ds = db = 0
    rows = []
    for i in range(1, n):
        x, y, w, h, area = st[i]
        if area < MIN_AREA:
            ds += 1
            continue
        sub = (lab[y:y + h, x:x + w] == i).astype(np.uint8)
        s = skel_px(sub)
        if s < MIN_SKEL:
            ds += 1
            continue
        keep[i] = True
        rows.append((int(area), s))
    rows.sort(reverse=True)
    print(f'  [{name}] 成分 {n-1} → 保留 {int(keep.sum())}（丢碎点 {ds}）', flush=True)
    for a, s in rows[:5]:
        print(f'      area {a:>8d} skel {s:>7d}', flush=True)
    return keep[lab].astype(np.uint8)


def main():
    print('═══ 读原生底图 ═══', flush=True)
    g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    H, W = g.shape
    print(f'  {W}x{H}', flush=True)
    np.save('/tmp/v5f_gray.npy', g)

    # ── A 亮路主干网 ──
    print(f'═══ A 亮路主干网 >= {BRIGHT_LO} ═══', flush=True)
    A = clean((g >= BRIGHT_LO).astype(np.uint8), 'bright')
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (CLOSE_K, CLOSE_K))
    A = cv2.morphologyEx(A, cv2.MORPH_CLOSE, k)
    del k
    if KEEP_MAIN:
        n, lab, st, _ = cv2.connectedComponentsWithStats(A, 8)
        big = int(np.argmax(st[1:, cv2.CC_STAT_AREA])) + 1
        print(f'  主干成分 {int(st[big,cv2.CC_STAT_AREA])} px / 共 {n-1}', flush=True)
        A = (lab == big).astype(np.uint8)
        del lab
    sA = skel_px(A)
    print(f'  A 骨架 {sA}px = {sA*M_PER_PX/1000:.1f} km', flush=True)

    # ── B 用户标注的暗色车道线 ──
    print(f'═══ B 暗色车道线 == {DARK_V} ═══', flush=True)
    B = clean((g == DARK_V).astype(np.uint8), 'dark')
    kB = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    B = cv2.morphologyEx(B, cv2.MORPH_CLOSE, kB)
    del kB
    sB = skel_px(B)
    print(f'  B 骨架 {sB}px = {sB*M_PER_PX/1000:.1f} km', flush=True)

    # ── V5 = A ∪ B ──
    print('═══ V5 = A ∪ B ═══', flush=True)
    V5 = ((A > 0) | (B > 0)).astype(np.uint8)
    s5 = skel_px(V5)
    n5, lab5, st5, _ = cv2.connectedComponentsWithStats(V5, 8)
    print(f'★ V5 骨架 {s5}px = {s5*M_PER_PX/1000:.1f} km  成分 {n5-1}', flush=True)

    # 用户笔画带覆盖率
    sp = '/Users/dupi/Desktop/road_patch_20261003_141553.png'
    stroke_cov = None
    if os.path.exists(sp):
        im = cv2.imread(sp, cv2.IMREAD_UNCHANGED)
        Ar = cv2.resize((im[:, :, 3] > 0).astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST)
        Kb = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
        band = cv2.dilate(Ar, Kb)
        del Kb, Ar
        V5d = cv2.dilate(V5, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
        stroke_cov = float((band & V5d).sum()) / float(band.sum())
        print(f'  你的笔画带覆盖率 {stroke_cov*100:.1f}%', flush=True)
        del band, V5d
        del im

    # ── 渲染 ──
    print('═══ 渲染 ═══', flush=True)
    w = np.zeros((H, W, 3), np.uint8)
    w[A > 0] = (255, 255, 255)
    w[B > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5_白线黑底_全域.png', w)
    cv2.imwrite(f'{OUT}/V5_白线黑底.png',
                cv2.resize(w, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    del w
    base = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    over = base.copy()
    over[A > 0] = (77, 77, 255)     # BGR 红 = 亮路
    over[B > 0] = (0, 212, 255)     # BGR 黄 = 暗色车道线（你标的）
    cv2.imwrite(f'{OUT}/V5_交付_红亮路_黄暗线_压原图.png',
                cv2.resize(over, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    cv2.imwrite(f'{OUT}/V5_交付_红亮路_黄暗线_压原图_全域.png', over)
    del over, base

    # 三联
    g2 = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    base2 = cv2.cvtColor(g2, cv2.COLOR_GRAY2BGR)
    sc = 3
    def th(i): return cv2.resize(i, (W // sc, H // sc), interpolation=cv2.INTER_AREA)
    ww = np.zeros((H, W, 3), np.uint8)
    ww[A > 0] = (255, 255, 255); ww[B > 0] = (255, 255, 255)
    mm = base2.copy(); mm[A > 0] = (77, 77, 255); mm[B > 0] = (0, 212, 255)
    t1 = th(base2); t2 = th(ww); t3 = th(mm)
    for t, s in (('原图', t1), ('V5 白线', t2), ('V5 红=亮路 黄=暗线', t3)):
        cv2.putText(s, t, (30, 80), cv2.FONT_HERSHEY_SIMPLEX, 2.6, (0, 0, 255), 7)
    cv2.imwrite(f'{OUT}/V5_交付_三联.png', np.hstack([t1, t2, t3]))
    del ww, mm, base2, g2

    # 暗线单层（用户想看的那条）
    bw = np.zeros((H, W, 3), np.uint8); bw[B > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5_暗色车道线_单层.png', cv2.resize(bw, (W // 2, H // 2),
                                                       interpolation=cv2.INTER_AREA))
    del bw
    bb = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    bb[B > 0] = (0, 212, 255)
    cv2.imwrite(f'{OUT}/V5_暗色车道线_压原图.png', cv2.resize(bb, (W // 2, H // 2),
                                                      interpolation=cv2.INTER_AREA))
    del bb, g

    json.dump({'bright_lo': BRIGHT_LO, 'dark_v': DARK_V, 'close_k': CLOSE_K,
               'A_km': round(sA * M_PER_PX / 1000, 1),
               'B_km': round(sB * M_PER_PX / 1000, 1),
               'V5_km': round(s5 * M_PER_PX / 1000, 1),
               'V5_comps': int(n5 - 1),
               'stroke_cov': None if stroke_cov is None else round(stroke_cov, 4)},
              open(f'{OUT}/V5_report.json', 'w'), indent=1, ensure_ascii=False)
    print('  →', OUT, flush=True)


if __name__ == '__main__':
    main()
