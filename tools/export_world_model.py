#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""世界模型 (src/world_model.py · WorldModel) → CoreML 单模型导出 + INT8 量化

================================================================================
0. 这是什么
================================================================================
    世界模型是 MoE 结构（3 专家：高速 / 低速 / 赛道），预测下一帧 fused。
    本脚本把它**单独**导成一个 CoreML 模型（world.mlmodelc），并做：
      · INT8 palette+kmeans 量化（用户铁律：nbits=8）
      · compute_units / 算子派发验证（GPU preferred = 0，无 while_loop / logical_and）
      · 数值验证（PyTorch forward vs CoreML predict，maxdiff < 1e-3）

================================================================================
1. 契约（输入/输出，与 Swift 侧逐字对齐）
================================================================================
    输入（全部 float32）：
        fused          [1, 512]   上一帧融合特征
        action         [1, 3]     steer / throttle / brake
        det_feat       [1, 128]   检测特征（投影后）
        det_mask       [1, 20]    检测有效掩码
        vehicle_state  [1, 8]     车辆状态
        track_mode     [1, 1]     0=自动, 1=赛道（路由器强提示）
    输出（全部 float32）：
        predicted_next_fused  [1, 512]  下一帧融合特征预测
        routing_weights       [1, 3]    MoE 路由权重（诊断用）

================================================================================
2. INT8 方案（借鉴 tools/export_m9_v2_int8.py 已量产配方）
================================================================================
    · palette + kmeans，nbits=8（用户铁律，不可改 16）
    · granularity=per_tensor，group_size=1
        ── yolopx 实测：gs=32 只压到 30% 张量（channel_num % gs != 0 就静默跳过）；
           gs=1 = 100% 张量覆盖。本脚本铁定 gs=1。
    · compute_precision=FLOAT16（ANE 原生），IO 恒 fp32（ct 坑 3）
    · 目标体积 ≤ 3MB（3 专家 MoE，INT8 ≈ 1 byte/param）

================================================================================
3. compute_units 验证（MLComputePlan 算子级证据）
================================================================================
    · 【Python 侧·硬门槛】转换后扫 MIL program：
        - 不得出现 while_loop（_StrictGRUStep 手展开 GRU，见 src/model_v2.py §7.5）
          → nn.GRUCell 会 trace 出 unsafe_chunk/loop，CoreML 不认，导出必炸。
        - 不得出现 logical_and（路由/掩码用乘法，不能用逻辑与）
      出现即中止导出。
    · 【Swift 侧·派发证据】xcrun 编译 .mlpackage → .mlmodelc，再跑
        tools/ane_dispatch_check.swift（MLComputePlan 算子级 preferred）：
        - 确认 GPU preferred = 0（全部 preferred=ANE 或 CPU，不落 GPU）
        - 打印非 ANE 算子清单
      （coremltools Python 不暴露 MLComputePlan，只能走 Swift。）

================================================================================
4. 数值验证
================================================================================
    · 同一批随机输入，PyTorch forward 与 CoreML.predict 逐元素比
    · predicted_next_fused maxdiff < 1e-3（硬门槛）
    · routing_weights maxdiff 仅报告（诊断输出，容差放宽到 1e-2）

================================================================================
5. 与 W1 的依赖
================================================================================
    src/world_model.py 由 W1 撰写，可能尚未完成。
    · 若 `from world_model import WorldModel` 成功 → 正常导出
    · 若 ImportError → 脚本用内置 _StubWorldModel（同契约 I/O）跑通框架，
      产物**绝不可上车**（随机权重），仅供链路/量化/派发验证。
      加 --self-test 强制走 stub。

用法
----
    # 正式导出（W1 完成后）
    ./.venv-yolo26/bin/python3 tools/export_world_model.py \\
        --src checkpoints/world_model/best.pt \\
        --out models/world_model.mlpackage

    # 框架自检（W1 没交货时）
    ./.venv-yolo26/bin/python3 tools/export_world_model.py --self-test \\
        --out /tmp/world_probe.mlpackage

    # 编译 + Swift 派发检查（导出后）
    ./.venv-yolo26/bin/python3 tools/export_world_model.py --self-test \\
        --out /tmp/world_probe.mlpackage --dispatch-check
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(_ROOT / "src"))
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import torch  # noqa: E402
import torch.nn as nn  # noqa: E402

# ============================================================================
# 契约常量 —— 单一事实源应是 src/world_model.py（W1 撰写中），此处先钉死 I/O 形状
# ============================================================================

#: CoreML 输入名（与 Swift 侧逐字对齐，顺序即 forward 参数顺序）
INPUT_NAMES: Tuple[str, ...] = (
    "fused", "action", "det_feat", "det_mask", "vehicle_state", "track_mode",
)

#: CoreML 输出名
OUTPUT_NAMES: Tuple[str, ...] = ("predicted_next_fused", "routing_weights")

#: 输入形状（batch=1）
INPUT_SHAPES: Tuple[Tuple[int, ...], ...] = (
    (1, 512),   # fused
    (1, 3),     # action (steer/throttle/brake)
    (1, 128),   # det_feat
    (1, 20),    # det_mask
    (1, 8),     # vehicle_state
    (1, 1),     # track_mode (0=自动, 1=赛道)
)

#: 输出形状
OUTPUT_SHAPES: Tuple[Tuple[int, ...], ...] = (
    (1, 512),   # predicted_next_fused
    (1, 3),     # routing_weights
)

#: MIL 里【禁止出现】的算子类型（lowercase 匹配）
_FORBIDDEN_OP_TYPES = ("while_loop", "logical_and")

#: INT8 铁律
NBITS = 8
GROUP_SIZE = 1
TARGET_BYTES = 3 * 1024 * 1024   # ≤ 3MB


# ============================================================================
# 1. WorldModel 加载（W1 依赖处理）
# ============================================================================

#: 真实 WorldModel 是否可用（import 成功 = True）
try:
    from world_model import WorldModel  # type: ignore  # noqa: E402
    _HAVE_WORLD_MODEL = True
except Exception as _imp_err:  # noqa: WPS433
    _HAVE_WORLD_MODEL = False
    _IMPORT_ERROR = str(_imp_err)
    WorldModel = None  # type: ignore


class _StubWorldModel(nn.Module):
    """与 WorldModel 同 I/O 契约的占位模型（W1 未交货时跑通框架用）。

    ⚠️ 随机权重，产物绝不可上车。结构尽量贴近真实 MoE：
        · 3 专家 MLP（512→512→512），路由器 Linear(512+6→3)+softmax
        · 用 _StrictGRUStep 风格的**基础算子**（Linear/sigmoid/tanh/mul），
          绝不碰 nn.GRUCell（会 trace 出 while_loop → CoreML 炸）。
        · 路由/掩码一律乘法，不用 logical_and。
    """

    NUM_EXPERTS = 3
    FUSED_DIM = 512

    def __init__(self) -> None:
        super().__init__()
        cond_dim = self.FUSED_DIM + 3 + 128 + 20 + 8 + 1   # fused+action+det_feat+det_mask+state+track_mode
        # 路由器：条件 → 3 个专家权重（softmax，无 logical_and）
        self.router = nn.Linear(cond_dim, self.NUM_EXPERTS)
        # 3 个专家：各自 fused → next_fused
        self.experts = nn.ModuleList([
            nn.Sequential(nn.Linear(self.FUSED_DIM, self.FUSED_DIM),
                          nn.Tanh(),
                          nn.Linear(self.FUSED_DIM, self.FUSED_DIM))
            for _ in range(self.NUM_EXPERTS)
        ])
        # 动作条件注入（action 影响下一帧预测）
        self.action_proj = nn.Linear(3, self.FUSED_DIM)

    def forward(self, fused, action, det_feat, det_mask, vehicle_state, track_mode):
        # ── 路由条件（拼接，纯 Linear，无逻辑算子）──
        cond = torch.cat([fused, action, det_feat, det_mask, vehicle_state, track_mode], dim=1)
        logits = self.router(cond)                       # [1, 3]
        routing_weights = torch.softmax(logits, dim=1)   # [1, 3]

        # ── 专家输出（每专家独立 forward，再加权求和）──
        act = self.action_proj(action)                   # [1, 512]
        expert_outs = [exp(fused) + act for exp in self.experts]   # list of [1,512]
        stacked = torch.stack(expert_outs, dim=1)        # [1, 3, 512]
        rw = routing_weights.unsqueeze(-1)               # [1, 3, 1]
        predicted_next_fused = (stacked * rw).sum(dim=1) # [1, 512] —— 加权求和，无 logical_and
        return predicted_next_fused, routing_weights


class _ExportWorldModel(nn.Module):
    """把 WorldModel 摊平成 6 输入 2 输出的导出包装（batch=1 固定）。

    为什么必需（W1 的 WorldModel.forward 签名与导出契约有三处 gap）：
      ① forward 有 8 个参数（含可选 h_high / h_low GRU 隐状态）。
         导出契约只要 6 个输入 —— 隐状态是**内部循环状态**，不应作为 CoreML 输入。
         这里固定用 buffer 的零初始化（WorldModel 已 register_buffer h_high_init/h_low_init），
         等价于「单步预测、无历史隐状态」。
      ② track_mode 维度规整里有 `tm.shape[1] != 1`（Python bool 比较），
         trace 会 TracerWarning 且控制流被烤死。wrapper 强制传 [B,1]，绕开那段分支。
      ③ 输出是 (pred_next_fused, routing_weights) tuple —— 直接返回，ct 用 outputs= 钉名。

    ★ 不引入新的 GRU / 循环 —— WorldModel 内部已用 _StrictGRUStep（手展开，无 while_loop），
      本 wrapper 只是「签名整形」，不改变算子结构。
    """

    def __init__(self, wm: nn.Module) -> None:
        super().__init__()
        self.wm = wm
        # 隐状态 buffer：单步预测用零初始化（与 WorldModel.h_high_init/h_low_init 一致）
        # 已在 WorldModel 里 register_buffer，这里直接引用，不重复注册。

    def forward(self, fused, action, det_feat, det_mask, vehicle_state, track_mode):
        # track_mode 强制 [B,1]，绕开 WorldModel.forward 里的 Python bool 控制流
        if track_mode.dim() == 0:
            tm = track_mode.unsqueeze(0).unsqueeze(0)
        elif track_mode.dim() == 1:
            tm = track_mode.unsqueeze(1)
        else:
            tm = track_mode
        # 隐状态传 None → WorldModel 用 buffer 的零初始化（单步预测）
        pred_next_fused, routing_weights = self.wm(
            fused, action, det_feat, det_mask, vehicle_state, tm,
            h_high=None, h_low=None)
        return pred_next_fused, routing_weights


def build_world_model(src: Optional[Path]) -> Tuple[nn.Module, Dict]:
    """构建 WorldModel 并加载权重（若有）。

    Returns: (model, meta) —— meta 含 random_init / missing / unexpected。
    """
    if not _HAVE_WORLD_MODEL:
        print(f"[WM导出] ⚠ src/world_model.py 不可用（{ _IMPORT_ERROR if not _HAVE_WORLD_MODEL else 'n/a'}）")
        print("[WM导出]   → 使用 _StubWorldModel（随机权重，产物绝不可上车）")
        m = _StubWorldModel().eval()
        return m, {"random_init": True, "stub": True,
                   "missing": 0, "unexpected": 0}

    # TODO(W1): 真实 WorldModel 的构造签名 / checkpoint 字段名以 W1 落地为准。
    #   目前按「WorldModel() 无参构造 + state_dict 直接 load」的常见形态写。
    m = WorldModel().eval()
    meta: Dict = {"random_init": True, "stub": False, "missing": 0, "unexpected": 0}
    if src is not None and src.exists():
        ck = torch.load(str(src), map_location="cpu", weights_only=False)
        sd = ck.get("model_state_dict", ck) if isinstance(ck, dict) else ck
        sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v
              for k, v in sd.items()}
        res = m.load_state_dict(sd, strict=False)
        meta.update(random_init=False,
                    missing=len(res.missing_keys),
                    unexpected=len(res.unexpected_keys))
        if res.missing_keys:
            print(f"[WM导出]   ⚠ missing={len(res.missing_keys)} 样例: {list(res.missing_keys)[:5]}")
        if res.unexpected_keys:
            print(f"[WM导出]   ⚠ unexpected={len(res.unexpected_keys)} 样例: {list(res.unexpected_keys)[:5]}")
        if hasattr(m, "reparameterize"):
            m.reparameterize()
            print("[WM导出] ✓ reparameterize 完成（RepVGG 折叠）")
    else:
        print(f"[WM导出] ⚠ 权重不存在（{src}）→ 随机初始化（产物绝不可上车）")
    # ★ 用 _ExportWorldModel 包装：钉死 6 输入 2 输出契约，固定 batch=1，
    #   隐状态用 buffer 零初始化（单步预测），绕开 track_mode 的 Python bool 控制流。
    export_m = _ExportWorldModel(m).eval()
    return export_m, meta


# ============================================================================
# 2. 输入构造 + 数值验证
# ============================================================================


def make_inputs(seed: int = 0) -> List[torch.Tensor]:
    """确定性随机输入（训练分布内近似）。track_mode 给 0（自动模式）。"""
    g = torch.Generator().manual_seed(seed)
    fused = torch.rand(1, 512, generator=g) * 2.0 - 1.0
    action = torch.rand(1, 3, generator=g) * 2.0 - 1.0   # steer/throttle/brake ∈ [-1,1]
    det_feat = torch.rand(1, 128, generator=g)
    det_mask = (torch.rand(1, 20, generator=g) > 0.35).float()
    vehicle_state = torch.rand(1, 8, generator=g) * 2.0 - 1.0
    track_mode = torch.zeros(1, 1)                        # 0 = 自动
    return [fused, action, det_feat, det_mask, vehicle_state, track_mode]


def torch_forward(model: nn.Module, inputs: Sequence[torch.Tensor]
                  ) -> Tuple[np.ndarray, np.ndarray]:
    with torch.no_grad():
        nxt, rw = model(*inputs)
    return (nxt.detach().cpu().numpy().astype(np.float32),
            rw.detach().cpu().numpy().astype(np.float32))


def coreml_predict(mlmodel, inputs: Sequence[torch.Tensor]
                   ) -> Tuple[np.ndarray, np.ndarray]:
    feed = {n: t.detach().cpu().numpy().astype(np.float32)
            for n, t in zip(INPUT_NAMES, inputs)}
    pred = mlmodel.predict(feed)
    return (np.asarray(pred["predicted_next_fused"]).astype(np.float32),
            np.asarray(pred["routing_weights"]).astype(np.float32))


def verify_numerical(model: nn.Module, mlmodel, seeds: Sequence[int] = (0, 1, 2)
                     ) -> Dict:
    """PyTorch vs CoreML，多 seed 取最差 maxdiff。"""
    worst_next = 0.0
    worst_rw = 0.0
    detail = []
    for s in seeds:
        ins = make_inputs(s)
        pt_nxt, pt_rw = torch_forward(model, ins)
        cm_nxt, cm_rw = coreml_predict(mlmodel, ins)
        d_next = float(np.abs(pt_nxt - cm_nxt).max())
        d_rw = float(np.abs(pt_rw - cm_rw).max())
        worst_next = max(worst_next, d_next)
        worst_rw = max(worst_rw, d_rw)
        detail.append({"seed": s, "next_maxdiff": d_next, "rw_maxdiff": d_rw})
        flag = "✅" if d_next < 1e-3 else "❌"
        print(f"[WM导出]   seed={s}: next_maxdiff={d_next:.3e}  rw_maxdiff={d_rw:.3e}  {flag}")
    ok = worst_next < 1e-3
    print(f"[WM导出] {'✓' if ok else '✗'} 数值验证：next 最差 {worst_next:.3e}"
          f"（门槛 1e-3）{'通过' if ok else '失败'}")
    return {"worst_next_maxdiff": worst_next, "worst_rw_maxdiff": worst_rw,
            "pass": ok, "detail": detail}


# ============================================================================
# 3. 转换 + INT8 量化
# ============================================================================


def convert_coreml(model: nn.Module, inputs: Sequence[torch.Tensor], target):
    """trace → ct.convert（FLOAT16，macOS15，mlprogram，IO 恒 fp32）。"""
    import coremltools as ct

    with torch.no_grad():
        traced = torch.jit.trace(model, tuple(inputs), strict=False)

    # ── 反证：trace 图里不该有 GRU/RNN/loop（世界模型若用循环必须手展开）──
    kinds: Dict[str, int] = {}
    for node in traced.inlined_graph.nodes():
        k = str(node.kind())
        kinds[k] = kinds.get(k, 0) + 1
    bad_trace = [k for k in kinds if any(t in k.lower()
                 for t in ("gru", "rnn", "while", "loop"))]
    if bad_trace:
        print(f"[WM导出] ⚠ trace 图含疑似循环算子: {bad_trace}（应手展开为 Linear）")
    else:
        print(f"[WM导出] ✓ trace 图无 GRU/RNN/loop 算子（{sum(kinds.values())} 个算子）")

    ml_in = [ct.TensorType(name=n, shape=s, dtype=np.float32)
             for n, s in zip(INPUT_NAMES, INPUT_SHAPES)]
    # ★ outputs 不能带 shape（ct 自动从输入+算子推断；带 shape 抛 ValueError）
    #   与 export_m9_v2_int8.py 的 _convert_fp16 一致。
    ml_out = [ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES]

    ml = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        minimum_deployment_target=target,
        compute_precision=ct.precision.FLOAT16,
        inputs=ml_in,
        outputs=ml_out,
    )
    return ml


def palettize_int8(mlmodel) -> object:
    """INT8 palette+kmeans 量化（nbits=8 铁律，group_size=1 = 100% 覆盖）。

    ★ 与 tools/export_m9_v2_int8.py 的量产配方一致：
        OpPalettizerConfig(mode="kmeans", nbits=8,
                           granularity="per_tensor", group_size=1)
      group_size=1 是 100% 覆盖的关键（gs=32 只压到 30% 张量）。
    ★ 世界模型全量量化（无 lane/fusion 保精度需求；路由权重诊断用，
      若数值验证不过可加 --preserve-router 逃生口）。
    """
    import coremltools.optimize.coreml as cto

    gcfg = cto.OpPalettizerConfig(
        mode="kmeans",
        nbits=NBITS,                 # = 8（铁律）
        granularity="per_tensor",
        group_size=GROUP_SIZE,       # = 1（100% 覆盖）
    )
    cfg = cto.OptimizationConfig(global_config=gcfg)
    out = cto.palettize_weights(mlmodel, cfg)
    print(f"[WM导出] ✓ INT8 palette: mode=kmeans nbits={NBITS} "
          f"granularity=per_tensor group_size={GROUP_SIZE}")
    return out


# ============================================================================
# 4. MIL 算子检查（while_loop / logical_and 硬门槛）
# ============================================================================


def _walk_mil_ops(prog) -> List[Tuple[str, str]]:
    """递归收集 (op_type, op_name)。

    ★ coremltools 8.3 的 MIL Function **本身就是 block**（有 .operations），
      不像 MIL ops 那样有 .block。op 可能有 .blocks（嵌套 region），递归进去。
    """
    out: List[Tuple[str, str]] = []
    def walk(block):
        for op in block.operations:
            out.append((op.op_type, op.name))
            for sub in getattr(op, "blocks", []) or []:
                walk(sub)
    for fn in prog.functions.values():
        walk(fn)   # fn 即 block
    return out


def check_mil_forbidden(mlmodel) -> Dict:
    """扫 MIL program，确认无 while_loop / logical_and。"""
    prog = getattr(mlmodel, "_mil_program", None)
    if prog is None:
        return {"available": False, "forbidden_hits": {}, "total_ops": 0}
    ops = _walk_mil_ops(prog)
    kinds: Dict[str, int] = {}
    forbidden: Dict[str, List[str]] = {}
    for t, name in ops:
        tl = t.lower()
        kinds[tl] = kinds.get(tl, 0) + 1
        if tl in _FORBIDDEN_OP_TYPES:
            forbidden.setdefault(tl, []).append(name)
    total = len(ops)
    print(f"[WM导出] MIL 算子总数 {total}，禁止算子命中: "
          f"{ {k: len(v) for k, v in forbidden.items()} or '无' }")
    if forbidden:
        for k, names in forbidden.items():
            print(f"[WM导出]   ❌ {k} ×{len(names)} 样例: {names[:5]}")
    else:
        print(f"[WM导出] ✓ 无 while_loop / logical_and（_StrictGRUStep 手展开达标）")
    return {"available": True, "forbidden_hits": {k: len(v) for k, v in forbidden.items()},
            "total_ops": total, "kinds": kinds}


# ============================================================================
# 5. 编译 + Swift 派发检查（MLComputePlan，GPU preferred = 0）
# ============================================================================


def run_dispatch_check(mlpackage: Path, outdir: Path) -> Dict:
    """xcrun 编译 .mlpackage → .mlmodelc，再跑 ane_dispatch_check.swift。

    解析 swift 输出，确认 GPU preferred = 0。
    （coremltools Python 不暴露 MLComputePlan，只能走 Swift。）
    """
    swift_tool = _ROOT / "tools" / "ane_dispatch_check.swift"
    res: Dict = {"ran": False}
    if not swift_tool.exists():
        res["error"] = f"swift 工具不存在: {swift_tool}"
        print(f"[WM导出] ⚠ {res['error']}")
        return res

    outdir.mkdir(parents=True, exist_ok=True)
    mlmodelc = outdir / (mlpackage.stem + ".mlmodelc")
    if mlmodelc.exists():
        shutil.rmtree(mlmodelc)

    # ── 编译 ──
    t0 = time.time()
    cp = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(mlpackage), str(outdir)],
        capture_output=True, text=True)
    res["compile_s"] = time.time() - t0
    if cp.returncode != 0:
        res["error"] = f"coremlcompiler 失败: {cp.stderr.strip()[:200]}"
        print(f"[WM导出] ⚠ {res['error']}")
        return res
    print(f"[WM导出] ✓ 编译 → {mlmodelc}（{res['compile_s']:.1f}s）")

    # ── Swift 派发检查 ──
    sp = subprocess.run(
        ["swift", str(swift_tool), str(mlmodelc)],
        capture_output=True, text=True)
    res["ran"] = True
    res["swift_stdout"] = sp.stdout
    res["swift_stderr"] = sp.stderr
    if sp.returncode != 0:
        res["error"] = f"swift 退出 {sp.returncode}: {sp.stderr.strip()[:200]}"
        print(f"[WM导出] ⚠ {res['error']}")
        return res

    # ── 解析 preferred 设备派发表 ──
    # swift 输出形如：
    #   preferred 设备派发:
    #     gpu     12  (5.1%)
    #     ane    220  (94.9%)
    gpu_count = None
    device_counts: Dict[str, int] = {}
    in_table = False
    for line in sp.stdout.splitlines():
        if "preferred 设备派发" in line:
            in_table = True
            continue
        if in_table:
            if not line.strip() or line.startswith("─"):
                continue
            # 行形如 "  ane    220  (94.9%)" 或 "  ane   ×220"
            parts = line.split()
            if len(parts) >= 2:
                dev = parts[0]
                try:
                    cnt = int(parts[1].lstrip("×"))
                    device_counts[dev] = cnt
                except ValueError:
                    pass
            if "ANE cost 占比" in line or "supported" in line:
                in_table = False
    gpu_count = device_counts.get("gpu", 0)
    res["device_counts"] = device_counts
    res["gpu_preferred"] = gpu_count
    ok = gpu_count == 0
    res["gpu_zero"] = ok
    print(f"[WM导出] preferred 派发: {device_counts}")
    print(f"[WM导出] {'✓' if ok else '✗'} GPU preferred = {gpu_count}（要求 0）")
    if not ok:
        print(f"[WM导出]   ⚠ 有 {gpu_count} 个算子 preferred=GPU，需排查")
    return res


# ============================================================================
# 6. 体积
# ============================================================================


def dir_bytes(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def weights_bytes(mlpackage: Path) -> int:
    w = mlpackage / "Data" / "com.apple.CoreML" / "weights"
    return dir_bytes(w) if w.exists() else 0


# ============================================================================
# 7. 主流程
# ============================================================================


def main() -> int:
    ap = argparse.ArgumentParser(description="世界模型 → CoreML 单模型 + INT8 量化")
    ap.add_argument("--src", default=str(_ROOT / "checkpoints" / "world_model" / "best.pt"),
                    help="WorldModel checkpoint（W1 产出）")
    ap.add_argument("--out", default=str(_ROOT / "models" / "world_model.mlpackage"))
    ap.add_argument("--target", default="macOS15",
                    choices=["macOS13", "macOS14", "macOS15"])
    ap.add_argument("--self-test", action="store_true",
                    help="W1 未交货时用 _StubWorldModel 跑通框架（产物不可上车）")
    ap.add_argument("--dispatch-check", action="store_true",
                    help="导出后编译 + 跑 ane_dispatch_check.swift（GPU preferred=0）")
    ap.add_argument("--no-verify", action="store_true",
                    help="跳过数值验证（debug 用）")
    ap.add_argument("--json", default="/tmp/world_model_export_report.json")
    args = ap.parse_args()

    import coremltools as ct
    target = {"macOS13": ct.target.macOS13, "macOS14": ct.target.macOS14,
              "macOS15": ct.target.macOS15}[args.target]

    print("=" * 78)
    print(" 世界模型 (WorldModel) → CoreML 单模型 + INT8 量化")
    print("=" * 78)
    print(f"[WM导出] torch {torch.__version__} / coremltools {ct.__version__} "
          f"/ numpy {np.__version__} / py {sys.version.split()[0]}")
    print(f"[WM导出] WorldModel 可用: {_HAVE_WORLD_MODEL}"
          + ("" if _HAVE_WORLD_MODEL else f"（{_IMPORT_ERROR}）"))

    # ── 1. 构建模型 ──
    src = Path(args.src)
    if not _HAVE_WORLD_MODEL:
        if not args.self_test:
            print("[WM导出] ✗ src/world_model.py 不可用且未加 --self-test，中止", file=sys.stderr)
            print("[WM导出]   W1 还在写世界模型，等其交付后再正式导出。", file=sys.stderr)
            return 2
        src = None
    model, meta = build_world_model(src)
    total_params = sum(p.numel() for p in model.parameters())
    print(f"[WM导出] 参数量 = {total_params:,}（{total_params/1e6:.4f}M）"
          f"→ INT8 理论下限 {total_params/1048576:.2f} MB")
    if meta.get("random_init"):
        print("[WM导出] ⚠⚠ 随机权重：体积/派发/图结构有效，**数值偏差不代表真实精度**")

    # ── 2. trace + convert ──
    base_inputs = make_inputs(0)
    print(f"\n[WM导出] ── trace + convert（FLOAT16 / {args.target} / mlprogram）──")
    t0 = time.time()
    mlmodel = convert_coreml(model, base_inputs, target)
    print(f"[WM导出] ✓ convert 完成（{time.time()-t0:.1f}s）")

    # ── 3. INT8 量化 ──
    print(f"\n[WM导出] ── INT8 palette+kmeans（nbits={NBITS} gs={GROUP_SIZE}）──")
    t0 = time.time()
    mlmodel = palettize_int8(mlmodel)
    print(f"[WM导出] ✓ 量化完成（{time.time()-t0:.1f}s）")

    # ── 4. MIL 算子检查（硬门槛）──
    print(f"\n[WM导出] ── MIL 算子检查（禁 while_loop / logical_and）──")
    mil_check = check_mil_forbidden(mlmodel)
    if mil_check.get("forbidden_hits"):
        print("[WM导出] ❌ 出现禁止算子，中止导出（需手展开 GRU / 改逻辑与为乘法）")
        return 3

    # ── 5. 保存 + 体积 ──
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out))
    total_b = dir_bytes(out)
    weights_b = weights_bytes(out)
    print(f"\n[WM导出] ✓ 已保存: {out}")
    print(f"[WM导出]   体积：总 {total_b/1048576:.3f} MB / 权重净重 {weights_b/1048576:.3f} MB"
          f"（目标 ≤ {TARGET_BYTES/1048576:.1f} MB）")
    size_ok = total_b <= TARGET_BYTES
    if not size_ok:
        print(f"[WM导出]   ⚠ 超目标 { (total_b-TARGET_BYTES)/1048576:.3f} MB"
              "（3 专家 MoE 参数量决定下限；可减 expert 隐藏维或专家数）")

    # ── 6. 数值验证 ──
    verify: Dict = {"skipped": False}
    if not args.no_verify:
        print(f"\n[WM导出] ── 数值验证（PyTorch vs CoreML，门槛 1e-3）──")
        verify = verify_numerical(model, mlmodel, seeds=(0, 1, 2))
    else:
        print("[WM导出] 跳过数值验证（--no-verify）")

    # ── 7. 编译 + Swift 派发检查（可选）──
    dispatch: Dict = {"skipped": True}
    if args.dispatch_check:
        print(f"\n[WM导出] ── 编译 + Swift 派发检查（MLComputePlan）──")
        dispatch = run_dispatch_check(out, out.parent)

    # ── 汇总 ──
    report = {
        "params": total_params,
        "meta": meta,
        "target": args.target,
        "int8": {"nbits": NBITS, "group_size": GROUP_SIZE,
                 "mode": "kmeans", "granularity": "per_tensor"},
        "size": {"total_bytes": total_b, "weights_bytes": weights_b,
                 "total_mb": total_b/1048576, "weights_mb": weights_b/1048576,
                 "target_mb": TARGET_BYTES/1048576, "ok": size_ok},
        "mil_check": {k: v for k, v in mil_check.items()
                      if k != "kinds"},   # kinds 太长，单独不进 report
        "verify": verify,
        "dispatch": dispatch,
        "out": str(out),
    }
    Path(args.json).write_text(json.dumps(report, ensure_ascii=False, indent=2),
                               encoding="utf-8")
    print(f"\n[WM导出] 报告 JSON: {args.json}")

    print("\n" + "=" * 78)
    ok_all = size_ok and (verify.get("pass", True)) and not mil_check.get("forbidden_hits")
    if args.dispatch_check:
        ok_all = ok_all and dispatch.get("gpu_zero", False)
    print(f" 完成 → {out}")
    print(f"   INT8: kmeans nbits=8 gs=1（100% 覆盖）")
    print(f"   体积: {total_b/1048576:.3f} MB（目标 ≤3MB {'✓' if size_ok else '✗'}）")
    print(f"   数值: next maxdiff {verify.get('worst_next_maxdiff', 'n/a')}（门槛 1e-3）")
    if args.dispatch_check:
        print(f"   GPU preferred: {dispatch.get('gpu_preferred', 'n/a')}（要求 0）")
    print(f"   deployable: {not meta.get('random_init')}")
    print("=" * 78)
    return 0 if ok_all else 1


if __name__ == "__main__":
    raise SystemExit(main())
