#!/usr/bin/env python3
"""
路网提取 v7 —— 原生 13056 分辨率 + 深灰带 + 细线过滤

★ 为什么要到原生分辨率
  v6 在 6528（2 倍降采样）上做，细路（原生宽约 2-3px）被 INTER_AREA
  平均掉一半对比度，实测漏掉用户笔画 21.8%。
  改在原生 13056 上检测，同样判据召回@10 从 78% → 97.9%。
  ⚠️ 代价：原生 13056² uint8 = 170MB/张，本机 16GB（可用常<2GB），
     必须分块（ROWS 行 + 上下 halo）处理，逐块 max-pool 回 6528。

★ 判据（与 v6 同源，只是分辨率提高）
  A 深灰带：27 <= 原生值 < 39
  B 平滑：|c - blur(c,5)| <= 4   （地形有细密斜纹噪声）
  C 细线：形态学开运算(k) 后消失 → 细线；开运算后仍在 → 大色块，剔除
  D 长度：连通分量 >= MINLEN px（在 6528 空间）

用法：python3 extract_v7.py [--sweep]
环境变量：AURORA_V7_*
"""
import os, sys, gc, time
import numpy as np
import cv2
from skimage.morphology import skeletonize

N   = 13056
S   = 6528
PX_M = 1.22
LO  = int(os.environ.get('AURORA_V7_LO', 27))
HI  = int(os.environ.get('AURORA_V7_HI', 39))
TOL = int(os.environ.get('AURORA_V7_TOL', 4))
THIN= int(os.environ.get('AURORA_V7_THIN_K', 7))
MINLEN = int(os.environ.get('AURORA_V7_MINLEN', 200))
ROWS= 1024
HALO= 16
t0 = time.time()
def log(m): print(m, flush=True)


def native_line_mask(lo=LO, hi=HI, tol=TOL, thin=THIN, rows=ROWS, halo=HALO):
    """分块在原生 13056 上算「深灰带 ∧ 平滑 ∧ 细线」，逐块 max-pool 回 6528。
    ⚠️ 开运算核大于 halo 会在块边界产生假阳性/假阴性，halo 必须 >= thin。"""
    src = cv2.imread('models/bigworldmap-13056.jpg', cv2.IMREAD_GRAYSCALE)
    el = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (thin, thin))
    out = np.zeros((S, S), np.uint8)
    for y0 in range(0, N, rows):
        y1 = min(N, y0 + rows)
        a = max(0, y0 - halo); b = min(N, y1 + halo)
        c = src[a:b].astype(np.float32)
        band = ((c >= lo) & (c < hi)).astype(np.uint8)
        blur = cv2.blur(c, (5, 5))
        sm = (np.abs(c - blur) <= tol).astype(np.uint8)
        line = cv2.bitwise_and(band, sm)
        del band, sm, blur
        blob = cv2.morphologyEx(line, cv2.MORPH_OPEN, el)
        line = cv2.bitwise_and(line, cv2.bitwise_not(blob))
        del blob, c
        # 裁掉 halo，还原到本块
        line = line[y0 - a: y0 - a + (y1 - y0)]
        # max-pool 2x2 → 6528
        h = y1 - y0
        q = line.reshape(h // 2, 2, S, 2).max(axis=(1, 3))
        out[y0 // 2: y1 // 2] = q
        del line, q; gc.collect()
    del src; gc.collect()
    return out


def filter_len(mask, minlen):
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    keep = np.where(stats[:, cv2.CC_STAT_AREA] >= minlen)[0]
    keep = keep[keep > 0]
    out = np.isin(lab, keep).astype(np.uint8)
    del lab
    return out


def load_hint():
    hs = np.load('/tmp/hint_small.npy')
    return cv2.resize(hs * 255, (S, S), interpolation=cv2.INTER_NEAREST) > 127


def metrics(mask, hint, name):
    m = mask > 0
    nm = int(m.sum())
    if nm == 0:
        log(f'  {name:32s} 空'); return None
    r = {}
    for k in (5, 10):
        ker = np.ones((2*k+1, 2*k+1), np.uint8)
        d = cv2.dilate(m.astype(np.uint8), ker) > 0; r[f'rec{k}'] = 100*d[hint].mean(); del d
        d = cv2.dilate(hint.astype(np.uint8), ker) > 0; r[f'pre{k}'] = 100*d[m].mean(); del d
    f1 = 2*r['rec10']*r['pre10']/(r['rec10']+r['pre10'])
    r['f1'] = f1
    log(f'  {name:32s} {nm:7d}px {nm*PX_M/1000:6.1f}km | '
        f'召回@5 {r["rec5"]:5.1f}% @10 {r["rec10"]:5.1f}% | '
        f'精确@5 {r["pre5"]:5.1f}% @10 {r["pre10"]:5.1f}% | F1 {f1:5.1f}')
    return r


if __name__ == '__main__':
    log(f'═══ v7 原生分辨率检测  {N}x{N} ═══')
    hint = load_hint()
    log(f'  笔画 {int(hint.sum())} px')

    if '--sweep' in sys.argv:
        for lo, hi, tol in [(27, 39, 4), (28, 36, 4), (28, 38, 4), (27, 40, 4), (28, 36, 5)]:
            for thin in [5, 7, 9]:
                lm = native_line_mask(lo, hi, tol, thin)
                lm = filter_len(lm, MINLEN)
                sk = skeletonize(lm > 0).astype(np.uint8)
                metrics(sk, hint, f'lo={lo} hi={hi} tol={tol} thin={thin}')
                del lm, sk; gc.collect()
        log(f'\n  用时 {time.time()-t0:.1f}s')
        sys.exit(0)

    log(f'═══ 检测 lo={LO} hi={HI} tol={TOL} thin={THIN} minlen={MINLEN} ═══')
    lm = native_line_mask()
    log(f'  maxpool 后前景 {lm.mean()*100:.3f}%')
    lm = filter_len(lm, MINLEN)
    log(f'  长度过滤后 {lm.mean()*100:.3f}%')
    sk = skeletonize(lm > 0).astype(np.uint8)
    log(f'  骨架 {int(sk.sum())} px = {sk.sum()*PX_M/1000:.1f} km')
    metrics(sk, hint, 'v7 骨架')
    np.save('/tmp/sk_v7.npy', sk)
    log('  已保存 /tmp/sk_v7.npy')

    for tag, p in [('v6', '/tmp/sk_v6.npy'), ('v5', '/tmp/sk_v5.npy')]:
        if os.path.exists(p):
            metrics(np.load(p).astype(np.uint8), hint, f'{tag} 骨架')

    g = cv2.resize(cv2.imread('models/bigworldmap-13056.jpg', cv2.IMREAD_GRAYSCALE),
                   (S, S), interpolation=cv2.INTER_AREA)
    show = cv2.cvtColor(np.clip(g.astype(np.float32)*0.65+35, 0, 255).astype(np.uint8),
                        cv2.COLOR_GRAY2BGR)
    show[cv2.dilate(sk, np.ones((3, 3), np.uint8)) > 0] = (0, 210, 60)
    show[cv2.dilate(hint.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0] = (0, 255, 255)
    cv2.imwrite('docs/roadnet/审查/v7预览.png',
                cv2.resize(show, (1600, 1600), interpolation=cv2.INTER_AREA))
    log('  预览 docs/roadnet/审查/v7预览.png')
    log(f'\n  用时 {time.time()-t0:.1f}s')
