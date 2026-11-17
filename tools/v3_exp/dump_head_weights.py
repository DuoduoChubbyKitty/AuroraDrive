#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 V3 checkpoint 取出 output_head 的初始权重，导出成 Swift 易读的 JSON。

背景：Swift 端要在本机（iOS/macOS）做在线训练策略头时，需要一个与 V3 训练对齐的
**输出头初始权重**，否则本地头要从零学起、偏离已训练的 V3 表示。本脚本把 checkpoint
里 `output_head` 的相关张量读出来，按推理时的实际结构（Dropout 已关闭，不含 dropout）
扁平化成 `{name: {shape, data:[...]}}`，供 Swift 侧构造 `Linear/ReLU` 层时逐层加载。

结构（见 src/model_v3.py `V3OutputHead`，dim=256 / hidden1=192 / hidden2=96）：
    trunk:          Linear(256→192) → ReLU → Dropout(0.1，推理关闭) → Linear(192→96) → ReLU
    vertical:       Linear(96→3)
    horizontal:     Linear(96→3)
    handbrake:      Linear(96→1)
    brake:          Linear(96→1)
    confidence:     Linear(96→1)
    risk:           Linear(96→1)
（super_brake / ultimate 是派生输出，没有独立 Linear；value 头本 checkpoint 里不存在，
  脚本额外给一条“256→1，初始 0（输出头 bias=0）”的初始化建议，见文档头说明。）

⚠️ 训练口径差异（如实标注，见 tools/v3_rl/policy.py）：
   Python RL 端把 `output_head.trunk` **冻结**，只训练 vertical/horizontal + 一个新建
   value_head；本脚本按“导出顶部输出头结构”的口径，把 trunk 也一并导出，便于 Swift
   既可选“冻结 trunk、只训两决策头”，也可选“全头微调”。是否冻结由 Swift 侧决定，
   本脚本只如实给出全部顶部输出头权重。

用法：
  /usr/local/bin/python3.11 tools/v3_exp/dump_head_weights.py \
      --ckpt models/aurora_v3_best_ep13_20261115.pt \
      --out tools/v3_rl/swift_head_init.json

退出码：0 成功；2 checkpoint 缺失/缺键。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
_V3_EXP = _REPO_ROOT / "tools" / "v3_exp"
if str(_V3_EXP) not in sys.path:
    sys.path.insert(0, str(_V3_EXP))

import export_v3_checkpoint_int4 as base  # noqa: E402

DEFAULT_CKPT = _REPO_ROOT / "models" / "aurora_v3_best_ep13_20261115.pt"
DEFAULT_OUT = _REPO_ROOT / "tools" / "v3_rl" / "swift_head_init.json"

# trunk 的 Linear 在 Sequential 中的下标：0 = Linear(256→192)，3 = Linear(192→96)
# （下标 1=ReLU、2=Dropout 无参数；与 V3OutputHead.trunk 的定义严格对应。）
TRUNK_LINEAR_INDICES = (0, 3)

# 需要导出的独立 Linear 头（均为 96→C）。super_brake/ultimate 是派生量，无独立权重。
LINEAR_HEADS = ("vertical", "horizontal", "handbrake", "brake", "confidence", "risk")


def _load_state_dict(ckpt_path: Path) -> Dict[str, "object"]:
    """按与现有导出脚本完全一致的口径加载 state_dict（NPU shim + 去 _orig_mod. 前缀）。

    复用 base 的 install_torch_npu_stub，但**不 build 模型**（只读权重，不需要实例化
    整个 V3），因此这里直接 torch.load + 取 ckpt["model"]/["model_state_dict"]/ckpt。
    """
    import torch

    base.install_torch_npu_stub()
    ckpt = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
    if isinstance(ckpt, dict) and "model" in ckpt:
        sd = ckpt["model"]
    elif isinstance(ckpt, dict) and "model_state_dict" in ckpt:
        sd = ckpt["model_state_dict"]
    else:
        sd = ckpt
    return {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v
            for k, v in sd.items()}


def _tensor_entry(name: str, tensor) -> Dict[str, object]:
    """把一个张量转成 {name, shape, data}；data 为行优先扁平 float 列表（float32 精度）。"""
    import numpy as np

    arr = tensor.detach().to("cpu", dtype=None).contiguous()
    arr_np = arr.numpy().astype(np.float32).reshape(-1)
    return {
        "name": name,
        "shape": [int(d) for d in arr.shape],
        "data": [float(x) for x in arr_np],
    }


def build_head_payload(sd: Dict[str, "object"]) -> Dict[str, object]:
    """从 state_dict 抽 output_head 的顶部结构，返回可直接 json 序列化的 payload。"""
    tensors: List[Dict[str, object]] = []

    # ── trunk: Sequential(Linear, ReLU, Dropout, Linear, ReLU) 的两个 Linear ──
    for idx in TRUNK_LINEAR_INDICES:
        for suffix in ("weight", "bias"):
            key = f"output_head.trunk.{idx}.{suffix}"
            if key not in sd:
                raise KeyError(f"checkpoint 缺少 trunk 张量：{key}")
            tensors.append(_tensor_entry(f"trunk.{idx}.{suffix}", sd[key]))

    # ── 6 个独立 Linear 头 ──
    for head in LINEAR_HEADS:
        for suffix in ("weight", "bias"):
            key = f"output_head.{head}.{suffix}"
            if key not in sd:
                raise KeyError(f"checkpoint 缺少输出头张量：{key}")
            tensors.append(_tensor_entry(f"{head}.{suffix}", sd[key]))

    def shape_of(name: str) -> List[int]:
        for t in tensors:
            if t["name"] == name:
                return t["shape"]
        raise KeyError(name)

    dim = shape_of("trunk.0.weight")[1]          # 256
    hidden2 = shape_of("trunk.3.weight")[0]      # 96

    return {
        "source": "V3 checkpoint output_head（推理态，Dropout 已关闭，不含 dropout）",
        "dim_state_token": dim,
        "hidden1": shape_of("trunk.0.weight")[0],   # 192
        "hidden2": hidden2,                          # 96
        "structure": {
            "trunk": [
                {"op": "Linear", "in": dim, "out": shape_of("trunk.0.weight")[0]},
                {"op": "ReLU"},
                {"op": "Linear", "in": shape_of("trunk.3.weight")[1], "out": hidden2},
                {"op": "ReLU"},
            ],
            "heads": {h: {"op": "Linear", "in": hidden2,
                          "out": shape_of(f"{h}.weight")[0]} for h in LINEAR_HEADS},
        },
        "value_head_init": {
            "note": "checkpoint 内无 value 头；建议新建 state_token(256)→1 的线性，权重与 bias 初始化为 0",
            "shape_weight": [1, dim],
            "shape_bias": [1],
            "init": "zero",
        },
        "tensors": tensors,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="导出 V3 output_head 初始权重为 Swift 易读 JSON")
    ap.add_argument("--ckpt", default=str(DEFAULT_CKPT))
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    args = ap.parse_args()

    ckpt = Path(args.ckpt)
    if not ckpt.exists():
        print(f"[错误] checkpoint 不存在：{ckpt}", file=sys.stderr)
        return 2
    sd = _load_state_dict(ckpt)
    try:
        payload = build_head_payload(sd)
    except KeyError as exc:
        print(f"[错误] 权重结构不符：{exc}", file=sys.stderr)
        return 2

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    size_kb = out_path.stat().st_size / 1024
    print(f"[dump] ✅ 写入 {out_path}  ({size_kb:.1f} KB)")
    print(f"[dump] state_token 维数 dim={payload['dim_state_token']}，"
          f"hidden1={payload['hidden1']}，hidden2={payload['hidden2']}")
    print(f"[dump] 导出 {len(payload['tensors'])} 个张量：")
    for t in payload["tensors"]:
        print(f"        {t['name']:<20} shape={t['shape']}  n={len(t['data'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
