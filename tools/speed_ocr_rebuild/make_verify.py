#!/usr/bin/env python3
"""二次复核：把已标注的 500 张重新打乱顺序拼图（防记忆），供独立重读"""
import os, json, glob, random
from PIL import Image, ImageDraw
IMAGE_DIR='/Users/dupi/Desktop/自动驾驶系统/data/speed_crops_v3'
OUT='/Users/dupi/Desktop/自动驾驶系统/tools/speed_ocr_rebuild/verify'
os.makedirs(OUT, exist_ok=True)
allf=[]
for jf in sorted(glob.glob('/Users/dupi/Desktop/自动驾驶系统/tools/speed_ocr_rebuild/labels/batch_*.json')):
    d=json.load(open(jf)); b=d['batch']
    pick=open(f'/Users/dupi/Desktop/自动驾驶系统/tools/speed_ocr_rebuild/batches/batch_{b:03d}.txt').read().split('\n')
    for k in d['labels']: allf.append(pick[int(k)])
print(f'待复核 {len(allf)} 张')
random.seed(777); random.shuffle(allf)     # 打乱顺序，与第一遍不同
B=100
for bi in range((len(allf)+B-1)//B):
    chunk=allf[bi*B:(bi+1)*B]
    SCALE=5; COLS=10
    cw,ch=51*SCALE,18*SCALE; PAD=6; TOP=16
    rows=(len(chunk)+COLS-1)//COLS
    canvas=Image.new('RGB',(COLS*(cw+PAD)+PAD, rows*(ch+TOP+PAD)+PAD),(18,18,22))
    dr=ImageDraw.Draw(canvas)
    for i,fn in enumerate(chunk):
        r_,c_=divmod(i,COLS); x=PAD+c_*(cw+PAD); y=PAD+r_*(ch+TOP+PAD)
        im=Image.open(os.path.join(IMAGE_DIR,fn)).convert('RGB').resize((cw,ch),Image.LANCZOS)
        canvas.paste(im,(x,y+TOP)); dr.text((x+2,y+3), f'#{i:03d}', fill=(120,220,255))
    canvas.save(f'{OUT}/verify_{bi:03d}.png')
    open(f'{OUT}/verify_{bi:03d}.txt','w').write('\n'.join(chunk))
print('已生成复核拼图:', sorted(os.listdir(OUT))[:6])
