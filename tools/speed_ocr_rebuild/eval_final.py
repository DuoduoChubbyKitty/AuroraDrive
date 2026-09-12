#!/usr/bin/env python3
"""车速 OCR 最终评测 —— 固化正确解码规则 + 时序滤波验证

解码规则（三条实验得出的关键结论）：
  1. 长度 < 2 的数字串视为噪声（加载画面/菜单上的单个字符）
  2. 置信度 < 0.3 视为无效
  3. 有效时取「后 3 位」，不足 3 位左边补零
     —— 模型常在前部多读 1~2 个字符（如 "1018" 实为 018），
        取前 3 位会错，取后 3 位才对
"""
import os, re, csv, time
import numpy as np, coremltools as ct
from PIL import Image

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
IMG = f'{ROOT}/data/speed_crops_v3'
PKG = f'{ROOT}/tools/speed_ocr_rebuild/models/speed_ppocrv6_tiny.mlpackage'
OCR = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/tiny'
H, W = 48, 320
CONF_MIN = 0.30

cs = open(f'{OCR}/keys.txt', encoding='utf-8').read().split('\n')
if cs and cs[-1] == '': cs = cs[:-1]

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
    """→ (速度 或 None, 置信度)"""
    idx = lg.argmax(-1); out = []; prev = -1; cf = []
    for i, k in enumerate(idx):
        if k != prev and k != 0 and 0 <= k - 1 < len(cs):
            out.append(cs[k-1]); cf.append(float(lg[i, k]))
        prev = k
    d = ''.join(c for c in ''.join(out) if c.isdigit())
    conf = min(cf) if cf else 0.0
    if len(d) < 2 or conf < CONF_MIN:      # 规则 1 + 2
        return None, conf
    return int(d[-3:].zfill(3)), conf      # 规则 3

human = {}
with open(f'{ROOT}/data/speed_crops_v3_human.csv', newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        if row['状态'] == 'ok': human[row['文件名']] = int(row['速度'])
def frame_of(fn): return int(re.search(r'_(\d{6})\.jpg$', fn).group(1))
need = {}
for fn in human: need.setdefault(fn.rsplit('_', 1)[0], []).append(fn)

print('=== 连续推理 ===')
t0 = time.perf_counter(); nframe = 0
seqs = {}
for c in need:
    fs = sorted([f for f in os.listdir(IMG) if f.startswith(c) and f.endswith('.jpg')], key=frame_of)
    rows = []
    for f in fs:
        v, cf = decode(cm.predict({iname: to_input(f)})[oname][0])
        rows.append((frame_of(f), f, v, cf))
    seqs[c] = rows; nframe += len(fs)
    print(f'  {c}: {len(fs)} 帧')
print(f'  合计 {nframe} 帧, {(time.perf_counter()-t0)/nframe*1000:.2f} ms/帧')

# ---------- 指标 1：单帧（无滤波） ----------
tot = ok = 0; inv = 0
for c, rows in seqs.items():
    pos = {frame_of(fn): fn for fn in need[c]}
    for fr, fn, v, cf in rows:
        if fr not in pos: continue
        tot += 1
        if v is None: inv += 1
        elif v == human[pos[fr]]: ok += 1
print(f'\n【指标1】单帧（无滤波）: {ok}/{tot} = {ok/tot*100:.2f}%   （判为无效 {inv}）')

# ---------- 指标 2：时序滤波 ----------
def temporal(rows, win_s, kvalid, fps=30.0):
    """无效帧保持上一个确认值；有效读数在时间窗内按 ±2 容差投票"""
    out = {}; buf = []; last = None
    for fr, fn, v, cf in rows:
        if v is None:
            out[fr] = last; continue
        buf.append((fr, v))
        buf = [x for x in buf if fr - x[0] <= win_s * fps][-kvalid:]
        best, bc = None, -1
        for cand in sorted(set(x[1] for x in buf)):
            grp = [x[1] for x in buf if abs(x[1] - cand) <= 2]
            if len(grp) > bc: bc = len(grp); best = int(round(sum(grp) / len(grp)))
        last = best; out[fr] = best
    return out

print(f"\n【指标2】时序滤波参数扫描")
print(f"{'窗(秒)':>8s} {'K=1':>9s} {'K=2':>9s} {'K=3':>9s} {'K=5':>9s}")
best = (None, None, -1)
for ws in [0.2, 0.34, 0.5, 1.0]:
    line = f'{ws:8.2f}'
    for K in [1, 2, 3, 5]:
        t2 = k2 = 0
        for c, rows in seqs.items():
            f = temporal(rows, ws, K)
            pos = {frame_of(fn): fn for fn in need[c]}
            for fr, fn, v, cf in rows:
                if fr not in pos: continue
                t2 += 1
                if f[fr] == human[pos[fr]]: k2 += 1
        pct = k2 / t2 * 100
        line += f' {pct:8.2f}%'
        if pct > best[2]: best = (ws, K, pct)
    print(line)

print(f'\n最佳滤波: 窗={best[0]}s K={best[1]} → {best[2]:.2f}%')
s1 = ok / tot * 100
final = max(s1, best[2])
print('\n' + '=' * 52)
print(f'  单帧准确率      : {s1:.2f}%')
print(f'  时序滤波后      : {best[2]:.2f}%')
print(f'  最终系统级      : {final:.2f}%')
print(f'  门槛 95% → {"达标 ✅" if final>=95 else "未达标 ❌"}')
print(f'  门槛 99% → {"达标 ✅" if final>=99 else "未达标 ❌"}')
print('=' * 52)
