#!/usr/bin/env python3
"""阶段1.2 准备 PaddleOCR 格式数据集（软链图片，不复制）"""
import os, csv, shutil, json
from collections import defaultdict
ROOT='/Users/dupi/Desktop/自动驾驶系统'
IMG=f'{ROOT}/data/speed_crops_v3'
DS=f'{ROOT}/tools/ppocrv6_finetune/dataset'
os.makedirs(DS, exist_ok=True)

# ── 读真值 ──
human={}
for row in csv.DictReader(open(f'{ROOT}/data/speed_crops_v3_human.csv',encoding='utf-8')):
    if row['状态']=='ok': human[row['文件名']]=row['速度']
print(f'有效样本: {len(human)}')

# ── 划分：沿用既定（测试=整个 clip_204437）──
TEST_CLIP='clip_20260827_204437'
tr=sorted([f for f in human if f.rsplit('_',1)[0]!=TEST_CLIP])
va=sorted([f for f in human if f.rsplit('_',1)[0]==TEST_CLIP])
print(f'训练 {len(tr)}   测试 {len(va)}（{TEST_CLIP}）')

# ── 写标注文件（标准格式：相对路径 <TAB> 文本）──
def write(p, items):
    with open(p,'w',encoding='utf-8') as f:
        for fn in items:
            f.write(f'{fn}\t{human[fn]}\n')
write(f'{DS}/train.txt', tr)
write(f'{DS}/val.txt', va)

# ── 字典：用项目现有 keys.txt（6904 字符，与预训练模型一致）──
src_dict=f'{ROOT}/MaaNTE/assets/MaaCommonAssets/OCR/ppocr_v6/tiny/keys.txt'
shutil.copy(src_dict, f'{DS}/dict.txt')

# ── 图片目录软链（不复制 8301 张）──
link=f'{DS}/images'
if os.path.islink(link) or os.path.exists(link):
    if os.path.islink(link): os.unlink(link)
    elif os.path.isdir(link): shutil.rmtree(link)
os.symlink(IMG, link)

# ── 校验 ──
print(f'\n输出目录: {DS}')
for f in ['train.txt','val.txt','dict.txt']:
    p=os.path.join(DS,f)
    n=sum(1 for _ in open(p,encoding='utf-8'))
    print(f'  {f:10s} {n:6d} 行  {os.path.getsize(p)/1024:.1f} KB')
print(f'  images     → 软链到 {IMG}')
print()
print('train.txt 前 3 行:')
for i,l in enumerate(open(f'{DS}/train.txt',encoding='utf-8')):
    if i>=3: break
    print('   ', repr(l.rstrip()))
print('val.txt 前 3 行:')
for i,l in enumerate(open(f'{DS}/val.txt',encoding='utf-8')):
    if i>=3: break
    print('   ', repr(l.rstrip()))
# 字典核对
kc=len([l for l in open(f'{DS}/dict.txt',encoding='utf-8').read().split('\n') if l!=''])
print(f'\ndict.txt 字符数: {kc}  （预训练模型应为 6904）')
json.dump({'test_clip':TEST_CLIP,'n_train':len(tr),'n_val':len(va)},
          open(f'{DS}/split.json','w'), indent=2, ensure_ascii=False)
