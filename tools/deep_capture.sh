#!/bin/bash
# ============================================================================
#  AuroraDrive 超深度数据采集（v1 · 2026-10-01）
# ============================================================================
#
#  【它采什么】七层数据，每层都落到同一个文件，时间戳对齐：
#    L1 进程层   — CPU% / RSS / nice / 线程数 / 优先级 / 累计 CPU 时间
#    L2 硬件层   — P核/E核频率与占用率、GPU 频率与功率、热压力（powermetrics）
#    L3 系统层   — load average / 内存压力 / swap / 运行队列 / CPU 占用分布
#    L4 应用层   — 引擎统计（推理耗时/帧数/掩码/检测框/降级）
#    L5 分段层   — tick 14 段耗时（PerfBus）
#    L6 主循环   — tickGap / capGap / capWork / 车速 / OCR / 事件计数
#    L7 线程栈   — 每 N 轮一次调用栈采样
#
#  【为什么不用 sample 做耗时测量 —— 重要】
#    `sample` 文档明写：它 **每 1ms 暂停进程一次**（"suspends the process at
#    specified intervals"）。2026-10-01 实测：开着 sample 时引擎推理耗时
#    从 295ms 被抬到 378ms —— **测量工具本身污染了被测量对象**。
#    故本脚本：
#      · 耗时数据一律取**进程内 PerfBus / 引擎日志**（无侵入）
#      · 线程栈采样默认**关闭**（SAMPLE_STACKS=1 才开，且明确标注污染风险）
#
#  【密码处理】
#    本文件**不包含密码**。sudo 密码通过环境变量 SUDO_PW 传入，用完即弃，
#    不落盘、不进命令行历史（-S 从 stdin 读，不是参数）。
#
#  【用法】
#    SUDO_PW=你的密码 ./deep_capture.sh [运行秒数]
#    例如：SUDO_PW=xxx ./deep_capture.sh 120
#
#  【输出】
#    /tmp/aurora_deep_capture.txt     全部数据（追加模式，不覆盖历史）
#    /tmp/aurora_deep_capture.meta    本次采集的元信息
# ============================================================================

set -u

DURATION="${1:-120}"                 # 采集总时长（秒），默认 120
INTERVAL=2                           # 主采样间隔（秒）
OUT=/tmp/aurora_deep_capture.txt
META=/tmp/aurora_deep_capture.meta
ENG=~/Library/Logs/AuroraEngine.log
DBG=/tmp/aurora_debug.log
SAMPLE_STACKS="${SAMPLE_STACKS:-0}"  # 1 = 开启栈采样（有污染风险，默认关）
PW="${SUDO_PW:-}"                    # sudo 密码（不落盘）

# ── 辅助：带密码跑 sudo（密码只经 stdin，不进 argv）──
run_sudo() {
    if [ -n "$PW" ]; then
        echo "$PW" | sudo -S "$@" 2>/dev/null
    else
        sudo -n "$@" 2>/dev/null
    fi
}

# ── 前置检查 ──
echo "════════ AuroraDrive 超深度采集 ════════"
echo "时长: ${DURATION}s   间隔: ${INTERVAL}s   栈采样: $([ "$SAMPLE_STACKS" = "1" ] && echo 开 || echo 关)"
echo ""

HAS_SUDO=0
if [ -n "$PW" ] && run_sudo true; then
    HAS_SUDO=1
    echo "✓ sudo 可用 → 硬件层（P/E核频率、GPU、热压力）将采集"
else
    echo "⚠️ sudo 不可用 → 跳过硬件层（其余六层照常）"
fi

# ── 元信息 ──
{
    echo "===== 采集开始 $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "duration=${DURATION}s interval=${INTERVAL}s stacks=${SAMPLE_STACKS} sudo=${HAS_SUDO}"
    echo "machine=$(sysctl -n hw.model 2>/dev/null) cpu=$(sysctl -n hw.ncpu 2>/dev/null)"
    echo "mem_gb=$(echo "$(sysctl -n hw.memsize 2>/dev/null) / 1073741824" | bc 2>/dev/null)"
} > "$META"

echo "" >> "$OUT"
echo "========================================================================" >> "$OUT"
echo "===== 采集开始 $(date '+%Y-%m-%d %H:%M:%S')  时长=${DURATION}s  间隔=${INTERVAL}s =====" >> "$OUT"
echo "========================================================================" >> "$OUT"

# ── 后台：powermetrics 连续采集（硬件层）──
PW_PID=""
if [ "$HAS_SUDO" = "1" ]; then
    # -i 2000ms，输出追加；用 timeout 保证随脚本结束
    (
        echo "$PW" | sudo -S powermetrics -n $((DURATION / 2 + 5)) -i 2000 \
            -s cpu_power,gpu_power,thermal \
            --show-process-energy 2>/dev/null \
          | grep -E "Sampled system activity|P-Cluster HW active|E-Cluster HW active|GPU HW active frequency|GPU HW active residency|GPU Power|pressure level|AuroraDrive|Name " \
          | sed 's/^/[HW] /' >> "$OUT"
    ) &
    PW_PID=$!
    # ⚠️ 注意：变量后面不要紧跟全角字符（曾误写成 `$PW_PID）`，
    #    shell 会把全角括号并进变量名 → "unbound variable"）。
    echo "· 硬件层采集已启动 (PID $PW_PID)"
fi

# ── 主循环 ──
ROUND=0
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
    ROUND=$((ROUND + 1))
    TS=$(date '+%H:%M:%S')

    {
        echo ""
        echo "########## [$ROUND] $TS ##########"

        # ── L1 进程层 ──
        # ps -o nice 能看出 -20 提权是否生效；etimes 看进程年龄
        echo "--- L1 进程 ---"
        ps -Ao pid,ppid,pcpu,rss,nice,nlwp,pri,etime,comm 2>/dev/null \
          | grep -i "AuroraDriveUI\|aurora" | grep -v grep \
          | awk '{printf "pid=%s ppid=%s cpu=%s%% rss=%sKB nice=%s thr=%s pri=%s up=%s %s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}'

        # 累计 CPU 时间（看真实消耗速率）
        for p in $(pgrep -x AuroraDriveUI 2>/dev/null); do
            echo "  cputime pid=$p: $(ps -p $p -o time= 2>/dev/null | tr -d ' ')"
        done

        # ── L3 系统层 ──
        echo "--- L3 系统 ---"
        echo "  loadavg: $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
        echo "  cpu_usage: $(top -l 1 -n 0 2>/dev/null | grep 'CPU usage' | head -1 | sed 's/^ *//')"
        echo "  mem: $(vm_stat 2>/dev/null | head -4 | tr '\n' ' ' | tr -s ' ')"
        echo "  swap: $(sysctl -n vm.swapusage 2>/dev/null)"
        echo "  thermodynamic: $(sysctl -n machdep.xcpm.cpu_thermal_level 2>/dev/null || echo n/a)"
        echo "  p_core_freq_pct: $(sysctl -n hw.cpufrequency 2>/dev/null || echo n/a)"

        # ── L4 应用层：引擎统计 ──
        echo "--- L4 引擎统计 ---"
        grep "\[ENGINE\] 统计" "$ENG" 2>/dev/null | tail -2

        # ── L5 分段层 ──
        echo "--- L5 tick分段 ---"
        grep "PERF\] tick分段" "$DBG" 2>/dev/null | tail -1

        # ── L6 主循环 ──
        echo "--- L6 tick ---"
        grep " tick: mode=" "$DBG" 2>/dev/null | tail -1 | cut -c1-400

        # ── L7 线程栈（可选，默认关）──
        if [ "$SAMPLE_STACKS" = "1" ]; then
            for p in $(pgrep -x AuroraDriveUI 2>/dev/null); do
                sample $p 1 -file /tmp/dc_s_$p.txt > /dev/null 2>&1
                echo "--- L7 stack pid=$p (⚠️ sample 会暂停进程，耗时数据此时不可信) ---"
                sed -n '/Sort by top of stack/,/^$/p' /tmp/dc_s_$p.txt 2>/dev/null | head -10
            done
        fi
    } >> "$OUT"

    sleep $INTERVAL
done

# ── 收尾 ──
[ -n "$PW_PID" ] && kill $PW_PID 2>/dev/null

{
    echo ""
    echo "===== 采集结束 $(date '+%Y-%m-%d %H:%M:%S')  共 $ROUND 轮 ====="
} >> "$OUT"

echo ""
echo "════════ 采集完成 ════════"
echo "轮数: $ROUND"
echo "输出: $OUT"
echo "大小: $(ls -la "$OUT" 2>/dev/null | awk '{print $5}') 字节"
echo ""
echo "快速摘要："
echo "  进程记录数: $(grep -c 'pid=' "$OUT" 2>/dev/null)"
echo "  引擎统计数: $(grep -c '\[ENGINE\] 统计' "$OUT" 2>/dev/null)"
echo "  分段记录数: $(grep -c 'PERF\] tick分段' "$OUT" 2>/dev/null)"
