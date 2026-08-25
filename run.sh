#!/bin/sh
# run.sh — AuroraDrive 一键编译+签名+启动
# 用法: ./run.sh           → 编译+签名+启动 GUI
#       ./run.sh --status  → 只检查环境,不启动
#       ./run.sh --yolo-selftest <图片>  → YOLO 自检
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

BIN_SRC=".build/release/AuroraDrive"
BIN_DST="AuroraDriveUI"

echo "═══════════════════════════════════════════════"
echo "  AuroraDrive 启动脚本"
echo "═══════════════════════════════════════════════"

# ── 环境检查 ──
echo ""
echo "[1/4] 环境检查"
SWIFT_VER=$(swift --version 2>&1 | head -1)
echo "  Swift: $SWIFT_VER"
MACOS_VER=$(sw_vers -productVersion 2>/dev/null)
echo "  macOS: $MACOS_VER"

# libpcap 检查
if ls /usr/lib/libpcap* >/dev/null 2>&1 || brew list libpcap >/dev/null 2>&1; then
    echo "  libpcap: ✓ 已安装"
else
    echo "  libpcap: ✗ 未安装 (NetworkPacketCapture.swift 需要)"
    echo "    安装: brew install libpcap"
fi

# 模型检查
echo ""
echo "[2/4] 模型检查"
for m in m9_mono game_assist_control yolo26s; do
    if [ -d "models/${m}.mlmodelc" ]; then
        echo "  ${m}.mlmodelc: ✓"
    elif [ -d "models/${m}.mlpackage" ]; then
        echo "  ${m}.mlpackage: ✓ (未编译,回退加载)"
    else
        echo "  ${m}: ✗ 缺失!"
    fi
done

# --status 模式:只检查不启动
if [ "$1" = "--status" ]; then
    echo ""
    echo "[完成] 仅检查模式,不启动。"
    exit 0
fi

# ── 编译 ──
echo ""
echo "[3/4] 编译 (release)"
# 必须先清缓存! SwiftPM 缓存会导致代码改动不生效
rm -rf .build
swift build -c release 2>&1 | tail -5
if [ -f "$BIN_SRC" ]; then
    echo "  编译成功 ✓"
else
    echo "  编译失败! 请检查错误"
    exit 1
fi

# ── 复制+签名 ──
echo ""
echo "[4/4] 签名 + 部署"
/usr/bin/codesign --force --deep --sign - "$BIN_SRC" 2>/dev/null || true
cp "$BIN_SRC" "$BIN_DST"
/usr/bin/xattr -d com.apple.quarantine "$BIN_DST" 2>/dev/null || true

# 构建 .app bundle(从子进程启动时需要,避免 SIGKILL)
BUNDLE_DIR="$ROOT/AuroraDriveUI.app"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
cp "$BIN_SRC" "$BUNDLE_DIR/Contents/MacOS/AuroraDriveUI"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  '<key>CFBundleExecutable</key><string>AuroraDriveUI</string>' \
  '<key>NSPrincipalClass</key><string>NSApplication</string>' \
  '<key>CFBundleIdentifier</key><string>com.aurora.driveui</string>' \
  '<key>CFBundleName</key><string>AuroraDrive</string>' \
  '<key>CFBundlePackageType</key><string>APPL</string>' \
  '<key>CFBundleShortVersionString</key><string>1.0</string>' \
  '<key>CFBundleVersion</key><string>1</string>' \
  '<key>LSMinimumSystemVersion</key><string>14.0</string>' \
  '</dict></plist>' > "$BUNDLE_DIR/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$BUNDLE_DIR" 2>/dev/null || true
/usr/bin/xattr -d com.apple.quarantine "$BUNDLE_DIR" 2>/dev/null || true

# 清理旧进程
/usr/bin/pkill -f "AuroraDriveUI" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════"
echo "  部署完成:"
echo "  裸可执行: $ROOT/$BIN_DST"
echo "  .app bundle: $BUNDLE_DIR"
echo "═══════════════════════════════════════════════"
echo ""

# 启动
if [ "$1" = "--yolo-selftest" ] && [ -n "$2" ]; then
    echo "运行 YOLO 自检: $2"
    ./$BIN_DST --yolo-selftest "$2"
elif [ "$1" = "--yolo-bench" ] && [ -n "$2" ]; then
    echo "运行 YOLO 基准: $2"
    ./$BIN_DST --yolo-bench "$2"
else
    echo "启动 AuroraDrive..."
    # 优先用 .app bundle (LaunchServices 干净父进程)
    open "$BUNDLE_DIR"
    echo "已启动。如果没出现窗口,检查:"
    echo "  1. 屏幕录制权限: 系统设置 → 隐私 → 屏幕录制"
    echo "  2. 辅助功能权限: 系统设置 → 隐私 → 辅助功能"
    echo "  3. 手动跑裸文件: ./$BIN_DST"
fi
