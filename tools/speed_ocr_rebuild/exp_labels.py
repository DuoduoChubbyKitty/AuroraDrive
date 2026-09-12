#!/usr/bin/env python3
"""阶段1.2 关键实验：标签质量对训练结果的直接影响

同一架构、同一数据划分，唯一变量是标签来源：
  A) speed_crops_v3_consensus.csv  （旧自动标注，已证实系统性错误）
  B) speed_crops_v3_human.csv      （本次多模态人工判读）

测试集统一用「人工标签」（唯一可信真值）。
另附参照：直接用 PP-OCRv6 识别器在测试集上的准确率（不训练）。
"""
import os, csv, random, sys
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from PIL import Image
from collections import Counter

ROOT = '/Users/dupi/Desktop/自动驾驶系统'
IMG = f'{ROOT}/data/speed_crops_v3'
OUT = f'{ROOT}/tools/speed_ocr_rebuild'
torch.manual_seed(42); random.seed(42); np.random.seed(42)
DEV = 'mps' if torch.backends.mps.is_available() else 'cpu'

# ---------- 读三种标签 ----------
def load_csv(p):
    o = {}
    with open(p, newline='', encoding='utf-8-sig') as f:
        r = csv.reader(f); next(r, None)
        for row in r:
            if len(row) >= 2 and row[1] and row[1] != '-':
                o[row[0]] = row[1].strip().zfill(3)
    return o

human = {}; status = {}
with open(f'{ROOT}/data/speed_crops_v3_human.csv', newline='', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        status[row['文件名']] = row['状态']
        if row['状态'] == 'ok': human[row['文件名']] = row['速度']
cons = load_csv(f'{ROOT}/data/speed_crops_v3_consensus.csv')

# 只保留两份标注都覆盖的样本，保证 A/B 训练数据完全一致
files = sorted(f for f in human if f in cons)
print(f'人工标注有效 {len(human)} 张，与 consensus 的交集 {len(files)} 张（A/B 用同一批）')

# 随机划分：本实验只比较「标签来源」这一个变量，A/B 用同一划分
# （数据只有 4 个 clip，按 clip 划分会让训练集只剩 156 张；最终模型再用 clip 划分）
random.shuffle(files)
n_val = int(len(files) * 0.2)
va = files[:n_val]; tr = files[n_val:]
print(f'划分: 训练 {len(tr)} 张 / 验证 {len(va)} 张')

# ---------- 数据：51×18 灰度 → 3 位数字标签 ----------
TH, TW = 18, 51
_cache = {}
def load_img(fn):
    if fn in _cache: return _cache[fn]
    im = Image.open(os.path.join(IMG, fn)).convert('L').resize((TW, TH), Image.LANCZOS)
    a = np.asarray(im, dtype=np.float32) / 255.0
    _cache[fn] = a[None]
    return _cache[fn]

def batch(items, labels, idxs):
    xs = np.stack([load_img(items[i]) for i in idxs])
    ys = np.array([[int(labels[items[i]][k]) for k in range(3)] for i in idxs], dtype=np.int64)
    return torch.from_numpy(xs).to(DEV), torch.from_numpy(ys).to(DEV)

# ---------- 架构：CRNN-lite，一次出 3 位（不做逐位裁切） ----------
class SpeedNet(nn.Module):
    def __init__(self):
        super().__init__()
        def blk(i, o, pool=True):
            L = [nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True)]
            if pool: L.append(nn.MaxPool2d(2, 2))
            return L
        self.f = nn.Sequential(*blk(1, 32), *blk(32, 64), *blk(64, 128), *blk(128, 128, False))
        self.head = nn.Sequential(nn.Flatten(), nn.Linear(128 * 2 * 6, 256), nn.ReLU(inplace=True),
                                  nn.Dropout(0.3))
        self.d0 = nn.Linear(256, 10); self.d1 = nn.Linear(256, 10); self.d2 = nn.Linear(256, 10)
    def forward(self, x):
        h = self.head(self.f(x))
        return self.d0(h), self.d1(h), self.d2(h)

def evaluate(model, items, labels):
    model.eval(); ok = 0
    with torch.no_grad():
        for s in range(0, len(items), 128):
            idx = list(range(s, min(s + 128, len(items))))
            x, y = batch(items, labels, idx)
            o = model(x)
            pred = torch.stack([o[k].argmax(1) for k in range(3)], 1)
            ok += (pred == y).all(1).sum().item()
    return ok / len(items)

def train(train_labels, tag):
    model = SpeedNet().to(DEV)
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=120)
    EPOCH, BS = 120, 64
    for ep in range(EPOCH):
        model.train()
        order = list(range(len(tr))); random.shuffle(order)
        for s in range(0, len(order), BS):
            idx = order[s:s + BS]
            x, y = batch(tr, train_labels, idx)
            o = model(x)
            loss = sum(F.cross_entropy(o[k], y[:, k]) for k in range(3))
            loss.backward(); opt.step(); opt.zero_grad(set_to_none=True)
        sched.step()
    acc = evaluate(model, va, human)      # 测试集永远是人工标签
    print(f'  [{tag}] 验证(人工真值) 全等 = {acc*100:.1f}%')
    return acc

print('\n=== 1.2 标签质量对照实验 ===')
print('架构/数据/划分完全一致，唯一变量 = 训练标签来源\n')
accA = train(cons, '训练标签 = 旧 consensus（自动）')
accB = train(human, '训练标签 = 人工判读（本次）')
print(f'\n提升: {(accB-accA)*100:+.1f} 个百分点   门槛 15pp → {"达标 ✅" if (accB-accA)*100>=15 else "未达标 ❌"}')

# ---------- 参照：PP-OCRv6 直接识别 ----------
print('\n=== 参照：PP-OCRv6 直接识别（不训练）在人工真值上的准确率 ===')
try:
    import onnxruntime as ort
    for tier in ['tiny', 'small']:
        rp = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/{tier}/rec.onnx'
        kp = f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/{tier}/keys.txt'
        if not os.path.exists(rp): continue
        cs = open(kp, encoding='utf-8').read().split('\n')
        if cs and cs[-1] == '': cs = cs[:-1]
        sess = ort.InferenceSession(rp, providers=['CPUExecutionProvider'])
        iname = sess.get_inputs()[0].name
        ok = 0
        for fn in va:
            bgr = np.asarray(Image.open(os.path.join(IMG, fn)).convert('RGB'))[:, :, ::-1]
            h, w = bgr.shape[:2]
            nw = max(1, min(int(round(w * 48 / h)), 320))
            rs = np.asarray(Image.fromarray(bgr[:, :, ::-1]).resize((nw, 48), Image.LANCZOS))[:, :, ::-1]
            canvas = np.zeros((48, 320, 3), np.uint8); canvas[:, :nw] = rs
            x = ((canvas[:, :, ::-1].astype(np.float32) / 255.0) - 0.5) / 0.5
            logits = sess.run(None, {iname: x.transpose(2, 0, 1)[None].astype(np.float32)})[0][0]
            idx = logits.argmax(-1); s = ''; prev = -1
            for i in idx:
                if i != prev and i != 0 and 0 <= i - 1 < len(cs): s += cs[i - 1]
                prev = i
            d = ''.join(c for c in s if c.isdigit())
            if d and d[:3].zfill(3) == human[fn]: ok += 1
        print(f'  PP-OCRv6 {tier:5s} 全等 = {ok/len(va)*100:.1f}%')
except Exception as e:
    print('  PP-OCRv6 参照失败:', e)
