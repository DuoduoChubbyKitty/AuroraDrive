#!/bin/bash
# gpu-attrib.sh — 按进程归因 GPU 时间（只读，不改系统状态）
#
# 【为什么需要】
#   powermetrics --show-process-gpu 的 per-process GPU ms/s 在本机恒为 0.00，
#   lsof/vmmap 也看不到 CoreML 权重映射。要判断"36.4% 设备级 GPU 活跃"
#   到底是谁贡献的，必须另找数据源。
#
# 【数据源】IORegistry 里 AGXDeviceUserClient 节点的 AppUsage 数组：
#     "IOUserClientCreator" = "pid 669, WindowServer"
#     "AppUsage" = ({"API"="Metal","lastSubmittedTime"=...,"accumulatedGPUTime"=...})
#   accumulatedGPUTime 是每个 GPU 客户端累积的 GPU 执行时间（纳秒），
#   按 pid 聚合后做两次采样求差，即得该进程的 GPU 占用率。
#
# 【口径限制】（实测，别当万能）
#   - 只统计 Metal（含 Metal 承载的 Core Image / SceneKit / SpriteKit / Core ML GPU 路径）。
#     Core ML 若走 ANE 或 CPU 不出现；走 GPU 时通常计入该进程 Metal 客户端。
#   - 按 pid 聚合，同一 pid 的多个 GPU 客户端会相加。
#   - AGXDeviceUserClient 节点在进程退出后消失，长窗口采样会漏掉已退出进程。
#   - 折合的"设备活跃 %"是双向累加的设备时间占比，与 powermetrics 的
#     "GPU 活跃驻留"口径不完全等价（后者按采样窗口内 GPU 非空闲时间计），
#     数量级可比，绝对值会有偏差，只用来看相对份额。
#
# 【用法】
#   bash scripts/gpu-attrib.sh            # 默认 2s 窗口 × 3 次
#   bash scripts/gpu-attrib.sh 2 5        # 2s 窗口 × 5 次
#   bash scripts/gpu-attrib.sh 5 1        # 5s 窗口 × 1 次（单次更稳）
#
# 【配套】需要设备级对照时同窗口跑：
#   ioreg -r -c IOAccelerator -w 0 | grep -o '"Device Utilization %"=[0-9]*'

set -u
INTERVAL="${1:-2}"
ROUNDS="${2:-3}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "错误: 需要 python3（用于解析 ioreg -a 的 XML 输出）" >&2
    exit 1
fi

exec python3 - "$INTERVAL" "$ROUNDS" <<'PY'
import plistlib
import re
import subprocess
import sys
import time


_NAME_CACHE = {}


def resolve_name(pid, fallback):
    """creator 里的进程名被内核截断到 16 字符，用 ps 按 pid 换全名"""
    if pid in _NAME_CACHE:
        return _NAME_CACHE[pid]
    name = fallback
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True, check=False,
        ).stdout.decode("utf-8", "replace").strip()
        if out:
            name = out.rsplit("/", 1)[-1]
    except OSError:
        pass
    _NAME_CACHE[pid] = name
    return name


def sample():
    """返回 {pid: (进程名, accumulatedGPUTime 总和, 客户端数)}"""
    raw = subprocess.run(
        ["ioreg", "-a", "-r", "-c", "AGXDeviceUserClient"],
        capture_output=True, check=False,
    ).stdout
    if not raw:
        return {}
    nodes = plistlib.loads(raw)
    usage = {}
    for node in nodes:
        m = re.match(r"pid (\d+), (.+)", node.get("IOUserClientCreator", ""))
        if not m:
            continue
        pid = int(m.group(1))
        name = resolve_name(pid, m.group(2).strip())
        total = sum(e.get("accumulatedGPUTime", 0) for e in node.get("AppUsage", []))
        prev = usage.get(pid)
        usage[pid] = (name, prev[1] + total, prev[2] + 1) if prev else (name, total, 1)
    return usage


def device_util():
    """设备级 Device Utilization %（同一时刻的瞬时值）"""
    raw = subprocess.run(
        ["ioreg", "-r", "-c", "IOAccelerator", "-w", "0"],
        capture_output=True, check=False,
    ).stdout.decode("utf-8", "replace")
    m = re.search(r'"Device Utilization %"=(\d+)', raw)
    return int(m.group(1)) if m else -1


def main():
    interval = float(sys.argv[1])
    rounds = int(sys.argv[2])
    prev = sample()
    for i in range(rounds):
        dev_before = device_util()
        time.sleep(interval)
        dev_after = device_util()
        cur = sample()

        rows = []
        for pid, (name, total, n) in cur.items():
            if pid not in prev:
                continue
            delta = total - prev[pid][1]
            if delta > 0:
                rows.append((delta, pid, name, n))
        rows.sort(reverse=True)

        print(f"===== 窗口 {interval:.1f}s #{i + 1}  "
              f"设备 Device Util: {dev_before}% → {dev_after}% =====")
        print(f"{'pid':>8} {'进程名':<24} {'ΔGPUTime(ns)':>15} {'GPU ms/s':>10} {'客户端':>6}")
        for delta, pid, name, n in rows:
            print(f"{pid:>8} {name[:24]:<24} {delta:>15} {delta / 1e6 / interval:>10.1f} {n:>6}")
        total = sum(r[0] for r in rows)
        print(f"-- 全部 GPU 客户端合计: {total / 1e6 / interval:.1f} ms/s "
              f"(双向累加折合 {total / 1e9 / interval * 100:.1f}%)\n")
        prev = cur


main()
PY
