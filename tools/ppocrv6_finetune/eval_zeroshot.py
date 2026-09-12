#!/usr/bin/env python3
"""阶段1.4 零样本基线：PP-OCRv6 tiny 原版在完整 5077 张测试集上的准确率"""
import os, csv, numpy as np, onnxruntime as ort
from PIL import Image
ROOT='/Users/dupi/Desktop/自动驾驶系统'
IMG=f'{ROOT}/data/speed_crops_v3'
OCR=f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/tiny'
TEST_CLIP='clip_20260827_204437'
H,W=48,320; CONF_MIN=0.30

human={}
for row in csv.DictReader(open(f'{ROOT}/data/speed_crops_v3_human.csv',encoding='utf-8')):
    if row['状态']=='ok': human[row['文件名']]=row['速度']
va=sorted([f for f in human if f.rsplit('_',1)[0]==TEST_CLIP])
cs=[l for l in open(f'{OCR}/keys.txt',encoding='utf-8').read().split('\n') if l!='']
print(f'测试集: {TEST_CLIP}  {len(va)} 张')

def to_input(fn):
    im=Image.open(os.path.join(IMG,fn)).convert('RGB')
    w,h=im.size; nw=max(1,min(int(round(w*H/h)),W))
    im=im.resize((nw,H),Image.LANCZOS)
    c=np.zeros((H,W,3),np.uint8); c[:,:nw]=np.asarray(im)
    x=((c[:,:,::-1].astype(np.float32)/255.0)-0.5)/0.5   # BGR + normalize
    return x.transpose(2,0,1)[None].astype(np.float32)

sess=ort.InferenceSession(f'{OCR}/rec.onnx', providers=['CPUExecutionProvider'])
iname=sess.get_inputs()[0].name

def decode(lg):
    idx=lg.argmax(-1); out=[]; prev=-1; cf=[]
    for i,k in enumerate(idx):
        if k!=prev and k!=0 and 0<=k-1<len(cs): out.append(cs[k-1]); cf.append(float(lg[i,k]))
        prev=k
    d=''.join(c for c in ''.join(out) if c.isdigit())
    return d, (min(cf) if cf else 0.0)

raw_ok=rule_ok=0; lens={}
import time; t0=time.perf_counter()
for fn in va:
    d,conf=decode(sess.run(None,{iname:to_input(fn)})[0][0])
    lens[len(d)]=lens.get(len(d),0)+1
    gt=human[fn]
    if d==gt: raw_ok+=1                      # PaddleOCR 原生判据（全串匹配）
    if len(d)>=2 and conf>=CONF_MIN and d[-3:].zfill(3)==gt: rule_ok+=1
dt=(time.perf_counter()-t0)/len(va)*1000
n=len(va)
print(f'\n=== 零样本基线（PP-OCRv6 tiny 原版）===')
print(f'  ① 原生全串匹配 : {raw_ok}/{n} = {raw_ok/n*100:.2f}%')
print(f'  ② 加解码规则后 : {rule_ok}/{n} = {rule_ok/n*100:.2f}%')
print(f'  单张耗时 {dt:.2f} ms')
print(f'\n  输出数字串长度分布: {dict(sorted(lens.items()))}')
