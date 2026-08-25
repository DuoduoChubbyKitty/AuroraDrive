# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
M9-Mono 单目模型训练 + ONNX/CoreML 导出

完整流程：
  1. 从 data/raw_clips/ 加载所有 clip（旧版 Python + 新版 C++ 格式均支持）
  2. 按 clip 边界划分 train/val
  3. 训练 M9MonoModel（RepVGG-A0 + 6 维 state → 三头）
  4. 保存 best_model.pt 到 checkpoints/m9_mono/
  5. 导出 ONNX 到 models/m9_mono.onnx
  6. 转换 ONNX → CoreML models/m9_mono.mlmodelc

用法：
  /usr/local/bin/python3.11 -m src.train_mono --epochs 30
  /usr/local/bin/python3.11 -m src.train_mono --epochs 30 --no-amp --device cpu
"""

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Optional, Dict

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

# 项目根路径
_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT))

from src.config import ROOT_DIR, MODELS_DIR, LOSS_WEIGHTS, TRAIN_GRAD_CLIP_NORM, TRAIN_WEIGHT_DECAY
from src.model import M9MonoModel, M9Loss, build_m9_mono, export_onnx_mono
from src.mono_dataset import MonoClipsDataset, make_train_val_split


def _print_mono_stats(model: M9MonoModel):
    """打印 M9-Mono 模型参数统计（避免 get_model_stats() 对 M9Model 的硬编码依赖）。"""
    repvgg_p = sum(p.numel() for p in model.repvgg.parameters())
    fusion_p = sum(p.numel() for p in model.fusion_head.parameters())
    total = repvgg_p + fusion_p
    print(f"─── M9-Mono 参数统计 ───")
    print(f"  RepVGG-A0:   {repvgg_p:>10,}  ({repvgg_p/1e6:.2f}M)")
    print(f"  FusionHead:  {fusion_p:>10,}  ({fusion_p/1e3:.1f}K)")
    print(f"  Total:       {total:>10,}  ({total/1e6:.2f}M)")
    print(f"  Size: fp32={total*4/1024/1024:.1f}MB  fp16={total*2/1024/1024:.1f}MB")
    print(f"─────────────────────")


# ==================== 优化器（param group 分离：BN/bias 不加 WD）====================

def build_adamw_optimizer(model: torch.nn.Module, lr: float, weight_decay: float):
    """分离 decay/no_decay 参数组：1D 参数（BN γ/β、bias）不加 weight decay。
    跳过 requires_grad=False 的冻结参数。"""
    decay, no_decay = [], []
    for n, p in model.named_parameters():
        if not p.requires_grad:
            continue
        if p.ndim <= 1 or "bn" in n.lower() or "bias" in n.lower() or "norm" in n.lower():
            no_decay.append(p)
        else:
            decay.append(p)
    return torch.optim.AdamW(
        [
            {"params": decay, "weight_decay": weight_decay},
            {"params": no_decay, "weight_decay": 0.0},
        ],
        lr=lr,
    )


# ==================== Cosine Annealing + Warmup 调度器 ====================

class CosineWithWarmup:
    """Warmup（线性）→ Cosine Annealing。
    Warmup 阶段 lr 线性从 0 升到 base_lr；之后 cosine 衰减到 min_lr。"""

    def __init__(self, optimizer, warmup_steps: int, total_steps: int,
                 base_lr: float, min_lr: float = 1e-6):
        self.opt = optimizer
        self.warmup = max(1, warmup_steps)
        self.total = max(self.warmup + 1, total_steps)
        self.base_lr = base_lr
        self.min_lr = min_lr
        self.step_n = 0

    def step(self):
        self.step_n += 1
        lr = self._lr(self.step_n)
        for pg in self.opt.param_groups:
            pg["lr"] = lr

    def _lr(self, n: int) -> float:
        if n <= self.warmup:
            return self.base_lr * n / self.warmup
        # Cosine phase
        progress = (n - self.warmup) / max(1, self.total - self.warmup)
        progress = min(max(progress, 0.0), 1.0)
        cosine = 0.5 * (1.0 + math.cos(math.pi * progress))
        return self.min_lr + (self.base_lr - self.min_lr) * cosine


# ==================== 训练循环 ====================

def train_mono(
    epochs: int = 30,
    batch_size: int = 8,
    grad_accum: int = 2,
    lr: float = 3e-4,
    weight_decay: float = TRAIN_WEIGHT_DECAY,
    image_size=(180, 320),
    val_ratio: float = 0.15,
    use_amp: bool = True,
    device: str = "auto",
    clips_dir: Optional[str] = None,
    view_filter: Optional[str] = None,
    checkpoint_dir: Optional[str] = None,
    resume_from: Optional[str] = None,
    num_workers: int = 0,
    seed: int = 42,
) -> Path:
    """完整训练流程。返回 best_model.pt 路径。"""

    # 1. 设备选择
    if device == "auto":
        if torch.backends.mps.is_available():
            device = "mps"
        elif torch.cuda.is_available():
            device = "cuda"
        else:
            device = "cpu"
    print(f"\n{'='*60}\n[M9-Mono] 训练 | device={device} | epochs={epochs} "
          f"| batch={batch_size}×{grad_accum}\n{'='*60}\n")

    # 2. 数据集
    clips_dir = Path(clips_dir) if clips_dir else _ROOT / "data" / "raw_clips"
    train_dataset = MonoClipsDataset(
        clips_dir, image_size=image_size, augment=True,
        skip_zero_label=True, seed=seed, view_filter=view_filter)
    train_ds, val_ds = make_train_val_split(train_dataset, val_ratio=val_ratio, seed=seed)

    # pin_memory 仅 CUDA 受益；MPS 上反而增加 host↔device 拷贝开销
    pin = (device == "cuda")
    train_loader = DataLoader(
        train_ds, batch_size=batch_size, shuffle=True,
        num_workers=num_workers, pin_memory=pin, drop_last=True,
        persistent_workers=(num_workers > 0))
    val_loader = DataLoader(
        val_ds, batch_size=batch_size, shuffle=False,
        num_workers=num_workers, pin_memory=pin,
        persistent_workers=(num_workers > 0))

    # 3. 模型 + 优化器 + 损失
    torch.manual_seed(seed)
    model = build_m9_mono(deploy=False)
    model.to(device)
    _print_mono_stats(model)

    # 增量续训：resume_from 指定且文件存在时，从现有权重加载（训练逻辑不变）
    if resume_from:
        if os.path.exists(resume_from):
            print(f"\n[Resume] 从 {resume_from} 加载权重继续训练")
            _ck = torch.load(resume_from, map_location="cpu", weights_only=False)
            _sd = _ck["model_state_dict"] if isinstance(_ck, dict) and "model_state_dict" in _ck else _ck
            _sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v
                   for k, v in _sd.items()}
            _miss, _unexp = model.load_state_dict(_sd, strict=False)
            print(f"[Resume] ✓ 加载完成 | missing={len(_miss)} unexpected={len(_unexp)}")
        else:
            print(f"\n[Resume] ⚠ resume_from 指定但不存在: {resume_from}，改为从头训练")

    # 激活流（可视化用）：默认关闭，AURORA_ACT_STREAM=1 时启用，对正常训练零开销
    act_streamer = None
    if os.environ.get("AURORA_ACT_STREAM"):
        try:
            from src.act_stream import ActivationStreamer
            _act_dir = Path(checkpoint_dir) if checkpoint_dir else (_ROOT / "checkpoints" / "m9_mono")
            _act_path = _act_dir / "activation_state.json"
            act_streamer = ActivationStreamer(model, _act_path, every=4)
            print(f"[ActStream] 已启用 → {_act_path}")
        except Exception as _e:
            print(f"  ⚠ 激活流初始化失败: {_e}")

    optimizer = build_adamw_optimizer(model, lr=lr, weight_decay=weight_decay)
    loss_fn = M9Loss(**LOSS_WEIGHTS)

    # AMP scaler（CPU 无 AMP，CUDA 用；MPS 完全不用：GradScaler 在 MPS 上会因 inf 梯度
    # 导致 optimizer.step 静默跳过，权重冻结。MPS 仍走 GPU，只是纯 fp32，不玩半精度）
    use_amp = use_amp and device != "cpu"
    if device == "mps":
        use_amp = False
    scaler = torch.amp.GradScaler(device=device) if use_amp else None

    # 总步数 = epoch × 每 epoch 步数 / grad_accum
    steps_per_epoch = max(1, len(train_loader) // grad_accum)
    total_steps = epochs * steps_per_epoch
    scheduler = CosineWithWarmup(
        optimizer, warmup_steps=max(1, steps_per_epoch),
        total_steps=total_steps, base_lr=lr, min_lr=lr * 0.01)

    # 4. 训练状态
    ckpt_dir = Path(checkpoint_dir) if checkpoint_dir else _ROOT / "checkpoints" / "m9_mono"
    ckpt_dir.mkdir(parents=True, exist_ok=True)
    best_val_loss = float("inf")
    train_history, val_history = [], []

    # 5. 训练循环
    for epoch in range(epochs):
        ep_t0 = time.time()
        model.train()
        optimizer.zero_grad()
        ep_loss = ep_steer = ep_thr = ep_br = 0.0
        n_b = 0
        accum_count = 0

        for bi, batch in enumerate(train_loader):
            img = batch["image"].to(device, non_blocking=pin)
            vs = batch["vehicle_state"].to(device, non_blocking=pin)
            gt_s = batch["steer"].to(device, non_blocking=pin)
            gt_t = batch["throttle"].to(device, non_blocking=pin)
            gt_b = batch["brake"].to(device, non_blocking=pin)

            with torch.amp.autocast(device_type=device, enabled=use_amp):
                pred_s, pred_t, pred_b = model(img, vs)
                loss, comps = loss_fn(pred_s, pred_t, pred_b, gt_s, gt_t, gt_b)
                loss = loss / grad_accum

            if scaler is not None:
                scaler.scale(loss).backward()
            else:
                loss.backward()
            accum_count += 1

            if accum_count >= grad_accum:
                if scaler is not None:
                    scaler.unscale_(optimizer)
                torch.nn.utils.clip_grad_norm_(
                    model.parameters(), max_norm=TRAIN_GRAD_CLIP_NORM)
                if scaler is not None:
                    scaler.step(optimizer)
                    scaler.update()
                else:
                    optimizer.step()
                optimizer.zero_grad()
                scheduler.step()
                accum_count = 0

            ep_loss += comps["total"]
            ep_steer += comps["steer"]
            ep_thr += comps["throttle"]
            ep_br += comps["brake"]
            n_b += 1

            if act_streamer is not None:
                act_streamer.step(epoch, bi, comps["total"], optimizer.param_groups[0]["lr"])

        # 处理尾部不完整累积
        if accum_count > 0:
            if scaler is not None:
                scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(
                model.parameters(), max_norm=TRAIN_GRAD_CLIP_NORM)
            if scaler is not None:
                scaler.step(optimizer)
                scaler.update()
            else:
                optimizer.step()
            optimizer.zero_grad()

        train_metrics = {
            "epoch": epoch,
            "loss": ep_loss / max(n_b, 1),
            "steer_loss": ep_steer / max(n_b, 1),
            "throttle_loss": ep_thr / max(n_b, 1),
            "brake_loss": ep_br / max(n_b, 1),
        }
        train_history.append(train_metrics)

        # 6. 验证
        val_metrics = _validate_mono(model, val_loader, loss_fn, device, use_amp)
        val_history.append(val_metrics)
        val_loss = val_metrics["loss"]

        # MPS 显存保活：每 epoch 清理一次，缓解碎片导致的 OOM
        if device == "mps":
            torch.mps.empty_cache()

        ep_dt = time.time() - ep_t0
        print(f"Epoch {epoch:3d}/{epochs} | {ep_dt:5.1f}s | "
              f"train_loss={train_metrics['loss']:.4f} "
              f"(steer={train_metrics['steer_loss']:.4f}) | "
              f"val_loss={val_loss:.4f} "
              f"(steer={val_metrics['steer_loss']:.4f}) | "
              f"lr={optimizer.param_groups[0]['lr']:.2e}")

        # 7. 保存 best_model
        is_best = val_loss < best_val_loss
        if is_best:
            best_val_loss = val_loss
            best_path = ckpt_dir / "best_model.pt"
            torch.save({
                "epoch": epoch,
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "best_val_loss": best_val_loss,
                "image_size": list(image_size),
            }, best_path)
            print(f"  ★ 新最佳 val_loss={best_val_loss:.4f} → {best_path}")

        # 每 10 epoch 存一个 checkpoint
        if (epoch + 1) % 10 == 0:
            ck_path = ckpt_dir / f"checkpoint_epoch_{epoch:03d}.pt"
            torch.save({
                "epoch": epoch,
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "best_val_loss": best_val_loss,
                "image_size": list(image_size),
            }, ck_path)

    # 8. 保存训练日志
    log_path = ckpt_dir / "training_log.json"
    with open(log_path, "w") as f:
        json.dump({
            "train_history": train_history,
            "val_history": val_history,
            "best_val_loss": best_val_loss,
            "epochs": epochs,
            "image_size": list(image_size),
        }, f, indent=2)
    print(f"\n✓ 训练完成 | best_val_loss={best_val_loss:.4f} | 日志: {log_path}")
    if act_streamer is not None:
        act_streamer.close()
    return ckpt_dir / "best_model.pt"


@torch.no_grad()
def _validate_mono(model, loader, loss_fn, device, use_amp) -> Dict[str, float]:
    """验证集评估。"""
    model.eval()
    total = steer = thr = br = 0.0
    n = 0
    for batch in loader:
        img = batch["image"].to(device)
        vs = batch["vehicle_state"].to(device)
        gt_s = batch["steer"].to(device)
        gt_t = batch["throttle"].to(device)
        gt_b = batch["brake"].to(device)
        with torch.amp.autocast(device_type=device, enabled=use_amp):
            pred_s, pred_t, pred_b = model(img, vs)
            _, comps = loss_fn(pred_s, pred_t, pred_b, gt_s, gt_t, gt_b)
        total += comps["total"]
        steer += comps["steer"]
        thr += comps["throttle"]
        br += comps["brake"]
        n += 1
    return {
        "loss": total / max(n, 1),
        "steer_loss": steer / max(n, 1),
        "throttle_loss": thr / max(n, 1),
        "brake_loss": br / max(n, 1),
    }


# ==================== PyTorch → CoreML 转换 ====================

def convert_torch_to_coreml(state_dict_path: Path, mlmodelc_path: Path,
                            img_h: int = 180, img_w: int = 320) -> Path:
    """将 M9-Mono PyTorch 模型转换为 CoreML .mlmodelc 部署格式。

    流程：
      1. 构建训练态模型 + 加载 state_dict + reparameterize（融合成部署态）
      2. torch.jit.trace 固化输入 shape
      3. coremltools source="pytorch" → CoreML NeuralNetwork
      4. 保存 .mlmodel 源文件
      5. xcrun coremlcompiler 编译为 .mlmodelc 目录

    输入：
      image:         [1, 3, H, W]  float32 (0-1 归一化)
      vehicle_state: [1, 6]        float32
    输出：
      steer/throttle/brake: [1, 1]
    """
    import coremltools as ct
    import shutil
    import subprocess

    print(f"[CoreML] 转换 PyTorch → CoreML: {state_dict_path}")

    # 1. 构建训练态模型 + 加载权重 + reparameterize（融合成部署态）
    # P0-4 修复：原 deploy=True 时 rbr_reparam 是随机初始化，训练 checkpoint 是训练态键
    # （rbr_3x3/rbr_1x1/rbr_identity + BN），strict=False 会静默忽略 → 导出随机权重模型。
    # 正确流程：训练态构建 → 加载训练 checkpoint → reparameterize 融合成部署态。
    model = build_m9_mono(deploy=False)
    ckpt = torch.load(state_dict_path, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) \
        and "model_state_dict" in ckpt else ckpt
    # 剥离 torch.compile 包装前缀
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v
          for k, v in sd.items()}
    model.load_state_dict(sd, strict=False)
    model.reparameterize()   # RepVGG 训练态 → 部署态融合（缺这步 = 随机权重）
    model.eval()

    # 2. jit.trace 固化（避免动态 shape 引发 MIL 转换错误）
    dummy_img = torch.zeros(1, 3, img_h, img_w)
    dummy_vs = torch.zeros(1, 6)
    with torch.no_grad():
        traced = torch.jit.trace(model, (dummy_img, dummy_vs))
    print("[CoreML] ✓ jit.trace 成功")

    # 3. 转 CoreML（ML Program 格式，macOS12+ 要求）
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS12,
        inputs=[
            ct.TensorType(name="image", shape=(1, 3, img_h, img_w)),
            ct.TensorType(name="vehicle_state", shape=(1, 6)),
        ],
        outputs=[
            ct.TensorType(name="steer"),
            ct.TensorType(name="throttle"),
            ct.TensorType(name="brake"),
        ],
        skip_model_load=False,
    )
    print("[CoreML] ✓ PyTorch → CoreML 转换完成（ML Program 格式）")

    # 4. 元数据
    spec = mlmodel.get_spec()
    spec.description.metadata.shortDescription = "AuroraDrive M9-Mono 单目端到端驾驶模型"
    spec.description.metadata.author = "AuroraDrive"
    spec.description.metadata.versionString = "1.0"

    # 5. 保存 .mlpackage 源文件（ML Program 格式要求）
    mlpackage_path = mlmodelc_path.with_suffix(".mlpackage")
    if mlpackage_path.exists():
        shutil.rmtree(mlpackage_path)
    mlmodel.save(str(mlpackage_path))
    print(f"[CoreML] ✓ 源模型: {mlpackage_path}")

    # 6. 编译 .mlpackage → .mlmodelc（目录，运行时直接加载）
    # 优先用 xcrun coremlcompiler（需 Xcode）；不可用时退到 ct.utils.compile_model
    if mlmodelc_path.exists():
        shutil.rmtree(mlmodelc_path)
    mlmodelc_path.parent.mkdir(parents=True, exist_ok=True)

    import subprocess
    cmd = ["xcrun", "coremlcompiler", "compile",
           str(mlpackage_path), str(mlmodelc_path.parent)]
    print(f"[CoreML] 尝试编译: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        print(f"[CoreML] ✓ 编译模型 (xcrun): {mlmodelc_path}")
    else:
        # 退到 coremltools 内置编译器（不依赖 Xcode）
        print(f"[CoreML] xcrun 失败（{result.stderr.strip()[:80]}），退到 ct.utils.compile_model")
        try:
            compiled_url = ct.utils.compile_model(str(mlpackage_path))
            # compile_model 返回 .mlmodelc 路径（在同目录下）
            compiled_path = Path(compiled_url.path
                                  if hasattr(compiled_url, 'path') else str(compiled_url))
            if compiled_path != mlmodelc_path:
                if mlmodelc_path.exists():
                    shutil.rmtree(mlmodelc_path)
                shutil.move(str(compiled_path), str(mlmodelc_path))
            print(f"[CoreML] ✓ 编译模型 (ct.utils): {mlmodelc_path}")
        except Exception as e:
            # raise ... from e 保留原始异常链，便于调试 CoreML 编译失败根因
            raise RuntimeError(
                f"CoreML 编译失败（xcrun 与 ct.utils 均失败）: {e}\n"
                f"可手动保留 .mlpackage 源文件供运行时加载: {mlpackage_path}") from e
    return mlmodelc_path


# ==================== CLI 入口 ====================

def parse_args():
    p = argparse.ArgumentParser(description="M9-Mono 单目模型训练 + 导出")
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch_size", type=int, default=8)
    p.add_argument("--grad_accum", type=int, default=2)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--weight_decay", type=float, default=TRAIN_WEIGHT_DECAY)
    p.add_argument("--val_ratio", type=float, default=0.15)
    p.add_argument("--no_amp", action="store_true")
    p.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"])
    p.add_argument("--clips_dir", default=None)
    p.add_argument("--checkpoint_dir", default=None)
    p.add_argument("--num_workers", type=int, default=0)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--img_h", type=int, default=180)
    p.add_argument("--img_w", type=int, default=320)
    p.add_argument("--skip_train", action="store_true",
                   help="跳过训练，仅做 ONNX + CoreML 导出（需已有 best_model.pt）")
    p.add_argument("--skip_coreml", action="store_true",
                   help="跳过 ONNX → CoreML 转换")
    return p.parse_args()


def main():
    args = parse_args()
    image_size = (args.img_h, args.img_w)
    use_amp = not args.no_amp

    # 1. 训练
    if not args.skip_train:
        best_path = train_mono(
            epochs=args.epochs,
            batch_size=args.batch_size,
            grad_accum=args.grad_accum,
            lr=args.lr,
            weight_decay=args.weight_decay,
            image_size=image_size,
            val_ratio=args.val_ratio,
            use_amp=use_amp,
            device=args.device,
            clips_dir=args.clips_dir,
            checkpoint_dir=args.checkpoint_dir,
            num_workers=args.num_workers,
            seed=args.seed,
        )
    else:
        ckpt_dir = Path(args.checkpoint_dir) if args.checkpoint_dir else _ROOT / "checkpoints" / "m9_mono"
        best_path = ckpt_dir / "best_model.pt"
        if not best_path.exists():
            print(f"[错误] 未找到 best_model.pt: {best_path}")
            sys.exit(1)

    # 2. 导出 ONNX
    onnx_path = MODELS_DIR / "m9_mono.onnx"
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"\n[ONNX] 导出 → {onnx_path}")
    export_onnx_mono(str(best_path), str(onnx_path), img_h=args.img_h, img_w=args.img_w)

    # 3. 转 CoreML（直接从 PyTorch，coremltools 9.0 不支持 ONNX 输入）
    if not args.skip_coreml:
        mlmodelc_path = MODELS_DIR / "m9_mono.mlmodelc"
        try:
            convert_torch_to_coreml(
                best_path, mlmodelc_path, img_h=args.img_h, img_w=args.img_w)
            print(f"\n✅ CoreML 模型已生成: {mlmodelc_path}")
        except Exception as e:
            print(f"\n⚠ CoreML 转换失败: {type(e).__name__}: {e}")
            print("  ONNX 模型仍可用（C++ 推理引擎 fallback）")
            import traceback
            traceback.print_exc()

    print(f"\n{'='*60}\n✅ M9-Mono 训练 + 导出全部完成\n{'='*60}")


if __name__ == "__main__":
    main()
