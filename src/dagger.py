# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
DAgger 迭代训练框架（防过拟合 F2）

解决行为克隆（BC）的协变量偏移（covariate shift）：
  BC 只在「专家状态分布」上训练；模型部署后一旦偏离专家轨迹，就会进入 OOD 状态，
  而 OOD 状态下模型从未见过正确标签 → 越偏越远（compounding error）。
  DAgger 迭代式收集「模型自身状态分布」下的专家纠正标签，逐步覆盖 OOD 区域。

迭代循环：
  0. BC 预热（stage1 专家数据，Trainer.train_2d）
  1. for i in range(n_iterations):
       a. rollout   ：当前最优模型驾驶，专家在偏差帧标注 → 新 stage2 h5
       b. aggregate ：stage1 + 历次 stage2 合并为统一数据集（HDF5Dataset）
       c. finetune  ：从 best_model.pt（EMA 权重）继续低 lr 微调，Early Stopping 守护

复用：DataGenerator.generate_stage2 / Trainer / HDF5Dataset，零重复实现。
"""

from pathlib import Path
from typing import Optional, List

import torch

from src.config import (
    MODEL_CHECKPOINT_DIR,
    TRAIN_BATCH_SIZE, TRAIN_GRADIENT_ACCUM,
    TRAIN_LR_2D, TRAIN_WEIGHT_DECAY,
    TRAIN_RESOLUTION_HIGH,
)
from src.model import build_m9
from src.trainer import Trainer, WarmupCosineScheduler, build_adamw_optimizer
from src.data_generator import DataGenerator, HDF5Dataset


class DAggerRunner:
    """DAgger 迭代训练编排器。

    用法：
        runner = DAggerRunner(device="mps", roads=roads, traffic_manager=tm, ...)
        runner.run(stage1_dataset, bc_epochs=80)
    """

    def __init__(
        self,
        device: str = "cpu",
        checkpoint_dir: Optional[Path] = None,
        n_iterations: int = 3,
        rollout_frames: int = 20000,
        finetune_epochs: int = 10,
        finetune_lr: float = TRAIN_LR_2D * 0.1,
        finetune_warmup: int = 2,
        early_stop_patience: int = 4,
        correction_interval: int = 10,
        correction_threshold: float = 0.15,
        roads=None, buildings=None, world=None, traffic_manager=None,
        dt: float = 0.1,
    ):
        self.device = device
        self.checkpoint_dir = Path(checkpoint_dir) if checkpoint_dir else MODEL_CHECKPOINT_DIR
        self.checkpoint_dir.mkdir(parents=True, exist_ok=True)

        self.n_iterations = n_iterations
        self.rollout_frames = rollout_frames
        self.finetune_epochs = finetune_epochs
        self.finetune_lr = finetune_lr
        self.finetune_warmup = finetune_warmup
        self.early_stop_patience = early_stop_patience
        self.correction_interval = correction_interval
        self.correction_threshold = correction_threshold

        self.roads = roads
        self.buildings = buildings
        self.world = world
        self.traffic_manager = traffic_manager
        self.dt = dt

        self.generator = DataGenerator()
        self._stage1_dir = self.generator.output_dir / "stage1_bc"
        # 历次 rollout 产出的 stage2 目录（聚合时拼接）
        self.stage2_dirs: List[Path] = []

    # ==================== 模型加载 ====================

    def _load_best_model(self):
        """加载 best_model.pt（含 EMA 平滑权重）作为本轮 rollout/微调起点。"""
        model = build_m9(deploy=False).to(self.device)
        best = self.checkpoint_dir / "best_model.pt"
        if best.exists():
            ckpt = torch.load(best, map_location=self.device, weights_only=False)
            _m = getattr(model, "_orig_mod", model)
            _m.load_state_dict(ckpt["model_state_dict"])
            print(f"[DAgger] 加载 best_model.pt (epoch={ckpt.get('epoch')}, "
                  f"val_loss={ckpt.get('best_val_loss', float('inf')):.4f})")
        else:
            print("[DAgger] 无 checkpoint，使用随机初始化模型")
        return model

    # ==================== BC 预热 ====================

    def bc_pretrain(self, train_dataset: HDF5Dataset, epochs: int = 80):
        """阶段0：行为克隆预热（纯专家数据）。"""
        print(f"\n{'='*60}\nDAgger 阶段0：行为克隆预热 | {epochs} epochs\n{'='*60}")
        model = build_m9(deploy=False).to(self.device)
        trainer = Trainer(model, device=self.device, checkpoint_dir=self.checkpoint_dir)
        trainer.train_2d(train_dataset, epochs=epochs)
        return trainer

    # ==================== 单次 DAgger 迭代 ====================

    def _rollout(self, model, iteration: int) -> Path:
        """rollout：模型驾驶 + 专家纠正标注 → 隔离的 stage2 目录。

        generate_stage2 写死输出到 output_dir/stage2_dagger，故临时切换 output_dir
        到 per-iteration 子目录，避免历次 rollout 互相覆盖。
        """
        orig_output = self.generator.output_dir
        rollout_root = orig_output.parent / f"dagger_rollout_iter{iteration}"
        rollout_root.mkdir(parents=True, exist_ok=True)
        self.generator.output_dir = rollout_root
        try:
            stage2_path = self.generator.generate_stage2(
                target_frames=self.rollout_frames,
                model=model,
                roads=self.roads, buildings=self.buildings,
                world=self.world, traffic_manager=self.traffic_manager,
                dt=self.dt,
                correction_interval=self.correction_interval,
                correction_threshold=self.correction_threshold,
            )
        finally:
            self.generator.output_dir = orig_output
        return Path(stage2_path)

    def _aggregate(self) -> HDF5Dataset:
        """聚合 stage1 + 所有 stage2 目录为统一数据集。"""
        data_dirs = [str(self._stage1_dir)] + [str(d) for d in self.stage2_dirs]
        # 过滤不存在的目录（stage1 可能尚未生成时优雅跳过）
        data_dirs = [d for d in data_dirs if Path(d).exists()]
        combined = HDF5Dataset(data_dirs, augment=True)
        print(f"[DAgger] 聚合 {len(data_dirs)} 个目录, 共 {len(combined)} 样本")
        return combined

    def _finetune(self, model, dataset: HDF5Dataset):
        """增量微调：低 lr + 少 epoch + 不切换分辨率 + Early Stopping。

        直接调 _run_training（绕过 train_2d 的分辨率切换），用 finetune_lr 调度。
        """
        trainer = Trainer(
            model, device=self.device, checkpoint_dir=self.checkpoint_dir,
            ema_decay=0.999, early_stop_patience=self.early_stop_patience,
        )
        # 用 finetune_lr 重建优化器（保留 S1 param group 分离）
        trainer.optimizer = build_adamw_optimizer(
            model, lr=self.finetune_lr, weight_decay=TRAIN_WEIGHT_DECAY)
        trainer.current_resolution = TRAIN_RESOLUTION_HIGH  # 微调阶段固定高分辨率

        train_loader, val_loader, test_loader = trainer._create_dataloaders(
            dataset, TRAIN_BATCH_SIZE, val_split=0.1, num_workers=4, pin_memory=True)

        scheduler = WarmupCosineScheduler(
            trainer.optimizer, warmup_epochs=self.finetune_warmup,
            total_epochs=self.finetune_epochs, base_lr=self.finetune_lr)

        trainer._run_training(
            train_loader, val_loader, self.finetune_epochs, scheduler,
            grad_accum=TRAIN_GRADIENT_ACCUM, validate_every=2, save_every=5,
            test_loader=test_loader)

    def run_iteration(self, iteration: int):
        """单次 DAgger 迭代：rollout → aggregate → finetune。"""
        print(f"\n{'#'*60}\n# DAgger 迭代 {iteration+1}/{self.n_iterations}\n{'#'*60}")

        # 1. 加载当前最优模型（EMA 权重）
        model = self._load_best_model()

        # 2. rollout：模型驾驶 + 专家纠正标注
        stage2_dir = self._rollout(model, iteration)
        self.stage2_dirs.append(stage2_dir)
        n_corrections = self.generator.stats.get("expert_corrections", 0)
        print(f"[DAgger] 迭代 {iteration} rollout 完成: {self.rollout_frames} 帧, "
              f"专家纠正 {n_corrections} 次 → {stage2_dir}")

        # 3. aggregate：stage1 + 历次 stage2
        combined = self._aggregate()

        # 4. incremental finetune
        self._finetune(model, combined)

    # ==================== 完整流程入口 ====================

    def run(self, stage1_dataset: HDF5Dataset, bc_epochs: int = 80):
        """完整 DAgger 流程：BC 预热 → N 次迭代。

        Args:
            stage1_dataset: 阶段1 专家数据集（需先由 DataGenerator.generate_stage1 生成）
            bc_epochs: BC 预热 epoch 数
        """
        self.bc_pretrain(stage1_dataset, epochs=bc_epochs)
        for i in range(self.n_iterations):
            self.run_iteration(i)
        print(f"\n{'='*60}\n✅ DAgger 完成 | {self.n_iterations} 次迭代\n{'='*60}")
        return self._load_best_model()
