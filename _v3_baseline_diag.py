import sys, os, random
sys.path.insert(0,'tools/v3_exp'); sys.path.insert(0,'src'); sys.path.insert(0,'.')
import numpy as np, torch
import export_v3_checkpoint_int4 as E
from src.dataset_v3 import V3KeyDataset
from torch.utils.data import DataLoader, Subset

dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
print(f"[diag] device={dev}, torch={torch.__version__}", flush=True)
model, _cfg = E.load_trained_model(__import__("pathlib").Path("models/aurora_v3_best_ep13_20261115.pt")); model = model.to(dev).eval()

ds = V3KeyDataset('data/lean_clips', skip_all_zero=False, augment=False, decode_workers=4)
print(f"[diag] 数据集总帧 {len(ds)}", flush=True)
random.seed(0)
idxs = list(range(len(ds)))
if len(idxs) > 6000: idxs = random.sample(idxs, 6000)
loader = DataLoader(Subset(ds, idxs), batch_size=24, num_workers=0)

V = np.zeros((3,3), dtype=np.int64); H = np.zeros((3,3), dtype=np.int64)
n=0; brake_h=0; brake_pred=0; brake_tp=0; seen=0
with torch.no_grad():
    for b in loader:
        inp = {k: b[k].float().to(dev) for k in ['image_hi','image_lo','lane','dets','det_mask','vehicle_state']}
        out = model(**inp)
        vp = out['vertical'].argmax(1).cpu().numpy(); hp = out['horizontal'].argmax(1).cpu().numpy()
        vy = b['vertical'].long().numpy(); hy = b['horizontal'].long().numpy()
        for a,p in zip(vy,vp): V[a,p]+=1
        for a,p in zip(hy,hp): H[a,p]+=1
        bp = (out['brake'][:,0]>0).cpu().numpy().astype(int); by = b['brake'][:,0].numpy().astype(int)
        brake_h += int(by.sum()); brake_pred += int(bp.sum()); brake_tp += int(((bp==1)&(by==1)).sum())
        n += len(vy); seen += len(vy)
        if seen % 1200 < 24: print(f"[diag] 处理 {seen} 帧...", flush=True)

print("\n===== VERTICAL 混淆矩阵 (行=人类真实, 列=模型预测) =====", flush=True)
print("        pred:W   NONE    S", flush=True)
for i,name in enumerate(['W  ','NONE','S  ']): print(f"  {name}: {V[i]}", flush=True)
fwd = V[0].sum(); fwd_ok = V[0,0]; fwd_stop = V[0,1]+V[0,2]
print(f"\n[关键] 人类在W(前进)的帧: {fwd}", flush=True)
print(f"  模型也W(继续走): {fwd_ok} ({100*fwd_ok/max(fwd,1):.1f}%)", flush=True)
print(f"  模型却NONE/S(该走却停): {fwd_stop} ({100*fwd_stop/max(fwd,1):.1f}%)  <- 越大越胆小", flush=True)
tot = V.sum(); model_stop = V[:,1].sum()+V[:,2].sum()
print(f"\n[关键] 模型整体预测 NONE/S(停/刹)占比: {100*model_stop/tot:.1f}% (人类真实停占比 {100*(V[1].sum()+V[2].sum())/tot:.1f}%)", flush=True)
print("\n===== HORIZONTAL 混淆 (行=真实 A/NONE/D) =====", flush=True)
for i,name in enumerate(['A   ','NONE','D   ']): print(f"  {name}: {H[i]}", flush=True)
print(f"\n[brake] 人类刹车帧={brake_h} 模型预测刹车帧={brake_pred} 命中={brake_tp}", flush=True)
print(f"[diag] 完成，共 {n} 帧", flush=True)
