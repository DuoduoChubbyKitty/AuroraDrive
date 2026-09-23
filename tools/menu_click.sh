#!/bin/bash
# 稳健菜单点击 v2：模板匹配检测菜单 -> 点目标 -> 截图
# 用法: menu_click.sh <名字> <1280空间x> <1280空间y> [等待秒] [是否关旧界面]
NAME="$1"; X="$2"; Y="$3"; W="${4:-2.5}"; CLOSE="${5:-1}"
if [ "$CLOSE" = "1" ]; then cliclick m:1410,82 w:150 c:1410,82 >/dev/null 2>&1; sleep 1.8; fi
SX=$(/usr/bin/python3 -c "print(int($X*1.1484))")
SY=$(/usr/bin/python3 -c "print(int($Y*1.1484+33))")
menu_open() {
  /usr/bin/python3 -c "
import cv2,sys
im = cv2.imread('/tmp/_chk.png')
if im is None: sys.exit(1)
live = cv2.resize(im,(1280,803),interpolation=cv2.INTER_AREA)
feat = cv2.imread('/tmp/menu_feature.png')
r = cv2.matchTemplate(live,feat,cv2.TM_CCOEFF_NORMED); _,mx,_,_ = cv2.minMaxLoc(r)
sys.exit(0 if mx>0.7 else 1)" 2>/dev/null
}
ok=0
for i in 1 2 3 4; do
  /usr/bin/python3 tools/cgrab.py /tmp/_chk.png 0 33 1470 923 >/dev/null 2>&1
  if menu_open; then ok=1; break; fi
  cliclick kp:esc >/dev/null 2>&1; sleep 2
done
[ "$ok" = "0" ] && { echo "  ✗ $NAME 菜单打不开"; exit 1; }
cliclick m:$SX,$SY w:150 c:$SX,$SY >/dev/null 2>&1
sleep "$W"
/usr/bin/python3 tools/cgrab.py /tmp/_ctmp.png 0 33 1470 923 >/dev/null 2>&1
/usr/bin/python3 -c "
import cv2
im = cv2.imread('/tmp/_ctmp.png'); H,W = im.shape[:2]
cv2.imwrite('data/mac_shots/$NAME.png', cv2.resize(im,(1280,int(H*1280/W)),interpolation=cv2.INTER_AREA))
print('  ✓ $NAME')"
