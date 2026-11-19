#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""清洗 lean_clips：剔除「长时间六键全零」的菜单/加载/停车段。

【方案三：原始数据只读，绝不修改】
  - 只读 data/lean_clips/*/controls.csv，绝不写回、绝不删图片
  - 输出到 data/lean_clips_clean/：
      · <clip>/controls_clean.csv   —— 保留帧（原始行，逐字不变）
      · <clip>/frames_clean.txt     —— 保留帧的文件名清单（供训练按名取帧，绝不错位）
      · <clip>/dropped.txt          —— 被剔除帧的文件名 + 剔除原因
      · _clean_report.json / _clean_report.md —— 汇总

【剔除规则（可调）】
  连续 >= MIN_DROP_FRAMES 帧且这连续段内「六键全零」→ 整段剔除。
  默认 150 帧 ≈ 10 秒（15Hz）。短全零段（滑行/甩尾自救，1~7 帧）保留。

【为什么不看图片、只看按键】
  菜单/加载/停车的确定性特征是「长时间一个键都不按」。这不需要视觉判断。
  （「没速度表 ≠ 菜单」——停车等红灯也没速度变化，但那些是真实的静止，
   本脚本会把它们一起当长全零剔除；若日后需要区分，用速度表 OCR 另行标记。）

用法：
  python3 tools/clean_lean_clips.py                 # 默认阈值 150
  python3 tools/clean_lean_clips.py --min-drop 150 --dry-run
"""
from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path

ATOMIC_KEYS = ("w", "a", "s", "d", "shift", "space")

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "data" / "lean_clips"
OUT = ROOT / "data" / "lean_clips_clean"


def is_all_zero(row: dict) -> bool:
    """该行六键是否全部为 0（缺列/空串按 0 处理）。"""
    for k in ATOMIC_KEYS:
        raw = (row.get(k) or "").strip()
        try:
            v = int(float(raw)) if raw != "" else 0
        except ValueError:
            v = 0
        if v != 0:
            return False
    return True


def find_long_zero_blocks(rows: list[dict], min_len: int) -> list[tuple[int, int]]:
    """返回连续全零且长度 >= min_len 的 (start, end) 闭区间列表（行下标）。"""
    blocks: list[tuple[int, int]] = []
    n = len(rows)
    i = 0
    while i < n:
        if is_all_zero(rows[i]):
            j = i
            while j + 1 < n and is_all_zero(rows[j + 1]):
                j += 1
            if (j - i + 1) >= min_len:
                blocks.append((i, j))
            i = j + 1
        else:
            i += 1
    return blocks


def frame_name(row: dict, fallback_idx: int) -> str:
    """帧文件名：优先用 frame 列（6 位），否则用行号。"""
    raw = (row.get("frame") or "").strip()
    if raw != "":
        try:
            return f"{int(float(raw)):06d}.jpg"
        except ValueError:
            pass
    return f"{fallback_idx:06d}.jpg"


def clean_clip(clip_dir: Path, min_len: int, dry_run: bool) -> dict:
    csv_path = clip_dir / "controls.csv"
    if not csv_path.exists():
        return {"clip": clip_dir.name, "skipped": "no controls.csv"}

    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    blocks = find_long_zero_blocks(rows, min_len)
    drop_idx = set()
    for a, b in blocks:
        drop_idx.update(range(a, b + 1))

    kept_rows = [r for i, r in enumerate(rows) if i not in drop_idx]
    dropped_rows = [(i, rows[i]) for i in sorted(drop_idx)]

    report = {
        "clip": clip_dir.name,
        "rows": len(rows),
        "kept": len(kept_rows),
        "dropped": len(dropped_rows),
        "dropped_pct": round(len(dropped_rows) / len(rows) * 100, 2) if rows else 0.0,
        "long_zero_blocks": [
            {"start_row": a, "end_row": b, "frames": b - a + 1,
             "start_sec": round(a / 15.0, 1), "end_sec": round(b / 15.0, 1)}
            for a, b in blocks
        ],
    }
    if dry_run:
        return report

    out_dir = OUT / clip_dir.name
    out_dir.mkdir(parents=True, exist_ok=True)

    # 保留帧 CSV（逐字写回原始字段与值，行序不变）
    with open(out_dir / "controls_clean.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in kept_rows:
            w.writerow(r)

    # 保留帧文件名清单（供训练按名取帧，避免行号错位）
    with open(out_dir / "frames_clean.txt", "w", encoding="utf-8") as f:
        for i, r in enumerate(rows):
            if i not in drop_idx:
                f.write(frame_name(r, i) + "\n")

    # 剔除清单 + 原因
    with open(out_dir / "dropped.txt", "w", encoding="utf-8") as f:
        for i, r in dropped_rows:
            f.write(f"{frame_name(r, i)}\tlong_zero_block\trow={i}\n")

    return report


def main() -> None:
    ap = argparse.ArgumentParser(description="清洗 lean_clips：剔除长全零菜单段（原始数据只读）")
    ap.add_argument("--min-drop", type=int, default=150, help="连续全零多少帧才剔除（默认150≈10s）")
    ap.add_argument("--dry-run", action="store_true", help="只统计不写文件")
    args = ap.parse_args()

    clip_dirs = sorted(d for d in SRC.glob("clip_*") if d.is_dir())
    if not clip_dirs:
        raise SystemExit(f"没有找到 clip: {SRC}")

    reports = []
    tot_rows = tot_kept = tot_dropped = 0
    for d in clip_dirs:
        rep = clean_clip(d, args.min_drop, args.dry_run)
        reports.append(rep)
        if "skipped" in rep:
            print(f"  跳过 {rep['clip']}: {rep['skipped']}")
            continue
        tot_rows += rep["rows"]; tot_kept += rep["kept"]; tot_dropped += rep["dropped"]
        print(f"  {rep['clip']}: {rep['rows']} → 保留 {rep['kept']}，剔除 {rep['dropped']} "
              f"({rep['dropped_pct']}%, {len(rep['long_zero_blocks'])} 段)")

    summary = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "rule": f"连续 >= {args.min_drop} 帧六键全零 → 整段剔除为菜单/加载/停车",
        "note": "原始 data/lean_clips 只读未改；清洗结果在 data/lean_clips_clean",
        "min_drop_frames": args.min_drop,
        "total_rows": tot_rows,
        "total_kept": tot_kept,
        "total_dropped": tot_dropped,
        "total_dropped_pct": round(tot_dropped / tot_rows * 100, 2) if tot_rows else 0.0,
        "clips": reports,
    }

    if not args.dry_run:
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "_clean_report.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
        # Markdown 版
        lines = [
            "# lean_clips 清洗报告", "",
            f"- 规则：{summary['rule']}",
            f"- 生成：{summary['generatedAt']}",
            f"- 原始数据：`data/lean_clips`（只读，未改动）",
            f"- 清洗结果：`data/lean_clips_clean`", "",
            f"**总计：{tot_rows} 帧 → 保留 {tot_kept}，剔除 {tot_dropped} ({summary['total_dropped_pct']}%)**", "",
            "| clip | 原始 | 保留 | 剔除 | 剔除% | 长零段数 |",
            "|---|---:|---:|---:|---:|---:|",
        ]
        for r in reports:
            if "skipped" in r:
                continue
            lines.append(f"| {r['clip']} | {r['rows']} | {r['kept']} | {r['dropped']} | "
                         f"{r['dropped_pct']} | {len(r['long_zero_blocks'])} |")
        (OUT / "_clean_report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"\n总计: {tot_rows} → 保留 {tot_kept}, 剔除 {tot_dropped} "
          f"({summary['total_dropped_pct']}%)")
    print(("DRY-RUN，未写文件" if args.dry_run else f"输出目录: {OUT}"))


if __name__ == "__main__":
    main()
