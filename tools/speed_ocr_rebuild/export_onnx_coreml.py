#!/usr/bin/env python3
"""导出训练好的 SpeedNet → ONNX + CoreML，并验证精度保持"""
import os, csv, numpy as np, torch, torch.nn as nn, coremltools as ct
from PIL import Image
ROOT='/Users/dupi/Desktop/自动驾驶系统'
IMG=f'{ROOT}/data/speed_crops_v3'; OUT=f'{ROOT}/tools/speed_ocr_rebuild'
CKPT=f'{OUT}/checkpoints/speednet_best.pt'; TH,TW=18,51
import sys; sys.path.insert(0, f'{OUT}')
from train_full import SpeedNet   # 复用同一架构定义

human={}
for row in csv.DictReader(open(f'{ROOT}/data/speed_crops_v3_human.csv',encoding='utf-8')):
    if row['状态']=='ok': human[row['文件名']]=row['速度']
test_clip=max({f.rsplit('_',1)[0] for f in human}, key=lambda k: sum(1 for f in human if f.rsplit('_',1)[0]==k))
va=[f for f in human if f.rsplit('_',1)[0]==test_clip]
print(f'验证集 = clip {test_clip}   {len(va)} 张')

m=SpeedNet(); m.load_state_dict(torch.load(CKPT, map_location='cpu')); m.eval()
dummy=torch.randn(1,1,TH,TW)
print(f'参数量: {sum(p.numel() for p in m.parameters())/1e6:.3f} M')

# ONNX
onnx_p=f'{OUT}/models/speednet.onnx'
torch.onnx.export(m, dummy, onnx_p, input_names=['image'], output_names=['d0','d1','d2'],
                  opset_version=17, dynamo=False)
print(f'✅ ONNX → {onnx_p}  {os.path.getsize(onnx_p)/1048576:.2f} MB')

# CoreML
traced=torch.jit.trace(m, dummy)
mlm=ct.convert(traced, inputs=[ct.TensorType(name='image', shape=(1,1,TH,TW))],
               convert_to='mlprogram', minimum_deployment_target=ct.target.macOS15,
               compute_precision=ct.precision.FLOAT16)
pkg=f'{OUT}/models/speednet.mlpackage'; mlm.save(pkg)
sz=sum(os.path.getsize(os.path.join(r,f)) for r,_,fs in os.walk(pkg) for f in fs)/1048576
print(f'✅ CoreML → {pkg}  {sz:.2f} MB')

# 精度验证
def load(fn):
    im=Image.open(os.path.join(IMG,fn)).convert('L').resize((TW,TH),Image.LANCZOS)
    return (np.asarray(im,dtype=np.float32)/255.0)[None]
cm=ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
sp=cm.get_spec(); iname=sp.description.input[0].name
onames=[o.name for o in sp.description.output]
ok_pt=ok_cm=0
import time
t0=time.perf_counter()
for fn in va:
    x=load(fn); gt=human[fn]
    with torch.no_grad():
        o=m(torch.from_numpy(x)[None])
        p=''.join(str(o[k].argmax(1).item()) for k in range(3))
    if p==gt: ok_pt+=1
    r=cm.predict({iname:x[None]})
    arrs=[np.asarray(r[n]).ravel() for n in onames]
    pc=''.join(str(int(a.argmax())) for a in arrs)
    if pc==gt: ok_cm+=1
dt=(time.perf_counter()-t0)/len(va)*1000
print(f'\n=== 精度对照（{len(va)} 张，整个未见 clip）===')
print(f'  PyTorch 原版 : {ok_pt}/{len(va)} = {ok_pt/len(va)*100:.2f}%')
print(f'  CoreML 版    : {ok_cm}/{len(va)} = {ok_cm/len(va)*100:.2f}%')
print(f'  CoreML 单张耗时（含双模型对比）: {dt:.2f} ms')
print(f'  输入名: {iname}   输出名: {onames}')
