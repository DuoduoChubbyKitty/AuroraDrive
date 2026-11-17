#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 V3 checkpoint 导出为 CoreML fp16，**输出 = 现有 6 路 logits + state_token[256]**。

为什么要单独一个脚本、不改 `src/model_v3.py` / 不改现有 `export_v3_checkpoint_int4.py`：
  现有导出链（`EXPORT_OUTPUT_NAMES` = 6 个 logits）是**已验收的部署链**，
  直接改它会牵动 InferenceEngineV3.swift 的输出解析与 INT4 量化/漂移评估，
  风险远大于收益。Swift 端要做**本机在线训练**策略头时，需要冻结骨干吐出的
  `state_token`（V3Model.forward(return_state_token=True) 会返回 out["state_token"]，
  shape [B,256]）作为特征。本脚本只新增这一路输出，其余完全复用现有实现。

复用面（不重写、不复制）：
  · `install_torch_npu_stub` / `load_trained_model` —— 直接 import 现有导出脚本；
  · 输入构造、输入 TensorType —— 复用 `zeros_inputs` / `_input_shapes`；
  · 输出名集合 —— 直接读模型定义里的 `EXPORT_OUTPUT_NAMES`，避免脚本里再抄一份漂移。
本文件内**新增**一个 wrapper 变体 `_StateTokenExportWrapper`（在原 6 路 tuple 末尾追加
state_token），不改 `src/model_v3.py` 里的 `_ExportWrapper`。

用法：
  # 只做 trace + shape 校验，不写盘（本机轻量，不 forward 大批量、不训练）：
  /usr/local/bin/python3.11 tools/v3_exp/export_state_token_model.py --dry-run

  # 真实导出（写盘，较重；需 coremltools 可用）：
  /usr/local/bin/python3.11 tools/v3_exp/export_state_token_model.py \
      --ckpt models/aurora_v3_best_ep13_20261115.pt \
      --out models/v3_state_token.mlpackage

退出码：0 成功；2 参数/加载失败；3 CoreML 转换失败（打印真实错误）。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_V3_EXP = _REPO_ROOT / "tools" / "v3_exp"
if str(_V3_EXP) not in sys.path:
    sys.path.insert(0, str(_V3_EXP))

# 复用现有导出脚本（以 `import xxx as base` 形式，与本目录 features.py 的既有约定一致）。
import export_v3_checkpoint_int4 as base  # noqa: E402

DEFAULT_CKPT = _REPO_ROOT / "models" / "aurora_v3_best_ep13_20261115.pt"
DEFAULT_OUT = _REPO_ROOT / "models" / "v3_state_token.mlpackage"

# 新增输出名：state_token 是 V3Model.forward 在 return_state_token=True 时返回的第二阶段
# state token（[B, dim]，dim=256）。契约维数从模型定义读，不在这里写死 256。
STATE_TOKEN_NAME = "state_token"


def _state_token_dim() -> int:
    """state_token 的通道维（= V3Config.dim，默认 256）。从模型定义读，避免硬编码漂移。"""
    from src.model_v3 import V3Config
    return int(V3Config().dim)


def _all_output_names() -> Tuple[str, ...]:
    """导出输出契约 = 现有 6 路 logits + state_token（顺序即 tuple 顺序）。"""
    return tuple(base.OUTPUT_NAMES) + (STATE_TOKEN_NAME,)


def _build_wrapper_class():
    """在本文件内定义扩展 wrapper：在原有 6 路输出 tuple 末尾追加 state_token。

    为什么不继承 `_ExportWrapper` 再覆盖 forward：`_ExportWrapper.forward` 内部
    只按 `EXPORT_OUTPUT_NAMES` 取键、无法拿到 state_token；重新实现一个薄 forward
    更直白，也避免依赖父类内部实现细节。这里用 `nn.Module` 直接组合。
    """
    import torch.nn as nn

    class StateTokenExportWrapper(nn.Module):
        """把 forward(return_state_token=True) 的 dict → tuple(6 logits, state_token)。

        为什么必须返回 tuple 而不是 dict：coremltools 9.0 的 torch 前端没有实现
        `dictconstruct` 算子（见 src/model_v3.py `_ExportWrapper` 注释），直接导出 dict
        会在 ct.convert 报 NotImplementedError。tuple 是已验证可用的形态。
        """

        def __init__(self, model: nn.Module):
            super().__init__()
            self.model = model

        def forward(self, image_hi, image_lo, lane, dets, det_mask, vehicle_state):
            out = self.model(
                image_hi=image_hi, image_lo=image_lo, lane=lane,
                dets=dets, det_mask=det_mask, vehicle_state=vehicle_state,
                return_state_token=True,
            )
            return tuple(out[name] for name in base.OUTPUT_NAMES) + (out[STATE_TOKEN_NAME],)

    return StateTokenExportWrapper


def _print_trace_shapes(traced, dummy, expected_dim: int) -> None:
    """跑一遍 traced 图并打印每个输出张量 shape；断言 state_token 维数符合契约。"""
    import torch

    with torch.no_grad():
        outs = traced(*dummy)
    names = _all_output_names()
    if len(outs) != len(names):
        raise AssertionError(f"trace 输出数量 {len(outs)} != 契约 {len(names)}")
    print(f"[dry-run] trace 成功，输出 {len(outs)} 路张量：")
    for name, t in zip(names, outs):
        shape = tuple(int(d) for d in t.shape)
        print(f"           {name:<12} shape={shape}")
    st = outs[-1]
    if st.dim() != 2 or int(st.shape[-1]) != expected_dim:
        raise AssertionError(
            f"state_token 形状 {tuple(st.shape)} 不符合契约 [B,{expected_dim}]")
    print(f"[dry-run] ✅ state_token 维数确认 = {int(st.shape[-1])}（契约 {expected_dim}），"
          f"shape={tuple(int(d) for d in st.shape)}")


def run_dry_run(model, cfg) -> int:
    """只做 trace + 输出 shape 校验，不写盘（不 ct.convert、不 forward 大批量）。"""
    import torch

    wrapper = _build_wrapper_class()(model).eval()
    dummy = base.zeros_inputs(cfg, batch=1)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, dummy, strict=False)
    _print_trace_shapes(traced, dummy, _state_token_dim())
    print("[dry-run] 未写盘（--dry-run）；如需真实导出请去掉 --dry-run 并给 --out。")
    return 0


def run_export(model, cfg, out_path: Path, ios: int) -> int:
    """真实导出 fp16 mlpackage，输出 6 logits + state_token。"""
    import shutil

    import coremltools as ct
    import torch

    wrapper = _build_wrapper_class()(model).eval()
    dummy = base.zeros_inputs(cfg, batch=1)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, dummy, strict=False)

    # 先做形状校验（与 dry-run 同一逻辑），shape 不符就不进入昂贵的 convert。
    _print_trace_shapes(traced, dummy, _state_token_dim())

    if out_path.exists():
        shutil.rmtree(out_path)

    deploy_target = ct.target.iOS18 if ios >= 18 else ct.target.iOS17
    names = _all_output_names()
    try:
        mlmodel = ct.convert(
            traced,
            inputs=base._input_shapes(cfg),
            outputs=[ct.TensorType(name=n) for n in names],
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=deploy_target,
            convert_to="mlprogram",
        )
    except Exception as exc:  # 如实上报真实错误（coremltools 版本告警导致的失败不吞掉）
        print(f"[错误] CoreML 转换失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 3
    mlmodel.save(str(out_path))
    size_mb = base.dir_size_mb(out_path)
    print(f"[export] ✅ 导出成功（iOS{ios}）：{out_path}  {size_mb:.2f} MB，输出={list(names)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="V3 checkpoint → CoreML fp16（6 logits + state_token[256]）")
    ap.add_argument("--ckpt", default=str(DEFAULT_CKPT))
    ap.add_argument("--out", default=str(DEFAULT_OUT),
                    help="导出的 .mlpackage 路径（真实导出用）")
    ap.add_argument("--ios", type=int, default=17, choices=[17, 18])
    ap.add_argument("--dry-run", action="store_true",
                    help="只 trace + shape 校验，不写盘")
    args = ap.parse_args()

    ckpt = Path(args.ckpt)
    if not ckpt.exists():
        print(f"[错误] checkpoint 不存在：{ckpt}", file=sys.stderr)
        return 2
    try:
        model, cfg = base.load_trained_model(ckpt)
    except FileNotFoundError as exc:
        print(f"[错误] checkpoint 不存在：{exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"[错误] 加载 checkpoint 失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 2

    if args.dry_run:
        return run_dry_run(model, cfg)
    return run_export(model, cfg, Path(args.out), args.ios)


if __name__ == "__main__":
    sys.exit(main())
