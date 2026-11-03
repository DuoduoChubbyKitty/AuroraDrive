# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
单目数据集加载器 — 解析 data/raw_clips/ 中的录制片段

支持两种录制格式：
  1) 旧版 Python AuroraRecorder（单 cam）
     - frames/000001.jpg, 000002.jpg, ...
     - controls.csv 表头: t_sec,frame,steer,throttle,brake
     - 无车辆状态字段 → vehicle_state 用零向量填充
  2) 新版 C++ sidecar（10 cam，12Hz DAgger）
     - frames/cam00_000001.jpg, cam01_000001.jpg, ... cam09_000001.jpg
     - controls.csv 表头: frame,steer,throttle,brake,speed_kmh,heading,
                          pos_x,pos_y,curvature,speed_limit
     - 取 cam00 作为单目输入，vehicle_state 取 [speed_norm, curvature, ...]

输出 PyTorch Dataset，每条样本：
  - image:        [3, H, W]  float32, 0-1 归一化
  - vehicle_state:[6]        float32
  - steer/throttle/brake:    float32 标量
"""

import csv
import json
import random
from pathlib import Path
from typing import List, Tuple, Optional, Dict

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset


# 数据增强参数（沿用 config.DATA_AUGMENTATION 的轻量子集）
_AUG_BRIGHTNESS = 0.20   # ±20% 亮度抖动（每帧随机）
_AUG_CONTRAST = 0.15     # ±15% 对比度抖动（每帧随机）


def _list_clips(clips_dir: Path) -> List[Path]:
    """扫描所有有效 clip 目录（必须同时含 frames/ 和 controls.csv）。"""
    if not clips_dir.exists():
        return []
    clips = []
    for sub in sorted(clips_dir.iterdir()):
        if not sub.is_dir():
            continue
        if not sub.name.startswith("clip_"):
            continue
        if (sub / "controls.csv").exists() and (sub / "frames").is_dir():
            clips.append(sub)
    return clips


def _clip_view(clip_dir: Path) -> Optional[str]:
    """从 view.txt 或 clip.json 获取 clip 整体视角标签。
    返回 "TPV"/"FPV"/"MENU" 或 None（无法判断时）。
    """
    # 1) 显式标注文件（优先级最高）
    vt = clip_dir / "view.txt"
    if vt.exists():
        raw = vt.read_text().strip().upper()
        if raw in ("TPV", "FPV", "MENU"):
            return raw
    # 2) 录制器写入的 clip.json
    cj = clip_dir / "clip.json"
    if cj.exists():
        try:
            d = json.loads(cj.read_text())
            v = str(d.get("view", "")).strip().upper()
            if v in ("TPV", "FPV", "MENU"):
                return v
        except (json.JSONDecodeError, KeyError, TypeError):
            pass
    return None


def _detect_format(header: List[str]) -> str:
    """根据 controls.csv 表头判定录制格式。
    返回 "v1_old"（Python 单 cam）、"v2_new"（C++ 10 cam）、
    "v3_keys"（2026-11-03 起的纯按键 10 列，V3 专用）或 "unknown"。

    ⚠️ 2026-11-03 修复（审查 P1-6）：旧实现最后一行是 `return "v1_old"`，
       即**任何无法识别的表头都会被当成 v1_old 继续加载**。这层"看起来像什么
       就当什么"的子集猜测，会让错格式的文件悄无声息地走进 V2 训练流程。
       现在改为：必须真的具备 v1_old 的三列（steer/throttle/brake）才判 v1_old，
       否则返回 "unknown"，由调用方显式报错（fail fast）。
    """
    h = [c.strip() for c in header]
    if "speed_kmh" in h and "curvature" in h:
        return "v2_new"
    # V3 纯按键格式：没有 steer/throttle，只有原始按键列
    if "w" in h and "shift" in h and "super_brake" in h:
        return "v3_keys"
    # v1_old 的判别必须正向成立：连续量三列齐全
    if all(k in h for k in ("steer", "throttle", "brake")):
        return "v1_old"
    return "unknown"


def _load_controls_csv(csv_path: Path) -> Tuple[List[Dict], str]:
    """读取 controls.csv，返回逐帧 dict 列表 + 格式标识。
    兼容新旧两种表头。

    ⚠️ 2026-11-03：录制器已改为**纯按键 10 列**（v3_keys）。
       本函数是 V2/Mono 连续量模型的加载器，**读不了 v3_keys 格式**——
       它需要 steer/throttle/brake 三个连续量，而新格式只有按键 0/1。
       以前的写法是 `except (ValueError, KeyError): continue` 静默跳过，
       结果整批数据被吞成空列表且无任何告警（实测 4 行输入 → 返回 0 行）。
       现在改为**显式报错**：宁可在数据加载阶段炸掉，也不要拿空数据集训一整天。
    """
    with open(csv_path, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames or []
        fmt = _detect_format(header)
        if fmt == "v3_keys":
            raise ValueError(
                f"{csv_path} 是 V3 纯按键格式（w/a/s/d/shift/space/...），"
                "mono_dataset 是 V2/Mono 连续量模型的数据集，无法读取。\n"
                "  请用 V3 专用数据集（src/dataset_v3.py）训练 V3 模型，"
                "或改用 V2 格式的录制数据训练 V2/Mono。"
            )
        if fmt == "unknown":
            # 审查 P1-6：以前未知表头会被当成 v1_old 静默继续，最终产出空数据集
            raise ValueError(
                f"{csv_path} 的表头无法识别：{header}\n"
                "  V2/Mono 需要 steer/throttle/brake 三列（v1_old），"
                "或额外带 speed_kmh/curvature（v2_new）。\n"
                "  请先跑 `python3 tools/verify_recording.py <目录>` 检查录制产物格式。"
            )
        rows = []
        n_bad_rows = 0
        first_bad = ""
        for i, r in enumerate(reader):
            try:
                row = {
                    "steer": float(r["steer"]),
                    "throttle": float(r["throttle"]),
                    "brake": float(r["brake"]),
                }
                if fmt == "v2_new":
                    # 新格式：从 sidecar 物理量构造 6 维 vehicle_state
                    speed_kmh = float(r.get("speed_kmh", 0.0))
                    curvature = float(r.get("curvature", 0.0))
                    heading = float(r.get("heading", 0.0))
                    speed_limit = float(r.get("speed_limit", 60.0))
                    row["vehicle_state"] = np.array([
                        # 全部归一化到 [-1, 1] 或 [0, 1]，匹配 M9-Mono 训练分布
                        np.clip(speed_kmh / 120.0, 0.0, 1.0),         # speed_norm
                        np.clip(curvature * 5.0, -1.0, 1.0),          # curvature（放大）
                        np.sin(heading),                               # heading_sin
                        np.cos(heading),                               # heading_cos
                        np.clip(speed_limit / 120.0, 0.0, 1.0),        # speed_limit_norm
                        0.0,                                            # reserved
                    ], dtype=np.float32)
                else:
                    # 旧格式：无车辆状态，零向量填充（模型仍可从图像学习）
                    row["vehicle_state"] = np.zeros(6, dtype=np.float32)
                rows.append(row)
            except (ValueError, KeyError) as exc:
                # 审查 P1-5：坏行不能静默丢弃。整批都是坏行时必须报错，
                # 否则会得到一个空数据集却在训练时才发现（白等一整轮）。
                n_bad_rows += 1
                if not first_bad:
                    first_bad = f"第{i}行({type(exc).__name__}: {exc})"
        if n_bad_rows:
            if not rows:
                raise ValueError(
                    f"{csv_path} 的 {n_bad_rows} 行数据全部无法解析，首个错误: {first_bad}\n"
                    "  这通常意味着列名对但内容格式不对（如空值、非数字）。"
                )
            print(f"[warn] {csv_path.name}: 跳过 {n_bad_rows} 行无法解析的数据"
                  f"（共 {len(rows) + n_bad_rows} 行），首个错误: {first_bad}")
        return rows, fmt


def _frame_path(clip_dir: Path, fmt: str, frame_idx: int) -> Optional[Path]:
    """根据格式构造单帧图像路径。"""
    frames_dir = clip_dir / "frames"
    if fmt == "v2_new":
        # cam00_000001.jpg（取前向相机）
        fname = f"cam00_{frame_idx:06d}.jpg"
    else:
        # 000001.jpg（旧版单 cam）
        fname = f"{frame_idx:06d}.jpg"
    p = frames_dir / fname
    return p if p.exists() else None


def _augment(img: np.ndarray, steer: float, rng: random.Random) -> Tuple[np.ndarray, float]:
    """轻量图像增强：亮度抖动 + 对比度抖动（每帧均随机应用，不做水平翻转）。
    img: [H, W, 3] float32 [0, 1]
    返回增强后的 img 与对应 steer（翻转已移除，steer 保持不变）。
    """
    # 亮度抖动（每帧随机 ±_AUG_BRIGHTNESS）
    delta = rng.uniform(-_AUG_BRIGHTNESS, _AUG_BRIGHTNESS)
    img = np.clip(img + delta, 0.0, 1.0).astype(np.float32)
    # 对比度抖动（每帧随机 ±_AUG_CONTRAST）
    factor = 1.0 + rng.uniform(-_AUG_CONTRAST, _AUG_CONTRAST)
    mean = img.mean()
    img = np.clip((img - mean) * factor + mean, 0.0, 1.0).astype(np.float32)
    return img, steer


class MonoClipsDataset(Dataset):
    """单目片段数据集。

    扫描 data/raw_clips/ 下所有 clip_* 目录，加载 (image, vehicle_state, label) 三元组。
    skip_zero_label=True 时丢弃全零标签帧（旧版 Python clip 启动期常见），
    避免模型被静止帧主导。
    """

    def __init__(
        self,
        clips_dir: str | Path,
        image_size: Tuple[int, int] = (180, 320),   # (H, W) → 匹配 m9_mono 默认
        augment: bool = False,
        skip_zero_label: bool = True,
        view_filter: Optional[str] = None,
        seed: int = 42,
    ):
        self.clips_dir = Path(clips_dir)
        self.image_size = image_size  # (H, W)
        self.augment = augment
        self.skip_zero_label = skip_zero_label
        self.view_filter = view_filter
        self.rng = random.Random(seed)

        # 扫描所有 clip，构建全局索引：(clip_dir, fmt, frame_idx, label_dict)
        self.index: List[Tuple[Path, str, int, Dict]] = []
        clips = _list_clips(self.clips_dir)
        if not clips:
            raise RuntimeError(f"未在 {self.clips_dir} 找到任何 clip_* 目录")

        # 按视角过滤（FPV 专用模型训练时只取 FPV clip）
        if view_filter:
            clips = [c for c in clips if _clip_view(c) == view_filter]
            if not clips:
                raise RuntimeError(
                    f"没有 view={view_filter} 的 clip（共 {len(_list_clips(self.clips_dir))} 个 clip）")

        for clip in clips:
            rows, fmt = _load_controls_csv(clip / "controls.csv")
            for i, row in enumerate(rows):
                # 跳过全零标签帧（仅当开启过滤时）
                if skip_zero_label and row["steer"] == 0.0 \
                        and row["throttle"] == 0.0 and row["brake"] == 0.0:
                    continue
                # 检查图像文件存在（避免索引到已删除的帧）
                if _frame_path(clip, fmt, i) is None:
                    continue
                self.index.append((clip, fmt, i, row))

        # 标签范围检查
        if not self.index:
            raise RuntimeError(f"所有 clip 帧均被过滤（skip_zero_label={skip_zero_label}）")

        n_steering_active = sum(1 for *_, r in self.index
                                if r["steer"] != 0.0 or r["throttle"] != 0.0)
        info = f"view={view_filter}" if view_filter else "全部视角"
        print(f"[MonoDataset] 加载 {len(self.index)} 样本，来自 {len(clips)} 个 clip "
              f"（{info}，有效控制帧 {n_steering_active}）")

    def __len__(self) -> int:
        return len(self.index)

    def __getitem__(self, idx: int) -> Dict[str, torch.Tensor]:
        clip_dir, fmt, frame_idx, row = self.index[idx]
        img_path = _frame_path(clip_dir, fmt, frame_idx)
        if img_path is None:
            raise RuntimeError(f"图像缺失: clip={clip_dir.name} frame={frame_idx}")

        # PIL 读取 → RGB → resize → 归一化 [0,1] → float32 HWC
        with Image.open(img_path) as im:
            im = im.convert("RGB").resize(
                (self.image_size[1], self.image_size[0]), Image.BILINEAR)
            img = np.asarray(im, dtype=np.float32) / 255.0

        steer = float(row["steer"])
        if self.augment:
            img, steer = _augment(img, steer, self.rng)

        # HWC → CHW
        img = np.transpose(img, (2, 0, 1)).copy()

        return {
            "image": torch.from_numpy(img),
            "vehicle_state": torch.from_numpy(row["vehicle_state"].copy()),
            "steer": torch.tensor([steer], dtype=torch.float32),
            "throttle": torch.tensor([float(row["throttle"])], dtype=torch.float32),
            "brake": torch.tensor([float(row["brake"])], dtype=torch.float32),
        }


def make_train_val_split(
    dataset: MonoClipsDataset,
    val_ratio: float = 0.1,
    seed: int = 42,
) -> Tuple[MonoClipsDataset, MonoClipsDataset]:
    """按 clip 边界划分训练/验证集（避免同一 clip 帧跨 split 造成泄漏）。

    仅基于 dataset.index 中实际出现的 clip 做划分（跳过空 clip）。
    若有效 clip 数 < 4 退化为按帧随机划分（小数据集兜底）。
    """
    # 收集 dataset.index 中实际出现过的 clip（保证至少有一帧）
    clip_counts: Dict[Path, int] = {}
    for c, *_ in dataset.index:
        clip_counts[c] = clip_counts.get(c, 0) + 1
    active_clips = [c for c, n in clip_counts.items() if n > 0]

    if len(active_clips) >= 4:
        # 按 clip 划分
        rng = random.Random(seed)
        rng.shuffle(active_clips)
        # val 取至少 1 个 clip，最多 val_ratio 比例
        n_val = max(1, int(len(active_clips) * val_ratio))
        # 同时保证 train 至少有 1 个 clip（避免极端 val 全取）
        if n_val >= len(active_clips):
            n_val = len(active_clips) - 1
        val_clips = set(active_clips[:n_val])

        train_idx = [i for i, (c, *_) in enumerate(dataset.index) if c not in val_clips]
        val_idx = [i for i, (c, *_) in enumerate(dataset.index) if c in val_clips]

        # 兜底：若 val 恰好为空（理论不该发生），退化为按帧划分
        if not val_idx:
            return _fallback_frame_split(dataset, val_ratio, seed)

        train_ds = torch.utils.data.Subset(dataset, train_idx)
        val_ds = torch.utils.data.Subset(dataset, val_idx)
        print(f"[MonoDataset] 按 clip 划分: train={len(train_ds)} val={len(val_ds)} "
              f"(val_clips={len(val_clips)}/{len(active_clips)})")
        return train_ds, val_ds

    return _fallback_frame_split(dataset, val_ratio, seed)


def _fallback_frame_split(
    dataset: MonoClipsDataset,
    val_ratio: float,
    seed: int,
) -> Tuple[MonoClipsDataset, MonoClipsDataset]:
    """按帧随机划分（小数据集兜底，保证至少 1 条 val 样本）。"""
    n = len(dataset)
    n_val = max(1, int(n * val_ratio))
    g = torch.Generator().manual_seed(seed)
    perm = torch.randperm(n, generator=g).tolist()
    val_idx_set = set(perm[:n_val])
    train_idx = [i for i in range(n) if i not in val_idx_set]
    val_idx_list = list(val_idx_set)

    train_ds = torch.utils.data.Subset(dataset, train_idx)
    val_ds = torch.utils.data.Subset(dataset, val_idx_list)
    print(f"[MonoDataset] 按帧随机划分: train={len(train_ds)} val={len(val_ds)}")
    return train_ds, val_ds
