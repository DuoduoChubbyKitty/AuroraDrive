#!/usr/bin/env python3
"""训练速度表数字识别CNN — 10类(0-9)，输入51x18x1灰度"""
import torch, torch.nn as nn, torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader
from PIL import Image
import csv, random, os
from pathlib import Path

# ── 坐标(裁单个数字) ──
SLOT_CX = [0.479, 0.496, 0.512]
SLOT_W = 0.014
SLOT_YMIN, SLOT_YMAX = 0.897, 0.932
TW, TH = 25, 45  # 与字模同尺寸

# ── 数据集 ──
class SpeedDigitDataset(Dataset):
    def __init__(self, frames_dir, labels_csv, train=True):
        self.samples = []  # (img_path, digit)
        with open(labels_csv) as f:
            reader = csv.DictReader(f)
            for row in reader:
                speed_str = (row.get("速度") or row.get("速度(km/h)") or "").strip()
                if not speed_str or speed_str.startswith("?"):
                    continue
                if not speed_str.isdigit():
                    continue
                speed = int(speed_str)
                if speed > 300:
                    continue
                digits = [speed // 100, (speed // 10) % 10, speed % 10]
                fname = (row.get("\ufeff\u6587\u4ef6\u540d") or row.get("\u6587\u4ef6\u540d") or row.get("filename") or "")
                frame_path = Path(frames_dir) / fname
                if not frame_path.exists():
                    continue
                for i, d in enumerate(digits):
                    self.samples.append((str(frame_path), i, d))
        
        random.seed(42)
        random.shuffle(self.samples)
        split = int(len(self.samples) * 0.85)
        self.samples = self.samples[:split] if train else self.samples[split:]
    
    def __len__(self):
        return len(self.samples)
    
    def __getitem__(self, idx):
        path, slot_idx, digit = self.samples[idx]
        img = Image.open(path).convert("L")
        w, h = img.size
        cx = SLOT_CX[slot_idx]
        sx = int(cx * w - SLOT_W * w / 2)
        sy = int(SLOT_YMIN * h)
        sw = int(SLOT_W * w)
        sh = int((SLOT_YMAX - SLOT_YMIN) * h)
        crop = img.crop((sx, sy, sx + sw, sy + sh))
        crop = crop.resize((TW, TH), Image.LANCZOS)
        import numpy as np
        arr = np.array(crop, dtype=np.float32) / 255.0
        return torch.tensor(arr).unsqueeze(0), digit

# ── 模型 ──
class DigitCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 16, 3, padding=1)
        self.conv2 = nn.Conv2d(16, 32, 3, padding=1)
        self.conv3 = nn.Conv2d(32, 64, 3, padding=1)
        self.fc1 = nn.Linear(64 * 3 * 5, 128)
        self.fc2 = nn.Linear(128, 10)
        self.pool = nn.MaxPool2d(2, 2)
    
    def forward(self, x):
        x = self.pool(F.relu(self.conv1(x)))   # 25x45 -> 12x22
        x = self.pool(F.relu(self.conv2(x)))   # -> 6x11
        x = self.pool(F.relu(self.conv3(x)))    # -> 3x5
        x = x.view(-1, 64 * 3 * 5)
        x = F.relu(self.fc1(x))
        x = self.fc2(x)
        return x

# ── 训练 ──
frames_dir = "clip_20260817_124937/frames"
labels_csv = "/Users/dupi/Desktop/速度标注表_easyocr.csv"

train_ds = SpeedDigitDataset(frames_dir, labels_csv, train=True)
val_ds = SpeedDigitDataset(frames_dir, labels_csv, train=False)
print(f"训练: {len(train_ds)} 样本, 验证: {len(val_ds)} 样本")

train_loader = DataLoader(train_ds, batch_size=64, shuffle=True)
val_loader = DataLoader(val_ds, batch_size=64)

device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
print(f"设备: {device}")

model = DigitCNN().to(device)
criterion = nn.CrossEntropyLoss()
optimizer = torch.optim.Adam(model.parameters(), lr=0.001)

best_acc = 0
for epoch in range(30):
    model.train()
    total, correct = 0, 0
    for imgs, labels in train_loader:
        imgs, labels = imgs.to(device), labels.to(device)
        out = model(imgs)
        loss = criterion(out, labels)
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        _, pred = out.max(1)
        correct += (pred == labels).sum().item()
        total += labels.size(0)
    
    # 验证
    model.eval()
    v_correct, v_total = 0, 0
    with torch.no_grad():
        for imgs, labels in val_loader:
            imgs, labels = imgs.to(device), labels.to(device)
            out = model(imgs)
            _, pred = out.max(1)
            v_correct += (pred == labels).sum().item()
            v_total += labels.size(0)
    
    train_acc = correct / total * 100
    val_acc = v_correct / v_total * 100
    print(f"Epoch {epoch+1}: 训练{train_acc:.1f}% 验证{val_acc:.1f}%")
    
    if val_acc > best_acc:
        best_acc = val_acc
        torch.save(model.state_dict(), "models/speed_digit_cnn.pth")
        print(f"  → 保存最佳模型 (验证{val_acc:.1f}%)")

print(f"\n训练完成! 最佳验证准确率: {best_acc:.1f}%")

# ── 转CoreML ──
print("\n转换CoreML...")
import coremltools as ct

model.cpu()
model.eval()
example = torch.randn(1, 1, TH, TW)
traced = torch.jit.trace(model, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="image", shape=(1, 1, TH, TW))],
    classifier_config=ct.ClassifierConfig(list(range(10)))
)
mlmodel.short_description = "速度表数字识别CNN(0-9)"
mlmodel.author = "AuroraDrive"
mlmodel.save("models/speed_digit_cnn.mlmodelc".replace(".mlmodelc", ".mlpackage"))
print("CoreML模型: models/speed_digit_cnn.mlpackage")
