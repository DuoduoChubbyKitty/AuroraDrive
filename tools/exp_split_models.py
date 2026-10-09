#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
双模型拆分实验（S1 性能攻坚）：把 M2Model 拆成「8 帧图像编码器」+「单帧主控」两个 CoreML 模型

================================================================================
0. 要回答的问题（Lead 派单）
================================================================================
主驾驶模型 V2 当前 p95 = 20.95~29.28 ms，硬红线要求 **p95 ≤ 16ms**。
已知（Lead 实测，本脚本不重复）：
    · 1 帧 + palette INT8  → ANE 2.23 ms ✅
    · 8 帧 + palette INT8  → MILCompilerForANE error → CPU 16.16 ms
    · 8 帧 + fp16          → MILCompilerForANE error → CPU 15.23 ms
    · 结论：**8 帧时序窗口是 ANE 编译失败的根因**，与步数/量化无关。

本脚本验证「双模型拆分」能否把 8 帧成本隔离出去、让主控图回到单帧：

    模型 A（图像编码器）: image [8,3,180,320] → img_feat [1,256]
    模型 B（主控）      : img_feat [1,256] + lane + dets + det_mask + vehicle_state → 6 输出

================================================================================
1. ★ 拆分点的选择依据（必须与 M2Model.forward 的时序模式逐位一致）
================================================================================
`src/model_v2.py:1430-1456` 的时序模式逻辑（image=[8,...] 而 lane/det/state 的
batch=1 时触发）：

    img_feat   = image_encoder(image)                 # [8,256]
    current    = img_feat[-1:]                        # [1,256] 取最后一帧
    temporal   = temporal_encoder(img_feat.unsqueeze(0), None)   # [1,128]
    projected  = temporal_proj(temporal)              # [1,256]
    img_feat   = current + projected                  # [1,256]  ← 拆分点在此
    fused      = cat([img_feat, lane_feat, det_feat, state_feat])  # [1,512]
    fused      = refiner(fused)                       # 12 步 + 4 步 MoE
    steer/throttle/brake = fusion_head(fused)
    car_heading = heading_head(img_feat, None)
    confidence, risk = risk_head(fused, det_feat, det_mask, speed)

→ **A = image_encoder + temporal_encoder + temporal_proj + 末帧残差**，输出 [1,256]
→ **B = lane/det/state 编码 + refiner + fusion_head + heading_head + risk_head**
这样 B 的输入里**完全没有时间维**（img_feat 已是 [1,256]），是真正的单帧图。

================================================================================
2. ★ ANE 是否生效：双重权威判据（不靠"耗时比值"猜）
================================================================================
判据① **stderr 抓 MILCompilerForANE**：CoreML 的 ANE 编译失败是**静默**的
      （predict 照样成功、只是退化到 CPU），但错误信息会打到进程 stderr：
          `E5RT encountered an STL exception. msg = MILCompilerForANE error:
           failed to compile ANE model using ANEF. Error=_ANECompiler : ANECCompile() FAILED.`
      → 本脚本用**子进程**跑 `anecheck` 模式并捕获 stderr，逐模型给出确定性判定。
      ⚠️ 触发时机：`MLComputePlan.load_from_path()`（不是 MLModel 构造，也不是 predict）。

判据② **MLComputePlan 算子落点直方图**：直接问 CoreML 每个算子打算跑在哪。
      实测锚点（本机 Apple M3 / macOS 26.6.2 / coremltools 8.3）：
          1 帧 int8（已知 ANE 生效）→ {"NeuralEngine": 86, "UNKNOWN": 184}，stderr 干净
          8 帧 fp16（已知 ANE 失败）→ {"CPU": 479, "UNKNOWN": 459}，stderr 有 ANECCompile FAILED
      → 两者同时看，结论才可靠。

================================================================================
3. 测量协议
================================================================================
    · **ABBA 交替**：NE, CPU, CPU, NE —— 抵消本机负载漂移（MacBook Air 无风扇，
      已知会热漂移；docs/迭代精修-ANE边界实测-2026-10-08.md §6 记录单次波动可达 2×）
    · 每档 warmup + N 次计时，取**中位数**
    · 记录 uptime / load average（测前测后各一次）
    · 全部真机实测，**无估算**

================================================================================
4. 用法
================================================================================
    # 全流程（构建 → 等价性 → 导出 → ANE 判定 → ABBA 计时 → 串联）
    ./.venv-yolo26/bin/python3 tools/exp_split_models.py all

    # 分步
    ./.venv-yolo26/bin/python3 tools/exp_split_models.py build      # 只构建 + 等价性
    ./.venv-yolo26/bin/python3 tools/exp_split_models.py export     # 只导出
    ./.venv-yolo26/bin/python3 tools/exp_split_models.py bench      # 只计时
    ./.venv-yolo26/bin/python3 tools/exp_split_models.py anecheck <path>   # 子进程用

产物：models/exp_split_*/  +  /tmp/exp_split_report.json
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
import warnings
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import torch  # noqa: E402
import torch.nn as nn  # noqa: E402

warnings.simplefilter("ignore")

OUT_ROOT = _ROOT / "models" / "exp_split"
REPORT = Path("/tmp/exp_split_report.json")

#: 契约（与 tools/export_m9_v2_int8.py 逐字一致）
INPUT_NAMES_FULL: Tuple[str, ...] = ("image", "lane", "dets", "det_mask", "vehicle_state")
OUTPUT_NAMES: Tuple[str, ...] = ("steer", "throttle", "brake",
                                 "confidence", "risk", "car_heading")
CKPT = _ROOT / "checkpoints" / "m9_v2" / "best_model.pt"


# ============================================================================
# 1. 拆分的两个（三个）包装模块
# ============================================================================

class SplitA(nn.Module):
    """模型 A（完整版）：image [N,3,180,320] → img_feat [1,256]。

    内容 = ImageEncoder + TemporalEncoder + temporal_proj + 末帧残差，
    与 M2Model.forward 的 seq_mode 分支逐位一致（src/model_v2.py:1442-1456）。

    ⚠️ TemporalEncoder.forward 强制要求 seq_len == num_frames（见 temporal.py
       的 shape 校验），所以 N 必须等于构造时的 num_frames（默认 8）。
       若要跑 batch=4，请用 SplitACNN（纯卷积，无时序约束）。
    """

    def __init__(self, m):
        super().__init__()
        self.image_encoder = m.image_encoder
        self.temporal_encoder = m.temporal_encoder
        self.temporal_proj = m.temporal_proj

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        img_feat = self.image_encoder(image)                       # [N,256]
        current = img_feat[-1:]                                    # [1,256]
        temporal = self.temporal_encoder(img_feat.unsqueeze(0), None)   # [1,128]
        projected = self.temporal_proj(temporal)                   # [1,256]
        return current + projected                                 # [1,256]


class SplitACNN(nn.Module):
    """模型 A-CNN：image [N,3,180,320] → feats [N,256]（**纯卷积，无时序**）。

    用途：ANE 边界扫描。若 batch=8 的完整 A 编译失败，用它隔离
    「是卷积 batch=8 撑不住，还是 GRU 撑不住」。
    batch=4/2 的变体也走这个类（跑多次再拼），**不降总帧数**。
    """

    def __init__(self, m):
        super().__init__()
        self.image_encoder = m.image_encoder

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return self.image_encoder(image)


class SplitATemporal(nn.Module):
    """模型 A-T：feats [8,256] → img_feat [1,256]（**只有时序部分**）。

    用途：三模型拆分的中间件。若 A-CNN(8) 能上 ANE 而 A(完整) 不能，
    说明瓶颈在 GRU → 把 GRU 单独拆出来（参数量仅 ~50K，图极小）。
    """

    def __init__(self, m):
        super().__init__()
        self.temporal_encoder = m.temporal_encoder
        self.temporal_proj = m.temporal_proj

    def forward(self, feats: torch.Tensor) -> torch.Tensor:
        current = feats[-1:]                                       # [1,256]
        temporal = self.temporal_encoder(feats.unsqueeze(0), None)  # [1,128]
        return current + self.temporal_proj(temporal)              # [1,256]


class SplitB(nn.Module):
    """模型 B（主控）：img_feat [1,256] + 4 路感知 → 6 输出。

    复刻 M2Model.forward 从 `fused = cat(...)` 起的全部逻辑
    （src/model_v2.py:1458-1511），**只把 img_feat 改为外部输入**。

    ⚠️ 逐位一致的关键点（改这里必须同步改 model_v2.py）：
       · lane/det/state 三个 encoder 的 `ref` 参数在原模型里传的是 `image`；
         这里传 `img_feat`（同为 float32，仅用于 _zero_like 取 device/dtype）
         —— 数值上等价，因为 _zero_like 只用它取 device/dtype。
       · car_heading 用**后时序的** img_feat（原模型 :1494 传的就是被重绑过的
         img_feat，即 current + projected）→ 本类输入正是它，天然对齐。
       · risk_head 的 speed = vehicle_state[:,0]。
       · camera_heading=None（与 _ExportWrapper 一致）。
    """

    def __init__(self, m):
        super().__init__()
        self.lane_encoder = m.lane_encoder
        self.det_encoder = m.det_encoder
        self.state_encoder = m.state_encoder
        self.refiner = m.refiner
        self.fusion_head = m.fusion_head
        self.heading_head = m.heading_head
        self.risk_head = m.risk_head

    def forward(self, img_feat, lane, dets, det_mask, vehicle_state):
        batch_size = img_feat.shape[0]

        lane_feat = self.lane_encoder(lane, batch_size, img_feat)
        det_feat = self.det_encoder(dets, det_mask, batch_size, img_feat)
        state_feat = self.state_encoder(vehicle_state, batch_size, img_feat)

        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)  # [1,512]
        if self.refiner is not None:
            fused = self.refiner(fused)
        steer, throttle, brake = self.fusion_head(fused)

        def _col(v):
            """把 [B] / [B,1] 统一成 [B,1]（与 _ExportWrapper._or_zero 同款）。"""
            if v is None:
                return torch.zeros(batch_size, 1, dtype=steer.dtype, device=steer.device)
            return v.view(-1, 1) if v.dim() == 1 else v

        car_heading = None
        if self.heading_head is not None:
            try:
                car_heading = self.heading_head(img_feat, None)
            except Exception:
                car_heading = None

        confidence = risk = None
        if self.risk_head is not None:
            try:
                confidence, risk = self.risk_head(
                    fused, det_feat=det_feat, det_mask=det_mask,
                    speed=(vehicle_state[:, 0] if vehicle_state is not None
                           and vehicle_state.dim() == 2 and vehicle_state.shape[1] > 0
                           else None))
            except Exception:
                pass

        return (steer, throttle, brake, _col(confidence), _col(risk), _col(car_heading))


class FullWrapper(nn.Module):
    """完整模型（单模型基线），6 输出扁平化 —— 与 export_m9_v2_int8.py 的
    `_ExportWrapper` 逐字一致，用于等价性对照与总耗时基线。"""

    def __init__(self, m):
        super().__init__()
        self.model = m

    def forward(self, image, lane, dets, det_mask, vehicle_state):
        steer, throttle, brake, aux = self.model(
            image, lane, dets, det_mask, vehicle_state,
            camera_heading=None, return_aux=True)

        def _or_zero(v, width: int = 1):
            if v is None:
                return torch.zeros(1, width, dtype=steer.dtype, device=steer.device)
            return v.view(-1, width) if v.dim() == 1 else v

        return (steer, throttle, brake,
                _or_zero(aux.get("confidence")), _or_zero(aux.get("risk")),
                _or_zero(aux.get("car_heading")))


# ============================================================================
# 2. 构建 / 加载
# ============================================================================

def _load_state_dict(src: Path) -> Dict[str, torch.Tensor]:
    ckpt = torch.load(src, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    for k in [k for k in sd if k.startswith("lane_steer_probe.")]:
        del sd[k]
    return sd


def build(seed: Optional[int] = None, live_all_paths: bool = False):
    """构建 M2Model（部署态：已重参数化）。

    Args:
        seed: 若给定 → 全模型重新随机初始化（用于"所有通路都活着"的等价性测试）
        live_all_paths: 把零初始化的残差投影（refiner_proj / expert_out_proj /
            temporal_proj）显式扰动成非零小量。
            ★ 为什么必需：这三个投影**零初始化**，导致 refiner 12 步恒等、
              MoE 恒等、时序残差恒等 —— 不扰动的话"拆分等价性"根本没测到
              这几条路径（测了个寂寞）。扰动后才真正验证整图。
    """
    from src.model_v2 import build_model

    print(f"[build] 构建 deploy=False, num_steps=12, moe_steps=[9,10,11,12]")
    model = build_model(deploy=False, num_steps=12, moe_steps=[9, 10, 11, 12])

    if seed is not None:
        g = torch.Generator().manual_seed(seed)
        for p in model.parameters():
            p.data = torch.randn(p.shape, generator=g) * 0.05
        print(f"[build] ⚠ 全模型随机重初始化（seed={seed}）—— 仅用于等价性/图结构验证")
    else:
        sd = _load_state_dict(CKPT)
        res = model.load_state_dict(sd, strict=False)
        print(f"[build] 加载 {CKPT.name}: missing={len(res.missing_keys)} "
              f"unexpected={len(res.unexpected_keys)}")
        print(f"[build]   ⚠ checkpoint 不含 refiner/temporal/risk/heading 权重"
              f"（与 models/m9_v2.mlpackage 同源，65.7% 随机）→ 仅供性能/图结构验证")

    if live_all_paths:
        g = torch.Generator().manual_seed(1234)
        n = 0
        with torch.no_grad():
            for name, mod in (("refiner.refiner_proj", model.refiner.refiner_proj),
                              ("refiner.expert_out_proj", model.refiner.expert_out_proj),
                              ("temporal_proj", model.temporal_proj)):
                if mod is None:
                    continue
                mod.weight.data = torch.randn(mod.weight.shape, generator=g) * 0.05
                mod.bias.data = torch.randn(mod.bias.shape, generator=g) * 0.05
                n += 1
            if model.refiner is not None:
                for e in model.refiner.experts:
                    for p in e.parameters():
                        p.data = torch.randn(p.shape, generator=g) * 0.05
                n += 1
        print(f"[build] ★ live_all_paths：扰动 {n} 组零初始化投影 + 专家 → 全通路激活")

    model.eval()
    model.reparameterize()
    print(f"[build] reparameterize() 完成（部署态），参数量 "
          f"{sum(p.numel() for p in model.parameters()):,}")
    return model


# ============================================================================
# 3. 数值等价性：完整模型 vs A→B 串联
# ============================================================================

def _cases(c) -> Dict[str, list]:
    """契约边界用例（空输入是真实驾驶常态，必须一起验）。"""
    g = torch.Generator().manual_seed(0)
    img = torch.rand(8, 3, c["img_h"], c["img_w"], generator=g)
    lane = (torch.rand(1, 1, c["lane_size"], c["lane_size"], generator=g) > 0.985).float()
    dets = torch.rand(1, c["num_dets"], c["det_feat_dim"], generator=g)
    det_mask = (torch.rand(1, c["num_dets"], generator=g) > 0.35).float()
    state = torch.rand(1, c["state_dim"], generator=g) * 2.0 - 1.0
    return {
        "normal":     [img, lane, dets, det_mask, state],
        "no_dets":    [img, lane, torch.zeros_like(dets), torch.zeros_like(det_mask), state],
        "no_lane":    [img, torch.zeros_like(lane), dets, det_mask, state],
        "zero_state": [img, lane, dets, det_mask, torch.zeros_like(state)],
        "all_empty":  [img, torch.zeros_like(lane), torch.zeros_like(dets),
                       torch.zeros_like(det_mask), torch.zeros_like(state)],
        "saturated":  [torch.ones_like(img), torch.ones_like(lane), torch.ones_like(dets),
                       torch.ones_like(det_mask), torch.ones_like(state)],
    }


def check_equivalence(model) -> Dict:
    """完整模型 forward vs A→B 串联，逐用例比 maxdiff。

    这是**拆分正确性**的硬证据：maxdiff 必须 ~1e-7（float32 精度极限），
    因为两侧跑的是同一份权重、同一批算子，只是被切成两次调用。
    """
    full = FullWrapper(model).eval()
    a = SplitA(model).eval()
    b = SplitB(model).eval()

    c = {"img_h": 180, "img_w": 320, "lane_size": 160, "num_dets": 20,
         "det_feat_dim": 12, "state_dim": 8}
    def _flat(outs):
        """把 6 个张量摊平成 6 个 float 标量（契约是每输出 1 个数）。"""
        return [float(t.reshape(-1)[0]) for t in outs]

    out = {}
    worst = 0.0
    with torch.no_grad():
        for name, ins in _cases(c).items():
            ref = _flat(full(*ins))
            feat = a(ins[0])
            got = _flat(b(feat, *ins[1:]))
            d = max(abs(x - y) for x, y in zip(ref, got))
            # 同时报 img_feat 这一中间量的量级（确认它没被拆成 0）
            out[name] = {"maxdiff": d, "full": [round(v, 8) for v in ref],
                         "split": [round(v, 8) for v in got],
                         "img_feat_absmax": float(feat.abs().max()),
                         "img_feat_norm": float(feat.norm())}
            worst = max(worst, d)
            print(f"[equiv]   {name:<11} maxdiff={d:.3e}  |img_feat|max={out[name]['img_feat_absmax']:.4f}")
    out["_worst"] = worst
    print(f"[equiv] ★ 最差 maxdiff = {worst:.3e}  "
          f"{'✅ 等价（<1e-3）' if worst < 1e-3 else '🔴 不等价'}")
    return out


# ============================================================================
# 4. 导出
# ============================================================================

def _convert(traced, inputs: Sequence[Tuple[str, tuple]], outputs: Sequence[str],
             target, precision="fp16"):
    import coremltools as ct
    in_types = [ct.TensorType(name=n, shape=s, dtype=np.float32) for n, s in inputs]
    out_types = [ct.TensorType(name=n, dtype=np.float32) for n in outputs]
    prec = ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32
    return ct.convert(traced, source="pytorch", convert_to="mlprogram",
                      minimum_deployment_target=target,
                      compute_precision=prec,
                      inputs=in_types, outputs=out_types)


def _palettize(mlmodel, group_size: int = 1):
    import coremltools.optimize.coreml as cto
    cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
        mode="kmeans", nbits=8, granularity="per_tensor", group_size=group_size))
    return cto.palettize_weights(mlmodel, cfg)


def _dir_bytes(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def export_variant(variant: str, model, c, quant: str, target, out_root: Path) -> Dict:
    """导出一个变体 + 一种量化。返回 {path, mb, ...}。"""
    import coremltools as ct

    img_h, img_w = c["img_h"], c["img_w"]
    lane_s, nd, dfd, sd = c["lane_size"], c["num_dets"], c["det_feat_dim"], c["state_dim"]

    if variant == "A_full":
        mod = SplitA(model).eval()
        ins = [("image", (8, 3, img_h, img_w))]
        outs = ["img_feat"]
        sample = (torch.rand(8, 3, img_h, img_w),)
    elif variant in ("A_cnn8", "A_cnn4", "A_cnn2", "A_cnn1"):
        n = int(variant[-1])
        mod = SplitACNN(model).eval()
        ins = [("image", (n, 3, img_h, img_w))]
        outs = ["feats"]
        sample = (torch.rand(n, 3, img_h, img_w),)
    elif variant == "A_temporal":
        mod = SplitATemporal(model).eval()
        ins = [("feats", (8, 256))]
        outs = ["img_feat"]
        sample = (torch.rand(8, 256),)
    elif variant == "B":
        mod = SplitB(model).eval()
        ins = [("img_feat", (1, 256)),
               ("lane", (1, 1, lane_s, lane_s)),
               ("dets", (1, nd, dfd)),
               ("det_mask", (1, nd)),
               ("vehicle_state", (1, sd))]
        outs = list(OUTPUT_NAMES)
        sample = (torch.rand(1, 256), torch.rand(1, 1, lane_s, lane_s),
                  torch.rand(1, nd, dfd), torch.rand(1, nd), torch.rand(1, sd))
    elif variant == "full":
        mod = FullWrapper(model).eval()
        ins = [("image", (8, 3, img_h, img_w)),
               ("lane", (1, 1, lane_s, lane_s)),
               ("dets", (1, nd, dfd)),
               ("det_mask", (1, nd)),
               ("vehicle_state", (1, sd))]
        outs = list(OUTPUT_NAMES)
        sample = (torch.rand(8, 3, img_h, img_w), torch.rand(1, 1, lane_s, lane_s),
                  torch.rand(1, nd, dfd), torch.rand(1, nd), torch.rand(1, sd))
    else:
        raise ValueError(variant)

    out = out_root / f"{variant}_{quant}.mlpackage"
    if out.exists():
        shutil.rmtree(out)
    out.parent.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    with torch.no_grad():
        traced = torch.jit.trace(mod, sample, strict=False)
    ml = _convert(traced, ins, outs, target, precision="fp16")
    if quant == "palette_int8":
        ml = _palettize(ml, group_size=1)
    ml.save(str(out))
    dt = time.time() - t0

    mb = _dir_bytes(out) / 1048576.0
    print(f"[export] {variant:<11} {quant:<12} {mb:>7.3f} MB  ({dt:.1f}s)  → {out}")
    return {"variant": variant, "quant": quant, "path": str(out), "mb": mb,
            "convert_s": dt, "inputs": dict(ins), "outputs": outs}


# ============================================================================
# 5. ANE 判定（子进程，抓 stderr）
# ============================================================================

def anecheck_subprocess(path: str) -> Dict:
    """★ 权威判据：另起子进程跑 anecheck 模式，捕获 stderr 里的 ANE 编译错误。

    为什么必须子进程：MILCompilerForANE 的错误由 E5RT/CoreML C++ 层打到
    **进程 stderr**，Python 侧拿不到异常（predict 静默成功、只是慢）。
    """
    cmd = [sys.executable, str(Path(__file__).resolve()), "anecheck", path]
    t0 = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    dt = time.time() - t0

    stderr = proc.stderr or ""
    stdout = proc.stdout or ""
    # ★★ 实测修正（2026-10-09）：E5RT/MILCompilerForANE 的报错**两个流都可能出现**
    #    —— 直接跑时它落在 stdout，经 shell 管道时又可能被归到 stderr。
    #    只查一个流会漏报（本脚本第一版就漏了 full 变体，误判成 NO_ANE_OPS）。
    #    → **两个流合并后再判**，这是唯一可靠的做法。
    both = stderr + "\n" + stdout
    ane_err = ("MILCompilerForANE" in both) or ("ANECCompile() FAILED" in both)

    hist = {}
    total = None
    for line in both.splitlines():
        line = line.strip()
        if line.startswith("{") and '"device_hist"' in line:
            try:
                payload = json.loads(line)
                hist = payload.get("device_hist", {})
                total = payload.get("total_ops")
            except Exception:
                # JSON 行后面可能被 E5RT 的报错文本粘连 → 退化为正则抽取
                try:
                    i = line.index("{")
                    j = line.rindex("}") + 1
                    payload = json.loads(line[i:j])
                    hist = payload.get("device_hist", {})
                    total = payload.get("total_ops")
                except Exception:
                    pass

    ne = hist.get("NeuralEngine", 0)
    cpu = hist.get("CPU", 0)
    gpu = hist.get("GPU", 0)
    verdict = "ANE_FAIL" if ane_err else ("ANE_OK" if ne > 0 else "NO_ANE_OPS")
    return {"path": path, "ane_error": ane_err, "device_hist": hist,
            "total_ops": total, "ne_ops": ne, "cpu_ops": cpu, "gpu_ops": gpu,
            "verdict": verdict, "check_s": dt,
            "stderr_tail": both.strip().splitlines()[-1][:300] if both.strip() else ""}


def _anecheck_main(path: str) -> int:
    """子进程模式：加载 + 预测 + 读 MLComputePlan，把算子落点打成 JSON。"""
    import coremltools as ct
    from coremltools.models.compute_plan import MLComputePlan

    cu = ct.ComputeUnit.CPU_AND_NE
    m = ct.models.MLModel(path, compute_units=cu)
    spec = m.get_spec()
    feed = {i.name: np.zeros(list(i.type.multiArrayType.shape), dtype=np.float32)
            for i in spec.description.input}
    m.predict(feed)                       # 触发一次真实执行
    compiled = m.get_compiled_model_path()
    plan = MLComputePlan.load_from_path(compiled, compute_units=cu)   # ★ 触发 ANE 编译
    prog = plan.model_structure.program
    fn = prog.functions["main"]

    cnt = collections.Counter()

    def walk(block):
        for op in block.operations:
            dev = plan.get_compute_device_usage_for_mlprogram_operation(op)
            nm = "UNKNOWN"
            if dev is not None and dev.preferred_compute_device is not None:
                nm = type(dev.preferred_compute_device).__name__ \
                    .replace("ML", "").replace("ComputeDevice", "")
            cnt[nm] += 1
            for b in op.blocks:
                walk(b)

    walk(fn.block)
    print(json.dumps({"path": path, "total_ops": sum(cnt.values()),
                      "device_hist": dict(cnt)}, ensure_ascii=False))
    return 0


# ============================================================================
# 6. ABBA 计时
# ============================================================================

def _feed_from_spec(m, seed=0):
    """按模型 spec 造确定性输入。"""
    spec = m.get_spec()
    g = np.random.default_rng(seed)
    feed = {}
    for i in spec.description.input:
        shape = list(i.type.multiArrayType.shape)
        a = g.random(shape, dtype=np.float32)
        if i.name == "lane":
            a = (a > 0.985).astype(np.float32)
        if i.name == "det_mask":
            a = (a > 0.35).astype(np.float32)
        feed[i.name] = a
    return feed


def _bench_once(m, feed, iters=60, warmup=10):
    for _ in range(warmup):
        m.predict(feed)
    t0 = time.perf_counter()
    for _ in range(iters):
        m.predict(feed)
    return (time.perf_counter() - t0) / iters * 1000.0


def bench_abba(path: str, iters: int = 60, warmup: int = 10) -> Dict:
    """ABBA 交替：NE, CPU, CPU, NE → 各自取中位。抵消负载漂移。"""
    import coremltools as ct

    t_load = time.perf_counter()
    m_ne = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_NE)
    load_ne = (time.perf_counter() - t_load) * 1000.0
    t_load = time.perf_counter()
    m_cpu = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_ONLY)
    load_cpu = (time.perf_counter() - t_load) * 1000.0

    feed = _feed_from_spec(m_ne)

    # 冷启动（含 ANE 编译 / 权重加载）
    t0 = time.perf_counter()
    m_ne.predict(feed)
    cold_ms = (time.perf_counter() - t0) * 1000.0

    a1 = _bench_once(m_ne, feed, iters, warmup)
    c1 = _bench_once(m_cpu, feed, iters, warmup)
    c2 = _bench_once(m_cpu, feed, iters, warmup)
    a2 = _bench_once(m_ne, feed, iters, warmup)

    ne = statistics.median([a1, a2])
    cpu = statistics.median([c1, c2])
    return {"ne_ms": ne, "cpu_ms": cpu, "ratio": ne / cpu if cpu else None,
            "ne_rounds": [a1, a2], "cpu_rounds": [c1, c2],
            "load_ne_ms": load_ne, "load_cpu_ms": load_cpu, "cold_ms": cold_ms,
            "iters": iters, "warmup": warmup}


def bench_p95(path: str, cu_name: str = "CPU_AND_NE", iters: int = 200) -> Dict:
    """单档 p50/p95（与 Lead 的 p95≤16ms 口径对齐）。"""
    import coremltools as ct
    cu = getattr(ct.ComputeUnit, cu_name)
    m = ct.models.MLModel(path, compute_units=cu)
    feed = _feed_from_spec(m)
    for _ in range(20):
        m.predict(feed)
    s = []
    for _ in range(iters):
        t0 = time.perf_counter()
        m.predict(feed)
        s.append((time.perf_counter() - t0) * 1000.0)
    s.sort()
    return {"cu": cu_name, "p50_ms": statistics.median(s),
            "p95_ms": s[int(len(s) * 0.95)], "min_ms": s[0], "max_ms": s[-1],
            "mean_ms": statistics.fmean(s), "n": len(s)}


def _a_output_name(ma) -> str:
    """A 类模型的输出名：A_full/A_temporal → 'img_feat'，A_cnnN → 'feats'。

    ★ 必须自动识别：写死名字会让 A_cnn8 串联直接 KeyError（本脚本第一版踩过）。
    """
    outs = [o.name for o in ma.get_spec().description.output]
    for cand in ("img_feat", "feats"):
        if cand in outs:
            return cand
    return outs[0]


def bench_chain(a_path: str, b_path: str, iters: int = 60, warmup: int = 10) -> Dict:
    """★ A→B 串联总延迟（真实串联：A 的输出直接喂 B 的输入）。

    ABBA：NE, CPU, CPU, NE。同时报"分项之和"以暴露 Python 调用开销。
    """
    import coremltools as ct

    def _mk(cu):
        ma = ct.models.MLModel(a_path, compute_units=cu)
        mb = ct.models.MLModel(b_path, compute_units=cu)
        return ma, mb

    ma_ne, mb_ne = _mk(ct.ComputeUnit.CPU_AND_NE)
    ma_cpu, mb_cpu = _mk(ct.ComputeUnit.CPU_ONLY)

    a_out = _a_output_name(ma_ne)
    fa = _feed_from_spec(ma_ne)
    fb = _feed_from_spec(mb_ne)

    def _run(ma, mb, n, w):
        fb_local = dict(fb)
        fb_local["img_feat"] = np.asarray(ma.predict(fa)[a_out], dtype=np.float32)
        for _ in range(w):
            fb_local["img_feat"] = np.asarray(ma.predict(fa)[a_out], dtype=np.float32)
            mb.predict(fb_local)
        t0 = time.perf_counter()
        for _ in range(n):
            fb_local["img_feat"] = np.asarray(ma.predict(fa)[a_out], dtype=np.float32)
            mb.predict(fb_local)
        return (time.perf_counter() - t0) / n * 1000.0

    a1 = _run(ma_ne, mb_ne, iters, warmup)
    c1 = _run(ma_cpu, mb_cpu, iters, warmup)
    c2 = _run(ma_cpu, mb_cpu, iters, warmup)
    a2 = _run(ma_ne, mb_ne, iters, warmup)
    return {"ne_ms": statistics.median([a1, a2]), "cpu_ms": statistics.median([c1, c2]),
            "ne_rounds": [a1, a2], "cpu_rounds": [c1, c2], "iters": iters,
            "a_output": a_out}


def bench_chain3(cnn_path: str, tmp_path: str, b_path: str,
                 iters: int = 60, warmup: int = 10) -> Dict:
    """★ 三模型串联：A_cnn(8帧纯卷积) → A_temporal(GRU) → B。

    用途：若 A_cnn8 与 A_temporal 都能各自上 ANE，但合起来的 A_full 不能，
    就退回这个三拆方案。实测 A_full 能上 ANE，故本函数作为**对照/备选**保留。
    """
    import coremltools as ct

    def _mk(cu):
        return (ct.models.MLModel(cnn_path, compute_units=cu),
                ct.models.MLModel(tmp_path, compute_units=cu),
                ct.models.MLModel(b_path, compute_units=cu))

    m1_ne, m2_ne, m3_ne = _mk(ct.ComputeUnit.CPU_AND_NE)
    m1_cpu, m2_cpu, m3_cpu = _mk(ct.ComputeUnit.CPU_ONLY)

    f1 = _feed_from_spec(m1_ne)
    f3 = _feed_from_spec(m3_ne)
    o1 = _a_output_name(m1_ne)          # A_cnn → "feats"
    o2 = _a_output_name(m2_ne)          # A_temporal → "img_feat"
    # A_temporal 的**输入**名（A_cnn 的输入是 image）
    i2 = [i.name for i in m2_ne.get_spec().description.input][0]

    def _run(m1, m2, m3, n, w):
        f3_local = dict(f3)
        for _ in range(w + 1):
            feats = np.asarray(m1.predict(f1)[o1], dtype=np.float32)
            f3_local["img_feat"] = np.asarray(m2.predict({i2: feats})[o2],
                                              dtype=np.float32)
            m3.predict(f3_local)
        t0 = time.perf_counter()
        for _ in range(n):
            feats = np.asarray(m1.predict(f1)[o1], dtype=np.float32)
            f3_local["img_feat"] = np.asarray(m2.predict({i2: feats})[o2],
                                              dtype=np.float32)
            m3.predict(f3_local)
        return (time.perf_counter() - t0) / n * 1000.0

    a1 = _run(m1_ne, m2_ne, m3_ne, iters, warmup)
    c1 = _run(m1_cpu, m2_cpu, m3_cpu, iters, warmup)
    c2 = _run(m1_cpu, m2_cpu, m3_cpu, iters, warmup)
    a2 = _run(m1_ne, m2_ne, m3_ne, iters, warmup)
    return {"ne_ms": statistics.median([a1, a2]), "cpu_ms": statistics.median([c1, c2]),
            "ne_rounds": [a1, a2], "cpu_rounds": [c1, c2], "iters": iters}


# ============================================================================
# 7. 主流程
# ============================================================================

def _sysinfo() -> Dict:
    def sh(cmd):
        try:
            return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                                  timeout=10).stdout.strip()
        except Exception:
            return ""
    return {"uptime": sh("uptime"), "cpu": sh("sysctl -n machdep.cpu.brand_string"),
            "os": sh("sw_vers -productVersion"), "time": time.strftime("%Y-%m-%d %H:%M:%S")}


def cmd_build(args, report: Dict) -> int:
    report["sysinfo_before"] = _sysinfo()
    print(f"[env] {report['sysinfo_before']['cpu']} / macOS "
          f"{report['sysinfo_before']['os']} / {report['sysinfo_before']['uptime']}")

    # ---- ① 真实权重（checkpoint）下的等价性 ----
    print("\n" + "=" * 78)
    print(" ① 数值等价性 —— checkpoint 权重（refiner/temporal 为零初始化 → 部分通路恒等）")
    print("=" * 78)
    m1 = build(seed=None, live_all_paths=False)
    report["equiv_ckpt"] = check_equivalence(m1)

    # ---- ② 全通路激活下的等价性（真正测到 refiner/MoE/时序残差）----
    print("\n" + "=" * 78)
    print(" ② 数值等价性 —— live_all_paths（零初始化投影 + 专家全部扰动 → 全通路激活）")
    print("=" * 78)
    m2 = build(seed=None, live_all_paths=True)
    report["equiv_live"] = check_equivalence(m2)

    # ---- ③ 纯随机权重（彻底排除零初始化掩盖）----
    print("\n" + "=" * 78)
    print(" ③ 数值等价性 —— 全模型随机权重（seed=7）")
    print("=" * 78)
    m3 = build(seed=7, live_all_paths=False)
    report["equiv_random"] = check_equivalence(m3)

    report["equiv_worst"] = max(report["equiv_ckpt"]["_worst"],
                                report["equiv_live"]["_worst"],
                                report["equiv_random"]["_worst"])
    print(f"\n[equiv] ★★ 三组最差 maxdiff = {report['equiv_worst']:.3e}")
    return 0


def cmd_export(args, report: Dict) -> int:
    import coremltools as ct
    target = ct.target.macOS13

    # 用 live_all_paths 的模型导出（全通路激活 → 图结构与真实部署一致且可验证）
    model = build(seed=None, live_all_paths=True)
    c = {"img_h": 180, "img_w": 320, "lane_size": 160, "num_dets": 20,
         "det_feat_dim": 12, "state_dim": 8}

    variants = args.variants
    results = []
    for v in variants:
        for q in args.quants:
            try:
                results.append(export_variant(v, model, c, q, target, OUT_ROOT))
            except Exception as exc:
                print(f"[export] ✗ {v} {q}: {type(exc).__name__}: {str(exc)[:200]}")
                results.append({"variant": v, "quant": q, "error":
                                f"{type(exc).__name__}: {str(exc)[:300]}"})
    report["artifacts"] = results
    return 0


def cmd_bench(args, report: Dict) -> int:
    arts = [a for a in report.get("artifacts", []) if "error" not in a]
    if not arts:
        print("[bench] ✗ 没有可用产物，先跑 export")
        return 2

    report["sysinfo_mid"] = _sysinfo()
    print(f"[bench] {report['sysinfo_mid']['uptime']}\n")

    print("=" * 100)
    print(" ANE 判定（子进程抓 stderr）+ ABBA 计时")
    print("=" * 100)
    print(f"  {'变体':<12}{'量化':<13}{'体积MB':>8}{'ANE判定':>10}"
          f"{'ANE算子':>8}{'CPU算子':>8}{'NE ms':>9}{'CPU ms':>9}{'NE/CPU':>8}")
    print("  " + "-" * 94)

    for a in arts:
        v = anecheck_subprocess(a["path"])
        a["ane"] = v
        try:
            b = bench_abba(a["path"], iters=args.iters)
        except Exception as exc:
            b = {"error": f"{type(exc).__name__}: {str(exc)[:150]}"}
        a["bench"] = b
        ne = f"{b['ne_ms']:.3f}" if "ne_ms" in b else "—"
        cpu = f"{b['cpu_ms']:.3f}" if "cpu_ms" in b else "—"
        rat = f"{b['ratio']:.2f}" if b.get("ratio") else "—"
        print(f"  {a['variant']:<12}{a['quant']:<13}{a['mb']:>8.3f}"
              f"{v['verdict']:>10}{v['ne_ops']:>8}{v['cpu_ops']:>8}"
              f"{ne:>9}{cpu:>9}{rat:>8}")

    # ---- p95 专项（对齐 Lead 的 p95≤16ms 口径）----
    print("\n" + "=" * 100)
    print(" p95 专项（每档 200 次，含 warmup 20）")
    print("=" * 100)
    print(f"  {'变体':<12}{'量化':<13}{'计算单元':<16}{'p50 ms':>9}{'p95 ms':>9}{'min':>8}{'max':>8}")
    print("  " + "-" * 80)
    for a in arts:
        a["p95"] = {}
        for cu in ("CPU_AND_NE", "CPU_ONLY"):
            try:
                r = bench_p95(a["path"], cu, iters=200)
            except Exception as exc:
                r = {"error": f"{type(exc).__name__}: {str(exc)[:120]}"}
            a["p95"][cu] = r
            if "p50_ms" in r:
                print(f"  {a['variant']:<12}{a['quant']:<13}{cu:<16}"
                      f"{r['p50_ms']:>9.3f}{r['p95_ms']:>9.3f}{r['min_ms']:>8.3f}{r['max_ms']:>8.3f}")
            else:
                print(f"  {a['variant']:<12}{a['quant']:<13}{cu:<16}   ✗ {r['error'][:60]}")

    report["sysinfo_after"] = _sysinfo()
    print(f"\n[bench] 测后 {report['sysinfo_after']['uptime']}")
    return 0


def cmd_chain(args, report: Dict) -> int:
    arts = {(a["variant"], a["quant"]): a
            for a in report.get("artifacts", []) if "error" not in a}

    # 串联组合：(A 变体, A 量化, B 量化)
    plans = json.loads(args.chain_plans) if args.chain_plans else [
        ["A_full", "palette_int8", "palette_int8"],
        ["A_full", "fp16", "fp16"],
        ["A_cnn8", "palette_int8", "palette_int8"],
    ]

    print("\n" + "=" * 100)
    print(" A→B 串联总延迟（ABBA：NE,CPU,CPU,NE）")
    print("=" * 100)
    print(f"  {'组合':<38}{'NE ms':>10}{'CPU ms':>10}{'分项和(NE)':>12}{'开销':>9}")
    print("  " + "-" * 82)

    report["chain"] = []
    for av, aq, bq in plans:
        a = arts.get((av, aq))
        b = arts.get(("B", bq))
        if a is None or b is None:
            print(f"  {av}/{aq} → B/{bq:<24}  ✗ 产物缺失")
            continue
        try:
            r = bench_chain(a["path"], b["path"], iters=args.iters)
        except Exception as exc:
            print(f"  {av}/{aq} → B/{bq:<24}  ✗ {type(exc).__name__}: {str(exc)[:80]}")
            continue
        a_ne = a.get("bench", {}).get("ne_ms")
        b_ne = b.get("bench", {}).get("ne_ms")
        ssum = (a_ne or 0) + (b_ne or 0)
        overhead = r["ne_ms"] - ssum
        rec = {"a": av, "a_quant": aq, "b_quant": bq, **r,
               "sum_parts_ne": ssum, "overhead_ne": overhead}
        report["chain"].append(rec)
        print(f"  {av+'/'+aq+' → B/'+bq:<38}{r['ne_ms']:>10.3f}{r['cpu_ms']:>10.3f}"
              f"{ssum:>12.3f}{overhead:>9.3f}")

    # 单模型基线
    f = arts.get(("full", "palette_int8")) or arts.get(("full", "fp16"))
    if f:
        print(f"\n  [基线] 单模型 full/{f['quant']}: "
              f"NE {f.get('bench', {}).get('ne_ms', float('nan')):.3f} ms / "
              f"CPU {f.get('bench', {}).get('cpu_ms', float('nan')):.3f} ms "
              f"(ANE判定 {f.get('ane', {}).get('verdict')})")
    return 0


def _loadavg() -> float:
    try:
        return os.getloadavg()[0]
    except Exception:
        return -1.0


def _wait_for_quiet(max_load: float = 6.0, timeout_s: float = 600.0,
                    poll_s: float = 5.0) -> Tuple[float, float]:
    """等本机负载降到阈值以下（MacBook Air 无风扇 + 本机常有并行重活）。

    ★ 为什么必须等：S1 首次 bench 时本机 load average 高达 37~44
      （兄弟 agent 的 /tmp/s5_reuse/*.py 各占 ~90% CPU）—— 那种条件下
      CPU 档数字被放大 3~5 倍，**不可作为结论**。
      本函数如实返回 (最终load, 等待秒数)，报告里一并记录。
    """
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        la = _loadavg()
        if la < max_load:
            return la, time.time() - t0
        time.sleep(poll_s)
    return _loadavg(), time.time() - t0


def cmd_remeasure(args, report: Dict) -> int:
    """★ 可信复测：负载门控 + **轮转交错**（round-robin）测所有变体。

    与 cmd_bench 的区别：
      · cmd_bench 是"逐变体跑完再跑下一个" → 负载漂移会让后面的变体吃亏/占便宜
      · 本模式**每一轮把全部变体各测一遍**，轮间交错 → 负载漂移被摊平到所有变体
      · 每轮记录 load average，取**跨轮中位数**（不是跨样本中位数）
    """
    import coremltools as ct

    arts = {(a["variant"], a["quant"]): a
            for a in report.get("artifacts", []) if "error" not in a}

    # 要测的变体（按重要性排序；只测存在的）
    wanted = [(v, q) for v in ("A_cnn2", "A_cnn4", "A_cnn8", "A_full",
                               "A_temporal", "B", "full")
              for q in ("palette_int8", "fp16")]
    todo = [(v, q) for v, q in wanted if (v, q) in arts]

    la0, waited = _wait_for_quiet(args.max_load, args.quiet_timeout)
    print(f"[remeasure] 负载门控：等待 {waited:.0f}s 后 load={la0:.2f} "
          f"(阈值 {args.max_load})；本机 {os.cpu_count()} 核")

    # 预加载全部模型（NE + CPU 各一份），避免加载开销混进计时
    loaded: Dict[Tuple[str, str], Dict] = {}
    for key in todo:
        p = arts[key]["path"]
        try:
            m_ne = ct.models.MLModel(p, compute_units=ct.ComputeUnit.CPU_AND_NE)
            m_cpu = ct.models.MLModel(p, compute_units=ct.ComputeUnit.CPU_ONLY)
            feed = _feed_from_spec(m_ne)
            for _ in range(10):          # warmup（含 ANE 编译）
                m_ne.predict(feed)
            loaded[key] = {"ne": m_ne, "cpu": m_cpu, "feed": feed}
        except Exception as exc:
            print(f"[remeasure] ✗ 加载 {key}: {type(exc).__name__}: {str(exc)[:100]}")

    rounds = args.rounds
    iters = args.iters
    # samples[key][cu] = [round1, round2, ...]
    samples: Dict = {k: {"CPU_AND_NE": [], "CPU_ONLY": []} for k in loaded}
    loads: List[float] = []

    for r in range(rounds):
        for key, L in loaded.items():
            for cu_name in ("CPU_AND_NE", "CPU_ONLY"):
                m = L["ne"] if cu_name == "CPU_AND_NE" else L["cpu"]
                t0 = time.perf_counter()
                for _ in range(iters):
                    m.predict(L["feed"])
                ms = (time.perf_counter() - t0) / iters * 1000.0
                samples[key][cu_name].append(ms)
        loads.append(_loadavg())
        print(f"[remeasure] 第 {r+1}/{rounds} 轮完成，load={loads[-1]:.2f}")

    print("\n" + "=" * 104)
    print(f" 可信复测结果（{rounds} 轮轮转交错 × 每轮 {iters} 次；取跨轮中位数）")
    print("=" * 104)
    print(f"  {'变体':<12}{'量化':<13}{'ANE判定':>10}{'NE中位':>9}{'NE范围':>18}"
          f"{'CPU中位':>10}{'NE/CPU':>8}")
    print("  " + "-" * 96)

    out = {}
    for key in sorted(loaded, key=lambda k: (k[0], k[1])):
        v, q = key
        ne = samples[key]["CPU_AND_NE"]
        cpu = samples[key]["CPU_ONLY"]
        ne_med = statistics.median(ne)
        cpu_med = statistics.median(cpu)
        a = arts[key]
        verdict = a.get("ane", {}).get("verdict", "?")
        rng = f"{min(ne):.2f}~{max(ne):.2f}"
        out[f"{v}_{q}"] = {"variant": v, "quant": q, "ane_verdict": verdict,
                           "ne_median": ne_med, "ne_min": min(ne), "ne_max": max(ne),
                           "ne_rounds": ne, "cpu_median": cpu_med,
                           "cpu_min": min(cpu), "cpu_max": max(cpu),
                           "cpu_rounds": cpu, "ratio": ne_med / cpu_med if cpu_med else None}
        print(f"  {v:<12}{q:<13}{verdict:>10}{ne_med:>9.3f}{rng:>18}"
              f"{cpu_med:>10.3f}{ne_med/cpu_med:>8.2f}")

    report["remeasure"] = {"rounds": rounds, "iters": iters,
                           "load_before": la0, "waited_s": waited,
                           "loads_per_round": loads, "results": out}
    report["sysinfo_remeasure"] = _sysinfo()
    print(f"\n[remeasure] 各轮 load: {[round(x,2) for x in loads]}")
    print(f"[remeasure] {report['sysinfo_remeasure']['uptime']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="双模型拆分实验（S1）")
    ap.add_argument("mode", choices=["all", "build", "export", "bench", "chain",
                                     "anecheck", "remeasure"])
    ap.add_argument("path", nargs="?", help="anecheck 模式的模型路径")
    ap.add_argument("--variants", nargs="*",
                    default=["A_full", "A_cnn8", "A_cnn4", "A_cnn2",
                             "A_temporal", "B", "full"])
    ap.add_argument("--quants", nargs="*", default=["palette_int8", "fp16"])
    ap.add_argument("--iters", type=int, default=60)
    ap.add_argument("--rounds", type=int, default=5, help="remeasure 的轮转轮数")
    ap.add_argument("--max-load", type=float, default=6.0,
                    help="remeasure 的负载门控阈值（load average）")
    ap.add_argument("--quiet-timeout", type=float, default=600.0)
    ap.add_argument("--chain-plans", default=None, help="JSON: [[A变体,A量化,B量化],...]")
    args = ap.parse_args()

    if args.mode == "anecheck":
        if not args.path:
            print("anecheck 需要模型路径", file=sys.stderr)
            return 2
        return _anecheck_main(args.path)

    report: Dict = {}
    if REPORT.exists():
        try:
            report = json.loads(REPORT.read_text(encoding="utf-8"))
        except Exception:
            report = {}

    if args.mode in ("all", "build"):
        cmd_build(args, report)
    if args.mode in ("all", "export"):
        cmd_export(args, report)
    if args.mode in ("all", "bench"):
        cmd_bench(args, report)
    if args.mode in ("all", "chain"):
        cmd_chain(args, report)
    if args.mode == "remeasure":
        cmd_remeasure(args, report)

    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[report] {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
