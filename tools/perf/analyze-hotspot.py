#!/usr/bin/env python3
"""分析 hotspot-recorder 的产物：把 JSONL + sample 调用栈汇总成人可读报告。

【用法】
  python3 tools/perf/analyze-hotspot.py                       # 自动找最新 jsonl
  python3 tools/perf/analyze-hotspot.py <jsonl 路径>
  python3 tools/perf/analyze-hotspot.py <jsonl> --samples     # 额外解析抓到的调用栈

【输出什么】
  1. 时间线概览：load / GPU / 内存 / Aurora CPU 的分位数
  2. 「卡顿窗口」：Aurora CPU 高 或 load 接近核数 的时段（分段列出，便于对时间点）
  3. 热点调用栈 Top-N：从 sample_*.txt 里按样本数排序，剥离系统噪音
  4. 记录器自身开销（证明数据没被采样器污染）
"""
import glob
import json
import os
import re
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")

# sample 输出里每帧形如 "   + 1234 symbol  (in image) + 12  [0xaddr]"
_FRAME_RE = re.compile(r"^\s*[+!:| ]*(\d+)\s+(\S.*?)\s+\(in\s+([^)]+)\)")
# 纯等待/空闲相关的符号：卡顿分析里应当剔除，否则永远只看得到 mach_msg
_IDLE_HINTS = ("mach_msg", "semaphore_wait", "thread_start", "start_wqthread",
               "_pthread_wqthread", "__psynch", "kevent", "select", "poll",
               "received_events", "nanosleep", "sleep", "wait4", "read\u0000",
               "__ulock_wait", "parking", "CFRunLoopRun", "RunLoop")


def find_latest_jsonl():
    files = sorted(glob.glob(os.path.join(RAW, "hotspot_*.jsonl")),
                   key=os.path.getmtime, reverse=True)
    return files[0] if files else None


def load_jsonl(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    idx = min(len(s) - 1, int(len(s) * p))
    return s[idx]


def summarize(rows):
    print("=" * 78)
    print("① 时间线概览")
    print("=" * 78)
    span = rows[-1]["t"] - rows[0]["t"] if len(rows) > 1 else 0
    print(f"  记录 {len(rows)} 条，覆盖 {span/60:.1f} 分钟"
          f"（{rows[0]['ts']} → {rows[-1]['ts']}）")

    load = [r["load1"] for r in rows if r.get("load1") is not None]
    ncore = rows[0].get("core") or 8
    if load:
        print(f"  load1     : p50={st.median(load):.2f} p95={pct(load,.95):.2f} "
              f"max={max(load):.2f}   （核数 {ncore}，>%d 表示 CPU 跑满）" % ncore)

    gpu = [r["gpu"] for r in rows if r.get("gpu") and r["gpu"].get("dev") is not None]
    if gpu:
        dev = [g["dev"] for g in gpu]
        ren = [g["render"] for g in gpu if g.get("render") is not None]
        print(f"  GPU device: p50={st.median(dev):.0f}% p95={pct(dev,.95):.0f}% max={max(dev)}%")
        if ren:
            print(f"  GPU render: p50={st.median(ren):.0f}% p95={pct(ren,.95):.0f}% max={max(ren)}%")

    mem = [r["mem_free_pct"] for r in rows if r.get("mem_free_pct") is not None]
    if mem:
        print(f"  内存空闲  : p50={st.median(mem):.0f}% min={min(mem):.0f}%")

    thr = [r["thermal"] for r in rows if r.get("thermal")]
    if thr:
        n_thr = sum(1 for t in thr if t.get("throttled"))
        print(f"  热节流    : {n_thr}/{len(thr)} 个样本处于降频"
              f"{'  ⚠️ 降频会直接掉帧' if n_thr else '（未降频）'}")

    aur = [r["aurora_cpu_sum"] for r in rows if r.get("aurora_cpu_sum") is not None]
    if aur:
        active = [a for a in aur if a > 5]
        print(f"  Aurora CPU: p50={st.median(aur):.1f}% max={max(aur):.1f}%  "
              f"有负载样本 {len(active)}/{len(aur)} 条")
        if active:
            print(f"              有负载时 p50={st.median(active):.1f}% "
                  f"p95={pct(active,.95):.1f}% max={max(active):.1f}%")

    rec = [r["recorder"] for r in rows if r.get("recorder")]
    if rec:
        self_cpu = [x["self_cpu"] for x in rec if x.get("self_cpu") is not None]
        loop = [x["loop_ms"] for x in rec if x.get("loop_ms") is not None]
        print()
        print(f"  记录器自身: CPU p50={st.median(self_cpu):.2f}% max={max(self_cpu):.2f}%  "
              f"每轮 {st.median(loop):.0f}ms  （低 = 未污染被测对象）" if self_cpu and loop
              else "  记录器自身: 无数据")


def stutter_windows(rows, min_aurora=10.0):
    """找出「Aurora 在算」的连续时段，输出起止时间与峰值。"""
    print()
    print("=" * 78)
    print("② 有负载窗口（Aurora CPU > %.0f%% 的连续时段）" % min_aurora)
    print("=" * 78)
    windows, cur = [], None
    for r in rows:
        busy = r.get("aurora_cpu_sum", 0) >= min_aurora
        if busy:
            if cur is None:
                cur = {"start": r["ts"], "t0": r["t"], "peak": r["aurora_cpu_sum"],
                       "n": 1, "gpu_peak": (r.get("gpu") or {}).get("dev")}
            else:
                cur["n"] += 1
                cur["peak"] = max(cur["peak"], r["aurora_cpu_sum"])
                g = (r.get("gpu") or {}).get("dev")
                if g is not None:
                    cur["gpu_peak"] = max(cur["gpu_peak"] or 0, g)
        elif cur is not None:
            cur["end"] = r["ts"]
            windows.append(cur)
            cur = None
    if cur is not None:
        cur["end"] = rows[-1]["ts"]
        windows.append(cur)

    if not windows:
        print("  ⚠️ 全程没有 Aurora 负载样本 —— 本次记录期间流水线没跑起来。")
        print("     要抓卡顿，必须在「辅助开着 + 游戏在跑 + 处于驾驶状态」时记录。")
        return

    print(f"  共 {len(windows)} 个窗口：")
    for w in windows[:20]:
        dur = w["n"] * (rows[1]["t"] - rows[0]["t"] if len(rows) > 1 else 2)
        print(f"    {w['start']} → {w['end']}  约 {dur:.0f}s  "
              f"Aurora峰值 {w['peak']:.0f}%  GPU峰值 {w['gpu_peak']}%")
    if len(windows) > 20:
        print(f"    …其余 {len(windows)-20} 个略")


def parse_samples(rows):
    print()
    print("=" * 78)
    print("③ 抓到的调用栈热点（按样本数排序，已剔除纯等待帧）")
    print("=" * 78)
    files = [r["sample"] for r in rows if r.get("sample")]
    if not files:
        print("  本次没有抓到调用栈（Aurora 负载未超过阈值，或已到次数上限）。")
        dangling = sorted(glob.glob(os.path.join(RAW, "sample_*.txt")),
                          key=os.path.getmtime, reverse=True)
        if dangling:
            print(f"  但 raw/ 下有 {len(dangling)} 个历史 sample 文件，可用 --samples 一并分析。")
        return

    for path in files:
        if not os.path.exists(path):
            print(f"  ⚠️ 文件不存在: {path}")
            continue
        print()
        print(f"  ── {os.path.basename(path)} ──")
        counts = {}
        total_line = None
        with open(path, errors="replace") as f:
            for line in f:
                if total_line is None and "Total number in stack" in line:
                    total_line = line.strip()
                m = _FRAME_RE.match(line)
                if not m:
                    continue
                n, sym, img = int(m.group(1)), m.group(2).strip(), m.group(3)
                low = sym.lower()
                if any(h.lower() in low for h in _IDLE_HINTS):
                    continue
                key = (sym, img)
                counts[key] = max(counts.get(key, 0), n)
        if not counts:
            print("    无可解析帧（可能进程几乎全空闲）")
            continue
        top = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:15]
        peak = top[0][1]
        for (sym, img), n in top:
            bar = "█" * max(1, int(20 * n / peak))
            print(f"    {n:6d}  {bar:<20} {sym[:66]}  [{img}]")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_samples = "--samples" in sys.argv
    path = args[0] if args else find_latest_jsonl()
    if not path or not os.path.exists(path):
        print("找不到 jsonl 文件。先跑：python3 tools/perf/hotspot-recorder.py <秒数>")
        return 1
    print(f"分析文件: {path}")
    rows = load_jsonl(path)
    if not rows:
        print("文件为空。")
        return 1
    summarize(rows)
    stutter_windows(rows)
    if want_samples:
        parse_samples(rows)
    else:
        print()
        print("（加 --samples 可解析抓到的调用栈）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
