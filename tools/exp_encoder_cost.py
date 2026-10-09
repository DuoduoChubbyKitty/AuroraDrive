#!/usr/bin/env python3
"""8 帧编码成本拆解实验（S4 性能攻坚，2026-10-09）。

【要回答的问题】
  Q1. 纯 ImageEncoder(8 帧 batch) 单独导出 → ANE 能编译吗？耗时多少？
  Q2. ImageEncoder(1 帧) 单独 → ANE 耗时多少？
  Q3. 其余部分（时序 + refiner + MoE + 融合头，吃预计算特征）单独 → ANE 耗时多少？
  Q4. 8× 编码是不是真的 8× 成本？ANE 失败是「batch 维度」还是「图太大」？
  Q5. ANE 能编译的最大 batch 是多少？（不许降总帧数，但可以跑多次小 batch）
  Q6. 空间维度（180×320 vs 更小）对 ANE 行为的影响 —— **仅诊断**。
  Q7. 「跑两次 batch=4」 vs 「一次 batch=8 CPU」哪个快？
  Q8. 8 帧编码占总延迟的百分比？

【方法】
  · 每个变体导出为独立 mlpackage，**在独立子进程里**加载 + 测量
    （CPU_ONLY 档位在本项目历史上触发过 MPSGraph 断言 SIGABRT，
     子进程隔离保证单个变体崩溃不会带走整个实验）。
  · 每个变体两种精度：fp16（ANE 原生）/ palette_kmeans INT8（部署配方，与
    tools/export_m9_v2_int8.py 逐字同款）。
  · 真机测量用 **ABBA 交替**（ANE, CPU, CPU, ANE）× rounds，取中位/p95。
  · 设备归因用 **MLComputePlan**：逐算子 preferred_compute_device + 估算成本占比
    （口径与 tools/yolopx/exp_quant_palette.py:105-131 一致）。

【产物】
  · models/exp_enc_<variant>_<precision>.mlpackage
  · /tmp/s4_encoder_cost/*.json（每变体原始数据）+ summary.json

【纪律】
  · 不改 src/、Sources/、现有导出脚本（本脚本只 import 它们，不修改）。
  · 不降步数、不降 MoE、不降帧数、不降分辨率 —— 本脚本只做**诊断与对照**。

用法：
  # 全部变体（推荐后台跑）
  ./.venv-yolo26/bin/python3 tools/exp_encoder_cost.py

  # 只跑图像编码器 batch 扫描
  ./.venv-yolo26/bin/python3 tools/exp_encoder_cost.py --only enc_b

  # 只跑 fp16
  ./.venv-yolo26/bin/python3 tools/exp_encoder_cost.py --precisions fp16
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))
if str(_ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(_ROOT / "tools"))

import numpy as np  # noqa: E402
import torch  # noqa: E402

import export_m9_v2_int8 as E  # noqa: E402  （只 import，不修改）

MODELS_DIR = _ROOT / "models"
DEFAULT_CKPT = _ROOT / "checkpoints" / "m9_v2" / "best_model.pt"
DEFAULT_WORK = Path("/tmp/s4_encoder_cost")

# ============================================================================
# 1. 变体定义
# ============================================================================
# 每个变体 = (wrapper 类名, 输入 spec 列表, 输出名列表, 说明)
# 输入名沿用部署契约（image / lane / dets / det_mask / vehicle_state），
# 组件变体用 img_feat / fused 等中间张量名。

IMG = (180, 320)


def _specs_for(variant: str) -> Tuple[List[Tuple[str, Tuple[int, ...]]], List[str]]:
    """返回 (inputs, outputs) 规格。"""
    if variant.startswith("enc_b"):
        # enc_b<N> / enc_b<N>_h<H>w<W>
        body = variant[len("enc_b"):]
        if "_h" in body:
            bs, hw = body.split("_h")
            h, w = hw.split("w")
            h, w = int(h), int(w)
        else:
            bs, h, w = body, IMG[0], IMG[1]
        b = int(bs)
        return [("image", (b, 3, h, w))], ["img_feat"]

    if variant == "temporal_only":
        return [("img_feat_seq", (1, 8, 256))], ["temporal_out"]

    if variant == "refiner_only":
        return [("fused_in", (1, 512))], ["fused_out"]

    if variant == "rest_heads":
        return [("img_feat_cur", (1, 256)),
                ("lane", (1, 1, 160, 160)),
                ("dets", (1, 20, 12)),
                ("det_mask", (1, 20)),
                ("vehicle_state", (1, 8))], ["steer", "throttle", "brake",
                                             "confidence", "risk", "car_heading"]

    if variant == "model_b":
        # ★ Lead 拆分路线的模型 B：吃**预计算的 8 帧特征**（环形缓冲），
        #   每 tick 只编码 1 个新帧（模型 A = enc_b1）。输入契约从
        #   image [8,3,180,320] 改为 img_feat_seq [1,8,256]。
        return [("img_feat_seq", (1, 8, 256)),
                ("lane", (1, 1, 160, 160)),
                ("dets", (1, 20, 12)),
                ("det_mask", (1, 20)),
                ("vehicle_state", (1, 8))], ["steer", "throttle", "brake",
                                             "confidence", "risk", "car_heading"]

    if variant in ("full_b1", "full_b8"):
        b = 1 if variant == "full_b1" else 8
        return [("image", (b, 3, IMG[0], IMG[1])),
                ("lane", (1, 1, 160, 160)),
                ("dets", (1, 20, 12)),
                ("det_mask", (1, 20)),
                ("vehicle_state", (1, 8))], ["steer", "throttle", "brake",
                                             "confidence", "risk", "car_heading"]

    if variant == "rest_no_refiner":
        return [("img_feat_cur", (1, 256)),
                ("lane", (1, 1, 160, 160)),
                ("dets", (1, 20, 12)),
                ("det_mask", (1, 20)),
                ("vehicle_state", (1, 8))], ["steer", "throttle", "brake",
                                             "confidence", "risk", "car_heading"]

    raise KeyError(f"未知变体 {variant}")


VARIANT_NOTES: Dict[str, str] = {
    "enc_b1": "纯 ImageEncoder，1 帧 → [1,256]",
    "enc_b2": "纯 ImageEncoder，batch=2",
    "enc_b4": "纯 ImageEncoder，batch=4",
    "enc_b8": "纯 ImageEncoder，batch=8（= 部署时序窗口）",
    "enc_b16": "纯 ImageEncoder，batch=16（诊断：8 是否为边界）",
    "enc_b1_h90w160": "纯 ImageEncoder，1 帧 @90×160（空间诊断，1/4 面积）",
    "enc_b8_h90w160": "纯 ImageEncoder，8 帧 @90×160（空间诊断，1/4 面积）",
    "enc_b8_h45w80": "纯 ImageEncoder，8 帧 @45×80（空间诊断，1/16 面积）",
    "temporal_only": "TemporalEncoder(GRU) + temporal_proj，吃预计算 [1,8,256]",
    "refiner_only": "IterationRefiner（12 步 + 末 4 步 MoE），[1,512] → [1,512]",
    "rest_no_refiner": "img_feat + lane/det/state + 融合头 + 三辅助头（**不含 refiner**）",
    "rest_heads": "img_feat + lane/det/state + 融合头 + 12 步 refiner/MoE + 三辅助头",
    "model_b": "★ 拆分路线模型 B：吃预计算 [1,8,256] 特征序列 + 单帧分支 → 6 输出",
    "full_b1": "完整模型，1 帧（单帧路径，时序不参与）",
    "full_b8": "完整模型，8 帧（**部署形态**）",
}

DEFAULT_VARIANTS: Tuple[str, ...] = (
    "enc_b1", "enc_b2", "enc_b4", "enc_b8", "enc_b16",
    "enc_b1_h90w160", "enc_b8_h90w160", "enc_b8_h45w80",
    "temporal_only", "refiner_only", "rest_no_refiner", "rest_heads",
    "full_b1", "full_b8", "model_b",
)


# ============================================================================
# 2. 包装模块（只读 src/model_v2.py 的公开接口）
# ============================================================================

class EncOnly(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, image):
        return self.m.image_encoder(image)


class TemporalOnly(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, img_feat_seq):
        return self.m.temporal_proj(self.m.temporal_encoder(img_feat_seq, None))


class RefinerOnly(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, fused_in):
        return self.m.refiner(fused_in)


class _HeadsBase(torch.nn.Module):
    """img_feat + 三分支 + 融合 + (可选)refiner + 三辅助头。"""

    def __init__(self, m, use_refiner: bool = True):
        super().__init__()
        self.m = m
        self.use_refiner = use_refiner

    def forward(self, img_feat_cur, lane, dets, det_mask, vehicle_state):
        m = self.m
        lane_feat = m.lane_encoder(lane, 1, img_feat_cur)
        det_feat = m.det_encoder(dets, det_mask, 1, img_feat_cur)
        state_feat = m.state_encoder(vehicle_state, 1, img_feat_cur)
        fused = torch.cat([img_feat_cur, lane_feat, det_feat, state_feat], dim=1)
        if self.use_refiner and m.refiner is not None:
            fused = m.refiner(fused)
        steer, throttle, brake = m.fusion_head(fused)

        car_heading = torch.zeros(1, 1, dtype=steer.dtype)
        confidence = torch.zeros(1, 1, dtype=steer.dtype)
        risk = torch.zeros(1, 1, dtype=steer.dtype)
        if m.heading_head is not None:
            ch = m.heading_head(img_feat_cur, None)
            car_heading = ch.reshape(1, 1)
        if m.risk_head is not None:
            try:
                conf, rk = m.risk_head(fused, det_feat=det_feat, det_mask=det_mask,
                                       speed=vehicle_state[:, 0])
                confidence = conf.reshape(1, 1)
                risk = rk.reshape(1, 1)
            except Exception:
                pass
        return steer, throttle, brake, confidence, risk, car_heading


class RestHeads(_HeadsBase):
    def __init__(self, m):
        super().__init__(m, use_refiner=True)


class RestNoRefiner(_HeadsBase):
    def __init__(self, m):
        super().__init__(m, use_refiner=False)


class ModelB(torch.nn.Module):
    """Lead 拆分路线的模型 B：吃预计算 8 帧特征 + 单帧分支 → 6 输出。

    与 M2Model.forward 的时序分支**逐字同序**：
        feat_seq [1,8,256] → temporal_encoder → temporal_proj
        → current = feat_seq[:, -1:, :] → img_feat = current + proj（残差）
        → 拼 lane/det/state → refiner(12 步 + 末 4 步 MoE) → fusion_head
    """

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, img_feat_seq, lane, dets, det_mask, vehicle_state):
        m = self.m
        current = img_feat_seq[:, -1:, :].reshape(1, -1)          # [1,256] 当前帧
        temporal_feat = m.temporal_encoder(img_feat_seq, None)     # [1,128]
        projected = m.temporal_proj(temporal_feat)                 # [1,256]
        img_feat = current + projected                             # 残差

        lane_feat = m.lane_encoder(lane, 1, img_feat)
        det_feat = m.det_encoder(dets, det_mask, 1, img_feat)
        state_feat = m.state_encoder(vehicle_state, 1, img_feat)
        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)
        if m.refiner is not None:
            fused = m.refiner(fused)
        steer, throttle, brake = m.fusion_head(fused)

        car_heading = torch.zeros(1, 1, dtype=steer.dtype)
        confidence = torch.zeros(1, 1, dtype=steer.dtype)
        risk = torch.zeros(1, 1, dtype=steer.dtype)
        if m.heading_head is not None:
            car_heading = m.heading_head(img_feat, None).reshape(1, 1)
        if m.risk_head is not None:
            try:
                conf, rk = m.risk_head(fused, det_feat=det_feat, det_mask=det_mask,
                                       speed=vehicle_state[:, 0])
                confidence = conf.reshape(1, 1)
                risk = rk.reshape(1, 1)
            except Exception:
                pass
        return steer, throttle, brake, confidence, risk, car_heading


def build_wrapper(variant: str, model):
    if variant.startswith("enc_b"):
        return EncOnly(model).eval()
    if variant == "temporal_only":
        return TemporalOnly(model).eval()
    if variant == "refiner_only":
        return RefinerOnly(model).eval()
    if variant == "rest_heads":
        return RestHeads(model).eval()
    if variant == "rest_no_refiner":
        return RestNoRefiner(model).eval()
    if variant == "model_b":
        return ModelB(model).eval()
    if variant in ("full_b1", "full_b8"):
        return E._ExportWrapper(model).eval()
    raise KeyError(variant)


# ============================================================================
# 3. 输入构造
# ============================================================================

def make_feed(specs: Sequence[Tuple[str, Tuple[int, ...]]], seed: int = 0
              ) -> Dict[str, np.ndarray]:
    """按部署契约构造确定性输入（与 E._make_inputs 同分布）。"""
    g = torch.Generator().manual_seed(seed)
    feed: Dict[str, np.ndarray] = {}
    for name, shape in specs:
        if name == "image":
            t = torch.rand(*shape, generator=g)
        elif name == "lane":
            t = (torch.rand(*shape, generator=g) > 0.985).float()
        elif name == "dets":
            t = torch.rand(*shape, generator=g)
        elif name == "det_mask":
            t = (torch.rand(*shape, generator=g) > 0.35).float()
        elif name == "vehicle_state":
            t = torch.rand(*shape, generator=g) * 2.0 - 1.0
        elif name in ("img_feat", "img_feat_cur", "fused_in"):
            t = torch.randn(*shape, generator=g)
        elif name == "img_feat_seq":
            t = torch.randn(*shape, generator=g)
        else:
            t = torch.rand(*shape, generator=g)
        feed[name] = t.detach().cpu().numpy().astype(np.float32)
    return feed


# ============================================================================
# 4. 转换 / 量化 / 测量
# ============================================================================

def convert(traced, specs, out_names, target):
    """fp16 图，IO 恒 fp32（与 E._convert_fp16 同款，只是输入/输出名可变）。"""
    import coremltools as ct
    import warnings as _w
    inputs = [ct.TensorType(name=n, shape=s, dtype=np.float32) for n, s in specs]
    outputs = [ct.TensorType(name=n, dtype=np.float32) for n in out_names]
    with _w.catch_warnings():
        _w.simplefilter("ignore")
        return ct.convert(traced, source="pytorch", convert_to="mlprogram",
                          minimum_deployment_target=target,
                          compute_precision=ct.precision.FLOAT16,
                          inputs=inputs, outputs=outputs)


def bench_one(model, feed, warmup: int, rounds: int, iters: int) -> Dict[str, float]:
    """单模型计时：warmup 后 rounds×iters 次，返回中位/p95/min/max。"""
    for _ in range(warmup):
        model.predict(feed)
    samples: List[float] = []
    for _ in range(rounds):
        for _ in range(iters):
            t0 = time.perf_counter()
            model.predict(feed)
            samples.append((time.perf_counter() - t0) * 1000.0)
    samples.sort()
    return {
        "median_ms": statistics.median(samples),
        "mean_ms": statistics.fmean(samples),
        "p95_ms": samples[min(int(len(samples) * 0.95), len(samples) - 1)],
        "min_ms": samples[0],
        "max_ms": samples[-1],
        "n": len(samples),
    }


def abba(ane_model, cpu_model, feed, warmup: int, rounds: int, iters: int
         ) -> Dict[str, Dict[str, float]]:
    """ABBA 交替：每轮 [ANE, CPU, CPU, ANE]，抵消本机负载漂移。"""
    for _ in range(warmup):
        ane_model.predict(feed)
        cpu_model.predict(feed)
    a: List[float] = []
    c: List[float] = []
    for _ in range(rounds):
        for _ in range(iters):
            t0 = time.perf_counter()
            ane_model.predict(feed)
            a.append((time.perf_counter() - t0) * 1000.0)
        for _ in range(2):
            for _ in range(iters):
                t0 = time.perf_counter()
                cpu_model.predict(feed)
                c.append((time.perf_counter() - t0) * 1000.0)
        for _ in range(iters):
            t0 = time.perf_counter()
            ane_model.predict(feed)
            a.append((time.perf_counter() - t0) * 1000.0)

    def stat(s: List[float]) -> Dict[str, float]:
        s = sorted(s)
        return {"median_ms": statistics.median(s), "mean_ms": statistics.fmean(s),
                "p95_ms": s[min(int(len(s) * 0.95), len(s) - 1)],
                "min_ms": s[0], "max_ms": s[-1], "n": len(s)}

    return {"ane": stat(a), "cpu": stat(c)}


def device_census(compiled_path: str, units=None) -> Dict:
    """MLComputePlan 逐算子设备落点 + 估算成本占比。"""
    import coremltools as ct
    from coremltools.models.compute_plan import MLComputePlan
    info: Dict = {}
    try:
        if units is None:
            units = ct.ComputeUnit.CPU_AND_NE
        plan = MLComputePlan.load_from_path(compiled_path, compute_units=units)
        ops = list(plan.model_structure.program.functions["main"].block.operations)
        info["n_ops"] = len(ops)
        info["op_types"] = dict(collections.Counter(o.operator_name for o in ops).most_common(8))
        dev = collections.Counter()
        cost: Dict[str, float] = collections.defaultdict(float)
        for o in ops:
            if o.operator_name == "const":
                continue
            try:
                u = plan.get_compute_device_usage_for_mlprogram_operation(o)
                d = type(u.preferred_compute_device).__name__ \
                    .replace("ML", "").replace("ComputeDevice", "")
            except Exception:
                d = "unreported"
            dev[d] += 1
            try:
                cc = plan.get_estimated_cost_for_mlprogram_operation(o)
                if cc is not None:
                    cost[d] += float(cc.weight)
            except Exception:
                pass
        info["device_ops"] = dict(dev)
        info["cost_share"] = {k: round(v, 4) for k, v in cost.items()}
    except Exception as exc:
        info["error"] = f"{type(exc).__name__}: {str(exc)[:160]}"
    return info


def load_avg() -> List[float]:
    try:
        return [round(float(x), 2) for x in os.getloadavg()]
    except Exception:
        return []


# ============================================================================
# 5. 子进程 worker：导出 + 测量一个 (variant, precision)
# ============================================================================

def worker_main(args) -> int:
    import coremltools as ct

    variant, precision = args._worker, args.precision
    specs, out_names = _specs_for(variant)
    target = {"macOS13": ct.target.macOS13, "macOS14": ct.target.macOS14,
              "macOS15": ct.target.macOS15}[args.target]

    res: Dict = {
        "variant": variant, "precision": precision,
        "note": VARIANT_NOTES.get(variant, ""),
        "inputs": [{"name": n, "shape": list(s)} for n, s in specs],
        "outputs": list(out_names),
        "host": {"load_avg_start": load_avg(), "torch": torch.__version__,
                 "coremltools": ct.__version__},
    }

    # ---- 构建模型（真权重；缺失参数如实记录）----
    t0 = time.time()
    sd = E._load_state_dict(Path(args.src))
    model, lr = E._build_and_load(sd)
    own = dict(model.state_dict())
    missing = [k for k in own if k not in sd]
    res["weight_load_s"] = round(time.time() - t0, 2)
    res["missing_keys"] = len(missing)
    res["missing_params"] = int(sum(own[k].numel() for k in missing))
    res["total_params"] = int(sum(v.numel() for v in own.values()))
    res["missing_ratio_pct"] = round(100.0 * res["missing_params"]
                                     / max(res["total_params"], 1), 2)
    res["missing_by_prefix"] = dict(collections.Counter(k.split(".")[0] for k in missing))

    wrapper = build_wrapper(variant, model)
    feed = make_feed(specs, seed=args.seed)
    torch_inputs = [torch.from_numpy(feed[n]) for n, _ in specs]

    # ---- 导出 ----
    t0 = time.time()
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, tuple(torch_inputs), strict=False)
    res["trace_s"] = round(time.time() - t0, 2)

    t0 = time.time()
    try:
        mlmodel = convert(traced, specs, out_names, target)
    except Exception as exc:
        res["convert_error"] = f"{type(exc).__name__}: {str(exc)[:300]}"
        _write(args.json_out, res)
        return 1
    res["convert_s"] = round(time.time() - t0, 2)

    # ---- 量化（部署配方，与 export_m9_v2_int8.py 同款）----
    if precision != "fp16":
        t0 = time.time()
        mlmodel, notes = E.quantize(mlmodel, precision, args.group_size,
                                    E.DEFAULT_PRESERVE_PREFIXES, not args.no_preserve)
        res["quantize_s"] = round(time.time() - t0, 2)
        res["quant_notes"] = notes

    out_path = Path(args.out_dir) / f"exp_enc_{variant}_{precision}.mlpackage"
    if out_path.exists():
        import shutil
        shutil.rmtree(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))
    res["path"] = str(out_path)
    res["total_mb"] = round(E._dir_bytes(out_path) / 1048576.0, 3)

    # ---- 加载 + 冷启动 ----
    try:
        t0 = time.perf_counter()
        m_ane = ct.models.MLModel(str(out_path), compute_units=ct.ComputeUnit.CPU_AND_NE)
        res["load_ane_ms"] = round((time.perf_counter() - t0) * 1000.0, 1)
        t0 = time.perf_counter()
        m_ane.predict(feed)
        res["cold_ane_ms"] = round((time.perf_counter() - t0) * 1000.0, 2)
    except Exception as exc:
        res["ane_load_error"] = f"{type(exc).__name__}: {str(exc)[:300]}"
        _write(args.json_out, res)
        return 2

    # ---- 设备落点普查（静态，CPU_AND_NE 视角）----
    res["census"] = device_census(m_ane.get_compiled_model_path(),
                                 ct.ComputeUnit.CPU_AND_NE)
    res["census_all"] = device_census(m_ane.get_compiled_model_path(),
                                     ct.ComputeUnit.ALL)

    # ---- ABBA 真机计时 ----
    try:
        t0 = time.perf_counter()
        m_cpu = ct.models.MLModel(str(out_path), compute_units=ct.ComputeUnit.CPU_ONLY)
        res["load_cpu_ms"] = round((time.perf_counter() - t0) * 1000.0, 1)
        res["abba"] = abba(m_ane, m_cpu, feed, args.warmup, args.rounds, args.iters)
    except Exception as exc:
        res["cpu_error"] = f"{type(exc).__name__}: {str(exc)[:300]}"

    # ---- ALL 档位交叉核对 ----
    if not args.no_all:
        try:
            m_all = ct.models.MLModel(str(out_path), compute_units=ct.ComputeUnit.ALL)
            res["all"] = bench_one(m_all, feed, args.warmup, max(1, args.rounds // 2),
                                   max(1, args.iters // 2))
        except Exception as exc:
            res["all_error"] = f"{type(exc).__name__}: {str(exc)[:200]}"

    res["host"]["load_avg_end"] = load_avg()

    # ---- 判定 ----
    ab = res.get("abba")
    if ab:
        a, c = ab["ane"]["median_ms"], ab["cpu"]["median_ms"]
        res["verdict"] = {
            "ane_median_ms": a, "cpu_median_ms": c,
            "ane_over_cpu": round(a / c, 3) if c else None,
            "speedup_x": round(c / a, 2) if a else None,
            "ane_effective": bool(a < c * 0.95),
            "ne_ops": (res.get("census") or {}).get("device_ops", {}).get("NeuralEngine", 0),
            "ne_cost_share": (res.get("census") or {}).get("cost_share", {}).get("NeuralEngine"),
        }

    _write(args.json_out, res)
    print(f"[S4] {variant:<16} {precision:<16} "
          f"ANE {ab['ane']['median_ms']:.3f}ms / CPU {ab['cpu']['median_ms']:.3f}ms"
          if ab else f"[S4] {variant} {precision} 无计时", flush=True)
    return 0


def _write(path: str, payload: Dict) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


# ============================================================================
# 6. 父进程：编排
# ============================================================================

def parent_main(args) -> int:
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    if args.only:
        # 精确名优先；未命中时退化为前缀匹配（"enc_b" → 全部编码器变体）
        variants = [v for v in DEFAULT_VARIANTS if v in args.only]
        if not variants:
            variants = [v for v in DEFAULT_VARIANTS
                        if any(v.startswith(p) for p in args.only)]
    else:
        variants = list(DEFAULT_VARIANTS)

    print("=" * 88)
    print(" S4 · 8 帧编码成本拆解（真机 CoreML 导出 + ABBA 实测）")
    print("=" * 88)
    print(f"[S4] 变体 {len(variants)} 个 × 精度 {args.precisions}")
    print(f"[S4] 权重 {args.src}")
    print(f"[S4] 产物 {args.out_dir}/exp_enc_*.mlpackage ；数据 {work}")

    results: List[Dict] = []
    for variant in variants:
        for precision in args.precisions:
            json_out = work / f"{variant}__{precision}.json"
            if json_out.exists() and not args.force:
                print(f"[S4] 跳过（已有）{variant} / {precision}")
                results.append(json.loads(json_out.read_text(encoding="utf-8")))
                continue
            cmd = [sys.executable, str(Path(__file__).resolve()),
                   "--_worker", variant, "--precision", precision,
                   "--json-out", str(json_out), "--out-dir", str(args.out_dir),
                   "--src", str(args.src), "--target", args.target,
                   "--group-size", str(args.group_size),
                   "--warmup", str(args.warmup), "--rounds", str(args.rounds),
                   "--iters", str(args.iters), "--seed", str(args.seed)]
            if args.no_preserve:
                cmd.append("--no-preserve")
            if args.no_all:
                cmd.append("--no-all")
            print(f"\n[S4] ▶ {variant} / {precision} …", flush=True)
            t0 = time.time()
            proc = subprocess.run(cmd, capture_output=True, text=True)
            dt = time.time() - t0
            if json_out.exists():
                r = json.loads(json_out.read_text(encoding="utf-8"))
                r["wall_s"] = round(dt, 1)
            else:
                r = {"variant": variant, "precision": precision, "wall_s": round(dt, 1),
                     "worker_crash": True, "returncode": proc.returncode,
                     "stderr_tail": (proc.stderr or "")[-600:]}
            if proc.returncode != 0 and not r.get("abba"):
                r.setdefault("stderr_tail", (proc.stderr or "")[-600:])
            results.append(r)
            _print_row(r)

    summary = {"ckpt": str(args.src), "precisions": args.precisions,
               "variants": variants, "results": results,
               "host": {"load_avg": load_avg(), "python": sys.version.split()[0]}}
    (work / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[S4] 汇总：{work / 'summary.json'}")
    _print_table(results)
    return 0


def _print_row(r: Dict) -> None:
    ab = r.get("abba")
    name = f"{r['variant']}/{r['precision']}"
    if ab:
        v = r.get("verdict", {})
        ne = v.get("ne_ops")
        print(f"[S4] ◀ {name:<34} ANE {ab['ane']['median_ms']:7.3f} "
              f"(p95 {ab['ane']['p95_ms']:7.3f})  CPU {ab['cpu']['median_ms']:7.3f} "
              f"| 加速 {v.get('speedup_x')}× | NE算子 {ne} | {r.get('total_mb')}MB")
    elif r.get("ane_load_error"):
        print(f"[S4] ◀ {name:<34} 🔴 ANE 加载失败：{r['ane_load_error'][:90]}")
    elif r.get("convert_error"):
        print(f"[S4] ◀ {name:<34} 🔴 转换失败：{r['convert_error'][:90]}")
    else:
        print(f"[S4] ◀ {name:<34} ⚠ 无计时 rc={r.get('returncode')} "
              f"{(r.get('stderr_tail') or '')[-120:]}")


def _print_table(results: Sequence[Dict]) -> None:
    print("\n" + "=" * 108)
    print(f"{'变体':<18}{'精度':<16}{'MB':>7}{'ANE中位':>10}{'ANE p95':>10}"
          f"{'CPU中位':>10}{'加速':>8}{'NE算子':>8}{'ANE生效':>9}")
    print("-" * 108)
    for r in results:
        ab = r.get("abba")
        v = r.get("verdict", {})
        mb = f"{r.get('total_mb', float('nan')):.2f}" if r.get("total_mb") else "n/a"
        if ab:
            print(f"{r['variant']:<18}{r['precision']:<16}{mb:>7}"
                  f"{ab['ane']['median_ms']:>10.3f}{ab['ane']['p95_ms']:>10.3f}"
                  f"{ab['cpu']['median_ms']:>10.3f}{str(v.get('speedup_x')):>8}"
                  f"{str(v.get('ne_ops')):>8}{'✅' if v.get('ane_effective') else '🔴':>8}")
        else:
            reason = "转换失败" if r.get("convert_error") else (
                "ANE加载失败" if r.get("ane_load_error") else "无数据")
            print(f"{r['variant']:<18}{r['precision']:<16}{mb:>7}{'—':>10}{'—':>10}"
                  f"{'—':>10}{'—':>8}{'—':>8}{reason:>8}")
    print("=" * 108)


# ============================================================================
# 7. 入口
# ============================================================================

def main() -> int:
    ap = argparse.ArgumentParser(description="8 帧编码成本拆解（S4）")
    ap.add_argument("--src", default=str(DEFAULT_CKPT))
    ap.add_argument("--out-dir", default=str(MODELS_DIR))
    ap.add_argument("--work", default=str(DEFAULT_WORK))
    ap.add_argument("--only", nargs="*", default=None, help="只跑指定前缀的变体")
    ap.add_argument("--precisions", nargs="*", default=["fp16", "palette_kmeans"])
    ap.add_argument("--group-size", type=int, default=1)
    ap.add_argument("--no-preserve", action="store_true")
    ap.add_argument("--target", default="macOS13", choices=["macOS13", "macOS14", "macOS15"])
    ap.add_argument("--warmup", type=int, default=8)
    ap.add_argument("--rounds", type=int, default=4)
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-all", action="store_true")
    ap.add_argument("--force", action="store_true")
    # worker 侧参数
    ap.add_argument("--_worker", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--precision", default="fp16", help=argparse.SUPPRESS)
    ap.add_argument("--json-out", default="/tmp/s4_encoder_cost/_w.json", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args._worker:
        return worker_main(args)
    return parent_main(args)


if __name__ == "__main__":
    raise SystemExit(main())
