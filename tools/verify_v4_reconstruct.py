#!/usr/bin/env python3
"""
验证 v4 架构重建 + 同源切槽/缩放数学是否正确。
用 speed_digit_cnn_v4.pth 权重，在 speed_crops_v3 + consensus 标签上跑准确率。
若准确率接近 v4 训练验证值(约 81.9%)，说明整条链路(架构+切槽+缩放+灰度)完全复现。
"""
import torch, torch.nn as nn
import numpy as np, csv, glob, os
from PIL import Image

# ── 复刻推理端常量 ──
SPEED_ROI = (0.455, 0.885, 0.080, 0.050)   # x, y, w, h 全屏归一化
SLOT_CX = [0.479, 0.496, 0.512]             # 全屏归一化槽位中心
SLOT_W = 0.014
SLOT_YMIN, SLOT_YMAX = 0.897, 0.932
TH, TW = 90, 50                             # 模板 H×W

# ROI 相对坐标
roi_x, roi_y, roi_w, roi_h = SPEED_ROI
ROI_CX = [(c - roi_x) / roi_w for c in SLOT_CX]
ROI_HALF_W = (SLOT_W / 2.0) / roi_w
ROI_YMIN = (SLOT_YMIN - roi_y) / roi_h
ROI_YMAX = (SLOT_YMAX - roi_y) / roi_h

def bankers_round(v):
    """复刻 Swift .rounded(.toNearestOrEven) / Python 银行家舍入"""
    return int(np.floor(v + 0.5)) if (v - np.floor(v)) != 0.5 else int(np.floor(v) // 2 * 2)

def nearest_idx(i, srcN, dstN):
    """复刻 Swift nearestSourceIndex"""
    if dstN <= 1 or srcN <= 1:
        return 0
    if i == 0:
        return 0
    if i == dstN - 1:
        return srcN - 1
    step = (srcN - 1) / (dstN - 1)
    return int(i * step)

def crop_slots(gray, w, h):
    """复刻 cropSlots：从 ROI 图切 3 槽（灰度数组 H×W）"""
    slots = []
    for cx in ROI_CX:
        xc = round(cx * w)          # round() = 银行家舍入
        hw = round(ROI_HALF_W * w)
        ymin = round(ROI_YMIN * h)
        ymax = round(ROI_YMAX * h)
        x0, x1 = xc - hw, xc + hw
        if x0 < 0 or x1 > w or ymin < 0 or ymax > h or x1 <= x0 or ymax <= ymin:
            return None
        slots.append(gray[ymin:ymax, x0:x1])
    return slots

def resize_nearest(src, srcH, srcW, dstH, dstW):
    """复刻 resizeNearest"""
    out = np.zeros((dstH, dstW), dtype=np.float32)
    for y in range(dstH):
        sy = nearest_idx(y, srcH, dstH)
        for x in range(dstW):
            sx = nearest_idx(x, srcW, dstW)
            out[y, x] = src[sy, sx]
    return out

# ── 重建 v4 架构 ──
class DigitCNN(nn.Module):
    def __init__(self):
        super().__init__()
        def block(cin, cout, pool):
            L = [nn.Conv2d(cin, cout, 3, padding=1), nn.BatchNorm2d(cout), nn.ReLU(inplace=True)]
            if pool: L.append(nn.MaxPool2d(2, 2))
            return L
        layers = []
        layers += block(1, 16, True)
        layers += block(16, 32, True)
        layers += block(32, 64, True)
        layers += block(64, 128, False)
        layers += block(128, 256, True)
        self.f = nn.Sequential(*layers)
        self.c = nn.Sequential(
            nn.Flatten(), nn.Linear(3840, 512), nn.ReLU(inplace=True), nn.Dropout(0.5),
            nn.Linear(512, 128), nn.ReLU(inplace=True), nn.Linear(128, 10)
        )
    def forward(self, x):
        return self.c(self.f(x))

model = DigitCNN()
sd = torch.load('models/speed_digit_cnn_v4.pth', map_location='cpu', weights_only=True)
model.load_state_dict(sd)
model.eval()

# ── 读标签 ──
labels = {}
with open('data/speed_crops_v3_consensus.csv', newline='', encoding='utf-8-sig') as f:
    for row in csv.DictReader(f):
        fn = row['文件名'].strip()
        sp = row['速度'].strip()
        if sp.isdigit():
            labels[fn] = int(sp)

# ── 批量推理（每槽独立作为单数字样本）──
files = sorted(labels.keys())
print(f'标签样本: {len(files)}')

all_inputs = []   # 每个元素 [90,50] 单槽
all_digits = []   # 每个元素 0-9 单数字标签
triplets = []     # 每个元素 (fn, true_speed)
skipped = 0

for fn in files:
    p = os.path.join('data/speed_crops_v3', fn)
    if not os.path.exists(p):
        skipped += 1
        continue
    img = Image.open(p).convert('L')
    w, h = img.size
    gray = np.asarray(img, dtype=np.float32)
    slots = crop_slots(gray, w, h)
    if slots is None:
        skipped += 1
        continue
    sp = labels[fn]
    digits = [sp // 100, (sp // 10) % 10, sp % 10]
    for s in slots:
        sh_, sw_ = s.shape
        r = resize_nearest(s, sh_, sw_, TH, TW)
        all_inputs.append(r / 255.0)
    all_digits.extend(digits)
    triplets.append((fn, sp))

if not all_inputs:
    print(f'无有效样本（skipped={skipped}）')
    raise SystemExit

X = torch.tensor(np.stack(all_inputs), dtype=torch.float32)[:, None, :, :]  # [M,1,90,50]
with torch.no_grad():
    logits = model(X)            # [M,10]
pred = logits.argmax(dim=-1)     # [M]
Y = torch.tensor(all_digits)

# 每槽独立准确率（按槽位 0/1/2 分组）
M = pred.shape[0]
per_slot = []
for s in range(3):
    idx = list(range(s, M, 3))
    per_slot.append((pred[idx] == Y[idx]).float().mean().item())
# 三位数全对
n_trip = M // 3
pred3 = pred.view(n_trip, 3)
Y3 = Y.view(n_trip, 3)
full_correct = (pred3 == Y3).all(dim=1).float().mean().item()

print(f'有效样本: {n_trip} 图 / {M} 槽（skipped={skipped}）')
print(f'每槽准确率: 百位={per_slot[0]*100:.1f}% 十位={per_slot[1]*100:.1f}% 个位={per_slot[2]*100:.1f}%')
print(f'三位数全对: {full_correct*100:.1f}%')

# 错误样例
wrong = (pred3 != Y3).any(dim=1)
wrong_idx = wrong.nonzero().squeeze(1).tolist()
print(f'\n错误样例（前 15）:')
for i in wrong_idx[:15]:
    fn, true = triplets[i]
    pr = pred3[i].tolist()
    t = Y3[i].tolist()
    print(f'  {fn}: 真实={t[0]}{t[1]}{t[2]} 预测={pr[0]}{pr[1]}{pr[2]}')
