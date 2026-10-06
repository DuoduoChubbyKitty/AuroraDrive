# YOLOPX · W1 Swift 编译修复报告（任务 t20）

> 契约：`swift build -c release` 退出码 0、零 `error:`（warning 不计）、不通过删功能/注释代码/改 `Any` 绕过。
> 实测时间：2026-09-26 22:30–22:40（GMT+8）。执行：swift-fixer（attempt 1）。

---

## 0. 结论

**通过。** `swift build -c release` 退出码 **0**，非 warning 的 `error:` 行数 **0**；
独立 scratch 目录下**全量干净重建 191.06s** 同样 EXIT=0、零 error。
三处已知编译错误源已全部消解（2 处为既有改动、1 处为白名单登记），本轮**无需新增代码修改**。

⚠️ 一个必须写在前面的定性：**Swift 树在我接手时已经是可编译的**。
本任务的实际贡献是 ① 用「干净重建」排除增量缓存假绿；② 逐条复核三处错误源的真实状态；
③ 对「未删功能/未注释/未改 Any」取证。**我没有为了「修点什么」而改动任何源文件。**

---

## 1. 验证方法（为何不能只跑一次增量构建）

第一次 `swift build -c release` 只输出 `Build complete! (1.15s)`、`[0/3]` 作业 —— 这是**空转**，
什么都没重编。仅凭它判绿是**缓存假绿**，不满足「零疑虑」标准。因此追加三项独立取证：

| 取证 | 命令 | 结果 |
|---|---|---|
| 缓存新鲜度 | `find Sources Vendor/MetalGoose -name '*.swift' -newer .build/release/AuroraDrive` | **空** —— 全部源码早于产物 |
| 产物 vs 源码时间 | `stat` 关键文件 | 产物 `22:11:23` 晚于最新源码 `AuroraDriveApp.swift 21:37:14` |
| **全量干净重建** | `swift build -c release --scratch-path /tmp/yolopx-t20-scratch` | **EXIT=0**，`Build complete! (191.06s)`，零 error |

干净重建用 `whole-module-optimization` 把主 target **41 个白名单文件一次性整体编译**
（日志中 `[9/11] Compiling AuroraDrive AIAgentPanel.swift` 为整模块作业，其后无逐文件 Compiling 行）——
这是「全部文件都过了编译」的强证据，且**不触碰用户的 `.build/`**（红线 4）。

日志量对照：干净重建 241 行日志 / 47 条 warning；工作区增量构建零 error。

---

## 2. 修复逐条清单（文件:行 + 根因 + 修法）

### 2.1 已知错误源 ①：`Self.applyLaneAdvice` —— 类型无该成员【已消解】

- **文件:行**：`Sources/AuroraDrive/App/AuroraDriveApp.swift:3408`
- **根因**：`applyLaneAdvice` 是**文件级全局函数**（同文件 `:3829` 定义），不是 `DriveState` 的成员。
  在实例方法里写 `Self.applyLaneAdvice(...)`，Swift 会去类型命名空间找静态成员 →
  报 `type 'Self' has no member 'applyLaneAdvice'`。
- **修法**：去掉 `Self.` 前缀，直接调用全局函数；并就地留下注释说明原因，防止后人再写回去。
  ```swift
  // applyLaneAdvice 是文件级全局函数（同文件 ~3827 行），不是 DriveState 的成员，
  // 因此不能带 Self. 前缀（带前缀会报 "type 'Self' has no member 'applyLaneAdvice'"）。
  currentCommand = applyLaneAdvice(advice, to: currentCommand)
  ```
- **复核证据**：`grep -rn "Self\.applyLaneAdvice" Sources/ Vendor/` → **0 命中**；
  同文件另有 2 处调用（`:1354`、`:1367`）本就是这个正确写法。

### 2.2 已知错误源 ②：`runFitSelfTest()` 重复定义 —— 已消解【确认为纯搬移，零功能损失】

- **文件:行**：`Sources/AuroraDrive/App/AuroraDriveApp.swift:1177`（现存唯一一份）
- **根因**：工作区改动在新增 `runYolopxSelfTest()`（`:1222`）时，把原 `runFitSelfTest()` 整体**上移**，
  形成「旧位置 + 新位置各一份」的重叠 → 重复定义。
- **修法**：删除重叠的那一份，功能**逐字保留**在 `:1177`。
- **「不是删功能」的取证**（这是本节关键，不能只凭眼看）：
  ```
  HEAD 版本      : func runFitSelfTest() 在第 1295 行
  工作区版本     : func runFitSelfTest() 在第 1177 行   ← diff 中作为 + 行出现（新增位置）
  diff 中出现的 - 行：是旧位置那一份
  awk 取 HEAD 1295–1327 函数体  vs  sed 取工作区 1177–1209 函数体  → diff 结果 IDENTICAL
  ```
  函数体逐字相同 → **纯搬移，无一行功能被丢弃**。两版（HEAD / 工作区）各都只有 **1 处**定义，无残留重复。

### 2.3 已知错误源 ③：`Package.swift` 显式白名单漏登记 —— 新文件必须登记

- **文件:行**：`Package.swift:119`（LaneFallback.swift）、`Package.swift:122`（YolopxEngine.swift）
- **根因**：本项目 `executableTarget` 用**显式文件白名单**（`sources:` 数组）而非目录扫描。
  新文件不进 `sources:` 就等于不存在 → 使用处报 `cannot find 'X' in scope`
  （作战手册 §6 记载：曾因此一次产生 **66 个假错误**，极易误判为「工程烂了」）。
- **修法**：把两个新文件按字母序正确插入白名单：
  ```swift
  "Sources/AuroraDrive/Inference/LaneFallback.swift",   // :119，插在 InferenceEngine.swift 后
  "Sources/AuroraDrive/Inference/YolopxEngine.swift",   // :122，插在 YoloEngine.swift 后
  ```
- **复核证据**：白名单 `sources:` 数组当前 **41 个 .swift**，与干净重建整模块作业覆盖的文件集一致；
  两个新文件均在册。

### 2.4 连带改动（同一批 W1 接线，供审查对齐）

| 文件:行 | 内容 | 性质 |
|---|---|---|
| `AuroraDriveApp.swift:820` | `oneShotFlags` 增加 `--yolopx-selftest` | 新增（避免自检进程与常驻 UI 抢锁） |
| `AuroraDriveApp.swift:822-823` | `--yolopx-selftest` → `runYolopxSelfTest(); exit(0)` | 新增 |
| `AuroraDriveApp.swift:1882-1885` | `effectiveDetections` 增加 YOLOPX 优先 + 自动回落 yolo26s | **改写**（原一行三元表达式拆开，行为向上兼容） |
| `AuroraDriveApp.swift:2743` | `yolopxEngine.loadIfNeeded()` | 新增 |
| `AuroraDriveApp.swift:~2745` | 模型加载日志增加 `YOLOPX=` 字段 | 改写（原行内容保留） |
| `MissionConsole.swift:589` | `MaskOverlay(...)` 掩码叠加绘制 | 新增 |

---

## 3. 「未走捷径」取证（契约硬性项）

| 禁止项 | 检查命令 | 结果 |
|---|---|---|
| 把类型改成 `Any` 绕过 | `git diff -- Sources/ Package.swift \| grep "^+" \| grep "as Any\|as? Any\|AnyObject"` | **空**（没有任何 Any 化） |
| 注释掉代码蒙混 | `git diff -- Sources/ \| grep "^+" \| grep -E "^\+\s*//\s*(let\|var\|func\|if\|for\|guard\|return\|self\.)"` | **空**（没有新注释掉的代码） |
| 删除功能 | 逐条审查 diff 全部 `-` 行 | 见下 |

**diff 全部删除行（3 类，均已解释，无一为功能删除）**：

1. `"--limit-selftest", "--nic-autotest", "--proto-selftest"]` → 同一行拆分后**追加** `--yolopx-selftest`，原三元素全保留。
2. `func runFitSelfTest() { ... }` 整段 → **纯搬移**至 `:1177`，函数体逐字相同（§2.2 已取证）。
3. `EngineClient.shared.isActive ? remoteDetections : yoloEngine.detections` → 拆为 `let base = ...` 后**追加** YOLOPX 回落分支，原逻辑原样保留为 `return base`。

结论：**全部删除行都是「同一行被拆分/上移后追加新内容」，无任何功能被删除、注释或降级**。
`git diff --stat` 汇总：`3 files changed, 425 insertions(+), 41 deletions(-)` —— 净增 384 行。

---

## 4. 编译无关、但已确认的真实缺陷（**不在 t20 范围，移交 t23**）

> 之所以写进本报告：这是作战手册点名的**行为 bug**，且 t20 与它同在 `YoloEngine.swift` 的归属范围内，
> 极易被「顺手改掉」从而**绕过 t23 的数据标定**。我明确**没有**动它 —— 改阈值是需要真实框数分布支撑的独立工作。

- **文件:行**：`Sources/AuroraDrive/Inference/YoloEngine.swift:60` — `var maxDetections: Int = 20`
- **与编译的关系**：**无关**。它是运行期取框上限，改成任何 Int 都照样过编译。
- **真实影响**：本地 YoloEngine 路径下，一帧最多产出 20 个框，而路况判定阈值是
  `AutoRoadCondition.extremeThreshold = 70` / `busy = 50` / `medium = 30`
  （`ControlWiring.swift:423-433`）→ **「中等(>30) / 繁忙(>50) / 极度复杂(>70)」三档永远无法触发**，
  自动限速实际上只有「简单/轻松」两档在工作。
- **注意**：`AuroraDriveApp.swift:1378` 的自检断言 `probe.maxDetections > AutoRoadCondition.extremeThreshold`
  用的探针是 **`YolopxEngine()`（上限 300，`YolopxEngine.swift:167`）** ——
  所以该断言对 `YoloEngine` 的 20 **不构成任何保护**，这正是 bug 长期藏身的原因。
- **结论**：`YoloEngine.maxDetections = 20` 相对路况阈值体系是**真实缺陷**，需按 t23 用真实行车图实测框数分布来标定，**不宜拍脑袋改**。

---

## 5. 遗留观察（warning 级，不阻塞）

1. **2 条 unhandled files warning**（根目录未声明为资源也未排除）：
   `default.metallib`、`YOLO家族三合一模型清单_2026-09-26.html`。
   `default.metallib` 疑似 Metal 着色库产物，若运行期按路径加载需确认其仍在原地（本任务未动）。建议纳入 t29 白名单/排除清单核对。
2. 干净重建共 **47 条 warning**，与手册「约 250 条」不符 —— 原因是整模块编译只输出首屏摘要；
   含 `error:` 字样的 warning 是本项目判错的主要误判源，故本报告全部统计均加了 `grep -v warning`。

---

## 6. 复现命令（照抄即可）

```bash
cd /Users/dupi/Desktop/自动驾驶系统

# ① 契约 verify 命令（期望 0）
swift build -c release 2>&1 | grep -E "\berror: " | grep -v warning | wc -l

# ② 退出码（期望 0）
swift build -c release > /tmp/b.log 2>&1; echo "exit=$?"; grep -cE "\berror: " /tmp/b.log

# ③ 排除缓存假绿：全量干净重建（6–10 分钟，不污染用户 .build）
swift build -c release --scratch-path /tmp/yolopx-t20-scratch; echo "exit=$?"

# ④ 三条错误源回归防护
grep -rn "Self\.applyLaneAdvice" Sources/ Vendor/            # 期望 0 命中
grep -c "^func runFitSelfTest()" Sources/AuroraDrive/App/AuroraDriveApp.swift   # 期望 1
grep -c "runYolopxSelfTest()" Sources/AuroraDrive/App/AuroraDriveApp.swift      # 期望 >=2（定义+调用）
```

---

## 7. 本轮实测记录

| 项 | 值 |
|---|---|
| 工作区增量构建 | `Build complete! (1.15s)`，EXIT=**0**，error=**0** |
| 全量干净重建（scratch） | `Build complete! (191.06s)`，EXIT=**0**，error=**0** |
| 契约 verify 命令 | `SWIFT_BUILD_EXIT=0`，输出 **0** |
| 改动文件数（本轮） | **1**（仅本报告；未改任何源码，因无需改动） |
| 编译覆盖 | 主 target 白名单 41 文件，整模块作业一次性通过 |

**「未验证」声明**：本报告只覆盖**编译层面**。Swift 侧功能行为（掩码叠加正确性、
YOLOPX 回落是否真的在运行期生效、`applyLaneAdvice` 限幅数值）**未**在本任务验证，属后续任务范围。
