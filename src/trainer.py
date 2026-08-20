# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
训练循环 — DAgger 三阶段 + AMP + 梯度累积

训练策略（针对 M3 16GB 统一内存优化）：

2D 预训练阶段（80 epochs）：
  - Epoch 1-50：分辨率 112×112，内存 ~6GB
  - Epoch 51-80：分辨率 224×224，内存 ~12GB
  - AMP FP16 混合精度
  - 梯度累积 4 步 → 有效 batch=16

3D 微调阶段（10 epochs，可选）：
  - 冻结 RepVGG 骨干 + PointNet-Lite
  - 只训练融合头最后 2 层
  - 分辨率 224×224，lr=1e-5

关键特性：
  - Cosine Annealing + 5 epoch Warmup
  - AdamW 优化器
  - 损失权重：转向 1.0 : 油门 0.5 : 刹车 0.5
  - 梯度裁剪 max_norm=1.0
  - 验证集每 5 epoch 评估
  - Checkpoint 每 10 epoch 保存
  - 训练完成自动 reparameterize + 导出
"""

import gc
import time
import json
import math
import torch
from torch.utils.data import DataLoader, random_split
from pathlib import Path
from typing import Optional, Dict, Tuple, List
import numpy as np
from tqdm import tqdm

from src.config import (
    ROOT_DIR,
    TRAIN_BATCH_SIZE, TRAIN_GRADIENT_ACCUM,
    TRAIN_EPOCHS_2D, TRAIN_EPOCHS_3D,
    TRAIN_LR_2D, TRAIN_LR_3D,
    TRAIN_WARMUP_EPOCHS, TRAIN_WEIGHT_DECAY, TRAIN_GRAD_CLIP_NORM,
    TRAIN_RESOLUTION_LOW, TRAIN_RESOLUTION_HIGH,
    LOSS_WEIGHTS,
    MODEL_CHECKPOINT_DIR,
)
from src.model import M9Model, M9Loss, build_m9, get_model_stats, export_for_deployment
from src.data_generator import HDF5Dataset


# ==================== 学习率调度器 ====================

class WarmupCosineScheduler:
    """
    Warmup + Cosine Annealing 学习率调度
    """

    def __init__(
        self,
        optimizer: torch.optim.Optimizer,
        warmup_epochs: int = 5,
        total_epochs: int = 80,
        base_lr: float = 3e-4,
        min_lr: float = 1e-6,
    ):
        self.optimizer = optimizer
        self.warmup_epochs = warmup_epochs
        self.total_epochs = total_epochs
        self.base_lr = base_lr
        self.min_lr = min_lr
        self.current_epoch = 0

    def step(self, epoch: int = None):
        """更新学习率"""
        if epoch is not None:
            self.current_epoch = epoch
        else:
            self.current_epoch += 1

        lr = self._get_lr(self.current_epoch)
        for param_group in self.optimizer.param_groups:
            param_group["lr"] = lr

    def _get_lr(self, epoch: int) -> float:
        """计算当前 epoch 的学习率"""
        if epoch < self.warmup_epochs:
            # 线性 warmup
            return self.base_lr * (epoch + 1) / self.warmup_epochs
        else:
            # Cosine annealing（denom 防 0，progress 钳制到 [0,1]）
            cosine_epochs = max(self.total_epochs - self.warmup_epochs, 1)
            progress = min(max((epoch - self.warmup_epochs) / cosine_epochs, 0.0), 1.0)
            cosine = 0.5 * (1.0 + math.cos(math.pi * progress))
            return self.min_lr + (self.base_lr - self.min_lr) * cosine

    def get_last_lr(self) -> float:
        return self._get_lr(self.current_epoch)


# ==================== EMA 权重平滑（防过拟合 S6） ====================

class EMA:
    """指数移动平均：验证时套用平滑权重，best 模型保存 EMA 权重，降低选点方差。"""

    def __init__(self, model, decay: float = 0.999):
        self.decay = decay
        self.shadow = {k: v.detach().clone().float()
                       for k, v in model.state_dict().items()
                       if v.dtype.is_floating_point}
        self._backup = None

    @torch.no_grad()
    def update(self, model):
        for k, v in model.state_dict().items():
            if k in self.shadow:
                self.shadow[k].mul_(self.decay).add_(v.detach().float(), alpha=1 - self.decay)

    def apply(self, model):
        """验证/保存前套用 EMA 权重（先备份原权重）"""
        self._backup = {k: v.detach().clone()
                        for k, v in model.state_dict().items()
                        if k in self.shadow}
        _state_model = getattr(model, '_orig_mod', model)
        _state_model.load_state_dict({**model.state_dict(), **self.shadow}, strict=False)

    def restore(self, model):
        """验证后恢复原权重"""
        if self._backup is not None:
            _state_model = getattr(model, '_orig_mod', model)
            _state_model.load_state_dict({**model.state_dict(), **self._backup}, strict=False)
            self._backup = None


# ==================== 优化器构建（param group：BN/bias 不加 WD，防过拟合 S1） ====================

def build_adamw_optimizer(model, lr: float, weight_decay: float):
    """分离 decay/no_decay 参数组：1D 参数（BN γ/β、bias）不加 weight decay。"""
    decay, no_decay = [], []
    for n, p in model.named_parameters():
        if not p.requires_grad:
            continue
        # 1D 参数（bias、BN/LN 的 γ/β）+ 显式 bn 标记 → 不衰减
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


# ==================== 训练器 ====================

class Trainer:
    """
    M9 模型训练器（AMP + 梯度累积）
    """

    def __init__(
        self,
        model: M9Model,
        device: str = "cpu",
        optimizer: Optional[torch.optim.Optimizer] = None,
        loss_fn: Optional[M9Loss] = None,
        checkpoint_dir: Optional[Path] = None,
        log_dir: Optional[Path] = None,
        use_amp: Optional[bool] = None,
        ema_decay: float = 0.999,
        early_stop_patience: int = 8,
        max_checkpoints: int = 3,
    ):
        self.model = model
        self.device = device

        # 优化器：param group 分离（BN/bias 不加 WD，防过拟合 S1）
        # 外部传入 optimizer 时原样使用（向后兼容）；否则用 build_adamw_optimizer
        self.optimizer = optimizer or build_adamw_optimizer(
            model, lr=TRAIN_LR_2D, weight_decay=TRAIN_WEIGHT_DECAY)

        # 损失函数
        self.loss_fn = loss_fn or M9Loss(**LOSS_WEIGHTS)

        # AMP 开关：显式 use_amp 优先，否则按设备推断
        self.use_amp = use_amp if use_amp is not None else (device != "cpu")

        # GradScaler for AMP
        self.scaler = torch.amp.GradScaler(device=self.device if self.use_amp else "cpu")

        # 目录
        self.checkpoint_dir = Path(checkpoint_dir) if checkpoint_dir else MODEL_CHECKPOINT_DIR
        self.checkpoint_dir.mkdir(parents=True, exist_ok=True)

        self.log_dir = Path(log_dir) if log_dir else ROOT_DIR / "logs"
        self.log_dir.mkdir(parents=True, exist_ok=True)

        # 训练状态
        self.current_epoch = 0
        self.global_step = 0
        self.best_val_loss = float("inf")
        self.train_history: List[Dict] = []
        self.val_history: List[Dict] = []

        # 分辨率设置
        self.current_resolution = TRAIN_RESOLUTION_LOW  # (112, 112)

        # 防过拟合：Early Stopping（F1）+ EMA（S6）+ checkpoint 清理（M5）
        self.early_stop_patience = early_stop_patience
        self._no_improve = 0
        self._last_train_loss = float("inf")
        self.ema = EMA(model, decay=ema_decay) if ema_decay > 0 else None
        self.max_checkpoints = max_checkpoints

    def _resize_images(
        self, images: torch.Tensor, target_size: Tuple[int, int],
    ) -> torch.Tensor:
        """
        调整图像分辨率
        images: [B, 10, 3, H, W]
        """
        B, C_count, C, H, W = images.shape
        images_flat = images.reshape(B * C_count, C, H, W)
        images_resized = torch.nn.functional.interpolate(
            images_flat, size=target_size, mode="bilinear", align_corners=False,
        )
        return images_resized.reshape(B, C_count, C, target_size[0], target_size[1])

    def _step_optimizer(self):
        """梯度裁剪 + optimizer step + zero grad + EMA 更新（防过拟合 S6）。

        统一封装两处梯度累积 step 点，消除重复并集中接入 EMA 权重平滑。
        """
        self.scaler.unscale_(self.optimizer)
        torch.nn.utils.clip_grad_norm_(
            self.model.parameters(), max_norm=TRAIN_GRAD_CLIP_NORM)
        self.scaler.step(self.optimizer)
        self.scaler.update()
        self.optimizer.zero_grad()
        self.global_step += 1
        if self.ema is not None:
            self.ema.update(self.model)

    def train_epoch(
        self,
        dataloader: DataLoader,
        epoch: int,
        gradient_accum_steps: int = TRAIN_GRADIENT_ACCUM,
    ) -> Dict[str, float]:
        """
        训练一个 epoch

        返回: {"loss": ..., "steer_loss": ..., "throttle_loss": ..., "brake_loss": ...}
        """
        self.model.train()
        self.model.to(self.device)
        
        # torch.compile 加速（MPS backend）
        if not hasattr(self, '_compiled') and hasattr(torch, 'compile'):
            try:
                self.model = torch.compile(self.model, backend="aot_eager" if self.device == "mps" else "inductor")
                self._compiled = True
            except Exception as e:
                print(f"[警告] torch.compile 失败，继续原生执行: {e}")
                self._compiled = True

        total_loss = 0.0
        total_steer = 0.0
        total_throttle = 0.0
        total_brake = 0.0
        num_batches = 0
        accum_loss = 0.0

        self.optimizer.zero_grad()

        pbar = tqdm(dataloader, desc=f"Epoch {epoch}")
        batch_idx = -1
        for batch_idx, batch in enumerate(pbar):
            # 数据移动到设备
            images = batch["images"].to(self.device)              # [B, 10, 3, H, W]
            point_clouds = batch["point_clouds"].to(self.device)  # [B, 2, N, 3]
            vehicle_state = batch["vehicle_state"].to(self.device)  # [B, 6]
            gt_steer = batch["steer"].to(self.device)             # [B, 1]
            gt_throttle = batch["throttle"].to(self.device)       # [B, 1]
            gt_brake = batch["brake"].to(self.device)            # [B, 1]

            # 调整分辨率
            # 始终对齐到当前分辨率（含 HIGH 阶段 224），避免模型吃到低分辨率原图
            images = self._resize_images(images, self.current_resolution)

            # AMP 前向
            with torch.amp.autocast(device_type=self.device, enabled=self.use_amp):
                pred_steer, pred_throttle, pred_brake = self.model(
                    images, point_clouds, vehicle_state
                )
                loss, components = self.loss_fn(
                    pred_steer, pred_throttle, pred_brake,
                    gt_steer, gt_throttle, gt_brake,
                )

                # 梯度累积缩放
                loss = loss / gradient_accum_steps

            # AMP 反向传播
            self.scaler.scale(loss).backward()

            accum_loss += loss.item() * gradient_accum_steps

            # 梯度累积步骤
            if (batch_idx + 1) % gradient_accum_steps == 0:
                self._step_optimizer()

            # 统计
            total_loss += components["total"]
            total_steer += components["steer"]
            total_throttle += components["throttle"]
            total_brake += components["brake"]
            num_batches += 1

            # 更新进度条
            pbar.set_postfix({
                "loss": f"{accum_loss:.4f}" if (batch_idx + 1) % gradient_accum_steps != 0
                        else f"{components['total']:.4f}",
                "steer": f"{components['steer']:.4f}",
            })

        # 处理最后不完整的梯度累积
        if (batch_idx + 1) % gradient_accum_steps != 0:
            self._step_optimizer()

        metrics = {
            "loss": total_loss / max(num_batches, 1),
            "steer_loss": total_steer / max(num_batches, 1),
            "throttle_loss": total_throttle / max(num_batches, 1),
            "brake_loss": total_brake / max(num_batches, 1),
        }

        self.train_history.append({**metrics, "epoch": epoch})
        return metrics

    @torch.no_grad()
    def validate(self, dataloader: DataLoader) -> Dict[str, float]:
        """
        验证集评估
        """
        self.model.eval()
        self.model.to(self.device)

        total_loss = 0.0
        total_steer = 0.0
        total_throttle = 0.0
        total_brake = 0.0
        num_batches = 0

        pbar = tqdm(dataloader, desc="Validation")
        for batch in pbar:
            images = batch["images"].to(self.device)
            point_clouds = batch["point_clouds"].to(self.device)
            vehicle_state = batch["vehicle_state"].to(self.device)
            gt_steer = batch["steer"].to(self.device)
            gt_throttle = batch["throttle"].to(self.device)
            gt_brake = batch["brake"].to(self.device)

            # 始终对齐到当前分辨率（含 HIGH 阶段 224），避免模型吃到低分辨率原图
            images = self._resize_images(images, self.current_resolution)

            pred_steer, pred_throttle, pred_brake = self.model(
                images, point_clouds, vehicle_state
            )
            _, components = self.loss_fn(
                pred_steer, pred_throttle, pred_brake,
                gt_steer, gt_throttle, gt_brake,
            )

            total_loss += components["total"]
            total_steer += components["steer"]
            total_throttle += components["throttle"]
            total_brake += components["brake"]
            num_batches += 1

            pbar.set_postfix({"loss": f"{components['total']:.4f}"})

        metrics = {
            "loss": total_loss / max(num_batches, 1),
            "steer_loss": total_steer / max(num_batches, 1),
            "throttle_loss": total_throttle / max(num_batches, 1),
            "brake_loss": total_brake / max(num_batches, 1),
        }

        self.val_history.append(metrics)
        return metrics

    def save_checkpoint(self, epoch: int, is_best: bool = False):
        """保存检查点"""
        # 剥离 torch.compile 包装，避免 state_dict 键带 _orig_mod. 前缀导致加载失败
        _state_model = getattr(self.model, '_orig_mod', self.model)
        checkpoint = {
            "epoch": epoch,
            "global_step": self.global_step,
            "model_state_dict": _state_model.state_dict(),
            "optimizer_state_dict": self.optimizer.state_dict(),
            "scaler_state_dict": self.scaler.state_dict(),
            "best_val_loss": self.best_val_loss,
            "train_history": self.train_history,
            "val_history": self.val_history,
            "resolution": self.current_resolution,
        }

        # 常规检查点
        path = self.checkpoint_dir / f"checkpoint_epoch_{epoch:03d}.pt"
        torch.save(checkpoint, path)

        # 最佳模型
        if is_best:
            best_path = self.checkpoint_dir / "best_model.pt"
            torch.save(checkpoint, best_path)

    def load_checkpoint(self, path: str) -> int:
        """加载检查点，返回恢复的 epoch"""
        checkpoint = torch.load(path, map_location=self.device, weights_only=False)
        _state_model = getattr(self.model, '_orig_mod', self.model)
        _state_model.load_state_dict(checkpoint["model_state_dict"])
        self.optimizer.load_state_dict(checkpoint["optimizer_state_dict"])
        self.scaler.load_state_dict(checkpoint["scaler_state_dict"])
        self.global_step = checkpoint.get("global_step", 0)
        self.best_val_loss = checkpoint.get("best_val_loss", float("inf"))
        self.train_history = checkpoint.get("train_history", [])
        self.val_history = checkpoint.get("val_history", [])
        self.current_resolution = checkpoint.get("resolution", TRAIN_RESOLUTION_LOW)
        return checkpoint["epoch"]

    def _cleanup_checkpoints(self):
        """M5：只保留最近 max_checkpoints 个常规检查点（best_model.pt 不参与清理）。"""
        ckpts = sorted(
            self.checkpoint_dir.glob("checkpoint_epoch_*.pt"),
            key=lambda p: p.stat().st_mtime,
        )
        while len(ckpts) > self.max_checkpoints:
            oldest = ckpts.pop(0)
            try:
                oldest.unlink()
            except OSError:
                pass

    # ==================== 共享训练循环 ====================

    def _create_dataloaders(self, dataset, batch_size, val_split=0.1, test_split=0.1,
                            num_workers=0, pin_memory=False):
        """创建 train/val/test DataLoader（3-way split，防过拟合 S5）。

        - train：训练权重
        - val：模型选择 / early stopping（可被间接调参，故单独留 test）
        - test：训练结束后一次性无偏评估
        2D 阶段传 num_workers=4/pin_memory=True。
        """
        n = len(dataset)
        test_size = int(n * test_split)
        val_size = int(n * val_split)
        train_size = n - val_size - test_size
        train_subset, val_subset, test_subset = random_split(
            dataset, [train_size, val_size, test_size],
            generator=torch.Generator().manual_seed(42))
        train_loader = DataLoader(
            train_subset, batch_size=batch_size, shuffle=True,
            num_workers=num_workers, pin_memory=pin_memory,
            drop_last=True, persistent_workers=(num_workers > 0))
        val_loader = DataLoader(
            val_subset, batch_size=batch_size, shuffle=False,
            num_workers=min(2, num_workers), pin_memory=pin_memory,
            persistent_workers=(num_workers > 0))
        test_loader = DataLoader(
            test_subset, batch_size=batch_size, shuffle=False,
            num_workers=min(2, num_workers), pin_memory=pin_memory)
        print(f"训练集: {train_size} | 验证集: {val_size} | 测试集: {test_size}")
        print(f"每 epoch: {len(train_loader)} batches\n")
        return train_loader, val_loader, test_loader

    def _run_training(
        self,
        train_loader, val_loader,
        epochs: int,
        scheduler,
        grad_accum: int = 1,
        validate_every: int = 5,
        save_every: int = 10,
        start_epoch: int = 0,
        pre_epoch_fn=None,
        test_loader: Optional[DataLoader] = None,
    ):
        """共享训练循环。

        防过拟合集成：
        - F1 Early Stopping：val_loss 连续 early_stop_patience 轮不降则停
        - S6 EMA：验证/保存 best 时套用平滑权重，验证后恢复
        - M4 train-val gap 监控：val/train 过大提示过拟合
        - M5 checkpoint 清理：只保留最近 max_checkpoints 个
        - S5 test_loader：训练结束后一次性无偏评估

        pre_epoch_fn(epoch) → Optional[scheduler] 用于分辨率切换等 epoch 前回调。
        """
        stopped = False
        for epoch in range(start_epoch, epochs):
            epoch_t0 = time.time()

            # pre-epoch hook（分辨率切换等，可返回新 scheduler）
            if pre_epoch_fn is not None:
                new_scheduler = pre_epoch_fn(epoch)
                if new_scheduler is not None:
                    scheduler = new_scheduler

            lr = scheduler._get_lr(epoch)
            for pg in self.optimizer.param_groups:
                pg["lr"] = lr

            train_metrics = self.train_epoch(train_loader, epoch, grad_accum)
            self.current_epoch = epoch
            train_loss = train_metrics["loss"]
            self._last_train_loss = train_loss
            print(f"Epoch {epoch:3d}/{epochs} | "
                  f"LR: {lr:.2e} | Loss: {train_loss:.4f} | "
                  f"Time: {time.time() - epoch_t0:.1f}s")

            is_best = False
            if (epoch + 1) % validate_every == 0 or epoch == epochs - 1:
                # 验证时套用 EMA 权重（S6），验证后恢复原权重继续训练
                if self.ema is not None:
                    self.ema.apply(self.model)
                val_metrics = self.validate(val_loader)
                val_loss = val_metrics["loss"]

                # M4：train-val gap 监控（val 远高于 train 提示过拟合）
                gap = val_loss - train_loss
                overfit_ratio = val_loss / max(abs(train_loss), 1e-6)
                print(f"  → Val: Loss={val_loss:.4f} "
                      f"Steer={val_metrics.get('steer_loss', 0):.4f} "
                      f"Throttle={val_metrics.get('throttle_loss', 0):.4f} "
                      f"Brake={val_metrics.get('brake_loss', 0):.4f} "
                      f"| gap(val-train)={gap:+.4f} ratio={overfit_ratio:.2f}")
                if overfit_ratio > 1.5:
                    print("  ⚠ val/train > 1.5，过拟合信号，建议加强正则化或早停")

                if val_loss < self.best_val_loss:
                    self.best_val_loss = val_loss
                    self._no_improve = 0
                    is_best = True
                    print(f"  ★ 新最佳模型! val_loss={self.best_val_loss:.4f}")
                    # best 在 EMA 套用窗口内保存 → 部署用 EMA 权重
                    self.save_checkpoint(epoch, is_best=True)
                else:
                    self._no_improve += 1
                    print(f"  · val_loss 连续 {self._no_improve}/{self.early_stop_patience} 轮未改善")

                # 恢复原权重继续训练（best_model.pt 已落盘 EMA 权重）
                if self.ema is not None:
                    self.ema.restore(self.model)

            if (epoch + 1) % save_every == 0 or epoch == epochs - 1:
                if not is_best:  # 最佳模型已在上面保存
                    self.save_checkpoint(epoch, is_best=False)
                    print(f"  💾 Checkpoint saved (epoch {epoch + 1})")
                self._cleanup_checkpoints()  # M5

            if epoch % 10 == 0:
                gc.collect()

            # F1：Early Stopping（按验证轮次计数）
            if self.early_stop_patience > 0 and self._no_improve >= self.early_stop_patience:
                print(f"\n⏹ Early stopping: val_loss 连续 {self._no_improve} 轮未改善，提前结束训练")
                stopped = True
                break

        # S5：最终 test 无偏评估（套用 EMA）
        if test_loader is not None:
            if self.ema is not None:
                self.ema.apply(self.model)
            test_metrics = self.validate(test_loader)
            if self.ema is not None:
                self.ema.restore(self.model)
            tag = "（early stop）" if stopped else ""
            print(f"\n📈 最终 test 评估{tag}: Loss={test_metrics['loss']:.4f} "
                  f"Steer={test_metrics.get('steer_loss', 0):.4f} "
                  f"Throttle={test_metrics.get('throttle_loss', 0):.4f} "
                  f"Brake={test_metrics.get('brake_loss', 0):.4f}")
            # train/test gap：判断泛化能力
            tgap = test_metrics["loss"] - self._last_train_loss
            print(f"   test-train gap={tgap:+.4f}（越小泛化越好）")

    # ==================== 完整训练流程 ====================

    def train_2d(
        self,
        train_dataset: HDF5Dataset,
        epochs: int = TRAIN_EPOCHS_2D,
        batch_size: int = TRAIN_BATCH_SIZE,
        grad_accum: int = TRAIN_GRADIENT_ACCUM,
        val_split: float = 0.1,
        validate_every: int = 5,
        save_every: int = 10,
        resolution_switch_epoch: int = 50,
        resume_from: Optional[str] = None,
    ):
        """2D 预训练：AMP FP16 + 梯度累积 + 分辨率递进（112→224）"""
        print(f"\n{'='*60}")
        print(f"M9 2D 预训练 | {epochs} epochs | GPU: {self.device}")
        print(f"Batch: {batch_size} × {grad_accum} = {batch_size * grad_accum} (有效)")
        print(f"AMP: {'启用' if self.device != 'cpu' else '禁用(CPU)'}")
        print(f"{'='*60}\n")

        start_epoch = 0
        if resume_from:
            start_epoch = self.load_checkpoint(resume_from) + 1
            print(f"从 checkpoint 恢复: epoch {start_epoch}")

        train_loader, val_loader, test_loader = self._create_dataloaders(
            train_dataset, batch_size, val_split, num_workers=4, pin_memory=True)

        scheduler = WarmupCosineScheduler(
            self.optimizer, warmup_epochs=TRAIN_WARMUP_EPOCHS,
            total_epochs=epochs, base_lr=TRAIN_LR_2D)

        def pre_epoch_fn(epoch):
            # S4：分辨率切换 lr 补偿 — 不重建 optimizer（保留 AdamW 动量），
            # 仅把 base_lr 降到 1/10 + 3 epoch warmup 重新爬升，避免高分辨率梯度尺度震荡
            if epoch >= resolution_switch_epoch and self.current_resolution != TRAIN_RESOLUTION_HIGH:
                self.current_resolution = TRAIN_RESOLUTION_HIGH
                print(f"\n>>> Epoch {epoch}: 分辨率切换至 {self.current_resolution}（lr 降至 1/10 + 3ep warmup）")
                return WarmupCosineScheduler(
                    self.optimizer, warmup_epochs=3,
                    total_epochs=epochs, base_lr=TRAIN_LR_2D * 0.1)

        self._run_training(train_loader, val_loader, epochs, scheduler,
                           grad_accum=grad_accum, validate_every=validate_every,
                           save_every=save_every, start_epoch=start_epoch,
                           pre_epoch_fn=pre_epoch_fn, test_loader=test_loader)

        print(f"\n2D 训练完成! 最佳 val_loss: {self.best_val_loss:.4f}")

    def train_3d_finetune(
        self,
        train_dataset: HDF5Dataset,
        epochs: int = TRAIN_EPOCHS_3D,
        batch_size: int = TRAIN_BATCH_SIZE,
        validate_every: int = 2,
        save_every: int = 5,
        lr: float = TRAIN_LR_3D,
    ):
        """3D 域适应微调：冻结骨干+fc1，只训练 fc2/fc3+输出头。lr 默认 1e-5，224×224"""
        print(f"\n{'='*60}")
        print(f"M9 3D 微调 | {epochs} epochs | lr={lr}")
        print(f"{'='*60}\n")

        self.current_resolution = TRAIN_RESOLUTION_HIGH

        # 冻结骨干
        print("冻结 RepVGG-A0 和 PointNet-Lite...")
        for param in self.model.repvgg.parameters():
            param.requires_grad = False
        for param in self.model.pointnet.parameters():
            param.requires_grad = False
        print("冻结融合头 fc1，训练 fc2/fc3 + 输出头...")
        for param in self.model.fusion_head.fc1.parameters():
            param.requires_grad = False

        trainable_params = [p for p in self.model.parameters() if p.requires_grad]
        n_trainable = sum(p.numel() for p in trainable_params)
        n_total = sum(p.numel() for p in self.model.parameters())
        print(f"可训练参数: {n_trainable:,} / {n_total:,} ({n_trainable/n_total*100:.1f}%)")

        # S1：3D 微调同样用 param group 分离（BN/bias 不衰减）。
        # build_adamw_optimizer 会自动跳过 requires_grad=False 的冻结参数。
        self.optimizer = build_adamw_optimizer(self.model, lr=lr, weight_decay=TRAIN_WEIGHT_DECAY)

        train_loader, val_loader, test_loader = self._create_dataloaders(
            train_dataset, batch_size, val_split=0.1)

        scheduler = WarmupCosineScheduler(
            self.optimizer, warmup_epochs=0, total_epochs=epochs, base_lr=lr)

        self._run_training(train_loader, val_loader, epochs, scheduler,
                           grad_accum=TRAIN_GRADIENT_ACCUM, validate_every=validate_every,
                           save_every=save_every, test_loader=test_loader)

        print(f"\n3D 微调完成! 最佳 val_loss: {self.best_val_loss:.4f}")

    def finalize(self, export_path: Optional[str] = None):
        """
        训练最终化：reparameterize + 导出
        """
        print(f"\n{'='*60}")
        print("模型最终化")
        print(f"{'='*60}")

        # 结构重参数化（剥离 torch.compile 包装后再重参数化）
        print("执行 RepVGG 结构重参数化...")
        _state_model = getattr(self.model, '_orig_mod', self.model)
        _state_model.reparameterize()

        # 模型统计
        print(get_model_stats(self.model))

        # 导出
        if export_path is None:
            export_path = str(self.checkpoint_dir / "m9_deploy.pth")
        export_for_deployment(self.model, export_path)
        print(f"部署模型导出: {export_path}")

    def save_training_log(self, path: Optional[str] = None):
        """保存训练日志为 JSON"""
        if path is None:
            path = str(self.log_dir / "training_log.json")
        log = {
            "train_history": self.train_history,
            "val_history": self.val_history,
            "best_val_loss": self.best_val_loss,
            "total_epochs": self.current_epoch,
            "global_steps": self.global_step,
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(log, f, indent=2, ensure_ascii=False)
        print(f"训练日志保存: {path}")


# ==================== 主训练入口 ====================

def run_full_training(
    data_dirs: List[str],
    device: str = "cpu",
    use_pretrained: bool = False,
    pretrained_path: Optional[str] = None,
    save_dir: Optional[str] = None,
):
    """
    运行完整训练管线

    1. 加载数据
    2. 构建模型
    3. 2D 预训练（80 epochs）
    4. 3D 微调（可选，10 epochs）
    5. 模型最终化
    """
    print("\n" + "=" * 60)
    print("M9 端到端自动驾驶模型 — 完整训练管线")
    print("=" * 60)

    # 检测设备
    if device == "auto":
        if torch.cuda.is_available():
            device = "cuda"
        elif torch.backends.mps.is_available():
            device = "mps"
        else:
            device = "cpu"
    print(f"设备: {device}")

    # 加载数据
    print(f"\n加载数据: {data_dirs}")
    dataset = HDF5Dataset(data_dirs, augment=True)
    print(f"总样本数: {len(dataset)}")

    # 构建模型
    print("\n构建 M9 模型...")
    model = build_m9(deploy=False)

    if use_pretrained and pretrained_path:
        from src.model import load_pretrained_repvgg
        load_pretrained_repvgg(model, pretrained_path)

    print(get_model_stats(model))

    # 训练器
    trainer = Trainer(model, device=device, checkpoint_dir=save_dir)

    # 2D 预训练
    trainer.train_2d(dataset)

    # 3D 微调（需要 3D 渲染数据）
    # trainer.train_3d_finetune(dataset_3d)

    # 最终化
    trainer.finalize()
    trainer.save_training_log()

    print("\n✅ 训练完成!")
    return model
