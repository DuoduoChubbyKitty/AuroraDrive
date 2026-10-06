#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_road_corners.py — 从干净路网先验提取「弯道打点」（离线一次性）

【方法】射线峰值法（2026-09-30 验证有效）
  1. 沿路网骨架每 7 格取一个种子点
  2. 向 24 个方向发射射线，量「连续可达长度」（遇断点即停）
  3. 找局部峰值（相邻 30° 内合并）：
       峰值数 == 2  → 弯道（两个分支）
       峰值数 >= 3  → 路口（本轮不打点，转向逻辑太复杂、先不碰）
  4. 弯度 = 两分支夹角偏离 180° 的量；曲率半径 ≈ 弧长 / 弧度
  5. 左右转向 = 两分支方向叉积符号（图像 y 向下 → 叉积 > 0 = 向右）
  6. 聚类去重（26 格 ≈ 100m 内合并为一个弯道）
  7. **吸附**：点必须落在路面像素上（局部窗口中心化，不用组内均值 ——
     均值会落到路外的空地，这是上一版 83% 打点跑偏的直接原因）

【输入】models/road_prior_2048_t70.png （阈值 70 的干净路网，见 make_road_prior_t70.py）
【输出】models/road_corners_t70.json

用法: python3 models/tools/make_road_corners.py
"""
import numpy as np, math, json
from PIL import Image

PRIOR = 'models/road_prior_2048_t70.png'
OUT   = 'models/road_corners_t70.json'
N     = 2048
MAP   = 13056.0
CELL  = MAP / N * 0.61          # 3.89 m/格

# 校准（与 CoordinateCapture.kCalib* 同源）
A = 0.016394586684750773
B = 5.693519256055879e-08
TX = 6526.474380746091
TY = 5210.664390686138
DEN = A*A + B*B

# 参数
STEP_CAP  = 2.0       # 射线步长（格）
MAX_REACH = 40.0      # 射线最大长度（格）= 156 m
NANG      = 24        # 射线方向数（每 15°）
MIN_BRANCH = 12.0     # 分支最短长度（格）= 47 m，太短不算可选通路
MIN_BEND  = 10.0      # 最小弯度（度），小于此视为直路
SEED_STEP = 7         # 种子扫描步长（格）= 27 m
CLUSTER_R = 26        # 聚类半径（格）= 101 m

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
                d -= STEP_CAP
                break
        out.append(min(d, MAX_REACH))
    return np.array(out)

def peaks(reach):
    """局部极大；相邻 2 个方向（30°）内合并为一个分支"""
    n = len(reach); cand = []
    for i in range(n):
        if reach[i] < MIN_BRANCH: continue
        if reach[i] >= reach[(i-1) % n] and reach[i] >= reach[(i+1) % n]:
            cand.append((i, reach[i]))
    cand.sort(key=lambda c: -c[1])
    kept = []
    for i, v in cand:
        if all(min(abs(i-j), n-abs(i-j)) > 2 for j, _ in kept):
            kept.append((i, v))
    return [(math.degrees(ANGS[i]), v) for i, v in kept]

def snap_to_road(gx, gy, maxr=6):
    """吸附到最近的路面格（环形搜索）"""
    if road(gx, gy, 0): return gx, gy, 0
    for r in range(1, maxr+1):
        best = None
        for dy in range(-r, r+1):
            for dx in range(-r, r+1):
                if max(abs(dx), abs(dy)) != r: continue
                x2, y2 = gx+dx, gy+dy
                if 0 <= x2 < N and 0 <= y2 < N and prior[y2, x2]:
                    d = dx*dx + dy*dy
                    if best is None or d < best[0]: best = (d, x2, y2)
        if best: return best[1], best[2], math.sqrt(best[0])
    return None, None, None

def main():
    global prior, ANGS
    prior = np.asarray(Image.open(PRIOR).convert('L')) > 127
    ANGS = np.radians(np.arange(0, 360, 360.0/NANG))
    print(f"输入 {PRIOR}  道路占比 {prior.mean()*100:.2f}%  1格={CELL:.2f}m")

    cands = []
    for gy in range(14, N-14, SEED_STEP):
        for gx in range(14, N-14, SEED_STEP):
            if not prior[gy, gx]: continue
            pk = peaks(reaches(gx, gy))
            if len(pk) != 2: continue                 # 只要两分支（弯道）
            (a1, r1), (a2, r2) = sorted(pk, key=lambda p: -p[1])
            d = abs(a1 - a2) % 360.0
            d = min(d, 360.0 - d)
            bend = 180.0 - d                          # 偏离直线的角度
            if bend < MIN_BEND: continue
            if min(r1, r2) < MIN_BRANCH: continue
            cands.append((gx, gy, a1, r1, a2, r2, bend))
    print(f"弯道候选 {len(cands)}")

    # 聚类
    cands.sort(key=lambda c: -c[6])
    used = [False]*len(cands); segs = []
    for i, c in enumerate(cands):
        if used[i]: continue
        grp = [c]; used[i] = True
        for j in range(i+1, len(cands)):
            if used[j]: continue
            if math.hypot(cands[j][0]-c[0], cands[j][1]-c[1]) <= CLUSTER_R:
                grp.append(cands[j]); used[j] = True
        rep = max(grp, key=lambda g: g[6])
        # ⚠️ 不用均值（会落到路外）；用弯度最大的那个代表点的坐标 + 吸附
        segs.append((rep[0], rep[1], rep))
    print(f"弯道段 {len(segs)}")

    out = []; dropped = 0
    for _gx, _gy, (gx, gy, a1, r1, a2, r2, bend) in segs:
        sx, sy, sd = snap_to_road(gx, gy)
        if sx is None:
            dropped += 1; continue                    # 吸附不到路面 → 丢弃（宁缺勿错）
        wx, wy = g2w(sx, sy)
        a = math.radians(a1)
        compass = math.degrees(math.atan2(math.cos(a), -math.sin(a))) % 360.0
        d1 = (math.cos(math.radians(a1)), math.sin(math.radians(a1)))
        d2 = (math.cos(math.radians(a2)), math.sin(math.radians(a2)))
        cross = d1[0]*d2[1] - d1[1]*d2[0]
        span_m = min(r1, r2) * CELL * 2
        radius = span_m / math.radians(max(bend, 1e-6))
        grade = '急' if bend > 45 else ('中' if bend > 25 else '缓')
        out.append(dict(worldX=round(wx,1), worldY=round(wy,1),
                        gridX=sx, gridY=sy,
                        roadHeading=round(compass,1), turnDeg=round(bend,1),
                        turnSign=1 if cross > 0 else -1, radiusM=round(radius,0),
                        grade=grade, spanM=round(span_m,0),
                        snapCells=round(sd,1)))
    out.sort(key=lambda c: c['radiusM'])
    json.dump(out, open(OUT, 'w'), ensure_ascii=False, indent=1)

    from collections import Counter
    print(f"\n✓ {OUT}  {len(out)} 点（吸附失败丢弃 {dropped}）")
    print(f"  分档: {Counter(c['grade'] for c in out)}")
    # 复核：100% 落在路面
    on = sum(1 for c in out if road(c['gridX'], c['gridY'], 0))
    print(f"  落在路面: {on}/{len(out)} = {on*100//max(len(out),1)}%")
    print("\n最急 10 个:")
    for c in out[:10]:
        sd = '右' if c['turnSign'] > 0 else '左'
        print(f"  ({c['worldX']:>10.0f},{c['worldY']:>9.0f}) 进入={c['roadHeading']:>5.1f}° "
              f"弯={c['turnDeg']:>5.1f}°({sd}) 半径≈{c['radiusM']:>5.0f}m {c['grade']}")

if __name__ == '__main__':
    main()
