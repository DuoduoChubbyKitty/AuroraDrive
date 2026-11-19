#!/bin/bash
# 独立对抗测试：独立 swiftc 编译，生产源逐字复制（不修改 Sources/...）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$AUDIT/../.." && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"

unset TMPDIR
export PATH="/Volumes/项目依赖/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"

SDK=$(xcrun --sdk macosx --show-sdk-path) || { echo "xcrun 失败"; exit 1; }

# 逐字复制生产源并校验一致（绝不改写业务逻辑）
cp "$ROOT/Sources/AuroraDrive/Agent/SpeedExtrapolator.swift" "$OUT/SpeedExtrapolator.swift"
cmp -s "$OUT/SpeedExtrapolator.swift" "$ROOT/Sources/AuroraDrive/Agent/SpeedExtrapolator.swift" || {
  echo "生产源复制不一致，中止"; exit 1; }

echo "编译：swiftc -O -sdk $SDK -o $OUT/adv_tests <生产源> <对抗测试 main.swift>"
swiftc -O -sdk "$SDK" -Xcc -isysroot -Xcc "$SDK" \
  -o "$OUT/adv_tests" \
  "$OUT/SpeedExtrapolator.swift" \
  "$HERE/SpeedExtrapolatorAdversarialTests/main.swift"
rc=$?
if [ $rc -ne 0 ]; then echo "编译失败 (exit $rc)"; exit $rc; fi
echo "✅ 生成 $OUT/adv_tests"
