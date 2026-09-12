#!/usr/bin/env python3
"""时序滤波验证 v2 —— 滑动窗众数（无锁存，异常值被邻帧投票淘汰）
   对比多个窗口宽度，找出最优
"""
import os, csv, re, time, sys
from collections import Counter, defaultdict
import numpy as np, coremltools as ct
from PIL import Image

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
IMG = f'{ROOT}/data/speed_crops_v3'
PKG = f'{ROOT}/tools/speed_ocr_rebuild/models/speed_ppocrv6_tiny.mlpackage'
OCR = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/tiny'
CACHE = f'{ROOT}/tools/speed_ocr_rebuild/cache_preds.npz'
H, W = 48, 320

cs = open(f'{OCR}/keys.txt', encoding='utf-8').read().split('\n')
if cs and cs[-1] == '': cs = cs[:-1]

human = {}
with open(f'{ROOT}/data/speed_crops_v3_human.csv', newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        if row['状态'] == 'ok': human[row['文件名']] = int(row['速度'])

def clip_of(fn): return fn.rsplit('_', 1)[0]
def frame_of(fn): return int(re.search(r'_(\d{6})\.jpg$', fn).group(1))

need = defaultdict(list)
for fn in human: need[clip_of(fn)].append(fn)

# ---------- 推理（带缓存，避免重复跑） ----------
def build_preds():
    cm = ct.models.MLModel(PKG, compute_units=ct.ComputeUnit.ALL)
    sp = cm.get_spec()
    iname = sp.description.input[0].name; oname = sp.description.output[0].name
    def to_input(fn):
        im = Image.open(os.path.join(IMG, fn)).convert('RGB')
        w, h = im.size
        nw = max(1, min(int(round(w * H / h)), W))
        im = im.resize((nw, H), Image.LANCZOS)
        canvas = np.zeros((H, W, 3), np.uint8); canvas[:, :nw] = np.asarray(im)
        x = ((canvas.astype(np.float32) / 255.0) - 0.5) / 0.5
        return x.transpose(2, 0, 1)[None].astype(np.float32)
    def decode(lg):
        # 注意：必须要求 >=3 位数字才算有效。
        # 否则单个字符（如 "8"）会被 zfill 成 "008" 当成合法读数，污染时序投票。
        idx = lg.argmax(-1); out = []; prev = -1; conf = []
        for i, k in enumerate(idx):
            if k != prev and k != 0 and 0 <= k - 1 < len(cs):
                out.append(cs[k-1]); conf.append(float(lg[i, k]))
            prev = k
        d = ''.join(c for c in ''.join(out) if c.isdigit())
        if len(d) < 3: return -1
        return int(d[:3])
    preds = {}
    allfiles = sorted(os.listdir(IMG))
    for c in need:
        fs = sorted([f for f in allfiles if f.startswith(c) and f.endswith('.jpg')], key=frame_of)
        t0 = time.perf_counter()
        preds[c] = [(frame_of(fn), fn, decode(cm.predict({iname: to_input(fn)})[oname][0])) for fn in fs]
        print(f'  {c}: {len(fs)} 帧  {(time.perf_counter()-t0)/len(fs)*1000:.1f} ms/帧')
    return preds

if os.path.exists(CACHE):
    z = np.load(CACHE, allow_pickle=True)
    preds = {c: list(z[c]) for c in z.files}
    print('（使用缓存的推理结果）')
else:
    print('=== 连续推理 ===')
    preds = build_preds()
    np.savez(CACHE, **{c: np.array(v, dtype=object) for c, v in preds.items()})

# ---------- 滑动窗众数滤波 ----------
def flt_win(vals, win):
    """win=1 即原样输出；win>1 取窗口内按 ±2 容差的最大簇均值"""
    n = len(vals); out = [None]*n
    half = win // 2
    for i in range(n):
        lo = max(0, i - half); hi = min(n, i + half + 1)
        w = [v for v in vals[lo:hi] if v is not None and v >= 0]
        if not w:
            out[i] = vals[i]; continue
        best, bc = None, -1
        for cand in sorted(set(w)):
            grp = [v for v in w if abs(v - cand) <= 2]
            if len(grp) > bc:
                bc = len(grp); best = int(round(sum(grp) / len(grp)))
        out[i] = best
    return out

print('\n=== 窗口宽度对比（全部 474 个标注帧位）===')
rows = []
for win in [1, 3, 5, 9, 15, 21, 31, 41]:
    tot = ok = 0
    for c, seq in preds.items():
        vals = [int(p) if p >= 0 else None for _, _, p in seq]
        f = flt_win(vals, win)
        pos = {frame_of(fn): fn for fn in need[c]}
        for i, (fr, fn, raw) in enumerate(seq):
            if fr not in pos: continue
            tot += 1
            if f[i] == human[pos[fr]]: ok += 1
    pct = ok / tot * 100
    rows.append((win, ok, tot, pct))
    print(f'  窗口 {win:3d} 帧 ({win/30.0*1000:5.0f} ms):  {ok:3d}/{tot} = {pct:5.2f}%')

best = max(rows, key=lambda r: r[3])
print(f"\n最佳窗口: {best[0]} 帧 → {best[3]:.2f}%")
print(f"门槛 99% → {'达标 ✅' if best[3] >= 99 else '未达标 ❌'}")
