#!/bin/bash
# ============================================================================
#  tools/perf/load.sh —— 受控背景负载生成器（收编自 perf-pipeline 的 /tmp/burn.cpp）
# ============================================================================
#  【为什么需要】
#  「等机器空了再测」测的是**用户永远不会遇到的工况**。真实场景是
#  游戏满载 GPU/CPU + 30fps 采集 + 4 个模型推理 + 光流 —— 比几个并发构建高得多。
#  **越高负载越有参考价值。**
#
#  【做法】背景负载跑 UTILITY QoS（模拟游戏/后台的真实优先级分布），
#  被测进程跑 USER_INTERACTIVE（与生产 tick 一致）。
#
#  【用法】
#    bash tools/perf/load.sh build            # 编译（只需一次）
#    bash tools/perf/load.sh run 6 30         # 6 线程 UTILITY 负载，持续 30s
#    bash tools/perf/load.sh with 6 60 -- <命令...>   # 边加载边跑命令
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tools/perf/burn.cpp"
BIN="$ROOT/tools/perf/.burn"

case "${1:-run}" in
  build)
    clang++ -std=c++17 -O2 -pthread -o "$BIN" "$SRC" && echo "✅ 已编译 $BIN"
    ;;
  run)
    [ -x "$BIN" ] || { clang++ -std=c++17 -O2 -pthread -o "$BIN" "$SRC" || exit 1; }
    exec "$BIN" "${2:-6}" "${3:-30}"
    ;;
  with)
    N="${2:-6}"; S="${3:-60}"; shift 3; [ "${1:-}" = "--" ] && shift
    [ -x "$BIN" ] || clang++ -std=c++17 -O2 -pthread -o "$BIN" "$SRC" || exit 1
    "$BIN" "$N" "$S" >/dev/null 2>&1 &
    LOADPID=$!
    trap 'kill $LOADPID 2>/dev/null' EXIT
    sleep 2   # 让负载起来
    echo "  [load] ${N} 线程 UTILITY 负载已起（pid=${LOADPID}，${S}s）"
    "$@"
    RC=$?
    kill $LOADPID 2>/dev/null
    return $RC 2>/dev/null || exit $RC
    ;;
  *) echo "用法: $0 {build|run <线程> <秒>|with <线程> <秒> -- <命令...>}"; exit 2 ;;
esac
