#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_road_corners_v3b.py — 打点 v3b：修 v3 露出但图像核对抓出的三个问题

【v3 → v3b 修正（2026-09-30，均来自图像核对 + 量化）】

  ① **reach 44% 饱和在 156m**（MAX_REACH=40 格上限）
     后果：主路判据退化成"饱和 vs 未饱和"两档，不是真实主次。"长度比中位 2.89"
     是统计幻觉。修：MAX_REACH 40 → **120 格（467m）**，让长路能拉开差距；
     同时对饱和值额外记录 `reachSaturated` 标记，供运行时降权。

  ② **widthCells 6% 算出 0**（707 条支路）
     根因：宽度采样从距路口 2m 处开始，若该处被斑马线/路口空白挡住 → 直接 break 返回 0。
     修：起点从 2m 挪到 **1 格**（=3.89m，避开路口空白），
     采样失败时**退化为沿该方向的垂直投影宽度**（用 ±2 格窗口里的路面像素数估计），
     仍取不到则记 0 并标 `widthValid=false`。

  ③ **路口点间距中位 23m、87% ≤30m** —— 一个物理路口被多个点重复覆盖
     后果：运行时同一路口会被反复触发。
     修：**聚类去重**（radius 30m 内合并为一个路口记录），
     合并时取"支路数最多"的那个点为代表（最完整），
     并把组内各点的支路并集去重（≥15° 合并）。

【输出】models/road_corners_v3b.json
  弯道记录与 v2/v3 完全一致（已验证，不动）
  路口记录: ... branches=[{deg, reachM, widthCells, reachSat, widthValid}],
            clustered=组内点数

用法: python3 models/tools/make_road_corners_v3b.py
"""
import numpy as np, math, json
from PIL import Image

PRIOR = 'models/road_prior_2048_t70_fixed.png'
OUT   = 'models/road_corners_v3b.json'
N = 2048
MAP = 13056.0
CELL = MAP / N * 0.61

A = 0.016394586684750773
B = 5.693519256055879e-08
TX = 6526.474380746091
TY = 5210.664390686138
DEN = A*A + B*B

STEP_CAP   = 2.0
MAX_REACH  = 120.0            # ★ 修正①：40 → 120 格（467m），避免过早饱和
NANG       = 36
MIN_BRANCH = 10.0
MIN_BEND   = 8.0
SEED_STEP  = 6
CLUSTER_M  = 30.0             # ★ 修正③：30m 内的路口点合并

def g2w(gx, gy):
    st = MAP / N
    mx, my = gx*st, gy*st
    return (A*(mx-TX) + B*(my-TY))/DEN, (-B*(mx-TX) + A*(my-TY))/DEN

def road(x, y, r=1):
    xi, yi = int(round(x)), int(round(y))
    if not (0 <= xi < N and 0 <= yi < N): return False
    return bool(prior[max(0,yi-r):yi+r+1, max(0,xi-r):xi+r+1].any())

def reaches(gx, gy):
    out = []
    for a in ANGS:
        ca, sa = math.cos(a), math.sin(a)
        d = 0.0
        while d < MAX_REACH:
            d += STEP_CAP
            if not road(gx + ca*d, gy + sa*d, 1):
                d -= STEP_CAP; break
        out.append(min(d, MAX_REACH))
    return np.array(out)

def peaks(reach):
    n = len(reach); cand = []
    for i in range(n):
        if reach[i] < MIN_BRANCH: continue
        if reach[i] >= reach[(i-1) % n] and reach[i] >= reach[(i+1) % n]:
            cand.append((i, reach[i]))
    cand.sort(key=lambda c: -c[1])
    kept = []
    for i, v in cand:
        if all(min(abs(i-j), n-abs(i-j)) > 1 for j, _ in kept):
            kept.append((i, v))
    return [(math.degrees(ANGS[i]), v) for i, v in kept]

def branch_width(gx, gy, ang_deg, scan=9.0, step=0.5):
    """支路宽度（格）。★修正②：起点 3.89m（避开路口空白）；失败则用垂直窗口估计。"""
    a = math.radians(ang_deg)
    ca, sa = math.cos(a), math.sin(a)
    pa, pb = -sa, ca
    widths = []
    d = 3.89                                   # ★ 从 1 格开始（原 2.0）
    while d <= 14.0:
        cx, cy = gx + ca*d, gy + sa*d
        if not road(cx, cy, 0):
            d += 1.0; continue                 # ★ 跳过单点空洞（斑马线残留）
        w = 0.0
        for sgn in (1.0, -1.0):
            t = 0.0
            while t < scan:
                t += step
                if not road(cx + pa*t*sgn, cy + pb*t*sgn, 0): break
            w += t - step
        widths.append(w + 1.0)
        d += 2.0
        if len(widths) >= 5: break
    if widths: return float(np.median(widths)), True
    # ★ 退化估计：该方向 2~8 格范围内，垂直 ±2 格窗口的路面像素数开方
    cnt = 0
    for dd in np.arange(2.0, 8.0, 1.0):
        cx, cy = gx + ca*dd, gy + sa*dd
        xi, yi = int(round(cx)), int(round(cy))
        if 0 <= xi < N and 0 <= yi < N:
            cnt += int(prior[max(0,yi-2):yi+3, max(0,xi-2):xi+3].sum())
    if cnt > 0:
        return float(max(1.0, math.sqrt(cnt))), False
    return 0.0, False

def compass_of(img_ang_deg):
    a = math.radians(img_ang_deg)
    return math.degrees(math.atan2(math.cos(a), -math.sin(a))) % 360.0

def angdiff(a, b):
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)

def merge_branches(brs, tol=15.0):
    brs = sorted(brs, key=lambda b: -b['reachM'])
    out = []
    for b in brs:
        if all(angdiff(b['deg'], o['deg']) > tol for o in out):
            out.append(b)
    return out

def choose_exit(branches, in_deg):
    car = (in_deg + 180.0) % 360.0
    cands = [b for b in branches if angdiff(b['deg'], in_deg) > 30.0]
    if not cands: return None
    cands.sort(key=lambda b: angdiff(car, b['deg']))
    best = cands[0]
    near = [b for b in cands if angdiff(car, b['deg']) < 25.0]
    if len(near) >= 2:
        near.sort(key=lambda b: -b['reachM'])
        if near[0]['reachM'] > near[1]['reachM'] * 1.2:
            best = near[0]
        else:
            v = [b for b in near if b['widthValid']]
            if v:
                v.sort(key=lambda b: -b['widthCells'])
                best = v[0]
    return best

def main():
    global prior, ANGS
    prior = np.asarray(Image.open(PRIOR).convert('L')) > 127
    ANGS = np.radians(np.arange(0, 360, 360.0/NANG))
    print(f"输入 {PRIOR}  道路占比 {prior.mean()*100:.2f}%  1格={CELL:.2f}m")
    print(f"MAX_REACH={MAX_REACH}格={MAX_REACH*CELL:.0f}m  聚类半径={CLUSTER_M}m")

    bends, juncs = [], []
    for gy in range(12, N-12, SEED_STEP):
        for gx in range(12, N-12, SEED_STEP):
            if not prior[gy, gx]: continue
            pk = peaks(reaches(gx, gy))
            if len(pk) < 2: continue
            pk.sort(key=lambda p: -p[1])

            if len(pk) == 2:
                (a1, r1), (a2, r2) = pk[0], pk[1]
                d = abs(a1-a2) % 360.0; d = min(d, 360.0-d)
                bend = 180.0 - d
                if bend < MIN_BEND: continue
                if min(r1, r2) < MIN_BRANCH: continue
                wx, wy = g2w(gx, gy)
                span_m = min(r1, r2) * CELL * 2
                radius = span_m / math.radians(max(bend, 1e-6))
                grade = '急' if bend > 45 else ('中' if bend > 25 else '缓')
                d1 = (math.cos(math.radians(a1)), math.sin(math.radians(a1)))
                d2 = (math.cos(math.radians(a2)), math.sin(math.radians(a2)))
                cross = d1[0]*d2[1] - d1[1]*d2[0]
                for in_ang, out_ang, sign in ((a1, a2, 1 if cross > 0 else -1),
                                              (a2, a1, -1 if cross > 0 else 1)):
                    bends.append(dict(
                        worldX=round(wx,1), worldY=round(wy,1),
                        gridX=gx, gridY=gy,
                        headingIn=round(compass_of(in_ang),1),
                        headingOut=round(compass_of(out_ang),1),
                        turnDeg=round(bend,1), turnSign=sign,
                        radiusM=round(radius,0), grade=grade,
                        type='bend', branchCount=2))
            else:
                wx, wy = g2w(gx, gy)
                raw = []
                for a_img, rc in pk:
                    deg = compass_of(a_img)
                    w, wv = branch_width(gx, gy, a_img)
                    raw.append(dict(deg=round(deg,1),
                                    reachM=round(rc*CELL,0),
                                    widthCells=round(w,1),
                                    reachSat=bool(rc >= MAX_REACH - 0.01),
                                    widthValid=wv))
                branches = merge_branches(raw)
                if len(branches) < 3: continue
                juncs.append(dict(worldX=round(wx,1), worldY=round(wy,1),
                                  gridX=gx, gridY=gy, branches=branches))

    # ★ 修正③：路口聚类去重（30m 内合并）
    juncs.sort(key=lambda r: -len(r['branches']))
    used = [False]*len(juncs); merged = []
    for i, r in enumerate(juncs):
        if used[i]: continue
        grp = [r]; used[i] = True
        for j in range(i+1, len(juncs)):
            if used[j]: continue
            if math.hypot((juncs[j]['gridX']-r['gridX'])*CELL,
                          (juncs[j]['gridY']-r['gridY'])*CELL) <= CLUSTER_M:
                grp.append(juncs[j]); used[j] = True
        rep = max(grp, key=lambda g: len(g['branches']))
        allb = [b for g in grp for b in g['branches']]
        branches = merge_branches(allb)
        ex = choose_exit(branches, branches[0]['deg'])
        merged.append(dict(
            worldX=rep['worldX'], worldY=rep['worldY'],
            gridX=rep['gridX'], gridY=rep['gridY'],
            headingIn=None, headingOut=None,
            turnDeg=0.0, turnSign=0, radiusM=0.0, grade='路口',
            type='junction', branchCount=len(branches),
            branches=branches, clustered=len(grp),
            exitSample=ex['deg'] if ex else None))

    recs = bends + merged
    json.dump(recs, open(OUT, 'w'), ensure_ascii=False, indent=1)
    from collections import Counter
    print(f"\n✓ {OUT}")
    print(f"  弯道 {len(bends)} 条（{len(bends)//2} 位置 × 双向）")
    print(f"  路口 {len(merged)} 条（聚类前 {len(juncs)}）")
    print(f"  路口支路数分布: {Counter(r['branchCount'] for r in merged)}")
    print(f"  聚类点数分布: {Counter(r['clustered'] for r in merged).most_common(5)}")
    on = sum(1 for r in recs if road(r['gridX'], r['gridY'], 0))
    print(f"  落在路面: {on}/{len(recs)} = {on*100//len(recs)}%")

    allb = [b for r in merged for b in r['branches']]
    sat = sum(1 for b in allb if b['reachSat'])
    z = sum(1 for b in allb if not b['widthValid'] and b['widthCells'] <= 0.5)
    print(f"\n  修正① reach 饱和: {sat}/{len(allb)} = {sat*100//max(len(allb),1)}%（原 44%）")
    print(f"  修正② 宽度失效: {z}/{len(allb)} = {z*100//max(len(allb),1)}%（原 6%）")
    import statistics
    rs=[b['reachM'] for b in allb]
    print(f"  reach 分布: 中位 {statistics.median(rs):.0f}m  最大 {max(rs):.0f}m")

if __name__ == '__main__':
    main()
