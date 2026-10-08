# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
多任务数据集加载器 v2 — 图像 + 车道线 + 检测框 + 车辆状态（accel/heading/curvature）

设计目标（对应新主驾驶模型的数据需求）
--------------------------------------------------
每条样本同时携带：
  - image          : [3, H, W]      图像（与 mono_dataset 完全一致，不变）
  - lane_mask      : [1, H, W]      车道线二值掩码（1=车道线）
  - det_boxes      : [N, 4]         检测框 xyxy，**归一化到 [0,1]**
  - det_scores     : [N]            置信度
  - det_classes    : [N]            类别 id
  - det_mask       : [N]            ★ 变长 padding 的 attention mask（1=真实框，0=空位）
  - vehicle_state  : [10]           含 accel + heading + curvature
  - vehicle_state_mask : [10]       ★ 字段级降级掩码（1=真实值，0=缺失补零）
  - steer/throttle/brake : [1]

⛔ 明确不输出可行驶区域（drivable area）。
   yolopx 的 `da` 头在本文件中**从不被读取**（只取 `ll` 车道线头与 `det` 检测头），
   见 `backfill_lane_masks()` 中的显式丢弃注释。

================================ 数据现状（实测，2026-10-08）================================
本仓库 data/raw_clips/ 下现有 5 个 clip，**全部是 v1_old 格式**，实测结论：

  clip_20260825_182145  23 帧   表头 t_sec,frame,steer,throttle,brake
  clip_20260825_182147  12 帧   同上
  clip_20260922_003025   2 帧   同上（dt≈0.0011s，异常高频，见下方 accel 保护）
  clip_20260922_003027  22 帧   同上
  clip_20260922_003029  70 帧   同上
  合计 129 帧 / 129 行 controls.csv

  ① **车道线：录制时没有存。** RecordEngine.swift 只落盘 frames/ + controls.csv
     (t_sec,frame,steer,throttle,brake) + view.txt + meta.json，全仓库不存在任何
     lane_mask / lane_poly / lanes.json 产物（已 grep 验证）。
     → 本文件提供 `backfill_lane_masks()` 离线补算（用 yolopx 的 ll 头对录制帧跑一遍）。
  ② **检测框：录制时也没有存。** 同上，无任何 detections/bbox 落盘。
     → 本文件提供 `backfill_detections()` 离线补算（yolopx det 头 + NMS）。
  ③ **speed_kmh / heading / curvature：现有 5 个 clip 全都没有。**
     v2_new 格式（C++ sidecar 10 cam）在本仓库**没有任何实际数据**，
     仅有 mono_dataset.py 中按表头推断的解析分支。
     → 因此 accel 无法从真实 speed 差分得到，本文件如实降级为 0 并把 mask 置 0。
  ④ **控制标签全为零**：5 个 clip 的 steer/throttle/brake 每一行都是 0.0。
     mono_dataset 在 skip_zero_label=True 下会直接抛
     RuntimeError("所有 clip 帧均被过滤")。
     → 本文件默认不因标签全零而丢弃样本，也不会崩溃（见 allow_empty / require_active_control）。

================================ 降级策略（缺字段不报错，置零 + mask 标记）================================
  缺 lane_mask      → 全 0 掩码，lane_present=False
  缺 detections     → 全 0 张量，det_mask 全 0（模型可通过 mask 忽略空位）
  缺 speed_kmh      → speed_norm=0，vehicle_state_mask[0]=0，且 accel 无法计算 → mask[6/7]=0
  缺 heading        → sin=0, cos=1（等价 heading=0，与 InferenceEngine 运行时行为一致），mask[2/3/8]=0
  缺 curvature      → 0，mask[1/9]=0
  缺 speed_limit    → 0，mask[4]=0
  缺 t_sec          → 用 default_fps 推 dt 计算 accel
  dt 过小/异常      → 该帧 accel 置 0 且 mask=0（实测 clip_20260922_003025 dt=0.0011s）

================================ vehicle_state 布局（STATE_DIM=10）================================
  前 6 维与 src/mono_dataset.py 的 v2_new 契约**逐位一致**，便于旧权重继续前向兼容
  （取 vehicle_state[:6] 即为旧契约）；后 4 维为本次新增。

  idx  name               计算式                          说明
  ---  -----------------  ------------------------------  --------------------------------
   0   speed_norm         clip(speed_kmh/120, 0, 1)       旧契约
   1   curvature_x5       clip(curvature*5, -1, 1)        旧契约
   2   heading_sin        sin(heading_rad)                旧契约（heading 统一转弧度）
   3   heading_cos        cos(heading_rad)                旧契约
   4   speed_limit_norm   clip(speed_limit/120, 0, 1)     旧契约
   5   reserved           0.0                             旧契约占位
   6   accel_norm         clip(accel_mps2/5, -1, 1)        ★新增：逐帧差分算出的加速度
   7   accel_mps2         accel_mps2（原始 m/s²，已限幅）   ★新增：原始量，供自定义损失
   8   heading_wrapped    wrap_to_pi(heading_rad)/pi        ★新增：连续角（无 sin/cos 二义性）
   9   curvature_raw      curvature（原始 1/m）             ★新增：原始量

  heading 单位：**录制端未在本仓库（v2 CSV 写入端缺失）**，故本文件不假定单位，
  提供 heading_unit="auto"|"rad"|"deg"，auto 判定规则见 `_infer_heading_unit()`：
    max|heading| > 2π+eps → 判为「度」并转弧度；否则判为「弧度」。
  注意本仓库内部两种约定并存：mono_dataset/InferenceEngine 按**弧度**用 sin/cos，
  而 NetworkLocator/CoordinateCapture 产出的 heading 是**度**（[0,360)）。
  这是真实存在的口径冲突，务必在写入端确认后显式指定 heading_unit。

================================ 兼容的两种录制格式 ================================
  v1_old（旧版 Python AuroraRecorder，单 cam）
    frames/000000.jpg ...        controls.csv: t_sec,frame,steer,throttle,brake
  v2_new（新版 C++ sidecar，10 cam，12Hz DAgger）
    frames/cam00_000000.jpg ...  controls.csv: frame,steer,throttle,brake,
                                 speed_kmh,heading,pos_x,pos_y,curvature,speed_limit
    取 cam00 作为单目输入。
  帧号来源：优先用 CSV 的 `frame` 列（mono_dataset 用行序号，行序与 frame 列不一致时会错位）；
  缺失时才回退到行序号。图像扩展名 .jpg / .png 都会尝试。
"""

from __future__ import annotations

import csv
import json
import math
import random
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Sequence, Tuple

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

# ---- 车道线几何口径（与 Swift MaskGrid 逐位对齐的唯一真值实现）----
# 两种导入方式都支持：`python -m src.train_v2`（包内）与 `python src/dataset_v2.py`（脚本）
try:                                        # pragma: no cover - 取决于调用方式
    from .lane_geometry import (            # type: ignore[import-not-found]
        LANE_GRID, LANE_SRC_SIZE, LETTERBOX_PAD_VALUE,
        assert_lane_contract, grid_content_rows, letterbox_metrics,
        logits_to_grid, normalize_lane_mask, valid_region_in_grid,
    )
except ImportError:                         # pragma: no cover
    from lane_geometry import (             # type: ignore[no-redef]
        LANE_GRID, LANE_SRC_SIZE, LETTERBOX_PAD_VALUE,
        assert_lane_contract, grid_content_rows, letterbox_metrics,
        logits_to_grid, normalize_lane_mask, valid_region_in_grid,
    )

# ===================== 可调常量 =====================
STATE_DIM = 10
LEGACY_STATE_DIM = 6          # 前 6 维 = mono_dataset v2_new 契约
DEFAULT_DET_N = 20            # 检测框固定槽位数 N（padding 到 N）
DEFAULT_IMAGE_SIZE = (180, 320)   # (H, W)，与 mono_dataset 默认一致
DEFAULT_FPS = 30.0            # 缺 t_sec 时用于推 dt

_AUG_BRIGHTNESS = 0.20
_AUG_CONTRAST = 0.15

# 加速度保护（实测 clip_20260922_003025 的 dt=0.0011s 会把差分炸到上千 m/s²）
ACCEL_CLAMP_MPS2 = 20.0       # 物理上限，超出即限幅
DT_MIN_SEC = 1e-3             # 小于此值的 dt 视为不可用 → 该帧 accel 置 0 且 mask=0

# vehicle_state 各维语义（供训练侧按名索引）
STATE_LAYOUT: Dict[str, int] = {
    "speed_norm": 0,
    "curvature_x5": 1,
    "heading_sin": 2,
    "heading_cos": 3,
    "speed_limit_norm": 4,
    "reserved": 5,
    "accel_norm": 6,
    "accel_mps2": 7,
    "heading_wrapped": 8,
    "curvature_raw": 9,
}

_LANE_CACHE_DIR = "lane_mask"      # lane_mask/000000.png（uint8 0/255）
_DET_CACHE_DIR = "detections"      # detections/000000.json


# ==================================================================================
# 工具函数
# ==================================================================================
def _wrap_to_pi(rad: float) -> float:
    """把角度环绕到 (-π, π]。"""
    return (rad + math.pi) % (2.0 * math.pi) - math.pi


def _safe_float(v: Any) -> Optional[float]:
    """字符串 → float；空值/非数字返回 None（用于降级判断）。"""
    if v is None:
        return None
    s = str(v).strip()
    if s == "" or s.lower() in ("nan", "none", "null"):
        return None
    try:
        f = float(s)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _infer_heading_unit(values: Sequence[float], eps: float = 1e-6) -> str:
    """推断 heading 单位，返回 "rad" 或 "deg"。

    规则（保守）：
      · 只要存在 |h| > 2π+eps 的值 → 不可能是弧度 → "deg"
      · 否则 → "rad"
    边界情况：heading 恰好只在 [0, 2π) 内取值时无法区分（真实数据几乎不会这么巧），
    此时按 "rad" 处理；写入端确认后请显式传 heading_unit="deg"。
    """
    if not values:
        return "rad"
    m = max(abs(v) for v in values)
    return "deg" if m > 2.0 * math.pi + eps else "rad"


# ==================================================================================
# clip 扫描与格式判定
# ==================================================================================
def _list_clips(clips_dir: Path) -> List[Path]:
    """扫描所有有效 clip 目录（必须同时含 frames/ 和 controls.csv）。"""
    if not clips_dir.exists():
        return []
    clips = []
    for sub in sorted(clips_dir.iterdir()):
        if not sub.is_dir() or not sub.name.startswith("clip_"):
            continue
        if (sub / "controls.csv").exists() and (sub / "frames").is_dir():
            clips.append(sub)
    return clips


def _clip_view(clip_dir: Path) -> Optional[str]:
    """从 view.txt 或 clip.json 读取整体视角标签；无法判断返回 None。"""
    vt = clip_dir / "view.txt"
    if vt.exists():
        raw = vt.read_text().strip().upper()
        if raw in ("TPV", "FPV", "MENU"):
            return raw
    cj = clip_dir / "clip.json"
    if cj.exists():
        try:
            v = str(json.loads(cj.read_text()).get("view", "")).strip().upper()
            if v in ("TPV", "FPV", "MENU"):
                return v
        except (json.JSONDecodeError, KeyError, TypeError, OSError):
            pass
    return None


def _detect_format(header: Sequence[str], clip_dir: Path) -> str:
    """判定录制格式 → "v1_old" | "v2_new"。**仅用于统计/报告**。

    ⚠️ 帧文件名不再依赖本判定（见 `_frame_path`）：实测存在「表头像 v2 但帧名是
    旧式 000000.jpg」的混合 clip，若按 fmt 硬拼 cam00_ 前缀会整 clip 取不到帧。

    判据优先级：
      1) frames/ 下存在 cam00_* 文件 → v2_new（最强信号：10 cam sidecar）
      2) 表头**同时**含 speed_kmh 与 curvature → v2_new（与 mono_dataset 判据一致）
      3) 否则 → v1_old（旧版 Python 单 cam）
    """
    try:
        frames_dir = clip_dir / "frames"
        if frames_dir.is_dir():
            for p in frames_dir.iterdir():
                if p.name.startswith("cam00_"):
                    return "v2_new"
    except OSError:
        pass
    h = {c.strip() for c in header}
    if "speed_kmh" in h and "curvature" in h:
        return "v2_new"
    return "v1_old"


def _read_header(csv_path: Path) -> List[str]:
    """安全读取 controls.csv 表头（不泄漏文件句柄）。"""
    try:
        with open(csv_path, "r", newline="", encoding="utf-8") as f:
            return [c.strip() for c in (next(csv.reader(f), []) or [])]
    except (OSError, StopIteration, csv.Error):
        return []


def _frame_path(clip_dir: Path, fmt: str, frame_no: int) -> Optional[Path]:
    """构造单帧图像路径。找不到返回 None。

    **两种命名约定都尝试**（顺序：cam00_ 优先 = 前向相机）：
      v2_new: cam00_000000.jpg      v1_old: 000000.jpg
    这样即使 controls.csv 表头与实际帧命名不一致（混合 clip）也不会整 clip 丢帧。
    """
    frames_dir = clip_dir / "frames"
    stems = (f"cam00_{frame_no:06d}", f"{frame_no:06d}") \
        if fmt == "v2_new" else (f"{frame_no:06d}", f"cam00_{frame_no:06d}")
    for stem in stems:
        for ext in (".jpg", ".jpeg", ".png"):
            p = frames_dir / f"{stem}{ext}"
            if p.exists():
                return p
    return None


# ==================================================================================
# controls.csv 解析（含加速度差分）
# ==================================================================================
def _load_controls_csv(
    csv_path: Path,
    clip_dir: Path,
    heading_unit: str = "auto",
    default_fps: float = DEFAULT_FPS,
) -> Tuple[List[Dict[str, Any]], str, Dict[str, Any]]:
    """读取 controls.csv → 逐帧 dict 列表 + 格式标识 + 诊断信息。

    返回的每行 dict 含：
      frame_no, t_sec, steer, throttle, brake,
      speed_kmh/heading_rad/curvature/speed_limit（缺失为 None）,
      vehicle_state[10], vehicle_state_mask[10], accel_mps2, accel_ok
    """
    with open(csv_path, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        header = [c.strip() for c in (reader.fieldnames or [])]
        fmt = _detect_format(header, clip_dir)
        raw_rows = list(reader)

    diag: Dict[str, Any] = {
        "format": fmt,
        "n_rows": len(raw_rows),
        "has_speed": False,
        "has_heading": False,
        "has_curvature": False,
        "has_speed_limit": False,
        "has_t_sec": "t_sec" in header,
        "heading_unit": None,
        "n_accel_ok": 0,
        "n_accel_rejected_dt": 0,
        "n_accel_clamped": 0,
    }

    rows: List[Dict[str, Any]] = []
    for i, r in enumerate(raw_rows):
        steer = _safe_float(r.get("steer"))
        throttle = _safe_float(r.get("throttle"))
        brake = _safe_float(r.get("brake"))
        if steer is None or throttle is None or brake is None:
            continue  # 控制标签损坏的行直接跳过（其余字段再好也无法训练）

        # 帧号：优先 CSV 的 frame 列，缺失时回退行序号
        fno = _safe_float(r.get("frame"))
        frame_no = int(fno) if fno is not None else i

        rows.append({
            "frame_no": frame_no,
            "t_sec": _safe_float(r.get("t_sec")),
            "steer": steer,
            "throttle": throttle,
            "brake": brake,
            "speed_kmh": _safe_float(r.get("speed_kmh")),
            "heading_raw": _safe_float(r.get("heading")),
            "curvature": _safe_float(r.get("curvature")),
            "speed_limit": _safe_float(r.get("speed_limit")),
        })

    if not rows:
        return rows, fmt, diag

    # ---- heading 单位统一（auto 判定，全 clip 统一，避免逐帧抖动）----
    hvals = [r["heading_raw"] for r in rows if r["heading_raw"] is not None]
    unit = heading_unit
    if unit == "auto":
        unit = _infer_heading_unit(hvals)
    diag["heading_unit"] = unit if hvals else None
    for r in rows:
        h = r["heading_raw"]
        if h is None:
            r["heading_rad"] = None
        else:
            r["heading_rad"] = math.radians(h) if unit == "deg" else float(h)

    # ---- 加速度：speed_kmh 逐帧差分 ÷ dt ----
    n = len(rows)
    for i in range(n):
        rows[i]["accel_mps2"] = 0.0
        rows[i]["accel_ok"] = False
        rows[i]["accel_clamped"] = False

    for i in range(1, n):
        s0, s1 = rows[i - 1]["speed_kmh"], rows[i]["speed_kmh"]
        if s0 is None or s1 is None:
            continue  # 缺 speed 字段 → 无法差分（当前 5 个 clip 全走这里）
        t0, t1 = rows[i - 1]["t_sec"], rows[i]["t_sec"]
        if t0 is not None and t1 is not None:
            dt = t1 - t0
        else:
            dt = 1.0 / default_fps if default_fps > 0 else None
        if dt is None or dt < DT_MIN_SEC:
            diag["n_accel_rejected_dt"] += 1   # dt 异常（实测有 0.0011s 的 clip）
            continue
        a = (s1 - s0) / 3.6 / dt               # km/h → m/s，再 ÷ s
        if abs(a) > ACCEL_CLAMP_MPS2:
            a = math.copysign(ACCEL_CLAMP_MPS2, a)
            rows[i]["accel_clamped"] = True
            diag["n_accel_clamped"] += 1
        rows[i]["accel_mps2"] = a
        rows[i]["accel_ok"] = True
        diag["n_accel_ok"] += 1

    # ---- 组装 vehicle_state[10] + vehicle_state_mask[10] ----
    for r in rows:
        st = np.zeros(STATE_DIM, dtype=np.float32)
        mk = np.zeros(STATE_DIM, dtype=np.float32)

        if r["speed_kmh"] is not None:
            st[0] = float(np.clip(r["speed_kmh"] / 120.0, 0.0, 1.0))
            mk[0] = 1.0
            diag["has_speed"] = True

        if r["curvature"] is not None:
            st[1] = float(np.clip(r["curvature"] * 5.0, -1.0, 1.0))
            st[9] = float(r["curvature"])
            mk[1] = mk[9] = 1.0
            diag["has_curvature"] = True

        if r["heading_rad"] is not None:
            h = r["heading_rad"]
            st[2] = math.sin(h)
            st[3] = math.cos(h)
            st[8] = float(_wrap_to_pi(h) / math.pi)
            mk[2] = mk[3] = mk[8] = 1.0
            diag["has_heading"] = True
        else:
            # 降级：等价 heading=0，与 InferenceEngine.buildVehicleState 的
            # 「无遥测 → sin=0/cos=1」运行时行为保持一致，但 mask=0 明确标记为缺失
            st[2], st[3] = 0.0, 1.0

        if r["speed_limit"] is not None:
            st[4] = float(np.clip(r["speed_limit"] / 120.0, 0.0, 1.0))
            mk[4] = 1.0
            diag["has_speed_limit"] = True

        st[5] = 0.0  # reserved：恒 0，非缺失

        if r["accel_ok"]:
            st[6] = float(np.clip(r["accel_mps2"] / 5.0, -1.0, 1.0))
            st[7] = float(r["accel_mps2"])
            mk[6] = mk[7] = 1.0

        r["vehicle_state"] = st
        r["vehicle_state_mask"] = mk

    return rows, fmt, diag


# ==================================================================================
# 车道线掩码 / 检测框 缓存读取（含缺失降级）
# ==================================================================================
def _load_lane_mask(clip_dir: Path, frame_no: int, size: Tuple[int, int],
                    grid: int = LANE_GRID, strict_geometry: bool = False
                    ) -> Tuple[np.ndarray, bool]:
    """读取车道线掩码 → ([1, grid, grid] float32 {0,1}, present)。

    ★ 几何口径（2026-10-08 修复，本函数是核心修复点）
    ----------------------------------------------------------------
    返回的掩码是 **letterbox 640 坐标系下采样后的 grid×grid 网格**，
    与 Swift `YolopxEngine.extractMask()` 产出的 `MaskGrid` **逐位同口径**。

    ⛔ 修复前的行为（bug）：把缓存掩码 `resize` 到 `size=(H,W)`（相机空间 180×320），
       导致「内容填满全图、无灰边、纵横比破坏」，与运行时口径最多差 35 格（21.9%）。
       根因是当时认为 lane_mask 应与 image 同分辨率 —— 但运行时 lane_mask 来自
       **letterbox 640 的俯视投影**，与 180×320 的相机空间图**本就不同坐标系**。

    优先级：
      1) lane_mask/{frame:06d}.png   离线补算缓存
         · 640×640（letterbox 全分辨率）→ 4×4 多数表决降到 grid
         · grid×grid（已降采样）        → 原样使用
      2) lane_masks.npz              键为 "frame_{no}" 或 str(no)，同上规则
      3) lanes.json / lane_poly.json 折线 → 现场栅格化（相机空间，标注为 legacy）
    全部缺失 → 返回全 0 掩码 + present=False（**不报错**，符合降级纪律）。

    Args:
        size: 相机空间 (H, W)，**仅用于 lanes.json 折线栅格化这条 legacy 路径**
        grid: 输出网格边长，默认 160（= Swift maskGridSize）
        strict_geometry: True 时，若缓存尺寸既不是 grid×grid 也不能整除到 grid，
            直接抛错而不是降级（用于训练侧 fail-fast）
    """
    H, W = size
    empty = np.zeros((1, grid, grid), dtype=np.float32)

    def _to_grid(arr: np.ndarray) -> np.ndarray:
        """把任意合法来源归一到 [grid, grid] {0,1}；不合法则按 strict_geometry 决定。"""
        a = np.asarray(arr)
        while a.ndim > 2 and a.shape[0] == 1:
            a = a[0]
        if a.ndim != 2:
            raise ValueError(f"_load_lane_mask: 期望 2D 掩码，实际 {a.shape}")
        h, w = a.shape
        if (h, w) == (grid, grid):
            return (a > 0.5).astype(np.float32)
        if h == w and h % grid == 0:
            # letterbox 全分辨率 → 多数表决（与 Swift extractMask 同规则）
            m = (a > 0.5).astype(np.uint8)
            stride = h // grid
            blocks = m.reshape(grid, stride, grid, stride)
            return (blocks.sum(axis=(1, 3)) * 2 >= stride * stride).astype(np.float32)
        if strict_geometry:
            raise ValueError(
                f"_load_lane_mask: 缓存掩码尺寸 {h}×{w} 无法归一到 {grid}×{grid} 的 "
                f"letterbox 口径。**拒绝静默 resize**（会破坏与 Swift MaskGrid 的几何一致性）。"
                f"请重新运行 backfill_lane_masks() 以产出 letterbox 口径缓存。")
        # 非严格模式：仍不 resize（那正是被修复的 bug），改为返回空掩码并标记缺失
        return None  # type: ignore[return-value]

    p = clip_dir / _LANE_CACHE_DIR / f"{frame_no:06d}.png"
    if p.exists():
        with Image.open(p) as im:
            arr = np.asarray(im.convert("L"), dtype=np.float32)
        g = _to_grid(arr > 127)
        if g is None:
            return empty, False
        return g[None, :, :], True

    npz = clip_dir / "lane_masks.npz"
    if npz.exists():
        try:
            with np.load(npz) as z:
                for key in (f"frame_{frame_no}", str(frame_no)):
                    if key in z:
                        g = _to_grid(z[key] > 0)
                        if g is None:
                            return empty, False
                        return g[None, :, :], True
        except (OSError, ValueError, KeyError):
            pass

    for name in ("lanes.json", "lane_poly.json"):
        pj = clip_dir / name
        if pj.exists():
            try:
                data = json.loads(pj.read_text())
                polys = data.get(str(frame_no), data.get(f"frame_{frame_no}"))
                if polys:
                    # ⚠️ legacy 路径：折线是**相机空间归一化坐标**，与 letterbox 口径不同源。
                    #    仅作过渡兼容，正式数据必须走 backfill_lane_masks()。
                    cam = _rasterize_polylines(polys, size)      # [1,H,W]
                    g = _to_grid(cam)
                    if g is None:
                        return empty, False
                    return g[None, :, :], True
            except (json.JSONDecodeError, OSError, TypeError, KeyError):
                pass

    return empty, False


def _rasterize_polylines(polys: Any, size: Tuple[int, int], thickness: int = 3
                         ) -> np.ndarray:
    """把折线列表栅格化成 [1, H, W] 掩码（坐标按 [0,1] 归一化理解）。

    降级说明：无 cv2 时用「按点画圆」的朴素实现，够训练用；
    有 cv2 时走 cv2.polylines（更贴近 yolopx 的 ll 头形态）。
    """
    H, W = size
    mask = np.zeros((H, W), dtype=np.uint8)
    if not isinstance(polys, (list, tuple)):
        polys = [polys]
    try:
        import cv2  # 可选依赖
        pts_all = []
        for poly in polys:
            if not isinstance(poly, (list, tuple)) or len(poly) < 2:
                continue
            pts = np.array([[int(round(float(x) * (W - 1))),
                             int(round(float(y) * (H - 1)))] for x, y in poly],
                           dtype=np.int32)
            pts_all.append(pts)
        if pts_all:
            cv2.polylines(mask, pts_all, False, 255, thickness)
        return (mask > 0).astype(np.float32)[None, :, :]
    except ImportError:
        pass

    r = max(1, thickness // 2)
    for poly in polys:
        if not isinstance(poly, (list, tuple)) or len(poly) < 2:
            continue
        pts = [(int(round(float(x) * (W - 1))), int(round(float(y) * (H - 1))))
               for x, y in poly]
        for (x0, y0), (x1, y1) in zip(pts[:-1], pts[1:]):
            steps = max(abs(x1 - x0), abs(y1 - y0), 1)
            for s in range(steps + 1):
                x = int(round(x0 + (x1 - x0) * s / steps))
                y = int(round(y0 + (y1 - y0) * s / steps))
                mask[max(0, y - r):min(H, y + r + 1),
                     max(0, x - r):min(W, x + r + 1)] = 255
    return (mask > 0).astype(np.float32)[None, :, :]


def _load_detections(clip_dir: Path, frame_no: int, n_slots: int
                     ) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, bool]:
    """读取检测框 → (boxes[N,4] 归一化 xyxy, scores[N], classes[N], mask[N], present)。

    优先级：
      1) detections/{frame:06d}.json  {"boxes":[[x1,y1,x2,y2]...], "scores":[...],
                                       "classes":[...], "w":W, "h":H}   像素坐标
      2) detections.npz               键 frame_{no} → [M,6] (x1,y1,x2,y2,score,cls)
    缺失 → 全 0 + mask 全 0（present=False），**不报错**。
    **超出 N 的框按 score 降序截断**；不足 N 的槽位 boxes/scores/classes 全 0，mask=0。
    """
    boxes = np.zeros((n_slots, 4), dtype=np.float32)
    scores = np.zeros(n_slots, dtype=np.float32)
    classes = np.zeros(n_slots, dtype=np.int64)
    mask = np.zeros(n_slots, dtype=np.float32)

    raw: Optional[np.ndarray] = None      # [M, 6] → x1,y1,x2,y2,score,cls（像素坐标）
    src_wh: Optional[Tuple[float, float]] = None

    pj = clip_dir / _DET_CACHE_DIR / f"{frame_no:06d}.json"
    if pj.exists():
        try:
            d = json.loads(pj.read_text())
            b = d.get("boxes") or []
            if b:
                s = d.get("scores") or [1.0] * len(b)
                c = d.get("classes") or [0] * len(b)
                m = min(len(b), len(s), len(c))
                raw = np.array(
                    [[*b[i][:4], float(s[i]), float(c[i])] for i in range(m)],
                    dtype=np.float32)
                src_wh = (float(d.get("w") or 0.0), float(d.get("h") or 0.0))
        except (json.JSONDecodeError, OSError, TypeError, ValueError, IndexError):
            raw = None

    if raw is None:
        npz = clip_dir / "detections.npz"
        if npz.exists():
            try:
                with np.load(npz) as z:
                    for key in (f"frame_{frame_no}", str(frame_no)):
                        if key in z:
                            raw = np.asarray(z[key], dtype=np.float32).reshape(-1, 6)
                            break
            except (OSError, ValueError, KeyError):
                raw = None

    if raw is None or len(raw) == 0:
        return boxes, scores, classes, mask, False

    # 丢弃退化框（宽或高 <= 0，例如 y1==y2==0 的零面积框）。
    # 实测 yolopx det 头在低置信度下会吐出这类框，直接喂给模型会污染回归目标。
    wh = raw[:, 2:4] - raw[:, 0:2]
    raw = raw[(wh[:, 0] > 0) & (wh[:, 1] > 0)]
    if len(raw) == 0:
        return boxes, scores, classes, mask, False

    # 按 score 降序，超出槽位数截断
    order = np.argsort(-raw[:, 4])
    raw = raw[order][:n_slots]

    # 归一化到 [0,1]：JSON 自带 w/h 时按源尺寸归一；否则假定已是归一化坐标
    if src_wh is not None and src_wh[0] > 1.0 and src_wh[1] > 1.0:
        raw[:, 0] /= src_wh[0]
        raw[:, 2] /= src_wh[0]
        raw[:, 1] /= src_wh[1]
        raw[:, 3] /= src_wh[1]
    elif raw[:, :4].max() > 1.0:
        # 没有尺寸信息但坐标明显是像素 → 按 640×360 兜底并告警一次
        raw[:, 0] /= 640.0
        raw[:, 2] /= 640.0
        raw[:, 1] /= 360.0
        raw[:, 3] /= 360.0

    m = len(raw)
    boxes[:m] = np.clip(raw[:, :4], 0.0, 1.0)
    scores[:m] = raw[:, 4]
    classes[:m] = raw[:, 5].astype(np.int64)
    mask[:m] = 1.0
    return boxes, scores, classes, mask, True


# ==================================================================================
# 数据集主体
# ==================================================================================
class MultiTaskClipsDataset(Dataset):
    """多任务片段数据集：图像 + 车道线 + 检测框 + 车辆状态。

    参数
    ----
    clips_dir        : data/raw_clips 之类的目录（扫 clip_* 子目录）
    image_size       : (H, W)，默认 (180, 320)，与 mono_dataset 一致
    num_dets         : 检测框固定槽位数 N（padding 目标），默认 20
    augment          : 亮度/对比度抖动（不做水平翻转——翻转会同时改变车道线几何，
                       本文件不实现翻转以保持 lane_mask 与 steer 语义自洽）
    view_filter      : "FPV"/"TPV"/"MENU"，只保留对应视角 clip
    heading_unit     : "auto"|"rad"|"deg"，见模块 docstring
    default_fps      : 缺 t_sec 时用于推 dt
    require_active_control : True 时只保留 steer/throttle/brake 非全零的帧
                       （⚠ 当前 5 个 clip 全零，开启后会得到空数据集）
    allow_empty      : True 时数据集为空只告警不抛异常（默认，避免像
                       mono_dataset 那样直接 RuntimeError）
    strict           : True 时任何缺失字段都抛异常（默认 False = 全程降级）
    """

    def __init__(
        self,
        clips_dir: str | Path,
        image_size: Tuple[int, int] = DEFAULT_IMAGE_SIZE,
        num_dets: int = DEFAULT_DET_N,
        augment: bool = False,
        view_filter: Optional[str] = None,
        heading_unit: str = "auto",
        default_fps: float = DEFAULT_FPS,
        require_active_control: bool = False,
        allow_empty: bool = True,
        strict: bool = False,
        lane_grid: int = LANE_GRID,
        strict_lane_geometry: bool = False,
        seed: int = 42,
    ):
        self.clips_dir = Path(clips_dir)
        self.image_size = tuple(image_size)   # (H, W)
        self.num_dets = int(num_dets)
        self.augment = augment
        self.view_filter = view_filter
        self.heading_unit = heading_unit
        self.default_fps = default_fps
        self.strict = strict
        # ★ 车道线几何口径：输出网格边长（= Swift maskGridSize）
        self.lane_grid = int(lane_grid)
        # ★ True 时缓存尺寸不合 letterbox 口径即抛错，而非降级
        self.strict_lane_geometry = bool(strict_lane_geometry)
        self.rng = random.Random(seed)

        self.index: List[Tuple[Path, str, Dict[str, Any]]] = []
        self.diags: Dict[str, Dict[str, Any]] = {}

        clips = _list_clips(self.clips_dir)
        if not clips:
            raise RuntimeError(f"未在 {self.clips_dir} 找到任何 clip_* 目录")

        if view_filter:
            clips = [c for c in clips if _clip_view(c) == view_filter]
            if not clips:
                raise RuntimeError(f"没有 view={view_filter} 的 clip")

        n_lane = n_det = 0
        for clip in clips:
            rows, fmt, diag = _load_controls_csv(
                clip / "controls.csv", clip, self.heading_unit, self.default_fps)
            self.diags[clip.name] = diag
            for row in rows:
                if require_active_control and row["steer"] == 0.0 \
                        and row["throttle"] == 0.0 and row["brake"] == 0.0:
                    continue
                if _frame_path(clip, fmt, row["frame_no"]) is None:
                    continue
                # 预探测缓存是否存在（只做统计用，实际读取在 __getitem__）
                fno = row["frame_no"]
                if (clip / _LANE_CACHE_DIR / f"{fno:06d}.png").exists() \
                        or (clip / "lane_masks.npz").exists() \
                        or (clip / "lanes.json").exists() \
                        or (clip / "lane_poly.json").exists():
                    n_lane += 1
                if (clip / _DET_CACHE_DIR / f"{fno:06d}.json").exists() \
                        or (clip / "detections.npz").exists():
                    n_det += 1
                self.index.append((clip, fmt, row))

        self.n_with_lane = n_lane
        self.n_with_det = n_det

        if not self.index:
            msg = (f"[DatasetV2] {self.clips_dir} 无可用样本"
                   f"（require_active_control={require_active_control}）")
            if allow_empty:
                print("⚠️  " + msg)
            else:
                raise RuntimeError(msg)

        if strict and (n_lane == 0 or n_det == 0):
            raise RuntimeError(
                f"strict=True 但缓存缺失：lane={n_lane} det={n_det}。"
                f"请先运行 backfill_lane_masks()/backfill_detections()")

        print(f"[DatasetV2] 加载 {len(self.index)} 样本，来自 {len(clips)} 个 clip "
              f"（车道线缓存 {n_lane}，检测缓存 {n_det}，"
              f"格式 {sorted({d['format'] for d in self.diags.values()})}）")
        if n_lane == 0:
            print("⚠️  [DatasetV2] 无车道线缓存 → lane_mask 全 0 降级。"
                  "录制端未存车道线，请先跑 backfill_lane_masks()")
        if n_det == 0:
            print("⚠️  [DatasetV2] 无检测框缓存 → det_mask 全 0 降级。"
                  "录制端未存检测框，请先跑 backfill_detections()")

    def __len__(self) -> int:
        return len(self.index)

    def __getitem__(self, idx: int) -> Dict[str, torch.Tensor]:
        clip_dir, fmt, row = self.index[idx]
        fno = row["frame_no"]

        img_path = _frame_path(clip_dir, fmt, fno)
        if img_path is None:
            raise RuntimeError(f"图像缺失: clip={clip_dir.name} frame={fno}")

        # ---- 图像：与 mono_dataset 完全一致的预处理 ----
        with Image.open(img_path) as im:
            im = im.convert("RGB").resize(
                (self.image_size[1], self.image_size[0]), Image.BILINEAR)
            img = np.asarray(im, dtype=np.float32) / 255.0

        steer = float(row["steer"])
        if self.augment:
            img = self._augment(img)
        img = np.transpose(img, (2, 0, 1)).copy()

        # ---- 车道线（★ letterbox 口径 grid×grid，与 Swift MaskGrid 逐位同口径）----
        lane, lane_present = _load_lane_mask(
            clip_dir, fno, self.image_size, grid=self.lane_grid,
            strict_geometry=self.strict_lane_geometry)

        # ---- 检测框（变长 → padding + mask）----
        boxes, scores, classes, det_mask, det_present = _load_detections(
            clip_dir, fno, self.num_dets)

        if self.strict and not (lane_present and det_present):
            raise RuntimeError(
                f"strict=True 但字段缺失: clip={clip_dir.name} frame={fno} "
                f"lane={lane_present} det={det_present}")

        return {
            "image": torch.from_numpy(img),
            "lane_mask": torch.from_numpy(lane),
            "lane_present": torch.tensor([1.0 if lane_present else 0.0],
                                         dtype=torch.float32),
            "det_boxes": torch.from_numpy(boxes),
            "det_scores": torch.from_numpy(scores),
            "det_classes": torch.from_numpy(classes),
            "det_mask": torch.from_numpy(det_mask),
            "det_present": torch.tensor([1.0 if det_present else 0.0],
                                        dtype=torch.float32),
            "vehicle_state": torch.from_numpy(row["vehicle_state"].copy()),
            "vehicle_state_mask": torch.from_numpy(row["vehicle_state_mask"].copy()),
            "steer": torch.tensor([steer], dtype=torch.float32),
            "throttle": torch.tensor([float(row["throttle"])], dtype=torch.float32),
            "brake": torch.tensor([float(row["brake"])], dtype=torch.float32),
            "frame_no": torch.tensor([fno], dtype=torch.int64),
        }

    # ---- 增强（只做亮度/对比度；不做翻转，避免 lane_mask 与 steer 语义打架）----
    def _augment(self, img: np.ndarray) -> np.ndarray:
        delta = self.rng.uniform(-_AUG_BRIGHTNESS, _AUG_BRIGHTNESS)
        img = np.clip(img + delta, 0.0, 1.0).astype(np.float32)
        factor = 1.0 + self.rng.uniform(-_AUG_CONTRAST, _AUG_CONTRAST)
        mean = img.mean()
        return np.clip((img - mean) * factor + mean, 0.0, 1.0).astype(np.float32)

    # ---- 数据现状报告（如实说明有什么、缺什么）----
    def coverage_report(self) -> Dict[str, Any]:
        """返回当前数据集的字段覆盖情况，用于「如实报告数据现状」。"""
        n = max(1, len(self.index))
        has_speed = sum(1 for d in self.diags.values() if d["has_speed"])
        has_head = sum(1 for d in self.diags.values() if d["has_heading"])
        has_curv = sum(1 for d in self.diags.values() if d["has_curvature"])
        accel_ok = sum(d["n_accel_ok"] for d in self.diags.values())
        accel_bad_dt = sum(d["n_accel_rejected_dt"] for d in self.diags.values())
        accel_clamped = sum(d["n_accel_clamped"] for d in self.diags.values())
        return {
            "clips": len(self.diags),
            "samples": len(self.index),
            "formats": sorted({d["format"] for d in self.diags.values()}),
            "clips_with_speed_kmh": has_speed,
            "clips_with_heading": has_head,
            "clips_with_curvature": has_curv,
            "heading_units": sorted({str(d["heading_unit"]) for d in self.diags.values()}),
            "samples_with_lane_cache": self.n_with_lane,
            "samples_with_det_cache": self.n_with_det,
            "lane_coverage": self.n_with_lane / n,
            "det_coverage": self.n_with_det / n,
            "accel_frames_ok": accel_ok,
            "accel_frames_rejected_bad_dt": accel_bad_dt,
            "accel_frames_clamped": accel_clamped,
            "drivable_area": "NOT_OUTPUT（本加载器不产出可行驶区域）",
        }


# ==================================================================================
# collate：固定 N，直接 stack 即可（保留 mask 供 loss 忽略空位）
# ==================================================================================
def collate_v2(batch: List[Dict[str, torch.Tensor]]) -> Dict[str, torch.Tensor]:
    """默认 collate。N 固定，故所有张量可直接 stack。"""
    out: Dict[str, torch.Tensor] = {}
    for k in batch[0]:
        out[k] = torch.stack([b[k] for b in batch], dim=0)
    return out


# ==================================================================================
# 训练/验证划分（按 clip 边界，避免同 clip 帧泄漏）
# ==================================================================================
def make_train_val_split(
    dataset: MultiTaskClipsDataset,
    val_ratio: float = 0.1,
    seed: int = 42,
) -> Tuple[Any, Any]:
    """按 clip 边界划分；有效 clip < 4 时退化为按帧随机划分。"""
    clip_counts: Dict[Path, int] = {}
    for c, *_ in dataset.index:
        clip_counts[c] = clip_counts.get(c, 0) + 1
    active = [c for c, k in clip_counts.items() if k > 0]

    if len(active) >= 4:
        rng = random.Random(seed)
        rng.shuffle(active)
        n_val = max(1, int(len(active) * val_ratio))
        if n_val >= len(active):
            n_val = len(active) - 1
        val_clips = set(active[:n_val])
        train_idx = [i for i, (c, *_) in enumerate(dataset.index) if c not in val_clips]
        val_idx = [i for i, (c, *_) in enumerate(dataset.index) if c in val_clips]
        if val_idx:
            print(f"[DatasetV2] 按 clip 划分: train={len(train_idx)} val={len(val_idx)}")
            return (torch.utils.data.Subset(dataset, train_idx),
                    torch.utils.data.Subset(dataset, val_idx))

    n = len(dataset)
    n_val = max(1, int(n * val_ratio)) if n > 0 else 0
    g = torch.Generator().manual_seed(seed)
    perm = torch.randperm(n, generator=g).tolist() if n > 0 else []
    val_set = set(perm[:n_val])
    train_idx = [i for i in range(n) if i not in val_set]
    val_idx = list(val_set)
    print(f"[DatasetV2] 按帧随机划分: train={len(train_idx)} val={len(val_idx)}")
    return (torch.utils.data.Subset(dataset, train_idx),
            torch.utils.data.Subset(dataset, val_idx))


# ==================================================================================
# 离线补算：车道线 / 检测框（录制时没存，必须回填）
# ==================================================================================
def _load_yolopx(imgsz: int = 640, ckpt: Optional[Path] = None):
    """懒加载 yolopx 模型（仅补算时用，数据集本身不依赖 torch-yolopx）。

    复用仓库既有的导出脚本（已处理 PSA_p 静态尺寸补丁 + YOLOX 非原地 decode）。
    返回 (net, letterbox_rgb, imgsz)。
    """
    import sys
    root = Path(__file__).resolve().parent.parent
    yx = root / "tools" / "yolopx"
    if not yx.exists():
        raise RuntimeError(f"找不到 yolopx：{yx}")
    if str(yx) not in sys.path:
        sys.path.insert(0, str(yx))
    from export_yolopx_coreml import build            # noqa: E402
    from verify_yolopx_coreml import letterbox_rgb    # noqa: E402

    net = build(imgsz)[0]   # build() 返回 (model, traced, shapes)
    print("[DatasetV2] yolopx 加载完成（imgsz=%d）" % imgsz)
    return net, letterbox_rgb, imgsz


def _yolopx_forward(net, letterbox_rgb, img_path: Path, imgsz: int):
    """单帧前向 → (det[8400,6], ll[2,H,W])。

    ⛔ **显式丢弃 da（可行驶区域）头**：`out[1]` 在这里被直接忽略，
       本函数只返回 det 与 ll，确保可行驶区域不会被写进任何缓存。
    """
    import torch

    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)

    rgb = letterbox_rgb(Path(img_path), imgsz)
    x = rgb.astype(np.float32) / 255.0
    x = (x - mean) / std
    x = torch.from_numpy(np.ascontiguousarray(x.transpose(2, 0, 1))) \
        .unsqueeze(0).float()
    with torch.no_grad():
        out = net(x)
    det = out[0]
    if isinstance(det, (tuple, list)):
        det = det[0]
    det = det[0].numpy() if hasattr(det, "numpy") else np.asarray(det)[0]
    ll = out[2]
    ll = ll[0].numpy() if hasattr(ll, "numpy") else np.asarray(ll)[0]
    # out[1]（da，可行驶区域）被有意丢弃 —— 本数据集不需要
    return det, ll


def _nms_numpy(boxes: np.ndarray, scores: np.ndarray, iou_thres: float) -> np.ndarray:
    """纯 numpy NMS，返回保留下标（按分数降序）。"""
    if len(boxes) == 0:
        return np.empty(0, dtype=np.int64)
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = np.maximum(0.0, x2 - x1) * np.maximum(0.0, y2 - y1)
    order = scores.argsort()[::-1]
    keep: List[int] = []
    while order.size > 0:
        i = order[0]
        keep.append(int(i))
        if order.size == 1:
            break
        rest = order[1:]
        xx1 = np.maximum(x1[i], x1[rest])
        yy1 = np.maximum(y1[i], y1[rest])
        xx2 = np.minimum(x2[i], x2[rest])
        yy2 = np.minimum(y2[i], y2[rest])
        inter = np.maximum(0.0, xx2 - xx1) * np.maximum(0.0, yy2 - yy1)
        iou = inter / np.maximum(areas[i] + areas[rest] - inter, 1e-9)
        order = rest[iou <= iou_thres]
    return np.array(keep, dtype=np.int64)


def backfill_lane_masks(
    clips_dir: str | Path,
    imgsz: int = 640,
    overwrite: bool = False,
    limit: Optional[int] = None,
    grid: int = LANE_GRID,
) -> Dict[str, int]:
    """【离线补算】用 yolopx 的 **ll 车道线头** 对录制帧跑一遍，落盘车道线掩码。

    为什么需要：录制端（RecordEngine.swift）**没有存车道线**，只存了
    frames/ + controls.csv + view.txt + meta.json。所以 lane_mask 必须事后补算。

    落盘：{clip}/lane_mask/{frame:06d}.png   uint8 0/255（1=车道线）
    模型：models/yolopx/yolopx_epoch195.pth，输入 640×640 letterbox + ImageNet 归一化，
          取 `ll` 头；**`da`（可行驶区域）头被显式丢弃**。

    ★ 几何口径（2026-10-08 修复）
    ----------------------------------------------------------------
    落盘的掩码是 **grid×grid（默认 160×160）**，通过 `logits_to_grid()` 产出，
    逐行复刻 Swift `YolopxEngine.extractMask()`：
        1) 在 640 上算 `ch1 > ch0`
        2) 对每个 4×4 块做多数表决 → grid×grid
    ⟹ 与运行时 `MaskGrid` **逐位同口径**（Swift 真跑对拍：25600 像素 0 差异）。

    ⛔ 修复前的行为：存 640 全分辨率 `argmax`，再由加载器 `resize` 到相机空间
       —— 几何错位最多 35 格（网格高度 21.9%）。现在存 grid 网格，加载器原样读取，
       **不做任何 resize**。

    ⚠️ 这是**伪标签**（yolopx 预测），不是人工标注，存在域偏差，训练时建议给较低权重。
    """
    from PIL import Image as _Image

    net, letterbox_rgb, imgsz = _load_yolopx(imgsz)
    if imgsz % grid != 0:
        raise ValueError(
            f"backfill_lane_masks: imgsz={imgsz} 不能被 grid={grid} 整除，"
            f"无法复刻 Swift 的多数表决降采样")
    stats = {"clips": 0, "frames": 0, "skipped": 0, "empty_frames": 0}
    for clip in _list_clips(Path(clips_dir)):
        fmt = _detect_format(_read_header(clip / "controls.csv"), clip)
        out_dir = clip / _LANE_CACHE_DIR
        out_dir.mkdir(exist_ok=True)
        n_done = 0
        for img_path in sorted((clip / "frames").iterdir()):
            if img_path.suffix.lower() not in (".jpg", ".jpeg", ".png"):
                continue
            if fmt == "v2_new" and not img_path.name.startswith("cam00_"):
                continue   # 10 cam 只取前向 cam00
            try:
                fno = int(img_path.stem.split("_")[-1])
            except ValueError:
                continue
            out_p = out_dir / f"{fno:06d}.png"
            if out_p.exists() and not overwrite:
                stats["skipped"] += 1
                continue
            det, ll = _yolopx_forward(net, letterbox_rgb, img_path, imgsz)
            # ★ 逐行复刻 Swift extractMask：(ch1>ch0) → 4×4 多数表决 → grid×grid
            g = logits_to_grid(ll, grid=grid)
            if g.sum() == 0:
                stats["empty_frames"] += 1
            _Image.fromarray((g * 255).astype(np.uint8)).save(out_p)
            n_done += 1
            stats["frames"] += 1
            if limit is not None and stats["frames"] >= limit:
                stats["clips"] += 1
                return stats
        stats["clips"] += 1
        print(f"[backfill_lane] {clip.name}: 新算 {n_done} 帧（{grid}×{grid} letterbox 口径）")
    if stats["empty_frames"]:
        print(f"[backfill_lane] ⚠ {stats['empty_frames']} 帧车道线全空"
              f"（隧道/逆光/标线磨损，或域偏差）")
    return stats


def backfill_detections(
    clips_dir: str | Path,
    imgsz: int = 640,
    conf_thres: float = 0.25,
    iou_thres: float = 0.45,
    max_det: int = 50,
    overwrite: bool = False,
    limit: Optional[int] = None,
) -> Dict[str, int]:
    """【离线补算】用 yolopx 的 **det 检测头** 生成检测框缓存。

    为什么需要：录制端同样**没有存检测框**。

    落盘：{clip}/detections/{frame:06d}.json
          {"boxes": [[x1,y1,x2,y2]...] 像素坐标, "scores": [...], "classes": [...],
           "w": W, "h": H}   （w/h 供加载器归一化）
    后处理：obj_conf × cls_conf → 阈值过滤 → NMS（纯 numpy 实现）。
    ⚠️ 同样是伪标签，且 yolopx 检测头类别集有限（以车辆为主），非人工标注。
    """
    net, letterbox_rgb, imgsz = _load_yolopx(imgsz)
    stats = {"clips": 0, "frames": 0, "boxes": 0, "skipped": 0}
    for clip in _list_clips(Path(clips_dir)):
        fmt = _detect_format(_read_header(clip / "controls.csv"), clip)
        out_dir = clip / _DET_CACHE_DIR
        out_dir.mkdir(exist_ok=True)
        n_done = 0
        for img_path in sorted((clip / "frames").iterdir()):
            if img_path.suffix.lower() not in (".jpg", ".jpeg", ".png"):
                continue
            if fmt == "v2_new" and not img_path.name.startswith("cam00_"):
                continue
            try:
                fno = int(img_path.stem.split("_")[-1])
            except ValueError:
                continue
            out_p = out_dir / f"{fno:06d}.json"
            if out_p.exists() and not overwrite:
                stats["skipped"] += 1
                continue

            det, _ll = _yolopx_forward(net, letterbox_rgb, img_path, imgsz)
            with Image.open(img_path) as im:
                W, H = im.size

            if det.ndim == 2 and det.shape[1] >= 6:
                boxes = det[:, :4].copy()
                scores = det[:, 4] * det[:, 5]      # obj_conf × cls_conf
                cls = det[:, 5]
                keep = scores > conf_thres
                boxes, scores, cls = boxes[keep], scores[keep], cls[keep]
                if len(boxes):
                    # cxcywh → xyxy
                    xyxy = np.empty_like(boxes)
                    xyxy[:, 0] = boxes[:, 0] - boxes[:, 2] / 2
                    xyxy[:, 1] = boxes[:, 1] - boxes[:, 3] / 2
                    xyxy[:, 2] = boxes[:, 0] + boxes[:, 2] / 2
                    xyxy[:, 3] = boxes[:, 1] + boxes[:, 3] / 2
                    # letterbox 坐标 → 原图坐标（等比缩放 + 居中 padding）
                    r = min(imgsz / H, imgsz / W)
                    pad_x = (imgsz - W * r) / 2.0
                    pad_y = (imgsz - H * r) / 2.0
                    xyxy[:, [0, 2]] = (xyxy[:, [0, 2]] - pad_x) / r
                    xyxy[:, [1, 3]] = (xyxy[:, [1, 3]] - pad_y) / r
                    xyxy[:, [0, 2]] = np.clip(xyxy[:, [0, 2]], 0, W)
                    xyxy[:, [1, 3]] = np.clip(xyxy[:, [1, 3]], 0, H)
                    k = _nms_numpy(xyxy, scores, iou_thres)[:max_det]
                    xyxy, scores, cls = xyxy[k], scores[k], cls[k]
                    # 再丢一次退化框：裁剪到图像边界后可能出现零面积框
                    wh = xyxy[:, 2:4] - xyxy[:, 0:2]
                    good = (wh[:, 0] > 1.0) & (wh[:, 1] > 1.0)
                    xyxy, scores, cls = xyxy[good], scores[good], cls[good]
                else:
                    xyxy = np.zeros((0, 4), dtype=np.float32)
            else:
                xyxy = np.zeros((0, 4), dtype=np.float32)
                scores = np.zeros(0, dtype=np.float32)
                cls = np.zeros(0, dtype=np.float32)

            out_p.write_text(json.dumps({
                "boxes": xyxy.round(2).tolist(),
                "scores": scores.round(4).tolist(),
                "classes": cls.astype(int).tolist(),
                "w": W, "h": H,
            }))
            n_done += 1
            stats["frames"] += 1
            stats["boxes"] += int(len(xyxy))
            if limit is not None and stats["frames"] >= limit:
                stats["clips"] += 1
                return stats
        stats["clips"] += 1
        print(f"[backfill_det] {clip.name}: 新算 {n_done} 帧")
    return stats


# ==================================================================================
# 数据质量审计（如实报告「到底有什么」）
# ==================================================================================
def audit_clips(clips_dir: str | Path, hash_frames: bool = True) -> Dict[str, Any]:
    """逐 clip 审计数据现状，返回结构化报告（不抛异常）。

    ⚠️ 2026-10-08 实测发现（本函数会自动报出来）：
       现有 5 个 clip 的 frames/*.jpg **是整屏桌面截图**，不是游戏前向画面——
       帧里含 macOS 菜单栏、Dock、其他应用窗口。根因见
       Sources/AuroraDrive/App/AuroraDriveApp.swift:7438
         `if isRecording, let image = currentScreenImage {`
       `currentScreenImage` 来自 CaptureEngine 的整屏捕获（非游戏窗口裁剪）。
       → 这类帧**不能直接用于训练**：图像与 steer 标签无因果对应关系。
       必须在录制端改为「游戏窗口区域裁剪」后重录，或对现有帧做窗口 ROI 裁剪。

    另外会报告：控制标签全零帧占比、重复帧、dt 分布（异常高频）、
    以及 lane/det 缓存是否存在。
    """
    import hashlib

    clips = _list_clips(Path(clips_dir))
    report: Dict[str, Any] = {"clips": [], "totals": {}}
    tot_frames = tot_zero = tot_dup = 0

    for clip in clips:
        header = _read_header(clip / "controls.csv")
        fmt = _detect_format(header, clip)
        rows, _fmt, diag = _load_controls_csv(
            clip / "controls.csv", clip, "auto", DEFAULT_FPS)

        frames_dir = clip / "frames"
        frames = sorted(p for p in frames_dir.iterdir()
                        if p.suffix.lower() in (".jpg", ".jpeg", ".png")) \
            if frames_dir.is_dir() else []

        zero_rows = sum(1 for r in rows if r["steer"] == 0.0
                        and r["throttle"] == 0.0 and r["brake"] == 0.0)

        dup = 0
        if hash_frames and frames:
            hs = [hashlib.md5(p.read_bytes()).hexdigest() for p in frames]
            dup = len(hs) - len(set(hs))

        dts: List[float] = []
        ts = [r["t_sec"] for r in rows if r["t_sec"] is not None]
        for a, b in zip(ts[:-1], ts[1:]):
            dts.append(b - a)
        dt_med = float(np.median(dts)) if dts else None

        meta: Dict[str, Any] = {}
        mp = clip / "meta.json"
        if mp.exists():
            try:
                meta = json.loads(mp.read_text())
            except (json.JSONDecodeError, OSError):
                meta = {}

        with Image.open(frames[0]) as _im0:
            frame_size = _im0.size
        report["clips"].append({
            "name": clip.name,
            "format": fmt,
            "header": header,
            "frames_on_disk": len(frames),
            "csv_rows": len(rows),
            "frame_size": frame_size if frames else None,
            "view": _clip_view(clip),
            "meta_resolution": (meta.get("target_w"), meta.get("target_h")),
            "zero_label_rows": zero_rows,
            "zero_label_ratio": (zero_rows / len(rows)) if rows else None,
            "duplicate_frames": dup,
            "dt_median_sec": dt_med,
            "implied_fps": (1.0 / dt_med) if dt_med else None,
            "has_speed_kmh": diag["has_speed"],
            "has_heading": diag["has_heading"],
            "has_curvature": diag["has_curvature"],
            "has_lane_cache": (clip / _LANE_CACHE_DIR).exists()
                              or (clip / "lane_masks.npz").exists()
                              or (clip / "lanes.json").exists(),
            "has_det_cache": (clip / _DET_CACHE_DIR).exists()
                             or (clip / "detections.npz").exists(),
        })
        tot_frames += len(frames)
        tot_zero += zero_rows
        tot_dup += dup

    report["totals"] = {
        "n_clips": len(clips),
        "frames_on_disk": tot_frames,
        "zero_label_rows": tot_zero,
        "duplicate_frames": tot_dup,
        "clips_with_lane_cache": sum(1 for c in report["clips"] if c["has_lane_cache"]),
        "clips_with_det_cache": sum(1 for c in report["clips"] if c["has_det_cache"]),
        "clips_with_speed": sum(1 for c in report["clips"] if c["has_speed_kmh"]),
        "clips_with_heading": sum(1 for c in report["clips"] if c["has_heading"]),
        "clips_with_curvature": sum(1 for c in report["clips"] if c["has_curvature"]),
        "formats": sorted({c["format"] for c in report["clips"]}),
    }
    return report


def print_audit(clips_dir: str | Path) -> None:
    """人类可读的数据现状报告。"""
    rep = audit_clips(clips_dir)
    print("=" * 88)
    print(f"数据审计 — {clips_dir}")
    print("=" * 88)
    for c in rep["clips"]:
        ratio = 0.0 if c["zero_label_ratio"] is None else c["zero_label_ratio"] * 100
        fps = c["implied_fps"]
        print(f"\n■ {c['name']}  [{c['format']}]  view={c['view']}")
        print(f"   帧文件 {c['frames_on_disk']} / CSV 行 {c['csv_rows']}"
              f" / 尺寸 {c['frame_size']} / meta {c['meta_resolution']}")
        print(f"   表头: {c['header']}")
        print(f"   全零控制帧 {c['zero_label_rows']}（{ratio:.0f}%）"
              f" / 重复帧 {c['duplicate_frames']}")
        print(f"   dt 中位 {c['dt_median_sec']}"
              f"{'' if fps is None else f' → {fps:.1f} Hz'}")
        print(f"   speed={c['has_speed_kmh']} heading={c['has_heading']} "
              f"curvature={c['has_curvature']} "
              f"lane缓存={c['has_lane_cache']} det缓存={c['has_det_cache']}")
    t = rep["totals"]
    print("\n" + "-" * 88)
    print(f"合计: {t['n_clips']} clip / {t['frames_on_disk']} 帧 / "
          f"全零控制帧 {t['zero_label_rows']} / 重复帧 {t['duplicate_frames']}")
    print(f"      speed={t['clips_with_speed']}/{t['n_clips']} "
          f"heading={t['clips_with_heading']}/{t['n_clips']} "
          f"curvature={t['clips_with_curvature']}/{t['n_clips']} "
          f"lane缓存={t['clips_with_lane_cache']}/{t['n_clips']} "
          f"det缓存={t['clips_with_det_cache']}/{t['n_clips']}")
    print("-" * 88)
    print("⚠️  已知问题：现有帧为整屏桌面截图（含菜单栏/Dock/其他窗口），")
    print("    非游戏前向画面 → 图像与 steer 无因果对应，不宜直接训练。")
    print("    详见 dataset_v2.audit_clips() docstring。")
    print("=" * 88)


# ==================================================================================
# 自检：python src/dataset_v2.py
# ==================================================================================
if __name__ == "__main__":
    import sys

    root = Path(__file__).resolve().parent.parent
    clips = root / "data" / "raw_clips"
    print("=" * 78)
    print("dataset_v2 自检 —", clips)
    print("=" * 78)

    print_audit(clips)

    ds = MultiTaskClipsDataset(clips, allow_empty=True)
    print(f"\n样本数: {len(ds)}")
    print("\n覆盖情况:")
    for k, v in ds.coverage_report().items():
        print(f"  {k:34s} = {v}")

    if len(ds) > 0:
        s = ds[0]
        print("\n单样本输出规格:")
        for k, v in s.items():
            if isinstance(v, torch.Tensor):
                extra = ""
                if v.dtype.is_floating_point and v.numel() > 1:
                    extra = f"  min={v.min():.3f} max={v.max():.3f}"
                print(f"  {k:20s} {str(tuple(v.shape)):12s} {str(v.dtype):14s}{extra}")
        print("\nvehicle_state 布局:")
        for name, i in sorted(STATE_LAYOUT.items(), key=lambda kv: kv[1]):
            print(f"  [{i}] {name:20s} = {s['vehicle_state'][i].item():+.4f}"
                  f"   mask={s['vehicle_state_mask'][i].item():.0f}")

        b = collate_v2([ds[i] for i in range(min(4, len(ds)))])
        print("\ncollate 后 batch:")
        for k, v in b.items():
            print(f"  {k:20s} {tuple(v.shape)}")
    print("\n自检结束。")
