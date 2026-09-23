# 四级 · BPF 权限与 LaunchDaemon 自动安装

> 实现于 `Sources/AuroraDrive/BPFSetup.swift`（162 行）+ `AuroraDriveApp.swift` 的 `BPFPasswordSheet`
> 上级：[网络定位子系统](02-network-locate.md) ｜ English: [BPF & LaunchDaemon](../英文版/bpf-daemon.en.md)

> **档案标注（2026-09-19 核对更新，基线 7b7d2db）**：`BPFSetup.swift` 由 125 行增至 162 行——新增 `isLaunchDaemonLoaded()`（`launchctl list | grep` 判断）、`needsLoad()`（已装未载）与 `loadDaemonIfNeeded()`（`launchctl load` + `start` 补载）三个 API（后两者目前无调用方，属预留能力）；启动路径仍为：BPF 可用 → 通过；否则 Daemon 未装 → 弹密码窗；Daemon 已装 → `tryImmediateChmod()` 重测。脚本内容、路径与判定表未变，正文各节核对仍成立。

## 1. 问题

libpcap 抓包需要 `/dev/bpf*` 设备可读写，但 macOS **每次重启**都会把这些节点重置为 root-only（`crw-------`）。这意味着任何依赖 pcap 的程序在普通用户下每次开机都会失效。

## 2. 方案总览

```
App 启动
  → BPFSetupManager.needsInstall()
      = !isBPFAvailable() && !isLaunchDaemonInstalled()
  → true: TopToolbar 显示 BPF 药丸 + 自动弹 BPFPasswordSheet（默认密码 123456）
  → 用户点击「安装」→ install(password:)：
      1. 生成 shell 脚本写入 /tmp/aurora_bpf_setup.sh（0o755）
      2. osascript: do shell script "bash /tmp/..." password "<pwd>"
         with administrator privileges        ← 密码经参数传入，不弹系统密码窗
      3. 脚本内容：
         - 写 /usr/local/bin/aurora-bpf-setup.sh（chmod 666 /dev/bpf*）
         - 写 /Library/LaunchDaemons/com.aurora.bpf-setup.plist（RunAtLoad=true）
         - launchctl load 该 plist
         - 立即 chmod 666 /dev/bpf*（本次会话立即生效）
         - echo "BPF_SETUP_DONE"（成功标志）
      4. terminationStatus==0 且 isBPFAvailable() → 成功
```

**效果**：用户只输一次密码。之后每次重启，launchd 自动跑 setup 脚本恢复 BPF 权限，App 无感。

## 3. 关键实现细节

### 3.1 密码经 AppleScript 参数传递（不弹系统窗）

```swift
let escapedPwd = password.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
let appleScript = "do shell script \"bash \(scriptPath)\" password \"\(escapedPwd)\" with administrator privileges"
```

先转义 `\` 再转义 `"`（顺序不能反），防止密码含特殊字符破坏 AppleScript 字符串。osascript 以 `Process` 方式运行并捕获 stdout/stderr。

### 3.2 结果判定

| 情况 | 判定 |
|---|---|
| 退出码 0 + `isBPFAvailable()` | 「BPF权限已安装，开机自动生效」 |
| 退出码 0 但 BPF 仍不可用 | 「LaunchDaemon已安装，请重启电脑后生效」（launchd 加载有时序） |
| stderr 含 Authentication/password | 「密码错误」 |
| 其他非零退出 | 「安装失败: <stderr>」 |

### 3.3 launchd 时序兜底（tryImmediateChmod）

开机早期 launchd 可能还没跑到我们的 plist。`tryImmediateChmod()` 用 `launchctl start com.aurora.bpf-setup` 手动 kickstart，`sleep 1` 后 `test -r /dev/bpf0` 验证——App 启动时若 LaunchDaemon 已装但 BPF 仍不可用就走这条路，不用重启电脑。

### 3.4 状态机（AuroraDriveApp 侧）

```
BPFSetupManager.needsInstall() 或 提权 Daemon(PrioritySetup) 未装?
├─ 是 → showBPFPasswordSheet=true → 同一密码窗一次装齐 BPF + 性能提权
│       （注意代码注释：必须并入首条件，否则被 isBPFAvailable 分支截胡，提权器永远装不上）
└─ 否 → BPFSetupManager.isBPFAvailable()?
    ├─ 是 → bpfAuthorized=true，药丸不显示
    └─ 否 → BPFSetupManager.isLaunchDaemonInstalled()?
        ├─ true → tryImmediateChmod() → 重测
        └─ false → 保持 bpfAuthorized=false
```

## 4. 安全权衡（如实说明）

- 密码**不落盘**：只在 osascript 参数里用一次，进程结束即消失；但会出现在该进程的启动参数里（`ps` 可见瞬间）——单用户个人机可接受
- LaunchDaemon 脚本以 root 跑 `chmod 666 /dev/bpf*`：把包捕获设备开放给所有用户——这是 pcap 类工具（Wireshark 同款方案）的标准做法，但在多用户机器上意味着任何本地用户都能抓包
- plist 固定路径 `/Library/LaunchDaemons/com.aurora.bpf-setup.plist`，`isLaunchDaemonInstalled()` 用文件存在性判断

## 5. 排障

| 症状 | 原因与处理 |
|---|---|
| 装完显示「请重启电脑后生效」 | launchd 加载时序，重启或 `sudo launchctl kickstart -k system/com.aurora.bpf-setup` |
| 重启后 BPF 又不可用 | 检查 plist 是否存在：`ls /Library/LaunchDaemons/com.aurora.bpf-setup.plist`；被安全软件清除则重装 |
| 密码窗重复弹出 | `isBPFAvailable()` 失败 + Daemon 未装；先手动 `sudo chmod 666 /dev/bpf*` 验证 BPF 本身可用 |
