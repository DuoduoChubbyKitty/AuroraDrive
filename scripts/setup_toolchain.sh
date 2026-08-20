#!/usr/bin/env bash
# setup_toolchain.sh — 一键安装 AuroraDrive 原生 App 构建工具链
#
# 安装内容：
#   1. Rust + Cargo（rustup）
#   2. Tauri CLI v2
#   3. CMake（C++ 构建系统）
#   4. LibTorch（C++ 推理依赖，可选）
#
# 用法：
#   ./scripts/setup_toolchain.sh
#
# 注意：需要网络访问。brew 应已安装。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== AuroraDrive 工具链安装 ==="
echo "  项目根: $ROOT"
echo ""

# ─────────────────────────────────────────────
# 1. Rust + Cargo
# ─────────────────────────────────────────────
if ! command -v cargo >/dev/null 2>&1; then
    echo "▶ 安装 Rust（rustup）..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
else
    echo "✓ Rust 已安装：$(rustc --version)"
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env" 2>/dev/null || true
fi

# ─────────────────────────────────────────────
# 2. Tauri CLI v2
# ─────────────────────────────────────────────
if ! cargo tauri --version >/dev/null 2>&1; then
    echo "▶ 安装 Tauri CLI v2..."
    cargo install tauri-cli --version "^2.0" --locked
else
    echo "✓ Tauri CLI 已安装：$(cargo tauri --version 2>&1 | head -1)"
fi

# ─────────────────────────────────────────────
# 3. CMake
# ─────────────────────────────────────────────
if ! command -v cmake >/dev/null 2>&1; then
    echo "▶ 安装 CMake..."
    brew install cmake
else
    echo "✓ CMake 已安装：$(cmake --version | head -1)"
fi

# ─────────────────────────────────────────────
# 4. 构建 C++ sidecar（CMake）
# ─────────────────────────────────────────────
echo "▶ 构建 C++ sidecar..."
mkdir -p "$ROOT/cpp/build"
cd "$ROOT/cpp/build"
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --parallel
cd "$ROOT"

echo ""
echo "=== ✅ 工具链安装完成 ==="
echo "  Rust:    $(rustc --version)"
echo "  Tauri:   $(cargo tauri --version 2>&1 | head -1)"
echo "  CMake:   $(cmake --version | head -1)"
echo ""
echo "下一步："
echo "  1. cd frontend && pnpm install --no-frozen-lockfile && pnpm run build   # 构建前端"
echo "  2. cargo tauri dev                               # 开发模式启动 App"
echo "  3. cargo tauri build                             # 打包 .app/.dmg"
