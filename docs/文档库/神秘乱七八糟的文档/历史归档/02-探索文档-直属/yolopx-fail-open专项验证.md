# YOLOPX fail-open 安全红线专项验证（R2）

- **验证对象**：`LaneFallback.evaluate` 的 fail-open 门控 + `applyLaneAdvice` 的越权限额
- **验证任务**：t31 / attempt `0db6ca5b-4324-4c8a-8186-83297e97cabb`
- **验证员**：code-quality-auditor（只读；未修改任何生产源码）
- **被测基线**：`LaneFallback.swift` md5 `f22957a0ba08df66833596225a303b99`，mtime `2026-09-26 17:04`（早于 t30 审查，**t45 修复尚未落地**）
- **验证时间**：2026-09-27 01:06 起
- **裁决**：**needs_revision（1 个 blocker、1 个 high）**

---

## 0. 硬结论（先说答案）

### 「fail-open 门控是否可靠？」

**部分可靠 —— 5 类降级输入中 4 类完全可靠，第 3 类（尺寸校验）存在漏口，且漏口会导致崩溃。**

| | 结论 |
|---|---|
| ① `isDegraded=true` | ✅ **完全可靠** —— 所有变体一律返回 nil |
| ② 掩码全空 | ✅ **完全可靠** —— 4 种变体全部 nil |
| ③ 掩码宽度不匹配 | 🔴 **漏口** —— `ll=160/da=80`、`ll=80/da=160`、`ll=320/da=160` **全部给出 `steer=±0.25` 的建议** |
| ④ `validCells=0` | ✅ **可靠**（但见 §5 说明：实测被门② 提前拦下，非门④ 自身作用） |
| ⑤ 有效行数不足 | ✅ **完全可靠** —— 7 种变体全部 nil（含门槛边界恰好 3 行时正确放行） |

**21 例中：✅ 符合预期 18 / 🔴 漏口 3 / ❌ 意外拒绝 0。**

### 「有无任何路径会在输入不可信时给出转向建议？」

**有，两条：**

1. **B1（blocker）**：非预期尺寸的掩码（如 `da` 是 80×80 而 `ll` 是 160×160）**不会被门② 拦截**，`evaluate` 正常给出转向建议。门② 只校验「宽 == 高」（自洽性），**从不与生产常量 `maskGridSize=160` 比较**。
2. **H1（high）**：`MaskGrid.at()` 的边界守卫只覆盖 `x/y`，**不覆盖 `cells` 数组长度**。构造 `cells` 短于 `width*height` 的 `MaskGrid` 会在 `evaluate` 内触发 **SIGTRAP 崩溃**（Swift 数组越界陷阱）。**这是 fail-hard 而非 fail-open** —— 两个调用点均已用独立子进程钉死。**当前生产路径不可达**（`MaskGrid` 仅有的两个构造点都满足不变式），故按「真实可达性」定级为 **high** 而非 blocker；但其不变式**无任何断言保护**，任何未来的掩码构造点（例如从共享内存反序列化）会立刻把它升级为 blocker。详见 §5。

> **诚实定性变更**：t30 报告在 §审查项 4 把「③ 宽度不匹配 → nil」写为 PASS，并称「本次 nil 属巧合」。**该转写不准确，现予更正**：实测取决于具体尺寸组合 —— 当 `da` 与 `ll` 都通过「宽==高」自洽检查时**不会**返回 nil；t30 那例之所以是 nil，是因为我当时用 `full`（160 格）作 `laneMask`（缺失偏差行）而非真正的车道线掩码。本报告 §2.2 用同一实例、同一顺序原样重放，确认得 `nil`，但用真实车道线掩码重跑即得 `steer=+0.25`。**t30 的结论方向正确（门② 缺尺寸互校），严重度由 low 上调为 blocker。**

---

## 1. 验证方法

### 1.1 被验证代码的获取方式（可审计）

从生产源码**逐字抽取**（仅去掉 `private` / `nonisolated` / `@MainActor` 等隔离装饰，**逻辑零改动**）：

| 段 | 来源 |
|---|---|
| `MaskGrid` | `YolopxEngine.swift:44-64` |
| `LetterboxMetrics` | `YolopxEngine.swift:74-136` |
| `extractMask` / `isContiguous` / `fastRows` / `readML` | `YolopxEngine.swift:703-839` |
| `parseDetections` / `iouXYXY` | `YolopxEngine.swift:602-695` |
| **`LaneFallback` 全文** | `LaneFallback.swift:26-273` |
| `ControlCommand` | `EscapeController.swift:28-44` |
| **`applyLaneAdvice` + `adviceSteerLimit`** | `AuroraDriveApp.swift:3829-3849` |

**抽取一致性自检**：11 条关键行（`guard !isDegraded else {`、`let deviation = median - 0.5`、`var throttleCap = 1.0`、
`let delta = max(-adviceSteerLimit, min(adviceSteerLimit, weighted))` 等）**逐字命中生产源码 11/11，缺失 0**。

> 这是**行为复刻**而非插桩生产二进制。凡涉及「代码会不会崩」「输出什么值」的结论均来自**真实执行编译后的 Swift 代码**（非 Python 模拟、非阅读推断）。局限见 §7。

### 1.2 崩溃隔离

所有可能崩溃的用例**每个独立进程**运行，由父 shell 捕获退出码：

- `EXIT=133` → `SIGTRAP`（Swift 数组越界 / 断言陷阱）
- `EXIT=134` → `SIGABRT`，`EXIT=139` → `SIGSEGV`

---

## 2. 正向验证：5 类降级输入逐类实测

### 2.1 总表（21 例）

| 类别 | 用例 | 期望 | 实测 | 判定 |
|---|---|---|---|---|
| ①降级位 | `isDegraded=true`（掩码合法） | nil | nil | ✅ |
| ①降级位 | `isDegraded=true` + 空掩码 | nil | nil | ✅ |
| ②掩码空 | `.empty` / `.empty` | nil | nil | ✅ |
| ②掩码空 | 结构合法但全零 | nil | nil | ✅ |
| ②掩码空 | 仅 `ll` 空 | nil | nil | ✅ |
| ②掩码空 | 仅 `da` 空 | nil | nil | ✅ |
| **③尺寸** | **`ll=160`/`da=80`** | nil | **`steer=+0.2500`** | 🔴 **漏口** |
| **③尺寸** | **`ll=80`/`da=160`** | nil | **`steer=+0.2500`** | 🔴 **漏口** |
| **③尺寸** | **`ll=320`/`da=160`** | nil | **`steer=+0.2500`** | 🔴 **漏口** |
| ③尺寸 | `ll=160×80`（宽高不等） | nil | nil | ✅ |
| ③尺寸 | `metrics = .zero` | nil | nil | ✅ |
| ④validCells | `padX/Y=700` 越界 | nil | nil | ✅ |
| ④validCells | `newW=0` | nil | nil | ✅ |
| ⑤行数 | 全零 `ll`（0 行） | nil | nil | ✅ |
| ⑤行数 | 1 行有值 | nil | nil | ✅ |
| ⑤行数 | 2 行有值 | nil | nil | ✅ |
| ⑤行数 | 前景仅 1 格 | nil | nil | ✅ |
| ⑤行数 | 前景在采样带上方 | nil | nil | ✅ |
| ⑤行数 | 前景在采样带下方 | nil | nil | ✅ |
| 对照组 | 合法车道线（**须给建议**） | 给建议 | `steer=+0.2500` | ✅ |
| 对照组 | 恰好 3 行（门槛边界） | 给建议 | `steer=+0.0000` | ✅ |

**✅ 符合预期 18 / 🔴 漏口 3 / ❌ 意外拒绝 0**

> 对照组的存在是为了**证明测试装置有效** —— 不是「恒返回 nil」的假绿。恰好 3 行（`rowCenters.count >= 3` 的边界）正确放行，2 行正确拒绝，门槛行为精确。

### 2.2 第 3 类漏口的精确界定

`LaneFallback.swift:122-124` 的门② 实际内容是：

```swift
guard laneMask.width > 0, drivableMask.width > 0,
      laneMask.width == laneMask.height,        // ← 只校验"自洽"
      drivableMask.width == drivableMask.height,
      metrics.newW > 0, metrics.newH > 0 else {
```

**它检查的是「每个掩码自己是不是正方形」，从来不检查「两个掩码是不是同一个尺寸」，也从不与生产常量 `YolopxEngine.maskGridSize`（=160，`YolopxEngine.swift:152-153`）比较。**

按 `ll` 宽度扫描（`da` 恒为合法 160）：

| `ll` 宽度 | 是否预期值 | 实测 |
|---|---|---|
| 40 | ≠ | `steer=+0.2500` ← 门② 未拦 |
| 80 | ≠ | `steer=+0.2500` ← 门② 未拦 |
| **160** | **=** | `steer=+0.2500` |
| 320 | ≠ | `steer=+0.2500` ← 门② 未拦 |
| 640 | ≠ | `steer=+0.2500` ← 门② 未拦 |

**根因**：`evaluate` 用 `laneMask.width` 归一化偏差（`:131,155`），却用 `drivableMask.width` 在 `ratio()` 里算 valid 区（`:257`）。两者尺寸不一致时，**两套坐标静默混用**，输出的是一个「用 A 的尺子量、用 B 的尺子判」的数。

### 2.3 t30 用例的原样重放（诚实自纠）

按 t30 报告 §审查项 4 的**同一 `LaneFallback` 实例、同一调用顺序**原样重放：

```
nil  ① isDegraded=true
nil  ② 掩码为空
nil  ②b 仅 ll 空
给了建议 steer=0.0  ③ 宽度不匹配(ll=160,da=80)      ← t30 记为 nil，实为 steer=0.0
nil  ③b 宽高不等(ll=160×80)
nil  ③c metrics 无效(newW=0)
nil  ④ 行数不足(全零 ll)
nil  ④b 仅 2 行有前景
```

**结果与 t30 报告的转写不符**：t30 把该例记为 `✅ nil`，实际是 **`给了建议 steer=0.0`**（我的父 shell 只 `print` 了「是否 nil」的分支标签，报告转写时误记）。

**为什么 t30 那例是 `steer=0.0` 而非 `+0.25`**：t30 用例把 `laneMask` 传成了 `full`（160×160 全前景，缺失偏差行）—— 全前景的行中心恒为 0.5，`deviation≈0`，故输出 `steer=0.0`。**换成真实车道线掩码（同样 160 格）即得 `steer=+0.25`**（见 §2.2 的扫描）。

**更正后的结论**：t30 指出的「门② 缺尺寸互校」**方向正确**，但严重度定级偏低（记为 low），且「本次 nil 属巧合」的描述不准确 —— 事实是**根本没返回 nil**。本报告上调为 **blocker**。

---

## 3. 反向验证：看似合理但实际不可信

| # | 输入构造 | 实测 | 判定 |
|---|---|---|---|
| B1 | 全屏都是车道线（cells 全 1，前景 100%） | `steer=+0.0000`，未拒绝 | 🔴 **采纳** |
| B1b | 全屏车道线 + 全屏可行驶区 | `steer=+0.0000`，未拒绝 | 🔴 **采纳** |
| B2 | 掩码只有 1 行有值 | `nil` | ✅ 拒绝 |
| B3a | `metrics.ratio = NaN` | `steer=+0.2500` | ⚠️ 采纳（`ratio` 未被 `evaluate` 使用，见下） |
| B3b | `metrics.padX = Int.max/2` | `nil` | ✅ 拒绝 |
| B3c | `metrics.newW = Int.max/2` | `steer=+0.2500` | ⚠️ 采纳 |
| B4a | 坐标全在图像外（`padX=1000`） | `nil` | ✅ 拒绝 |
| B4b | 2560×1080 真实比例 | `steer=+0.2500` | ✅ 采纳（正确行为） |
| B5 | 车道线在画面**左侧** | `steer=+0.2500` | 🔴 **方向反转**（见下） |
| B5b | 车道线在画面**右侧** | `steer=-0.2500` | 🔴 **方向反转** |
| B6 | 可行驶区极少 | `steer=+0.2500 brake=0.60 cap=0.00 conf=0.50` | ✅ 刹车+压油门正确 |

### 3.1 「全屏都是车道线」为何是**门控盲区**

全前景 → 每行中心恒 0.5 → `deviation≈0` → 输出 `steer=0.0`。**看起来是安全的（居中），但语义上它是「对 100% 垃圾输入给出了一个合法建议」**，且 `confidence=1.00`（满置信）。

更危险的是**部分退化**：

| 构造 | 前景占比 | 实测输出 |
|---|---|---|
| 全前景但左侧空 20% | 80% | `steer=-0.2500`（**饱和**） |
| 全前景但右侧空 20% | 80% | `steer=+0.2500`（**饱和**） |
| 仅采样带内全前景 | 37.5% | `steer=+0.0000` |
| 前景占比 90%（稀疏洞） | 90% | `steer=+0.0000` |

**真实的 lane 头有效占比是 1.3%~3.9%**（145 张真实行车图实测，t30 报告 §2 审查项 3）。而 `YolopxEngine` 的降级判定**只有下限没有上限**：

```swift
nonisolated static let lanePositiveFloor = 0.002   // 0.2% —— 只有下限
...
isDegraded = (laneRatio < Self.lanePositiveFloor) || (drivableRatio < Self.drivablePositiveFloor)
```

**前景占比扫描（决定性证据）**：

| 构造前景占比 | 相对真实分布 | `evaluate` 输出 |
|---|---|---|
| 1.70% | 正常 | `steer=+0.2500` |
| 3.16% | 正常上限 | `steer=+0.2500` |
| 5.83% | 1.5× | `steer=+0.2500` |
| 11.67% | 3× | `steer=+0.2500` ← 仍被采纳 |
| 19.44% | 5× | `steer=+0.2500` ← 仍被采纳 |
| **27.22%** | **7×** | `steer=+0.2500` ← **仍被采纳** |
| **38.89%** | **10×** | `steer=+0.0000` ← **仍被采纳（满置信）** |

→ **从一个 1.3% 前景的正常掩码，到 38.89% 前景的完全塌陷掩码，`isDegraded` 全程为 false，`LaneFallback` 全程给建议且 `confidence` 可达 1.00。** 「大面积前景」是 seg 头失效最典型的形态之一（与 int8 塌陷方向相反，但同样不可信）。

### 3.2 噪声掩码：恒定噪声被完整采纳

模拟「持续性误检」（同一帧掩码连喂 12 帧）：

| 噪声密度 | 单帧给建议 | 非零转向 | 最大 \|steer\| |
|---|---|---|---|
| 1‰ | — | 28/40 | **0.2500（饱和）** |
| 3‰ | — | 27/40 | **0.2500（饱和）** |
| 5‰ | — | 14/40 | **0.2500（饱和）** |

对照「逐帧新噪声」（每帧重新随机）在 40 帧连续喂入下**非零转向 0 帧** —— 因为门③ 突变丢弃（`maxDeviationJump=0.15`）把跳变挡掉了。

**结论**：`LaneFallback` **无法区分「结构化车道线」与「恒定噪声」** —— 它只用「有多少行有前景」和「行中心的均值」，不看形状。真实车道线给 `±0.25`，恒定噪声也给 `±0.25`。突变门只能挡住**变化快**的噪声，挡不住**稳定存在的**误检。

### 3.3 NaN / Inf 在原始张量层（已由 `extractMask` 正确消化）

| 原始 logits 构造（真实 dtype `float16`） | 前景格 | 送入 `LaneFallback` |
|---|---|---|
| `ch0=ch1=1.0` | 0/25600 | `nil`（拒绝） |
| `ch0=1.0, ch1=0.0` | 0/25600 | `nil`（拒绝） |
| `ch0=0.0, ch1=1.0` | **25600/25600** | ⚠️ 给建议 `steer=+0.0000` |
| `ch0=NaN, ch1=1.0` | 0/25600 | `nil`（拒绝） |
| `ch0=1.0, ch1=NaN` | 0/25600 | `nil`（拒绝） |
| `ch0=+Inf, ch1=-Inf` | 0/25600 | `nil`（拒绝） |
| `ch0=+Inf, ch1=+Inf` | 0/25600 | `nil`（拒绝） |

**✅ NaN/Inf 全部被正确消化为「无前景」→ 进而被门④/⑤ 拒绝。`Int(NaN)` 类崩溃风险不存在于本路径。**

### 3.4 ⚠️ 附带发现：`float32` 张量会被静默读错

`extractMask` 对 `dataPointer` 做了**两次无条件绑定**，靠 `if let` 顺序保证正确：

```swift
let f16 = contiguous ? arr.dataPointer.bindMemory(to: Float16.self, capacity: total) : nil
let f32 = contiguous ? arr.dataPointer.bindMemory(to: Float32.self, capacity: total) : nil
...
if let f16 { a = Float(f16[i0]); b = Float(f16[i1]) }   // ← 先命中，不看 dtype
else if let f32 { ... }
```

实测**同一张 float32 张量**（语义 `ch0=0, ch1=1` = 全前景）：

| dtype | 前景格 |
|---|---|
| `float16`（生产 dtype） | **25600/25600（正确）** |
| `float32` | **0/25600（读错 → 被判为全背景）** |

当前模型输出是 `float16`（t30 已实测 `65552`），故**生产路径正确**。但这属于「靠 dtype 巧合」的无断言保护路径 —— 换任何 fp32 输出的导出形态即静默失效。定级 **medium**（非本次 fail-open 专项的 blocker）。

---

## 4. 越权验证：`applyLaneAdvice`

### 4.1 定向用例（7 例）

构造**故意超限**的极端 advice（`steer=±1.0`、`throttleCap=1.0`、`brake=0.0`）：

| # | 场景 | 输入 → 输出 | 单帧 \|Δsteer\| | 油门只压 | 刹车只加 | 判定 |
|---|---|---|---|---|---|---|
| C1 | `steer=+1.0` | `base(+0.00,thr 0,brk 1.0)` → `(+0.2500, 0.00, 1.00)` | 0.2500 | ✓ | ✓ | ✅ |
| C1b | `steer=-1.0` | `base(+0.00,thr 0,brk 1.0)` → `(-0.2500, 0.00, 1.00)` | 0.2500 | ✓ | ✓ | ✅ |
| C2 | 满油门下叠加 | `base(+0.00,thr **1.0**,brk 0)` → `(+0.2500, **1.00**, 0.00)` | 0.2500 | ✓ | ✓ | ✅ |
| C2b | 满油门 + `-1` 满舵 | `base(+0.00,thr **1.0**,brk 0)` → `(-0.2500, **1.00**, 0.00)` | 0.2500 | ✓ | ✓ | ✅ |
| C3 | 已满右舵 1.0 + 左修 | `base(+1.00,thr 0,brk 1.0)` → `(+0.7500, 0.00, 1.00)` | 0.2500 | ✓ | ✓ | ✅ |
| C4 | `brake=0`（想松刹车） | `base(+0.00,thr 0,brk **0.9**)` → `(+0.2500, 0.00, **0.90**)` | 0.2500 | ✓ | ✓ | ✅ |
| C5 | 已负舵 −1.0 + 右修 | `base(-1.00,thr 0,brk 1.0)` → `(-0.7500, 0.00, 1.00)` | 0.2500 | ✓ | ✓ | ✅ |
| C6 | `confidence=0` | 全字段**零变化** | 0 | ✓ | ✓ | ✅ |
| C7 | 满舵+满油门+满刹 + 极端 advice | `(1.0000, 1.00, 1.00)` 全在 `[0,1]` | — | ✓ | ✓ | ✅ |

**C 类失败数 = 0**

### 4.2 模糊测试（20000 组）

对 `advice` 注入**故意超限**的随机值（`steer ∈ [-2,2]`、`brake ∈ [-0.5,1]`、`throttleCap ∈ [0,1.5]`、`confidence ∈ [-0.25,1.25]`），`base` 全字段随机化：

```
违反次数 = 0
max|Δsteer|   = 0.250000   （限 0.25）
min(Δthrottle) = -0.991091  （须 ≥ 0：只压不抬）
min(Δbrake)    =  0.000000  （须 ≥ 0：只加不减）
max|out.steer| = 1.000000   （须 ≤ 1）
```

**判定：✅ 三条硬规则在 20000 组模糊下零违反。**

> **但必须分清「限额」与「充分性」**：`applyLaneAdvice` 的**数学不变量完美**（限幅、加权、min/max 语义在 20k 模糊下零违反）。然而它**无法弥补上游缺陷** —— 见 §5。特别是 C2/C2b 暴露的：兜底在 `throttleCap=1.0`（默认值）时**对油门零作用**，满油门原样穿透，兜底只贡献了一次转向。

---

## 5. 🔴 Blocker / 🟠 High

### B1 — 非预期尺寸掩码不被拦截，静默产出转向建议（🔴 blocker）

**文件:行**：`Sources/AuroraDrive/Inference/LaneFallback.swift:122-124`（门②）

**根因**：门② 只检查 `laneMask.width == laneMask.height`（自洽性），
**从不检查** `laneMask.width == drivableMask.width`，
**也从不检查** `laneMask.width == YolopxEngine.maskGridSize`（生产常量 160）。

**实测**：`ll=40/80/160/320/640` × `da=160` **全部给出 `steer=+0.2500`**（`ll=160/da=80`、`ll=80/da=160`、`ll=320/da=160` 同样）。

**危害链**：`evaluate` 用 `laneMask.width` 归一化偏差（`:131,155`），却用 `drivableMask.width` 在 `ratio()` 里算 valid 区（`:257`）。**两套坐标静默混用** → 输出的转向基于一个既非 A 也非 B 的坐标系。这正是 fail-open 红线要防的「基于垃圾输入给转向建议」。

**为什么是 blocker 而非 high**：`LaneFallback` 的**唯一契约**就是「输入不可信 ⇒ 返回 nil」。尺寸不匹配是最典型的「输入不可信」，而它给出的是一份**看起来完全合法**（`steer=±0.25`、`confidence=1.00`）的建议，下游无从识别。

**修复建议**：
```swift
guard laneMask.width == drivableMask.width,
      laneMask.width == YolopxEngine.maskGridSize,
      laneMask.height == drivableMask.height else { reset(); return nil }
```

---

### H1 — `MaskGrid.at()` 不守卫 `cells` 长度，畸形掩码导致 SIGTRAP（fail-hard）（🟠 high）

**文件:行**：`Sources/AuroraDrive/Inference/YolopxEngine.swift:50-54`（`at` 的守卫范围），
崩溃调用点：`LaneFallback.swift:149`（偏差循环）与 `LaneFallback.swift:268`（`ratio()` 循环）

```swift
@inline(__always)
func at(_ x: Int, _ y: Int) -> Bool {
    guard x >= 0, x < width, y >= 0, y < height else { return false }  // ← 只守卫 x/y
    return cells[y * width + x] != 0                                    // ← 不守卫 cells.count
}
```

**实测（崩溃隔离，每例独立进程）**：

| # | 构造 | 结果 |
|---|---|---|
| D1 | `MaskGrid(width:160,height:160,cells.count:100)` | `EXIT=133` **SIGTRAP**，frame 0 进入 `evaluate` 即死 |
| D3 | `MaskGrid(width:160,height:160,cells:[])` | `EXIT=133` **SIGTRAP** |
| D6 | `MaskGrid(width:100000,height:100000,cells.count:10)` | `EXIT=133` **SIGTRAP** |
| D7 | `da` 畸形（`ll` 合法） | `EXIT=133` **SIGTRAP** |
| D2 | `cells` 过长（40000） | `EXIT=0` 正常（只会读前 25600，多余部分无影响） |
| D4 | `width=0` | `EXIT=0` 正常（门② 拦下） |
| D5 | `height=0` | `EXIT=0` 正常（门② 拦下） |

**调用点钉死**（二分逼近）：
- `cells = 160×95`，前景行 90..149 → `at(30,94)` 安全、`at(30,95)` **SIGTRAP** ⇒ 崩在 **`LaneFallback.swift:149`** 的 `laneMask.at(x, y)`（偏差循环）
- `ll` 合法但 `da.cells` 只够到 `y=40`（valid 区从 `y=35` 起）→ **SIGTRAP** ⇒ 崩在 **`LaneFallback.swift:268`** 的 `grid.at(x, y)`（`ratio()` 循环）
- 对照：`da.cells` 覆盖到 valid 区（126 行）→ 正常返回建议，不崩

**危害链**：`MaskGrid` 是 `struct`，其构造器**不校验** `cells.count == width*height`（合成的 memberwise init + `static let empty = MaskGrid(width:0,height:0,cells:[])` 是全部构造路径）。任何让 `width/height` 与 `cells` 脱钩的路径都会**在 `LaneFallback` 内崩溃**。

**为什么是 high 而非 blocker（定级依据）**：
- **按潜在危害**，它够 blocker 标准：`evaluate` 运行在**主线程 tick 内**（`AuroraDriveApp.swift:3401`），SIGTRAP 是**进程级死亡** —— 整个驾驶进程连同按键注入一起消失，方向盘停在崩溃瞬间的状态（已按下的键可能不会释放）。且它是 **fail-hard 而非 fail-open**，与本次专项要验证的安全属性**直接对立**。
- **但按真实可达性**，它是 high：生产路径下 `MaskGrid` 只有两个构造点 —— `extractMask`（`cells = [UInt8](repeating: 0, count: grid*grid)`，`grid` 来自常量 160）与 `smoothMask`（`count = n = grid.cells.count`，宽高沿用输入）。**两条路径都满足不变式**（已 grep 全仓确认），故崩落在当前生产代码中**不可达**。本报告不把「当前不可达的潜在崩溃」列为 blocker。
- **但必须限期处置**：① 该不变式**没有任何断言或注释保护**，是隐式契约；② `MaskGrid` 是 `internal` 且成员可自由构造；③ R1 报告 H3 已建议「把 160×160 掩码网格加入共享内存协议」以修复引擎模式的空掩码问题 —— **那个修复会立刻引入反序列化构造点，从而激活本崩溃**。因此本条与 H3 互为约束，须同步处理。

**修复建议**：任选其一或并用 ——
```swift
// ① 让 at() 自我保护（最小改动，同时消除所有调用点的同类风险）
guard x >= 0, x < width, y >= 0, y < height, cells.count >= width * height else { return false }
// ② 给 MaskGrid 加不变式校验的构造器（init 内 precondition / 或返回 optional）
```
> **建议优先 ①** —— 它是 fail-open（越界返回 `false` = 背景），与红线语义一致；② 的 `precondition` 仍是 fail-hard。

---

## 6. 非 blocker 但需记录

| ID | 级别 | 位置 | 问题 | 实测证据 |
|---|---|---|---|---|
| **M1** | medium | `YolopxEngine.swift:50-54` | `MaskGrid.at()` 只守卫 x/y 不守卫 `cells.count`（H1 的根因，独立记录以便分别跟踪） | 同 H1 |
| **M2** | medium | `YolopxEngine.swift:718-719,741` | `extractMask` 把 `dataPointer` **无条件双绑定** f16/f32，靠 `if let` 顺序 + dtype 巧合保证正确。实测：同一 float32 张量（语义全前景）被读成 **0/25600 前景（全错）**；float16 正确 | 见 §3.4 |
| **M3** | medium | `YolopxEngine.swift:178,574` | 降级判定**只有下限无上限**：`laneRatio < 0.002`。前景占比从 1.70% 涨到 **38.89%** 全程 `isDegraded=false`，`LaneFallback` 全程给建议且 `confidence` 可达 **1.00** | 见 §3.1 扫描表 |
| **M4** | medium | `LaneFallback.swift:146-158` | 只按「有多少行有前景」+ 行中心均值判方向，**不看形状**。恒定噪声（5‰）与真实车道线同样给到 `steer=±0.25`（饱和），`confidence` 同样可达 1.00 | 见 §3.2 |
| **M5** | low | `LaneFallback.swift:136-137` | 采样带（`sampleTopY=360/sampleBottomY=600`）**不按 valid 区域裁剪**：2560×1080 时仅 39% 落在画面内，其余落在 letterbox 灰边 | 见 R1 报告 H2 |
| **M6** | low | `LaneFallback.swift:171-174` | 突变帧返回 `nil` 时**不更新 `lastDeviation`**，但也**不更新稳定计数** —— 连续突变会无限期保持在旧方向。本次实测逐帧噪声因此被完全挡住（行为正确），但语义上是「沉默」而非「拒绝」 | 见 §3.2 |

---

## 7. 诚实局限

1. **复刻而非插桩**：被验证的 `LaneFallback` / `applyLaneAdvice` 是从生产源码**逐字抽取后独立编译**的副本（仅去隔离装饰）。已做 11/11 关键行逐字一致性自检，但严格说不是链接生产符号的同一份二进制。
2. **未真机驾驶**：所有输入均为构造数据，**未在真实游戏画面 + 真实推理输出下跑过完整驾驶循环**。§3.1 的「前景占比扫描」用的是几何构造掩码，真实 seg 头塌陷时的形态（是否有结构、是否连续）**未采样**。
3. **未覆盖 `isDegraded` 的真实触发路径**：本报告验证的是 `evaluate` 在给定 `isDegraded` 值下的行为。`isDegraded` 本身的判定质量（M3）由 `YolopxEngine.finish` 决定，其真实性已在 R1 报告 §审查项 3 独立覆盖。
4. **性能与并发未验**：未验证 `evaluate` 在 30Hz 主线程下的耗时（R1 报告实测主线程新增约 1ms，不构成问题），未验证与推理队列的并发访问。
5. **崩溃可达性判断基于静态构造点分析**：H1 判为「当前不可达」依据是 `MaskGrid` 仅有两个构造点且均满足不变式（grep 全仓确认）。若存在动态构造路径未被我扫到，可达性结论需修正。
6. **`t45` 修复尚未落地**：被测基线 `LaneFallback.swift` md5 `f22957a0ba08df66833596225a303b99` / mtime `17:04`，早于本任务开始。若修复已并行进行，**请在修复后重新对本报告用例复跑**。

---

## 8. 复现命令

```sh
cd /tmp/t30-audit

# ① 生成逐字抽取的测试基线（含 11/11 关键行一致性自检）
#    prod_core.swift ← LaneFallback.swift:26-273 / YolopxEngine.swift:44-64,74-136,602-695,703-839,843-889
#                      / RuleController.swift:29-70 / EscapeController.swift:28-44 / AuroraDriveApp.swift:3829-3849

# ② 总表（21 例：5 类降级 + 对照组）
swiftc -O prod_core.swift r2_n.swift -o nn && ./nn

# ③ 崩溃隔离（每例独立进程，父 shell 捕获 133=SIGTRAP）
swiftc -O prod_core.swift r2_d.swift -o dd
for i in 0 1 2 3 4 5 6; do ./dd $i 1; echo "case $i EXIT=$?"; done

# ④ 崩溃调用点二分钉死
swiftc -O prod_core.swift r2_m.swift -o m
./m trap      # → EXIT=133，钉死在 LaneFallback.swift:149
./m ratio     # → EXIT=133，钉死在 LaneFallback.swift:268
./m ratio2    # → EXIT=0（对照：cells 够用则不崩）
./m coverage  # → 前景占比盲区扫描表

# ⑤ 越权定向 + 模糊（20000 组）
swiftc -O prod_core.swift r2_k.swift -o k && ./k

# ⑥ 原始张量层 NaN/Inf + dtype 隐患
swiftc -O prod_core.swift r2_f.swift -o f && ./f

# ⑦ 噪声蒙卡 / 突变门 / 尺寸扫描
swiftc -O prod_core.swift r2_h.swift -o h && ./h
swiftc -O prod_core.swift r2_i.swift -o i && ./i
swiftc -O prod_core.swift r2_g.swift -o g && ./g
```

---

## 9. 只读合规声明

- **未修改任何生产源码**（`Sources/**`、`Package.swift`、`models/**`、`tools/yolopx/**` 零改动）。
- 唯一写入 = 本报告 + `/tmp/t30-audit/` 下的测试用例与逐字抽取基线（未污染仓库；`tools/yolopx` 为独立 git 仓库，全程未写入）。
- `/tmp/t30-audit/prod_core.swift` 为生产源码的逐字副本，仅去 `private`/`nonisolated`/`@MainActor` 隔离装饰，**逻辑零改动**，附 11/11 关键行一致性自检。
