# AuroraDrive 开发者文档（中文 / Chinese）

> 本文是全部开发文档的**总入口（二级）**。每章对应一个独立的三级文档；要看最深实现细节，进入四级《核心实现原理》。English version: [DEVELOPER_GUIDE.en.md](DEVELOPER_GUIDE.en.md)
>
> **真实性约定**：所有文档描述的常量、函数名、流程均直接取自仓库源码（标注 `文件:行号`），与代码零偏差。与注释冲突时以代码为准（已知的注释-实现不一致在文档中如实标注）。

---

## 目录（三级菜单）

| 章 | 文档 | 覆盖源码（Sources/AuroraDrive/） |
|---|---|---|
| 一 | [系统架构总览](dev/01-architecture.md) | `AuroraDriveApp.swift`(3276) `DegradeStateMachine.swift`(250) |
| 二 | [网络定位子系统](dev/02-network-locate.md) | `CoordinateCapture.swift`(576) `NetworkHealer.swift`(377) `VisualLocator.swift`(491) `MinimapLocatorView.swift` `MinimapTileCache.swift` |
| 三 | [速度识别子系统](dev/03-speed-ocr.md) | `SpeedOCRReader.swift`(1061) |
| 四 | [视觉与推理子系统](dev/04-vision-inference.md) | `CaptureEngine.swift` `InferenceEngine.swift` `YoloEngine.swift` `ConfidenceEstimator.swift` `RecordEngine.swift` |
| 五 | [控制与安全子系统](dev/05-control-safety.md) | `ControlEngine.swift` `KeyboardMonitor.swift` `RuleController.swift` `EscapeController.swift` |
| 六 | [常见问题 FAQ](#六常见问题-faq) | — |

### 四级深入文档（核心实现原理）

| 文档 | 揭示内容 |
|---|---|
| [UE5 移动包位流逐字段解析](internals/ue5-bitstream.md) | 位读取原语 / 向量块 / 旋转块 / 扫描定位 |
| [坐标标定常量推导](internals/coordinate-calibration.md) | kCalibA/B/TX/TY 仿射变换与东北向量 |
| [BPF 权限与 LaunchDaemon](internals/bpf-daemon.md) | App 内密码 → osascript → 开机自启全链路 |
| [App Nap 对抗机制](internals/app-nap.md) | 六重锁：禁终止/beginActivity/-20/EventTap/768MB mlock/实时约束 |
| [踩坑实录](internals/pitfalls.md) | PAC 崩溃 / 无符号下溢 / 网卡抓错 / CoreML 编译 等真实事故 |

---

## 一、系统架构总览 → [三级文档](dev/01-architecture.md)

进程内四条生命线：

1. **主线程**：SwiftUI 渲染 + 状态写回（`@Observable DriveState`）
2. **tick 队列**（`com.aurora.tick`，30Hz DispatchSource）：`state.tick()` 驱动捕获→推理→按键
3. **网络定位队列**（`com.aurora.netlocate`，10Hz）：`runNetworkLocateStep()`
4. **抓包线程**（`com.aurora.coordinate-capture`）：`pcap_next_ex` 阻塞循环

App Nap 六重对抗（禁自动终止 / beginActivity / nice -20 / CGEventTap / 768MB mlock / 主线程实时约束）保证全屏下 tick 不掉帧。四档降级（e2e/yolo/recover/rule）由 `DegradeStateMachine` 驱动，阈值：降级 0.65 / 恢复 0.80（滞回 0.15）/ 卡住 3km/h×3s / 脱困超时 30s。

## 二、网络定位子系统 → [三级文档](dev/02-network-locate.md)

- **BPF 权限**：App 内密码弹窗 → osascript → `com.aurora.bpf-setup` LaunchDaemon 开机自动 `chmod 666 /dev/bpf*`
- **抓包**：`pcap_findalldevs` 枚举网卡（跳过 lo/utun 等虚拟网卡）→ 过滤器 `tcp port 30031` → `pcap_next_ex` 循环
- **解码**：剥三层头 → 只放行 c2s → UE5 位流扫描 → 世界坐标 + 朝向 → 仿射变换到 11264px 地图
- **自愈**：NetworkHealer 5s 定时诊断（5 种实际诊断），网络挂 → 视觉顶班 → 修复 → 切回
- **活/死澄清**：NetworkLocator（WebSocket）编译但零实例化；NetworkPacketCapture 已移 legacy/ 不编译；VisualLocator NCC 引擎已装配未接线

## 三、速度识别子系统 → [三级文档](dev/03-speed-ocr.md)

**双引擎**：CNN 主引擎（`recognizeCNN`，`speed_digit_cnn_v4.mlpackage` INT4，输入 `[1,1,90,50]`）+ 字模模板降级（当前停用：字模库 45×25 与 CNN 模板 90×50 尺寸不匹配，加载被拒）。

模型加载必须 `MLModel.compileModel(at:)` 先编译（新版 macOS 不再隐式编译 .mlpackage）。三层校验：量程 0~400 → 跳变 ≤60 km/h → 1 秒窗口 3 帧投票（容差 ±2）。

## 四、视觉与推理子系统 → [三级文档](dev/04-vision-inference.md)

- CaptureEngine：ScreenCaptureKit 30fps BGRA，每帧直发 4 条回调（UI/YOLO/MetalFX/原生 ROI）
- InferenceEngine：m9_mono，输入 `image[1,3,180,320]` + `vehicle_state[1,6]`（v2_new 契约），输出 steer/throttle/brake
- YoloEngine：yolo26s，inputSize 640，conf 阈值 0.22，inferFast 直通快路径，CocoLabels 80→4 类映射
- ConfidenceEstimator：一致性 0.5 + 极端度 0.3 + 亮度 0.2 加权估算 E2E 置信度（isLive 门控归零）
- RecordEngine：raw_clips（640×360 + controls.csv）与 glyph_clips（字模 ROI PNG）双模式录制
- MetalFX：只挂显示 overlay（架构红线）
- AutomationPanel：9 自动化按钮纯 UI 占位

## 五、控制与安全子系统 → [三级文档](dev/05-control-safety.md)

- ControlEngine：`CGEventSource(.hidSystemState)`（游戏只读 HID 层）+ `.cghidEventTap` 注入；键码 W13/S1/A0/D2/空格49/Shift56
- KeyboardMonitor：全局物理键监听（显示用，**非急停**）
- RuleController：YOLO 检测 → 决策表（直行 0.8 油门 / urgency>0.55 急刹 / >0.25 减速避让）
- EscapeController：倒车 1.5s → 反打 0.8s → 前进 2.0s 循环，15s 超时，>8km/h 成功
- 紧急停车：`stopDriving()` → `releaseAll()` + `forceRule` 一键规则

## 六、常见问题 FAQ

**Q1：启动后提示「CNN模型和字模均未加载」？**
CNN 模型加载失败。检查 `models/speed_digit_cnn_v4.mlpackage` 是否存在；当前代码已用 `MLModel.compileModel(at:)` 先编译再加载，若仍失败请提 issue 附 `/tmp/aurora_pcap.log`。

**Q2：网络定位一直不工作？**
先确认 BPF 权限：`ls -l /dev/bpf0` 应为 `crw-rw-rw-`。不是就跑 App 内 BPF 安装，或手动 `sudo chmod 666 /dev/bpf*`（重启会失效，建议走 App 内安装）。

**Q3：定位显示异常 / 小地图位置不对？**
大堂/加载界面没有移动包是正常的。进入驾驶后自动恢复。位置持续偏差请对照已知地标检查标定（见 internals/coordinate-calibration）。

**Q4：速度数字偶尔跳变？**
单帧误识别会被三层校验拦下：跳变 >60 km/h 置零置信度走降级，1 秒窗口 3 帧投票（容差 ±2）通过才输出。

**Q5：编译报宏错误 "ObservableMacro could not be found"？**
Xcode 宏插件问题（常见于中文路径/外置盘 Xcode）。用完整权限编译，或将 Xcode 装到 `/Applications`。

**Q6：models/ 里的 speed_digit_cnn（无 v4）、speed_templates.json 是什么？**
早期 CNN v1 和旧模板库的遗留文件，当前代码不引用（SpeedOCRReader 只加载 speed_glyphs.json 与 v4.mlpackage），可忽略。
