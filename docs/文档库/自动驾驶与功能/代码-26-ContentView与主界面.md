# 代码-26 ContentView 与主界面

> 覆盖源文件：**旧版 AuroraDriveApp.swift 下部（2164 行起）的 ContentView 已在 UI 大改版中删除**。现 ContentView = `App/MissionConsole.swift`（3934 行）:2772。
>
> **⚠️ 2026-09-25 深度复核块（本档旧内容已整体失效）**：
> ① 旧 ContentView + FloatingMinimap + TopToolbar（本档原描述对象）**全部删除**——被"任务控制中心"取代（网页原型一比一原生翻译，见 代码-27）；
> ② 新 ContentView 在 **MissionConsole.swift:2772**：`.app` 整体布局 = TopBar + MainGrid（1fr 344px 372px 三栏）+ 浮层（MapOverlay/SkillOverlay）+ AI 对话卡；
> ③ 本档旧正文保留仅作历史参考（了解大改版前的布局思路）；**阅读新界面结构请看 代码-27 与源码 MissionConsole.swift**；
> ④ 仍在 AuroraDriveApp.swift 下部且活跃的视图：BPFPasswordSheet/DaemonInstallSheet（权限弹窗）、ObstacleOverlay（检测框叠加层）、FrameHostView/UpscaleFrameHostView（画面直绘宿主）——这些的描述见 代码-24 复核块第 ⑥ 条。

## 一、ContentView 主布局与 onAppear（第 2168–2334 行）

**`ContentView`（struct: View，第 2168–2169 行）**——主布局：顶部工具栏 + 左画面 + 右侧边栏。

**状态（第 2169–2173 行）**：`@State var state = DriveState()`（**每实例一份状态**）+ `tickTimer/tickDispatchSource/netLocDispatchSource`（两个定时器句柄）。

**body 布局（第 2175–2204 行）：**

```
ZStack(alignment: .top) {
    HStack(spacing: 0) {
        if AgentSkillCenter.shared.isPanelOpen {          // AI 面板展开时
            AIAgentPanelView(center:).frame(width: 348)
                .transition(.move(edge: .leading))
        }
        GameViewportView(state:).frame(maxWidth: .infinity, maxHeight: .infinity)
        SidebarView(state:).frame(width: 360)
    }
    .padding(.top, 44)
    .animation(.spring(0.45, 0.74), value: isPanelOpen)
    TopToolbar(state:)
    AIAgentEdgeTab(center:, panelWidth: 348)              // 左缘箭头，zIndex(20)
}
.background(Theme.bgPure)
.preferredColorScheme(.dark)
```

- **主内容行注释（2177–2178 行）**："AI 面板展开时占左侧 348pt，主 UI（游戏视口+侧边栏）**整体右移——往外扩展而非覆盖，网络地图/悬浮小地图永不被遮挡**"
- 两个 `.sheet`：BPFPasswordSheet / DaemonInstallSheet（权限安装引导）
- **`.onDisappear`（2211–2218 行）**：三个定时器全部 invalidate/cancel + 置 nil

**`.onAppear`（第 2219–2332 行）——tick 驱动与初始化七步：**

1. **tick 驱动（2220–2233 行）**：**用 DispatchSource 替代 main RunLoop Timer——main RunLoop Timer 会被 App Nap 冻结（游戏全屏时 tick 掉到 8Hz）；DispatchSource 在独立高优先级队列上运行，不受 App Nap 影响**——`DispatchQueue("com.aurora.tick", .userInteractive)` + `schedule(repeating: 1.0/30.0, leeway: .nanoseconds(0))`（**leeway 0：零容差，30Hz 红线**）→ 事件主线程 `state.tick()`；`tickTimer = nil`（不再用 Timer 类型）
2. **Daemon 检查（2235–2245 行）**：isDaemonMode = `isRunningAsDaemon()`、daemonInstalled = `isDaemonInstalled()`；`needsInstall()` → showDaemonInstallSheet = true（安装引导）
3. **BPF 权限检查（2247–2261 行）**：`needsInstall() || !PrioritySetupManager.isLaunchDaemonInstalled()` → 同一密码弹窗（**一次输入装齐 BPF + 性能提权**——源注释："必须并入首条件：若拆成后续 else if，会被 isBPFAvailable 分支截胡导致提权器永远装不上"）；isBPFAvailable → bpfAuthorized = true；isLaunchDaemonInstalled → tryImmediateChmod + 重查
4. **网络定位定时器（2263–2271 行）**：nlQueue（.userInteractive）+ **repeating 1.0/10.0（注释写 4Hz，实际 10Hz——注释滞后）** → `state.runNetworkLocateStep()`
5. **`--auto-drive` / `--auto-seconds`（2272–2289 行）**：**自主测试入口——启动后自动开始驾驶（模拟人工点击「开始驾驶」），到点自动退出，用于无人值守的端到端验证（跑完读 /tmp/aurora_debug.log）**——`--auto-drive`：1.5s 后 `state.startDriving()`；`--auto-seconds N`：N 秒后 `exit(0)`
6. **`--upscale-selftest`（2290–2295 行）**：0.5s 后 `runUpscaleSelfTest()`（**此入口在 onAppear 而非 Launcher：需要 MTKView/NSApp 上下文**）
7. **AI Agent 面板初始化（2297–2332 行）**：`AgentSkillCenter.shared.configure(control:capture:)`（注入按键/截屏引擎——**人类 + AI 共用执行通道**）；`--agent-selftest` → 1.2s 后 configure + `AgentSelfTest.run(center:)`；`--agent-ui-shot` → `AgentUIShot.run()`；`--agent-layout-shot` → `runLayoutCompare()`
   - **注释（2324–2331 行）**：`--auto-login` 已移到 AppDelegate（与 UI 渲染解耦）；`--agent-command` 派发已移到 AppDelegate（**命令模式下窗口被 orderOut、本 onAppear 可能不触发，派发不能依赖视图渲染**）
   - **configure 被调用了 3 次（2299/2306、2327 行）**——幂等（重复注入无副作用，最后一次生效）

## 二、FloatingMinimap 悬浮小地图（第 2337–2564 行）

**`DirectionTriangle`（Shape，第 2342–2351 行）**——朝向指示三角形（与 GameMapView 内的私有 Triangle 同款）：midX/minY → maxX/maxY → minX/maxY 闭合。

**`FloatingMinimap`（struct: View，第 2353–2357 行）**——**常驻左上角悬浮小地图（不依赖 GameMapView，应用启动即显示）**：

- `@Bindable var state: DriveState`
- `@StateObject tileCache = MinimapTileCache()`——**瓦片缓存：应用启动即 onAppear 触发后台切图，与驾驶/定位状态无关（用户要求：不开自动驾驶也要显示小地图当作地图用）**

**尺寸与 hitTesting（第 2359–2368 行）——踩坑记录：**

```swift
minimapBody
    .padding(12)
    .frame(width: 224, height: 224)   // 固定 224×224（200 小地图 + padding 12×2）
    .allowsHitTesting(false)
    .onAppear { tileCache.ensureLoaded() }
```

- **源注释（2360–2363 行）**："之前用 `.frame(maxWidth:.infinity, maxHeight:.infinity)` 占满全窗 + zIndex(15)，**即使 allowsHitTesting(false)，占满的高 zIndex 层在部分 SwiftUI 版本下仍会拦截 hit，导致 sidebar 按钮点不到。固定尺寸只占左上角，彻底不挡按钮**"

**状态判定（第 2373–2384 行）：**

| 成员 | 说明 |
|---|---|
| `size`（static） | 200（MinimapTileCache.minimapPx） |
| `hasValidLocate`（计算属性） | **网络定位是否有效**：score > 0.3 && x/y ∈ (0, 13056)——**networkLocateX/Y 是 13056 像素坐标（map-2026-08 参考坐标系，非百分比）** |
| `gameRunning` | `hasValidLocate \|\| state.isDriving` |

**minimapBody（第 2388–2431 行）——三分支底图：**

1. **有定位（2392–2396 行）**：`tileCache.tileAt(mapPixelX:mapPixelY:)`——**显示角色当前所在瓦片（局部放大），与参考 MINI_MAP_ROI 语义一致**
2. **无定位（2397–2399 行）**：`tileCache.overview`——**全图缩略，让小地图始终是可用地图（非空白）**
3. **都没有（2400–2401 行）**：placeholder（加载中/错误提示）
4. 叠加：gridOverlay（7×7 网格线，青 0.15/0.5pt）+ statusBadge + cursor（有定位时）
5. 外框：cyan 0.5 描边 1.5pt + 右下角徽章（瓦片索引 "x,y/8×8" 或 "切图 Nms"）+ shadow

**底图视图（第 2435–2477 行）：**

- `mapImage(_:)`：NSImage(cgImage:size:200) → resizable + clipShape 圆角
- `overviewImage(_:)`：同构 + **scaledToFill + clipped()**（全图填满裁切）
- `placeholder`：黑底 0.85 + **loadError 时红色警示（exclamationmark.triangle + 错误文本）**——**加载失败显式可见，不静默**；否则 ProgressView + "加载地图瓦片…"

**statusBadge（第 2498–2536 行）**——状态徽章（左上）：

- 状态点：gameRunning ? 绿 : 红（发光 shadow）
- **文案：`gameRunning ? "一环已打开" : "一环未打开"`**（9pt bold rounded）
- 有定位：坐标（monospaced 8pt）+ **置信度（`Int(score × 100)%`，>0.7 青 : danger 红）**
- 驾驶中无定位："等待网络定位…"；未驾驶："未开启驾驶"

**cursor（第 2540–2563 行）**——光标（**瓦片内相对位置**）：

- `cx/cy = MinimapTileCache.inTileOffset(mapPixel:)`（0~200 瓦片内偏移，见 代码-18）
- 三层：cyan 0.3 光晕圆（22pt）+ cyan 实心圆（10pt 白描边）+ **DirectionTriangle 白色朝向三角（`rotationEffect(.degrees(networkLocateHeading))` + offset y -12）**
- `.position(x: cx, y: cy)` + spring 动画（0.25/0.85，value: x/y——**位置变化平滑过渡**）

## 三、upscaleBadge / BPFPasswordSheet / DaemonInstallSheet（第 2690–2912 行）

**`upscaleBadge`（private 计算属性，第 2690–2715 行）**——插帧状态徽章（五分支判定）：

| 条件（优先级从上到下） | 颜色 | 文案 |
|---|---|---|
| `!upscaleSupported` | danger | "插帧不可用" |
| `upscaleEngineError` 非空 | danger | "插帧异常 · err" |
| `!upscaleEnabled` | textTertiary | "插帧 · 关" |
| `!isDriving` | textTertiary | **"插帧 · 待机"**——源注释："**没在驾驶 = 没有新帧可插（停止/暂停后不应继续显示'插帧中'）**" |
| `upscaleLive` 非空 | cyan | "插帧中 · live（产出/透传/输入→输出 fps）" |
| else | cyan | "插帧中 · 等待" |

- 渲染：9pt monospaced semibold + lineLimit(1) + Capsule 底（col 0.12）+ 描边（0.35）+ help（"插帧实时状态：产出=插入的中间帧 输出=总呈现帧 透传=未插帧直通 帧率"）

**`BPFPasswordSheet`（struct: View，第 2720–2816 行）**——BPF 权限安装弹窗（**灵动岛风格**）：

- 状态：`@Bindable state` + `@State password = "123456"`（**默认密码占位——用户实际输入自己的管理员密码**）
- 头部：key.fill 图标（发光）+ "安装系统权限" 标题 + 说明（"BPF 网络权限 + 性能提权（nice -20 防游戏挤占）\n输入管理员密码，安装后永久生效，重启自动恢复"）
- SecureField（monospaced 14pt + bgPure 底）；安装消息：`bpfInstallMessage` 非空显示（**含"成功/已安装"→ cyan，否则 orangeRed**）
- **安装按钮（2762–2803 行）**：`state.bpfInstalling = true` → global 队列（.userInteractive）：
  - `BPFSetupManager.install(password: pwd)`——BPF 网络权限
  - **`PrioritySetupManager.install(password: pwd)`——同一密码顺带装性能提权（renice -20 守护），无需额外按钮**
  - 主线程回写：bpfInstalling=false、消息拼接（**提权成功附加"；性能提权已生效（nice -20）"；提权失败但 BPF 成功附加"；性能提权未装：…"**）、result.success → bpfAuthorized = true + 1.5s 后自动关弹窗
- disabled（bpfInstalling \|\| password.isEmpty）；.ultraThinMaterial 底 + cyan 描边 + frame(width: 340)

**`DaemonInstallSheet`（struct: View，第 2821–2912 行）**——Daemon 安装引导弹窗（**首次启动时引导用户安装为 LaunchDaemon（最高优先级）**）：

- 头部：shield 徽标 + "安装系统级服务" + 说明（"游戏全屏时 macOS 会冻结后台 App\n安装为系统服务可获得最高调度优先级\n防止被冻结，只需输入一次密码"）
- **安装按钮（2865–2898 行）**：global 队列（.userInitiated）→ `DaemonSetupManager.currentExecutablePath()`（**当前可执行文件路径**——LaunchDaemon plist 要指向它）→ `DaemonSetupManager.install(password:pwd:currentExecutablePath:)` → 主线程回写（daemonInstalled = true + 2.0s 后自动关弹窗）
- **"暂不安装"按钮**（不是"取消"——语义：可以以后再装）；frame(width: 360)

## 四、GameViewportView 叠加区与框选手势（第 2915–3140 行）

**`GameViewportView`（struct: View，第 2919–2924 行）**——左侧游戏画面叠加区：

- `@Bindable var state: DriveState` + `@State dragStart/dragCurrent`（**手动框选：拖拽起点/当前点（视口坐标）**）

**body 的 GeometryReader ZStack（第 2926–3085 行，自下而上八层）：**

1. **黑底**：`Color.black`
2. **真实游戏画面（2931–2978 行）——三分支**：
   - `state.isStreaming` + `upscaleEnabled` → `UpscaleFrameHostView(host: upscaleHost)`——**引擎模式下 UI 不采集、只显示：插帧的帧来自引擎（全分辨率经共享内存送来），由 tickEngineMode 喂给 upscaleHost，所以两种档位都能正常显示**；onChange(upscaleEnabled) 关闭时 clear
   - isStreaming 非 upscale → `FrameHostView(host: frameHost)`（普通直绘）
   - 未启动 → 纯黑 + 待机提示（**权限提示优先级：辅助功能 > 屏幕录制**——"需要辅助功能权限/需要屏幕录制权限 + 授权路径"，都正常 → "点击右侧启动按钮"）
3. **AI 识别叠加层（2980–2985 行）**：`ObstacleOverlay(active: isDriving, detections: state.effectiveDetections, sourceSize: screenSize, lockedTarget: yoloEngine.lockedTarget, isLocked: yoloEngine.isLocked)`——**本地模式=YoloEngine / 引擎模式=引擎回传（effectiveDetections 统一读取点）**
4. **小地图（2987–2990 行）**：`MinimapLocatorView(state:)` + allowsHitTesting(true)（**移植版，显示网络定位位置，放在左上角**）
5. **速度表 ROI 调试框（2992–2993 行）**：`SpeedROIOverlay(sourceSize:)`——红框=速度表区域，蓝框=3 个数字槽位
6. **手动框选预览（2995–3007 行）**：拖拽中显示虚线框（orangeRed 0.95 + dash [6,4]，>4px 才显示）
7. **锁定状态悬浮提示（3009–3036 行）**：isLocked 时——"🎯 lockMessage" 胶囊 + **取消锁定按钮（xmark.circle.fill → clearLock()）**——allowsHitTesting(true)
8. **装饰与 HUD（3038–3083 行）**：地平线光晕（**FSD 风格装饰**，isDriving 时 0.16 : 0.05，allowsHitTesting false 不挡画面交互）+ **左下角 HUD：REC（录制中红点）/ FRAMES 帧数**（Capsule 胶囊）+ **底部键盘可视化条**：`KeyboardBar(state: agentMode:)`——显示 WASD + 空格 + Shift，按下时变青绿色发光，观察控制引擎的按键状态实时高亮
- `.clipped()`——裁剪出界内容

**框选手势（第 3086–3134 行）——锁定追踪目标：**

- `.contentShape(Rectangle())` + `DragGesture(minimumDistance: 0)`（**0 = 点击也算**）
- onChanged：`guard state.isDriving`（**驾驶中才允许框选**）→ dragStart/dragCurrent 记录
- onEnded（3096–3133 行）：
  1. `defer { dragStart = nil; dragCurrent = nil }`（无论如何清拖拽状态）
  2. **视口坐标 → 源图归一化（3102–3109 行）**：**基准用 screenSize（本地/引擎、直绘/插帧两条显示路径都有值）；不用 frameHost.latestSize——插帧路径画面由 MetalGoose 直渲、不经过 frameHost，读它会拿到空值 → 整个框选被 guard 拦掉（选不了）**——`srcSize = state.screenSize ?? state.frameHost.latestSize` → `viewToSourceNorm` × 2（起止两点）→ 归一化 rect
  3. **拖得够大（>0.05）= 手动框选锁定（3115–3117 行）**：`state.yoloEngine.setLock(x: rect.midX, y: rect.midY, width:height:)`
  4. **点选（3119–3131 行）**：**只有「点在检测框上」才锁定该框；点空白不再生成幽灵框**——源注释："**注意检测结果必须走 effectiveDetections——引擎模式下框来自后台引擎，读 yoloEngine.detections 永远是空数组，会退化成「点哪都建一个 0.12 的框」**"——`dets.first(where: hitTest($0, center, margin: 0.03))` → setLock(to:)；**未直接命中时找最近框（`normDist < 0.12`）→ setLock(to: nearest)**；**点空白处：不生成任何框（旧行为会留下永不消失的 0.12 幽灵框）**
- **`.overlay(alignment: .trailing)`（3135–3140 行）**：与侧边栏之间的渐变分界光带（cyan 0.22→clear，宽 1）

## 五、框选辅助函数与 KeyboardBar / KeyCap（第 3144–3253 行）

**两个框选辅助函数（private static，第 3144–3152 行）：**

| 函数 | 签名 | 说明 |
|---|---|---|
| `normDist` | `(_ d: Detection, _ p: CGPoint) -> Double` | **检测框中心到点的归一化距离**——`hypot(d.x - p.x, d.y - p.y)` |
| `hitTest` | `(_ d: Detection, _ p: CGPoint, margin: Double) -> Bool` | **点是否落在检测框内（含少量外扩余量，方便点小目标）**——`\|p.x - d.x\| <= d.width/2 + margin && \|p.y - d.y\| <= d.height/2 + margin`（调用方 margin=0.03） |

**`KeyboardBar`（struct: View，第 3163–3218 行）——底部键盘可视化条（显示按键状态）：**

- **两种模式（3159–3162 行注释）**：**AI Agent 模式：显示所有游戏键（WASD + F/E/ESC/Q/R + 1-4）；驾驶模式：显示 WASD + 空格 + Shift**；active=true 时青色发光，**来自物理键盘或 AI 注入**
- `isAIHeld(_ key: GameKey)`：`state.controlEngine.isHeld(key)`——**AI 注入的键**
- `isPhysicalHeld(_ keyCode: CGKeyCode)`：`state.keyboardMonitor.isHeld(keyCode)`——**物理键盘的键**
- **agentMode 网格（3178–3202 行）**：14 个 KeyCap——移动 W/A/S/D（`isAIHeld(.w) \|\| isPhysicalHeld(87)`）+ 交互 F/E/␣（wide）+ UI ESC（narrow）/Q/R + 数字 1-4——**AI 注入（GameKey 枚举）或物理键（HID 码 87/65/83/68…）任一按下即高亮**；深青底（0,0.1,0.15, 0.85）+ cyan 0.4 描边
- **驾驶模式条（3203–3216 行）**：6 个 KeyCap——W/A/S/D/␣(wide)/⇧——**物理键码走 `state.controlEngine.keyMap.keyCode(for:)`（KeyMap 语义键，virtualKey 13/0/1/2/49/56）**——注释（3206 行）——黑 0.55 底 + 白 0.08 描边
- **⚠️ 注意两种模式用不同的键码体系**：agentMode 用硬编码 HID 码（87/65/83/68），驾驶模式用 KeyMap（virtualKey 13/0/1/2）——与 代码-08 的两套键码体系一致

**`KeyCap`（struct: View，第 3224–3253 行）**——单个键帽：

| 参数 | 说明 |
|---|---|
| `label / active` | 键名 / 是否按下（true=青绿色发光，false=暗色边框） |
| `wide` | 是否加宽（空格键，60pt） |
| `narrow` | 是否缩小（功能键，28pt；普通 22pt） |

- 渲染：active 时**字体变大（11 vs 10）+ 黑字 + 青绿底（0,1,0.6）+ 描边 + 发光 shadow radius 6**；非 active 暗色白 0.04 + cyan 0.3 描边；`.animation(.easeInOut(0.08), value: active)`——按下瞬间快速过渡

## 六、坐标变换公共函数与两个 Overlay（第 3255–3463 行）

**引用关系（grep 全 Sources 实测）**：`ObstacleOverlay` 唯一调用方 = GameViewportView:2981（active/detections=effectiveDetections/sourceSize/lockedTarget/isLocked 五参数）；`SpeedROIOverlay` 唯一调用方 = GameViewportView:2993（sourceSize）；`aspectFillLayout` 3 个调用方（viewToSourceNorm:3336、SpeedROIOverlay:3350、ObstacleOverlay:3403）；`viewToSourceNorm` 唯一调用方 = GameViewportView 框选手势:3108–3109；**`LaneCanvas` 全项目零调用方——死代码**（曾的游戏视口背景车道线装饰，GameViewportView 改用真实画面流后遗留，未被删除）。

**`LaneCanvas`（struct: View，第 3256–3308 行，⚠️ 死代码）**——Canvas 绘制：透视车道线（青色发光 + 滚动虚线）：

- `phase: Double`（**虚线滚动相位**——动画驱动）/ `active: Bool`（驾驶时 1.0 : 0.28 不透明度）
- `laneXs = [0.06, 0.30, 0.50, 0.70, 0.94]`——底部五条车道线 x 比例
- 绘制：horizonY = 0.42 高、灭点 = 中点——**五条二次贝塞尔曲线（底部 → 灭点）**，三层描边（外辉光 10pt/0.18 + 中辉光 4.5pt/0.35 + 核心亮线 2.2pt；**中间线实线、两侧滚动虚线 dash [26,20] dashPhase: -phase**）+ 灭点光源椭圆（120×28/0.5）+ 地平细线（1pt/0.22）
- **保留价值**：若未来做"无画面时的驾驶舱背景动画"，这个视图直接可用（`LaneCanvas(phase: 动画相位, active: isDriving)`）——删除前先确认不再需要

**`aspectFillLayout(source: CGSize?, view: CGSize) -> (origin: CGPoint, size: CGSize)`（internal func，第 3318–3326 行）——aspect-fill 变换参数（坐标契约的根）：**

- **坐标换算说明（3312–3316 行注释）**："YOLO 输出的是「整帧归一化坐标」，而游戏画面用 .aspectRatio(.fill) + .clipped() 显示，源画面和视口宽高比不一致时会被裁切。**这里必须复现同样的 aspect-fill 变换，否则画出来的框会整体偏移/缩放错位**"
- `guard src.width/height > 0 else { return (.zero, view) }`——**sourceSize 为 nil 时退化为直接铺满**（无源尺寸信息，框按视口全幅换算）
- `scale = max(view.width/src.width, view.height/src.height)`——**fill 语义：取大者（铺满 + 裁切）**
- `drawn = src × scale`；origin = `(view - drawn)/2`（居中裁切的负偏移）

**`viewToSourceNorm(point:source:view:) -> CGPoint?`（internal func，第 3330–3341 行）——aspect-fill 逆变换（框选手势用）：**

- `(point - origin) / drawn` → 归一化；**超出源图绘制区域的点返回 nil**（`guard nx/ny ∈ [0,1]`）——视口黑边上的点不进框选

**`SpeedROIOverlay`（struct: View，第 3345–3378 行）**——速度表 ROI 调试框（**在 App 预览画面上画框，显示 OCR 在看哪里**）：

- Canvas 内：`aspectFillLayout` → **红框 = CaptureEngine.speedROINorm 速度表区域**（2pt 描边 + 0.1 填充）→ **三个青框 = SpeedOCRReader.slotCentersNorm/slotWidthNorm/slotYMinNorm/slotYMaxNorm 数字槽位**（`(cx - slotW/2)` 中心换算 + 1.5pt 描边）——**与 OCR 实际裁剪用同一组常量，所见即所裁**
- `.allowsHitTesting(false)`——纯显示不挡交互

**`ObstacleOverlay`（struct: View，第 3380–3463 行）**——障碍框：**YoloEngine 的真实检测结果，按类别着色 + 标签 + 置信度**：

| 参数 | 说明 |
|---|---|
| `active: Bool` | false 直接 return（不画） |
| `detections: [Detection]` | 本帧检测结果（**归一化中心点 + 宽高**） |
| `sourceSize: CGSize?` | 源画面像素尺寸，用于 aspect-fill 裁切换算；**nil 时退化为直接铺满** |
| `lockedTarget: Detection?` | 锁定目标（手动框选/点选后由 YOLO 追踪），画金色高亮框 |
| `isLocked: Bool` | 锁定状态 |

**类别配色（private static，第 3391–3398 行）**：`.pedestrian → Theme.danger`（行人：红）/ `.car → Theme.cyan`（车辆：青）/ `.sign → 黄（1,0.82,0.25）` / `.obstacle → Theme.orangeRed`（其他：橙）。

**① 检测框（3404–3429 行）**：

- 逐框：`danger = d.isInDangerZone()`（**默认参数 0.18/0.45——与 RuleController 的决策同一函数**）→ 框（`max(w×t.width, 2)` 防零尺寸 + 圆角 4）
- 填充（danger ? 0.18 : 0.08）+ **描边（danger ? 2.2 : 1.4pt，0.9）**——**源注释（3414 行）："无阴影直接描边：去掉逐框 drawLayer 的高斯模糊（最贵部分），描边已足够醒目"**——性能优化：Canvas 内逐框高斯模糊曾是最贵的绘制
- **文字胶囊（3418–3428 行）**："**resolve/measure 各只调一次**；胶囊在框顶上方，底部距框顶 16pt"——`ctx.resolve(Text(...9pt bold monospaced 黑字))` → `measure` → 胶囊 rect（**capX clamp 到视口内、capY = max(box.minY - 16 - h - 4, 4)**）→ fill（类别色 0.9）+ draw

**② 锁定目标（3430–3459 行）**：

- `isLocked && lockedTarget` 时：金色框（orangeRed 3pt 描边 + 0.12 填充，`max(w, 6)` 防过小）+ **四角准星 14pt**（四角各两条 14px 线段，`±sx/±sy` 方向）+ **"🎯 rawName LOCK" 文字胶囊**（10pt heavy monospaced，距框顶 18pt）
- `.allowsHitTesting(false)`——纯显示（锁定取消按钮在 GameViewportView 的悬浮提示层，见单元四）

## 七、SidebarView / StatusPanel / ModeGroupChip / ConfidenceBar（第 3654–3861 行）

**引用关系（grep 实测）**：`StatusPanel/ControlPanel/ConfigPanel` 唯一调用方 = SidebarView:3664–3666（六面板前三个）；`ModeGroupChip` 唯一调用方 = StatusPanel:3693；`ConfidenceBar` 唯一调用方 = StatusPanel:3708；**`m9Status` 与 `engineConnected` 的显示位置是 TopToolbar:2656–2670（顶部工具栏引擎状态芯片），不在 StatusPanel**；`speedOCR.activeEngine/engineNotice` 引用 = StatusPanel 车速标签（3730–3749）+ 提示条（3792）+ tick 调试摘要（2074/2076）。

**`SidebarView`（struct: View，第 3658–3676 行）——右侧毛玻璃侧边栏**：ScrollView（无指示条）× VStack（spacing 14）× **六个面板**：`StatusPanel → ControlPanel → ConfigPanel → TrainingPanel → GameMapCard → LogViewerPanel`；背景：`.ultraThinMaterial.opacity(0.55)` + `Color.black.opacity(0.55)` 双层（毛玻璃 + 压暗）。

**`StatusPanel`（struct: View，第 3682–3807 行）——状态面板（GlowCard）：**

1. **驾驶模式芯片（3690–3695 行）**：`ForEach(DriveModeGroup.allCases) { ModeGroupChip(group:, active: state.isDriving && g.contains(state.mode)) }`——**内部 4 档合并为 2 个用户可见档位（端到端主驾 / 规则）**；组内任一内部档位处于当前 mode 时整组高亮
2. **置信度（3697–3709 行）**：`%.1f%%`（12pt bold monospaced cyan）+ `ConfidenceBar(value:)`
3. **车速 + FPS + 禁用控制（3711–3790 行）**：
   - **大车速数字（3713–3724 行）**：52pt heavy rounded 白字 + cyan 发光 shadow 12 + `contentTransition(.numericText())`——**★ 三位数（>99）时 52pt 宽度暴涨，曾被容器挤压折成两排：lineLimit(1) 禁止折行；minimumScaleFactor(0.55) 空间不足时缩字；fixedSize(horizontal: true) 让文本按内容优先取宽，不被压扁换行**（3719–3724 行注释）；`speedKmh < 0` 显示 "--"
   - **车速识别引擎标签（3728–3749 行）**：`state.speedOCR.activeEngine.rawValue`——**PP-OCRv6（主，青）/ CNN（备用降级，橙）**；**@Observable 嵌套：activeEngine 变化时 body 自动刷新**；Capsule 底 + 描边 + help（"车速识别引擎：PP-OCRv6 微调模型（主）/ CNN（PP-OCR 故障时自动切换）"）
   - **禁用控制按钮（3752–3780 行）**：`state.controlDisabled.toggle()`——hand.raised 图标（**开启=黑字压橙红底**"控制已禁"）；help（"已禁用 AI 控制：模型仅检测画面，人工驾驶"）
   - FPS（22pt monospaced）+ "FPS"（9pt tracking 1.5）
4. **引擎切换/加载提示条（3791–3803 行）**：`speedOCR.engineNotice` 非空显示——exclamationmark.triangle + 文本（orangeRed，lineLimit 2）——"PP-OCR 故障降级 CNN、备用缺失等"

**`ModeGroupChip`（struct: View，第 3811–3842 行）**——驾驶模式分组芯片（**2 个用户可见档位：端到端主驾 / 规则**）：

- icon（SF Symbol：brain.head.profile / shield.lefthalf.filled）+ rawValue（11pt semibold）+ desc（9pt，lineLimit 2，0.85 透明度）
- **高亮时深色字压在亮青底上（3830 行）**：active → `.black` 压 `Theme.cyan` 底 + shadow 10；非 active → textSecondary 压白 0.05 底 + 白 0.09 描边
- `.animation(.spring(response: 0.3), value: active)`

**`ConfidenceBar`（struct: View，第 3844–3861 行）**——置信度条：GeometryReader × ZStack（leading）——白 0.08 Capsule 底 + **LinearGradient（cyanDim → cyan）进度条**（`max(6, width × value)`——**最小 6pt 保证 0 值时也有一丝可见**）+ cyan shadow 8；高度 8；`.animation(.easeOut(0.25), value: value)`。

## 八、ControlPanel / ConfigPanel / TrainingPanel / LogViewerPanel（第 3864–4379 行）

**引用关系（grep 实测）**：ControlPanel/ConfigPanel/TrainingPanel/GameMapCard/LogViewerPanel 全部唯一调用方 = SidebarView:3664–3669；`TrainButton` 唯一调用方 = TrainingPanel:4159/4167（录制+训练两个按钮）；`startTraining()` 唯一调用方 = TrainingPanel:4172；**GameMapCard 定义在 GameMapView.swift:1824**（不在本文件）。

**`ControlPanel`（第 3868–3977 行）——控制按钮（GlowCard）：**

1. **CONTROL 标题 + 紧急切纯规则胶囊开关（3874–3913 行）**：`state.forceRuleMode.toggle()`——shield 图标；**开启：白字压 danger 红底**（"已强制纯规则兜底（M9 停推理），点击恢复自动"）；help 原文："**紧急切纯规则：一键强制规则兜底，M9 停推理（游戏鼠标点不过去时的应急开关）**"
2. **启动自动驾驶大按钮（3916–3951 行）**：`isDriving ? stopDriving() : startDriving()`——play/stop 图标；**启动：黑字压 cyan 渐变底 + cyan 发光 shadow 18**；停止：白字压白渐变底 + danger 0.7 描边 1.5
3. **极速模式 Toggle（3953–3973 行）**：flame.fill 图标（开启 orangeRed 发光）+ "极速模式/解除限速,全速冲刺" + `Toggle($state.sportMode)`（orangeRed tint）

**`ConfigPanel`（第 3984–4035 行）——配置面板（GlowCard）：**

- **速度上限滑块（3992–3994 行）**：`SettingSlider(value: $state.speedLimit, range: 40...200, step: 5)`——**"%.0f km/h"**（**speedLimit 不是显示项，经 vehicle_state[4] 参与推理**）
- **降级阈值滑块（3996–3998 行）**：`range: 0.3...0.9, step: 0.01`
- **显示插帧 SettingRow（4000–4007 行）**：subtitles："MetalGoose MGFG-1 · 仅影响预览观感 / 游戏很卡时，可短暂看着预览框的插帧画面撑过关卡"；**binding 用自定义 Binding（set 走 `state.setUpscaleEnabled($0)`——同步采集侧+引擎侧）**；disabled: !upscaleSupported
- **游戏模式兼容 SettingRow（4009–4016 行）**：subtitles："捕获线程时间约束调度 · 对抗全屏游戏降权 / 游戏全屏卡成 1 帧时开着它；游戏掉帧就关"；set 走 `setGameModeBoost`
- **行驶录制 Toggle（4018–4031 行）**：record.circle（isRecording ? danger 红）+ `Toggle($state.isRecording)`（cyan tint）——didSet 触发 RecordEngine 启停

**`SettingSlider`（第 4037–4060 行）**：title + valueText（monospaced cyan）+ Slider（range/step，cyan tint + shadow 4）。

**`SettingRow`（第 4067–4102 行）**：icon（isActive ? activeColor + 可选发光）+ title（13pt semibold）+ subtitles 多行（10pt tertiary）+ Toggle（binding/activeColor tint/disabled）。

**`TrainingPanel`（第 4109–4194 行）——训练控制（GlowCard）：**

1. **专家模式（4117–4131 行）**：`Toggle($state.expertMode)`——person.crop.circle + "专家模式（录真人键）"——**录制来源切到真人物理键（模仿学习的专家演示标签）**
2. **字模模式（4133–4148 行）**：`Toggle($state.glyphMode)`——number.square + "字模模式（录原生速度表）"；**注释（4142 行）："录制中此开关不生效（glyphMode 在 start() 时一次性读取），可点但不热切换"**
3. **trainingLog（4149–4155 行）**：非空显示（10pt tertiary）——训练状态/完成/失败原因
4. **录制 + 训练按钮（4157–4173 行）**：`TrainButton("录制中"/"录制", record.circle, Theme.danger, filled: isRecording) { state.isRecording.toggle() }` + `TrainButton("训练中…"/"训练", cpu, Theme.cyan, filled: isTraining) { state.startTraining() }`
5. **模型版本（4175–4190 行）**：shippingbox.fill + "模型版本" + `state.modelVersion`（monospaced 白 0.06 底）

**`TrainButton`（第 4196–4226 行）**：icon + title（13pt semibold）——**filled：黑字压 tint 实心底 + tint 发光 shadow 10**；非 filled：tint 字压 tint 0.10 底 + 0.5 描边；maxWidth infinity + 垂直 11。

**`LogViewerPanel`（第 4232–4379 行）——日志查看面板（显示 /tmp/aurora_debug.log 的最新内容）：**

- **状态（4234–4237 行）**：logContent（"日志未加载"）/ isExpanded（false）/ autoRefresh（false）/ refreshTimer
- **标题栏（4242–4278 行）**：DEBUG LOG + **自动刷新 Toggle（scaleEffect 0.7；onChange 启停 startAutoRefresh/stopAutoRefresh）** + 手动刷新按钮（arrow.clockwise）+ 展开/收起（chevron.up/down，easeInOut 0.2）
- **展开内容（4280–4334 行）**：ScrollView（200 高）× Text（**9pt monospaced + textSelection 可选中**）+ 黑 0.5 底 + cyan 0.2 描边；底部操作：**清空日志（danger）** + **在 Finder 中显示（cyan）** + "自动刷新中..." 状态文字
- **`loadLog()`（4345–4355 行）**：读 `/tmp/aurora_debug.log` → **只显示最后 200 行**（`lines.suffix(200)`）；文件不存在 → "日志文件不存在或无法读取\n路径: …"
- **`clearLog()`（4357–4361 行）**：空串 atomic 写（**truncate 重写**）→ "日志已清空"
- **`showInFinder()`（4363–4367 行）**：`NSWorkspace.shared.activateFileViewerSelecting([url])`
- **`startAutoRefresh/stopAutoRefresh`（4369–4378 行）**：`Timer.scheduledTimer(1.0, repeats: true)` 每 1s loadLog；invalidate + nil
- `.onAppear { loadLog() }` + `.onDisappear { stopAutoRefresh() }`——**离开视图自动停刷新（防 Timer 泄漏）**

**代码-26 文档至此完整**（AuroraDriveApp 2164–4379 行全覆盖；全文件 40 个顶层定义全部覆盖，无遗漏）。

## 十、FrameHost / UpscaleFrameHost 直绘宿主与 Vendor 接口（第 3465–3651 行）

**引用关系（grep 实测）**：`FrameHost.push` 四处调用（init 回调转发链:1866、tick 消费:1746、tickEngineMode:1732）；`UpscaleFrameHost.push` 两处（init onUpscaleFrame:1401、tickEngineMode:1732）；frameHost 唯一消费者 = GameViewportView:2943 的 FrameHostView；upscaleHost 唯一消费者 = GameViewportView:2938 的 UpscaleFrameHostView；**Vendor 实际位置 = 工作区根 `Vendor/MetalGoose/Engine/`（6 文件：CaptureSettings/GooseEngine 90KB/GooseUpscaler/Shaders.metal/Stubs/WindowCaptureManager），Package.swift 白名单列 5 个 .swift（84–88 行），path="." + exclude 59 项（2026-09-20 由 28 项订正扩容，见代码-00）**。

**`FrameHost`（@MainActor final class，第 3474–3498 行）——画面帧直绘宿主：**

- **头注释（3469–3472 行）**："自定义 NSView 由 SwiftUI 创建一次，之后 tick 直接 push CGImage 到 layer.contents（contentsGravity = resizeAspectFill），**不再经过 body diff，避免大图每帧触发 SwiftUI 重绘；也规避 NSImageView 由 NSImageCell 绘制、contentsGravity 不生效导致 letterbox 的问题**"
- `attach(_ view: NSView)`：wantsLayer + **contentsGravity = .resizeAspectFill** + masksToBounds + **仅在有缓存时回填（停止后 clear() 已清空缓存，重启不再闪旧帧）**
- `push(_ image: CGImage)`：cachedCGImage = image + `hostView?.layer?.contents = image`——**逐帧覆盖，无排队**
- `clear()`：缓存 nil + layer contents nil——**停止/出错时清空缓存并回落黑底，释放最新帧**
- `latestSize`（计算属性）：`cachedCGImage.map { CGSize }`——最近帧尺寸（框选手势的回退源）

**`FrameHostView`（NSViewRepresentable，第 3500–3512 行）**：makeNSView 创建 NSView（wantsLayer + resizeAspectFill + masksToBounds）+ `host.attach(v)`；updateNSView 空（**直绘不靠 SwiftUI 更新**）；dismantle 时 `layer?.contents = nil`。

**`UpscaleFrameHost`（final class，第 3516–3638 行）——MetalGoose 插帧/超分引擎（仅显示路径）：**

| 成员 | 说明 |
|---|---|
| `mttkView`（weak）/ `engine: GooseUpscaler?` | MTKView 弱引用 + 插帧引擎 |
| `isAvailable`（private(set)） | 引擎创建成功 = true（Metal 可用） |
| `ingestQueue`（"aurora.upscale.ingest", .userInitiated）+ `frameLock`（OSAllocatedUnfairLock）+ `latestBuffer` + `isDraining` | **推帧队列与跳帧：push 只覆盖最新帧，drain 循环消费（isDraining 防重复 drain）** |
| `lastAttachInfo`（private(set)） | attach 时的 view/drawable 尺寸字符串（诊断） |

**方法：**

- **`prepare()`（3529–3536 行）**：`guard engine == nil`（防重复创建）→ `GooseUpscaler.make()` → `configureInterpolation()`；失败 isAvailable = false
- **`attach(_ view: MTKView)`（3538–3553 行）**：`guard engine`（**nil 时 isAvailable=false——Metal 不可用，UI 显示"插帧不可用"**）→ `engine.detachFromView()`（防旧 view 残留）→ mtkView = view + device = `MTLCreateSystemDefaultDevice()` + **framebufferOnly = false**（**要读回像素？否——插帧输出要 draw 到屏，非只读**）+ clearColor 黑 + **enableSetNeedsDisplay = false + isPaused = false**（**MetalGoose 自己驱动 draw 循环，不靠 MTKView 默认 60Hz**）→ `engine.attachToView(view, displayRefreshRate: 60, minRefreshRate: 30)` + `configureInterpolation()`（**attach 时再配一次——防 prepare 后 settings 被改**）+ lastAttachInfo 记录
- **`statsSnapshot()/pendingError()`（3555–3561 行）**：转发引擎（诊断：插帧产出/引擎错误）
- **`push(pixelBuffer:)`（3563–3576 行）**：`guard engine != nil` → 锁内 `latestBuffer = pixelBuffer`（覆盖）+ isDraining 判定（**false 时置 true 并 start drain；true 时只覆盖不重复 drain**）→ 解锁 → drain
- **`drain()`（3578–3603 行）**：ingestQueue 循环——锁内取 latestBuffer（nil → isDraining=false + 退出）→ `Self.cgImage(from: buf)` → `engine.ingest(cgImage:)`
- **`clear()`（3605–3608 行）**：`engine?.detachFromView()` + mtkView = nil——**停掉 MetalGoose 渲染（detach）**
- **`cgImage(from: CVPixelBuffer)`（private static，3610–3637 行）**：CVPixelBuffer → CGImage——**readOnly 锁基址 + `premultipliedFirst | byteOrder32Little`（BGRA）**；**`Unmanaged.passRetained(pixelBuffer).toOpaque()` 作 CGDataProvider dataInfo，releaseData 回调里 `Unmanaged<CVPixelBuffer>.fromOpaque(info!).release()`——CGImage 持有 CVPixelBuffer 引用，防止 buffer 提前释放（use-after-release 防护）**；provider 创建失败时手动 release 平衡

**`UpscaleFrameHostView`（NSViewRepresentable，第 3640–3651 行）**：makeNSView 创建 MTKView + `host.attach(v)`；updateNSView 空；dismantle 空（**detach 由 clear() 负责，视图 dismantle 不重复 detach**）。

**`GooseUpscaler`（Vendor/MetalGoose/Engine/GooseUpscaler.swift，92 行）——public 集成门面：**

- **头注释（4–14 行）**："上游 vendor 的 GooseEngine 保持逐字节一致（成员 internal，模块内 API）；本薄封装文档化 re-expose AuroraDrive 需要的最小表面——make/attachToView/detachFromView/ingest——**as public，不补丁 vendored 源**。**架构注：喂到这里的帧只走显示/叠加路径；capture → CoreML 推理 → 按键注入决策链路永不经过本引擎（见项目 NOTICE 的延迟红线依据）**"
- **`configureInterpolation()`（54–61 行）**：走 vendored 引擎自己的 settings 表面（`CaptureSettings.shared` + `engine.updateSettings`）——**scalingType=.off（只插帧，不做空间超分）+ aaMode=.off + frameGenMode=.interpolation + frameGenMultiplier=2（MetalFX 插帧固定 2x）**；**"Interpolation holds back one captured frame, so it adds a full capture interval of latency; callers must only ever use this on the human-facing display/overlay path, never in the capture → inference → key-injection decision chain"**
- **`GooseUpscalerStats`（65–72 行）**：outputFrameCount/interpolatedFrameCount/passthroughFrameCount/generatedFrameCount/outputFPS/captureFPS 六字段（**interpolatedFrameCount 持续增长 = 插帧工作；outputFPS 应 ≈ 捕获帧率 × 2**）
- **`pendingError()`（89–91 行）**：`engine.consumePendingError()`——**取出一条尚未上报的引擎错误（如 MG-ENG-010 MetalFX 插值器创建失败）——显式暴露"插帧为何静默不产帧"的根因**

**⚠️ Shaders.metal 与 SPM 白名单（关键发现，GooseEngine.swift 442–465 行）**：**Shaders.metal 不在 Package.swift sources 白名单（不参与 SPM 编译）——着色器运行时从源文件编译**：① Bundle.main 找 Shaders.metal（.app 场景）；② **可执行文件目录三候选**：`exeDir/Shaders.metal`、`exeDir/Vendor/MetalGoose/Engine/Shaders.metal`、**硬编码 `/Users/dupi/Desktop/自动驾驶系统/Vendor/MetalGoose/Engine/Shaders.metal`**（独立可执行文件场景）；③ 全败 → `device.makeDefaultLibrary()`（有预编译 metallib 时兜底）。**给别的 AI 的提醒：改 Shaders.metal 后无需重新编译 Swift；但移动 Vendor 目录会让候选 ② 失效，只剩硬编码候选 ③（若项目根也变了则插帧静默无数据，看 upscaleBadge 的"插帧不可用/异常"）**。

**代码-26 文档至此完整**（AuroraDriveApp 2164–4379 行 + Vendor 接口全覆盖；全文件 40 个顶层定义全部覆盖，无遗漏）。

## 九、TopToolbar 顶部工具栏（第 2566–2716 行）

**引用关系（grep 实测）**：`TopToolbar` 唯一调用方 = ContentView:2194（ZStack top 层）；`upscaleBadge` 唯一调用方 = TopToolbar:2587；frameHost.push 四处调用（init onFrame 转发链:1866、tick 消费:1746、tickEngineMode:1732）。

**`TopToolbar`（struct: View，第 2571–2688 行）——顶部细工具栏（44 高）：**

**左区（2576–2588 行）**：steeringwheel 图标（发光 6）+ "AuroraDrive"（14pt bold rounded + **tracking 1.2** + cyan 发光 8）+ **upscaleBadge**（插帧状态徽章，见单元三）。

**右区（2592–2674 行）——Daemon/BPF/模式/引擎状态芯片组（Capsule 白 0.05 底 + 白 0.1 描边）：**

| 芯片 | 条件 | 说明 |
|---|---|---|
| "系统级"（shield+checkmark） | `state.isDaemonMode` | **Daemon 系统服务状态药丸（最高优先级标识）**——cyan 0.2 底 + help（"当前以系统服务运行，最高调度优先级"） |
| "升级"（shield）按钮 | `!state.daemonInstalled` | 点击 → `showDaemonInstallSheet = true`——orangeRed 0.15 底 + help（"安装为系统服务，防止游戏全屏时被冻结"）；**已安装未运行时不显示（既不是系统级也不是升级按钮——安静）** |
| "BPF"（key.fill）按钮 | `!state.bpfAuthorized` | 点击 → `showBPFPasswordSheet = true`——orangeRed 0.2 底 + 发光 4 + help（"点击安装BPF权限（只需一次）"）——**灵动岛风格折叠：已授权时整个按钮消失** |
| 定位指示灯（Circle 7pt） | 恒显示 | `state.isDriving ? cyan : textTertiary` + 发光——**注释（2646 行）："不需要密码，BPF 已 chmod 666"** |
| 模式文字（11pt monospaced） | 恒显示 | **`isDriving ? (mode == .recover ? "脱困中" : mode.uiGroup.rawValue) : "待机"`——P0-2 修复：脱困（自动倒车/转向，最高风险动作）期间显示独立告警"脱困中"（orangeRed），不并入「规则」分组**；驾驶中非脱困显示 UI 组名（端到端主驾/规则，cyan） |
| **M9 状态（9pt monospaced）** | `state.isDriving` | `state.m9Status.text/color`——**M9活跃（cyan）/ M9失联（danger）/ M9未加载（tertiary）**（DriveState:1166 计算属性：**结果超 1s 没更新 = 没参与开车**） |
| **引擎连接状态** | `state.engineModeActive` | Circle 6pt（connected ? cyan : orangeRed 发光 4）+ "引擎已连接/引擎失联"（9pt monospaced）——**仅引擎模式显示；本地模式此块不出现**；help（"后台引擎运行中：抓屏/推理/按键都在引擎进程里，本窗口只负责显示"） |

**外框（2679–2687 行）**：水平 18 + 高 44 + `.bar.opacity(0.4)` 底 + **底部渐变分界线（cyan 0.35→clear，1pt）**。

**upscaleBadge（第 2690–2715 行）**——插帧状态徽章（五分支判定，见单元三详表）：`!upscaleSupported`→"插帧不可用"(danger) / `upscaleEngineError`→"插帧异常 · err"(danger) / `!upscaleEnabled`→"插帧 · 关" / `!isDriving`→**"插帧 · 待机"**（源注释："**没在驾驶 = 没有新帧可插（停止/暂停后不应继续显示'插帧中'）**"）/ upscaleLive→"插帧中 · live" / else→"插帧中 · 等待"——9pt monospaced semibold + Capsule 底（col 0.12）+ 描边（0.35）+ help（"插帧实时状态：产出=插入的中间帧 输出=总呈现帧 透传=未插帧直通 帧率"）。