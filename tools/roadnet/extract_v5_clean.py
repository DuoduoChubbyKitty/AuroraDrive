#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_v5_clean.py —— V5 清洗版（第二版，判据换成灰阶分带）

★ 关键发现（原生 13056 实测）：
  亮路   : >=60   → 最大连通域占 97.4%，只有 1015 个成分  = 真路网
  楼(实心): 43-48 → 1153 个 >=100px 的方形块             = 要踢掉的
  楼影/暗路: 36-40 → 76577 个碎片                        = 要踢掉的
  V3 用 >45 → 最大块只占 78.3%、1276 个碎片 = 楼全吞进来了

用户三项要求：
  ① 稀稀拉拉的小点    → 面积/骨架长过滤
  ② 没连主干道的楼块  → 亮路用 >=60 天然排除楼
  ③ 裂缝闭合          → 小核闭运算，不糊路

判据：
  MAIN_LO   : 亮路下限（默认 60）
  MIN_AREA  : 成分最小面积
  MIN_SKEL  : 成分最小骨架长
  CLOSE_K   : 闭运算核
  KEEP_MAIN : 只保留最大主干连通域
"""
import os, sys, json
import numpy as np
import cv2
from skimage.morphology import skeletonize

MAP = 'models/bigworldmap-13056.jpg'
OUT = 'docs/roadnet/v5'
M_PER_PX = 0.61

MAIN_LO = int(os.environ.get('V5_MAIN_LO', 60))       # ★ 亮路下限
DARK_V = int(os.environ.get('V5_DARK_V', 0))          # 0=不加暗路
MIN_AREA = int(os.environ.get('V5_MIN_AREA', 60))
MIN_SKEL = int(os.environ.get('V5_MIN_SKEL', 30))
CLOSE_K = int(os.environ.get('V5_CLOSE_K', 7))
KEEP_MAIN = os.environ.get('V5_KEEP_MAIN', '1') == '1'
DROP_BLOB_FILL = float(os.environ.get('V5_BLOB_FILL', 0.0))   # >0 时按填充率踢方块

os.makedirs(OUT, exist_ok=True)


def skel(m):
    s = skeletonize(m > 0)
    return s, int(s.sum())


def main():
    print(f'═══ ① 读原生底图 ═══', flush=True)
    g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    H, W = g.shape
    if DARK_V:
        mask = ((g >= MAIN_LO) | (g == DARK_V)).astype(np.uint8)
        print(f'  亮路 >={MAIN_LO}  +  暗路 =={DARK_V}', flush=True)
    else:
        mask = (g >= MAIN_LO).astype(np.uint8)
        print(f'  亮路 >={MAIN_LO}（不含楼区 43-48）', flush=True)
    del g
    print(f'  原始 {int(mask.sum())} px ({mask.sum()/ (H*W) *100:.3f}%)', flush=True)

    print(f'═══ ② 去碎点+去实心块 ═══', flush=True)
    n, lab, st, _ = cv2.connectedComponentsWithStats(mask, 8)
    keep = np.zeros(n, bool)
    drop_small = drop_blob = 0
    sizes = []
    for i in range(1, n):
        x, y, w, h, area = st[i]
        if area < MIN_AREA:
            drop_small += 1
            continue
        sub = (lab[y:y + h, x:x + w] == i).astype(np.uint8)
        s, skp = skel(sub)
        if skp < MIN_SKEL:
            drop_small += 1
            continue
        if DROP_BLOB_FILL > 0:
            fill = area / (w * h)
            if fill > DROP_BLOB_FILL:
                drop_blob += 1
                continue
        keep[i] = True
        sizes.append((int(area), skp))
    print(f'  成分 {n-1} → 保留 {int(keep.sum())}  丢碎点 {drop_small}  丢实心块 {drop_blob}', flush=True)
    sizes.sort(reverse=True)
    for a, s in sizes[:8]:
        print(f'    area {a:>8d}  skel {s:>7d}', flush=True)
    clean = keep[lab].astype(np.uint8)
    del lab, mask
    s, skp = skel(clean)
    print(f'  清洗后 骨架 {skp}px = {skp*M_PER_PX/1000:.1f} km', flush=True)

    print(f'═══ ③ 裂缝闭合 {CLOSE_K}px ═══', flush=True)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (CLOSE_K, CLOSE_K))
    closed = cv2.morphologyEx(clean, cv2.MORPH_CLOSE, k)
    del k
    print(f'  +{int(closed.sum())-int(clean.sum())} px', flush=True)

    result = closed
    if KEEP_MAIN:
        print('═══ ④ 只留主干连通域 ═══', flush=True)
        n2, lab2, st2, _ = cv2.connectedComponentsWithStats(closed, 8)
        areas = st2[1:, cv2.CC_STAT_AREA]
        order = np.argsort(-areas) + 1
        big = int(order[0])
        main = (lab2 == big).astype(np.uint8)
        print(f'  成分 {n2-1}  最大 {int(st2[big,cv2.CC_STAT_AREA])}px '
              f'({st2[big,cv2.CC_STAT_AREA]/closed.sum()*100:.1f}%)', flush=True)
        for r in order[:5]:
            print(f'    {int(st2[r,cv2.CC_STAT_AREA]):>9d} px  @{st2[r,0]},{st2[r,1]}', flush=True)
        result = main
        del lab2, closed

    s, skp = skel(result)
    n3, lab3, st3, _ = cv2.connectedComponentsWithStats(result, 8)
    tag = '全连通' if n3 - 1 == 1 else ''
    print(f'★ V5 骨架 {skp}px = {skp*M_PER_PX/1000:.1f} km  连通域 {n3-1} {tag}', flush=True)
    del lab3

    print('═══ ⑤ 渲染 ═══', flush=True)
    w = np.zeros((H, W, 3), np.uint8)
    w[result > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5_白线黑底.png', cv2.resize(w, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    cv2.imwrite(f'{OUT}/V5_白线黑底_全域.png', w)
    del w
    g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    base = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    over = base.copy()
    over[result > 0] = (0, 0, 255)
    cv2.imwrite(f'{OUT}/V5_红线压原图.png', cv2.resize(over, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    del over
    sc = 4
    def th(i):
        return cv2.resize(i, (W // sc, H // sc), interpolation=cv2.INTER_AREA)
    tiles = []
    for t, m in (('① 原始>=60', (g >= MAIN_LO).astype(np.uint8)),
                 ('② 去碎点去楼', clean), ('③ 闭合+主干网', result)):
        c = th(base.copy())
        mm = cv2.resize(m, (W // sc, H // sc), interpolation=cv2.INTER_NEAREST)
        c[mm > 0] = (0, 255, 255)
        cv2.putText(c, t, (30, 80), cv2.FONT_HERSHEY_SIMPLEX, 2.6, (0, 0, 255), 7)
        tiles.append(c)
    cv2.imwrite(f'{OUT}/V5_清洗对比三联.png', np.hstack(tiles))
    json.dump({'main_lo': MAIN_LO, 'dark_v': DARK_V, 'close_k': CLOSE_K,
               'skel_px': int(skp), 'km': round(skp * M_PER_PX / 1000, 1),
               'comps': int(n3 - 1)}, open(f'{OUT}/V5_report.json', 'w'),
              indent=1, ensure_ascii=False)
    print('  →', OUT, flush=True)


if __name__ == '__main__':
    main()
