#!/usr/bin/env python3
"""OCR 节点 ROI 修正的本地验证（零 OCR 成本）。

原理：文字区域在灰度图上表现为高边缘密度 + 多连通小块。
对每个 OCR 节点，在全样本上比较「原 ROI」与「修正 ROI」的文本似然度。
若修正后显著更高 -> 证明规则有效。

输出 build/ocr_validation.json
"""
import cv2
import json
import numpy as np
import os
import glob

cv2.setNumThreads(8)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_W, IMG_H = 1280, 803
H_RULE, MARGIN = 83, 32

CACHE = os.path.join(ROOT, 'data/_gray_cache')


def text_score(g):
    """文本似然度：边缘密度 + 小块数量"""
    if g.size == 0 or g.shape[0] < 6 or g.shape[1] < 6:
        return 0.0
    lap = cv2.Laplacian(g, cv2.CV_64F)
    edge = float(np.mean(np.abs(lap)))
    # 二值化后数连通块（字符）
    _, bw = cv2.threshold(g, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    n, _, stats, _ = cv2.connectedComponentsWithStats(bw, 8)
    small = sum(1 for i in range(1, n)
                if 4 <= stats[i, cv2.CC_STAT_AREA] <= 400
                and stats[i, cv2.CC_STAT_HEIGHT] <= 40)
    return edge * 0.5 + min(small, 40) * 1.5


def clip(x, y, w, h):
    x = max(0, min(int(x), IMG_W - 1))
    y = max(0, min(int(y), IMG_H - 1))
    w = max(1, min(int(w), IMG_W - x))
    h = max(1, min(int(h), IMG_H - y))
    return x, y, w, h


def main():
    nodes = json.load(open(os.path.join(ROOT, 'build/nodes_inventory.json')))
    ov = json.load(open(os.path.join(ROOT, 'build/maa_override_all.json')))

    gray_files = sorted(glob.glob(os.path.join(CACHE, '*.png')))
    shots = []
    for p in gray_files:
        g = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
        if g is not None:
            shots.append((os.path.basename(p), g))
    print(f'样本 {len(shots)} 张', flush=True)

    targets = [(k, v) for k, v in nodes.items()
               if v.get('type') == 'OCR' and v.get('expected')
               and isinstance(v.get('roi'), list) and len(v['roi']) == 4]
    print(f'可验证 OCR 节点 {len(targets)}', flush=True)

    results = {}
    for i, (name, v) in enumerate(targets):
        ox, oy, ow, oh = [int(t) for t in v['roi']]
        new = ov.get(name, {}).get('recognition', {}).get('param', {}).get('roi')
        if not new:
            continue
        nx, ny, nw, nh = new
        best = {'orig': -1, 'new': -1, 'shot_o': None, 'shot_n': None}
        for key, g in shots:
            cx, cy, cw, ch = clip(ox, oy, ow, oh)
            so = text_score(g[cy:cy + ch, cx:cx + cw])
            if so > best['orig']:
                best['orig'] = so
                best['shot_o'] = key
            cx, cy, cw, ch = clip(nx, ny, nw, nh)
            sn = text_score(g[cy:cy + ch, cx:cx + cw])
            if sn > best['new']:
                best['new'] = sn
                best['shot_n'] = key
        ratio = (best['new'] / best['orig']) if best['orig'] > 1e-6 else float('inf')
        results[name] = {
            'roi_orig': [ox, oy, ow, oh],
            'roi_new': [nx, ny, nw, nh],
            'score_orig': round(best['orig'], 2),
            'score_new': round(best['new'], 2),
            'ratio': (round(ratio, 3) if ratio != float('inf') else None),
            'shot': best['shot_n'],
            'verdict': ('improved' if ratio > 1.15 else
                        'equal' if 0.85 <= ratio <= 1.15 else 'worse'),
        }
        if (i + 1) % 20 == 0:
            print(f'  {i+1}/{len(targets)}', flush=True)

    json.dump(results, open(os.path.join(ROOT, 'build/ocr_validation.json'), 'w'),
              ensure_ascii=False, indent=1)

    v = {}
    for r in results.values():
        v[r['verdict']] = v.get(r['verdict'], 0) + 1
    print('\n=== 结果 ===')
    for k, c in sorted(v.items(), key=lambda x: -x[1]):
        print(f'  {k:10s} {c}')

    imp = [(n, r) for n, r in results.items() if r['verdict'] == 'improved']
    imp.sort(key=lambda x: -(x[1]['ratio'] or 0))
    print(f'\n=== 修正后明显更像文字（Top 20）===')
    for n, r in imp[:20]:
        print(f"  ×{r['ratio']:.2f}  {r['score_orig']:7.1f} -> {r['score_new']:7.1f}  {n[:40]}")

    wor = [(n, r) for n, r in results.items() if r['verdict'] == 'worse']
    if wor:
        print(f'\n=== 修正后反而更差（{len(wor)}）===')
        for n, r in wor[:15]:
            print(f"  ×{r['ratio']:.2f}  {r['score_orig']:7.1f} -> {r['score_new']:7.1f}  {n[:40]}")


if __name__ == '__main__':
    main()
