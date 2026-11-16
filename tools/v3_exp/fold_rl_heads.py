#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 RL 训出的头权重折回完整 V3 checkpoint，补齐「真训完 → 部署」缺的一环。

背景（为什么需要这个脚本）：
  `tools/v3_rl/train_rl.py` 只保存**可训练的头权重**（`policy.TorchPolicy.head_state_dict()`，
  键名形如 `vertical.weight` / `horizontal.weight` / `value.*`）。它并没有把这几把小张量
  写回完整的 V3 checkpoint，因此「训完 → 走现有 INT4/CoreML 导出」这条链断了一环：
  `export_v3_checkpoint_int4.py` 要的是一份**完整、结构严格匹配**的 checkpoint，喂给它
  只有几把头的 .pt 会直接 strict 加载失败。本脚本就是把头权重折回完整 checkpoint 的桥。

做什么 / 不做什么：
  * 只回灌 **部署会用到** 的两个决策头：`output_head.vertical` 与 `output_head.horizontal`
    （各 weight + bias，共 4 个张量）。它们决定纵向/横向动作分类，是真正上线的权重。
  * `value.*` 是 PPO 的 critic（价值基线），**不参与部署**，只用于训练期优势估计；
    这里跳过并打印提示，不写入 checkpoint（写进去反而是污染：导出图里没有它）。
  * 骨架、trunk、其余安全头（handbrake/brake/confidence/risk）**一律不动**，保持原
    checkpoint 的字节内容——我们只改那 4 个键。

为什么保存「训练态（deploy=False）」的完整 checkpoint 而不是 deploy 态的模型：
  `export_v3_checkpoint_int4.py` 的加载契约是「先按训练态 build → strict 加载多分支
  checkpoint → 再 reparameterize 折叠」。它要的 checkpoint 里骨干是**训练态多分支**权重。
  所以本脚本原样保留原 checkpoint 的训练态 state_dict，只在内存里替换 4 个 Linear 头键，
  再整体存盘，这样产物能被下游导出脚本原样 strict 加载。

strict 校验（本脚本的核心价值，拒绝静默失败）：
  * 原始 checkpoint 用 `export_v3_checkpoint_int4.load_trained_model` 严格加载一遍
    （strict=True），确认「源 checkpoint 正是导出会接受的那份」。
  * 对每个要回灌的头键，逐一核对：键在 checkpoint 里是否存在 → 形状是否一致。
    任何键缺失 / 形状不符 / 未知前缀，都**带键名**报错并退出，绝不吞异常。
  * 折叠后的完整 state_dict 再 strict 加载进一个全新的训练态模型，证明「产物本身
    也能被下游 strict 加载」——这步只 build + load，不 forward、不训练。

本机硬约束（不得违反）：
  本机只允许「加载 + 键对齐校验」这类只读动作；**禁止真实训练与推理**。因此本脚本
  默认就只做键对齐（`--dry-run`），不做 forward、不做量化、不碰 CoreML。真正的
  INT4/CoreML 导出与训练都必须在云端 GPU 机器上跑（见 docs/v3-design/06 文档）。

用法：
  # 只校验键对齐，不写盘（本机可跑，符合「禁止训练/推理」约束）
  /usr/local/bin/python3.11 tools/v3_exp/fold_rl_heads.py \
      --ckpt models/aurora_v3_best_ep13_20261115.pt \
      --head-ckpt /path/to/rl_head.pt --out /tmp/aurora_v3_rl_folded.pt --dry-run

  # 真正落盘一份可部署 checkpoint（应在云端或明确允许写盘的机器上执行）
  /usr/local/bin/python3.11 tools/v3_exp/fold_rl_heads.py \
      --ckpt models/aurora_v3_best_ep13_20261115.pt \
      --head-ckpt /path/to/rl_head.pt --out models/aurora_v3_rl_folded.pt
退出码：0 成功；2 参数/输入错误；3 键对齐校验失败（键缺失或形状不符）。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import torch

_REPO_ROOT = Path(__file__).resolve().parents[2]
# 复用导出脚本的加载与哈希逻辑：保证「折回」与「导出」对 checkpoint 的理解完全一致。
for _p in (_REPO_ROOT, _REPO_ROOT / "tools" / "v3_exp"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import export_v3_checkpoint_int4 as E  # noqa: E402

DEFAULT_CKPT = _REPO_ROOT / "models" / "aurora_v3_best_ep13_20261115.pt"

# 部署会消费的两个决策头：RL head 键 → 完整 checkpoint 里的目标键（加 output_head. 前缀）。
# 顺序固定，便于报告稳定对齐；value.* 刻意不在列。
DEPLOY_HEAD_KEYS: Tuple[str, ...] = (
    "vertical.weight", "vertical.bias",
    "horizontal.weight", "horizontal.bias",
)
_HEAD_PREFIX = "output_head."


def _extract_state_dict(ckpt: object, ckpt_path: Path) -> Dict[str, torch.Tensor]:
    """按导出脚本同一口径取出训练态 state_dict，并去掉 torch.compile 的 _orig_mod. 前缀。"""
    if isinstance(ckpt, dict) and "model" in ckpt:
        sd = ckpt["model"]
    elif isinstance(ckpt, dict) and "model_state_dict" in ckpt:
        sd = ckpt["model_state_dict"]
    elif isinstance(ckpt, dict) and all(torch.is_tensor(v) for v in ckpt.values()):
        sd = ckpt  # 裸 state_dict
    else:
        raise RuntimeError(
            f"无法从 {ckpt_path} 识别 state_dict：期望 dict 含 'model'/'model_state_dict'，"
            f"或全为张量的裸 state_dict，实际顶层类型={type(ckpt).__name__}，"
            f"顶层键={list(ckpt)[:8] if isinstance(ckpt, dict) else 'N/A'}")
    stripped: Dict[str, torch.Tensor] = {}
    for k, v in sd.items():
        nk = k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k
        if nk in stripped:
            raise RuntimeError(f"{ckpt_path} 去 _orig_mod. 前缀后出现重名键：{nk}")
        stripped[nk] = v
    return stripped


def _extract_head_state_dict(head_ckpt: object, head_path: Path) -> Dict[str, torch.Tensor]:
    """从 RL 头 .pt 取出 head_state_dict；兼容 train_rl 的包装 dict 与裸头 dict 两种形态。"""
    if not isinstance(head_ckpt, dict):
        raise RuntimeError(f"{head_path} 不是 dict（train_rl --out-ckpt 产物应为含 head_state_dict 的 dict），"
                           f"实际类型={type(head_ckpt).__name__}")
    if "head_state_dict" in head_ckpt:
        head_sd = head_ckpt["head_state_dict"]
    elif head_ckpt and all(torch.is_tensor(v) for v in head_ckpt.values()):
        head_sd = head_ckpt  # 裸 head_state_dict
    else:
        raise RuntimeError(f"{head_path} 里找不到 head_state_dict，顶层键={list(head_ckpt.keys())[:8]}")
    if not isinstance(head_sd, dict) or not head_sd:
        raise RuntimeError(f"{head_path} 的 head_state_dict 为空或非 dict：{type(head_sd).__name__}")
    return head_sd


def _align_and_fold(
    train_sd: Dict[str, torch.Tensor],
    head_sd: Dict[str, torch.Tensor],
) -> List[Dict[str, object]]:
    """逐键核对并生成折叠后的新 state_dict（不写盘）。

    返回每个键的对齐报告；任何缺失/形状不符/未知前缀都抛 RuntimeError（带键名）。
    """
    # 先确认 head_sd 不带未知键：除 value.*（critic，跳过）外，只能是 vertical./horizontal.。
    unknown = [k for k in head_sd
               if not (k.startswith("vertical.") or k.startswith("horizontal.") or k.startswith("value."))]
    if unknown:
        raise RuntimeError(f"RL 头 checkpoint 含未知前缀键（不认识，拒绝回灌）：{unknown}")

    # 必须齐备的部署头键：缺一个都不行，否则折回的 checkpoint 会带着旧头权重静默上线。
    missing_in_head = [k for k in DEPLOY_HEAD_KEYS if k not in head_sd]
    if missing_in_head:
        raise RuntimeError(f"RL 头 checkpoint 缺失部署必需的键：{missing_in_head}")

    report: List[Dict[str, object]] = []
    for src_key in DEPLOY_HEAD_KEYS:
        dst_key = _HEAD_PREFIX + src_key  # vertical.weight → output_head.vertical.weight
        src_t = head_sd[src_key]
        if dst_key not in train_sd:
            raise RuntimeError(f"原 checkpoint 缺少目标键 {dst_key}（对应 RL 键 {src_key}）——结构不匹配")
        dst_t = train_sd[dst_key]
        if tuple(src_t.shape) != tuple(dst_t.shape):
            raise RuntimeError(
                f"形状不符：{src_key} {tuple(src_t.shape)} vs {dst_key} {tuple(dst_t.shape)}")
        train_sd[dst_key] = src_t.detach().cpu().clone()  # 原地替换该键
        report.append({
            "rl_key": src_key, "ckpt_key": dst_key,
            "shape": tuple(int(x) for x in src_t.shape), "status": "aligned",
        })

    # value.* 只有提示意义：它不写进 checkpoint。列出个数便于审计。
    skipped = sorted(k for k in head_sd if k.startswith("value."))
    report.append({"value_skipped": skipped, "status": "skipped_critic"})
    return report


def _validate_folded_strict(folded_sd: Dict[str, torch.Tensor]) -> None:
    """把折叠后的完整 state_dict 严格加载进全新训练态模型，证明产物结构可被下游接受。

    只 build + load_state_dict(strict=True)，不 forward、不训练（符合本机约束）。
    """
    from src.model_v3 import build_v3_model, V3Config
    model = build_v3_model(deploy=False, cfg=V3Config())
    model.load_state_dict(folded_sd, strict=True)  # 任何 missing/unexpected 直接抛


def _validate_final_container(out_ckpt: "object") -> None:
    """按导出器 load_trained_model 的**同一口径**从最终容器取出 state_dict 并 strict 校验。

    这一步专门验证"写出去的那份容器"能被下游接受：若把裸 state_dict 装进顶层、
    又在顶层塞了非张量元数据（如 rl_fold），导出器会把它整体当 state_dict 而失败。
    """
    if isinstance(out_ckpt, dict) and "model" in out_ckpt:
        sd = out_ckpt["model"]
    elif isinstance(out_ckpt, dict) and "model_state_dict" in out_ckpt:
        sd = out_ckpt["model_state_dict"]
    else:
        sd = out_ckpt
        if isinstance(out_ckpt, dict) and not all(torch.is_tensor(v) for v in out_ckpt.values()):
            raise RuntimeError(
                "最终容器既不含 'model'/'model_state_dict'，顶层又混入非张量键，"
                f"导出器会把它当 state_dict 加载失败；顶层键={list(out_ckpt)[:8]}")
    _validate_folded_strict(sd)


def main(argv: "List[str] | None" = None) -> int:
    ap = argparse.ArgumentParser(
        description="把 RL 训出的头权重折回完整 V3 checkpoint（供 INT4/CoreML 导出）")
    ap.add_argument("--ckpt", default=str(DEFAULT_CKPT),
                    help="原始 V3 checkpoint（训练态、完整权重）")
    ap.add_argument("--head-ckpt", required=True,
                    help="RL 训练产物 .pt（train_rl --out-ckpt，含 head_state_dict）")
    ap.add_argument("--out", required=True,
                    help="输出完整可部署 checkpoint 路径")
    ap.add_argument("--dry-run", action="store_true",
                    help="只做键对齐校验，不写盘（本机可跑；不做 forward、不训练）")
    args = ap.parse_args(argv)

    ckpt_path = Path(args.ckpt)
    head_path = Path(args.head_ckpt)
    out_path = Path(args.out)
    if not ckpt_path.is_file():
        print(f"[错误] --ckpt 不存在：{ckpt_path}", file=sys.stderr)
        return 2
    if not head_path.is_file():
        print(f"[错误] --head-ckpt 不存在：{head_path}", file=sys.stderr)
        return 2

    # 1) 复用导出脚本的加载逻辑，严格校验「源 checkpoint 正是导出会接受的那份」。
    E.install_torch_npu_stub()
    try:
        model, _cfg = E.load_trained_model(ckpt_path)
    except Exception as exc:  # noqa: BLE001 - 上报具体原因后以非零码退出，不吞
        print(f"[错误] 源 checkpoint 严格加载失败（{ckpt_path}）：{exc}", file=sys.stderr)
        return 3
    del model  # 只要校验结果；fold 走训练态 state_dict

    # 2) 取出原始训练态 state_dict、RL 头 dict，逐键对齐并折叠。
    raw_ckpt = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
    train_sd = _extract_state_dict(raw_ckpt, ckpt_path)
    head_sd = _extract_head_state_dict(
        torch.load(str(head_path), map_location="cpu", weights_only=False), head_path)
    try:
        report = _align_and_fold(train_sd, head_sd)
    except RuntimeError as exc:
        print(f"[错误] 键对齐失败：{exc}", file=sys.stderr)
        return 3

    # 3) 打印对齐明细（不论 dry-run 与否都打印，留审计痕迹）。
    print(f"[fold] 源 checkpoint : {ckpt_path}")
    print(f"[fold] RL 头 checkpoint: {head_path}")
    for row in report:
        if "ckpt_key" in row:
            print(f"[fold]   ✓ {row['rl_key']:<20} → {row['ckpt_key']:<32} shape={row['shape']}")
        elif "value_skipped" in row:
            vals = row["value_skipped"]
            print(f"[fold]   · 跳过 critic（不参与部署，不写入）：{vals if vals else '无'}")

    # 4) 折叠产物再 strict 加载一遍，证明「写出去的这份也能被下游接受」。
    try:
        _validate_folded_strict(train_sd)
    except Exception as exc:  # noqa: BLE001
        print(f"[错误] 折叠后的完整 checkpoint strict 校验失败：{exc}", file=sys.stderr)
        return 3
    print("[fold] 折叠后完整 checkpoint strict 校验通过（仅 load，未 forward/未训练）。")

    # 5) 真正落盘：始终包装成 {"model": state_dict, ...} 容器。
    #    导出器 load_trained_model 只把 ckpt["model"] / ckpt["model_state_dict"] 当作
    #    state_dict；若这里写裸 state_dict 再往顶层塞 "rl_fold"，导出器会把整个顶层
    #    （含非张量的 rl_fold）当成 state_dict 去 strict 加载而失败。故裸输入也必须包一层，
    #    并且 dry-run 的 strict 校验要针对**最终写出的容器**，不能只验裸 dict。
    if isinstance(raw_ckpt, dict) and "model" in raw_ckpt:
        out_ckpt = dict(raw_ckpt)
        out_ckpt["model"] = train_sd
    elif isinstance(raw_ckpt, dict) and "model_state_dict" in raw_ckpt:
        out_ckpt = dict(raw_ckpt)
        out_ckpt["model_state_dict"] = train_sd
    else:
        # 裸 state_dict 输入：包成与导出一致的 "model" 容器，杜绝顶层非张量键污染。
        out_ckpt = {"model": train_sd}
    out_ckpt["rl_fold"] = {
        "source_ckpt": str(ckpt_path),
        "source_sha256": E.sha256_of(ckpt_path),
        "head_ckpt": str(head_path),
        "head_sha256": E.sha256_of(head_path),
        "folded_head_keys": list(DEPLOY_HEAD_KEYS),
    }

    # 6) 校验**最终容器**能被导出逻辑正确取出并 strict 加载（对比第 4 步只验裸 train_sd）。
    try:
        _validate_final_container(out_ckpt)
    except Exception as exc:  # noqa: BLE001
        print(f"[错误] 最终 checkpoint 容器校验失败（导出器将无法加载）：{exc}", file=sys.stderr)
        return 3
    print("[fold] 最终容器校验通过（导出器可从中取出 'model' 并 strict 加载）。")

    if args.dry_run:
        print(f"[fold] --dry-run：键对齐+最终容器校验通过，未写盘（目标将输出到 {out_path}）。")
        return 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(out_ckpt, str(out_path))
    print(f"[fold] 已写出完整可部署 checkpoint → {out_path}"
          f"（sha256={E.sha256_of(out_path)}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
