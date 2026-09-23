#!/usr/bin/env python3
"""决定性测试：用 Maa 的真实匹配逻辑做 A/B 对比。

Maa 的做法是「在 ROI 裁剪区域内做 matchTemplate」。
对每个 TemplateMatch 节点：
  原ROI 内匹配 -> best_orig
  修正ROI 内匹配 -> best_new
同一张截图、同一个模板，只有 ROI 不同 —— 纯粹的 A/B。

输出 build/roi_ab_test.json
"""
import cv2
import json
import numpy as np
import os
import glob

cv2.setNumThreads(8)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, 'MaaNTE/assets/resource/base')
CACHE = os.path.join(ROOT, 'data/_gray_cache')
IMG_W, IMG_H = 1280, 803
HIT = 0.80
MAYBE = 0.70


def match_in_roi(shot, tpl, roi):
    x, y, w, h = [int(v) for v in roi]
    x = max(0, min(x, IMG_W - 1)); y = max(0, min(y, IMG_H - 1))
    w = max(1, min(w, IMG_W - x)); h = max(1, min(h, IMG_H - y))
    crop = shot[y:y + h, x:x + w]
    th, tw = tpl.shape
    if th > crop.shape[0] or tw > crop.shape[1]:
        return -1.0, None
    r = cv2.matchTemplate(crop, tpl, cv2.TM_CCOEFF_NORMED)
    _, mx, _, ml = cv2.minMaxLoc(r)
    return float(mx), (x + int(ml[0]), y + int(ml[1]))


def main():
    nodes = json.load(open(os.path.join(ROOT, 'build/nodes_inventory.json')))
    ov = json.load(open(os.path.join(ROOT, 'build/maa_override_all.json')))

    shots = []
    for p in sorted(glob.glob(os.path.join(CACHE, '*.png'))):
        g = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
        if g is not None:
            shots.append((os.path.basename(p), g))
    print(f'样本 {len(shots)}', flush=True)

    targets = []
    for k, v in nodes.items():
        t = v.get('template')
        roi = v.get('roi')
        if not t or not isinstance(roi, list) or len(roi) != 4:
            continue
        new = ov.get(k, {}).get('recognition', {}).get('param', {}).get('roi')
        if not new:
            continue
        ts = t if isinstance(t, list) else [t]
        targets.append((k, ts, roi, new))
    print(f'可测 TemplateMatch 节点 {len(targets)}', flush=True)

    tpl_cache = {}
    results = {}
    for i, (name, ts, roi, new) in enumerate(targets):
        bo, bn, bo_shot, bn_shot = -2.0, -2.0, None, None
        bo_on_bn = -2.0
        for rel in ts:
            if rel not in tpl_cache:
                im = cv2.imread(os.path.join(BASE, 'image', rel))
                tpl_cache[rel] = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY) if im is not None else None
            tpl = tpl_cache[rel]
            if tpl is None:
                continue
            for key, g in shots:
                so, _ = match_in_roi(g, tpl, roi)
                sn, _ = match_in_roi(g, tpl, new)
                if so > bo:
                    bo, bo_shot = so, key
                if sn > bn:
                    bn, bn_shot = sn, key
                if sn > bo_on_bn and key == bn_shot:
                    bo_on_bn = so
        # 同截图对比：在 best_new 那张上，原ROI 的分数
        if bn_shot:
            for rel in ts:
                tpl = tpl_cache.get(rel)
                if tpl is None:
                    continue
                for key, g in shots:
                    if key != bn_shot:
                        continue
                    so, _ = match_in_roi(g, tpl, roi)
                    bo_on_bn = max(bo_on_bn, so)
        results[name] = {
            'template': ts[0], 'roi_orig': roi, 'roi_new': new,
            'score_orig': round(bo, 4), 'score_new': round(bn, 4),
            'score_orig_on_best_shot': round(bo_on_bn, 4),
            'shot_new': bn_shot, 'shot_orig': bo_shot,
            'hit_orig': bo >= HIT, 'hit_new': bn >= HIT,
            'verdict': ('fixed' if (bn >= HIT and bo < HIT) else
                        'broke' if (bo >= HIT and bn < HIT) else
                        'both_hit' if (bo >= HIT and bn >= HIT) else
                        'both_miss'),
        }
        if (i + 1) % 20 == 0:
            print(f'  {i+1}/{len(targets)}', flush=True)

    json.dump(results, open(os.path.join(ROOT, 'build/roi_ab_test.json'), 'w'),
              ensure_ascii=False, indent=1)

    v = {}
    for r in results.values():
        v[r['verdict']] = v.get(r['verdict'], 0) + 1
    print('\n=== A/B 结果（阈值 0.80）===')
    for k, c in sorted(v.items(), key=lambda x: -x[1]):
        print(f'  {k:12s} {c}')
    n_orig = sum(1 for r in results.values() if r['hit_orig'])
    n_new = sum(1 for r in results.values() if r['hit_new'])
    print(f'\n原ROI 命中 {n_orig}/{len(results)}   修正后命中 {n_new}/{len(results)}')

    fx = [(n, r) for n, r in results.items() if r['verdict'] == 'fixed']
    if fx:
        print(f'\n=== 修正救回来的节点（{len(fx)}）===')
        for n, r in fx:
            print(f"  {r['score_orig']:.3f} -> {r['score_new']:.3f}   {n[:44]}")
    br = [(n, r) for n, r in results.items() if r['verdict'] == 'broke']
    if br:
        print(f'\n=== 修正后变命不中（{len(br)}）★需人工看 ===')
        for n, r in br:
            print(f"  {r['score_orig']:.3f} -> {r['score_new']:.3f}   {n[:44]}")


if __name__ == '__main__':
    main()
