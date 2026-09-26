#!/usr/bin/env python3
"""异环 30031 移动包坐标提取器（2026-09-25 逆向结果）。

背景
----
项目早期对齐 MaaNTE 时，30031 跑的是**裸 UE5 位流移动包**；游戏 1.4.x 后
协议改为 **protobuf 封装 + 位流坐标字段**，MaaNTE 原版 `_Decoder` 对新包
返回 None（已实测验证）。本脚本按实测逆向出的新结构提取坐标。

实测出的包结构（s2c，服务器→客户端）
-----------------------------------
payload 长度 72 或 76 字节，前 56 字节固定前缀：

    48000000140000000000000000000a000c000400000008000a0000006204
    0000280000001000000000000a0018000400080010000a000000

第 56 字节起是**双记录**，每记录 64 位步长，字段用**位偏移**定位：

    rec1: bit 498 = 坐标分量 X1      bit 509 = 高度 Z1
    rec2: bit 562 = 坐标分量 X2      bit 573 = 高度 Z2

实测判据（2026-09-25，真机连续采样）
    · 角色移动时 X1 与 X2 每包同步 -1.12（服务器批量下发轨迹点）
    · 角色静止时字段完全不变（对照 idle.pcap 仅 1 个值）
    · Z 分量（bit509/573）几乎恒定（31851.9 / 31852.9）—— 角色未改变高度

用法
----
    python3 extract_coord.py <样本.pcap>            # 解析文件
    python3 extract_coord.py --live 20 [en8]        # 实时抓 20 秒

坐标为游戏世界坐标（单位 cm），转地图像素用项目标定常量（见 --map）。
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import time
from pathlib import Path

# 与 Sources/AuroraDrive/Capture/CoordinateCapture.swift 的 kCalib* 同步
CALIB_A = 0.016394586684750773
CALIB_B = 5.693519256055879e-08
CALIB_TX = 6526.474380746091
CALIB_TY = 5210.664390686138
MAP_SIZE = 13056

# 实测出的固定前缀（前 56 字节）
PREFIX = bytes.fromhex(
    "48000000140000000000000000000a000c000400000008000a0000006204"
    "0000280000001000000000000a0018000400080010000a000000"
)

# 位偏移（实测）
BIT_X1, BIT_Z1 = 498, 509
BIT_X2, BIT_Z2 = 562, 573

VALID_LENGTHS = (72, 76)


def bits(data: bytes, offset: int, count: int) -> int:
    """从字节数组指定位偏移读 count 位（等价于 MaaNTE `_bits`）。"""
    if offset < 0 or count <= 0 or offset + count > len(data) * 8:
        raise ValueError("bit range is outside payload")
    first = offset // 8
    last = (offset + count + 7) // 8
    value = int.from_bytes(data[first:last], "little")
    return (value >> (offset % 8)) & ((1 << count) - 1)


def f32(data: bytes, offset: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits(data, offset, 32)))[0]


def is_move_payload(payload: bytes) -> bool:
    """是否是实测的移动包（长度 + 固定前缀双重判据）。"""
    return len(payload) in VALID_LENGTHS and payload.startswith(PREFIX)


def extract(payload: bytes):
    """提取 (X1, Z1, X2, Z2)；不匹配返回 None。"""
    if not is_move_payload(payload):
        return None
    try:
        return (f32(payload, BIT_X1), f32(payload, BIT_Z1),
                f32(payload, BIT_X2), f32(payload, BIT_Z2))
    except (ValueError, struct.error):
        return None


def to_map(world_x: float, world_y: float) -> tuple[float, float]:
    """世界坐标 → 地图像素（与 Swift worldToMapPixel 同公式）。"""
    mx = CALIB_A * world_x - CALIB_B * world_y + CALIB_TX
    my = CALIB_B * world_x + CALIB_A * world_y + CALIB_TY
    return (mx, my)


def iter_pcap_tcp_payloads(path: Path):
    """遍历 pcap 的 TCP payload（支持 us 精度，大小端 magic）。"""
    raw = path.read_bytes()
    if len(raw) < 24:
        return
    magic = raw[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        raise ValueError(f"未知 pcap magic: {magic!r}")
    nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
    offset = 24
    while offset + 16 <= len(raw):
        _, _, incl, _ = struct.unpack(endian + "IIII", raw[offset:offset + 16])
        offset += 16
        pkt = raw[offset:offset + incl]
        offset += incl
        if len(pkt) < 34 or struct.unpack(">H", pkt[12:14])[0] != 0x0800:
            continue                      # 非 IPv4
        ihl = (pkt[14] & 0x0F) * 4
        if pkt[14 + 9] != 6:               # 非 TCP
            continue
        tso = 14 + ihl
        if len(pkt) < tso + 20:
            continue
        doff = ((pkt[tso + 12] >> 4) & 0x0F) * 4
        src = ".".join(str(b) for b in pkt[26:30])
        dst = ".".join(str(b) for b in pkt[30:34])
        yield src, dst, pkt[tso + doff:]


def analyze_file(path: Path, show_map: bool) -> None:
    print(f"=== 解析 {path.name} ===")
    count = 0
    for src, dst, payload in iter_pcap_tcp_payloads(path):
        got = extract(payload)
        if got is None:
            continue
        x1, z1, x2, z2 = got
        count += 1
        direction = "s2c" if dst.startswith("192.168.") else "c2s"
        line = (f"  [{count:3d}] {direction} len={len(payload):3d}  "
                f"X1={x1:12.2f} Z1={z1:10.2f}  X2={x2:12.2f} Z2={z2:10.2f}")
        if show_map:
            mx, my = to_map(x1, x2)
            inside = 0 <= mx < MAP_SIZE and 0 <= my < MAP_SIZE
            line += f"  → 地图({mx:7.1f},{my:7.1f}){'✓' if inside else '✗'}"
        print(line)
    print(f"=== {path.name}: {count} 个移动包 ===")
    if count == 0:
        print("  （无移动包：游戏未移动 / 未进世界 / 需确认网卡）")


def live(seconds: float, iface: str, show_map: bool) -> None:
    out = Path("/tmp/aurora_rev_live.pcap")
    if out.exists():
        out.unlink()
    proc = subprocess.Popen(
        ["tcpdump", "-i", iface, "-n", "-s", "0", "-U", "-w", str(out), "port", "30031"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    print(f"[LIVE] {iface}:30031 提取 {seconds:.0f}s …")
    start = time.time()
    offset = 24
    count = 0
    try:
        while time.time() - start < seconds:
            time.sleep(0.25)
            try:
                raw = out.read_bytes()
            except OSError:
                continue
            while offset + 16 <= len(raw):
                _, _, incl, _ = struct.unpack("<IIII", raw[offset:offset + 16])
                offset += 16
                pkt = raw[offset:offset + incl]
                offset += incl
                if len(pkt) < 34 or struct.unpack(">H", pkt[12:14])[0] != 0x0800:
                    continue
                ihl = (pkt[14] & 0x0F) * 4
                if pkt[14 + 9] != 6:
                    continue
                tso = 14 + ihl
                if len(pkt) < tso + 20:
                    continue
                doff = ((pkt[tso + 12] >> 4) & 0x0F) * 4
                got = extract(pkt[tso + doff:])
                if got is None:
                    continue
                x1, z1, x2, z2 = got
                count += 1
                line = (f"  [{count:3d}] t={time.time() - start:5.1f}s  "
                        f"X1={x1:12.2f} Z1={z1:10.2f}  X2={x2:12.2f} Z2={z2:10.2f}")
                if show_map:
                    mx, my = to_map(x1, x2)
                    line += f"  → 地图({mx:7.1f},{my:7.1f})"
                print(line, flush=True)
    finally:
        proc.terminate()
    print(f"[LIVE] 结束，共 {count} 个坐标样本")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="异环 30031 坐标提取器")
    parser.add_argument("pcap", nargs="?", help="样本 pcap 路径")
    parser.add_argument("--live", type=float, metavar="SECONDS", help="实时抓包秒数")
    parser.add_argument("--iface", default="en8", help="实时抓包网卡（默认 en8）")
    parser.add_argument("--map", action="store_true", help="同时输出地图像素")
    args = parser.parse_args(argv)

    if args.live:
        live(args.live, args.iface, args.map)
        return 0
    if not args.pcap:
        parser.error("需要 pcap 路径或 --live")
    analyze_file(Path(args.pcap), args.map)
    return 0


if __name__ == "__main__":
    sys.exit(main())
