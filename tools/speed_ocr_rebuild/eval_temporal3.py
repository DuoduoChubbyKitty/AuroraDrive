#!/usr/bin/env python3
"""时序滤波 v3 —— 置信度门槛 + 有效读数滑动窗
   设计要点（前两版失败的原因）：
   1. 必须先做置信度过滤。加载画面/菜单帧虽然大多解不出（-1），
      但个别会解出错误的三位数（置信度显著偏低），不加门槛会污染投票。
   2. 窗口应基于「最近 K 个有效读数」而非固定帧数 —— 有效帧是稀疏的。
   3. 不要用锁存式跳变约束（会在速度真实变化时死锁）。
"""
import os, csv, re, time
from collections import Counter, defaultdict
import numpy as np, coremltools as ct
from PIL import Image

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
IMG = f'{ROOT}/data/speed_crops_v3'
PKG = f'{ROOT}/tools/speed_ocr_rebuild/models/speed_ppocrv6_tiny.mlpackage'
OCR = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/tiny'
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

cm = ct.models.MLModel(PKG, compute_units=ct.ComputeUnit.ALL)
sp = cm.get_spec()
iname = sp.description.input[0].name; oname = sp.description.output[0].name

def to_input(fn):
    im = Image.open(os.path.join(IMG, fn)).convert('RGB'); w, h = im.size
    nw = max(1, min(int(round(w * H / h)), W)); im = im.resize((nw, H), Image.LANCZOS)
    c = np.zeros((H, W, 3), np.uint8); c[:, :nw] = np.asarray(im)
    x = ((c.astype(np.float32) / 255.0) - 0.5) / 0.5
    return x.transpose(2, 0, 1)[None].astype(np.float32)

def decode(lg):
    idx = lg.argmax(-1); out = []; prev = -1; cf = []
    for i, k in enumerate(idx):
        if k != prev and k != 0 and 0 <= k - 1 < len(cs):
            out.append(cs[k-1]); cf.append(float(lg[i, k]))
        prev = k
    d = ''.join(c for c in ''.join(out) if c.isdigit())
    if len(d) < 3: return -1, 0.0
    return int(d[:3]), (min(cf) if cf else 0.0)

print('=== 推理（含置信度）===')
seqs = {}
for c in need:
    fs = sorted([f for f in os.listdir(IMG) if f.startswith(c) and f.endswith('.jpg')], key=frame_of)
    seqs[c] = [(frame_of(f), f) + decode(cm.predict({iname: to_input(f)})[oname][0]) for f in fs]
    print(f'  {c}: {len(fs)} 帧')

def temporal(rows, conf_thr, kvalid):
    """conf_thr: 置信度门槛; kvalid: 对最近 K 个有效读数投票"""
    out = {}; buf = []; last = None
    for fr, fn, v, cf in rows:
        if v < 0 or cf < conf_thr:
            out[fr] = last                    # 无效 → 保持上一个已确认值
            continue
        buf.append(v)
        if len(buf) > kvalid: buf.pop(0)
        # 众数（±2 容差）
        best, bc = None, -1
        for cand in sorted(set(buf)):
            grp = [x for x in buf if abs(x - cand) <= 2]
            if len(grp) > bc: bc = len(grp); best = int(round(sum(grp)/len(grp)))
        last = best
        out[fr] = best
    return out

print('\n=== 参数扫描（474 个标注帧位）===')
print(f"{'置信度门槛':>10s} {'K=1':>9s} {'K=3':>9s} {'K=5':>9s} {'K=7':>9s} {'K=11':>9s}")
best = (None, None, -1)
for thr in [0.0, 0.3, 0.5, 0.6, 0.7, 0.8, 0.9]:
    line = f'{thr:10.2f}'
    for K in [1, 3, 5, 7, 11]:
        tot = ok = 0
        for c, rows in seqs.items():
            f = temporal(rows, thr, K)
            pos = {frame_of(fn): fn for fn in need[c]}
            for fr, fn, v, cf in rows:
                if fr not in pos: continue
                tot += 1
                if f[fr] == human[pos[fr]]: ok += 1
        pct = ok / tot * 100
        line += f' {pct:8.2f}%'
        if pct > best[2]: best = (thr, K, pct)
    print(line)

print(f'\n最佳: 置信度门槛={best[0]}  K={best[1]}  →  {best[2]:.2f}%')
print(f"门槛 99% → {'达标 ✅' if best[2] >= 99 else '未达标 ❌'}")
