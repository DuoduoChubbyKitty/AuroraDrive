#!/usr/bin/env python3
"""SpeedExtrapolator 隔离测试装置的构建脚本。

做法（与 verify/takeover_audit 一致）：把生产源 SpeedExtrapolator.swift **逐字复制**
进 build/，与 Tests/main.swift 一起用 swiftc 编译成可执行文件 build/harness。
绝不重写业务逻辑、绝不引入桩代码——测的就是生产里跑的那份。

用法：
  python3 build_harness.py        # 生成 build/harness
"""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "Sources" / "AuroraDrive"
HERE = Path(__file__).resolve().parent
OUT = HERE / "build"
OUT.mkdir(exist_ok=True)

# 逐字复制生产源（唯一依赖是 Foundation，无外部符号）
src_file = SRC / "Agent" / "SpeedExtrapolator.swift"
if not src_file.exists():
    raise SystemExit(f"找不到生产源: {src_file}")
dst_file = OUT / "SpeedExtrapolator.swift"
shutil.copy(src_file, dst_file)

# 断言：复制的是原文（防止误改业务逻辑）
if dst_file.read_text() != src_file.read_text():
    raise SystemExit("复制后内容不一致，中止")

main_swift = HERE / "Tests" / "main.swift"
harness = OUT / "harness"

# 直接调 swiftc 需要显式 SDK 与运行时库路径（不经过 SwiftPM 时它不会自动找）
sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                     capture_output=True, text=True).stdout.strip()
if not sdk:
    raise SystemExit("无法取得 macOS SDK 路径（xcrun 失败）")

cmd = [
    "swiftc",
    "-O",
    "-sdk", sdk,
    "-Xcc", "-isysroot", "-Xcc", sdk,
    "-o", str(harness),
    str(dst_file),
    str(main_swift),
]
print("编译:", " ".join(cmd))
result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0:
    print("--- swiftc stdout ---")
    print(result.stdout)
    print("--- swiftc stderr ---")
    print(result.stderr)
    raise SystemExit(f"编译失败 (exit {result.returncode})")
print(f"✅ 生成 {harness}")
