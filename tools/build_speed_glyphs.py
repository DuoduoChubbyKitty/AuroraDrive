#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 build_speed_glyphs.py — 速度表数字字模训练工具（开发机用 Python）

 职责：从录制的全屏原生帧里，按固定槽位裁出 3 个数字位置 → 灰度 + Otsu →
       缩放到统一尺寸（默认 25×45）→ 聚类（相似数字合并）→ 输出字模库文件
       `models/speed_glyphs.json`（与 Swift 端加载格式一致）。

 用法：
     .venv-yolo26/bin/python tools/build_speed_glyphs.py \
         --frames-dir data/raw_clips/clip_xxx/frames \
         --out-models models/speed_glyphs.json \
         --clusters-out tools/speed_clusters.png

 设计要点：
   - 槽位归一化坐标和 Swift 端 `SpeedOCRReader.slotCentersNorm / slotWidthNorm /
     slotYMinNorm / slotYMaxNorm` 完全一致（**单一事实源**：这里常量值改了，
     Swift 端常量也要改，反之亦然）。
   - 缩放后做二值化（Otsu 自适应阈值），不写死固定阈值——游戏亮度会变。
   - 对每位数字的所有样本做按位多数投票，输出"代表性模板"。
   - 聚类用相似度（汉明距离）做并查集合并，输出每个聚类的可视化 PNG
     （含 N 张典型样本缩略图 + 投票模板），便于人工核对每个聚类对应的数字。
   - 不交互：聚类结果完全靠相似度合并，人工复核只看 PNG，按键 0~9 给每聚类打标。

 输出文件：
   - models/speed_glyphs.json：Swift 端加载的字模库（当前只有 "0" 占位，
     其他聚类先留空位，标注后再补）。
   - tools/speed_clusters.png：聚类可视化（每个聚类一行：N 张样本 + 投票模板）。
================================================================================
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import numpy as np
from PIL import Image


# ─────────────────────────────────────────────────────────────────────────────
# 槽位定义（与 Swift SpeedOCRReader 同源常量；改这里必须同步改 Swift 端）
# ─────────────────────────────────────────────────────────────────────────────
# 三个数字槽的归一化 x 中心（0~1，原点在左上角，x 向右）
# 2026-08-15 由 clip_20260815_130055 实测：ROI 内 digit centers ≈ [71,120,169]px
# 换算回全屏归一化 = [0.479, 0.496, 0.512]
SLOT_CENTERS_NORM = (0.479, 0.496, 0.512)
# 每个槽的归一化宽度（0~1）。实测最大数字宽度 ≈ 41px / 2940px = 0.014。
# 旧值 0.022 导致相邻槽重叠 17~21px，是污染模板、产生重复聚类的主因。
SLOT_WIDTH_NORM = 0.014
# 数字本体的归一化 y 上下界（0~1，原点左上角，y 向下）。
# 关键：y_min 必须跳过仪表台顶部反光带（dashboard reflection strip），
# 否则 Otsu 会把整张图判定为「亮=前景」，反光占了大半像素，模板被污染。
# 实测反光带在部分帧会下探到 y≈0.89，故 SLOT_Y_MIN_NORM = 0.897 保守取在
# 数字本体起始处，牺牲少量顶部笔画换取二值化稳定。
# y_max 由实测数字底部 0.9319 取 0.932，避免旧 0.924 切掉下半段笔画。
SLOT_Y_MIN_NORM = 0.897
SLOT_Y_MAX_NORM = 0.932

# 字模模式 ROI（与 RecordEngine.glyphROINorm 同源，归一化 x,y,w,h）：
# App「字模模式」录出的帧是速度表区域切片（非全屏），槽位坐标需相对该 ROI
# 换算。传 --roi-norm "0.455,0.885,0.080,0.050" 即启用。
GLYPH_ROI_NORM = (0.455, 0.885, 0.080, 0.050)

# 模板缩放尺寸（与 Swift 端模板匹配一致：宽×高）
TEMPLATE_W = 25
TEMPLATE_H = 45


# ─────────────────────────────────────────────────────────────────────────────
# 图像处理工具
# ─────────────────────────────────────────────────────────────────────────────
def otsu_threshold(gray: np.ndarray) -> int:
    """Otsu 自适应阈值——按图像灰度直方图自动选取前景/背景分割点。

    输入 gray：uint8 灰度图（H×W，0~255）。
    返回：最佳阈值（0~255）；单一灰度（纯色图，非零灰度级 < 2）时返回 0，
    该退化情形由调用方 binarize_otsu 负责转成「全 0 无前景」。
    """
    # 256 bin 直方图
    hist, _ = np.histogram(gray, bins=256, range=(0, 256))
    total = gray.size
    if total == 0:
        return 0
    # 非零灰度级 < 2 → 无法分两类，阈值退化为 0（调用方应返回全 0）
    if int(np.count_nonzero(hist)) < 2:
        return 0
    # 总均值
    sum_all = float(np.dot(np.arange(256), hist))
    sum_bg = 0.0  # 背景（<= t）像素权重累计
    w_bg = 0  # 背景像素数累计
    var_max = 0.0
    thr_best = 0
    for t in range(256):
        w_bg += hist[t]
        if w_bg == 0:
            continue
        w_fg = total - w_bg
        if w_fg == 0:
            break
        sum_bg += t * hist[t]
        m_bg = sum_bg / w_bg
        m_fg = (sum_all - sum_bg) / w_fg
        # 类间方差
        var_between = w_bg * w_fg * (m_bg - m_fg) ** 2
        if var_between > var_max:
            var_max = var_between
            thr_best = t
    return int(thr_best)


def binarize_otsu(gray: np.ndarray) -> np.ndarray:
    """对灰度图做 Otsu 二值化，返回 uint8 0/1 掩码（1=亮=前景=数字笔画）。

    单色退化（非零灰度级 < 2，如全白/全黑帧）→ 返回全 0（视为无前景），
    避免 thr=0 时 `gray>0` 全成立 → 输出全 1 的语义错误。
    """
    hist, _ = np.histogram(gray, bins=256, range=(0, 256))
    if int(np.count_nonzero(hist)) < 2:
        return np.zeros_like(gray, dtype=np.uint8)
    thr = otsu_threshold(gray)
    return (gray > thr).astype(np.uint8)


def crop_slot(gray: np.ndarray, slot_idx: int, roi: tuple[float, float, float, float] | None = None) -> np.ndarray:
    """从灰度图按固定槽位裁出单个数字区域，返回原分辨率灰度子图。

    参数：
      - gray: 输入灰度图（全屏帧 或 字模模式 ROI 切片）
      - slot_idx: 槽位下标 0~2
      - roi: 非 None 时表示 gray 是「速度表 ROI 切片」，其归一化位置 (x,y,w,h)
        在屏幕上（与 RecordEngine.glyphROINorm 同源）。此时把全屏归一化槽位
        坐标换算为相对 ROI 的坐标再裁剪——保证训练窗与运行时裁剪窗像素级一致。

    量化：cx / half_w / y0 / y1 都用 `int(round(...))` 取整，宽度 = 2·round(halfW)。
    与 Swift 端 `cropSlots` 的 round() 量化像素级一致（训练窗 == 运行时裁剪窗）。
    """
    h, w = gray.shape
    if roi is None:
        cx_norm = SLOT_CENTERS_NORM[slot_idx]
        half_w_norm = SLOT_WIDTH_NORM / 2.0
        y0_norm, y1_norm = SLOT_Y_MIN_NORM, SLOT_Y_MAX_NORM
    else:
        # ROI 模式：全屏归一化 → ROI 相对坐标
        rx, ry, rw, rh = roi
        cx_norm = (SLOT_CENTERS_NORM[slot_idx] - rx) / rw
        half_w_norm = (SLOT_WIDTH_NORM / 2.0) / rw
        y0_norm = (SLOT_Y_MIN_NORM - ry) / rh
        y1_norm = (SLOT_Y_MAX_NORM - ry) / rh
    cx = int(round(cx_norm * w))
    half_w = int(round(half_w_norm * w))
    y0 = int(round(y0_norm * h))
    y1 = int(round(y1_norm * h))
    return gray[y0:y1, cx - half_w : cx + half_w]


def resize_nn(arr: np.ndarray, h: int, w: int) -> np.ndarray:
    """最近邻缩放到 (h, w)。二值图用最近邻避免中间灰度。

    与 Swift 端 `SpeedOCRReader.resizeNearest` 同源同形：源下标 =
    linspace(0, srcN-1, dstN) 取整。字模训练与运行时匹配必须同一种缩放，
    否则残差系统性抬高。
    """
    sh, sw = arr.shape
    rs = np.linspace(0, sh - 1, h).astype(np.int64)
    cs = np.linspace(0, sw - 1, w).astype(np.int64)
    return arr[rs[:, None], cs[None, :]]


def erode_binary(mask: np.ndarray, ksize: int = 5, iters: int = 1) -> np.ndarray:
    """5×5 核二值图腐蚀 iters 次——把孤立前景像素和过细笔画抹掉。

    实现：用 scipy 均匀滤波（等价于矩形卷积），窗口内 sum == ksize*ksize 视为
    全前景（min 滤波也能做，这里用 sum 更直观也更快）。
    - 速度表数字抖动时，缩放 + Otsu 后会产生少量像素级噪点；
      5×5 腐蚀一次能把 1~2 px 宽的孤立前景抹平，对真实粗笔画无伤大雅。
    """
    try:
        from scipy.ndimage import uniform_filter
    except ImportError:  # 无 scipy 时回退到慢路径 cumsum
        return _erode_binary_cumsum(mask, ksize, iters)
    out = mask.astype(np.float32)
    for _ in range(iters):
        summed = uniform_filter(out, size=ksize, mode="constant", cval=0.0)
        out = (summed == ksize * ksize).astype(np.uint8)
    return out.astype(np.uint8)


def _erode_binary_cumsum(mask: np.ndarray, ksize: int, iters: int) -> np.ndarray:
    """无 scipy 时的回退实现：用 cumsum 计算 ksize×ksize 窗口和。"""
    out = mask.copy()
    k = ksize
    for _ in range(iters):
        h, w = out.shape
        padded = np.pad(out, 1, mode="constant", constant_values=0)
        # 构造 2D 累计和（行+列方向），S[i,j] = sum(padded[0..i, 0..j])
        cs = padded.cumsum(axis=0).cumsum(axis=1)
        # 窗口 (r..r+k-1, c..c+k-1) 的 sum：
        # sum = S[r+k, c+k] - S[r-1, c+k] - S[r+k, c-1] + S[r-1, c-1]
        # 用切片直接拿，避免 per-cell 调用
        # S indices valid: r+k in [k, h+k-1], c+k in [k, w+k-1]
        a = cs[k : h + k, k : w + k]
        b = cs[0:h, k : w + k]
        c = cs[k : h + k, 0:w]
        d = cs[0:h, 0:w]
        win_sum = a - b - c + d
        out = (win_sum == k * k).astype(np.uint8)
    return out


def make_template(gray: np.ndarray) -> np.ndarray:
    """把原分辨率灰度槽位图处理为标准模板（H=45 × W=25 的 0/1 图）。

    流程：
      1. Otsu 二值化（自适应阈值，免受游戏亮度变化影响）
      2. 缩放到 (TEMPLATE_H, TEMPLATE_W)（最近邻，避免中间灰度）

    说明：5×5 腐蚀会抹掉缩放后的所有笔画（缩放后笔画 ~2 px 宽，5×5 必空）。
    抖动抑制改在 Swift 端用「±1 px 三位置投票匹配」实现（见 SpeedOCRReader
    的 matchDigit 函数），模板与运行时两侧都不做腐蚀，保持一致。
    """
    binary = binarize_otsu(gray)
    return resize_nn(binary, TEMPLATE_H, TEMPLATE_W)


# ─────────────────────────────────────────────────────────────────────────────
# 聚类（按位汉明距离 + 并查集）
# ─────────────────────────────────────────────────────────────────────────────
@dataclass
class Cluster:
    """单个聚类：多个样本 → 一个代表性模板（按位多数投票）。"""
    members: list[int] = field(default_factory=list)  # 样本下标列表
    template: np.ndarray | None = None               # H×W uint8 投票模板
    label: str = ""                                  # 人工标注（0~9，未标为空）


def hamming(a: np.ndarray, b: np.ndarray) -> int:
    """二值模板按位不同像素数（越小越相似）。"""
    return int(np.sum(a != b))


def majority_vote(samples: list[np.ndarray]) -> np.ndarray:
    """同尺寸二值样本按位投票，>50% 视为 1，否则 0。"""
    arr = np.stack(samples, axis=0)
    counts = arr.sum(axis=0)
    h, w = arr.shape[1:]
    # 多数票：>= 一半
    half = arr.shape[0] / 2
    return (counts >= half).astype(np.uint8)


def union_find(n: int) -> tuple[list[int], list[int]]:
    """并查集：parent + rank。"""
    parent = list(range(n))
    rank = [0] * n
    return parent, rank


def uf_find(parent: list[int], x: int) -> int:
    while parent[x] != x:
        parent[x] = parent[parent[x]]  # 路径压缩
        x = parent[x]
    return x


def uf_union(parent: list[int], rank: list[int], x: int, y: int) -> None:
    rx = uf_find(parent, x)
    ry = uf_find(parent, y)
    if rx == ry:
        return
    if rank[rx] < rank[ry]:
        parent[rx] = ry
    elif rank[rx] > rank[ry]:
        parent[ry] = rx
    else:
        parent[ry] = rx
        rank[rx] += 1


def cluster_by_hamming(
    samples: list[np.ndarray], threshold: int
) -> list[Cluster]:
    """对所有样本做并查集合并：汉明距离 < threshold 的归为同一聚类。

    - threshold 越大，聚类越粗（容易把不同数字合并）；
      threshold 越小，聚类越细（容易把同数字的不同形态拆开）。
    - 0~9 共 10 类 + 1 类背景（不可识别）= 11 类典型上限。
    """
    n = len(samples)
    parent, rank = union_find(n)
    for i in range(n):
        for j in range(i + 1, n):
            if hamming(samples[i], samples[j]) < threshold:
                uf_union(parent, rank, i, j)
    # 收集每聚类成员
    roots: dict[int, list[int]] = {}
    for i in range(n):
        r = uf_find(parent, i)
        roots.setdefault(r, []).append(i)
    # 输出
    clusters: list[Cluster] = []
    for r, idxs in roots.items():
        mem_samples = [samples[i] for i in idxs]
        clusters.append(
            Cluster(members=idxs, template=majority_vote(mem_samples))
        )
    # 按大小降序
    clusters.sort(key=lambda c: len(c.members), reverse=True)
    return clusters


# ─────────────────────────────────────────────────────────────────────────────
# 可视化（每个聚类一行：缩略图列表 + 投票模板）
# ─────────────────────────────────────────────────────────────────────────────
def render_clusters_png(
    clusters: list[Cluster],
    samples: list[np.ndarray],
    out_path: Path,
    thumbs_per_cluster: int = 6,
) -> None:
    """输出聚类可视化 PNG，便于人工核对每个聚类对应的数字。

    每行：左侧 N 张样本缩略图（最多 thumbs_per_cluster 张） + 右侧投票模板。
    背景太暗时显示成白底黑前景，方便目测。
    """
    rows = len(clusters)
    if rows == 0:
        return
    cell_w = TEMPLATE_W + 2
    cell_h = TEMPLATE_H + 2
    label_w = 60
    thumbs_w = thumbs_per_cluster * cell_w
    total_w = label_w + thumbs_w + cell_w + 10
    total_h = rows * cell_h + 4

    # 渲染到 RGB 画布
    canvas = np.full((total_h, total_w, 3), 240, dtype=np.uint8)
    for ri, cl in enumerate(clusters):
        y0 = ri * cell_h + 2
        # 标签列（前 label_w 像素写文字 "C# N="）
        # 不画文字（避免依赖 PIL.ImageFont），只用灰度区分背景；标签信息单独打印
        # 缩略图
        for ti, member_idx in enumerate(cl.members[:thumbs_per_cluster]):
            x0 = label_w + ti * cell_w
            m = samples[member_idx]
            canvas[y0 + 1 : y0 + 1 + TEMPLATE_H, x0 + 1 : x0 + 1 + TEMPLATE_W] = (
                np.where(m[:, :, None] == 1, 0, 255).astype(np.uint8)
            )
        # 投票模板
        x0 = label_w + thumbs_w
        m = cl.template
        if m is not None:
            canvas[y0 + 1 : y0 + 1 + TEMPLATE_H, x0 + 1 : x0 + 1 + TEMPLATE_W] = (
                np.where(m[:, :, None] == 1, 0, 255).astype(np.uint8)
            )
    Image.fromarray(canvas).save(out_path)


# ─────────────────────────────────────────────────────────────────────────────
# 字模库 JSON 序列化
# ─────────────────────────────────────────────────────────────────────────────
def build_glyph_json(
    clusters: list[Cluster],
    label_map: dict[int, str] | None = None,
) -> dict:
    """构造字模库 JSON dict（与 Swift 端 SpeedGlyphLibrary 解码结构一致）。"""
    label_map = label_map or {}
    templates: dict[str, list[list[int]]] = {}
    for ci, cl in enumerate(clusters):
        label = label_map.get(ci, cl.label or "")
        if not label:
            continue
        if cl.template is None:
            continue
        # 用聚类模板作为该数字的字模（若有多个聚类同一标签，按投票模板覆盖）
        templates[label] = cl.template.astype(int).tolist()
    return {
        "version": 1,
        "template_width": TEMPLATE_W,
        "template_height": TEMPLATE_H,
        "slot_centers_norm": list(SLOT_CENTERS_NORM),
        "slot_width_norm": SLOT_WIDTH_NORM,
        "slot_y_min_norm": SLOT_Y_MIN_NORM,
        "slot_y_max_norm": SLOT_Y_MAX_NORM,
        "templates": templates,
    }


# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────
def iter_jpeg_or_png(paths: Iterable[Path]) -> Iterable[Path]:
    """过滤 jpg/png 帧路径。"""
    for p in paths:
        if p.suffix.lower() in {".jpg", ".jpeg", ".png"}:
            yield p


def load_frames(frames_dir: Path) -> list[np.ndarray]:
    """加载目录下所有 jpg/png 帧为灰度 np.ndarray 列表。"""
    images: list[np.ndarray] = []
    for p in sorted(iter_jpeg_or_png(frames_dir.iterdir())):
        try:
            im = Image.open(p).convert("L")
        except Exception as exc:  # 损坏文件跳过
            print(f"  skip {p.name}: {exc}", file=sys.stderr)
            continue
        images.append(np.array(im, dtype=np.uint8))
    return images


def main() -> int:
    ap = argparse.ArgumentParser(description="速度表数字字模训练工具")
    ap.add_argument(
        "--frames-dir",
        required=True,
        help="原生全屏帧目录（jpg/png）",
    )
    ap.add_argument(
        "--out-models",
        default="models/speed_glyphs.json",
        help="字模库 JSON 输出路径（默认 models/speed_glyphs.json）",
    )
    ap.add_argument(
        "--clusters-out",
        default="tools/speed_clusters.png",
        help="聚类可视化 PNG 输出路径（人工核对用）",
    )
    ap.add_argument(
        "--hamming-threshold",
        type=int,
        default=80,
        help="汉明距离并查集阈值（默认 80；越小聚类越细）",
    )
    ap.add_argument(
        "--max-frames",
        type=int,
        default=200,
        help="最多采样帧数（默认 200；超过则均匀采样）",
    )
    ap.add_argument(
        "--default-zero",
        action="store_true",
        help="把最大聚类直接标为 '0' 字模（怠速录屏场景）",
    )
    ap.add_argument(
        "--roi-norm",
        default=None,
        help="帧是速度表 ROI 切片时的归一化位置 'x,y,w,h'（与 RecordEngine "
             "glyphROINorm 同源，如 0.455,0.885,0.080,0.050）；缺省表示输入是"
             "全屏帧。App 字模模式录出的帧必须传这个参数。",
    )
    args = ap.parse_args()

    # ROI 模式解析：全屏帧 → None；切片帧 → (x, y, w, h)
    roi: tuple[float, float, float, float] | None = None
    if args.roi_norm:
        parts = [float(v) for v in args.roi_norm.split(",")]
        if len(parts) != 4:
            print("--roi-norm 需要 4 个逗号分隔值: x,y,w,h", file=sys.stderr)
            return 2
        roi = (parts[0], parts[1], parts[2], parts[3])
        print(f"      ROI 模式: 帧为速度表切片 (x={parts[0]},y={parts[1]},w={parts[2]},h={parts[3]})")

    frames_dir = Path(args.frames_dir)
    if not frames_dir.is_dir():
        print(f"frames dir not found: {frames_dir}", file=sys.stderr)
        return 2

    print(f"[1/4] load frames from {frames_dir} ...")
    frames = load_frames(frames_dir)
    if not frames:
        print("no frames loaded", file=sys.stderr)
        return 2
    print(f"      loaded {len(frames)} frames")

    # 均匀采样
    n = len(frames)
    if n > args.max_frames:
        idx = np.linspace(0, n - 1, args.max_frames).astype(int)
        frames = [frames[i] for i in idx]
    print(f"      sampling to {len(frames)} frames")

    # 提取每帧的 3 个槽位 → 模板
    print(f"[2/4] crop slots + binarize + resize ...")
    samples: list[np.ndarray] = []
    for fi, gray in enumerate(frames):
        for si in range(3):
            sub = crop_slot(gray, si, roi=roi)
            if sub.size == 0:
                continue
            tmpl = make_template(sub)
            samples.append(tmpl)
        if fi % 50 == 0:
            print(f"      frame {fi}/{len(frames)}")
    print(f"      {len(samples)} slot samples")

    # 聚类
    print(f"[3/4] cluster by Hamming distance (< {args.hamming_threshold}) ...")
    clusters = cluster_by_hamming(samples, threshold=args.hamming_threshold)
    print(f"      {len(clusters)} clusters:")
    for ci, cl in enumerate(clusters):
        print(f"        C{ci}: {len(cl.members):5d} members")

    # 可视化
    out_clusters = Path(args.clusters_out)
    out_clusters.parent.mkdir(parents=True, exist_ok=True)
    render_clusters_png(clusters, samples, out_clusters)
    print(f"[4/4] clusters visualization → {out_clusters}")

    # 字模 JSON
    label_map: dict[int, str] = {}
    if args.default_zero and clusters:
        # 怠速录屏场景：最大聚类通常是 "0"
        label_map[0] = "0"
        print("      default-zero mode: C0 → '0'")
    glyph = build_glyph_json(clusters, label_map=label_map)
    out_models = Path(args.out_models)
    out_models.parent.mkdir(parents=True, exist_ok=True)
    out_models.write_text(json.dumps(glyph, ensure_ascii=False, indent=2))
    print(f"      glyph library → {out_models} (labels: {list(glyph['templates'].keys())})")
    return 0


if __name__ == "__main__":
    sys.exit(main())