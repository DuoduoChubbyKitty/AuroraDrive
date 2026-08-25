import sys, torch
from pathlib import Path
ROOT = Path("/Users/dupi/Desktop/自动驾驶系统")
sys.path.insert(0, str(ROOT / "src"))
from model import build_m9_mono
device = "mps"
model = build_m9_mono(deploy=False).to(device).eval()
img = torch.rand(2, 3, 224, 224, device=device)
vs = torch.zeros(2, 6, device=device)
cam = model.repvgg(img)
print(f"cam_feat: mean={cam.mean().item():.3f} absmean={cam.abs().mean().item():.3f} max={cam.abs().max().item():.2f} shape={tuple(cam.shape)}")
fused = torch.cat([cam, vs], dim=1)
h1 = torch.relu(model.fusion_head.fc1(fused))
print(f"fc1 out : mean={h1.mean().item():.3f} absmean={h1.abs().mean().item():.3f} max={h1.abs().max().item():.2f}")
h3 = torch.relu(model.fusion_head.fc3(torch.relu(model.fusion_head.fc2(h1))))
print(f"fc3 out : mean={h3.mean().item():.3f} absmean={h3.abs().mean().item():.3f} max={h3.abs().max().item():.2f}")
pre_steer = model.fusion_head.steer_head(h3)
print(f"steer_pre: mean={pre_steer.mean().item():.3f} absmean={pre_steer.abs().mean().item():.3f} (tanh 饱和阈值≈|3|)")
print(f"fc1 weight std={model.fusion_head.fc1.weight.std().item():.4f}  steer_head weight std={model.fusion_head.steer_head.weight.std().item():.4f}")
print("若 cam_feat/fc 输出 max 高达几十~几百 → 必然饱和")
