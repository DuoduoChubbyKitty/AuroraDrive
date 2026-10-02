#!/bin/bash
# ============================================================================
#  run_perf_capture.sh — 真机游戏性能采集（一键）
#  用法: SUDO_PW=密码 ./tools/run_perf_capture.sh [秒数]
#  产物: data/perf-2026-10-02/<时间戳>/   七层数据 + 引擎日志快照
# ============================================================================
set -u
DUR="${1:-600}"
PW="${SUDO_PW:-}"
OUTDIR="data/perf-2026-10-02/game-$(date '+%H%M%S')"
mkdir -p "$OUTDIR"

echo "═══ 采集前基线 ═══"
ps aux | grep -E "异环.app/Contents/MacOS/异环|AuroraDriveUI" | grep -v grep | awk '{printf "  %-60s cpu=%s%% rss=%sKB\n",$11,$3,$4}' | head -4

echo ""
echo "═══ 开跑（${DUR}s）→ $OUTDIR ═══"
SUDO_PW="$PW" ./tools/deep_capture.sh "$DUR" 2>&1 | tail -12

cp -f /tmp/aurora_deep_capture.txt "$OUTDIR/deep_capture.txt" 2>/dev/null && echo "  ✓ deep_capture.txt"
for f in ~/Library/Logs/AuroraEngine.log /tmp/aurora_debug.log; do
  [ -f "$f" ] && cp -f "$f" "$OUTDIR/$(basename $f)" && echo "  ✓ $(basename $f)"
done
echo ""
echo "═══ 采集后：关键指标 ═══"
grep -E "yolopx.*Hz|推理计数" "$OUTDIR/AuroraEngine.log" 2>/dev/null | tail -6
echo "产物目录: $OUTDIR"
