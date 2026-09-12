#!/usr/bin/env python3
"""把各批标注 JSON 合并成 data/speed_crops_v3_human.csv"""
import json, os, glob, csv
ROOT='/Users/dupi/Desktop/自动驾驶系统'
OUT=f'{ROOT}/data/speed_crops_v3_human.csv'
rows=[]; rej=[]; seen=set()
for jf in sorted(glob.glob(f'{ROOT}/tools/speed_ocr_rebuild/labels/batch_*.json')):
    d=json.load(open(jf))
    b=d['batch']
    pick=open(f'{ROOT}/tools/speed_ocr_rebuild/batches/batch_{b:03d}.txt').read().split('\n')
    for k,v in d['labels'].items():
        i=int(k); fn=pick[i]
        if fn in seen: continue
        seen.add(fn)
        if v: rows.append((fn,v,'ok',''))
        else: rows.append((fn,'-','reject', d.get('reject_reason',{}).get(k,'')))
os.makedirs(os.path.dirname(OUT),exist_ok=True)
with open(OUT,'w',newline='',encoding='utf-8') as f:
    w=csv.writer(f); w.writerow(['文件名','速度','状态','备注'])
    for r in rows: w.writerow(r)
ok=sum(1 for r in rows if r[2]=='ok'); rj=sum(1 for r in rows if r[2]=='reject')
print(f'已写出 {OUT}')
print(f'  总计 {len(rows)}  |  有效 {ok}  |  剔除 {rj}')
