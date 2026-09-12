#!/usr/bin/env python3
"""把 PP-OCRv6 tiny rec 转成 CoreML，并验证精度保持
   路径：ONNX → onnx2torch → torch.jit.trace → coremltools(mlprogram)
"""
import os, csv, sys
import numpy as np, torch, torch.nn as nn
from PIL import Image

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
IMG = f'{ROOT}/data/speed_crops_v3'
OCR = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/tiny'
OUTDIR = f'{ROOT}/tools/speed_ocr_rebuild/models'
os.makedirs(OUTDIR, exist_ok=True)

H, W = 48, 320

print('=== 1. ONNX → PyTorch ===')
from onnx2torch import convert
torch_model = convert(f'{OCR}/rec.onnx').eval()
print('  ✅ 转换完成')

print('\n=== 2. 确定输入 / 输出名 ===')
dummy = torch.randn(1, 3, H, W)
with torch.no_grad():
    out = torch_model(dummy)
print('  输出 shape:', tuple(out.shape), '（应为 [1, T, 6904]）')

print('\n=== 3. 包装成只返回 logits 的模块（避免多输出歧义）===')
class Wrap(nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, x):
        y = self.m(x)
        return y[0] if isinstance(y, (list, tuple)) else y

wrapped = Wrap(torch_model).eval()
with torch.no_grad():
    o2 = wrapped(dummy)
print('  包装后输出:', tuple(o2.shape))

print('\n=== 4. trace → CoreML (mlprogram) ===')
traced = torch.jit.trace(wrapped, dummy)
import coremltools as ct
mlm = ct.convert(
    traced,
    inputs=[ct.TensorType(name='speed_img', shape=(1, 3, H, W))],
    outputs=[ct.TensorType(name='logits')],
    convert_to='mlprogram',
    minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16,
)
pkg = f'{OUTDIR}/speed_ppocrv6_tiny.mlpackage'
mlm.save(pkg)
sz = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(pkg) for f in fs) / 1048576
print(f'  ✅ 已保存 {pkg}   {sz:.2f} MB')

print('\n=== 5. 验证：CoreML 精度是否与 ONNX 一致 ===')
cs = open(f'{OCR}/keys.txt', encoding='utf-8').read().split('\n')
if cs and cs[-1] == '': cs = cs[:-1]

def ctc(logits):
    idx = logits.argmax(-1); out = []; prev = -1
    for i in idx:
        if i != prev and i != 0 and 0 <= i - 1 < len(cs): out.append(cs[i - 1])
        prev = i
    return ''.join(out)

def norm3(s):
    d = ''.join(c for c in str(s) if c.isdigit())
    return d[:3].zfill(3) if d else None

def to_input(fn):
    im = Image.open(os.path.join(IMG, fn)).convert('RGB')
    w, h = im.size
    nw = max(1, min(int(round(w * H / h)), W))
    im = im.resize((nw, H), Image.LANCZOS)
    canvas = np.zeros((H, W, 3), np.uint8)
    canvas[:, :nw] = np.asarray(im)
    x = ((canvas.astype(np.float32) / 255.0) - 0.5) / 0.5
    return x.transpose(2, 0, 1)[None].astype(np.float32)

human = {}
with open(f'{ROOT}/data/speed_crops_v3_human.csv', newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        if row['状态'] == 'ok': human[row['文件名']] = row['速度']
files = sorted(human.keys())

cm = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
sp = cm.get_spec()
iname = sp.description.input[0].name
oname = sp.description.output[0].name
print(f'  CoreML 输入名={iname}  输出名={oname}')

ok_c = ok_t = 0; errs = []
import time
t0 = time.perf_counter()
for fn in files:
    x = to_input(fn)
    lg = cm.predict({iname: x})[oname]
    p = norm3(ctc(lg[0])); gt = human[fn]
    if p == gt: ok_c += 1
    elif len(errs) < 5: errs.append((fn[-14:], gt, p))
dt = (time.perf_counter() - t0) / len(files) * 1000
print(f'\n  CoreML 全等 = {ok_c}/{len(files)} = {ok_c/len(files)*100:.1f}%   单张 {dt:.1f} ms')
if errs: print('  错例:', '; '.join(f'{g}→{p}' for _, g, p in errs))
print(f'\n  （对照 ONNX 原始: 98.5%）')
