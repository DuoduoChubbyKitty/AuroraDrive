#!/usr/bin/env python3
# 验证录制产物是否符合训练端 mono_dataset 期望格式（纯 stdlib，无需 torch）
# 对应 mono_dataset 约定:
#   目录 data/raw_clips/clip_*  → _list_clips 只扫 clip_ 前缀
#   frames/%06d.jpg            → _frame_path v1_old: {frame_idx:06d}.jpg
#   controls.csv 表头 t_sec,frame,steer,throttle,brake → _load_controls_csv 读 steer/throttle/brake
#   view.txt (FPV/TPV)         → _clip_view 视角过滤
import csv
from pathlib import Path

ROOT = Path("/Users/dupi/Desktop/自动驾驶系统/data/raw_clips")
EXPECTED_HEADER = ["t_sec", "frame", "steer", "throttle", "brake"]


def verify():
    if not ROOT.exists():
        print(f"[!] {ROOT} 不存在 —— 还没有任何录制")
        return
    clips = sorted(p for p in ROOT.iterdir() if p.is_dir() and p.name.startswith("clip_"))
    print(f"扫描 {ROOT}\n找到 {len(clips)} 个 clip_ 目录\n")
    for c in clips:
        info, issues = [], []
        info.append("clip_ 前缀 OK")
        frames = sorted(c.glob("frames/*.jpg"))
        if frames:
            info.append(f"frames/*.jpg = {len(frames)} 张 (首张 {frames[0].name})")
        else:
            issues.append("缺少 frames/*.jpg")
        csvp = c / "controls.csv"
        if csvp.exists():
            with open(csvp) as f:
                h = next(csv.reader(f))
            if h == EXPECTED_HEADER:
                info.append("controls.csv 表头 OK (t_sec,frame,steer,throttle,brake)")
            else:
                issues.append(f"controls.csv 表头不符: {h}")
            rows = list(csv.DictReader(open(csvp)))
            if rows:
                r0 = rows[0]
                info.append(f"控制行={len(rows)} 首行 steer={r0['steer']} throttle={r0['throttle']} brake={r0['brake']}")
        else:
            issues.append("缺少 controls.csv")
        vt = c / "view.txt"
        if vt.exists():
            info.append(f"view.txt = {vt.read_text().strip()}")
        else:
            issues.append("缺少 view.txt")
        tag = "OK " if not issues else "WARN"
        print(f"[{tag}] {c.name}")
        for i in info:
            print(f"      \u2713 {i}")
        for i in issues:
            print(f"      \u2717 {i}")
    print("\n验证结束。OK = 训练端 mono_dataset 能直接扫描并读取该 clip。")


if __name__ == "__main__":
    verify()
