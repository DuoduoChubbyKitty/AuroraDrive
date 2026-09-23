# 代码-02 AuroraPaths 项目根定位

> 覆盖源文件：`Sources/AuroraDrive/Core/AuroraPaths.swift`（58 行，commit d64873b 后位于 Core/ 子目录）。基于当前仓库逐单元编写。

## 一、projectRoot() 多候选根目录解析（第 8–47 行）

**为什么存在**：源码重组进 `Sources/AuroraDrive/Core/` 后，`#filePath` 不再指向项目根（文件注释第 3 行）。本项目零外部依赖、模型/数据/录制目录都在仓库根（`models/`、`data/`），但进程启动方式多样（SwiftPM 直启、双击 AuroraDriveUI、.app bundle、--engine 子进程），cwd 各不相同——所以需要一个统一的多候选解析器，供 RecordEngine（data/raw_clips）、InferenceEngine（models）、CoordinateCapture 等定位资源。

**签名**：`static func projectRoot() -> URL`（无参，返回项目根 URL）。

**缓存**：`nonisolated(unsafe) static var cachedRoot: URL?`（第 10 行）——进程内只解析一次，命中直接返回（第 14 行）。`nonisolated(unsafe)` 是 Swift 6 严格并发下的逃生舱：路径解析无竞态危害，作者显式关闭隔离检查。

**四个候选（按优先级，第 16–33 行）：**

| # | 候选 | 适用场景 |
|---|---|---|
| 1 | `#filePath` 上溯 4 级（`Sources/AuroraDrive/Core/AuroraPaths.swift` → 项目根） | SwiftPM 从源码树构建运行（编译期路径可信） |
| 2 | `FileManager.default.currentDirectoryPath`（cwd） | 从项目根手动启动 |
| 3 | `Bundle.main.executableURL?.deletingLastPathComponent()`（可执行文件所在目录） | 双击 AuroraDriveUI 启动（cwd 即此处） |
| 4 | 硬编码 `"/Users/dupi/Desktop/自动驾驶系统"`（兜底） | 全部候选失败的最后防线 |

**验证规则（第 35–42 行）**：逐候选检查目录下存在 `Package.swift` **或** `models/`，第一个通过的入选 `cachedRoot` 并返回。验证是防"候选碰巧存在但不是项目根"的关键——只看存在性、不校验内容。

**全败回退（第 44–46 行）**：返回候选 1（源文件注释："调用方仍需处理资源缺失"）——**不抛错**，调用方必须自己处理资源缺失路径（这是调用契约的一部分）。

**候选 4 的注意点**：硬编码用户路径（`/Users/dupi/...`），换机器部署会失效——但它只是兜底（候选 1–3 通常已命中），且全败时回退候选 1 也不经过它。若要移植到别的机器，改这一行或依赖候选 2/3。

## 二、modelsDir()/dataDir() 与调用方清单

**两个便捷方法（第 50–57 行）：**

```swift
static func modelsDir() -> URL { projectRoot().appendingPathComponent("models") }
static func dataDir() -> URL    { projectRoot().appendingPathComponent("data") }
```

- `modelsDir()` → `models/`（CoreML 模型 .mlmodelc/.mlpackage、字模库、地图资源）
- `dataDir()` → `data/`（raw_clips / glyph_clips 训练数据）

**实测调用方清单（grep `AuroraPaths\.` 全 Sources，6 文件 8 处）——全部直接调 `projectRoot()` 后自行 append 子路径，两个便捷方法目前无人调用（预留 API）：**

| 调用方 | 位置 | 拼接的子路径 |
|---|---|---|
| `Inference/YoloEngine.swift` | :139 | `models`（YOLO 模型） |
| `Inference/InferenceEngine.swift` | :128 | `models`（m9_mono / game_assist_control） |
| `Inference/SpeedOCRReader.swift` | :248 | `root`（字模/速度模板资源） |
| `Capture/RecordEngine.swift` | :53 | recordings 根（录制输出） |
| `Capture/RecordEngine.swift` | :122 | `data/raw_clips`（训练数据输出） |
| `App/AuroraDriveApp.swift` | :1655 | `models`（模型检查/加载） |
| `App/AuroraDriveApp.swift` | :1701 | `rawClips`（录制数据入口） |

**调用契约**：`projectRoot()` 全败时回退候选 1 不抛错，所以每个调用方拿到的 URL 可能指向不存在的目录——调用方必须自己 `FileManager.default.fileExists` 验证（InferenceEngine.modelURL 就是范例：先查 `.mlmodelc` 存在性，回退 `.mlpackage`）。

**新增资源目录的规范**：若要加 `recordings`/`glyphs` 等新便捷方法，照 50–57 行的样式加一行 `static func xxxDir() -> URL`；不要在调用方散落硬编码路径——散落会重蹈"整理后路径断链"的覆辙。
