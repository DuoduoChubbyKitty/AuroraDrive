"""实验 B2：复用已导出模型做**抗噪复测**

⚠️⚠️ 【本机实测的测量环境 —— 必须与结论一起引用】
   测试期间本机 load average ≈ **53**，有 **5 个其它 Python 进程各占 ~90% CPU**
   （同工作区其它 agent 在并行跑基准）。⟹ 绝对耗时被严重污染：
   同一模型在不同时刻可差 5~10×（实测 F8 一次 51.9ms、一次 81.0ms，而 t1 报告 16.16ms）。

   【对策】用 **min-of-N**（N=80）作为统计量：
     · min 是**受争抢影响最小**的样本，近似"无争抢下的真实延迟"
     · p50/p95 在共享机器上测的是"排队+争抢"，不是模型本身
   【比值可信】ANE/CPU 比值在同一进程、同一时刻测得 → 共享的争抢被抵消，
     故 **A/C 比值是可信的**，绝对毫秒数只作量级参考。

   【判定依据】ANE 编译失败会有明确的 stderr：
     `MILCompilerForANE error: failed to compile ANE model using ANEF`
     配合 A/C ≈ 1.0（退化为纯 CPU）双重确认。
"""
import os
import sys
import time
import glob
import statistics
import warnings

sys.path.insert(0, os.path.abspath("."))
import numpy as np
import torch
import coremltools as ct

warnings.simplefilter("ignore")
NFRAMES = 8


def find_models():
    """定位实验 B 留下的产物（临时目录名随机，用 glob 找）。"""
    pats = [
        "/var/folders/*/*/T/pipe_*/*.mlpackage",
        "/tmp/pipe_*/*.mlpackage",
    ]
    found = {}
    for p in pats:
        for d in glob.glob(p):
            name = os.path.basename(d).replace(".mlpackage", "")
            found.setdefault(name, d)
    return found


def mkfeed(kind, seed=0):
    g = torch.Generator().manual_seed(seed)
    if kind == "E1":
        return {"image": torch.rand(1, 3, 180, 320, generator=g).numpy()}
    if kind == "C8":
        return {
            "feats": torch.rand(1, NFRAMES, 256, generator=g).numpy(),
            "lane": (torch.rand(1, 1, 160, 160, generator=g) > 0.985).float().numpy(),
            "dets": torch.rand(1, 20, 12, generator=g).numpy(),
            "det_mask": (torch.rand(1, 20, generator=g) > 0.35).float().numpy(),
            "vehicle_state": torch.rand(1, 8, generator=g).numpy(),
        }
    return {
        "image": torch.rand(NFRAMES, 3, 180, 320, generator=g).numpy(),
        "lane": (torch.rand(1, 1, 160, 160, generator=g) > 0.985).float().numpy(),
        "dets": torch.rand(1, 20, 12, generator=g).numpy(),
        "det_mask": (torch.rand(1, 20, generator=g) > 0.35).float().numpy(),
        "vehicle_state": torch.rand(1, 8, generator=g).numpy(),
    }


def bench(p, feed, cu, iters=80, warmup=10):
    """返回 min/p50/p95。min = 抗争抢的"真实延迟"估计（见文件头）。"""
    mm = ct.models.MLModel(p, compute_units=cu)
    for _ in range(warmup):
        mm.predict(feed)
    ts = []
    for _ in range(iters):
        t0 = time.perf_counter()
        mm.predict(feed)
        ts.append((time.perf_counter() - t0) * 1000)
    ts.sort()
    return {"p50": statistics.median(ts),
            "p95": ts[int((len(ts) - 1) * 0.95)],
            "min": ts[0], "mean": sum(ts) / len(ts)}


def abba(p, feed):
    """ABBA 交替：抵消负载漂移。min 取四轮里的最小（最干净样本）。"""
    a1 = bench(p, feed, ct.ComputeUnit.CPU_AND_NE)
    c1 = bench(p, feed, ct.ComputeUnit.CPU_ONLY)
    c2 = bench(p, feed, ct.ComputeUnit.CPU_ONLY)
    a2 = bench(p, feed, ct.ComputeUnit.CPU_AND_NE)
    ane = {"min": min(a1["min"], a2["min"]),
           "p50": statistics.median([a1["p50"], a2["p50"]]),
           "p95": statistics.median([a1["p95"], a2["p95"]])}
    cpu = {"min": min(c1["min"], c2["min"]),
           "p50": statistics.median([c1["p50"], c2["p50"]]),
           "p95": statistics.median([c1["p95"], c2["p95"]])}
    return ane, cpu


def main() -> int:
    models = find_models()
    print("=" * 108)
    print("实验 B2：已导出模型干净复测（无转换负载污染，50 次迭代 + ABBA 交替）")
    print("=" * 108)
    for k, v in sorted(models.items()):
        print(f"  找到 {k}: {v}")
    if not models:
        print("  ✗ 未找到实验 B 的产物 —— 请先跑 tools/exp_pipeline_ane.py")
        return 1

    kinds = {"E1": "E1", "C8": "C8", "F8": "F8"}
    res = {}
    print(f"\n  {'配置':<10}{'ANE min':>10}{'CPU min':>10}{'A/C':>7}  "
          f"{'ANE p50':>9}{'CPU p50':>9}  判定")
    print("  " + "-" * 74)
    for name, kind in kinds.items():
        if name not in models:
            print(f"  {name:<10} 缺失")
            continue
        ane, cpu = abba(models[name], mkfeed(kind))
        res[name] = (ane, cpu)
        r = ane["min"] / cpu["min"]
        print(f"  {name:<10}{ane['min']:>10.2f}{cpu['min']:>10.2f}{r:>7.2f}  "
              f"{ane['p50']:>9.2f}{cpu['p50']:>9.2f}  "
              f"{'✅ ANE 生效' if r < 0.85 else '🔴 退化 CPU（ANE 编译失败）'}")

    print("\n" + "=" * 108)
    print("流水线合成（min 口径 = 无争抢延迟估计；p50 口径 = 本机实测含争抢）")
    print("=" * 108)
    if "E1" in res and "C8" in res:
        e_ane, e_cpu = res["E1"]
        c_ane, c_cpu = res["C8"]
        print(f"  每帧稳态成本 = 编码器(1帧) + 主控(8帧特征)")
        print(f"    ANE 路径: min {e_ane['min']:.2f} + {c_ane['min']:.2f} = "
              f"{e_ane['min'] + c_ane['min']:.2f} ms   |  "
              f"p50 {e_ane['p50']:.2f} + {c_ane['p50']:.2f} = "
              f"{e_ane['p50'] + c_ane['p50']:.2f} ms")
        print(f"    CPU 路径: min {e_cpu['min']:.2f} + {c_cpu['min']:.2f} = "
              f"{e_cpu['min'] + c_cpu['min']:.2f} ms   |  "
              f"p50 {e_cpu['p50']:.2f} + {c_cpu['p50']:.2f} = "
              f"{e_cpu['p50'] + c_cpu['p50']:.2f} ms")
        if "F8" in res:
            f_ane, f_cpu = res["F8"]
            base = min(f_ane["min"], f_cpu["min"])
            new = e_ane["min"] + c_ane["min"]
            print(f"\n  当前基线 F8: min {f_ane['min']:.2f}(ANE) / {f_cpu['min']:.2f}(CPU) ms")
            print(f"  ⟹ 新方案 min {new:.2f} ms（相对 F8 最快路径提速 {base / new:.2f}×）")
            print(f"  ⚠️ 绝对 ms 受本机争抢污染，比值可信；p95 达标判定须在**空载机器**上复测")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
