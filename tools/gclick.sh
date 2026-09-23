#!/bin/bash
# 安全点击：先抬游戏并验证前台 -> 点击 -> 截图
# 用法: gclick.sh <名字> <1280空间x> <1280空间y> [等待秒]
NAME="$1"; X="$2"; Y="$3"; W="${4:-3.0}"
SX=$(/usr/bin/python3 -c "print(int($X*1.1484))")
SY=$(/usr/bin/python3 -c "print(int($Y*1.1484+33))")
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is 53168) to true' >/dev/null 2>&1
sleep 0.7
FRONT=$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)
if [ "$FRONT" != "53168" ]; then echo "  ✗ 游戏不在前台，取消点击"; exit 1; fi
cliclick m:$SX,$SY w:150 c:$SX,$SY >/dev/null 2>&1
sleep "$W"
/usr/bin/python3 tools/cgrab.py /tmp/_ctmp.png 0 33 1470 923 >/dev/null 2>&1
/usr/bin/python3 -c "
import cv2
im=cv2.imread('/tmp/_ctmp.png'); H,W=im.shape[:2]
cv2.imwrite('data/mac_shots/$NAME.png', cv2.resize(im,(1280,int(H*1280/W)),interpolation=cv2.INTER_AREA))
print('  ✓ $NAME')"
