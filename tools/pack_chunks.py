#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按分片把清洗后数据打成多个 aurora_train_pack_partNN.zip（每个 ≤ 设定上限），
供网页上传（单文件过大网页会中途失败）。

复用 pack_clean_train 的重编号 + 硬链接逻辑：
  · 帧按顺序硬链接成 000000.jpg..(N-1).jpg
  · CSV frame 列重编号为 0..N-1，t_sec 保留原值
  · speed_kmh 留空

用法：
  # 只看分片计划
  python3 tools/pack_chunks.py --plan --limit-mb 350
  # 打第 i 个分片（1 起）
  python3 tools/pack_chunks.py --build-index 1 --limit-mb 350
  # 打全部分片
  python3 tools/pack_chunks.py --build-all --limit-mb 350
"""
from __future__ import annotations

import argparse
import csv
import os
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLEAN = ROOT / "data" / "lean_clips_clean"
ORIG = ROOT / "data" / "lean_clips"
STAGING = Path("/Volumes/系统/aurora_pack_staging")
OUTDIR = Path.home() / "Desktop"
HEADER = ["t_sec", "frame", "speed_kmh", "w", "a", "s", "d",
          "shift", "space", "super_brake", "ultimate_brake"]
KEY_COLS = ["w", "a", "s", "d", "shift", "space", "super_brake", "ultimate_brake"]
MIN_FRAMES = 20


def clip_info(clip: str):
    """返回 (frames, bytes) 或 None。"""
    clean_dir = CLEAN / clip
    fl = clean_dir / "frames_clean.txt"
    if not fl.exists():
        return None
    names = [l.strip() for l in open(fl, encoding="utf-8") if l.strip()]
    if len(names) < MIN_FRAMES:
        return None
    fb = ORIG / clip / "frames"
    sz = sum(os.path.getsize(fb / n) for n in names if (fb / n).exists())
    sz += os.path.getsize(clean_dir / "controls_clean.csv")
    return (len(names), sz)


def plan_chunks(limit_mb: int):
    clips = sorted(d.name for d in CLEAN.glob("clip_*") if d.is_dir())
    items = []
    for c in clips:
        info = clip_info(c)
        if info:
            items.append((c, info[0], info[1]))
    items.sort(key=lambda x: -x[2])
    lim = limit_mb * 1024 * 1024
    chunks, cur, cursz = [], [], 0
    for c, n, sz in items:
        if cur and cursz + sz > lim:
            chunks.append(cur); cur, cursz = [], 0
        cur.append(c); cursz += sz
    if cur:
        chunks.append(cur)
    return chunks, items


def build_clip_into(clip: str, staging: Path):
    clean_dir = CLEAN / clip
    rows = list(csv.DictReader(open(clean_dir / "controls_clean.csv", newline="", encoding="utf-8")))
    kept = [l.strip() for l in open(clean_dir / "frames_clean.txt", encoding="utf-8") if l.strip()]
    orig_frames = ORIG / clip / "frames"
    out = staging / "payload" / clip
    if out.exists():
        shutil.rmtree(out)
    (out / "frames").mkdir(parents=True)
    for k, (row, fn) in enumerate(zip(rows, kept)):
        src, dst = orig_frames / fn, out / "frames" / f"{k:06d}.jpg"
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)
    with open(out / "controls.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(HEADER)
        for k, row in enumerate(rows):
            w.writerow([row["t_sec"], k, ""] + [row.get(c, "0") or "0" for c in KEY_COLS])


def build_chunk(chunk_clips, index: int):
    staging = STAGING / f"chunk{index:02d}"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    for c in chunk_clips:
        build_clip_into(c, staging)
    out_zip = OUTDIR / f"aurora_train_pack_part{index:02d}.zip"
    if out_zip.exists():
        out_zip.unlink()
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        payload = staging / "payload"
        for p in sorted(payload.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(payload))
    size_mb = out_zip.stat().st_size / 1024 / 1024
    shutil.rmtree(staging, ignore_errors=True)
    return out_zip, size_mb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit-mb", type=int, default=350)
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--build-index", type=int, default=None)
    ap.add_argument("--build-all", action="store_true")
    args = ap.parse_args()

    chunks, items = plan_chunks(args.limit_mb)
    if args.plan:
        print(f"共 {len(chunks)} 个分片（上限 {args.limit_mb}MB）:")
        for i, ch in enumerate(chunks, 1):
            sz = sum(clip_info(c)[1] for c in ch)
            print(f"  分片{i}: {len(ch)}clip {sz/1024/1024:.0f}MB  {','.join(c.replace('clip_','') for c in ch)}")
        return
    if args.build_index:
        i = args.build_index
        zp, mb = build_chunk(chunks[i-1], i)
        print(f"✅ 分片{i}: {zp} ({mb:.0f}MB)  clips={[c.replace('clip_','') for c in chunks[i-1]]}")
        return
    if args.build_all:
        for i, ch in enumerate(chunks, 1):
            zp, mb = build_chunk(ch, i)
            print(f"✅ 分片{i}/{len(chunks)}: {zp.name} ({mb:.0f}MB)", flush=True)
        return
    ap.print_help()


if __name__ == "__main__":
    main()
