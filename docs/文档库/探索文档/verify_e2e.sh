#!/bin/bash
# 屏幕录制重授后的完整 e2e 验证（游戏前台 + OCR 通路 + 按键通路）
# 用法: ./verify_e2e.sh  [指令1]  [指令2]
set -e
cd ~/Desktop/自动驾驶系统

CMD1="${1:-帮我领奖励}"
CMD2="${2:-帮我钓个鱼}"

echo "── 0. 清理旧进程"
pkill -f 'AuroraDriveUI' 2>/dev/null || true
pkill -f 'release/AuroraDrive' 2>/dev/null || true
sleep 2
ps aux | grep -E 'AuroraDrive' | grep -v grep || echo "(无残留)"

echo "── 1. 游戏切前台"
osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "异环") to true'
sleep 1
echo "frontmost=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')"

echo "── 2. e2e #1: $CMD1（OCR 通路）"
rm -f /tmp/aurora_debug.log
nohup ./AuroraDriveUI.app/Contents/MacOS/AuroraDriveUI --agent-command "$CMD1" > /tmp/e2e_1.log 2>&1 &
sleep 30
echo "frontmost=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')"
grep -E '拿不到截屏|\[rewards\]|\[fishing\]|\[Agent\]|LLM' /tmp/aurora_debug.log | tail -25 || true

echo "── 3. 停 e2e #1，e2e #2: $CMD2（按键通路）"
pkill -f 'AuroraDriveUI --agent-command' 2>/dev/null || true
sleep 2
osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "异环") to true'
sleep 1
rm -f /tmp/aurora_debug.log
nohup ./AuroraDriveUI.app/Contents/MacOS/AuroraDriveUI --agent-command "$CMD2" > /tmp/e2e_2.log 2>&1 &
sleep 45
echo "frontmost=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')"
grep -E '钓鱼|F 键|第.*轮|完成|取消' /tmp/aurora_debug.log | tail -20 || true
echo "── done"
