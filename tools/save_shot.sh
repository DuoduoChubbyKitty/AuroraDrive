#!/bin/bash
# 把 computer_use 最新截图存成语义文件名
# 用法: save_shot.sh <语义名>
SRC="$1"; NAME="$2"
if [ -z "$SRC" ] || [ -z "$NAME" ]; then echo "用法: save_shot.sh <源png> <名字>"; exit 1; fi
/usr/bin/python3 -c "
import cv2, sys
img = cv2.imread('$SRC')
if img is None: sys.exit('读取失败: $SRC')
H,W = img.shape[:2]
live = cv2.resize(img, (1280, int(H*1280/W)), interpolation=cv2.INTER_AREA)
out = 'data/mac_shots/$NAME.png'
cv2.imwrite(out, live)
print(f'已存 {out}  {live.shape[1]}x{live.shape[0]}')
"
