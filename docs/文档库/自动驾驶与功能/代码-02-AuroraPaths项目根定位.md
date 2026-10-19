# 代码-02 AuroraPaths 项目根定位

> ✅ **2026-10-18 复核**（merge-arch）：逐行对照 `Sources/AuroraDrive/Core/AuroraPaths.swift`（118 行），§一全部区间引用命中（8-107 / :46 / :41 / 49-95 / 97-103 / 105-107 / 109-117 / :52-57 / :59-60 / :62-65 / :88-95 / :67-87）；§二 modelsDir() 8 处 ✅、dataDir() 0 处 ✅ 仍成立。修正 3 处：
> 1. **总数**：「16 文件 49 处」→「**17 文件 51 行**」（2026-10-18 二次重基准 `grep -rn "AuroraPaths\." Sources/` 实测；其中 6 行为注释/散文提及，**真实代码调用 45 行**）。
> 2. **AuroraDriveApp 4 处行号漂移**：原文 :5249/:5263/:6454/:6502 指向注释/函数声明，实际 `AuroraPaths.` 调用分别在 :5251/:5265/:6457/:6505（+2~+3 行）。
> 3. **QuestPanelReader.swift 漏列**：3 处调用（:668/:682/:937）未入表，已补。
>
> **✅ 行号已按当前版重基准（2026-10-18 二次）**：`AuroraPaths.swift` 118 行**未变**，§一全部区间引用（8-107 / :46 / :41 / 49-95 / 97-103 / 105-107 / 109-117 / :52-57 / :59-60 / :62-65 / :88-95 / :67-87 / :110-112 / :115-117）逐条 `sed -n` **全部命中、零漂移**。
> §二调用方清单修正 5 条：`RecordEngine :85/:175→:89/:179`（原引的是属性声明行）、`CategoryPanel` 补 `:177`、`MissionConsole` 补 `:2973`、文件数 `16→17`、真实代码调用行数 `48→45`（6 行是注释提及）。

> 覆盖源文件：`Sources/AuroraDrive/Core/AuroraPaths.swift`（**118 行**，2026-10-17 `wc -l` 实测）。基于当前仓库逐单元编写（**2026-10-17 复核**：正文行号已按当前 118 行版 `grep -n` 逐条实测校正，与源码一致）。

## 一、projectRoot() 多候选根目录解析（第 8–107 行）

**为什么存在**：源码重组进 `Sources/AuroraDrive/Core/` 后，`#filePath` 不再指向项目根（文件注释第 3 行）。本项目零外部依赖、模型/数据/录制目录都在仓库根（`models/`、`data/`），但进程启动方式多样（SwiftPM 直启、双击 AuroraDriveUI、.app bundle、--engine 子进程），cwd 各不相同——所以需要一个统一的多候选解析器，供 RecordEngine（data/raw_clips）、InferenceEngine（models）、CoordinateCapture 等定位资源。

**签名**：`static func projectRoot() -> URL`（**:46**，无参，返回项目根 URL）。

**缓存（第 41 行）**：`private static let cachedRoot: URL = resolveRoot()`——`static let` 由 `swift_once` 保证线程安全且只求值一次（P-3 修复，:10-38 注释：原 `nonisolated(unsafe) static var` 有数据竞争，多线程可能各探测一遍）。`projectRoot()` 每次调用只读一次内存。

**候选解析（第 49–95 行，resolveRoot 内）**：先按优先级放入 3 个初始候选，再附加「可执行文件目录逐级上溯 ≤6 级」的机器无关兜底候选：

| # | 候选 | 适用场景 |
|---|---|---|
| 1 | `#filePath` 上溯 4 级（`Sources/AuroraDrive/Core/AuroraPaths.swift` → 项目根，:52-57） | SwiftPM 从源码树构建运行（编译期路径可信） |
| 2 | `FileManager.default.currentDirectoryPath`（cwd，:59-60） | 从项目根手动启动 |
| 3 | `Bundle.main.executableURL?.deletingLastPathComponent()`（:62-65） | 双击 AuroraDriveUI 启动（cwd 即此处） |
| 4 | 可执行文件目录**逐级上溯 ≤6 级**（:88-95） | 二进制在 `.build/` 构建树内、或装在项目树任意处（机器无关） |

> ⚠️ 历史第 4 候选曾硬编码绝对路径 `/Users/dupi/Desktop/自动驾驶系统` 做兜底，**P-1（2026-10-04）已删除**——换机器/换用户名会静默失效，且个人路径进源码是隐私问题（:67-87 注释；中间还记了一次「换成 homeDirectoryForCurrentUser 是死候选」的返工教训）。

**验证规则（第 97–103 行）**：逐候选检查目录下存在 `Package.swift` **或** `models/`，第一个通过的入选 `cachedRoot` 并返回。验证是防"候选碰巧存在但不是项目根"的关键——只看存在性、不校验内容。

**全败回退（第 105–107 行）**：返回候选 1（源文件注释："调用方仍需处理资源缺失"）——**不抛错**，调用方必须自己处理资源缺失路径（这是调用契约的一部分）。

## 二、modelsDir()/dataDir() 与调用方清单

**两个便捷方法（第 109–117 行）：**

```swift
static func modelsDir() -> URL { projectRoot().appendingPathComponent("models") }   // :110-112
static func dataDir() -> URL    { projectRoot().appendingPathComponent("data") }    // :115-117
```

- `modelsDir()` → `models/`（CoreML 模型 .mlmodelc/.mlpackage、字模库、地图资源）
- `dataDir()` → `data/`（raw_clips / glyph_clips 训练数据）

**实测调用方清单（2026-10-18 二次重基准 `grep -rn "AuroraPaths\." Sources/`：**17 文件 51 行**，其中 6 行是注释/散文提及（`AuroraPaths.swift:52`、`AuroraBrand.swift:31/:37`、`MapWiring.swift:324`、`SpeedOCRReader.swift:384`、`AuroraDriveApp.swift:5248`）→ **真实代码调用 45 行**）——绝大多数直接调 `projectRoot()` 后自行 append 子路径；`modelsDir()` 已有 8 处调用，`dataDir()` 仍无人调用（预留 API）：**

> ⚠️ 2026-10-18 复核：原写「16 文件 49 处」，今日实测 **51 行**（含 6 行为注释/散文提及，真实代码调用 45 行）；其中 `App/AuroraDriveApp.swift` 由 6 处增至 13 处、新增 `Inference/QuestPanelReader.swift` 3 处。
> 下表 AuroraDriveApp 的 4 个行号原指向注释/函数声明（:5249/:5263/:6454/:6502），已更正为真实的 `AuroraPaths.` 调出行。

| 调用方 | 位置 | 拼接的子路径 |
|---|---|---|
| `Capture/RecordEngine.swift` | :89 / :179 | `data/glyph_clips`（字模模式训练输出）/ `data/raw_clips`（训练数据输出） |
| `App/AuroraDriveApp.swift` | :5251 | `models`（detectedModelName，模型挂载探测；:5248-5250 是"必须用 projectRoot 而非 cwd"的注释，其中 :5248 的注释里也出现了 `AuroraPaths.projectRoot()` 字样） |
| `App/AuroraDriveApp.swift` | :5265 | `models`（modelFileExists，模型存在性；:5263 是函数声明） |
| `App/AuroraDriveApp.swift` | :6457 | `models`（deployTrainedModel 部署目录；:6454 是注释行） |
| `App/AuroraDriveApp.swift` | :6505 | `data/raw_clips`（clearRawClips 清录制；:6502 是注释行） |
| `App/AuroraDriveApp.swift` | :2528 / :2741 | `models/`（ayolom/yolopx 产物自检，modelsDir()） |
| `App/AuroraDriveApp.swift` | :1461 / :2356 / :4506-4507 / :6419 / :6422 | tools/reverse/samples、根目录、大地图两张、训练 cwd、train.log |
| `App/MapWiring.swift` | :326 | `models/map_locations.json`（地图标记库）；:324 是注释提及 |
| `App/MissionConsole.swift` | :2252 / :2973 | `models/map_tiles`（瓦片目录）/ 另一处根目录定位（**2026-10-18 补录，原文漏列**） |
| `Inference/SpeedOCRReader.swift` | :343 / :396 / :455 | 字符表 / 字模 .mlmodelc 候选 / 字符表（三处均先 `projectRoot()`）；另 :384 是注释提及（非调用），不计入 |
| `Inference/QuestPanelReader.swift` | :668 / :682 / :937 | `models/quest_index.json` / QuestChainIndex root / 索引根（**2026-10-18 补录，原文漏列**） |
| `Inference/InferenceEngine.swift` | :143 | `models`（m9_mono / game_assist_control） |
| `Inference/InferenceEngineV2.swift` | :1608 / :1616 / :1625 / :1637 / :1647 / :1675 | `models`（V2 六处模型路径） |
| `Inference/YoloEngine.swift` | :162 | `models`（yolo26s） |
| `Inference/YolopxEngine.swift` | :672 | `models/`（modelsDir() + 模型子目录） |
| `App/CategoryPanel.swift` | :134 / :137 / :139 / :177 / :180 | 分类/词表/图标（:137/:139 走 modelsDir()；:177 是本次补录） |
| `App/RouteGraph.swift` | :219 | `models/route_graph.json`（modelsDir()） |
| `App/MarkerTaxonomy.swift` | :74 | `models/map_categories.json`（modelsDir()） |
| `App/MapLayers.swift` | :592 | 栅格资源（projectRoot()） |
| `App/AuroraBrand.swift` | :87 | logo 资源（projectRoot()；:31/:37 是注释里的对照说明，已实测确认） |
| `App/MapSelfTest.swift` | :534 / :627 / :648 / :773 | 底图、Sources 根、自检资源 |

**双击 .app 启动的坑（MapWiring:324-325 注释实录）**：cwd 是 `/` 而非可执行文件目录——所以地图资源**一律用 projectRoot()**，不依赖 cwd；AuroraDriveApp:5248-5250 同样注释"必须用 AuroraPaths.projectRoot() 而不是 currentDirectoryPath"（:5246 是 `detectedModelName()` 函数声明，不是注释行）。

**调用契约**：`projectRoot()` 全败时回退候选 1 不抛错，所以每个调用方拿到的 URL 可能指向不存在的目录——调用方必须自己 `FileManager.default.fileExists` 验证（InferenceEngine.modelURL 就是范例：先查 `.mlmodelc` 存在性，回退 `.mlpackage`）。

**新增资源目录的规范**：若要加 `recordings`/`glyphs` 等新便捷方法，照 :110-117 的样式加一行 `static func xxxDir() -> URL`；不要在调用方散落硬编码路径——散落会重蹈"整理后路径断链"的覆辙。
