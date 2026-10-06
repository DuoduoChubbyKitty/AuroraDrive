# YOLOPX 崩溃与掉帧专项（R3）

- **审计对象**：NaN/Inf 防护、数组越界、掉帧压力
- **审计任务**：t32 / attempt `e44ca8f4-39e4-4865-871f-3633e4ba6942`
- **审计员**：code-quality-auditor（只读；未修改任何生产源码）
- **审计时间**：2026-09-27 01:35 起
- **裁决**：**needs_revision（1 个 blocker）**

---

## 0. 先说被测基线（重要）

**本轮审计的代码不是 t30/t31 审计的那份。** 三个文件在 01:24–01:30 已被 t45/t47 修复改动：

| 文件 | t30/t31 审计时 | 本轮 |
|---|---|---|
| `YolopxEngine.swift` | mtime 17:xx / md5 `…` | **mtime 01:28 / md5 `1ea293656efc3742e86f5c7415b5a83f`** |
| `LaneFallback.swift` | mtime 17:04 / md5 `f22957a…` | **mtime 01:24 / md5 `9dbcaebe08e4817854a0b078f1d5e482`** |
| `AuroraDriveApp.swift` | mtime 17:xx | **mtime 01:30 / md5 `f28ef452978c17e0bad85bc383bdb84d`** |

**已落地的修复（本轮确认，不再重复报）**：
- ✅ R1-B1 / R2-B1 **尺寸同构校验**（`LaneFallback.swift:154-159` 新增 `laneMask.width == drivableMask.width`）
- ✅ R1-B1 **转向符号**（`:274` 改为 `deviation * steerGain`，注释同步更正）
- ✅ R1-B2 **`throttleCap` 改 `Optional`**（`:47`）+ 结构性保守保证（`:303-306`，介入时必压到 ≤0.3）
- ✅ R1-H2 **采样带动态化**（`:177-191`，按 metrics 的 valid 区取"下 1/4 ~ 下 9/10"）
- ✅ R1-H4 **稳定性双条件**（`:98-103` 帧数 **或** 时间窗 0.2s）
- ✅ R1-H1 **`fastRowsStrided`**（`YolopxEngine.swift:868-904`，按真实 strides 读 det）
- ✅ R1-M1 **EMA 注释更正 + 首帧初始化语义**（`:792-798`）
- ✅ R1-M4 自检 C3 改为**双向自洽断言**（`AuroraDriveApp.swift:1356-1370`，左右各一次，代码与断言不可能同错）

**复刻基线**：从当前生产源码逐字抽取（`/tmp/t30-audit/cur_core.swift`，966 行），仅去 `private`/`nonisolated`/`@MainActor` 隔离装饰，**逻辑零改动**；**11/11 关键行逐字一致性自检通过**。

---

## 1. 硬结论

| 审计项 | 结论 |
|---|---|
| ① **NaN/Inf 防护** | ✅ **完整**。`parseDetections` 的 `isFinite` 防线覆盖全部 5 个数值字段；11 组边界（全 NaN / conf=NaN / conf=±Inf / cx=±Inf / w=Inf / w=NaN / w=-1e30 / Float16 最大值）**全部安全剔除，零 trap**。掩码层 NaN/Inf 被 `b > a` 比较自然消化为"无前景"。`LetterboxMetrics.calculate` 极值输入（`Int.max`、0、负数）**无 trap**。 |
| ② **数组越界** | 🔴 **存在崩溃级缺口（需修）**。`MaskGrid.at()` **仍不守卫 `cells.count`**（t31 的 H1 未落地）。畸形掩码在 `evaluate` 内**实测 SIGTRAP**（`EXIT=133`），两处调用点均已二分钉死。**当前生产路径不可达**（构造点均满足不变式），但无断言保护。 |
| ③ **掉帧压力** | ✅ **安全**。主线程新增全部开销实测 **1.5 ms（正常）~ 4.4 ms（掩码完全退化）**，33ms 预算下占比 **4.6%~13%**。`MaskOverlay` 呈良好线性（≤2.6 ms）。EMA 稳态**不改变**前景占比。 |
| ④ **是否存在崩溃/掉帧级风险** | **崩溃级：有**（下方 blocker，条件触达）；**掉帧级：无**。 |

---

## 2. 审计项 ①：NaN/Inf 防护

### 2.1 `Int(Double)` 转换点全量清点（Swift 会 trap，不返回 0）

全仓 `Int(` 转换点共 **16 处**，逐条实测：

| # | 位置 | 输入来源 | 极值实测 | 判定 |
|---|---|---|---|---|
| 1-3 | `YolopxEngine.swift:131,132,136` `LetterboxMetrics.calculate` | `srcW/srcH`（外部尺寸） | `srcW=Int.max` → `r=6.9e-17`、`newW=640` **无 trap**；`srcW=0/-1` → guard 提前返回 `.zero` | ✅ |
| 4-7 | `YolopxEngine.swift:743-746` `extractMask` 的 `vx0/vy0/vx1/vy1` | `metrics.padX/padY/newW/newH`（**Int，已是整数**） | `padX=Int.max/2` 实测无 trap；且外层有 `min(grid, …)` 钳位 | ✅ |
| 8-11 | `YolopxEngine.swift:824-827` `positiveRatios` 同上 | 同上 | 同上 | ✅ |
| 12-13 | `LaneFallback.swift:186-187` `y0/y1`（**R1-H2 新增的动态采样带**） | `padY + newH*frac`，再除 `scale` | 见 §2.2 | ✅ |
| 14-17 | `LaneFallback.swift:339-342` `ratio()` 的 `x0/y0/x1/y1` | `metrics.padX/padY/newW/newH` | 同 4-7 | ✅ |

**关键分析（本轮重点核查 R1-H2 新引入的转换点）**：`bandTop / scale` 与 `bandBottom / scale`，其中 `scale = 640.0 / Double(laneMask.width)`。

- `laneMask.width > 0` 由**门② 保证**（`:154`），故 `scale` 有限且为正。
- `contentH > 0` 由 `:180-183` 的 guard 保证，故 `bandTop/bandBottom` 有限。
- 实测 6 组极值（含 `padY=Int.max/2`、`newH=Int.max/2`）**全部无 trap**（见下 §2.2）。
- ✅ **结论：R1-H2 的改动没有引入新的 trap 面。**

### 2.2 极值输入实测（复刻 `evaluate` 的计算链，不经门②）

```
padY=0/0      newW=640 newH=640              → y0=40   y1=144   放行
padY=0/140    newW=640 newH=360              → y0=57   y1=116   放行
padY=700/700  newW=640 newH=640              → y0=215  y1=160   门④拒绝（y1>y0 不成立）
padY=140/140  newW=640 newH=360              → y0=57   y1=116   放行
padY=Int.max/2 newW=640 newH=640             → y0=40   y1=144   放行   ← Double 域计算，不 trap
padY=0/newH=Int.max/2                        → y0=2.88e17 y1=160  门④拒绝
```
**零 trap。**

### 2.3 det 输出的非有限值 → `parseDetections`（逐组实测）

```
全 NaN                    → 0 框（已剔除）
conf=NaN（其余正常）      → 0 框（已剔除）
conf=+Inf                 → 0 框（已剔除）
cx=+Inf                   → 0 框（已剔除）
cx=-Inf                   → 0 框（已剔除）
w=+Inf                    → 0 框（已剔除）
w=NaN（conf 正常）        → 0 框（已剔除）
w=-1e30（大负数）         → 0 框（已剔除）
Float16 最大值 w=65504    → 1 框（被钳位为全帧框，非崩溃）
cx=1e30（float16→Inf）    → 0 框（已剔除）
```

**根因确认**（`YolopxEngine.swift:649-652`）：
```swift
// 非有限值一律跳过（NaN/Inf 进 Int() 会 runtime trap 崩全车）
guard conf.isFinite, conf > confidenceThreshold,
      cx.isFinite, cy.isFinite, w.isFinite, h.isFinite,
      w > 1, h > 1 else { continue }
```
- 5 个数值字段**全部**过 `isFinite`；
- `conf > confidenceThreshold` 对 **NaN 恒 false**（IEEE 比较语义）→ NaN conf 被二次拦截；
- `w > 1, h > 1` 对 **NaN 恒 false** → NaN 尺寸被二次拦截。
- 归一化输出还有 `min(max(…, 0), 1)` 四重钳位（`:692-695`）。

✅ **结论：det 路径的 NaN/Inf 防护完整且有多重冗余。**

### 2.4 掩码层 NaN/Inf（真实 dtype `float16`，逐组实测）

| 原始 logits 构造 | 前景格 | 送入 `LaneFallback` |
|---|---|---|
| `da` 全 NaN | 0/25600 | `nil`（拒绝） |
| `da` ch1=+Inf | 25600/25600 | 给建议（**语义正确**：正值即前景） |
| `da` ch0=+Inf / ch1=-Inf | 0/25600 | `nil`（拒绝） |
| `da` 交替 NaN / 正常值 | 25600/25600 | 给建议 |

**机制**：`extractMask` 只做 `if b > a { positive += 1 }`。NaN 参与比较恒 false，**不会向上传播**，只会退化为"该像素判为背景"。✅ **NaN 被自然消化，不产生非有限值下游。**

> ⚠️ 附带发现（medium）：ch1=+Inf 会产出 100% 前景。这不是 NaN 问题，而是 §4 提到的「前景占比无上限」问题 —— 已由 t31-R2-M3 记录，本轮不重复计入本审计项。

---

## 3. 审计项 ②：数组越界

### 3.1 越界点总表

| # | 索引访问 | 守卫 | 判定 |
|---|---|---|---|
| 1 | `MaskGrid.at()` 的 `cells[y*width+x]` | `x∈[0,width)`、`y∈[0,height)`；**不守卫 `cells.count`** | 🔴 **见 B1** |
| 2 | `extractMask` 的 `cells[gy*grid+gx]` | `grid` 由常量 160，`cells` 由 `count: grid*grid` 分配 | ✅ 同源 |
| 3 | `extractMask` 的 `f16[i0]/f16[i1]` | `capacity: total = shape[1]*h*w`；`i0 < h*w`、`i1 = h*w + i0 < total` | ✅ |
| 4 | `fastRowsStrided` 的 `base[off+j]` | `capacity = (rows-1)*rowStride+cols`；`off+j ≤ (rows-1)*rowStride+cols-1` | ✅（注释已明确该式） |
| 5 | `fastRows` 的 `p[i]` | `capacity: total`，`i < total` | ✅ |
| 6 | `parseDetections` 的 `raw[b+4]`（`b=i*6`） | `fastRowsStrided` 返回定长 `rows*cols`；`i<n` ⇒ `b+4 < n*6` | ✅ |
| 7 | `candidates[i]` / `kept[idx]` / `suppressed[idx]` | 索引来自 `candidates.indices` 或 `order`（同一集合） | ✅ |
| 8 | `rowCenters[rowCenters.count/2]` | 前置 `guard rowCenters.count >= 3`（`:211`） | ✅ |
| 9 | `ModelArray` 的 `out.shape[1]` | `guard out.shape.count >= 2`（`:623`） | ✅ |
| 10 | `extractMask` 的 `shape[1..3]` | `guard shape.count == 4, shape[1] >= 2`（`:728`） | ✅ |
| 11 | 候选模型列表 `candidateURLs` | `.map` 遍历，无下标 | ✅ |
| 12 | 采样带 `y0..<y1` | `guard y1 > y0`（`:188`）+ `y1 ≤ laneMask.height` | ✅ |
| 13 | `ratio()` 的 `x0..<x1` / `y0..<y1` | `guard x1 > x0, y1 > y0`（`:343`）+ `min(grid.width, …)` | ✅ |
| 14 | `MaskOverlay` 的 `0..<drivableMask.height` × `.at()` | `.at()` 自身守卫 x/y；`width/height` 同源 | ✅ |

**13/14 项有完整边界检查；唯一缺口是 #1。**

### 3.2 🔴 B1 — `MaskGrid.at()` 不守卫 `cells` 长度（崩溃级，独立子进程实测）

**位置**：`Sources/AuroraDrive/Inference/YolopxEngine.swift:50-54`

```swift
@inline(__always)
func at(_ x: Int, _ y: Int) -> Bool {
    guard x >= 0, x < width, y >= 0, y < height else { return false }  // ← 只守卫 x/y
    return cells[y * width + x] != 0                                    // ← 不守卫 cells.count
}
```

**实测（每例独立进程，父 shell 捕获退出码）**：

| 构造 | 结果 |
|---|---|
| 声明 160×160 / `cells.count = 100`，`at(0,0)` | 正常返回（cells[0] 存在） |
| 同前，`at(159,159)`（= cells[25599]） | **`EXIT=133` SIGTRAP** |
| 声明 160×160 / `cells = []`（空） | **`EXIT=133` SIGTRAP** |
| 声明 100000×100000 / `cells.count = 10` | **`EXIT=133` SIGTRAP** |
| `da` 畸形（`ll` 合法） | **`EXIT=133` SIGTRAP** |

**`evaluate` 内两处调用点均已二分钉死**：

| 调用点 | 构造 | 结果 |
|---|---|---|
| **`LaneFallback.swift:199`**（偏差循环 `laneMask.at(x, y)`） | `ll` 声明 160×160 但 `cells=160×80`，前景行 57..80；`at(30,79)` 安全 → 进入 `evaluate` 后在 y=80 越界 | **`EXIT=133` SIGTRAP** |
| **`LaneFallback.swift:349`**（`ratio()` 内 `grid.at(x, y)`） | `da` 声明 160×160 但 `cells=160×40`；`ratio` 扫 valid 区 y0=35..y1=125 | **`EXIT=133` SIGTRAP** |
| **对照**（`cells` 完全够用） | — | `EXIT=0`，正常输出 `steer=-0.2500` |

**为什么定级 blocker**：
1. `evaluate` 运行在**主线程 tick 内**（`AuroraDriveApp.swift:3401`），SIGTRAP 是**进程级死亡** —— 整个驾驶进程连同按键注入一起消失，已按下的键可能不会释放。
2. 这是 **fail-hard 而非 fail-open**，与 `LaneFallback` 的核心契约（"输入不可信 ⇒ 返回 nil"）**直接对立**。
3. 它**已有报告记录**（t31-R2-H1），但**本轮复核确认修复未落地** —— 代码与 t31 审计时**逐字相同**。按"重复出现且未处置"对待，不再降级。

**诚实说明当前可达性（不夸大）**：
- 生产路径下 `MaskGrid` 构造点经 grep 全仓清点为 **8 处**：`YolopxEngine.swift:63`（`.empty`，0×0）、`:781`（`count: grid*grid`）、`:815`（`count: n = grid.cells.count`）、以及 `AuroraDriveApp.swift:1310/1327/1330/1354/1393` 的**自检夹具**。
- **全部满足 `cells.count == width*height`**：前两个由构造式保证；自检夹具逐一核对均为 `[UInt8](repeating: 0, count: 160*160)` 形式（已 `read` 确认）。
- ⇒ **当前生产代码中该崩溃不可达。**

**但必须限期处置**，三条理由：
1. 该不变式**没有任何断言、注释或类型约束保护**，纯属隐式契约；
2. `MaskGrid` 是 `internal` 且有合成的 memberwise init，任何新增构造点都会立刻激活；
3. **与 R1-H3 的方案互为约束** —— `AuroraDriveApp`/`EngineMain` 的注释（`EngineMain.swift:32-35`）已明确写下未来方案：「若将来要在引擎模式下也显示掩码，必须先把 160×160 网格（约 50KB）加进共享内存协议」——**那个反序列化构造点会直接激活本崩溃**。

**修复建议**（一行，且语义为 fail-open）：
```swift
guard x >= 0, x < width, y >= 0, y < height, cells.count >= width * height else { return false }
```
> 优于「构造器加 `precondition`」——后者仍是 fail-hard。

---

## 4. 审计项 ③：掉帧压力

### 4.1 测量方法说明（先声明局限）

- **生产同款实现**：用 SwiftUI `Path`（生产 `MaskOverlay` 用的就是这个）+ 与生产**同构**的双层循环（全网格遍历 + `where` 过滤 + `addRect`）。
- ⚠️ **只测到 CPU 侧建路径成本**。`ctx.fill(path)` 的 **GPU 填充**本机无窗口环境无法测量 —— 这一部分**未量化**，见 §6 局限。
- 初版用 `CGMutablePath` 得到的 8%→0.29ms / 16%→2.60ms **非线性是测量假象**（两种 Path 实现不同）。改用生产同款 `SwiftUI.Path` 后呈**良好线性**，下表为**修正后**数据。

### 4.2 `MaskOverlay` 建路径成本（生产同款 `SwiftUI.Path`，5 轮取最小）

| 前景占比 | Rect 数 | Path 构建耗时 |
|---|---|---|
| ll 1.3% | 333 | 0.077 ms |
| ll 2.6% | 668 | 0.083 ms |
| da 8% | 2083 | 0.175 ms |
| da 16% | 4181 | 0.330 ms |
| ll 38.9%（t31-R2 实测退化上限） | 10022 | 0.886 ms |
| 全前景 100% | 25600 | 2.606 ms |

**结论**：**呈线性**（≈ 0.10 µs/Rect）。任务书给的估算区间（da 8~16% → 2000~4000 Rect、ll 1.3~2.6% → 300~700 Rect）**与实际相符**，实测耗时 **0.42 ms/帧**（da16%+ll2.6% 最坏组合）。

> 生产代码注释（`AuroraDriveApp.swift:3894-3897`）称"全网格遍历则一定会掉帧" —— 实测**全网格最坏 2.6 ms**，"一定会掉帧"的措辞偏重，但其**结论方向正确**（用 `where` 只遍历前景格是对的）。

### 4.3 掩码 EMA 平滑成本与行为

| 项 | 实测 |
|---|---|
| `smoothMask` ×1 | **0.352 ms** |
| da + ll 两张 | **0.704 ms/帧** |

**EMA 行为实测**（回应 R1-M1「EMA 疑为死状态」）：
```
首帧（accum 空 → map 初始化分支）: 输入前景=1 → 输出前景=1，accum.count=25600
交替抖动 [1,0,1,0,…] 8 帧 → 输出 [1,1,1,1,1,0,1,0]（确实在抑制）
[0,1,1,1,1,1] → 输出 [0,0,1,1,1,1] → 确认需连续 2 帧才放行
```
✅ **EMA 确实在起作用**（与代码注释 `:786-790` 的说明一致），R1-M1 的疑虑可关闭。

**EMA 是否改变前景占比（影响 t31-R2-M3 的结论）**：
| 输入占比 | 30 帧 EMA 稳态输出 |
|---|---|
| 1.3% | 1.3% |
| 2.6% | 2.6% |
| 8.0% | 8.1% |
| 16.0% | 16.3% |
| 38.9% | 39.1% |
✅ **稳态不改变占比**（恒定量输入下 EMA 收敛到真值）⇒ **t31-R2-M3「前景占比无上限」的结论不受 EMA 影响，依然成立。**

### 4.4 主线程 tick 总预算对照

| 场景 | letterbox | EMA ×2 | MaskOverlay | 合计 | 33ms 占比 |
|---|---|---|---|---|---|
| **正常**（da 8% + ll 2.6%） | 0.327 | 0.704 | 0.810 | **≈ 1.8 ms** | **5%** |
| **最坏合理**（da 16% + ll 2.6%） | 0.327 | 0.704 | 0.423 | **≈ 1.5 ms** | **4.6%** |
| **完全退化**（da 100% + ll 38.9%） | 0.327 | 0.704 | 3.341 | **≈ 4.4 ms** | **13%** |

**✅ 掉帧结论：无掉帧级风险。** 即使掩码完全退化（t31-R2 实测可达的最坏形态），主线程新增仍只占 33ms 预算的 13%，留足 28.6ms 给推理触发、控制、录制、UI 刷新。

**新增遍历成本说明**：`MaskOverlay` 每帧遍历 25600×2 格**全部**（只对前景格 `addRect`）—— 空掩码时纯遍历仅 **0.091 ms**，可忽略。

**与推理的相互作用（不属于本审计项但需提示）**：`yolopxEngine.infer` 在**主线程**做 letterbox（0.327 ms），推理本身在 `inferenceQueue` 后台（R1 实测 163 ms/帧），且有 `isInferencing` 防重叠 → **不会阻塞主线程、不会积压**。主线程侧总计仍在 2 ms 量级。

---

## 5. 附带更正：R1 的 H3 结论错误（非本次审计项，但涉及接线事实）

R1 报告 §审查项 7 曾判定「引擎模式下 YOLOPX **双份代价零收益** —— 引擎进程真跑 YOLOPX」。**该结论是错的，本轮予以更正。**

**代码事实**：

| 事实 | 证据 |
|---|---|
| 引擎进程是 **socket 服务端** | `EngineMain.swift:568` `server.start()`；全文只用 `EngineClient.protocolVersion`（`:802`），**从不调用 `startup()`** |
| `isActive` 只由**客户端连接**激活 | `EngineClient.swift:168` `private func activate() { isActive = true; … }`，唯一调用者是 `:130 func startup()` 的重连定时器 |
| 引擎进程内 `isActive` **恒为 false** | 既然 `activate()` 从不执行 → `EngineClient.shared.isActive == false` |
| 故引擎进程的 `st.tick()` **走完整本地路径** | `AuroraDriveApp.swift:3180` 的 `if EngineClient.shared.isActive { tickEngineMode(); return }` **不进** |

**等一下** —— 上表推出的是「引擎进程 tick 走完整路径 ⇒ **会**跑 YOLOPX」，而 `EngineMain.swift:22-35` 的注释称「引擎模式下 YOLOPX 根本不跑」。

**两者矛盾，且该注释的论证有误**：它引用的 `AuroraDriveApp.swift:3172 附近` 早退分支，在**引擎进程内的条件为 false**（因为引擎进程自己不 activate），所以那个 `return` **不会**在引擎进程里生效。

**我不断言哪一方对**：本项需要**运行期证据**（在引擎进程内打印 `EngineClient.shared.isActive` 与 `yolopxEngine.inferenceCount`）才能定案，**本轮为只读审计、不启动进程，故不给结论**。

**但可以确定的是**：`EngineMain.swift:22-35` 的注释把「UI 进程的早退条件」当作「引擎进程的行为依据」，这个**论证链是错的** —— 即使最终结论偶然正确，注释本身会误导后来者。建议：① 用运行期证据定案；② 无论结论如何，修正该注释的论证依据。

> 本项按 **medium** 记录，不计入本次三项审计的 blocker。

---

## 6. 诚实局限

1. **复刻而非插桩**：被测代码从生产源码逐字抽取后独立编译（11/11 关键行一致性自检通过），非链接生产符号的同一二进制。
2. **GPU 填充成本未量化**：`MaskOverlay` 只测了 CPU 侧 `Path` 构建。`ctx.fill(path)` 的 GPU 侧（25600 个 Rect 的批量填充）**本机无窗口环境无法测量**。这是掉帧结论最大的不确定来源 —— 但按"CPU 侧 2.6ms 对应 GPU 侧通常为同量级或更低"的经验，且 33ms 预算充裕（当前占 5~13%），**判为无掉帧风险是合理的**，非"已证明安全"。
3. **未真机跑 App**：所有测量为离线微基准，未在真实驾驶会话中采样 `tickGapMs`。生产已有 `tickGapMs` 诊断字段（`AuroraDriveApp.swift:3175`），建议真机确认。
4. **B1 的可达性判断基于静态构造点分析**（grep 全仓 8 处 + 逐处 read 核对）。若存在我未扫到的动态构造路径，可达性结论需修正。
5. **性能为单点测量**：手册 §140 已警告本机噪声大。本报告只采用**量级差距悬殊**的结论（2.6ms vs 33ms），未采用 10% 量级差异。
6. **§5 的接线矛盾未定案**：需运行期证据，本轮只读审计不提供。
7. **修复并行进行中**：本轮基线为 01:24–01:30。若 t45/t47 在我审计期间继续改动，请在修复后对本报告用例复跑。

---

## 7. 复现命令

```sh
cd /tmp/t30-audit

# 复刻基线（逐字抽取自当前生产源码，含 11/11 关键行一致性自检）
#   cur_core.swift ← YolopxEngine.swift:44-64,74-142,618-715,723-925,929-979(+readML)
#                   / LaneFallback.swift:28-354 / RuleController.swift:29-70
#                   / EscapeController.swift:28-44 / AuroraDriveApp.swift:3899-3937

# ① NaN/Inf 审计（Int() 转换点极值 + det 边界 10 组 + 掩码 NaN/Inf）
swiftc -O cur_core.swift cand.swift r3_a.swift -o a3 && ./a3

# ② 越界审计（含崩溃隔离；133 = SIGTRAP）
swiftc -O cur_core.swift cand.swift r3_e.swift -o e3
./e3 ll    # → EXIT=133，钉死 LaneFallback.swift:199（偏差循环）
./e3 da    # → EXIT=133，钉死 LaneFallback.swift:349（ratio()）
./e3 ok    # → EXIT=0（对照：cells 够用）
./e3 ema   # → EMA 行为 + 稳态占比

# ③ 掉帧压力量化（生产同款 SwiftUI.Path）
swiftc -O cur_core.swift cand.swift r3_d.swift -o d3 && ./d3
```

---

## 8. 只读合规声明

- **未修改任何生产源码**（`Sources/**`、`Package.swift`、`models/**`、`tools/yolopx/**` 零改动）。
- 唯一写入 = 本报告 + `/tmp/t30-audit/` 下的测试用例与逐字抽取基线（未污染仓库；`tools/yolopx` 为独立 git 仓库，全程未写入）。
- `cur_core.swift` 为生产源码逐字副本，仅去 `private`/`nonisolated`/`@MainActor` 隔离装饰，**逻辑零改动**。
