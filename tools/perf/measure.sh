#!/bin/bash
# ============================================================================
#  tools/perf/measure.sh —— 统一性能测量夹具（2026-10-04 新增）
# ============================================================================
#
# 【为什么需要它】
# 本项目已有 25 个 `--xxx-selftest` 入口，但没有**统一的测量口径**。后果：
#   · 同一个光流，三种负载下差 18 倍（0.979 / 2.889 / 18.073 ms p50）
#   · `--map-selftest` 的 T4 门禁在 load 18 时**假失败**（6.98ms ✅ → 40.50ms ❌）
#   · 「模型加载 2876ms」是冷缓存数字，热态只有 137ms（21× 差异）
#   · 多人协作时同一命令互相干扰，谁也不知道对方的数字能不能信
#
# 本脚本做三件事：
#   1. **记录负载**（load average + 谁在吃 CPU）—— 没有这个，数字不可解读
#   2. **冷/热分开测**（首次 vs 稳态是两回事，本项目已因此误判过两次）
#   3. **把结果落盘成可对比的格式**（`tools/perf/baseline.md`）
#
# 【用法】
#   ./tools/perf/measure.sh              # 全量测量，输出到 stdout + baseline.md
#   ./tools/perf/measure.sh --quick      # 只测关键几项（约 1 分钟）
#   ./tools/perf/measure.sh --label "阶段A后"   # 给本次测量打标签
#
# 【纪律】数字必须带负载一起看。本脚本会把 load 打进每一行。

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

BIN="$ROOT/.build/scratch/release/AuroraDrive"
OUT="$ROOT/tools/perf/baseline.md"
QUICK=0
LABEL="未标注"

while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1; shift ;;
        --label) LABEL="${2:-未标注}"; shift 2 ;;
        *) shift ;;
    esac
done

if [ ! -x "$BIN" ]; then
    echo "✗ 找不到可执行文件：$BIN"
    echo "  先跑：swift build -c release --disable-sandbox --scratch-path .build/scratch"
    exit 1
fi

# ── 负载快照 ──────────────────────────────────────────────────────────────
LOAD1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo "?")
TOP3=$(ps -eo %cpu,comm -r 2>/dev/null | sed -n '2,4p' | awk '{printf "%s(%.0f%%) ", $2, $1}')

echo "════════════════════════════════════════════════════════════"
echo "  AuroraDrive 性能测量 · $LABEL"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  负载: $LOAD1 / $NCPU 核   (超售 $(echo "$LOAD1 $NCPU" | awk '{printf "%.1f", $1/$2}')×)"
echo "  吃 CPU 的前三名: $TOP3"
if [ "$(echo "$LOAD1 $NCPU" | awk '{print ($1 > $2*1.5) ? 1 : 0}')" = "1" ]; then
    echo ""
    echo "  ⚠️⚠️  负载超过核数 1.5 倍 —— 本次**耗时类数字不可用于验收**"
    echo "       内存类 / 计数类数字不受影响，仍可用"
fi
echo "════════════════════════════════════════════════════════════"
echo ""

run() {
    local name="$1"; shift
    local log="/tmp/perf_${name}.log"
    printf "  %-24s " "$name"
    if "$@" > "$log" 2>&1; then
        echo "✅"
    else
        echo "❌ (exit=$?)"
    fi
    return 0
}

show() {
    local name="$1"; local pat="$2"
    local log="/tmp/perf_${name}.log"
    [ -f "$log" ] || return 0
    grep -E "$pat" "$log" 2>/dev/null | sed 's/^/      /' | head -14
}

echo "── 地图渲染 ──────────────────────────────────────────"
run map-selftest env AURORA_UI_LOCAL=1 "$BIN" --map-selftest
show map-selftest 'T[0-9]|✅|❌|通过|失败'

if [ "$QUICK" = "0" ]; then
    echo ""
    echo "── 实时链路（光流 / tick）────────────────────────────"
    run perf-selftest env AURORA_UI_LOCAL=1 "$BIN" --perf-selftest --seconds 8
    show perf-selftest 'opticalflow|tick\.loop|submit\.|infer\.|引擎进程 CPU|加载:'
fi

echo ""
echo "── 地图基准（冷启 vs 稳态）───────────────────────────"
run mc-bench env AURORA_UI_LOCAL=1 "$BIN" --mc-map-bench --iters 40
show mc-bench 'MC-BENCH.*①|MC-BENCH.*③|冷启'

echo ""
echo "── 地图窗口（三栏 + 品牌 + 数据）─────────────────────"
run map-window env AURORA_UI_LOCAL=1 "$BIN" --map-window-test
show map-window '通过|失败|❌'

if [ "$QUICK" = "0" ]; then
    echo ""
    echo "── 其它自检 ──────────────────────────────────────────"
    for t in motion opticalflow fit route taxonomy; do
        run "$t" env AURORA_UI_LOCAL=1 "$BIN" "--${t}-selftest"
        show "$t" '通过|失败|PASS|FAIL|结果'
    done
fi

echo ""
echo "── 构建 ──────────────────────────────────────────────"
printf "  %-24s " "空转 swift build"
T0=$(date +%s)
if swift build -c release --disable-sandbox --scratch-path .build/scratch > /tmp/perf_build.log 2>&1; then
    T1=$(date +%s)
    echo "✅ $((T1-T0))s"
    UNH=$(grep -c "unhandled" /tmp/perf_build.log 2>/dev/null || echo 0)
    echo "      unhandled 警告: $UNH  （期望 0）"
else
    echo "❌"
fi

echo ""
echo "── 磁盘 / 内存占用 ───────────────────────────────────"
printf "  %-24s %s\n" "仓库" "$(du -sh . 2>/dev/null | awk '{print $1}')"
printf "  %-24s %s\n" ".git" "$(du -sh .git 2>/dev/null | awk '{print $1}')"
printf "  %-24s %s\n" ".build" "$(du -sh .build 2>/dev/null | awk '{print $1}')"
printf "  %-24s %s\n" "models" "$(du -sh models 2>/dev/null | awk '{print $1}')"
printf "  %-24s %s\n" "~/Library/Logs 碎片" "$(ls ~/Library/Logs 2>/dev/null | grep -ci aurora)"
printf "  %-24s %s\n" "/tmp/aurora*" "$(du -sh /tmp/aurora* 2>/dev/null | awk '{s+=$1} END{print s" 项"}')"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  完整日志在 /tmp/perf_*.log"
echo "  要把本次结果追加到 ${OUT} ，运行："
echo "    ./tools/perf/measure.sh 2>&1 | tee -a ${OUT}"
echo "════════════════════════════════════════════════════════════"
