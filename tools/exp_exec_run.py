#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_exec_run.py — S2 测量调度器（ABBA 交替 + 负载记录）

驱动 `models/exp_exec_tmp/exp_exec_bench`（Swift 原生 CoreML 计时），
按 **ABBA 交替顺序** 跑完所有配置，抵消本机负载漂移。

为什么顺序要 ABBA：
    本机是 M3 MacBook Air（无风扇）且**同时有其他 agent 在跑**，负载会漂移。
    若按 A,B,C,D 顺序各测 5 轮，后测的配置会系统性地受"机器越来越热/越来越忙"
    影响。ABBA（正向一轮 + 反向一轮）让每个配置在时间轴上的位置对称，
    系统性漂移被抵消到一阶。

用法：
    ./.venv-yolo26/bin/python3 tools/exp_exec_run.py --suite units
    ./.venv-yolo26/bin/python3 tools/exp_exec_run.py --suite variants
    ./.venv-yolo26/bin/python3 tools/exp_exec_run.py --suite config
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

# 基准模型（与 Lead 实测口径一致）
BASE_MODEL = "models/m9_v2.mlmodelc"


def run_once(model, units, strategy="default", lowprec=False, reshape="frequent",
             rounds=1, iters=30, warmup=5, plan=True, label="", timeout=300):
    """跑一次 Swift 基准，返回解析后的 dict（含 samples）。"""
    cmd = [str(BENCH), "--model", str(_ROOT / model), "--units", units,
           "--strategy", strategy, "--reshape", reshape,
           "--lowprec-accum", "1" if lowprec else "0",
           "--rounds", str(rounds), "--iters", str(iters), "--warmup", str(warmup),
           "--plan", "1" if plan else "0", "--label", label]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"label": label, "error": "timeout", "model": model, "units": units}
    wall = time.time() - t0
    res = None
    stderr = p.stderr
    for line in p.stdout.splitlines():
        if line.startswith("RESULT_JSON "):
            res = json.loads(line[len("RESULT_JSON "):])
    if res is None:
        return {"label": label, "error": f"no_result rc={p.returncode}",
                "stderr": stderr[-400:], "model": model, "units": units}
    res["wall_s"] = wall
    res["stderr_ane_fail"] = ("MILCompilerForANE" in stderr) or ("MILCompilerForANE" in p.stdout)
    res["stderr_tail"] = stderr[-500:]
    res["stdout_head"] = p.stdout[:0]
    res["rc"] = p.returncode
    return res


def pct(samples, p):
    s = sorted(samples)
    return s[min(len(s) - 1, int(len(s) * p))]


def summarize(runs):
    """把同一配置的多次 run 合并统计。"""
    ok = [r for r in runs if "samples" in r]
    if not ok:
        return {"error": runs[0].get("error", "all_failed"), "n_runs": 0}
    samples = [x for r in ok for x in r["samples"]]
    loads = [rs.get("loadavg_before", 0) for r in ok for rs in r.get("round_stats", [])]
    return {
        "n_runs": len(ok),
        "n_samples": len(samples),
        "p50": pct(samples, 0.50),
        "p90": pct(samples, 0.90),
        "p95": pct(samples, 0.95),
        "p99": pct(samples, 0.99),
        "max": max(samples),
        "mean": statistics.fmean(samples),
        "min": min(samples),
        "stdev": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
        "ane_compile_fail": any(r.get("stderr_ane_fail") for r in ok),
        "plan_device_counts": ok[0].get("plan_device_counts", {}),
        "plan_cost_pct": None,
        "loadavg_max": max(loads) if loads else None,
        "loadavg_mean": statistics.fmean(loads) if loads else None,
        "first_out": ok[0].get("first_out", ""),
    }


def abba(suite, iters, reps, warmup):
    """按 ABBA 顺序跑完 suite 里所有配置。"""
    results = {}
    for name, cfg in suite.items():
        results[name] = []

    for rep in range(reps):
        order = list(suite.keys()) if rep % 2 == 0 else list(suite.keys())[::-1]
        print(f"\n--- rep {rep+1}/{reps} 顺序={'正向' if rep%2==0 else '反向'} ---")
        for name in order:
            cfg = suite[name]
            r = run_once(**cfg, iters=iters, warmup=warmup, label=name)
            if "samples" in r:
                print(f"  {name:<28} p50={r['p50']:7.2f} p95={r['p95']:7.2f} "
                      f"max={r['max']:7.2f} ane_fail={r['stderr_ane_fail']} "
                      f"plan={r.get('plan_device_counts')}")
            else:
                print(f"  {name:<28} FAILED: {r.get('error')} {r.get('stderr','')[:120]}")
            results[name].append(r)
    return results


def build_suite(kind):
    if kind == "units":
        # ① computeUnits 全档对比（基准模型，默认旋钮）
        return {u: dict(model=BASE_MODEL, units=u) for u in
                ["all", "cpuAndGPU", "cpuOnly", "cpuAndNE"]}
    if kind == "config":
        # ② MLModelConfiguration 其他旋钮（在 .all 与 .cpuAndGPU 两个 computeUnits 上）
        s = {}
        for u in ["all", "cpuAndGPU", "cpuOnly"]:
            s[f"{u}/default"] = dict(model=BASE_MODEL, units=u)
            s[f"{u}/fastPred"] = dict(model=BASE_MODEL, units=u, strategy="fastPrediction")
            s[f"{u}/fastPred+lowprec"] = dict(model=BASE_MODEL, units=u,
                                              strategy="fastPrediction", lowprec=True)
            s[f"{u}/reshapeInfreq"] = dict(model=BASE_MODEL, units=u, reshape="infrequent")
        return s
    if kind == "variants":
        # ③ 导出侧旋钮：每个 exp_exec_* 产物在 GPU/CPU 上各测一遍
        s = {}
        for p in sorted((_ROOT / "models").glob("exp_exec_*.mlmodelc")):
            if p.name.startswith("exp_exec_tmp"):
                continue
            n = p.name[len("exp_exec_"):-len(".mlmodelc")]
            s[f"{n}/gpu"] = dict(model=str(p.relative_to(_ROOT)), units="cpuAndGPU")
            s[f"{n}/cpu"] = dict(model=str(p.relative_to(_ROOT)), units="cpuOnly")
            s[f"{n}/all"] = dict(model=str(p.relative_to(_ROOT)), units="all")
        return s
    raise SystemExit(f"未知 suite：{kind}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", required=True, choices=["units", "config", "variants"])
    ap.add_argument("--iters", type=int, default=30)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--tag", default="")
    args = ap.parse_args()

    if not BENCH.exists():
        raise SystemExit(f"✗ 基准程序不存在：{BENCH}\n  先编译：swiftc -O -o {BENCH} "
                         f"tools/exp_exec_bench.swift")
    OUTDIR.mkdir(parents=True, exist_ok=True)
    suite = build_suite(args.suite)
    print(f"═══ S2 suite={args.suite} 配置数={len(suite)} reps={args.reps} "
          f"iters={args.iters} warmup={args.warmup} ═══")
    print(f"    uptime={int(time.time())} loadavg={os.getloadavg()}")
    print(f"    机型：{subprocess.run(['sysctl','-n','machdep.cpu.brand_string'],"
          f"capture_output=True,text=True).stdout.strip()}")

    results = abba(suite, args.iters, args.reps, args.warmup)

    out = {}
    print(f"\n═══ 汇总（suite={args.suite}）═══")
    print(f"{'配置':<30} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8} "
          f"{'样本':>6} {'ANE失败':>8}  plan")
    for name, runs in results.items():
        s = summarize(runs)
        out[name] = s
        if s.get("n_runs", 0) == 0:
            print(f"{name:<30}  FAILED: {s.get('error')}")
            continue
        print(f"{name:<30} {s['p50']:8.2f} {s['p95']:8.2f} {s['p99']:8.2f} "
              f"{s['max']:8.2f} {s['n_samples']:6d} {str(s['ane_compile_fail']):>8}  "
              f"{s['plan_device_counts']}")

    tag = args.tag or args.suite
    p = OUTDIR / f"{tag}-{time.strftime('%H%M%S')}.json"
    p.write_text(json.dumps({"suite": args.suite, "args": vars(args),
                             "summary": out,
                             "raw": {k: [{kk: vv for kk, vv in r.items() if kk != "samples"}
                                         for r in v] for k, v in results.items()},
                             "samples": {k: [x for r in v if "samples" in r
                                             for x in r["samples"]] for k, v in results.items()},
                             }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果 → {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
