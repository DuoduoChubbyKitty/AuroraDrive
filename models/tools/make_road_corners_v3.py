#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_road_corners_v3.py — 打点 v3（在 v2 基础上补「支路长度/宽度」）

【为什么需要 v3（2026-09-30）】
  v2 的路口记录只存了各支路的**角度**（`branches: [280.0, 90.0, 230.0]`），
  但选路时需要知道**哪条是主路**：实测 12.8% 的情形有 2 条以上支路都在车头
  25° 内（Y 形岔路），此时"最贴近车头"挑不出主路，会拐进小巷。
  而 `peaks()` **本来就已经量出每条支路的射线可达长度**（`reach`，格），
  只是生成 json 时丢掉了 —— v3 把它补回去，并额外量一个宽度。

【v3 相对 v2 的唯一改动】
  路口记录的 `branches` 从 `[角度, ...]`
  改为 `[{deg, reachM, widthCells}, ...]`
  其余（弯道部分、双向、密集布点、闭运算位图输入）**完全不变**。

【输出】models/road_corners_v3.json
  弯道记录: worldX, worldY, gridX, gridY, headingIn, headingOut,
            turnDeg, turnSign, radiusM, grade, type='bend', branchCount=2
  路口记录: worldX, worldY, gridX, gridY, type='junction', branchCount,
            branches=[{deg, reachM, widthCells}, ...]
            exitBest = 默认出口（几何选路结果，离线算好便于核对）

【主路判据】reach 越长 = 越主干；同长则比宽度（widthCells）

用法: python3 models/tools/make_road_corners_v3.py
"""
import numpy as np, math, json
from PIL import Image

PRIOR = 'models/road_prior_2048_t70_fixed.png'
OUT   = 'models/road_corners_v3.json'
N = 2048
MAP = 13056.0
CELL = MAP / N * 0.61          # 3.89 m/格

A = 0.016394586684750773
B = 5.693519256055879e-08
TX = 6526.474380746091
TY = 5210.664390686138
DEN = A*A + B*B

STEP_CAP   = 2.0
MAX_REACH  = 40.0              # 40 格 = 156 m（主路判据的观测长度）
NANG       = 36
MIN_BRANCH = 10.0
MIN_BEND   = 8.0
SEED_STEP  = 6

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
    """支路宽度：沿该方向推进，量垂直于它方向的"路面跨度"（格）。
    取前 12m 内的中位跨度 —— 主干道比小巷宽，这是主路判据的第二维。"""
    a = math.radians(ang_deg)
    ca, sa = math.cos(a), math.sin(a)
    pa, pb = -sa, ca                     # 垂直方向
    widths = []
    d = 2.0
    while d <= 12.0:
        cx, cy = gx + ca*d, gy + sa*d
        if not road(cx, cy, 0):
            break
        # 沿垂直方向量跨度（中心向两侧扩）
        w = 0.0
        for sgn in (1.0, -1.0):
            t = 0.0
            while t < scan:
                t += step
                if not road(cx + pa*t*sgn, cy + pb*t*sgn, 0): break
            w += t - step
        widths.append(w + 1.0)           # +1 含中心格
        d += 2.0
    if not widths: return 0.0
    return float(np.median(widths))

def compass_of(img_ang_deg):
    a = math.radians(img_ang_deg)
    return math.degrees(math.atan2(math.cos(a), -math.sin(a))) % 360.0

def angdiff(a, b):
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)

def merge_branches(brs, tol=15.0):
    """合并方向相近的支路（同一支路在射线采样里的多个峰）"""
    brs = sorted(brs, key=lambda b: -b['reachM'])
    out = []
    for b in brs:
        if all(angdiff(b['deg'], o['deg']) > tol for o in out):
            out.append(b)
    return out

def choose_exit(branches, in_deg):
    """几何选路（离线预算，供核对；运行时 Swift 侧同样逻辑）
      ① 排除来路；② 选与车头夹角最小；③ 同向多支路用主路判据（长度→宽度）"""
    car = (in_deg + 180.0) % 360.0
    cands = [b for b in branches if angdiff(b['deg'], in_deg) > 30.0]
    if not cands: return None
    cands.sort(key=lambda b: angdiff(car, b['deg']))
    best = cands[0]
    near = [b for b in cands if angdiff(car, b['deg']) < 25.0]
    if len(near) >= 2:
        # 主路判据：先比长度（差 <20% 视为同级），再比宽度
        near.sort(key=lambda b: -b['reachM'])
        if near[0]['reachM'] > near[1]['reachM'] * 1.2:
            best = near[0]
        else:
            near.sort(key=lambda b: -b['widthCells'])
            best = near[0]
    return best

def main():
    global prior, ANGS
    prior = np.asarray(Image.open(PRIOR).convert('L')) > 127
    ANGS = np.radians(np.arange(0, 360, 360.0/NANG))
    print(f"输入 {PRIOR}  道路占比 {prior.mean()*100:.2f}%  1格={CELL:.2f}m")

    recs = []
    n_bend = n_junc = 0
    for gy in range(12, N-12, SEED_STEP):
        for gx in range(12, N-12, SEED_STEP):
            if not prior[gy, gx]: continue
            pk = peaks(reaches(gx, gy))
            if len(pk) < 2: continue
            pk.sort(key=lambda p: -p[1])

            if len(pk) == 2:
                # ── 弯道（与 v2 完全一致）──
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
                    recs.append(dict(
                        worldX=round(wx,1), worldY=round(wy,1),
                        gridX=gx, gridY=gy,
                        headingIn=round(compass_of(in_ang),1),
                        headingOut=round(compass_of(out_ang),1),
                        turnDeg=round(bend,1), turnSign=sign,
                        radiusM=round(radius,0), grade=grade,
                        type='bend', branchCount=2))
                n_bend += 1
            else:
                # ── 路口：v3 补支路长度 + 宽度 ──
                wx, wy = g2w(gx, gy)
                raw = []
                for a_img, rc in pk:
                    deg = compass_of(a_img)
                    w = branch_width(gx, gy, a_img)
                    raw.append(dict(deg=round(deg,1),
                                    reachM=round(rc*CELL,0),
                                    widthCells=round(w,1)))
                branches = merge_branches(raw)
                if len(branches) < 3: continue        # 合并后不足 3 条 → 不是路口
                # 离线预算默认出口（用在来路 = 第一条上，供核对参考）
                ex = choose_exit(branches, branches[0]['deg'])
                recs.append(dict(
                    worldX=round(wx,1), worldY=round(wy,1),
                    gridX=gx, gridY=gy,
                    headingIn=None, headingOut=None,
                    turnDeg=0.0, turnSign=0,
                    radiusM=0.0, grade='路口',
                    type='junction', branchCount=len(branches),
                    branches=branches,
                    exitSample=ex['deg'] if ex else None))
                n_junc += 1

    json.dump(recs, open(OUT, 'w'), ensure_ascii=False, indent=1)
    from collections import Counter
    print(f"\n✓ {OUT}")
    print(f"  总记录 {len(recs)}  (弯道位置 {n_bend} → {n_bend*2} 条；路口 {n_junc} 条)")
    print(f"  路口支路数分布: {Counter(r['branchCount'] for r in recs if r['type']=='junction')}")
    on = sum(1 for r in recs if road(r['gridX'], r['gridY'], 0))
    print(f"  落在路面: {on}/{len(recs)} = {on*100//len(recs)}%")

    # 主路判据有效性：长度/宽度是否真能区分主次
    import statistics
    spreads_l, spreads_w, forks = [], [], 0
    for r in recs:
        if r['type'] != 'junction': continue
        bs = r['branches']
        if len(bs) < 2: continue
        rs = sorted(b['reachM'] for b in bs)
        ws = sorted(b['widthCells'] for b in bs)
        if rs[-1] > 0:
            spreads_l.append(rs[-1] / max(rs[0], 1))
            spreads_w.append(ws[-1] / max(ws[0], 0.1))
        for i, inc in enumerate(bs):
            car = (inc['deg'] + 180.0) % 360.0
            near = [b for j, b in enumerate(bs)
                    if j != i and angdiff(car, b['deg']) < 25.0]
            if len(near) >= 2: forks += 1
    if spreads_l:
        print(f"\n  主路判据区分度（最长/最短）：")
        print(f"    长度比 中位 {statistics.median(spreads_l):.2f}")
        print(f"    宽度比 中位 {statistics.median(spreads_w):.2f}")
        print(f"    Y形岔路情形 {forks}（每条来路都试）")

if __name__ == '__main__':
    main()
