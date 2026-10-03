#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v5_to_graph.py —— V5 1px 中心线 → 可寻路矢量图（第三版 · 性能版）

用户 2026-10-03 16:3x：
  「你他妈卡三分多钟了，继续给我做矢量图……给我用最快的办法跑出来」

卡死原因（实测定位）：
  ① cluster_nodes 里对 13056² 全图跑 np.isin(lab, members)，簇数几百 → O(簇数×H×W)
  ② 同时开了 3 张 int32 标签图，每张 13056²×4B = 682MB → 16GB 机器直接换页

本版做法：**一张全尺寸 int32 标签图都不多开**
  · 节点像素只有 ~682 个 → 并查集 + 网格哈希，纯 Python 处理坐标，秒出
  · 端点归属用 dict 查表（8 邻域），不需要 pad 一张全图
  · 边连通域只用一次 cv2.connectedComponentsWithStats，用完立刻 del
"""
import os, json, math, heapq, random, sys
from collections import Counter, defaultdict
import numpy as np
import cv2

SK = 'docs/roadnet/v5/V5_line_全分辨率.png'
OUTG = 'tools/roadnet/v5_graph.json'
OUTR = 'tools/roadnet/v5_graph_report.json'
M_PER_PX = 0.61
MAP_SIZE = 13056
META_MAP = 'models/bigworldmap-13056.jpg'

A_CAL, B_CAL = 0.016394586684750773, 5.693519256055879e-08
TX_CAL, TY_CAL = 6526.474380746091, 5210.664390686138

NODE_MERGE_PX = float(os.environ.get('NODE_MERGE_PX', 6))
RDP_EPS = float(os.environ.get('RDP_EPS', 1.8))
MIN_EDGE_PX = int(os.environ.get('MIN_EDGE_PX', 3))
RING = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]


def crossing_number(sk):
    """交叉数：1=端点  2=通路  >=3=真路口（比邻居数准，不会被斜角台阶骗）"""
    H, W = sk.shape
    p = np.zeros((H + 2, W + 2), np.uint8)
    p[1:-1, 1:-1] = sk
    ring = [p[1 + dy:H + 1 + dy, 1 + dx:W + 1 + dx] for dy, dx in RING]
    cn = np.zeros((H, W), np.uint8)
    for i in range(8):
        cn += ((ring[i] == 0) & (ring[(i + 1) % 8] == 1)).astype(np.uint8)
    return cn


def cluster_points(pts, radius):
    """pts=[(y,x)] → (clusters:list[list[int]], centers:list[(x,y)]) 网格哈希+并查集"""
    n = len(pts)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    cell = max(radius, 1.0)
    grid = defaultdict(list)
    for i, (y, x) in enumerate(pts):
        grid[(int(x // cell), int(y // cell))].append(i)
    r2 = radius * radius
    for (gx, gy), members in grid.items():
        near = []
        for ddx in (-1, 0, 1):
            for ddy in (-1, 0, 1):
                near.extend(grid.get((gx + ddx, gy + ddy), ()))
        for ai in members:
            y1, x1 = pts[ai]
            for bi in near:
                if bi <= ai:
                    continue
                y2, x2 = pts[bi]
                if (x1 - x2) ** 2 + (y1 - y2) ** 2 <= r2:
                    union(ai, bi)
    groups = defaultdict(list)
    for i in range(n):
        groups[find(i)].append(i)
    clusters = []
    centers = []
    for root, members in sorted(groups.items()):
        sy = sum(pts[m][0] for m in members) / len(members)
        sx = sum(pts[m][1] for m in members) / len(members)
        clusters.append(members)
        centers.append((int(round(sx)), int(round(sy))))
    return clusters, centers


def order_component(cmask):
    """单像素宽连通域 → 有序折线 [(y,x)...]

    前提：调用方已保证该连通域是**简单路径**（节点像素及其外圈都已删除）。
    此时每个像素最多 2 个邻居，贪婪走一遍即无损。
    """
    ys, xs = np.nonzero(cmask)
    pts = set(zip(ys.tolist(), xs.tolist()))
    if not pts:
        return []
    h, w = cmask.shape

    def nb(p):
        y, x = p
        out = []
        for dy, dx in RING:
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and (ny, nx) in pts:
                out.append((ny, nx))
        return out

    ends = [p for p in pts if len(nb(p)) == 1]
    start = ends[0] if ends else next(iter(pts))
    path = [start]
    used = {start}
    cur = start
    while True:
        nxt = None
        for q in nb(cur):
            if q not in used:
                nxt = q
                break
        if nxt is None:
            break
        path.append(nxt)
        used.add(nxt)
        cur = nxt
    return path



def main():
    t0 = __import__('time').time()
    print('═══ ① 读 1px 中心线 ═══', flush=True)
    sk = (cv2.imread(SK, cv2.IMREAD_GRAYSCALE) > 0).astype(np.uint8)
    H, W = sk.shape
    n_fg = int(sk.sum())
    print(f'  {W}x{H}  前景 {n_fg} px = {n_fg*M_PER_PX/1000:.1f} km', flush=True)

    print('═══ ② 交叉数分类 ═══', flush=True)
    cn = crossing_number(sk)
    is_sk = sk > 0
    end_px = is_sk & (cn == 1)
    junc_px = is_sk & (cn >= 3)
    iso_px = is_sk & (cn == 0)
    n_end, n_junc, n_iso = int(end_px.sum()), int(junc_px.sum()), int(iso_px.sum())
    print(f'  端点 {n_end}  路口像素 {n_junc}  孤点 {n_iso}', flush=True)

    node_mask = end_px | junc_px | iso_px
    del cn, end_px, junc_px
    ys, xs = np.nonzero(node_mask)
    node_pts = list(zip(ys.tolist(), xs.tolist()))
    print(f'  节点像素 {len(node_pts)}', flush=True)
    del node_mask

    print('═══ ③ 节点聚类（网格哈希+并查集，纯坐标） ═══', flush=True)
    clusters, centers = cluster_points(node_pts, NODE_MERGE_PX)
    print(f'  → 簇 {len(clusters)}', flush=True)
    # 像素 → 簇号 查表
    px2cl = {}
    for ci, members in enumerate(clusters):
        for m in members:
            px2cl[node_pts[m]] = ci + 1
    del node_pts, clusters

    print('═══ ④ 切边（骨架 − 节点像素及其外圈） ═══', flush=True)
    # ★ 关键：只删路口像素本身不够！8 连通下三条支路仍会在对角线上黏成一块，
    #   实测只切出 242 段（应为 ~600 段），且总长算成 152%。
    #   必须把节点像素及其 3x3 外圈一起删，支路才真正断开成简单路径。
    node_full = np.zeros((H, W), np.uint8)
    for (py, px) in px2cl:
        node_full[py, px] = 1
    node_dil = cv2.dilate(node_full, cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3)))
    del node_full
    edge_skel = (is_sk & (node_dil == 0)).astype(np.uint8)
    del node_dil, is_sk
    n_e, elab, est, _ = cv2.connectedComponentsWithStats(edge_skel, 8)
    print(f'  边连通域 {n_e-1}', flush=True)

    edges = []
    drop_tiny = 0
    for i in range(1, n_e):
        x, y, w, h, area = (int(est[i, 0]), int(est[i, 1]), int(est[i, 2]),
                            int(est[i, 3]), int(est[i, 4]))
        if area < MIN_EDGE_PX:
            drop_tiny += 1
            continue
        sub = (elab[y:y + h, x:x + w] == i)
        path = order_component(sub)
        if not path:
            continue
        path = [(py + y, px + x) for (py, px) in path]
        ends_cl = []
        for (py, px) in (path[0], path[-1]):
            votes = Counter()
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    v = px2cl.get((py + dy, px + dx))
                    if v:
                        votes[v] += 1
            ends_cl.append(votes.most_common(1)[0][0] if votes else None)
        a, b = ends_cl
        if a is None and b is None:
            continue
        if a is None:
            a = b
        if b is None:
            b = a
        L = 0.0
        for k in range(1, len(path)):
            L += math.hypot(path[k][1] - path[k - 1][1], path[k][0] - path[k - 1][0])
        # 端点要算到节点中心，否则每次过路口都少 3~6px，累计误差很大
        if a == b:
            pass
        else:
            cy_a = centers[a - 1][1]
            cx_a = centers[a - 1][0]
            cy_b = centers[b - 1][1]
            cx_b = centers[b - 1][0]
            L += math.hypot(path[0][1] - cx_a, path[0][0] - cy_a)
            L += math.hypot(path[-1][1] - cx_b, path[-1][0] - cy_b)
        if len(path) >= 3:
            arr = np.array([(px, py) for (py, px) in path], np.int32).reshape(-1, 1, 2)
            simp = cv2.approxPolyDP(arr, RDP_EPS, False).reshape(-1, 2)
        else:
            simp = np.array([(px, py) for (py, px) in path], np.int32).reshape(-1, 2)
        edges.append({'a': int(a), 'b': int(b), 'len_px': round(L, 1),
                      'len_m': round(L * M_PER_PX, 1),
                      'poly': [[int(p[0]), int(p[1])] for p in simp]})
    del elab, est, edge_skel
    print(f'  有效边 {len(edges)}  丢弃过小 {drop_tiny}', flush=True)

    ids = sorted({e['a'] for e in edges} | {e['b'] for e in edges})
    remap = {o: i for i, o in enumerate(ids)}
    for e in edges:
        e['a'] = remap[e['a']]
        e['b'] = remap[e['b']]
    nodes = []
    for o in ids:
        cx, cy = centers[o - 1]
        nodes.append({'id': remap[o], 'x': int(cx), 'y': int(cy), 'deg': 0})
    deg = Counter()
    for e in edges:
        deg[e['a']] += 1
        deg[e['b']] += 1
    for n in nodes:
        n['deg'] = int(deg.get(n['id'], 0))

    tot_m = sum(e['len_m'] for e in edges)
    cov = sum(e['len_m'] for e in edges) / (n_fg * M_PER_PX) * 100
    print(f'★ 图: 节点 {len(nodes)}  边 {len(edges)}  总长 {tot_m/1000:.1f} km '
          f'(覆盖骨架 {cov:.1f}%)', flush=True)
    c = Counter(n['deg'] for n in nodes)
    print('  度分布: ' + '  '.join(f'deg{d}:{c[d]}' for d in sorted(c)[:10]), flush=True)

    print('═══ ⑤ Dijkstra 自检 ═══', flush=True)
    adj = defaultdict(list)
    for e in edges:
        adj[e['a']].append((e['b'], e['len_px']))
        adj[e['b']].append((e['a'], e['len_px']))

    def dijkstra(s, t):
        dist = {s: 0.0}
        pq = [(0.0, s)]
        prev = {}
        done = set()
        while pq:
            d, u = heapq.heappop(pq)
            if u in done:
                continue
            done.add(u)
            if u == t:
                break
            for v, w in adj.get(u, ()):
                nd = d + w
                if nd < dist.get(v, 1e18):
                    dist[v] = nd
                    prev[v] = u
                    heapq.heappush(pq, (nd, v))
        if t not in dist:
            return None
        p = [t]
        while p[-1] != s:
            p.append(prev[p[-1]])
        return dist[t], p[::-1]

    random.seed(7)
    ok = fail = 0
    lens = []
    for _ in range(300):
        s = random.choice(nodes)['id']
        t = random.choice(nodes)['id']
        if s == t:
            continue
        r = dijkstra(s, t)
        if r:
            ok += 1
            lens.append(r[0] * M_PER_PX)
        else:
            fail += 1
    print(f'  随机 300 对: 可达 {ok}  不可达 {fail}', flush=True)
    if lens:
        lens.sort()
        print(f'  路径中位 {lens[len(lens)//2]/1000:.2f} km  '
              f'最短 {lens[0]/1000:.3f}  最长 {lens[-1]/1000:.1f} km', flush=True)

    seen_set = set()
    comps = []
    for n in nodes:
        if n['id'] in seen_set:
            continue
        st_ = [n['id']]
        seen_set.add(n['id'])
        cnt = 0
        while st_:
            u = st_.pop()
            cnt += 1
            for v, _ in adj.get(u, ()):
                if v not in seen_set:
                    seen_set.add(v)
                    st_.append(v)
        comps.append(cnt)
    comps.sort(reverse=True)
    print(f'  连通域 {len(comps)}  最大 {comps[0]}/{len(nodes)} '
          f'({comps[0]/len(nodes)*100:.1f}%)', flush=True)
    if len(comps) > 1:
        print(f'  其余 {comps[1:9]}', flush=True)

    print('═══ ⑥ 写文件 ═══', flush=True)
    json.dump({'meta': {'map_size': MAP_SIZE, 'm_per_px': M_PER_PX,
                        'calib': {'A': A_CAL, 'B': B_CAL, 'TX': TX_CAL, 'TY': TY_CAL},
                        'source': SK},
               'nodes': nodes, 'edges': edges},
              open(OUTG, 'w'), ensure_ascii=False)
    json.dump({'nodes': len(nodes), 'edges': len(edges),
               'total_km': round(tot_m / 1000, 1),
               'skeleton_km': round(n_fg * M_PER_PX / 1000, 1),
               'skeleton_cov_pct': round(cov, 1),
               'endpoints': n_end, 'junctions_px': n_junc, 'isolated_px': n_iso,
               'node_clusters': len(centers),
               'comps': len(comps), 'largest_comp': comps[0],
               'largest_pct': round(comps[0] / len(nodes) * 100, 1),
               'dijkstra_ok': ok, 'dijkstra_fail': fail,
               'deg_dist': {int(k): int(v) for k, v in c.items()}},
              open(OUTR, 'w'), indent=1, ensure_ascii=False)
    print(f'  → {OUTG}', flush=True)

    print('═══ ⑦ 渲染校验 ═══', flush=True)
    g = cv2.imread(META_MAP, cv2.IMREAD_GRAYSCALE)
    vis = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    del g
    for e in edges:
        pts = np.array(e['poly'], np.int32)
        cv2.polylines(vis, [pts], False, (0, 0, 255), 3)
    for n in nodes:
        col = (0, 255, 0) if n['deg'] == 1 else (0, 255, 255)
        cv2.circle(vis, (n['x'], n['y']), 10, col, -1)
    cv2.imwrite('docs/roadnet/v5/V5图_节点.png',
                cv2.resize(vis, (MAP_SIZE // 2, MAP_SIZE // 2), interpolation=cv2.INTER_AREA))
    del vis
    print(f'  → docs/roadnet/v5/V5图_节点.png', flush=True)
    print(f'═══ 总耗时 {__import__("time").time()-t0:.1f}s ═══', flush=True)


if __name__ == '__main__':
    main()
