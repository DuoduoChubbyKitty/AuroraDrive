#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
exp_exec_pair.py — S2 配对测量器（同轮背靠背 + ABBA 交替 + 可选受控负载）

================================================================================
为什么要"配对"而不是"排队各测一遍"
================================================================================
本机是 M3 MacBook Air（**无风扇**），且**同时有其他 agent 在跑重活**。
实测同一份产物、同一配置：

    07:29  load≈5   → p50 14.41 ms
    07:53  load≈34  → p50 53.17 ms

**差 3.7×**。在这种机器上按 A→B→C→D 顺序各测 5 轮，后测的配置会被
系统性地拖累，结论直接是错的（"最后测的最慢"）。

三条对策，本脚本全上：
  ① **配对**：一轮之内把**所有配置背靠背**跑完（间隔 < 1s），
     负载漂移对每个配置的影响近似相同 → 比**比值**（相对基准的倍率）而不是绝对值。
  ② **ABBA**：正向一轮 + 反向一轮，把"轮内顺序效应"也抵消掉。
  ③ **受控负载**（--burn N）：用 `tools/perf/.burn` 起 N 线程 UTILITY 负载，
     让**每轮**都在同样的背景负载下，消除"什么时候恰好没人抢"的运气成分。
     ★ 这不只是权宜之计：项目既有方法论（`tools/perf/load.sh` 头注释）明确写着
       「等机器空了再测，测的是用户永远不会遇到的工况」——真实场景就是满载。

输出：每配置的 p50/p95（合并所有轮次）+ **相对基准的倍率** + 每轮 loadavg 记录。

用法：
    # 空载配对（能等到安静窗口时用）
    ./.venv-yolo26/bin/python3 tools/exp_exec_pair.py --suite units --reps 4

    # 受控满载配对（推荐：可复现，且贴近真实工况）
    ./.venv-yolo26/bin/python3 tools/exp_exec_pair.py --suite units --reps 4 --burn 6
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
BURN = _ROOT / "tools" / "perf" / ".burn"
OUTDIR = _ROOT / "models" / "exp_exec_results"
BASE_MODEL = "models/m9_v2.mlmodelc"


def loadavg():
    return os.getloadavg()[0]


def pctl(s, p):
    s = sorted(s)
    return s[min(len(s) - 1, int(len(s) * p))]


def run_once(model, units, strategy="default", lowprec=False, reshape="frequent",
             iters=30, warmup=5, label="", timeout=900):
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
    res["loadavg_before"] = loadavg()
    res["uptime"] = int(time.time())
    return res


def build_suite(kind):
    if kind == "units":
        return {u: dict(model=BASE_MODEL, units=u) for u in
                ["cpuAndGPU", "cpuOnly", "all", "cpuAndNE"]}
    if kind == "config":
        s = {}
        for u in ["cpuAndGPU", "cpuOnly"]:
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
        return s
    if kind == "variants_cpu":
        s = {}
        for p in sorted((_ROOT / "models").glob("exp_exec_t_*.mlmodelc")):
            n = p.name[len("exp_exec_"):-len(".mlmodelc")]
            s[f"{n}/cpu"] = dict(model=str(p.relative_to(_ROOT)), units="cpuOnly")
        return s
    if kind == "final":
        # 决胜局：现役配置 vs 各候选（同一轮内背靠背）
        return {
            "现役 fp16/mac13 + .all":       dict(model=BASE_MODEL, units="all"),
            "现役 fp16/mac13 + .cpuAndGPU": dict(model=BASE_MODEL, units="cpuAndGPU"),
            "fp16/mac14 + .cpuAndGPU":      dict(model="models/exp_exec_t_mac14_fp16.mlmodelc",
                                                 units="cpuAndGPU"),
            "fp16/mac15 + .cpuAndGPU":      dict(model="models/exp_exec_t_mac15_fp16.mlmodelc",
                                                 units="cpuAndGPU"),
            "fp32/mac13 + .all":            dict(model="models/exp_exec_t_mac13_fp32.mlmodelc",
                                                 units="all"),
            "fp32/mac15 + .all":            dict(model="models/exp_exec_t_mac15_fp32.mlmodelc",
                                                 units="all"),
            "fp32/mac15 + .cpuAndGPU":      dict(model="models/exp_exec_t_mac15_fp32.mlmodelc",
                                                 units="cpuAndGPU"),
        }
    if kind == "anecheck":
        # ANE 三重判据：三档 computeUnits 下逐算子派发 + 编译日志
        s = {}
        for u in ["all", "cpuAndNE", "cpuAndGPU", "cpuOnly"]:
            s[f"fp16/mac13 + .{u}"] = dict(model=BASE_MODEL, units=u)
            s[f"fp32/mac15 + .{u}"] = dict(model="models/exp_exec_t_mac15_fp32.mlmodelc", units=u)
        return s
    raise SystemExit(f"未知 suite：{kind}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", required=True,
                    choices=["units", "config", "variants", "variants_cpu", "final", "anecheck"])
    ap.add_argument("--iters", type=int, default=30)
    ap.add_argument("--reps", type=int, default=4)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--burn", type=int, default=0,
                    help="受控 CPU 背景负载线程数（0=不加；推荐 6，与项目 load.sh 口径一致）")
    ap.add_argument("--gpu-burn", type=int, default=0,
                    help="受控 **GPU** 背景负载强度（0=不加）。真实驾驶场景游戏占 GPU，"
                         "用来验证 .cpuAndGPU 是否与游戏抢 GPU")
    ap.add_argument("--burn-sec", type=int, default=1200)
    ap.add_argument("--baseline", default=None, help="倍率基准配置名（默认第一个）")
    ap.add_argument("--tag", default="")
    args = ap.parse_args()

    OUTDIR.mkdir(parents=True, exist_ok=True)
    suite = build_suite(args.suite)
    names = list(suite.keys())
    base = args.baseline or names[0]
    if base not in suite:
        raise SystemExit(f"基准 {base} 不在 suite 中")
    tag = args.tag or args.suite
    log_path = OUTDIR / f"pair-{tag}-{time.strftime('%H%M%S')}.log"
    fh = log_path.open("w", encoding="utf-8")

    def emit(s):
        print(s)
        fh.write(s + "\n")
        fh.flush()

    burn = None
    gpu_burn = None
    if args.burn > 0:
        if not BURN.exists():
            raise SystemExit(f"✗ 负载生成器不存在：{BURN}\n  先编译：bash tools/perf/load.sh build")
        burn = subprocess.Popen([str(BURN), str(args.burn), str(args.burn_sec)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if args.gpu_burn > 0:
        gb = _ROOT / "models" / "exp_exec_tmp" / "gpu_burn"
        if not gb.exists():
            raise SystemExit(f"✗ GPU 负载生成器不存在：{gb}\n"
                             f"  先编译：swiftc -O -o {gb} tools/exp_exec_gpu_burn.swift")
        gpu_burn = subprocess.Popen([str(gb), str(args.burn_sec), str(args.gpu_burn)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if burn is not None or gpu_burn is not None:
        time.sleep(3.0)   # 让负载稳定

    try:
        emit(f"═══ 配对测量 suite={args.suite} 配置数={len(suite)} reps={args.reps} "
             f"iters={args.iters} cpu_burn={args.burn}线程 gpu_burn={args.gpu_burn} "
             f"基准={base} ═══")
        emit(f"    开始 {time.strftime('%Y-%m-%d %H:%M:%S')} loadavg={loadavg():.2f} "
             f"uptime={int(time.time())}")

        results = {k: [] for k in names}
        for rep in range(args.reps):
            order = names if rep % 2 == 0 else names[::-1]
            emit(f"\n--- rep {rep+1}/{args.reps} {'正向' if rep%2==0 else '反向'} "
                 f"(load={loadavg():.2f}) ---")
            for name in order:
                r = run_once(**suite[name], iters=args.iters, warmup=args.warmup, label=name)
                results[name].append(r)
                if "samples" in r:
                    emit(f"  {name:<26} p50={r['p50']:7.2f} p95={r['p95']:7.2f} "
                         f"max={r['max']:7.2f} ane_fail={str(r['ane_fail']):<5} "
                         f"load={r['loadavg_before']:.2f}")
                else:
                    emit(f"  {name:<26} FAILED {r.get('error')} {r.get('stderr','')[:100]}")

        # ---- 汇总 ----
        emit(f"\n═══ 汇总（配对，基准 = {base}）═══")
        emit(f"{'配置':<26} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8} {'轮':>3} "
             f"{'样本':>5} {'×p50':>7} {'×p95':>7} {'ANE失败':>7}")
        summary = {}
        base_runs = [r for r in results[base] if "samples" in r]
        if not base_runs:
            emit(f"⚠ 基准 {base} 无数据，无法算倍率")
        base_p50 = pctl([x for r in base_runs for x in r["samples"]], .50) if base_runs else None
        base_p95 = pctl([x for r in base_runs for x in r["samples"]], .95) if base_runs else None

        for name in names:
            ok = [r for r in results[name] if "samples" in r]
            if not ok:
                summary[name] = {"n_runs": 0, "error": results[name][0].get("error")}
                emit(f"{name:<26} 无数据")
                continue
            s = sorted(x for r in ok for x in r["samples"])
            las = [r["loadavg_before"] for r in ok]
            summary[name] = {
                "n_runs": len(ok), "n_samples": len(s),
                "p50": pctl(s, .50), "p90": pctl(s, .90), "p95": pctl(s, .95),
                "p99": pctl(s, .99), "max": max(s), "mean": statistics.fmean(s),
                "min": min(s), "stdev": statistics.pstdev(s) if len(s) > 1 else 0.0,
                "ane_compile_fail": any(r["ane_fail"] for r in ok),
                "loadavg_mean": statistics.fmean(las), "loadavg_max": max(las),
                "uptimes": [r["uptime"] for r in ok],
                "ratio_p50_vs_base": (pctl(s, .50) / base_p50) if base_p50 else None,
                "ratio_p95_vs_base": (pctl(s, .95) / base_p95) if base_p95 else None,
                "per_rep_p50": [r["p50"] for r in ok],
            }
            emit(f"{name:<26} {summary[name]['p50']:8.2f} {summary[name]['p95']:8.2f} "
                 f"{summary[name]['p99']:8.2f} {summary[name]['max']:8.2f} "
                 f"{len(ok):3d} {len(s):5d} "
                 f"{summary[name]['ratio_p50_vs_base']:7.3f} "
                 f"{summary[name]['ratio_p95_vs_base']:7.3f} "
                 f"{str(summary[name]['ane_compile_fail']):>7}")

        out = OUTDIR / f"pair-{tag}-{time.strftime('%H%M%S')}.json"
        out.write_text(json.dumps({
            "suite": args.suite, "args": vars(args), "baseline": base, "summary": summary,
            "raw": {k: [{kk: vv for kk, vv in r.items() if kk != "samples"} for r in v]
                    for k, v in results.items()},
            "samples": {k: [x for r in v if "samples" in r for x in r["samples"]]
                        for k, v in results.items()},
            "log": str(log_path),
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        emit(f"\n结果 → {out}")
    finally:
        if burn is not None:
            burn.terminate()
            try:
                burn.wait(timeout=10)
            except subprocess.TimeoutExpired:
                burn.kill()
        fh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
