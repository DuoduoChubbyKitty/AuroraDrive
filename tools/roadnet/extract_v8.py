#!/usr/bin/env python3
"""
路网提取 v8 —— 灰路（28-39）去细线过滤 + 亮主干（>80）合并

★ v8 要解决的问题（v6 的致命错误）
  v6 假设「路是细线」，用形态学开运算把"开运算后仍在的"当大色块删掉。
  但放大到原生分辨率看（docs/roadnet/审查/高清_路_放大.png）：
      **地图上的路是【粗带】（原生约 10-14px 宽），不是细线。**
  开运算把整条路删掉 → v6 只有 23.9km、召回 77.9%。
  去掉细线过滤后同一参数：召回@10 77.9% → 93.7%，F1 75.2 → 83.2。

★ v8 判据
  A 灰路：  28 <= 原生值 < 39   且  |c - blur(c,5)| <= 4（地形有斜纹噪声）
  B 亮主干：原生值 > 80
  C 长度过滤：连通分量 >= MINLEN px（6528 空间）
  D 闭合桥接：形态学 close(3) 补断点
  输出 = 灰路骨架 ∪ 亮主干骨架

用法：python3 extract_v8.py [--no-bright]
"""
import sys, os, gc, time
import numpy as np
import cv2
from skimage.morphology import skeletonize

MAP    = 'models/bigworldmap-13056.jpg'
S      = 6528
PX_M   = 1.22
LO     = int(os.environ.get('AURORA_V8_LO', 28))
HI     = int(os.environ.get('AURORA_V8_HI', 39))
TOL    = int(os.environ.get('AURORA_V8_TOL', 4))
MINLEN = int(os.environ.get('AURORA_V8_MINLEN', 200))
CLOSE  = int(os.environ.get('AURORA_V8_CLOSE', 3))
BRIGHT_TH = int(os.environ.get('AURORA_V8_BRIGHT', 80))
BRIGHT_MIN= int(os.environ.get('AURORA_V8_BRIGHT_MIN', 80))
OUT    = 'tools/roadnet/road_graph_v8.json'
t0 = time.time()
def log(m): print(m, flush=True)


def load_hint():
    hs = np.load('/tmp/hint_small.npy')
    return cv2.resize(hs * 255, (S, S), interpolation=cv2.INTER_NEAREST) > 127


def metrics(mask, hint, name):
    m = mask > 0
    nm = int(m.sum())
    if nm == 0:
        log(f'  {name:30s} 空'); return None
    r = {}
    for k in (5, 10):
        ker = np.ones((2*k+1, 2*k+1), np.uint8)
        d = cv2.dilate(m.astype(np.uint8), ker) > 0; r[f'rec{k}'] = 100*d[hint].mean(); del d
        d = cv2.dilate(hint.astype(np.uint8), ker) > 0; r[f'pre{k}'] = 100*d[m].mean(); del d
    f1 = 2*r['rec10']*r['pre10']/(r['rec10']+r['pre10']) if (r['rec10']+r['pre10']) else 0
    ncomp = cv2.connectedComponentsWithStats(m.astype(np.uint8), connectivity=8)[0]-1
    log(f'  {name:30s} {nm:7d}px {nm*PX_M/1000:6.1f}km {ncomp:5d}段 | '
        f'召回@5 {r["rec5"]:5.1f}% @10 {r["rec10"]:5.1f}% | '
        f'精确@5 {r["pre5"]:5.1f}% @10 {r["pre10"]:5.1f}% | F1 {f1:5.1f}')
    return {**r, 'f1': f1, 'px': nm, 'comp': ncomp}


def gray_mask(g, lo=LO, hi=HI, tol=TOL, minlen=MINLEN, close=CLOSE):
    """灰路：色带 + 平滑（噪声抑制），无细线过滤（★路是粗带）"""
    m = ((g >= lo) & (g < hi)).astype(np.uint8)
    b = cv2.blur(g.astype(np.float32), (5, 5))
    m = cv2.bitwise_and(m, (np.abs(g.astype(np.float32) - b) <= tol).astype(np.uint8))
    del b; gc.collect()
    if close:
        m = cv2.morphologyEx(m, cv2.MORPH_CLOSE,
                             cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (close, close)))
    n, lab, st, _ = cv2.connectedComponentsWithStats(m, connectivity=8)
    keep = np.where(st[:, cv2.CC_STAT_AREA] >= minlen)[0]
    keep = keep[keep > 0]
    out = np.isin(lab, keep).astype(np.uint8)
    del lab, st; gc.collect()
    return out


def bright_mask(g, th=BRIGHT_TH, minlen=BRIGHT_MIN):
    """亮主干 >80（宽路，面积过滤即可）"""
    m = (g > th).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats(m, connectivity=8)
    keep = np.where(st[:, cv2.CC_STAT_AREA] >= minlen)[0]
    keep = keep[keep > 0]
    out = np.isin(lab, keep).astype(np.uint8)
    del lab, st; gc.collect()
    return out


if __name__ == '__main__':
    log(f'═══ v8 灰路(无细线过滤) + 亮主干  底图 {MAP} ═══')
    g = cv2.resize(cv2.imread(MAP, cv2.IMREAD_GRAYSCALE), (S, S),
                   interpolation=cv2.INTER_AREA)
    hint = load_hint()
    log(f'  {g.shape}  1px={PX_M} m  笔画 {int(hint.sum())} px')

    log(f'═══ ① 灰路 lo={LO} hi={HI} tol={TOL} minlen={MINLEN} close={CLOSE} ═══')
    gm = gray_mask(g)
    skG = skeletonize(gm > 0).astype(np.uint8); del gm; gc.collect()
    metrics(skG, hint, '灰路（你标的）')
    np.save('/tmp/sk_v8_gray.npy', skG)

    log(f'═══ ② 亮主干 >{BRIGHT_TH} minlen={BRIGHT_MIN} ═══')
    bm = bright_mask(g)
    skB = skeletonize(bm > 0).astype(np.uint8); del bm; gc.collect()
    metrics(skB, hint, '亮主干（你没画的）')
    np.save('/tmp/sk_v8_bright.npy', skB)

    if '--no-bright' in sys.argv:
        final = skG
        log('═══ ③ 只用灰路 ═══')
    else:
        final = np.maximum(skG, skB)
        log('═══ ③ 合并 ═══')
    metrics(final, hint, '★ v8 最终')
    np.save('/tmp/sk_v8_final.npy', final)

    # 连通性检查：灰路有多少段接到主干
    bd = cv2.dilate(skB, np.ones((9, 9), np.uint8)) > 0
    n, lab, st, _ = cv2.connectedComponentsWithStats(skG, connectivity=8)
    touch = orph = opx = 0
    for i in range(1, n):
        m = (lab == i)
        if (m & bd).any(): touch += 1
        else: orph += 1; opx += st[i, cv2.CC_STAT_AREA]
    log(f'  灰路 {n-1} 段：接主干 {touch} 段，孤立 {orph} 段 '
        f'({opx}px={opx*PX_M/1000:.1f}km, {opx/max(1,skG.sum())*100:.1f}%)')

    show = np.zeros((S, S, 3), np.uint8)
    show[cv2.dilate(final, np.ones((3, 3), np.uint8)) > 0] = (255, 255, 255)
    cv2.imwrite('docs/roadnet/v8_白线_黑底.png',
                cv2.resize(show, (2048, 2048), interpolation=cv2.INTER_AREA))
    show2 = cv2.cvtColor(np.clip(g.astype(np.float32)*0.85, 0, 255).astype(np.uint8),
                         cv2.COLOR_GRAY2BGR)
    show2[cv2.dilate(final, np.ones((3, 3), np.uint8)) > 0] = (255, 255, 255)
    cv2.imwrite('docs/roadnet/v8_白线_带底图.png',
                cv2.resize(show2, (2048, 2048), interpolation=cv2.INTER_AREA))
    log(f'\n  用时 {time.time()-t0:.1f}s')
