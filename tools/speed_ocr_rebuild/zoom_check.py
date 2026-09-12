import json, csv, os, sys
from PIL import Image, ImageDraw
ROOT='/Users/dupi/Desktop/自动驾驶系统'
IMG_DIR=f'{ROOT}/data/speed_crops_v3'
d=json.load(open('labels/batch_000.json')); L=d['labels']
pick=open('batches/batch_000.txt').read().split('\n')
def load(p):
    o={}
    with open(p,newline='',encoding='utf-8-sig') as f:
        r=csv.reader(f); next(r,None)
        for row in r:
            if len(row)>=2: o[row[0]]=row[1].strip().zfill(3)
    return o
cons=load(f'{ROOT}/data/speed_crops_v3_consensus.csv')
labs=load(f'{ROOT}/data/speed_crops_v3_labels.csv')
IDX=[int(x) for x in sys.argv[1:]] or [0,1,6,13,17,19,4,7]
SCALE=12
cw,ch=51*SCALE,18*SCALE
cols=4; rows=(len(IDX)+cols-1)//cols
W=cols*(cw+14)+14; H=rows*(ch+52)+14
canvas=Image.new('RGB',(W,H),(15,15,18)); dr=ImageDraw.Draw(canvas)
for k,i in enumerate(IDX):
    r_,c_=divmod(k,cols)
    x=14+c_*(cw+14); y=14+r_*(ch+52)
    fn=pick[i]
    im=Image.open(os.path.join(IMG_DIR,fn)).convert('RGB').resize((cw,ch),Image.LANCZOS)
    canvas.paste(im,(x,y+40))
    dr.text((x, y+2),  f'#{i:03d}  我={L.get(f"{i:03d}")}', fill=(120,255,150))
    dr.text((x, y+16), f'cons={cons.get(fn,"-")}', fill=(255,170,120))
    dr.text((x, y+30), f'labs={labs.get(fn,"-")}', fill=(150,200,255))
canvas.save('zoom_check.png')
print('已保存 zoom_check.png', canvas.size)
for i in IDX:
    fn=pick[i]
    print(f'  #{i:03d} {fn}')
