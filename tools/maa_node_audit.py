#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MaaNTE ROI 节点 × macOS 截图 全量核查（ROI 范围内搜索，极快）

思路
----
250 个 pipeline 节点只用到 ~37 个模板文件。每个节点本来就该在自己的 ROI 里搜索，
全屏搜索是 84 倍的无谓开销。

但 MaaNTE 的原 ROI 建立在 1280x720 基准上，而 macOS 实际识别空间是 1280x803
（顶部锚定不变 / 底部锚定 +83）。所以搜索范围取：

    [x, y - PAD, w, h + 2*PAD]        PAD = 100（覆盖 +83 且留余量）

这样既不会有漏检，又比全屏快十几倍。

对每个节点输出：
    score_orig   —— 在【原 ROI】内的最高分及位置
    score_pad    —— 在【扩展 ROI】内的最高分及位置
    anchor       —— 由落点推断的锚定方向（top / bottom / unknown）

判定：
    ✅ 原ROI可用    —— 原 ROI 内分数 >= 阈值
    🔧 需+83        —— 扩展 ROI 内分数达标，且落点 y ≈ roi.y + 83
    ❓ 数据不足      —— 扩展范围内也没有达标分数（该 UI 未出现在这批截图里）
"""

import cv2
import numpy as np
import os
import sys
import glob
import json
import time
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from maa_roi_offset import collect

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_BASE = os.path.join(ROOT, 'MaaNTE/assets/resource/base/image')
PIPE_DIR = os.path.join(ROOT, 'MaaNTE/assets/resource/base/pipeline')
SHOTS_DIR = os.path.join(ROOT, 'data/mac_shots')

PAD = 100          # 垂直扩展余量（覆盖 +83）
SCORE_HIT = 0.80   # 判定"确实命中"的分数
SCORE_MAYBE = 0.65 # 判定"可能命中"的分数


def search_in(img, tp, x, y, w, h):
    """在指定矩形内搜索模板，返回 (score, x, y) 或 None。"""
    IH, IW = img.shape[:2]
    th, tw = tp.shape[:2]
    x0 = max(0, x); y0 = max(0, y)
    x1 = min(IW, x + w); y1 = min(IH, y + h)
    if x1 - x0 <= tw or y1 - y0 <= th:
        return None
    reg = img[y0:y1, x0:x1]
    res = cv2.matchTemplate(reg, tp, cv2.TM_CCOEFF_NORMED)
    _, mx, _, loc = cv2.minMaxLoc(res)
    return float(mx), x0 + loc[0], y0 + loc[1]


def main():
    shots = []
    for p in sorted(glob.glob(os.path.join(SHOTS_DIR, '*.png'))):
        im = cv2.imread(p)
        if im is not None:
            shots.append((os.path.basename(p), im))
    if not shots:
        print('[!] data/mac_shots 为空')
        return 1

    nodes = collect(PIPE_DIR)
    # 按模板归并
    by_t = defaultdict(list)
    for f, name, roi, tpl in nodes:
        if isinstance(tpl, str) and tpl.endswith('.png'):
            by_t[tpl].append((name, [int(v) for v in roi]))

    print(f'截图: {len(shots)} 张   节点: {len(nodes)} 个   涉及模板: {len(by_t)} 个')
    print(f'搜索范围: 原ROI 的 Y 方向各扩 {PAD}px\n')

    t0 = time.time()
    rows = []
    for tpl, refs in sorted(by_t.items()):
        p = os.path.join(IMG_BASE, tpl)
        if not os.path.exists(p):
            rows.append(dict(tpl=tpl, verdict='❌ 模板缺失', best=None, refs=refs))
            continue
        tp = cv2.imread(p)
        if tp is None:
            rows.append(dict(tpl=tpl, verdict='❌ 读取失败', best=None, refs=refs))
            continue
        th, tw = tp.shape[:2]

        # 汇总该模板在所有节点、所有截图上的最佳表现
        per_node = []
        for name, roi in refs:
            x, y, w, h = roi
            best_orig = None
            best_pad = None
            best_shot = ''
            for sn, img in shots:
                IH, IW = img.shape[:2]
                if th >= IH or tw >= IW:
                    continue
                r1 = search_in(img, tp, x, y, w, h)
                if r1 and (best_orig is None or r1[0] > best_orig[0]):
                    best_orig = r1; best_shot = sn
                r2 = search_in(img, tp, x, y - PAD, w, h + 2 * PAD)
                if r2 and (best_pad is None or r2[0] > best_pad[0]):
                    best_pad = r2
            per_node.append(dict(name=name, roi=roi, orig=best_orig, pad=best_pad,
                                 shot=best_shot))

        # 判定
        ok_orig = [n for n in per_node if n['orig'] and n['orig'][0] >= SCORE_HIT]
        ok_pad = [n for n in per_node if n['pad'] and n['pad'][0] >= SCORE_HIT]
        maybe = [n for n in per_node if n['pad'] and n['pad'][0] >= SCORE_MAYBE]

        if ok_orig:
            verdict = '✅ 直接可用'
        elif ok_pad:
            # 看落点是否 y ≈ roi.y + 83
            shifted = 0
            for n in ok_pad:
                dy = n['pad'][2] - n['roi'][1]
                if 70 <= dy <= 96:
                    shifted += 1
            verdict = '🔧 需+83' if shifted >= len(ok_pad) / 2 else '⚠️ 位置异常'
        elif maybe:
            verdict = '🟡 分数偏低'
        else:
            verdict = '❓ 数据不足'

        rows.append(dict(tpl=tpl, verdict=verdict, refs=refs, nodes=per_node,
                         best=max((n['pad'][0] for n in per_node if n['pad']), default=0)))

    el = time.time() - t0

    order = {'✅ 直接可用': 0, '🔧 需+83': 1, '⚠️ 位置异常': 2, '🟡 分数偏低': 3,
             '❓ 数据不足': 4, '❌ 模板缺失': 5, '❌ 读取失败': 6}
    rows.sort(key=lambda r: (order.get(r['verdict'], 9), -r['best']))

    stat = defaultdict(int)
    for r in rows:
        stat[r['verdict']] += 1

    print(f'耗时 {el:.2f}s\n')
    print('=' * 96)
    print('判定汇总')
    print('=' * 96)
    for k in sorted(stat, key=lambda x: order.get(x, 9)):
        print(f'  {k:14s} {stat[k]:3d} 个模板')

    print()
    print('=' * 96)
    print('明细')
    print('=' * 96)
    for r in rows:
        print(f"{r['verdict']:14s} {r['tpl']:52s} 最高分 {r['best']:.3f}")
        for n in r.get('nodes', []):
            if not n['pad']:
                continue
            o = f"{n['orig'][0]:.3f}@({n['orig'][1]},{n['orig'][2]})" if n['orig'] else '—'
            pp = f"{n['pad'][0]:.3f}@({n['pad'][1]},{n['pad'][2]})"
            dy = n['pad'][2] - n['roi'][1]
            print(f"      {n['name'][:34]:36s} roi{str(n['roi']):22s} 原ROI {o:22s} 扩ROI {pp:22s} Δy={dy:+d}")

    out = os.path.join(ROOT, 'build/maa_node_audit.json')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump([{k: v for k, v in r.items() if k != 'nodes'} for r in rows],
                  f, ensure_ascii=False, indent=2)
    print(f'\n已写入: {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
