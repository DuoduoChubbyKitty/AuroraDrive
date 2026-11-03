# 性能审计文档 · 对抗式核验报告

- 核验日期：2026-11-01
- 核验对象：`docs/perf-audit-20261024/{1-arrow-hunter,2-cpu-hotpath,3-compute-units,4-idle-waste}.md`、`docs/perf-audit-gpu/{10-cpu-compositing-design,11-gpu-users}.md`
- 核验方式：**只读**。逐条把文档的 `file:line` 断言拿到当前源码 `sed -n` / `rg` 对照；计数类断言全部重跑。未启动任何 GUI、未联网、未改 `Sources/`、未动 git 工作区。
- 当前基线：`git status --porcelain` 除本报告目录外为空；HEAD = `3082269`（2026-10-29 21:22），提交信息本身即「清理纯浪费 + 指针朝向可信度修复 + GPU 审计文档」。

---

## 1. 一句话结论

**六份文档的「机制分析」大体可信（尤其 doc3 的 Yolopx ABBA 否决、doc10 的层序/MaskGrid 数学、doc1 的 M3 冻结机制），但它们的「待修项 + 计数」已大面积过期：至少 4 份文档的 P0 建议在同一批源码里已经落地，文档却仍以「待修」呈现。可复现的硬错误 24 处（结论级 8 处 + 数字失真 6 处 + 行号漂移 10 组），其中 doc3 的「SpeedOCR 未设 computeUnits」和 doc2 的「publish 每条 tick 无条件」错得最伤——按这两条去优化会做无用功。**

---

## 2. 错误清单

### 2.1 结论级错误（状态与源码相反，最危险）

| # | 文档位置 | 文档原话 | 实际情况（当前源码） | 证据 |
|---|---|---|---|---|
| **C1** | doc3 §1/§2.1/§3-①/§7 | 「项目里确实有一个模型从来没设过 `computeUnits`（`SpeedOCRReader.loadOneModel`），走默认 `.all`……给它补上显式档位是唯一强烈建议」 | **已经改了。** `loadOneModel` 已 `let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine`，注释日期 2026-10-24。§3-① 建议的代码与现源码逐字一致 | `SpeedOCRReader.swift:412-420`（注释「⚠️ 2026-10-24 补显式 computeUnits（本轮审计发现）」）、`:432-433`、`:441` |
| **C2** | doc3 §6.2 | 「`SpeedOCRReader` 是全仓唯一『裸 `MLModel(contentsOf:)`』的模型加载点」 | **已不成立**：`MLModel(contentsOf: loadURL, configuration: config)` 已带配置 | `SpeedOCRReader.swift:441` |
| **C3** | doc3 §3-③/§6.1 | 「`SpeedOCRReader.swift:541` 写『闸 1：5Hz 时间节流（200ms）』，注释与代码不符」 | **该行已不是那句话**（现为 `.mlmodelc` 说明）；真正的「5Hz」注释已在别处被改成 15Hz 并保留更正说明 | `:541` 现为 `.mlmodelc`；`:568-570` 为「闸 1：15Hz 时间节流（66.7ms）……原文写『5Hz / 200ms』」 |
| **C4** | doc2 §1/§2 #1/§3-①/§6 | 「`publish` 每 tick 无条件整帧写入、`seq` 无条件 +1，**不受 `isDriving` 门控**，`:1431` 在 `if st.isDriving` 之外」 | **已加「无新帧短路」**：`if !st.isDriving, !wantFullFrame, pixelsUnchanged, stateUnchanged, !keepAliveDue { skip } else { publish }`。`:1431` 早已不是 publish 调用点 | `EngineMain.swift:1478-1538`（真实 publish 在 `:1538`）；跳过计数 `skippedPublishTicks` |
| **C5** | doc2 §2 #2 | 「`poll()` 仅以 `seq != lastFrameSeq` 判新（`:646`）。因 #1 让 `seq` 每 tick 必变，这道门**永远放行**」 | 该推论**随 C4 一起失效**：空闲态 `seq` 不再每 tick 变（日志实测 15s 只 +14），`poll` 的 seq 门恢复有效 | `EngineMain.swift:1516-1528`；`~/Library/Logs/AuroraEngine.log` 08:41:37→08:41:52 `seq=590→604`、`skip=297` |
| **C6** | doc2 §2 #3/§3-② | 「`publishMasks` 调用在 `if fp != lastFingerprint` **之外**，每 tick 都重写两份掩码；`:1473-1483`」 | **已挪进花括号内**；`:1473-1483` 现在是「应急抓屏频率」代码，掩码块已移到 `:1564-1642` | `EngineMain.swift:1623-1633`（`if fp != EngineGlobals.lastMaskFingerprint { … publishMasks(…) }`） |
| **C7** | doc4 §3-①/§5.2 | 「引擎进程的 Vision OCR 每 0.7s 跑一次、产物无人接收——零风险收益最大；`!isActive` 挡不住引擎进程」 | **已加进程身份门控**：`let isEngineProcess = CommandLine.arguments.contains("--engine")`，`if AuroraFlags.questOCR, !isEngineProcess, !isActive, …`。引擎进程不再跑 | `AuroraDriveApp.swift:7242-7246` |
| **C8** | doc1 §1/§2 M1/§4 P0 | 「箭头回退时**视觉上没有任何区分**——同一根 `Capsule`、同一个颜色」「P0：回退值必须可见，不再静默」 | **已区分**：无读数时箭头改 `Aurora.amber.opacity(0.45)`（琥珀半透明），有读数仍是 `Aurora.ice`；P0 建议已落地。**回退行为本身仍在**（仍是 `bodyHeadingDeg ?? locatorHeading`），只是不再静默 | `MissionConsole.swift:2040-2048`（修复注释）、`:2049-2055` |

> 说明：C8 是**部分过期**——「静默」这半句错了，「回退到视角朝向」这半句仍对。引用时不能整条作废。

### 2.2 数字失真（重新 grep 的实测值）

| # | 文档位置 | 文档原话 | 实测 | 复现命令 / 备注 |
|---|---|---|---|---|
| **N1** | doc3 §6.2 | 「其余 **7 处 `.all`**、**8 处 `.cpuOnly`**、**3 处 `.cpuAndNeuralEngine`**」 | 代码赋值：`.all`=**6**、`.cpuOnly`=**5**、`.cpuAndNeuralEngine`=**4** | `rg -n '^\s*[A-Za-z]\w*\.computeUnits\s*=\s*\.(all\|cpuOnly\|cpuAndNeuralEngine)\b' Sources/` |
| **N2** | doc11 §3 结尾 | 「对照组：`.cpuOnly` **8 处**、`.cpuAndNeuralEngine` **4 处**」 | `.cpuOnly`=**5**、`.cpuAndNeuralEngine`=**4**（后者对） | 同上 |
| **N3** | doc11 §0 表 / §1.1 | 「`MTLTexture` **85 处** / `MTLDevice` **8** / `MTLCommandQueue` **4**」 | 85/8/4 是 `Vendor/MetalGoose/` **整目录**的**行数**，含**未被编译**的根目录副本 `Vendor/MetalGoose/GooseEngine.swift` 与 `README.md`。真正编进 target 的 `Vendor/MetalGoose/Engine/` 只有 **MTLTexture 42 行 / MTLDevice 4 / MTLCommandQueue 2** | `Package.swift:189-192`（sources 白名单 = `Vendor/MetalGoose/Engine`）；`rg -c MTLTexture Vendor/MetalGoose/` 得 42+42+1；`rg -c … Vendor/MetalGoose/Engine/` 得 42 |
| **N4** | doc4 §6 | 「`JSONSerialization` **仅出现在**：`EngineMain:1556`、`:1711`、`EngineClient:429`、`:875`」 | `Sources/` 内 **48 个代码行**（含注释 52 行），横跨 `LLMTransport`/`MapLayers`/`ToolRegistry`/`CategoryPanel`/`RecordEngine`/`NetworkLocator` 等。**「均不在 15Hz tick 热路径」这个结论仍成立**，但「仅出现在 4 处」是硬错 | `rg -n 'JSONSerialization\.' Sources/ \| wc -l` = 48 |
| **N5** | doc4 §6 | 「`Data(contentsOf:)` / `FileManager` 目录扫描：`AuroraDriveApp.swift:1484` **一处**」 | `Data(contentsOf:)` 全仓 **10 处**（QuestPanelReader×2、RoadCornerGuide、AgentSettings、LLMHealth、MapLayers×3、AuroraDriveApp、LLMSelfTest） | `rg -n 'Data\(contentsOf:' Sources/` |
| **N6** | doc4 §6 | 「`while true` 死循环 **共 3 处**」 | **5 处**（`LLMTransport:1501`、`RouteGraph:446`、`AuroraDriveApp:9171`、`PrivilegePill:375/423` —— 后两处在内嵌 bash 脚本字符串里）。「都是有限循环」结论仍成立 | `rg -n 'while true' Sources/` |
| **N7** | doc4 §5.2 | 「`EngineClient.startup()` 调用点全仓库**仅 1 处**：`AuroraDriveApp.swift:217`」 | **2 处**：`AuroraDriveApp.swift:217` + `EngineClient.swift:336`（重连路径自调用）。「引擎进程 `isActive` 恒 false」结论仍成立 | `rg -n 'startup\(\)' Sources/AuroraDrive/Core/EngineClient.swift` → `:336 self.startup()` |
| **N8** | doc11 §2.5 | 「录制链写盘是 `NSBitmapImageRep.png`（`:565`/`:631`），没有视频编码」 | 「无 `AVAssetWriter`/`VTCompressionSession`」正确；但**主帧路径是 JPEG**（`:599-602`，训练端读 `.jpg`），PNG 只用于字模原生 ROI（`:631`） | `RecordEngine.swift:599-602`、`:631`；`rg AVAssetWriter\|VTCompressionSession RecordEngine.swift` = 0 |

### 2.3 行号漂移（抽样；doc1 的指针段、doc4 的定时器表、doc10 的 AuroraTheme 段几乎整体失效）

| # | 文档位置 | 文档指向 | 当前实际 |
|---|---|---|---|
| **L1** | doc1 §2 M1 | 回退渲染 `MissionConsole.swift:2044` | `:2055`（`rotationEffect(.degrees(state.bodyHeadingDeg ?? state.locatorHeading))`）；`:2044` 已是修复注释 |
| **L2** | doc1 §2 M2 | conf 消费点 `App:4400 / :6768 / :7398 / :7401`；`MissionConsole:1868` | `App:4400`（声明对）/ `:6791-6792`（同步）/ `:7448`、`:7451`（写入）；`MissionConsole:1868` 对 |
| **L3** | doc1 §2 M3 | `guard isDriving` `App:7342`；指针段 `:7379-7404`；写入点 `:6767/:7397/:7400` | `guard` 在 `:7393`；指针段 `:7430-7455`；写入 `:6791`、`:7448`、`:7451` |
| **L4** | doc1 §2 M3/§2.2 | 注释 `App:7383-7385` | 该段注释在 `:7432-7439`（内容仍在，即「待机不刷新」） |
| **L5** | doc1 §2 M4 | `App:7394`、`App:8099`（frontmostApplication） | `:7445`；`frontmostApplication` 在 `:8150`（`:8099` 是 `controlEngine.releaseAll()`） |
| **L6** | doc1 §4 P1 | `stopDriving` `App:6446` | `:6465`（`func stopDriving()`） |
| **L7** | doc2 §2 #1 附注 | `currentFrameCG` 声明 `App:5193`、写入 `:6689/:7164` | 声明 `:5193` **对**；写入实际 `:6713`、`:7188`（**注意**：`rg 'currentFrameCG = nil'` 仍 0 命中，这条结论正确） |
| **L8** | doc2 §2 #3/§3-② | 指纹 `:1471`、局限注释 `:1462-1464`、掩码块 `:1473-1483` | 指纹构造 `:1607-1622`、局限说明 `:1589-1592`、掩码块 `:1593-1642` |
| **L9** | doc2 §4 | `debugSummary` 节流 `App:8086`；`processMemoryMB()` `:8106` | 节流 `if nowLog.timeIntervalSince(lastTickLog) >= 1.0` 在 `:8138`；`processMemoryMB` 定义 `:5615`、调用 `:8156` |
| **L10** | doc4 §2 表 | `EngineMain.swift:1242` engineTicker 15Hz；`:1263` engineHeartbeat 1Hz | `:1242` 是 `EngineGlobals.latestFullFrame = pb`；ticker 在 `:1271-1292`，heartbeat 在 `:1301` |
| **L11** | doc4 §2 表 | `MissionConsole.swift:6222` tickDispatchSource；`:6298` netLocDispatchSource | `:6222` 是 `private func bootstrap()`（timer 在 `:6227-6234`）；netLoc 注释 `:6301`、赋值 `:6323` |
| **L12** | doc4 §2 表 | `antiFreezeTimer` 空实现 `App:6519` | `startAntiFreeze()` 在 `:6543-6546`；`:6519` 是 `setGameModeBoost`（`antiFreezeTimer` 声明 `:5378` **对**） |
| **L13** | doc4 §2 表 | `GameModeDefender.start()` 引擎侧 `EngineMain.swift:1120` | `:1159`（`:1120` 是帮助文本注释） |
| **L14** | doc4 §2 表 | `AuroraCache.swift:238` metricsTimer / `:237` guard | 声明 `:238` 对；安装处 `guard PerfBus.enabled else { return }` 在 `:514-515`；`:237` 附近是注释 |
| **L15** | doc4 §4.1 | `tickEngineMode()` `App:6663` | `:6687`（`:6663` 是 `}`） |
| **L16** | doc10 §1.3/§6.2 | 光斑 `.blur(radius: 60)` 在 `AuroraTheme.swift:658`；`drift` 开关 `:705-706`；blob 形状 `:712-720`；「可被 CA 缓存」注释 `:701` | **整段系统性偏 +15 行**：`.blur(radius: 60)` 在 `:643`；`driftEnabled`/`if driftEnabled` 在 `:690-691`；`private func blob` 在 `:697-705`；缓存注释在 `:686`。**doc10 自带的「6.2 行号复核表」把 `:658` 复核成 `.blur(radius: 60)` 是错的**（`sed -n 658p` 实际是「位置 ⟹ …」） |
| **L17** | doc3 §2.1 调用频率列 | `detectGateA` `App:7091`、`yolopxEngine.infer` `:7541`、`inferenceEngineV2.infer` `:7455`、`assist … :7492`、`speedOCR` 调用 `:7321`、tick 基准 `EngineMain:710`、yolo26s `unload :517/:528` | `detectGateA` 定义 `:7115`、`yolopxEngine.infer` `:7592`、`inferenceEngineV2.infer` `:7506`、assist 保活 `:7543-7544`、`speedOCR.infer` `:7372`、`engineTickHz = 15.0` 在 `EngineMain:771`、`unload()` 在 `YoloEngine:517`（`:528` 是 print 行） |
| **L18** | doc10 §6 索引 | `AuroraFlags.swift:295` disableLightField | 已撤销（banner 已自述），`:295` 现为 `segHandoverM`。**banner 的描述正确**，只是正文仍留着旧锚点 |
| **L19** | doc11 §3-① | `ane_dispatch_check.swift:23` 固定 `.all` | `:22`（`cfg.computeUnits = .all`） |
| **L20** | doc1 §6-3 | `/tmp/aurora_debug.log:153,187` 两次「坐标陈旧 年龄=18.1s」 | **该文件已被覆盖**（现 821 行、时间戳全为今日 08:36–08:47），`grep -c 坐标陈旧` = 0。原证据无法复现 |

> **行号漂移的成因（重要）**：六份文档与它们描述的修复是**同一个提交 `3082269`（10-29）进来的**。也就是说，文档写的是「修复前」的源码，而修复在同一提交里就进了库，文档结论没有回写。后续 `MissionConsole.swift` / `EngineMain.swift`（mtime 2026-11-01 08:44）可能又被触碰，但对 `HEAD` 内容无差异。

### 2.4 取证口径过期

| # | 文档位置 | 文档原话 | 实况 |
|---|---|---|---|
| **E1** | doc1 §2 M6 | 「心跳 3s 超时（本次采样日志中**未出现**，`grep -c "心跳超时" /tmp/aurora_debug.log` = 0）」 | 该判断对当次采样成立，但**当前日志里心跳超时并不罕见**：`~/Library/Logs/AuroraEngineClient.log` 今日 `grep -c 心跳超时` = **11**（最近 08:46:39 一次）。「M6 缺乏现场证据」这句已不能照抄 |
| **E2** | doc4 §1/§5.1 | 「引擎进程仍按 15Hz 跑完整 tick，`seq` 每 15s 精确 +225」 | 修复前为真；**当前实测空闲态 15s 只 +14（≈0.93Hz）**，日志每行带 `skip=N`。该结论已过期 |
| **E3** | doc10 全文 | 附录 A/B/C 的 A/B 数据（`/tmp/vis_ab3_out.log`、`/tmp/gpuwho.log`、`/tmp/samp_2138.txt` 等） | 这些 `/tmp` 证据**已全部不存在**（仅 `/tmp/aurora_debug.log` 在），附录 A/B/C 的实测数字**当前无法复现** |

---

## 3. 已过期但仍被引用的结论（最需警惕——会误导后续优化）

按「照做会浪费多少」排序：

1. **【doc3】「给 SpeedOCR 补 `.cpuAndNeuralEngine`」是待办** → **已完成**。若照文档再做一次，是重复劳动；若把它当"未受控 GPU 源"写进报告，会重复记账。同时注意：doc3 自己定的前置条件「先跑 `ane_dispatch_check` 确认 GPU 占比 > 0，=0 就不要改」——**仓库里找不到该前置测量的结果记录**，而代码已经改了。这是审计纪律上的断链，比单纯过期更值得记。
2. **【doc2】「publish 每 tick 无条件、UI 每 tick 重建 CGImage」是最大白做** → 引擎侧 dedup 已上线，空闲态 `seq` 从 15Hz 降到 ~1Hz。UI 侧 `poll()` 的 `Data(bytes:)`+`CGImage` 重建现在只在有新帧时发生；doc2 §3-③ 的「UI 单边兜底」收益也随之折旧。
3. **【doc2】「掩码指纹短路从未生效」** → 已生效。`writeMask` 不再每 tick 重写，`sample` 热点榜（05 文档 `:236` 的 96 采样）不可再作为「当前代价」引用。
4. **【doc4】「引擎进程 Vision OCR 是唯一有量化数字的纯浪费」** → 已被 `--engine` 门控关掉。「4.8% 单核 / 33.6ms」可作为历史成本引用，但**不能再写成现状**。
5. **【doc1】「箭头回退无任何视觉区分」** → 已加琥珀半透明。定验收标准时必须改成「琥珀 = 回退值」，否则验收判据本身会错。但 **M3（停车不置 nil → 冻结）仍成立**（`stopDriving:6465`、`pauseDriving:2350` 都不清 `bodyHeadingDeg`），**M2（conf 不算门控）仍成立**（全仓无阈值比较）。
6. **【doc1 §3.1】复现 M1 的预期现象「侧栏显示无指针、但箭头仍跟着视角转」** → 现在会看到**琥珀半透明**箭头，不是"看不出区别"。复现步骤需改写，否则执行者会误判"没复现成功"。
7. **【doc4 §5.1】「空转态 15Hz 从不降级」** → 抓屏/tick 频率本身确实不降，但**发布**已降（skip）。这两件事被文档混为一谈，现在必须拆开说。
8. **【doc11】「MTLTexture 85 处」作为"Metal 规模"论据** → 口径含未编译副本。说明 Metal 规模时应用 42（Engine/ 目录），否则会夸大 2 倍。

---

## 4. 核实为正确的关键结论（可继续采信，避免重复劳动）

### 4.1 doc3（CoreML 档位）—— 结构判断几乎全对
- **Yolopx 的 `.all` 三重否决**：183.0/204.6ms（空载）、191.4/199.1ms（8 核满载）、62.8% `BnnsCpuInferenceOperation`、`.cpuAndGpu` 427 算子 97~100ms、`.cpuOnly` 548ms+ —— 与 `YolopxEngine.swift:707-746` **逐字一致**，且源码注明「两次独立 ABBA 复测」。
- **V2 enc/ctl 按模型分配**：`enc→.cpuAndNeuralEngine (0.34ms)`、`ctl→.cpuOnly (3.48→0.57ms, 6.1×, 71.8% preferred=GPU)` —— `InferenceEngineV2.swift:1807-1821` 对。
- **各模型频率**：ayolom 每 tick 15Hz（`detectGateA = … || isAyolom …`，`App:7115`）、legacy 档 yolopx/yolo26s 各 7.5Hz（偶数/奇数帧）、V2 15Hz、assist 3Hz（5 帧保活，`App:7543`）、tiny_arrow 5Hz（`App:7445` `%3`）、speedOCR **15Hz**（`SpeedOCRReader.swift:93` + `:568` 闸门）、world_model 默认不加载（`InferenceEngineV2.swift:1687-1688`，仅 `AURORA_WORLD_MODEL=1` 开）。**全部核对无误。**
- **`pointer_heading` / 裸 `speed_digit_cnn` / `exp_*` 零引用**：`rg` 确认（`pointer_heading` 在 Sources 内 0 命中）。现役是 `tiny_arrow_v2`（`PointerHeadingReader.swift:273`）、`speed_digit_cnn_v4`（`:342`）。
- **模型体积**：`tiny_arrow_v2` 44K、`ppocrv6_tiny_ft_int8` 1.2M、`speed_digit_cnn_v4` 2.3M —— `du -sh` 实测一致。

### 4.2 doc10（CPU 合成设计）—— 几何/层序数学正确
- **ViewportPanel 12 层 ZStack 行号**：`:588/592/598/608/618/650/663/677/706/732/756/792/815` **全部精确命中**。
- **层序与注释矛盾**：`:614` 注释称「掩码画在检测框之下」，但 `MaskOverlay`（`:618`）排在 `ObstacleOverlay`（`:608`）之后 → ZStack 后者在上，**实际掩码盖住框**。该发现仍成立。
- **MaskGrid→屏幕映射**：`aspectFillLayout`（`:8743-8751`）、`+0.5` 补缝（`:8838`）、`padX/padY`、`r=min(640/h,640/w)`、`sx==sy==scale` —— 与 `:8822-8840` 一致。
- **文字块位置**：`ObstacleOverlay` 的类别+置信度胶囊（`:8966-8975`）、LOCK 标签（`:8996-9005`）、`MaskOverlay` 降级角标（`:8910`）—— 对，这些是"不能进位图"的硬约束。
- **`AURORA_DISABLE_LIGHT_FIELD` 已撤销**：`rg` 全仓 0 命中，与 doc10 顶部 banner 自述一致（banner 是对的，只是正文行号没跟着回退，见 L16）。
- **附录 A「光斑层成本≈0，停止 CPU 烘焙」**：数据无法复现，但**结论方向与源码自洽**——漂移默认关（`:690-691`），`.drawingGroup()` 失败记录在 `:617-641`。作为"不要先做这一步"的决策依据仍可用。

### 4.3 doc4（空转浪费）—— 定时器普查基本准确
- **`startAntiFreeze()` 确为空实现**（`App:6543-6546` 只 `dlog` 一行）。
- **`AuroraCache.metricsTimer` 生产不装**：`installMetricsTimerIfNeeded` 首行 `guard PerfBus.enabled else { return }`（`:514-515`）。
- **`LLMHealth.startAdaptiveProbing()` 无调用方**：全仓只有定义 `:502` 与注释 `:377`。
- **`GameModeDefender` 两进程各一份**：`EngineMain:1159` + `App:236`，3s / leeway 200ms（`GameModeDefender.swift:152-158`）。
- **BrandMark `spin` 是死状态**：`@State spin`（`:177`）、`repeatForever`（`:194`）、body（`:179-198`）内无任何读取 —— 对。
- **`PerfBus` 关闭时零开销**：`@inline(__always)` + `enabled ? … : 0`（`PerfSelfTest.swift:191-212`）。
- **`tickGapMs` / `lastTickTime` / `currentFrameCG` 均 `@ObservationIgnored`**（`:5558`/`:5556`/`:5193`）。
- **`currentFrameCG = nil` 全仓零命中** —— 仍成立（这就是 M3 冻结与 doc2「陈帧」的共同前提）。
- **`idleSkip` 降频**：MissionConsole `:6251`（15÷8≈1.9Hz）、netLoc `:6303`（10→2Hz）—— 对。
- **GameHUD 0.5s Timer**（`GameHUDWindow.swift:97`）、**QuestPanelReader 0.7s + `.accurate` p50 33.6ms**（`:431`、`:524-526`）—— 对。

### 4.4 doc11（GPU 使用点）
- **MetalGoose 编进主 target**：`Package.swift:189-192` 白名单含 `Vendor/MetalGoose/Engine`；根目录同名文件在 `exclude`（`:163-178`）。
- **每次 UI 启动建设备/队列**：`App:6262-6266`（`if !--engine { upscaleHost.prepare() }`）；`GooseEngine.swift:420-425`、`:889`（`view.isPaused = false`）。
- **`upscaleEnabled` 默认 false**（`App:5330`）、MTKView 遮挡门控（`:9105-9141`）—— 对。
- **两处 CIContext 默认关**：`ConfidenceEstimator.swift:274-275`（`AURORA_CONF_CI`）、`SpeedOCRReader.swift:970`（`AURORA_OCR_CI`）—— 对。
- **`CVPixelBufferGetIOSurface` 在 `Sources/` 0 处**；`import MetalPerformanceShaders` 0 处 —— 对。
- **无 `AVAssetWriter` / `VTCompressionSession`** —— 对（但见 N8：主帧是 JPEG）。
- **`tools/` 与 `Tools/` 同 inode `27586270`** —— 对。

### 4.5 doc1（箭头）
- **M2 置信度契约无人执行** —— **仍成立**：`bodyHeadingConf` 全仓只被 `MissionConsole:1868` 显示、`App:6792` 同步、`App:7449/7452` 写入；**无任何阈值比较**。`PointerHeadingReader.swift:114` 的「低于调用方阈值应视为不可信」仍无人执行。
- **M3 停车不置 nil → 冻结** —— **仍成立**：`stopDriving()`（`App:6465-6489`）与 `EngineMain.pauseDriving`（`:2350-2362`）都不碰 `bodyHeadingDeg`。
- **M4 无游戏画面门控** —— **仍成立**：调用侧只有 `pointerReader.isAvailable, adaptiveFrameCounter % 3 == 0`（`:7445`），无 frontmost/窗口判定。
- **M5 area=80 档位跳变** —— 常量仍在：`smallAreaSplit=80`（`:217`）、small 档 `aspect≤2.6 / fill 0.38~0.92 / sharpen≥4.4`（`:220-224`）、normal 档 `1.8 / 0.42~0.78 / 4.8`（`:227-231`）、`judge` 在 `:761-787`。文档漏了 `smallFillMin=0.38`，但主体对。
- **M6 连接丢失不清 `engineBodyHeading`** —— **仍成立**：`handleConnectionLoss`（`EngineClient.swift:578-596`）不清它；只有 `pointer` 消息的两个分支会写（`:434-437`）。
- **交接笔记的 0.16° 跳变中位**：`docs/指针朝向-交接笔记.md:236` 原文一致。

---

## 5. 置信度与未验证项

### 5.1 高置信（源码原文 + grep 计数双重确认）
§2.1 全部 8 条、§2.2 N1–N8、§4 全部条目。这些都可以复现，命令已写在表内。

### 5.2 未验证 / 无法验证
| 项 | 原因 |
|---|---|
| doc1 §5.2 的离线复刻判据数据（120/120 命中率、rcv 0.25~0.35、sharpen 5.2~6.8、尺度/模糊鲁棒性） | 依赖 `/tmp/nte_vid`、`/tmp/ptr_equiv`、`/tmp/ptrtest_480` 三套帧集，**均不存在**；未重新跑，不采信也不否定 |
| doc1 §6-3 的「坐标陈旧 18.1s」两处日志 | `/tmp/aurora_debug.log` 已被覆盖（L20），原行号无法核对 |
| doc10 附录 A/B/C 的全部实测数字（WindowServer 7.4%~44% 漂移、+12.82pp、0/720 重复率、MPSGraph 等） | `/tmp` 证据文件全部丢失；且 doc11 §2.6 的 +12.82pp 与 doc10 附录 A 的 0.27pp 本就是**不同实验**，不能互相印证 |
| doc11 §1.4/§2.6 的 GPU 百分比（4.76%、0.76%/0.01%、+12.82pp） | 原始 `/tmp/gpuwatch.py`、`/tmp/vis_ab3_out.log` 不存在；本机 WindowServer 基线漂移极大（文档自己也写了 7.4%~44%），这些数字只能作为"量级参考" |
| doc2 §2 的 `sample` 采样（writeMask 96、extractMask 465） | 引自 `docs/整合文档/05-性能与优化全史.md:232-236`，**该引用本身核对正确**，但它是 2026-10-11 的历史采样，不是当前值 |
| `YolopxEngine.extractMask` 是否仍是热点 #2 | 同上，历史数据；本次未采样 |
| doc3 的「6 个组件 GPU 算子 = 0」 | 引自 `docs/老旧文档/已整合归档-2026-10-18/性能-推理GPU占用审计-2026-10-11.md:193`，**引用路径与实际归档位置不符**（doc3 写的是裸文件名，文件实际在 `老旧文档/已整合归档-2026-10-18/` 下）；内容本身存在且相符，但按 doc3 给的路径找不到 |
| SpeedOCR 改档后的 `ane_dispatch_check` 结果 | 仓库内无记录；doc3 定的「先测 GPU 占比」前置步骤**无证据表明执行过** |
| 运行时行为（箭头实际颜色、OCR 是否真停） | 按纪律未启动 App；仅由源码与既有日志推断 |

### 5.3 一个需要 Lead 拍板的边界情况
doc3 把 `SpeedOCRReader` 称为「第 8 个 CoreML 加载点」。按 `MLModelConfiguration` 实例数重数：`PointerHeadingReader`1 + `YoloEngine`1 + `InferenceEngineV2`9 + `YolopxEngine`1 + `InferenceEngine`2 + `SpeedOCRReader`1 = **15 个配置实例**；按**模型文件**数则是 doc3 的分法。口径不同，数字不同，引用时须注明是"模型数"还是"配置点数"。

---

## 6. 给后续优化的三条硬建议

1. **以源码为准，不要以这三份文档的「待修清单」为准**。doc2 的 #1/#3、doc3 的 §3-①、doc4 的 §3-①、doc1 的 P0（渲染部分）都已在 `3082269` 落地。先 `git show 3082269 --stat` 看一遍再排期。
2. **doc1 的四条机制里还活着的是 M2/M3/M4/M5/M6，M1 只剩一半**（回退仍在、静默已除）。若继续修箭头，应从 "conf 门控"（M2）和 "stopDriving 清 nil"（M3）入手，这两条源码确认未动。
3. **doc10 的结论（光斑层≈0、不做 CPU 烘焙）可以采信，但不要引用它的行号**：`AuroraTheme.swift` 段整体偏 +15 行。用符号名 grep（`AuroraLightField`、`blob(`、`driftEnabled`）定位。
