#!/bin/bash
# ============================================================================
# sign_and_deploy.sh — 真签名 + 原子部署 AuroraDriveUI
#
# 背景：ad-hoc 签名（TeamIdentifier=not set）在 macOS 26 Taskgated 下会被
#       SIGKILL (Code Signature Invalid)（见 ~/Library/Logs/DiagnosticReports/
#       AuroraDriveUI-2026-09-10-*.ips）。用 Apple Development 证书真签名治本。
#
# 用法：
#   ./scripts/sign_and_deploy.sh          # 构建 + 签名 + 原子部署
#   ./scripts/sign_and_deploy.sh --no-build   # 跳过构建，只重签现有产物
#
# 前置：Xcode → Settings → Accounts → Manage Certificates → + →
#       Apple Development（证书自动入钥匙串；免费账号证书 7 天有效期，
#       过期重跑本脚本即可）
# ============================================================================
set -euo pipefail

ROOT="/Users/dupi/Desktop/自动驾驶系统"
BIN="$ROOT/.build/debug/AuroraDriveUI"
DEPLOY="$ROOT/AuroraDriveUI"

# 1. 找签名证书（取第一个有效的 Apple Development）
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Apple Development" | head -1 \
  | sed 's/^[^"]*"\(.*\)"$/\1/')
if [[ -z "${IDENTITY:-}" ]]; then
  echo "✗ 未找到 Apple Development 证书"
  echo "  请在 Xcode → Settings… → Accounts → Manage Certificates… →"
  echo "  左下角 + → Apple Development 生成后重跑本脚本"
  exit 1
fi
echo "✓ 签名证书: $IDENTITY"

# 2. 构建（可跳过）
if [[ "${1:-}" != "--no-build" ]]; then
  echo "→ swift build…"
  (cd "$ROOT" && swift build 2>&1 | grep -E "error|Build complete" | tail -2)
fi
[[ -f "$BIN" ]] || { echo "✗ 未找到构建产物 $BIN"; exit 1; }

# 3. 真签名（带时间戳；不加 --options runtime，最小变更）
echo "→ codesign…"
codesign --force --sign "$IDENTITY" --timestamp "$BIN"

# 4. 校验签名 + TeamID
codesign -dv "$BIN" 2>&1 | grep -E "Signature|TeamIdentifier|CDHash" | sed 's/^/  /'

# 5. 原子部署：cp 到临时文件 + mv 换 inode。
#    绝不原地覆盖运行中二进制（demand paging 读到新旧混合页 → 内核 SIGKILL）
TMP="/tmp/AuroraDriveUI.$$"
cp "$BIN" "$TMP"
mv -f "$TMP" "$DEPLOY"
echo "✓ 已原子部署到 $DEPLOY"
echo "  （运行中的实例不受影响；下次启动 app 自动用新签名版本）"
