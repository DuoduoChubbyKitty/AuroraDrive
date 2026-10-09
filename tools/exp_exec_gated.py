#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_exec_gated.py — 负载门控测量（S2 · 2026-10-09）

================================================================================
为什么需要这个
================================================================================
本机是 M3 MacBook Air（**无风扇**），且**同时有其他 agent 在跑重活**。
实测：同一个配置（`.all` / m9_v2.mlmodelc）
    07:29 load≈5   → p50 14.41 ms
    07:53 load≈34  → p50 53.17 ms
**同一份产物、同一个配置，差 3.7×** —— 全部来自机器争用。

⟹ 在高负载下测出的绝对值**毫无意义**，绝不能写进报告当结论。

本脚本的纪律：
  1. **门控**：每轮测量前检查 1 分钟平均负载，只有 < --max-load 才开测；
     否则等待（可配 --wait-sec 超时）。
  2. **ABBA**：正向一轮 + 反向一轮，抵消残余漂移。
  3. **记录**：每轮记 uptime / loadavg_before / loadavg_after，全部落盘。
  4. **诚实**：拿不到安静窗口就**如实报告"未取得可信绝对值"**，不给假数。

用法：
    ./.venv-yolo26/bin/python3 tools/exp_exec_gated.py --suite units \
        --max-load 3.0 --wait-sec 900 --reps 3
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
BENCH = _ROOT / "models" / "exp_exec_tmp" / "exp_exec_bench"
OUTDIR = _ROOT / "models" / "exp_exec_results"
BASE_MODEL = "models/m9_v2.mlmodelc"


def loadavg():
    return os.getloadavg()[0]


def wait_for_quiet(max_load, wait_sec, label=""):
    """等到 1 分钟平均负载 < max_load。返回 (ok, waited_s, samples)。"""
    t0 = time.time()
    samples = []
    while time.time() - t0 < wait_sec:
        la = loadavg()
        samples.append(round(la, 2))
        if la < max_load:
            return True, time.time() - t0, samples
        time.sleep(5)
    return False, time.time() - t0, samples


def run_once(model, units, strategy="default", lowprec=False, reshape="frequent",
             iters=30, warmup=5, label="", timeout=600):
    cmd = [str(BENCH), "--model", str(_ROOT / model), "--units", units,
           "--strategy", strategy, "--reshape", reshape,
           "--lowprec-accum", "1" if lowprec else "0",
           "--rounds", "1", "--iters", str(iters), "--warmup", str(warmup),
           "--plan", "0", "--label", label]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"label": label, "error": "timeout"}
    res = None
    for line in p.stdout.splitlines():
        if line.startswith("RESULT_JSON "):
            res = json.loads(line[len("RESULT_JSON "):])
    if res is None:
        return {"label": label, "error": f"no_result rc={p.returncode}",
                "stderr": p.stderr[-300:]}
    res["ane_fail"] = "MILCompilerForANE" in p.stderr or "MILCompilerForANE" in p.stdout
    return res


def build_suite(kind):
    if kind == "units":
        return {u: dict(model=BASE_MODEL, units=u) for u in
                ["cpuAndGPU", "cpuOnly", "all", "cpuAndNE"]}
    if kind == "config":
        s = {}
        for u in ["cpuAndGPU", "cpuOnly", "all"]:
            s[f"{u}/default"] = dict(model=BASE_MODEL, units=u)
            s[f"{u}/fastPred"] = dict(model=BASE_MODEL, units=u, strategy="fastPrediction")
            s[f"{u}/fastPred+lowprec"] = dict(model=BASE_MODEL, units=u,
                                              strategy="fastPrediction", lowprec=True)
            s[f"{u}/reshapeInfreq"] = dict(model=BASE_MODEL, units=u, reshape="infrequent")
        return s
    if kind == "variants":
        s = {}
        for p in sorted((_ROOT / "models").glob("exp_exec_t_*.mlmodelc")):
            n = p.name[len("exp_exec_"):-len(".mlmodelc")]
            s[f"{n}/gpu"] = dict(model=str(p.relative_to(_ROOT)), units="cpuAndGPU")
            s[f"{n}/cpu"] = dict(model=str(p.relative_to(_ROOT)), units="cpuOnly")
        return s
    raise SystemExit(f"未知 suite：{kind}")


def pctl(s, p):
    s = sorted(s)
    return s[min(len(s) - 1, int(len(s) * p))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", required=True, choices=["units", "config", "variants"])
    ap.add_argument("--iters", type=int, default=30)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--max-load", type=float, default=3.0)
    ap.add_argument("--wait-sec", type=float, default=900)
    ap.add_argument("--tag", default="")
    args = ap.parse_args()

    OUTDIR.mkdir(parents=True, exist_ok=True)
    suite = build_suite(args.suite)
    log_path = OUTDIR / f"gated-{args.tag or args.suite}-{time.strftime('%H%M%S')}.log"
    fh = log_path.open("w", encoding="utf-8")

    def emit(s):
        print(s)
        fh.write(s + "\n")
        fh.flush()

    emit(f"═══ 负载门控测量 suite={args.suite} 配置数={len(suite)} reps={args.reps} "
         f"iters={args.iters} max_load={args.max_load} ═══")
    emit(f"    开始 {time.strftime('%Y-%m-%d %H:%M:%S')} loadavg={loadavg():.2f} "
         f"uptime={int(time.time())}")

    results = {k: [] for k in suite}
    skipped = {k: 0 for k in suite}

    for rep in range(args.reps):
        order = list(suite.keys()) if rep % 2 == 0 else list(suite.keys())[::-1]
        emit(f"\n--- rep {rep+1}/{args.reps} {'正向' if rep%2==0 else '反向'} ---")
        for name in order:
            ok, waited, samples = wait_for_quiet(args.max_load, args.wait_sec, name)
            if not ok:
                emit(f"  {name:<26} ⏭ 等待 {waited:.0f}s 未取得安静窗口"
                     f"（loadavg 仍 {samples[-1] if samples else '?'}）→ 跳过")
                skipped[name] += 1
                continue
            la0 = loadavg()
            r = run_once(**suite[name], iters=args.iters, warmup=args.warmup, label=name)
            la1 = loadavg()
            r["loadavg_before"] = la0
            r["loadavg_after"] = la1
            r["waited_s"] = waited
            r["uptime"] = int(time.time())
            results[name].append(r)
            if "samples" in r:
                emit(f"  {name:<26} p50={r['p50']:7.2f} p95={r['p95']:7.2f} "
                     f"max={r['max']:7.2f} load {la0:.2f}→{la1:.2f} "
                     f"(等{waited:.0f}s) ane_fail={r['ane_fail']}")
            else:
                emit(f"  {name:<26} FAILED {r.get('error')}")

    emit(f"\n═══ 汇总 ═══")
    emit(f"{'配置':<26} {'p50':>8} {'p95':>8} {'max':>8} {'轮':>3} {'样本':>5} "
         f"{'ANE失败':>7} {'load均值':>9}")
    summary = {}
    for name, runs in results.items():
        ok = [r for r in runs if "samples" in r]
        if not ok:
            summary[name] = {"n_runs": 0, "skipped": skipped[name]}
            emit(f"{name:<26} 无可信数据（跳过 {skipped[name]} 次）")
            continue
        s = [x for r in ok for x in r["samples"]]
        s = sorted(s)
        las = [r["loadavg_before"] for r in ok]
        summary[name] = {
            "n_runs": len(ok), "n_samples": len(s),
            "p50": pctl(s, .50), "p90": pctl(s, .90), "p95": pctl(s, .95),
            "p99": pctl(s, .99), "max": max(s), "mean": statistics.fmean(s),
            "min": min(s), "stdev": statistics.pstdev(s) if len(s) > 1 else 0.0,
            "ane_compile_fail": any(r["ane_fail"] for r in ok),
            "loadavg_mean": statistics.fmean(las), "loadavg_max": max(las),
            "uptimes": [r["uptime"] for r in ok],
            "skipped": skipped[name],
        }
        emit(f"{name:<26} {summary[name]['p50']:8.2f} {summary[name]['p95']:8.2f} "
             f"{summary[name]['max']:8.2f} {len(ok):3d} {len(s):5d} "
             f"{str(summary[name]['ane_compile_fail']):>7} "
             f"{summary[name]['loadavg_mean']:9.2f}")

    out = OUTDIR / f"gated-{args.tag or args.suite}-{time.strftime('%H%M%S')}.json"
    out.write_text(json.dumps({
        "suite": args.suite, "args": vars(args), "summary": summary,
        "raw": {k: [{kk: vv for kk, vv in r.items() if kk != "samples"} for r in v]
                for k, v in results.items()},
        "samples": {k: [x for r in v if "samples" in r for x in r["samples"]]
                    for k, v in results.items()},
        "log": str(log_path),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    emit(f"\n结果 → {out}")
    fh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
