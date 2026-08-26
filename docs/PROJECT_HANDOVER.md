# AuroraDrive 项目交接文档（2026-08-26）

## 一、项目概述

**AuroraDrive** 是 macOS 上的 SwiftUI 游戏辅助自动驾驶工具。
- **游戏**：异环（NTE）
- **核心功能**：截屏游戏画面 → AI模型推理 → CGEvent按键注入 → 自动驾驶
- **技术栈**：纯SwiftUI + SwiftPM + CoreML + ScreenCaptureKit + CGEvent
- **工作区**：`/Users/dupi/Desktop/自动驾驶系统`
- **用户只点击裸可执行文件 `./AuroraDriveUI`，不点App包**

## 二、构建关键纪律

### 必须遵守
```bash
# 每次改代码后必须清缓存再编译，否则SwiftPM缓存导致改动不生效
rm -rf .build && swift build -c release
# 签名
codesign --force --deep --sign - .build/release/AuroraDrive
# 复制到可执行文件
cp .build/release/AuroraDrive AuroraDriveUI
xattr -cr AuroraDriveUI
```

### Package.swift 关键配置
```swift
// 必须用Swift5语言模式，否则Swift6严格并发检查报错
swiftSettings: [.swiftLanguageMode(.v5)]
// 链接pcap库（网络抓包用）
linkerSettings: [.linkedLibrary("pcap")]
// PostBuildSign插件已移除（清缓存后报错），手动codesign即可
```

### 编译报错检查清单
1. `MinimapTileCache.swift` — `tileIndex(mapPixel:)` 必须带参数标签
2. `NetworkPacketCapture.swift` 不在Package.swift的sources里（旧代码，不编译）
3. 如果报 `RawPoint is ambiguous` — NetworkLocator.swift 和 NetworkPacketCapture.swift 都定义了RawPoint/MapPoint，不能同时编译

## 三、当前架构

### 文件结构
```
AuroraDriveApp.swift     — 主程序 ~3000行（ContentView + DriveState + GameViewportView + UI组件）
Package.swift            — SwiftPM构建配置
run.sh                   — 一键编译+签名+启动脚本（内置rm -rf .build清缓存）

CaptureEngine.swift      — ScreenCaptureKit截屏引擎（onFrame/onYoloFrame/onNativeFrame回调）
ControlEngine.swift      — CGEvent按键注入（KeyMap: steer→A/D, throttle→W, brake→S）
InferenceEngine.swift    — CoreML E2E推理（m9_mono → steer/throttle/brake）
YoloEngine.swift         — CoreML YOLO检测（yolo26s → COCO 80类检测框）
SpeedOCRReader.swift     — 速度表读取（旧字模模板匹配，准确率0.2%极低，待替换）
DegradeStateMachine.swift— 降级状态机（4档: e2e→yolo→recover→rule）
EscapeController.swift   — 脱困策略（倒车→转向→前进）
RuleController.swift     — 规则控制（YOLO检测→手写规则控制量）
ConfidenceEstimator.swift— 置信度估算
KeyboardMonitor.swift   — 物理键盘监听
RecordEngine.swift       — 录制引擎
GameMapView.swift        — 游戏地图视图
MinimapTileCache.swift   — 小地图瓦片缓存（旧版，不工作好）
NetworkPacketCapture.swift— 旧网络抓包（不编译，假实现）

# 移植过来的文件（从外置盘"自动驾驶系统垃圾"版本）
NetworkLocator.swift     — WebSocket客户端连MaaNTE拿坐标（626行）
VisualLocator.swift     — 小地图模板匹配定位（487行，自包含不需要服务端）
MinimapLocatorView.swift— 小地图UI（192行，显示玩家位置+朝向+目标）
```

### 3个CoreML模型（在models/目录）
| 模型 | 大小 | 用途 | 加载者 |
|---|---|---|---|
| m9_mono.mlmodelc | 15MB | 档1 E2E端到端主驾 | InferenceEngine()默认 |
| game_assist_control.mlmodelc | 15MB | 档2神经网接管 | InferenceEngine(modelFileName:) |
| yolo26s.mlmodelc | 9.4MB | YOLO检测(档2/档4) | YoloEngine() |
| speed_digit_cnn.mlmodelc | 50KB | 速度表数字CNN(98.4%准确率，未接入，裁剪坐标有问题) | 未接入 |

### 降级梯子（用户认为已经很好，不要改）
```
档1 e2e: m9_mono模型直接开车
档2 yolo: game_assist_control模型开车 + yolo26s画检测框
档3 recover: 卡死脱困（纯逻辑：倒车→转向→前进）
档4 rule: yolo26s检测 + 手写规则控制
```

### DriveState 关键字段（AuroraDriveApp.swift内）
```swift
// 截屏
var isStreaming, capturePermissionDenied, fps, speedKmh, confidence
// 控制
var isDriving, controlDisabled, forceRuleMode, mode(DriveMode)
// 网络定位（移植的）
var enableNetworkLocate, networkLocateX/Y/Score/Mode/Heading
var locatorFound, locatorX, locatorY, locatorScore, locatorHeading, locatorTarget
private var networkLocatorPorted: NetworkLocator?
private let locateCtx = LocateContext()
func runNetworkLocateStep()  // 4Hz DispatchSource调用
```

### ContentView布局
```swift
ZStack(alignment: .top) {
    HStack(spacing: 0) {
        GameViewportView(state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                MinimapLocatorView(state: state)  // 移植的小地图
            }
        SidebarView(state: state)
            .frame(width: 360)
    }
    .padding(.top, 44)
    TopToolbar(state: state)
}
```

### tick循环（30Hz，App Nap防护）
```swift
// DispatchSource替代main RunLoop Timer（不受App Nap冻结）
let timerQueue = DispatchQueue(label: "com.aurora.tick", qos: .userInteractive)
let timer = DispatchSource.makeTimerSource(queue: timerQueue)
timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .nanoseconds(0))
timer.setEventHandler { DispatchQueue.main.async { state.tick() } }
timer.resume()

// 网络定位定时器（4Hz）
let nlQueue = DispatchQueue(label: "com.aurora.netlocate", qos: .userInteractive)
let nlTimer = DispatchSource.makeTimerSource(queue: nlQueue)
nlTimer.schedule(deadline: .now(), repeating: 1.0 / 4.0, leeway: .nanoseconds(0))
nlTimer.setEventHandler { DispatchQueue.main.async { state.runNetworkLocateStep() } }
nlTimer.resume()
```

### App Nap四重锁死（防止游戏全屏时App被冻结）
```swift
// 1. nice=-20（进程最高优先级）
setpriority(PRIO_PROCESS, 0, -20)
// 2. DispatchSource .userInteractive（tick不走main RunLoop）
// 3. CGEventTap（系统必须保持有event tap的进程响应）
let eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: eventMask,
    callback: { _, _, event, _ in return Unmanaged.passUnretained(event) }, userInfo: nil)
CGEvent.tapEnable(tap: eventTap, enable: true)
// 4. 768MB内存+mlock（系统不敢冻结重资源进程）
let allocSize = 768 * 1024 * 1024
let buf = UnsafeMutableRawPointer.allocate(byteCount: allocSize, alignment: 4096)
for i in 0..<pageCount { buf.advanced(by: i*4096).storeBytes(of: UInt8(i&0xFF), as: UInt8.self) }
mlock(buf, allocSize)
```

## 四、已完成的工作

### ✅ 架构pivot
- 旧Tauri+React+C++模拟器架构 → 纯SwiftUI单文件架构
- git历史彻底清除（rm .git + git init，.git从207MB→7.1MB）

### ✅ sidebar按钮修复
- 根因：SwiftPM构建缓存导致代码改动从未编译进去
- rm -rf .build后暴露MinimapTileCache.swift编译错误（缺mapPixel:参数标签 + Swift6并发检查）
- 修复：补参数标签 + Package.swift加.swiftLanguageMode(.v5)
- 自动化抽屉改为内联按钮（AutomationInlinePanel，避免hit-test问题）

### ✅ 速度表ROI调试框
- SpeedROIOverlay在App预览画面画红框(速度表ROI)+蓝框(3个数字槽位)
- 坐标已验证正确

### ✅ 网络定位移植（部分完成）
- NetworkLocator.swift + VisualLocator.swift + MinimapLocatorView.swift 已拷入
- DriveState已加locator字段 + runNetworkLocateStep方法
- 4Hz网络定位DispatchSource定时器已加
- MinimapLocatorView已加到ContentView overlay
- NetworkPacketCapture.swift已从Package.swift移除（不编译）

### ✅ 速度表CNN训练
- 训练数据：580帧游戏截图，EasyOCR自动标注563张有效
- CNN结构：3层卷积(16→32→64)+2层全连接(128→10)
- 验证准确率98.4%，PyTorch CPU 5888fps
- CoreML模型已生成：models/speed_digit_cnn.mlmodelc
- **未接入运行**：裁剪坐标CIImage Y翻转有问题，需要调试

### ✅ App Nap四重锁死
- nice=-20 + DispatchSource + CGEventTap + 768MB mlock

## 五、待完成任务（按优先级）

### 🔴 P0：网络定位自包含
**目标**：App自己抓网络包解析UE5坐标，不依赖MaaNTE服务端

**方案**：把MaaNTE的 `nte_coordinate_api.py` 的核心逻辑移植到Swift
- `_bits()/_vector()/_rotator()` — 纯bit位运算，直接翻译
- `_Decoder` 类 — 状态跟踪+候选选择逻辑
- 用libpcap（Package.swift已链接pcap）抓TCP包
- 坐标变换常量已在NetworkLocator.swift里

**关键文件**：
- 源码：`MaaNTE/agent/custom/action/Navi/nte_coordinate_api.py`（611行）
- 目标：新建 `CoordinateCapture.swift` 或改造 `NetworkPacketCapture.swift`
- 坐标变换常量已在：`NetworkLocator.swift` 第7-14行

**MaaNTE的坐标抓取原理**：
1. 用scapy(Python libpcap封装)抓网络包
2. 过滤TCP c2s(客户端→服务器)包
3. bit位运算解析UE5移动包：时间戳+加速度+位置(Vector3)+旋转(FRotator)
4. 校准常量变换到地图像素：
   ```
   _CALIBRATION_A = 0.016394586684750773
   _CALIBRATION_B = 5.693519256055879e-08
   _CALIBRATION_TX = 6293.474380746091
   _CALIBRATION_TY = 3472.664390686138
   _NORTH = (-0.013752068070295848, -0.9999054358407049, 0.0)
   _EAST = (0.9999054358407049, -0.01375206807029585, 0.0)
   ```
5. 不需要MaaFramework、不需要Python、不需要任何外部服务

### 🔴 P1：速度表OCR替换
**当前状态**：旧字模系统准确率0.2%极低，CNN模型已训好但裁剪坐标有问题

**方案**：
- CNN模型 `models/speed_digit_cnn.mlmodelc` 已训好（98.4%准确率）
- 需要修复 `SpeedOCRReader.swift` 的 `cropSlot` 函数
- 问题：CIImage坐标系（左下角原点）vs CVPixelBuffer坐标系（左上角原点）
- 修复后用CoreML加载CNN模型替代字模

**备选方案**：用Apple Vision VNRecognizeTextRequest（已尝试但被用户否决，需4倍放大+只认数字+accurate精度）

### 🟡 P2：视觉识别升级（路线A）
**目标**：自动驾驶用YOLO + 自动化任务用模板匹配

**当前问题**：YOLO26s是COCO通用模型，检测框抖动严重

**方案**：
1. 自动驾驶（检测路上车/人）— 重新训练YOLO（用游戏截图）
2. 自动化任务（识别UI按钮）— 移植MaaNTE的196张模板图 + 写Swift模板匹配引擎
3. 模板匹配用vImage(Accelerate框架)替代OpenCV的cv2.matchTemplate

**MaaNTE模板图位置**：`MaaNTE/assets/resource/base/image/`（196张PNG）

### 🟡 P3：MaaNTE自动化功能移植
**目标**：把MaaNTE的自动化功能移植到Swift，自包含

**MaaNTE代码结构**：
- `MaaNTE/agent/custom/action/` — 60+个Python文件，约17000行
- `MaaNTE/assets/resource/base/pipeline/` — 92个JSON任务流程定义
- `MaaNTE/assets/resource/base/image/` — 196张模板图

**各功能移植难度**：
| 功能 | Python代码量 | 难度 | 依赖什么 |
|---|---|---|---|
| 自动钓鱼 | 877行 | 中 | 模板匹配+截图+按键 |
| 自动做咖啡 | 300行 | 低 | 同上 |
| 粉爪大劫案 | 6507行 | 高 | 复杂战斗AI+键盘控制+模板匹配 |
| 俄罗斯方块 | 1490行 | 高 | 游戏AI+棋盘检测 |
| 节奏游戏 | 1611行 | 高 | 音频检测+按键 |
| 自动弹钢琴 | 782行 | 中 | MIDI解析+按键映射 |
| 自动闪避 | 571行 | 中 | 声音检测+按键 |
| 自动收家具 | 162行 | 低 | 模板匹配+点击 |
| 地图传送 | 1405行 | 中 | 坐标+导航 |

**MaaFramework API替代映射**：
| MaaFramework API | Swift替代 |
|---|---|
| controller.post_screencap() | ScreenCaptureKit（已有） |
| controller.post_key_up/down() | CGEvent（已有KeyMap） |
| self.ctx.run_task("节点") | 需写Swift模板匹配引擎 |
| self.ctx.run_recognition() | 同上 |
| cv2.matchTemplate() | vImage或Vision VNFeaturePrintObservation |

**粉爪大劫案移植方案**：
- 6个Python文件，6507行
- 用4个MaaFramework API：截图/按键/run_task(模板匹配+点击)/run_recognition
- 截图和按键我们已有，只差模板匹配引擎
- Windows VK码→macOS keyCode（KeyMap已有映射）
- 移植步骤：拷196张模板图→写Swift模板匹配引擎→翻译战斗逻辑

## 六、关键代码位置

### 速度表ROI坐标（CaptureEngine.swift）
```swift
nonisolated static let speedROINorm = CGRect(x: 0.455, y: 0.885,
                                             width: 0.080, height: 0.050)
```

### 数字槽位坐标（SpeedOCRReader.swift）
```swift
nonisolated static let slotCentersNorm: [CGFloat] = [0.479, 0.496, 0.512]
nonisolated static let slotWidthNorm: CGFloat = 0.014
nonisolated static let slotYMinNorm: CGFloat = 0.897
nonisolated static let slotYMaxNorm: CGFloat = 0.932
nonisolated static let templateHeight: Int = 45
nonisolated static let templateWidth: Int = 25
```

### 截屏回调接线（AuroraDriveApp.swift init()）
```swift
captureEngine.onFrame = { image, cgImage in ... }       // 显示帧
captureEngine.onYoloFrame = { pb in ... }                // YOLO直通帧(352×352)
captureEngine.onNativeFrame = { pb in ... }             // 速度表ROI帧(51×18)
captureEngine.onUpscaleFrame = { pb in ... }            // 插帧帧
captureEngine.onStatusChange = { status in ... }        // 启停状态
```

### 网络定位调用链
```
onAppear → DispatchSource 4Hz → state.runNetworkLocateStep()
  → NetworkLocator().prepare()  // 连ws://127.0.0.1:9004
  → NetworkLocator().locate()    // 拿坐标
  → DispatchQueue.main.async    // 写 locatorX/Y/Found/Heading
  → MinimapLocatorView显示      // 画位置块+朝向三角
```

## 七、MaaNTE关键文件索引

### 网络定位（自包含移植源）
- `MaaNTE/agent/custom/action/Navi/nte_coordinate_api.py` — UE5包解析核心（611行）
  - `_bits(data, offset, count)` — bit位读取
  - `_vector(data, offset, scale)` — UE5 Vector3序列化解码
  - `_rotator(data, offset)` — UE5 FRotator序列化解码
  - `_Decoder` 类 — 状态跟踪+候选选择
  - `CoordinateCapture` 类 — scapy抓包+解码
- `MaaNTE/agent/custom/action/Navi/coordinate_position.py` — 坐标变换+WebSocket服务
- `MaaNTE/agent/custom/action/Navi/navigation_server.py` — WebSocket服务端

### 自动化功能
- `MaaNTE/agent/custom/action/AutoFish/` — 自动钓鱼（877行）
- `MaaNTE/agent/custom/action/AutoCoffee/` — 自动做咖啡（300行）
- `MaaNTE/agent/custom/action/pinkpaw/` — 粉爪大劫案（6507行）
- `MaaNTE/agent/custom/action/Tetris/` — 俄罗斯方块（1490行）
- `MaaNTE/agent/custom/action/rhythm/` — 节奏游戏（1611行）
- `MaaNTE/agent/custom/action/auto_piano/` — 自动弹钢琴（782行）
- `MaaNTE/agent/custom/action/SoundTrigger/` — 自动闪避（571行）
- `MaaNTE/agent/custom/action/Furniture/` — 自动收家具（162行）
- `MaaNTE/agent/custom/action/MapTeleport/` — 地图传送（1405行）

### 资源
- `MaaNTE/assets/resource/base/pipeline/` — 92个JSON任务流程
- `MaaNTE/assets/resource/base/image/` — 196张模板图
- `MaaNTE/assets/resource/tasks/` — 任务配置JSON

## 八、外置盘备份（严禁修改）

- **路径**：`/Volumes/代码项目/`
- **"自动驾驶系统垃圾"**：修好UI的旧版（有NetworkLocator等Swift源码）
- **"自动驾驶系统"**：另一份副本
- **严禁在外置盘上运行或修改代码**
- **只允许在工作区 `/Users/dupi/Desktop/自动驾驶系统` 更新**

## 九、用户偏好（必须遵守）

1. **永远只点可执行文件** `./AuroraDriveUI`，不点App包
2. **外置盘是救命稻草**，严禁修改外置盘文件
3. **能移植就移植，不要自己写**（用户认为自研代码质量差）
4. **改代码后必须 `rm -rf .build`** 再 `swift build`
5. **代码质量要高**，禁止打补丁/残留式修复
6. **速度表OCR**：旧字模0.2%准确率不能用，需要替换
7. **网络定位**：要自包含，不依赖外部服务端
8. **视觉识别**：YOLO26s稳定性差，路线A（驾驶用YOLO+自动化用模板匹配）

## 十、git提交历史
```
9c5ef34 内存锁定256MB→768MB
5fea87b 四重锁死：+2GB内存mlock锁定
726d14e 系统级实时保护：nice=-20 + CGEventTap + DispatchSource三重锁死
03e5468 App Nap修复+速度表ROI调试框
136d2f8 run.sh: 每次编译前 rm -rf .build 清缓存
8a5a41d 修复 sidebar 按钮无法点击 + 清理构建配置
b5febe6 AuroraDrive 游戏辅助自动驾驶 - SwiftUI 基线
```
