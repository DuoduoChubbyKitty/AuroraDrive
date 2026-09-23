# 代码-24 AuroraDriveApp 入口与 AppDelegate

> 覆盖源文件：`Sources/AuroraDrive/App/AuroraDriveApp.swift`（4379 行）之上部：文件头 + AppDelegate（1–379 行）。基于当前仓库逐单元编写。（中部 AgentSkillCenter/调度见 代码-25，下部 ContentView 见 代码-26）

## 一、AppDelegate 与 Game Mode 锚定窗口（第 26–87 行）

**文件头（4–8 行）**：AuroraDrive——异环游戏自动开车辅助工具；**SwiftUI macOS 14+ | 单窗口 1200x760 | Tesla FSD 驾驶舱风格；纯黑底 + 青色(#00E5FF)发光 + 高对比白字**。

**AppDelegate（final class，第 27 行起）**——应用启动时**强制激活窗口到前台**（直接 swift 运行时窗口默认不激活）。

**静态/成员状态（第 29–39 行）：**

| 成员 | 说明 |
|---|---|
| `static var agentEngines: (control: ControlEngine, capture: CaptureEngine)?` | **命令模式（--agent-command）独立引擎组：静态持有，防 Arc 释放导致 SCK 流停摆** |
| `napToken: NSObjectProtocol?` | 抑制 App Nap 的 activity token（**必须持有，否则 activity 立即释放、抑制失效**） |
| `eventTap: CFMachPort?` | CGEventTap 句柄（持有防止释放，系统级实时保护） |
| `memoryAnchor: UnsafeMutableRawPointer?` | 768MB 内存锚点（持有防止释放，让系统不敢冻结本进程） |
| `powerAssertionID: IOPMAssertionID` | IOPMAssertion ID（防止系统 Power Management 判定进程空闲并冻结，Game Mode 最强对抗） |
| `gameModeAnchorWindow: NSWindow?` | Game Mode 对抗锚定窗口（1×1 浮层） |

**`installGameModeAnchorWindow()`（private，第 58–87 行）——Game Mode 对抗：安装 1×1「锚定窗口」：**

- **原理（42–46 行注释）**：Game Mode 由 gamepolicyd 管理，它系统性地压制**后台任务**（Apple 原话：lowering usage for background tasks / background threads being suppressed）。macOS 判定"后台"的常见依据是「无可见窗口 + 无用户交互」——**这里挂一个技术上可见、视觉上无感的窗口，试图让本进程不被归入纯后台桶**
- **关键设计（48–53 行）**：`fullScreenAuxiliary`——**能随游戏全屏 Space 一起显示**（否则游戏全屏后本窗口被移出该 Space，等于不存在）；1×1 px + 近乎透明 + `ignoresMouseEvents`——视觉与交互零干扰；`.floating` 层级——保证不被游戏窗口完全遮蔽；**屏幕右下角**——即使有 1px 痕迹也在最不显眼处
- 窗口属性：isOpaque=false、**`backgroundColor = NSColor.black.withAlphaComponent(0.02)`——非零 alpha：完全透明的窗口可能被系统直接判定为"无可见内容"**、hasShadow=false、ignoresMouseEvents=true（绝不拦截点击）、isMovable=false、level=.floating、collectionBehavior=[.canJoinAllSpaces, .stationary, .ignoresCycle, **.fullScreenAuxiliary**]
- **位置（74–79 行）**：**用 CGDisplayBounds 计算：NSScreen.main 在「app 未激活 / 从 shell 启动」时会返回异常值（实测 maxX=0 → 窗口跑到屏幕外），CGDisplay 不受激活状态影响**——`screenBounds.maxX - 4 / maxY - 4`（右下角内缩：在屏内 + 避开 Dock）
- `orderFrontRegardless()` + gameModeAnchorWindow = w + **诊断落盘 `/tmp/aurora_anchor_diag.log`**（"stdout 重定向到文件时是块缓冲，print 可能不落盘"）+ `fflush(stdout)` + print

**诚实标注（55–57 行注释）**：此对抗是否被 gamepolicyd 认可**没有公开证据**，属于工程尝试；配合已有的 beginActivity(.latencyCritical) / CGEventTap / IOPMAssertion 共同构成多层防护。**若实测无效，可调 alphaValue / 尺寸 / level 再试**。

## 二、applicationDidFinishLaunching 启动分流（第 89–360 行）

**方法体按启动路径分流（89–360 行）——先 CLI 自检、再引擎探测、再防冻结、再命令模式：**

**① CLI 自检与诊断入口（92–159 行）：**

| 参数 | 行为 |
|---|---|
| `--daemon`（或 AURORA_DAEMON_MODE=1） | Daemon 模式：`NSApp.setActivationPolicy(.accessory)`（不激活窗口、不显示 Dock 图标，纯后台运行）——**历史入口保留** |
| `--test-xpc` | **用户会话 XPC Agent 方案已废弃**——"launchd 拉起的进程拿不到 TCC 权限，引擎改由主程序 spawn 子进程承担"；打印提示 + `exit(0)` |
| `--tcc-selftest` | **TCC 权限继承验证**：`AXIsProcessTrusted()`（**不带 prompt = 纯查询，零弹窗**）+ `CGPreflightScreenCaptureAccess()`（纯查询）→ 结果追加写 `~/Library/Logs/AuroraTCCSelfTest.log` → `exit((axOK && screenOK) ? 0 : 2)`。"launchd 以「与 UI 完全相同的可执行文件路径+签名」拉起本进程，因此这里的预检结果 = 未来 --engine 模式的真实权限状态" |
| `--yolo-selftest <图片>` | `YoloEngine().selfTest(imagePath:)` + `exit(0)` |
| `--yolo-bench <图片>` | `YoloEngine().benchmark(imagePath:)`（对比直通 vs 慢路径）+ `exit(0)` |
| `--speed-selftest <目录> [--roi x,y,w,h]` | `SpeedOCRReader().selfTestDirectory(...)`（--roi 解析 4 个 Double → CGRect，目录是 ROI 切片帧时传归一化位置）+ `exit(0)` |

**② 引擎模式探测（161–166 行）**：`if !isDaemon { EngineClient.shared.startup() }`——**探测 engine.sock：已有健康引擎 → 直接连接；没有 → spawn 自己（--engine）。任一步失败自动回退本地模式（全部本地逻辑保持原样）**。

**③ 防 App Nap + 优先级（168–184 行）：**

- `disableAutomaticTermination("AuroraDrive 实时游戏辅助：持续截屏 + AI 决策注入")`——只防"被系统自动退出"，不管节流
- **`beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])`（176–178 行）**——源注释："App 在游戏前台全屏时沦为后台 App，系统默认会对它的 RunLoop 定时器/渲染做 **App Nap 节流（Timer 掉帧、界面卡）——这正是"只有 App 界面卡"的根因**。.latencyCritical 声明对延迟敏感 → 系统不再对其节流，后台保持前台级节奏。token 必须持有（napToken）"
- `setpriority(PRIO_PROCESS, 0, -20)`——**最高进程优先级 nice=-20（用户进程极限）**
- `GameModeDefender.shared.start()`——**Game Mode 对抗（持久战）：静音音频 + 每 3s 重新主张 nice/activity/音频**
- **HUD 承担"可见窗口"职责（186–189 行注释）**：由 DriveState 的 GameHUDWindow（左上角绿色帧率 HUD）承担——它比 1×1 隐形锚点更可能被 gamepolicyd 认作"有可见窗口的应用"，且同时提供实用信息；**锚定窗口方案保留在方法中，默认不再调用**

**④ CGEventTap 空监听（192–211 行）：**

- **`CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: keyDown, callback: { return Unmanaged.passUnretained(event) })`**——源注释："**系统必须保持有 event tap 的进程响应，否则事件丢弃——这是强制系统不冻结本进程的最有效手段（Game Mode 也挡不住）**。只监听键盘事件，**不监听鼠标移动（避免鼠标被强制移到左上角）**"
- `tapCreate` 失败 → "可能辅助功能权限未授权" + **return（后续 IOPM/Darwin 不再安装）**
- `tapEnable(enable: true)` + CFRunLoopAddSource(.commonModes) + `self.eventTap = eventTap`（持有防释放）

**⑤ 768MB 内存锚点（213–230 行）**：`UnsafeMutableRawPointer.allocate(768MB, alignment: 4096)` → **逐页写首字节（强制物理内存映射）** → **`mlock(buf, allocSize)` 锁定页面在物理 RAM，系统不能换出**（失败打印"可能需要root"）→ `self.memoryAnchor = buf`（持有防止释放）。"让系统认为本进程是「重资源进程」不敢冻结"。

**⑥ 命令模式与 IOPMAssertion（232–261 行）：**

- `NSApp.setActivationPolicy(isCommandMode ? .accessory : .regular)`——**.accessory 下进程不占 Dock、不触发 Space 切换（保持游戏所在 Space 激活，供键注入落到游戏内）**；非命令模式才 `NSApp.activate(ignoringOtherApps: true)`
- **`IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, On, "AuroraDrive Real-time Game Assistant")`（243–261 行）**——"**对抗 Game Mode 冻结后台进程的官方 API，比任何 hack 都稳定**"；成功/失败都写 `/tmp/aurora_iopm_status.log`（"SwiftUI App 不输出到终端"）

**⑦ Darwin Notification Center（263–304 行）**：`CFNotificationCenterGetDarwinNotifyCenter()` + 三个 observer（`com.apple.system.powermanagement`（系统睡眠/唤醒）、`com.apple.system.displays.reconfiguration`（**全屏切换时触发**）、`com.apple.system.clock_set`（系统时间变化））——"**系统不会冻结正在监听系统通知的进程**"，回调只 print。

**⑧ 窗口激活与自动登录/命令派发（306–345 行）：**

- **延迟激活（306–319 行）**：**SwiftUI WindowGroup 的窗口在 applicationDidFinishLaunching 之后、runloop 下一轮才创建（此时同步遍历 NSApp.windows 常为空，激活无效）。延迟到下一 runloop 再激活**——`DispatchQueue.main.async { NSApp.activate + 全部 window makeKeyAndOrderFront + orderFrontRegardless }`；**命令模式不激活**
- **`--auto-login`（321–333 行）**：**放在 applicationDidFinishLaunching 而非 ContentView.onAppear：登录守护与 UI 渲染解耦——引擎/权限环境异常导致窗口创建延迟或失败时，守护照样启动，不会"卡死在等窗口"**。守护内部已有安全护栏：① 只有检测到游戏窗口（异环/NTE）才允许点击，绝不误点其他窗口；② 每 8s 一次、最多 10 次（80s 超时自动停止）；③ 游戏未开/已登录时安静等待或退出，无副作用。`asyncAfter(1.5)` → `AgentSkillCenter.shared.requestAutoLoginOnStartup()`
- **`--agent-command "<指令>"`（335–345 行）**：**与 --auto-login 同理放在 AppDelegate：命令模式（.accessory）下窗口可能被 orderOut、视图 onAppear 不触发，派发必须与视图渲染解耦**。AgentSkillCenter 内部排队，引擎注入（configure）时补发，8s 兜底。`asyncAfter(1.5)` → `requestCommandOnStartup(cmd)`

**⑨ 命令模式引擎注入（347–359 行）**：`--agent-command` 时——**由 AppDelegate 独立创建一组引擎并注入（不走 DriveState，避免其 init 副作用：删 /tmp/aurora_debug.log + 装第二套 HUD）**；`AppDelegate.agentEngines = (ctl, cap)`（**静态持有防释放**）+ `configure(control:capture:)` + `cap.start()`（本地 SCK 全屏流，屏幕录制 TCC）；"视图若随后渲染也会 configure 一次（DriveState 引擎），后注入者生效，二者等价"。

**`applicationWillTerminate`（第 365–367 行）**：`EngineClient.shared.sendByeSync()`——**正常退出前通知后台引擎「我走了，继续跑」：引擎收到 bye 后释放按键但保持抓屏推理，等待下次 UI 重连，且不会把这次断开当作崩溃来处理（不触发看门狗停车）**。

**`deinit`（第 369–378 行）**：gameModeAnchorWindow orderOut + nil、`IOPMAssertionRelease(powerAssertionID)`（进程退出时自动调用）。

## 三、upscale 自检 / 主线程优先级提升 / @main Launcher（第 382–673 行）

**`runUpscaleSelfTest()`（private，第 386–468 行）——插帧引擎自检（`--upscale-selftest`）**：

1. `GooseUpscaler.make()` 为 nil → FAIL exit(1)（"Metal 不可用或引擎初始化失败"）→ `configureInterpolation()`（"插帧模式配置完成"）
2. **测试窗口挂载（395–410 行）**：MTKView（320×180）+ NSWindow（borderless、floating、位置 NSScreen.main.visibleFrame 中上）→ `upscaler.attachToView(view, displayRefreshRate: 60, minRefreshRate: 30)` → makeKeyAndOrderFront——打印 view/drawable 尺寸
3. **喂帧定时器（417–433 行）**：0.5s 后——feedTimer 0.10s 间隔（`SelfTestImage.make(640×360, frame: 计数)` 合成图 → `upscaler.ingest(cgImage:)` → 手动驱动 draw）+ drawTick 0.050s（纯驱动 draw）——两个 Timer 都 RunLoop.main .common
4. **8 秒后判定（435–467 行）**：`statsSnapshot()` 前后对比——`rendered = outputFrameCount 增加`、`interpolated = interpolatedFrameCount 增加`：
   - **双真 → PASS**（"插帧工作 out A→B interp C→D fps N"）+ `SelfTestResult.write` + `exit(0)`
   - rendered 但未插帧 → **FAIL"渲染出帧但未插帧(纯透传)"** + exit(1)
   - 无输出 → FAIL"渲染路径无输出 MTKView未渲染出帧" + exit(1)
   - `pendingError()` 非空 → ENGINE-ERR 附加进结果文件

**`SelfTestResult`（private enum，第 470–478 行）**：结果写 `/tmp/upselftest_result.txt`——`[UPSELFTEST] verdict [ENGINE-ERR=...]`。

**`SelfTestImage.make(width:height:frame:)`（private enum，第 480–493 行）**：合成测试图——蓝底（0.15/0.55/0.95）+ **橙色方块随 frame 位移（`frame % 8 × 60`，120×80 @y=120）**——给插帧引擎一个"会动的画面"（静止画面插帧无从插）。premultipliedLast | byteOrder32Big（RGBA）。

**`applyMainThreadBoost(_ enabled: Bool)`（private，第 500–525 行）——主线程优先级提升（对抗全屏游戏时的线程降权）**：

- enabled：`mach_thread_self()` → `thread_time_constraint_policy_data_t(period: 33_333_333ns≈30Hz, computation: 6ms, constraint: 15ms, preemptible: 1)`——**时间约束调度（THREAD_TIME_CONSTRAINT_POLICY）**：系统保证主线程每 33ms 至少跑 6ms（15ms 约束内）；`units(_ ns:)` 用 mach_timebase 换算（denom/numer 防御）
- 关闭：`thread_policy_set(THREAD_STANDARD_POLICY)`——恢复标准调度

**`@main AuroraDriveLauncher`（第 531–673 行）——进程入口分流**：

- **为什么移到 Launcher（527–530 行注释）**："`--engine` 走纯后台引擎（EngineMain，不触碰 SwiftUI、不创建窗口、不跑 NSApp），否则照常启动 SwiftUI 界面。**@main 从 App 结构移到本 Launcher 仅为拿到最早的进程入口，SwiftUI 的 App/Scene/AppDelegate 结构完全保持原样**"

**UI 单实例锁（第 533–556 行）**：

- `uiLockFD`（nonisolated(unsafe) static）——fd 持有到进程退出，内核自动释放
- **背景（2026-09-12 实测，536–539 行注释）**：两个 UI 实例会互抢同一个引擎 socket——**引擎只服务一个客户端，双方轮流被踢 → 各自「断开→重连」0.5 秒死循环刷屏**。引擎侧早有 engine.lock，**UI 侧此前缺失，这里补齐**
- `acquireUISingleInstanceLock() -> Bool`：建 `ui.lock`（Application Support/AuroraDrive/，0o600）→ `flock(LOCK_EX | LOCK_NB)` → 持有 + 写 pid；**锁文件不可建时放行（不阻碍正常使用）**；flock 失败 → close + false

**`main()`（第 558–672 行）——顶层分流四步：**

1. **`setvbuf(stdout, nil, _IOLBF, 0)`（561 行）**——**stdout 改行缓冲：print 立即落盘（重定向到文件/管道时不再等到进程退出才 flush——否则 crash/卡死时日志全丢，无法定位）**
2. **`--engine`（564–566 行）**：`EngineMain.run()`——**永不返回**（dispatchMain 常驻；自身已有 engine.lock）
3. **`--set-llm-config <apiKey> <baseUrl> <model>`（568–583 行）**：**提前处理（不需要 GUI/引擎）**——AgentSettings.save()（本地小本本 + 固定域 UserDefaults，不碰钥匙串）→ 打印保存结果（key 打码）→ exit
4. **`--agent-llm-test`（585–658 行）**：**真实 LLM 请求自测（不需要 GUI）**——**修复：纯同步 URLSession + 30s 硬超时（不依赖 Swift concurrency / Keychain 解锁）**：
   - 非阻塞读取配置：UserDefaults 读 baseUrl/model（默认 agnes-ai.cn/v1 + agnes-2.5-flash），**Key 从环境变量 AURORA_API_KEY（CLI 场景）**
   - 组请求（POST chat/completions，messages 只有 1 条 user "用一句话回答：1+1等于几？"，max_tokens 100）→ `dataTask + semaphore`（**semaphore 35s 超时**，task.cancel）→ 200...299 校验 → 解析 content 打印 → exit(0)
5. **一次性自检不参与 UI 锁（659–670 行）**：`oneShotFlags = [--speed-selftest, --tcc-selftest, --test-xpc, --yolo-selftest, --upscale-selftest, --yolo-bench, --daemon]`——"**它们是短命进程或被 launchd 托管，若参与锁会与常驻 UI 互斥，导致自检失败或用户无法启动界面**"；非 oneShot 且锁失败 → 打印原因（"两个 UI 会互抢引擎 socket（0.5s 断开重连死循环）"）+ exit(0)
6. `AuroraDriveApp.main()`——正常启动 SwiftUI

## 四、AuroraDriveApp Scene 与 Theme 设计系统（第 675–744 行）

**`AuroraDriveApp`（struct: App，第 675–715 行）**：

- `@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate`——挂 AppDelegate
- **body（WindowGroup）**：`ContentView()` + `.frame(minWidth: 880, minHeight: 560)` + `.background(Color.black)` + `.onAppear`：
  - `isCommandMode` 判定 → **命令模式：全部窗口 `orderOut(nil)`（后台运行、不抢焦点、不前置窗口——保持游戏所在 Space 激活，供键注入落到游戏内）** + return
  - 正常模式：`NSApp.activate` + 全窗口 makeKeyAndOrderFront + orderFrontRegardless + **标题栏 chrome 全部隐藏**——"全屏游戏时标题栏（含红黄绿按钮/标题条）会浮在游戏画面上遮挡一条，这里把标题栏 chrome 全部隐藏"：`titlebarAppearsTransparent = true` + `titleVisibility = .hidden` + 三个 standardWindowButton（close/miniaturize/zoom）isHidden
  - **⚠️ 踩坑记录（704–706 行注释）**："**绝不要开 isMovableByWindowBackground——那会让「在画面上拖拽」变成「拖动整个窗口」，把框选手势整个吃掉（实测踩过）**。拖窗口请拖窗口顶部那条隐形标题栏区域"
- `.windowStyle(.hiddenTitleBar)` + `.windowResizability(.contentMinSize)` + **`.defaultSize(width: 1200, height: 760)`**（单窗口 Tesla FSD 驾驶舱风格）

**`Theme`（enum，第 723–744 行）——全局主题：FSD 驾驶舱配色与发光参数：**

| 组 | 常量 | 值 |
|---|---|---|
| 背景 | `bgPure` / `bgCard` / `bgCardEdge` | `Color.black` / 白 0.045 / 白 0.08 |
| 主色/强调 | `cyan` / `cyanDim` / `orangeRed` / `danger` | **#00E5FF**（0,0.898,1.0）/ 同×0.55 /（1,0.36,0.22）**极速模式** /（1,0.24,0.28）**障碍红** |
| 文字 | `textPrimary / textSecondary / textTertiary` | 白 / 白 0.62 / 白 0.38——**注释："严禁黑色文字"**（黑底主题） |
| 发光 | `glow(_ color:radius:)` | **占位**（EmptyView().shadow）——实际用 .shadow 修饰符，此方法不参与渲染 |

**`GlowCard<Content: View>`（struct，第 747–768 行）**——圆角卡片容器：半透明底 + 细描边 + 内高光：padding（默认 16）+ ZStack（16 圆角 fill bgCard + **LinearGradient 描边（白 0.14→0.04 对角）**）+ clipShape。

**`SectionHeader`（struct，第 771–786 行）**——区块标题：小字大写 + 青色竖条：**3×12 青色圆角条（发光 shadow radius 4）** + `Text(title)`（11pt bold rounded + **tracking 2.5** + textSecondary）+ Spacer。

## 五、DriveMode 双层分组与专家模式标签换算器（第 789–850 行）

**`DriveMode`（enum: String, CaseIterable, Identifiable，第 793–811 行）**——内部降级状态机的 4 个档位：

| case | rawValue | 说明 |
|---|---|---|
| `.e2e` | "端到端主驾" | **档1**：M9 端到端模型直接开车 |
| `.yolo` | "YOLO接管" | **档2**：第二套神经网接管（YOLO 画框） |
| `.recover` | "脱困中" | **档3**：卡死脱困（自动倒车/转向） |
| `.rule` | "纯规则兜底" | **档4**：YOLO 检测 + 手写规则（最后防线） |

- **794–795 行注释**："内部降级状态机的 4 个档位（**逻辑层完整保留，降级/回升仍按 4 档走**）。**UI 层按 DriveModeGroup 合并为 2 个用户可见档位**（端到端主驾 / 规则）"——逻辑 4 档、UI 2 组，两层口径分开
- **`uiGroup: DriveModeGroup`（805–810 行）**——所属 UI 展示分组：**模型驱动侧（e2e+yolo）归「端到端主驾」；规则/脱困侧（recover+rule）归「规则」**

**`DriveModeGroup`（enum: String, CaseIterable, Identifiable，第 816–847 行）**——UI 用户可见的驾驶模式分组（**内部 4 档合并为 2 档**）：

| case | rawValue | members（覆盖的内部档位） | desc（UI 芯片副标题） | icon |
|---|---|---|---|---|
| `.e2eDrive` | "端到端主驾" | `[.e2e, .yolo]` | "模型驾驶：M9 端到端 + 神经网接管，开得快" | `brain.head.profile` |
| `.ruleFallback` | "规则" | `[.recover, .rule]` | "规则兜底 + 脱困：紧急保命，不当主驾" | `shield.lefthalf.filled` |

- `contains(_ m: DriveMode) -> Bool`——组内是否包含指定内部档位（用于高亮当前组）

**为什么合并为 2 组（814–815 行注释）**：`.e2eDrive` 端到端主驾：模型驱动侧，开得快（M9 + 神经网接管）；`.ruleFallback` 规则：规则兜底 + 脱困，**紧急保命用，不当主驾**——用户视角只关心"AI 开"还是"规则兜底"，内部档位是工程细节。

**专家模式录制标签换算器（第 849 行起，纯函数便于单测）**——把物理按键的"按住时长"换算成连续控制标签，语义≈"按住该键的力度比例"——与 KeyboardMonitor.holdDuration 配合（专家模式录制，见 代码-10 单元二）。

**代码-24 文档至此完整**（AuroraDriveApp.swift 1–850 行全覆盖：AppDelegate 与锚定窗口 → 启动分流九步 → 自检/线程提升/@main Launcher → Scene 与 Theme → DriveMode 双层分组）。剩余 851–4379 行（DriveState 状态主体、AgentSkillCenter 调度、ContentView 主界面）见 代码-25/代码-26。