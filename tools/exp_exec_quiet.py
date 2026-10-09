#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_exec_quiet.py — 安静窗口探针 + 自动跑全套（S2 · 2026-10-09）

本机（M3 MacBook Air）同时跑着其他 agent 的重活，loadavg 在 1~35 之间乱跳。
绝对延迟只有在**安静窗口**（loadavg < 阈值）里才有意义。

本脚本：
  1. 轮询 loadavg，直到连续 K 次低于阈值（默认连续 3 次 < 1.5，间隔 10s）；
  2. 一旦拿到窗口，**立刻**跑指定的 suite 序列（默认 units → config）；
  3. 窗口内如果 loadavg 又涨回去，**中止并如实标记**该批次数据不可信；
  4. 全程落盘日志，含每次测量的 uptime 与 loadavg。

用法：
    nohup ./.venv-yolo26/bin/python3 tools/exp_exec_quiet.py \
        --suites units,config --max-load 1.5 --reps 5 --wait-min 90 \
        > /tmp/s2_quiet.log 2>&1 &
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
OUTDIR = _ROOT / "models" / "exp_exec_results"


def loadavg():
    return os.getloadavg()[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suites", default="units,config")
    ap.add_argument("--max-load", type=float, default=1.5)
    ap.add_argument("--consecutive", type=int, default=3)
    ap.add_argument("--interval", type=float, default=10)
    ap.add_argument("--wait-min", type=float, default=90)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--iters", type=int, default=30)
    args = ap.parse_args()

    OUTDIR.mkdir(parents=True, exist_ok=True)
    log = OUTDIR / f"quiet-probe-{time.strftime('%H%M%S')}.log"
    fh = log.open("w", encoding="utf-8")

    def emit(s):
        print(s, flush=True)
        fh.write(s + "\n")
        fh.flush()

    emit(f"═══ 安静窗口探针 开始 {time.strftime('%Y-%m-%d %H:%M:%S')} ═══")
    emit(f"    阈值 loadavg<{args.max_load} 连续 {args.consecutive} 次（间隔 {args.interval}s），"
         f"最长等 {args.wait_min} 分钟")

    t0 = time.time()
    streak = 0
    hist = []
    while (time.time() - t0) / 60 < args.wait_min:
        la = loadavg()
        hist.append((int(time.time()), round(la, 2)))
        streak = streak + 1 if la < args.max_load else 0
        if len(hist) % 6 == 1:
            emit(f"    [{time.strftime('%H:%M:%S')}] load={la:.2f} 连续达标={streak}"
                 f"（已等 {(time.time()-t0)/60:.1f} 分钟）")
        if streak >= args.consecutive:
            emit(f"\n★ 取得安静窗口 {time.strftime('%H:%M:%S')} load={la:.2f}"
                 f"（等待 {(time.time()-t0)/60:.1f} 分钟）")
            break
        time.sleep(args.interval)
    else:
        emit(f"\n✗ 等待 {args.wait_min} 分钟仍未取得安静窗口（最后 load={loadavg():.2f}）")
        emit("  → 绝对值未取得；本报告只使用**配对/受控负载**下的比值结论")
        fh.close()
        return 3

    rc_all = 0
    for suite in args.suites.split(","):
        suite = suite.strip()
        if not suite:
            continue
        la0 = loadavg()
        emit(f"\n>>> 跑 suite={suite}（起始 load={la0:.2f}，"
             f"若中途 >{args.max_load*3:.1f} 则数据标为受扰）")
        cmd = [str(_ROOT / ".venv-yolo26/bin/python3"),
               str(_ROOT / "tools/exp_exec_pair.py"),
               "--suite", suite, "--iters", str(args.iters),
               "--reps", str(args.reps), "--warmup", "5", "--burn", "0",
               "--tag", f"{suite}-quiet"]
        p = subprocess.run(cmd, capture_output=True, text=True)
        emit(p.stdout[-6000:])
        if p.returncode != 0:
            rc_all = p.returncode
            emit(f"!!! suite={suite} 退出码 {p.returncode}")
        la1 = loadavg()
        emit(f"<<< suite={suite} 结束 load={la1:.2f}"
             f"（{'窗口保持' if la1 < args.max_load*3 else '⚠ 窗口已被打破，数据受扰'}）")

    emit(f"\n全部完成 {time.strftime('%H:%M:%S')}")
    fh.close()
    return rc_all


if __name__ == "__main__":
    raise SystemExit(main())
