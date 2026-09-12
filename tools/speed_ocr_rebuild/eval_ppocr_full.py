#!/usr/bin/env python3
"""复核：PP-OCRv6 在全部人工标注样本上的真实准确率（不训练，直接识别）"""
import os, csv, sys
import numpy as np
from PIL import Image
import onnxruntime as ort

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
IMG = f'{ROOT}/data/speed_crops_v3'
OCR = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6'

human = {}
with open(f'{ROOT}/data/speed_crops_v3_human.csv', newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        if row['状态'] == 'ok': human[row['文件名']] = row['速度']
files = sorted(human.keys())
print(f'人工标注有效样本: {len(files)} 张（全量复核）\n')

def ctc(logits, cs):
    idx = logits.argmax(-1); out = []; prev = -1
    for i in idx:
        if i != prev and i != 0 and 0 <= i - 1 < len(cs): out.append(cs[i - 1])
        prev = i
    return ''.join(out)

def norm3(s):
    d = ''.join(c for c in str(s) if c.isdigit())
    return d[:3].zfill(3) if d else None

def to_tensor(fn, H=48, W=320):
    im = Image.open(os.path.join(IMG, fn)).convert('RGB')
    w, h = im.size
    nw = max(1, min(int(round(w * H / h)), W))
    im = im.resize((nw, H), Image.LANCZOS)
    canvas = np.zeros((H, W, 3), np.uint8)
    canvas[:, :nw] = np.asarray(im)
    x = ((canvas.astype(np.float32) / 255.0) - 0.5) / 0.5
    return x.transpose(2, 0, 1)[None].astype(np.float32)

print(f"{'模型':22s} {'全等':>12s} {'逐位准确率(百/十/个)':>26s}")
print('-' * 66)
for tier in ['tiny', 'small', 'medium']:
    rp = f'{OCR}/{tier}/rec.onnx'
    if not os.path.exists(rp): continue
    cs = open(f'{OCR}/{tier}/keys.txt', encoding='utf-8').read().split('\n')
    if cs and cs[-1] == '': cs = cs[:-1]
    sess = ort.InferenceSession(rp, providers=['CPUExecutionProvider'])
    iname = sess.get_inputs()[0].name
    ok = 0; pos = [0, 0, 0]; tot = 0; errs = []
    for fn in files:
        logits = sess.run(None, {iname: to_tensor(fn)})[0][0]
        p = norm3(ctc(logits, cs)); gt = human[fn]
        if p is None: p = '???'
        tot += 1
        if p == gt: ok += 1
        else:
            for k in range(3):
                if k < len(p) and p[k] == gt[k]: pos[k] += 1
            if len(errs) < 5: errs.append((fn[-14:], gt, p))
    mb = os.path.getsize(rp) / 1048576
    print(f"PP-OCRv6 {tier:8s}({mb:5.1f}MB) {ok:5d}/{tot} {ok/tot*100:5.1f}%   "
          f"{pos[0]/tot*100:5.1f} / {pos[1]/tot*100:5.1f} / {pos[2]/tot*100:5.1f}")
    if errs:
        print('      错例:', '; '.join(f'{g}→{p}' for _, g, p in errs))
