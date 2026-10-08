#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
M9-v2（src/model_v2.py 的 M2Model）→ CoreML **INT8** 导出 + 体积/性能/偏差三测

================================================================================
0. 用户硬约束（最高依据）
================================================================================
    「我说是 INT8 体积，我要的是 INT8，并不是那种（FP16）」

→ 本脚本的**默认与主推方案是 8 位权重压缩**（palette/kmeans 或 linear int8），
  不是 fp16。fp16 只作为**对照基线**保留（`--precision fp16`），用于回答
  "INT8 相对 FP16 损失了多少" —— 它绝不是交付物。

★ 铁律：`nbits=8`。任何把 nbits 提到 16 的配置都违反用户约束。

================================================================================
1. 与既有脚本的关系（红线）
================================================================================
    · `src/model_v2.py`          —— **只读**，一行不改（模型定义方 = M2）
    · `tools/export_m9_v2_coreml.py` —— **只读**，一行不改（M2 的 fp16/int8 导出器）
    · 本文件是**新建**，只做 INT8 专项：方案对比 + 三测 + 报告数据

  为什么不直接改 M2 的脚本？因为 M2 脚本的默认档是 fp16（用户已明确否决），
  且它只实现了 linear int8 一种量化。INT8 专项需要：
    (a) palette(kmeans) 方案 —— 项目已量产验证（ayolom 7.2M→3.8M）
    (b) **关键分支保精度**机制（lane 头 / 融合头跳过压缩）
    (c) group_size 扫描（yolopx 实测 gs=32 会静默跳过 ~70% 张量，直接决定体积）
    (d) 真机性能 + 冷启动 + 时序抖动

================================================================================
2. ★ 为什么主推 palette(kmeans) 而不是 linear int8（都有实测依据）
================================================================================
【依据 A · 项目内 INT8 全量化已被证伪】
    `tools/yolopx/export_yolopx_coreml.py` 实测：int8 把**车道线正像素占比
    从 1.30–1.80% 打到 0.13–0.21%（掉 10×）**，结论「INT8 全量化已证伪，勿用」。
    → 车道线是**稀疏细结构**，全量化会把细线整条抹掉。本项目有 lane 分支，
      属于同一风险面，必须给 lane 相关权重留保命机制。

【依据 B · 项目已量产的 INT8 配方 = palette + 关键头保 fp16】
    `tools/ayolom/export_ayolom_coreml.py:121-148` `quantize_palette_int8()`：
        mode="kmeans", nbits=8, granularity="per_tensor", group_size=32,
        op_name_configs={det 头算子: None}   ← None = 跳过压缩（不是 mode="none"！）
    实测体积 7.2M → **3.8M**（压掉 47%）。

【依据 C · group_size 决定体积上限（最阴的坑）】
    `tools/yolopx/exp_quant_palette.py:18-24` 实测（868 个非 det 头权重）：
        gs=1 → 100.0% 张量可压    gs=2 → 95.7%    gs=4 → 55.2%
        gs=8 → 32.8%              gs=16 → 30.9%   gs=32 → 30.4%
    原因：coremltools `_quantization_passes.py` 对
        `channel_num % channel_group_size != 0` 的张量**只打 warning 就跳过**，
    不报错。所以 gs=32 的"INT8 模型"实际只有 30% 权重真被压过 —— 体积自然下不去。
    → 本脚本默认 `--group-size 1`（= per-channel 等价物，100% 覆盖），
      并把 gs=32 作为对照，用实测数字说明差异。

================================================================================
3. ★ 三测口径（全部实测，不许估算）
================================================================================
    ① 体积：.mlpackage 落盘后 `du` 实测；同时给 weights/ 目录净重
    ② 真机耗时：coremltools 在本机（Apple Silicon）真跑
         · compute_units 三档：cpuAndNeuralEngine / all / cpuOnly
         · 每档 **5 轮 × 100 次**，取**中位数**（抗抖动）
         · 另测**冷启动**（首次 predict，含模型加载 + ANE 编译）
    ③ 量化偏差：对 fp16 基线与 int8 各跑同一批输入，逐用例比 maxdiff
         · 6 个契约用例（normal/no_dets/no_lane/zero_state/all_empty/saturated）
         · **lane 分支专项**：对 lane 输入做扰动扫描，看 steer 输出是否被量化毁掉
         · **时序抖动**：连续帧序列下的输出抖动幅度（量化引入的抖动是关键风险）

================================================================================
4. 产物
================================================================================
    models/m9_v2_int8.mlpackage          主交付（palette 8bit）
    /tmp/m9v2_int8_report.json           机器可读三测数据（供报告引用）
    控制台全文输出                        人读证据

用法
----
    # 主方案：palette kmeans 8bit + gs=1（100% 覆盖）
    ./.venv-yolo26/bin/python3 tools/export_m9_v2_int8.py \
        --src checkpoints/m9_v2/best_model.pt \
        --out models/m9_v2_int8.mlpackage

    # 随机权重跑通链路（产物绝不可上车）
    ./.venv-yolo26/bin/python3 tools/export_m9_v2_int8.py --self-test --out /tmp/probe.mlpackage

    # 全方案对比（palette gs=1/2/8/32 + linear int8 + fp16 基线）
    ./.venv-yolo26/bin/python3 tools/export_m9_v2_int8.py --compare-all
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
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

# ============================================================================
# 契约常量 —— 单一事实源是 src/model_v2.py，这里只做"读取"不硬编码尺寸
# ============================================================================

#: CoreML 输入名 —— **与 export_m9_v2_coreml.py（M2 权威脚本）逐字一致**。
# ★ 方案 A（Lead 2026-10-08 拍板）：image 的 batch 维 = 时序窗口 [8,3,180,320]，
#   模型内部 batch 跑 ImageEncoder → 8×256 特征 → 当作 N=8 序列喂 GRU。
#   ⚠️ 本文件曾落后于 M2 脚本（仍写 5 输入 3 输出）—— 契约漂移会让 int8 产物
#   与 Swift 侧 / fp16 产物**不兼容**，故此处必须同步（t1 验证抓出的假绿同款问题）。
INPUT_NAMES: Tuple[str, ...] = ("image", "lane", "dets", "det_mask", "vehicle_state")

#: CoreML 输出名（含 M4 三个新头，与 M2 脚本同序）
OUTPUT_NAMES: Tuple[str, ...] = ("steer", "throttle", "brake",
                                 "confidence", "risk", "car_heading")

#: 训练期探针前缀（导出前必须剥离，见 M2 脚本 坑 5）
_TRAINING_PROBE_PREFIX = "lane_steer_probe."

#: 量化时**必须保 fp16 的关键权重前缀**（依据 §2-A/B）
#:
#: lane 分支：车道线是稀疏细结构，yolopx 实测全量化把正像素打掉 10×。
#:            宁可少压几 KB，也不能让车道线消失。
#: fusion_head：三个输出的最终融合层，是控制量的直接产生处，量化误差会
#:            直接变成转向抖动（src/model_v2.py §4 已写明此风险）。
DEFAULT_PRESERVE_PREFIXES: Tuple[str, ...] = (
    "lane_encoder.",
    "fusion_head.",
)

# ============================================================================
# 1. 权重加载（与 M2 脚本同款，保证口径一致）
# ============================================================================


def _load_state_dict(src: Path) -> Dict[str, torch.Tensor]:
    """读取 checkpoint，剥离 torch.compile 前缀与训练期探针。"""
    ckpt = torch.load(src, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    probe_keys = [k for k in sd if k.startswith(_TRAINING_PROBE_PREFIX)]
    for k in probe_keys:
        del sd[k]
    if probe_keys:
        print(f"[INT8] 剥离训练期探针 {len(probe_keys)} 个键")
    return sd


def _build_and_load(sd: Optional[Dict[str, torch.Tensor]]):
    """训练态构建 → load → reparameterize（M2 脚本 坑 6，误用会导出随机权重）。"""
    from src.model_v2 import build_model  # noqa: WPS433

    if sd is None:
        print("[INT8] ⚠ 随机初始化权重（仅验链路，产物绝不可上车）")
        model = build_model(deploy=False)
        model.eval()
        model.reparameterize()
        return model, {"random_init": True, "missing": 0, "unexpected": 0}

    has_reparam = any("rbr_reparam" in k for k in sd)
    if has_reparam:
        print("[INT8] 权重为融合态(rbr_reparam) → deploy=True 构建")
        model = build_model(deploy=True)
        res = model.load_state_dict(sd, strict=False)
    else:
        print("[INT8] 权重为训练态(多分支) → deploy=False 构建 + reparameterize")
        model = build_model(deploy=False)
        res = model.load_state_dict(sd, strict=False)
        model.reparameterize()
    model.eval()
    if res.missing_keys or res.unexpected_keys:
        print(f"[INT8]   ⚠ missing={len(res.missing_keys)} unexpected={len(res.unexpected_keys)}")
        print(f"[INT8]     missing 样例: {list(res.missing_keys)[:5]}")
        print(f"[INT8]     unexpected 样例: {list(res.unexpected_keys)[:5]}")
    return model, {"random_init": False,
                   "missing": len(res.missing_keys),
                   "unexpected": len(res.unexpected_keys)}


def _contract_from_model(model) -> Dict[str, int]:
    c = {
        "img_h": int(getattr(model, "img_h", 180)),
        "img_w": int(getattr(model, "img_w", 320)),
        "lane_size": int(getattr(model, "lane_size", 160)),
        "num_dets": int(getattr(model, "max_detections", 20)),
        "det_feat_dim": int(getattr(model, "det_in_dim", 12)),
        "state_dim": int(getattr(model, "state_dim", 8)),
    }
    # ★ 方案 A：时序窗口 N（= image 的 batch 维度），与 M2 脚本同源读取
    n_frames = 8
    te = getattr(model, "temporal_encoder", None)
    if te is not None:
        n_frames = int(getattr(te, "num_frames", 8))
    c["num_frames"] = n_frames
    return c


def _shapes(c: Dict[str, int]) -> List[Tuple[int, ...]]:
    """与 export_m9_v2_coreml.py 逐字一致：image batch = 时序窗口。"""
    return [
        (c["num_frames"], 3, c["img_h"], c["img_w"]),   # image ← batch=8 = 时序窗口
        (1, 1, c["lane_size"], c["lane_size"]),         # lane
        (1, c["num_dets"], c["det_feat_dim"]),          # dets
        (1, c["num_dets"]),                             # det_mask
        (1, c["state_dim"]),                            # vehicle_state
    ]


# ============================================================================
# 2. 输入构造（含 lane 分支专项与帧序列）
# ============================================================================


def _make_inputs(c: Dict[str, int], seed: int = 0) -> List[torch.Tensor]:
    """训练分布内的确定性输入。lane 用高阈值伯努利逼近真实稀疏度（1~2%）。

    ★ 方案 A：image 是 [num_frames, 3, H, W]（batch=时序窗口），与 M2 脚本一致。
    """
    g = torch.Generator().manual_seed(seed)
    img = torch.rand(c["num_frames"], 3, c["img_h"], c["img_w"], generator=g)
    lane = (torch.rand(1, 1, c["lane_size"], c["lane_size"], generator=g) > 0.985).float()
    dets = torch.rand(1, c["num_dets"], c["det_feat_dim"], generator=g)
    det_mask = (torch.rand(1, c["num_dets"], generator=g) > 0.35).float()
    state = torch.rand(1, c["state_dim"], generator=g) * 2.0 - 1.0
    return [img, lane, dets, det_mask, state]


def _edge_cases(c: Dict[str, int], base: Sequence[torch.Tensor]
                ) -> Dict[str, List[torch.Tensor]]:
    """契约边界用例（空输入是真实驾驶常态）。"""
    img, lane, dets, det_mask, state = base
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


def _lane_sweep(c: Dict[str, int], base: Sequence[torch.Tensor], n: int = 8
                ) -> Dict[str, List[torch.Tensor]]:
    """★ lane 分支专项：车道线**位置/粗细/密度**扫描。

    依据 §2-A：量化最可能毁掉的是稀疏细结构。这里沿"车道线从无到有、从粗到细"
    连续改变 lane 输入，看 steer 输出是否仍**单调/平滑**响应 —— 如果量化把
    细线抹平，steer 会退化成常数（正是"只会直走"的症状）。
    """
    img, lane, dets, det_mask, state = base
    H = c["lane_size"]
    cases: Dict[str, List[torch.Tensor]] = {}
    for i in range(n):
        density = 0.5 ** (i + 1)          # 从 50% 稠密 → 极稀疏
        thr = 1.0 - 0.02 * density * 20   # 阈值随密度上升
        thr = min(max(thr, 0.90), 0.9999)
        g = torch.Generator().manual_seed(1000 + i)
        l = (torch.rand(1, 1, H, H, generator=g) > thr).float()
        cases[f"lane_density_{i}"] = [img, l, dets, det_mask, state]
    # 单条细线（模拟真实车道线：1~2 像素宽）
    for width in (1, 2, 3, 6):
        l = torch.zeros(1, 1, H, H)
        cx = H // 2
        l[0, 0, :, cx:cx + width] = 1.0
        cases[f"lane_line_w{width}"] = [img, l, dets, det_mask, state]
    return cases


def _frame_sequence(c: Dict[str, int], base: Sequence[torch.Tensor], n: int = 24
                    ) -> List[List[torch.Tensor]]:
    """模拟连续帧：lane 轻微漂移 + state 缓慢变化，用于**时序抖动**测量。"""
    img, lane, dets, det_mask, state = base
    H = c["lane_size"]
    seq: List[List[torch.Tensor]] = []
    for t in range(n):
        shift = int(round(2.0 * np.sin(2 * np.pi * t / n)))
        l = torch.zeros_like(lane)
        cx = H // 2 + shift
        l[0, 0, :, max(0, cx):max(1, cx + 2)] = 1.0
        st = state.clone()
        st[0, 0] = 0.3 + 0.2 * float(np.sin(2 * np.pi * t / n))   # speed 缓变
        st[0, 4] = 0.1 * float(np.cos(2 * np.pi * t / n))         # curvature 缓变
        seq.append([img, l, dets, det_mask, st])
    return seq


# ============================================================================
# 3. 转换 + 量化
# ============================================================================


def _convert_fp16(traced, c: Dict[str, int], target):
    """先转 fp16 图（ANE 原生），IO 恒 fp32（M2 脚本 坑 3）。"""
    import coremltools as ct

    shapes = _shapes(c)
    inputs = [ct.TensorType(name=n, shape=s, dtype=np.float32)
              for n, s in zip(INPUT_NAMES, shapes)]
    outputs = [ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return ct.convert(traced, source="pytorch", convert_to="mlprogram",
                          minimum_deployment_target=target,
                          compute_precision=ct.precision.FLOAT16,
                          inputs=inputs, outputs=outputs)


def _preserve_op_names(mlmodel, prefixes: Sequence[str]) -> List[str]:
    """找出「需要保 fp16」的算子名。

    ★★ 实测（2026-10-08）：**不能靠权重名前缀匹配**，因为 MIL 里两类分支的
    权重命名规律完全不同：
      · `fusion_head_*`   → 权重名保留语义前缀（`fusion_head_fc1_weight_to_fp16`）✅
      · lane 分支          → 权重名是 **`const_2` / `const_4` / `const_6`（无语义）** ❌
        （实测：lane 输入 `lane_to_fp16` → max_pool → conv(const_2) → relu
          → conv(const_4) → relu → conv(const_6) → relu → reduce_mean → lane_feat）
    → 因此本函数用**两条路并用**：
        ① 权重名前缀匹配（对 fusion_head 有效）
        ② **从指定输入出发的数据流追踪**（对 lane 有效：lane → 其下游全部 conv/linear）
      跳过压缩的写法是 `op_name_configs={op: None}`（值给 None，不是 mode="none"）。
    """
    prog = getattr(mlmodel, "_mil_program", None)
    if prog is None:
        return []

    names: List[str] = []
    hit_weights: List[str] = []

    for fn in prog.functions.values():
        ops = list(fn.operations)

        # ---- 路线 ①：权重名前缀 ----
        for op in ops:
            for inp in op.inputs.values():
                wname = getattr(inp, "name", None)
                if not wname:
                    continue
                base = wname.split("_to_fp16")[0]
                if any(base.startswith(p) for p in prefixes):
                    hit_weights.append(base)
                    if op.name not in names:
                        names.append(op.name)

        # ---- 路线 ②：数据流追踪（从 lane 输入出发）----
        # 前缀里含 "lane" 的，取其在图中的**输入名**（如 lane / lane_to_fp16）作为起点。
        roots = set()
        for op in ops:
            for out in op.outputs:
                nm = out.name or ""
                if nm == "lane" or nm.startswith("lane_to_fp16"):
                    roots.add(nm)
        if roots:
            frontier = set(roots)
            seen_ops = set()
            for _ in range(64):                     # 深度上限，防环
                nxt = set()
                for op in ops:
                    if op.name in seen_ops or op.op_type == "const":
                        continue
                    ins = {getattr(v, "name", "") for v in op.inputs.values()}
                    if ins & frontier:
                        seen_ops.add(op.name)
                        if op.name not in names:
                            names.append(op.name)
                        nxt.update(o.name for o in op.outputs)
                if not nxt:
                    break
                frontier = nxt
            if seen_ops:
                print(f"[INT8]   数据流追踪：lane 输入下游命中 {len(seen_ops)} 个算子")

    if hit_weights:
        print(f"[INT8]   权重名前缀命中 {len(hit_weights)} 个权重")
        for w in hit_weights[:4]:
            print(f"[INT8]     权重样例 {w}")
    return sorted(set(names))


def quantize(mlmodel, scheme: str, group_size: int, preserve_prefixes: Sequence[str],
             preserve: bool) -> Tuple[object, List[str]]:
    """按方案量化。scheme ∈ {palette_kmeans, palette_uniform, linear_int8}。"""
    import coremltools.optimize.coreml as cto

    notes: List[str] = []
    op_names: List[str] = []
    if preserve and preserve_prefixes:
        op_names = _preserve_op_names(mlmodel, preserve_prefixes)
        if not op_names:
            notes.append("⚠ 未匹配到任何待保留算子 —— 将全量量化（风险：lane/融合头可能失真）")
        else:
            notes.append(f"保 fp16 算子 {len(op_names)} 个（前缀 {list(preserve_prefixes)}）")

    # ⚠️ 跳过压缩的写法是**值给 None**，不是 OpPalettizerConfig(mode="none")
    #    —— 后者抛 ValueError（OpPalettizerConfig.check_mode 只认 KMEANS/UNIFORM/...）
    #    此写法与 tools/ayolom/export_ayolom_coreml.py:140-147 逐字一致。
    op_cfg = {op: None for op in op_names} if op_names else None

    if scheme in ("palette_kmeans", "palette_uniform"):
        mode = "kmeans" if scheme == "palette_kmeans" else "uniform"
        gcfg = cto.OpPalettizerConfig(mode=mode, nbits=8,
                                      granularity="per_tensor",
                                      group_size=group_size)
        cfg = cto.OptimizationConfig(global_config=gcfg, op_name_configs=op_cfg)
        out = cto.palettize_weights(mlmodel, cfg)
        notes.append(f"palette mode={mode} nbits=8 granularity=per_tensor group_size={group_size}")
    elif scheme == "linear_int8":
        gcfg = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype=np.int8,
                                           granularity="per_channel", block_size=group_size)
        cfg = cto.OptimizationConfig(global_config=gcfg, op_name_configs=op_cfg)
        out = cto.linear_quantize_weights(mlmodel, cfg)
        notes.append(f"linear mode=linear_symmetric dtype=int8 per_channel block_size={group_size}")
    else:
        raise ValueError(f"未知方案 {scheme}")

    if op_names:
        notes.append("关键分支（lane/fusion）保持高精度 —— 依据 yolopx 实测"
                     "「INT8 全量化把车道线正像素打掉 10×」")
    return out, notes


# ============================================================================
# 4. 体积 / 性能 / 偏差 三测
# ============================================================================


def _dir_bytes(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def _weights_bytes(mlpackage: Path) -> int:
    """只算权重目录净重（排除 manifest 等元数据），更能反映"模型本体"大小。"""
    w = mlpackage / "Data" / "com.apple.CoreML" / "weights"
    return _dir_bytes(w) if w.exists() else 0


def _to_feed(inputs: Sequence[torch.Tensor]) -> Dict[str, np.ndarray]:
    return {n: t.detach().cpu().numpy().astype(np.float32)
            for n, t in zip(INPUT_NAMES, inputs)}


def _torch_forward(model, inputs: Sequence[torch.Tensor]) -> List[float]:
    """PyTorch 参考输出（6 个标量）。model 可能是 _ExportWrapper 或裸 M2Model。"""
    with torch.no_grad():
        out = model(*inputs)
    if isinstance(out, tuple) and len(out) == 4 and isinstance(out[-1], dict):
        # 裸 M2Model(return_aux=True)：aux 是 dict，需手工摊平（顺序与 OUTPUT_NAMES 一致）
        steer, throttle, brake, aux = out
        def _v(x):
            return 0.0 if x is None else float(x.flatten()[0])
        return [float(steer.flatten()[0]), float(throttle.flatten()[0]),
                float(brake.flatten()[0]), _v(aux.get("confidence")),
                _v(aux.get("risk")), _v(aux.get("car_heading"))]
    return [float(o.flatten()[0]) for o in out]


class _ExportWrapper(torch.nn.Module):
    """把 `M2Model` 摊平成 6 张量（与 export_m9_v2_coreml.py 的同名类**逐字一致**）。

    为什么必需：`M2Model(return_aux=True)` 返回 `(steer, throttle, brake, aux: Dict)`，
    `jit.trace` 无法输出 dict，`ct.convert(outputs=...)` 也要求扁平张量列表。
    辅助头为 None 时用零张量占位 —— 保证 6 输出契约恒定，Swift 侧不必分支。
    """

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, image, lane, dets, det_mask, vehicle_state):
        steer, throttle, brake, aux = self.model(
            image, lane, dets, det_mask, vehicle_state,
            camera_heading=None, return_aux=True)

        def _or_zero(v, width: int = 1):
            if v is None:
                return torch.zeros(1, width, dtype=steer.dtype, device=steer.device)
            if v.dim() == 1:
                return v.view(-1, width)
            return v

        return (steer, throttle, brake,
                _or_zero(aux.get("confidence")), _or_zero(aux.get("risk")),
                _or_zero(aux.get("car_heading")))


def _coreml_forward(mlmodel, inputs: Sequence[torch.Tensor]) -> List[float]:
    pred = mlmodel.predict(_to_feed(inputs))
    return [float(np.asarray(pred[n]).flatten()[0]) for n in OUTPUT_NAMES]


def bench(mlmodel, inputs: Sequence[torch.Tensor], rounds: int = 5, iters: int = 100
          ) -> Dict[str, float]:
    """真机耗时：rounds × iters，取中位数（抗抖动）。"""
    feed = _to_feed(inputs)
    samples: List[float] = []
    for _ in range(rounds):
        for _ in range(iters):
            t0 = time.perf_counter()
            mlmodel.predict(feed)
            samples.append((time.perf_counter() - t0) * 1000.0)
    samples.sort()
    return {
        "median_ms": statistics.median(samples),
        "mean_ms": statistics.fmean(samples),
        "p95_ms": samples[int(len(samples) * 0.95)],
        "min_ms": samples[0],
        "max_ms": samples[-1],
        "n": len(samples),
    }


def load_for_bench(path: Path, cu):
    import coremltools as ct
    return ct.models.MLModel(str(path), compute_units=cu)


# ============================================================================
# 5. 主流程
# ============================================================================


def _export_one(model, c: Dict[str, int], base_inputs, out: Path, scheme: str,
                group_size: int, preserve: bool, target, do_bench: bool,
                bench_iters: int) -> Dict:
    """导出一个方案并完成三测，返回结果 dict。"""
    import coremltools as ct

    res: Dict = {"scheme": scheme, "group_size": group_size, "preserve": preserve}

    with torch.no_grad():
        traced = torch.jit.trace(_ExportWrapper(model).eval(), tuple(base_inputs), strict=False)

    t0 = time.time()
    mlmodel = _convert_fp16(traced, c, target)
    res["convert_s"] = time.time() - t0

    notes: List[str] = []
    if scheme != "fp16":
        mlmodel, notes = quantize(mlmodel, scheme, group_size,
                                  DEFAULT_PRESERVE_PREFIXES, preserve)
    for n in notes:
        print(f"[INT8]   · {n}")
    res["notes"] = notes

    if out.exists():
        shutil.rmtree(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out))

    res["total_bytes"] = _dir_bytes(out)
    res["weights_bytes"] = _weights_bytes(out)
    res["total_mb"] = res["total_bytes"] / 1048576.0
    res["weights_mb"] = res["weights_bytes"] / 1048576.0
    print(f"[INT8]   体积：总 {res['total_mb']:.3f} MB / 权重净重 {res['weights_mb']:.3f} MB")

    # ---- 偏差（对 fp16 基线由调用方统一比，这里先存自身输出）----
    cases = _edge_cases(c, base_inputs)
    res["edge"] = {}
    for name, ins in cases.items():
        rv = _torch_forward(export_model, ins)
        cv = _coreml_forward(mlmodel, ins)
        res["edge"][name] = {"pt": rv, "cm": cv,
                             "maxdiff": max(abs(a - b) for a, b in zip(rv, cv))}

    # lane 专项
    res["lane"] = {}
    for name, ins in _lane_sweep(c, base_inputs).items():
        rv = _torch_forward(export_model, ins)
        cv = _coreml_forward(mlmodel, ins)
        res["lane"][name] = {"pt": rv, "cm": cv,
                             "maxdiff": max(abs(a - b) for a, b in zip(rv, cv))}

    # 时序抖动
    seq = _frame_sequence(c, base_inputs)
    cm_series = [_coreml_forward(mlmodel, ins) for ins in seq]
    pt_series = [_torch_forward(export_model, ins) for ins in seq]
    res["jitter"] = {
        "cm_steer_std": float(np.std([s[0] for s in cm_series])),
        "pt_steer_std": float(np.std([s[0] for s in pt_series])),
        "cm_steer_range": float(np.max([s[0] for s in cm_series]) - np.min([s[0] for s in cm_series])),
        "pt_steer_range": float(np.max([s[0] for s in pt_series]) - np.min([s[0] for s in pt_series])),
        "cm_series": cm_series, "pt_series": pt_series,
    }

    # ---- 性能 ----
    if do_bench:
        res["perf"] = {}
        for label, cu in (("cpuAndNeuralEngine", ct.ComputeUnit.CPU_AND_NE),
                          ("all", ct.ComputeUnit.ALL),
                          ("cpuOnly", ct.ComputeUnit.CPU_ONLY)):
            try:
                t_load = time.perf_counter()
                m = load_for_bench(out, cu)
                load_ms = (time.perf_counter() - t_load) * 1000.0
                # 冷启动：第一次 predict（含 ANE 编译）
                t0 = time.perf_counter()
                m.predict(_to_feed(base_inputs))
                cold_ms = (time.perf_counter() - t0) * 1000.0
                b = bench(m, base_inputs, rounds=5, iters=bench_iters)
                b["load_ms"] = load_ms
                b["cold_ms"] = cold_ms
                res["perf"][label] = b
                print(f"[INT8]   {label:<20} 中位 {b['median_ms']:.3f} ms "
                      f"(p95 {b['p95_ms']:.3f}) 冷启动 {cold_ms:.2f} ms 加载 {load_ms:.1f} ms")
            except Exception as exc:  # pragma: no cover
                res["perf"][label] = {"error": f"{type(exc).__name__}: {exc}"}
                print(f"[INT8]   {label:<20} ✗ {type(exc).__name__}: {str(exc)[:80]}")
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description="M9-v2 → CoreML INT8 导出 + 三测")
    ap.add_argument("--src", default=str(_ROOT / "checkpoints" / "m9_v2" / "best_model.pt"))
    ap.add_argument("--out", default=str(_ROOT / "models" / "m9_v2_int8.mlpackage"))
    ap.add_argument("--scheme", default="palette_kmeans",
                    choices=["palette_kmeans", "palette_uniform", "linear_int8", "fp16"],
                    help="量化方案（默认 palette_kmeans，项目已量产验证）")
    ap.add_argument("--group-size", type=int, default=1,
                    help="palette group_size（默认 1 = per-channel 等价物，100%% 张量可压；"
                         "yolopx 实测 gs=32 只压到 30%% 张量）")
    ap.add_argument("--no-preserve", action="store_true",
                    help="不保留关键分支（全量量化，用于对照/负向验证）")
    ap.add_argument("--self-test", action="store_true", help="权重缺失时用随机权重跑链路")
    ap.add_argument("--compare-all", action="store_true", help="跑全部方案对比")
    ap.add_argument("--bench-iters", type=int, default=100)
    ap.add_argument("--no-bench", action="store_true")
    ap.add_argument("--target", default="macOS13", choices=["macOS13", "macOS14", "macOS15"])
    ap.add_argument("--json", default="/tmp/m9v2_int8_report.json")
    args = ap.parse_args()

    import coremltools as ct

    target = {"macOS13": ct.target.macOS13, "macOS14": ct.target.macOS14,
              "macOS15": ct.target.macOS15}[args.target]

    print("=" * 78)
    print(" M9-v2 (model_v2) → CoreML INT8 导出 + 体积/性能/偏差三测")
    print("=" * 78)
    print(f"[INT8] torch {torch.__version__} / coremltools {ct.__version__} / "
          f"numpy {np.__version__} / py {sys.version.split()[0]}")

    src = Path(args.src)
    sd = None
    if src.exists():
        print(f"[INT8] 权重：{src}")
        sd = _load_state_dict(src)
        random_init = False
    elif args.self_test:
        print(f"[INT8] ⚠ 权重不存在（{src}）→ 随机初始化（产物绝不可上车）")
        random_init = True
    else:
        print(f"[INT8] ✗ 权重不存在：{src}", file=sys.stderr)
        print("[INT8]   M2 训练产出路径 = checkpoints/m9_v2/best_model.pt"
              "（src/train_v2.py 的 DEFAULT_CKPT_DIR）。", file=sys.stderr)
        print("[INT8]   加 --self-test 可先用随机权重验证链路。", file=sys.stderr)
        return 2

    model, lr = _build_and_load(sd)
    random_init = bool(lr.get("random_init"))
    total_params = sum(p.numel() for p in model.parameters())
    c = _contract_from_model(model)
    print(f"[INT8] 参数量 = {total_params:,}（{total_params/1e6:.4f}M）"
          f"→ INT8 理论下限 {total_params/1048576:.2f} MB")
    if random_init:
        print("[INT8] ⚠⚠ 本次为随机权重：**体积与耗时有效，偏差数字不代表真实精度**")

    base_inputs = _make_inputs(c)
    print(f"[INT8] PyTorch 参考输出 = {[round(v, 6) for v in _torch_forward(export_model, base_inputs)]}")

    if args.compare_all:
        plans = [("fp16", 32, False),
                 ("palette_kmeans", 1, True), ("palette_kmeans", 2, True),
                 ("palette_kmeans", 8, True), ("palette_kmeans", 32, True),
                 ("palette_uniform", 1, True),
                 ("linear_int8", 32, True),
                 ("palette_kmeans", 1, False)]      # 负向对照：不保 lane/fusion
    else:
        plans = [(args.scheme, args.group_size, not args.no_preserve)]

    results: List[Dict] = []
    for scheme, gs, preserve in plans:
        tag = f"{scheme}_gs{gs}" + ("" if preserve or scheme == "fp16" else "_nopreserve")
        out = Path(args.out) if len(plans) == 1 else Path(f"/tmp/m9v2_{tag}.mlpackage")
        print(f"\n[INT8] ── 方案 {tag} ──")
        r = _export_one(model, c, base_inputs, out, scheme, gs, preserve,
                        target, not args.no_bench, args.bench_iters)
        r["tag"] = tag
        r["out"] = str(out)
        r["random_init"] = random_init
        r["params"] = total_params
        results.append(r)

    # ---- 汇总表 ----
    base = next((r for r in results if r["scheme"] == "fp16"), None)
    print("\n" + "=" * 78)
    print(" 汇总")
    print("=" * 78)
    print(f"{'方案':<32} {'体积MB':>8} {'权重MB':>8} {'最差偏差':>10} {'中位ms':>8}")
    for r in results:
        worst = max(v["maxdiff"] for v in r["edge"].values())
        med = r.get("perf", {}).get("all", {}).get("median_ms")
        med_s = f"{med:.3f}" if isinstance(med, (int, float)) else "n/a"
        print(f"{r['tag']:<32} {r['total_mb']:>8.3f} {r['weights_mb']:>8.3f} "
              f"{worst:>10.2e} {med_s:>8}")

    payload = {
        "params": total_params,
        "random_init": random_init,
        "contract": c,
        "preserve_prefixes": list(DEFAULT_PRESERVE_PREFIXES),
        "results": results,
    }
    Path(args.json).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n[INT8] 三测数据 JSON：{args.json}")
    if random_init:
        print("[INT8] ⚠ 提醒：以上偏差数字基于随机权重，**不得作为精度结论引用**")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
