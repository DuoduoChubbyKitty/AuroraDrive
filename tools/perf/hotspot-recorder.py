#!/usr/bin/env python3
"""后台热点记录器 —— 玩游戏时独立采样并自动抓调用栈，事后分析。

【为什么需要】人玩游戏时机器已经很卡，若由 AI 在前台跑采样/分析，只会更卡、
而且会污染被测对象。本程序常驻后台、开销 <0.02%，用户打完游戏后直接分析文件，
不需要任何人在场。

【它解决什么答不了的问题】
  静态分析只能猜。真正要回答的是「卡的那一秒，我们到底在算什么」。
  所以本程序在 Aurora CPU 超过阈值时**自动调用系统 `sample`** 抓调用栈落盘，
  这就是热点证据，不需要 AURORA_PERF、不需要重启 App、不需要复现操作。

【采什么】
  · 全系统每进程 CPU（libproc，无需 root）
  · GPU 利用率（ioreg IOAccelerator：Device/Renderer/Tiler）
  · load1 / 可用内存 / **热节流状态**（pmset -g therm：CPU_Speed_Limit<100 = 正在降频）
  · Aurora 进程单列，区分 UI / 引擎
  · 自动 sample：Aurora 超阈值时抓 1 秒调用栈 → tools/perf/raw/sample_*.txt
  · 记录器自身开销（证明它不是新的卡顿源）

【为什么输出到工作区内】DSH 文件沙箱是 workspace-write，写 ~/Library/Logs 会被拒
（实测 PermissionError）。默认落 `tools/perf/raw/`，可用 --out 覆盖。

【用法】
  python3 tools/perf/hotspot-recorder.py                    # 30 分钟
  python3 tools/perf/hotspot-recorder.py 7200 --interval 2  # 2 小时
  nohup python3 tools/perf/hotspot-recorder.py 7200 >/tmp/hotspot.log 2>&1 &

  验证 sample 管道是否通（不依赖 Aurora 有负载）：
  python3 tools/perf/hotspot-recorder.py --sample-once <pid>
"""
import argparse
import ctypes
import ctypes.util
import json
import os
import re
import signal
import struct
import subprocess
import sys
import time

libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
PROC_ALL_PIDS = 1
PROC_PIDTBSDINFO = 3
PROC_PIDTASKINFO = 4

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RAW_DIR = os.path.join(ROOT, "tools", "perf", "raw")

_running = True


def _stop(_sig, _frm):
    global _running
    _running = False


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


def all_pids():
    buf = ctypes.create_string_buffer(4096 * 8)
    n = libproc.proc_listallpids(buf, ctypes.c_int(len(buf)))
    if n <= 0:
        return []
    return list(struct.unpack_from("<%di" % n, buf.raw, 0))


def proc_name(pid):
    buf = ctypes.create_string_buffer(256)
    n = libproc.proc_name(ctypes.c_int(pid), buf, ctypes.c_uint32(256))
    return buf.value.decode("utf-8", "replace") if n > 0 else "?"


def proc_ppid(pid):
    """父进程 pid；读不到返回 -1。proc_bsdinfo 里 pbi_ppid 在偏移 16。"""
    buf = ctypes.create_string_buffer(256)
    n = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDTBSDINFO),
                             ctypes.c_uint64(0), buf, ctypes.c_int(256))
    if n <= 0:
        return -1
    return struct.unpack_from("<i", buf.raw, 16)[0]


def taskinfo(pid):
    """(总CPU纳秒, user, sys, 常驻字节)；读不到返回 None（进程已退出）。"""
    buf = ctypes.create_string_buffer(256)
    n = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDTASKINFO),
                             ctypes.c_uint64(0), buf, ctypes.c_int(256))
    if n <= 0:
        return None
    virt, res, user, system = struct.unpack_from("<4Q", buf.raw, 0)
    return (user + system, user, system, res)


_GPU_PATTERNS = (
    re.compile(rb'"Device Utilization %"=(\d+).*?"Renderer Utilization %"=(\d+)'
               rb'.*?"Tiler Utilization %"=(\d+)'),
    re.compile(rb'"Tiler Utilization %"=(\d+).*?"Renderer Utilization %"=(\d+)'
               rb'.*?"Device Utilization %"=(\d+)'),
)


def gpu_util():
    """GPU (device, renderer, tiler) 百分比；读不到返回 (None, None, None)。"""
    try:
        out = subprocess.run(["/usr/sbin/ioreg", "-r", "-d", "1", "-c", "IOAccelerator"],
                             capture_output=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return (None, None, None)
    m = _GPU_PATTERNS[0].search(out)
    if m:
        return tuple(int(x) for x in m.groups())
    m = _GPU_PATTERNS[1].search(out)
    if m:
        t, r, d = (int(x) for x in m.groups())
        return (d, r, t)
    return (None, None, None)


_MEM_RE = re.compile(r"free percentage:\s*([\d.]+)%")


def mem_free_pct():
    try:
        out = subprocess.run(["/usr/bin/memory_pressure", "-Q"],
                             capture_output=True, timeout=5).stdout.decode(errors="replace")
        m = _MEM_RE.search(out)
        return float(m.group(1)) if m else None
    except (OSError, subprocess.SubprocessError):
        return None


_THERM_RE = re.compile(r"(CPU_Scheduler_Limit|CPU_Available_CPUs|CPU_Speed_Limit)\s*=\s*(\d+)")


def thermal_state():
    """热节流：CPU_Speed_Limit<100 表示正在降频（会直接掉帧）。读不到返回 None。"""
    try:
        out = subprocess.run(["/usr/bin/pmset", "-g", "therm"],
                             capture_output=True, timeout=5).stdout.decode(errors="replace")
    except (OSError, subprocess.SubprocessError):
        return None
    found = dict(_THERM_RE.findall(out))
    if not found:
        return {"throttled": False, "raw": "no thermal record"}
    limit = int(found.get("CPU_Speed_Limit", 100))
    return {"throttled": limit < 100,
            "speed_limit": limit,
            "sched_limit": int(found.get("CPU_Scheduler_Limit", 100)),
            "cpus": int(found.get("CPU_Available_CPUs", 0)) or None}


def take_sample(pid, seconds, tag):
    """抓 pid 的调用栈到 raw/sample_<ts>_<tag>.txt，返回路径（失败返回 None）。"""
    os.makedirs(RAW_DIR, exist_ok=True)
    path = os.path.join(RAW_DIR, "sample_%s_%s.txt" % (time.strftime("%Y%m%d_%H%M%S"), tag))
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-f", path],
                       capture_output=True, timeout=seconds + 10)
    except (OSError, subprocess.SubprocessError):
        return None
    return path if os.path.exists(path) and os.path.getsize(path) > 0 else None


def label_aurora(rows_all, pid_names):
    """把 Aurora 进程标成 UI / 引擎。引擎是 UI 的子进程（ppid 指向另一个 Aurora）。"""
    aurora_pids = [p for p, n in pid_names.items() if "AuroraDrive" in n]
    ppid = {p: proc_ppid(p) for p in aurora_pids}
    out = []
    for r in rows_all:
        p = r["pid"]
        if p not in aurora_pids:
            continue
        role = "UI" if ppid.get(p) not in aurora_pids else "engine"
        out.append({**r, "role": role, "ppid": ppid.get(p, -1)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("duration", nargs="?", type=float, default=1800.0,
                    help="总时长（秒），默认 1800")
    ap.add_argument("--interval", type=float, default=2.0, help="采样间隔秒，默认 2")
    ap.add_argument("--out", default=None, help="输出 jsonl 路径")
    ap.add_argument("--gpu-every", type=int, default=1,
                    help="每 N 次采样读一次 GPU（ioreg 较慢），默认 1")
    ap.add_argument("--no-auto-sample", dest="auto_sample", action="store_false",
                    help="关闭自动抓调用栈")
    ap.add_argument("--sample-threshold", type=float, default=15.0,
                    help="Aurora 合计 CPU%% 超过此值才抓栈，默认 15")
    ap.add_argument("--sample-every", type=float, default=90.0,
                    help="两次抓栈最小间隔秒，默认 90（抓栈本身有开销，别太密）")
    ap.add_argument("--sample-max", type=int, default=8,
                    help="整轮最多抓几次栈，默认 8（防止把磁盘塞满）")
    ap.add_argument("--sample-sec", type=int, default=1, help="每次抓栈时长秒，默认 1")
    ap.add_argument("--sample-once", type=int, default=None, metavar="PID",
                    help="只对指定 pid 抓一次栈然后退出（用于验证管道是否通）")
    ap.set_defaults(auto_sample=True)
    args = ap.parse_args()

    if args.sample_once is not None:
        p = take_sample(args.sample_once, args.sample_sec, "once")
        if p:
            print("✓ 抓栈成功 → %s（%d 字节）" % (p, os.path.getsize(p)))
            return 0
        print("✗ 抓栈失败（pid 不存在 / 权限不足 / sample 不可用）")
        return 1

    out_path = args.out or os.path.join(
        RAW_DIR, "hotspot_%s.jsonl" % time.strftime("%Y%m%d_%H%M%S"))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    ncpu = int(subprocess.check_output(["sysctl", "-n", "hw.ncpu"]).strip())
    me = os.getpid()
    f = open(out_path, "w", buffering=1)
    print("记录中 → %s" % out_path)
    print("  间隔 %.1fs · 上限 %.0f 分钟 · 核数 %d · 自身 pid %d" % (
        args.interval, args.duration / 60.0, ncpu, me))
    print("  自动抓栈: %s（阈值 %.0f%% · 间隔 ≥%.0fs · 最多 %d 次 · 每次 %ds）" % (
        "开" if args.auto_sample else "关", args.sample_threshold,
        args.sample_every, args.sample_max, args.sample_sec), flush=True)

    start = time.time()
    prev, prev_me = {}, None
    n = 0
    gpu = mem = therm = None
    samples = []
    last_sample_at = -1e9

    while _running and (time.time() - start) < args.duration:
        tick = time.time()
        names, cur = {}, {}
        for p in all_pids():
            ti = taskinfo(p)
            if ti:
                cur[p] = ti
                names[p] = proc_name(p)

        if prev:
            rows = []
            aurora_cpu = {}
            for p, ti in cur.items():
                old = prev.get(p)
                if not old:
                    continue
                dcpu = (ti[0] - old[0]) / 1e9 / args.interval * 100.0
                nm = names.get(p, "?")
                if "AuroraDrive" in nm:
                    aurora_cpu[p] = (dcpu, nm, ti[3])
                if dcpu >= 0.5:
                    rows.append({"pid": p, "name": nm, "cpu": round(dcpu, 1),
                                 "rss_mb": round(ti[3] / 1048576.0, 1)})
            rows.sort(key=lambda r: r["cpu"], reverse=True)
            aurora = label_aurora(rows, names)

            my_ti = cur.get(me)
            self_cpu = None
            if my_ti and prev_me is not None:
                self_cpu = round((my_ti[0] - prev_me) / 1e9 / args.interval * 100.0, 2)
            prev_me = my_ti[0] if my_ti else None

            if n % max(1, args.gpu_every) == 0:
                gpu = gpu_util()
                mem = mem_free_pct()
                therm = thermal_state()

            # ── 自动抓栈：只在 Aurora 真的在算、且没超过频率/次数上限时做 ──
            sample_path = None
            a_sum = sum(v[0] for v in aurora_cpu.values())
            if (args.auto_sample
                    and a_sum >= args.sample_threshold
                    and len(samples) < args.sample_max
                    and (time.time() - last_sample_at) >= args.sample_every):
                # 抓最忙的那个 Aurora 进程（引擎通常比 UI 重）
                victim = max(aurora_cpu.items(), key=lambda kv: kv[1][0])
                pid, (cpu, nm, _rss) = victim
                role = "engine" if len([q for q in aurora_cpu if proc_ppid(q) in aurora_cpu]) else "UI"
                sample_path = take_sample(pid, args.sample_sec,
                                          "%s_pid%d_cpu%.0f" % (role, pid, cpu))
                last_sample_at = time.time()
                if sample_path:
                    samples.append({"ts": time.strftime("%H:%M:%S"),
                                    "pid": pid, "role": role,
                                    "cpu": round(cpu, 1), "file": sample_path})

            rec = {
                "ts": time.strftime("%H:%M:%S"),
                "t": round(time.time() - start, 1),
                "load1": round(os.getloadavg()[0], 2),
                "core": ncpu,
                "gpu": {"dev": gpu[0], "render": gpu[1], "tiler": gpu[2]} if gpu else None,
                "mem_free_pct": mem,
                "thermal": therm,
                "aurora_cpu_sum": round(a_sum, 1),
                "aurora": aurora,
                "top": rows[:10],
                "sample": sample_path,
                "recorder": {"self_cpu": self_cpu,
                             "loop_ms": round((time.time() - tick) * 1000.0, 1)},
            }
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n += 1

        prev = cur
        if prev_me is None:
            _mt = cur.get(me)
            prev_me = _mt[0] if _mt else None
        time.sleep(max(0.2, args.interval - (time.time() - tick)))

    f.close()
    print("已停止 → %s（%d 条记录，%d 次抓栈）" % (out_path, n, len(samples)), flush=True)
    for s in samples:
        print("  抓栈 %s pid=%d %s cpu=%.1f%% → %s"
              % (s["ts"], s["pid"], s["role"], s["cpu"], s["file"]), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
