import csv
from pathlib import Path
bins=[0,1,20,40,60,80,100,120,140,10000]
labels=['<1','1-20','20-40','40-60','60-80','80-100','100-120','120-140','>140']
cnt=[0]*len(labels)
tot=0; nospeed=0
# 高速度段真值分布
hi={'W':0,'NONE':0,'S':0}; hi_brake=0; hi_n=0
for c in sorted(Path('data/lean_clips_clean').glob('clip_*')):
    f=c/'controls_clean.csv'
    if not f.exists(): continue
    for r in csv.DictReader(open(f,encoding='utf-8')):
        s=r['speed_kmh'].strip()
        if s in ('','None'):
            nospeed+=1; continue
        try: v=float(s)
        except: nospeed+=1; continue
        tot+=1
        for i in range(len(labels)):
            if bins[i]<=v<bins[i+1]:
                cnt[i]+=1; break
        if v>=100:
            hi_n+=1
            w=r['w'].strip() not in ('','0'); ss=r['s'].strip() not in ('','0')
            hl='W' if w else ('S' if ss else 'NONE')
            hi[hl]+=1
            if r['space'].strip() not in ('','0') or r['shift'].strip() not in ('','0'): hi_brake+=1
print("=== 训练数据速度分布（有速度帧 %d，无速度帧 %d）==="%(tot,nospeed))
for lab,c in zip(labels,cnt):
    print(f"  {lab:>8} km/h: {c:6d}  ({100*c/max(tot,1):5.2f}%)")
print(f"\n=== 高速段(>=100km/h)共 {hi_n} 帧（占 {100*hi_n/max(tot,1):.3f}%）===")
print("  该速度段真值纵向分布:",hi,f"  其中踩刹车(Space/Shift)帧: {hi_brake} ({100*hi_brake/max(hi_n,1):.1f}%)")
print(f"  对比：整体 W占比 {77.9:.1f}%")
