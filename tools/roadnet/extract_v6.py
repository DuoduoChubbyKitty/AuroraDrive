#!/usr/bin/env python3
"""
路网提取 v6 —— 「深灰带」检测（对应 v5 的根本性修正）

═══════════════════════════════════════════════════════════════
★ v5 为什么错（本条目不写就不许改代码）
═══════════════════════════════════════════════════════════════
v5 假设「路 = 比两侧都亮的细线」（对称脊）。
但在原生分辨率下放大用户标注点（docs/roadnet/审查/放大_密集笔画.png）：
    用户笔画 100% 贴着【比周围略亮的深灰色带状物】，
    其原生亮度 p50 = 33，即 "30-35" 那一档。
    而值 83 的亮白线是【公路主干】，不是用户要找的村道/小路。

v5 及之前所有版本都在找「最亮的东西」，因此：
    · 值 83 主干 → 抽出来 95 km，召回仅 5.4%（用户根本没画这些）
    · 用户真正画的 33 深灰带 → 被当作"田地"排除

═══════════════════════════════════════════════════════════════
★ v6 判据
═══════════════════════════════════════════════════════════════
「带状」= 该像素属于一条【窄的长条】，而不是【大块色斑】。
    判据 A：亮度落在深灰带（默认 28..40，对应原生 33±）
    判据 B：形态学「开运算后消失」→ 窄条；开运算后仍在 → 大色块（去掉）
    判据 C：连通分量足够长（>N px），短碎块丢弃

验收：tools/roadnet/eval_net.py，同时看【召回】和【精确】。
      v5 的召回 64.5% 是拿 6.9% 的精确换的 —— 本版必须两个都上去。

用法：
    python3 extract_v6.py                # 用默认参数
    python3 extract_v6.py --sweep        # 参数扫描（不建图，只看指标）
环境变量（便于调参，不必改文件）：
    AURORA_V6_LO / AURORA_V6_HI   深灰带范围（原生值）
    AURORA_V6_THIN_K              细线开运算核（越大越只留细线）
    AURORA_V6_MINLEN              连通分量最短长度(px, 6528空间)
"""
import os, sys, json, time, gc
import numpy as np
import cv2
from skimage.morphology import skeletonize

MAP   = 'models/bigworldmap-13056.jpg'
S     = 6528
PX_M  = S / 13056 * 0.61 * 13056 / S * 2   # = 1.22 m/px（6528空间）
PX_M  = 1.22
LO    = int(os.environ.get('AURORA_V6_LO', 27))
HI    = int(os.environ.get('AURORA_V6_HI', 39))
THIN  = int(os.environ.get('AURORA_V6_THIN_K', 7))
MINLEN= int(os.environ.get('AURORA_V6_MINLEN', 200))
SMOOTH_K   = int(os.environ.get('AURORA_V6_SMOOTH_K', 5))
SMOOTH_TOL = int(os.environ.get('AURORA_V6_SMOOTH_TOL', 4))
OUT   = 'tools/roadnet/road_graph_v6.json'
SKOUT = '/tmp/sk_v6.npy'
t0 = time.time()
def log(m): print(m, flush=True)


def load_base():
    return cv2.resize(cv2.imread(MAP, cv2.IMREAD_GRAYSCALE), (S, S),
                      interpolation=cv2.INTER_AREA)


def load_hint():
    hs = np.load('/tmp/hint_small.npy')
    return cv2.resize(hs * 255, (S, S), interpolation=cv2.INTER_NEAREST) > 127


def metrics(mask, hint, name):
    """同时报召回与精确（精确 = 候选有多少落在笔画附近）。"""
    m = mask > 0
    nm = int(m.sum())
    if nm == 0:
        log(f'  {name:28s} 空'); return None
    out = {'px': nm}
    for k in (5, 10):
        ker = np.ones((2*k+1, 2*k+1), np.uint8)
        d = cv2.dilate(m.astype(np.uint8), ker) > 0
        out[f'rec{k}'] = float(d[hint].mean() * 100)
        del d
        d = cv2.dilate(hint.astype(np.uint8), ker) > 0
        out[f'pre{k}'] = float(d[m].mean() * 100)
        del d
    r, p = out['rec10'], out['pre10']
    out['f1'] = 2*r*p/(r+p) if r+p > 0 else 0.0
    log(f'  {name:28s} {nm:7d}px {nm*PX_M/1000:6.1f}km | '
        f'召回@5 {out["rec5"]:5.1f}% @10 {out["rec10"]:5.1f}% | '
        f'精确@5 {out["pre5"]:5.1f}% @10 {out["pre10"]:5.1f}% | F1 {out["f1"]:5.1f}')
    return out


def detect(g, lo=LO, hi=HI, thin=THIN, minlen=MINLEN,
           smooth_k=SMOOTH_K, smooth_tol=SMOOTH_TOL):
    """v6 主检测：深灰带 ∧ 平滑 ∧ 窄条 ∧ 足够长。返回 6528² uint8 掩码。"""
    band = ((g >= lo) & (g < hi)).astype(np.uint8)
    # 平滑判据：地形有细密斜纹噪声，路带是平滑的
    sm = smooth_mask(g, smooth_k, smooth_tol)
    line = cv2.bitwise_and(band, sm)
    del band, sm; gc.collect()
    # B: 开运算能留下的 = 大色块 → 去掉；只保留窄条
    el = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (thin, thin))
    blob = cv2.morphologyEx(line, cv2.MORPH_OPEN, el)
    line = cv2.bitwise_and(line, cv2.bitwise_not(blob))
    del blob; gc.collect()
    # C: 连通分量长度过滤
    line = filter_len(line, minlen)
    return line


def filter_len(mask, minlen):
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    keep = np.where(stats[:, cv2.CC_STAT_AREA] >= minlen)[0]
    keep = keep[keep > 0]
    out = np.isin(lab, keep).astype(np.uint8)
    del lab
    return out


def smooth_mask(g, k, tol):
    """平滑度判据：路带平滑（局部方差小），地形有细密斜纹噪声。
       用 k×k 均值滤波后，与原始值差得多的像素 = 噪声纹理，剔除。"""
    m = cv2.blur(g.astype(np.float32), (k, k))
    return (np.abs(g.astype(np.float32) - m) <= tol).astype(np.uint8)


def sweep(g, hint):
    log('═══ 参数扫描（只看指标，不建图）═══')
    best = None
    for lo, hi in [(28, 36), (28, 40), (30, 36), (27, 45), (25, 40)]:
        for thin in [5, 7, 9]:
            base = detect(g, lo, hi, thin)
            for minlen in [40, 120]:
                m = filter_len(base, minlen)
                r = metrics(skeletonize(m > 0).astype(np.uint8), hint,
                            f'lo={lo} hi={hi} thin={thin} minlen={minlen}')
                if r and (best is None or r['f1'] > best[1]['f1']):
                    best = (f'lo={lo} hi={hi} thin={thin} minlen={minlen}', r)
                del m
            del base; gc.collect()
    log(f'\n  ★ 最优 F1: {best[0]}  F1={best[1]["f1"]:.1f} '
        f'(召回@10 {best[1]["rec10"]:.1f}% 精确@10 {best[1]["pre10"]:.1f}%)')

    log('\n═══ 追加：平滑度判据 ═══')
    for lo, hi, thin in [(28, 40, 7), (28, 36, 7), (27, 45, 7)]:
        for k, tol in [(3, 3), (5, 4), (5, 6), (7, 6)]:
            band = ((g >= lo) & (g < hi)).astype(np.uint8)
            sm = smooth_mask(g, k, tol)
            m = cv2.bitwise_and(band, sm)
            el = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (thin, thin))
            blob = cv2.morphologyEx(m, cv2.MORPH_OPEN, el)
            m = cv2.bitwise_and(m, cv2.bitwise_not(blob))
            m = filter_len(m, 40)
            r = metrics(skeletonize(m > 0).astype(np.uint8), hint,
                        f'band{lo}-{hi} smooth k={k} tol={tol}')
            if r and (best is None or r['f1'] > best[1]['f1']):
                best = (f'band{lo}-{hi} smooth k={k} tol={tol}', r)
            del m, band, sm, blob; gc.collect()
    log(f'\n  ★★ 全局最优 F1: {best[0]}  F1={best[1]["f1"]:.1f} '
        f'(召回@10 {best[1]["rec10"]:.1f}% 精确@10 {best[1]["pre10"]:.1f}%)')
    return best


if __name__ == '__main__':
    log(f'═══ v6 深灰带检测  底图 {MAP} ═══')
    g = load_base()
    hint = load_hint()
    log(f'  {g.shape}  1px={PX_M} m   笔画 {int(hint.sum())} px')

    if '--sweep' in sys.argv:
        sweep(g, hint); sys.exit(0)

    log(f'═══ 检测 lo={LO} hi={HI} thin={THIN} minlen={MINLEN} ═══')
    line = detect(g)
    log(f'  线状前景 {line.mean()*100:.3f}%')
    sk = skeletonize(line > 0).astype(np.uint8)
    log(f'  骨架 {int(sk.sum())} px = {sk.sum()*PX_M/1000:.1f} km')
    metrics(sk, hint, 'v6 骨架')
    np.save(SKOUT, sk)
    log(f'  已保存 {SKOUT}')

    # 与 v5 对比
    if os.path.exists('/tmp/sk_v5.npy'):
        log('\n── 对照 v5 ──')
        metrics(np.load('/tmp/sk_v5.npy').astype(np.uint8), hint, 'v5 骨架')

    # 可视化
    try:
        show = cv2.cvtColor(np.clip(g.astype(np.float32)*1.6, 0, 255).astype(np.uint8),
                            cv2.COLOR_GRAY2BGR)
        sd = cv2.dilate(sk, np.ones((2, 2), np.uint8)) > 0
        show[sd] = (0, 0, 255)
        hd = cv2.dilate(hint.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        show[hd] = (0, 255, 255)
        cv2.imwrite('docs/roadnet/审查/v6预览.png',
                    cv2.resize(show, (1500, 1500), interpolation=cv2.INTER_AREA))
        log('  预览 docs/roadnet/审查/v6预览.png')
    except Exception as e:
        log(f'  预览失败 {e}')

    log(f'\n  用时 {time.time()-t0:.1f}s')
