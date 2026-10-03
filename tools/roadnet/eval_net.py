#!/usr/bin/env python3
"""
路网候选评估 —— 用「用户笔画」当真值，同时算【召回】和【精确】。

★ 为什么必须算精确率：
  之前 extract_ridge.py 只报「验收(召回)」——笔画有多少落在骨架附近。
  但用户真正骂的是【精确】：骨架里塞满了田埂/亭子/地块圈。
  只报召回 = 自己给自己发奖状。本脚本两个都报。

★ 真值来源（两种，互为校验）：
  /tmp/hint_small.npy   1632²  笔画像素（已预压，内存友好）
  用 INTER_NEAREST 升到 6528 —— 绝不可把 1px 骨架降采样（会消失）。

指标：
  recall@5/@10   笔画像素中，距候选 ≤5/≤10 px 的比例（能不能盖住真路）
  prec@5/@10     候选像素中，距笔画 ≤5/≤10 px 的比例（有没有塞垃圾）
  F1             2PR/(P+R)
"""
import sys, os, time
import numpy as np
import cv2
from skimage.morphology import skeletonize

MAP = 'models/bigworldmap-13056.jpg'
S = 6528
PX_M = 1.22
t0 = time.time()
def log(m): print(m, flush=True)

_g8 = None
def base():
    """管线真实输入：bigworldmap INTER_AREA → 6528"""
    global _g8
    if _g8 is None:
        _g8 = cv2.resize(cv2.imread(MAP, cv2.IMREAD_GRAYSCALE), (S, S),
                         interpolation=cv2.INTER_AREA)
    return _g8

_hint = None
def stroke():
    global _hint
    if _hint is None:
        hs = np.load('/tmp/hint_small.npy')
        _hint = cv2.resize(hs * 255, (S, S), interpolation=cv2.INTER_NEAREST) > 127
    return _hint


def metrics(mask, name, ks=(5, 10)):
    """mask: 6528² 的线状候选（bool/uint8）。同时报召回与精确。"""
    h = stroke()
    m = mask > 0
    ns = int(h.sum()); nm = int(m.sum())
    if nm == 0 or ns == 0:
        log(f'  {name:26s} 空'); return None
    out = {}
    # 召回：把候选膨胀 k 后看笔画被盖住多少
    for k in ks:
        ker = np.ones((2 * k + 1, 2 * k + 1), np.uint8)
        d = cv2.dilate(m.astype(np.uint8), ker) > 0
        out[f'rec{k}'] = float(d[h].mean() * 100)
        del d
    # 精确：把笔画膨胀 k 后看候选落在里面的比例（同一 k，对称）
    for k in ks:
        ker = np.ones((2 * k + 1, 2 * k + 1), np.uint8)
        d = cv2.dilate(h.astype(np.uint8), ker) > 0
        out[f'pre{k}'] = float(d[m].mean() * 100)
        del d
    r, p = out.get('rec10', 0), out.get('pre10', 0)
    out['f1'] = 2 * r * p / (r + p) if (r + p) > 0 else 0.0
    log(f'  {name:26s} {nm:7d}px {nm*PX_M/1000:6.1f}km | '
        f'召回@{ks[0]} {out[f"rec{ks[0]}"]:5.1f}% @{ks[1]} {out[f"rec{ks[1]}"]:5.1f}% | '
        f'精确@{ks[0]} {out[f"pre{ks[0]}"]:5.1f}% @{ks[1]} {out[f"pre{ks[1]}"]:5.1f}% | F1 {out["f1"]:5.1f}')
    return out


def skel(mask):
    return skeletonize(mask > 0).astype(np.uint8)


if __name__ == '__main__':
    g = base()
    log('═══ 候选基准评估（真值=用户笔画）═══')
    log(f'  底图 {g.shape}  笔画像素 {int(stroke().sum())}')

    log('\n── ① 纯亮度阈值（无骨架化）──')
    for lo, hi in [(81, 256), (52, 80), (27, 51), (17, 26), (17, 51), (18, 256)]:
        m = (g >= lo) & (g < hi)
        metrics(m, f'band {lo}-{hi}')

    log('\n── ② 亮度阈值 + 骨架化 ──')
    for lo, hi in [(81, 256), (27, 51), (17, 51)]:
        m = (g >= lo) & (g < hi)
        metrics(skel(m), f'skel {lo}-{hi}')

    log('\n── ③ 当前 v5 ──')
    if os.path.exists('/tmp/sk_v5.npy'):
        v5 = np.load('/tmp/sk_v5.npy').astype(np.uint8)
        metrics(v5, 'v5 对称脊骨架')
        lab = np.load('/tmp/lab_v5.npy')
        areas = np.load('/tmp/areas.npy')
        big = int(np.argmax(areas[1:])) + 1
        metrics((lab == big), f'v5 仅最大分量({big})')
        metrics(((lab > 0) & (lab != big)), 'v5 仅其余碎片')

    log(f'\n  用时 {time.time()-t0:.1f}s')
