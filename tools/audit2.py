#!/usr/bin/env python3
"""全量审计 + 反向推导（无 fork 版，避开 macOS fork+OpenCV 死锁）。

两阶段：
  1) 把所有样本统一成 1280x803 灰度缓存（只做一次，之后秒开）
  2) 用 OpenCV 自带多线程逐模板全图匹配，反推每个节点的偏移
进度写 build/audit.log，可随时查看。
"""
import cv2
import json
import numpy as np
import os
import glob
import time

cv2.setNumThreads(8)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, 'MaaNTE/assets/resource/base')
CACHE = os.path.join(ROOT, 'data/_gray_cache')
LOG = os.path.join(ROOT, 'build/audit.log')
OUT = os.path.join(ROOT, 'build/audit_result.json')
os.makedirs(CACHE, exist_ok=True)
os.makedirs(os.path.dirname(LOG), exist_ok=True)

THRESH_HIT = 0.85
THRESH_MAYBE = 0.70


def log(msg):
    line = f'{time.strftime("%H:%M:%S")} {msg}'
    with open(LOG, 'a') as f:
        f.write(line + '\n')
    print(line, flush=True)


def to_gray1280(p):
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


def main():
    open(LOG, 'w').close()
    log('=== 开始 ===')

    NODES = json.load(open(os.path.join(ROOT, 'build/nodes_inventory.json')))
    TPL_OK = json.load(open(os.path.join(ROOT, 'build/templates_ok.json')))

    # ---------- 阶段 1：缓存 ----------
    srcs = []
    for d in ('data/mac_shots', 'data/watch'):
        srcs += glob.glob(os.path.join(ROOT, d, '*.png'))
    srcs = sorted(set(srcs))
    log(f'样本池 {len(srcs)}')

    cache_meta = os.path.join(CACHE, 'index.json')
    if os.path.exists(cache_meta):
        idx = json.load(open(cache_meta))
        log(f'复用缓存 {len(idx)}')
    else:
        idx = []
        for i, p in enumerate(srcs):
            key = os.path.splitext(os.path.basename(p))[0]
            dst = os.path.join(CACHE, key + '.png')
            if not os.path.exists(dst):
                g = to_gray1280(p)
                if g is None:
                    continue
                cv2.imwrite(dst, g)
            idx.append({'src': p, 'gray': dst, 'key': key})
            if (i + 1) % 40 == 0:
                log(f'  缓存 {i+1}/{len(srcs)}')
        json.dump(idx, open(cache_meta, 'w'), ensure_ascii=False)
        log(f'缓存完成 {len(idx)}')

    # 去重（在灰度缩略图上）
    uniq, thumbs = [], []
    for e in idx:
        g = cv2.imread(e['gray'], cv2.IMREAD_GRAYSCALE)
        if g is None:
            continue
        t = cv2.resize(g, (160, 100), interpolation=cv2.INTER_AREA)
        if any(float(np.mean(cv2.absdiff(t, u))) < 9.0 for u in thumbs):
            continue
        uniq.append(e)
        thumbs.append(t)
    log(f'去重后 {len(uniq)} 张')

    shots = []
    for e in uniq:
        g = cv2.imread(e['gray'], cv2.IMREAD_GRAYSCALE)
        if g is not None:
            shots.append((e['key'], g))
    log(f'载入内存 {len(shots)} 张')

    # ---------- 阶段 2：匹配 ----------
    results = {}
    t0 = time.time()
    for i, rel in enumerate(TPL_OK):
        tpl = cv2.imread(os.path.join(BASE, 'image', rel))
        if tpl is None:
            results[rel] = {'error': 'unreadable'}
            continue
        tg = cv2.cvtColor(tpl, cv2.COLOR_BGR2GRAY)
        th, tw = tg.shape
        best = (-2.0, -1, -1, None)
        for key, sg in shots:
            if th > sg.shape[0] or tw > sg.shape[1]:
                continue
            r = cv2.matchTemplate(sg, tg, cv2.TM_CCOEFF_NORMED)
            _, mx, _, ml = cv2.minMaxLoc(r)
            if mx > best[0]:
                best = (float(mx), int(ml[0]), int(ml[1]), key)
        results[rel] = {'score': round(best[0], 4), 'x': best[1], 'y': best[2],
                        'tpl_w': tw, 'tpl_h': th, 'shot': best[3]}
        if (i + 1) % 5 == 0:
            el = time.time() - t0
            log(f'  [{i+1}/{len(TPL_OK)}] {rel} -> {best[0]:.3f}  ({el:.0f}s)')

    # ---------- 反推 ----------
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
            e['delta'] = [best['x'] - roi[0], best['y'] - roi[1]]
            if best['score'] >= THRESH_HIT:
                e['roi_derived'] = [best['x'], best['y'],
                                    max(roi[2], tw), max(roi[3], th)]
                e['verdict'] = 'hit'
            else:
                e['verdict'] = 'maybe'
        else:
            e['verdict'] = 'no-roi' if not roi else 'low'
        derived[name] = e

    json.dump({'templates': results, 'nodes': derived,
               'stats': {'pool': len(srcs), 'uniq': len(uniq),
                         'templates': len(TPL_OK), 'nodes': len(derived),
                         'elapsed_sec': round(time.time() - t0, 1)}},
              open(OUT, 'w'), ensure_ascii=False, indent=1)

    v = {}
    for d in derived.values():
        v[d['verdict']] = v.get(d['verdict'], 0) + 1
    log('=== 判定 ===')
    for k, c in sorted(v.items(), key=lambda x: -x[1]):
        log(f'  {k:8s} {c}')
    hits = sorted([(n, d) for n, d in derived.items() if d['verdict'] == 'hit'],
                  key=lambda x: -x[1]['score'])
    log(f'=== 命中 {len(hits)} ===')
    for n, d in hits[:30]:
        dx, dy = d['delta']
        log(f'  {d["score"]:.3f} Δ({dx:+5d},{dy:+5d}) {n[:44]}')
    if hits:
        dxs = [d['delta'][0] for _, d in hits]
        dys = [d['delta'][1] for _, d in hits]
        log(f'Δx 中位 {int(np.median(dxs)):+d} ({min(dxs):+d}~{max(dxs):+d})')
        log(f'Δy 中位 {int(np.median(dys)):+d} ({min(dys):+d}~{max(dys):+d})')
    log(f'=== 完成 -> {OUT} ===')


if __name__ == '__main__':
    main()
