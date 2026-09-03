# 四级 · App Nap 对抗机制

> 实现于 `AuroraDriveApp.swift` `AppDelegate.applicationDidFinishLaunching`
> 上级：[系统架构总览](../dev/01-architecture.md) ｜ English: [App Nap Countermeasures](en/app-nap.en.md)

## 1. 问题

macOS 对「看起来空闲」的窗口化 App 施加 App Nap：降 CPU 优先级、压缩定时器（`Timer` 从 30Hz 掉到 8Hz）。本项目常驻后台、窗口常被游戏全屏遮挡——正是最容易被「打盹」的场景，而驾驶决策链跑在定时器上，定时器掉帧 = 转向输出滞后。

## 2. 六重锁（applicationDidFinishLaunching）

### 锁 1：禁自动终止（`disableAutomaticTermination`）

禁用系统在内存压力下自动终止空闲 App 的行为。

### 锁 2：抑制 App Nap（`beginActivity`，:81-83）

```swift
ProcessInfo.processInfo.beginActivity(
    options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled],
    reason: "...")
```

返回 token 持有于 `napToken`——token 释放即失效，所以必须长持有。

### 锁 3：最高进程优先级（`setpriority`，:85）

```swift
setpriority(PRIO_PROCESS, 0, -20)   // nice=-20 用户态最高
```

### 锁 4：CGEventTap 实时保护（:92-108）

`.listenOnly` **空 tap** 挂 RunLoop：持有 HID 事件监听让系统判定「进程在实时处理输入」，不冻结。句柄持有于 `eventTap`。
> 区分：这个 tap 用于保活；`ControlEngine` 的注入（`.cghidEventTap` post）用于按键，是两个不同机制。

### 锁 5：768MB mlock 内存锚点（:110-127）

```swift
let allocSize = 768 * 1024 * 1024        // 196608 页
for i in 0..<pageCount {                 // 逐页写首字节
    buf.advanced(by: i*4096).storeBytes(of: UInt8(i & 0xFF), as: UInt8.self)
}
mlock(buf, allocSize)                    // 锁定物理 RAM
```

- **逐页写首字节必须做**：macOS 内存页惰性分配，不写的页不占物理内存，mlock 锁了个寂寞
- **为什么 768MB**：实测调出——macOS 的内存压力策略对「大内存 + mlock」进程极度保守，不敢冻结不敢换出；小进程说杀就杀。**不要改小**

### 锁 6：主线程实时约束（`applyMainThreadBoost`，:263-288）

`THREAD_TIME_CONSTRAINT_POLICY`，period≈33.3ms（30Hz）。由 `setGameModeBoost` 调用，`gameModeBoost` 默认 true。

## 3. 定时器选择（配套）

主循环 `DispatchSource.makeTimerSource`（`com.aurora.tick`，30Hz）而非 `Timer`：独立队列 + `userInteractive` QoS + `leeway: .nanoseconds(0)`（拒绝定时器合并）。

## 4. 验证方法

1. 启动 App、开始驾驶
2. 游戏切全屏盖住 App 窗口
3. 观察 `tickGapMs` 稳定 ~33ms 即未被 Nap
4. 对照实验：注释六重锁重编译，全屏下 tick 掉到 ~8Hz

## 5. 代价

| 代价 | 量级 | 评估 |
|---|---|---|
| 常驻物理内存 | 768MB+ | 16GB 机器可接受，换决策链永不冻结 |
| CPU 优先级挤占 | 极小（tick 轻量） | 游戏 GPU 是瓶颈，不受影响 |
| 电耗 | 略增 | 桌面场景可接受 |
