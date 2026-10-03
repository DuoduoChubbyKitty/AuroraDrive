#!/usr/bin/env python3
"""
路网提取 v9 —— 全亮度分层合并（最终汇总版）

★ 设计目标
  用户 2026-10-03 反馈：「找到的图没有一张是正确的，只能用浏览器补全了」。
  本版不再赌单一阈值，而是把【地图上所有可能承载道路的亮度层】分别提取，
  逐层量化「召回 / 精确 / 连通性」，再由上层决定保留哪几层，
  最后统一输出【一张纯白线黑底图】供人工在浏览器里补全。

★ 三层（全部实测过，各有取舍）
  L1 亮主干  >80           —— 公路/主干道；路宽粗、连通性好
  L2 灰路    28..39        —— 村道/小路（用户标注的正是这层）；★ 路是粗带不是细线
  L3 中灰    40..51        —— 过渡带，含部分道路边缘与地形边界（噪声大，默认关）
  L4 暗路    17..27        —— ★ 用户笔画 55.9% 落在此层，但全图占 8.19% 噪声极多

★ 与 v6 的关系
  v6 用「细线过滤（开运算后减掉）」把所有者都删了。实测证明路是粗带：
  去掉细线过滤后 灰路 召回@10 77.9% → 93.7%，F1 75.2 → 83.2。
  v9 沿用这个修正，并把分层结果并起来。

用法：
    python3 extract_v9.py             # 默认 L1+L2 合并
    python3 extract_v9.py --layers L1,L2,L4
    python3 extract_v9.py --report    # 只报每层指标，不合并
环境变量：AURORA_V9_*
"""
import os, sys, gc, time
import numpy as np
import cv2
from skimage.morphology import skeletonize

MAP = 'models/bigworldmap-13056.jpg'
S   = 6528
PX_M = 1.22
t0 = time.time()
def log(m): print(m, flush=True)

# 每层参数：name -> (lo, hi, minlen, close, tol, use_smooth)
LAYERS = {
    'L1': dict(name='亮主干 >80',      lo=81, hi=256, minlen=80,  close=0, tol=0, smooth=False),
    'L2': dict(name='灰路 28-39',      lo=28, hi=39,  minlen=200, close=3, tol=4, smooth=True),
    'L3': dict(name='中灰 40-51',      lo=40, hi=52,  minlen=200, close=3, tol=4, smooth=True),
    'L4': dict(name='暗路 17-27',      lo=17, hi=27,  minlen=200, close=3, tol=5, smooth=True),
}
DEFAULT_LAYERS = os.environ.get('AURORA_V9_LAYERS', 'L1,L2')


def load_hint():
    hs = np.load('/tmp/hint_small.npy')
    return cv2.resize(hs * 255, (S, S), interpolation=cv2.INTER_NEAREST) > 127


def metrics(mask, hint, name):
    m = mask > 0
    nm = int(m.sum())
    if nm == 0:
        log(f'  {name:26s} 空'); return None
    r = {}
    for k in (5, 10):
        ker = np.ones((2*k+1, 2*k+1), np.uint8)
        d = cv2.dilate(m.astype(np.uint8), ker) > 0; r[f'rec{k}'] = 100*d[hint].mean(); del d
        d = cv2.dilate(hint.astype(np.uint8), ker) > 0; r[f'pre{k}'] = 100*d[m].mean(); del d
    r['f1'] = 2*r['rec10']*r['pre10']/(r['rec10']+r['pre10']) if (r['rec10']+r['pre10']) else 0
    r['px'] = nm
    r['comp'] = cv2.connectedComponentsWithStats(m.astype(np.uint8), connectivity=8)[0]-1
    log(f'  {name:26s} {nm:7d}px {nm*PX_M/1000:6.1f}km {r["comp"]:5d}段 | '
        f'召回@5 {r["rec5"]:5.1f}% @10 {r["rec10"]:5.1f}% | '
        f'精确@5 {r["pre5"]:5.1f}% @10 {r["pre10"]:5.1f}% | F1 {r["f1"]:5.1f}')
    return r


def layer_mask(g, cfg):
    """单层提取。★ 不做细线过滤——路是粗带。"""
    m = ((g >= cfg['lo']) & (g < cfg['hi'])).astype(np.uint8)
    if cfg['smooth']:
        b = cv2.blur(g.astype(np.float32), (5, 5))
        m = cv2.bitwise_and(m, (np.abs(g.astype(np.float32) - b) <= cfg['tol']).astype(np.uint8))
        del b
    if cfg['close']:
        m = cv2.morphologyEx(m, cv2.MORPH_CLOSE,
                             cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                                       (cfg['close'], cfg['close'])))
    n, lab, st, _ = cv2.connectedComponentsWithStats(m, connectivity=8)
    keep = np.where(st[:, cv2.CC_STAT_AREA] >= cfg['minlen'])[0]
    keep = keep[keep > 0]
    out = np.isin(lab, keep).astype(np.uint8)
    del lab, st; gc.collect()
    return out


def connectivity(sk, ref):
    """sk 有多少段接到 ref（参考网）。返回 (段数, 接主干段数, 孤立段数, 孤立像素)"""
    n = cv2.connectedComponentsWithStats(sk, connectivity=8)[0] - 1
    if ref is None or not ref.sum():
        return n, 0, 0, 0
    bd = cv2.dilate(ref, np.ones((9, 9), np.uint8)) > 0
    n, lab, st, _ = cv2.connectedComponentsWithStats(sk, connectivity=8)
    touch = orph = opx = 0
    for i in range(1, n):
        m = (lab == i)
        if (m & bd).any(): touch += 1
        else: orph += 1; opx += st[i, cv2.CC_STAT_AREA]
    return n-1, touch, orph, opx


if __name__ == '__main__':
    want = None
    for a in sys.argv[1:]:
        if a.startswith('--layers'):
            want = a.split('=')[1] if '=' in a else None
    if want is None and '--layers' in sys.argv:
        i = sys.argv.index('--layers')
        if i + 1 < len(sys.argv): want = sys.argv[i+1]
    layers = (want or DEFAULT_LAYERS).split(',')

    log(f'═══ v9 分层合并  底图 {MAP} ═══')
    g = cv2.resize(cv2.imread(MAP, cv2.IMREAD_GRAYSCALE), (S, S),
                   interpolation=cv2.INTER_AREA)
    hint = load_hint()
    log(f'  {g.shape}  1px={PX_M} m  笔画 {int(hint.sum())} px')

    sk = {}
    log('\n── 各层单独指标（真值=用户笔画）──')
    for key in ['L1', 'L2', 'L3', 'L4']:
        cfg = LAYERS[key]
        m = layer_mask(g, cfg)
        s = skeletonize(m > 0).astype(np.uint8); del m; gc.collect()
        r = metrics(s, hint, f'{key} {cfg["name"]}')
        sk[key] = s
        np.save(f'/tmp/sk_v9_{key}.npy', s)
        if r:
            n, touch, orph, opx = connectivity(s, sk.get('L1') if key != 'L1' else None)
            if opx:
                log(f'       └ 孤立于主干: {orph}/{n} 段 {opx*PX_M/1000:.1f}km ({opx/r["px"]*100:.1f}%)')
        del s; gc.collect()

    if '--report' in sys.argv:
        log(f'\n  用时 {time.time()-t0:.1f}s'); sys.exit(0)

    log(f'\n── 合并 {layers} ──')
    final = np.zeros((S, S), np.uint8)
    for k in layers:
        if k in sk: final = np.maximum(final, sk[k])
    metrics(final, hint, '★ v9 最终')
    np.save('/tmp/sk_v9_final.npy', final)

    outdir = 'docs/roadnet'
    os.makedirs(outdir, exist_ok=True)
    show = np.zeros((S, S, 3), np.uint8)
    show[cv2.dilate(final, np.ones((3, 3), np.uint8)) > 0] = (255, 255, 255)
    cv2.imwrite(f'{outdir}/v9_白线_黑底.png',
                cv2.resize(show, (2048, 2048), interpolation=cv2.INTER_AREA))
    show2 = cv2.cvtColor(np.clip(g.astype(np.float32)*0.85, 0, 255).astype(np.uint8),
                         cv2.COLOR_GRAY2BGR)
    show2[cv2.dilate(final, np.ones((3, 3), np.uint8)) > 0] = (255, 255, 255)
    cv2.imwrite(f'{outdir}/v9_白线_带底图.png',
                cv2.resize(show2, (2048, 2048), interpolation=cv2.INTER_AREA))
    log(f'  ✓ {outdir}/v9_白线_黑底.png')
    log(f'\n  用时 {time.time()-t0:.1f}s')
