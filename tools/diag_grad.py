import sys, torch
from pathlib import Path

ROOT = Path("/Users/dupi/Desktop/自动驾驶系统")
sys.path.insert(0, str(ROOT / "src"))

from model import build_m9_mono, M9Loss
from mono_dataset import MonoClipsDataset, make_train_val_split
from config import LOSS_WEIGHTS, TRAIN_GRAD_CLIP_NORM, TRAIN_WEIGHT_DECAY

device = "mps"
torch.manual_seed(0)
model = build_m9_mono(deploy=False).to(device)
loss_fn = M9Loss(**LOSS_WEIGHTS)
opt = torch.optim.AdamW(model.parameters(), lr=3e-4, weight_decay=TRAIN_WEIGHT_DECAY)


def pnorm():
    return sum(p.norm().item() ** 2 for p in model.parameters() if p.requires_grad) ** 0.5


ds = MonoClipsDataset(ROOT / "data" / "raw_clips", image_size=(224, 224), augment=True)
train_ds, _ = make_train_val_split(ds, val_ratio=0.15, seed=0)
loader = torch.utils.data.DataLoader(train_ds, batch_size=4, shuffle=True, num_workers=0)
it = iter(loader)

print(f"param_norm(init) = {pnorm():.4f}")
# 跟踪一个具体参数，避免 pnorm 浮点噪声
track = next(iter(model.fusion_head.steer_head.parameters())).detach().clone()
import copy
track0 = copy.deepcopy(track)
print("=== 跑 30 步，看 loss 能否跌破 1.5047(训练冻结值) ===")
min_loss = 1e9
for step in range(30):
    batch = next(it)
    img = batch["image"].to(device)
    vs = batch["vehicle_state"].to(device)
    gt_s = batch["steer"].to(device)
    gt_t = batch["throttle"].to(device)
    gt_b = batch["brake"].to(device)
    pred_s, pred_t, pred_b = model(img, vs)
    loss, comps = loss_fn(pred_s, pred_t, pred_b, gt_s, gt_t, gt_b)
    opt.zero_grad()
    loss.backward()
    gn = torch.nn.utils.clip_grad_norm_(model.parameters(), TRAIN_GRAD_CLIP_NORM)
    opt.step()
    min_loss = min(min_loss, loss.item())
    if step % 5 == 0 or step == 29:
        delta = (track - track0).norm().item()
        print(f"  step{step:2d}: loss={loss.item():.4f} min={min_loss:.4f} "
              f"grad={gn.item():.2f} steer_predμ={pred_s.mean().item():.3f} σ={pred_s.std().item():.3f} "
              f"thr_predμ={pred_t.mean().item():.3f} br_predμ={pred_b.mean().item():.3f} "
              f"steer_headΔ={delta:+.5f}")
print("DONE")
