#!/usr/bin/env python3
"""SpeedExtrapolator「补充固定用例」的独立构建脚本。

与 build_harness.py 的区别：main.swift 里已有顶层代码与 main 入口，
再把它和补充用例一起编译会出现重复 main 符号。因此这里只把
build/SpeedExtrapolator.swift（生产源逐字副本）+ Tests/main_fixed_extra.swift
用 -parse-as-library + @main 单独编译成 build/harness_extra。

用法：
  python3 build_harness_extra.py
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = HERE / "build"
src = OUT / "SpeedExtrapolator.swift"          # 由 build_harness.py 复制
tests = HERE / "Tests" / "main_fixed_extra.swift"
harness = OUT / "harness_extra"

prod = ROOT / "Sources" / "AuroraDrive" / "Agent" / "SpeedExtrapolator.swift"
if not src.exists():
    raise SystemExit(f"缺少 {src}，请先运行 build_harness.py")
if src.read_text() != prod.read_text():
    raise SystemExit("build/SpeedExtrapolator.swift 与生产源不一致，中止")

sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                     capture_output=True, text=True).stdout.strip()
if not sdk:
    raise SystemExit("无法取得 macOS SDK 路径（xcrun 失败）")

cmd = [
    "swiftc", "-O", "-parse-as-library",
    "-sdk", sdk, "-Xcc", "-isysroot", "-Xcc", sdk,
    "-o", str(harness), str(src), str(tests),
]
print("编译:", " ".join(cmd))
result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0:
    print("--- swiftc stdout ---"); print(result.stdout)
    print("--- swiftc stderr ---"); print(result.stderr)
    raise SystemExit(f"编译失败 (exit {result.returncode})")
print(f"✅ 生成 {harness}")
