#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
M2 (model_v2) 端到端驾驶模型 → CoreML 导出（多输入 / 多输出）

================================================================================
0. 这个脚本是什么、依赖谁
================================================================================
把 `src/model_v2.py` 的 `M2Model` 导出为 CoreML `.mlpackage` / `.mlmodelc`。

依赖（硬）：
    · src/model_v2.py          模型定义（M2 交付件；缺失即报错退出）
    · checkpoints/m9_v2/best_model.pt   训练产出（src/train_v2.py 的默认输出目录）
    · .venv-yolo26/bin/python3  py3.11 + torch + coremltools 8.3（项目主 venv 是
      py3.14，coremltools 无可用轮子，故沿用既有导出脚本的 venv 约定）

★ 与既有导出脚本的关系（红线）：
    本文件是**新建文件**。`tools/export_game_assist_coreml.py`（单目 2 输入）与
    `tools/export_yolo26s_coreml.py` **一行都没有改动**。M2 是 5 输入模型，
    输入/输出契约与那两个模型都不同，因此必须独立成脚本，不能复用。

用法：
    # 正式导出（需先跑完训练）
    ./.venv-yolo26/bin/python3 tools/export_m9_v2_coreml.py \
        --src checkpoints/m9_v2/best_model.pt \
        --out models/m9_v2.mlmodelc \
        --precision float16

    # 训练还没跑完？先用随机权重验证**转换链路**本身是否通
    #   （产出的模型是随机权重，**只能用来验证管线，绝不可上车**）
    ./.venv-yolo26/bin/python3 tools/export_m9_v2_coreml.py --self-test --out /tmp/m9_v2_probe.mlmodelc

================================================================================
1. ★ 输入 / 输出契约（与 Swift `InferenceEngine` 逐字对齐）
================================================================================
契约真值来自 `src/model_v2.py` 的 `M2Model.__init__`（`self.img_h` / `self.max_detections`
等），本脚本**从模型实例读取**而不是硬编码，避免两侧漂移。

┌───────────────┬──────────────────────┬────────┬──────────────────────────────┐
│ 名称          │ shape                │ dtype  │ 含义                         │
├───────────────┼──────────────────────┼────────┼──────────────────────────────┤
│ image         │ [1, 3, 180, 320]     │ f32    │ 第三视角截图，CHW，[0,1] 归一 │
│ lane          │ [1, 1, 160, 160]     │ f32    │ 车道线掩码，二值 0/1          │
│ dets          │ [1, 20, 12]          │ f32    │ 检测框固定槽位，空槽补 0      │
│ det_mask      │ [1, 20]              │ f32    │ 1=有效框，0=空槽              │
│ vehicle_state │ [1, 8]               │ f32    │ 车辆状态（见下）              │
├───────────────┼──────────────────────┼────────┼──────────────────────────────┤
│ steer         │ [1, 1]               │ f32    │ tanh    ∈ [-1, 1]            │
│ throttle      │ [1, 1]               │ f32    │ sigmoid ∈ [0, 1]             │
│ brake         │ [1, 1]               │ f32    │ sigmoid ∈ [0, 1]             │
└───────────────┴──────────────────────┴────────┴──────────────────────────────┘

每框 12 维（`dets` 第 3 维）：
    [0] x  中心 x 归一化 [0,1]        ← Swift `Detection.x`
    [1] y  中心 y 归一化 [0,1]        ← Swift `Detection.y`
    [2] w  宽 归一化 [0,1]            ← Swift `Detection.width`
    [3] h  高 归一化 [0,1]            ← Swift `Detection.height`
    [4:8] label one-hot(car, pedestrian, sign, obstacle)  ← Swift `Detection.Label`
    [8] confidence [0,1]              ← Swift `Detection.confidence`
    [9] speed    框内目标相对速度（无则 0）
    [10] heading 框内目标朝向（无则 0）
    [11] age     连续跟踪帧数归一化（无跟踪则 0）

`vehicle_state` 8 维（归一化约定务必与采集侧一致）：
    [0] speed          车速/速度上限      ∈ [0,1]
    [1] accel          纵向加速度/10 m·s⁻² ∈ [-1,1]   ← 需求⑤
    [2] heading        当前角度/π         ∈ [-1,1]   ← 需求⑤
    [3] heading_rate   角度变化率/π·s⁻¹    ∈ [-1,1]
    [4] curvature      路径曲率           ∈ [-1,1]
    [5] lateral_offset 相对车道中心横偏    ∈ [-1,1]
    [6] steer_angle    方向盘角/最大角     ∈ [-1,1]
    [7] reserved       预留（ego_visible 标志）

⛔ 契约红线：**不含可行驶区域（drivableMask / daGrid）**。用户明确要求"可行驶
   区域不要收"。任何把 drivableMask 拼进 lane 通道的做法都破坏本契约。
⛔ 第三视角下自车也会被检测成框，该框必须在 Swift 侧 `EgoBoxFilter` 剔除后
   再喂给本模型；模型只收 `ego_visible` 标志位（vehicle_state[7]）。

================================================================================
2. ★★ CoreML 转换的坑（全部本机实测，coremltools 8.3 / macOS 26.6 / torch 2.13）
================================================================================

【坑 1 · 输入名 `state` 被静默重命名 → Swift 侧 KeyError】
    coremltools 8.3 把名为 `state` 的输入**静默改名**为 `state_workaround`
    （`state` 与 MIL 内部状态变量保留字冲突）。实测：
        TensorType(name="state")          → 实际生成 'state_workaround'
        TensorType(name="vehicle_state")  → 原样保留 'vehicle_state'
    且报错发生在**推理时**而非转换时：
        KeyError: Provided key "state" ... does not match any of the model
        input name(s), which are: {'dets','det_mask','lane','state_workaround','image'}
    → 本脚本统一用 `vehicle_state`（恰好与 InferenceEngine.swift 既有契约同名）。
    → 脚本内有断言（`_assert_no_renamed_inputs`），改名即报错退出，绝不静默放过。
    ⚠️ 试过 `ct.utils.rename_feature(spec, "state_workaround", "state")` 想改回来：
      **行不通**，抛
        ValueError: Input/output names for ML Program must be of the format
        [a-zA-Z_][a-zA-Z0-9_]*. ... Provided feature name, "state" does not satisfy
      即 `state` 这个名字在 mlprogram 后端本身就不合法，改名是 coremltools 的
      保护行为，不是 bug。**替代方案 = 换个名字**，没有第二条路。

【坑 2 · 变长 N（动态 shape）在 CoreML 上是死路】
    M2 的检测框数量天然变长（0~20）。两条动态 shape 路线**实测均不可行**：
      · `ct.RangeDim(1, 64, default=20)` → 转换期直接崩：
            IndexError: list assignment index out of range
      · `ct.EnumeratedShapes([[1,4,12],[1,20,12]])` → 转换能过，但**编译期崩**：
            RuntimeError: Failed to build the model execution plan ... error code: -7
        且 CoreML 硬限制"每个模型最多一个 enumerated-shape 输入"，而 dets 与
        det_mask 的 N 必须联动 → 两个输入都要 enumerated → 直接报
            "A model supports up to one input feature with enumerated shapes,
             but it configures these input features to use the enumerated shape
             flexibility: [det_mask, dets]"
    → **唯一可行方案 = 固定 N + valid 位**（即本脚本方案）：
        N 固定为 20，空槽 dets 全 0、det_mask 置 0。
        `DetectionEncoder` 用 `torch.where(mask>0, x, -inf)` 做 masked max pool +
        `_masked_mean_pool` 做 masked mean pool，因此**空槽的 0 值不会污染输出**，
        0 个框 / 3 个框 / 20 个框语义完全正确。已在 §精度校验的 no_dets/all_empty
        用例里逐项验证（与 PyTorch 输出一致）。
    → Swift 侧**不需要**改模型，只需保证喂满 20 槽。少喂会直接报 shape 错，
      不会静默算错（见坑 4）。

【坑 3 · `compute_precision=FLOAT16` 会把输入/输出也变成 fp16】
    实测 spec：
        compute_precision=FLOAT16 + 不给 IO dtype → IN/OUT 全部 dataType=65552 (FLOAT16)
        compute_precision=FLOAT16 + IO dtype=fp32 → IN/OUT 全部 65568 (FLOAT32) ★
    而 `InferenceEngine.swift` 构造的是 `.float32` MLMultiArray（且已有复用缓冲
    `reusableImageBuffer`/`reusableStateBuffer` 都是 `.float32`）。
    → 本脚本**显式给所有输入/输出指定 `dtype=np.float32`**，把 fp16 只留在**图内部**：
        · ANE 仍然按 fp16 算（速度收益全保留）
        · Swift 侧零改动、无需碰复用缓冲
        · 精度实测与 fp16 IO 版**完全一致**（maxdiff 6.39e-04，逐位同值）
    已部署的 `models/game_assist_control.mlpackage` 也是 FLOAT32 IO，口径一致。

【坑 4 · 输入顺序错位会报错，不会静默算错】
    `ct.convert(inputs=[...])` 的顺序**必须**与 `torch.jit.trace` 的实参顺序一致。
    实测把 dets/det_mask 对调 → 转换期抛
        IndexError: list assignment index out of range
    属于"安全失败"，不会产出错模型。但**不要依赖它报错**：本脚本用
    `_INPUT_SPEC` 单一常量表同时驱动 trace 与 convert，从结构上杜绝错位。

【坑 5 · 训练期探针 `lane_steer_probe.*` 必须剥离】
    `src/train_v2.py` 会把 `LaneSteerProbe` 挂成模型子模块随 checkpoint 存取
    （它只服务训练期损失，不参与推理）。若原样 `load_state_dict`，
    探针权重会以 unexpected_keys 形式混入并**被 trace 进计算图**（多一堆无用算子）。
    → 本脚本在 load 前按前缀过滤掉所有 `lane_steer_probe.` 键，并打印剥离数量。

【坑 6 · RepVGG 必须走「训练态构建 → load → reparameterize」】
    与 `export_game_assist_coreml.py` 同源的致命坑：训练存档是**多分支训练态**
    （rbr_3x3 / rbr_1x1 / rbr_identity）。若用 `build_model(deploy=True)` 直接
    `load_state_dict(strict=False)`，融合态结构只有 `rbr_reparam` 键，多分支权重
    **全部被静默丢弃** → 导出随机权重模型。
    → 本脚本自动检测权重态并选择正确路径，且**导出后打印参数量核对**。

【坑 7 · Manifest.json 是 coremltools 的洁癖，不是 CoreML 的要求】
    这条**很容易误判**，故把实测证据写全。用 Swift 直接 `MLModel(contentsOf:)`
    验证（真机 CoreML 路径，macOS 26.6）：

        OK    /tmp/.../ct1/m9_v2.mlmodelc     ← xcrun coremlc 产物（无 Manifest.json）
              inputs=["det_mask","dets","image","lane","vehicle_state"]
              in image shape=[1,3,180,320] dtype=65568   ← 65568 = FLOAT32 ✓
        OK    models/game_assist_control.mlmodelc        ← 仓库现有模型（同样无 Manifest.json）
        FAIL  run1/m9_v2.mlpackage
              "Compile the model with Xcode or `MLModel.compileModel(at:)`"
        FAIL  models/game_assist_control.mlpackage       ← 同上

    结论（三条，全部与直觉相反）：
      ① `xcrun coremlc compile` 产出的 `.mlmodelc` **不带** Manifest.json，
         但**真机 CoreML 能正常加载** —— 它就是可部署产物。
      ② `ct.models.MLModel()`（Python）**要求** Manifest.json，否则抛
             RuntimeError: A valid manifest does not exist at path: .../Manifest.json
         所以「Python 侧加载不了」≠「模型不能用」。本脚本的精度校验因此
         走 `.mlpackage`（Python 可加载），转换正确性等价。
      ③ `.mlpackage` **不能**被 `MLModel(contentsOf:)` 直接加载，必须先
         `MLModel.compileModel(at:)`。
         ⚠️ 顺带发现（**不在本次改动范围，仅记录**）：`InferenceEngine.swift:142-150`
            的 `modelURL` 在 .mlmodelc 缺失时会回退返回 `.mlpackage`，而
            `loadIfNeeded()` 直接 `MLModel(contentsOf: modelURL)` —— 这条回退路径
            按上述实测**是走不通的**（对比 `YolopxEngine` 有显式 `compileModel`）。
            本脚本因此**始终优先产出可用的 .mlmodelc**，不依赖该回退。
    → 本脚本：优先 `xcrun coremlc`，成功判据 = `model.mil` + `coremldata.bin` 存在
      （**不是** Manifest.json）；失败才退回「仅 .mlpackage」并明确告警。

【坑 8 · 无害但吓人的 RuntimeWarning】
    转换期可能出现：
        RuntimeWarning: overflow encountered in cast
        (coremltools/.../elementwise_unary.py:889)
    来源是 `DetectionEncoder` 的 `torch.finfo(x.dtype).min`（fp32 的 -3.4e38）
    在常量折叠时往 fp16 转 → -inf。**语义上正是我们想要的**（空槽置 -inf 再
    max pool，全空时由 `where(valid_any>0, ...)` 归零），实测 all_empty 用例
    与 PyTorch 输出一致。**可以忽略**，但在这里写明以免后人误判。
    另有 TracerWarning 关于 `dets.shape[1] == 0` 的 Python 布尔：
    该分支在 trace 时被固化为"N≠0"这一支 —— 正是我们要的（N 恒为 20）。
    ⚠️ 因此**绝不允许用 N=0 去 trace**，脚本内有 `--num-dets >= 1` 校验。

================================================================================
3. ★ computeUnits 策略（项目已实测，不要乱改）
================================================================================
本脚本**不写死** computeUnits —— 它属于**运行时加载配置**，在 Swift 侧：

    InferenceEngine.swift:164 / :206   config.computeUnits = .all
    YolopxEngine.swift:730             config.computeUnits = .all

`.all` 是项目用 ABBA 交错协议复测两轮后**钉死**的结论（`YolopxEngine.swift:695-716`）：
    场景          .all        .cpuAndNeuralEngine
    空载        183.0 ms        204.6 ms      ← .all 快 10.6%
    8 核满载    191.4 ms        199.1 ms      ← .all 快  3.9%
两个场景 `.all` 都更快，且负载下差距**收窄而非扩大**，推翻了"避开 GPU 收益更大"
的假设。真正的瓶颈是 Espresso 把 62.8% 的算子派给了 CPU 后端
（`BnnsCpuInferenceOperation`），而它**不受 computeUnits 控制**——`.all` 已经是
"让 CoreML 自己挑最优"的结果，人工指定反而更差（`.cpuAndGpu` 慢一倍多且曾触发
MPSGraph SIGABRT；`.cpuOnly` 548ms+）。

→ 本脚本只保证**导出配置**与 `.all` 相容：
    · `convert_to="mlprogram"` + `minimum_deployment_target=macOS13`
      （ANE 需要 mlprogram；neuralnetwork 是 legacy 格式，ANE 支持差）
    · `compute_precision=FLOAT16`（图内 fp16，ANE 原生）
    · IO dtype 固定 fp32（见坑 3，不改 Swift 侧缓冲类型）
    · int8 **只作为兜底档**，默认不产（见下）

★ int8 量化（`--precision int8`）—— 默认关闭，理由充分：
    实测（同一权重、同一批输入，5 个用例取最差）：
        fp16  maxdiff = 1.26e-03   体积 6.07 MB
        int8  maxdiff = 8.39e-03   体积 3.08 MB
    int8 把误差放大 **6.7×**，而 `src/model_v2.py` §4 已写明"控制模型输出为连续
    回归量，量化误差可能引入转向抖动"。项目内已有先例：`tools/yolopx/export_yolopx_coreml.py`
    实测 int8 把车道线正像素占比从 1.30–1.80% 打到 0.13–0.21%（**掉 10×**），
    结论"INT8 全量化已证伪，勿用"。
    → 本脚本默认 `float16`；int8 需显式指定，且**精度校验阈值自动收紧并告警**。

================================================================================
4. 产物
================================================================================
    <out>.mlpackage        未编译源模型（调试/对拍用）
    <out>.mlmodelc         编译产物（xcrun coremlc，带 Manifest.json，可直接加载）
    <out 同目录>/m9_v2_contract.json   （--emit-contract 时）机器可读契约，供 Swift 侧核对
"""

import argparse
import json
import shutil
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
import coremltools as ct  # noqa: E402


# ============================================================================
# 1. 契约常量（唯一事实源：src/model_v2.py）
# ============================================================================

#: CoreML 输入名（顺序 = trace 实参顺序 = convert inputs 顺序，三者必须一致）
# ★ 方案 A（Lead 2026-10-08 拍板）：image 的 batch=8 就是时序窗口 ——
#   模型接收 8 帧原图 [8,3,180,320]，内部 batch 跑一次 ImageEncoder（真机实测 1.62ms，
#   比 8 次 batch=1 快 18%），得到 8×256 特征后**当作 N=8 序列喂 GRU**（[B=1,N=8,C]）。
#   两个维度不要搞混：图像的 batch8 变成时序的 N8。
#   ⚠️ 不加 history_feats/frame_mask 输入（不再需要，模型内部消化）。
INPUT_NAMES: Tuple[str, ...] = ("image", "lane", "dets", "det_mask", "vehicle_state")

#: CoreML 输出名（顺序 = M2Model.forward(return_aux=True) 的返回顺序）
# ★ M4 三个新头上车（t1 验证抓出的部署链路缺失）：
#   confidence/risk ∈ [0,1]（w4 风险头）、car_heading 归一化 Δheading（w3 车头朝向头）
OUTPUT_NAMES: Tuple[str, ...] = ("steer", "throttle", "brake",
                                 "confidence", "risk", "car_heading")

#: coremltools 对名为 `state` 的输入会静默改名的目标（坑 1）
_RENAMED_STATE = "state_workaround"

#: 训练期探针键前缀（坑 5）——导出前必须剥离
_TRAINING_PROBE_PREFIX = "lane_steer_probe."


def _load_state_dict(src: Path) -> Dict[str, torch.Tensor]:
    """读取 checkpoint，剥离 torch.compile 前缀与训练期探针。

    与 `export_game_assist_coreml.py::_load_sd` 同款处理，额外多一步探针剥离。
    """
    ckpt = torch.load(src, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    # 剥离 torch.compile 的 _orig_mod. 包装前缀
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    # 剥离训练期探针（坑 5）
    probe_keys = [k for k in sd if k.startswith(_TRAINING_PROBE_PREFIX)]
    for k in probe_keys:
        del sd[k]
    if probe_keys:
        print(f"[导出] 剥离训练期探针 {len(probe_keys)} 个键 "
              f"（{_TRAINING_PROBE_PREFIX}*，仅训练期损失用，不参与推理）")
    return sd


def _build_and_load(sd: Optional[Dict[str, torch.Tensor]], src: Optional[Path]):
    """构建 M2Model 并加载权重，返回 (model, load_report)。

    ★ 关键：训练态构建 → load → reparameterize（坑 6）。
    用 deploy=True 构建会因键名不匹配**静默丢弃全部 RepVGG 多分支权重**。
    """
    try:
        from src.model_v2 import build_model  # noqa: WPS433
    except ImportError as exc:  # pragma: no cover - 依赖缺失时的明确报错
        print(f"[导出] ✗ 无法导入 src.model_v2：{exc}", file=sys.stderr)
        print("[导出]   M2 的模型定义尚未落地。本脚本按约定接口编写，"
              "等 src/model_v2.py 就位后即可直接运行。", file=sys.stderr)
        raise SystemExit(2)

    if sd is None:
        print("[导出] ⚠ --self-test / --allow-random-init：使用**随机初始化**权重")
        print("[导出]   ⚠ 产物只能验证转换链路，**绝不可上车**")
        model = build_model(deploy=False)
        model.eval()
        model.reparameterize()
        return model, {"missing": 0, "unexpected": 0, "random_init": True}

    # 检测权重态：融合态（rbr_reparam）还是训练态（rbr_3x3 多分支）
    has_reparam = any("rbr_reparam" in k for k in sd)
    if has_reparam:
        print("[导出] 权重为融合态(rbr_reparam) → deploy=True 构建直接 load")
        model = build_model(deploy=True)
        res = model.load_state_dict(sd, strict=False)
    else:
        print("[导出] 权重为训练态(rbr_3x3 多分支) → deploy=False 构建 + reparameterize 融合")
        model = build_model(deploy=False)
        res = model.load_state_dict(sd, strict=False)
        model.reparameterize()
    model.eval()
    return model, {
        "missing": len(res.missing_keys),
        "unexpected": len(res.unexpected_keys),
        "missing_keys": list(res.missing_keys)[:8],
        "unexpected_keys": list(res.unexpected_keys)[:8],
        "random_init": False,
    }


def _contract_from_model(model) -> Dict[str, int]:
    """从模型实例读取契约尺寸（单一事实源，避免两侧漂移）。"""
    c = {
        "img_h": int(getattr(model, "img_h", 180)),
        "img_w": int(getattr(model, "img_w", 320)),
        "lane_size": int(getattr(model, "lane_size", 160)),
        "num_dets": int(getattr(model, "max_detections", 20)),
        "det_feat_dim": int(getattr(model, "det_in_dim", 12)),
        "state_dim": int(getattr(model, "state_dim", 8)),
    }
    # ★ 方案 A：时序窗口 N（= image 的 batch 维度）。
    #   从模型的时序编码器读真实值（单一事实源），读不到用默认 8。
    n_frames = 8
    te = getattr(model, "temporal_encoder", None)
    if te is not None:
        n_frames = int(getattr(te, "num_frames", 8))
    c["num_frames"] = n_frames
    return c


def _shapes(c: Dict[str, int]) -> List[Tuple[int, ...]]:
    """按 INPUT_NAMES 顺序给出各输入 shape（顺序即契约，勿单独调整）。

    ★ 方案 A：image 是 [num_frames, 3, H, W]（batch=时序窗口），不是 [1,...]。
    """
    return [
        (c["num_frames"], 3, c["img_h"], c["img_w"]),   # image ← batch=8 = 时序窗口
        (1, 1, c["lane_size"], c["lane_size"]),         # lane
        (1, c["num_dets"], c["det_feat_dim"]),          # dets
        (1, c["num_dets"]),                             # det_mask
        (1, c["state_dim"]),                            # vehicle_state
    ]


# ============================================================================
# 2. 输入构造 / 精度校验用例
# ============================================================================

def _make_inputs(c: Dict[str, int], seed: int = 0) -> List[torch.Tensor]:
    """构造一组**在训练分布内**的确定性输入（固定 seed，保证可复现）。

    ★ 方案 A：`image` 是 [num_frames, 3, H, W]（batch 维 = 时序窗口），
    其余分支仍是单帧 [1,...] —— 正是模型内部 `seq_mode` 判定的触发条件
    （image.dim0=8 ≠ 其他分支 dim0=1）。
    """
    g = torch.Generator().manual_seed(seed)
    img = torch.rand(c["num_frames"], 3, c["img_h"], c["img_w"], generator=g)
    # 车道线是稀疏细线（实测正像素占比 1~2%），用高阈值伯努利逼近真实分布
    lane = (torch.rand(1, 1, c["lane_size"], c["lane_size"], generator=g) > 0.985).float()
    dets = torch.rand(1, c["num_dets"], c["det_feat_dim"], generator=g)
    det_mask = (torch.rand(1, c["num_dets"], generator=g) > 0.35).float()
    state = torch.rand(1, c["state_dim"], generator=g) * 2.0 - 1.0
    return [img, lane, dets, det_mask, state]


def _edge_cases(c: Dict[str, int], base: Sequence[torch.Tensor]
                ) -> Dict[str, List[torch.Tensor]]:
    """边界用例：**空输入是真实驾驶的常态而非异常**（model_v2 §5 硬性要求）。

    每一项都对应 model_v2 明确支持的一条空输入路径，必须与 PyTorch 逐项对拍。
    """
    img, lane, dets, det_mask, state = base
    z_lane = torch.zeros_like(lane)
    z_dets = torch.zeros_like(dets)
    z_mask = torch.zeros_like(det_mask)
    z_state = torch.zeros_like(state)
    return {
        "normal":     [img, lane, dets, det_mask, state],
        "no_dets":    [img, lane, z_dets, z_mask, state],            # 0 个框
        "no_lane":    [img, z_lane, dets, det_mask, state],          # 车道线全丢
        "zero_state": [img, lane, dets, det_mask, z_state],          # 遥测未接入
        "all_empty":  [img, z_lane, z_dets, z_mask, z_state],        # 感知全丢
        "saturated":  [torch.ones_like(img), torch.ones_like(lane),
                       torch.ones_like(dets), torch.ones_like(det_mask),
                       torch.ones_like(state)],                      # 全饱和
    }


def _to_feed(inputs: Sequence[torch.Tensor]) -> Dict[str, np.ndarray]:
    """按 INPUT_NAMES 组装 CoreML 输入 dict（**fp32**，与坑 3 的 IO dtype 一致）。"""
    return {n: t.detach().cpu().numpy().astype(np.float32)
            for n, t in zip(INPUT_NAMES, inputs)}


class _ExportWrapper(torch.nn.Module):
    """把 `M2Model` 包装成**导出所需的多输出形态**（6 个张量）。

    【为什么必须有这一层】（t1 验证抓出的部署链路缺失）
      `M2Model.forward(..., return_aux=True)` 返回 `(steer, throttle, brake, aux: Dict)`，
      **第二个返回值是 dict** —— `torch.jit.trace` 无法把 dict 作为图输出，
      `ct.convert(outputs=[...])` 也要求扁平张量列表。
      所以导出前必须把 aux 里的 3 个头**拆成位置固定的张量**，顺序与 OUTPUT_NAMES 一致。

    【为什么要有 fallback 分支】
      辅助头在运行时可能失败（model_v2 内部 catch 后置 None，这是刻意的 fail-safe）。
      但**导出时 trace 必须看到真实张量**，否则该输出会缺 shape、CoreML 拿不到。
      故 None 时用同 batch 的零张量占位 —— 与运行时"该头不可用"语义一致，
      且保证 6 输出契约**恒定**（Swift 侧不必做"有时有有时无"的分支）。
    """

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, image, lane, dets, det_mask, vehicle_state):
        steer, throttle, brake, aux = self.model(
            image, lane, dets, det_mask, vehicle_state,
            camera_heading=None,      # ← 纯视觉绝对预测（fail-safe，见 heading_head）
            return_aux=True)

        def _or_zero(v, width: int = 1):
            """None → 零张量占位；有值 → 保证是 [1,width] 二维。"""
            if v is None:
                return torch.zeros(1, width, dtype=steer.dtype, device=steer.device)
            if v.dim() == 1:
                return v.view(-1, width)
            return v

        confidence = _or_zero(aux.get("confidence"))
        risk = _or_zero(aux.get("risk"))
        car_heading = _or_zero(aux.get("car_heading"))
        return steer, throttle, brake, confidence, risk, car_heading


def _torch_forward(model, inputs: Sequence[torch.Tensor]) -> List[float]:
    """PyTorch 参考输出（6 个标量）。model 可能是 _ExportWrapper 或裸 M2Model。"""
    with torch.no_grad():
        out = model(*inputs)
    if isinstance(out, tuple) and len(out) == 4 and isinstance(out[-1], dict):
        # 裸 M2Model(return_aux=True) 的形态 → 手工摊平（保持与 OUTPUT_NAMES 同序）
        steer, throttle, brake, aux = out
        def _v(x):
            return 0.0 if x is None else float(x.flatten()[0])
        return [float(steer.flatten()[0]), float(throttle.flatten()[0]),
                float(brake.flatten()[0]), _v(aux.get("confidence")),
                _v(aux.get("risk")), _v(aux.get("car_heading"))]
    return [float(o.flatten()[0]) for o in out]


def _coreml_forward(mlmodel, inputs: Sequence[torch.Tensor]) -> List[float]:
    pred = mlmodel.predict(_to_feed(inputs))
    vals = []
    for n in OUTPUT_NAMES:
        if n not in pred:
            raise RuntimeError(f"CoreML 输出缺少 '{n}'，实际输出：{sorted(pred)}")
        vals.append(float(np.asarray(pred[n]).flatten()[0]))
    return vals


# ============================================================================
# 3. 转换
# ============================================================================

def _assert_input_contract(mlmodel, expected_shapes: Sequence[Tuple[int, ...]]) -> None:
    """转换后立即核对输入名/顺序/shape（坑 1 的自动防线）。"""
    spec = mlmodel.get_spec()
    got = [(x.name, tuple(x.type.multiArrayType.shape)) for x in spec.description.input]
    names = [n for n, _ in got]

    if _RENAMED_STATE in names:
        raise RuntimeError(
            f"输入名被 coremltools 静默重命名：'state' → '{_RENAMED_STATE}'。\n"
            f"  实际输入：{names}\n"
            f"  Swift 侧按原契约取值会抛 KeyError。请改用 'vehicle_state'（见脚本头 坑 1）。"
        )
    if names != list(INPUT_NAMES):
        raise RuntimeError(
            f"输入名/顺序不符契约。\n  期望：{list(INPUT_NAMES)}\n  实际：{names}"
        )
    for (name, shape), want in zip(got, expected_shapes):
        if shape != want:
            raise RuntimeError(f"输入 '{name}' shape 不符：期望 {want}，实际 {shape}")

    out_names = [x.name for x in spec.description.output]
    if out_names != list(OUTPUT_NAMES):
        raise RuntimeError(
            f"输出名/顺序不符契约。\n  期望：{list(OUTPUT_NAMES)}\n  实际：{out_names}"
        )


def convert(traced, c: Dict[str, int], precision: str, target):
    """执行 CoreML 转换。返回 (mlmodel, convert_notes)。"""
    shapes = _shapes(c)
    notes: List[str] = []

    # ★ IO dtype 固定 fp32（坑 3）：fp16 只留在图内部，Swift 侧复用缓冲零改动
    inputs = [ct.TensorType(name=n, shape=s, dtype=np.float32)
              for n, s in zip(INPUT_NAMES, shapes)]
    outputs = [ct.TensorType(name=n, dtype=np.float32) for n in OUTPUT_NAMES]

    convert_kwargs = dict(
        source="pytorch",
        convert_to="mlprogram",                     # ANE 需要 mlprogram（legacy neuralnetwork 不行）
        minimum_deployment_target=target,
        inputs=inputs,
        outputs=outputs,
    )

    if precision == "float16":
        convert_kwargs["compute_precision"] = ct.precision.FLOAT16
    elif precision == "float32":
        convert_kwargs["compute_precision"] = ct.precision.FLOAT32
    # int8：先用 fp16 图转换，再对权重做线性量化（下方处理）

    if precision == "int8":
        convert_kwargs["compute_precision"] = ct.precision.FLOAT16
        notes.append("int8：先转 fp16 图，再对权重做 linear_symmetric/per_channel 量化")

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        mlmodel = ct.convert(traced, **convert_kwargs)
    # 坑 8：把转换期告警如实转述，但不当作失败
    for w in caught:
        msg = str(w.message)
        if "overflow encountered in cast" in msg:
            notes.append("已知无害告警：overflow encountered in cast（fp32 -inf 常量折进 fp16，"
                         "语义正确，见脚本头 坑 8）")
        elif "TracerWarning" in w.category.__name__:
            notes.append(f"TracerWarning：{msg[:100]}（N 恒为 {c['num_dets']}，分支已固化，符合预期）")

    if precision == "int8":
        import coremltools.optimize.coreml as cto
        # ⚠️ coremltools 8.3 的 API 与 9.x 不同：`op_linear_quantizer_config=` 会抛
        #    TypeError: OptimizationConfig.__init__() got an unexpected keyword argument
        #    正确写法是 global_config= / op_type_configs=（见 坑/兼容性说明）
        cfg = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric",
                                                      dtype=np.int8))
        mlmodel = cto.linear_quantize_weights(mlmodel, config=cfg)

    return mlmodel, notes


# ============================================================================
# 4. 编译 / 落盘
# ============================================================================

def _is_compiled_ok(modelc: Path) -> bool:
    """判断 .mlmodelc 是否为可用的编译产物。

    ★ 坑 7：判据**不是** Manifest.json —— `xcrun coremlc` 根本不产这个文件，
      但产物能被真机 CoreML 正常加载（已用 Swift `MLModel(contentsOf:)` 实测通过）。
      Manifest.json 只是 coremltools Python 侧的加载要求。
      真正的编译产物标志是 `model.mil` + `coremldata.bin`。
    """
    return (modelc / "model.mil").exists() and (modelc / "coremldata.bin").exists()


def save_and_compile(mlmodel, out: Path) -> Tuple[Path, Optional[Path], List[str]]:
    """保存 .mlpackage 并编译 .mlmodelc。

    Returns:
        (mlpackage 路径, mlmodelc 路径或 None, notes)

    ★ 坑 7：优先 `xcrun coremlc`；其产物**不带** Manifest.json 但真机可加载。
      编译不可用时**明确降级**为「仅 .mlpackage」，不假装成功。

    ★★ 坑 9（2026-10-08 修复）：`--out` 传 `.mlpackage` 结尾会**自删产物**。
        旧代码：
            mlpackage = out.with_suffix(".mlpackage")   # out 已是 .mlpackage → 同一路径
            mlmodelc  = out                             # → 也是同一路径
            ...
            shutil.rmtree(mlmodelc)                     # → 把刚 save 的产物删掉
        实测症状：打印"✓ 转换完成/源模型已保存"，exit=6，**盘上无文件**（假报成功）。
        修法三条（缺一不可）：
          ① 路径去重：out 以 .mlpackage 结尾时，mlpackage 就是 out 本身，
             编译产物改到 `<stem>.mlmodelc`，两者永不指向同一路径
          ② 落盘后**断言存在**（save 完立刻检查，不存在即抛错）
          ③ **先验证再打印**：任何"已保存/成功"字样都在断言通过之后才输出
    """
    notes: List[str] = []
    out.parent.mkdir(parents=True, exist_ok=True)

    # ---- ① 路径去重（坑 9）----
    # 语义：out 指向**编译产物** .mlmodelc；.mlpackage 永远取同 stem。
    # 若调用方把 out 写成 .mlpackage，则 mlpackage=out、mlmodelc=同 stem 的 .mlmodelc，
    # 绝不出现两者同路径。
    if out.suffix == ".mlpackage":
        mlpackage = out
        mlmodelc = out.with_suffix(".mlmodelc")
    else:
        mlpackage = out.with_suffix(".mlpackage")
        mlmodelc = out
    if mlpackage == mlmodelc:                      # 双保险：任何情况下都不允许同路径
        mlmodelc = mlpackage.with_suffix(".mlmodelc")
    assert mlpackage != mlmodelc, "内部错误：mlpackage 与 mlmodelc 指向同一路径（坑 9）"

    if mlpackage.exists():
        shutil.rmtree(mlpackage)
    mlmodel.save(str(mlpackage))

    # ---- ② 落盘后断言（坑 9）----
    if not mlpackage.exists():
        raise RuntimeError(
            f"保存 .mlpackage 失败：{mlpackage} 不存在。"
            "拒绝继续（避免假报成功）。"
        )
    weight_files = [f for f in mlpackage.rglob("*") if f.is_file()]
    if not weight_files:
        raise RuntimeError(f"保存的 .mlpackage 是空目录：{mlpackage}（拒绝假报成功）")

    # ---- ③ 先验证再打印（坑 9）----
    notes.append(f"源模型已保存并校验存在：{mlpackage}"
                 f"（{len(weight_files)} 个文件）")

    if mlmodelc.exists():
        shutil.rmtree(mlmodelc)

    cmd = ["xcrun", "coremlc", "compile", str(mlpackage), str(mlmodelc.parent)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        r = None
        notes.append("xcrun 不存在（未装 Xcode CLT）→ 无法编译 .mlmodelc")

    if r is not None and r.returncode == 0 and _is_compiled_ok(mlmodelc):
        notes.append(f"编译成功（xcrun coremlc）：{mlmodelc}")
        notes.append("  注：无 Manifest.json 属正常（coremlc 不产该文件）；"
                     "真机 MLModel(contentsOf:) 可加载，Manifest.json 只是 coremltools 的要求")
        return mlpackage, mlmodelc, notes

    if r is not None and r.returncode == 0:
        notes.append(f"⚠ xcrun 返回 0 但 {mlmodelc} 缺 model.mil/coremldata.bin —— 视为编译失败")
    elif r is not None:
        notes.append(f"⚠ xcrun coremlc 失败（rc={r.returncode}）：{r.stderr.strip()[:160]}")

    if mlmodelc.exists():
        shutil.rmtree(mlmodelc, ignore_errors=True)

    # 替代方案：保留 .mlpackage。⚠️ MLModel(contentsOf:) **不能**直接加载 .mlpackage，
    # 调用方必须先 MLModel.compileModel(at:)（见脚本头 坑 7）。
    notes.append("→ 替代方案：仅保留 .mlpackage。⚠️ 加载前必须先走 "
                 "MLModel.compileModel(at:)，否则 MLModel(contentsOf:) 会报 "
                 "'Compile the model with Xcode'")
    return mlpackage, None, notes

    cmd = ["xcrun", "coremlc", "compile", str(mlpackage), str(mlmodelc.parent)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        r = None
        notes.append("xcrun 不存在（未装 Xcode CLT）→ 无法编译 .mlmodelc")

    if r is not None and r.returncode == 0 and _is_compiled_ok(mlmodelc):
        notes.append(f"编译成功（xcrun coremlc）：{mlmodelc}")
        notes.append("  注：无 Manifest.json 属正常（coremlc 不产该文件）；"
                     "真机 MLModel(contentsOf:) 可加载，Manifest.json 只是 coremltools 的要求")
        return mlpackage, mlmodelc, notes

    if r is not None and r.returncode == 0:
        notes.append(f"⚠ xcrun 返回 0 但 {mlmodelc} 缺 model.mil/coremldata.bin —— 视为编译失败")
    elif r is not None:
        notes.append(f"⚠ xcrun coremlc 失败（rc={r.returncode}）：{r.stderr.strip()[:160]}")

    if mlmodelc.exists():
        shutil.rmtree(mlmodelc, ignore_errors=True)

    # 替代方案：保留 .mlpackage。⚠️ MLModel(contentsOf:) **不能**直接加载 .mlpackage，
    # 调用方必须先 MLModel.compileModel(at:)（见脚本头 坑 7）。
    notes.append("→ 替代方案：仅保留 .mlpackage。⚠️ 加载前必须先走 "
                 "MLModel.compileModel(at:)，否则 MLModel(contentsOf:) 会报 "
                 "'Compile the model with Xcode'")
    return mlpackage, None, notes


# ============================================================================
# 5. 主流程
# ============================================================================

def main() -> int:
    ap = argparse.ArgumentParser(
        description="M2 (model_v2) 端到端驾驶模型 → CoreML 导出（多输入）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="契约：image[1,3,180,320] + lane[1,1,160,160] + dets[1,20,12] "
               "+ det_mask[1,20] + vehicle_state[1,8] → steer/throttle/brake [1,1]",
    )
    ap.add_argument("--src", default=str(_ROOT / "checkpoints" / "m9_v2" / "best_model.pt"),
                    help="PyTorch 存档（含 model_state_dict）；默认 train_v2.py 的产出路径")
    ap.add_argument("--out", default=str(_ROOT / "models" / "m9_v2.mlmodelc"),
                    help="输出路径（同时产出同名 .mlpackage）")
    ap.add_argument("--precision", choices=["float16", "float32", "int8"], default="float16",
                    help="float16(默认,图内fp16,IO恒fp32) / float32 / int8(权重8位,兜底档,精度差6.7×)")
    ap.add_argument("--target", choices=["macOS13", "macOS14", "macOS15"], default="macOS13",
                    help="最低部署目标（macOS13 起支持 mlprogram/ANE）")
    ap.add_argument("--num-dets", type=int, default=None,
                    help="覆盖检测框固定槽位 N（默认取模型契约值 20；CoreML 不支持动态 N）")
    ap.add_argument("--self-test", "--allow-random-init", dest="self_test", action="store_true",
                    help="src 不存在时用随机初始化权重跑通转换链路（产物不可上车）")
    ap.add_argument("--emit-contract", action="store_true",
                    help="额外输出 m9_v2_contract.json（机器可读契约，供 Swift 侧核对）")
    ap.add_argument("--tol", type=float, default=None,
                    help="精度校验阈值（默认 fp16/32: 5e-3，int8: 2e-2）")
    args = ap.parse_args()

    src = Path(args.src)
    out = Path(args.out)
    target = {"macOS13": ct.target.macOS13,
              "macOS14": ct.target.macOS14,
              "macOS15": ct.target.macOS15}[args.target]

    print("=" * 78)
    print(" M2 (model_v2) → CoreML 导出")
    print("=" * 78)
    print(f"[导出] torch {torch.__version__} / coremltools {ct.__version__} / "
          f"numpy {np.__version__} / py {sys.version.split()[0]}")

    # ---- 1. 权重 ----
    sd = None
    if src.exists():
        print(f"[导出] 读取权重：{src}")
        sd = _load_state_dict(src)
    elif args.self_test:
        print(f"[导出] ⚠ 权重不存在（{src}），--self-test 生效 → 随机初始化")
    else:
        print(f"[导出] ✗ 权重不存在：{src}", file=sys.stderr)
        print("[导出]   M2 的训练产出路径是 checkpoints/m9_v2/best_model.pt"
              "（src/train_v2.py 的 DEFAULT_CKPT_DIR）。", file=sys.stderr)
        print("[导出]   若训练尚未跑完，可加 --self-test 先验证转换链路。", file=sys.stderr)
        return 2

    model, load_report = _build_and_load(sd, src if src.exists() else None)
    if not load_report.get("random_init"):
        print(f"[导出] load_state_dict: missing={load_report['missing']} "
              f"unexpected={load_report['unexpected']}")
        if load_report["missing"] or load_report["unexpected"]:
            print(f"[导出]   missing 样例: {load_report.get('missing_keys')}")
            print(f"[导出]   unexpected 样例: {load_report.get('unexpected_keys')}")
            print("[导出]   ⚠ 存在未命中键 —— 请确认 checkpoint 与 model_v2 版本一致"
                  "（权重态误判会导致导出随机权重模型）")
    total_params = sum(p.numel() for p in model.parameters())
    print(f"[导出] 参数量 = {total_params:,}（{total_params * 2 / 1048576:.2f} MB @fp16）")

    # ---- 2. 契约 ----
    c = _contract_from_model(model)
    if args.num_dets is not None:
        if args.num_dets < 1:
            print("[导出] ✗ --num-dets 必须 ≥ 1（N=0 会把错误分支固化进计算图，见脚本头 坑 8）",
                  file=sys.stderr)
            return 2
        if args.num_dets != c["num_dets"]:
            print(f"[导出] ⚠ 覆盖 N：{c['num_dets']} → {args.num_dets}"
                  "（必须与 Swift 侧喂入的槽位数一致，否则报 shape 错）")
        c["num_dets"] = args.num_dets

    print("[导出] 契约（输入顺序即 convert/trace 顺序）：")
    for n, s in zip(INPUT_NAMES, _shapes(c)):
        print(f"         {n:<14} {list(s)}")
    print(f"         输出 {' / '.join(OUTPUT_NAMES)}  均为 [1, 1] fp32")

    # ---- 3. 参考推理 + trace ----
    base_inputs = _make_inputs(c)
    ref = _torch_forward(model, base_inputs)
    print(f"[导出] PyTorch 参考输出（{len(ref)} 个标量）= {[round(v, 6) for v in ref]}")

    # ★ 用 _ExportWrapper 包装：M2Model(return_aux=True) 返回 dict，
    #   trace 无法输出 dict → 必须摊平成 6 张量（t1 抓出的部署链路缺失）。
    export_model = _ExportWrapper(model)
    export_model.eval()

    try:
        with torch.no_grad():
            traced = torch.jit.trace(export_model, tuple(base_inputs), strict=False)
    except Exception as exc:
        print(f"[导出] ✗ jit.trace 失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 3
    print("[导出] ✓ jit.trace 成功")

    # ---- 3b. ★ GRU 算子在图里吗？（t1 就是靠这个发现的假绿）----
    #  时序分支吃模型内部算出的特征（方案 A），trace 不应剪掉它；
    #  但"图里有 GRU"必须**算子级验证**，不能靠代码字符串匹配 ——
    #  coremltools 会把 aten::gru 拆成 while_loop + slice_by_index。
    try:
        from collections import Counter as _Counter
        kinds = _Counter(str(n.kind()) for n in traced.inlined_graph.nodes())
        has_gru_torch = any("gru" in k.lower() for k in kinds)
        if not has_gru_torch:
            print("[导出] ✗ 假绿防线触发：trace 图里没有 GRU 算子（时序分支被剪掉）！\n"
                  "  检查 model_v2 的时序分支是否依赖外部输入（None → 被 trace 剪枝）。",
                  file=sys.stderr)
            return 8
        print(f"[导出] ✓ trace 图含 aten::gru（时序分支在图内，算子数 {sum(kinds.values())}）")
    except Exception as exc:
        print(f"[导出] ⚠ GRU 算子检查失败（不阻断）：{type(exc).__name__}: {exc}", file=sys.stderr)

    # ---- 4. 转换 ----
    t0 = time.time()
    try:
        mlmodel, notes = convert(traced, c, args.precision, target)
    except Exception as exc:
        print(f"[导出] ✗ CoreML 转换失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        print("[导出]   常见原因见脚本头 §2「CoreML 转换的坑」。", file=sys.stderr)
        return 4
    for n in notes:
        print(f"[导出]   · {n}")
    print(f"[导出] ✓ CoreML 转换完成（{time.time() - t0:.1f}s，"
          f"precision={args.precision}, target={args.target}）")

    # ---- 5. 契约断言（坑 1 防线）----
    try:
        _assert_input_contract(mlmodel, _shapes(c))
    except RuntimeError as exc:
        print(f"[导出] ✗ 契约校验失败：\n{exc}", file=sys.stderr)
        return 5
    print("[导出] ✓ 输入名/顺序/shape 与输出名全部符合契约")

    # ---- 6. 落盘 + 编译 ----
    mlpackage, mlmodelc, save_notes = save_and_compile(mlmodel, out)
    for n in save_notes:
        print(f"[导出]   · {n}")

    # ---- 7. 精度校验（与 PyTorch 逐用例对拍）----
    tol = args.tol if args.tol is not None else (2e-2 if args.precision == "int8" else 5e-3)
    print(f"[导出] 精度校验（阈值 {tol:g}，{args.precision}）：")

    # ★ 坑 7：Python 侧 `ct.models.MLModel` 要求 Manifest.json，而 coremlc 产物没有
    #   （真机 CoreML 能加载，Python 不能）。故 Python 精度校验**一律走 .mlpackage**，
    #   它验证的是「转换正确性」，与编译产物同源同图，等价性成立。
    verify_path = mlpackage
    print(f"[导出]   校验对象：{verify_path.name}（Python 侧用 .mlpackage，见脚本头 坑 7）")
    if mlmodelc is not None:
        print(f"[导出]   部署产物：{mlmodelc.name}（已用 xcrun coremlc 编译；"
              f"真机 MLModel(contentsOf:) 可加载）")
    try:
        loaded = ct.models.MLModel(str(verify_path))
    except Exception as exc:
        print(f"[导出] ✗ 加载校验模型失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 6

    cases = _edge_cases(c, base_inputs)
    worst = 0.0
    worst_case = ""
    failed: List[str] = []
    for name, inputs in cases.items():
        try:
            rv = _torch_forward(export_model, inputs)   # ← 用 wrapper（6 输出，与 CoreML 同形态）
            cv = _coreml_forward(loaded, inputs)
        except Exception as exc:
            print(f"[导出]   ✗ {name:<11} 推理失败：{type(exc).__name__}: {str(exc)[:110]}")
            failed.append(name)
            continue
        diff = max(abs(a - b) for a, b in zip(rv, cv))
        if diff > worst:
            worst, worst_case = diff, name
        flag = "✓" if diff < tol else "⚠ 超阈值"
        print(f"[导出]   {flag} {name:<11} pt={[round(v, 5) for v in rv]} "
              f"cm={[round(v, 5) for v in cv]} maxdiff={diff:.2e}")

    if failed:
        print(f"[导出] ✗ {len(failed)} 个用例推理失败：{failed}", file=sys.stderr)
        return 7

    ok = worst < tol
    print(f"[导出] 最大差异 = {worst:.2e}（用例 '{worst_case}'）"
          f"{'✓ 可接受' if ok else '⚠ 超阈值 —— 请评估量化失真'}")
    if args.precision == "int8":
        print("[导出]   ⚠ int8 为兜底档：控制输出是连续回归量，量化误差可能引入转向抖动。"
              "项目内 yolopx 已实测 int8 把细目标打掉 10×。上线前请用真实帧序列做时序抖动评估。")

    # ---- 8. 可选：契约 JSON ----
    if args.emit_contract:
        contract = {
            "model": "M2 / m9_v2",
            "source": "src/model_v2.py",
            "checkpoint": str(src) if src.exists() else None,
            "precision": args.precision,
            "target": args.target,
            "random_init": bool(load_report.get("random_init")),
            "compute_units_policy": ".all（运行时由 Swift 侧设置，项目已实测最快，勿改）",
            "inputs": [
                {"name": n, "shape": list(s), "dtype": "float32"}
                for n, s in zip(INPUT_NAMES, _shapes(c))
            ],
            "outputs": [{"name": n, "shape": [1, 1], "dtype": "float32"} for n in OUTPUT_NAMES],
            "det_feature_layout": ["x", "y", "w", "h",
                                   "label_car", "label_pedestrian", "label_sign", "label_obstacle",
                                   "confidence", "speed", "heading", "age"],
            "state_layout": ["speed", "accel", "heading", "heading_rate",
                             "curvature", "lateral_offset", "steer_angle", "reserved"],
            "notes": [
                "不含可行驶区域（drivableMask/daGrid）—— 契约红线",
                "N 固定 20 + det_mask valid 位（CoreML 不支持动态 N，见脚本头 坑 2）",
                "IO dtype 恒 fp32，fp16 只在图内（坑 3）",
                "输入名不可用 'state'，会被 coremltools 静默改名（坑 1）",
            ],
        }
        cpath = out.parent / "m9_v2_contract.json"
        cpath.write_text(json.dumps(contract, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[导出] ✓ 契约 JSON：{cpath}")

    # ---- 9. 总结 ----
    print("=" * 78)
    print(f"[导出] 完成 → {mlmodelc if mlmodelc else mlpackage}"
          f"  (precision={args.precision}, 最大差异={worst:.2e})")
    print(f"[导出] Swift 侧加载：config.computeUnits = .all（勿改，见脚本头 §3）")
    print("=" * 78)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
