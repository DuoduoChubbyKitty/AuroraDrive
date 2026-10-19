# 代码-01 AuroraDriveShared 与 UserAgent XPC 服务

> ✅ **2026-10-18 复核**（merge-arch）：逐行对照 `Sources/AuroraDriveShared/AuroraDriveShared.swift`（21 行）与 `Sources/AuroraDriveUserAgent/main.swift`（52 行），两个文件的行号引用全部命中，无漂移。**但发现一个重大口径问题**：
>
> **本文描述的整条「XPC Agent 服务链」已废弃**（详见 §四），这是本次复核最重要的修正。
> - ① `DaemonSetup.swift`（Core/）第 9-14 行注释原文：*「原『用户会话 XPC Agent』方案**已废弃**——实测 launchd 拉起的后台进程拿不到 TCC 权限（ax=false、screen=false），驾驶引擎改为由主程序 spawn 的子进程承担」*。
> - ② `isRunningAsDaemon()` 恒 `false`、`isDaemonInstalled()` 恒 `false`（`DaemonSetup.swift:22` / `:25`，空壳兼容入口）；`needsInstall() = !isBPFAvailable()`（:28）——**daemon 安装路径已从"装 Agent"变成"装 BPF 权限守护"**。
> - ③ 全仓 `Sources/` 内 **`com.aurora.drive.agent` 只出现在 AuroraDriveShared.swift:8-9 两行常量定义里**；`NSXPCConnection` / `AuroraDriveUserAgentProtocol` 在 `AuroraDrive` 主 target **零引用**（`grep -rn` 实测，输出为空）；`ping` / `startDriving` / `stopDriving` 三个 XPC 方法**没有任何客户端调用**（`EngineMain.swift:1513/1525` 与 `EngineGlobals.state?.startDriving()` 是驾驶引擎的同名方法，与 XPC 协议无关）。
> - ④ 机器现状：`launchctl list | grep com.aurora.drive.agent` → **0 命中**（Agent 未注册）；`~/Library/LaunchAgents/` 无该 label；`/Library/LaunchDaemons/` 里只有 `com.aurora.bpf-fix.plist` / `com.aurora.bpf-setup.plist` / `com.aurora.drive.daemon.plist` / `com.aurora.priority.plist` —— 其中 `com.aurora.drive.daemon.plist` 的 Label 是 `com.aurora.drive.daemon`（**不是** `.agent`）、`ProgramArguments` 指向 `/usr/local/bin/aurora-drive-daemon --daemon`（即 AuroraDriveUI 二进制本身）、**且无 `MachServices` key**，与 XPC Agent 无关。
> - ⑤ `drivingRequested` 置位后确实无任何读取（`main.swift:9/17/24` 三处，grep 全仓只有这三行）——原文此结论仍成立。
>
> 处置：**保留源码级描述**（两个文件本身仍编译进 `Package.swift`：`AuroraDriveUserAgent` 是 `executableTarget`，`:72-76`；`AuroraDriveShared` 被两个 target 依赖 `:55-56/:79`），**但把「宿主运行链」从现状描述改为历史链**，并新增 §四说明现状。

> 覆盖源文件：`Sources/AuroraDriveShared/AuroraDriveShared.swift`（21 行）、`Sources/AuroraDriveUserAgent/main.swift`（52 行）。基于当前仓库逐单元编写。

## 一、服务名与协议定义（AuroraDriveShared.swift 逐行）

`AuroraDriveShared` 是一个 21 行的极小库 target，只放 UI 进程与用户会话 Agent 共用的**身份常量**和 **XPC 协议声明**——两边都 import 它，保证服务名/协议签名不漂移。

**`AuroraDriveServiceIdentity`（enum，全静态常量，第 7–11 行）：**

| 成员 | 值 | 用途 |
|---|---|---|
| `machServiceName` | `"com.aurora.drive.agent"` | Mach 服务名，`NSXPCListener(machServiceName:)` 用它注册 |
| `launchAgentLabel` | `"com.aurora.drive.agent"` | launchd 的 Label，`launchctl` / LaunchAgent plist 用它 |
| `protocolVersion` | `1` | XPC 协议版本号，`ping` 回复的第一个 Int |

**`AuroraDriveUserAgentProtocol`（`@objc` protocol，第 17–21 行）——用户会话 Agent 的最小 XPC 接口，只有 3 个方法：**

```swift
func ping(withReply reply: @escaping (Int, String) -> Void)
func startDriving(withReply reply: @escaping (Bool, String) -> Void)
func stopDriving(withReply reply: @escaping (Bool, String) -> Void)
```

- `ping` → 回复 `(protocolVersion, "ready")`，健康检查用
- `startDriving` → 置位 drivingRequested，回复 `(true, "accepted")`
- `stopDriving` → 清零 drivingRequested，回复 `(true, "accepted")`

**设计约束（源文件注释原文）**：当前阶段只提供健康检查和生命周期信号，**不把任意 shell 命令暴露给 XPC 客户端**；后续迁移捕获/推理/控制时，应继续沿用窄接口，不直接暴露引擎对象。这是刻意的安全边界：XPC 面只传"意图信号"，不传"执行能力"。

注意协议是 `@objc` 的——`NSXPCInterface(with:)` 要求 ObjC 可见的协议，成员都必须用 `withReply:` 形式（reply 闭包在服务端异步填充）。

## 二、UserAgentService 实现与 NSXPCListener 装配（main.swift 逐行）

`main.swift`（52 行）是 `AuroraDriveUserAgent` 可执行 target 的顶层代码，无 `@main` 标注（顶层语句直接执行）。三个部分：

**① `UserAgentService`（NSObject + AuroraDriveUserAgentProtocol，第 7–28 行）**

- 状态：`private let lock = NSLock()` + `private var drivingRequested = false`
- `ping(withReply:)`（11–13 行）：`reply(AuroraDriveServiceIdentity.protocolVersion, "ready")`——回协议版本 + ready
- `startDriving(withReply:)`（15–20 行）：`lock.lock()` → `drivingRequested = true` → `lock.unlock()` → `reply(true, "accepted")`
- `stopDriving(withReply:)`（22–27 行）：同样加锁，置 `drivingRequested = false`，回复 `(true, "accepted")`

**注意**：`drivingRequested` 置位后**当前没有任何代码读取它**——这是预留的状态位，真正的驾驶启动逻辑尚未接入 XPC 面（与 3 方法窄接口的设计一致）。XPC 连接是并发的，所以状态位必须加锁（`NSLock`）。

**② `UserAgentDelegate`（NSXPCListenerDelegate，第 30–44 行）**

```swift
func listener(_ listener: NSXPCListener,
              shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: AuroraDriveUserAgentProtocol.self)
    newConnection.exportedObject = service
    newConnection.resume()
    return true
}
```

- `exportedInterface`：把共享协议挂到连接上（客户端凭此调用）
- `exportedObject`：单一 `service` 实例（`private let service = UserAgentService()`，第 31 行）服务所有连接
- `newConnection.resume()`：必须调用，否则连接永远不活
- 返回 `true`：**无条件接受任何新连接**——没有 code-signing 校验/客户端白名单。安全边界靠"接口窄"（只有 ping/start/stop）而非"连接触名"。若后续要收紧，在 `shouldAcceptNewConnection` 里加 `newConnection.remoteObject` 的审计校验。

**③ 顶层装配与常驻（第 46–52 行）**

```swift
private let delegate = UserAgentDelegate()
private let listener = NSXPCListener(machServiceName: AuroraDriveServiceIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
```

- `NSXPCListener(machServiceName:)`：按 launchd 注册的 Mach 服务名监听（要求进程由 LaunchAgent 启动且 plist 声明了 `MachServices` key，否则监听收不到连接）
- `listener.resume()` 启动监听；`RunLoop.current.run()` 让主线程常驻不退出（顶层代码跑完 RunLoop 才不终止进程）

**宿主运行链（历史链，2026-10-18 复核确认已废弃）**：原设计为 `DaemonSetup.swift`（Core/）安装 LaunchAgent → launchd 以 label `com.aurora.drive.agent` 拉起本进程 → 本监听接受 UI 进程（AuroraDrive）的连接 → `ping` 健康检查。

> ⚠️ **这条链今天不成立**：实测 `launchctl list` 无 `com.aurora.drive.agent`、`~/Library/LaunchAgents/` 无该 plist、`AuroraDrive` 主 target 零处引用该协议。废弃原因与现状见 §四。

## 四、现状：这条 XPC 链已废弃（2026-10-18 复核新增）

**结论**：`AuroraDriveShared` + `AuroraDriveUserAgent` 这组 target **仍在 `Package.swift` 里、仍能编译**（`AuroraDriveUserAgent` 是 `.executableTarget`，`Package.swift:72-76`；产物 `.build/scratch/release/AuroraDriveUserAgent` 存在，64,280 B），**但它们承担的 XPC 服务链已被放弃**。

**废弃原因（`DaemonSetup.swift:9-14` 注释原文）**：

> 原「用户会话 XPC Agent」方案**已废弃**——实测 launchd 拉起的后台进程拿不到 TCC 权限（ax=false、screen=false），驾驶引擎改为由主程序 spawn 的子进程承担（沿进程链继承权限，见 `EngineMain.swift` / `EngineClient.swift`）。

即：launchd 起的后台进程**拿不到屏幕录制 + 辅助功能权限**，而自动驾驶这两样都要。改为主程序 spawn 子进程，权限沿进程链继承。

**现状的四条硬证据**：

| 检查 | 命令 | 结果 |
|---|---|---|
| 全仓引用 | `grep -rn "com.aurora.drive.agent" Sources/` | 仅 `AuroraDriveShared.swift:8-9` 两行常量定义 |
| 主 target 是否用协议 | `grep -rn "NSXPCConnection\|AuroraDriveUserAgentProtocol" Sources/`（排除两个 agent 文件） | **空** |
| 客户端调用 | `grep -rn "startDriving\|stopDriving\|\.ping(" Sources/` | 命中的全是 `EngineMain` / `AuroraDriveApp` 的**同名驾驶方法**，与 XPC 协议无关 |
| launchd 注册 | `launchctl list \| grep com.aurora.drive.agent` | **0 命中**（未注册、未加载） |

**DaemonSetup 的空壳现状**（对应代码-30 的二节）：`isRunningAsDaemon()` 恒 `false`（:22）、`isDaemonInstalled()` 恒 `false`（:25）、`needsInstall() = !isBPFAvailable()`（:28）、`install(password:)` 保留参数但不读取（:34）、`uninstall(password:)` 恒 `(true, "无需卸载")`（:47）。**"装 daemon"这件事已被"装 BPF 权限守护"取代**（见 `PrivilegePill` 与 `BPFSetup`）。

**现存 launchd 服务清单**（`/Library/LaunchDaemons/`）：`com.aurora.bpf-fix.plist`、`com.aurora.bpf-setup.plist`、`com.aurora.priority.plist`、`com.aurora.drive.daemon.plist`。**没有一个是 `com.aurora.drive.agent`**。其中 `com.aurora.drive.daemon.plist` 的 Label 是 `com.aurora.drive.daemon`、`ProgramArguments` 为 `/usr/local/bin/aurora-drive-daemon --daemon`（该文件是 AuroraDriveUI 二进制本体，非 UserAgent）、且 plist 内**无 `MachServices` key** —— 它是"用 daemon 模式跑主程序"，与 XPC Agent 是两回事。

**因此本文的一二两节应按"历史实现"阅读**：源码描述本身仍准确（可直接对照两个文件读懂 NSXPC 的最小用法），但**不要把"宿主运行链"当成产品现状**。
