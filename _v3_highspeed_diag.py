import sys; sys.path.insert(0,'tools/v3_exp'); sys.path.insert(0,'src'); sys.path.insert(0,'.')
import numpy as np, torch
import export_v3_checkpoint_int4 as E
from src.dataset_v3 import V3KeyDataset
from torch.utils.data import DataLoader, Subset
dev='mps' if torch.backends.mps.is_available() else 'cpu'
model,_=E.load_trained_model(__import__('pathlib').Path('models/aurora_v3_best_ep13_20261115.pt'))
model=model.to(dev).eval()
ds=V3KeyDataset('data/lean_clips', skip_all_zero=False, augment=False, decode_workers=4)
# 先扫 label+speed 选高速(W)帧候选：用 dataset 的 index 和 rows
idx=list(range(len(ds)))
# 取每个样本的 vertical 真值 + speed（从 ds 直接查，避免全量推理）
import random; random.seed(0)
cand=[]
for i in idx:
    try:
        it=ds[i]
    except Exception: continue
    v=int(it['vertical']); sp=float(it.get('speed_kmh', torch.tensor(0.0))); sv=float(it.get('speed_valid', torch.tensor(0.0)))
    if sv>=0.5 and sp>=100 and v==0:  # 高速 + 人类W
        cand.append((i,sp))
    if len(cand)>=2500: break
print(f"高速(W)候选帧: {len(cand)}", flush=True)
random.shuffle(cand); cand=cand[:1500]
sub=Subset(ds,[i for i,_ in cand]); loader=DataLoader(sub,batch_size=24,num_workers=0)
# 统计模型在“高速人类W”帧上的输出
conf=np.zeros((3,3),dtype=np.int64); brake_fp=0; n=0; S_out=0; NONE_out=0; W_out=0
with torch.no_grad():
    for b in loader:
        inp={k:b[k].float().to(dev) for k in ['image_hi','image_lo','lane','dets','det_mask','vehicle_state']}
        out=model(**inp)
        vp=out['vertical'].argmax(1).cpu().numpy(); vy=b['vertical'].long().numpy()
        for a,p in zip(vy,vp): conf[a,p]+=1
        bp=(out['brake'][:,0]>0)|(out['handbrake'][:,0]>0)|(out['super_brake'][:,0]>0)|(out['ultimate'][:,0]>0)
        brake_fp+=int(bp.sum()); n+=len(vy)
        S_out+=int((vp==2).sum()); NONE_out+=int((vp==1).sum()); W_out+=int((vp==0).sum())
print(f"\n=== 模型在【高速(>=100)且人类踩油门W】{n} 帧上的输出 ===",flush=True)
print(f"  模型仍判 W(继续冲): {W_out} ({100*W_out/max(n,1):.1f}%)",flush=True)
print(f"  模型判 NONE(不给油): {NONE_out} ({100*NONE_out/max(n,1):.1f}%)",flush=True)
print(f"  模型判 S(倒车/刹车): {S_out} ({100*S_out/max(n,1):.1f}%)  <-- 高速自杀刹车",flush=True)
print(f"  模型任一刹车头触发(含手刹/超级/极致): {brake_fp} ({100*brake_fp/max(n,1):.1f}%)",flush=True)
