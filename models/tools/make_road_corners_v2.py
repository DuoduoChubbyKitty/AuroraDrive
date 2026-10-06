#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_road_corners_v2.py — 弯道打点 v2（密集 · 双向 · 覆盖整个弯道）

【v1 的三个致命错误（用户 2026-09-30 指出）】
  1. **一个弯道只打一个点** —— 弯道是"一整段"，车从不同方向来、从不同车道来，
     打的点位置都不同。只打一个点 → 从别的方向开过来直接漏掉。
     ⟹ v2：沿弯道**密集布点**（每 ~12m 一个），覆盖整段弯道。
  2. **只记一个进入方向** —— 一条弯道有**两个进入方向**（A→B 和 B→A），
     弯度左右相反。只记一个 → 反向行驶时方向全错。
     ⟹ v2：每个位置生成**两条记录**（两个进入方向各一条，turnSign 相反）。
  3. **路网有断裂（斑马线）没发现** —— 底图斑马线处灰度 17~68（路面 80~88），
     二值化后被挖成 837 处窄缝，射线打到缝里就"断"了。
     ⟹ v2：输入用**闭运算填缝后**的位图（road_prior_2048_t70_fixed.png）。

【方法】逐点曲率（不聚类）：
  沿路网骨架每 6 格（约 23m）取一点；
  向 24 方向发射射线量「连续可达长度」→ 找分支峰值；
  两分支夹角偏离 180° = 弯度；分支数 >= 3 = 路口（也记，标注类型）。

【输出】models/road_corners_v2.json
  字段: worldX, worldY, gridX, gridY,
        headingIn (进入方向罗盘角), turnDeg, turnSign(±1),
        radiusM, grade, type(bend/junction), branchCount

用法: python3 models/tools/make_road_corners_v2.py
"""
import numpy as np, math, json
from PIL import Image

PRIOR = 'models/road_prior_2048_t70_fixed.png'
OUT   = 'models/road_corners_v2.json'
N = 2048
MAP = 13056.0
CELL = MAP / N * 0.61          # 3.89 m/格

A = 0.016394586684750773
B = 5.693519256055879e-08
TX = 6526.474380746091
TY = 5210.664390686138
DEN = A*A + B*B

STEP_CAP  = 2.0
MAX_REACH = 40.0
NANG      = 36          # 每 10° 一条射线（比 v1 的 24 方向更细）
MIN_BRANCH = 10.0
MIN_BEND  = 8.0
SEED_STEP = 6           # ★ 密集：每 6 格 ≈ 23m 一个种子（v1 是 7 且聚类成 1 点）

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

def compass_of(img_ang_deg):
    a = math.radians(img_ang_deg)
    c = math.degrees(math.atan2(math.cos(a), -math.sin(a))) % 360.0
    return c

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
            typ = 'junction' if len(pk) >= 3 else 'bend'

            if typ == 'bend':
                (a1, r1), (a2, r2) = pk[0], pk[1]
                d = abs(a1-a2) % 360.0; d = min(d, 360.0-d)
                bend = 180.0 - d
                if bend < MIN_BEND: continue
                if min(r1, r2) < MIN_BRANCH: continue
                wx, wy = g2w(gx, gy)
                span_m = min(r1, r2) * CELL * 2
                radius = span_m / math.radians(max(bend, 1e-6))
                grade = '急' if bend > 45 else ('中' if bend > 25 else '缓')
                # ★ 双向记录：两个进入方向各一条
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
                # 路口：记位置 + 各分支方向（转向逻辑后续再做，先留数据）
                wx, wy = g2w(gx, gy)
                branches = [round(compass_of(a),1) for a, _ in pk]
                recs.append(dict(
                    worldX=round(wx,1), worldY=round(wy,1),
                    gridX=gx, gridY=gy,
                    headingIn=None, headingOut=None,
                    turnDeg=0.0, turnSign=0,
                    radiusM=0.0, grade='路口',
                    type='junction', branchCount=len(pk),
                    branches=branches))
                n_junc += 1

    json.dump(recs, open(OUT, 'w'), ensure_ascii=False, indent=1)
    from collections import Counter
    print(f"\n✓ {OUT}")
    print(f"  总记录 {len(recs)}  (弯道位置 {n_bend} 个 → 双向共 {n_bend*2} 条；路口 {n_junc} 条)")
    print(f"  弯道档位: {Counter(r['grade'] for r in recs if r['type']=='bend')}")
    print(f"  弯道数 {sum(1 for r in recs if r['type']=='bend')}  路口数 {sum(1 for r in recs if r['type']=='junction')}")
    # 复核落在路面
    on = sum(1 for r in recs if road(r['gridX'], r['gridY'], 0))
    print(f"  落在路面: {on}/{len(recs)} = {on*100//len(recs)}%")

if __name__ == '__main__':
    main()
