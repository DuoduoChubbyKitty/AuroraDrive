#!/bin/bash
# 界面采集流水线：点击 -> 等待 -> 截图 -> 存 1280x803
# 用法: collect_ui.sh <名字> <x> <y> [等待秒]
NAME="$1"; X="$2"; Y="$3"; W="${4:-2.5}"
cliclick m:$X,$Y w:150 c:$X,$Y >/dev/null 2>&1
sleep "$W"
/usr/bin/python3 tools/cgrab.py /tmp/_ctmp.png 0 33 1470 923 >/dev/null 2>&1
/usr/bin/python3 -c "
import cv2
img = cv2.imread('/tmp/_ctmp.png')
H,W = img.shape[:2]
live = cv2.resize(img, (1280, int(H*1280/W)), interpolation=cv2.INTER_AREA)
cv2.imwrite('data/mac_shots/$NAME.png', live)
print(f'  ✓ $NAME  ({live.shape[1]}x{live.shape[0]})')
"
