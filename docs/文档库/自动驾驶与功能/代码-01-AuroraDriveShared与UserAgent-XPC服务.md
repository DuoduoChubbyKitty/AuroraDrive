# 代码-01 AuroraDriveShared 与 UserAgent XPC 服务

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

**宿主运行链**：`DaemonSetup.swift`（Core/）安装 LaunchAgent → launchd 以 label `com.aurora.drive.agent` 拉起本进程 → 本监听接受 UI 进程（AuroraDrive）的连接 → `ping` 健康检查。
