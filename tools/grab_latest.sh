#!/bin/bash
# 把 computer_use 最新的截图 artifact 存成语义文件名
# 用法: grab_latest.sh <语义名> [artifacts根目录]
NAME="$1"
ROOT="${2:-.dsh-computer-use/artifacts}"
[ -z "$NAME" ] && { echo "用法: grab_latest.sh <语义名>"; exit 1; }
LATEST=$(ls -t "$ROOT"/*/*.png 2>/dev/null | head -1)
[ -z "$LATEST" ] && { echo "找不到 artifact"; exit 1; }
/usr/bin/python3 -c "
import cv2
img = cv2.imread('$LATEST')
if img is None: raise SystemExit('读取失败')
H,W = img.shape[:2]
live = cv2.resize(img, (1280, int(H*1280/W)), interpolation=cv2.INTER_AREA)
cv2.imwrite('data/mac_shots/$NAME.png', live)
print(f'已存 data/mac_shots/$NAME.png  {live.shape[1]}x{live.shape[0]}  (源 {W}x{H})')
"
