#!/bin/bash
# AuroraDrive 编译并更新可执行文件脚本
# 使用方法：在终端运行 ./compile_and_update.sh

set -e

echo "🔨 开始编译 AuroraDrive..."
cd "$(dirname "$0")"

# 备份旧版本
if [ -f "AuroraDriveUI" ]; then
    backup_name="AuroraDriveUI.bak-$(date +%Y%m%d-%H%M%S)"
    cp AuroraDriveUI "$backup_name"
    echo "✅ 已备份旧版本到: $backup_name"
fi

# 尝试在Xcode中编译
echo "📦 正在编译（这可能需要几分钟）..."
/Volumes/项目依赖/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
    -scheme AuroraDrive \
    -configuration Release \
    -derivedDataPath .build \
    build 2>&1 | tee /tmp/aurora_build.log | grep -E "(Building|Linking|error|warning|succeeded)"

# 查找编译产物
echo ""
echo "🔍 查找编译产物..."

# 可能的位置
possible_paths=(
    ".build/Build/Products/Release/AuroraDrive"
    ".build/arm64-apple-macosx/release/AuroraDrive"
    "~/Library/Developer/Xcode/DerivedData/AuroraDrive-*/Build/Products/Release/AuroraDrive"
)

found=""
for path in "${possible_paths[@]}"; do
    expanded_path=$(eval echo "$path")
    if [ -f "$expanded_path" ]; then
        found="$expanded_path"
        echo "✅ 找到编译产物: $found"
        break
    fi
done

if [ -z "$found" ]; then
    echo "❌ 未找到编译产物，可能编译失败"
    echo "请检查日志: /tmp/aurora_build.log"
    exit 1
fi

# 复制可执行文件
cp "$found" AuroraDriveUI
chmod +x AuroraDriveUI
echo "✅ 已更新可执行文件: AuroraDriveUI"

# 显示版本信息
file_size=$(du -h AuroraDriveUI | cut -f1)
echo ""
echo "🎉 编译完成！"
echo "   文件大小: $file_size"
echo "   可执行文件: $(pwd)/AuroraDriveUI"
echo ""
echo "💡 现在可以双击 AuroraDriveUI 运行应用了"
