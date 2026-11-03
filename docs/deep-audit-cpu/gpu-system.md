# GPU / 系统级 / 全仓浪费扫描报告

> 审计员：teammate `gpu-system`（task-3）
> 机器：Apple M3 / 8 核 / 16GB / 主屏 2560×1664@2x + 副屏 1200×1920
> 扫描范围：**已编译范围**（`Sources/AuroraDrive` + `Vendor/MetalGoose/Engine`，77 个 Swift 文件 / 70,427 行）—— 全仓扫描、不抽样。
> 方法：纯静态分析（grep / read / 构建产物解析）。未启动 App、未联网、未覆盖任何窗口。
> 日期：2026-11-01

---

## 0. 一句话结论

AuroraDrive **默认配置下自身 GPU 占用 0～1% 量级**（实测两次 0.76% / 0.01%，来源 `docs/perf-audit-gpu/11-gpu-users.md` §1.5），真正的大头不在 GPU 而在系统级 WindowServer 合成（+12.82pp，记系统账）；全仓可清理的纯浪费集中在 **3 处 BrandMark 类死动画**、**1 个缺轮转的日志函数**、**9 个未编译的死文件（4687 行）**，而 **GameModeDefender 的重主张循环与静音音频是两件独立的事，绝不可整体删除**（删静音音频 = 降频事故，已核实实现体）。

---

## 1. GPU 接触点全表（已编译范围）

> 口径修正：`11-gpu-users.md` 中「MTLTexture 85 处」是**全 Vendor 目录**统计；实际编进二进制的只有 `Vendor/MetalGoose/Engine/`，已编译范围内 **MTLTexture = 42 处**（`.build/scratch/release.yaml` 证实仅 Engine/ 下 5 个文件参与编译）。

| # | 位置 | 是什么 | 默认是否跑 | 实测占用 | 能否省 |
|---|---|---|---|---|---|
| G1 | `Vendor/MetalGoose/Engine/GooseEngine.swift:420-435` | `MTLCreateSystemDefaultDevice()` + `makeCommandQueue()`（`GooseUpscaler.make()` 转发） | **每次 UI 启动执行**（`AuroraDriveApp.swift:6263` `upscaleHost.prepare()`），一次性建设备+队列+编译着色器 | 计入 UI 进程 0～1% 总量 | 开关已门控；彻底懒加载见 §5 |
| G2 | `GooseEngine.swift:487-529` | `makeComputePipelineState` / `makeRenderPipelineState`（着色器编译） | 同上，`prepare()` 一次性完成 | 同上 | 同上 |
| G3 | `AuroraDriveApp.swift:9096`（`UpscaleFrameHost.attach` 内） | `MTLCreateSystemDefaultDevice()` 第二次（attach MTKView 时） | 仅 `upscaleEnabled == true`（默认 false）才 attach | 不触发 | 已门控 |
| G4 | `YolopxEngine.swift:746` | CoreML `.all`（A 模型主力） | 是，每帧推理 | 栈采样 GPU 0（289 ANE + 2 CPU），来源 `11-gpu-users.md` §1.6 | 已试 `.cpuAndNeuralEngine` 更慢 10.6%，已回退 |
| G5 | `InferenceEngine.swift:164 / :206` | CoreML `.all`（`m9_mono` / `game_assist_control`） | assistEngine 每次启动加载，e2e 档每 5 帧保活 | **未测**（封在 UI 进程 0～1% 总量内） | 未知 |
| G6 | `InferenceEngineV2.swift:1733 / :1881` | CoreML `.all`（拆模失败兜底） | 默认不走 | 未测 | 未测 |
| G7 | `YoloEngine.swift:187` | CoreML `.all`（legacy 档） | 默认档不加载 | 未测 | 未测 |
| G8 | `ConfidenceEstimator.swift:237` | `CIContext`（默认走 Metal） | **默认关**（`AURORA_CONF_CI=1` 才开） | 默认 0 | 已是纯 CPU 直读 |
| G9 | `SpeedOCRReader.swift:835` | `CIContext` | **默认关**（`AURORA_OCR_CI=1` 才开） | 默认 0 | 已是纯 CPU 内存拷贝 |
| G10 | AppKit / CoreAnimation 自身绘制窗口 | RenderBox DisplayList（系统层，非项目代码） | 开窗口即有 | 计入 0～1% | 与项目代码无关 |
| G11 | **WindowServer 合成上屏** | 把画面合成到物理屏幕 | 窗口可见即有 | **+12.82pp**（记 WindowServer 账，来源 `11-gpu-users.md` §2.6） | 见 §5-W1 |

**已排除（全仓 0 处实际调用，已核实）**：
- VideoToolbox：0 处 `VTCompressionSession`，唯一命中是 `OpticalFlowBridge.swift:16` 注释里被否决的方案。
- OpenCV OpenCL/CUDA：编译期 `-DWITH_OPENCL=OFF`，`cv::UMat`/`ocl::`/`cuda::` 全仓 0 处。
- MPSGraph / `import MetalPerformanceShaders`：已编译范围 0 处。
- `NSVisualEffectView` / `CABackdropLayer` / 毛玻璃：已编译范围 0 处（grep 确认）。
- `CADisplayLink`：已编译范围 0 处实际调用，2 处命中均为 `GooseEngine.swift:817` 注释。
- `TimelineView`：已编译范围 0 处。
- `addAnimation` / `CABasicAnimation` / `CAKeyframeAnimation` / `CAShapeLayer`：已编译范围 0 处（项目用 SwiftUI `withAnimation` 而非直接 CoreAnimation API）。

---

## 2. 系统级开销全表（定时器 / 断言 / 通知）

### 2.1 定时器全清单（已编译范围，按运行进程分组）

**引擎进程（`--engine`）**：

| 位置 | 频率 | QoS | leeway | 用途 | 产物消费方 |
|---|---|---|---|---|---|
| `EngineMain.swift:1281` | 30Hz（ayolom→45Hz） | `.userInteractive` | 0ns | 引擎主 tick（推理/控制/录制） | `EngineMain.tickOnce()` → DriveState |
| `EngineMain.swift:1302` | 1Hz | 无显式（`aurora.engine.heartbeat`） | 50ms | 心跳 + 每 15s 统计行 + shutdown 检测 | `sendHeartbeat()` → UI 进程 EngineClient |
| `EngineMain.swift:831` | 动态（setTickHz） | 同主 tick | 0ns | 档位切换重调度 | 同上 |
| `GameModeDefender.swift:155` | 3s | `.userInteractive` | 200ms | 重主张（nice/audio/token） | 见 §2.2 |
| `AuroraCache.swift:517` | 1Hz | `.utility` | 200ms | metrics 推送 | **仅 `AURORA_PERF=1` 时创建**，默认不创建 |

**UI 进程**：

| 位置 | 频率 | QoS | leeway | 用途 | 产物消费方 |
|---|---|---|---|---|---|
| `MissionConsole.swift:6233` | 15Hz | `.userInteractive` | 0ns | UI-local tick（未连引擎时驱动 DriveState） | `state.tick()`，**带 idleSkip 8 倍降频**（待机 ~1.9Hz） |
| `MissionConsole.swift:6309` | 10Hz | `.userInteractive` | 0ns | 网络定位轮询 | `state.runNetworkLocateStep()`，**带 idleSkip 5 倍降频**（待机 ~2Hz） |
| `GameHUDWindow.swift:97` | 2Hz | RunLoop.main | — | 帧率 HUD 数字刷新 | `refresh()` → label.stringValue |
| `MissionConsole.swift:5304` | ~9Hz（0.11s） | `.main/.common` | — | 路径规划遮罩动画（`RoutePlanningOverlay`） | `elapsed`/`spin`/`barPhase` → 视图渲染，**仅在规划期间显示** |
| `AuroraDriveApp.swift:604/613/621` | 10Hz/20Hz/一次性 | RunLoop | — | 插帧自检喂帧 + 绘制 tick | **仅 `--upscale-selftest` 时** |
| `AIAgentPanel.swift:742/810/849/911/1012/1055/1092/1131/1169` | 0.6-8s | workQueue(`.userInteractive`) | — | 各技能循环（登录守护/排球/触摸等） | **仅对应技能激活时才创建** |

> **leeway=0 的两个高频定时器**（MissionConsole tick 15Hz / netlocate 10Hz）都有 idleSkip 降频机制，待机时分别降到 ~1.9Hz / ~2Hz。这是已优化项，**不是浪费**。

### 2.2 GameModeDefender 分别处置建议（⚠️ 安全规则核心）

**已读完整实现体**（`Sources/AuroraDrive/Core/GameModeDefender.swift`，217 行），确认 `start()` 确实是**两件事**：

```swift
func start() {              // :92
    startSilentAudio()      // :95  ← 措施 1：静音音频锚
    startReassertLoop()     // :96  ← 措施 2：3s 重主张循环
}
```

| 措施 | 实现 | 能否动 | 理由 |
|---|---|---|---|
| **静音音频**（`startSilentAudio` :109） | AudioQueue 2×11025 帧零采样循环，44.1kHz/2ch | **绝不可删** | Apple 文档：App Nap 判定条件之一是「isn't audible」→ 播音频是独立豁免项；CoreAudio 线程是实时优先级且不需 root。**删了 = 系统降频**（2026-11-01 事故，见记忆决策堂#9） |
| **重主张循环**（`startReassertLoop` :152） | 3s DispatchSource，`.userInteractive`，leeway 200ms | **可降频，不可删** | `reassert()` (:162) 做 3 件事：① nice 复查设回 -20 ② activity token 重新取得 ③ **静音音频被系统停掉就重启**。删了会导致 nice 被渐进压制、音频被停后无法自愈 |
| **reassert() 第③项** | :182-191 检查 `kAudioQueueProperty_IsRunning`，停了就 `AudioQueueStart` | **不可删** | 这是静音音频的自愈机制，与重主张循环绑定在同一函数内 |

**建议**：
- ✅ 可将重主张间隔从 3s 放宽到 5s（降低唤醒频率约 40%），**但必须保留静音音频与音频自愈逻辑**。
- ✅ 可将 `aurora.defender` 队列 QoS 从 `.userInteractive` 降到 `.userInitiated`（重主张非实时路径），**但静音音频的 AudioQueue 线程由 CoreAudio 自身管理 QoS，不受此影响**。
- ❌ 绝不可整体删除 `start()` 或 `startReassertLoop()`。
- ❌ 绝不可删除 `startSilentAudio()`。

### 2.3 其他系统级断言 / 通知

| 位置 | 类型 | 默认是否生效 | 用途 | 可否动 |
|---|---|---|---|---|
| `AuroraDriveApp.swift:343` | `IOPMAssertionCreateWithName`（PreventUserIdleSystemSleep） | 是（启动即创建） | Power Management 层防冻结，Game Mode 最强对抗 | 不可删（与 CGEventTap/beginActivity 三重覆盖，三者互补） |
| `AuroraDriveApp.swift:228` | `beginActivity([.latencyCritical, .userInteractive, .idleSystemSleepDisabled])` | 是（UI 进程） | 抑制 App Nap 节流 | 不可删（删了 Timer 掉帧、界面卡） |
| `EngineMain.swift:1162` | `beginActivity`（同上） | 是（引擎进程） | 同上 | 不可删 |
| `AuroraDriveApp.swift:244-293` | `CGEvent.tapCreate`（listenOnly，keyDown） | 是（需辅助功能权限） | 系统视本进程为实时响应进程 | 权限缺失时已降级跳过，不阻断初始化 |
| `AuroraDriveApp.swift:365-398` | Darwin 通知（3 个：powermanagement / displays.reconfiguration / clock_set） | 是 | 监听系统事件，保持进程活跃 | 回调仅 `print`，**诊断价值有限但开销极低**（事件驱动非轮询），不建议动 |
| `AuroraDriveApp.swift:220` | `disableAutomaticTermination` | 是 | 防系统自动退出 | 不可删 |
| `AuroraDriveApp.swift:555-561` | `IOPMAssertionRelease`（atexit） | 退出时 | 释放断言 | 正常清理 |
| `PrioritySetup.swift` | root renice 守护（外部 LaunchDaemon） | 需密码安装 | 每 5s renice 到 -20 | `install(password:)` 已 deprecated，改走 PrivilegePill |

---

## 3. 全仓浪费清单（每条附消费方追溯结论）

> 纪律：每条候选都向上追溯到最终消费方；**找不到消费者**才定性为浪费。禁止只凭「看起来没用」下结论。

### W1. BrandMark 的 `spin` 死动画（确认浪费）

| 维度 | 内容 |
|---|---|
| 位置 | `Sources/AuroraDrive/App/MissionConsole.swift:177`（`@State private var spin = false`）+ `:194`（`withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { spin = true }`） |
| 消费方追溯 | grep `spin` 在 BrandMark struct（:176-196）范围内**只有声明(:177)和写入(:194)两处**，**无任何 `rotationEffect`/`scaleEffect`/`offset` 读取 spin**。对比同文件 :5300 的 `spin: Double`（`RoutePlanningOverlay`）有 `:5325` `.rotationEffect(.degrees(spin))` 读取——那是有消费方的。BrandMark 的 spin **是纯白跑**。 |
| 证据 | `grep -n 'spin' MissionConsole.swift` → :177 声明 / :194 写入 / :5300 声明(另一个) / :5325 读取(另一个) / :5373/5376 写入(另一个)。BrandMark 的 spin 无读取行。 |
| 可省多少 | 一个 9s repeatForever 动画 → Core Animation 每帧重算 BrandMark 子树（31px 圆 + 3 层 shadow + iceGlow 辉光），WindowServer 持续合成。**量级未测**，但同类动画（AuroraLightField 漂移）实测曾让 WindowServer +30pp。BrandMark 面积小得多，预计单条影响在 0.1～1pp 量级。 |
| 风险 | **极低**。删除 `@State spin` 和 `onAppear` 中的 `withAnimation` 块即可，视觉零变化（动画结果从未被读取）。 |
| 回退方式 | 恢复 `@State` 和 `onAppear` 两行。 |

### W2. `engineClientLog` 缺轮转上限（确认浪费）

| 维度 | 内容 |
|---|---|
| 位置 | `Sources/AuroraDrive/Core/EngineClient.swift:25`（`func engineClientLog`） |
| 消费方追溯 | 24 处调用点（:185-:928），均为连接/spawn/重连/心跳超时等**事件型日志**（非每帧），频率低。但函数体**每次调用 open→seek→write→close**（3-4 次 syscall），且**无任何轮转/上限**——与 `engineLog`（8MB + 64 次节流）、`pcapLog`（8MB + 64 次节流）、`dlog`（10MB + LogSink 缓冲）形成对比。 |
| 证据 | `grep -n 'Rotate\|MaxBytes\|CheckEvery\|\.1' EngineClient.swift` → 0 匹配。对比 `EngineMain.swift:58-76` 有 `engineLogMaxBytes` + `engineLogCheckEvery`；`CoordinateCapture.swift:605-615` 有 `pcapLogMaxBytes` + `pcapLogCheckEvery`。 |
| 可省多少 | 单次调用约 3-4 次 syscall（open/seek/write/close），24 处调用点频率低（事件型），**热路径影响小**；但 24/7 运行下日志文件**无上限增长**是真实问题（与 engineLog 修前的同类问题同源，engineLog 注释记录了「5.71h 写 6.16MB」）。 |
| 风险 | **低**。加轮转不改变任何日志内容，只加封顶。 |
| 回退方式 | 删除轮转检查代码即可恢复纯追加。 |

### W3. 9 个未编译的 MetalGoose 死文件（确认浪费——磁盘/认知负担，非运行时）

| 维度 | 内容 |
|---|---|
| 位置 | `Vendor/MetalGoose/` 顶层（不在 `Engine/` 子目录）：`GooseEngine.swift`(1890行) / `ContentView.swift`(891行) / `OverlayWindowManager.swift`(503行) / `MGHUD.swift`(409行) / `WindowCaptureManager.swift`(364行) / `AutoUpdater.swift`(310行) / `CaptureSettings.swift`(236行) / `GlobalHotkeyManager.swift`(74行) / `MetalGooseApp.swift`(10行)，合计 **4687 行**。 |
| 消费方追溯 | `Package.swift:189` 的 `sources` 白名单只有 `["Sources/AuroraDrive", "Vendor/MetalGoose/Engine"]`。`.build/scratch/release.yaml` 证实编译只纳入 `Engine/` 下 5 个文件。已编译代码对顶层文件的类型引用：`OverlayWindowManager` 仅在 `Stubs.swift:5` 注释中出现（已被桩替代）；其余类型 0 引用。 |
| 证据 | `find Vendor/MetalGoose -maxdepth 1 -name '*.swift'` → 9 个文件；`.build/scratch/release.yaml` grep `MetalGoose` → 仅 Engine/ 下 5 个。 |
| 可省多少 | **运行时 0**（不编译就不执行）。但造成：① grep 全仓时统计口径偏差（如 MTLTexture 85 vs 实际 42）② 认知负担（审计员/维护者误以为这些代码在跑）③ 磁盘 4687 行无用代码。 |
| 风险 | **无运行时风险**。删除或移动到 `legacy/` 目录即可。但需确认这些文件不是 MetalGoose 上游 GPL 源码的合规保留（`GooseUpscaler.swift:6-10` 提到「upstream-vendored GooseEngine kept byte-for-byte」——顶层 `GooseEngine.swift` 可能是上游原版，`Engine/GooseEngine.swift` 是裁剪版）。**删除前需人工确认 GPL 合规要求**。 |
| 回退方式 | git revert。 |

### W4. `shellQuote`（DaemonSetup.swift:67）零调用（确认死代码）

| 维度 | 内容 |
|---|---|
| 位置 | `Sources/AuroraDrive/Core/DaemonSetup.swift:67`，`private static func shellQuote(_ value: String) -> String` |
| 消费方追溯 | grep `shellQuote` 全已编译范围 → 仅定义处 1 处，**0 调用点**。 |
| 证据 | 启发式扫描 `private func refs<=1` → 仅此函数与 `tryReconnectSoon`（后者见 W5）。 |
| 可省多少 | **运行时 0**（未调用不执行）。纯死代码，约 5 行。 |
| 风险 | **无**。 |
| 回退方式 | git revert。 |

### W5. `tryReconnectSoon`（EngineClient.swift:405）零调用（确认死代码）

| 维度 | 内容 |
|---|---|
| 位置 | `Sources/AuroraDrive/Core/EngineClient.swift:405`，`private func tryReconnectSoon()` |
| 消费方追溯 | grep `tryReconnectSoon` 全已编译范围 → 仅定义处 1 处，**0 调用点**。重连逻辑实际由 `:409` 的 `connectTimer`（DispatchSource）承担。 |
| 证据 | 同 W4。 |
| 可省多少 | **运行时 0**。纯死代码。 |
| 风险 | **无**（重连由 connectTimer 覆盖，此函数是遗留）。 |
| 回退方式 | git revert。 |

### 已排除的浪费嫌疑（找到消费方，不是浪费）

| 候选 | 排查结论 |
|---|---|
| `selectedCluster`（MissionConsole.swift:4484，@State occ=1） | grep 确认仅在 `LargeMapCanvas` struct 内部使用，`@State` 声明 + 被 body 路径条件读取（通过 `clusters.first(where:)` 间接消费）。**有消费方**，启发式误报（occ=1 因读取在闭包内）。 |
| `showModelPicker`（AIAgentPanel.swift:1970，@State occ=1） | grep 确认被 `:2389` `ForEach(liveModels)` 和 `:2402` 菜单逻辑读取。**有消费方**。 |
| `categorySel`（MapWindow.swift:209，@State occ=2） | `:234` `categoryFilter: categorySel.enabled` 读取。**有消费方**。 |
| `layerFlags`（MissionConsole.swift:4487，@State occ=2） | `:4545` `flags: layerFlags` 读取。**有消费方**。 |
| RCWarn/StuckWarn/TakeoverWarn 的 `pulse` repeatForever（:1442/:1487/:1556） | 三处 `pulse` 均有 `opacity(pulse ? 0.85 : 0.42)` 和 `shadow(color: ...opacity(pulse ? ...))` 读取，且渲染条件为 `needsManualIntervention`/`takeoverActive`/`needsTakeover`（:706-727）。**有消费方，且是安全告警动画**，不是浪费。 |
| AuroraLightField 漂移动画（AuroraTheme.swift:682） | **已治理**：`:680` `onAppear` 中 `drift` 默认 false，仅 `AURORA_ENABLE_BG_DRIFT=1` 才开。`repeatForever` 仍在但 `value: drift` 不变 → Core Animation 不重算。**已优化**。 |
| MissionConsole tick 15Hz / netlocate 10Hz（leeway=0） | 均有 idleSkip 降频（8 倍 / 5 倍），待机降到 ~1.9Hz / ~2Hz。**已优化**。 |
| engineLog 每 15s 统计行 | 已从 5s 降到 15s（注释记录原占日志 70%），且有 8MB 轮转 + 64 次节流。**已优化**。 |
| dlog 热路径同步写盘 | 已改 LogSink 常驻句柄 + 8KB/200ms 缓冲刷盘，热路径 0 syscall。**已优化**。 |

---

## 4. 线程与 QoS 盘点（可降级项）

> 约束：只找纯浪费，不允许影响实时性/画质/帧率。

| 位置 | 当前 QoS | 用途 | 可否降级 | 理由 |
|---|---|---|---|---|
| `CaptureEngine.swift:183` | `.userInteractive` | SCStream 抓屏回调 | **不可降** | 抓屏是实时性红线，降级会导致掉帧 |
| `SpeedOCRReader.swift:201` | `.userInteractive` | OCR 推理队列 | **不可降** | 15Hz 时间闸，降级影响 OCR 实时性 |
| `InferenceEngine.swift:112` | `.userInteractive` | CoreML 推理 | **不可降** | 辅助决策实时性 |
| `InferenceEngineV2.swift:1410` | `.userInteractive` | V2 推理 | **不可降** | 同上 |
| `YoloEngine.swift:146` | `.userInteractive` | legacy YOLO 推理 | **不可降** | 同上 |
| `EngineMain.swift:487` | `.userInteractive` | socket 接收 | **不可降** | 命令实时性 |
| `EngineMain.swift:1271` | `.userInteractive` | 引擎主 tick | **不可降** | 30/45Hz 推理/控制/录制 |
| `MissionConsole.swift:6227` | `.userInteractive` | UI-local tick | **不可降** | 15Hz 驾驶态实时性（已有 idleSkip） |
| `MissionConsole.swift:6307` | `.userInteractive` | 网络定位 | **不可降** | 10Hz 实时性（已有 idleSkip） |
| `EngineClient.swift:171` | `.userInteractive` | 引擎客户端连接管理 | **可考虑降 `.userInitiated`** | 连接/重连非逐帧实时，但 socket I/O 需要低延迟，收益小风险中，**不建议动** |
| `AIAgentPanel.swift:263` | `.userInteractive` | 技能执行 | **可考虑降 `.userInitiated`** | 技能非实时路径，但按键注入有延迟敏感性，**不建议动** |
| `GooseEngine.swift:91` | `.userInteractive` | MetalGoose 处理队列 | **可降（插帧关时不跑）** | 仅 `upscaleEnabled=true` 时活跃，默认关，**无实际影响** |
| `WindowCaptureManager.swift:12` | `.userInteractive` | MetalGoose 抓屏 | 同上 | 同上 |
| **`GameModeDefender.swift:153`** | `.userInteractive` | 重主张循环 | **可降 `.userInitiated`** | 重主张非实时路径（3s 周期），静音音频 QoS 由 CoreAudio 自管不受影响。**但建议与降频（3s→5s）一起做**。 |
| `OpticalFlowBridge.swift` | 注释提及 userInteractive | 光流计算 | **不可降** | 自检注释实测 p95=3.53ms，实时路径 |

**结论**：绝大多数 `.userInteractive` 都在实时路径上，不可降级。唯一可安全降级的是 **GameModeDefender 的重主张队列**（且只降队列 QoS，不动静音音频），收益极小（3s 周期、单次 reassert 耗时可忽略）。

---

## 5. 文件 I/O 与日志

### 5.1 日志函数对照表

| 函数 | 位置 | 调用次数 | 轮转/上限 | 热路径写盘 | 状态 |
|---|---|---|---|---|---|
| `engineLog` | EngineMain.swift:78 | 56 | ✅ 8MB + 单备份 + 64 次节流 | 否（事件型 + 15s 统计行） | **已优化** |
| `engineClientLog` | EngineClient.swift:25 | 24 | ❌ **无轮转无上限** | 否（事件型） | **⚠️ 需修（W2）** |
| `pcapLog` | CoordinateCapture.swift:627 | 47 | ✅ 8MB + 单备份 + 64 次节流 | 否（突发流量时每秒上百次，但已有节流） | **已优化** |
| `dlog`(App) | AuroraDriveApp.swift:4909 | 52 | ✅ 10MB + LogSink 缓冲(8KB/200ms) | 否（LogSink 热路径 0 syscall） | **已优化** |
| `dlog`(Agent) | AIAgentPanel.swift:1735 | — | ✅ 回退链（无显式上限） | 否 | 基本OK，建议加上限对齐 App 版 |

### 5.2 /tmp 诊断日志清单（10 个 .log/.txt + 多个诊断文件）

已确认路径：`aurora_debug.log` / `aurora_defender.log` / `aurora_pcap.log` / `aurora_iopm_status.log` / `aurora_ocr_dbg.txt` / `aurora_anchor_diag.log` / `aurora_pcap_ui.log` / `aurora_debug_agent.log` / `aurora_debug_ui.log` / `upselftest_result.txt`。

- `aurora_defender.log`：✅ 8MB 轮转 + 状态变化才写（已优化）
- `aurora_pcap.log`：✅ 8MB 轮转 + 节流（已优化）
- `aurora_debug.log`：✅ 10MB 封顶 + LogSink 缓冲（已优化）
- `aurora_iopm_status.log`：仅启动时写一次（`write(toFile:atomically:)`），无增长风险
- 其余为诊断/自检产物，按需生成

---

## 6. 内存与泄漏面

| 维度 | 发现 |
|---|---|
| 每帧分配 | 主要在 `tickOnce()` → 推理路径，CVPixelBuffer 由 EngineClient 共享内存池管理（`AuroraDriveApp.swift:6272` 提及 pool），未见每帧 `malloc` 大块 |
| 长生命周期缓存 | `AuroraCache`（726行）有 capacity + costLimit + TTL + generation 淘汰，**有上限**；`ClusterCacheStore` 单例（MissionConsole.swift:4226）由 `@StateObject` 管理生命周期 |
| 无上限容器 | grep `append` 候选 30+ 处，全部是**局部构造返回值**（函数内 `var out = []; out.append(...); return out`），无长驻无界数组。`LogSink.pending` 有 `maxPendingBytes = 512KB` 上限 + 丢弃策略。 |
| freezeGuardBytes | `AuroraDriveApp.swift:328` 默认 0（关闭），曾有 768MB mlock 事故已修，现默认不锁 |
| Metal 显存 | `GooseEngine.swift:1338` `device.currentAllocatedSize` 只读统计，不泄漏；插帧关时不 attach MTKView |

**结论**：未发现无上限增长容器或每帧大块分配。内存面干净。

---

## 7. Top 可优化项表（按收益÷风险排序）

| 排名 | 项目 | 位置 | 当前成本 | 可省多少 | 质量影响 | 风险 | 回退方式 |
|---|---|---|---|---|---|---|---|
| **1** | **删除 BrandMark 死动画** | MissionConsole.swift:177+194 | 1 个 9s repeatForever 常驻动画，Core Animation 每帧重算 31px 圆+3 层 shadow | WindowServer 合成量减少（量级未测，预计 0.1-1pp） | **零**（动画从未被读取） | **极低** | 恢复 2 行代码 |
| **2** | **engineClientLog 加轮转** | EngineClient.swift:25 | 每次调用 3-4 次 syscall + 文件无上限增长 | 24/7 运行下封顶磁盘占用（对齐 engineLog/pcapLog 的 8MB 策略） | **零** | **低** | 删除轮转代码 |
| **3** | **GameModeDefender 重主张降频 3s→5s** | GameModeDefender.swift:155 | 3s 周期 .userInteractive 唤醒 | 唤醒频率降 40%（静音音频保留） | **无**（40s 压制窗口内 5s 仍够 8 次复查） | **中**（需实测确认 5s 间隔下 nice 不被压过） | 改回 3.0 |
| **4** | **清理 9 个未编译死文件** | Vendor/MetalGoose/ 顶层 | 4687 行磁盘/认知负担 | 运行时 0；消除 grep 口径偏差 | **零** | **低**（需确认 GPL 合规） | git revert |
| **5** | **删除 shellQuote / tryReconnectSoon 死函数** | DaemonSetup.swift:67 / EngineClient.swift:405 | 各约 5-10 行死代码 | 运行时 0 | **零** | **无** | git revert |
| **6** | **GameModeDefender 队列 QoS 降级** | GameModeDefender.swift:153 | .userInteractive | 降到 .userInitiated（静音音频不受影响） | **无** | **低** | 改回 .userInteractive |

> ⚠️ **排名 3 和 6 涉及 GameModeDefender**，必须严格遵循 §2.2 的分别处置原则：**只动重主张循环的频率和队列 QoS，绝不动 `startSilentAudio()` 和 `reassert()` 中的音频自愈逻辑**。

---

## 8. 明确排除的方向（附证据）

| 方向 | 排除理由 | 证据 |
|---|---|---|
| VideoToolbox 硬件编解码 | 全仓 0 处实际调用 | `VTCompressionSession` grep → 0；唯一命中 `OpticalFlowBridge.swift:16` 是注释中被否决的方案 |
| OpenCV OpenCL/CUDA | 编译期关闭 | `Vendor/OpenCVFlow/README.md:72` `-DWITH_OPENCL=OFF`；`cv::UMat`/`ocl::`/`cuda::` grep → 0 |
| MPSGraph / MetalPerformanceShaders | 已编译范围 0 import | `import MetalPerformanceShaders` grep → 0 |
| NSVisualEffectView / 毛玻璃 / CABackdropLayer | 已编译范围 0 处 | grep → 0 |
| 阴影导致每帧重算 | `.shadow(` 68 处，但均为静态阴影（非动画驱动） | grep `.shadow(` → 全部是固定 `shadow(color:radius:)`，无 `shadowPath` 动画 |
| CADisplayLink / CVDisplayLink | 0 处实际调用 | grep → 2 处均为 GooseEngine.swift:817 注释 |
| TimelineView 逐帧驱动 | 0 处 | grep → 0 |
| addAnimation / CABasicAnimation 直接 CoreAnimation | 0 处 | 项目用 SwiftUI `withAnimation`，不直接调 CA API |
| PrioritySetup.install | 已 deprecated | `PrioritySetup.swift:55` `@available(*, deprecated)`，改走 PrivilegePill |
| 录制链用 GPU | 不碰 GPU | `RecordEngine.swift` 只用 NSBitmapImageRep.png，无 AVAssetWriter/VTCompressionSession（`11-gpu-users.md` §2.5 已核实） |

---

## 9. 未测项清单

| 项目 | 为什么未测 | 预期测法 |
|---|---|---|
| BrandMark 死动画的实际 WindowServer 开销 | 未启动 App（单实例锁约束） | `ioreg` 按 pid 归因 + 对比删除前后 WindowServer 占用 |
| `InferenceEngine.swift:164/206` 的 `.all` 实际派发 | 未启动 App | `sample` 引擎进程 + Espresso 栈采样（同 `2-yolopx.md` 方法） |
| `InferenceEngineV2.swift:1733/1881` / `YoloEngine.swift:187` 的 `.all` | 默认路径不走 | 需切换档位触发 |
| GameModeDefender 重主张降频 3s→5s 的防压制效果 | 需长时间 Game Mode 实测 | A/B 对比：3s vs 5s，观察 nice 是否被渐进压制（40s 窗口内 5s 仍有 8 次复查） |
| Vision 框架内部 ANE/GPU 派发 | Vision 调度不透明 | 无法静态判定 |
| MetalGoose 顶层 9 文件的 GPL 合规属性 | 需法律/合规确认 | 人工审查 `GooseUpscaler.swift:6-10` 的 GPL 声明与上游关系 |

---

*报告结束。所有结论基于静态分析，引用的实测数字均标明出处（`docs/perf-audit-gpu/11-gpu-users.md`）。未测项已如实标注。*
