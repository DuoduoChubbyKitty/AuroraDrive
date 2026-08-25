#!/usr/bin/env python3
"""
AuroraRecorder 录制剪辑 -> M9 训练用 HDF5。

把 data/raw_clips/clip_* 的 frames/*.jpg + controls.csv 转成 trainer.py 要求的
HDF5 格式（src/data_generator.HDF5Dataset 消费）：
  - images        : [N, 10, 224, 224, 3]  float32 in [0,1]  （10 张连续帧为一个样本）
  - point_clouds  : [N, 2, 2048, 4]        float32 全 0    （录制无激光雷达，填零避免走捷径）
  - vehicle_states: [N, 6]                 float32 全 0    （同上）
  - steer/throttle/brake: [N, 1]           float32         （取自真实 controls.csv，比模型猜的准）

用法:
  python3 tools/build_hdf5.py
  python3 tools/build_hdf5.py --out data/training_samples/aurora_rec.h5 --stride 10
"""
import argparse
import csv
import glob
import os
import sys
import time

import numpy as np
from PIL import Image
import h5py

RAW = "data/raw_clips"
IMG = 224
WIN = 10            # 每个样本 10 张连续帧
PC_N = 2048         # 点云点数（与 HDF5Dataset 期望一致）


def load_controls(clip):
    p = os.path.join(clip, "controls.csv")
    if not os.path.exists(p):
        return []
    rows = []
    with open(p, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                rows.append((float(row["steer"]),
                             float(row["throttle"]),
                             float(row["brake"])))
            except (KeyError, ValueError):
                pass
    return rows


def main():
    ap = argparse.ArgumentParser(description="录制剪辑 -> M9 训练 HDF5")
    ap.add_argument("--raw", default=RAW)
    ap.add_argument("--out", default="data/training_samples/aurora_rec.h5")
    ap.add_argument("--stride", type=int, default=WIN,
                    help="相邻样本帧窗口滑动步长（默认=窗口大小=不重叠）")
    ap.add_argument("--win", type=int, default=WIN)
    args = ap.parse_args()

    clips = sorted(glob.glob(os.path.join(args.raw, "clip_*")))
    imgs, pcs, vss, sts, ths, brs = [], [], [], [], [], []

    for clip in clips:
        fps_files = (sorted(glob.glob(os.path.join(clip, "frames", "*.jpg")))
                     or sorted(glob.glob(os.path.join(clip, "*.jpg"))))
        if len(fps_files) < args.win:
            print(f"  skip {os.path.basename(clip)}: {len(fps_files)} 帧 < {args.win}")
            continue
        controls = load_controls(clip)
        n = len(fps_files)
        kept = 0
        for s in range(0, n - args.win + 1, args.stride):
            win = []
            ok = True
            for j in range(args.win):
                try:
                    im = Image.open(fps_files[s + j]).convert("RGB").resize(
                        (IMG, IMG), Image.BILINEAR)
                    win.append(np.asarray(im, dtype=np.float32) / 255.0)
                except Exception as e:
                    ok = False
                    break
            if not ok:
                continue
            imgs.append(np.stack(win))                      # [10,224,224,3]
            pcs.append(np.zeros((2, PC_N, 4), dtype=np.float32))
            vss.append(np.zeros((6,), dtype=np.float32))
            # GT：取窗口内 controls 均值（按位置对齐；缺 controls 则记 0）
            if controls:
                seg = controls[s:s + args.win]
                if seg:
                    sts.append(float(np.mean([c[0] for c in seg])))
                    ths.append(float(np.mean([c[1] for c in seg])))
                    brs.append(float(np.mean([c[2] for c in seg])))
                    kept += 1
                    continue
            sts.append(0.0); ths.append(0.0); brs.append(0.0)
            kept += 1
        print(f"  {os.path.basename(clip)}: {len(fps_files)} 帧 -> {kept} 样本")

    if not imgs:
        print("[error] 无可用样本（clip 都太短或无帧）")
        sys.exit(1)

    images = np.stack(imgs)
    point_clouds = np.stack(pcs)
    vehicle_states = np.stack(vss)
    steer = np.array(sts, dtype=np.float32).reshape(-1, 1)
    throttle = np.array(ths, dtype=np.float32).reshape(-1, 1)
    brake = np.array(brs, dtype=np.float32).reshape(-1, 1)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with h5py.File(args.out, "w") as f:
        f.create_dataset("images", data=images, compression="gzip", compression_opts=4)
        f.create_dataset("point_clouds", data=point_clouds, compression="gzip", compression_opts=4)
        f.create_dataset("vehicle_states", data=vehicle_states, compression="gzip", compression_opts=4)
        f.create_dataset("steer", data=steer)
        f.create_dataset("throttle", data=throttle)
        f.create_dataset("brake", data=brake)
        f.attrs["stage"] = "aurora_rec"
        f.attrs["num_samples"] = len(images)
        f.attrs["created_at"] = time.strftime("%Y-%m-%d %H:%M:%S")

    mb = images.nbytes / 1e6
    print(f"✅ 写入 {args.out}: {len(images)} 样本 | images {mb:.1f}MB | "
          f"steer∈[{steer.min():.2f},{steer.max():.2f}] "
          f"throttle∈[{throttle.min():.2f},{throttle.max():.2f}]")


if __name__ == "__main__":
    main()
