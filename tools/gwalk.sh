#!/bin/bash
# 持续走路：按住某键 N 秒，可选同时转视角
# 用法: gwalk.sh <键> <秒> [鼠标转视角dx]
KEY="$1"; SECS="$2"; DX="${3:-0}"
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is 53168) to true' >/dev/null 2>&1
sleep 0.5
FRONT=$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)
[ "$FRONT" != "53168" ] && { echo "  ✗ 游戏不在前台"; exit 1; }
cliclick kd:$KEY >/dev/null 2>&1
if [ "$DX" != "0" ]; then
  # 转视角：按住鼠标中键拖动（很多游戏用这个），这里先用简单鼠标移动
  cliclick m:$(($(cliclick p | cut -d, -f1)+DX)),$(cliclick p | cut -d, -f2) >/dev/null 2>&1
fi
sleep "$SECS"
cliclick ku:$KEY >/dev/null 2>&1
echo "  已按 $KEY ${SECS}s"
