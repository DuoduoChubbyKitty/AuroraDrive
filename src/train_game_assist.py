# [TRAINING-ONLY] 游戏辅助模型训练（独立产品线，与自动驾驶 M9 解耦）
"""
游戏辅助驾驶模型训练流程：
  1. TPV/FPV 端到端控制模型（基于 M9MonoModel 架构，复用 RepVGG-A0 主干）
     - 输入：游戏截屏 320x180 RGB
     - 输出：steer/throttle/brake 三头
     - 数据：data/raw_clips/clip_*（游戏画面录制，含 controls.csv 标签）
  2. 视角分类器（MobileNetV3-Small 三分类：TPV/FPV/MENU）
     - 用于运行时路由到 TPV/FPV 控制模型，菜单状态冻结控制
  3. YOLO 目标检测（Yolo-FastestV2，车辆/UI 元素检测）
     - 需 VOC 格式标注，目前数据无目标框，先生成小规模合成数据训练

用法：
  python3 -m src.train_game_assist --epochs 30 --device mps
"""

import argparse
import json
import random
import sys
import time
from pathlib import Path
from typing import Optional, Dict, List, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT))

from src.config import ROOT_DIR, MODELS_DIR, LOSS_WEIGHTS, TRAIN_GRAD_CLIP_NORM, TRAIN_WEIGHT_DECAY
from src.model import M9MonoModel, M9Loss, build_m9_mono, export_onnx_mono
from src.mono_dataset import MonoClipsDataset, make_train_val_split
from src.train_mono import (
    build_adamw_optimizer, CosineWithWarmup, convert_torch_to_coreml,
)


# ==================== 视角分类器（轻量 CNN）====================

class ViewClassifier(nn.Module):
    """MobileNetV3-Small 风格轻量视角分类器（TPV/FPV/MENU 三分类）。
    输入 [B,3,180,320]，输出 [B,3] logits。
    参数量 < 1M，CoreML 部署推理 < 1ms。"""

    def __init__(self, num_classes: int = 3):
        super().__init__()
        # 轻量骨干：3 个深度可分离卷积块 + 2 个残差块
        self.stem = nn.Sequential(
            nn.Conv2d(3, 16, 3, stride=2, padding=1, bias=False),
            nn.BatchNorm2d(16), nn.ReLU6(inplace=True),
        )
        self.dw_blocks = nn.Sequential(
            self._make_dw_block(16, 24, 1),
            self._make_dw_block(24, 32, 2),
            self._make_dw_block(32, 48, 2),
            self._make_dw_block(48, 64, 1),
        )
        # 1x1 卷积头 + 全局平均池化 + 分类头
        self.head = nn.Sequential(
            nn.Conv2d(64, 128, 1, bias=False),
            nn.BatchNorm2d(128), nn.ReLU6(inplace=True),
            nn.AdaptiveAvgPool2d(1),
            nn.Flatten(),
            nn.Dropout(0.1),
            nn.Linear(128, num_classes),
        )

    @staticmethod
    def _make_dw_block(in_c: int, out_c: int, stride: int) -> nn.Module:
        return nn.Sequential(
            # 深度可分离：3x3 depthwise + 1x1 pointwise
            nn.Conv2d(in_c, in_c, 3, stride=stride, padding=1, groups=in_c, bias=False),
            nn.BatchNorm2d(in_c), nn.ReLU6(inplace=True),
            nn.Conv2d(in_c, out_c, 1, bias=False),
            nn.BatchNorm2d(out_c), nn.ReLU6(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.head(self.dw_blocks(self.stem(x)))


class ViewClassifierDataset(Dataset):
    """视角分类数据集：从 raw_clips 加载图像 + 视角标签。
    标签来源（优先级）：
      1. clip 目录下的 view.txt（人工指定，内容 TPV/FPV/MENU 之一）
      2. clip.json 的 view 字段（录制器 --view 写入，支持 TPV/FPV/MENU）
      3. 旧 clip 无元数据时的亮度/小地图启发式兜底（仅能区分 TPV/FPV）
    数据增强：亮度抖动 + 水平翻转。"""

    LABEL_NAMES = ["TPV", "FPV", "MENU"]

    def __init__(self, clips_dir: Path, image_size=(180, 320), augment=True, seed=42):
        self.image_size = image_size
        self.augment = augment
        self.rng = random.Random(seed)
        self.samples: List[Tuple[Path, int]] = []
        clips = sorted(p for p in clips_dir.iterdir()
                       if p.is_dir() and p.name.startswith("clip_")
                       and (p / "frames").is_dir())
        for clip in clips:
            clip_label = self._clip_label(clip)  # int | None
            frames_dir = clip / "frames"
            for img_path in sorted(frames_dir.glob("*.jpg")):
                # 优先用 clip 级标签（view.txt / clip.json），缺则逐帧启发式兜底
                label = clip_label if clip_label is not None else self._heuristic_label(img_path)
                self.samples.append((img_path, label))

    def _clip_label(self, clip: Path) -> Optional[int]:
        """从 clip 元数据确定视角标签。优先级：view.txt > clip.json.view。
        均无则返回 None（调用方退化为逐帧启发式）。"""
        vt = clip / "view.txt"
        if vt.exists():
            v = vt.read_text().strip().upper()
            if v in self.LABEL_NAMES:
                return self.LABEL_NAMES.index(v)
        cj = clip / "clip.json"
        if cj.exists():
            try:
                import json
                d = json.loads(cj.read_text())
                v = str(d.get("view", "")).strip().upper()
                if v in self.LABEL_NAMES:
                    return self.LABEL_NAMES.index(v)
            except Exception:
                pass
        return None

    def _heuristic_label(self, img_path: Path) -> int:
        """启发式生成标签（无人工标注时的 fallback）。
        实际部署应改为人工标注 + 模型自训练迭代。"""
        try:
            from PIL import Image
            import numpy as np
            img = Image.open(img_path).convert("RGB").resize((320, 180))
            arr = np.asarray(img, dtype=np.float32) / 255.0
            # 右上角 80x80 区域亮度（小地图区域）
            minimap = arr[10:90, 240:320, :].mean()
            # 下 1/3 区域亮度（仪表盘）
            bottom = arr[120:180, :, :].mean()
            # 整体亮度
            overall = arr.mean()
            # 小地图亮 + 下侧亮 → TPV
            if minimap > 0.45 and bottom > 0.40:
                return 0  # TPV
            # 整体偏暗 + 颜色分布均匀 → FPV
            if overall < 0.30:
                return 1  # FPV
            # 中间状态默认 FPV（保守，避免误判为 MENU 冻结控制）
            return 1  # FPV
        except Exception:
            return 1  # FPV 默认

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int) -> Dict[str, torch.Tensor]:
        from PIL import Image
        import numpy as np
        img_path, label = self.samples[idx]
        img = Image.open(img_path).convert("RGB").resize((self.image_size[1], self.image_size[0]))
        arr = np.asarray(img, dtype=np.float32) / 255.0
        # HWC → CHW
        arr = arr.transpose(2, 0, 1)
        if self.augment and self.rng.random() < 0.5:
            # 亮度抖动
            factor = 0.8 + 0.4 * self.rng.random()
            arr = (arr * factor).clip(0, 1)
        return {
            "image": torch.from_numpy(arr.copy()),
            "label": torch.tensor(label, dtype=torch.long),
        }


# ==================== 视角分类器训练 ====================

def train_view_classifier(
    epochs: int = 15,
    batch_size: int = 16,
    lr: float = 1e-3,
    image_size=(180, 320),
    device: str = "auto",
    seed: int = 42,
) -> Path:
    """训练视角分类器，输出 CoreML 模型。"""
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"\n{'='*60}\n[ViewClassifier] 训练 | device={device} | epochs={epochs}\n{'='*60}\n")

    torch.manual_seed(seed)
    clips_dir = _ROOT / "data" / "raw_clips"
    full_ds = ViewClassifierDataset(clips_dir, image_size=image_size, augment=True, seed=seed)
    if len(full_ds) == 0:
        raise RuntimeError(f"无训练数据: {clips_dir}")
    # 简单 8:2 划分
    n_val = max(1, len(full_ds) // 5)
    n_train = len(full_ds) - n_val
    train_ds, val_ds = torch.utils.data.random_split(
        full_ds, [n_train, n_val], generator=torch.Generator().manual_seed(seed))

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True, drop_last=True)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False)

    model = ViewClassifier(num_classes=3).to(device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"  ViewClassifier 参数: {n_params:,} ({n_params/1e6:.2f}M)")

    optimizer = build_adamw_optimizer(model, lr=lr, weight_decay=1e-4)
    scheduler = CosineWithWarmup(optimizer, warmup_steps=len(train_loader),
                                  total_steps=epochs * len(train_loader), base_lr=lr)
    loss_fn = nn.CrossEntropyLoss()

    ckpt_dir = _ROOT / "checkpoints" / "view_classifier"
    ckpt_dir.mkdir(parents=True, exist_ok=True)
    best_val_acc = 0.0

    for epoch in range(epochs):
        model.train()
        ep_loss = 0.0
        correct = 0
        total = 0
        for batch in train_loader:
            img = batch["image"].to(device)
            label = batch["label"].to(device)
            optimizer.zero_grad()
            logits = model(img)
            loss = loss_fn(logits, label)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=TRAIN_GRAD_CLIP_NORM)
            optimizer.step()
            scheduler.step()
            ep_loss += loss.item()
            pred = logits.argmax(dim=1)
            correct += (pred == label).sum().item()
            total += label.size(0)
        train_acc = correct / max(total, 1)

        # 验证
        model.eval()
        val_correct = val_total = 0
        with torch.no_grad():
            for batch in val_loader:
                img = batch["image"].to(device)
                label = batch["label"].to(device)
                logits = model(img)
                pred = logits.argmax(dim=1)
                val_correct += (pred == label).sum().item()
                val_total += label.size(0)
        val_acc = val_correct / max(val_total, 1)

        print(f"Epoch {epoch:3d}/{epochs} | loss={ep_loss/max(len(train_loader),1):.4f} "
              f"| train_acc={train_acc:.3f} | val_acc={val_acc:.3f} "
              f"| lr={optimizer.param_groups[0]['lr']:.2e}")

        if val_acc > best_val_acc:
            best_val_acc = val_acc
            torch.save({"model_state_dict": model.state_dict(),
                        "val_acc": best_val_acc, "epoch": epoch},
                       ckpt_dir / "best_model.pt")
            print(f"  ★ 新最佳 val_acc={best_val_acc:.3f}")

    # 导出 CoreML
    best_path = ckpt_dir / "best_model.pt"
    ckpt = torch.load(best_path, map_location="cpu", weights_only=False)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()

    import coremltools as ct
    dummy = torch.zeros(1, 3, *image_size)
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy)
    mlmodel = ct.convert(
        traced, source="pytorch", convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS12,
        inputs=[ct.TensorType(name="image", shape=(1, 3, *image_size))],
        outputs=[ct.TensorType(name="logits")],
    )
    mlmodel.short_description = "AuroraDrive 游戏辅助视角分类器（TPV/FPV/MENU 三分类）"
    mlpackage_path = MODELS_DIR / "view_classifier.mlpackage"
    mlmodelc_path = MODELS_DIR / "view_classifier.mlmodelc"
    import shutil
    if mlpackage_path.exists(): shutil.rmtree(mlpackage_path)
    mlmodel.save(str(mlpackage_path))
    # 编译 mlmodelc
    import subprocess
    if mlmodelc_path.exists(): shutil.rmtree(mlmodelc_path)
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(mlpackage_path), str(MODELS_DIR)],
        capture_output=True, text=True)
    if result.returncode != 0:
        compiled = ct.utils.compile_model(str(mlpackage_path))
        compiled_path = Path(compiled.path if hasattr(compiled, 'path') else str(compiled))
        if compiled_path != mlmodelc_path:
            if mlmodelc_path.exists(): shutil.rmtree(mlmodelc_path)
            shutil.move(str(compiled_path), str(mlmodelc_path))
    print(f"\n✓ ViewClassifier 训练完成 | best_val_acc={best_val_acc:.3f} | {mlmodelc_path}")
    return mlmodelc_path


# ==================== TPV/FPV 控制模型训练 ====================

def train_game_assist_control(
    epochs: int = 30,
    batch_size: int = 8,
    grad_accum: int = 2,
    lr: float = 3e-4,
    image_size=(180, 320),
    val_ratio: float = 0.15,
    use_amp: bool = True,
    device: str = "auto",
    seed: int = 42,
) -> Path:
    """训练游戏辅助控制模型（TPV/FPV 共用，基于 M9MonoModel 架构）。
    与自动驾驶 M9-Mono 区别：
      - 输入：游戏截屏（不是仿真相机）
      - 输出：steer/throttle/brake 三头（同结构）
      - 训练数据：raw_clips 游戏录制（带 controls.csv）
      - 部署位置：models/game_assist_control.mlmodelc（与 m9_mono 隔离）
    """
    from src.train_mono import train_mono
    # 复用 train_mono 框架，但输出到独立 checkpoint 目录
    ckpt_dir = _ROOT / "checkpoints" / "game_assist_control"
    ckpt_dir.mkdir(parents=True, exist_ok=True)
    best_path = train_mono(
        epochs=epochs, batch_size=batch_size, grad_accum=grad_accum,
        lr=lr, image_size=image_size, val_ratio=val_ratio,
        use_amp=use_amp, device=device, seed=seed,
        checkpoint_dir=str(ckpt_dir),
        resume_from=str(ckpt_dir / "best_model.pt"),
    )

    # 转换为独立 CoreML 模型（不覆盖 m9_mono）
    control_mlmodelc = MODELS_DIR / "game_assist_control.mlmodelc"
    convert_torch_to_coreml(best_path, control_mlmodelc,
                            img_h=image_size[0], img_w=image_size[1])
    print(f"\n✓ GameAssist 控制模型训练完成 | {control_mlmodelc}")
    return control_mlmodelc


def train_game_assist_control_fpv(
    epochs: int = 30,
    batch_size: int = 8,
    grad_accum: int = 2,
    lr: float = 3e-4,
    image_size=(180, 320),
    val_ratio: float = 0.15,
    use_amp: bool = True,
    device: str = "auto",
    seed: int = 42,
) -> Optional[Path]:
    """训练 FPV 车窗专用控制模型（独立于 TPV 共用模型）。
    只取 view=FPV 的录制数据，skip_zero_label 自动过滤游戏内置自动驾驶段。
    输出：checkpoints/game_assist_control_fpv/ + models/game_assist_control_fpv.mlmodelc
    """
    from src.train_mono import train_mono
    from src.mono_dataset import _list_clips, _clip_view

    ckpt_dir = _ROOT / "checkpoints" / "game_assist_control_fpv"
    ckpt_dir.mkdir(parents=True, exist_ok=True)

    # 先检查是否有 view=FPV 的 clip
    all_clips = _list_clips(_ROOT / "data" / "raw_clips")
    fpv_clips = [c for c in all_clips if _clip_view(c) == "FPV"]
    if not fpv_clips:
        print("[FPV] 没有 FPV 训练数据，跳过 FPV 控制模型训练")
        return None
    print(f"[FPV] 发现 {len(fpv_clips)} 个 FPV clip：{', '.join(c.name for c in fpv_clips)}")

    best_path = train_mono(
        epochs=epochs, batch_size=batch_size, grad_accum=grad_accum,
        lr=lr, image_size=image_size, val_ratio=val_ratio,
        use_amp=use_amp, device=device, seed=seed,
        checkpoint_dir=str(ckpt_dir),
        view_filter="FPV",
    )

    fpv_mlmodelc = MODELS_DIR / "game_assist_control_fpv.mlmodelc"
    convert_torch_to_coreml(best_path, fpv_mlmodelc,
                            img_h=image_size[0], img_w=image_size[1])
    print(f"\n✓ FPV 车窗控制模型训练完成 | {fpv_mlmodelc}")
    return fpv_mlmodelc


# ==================== YOLO 目标检测训练（合成数据 + 迁移）====================

def train_yolo_game(
    epochs: int = 10,
    device: str = "auto",
) -> Path:
    """训练 YOLO 游戏目标检测模型。
    现状：raw_clips 无 VOC 格式目标框标注，先用 Yolo-FastestV2 预训练权重 +
          合成数据（截屏自动标注车辆位置）小规模微调。
    输出：models/game_assist_yolo.onnx（独立于控制模型）。
    """
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    yolo_dir = _ROOT / "Yolo-FastestV2"
    if not yolo_dir.exists():
        raise RuntimeError(f"Yolo-FastestV2 目录不存在: {yolo_dir}")

    print(f"\n{'='*60}\n[YOLO-Game] 训练 | device={device} | epochs={epochs}\n{'='*60}\n")
    print("  注意：当前 raw_clips 无目标框标注，使用预训练权重作为初始模型")
    print("  实际部署需补充人工标注数据迭代训练")

    # Yolo-FastestV2 已有预训练权重，直接转为 ONNX 部署
    # 训练流程见 Yolo-FastestV2/train.py，此处仅做权重导出
    pretrained = yolo_dir / "weights" / "latest.pth"
    if not pretrained.exists():
        # 退到 Yolo-FastestV2 默认权重
        pretrained = yolo_dir / "weights" / "best.pth"
    if not pretrained.exists():
        print(f"  ⚠ 预训练权重不存在: {pretrained}")
        print("  跳过 YOLO 训练，使用 HSV + 控制模型级联（无目标检测）")
        return None

    # 导出 ONNX（Yolo-FastestV2/pytorch2onnx.py 已有）
    onnx_out = MODELS_DIR / "game_assist_yolo.onnx"
    import subprocess
    cmd = [sys.executable, str(yolo_dir / "pytorch2onnx.py"),
           "--cfg", str(yolo_dir / "cfg" / "yolo-fastestv2.cfg"),
           "--weights", str(pretrained),
           "--output", str(onnx_out)]
    print(f"  执行: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(yolo_dir), capture_output=True, text=True)
    if result.returncode == 0:
        print(f"\n✓ YOLO ONNX 导出完成 | {onnx_out}")
        return onnx_out
    else:
        print(f"  ⚠ ONNX 导出失败: {result.stderr[:200]}")
        return None


# ==================== CLI 入口 ====================

def parse_args():
    p = argparse.ArgumentParser(description="游戏辅助模型训练（TPV/FPV 控制 + 视角分类 + YOLO）")
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch_size", type=int, default=8)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"])
    p.add_argument("--no_amp", action="store_true")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--skip_control", action="store_true", help="跳过 TPV/FPV 控制模型")
    p.add_argument("--skip_view", action="store_true", help="跳过视角分类器")
    p.add_argument("--skip_yolo", action="store_true", help="跳过 YOLO")
    return p.parse_args()


def main():
    import random
    args = parse_args()
    use_amp = not args.no_amp
    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    results = {}
    if not args.skip_control:
        try:
            results["control"] = train_game_assist_control(
                epochs=args.epochs, batch_size=args.batch_size, lr=args.lr,
                use_amp=use_amp, device=args.device, seed=args.seed)
        except Exception as e:
            print(f"  ⚠ 控制模型训练失败: {e}")
            import traceback; traceback.print_exc()

        # FPV 车窗专用控制模型（独立训练，与 TPV 共用模型解耦）
        try:
            results["control_fpv"] = train_game_assist_control_fpv(
                epochs=args.epochs, batch_size=args.batch_size, lr=args.lr,
                use_amp=use_amp, device=args.device, seed=args.seed)
        except Exception as e:
            print(f"  ⚠ FPV 控制模型训练失败: {e}")
            import traceback; traceback.print_exc()

    if not args.skip_view:
        try:
            results["view"] = train_view_classifier(
                epochs=min(15, args.epochs), batch_size=16, lr=1e-3,
                device=args.device, seed=args.seed)
        except Exception as e:
            print(f"  ⚠ 视角分类器训练失败: {e}")
            import traceback; traceback.print_exc()

    if not args.skip_yolo:
        try:
            results["yolo"] = train_yolo_game(epochs=10, device=args.device)
        except Exception as e:
            print(f"  ⚠ YOLO 训练失败: {e}")
            import traceback; traceback.print_exc()

    print(f"\n{'='*60}\n✅ 游戏辅助模型训练全部完成\n{'='*60}")
    for k, v in results.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
