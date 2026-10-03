#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
route_v5.py —— V5 路网寻路（A* + 拐弯惩罚）

用户 2026-10-03：
  「我想选的就是拐弯最少，距离又少，速度最快……路径规划又不值钱，零点几毫秒」

三个目标互相打架，标准解法是**把拐弯折成"等效米数"塞进边权**：
    代价 = 边长度 + W × (转向角 / 90°)
      W = 0    → 纯最短距离（拐弯多）
      W = 30   → 轻微讨厌拐弯
      W = 80   → 明显偏好直行
      W = 200  → 几乎等同「拐弯最少优先」
      turns_first → 字典序：先比拐弯数，再比距离

实现要点：
  **状态图 = 有向半边**（edge, 方向）。只用节点建图的话，
  A* 到了路口不知道"我是从哪条路进来的"，根本算不出转向角。
  半边状态数 = 2 × 825 = 1650，启发式用欧氏直线距离（可采纳，保证最优）。
"""
import json, math, heapq, random, time, os, sys
from collections import defaultdict
import numpy as np
import cv2

G = 'tools/roadnet/v5_graph.json'
META_MAP = 'models/bigworldmap-13056.jpg'
OUT = 'docs/roadnet/v5/寻路'
D_DIR = 6.0                 # 估算方向时，从节点沿边取 6px 作为方向向量
TURN_THRESH_DEG = 25.0      # 转向角 > 25° 才算"拐了个弯"
BIG = 1e7                   # turns_first 模式的拐弯权重

os.makedirs(OUT, exist_ok=True)


def dir_from(poly, at_start):
    """从端点沿折线走 D_DIR 像素，返回该处单位方向向量"""
    pts = poly if at_start else poly[::-1]
    x0, y0 = pts[0]
    acc = 0.0
    for k in range(1, len(pts)):
        x1, y1 = pts[k]
        acc += math.hypot(x1 - x0, y1 - y0)
        if acc >= D_DIR or k == len(pts) - 1:
            vx, vy = x1 - x0, y1 - y0
            n = math.hypot(vx, vy) or 1.0
            return vx / n, vy / n
    return 0.0, 0.0


def angle_deg(d1, d2):
    """两方向向量夹角（度）"""
    c = max(-1.0, min(1.0, d1[0] * d2[0] + d1[1] * d2[1]))
    return math.degrees(math.acos(c))


class Router:
    def __init__(self, gj):
        self.nodes = {n['id']: n for n in gj['nodes']}
        self.edges = gj['edges']
        self.mpp = gj['meta']['m_per_px']
        self.inc = defaultdict(list)      # node → [(edge_idx, endpoint)]
        self.dirs = []                    # [(dir_a, dir_b)]
        for i, e in enumerate(self.edges):
            poly = e['poly']
            da = dir_from(poly, True)
            db = dir_from(poly, False)
            self.dirs.append((da, db))
            self.inc[e['a']].append((i, 0))
            self.inc[e['b']].append((i, 1))
        self.n_state = 2 * len(self.edges)
        self._hcache = {}

    # ── 半边状态工具 ──
    def start_node(self, i, df):
        return self.edges[i]['a'] if df == 0 else self.edges[i]['b']

    def end_node(self, i, df):
        return self.edges[i]['b'] if df == 0 else self.edges[i]['a']

    def leave_dir(self, i, df):
        return self.dirs[i][0] if df == 0 else self.dirs[i][1]

    def arrive_dir(self, i, df):
        """行至终点时的行进方向 = 终点处入边方向的取反"""
        d = self.dirs[i][1] if df == 0 else self.dirs[i][0]
        return (-d[0], -d[1])

    def h(self, u, t):
        """欧氏直线距离（可采纳）"""
        key = (u, t)
        v = self._hcache.get(key)
        if v is None:
            a, b = self.nodes[u], self.nodes[t]
            v = math.hypot(a['x'] - b['x'], a['y'] - b['y']) * self.mpp
            self._hcache[key] = v
        return v

    def route(self, s, t, turn_w=0.0, turns_first=False):
        """A* 求路。返回 dict 或 None"""
        if s == t:
            return None
        pq = []
        cnt = 0
        best_g = {}
        prev = {}
        # 起步：从 s 出发的任意半边，无拐弯惩罚
        for (i, ep) in self.inc.get(s, ()):
            df = 0 if ep == 0 else 1
            g = self.edges[i]['len_m']
            st = (i, df)
            if g < best_g.get(st, 1e18):
                best_g[st] = g
                prev[st] = None
                cnt += 1
                f = g + self.h(self.end_node(i, df), t)
                heapq.heappush(pq, (f, cnt, st))
        goal = None
        closed = set()
        while pq:
            f, _, st = heapq.heappop(pq)
            if st in closed:
                continue
            closed.add(st)
            i, df = st
            u = self.end_node(i, df)
            if u == t:
                goal = st
                break
            a_dir = self.arrive_dir(i, df)
            g0 = best_g[st]
            for (j, ep) in self.inc.get(u, ()):
                if j == i:
                    continue
                df2 = 0 if ep == 0 else 1
                st2 = (j, df2)
                if st2 in closed:
                    continue
                ang = angle_deg(a_dir, self.leave_dir(j, ep))
                if turns_first:
                    pen = BIG if ang > TURN_THRESH_DEG else 0.0
                else:
                    pen = turn_w * (ang / 90.0)
                ng = g0 + self.edges[j]['len_m'] + pen
                if ng < best_g.get(st2, 1e18):
                    best_g[st2] = ng
                    prev[st2] = st
                    cnt += 1
                    heapq.heappush(pq, (ng + self.h(self.end_node(j, df2), t), cnt, st2))
        if goal is None:
            return None
        # 回溯
        chain = []
        cur = goal
        while cur is not None:
            chain.append(cur)
            cur = prev[cur]
        chain.reverse()
        # 统计
        dist = 0.0
        turns = 0
        pts = []
        for k, (i, df) in enumerate(chain):
            e = self.edges[i]
            poly = e['poly'] if df == 0 else e['poly'][::-1]
            dist += e['len_m']
            if k:
                pi, pdf = chain[k - 1]
                ang = angle_deg(self.arrive_dir(pi, pdf), self.leave_dir(i, df))
                if ang > TURN_THRESH_DEG:
                    turns += 1
            for p in poly:
                if not pts or pts[-1] != (p[0], p[1]):
                    pts.append((p[0], p[1]))
        return {'dist_m': dist, 'turns': turns, 'cost': best_g[goal],
                'states': len(chain), 'pts': pts,
                'nodes': [self.start_node(i, df) for (i, df) in chain] +
                         [self.end_node(*chain[-1])]}


def load():
    return Router(json.load(open(G)))


def pick_pairs(R, n=300, seed=11):
    ids = list(R.nodes)
    random.seed(seed)
    out = []
    while len(out) < n:
        a, b = random.choice(ids), random.choice(ids)
        if a == b:
            continue
        pa, pb = R.nodes[a], R.nodes[b]
        if math.hypot(pa['x'] - pb['x'], pa['y'] - pb['y']) * R.mpp > 2000:
            out.append((a, b))
    return out


def sweep():
    R = load()
    pairs = pick_pairs(R, 300)
    print(f'图: 节点 {len(R.nodes)}  边 {len(R.edges)}  状态 {R.n_state}')
    print(f'采样 {len(pairs)} 对（直线距离 > 2km）')
    print()
    hdr = f'{"模式":<26} {"中位耗时":>9} {"中位拐弯":>9} {"中位距离":>10} {"比纯距离远":>11}'
    print(hdr)
    print('-' * len(hdr))

    rows = []
    cfgs = [
        ('纯最短距离 W=0',       0.0,          False),
        ('W=15 微厌拐弯',        15.0,         False),
        ('W=30 轻厌拐弯',        30.0,         False),
        ('W=50 中厌拐弯',        50.0,         False),
        ('W=80 明显偏好直行',    80.0,         False),
        ('W=120',                120.0,        False),
        ('W=200 几乎不拐弯',     200.0,        False),
        ('W=400 极强',           400.0,        False),
        ('拐弯最少优先(字典序)',  0.0,          True),
    ]
    base_dist = {}
    for name, w, tf in cfgs:
        ts, turns, dists = [], [], []
        for s, t in pairs:
            a = time.perf_counter()
            r = R.route(s, t, w, tf)
            ts.append((time.perf_counter() - a) * 1000)
            if r:
                turns.append(r['turns'])
                dists.append(r['dist_m'])
        ts.sort()
        med_t = ts[len(ts) // 2]
        mt = sorted(turns)[len(turns) // 2] if turns else 0
        md = sorted(dists)[len(dists) // 2] if dists else 0
        if name.startswith('纯最短'):
            base_dist['v'] = md
        det = (md / base_dist.get('v', md) - 1) * 100 if base_dist.get('v') else 0
        rows.append((name, med_t, mt, md, det, sum(turns) / max(1, len(turns))))
        print(f'{name:<26} {med_t:>7.2f}ms {mt:>9.0f} {md/1000:>8.2f}km {det:>10.1f}%')

    print()
    print('平均拐弯数（更能看出差别）：')
    for name, _, mt, md, det, avg in rows:
        bar = '█' * int(avg / 2)
        print(f'  {name:<26} 平均 {avg:>5.1f} 个  {bar}')

    json.dump({'rows': [{'name': n, 'ms': round(t, 3), 'turns_med': mt,
                         'dist_km': round(d / 1000, 2), 'detour_pct': round(det, 1),
                         'turns_avg': round(a, 1)} for n, t, mt, d, det, a in rows]},
              open(f'{OUT}/权重扫描.json', 'w'), indent=1, ensure_ascii=False)
    print(f'  → {OUT}/权重扫描.json')
    return R, pairs


def render(R, pairs):
    """挑「纯距离」和「最少拐弯」差别最大的那对，画出来对比"""
    print('\n找对比最强的起终点…', flush=True)
    best = None
    for s, t in pairs:
        r0 = R.route(s, t, 0.0)
        r1 = R.route(s, t, 200.0)
        r2 = R.route(s, t, 0.0, True)
        if not (r0 and r1 and r2):
            continue
        score = (r0['turns'] - r1['turns']) + (0 if r0['turns'] == 0 else 0)
        if best is None or score > best[0]:
            best = (score, s, t, r0, r1, r2)
    if best is None:
        print('  没找到')
        return
    score, s, t, r0, r1, r2 = best
    print(f'  起点 {s} @{R.nodes[s]["x"]},{R.nodes[s]["y"]}')
    print(f'  终点 {t} @{R.nodes[t]["x"]},{R.nodes[t]["y"]}')
    for nm, r in (('纯距离', r0), ('W=200', r1), ('拐弯最少', r2)):
        print(f'    {nm:<8} {r["dist_m"]/1000:.2f} km  拐弯 {r["turns"]:>3}  段 {r["states"]}')

    g = cv2.imread(META_MAP, cv2.IMREAD_GRAYSCALE)
    base = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    COL = [(0, 0, 255), (0, 200, 255), (0, 255, 0)]     # 蓝=纯距离 橙黄=W200 绿=最少拐弯
    vis = base.copy()
    for r, c in zip((r0, r1, r2), COL):
        pts = np.array(r['pts'], np.int32)
        cv2.polylines(vis, [pts], False, c, 9)
    for nid, c in ((s, (255, 0, 255)), (t, (255, 0, 0))):
        cv2.circle(vis, (R.nodes[nid]['x'], R.nodes[nid]['y']), 30, c, -1)
    cv2.imwrite(f'{OUT}/对比_纯距离vs最少拐弯.png',
                cv2.resize(vis, (6528, 6528), interpolation=cv2.INTER_AREA))
    # 局部放大
    xs = [p[0] for p in r0['pts']] + [p[0] for p in r2['pts']]
    ys = [p[1] for p in r0['pts']] + [p[1] for p in r2['pts']]
    x0, x1 = max(0, min(xs) - 300), min(13056, max(xs) + 300)
    y0, y1 = max(0, min(ys) - 300), min(13056, max(ys) + 300)
    if x1 - x0 > 200 and y1 - y0 > 200:
        crop = np.hstack([base[y0:y1, x0:x1], vis[y0:y1, x0:x1]])
        f = min(2.0, 1600 / max(1, crop.shape[1]))
        cv2.imwrite(f'{OUT}/对比_放大.png',
                    cv2.resize(crop, None, fx=f, fy=f, interpolation=cv2.INTER_AREA))
    print(f'  → {OUT}/对比_纯距离vs最少拐弯.png')

    # 三条路各画一张清楚的
    for nm, r, c, tag in (('纯距离', r0, (0, 0, 255), 'W0'),
                          ('W200', r1, (0, 200, 255), 'W200'),
                          ('最少拐弯', r2, (0, 255, 0), 'TURNS')):
        v = base.copy()
        cv2.polylines(v, [np.array(r['pts'], np.int32)], False, c, 9)
        cv2.circle(v, (R.nodes[s]['x'], R.nodes[s]['y']), 30, (255, 0, 255), -1)
        cv2.circle(v, (R.nodes[t]['x'], R.nodes[t]['y']), 30, (255, 0, 0), -1)
        cv2.imwrite(f'{OUT}/路线_{tag}.png',
                    cv2.resize(v, (6528, 6528), interpolation=cv2.INTER_AREA))


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'sweep'
    if mode == 'sweep':
        R, pairs = sweep()
        render(R, pairs)
    elif mode == 'render':
        R = load()
        render(R, pick_pairs(R, 120))
