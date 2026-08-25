#!/usr/bin/env python3
# [OFFLINE-TOOL] 离线训练数据采集工具（键盘事件录制），不进入 Route B 运行时部署包。
"""
AuroraDrive 键盘监听器 - 在终端自己跑，不受沙箱限制

用法: python3 key_watcher.py [输出文件路径]
默认输出: /tmp/aurora_keys.csv

按 Ctrl+C 停止。
"""

import ctypes, time, sys, csv, os

_cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_cg.CGEventSourceKeyState.restype = ctypes.c_bool
_cg.CGEventSourceKeyState.argtypes = [ctypes.c_int32, ctypes.c_uint16]

VK = {"W": 0x0D, "A": 0x00, "S": 0x01, "D": 0x02, "SPACE": 0x31, "SHIFT": 0x38}
HID = 1

out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/aurora_keys.csv"
interval = 0.1  # 100ms

print(f"键盘监听器启动 → {out_path}")
print("监控: W A S D SPACE SHIFT")
print("按 Ctrl+C 停止\n")

with open(out_path, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["timestamp", "W", "A", "S", "D", "SPACE", "SHIFT"])
    writer.writeheader()
    
    t0 = time.time()
    try:
        while True:
            ts = round(time.time() - t0, 4)
            row = {"timestamp": ts}
            for name, kc in VK.items():
                row[name] = 1 if _cg.CGEventSourceKeyState(HID, kc) else 0
            writer.writerow(row)
            f.flush()
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n已停止")
