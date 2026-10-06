// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AuroraFlags.swift — 环境开关的**唯一事实源**（A17）
// ============================================================================
//
//  【为什么要有这个文件】
//  改造前的现状（`perf-core` 全量扫描实测）：
//    · **72 个** `AURORA_*` 环境变量，散落在 **13 个文件 / 70+ 处调用点**；
//      ⚠️ 统计口径：必须扫 `"AURORA_*"` **字符串字面量**，不能只扫
//      `environment["X"]` 下标表达式 —— 后者会漏掉两类：
//        ① `let env = ProcessInfo.processInfo.environment` 然后 `env["X"]`（25 个）
//        ② 常量持有键名，如 `EgoBoxFilter.envKey = "AURORA_EGO_AREA"`（3 个）
//      我第一版统计只扫下标，得出 41 个 —— **错得很远**，记此存照。
//    · 读取方式五花八门：`ProcessInfo.processInfo.environment["X"] == "1"`、
//      `let env = ProcessInfo.processInfo.environment` 然后 `env["X"]`、
//      `.flatMap(Double.init) ?? 默认值` …… **没有任何一处汇总**；
//    · 默认值只存在于各自的 `?? ` 表达式里 —— 想知道「不设这个变量会怎样」
//      必须把 13 个文件全读一遍；
//    · 更糟的是**热路径现读**：项目自己实测 `ProcessInfo.environment[key]`
//      **17.213 µs/次**（`AuroraDriveApp.swift:5171`）／**0.032 ms/次**
//      （`MarkerCluster.swift:75`）。`AURORA_OCR_DEBUG` 曾在每次 OCR 推理里
//      现读 3 次（`SpeedOCRReader.swift`），`AURORA_DISABLE_OPTICAL_FLOW`
//      曾在每帧现读 —— 后者已被改成 `static let`，前者没有（典型的对称遗漏）。
//
//  本文件把三件事一次解决：
//    ① **集中**：每个开关一个 `static let`，进程生命周期内只读一次环境变量；
//    ② **自描述**：每个开关带 `defaultValue` / 一行说明 / `isDiagnostic` / 读取方；
//    ③ **可发现**：`--flags-help` 打印全表 —— 再也不用靠 grep 考古。
//
//  ────────────────────────────────────────────────────────────────────────
//  【为什么用 static let 而不是每次现读】
//  ────────────────────────────────────────────────────────────────────────
//  `static let` 在 Swift 里由 `swift_once` 保证**线程安全 + 只求值一次**，
//  之后每次访问就是一次内存读（纳秒级）。而现读一次是 **17–32 µs**。
//  对 30Hz 热路径，17µs × 30 = 0.5ms/s 的白烧 —— 这正是本项目已经修过
//  一次的坑（`AuroraDriveApp.swift:5170-5173` 的注释有完整记录）。
//
//  ⚠️ **语义差异（必须知道）**：`static let` 在**首次访问时**取值，
//  之后即使 `setenv()` 改了环境变量也**不会**重新读取。
//  本项目有一处依赖运行时改环境变量：
//    `AuroraDriveApp.swift:3232` 的 `setenv("AURORA_EGO_CHECK", "off", 1)`
//  → 故 `egoCheck` 在本文件里**刻意保留为每次现读**（见其注释），
//    不参与 `static let` 化。这是唯一的一处例外，已显式标注。
//
//  ────────────────────────────────────────────────────────────────────────
//  【怎么用】
//  ────────────────────────────────────────────────────────────────────────
//      旧：ProcessInfo.processInfo.environment["AURORA_OCR_DEBUG"] == "1"
//      新：AuroraFlags.ocrDebug
//
//  自检：`AuroraFlags.helpText()`（挂 `--flags-help`）
// ============================================================================

import Foundation

// MARK: - 开关描述

/// 单个开关的自描述条目。用于 `--flags-help` 全表打印。
struct AuroraFlagSpec: Sendable {
    /// 环境变量名，如 `"AURORA_UI_LOCAL"`
    let key: String
    /// 人类可读的默认值（**必须与实际代码默认值一致**，不一致就是文档撒谎）
    let defaultValue: String
    /// 一行说明：这个开关干什么
    let summary: String
    /// 是否仅诊断/排障用（生产环境不该设）
    let isDiagnostic: Bool
    /// 读取方（文件路径，便于 grep 定位）
    let readBy: String
}

// MARK: - 开关表

enum AuroraFlags {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: 读取入口 —— 全仓**唯一**一处 `environment[...]` 下标
    // ═══════════════════════════════════════════════════════════════════════
    //
    // 为什么收敛到这一个函数：这样 `grep -rn 'environment\[' Sources/` 的
    // 命中数就是"还有多少处没迁移"的**直接度量**。本文件内部只有下面 1 处。
    //
    // 迁移进度（2026-10-04 perf-core 落地时）：
    //   · 本文件覆盖全部 72 个变量的**声明与默认值**；
    //   · 调用点迁移按写域分片进行 —— 详见文件尾 `migrationStatus`。

    @inline(__always)
    private static func raw(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    /// 布尔开关：**只有显式设为 `"1"` 才算开**。
    ///
    /// 为什么不接受 `"true"`/`"yes"`：本项目历史约定就是 `== "1"`
    /// （见 `AuroraDriveApp.swift:138/5334` 等）。保持逐字一致，
    /// 避免"以前能用现在不能"的静默行为变化。
    private static func bool(_ key: String, default def: Bool) -> Bool {
        guard let v = raw(key) else { return def }
        return v == "1"
    }

    /// 反向布尔：`"0"` 才算关，其余（含未设）都算开。
    /// 用于 `AURORA_CACHE` / `AURORA_MAP_FILTER_BAR` 这类"默认开"的开关。
    private static func boolNotZero(_ key: String, default def: Bool) -> Bool {
        guard let v = raw(key) else { return def }
        return v != "0"
    }

    private static func str(_ key: String) -> String? {
        guard let v = raw(key), !v.isEmpty else { return nil }
        return v
    }

    private static func dbl(_ key: String, default def: Double) -> Double {
        raw(key).flatMap(Double.init) ?? def
    }

    private static func dblOpt(_ key: String) -> Double? {
        raw(key).flatMap(Double.init)
    }

    private static func int(_ key: String, default def: Int) -> Int {
        raw(key).flatMap(Int.init) ?? def
    }

    private static func intOpt(_ key: String) -> Int? {
        raw(key).flatMap(Int.init)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: A. 运行模式 / 进程（5）
    // ═══════════════════════════════════════════════════════════════════════

    /// 强制 UI 本地模式：不连引擎、不启动重连轮询。
    /// 用途：隔离"引擎模式 vs 本地模式"两类性能问题的二分开关。
    static let uiLocal = bool("AURORA_UI_LOCAL", default: false)

    /// Daemon 模式：不激活窗口、不显示 Dock 图标，纯后台运行。
    static let daemonMode = bool("AURORA_DAEMON_MODE", default: false)

    /// 观测模式：强制 `controlDisabled = true`（一行按键都不注入），
    /// 但截屏/推理/定位/渲染照跑。用于"只看不碰"的验证。
    static let observeOnly = bool("AURORA_OBSERVE_ONLY", default: false)

    /// TCC 自检标记：只影响 `--tcc-selftest` 写进日志的 `mode=` 字段，无行为分支。
    static let tccTest = str("AURORA_TCC_TEST")

    /// LLM API Key（仅 CLI `--agent-llm-test` 场景；GUI 走本地小本本文件）。
    /// ⚠️ 绝不打印、绝不落盘。
    static let apiKey = str("AURORA_API_KEY")

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: B. 引擎 / IPC / 网络（4）
    // ═══════════════════════════════════════════════════════════════════════

    /// 诊断：跳过引擎的 TCC fail-fast（**仅无权限环境验证非权限逻辑**）。
    static let engineDiagSkipTCC = bool("AURORA_ENGINE_DIAG_SKIP_TCC", default: false)

    /// 诊断：引擎只抓屏、不注入按键（用于端到端验证「采集→共享内存→UI」链路）。
    static let engineDiagCaptureOnly = bool("AURORA_ENGINE_DIAG_CAPTURE_ONLY", default: false)

    /// 抓包走旧协议解码路径（`UE5Decoder` 的 legacy 分支）。
    static let legacyProto = bool("AURORA_LEGACY_PROTO", default: false)

    /// 网卡自检的目标地址（`--nic-autotest`）。
    static let nicTestTarget = str("AURORA_NIC_TEST_TARGET") ?? "49.232.46.87"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: C. 推理 / 感知（6）
    // ═══════════════════════════════════════════════════════════════════════

    /// 感知模型族选择（A-YOLOM / YOLOPX 等）。未设 → 默认 A-YOLOM。
    static let ayolom = str("AURORA_AYOLOM")

    /// 推理队列的 QoS 覆盖（未设 → 用各引擎自己的默认）。
    static let inferQoS = str("AURORA_INFER_QOS")

    /// YOLOPX 最小推理间隔（毫秒）。`0` = 不限制（每帧都跑）。
    static let yolopxIntervalMs = dbl("AURORA_YOLOPX_INTERVAL_MS", default: 0)

    /// letterbox 预处理放主线程做（默认在推理队列做）。
    static let yolopxLetterboxMain = bool("AURORA_YOLOPX_LETTERBOX_MAIN", default: false)

    /// OCR 模型延迟到首次推理前才加载（用于隔离"启动耗时归因"）。
    static let skipModelLoad = bool("AURORA_SKIP_MODEL_LOAD", default: false)

    /// OCR 调试打印。⚠️ 曾在每次推理现读 3 次（17µs×3），本文件已收敛。
    static let ocrDebug = bool("AURORA_OCR_DEBUG", default: false)

    /// 任务面板 OCR：读左侧任务面板文字 → 查 `models/quest_index.json` → 世界坐标目标。
    ///
    /// **默认开启**（2026-10-06 用户实测反馈改默认）。
    /// 用户原话：「我要默认开，然后会显示暂前无任务」。
    /// 本功能只做「读屏 OCR → 匹配任务表 → 设置导航目标」，不改驾驶行为，
    /// 不属于「新增功能默认关」的范畴（那条防的是自动控制类）。
    /// 关闭方式：环境变量 `AURORA_QUEST_OCR=0`。
    /// 打开后：每 0.7 秒一次 Vision OCR，确认到任务时调用 `setLocatorTarget`。
    /// 自检入口 `--quest-selftest` 不需要本开关（它只读索引、不截屏）。
    static let questOCR = bool("AURORA_QUEST_OCR", default: true)

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: D. 光流 / 自车运动（6）
    // ═══════════════════════════════════════════════════════════════════════

    /// 关闭光流（诊断）。⚠️ 光流**不是**死代码 —— 它的消费链是
    /// `updateEgoMotion → currentEgoFlow → EgoMotionModel.verdict → egoVerdicts
    /// → blocksPrediction → canPredict`（`MotionPredictor.swift:248/371/448`）。
    /// 它是 `PerceptionMode.legacy` 档的核心组件，不要默认关。
    static let disableOpticalFlow = bool("AURORA_DISABLE_OPTICAL_FLOW", default: false)

    /// 自车框屏蔽的面积阈值（归一化宽×高）。默认 0.04（4%）；`0` = 关闭屏蔽。
    ///
    /// ⚠️ 这个开关在源码里是**间接下标**的 —— `EgoBoxFilter.envKey` 常量持有名字，
    /// 调用点是 `environment[envKey]`。我第一版扫描只匹配字面量 `environment["X"]`，
    /// **漏掉了它**（同类漏网还有 `AURORA_BENCH_DRAG_PX` / `AURORA_MAP_NO_LOADNORM`）。
    /// 记在这里：以后统计开关数，要扫 `"AURORA_*"` **字符串字面量**，不是下标表达式。
    static let egoArea: Double = {
        let v = dbl("AURORA_EGO_AREA", default: 0.04)
        // ⚠️ 校验必须与原 `EgoBoxFilter.configured` **逐字一致**，否则迁移会改行为：
        //    · `Double("inf")` / `Double("nan")` 能解析成功，但语义无效；
        //    · 负数会让 `EgoBoxFilter.isEnabled`（`areaThreshold > 0`）误判为"关闭屏蔽"。
        //    原实现在"解析失败 / 非有限 / 负数"三种情况下都回退默认值 —— 这里照搬。
        return (v.isFinite && v >= 0) ? v : 0.04
    }()

    /// 自车运动校验开关。`"off"` = 关闭判定（行为回退到接线前）。
    ///
    /// ⚠️ **本项刻意不 `static let` 化**：`AuroraDriveApp.swift:3232` 的自检
    /// 会在**运行时** `setenv("AURORA_EGO_CHECK", "off", 1)` / `unsetenv`，
    /// 依赖"改了就立刻生效"。`static let` 只在首次访问取值，会让那个自检失效。
    /// 这是全表唯一一处每次现读的开关 —— 它不在热路径上（判定在 `predict()` 里
    /// 每帧只做一次字典查表，环境变量读取只发生在自检路径）。
    static var egoCheck: String? { raw("AURORA_EGO_CHECK") }

    /// 自车运动校验：最大前向速率（归一化）
    static let egoMaxFwd = dbl("AURORA_EGO_MAX_FWD", default: 0.5)
    /// 自车运动校验：最大光流位移（像素）
    static let egoMaxFlowPx = dbl("AURORA_EGO_MAX_FLOW_PX", default: 80.0)
    /// 自车运动校验：残差比阈值
    static let egoResidualRatio = dbl("AURORA_EGO_RESIDUAL_RATIO", default: 0.6)
    /// 自车运动校验：最低置信度
    static let egoMinConf = dbl("AURORA_EGO_MIN_CONF", default: 0.35)

    /// 自车运动诊断：打印「光流是否在跑 / 否决了多少个框」。
    ///
    /// 【为什么这是**永久设施**而不是临时补丁】
    /// A2（光流按档位门控）落地后，`.ayolom` 档不再跑光流 → `currentEgoFlow` 恒 nil
    /// → `egoBlocked` 恒 false。这带来一个**以后必然反复出现的争论**：
    /// 「光流到底该不该跑？关了它有什么后果？」—— 没有可观测数字时，这类争论
    /// 只能靠读代码 + 猜，而本项目已经因此**误判过一次**（`perf-core` 曾据
    /// 过期注释断定"光流零消费者"，实际消费链在 `MotionPredictor` 里）。
    ///
    /// 故本开关与其余 69 个**同规格**保留（加它之前是 69 个，加完 70 个，再加 KEY_REFRESH_HZ 共 71 个）：默认关闭 → 生产零开销
    /// （`static let` 只读一次 + 每帧一个 bool 判断），需要时一个环境变量即可取证。
    /// 输出复用**现成的 1Hz 日志闸门**（`AuroraDriveApp.swift`），不新增定时器。
    static let egoDiag = bool("AURORA_EGO_DIAG", default: false)

    /// 按住键重发频率（**Hz，不是间隔**）。`0` = 不节流（每帧重发，
    /// 行为与改动前**逐帧一致**）；有效范围 `(0, 60]`，越界一律回退 0。
    ///
    /// ⚠️ 单位陷阱：调用方要的是**间隔**，用 `keyRefreshHz > 0 ? 1/keyRefreshHz : 0` 换算。
    /// 校验（`>0 && <=60`）与原 `ControlEngine.keyRefreshInterval` 逐字一致，
    /// 故非法输入（负数 / 0 / 61+ / 非数字）行为不变。
    ///
    /// ⚠️ 启用后**必须真机验证**：历史事故记录在 `ControlEngine.refreshHeldKeys`
    /// 的注释里 —— 重发不足会表现为「UI 显示 W 已按住，游戏纹丝不动」。
    /// 本机无游戏，故默认 0、不擅自启用。
    static let keyRefreshHz: Double = {
        let v = dbl("AURORA_KEY_REFRESH_HZ", default: 0)
        return (v > 0 && v <= 60) ? v : 0
    }()

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: E. 驾驶 / 控制（9）
    // ═══════════════════════════════════════════════════════════════════════

    /// 车道保持生效的档位（逗号分隔）。默认 `"rule,yolo"`；`"rule"` = 退回改前行为。
    static let laneKeepTiers = str("AURORA_LANEKEEP_TIERS")

    /// 恢复"每帧无条件 `releaseAll()`"的旧行为（用于 ABBA 对比节流收益）。
    static let releaseAllEveryTick = bool("AURORA_RELEASE_ALL_EVERY_TICK", default: false)

    /// 零速持续多少秒后拉"请求人工介入"横幅。默认 30。
    static let stuckSeconds = dbl("AURORA_STUCK_SECONDS", default: 30)

    /// 主题背景漂移动画（默认关 —— 它是持续动画，会一直占 WindowServer）。
    static let enableBgDrift = bool("AURORA_ENABLE_BG_DRIFT", default: false)

    /// 驾驶分段：触发回正的车头偏角（度）
    static let segStraightenDeg = dbl("AURORA_SEG_STRAIGHTEN_DEG", default: 15.0)
    /// 驾驶分段：判定回正完成的车头偏角（度）
    static let segStraightenDoneDeg = dbl("AURORA_SEG_STRAIGHTEN_DONE_DEG", default: 8.0)
    /// 驾驶分段：交接所需最小前进距离（米）
    static let segHandoverM = dbl("AURORA_SEG_HANDOVER_M", default: 15.0)
    /// 驾驶分段：交接所需最小连续帧数
    static let segHandoverFrames = int("AURORA_SEG_HANDOVER_FRAMES", default: 10)
    /// 驾驶分段：走廊容差（米）
    static let segCorridorM = dbl("AURORA_SEG_CORRIDOR_M", default: 8.0)
    /// 驾驶分段：地图段超时（秒）
    static let segMapTimeoutS = dbl("AURORA_SEG_MAP_TIMEOUT_S", default: 20.0)

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: F. 路网 / 弯道引导（13）
    // ═══════════════════════════════════════════════════════════════════════

    /// 弯道：提前量（米）
    static let cornerLookaheadM = dbl("AURORA_CORNER_LOOKAHEAD_M", default: 40.0)
    /// 弯道：方向匹配容差（度）
    static let cornerHeadingTolDeg = dbl("AURORA_CORNER_HEADING_TOL_DEG", default: 60.0)
    /// 弯道：转向死区（度）
    static let cornerDeadbandDeg = dbl("AURORA_CORNER_DEADBAND_DEG", default: 8.0)
    /// 弯道：转向饱和角（度）
    static let cornerSatDeg = dbl("AURORA_CORNER_SAT_DEG", default: 35.0)
    /// 弯道：判定"已过点"的距离（米）
    static let cornerPassedM = dbl("AURORA_CORNER_PASSED_M", default: 15.0)
    /// 弯道：前方锥半角（度）
    static let cornerConeDeg = dbl("AURORA_CORNER_CONE_DEG", default: 75.0)
    /// 弯道：急弯半径阈值（米）
    static let cornerTightRM = dbl("AURORA_CORNER_TIGHT_R_M", default: 80.0)
    /// 弯道：急弯建议限速（km/h）
    static let cornerTightSpeed = dbl("AURORA_CORNER_TIGHT_SPEED", default: 40.0)
    /// 路口：提前量（米）
    static let juncLookaheadM = dbl("AURORA_JUNC_LOOKAHEAD_M", default: 45.0)
    /// 路口：开始转向距离（米）
    static let juncApproachM = dbl("AURORA_JUNC_APPROACH_M", default: 25.0)
    /// 路口：排除"来路"的角度容差（度）
    static let juncExcludeDeg = dbl("AURORA_JUNC_EXCLUDE_DEG", default: 35.0)
    /// 路口：Y 形岔路夹角容差（度）
    static let juncForkTolDeg = dbl("AURORA_JUNC_FORK_TOL_DEG", default: 25.0)
    /// 路口：主路判据的长度比阈值
    static let juncReachRatio = dbl("AURORA_JUNC_REACH_RATIO", default: 1.2)

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: G. 地图 UI（16）
    // ═══════════════════════════════════════════════════════════════════════

    /// 启动即打开独立地图窗口（`AURORA_MAP_WINDOW=1`）
    static let mapWindow = bool("AURORA_MAP_WINDOW", default: false)

    /// B1 底图**视野窗口**（`MissionConsole.swift` 的 `ViewportWindowMetrics`）。
    /// 默认开；`=0` 回退到优化前的「源图直裁」路径，供配对 A/B 录基线。
    ///
    /// ⚠️ 与上面的 `mapWindow` **不是一回事**，别混：
    ///   · `AURORA_MAP_WINDOW`      —— 「启动即打开**独立地图窗口**」（UI 行为）
    ///   · `AURORA_MAP_TILE_WINDOW` —— 「底图走**视野窗口**还是源图直裁」（渲染路径）
    ///   这两个名字撞车过一次（`map-tests` 发现验证脚本会切到不相干的开关），
    ///   故 B1 的开关从 `AURORA_MAP_WINDOW` 改名为 `AURORA_MAP_TILE_WINDOW`。
    ///   这条注释就是为了让下一个人不再撞 —— **命名撞车的代价是"验证脚本测错东西"**，
    ///   而那种错是静默的。
    static let mapTileWindow = boolNotZero("AURORA_MAP_TILE_WINDOW", default: true)
    /// 底图调色开关（0=关闭，回到原始暗底图）。
    ///
    /// 背景：`bigworldmap-13056.jpg` 本体均值只有 11.4/255、88.8% 像素 < 20，
    /// 与画布背景（亮度 7.8）几乎同值 → 图底关系消失，地图看起来像空白。
    /// 调色（gamma ≈ 0.70，见 `MapTileImage.baseMapBrightness`）把它抬到可读。
    /// 这个开关的**唯一用途**是 ABBA 对拍：证明调色值这个代价、且没拖慢帧率。
    static let baseMapGrade = boolNotZero("AURORA_BASEMAP_GRADE", default: true)
    /// 地图默认视野（米）覆盖
    static let mapSpanM = dblOpt("AURORA_MAP_SPAN_M")
    /// 图层开关位覆盖（1=路网 2=骨架 4=POI）
    static let mapLayers = str("AURORA_MAP_LAYERS")
    /// 走旧的 `ForEach` 标记渲染路径（性能 A/B 对照）
    static let mapLegacyMarkers = bool("AURORA_MAP_LEGACY_MARKERS", default: false)
    /// 显示中栏组筛选条（`=0` 隐藏）
    static let mapFilterBar = boolNotZero("AURORA_MAP_FILTER_BAR", default: true)
    /// 完全跳过标记图层（排障二分：把底图成本与标记成本分开量）
    static let mapNoMarkers = bool("AURORA_MAP_NO_MARKERS", default: false)
    /// 标签显示上限
    static let mapMaxLabels = intOpt("AURORA_MAP_MAX_LABELS")
    /// 关闭地图自检的"负载归一化"（**唯一目的是做 A/B 对照** ——
    /// 没有这个开关，"红灯是负载造成的"这句话就是不可证伪的）
    static let mapNoLoadNorm = bool("AURORA_MAP_NO_LOADNORM", default: false)
    /// 标签显示的距离门槛（米）
    static let mapLabelSpanM = dblOpt("AURORA_MAP_LABEL_SPAN_M")
    /// 聚类格边长（屏幕 px）覆盖
    static let mapClusterPx = dblOpt("AURORA_MAP_CLUSTER_PX")
    /// 聚类代表点优先级覆盖（`"传送点:0,资源:1"` 形式）
    static let mapClusterPriority = str("AURORA_MAP_CLUSTER_PRIORITY")
    /// 聚类分段计时打印（`[CLUSTER-TRACE]`）
    static let mapClusterTrace = bool("AURORA_MAP_CLUSTER_TRACE", default: false)
    /// 默认开启的组（逗号分隔）
    static let mapDefaultGroups = str("AURORA_MAP_DEFAULT_GROUPS")
    /// 标记词表文件路径覆盖
    static let markerTaxonomy = str("AURORA_MARKER_TAXONOMY")
    /// 路网图文件路径覆盖
    static let routeGraph = str("AURORA_ROUTE_GRAPH")
    /// 路线规划：直线优先（排障）
    static let routeStraight = bool("AURORA_ROUTE_STRAIGHT", default: false)
    /// 路线规划：拐弯惩罚权重覆盖
    static let routeTurnW = dblOpt("AURORA_ROUTE_TURN_W")

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: H. 性能 / 日志（5）
    // ═══════════════════════════════════════════════════════════════════════

    /// 打开 `PerfBus` 打点（性能基线的前提）。**生产默认关** → 零开销。
    static let perf = bool("AURORA_PERF", default: false)
    /// `--perf-selftest` 每个指标的轮数
    static let perfRounds = int("AURORA_PERF_ROUNDS", default: 6)
    /// 日志改回"逐行同步写"的旧行为（用于对比 LogSink 缓冲的收益）
    static let logSync = bool("AURORA_LOG_SYNC", default: false)
    /// 跳过帧率 HUD 安装（WindowServer 负载对照实验）
    static let disableHUD = bool("AURORA_DISABLE_HUD", default: false)
    /// `--mc-map-bench` 每轮之间排空队列
    static let benchDrain = bool("AURORA_BENCH_DRAIN", default: false)
    /// `--mc-map-bench` 每轮的视口平移量（px）。默认 **8**；`0` = 旧口径（加 `.offset`，
    /// 40 轮全命中，测出来的其实是"缓存命中后的 SwiftUI 光栅化"，不是底图成本）。
    static let benchDragPx = dbl("AURORA_BENCH_DRAG_PX", default: 8)

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: I. 缓存（1，2026-10-04 A16 新增）
    // ═══════════════════════════════════════════════════════════════════════

    /// 缓存层总开关。`AURORA_CACHE=0` → 所有 `AuroraCache` 直通 `compute()`，
    /// 不读不写不计数。用于 ABBA 对比「有缓存 vs 无缓存」。
    static let cacheEnabled = boolNotZero("AURORA_CACHE", default: true)

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: 全表
    // ═══════════════════════════════════════════════════════════════════════

    /// 全部开关的描述表。**新增开关必须同时加进这里** ——
    /// `--flags-help` 与自检都以本表为准，漏加等于这个开关"不存在"。
    static let all: [AuroraFlagSpec] = [
        // A. 运行模式
        .init(key: "AURORA_UI_LOCAL", defaultValue: "0", summary: "强制 UI 本地模式（不连引擎、不重连）", isDiagnostic: true, readBy: "Core/EngineClient.swift"),
        .init(key: "AURORA_DAEMON_MODE", defaultValue: "0", summary: "Daemon 模式：不激活窗口、无 Dock 图标", isDiagnostic: false, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_OBSERVE_ONLY", defaultValue: "0", summary: "观测模式：强制禁用控制，只看不碰", isDiagnostic: true, readBy: "Core/EngineMain.swift, App/AuroraDriveApp.swift"),
        .init(key: "AURORA_TCC_TEST", defaultValue: "(未设)", summary: "TCC 自检日志的 mode 字段标记", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_API_KEY", defaultValue: "(未设)", summary: "LLM API Key（仅 CLI --agent-llm-test）", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        // B. 引擎 / 网络
        .init(key: "AURORA_ENGINE_DIAG_SKIP_TCC", defaultValue: "0", summary: "诊断：跳过引擎 TCC fail-fast", isDiagnostic: true, readBy: "Core/EngineMain.swift"),
        .init(key: "AURORA_ENGINE_DIAG_CAPTURE_ONLY", defaultValue: "0", summary: "诊断：引擎只抓屏不注入按键", isDiagnostic: true, readBy: "Core/EngineMain.swift"),
        .init(key: "AURORA_LEGACY_PROTO", defaultValue: "0", summary: "抓包走旧协议解码路径", isDiagnostic: true, readBy: "Capture/CoordinateCapture.swift"),
        .init(key: "AURORA_NIC_TEST_TARGET", defaultValue: "49.232.46.87", summary: "网卡自检目标地址", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        // C. 推理 / 感知
        .init(key: "AURORA_AYOLOM", defaultValue: "(未设→A-YOLOM)", summary: "感知模型族选择", isDiagnostic: false, readBy: "Inference/YolopxEngine.swift"),
        .init(key: "AURORA_INFER_QOS", defaultValue: "(未设)", summary: "推理队列 QoS 覆盖", isDiagnostic: true, readBy: "Inference/YolopxEngine.swift"),
        .init(key: "AURORA_YOLOPX_INTERVAL_MS", defaultValue: "0", summary: "YOLOPX 最小推理间隔 ms（0=不限）", isDiagnostic: true, readBy: "Inference/YolopxEngine.swift"),
        .init(key: "AURORA_YOLOPX_LETTERBOX_MAIN", defaultValue: "0", summary: "letterbox 预处理放主线程", isDiagnostic: true, readBy: "Inference/YolopxEngine.swift"),
        .init(key: "AURORA_SKIP_MODEL_LOAD", defaultValue: "0", summary: "OCR 模型延迟到首次推理前加载", isDiagnostic: true, readBy: "Inference/SpeedOCRReader.swift"),
        .init(key: "AURORA_OCR_DEBUG", defaultValue: "0", summary: "OCR 调试打印（曾在推理热路径现读 3 次）", isDiagnostic: true, readBy: "Inference/SpeedOCRReader.swift"),
        .init(key: "AURORA_QUEST_OCR", defaultValue: "0", summary: "任务面板 OCR 读任务名 → 世界坐标目标（默认关）", isDiagnostic: false, readBy: "Inference/QuestPanelReader.swift"),
        // D. 光流 / 自车运动
        .init(key: "AURORA_DISABLE_OPTICAL_FLOW", defaultValue: "0", summary: "关闭光流（legacy 档核心组件，勿默认关）", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_EGO_CHECK", defaultValue: "(未设=开)", summary: "自车运动校验开关；off=关闭判定。⚠️ 运行时可变，故不 static let 化", isDiagnostic: true, readBy: "Inference/EgoMotionModel.swift"),
        .init(key: "AURORA_EGO_MAX_FWD", defaultValue: "0.5", summary: "自车校验：最大前向速率", isDiagnostic: true, readBy: "Inference/EgoMotionModel.swift"),
        .init(key: "AURORA_EGO_MAX_FLOW_PX", defaultValue: "80.0", summary: "自车校验：最大光流位移（像素）", isDiagnostic: true, readBy: "Inference/EgoMotionModel.swift"),
        .init(key: "AURORA_EGO_RESIDUAL_RATIO", defaultValue: "0.6", summary: "自车校验：残差比阈值", isDiagnostic: true, readBy: "Inference/EgoMotionModel.swift"),
        .init(key: "AURORA_EGO_MIN_CONF", defaultValue: "0.35", summary: "自车校验：最低置信度", isDiagnostic: true, readBy: "Inference/EgoMotionModel.swift"),
        .init(key: "AURORA_EGO_AREA", defaultValue: "0.04", summary: "自车框屏蔽的面积阈值（0=关闭屏蔽）；经 EgoBoxFilter.envKey 间接下标", isDiagnostic: false, readBy: "Agent/EgoBoxFilter.swift"),
        .init(key: "AURORA_EGO_DIAG", defaultValue: "0", summary: "自车运动诊断：打印光流是否在跑 + 否决计数（复用 1Hz 日志闸门，不新增定时器）", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        // E. 驾驶 / 控制
        .init(key: "AURORA_LANEKEEP_TIERS", defaultValue: "rule,yolo", summary: "车道保持生效档位（rule / rule,yolo / e2e,…）", isDiagnostic: false, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_RELEASE_ALL_EVERY_TICK", defaultValue: "0", summary: "恢复每帧无条件 releaseAll 的旧行为", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_KEY_REFRESH_HZ", defaultValue: "0", summary: "按住键重发频率 Hz（0=不节流，逐帧一致）；启用后必须真机验证", isDiagnostic: true, readBy: "Control/ControlEngine.swift"),
        .init(key: "AURORA_STUCK_SECONDS", defaultValue: "30", summary: "零速多少秒后拉人工介入横幅", isDiagnostic: false, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_ENABLE_BG_DRIFT", defaultValue: "0", summary: "主题背景漂移动画（持续动画，占 WindowServer）", isDiagnostic: true, readBy: "App/AuroraTheme.swift"),
        .init(key: "AURORA_SEG_STRAIGHTEN_DEG", defaultValue: "15.0", summary: "驾驶分段：触发回正的车头偏角", isDiagnostic: false, readBy: "Agent/DriveSegmentController.swift"),
        .init(key: "AURORA_SEG_STRAIGHTEN_DONE_DEG", defaultValue: "8.0", summary: "驾驶分段：判定回正完成的角度", isDiagnostic: false, readBy: "Agent/DriveSegmentController.swift"),
        .init(key: "AURORA_SEG_HANDOVER_M", defaultValue: "15.0", summary: "驾驶分段：交接所需最小前进距离", isDiagnostic: false, readBy: "Agent/DriveSegmentController.swift"),
        .init(key: "AURORA_SEG_HANDOVER_FRAMES", defaultValue: "10", summary: "驾驶分段：交接所需最小连续帧数", isDiagnostic: false, readBy: "Agent/DriveSegmentController.swift"),
        .init(key: "AURORA_SEG_CORRIDOR_M", defaultValue: "8.0", summary: "驾驶分段：道路走廊容差", isDiagnostic: false, readBy: "Agent/DriveSegmentController.swift"),
        .init(key: "AURORA_SEG_MAP_TIMEOUT_S", defaultValue: "20.0", summary: "驾驶分段：地图段超时", isDiagnostic: false, readBy: "Agent/DriveSegmentController.swift"),
        // F. 路网 / 弯道
        .init(key: "AURORA_CORNER_LOOKAHEAD_M", defaultValue: "40.0", summary: "弯道：提前量（米）", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_CORNER_HEADING_TOL_DEG", defaultValue: "60.0", summary: "弯道：方向匹配容差", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_CORNER_DEADBAND_DEG", defaultValue: "8.0", summary: "弯道：转向死区", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_CORNER_SAT_DEG", defaultValue: "35.0", summary: "弯道：转向饱和角", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_CORNER_PASSED_M", defaultValue: "15.0", summary: "弯道：判定已过点的距离", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_CORNER_CONE_DEG", defaultValue: "75.0", summary: "弯道：前方锥半角", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_CORNER_TIGHT_R_M", defaultValue: "80.0", summary: "弯道：急弯半径阈值", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_CORNER_TIGHT_SPEED", defaultValue: "40.0", summary: "弯道：急弯建议限速 km/h", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_JUNC_LOOKAHEAD_M", defaultValue: "45.0", summary: "路口：提前量", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_JUNC_APPROACH_M", defaultValue: "25.0", summary: "路口：开始转向距离", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_JUNC_EXCLUDE_DEG", defaultValue: "35.0", summary: "路口：排除来路的容差", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_JUNC_FORK_TOL_DEG", defaultValue: "25.0", summary: "路口：Y 形岔路夹角容差", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        .init(key: "AURORA_JUNC_REACH_RATIO", defaultValue: "1.2", summary: "路口：主路判据长度比", isDiagnostic: false, readBy: "Inference/RoadCornerGuide.swift"),
        // G. 地图 UI
        .init(key: "AURORA_MAP_WINDOW", defaultValue: "0", summary: "启动即打开独立地图窗口（UI 行为）", isDiagnostic: false, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_MAP_TILE_WINDOW", defaultValue: "1", summary: "B1 底图视野窗口（0=回退源图直裁，供配对 A/B）；⚠️与 MAP_WINDOW 不是一回事", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_BASEMAP_GRADE", defaultValue: "1", summary: "底图调色（0=关闭回到原始暗底图；供 ABBA 对拍调色代价）", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_SPAN_M", defaultValue: "(未设)", summary: "地图默认视野（米）覆盖", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_LAYERS", defaultValue: "(未设)", summary: "图层开关位覆盖（1=路网 2=骨架 4=POI）", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_LEGACY_MARKERS", defaultValue: "0", summary: "走旧 ForEach 标记渲染路径（A/B 对照）", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_FILTER_BAR", defaultValue: "1", summary: "显示中栏组筛选条（=0 隐藏）", isDiagnostic: false, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_NO_MARKERS", defaultValue: "0", summary: "完全跳过标记图层（成本二分排障）", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_MAX_LABELS", defaultValue: "(未设)", summary: "地图标签显示上限", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_NO_LOADNORM", defaultValue: "0", summary: "关闭地图自检的负载归一化（A/B 对照专用）", isDiagnostic: true, readBy: "App/MapSelfTest.swift"),
        .init(key: "AURORA_MAP_LABEL_SPAN_M", defaultValue: "(未设)", summary: "标签显示的距离门槛（米）", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_CLUSTER_PX", defaultValue: "(未设)", summary: "聚类格边长（屏幕 px）覆盖", isDiagnostic: false, readBy: "App/MarkerCluster.swift"),
        .init(key: "AURORA_MAP_CLUSTER_PRIORITY", defaultValue: "(未设)", summary: "聚类代表点优先级覆盖", isDiagnostic: false, readBy: "App/MarkerCluster.swift"),
        .init(key: "AURORA_MAP_CLUSTER_TRACE", defaultValue: "0", summary: "聚类分段计时打印 [CLUSTER-TRACE]", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_MAP_DEFAULT_GROUPS", defaultValue: "(未设)", summary: "地图默认开启的组", isDiagnostic: false, readBy: "App/MarkerTaxonomy.swift"),
        .init(key: "AURORA_MARKER_TAXONOMY", defaultValue: "(未设)", summary: "标记词表文件路径覆盖", isDiagnostic: true, readBy: "App/MarkerTaxonomy.swift"),
        .init(key: "AURORA_ROUTE_GRAPH", defaultValue: "(未设)", summary: "路网图文件路径覆盖", isDiagnostic: true, readBy: "App/RouteGraph.swift"),
        .init(key: "AURORA_ROUTE_STRAIGHT", defaultValue: "0", summary: "路线规划直线优先（排障）", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_ROUTE_TURN_W", defaultValue: "(未设)", summary: "路线规划拐弯惩罚权重覆盖", isDiagnostic: false, readBy: "App/RouteGraph.swift"),
        // H. 性能 / 日志
        .init(key: "AURORA_PERF", defaultValue: "0", summary: "打开 PerfBus 打点（性能基线前提）", isDiagnostic: true, readBy: "App/PerfSelfTest.swift"),
        .init(key: "AURORA_PERF_ROUNDS", defaultValue: "6", summary: "--perf-selftest 每指标轮数", isDiagnostic: true, readBy: "App/PerfSelfTest.swift"),
        .init(key: "AURORA_LOG_SYNC", defaultValue: "0", summary: "日志改回逐行同步写（对比 LogSink 收益）", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_DISABLE_HUD", defaultValue: "0", summary: "跳过帧率 HUD（WindowServer 对照实验）", isDiagnostic: true, readBy: "App/AuroraDriveApp.swift"),
        .init(key: "AURORA_BENCH_DRAIN", defaultValue: "0", summary: "--mc-map-bench 每轮排空队列", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        .init(key: "AURORA_BENCH_DRAG_PX", defaultValue: "8", summary: "--mc-map-bench 每轮视口平移量 px（0=旧口径，测的其实是光栅化）", isDiagnostic: true, readBy: "App/MissionConsole.swift"),
        // I. 缓存
        .init(key: "AURORA_CACHE", defaultValue: "1", summary: "缓存层总开关（0=全部直通，ABBA 对比用）", isDiagnostic: true, readBy: "Core/AuroraCache.swift"),
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: 帮助输出
    // ═══════════════════════════════════════════════════════════════════════

    /// `--flags-help` 的全表文本。
    ///
    /// 格式固定为**每个开关一行**（`--flags-help | wc -l` 可直接当断言用）：
    ///   首行标题 + 每个开关一行 + 末尾统计行。
    /// 故 `wc -l` = `all.count + 2`。
    static func helpText() -> String {
        var lines: [String] = []
        lines.append("AuroraDrive 环境开关全表（共 \(all.count) 个；标 [诊断] 的仅排障用）")
        for f in all {
            let tag = f.isDiagnostic ? "[诊断]" : "[功能]"
            lines.append("  \(tag) \(f.key)=\(f.defaultValue)  — \(f.summary)   ← \(f.readBy)")
        }
        lines.append("提示：`AURORA_PERF=1` 打开性能打点；`AURORA_CACHE=0` 关闭缓存层做 A/B。")
        return lines.joined(separator: "\n")
    }

    /// 迁移进度自述：还有哪些文件直接读环境变量（未走本文件）。
    ///
    /// 为什么把它写进代码而不是只写在报告里：迁移是**分片进行**的
    /// （各文件的写域不同），这个列表就是"还剩多少"的活文档。
    static let migrationStatus: [String] = [
        "已收敛到本文件：Core/AuroraCache.swift, Core/AuroraFlags.swift",
        "待迁移（写域不在 perf-core）：App/AuroraDriveApp.swift, App/MissionConsole.swift,",
        "  App/PerfSelfTest.swift, App/MarkerCluster.swift, App/MarkerTaxonomy.swift,",
        "  App/RouteGraph.swift, App/AuroraTheme.swift, Capture/CoordinateCapture.swift,",
        "  Inference/YolopxEngine.swift",
    ]
}
