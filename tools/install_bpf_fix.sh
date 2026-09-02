#!/bin/bash
# 安装BPF权限修复LaunchDaemon（开机自动chmod 666 /dev/bpf*）
# 只需要运行一次，之后重启也生效，App永远不用再输密码

echo "⚠️ 需要输入管理员密码（就是你的开机密码）"
sudo tee /Library/LaunchDaemons/com.aurora.bpf-fix.plist > /dev/null << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aurora.bpf-fix</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/chmod</string>
        <string>666</string>
        <string>/dev/bpf0</string>
        <string>/dev/bpf1</string>
        <string>/dev/bpf2</string>
        <string>/dev/bpf3</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartOnMount</key>
    <true/>
</dict>
</PLIST>
PLIST
sudo chmod 644 /Library/LaunchDaemons/com.aurora.bpf-fix.plist
sudo launchctl load /Library/LaunchDaemons/com.aurora.bpf-fix.plist
sudo chmod 666 /dev/bpf*
echo "✅ BPF权限修复完成！App启动再也不会弹密码框了"