#!/usr/bin/env python3
"""SpeedNet CoreML 版 — 全量评测（含训练集/测试集分离 + 逐位 + 混淆矩阵）"""
import os, csv, numpy as np, coremltools as ct, time
from PIL import Image
from collections import Counter, defaultdict
ROOT='/Users/dupi/Desktop/自动驾驶系统'; IMG=f'{ROOT}/data/speed_crops_v3'
PKG=f'{ROOT}/tools/speed_ocr_rebuild/models/speednet.mlpackage'; TH,TW=18,51
human={}
for row in csv.DictReader(open(f'{ROOT}/data/speed_crops_v3_human.csv',encoding='utf-8')):
    if row['状态']=='ok': human[row['文件名']]=row['速度']
grp=defaultdict(list)
for fn in human: grp[fn.rsplit('_',1)[0]].append(fn)
test_clip=max(grp,key=lambda k:len(grp[k]))
cm=ct.models.MLModel(PKG, compute_units=ct.ComputeUnit.ALL)
sp=cm.get_spec(); iname=sp.description.input[0].name
onames=[o.name for o in sp.description.output]
def load(fn):
    im=Image.open(os.path.join(IMG,fn)).convert('L').resize((TW,TH),Image.LANCZOS)
    return (np.asarray(im,dtype=np.float32)/255.0)[None,None]
res={}; t0=time.perf_counter()
for fn,gt in human.items():
    r=cm.predict({iname:load(fn)})
    p=''.join(str(int(np.asarray(r[n]).ravel().argmax())) for n in onames)
    res[fn]=p
dt=(time.perf_counter()-t0)/len(human)*1000
tr=[f for f in human if f.rsplit('_',1)[0]!=test_clip]; va=grp[test_clip]
def stat(items):
    ok=sum(1 for f in items if res[f]==human[f]); pos=[0,0,0]; conf={k:Counter() for k in range(3)}
    for f in items:
        p,g=res[f],human[f]
        for k in range(3):
            if p[k]==g[k]: pos[k]+=1
            else: conf[k][(g[k],p[k])]+=1
    return ok/len(items)*100, [x/len(items)*100 for x in pos], conf
print(f'=== SpeedNet CoreML 全量评测（{len(human)} 张）===')
print(f'  单张耗时 {dt:.2f} ms\n')
for nm,items in [('测试集（整个未见 clip '+test_clip[-6:]+'）',va), ('训练集（其余 3 clip）',tr), ('全量',list(human))]:
    a,p,c=stat(items)
    print(f'  {nm}  n={len(items)}')
    print(f'    完全匹配 {a:.2f}%    逐位 {p[0]:.2f}/{p[1]:.2f}/{p[2]:.2f}')
    for k,n2 in enumerate(['百位','十位','个位']):
        if c[k]: print(f'      {n2}错误: ' + ', '.join(f'{x}→{y}×{n}' for (x,y),n in c[k].most_common(4)))
