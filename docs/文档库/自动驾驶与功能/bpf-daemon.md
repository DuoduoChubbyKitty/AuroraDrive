# 四级 · BPF 与性能 LaunchDaemon

> **当前实现复核：2026-11-08**
> 权威源码：`Sources/AuroraDrive/Core/PrivilegePill.swift`、`BPFSetup.swift`、`PrioritySetup.swift`。旧版基于 AppleScript/`osascript`、默认密码 `123456`、一次性 `RunAtLoad` chmod 的说明均已失效。

## 1. 当前安装内容

用户在 App 内输入当前 macOS 管理员密码后，`PrivilegePill.install(password:)` 将一次性脚本写到 `/tmp/aurora_privilege_install.sh`，再通过 `sudo -S` 执行。密码只从标准输入传给 `sudo`，不写入命令参数、安装脚本或日志。

安装会创建以下常驻服务：

| 服务 | 程序 | 当前行为 |
|---|---|---|
| `com.aurora.bpf-setup` | `/usr/local/bin/aurora-bpf-setup.sh` | root 身份每 3 秒枚举 `/dev/bpf*`；权限不是 `666` 时执行 `chmod 666` |
| `com.aurora.priority` | `/usr/local/bin/aurora-priority.sh` | root 身份每 5 秒寻找名为 `AuroraDriveUI` 的进程并执行 `renice -20` |

两个 plist 位于 `/Library/LaunchDaemons/`，均设置 `RunAtLoad=true` 与 `KeepAlive=true`，所以安装后会随系统启动并持续运行，不要求 AuroraDrive UI 已打开。

## 2. 为什么需要 BPF 服务

网络定位通过 libpcap 读取 UE5 移动同步流。macOS 的 `/dev/bpfN` 由内核按需创建，初始通常只有 root 能访问。只在开机时 chmod 一次无法覆盖稍后新建的设备，因此当前脚本采用常驻轮询。

`BPFSetupManager.isBPFAvailable()` 会动态枚举最多 64 个 BPF 设备，并用 `access(O_RDWR)` 判断普通用户进程是否真的能读写；不再只检查 `/dev/bpf0`。

## 3. 安装流程

```text
App 内 SecureField 输入管理员密码
  → PrivilegePill.install(password:)
  → 写临时安装脚本（0700）
  → sudo -S -p '' /bin/bash -c '/bin/bash /tmp/aurora_privilege_install.sh'
  → 写两个 /usr/local/bin/aurora-*.sh
  → 写两个 /Library/LaunchDaemons/com.aurora.*.plist
  → launchctl bootstrap + kickstart
  → 立即 chmod 666 /dev/bpf*
  → 删除临时安装脚本并复核权限状态
```

没有默认密码。旧文档里的 `123456` 是已经删除的开发期临时值。

## 4. 安全边界

- `chmod 666 /dev/bpf*` 会允许**本机所有用户进程**访问抓包设备，而不是只授权 AuroraDrive。单用户实验机风险相对可控，多用户或高安全要求设备不建议使用这一权限模型。
- 两个脚本均以 root 身份无限循环，并由 launchd `KeepAlive`。脚本被替换或路径被非预期修改会扩大风险，因此 `/usr/local/bin/aurora-*.sh` 必须保持 `root:wheel` 所有权且不可由普通用户写入。
- `renice -20` 会提高 AuroraDrive 调度优先级，可能进一步挤压游戏或其他前台任务。它不是网络定位的必要条件，只是当前统一安装脚本的一部分。
- 密码虽然不落盘、不进 argv，但会短暂存在于 App 与 `sudo` 的进程内存中。用户必须信任当前源码和实际运行的构建产物。

## 5. 当前状态检查

```sh
sudo launchctl print system/com.aurora.bpf-setup
sudo launchctl print system/com.aurora.priority
ls -l /Library/LaunchDaemons/com.aurora.*.plist
ls -l /usr/local/bin/aurora-*.sh
ls -l /dev/bpf*
```

正常情况下，两个服务显示 `state = running`，BPF 设备显示 `crw-rw-rw-`。

## 6. 排障

| 症状 | 检查与处理 |
|---|---|
| App 显示 BPF 不可用 | 检查服务状态与 `/dev/bpf*` 权限；游戏或抓包程序未启动时设备可能尚未创建 |
| plist 存在但服务未运行 | `sudo launchctl kickstart -k system/com.aurora.bpf-setup`，再检查 launchd 输出 |
| 密码错误 | App 会识别 `incorrect password` / `sorry, try again` 并要求重新输入 |
| 权限显示已安装但定位无数据 | 权限只解决“能打开 BPF”；还需确认接口选择、tcp/30031 流量和 UE5 数据解析 |
| 旧服务仍存在 | 早期版本可能遗留 `com.aurora.bpf-fix.plist`；它不属于当前安装脚本，应单独审查后再决定是否移除 |

## 7. 文档口径

当前实现是“`sudo -S` + 两个常驻 LaunchDaemon”，不是：

- 默认密码 `123456`；
- `osascript ... with administrator privileges`；
- 把密码拼进 AppleScript 或进程参数；
- 只在开机时执行一次 chmod；
- 只安装 `com.aurora.bpf-setup` 一个服务。

后续若权限方案改变，应优先同步本文、根目录中英文 README 与 `00-文档索引.md`。
