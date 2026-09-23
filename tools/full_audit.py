#!/usr/bin/env python3
"""全量审计 + 反向推导偏移（多进程并行版）。

模板为 1280 宽空间设计；截图缩到 1280 宽后模板应 1:1 命中。
全图搜模板 -> 实测位置；与声明 ROI 比对 -> 反推该节点该用的 ROI。
"""
import cv2
import json
import multiprocessing as mp
import numpy as np
import os
import glob
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, 'MaaNTE/assets/resource/base')
NODES = json.load(open(os.path.join(ROOT, 'build/nodes_inventory.json')))
TPL_OK = json.load(open(os.path.join(ROOT, 'build/templates_ok.json')))
SHOT_DIRS = [os.path.join(ROOT, 'data/mac_shots'), os.path.join(ROOT, 'data/watch')]
OUT = os.path.join(ROOT, 'build/audit_result.json')
THRESH_HIT = 0.85
THRESH_MAYBE = 0.70

_SHOTS = []   # fork 后共享


def load_shot(p):
    im = cv2.imread(p)
    if im is None:
        return None
    h, w = im.shape[:2]
    if w == 2940:
        im = im[66:66 + 1846, :]
        h, w = im.shape[:2]
    nh = int(round(h * 1280.0 / w))
    im = cv2.resize(im, (1280, nh), interpolation=cv2.INTER_AREA)
    g = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY)
    if g.shape[0] != 803:
        pad = np.zeros((803, 1280), np.uint8)
        hh = min(803, g.shape[0])
        pad[:hh, :] = g[:hh, :]
        g = pad
    return g


def init_shots(paths):
    global _SHOTS
    _SHOTS = []
    for p in paths:
        g = load_shot(p)
        if g is not None:
            _SHOTS.append((os.path.basename(p), g))


def work(tpl_rel):
    tp = os.path.join(BASE, 'image', tpl_rel)
    tpl = cv2.imread(tp)
    if tpl is None:
        return tpl_rel, {'error': 'unreadable'}
    tg = cv2.cvtColor(tpl, cv2.COLOR_BGR2GRAY)
    th, tw = tg.shape
    best = (-2.0, -1, -1, None)
    for name, sg in _SHOTS:
        if th > sg.shape[0] or tw > sg.shape[1]:
            continue
        r = cv2.matchTemplate(sg, tg, cv2.TM_CCOEFF_NORMED)
        _, mx, _, ml = cv2.minMaxLoc(r)
        if mx > best[0]:
            best = (float(mx), int(ml[0]), int(ml[1]), name)
    return tpl_rel, {
        'score': round(best[0], 4),
        'x': best[1], 'y': best[2],
        'tpl_w': tw, 'tpl_h': th,
        'shot': best[3],
    }


def main():
    shots = []
    for d in SHOT_DIRS:
        shots += glob.glob(os.path.join(d, '*.png'))
    shots = sorted(set(shots))
    print(f'样本池 {len(shots)} 张', flush=True)

    # 去重
    uniq, thumbs = [], []
    for p in shots:
        g = load_shot(p)
        if g is None:
            continue
        t = cv2.resize(g, (160, 100), interpolation=cv2.INTER_AREA)
        if any(float(np.mean(cv2.absdiff(t, u))) < 9.0 for u in thumbs):
            continue
        uniq.append(p)
        thumbs.append(t)
    print(f'去重后 {len(uniq)} 张', flush=True)

    # 父进程加载一次，fork 后子进程 COW 共享，避免 8 倍重复读盘
    global _SHOTS
    print('载入样本到内存...', flush=True)
    for p in uniq:
        g = load_shot(p)
        if g is not None:
            _SHOTS.append((os.path.basename(p), g))
    print(f'已载入 {len(_SHOTS)} 张 1280x803 灰度', flush=True)

    ctx = mp.get_context('fork')
    nproc = min(8, ctx.cpu_count() or 4)
    print(f'并行 {nproc} 进程 × {len(TPL_OK)} 模板', flush=True)

    results = {}
    with ctx.Pool(nproc) as pool:
        for i, (rel, res) in enumerate(pool.imap_unordered(work, TPL_OK, chunksize=1)):
            results[rel] = res
            print(f'  [{i+1}/{len(TPL_OK)}] {rel} -> {res.get("score","?")}', flush=True)
    print(f'匹配完成 {len(results)} 个模板', flush=True)

    # 反推
    derived = {}
    for name, n in NODES.items():
        t = n.get('template')
        if not t:
            continue
        ts = t if isinstance(t, list) else [t]
        cands = [results.get(x) for x in ts]
        cands = [c for c in cands if c and c.get('score', -2) > -1]
        if not cands:
            continue
        best = max(cands, key=lambda c: c['score'])
        roi = n.get('roi')
        e = {'file': n['file'], 'type': n['type'], 'score': best['score'],
             'found_at': [best['x'], best['y']],
             'tpl_size': [best['tpl_w'], best['tpl_h']],
             'roi_declared': roi, 'shot': best['shot']}
        if roi and best['score'] >= THRESH_MAYBE:
            tw, th = best['tpl_w'], best['tpl_h']
            rx, ry = roi[0], roi[1]
            e['delta'] = [best['x'] - rx, best['y'] - ry]
            if best['score'] >= THRESH_HIT:
                e['roi_derived'] = [best['x'], best['y'], max(roi[2], tw), max(roi[3], th)]
                e['verdict'] = 'hit'
            else:
                e['verdict'] = 'maybe'
        else:
            e['verdict'] = 'no-roi' if not roi else 'low'
        derived[name] = e

    json.dump({'templates': results, 'nodes': derived,
               'stats': {'pool': len(shots), 'uniq': len(uniq),
                         'templates': len(TPL_OK), 'nodes': len(derived)}},
              open(OUT, 'w'), ensure_ascii=False, indent=1)

    v = {}
    for d in derived.values():
        v[d['verdict']] = v.get(d['verdict'], 0) + 1
    print('\n=== 判定 ===')
    for k, c in sorted(v.items(), key=lambda x: -x[1]):
        print(f'  {k:8s} {c}')

    hits = sorted([(n, d) for n, d in derived.items() if d['verdict'] == 'hit'],
                  key=lambda x: -x[1]['score'])
    print(f'\n=== 命中 {len(hits)} 个 ===')
    for n, d in hits[:25]:
        dx, dy = d['delta']
        print(f'  {d["score"]:.3f} Δ({dx:+5d},{dy:+5d})  {n[:46]}')
    if hits:
        dxs = [d['delta'][0] for _, d in hits]
        dys = [d['delta'][1] for _, d in hits]
        print(f'\nΔx 中位 {int(np.median(dxs)):+d} ({min(dxs):+d}~{max(dxs):+d})')
        print(f'Δy 中位 {int(np.median(dys)):+d} ({min(dys):+d}~{max(dys):+d})')
    print(f'\n结果: {OUT}')


if __name__ == '__main__':
    main()
