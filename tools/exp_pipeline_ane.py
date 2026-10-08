"""实验 B：拆分为「1帧图像编码器 + 8帧特征主控」两段模型的 ANE/CPU 实测

【背景】t1 四格对照（docs/迭代精修-ANE边界实测-2026-10-08.md）结论：
    8 帧 image 窗口 → ANE 编译失败，退化 CPU（16.16ms）
    1 帧 image      → ANE 2.23ms ✅
  ⚠️ 但 t1 那个"1 帧"对照里，时序分支被 trace 掉了（单帧模式下
     seq_mode=False，TemporalEncoder 根本不进图）—— **不是真实部署形态**。
     本实验按**真实部署形态**（时序分支必须在图里）重测。

【本实验的三个模型】
  E1: 编码器 image[1,3,180,320] → feat[1,256]
      —— Swift 每帧只跑这一个（历史帧特征走缓存）
  C8: 主控   feats[1,8,256] + lane + dets + det_mask + vehicle_state → 6 输出
      —— 含 TemporalEncoder + refiner(12步/4步MoE) + fusion + 3 辅助头
  F8: 原全量 image[8,3,180,320] → 6 输出（基线，用于对账 16.16ms）

【判据】ANE < CPU × 0.85 = ANE 生效（沿用 t1 协议）
【测量】ABBA 交替（ANE,CPU,CPU,ANE 取中位）抵消负载漂移；5 warmup + 30 iters
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
import coremltools.optimize.coreml as cto

import src.model_v2 as mv

warnings.simplefilter("ignore")

CKPT = "checkpoints/m9_v2/best_model.pt"
NFRAMES = 8
OUTS = ["steer", "throttle", "brake", "confidence", "risk", "car_heading"]


# ─────────────────────────── 模型构建 ───────────────────────────

def build_deploy():
    """训练态构建 → load → reparameterize（坑 6 正确顺序）。

    ⚠️ 本 checkpoint 的权重在顶层键 `model_state_dict`（不是 `model`/`state_dict`）。
       踩坑记录：按 `model`/`state_dict` 取名会**取不到权重**（拿到的是含 epoch/
       optimizer 的顶层 dict）→ load_state_dict 报 missing=298/unexpected=13 →
       模型实为**全随机初始化**，性能与精度数据全部失真。
    """
    if os.path.exists(CKPT):
        raw = torch.load(CKPT, map_location="cpu")
        sd = raw
        if isinstance(raw, dict):
            for key in ("model_state_dict", "model", "state_dict"):
                if key in raw and isinstance(raw[key], dict):
                    sd = raw[key]
                    print(f"[构建] 权重取自顶层键 '{key}'")
                    break
        has_reparam = any("rbr_reparam" in k for k in sd)
        if has_reparam:
            m = mv.build_model(deploy=True)
            res = m.load_state_dict(sd, strict=False)
        else:
            m = mv.build_model(deploy=False)
            res = m.load_state_dict(sd, strict=False)
            m.reparameterize()
        print(f"[构建] checkpoint 加载: missing={len(res.missing_keys)} "
              f"unexpected={len(res.unexpected_keys)}")
    else:
        torch.manual_seed(0)
        m = mv.build_model(deploy=False)
        m.reparameterize()
        print("[构建] ⚠ checkpoint 不存在 → 随机初始化（仅验证图结构与性能）")
    m.eval()
    return m


def _or_zero(v, width=1):
    if v is None:
        return torch.zeros(1, width)
    return v.view(-1, width) if v.dim() == 1 else v


class EncoderWrapper(torch.nn.Module):
    """E1: [1,3,180,320] → [1,256]"""

    def __init__(self, m):
        super().__init__()
        self.enc = m.image_encoder

    def forward(self, image):
        return self.enc(image)


class ControllerWrapper(torch.nn.Module):
    """C8: feats[1,8,256] + lane + dets + det_mask + vehicle_state → 6 输出

    【与 M2Model.forward 的 seq_mode 路径逐位对齐】见 src/model_v2.py:1441-1478。
    除 img_feat 来源改为"外部传入的 8 帧特征"外，其余路径（GRU → temporal_proj
    残差 → 四分支融合 → refiner → fusion_head → 三辅助头）**完全一致**。
    """

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, feats, lane, dets, det_mask, vehicle_state):
        m = self.m
        img_feat = feats[0]                       # [8,256]
        current_img_feat = img_feat[-1:]          # [1,256] 当前帧
        temporal_feat = m.temporal_encoder(img_feat.unsqueeze(0), None)
        projected = m.temporal_proj(temporal_feat)
        img_feat_cur = current_img_feat + projected

        lane_feat = m.lane_encoder(lane, 1, feats)
        det_feat = m.det_encoder(dets, det_mask, 1, feats)
        state_feat = m.state_encoder(vehicle_state, 1, feats)
        fused = torch.cat([img_feat_cur, lane_feat, det_feat, state_feat], dim=1)

        if m.refiner is not None:
            fused = m.refiner(fused)
        steer, throttle, brake = m.fusion_head(fused)

        car_heading = (m.heading_head(img_feat_cur, None)
                       if m.heading_head is not None else torch.zeros(1, 1))
        if m.risk_head is not None:
            confidence, risk = m.risk_head(fused, det_feat=det_feat,
                                           det_mask=det_mask,
                                           speed=vehicle_state[:, 0])
        else:
            confidence = risk = torch.zeros(1, 1)
        return (steer, throttle, brake, _or_zero(confidence),
                _or_zero(risk), _or_zero(car_heading))


class FullWrapper(torch.nn.Module):
    """F8: 原全量 [8,3,180,320] → 6 输出（基线）"""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, image, lane, dets, det_mask, vehicle_state):
        steer, throttle, brake, aux = self.m(
            image, lane, dets, det_mask, vehicle_state,
            camera_heading=None, return_aux=True)
        return (steer, throttle, brake,
                _or_zero(aux.get("confidence")), _or_zero(aux.get("risk")),
                _or_zero(aux.get("car_heading")))


# ─────────────────────────── 导出与测量 ───────────────────────────

def convert(traced, inputs, quant, out_names=None):
    ml = ct.convert(traced, inputs=inputs,
                    outputs=[ct.TensorType(name=n, dtype=np.float32)
                             for n in (out_names or OUTS)],
                    convert_to="mlprogram",
                    minimum_deployment_target=ct.target.macOS13,
                    compute_precision=ct.precision.FLOAT16)
    if quant == "palette":
        cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
            mode="kmeans", nbits=8, granularity="per_tensor", group_size=1))
        ml = cto.palettize_weights(ml, cfg)
    return ml


def bench(p, feed, cu, iters=30, warmup=5):
    mm = ct.models.MLModel(p, compute_units=cu)
    for _ in range(warmup):
        mm.predict(feed)
    t0 = time.perf_counter()
    for _ in range(iters):
        mm.predict(feed)
    return (time.perf_counter() - t0) / iters * 1000


def abba(p, feed):
    a1 = bench(p, feed, ct.ComputeUnit.CPU_AND_NE)
    c1 = bench(p, feed, ct.ComputeUnit.CPU_ONLY)
    c2 = bench(p, feed, ct.ComputeUnit.CPU_ONLY)
    a2 = bench(p, feed, ct.ComputeUnit.CPU_AND_NE)
    return statistics.median([a1, a2]), statistics.median([c1, c2])


def size_mb(p):
    return sum(os.path.getsize(os.path.join(r, f))
               for r, _, fs in os.walk(p) for f in fs) / 1024 / 1024


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


def main() -> int:
    m = build_deploy()
    td = tempfile.mkdtemp(prefix="pipe_")
    print(f"[临时目录] {td}\n")

    cases = []

    # ── E1：1 帧编码器 ──
    enc = EncoderWrapper(m).eval()
    tr = torch.jit.trace(enc, (torch.zeros(1, 3, 180, 320),), strict=False)
    ml = convert(tr, [ct.TensorType(name="image", shape=(1, 3, 180, 320),
                                    dtype=np.float32)], "palette", out_names=["feat"])
    p = os.path.join(td, "E1.mlpackage")
    ml.save(p)
    cases.append(("E1 编码器 1帧 [1,3,180,320]→[1,256]", p, "E1", "palette"))

    # ── C8：8 帧特征主控 ──
    ctl = ControllerWrapper(m).eval()
    tr = torch.jit.trace(ctl, (torch.zeros(1, NFRAMES, 256), torch.zeros(1, 1, 160, 160),
                               torch.zeros(1, 20, 12), torch.zeros(1, 20),
                               torch.zeros(1, 8)), strict=False)
    ml = convert(tr, [
        ct.TensorType(name="feats", shape=(1, NFRAMES, 256), dtype=np.float32),
        ct.TensorType(name="lane", shape=(1, 1, 160, 160), dtype=np.float32),
        ct.TensorType(name="dets", shape=(1, 20, 12), dtype=np.float32),
        ct.TensorType(name="det_mask", shape=(1, 20), dtype=np.float32),
        ct.TensorType(name="vehicle_state", shape=(1, 8), dtype=np.float32),
    ], "palette")
    p = os.path.join(td, "C8.mlpackage")
    ml.save(p)
    cases.append(("C8 主控 8帧特征 [1,8,256]→6输出", p, "C8", "palette"))

    # ── F8：原全量基线 ──
    full = FullWrapper(m).eval()
    tr = torch.jit.trace(full, (torch.zeros(NFRAMES, 3, 180, 320), torch.zeros(1, 1, 160, 160),
                                torch.zeros(1, 20, 12), torch.zeros(1, 20),
                                torch.zeros(1, 8)), strict=False)
    ml = convert(tr, [
        ct.TensorType(name="image", shape=(NFRAMES, 3, 180, 320), dtype=np.float32),
        ct.TensorType(name="lane", shape=(1, 1, 160, 160), dtype=np.float32),
        ct.TensorType(name="dets", shape=(1, 20, 12), dtype=np.float32),
        ct.TensorType(name="det_mask", shape=(1, 20), dtype=np.float32),
        ct.TensorType(name="vehicle_state", shape=(1, 8), dtype=np.float32),
    ], "palette")
    p = os.path.join(td, "F8.mlpackage")
    ml.save(p)
    cases.append(("F8 全量基线 8帧原图（当前部署）", p, "F8", "palette"))

    print("=" * 104)
    print("实验 B：拆分两段模型的 ANE/CPU 实测（部署态 + palette INT8，与部署一致）")
    print("=" * 104)
    print(f"  {'配置':<40}{'体积MB':>9}{'ANE ms':>10}{'CPU ms':>10}{'A/C':>8}  判定")
    print("  " + "-" * 86)
    results = {}
    for tag, path, kind, quant in cases:
        try:
            a, c = abba(path, mkfeed(kind))
            r = a / c
            results[kind] = (a, c, r, size_mb(path))
            print(f"  {tag:<40}{size_mb(path):>9.3f}{a:>10.2f}{c:>10.2f}{r:>8.2f}  "
                  f"{'✅ ANE 生效' if r < 0.85 else '🔴 退化 CPU'}")
        except Exception as e:
            print(f"  {tag:<40}{'—':>9}{'—':>10}{'—':>10}{'—':>8}  ✗ {type(e).__name__}: {str(e)[:44]}")

    # ── 流水线合成估算（串行两段 = 单帧延迟；这是**估算**不是实测）──
    print("\n" + "=" * 104)
    print("流水线合成（理论估算，基于上表实测值相加）")
    print("=" * 104)
    if "E1" in results and "C8" in results:
        e_a, e_c = results["E1"][0], results["E1"][1]
        c_a, c_c = results["C8"][0], results["C8"][1]
        f_a, f_c = results.get("F8", (float("nan"),) * 2)[:2]
        print(f"  方案① 串行两段（ANE 若两段都生效）: {e_a:.2f} + {c_a:.2f} = {e_a + c_a:.2f} ms")
        print(f"  方案① 串行两段（CPU 保守）        : {e_c:.2f} + {c_c:.2f} = {e_c + c_c:.2f} ms")
        if f_a == f_a:
            print(f"  当前基线 F8                        : ANE {f_a:.2f} / CPU {f_c:.2f} ms")
            print(f"  ⟹ 相对当前 CPU 基线提速: "
                  f"{(f_c / (e_a + c_a)):.2f}× (ANE两段) / {(f_c / (e_c + c_c)):.2f}× (CPU两段)")
    else:
        print("  ⚠️ 缺少 E1/C8 结果，无法合成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
