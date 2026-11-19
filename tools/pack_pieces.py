#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把清洗后数据按「字节上限」切成若干片（每片成一个独立 clip 目录），供网页上传。

背景：平台网页单文件上传在 ~120MB 以上会中途失败（实测 82MB 成功、235MB 失败）。
  故每片控制在 --limit-mb（默认 115MB）以内；单个大 clip 会被拆成多片，
  每片是独立 clip_* 目录（帧重新编号 0..M-1、t_sec 保留原值），训练端逐个当独立片段读，
  帧连续、fps 校验不受影响。

产出：~/Desktop/aurora_train_pack_pieceNNN.zip（NNN 三位序号）
      另写 ~/Desktop/aurora_pieces_manifest.json（片->源clip/帧范围，便于核对）

用法：
  python3 tools/pack_pieces.py --plan
  python3 tools/pack_pieces.py --build-all --limit-mb 115
  python3 tools/pack_pieces.py --build-one 3 --limit-mb 115
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
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
# 已单独成功上传的源 clip（避免重复打包）：clip_20261104_132750 已作为 part99 上传
ALREADY_UPLOADED = set()


def load_clip(clip):
    clean_dir = CLEAN / clip
    rows = list(csv.DictReader(open(clean_dir / "controls_clean.csv", newline="", encoding="utf-8")))
    kept = [l.strip() for l in open(clean_dir / "frames_clean.txt", encoding="utf-8") if l.strip()]
    if len(rows) < MIN_FRAMES or len(rows) != len(kept):
        return None
    fb = ORIG / clip / "frames"
    sizes = [os.path.getsize(fb / fn) if (fb / fn).exists() else 0 for fn in kept]
    csv_sz = os.path.getsize(clean_dir / "controls_clean.csv")
    return {"clip": clip, "rows": rows, "kept": kept, "sizes": sizes, "csv_sz": csv_sz}


def build_plan(limit_mb):
    """返回 pieces: [ {name, src_clip, start, end, bytes} ]（start/end 为源 clip 内行下标，闭区间）。"""
    lim = limit_mb * 1024 * 1024
    clips = sorted(d.name for d in CLEAN.glob("clip_*") if d.is_dir())
    pieces = []
    for clip in clips:
        if clip in ALREADY_UPLOADED:
            continue
        info = load_clip(clip)
        if not info:
            continue
        rows, sizes, csv_sz = info["rows"], info["sizes"], info["csv_sz"]
        # 贪心切片：每片帧字节和 + 该片分摊 csv（整份 csv 每片都写一份，按片摊算一次）
        n = len(rows)
        start = 0
        while start < n:
            acc = csv_sz
            end = start
            while end < n and acc + sizes[end] <= lim:
                acc += sizes[end]; end += 1
            if end == start:  # 单帧就超限（极小概率），强制放一帧
                end = start + 1; acc += sizes[start]
            pieces.append({"src_clip": clip, "start": start, "end": end - 1,
                           "frames": end - start, "bytes": acc})
            start = end
    # 命名
    for i, p in enumerate(pieces):
        p["name"] = f"aurora_train_pack_piece{i:03d}.zip"
    return pieces


def build_piece(piece):
    clip = piece["src_clip"]
    info = load_clip(clip)
    rows, kept = info["rows"], info["kept"]
    a, b = piece["start"], piece["end"]
    sub_rows = rows[a:b+1]
    sub_kept = kept[a:b+1]
    out_name = piece["name"]
    staging = STAGING / out_name.replace(".zip", "")
    if staging.exists():
        shutil.rmtree(staging)
    payload = staging / "payload" / f"{clip}_p{a:05d}"
    (payload / "frames").mkdir(parents=True)
    fb = ORIG / clip / "frames"
    for k, (row, fn) in enumerate(zip(sub_rows, sub_kept)):
        src, dst = fb / fn, payload / "frames" / f"{k:06d}.jpg"
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)
    with open(payload / "controls.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(HEADER)
        for k, row in enumerate(sub_rows):
            w.writerow([row["t_sec"], k, ""] + [row.get(c, "0") or "0" for c in KEY_COLS])
    out_zip = OUTDIR / out_name
    if out_zip.exists():
        out_zip.unlink()
    import zipfile
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        for p in sorted(payload.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(staging / "payload"))
    mb = out_zip.stat().st_size / 1024 / 1024
    shutil.rmtree(staging, ignore_errors=True)
    return out_zip, mb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit-mb", type=int, default=115)
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--build-all", action="store_true")
    ap.add_argument("--build-one", type=int, default=None)
    args = ap.parse_args()

    pieces = build_plan(args.limit_mb)
    if args.plan:
        tot = sum(p["bytes"] for p in pieces)
        print(f"共 {len(pieces)} 片（上限 {args.limit_mb}MB），总 {tot/1024/1024:.0f}MB（不含已传的 132750）")
        for i, p in enumerate(pieces):
            print(f"  {p['name']}: {p['frames']}帧 {p['bytes']/1024/1024:.0f}MB  {p['src_clip']}[{p['start']}..{p['end']}]")
        return
    if args.build_one is not None:
        p = pieces[args.build_one]
        zp, mb = build_piece(p)
        print(f"✅ {zp.name} ({mb:.0f}MB)")
        return
    if args.build_all:
        manifest = []
        for i, p in enumerate(pieces):
            zp, mb = build_piece(p)
            p2 = dict(p); p2["zip_mb"] = round(mb, 1); p2["zip"] = str(zp)
            manifest.append(p2)
            print(f"✅ [{i+1}/{len(pieces)}] {zp.name} ({mb:.0f}MB) {p['src_clip']}[{p['start']}..{p['end']}]", flush=True)
        (OUTDIR / "aurora_pieces_manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"\n清单: {OUTDIR/'aurora_pieces_manifest.json'}")
        return
    ap.print_help()


if __name__ == "__main__":
    main()
