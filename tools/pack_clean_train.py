#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把清洗后的数据（data/lean_clips_clean）打包成可直接训练的 aurora_train_pack.zip。

【为什么需要重编号】
  dataset_v3.__getitem__ 用**行号 i** 拼 `frames/{i:06d}.jpg`，并强制 `frame` 列 == 行号 0..N-1。
  而清洗后保留的帧是断号的（原 000197.jpg、000198.jpg…），t_sec 也不连续。
  所以必须：把保留帧按顺序硬链接成 000000.jpg..(N-1).jpg，并把 CSV 的 frame 列同步重编号为 0..N-1。

【为什么 t_sec 保留原值、不重排】
  fps 校验（EXPECTED_FPS=15，容差 15%）读的是相邻行 t_sec 差值。
  保留原始 t_sec 且不重排 → 相邻保留帧 dt≈0.067s→14.8fps，通过校验；
  同时保证「第 k 帧」对应的真实时间点不变。

【目录/盘】
  帧在 /Volumes/系统/lean_clips（同盘）。暂存目录建在 /Volumes/系统 下用硬链接（秒级、不占空间）。
  产出 zip 落 ~/Desktop。

用法：
  python3 tools/pack_clean_train.py --staging /Volumes/系统/aurora_pack_staging \
      --out ~/Desktop/aurora_train_pack_clean.zip
"""
from __future__ import annotations

import argparse
import csv
import os
import shutil
import statistics
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLEAN = ROOT / "data" / "lean_clips_clean"      # 清洗 CSV / frames_clean.txt
ORIG = ROOT / "data" / "lean_clips"             # 原始帧（软链到 /Volumes/系统/lean_clips）
HEADER = ["t_sec", "frame", "speed_kmh", "w", "a", "s", "d",
          "shift", "space", "super_brake", "ultimate_brake"]
KEY_COLS = ["w", "a", "s", "d", "shift", "space", "super_brake", "ultimate_brake"]
MIN_FRAMES = 20          # 清洗后少于此帧数的 clip 丢弃（太短无训练价值）
EXPECTED_FPS = 15.0
FPS_TOL = 0.15


def check_fps(clip: str, ts: list[float]) -> tuple[float, bool]:
    if len(ts) < 2:
        return 0.0, True
    dts = [b - a for a, b in zip(ts, ts[1:]) if b > a]
    if not dts:
        return 0.0, True
    fps = 1.0 / statistics.median(dts)
    ok = abs(fps - EXPECTED_FPS) / EXPECTED_FPS <= FPS_TOL
    return fps, ok


def build_clip(clip_name: str, staging: Path) -> dict | None:
    clean_dir = CLEAN / clip_name
    csv_in = clean_dir / "controls_clean.csv"
    frames_list = clean_dir / "frames_clean.txt"
    orig_frames = ORIG / clip_name / "frames"
    if not (csv_in.exists() and frames_list.exists() and orig_frames.is_dir()):
        return {"clip": clip_name, "skipped": "缺文件"}

    rows = list(csv.DictReader(open(csv_in, newline="", encoding="utf-8")))
    kept_names = [ln.strip() for ln in open(frames_list, encoding="utf-8") if ln.strip()]
    if len(rows) != len(kept_names):
        return {"clip": clip_name, "skipped": f"CSV行={len(rows)} 与 帧清单={len(kept_names)} 不一致"}
    if len(rows) < MIN_FRAMES:
        return {"clip": clip_name, "skipped": f"仅 {len(rows)} 帧 (<{MIN_FRAMES})"}

    out = staging / clip_name
    if out.exists():
        shutil.rmtree(out)
    (out / "frames").mkdir(parents=True)

    ts: list[float] = []
    for k, (row, fname) in enumerate(zip(rows, kept_names)):
        src = orig_frames / fname
        if not src.exists():
            raise FileNotFoundError(f"{clip_name}: 源帧缺失 {src}")
        dst = out / "frames" / f"{k:06d}.jpg"
        try:
            os.link(src, dst)          # 同盘硬链接：秒级、不占额外空间
        except OSError:
            shutil.copy2(src, dst)     # 跨盘兜底（会慢、占空间）
        ts.append(float(row["t_sec"]))

    # 写新 controls.csv：frame=k，t_sec 原值，按键列原值，speed 留空
    with open(out / "controls.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(HEADER)
        for k, row in enumerate(rows):
            keys = [row.get(c, "0") or "0" for c in KEY_COLS]
            w.writerow([row["t_sec"], k, ""] + keys)

    fps, fps_ok = check_fps(clip_name, ts)
    return {"clip": clip_name, "frames": len(rows), "fps": round(fps, 2), "fps_ok": fps_ok}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--staging", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep-staging", action="store_true", help="打包后保留暂存目录")
    args = ap.parse_args()

    staging = Path(args.staging).expanduser()
    out_zip = Path(args.out).expanduser()
    staging.mkdir(parents=True, exist_ok=True)

    clips = sorted(d.name for d in CLEAN.glob("clip_*") if d.is_dir())
    print(f"待处理 {len(clips)} 个清洗 clip")
    results = []
    bad_fps = []
    total = 0
    for c in clips:
        r = build_clip(c, staging)
        results.append(r)
        if r is None:
            continue
        if "skipped" in r:
            print(f"  跳过 {c}: {r['skipped']}")
            continue
        total += r["frames"]
        flag = "" if r["fps_ok"] else "  ⚠️FPS超容差"
        if not r["fps_ok"]:
            bad_fps.append(c)
        print(f"  {c}: {r['frames']} 帧, fps≈{r['fps']}{flag}")

    built = [r for r in results if r and "frames" in r]
    print(f"\n打包 {len(built)} 个 clip, 共 {total} 帧 → {out_zip}")

    out_zip.parent.mkdir(parents=True, exist_ok=True)
    if out_zip.exists():
        out_zip.unlink()
    # -0 store：JPEG 已压缩，再压无收益且慢
    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as z:
        for r in built:
            cdir = staging / r["clip"]
            for p in sorted(cdir.rglob("*")):
                if p.is_file():
                    z.write(p, p.relative_to(staging))
            print(f"  已写入 {r['clip']}", flush=True)

    size_gb = out_zip.stat().st_size / 1024 / 1024 / 1024
    print(f"\n✅ 完成: {out_zip}  ({size_gb:.2f} GB)")
    if bad_fps:
        print(f"⚠️ 有 fps 超容差的 clip（需人工确认）: {bad_fps}")
    if not args.keep_staging:
        shutil.rmtree(staging, ignore_errors=True)
        print(f"已清理暂存 {staging}")


if __name__ == "__main__":
    main()
