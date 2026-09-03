# 一、系统架构总览

> 覆盖源码：`AuroraDriveApp.swift`(3276) `DegradeStateMachine.swift`(250)
> 上级：[开发者文档](../DEVELOPER_GUIDE.md) ｜ English: [Architecture](en/01-architecture.en.md)

## 1.1 引擎清单（DriveState）

`DriveState` 是 `@Observable @MainActor final class`，引擎实例为普通 `let` 常量（`@ObservationIgnored` 只用于高频内部状态如 pendingFrame/healer）：

| 变量 | 引擎 | 模型/职责 |
|---|---|---|
| `captureEngine` | CaptureEngine | ScreenCaptureKit 30fps |
| `controlEngine` | ControlEngine | CGEvent 按键注入 |
| `keyboardMonitor` | KeyboardMonitor | 全局键盘监听 |
| `degradeStm` | DegradeStateMachine | 四档降级 |
| `recordEngine` | RecordEngine | 录屏（训练数据） |
| `escapeController` | EscapeController | 卡死脱困 |
| `ruleController` | RuleController | YOLO→规则控制量 |
| `confidenceEst` | ConfidenceEstimator | E2E 置信度估算 |
| `inferenceEngine` | InferenceEngine | m9_mono（档 1） |
| `assistEngine` | InferenceEngine("game_assist_control") | 档 2 |
| `yoloEngine` | YoloEngine | yolo26s |
| `speedOCR` | SpeedOCRReader | 速度 CNN |
| `healer` | NetworkHealer | 网络定位自愈（懒加载） |

## 1.2 线程模型

| 队列/线程 | QoS | 频率 | 职责 |
|---|---|---|---|
| 主线程 | — | 事件驱动 | SwiftUI 渲染、状态写回 |
| `com.aurora.tick` | userInteractive | **30Hz** | `state.tick()` 主循环（DispatchSource） |
| `com.aurora.netlocate` | userInteractive | **10Hz** | `runNetworkLocateStep()` |
| `com.aurora.coordinate-capture` | 默认 | 阻塞循环 | `pcap_next_ex` 抓包 |
| `com.aurora.inference` | userInitiated | ~24Hz | E2E/YOLO 推理（串行防重叠） |
| `com.aurora.confidence.brightness` | 后台 | 按需 | 亮度检测 |

**关键设计**：主循环用 `DispatchSource.makeTimerSource` 而非 `Timer`——`Timer` 挂 main RunLoop 会被 App Nap 压到 8Hz，DispatchSource 独立队列不受影响：

```swift
let timerQueue = DispatchQueue(label: "com.aurora.tick", qos: .userInteractive)
let timer = DispatchSource.makeTimerSource(queue: timerQueue)
timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .nanoseconds(0))
timer.setEventHandler { DispatchQueue.main.async { state.tick() } }
```

## 1.3 App Nap 六重对抗（applicationDidFinishLaunching）

| 锁 | 实现 |
|---|---|
| 1 禁自动终止 | `disableAutomaticTermination` |
| 2 抑制 App Nap | `beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])` → 持有 `napToken` |
| 3 最高优先级 | `setpriority(PRIO_PROCESS, 0, -20)` |
| 4 CGEventTap | `.listenOnly` 空 tap 挂 RunLoop → 系统判定进程在实时处理输入，不冻结 |
| 5 内存锚点 | 768MB 逐页写首字节 + `mlock`（惰性页不写不占物理内存），持有 `memoryAnchor` |
| 6 主线程实时约束 | `THREAD_TIME_CONSTRAINT_POLICY` period≈33.3ms（`applyMainThreadBoost`，`gameModeBoost` 默认 true） |

> 768MB 是实测经验值：macOS 对「大内存 + mlock」进程极度保守，不敢冻结/换出。**不要改小**。详见四级文档 [App Nap 对抗](../internals/app-nap.md)。

## 1.4 BPF 权限自动安装

启动时 `access("/dev/bpf0", O_RDWR)` 检测；不可用且未装 LaunchDaemon → `showBPFPasswordSheet = true` 弹 App 内密码窗。输入密码后 `BPFSetupManager.install()` 经 osascript 以管理员权限部署 `/usr/local/bin/aurora-bpf-setup.sh`（`chmod 666 /dev/bpf*`）+ `/Library/LaunchDaemons/com.aurora.bpf-setup.plist`（RunAtLoad）——一次输入，每次开机自动恢复。详见四级文档。

## 1.5 四档降级状态机

**DriveMode**：`e2e` 端到端主驾 / `yolo` YOLO接管 / `recover` 脱困中 / `rule` 纯规则兜底。
**DriveModeGroup** 把 4 档归并为用户可见 2 档：`e2eDrive`（[e2e, yolo]）、`ruleFallback`（[recover, rule]）。

**核心阈值**：降级线 0.65、恢复线 0.80（滞回 0.15，防阈值边缘横跳）、卡住判定 3.0 km/h 持续 3.0s、脱困超时 30s。

**优先级**：`forceRule`（一键规则）> `sportMode`（强制 e2e，不进脱困）> `warmingUp` > 卡住检测 > 健康梯子。

```
e2e  --(!m9Live || health<0.65)-->  yolo
yolo --(!assistLive || health<0.65)-->  rule
yolo --(m9Live && health>0.80)-->  e2e
rule --(assistLive && health>0.80)-->  yolo
*    --(stuckSeconds≥3.0)-->  recover
recover --(speedValid && speed>6.0)-->  e2e   |   --(超30s)-->  rule
```

**stuckSeconds 细节**：`speedValid=false`（速度读不到）时冻结不累计不清零；低速按真实时间差累加；车动按 2× 衰减 0.5s 清零（防抖）。

> ⚠️ 注释与代码不一致：网络定位定时器注释写"4Hz"但代码是 10Hz，以代码为准。

## 1.6 生命周期

- `startDriving()`：权限检查（失败弹辅助功能设置）→ `releaseAll()` 防卡键 → `isDriving=true` → keyboardMonitor.start → captureEngine.start → 三模型 `loadIfNeeded()`
- `stopDriving()`：`releaseAll()` → 停推理
- `--auto-drive` CLI：无人值守端到端自测
- 定位旁路：`runNetworkLocateStep()`（10Hz）只服务地图显示——**驾驶决策吃画面不吃地图坐标**，定位挂了不影响开车
