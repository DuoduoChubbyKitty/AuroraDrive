# YOLOPX · W3 修复轮次 2（t45）报告

> 契约：13 项验收标准，覆盖车道兜底方向缺陷、油门语义、strides 性能、采样带几何、
> 引擎模式行为、稳定性窗、自检断言与退出码等。
> 执行：swift-fixer｜**时间：2026-09-27 01:05–02:10（GMT+8）**｜attempt 2。

---

## 0. 结论摘要

13 项**全部处理完毕**（12 项改代码 + 1 项按事实记录不改）。
`swift build -c release` **EXIT=0**、error 计数 **0**；
`--yolopx-selftest` **42 项断言全过、0 失败、退出码 0**。

**两项超出契约预期的实测收获**：

1. **C3 的性能影响比契约预估的大得多**：契约估「163.5ms→119ms」，
   实测 det 读取 **79.20ms → 0.19ms（约 417×）**，逐位一致。这是本轮最大的性能发现。
2. **C5 的前提经核实不成立**：契约怀疑「引擎模式白烧 YOLOPX 算力」，
   实测代码路径（`tick()` 提前 return + `infer` 唯一调用点在 return 之后）
   **证明引擎模式下 YOLOPX 根本不跑**。我**没有**照契约去加 `enabled=false`
   （那会掩盖事实），改为在 `EngineMain.swift` 记录真实行为。

---

## 1. 逐条修复（13 项）

### C1 ✅ `LaneFallback.swift:205` 转向符号反了 —— **安全关键**

- **根因**：`deviation = median - 0.5`，**正 = 车道中心在画面右侧**；
  `steer` 正 = 向右打方向。车偏左时车道中心出现在右侧 → `deviation > 0` → 应**向右**修正。
  但代码写 `-deviation`，**恰好反向** —— 会朝**背离车道中心**的一侧打方向。
  更糟的是紧邻注释写的是「往右修正」，**代码与自己的注释互相矛盾**。
- **修法**：`let raw = deviation * steerGain`（去掉负号），并把符号约定完整写进注释。
- **`AuroraDriveApp.swift:1324` 断言同步修正（契约点名的「同错无法互查」）**：
  原断言 `ck("转向方向正确（线在左→向左修正）", a.steer <= 0, ...)`。
  我**没有**简单改文字，而是改成**双向自洽断言**：同一条线分别放左/右两侧，
  要求两次修正**方向相反且都指向车道中心**，并校验左右幅度对称。
  → **代码与断言不可能再同错**：任何单侧符号改动都会被立刻抓住。
- **实测验证**（`--yolopx-selftest`）：
  ```
  ✓ 车偏右（线在左）→ 向左修正 steer<0  — steer=-0.250
  ✓ 车偏左（线在右）→ 向右修正 steer>0  — steer=+0.250
  ```

### C2 ✅ `throttleCap` 引入 Optional/nil + 结构性保守保证（选方案①）

- **改法**：`let throttleCap: Double?` —— `nil` = **对油门不表态**（调用方保持原值）。
  原用 `1.0` 表示"不改变"，但 `min(cmd.throttle, 1.0)` 恒等于原值，
  「没意见」与「上限恰为 1.0」两种语义被混同，**类型上无法区分**。
- **额外的结构性保证（超出契约要求）**：新增
  `let isIntervening = abs(steer) > 0 || brake > 0`，
  只要兜底**真的在介入**，`throttleCap` 必被压到 `interveningThrottleCap = 0.3` 以下。
  → 「兜底在场 ⇒ 保守」由**赋值**保证，而不是靠调用方记得检查。
- **调用侧**：`applyLaneAdvice` 改为
  ```swift
  if let cap = advice.throttleCap { out.throttle = max(0.0, min(cmd.throttle, cap)) }
  ```
- **实测**：`✓ 兜底介入时满油门被压到 <=0.3（B2）— throttle=0.30`；
  `✓ throttleCap=nil 时不改变油门（0.42 保持）— throttle=0.42`。

### C3 ✅ `isContiguous` 按真实 strides 判定 —— **实测收益 417×**

- **实测事实**（用 App 同款 API 读真实张量）：
  ```
  det  shape=[1,8400,6]      strides=[268800, 32, 1]   dims=3
  da   shape=[1,2,640,640]   strides=[819200,409600,640,1]  dims=4
  ll   同 da
  ```
  **det 是 3 维、行跨度 32（≠6，有对齐填充）**，而旧 `isContiguous` 要求
  `strides.count == 4` → **直接返回 false** ⇒ det 的快速路径**从未生效**，
  每帧退化为 8400×5 次 `readML` 下标访问。
- **修法**：新增 `fastRowsStrided()`：只要求「最内维连续（`strides[last]==1`）+
  行跨度 ≥ cols」，行偏移用 **真实 `strides[1]`**；`capacity` 按
  `(rows-1)*rowStride + cols` 计算以避免越界读。det 调用点切到新函数。
  `isContiguous` 保留给 da/ll（它们实测严格连续）。
- **实测收益（50 次平均）**：
  ```
  下标读 readML : 79.20 ms/次
  快速路径     :  0.19 ms/次      → 约 417×
  正确性：前 200 行 × 6 列 最大绝对差 = 0.0（逐位一致）
  ```
- **诚实说明**：契约预估「163.5→119ms（省 44.5ms）」。实测单次 det 读取省 **~79ms**，
  与预估同量级但更大；**端到端总延迟未由我复测**（属 t25/t37 范围），
  此处只声明"det 读取环节"的确定性收益。

### C4 ✅ 采样带按 `metrics` 动态计算

- **根因**：原硬编码 640 坐标 `y∈[360,600)`，**假设内容铺满整高**。
  但 21:9 这类宽幅输入内容只有 270 高、上方还有 185 灰边 ——
  硬编码区间会整段落在灰边里（读到全 0）或图像之外，
  于是"看不见车道线"时**无法区分是真没有还是取错位置**。
- **修法**：改用**有效内容区**比例：
  `contentTop = padY`、`contentBottom = padY + newH`，
  采样带 = 内容区的**下 1/4 ~ 下 9/10**（常数 `sampleBandTopFrac=0.25` /
  `sampleBandBottomFrac=0.9`）。删除已无用的 `sampleTopY/sampleBottomY`。

### C5 ✅ 引擎模式 YOLOPX 行为 —— **按事实记录，不改代码**

- **契约二选一**：①把 da/ll 网格加进共享内存；②在 `EngineMain` 显式 `enabled=false`。
- **核实结论：②的前提不成立。** 代码事实：
  - `DriveState.tick()` 在 `EngineClient.shared.isActive` 时执行
    `tickEngineMode(); return` —— **提前返回**（`AuroraDriveApp.swift:3172` 附近）；
  - `yolopxEngine.infer(image:)` **全仓库仅 1 处**调用，位于该 return **之后**
    的本地推理分支（`:3260`）→ 引擎模式**永远走不到**。
  ⇒ **引擎模式下 YOLOPX 根本不跑，不存在白烧算力。**
- **修法**：**未改任何逻辑**（加 `enabled=false` 反而会误导后人以为"引擎模式本会跑、
  需要人为关掉"）。改为在 `EngineMain.swift` 头部记录完整事实：
  为什么不跑、da/ll 掩码在引擎模式下为空、`LaneFallback` 因 `isDegraded=true` 不介入
  属既定设计，以及"若将来要在引擎模式显示掩码，须先把 160×160 网格加进共享内存协议"。
- **附带发现**：掩码确实**不在**共享内存协议里 → 选项①若要做是"新增协议字段"级别的工作，
  不是本轮范围。已在注释中标注为**未做**。

### C6 ✅ `stabilityFrames` 时间窗 + 33ms 红线独立上报

- **根因**：帧计数在**变帧率**下 ≠ 固定时长。YOLOPX 实测端到端约 119–163ms（≈6–8Hz），
  而调用方 tick 是 30Hz，且 `infer()` 有"上一帧没跑完就跳过"的防重叠门 ——
  喂进本函数的**不是**每 33ms 一帧，而是每 ~120ms 一帧。
  于是 6 帧 ≈ **0.72s**，比注释写的 0.2s 慢 3.6 倍。
- **修法**：双条件「先到者成立」——`stableEnough = framesOK || timeOK`，
  新增 `stabilityWindowSeconds = 0.2` 与 `stableSince` 时间戳（方向切换时重置，
  `reset()` 清空）。时间窗与帧率无关：推理变快不会让门变松，变慢也不会变严。
- **33ms 红线记录**（契约要求作为**独立未关闭项**上报）：

  | 项 | 值 |
  |---|---|
  | 红线 | 单帧 ≤ 33ms（30fps） |
  | 实测端到端（他方数据） | **163.5ms**（≈4.0× 超支） |
  | 本轮 C3 确定性收益 | det 读取 **−79.2ms**（79.20→0.19） |
  | 修复后**预期** | 约 **84ms**（仍 **2.5× 超支**） |
  | 状态 | 🔴 **红线未达标，未关闭** |

  ⚠️ 「预期 84ms」是**算术推算**（163.5 − 79.2），**不是实测端到端**——
  端到端复测属 t25/t37，本报告不作达标声明。

### C7 ✅ 自检 B1/B3/退出码

- **B1**：原断言已正确（`16:9 上下补灰边 padX==0 && padY>0`），实测 ✓ 通过；
  额外补了「内容高+双灰边=640」分区守恒断言（原已存在，确认有效）。
- **B3（真错）**：原断言 `ck("21:9 左右补灰边", padX>0 && padY==0)` ——
  **与实际几何恰好相反**：21:9 比 1:1 宽，缩到宽 640 后内容只有 270 高，
  灰边出现在**上下**（`padY=185`），`padX` 反而是 0。
  → 改为「以上下补边为主」+「横向铺满」+「纵向分区守恒 640」三条。
  实测：`✓ 21:9 以上下补边为主 — padX=0 padY=185`、`✓ 21:9 纵向分区守恒 640 — 185+270+185`。
- **③ 退出码（真错）**：`runYolopxSelfTest()` 原返回 `Void`，调用处**无条件 `exit(0)`** ——
  自检 FAIL 也返回成功，CI/脚本无法凭退出码发现问题。
  改为 `-> Int`（失败项数）+ `@discardableResult`，
  调用处 `exit(failed == 0 ? 0 : Int32(min(failed, 127)))`。
  实测：全过时 `SELFTEST_EXIT=0`。

### C8 ✅ EMA 实测（按契约要求"实测，不臆断"）

- **逐帧模拟实证**（`maskEMA=0.35` / `threshold=0.5`）：
  ```
  单帧孤立冒起 [1,0,0,0,0,0] → 输出全 0（完全抑制）
  连续2帧      [1,1,0,0,0,0] → [0,1,0,0,0,0]
  交替抖动     [0,1,0,1,0,1] → [0,0,0,0,0,1]（6 帧只放行 1 帧）
  ```
  ⇒ **EMA 确实在抑制抖动，机制保留**（契约给的"若未生效则删除"未触发）。
- **附带改进与自我修正**：初版注释我写成"每帧都有 2 帧冷启动延迟"，
  复核 `accum` 是**跨帧持久成员**（仅 `reset()` 清空）后**修正**为：
  冷启动只发生在**会话首帧 / reset 后那一帧**。仍改为用首帧观测初始化累加器
  （前景=1/背景=0），避免"reset 后头两帧掩码偏空 → 占比偏低 → 误触降级"的边界抖动。

### C9 ✅ `guard enabled else { reset(); return }`

- **根因**：原只 `return` 不清理 —— 停用引擎后 `drivableMask/laneMask/isDegraded`
  仍停留在停用前旧值，决策层此时读到会拿**过期掩码**判断。
- **修法**：与 `reloadModel()`/`reset()` 同一清理语义。已核实 `reset()`
  会清 `drivableMask/laneMask/metrics` 并置 `isDegraded = true`（`:586-597`）。

### C10 ✅ `drawLetterbox` 用 `drawOriginY` + `isInPad` 对称性说明

- **实测澄清**：`drawOriginY ≡ padBottom`（已存在属性）。我按 4 种宽高比实测算出
  `padY == padBottom` 恒成立（16:9→140/140、16:10→120/120、21:9→185/185、方形→0/0），
  **故当前代码没有实际画偏错误**。
- **仍改**：绘制改用 `metrics.drawOriginY` —— 二者数值相同但**语义不同**
  （`padY` 是"顶部灰边（行序口径）"，`drawOriginY` 是"CGContext 左下原点下的内容下边界"）。
  一旦将来非对称 padding，用 `padY` 会画偏。这属**消除隐患**而非修错。
- **`isInPad` 对称性假设**：如实记录在文档注释里（当前假定 top==bottom，实测成立；
  若非对称须改为显式传 padBottom）。

### C11 ✅ 自检 B2 改为断言**等效油门**

- 契约原话：断言兜底介入期间的等效油门 ≥ `applyLaneAdvice(a, to: ControlCommand(steer:0,
  throttle:1.0, ...)).throttle <= 0.3`，使 B2 可被自检捕获。
- **修法**：新增 D2 断言
  ```swift
  let intervene = LaneAdvice(steer: 0.2, brake: 0.4, throttleCap: 0.3, confidence: 1.0, ...)
  let capped = applyLaneAdvice(intervene, to: ControlCommand(steer:0, throttle:1.0, ...))
  ck("兜底介入时满油门被压到 <=0.3（B2）", capped.throttle <= 0.3 + 1e-9, ...)
  ```
  另在 C3 段也加了一条从**真实 evaluate 输出**出发的等效油门断言（双保险）。
- **实测**：`✓ 兜底介入时满油门被压到 <=0.3（B2）— throttle=0.30`。

### C12 ✅ 三开关注释修正（选"修正注释"路径）

- **核实**：`preferYolopxDetections` / `showYolopxMasks` / `YolopxEngine.enabled`
  在全仓库**均无 UI 绑定**（无 Toggle/Binding，仅 3 处读取）——
  只能改代码常量并重编译。
- **修法**：三处注释分别补「⚠️ 运维须知：**无设置面板入口**，改动需改代码常量并重编译；
  若需运行时切换应接入设置面板（**当前未做**）」。
  选注释路径而非接面板：接面板涉及 UI 设计（且用户视觉要求极高），
  超出本任务 in-scope，不宜擅自改 UI。

### C13 ✅ 门② 补掩码同构校验

- **修法**：`laneMask.width == drivableMask.width`（并同步 `height`）。
  两者来自同帧同 letterbox 坐标系，尺寸不一致说明上游给了错配数据，
  此时按任一方几何换算都是错的 → 必须拒绝。

---

## 2. 验证证据

### 2.1 契约 verify 三条命令

```
① swift build -c release 2>&1 | grep -E "\berror: " | grep -v warning | wc -l   → 0
   （构建 Build complete! (310.95s)、EXIT=0）
② find models/yolopx/yolopx3_pal8_detfp.mlmodelc -type f | sort
   → analytics/coremldata.bin, coremldata.bin, metadata.json, model.mil, weights/weight.bin（五件套）
③ find models/yolopx/yolopx3_w8a16.mlmodelc -type f | sort
   → weights/weight.bin（仅一个，确认残缺）
```

### 2.2 `--yolopx-selftest` 实跑

```
42 项断言全过、0 失败；SELFTEST_EXIT=0
关键条目：
  ✓ 车偏右（线在左）→ 向左修正 steer<0  — steer=-0.250      ← C1
  ✓ 车偏左（线在右）→ 向右修正 steer>0  — steer=+0.250      ← C1 双向
  ✓ 21:9 以上下补边为主 — padX=0 padY=185                    ← C7
  ✓ 21:9 纵向分区守恒 640 — 185+270+185                      ← C7
  ✓ 兜底介入时满油门被压到 <=0.3（B2）— throttle=0.30        ← C11
  ✓ throttleCap=nil 时不改变油门（0.42 保持）— throttle=0.42 ← C2
```

### 2.3 C3 性能实证（独立程序，App 同款 API）

```
det shape=[1,8400,6] strides=[268800, 32, 1] dims=3
旧 isContiguous 要求 dims==4 → 直接失败 ⇒ 快速路径从未生效
新 fastRowsStrided vs 下标读：前 200 行×6 列 最大绝对差 = 0.0（逐位一致）
下标读 79.20 ms/次   快速路径 0.19 ms/次   → 约 417×
```

---

## 3. 红线与捷径合规

| 项 | 结果 |
|---|---|
| 禁改 `models/` | ✅ 文件数 **139 → 139** 未变；w8a16 破损保持原样 |
| 禁改 vendored | ✅ `tools/yolopx/` 零改动（实测程序全在 `/tmp/t45/`） |
| 禁删功能 | ✅ 仅重写逻辑与注释，无功能删除 |
| 禁 `as Any` 绕过 | ✅ 四个改动文件 **0 命中** |
| 禁注释掉代码 | ✅ LaneFallback / YolopxEngine **0 命中** |

**改动文件（4 个，全部在 in-scope 内）**：
`LaneFallback.swift`、`YolopxEngine.swift`、`AuroraDriveApp.swift`、`EngineMain.swift`

---

## 4. 诚实局限与未验证

1. **端到端延迟未复测**。C3 的 417× 是**单次 det 读取环节**的确定性收益；
   "163.5→约 84ms"是算术推算，**不是端到端实测**。端到端复测属 t25/t37。
   **33ms 红线目前仍未达标**（见 C6 表），本报告不作达标声明。
2. **C5 未做引擎模式掩码功能**。仅记录事实；若要在引擎模式下显示掩码，
   需新增共享内存协议字段（约 50KB/帧），属独立工作量，**未做**。
3. **C10 属"消除隐患"而非修错**。实测算出当前 4 种宽高比下 `padY == padBottom`，
   因此改前**没有**实际画偏错误。请勿在终审材料写成"修了绘制 bug"。
4. **C12 未接设置面板**。仅修正注释使其不再误导；运行时切换能力**仍不存在**。
5. **C8 冷启动修正的影响面未经真机验证**。仅论证了逻辑（`accum` 持久、
   仅 reset 清空）与模拟行为，未在真机观察"reset 后两帧掩码占比"是否改善。
6. **自检为离线逻辑断言**，不覆盖真实模型的推理数值正确性（属 t24）。
7. **C1 的符号修复未经真机道路验证**。虽然双向断言已在自检中证明方向正确，
   但"实车兜底转向是否符合预期"需实机路测（红线：感知不得裸上实车）。

---

## 5. 复现命令

```bash
cd /Users/dupi/Desktop/自动驾驶系统

# ① 契约 verify
swift build -c release 2>&1 | grep -E "\berror: " | grep -v warning | wc -l
find models/yolopx/yolopx3_pal8_detfp.mlmodelc -type f | sort
find models/yolopx/yolopx3_w8a16.mlmodelc -type f | sort

# ② 自检（42 项断言 + 退出码语义）
./.build/release/AuroraDrive --yolopx-selftest; echo "exit=$?"

# ③ C3 性能与正确性实证
cd /tmp/t45 && swiftc -O perf.swift -o perf && ./perf

# ④ C8 EMA 行为实证
cd /tmp/t45 && swiftc -O ema.swift -o ema && ./ema
```

---

## 6. 本轮实测记录

| 项 | 值 |
|---|---|
| 编译 | `Build complete! (310.95s)`，EXIT=**0**，error=**0** |
| 自检 | **42 ✓ / 0 ✗**，退出码 **0** |
| C3 det 读取 | **79.20ms → 0.19ms（约 417×）**，逐位一致（max diff 0.0） |
| 验收项 | 13/13 处理完毕（12 改代码 + 1 按事实记录） |
| 改动文件 | 4 个（均在 in-scope） |
| `models/` | 139 文件未变 |
| vendored | 零改动 |
| **33ms 红线** | 🔴 **未达标（未关闭项）** |
