# AuroraDrive 开发者文档（中文 / Chinese）

> 本文是全部开发文档的**总入口（二级）**。每章对应一个独立的三级文档；要看最深实现细节，进入四级《核心实现原理》。English version: [DEVELOPER_GUIDE.en.md](../神秘乱七八糟的文档/历史归档/03-英文版/DEVELOPER_GUIDE.en.md)
>
> **真实性约定**：所有文档描述的常量、函数名、流程均直接取自仓库源码（标注 `文件:行号`），与代码零偏差。与注释冲突时以代码为准（已知的注释-实现不一致在文档中如实标注）。

---

## 目录（三级菜单）

| 章 | 文档 | 覆盖源码（Sources/AuroraDrive/） |
|---|---|---|
| 一 | [系统架构总览](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/01-architecture.md) | `AuroraDriveApp.swift`(4379) `DegradeStateMachine.swift`(250) |
| 二 | [网络定位子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/02-network-locate.md) | `CoordinateCapture.swift`(635) ~~`NetworkHealer.swift`~~（76e9027 已删，自愈引擎退役） `VisualLocator.swift`(491) `MinimapLocatorView.swift` `MinimapTileCache.swift` |
| 三 | [速度识别子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/03-speed-ocr.md) | `SpeedOCRReader.swift`(1243，PP-OCRv6 主 / CNN 备双引擎) |
| 四 | [视觉与推理子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/04-vision-inference.md) | `CaptureEngine.swift` `InferenceEngine.swift` `YoloEngine.swift` `ConfidenceEstimator.swift` `RecordEngine.swift` `YolopxEngine.swift` `OpticalFlowBridge.swift` `MotionPredictor.swift` `FallbackGuard.swift` |
| 五 | [控制与安全子系统](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/05-control-safety.md) | `ControlEngine.swift` `KeyboardMonitor.swift` `RuleController.swift` `EscapeController.swift` |
| 六 | [常见问题 FAQ](#六常见问题-faq) | — |
| 七 | [2026-09-19 磁盘清理说明](#七2026-09-19-磁盘清理说明) | 迁移路径对照 + MaaNTE 侧现状速记 |

### 四级深入文档（核心实现原理）

| 文档 | 揭示内容 |
|---|---|
| [UE5 移动包位流逐字段解析](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/ue5-bitstream.md) | 位读取原语 / 向量块 / 旋转块 / 扫描定位 |
| [坐标标定常量推导](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/coordinate-calibration.md) | kCalibA/B/TX/TY 仿射变换与东北向量 |
| [BPF 权限与 LaunchDaemon](bpf-daemon.md) | App 内密码 → osascript → 开机自启全链路 |
| [App Nap 对抗机制](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/app-nap.md) | 六重锁：禁终止/beginActivity/-20/EventTap/768MB mlock/实时约束 |
| [踩坑实录](pitfalls.md) | PAC 崩溃 / 无符号下溢 / 网卡抓错 / CoreML 编译 等真实事故 |

---

## 一、系统架构总览 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/01-architecture.md)

进程内四条生命线：

1. **主线程**：SwiftUI 渲染 + 状态写回（`@Observable DriveState`）
2. **tick 队列**（`com.aurora.tick`，30Hz DispatchSource）：`state.tick()` 驱动捕获→推理→按键
3. **网络定位队列**（`com.aurora.netlocate`，10Hz）：`runNetworkLocateStep()`
4. **抓包线程**（`com.aurora.coordinate-capture`）：`pcap_next_ex` 阻塞循环

App Nap 六重对抗（禁自动终止 / beginActivity / nice -20 / CGEventTap / 768MB mlock / 主线程实时约束）保证全屏下 tick 不掉帧。四档降级（e2e/yolo/recover/rule）由 `DegradeStateMachine` 驱动，阈值：降级 0.65 / 恢复 0.80（滞回 0.15）/ 卡住 3km/h×3s / 脱困超时 30s。

## 二、网络定位子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/02-network-locate.md)

- **BPF 权限**：App 内密码弹窗 → osascript → `com.aurora.bpf-setup` LaunchDaemon 开机自动 `chmod 666 /dev/bpf*`
- **抓包**：`pcap_findalldevs` 枚举网卡（跳过 lo/utun 等虚拟网卡）→ 过滤器 `tcp port 30031 or udp`（MaaNTE 对齐，UE5 移动同步可走 UDP）→ `pcap_next_ex` 循环
- **解码**：剥三层头 → 只放行 c2s → UE5 位流扫描 → 世界坐标 + 朝向 → 仿射变换到 13056×13056 地图（map-2026-08，2026-09-13 升级）
- **定位现行**：`runNetworkLocateStep()`（10Hz）内 `CoordinateCapture` 懒初始化 + `read(maxAge:1.0)` 直连，无自愈引擎（原 NetworkHealer 随 76e9027 删除）
- **活/死澄清**：NetworkLocator（WebSocket）编译但零实例化；NetworkPacketCapture 已移 legacy/ 不编译；VisualLocator NCC 引擎已装配未接线

## 三、速度识别子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/03-speed-ocr.md)

**双引擎**（2026-09-19 订正）：PP-OCRv6 微调整行模型（`ppocrv6_tiny_ft_int8.mlpackage`，int8，GPU 推理）为主路径 + 逐位 CNN（`speed_digit_cnn_v4*`）为备用引擎；旧字模模板引擎已删除（档案见 dev/03-speed-ocr.md）。

模型加载必须 `MLModel.compileModel(at:)` 先编译（新版 macOS 不再隐式编译 .mlpackage）。三层校验：量程 0~400 → 跳变 ≤60 km/h → 1 秒窗口 3 帧投票（容差 ±2）。

## 四、视觉与推理子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/04-vision-inference.md)

- CaptureEngine：ScreenCaptureKit 30fps BGRA，每帧直发 4 条回调（UI/YOLO/MetalFX/原生 ROI）
- InferenceEngine：m9_mono，输入 `image[1,3,180,320]` + `vehicle_state[1,6]`（v2_new 契约），输出 steer/throttle/brake
- YoloEngine：yolo26s，inputSize 640，conf 阈值 0.22，inferFast 直通快路径，CocoLabels 80→4 类映射
- ConfidenceEstimator：一致性 0.5 + 极端度 0.3 + 亮度 0.2 加权估算 E2E 置信度（isLive 门控归零）
- RecordEngine：raw_clips（640×360 + controls.csv）与 glyph_clips（字模 ROI PNG）双模式录制
- MetalFX：只挂显示 overlay（架构红线）
- AutomationPanel：9 自动化按钮纯 UI 占位

## 五、控制与安全子系统 → [三级文档](../神秘乱七八糟的文档/历史归档/05-自动驾驶与功能-早期稿/05-control-safety.md)

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

---

## 七、2026-09-19 磁盘清理说明

2026-09-19 已做磁盘清理，以下路径**已从本地移出**，统一迁移至外置硬盘：
`/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/`。

> ### ⚠️ 2026-09-29 路径修正（重要）
>
> **原文写的路径是** `/Volumes/代码项目/删除_20260919/自动驾驶系统清理/` ——
> **该路径不存在**（实测 `ls` 报 `No such file or directory`）。
>
> 真实路径**嵌在「自动驾驶项目半成品版本1.0到10.0」目录内，比原文多了两级**：
> ```
> /Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/
> ```
>
> **实测确认**：该归档目录 **22 GB / 9 个子目录**，与下表迁移项**一一对应**
> （`web_frames` / `template_scratch` / `build_contact` / `ocr_batch` / `ocr_batch2` /
> `gray_cache` / `videos` / `build_cache` / `ppocrv6_finetune_output`）。
>
> **按原路径去找会报 No such file，容易误以为"数据丢了"——实际 22 GB 完好。**
> 英文版 `DEVELOPER_GUIDE.en.md` 同样记错，已同步修正。

文档中出现这些旧路径时一律以上述迁移位置为准：

| 原本地路径 | 内容 |
|---|---|
| `data/web_frames` | 19G，22741 帧 web 视频截帧 |
| `build/vid_*.mp4` | 14 个挖掘用视频 |
| `build/template_scratch` | 模板挖掘工作区 |
| `build/contact` | 接触检测中间产物 |
| `build/ocr_batch(2)` | OCR 批量测试中间产物 |
| `data/_gray_cache` | 263 张 1280×803 灰度缓存（重跑 `tools/audit2.py` 需先重建） |
| `tools/ppocrv6_finetune/output` | PPOCRv6 微调输出 |
| `.build` | 构建缓存 |

本地保留的相关数据：`build/new_templates`（**265 条目 / 264 张 png**，2026-09-29 实测；原记 291/268，⚠️ 数字已变——另有 `_rejected/` 27 项淘汰候选）、`build/dig_*.json`（52 份挖掘证据 ✅ 实测吻合）、`build/maa_pipeline_override.json`（全量 250 节点 override ✅ 实测吻合）、`data/mac_shots`（208 张实机截图 ✅ 实测吻合）。

> ### 📌 2026-09-29 补充：模板挖掘的**两份原始调研报告**（此前未被引用）
>
> `build/` 目录下有两份**高价值调研报告**，此前**未被任何文档引用**：
>
> | 文件 | 规模 | 内容 |
> |---|---|---|
> | `build/route3_template_scene_map.md` | **51 KB** | **MaaNTE 官方模板 → 场景映射 & 缺失场景报告**（模板挖掘的**直接依据**） |
> | `build/route2_web_ui_research.md` | **35 KB** | 《异环》界面文字与布局的**公开网络调研**（为无法验证的 OCR 节点补外部证据） |
>
> **`route3` 的关键结论**（数据本轮实测**仍然准确**）：
> - MaaNTE 自带模板图 **211 张**（21 个目录）——✅ **实测吻合**
>   - 其中被 pipeline 引用 **110 张**，**101 张从未被引用**（遗留/备用资源）
> - pipeline **623 个可识别节点** + 29 个纯流程节点，分属 **24 个场景桶**
> - **101 个无法验证节点**（OCR miss 71 + TemplateMatch both_miss 30），分布 **15 个场景**
> - 其中 **13 个有官方模板支持** → 属官方正常流程，值得优先补截图
> - ⚠️ 该报告还纠正了上一轮的测试缺陷：**漏测了 20 个 TemplateMatch 节点**
>   （前一版解析器不支持扁平写法，`template` 被读成 null）
> - 给出**优先级排序的补图清单**（WitchDivination 15 / Fish 12 / MakeCoffee 11 / Tetris 11 / Volleyball 10 …）
>
> **⟹ 进展对照**：官方 211 张 → 我们已挖掘 **264 张**（超出官方 53 张）
>
> **`route2` 的方法论亮点**（值得沿用）：
> - **证据分级**：A 级（官方原文）/ B 级（大型攻略站带截图）/ C 级（玩家社区，可能 AI 洗稿）
> - **诚实边界**：「公开网络资料几乎不会逐字记录某个弹窗上的按钮是什么字」——
>   能确认的是**功能存在性 + 主要界面文案 + 交互流程**；按钮级文案查不到就写「未查证到」，**不做推测**
> - 已确认的关键文案：`纳库佩达之池` / `虔诚许愿` / `呗果` / `环期赏令` / `维特海默塔` /
>   `粉爪大劫案` / `Tetrominoes` / `魔女之家` / `一咖舍` / `店长特供` / `渔具商店`
> - ⚠️ 且**严格遵守了铁律**：「**未接触任何游戏文件、未使用游戏本体资源、未解包**」

MaaNTE 侧现状速记（详见 `docs/文档库/Maa深度/MaaNTE移植对照表.md`、`docs/文档库/Maa深度/ROI反推规则.md`、`docs/文档库/探索文档/界面采集作业指令.md`）：

- 250 个 ROI 节点 override 已生成（181 规则套用 + 32 精确反推，+83 偏移规则），落地 `build/maa_pipeline_override.json`
- 剩 24 个缺模板节点需实机采集补齐（胜负加载屏、商店页、光标；SceneLoadingType2 的 '%' 与 Sync×6 疑似占位坏定义，可不采）
- 坐标体系 1470×923 固定不可变；运行期长边缩到 1280（截图 1280×803）；OCR 必须 GPU；按键走 ControlEngine CGEvent；游戏启动先点窗口、按 T 开车；Maa 只做工具，不整体接管
- BidKing（拍卖王）PR#434 代码已提取至独立文件夹 `BidKing_PR434/`（git 7b7d2db，未合并主线）
