#!/usr/bin/env bash
# AuroraDrive 启动脚本
# 双击此文件即可启动自动驾驶系统
#
# 用法：
#   ./start.sh                  # 启动驾驶模式
#   ./start.sh --network-locate-selftest   # 网络定位自检
#   ./start.sh --yolo-selftest <图片路径>   # YOLO 自检
#   ./start.sh --speed-selftest <目录>     # 速度 OCR 自检
#
# 首次运行会提示授权屏幕录制和辅助功能权限

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 颜色定义
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     AuroraDrive 异环自动驾驶系统      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# 检查 Xcode 命令行工具
if ! command -v swift >/dev/null 2>&1; then
    echo -e "${RED}错误：未找到 Swift 编译器${NC}"
    echo "请安装 Xcode 16+ 或 Command Line Tools"
    exit 1
fi

echo -e "${GREEN}✓ Swift 编译器就绪${NC}"

# 构建（Release 模式）
echo ""
echo "▶ 构建项目..."
SWIFT_PACKAGE_DISABLE_SANDBOX=1 swift build -c release 2>&1 | tail -5

BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
    echo -e "${RED}构建失败${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 构建完成${NC}"

# 可执行文件路径
EXECUTABLE=".build/release/AuroraDrive"
if [ ! -f "$EXECUTABLE" ]; then
    echo -e "${RED}错误：找不到可执行文件 ${EXECUTABLE}${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ 启动 AuroraDrive...${NC}"
echo ""

# 运行可执行文件（传递所有参数）
exec "$EXECUTABLE" "$@"
