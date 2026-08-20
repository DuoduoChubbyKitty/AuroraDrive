# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
训练入口 — 命令行参数解析 + DAgger 四阶段训练流程编排

用法:
    python -m src.train --stage all          # 完整四阶段
    python -m src.train --stage 1            # 仅阶段1: 行为克隆预热
    python -m src.train --stage 2 --resume checkpoints/best_model.pt
    python -m src.train --stage 3
    python -m src.train --stage 4 --lr 1e-5 --epochs 10

四阶段:
    阶段1: 行为克隆预热 (50K帧, 2D渲染, 112×112)
    阶段2: DAgger 在线采集 (20K帧, 2D渲染)
    阶段3: 偏离恢复专项训练 (20K帧, 2D渲染, 224×224)
    阶段4: 3D域适应微调 (8-15K帧, SceneKit正3D渲染, 冻结骨干)
"""

import argparse
import sys
import os
from pathlib import Path

# 项目根路径
_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT))

import torch

from src.config import (
    DATA_DIR,
    TRAIN_BATCH_SIZE, TRAIN_GRADIENT_ACCUM,
    TRAIN_EPOCHS_2D, TRAIN_EPOCHS_3D,
    TRAIN_LR_2D, TRAIN_LR_3D,
    MODEL_REPVGG_PRETRAINED, MODEL_CHECKPOINT_DIR,
    TRAIN_TOTAL_FRAMES_2D,
)
from src.model import build_m9, load_pretrained_repvgg, get_model_stats
from src.trainer import Trainer
from src.data_generator import DataGenerator, HDF5Dataset


class TrainPipeline:
    """
    训练流程编排器
    负责数据生成 → 模型构建 → 训练循环 → 导出
    """

    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.stage = args.stage
        self.epochs = args.epochs
        self.batch_size = args.batch_size
        self.lr = args.lr
        self.resume = args.resume
        self.use_amp = args.use_amp
        self.grad_accum = args.grad_accum
        self.dry_run = args.dry_run

        # 设备选择
        if args.device == "auto":
            if torch.cuda.is_available():
                self.device = "cuda"
            elif torch.backends.mps.is_available():
                self.device = "mps"
            else:
                self.device = "cpu"
        else:
            self.device = args.device

        # 数据路径
        self.data_dir = DATA_DIR / "training_samples"
        self.checkpoint_dir = Path(args.checkpoint_dir) if args.checkpoint_dir else MODEL_CHECKPOINT_DIR
        self.checkpoint_dir.mkdir(parents=True, exist_ok=True)

    def run(self):
        """执行训练流程"""
        self._print_header()

        if self.dry_run:
            print("[Train] 干跑模式，不执行训练")
            self._print_config()
            return

        # ---- 阶段 0: 数据生成（如需要）----
        if self.args.generate_data:
            self._generate_training_data()

        # ---- 阶段 1-3: 2D 训练 ----
        if self.stage in ("all", 1, 2, 3):
            self._train_2d()

        # ---- 阶段 4: 3D 微调 ----
        if self.stage in ("all", 4):
            self._train_3d_finetune()

        print("\n" + "=" * 60)
        print("[Train] 全部训练完成!")
        print("=" * 60)

    def _print_header(self):
        print("=" * 60)
        print("轻量级端到端自动驾驶模拟系统 — M9 训练")
        print(f"平台: Apple M3 Mac / macOS")
        print(f"设备: {self.device}")
        print(f"阶段: {self.stage}")
        print("=" * 60)

    def _print_config(self):
        print(f"  Epochs: {self.epochs}")
        print(f"  Batch: {self.batch_size} × {self.grad_accum} = {self.batch_size * self.grad_accum}")
        print(f"  LR: {self.lr}")
        print(f"  AMP: {self.use_amp}")
        print(f"  Checkpoint: {self.checkpoint_dir}")

    def _generate_training_data(self):
        """生成 DAgger 训练数据"""
        print("\n[数据生成] 开始 DAgger 三阶段数据生成...")

        gen = DataGenerator(
            output_dir=self.data_dir,
            seed=self.args.seed,
        )

        # 阶段1数据
        gen.generate_stage1(
            target_frames=TRAIN_TOTAL_FRAMES_2D // 2,  # 简化：实际50K
        )

        # 阶段3数据（阶段2需要模型，跳过或使用简单模式）
        gen.generate_stage3(
            target_frames=TRAIN_TOTAL_FRAMES_2D // 4,  # 简化
        )

        print(f"[数据生成] 完成: {gen.get_stats()}")
        print(f"[数据生成] 数据目录: {self.data_dir}")

    def _train_2d(self):
        """2D 预训练阶段"""
        print(f"\n{'='*60}")
        print("[2D 训练] 构建模型 + 加载数据 + 训练")
        print(f"{'='*60}")

        # 构建模型
        model = build_m9(deploy=False)

        # 加载预训练权重
        if self.args.pretrained and MODEL_REPVGG_PRETRAINED.exists():
            load_pretrained_repvgg(model, str(MODEL_REPVGG_PRETRAINED))
        elif self.args.pretrained:
            print(f"[警告] 预训练权重不存在: {MODEL_REPVGG_PRETRAINED}")

        print(get_model_stats(model))

        # 加载数据
        data_dirs = [str(self.data_dir / d) for d in ["stage1_bc", "stage2_dagger", "stage3_recovery"]
                     if (self.data_dir / d).exists()]
        if not data_dirs:
            print(f"[错误] 未找到训练数据，请先运行 --generate_data")
            print(f"  期望路径: {self.data_dir}/stage1_bc/*.h5")
            return

        dataset = HDF5Dataset(data_dirs, augment=True)
        print(f"数据集: {len(dataset)} 样本, 来源: {data_dirs}")

        # 创建训练器
        trainer = Trainer(
            model=model,
            device=self.device,
            checkpoint_dir=self.checkpoint_dir,
            use_amp=self.args.use_amp,
        )

        # 恢复训练
        resume_path = self.resume
        if resume_path and os.path.exists(resume_path):
            print("从 checkpoint 恢复训练")
        else:
            resume_path = None  # 不存在则不传，避免 train_2d 内 torch.load 崩

        # 训练
        epochs = self.epochs if self.epochs else TRAIN_EPOCHS_2D
        trainer.train_2d(
            train_dataset=dataset,
            epochs=epochs,
            batch_size=self.batch_size,
            grad_accum=self.grad_accum,
            resume_from=resume_path,
        )

        # 最终化
        trainer.finalize()
        trainer.save_training_log()

    def _train_3d_finetune(self):
        """3D 域适应微调阶段"""
        print(f"\n{'='*60}")
        print("[3D 微调] 冻结骨干 + 微调融合头")
        print(f"{'='*60}")

        # 加载 2D 训练后的模型
        best_path = self.checkpoint_dir / "best_model.pt"
        if not best_path.exists():
            print(f"[错误] 未找到 2D 训练最佳模型: {best_path}")
            print("  请先完成 2D 训练阶段")
            return

        model = build_m9(deploy=False)
        # 先落到 cpu，再由 Trainer 内部 .to(self.device) 安全搬运，避免 MPS/CUDA 上的设备不匹配
        checkpoint = torch.load(best_path, map_location="cpu", weights_only=False)
        model.load_state_dict(checkpoint["model_state_dict"])
        print(f"已加载 2D 训练模型: {best_path}")

        # 加载 3D 数据
        data_dir_3d = self.data_dir / "stage4_3d"
        if not data_dir_3d.exists():
            print(f"[警告] 3D 数据目录不存在: {data_dir_3d}")
            print("  3D 微调需要 SceneKit 渲染数据，跳过此阶段")
            return

        dataset = HDF5Dataset([str(data_dir_3d)], augment=False)
        print(f"3D 数据集: {len(dataset)} 样本")

        # 训练器
        trainer = Trainer(
            model=model,
            device=self.device,
            checkpoint_dir=self.checkpoint_dir,
            use_amp=self.args.use_amp,
        )

        epochs = self.epochs if self.epochs else TRAIN_EPOCHS_3D
        lr = self.lr if self.lr else TRAIN_LR_3D
        trainer.train_3d_finetune(
            train_dataset=dataset,
            epochs=epochs,
            batch_size=self.batch_size,
            lr=lr,
        )

        trainer.finalize()


def parse_args():
    """解析命令行参数"""
    parser = argparse.ArgumentParser(
        description="轻量级端到端自动驾驶模拟系统 — M9 训练入口",
    )

    parser.add_argument("--config", type=str, default=None,
                        help="训练配置文件路径 (YAML, 可选)")
    parser.add_argument("--stage", default="all",
                        help="训练阶段: all|1|2|3|4 (默认 all)")
    parser.add_argument("--epochs", type=int, default=None,
                        help="Epoch 数 (覆盖默认值)")
    parser.add_argument("--batch_size", type=int, default=TRAIN_BATCH_SIZE,
                        help=f"Batch size (默认 {TRAIN_BATCH_SIZE})")
    parser.add_argument("--lr", type=float, default=None,
                        help="学习率 (覆盖默认值)")
    parser.add_argument("--resume", type=str, default=None,
                        help="从 checkpoint 恢复训练")
    parser.add_argument("--device", type=str, default="auto",
                        choices=["auto", "cpu", "cuda", "mps"],
                        help="计算设备 (默认 auto)")
    parser.add_argument("--grad_accum", type=int, default=TRAIN_GRADIENT_ACCUM,
                        help=f"梯度累积步数 (默认 {TRAIN_GRADIENT_ACCUM})")
    parser.add_argument("--use_amp", action="store_true", default=None,
                        help="启用 AMP 混合精度 (默认按设备自动: CPU 关闭, GPU/MPS 开启)")
    parser.add_argument("--no_amp", action="store_true",
                        help="禁用 AMP")
    parser.add_argument("--pretrained", action="store_true",
                        help="加载 RepVGG ImageNet 预训练权重")
    parser.add_argument("--generate_data", action="store_true",
                        help="训练前先生成 DAgger 训练数据")
    parser.add_argument("--checkpoint_dir", type=str, default=None,
                        help="Checkpoint 保存目录")
    parser.add_argument("--seed", type=int, default=42,
                        help="随机种子")
    parser.add_argument("--dry_run", action="store_true",
                        help="干跑模式 (只打印配置)")

    args = parser.parse_args()

    # 类型转换
    try:
        args.stage = int(args.stage)
    except (ValueError, TypeError):
        pass  # 保持 "all"

    # 默认值
    if args.epochs is None:
        args.epochs = TRAIN_EPOCHS_3D if args.stage == 4 else TRAIN_EPOCHS_2D
    if args.lr is None:
        args.lr = TRAIN_LR_3D if args.stage == 4 else TRAIN_LR_2D
    if args.no_amp:
        args.use_amp = False

    return args


def main():
    args = parse_args()
    pipeline = TrainPipeline(args)
    pipeline.run()


if __name__ == "__main__":
    main()
