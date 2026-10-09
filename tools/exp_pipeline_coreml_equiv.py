"""实验 C：**部署态 CoreML 产物**上的拆分等价性验证（最强证据）

【为什么必须单独做这一步】实验 A 证的是 **PyTorch fp32** 下等价（maxdiff=0）。
    但真实部署是 **CoreML + palette INT8 量化**，而 E1/C8/F8 是**三个独立量化**的
    模型 —— 量化误差可能让"拆分"与"不拆"产生差异。这一步在**真实产物**上验证。

【做法】
    F8(image[8,3,180,320], ...)                      → 6 输出（当前部署路径）
    E1(image[i]) for i in 0..7 → 堆叠 [1,8,256]
      → C8(feats, lane, dets, det_mask, vehicle_state) → 6 输出（新拆分路径）
    比较两者 6 个输出。

【判据】maxdiff < 1e-3（Lead 要求）

【附带产出】把 8 帧特征在 CoreML 里的**逐帧编码耗时**与"batch=8 一次编码"对比，
    量化"每帧只编码 1 帧"的真实收益。
"""
import os
import sys
import glob
import time
import statistics
import warnings

sys.path.insert(0, os.path.abspath("."))
import numpy as np
import torch
import coremltools as ct

warnings.simplefilter("ignore")
NFRAMES = 8
OUTS = ["steer", "throttle", "brake", "confidence", "risk", "car_heading"]


def find_models():
    found = {}
    for p in ("/var/folders/*/*/T/pipe_*/*.mlpackage", "/tmp/pipe_*/*.mlpackage"):
        for d in glob.glob(p):
            found.setdefault(os.path.basename(d).replace(".mlpackage", ""), d)
    return found


def main() -> int:
    models = find_models()
    need = ("E1", "C8", "F8")
    missing = [n for n in need if n not in models]
    if missing:
        print(f"✗ 缺少产物 {missing} —— 请先跑 tools/exp_pipeline_ane.py")
        return 1

    print("=" * 100)
    print("实验 C：CoreML 部署产物上的拆分等价性（含 palette INT8 量化）")
    print("=" * 100)

    # ★ 用 CPU_ONLY 保证数值可复现（ANE/GPU 的 fp16 累加顺序可能不同）
    e1 = ct.models.MLModel(models["E1"], compute_units=ct.ComputeUnit.CPU_ONLY)
    c8 = ct.models.MLModel(models["C8"], compute_units=ct.ComputeUnit.CPU_ONLY)
    f8 = ct.models.MLModel(models["F8"], compute_units=ct.ComputeUnit.CPU_ONLY)

    g = torch.Generator().manual_seed(7)
    imgs = torch.rand(NFRAMES, 3, 180, 320, generator=g).numpy()
    lane = (torch.rand(1, 1, 160, 160, generator=g) > 0.985).float().numpy()
    dets = torch.rand(1, 20, 12, generator=g).numpy()
    det_mask = (torch.rand(1, 20, generator=g) > 0.35).float().numpy()
    vs = torch.rand(1, 8, generator=g).numpy()

    # ── 路径 1：当前部署（F8 一次吃 8 帧原图）──
    out_f8 = f8.predict({"image": imgs, "lane": lane, "dets": dets,
                         "det_mask": det_mask, "vehicle_state": vs})

    # ── 路径 2：新拆分（E1 逐帧编码 → 缓存特征 → C8 吃 8 帧特征）──
    feats = np.concatenate([e1.predict({"image": imgs[i:i + 1]})["feat"]
                            for i in range(NFRAMES)], axis=0)      # [8,256]
    out_c8 = c8.predict({"feats": feats[None, ...], "lane": lane, "dets": dets,
                         "det_mask": det_mask, "vehicle_state": vs})

    print(f"\n  {'输出':<14}{'F8（当前）':>16}{'E1→C8（新）':>16}{'diff':>12}  判定")
    print("  " + "-" * 66)
    worst = 0.0
    for n in OUTS:
        a = float(np.asarray(out_f8[n]).flatten()[0])
        b = float(np.asarray(out_c8[n]).flatten()[0])
        d = abs(a - b)
        worst = max(worst, d)
        print(f"  {n:<14}{a:>16.8f}{b:>16.8f}{d:>12.3e}  {'✓' if d < 1e-3 else '✗'}")

    print(f"\n  ⟹ 最大偏差 {worst:.3e}  vs 判据 1e-3  →  "
          f"{'✅ 拆分等价（部署产物级验证通过）' if worst < 1e-3 else '🔴 不等价，需排查量化差异'}")

    # ── 附带：编码耗时对比（每帧 1 次 vs 8 帧一次 batch）──
    print("\n" + "=" * 100)
    print("附带：编码耗时对比（min-of-40，抗本机争抢）")
    print("=" * 100)
    for tag, m, feed in (("E1 单帧编码 [1,3,180,320]", e1, {"image": imgs[0:1]}),
                         ("F8 含 8 帧编码（全量）", f8,
                          {"image": imgs, "lane": lane, "dets": dets,
                           "det_mask": det_mask, "vehicle_state": vs})):
        for _ in range(8):
            m.predict(feed)
        ts = []
        for _ in range(40):
            t0 = time.perf_counter()
            m.predict(feed)
            ts.append((time.perf_counter() - t0) * 1000)
        ts.sort()
        print(f"  {tag:<34} min={ts[0]:>7.2f}  p50={statistics.median(ts):>7.2f} ms")
    print("\n  注：E1 每帧只跑 1 次 → 8 帧窗口的总编码成本 = 1×E1（而非 1×F8）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
