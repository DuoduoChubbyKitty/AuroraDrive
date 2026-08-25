#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
规则法补标 strong_brake（方案 B），不调用任何视觉模型，纯在 controls.csv 上跑。

规则：扫描 brake 列，找出"连续踩刹车"的帧段；段长度 >= threshold 帧的，整段标 strong_brake=1，
否则标 0。短按的小刹车（如转弯轻点）不标，长按的急刹/长刹标 1。

列序（controls.csv）：t_sec, frame, steer, throttle, brake, handbrake, strong_brake
  brake       = 第 5 列 (index 4)
  strong_brake= 第 7 列 (index 6)

用法：
  python3 tools/label_strong_brake_rule.py [--threshold 20] [--clip <dir>]

默认作用在最近一个 clip 的 controls.csv 上。运行前会自动备份为 controls.csv.rule_bak。
"""
import os
import sys
import glob
import argparse

DEFAULT_PROJECT = "/Users/dupi/Desktop/自动驾驶系统"


def find_latest_clip(project):
    clips = glob.glob(os.path.join(project, "data", "raw_clips", "clip_*"))
    if not clips:
        return None
    return max(clips, key=os.path.getmtime)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--threshold", type=int, default=20, help="连续刹车段长度阈值(帧)，>=此值标 strong_brake=1")
    ap.add_argument("--clip", type=str, default=None, help="指定 clip 目录")
    ap.add_argument("--project", type=str, default=DEFAULT_PROJECT)
    args = ap.parse_args()

    clip = args.clip or find_latest_clip(args.project)
    if not clip:
        print("找不到任何 clip 目录")
        sys.exit(1)

    csv_path = os.path.join(clip, "controls.csv")
    if not os.path.isfile(csv_path):
        print(f"找不到 {csv_path}")
        sys.exit(1)

    # 备份（规则版备份，不覆盖视觉版 .bak）
    bak = csv_path + ".rule_bak"
    with open(csv_path, "r") as f:
        raw = f.read()
    with open(bak, "w") as f:
        f.write(raw)
    print(f"已备份原始 controls.csv -> {bak}")

    lines = raw.splitlines()
    header = lines[0]
    rows = [l.split(",") for l in lines[1:] if l.strip()]

    # 校验列数
    if len(rows[0]) < 7:
        print(f"列数异常: 期望>=7, 实际={len(rows[0])}")
        sys.exit(1)

    n = len(rows)
    mark = set()
    i = 0
    while i < n:
        if float(rows[i][4]) == 1.0:  # brake==1
            j = i
            seg = []
            while j < n and float(rows[j][4]) == 1.0:
                # 仅当帧号连续时才算同一段；非连续则断开
                if seg and int(float(rows[j][1])) != int(float(rows[j - 1][1])) + 1:
                    break
                seg.append(j)
                j += 1
            if len(seg) >= args.threshold:
                for k in seg:
                    mark.add(k)
            i = j
        else:
            i += 1

    for k in mark:
        rows[k][6] = "1.0"

    with open(csv_path, "w") as f:
        f.write(header + "\n")
        for r in rows:
            f.write(",".join(r) + "\n")

    total_brake = sum(1 for r in rows if float(r[4]) == 1.0)
    total_strong = len(mark)
    print(f"clip: {os.path.basename(clip)}")
    print(f"总帧: {n}  刹车帧(brake=1): {total_brake}  标为紧急(strong_brake=1): {total_strong} "
          f"({100.0*total_strong/total_brake:.1f}% of brake)")
    print(f"阈值: {args.threshold} 帧  紧急段中未标(短按): {total_brake-total_strong}")


if __name__ == "__main__":
    main()
