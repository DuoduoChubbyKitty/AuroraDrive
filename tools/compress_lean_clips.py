#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把已录制的 lean_clips 帧压缩到模型输入尺寸（384×224，q0.90）。

【为什么需要这个脚本】
录制器原先存 1280×832 原图 + JPEG q0.92，实测 365 KB/帧 = 18.8 GB/小时；
而 `dataset_v3` 训练时第一件事就是 `resize((384, 224))` —— 存的像素里约 92%
在训练时被直接丢弃。2026-11-04 用户拍板改为直接存模型尺寸，录制器已改
（`LeanRecordEngine.storeWidth/storeHeight`），本脚本负责把**改之前已录的
历史数据**也收敛到同一格式，否则新旧数据混用会得到两种分布。

【关键安全设计】
  · 绝不原地覆盖：先写到目标目录同级的临时树 `.<clip>.compressing/`，
    全部帧成功 + 逐项校验通过后，才 `os.replace` 换成正式目录。中途失败
    只删临时树，原数据一个字节都不动。
  · 逐帧校验：压缩后回读，断言像素尺寸 == 384×224 且能被 PIL 解码。
    只信"文件写成功"是不够的 —— JPEG 截断在 size 上看起来是成功的。
  · 帧号严格守恒：输出文件名与输入一一对应，不新增、不遗漏、不改名。
    `dataset_v3` 依赖「CSV 第 j 行 ⟷ frames/0000jj.jpg」这条硬约束，
    这里少一帧就会让整段数据静默错位。
  · CSV 不重写：按键标签与帧号无关，只和行序有关，压缩不改变行序。

【不覆盖什么（诚实边界）】
  · 不重新跑速度 OCR。压缩后速度表 ROI 从 102×42 变成 31×11 像素，
    已有的 speed_kmh 是在高分辨率下识别出来的、质量更好，保留即可。
    只有**未标注**的帧才需要将来按新尺寸重跑（实测 224×384 下
    PP-OCR 仍有 295/298 帧数值完全正确，见 docs/整合文档）。
  · 不修改 meta.json 的 width/height —— 由本脚本显式改写，因为 meta 的
    唯一用途就是事后判断这份数据的分辨率，留着 1280×832 就是错误信息。

跑法：
    # 预演（只统计，不写盘）
    python3 tools/compress_lean_clips.py --root data/lean_clips --dry-run

    # 实跑
    python3 tools/compress_lean_clips.py --root data/lean_clips

    # 只处理指定片段
    python3 tools/compress_lean_clips.py --root data/lean_clips \
        --only clip_20261104_211247

退出码：0=全部成功；1=有片段失败（失败项逐条打印，原数据未动）
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - 环境缺失时给出可操作提示
    print("需要 Pillow：python3 -m pip install pillow", file=sys.stderr)
    raise SystemExit(1)

# 与 `LeanRecordEngine.storeWidth/storeHeight` 必须逐字一致。
# 训练端 `dataset_v3.image_size = (224, 384)` 是 (H, W)，此处按 (W, H) 书写。
STORE_WIDTH = 384
STORE_HEIGHT = 224
JPEG_QUALITY = 90

# 重采样用 LANCZOS：一次性把 1280→384 缩小 3.3 倍，双线性会产生明显锯齿，
# 而这是**最后一次**降采样机会（源图压缩后即丢弃），质量优先。
RESAMPLE = Image.LANCZOS


def find_clips(root: Path, only: list[str]) -> list[Path]:
    """列出所有含 frames/ 的片段目录，按名排序（顺序影响日志可读性）。"""
    clips = sorted(p for p in root.iterdir() if p.is_dir() and (p / "frames").is_dir())
    if only:
        wanted = set(only)
        clips = [c for c in clips if c.name in wanted]
        missing = wanted - {c.name for c in clips}
        if missing:
            raise SystemExit(f"指定的片段不存在：{sorted(missing)}")
    return clips


def compress_frames(src_dir: Path, dst_dir: Path) -> tuple[int, int, int]:
    """把 src_dir 下所有 jpg 压缩进 dst_dir。

    Returns: (帧数, 原始字节数, 压缩后字节数)
    Raises: RuntimeError 当任何一帧失败（调用方负责清理临时树）
    """
    dst_dir.mkdir(parents=True, exist_ok=True)
    names = sorted(p.name for p in src_dir.iterdir() if p.suffix.lower() == ".jpg")
    if not names:
        raise RuntimeError(f"{src_dir} 下没有 jpg 帧")

    total_src = 0
    total_dst = 0
    for i, name in enumerate(names, 1):
        src = src_dir / name
        dst = dst_dir / name
        total_src += src.stat().st_size
        try:
            with Image.open(src) as im:
                # convert("RGB")：源是 JPEG，理论上已是 RGB；显式转换是为了
                # 对付灰度/CMYK 等异常编码，避免 save 时抛错中断整段。
                out = im.convert("RGB").resize((STORE_WIDTH, STORE_HEIGHT), RESAMPLE)
                out.save(dst, "JPEG", quality=JPEG_QUALITY, optimize=True)
        except Exception as exc:  # noqa: BLE001 - 需要把具体帧号带进错误信息
            raise RuntimeError(f"压缩失败 {name}：{exc}") from exc

        # 回读校验：只信 write 成功是不够的，JPEG 截断/编码器异常都可能写出坏图
        try:
            with Image.open(dst) as chk:
                if (chk.width, chk.height) != (STORE_WIDTH, STORE_HEIGHT):
                    raise RuntimeError(
                        f"校验失败 {name}：尺寸 {chk.width}×{chk.height}，"
                        f"期望 {STORE_WIDTH}×{STORE_HEIGHT}")
                chk.verify()   # 检测文件截断/CRC 错误
        except RuntimeError:
            raise
        except Exception as exc:
            raise RuntimeError(f"校验失败 {name}：{exc}") from exc

        total_dst += dst.stat().st_size
        if i % 500 == 0 or i == len(names):
            print(f"      {i}/{len(names)} 帧", flush=True)

    return len(names), total_src, total_dst


def update_meta(clip_dir: Path) -> bool:
    """把 meta.json 的 width/height 改成实际落盘尺寸。返回是否改动了文件。"""
    meta_path = clip_dir / "meta.json"
    if not meta_path.exists():
        return False
    with meta_path.open() as f:
        meta = json.load(f)
    if meta.get("width") == STORE_WIDTH and meta.get("height") == STORE_HEIGHT:
        return False
    meta["width"] = STORE_WIDTH
    meta["height"] = STORE_HEIGHT
    # 用与 Swift 侧一致的 pretty-printed 格式，便于人工 diff。
    # tmp + replace 保证不会留下半个 JSON（与录制器 writeMeta 的 .atomic 同款理由）。
    tmp = meta_path.with_suffix(".json.tmp")
    with tmp.open("w") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False, sort_keys=True)
    os.replace(tmp, meta_path)
    return True


def process_clip(clip: Path, dry_run: bool) -> dict:
    """处理单个片段。返回统计字典；失败时抛异常，由调用方决定是否继续。"""
    frames = clip / "frames"
    results = {
        "clip": clip.name,
        "frames": 0,
        "bytes_before": 0,
        "bytes_after": 0,
        "meta_updated": False,
    }

    if dry_run:
        jpgs = [p for p in frames.iterdir() if p.suffix.lower() == ".jpg"]
        results["frames"] = len(jpgs)
        results["bytes_before"] = sum(p.stat().st_size for p in jpgs)
        # 预估：按实测 384×224 q90 的 27 KB/帧；仅用于预演展示，不写入任何结论
        results["bytes_after"] = len(jpgs) * 27 * 1024
        return results

    # 临时树放在 clip 同级，保证同一文件系统 → os.replace 是原子改名而非拷贝
    staging = clip.parent / f".{clip.name}.compressing"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    try:
        # 1) 先把不属于帧的附属文件复制过去（CSV 绝不重写，逐字节拷贝）
        for extra in clip.iterdir():
            if extra.name == "frames":
                continue
            if extra.is_dir():
                shutil.copytree(extra, staging / extra.name)
            else:
                shutil.copy2(extra, staging / extra.name)

        # 2) 压缩帧
        n, before, after = compress_frames(frames, staging / "frames")
        results.update(frames=n, bytes_before=before, bytes_after=after)

        # 3) 帧号守恒校验：输出帧数必须与输入严格相等，文件名集合必须一致
        src_names = {p.name for p in frames.iterdir() if p.suffix.lower() == ".jpg"}
        dst_names = {p.name for p in (staging / "frames").iterdir()
                     if p.suffix.lower() == ".jpg"}
        if src_names != dst_names:
            raise RuntimeError(
                f"帧文件集合不一致：缺 {sorted(src_names - dst_names)[:5]} "
                f"多 {sorted(dst_names - src_names)[:5]}")

        # 4) CSV 字节级比对：压缩不应触碰标签
        for csv_name in ("controls.csv",):
            a, b = clip / csv_name, staging / csv_name
            if a.exists():
                if not b.exists() or a.read_bytes() != b.read_bytes():
                    raise RuntimeError(f"{csv_name} 在暂存区被改动（不应发生）")

        # 5) 原子换位：旧目录先改名做后备，新目录顶上，再删后备。
        #    不用 shutil.rmtree(clip) 后 rename —— 那中间有一段"数据不存在"的窗口。
        backup = clip.parent / f".{clip.name}.precompress"
        if backup.exists():
            shutil.rmtree(backup)
        os.replace(clip, backup)
        try:
            os.replace(staging, clip)
        except Exception:
            os.replace(backup, clip)   # 换位失败：把原数据放回去
            raise
        results["meta_updated"] = update_meta(clip)
        shutil.rmtree(backup)
        return results
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    ap = argparse.ArgumentParser(description="把 lean_clips 帧压缩到 384×224")
    ap.add_argument("--root", required=True, help="lean_clips 根目录")
    ap.add_argument("--only", nargs="*", default=[], help="只处理指定片段名")
    ap.add_argument("--dry-run", action="store_true", help="只统计，不写盘")
    args = ap.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"根目录不存在：{root}", file=sys.stderr)
        return 1

    clips = find_clips(root, args.only)
    if not clips:
        print(f"{root} 下没有找到任何片段", file=sys.stderr)
        return 1

    print(f"目标格式：{STORE_WIDTH}×{STORE_HEIGHT}  JPEG q{JPEG_QUALITY}")
    print(f"片段数：{len(clips)}" + ("（预演，不写盘）" if args.dry_run else ""))
    print()

    rows = []
    failures = []
    for clip in clips:
        print(f"── {clip.name}")
        try:
            r = process_clip(clip, args.dry_run)
            rows.append(r)
            before_mb = r["bytes_before"] / 1024 / 1024
            after_mb = r["bytes_after"] / 1024 / 1024
            ratio = (r["bytes_after"] / r["bytes_before"] * 100) if r["bytes_before"] else 0
            print(f"   ✓ {r['frames']} 帧  {before_mb:.1f} MB → {after_mb:.1f} MB"
                  f"（{ratio:.0f}%）" + ("  meta 已更新" if r["meta_updated"] else ""))
        except Exception as exc:  # noqa: BLE001 - 单个片段失败不应中断其余片段
            failures.append((clip.name, str(exc)))
            print(f"   ✗ {exc}")
        print()

    total_before = sum(r["bytes_before"] for r in rows)
    total_after = sum(r["bytes_after"] for r in rows)
    total_frames = sum(r["frames"] for r in rows)
    print("═══ 汇总 ═══")
    print(f"  成功片段：{len(rows)} / {len(clips)}")
    print(f"  总帧数：{total_frames}")
    print(f"  体积：{total_before/1024/1024/1024:.2f} GB → {total_after/1024/1024/1024:.2f} GB"
          f"（{(total_after/total_before*100) if total_before else 0:.1f}%）")
    if total_frames:
        per_frame_kb = total_after / total_frames / 1024
        print(f"  平均：{per_frame_kb:.1f} KB/帧 → {per_frame_kb*15*3600/1024/1024:.2f} GB/小时")
    if failures:
        print(f"\n  失败 {len(failures)} 个（原数据未动）：")
        for name, err in failures:
            print(f"    · {name}: {err}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
