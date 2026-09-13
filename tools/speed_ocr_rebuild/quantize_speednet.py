#!/usr/bin/env python3
"""SpeedNet：修正输出名 + INT8 量化（含各档对比与精度验证）"""
import os, csv, sys, numpy as np, torch, torch.nn as nn, coremltools as ct
from PIL import Image
from collections import defaultdict
OUT='/Users/dupi/Desktop/自动驾驶系统/tools/speed_ocr_rebuild'
ROOT='/Users/dupi/Desktop/自动驾驶系统'; IMG=f'{ROOT}/data/speed_crops_v3'
sys.path.insert(0, OUT)
from train_full import SpeedNet
TH, TW = 18, 51

human={}
for row in csv.DictReader(open(f'{ROOT}/data/speed_crops_v3_human.csv',encoding='utf-8')):
    if row['状态']=='ok': human[row['文件名']]=row['速度']
grp=defaultdict(list)
for fn in human: grp[fn.rsplit('_',1)[0]].append(fn)
test_clip=max(grp,key=lambda k:len(grp[k])); va=grp[test_clip]
allf=sorted(human.keys())
print(f'有效 {len(human)}   测试 clip {test_clip}（{len(va)} 张）')

m=SpeedNet(); m.load_state_dict(torch.load(f'{OUT}/checkpoints/speednet_best.pt', map_location='cpu')); m.eval()
dummy=torch.randn(1,1,TH,TW); traced=torch.jit.trace(m, dummy)

print('\n=== 重新导出（输出名修正为 d0/d1/d2）===')
mlm=ct.convert(traced,
    inputs=[ct.TensorType(name='image', shape=(1,1,TH,TW))],
    outputs=[ct.TensorType(name='d0'), ct.TensorType(name='d1'), ct.TensorType(name='d2')],
    convert_to='mlprogram', minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16)
base=f'{OUT}/models/speednet.mlpackage'; mlm.save(base)
sp=mlm.get_spec()
print('  输入:', [i.name for i in sp.description.input], ' 输出:', [o.name for o in sp.description.output])

def load(fn):
    im=Image.open(os.path.join(IMG,fn)).convert('L').resize((TW,TH),Image.LANCZOS)
    return (np.asarray(im,dtype=np.float32)/255.0)[None,None]

def du(p):
    return sum(os.path.getsize(os.path.join(r,f)) for r,_,fs in os.walk(p) for f in fs)/1048576

def evaluate(pkg, items, onames):
    cm=ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
    sp=cm.get_spec(); iname=sp.description.input[0].name
    ok=0; errs=[]
    for fn in items:
        r=cm.predict({iname:load(fn)})
        p=''.join(str(int(np.asarray(r[n]).ravel().argmax())) for n in onames)
        if p==human[fn]: ok+=1
        elif len(errs)<3: errs.append((fn[-16:],human[fn],p))
    return ok/len(items)*100, errs

base_names=['d0','d1','d2']
acc_base, _ = evaluate(base, va, base_names)
print(f'\n=== 量化对比（测试集 {len(va)} 张 + 全量 {len(allf)} 张）===')
print(f"{'档位':>16s} {'体积':>10s} {'测试集':>9s} {'全量':>9s}  备注")
print('-'*68)
print(f"{'fp16 (基线)':>16s} {du(base):9.2f}M {acc_base:8.2f}% {'—':>9s}  输出名已修正")

from coremltools.optimize.coreml import (OptimizationConfig, OpLinearQuantizerConfig,
                                         linear_quantize_weights, OpPalettizerConfig,
                                         palettize_weights)
jobs=[
 ("int8 线性(per-channel)", OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")), linear_quantize_weights, "speednet_int8.mlpackage"),
 ("8-bit 调色板",           OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=8)), palettize_weights, "speednet_pal8.mlpackage"),
 ("6-bit 调色板",           OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=6)), palettize_weights, "speednet_pal6.mlpackage"),
 ("4-bit 调色板",           OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=4)), palettize_weights, "speednet_pal4.mlpackage"),
]
best=(None,-1)
for label, cfg, fn, name in jobs:
    p=f'{OUT}/models/{name}'
    try:
        q=fn(mlm, config=cfg); q.save(p)
        a_va,_ = evaluate(p, va, base_names)
        a_all,_ = evaluate(p, allf, base_names)
        print(f"{label:>16s} {du(p):9.2f}M {a_va:8.2f}% {a_all:8.2f}%  {'✅' if a_va>=99 else '⚠️'}")
        if a_va>best[1]: best=(label,a_va,name)
    except Exception as e:
        print(f"{label:>16s} {'-':>10s} {'失败':>9s} {'':>9s}  {type(e).__name__}: {str(e)[:40]}")
print('-'*68)
print(f"最佳: {best[0]} → 测试集 {best[1]:.2f}%  （{best[2]}）")
