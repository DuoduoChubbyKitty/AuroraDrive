#!/usr/bin/env python3
"""把 speed_crops_v3 切成标注批次（每批 100 张），生成拼图 + 清单。
   标注时隐藏真值，避免先入为主。
   用法: python3 make_batches.py <起始批号> [每批张数]
"""
import os, sys, csv, random, json
from PIL import Image, ImageDraw

ROOT='/Users/dupi/Desktop/自动驾驶系统'
IMG_DIR=f'{ROOT}/data/speed_crops_v3'
OUT=f'{ROOT}/tools/speed_ocr_rebuild/batches'
os.makedirs(OUT, exist_ok=True)

BATCH = int(sys.argv[2]) if len(sys.argv)>2 else 100
START = int(sys.argv[1]) if len(sys.argv)>1 else 0

# 固定顺序（种子固定 → 全流程可复现）
files = sorted(f for f in os.listdir(IMG_DIR) if f.endswith('.jpg'))
random.seed(20260912)
random.shuffle(files)
total = len(files)

lo = START*BATCH; hi = min(lo+BATCH, total)
if lo >= total:
    print(f'已到末尾（总 {total} 张，起始 {lo}）'); sys.exit(0)
pick = files[lo:hi]

# 拼图（10 列）
SCALE=5; COLS=10
cw,ch=51*SCALE,18*SCALE; PAD=6; TOP=16
rows=(len(pick)+COLS-1)//COLS
W=COLS*(cw+PAD)+PAD; H=rows*(ch+TOP+PAD)+PAD
canvas=Image.new('RGB',(W,H),(18,18,22)); dr=ImageDraw.Draw(canvas)
for i,fn in enumerate(pick):
    r_,c_=divmod(i,COLS)
    x=PAD+c_*(cw+PAD); y=PAD+r_*(ch+TOP+PAD)
    im=Image.open(os.path.join(IMG_DIR,fn)).convert('RGB').resize((cw,ch),Image.LANCZOS)
    canvas.paste(im,(x,y+TOP))
    dr.text((x+2,y+3), f'#{i:03d}', fill=(120,220,255))
sheet=f'{OUT}/batch_{START:03d}.png'
canvas.save(sheet)
with open(f'{OUT}/batch_{START:03d}.txt','w') as f:
    f.write('\n'.join(pick))
print(f'批 {START}: {len(pick)} 张  ({lo}~{hi-1} / {total})')
print(f'拼图: {sheet}')
