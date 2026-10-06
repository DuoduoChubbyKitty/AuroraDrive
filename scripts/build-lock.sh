#!/bin/bash
# ============================================================================
#  scripts/build-lock.sh —— 原子构建/验收锁（多人协作串行化）
# ============================================================================
#
#  【为什么需要它】
#  SwiftPM 是**全模块编译**：4 个人在同一个模块上并发改文件 + 并发 `swift build`
#  会互相打断，典型报错：
#      error: input file '.../AuroraTheme.swift' was modified during the build
#  更糟的是**一个人写坏，全组都验不了** —— 因为编译是整模块的，
#  任何一处 error 都会让所有人的 `swift build` 失败。
#  这是**基础设施缺陷**，不是某个人的失误；用锁串行化是标准做法。
#
#  【另一个更隐蔽的危害：并发基准测量】
#  实测：3 个 agent 同时跑 `--mc-map-bench --iters 200`，各占 ~85% CPU，
#  系统 loadavg 冲到 5.15/8 核 —— 此时**任何耗时类数字都不可比**。
#  所以「长任务」（自检 / 基准 / 门禁采集）也必须持锁，不只是 `swift build`。
#
#  【用法】
#    bash scripts/build-lock.sh acquire "阶段A验收"   # 拿不到 → 退出码 3
#    bash scripts/build-lock.sh release
#    bash scripts/build-lock.sh status
#    bash scripts/build-lock.sh run "原因" -- <命令...>   # 自动加锁/解锁
#
#  在脚本里（推荐）：
#    bash scripts/build-lock.sh acquire "regression-gate" || exit 3
#    trap 'bash scripts/build-lock.sh release' EXIT
#
#  【设计说明】
#  · 用 `mkdir` 做原子锁 —— bash 3.2 没有 flock 命令，但 mkdir 是原子的
#  · 锁目录里写 `owner`（pid / 时间 / 主机 / 原因），便于判断谁持有
#  · 残留锁超过 STALE_MIN 分钟 → **只提示，不自动删**（万一真的还在跑）
#  · 持锁进程已死 → 提示可安全清理，但仍不自动删（保守）
# ============================================================================
set -uo pipefail

LOCK="${AURORA_BUILD_LOCK:-${TMPDIR:-/tmp}/aurora-build.lock}"
STALE_MIN="${AURORA_BUILD_LOCK_STALE_MIN:-15}"
OWNER_FILE="$LOCK/owner"

_now() { date '+%Y-%m-%d %H:%M:%S'; }

_read_owner() {
    [ -f "$OWNER_FILE" ] || { echo "(无 owner 文件)"; return; }
    cat "$OWNER_FILE" 2>/dev/null
}

_owner_field() {  # $1 = 字段名
    [ -f "$OWNER_FILE" ] || return 1
    sed -n "s/^$1=//p" "$OWNER_FILE" 2>/dev/null | head -1
}

_age_min() {
    [ -d "$LOCK" ] || { echo 0; return; }
    local now birth
    now=$(date +%s)
    birth=$(stat -f %B "$LOCK" 2>/dev/null || echo "$now")
    echo $(( (now - birth) / 60 ))
}

cmd_acquire() {
    local reason="${1:-未说明}"
    if mkdir "$LOCK" 2>/dev/null; then
        {
            echo "pid=${AURORA_LOCK_OWNER_PID:-$PPID}"
            echo "time=$(_now)"
            echo "host=$(hostname)"
            echo "user=$(whoami)"
            echo "reason=$reason"
            echo "cwd=$PWD"
        } > "$OWNER_FILE"
        echo "🔒 已取构建锁：${LOCK}（pid=$$ · ${reason}）"
        return 0
    fi

    # 已被占用
    local age owner_pid
    age=$(_age_min)
    owner_pid=$(_owner_field pid || echo '?')
    echo "⚠️  另一处正在构建/验收 —— 拿不到锁。"
    echo "    锁目录：$LOCK"
    echo "    持有者：pid=$owner_pid  已持有 ${age} 分钟"
    echo "    ----- owner 内容 -----"
    _read_owner | sed 's/^/      /'
    echo "    -----------------------"

    if [ "$owner_pid" != '?' ] && ! kill -0 "$owner_pid" 2>/dev/null; then
        echo "    ⓘ pid $owner_pid 已不存在 → 很可能是残留锁，可安全清理："
        echo "        rm -rf '$LOCK'"
    fi
    if [ "$age" -ge "$STALE_MIN" ]; then
        echo "    ⓘ 已持有 ${age} 分钟 ≥ ${STALE_MIN} 分钟 —— 判定为**陈旧**。"
        echo "      但**不自动删**（万一真的还在跑）。确认后手动：rm -rf '$LOCK'"
    fi
    return 3
}

cmd_release() {
    if [ -d "$LOCK" ]; then
        local owner_pid
        owner_pid=$(_owner_field pid || echo '')
        if [ -n "$owner_pid" ] && [ "$owner_pid" != "${AURORA_LOCK_OWNER_PID:-$PPID}" ]; then
            echo "⚠️  锁的持有者是 pid=${owner_pid}，不是本调用方（${AURORA_LOCK_OWNER_PID:-$PPID}）—— 不释放。"
            echo "    若确认是残留：rm -rf '$LOCK'"
            return 1
        fi
        rm -rf "$LOCK"
        echo "🔓 已释放构建锁：$LOCK"
    else
        echo "ⓘ 锁不存在（无需释放）：$LOCK"
    fi
    return 0
}

cmd_status() {
    if [ -d "$LOCK" ]; then
        echo "🔒 锁被持有：${LOCK}（$(_age_min) 分钟）"
        _read_owner | sed 's/^/    /'
        local p; p=$(_owner_field pid || echo '')
        if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
            echo "    ⓘ pid $p 已不存在 → 残留锁，可 rm -rf '$LOCK'"
        fi
        return 1
    fi
    echo "🔓 无锁（空闲）：$LOCK"
    return 0
}

cmd_run() {
    local reason="${1:-run}"; shift || true
    [ "${1:-}" = "--" ] && shift
    [ $# -gt 0 ] || { echo "用法: build-lock.sh run \"原因\" -- <命令...>"; return 2; }
    cmd_acquire "$reason" || return 3
    local rc=0
    "$@" || rc=$?
    cmd_release
    return $rc
}

case "${1:-status}" in
    acquire) shift; cmd_acquire "${1:-未说明}" ;;
    release) cmd_release ;;
    status)  cmd_status ;;
    run)     shift; cmd_run "$@" ;;
    *) echo "用法: $0 {acquire [原因]|release|status|run \"原因\" -- <命令...>}"; exit 2 ;;
esac
