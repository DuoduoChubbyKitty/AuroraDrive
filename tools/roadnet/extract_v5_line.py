#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_v5_line.py —— V5 终极版：一条线（1px 中心线）

用户 2026-10-03 15:5x：
  "还有一些裂缝没闭合，我想让他变成彻底一条线，直接变成只有一种颜色的一整条线"

问题诊断（实测）：
  mask 层面已经是 1 个连通域，但**视觉上**全是断口：
    · 骨架 177462px 里有 1008 个死头、9465 个分叉点
    · 死头几像素内挤一堆（4821,3861 / 4834,3865 / 4814,3884 …）
  → 因为灰阶 38 车道线本身是**虚线/碎片**，骨架化后每节各自生成毛刺。

正确顺序（关键！）：
  ① 先"连成实心带"：对每个子层做方向性闭运算 + 形态学桥接
  ② 再抽骨架 → 得到 1px 连续中心线
  ③ 剪毛刺：删掉长度 < SPUR_MIN 的悬挂枝
  ④ 补断口：端点间 <= JOIN_MAX 的直线连接（再次 Kruskal）

输出：
  docs/roadnet/v5/V5_line_白线黑底.png    1px 白线
  docs/roadnet/v5/V5_line_红压原图.png    红线压原图
  docs/roadnet/v5/V5_line_全分辨率.png
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
CLOSE_A = int(os.environ.get('V5_CLOSE_A', 7))
CLOSE_B = int(os.environ.get('V5_CLOSE_B', 9))       # ★ 暗线补闭合（比之前大）
JOIN_MAX = float(os.environ.get('V5_JOIN_MAX', 120))
SPUR_MIN = int(os.environ.get('V5_SPUR_MIN', 12))    # 悬挂枝短于此就剪
LINE_W = int(os.environ.get('V5_LINE_W', 1))

os.makedirs(OUT, exist_ok=True)


def sk_px(m):
    return int(skeletonize(m > 0).sum())


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


def endpoints(sk):
    k = np.array([[1, 1, 1], [1, 10, 1], [1, 1, 1]], np.int16)
    nb = cv2.filter2D(sk.astype(np.int16), cv2.CV_16S, k)
    ey, ex = np.nonzero(sk & (nb == 11))
    return list(zip(ex.tolist(), ey.tolist()))


def join_ends(binmask, max_gap, width=1):
    """端点间 Kruskal 补断口"""
    n, lab, st, _ = cv2.connectedComponentsWithStats(binmask, 8)
    eps = {}
    for i in range(1, n):
        x, y, w, h, a = st[i]
        sub = (lab[y:y + h, x:x + w] == i).astype(np.uint8)
        sk = skeletonize(sub > 0)
        e = endpoints(sk)
        if not e:
            continue
        eps[i] = [(x + ex, y + ey) for ex, ey in e]
    ids = [i for i in eps if eps[i]]
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
    used = set()
    canvas = binmask.copy()
    drawn = 0
    for d, ia, j, ib, k, x1, y1, x2, y2 in edges:
        if (ia, j) in used or (ib, k) in used:
            continue
        if dsu.find(ia) == dsu.find(ib):
            continue
        dsu.union(ia, ib)
        used.add((ia, j)); used.add((ib, k))
        cv2.line(canvas, (x1, y1), (x2, y2), 1, width)
        drawn += 1
    return canvas, drawn


def prune_spurs(sk, min_len):
    """剪掉长度 < min_len 的悬挂枝（死头往内走）"""
    sk = sk.copy()
    removed = 0
    for _ in range(8):
        e = endpoints(sk)
        if not e:
            break
        nb_k = np.array([[1, 1, 1], [1, 10, 1], [1, 1, 1]], np.int16)
        killed = False
        for (x0, y0) in e:
            path = [(x0, y0)]
            cx, cy = x0, y0
            prev = None
            for _step in range(min_len):
                nxt = None
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < sk.shape[1] and 0 <= ny < sk.shape[0] and sk[ny, nx]:
                            if prev and (nx, ny) == prev:
                                continue
                            nxt = (nx, ny)
                            break
                    if nxt:
                        break
                if not nxt:
                    break
                path.append(nxt)
                prev = (cx, cy)
                cx, cy = nxt
                # 到达分叉点就停
                win = sk[max(0, cy - 1):cy + 2, max(0, cx - 1):cx + 2]
                if win.sum() >= 4:
                    break
            if len(path) < min_len:
                for (px, py) in path:
                    win = sk[max(0, py - 1):py + 2, max(0, px - 1):px + 2]
                    if win.sum() >= 4:
                        continue
                    sk[py, px] = False
                    removed += 1
                killed = True
        if not killed:
            break
    return sk, removed


def main():
    print('═══ 读原生底图 ═══', flush=True)
    g = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    H, W = g.shape

    # ① 亮路主干网
    print(f'═══ ① 亮路 >= {BRIGHT_LO} ═══', flush=True)
    A = (g >= BRIGHT_LO).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats(A, 8)
    keep = np.zeros(n, bool)
    for i in range(1, n):
        x, y, w, h, a = st[i]
        if a < MIN_AREA:
            continue
        if sk_px((lab[y:y + h, x:x + w] == i).astype(np.uint8)) < MIN_SKEL:
            continue
        keep[i] = True
    A = keep[lab].astype(np.uint8)
    kA = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (CLOSE_A, CLOSE_A))
    A = cv2.morphologyEx(A, cv2.MORPH_CLOSE, kA)
    n, lab, st, _ = cv2.connectedComponentsWithStats(A, 8)
    A = (lab == int(np.argmax(st[1:, 4])) + 1).astype(np.uint8)
    del lab
    print(f'  A 骨架 {sk_px(A)}px = {sk_px(A)*M_PER_PX/1000:.1f} km', flush=True)

    # ② 暗线：连成实心带（不做大闭运算会导致骨架毛刺；做方向性闭合更自然）
    print(f'═══ ② 暗线 == {DARK_V} → 连成实心带 ═══', flush=True)
    B = (g == DARK_V).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats(B, 8)
    keep = np.zeros(n, bool)
    for i in range(1, n):
        x, y, w, h, a = st[i]
        if a < MIN_AREA:
            continue
        if sk_px((lab[y:y + h, x:x + w] == i).astype(np.uint8)) < MIN_SKEL:
            continue
        keep[i] = True
    B = keep[lab].astype(np.uint8)
    del lab
    print(f'  原始 {int(B.sum())} px', flush=True)
    # 先按 4 个方向各做一次闭运算再取并集 → 直线/斜线缺口都能补，不糊成块
    dirs = [np.ones((1, CLOSE_B), np.uint8), np.ones((CLOSE_B, 1), np.uint8),
            np.eye(CLOSE_B, dtype=np.uint8),
            np.fliplr(np.eye(CLOSE_B, dtype=np.uint8))]
    Bd = B.copy()
    for d in dirs:
        Bd |= cv2.morphologyEx(B, cv2.MORPH_CLOSE, d)
    # 圆核补最后的零散缝
    kc = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    Bd = cv2.morphologyEx(Bd, cv2.MORPH_CLOSE, kc)
    del kc
    print(f'  方向性闭合后 {int(Bd.sum())} px (+{int(Bd.sum())-int(B.sum())})', flush=True)
    B = Bd
    del Bd

    # ③ 合并 + 补断口
    V5 = ((A > 0) | (B > 0)).astype(np.uint8)
    del A, B
    print('═══ ③ 桥接断口 ═══', flush=True)
    V5, nd = join_ends(V5, JOIN_MAX, LINE_W)
    print(f'  桥接 {nd} 条 (<= {JOIN_MAX:.0f}px)', flush=True)

    # ★ 保留一份"路面带"用于后面校验桥线（防抄近道穿空地）
    ROADBAND = cv2.dilate(V5, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)))
    np.save('/tmp/v5_roadband.npy', ROADBAND.astype(np.uint8))
    print(f'  路面带 {int((ROADBAND>0).sum())} px（用于校验桥线）', flush=True)

    # ④ 抽骨架
    print('═══ ④ 抽 1px 中心线 ═══', flush=True)
    sk = skeletonize(V5 > 0)
    print(f'  骨架 {int(sk.sum())}px = {sk.sum()*M_PER_PX/1000:.1f} km', flush=True)
    # ⑤ 剪毛刺
    sk2, rem = prune_spurs(sk, SPUR_MIN)
    print(f'  剪毛刺 {rem} px (长度<{SPUR_MIN})', flush=True)
    # ⑥ 再补一次断口（剪完可能又断开）
    sku = (sk2.astype(np.uint8)) * 255
    sku2, nd2 = join_ends(sku, JOIN_MAX, LINE_W)
    sk_final = (sku2 > 0)
    del sk, sk2, sku, sku2, V5

    # ⑦ 统一成一条：碎块就近吸附到主干，太远的删掉
    print('═══ ⑦ 统一成一条线 ═══', flush=True)
    SNAP_MAX = float(os.environ.get('V5_SNAP_MAX', 150))
    sk_bin = sk_final.astype(np.uint8)
    for _pass in range(4):
        n_u, lab_u, st_u, _ = cv2.connectedComponentsWithStats(sk_bin, 8)
        if n_u - 1 <= 1:
            break
        big = int(np.argmax(st_u[1:, 4])) + 1
        my, mx = np.nonzero(lab_u == big)
        mpix = np.stack([mx, my], 1).astype(np.int32)
        merged = dropped = 0
        for i in range(1, n_u):
            if i == big:
                continue
            x, y, w, h, a = st_u[i]
            sub = (lab_u[y:y + h, x:x + w] == i).astype(np.uint8)
            epl = endpoints(sub)
            if not epl:
                epl = [(w // 2, h // 2)]
            best = None
            for ex, ey in epl:
                px, py = x + ex, y + ey
                d2 = (mpix[:, 0] - px) ** 2 + (mpix[:, 1] - py) ** 2
                j = int(np.argmin(d2))
                dd = float(d2[j]) ** 0.5
                if best is None or dd < best[0]:
                    best = (dd, px, py, int(mpix[j, 0]), int(mpix[j, 1]))
            dd, px, py, qx, qy = best
            if dd <= SNAP_MAX:
                cv2.line(sk_bin, (px, py), (qx, qy), 1, LINE_W)
                merged += 1
            else:
                sk_bin[y:y + h, x:x + w][sub > 0] = 0
                dropped += 1
        print(f'  第{_pass+1}轮: 吸附 {merged}  删除 {dropped}', flush=True)
        if not merged:
            break
    # 吸附线是 2px 粗的，重新细化成 1px
    sk_final = skeletonize(sk_bin > 0)
    del sk_bin, lab_u

    # ⑧ 死头对接：把互相面对的死头连起来（这才是"裂缝闭合"）
    print('═══ ⑧ 死头对接（闭合裂缝） ═══', flush=True)
    TIP_MAX = float(os.environ.get('V5_TIP_MAX', 200))
    ONROAD = float(os.environ.get('V5_ONROAD', 0.75))   # ★ 桥线必须有此比例压在路面上
    sk_c = sk_final.astype(np.uint8).copy()
    rb = np.load('/tmp/v5_roadband.npy') > 0
    for _pass in range(3):
        tips = endpoints(sk_c.astype(bool))
        if len(tips) < 2:
            break
        cand = []
        for ai in range(len(tips)):
            x1, y1 = tips[ai]
            dx1 = dy1 = 0
            cx, cy, px, py = x1, y1, None, None
            for _ in range(6):
                nxt = None
                for ddy in (-1, 0, 1):
                    for ddx in (-1, 0, 1):
                        if ddx == 0 and ddy == 0:
                            continue
                        nx, ny = cx + ddx, cy + ddy
                        if 0 <= ny < H and 0 <= nx < W and sk_c[ny, nx]:
                            if px is not None and (nx, ny) == (px, py):
                                continue
                            nxt = (nx, ny)
                            break
                    if nxt:
                        break
                if not nxt:
                    break
                px, py, cx, cy = cx, cy, nxt[0], nxt[1]
            dx1, dy1 = x1 - cx, y1 - cy
            for bi in range(ai + 1, len(tips)):
                x2, y2 = tips[bi]
                d = ((x1 - x2) ** 2 + (y1 - y2) ** 2) ** 0.5
                if d > TIP_MAX or d < 1:
                    continue
                ux, uy = (x2 - x1) / d, (y2 - y1) / d
                n1 = (dx1 * dx1 + dy1 * dy1) ** 0.5
                if n1 < 1e-6:
                    continue
                cos1 = (dx1 * ux + dy1 * uy) / n1
                if cos1 < 0.2:       # 死头朝外方向必须大致指向对方
                    continue
                # ★ 校验：采样这条桥线，压在路面带上的比例
                n_s = max(8, int(d / 4))
                ts = np.linspace(0, 1, n_s)
                sx = (x1 + (x2 - x1) * ts).astype(np.int32)
                sy = (y1 + (y2 - y1) * ts).astype(np.int32)
                onr = float(rb[sy, sx].mean())
                if onr < ONROAD:
                    continue
                cand.append((d, onr, cos1, x1, y1, x2, y2))
        cand.sort(key=lambda c: c[0])
        drawn = 0
        used = set()
        rejected = 0
        for d, onr, cos1, x1, y1, x2, y2 in cand:
            if (x1, y1) in used or (x2, y2) in used:
                continue
            used.add((x1, y1)); used.add((x2, y2))
            cv2.line(sk_c, (x1, y1), (x2, y2), 1, LINE_W)
            drawn += 1
        total_pairs = 0
        for ai in range(len(tips)):
            for bi in range(ai + 1, len(tips)):
                d = ((tips[ai][0] - tips[bi][0]) ** 2 + (tips[ai][1] - tips[bi][1]) ** 2) ** 0.5
                if d <= TIP_MAX:
                    total_pairs += 1
        print(f'  第{_pass+1}轮: 死头 {len(tips)}  候选 {total_pairs}  通过路面校验 {len(cand)}  '
              f'对接 {drawn} 条 (<= {TIP_MAX:.0f}px, 压路面>{ONROAD:.0%})', flush=True)
        if not drawn:
            break
    sk_final = skeletonize(sk_c > 0)
    del sk_c, rb

    n_f, lab_f, st_f, _ = cv2.connectedComponentsWithStats(sk_final.astype(np.uint8), 8)
    big = int(np.argmax(st_f[1:, 4])) + 1
    print(f'★ 中心线 骨架 {int(sk_final.sum())}px = {sk_final.sum()*M_PER_PX/1000:.1f} km  '
          f'成分 {n_f-1}  最大占比 {st_f[big,4]/max(1,sk_final.sum())*100:.1f}%', flush=True)
    for r in (np.argsort(-st_f[1:, 4])[:6] + 1):
        print(f'    {int(st_f[r,4]):>7d} px  @{st_f[r,0]},{st_f[r,1]}', flush=True)
    e = endpoints(sk_final)
    k = np.array([[1, 1, 1], [1, 10, 1], [1, 1, 1]], np.int16)
    nbf = cv2.filter2D(sk_final.astype(np.int16), cv2.CV_16S, k)
    print(f'  死头 {sum(1 for _ in e)}  分叉点 {int((sk_final&(nbf>=13)).sum())}', flush=True)

    # ── 渲染 ──
    print('═══ 渲染 ═══', flush=True)
    line = (sk_final.astype(np.uint8)) * 255
    rgbw = np.zeros((H, W, 3), np.uint8); rgbw[sk_final] = (255, 255, 255)
    cv2.imwrite(f'{OUT}/V5_line_全分辨率.png', rgbw)
    cv2.imwrite(f'{OUT}/V5_line_白线黑底.png',
                cv2.resize(rgbw, (W // 2, H // 2), interpolation=cv2.INTER_NEAREST))
    del rgbw
    base = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    ov = base.copy(); ov[sk_final] = (0, 0, 255)
    cv2.imwrite(f'{OUT}/V5_line_红压原图.png',
                cv2.resize(ov, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    cv2.imwrite(f'{OUT}/V5_line_红压原图_全域.png', ov)
    # 粗一点的版本（方便肉眼看）
    ov2 = base.copy()
    thick = cv2.dilate(sk_final.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    ov2[thick > 0] = (0, 0, 255)
    cv2.imwrite(f'{OUT}/V5_line_红压原图_加粗3px.png',
                cv2.resize(ov2, (W // 2, H // 2), interpolation=cv2.INTER_AREA))
    del ov, ov2, base
    sc = 3
    def th(i): return cv2.resize(i, (W // sc, H // sc), interpolation=cv2.INTER_AREA)
    g2 = cv2.imread(MAP, cv2.IMREAD_GRAYSCALE)
    b2 = cv2.cvtColor(g2, cv2.COLOR_GRAY2BGR)
    w2 = np.zeros((H, W, 3), np.uint8); w2[sk_final] = (255, 255, 255)
    m2 = b2.copy(); m2[thick > 0] = (0, 0, 255)
    t1, t2, t3 = th(b2), th(w2), th(m2)
    for t, s in ((t1, '原图'), (t2, 'V5 = 1px 一整条线'), (t3, '红压原图')):
        cv2.putText(t, s, (30, 80), cv2.FONT_HERSHEY_SIMPLEX, 2.6, (0, 0, 255), 7)
    cv2.imwrite(f'{OUT}/V5_line_三联.png', np.hstack([t1, t2, t3]))
    del w2, m2, b2, g2, g, t1, t2, t3

    json.dump({'bright_lo': BRIGHT_LO, 'dark_v': DARK_V,
               'close_b': CLOSE_B, 'join_max': JOIN_MAX, 'spur_min': SPUR_MIN,
               'line_px': int(sk_final.sum()),
               'km': round(sk_final.sum() * M_PER_PX / 1000, 1),
               'comps': int(n_f - 1),
               'dead_ends': int(sum(1 for _ in e)),
               'upstream_comps': int(n_f - 1)},
              open(f'{OUT}/V5_line_report.json', 'w'), indent=1, ensure_ascii=False)
    print('  →', OUT, flush=True)


if __name__ == '__main__':
    main()
