#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「云端 NPU 训练出的 V3 checkpoint」导出为 CoreML fp16 / INT4，供 InferenceEngineV3 接入。

为什么单独成脚本、不改 `model_v3.export_coreml()`：
  该函数有三个硬伤会让我们这份 checkpoint 静默失败或走空：
    ① 只认 `ckpt["model_state_dict"]`，而 `src/train_v3.py` 的存档键是 `ckpt["model"]`
       → 用它会把整个 state_dict 当成 data 参与 `isinstance(... ,"model_state_dict" in ckpt)`
       判定失败后 `sd = ckpt`，键变成 {"model","epoch",...} 全对不上 → 实际一行权重都没加载；
    ② 云端 NPU 保存的张量在 pickle 里引用了 `torch_npu.utils.storage._rebuild_npu_tensor`
       与 `torch_npu.npu._format.Format`，本机没装 torch_npu 时 `torch.load` 直接
       `ModuleNotFoundError`；
    ③ 只导 fp16，没有 4-bit 量化步骤。
  本脚本只做这三件额外的事，导出主体（build→load→reparameterize→_ExportWrapper→trace→
  ct.convert）完全复用 `src/model_v3.py` 已验证的形态，不改模型定义。

量化口径（4-bit palettize，与项目既有 v3_int4 同规格）：
  `palettize_weights(OpPalettizerConfig(mode="kmeans", nbits=4, granularity="per_tensor"))`
  这是**纯权重 k-means**，coremltools 9.0 不接受校准数据；因此「INT4 校准」在本脚本里
  落为「用真实帧做逐层敏感度 + 真实验证集漂移评估」，据此决定是否保某些层为 fp16。

用法：
  /usr/local/bin/python3.11 tools/v3_exp/export_v3_checkpoint_int4.py --stage load
  ... --stage fp16   # 导出 fp16 基线
  ... --stage int4   # 在 fp16 基础上做 4-bit
  ... --stage all    # load+fp16+int4
退出码：0 成功；3 CoreML 转换失败（打印真实错误）。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Dict, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

OUT_DIR = Path("/tmp/v3_ckpt")
DEFAULT_CKPT = _REPO_ROOT / "models" / "aurora_v3_best_ep13_20261115.pt"
DEFAULT_MODELC = _REPO_ROOT / "models" / "v3_int4.mlmodelc"

# 输出名只有一处真源：直接复用模型定义里的 EXPORT_OUTPUT_NAMES，
# 避免「脚本里再抄一份」将来与模型定义漂移（评审 P2-9）。
from src.model_v3 import EXPORT_OUTPUT_NAMES as OUTPUT_NAMES  # noqa: E402

# 安全相关输出（动作/横纵向）：这些直接决定按键，必须零翻转才算严格通过。
SAFE_OUTPUTS = ("vertical", "horizontal", "handbrake", "brake", "super_brake", "ultimate")
# 连续监测输出（sigmoid 概率，参与健康度融合，不直接按按键）：用概率误差衡量。
PROB_OUTPUTS = ("confidence", "risk")

# 验收阈值（集中一处，报告里显式写出，避免「阈值散落在 print 里」）。
# 阈值依据实测（val_clips 128 样本）设定，不是拍脑袋：
#   - 动作 6 路转换一致率实测 100%，量化后最低 99.2%（vertical，1 例边界翻转）；
#   - super_brake 是 handbrake×brake 派生乘积，裸 logit 转换漂移可达 0.46（但动作 100% 一致），
#     故裸 logit 漂移只作「粗坏」诊断（>GROSS_LOGIT_DRIFT 才判失败），不作主判据；
#   - confidence 喂健康度融合，实测转换 0.0001、量化 0.011，故卡 ≤0.02；
#   - risk 当前无驾驶消费点（评审 P1-4 亦指出），量化概率误差实测 0.056，只告警不硬失败。
MIN_SAFE_AGREEMENT = 0.99       # 安全动作项决策一致率下限（量化后）
MAX_CONVERT_PROB_ERR = 0.02     # confidence 转换（fp16 vs torch）概率误差上限
MAX_QUANT_CONF_ERR = 0.02       # confidence 量化（int4 vs fp16）概率误差上限
GROSS_LOGIT_DRIFT = 3.0         # 裸 logit 转换漂移「粗坏」阈值（仅抓严重损坏）
RISK_WARN_ERR = 0.10            # risk 概率误差告警线（非硬门禁）
MIN_CALIB_SAMPLES = 30          # 低于此样本数不得宣称「可用」


# ============================================================================
# A1. torch_npu 反序列化 shim —— 必须在 import torch.load 使用前安装
# ============================================================================
def install_torch_npu_stub() -> None:
    """让「NPU 上保存的 checkpoint」能在没有 torch_npu 的本机被 torch.load。

    云端张量 pickle 引用了两个符号：
        torch_npu.utils.storage._rebuild_npu_tensor(...)  —— 重建 NPUTensor
        torch_npu.npu._format.Format                        —— 私有 format 参数
    我们只在本机做 CPU 反序列化：把 `_rebuild_npu_tensor` 委派给 torch 原生的
    `_rebuild_tensor_v2`（丢弃第 7 个 npu_format 参数与设备信息，强制 CPU 张量），
    `Format` 用空壳占位（它只是被 pickle 传递，不参与数值）。

    ⚠️ 适用范围（评审 P2-8）：本 shim 只在**本仓库这个 checkpoint**（412 张量、7 参
      签名、Format(2)/(0) 两种）上验证通过；不能据此宣称适用于任意 NPU 存档。
      对未验证的私有布局，shape/dtype 可能被错误还原。更稳的做法是在匹配版本的
      torch_npu 环境里加载原 checkpoint，再导出普通 CPU contiguous state_dict。
      本 shim 之后在 load_trained_model 里做了一次「全张量 CPU + 有限」体检兜底。
    """
    import types
    import torch

    def _make_pkg(name: str):
        mod = types.ModuleType(name)
        mod.__path__ = []  # 声明为 package，允许注册子模块
        sys.modules[name] = mod
        return mod

    if "torch_npu" not in sys.modules:
        root = _make_pkg("torch_npu")
        npu = _make_pkg("torch_npu.npu")
        utils = _make_pkg("torch_npu.utils")
        storage_mod = _make_pkg("torch_npu.utils.storage")
        fmt_mod = _make_pkg("torch_npu.npu._format")
        setattr(root, "npu", npu)
        setattr(root, "utils", utils)
        setattr(npu, "_format", fmt_mod)
        setattr(utils, "storage", storage_mod)

        class Format:  # noqa: D401 —— 仅作 pickle 占位，保留构造参数便于诊断
            def __init__(self, *a, **k):
                self.args = a
                self.kwargs = k

            def __repr__(self) -> str:
                return f"Format{self.args}"

        fmt_mod.Format = Format

        def _rebuild_npu_tensor(*args, **kwargs):
            # NPU 版签名 = 标准 6 参 + (npu_format=Format, device=...)。
            # 只取前 6 个标准参数委派给 torch 原生重建；npu_format/device 丢弃 → CPU。
            return torch._utils._rebuild_tensor_v2(*args[:6])

        storage_mod._rebuild_npu_tensor = _rebuild_npu_tensor


# ============================================================================
# A2. 严格加载 checkpoint → 部署态模型
# ============================================================================
def load_trained_model(ckpt_path: Path, verbose: bool = True):
    """加载训练存档并严格校验权重与架构匹配，返回已 reparameterize 的 eval 模型。

    严格性红线：`strict=True`。本项目历史上因 `strict=False` 静默丢弃权重吃过亏
    （train_v3.py:1013 注释）。任何 missing/unexpected 都必须当场炸掉。
    """
    import torch
    from src.model_v3 import build_v3_model, V3Config

    install_torch_npu_stub()
    ckpt = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
    if isinstance(ckpt, dict) and "model" in ckpt:
        sd = ckpt["model"]
    elif isinstance(ckpt, dict) and "model_state_dict" in ckpt:
        sd = ckpt["model_state_dict"]
    else:
        sd = ckpt
    # 去掉 torch.compile 的 _orig_mod. 前缀。
    # 去前缀后若出现同名键冲突（两把键归一化到同一名字），说明 state_dict 本身有病，
    # 直接报错而不是让后写的覆盖先写的（评审 P2-9）。
    stripped: Dict[str, "object"] = {}
    conflicts = []
    for k, v in sd.items():
        nk = k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k
        if nk in stripped:
            conflicts.append(nk)
        stripped[nk] = v
    if conflicts:
        raise RuntimeError(f"去掉 _orig_mod. 前缀后出现重名键（疑似存档损坏）：{conflicts[:5]}")
    sd = stripped

    cfg = V3Config()
    model = build_v3_model(deploy=False, cfg=cfg)
    # 直接 strict=True：任何 missing/unexpected 都会抛异常，杜绝静默漏载（评审 P2-9）。
    missing, unexpected = model.load_state_dict(sd, strict=True)
    # strict=True 通过时 missing/unexpected 必为空；仍显式断言，防上游语义改变。
    if missing or unexpected:  # pragma: no cover - 仅防御
        raise RuntimeError(f"strict 加载异常：missing={missing[:5]} unexpected={unexpected[:5]}")
    model.reparameterize()
    model.eval()
    # 反序列化体检（评审 P2-8 兜底）：NPU shim 若把某个张量错误还原（dtype/shape/布局/全零），
    # 这里会以「非有限值」暴露。覆盖 parameters + buffers（评审 P2-A：旧实现只查 parameters）。
    bad = []
    zero_injected = []
    for name, p in list(model.named_parameters()) + list(model.named_buffers()):
        t = p.detach()
        if t.is_floating_point():
            if not torch.isfinite(t).all():
                bad.append(name)
            elif t.numel() > 1 and torch.all(t == 0):
                zero_injected.append(name)
    if bad:
        raise RuntimeError(f"加载后张量含非有限值（疑似 NPU 反序列化损坏）：{bad[:5]}")
    # 全零张量只在「大量都全零」时告警（个别 BN/偏置全零可正常）——不阻断，但提示。
    if len(zero_injected) > 8:
        print(f"[A2] ⚠ 有 {len(zero_injected)} 个张量全零（疑似未加载/注入）：{zero_injected[:5]}…")
    if verbose:
        cnt = model.get_param_count()
        meta = {k: ckpt[k] for k in ("epoch", "select_metric", "best_select", "val_loss")
                if isinstance(ckpt, dict) and k in ckpt}
        print(f"[A2] 严格加载成功：{len(sd)} 张量；训练态参数={cnt['total']:,}，"
              f"部署态={cnt['deploy_total']:,}")
        if meta:
            print(f"[A2] checkpoint 元信息：{meta}")
    return model, cfg


# ============================================================================
# 输入构造（与 V3Model.forward 契约顺序一致）
# ============================================================================
def zeros_inputs(cfg, batch: int = 1) -> Tuple:
    import torch
    return (
        torch.zeros(batch, cfg.num_hi_frames, 3, cfg.image_hi_h, cfg.image_hi_w),
        torch.zeros(batch, cfg.num_lo_frames, 3, cfg.image_lo_h, cfg.image_lo_w),
        torch.zeros(batch, 1, cfg.lane_size, cfg.lane_size),
        torch.zeros(batch, cfg.max_detections, cfg.det_feat_dim),
        torch.zeros(batch, cfg.max_detections),
        torch.zeros(batch, cfg.state_dim),
    )


def _input_shapes(cfg):
    from coremltools import TensorType
    return [
        TensorType(name="image_hi", shape=(1, cfg.num_hi_frames, 3, cfg.image_hi_h, cfg.image_hi_w)),
        TensorType(name="image_lo", shape=(1, cfg.num_lo_frames, 3, cfg.image_lo_h, cfg.image_lo_w)),
        TensorType(name="lane", shape=(1, 1, cfg.lane_size, cfg.lane_size)),
        TensorType(name="dets", shape=(1, cfg.max_detections, cfg.det_feat_dim)),
        TensorType(name="det_mask", shape=(1, cfg.max_detections)),
        TensorType(name="vehicle_state", shape=(1, cfg.state_dim)),
    ]


# ============================================================================
# A3. 导出 fp16 基线
# ============================================================================
def export_fp16(model, cfg, out_path: Path, ios: int = 17) -> Path:
    import torch
    import coremltools as ct
    from src.model_v3 import _ExportWrapper, EXPORT_OUTPUT_NAMES

    if out_path.exists():
        import shutil
        shutil.rmtree(out_path)

    wrapper = _ExportWrapper(model).eval()
    dummy = zeros_inputs(cfg, batch=1)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, dummy, strict=False)

    t0 = time.perf_counter()
    deploy_target = ct.target.iOS18 if ios >= 18 else ct.target.iOS17
    mlmodel = ct.convert(
        traced,
        inputs=_input_shapes(cfg),
        outputs=[ct.TensorType(name=n) for n in EXPORT_OUTPUT_NAMES],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=deploy_target,
        convert_to="mlprogram",
    )
    mlmodel.save(str(out_path))
    dt = time.perf_counter() - t0
    size_mb = dir_size_mb(out_path)
    print(f"[A3] fp16 导出成功（iOS{ios}）：{out_path.name}  {size_mb:.2f} MB（{dt:.1f}s）")
    return out_path


# ============================================================================
# A4. 4-bit palettize
# ============================================================================
def quantize_int4(fp16_path: Path, out_path: Path,
                  protected_op_names=None, granularity: str = "per_tensor",
                  group_size: int = 32) -> Path:
    """对 fp16 mlpackage 做 4-bit kmeans palettize。

    granularity: per_tensor（最粗、最省）/ per_channel（细、精度好）/
                 per_grouped_channel（折中，配合 group_size）
    protected_op_names: 要高精度保留（跳过压缩，mode 保持）的权重算子名列表；
    传 None 表示全量化。coremltools 用 `op_name_configs={name: None}` 表示跳过压缩。
    """
    from coremltools.optimize.coreml import (
        OpPalettizerConfig, OptimizationConfig, palettize_weights)
    import coremltools as ct

    if out_path.exists():
        import shutil
        shutil.rmtree(out_path)

    fp16_model = ct.models.MLModel(str(fp16_path))
    kwargs = dict(mode="kmeans", nbits=4, granularity=granularity)
    if granularity == "per_grouped_channel":
        kwargs["group_size"] = group_size
    op_config = OpPalettizerConfig(**kwargs)
    op_name_configs = None
    if protected_op_names:
        op_name_configs = {n: None for n in protected_op_names}
    config = OptimizationConfig(global_config=op_config, op_name_configs=op_name_configs)
    t0 = time.perf_counter()
    quantized = palettize_weights(fp16_model, config)
    quantized.save(str(out_path))
    dt = time.perf_counter() - t0
    size_mb = dir_size_mb(out_path)
    fp16_mb = dir_size_mb(fp16_path)
    print(f"[A4] INT4 量化成功（{granularity}）：{out_path.name}  {size_mb:.2f} MB "
          f"（{fp16_mb / max(size_mb, 1e-9):.2f}× 压缩，{dt:.1f}s，保护层={len(protected_op_names or [])}）")
    return out_path


def _drift_of(int4_path: Path, fp16_out, np_inputs) -> Tuple[Dict[str, float], float]:
    """给定 int4 mlpackage，返回逐输出 quant_drift 与 worst。"""
    import coremltools as ct
    int4_model = ct.models.MLModel(str(int4_path))
    int4_out = _predict_mlmodel(int4_model, np_inputs)
    per = {}
    worst = 0.0
    for name in OUTPUT_NAMES:
        d = float(abs(int4_out[name].reshape(-1) - fp16_out[name].reshape(-1)).max())
        per[name] = d
        worst = max(worst, d)
    return per, worst


def sweep_granularity(fp16_path: Path, ckpt_path: Path, n_samples: int = 16) -> Dict[str, object]:
    """扫描不同量化粒度，用真实帧选「体积最小且漂移达标」的方案。

    项目判据：worst quant_drift < 1e-3 = 无损。依次试 per_tensor → per_channel，
    取第一个达标者；都不达标则返回最小 worst 的粒度，交由 B2 保护层兜底。
    """
    import coremltools as ct
    np_inputs, torch_inputs, meta = build_calib_inputs(n_samples)
    if np_inputs is None:
        return {"skipped": "no-data"}
    fp16_model = ct.models.MLModel(str(fp16_path))
    fp16_out = _predict_mlmodel(fp16_model, np_inputs)

    candidates = ["per_tensor", "per_grouped_channel"]
    results = {}
    tmp = OUT_DIR / "_sweep.mlpackage"
    best = None
    for gran in candidates:
        # per_grouped_channel 用 group_size=1（等价 per-channel，最细、100% 覆盖）
        gs = 1 if gran == "per_grouped_channel" else 32
        quantize_int4(fp16_path, tmp, granularity=gran, group_size=gs)
        per, worst = _drift_of(tmp, fp16_out, np_inputs)
        size_mb = dir_size_mb(tmp)
        results[gran] = {"worst_drift": worst, "size_mb": size_mb, "per_output": per,
                         "group_size": gs}
        print(f"[sweep] {gran:<18}(gs={gs}) size={size_mb:.2f}MB worst_drift={worst:.3e} "
              f"{'✅无损' if worst < 1e-3 else '有损'}")
        if best is None or (worst < 1e-3 and size_mb < best[2]):
            best = (gran, worst, size_mb)
    # 若都不达标，选 worst 最小者
    if best is None or best[1] >= 1e-3:
        best = min(((g, r["worst_drift"], r["size_mb"]) for g, r in results.items()),
                   key=lambda x: x[1])
    results["chosen"] = best[0]
    results["chosen_lossless"] = best[1] < 1e-3
    print(f"[sweep] 选定粒度 = {best[0]}（worst_drift={best[1]:.3e}）")
    return results


def dir_size_mb(path: Path) -> float:
    if path.is_file():
        return path.stat().st_size / (1024 * 1024)
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) / (1024 * 1024)


def sha256_of(path: Path, chunk: int = 1 << 20) -> str:
    """对文件或目录做稳定哈希：目录按「相对路径+大小+内容」排序累加，绑定产物来源。"""
    import hashlib
    h = hashlib.sha256()
    p = Path(path)
    if p.is_file():
        with p.open("rb") as f:
            for block in iter(lambda: f.read(chunk), b""):
                h.update(block)
        return h.hexdigest()
    for f in sorted(x for x in p.rglob("*") if x.is_file()):
        h.update(str(f.relative_to(p)).encode("utf-8"))
        h.update(b"\0")
        with f.open("rb") as fh:
            for block in iter(lambda: fh.read(chunk), b""):
                h.update(block)
    return h.hexdigest()


def sigmoid_np(x):
    import numpy as np
    return 1.0 / (1.0 + np.exp(-np.asarray(x, dtype=np.float64)))


def wilson_ci(k: int, n: int, z: float = 1.96):
    """二项比例的 Wilson 置信区间（小样本比正态近似稳），用于报告一致率不确定性。"""
    if n == 0:
        return (0.0, 0.0)
    import math
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    return (max(0.0, center - half), min(1.0, center + half))


def _expected_channels(name: str) -> int:
    """每个输出的特征维契约：vertical/horizontal 是 3 类 logits，其余是 1。"""
    return 3 if name in ("vertical", "horizontal") else 1


def assert_outputs_valid(outputs: Dict[str, "object"], expected_n: int, label: str) -> None:
    """硬门禁：输出集合齐全、**形状契约**、样本数一致、全部有限。任何违规立即抛错。

    这是评审 P0-1 的核心修复——旧实现在输出为 NaN 时 argmax/差值会得到
    「NaN==NaN 一致率 100% / max(0,NaN)=0」的假通过。这里在做任何比较**之前**就拦掉。

    形状契约（评审 P0-A 补强）：vertical/horizontal 必须 [N,3]，其余必须 [N,1]。
    旧实现只校验第一维(样本数)就 reshape，导致给 vertical 传 (N,4) 也被放过——属假通过。
    这里**不做 reshape 抹平**，直接按 (N, 期望通道数) 严格比对。
    """
    import numpy as np
    if not isinstance(outputs, dict):
        raise AssertionError(f"[{label}] 输出不是 dict：{type(outputs)}")
    missing = [k for k in OUTPUT_NAMES if k not in outputs]
    if missing:
        raise AssertionError(f"[{label}] 缺少输出键：{missing}")
    n_ref = None
    for name in OUTPUT_NAMES:
        arr = np.asarray(outputs[name], dtype=np.float64)
        want_c = _expected_channels(name)
        # 允许 (N,) 视作 (N,1)（连续量的常见形态），但绝不接受通道数不符。
        if arr.ndim == 1:
            arr2 = arr.reshape(-1, 1)
        else:
            arr2 = arr.reshape(arr.shape[0], -1)
        if arr2.shape[0] == 0:
            raise AssertionError(f"[{label}] 输出 {name} 为空")
        if arr2.shape[1] != want_c:
            raise AssertionError(
                f"[{label}] 输出 {name} 形状 {np.asarray(outputs[name]).shape} "
                f"通道数={arr2.shape[1]} != 契约 {want_c}")
        if n_ref is None:
            n_ref = arr2.shape[0]
        elif arr2.shape[0] != n_ref:
            raise AssertionError(f"[{label}] 输出 {name} 样本数 {arr2.shape[0]} 与其它 {n_ref} 不一致")
        if not np.all(np.isfinite(arr2)):
            bad = int(arr2.size - np.isfinite(arr2).sum())
            raise AssertionError(f"[{label}] 输出 {name} 含 {bad} 个非有限值（NaN/Inf），拒绝评估")
    if n_ref != expected_n:
        raise AssertionError(f"[{label}] 输出样本数 {n_ref} != 期望 {expected_n}")


def decode_decisions(outputs: Dict[str, "object"]) -> Dict[str, "object"]:
    """把 8 路 logits 解码成部署端真正消费的决策（argmax / sign>0 / sigmoid 概率）。

    动作（6 路）：三分类取 argmax，二分类取 logit>0（严格等价 sigmoid>0.5）。
    监测（confidence/risk）：取 sigmoid 概率（与 InferenceEngineV3.swift 的
    `Self.sigmoid(...)` 一致），用于比较连续值误差而非仅比符号（评审 P1-4）。
    """
    import numpy as np
    import coremltools as ct  # noqa: F401  (保持与其它函数一致的导入环境)

    def _argmax3(a):
        a = np.asarray(a)
        if a.ndim == 1:
            a = a.reshape(-1, 3)
        return np.argmax(a, axis=1)

    out: Dict[str, "object"] = {}
    out["vertical_cls"] = _argmax3(outputs["vertical"])
    out["horizontal_cls"] = _argmax3(outputs["horizontal"])
    for name in ("handbrake", "brake", "super_brake", "ultimate"):
        out[name + "_on"] = np.asarray(outputs[name]).reshape(-1) > 0
    out["confidence_p"] = sigmoid_np(np.asarray(outputs["confidence"]).reshape(-1))
    out["risk_p"] = sigmoid_np(np.asarray(outputs["risk"]).reshape(-1))
    return out


# ============================================================================
# B. 校准 / 漂移评估（真实帧）
# ============================================================================
MANIFEST_CANDIDATES = [Path("/Users/dupi/Desktop/aurora_pieces_manifest.json"),
                       _REPO_ROOT / "aurora_pieces_manifest.json"]


def _load_pieces_manifest() -> list:
    for p in MANIFEST_CANDIDATES:
        if p.exists():
            try:
                return json.loads(p.read_text(encoding="utf-8"))
            except Exception:
                return []
    return []


def _resolve_val_clips(ckpt_path):
    """把 checkpoint 的 val_clips 解析成精确分片列表 [(clip, start, end), ...]。

    评审 P1-A（关键）：`clip_xxx_p00000` 的后缀 `_pNNNNN` 是**清洗后帧序列的分片起点**
    （见 tools/pack_pieces.py），不是整段 clip。训练按**完整分片目录**划分划分，
    若把整段 clip 当验证集，会把该 clip 的其它分片（很可能进过训练）纳入验证 → 数据泄漏。
    故这里用打包清单精确恢复每个分片在清洗序列中的 [start,end]，验证集只取这些帧。

    返回 (pieces, ok)：pieces=[(clip_name, start, end)]；ok=True 表示精确解析成功。
    解析失败/manifest 缺失返回 ok=False，交由调用方决定是否失败（--val-clips 严格模式）。
    """
    try:
        import torch
        install_torch_npu_stub()
        ck = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
        raw = ck.get("val_clips") if isinstance(ck, dict) else None
        if not raw:
            return [], False
        import re
        parsed = []
        for p in raw:
            base = Path(p).name
            m = re.search(r"_p(\d+)$", base)
            start_from_name = int(m.group(1)) if m else 0
            clip_name = re.sub(r"_p\d+$", "", base)
            parsed.append((clip_name, start_from_name))
        manifest = _load_pieces_manifest()
        if not manifest:
            print("[B1] ⚠ 未找到打包清单，无法精确恢复分片范围")
            return [], False
        pieces = []
        for clip_name, start_from_name in parsed:
            matches = [m for m in manifest
                       if m.get("src_clip") == clip_name and int(m.get("start", -1)) == start_from_name]
            if len(matches) != 1:
                print(f"[B1] ⚠ 清单中无法唯一定位分片 {clip_name} start={start_from_name}（匹配 {len(matches)}）")
                return [], False
            mm = matches[0]
            pieces.append((clip_name, int(mm["start"]), int(mm["end"])))
        return pieces, True
    except Exception as exc:
        print(f"[B1] ⚠ 解析 val_clips 失败({type(exc).__name__}: {exc})")
        return [], False


def build_calib_inputs(n_samples: int, seed: int = 42,
                       use_val_clips: bool = False, ckpt_path=None):
    """从真实清洗数据取样本，组装成 6 路输入（含 batch 维）。

    默认：全量随机抽样（seed 固定，可复现）。
    use_val_clips=True 且 ckpt_path 提供：仅用 checkpoint 记录的 val_clips（训练独立留出），
      样本数可能少于 n_samples（该留出集本身大小）。这样选档与评估所用的数据与训练互斥，
      才是有意义的独立确认（评审 P1-5）。
    返回 (np_inputs, torch_inputs, meta)，meta 含索引、clip 名、每样本 (clip,frame)、
    数据 SHA 等可审计信息。无数据返回 (None, None, {})。
    """
    import numpy as np
    import torch
    from src.dataset_v3 import V3KeyDataset

    clips = _REPO_ROOT / "data" / "lean_clips"
    if not clips.exists():
        print(f"[B1] ⚠ 数据不可用：{clips} 不存在，跳过真实帧校准")
        return None, None, {}
    ds = V3KeyDataset(str(clips), skip_all_zero=True, augment=False, decode_workers=1)

    # 可选：仅取 val_clips 覆盖的样本（精确到帧范围，防跨分片泄漏）
    pool = list(range(len(ds)))
    used_val_clips = []
    if use_val_clips and ckpt_path is not None:
        pieces, ok = _resolve_val_clips(ckpt_path)
        if not ok or not pieces:
            # 严格模式：声称用独立留出却解析不出分片 → 直接失败，绝不退回随机蒙混（评审 P1-A）
            raise RuntimeError("--val-clips 要求精确分片，但无法从 checkpoint/manifest 恢复分片范围")
        kept = []
        for i, (clp, frame) in enumerate(ds.index):
            cname = Path(clp).name
            for (vc, s, e) in pieces:
                if cname == vc and s <= int(frame) <= e:
                    kept.append(i)
                    break
        if not kept:
            raise RuntimeError(f"--val-clips 分片 {pieces} 在数据集中无匹配样本")
        pool = kept
        used_val_clips = [f"{c}[{s}-{e}]" for (c, s, e) in pieces]
        print(f"[B1] 使用 checkpoint val_clips 精确分片：{used_val_clips}（候选样本 {len(pool)}）")

    rng = np.random.default_rng(seed)
    n = min(n_samples, len(pool))
    pick = sorted(rng.choice(len(pool), size=n, replace=False).tolist())
    idxs = [pool[i] for i in pick]
    keys = ["image_hi", "image_lo", "lane", "dets", "det_mask", "vehicle_state"]
    torch_inp = {k: [] for k in keys}
    per_sample = []
    for i in idxs:
        item = ds[int(i)]
        clip_path, frame_idx = ds.index[int(i)]
        per_sample.append({"clip": Path(clip_path).name, "frame": int(frame_idx)})
        for k in keys:
            torch_inp[k].append(item[k].unsqueeze(0))  # 加 batch 维
    torch_inp = {k: torch.cat(v, dim=0) for k, v in torch_inp.items()}
    np_inp = {k: v.numpy().astype(np.float16) for k, v in torch_inp.items()}

    # 数据指纹：对抽样输入的 float32 字节做 SHA256，绑定可复现的数据快照
    import hashlib
    dh = hashlib.sha256()
    for k in keys:
        dh.update(k.encode())
        dh.update(torch_inp[k].numpy().tobytes())
    # 防泄漏自检：val_clips 模式下，所有抽样帧必须落在声明的分片区间内
    if used_val_clips:
        pieces, _ = _resolve_val_clips(ckpt_path)
        for ps in per_sample:
            if not any(ps["clip"] == c and s <= ps["frame"] <= e for (c, s, e) in pieces):
                raise RuntimeError(f"val_clips 泄漏：样本 {ps} 不在声明的分片区间内")
    meta = {
        "n_samples": n,
        "dataset_size": len(ds),
        "seed": seed,
        "source": "val_clips" if used_val_clips else "all_random",
        "val_clips": used_val_clips,
        "per_sample": per_sample,
        "data_sha256": dh.hexdigest(),
    }
    print(f"[B1] 真实校准集：{n} 个样本（数据共 {len(ds)} 样本，来源={meta['source']}，"
          f"data_sha256={meta['data_sha256'][:12]}…）")
    return np_inp, torch_inp, meta


def _predict_mlmodel(mlmodel, np_inputs) -> Dict[str, "object"]:
    """逐样本推理（模型导出的固定 batch=1），再把各输出堆叠成 [N, ...]。"""
    import numpy as np
    keys = list(np_inputs.keys())
    n = np_inputs[keys[0]].shape[0]
    acc: Dict[str, list] = {k: [] for k in OUTPUT_NAMES}
    for i in range(n):
        feed = {k: np_inputs[k][i:i + 1] for k in keys}
        out = mlmodel.predict(feed)
        for name in OUTPUT_NAMES:
            acc[name].append(np.asarray(out[name], dtype=np.float32).reshape(-1))
    return {name: np.stack(v, axis=0) for name, v in acc.items()}


def evaluate_drift(fp16_path: Path, int4_path: Path, ckpt_path: Path,
                   n_samples: int = 128, k_torch_model=None,
                   use_val_clips: bool = False) -> Dict[str, object]:
    """在真实帧上评估 INT4 产物的可用性，返回 status ∈ {passed, failed, skipped}。

    双重门禁（评审 P1-4 修复）：
      ① 转换保真（PyTorch → fp16）：动作 6 路须 100% 一致、裸 logit 漂移仅作粗坏诊断、
         confidence 概率误差 ≤ MAX_CONVERT_PROB_ERR。若 fp16 基线本身就错，INT4 再"一致"也无意义。
      ② 量化影响（fp16 → INT4）：安全动作项决策一致率 ≥ MIN_SAFE_AGREEMENT；
         confidence sigmoid 概率误差 ≤ MAX_QUANT_CONF_ERR（连续量，不能只比符号）。
         risk 无驾驶消费点，仅告警（RISK_WARN_ERR）。

    硬门禁（评审 P0-1 修复）：做任何比较前，先用 assert_outputs_valid 校验三份输出
      齐全、形状/样本数一致、全部有限；NaN/Inf/缺键/形状不符立即抛错，绝不"100% 一致"假通过。

    数据来源（评审 P1-5）：use_val_clips=True 时使用 checkpoint 记录的 val_clips（独立留出）；
      否则退回全量随机。样本数 < MIN_CALIB_SAMPLES 时强制 status=failed。
    """
    import numpy as np
    import torch
    import coremltools as ct

    np_inputs, torch_inputs, meta = build_calib_inputs(
        n_samples, use_val_clips=use_val_clips, ckpt_path=ckpt_path)
    if np_inputs is None:
        return {"status": "skipped", "reason": "no-data"}

    n = meta["n_samples"]
    fp16_model = ct.models.MLModel(str(fp16_path))
    int4_model = ct.models.MLModel(str(int4_path))
    fp16_out = _predict_mlmodel(fp16_model, np_inputs)
    int4_out = _predict_mlmodel(int4_model, np_inputs)

    model = k_torch_model
    if model is None:
        model, _ = load_trained_model(Path(ckpt_path), verbose=False)
    with torch.no_grad():
        pt = model(**torch_inputs)
    torch_out = {k: pt[k].numpy().astype(np.float32) for k in OUTPUT_NAMES}

    # ── 硬门禁：先验证三份输出合法，再做任何比较 ──
    assert_outputs_valid(torch_out, n, "torch")
    assert_outputs_valid(fp16_out, n, "fp16")
    assert_outputs_valid(int4_out, n, "int4")

    dec_torch = decode_decisions(torch_out)
    dec_fp16 = decode_decisions(fp16_out)
    dec_int4 = decode_decisions(int4_out)

    result: Dict[str, object] = {
        "status": "failed", "n_samples": n, "per_output": {}, "flip_margins": {},
        "data": meta,
        "thresholds": {
            "min_safe_agreement": MIN_SAFE_AGREEMENT,
            "max_convert_prob_err": MAX_CONVERT_PROB_ERR,
            "max_quant_conf_err": MAX_QUANT_CONF_ERR,
            "gross_logit_drift": GROSS_LOGIT_DRIFT,
            "risk_warn_err": RISK_WARN_ERR,
            "min_calib_samples": MIN_CALIB_SAMPLES,
        },
        "reasons": [],
    }
    worst_logit = 0.0
    worst_conv = 0.0
    # 转换保真：逐输出比较 fp16 与 torch
    convert_action_flips = {}
    for name in OUTPUT_NAMES:
        b = fp16_out[name].reshape(-1)
        c = torch_out[name].reshape(-1)
        conv = float(abs(b - c).max())
        worst_conv = max(worst_conv, conv)
        # 动作一致（fp16 vs torch）
        if name in ("vertical", "horizontal"):
            same = (np.argmax(fp16_out[name], 1) == np.argmax(torch_out[name], 1)).mean()
        else:
            same = ((fp16_out[name].reshape(-1) > 0) == (torch_out[name].reshape(-1) > 0)).mean()
        convert_action_flips[name] = float(same)

    # 量化影响：逐输出比较 int4 与 fp16（部署真正消费的量）
    for name in OUTPUT_NAMES:
        a = int4_out[name].reshape(-1)
        b = fp16_out[name].reshape(-1)
        logit_drift = float(abs(a - b).max())
        worst_logit = max(worst_logit, logit_drift)
        if name in ("vertical", "horizontal"):
            df = np.argmax(fp16_out[name], 1)
            di = np.argmax(int4_out[name], 1)
            flip = np.where(df != di)[0]
            agree = float((df == di).mean())
        else:
            df = fp16_out[name].reshape(-1) > 0
            di = int4_out[name].reshape(-1) > 0
            flip = np.where(df != di)[0]
            agree = float((df == di).mean())
        # 翻转样本的 fp16 裕度（分类看 top1-top2 差，二分类看 |logit|）
        margins = []
        for i in flip:
            if name in ("vertical", "horizontal"):
                row = np.sort(fp16_out[name][i])[::-1]
                margins.append(float(row[0] - row[1]))
            else:
                margins.append(float(abs(fp16_out[name].reshape(-1)[i])))
        k = int(round(agree * n))
        ci_lo, ci_hi = wilson_ci(k, n)
        result["per_output"][name] = {
            "logit_drift_max": logit_drift,
            "convert_agreement": convert_action_flips[name],
            "decision_agreement": agree,
            "n_flip": int(len(flip)),
            "agreement_ci95": [round(ci_lo, 4), round(ci_hi, 4)],
        }
        result["flip_margins"][name] = margins

    # 连续监测输出：sigmoid 概率误差
    prob_err = {}
    for name in PROB_OUTPUTS:
        key = name + "_p"
        e = float(np.max(np.abs(dec_int4[key] - dec_fp16[key])))
        conv_e = float(np.max(np.abs(dec_fp16[key] - dec_torch[key])))
        prob_err[name] = {"int4_vs_fp16": e, "fp16_vs_torch": conv_e}
    result["prob_error"] = prob_err

    min_safe = min(result["per_output"][nm]["decision_agreement"] for nm in SAFE_OUTPUTS)
    min_convert = min(convert_action_flips[nm] for nm in SAFE_OUTPUTS)
    conf_quant = prob_err["confidence"]["int4_vs_fp16"]
    conf_conv = prob_err["confidence"]["fp16_vs_torch"]
    risk_quant = prob_err["risk"]["int4_vs_fp16"]

    result["min_safe_decision_agreement"] = min_safe
    result["min_safe_convert_agreement"] = min_convert
    result["worst_logit_drift"] = worst_logit
    result["worst_convert_drift"] = worst_conv
    result["confidence_quant_err"] = conf_quant
    result["confidence_convert_err"] = conf_conv
    result["risk_quant_err"] = risk_quant

    # ── 判定（阈值见文件头常量；均在 val_clips 上实测校准）──
    if n < MIN_CALIB_SAMPLES:
        result["reasons"].append(f"样本数 {n} < {MIN_CALIB_SAMPLES}，不足以下结论")
    # 转换保真：动作必须 100% 一致（fp16 基线不能先错）
    if min_convert < 1.0:
        result["reasons"].append(f"PyTorch→fp16 动作翻转（最低一致 {min_convert*100:.1f}%）")
    if worst_conv > GROSS_LOGIT_DRIFT:
        result["reasons"].append(f"PyTorch→fp16 裸 logit 严重漂移 {worst_conv:.3f} > {GROSS_LOGIT_DRIFT}")
    if conf_conv > MAX_CONVERT_PROB_ERR:
        result["reasons"].append(f"PyTorch→fp16 confidence 概率误差 {conf_conv:.3f} > {MAX_CONVERT_PROB_ERR}")
    # 量化影响：安全动作 ≥99% + confidence 概率误差
    if min_safe < MIN_SAFE_AGREEMENT:
        result["reasons"].append(f"安全项决策一致率 {min_safe*100:.2f}% < {MIN_SAFE_AGREEMENT*100:.0f}%")
    if conf_quant > MAX_QUANT_CONF_ERR:
        result["reasons"].append(f"INT4 confidence 概率误差 {conf_quant:.3f} > {MAX_QUANT_CONF_ERR}")
    warnings = []
    if risk_quant > RISK_WARN_ERR:
        warnings.append(f"risk 概率误差 {risk_quant:.3f} > {RISK_WARN_ERR}（无驾驶消费点，仅告警）")
    result["warnings"] = warnings

    result["status"] = "passed" if not result["reasons"] else "failed"

    mark = {"passed": "✅通过", "failed": "❌未通过", "skipped": "⏭跳过"}[result["status"]]
    print(f"[B3] INT4 可用性评估（{n} 样本，来源={meta['source']}）：{mark}")
    print(f"     转换保真: 动作最低一致={min_convert*100:.1f}%  confidence误差={conf_conv:.4f}  裸logit最大={worst_conv:.3f}(诊断)")
    print(f"     量化影响: 安全项最低一致={min_safe*100:.2f}%  confidence误差={conf_quant:.4f}  risk误差={risk_quant:.4f}(告警线{RISK_WARN_ERR})")
    for r in result["reasons"]:
        print(f"     ❌ {r}")
    for w in warnings:
        print(f"     ⚠ {w}")
    for name in OUTPUT_NAMES:
        po = result["per_output"][name]
        mg = [round(m, 3) for m in result["flip_margins"][name][:4]]
        flag = "← 裕度≥0.6(非纯边界)" if any(m >= 0.6 for m in result["flip_margins"][name]) else ""
        print(f"       {name:<12} 一致率={po['decision_agreement']*100:5.1f}% "
              f"CI95={po['agreement_ci95']} 翻转={po['n_flip']:>2} 裕度={mg} {flag}")
    return result


def sensitivity_analysis(fp16_path: Path, ckpt_path: Path,
                         n_samples: int = 64) -> Dict[str, object]:
    """分组敏感度：按模型语义分块，逐块"只量化该块、其余 fp16"，测安全项决策一致率劣化。

    比逐层（484 个算子）快得多，且直接回答「保护哪一块能保住决策」。分块依据算子名前缀。
    """
    import numpy as np
    import coremltools as ct
    import shutil
    from coremltools.optimize.coreml import (
        OpPalettizerConfig, OptimizationConfig, palettize_weights, get_weights_metadata)

    fp16_model = ct.models.MLModel(str(fp16_path))
    np_inputs, _, _ = build_calib_inputs(n_samples)
    if np_inputs is None:
        return {"skipped": "no-data"}
    base = _predict_mlmodel(fp16_model, np_inputs)
    meta = get_weights_metadata(fp16_model, weight_threshold=1)
    ops = sorted(meta.keys())

    def group_of(name: str) -> str:
        if "backbone" in name: return "backbone"
        if "temporal" in name: return "temporal"
        if "stage1" in name: return "stage1"
        if "stage2" in name: return "stage2"
        if "output_head" in name: return "output_head"
        if "lane" in name: return "lane"
        if "det" in name: return "det"
        if "intent" in name: return "intent"
        return "proj_state"

    groups: Dict[str, list] = {}
    for o in ops:
        groups.setdefault(group_of(o), []).append(o)

    def agreement(out):
        vals = []
        for n in ("vertical", "horizontal"):
            vals.append(float((np.argmax(out[n], 1) == np.argmax(base[n], 1)).mean()))
        for n in ("handbrake", "brake", "super_brake", "ultimate"):
            vals.append(float(((out[n].reshape(-1) > 0) == (base[n].reshape(-1) > 0)).mean()))
        return min(vals)

    tmp = OUT_DIR / "_sens.mlpackage"
    rows = []
    for gname, gops in groups.items():
        protect = [o for o in ops if o not in gops]  # 只量化本组，其余保护
        cfg = OptimizationConfig(
            global_config=OpPalettizerConfig(mode="kmeans", nbits=4, granularity="per_tensor"),
            op_name_configs={o: None for o in protect})
        try:
            q = palettize_weights(fp16_model, cfg)
            if tmp.exists():
                shutil.rmtree(tmp)
            q.save(str(tmp))
            out = _predict_mlmodel(ct.models.MLModel(str(tmp)), np_inputs)
            ag = agreement(out)
            rows.append({"group": gname, "n_ops": len(gops), "safe_agreement": ag})
            print(f"[B2] 只量化 {gname:<12}({len(gops):>3}算子) → 安全项一致率 {ag*100:.1f}%")
        except Exception as exc:
            rows.append({"group": gname, "n_ops": len(gops), "error": f"{type(exc).__name__}: {exc}"})
            print(f"[B2] {gname} 失败: {type(exc).__name__}: {str(exc)[:80]}")
    # 敏感度 = 一致率越低越敏感
    rows_ok = [r for r in rows if "safe_agreement" in r]
    rows_ok.sort(key=lambda r: r["safe_agreement"])
    return {"groups": rows, "most_sensitive": [r["group"] for r in rows_ok[:3]]}


# ============================================================================
# main
# ============================================================================
SCHEMES = {
    # scheme 名 → 要保护（跳过量化、保留 fp16）的算子名子串
    "full_int4": [],
    "protect_backbone": ["backbone"],
    "protect_backbone_proj": ["backbone", "proj", "state"],
}


def resolve_protected_ops(fp16_path: Path, scheme: str) -> list:
    """按 scheme 从 fp16 模型的权重元数据里挑出要保护的算子名。"""
    from coremltools.optimize.coreml import get_weights_metadata
    import coremltools as ct
    subs = SCHEMES[scheme]
    if not subs:
        return []
    meta = get_weights_metadata(ct.models.MLModel(str(fp16_path)), weight_threshold=1)
    ops = sorted(meta.keys())
    return [o for o in ops if any(s in o for s in subs)]


def _git_commit() -> str:
    import subprocess
    try:
        return subprocess.check_output(
            ["git", "-C", str(_REPO_ROOT), "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def _stamp_path(out_dir: Path) -> Path:
    return out_dir / ".fp16_stamp.json"


def _tool_versions() -> dict:
    """记录影响导出结果的关键工具版本（评审 P1-C：缓存应绑定工具版本）。"""
    import coremltools
    import numpy
    import torch
    return {"coremltools": coremltools.__version__, "numpy": numpy.__version__,
            "torch": torch.__version__}


def _stamp_identity(ckpt_sha: str, ios: int, scheme: str) -> dict:
    """缓存身份：checkpoint 哈希 + 目标 ios + 输出契约 + scheme + 导出源码哈希 + 工具版本。"""
    return {
        "ckpt_sha256": ckpt_sha,
        "ios": ios,
        "scheme": scheme,
        "outputs": list(OUTPUT_NAMES),
        "export_script_sha256": sha256_of(Path(__file__)),
        "tool_versions": _tool_versions(),
    }


def _check_or_write_fp16_stamp(out_dir: Path, ckpt_sha: str, ios: int,
                               fp16_path: Path, force: bool, scheme: str = "") -> bool:
    """校验 fp16 缓存身份；返回 True 表示可复用现有 fp16 产物。

    缓存必须**完整匹配**：checkpoint 哈希 + ios + 输出契约 + scheme + 导出源码哈希 + 工具版本，
    且 fp16_sha256 存在并严格等于当前产物内容。任一项不符即重导（评审 P1-2/P1-C）。
    """
    stamp = _stamp_path(out_dir)
    want = _stamp_identity(ckpt_sha, ios, scheme)
    if fp16_path.exists() and stamp.exists():
        try:
            old = json.loads(stamp.read_text(encoding="utf-8"))
        except Exception:
            old = {}
        mism = [k for k, v in want.items() if old.get(k) != v]
        cur = sha256_of(fp16_path)
        if not mism and not force and old.get("fp16_sha256") not in (None, "") \
                and old.get("fp16_sha256") == cur:
            print(f"[cache] 复用 fp16 缓存（身份匹配 ckpt={ckpt_sha[:12]}… ios={ios} scheme={scheme}，内容哈希一致）")
            return True
        if mism:
            print(f"[cache] fp16 缓存身份不匹配：{mism}，将重新导出")
        else:
            print("[cache] fp16 缓存内容哈希不符或缺失，将重新导出")
    return False


def _write_fp16_stamp(out_dir: Path, ckpt_sha: str, ios: int, fp16_path: Path,
                      scheme: str = "") -> None:
    stamp = _stamp_path(out_dir)
    data = _stamp_identity(ckpt_sha, ios, scheme)
    data["fp16_sha256"] = sha256_of(fp16_path)
    stamp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


REQUIRED_MODELC_FILES = ("coremldata.bin", "model.mil", "metadata.json", "weights/weight.bin")


def modelc_content_sha(modelc_dir: Path) -> str:
    """对 .mlmodelc 的**语义内容**求稳定指纹（weight.bin + model.mil + metadata.json）。

    为什么排除 coremldata.bin：实测同一 mlpackage 连续编译两次，weight.bin/model.mil/
    metadata.json 逐字节相同，唯独 coremldata.bin 不同（编译器在其中嵌 UUID/时间戳）。
    若用目录全量哈希做绑定，同一模型每次重编译都会得到不同「部署 sha」，反而让
    「哈希对不上」变成噪声。故用语义内容指纹代表模型身份，可稳定复现。

    缺必需文件时**抛错**（评审 P0-B：旧实现对不存在目录返回空内容 SHA 而非失败）。
    """
    import hashlib
    modelc_dir = Path(modelc_dir)
    if not modelc_dir.is_dir():
        raise RuntimeError(f"modelc 目录不存在：{modelc_dir}")
    missing = [n for n in ("weights/weight.bin", "model.mil", "metadata.json")
               if not (modelc_dir / n).is_file()]
    if missing:
        raise RuntimeError(f"modelc 缺少必需文件 {missing}，拒绝计算指纹")
    h = hashlib.sha256()
    for name in ("weights/weight.bin", "model.mil", "metadata.json"):
        h.update(name.encode())
        h.update((modelc_dir / name).read_bytes())
    return h.hexdigest()


def modelc_full_sha(modelc_dir: Path) -> str:
    """实际发布目录的完整哈希（含 coremldata.bin），用于上线完整性身份记录。"""
    return sha256_of(Path(modelc_dir))


def deploy_modelc(int4_package: Path, target_modelc: Path) -> str:
    """编译 mlpackage → target .mlmodelc，**原子发布**（评审 P1-B）。

    与旧实现的关键区别：
      · 编译与校验都在**目标同一父目录**的暂存目录里完成（同一文件系统），避免
        shutil.move 跨卷退化成「复制到一半失败」；
      · 校验通过后，用两次 os.rename 做原子交换：先把旧目录 rename 到备份，再把新目录
        rename 到 target（同 FS 的 rename 是近原子操作）；任一步失败则把旧目录 rename 回来，
        保证 target 要么是完整旧版、要么是完整新版，绝不出现半成品或把备份嵌进坏目录。
      · 全部校验通过后才切换，切换成功后才删备份。
    返回 target 的语义内容指纹。
    """
    import os
    import shutil
    import subprocess
    if not int4_package.exists():
        raise RuntimeError(f"待编译产物不存在：{int4_package}")
    target_modelc = Path(target_modelc)
    target_modelc.parent.mkdir(parents=True, exist_ok=True)
    # 暂存目录放在目标同一父目录 → 同一文件系统
    stage = target_modelc.parent / (".v3build_" + str(int(time.time())))
    if stage.exists():
        shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    try:
        r = subprocess.run(["xcrun", "coremlcompiler", "compile",
                            str(int4_package), str(stage)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"coremlcompiler 编译失败：{r.stderr.strip()[:500]}")
        built = stage / (int4_package.stem + ".mlmodelc")
        if not built.is_dir():
            cands = list(stage.glob("*.mlmodelc"))
            if not cands:
                raise RuntimeError(f"编译未产出 .mlmodelc：{list(stage.iterdir())}")
            built = cands[0]
        # 校验结构完整（缺必需文件即失败，绝不上线半成品）
        missing = [n for n in REQUIRED_MODELC_FILES if not (built / n).is_file()]
        if missing:
            raise RuntimeError(f"编译产物缺少必需文件 {missing}，拒绝部署")
        # 计算新指纹（在校验通过后）
        new_sha = modelc_content_sha(built)

        backup = target_modelc.parent / (".v3old_" + str(int(time.time())))
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
        had_old = target_modelc.exists()
        try:
            if had_old:
                os.rename(str(target_modelc), str(backup))  # 同 FS rename，近原子
            os.rename(str(built), str(target_modelc))       # 切换
        except Exception:
            # 回滚：若 target 仍空且备份在，则还原旧目录
            if not target_modelc.exists() and had_old and backup.exists():
                os.rename(str(backup), str(target_modelc))
            elif target_modelc.exists() and backup.exists():
                # target 已是新（rename 成功但后续异常），保留新、清备份
                shutil.rmtree(backup, ignore_errors=True)
            raise
        # 切换成功：删旧备份
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
        print(f"[deploy] 已原子部署 {target_modelc}（内容指纹={new_sha[:12]}…，{dir_size_mb(target_modelc):.2f} MB）")
        return new_sha
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="V3 checkpoint → CoreML fp16/INT4")
    ap.add_argument("--ckpt", default=str(DEFAULT_CKPT))
    ap.add_argument("--stage", default="all",
                    choices=["load", "fp16", "int4", "eval", "sens", "build", "all"])
    ap.add_argument("--scheme", default="protect_backbone", choices=list(SCHEMES.keys()),
                    help="量化方案：full_int4 / protect_backbone / protect_backbone_proj")
    ap.add_argument("--quant-mode", default="palettize", choices=["palettize"])
    ap.add_argument("--n-calib", type=int, default=128)
    ap.add_argument("--ios", type=int, default=18, choices=[17, 18])
    ap.add_argument("--out", default=None, help="int4 mlpackage 输出路径（默认 /tmp/v3_ckpt/v3_int4_<scheme>.mlpackage）")
    ap.add_argument("--modelc", default=None, help="部署目标 .mlmodelc；给出则编译并原子替换")
    ap.add_argument("--val-clips", action="store_true", help="评估用 checkpoint val_clips 独立留出")
    ap.add_argument("--force", action="store_true", help="忽略缓存强制重新导出 fp16")
    args = ap.parse_args()

    if args.n_calib <= 0:
        print(f"[错误] --n-calib 必须为正整数，收到 {args.n_calib}", file=sys.stderr)
        return 2

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ckpt_sha = sha256_of(Path(args.ckpt)) if Path(args.ckpt).exists() else "missing"
    report: Dict[str, object] = {
        "ckpt": args.ckpt, "ckpt_sha256": ckpt_sha, "ios": args.ios,
        "scheme": args.scheme, "git_commit": _git_commit(),
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    t_all = time.perf_counter()

    try:
        model, cfg = load_trained_model(Path(args.ckpt))
    except FileNotFoundError as exc:
        print(f"[错误] checkpoint 不存在：{exc}", file=sys.stderr)
        return 2
    report["params_train"] = model.get_param_count()["total"]
    report["params_deploy"] = model.get_param_count()["deploy_total"]

    fp16_path = OUT_DIR / "v3_fp16.mlpackage"
    int4_path = Path(args.out) if args.out else (OUT_DIR / f"v3_int4_{args.scheme}.mlpackage")

    # 依赖图：需要 fp16 基线的 stage（评审 P1-C：build 也要走 fp16 分支，否则读 fp16_size_mb 必 KeyError）
    needs_fp16 = args.stage in ("fp16", "int4", "eval", "all", "build")
    needs_int4 = args.stage in ("int4", "all", "build")

    # ── fp16 基线（带来源校验的缓存）──
    if needs_fp16:
        reuse = _check_or_write_fp16_stamp(OUT_DIR, ckpt_sha, args.ios, fp16_path, args.force, scheme=args.scheme)
        if not reuse:
            try:
                export_fp16(model, cfg, fp16_path, ios=args.ios)
            except Exception as exc:
                print(f"[错误] fp16 导出失败：{type(exc).__name__}: {exc}", file=sys.stderr)
                return 3
            _write_fp16_stamp(OUT_DIR, ckpt_sha, args.ios, fp16_path, scheme=args.scheme)
        report["fp16_size_mb"] = round(dir_size_mb(fp16_path), 3)
        report["fp16_sha256"] = sha256_of(fp16_path)
        report["build_status"] = "fp16_ok"

    # ── INT4 量化（按 scheme 保护层）──
    if needs_int4:
        if "fp16_size_mb" not in report:  # 防御：理论上 needs_fp16 已覆盖
            report["fp16_size_mb"] = round(dir_size_mb(fp16_path), 3)
        protected = resolve_protected_ops(fp16_path, args.scheme)
        report["scheme_protected_ops"] = len(protected)
        try:
            quantize_int4(fp16_path, int4_path, protected_op_names=protected,
                          granularity="per_tensor")
        except Exception as exc:
            print(f"[错误] INT4 量化失败：{type(exc).__name__}: {exc}", file=sys.stderr)
            return 3
        report["int4_path"] = str(int4_path)
        report["int4_size_mb"] = round(dir_size_mb(int4_path), 3)
        report["int4_sha256"] = sha256_of(int4_path)
        report["int4_compression"] = round(report["fp16_size_mb"] / max(report["int4_size_mb"], 1e-9), 3)
        report["build_status"] = "int4_ok"

    # ── 评估（硬门禁 + 三态）──
    eval_status = None
    if args.stage in ("eval", "all", "build"):
        if not (fp16_path.exists() and int4_path.exists()):
            print(f"[eval] 缺少待评估产物：fp16存在={fp16_path.exists()} int4存在={int4_path.exists()}", file=sys.stderr)
            eval_status = "skipped"
        else:
            drift = evaluate_drift(fp16_path, int4_path, Path(args.ckpt),
                                   args.n_calib, k_torch_model=model,
                                   use_val_clips=args.val_clips)
            report["drift"] = drift
            eval_status = drift.get("status", "failed") if isinstance(drift, dict) else "failed"
            # 未达标时跑分组敏感度，只作诊断，不改变 eval_status（评审 P0-2）
            if eval_status == "failed":
                report["sensitivity"] = sensitivity_analysis(fp16_path, Path(args.ckpt), args.n_calib)

    if args.stage == "sens":
        sens = sensitivity_analysis(fp16_path, Path(args.ckpt), args.n_calib)
        report["sensitivity"] = sens
        # 全部分组失败 → 视为失败（评审 P1-C）
        rows = sens.get("groups", []) if isinstance(sens, dict) else []
        if rows and all("error" in r for r in rows):
            print("[错误] 敏感度分析：所有分组均失败", file=sys.stderr)
            eval_status = "failed"

    report["eval_status"] = eval_status if eval_status is not None else "not_run"

    # ── 部署（仅 all/build 且评估通过；原子替换并绑定哈希）──
    deploy_status = "not_requested"
    if args.stage in ("all", "build"):
        if not args.modelc:
            deploy_status = "not_requested"
            print("[部署] 未提供 --modelc，跳过部署（eval_status 独立记录）")
        elif eval_status != "passed":
            deploy_status = "refused_eval_failed"
            print(f"[部署] 评估状态={eval_status}，未通过验收，拒绝部署", file=sys.stderr)
        else:
            try:
                deployed_sha = deploy_modelc(int4_path, Path(args.modelc))
                report["deployed_modelc"] = str(args.modelc)
                report["deployed_modelc_content_sha256"] = deployed_sha
                report["deployed_modelc_full_sha256"] = modelc_full_sha(Path(args.modelc))
                deploy_status = "deployed"
            except Exception as exc:
                print(f"[错误] 部署失败：{type(exc).__name__}: {exc}", file=sys.stderr)
                report["deploy_error"] = f"{type(exc).__name__}: {exc}"
                deploy_status = "deploy_failed"
    report["deploy_status"] = deploy_status

    report["total_seconds"] = round(time.perf_counter() - t_all, 1)
    (OUT_DIR / "export_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    # 审计产物：给出 --modelc 且部署成功时落一份到 models/（绑定提交与哈希）
    if args.modelc and deploy_status == "deployed":
        audit = Path(args.modelc).with_name("calibration_report.json")
        audit.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[done] 审计报告 → {audit}")

    print(f"[done] 报告 → {OUT_DIR / 'export_report.json'}；"
          f"build={report.get('build_status')} eval={report['eval_status']} deploy={deploy_status}")
    # 语义化退出码（评审 P0-2 / P1-C）：评估门禁是发布门禁
    if args.stage in ("load", "fp16", "int4", "sens"):
        # 仅构建类 stage：成功即 0；sens 全失败已在上面置 failed
        return 0 if report["eval_status"] in ("not_run",) else (0 if report["eval_status"] == "passed" else 1)
    if report["eval_status"] == "passed" and deploy_status in ("deployed", "not_requested"):
        return 0
    if report["eval_status"] == "skipped":
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
