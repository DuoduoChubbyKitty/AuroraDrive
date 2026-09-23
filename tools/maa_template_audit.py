#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MaaNTE 模板在 macOS 上的可用性全量核查

对 data/mac_shots/ 里的每张 1280x803 画面，逐个 pipeline 节点检查：
  1. 模板图在画面上能否匹配到（分数）
  2. 匹配位置是否落在【原 ROI】内（MaaNTE 基准 1280x720 的写法）
  3. 匹配位置是否落在【+83 扩展 ROI】内（macOS 1280x803 的实际空间）

输出一张清单，判定每张模板属于：
  ✅ 直接可用   —— 原 ROI 就能框住
  🔧 需偏移     —— 只有 +83 后才框住（底部锚定）
  ❓ 未出现     —— 这批截图里没出现，无法判定
  ❌ 对不上     —— 出现过但分数低，可能真的不兼容
"""

import cv2
import numpy as np
import os
import sys
import json
import glob
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from maa_roi_offset import collect

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_BASE = os.path.join(ROOT, 'MaaNTE/assets/resource/base/image')
PIPE_DIR = os.path.join(ROOT, 'MaaNTE/assets/resource/base/pipeline')
SHOTS_DIR = os.path.join(ROOT, 'data/mac_shots')

SCORE_OK = 0.75      # 判为"确实存在"的分数下限
SCORE_MAYBE = 0.60   # 待查区间


def load_shots():
    out = []
    for p in sorted(glob.glob(os.path.join(SHOTS_DIR, '*.png'))):
        im = cv2.imread(p)
        if im is not None:
            out.append((os.path.basename(p), im))
    return out


def main():
    shots = load_shots()
    if not shots:
        print(f'[!] {SHOTS_DIR} 里没有画面，先跑裁剪脚本')
        return 1
    print(f'画面数: {len(shots)}  尺寸示例: {shots[0][1].shape[1]}x{shots[0][1].shape[0]}\n')

    nodes = collect(PIPE_DIR)
    print(f'pipeline 节点(带 roi): {len(nodes)}\n')

    # 按模板路径归并节点
    by_tmpl = defaultdict(list)
    for f, name, roi, tpl in nodes:
        if isinstance(tpl, str) and tpl.endswith('.png'):
            by_tmpl[tpl].append((name, [int(v) for v in roi], f))

    print(f'涉及的模板文件: {len(by_tmpl)}\n')

    results = []
    for tpl, refs in sorted(by_tmpl.items()):
        p = os.path.join(IMG_BASE, tpl)
        if not os.path.exists(p):
            results.append(dict(tpl=tpl, verdict='❌ 模板文件缺失', score=0,
                                refs=refs, detail=''))
            continue
        tp = cv2.imread(p)
        if tp is None:
            results.append(dict(tpl=tpl, verdict='❌ 模板读取失败', score=0,
                                refs=refs, detail=''))
            continue
        th, tw = tp.shape[:2]

        best = None  # (score, shot, x, y)
        for sname, img in shots:
            IH, IW = img.shape[:2]
            if th >= IH or tw >= IW:
                continue
            res = cv2.matchTemplate(img, tp, cv2.TM_CCOEFF_NORMED)
            _, mx, _, loc = cv2.minMaxLoc(res)
            if best is None or mx > best[0]:
                best = (mx, sname, loc[0], loc[1])

        if best is None:
            results.append(dict(tpl=tpl, verdict='❓ 未出现', score=0, refs=refs,
                                detail='模板尺寸超过画面'))
            continue

        score, sname, mx, my = best
        if score < SCORE_MAYBE:
            results.append(dict(tpl=tpl, verdict='❓ 未出现', score=score, refs=refs,
                                detail=f'最高分 {score:.3f} @{sname}'))
            continue

        # 对每个引用它的节点，判断原 ROI / +83 ROI 谁框得住
        verdicts = []
        for name, roi, f in refs:
            x, y, w, h = roi
            in_orig = (x <= mx <= x + w - tw) and (y <= my <= y + h - th)
            in_shift = (x <= mx <= x + w - tw) and (y + 83 <= my <= y + 83 + h - th)
            verdicts.append((name, roi, in_orig, in_shift))

        n_orig = sum(1 for v in verdicts if v[2])
        n_shift = sum(1 for v in verdicts if v[3])
        if n_orig:
            verdict = '✅ 直接可用'
        elif n_shift:
            verdict = '🔧 需偏移'
        else:
            verdict = '⚠️ 位置不符'

        results.append(dict(tpl=tpl, verdict=verdict, score=score, refs=refs,
                            detail=f'{score:.3f} @{sname} ({mx},{my})',
                            verdicts=verdicts))

    # ---------------- 输出清单 ----------------
    order = {'✅ 直接可用': 0, '🔧 需偏移': 1, '⚠️ 位置不符': 2, '❌ 模板文件缺失': 3,
             '❌ 模板读取失败': 4, '❓ 未出现': 5}
    results.sort(key=lambda r: (order.get(r['verdict'], 9), -r['score']))

    stat = defaultdict(int)
    for r in results:
        stat[r['verdict']] += 1

    print('=' * 100)
    print('判定汇总')
    print('=' * 100)
    for k in sorted(stat, key=lambda x: order.get(x, 9)):
        print(f'  {k:16s} {stat[k]:3d} 张')
    print()

    print('=' * 100)
    print('详细清单')
    print('=' * 100)
    for r in results:
        print(f"{r['verdict']:14s} {r['tpl']:58s} {r['detail']}")
        for n, roi, io_, is_ in r.get('verdicts', []):
            mark = '原ROI✅' if io_ else ('+83✅' if is_ else '都不✅')
            print(f"                  └ {n[:38]:40s} roi={str(roi):24s} {mark}")

    # 落盘
    out = os.path.join(ROOT, 'build/maa_template_audit.json')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump([{k: v for k, v in r.items() if k != 'verdicts'} for r in results],
                  f, ensure_ascii=False, indent=2)
    print(f'\n已写入: {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
