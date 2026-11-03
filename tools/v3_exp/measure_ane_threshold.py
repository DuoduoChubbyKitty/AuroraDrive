#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 骨干补充实验：ANE 派发阈值定位 + 干净延迟测量（ABBA 中位）

触发本实验的两个观察（来自 measure_backbone_v3.py 实跑）：

  观察 A：D=128（4.16M / 4.56 GFLOPs）和 84-token（7.35M / 3.87 GFLOPs）这两个
          配置只有约 10% 算子派到 ANE，其余 196 个算子落 GPU；
          而 D=160（5.27 GFLOPs）和 D=192（6.13 GFLOPs）是 100% ANE、0 落 CPU/GPU。
  观察 B：CPU-only 延迟数字自相矛盾（d3 参数更少反而 9.21ms > d4 的 4.98ms），
          说明单轮计时被背景负载污染，不可信。

本实验回答两个问题：
  Q1（决定选型）：D=128 上不了 ANE，是因为 dim=128 这个宽度本身，
      还是因为「模型算力太小，CoreML 判定 GPU 更划算」？
      做法：固定 dim=128，只加深深度（算力变大），看派发是否翻转到 ANE。
      若加深后翻转到 ANE → 是算力阈值效应，dim=128 本身无罪；
      若始终不翻转 → 是宽度限制，D=128 必须排除。
  Q2（修正测量方法）：用 ABBA 交替 + 多轮取中位重测延迟，抵消负载漂移。

⚠️ 全程本地计算，不联网、不启动 App、不建窗口。
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import torch
import torch.nn as nn

_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROOT))

from tools.v3_exp.backbone_v3 import BackboneConfig, build_v3_backbone   # noqa: E402
from tools.v3_exp.measure_backbone_v3 import (                           # noqa: E402
    ane_probe,
    count_params,
    measure_flops,
)

OUT_DIR = Path("/tmp/v3_bb_threshold")


def abba_latency(pkg_path: str, cfg: BackboneConfig, rounds: int = 5,
                 warmup: int = 8, iters: int = 40) -> dict:
    """ABBA 交替测 ANE / CPU-only 延迟，每轮取中位。

    为什么用 ABBA：单轮顺序测（先 ANE 再 CPU）会被系统负载漂移污染——
    第一次跑的时候后台可能在编译/索引，第二次就干净了，两者差异会被误当成
    「ANE 比 CPU 快/慢」。ABBA（ANE,CPU,CPU,ANE）让两种模式的先后顺序对称，
    再对各轮取中位，可抵消单调漂移。这是仓库 exp_pipeline_ane.py 已用的协议。
    """
    import coremltools as ct
    import numpy as np
    import time

    image = np.random.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w).astype(np.float32)
    state = np.random.randn(1, cfg.state_dim).astype(np.float32)

    models = {}
    for key, unit in (("ane", ct.ComputeUnit.ALL), ("cpu", ct.ComputeUnit.CPU_ONLY)):
        m = ct.models.MLModel(pkg_path, compute_units=unit)
        names = [f.name for f in m.input_description._fd_spec]
        img_name = "image" if "image" in names else names[0]
        st_name = next((n for n in names if n != img_name), "vehicle_state")
        models[key] = (m, {img_name: image, st_name: state})

    samples: dict[str, list[float]] = {"ane": [], "cpu": []}

    def run_once(key: str) -> float:
        m, inputs = models[key]
        for _ in range(warmup):
            m.predict(inputs)
        t0 = time.perf_counter()
        for _ in range(iters):
            m.predict(inputs)
        return (time.perf_counter() - t0) / iters * 1000.0

    for _ in range(rounds):
        samples["ane"].append(run_once("ane"))
        samples["cpu"].append(run_once("cpu"))
        samples["cpu"].append(run_once("cpu"))
        samples["ane"].append(run_once("ane"))

    out = {
        "ane_ms_median": round(statistics.median(samples["ane"]), 3),
        "cpu_ms_median": round(statistics.median(samples["cpu"]), 3),
        "ane_samples": [round(x, 3) for x in samples["ane"]],
        "cpu_samples": [round(x, 3) for x in samples["cpu"]],
        "rounds": rounds,
        "iters_per_sample": iters,
    }
    a, c = out["ane_ms_median"], out["cpu_ms_median"]
    out["speedup"] = round(c / a, 2) if a else None
    return out


def probe_config(tag: str, cfg: BackboneConfig, want_latency: bool) -> dict:
    torch.manual_seed(0)
    model = build_v3_backbone(cfg, deploy=True).eval()
    image = torch.randn(1, cfg.in_channels, cfg.image_h, cfg.image_w)
    state = torch.randn(1, cfg.state_dim)

    total = count_params(model)
    flops = measure_flops(model, image, state)
    row = {
        "tag": tag,
        "dim": cfg.dim,
        "depth_per_stage": cfg.depth_per_stage,
        "tokens": cfg.num_visual_tokens(),
        "params": total,
        "flops_G": round(flops / 1e9, 3),
    }
    ane = ane_probe(model, cfg, tag)
    row["ane_ratio"] = ane["ane_ratio"]
    row["ane_ops"] = ane["ane_ops"]
    row["gpu_ops"] = ane["gpu_ops"]
    row["cpu_ops"] = ane["cpu_ops"]
    row["total_ops"] = ane["total_ops"]
    row["size_mb_fp16"] = ane["package_size_mb"]

    if want_latency:
        try:
            lat = abba_latency(str(Path(ane["package_path"]).with_suffix(".mlpackage")), cfg)
            row["latency"] = lat
        except Exception as exc:
            row["latency_error"] = f"{type(exc).__name__}: {exc}"

    print(f"\n[{tag}] dim={cfg.dim} depth={cfg.depth_per_stage} tokens={row['tokens']}")
    print(f"  参数 {total:,} ({total/1e6:.3f}M) | {row['flops_G']} GFLOPs")
    print(f"  ANE 派发: ANE={ane['ane_ops']} GPU={ane['gpu_ops']} CPU={ane['cpu_ops']} "
          f"/{ane['total_ops']}  → ANE {ane['ane_ratio']*100:.1f}%")
    if "latency" in row:
        lat = row["latency"]
        print(f"  ABBA 延迟: ANE {lat['ane_ms_median']} ms | CPU {lat['cpu_ms_median']} ms "
              f"| 加速 {lat['speedup']}×")
        print(f"    ANE 样本 {lat['ane_samples']}")
        print(f"    CPU 样本 {lat['cpu_samples']}")
    elif "latency_error" in row:
        print(f"  ⚠ 延迟测量失败: {row['latency_error']}")
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--latency", action="store_true", help="额外做 ABBA 延迟测量（较慢）")
    ap.add_argument("--out", default="/tmp/v3_bb_threshold.json")
    args = ap.parse_args()

    print("=" * 78)
    print("V3 骨干补充实验：ANE 派发阈值 + ABBA 干净延迟")
    print("=" * 78)

    results = []

    # ── Q1: 固定 dim=128，只加深深度 → 算力单调增大 ──
    # 若在某个深度上派发从 GPU 翻转到 ANE，说明是算力阈值效应而非宽度限制。
    print("\n── Q1：固定 D=128，加深深度（算力递增），观察 ANE 派发是否翻转 ──")
    for depth in (4, 6, 8, 10):
        cfg = BackboneConfig(dim=128, heads=4, depth_per_stage=depth)
        results.append(probe_config(f"D128_t336_d{depth}x2", cfg, want_latency=False))

    # ── 对照：D=160 / D=192 正常深度（已知 100% ANE，作为阳性对照）──
    print("\n── 对照：D=160 / D=192（阳性对照，预期 100% ANE）──")
    for d, h in ((160, 5), (192, 6)):
        cfg = BackboneConfig(dim=d, heads=h, depth_per_stage=4)
        results.append(probe_config(f"D{d}_t336_d4x2", cfg, want_latency=False))

    # ── Q2: 推荐配置的干净延迟（ABBA 中位）──
    if args.latency:
        print("\n── Q2：ABBA 干净延迟测量 ──")
        for tag, cfg in (
            ("LAT_D160_d4", BackboneConfig(dim=160, heads=5, depth_per_stage=4)),
            ("LAT_D192_d4", BackboneConfig(dim=192, heads=6, depth_per_stage=4)),
        ):
            results.append(probe_config(tag, cfg, want_latency=True))

    # ── 汇总 ──
    print(f"\n{'=' * 100}")
    print("【汇总】ANE 派发阈值实验")
    print(f"{'tag':<20} {'dim':>4} {'depth':>6} {'参数M':>8} {'GFLOPs':>8} "
          f"{'ANE':>5} {'GPU':>5} {'CPU':>5} {'ANE%':>7}")
    print("-" * 100)
    for r in results:
        print(f"{r['tag']:<20} {r['dim']:>4} {r['depth_per_stage']:>6} "
              f"{r['params']/1e6:>8.3f} {r['flops_G']:>8.3f} "
              f"{r['ane_ops']:>5} {r['gpu_ops']:>5} {r['cpu_ops']:>5} "
              f"{r['ane_ratio']*100:>6.1f}%")
    print("-" * 100)

    if args.latency:
        print("\n【ABBA 延迟（中位数）】")
        for r in results:
            if "latency" in r:
                lat = r["latency"]
                print(f"  {r['tag']:<14} ANE {lat['ane_ms_median']:>6.3f} ms | "
                      f"CPU {lat['cpu_ms_median']:>6.3f} ms | 加速 {lat['speedup']}× "
                      f"({lat['rounds']} 轮 × ({lat['iters_per_sample']}×4) 次取中位)")

    Path(args.out).write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f"\n结果已落盘: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
