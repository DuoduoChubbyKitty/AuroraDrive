"""实验 D：模型 B 的 ANE 失败根因 bisect（单变量）

【背景】实测（实验 B2 + 复测 S1 产物）：
    E1  编码器 [1,3,180,320] → ANE ✅ (A/C = 0.18~0.20)
    C8  主控   [1,8,256]     → ANE 🔴 (A/C = 1.02)
    S1 的 m9_v2_ctl [1,8,256] → ANE 🔴 (A/C = 1.21)
  即：**把 8 帧原图换成 8 帧 256 维特征后，ANE 依然失败** ⟹
      t1 报告"8 帧时序窗口是根因"的表述需要**精确化**：
      真正的杀手是「时序维 N=8」这个**图结构**，不是"8 帧图像"的数据量。

【本实验隔离两个候选变量】
    ① 时序维 N（GRU 展开的循环次数）—— N=8 vs N=1
    ② refiner 步数（12 步静态展开）—— 12 vs 1
  用 2×2 四格对照，逐个单独关掉，看 ANE 是否恢复。

【判定】A/C < 0.85 = ANE 生效（沿用项目既有协议）
【产出】告诉 Lead：模型 B 有没有可能上 ANE；若不能，瓶颈就在 CPU。
"""
import os
import sys
import time
import tempfile
import statistics
import warnings

sys.path.insert(0, os.path.abspath("."))
import numpy as np
import torch
import coremltools as ct

warnings.simplefilter("ignore")

CKPT = "checkpoints/m9_v2/best_model.pt"
OUTS = ["steer", "throttle", "brake", "confidence", "risk", "car_heading"]


def load_sd():
    raw = torch.load(CKPT, map_location="cpu")
    sd = raw
    if isinstance(raw, dict):
        for k in ("model_state_dict", "model", "state_dict"):
            if k in raw and isinstance(raw[k], dict):
                sd = raw[k]
                break
    return sd


def _or_zero(v, w=1):
    if v is None:
        return torch.zeros(1, w)
    return v.view(-1, w) if v.dim() == 1 else v


class Controller(torch.nn.Module):
    """主控：feat_seq [1,N,256] + 其他分支 → 6 输出。

    N 可配（默认 8）。N=1 时 TemporalEncoder 退化为"单帧"，
    但**仍走 GRU 分支**（num_frames=1 的 GRU 展开 1 步）——用于隔离"时序维长度"。
    """

    def __init__(self, m, n_frames):
        super().__init__()
        self.m = m
        self.n = n_frames

    def forward(self, feat_seq, lane, dets, det_mask, vehicle_state):
        m = self.m
        current = feat_seq[:, -1, :]                      # [1,256]
        temporal_feat = m.temporal_encoder(feat_seq, None)
        projected = m.temporal_proj(temporal_feat)
        img_feat = current + projected
        lane_feat = m.lane_encoder(lane, 1, feat_seq)
        det_feat = m.det_encoder(dets, det_mask, 1, feat_seq)
        state_feat = m.state_encoder(vehicle_state, 1, feat_seq)
        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)
        if m.refiner is not None:
            fused = m.refiner(fused)
        steer, throttle, brake = m.fusion_head(fused)
        ch = (m.heading_head(img_feat, None) if m.heading_head is not None
              else torch.zeros(1, 1))
        if m.risk_head is not None:
            conf, risk = m.risk_head(fused, det_feat=det_feat, det_mask=det_mask,
                                     speed=vehicle_state[:, 0])
        else:
            conf = risk = torch.zeros(1, 1)
        return steer, throttle, brake, _or_zero(conf), _or_zero(risk), _or_zero(ch)


def build(n_frames, steps, sd):
    """按指定 N / refiner 步数构建并加载权重。"""
    m = mv_build(n_frames, steps, sd)
    return m


def mv_build(n_frames, steps, sd):
    import src.model_v2 as mv
    m = mv.build_model(deploy=False, num_frames=n_frames, refiner_steps=steps)
    m.load_state_dict(sd, strict=False)
    m.reparameterize()
    m.eval()
    return m


def bench(p, feed, cu, iters=40, warmup=8):
    mm = ct.models.MLModel(p, compute_units=cu)
    for _ in range(warmup):
        mm.predict(feed)
    ts = []
    for _ in range(iters):
        t0 = time.perf_counter()
        mm.predict(feed)
        ts.append((time.perf_counter() - t0) * 1000)
    ts.sort()
    return ts[0], statistics.median(ts)


def abba(p, feed):
    a1 = bench(p, feed, ct.ComputeUnit.CPU_AND_NE)
    c1 = bench(p, feed, ct.ComputeUnit.CPU_ONLY)
    c2 = bench(p, feed, ct.ComputeUnit.CPU_ONLY)
    a2 = bench(p, feed, ct.ComputeUnit.CPU_AND_NE)
    return min(a1[0], a2[0]), min(c1[0], c2[0])


def main() -> int:
    sd = load_sd()
    td = tempfile.mkdtemp(prefix="bisect_")
    print("=" * 100)
    print("实验 D：模型 B 的 ANE 失败根因 bisect（2×2 单变量四格）")
    print("=" * 100)
    print(f"  {'配置':<28}{'N':>4}{'步数':>6}{'ANE min':>10}{'CPU min':>10}{'A/C':>8}  判定")
    print("  " + "-" * 84)

    cases = [
        ("完整（部署形态）", 8, 12),
        ("仅降时序维 N=1", 1, 12),
        ("仅降 refiner 到 1 步", 8, 1),
        ("两者都降", 1, 1),
    ]
    for tag, n, steps in cases:
        try:
            m = mv_build(n, steps, sd)
            ctl = Controller(m, n).eval()
            tr = torch.jit.trace(ctl, (torch.zeros(1, n, 256), torch.zeros(1, 1, 160, 160),
                                       torch.zeros(1, 20, 12), torch.zeros(1, 20),
                                       torch.zeros(1, 8)), strict=False)
            ml = ct.convert(tr, inputs=[
                ct.TensorType(name="feat_seq", shape=(1, n, 256), dtype=np.float32),
                ct.TensorType(name="lane", shape=(1, 1, 160, 160), dtype=np.float32),
                ct.TensorType(name="dets", shape=(1, 20, 12), dtype=np.float32),
                ct.TensorType(name="det_mask", shape=(1, 20), dtype=np.float32),
                ct.TensorType(name="vehicle_state", shape=(1, 8), dtype=np.float32),
            ], outputs=[ct.TensorType(name=x, dtype=np.float32) for x in OUTS],
                convert_to="mlprogram",
                minimum_deployment_target=ct.target.macOS15,
                compute_precision=ct.precision.FLOAT16)
            p = os.path.join(td, f"n{n}_s{steps}.mlpackage")
            ml.save(p)
            feed = {"feat_seq": np.zeros((1, n, 256), np.float32),
                    "lane": np.zeros((1, 1, 160, 160), np.float32),
                    "dets": np.zeros((1, 20, 12), np.float32),
                    "det_mask": np.zeros((1, 20), np.float32),
                    "vehicle_state": np.zeros((1, 8), np.float32)}
            a, c = abba(p, feed)
            r = a / c
            print(f"  {tag:<28}{n:>4}{steps:>6}{a:>10.2f}{c:>10.2f}{r:>8.2f}  "
                  f"{'✅ ANE 生效' if r < 0.85 else '🔴 退化 CPU'}")
        except Exception as e:
            print(f"  {tag:<28}{n:>4}{steps:>6}{'—':>10}{'—':>10}{'—':>8}  "
                  f"✗ {type(e).__name__}: {str(e)[:36]}")

    print("\n" + "=" * 100)
    print("读数指引")
    print("=" * 100)
    print("  · 若「仅降时序维 N=1」→ ANE 生效：杀手是**时序维 N**（GRU 展开长度）")
    print("  · 若「仅降 refiner 到 1 步」→ ANE 生效：杀手是**refiner 静态展开**")
    print("  · 若两者都失败：ANE 对含 GRU 的图整体不友好 → 模型 B 只能吃 CPU")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
