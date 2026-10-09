#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_exec_min.py — 用「多轮取最小值」估计无争用延迟（S2 · 2026-10-09）

================================================================================
为什么用最小值
================================================================================
本机（M3 MacBook Air，无风扇）在整个实验期间被其他 agent 抢 CPU，
loadavg 长期 10~50，**从未取得安静窗口**。在这种条件下：

  · 平均值/中位数被争用系统性抬高，**不能代表无争用性能**
  · 但**最小值**是稳健估计：只要某一轮恰好抢到了 CPU，最小值就逼近真实下界
  · 争用只会让延迟**变差**，不会变好 —— 所以 min 是**下界估计**，
    而"下界都达不到 16ms"是强结论；"下界达标"是弱结论（需注明）

本脚本对每个配置跑 N 轮，记录：
  · min-of-p50  —— 各轮 p50 的最小值（无争用 p50 的估计）
  · min-of-p95  —— 各轮 p95 的最小值
  · 全局 min    —— 所有单次样本的最小值
  · 以及每轮 loadavg，便于判断该轮是否接近安静

用法：
    ./.venv-yolo26/bin/python3 tools/exp_exec_min.py --rounds 12 --iters 30
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


def loadavg():
    return os.getloadavg()[0]


def run_once(cfg, iters, warmup, label):
    cmd = [str(BENCH), "--model", str(_ROOT / cfg["model"]), "--units", cfg["units"],
           "--strategy", cfg.get("strategy", "default"),
           "--reshape", cfg.get("reshape", "frequent"),
           "--lowprec-accum", "1" if cfg.get("lowprec") else "0",
           "--rounds", "1", "--iters", str(iters), "--warmup", str(warmup),
           "--plan", "0", "--label", label]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return None
    for line in p.stdout.splitlines():
        if line.startswith("RESULT_JSON "):
            r = json.loads(line[len("RESULT_JSON "):])
            r["ane_fail"] = "MILCompilerForANE" in p.stderr or "MILCompilerForANE" in p.stdout
            r["loadavg"] = loadavg()
            return r
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=12, help="每个配置重复轮数")
    ap.add_argument("--iters", type=int, default=30)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--tag", default="min")
    args = ap.parse_args()

    suite = {
        "fp16/mac13 + .all（现役）":   dict(model="models/m9_v2.mlmodelc", units="all"),
        "fp16/mac13 + .cpuAndGPU":     dict(model="models/m9_v2.mlmodelc", units="cpuAndGPU"),
        "fp16/mac13 + .cpuOnly":       dict(model="models/m9_v2.mlmodelc", units="cpuOnly"),
        "fp16/mac13 + .cpuAndNE":      dict(model="models/m9_v2.mlmodelc", units="cpuAndNE"),
        "fp32/mac15 + .all":           dict(model="models/exp_exec_t_mac15_fp32.mlmodelc", units="all"),
        "fp32/mac15 + .cpuAndGPU":     dict(model="models/exp_exec_t_mac15_fp32.mlmodelc", units="cpuAndGPU"),
        "fp16/mac14 + .cpuAndGPU":     dict(model="models/exp_exec_t_mac14_fp16.mlmodelc", units="cpuAndGPU"),
    }

    OUTDIR.mkdir(parents=True, exist_ok=True)
    log_path = OUTDIR / f"min-{args.tag}-{time.strftime('%H%M%S')}.log"
    fh = log_path.open("w", encoding="utf-8")

    def emit(s):
        print(s, flush=True)
        fh.write(s + "\n")
        fh.flush()

    emit(f"═══ 多轮取最小值 suite（{len(suite)} 配置 × {args.rounds} 轮 × {args.iters} 次）═══")
    emit(f"    开始 {time.strftime('%Y-%m-%d %H:%M:%S')} loadavg={loadavg():.2f}")

    all_runs = {k: [] for k in suite}
    for rnd in range(args.rounds):
        names = list(suite.keys()) if rnd % 2 == 0 else list(suite.keys())[::-1]
        emit(f"\n--- 第 {rnd+1}/{args.rounds} 轮 {'正向' if rnd%2==0 else '反向'} "
             f"(load={loadavg():.2f}) ---")
        for name in names:
            r = run_once(suite[name], args.iters, args.warmup, name)
            if r is None:
                emit(f"  {name:<30} FAILED")
                continue
            all_runs[name].append(r)
            emit(f"  {name:<30} p50={r['p50']:7.2f} p95={r['p95']:7.2f} "
                 f"max={r['max']:7.2f} load={r['loadavg']:.1f} "
                 f"ane_fail={r['ane_fail']}")

    emit(f"\n═══ 汇总：最小值 = 无争用下界估计 ═══")
    emit(f"{'配置':<30} {'min_p50':>8} {'min_p95':>8} {'全局min':>8} "
         f"{'中位p50':>8} {'轮':>3} {'load@min':>9} {'ANE失败':>7}")
    summary = {}
    for name, runs in all_runs.items():
        if not runs:
            summary[name] = {"n_runs": 0}
            continue
        p50s = [r["p50"] for r in runs]
        p95s = [r["p95"] for r in runs]
        i = p50s.index(min(p50s))
        summary[name] = {
            "n_runs": len(runs),
            "min_p50": min(p50s), "min_p95": min(p95s),
            "global_min": min(r["min"] for r in runs),
            "median_p50": statistics.median(p50s),
            "median_p95": statistics.median(p95s),
            "loadavg_at_min_p50": runs[i]["loadavg"],
            "loadavg_all": [round(r["loadavg"], 1) for r in runs],
            "p50s": p50s, "p95s": p95s,
            "ane_compile_fail": any(r["ane_fail"] for r in runs),
            "min_p50_run_samples": runs[i]["samples"],
        }
        emit(f"{name:<30} {summary[name]['min_p50']:8.2f} {summary[name]['min_p95']:8.2f} "
             f"{summary[name]['global_min']:8.2f} {summary[name]['median_p50']:8.2f} "
             f"{len(runs):3d} {summary[name]['loadavg_at_min_p50']:9.1f} "
             f"{str(summary[name]['ane_compile_fail']):>7}")

    # 相对现役 .all 的倍率（用 min_p50 与 median_p50 两个口径）
    ref = "fp16/mac13 + .all（现役）"
    if ref in summary and summary[ref].get("n_runs"):
        emit(f"\n═══ 相对现役（{ref}）的倍率 ═══")
        emit(f"{'配置':<30} {'×min_p50':>9} {'×median_p50':>12}")
        for name, s in summary.items():
            if not s.get("n_runs") or name == ref:
                continue
            emit(f"{name:<30} {s['min_p50']/summary[ref]['min_p50']:9.3f} "
                 f"{s['median_p50']/summary[ref]['median_p50']:12.3f}")

    out = OUTDIR / f"min-{args.tag}-{time.strftime('%H%M%S')}.json"
    out.write_text(json.dumps({"args": vars(args), "summary": summary},
                              ensure_ascii=False, indent=2), encoding="utf-8")
    emit(f"\n结果 → {out}")
    fh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
