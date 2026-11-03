#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 模型实测脚手架：参数量 / 模块占比 / forward 输出 shape。

为什么单独成脚本、而不把测量逻辑写进 `src/model_v3.py`：
  · 测量与业务代码分离是仓库既有约定（对照 `src/model_v3_experiments.py`），
    模型文件只描述结构，测量口径集中在脚本里，换口径不必碰模型。
  · 本脚本**只读**地 import 模型，不修改任何模型参数或源码。

测量口径（全部为本机实测，不接受估算值）：
  · 参数量 = sum(p.numel() for p in model.parameters())
  · forward shape = 真实跑一次随机输入后打印每个输出的 tuple(shape)
  · 体积 = 参数量 × 每参数字节数（fp32=4 / fp16=2 / int8=1 / 4bit=0.5）
    ⚠️ 这是**理论下界**，不含 CoreML 图结构/bias/元数据开销，
       与 .mlpackage 磁盘体积会有差异，报告里必须写清口径。

用法：
    # 训练态（RepVGG 多分支）
    /usr/local/bin/python3.11 tools/v3_exp/v3code_count.py

    # 部署态（已 reparameterize，参数量会变少）
    /usr/local/bin/python3.11 tools/v3_exp/v3code_count.py --deploy

    # 只做脚手架自检（不依赖 model_v3 是否已落盘）
    /usr/local/bin/python3.11 tools/v3_exp/v3code_count.py --selftest

退出码：0=成功；2=model_v3 尚未落盘（脚手架可用，模型未就绪）。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, Tuple

# ── 路径引导：本脚本位于 tools/v3_exp/ 下，仓库根在上两级 ──────────────
# 为什么显式插 sys.path 而不是 `from src import ...`：
#   以脚本方式运行时 sys.path[0] 是 tools/v3_exp/，仓库根不在其中，
#   直接 import src 会 ModuleNotFoundError（model_v2.py 头部记录过同类坑）。
_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import torch  # noqa: E402  （必须在 sys.path 引导之后导入）

# ── 输入契约（与 task-11 描述逐字一致，改这里等于改契约，需同步报告）──
#: 3 帧高清：批次 × 帧数 × 通道 × 高 × 宽
HI_SHAPE: Tuple[int, ...] = (3, 3, 224, 384)
#: 21 帧低清
LO_SHAPE: Tuple[int, ...] = (21, 3, 112, 192)
#: 车道线掩码
LANE_SHAPE: Tuple[int, ...] = (1, 160, 160)
#: 检测框固定槽位（空槽补 0）
DET_SHAPE: Tuple[int, ...] = (20, 12)
#: 检测框有效位
DET_MASK_SHAPE: Tuple[int, ...] = (20,)
#: 车辆状态
STATE_SHAPE: Tuple[int, ...] = (8,)

#: 输出名顺序（与 build_v3_model().forward 的返回顺序必须一致）
OUTPUT_NAMES: Tuple[str, ...] = (
    "vertical", "horizontal", "handbrake", "brake",
    "super_brake", "ultimate", "confidence", "risk",
)


def build_contract_inputs(batch: int = 1, device: str = "cpu") -> Dict[str, torch.Tensor]:
    """按契约构造一组随机输入（仅用于 shape 验证，不涉及数值正确性）。

    为什么用 `torch.rand` 而非 `torch.zeros`：
      全零输入会让 BatchNorm 之外的某些算子走进退化路径（如除法分母恒 0 的
      邻居算子），随机值更容易暴露 shape/广播类错误。
      但**不保证**数值语义正确 —— 本脚本只验证「跑得通、shape 对」。
    """
    shapes = {
        "image_hi": HI_SHAPE,
        "image_lo": LO_SHAPE,
        "lane": LANE_SHAPE,
        "dets": DET_SHAPE,
        "det_mask": DET_MASK_SHAPE,
        "vehicle_state": STATE_SHAPE,
    }
    inputs: Dict[str, torch.Tensor] = {}
    for name, shape in shapes.items():
        full = (batch,) + shape
        if name == "det_mask":
            # mask 用 1 表示全部有效：全 0 会让所有样本走"零向量早退"，
            # 测不到真实分支路径。上界不做归一，保持与 Swift 侧一致的 0/1 语义。
            inputs[name] = torch.ones(full, device=device)
        else:
            inputs[name] = torch.rand(full, device=device)
    return inputs


def count_module_params(model: torch.nn.Module) -> Dict[str, int]:
    """按**顶层子模块**统计参数量（用于看预算分配是否符合设计）。"""
    out: Dict[str, int] = {}
    for name, module in model.named_children():
        out[name] = sum(p.numel() for p in module.parameters())
    return out


def format_param_table(counts: Dict[str, int], total: int) -> str:
    """把模块参数量渲染成对齐表格（含占比，便于核对参数预算分配）。"""
    lines = ["=" * 62, "V3 模型参数统计（实测，按顶层子模块）", "=" * 62]
    width = max((len(k) for k in counts), default=8)
    for name, num in sorted(counts.items(), key=lambda kv: -kv[1]):
        ratio = (num / total * 100.0) if total else 0.0
        lines.append(f"{name:<{width}} : {num:>10,}  ({num / 1e6:>6.3f}M, {ratio:>5.1f}%)")
    lines.append("-" * 62)
    lines.append(f"{'合计':<{width}} : {total:>10,}  ({total / 1e6:>6.3f}M)")
    return "\n".join(lines)


def format_size_lines(total: int) -> str:
    """体积换算（理论下界，口径见文件头）。"""
    per_param = {"FP32": 4.0, "FP16": 2.0, "INT8": 1.0, "4bit": 0.5}
    parts = [f"{k}: {total * v / (1024 * 1024):.2f} MB" for k, v in per_param.items()]
    return "体积(理论): " + "  ".join(parts)


def run_forward_shape_check(model: torch.nn.Module, batch: int = 1) -> Dict[str, Tuple[int, ...]]:
    """真实跑一次 forward，返回 {输出名: shape}。

    为什么 eval() + no_grad()：
      · eval() 关掉 Dropout、固定 BatchNorm 统计量 —— 导出前的真实推理态；
        训练态下 Dropout 随机丢弃可能让某些维度意外变化，测出的 shape 不可信。
      · no_grad() 省显存，且避免测量动作产生计算图残留。
    """
    model.eval()
    inputs = build_contract_inputs(batch=batch)
    with torch.no_grad():
        outputs = model(**inputs)

    if not isinstance(outputs, dict):
        raise TypeError(
            f"forward 期望返回 dict（输出名→张量），实际 {type(outputs).__name__}；"
            f"若模型改为 tuple 返回，需同步修改本脚本与契约文档。")

    missing = [n for n in OUTPUT_NAMES if n not in outputs]
    if missing:
        raise KeyError(f"forward 返回缺少契约输出 {missing}，实际键={sorted(outputs)}")

    return {name: tuple(outputs[name].shape) for name in OUTPUT_NAMES}


def _selftest() -> int:
    """脚手架自检：用**已知参数量**的玩具模块验证统计口径本身没写错。

    为什么要自检：如果 count 函数本身有 bug，报告里的 12M 就是假的。
    用 Linear(10→20) 这个能手算的模块做锚点：10*20+20 = 220。
    """
    toy = torch.nn.Sequential(torch.nn.Linear(10, 20), torch.nn.ReLU())
    expected = 10 * 20 + 20
    actual = sum(p.numel() for p in toy.parameters())
    print(f"[selftest] Linear(10→20)+ReLU 参数量: 实测 {actual} / 期望 {expected}", end=" ")
    if actual != expected:
        print("❌ 统计口径错误")
        return 1
    print("✅")

    # forward shape 检查器同样要能独立验证：用一个返回契约 dict 的玩具模型。
    # ⚠️ 这个玩具模型必须与 `OUTPUT_NAMES` 同步 —— 若契约改了而这里没改，
    #    `--selftest` 会假红（报"缺少契约输出"），把契约问题误报成脚本 bug。
    #    实测踩过：8 输出契约落地后这里仍是旧 5 输出，selftest 直接 KeyError。
    class _ToyContractModel(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.dummy = torch.nn.Linear(1, 1)

        def forward(self, image_hi, image_lo, lane, dets, det_mask, vehicle_state):
            b = image_hi.shape[0]
            return {
                "vertical": torch.zeros(b, 3),
                "horizontal": torch.zeros(b, 3),
                "handbrake": torch.zeros(b, 1),
                "brake": torch.zeros(b, 1),
                "super_brake": torch.zeros(b, 1),
                "ultimate": torch.zeros(b, 1),
                "confidence": torch.zeros(b, 1),
                "risk": torch.zeros(b, 1),
            }

    shapes = run_forward_shape_check(_ToyContractModel(), batch=2)
    print(f"[selftest] 契约 shape 检查器: {shapes}")
    ok = (shapes["vertical"] == (2, 3) and shapes["horizontal"] == (2, 3)
          and shapes["handbrake"] == (2, 1))
    print("[selftest] " + ("✅ 通过" if ok else "❌ 失败"))
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="V3 模型实测脚手架（参数量 / forward shape）")
    parser.add_argument("--deploy", action="store_true",
                        help="构建部署态（已重参数化）；参数量会少于训练态")
    parser.add_argument("--batch", type=int, default=1, help="验证 forward 的批大小，默认 1")
    parser.add_argument("--selftest", action="store_true", help="只做脚手架自检，不加载 model_v3")
    args = parser.parse_args()

    if args.selftest:
        return _selftest()

    # ── model_v3 尚未落盘时给出明确提示，而不是抛一段看不懂的 ImportError ──
    try:
        from src.model_v3 import build_v3_model  # noqa: WPS433（延迟导入：允许未落盘）
    except ImportError as exc:
        print(f"[v3code_count] ❌ src/model_v3.py 尚不可用：{exc}")
        print("                脚手架已就绪，待 model_v3 落盘后重跑本脚本。")
        return 2

    model = build_v3_model(deploy=args.deploy)
    total = sum(p.numel() for p in model.parameters())
    counts = count_module_params(model)

    print(format_param_table(counts, total))
    print(format_size_lines(total))
    print(f"构建态: {'deploy（已重参数化）' if args.deploy else 'train（RepVGG 多分支）'}")

    print()
    shapes = run_forward_shape_check(model, batch=args.batch)
    print("=" * 62)
    print(f"forward 输出 shape（实测，B={args.batch}）")
    print("=" * 62)
    for name in OUTPUT_NAMES:
        print(f"{name:<12}: {shapes[name]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
