#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dataset_v3.py — V3 纯按键数据集（离散按键标签，无连续量）

设计原则（对应用户需求「直接输出 WASD 那种标签，而不是输出油门」）：
    CSV 每一列就是**一个真实按键的按下状态**，数据集直接把它变成 8 个输出头的
    监督目标，中间**不存在任何「连续量→按键」的阈值转换**。

数据契约（tools/aurora_recorder.c 2026-11-03 起产出的 10 列）：
    t_sec, frame, w, a, s, d, shift, space, super_brake, ultimate_brake

8 个输出头的目标（与 src/model_v3.py 的 V3Loss 契约一致）：
    vertical    [B]    long  0=W  1=NONE  2=S
    horizontal  [B]    long  0=A  1=NONE  2=D
    handbrake   [B,1]  float 0/1   (= shift)
    brake       [B,1]  float 0/1   (= space)
    super_brake [B,1]  float 0/1   (= shift ∧ space)
    ultimate    [B,1]  float 0/1   (= shift ∧ space ∧ s)
    confidence  [B,1]  float 0..1  代理真值，见 _confidence_targets
    risk        [B,1]  float 0..1  代理真值，见 _risk_targets
    intent      [B]    long  0=GO 1=SLOW 2=STOP（仅训练用，见 03-output-head.md §3.3）

为什么 vertical 的归属要按「安全优先序」而不是简单查表：
    同一帧可能同时按 W 和 S（人类玩家会这么按）。直接取先出现的会静默丢信息。
    规则（03-output-head.md §4.4）：S（制动）> W（给油），因为「该停却给油」
    比「该走却停」危险得多。见 vertical_from_keys()。

为什么 horizontal 保留 A/D 同时按为 NONE：
    游戏内 A+D 相互抵消，映射成 NONE 是物理正确；且与录制端「不静默改写输入」
    的原则分工一致——录制端记录事实，训练侧做语义归约。

未测声明：
    · 本文件不产生任何精度结论。真实数据分布、类别不平衡比例必须在
      录到真实数据后用 --stats 统计回填，**不得用合成数据冒充**。
    · confidence / risk 均为**代理真值**（proxy），不是人工标注的接管/碰撞标签。
      详见 src/risk_head.py:1101-1112 已记录的局限。

用法：
    # 统计真实数据分布（录完数据先跑这个）
    python3 src/dataset_v3.py --stats data/raw_clips

    # 训练脚本里直接用
    from dataset_v3 import V3KeyDataset, make_train_val_split
"""

from __future__ import annotations

import argparse
import csv
import random
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import torch
from torch.utils.data import Dataset

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None

#: 录制器 2026-11-03 起的必需列（顺序无关）
REQUIRED_COLUMNS = [
    "t_sec", "frame", "w", "a", "s", "d",
    "shift", "space", "super_brake", "ultimate_brake",
]

#: 原子键列（用于校验组合键一致性）
ATOMIC_KEYS = ["w", "a", "s", "d", "shift", "space"]

#: 高清帧数。必须与 model_v3.V3Config.num_hi_frames 一致（默认 3）。
#: 24 帧窗口 = 3 高清(t,t−1,t−2) + 21 低清(t−3 … t−23)，总计 24 帧 @15Hz = 1.6s。
NUM_HI_FRAMES = 3

#: 窗口总帧数（高低清合计），用于与模型侧断言对齐。
NUM_TOTAL_FRAMES = 24

#: V3 时序设计假设的录制帧率。
#: 依据：部署端 tick 定档 15Hz（EngineMain.swift:709「tick（推理+控制+录制）：15Hz」），
#: V3 的 24 帧窗口按 15Hz 设计 = 1.6s（model_v3.py:274）。
#: 录制成其他帧率会让「24 帧覆盖多长时间」与部署时不一致，
#: 模型学到的时间动态尺度就是错的（10fps 下 24 帧跨 2.4s，动作看起来更慢）。
EXPECTED_FPS = 15

#: 允许的帧率偏差比例。真实录制会因截屏耗时抖动，实测 t_sec 差值不会严格等于 1/15。
FPS_TOLERANCE = 0.15


# ----------------------------------------------------------------------------
# 标签构造（纯函数，便于单测和 --stats 复用）
# ----------------------------------------------------------------------------

def _bit(row: Dict[str, str], key: str) -> int:
    """把 CSV 单元格读成 0/1。

    录制器写的是整数 0/1，但历史上也可能出现 "0.0"/"1.0"（旧版用 %.1f）。
    两种情况都要接受；其余值视为数据损坏并**显式报错**，不静默当成 0。

    ⚠️ 2026-11-03 修复（审查 P0-2）：旧实现用 `(row.get(key) or "")`，
       于是「列不存在」（`None`）与「值为 0」无法区分，全都返回 0。

       实测后果（审查报告）：表头写成 `t_sec,frame, w,a,...`（多空格）时，
       DictReader 的键是 `' w'`，`row.get("w")` 恒 None → 真实按下的
       W/A 全被读成「没按」→ vertical/horizontal 全变 NONE，
       日志里没有任何异常；行被截断时同理。

       本次改造的核心承诺就是「不要静默失败」，所以这里必须把
       「缺失」与「合法 0」彻底分开：缺列 → 抛异常，不返回 0。
    """
    if key not in row:
        # 注意：不能用 sorted(row.keys()) —— DictReader 在行内字段多于表头时
        # 会把多余字段塞进键 None，而 Python 3 的 sorted 对 None 与 str 混合会抛
        # TypeError，从而把「缺列」这个真实原因掩盖掉。这里保持原顺序并转成 str。
        actual = [str(k) for k in row.keys()][:12]
        raise ValueError(
            f"CSV 缺少列 {key!r}（实际列: {actual}）——"
            "通常是表头含多余空格，或数据行字段数不足")
    raw = row[key]
    if raw is None:
        raise ValueError(f"列 {key!r} 的值为 None（数据行字段数少于表头）")
    raw = raw.strip()
    if raw in ("0", "0.0"):
        return 0
    if raw in ("1", "1.0"):
        return 1
    if raw == "":
        raise ValueError(f"列 {key!r} 为空串（数据损坏；录制器不会写空串）")
    raise ValueError(f"列 {key!r} 的值非法: {raw!r}（应为 0/1）")


def vertical_from_keys(w: int, s: int) -> int:
    """纵向三分类：0=W / 1=NONE / 2=S，按安全优先序归约。

    S 优先于 W：同帧同时按 W 和 S 时判为 S（制动）。
    理由：把「真在刹车」误判成「给油」会让车往前冲，是危险方向；
         把「真在给油」误判成「刹车」只是偏保守。安全系统只允许保守方向的错。
    """
    if s:
        return 2
    if w:
        return 0
    return 1


def horizontal_from_keys(a: int, d: int) -> int:
    """横向三分类：0=A / 1=NONE / 2=D。

    A+D 同时按 → NONE（游戏内相互抵消，物理正确）。
    """
    if a and not d:
        return 0
    if d and not a:
        return 2
    return 1


def intent_from_keys(w: int, a: int, s: int, d: int, shift: int, space: int) -> int:
    """stage1 制动意图：0=GO / 1=SLOW / 2=STOP（仅训练用）。

    定义严格照 03-output-head.md §3.3：
        STOP(2)：按了 Space 或 S（真在制动/后退）
        SLOW(1)：按了 Shift（手刹），或「同时给油+转向」（转弯需减速）
        GO(0)  ：其余
    STOP 必须先判，否则「Shift+Space+S」会被 SLOW 抢走。
    """
    if space or s:
        return 2
    if shift or (w and (a or d)):
        return 1
    return 0


def validate_row(row: Dict[str, str], where: str) -> None:
    """校验一行数据的内部自洽性。

    组合键必须严格等于原子键的逻辑与。不一致说明录制器有 bug 或文件被改坏，
    必须显式报错——这种错误静默通过会直接毒化训练标签。
    """
    w, a, s, d = (_bit(row, k) for k in ("w", "a", "s", "d"))
    shift, space = _bit(row, "shift"), _bit(row, "space")
    super_brake, ultimate = _bit(row, "super_brake"), _bit(row, "ultimate_brake")

    if super_brake != (shift and space):
        raise ValueError(
            f"{where}: super_brake={super_brake} 但 shift={shift}, space={space} "
            "（组合键必须等于原子键逻辑与）"
        )
    if ultimate != (shift and space and s):
        raise ValueError(
            f"{where}: ultimate_brake={ultimate} 但 shift={shift}, space={space}, s={s}"
        )


# ----------------------------------------------------------------------------
# 代理真值（confidence / risk）
# ----------------------------------------------------------------------------

def _confidence_targets(control_matrix: np.ndarray, tau: float = 0.15) -> np.ndarray:
    """由「控制量的帧间变化」构造 confidence 代理真值（越小越该低置信）。

    语义对齐 src/risk_head.py:1128 的 `confidence_target_from_temporal_change`：
    控制状态变化大 = 高动态/转折场景 = 判断更难 = 该低置信。

    Args:
        control_matrix: [N, 6] 每帧的 6 个原子键（w,a,s,d,shift,space），0/1
        tau: 变化量到置信度的缩放。6 个键最大变化量是 6，用 tau=0.15 时
             单键变化约降 0.15 置信度。
    Returns:
        [N, 1] float32，值域 (0, 1]
    """
    n = len(control_matrix)
    conf = np.ones((n, 1), dtype=np.float32)
    if n < 2:
        return conf
    # 当前帧与上一帧的差异键个数（0..6）
    diff = np.abs(np.diff(control_matrix, axis=0)).sum(axis=1)  # [N-1]
    # 与前向差分对齐：第 i 帧的"变化"用 i 与 i-1 的差；首帧无历史，设 0
    conf[1:, 0] = np.exp(-tau * diff)
    return np.clip(conf, 0.05, 1.0)


def _risk_targets(control_matrix: np.ndarray) -> np.ndarray:
    """由「制动强度」构造 risk 代理真值。

    ⚠️ 这是**简化代理**，不是真正的 TTC（没有前车距离/相对速度）。
    真实 risk_target_from_ttc（src/risk_head.py:1183）需要 TTC，本项目当前
    **没有**该输入 → 这里只能用「是否在制动/极限制动」作为危险程度的近似：
        · ultimate_brake（Shift+Space+S）→ 1.0（最高危，正在极限制动）
        · super_brake（Shift+Space）     → 0.8
        · space 或 s（普通制动/后退）    → 0.5
        · 其余                            → 0.1（基线，不是 0——保持头不饱和）

    诚实声明：该代理无法区分「平静减速」与「紧急避险」，训练出的 risk 头
    只能当作「当前是否处于制动动作」的指示器，不能当作真实风险预测。
    已列入未测项（见模块 docstring）。
    """
    n = len(control_matrix)
    risk = np.full((n, 1), 0.1, dtype=np.float32)
    for i in range(n):
        w, a, s, d, shift, space = control_matrix[i]
        if shift and space and s:
            risk[i, 0] = 1.0
        elif shift and space:
            risk[i, 0] = 0.8
        elif space or s:
            risk[i, 0] = 0.5
    return risk


# ----------------------------------------------------------------------------
# 数据集
# ----------------------------------------------------------------------------

class V3KeyDataset(Dataset):
    """V3 纯按键数据集：clip 目录 → 8 头监督目标。

    目录结构（录制器产出）：
        clip_20261103_120000/
            frames/000000.jpg ...
            controls.csv
            view.txt（可选）

    每个样本返回：
        image_hi   [3, 224, 384]  当前帧（高清）
        image_lo   [21, 3, 112, 192]  前 21 帧（低清），不足则用最早帧填充
        lane       [1, 160, 160]  车道掩码（当前未从录制数据获得 → 零图）
        dets       [20, 12]       检测框（同上 → 零）
        det_mask   [20]           检测有效位（全 0）
        vehicle_state [8]
        + 8 个 target（见模块 docstring）

    ⚠️ lane / dets 目前是零填充：录制数据里没有这两路信息。V3 模型设计上
       接受它们（继承 V2 契约），但**用零填充训练会让这两个分支学不到东西**。
       这是一个已记录的未测/待解决项——需要录制器未来把车道掩码与检测框一并落盘。
    """

    def __init__(
        self,
        clips_dir: str | Path,
        image_size: Tuple[int, int] = (224, 384),
        lowres_size: Tuple[int, int] = (112, 192),
        history: int = 21,
        augment: bool = False,
        view_filter: Optional[str] = None,
        skip_all_zero: bool = True,
        seed: int = 42,
        expected_fps: Optional[float] = EXPECTED_FPS,
    ):
        if Image is None:
            raise RuntimeError("需要 Pillow：pip install pillow")

        self.clips_dir = Path(clips_dir)
        self.image_size = image_size
        self.lowres_size = lowres_size
        self.history = history
        self.augment = augment
        self.rng = random.Random(seed)
        self.expected_fps = expected_fps

        self.index: List[Tuple[Path, int]] = []
        self._rows_cache: Dict[Path, List[Dict[str, str]]] = {}
        #: clip → [N,6] 原子键矩阵缓存（算 confidence / risk 用；实例级）
        self._cm_cache: Dict[Path, np.ndarray] = {}
        self._build_index(view_filter=view_filter, skip_all_zero=skip_all_zero)

    # -- 索引 --------------------------------------------------------------

    def _build_index(self, view_filter: Optional[str], skip_all_zero: bool) -> None:
        """建立全局样本索引 [(clip_dir, frame_idx), ...]。

        ⚠️ 这里曾经写成「每个 clip 存 (clip, start, rows) 再在 _locate 里按
           start 区间查找」，且 start 恒为 0 —— 所有 clip 的区间完全重叠，
           DataLoader 一打乱顺序就 IndexError（实测崩在 idx=91）。

        现在改成**扁平的全局 (clip, frame_idx) 列表**：
            · 下标即 Dataset 的 __len__ 语义，天然无重叠、无错位
            · frame_idx 是**文件里的真实帧号**（不是 valid 列表下标），
              所以 skip_all_zero 跳帧不会让后续帧号错位
            · rows 按 clip 缓存，__getitem__ 需要整段序列算 confidence/risk 时直接取
        """
        clips = sorted(
            p for p in self.clips_dir.iterdir()
            if p.is_dir() and p.name.startswith("clip_")
        )
        if not clips:
            raise RuntimeError(f"{self.clips_dir} 下没有 clip_* 目录（还没录数据？）")

        n_skipped = 0
        for clip in clips:
            if view_filter is not None:
                vt = clip / "view.txt"
                if not vt.exists() or vt.read_text(encoding="utf-8").strip() != view_filter:
                    continue

            csv_path = clip / "controls.csv"
            frames_dir = clip / "frames"
            if not csv_path.exists() or not frames_dir.is_dir():
                continue

            rows = self._read_rows(csv_path)
            if not rows:
                continue

            # 帧率校验：不一致会让 V3 的时间尺度学错，且训练日志看不出来
            self._check_fps(clip, rows)

            # ── 帧存在性预扫描（2026-11-03 修复：缺帧会让训练中途崩）──
            #
            # ⚠️ 旧实现只检查**样本自身那一帧**是否存在（下行 if not exists: continue），
            #    但 `__getitem__` 要回溯 24 帧窗口（t, t−1, …, t−23）去 `Image.open`。
            #    只要窗口里**任何一帧**缺失，就会抛 FileNotFoundError 直接打断训练。
            # 实测（构造缺第 10 帧的 clip）：索引里有 29 个样本、不含 10，
            #    但 ds[11]/ds[12]/ds[20] 全部抛 FileNotFoundError —— 崩在训练循环里，
            #    而不是加载时。缺失来源很现实：RecordEngine 的 JPEG 编码万一失败，
            #    CSV 行照写、帧文件却没有。
            #
            # 修法：建索引时就按「整窗可用」判定，宁可少几个样本，也不在训练中途炸。
            #   不伪造/复制缺失帧填充 —— 时序窗口里塞重复帧会教出错误的时间动态。
            n_frames = len(rows)
            # 真实回看深度必须按构造参数算，不能写死 NUM_TOTAL_FRAMES：
            # __getitem__ 的窗口是 hi_idx(range(NUM_HI_FRAMES)) + lo_idx(range(self.history))，
            # 最深回看到 frame_idx - (NUM_HI_FRAMES + self.history - 1)。
            # history 是可配置参数（默认 21 → 深度 23），写死常量会在自定义 history 时误判。
            window_span = NUM_HI_FRAMES + self.history - 1

            # 一次扫描出全部缺失帧号（每个 clip 只 stat 一遍）
            missing_frames = {
                j for j in range(n_frames)
                if not (frames_dir / f"{j:06d}.jpg").exists()
            }

            n_dropped_missing = 0
            prev_missing = -1   # 截至第 i 帧（含）最近的一个缺失帧号
            for i, row in enumerate(rows):
                if i in missing_frames:
                    prev_missing = i
                # 样本 i 的窗口是 [max(0, i-window_span), i]（历史不足时 clamp 到第 0 帧）。
                # 判定必须用「截至 i 的最近缺失帧」，而不是全 clip 最后一个缺失帧 ——
                # 后者会把「缺失发生在样本之后」的正常样本也误删。
                if prev_missing >= 0 and prev_missing >= i - window_span:
                    n_dropped_missing += 1
                    continue
                if skip_all_zero and all(_bit(row, k) == 0 for k in ATOMIC_KEYS):
                    n_skipped += 1
                    continue
                self.index.append((clip, i))   # i = 真实帧号

            if n_dropped_missing:
                print(f"[V3KeyDataset] {clip.name}: 因帧文件缺失跳过 "
                      f"{n_dropped_missing}/{n_frames} 个样本"
                      f"（缺帧会破坏其之后 {window_span} 帧的时序窗口）")

            self._rows_cache[clip] = rows

        if not self.index:
            raise RuntimeError(
                f"所有 clip 均无有效样本（skip_all_zero={skip_all_zero}, "
                f"跳过全零帧 {n_skipped} 个）。检查录制数据是否为空或格式不符。"
            )

        # 统计：index 是扁平的全局 (clip, frame_idx)，样本数就是 len(index)；
        # clip 数用 rows 缓存的键数量，二者不能混用（旧版在这里解包三元组崩过）。
        print(f"[V3KeyDataset] {len(self._rows_cache)} 个 clip，{len(self.index)} 个样本"
              f"（跳过全零帧 {n_skipped}）")

    def _check_fps(self, clip: Path, rows: List[Dict[str, str]]) -> None:
        """校验该 clip 的实际帧率是否与 V3 时序假设一致。

        为什么必须在**加载阶段**炸掉、而不是训完再说：
            V3 的 24 帧窗口按 15Hz 设计（部署端 tick 也是 15Hz，见
            EngineMain.swift:709）。若数据实际是 10fps，同样 24 帧跨 2.4 秒
            而不是 1.6 秒 —— 模型学到的时间尺度是错的，但 **loss 曲线完全正常**，
            日志里看不出任何异常，只有上车后表现为"刹车偏晚"。这类错误无法在
            训练过程中被发现，只能在数据入口拦。

        为什么用 t_sec 实数差而不是 clip.json 里的 "fps" 字段：
            clip.json 是录制器自己写的**声明值**，可能过时、可能被手改；
            t_sec 是每帧真实时钟差值，造不了假。两者冲突时以 t_sec 为准。

        Args:
            clip: clip 目录（仅用于报错定位）
            rows: 该 clip 的全部 CSV 行
        """
        if self.expected_fps is None or len(rows) < 2:
            return  # 显式关闭校验 / 样本太少（如只录几帧）无法估计

        try:
            ts = [float(r["t_sec"]) for r in rows]
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{clip}/controls.csv 的 t_sec 列含非数值: {exc}") from exc

        dts = [b - a for a, b in zip(ts, ts[1:]) if b > a]
        if not dts:
            return  # 时间戳未前进（异常，但由别处负责报），此处不重复抛
        median_dt = statistics.median(dts)
        if median_dt <= 0:
            return

        actual_fps = 1.0 / median_dt
        if abs(actual_fps - self.expected_fps) / self.expected_fps > FPS_TOLERANCE:
            raise ValueError(
                f"{clip}/controls.csv 的实际帧率约 {actual_fps:.1f}fps，"
                f"与 V3 假设的 {self.expected_fps:.0f}fps 不符（容差 {FPS_TOLERANCE:.0%}）。\n"
                "  V3 的 24 帧窗口按 15Hz 设计（=1.6s）；帧率不同会让模型学到的时间尺度错误。\n"
                "  处理：用 `--fps 15` 重录，或确认这是有意为之则传 expected_fps=None 关闭校验。"
            )

    @staticmethod
    def _read_rows(csv_path: Path) -> List[Dict[str, str]]:
        """读 controls.csv 并做格式 + 自洽性校验。"""
        with open(csv_path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            header = [c.strip() for c in (reader.fieldnames or [])]
            missing = [c for c in REQUIRED_COLUMNS if c not in header]
            if missing:
                raise ValueError(
                    f"{csv_path} 缺少必需列 {missing}\n"
                    f"  实际表头: {header}\n"
                    "  V3 需要录制器 2026-11-03 之后的纯按键格式；"
                    "旧格式请用 keylog.csv 重建或重录。"
                )
            rows = list(reader)

        for i, row in enumerate(rows):
            validate_row(row, where=f"{csv_path.name} 第 {i + 2} 行")
            # ── frame 列必须与行号严格一致（审查 P0-4）──
            # 为什么必须有：__getitem__ 用**行号 i** 去拼 frames/{i:06d}.jpg，
            # 却从不读 frame 列。若 CSV 行序与帧文件错位（合并/截断/人工修复/
            # 非录制器产物），就会得到「图是第 k 帧、标签是第 m 帧」——
            # **训练目标整体错位**且不报错。这是最隐蔽的数据污染形式。
            #
            # 实测反证（审查报告）：把 frame 列写成 99,98,97,96、文件名仍是
            # 000000..000003，旧实现照样返回 4 个样本、无任何告警。
            raw_frame = row.get("frame")
            if raw_frame is None:
                raise ValueError(f"{csv_path} 第 {i + 2} 行缺少 frame 列")
            try:
                frame_val = int(str(raw_frame).strip())
            except ValueError as exc:
                raise ValueError(
                    f"{csv_path} 第 {i + 2} 行 frame 列非整数: {raw_frame!r}") from exc
            if frame_val != i:
                raise ValueError(
                    f"{csv_path} 第 {i + 2} 行 frame={frame_val}，但它是第 {i} 个数据行"
                    f"（0 基，应为 {i}）。\n"
                    "  CSV 行序与帧文件编号已错位 → 图像与标签会整体错配。\n"
                    "  这通常是文件被合并/截断/人工编辑过，不是录制器原始产物。")
        return rows

    # -- Dataset 协议 ------------------------------------------------------

    def __len__(self) -> int:
        return len(self.index)

    def _locate(self, idx: int) -> Tuple[Path, int]:
        """全局索引 → (clip, 真实帧号)。

        索引是扁平的全局列表（见 _build_index 的说明），直接查表即可；
        不做区间扫描，从根本上消除旧版「start 恒为 0 导致区间重叠」的 bug。
        """
        if not (0 <= idx < len(self.index)):
            raise IndexError(f"索引越界: {idx}（数据集大小 {len(self.index)}）")
        return self.index[idx]

    def __getitem__(self, idx: int) -> Dict[str, torch.Tensor]:
        clip, frame_idx = self._locate(idx)
        rows = self._rows_cache[clip]
        frames_dir = clip / "frames"

        def load_frame(fi: int, size: Tuple[int, int]) -> np.ndarray:
            path = frames_dir / f"{fi:06d}.jpg"
            with Image.open(path) as im:
                im = im.convert("RGB").resize((size[1], size[0]), Image.BILINEAR)
                arr = np.asarray(im, dtype=np.float32) / 255.0
            if self.augment:
                arr = self._augment_brightness(arr)
            return np.transpose(arr, (2, 0, 1)).copy()

        # ---- 24 帧窗口：3 帧高清 + 21 帧低清，**最新帧在前** ----
        #
        # ⚠️ 帧顺序必须与 model_v3 的约定严格一致，否则模型学到的时间方向是反的。
        # 模型侧约定（见 V3Model._encode_hi 与 TemporalModuleV3 的 docstring）：
        #     image_hi[B,T,3,H,W]  索引 0 = 当前帧 t，1 = t−1，2 = t−2
        #     image_lo[B,T,3,H,W]  索引 0 = t−3，依此类推
        # 即整个 24 帧窗口是 [t, t−1, t−2, ..., t−23] —— **倒序（新→旧）**。
        # 曾经写成 range(21,0,-1)（旧→新），会让"踩油门后车前进"被学成相反因果。
        clamp_frame = lambda fi: max(0, fi)  # noqa: E731 — 历史不足时用最早帧填充

        hi_idx = [clamp_frame(frame_idx - k) for k in range(NUM_HI_FRAMES)]
        lo_idx = [clamp_frame(frame_idx - NUM_HI_FRAMES - k)
                  for k in range(self.history)]

        image_hi = np.stack(
            [load_frame(fi, self.image_size) for fi in hi_idx], axis=0
        )                                                                # [3,3,H,W]
        image_lo = np.stack(
            [load_frame(fi, self.lowres_size) for fi in lo_idx], axis=0
        )                                                                # [21,3,h,w]

        row = rows[frame_idx]
        vals = {k: _bit(row, k) for k in ATOMIC_KEYS}
        w, a, s, d = vals["w"], vals["a"], vals["s"], vals["d"]
        shift, space = vals["shift"], vals["space"]

        # confidence / risk 需要整段控制序列 → 按 clip 缓存，避免每帧重算 O(N²)
        cm = self._control_matrix(clip, rows)
        conf_all = _confidence_targets(cm)
        risk_all = _risk_targets(cm)

        # ── vehicle_state：只允许 t−1 及更早的信息，禁止当前帧标签泄漏 ──
        #
        # ⚠️ 2026-11-03 修复（审查 P0-5）：旧实现直接把**当前帧**的按键填进 state：
        #       vehicle_state[6] = -1 if a else (1 if d else 0)   ← 就是 horizontal 标签
        #       vehicle_state[0] = 1 if w else 0                   ← 就是 vertical 的一半
        #    实测后果：`state[6]` 与 `horizontal` **完全一一对应**（确定性泄漏，
        #    不是相关性）。模型只要读这一维就能 100% 猜出横向标签，根本不用看图。
        #    更糟的是部署端这两维来自完全不同的来源（speed OCR / 上一帧决策输出，
        #    见 InferenceEngineV2.swift:760-940），训练分布 ≠ 推理分布
        #    → 训练指标虚高、上车即崩。
        #
        # 为什么改成 t−1 而不是全零：
        #    论文的核心贡献就是 state-aware（把 t−1 的控制量做成 state token，
        #    见 papers/state_aware.txt §IV.A）。t−1 的动作在部署时**真实可得**
        #    ——它就是模型自己上一帧的输出。所以 t−1 既是合法的时序信息，
        #    又不构成泄漏。全部置零会让这个核心机制彻底失效，故优先选 t−1。
        #
        # 8 维来源（语义见 model_v2.StateEncoder 的文档）：
        #   [0] speed        → 录制数据里**没有**速度 → 恒 0
        #                      不从 W 伪造：按 W ≠ 车在动，语义错且同样泄漏
        #   [6] steer_angle  → t−1 的 A/D（上一帧转向指令），A→−1 / D→+1 / 其余→0
        #   其余             → 0（录制数据未提供）
        #
        # 验证方式（tests 里已实跑）：把当前帧的 A/D 翻转，vehicle_state 必须**不变**。
        vehicle_state = np.zeros(8, dtype=np.float32)
        if frame_idx > 0:
            prev = rows[frame_idx - 1]
            prev_a, prev_d = _bit(prev, "a"), _bit(prev, "d")
            # 与 horizontal_from_keys 同口径：A→−1，D→+1，同按或都不按→0
            if prev_a and not prev_d:
                vehicle_state[6] = -1.0
            elif prev_d and not prev_a:
                vehicle_state[6] = 1.0

        return {
            "image_hi": torch.from_numpy(image_hi),
            "image_lo": torch.from_numpy(image_lo),
            "lane": torch.zeros(1, 160, 160, dtype=torch.float32),
            "dets": torch.zeros(20, 12, dtype=torch.float32),
            "det_mask": torch.zeros(20, dtype=torch.float32),
            "vehicle_state": torch.from_numpy(vehicle_state),
            # ---- 8 个 target ----
            "vertical": torch.tensor(vertical_from_keys(w, s), dtype=torch.long),
            "horizontal": torch.tensor(horizontal_from_keys(a, d), dtype=torch.long),
            "handbrake": torch.tensor([float(shift)], dtype=torch.float32),
            "brake": torch.tensor([float(space)], dtype=torch.float32),
            "super_brake": torch.tensor([float(shift and space)], dtype=torch.float32),
            "ultimate": torch.tensor([float(shift and space and s)], dtype=torch.float32),
            "confidence": torch.tensor([float(conf_all[frame_idx, 0])], dtype=torch.float32),
            "risk": torch.tensor([float(risk_all[frame_idx, 0])], dtype=torch.float32),
            "intent": torch.tensor(
                intent_from_keys(w, a, s, d, shift, space), dtype=torch.long
            ),
        }

    def _control_matrix(self, clip: Path, rows: List[Dict[str, str]]) -> np.ndarray:
        """把整个 clip 的原子键转成 [N,6] 矩阵。

        按 clip 路径缓存（实例级，不是类级 —— 类级字典会被同一进程里的多个
        Dataset 实例共享，切数据集时会读到上一个数据集的矩阵，静默污染标签）。
        """
        cached = self._cm_cache.get(clip)
        if cached is not None:
            return cached
        cm = np.array(
            [[_bit(r, k) for k in ATOMIC_KEYS] for r in rows], dtype=np.float32
        )
        self._cm_cache[clip] = cm
        return cm

    @staticmethod
    def _augment_brightness(img: np.ndarray) -> np.ndarray:
        """仅亮度抖动。

        为什么不做水平翻转：翻转会改变左右转向的语义（A↔D），必须同时翻转标签，
        而本任务的方向键是**离散对称**的，误翻一次就把整段数据教反。收益不值得风险。
        """
        delta = np.random.uniform(-0.08, 0.08)
        return np.clip(img + delta, 0.0, 1.0).astype(np.float32)


# ----------------------------------------------------------------------------
# 训练/验证划分
# ----------------------------------------------------------------------------

def make_train_val_split(
    dataset: V3KeyDataset,
    val_ratio: float = 0.1,
    seed: int = 42,
) -> Tuple[torch.utils.data.Dataset, torch.utils.data.Dataset]:
    """按 **clip 边界**划分训练/验证集。

    为什么必须按 clip 而不是按帧随机切：
        V3 的输入是 24 帧滑动窗口（3 高清 + 21 低清）。相邻帧的窗口有 23 帧重叠，
        按帧随机切会让验证集里的几乎每一帧都在训练集中以"错开一帧"的形式出现过
        —— 验证指标会虚高到接近 100%，完全失去早期停止/选模型的意义。
        按 clip 切分保证验证集来自**整段独立的驾驶片段**，指标才是可信的。

    为什么 clip 太少时退化为按帧切（mono_dataset.py 同策略）：
        只有 2-3 个 clip 时按 clip 切会让 val 只剩极少样本、方差极大；
        退化切分不理想但至少能跑起来，且**会在日志里明确标注是退化模式**，
        不会让人误以为拿到了可信的验证指标。

    实参约定见 mono_dataset.make_train_val_split（本项目既有实现，保持一致）。
    """
    # clip → 该 clip 在全局 index 中的样本数
    clip_counts: Dict[Path, int] = {}
    for clip, _ in dataset.index:
        clip_counts[clip] = clip_counts.get(clip, 0) + 1

    active_clips = [c for c, n in clip_counts.items() if n > 0]

    if len(active_clips) >= 4:
        rng = random.Random(seed)
        shuffled = list(active_clips)
        rng.shuffle(shuffled)
        n_val = max(1, int(len(shuffled) * val_ratio))
        # 保证 train 至少留 1 个 clip（避免 val 全取）
        if n_val >= len(shuffled):
            n_val = len(shuffled) - 1
        val_clips = set(shuffled[:n_val])

        train_idx = [i for i, (clip, _) in enumerate(dataset.index) if clip not in val_clips]
        val_idx = [i for i, (clip, _) in enumerate(dataset.index) if clip in val_clips]

        if not val_idx:  # 理论不该发生，纯兜底
            return _fallback_frame_split(dataset, val_ratio, seed)

        print(f"[V3KeyDataset] 按 clip 划分: train={len(train_idx)} val={len(val_idx)} "
              f"(val_clips={len(val_clips)}/{len(active_clips)})")
        return (torch.utils.data.Subset(dataset, train_idx),
                torch.utils.data.Subset(dataset, val_idx))

    print(f"[V3KeyDataset] ⚠ clip 数 {len(active_clips)} < 4，退化为按帧划分"
          "（验证指标不可信，仅用于跑通流程）")
    return _fallback_frame_split(dataset, val_ratio, seed)


def _fallback_frame_split(
    dataset: V3KeyDataset,
    val_ratio: float,
    seed: int,
) -> Tuple[torch.utils.data.Dataset, torch.utils.data.Dataset]:
    """按帧随机划分（小数据集兜底，保证至少 1 条 val 样本）。"""
    n = len(dataset)
    n_val = max(1, int(n * val_ratio))
    g = torch.Generator().manual_seed(seed)
    perm = torch.randperm(n, generator=g).tolist()
    val_idx_set = set(perm[:n_val])
    train_idx = [i for i in range(n) if i not in val_idx_set]

    print(f"[V3KeyDataset] 按帧随机划分: train={len(train_idx)} val={len(val_idx_set)}")
    return (torch.utils.data.Subset(dataset, train_idx),
            torch.utils.data.Subset(dataset, sorted(val_idx_set)))


# ----------------------------------------------------------------------------
# 统计 / 自检
# ----------------------------------------------------------------------------

def print_stats(clips_dir: str | Path, skip_all_zero: bool = True) -> None:
    """统计真实数据的标签分布 —— 训练前必须跑，用它回填损失函数的类权重。

    为什么必须实测：03-output-head.md §5.1 实测过一个「永远输出 W」的平凡解
    准确率就有 80.8%，但 S 类一帧都不会。所以类权重不能拍脑袋，必须按真实
    分布算；模型选择也必须看 per-class recall 而不是总准确率。

    ⚠️ 2026-11-03 修复（审查 P1-1）：统计口径必须与**训练时实际喂给模型的数据**一致。
       训练用的 `V3KeyDataset` 默认 `skip_all_zero=True`（全零帧被丢弃），
       而旧版 `print_stats` 统计的是**全部行**，于是：
           实测（审查报告，同一份数据）
             训练实际分布 vertical = {0:21, 1:5, 2:10} 共 36 帧
             --stats 报告       vertical = {W:21, NONE:12, S:10} 共 43 帧
             → NONE 被多计 7 帧（正是被丢弃的全零帧），占比虚高 19%
       后果：按这份统计算出的类权重偏向 NONE，与训练实际分布不符，
       等于在错误的分布上做不平衡校正。

       现在默认按训练口径统计（跳过全零帧），并显式打印被跳过的帧数，
       让「原始行数」与「训练帧数」两个数字都可见，不会再有隐性偏差。
       需要看含全零帧的原始口径时传 `skip_all_zero=False`。
    """
    clips = sorted(
        p for p in Path(clips_dir).iterdir()
        if p.is_dir() and p.name.startswith("clip_")
    )
    if not clips:
        print(f"[错误] {clips_dir} 下没有 clip_* 目录")
        sys.exit(1)

    counts = {k: 0 for k in ATOMIC_KEYS}
    vert = [0, 0, 0]
    horiz = [0, 0, 0]
    intent = [0, 0, 0]
    total = 0          # 参与统计的帧数（= 训练实际使用的帧数）
    raw_total = 0      # CSV 原始行数
    n_skipped = 0      # 被跳过的全零帧

    for clip in clips:
        csv_path = clip / "controls.csv"
        if not csv_path.exists():
            continue
        rows = V3KeyDataset._read_rows(csv_path)
        for row in rows:
            raw_total += 1
            vals = {k: _bit(row, k) for k in ATOMIC_KEYS}
            if skip_all_zero and not any(vals[k] for k in ATOMIC_KEYS):
                n_skipped += 1
                continue
            for k in ATOMIC_KEYS:
                counts[k] += vals[k]
            vert[vertical_from_keys(vals["w"], vals["s"])] += 1
            horiz[horizontal_from_keys(vals["a"], vals["d"])] += 1
            intent[intent_from_keys(
                vals["w"], vals["a"], vals["s"], vals["d"],
                vals["shift"], vals["space"])] += 1
            total += 1

    if raw_total == 0:
        print("[错误] 没有读到任何数据行")
        sys.exit(1)
    if total == 0:
        print(f"[错误] {raw_total} 行数据在跳过全零帧后为空 —— "
              "整场录制没有任何按键，无法训练。")
        sys.exit(1)

    scope = "训练口径（已跳过全零帧，与 V3KeyDataset 默认一致）" \
        if skip_all_zero else "原始口径（含全零帧，非训练分布）"
    print(f"统计口径: {scope}")
    print(f"CSV 原始行数: {raw_total}    参与统计帧数: {total}    "
          f"跳过全零帧: {n_skipped}")
    print()
    print("原子键按下率:")
    for k in ATOMIC_KEYS:
        print(f"  {k:8s} {counts[k]:7d}  ({counts[k] / total * 100:5.2f}%)")
    print()
    print("vertical (W/NONE/S):")
    for i, name in enumerate(("W", "NONE", "S")):
        print(f"  {name:8s} {vert[i]:7d}  ({vert[i] / total * 100:5.2f}%)")
    print()
    print("horizontal (A/NONE/D):")
    for i, name in enumerate(("A", "NONE", "D")):
        print(f"  {name:8s} {horiz[i]:7d}  ({horiz[i] / total * 100:5.2f}%)")
    print()
    print("intent (GO/SLOW/STOP):")
    for i, name in enumerate(("GO", "SLOW", "STOP")):
        print(f"  {name:8s} {intent[i]:7d}  ({intent[i] / total * 100:5.2f}%)")

    # 类权重建议（逆频率，归一化到均值为 1）
    print()
    print("建议 vertical 类权重（逆频率，均值归一）:")
    inv = [(total / max(c, 1)) for c in vert]
    mean = sum(inv) / 3
    print("  " + "  ".join(f"{name}={v / mean:.2f}" for name, v in zip(("W", "NONE", "S"), inv)))


def _selftest() -> None:
    """自检：纯函数标签构造的边界与安全优先序。"""
    print("=== 标签构造自检 ===")

    # 安全优先序：W+S 同按 → S（制动优先）
    assert vertical_from_keys(1, 1) == 2, "W+S 同按应判 S（安全优先）"
    assert vertical_from_keys(1, 0) == 0, "只按 W 应判 W"
    assert vertical_from_keys(0, 1) == 2, "只按 S 应判 S"
    assert vertical_from_keys(0, 0) == 1, "都不按应判 NONE"

    # 横向：A+D → NONE
    assert horizontal_from_keys(1, 1) == 1, "A+D 同按应判 NONE"
    assert horizontal_from_keys(1, 0) == 0
    assert horizontal_from_keys(0, 1) == 2

    # intent：STOP 优先于 SLOW
    assert intent_from_keys(0, 0, 0, 0, 1, 1) == 2, "Shift+Space 应判 STOP（Space 优先）"
    assert intent_from_keys(0, 0, 0, 0, 1, 0) == 1, "只按 Shift 应判 SLOW"
    assert intent_from_keys(1, 1, 0, 0, 0, 0) == 1, "给油+转向应判 SLOW"
    assert intent_from_keys(1, 0, 0, 0, 0, 0) == 0, "直行给油应判 GO"

    # 代理真值形状与值域
    cm = np.array([[1, 0, 0, 0, 0, 0],
                   [1, 0, 0, 0, 0, 0],
                   [0, 0, 1, 0, 1, 1]], dtype=np.float32)
    conf = _confidence_targets(cm)
    assert conf.shape == (3, 1)
    assert np.all(conf > 0) and np.all(conf <= 1.0)
    assert conf[1, 0] == 1.0, "控制量无变化时置信度应为 1"
    assert conf[2, 0] < conf[1, 0], "控制量变化大时置信度应更低"

    risk = _risk_targets(cm)
    assert risk.shape == (3, 1)
    assert risk[2, 0] == 1.0, "ultimte（Shift+Space+S）应为最高风险"

    # 非法值必须显式报错，不能静默当 0
    try:
        _bit({"x": "2"}, "x")
        raise AssertionError("非法值 2 应抛异常")
    except ValueError:
        pass

    # 组合键自洽性校验必须能抓到造假
    bad = {"w": "0", "a": "0", "s": "0", "d": "0", "shift": "1", "space": "0",
           "super_brake": "1", "ultimate_brake": "0"}
    try:
        validate_row(bad, where="selftest")
        raise AssertionError("super_brake 造假应被抓住")
    except ValueError:
        pass

    print("  全部断言通过 ✅")


def main() -> None:
    ap = argparse.ArgumentParser(description="V3 纯按键数据集：统计 / 自检")
    ap.add_argument("--stats", metavar="CLIPS_DIR", help="统计真实数据标签分布")
    ap.add_argument("--selftest", action="store_true", help="跑标签构造自检")
    args = ap.parse_args()

    if args.selftest:
        _selftest()
    elif args.stats:
        print_stats(args.stats)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
