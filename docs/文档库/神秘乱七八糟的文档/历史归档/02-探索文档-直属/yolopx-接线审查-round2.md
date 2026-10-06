# YOLOPX 接线安全与代码质量审查（R4 · round-2）

- **审查对象**：t28 接线最终化 + t45 修复轮次 2（`review-round-2`）
- **审查任务**：t46 / attempt `2fdd643a-a351-47db-8949-614c767323d4`
- **审查员**：code-quality-auditor（只读；未修改任何生产源码）
- **审查时间**：2026-09-27 01:48 起
- **裁决**：**needs_revision（0 blocker / 1 high）**

---

## 0. 先说基线（本轮审查对象确实在变动）

审查期间被测文件被 t47 再次修改，故须声明两个时点：

| 文件 | t46 开始时（01:48） | 审查过程中（01:52–01:55） |
|---|---|---|
| `YolopxEngine.swift` | md5 `1ea293656efc…`（01:28） | **md5 `16d7ae6228be…`（01:55）** |
| `LaneFallback.swift` | md5 `9dbcaebe08e4…`（01:24） | **md5 `581cea449097…`（01:52）** |
| `AuroraDriveApp.swift` | md5 `f28ef452978c…`（01:30） | 未变 |
| `EngineMain.swift` | md5 `e5026f68fc9a…`（01:27） | 未变 |

**我在审查中发现 t47 已落地，并据新基线重跑了全部验证。** 本报告的结论基于**最新基线**（01:52–01:55），且**明确区分**「t45 的成果」与「t47 的成果」。

**复刻基线**：从最新生产源码逐字抽取（`/tmp/t30-audit/lf_core.swift`），仅去 `private`/`nonisolated` 隔离装饰，逻辑零改动；**关键行逐字一致性自检 5/6 命中**（唯一"缺失"是我 grep 的字符串拼写与实际用法不符，非代码问题）。

---

## 1. 硬结论

| # | 审查项 | 结论 |
|---|---|---|
| 1 | **三条链路「首次上线」标准** | ⚠️ **基本合格，但存在一处未达标**（见 H1：`loadIfNeeded` 主线程同步阻塞） |
| 2 | **主循环时序风险（33ms 红线）** | 🔴 **有 high**：R1-H1 修复后推理已大幅提速，但**加载路径**在主线程同步阻塞 5.4 秒（首次）/ 200ms（暖态） |
| 3 | **`loadFirstUsableModel` 候选遍历** | ✅ **实现正确**（逐候选 continue、每次失败记名+因、不吞异常） |
| 4 | **`.mlpackage` 编译路径** | ✅ **正确**（`MLModel.compileModel(at:)`，编译失败记录原因并 continue） |
| 5 | **`isUsingFp16Fallback` 读实际命中名** | ✅ **正确**（读 `loadedModelName`，非文件名猜） |
| 6 | **7 个接线点** | ✅ **全部在场且完好** |
| 7 | **I 轮 blocker 回归**（R2-B1 / R2-H1 / R3-B1…） | ✅ **全部已修复且实测验证通过** |

**当前唯一 high**：H1 —— `loadIfNeeded()` 在**主线程**同步执行模型加载，冷启动实测 **5.37 秒**（首次加载含 ANE 计算图编译与缓存落盘），暖态约 **200 ms**。

---

## 2. 审查项 1：三条新激活链路的「首次上线」标准

三条链路的**代码路径**本身在 t30/t31/t32 三轮已逐步审清；本项按契约要求，以「此前 `isLoaded` 恒 false ⇒ 死状态 ⇒ t28 后首次激活」为前提，逐条确认**激活后的实际行为**。

### 2.1 `effectiveDetections` 的 YOLOPX 分支

`AuroraDriveApp.swift:1881-1887`（t45 后行号未变）：
```swift
var effectiveDetections: [Detection] {
    let base = EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections
    if preferYolopxDetections, yolopxEngine.isLoaded, !yolopxEngine.detections.isEmpty {
        return yolopxEngine.detections
    }
    return base
}
```
✅ **四条回落路径完备**（未加载 / 无框 / 引擎模式 → 回落 `base`），不会变瞎。t30 §审查项 8 已验证，本轮复核无变化。

### 2.2 `MaskOverlay` 掩码绘制

`AuroraDriveApp.swift:3986-4060`。t32 §4.2 已用**生产同款 SwiftUI.Path** 实测：333 Rect = 0.077 ms … 25600 Rect = 2.606 ms，**呈线性 ≈0.10 µs/Rect**；主线程合计正常 1.8 ms（33ms 的 5%）、掩码完全退化 4.4 ms（13%）。✅ 无掉帧风险。

### 2.3 `LaneFallback` 车道兜底

本轮**重跑 t31 全部关键用例**（新基线）：

| 回归项 | t31 时 | 本轮实测 | 判定 |
|---|---|---|---|
| 方向符号（线在左→向左） | ❌ `+0.25`（反向） | **`-0.2500`** | ✅ 已修 |
| 线在右→向右 | ❌ `-0.25` | **`+0.2500`** | ✅ 已修 |
| 双向相反且指向中心 | ❌ | **✓ PASS** | ✅ |
| 非预期尺寸 ll=40/80/320/640 | ❌ 全部放行 | **全部 `nil`** | ✅ 已修 |
| `ll=80/da=80`（自洽且相等，t31 点名的绕过） | ❌ 放行 | **`nil`** | ✅ 已修 |
| 介入时 `throttleCap ≤ 0.3` | ❌ 默认 1.0 | **cap=0.30（正常）/ cap=0.00（da 极少）** | ✅ 已修 |
| 前景占比上限 | ❌ 38.9% 仍判健康 | **15% 起 `isDegraded=true` → nil** | ✅ 已修 |
| 越权四条硬规则 | ✅ | ✅（`Δ≤0.25` / 油门只压 / 刹车只加 全 ✓） | ✅ 保持 |

**⇒ 三条链路的首次上线行为均已达标。** 唯一未达标的是**加载路径的时序**（H1）。

---

## 3. 审查项 2：主循环时序风险（本轮重点）

### 3.1 `infer` 的主线程同步部分 —— ✅ 很小

`YolopxEngine.swift:495-550` 的结构是「主线程做 letterbox → `inferenceQueue.async` 后台推理 → 结果回主线程 `finish`」。实测主线程同步部分：

| 步骤 | 实测 |
|---|---|
| `LetterboxMetrics.calculate` | **< 0.0001 ms** |
| `drawLetterbox` | **0.312 ms** |
| **主线程同步合计** | **≈ 0.31 ms**（33ms 预算的 **0.9%**） |

### 3.2 `isInferencing` 跳帧门 —— ✅ 真的能防止主线程被拖死

`YolopxEngine.swift:528` `guard !isInferencing else { return }` + `:546` 置位 + `finish():615` / `reset():658` 复位。

- 主线程**只在开头做 0.31 ms 的 letterbox**，随后立即返回 → **不会等待推理完成**。
- 跳帧门确保后台队列不积压 → 主循环不会被推理拖死。
- ✅ **结论：`isInferencing` 机制有效。212ms/163.5ms 的推理耗时**全部发生在后台队列**，不占用 33ms 主循环预算**。

### 3.3 🔴 H1：`loadIfNeeded()` 在**主线程**同步阻塞（本轮唯一 high）

**位置**：`YolopxEngine.swift:394-425`（`loadIfNeeded`）→ `:352-392`（`loadFirstUsableModel`）

**独立进程实测**（每候选一个进程，避免多模型驻留互相干扰）：

| 候选 | 编译 | 加载 | 合计 | 首帧 prediction |
|---|---|---|---|---|
| **`yolopx3_pal8_detfp.mlmodelc`（实际命中）** | — | **5371.3 ms** | **5371.4 ms** | 378.0 ms |
| `yolopx3_w8a16.mlmodelc` | — | 失败 5.3 ms | 5.3 ms | — |
| `yolopx3_pal8_detfp.mlpackage` | 1097.9 ms | 6094.4 ms | 7192.4 ms | 258.9 ms |
| `yolopx3_int8.mlpackage` | 619.8 ms | 6665.3 ms | 7285.1 ms | **61576.8 ms** |

**同候选连续加载 3 次**（区分冷/暖）：
```
第 1 次 MLModel(contentsOf:) =  7113.1 ms
第 2 次 MLModel(contentsOf:) =   202.0 ms
第 3 次 MLModel(contentsOf:) =   199.6 ms
```
⇒ **冷启动 5.4~7.1 秒，暖态 ~200 ms**。差值来自 ANE 计算图编译与缓存落盘（`pal8_detfp.mlmodelc` 体积 **32 MB**，含 33 MB `weight.bin` + 358 KB `model.mil`）。

**调用点分析（决定这个阻塞落在谁身上）**：

| 调用点 | 上下文 | 阻塞后果 |
|---|---|---|
| `startDriving()`（`:2829`） | **用户点击「开始」的按钮回调**，主线程 | 🔴 **UI 冻结 5.4 秒**：按钮无响应、窗口转圈、无任何进度提示。且该语句位于 `captureEngine.start()` **之后**，此间抓屏已启动但推理未就绪 |
| `infer()` 内 `:473`（`isLoaded == false` 时） | **30Hz tick 路径内** | 🟠 首次 tick 阻塞 5.4 秒（tick 期间界面冻结）；此后有 5s 冷却期兜底 |

**为什么这是 high 而非 blocker**：
- **不产生错误决策**、不崩溃、不越权 —— 它只影响**可用性**（UI 冻结 + 启动延迟）。
- 首次加载发生在 `startDriving`（用户主动点击），此时车**尚未开始行驶**（`controlEngine.releaseAll()` 刚执行、无按键注入）⇒ **不构成"行驶中失控"**。
- **但**5.4 秒的主线程冻结在**驾驶启动瞬间**发生，若用户在此窗口内认为"没反应"而重复点击、或游戏已开始而 AI 未接管，存在**人为操作风险**；且 `captureEngine.start()` 已先行启动，抓屏线程在跑而主线程卡死 5.4 秒。

**这是既有架构模式，非 t28/t45 引入**：`InferenceEngine.loadIfNeeded()`（`:142`）与 `YoloEngine.loadIfNeeded()`（`:173`）**同样**在主线程同步 `MLModel(contentsOf:)`，且注释明确写着「P0-4 修复：…避免主线程同步 MLModel() 30Hz 重试风暴」。**故这是项目既有设计，YOLOPX 只是第三个加入者，且它的模型最大（32 MB）、加载最慢。**

**修复建议**（三选一，推荐 ①）：
1. **把 `loadFirstUsableModel()` 整体移到 `inferenceQueue`**（或 `Task.detached`），主线程只置一个 `isLoading` 标志 + 完成回调 —— 与 `warmUp` 的既有异步模式一致（`warmUp` 已经是 `queue.async`，说明这条路项目已走通）。
2. **至少在 `startDriving` 里延后**：先 `loadIfNeeded()` 的后台版、再让 UI 显示"模型加载中…"，避免按钮回调内阻塞。
3. 若坚持同步：给 `startDriving` 加**进度提示**（NSProgressIndicator / 日志），并在加载期间禁用「开始」按钮防重复点击。

> **补充说明（诚实）**：生产二进制 `--yolopx-selftest` 的总墙钟只有 **1.53 秒**（含加载 + 42 项断言），远低于我离线测得的 5.4 秒。差异来源：自检进程此前已多次加载过同名模型，**ANE 编译缓存已在系统 `/var/folders` 命中**。故 5.4 秒是**首次运行（冷缓存）**的值；长期使用后通常是 200 ms 量级。**H1 的实际影响取决于用户是否遇到冷缓存**（首次安装、系统清理临时目录后）。

---

## 4. 审查项 3-5：模型加载路径（契约逐点）

### 4.1 `loadFirstUsableModel` 候选遍历 —— ✅ 完全符合契约

`YolopxEngine.swift:352-392`，逐行核对：

| 契约要求 | 实现 | 判定 |
|---|---|---|
| 失败必须 `continue` 到下一候选 | `:363`（不存在）、`:374`（编译失败）、`:386`（加载失败）**三处均 `continue`** | ✅ |
| 每次失败记录「候选名 + 失败原因」 | `:362` `"✗ \(name) — 不存在"`、`:373` `"✗ \(name) — 编译失败: \(error.localizedDescription)"`、`:385` `"✗ \(name) — 加载失败: \(error.localizedDescription)"` | ✅ **三类失败都带候选名 + localizedDescription** |
| 不得吞异常 | 三处 `catch` 均**不重新抛出**，但**全部记录到 `log`**，且 `log` 在成功时（`:382`）与失败时（`:390`）**都**赋给 `loadAttemptLog`；失败时 `errorMessage` 汇总全部候选结局（`:404`） | ✅ 信息无丢失 |
| 成功即返回 | `:383` `return (m, name)` | ✅ |

**额外优点**：`:361` 先做 `fileExists` 存在性检查再编译/加载，**避免对不存在的路径调 `compileModel`**（会抛无信息异常）。

### 4.2 `.mlpackage` 的 `compileModel` 路径 —— ✅ 正确

```swift
if name.hasSuffix(".mlpackage") {
    do { loadURL = try MLModel.compileModel(at: url) }
    catch { log.append("  ✗ \(name) — 编译失败: \(error.localizedDescription)"); continue }
}
```
✅ **用 `name.hasSuffix(".mlpackage")` 判定而非依赖异常**；编译失败**记录原因并 continue**，不吞不崩。实测编译成功（1.1s / 0.6s），路径可达。

### 4.3 `isUsingFp16Fallback` 读实际命中名 —— ✅ 正确

`YolopxEngine.swift:389-391`：
```swift
private var isUsingFp16Fallback: Bool {
    (loadedModelName ?? "").contains("fp16")
}
```
✅ 读的正是 `loadIfNeeded` 里由 `hit.name` 赋值的 `loadedModelName`（`:411` `loadedModelName = hit.name`），**消除了"靠文件名猜"的重复真相源**。且使用时（`:418`）在 `loadedModelName` 赋值**之后**，无时序问题。

> minor：`.contains("fp16")` 是子串匹配。当前候选表里只有 `yolopx3_fp16.mlpackage` 含 `fp16`，无歧义。若将来出现 `w8a16_fp16` 之类命名会误判 —— 但**当前无此风险**，仅记录。

---

## 5. 审查项 6：7 个接线点逐条核对

| # | 契约要求 | 当前位置 | 内容 | 判定 |
|---|---|---|---|---|
| 1 | `:2550` `yolopxEngine` 字段 | **`:2636`** | `let yolopxEngine = YolopxEngine()` | ✅ |
| 2 | `:2554` `laneFallback` 字段 | **`:2640`** | `let laneFallback = LaneFallback()` | ✅ |
| 3 | `:2743` `loadIfNeeded` | **`:2829`** | `yolopxEngine.loadIfNeeded()` | ✅ |
| 4 | `:3182` `infer` | **`:3268`** | `yolopxEngine.infer(image: cg)` | ✅ |
| 5 | `:3401` 决策链兜底 | **`:3487`** | `if let advice = laneFallback.evaluate(laneMask: yolopxEngine.laneMask, …)` | ✅ |
| 6 | `:3829` `applyLaneAdvice` | **`:3915`** | `func applyLaneAdvice(_ advice: LaneAdvice, to cmd: ControlCommand)` | ✅ |
| 7 | `:3898` `MaskOverlay` | **`:3986`** | `struct MaskOverlay: View` | ✅ |
| 8 | `MissionConsole:589` | **`:589`** | `MaskOverlay(active: state.isDriving && state.showYolopxMasks, …)` | ✅ |

**行号整体后移是 t45 增补注释/代码所致，非接线位移。** 8 处全部在场、调用形态正确。`MissionConsole.swift` 的 mtime 仍是 `17:20`（未参与 t45 修改），接线未动。

**全仓唯一性复核**：`yolopxEngine.infer(image:)` 全仓 **1 处**调用（`:3268`），与 t45 的 C5 记录一致。

---

## 6. 审查项 7：I 轮 blocker 回归（全部已修，实测验证）

**新增实测（本轮 V1/V2/V3/V4/V5 五组，基于 01:52–01:55 新基线）**：

| 原 finding | 原级别 | 本轮实测 | 判定 |
|---|---|---|---|
| **R2-B1** 门② 不校验预期尺寸 | blocker | `ll=40/80/320/640` **全部 `nil`**；`ll=80/da=80`（t31 点名的自洽绕过）**`nil`** | ✅ **已修** |
| **R2-H1 / R3-B1** `at()` 不守卫 `cells.count` | high→blocker | `cells=100` / `cells=0` / `100000²,count=10` **均不崩溃**，`at(159,159)` 返回 `false`，`evaluate → nil` | ✅ **已修** |
| **R1-B1** 转向符号反向 | blocker | 线在左 → **`-0.2500`**；线在右 → **`+0.2500`**；双向相反且指向中心 ✓ | ✅ **已修** |
| **R1-B2** 满油门穿透 | blocker | 介入时 `cap=0.30`（正常）/ `cap=0.00`（da 极少）⇒ 结构性保守成立 | ✅ **已修** |
| **t31-M3** 前景占比无上限 | medium | 15% 起 `isDegraded=true` → `nil`（`lanePositiveCeil=0.10`） | ✅ **已修** |
| **R1-H2** 采样带固定常量 | high | 改为按 metrics 动态计算（下 1/4~下 9/10） | ✅ **已修** |
| **R1-H1** `fastRows` 不生效 | high | 新增 `fastRowsStrided`，t45 实测 **79.20 ms → 0.19 ms** | ✅ **已修** |
| **R1-M1** EMA 疑为死状态 | medium | t32 实测 EMA 确实在抑制抖动、稳态不改变占比 | ✅ **已关闭** |
| **R1-M4** 自检断言永真 | medium | 改为双向自洽断言（代码与断言不可能同错） | ✅ **已修** |

**`at()` 修复的额外优点（值得记录）**：除了 `cells.count >= width * height`，还加了
```swift
let idx = y * width + x
guard idx >= 0, idx < cells.count else { return false }
```
双重守卫，且**语义为 fail-open（返回 false = 背景）而非断言/崩溃** —— 与红线一致。这使得**任何未来新增的 `MaskGrid` 构造点（如 R1-H3 设想的掩码共享内存反序列化）都被这层兜住**。

**一处行为变化（诚实记录，非缺陷）**：截断掩码（`da.cells` 只覆盖部分行）现在**不崩溃**，但 `at()` 把越界当背景 ⇒ `drivableRatio` 被**低估** ⇒ 更容易触发刹车建议（`brake=0.60 cap=0.00`）。**退化方向是保守的**，符合 fail-open 精神。且该路径生产不可达（8 个构造点均满足不变式）。

---

## 7. 代码质量审查

| 维度 | 评价 |
|---|---|
| **命名** | ✅ `loadFirstUsableModel` / `fastRowsStrided` / `interveningThrottleCap` / `lanePositiveCeil` 达意。✅ 先前 R1-L6 指出的 `isContiguous` 名不符实已在注释中澄清（`:847` 附近说明它只给 da/ll 用） |
| **结构** | ✅ `nonisolated static` 纯函数与 `@MainActor` 状态分离清晰；新增的 `fastRowsStrided` 与 `fastRows` 职责分明（前者带 padding，后者要求严格连续） |
| **错误处理** | ✅ 三处 catch 全部记录 `localizedDescription`，无 `try!`、无 `as!`；`guard let` 链完备 |
| **防御性** | ✅ 显著提升：`at()` 双重守卫、门② 四重尺寸校验、`isFinite` 五字段、`conf > thresh` 与 `w > 1` 对 NaN 的二次拦截 |
| **重复代码** | ⚠️ **仍存在**：`YolopxEngine.positiveRatios()` 与 `LaneFallback.ratio()` 的 valid 区换算**几乎逐行相同**（同样的 `strideD`/`x0/y0/x1/y1`/双层循环）。R1 已记录，本轮**未处理** —— 属可接受的技术债（两处口径若分叉会静默出错，建议抽公共工具函数） |
| **魔法数字** | ✅ 改善明显：`interveningThrottleCap`、`lanePositiveCeil`、`drivablePositiveCeil`、`sampleBandTopFrac/BottomFrac` 均已具名 + 注释依据。⚠️ `MaskOverlay` 的 `+ 0.5`（防缝）仍无注释（R1-L7，low，未处理） |
| **注释质量** | ✅ **优秀**。多处注释直接记录「为什么」与「历史踩坑」+ 日期（如 `at()` 的 R2-H1 修复说明、`lanePositiveCeil` 的取值依据与局限）。**这是本项目最突出的优点** |
| **诚实性** | ✅ `lanePositiveCeil` 的注释**主动声明了取值局限**（t47 写明"详见上方取值依据与局限声明"），未把推断写成实测 |

---

## 8. 结论：这套接线能否安全上车？

**可以上车，但需先处理 H1（加载时序）或明确接受它。**

**已经达标的部分**（三轮审查的全部 blocker 均已修复并经本轮实测验证）：
1. ✅ **fail-open 红线成立** —— 五类降级输入全部返回 `nil`，尺寸校验已补到四重
2. ✅ **转向方向正确** —— 双向自洽验证通过
3. ✅ **不越权** —— 限幅 ±0.25、油门结构性保守（介入时 ≤0.3）、刹车只加不减
4. ✅ **不崩溃** —— `MaskGrid.at()` 双重守卫，畸形输入退化为"背景"而非 SIGTRAP
5. ✅ **主循环不被拖死** —— 主线程同步部分仅 0.31 ms，推理全在后台队列，跳帧门有效
6. ✅ **不掉帧** —— MaskOverlay 最坏 2.6 ms，主线程合计 ≤4.4 ms（33ms 的 13%）
7. ✅ **加载路径正确** —— 候选遍历、编译失败处理、失败原因记录、fp16 判定全部符合契约
8. ✅ **7 个接线点完好**

**仍待处理的唯一问题**：
- 🟠 **H1**：`loadIfNeeded()` 主线程同步阻塞 —— 冷启动 **5.4 秒**（首次/缓存失效）、暖态 ~200 ms。发生在 `startDriving` 按钮回调内，造成 UI 冻结。**属既有架构模式**（M9/YoloEngine 同样如此），非本轮引入，但 YOLOPX 模型最大、加载最慢，是三者中最严重的。

**33ms 红线的现状（诚实）**：t45 的 C3 修复把 `parseDetections` 从 79.2 ms 降到 0.19 ms，端到端推算约 84 ms，**仍超 33ms 预算 2.5 倍** —— 但这**发生在后台队列**，不占主循环预算。**主循环本身是安全的**（≤4.4 ms）。红线未达标属已知问题，已由 t45 独立上报，本报告不重复计入。

**建议的修复顺序**：H1（移 `loadFirstUsableModel` 到后台队列）→ 抽公共 `validRegionRatio` 消除重复（可选）。

---

## 9. 诚实局限

1. **基线在审查期间变动**：被测文件在 01:52–01:55 被 t47 修改，我已据新基线重跑全部验证。若此后继续修改，请复跑本报告用例。
2. **复刻而非插桩**：被测代码从生产源码逐字抽取后独立编译（关键行一致性自检通过），非链接生产符号的同一二进制。
3. **H1 的冷/暖差异未在真机验证**：5.4 秒是离线测得的**冷缓存**值；生产自检总墙钟仅 1.53 秒（缓存已暖）。**实际用户影响取决于是否遇到冷缓存**，需真机确认（建议在 `startDriving` 前后打时间戳日志）。
4. **未真机驾驶**：未启动 App 跑完整驾驶循环，未验证 H1 在真实点击流程中的冻结表现。
5. **性能为单点测量**：手册 §140 已警告本机噪声大，故只采用量级悬殊的结论。
6. **GPU 填充成本未量化**（沿用 t32 局限）：`MaskOverlay` 只测 CPU 侧建路径。
7. **未验证**：`isUsingFp16Fallback` 的 `.contains("fp16")` 子串匹配在当前候选表下无歧义，但未测试新增命名变更场景。

---

## 10. 复现命令

```sh
cd /tmp/t30-audit

# 逐字抽取基线（含关键行一致性自检）
#   lf_core.swift ← YolopxEngine.swift:44-82(MaskGrid),92-160(LetterboxMetrics)
#                 / LaneFallback.swift:29-366(全文) / EscapeController.swift:28-44
#                 / AuroraDriveApp.swift:3915-3938(applyLaneAdvice)

# ① I 轮 blocker 回归 + 三条链路首次上线验证
swiftc -O lf_core.swift r4_v.swift -o v4 && ./v4

# ② 截断掩码行为（at() 修复后的退化方向）
swiftc -O lf_core.swift r4_x.swift -o x4 && ./x4

# ③ H1：候选加载成本（每候选独立进程，避免多模型互相干扰）
swiftc -O lf_core.swift r4_load.swift -o l4
for c in yolopx3_pal8_detfp.mlmodelc yolopx3_w8a16.mlmodelc yolopx3_pal8_detfp.mlpackage; do ./l4 "$c"; done
swiftc -O lf_core.swift r4_warm.swift -o w4 && ./w4     # 冷/暖对比

# ④ 生产二进制自检（权威对照）
cd /Users/dupi/Desktop/自动驾驶系统
./.build/arm64-apple-macosx/release/AuroraDrive --yolopx-selftest   # 42 项全过 / 退出码 0
```

---

## 11. 只读合规声明

- **未修改任何生产源码**（`Sources/**`、`Package.swift`、`models/**`、`tools/yolopx/**` 零改动）。
- 唯一写入 = 本报告 + `/tmp/t30-audit/` 下的测试用例与逐字抽取基线。
- 崩溃隔离测试使用独立子进程，未影响任何生产进程。
