# 代码-02 AuroraPaths 项目根定位

> ✅ **2026-11-25 去行号化复核**：全文行号引用已全部替换为源码真实符号名（`enum AuroraPaths`、`projectRoot()`、`resolveRoot()`、`cachedRoot`、`modelsDir()`、`dataDir()`，以及各调用方所在函数/类型）。`Sources/AuroraDrive/Core/AuroraPaths.swift` 全文件（`enum AuroraPaths` 一个类型 + `projectRoot()`/`resolveRoot()`/`modelsDir()`/`dataDir()`），结构与本文描述一致，无需改写原描述。

> **二〇二六年十一月二十五日重基准**：`grep -rn "AuroraPaths\." Sources/` 实测 **23 个文件、共 66 处提及**，其中 7 处是注释/散文提及（`LeanRecordEngine.swift` 的 `clipsRoot` 说明、`AuroraPaths.swift` 的候选 1 注释、`AuroraDriveApp.swift` 的 `detectedModelName` 前注、`MapWiring.swift` 的 `loadFromDisk` 前注、`AuroraBrand.swift` 两处对照注释、`SpeedOCRReader.swift` 的 `modelCandidates` 注释）→ **真实代码调用 59 处**。`modelsDir()` 现有 **9 处**调用；`dataDir()` 仍**无人调用**（预留 API）。

> 覆盖源文件：`Sources/AuroraDrive/Core/AuroraPaths.swift`（全文件）。

## 一、projectRoot() 多候选根目录解析

**为什么存在**：源码重组进 `Sources/AuroraDrive/Core/` 后，`#filePath` 不再指向项目根（见文件头注释）。本项目零外部依赖、模型/数据/录制目录都在仓库根（`models/`、`data/`），但进程启动方式多样（SwiftPM 直启、双击 AuroraDriveUI、.app bundle、`--engine` 子进程），cwd 各不相同——所以需要一个统一的多候选解析器，供 `RecordEngine`（Glyph 模式与录制根）、`InferenceEngine`（models）、`CoordinateCapture` 等定位资源。

**签名**：`static func projectRoot() -> URL`（无参，返回项目根 URL），函数体只有一句 `cachedRoot` 读取——真正的探测在 `resolveRoot()`。

**缓存**：`private static let cachedRoot: URL = resolveRoot()`——`static let` 由 `swift_once` 保证线程安全且只求值一次（P-3 修复：原 `nonisolated(unsafe) static var cachedRoot` 有数据竞争，多线程可能各探测一遍）。`projectRoot()` 每次调用只读一次内存。

**候选解析（`resolveRoot()` 内）**：先按优先级放入 3 个初始候选，再附加「可执行文件目录逐级上溯 ≤6 级」的机器无关兜底候选：

| # | 候选 | 适用场景 |
|---|---|---|
| 1 | `#filePath` 上溯 4 级（`Sources/AuroraDrive/Core/AuroraPaths.swift` → 项目根） | SwiftPM 从源码树构建运行（编译期路径可信） |
| 2 | `FileManager.default.currentDirectoryPath`（cwd） | 从项目根手动启动 |
| 3 | `Bundle.main.executableURL?.deletingLastPathComponent()`（`execDir`） | 双击 AuroraDriveUI 启动（cwd 即此处） |
| 4 | 可执行文件目录**逐级上溯 ≤6 级**（循环 `dir.deletingLastPathComponent()`，遇 `"/"` 即 `break`） | 二进制在 `.build/` 构建树内、或装在项目树任意处（机器无关） |

> ⚠️ 历史第 4 候选曾硬编码绝对路径 `/Users/dupi/Desktop/自动驾驶系统` 做兜底，**P-1 已删除**——换机器/换用户名会静默失效，且个人路径进源码是隐私问题（`resolveRoot()` 内 P-1 注释块；中间还记了一次「换成 `homeDirectoryForCurrentUser` 是死候选」的返工教训）。

**验证规则**：`resolveRoot()` 末尾遍历 `candidates`，逐候选用 `FileManager.default.fileExists(atPath:)` 检查目录下存在 `Package.swift` **或** `models/`，第一个通过的入选并返回。验证是防「候选碰巧存在但不是项目根」的关键——只看存在性、不校验内容。

**全败回退**：`resolveRoot()` 返回 `candidates[0]`（源码注释："调用方仍需处理资源缺失"）——**不抛错**，调用方必须自己处理资源缺失路径（这是调用契约的一部分）。

## 二、modelsDir()/dataDir() 与调用方清单

**两个便捷方法**（`enum AuroraPaths` 中的静态方法）：

```swift
static func modelsDir() -> URL {
    projectRoot().appendingPathComponent("models")
}

static func dataDir() -> URL {
    projectRoot().appendingPathComponent("data")
}
```

- `modelsDir()` → `models/`（CoreML 模型 .mlmodelc/.mlpackage、字模库、地图资源）
- `dataDir()` → `data/`（raw_clips / glyph_clips 训练数据）

**实测调用方清单**（`grep -rn "AuroraPaths\." Sources/`：**23 个文件、共 66 处提及**，其中 7 处注释提及 → **真实代码调用 59 处**）——绝大多数直接调 `projectRoot()` 后自行 append 子路径；`modelsDir()` 9 处，`dataDir()` 仍无人调用（预留 API）。下表按「调用点所在函数/类型」定位，不再用行号：

| 调用方（文件 → 类型 / 函数） | 调用的 API | 拼接的子路径 / 用途 |
|---|---|---|
| `Capture/RecordEngine.swift` → `RecordEngine.glyphRoot` / `RecordEngine.recordingsRoot` | `projectRoot()` | `data/glyph_clips`（字模模式训练输出）/ `data/raw_clips`（训练数据输出） |
| `Capture/LeanRecordEngine.swift` → `LeanRecordEngine.compute` | `projectRoot()` | 精简录制引擎的根目录基准 |
| `App/AuroraDriveApp.swift` → `runProtoSelfTest()` | `projectRoot()` | `tools/reverse/samples`（新协议解码自检样本目录） |
| `App/AuroraDriveApp.swift` → `loadVisionTestImage()` | `projectRoot()` | 视觉自检找 `data/nte_test_frames/`、回落 `data/raw_clips/` |
| `App/AuroraDriveApp.swift` → `runAYolomSelfTest()` | `modelsDir()` | `ayolom`（A-YOLOM 产物存在性） |
| `App/AuroraDriveApp.swift` → `runPerceptionSelfTest()` | `modelsDir()` | `ayolom` / `yolopx`（两套模型产物都在） |
| `App/AuroraDriveApp.swift` → `DriveState.mapPath` | `projectRoot()` | `models/bigworldmap-13056.jpg`、`models/bigworldmapSecond.png`（大地图两张，排在后两个候选） |
| `App/AuroraDriveApp.swift` → `AuroraDriveApp.detectedModelName(mode:)` | `projectRoot()` | `models`（模型挂载探测；其上方注释明确「必须用 projectRoot 而不是 currentDirectoryPath」） |
| `App/AuroraDriveApp.swift` → `AuroraDriveApp.modelFileExists(mode:)` | `projectRoot()` | `models`（模型存在性） |
| `App/AuroraDriveApp.swift` → `startTraining()` | `projectRoot()` | 训练进程 `currentDirectoryURL` 与 `train.log` |
| `App/AuroraDriveApp.swift` → `deployTrainedModel()` | `projectRoot()` | `models`（部署目录） |
| `App/AuroraDriveApp.swift` → `clearRawClips()` | `projectRoot()` | `data/raw_clips`（清录制） |
| `App/MapWiring.swift` → `MapWiring.loadFromDisk()` | `projectRoot()` | `models/map_locations.json`（地图标记库）；其上方注释解释双击 .app 时 cwd 是 `/` |
| `App/MissionConsole.swift` → `ensureConfigured()` | `projectRoot()` | `models/map_tiles`（瓦片目录） |
| `App/MissionConsole.swift` → 地图载入逻辑 | `projectRoot()` | 另一处根目录定位 |
| `Inference/SpeedOCRReader.swift` → 模型加载路径 | `projectRoot()` | 字符表 / 字模 .mlmodelc 候选 / 字符表（均先 `projectRoot()`） |
| `Inference/SpeedOCRReader.swift` → `modelCandidates(name:relative:)` | `projectRoot()` | 候选模型路径前缀（其注释说明与首选候选「完全重复」） |
| `Inference/SpeedOCRReader.swift` → `loadPPOCRModel()` | `projectRoot()` | PPOCR 模型候选 |
| `Inference/QuestPanelReader.swift` → `ensureIndex()` | `projectRoot()` | `models/quest_index.json` |
| `Inference/QuestPanelReader.swift` → `ensureChain()` | `projectRoot()` | `QuestChainIndex.load(root:)` 的根 |
| `Inference/QuestPanelReader.swift` → `QuestPanelReader.runSelfTest()` | `projectRoot()` | 自检索引根 |
| `Inference/InferenceEngine.swift` → `InferenceEngine.modelURL` | `projectRoot()` | `models`（m9_mono / game_assist_control） |
| `Inference/InferenceEngineV2.swift` → `InferenceEngineV2.modelURL` / `worldModelURL` / `multiChunkURLs` | `projectRoot()` | `models`（V2 多处模型路径） |
| `Inference/InferenceEngineV3.swift` → `InferenceEngineV3` 实例属性初始化 | `projectRoot()` | V3 引擎根目录基准 |
| `Inference/YoloEngine.swift` → `YoloEngine.modelURL` | `projectRoot()` | `models`（yolo26s） |
| `Inference/YolopxEngine.swift` → `YolopxEngine.candidateURLs` | `modelsDir()` | `models/` + `modelDirName` 子目录 |
| `Inference/StateTokenAccelerator.swift` → `StateTokenAccelerator.init(modelURL:)` | `projectRoot()` | `models/<defaultModelName>.mlmodelc`（环境变量 `AURORA_STATE_TOKEN_MODEL` 可覆盖） |
| `Inference/PointerHeadingReader.swift` → `PointerHeadingReader.computeMargin` | `modelsDir()` | 模型目录 |
| `Inference/V3EngineSelfTest.swift` → 自检各步骤 | `projectRoot()` | `models/v3_fixed_input`、`models/v3_fixed_input_ref.json`、`models/<V3InputContract.modelFileName>.mlmodelc`、`Sources/AuroraDrive` 源码路径 |
| `App/CategoryPanel.swift` → `CategoryPanel.candidateURLs()` / `loadIconMap()` | `projectRoot()` + `modelsDir()` | `models/map_categories.json`、`models/marker_taxonomy.json`、`models/map_icon_map.json` |
| `App/RouteGraph.swift` → `RouteGraph.graphURL` | `modelsDir()` | `models/route_graph.json` |
| `App/MarkerTaxonomy.swift` → `MarkerTaxonomy.url` | `modelsDir()` | `models/map_categories.json` |
| `App/MapLayers.swift` → `MapLayers.resolve(_:)` | `projectRoot()` | 栅格资源 |
| `App/AuroraBrand.swift` → `AuroraBrand.candidates()` | `projectRoot()` | logo 资源（其注释里另有两处对照说明 `AuroraPaths.projectRoot()` 与 `AuroraPaths.cachedRoot`，非调用） |
| `App/MapSelfTest.swift` → `mapTestT5bBaseMapSoak` / `mapTestT6` / `mapTestT7` | `projectRoot()` | 底图、`Sources/AuroraDrive` 根、自检资源 |
| `RL/OnlineTrainingRuntime.swift` → `locateHeadInitJSON()` | `projectRoot()` | 头部初始化 JSON 路径 |

**双击 .app 启动的坑**（`MapWiring.loadFromDisk()` 上方注释实录）：cwd 是 `/` 而非可执行文件目录——所以地图资源**一律用 `projectRoot()`**，不依赖 cwd；`detectedModelName(mode:)` 上方同样注释「必须用 `AuroraPaths.projectRoot()` 而不是 `currentDirectoryPath`」。

**调用契约**：`projectRoot()` 全败时回退候选 1 不抛错，所以每个调用方拿到的 URL 可能指向不存在的目录——调用方必须自己 `FileManager.default.fileExists` 验证（`InferenceEngine.modelURL` 就是范例：先查 `.mlmodelc` 存在性，回退 `.mlpackage`）。

**新增资源目录的规范**：若要加 `recordings`/`glyphs` 等新便捷方法，照 `modelsDir()` / `dataDir()` 的样式加一行 `static func xxxDir() -> URL`；不要在调用方散落硬编码路径——散落会重蹈「整理后路径断链」的覆辙。
