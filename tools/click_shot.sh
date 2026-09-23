#!/bin/bash
# 点一个屏幕坐标 -> 等待 -> 截图
# 用法: click_shot.sh <名字> <屏幕x> <屏幕y> [等待秒]
cliclick m:$2,$3 w:150 c:$2,$3 >/dev/null 2>&1
sleep "${4:-3.0}"
/usr/bin/python3 tools/cgrab.py /tmp/_ctmp.png 0 33 1470 923 >/dev/null 2>&1
/usr/bin/python3 -c "
import cv2
im = cv2.imread('/tmp/_ctmp.png'); H,W=im.shape[:2]
cv2.imwrite('data/mac_shots/$1.png', cv2.resize(im,(1280,int(H*1280/W)),interpolation=cv2.INTER_AREA))
print('  ✓ $1')"
