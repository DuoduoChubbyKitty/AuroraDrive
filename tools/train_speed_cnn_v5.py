#!/usr/bin/env python3
"""
train_speed_cnn_v5.py — 速度表数字识别 v5 训练脚本（路线 A）

核心修正（相对 v4）：
1. 缩放插值统一用 LANCZOS（与推理端未来改的双线性对齐，消除"训练最近邻/推理LANCZOS"的错位）
2. 从 speed_digit_cnn_v4.pth 权重续训（不是从零）
3. 验证集按 clip 前缀分组划分（防同段视频相邻帧泄漏）
4. 数据增强：±1px 位移 + 亮度/对比度扰动
5. label smoothing + cosine 学习率

输入：data/speed_crops_v3/*.jpg（51×18 ROI 图）+ speed_crops_v3_consensus.csv
输出：models/speed_digit_cnn_v5.pth
"""
import torch, torch.nn as nn, torch.nn.functional as F
import numpy as np, csv, os, random, math
from PIL import Image
from pathlib import Path

# ── 常量（与 SpeedOCRReader.swift 严格同源）──
SPEED_ROI = (0.455, 0.885, 0.080, 0.050)
SLOT_CX = [0.479, 0.496, 0.512]
SLOT_W = 0.014
SLOT_YMIN, SLOT_YMAX = 0.897, 0.932
TH, TW = 90, 50
rx, ry, rw, rh = SPEED_ROI
ROI_CX = [(c - rx) / rw for c in SLOT_CX]
ROI_HALF_W = (SLOT_W / 2.0) / rw
ROI_YMIN = (SLOT_YMIN - ry) / rh
ROI_YMAX = (SLOT_YMAX - ry) / rh

# ── 超参 ──
BATCH = 128
EPOCHS = 40
LR = 1e-3
LABEL_SMOOTH = 0.05
AUG_SHIFT = 1          # ±1px 位移
AUG_BRIGHT = 0.15      # 亮度扰动幅度
VAL_RATIO = 0.1        # clip 分组验证占比

# ── 架构（v4 精确重建，已验证 strict load 全匹配）──
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

# ── 数据：读标签 + 按 clip 分组 ──
def load_labels(csv_path):
    labels = {}
    with open(csv_path, newline='', encoding='utf-8-sig') as f:
        for row in csv.DictReader(f):
            fn = row['文件名'].strip()
            sp = row['速度'].strip()
            if sp.isdigit():
                labels[fn] = int(sp)
    return labels

def clip_group(fn):
    # clip_20260827_204249_000061.jpg → clip_20260827_204249
    parts = fn.split('_')
    if len(parts) >= 3:
        return '_'.join(parts[:3])
    return fn

def crop_slots(gray_img, w, h):
    """复刻 cropSlots：从 ROI 灰度图切 3 槽（PIL Image）"""
    slots = []
    for cx in ROI_CX:
        xc = round(cx * w)
        hw = round(ROI_HALF_W * w)
        ym = round(ROI_YMIN * h)
        yM = round(ROI_YMAX * h)
        x0, x1 = xc - hw, xc + hw
        if x0 < 0 or x1 > w or ym < 0 or yM > h or x1 <= x0 or yM <= ym:
            return None
        slots.append(gray_img.crop((x0, ym, x1, yM)))
    return slots

# ── 样本生成：每图 → 3 槽 → LANCZOS resize 90×50 → 归一化 ──
def make_samples2(files, labels, augment=False, seed=None):
    rng = random.Random(seed)
    inputs, digits = [], []
    for fn in files:
        p = os.path.join('data/speed_crops_v3', fn)
        if not os.path.exists(p):
            continue
        img = Image.open(p).convert('L')
        w, h = img.size
        slots = crop_slots(img, w, h)
        if slots is None:
            continue
        sp = labels[fn]
        ds = [sp // 100, (sp // 10) % 10, sp % 10]
        for slot_idx, s in enumerate(slots):
            if augment:
                dx = rng.randint(-AUG_SHIFT, AUG_SHIFT)
                dy = rng.randint(-AUG_SHIFT, AUG_SHIFT)
                if dx != 0 or dy != 0:
                    s = s.transform(s.size, Image.AFFINE, (1, 0, dx, 0, 1, dy), Image.BILINEAR)
            s = s.resize((TW, TH), Image.Resampling.LANCZOS)
            arr = np.asarray(s, dtype=np.float32) / 255.0
            if augment:
                b = 1.0 + rng.uniform(-AUG_BRIGHT, AUG_BRIGHT)
                arr = np.clip(arr * b, 0.0, 1.0)
            inputs.append(arr)
            digits.append(ds[slot_idx])
    X = torch.tensor(np.stack(inputs), dtype=torch.float32)[:, None, :, :]
    Y = torch.tensor(digits, dtype=torch.long)
    return X, Y

def main():
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    print(f'设备: {dev}')

    labels = load_labels('data/speed_crops_v3_consensus.csv')
    files = sorted(labels.keys())
    print(f'标签样本: {len(files)}')

    # clip 分组划分
    groups = {}
    for fn in files:
        groups.setdefault(clip_group(fn), []).append(fn)
    group_names = sorted(groups.keys())
    random.Random(42).shuffle(group_names)
    n_val = max(1, int(len(group_names) * VAL_RATIO))
    val_groups = set(group_names[:n_val])
    train_files = [fn for fn in files if clip_group(fn) not in val_groups]
    val_files = [fn for fn in files if clip_group(fn) in val_groups]
    print(f'clip 组: {len(group_names)} | 训练图: {len(train_files)} 验证图: {len(val_files)}')

    X_train, Y_train = make_samples2(train_files, labels, augment=True, seed=1)
    X_val, Y_val = make_samples2(val_files, labels, augment=False)
    print(f'训练槽: {X_train.shape[0]} | 验证槽: {X_val.shape[0]}')

    model = DigitCNN().to(dev)
    # 从 v4.pth 续训
    v4 = torch.load('models/speed_digit_cnn_v4.pth', map_location='cpu', weights_only=True)
    model.load_state_dict(v4)
    print('已从 v4.pth 加载权重（续训起点）')

    opt = torch.optim.Adam(model.parameters(), lr=LR)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS)

    best_val = 0.0
    for epoch in range(EPOCHS):
        model.train()
        # 打乱 + 分批
        perm = torch.randperm(X_train.shape[0])
        total, correct = 0, 0
        for i in range(0, X_train.shape[0], BATCH):
            idx = perm[i:i+BATCH]
            xb = X_train[idx].to(dev)
            yb = Y_train[idx].to(dev)
            opt.zero_grad()
            logits = model(xb)
            loss = F.cross_entropy(logits, yb, label_smoothing=LABEL_SMOOTH)
            loss.backward()
            opt.step()
            correct += (logits.argmax(1) == yb).sum().item()
            total += yb.shape[0]
        sched.step()
        train_acc = correct / total

        model.eval()
        with torch.no_grad():
            # 验证分块（防 OOM）
            v_correct, v_total = 0, 0
            for i in range(0, X_val.shape[0], 1024):
                xb = X_val[i:i+1024].to(dev)
                yb = Y_val[i:i+1024].to(dev)
                v_correct += (model(xb).argmax(1) == yb).sum().item()
                v_total += yb.shape[0]
        val_acc = v_correct / v_total

        print(f'Epoch {epoch+1:2d}/{EPOCHS} 训练{train_acc*100:.2f}% 验证{val_acc*100:.2f}%', flush=True)
        if val_acc > best_val:
            best_val = val_acc
            torch.save(model.state_dict(), 'models/speed_digit_cnn_v5.pth')
            print(f'  → 保存最佳 (验证 {val_acc*100:.2f}%)', flush=True)

    print(f'\n完成！最佳验证每槽准确率: {best_val*100:.2f}%')

if __name__ == '__main__':
    main()
