#!/usr/bin/env python3
"""验证时序滤波后的系统级准确率
在完整连续帧序列上跑 CoreML 模型 → 叠加时序滤波 → 在人工标注帧位上评测
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

# 只在含标注样本的 clip 上做连续评测
need = defaultdict(list)
for fn in human: need[clip_of(fn)].append(fn)
print('含标注的 clip:')
for c, fs in need.items(): print(f'  {c}  {len(fs)} 张标注')

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

def decode(logits):
    idx = logits.argmax(-1); out = []; prev = -1
    for i in idx:
        if i != prev and i != 0 and 0 <= i - 1 < len(cs): out.append(cs[i - 1])
        prev = i
    s = ''.join(out)
    d = ''.join(c for c in s if c.isdigit())
    if not d: return None, 0.0
    # 置信度：被选中的 token 的平均概率
    p = logits[:, idx] if False else None
    return d[:3].zfill(3), 1.0

print('\n=== 逐 clip 连续推理 ===')
seq = {}   # clip -> list of (frame, filename, pred)
allfiles = sorted(os.listdir(IMG))
for c, lab in need.items():
    fs = sorted([f for f in allfiles if f.startswith(c) and f.endswith('.jpg')], key=frame_of)
    t0 = time.perf_counter()
    rows = []
    for fn in fs:
        lg = cm.predict({iname: to_input(fn)})[oname]
        pred, _ = decode(lg[0])
        rows.append((frame_of(fn), fn, pred))
    seq[c] = rows
    print(f'  {c}: {len(fs)} 帧  {(time.perf_counter()-t0)/len(fs)*1000:.1f} ms/帧')

# ---------- 时序滤波 ----------
MAXJUMP = 40      # km/h，相邻帧最大合理跳变
CONFIRM = 3       # 需要连续 N 帧一致才输出
WIN = 1.2         # 秒，候选时间窗

def temporal_filter(rows, fps=30.0):
    """返回 {帧号: 滤波后速度}"""
    out = {}; cand = []; last_good = None
    for fr, fn, pred in rows:
        if pred is None:
            if last_good is not None: out[fr] = last_good
            continue
        v = int(pred)
        # 1) 变化率约束
        if last_good is not None and abs(v - last_good) > MAXJUMP:
            out[fr] = last_good       # 判为非法读数，沿用上一个
            continue
        # 2) 多帧确认（容差 ±2）
        cand.append((v, fr))
        cand = [(cv, cf) for cv, cf in cand if fr - cf <= WIN * fps]
        grp = [cv for cv, cf in cand if abs(cv - v) <= 2]
        if len(grp) >= CONFIRM:
            vv = Counter(grp).most_common(1)[0][0]
            last_good = vv
            out[fr] = vv
        else:
            out[fr] = last_good if last_good is not None else v
    return out

print('\n=== 评测（人工标注帧位上）===')
tot = raw_ok = flt_ok = 0
for c, rows in seq.items():
    filt = temporal_filter(rows)
    raw = {fr: (int(p) if p else None) for fr, fn, p in rows}
    lab_fn = {frame_of(fn): fn for fn in need[c]}
    c_raw = c_flt = c_n = 0
    for fr, fn in lab_fn.items():
        gt = human[fn]
        c_n += 1
        if raw.get(fr) == gt: c_raw += 1
        if filt.get(fr) == gt: c_flt += 1
    tot += c_n; raw_ok += c_raw; flt_ok += c_flt
    print(f'  {c}: 标注 {c_n} 帧  原始 {c_raw}/{c_n} = {c_raw/c_n*100:5.1f}%   '
          f'滤波后 {c_flt}/{c_n} = {c_flt/c_n*100:5.1f}%')

print(f'\n合计:')
print(f'  原始单帧 : {raw_ok}/{tot} = {raw_ok/tot*100:.2f}%')
print(f'  时序滤波后: {flt_ok}/{tot} = {flt_ok/tot*100:.2f}%')
print(f'  门槛 99% → {"达标 ✅" if flt_ok/tot>=0.99 else "未达标 ❌"}')
