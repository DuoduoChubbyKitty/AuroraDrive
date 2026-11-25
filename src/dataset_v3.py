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
import os
import random
import statistics
import sys
from concurrent.futures import ThreadPoolExecutor
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

#: 「修饰键卡键」判定的最短连续帧数。
#:
#: 【为什么需要这个判定】录制器（tools/aurora_recorder.c）在部分片段里把
#:   shift/space 粘住了：clip_20261104_131750 帧 1190-2254 共 1065 帧
#:   （约 71 秒）shift 与 space 恒为 1，期间车速 0→191km/h、玩家一直在按 W。
#:   人不可能连续 71 秒不松手刹与空格 —— 这是录制故障，不是操作。
#:
#:   若不处理，会产生两个确定性错误：
#:     ① super_brake(=shift∧space) 头学到「这类画面永远=1」；
#:     ② L_rollover 的 violation = w(speed)·P(super_brake)·(1−P(S))，
#:        在高速段把 P(S) 硬推向 1，与 vertical 的 CE 标签（W）直接对冲：
#:        λ_roll=2.0 > λ_key=0.8，实测四个 P(S) 取值点上 rollover 梯度全部更大
#:        → 模型被按着「看到超级刹车就踩 S」，即使标签是给油。
#:
#:   5 秒（75 帧 @15Hz）是保守下限：真实「按住超级刹车」是点按，不会连续 75 帧。
MODIFIER_STUCK_MIN_RUN = 75


def modifier_valid_from_rows(rows: List[Dict[str, str]]) -> List[bool]:
    """逐帧判定「修饰键(shift/space)标签是否可信」。

    返回与 rows 等长的布尔列表：False 表示该帧处于**疑似卡键段**，
    其 shift/space 值不可信，不应作为 super_brake/ultimate 的监督目标，
    也不应参与 L_rollover。

    ⚠️ 这类帧的 **vertical / horizontal 仍然可信、仍用于训练**：
      卡键只影响两个修饰键，不代表玩家没在给油或打方向。
      所以本函数只产出 mask，**绝不删帧**。

    判定依据（只依赖数据本身，不写死 clip 名/帧号）：
      存在一段连续 ≥ MODIFIER_STUCK_MIN_RUN 帧、shift 与 space 同时为 1。
      该段内所有帧标记为不可信。
    """
    n = len(rows)
    both = []
    for r in rows:
        try:
            sh, sp = _bit(r, "shift"), _bit(r, "space")
        except ValueError:
            sh = sp = 0
        both.append(1 if (sh == 1 and sp == 1) else 0)

    valid = [True] * n
    start = None
    for i in range(n + 1):
        on = both[i] if i < n else 0
        if on and start is None:
            start = i
        elif not on and start is not None:
            if i - start >= MODIFIER_STUCK_MIN_RUN:
                for j in range(start, i):
                    valid[j] = False
            start = None
    return valid

#: 高清帧数。必须与 model_v3.V3Config.num_hi_frames 一致（默认 3）。
#: 24 帧窗口 = 3 高清(t,t−1,t−2) + 21 低清(t−3 … t−23)，总计 24 帧 @15Hz = 1.6s。
NUM_HI_FRAMES = 3

#: 窗口总帧数（高低清合计），用于与模型侧断言对齐。
NUM_TOTAL_FRAMES = 24

#: 低清帧数。必须与 model_v3.V3Config.num_lo_frames 一致（默认 21）。
#: dataset 的 history 参数就是这个数的入口——image_lo 是固定 21 帧窗口，
#: 不是自由配置；__init__ 里的硬校验会拦截任何不等于本值的 history。
NUM_LO_FRAMES = NUM_TOTAL_FRAMES - NUM_HI_FRAMES  # 21

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


def intent_from_keys(w: int, a: int, s: int, d: int, shift: int, space: int,
                    modifier_valid: bool = True) -> int:
    """stage1 制动意图：0=GO / 1=SLOW / 2=STOP（仅训练用）。

    定义严格照 03-output-head.md §3.3：
        STOP(2)：按了 Space 或 S（真在制动/后退）
        SLOW(1)：按了 Shift（手刹），或「同时给油+转向」（转弯需减速）
        GO(0)  ：其余
    STOP 必须先判，否则「Shift+Space+S」会被 SLOW 抢走。

    【为什么必须按 modifier_valid 屏蔽】
        卡键段（modifier_valid=False）里 shift 与 space 恒为 1（录制故障），
        若照原始值计算，STOP 分支的 `space` 恒真 → 整段被误判成 STOP。
        实测 clip_20261104_131750 第 2000 帧：vertical=W（正确）却 intent=STOP（错误）。
        而 intent 监督的 stage1 状态会传播进控制主干（model_v3.py:1043-1053），
        等于教模型「这画面是停车场景」—— 这是 ultimate 误触发的直接来源。
        故 modifier_valid=False 时把 shift/space 视为 0（不可信，不参与判定）。

    ⚠️ `s` 是原子键、不受卡键影响（卡键只坏 shift/space），仍照常参与判定：
       卡键段里真按了 S 的帧依然是合法 STOP，不能一起抹掉。
    """
    if not modifier_valid:
        shift = space = 0
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

def confidence_valid_from_modifier_valid(modifier_valid: List[bool]) -> List[bool]:
    """逐帧判定「confidence 代理真值是否可信」。

    【为什么 confidence 需要**相邻两帧都可信**】
        `_confidence_targets` 用「本帧与上一帧（t-1）的控制量差异」构造真值：
        差异大 → 低置信。若本帧或上一帧任一处于卡键段，其 shift/space 是故障值，
        差分就会被故障污染：
          · 卡键段起始帧：t-1 正常、t 变 1 → 伪造出「键状态剧变」→ confidence 假性变低；
          · 卡键段结束帧：t-1 是 1(故障)、t 恢复正常 → 又一次伪造剧变。
        所以只要 `modifier_valid[t]` 或 `modifier_valid[t-1]` 任一为 False，
        本帧 confidence 就不可信，必须屏蔽。

    【为什么首帧（t=0）只要求本帧可信】
        首帧没有上一帧（`_confidence_targets` 里 conf[0]=1.0，不参与差分），
        不存在「相邻帧污染」，故只看本帧。这与 `_confidence_targets` 的首帧
        特判严格对应；若这里也要求 t-1，会把每段第 0 帧误屏蔽（那里根本没有差分）。

    实测影响（data/lean_clips + data/lean_clips_hudmasked 两个目录一致）：
        卡键段共 3 段，`modifier_valid=0` 1739 帧；按本规则 confidence 不可信
        1742 帧 = 1739 + 3（每段之后的第一帧）。多出的 3 帧正是「离开卡键段
        第一帧」——它的差分项仍被上一帧的故障值污染，确实必须屏蔽。

    Args:
        modifier_valid: 与 `modifier_valid_from_rows` 输出等长的布尔列表
    Returns:
        与输入等长的布尔列表：True=该帧 confidence 真值可信
    """
    n = len(modifier_valid)
    valid = [True] * n
    for i in range(n):
        if not modifier_valid[i]:
            valid[i] = False
        elif i > 0 and not modifier_valid[i - 1]:
            valid[i] = False
    return valid


def _confidence_targets(control_matrix: np.ndarray, tau: float = 0.15,
                        modifier_valid: Optional[List[bool]] = None) -> np.ndarray:
    """由「控制量的帧间变化」构造 confidence 代理真值（越小越该低置信）。

    语义对齐 src/risk_head.py:1128 的 `confidence_target_from_temporal_change`：
    控制状态变化大 = 高动态/转折场景 = 判断更难 = 该低置信。

    Args:
        control_matrix: [N, 6] 每帧的 6 个原子键（w,a,s,d,shift,space），0/1
        tau: 变化量到置信度的缩放。6 个键最大变化量是 6，用 tau=0.15 时
             单键变化约降 0.15 置信度。
        modifier_valid: 可选的逐帧真值屏蔽（见 `modifier_valid_from_rows`）。
             传入时，**不可信帧的 shift/space 先按键位降级为 0** 再算差分。
             为什么必须降级：卡键段的 shift/space 是录制故障，差分里保留它们
             会在卡键段边界伪造「键状态剧变」。降级后差分只反映可信原子键的变化。
             注意这里只改*差分输入*，不改返回的置信度语义。
    Returns:
        [N, 1] float32，值域 (0, 1]
    """
    n = len(control_matrix)
    conf = np.ones((n, 1), dtype=np.float32)
    if n < 2:
        return conf
    cm = control_matrix
    if modifier_valid is not None:
        # 复制后再降级，绝不改动调用方的矩阵（它被多帧缓存共享）
        cm = np.array(control_matrix, dtype=np.float32, copy=True)
        # 原子键顺序见 dataset_v3.ATOMIC_KEYS = [w,a,s,d,shift,space] → 4/5 位
        for i in range(n):
            if not modifier_valid[i]:
                cm[i, 4] = 0.0
                cm[i, 5] = 0.0
    # 当前帧与上一帧的差异键个数（0..6）
    diff = np.abs(np.diff(cm, axis=0)).sum(axis=1)  # [N-1]
    # 与前向差分对齐：第 i 帧的"变化"用 i 与 i-1 的差；首帧无历史，设 0
    conf[1:, 0] = np.exp(-tau * diff)
    return np.clip(conf, 0.05, 1.0)


def _risk_targets(control_matrix: np.ndarray,
                  modifier_valid: Optional[List[bool]] = None) -> np.ndarray:
    """由「制动强度」构造 risk 代理真值。

    ⚠️ 这是**简化代理**，不是真正的 TTC（没有前车距离/相对速度）。
    真实 risk_target_from_ttc（src/risk_head.py:1183）需要 TTC，本项目当前
    **没有**该输入 → 这里只能用「是否在制动/极限制动」作为危险程度的近似：
        · ultimate_brake（Shift+Space+S）→ 1.0（最高危，正在极限制动）
        · super_brake（Shift+Space）     → 0.8
        · space 或 s（普通制动/后退）    → 0.5
        · 其余                            → 0.1（基线，不是 0——保持头不饱和）

    Args:
        control_matrix: [N, 6] 原子键矩阵
        modifier_valid: 可选逐帧真值屏蔽。传入时**不可信帧的 shift/space 降级为 0**
            再判定风险档位。为什么：卡键段 shift∧space 恒真 → risk 恒被抬到 0.8，
            实测 clip_20261104_131750 第 2000 帧 risk=0.8（实际只是 cruise 给油），
            等于教 risk 头「这类画面是高风险」。降级后该帧回落到「只看 space/s」
            的真实档位（未按 space/s → 0.1 基线）。

    诚实声明：该代理无法区分「平静减速」与「紧急避险」，训练出的 risk 头
    只能当作「当前是否处于制动动作」的指示器，不能当作真实风险预测。
    已列入未测项（见模块 docstring）。
    """
    n = len(control_matrix)
    risk = np.full((n, 1), 0.1, dtype=np.float32)
    for i in range(n):
        w, a, s, d, shift, space = control_matrix[i]
        if modifier_valid is not None and not modifier_valid[i]:
            # 卡键帧的 shift/space 是故障值：视为未按，避免 risk 被抬到 0.8/1.0
            shift = space = 0
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
        decode_workers: Optional[int] = None,
    ):
        if Image is None:
            raise RuntimeError("需要 Pillow：pip install pillow")

        self.clips_dir = Path(clips_dir)
        self.image_size = image_size
        self.lowres_size = lowres_size
        self.history = history
        # 【契约硬校验】history 是低清窗口深度，模型侧 image_lo 固定 21 帧
        # （NUM_LO_FRAMES = model_v3.V3Config.num_lo_frames 的默认）。传别的值
        # 训练能跑但窗口深度与模型契约不一致——模型期望 21 帧却收到别的数量，
        # 训练/推理分布错位，且错误不发生在加载期、毫无征兆。故在此 fail-fast。
        if history != NUM_LO_FRAMES:
            raise ValueError(
                f"history={history} 与模型契约不一致：image_lo 是固定的 "
                f"{NUM_LO_FRAMES} 帧低清窗口（与 model_v3.V3Config.num_lo_frames 绑定）。"
                f"改 history 必须同步改 src/model_v3.py 的 V3Config.num_lo_frames "
                f"和 CoreML 输入 shape，否则训练与推理分布不一致")
        self.augment = augment
        self.rng = random.Random(seed)
        self.expected_fps = expected_fps

        # 解码线程数：未显式传入时读环境变量 AURORA_DECODE_THREADS，再缺省为 1
        # （1 = 完全保持原来的单线程行为，调用方不传该参数时行为不变）。
        #
        # 为什么用线程并行解码，而不是 DataLoader 的 num_workers：
        #     容器 /dev/shm 固定 64MB，而单样本 24 帧张量约 8.1MB，多进程透传
        #     必然 bus error（2026-11-07 在书生平台实测五次全崩，file_system
        #     共享策略同样无效）。线程不走共享内存，因此不受该限制。
        # 为什么线程能真正并行（不是伪并行）：
        #     实测 Pillow 在 JPEG decode 与 resize 期间释放 GIL，
        #     4 线程 2.12x、8 线程 2.30x，且输出与原实现逐像素完全一致。
        if decode_workers is None:
            decode_workers = int(os.environ.get("AURORA_DECODE_THREADS", "1"))
        self.decode_workers = max(1, decode_workers)
        #: 懒建线程池：不在 __init__ 建，避免 Dataset 被 DataLoader 多进程序列化时
        #: ThreadPoolExecutor 无法 pickle 而报错。
        self._decode_pool: Optional[ThreadPoolExecutor] = None

        #: 显存帧缓存（vram_cache.V3VRAMFrameCache）。非 None 时 __getitem__ 从显存直取。
        #: 由训练脚本在构造好后挂载；不挂载时行为与原实现完全一致。
        self.vram_cache = None
        self.index: List[Tuple[Path, int]] = []
        self._rows_cache: Dict[Path, List[Dict[str, str]]] = {}
        #: 每 clip 的「修饰键是否可信」缓存。与 _rows_cache 同生命周期。
        #: 见 modifier_valid_from_rows()：False 的帧不参与 super_brake/ultimate 监督。
        self._modifier_valid_cache: Dict[Path, List[bool]] = {}
        #: 每 clip 的「confidence 真值是否可信」缓存（相邻帧规则，见
        #: confidence_valid_from_modifier_valid）。与 _modifier_valid_cache 同生命周期。
        self._confidence_valid_cache: Dict[Path, List[bool]] = {}
        #: clip → [N,6] 原子键矩阵缓存（算 confidence / risk 用；实例级）
        self._cm_cache: Dict[Path, np.ndarray] = {}
        #: clip → (confidence, risk) 代理真值缓存（同上，只依赖 cm，纯确定性）
        self._target_cache: Dict[Path, Tuple[np.ndarray, np.ndarray]] = {}
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
        # 修饰键可信性（卡键段 → False）。按 clip 惰性计算并缓存：
        # 逐帧计算会退化成 O(N²)，而这一判定只与整段 shift/space 序列有关。
        modifier_valid = self._modifier_valid_cache.get(clip)
        if modifier_valid is None:
            modifier_valid = modifier_valid_from_rows(rows)
            self._modifier_valid_cache[clip] = modifier_valid
        # confidence 真值涉及相邻两帧 → 另建一份「本帧或上一帧不可信即 False」的掩码。
        # 与 modifier_valid 分开缓存：两者语义不同（后者是本帧，前者是本帧∧上一帧），
        # 混用会让损失侧把单个卡键帧也当成「相邻帧污染」屏蔽掉。
        confidence_valid = self._confidence_valid_cache.get(clip)
        if confidence_valid is None:
            confidence_valid = confidence_valid_from_modifier_valid(modifier_valid)
            self._confidence_valid_cache[clip] = confidence_valid
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

        if self.vram_cache is not None and not self.augment:
            # ── 显存缓存路径 ──────────────────────────────────────────────
            # 相邻样本的 24 帧窗口重叠 23 帧，原实现每个样本都重解这 24 张 JPEG
            # → 同一帧被反复解码（乱序采样下一个 batch 冗余 32x、连续采样 14x）。
            # 预解码一次后每样本只剩 24 次显存切片，这是消除 GPU 空转的关键。
            #
            # ⚠️ 为什么 augment=True 时不走这里：亮度抖动要求按 self.rng 的**调用顺序**
            #    逐帧取随机数（24 次），一旦帧顺序或 clamp 与原始实现有偏差，
            #    随机流即错位、增强不可复现。训练实际用 augment=False。
            image_hi = self.vram_cache.gather(clip, hi_idx, high=True)
            image_hi = image_hi.float().div_(255.0)                      # [3,3,H,W]
            image_lo = self.vram_cache.gather(clip, lo_idx, high=False)
            image_lo = image_lo.float().div_(255.0)                      # [21,3,h,w]
        elif self.decode_workers > 1 and not self.augment:
            # ── CPU 多线程解码（未启用显存缓存时的回落路径）──
            # Pillow 在 decode/resize 期间释放 GIL，因此线程能真正并行（实测 2.1x）。
            # 为什么不用 DataLoader num_workers：容器 /dev/shm 仅 64MB，多进程必崩。
            # hi/lo 合并成一批提交，让线程池连续排满（分两批会有尾部空转）。
            if self._decode_pool is None:
                self._decode_pool = ThreadPoolExecutor(
                    max_workers=self.decode_workers,
                    thread_name_prefix="jpeg-decode",
                )
            jobs = [(fi, self.image_size) for fi in hi_idx]
            jobs += [(fi, self.lowres_size) for fi in lo_idx]
            frames = list(self._decode_pool.map(lambda a: load_frame(*a), jobs))
            image_hi = torch.from_numpy(np.stack(frames[:NUM_HI_FRAMES], axis=0))
            image_lo = torch.from_numpy(np.stack(frames[NUM_HI_FRAMES:], axis=0))
        else:
            # ── 单线程解码（augment=True 或显式 decode_workers=1）──
            image_hi = torch.from_numpy(np.stack(
                [load_frame(fi, self.image_size) for fi in hi_idx], axis=0
            ))                                                               # [3,3,H,W]
            image_lo = torch.from_numpy(np.stack(
                [load_frame(fi, self.lowres_size) for fi in lo_idx], axis=0
            ))                                                               # [21,3,h,w]

        row = rows[frame_idx]
        vals = {k: _bit(row, k) for k in ATOMIC_KEYS}
        w, a, s, d = vals["w"], vals["a"], vals["s"], vals["d"]
        shift, space = vals["shift"], vals["space"]

        # confidence / risk 需要整段控制序列 → 按 clip 缓存，避免每帧重算 O(N²)
        # 两条代理真值都按 modifier_valid 做键位屏蔽（卡键段 shift/space 是故障值）。
        conf_all, risk_all = self._conf_risk_targets(
            clip, rows, modifier_valid, confidence_valid)

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

        # ── 车速（只供 L_rollover，不进模型输入）──
        # 逐帧解析 `speed_kmh` 列：空串 / 缺列 / 非数字 / 负数 → speed_valid=0。
        # ⚠️ 为什么不复用 vehicle_state[0]：那一维是**模型输入**且当前恒 0，
        #    改它要同步部署端（InferenceEngineV2 的 V2Kinematics），是另一件事。
        #    这里只解决「安全项拿不到速度就会静默失效」。
        # ⚠️ 负数：录制器对「读不到」写空串，但存量 9 列数据里 -1 是 OCR 哨兵，
        #    两种都要按无效处理（拿 -1 去算 w 会被 clamp 成 0 → 高速也不罚）。
        speed_kmh = 0.0
        speed_valid = 0.0
        raw_speed = rows[frame_idx].get("speed_kmh")
        if raw_speed is not None:
            text = str(raw_speed).strip()
            if text != "":
                try:
                    value = float(text)
                except ValueError:
                    value = -1.0
                if value >= 0.0:
                    speed_kmh = value
                    speed_valid = 1.0

        # 当前帧修饰键是否可信（见 modifier_valid_from_rows 的说明）。
        # 必须定义在字典**之前** —— 字典字面量内部不能放语句。
        mvalid = bool(modifier_valid[frame_idx])

        # ── 上一帧车速：仅供 L_rollover 判断「是否真的在减速」──
        #
        # 【为什么需要】原 L_rollover 的 violation = w(speed)·P(super_brake)·(1−P(S))
        #   只看「想按超级刹车」这一个标志就去抬 P(S)。但 super_brake 标志本身可能
        #   来自录制器卡键（shift/space 粘住），而**卡键段车速是平稳的**。
        #   真正的防侧翻场景一定伴随车速下降。用「实际减速」作为触发条件，
        #   卡键段自然不触发，真急刹时照常保护。
        speed_prev_kmh = 0.0
        speed_prev_valid = 0.0
        if frame_idx > 0:
            raw_prev = rows[frame_idx - 1].get("speed_kmh")
            if raw_prev is not None:
                text_prev = str(raw_prev).strip()
                if text_prev != "":
                    try:
                        value_prev = float(text_prev)
                    except ValueError:
                        value_prev = -1.0
                    if value_prev >= 0.0:
                        speed_prev_kmh = value_prev
                        speed_prev_valid = 1.0

        return {
            # 三个分支（显存缓存 / 多线程 / 单线程）产出的都已经是张量，
            # 故此处不再包 from_numpy —— 否则对张量调用会直接 TypeError。
            "image_hi": image_hi,
            "image_lo": image_lo,
            "lane": torch.zeros(1, 160, 160, dtype=torch.float32),
            "dets": torch.zeros(20, 12, dtype=torch.float32),
            "det_mask": torch.zeros(20, dtype=torch.float32),
            "vehicle_state": torch.from_numpy(vehicle_state),
            # ── 车速：只给 L_rollover 用（target 侧标量），不进模型输入 ──
            # 数值是**原始 km/h**，不是归一化值 —— 防侧翻公式的 v_low/v_high
            # 就是按 km/h 定义的（20/30），传归一化值会让阈值完全错位。
            # ⚠️ 缺列/空串 → speed_valid=0，**不能拿 0 当速度**：那会把高速判成静止，
            #    防侧翻惩罚静默失效（03-output-head.md §3.7 明令禁止）。
            # ⚠️ 不填 vehicle_state[0]：那是**模型输入**，改了必须同步部署端
            #    （InferenceEngineV2 的 V2Kinematics 构造），属于另一处改动，
            #    不与本安全项混在一起做。
            "speed_kmh": torch.tensor([speed_kmh], dtype=torch.float32),
            "speed_valid": torch.tensor([speed_valid], dtype=torch.float32),
            # 上一帧车速（仅 L_rollover 用：判断是否真的在减速）
            "speed_prev_kmh": torch.tensor([speed_prev_kmh], dtype=torch.float32),
            "speed_prev_valid": torch.tensor([speed_prev_valid], dtype=torch.float32),
            # ---- 8 个 target ----
            "vertical": torch.tensor(vertical_from_keys(w, s), dtype=torch.long),
            "horizontal": torch.tensor(horizontal_from_keys(a, d), dtype=torch.long),
            "handbrake": torch.tensor([float(shift)], dtype=torch.float32),
            "brake": torch.tensor([float(space)], dtype=torch.float32),
            # ⚠️ 卡键段（modifier_valid=False）里 shift/space 是录制故障值，
            #    super_brake/ultimate 的监督目标必须屏蔽（置 0 由 loss 侧按
            #    modifier_valid 过滤，这里同时置 0 作双保险，避免误用）。
            #    注意：**不影响 vertical/horizontal** —— 卡键只坏两个修饰键，
            #    玩家当时是否给油/打方向仍然可信。
            "super_brake": torch.tensor(
                [float(shift and space and mvalid)], dtype=torch.float32),
            "ultimate": torch.tensor(
                [float(shift and space and s and mvalid)], dtype=torch.float32),
            # 逐帧 mask：1=修饰键标签可信，0=处于卡键段（loss 侧据此过滤）
            "modifier_valid": torch.tensor([float(mvalid)], dtype=torch.float32),
            # confidence 专用相邻帧掩码：1=本帧且上一帧 modifier 都可信。
            # 为什么单列一个键：confidence 真值由 t 与 t-1 的差分构造，任一端不可信
            # 都会污染真值；而 handbrake/brake 等只需本帧可信（modifier_valid）。
            "confidence_valid": torch.tensor(
                [float(bool(confidence_valid[frame_idx]))], dtype=torch.float32),
            "confidence": torch.tensor([float(conf_all[frame_idx, 0])], dtype=torch.float32),
            "risk": torch.tensor([float(risk_all[frame_idx, 0])], dtype=torch.float32),
            # ⚠️ intent 必须按 modifier_valid 屏蔽：卡键段 shift/space 恒 1，
            #    否则 STOP 分支的 space 恒真 → 整段误判 STOP，而 intent 监督的
            #    stage1 状态会进控制主干（model_v3.py:1043-1053），等于教模型
            #    「这画面是停车场景」。实测帧 2000：vertical=W 却 intent=STOP。
            "intent": torch.tensor(
                intent_from_keys(w, a, s, d, shift, space, modifier_valid=mvalid),
                dtype=torch.long
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

    def _conf_risk_targets(self, clip: Path, rows: List[Dict[str, str]],
                           modifier_valid: List[bool],
                           confidence_valid: List[bool]) -> Tuple[np.ndarray, np.ndarray]:
        """按 clip 缓存 confidence / risk 代理真值。

        为什么值得单独缓存：_risk_targets 是 Python 逐帧循环，对约 6200 帧的
        clip 实测 2.3 ms/次；原来它在 __getitem__ 里**每取一个样本就重算一遍**
        （67k 样本 × 2.3 ms ≈ 2.5 分钟/epoch 的纯重复计算）。两者只依赖
        control_matrix（纯确定性），缓存后与原实现逐元素一致。

        ⚠️ 两条代理真值都必须按修饰键可信性做屏蔽（见 `_risk_targets` /
            `_confidence_targets` 的 modifier_valid 参数）。真实标签只与
            control_matrix + modifier_valid 有关，与 confidence_valid 无关；
            confidence_valid 是**损失侧**的掩码（相邻帧规则），不影响真值本身，
            因此这里虽然接收它，只用于口径说明，不参与真值计算。
        """
        cached = self._target_cache.get(clip)
        if cached is not None:
            return cached
        cm = self._control_matrix(clip, rows)
        result = (_confidence_targets(cm, modifier_valid=modifier_valid),
                  _risk_targets(cm, modifier_valid=modifier_valid))
        self._target_cache[clip] = result
        return result

    def _augment_brightness(self, img: np.ndarray) -> np.ndarray:
        """仅亮度抖动。

        为什么不做水平翻转：翻转会改变左右转向的语义（A↔D），必须同时翻转标签，
        而本任务的方向键是**离散对称**的，误翻一次就把整段数据教反。收益不值得风险。

        ⚠️ 2026-11-03 修复（审查 P2-2）：原实现是 `@staticmethod` + 全局 `np.random`，
           而 `self.rng`（__init__ 里按 seed 建的 `random.Random`）根本没被用过。
           后果：DataLoader 有多个 worker 时，各 worker 从同一全局流取数 →
           亮度抖动高度相关，增强等于几乎没做（且不可复现）。
           改成实例方法用 `self.rng`：同一 seed 下序列确定、可复现。
        """
        delta = self.rng.uniform(-0.08, 0.08)
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
    # 修饰键可信性统计：与训练标签/损失侧严格同口径，否则 --stats 报出的
    # intent 分布与训练实际吃的标签不一致（会误导类权重决策）。
    n_modifier_invalid = 0    # modifier_valid=0 的帧（卡键段）
    n_confidence_invalid = 0  # confidence 不可信的帧（本帧或上一帧处于卡键段）
    # combo 正例按**可信帧**统计：super_brake/ultimate 已改为派生量，
    # 这两组数字就是「值不值得单独监督」的决定依据（见 model_v3 输出头注释）。
    combo_pos_all = {"super_brake": 0, "ultimate": 0}
    combo_pos_clean = {"super_brake": 0, "ultimate": 0}

    for clip in clips:
        csv_path = clip / "controls.csv"
        if not csv_path.exists():
            continue
        rows = V3KeyDataset._read_rows(csv_path)
        clip_modifier_valid = modifier_valid_from_rows(rows)
        clip_confidence_valid = confidence_valid_from_modifier_valid(clip_modifier_valid)
        for i, row in enumerate(rows):
            raw_total += 1
            mvalid = bool(clip_modifier_valid[i])
            if not mvalid:
                n_modifier_invalid += 1
            if not clip_confidence_valid[i]:
                n_confidence_invalid += 1
            vals = {k: _bit(row, k) for k in ATOMIC_KEYS}
            # combo 正例统计放在 skip 之前：与屏蔽帧数一样按全库行数口径，
            # 才能和「全库共屏蔽 1739 帧」的结论对齐。
            w_s, a_s = vals["w"], vals["a"]
            s_s, d_s = vals["s"], vals["d"]
            sb = int(vals["shift"] and vals["space"])
            ul = int(vals["shift"] and vals["space"] and s_s)
            combo_pos_all["super_brake"] += sb
            combo_pos_all["ultimate"] += ul
            if mvalid:
                combo_pos_clean["super_brake"] += sb
                combo_pos_clean["ultimate"] += ul
            if skip_all_zero and not any(vals[k] for k in ATOMIC_KEYS):
                n_skipped += 1
                continue
            for k in ATOMIC_KEYS:
                counts[k] += vals[k]
            vert[vertical_from_keys(w_s, s_s)] += 1
            horiz[horizontal_from_keys(a_s, d_s)] += 1
            # ⚠️ 必须传 modifier_valid：卡键段的 shift/space 是录制故障，
            #    不屏蔽会把整段卡键误算成 STOP，使 --stats 的 intent 分布失真
            #    （实测修复前 STOP=10461，修复后 STOP=9421，差 1040 帧）。
            intent[intent_from_keys(
                w_s, a_s, s_s, d_s, vals["shift"], vals["space"],
                modifier_valid=mvalid)] += 1
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

    # ── 修饰键可信性（本次修复的核心口径，必须可见）──
    # 为什么必须打印：卡键帧被 loss 侧屏蔽，若统计不显示这两行，就没人能确认
    # 「屏蔽是否真的生效」「intent 是否按 mask 计算」。这两个数字是回归基线：
    #   modifier_valid=0 实测 1739 帧（13 个 clip、3 段卡键）
    #   confidence_valid=0 = 1739 + 卡键段数(3) = 1742 帧（每段后第一帧的差分被污染）
    print()
    print("修饰键可信性（卡键屏蔽口径，与训练标签/损失侧一致）:")
    print(f"  modifier_valid=0   {n_modifier_invalid:7d} 帧"
          f"  ({(n_modifier_invalid / raw_total * 100):5.2f}% 的 CSV 行)")
    print(f"  confidence_valid=0 {n_confidence_invalid:7d} 帧"
          f"  (差值 {n_confidence_invalid - n_modifier_invalid:+d} = 卡键段数，"
          "每段结束后第一帧的帧间差分仍被故障值污染)")
    # combo 正例：super_brake/ultimate 已改为派生量，这两组数是「为什么不再
    # 单独监督」的可复查依据（干净正例仅数百，无法支撑独立 BCE 头）。
    print("  combo 正例（super_brake=shift∧space / ultimate=shift∧space∧s）:")
    print(f"    全部行: super_brake={combo_pos_all['super_brake']:5d}  "
          f"ultimate={combo_pos_all['ultimate']:5d}")
    print(f"    仅可信行: super_brake={combo_pos_clean['super_brake']:5d}  "
          f"ultimate={combo_pos_clean['ultimate']:5d}")

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
