# 代码-24 AuroraDriveApp 入口与 AppDelegate

> ✅ **2026-10-18 行号重基准（9097 行版，源码已冻结）**：逐条 `sed -n 'Np'` 查现状 + 语义比对（未用统一 +N 平移——实测偏移分段不同：前部 0、尾部 +2~+3）。
> 本轮修正 8 处：`lastDecided` 两处先比后写 `:7559/:7619`→**:7560/:7621**；悬空引用注释 `:7587`→**:7589**（其内引用的 `:4740`→**:5118**，实测 `lastDecided` 声明仍在 `:5116`）；尾部对象族 `:8128/:8229/:8449/:8594/:8688/:8714/:8730/:8899/:8956`→**:8130/:8231/:8451/:8596/:8690/:8716/:8732/:8901/:8958**（+2）；跨文件 `MissionConsole.swift:6886`→**:6891**；`EngineMain.swift:1957-1969`→**:1970 起**。
> 未修正（已核实准确）：头部 20 条锚点 + 46 条 CLI 分支 + 全部区间端点 **逐条命中**。

> 覆盖源文件：`Sources/AuroraDrive/App/AuroraDriveApp.swift`（**9097 行**，2026-10-18 `wc -l` 实测，源码已冻结）之上部：AppDelegate + Launcher + App Scene + WindowConfigurator + DragHandleView。中部 DriveState 见 [代码-25](代码-25-DriveState状态主体.md)；下部 BPF 弹窗/FrameHost 见本文第九节。
>
> ✅ **2026-10-17 复核（T7）**：全文行号按当前 9088 行版逐条 `grep -n` / `awk NR` 实测修正（正文数字全部为实测值）；历史遗留的补丁式阅读提示**已全部移除**——行号已修对，不再需要任何替代阅读方式。
>
> ✅ **2026-10-18 复核（merge-map）**：源文件由 9088→9094 行（lead 改动：DriveMode 注释 "4 档"→"3 档"、QUEST_OCR 默认开/关修正、tick 20Hz 定档、lastDecided 两处 30Hz→20Hz）。本次逐条 `sed -n` 核对：锚点表 DriveMode/DriveModeGroup/RecordLabelMapper 行号漂移 +2（注释行增加），§5 引文与注释措辞已同步更新；oneShotFlags 实测 50 项不变；route-selftest / quest-selftest 冻结基线行号不变。

> ### ✅ 2026-10-18 实测锚点表（**当前 9097 行版**，优先用此表定位）
>
> | 单元 | 当前行号 | 说明 |
> |---|---|---|
> | `final class AppDelegate` | **:27–556** | 类体；`deinit` :546-555 |
> | `installGameModeAnchorWindow()` | **:67–98** | 1×1 锚定窗口 |
> | `applicationDidFinishLaunching` | **:133–537** | 启动分流九步 |
> | `applicationWillTerminate` | **:542–544** | `sendByeSync()` |
> | `runUpscaleSelfTest()` | **:563–645** | `--upscale-selftest` |
> | `SelfTestResult` / `SelfTestImage` | **:647–655 / :657–670** | 结果落盘 / 合成图 |
> | `applyMainThreadBoost(_:)` | **:677–702** | THREAD_TIME_CONSTRAINT_POLICY |
> | `@main struct AuroraDriveLauncher` | **:722–1360** | `acquireUISingleInstanceLock` :730-746、`main()` :748-1359 |
> | `oneShotFlags` 数组 | **:919–970** | **实测 50 项**（逐元素解析计数） |
> | UI 锁判定 `isOneShot` | **:1301–1307** | 锁失败 → exit(0) |
> | 窗口状态恢复禁用（defaults register） | **:1351–1356** | 在 `AuroraDriveApp.main()` **:1358** 之前 |
> | `struct AuroraDriveApp: App` | **:1362–1431** | `body` :1365-1430 |
> | `runTaxonomySelfTest()` | **:1894–2098** | `--taxonomy-selftest` |
> | `runRouteSelfTest()` | **:2100–2298** | `--route-selftest` |
> | `runEgoBoxSelfTest()` | **:2406** | `--egobox-selftest` |
> | `struct WindowConfigurator` | **:3810** | 主窗口铺满 |
> | `final class DragHandleView` | **:3966** | 顶栏拖拽带（`interactiveRightInset` :3975） |
> | `enum DriveMode` | **:4047–4076** | 3 个 case；`.recover` 2026-09-30 已删（:4053-4055） |
> | `enum DriveModeGroup` | **:4082–4113** | `members` :4089、`contains` :4097、`desc` :4100、`icon` :4107 |
> | `enum RecordLabelMapper` | **:4121–4146** | 专家模式录制标签换算器 |
> | `final class DriveState` | **:4150** | 见 代码-25 |
>
> 头部注释引用的源码锚点（全部实测）：`--daemon`/`AURORA_DAEMON_MODE` 判定 **:137-138**、
> `--test-xpc` **:147**、`--tcc-selftest` **:156-171**（追加写 `~/Library/Logs/AuroraTCCSelfTest.log`，
> `exit((axOK && screenOK) ? 0 : 2)`，:170）、`--yolo-selftest` **:175**、`--yolo-bench` **:182**、
> `--speed-selftest` **:191**、`if !isDaemon { EngineClient.shared.startup() }` **:208-210**（daemon 跳过，:137-143）、
> `--auto-login` 派发 **:505-510**、`--agent-command` 派发 **:516-522**、命令模式引擎注入 **:529-536**。
> Launcher 侧：`setvbuf` **:751**、`--engine` 分流 **:822-824**、`--set-llm-config` **:826-841**、
> `--agent-llm-test` **:843-916**（`request.timeoutInterval = 30` **:870**，semaphore 等待 35s **:895**）。
>
> 各 CLI 分支行号（Launcher `main()` 内，全部实测）：`--mc-map` **:758**、`--mc-map-offline` **:763**、
> `--mc-route` **:770**、`--mc-route-loading` **:775**、`--mc-map-bench` **:782**、`--mc-shot` **:792**、
> `--mc-quest` **:810**、`--lanekeep-reality` **:979**、`--wire-selftest` **:990**、
> `--flags-help` **:998**、`--cache-selftest` **:1005**、`--quest-selftest` **:1014-1017**、
> `--capture-selftest` **:1023**、`--llm-selftest` **:1053**、`--llm-probe` **:1061**、
> `--llm-vision-selftest` **:1068**、`--control-selftest` **:1075**、`--tool-selftest` **:1082**、
> `--tool-call-demo` **:1089**、`--v2-selftest` **:1101**、`--llm-perf-selftest` **:1108**、
> `--websearch-selftest` **:1124**、`--perf-selftest` **:1130-1137**、`--tick-profile` **:1144-1150**、
> `--tick-bench` **:1157-1163**、`--realshot-selftest` **:1169-1180**、`--corner-selftest` **:1185-1188**、
> `--egobox-selftest` **:1192-1195**、`--perception-selftest` **:1199-1202**、
> `--lanekeep-selftest` **:1207-1210**、`--ayolom-selftest` **:1215-1218**、
> `--yolopx-selftest` **:1221-1228**、`--proto-selftest` **:1232-1235**、`--nic-autotest` **:1237-1240**、
> `--limit-selftest` **:1243-1246**、`--opticalflow-selftest` **:1249-1251**、
> `--motion-selftest` **:1254-1256**、`--fit-selftest` **:1260-1263**、`--route-selftest` **:1268-1270**、
> `--taxonomy-selftest` **:1274-1276**、`--map-selftest` **:1281-1283**、
> `--lane-extrapolator-selftest` **:1287-1291**、`--map-window-test` **:1297-1299**。

**oneShotFlags 实测 50 项（2026-10-17 逐元素解析）**：
`--speed-selftest`、`--tcc-selftest`、`--test-xpc`、`--yolo-selftest`、`--upscale-selftest`、`--yolo-bench`、
`--daemon`、`--mc-shot`、`--mc-map`、`--mc-map-offline`、`--fit-selftest`、`--limit-selftest`、
`--nic-autotest`、`--proto-selftest`、`--yolopx-selftest`、`--opticalflow-selftest`、`--motion-selftest`、
`--corner-selftest`、`--perf-selftest`、`--tick-profile`、`--tick-bench`、`--realshot-selftest`、
`--egobox-selftest`、`--ayolom-selftest`、`--lanekeep-selftest`、`--perception-selftest`、
`--wire-selftest`、`--lanekeep-reality`、`--route-selftest`、`--taxonomy-selftest`、`--mc-route`、
`--mc-route-loading`、`--mc-map-bench`、`--flags-help`、`--cache-selftest`、`--quest-selftest`、
`--mc-quest`、`--llm-selftest`、`--llm-probe`、`--llm-vision-selftest`、`--control-selftest`、
`--tool-selftest`、`--tool-call-demo`、`--llm-perf-selftest`、`--websearch-selftest`、`--v2-selftest`、
`--agent-selftest`、`--map-selftest`、`--lane-extrapolator-selftest`、`--capture-selftest`。
> 源码两处用 ⚠️ 强调数组是**手写维护**，漏登记会被 UI 单实例锁挡掉（:932-934、:936-940）。

## 一、AppDelegate 与 Game Mode 锚定窗口（:27–98）

**文件头（:4-8）**：AuroraDrive——异环游戏自动开车辅助工具；**SwiftUI macOS 14+ | 单窗口 1200x760 | Tesla FSD 驾驶舱风格；纯黑底 + 青色(#00E5FF)发光 + 高对比白字**。

**AppDelegate（final class，:27 起）**——应用启动时**强制激活窗口到前台**（直接 swift 运行时窗口默认不激活）。

**静态/成员状态（:28–48）：**

| 成员 | 说明 |
|---|---|
| `static var agentEngines: (control: ControlEngine, capture: CaptureEngine)?` | **命令模式（--agent-command）独立引擎组：静态持有，防 Arc 释放导致 SCK 流停摆** |
| `napToken: NSObjectProtocol?` | 抑制 App Nap 的 activity token（**必须持有，否则 activity 立即释放、抑制失效**） |
| `eventTap: CFMachPort?` | CGEventTap 句柄（持有防止释放，系统级实时保护） |
| `memoryAnchor: UnsafeMutableRawPointer?` | 防冻结内存锚点（持有防止释放；**默认关闭**，见 `freezeGuardBytes` :44） |
| `powerAssertionID: IOPMAssertionID` | IOPMAssertion ID（防止系统 Power Management 判定进程空闲并冻结，Game Mode 最强对抗） |
| `gameModeAnchorWindow: NSWindow?` | Game Mode 对抗锚定窗口（1×1 浮层） |

**`installGameModeAnchorWindow()`（private，:67–98）——Game Mode 对抗：安装 1×1「锚定窗口」：**

- **原理（:50-55 注释）**：Game Mode 由 gamepolicyd 管理，它系统性地压制**后台任务**（Apple 原话：lowering usage for background tasks / background threads being suppressed）。macOS 判定"后台"的常见依据是「无可见窗口 + 无用户交互」——**这里挂一个技术上可见、视觉上无感的窗口，试图让本进程不被归入纯后台桶**
- **关键设计（:57-62）**：`fullScreenAuxiliary`——**能随游戏全屏 Space 一起显示**（否则游戏全屏后本窗口被移出该 Space，等于不存在）；1×1 px + 近乎透明 + `ignoresMouseEvents`——视觉与交互零干扰；`.floating` 层级——保证不被游戏窗口完全遮蔽；**屏幕右下角**——即使有 1px 痕迹也在最不显眼处
- 窗口属性（:73-84）：isOpaque=false、**`backgroundColor = NSColor.black.withAlphaComponent(0.02)`——非零 alpha：完全透明的窗口可能被系统直接判定为"无可见内容"**、hasShadow=false、ignoresMouseEvents=true（绝不拦截点击）、isMovable=false、level=.floating、collectionBehavior=[.canJoinAllSpaces, .stationary, .ignoresCycle, **.fullScreenAuxiliary**]
- **位置（:85-90）**：**用 CGDisplayBounds 计算：NSScreen.main 在「app 未激活 / 从 shell 启动」时会返回异常值（实测 maxX=0 → 窗口跑到屏幕外），CGDisplay 不受激活状态影响**——`screenBounds.maxX - 4 / maxY - 4`（右下角内缩：在屏内 + 避开 Dock）
- `orderFrontRegardless()` + gameModeAnchorWindow = w（:91-92）+ **诊断落盘 `/tmp/aurora_anchor_diag.log`**（:93-95，"stdout 重定向到文件时是块缓冲，print 可能不落盘"）+ `fflush(stdout)` + print（:96-97）

**诚实标注（:64-66 注释）**：此对抗是否被 gamepolicyd 认可**没有公开证据**，属于工程尝试；配合已有的 beginActivity(.latencyCritical) / CGEventTap / IOPMAssertion 共同构成多层防护。**若实测无效，可调 alphaValue / 尺寸 / level 再试**。

## 二、applicationDidFinishLaunching 启动分流（:133–537）

**方法体按启动路径分流——先 CLI 自检、再引擎探测、再防冻结、再命令模式：**

**① CLI 自检与诊断入口（:136–203）：**

| 参数 | 行为 |
|---|---|
| `--daemon`（或 AURORA_DAEMON_MODE=1）（:136-143） | Daemon 模式：`NSApp.setActivationPolicy(.accessory)`（不激活窗口、不显示 Dock 图标，纯后台运行）——**历史入口保留** |
| `--test-xpc`（:145-150） | **用户会话 XPC Agent 方案已废弃**——"launchd 拉起的进程拿不到 TCC 权限，引擎改由主程序 spawn 子进程承担"；打印提示 + `exit(0)` |
| `--tcc-selftest`（:152-171） | **TCC 权限继承验证**：`AXIsProcessTrusted()`（**不带 prompt = 纯查询，零弹窗**）+ `CGPreflightScreenCaptureAccess()`（纯查询）→ 结果追加写 `~/Library/Logs/AuroraTCCSelfTest.log` → `exit((axOK && screenOK) ? 0 : 2)`（:170）。"launchd 以「与 UI 完全相同的可执行文件路径+签名」拉起本进程，因此这里的预检结果 = 未来 --engine 模式的真实权限状态" |
| `--yolo-selftest <图片>`（:175-179） | `YoloEngine().selfTest(imagePath:)` + `exit(0)` |
| `--yolo-bench <图片>`（:180-186） | `YoloEngine().benchmark(imagePath:)`（对比直通 vs 慢路径）+ `exit(0)` |
| `--speed-selftest <目录> [--roi x,y,w,h]`（:187-203） | `SpeedOCRReader().selfTestDirectory(...)`（--roi 解析 4 个 Double → CGRect，目录是 ROI 切片帧时传归一化位置）+ `exit(0)` |

**② 引擎模式探测（:205-210）**：`if !isDaemon { EngineClient.shared.startup() }`——**探测 engine.sock：已有健康引擎 → 直接连接；没有 → spawn 自己（--engine）。任一步失败自动回退本地模式（全部本地逻辑保持原样）**。

**③ 防 App Nap + 优先级（:212–228）：**

- `disableAutomaticTermination("AuroraDrive 实时游戏辅助：持续截屏 + AI 决策注入")`（:218-219）——只防"被系统自动退出"，不管节流
- **`beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])`（:220-222）**——源注释（:212-217）："App 在游戏前台全屏时沦为后台 App，系统默认会对它的 RunLoop 定时器/渲染做 **App Nap 节流（Timer 掉帧、界面卡）——这正是"只有 App 界面卡"的根因**。.latencyCritical 声明对延迟敏感 → 系统不再对其节流，后台保持前台级节奏。token 必须持有（napToken）"
- `setpriority(PRIO_PROCESS, 0, -20)`（:224-226）——**最高进程优先级 nice=-20（用户进程极限）**
- `GameModeDefender.shared.start()`（:228）——**Game Mode 对抗（持久战）：静音音频 + 每 3s 重新主张 nice/activity/音频**
- **HUD 承担"可见窗口"职责（:229-233 注释）**：由 DriveState 的 GameHUDWindow（左上角绿色帧率 HUD）承担——它比 1×1 隐形锚点更可能被 gamepolicyd 认作"有可见窗口的应用"，且同时提供实用信息；**锚定窗口方案保留在方法中，默认不再调用**

**④ CGEventTap 空监听（:236–287）：**

- **`CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: keyDown, callback: { return Unmanaged.passUnretained(event) })`（:269-276）**——源注释（:236-238）："**系统必须保持有 event tap 的进程响应，否则事件丢弃——这是强制系统不冻结本进程的最有效手段（Game Mode 也挡不住）**。只监听键盘事件，**不监听鼠标移动（避免鼠标被强制移到左上角）**"
- **权限缺失不再致命（:241-268 注释）**：改前是 `guard let ... else { return }`，辅助功能未授权会让**整个函数后续代码静默跳过**（含 --auto-login / --agent-command / 引擎构造）；现改为不阻断——权限缺失只跳过 event tap 段并如实记录（:282-287），其余初始化照常
- `tapEnable(enable: true)` + CFRunLoopAddSource(.commonModes) + `self.eventTap = eventTap`（:278-281，持有防释放）

**⑤ 防冻结内存锚（:289–321）**：**默认关闭**（`freezeGuardBytes = 0`，:37-44 注释记录 2026-09-23 实测：旧实现无条件 mlock 768MB → 主进程 RSS 825MB、swap 顶到 11.8GB/12.3GB → 游戏卡顿）。需要极限防冻结时才手动开：`UnsafeMutableRawPointer.allocate` → 逐页写首字节（:309-312）→ `mlock`（:313-317）→ `self.memoryAnchor = buf`（:318）；关闭时打印说明（:320）。

**⑥ 命令模式与 IOPMAssertion（:323–352）：**

- `NSApp.setActivationPolicy(isCommandMode ? .accessory : .regular)`（:325-326）——**.accessory 下进程不占 Dock、不触发 Space 切换（保持游戏所在 Space 激活，供键注入落到游戏内）**；非命令模式才 `NSApp.activate(ignoringOtherApps: true)`（:327-329）
- **`IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, On, "AuroraDrive Real-time Game Assistant")`（:335-340）**——"**对抗 Game Mode 冻结后台进程的官方 API，比任何 hack 都稳定**"；成功/失败都写 `/tmp/aurora_iopm_status.log`（:341-351，"SwiftUI App 不输出到终端"）

**⑦ Darwin Notification Center（:354–395）**：`CFNotificationCenterGetDarwinNotifyCenter()`（:357）+ 三个 observer（`com.apple.system.powermanagement`（系统睡眠/唤醒）:360-369、`com.apple.system.displays.reconfiguration`（**全屏切换时触发**）:372-381、`com.apple.system.clock_set`（系统时间变化）:384-393）——"**系统不会冻结正在监听系统通知的进程**"，回调只 print。

**⑧ 窗口激活与自动登录/命令派发（:397–522）：**

- **关掉 AppKit 窗口状态恢复（:397-403）**：`UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])`（:402）+ `NSWindow.allowsAutomaticWindowTabbing = false`（:403）——根治「绕一圈黑边」（系统持久化了一堆只剩标题栏高的空壳窗口）
- **延迟激活（:405–477）**：**SwiftUI WindowGroup 的窗口在 applicationDidFinishLaunching 之后、runloop 下一轮才创建（此时同步遍历 NSApp.windows 常为空，激活无效）。延迟到下一 runloop 再激活**——`DispatchQueue.main.async { NSApp.activate + 只前置主窗口 + orderFrontRegardless }`（:411-452）；**命令模式不激活**（:409-410）；清理退化窗口（:419-434）+ 屏幕约束（:446）+ 延迟诊断（:456-475）
- **`--auto-login`（:498-510）**：**放在 applicationDidFinishLaunching 而非 ContentView.onAppear：登录守护与 UI 渲染解耦——引擎/权限环境异常导致窗口创建延迟或失败时，守护照样启动，不会"卡死在等窗口"**。守护内部已有安全护栏：① 只有检测到游戏窗口（异环/NTE）才允许点击，绝不误点其他窗口；② 每 8s 一次、最多 10 次（80s 超时自动停止）；③ 游戏未开/已登录时安静等待或退出，无副作用。`asyncAfter(1.5)` → `AgentSkillCenter.shared.requestAutoLoginOnStartup()`（:507-509）
- **`--agent-command "<指令>"`（:512-522）**：**与 --auto-login 同理放在 AppDelegate：命令模式（.accessory）下窗口可能被 orderOut、视图 onAppear 不触发，派发必须与视图渲染解耦**。AgentSkillCenter 内部排队，引擎注入（configure）时补发，8s 兜底。`asyncAfter(1.5)` → `requestCommandOnStartup(cmd)`（:519-521）

**⑨ 命令模式引擎注入（:524–536）**：`--agent-command` 时——**由 AppDelegate 独立创建一组引擎并注入（不走 DriveState，避免其 init 副作用：删 /tmp/aurora_debug.log + 装第二套 HUD）**；`AppDelegate.agentEngines = (ctl, cap)`（**静态持有防释放**，:532）+ `configure(control:capture:)`（:533）+ `cap.start()`（本地 SCK 全屏流，屏幕录制 TCC，:534）；"视图若随后渲染也会 configure 一次（DriveState 引擎），后注入者生效，二者等价"（:528）。

**`applicationWillTerminate`（:542–544）**：`EngineClient.shared.sendByeSync()`——**正常退出前通知后台引擎「我走了，继续跑」：引擎收到 bye 后释放按键但保持抓屏推理，等待下次 UI 重连，且不会把这次断开当作崩溃来处理（不触发看门狗停车）**。

**`deinit`（:546–555）**：gameModeAnchorWindow orderOut + nil（:549-550）、`IOPMAssertionRelease(powerAssertionID)`（:551-554，进程退出时自动调用）。

## 三、upscale 自检 / 主线程优先级提升 / @main Launcher（:559–1360）

**`runUpscaleSelfTest()`（:563–645）——插帧引擎自检（`--upscale-selftest`）**：

1. `GooseUpscaler.make()` 为 nil → FAIL exit(1)（:564-567）→ `configureInterpolation()`（:569-570）
2. **测试窗口挂载（:572-587）**：MTKView（320×180）+ NSWindow（borderless、floating、位置 NSScreen.main.visibleFrame 中上）→ `upscaler.attachToView(view, displayRefreshRate: 60, minRefreshRate: 30)`（:584）→ makeKeyAndOrderFront——打印 view/drawable 尺寸（:587）
3. **喂帧定时器（:594-610）**：0.5s 后——feedTimer 0.10s 间隔（`SelfTestImage.make(640×360, frame: 计数)` 合成图 → `upscaler.ingest(cgImage:)` → 手动驱动 draw）+ drawTick 0.050s（纯驱动 draw）——两个 Timer 都 RunLoop.main .common
4. **8 秒后判定（:612-644）**：`statsSnapshot()` 前后对比——`rendered = outputFrameCount 增加`、`interpolated = interpolatedFrameCount 增加`：
   - **双真 → PASS**（"插帧工作 out A→B interp C→D fps N"）+ `SelfTestResult.write` + `exit(0)`（:627-631）
   - rendered 但未插帧 → **FAIL"渲染出帧但未插帧(纯透传)"** + exit(1)（:632-636）
   - 无输出 → FAIL"渲染路径无输出 MTKView未渲染出帧" + exit(1)（:637-642）
   - `pendingError()` 非空 → ENGINE-ERR 附加进结果文件（:620-623）

**`SelfTestResult`（private enum，:647–655）**：结果写 `/tmp/upselftest_result.txt`——`[UPSELFTEST] verdict [ENGINE-ERR=...]`。

**`SelfTestImage.make(width:height:frame:)`（private enum，:657–670）**：合成测试图——蓝底（0.15/0.55/0.95）+ **橙色方块随 frame 位移（`frame % 8 × 60`，120×80 @y=120）**（:666-667）——给插帧引擎一个"会动的画面"（静止画面插帧无从插）。premultipliedLast | byteOrder32Big（RGBA）。

**`applyMainThreadBoost(_ enabled: Bool)`（:677–702）——主线程优先级提升（对抗全屏游戏时的线程降权）**：

- enabled：`mach_thread_self()`（:678）→ `thread_time_constraint_policy_data_t(period: 33_333_333ns≈30Hz, computation: 6ms, constraint: 15ms, preemptible: 1)`（:686-690）——**时间约束调度（THREAD_TIME_CONSTRAINT_POLICY）**：系统保证主线程每 33ms 至少跑 6ms（15ms 约束内）；`units(_ ns:)` 用 mach_timebase 换算（denom/numer 防御，:680-685）
- 关闭：`thread_policy_set(THREAD_STANDARD_POLICY)`（:698-701）——恢复标准调度

**`@main AuroraDriveLauncher`（:722–1360）——进程入口分流**：

- **为什么移到 Launcher（:717-720 注释）**："`--engine` 走纯后台引擎（EngineMain，不触碰 SwiftUI、不创建窗口、不跑 NSApp），否则照常启动 SwiftUI 界面。**@main 从 App 结构移到本 Launcher 仅为拿到最早的进程入口，SwiftUI 的 App/Scene/AppDelegate 结构完全保持原样**"

**UI 单实例锁（:723–746）**：

- `uiLockFD`（nonisolated(unsafe) static，:724）——fd 持有到进程退出，内核自动释放
- **背景（2026-09-12 实测，:726-729 注释）**：两个 UI 实例会互抢同一个引擎 socket——**引擎只服务一个客户端，双方轮流被踢 → 各自「断开→重连」0.5 秒死循环刷屏**。引擎侧早有 engine.lock，**UI 侧此前缺失，这里补齐**
- `acquireUISingleInstanceLock() -> Bool`（:730-746）：建 `ui.lock`（Application Support/AuroraDrive/，0o600，:731-735）→ `flock(LOCK_EX | LOCK_NB)`（:737）→ 持有 + 写 pid（:738-742）；**锁文件不可建时放行（不阻碍正常使用）**（:736）；flock 失败 → close + false（:744-745）

**`main()`（:748–1359）——顶层分流：**

1. **`setvbuf(stdout, nil, _IOLBF, 0)`（:751）**——**stdout 改行缓冲：print 立即落盘（重定向到文件/管道时不再等到进程退出才 flush——否则 crash/卡死时日志全丢，无法定位）**（注释 :749-750）
2. **`--mc-*` 离屏出图夹具（:754-820）**：`--mc-map` :758 / `--mc-map-offline` :763 / `--mc-route` :770 / `--mc-route-loading` :775 / `--mc-map-bench` :782 / `--mc-shot` :792 / `--mc-quest` :810。**必须在这里同步跑完**（注释 :754-757：截图是纯离屏 ImageRenderer 渲染，放 onAppear 里无窗口永不触发 → 实测 240s 不出图）
3. **`--engine`（:822-824）**：`EngineMain.run()`——**永不返回**（dispatchMain 常驻；自身已有 engine.lock）
4. **`--set-llm-config <apiKey> <baseUrl> <model>`（:826-841）**：**提前处理（不需要 GUI/引擎）**——AgentSettings.save()（本地小本本 + 固定域 UserDefaults，不碰钥匙串）→ 打印保存结果（key 打码，:835）→ exit
5. **`--agent-llm-test`（:843-916）**：**真实 LLM 请求自测（不需要 GUI）**——**纯同步 URLSession + 30s 硬超时（不依赖 Swift concurrency / Keychain 解锁）**（:843-845）：
   - 非阻塞读取配置：UserDefaults 读 baseUrl/model，**Key 从环境变量 AURORA_API_KEY（CLI 场景）**（:846-857）
   - 组请求（POST chat/completions，messages 只有 1 条 user "用一句话回答：1+1等于几？"，max_tokens 100）→ `dataTask + semaphore`（**semaphore 35s 超时**，task.cancel，:881-899）→ 200...299 校验（:901-904）→ 解析 content 打印 → exit(0)
6. **一次性自检不参与 UI 锁（:919-970 + :1301-1307）**：`oneShotFlags`（**实测 50 项**）——"**它们是短命进程或被 launchd 托管，若参与锁会与常驻 UI 互斥，导致自检失败或用户无法启动界面**"（:917-918）；非 oneShot 且锁失败 → 打印原因（"两个 UI 会互抢引擎 socket（0.5s 断开重连死循环）"）+ exit(0)（:1302-1307）
7. **窗口状态恢复禁用（:1351-1356）**：`UserDefaults.standard.register`（`NSQuitAlwaysKeepsWindows` / `ApplePersistenceIgnoreState`）——必须在 NSApplication 处理 Apple Event **之前**设置（注释 :1309-1350）
8. `AuroraDriveApp.main()`（:1358）——正常启动 SwiftUI

## 四、AuroraDriveApp Scene（:1362–1431）

**`AuroraDriveApp`（struct: App，:1362–1431）**：

- `@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate`（:1363）——挂 AppDelegate
- **body（WindowGroup，:1365-1430）**：`ContentView()` + `.frame(minWidth: 880, minHeight: 500)`（:1369-1370）+ `.background(WindowConfigurator())`（:1373）+ `.background(Color.black)` + `.onAppear`（:1375-）：
  - `isCommandMode` 判定（:1377）→ **命令模式：全部窗口 `orderOut(nil)`（后台运行、不抢焦点、不前置窗口——保持游戏所在 Space 激活，供键注入落到游戏内）** + return（:1379-1384）
  - 正常模式：`NSApp.activate` + 只前置主窗口 + orderFrontRegardless（:1385-1391）+ **标题栏 chrome 全部隐藏**——"全屏游戏时标题栏（含红黄绿按钮/标题条）会浮在游戏画面上遮挡一条，这里把标题栏 chrome 全部隐藏"：`titlebarAppearsTransparent = true` + `titleVisibility = .hidden` + 三个 standardWindowButton（close/miniaturize/zoom）isHidden（:1392-1398）
  - **⚠️ 踩坑记录（:1399-1401 注释）**："**绝不要开 isMovableByWindowBackground——那会让「在画面上拖拽」变成「拖动整个窗口」，把框选手势整个吃掉（实测踩过）**。拖窗口请拖窗口顶部那条隐形标题栏区域"
- **地图窗口 ⌘M（:1403-1429）**：**默认绝对不自动开**（用户原话「我从来没要求给我打开App自动打开地图」）；用 ⌘M 开关独立地图窗口（`.commands { CommandGroup(after: .windowList) { Button("地图窗口") } }`）

**关于 `Theme` / `GlowCard` / `SectionHeader`（旧文档记录的对象）**：

> ⚠️ 这三个符号在 `Sources/` 中**已 grep 不到**（`grep -rn "Theme\b" App/AuroraDriveApp.swift` 无命中）。
> UI 大改版后主题已改为 **`App/AuroraTheme.swift` 的 `Aurora`**（enum，:32），令牌整套换名换值。
> 现役令牌请查 [代码-28](代码-28-GameHUDWindow与AuroraTheme.md)（记录的是**新版** `Aurora` 令牌，准确）。
>
> **新旧令牌对照**（便于读旧文档时转换）：
>
> | 用途 | 旧（`Theme`） | **新（`Aurora`）** |
> |---|---|---|
> | 底色 | `bgPure` = 黑 | **`void`** = `0x03060B` |
> | 卡片底 | `bgCard` = 白 0.045 | **`glassFill`** = `0x0B1422` @0.72 |
> | 卡片描边 | `bgCardEdge` = 白 0.08 | **`hair2`** = `0x8CBEFF` @0.17 |
> | 主强调 | `cyan` = `#00E5FF` | **`ice`** = `0x4CC9FF` |
> | 强调暗 | `cyanDim` = cyan×0.55 | **`iceLo`** = `0x4CC9FF` @0.34 |
> | 极速/警示 | `orangeRed` = (1,0.36,0.22) | **`amber`** = `0xFFB648` |
> | 危险 | `danger` = (1,0.24,0.28) | **`danger`** = `0xFF5468`（值也变了） |
> | 正文 | `textPrimary` = 白 | **`t1`** = `0xE9F3FF` |
> | 次级文字 | `textSecondary` = 白 0.62 | **`t2`** = `0xE9F3FF` @0.62（同比例，**色相改为米白**） |
>
> **新版完整令牌仓**（`AuroraTheme.swift`）：底色 `void`/`s0`~`s4`；玻璃 `glass`/`glassFill`/`glassFill2`/`glassSolid`；
> 发丝线 `hair1`~`hair4`（`0x8CBEFF` @ 0.10/0.17/0.28/0.42）；主强调 `ice`/`iceLo`/`iceHi`/`iceGlow`/`iceWash`；
> 语义 `ok`/`okLo`/`amber`/`danger`/`violet`；文字 `t1`~`t4`/`muted`；圆角 `r1`=8/`r2`=12/`r3`=15/`r4`=20。
>
> **下文旧 `Theme` 表格保留作历史参考**（理解大改版前的配色思路，**对应源码已不存在**）：

| 组 | 常量 | 值 |
|---|---|---|
| 背景 | `bgPure` / `bgCard` / `bgCardEdge` | `Color.black` / 白 0.045 / 白 0.08 |
| 主色/强调 | `cyan` / `cyanDim` / `orangeRed` / `danger` | **#00E5FF**（0,0.898,1.0）/ 同×0.55 /（1,0.36,0.22）**极速模式** /（1,0.24,0.28）**障碍红** |
| 文字 | `textPrimary / textSecondary / textTertiary` | 白 / 白 0.62 / 白 0.38——**注释："严禁黑色文字"**（黑底主题） |
| 发光 | `glow(_ color:radius:)` | **占位**（EmptyView().shadow）——实际用 .shadow 修饰符，此方法不参与渲染 |

## 五、DriveMode 双层分组与专家模式标签换算器（:4047–4146）

**`DriveMode`（enum: String, CaseIterable, Identifiable，:4047–4076）**——内部降级状态机的 **3 个档位**（`.recover` 已于 2026-09-30 删除，见 :4053-4055 注释）：

| case | rawValue | 说明 |
|---|---|---|
| `.e2e` | "端到端主驾" | **档1**：M9 端到端模型直接开车（:4050） |
| `.yolo` | "YOLO接管" | **档2**：第二套神经网接管（YOLO 画框）（:4051） |
| `.rule` | "纯规则兜底" | **档3**：YOLO 检测 + 手写规则（最后防线）（:4052） |

- **:4048-4049 注释（2026-10-18 已改）**："内部降级状态机的 **3 个**档位（2026-09-30 起从 4 档减为 3 档，见下方 .recover 删除说明）。**UI 层按 DriveModeGroup 合并为 2 个用户可见档位**（端到端主驾 / 规则）"
  > 旧版此注释写的是「4 个档位（**逻辑层完整保留**）」——那是删除 `.recover` 前的历史措辞，lead 2026-10-18 已改为 3 档口径。
- **`.recover` 删除说明（:4053-4055）**：".recover（脱困中）case 已按用户要求删除 —— 脱困策略实测压低速且无法退出，自动驾驶最多维持 ~12 秒。档位从 4 减为 3，UI 按钮只显示 端到端主驾 / 纯规则兜底 两个（见 MissionConsole gears）。"
- **`accentColor`（:4060-4065）**：正常档白色，降级档用状态色警示（`.e2e, .yolo` → 白；`.rule` → `Aurora.danger`）
- **`uiGroup: DriveModeGroup`（:4067-4074）**——所属 UI 展示分组：**模型驱动侧（e2e+yolo）归「端到端主驾」；规则侧（rule）归「规则」**（:4069 补注「脱困档 .recover 已于 2026-09-30 删除，故规则组只剩 .rule 一个成员」）

**`DriveModeGroup`（enum: String, CaseIterable, Identifiable，:4082–4113）**——UI 用户可见的驾驶模式分组（**内部 3 档合并为 2 档**）：

| case | rawValue | members（覆盖的内部档位） | desc（UI 芯片副标题） | icon |
|---|---|---|---|---|
| `.e2eDrive` | "端到端主驾" | `[.e2e, .yolo]`（:4091） | "模型驾驶：M9 端到端 + 神经网接管，开得快"（:4102） | `brain.head.profile`（:4109） |
| `.ruleFallback` | "规则" | `[.rule]`（:4092） | "规则兜底 + 脱困：紧急保命，不当主驾"（:4103） | `shield.lefthalf.filled`（:4110） |

- `members`（:4089-4094）、`contains(_ m: DriveMode)`（:4097）、`desc`（:4100-4105）、`icon`（:4107-4112）
- **⚠️ 待确认（UI 文案残留）**：`.ruleFallback` 的 `desc` 字符串（:4103）仍写「规则兜底 **+ 脱困**」——脱困档 `.recover` 已删除，上游注释 :4081 已标注「（原描述含"+ 脱困"，脱困档 2026-09-30 已删除）」，但 **desc 字符串本身未同步改**。这是「代码注释已修、用户可见文案未修」的不同步，需产品确认是否改为「规则兜底：紧急保命，不当主驾」。

**为什么合并为 2 组（:4078-4080 注释）**：`.e2eDrive` 端到端主驾：模型驱动侧，开得快（M9 + 神经网接管）；`.ruleFallback` 规则：规则兜底，紧急保命用，不当主驾——用户视角只关心"AI 开"还是"规则兜底"，内部档位是工程细节。

**专家模式录制标签换算器（`RecordLabelMapper`，:4121–4146，纯函数便于单测）**——把物理按键的"按住时长"换算成连续控制标签，语义≈"按住该键的力度比例"——与 KeyboardMonitor.holdDuration 配合（专家模式录制，见 [代码-10](代码-10-KeyboardMonitor键盘监视.md) 单元二）：`fullScaleDuration = 0.6`（:4125）、`holdRatio`（:4128-4129）、`steer(leftHeld:rightHeld:)`（:4133-4134）、`throttle(wHeld:)`（:4138-4139）、`brake(sHeld:spaceHeld:)`（:4143-4144）。

## 六、selftest 家族与 CLI 夹具

> 通用退出码约定：**返回失败项数**，`exit(failed == 0 ? 0 : min(failed, 127))`（如 `--perf-selftest` :1136、`--quest-selftest` :1016、`--corner-selftest` :1187）。例外（实测源码，无条件 `exit(0)`）：
> `--proto-selftest`（:1232-1235）、`--nic-autotest`（:1237-1240）、`--limit-selftest`（:1243-1246）、
> `--fit-selftest`（:1260-1263）——这四个的实际断言强度未验证。

### 6.1 任务重点夹具

**`--quest-selftest`**（分流 :1014-1017 → `QuestPanelReader.runSelfTest()`，`Inference/QuestPanelReader.swift:929`，`@MainActor`、返回失败项数）
- 数据源：`models/quest_index.json`（1372 个精确文本 → 2938 条带坐标的目标，`QuestPanelReader.swift:11`）；
  8 条真实面板文字回归（:909、:916-）、另加反向用例（假阳性）、投票缓冲、链消歧、坐标语义、
  ROI 提示行过滤（文件头 :72-73）。
- 分流处注释补一句模糊匹配与节流（`AuroraDriveApp.swift:1009-1013`）。
- **2026-10-18 实测 PASS**（`./.build/scratch/release/AuroraDrive --quest-selftest`）：确认到正确任务与坐标
  `qid=L110302_M target=(30757,65971)`；quest 名为空时回退 desc；「与薄荷对话」判 ambiguous（23 候选）→
  锚点 WJ101302 唯一后继 WJ101303 走链消歧；「与龙叔交谈」3 候选坐标相同走 coord-equivalent 放行；
  ROI 换算 88~1176 / 458~592；模糊阈值 0.62 / 可信 0.75；节流 0.7s。**全部通过**。
- **⚠️ 配套默认值更正（2026-10-17 lead 已改源码注释）**：任务面板 OCR 读取器**默认开启**
  （`AuroraFlags.questOCR` 默认 `true`，2026-10-06 用户实测反馈改默认）。原注释误写「默认关闭（默认 false）」，
  已在两处修正：`:5903`（读取器声明处）与 `:6967`（tick 调用点）。`--quest-selftest` 是纯索引查询，
  **不依赖本开关**（不截屏、不 OCR）。

**`--taxonomy-selftest`**（分流 :1274-1276 → `runTaxonomySelfTest()` :1894-2098）
- 钉三类「不崩但结果错」坑：匹配优先级、默认组解析、聚类性能（注释 :1272-1273）。
- 冻结基线（实测断言行号）：组数 = 7（:1908）；explore 450 / resource 1045 / travel 28 /
  monster 254 / shop 0 / service 0 / landmark 0（期望表 :1932-1933）；合计 = 1777（:1959）；
  1777 个标记全部有组（:1975）。**前置防假绿断言**：`!MapDatabase.markers.isEmpty`（:1939-1940）——
  `countByGroup` 是从 markers 现算的纯派生量，点位为空时统计恒为空 → 不先查就「全 0 通过」。

**`--route-selftest`**（分流 :1268-1270 → `runRouteSelfTest()` :2100-2298）——见第七节。

**`--wire-selftest`**（分流 :990 → `runWireSelfTest()`，`Core/WireSelfTest.swift:47`）
- 验证 2026-10-02 修复的四处「手切档位静默失效」缺陷（`WireSelfTest.swift:12-30`）：
  ① `EngineClient.sendCommand` 静默失败（:14-17）② `ControlWiring.pushConfig` 日志说谎（:19-21）
  ③ `pushEngineConfigIfChanged` 先记账后发送 → 永不重试（:23-26）④ 心跳超时只置 `isConnected`
  → 僵尸引擎模式（:28-30）。
- 全部断言基于**可观测行为**，不做源码字符串匹配（:32-33）。
- **必须 `AURORA_UI_LOCAL=1` 下跑**（`WireSelfTest.swift:36`；A1 用例就依赖本地模式必然未连引擎，:65）。

### 6.2 `--mc-*` 离屏出图夹具（均在 Launcher 无 GUI 阶段同步跑完）

- 为什么必须在 `main()` 同步跑：注释 `AuroraDriveApp.swift:754-757`——「截图是纯离屏 ImageRenderer
  渲染，若放到 ContentView.onAppear 里，无窗口时 view 不 layout → onAppear 永不触发，进程卡 240s」。
- `--mc-map` :758 / `--mc-map-offline` :763 / `--mc-route` :770 / `--mc-route-loading` :775 /
  `--mc-map-bench` :782（`--iters N` 可调，默认 12，:783-787，配 `AURORA_MAP_LEGACY_MARKERS=1` 做 A/B）
  / `--mc-shot [condition w h]` :792 / `--mc-quest [w h]` :810。
- `--mc-quest`（2026-10-06 新增，task-2 验收）：必须走真实 ViewportPanel——
  `MissionControlShot.renderQuestCardNow(canvas:)`（`MissionConsole.swift:6891`，默认画布 1470×560），
  把 questName 与真实世界坐标塞进 state，不依赖 OCR 真跑通（`AuroraDriveApp.swift:807-809` 注释）。
- `--mc-route`/`--mc-route-loading` 注释：数字自检证明算法对，这两个夹具证明**画对**（:768-769 注释）。

### 6.3 其余夹具一句话职责（出处均为分流处实测注释）

- `--perf-selftest` :1130-1137（各子系统单次耗时 p50/p95/p99）；`--tick-profile` :1144-1150（**只读**
  真实 tick 打点，需 GUI 样本）；`--tick-bench` :1157-1163（**主动驱动**真实 tick，离屏可 A/B）。
- `--realshot-selftest` :1169-1180：合成图自检 R2 必然 0 框、R3 必然 0.00%，本命令用真实截图补可信数值。
- `--corner-selftest` :1185-1188：离线地图先验（road_corners_v3b.json）漏拷/格式错时运行时静默
  fail-open → 变显式可验证。
- `--egobox-selftest` :1192-1195：自车框屏蔽阈值边界 + fail-open + 双访问器语义。
- `--perception-selftest` :1199-1202 / `--lanekeep-selftest` :1207-1210 / `--ayolom-selftest` :1215-1218 /
  `--yolopx-selftest` :1221-1228：感知档位、车道保持门、A-YOLOM 模型族（需 `AURORA_AYOLOM=1`）、
  YOLOPX 三合一。
- `--map-selftest` :1281-1283（T1~T6 门槛全部写进断言）；`--map-window-test` :1297-1299
  （真建 NSWindow 断言可见/尺寸/toggle；放锁**之前**以便用户开着 AuroraDrive 时验证新构建，
  配 `AURORA_UI_LOCAL=1` 避免抢引擎 socket，:1293-1296 注释）。
- `--tcc-selftest` :156-171（AppDelegate）：权限预检 = 未来 `--engine` 模式的真实权限状态
  （同执行文件路径 + 签名）。

## 七、route-selftest 冻结基线明细（`AuroraDriveApp.swift:2100–2298`）

2026-10-06 基线更新原因：**路网数据被修好**（`tools/roadnet/fix_roadnet.py`，删自环/极短边、
删重复边、断头吸附、分叉合并——`fix_roadnet.py:1-24`）——删自环 7 条、重复边 5 条、分叉合并 14 处、
断头吸附 80 个（迭代到收敛）、保留 36 个 >30m 远端断头；断头 118(19.3%)→36(5.4%)，
节点 612→664，边 825→932（`AuroraDriveApp.swift:2124-2137` 注释）。

- 图规模：`节点=664`（:2139）、`边=932`（:2140）、`米/像素=0.61`（:2141）
- 坐标往返：4 个世界坐标探针往返误差 < 0.5 px（:2155）；3 个像素探针正向→反向→正向
  < 0.5 px（:2169）
- 吸附：节点 24 自身坐标吸附 = 24（:2177）；偏移 10px 仍吸附到 24（:2183）
- 冻结基线（节点 24 → 36，坐标 (2258,4517)→(6446,4957)，:2201-2204）：
  - W=0：距离 5.78 km（容差 ±0.08）、拐弯数 30（:2210-2211）
  - W=200：距离 6.51 km（±0.08）、拐弯数 12，且 W=200 拐弯更少、路更长（:2215-2219）
  - 字典序模式：**拐弯数 ≤ W=200**（不再断言相等——旧等式是巧合，120 对随机样本中 51/120
    不成立；两者惩罚模型不同：字典序常数 1e7 vs 线性 W×角度/90°，:2234-2237）
- 性能：单次规划 < 5 ms（:2246）；300 对随机样本全可达（固定种子 `0x5DEECE66D`，
  且种子不再对节点数取模——2026-10-06 修复基线可复现性，:2253-2258）
- 验收哲学：与网页版冻结基线逐项对齐——同一份 `models/route_graph.json` 同时驱动本实现与
  `tools/roadnet/web/index.html` 的 `navRoute`（分流处注释 :1265-1267；`navRoute` 字样见 :1879 注释）
- **2026-10-18 实测 PASS**（`./.build/scratch/release/AuroraDrive --route-selftest`，输出与本文所列基线逐项一致）：
  `图规模 节点=664`、`边=932`、`米/像素 = 0.61`；`W=0 距离 5.781 km（基线 5.780）`、`拐弯数 30`、
  `折线 226 顶点`；`W=200 距离 6.512 km（基线 6.510）`、`拐弯数 12`；`字典序 11 / W=200 12`（≤ 成立）；
  `单次规划 0.070 ms`；`299/299 可达`；`平均拐弯 W=0 15.6 → W=200 12.1（降 23%）`；`平均单次规划 0.064 ms`。
  ⟹ 本文第七节所有数字均为**当前实测值**，无一处过期。

## 八、UI 进程 ⇄ 引擎进程的数据交接（详见 代码-33 复核块）

- 生命周期/通道/共享内存布局**逐行实测已迁入 代码-33「2026-10-06 复核块」**，本篇不再重复。
- UI 侧镜像点（`EngineClient.shared.isActive` 时全部取引擎数据，本地取本地引擎）：
  `AuroraDriveApp.swift:4206`（`displayDetections` 检测框）、`6600-6608`（录制命令回声抑制，
  `applyingRemoteRecord`）、`5104`（`e2eLatencyMs`）、`6586-6588`（速度）、
  `5867-5880`（`displayDrivableMask` / `displayMaskMetrics` / `displayMaskDegraded` 三对 display× 访问器）。
- 退出时 `applicationWillTerminate` → `EngineClient.shared.sendByeSync()`（:542-544）；
  引擎侧 `pauseDriving` 释放按键但保持抓屏推理（`Core/EngineMain.swift:1970` 起，函数定义；调用点 :1538 bye / :1928 watchdog）。

## 八·补、tick 内两个 2026-10-18 更新点（20Hz 定档 / lastDecided 两处）

以下两段 lead 2026-10-18 改过，原文档未覆盖，现补录（逐条 `sed -n` 核对）：

**① tick 的 20Hz 定档（`:7133-7137`）**——`dt` 计算的定档注释：

```
// ⚠️ 2026-10-12 最终定档 20Hz：用户拍板「20 赫兹应该也够用了」。
//   tick 是 20Hz（见 `EngineMain.engineTickHz`），抓屏两档也都 20fps
//   （2026-10-12 起对齐；原 ayolom 档 45fps 已废弃 —— 每 tick 只消费 1 帧，
//    多余帧全被跳帧丢弃，纯浪费带宽）。
```

> 旧口径「抓屏 ayolom 档仍 45fps」已废弃，改为两档（ayolom / yolo26s）都 20fps。

**② `dt` 不再硬编码（`:7138-7150`）**——2026-10-14 修复（perf-decision 排查发现）：

```
// ★ 2026-10-14 修复：原写法是硬编码 `1.0 / 20.0`。
//   但 EmergencyTakeover 会把 tick 切到 45Hz（冲刺，最长 35s）或 5Hz（让位），
//   此时硬编码值与真实 tick 间隔不符，下游的时间换算全错：
//     · 45Hz 下 → 帧计数常量（maxMissingFrames=30 等）实际时间缩 2.25×
//       （设计意图 1.5s 变成 0.67s）→ track 过早剪枝、速度过早确认
//     · 5Hz 下 → 时间扩 4×
//   改用本帧实测 tick 间隔（tickGapMs 在 tick() 开头已算好）。
//   钳位 [5ms, 200ms]：防首帧（tickGapMs 未初始化）与极端掉帧把 dt 算成 0 或巨大值。
let dt = min(max(tickGapMs / 1000.0, 0.005), 0.2)
```

**③ `lastDecided` 两处「先比后写」（限速刹车早退分支 `:7560`、主路径末尾 `:7621`；声明 `:5116`）**

- 声明处：`private var lastDecided: DriveMode = .e2e`（**:5116**），注释「诊断留档；脱困档已删除，不再做 `.recover` 边沿检测」。
- 两处赋值均已改为 `if lastDecided != decided { lastDecided = decided }`。
  `@Observable` 语义是**赋值即通知全体观察者**（不管值变没变），`decided` 正常行驶时长期停在同一个模式 ⟹
  无条件赋值等于每帧「通知所有人 → 无人响应」空转。
- **2026-10-18 口径变化**：注释里的「**每秒 30 次无效通知**」已改为「**20Hz 下每秒 20 次**」
  （原写 30Hz，是定档前的口径，lead 本次同步修正）。
- **悬空行号已清**：两处注释原引用 `:4718` / `:4592`（指向 `.recover` 边沿检测的旧位置），
  `.recover` 删除后这些位置已不存在；现改为文字描述「主路径末尾 `lastDecided` 那段的长注释」，
  不再留失效行号。当前 `lastDecided` 真实位置是 **:5116**。
- **⚠️ 仍有 1 处残留悬空引用**：`:7589` 注释写「见待机分支的 `speedValid` / `effectiveSpeed` 与
  **:5118** 的 `lastDecided`」——实测 `:5118` 现在是 `effectiveSpeed` 的文档注释首行（`lastDecided` 实际声明在 `:5116`），
  **不是** `lastDecided`。`lastDecided` 已移到 :5116。此引用需改为 :5116（属源码注释自身的小问题，未代为改动）。

## 九、下部对象（BPF 弹窗 / FrameHost / 日志面板）

同一文件 `:8130` 之后：`BPFPasswordSheet`（:8130，小药丸密码弹窗）/ `DaemonInstallSheet`（:8231）/
`MaskOverlay`（:8451）/ `ObstacleOverlay`（:8596）/ `FrameHost`（:8690，画面流直绘，绕开 SwiftUI body diff）/
`FrameHostView`（:8716）/ `UpscaleFrameHost`（:8732，MetalGoose 插帧宿主）/ `UpscaleFrameHostView`（:8901）/
`LogSink`（:8958，日志面板数据源）。

> 2026-10-18 复核更正：以上 9 个行号原按 9088 行版写为 :8121/:8222/:8442/:8587/:8681/:8707/:8723/:8892/:8949，
> 实测均已 **+7**（lead 在 §5 DriveMode 注释区新增了 7 行：3 档口径 + `.recover` 删除说明）。
> 逐个 `grep -n "^struct/final class"` 复核对齐，非估算。

---

**代码-24 文档至此完整**（AuroraDriveApp.swift :1-9094 上部全覆盖：AppDelegate 与锚定窗口 → 启动分流九步 → 自检/线程提升/@main Launcher → Scene → DriveMode 双层分组；中部 DriveState 见 [代码-25](代码-25-DriveState状态主体.md)）。

**2026-10-17 由 T7 复核**：全文行号按 9088 行版逐条实测（`grep -n` / `awk NR`），修正范围含：AppDelegate 全部方法区间、applicationDidFinishLaunching 九个分流步骤、Launcher/UI 锁/main() 全部分支、Scene 与 DriveMode 三枚举、selftest 家族 40+ 个 CLI 分支、route-selftest 冻结基线、UI 镜像点。历史补丁式阅读提示全部删除（已不成立）；`oneShotFlags` 实测 **50 项**；`Theme`/`GlowCard`/`SectionHeader` 三个旧符号确认已不存在（仅保留历史对照表）。

**2026-10-18 由 merge-map 复核**（源文件 9094 行版，逐条 `sed -n` / `grep -n` 核对）：
- 头部行数 9088→**9094**；锚点表「当前行号」列改称 9094 行版。
- §5 修正：`DriveMode` 区间 :4047–4075→**:4047–4076**、`DriveModeGroup` :4080–4111→**:4082–4113**、
  `RecordLabelMapper` :4119–4144→**:4121–4146**、`DriveState` :4148→**:4150**（均因 lead 在 :4048-4055
  新增 3 档口径注释与 .recover 删除说明而 +2）。
- §5 引文更新：:4048-4049 由「4 个档位（逻辑层完整保留）」改为「**3 个**档位（2026-09-30 起从 4 档减为 3 档）」；
  补录 `.recover` 删除说明（:4053-4055）与 `accentColor`（:4060-4065）；`uiGroup` 注释行号 :4067-4068→**:4067-4069**。
- §5 新增「⚠️ 待确认」一条：`.ruleFallback` 的 `desc` 字符串（:4103）仍含「+ 脱困」，而上游注释 :4081 已注明该词
  已因 `.recover` 删除而作废 —— **代码注释已修、用户可见文案未修**，需产品决策，未代为改动源码。
- §6.1 补 `--quest-selftest` 2026-10-18 实测 PASS 记录，并同步 QUEST_OCR 默认值口径（**默认开启**，
  `AuroraFlags.questOCR` 默认 true；lead 已在 :5903 / :6967 两处修正原「默认关闭」误注）。
- §7 补 `--route-selftest` 2026-10-18 实测 PASS 记录（全部基线与本文所列一致）。
- `oneShotFlags` 复测仍为 **50 项**（逐元素解析、剔除注释、无重复）；数组区间 :919–970 不变。
- `applyMainThreadBoost` 的 `period: 33_333_333ns ≈ 30Hz`（:686-690）**保持不变** —— 那是主线程调度周期常量，
  与 tick 定档 20Hz 是两件事，不随 tick 频率改写。
- **未发现**本文其余引用（`:27-556`、`:133-537`、`:563-645`、`:919-970`、`:1301-1307`、`:1894-2098`、
  `:2100-2298`、`:2124-2137`、`:3810`、`:3966` 及全部 CLI 分支行号）与当前源码不符 —— 这些区间在 lead
  本次改动**之前**，未发生漂移。
- 新增「§八·补」记录 tick 两个 2026-10-18 更新点：20Hz 定档注释（:7133-7137）、`dt` 改实测间隔
  （:7135-7150）、`lastDecided` 两处先比后写（:7560 / :7621，声明在 :5116，30Hz→20Hz 口径、
  悬空行号 :4718/:4592 已清）。
- 发现源码注释 1 处仍指向失效位置：`:7589` 引用「:5118 的 `lastDecided`」，实测 :5118 是 `effectiveSpeed` 注释、
  `lastDecided` 实际在 :5116 —— 已在本文标注，**未改源码**。
