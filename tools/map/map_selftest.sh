#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ============================================================================
#  tools/map/map_selftest.sh — 原生地图严格自检：跑一遍 + 汇总 + 落日志
# ============================================================================
#
#  为什么要有这个脚本：
#    `--map-selftest` 的判定全在进程退出码里（T1~T6 任一项不达标 → 非 0）。
#    但 CI / 人手跑的时候还需要三样东西，脚本负责补齐：
#      ① 完整输出留档（默认 tools/map/map_selftest.log，便于前后对比）
#      ② 一眼看出「失败的是哪几条」（直接 grep ❌）
#      ③ 把 T4/T5/T6 的实测数值从输出里摘出来单独列（性能回归靠数字看趋势）
#
#  用法：
#    tools/map/map_selftest.sh                     # 跑现有 release 产物
#    MAP_SELFTEST_BIN=/path/to/AuroraDrive tools/map/map_selftest.sh
#    MAP_SELFTEST_LOG=/tmp/x.log tools/map/map_selftest.sh
#
#  退出码 = 自检进程的退出码（0 = T1~T6 全过）。
#  注意：本脚本**不负责编译**（编译是 `swift build -c release --disable-sandbox
#  --scratch-path .build/scratch`），避免把「编译失败」和「自检失败」混成一个码。
# ============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${MAP_SELFTEST_BIN:-$ROOT/.build/scratch/release/AuroraDrive}"
LOG="${MAP_SELFTEST_LOG:-$ROOT/tools/map/map_selftest.log}"

if [ ! -x "$BIN" ]; then
  echo "✗ 找不到可执行文件：$BIN"
  echo "  先编译：swift build -c release --disable-sandbox --scratch-path .build/scratch"
  exit 127
fi

cd "$ROOT" || exit 127
echo "▶ 二进制：$BIN"
echo "▶ 日志：  $LOG"
echo "───────────────────────────────────────────────────────────────"

# AURORA_UI_LOCAL=1：强制本地模式（不连引擎），与任务书给的跑法一致
AURORA_UI_LOCAL=1 "$BIN" --map-selftest 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"

echo "───────────────────────────────────────────────────────────────"
echo "▶ 汇总"

ok=$(grep -c '✅' "$LOG" || true)
bad=$(grep -c '❌' "$LOG" || true)
echo "  ✅ $ok 项   ❌ $bad 项"

if [ "$bad" -gt 0 ]; then
  echo "  失败项："
  grep '❌' "$LOG" | sed 's/^/    /'
fi

# T4/T5/T6 的实测数值（性能回归看趋势用；断言细节以日志为准）
echo "  实测数值（T4/T5/T6）："
grep -E '^     (剔除开销|起始 RSS|禁用词)|^  [✅❌] T[456] ·' "$LOG" | sed 's/^/    /'

echo "───────────────────────────────────────────────────────────────"
if [ "$rc" -eq 0 ]; then
  echo "✅ 原生地图严格自检通过（T1~T6），退出码 0"
else
  echo "❌ 原生地图严格自检失败，退出码 $rc（详见 $LOG）"
fi
exit "$rc"
