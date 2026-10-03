#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_v5_bridge.py —— V5（补缝版 v2，Kruskal 最小生成森林）

用户 2026-10-03 15:1x 反馈：
  ① 最底下那条线没闭合（38 成分配对间距 34~39m 的断节）
  ② 左边那条显示成一大片（虚线被 CLOSE 填平）

上一版 bug：bridge() 把每个成分的端点两两组合、反复连线
  → 画出大量横跨的直线（右下出现一个大三角），而且同一端点被复用多次。
本版改法：
  · 对每个成分取骨架端点（真端点，不是中点）
  · 所有跨成分端点对按距离升序 → Kruskal（并查集）连边
  · 约束：距离 <= MAX_GAP，且每个端点最多用一次
  → 得到"最小生成森林"，只连最短的缝，绝无三角
  · 暗线层不做 CLOSE，保持虚线原样（解决 ② 的"糊成一大片"）
"""
import os, json
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
CLOSE_K_A = int(os.environ.get('V5_CLOSE_A', 7))
GAP_A = float(os.environ.get('V5_GAP_A', 80))    # 亮路内部补缝上限 px
GAP_B = float(os.environ.get('V5_GAP_B', 100))   # 暗线内部补缝上限 px
GAP_AB = float(os.environ.get('V5_GAP_AB', 90))  # 暗线↔亮路 补缝上限 px
BRIDGE_W = int(os.environ.get('V5_BRIDGE_W', 2))
KEEP_MAIN = os.environ.get('V5_KEEP_MAIN', '1') == '1'

os.makedirs(OUT, exist_ok=True)


def sk_px(m):
    return int(skeletonize(m > 0).sum())


def skel_endpoints(sub):
    """子图骨架的真端点；返回 [(x,y)]（局部坐标）"""
    sk = skeletonize(sub > 0)
    ys, xs = np.nonzero(sk)
    if len(ys) == 0:
        return []
    k = np.array([[1, 1, 1], [1, 10, 1], [1, 1, 1]], np.int16)
    nb = cv2.filter2D(sk.astype(np.int16), cv2.CV_16S, k)
    ep = sk & (nb == 11)
    ey, ex = np.nonzero(ep)
    if len(ey) == 0:
        ey, ex = ys, xs
    return list(zip(ex.tolist(), ey.tolist()))


def prepare(mask, name):
    """去碎点 → 返回干净掩膜 + 每个成分的端点(全局坐标)"""
    n, lab, st, _ = cv2.connectedComponentsWithStats(mask, 8)
    keep = np.zeros(n, bool)
    eps = {}
    for i in range(1, n):
        x, y, w, h, area = st[i]
        if area < MIN_AREA:
            continue
        sub = (lab[y:y + h, x:x + w] == i).astype(np.uint8)
        if sk_px(sub) < MIN_SKEL:
            continue
        keep[i] = True
        eps[i] = [(x + ex, y + ey) for ex, ey in skel_endpoints(sub)]
    clean = keep[lab].astype(np.uint8)
    print(f'  [{name}] 成分 {n-1} → 保留 {int(keep.sum())}  骨架 {sk_px(clean)}px '
          f'= {sk_px(clean)*M_PER_PX/1000:.1f} km', flush=True)
    return clean, eps


class DSU:
    def __init__(s, n): s.p = list(range(n))
    def find(s, x):
        while s.p[x] != x:
            s.p[x] = s.p[s.p[x]]
            x = s.p[x]
        return x
    def union(s, a, b):
        ra, rb = s.find(a), s.find(b)
        if ra == rb:
            return False
        s.p[rb] = ra
        return True


def bridge(mask, eps, max_gap, name, width=2):
    """Kruskal 最小生成森林：只连最短的缝，每端点最多用一次"""
    ids = [i for i in eps if eps[i]]
    if len(ids) < 2:
        return mask, []
    # 收集所有跨成分端点对
    edges = []
    for ai in range(len(ids)):
        for bi in range(ai + 1, len(ids)):
            ia, ib = ids[ai], ids[bi]
            for j, (x1, y1) in enumerate(eps[ia]):
                for k, (x2, y2) in enumerate(eps[ib]):
                    d = ((x1 - x2) ** 2 + (y1 - y2) ** 2) ** 0.5
                    if d <= max_gap:
                        edges.append((d, ia, j, ib, k, x1, y1, x2, y2))
    edges.sort(key=lambda e: e[0])
    dsu = DSU(max(ids) + 1)
    used = {}        # (组件, 端点索引) -> 已用
    canvas = mask.copy()
    drawn = []
    for d, ia, j, ib, k, x1, y1, x2, y2 in edges:
        if (ia, j) in used or (ib, k) in used:
            continue
        if dsu.find(ia) == dsu.find(ib):
            continue
        dsu.union(ia, ib)
        used[(ia, j)] = 1
        used[(ib, k)] = 1
        cv2.line(canvas, (x1, y1), (x2, y2), 1, width)
        drawn.append((round(d, 1), ia, ib))
    print(f'  [{name}] 桥接 {len(drawn)} 条 (上限 {max_gap:.0f}px)'
          + (f'  最短 {min(x[0] for x in drawn):.0f}px' if drawn else ''), flush=True)
    return canvas, drawn


def main():
    print('═══ 读原生底图 ═══', flush=True)
    g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    H, W = g.shape
    np.save('/tmp/v5b_gray.npy', g)

    # ── A 亮路 ──
    print(f'═══ A 亮路 >= {BRIGHT_LO} ═══', flush=True)
    A, epsA = prepare((g >= BRIGHT_LO).astype(np.uint8), 'bright')
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (CLOSE_K_A, CLOSE_K_A))
    A = cv2.morphologyEx(A, cv2.MORPH_CLOSE, k)
    del k
    if KEEP_MAIN:
        n, lab, st, _ = cv2.connectedComponentsWithStats(A, 8)
        big = int(np.argmax(st[1:, cv2.CC_STAT_AREA])) + 1
        A = (lab == big).astype(np.uint8)
        del lab
    # 重算端点（闭运算后成分变了）
    A, epsA = prepare(A, 'bright-final')
    np.save('/tmp/v5b_A.npy', A)

    # ── B 暗线（不闭运算）──
    print(f'═══ B 暗线 == {DARK_V}（保虚线，不闭运算） ═══', flush=True)
    B, epsB = prepare((g == DARK_V).astype(np.uint8), 'dark38')
    np.save('/tmp/v5b_B.npy', B)

    # ── 桥接 ──
    print('═══ 桥接补缝（Kruskal 最小生成森林） ═══', flush=True)
    newmask = np.zeros((H, W), np.uint8)      # 只记录新画的桥

    def rec(base_mask, eps, gap, name):
        before = base_mask.copy()
        after, drawn = bridge(base_mask, eps, gap, name, BRIDGE_W)
        newmask[:] |= cv2.subtract(after, before)
        return after

    B2 = rec(B, epsB, GAP_B, 'B内部')
    AB = ((A > 0) | (B2 > 0)).astype(np.uint8)
    _, epsAB = prepare(AB, 'A∪B')
    V5 = rec(AB, epsAB, GAP_AB, 'A∪B 全局')
    del AB

    # ── 收尾：就近吸附 or 删除 ──
    # ★ 桥接用的是"端点对端点"距离，会出现端点到主干端点 >GAP、
    #   但像素距离很近的碎屑（实测 33px @5880,6659 离主干仅 19px）。
    #   这里做最后一遍：够近的从"最近端点"直连"主干最近像素"，太远的删掉。
    ORPHAN_MAX = float(os.environ.get('V5_ORPHAN_MAX', 100))
    print(f'═══ 收尾吸附（≤{ORPHAN_MAX:.0f}px 吸附，否则删除） ═══', flush=True)
    n_a, lab_a, st_a, _ = cv2.connectedComponentsWithStats(V5, 8)
    big = int(np.argmax(st_a[1:, cv2.CC_STAT_AREA])) + 1
    mainm = (lab_a == big).astype(np.uint8)
    my, mx = np.nonzero(mainm)
    mpix = np.stack([mx, my], 1).astype(np.int32)
    snapped, dropped = [], []
    for i in range(1, n_a):
        if i == big:
            continue
        x, y, w, h, a = st_a[i]
        sub = (lab_a[y:y + h, x:x + w] == i).astype(np.uint8)
        epl = skel_endpoints(sub)
        if not epl:
            epl = [(w // 2, h // 2)]
        gx = np.array([x + ex for ex, _ in epl], np.int32)
        gy = np.array([y + ey for _, ey in epl], np.int32)
        # 每个端点找主干最近像素
        best = None
        for px, py in zip(gx, gy):
            d2 = (mpix[:, 0] - px) ** 2 + (mpix[:, 1] - py) ** 2
            j = int(np.argmin(d2))
            dd = float(d2[j]) ** 0.5
            if best is None or dd < best[0]:
                best = (dd, int(px), int(py), int(mpix[j, 0]), int(mpix[j, 1]))
        dd, px, py, qx, qy = best
        if dd <= ORPHAN_MAX:
            cv2.line(V5, (px, py), (qx, qy), 1, BRIDGE_W)
            newmask[:] |= cv2.line(np.zeros((H, W), np.uint8), (px, py), (qx, qy), 1, BRIDGE_W)
            snapped.append((int(a), round(dd, 1), int(x), int(y)))
        else:
            V5[y:y + h, x:x + w][sub > 0] = 0
            dropped.append((int(a), round(dd, 1), int(x), int(y)))
    del mainm, mpix, lab_a
    if snapped:
        print('  吸附 ' + ', '.join(f'{a}px(距{d}px)@{x},{y}' for a, d, x, y in snapped), flush=True)
    if dropped:
        print('  删除 ' + ', '.join(f'{a}px(距{d}px)@{x},{y}' for a, d, x, y in dropped), flush=True)
    if not snapped and not dropped:
        print('  无残留碎块', flush=True)

    s5 = sk_px(V5)
    n5, lab5, st5, _ = cv2.connectedComponentsWithStats(V5, 8)
    print(f'★ V5 骨架 {s5}px = {s5*M_PER_PX/1000:.1f} km  成分 {n5-1}', flush=True)
    for r in (np.argsort(-st5[1:, 4])[:8] + 1):
        print(f'    {int(st5[r,4]):>9d} px  @{st5[r,0]},{st5[r,1]}', flush=True)
    print(f'  桥接新增像素 {int(newmask.sum())}（应远小于总骨架）', flush=True)

    sp = '/Users/dupi/Desktop/road_patch_20261003_141553.png'
    cov = None
    if os.path.exists(sp):
        im = cv2.imread(sp, cv2.IMREAD_UNCHANGED)
        S = cv2.resize((im[:, :, 3] > 0).astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST)
        band = cv2.dilate(S, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)))
        V5d = cv2.dilate(V5, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
        cov = float((band & V5d).sum()) / float(band.sum())
        print(f'  笔画带覆盖 {cov*100:.1f}%', flush=True)
        del band, V5d, S, im

    # ── 渲染 ──
    print('═══ 渲染 ═══', flush=True)
    w = np.zeros((H, W, 3), np.uint8)
    w[V5 > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5_白线黑底_全域.png', w)
    cv2.imwrite(f'{OUT}/V5_白线黑底.png', cv2.resize(w, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    del w
    base = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    over = base.copy()
    over[A > 0] = (77, 77, 255)
    over[B2 > 0] = (0, 212, 255)
    cv2.imwrite(f'{OUT}/V5_交付_红亮路_黄暗线_压原图.png',
                cv2.resize(over, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    cv2.imwrite(f'{OUT}/V5_交付_红亮路_黄暗线_压原图_全域.png', over)
    # 诊断：洋红 = 新补的桥
    diag = over.copy()
    diag[newmask > 0] = (255, 0, 255)
    cv2.imwrite(f'{OUT}/V5_诊断_洋红=新补的桥.png',
                cv2.resize(diag, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    del diag, over
    sc = 3
    def th(i): return cv2.resize(i, (W // sc, H // sc), interpolation=cv2.INTER_AREA)
    ww = np.zeros((H, W, 3), np.uint8); ww[V5 > 0] = (255, 255, 255)
    mm = base.copy(); mm[A > 0] = (77, 77, 255); mm[B2 > 0] = (0, 212, 255)
    t1, t2, t3 = th(base), th(ww), th(mm)
    for t, s in ((t1, '原图'), (t2, 'V5 白线'), (t3, 'V5 红=亮路 黄=暗线')):
        cv2.putText(t, s, (30, 80), cv2.FONT_HERSHEY_SIMPLEX, 2.6, (0, 0, 255), 7)
    cv2.imwrite(f'{OUT}/V5_交付_三联.png', np.hstack([t1, t2, t3]))
    del ww, mm, t1, t2, t3, base
    bw = np.zeros((H, W, 3), np.uint8); bw[B2 > 0] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5_暗色车道线_单层.png',
                cv2.resize(bw, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    del bw, g

    json.dump({'bright_lo': BRIGHT_LO, 'dark_v': DARK_V,
               'gap_b': GAP_B, 'gap_ab': GAP_AB, 'bridge_w': BRIDGE_W,
               'V5_km': round(s5 * M_PER_PX / 1000, 1), 'V5_comps': int(n5 - 1),
               'bridge_px': int(newmask.sum()),
               'stroke_cov': None if cov is None else round(cov, 4)},
              open(f'{OUT}/V5_report.json', 'w'), indent=1, ensure_ascii=False)
    print('  →', OUT, flush=True)


if __name__ == '__main__':
    main()
