#!/usr/bin/env python3
"""DAGR → HDF5 转换器（D3 根治）

将 C++ DAggerCollector 写的 dagger_incr_XXXX.bin（DAGR 自定义二进制）
转换为 Python HDF5Dataset 可读的 .h5 文件，打通在线 DAgger 增量数据
到训练管线的最后一公里。

DAGR .bin 格式（小端，与 C++ write_binary_/write_sample_ 对齐）:
    magic[4]   = 'DAGR'
    ver   u32  = 1
    n     u32  = 样本数
    per sample:
        images        [10*224*224*3] f32   (HWC, 与 HDF5Dataset 期望一致)
        pc_M          u32             (点数，每样本可变)
        point_clouds  [2*pc_M*4] f32  (lidar, xyz+intensity)
        vehicle_state [6] f32
        lab           [3] f32         (steer, throttle, brake)

HDF5 .h5 格式（与 HDF5Dataset.__getitem__ 对齐）:
    attrs["num_samples"] = N
    "images"       [N, 10, 224, 224, 3] f32
    "point_clouds" [N, 2, max_M, 4] f32   (不足 max_M 的 padding 0)
    "vehicle_states" [N, 6] f32
    "steer"/"throttle"/"brake" [N] f32

用法:
    python3 tools/dagr_to_h5.py <input.bin> [more.bin ...] <output.h5>
    python3 tools/dagr_to_h5.py data/training_samples/dagger_increment/  output.h5  # 整个目录
"""
import sys
import os
import struct
import numpy as np
import h5py

MAGIC = b"DAGR"
IMG_COUNT = 10 * 224 * 224 * 3   # kDaggerImgCount
VS_COUNT = 6                      # kDaggerVsCount


def read_dagr(path: str):
    """读单个 DAGR .bin，返回样本列表。每样本: (images[IMG_COUNT], pc[2,M,4], vs[6], lab[3])"""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 12 or data[:4] != MAGIC:
        print(f"[warn] 非 DAGR 文件，跳过: {path}", file=sys.stderr)
        return []
    ver, n = struct.unpack_from("<II", data, 4)
    if ver != 1:
        print(f"[warn] 未知 DAGR 版本 {ver}，跳过: {path}", file=sys.stderr)
        return []
    samples = []
    off = 12
    for _ in range(n):
        # images
        if off + IMG_COUNT * 4 > len(data): break
        images = np.frombuffer(data, dtype="<f4", count=IMG_COUNT, offset=off).copy()
        off += IMG_COUNT * 4
        # pc_M
        if off + 4 > len(data): break
        (pc_M,) = struct.unpack_from("<I", data, off); off += 4
        pc_n = 2 * pc_M * 4
        if off + pc_n * 4 > len(data): break
        pc = np.frombuffer(data, dtype="<f4", count=pc_n, offset=off).copy().reshape(2, pc_M, 4)
        off += pc_n * 4
        # vehicle_state
        if off + VS_COUNT * 4 > len(data): break
        vs = np.frombuffer(data, dtype="<f4", count=VS_COUNT, offset=off).copy()
        off += VS_COUNT * 4
        # lab (steer/throttle/brake)
        if off + 3 * 4 > len(data): break
        lab = np.frombuffer(data, dtype="<f4", count=3, offset=off).copy()
        off += 3 * 4
        samples.append((images, pc, vs, lab))
    return samples


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    out_path = sys.argv[-1]
    in_paths = sys.argv[1:-1]

    # 收集所有输入文件（支持目录）
    bin_files = []
    for p in in_paths:
        if os.path.isdir(p):
            bin_files.extend(sorted(os.path.join(p, f) for f in os.listdir(p) if f.endswith(".bin")))
        elif p.endswith(".bin"):
            bin_files.append(p)

    if not bin_files:
        print(f"[error] 未找到 .bin 文件，输入: {in_paths}", file=sys.stderr); sys.exit(1)

    # 读所有样本
    all_samples = []
    for bf in bin_files:
        got = read_dagr(bf)
        print(f"[info] {bf}: {len(got)} 样本")
        all_samples.extend(got)
    if not all_samples:
        print("[error] 无有效样本", file=sys.stderr); sys.exit(1)

    N = len(all_samples)
    max_M = max(s[1].shape[1] for s in all_samples)
    print(f"[info] 总样本 {N}, 最大点数 max_M={max_M}")

    # 预分配数组
    images_arr = np.zeros((N, 10, 224, 224, 3), dtype=np.float32)
    pc_arr = np.zeros((N, 2, max_M, 4), dtype=np.float32)
    vs_arr = np.zeros((N, 6), dtype=np.float32)
    steer_arr = np.zeros(N, dtype=np.float32)
    throttle_arr = np.zeros(N, dtype=np.float32)
    brake_arr = np.zeros(N, dtype=np.float32)

    for i, (imgs, pc, vs, lab) in enumerate(all_samples):
        images_arr[i] = imgs.reshape(10, 224, 224, 3)
        m = pc.shape[1]
        pc_arr[i, :, :m, :] = pc          # 不足 max_M 的部分保持 0（padding）
        vs_arr[i] = vs
        steer_arr[i] = lab[0]
        throttle_arr[i] = lab[1]
        brake_arr[i] = lab[2]

    # 写 HDF5
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with h5py.File(out_path, "w") as f:
        f.attrs["num_samples"] = N
        f.create_dataset("images", data=images_arr, compression="gzip", compression_opts=4)
        f.create_dataset("point_clouds", data=pc_arr, compression="gzip", compression_opts=4)
        f.create_dataset("vehicle_states", data=vs_arr)
        f.create_dataset("steer", data=steer_arr)
        f.create_dataset("throttle", data=throttle_arr)
        f.create_dataset("brake", data=brake_arr)
    print(f"[done] 写入 {out_path}: {N} 样本, point_clouds padding 至 {max_M}")


if __name__ == "__main__":
    main()
