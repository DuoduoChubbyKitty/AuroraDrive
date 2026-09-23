#!/bin/bash
# 把游戏抬到前台并验证；失败返回 1
PID=53168
for i in 1 2 3; do
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1
  sleep 0.8
  FRONT=$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)
  if [ "$FRONT" = "$PID" ]; then echo "✅ 游戏在前台"; exit 0; fi
done
echo "❌ 抬不起来，当前前台 PID=$FRONT"; exit 1
