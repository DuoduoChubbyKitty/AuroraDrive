#!/usr/bin/env python3
"""A-YOLOM CoreML 速度实测（ABBA 交错 + 分位数）

沿用项目既有铁律（见 docs 性能实测 §6.x）：
  · 模型常驻，只切换被测对象；不重复加载
  · 预热后再计时（首次含 ANE 编译，必须丢弃）
  · 报 p50/p95/p99，不只报均值
  · 单独跑、不与其它模型同时加载，避免互相污染
"""
import sys, time, argparse, statistics
import numpy as np
import coremltools as ct


def bench(path, n_warm=10, n_run=60, unit="all"):
    cfg = ct.ComputeUnit.ALL if unit == "all" else ct.ComputeUnit.CPU_AND_NE
    t0 = time.time()
    m = ct.models.MLModel(path, compute_units=cfg)
    load = time.time() - t0

    spec = m.get_spec()
    inp = spec.description.input[0].name
    shape = [d for d in spec.description.input[0].type.multiArrayType.shape]
    print(f"  输入 {inp} {shape}   加载 {load*1000:.0f} ms")

    x = np.random.rand(*shape).astype(np.float32)
    for _ in range(n_warm):
        m.predict({inp: x})

    ts = []
    for _ in range(n_run):
        t = time.perf_counter()
        m.predict({inp: x})
        ts.append((time.perf_counter() - t) * 1000)
    ts.sort()
    p = lambda q: ts[min(int(len(ts) * q), len(ts) - 1)]
    return {
        "p50": p(0.50), "p95": p(0.95), "p99": p(0.99),
        "min": ts[0], "max": ts[-1], "mean": statistics.mean(ts),
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("models", nargs="+")
    ap.add_argument("--runs", type=int, default=60)
    ap.add_argument("--unit", default="all")
    a = ap.parse_args()
    print(f"=== A-YOLOM CoreML 实测 (unit={a.unit}, runs={a.runs}) ===")
    for mp in a.models:
        print(f"\n▶ {mp}")
        r = bench(mp, n_run=a.runs, unit=a.unit)
        print(f"    p50={r['p50']:.1f}  p95={r['p95']:.1f}  p99={r['p99']:.1f}  "
              f"min={r['min']:.1f}  max={r['max']:.1f}  mean={r['mean']:.1f}  (ms)")
        print(f"    → {1000/r['p50']:.1f} Hz (按 p50)")
