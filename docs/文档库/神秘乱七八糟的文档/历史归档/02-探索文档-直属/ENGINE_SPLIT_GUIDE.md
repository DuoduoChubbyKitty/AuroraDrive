# AuroraDrive 纯后台引擎拆分工程

> 📁 档案（2026-09-19 注）：引擎拆分已于 2026-09-11 完成（5/5 步，见 ENGINE_SPLIT_PROGRESS.md），本文中的"复工引导"步骤仅供历史回溯。文中 `cp .build/release/AuroraDrive` 等命令里的 `.build/` 为编译缓存（2026-09-19 已移至外置硬盘删除_20260919），`swift build -c release` 会重建，执行前请先构建。

## 一、复工引导（上下文丢失后第一件事）
1. 调 get_goal 确认目标与轮次
2. 读本文件恢复进度（ENGINE_SPLIT_PROGRESS.md）
3. `git log --oneline -10 && git status` 看当前 commit
4. `ls Sources/AuroraDrive/*.swift` 确认文件列表
5. 不要猜、不要重写已有逻辑；每个改动必须对应到具体文件 + 行号

---

## 二、项目基础（已深度核实）

**路径**：`/Users/dupi/Desktop/自动驾驶系统`
**构建**：SwiftPM，`swift build -c release`，产物 `.build/release/AuroraDrive`
**入口**：`@main struct AuroraDriveApp: App` 在 `AuroraDriveApp.swift:421`
**驱动闭环组装点**：`AuroraDriveApp.swift:955~1013`（applicationDidFinishLaunching 末尾）

### 已知组件清单（这些文件别动，在之上搭接口）
| 文件 | 职责 |
|---|---|
| `CaptureEngine.swift` | ScreenCaptureKit 抓屏（需屏幕录制权限） |
| `YoloEngine.swift` | CoreML YOLO 推理（@Observable @MainActor） |
| `ControlEngine.swift` | CGEvent HID 注入（需辅助功能权限） |
| `RuleController.swift` | 决策逻辑 |
| `DegradeStateMachine.swift` | 降级状态机 |
| `VisualLocator.swift` / `MinimapLocatorView.swift` / `GameMapView.swift` | UI 组件 |
| `Vendor/MetalGoose/` | 插帧渲染（UI 显示用） |
| `KeyboardMonitor.swift` | 物理键盘监听 |
| `AuroraDriveShared/` | XPC 协议（ping/startDriving/stopDriving） |
| `DaemonSetup.swift` | 现有 launchd Agent 安装器（废弃 BPF 部分） |

### 协作接口（理解这些，别破坏）
- CaptureEngine → onFrame 闭包（NSImage+CGImage）、onYoloFrame 闭包（CVPixelBuffer）、onUpscaleFrame 闭包
- YoloEngine → @Observable Detection 数组
- ControlEngine → hold/release 方法（按键注入）
- RuleController → 接收检测框，输出决策

---

## 三、已验证事实（禁止重新验证，直接使用）

1. ❌ **launchd 拉起进程拿不到 TCC 权限**（实测 ax=false, screen=false，2026-09-10）
2. ✅ **已授权进程 spawn 的子进程自动继承权限**（TCC responsible process 继承机制）
3. ⚠️ **编译后必须签名**：`cp` 覆盖二进制后必须跟 `codesign --force --sign -`，否则 `load code signature error 2 → kill -9`
4. 主程序已有三层防冻结：IOPMAssertion + CGEventTap（.cgSessionEventTap） + 768MB mlock 内存锚点（AppDelegate 第 26-33 行）

---

## 四、定死架构（不可动摇的设计决策）

### 核心思路
- **主程序 = UI 壳**（保留原有 SwiftUI 主体）
- **引擎子进程 = 纯后台闭环**（CaptureEngine + YoloEngine + ControlEngine + RuleController 全部在子进程里）
- **TCC 权限靠进程链继承**：主程序 spawn 子进程，子进程自动继承权限，零弹窗零配置
- **UI 可关闭**：引擎被系统收养继续驾驶，UI 重开重连恢复

### 通信方案（已选定，不再讨论）
| 数据类型 | 方案 | 路径/命名 |
|---|---|---|
| 帧（大带宽） | POSIX 共享内存双缓冲 | shm_open("aurora_frame")，mmap 双缓冲，命名信号量 |
| 命令/状态/心跳 | Unix domain socket | `~/Library/Application Support/AuroraDrive/engine.sock` |
| 启动发现 | 主进程 spawn 时传 pid 或自动扫描 socket | 见步骤 2 |

### TCC 自检流程（引擎启动第一步）
```swift
let axOK = AXIsProcessTrusted()  // 纯查询，不弹窗
let screenOK = CGPreflightScreenCaptureAccess()  // macOS 10.15+，纯查询
if !(axOK && screenOK) {
    print("[ENGINE] TCC 权限继承失败！ax=\(axOK) screen=\(screenOK)")
    exit(2)  // fail-fast
}
```

### 防冻结
- 引擎子进程 spawn 后立即：`ProcessInfo.beginActivity(.latencyCritical + .userInteractive)`
- 主程序已有 IOPMAssertion，保留不动

### 回退机制
- 引擎子进程启动失败 → UI 自动退回本地模式（原完整闭环在主进程跑）
- 通过 flag `AURORA_ENGINE_FAILED=1` 切换

---

## 五、实施步骤（每步 = 改动 → 编译 → commit → 更新进度）

### 步骤 0：存档
```bash
cd /Users/dupi/Desktop/自动驾驶系统
git add -A && git commit -m "pre-split backup"
touch ENGINE_SPLIT_PROGRESS.md
echo "# AuroraDrive 引擎拆分进度" > ENGINE_SPLIT_PROGRESS.md
echo "- 最后更新：$(date '+%Y-%m-%d %H:%M')" >> ENGINE_SPLIT_PROGRESS.md
echo "- 当前步骤：0/5" >> ENGINE_SPLIT_PROGRESS.md
echo "- 上一步 commit：pre-split backup" >> ENGINE_SPLIT_PROGRESS.md
echo "- 阻塞项：无" >> ENGINE_SPLIT_PROGRESS.md
echo "- 下一步要做：TCC 继承实测（步骤 1）" >> ENGINE_SPLIT_PROGRESS.md
```

### 步骤 1：TCC 继承实测（最关键，决定后续可行性）

**新建文件**：`Sources/AuroraDrive/TCCSelfTest.swift`

```swift
import ApplicationServices
import CoreGraphics

public func runTCCSelftest() {
    let axOK = AXIsProcessTrusted()
    let screenOK = CGPreflightScreenCaptureAccess()
    let line = "ts=\(Int(Date().timeIntervalSince1970)) ax=\(axOK) screen=\(screenOK)"
    let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AuroraTCCSelfTest.log").path
    FileManager.default.createFile(atPath: logPath, contents: nil)
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write((line + "\n").data(using: .utf8)!)
        fh.closeFile()
    }
    print("[TCC-SELFTEST] \(line)")
    exit(axOK && screenOK ? 0 : 2)
}
```

**在主进程 applicationDidFinishLaunching 开头加 --engine 分支**（AuroraDriveApp.swift）：
```swift
// 引擎子进程自检：只打印结果，不启动 UI
if args.contains("--tcc-selftest") {
    runTCCSelftest()
}
```

**实测脚本**（在终端手动跑，或写个小工具）：
```bash
cd /Users/dupi/Desktop/自动驾驶系统
: > ~/Library/Logs/AuroraTCCSelfTest.log
./AuroraDriveUI --tcc-selftest; echo "exit=$?"
cat ~/Library/Logs/AuroraTCCSelfTest.log
```

**判定**：
- `ax=true` 且 `screen=true` → 下一步可行
- 任一 `false` → **工程暂停，汇报用户**

commit：`git commit -m "[split] 步骤1: TCC 继承实测"`

### 步骤 2：引擎子进程骨架

**新建文件**：`Sources/AuroraDrive/EngineMain.swift`

```swift
import Foundation
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import CoreML

// 不 import SwiftUI/AppKit

public func engineMain() {
    // 1. TCC 自检
    let axOK = AXIsProcessTrusted()
    let screenOK = CGPreflightScreenCaptureAccess()
    print("[ENGINE] TCC ax=\(axOK) screen=\(screenOK)")
    guard axOK && screenOK else {
        print("[ENGINE] TCC 权限不足，退出")
        exit(2)
    }
    
    // 2. 防冻结
    ProcessInfo.processInfo.beginActivity(
        options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled],
        reason: "AuroraDrive 后台驾驶引擎")
    
    // 3. 创建 socket 监听
    let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AuroraDrive/engine.sock").path
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
        withIntermediateDirectories: true)
    // socket 监听代码...
    
    // 4. 创建共享内存（首次）
    // shm_open, mmap 双缓冲...
    
    // 5. 实例化引擎组件
    let captureEngine = CaptureEngine()
    let yoloEngine = YoloEngine()
    let controlEngine = ControlEngine()
    let ruleController = RuleController()
    
    // 6. 连线 + 循环
    // ...
}
```

**在主进程 applicationDidFinishLaunching 加 spawn 逻辑**：
```swift
if args.contains("--engine") {
    engineMain()
    return
}
```

**编译测试**：
```bash
swift build -c release
cp .build/release/AuroraDrive AuroraDriveUI
codesign --force --sign - AuroraDriveUI
# 手动拉起引擎
./AuroraDriveUI --engine &
# 检查是否存活
ps aux | grep AuroraDriveUI | grep -v grep
```

commit：`git commit -m "[split] 步骤2: 引擎子进程骨架"`

### 步骤 3：UI 侧接线

**修改 AuroraDriveApp.swift 的 applicationDidFinishLaunching**：
```swift
// 尝试连接引擎 socket
let socketPath = "...engine.sock"
if FileManager.default.fileExists(atPath: socketPath) {
    // 引擎已存在，UI 连上去
    // 设置子进程模式标志
    setupEngineMode(socketPath: socketPath)
} else {
    // 引擎未启动，spawn
    spawnEngine()
}
```

**修改 ContentView**：
- 替换本地引擎实例为 socket 连接
- MTKView 的 draw 改为从共享内存读帧
- 开始/停止按钮绑定 socket 命令
- 显示引擎状态（帧率、连接状态）

commit：`git commit -m "[split] 步骤3: UI 侧接线"`

### 步骤 4：看门狗 + 心跳

**Socket 协议扩展**：
```json
// 心跳（引擎→UI，每秒）
{"type":"heartbeat","ts":1234567890}

// 状态（引擎→UI，每帧）
{"type":"status","fps":30,"detections":5}

// 命令（UI→引擎）
{"type":"start"}
{"type":"stop"}
{"type":"bye"}   // UI 主动关闭

// 紧急停车（UI→引擎）
{"type":"emergency_stop"}
```

**看门狗逻辑**：
- UI 收到 heartbeat → 刷新 lastHeartbeat
- UI 超 3 秒未收到 → 发 emergency_stop
- 引擎收到 bye → 安全退出
- 引擎收到 emergency_stop → releaseAll keys，置 isDriving=false

commit：`git commit -m "[split] 步骤4: 看门狗"`

### 步骤 5：清理与验收

**清理旧方案**：
```bash
launchctl bootout gui/501/com.aurora.drive.agent 2>/dev/null
rm ~/Library/LaunchAgents/com.aurora.drive.agent.plist
```

**验收测试清单**：
1. ✅ 引擎 TCC 自检 ax=true screen=true
2. ✅ UI 启动自动 spawn 引擎，engine.sock 出现
3. ✅ 画板显示引擎抓屏（≥30fps）
4. ✅ 点开始 → 引擎推理 + 按键
5. ✅ 关 UI → 引擎继续
6. ✅ kill -9 UI → 3 秒停车
7. ✅ 真机驾驶 10 分钟无掉帧/崩溃

commit：`git commit -m "[split] 步骤5: 清理与验收"`

---

## 六、编译固定流程

每次编译必须完整执行：
```bash
cd /Users/dupi/Desktop/自动驾驶系统
swift build -c release
cp .build/release/AuroraDrive AuroraDriveUI
codesign --force --sign - AuroraDriveUI
cp AuroraDriveUI AuroraDriveUI.app/Contents/MacOS/AuroraDriveUI
codesign --force --sign - AuroraDriveUI.app
```

⚠️ **替换前检查**：`ps aux | grep AuroraDriveUI`，在跑必须问用户

---

## 七、硬性约束

违反一条工程暂停：
- ❌ 屏幕上不得出现「演示」「测试」「声明」「调试」字样
- ❌ 画面必须 ≥30fps，检测框完整
- ❌ 换模型（YOLO→车道线+可行驶区域）时 UI 零改动
- ✅ 每步 commit，进度文件实时更新
- ✅ 动系统目录先告知

---

## 八、ENGINE_SPLIT_PROGRESS.md 模板

```markdown
# AuroraDrive 引擎拆分进度
- 最后更新：YYYY-MM-DD HH:MM
- 当前步骤：N/5
- 上一步 commit：<hash>
- 阻塞项：无 / <描述>
- 下一步要做：<具体任务>
```

**规则**：每次续做先读此文件，不得删除旧内容（留痕）。

---

## 九、关键注意事项

### 关于启动分流
- **不要改 main.swift**：当前是 `@main` 结构，改 main.swift = 破坏性大重构
- **正确做法**：在 applicationDidFinishLaunching 里检查 args，`--engine` 分支直接调用 engineMain()

### 关于 TCC 权限
- 子进程继承是 macOS 标准行为（responsible process）
- 实测是唯一可信的依据，理论推断不准
- 权限失败必须 fail-fast，不能静默降级

### 关于共享内存
- 帧大小 = CaptureEngine 原生分辨率（运行时获取）
- 双缓冲避免撕裂：引擎写 A 读 B，交换指针
- 信号量控制同步

### 关于 Socket
- 路径固定：`~/Library/Application Support/AuroraDrive/engine.sock`
- 协议简单：JSON 行，不要二进制
- 断连处理：UI 端用 poll + read 返回 0 判断 EOF

---

**文档版本**：v2（深度读源码后修正）
**最后更新**：2026-09-10
**作者**：AI Assistant for AuroraDrive Project
