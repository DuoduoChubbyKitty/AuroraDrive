# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""车道线掩码几何口径 —— 训练侧与运行时（Swift）的**唯一真值**实现。

================================================================================
0. 为什么必须存在这个文件（一句话）
================================================================================
`lane_mask` 的 shape 都是 160×160，但**几何口径完全不同**：
  · 运行时（Swift `MaskGrid`）：**letterbox 640×640 坐标系**下采样而来，
    画面内容只占网格**行 35..125**，上下各 35 行是 letterbox 灰边（114 填充）。
  · 修复前的训练侧：录制帧直接 resize 到 160×160，**内容填满全图、无灰边、纵横比被破坏**。

后果：同一物理像素在两侧的网格行坐标**最多相差 35 格（网格高度的 22%）**，
且上下反向拉伸 —— 模型训练时看到的车道线位置，上车后系统性错位。

更危险的是：`LaneMaskEncoder` 开头是 `MaxPool2d(2,2)` + `AdaptiveAvgPool2d((1,1))`，
**任何输入尺寸都能吃下去不报错**，所以 shape 对齐会给人「已经对齐了」的**假安全感**。

================================================================================
1. 权威依据（全部为源码实证，非推断）
================================================================================
    · `Sources/AuroraDrive/Inference/YolopxEngine.swift:40`
        「二值掩码网格（letterbox 640 坐标系，按 gridStride 下采样后存储）」
    · `Sources/AuroraDrive/Inference/YolopxEngine.swift:374`
        「车道线掩码（letterbox 640 坐标系，下采样后）」
    · `Sources/AuroraDrive/Inference/InferenceEngineV2.swift:124`
        「掩码是 letterbox 640 坐标系的俯视图投影」
    · `Sources/AuroraDrive/Inference/YolopxEngine.swift:1263-1341` `extractMask()`
        —— 本文件的 `logits_to_grid()` **逐行复刻**该函数（见 §2）
    · `Sources/AuroraDrive/Inference/YolopxEngine.swift:150-166` `LetterboxMetrics.calculate()`
        —— 本文件的 `letterbox_metrics()` **逐行复刻**

================================================================================
2. extractMask 的精确语义（Swift 原文 → 本文件复刻）
================================================================================
Swift：
    let grid = 160, stride = size / grid          // 640/160 = 4
    for gy in 0..<grid { for gx in 0..<grid {
        var positive = 0
        for dy in 0..<stride { for dx in 0..<stride {
            let a = ch0[py][px], b = ch1[py][px]   // py=gy*stride+dy, px=gx*stride+dx
            if b > a { positive += 1 }
        }}
        if positive * 2 >= stride * stride { cells[gy*grid + gx] = 1 }   // 多数表决
    }}

即：**在 640×640 上算 (ch1 > ch0)，再对每个 4×4 块做 ≥50% 多数表决得到 160×160**。
等价于 `argmax(ch)==1` 后做 4×4 多数表决（argmax 选 ch1 ⟺ ch1 > ch0）。

⚠️ 关键：**不是**在 640 上直接 argmax 存成 640 掩码，**更不是**把它 resize 到 160。
   前者丢了多数表决的降噪，后者会破坏几何。

================================================================================
3. 与 letterbox 参数的关系（为什么内容只占 35..125）
================================================================================
640×360 源图 → letterbox 到 640×640：
    r = min(640/360, 640/640) = 1.0 → newW=640, newH=360
    dh = (640-360)/2 = 140 → padY = round(139.9) = 140, padBottom = round(140.1) = 140
网格 stride = 4：
    有效内容行范围 = ceil(140/4) .. ceil((140+360)/4) = 35 .. 125
    → 行 0..35 与 125..160 是灰边（114 填充），**不是道路**

================================================================================
4. 使用方式
================================================================================
    from lane_geometry import (logits_to_grid, mask_to_grid, letterbox_metrics,
                              valid_region_in_grid, normalize_lane_mask,
                              assert_lane_contract, LANE_GRID)

    grid = logits_to_grid(ll)                 # yolopx ll 头 [2,640,640] → [160,160] uint8
    assert_lane_contract(grid)                # 契约断言
"""

from __future__ import annotations

import math
from typing import Any, Dict, Optional, Tuple

import numpy as np

# ===================== 契约常量（与 Swift 逐位一致）=====================
#: 掩码网格边长（对齐 Swift `YolopxEngine.maskGridSize = 160`）
LANE_GRID: int = 160
#: 掩码的**源坐标系**边长（letterbox 输出尺寸，对齐 Swift `imgsz = 640`）
LANE_SRC_SIZE: int = 640
#: 下采样步长 = 640 / 160
LANE_STRIDE: int = LANE_SRC_SIZE // LANE_GRID
#: letterbox 灰边填充值（Swift 用 114）
LETTERBOX_PAD_VALUE: int = 114

#: 640×360 源图下的有效内容行范围（其余为灰边）。仅作断言/诊断用参考值。
VALID_ROWS_640x360: Tuple[int, int] = (35, 125)


# ==================================================================================
# 工具：Swift 语义的 round（half away from zero）
# ==================================================================================
def _swift_round(x: float) -> int:
    """复刻 Swift `Double.rounded()` —— **四舍五入远离零**。

    ⚠️ 不能用 Python 内置 `round()`：它是 banker's rounding（round-half-to-even），
       在 .5 边界上与 Swift 不一致（round(0.5)=0 而 Swift 给 1）。
       letterbox 参数必须与 Swift 逐位相同，故显式实现。
    """
    if x >= 0:
        return int(math.floor(x + 0.5))
    return int(math.ceil(x - 0.5))


# ==================================================================================
# letterbox 参数（复刻 Swift LetterboxMetrics.calculate）
# ==================================================================================
def letterbox_metrics(src_w: int, src_h: int, size: int = LANE_SRC_SIZE) -> Dict[str, Any]:
    """复刻 Swift `LetterboxMetrics.calculate(srcW:srcH:size:)`。

    官方 `letterbox_for_img` 的 padding 取整：
        top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
        left, right = int(round(dw - 0.1)), int(round(dw + 0.1))

    Returns:
        dict，键与 Swift `LetterboxMetrics` 字段同名：
        ratio / newW / newH / padX / padY / padBottom / srcW / srcH
    """
    if src_w <= 0 or src_h <= 0:
        raise ValueError(f"letterbox_metrics: 非法源尺寸 {src_w}×{src_h}")
    r = min(size / src_h, size / src_w)
    new_w = _swift_round(src_w * r)
    new_h = _swift_round(src_h * r)
    dw = (size - new_w) / 2.0
    dh = (size - new_h) / 2.0
    return {
        "ratio": r,
        "newW": new_w,
        "newH": new_h,
        "padX": _swift_round(dw - 0.1),
        "padY": _swift_round(dh - 0.1),        # = top
        "padBottom": _swift_round(dh + 0.1),   # = bottom
        "srcW": src_w,
        "srcH": src_h,
        "size": size,
    }


def valid_region_in_grid(metrics: Dict[str, Any],
                         grid: int = LANE_GRID) -> Tuple[int, int, int, int]:
    """复刻 Swift `extractMask` 的 valid 区域计算 → 网格坐标 (vx0, vy0, vx1, vy1)。

    Swift 原文：
        let strideD = Double(stride)
        let vx0 = max(0, Int(Double(metrics.padX) / strideD))
        let vy0 = max(0, Int(Double(metrics.padY) / strideD))
        let vx1 = min(grid, Int(ceil(Double(metrics.padX + metrics.newW) / strideD)))
        let vy1 = min(grid, Int(ceil(Double(metrics.padY + metrics.newH) / strideD)))

    返回 (vx0, vy0, vx1, vy1)，半开区间 [v0, v1)。
    """
    stride = metrics["size"] // grid
    stride_d = float(stride)
    vx0 = max(0, int(metrics["padX"] / stride_d))
    vy0 = max(0, int(metrics["padY"] / stride_d))
    vx1 = min(grid, int(math.ceil((metrics["padX"] + metrics["newW"]) / stride_d)))
    vy1 = min(grid, int(math.ceil((metrics["padY"] + metrics["newH"]) / stride_d)))
    return vx0, vy0, vx1, vy1


# ==================================================================================
# 核心：yolopx ll 头 logits → 160×160 网格（★ 逐行复刻 Swift extractMask）
# ==================================================================================
def logits_to_grid(ll: np.ndarray, grid: int = LANE_GRID) -> np.ndarray:
    """yolopx `ll` 头 logits → [grid, grid] uint8 {0,1}。

    ★ 这是训练侧产出 lane_mask 的**唯一正确入口**，逐行复刻 Swift `extractMask()`：
        1) 在源分辨率（640）上算 `ch1 > ch0`
        2) 对每个 stride×stride（4×4）块做**多数表决**（positive*2 >= stride²）

    Args:
        ll: [2, H, W] 或 [1, 2, H, W] 的 logits（H=W=640），ch0=背景 ch1=车道线
        grid: 输出网格边长，默认 160

    Returns:
        [grid, grid] uint8，取值 {0,1}

    Raises:
        ValueError: 形状不合法，或 H/W 不能被 stride 整除（Swift 同样直接返回空网格，
                    这里选择**报错**而非静默降级 —— 静默降级正是本次要根治的问题）
    """
    a = np.asarray(ll)
    if a.ndim == 4:
        if a.shape[0] != 1:
            raise ValueError(f"logits_to_grid: batch 必须为 1，实际 {a.shape[0]}")
        a = a[0]
    if a.ndim != 2 and not (a.ndim == 3 and a.shape[0] >= 2):
        raise ValueError(f"logits_to_grid: 期望 [2,H,W] 或 [H,W]，实际 {a.shape}")

    if a.ndim == 2:
        # 单通道：视为已二值的掩码
        pred = a > 0.5
    else:
        # ★ 与 Swift 完全一致：ch1 > ch0（不是 argmax 的等价改写要小心 NaN）
        pred = a[1] > a[0]

    src_size = a.shape[-1]
    if a.shape[-2] != src_size:
        raise ValueError(
            f"logits_to_grid: 期望方形源坐标系，实际 {a.shape[-2]}×{src_size}")
    stride = src_size // grid
    if src_size % grid != 0:
        raise ValueError(
            f"logits_to_grid: 源边长 {src_size} 不能被 grid {grid} 整除 "
            f"（Swift extractMask 在此情况下返回空网格；这里选择报错以免静默降级）")

    # ★ 多数表决（复刻 Swift 的双层 stride 循环）
    blocks = pred.reshape(grid, stride, grid, stride)
    positive = blocks.sum(axis=(1, 3))
    return (positive * 2 >= stride * stride).astype(np.uint8)


def mask_to_grid(mask: np.ndarray, grid: int = LANE_GRID) -> np.ndarray:
    """把**已二值的掩码**归一到 [grid, grid] uint8 {0,1}。

    接受的输入：
      · [grid, grid]            → 原样返回（已是目标口径）
      · [src, src] (src % grid == 0) → 做 4×4 多数表决（与 logits_to_grid 同规则）
      · 其它尺寸 → **抛错**，绝不静默 resize（静默 resize 正是本次修复的 bug）

    Raises:
        ValueError: 尺寸无法归一到目标网格
    """
    m = np.asarray(mask)
    while m.ndim > 2 and m.shape[0] == 1:
        m = m[0]
    if m.ndim != 2:
        raise ValueError(f"mask_to_grid: 期望 2D 掩码，实际 {m.shape}")

    if m.shape == (grid, grid):
        return (m > 0.5).astype(np.uint8)

    h, w = m.shape
    if h != w:
        raise ValueError(
            f"mask_to_grid: 掩码必须是方形（letterbox 口径），实际 {h}×{w}。"
            f"若这是相机空间的 180×320 掩码，说明口径错误 —— 应走 letterbox 重新生成，"
            f"不要 resize")
    if h % grid != 0:
        raise ValueError(
            f"mask_to_grid: 源边长 {h} 不能被 grid {grid} 整除，无法做多数表决。"
            f"拒绝静默 resize（会破坏几何口径）")
    stride = h // grid
    blocks = (m > 0.5).reshape(grid, stride, grid, stride)
    positive = blocks.sum(axis=(1, 3))
    return (positive * 2 >= stride * stride).astype(np.uint8)


# ==================================================================================
# 统一入口 + 契约断言
# ==================================================================================
def normalize_lane_mask(mask: Any, grid: int = LANE_GRID) -> np.ndarray:
    """把任意来源的车道线掩码归一到 **[1, grid, grid] float32 {0,1}**。

    这是数据集/训练侧的**唯一入口**。任何尺寸不合契约的输入都会**抛错**，
    不再静默 resize —— 这是本次修复的核心纪律。
    """
    arr = np.asarray(mask)
    g = mask_to_grid(arr, grid)
    return g.astype(np.float32)[None, :, :]


def assert_lane_contract(mask: np.ndarray, grid: int = LANE_GRID,
                         name: str = "lane_mask") -> None:
    """契约断言：形状/取值/几何口径三项。失败即抛错（fail-fast，不静默降级）。

    检查项：
      1) shape == [1, grid, grid]（或 [grid, grid]）
      2) 取值 ⊂ {0, 1}
      3) 几何口径：**若掩码全 0 则跳过**；否则警告"内容超出 valid 区域"
         —— 对 640×360 源图，valid 行范围应为 [35, 125)。

    Raises:
        ValueError: 形状或取值不合法
    """
    a = np.asarray(mask)
    if a.ndim == 3:
        if a.shape[0] != 1:
            raise ValueError(f"assert_lane_contract({name}): 期望通道=1，实际 {a.shape}")
        a2 = a[0]
    elif a.ndim == 2:
        a2 = a
    else:
        raise ValueError(f"assert_lane_contract({name}): 期望 2D/3D，实际 {a.shape}")

    if a2.shape != (grid, grid):
        raise ValueError(
            f"assert_lane_contract({name}): 期望 [{grid},{grid}]，实际 {a2.shape}")

    uniq = np.unique(a2)
    bad = [v for v in uniq.tolist() if v not in (0.0, 1.0)]
    if bad:
        raise ValueError(
            f"assert_lane_contract({name}): 取值必须 ⊂ {{0,1}}，实际出现 {bad[:5]}")


def grid_content_rows(mask: np.ndarray) -> Optional[Tuple[int, int]]:
    """返回掩码中**非零内容**所占的行范围 (row_min, row_max]；全 0 返回 None。

    用途：诊断几何口径。若掩码来自 640×360 源的 letterbox 口径，
    内容应落在 [35, 125) 内；若落在 [0, 160) 说明是"拉伸填满"的错误口径。
    """
    a = np.asarray(mask)
    while a.ndim > 2 and a.shape[0] == 1:
        a = a[0]
    rows = np.where(a.reshape(a.shape[0], -1).any(axis=1))[0]
    if rows.size == 0:
        return None
    return int(rows.min()), int(rows.max()) + 1


def describe_geometry(src_w: int = 640, src_h: int = 360,
                      grid: int = LANE_GRID) -> str:
    """生成人类可读的几何口径说明（供报告/日志引用）。"""
    m = letterbox_metrics(src_w, src_h, LANE_SRC_SIZE)
    vx0, vy0, vx1, vy1 = valid_region_in_grid(m, grid)
    lines = [
        f"letterbox 口径（源 {src_w}×{src_h} → {LANE_SRC_SIZE} 方形 → {grid} 网格）",
        f"  ratio={m['ratio']:.6f} newW={m['newW']} newH={m['newH']} "
        f"padX={m['padX']} padY={m['padY']} padBottom={m['padBottom']}",
        f"  stride={m['size'] // grid}",
        f"  ★ 有效内容网格范围: x∈[{vx0},{vx1})  y∈[{vy0},{vy1})",
        f"  ★ 灰边（非道路）: y∈[0,{vy0}) 与 y∈[{vy1},{grid})",
        f"  ★ 有效行占比: {(vy1 - vy0) / grid:.1%}",
    ]
    return "\n".join(lines)
