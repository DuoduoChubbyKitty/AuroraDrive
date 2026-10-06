#!/bin/bash
# ============================================================================
#  verify/run-guarded.sh —— 带「偏好域污染守卫」的自检运行器（W8）
# ============================================================================
#
#  【为什么要它】
#    2026-10-06 实测：并行施工期间有验证台会写用户真域
#    `com.aurora.drive.aiagent`（桩地址 127.0.0.1:18099 / stub-model），
#    导致此刻跑的**任何**自检候选链变成一条无效桩、结论全部失真
#    （取证：verify/evidence-llm/pref-domain-pollution-RECURRENCE.txt）。
#
#    验证方的职责是「结论必须可复现」。故本运行器在每次运行前后各记录一次
#    域状态：**不一致就判定该次结果作废并重试**，绝不拿被污染的输出去写报告。
#
#  【用法】
#    bash verify/run-guarded.sh <输出文件> -- <命令...>
#    例：bash verify/run-guarded.sh verify/evidence-llm/a1-network.txt -- \
#          ./.build/scratch/release/AuroraDrive --llm-selftest --network
#
#  【退出码】0=拿到干净结果；1=重试 N 次仍被污染（结果不可信）
# ============================================================================
set -uo pipefail

OUT="${1:?usage: run-guarded.sh <输出文件> -- <命令...>}"
shift
[ "${1:-}" = "--" ] && shift

DOMAIN="com.aurora.drive.aiagent"
MAX_TRIES=6
SNAPSHOT() { defaults read "$DOMAIN" 2>/dev/null | md5; }

for attempt in $(seq 1 "$MAX_TRIES"); do
    before=$(SNAPSHOT)
    {
        echo "=== RUN #$attempt (guarded) ==="
        echo "cmd: $*"
        echo "ts:  $(date '+%F %T %z')"
        echo "domain-before: $before"
        echo
        "$@"
        ec=$?
        echo
        echo ">>> EXIT=$ec"
    } > "$OUT" 2>&1
    after=$(SNAPSHOT)

    if [ "$before" = "$after" ]; then
        {
            echo
            echo "-- guard --"
            echo "domain-after: $after"
            echo "verdict: CLEAN (unchanged) -> result trustworthy"
        } >> "$OUT"
        echo "RUN#$attempt CLEAN (exit=$ec) -> $OUT"
        exit 0
    else
        {
            echo
            echo "-- guard --"
            echo "domain-after: $after (!= before $before)"
            echo "verdict: POLLUTED during run -> result discarded, retry"
        } >> "$OUT"
        echo "RUN#$attempt POLLUTED (domain changed) -> retry" >&2
        sleep 5
    fi
done

echo "polluted on all $MAX_TRIES attempts; result untrustworthy" >&2
exit 1
