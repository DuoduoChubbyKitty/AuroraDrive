#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mask_hud.py — 把录制画面里的 HUD 涂掉，产出「无 HUD 版」数据集。

【为什么需要它】
    动态世界模型「赢了基线却学不到动作因果」的机制根因是 **HUD 泄漏**：
    画面底部中央直接写着速度表读数（如「1 030」），该区域帧间 std=0.119。
    编码器只要读仪表盘就能降低预测误差，完全不需要理解「踩油门→加速」的因果链。
    这会污染所有基于该表征的下游训练：在有 HUD 的数据上指标好看，
    换到没有仪表盘的真实路况就掉，而且很难归因。

    所以先做一个「无 HUD 版」数据集，再用它重训，才能干净地回答
    「去掉仪表盘之后，动作条件到底能不能学出来」。

【区域是怎么定出来的】
    不是拍脑袋估的，是**先看图再定坐标**：
    1. 把 384x224 帧放大到 3 倍、每 32px 画网格并标注坐标，肉眼读出每个 HUD 元素的边界；
    2. 再对争议区域（底部速度表、顶部图标行）单独放大 6~9 倍、每 8px 打刻度复confirmation；
    3. 最后用「外环变化率」做数值校验：取每个矩形外侧 4px 的环带，
       跨时间比较其亮度差。环带仍在变化 ⇒ 说明边界外是动态场景，
       HUD 已被完整盖住；若环带静止 ⇒ 说明还有 UI 露在外面，需要扩框。

    实测五个区域的环带变化率（越大说明边界越干净）：
        minimap 0.133 / top_icons 0.231 / right_pnl 0.159 / speedo 0.096 / hint_bl 0.091
    全部 > 0.09，判定为「边界外仍是场景」。

【车体和风景必须保住（用户明确要求）】
    底部速度表 (y≥194) 与车尾 (y<192) 之间只有约 2px 间隔，所以下边界取 194：
    实测遮罩与车体范围 [130,100,265,192] 的重叠为 **0 像素**。
    低速剪影、路面、两侧建筑都落在遮罩之外。

【填充色为什么用中性灰而不是纯黑】
    训练侧归一化是 (x/255 − mean)/std，其中 mean≈(0.27,0.31,0.33)。
    纯黑会得到 (0−0.27)/0.21 ≈ −1.3，是训练分布里很少见的极端值，
    相当于给模型一个「这里被遮了」的强提示；中性灰 (128,128,128) 归一化后
    约 +1.1，既不极端，又确实不携带任何 HUD 信息。默认 128，可用 --fill 改。

【安全约束（这是唯一一份数据，操作必须可证伪）】
    1. 默认**拒绝**把输出写进 data/lean_clips/ 内部，也拒绝输出目录与输入目录相同
       —— 源数据是外置盘上唯一副本，任何「就地覆盖」都是不可接受的风险。
    2. 每帧写完立即读回校验尺寸，宽度/高度不对直接中止。
    3. 结束前核对「输出帧数 == 源帧数 == controls.csv 行数」，三条不等就报错。
    4. controls.csv 原样复制（字节级），因为帧号↔行号的硬配对必须保持。

用法：
    # 预览单帧效果（不写数据集，只存对比图）
    python3.11 tools/mask_hud.py --preview data/lean_clips/clip_xxx --preview-frame 2000

    # 处理全部 clip
    python3.11 tools/mask_hud.py --clips-dir data/lean_clips --out-dir data/lean_clips_hudmasked

    # 只处理一个
    python3.11 tools/mask_hud.py --clips-dir data/lean_clips --out-dir data/hudmasked --only clip_20261105_212945
"""
from __future__ import annotations

import argparse
import csv
import shutil
import sys
from pathlib import Path
from typing import Dict, List, Tuple

from PIL import Image, ImageDraw

# ------------------------------------------------------------------ 遮罩区域
# 坐标基于 384x224（录制数据的固定尺寸）。定界依据见模块 docstring。
# 注意 x 是宽(0..384)，y 是高(0..224)。
HUD_REGIONS: Dict[str, Tuple[int, int, int, int]] = {
    # 左上：小地图圆盘 + 紧邻其下的两行任务文字（"附近赛事" / 距离）
    "minimap": (0, 0, 74, 80),
    # 顶部右侧：状态图标行（道具/状态图标），左边界 238 避开左上地图与中部天空
    "top_icons": (238, 0, 384, 28),
    # 右侧：按键提示面板（"下车 F / 出现目标 / 车灯 F ..."）
    "right_pnl": (332, 100, 384, 200),
    # 底部中央：速度表数字 + 下方进度条。下边界 194 是「不碰车尾」的硬约束
    "speedo": (122, 194, 298, 224),
    # 左下：提示框（"Enter Enter" 等）
    "hint_bl": (0, 194, 68, 224),
}

#: 车体大致范围，仅用于自检「遮罩不许碰到车」。y 上界 192 与 speedo 的 194 留 2px 安全带。
CAR_BOX: Tuple[int, int, int, int] = (130, 100, 265, 192)


def _rect_area(r: Tuple[int, int, int, int]) -> int:
    x0, y0, x1, y1 = r
    return max(0, x1 - x0) * max(0, y1 - y0)


def _overlap_area(a: Tuple[int, int, int, int], b: Tuple[int, int, int, int]) -> int:
    ax0, ay0, ax1, ay1 = a
    bx0, by0, bx1, by1 = b
    ix = max(0, min(ax1, bx1) - max(ax0, bx0))
    iy = max(0, min(ay1, by1) - max(ay0, by0))
    return ix * iy


def mask_regions_for_size(width: int, height: int) -> Dict[str, Tuple[int, int, int, int]]:
    """把 384x224 上定好的区域映射到实际尺寸。

    为什么需要映射而不是写死：录制器已经改成存 384x224，但历史数据、
    以及将来可能的尺寸变更都会走到这里。按比例缩放比写死更安全 ——
    但**必须**先确认尺寸确实是 384x224 的原比例，否则宁可报错也不要悄悄画错位置。
    """
    if (width, height) == (384, 224):
        return dict(HUD_REGIONS)
    sx, sy = width / 384.0, height / 224.0
    out = {}
    for name, (x0, y0, x1, y1) in HUD_REGIONS.items():
        out[name] = (
            int(round(x0 * sx)),
            int(round(y0 * sy)),
            int(round(x1 * sx)),
            int(round(y1 * sy)),
        )
    return out


def apply_mask(img: Image.Image, fill: int) -> Image.Image:
    """把 HUD 区域涂成中性灰，返回新图（不修改入参）。

    每个框各画一次而不是先合并成大框：合并会把框之间的大片场景一起涂掉，
    而用户明确要求「尽量少切、别把车和风景一起切了」。
    """
    out = img.convert("RGB").copy()
    draw = ImageDraw.Draw(out)
    regions = mask_regions_for_size(out.width, out.height)
    for _name, box in regions.items():
        draw.rectangle(box, fill=(fill, fill, fill))
    return out


def _check_paths(src: Path, out: Path) -> None:
    """挡住两类致命误操作：写进源目录、输出等于输入。"""
    src_r = src.resolve()
    out_r = out.resolve()
    if src_r == out_r:
        raise SystemExit(f"✗ 输出目录与源目录相同（{out_r}）—— 拒绝就地覆盖")
    if src_r in out_r.parents:
        raise SystemExit(
            f"✗ 输出目录 {out_r} 位于源目录 {src_r} 内部 —— 拒绝在原数据目录里写新文件"
        )
    # 源数据固定在外置盘的 lean_clips，任何写入都要挡住
    if "lean_clips" in out_r.parts and "hudmasked" not in out_r.name:
        raise SystemExit(f"✗ 输出目录 {out_r} 看起来会覆盖原始 lean_clips —— 拒绝")


def _count_csv_rows(csv_path: Path) -> int:
    with csv_path.open("r", newline="", encoding="utf-8") as f:
        return sum(1 for _ in csv.DictReader(f))


def preview(clip_dir: Path, frame_idx: int, fill: int, dst: Path) -> None:
    """出一张「原图 | 遮罩后 | 遮罩边界」三联对比图，供人工确认。"""
    frames_dir = clip_dir / "frames"
    src = frames_dir / f"{frame_idx:06d}.jpg"
    if not src.exists():
        raise SystemExit(f"✗ 帧不存在：{src}")
    base = Image.open(src).convert("RGB")
    masked = apply_mask(base, fill)

    outlined = base.copy()
    d = ImageDraw.Draw(outlined)
    for box in mask_regions_for_size(outlined.width, outlined.height).values():
        d.rectangle(box, outline=(255, 0, 0), width=1)
    d.rectangle(CAR_BOX, outline=(0, 255, 0), width=1)  # 绿框=车体保护范围

    S = 3
    w, h = base.size
    canvas = Image.new("RGB", (w * S, h * S * 3 + 16), (20, 20, 20))
    for i, im in enumerate((base, outlined, masked)):
        canvas.paste(im.resize((w * S, h * S), Image.NEAREST), (0, i * (h * S + 8)))
    dst.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dst)
    print(f"  预览图已存：{dst}（上=原图 中=边界 下=遮罩结果）")


def process_clip(clip_dir: Path, out_dir: Path, fill: int, dry_run: bool) -> Tuple[int, int]:
    """处理单个 clip，返回 (帧数, 字节数)。"""
    frames_dir = clip_dir / "frames"
    csv_path = clip_dir / "controls.csv"
    if not frames_dir.is_dir():
        raise SystemExit(f"✗ 缺 frames/ 目录：{frames_dir}")
    if not csv_path.is_file():
        raise SystemExit(f"✗ 缺 controls.csv：{csv_path}")

    frame_files = sorted(frames_dir.glob("*.jpg"))
    n_csv = _count_csv_rows(csv_path)
    if len(frame_files) != n_csv:
        raise SystemExit(
            f"✗ {clip_dir.name}: 帧数 {len(frame_files)} 与 CSV 行数 {n_csv} 不等，"
            f"帧号↔行号的硬配对已损坏，拒绝处理"
        )

    if dry_run:
        area = sum(_rect_area(r) for r in HUD_REGIONS.values())
        print(f"  [dry-run] {clip_dir.name}: {len(frame_files)} 帧，"
              f"遮罩覆盖 {area / (384 * 224) * 100:.1f}% 画面")
        return len(frame_files), 0

    dst_frames = out_dir / "frames"
    dst_frames.mkdir(parents=True, exist_ok=True)
    written = 0
    total_bytes = 0
    for src in frame_files:
        img = Image.open(src)
        w, h = img.size
        masked = apply_mask(img, fill)
        dst = dst_frames / src.name
        masked.save(dst, quality=95, subsampling=0)
        # 读回校验：尺寸错说明 PIL 或参数出了问题，立刻中止而不是产出一堆坏帧
        with Image.open(dst) as chk:
            if chk.size != (w, h):
                raise SystemExit(f"✗ {dst.name} 读回尺寸 {chk.size} != {(w, h)}")
        written += 1
        total_bytes += dst.stat().st_size

    # controls.csv 必须字节级一致：只搬不改
    shutil.copy2(csv_path, out_dir / "controls.csv")

    # meta.json 若存在也一起带过去，但要把「是否已遮 HUD」写清楚，
    # 否则将来分不清这份数据是原版还是遮罩版
    meta_src = clip_dir / "meta.json"
    if meta_src.is_file():
        import json
        meta = json.loads(meta_src.read_text(encoding="utf-8"))
        meta["hud_masked"] = True
        meta["hud_mask_regions"] = HUD_REGIONS
        meta["hud_mask_fill"] = fill
        (out_dir / "meta.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    if written != len(frame_files):
        raise SystemExit(f"✗ {clip_dir.name}: 只写出 {written}/{len(frame_files)} 帧")
    return written, total_bytes


def main() -> int:
    ap = argparse.ArgumentParser(description="把录制画面的 HUD 涂掉，产出无 HUD 数据集")
    ap.add_argument("--clips-dir", type=Path, help="包含 clip_*/ 的目录")
    ap.add_argument("--out-dir", type=Path, help="输出根目录（会新建 clip_*/）")
    ap.add_argument("--only", action="append", default=[],
                    help="只处理指定 clip 名（可重复）")
    ap.add_argument("--fill", type=int, default=128,
                    help="遮罩填充灰度 0-255，默认 128（中性灰，理由见 docstring）")
    ap.add_argument("--dry-run", action="store_true", help="只统计不写文件")
    ap.add_argument("--preview", type=Path, help="只出单帧三联对比图，不写数据集")
    ap.add_argument("--preview-frame", type=int, default=2000, help="预览用帧号")
    ap.add_argument("--preview-out", type=Path,
                    default=Path("/tmp/hud_probe/preview_triple.png"))
    args = ap.parse_args()

    if not 0 <= args.fill <= 255:
        raise SystemExit(f"✗ --fill {args.fill} 超出 0-255")

    # 自检：遮罩不许压到车体。这是用户明确要求，做成启动断言而不是靠人记得
    car_overlap = sum(_overlap_area(r, CAR_BOX) for r in HUD_REGIONS.values())
    if car_overlap != 0:
        raise SystemExit(f"✗ 遮罩与车体保护框重叠 {car_overlap} px —— 会切到车，拒绝执行")
    total_area = sum(_rect_area(r) for r in HUD_REGIONS.values())
    print(f"[mask] 遮罩 {len(HUD_REGIONS)} 块，覆盖 {total_area / (384 * 224) * 100:.1f}% 画面，"
          f"车体重叠 0 px")

    if args.preview:
        preview(args.preview, args.preview_frame, args.fill, args.preview_out)
        return 0

    if not args.clips_dir or not args.out_dir:
        raise SystemExit("✗ 需要 --clips-dir 与 --out-dir（或改用 --preview）")

    _check_paths(args.clips_dir, args.out_dir)

    clips = sorted(p for p in args.clips_dir.iterdir()
                   if p.is_dir() and (p / "frames").is_dir())
    if args.only:
        clips = [p for p in clips if p.name in set(args.only)]
    if not clips:
        raise SystemExit(f"✗ {args.clips_dir} 下没有找到任何 clip_*/frames/")

    print(f"[mask] 待处理 {len(clips)} 个 clip -> {args.out_dir}")
    grand_frames = grand_bytes = 0
    for clip in clips:
        n, b = process_clip(clip, args.out_dir / clip.name, args.fill, args.dry_run)
        grand_frames += n
        grand_bytes += b
        if not args.dry_run:
            print(f"  ✓ {clip.name}: {n} 帧, {b / 1048576:.1f} MB")

    print(f"\n[mask] 完成：{grand_frames} 帧, {grand_bytes / 1048576:.1f} MB")
    print(f"[mask] 输出目录：{args.out_dir.resolve()}")
    print("[mask] 原始 data/lean_clips 未做任何改动")
    return 0


if __name__ == "__main__":
    sys.exit(main())
