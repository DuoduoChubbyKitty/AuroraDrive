#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""拆分模型真机延迟测量（p95≤16ms 攻坚）

测两个模型的 CoreML 延迟 + ANE 是否生效：
  · 模型 A（m9_v2_enc）: 单帧图像编码
  · 模型 B（m9_v2_ctl）: 单帧主控
  · 串联总延迟 = A + B

用法：
    ./.venv-yolo26/bin/python3 tools/measure_split_latency.py --rounds 10 --iters 30
"""
from __future__ import annotations

import argparse
import statistics
import sys
import time
from pathlib import Path

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT / "src"))

import coremltools as ct  # noqa: E402

IMG_H, IMG_W = 180, 320
LANE_SIZE = 160
NUM_DETS = 20
DET_FEAT_DIM = 12
STATE_DIM = 8
NUM_FRAMES = 8
FEAT_DIM = 256


def make_inputs_a() -> dict:
    return {"image": np.random.rand(1, 3, IMG_H, IMG_W).astype(np.float32)}


def make_inputs_b() -> dict:
    return {
        "feat_seq": np.random.rand(1, NUM_FRAMES, FEAT_DIM).astype(np.float32),
        "lane": np.zeros((1, 1, LANE_SIZE, LANE_SIZE), dtype=np.float32),
        "dets": np.zeros((1, NUM_DETS, DET_FEAT_DIM), dtype=np.float32),
        "det_mask": np.zeros((1, NUM_DETS), dtype=np.float32),
        "vehicle_state": np.zeros((1, STATE_DIM), dtype=np.float32),
    }


def time_model(model, inputs: dict, iters: int, warmup: int = 5) -> float:
    for _ in range(warmup):
        model.predict(inputs)
    ts = []
    for _ in range(iters):
        t0 = time.perf_counter()
        model.predict(inputs)
        ts.append((time.perf_counter() - t0) * 1000.0)
    return statistics.median(ts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--iters", type=int, default=30)
    ap.add_argument("--units", default="all",
                    choices=["all", "cpuAndGPU", "cpuOnly", "cpuAndNeuralEngine"])
    args = ap.parse_args()

    cu = {
        "all": ct.ComputeUnit.ALL,
        "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
        "cpuOnly": ct.ComputeUnit.CPU_ONLY,
        "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE,
    }[args.units]

    enc_path = _ROOT / "models" / "split" / "m9_v2_enc.mlpackage"  # Python 侧用 mlpackage（坑7：mlmodelc 无 Manifest.json）
    ctl_path = _ROOT / "models" / "split" / "m9_v2_ctl.mlpackage"
    for p in (enc_path, ctl_path):
        if not p.exists():
            print(f"❌ 模型不存在: {p}")
            print("   先跑: ./.venv-yolo26/bin/python3 tools/export_split_models.py")
            return 1

    print("=" * 70)
    print(f" 拆分模型延迟测量（computeUnits={args.units}）")
    print("=" * 70)

    # CoreML 的 computeUnits 通过 ct.models.MLModel(..., compute_units=) 传入
    # （coremltools 8.3 没有 ct.ModelConfiguration；那是 swift 侧 API）

    print("[测量] 加载模型 A（图像编码）...")
    t0 = time.perf_counter()
    ma = ct.models.MLModel(str(enc_path), compute_units=cu)
    load_a = (time.perf_counter() - t0) * 1000
    print(f"[测量]   ✓ 加载 {load_a:.0f}ms")

    print("[测量] 加载模型 B（主控）...")
    t0 = time.perf_counter()
    mb = ct.models.MLModel(str(ctl_path), compute_units=cu)
    load_b = (time.perf_counter() - t0) * 1000
    print(f"[测量]   ✓ 加载 {load_b:.0f}ms")

    ia, ib = make_inputs_a(), make_inputs_b()

    print(f"\n[测量] 预热 + {args.rounds} 轮 × {args.iters} 次 ...")
    rounds_a, rounds_b, rounds_ab = [], [], []
    for r in range(args.rounds):
        ta = time_model(ma, ia, args.iters)
        tb = time_model(mb, ib, args.iters)
        rounds_a.append(ta)
        rounds_b.append(tb)
        rounds_ab.append(ta + tb)
        print(f"[测量]   round {r+1:2d}: A={ta:6.2f}ms  B={tb:6.2f}ms  串联={ta+tb:6.2f}ms")

    def stats(xs):
        xs_sorted = sorted(xs)
        p50 = statistics.median(xs_sorted)
        p95 = xs_sorted[min(len(xs_sorted) - 1, int(round(0.95 * (len(xs_sorted) - 1))))]
        return p50, p95, max(xs_sorted), min(xs_sorted)

    print("\n" + "=" * 70)
    print(" 结果汇总")
    print("=" * 70)
    for name, xs in (("模型A(编码)", rounds_a), ("模型B(主控)", rounds_b), ("串联总计", rounds_ab)):
        p50, p95, mx, mn = stats(xs)
        print(f"  {name:12s}: p50={p50:6.2f}ms  p95={p95:6.2f}ms  "
              f"min={mn:6.2f}  max={mx:6.2f}")
    p50, p95, mx, _ = stats(rounds_ab)
    print()
    print(f"  ★ 串联 p95 = {p95:.2f}ms  →  目标 ≤16ms  "
          f"{'✅ 达标' if p95 <= 16 else '❌ 未达标'}")
    print(f"  ★ 等效频率 = {1000.0/p95:.1f}Hz  （30Hz 预算 33ms）")
    print(f"  ★ 30Hz 余量 = {33.0/p95:.2f}×")
    print()
    print("  ⚠️ 注意：若上面出现 MILCompilerForANE error，说明 ANE 编译失败已回退 CPU")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
