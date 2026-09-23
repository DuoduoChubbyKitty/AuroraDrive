#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MaaNTE 模板 × macOS 截图 全量匹配（多进程加速版）

单线程基线约 85ms/次全屏匹配（1280x803）。
本脚本用多进程把 (模板 × 截图) 的任务对拆到所有核心上。

用法:
    python3 tools/maa_fast_match.py                 # 全量
    python3 tools/maa_fast_match.py --jobs 8        # 指定进程数
    python3 tools/maa_fast_match.py --bench         # 只测速对照
"""

import cv2
import numpy as np
import os
import sys
import glob
import json
import time
import argparse
from multiprocessing import Pool, cpu_count
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_BASE = os.path.join(ROOT, 'MaaNTE/assets/resource/base/image')
SHOTS_DIR = os.path.join(ROOT, 'data/mac_shots')

# 全局（每个子进程各自持有，避免反复读盘）
_TPL = {}
_SHOTS = {}


def _init_worker(tpl_paths, shot_paths):
    for p in tpl_paths:
        im = cv2.imread(p)
        if im is not None:
            _TPL[p] = im
    for p in shot_paths:
        im = cv2.imread(p)
        if im is not None:
            _SHOTS[p] = im


def _match_one(args):
    """匹配一个 (模板, 截图) 对，返回最优位置与分数。"""
    tpath, spath = args
    tp = _TPL.get(tpath)
    img = _SHOTS.get(spath)
    if tp is None or img is None:
        return None
    th, tw = tp.shape[:2]
    IH, IW = img.shape[:2]
    if th >= IH or tw >= IW:
        return None
    res = cv2.matchTemplate(img, tp, cv2.TM_CCOEFF_NORMED)
    _, mx, _, loc = cv2.minMaxLoc(res)
    return (tpath, spath, float(mx), int(loc[0]), int(loc[1]))


def collect_templates():
    """收集 MaaNTE 图像库里的全部模板（排除角色立绘）。"""
    out = []
    for r, _, fs in os.walk(IMG_BASE):
        if 'Character_Pic' in r:
            continue
        for f in fs:
            if f.endswith('.png'):
                out.append(os.path.join(r, f))
    return sorted(out)


def collect_shots():
    return sorted(glob.glob(os.path.join(SHOTS_DIR, '*.png')))


def run(tpl_paths, shot_paths, jobs):
    pairs = [(t, s) for t in tpl_paths for s in shot_paths]
    n = len(pairs)
    if jobs <= 1:
        _init_worker(tpl_paths, shot_paths)
        results = [_match_one(p) for p in pairs]
    else:
        with Pool(jobs, initializer=_init_worker,
                  initargs=(tpl_paths, shot_paths)) as pool:
            results = pool.map(_match_one, pairs, chunksize=max(1, n // (jobs * 8)))
    return [r for r in results if r]


def main():
    ap = argparse.ArgumentParser(description='MaaNTE 模板全量匹配（多进程）')
    ap.add_argument('--jobs', type=int, default=0, help='进程数，0=全部核心')
    ap.add_argument('--bench', action='store_true', help='只对比单线程与多进程耗时')
    ap.add_argument('--top', type=int, default=25, help='输出前 N 条')
    ap.add_argument('--out', default='build/maa_match_all.json')
    args = ap.parse_args()

    tpls = collect_templates()
    shots = collect_shots()
    jobs = args.jobs or max(1, cpu_count() - 1)

    print(f'模板: {len(tpls)} 张')
    print(f'截图: {len(shots)} 张')
    print(f'任务对: {len(tpls) * len(shots)} 次匹配')
    print(f'CPU 核心: {cpu_count()}   使用进程: {jobs}')
    print()

    if args.bench:
        # 只取一小部分做对照
        sub_t = tpls[:12]
        sub_s = shots[:6]
        print(f'[基准测试] 用 {len(sub_t)} 模板 x {len(sub_s)} 截图 = {len(sub_t)*len(sub_s)} 次')
        t0 = time.time()
        r1 = run(sub_t, sub_s, 1)
        t_single = time.time() - t0
        print(f'  单进程: {t_single:.2f}s  ({t_single/len(r1)*1000:.1f} ms/次)')

        t0 = time.time()
        r2 = run(sub_t, sub_s, jobs)
        t_par = time.time() - t0
        print(f'  {jobs} 进程: {t_par:.2f}s  ({t_par/len(r2)*1000:.1f} ms/次)')
        print(f'  加速比: {t_single/max(t_par,0.001):.1f}x')
        print(f'  全量预测: 单进程 {t_single/len(r1)*len(tpls)*len(shots):.0f}s, '
              f'多进程 {t_par/len(r2)*len(tpls)*len(shots):.0f}s')
        return 0

    t0 = time.time()
    results = run(tpls, shots, jobs)
    el = time.time() - t0

    print(f'完成: {len(results)} 条结果, 耗时 {el:.1f}s  ({el/max(len(results),1)*1000:.1f} ms/次)')
    print()

    # 按模板归并，取最高分
    best = {}
    for tpath, spath, score, x, y in results:
        rel = os.path.relpath(tpath, IMG_BASE)
        if rel not in best or score > best[rel]['score']:
            best[rel] = dict(score=score, shot=os.path.basename(spath), x=x, y=y)
    ranked = sorted(best.items(), key=lambda kv: -kv[1]['score'])

    print(f'{"模板":56s} {"分数":7s} {"落点":14s} {"出现于"}')
    print('-' * 110)
    for rel, info in ranked[:args.top]:
        print(f'{rel:56s} {info["score"]:.3f}   ({info["x"]:4d},{info["y"]:3d})   {info["shot"][-12:]}')

    os.makedirs(os.path.dirname(os.path.join(ROOT, args.out)), exist_ok=True)
    with open(os.path.join(ROOT, args.out), 'w', encoding='utf-8') as f:
        json.dump({k: v for k, v in ranked}, f, ensure_ascii=False, indent=2)
    print(f'\n已写入: {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
