#!/usr/bin/env python3
"""
用 AuroraRecorder 录制的剪辑训练 M9Model（行为克隆）。

不重新生成专家帧，直接吃 build_hdf5.py 产出的 HDF5：
  data/training_samples/aurora_rec_20260721.h5

流程照搬 train_route.py 的训练段：M9Model + Trainer.train_2d，
MPS 优化环境变量照设。点云/车辆状态在录制数据里是零（见 build_hdf5.py），
模型只能从画面学，避免走捷径。

用法:
  python3.11 tools/train_recording.py
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import torch

# MPS 优化（来自 train_route.py）
os.environ["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] = "0.0"
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
torch.set_float32_matmul_precision('medium')

from src.data_generator import HDF5Dataset
from src.model import M9Model
from src.trainer import Trainer

H5 = "data/training_samples/aurora_rec_20260721.h5"
CKPT = "models/aurora_rec_ckpt"


def main():
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"设备: {device}")

    dataset = HDF5Dataset([H5], augment=False, seed=42)
    print(f"数据集: {len(dataset)} 样本")

    model = M9Model()
    trainer = Trainer(model=model, device=device, checkpoint_dir=CKPT)

    trainer.train_2d(
        train_dataset=dataset,
        epochs=20,
        batch_size=16,
        grad_accum=1,
        val_split=0.1,
        validate_every=2,
        save_every=5,
        resolution_switch_epoch=15,
    )

    trainer.finalize()  # reparameterize + 导出 m9_deploy.pth
    print("\n✅ 训练完成 ->", CKPT)


if __name__ == "__main__":
    main()
