#!/usr/bin/env python3
"""阶段 2｜用全量人工真值训练车速识别模型

- 数据：data/speed_crops_v3_human.csv（7883 有效）
- 划分：按 clip 前缀分组，留一组做测试（防相邻帧泄漏）
- 架构：SpeedNet（3 位数字联合输出，非逐位裁切）
- 输出：checkpoints + ONNX + CoreML
"""
import os, csv, random, json, time
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from PIL import Image

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
IMG = f'{ROOT}/data/speed_crops_v3'
OUT = f'{ROOT}/tools/speed_ocr_rebuild'
CKPT = f'{OUT}/checkpoints'
os.makedirs(CKPT, exist_ok=True)
torch.manual_seed(42); random.seed(42); np.random.seed(42)
DEV = 'mps' if torch.backends.mps.is_available() else 'cpu'
TH, TW = 18, 51

# ---------- 读全量真值 ----------
human = {}
with open(f'{ROOT}/data/speed_crops_v3_human.csv', newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        if row['状态'] == 'ok': human[row['文件名']] = row['速度']
print(f'有效样本: {len(human)}   设备: {DEV}')

def clip_of(fn): return fn.rsplit('_', 1)[0]
groups = {}
for fn in human: groups.setdefault(clip_of(fn), []).append(fn)
print('各 clip 样本数:', {k: len(v) for k, v in sorted(groups.items())})

# 留最大的 clip 做测试（最严苛：完全未见的录制段）
test_clip = max(groups, key=lambda k: len(groups[k]))
tr = [f for f in human if clip_of(f) != test_clip]
va = groups[test_clip]
print(f'训练 {len(tr)}   测试 {len(va)}（测试集 = 整个 clip {test_clip}）')

# ---------- 数据 ----------
_cache = {}
def load_img(fn):
    if fn in _cache: return _cache[fn]
    im = Image.open(os.path.join(IMG, fn)).convert('L').resize((TW, TH), Image.LANCZOS)
    a = np.asarray(im, dtype=np.float32) / 255.0
    arr = a[None]
    _cache[fn] = arr
    return arr

def batch(items, idxs, augment=False):
    xs = np.stack([load_img(items[i]) for i in idxs])
    if augment:
        # ±1px 位移 + 亮度扰动
        for k in range(xs.shape[0]):
            dx, dy = random.randint(-1, 1), random.randint(-1, 1)
            xs[k] = np.roll(xs[k], (dy, dx), axis=(1, 2))
            xs[k] = np.clip(xs[k] * random.uniform(0.85, 1.15) + random.uniform(-0.08, 0.08), 0, 1)
    ys = np.array([[int(human[items[i]][k]) for k in range(3)] for i in idxs], dtype=np.int64)
    return torch.from_numpy(xs.copy()).to(DEV), torch.from_numpy(ys).to(DEV)

class SpeedNet(nn.Module):
    def __init__(self):
        super().__init__()
        def blk(i, o, pool=True):
            L = [nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True)]
            if pool: L.append(nn.MaxPool2d(2, 2))
            return L
        self.f = nn.Sequential(*blk(1, 32), *blk(32, 64), *blk(64, 128), *blk(128, 128, False))
        self.head = nn.Sequential(nn.Flatten(), nn.Linear(128 * 2 * 6, 256),
                                  nn.ReLU(inplace=True), nn.Dropout(0.3))
        self.d0 = nn.Linear(256, 10); self.d1 = nn.Linear(256, 10); self.d2 = nn.Linear(256, 10)
    def forward(self, x):
        h = self.head(self.f(x))
        return self.d0(h), self.d1(h), self.d2(h)

def evaluate(model, items):
    model.eval(); ok = 0; pos = [0, 0, 0]
    with torch.no_grad():
        for s in range(0, len(items), 256):
            idx = list(range(s, min(s + 256, len(items))))
            x, y = batch(items, idx)
            o = model(x)
            pred = torch.stack([o[k].argmax(1) for k in range(3)], 1)
            ok += (pred == y).all(1).sum().item()
            for k in range(3): pos[k] += (pred[:, k] == y[:, k]).sum().item()
    return ok / len(items), [p / len(items) for p in pos]

# ---------- 训练 ----------
model = SpeedNet().to(DEV)
opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
EPOCHS, BS = 60, 128
sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS)
best = 0.0; t0 = time.perf_counter()
print(f'\n=== 训练（{EPOCHS} epochs, batch {BS}）===')
for ep in range(EPOCHS):
    model.train()
    order = list(range(len(tr))); random.shuffle(order)
    tot_loss = 0.0; nb = 0
    for s in range(0, len(order), BS):
        idx = order[s:s + BS]
        x, y = batch(tr, idx, augment=True)
        o = model(x)
        loss = sum(F.cross_entropy(o[k], y[:, k], label_smoothing=0.05) for k in range(3))
        loss.backward(); opt.step(); opt.zero_grad(set_to_none=True)
        tot_loss += loss.item(); nb += 1
    sched.step()
    if (ep + 1) % 5 == 0 or ep == EPOCHS - 1:
        acc, pos = evaluate(model, va)
        el = time.perf_counter() - t0
        print(f'  ep{ep+1:3d}  loss={tot_loss/max(nb,1):.3f}  测试全等={acc*100:5.2f}%  '
              f'逐位={pos[0]*100:.1f}/{pos[1]*100:.1f}/{pos[2]*100:.1f}  {el:.0f}s')
        if acc > best:
            best = acc
            torch.save(model.state_dict(), f'{CKPT}/speednet_best.pt')

torch.save(model.state_dict(), f'{CKPT}/speednet_last.pt')
acc, pos = evaluate(model, va)
print(f'\n=== 最终（取最佳 checkpoint 复评）===')
model.load_state_dict(torch.load(f'{CKPT}/speednet_best.pt', map_location=DEV))
acc, pos = evaluate(model, va)
print(f'  测试集（整个 clip {test_clip}，{len(va)} 张）')
print(f'    完全匹配  : {acc*100:.2f}%')
print(f'    逐位准确率: 百位 {pos[0]*100:.2f}%  十位 {pos[1]*100:.2f}%  个位 {pos[2]*100:.2f}%')
json.dump({'test_clip': test_clip, 'n_test': len(va), 'acc': acc,
           'pos_acc': pos, 'n_train': len(tr)},
          open(f'{CKPT}/train_result.json', 'w'), indent=2, ensure_ascii=False)
