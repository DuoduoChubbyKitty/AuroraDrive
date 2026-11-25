# 代码-38 PerfSelfTest 性能自检与测量总线

> ✅ **本文件已去行号化（2026-11-25）**：行号会随源码漂移，一律改为**符号名定位**；
> 每个名字都能在 `Sources/AuroraDrive/App/PerfSelfTest.swift` 里 grep 到。
> 历史复核记录里的旧行号数字（如「26 条锚点命中」）属**历史结论存档**，不代表当前坐标。

> 覆盖源文件：`Sources/AuroraDrive/App/PerfSelfTest.swift`
> 该文件**已在 git 跟踪中**（`git ls-files` 可查到）。
> 关联：[`性能实测-2026-09-30-卡顿与定位.md`](性能实测-2026-09-30-卡顿与定位.md)（测量结果记录处）、
> [`代码-37-EgoMotionModel自车运动径向模型.md`](代码-37-EgoMotionModel自车运动径向模型.md)

> **★ 关键结论（方法学，务必先读）**：`--perf-selftest` / `--tick-profile` 的 `RunLoop.current.run(until:)`
> 与 `--tick-bench` 的 `budget` 都把节拍**刻意固定为 `1.0 / 30.0`**，这不是 20Hz 迁移漏改：
> 自检验证的是「推理异步回写能否完成」（主线程用 `Thread.sleep` 会卡住 `DispatchQueue.main.async`
> 回写 → `isInferencing` 永真 → 后续提交全被防重叠门挡掉）；`--tick-bench` 则需要固定节拍否则
> p50/p99 会随生产频率漂移、跨版本不可比。详见 §三 与「三处固定节拍」小节。

---

## 一、为什么先建这个（文件头 `【为什么先建这个】` 段）

> 项目文档里记录过 **12 项"想当然的优化"实测全被否决**（改 vImage 反而让检测框 9→6、
> 预分配 tempBuffer 反而慢 20%、两级降采样慢 25%…）。
> 教训是：**性能不能凭直觉改，必须先有基线、再 ABBA 对比**。
> 本文件只做「测量」，不做任何优化 —— 它是后续所有改动的**裁判**。

> ⚠️ 注意：**"12 项"实际是 13 项**，见性能文档 §6.46.1。

## 二、测什么（文件头 `【测什么（对应七条红线）】` 段）

| 红线 | 指标 |
|---|---|
| **R1** | 各模型实际出结果频率 (Hz) ← **任何优化都不许让它降** |
| **R2** | 检测框数量 ← 精度红线 |
| **R3** | 掩码精度（可行驶 / 车道线占比） |
| **R4** | 速度表 OCR 频率 |
| **R5** | 小地图定位刷新（用定位样本计数近似；UI 刷新需人工观察） |

另测：tick 循环耗时 p50/p95/p99、引擎 CPU%、主线程阻塞。

## 三、★ 方法学（文件头 `【方法学】ABBA 交替` 段）

1. **ABBA 交替** —— 单次测量会被系统噪声污染（文档里满是"ABBA 各 12 轮"的做法）
2. **输出 p50/p95/p99 而非平均值** —— 因为卡顿是**长尾**问题，平均值会把它抹平
3. **不改生产逻辑** —— 只在现有调用点外围包计时

### 三处刻意固定的 30Hz 测试基线（★ 不是漏改）

| 位置（符号） | 用途 | 为什么必须固定 30Hz |
|---|---|---|
| `runPerfSelfTest(seconds:)` 采样循环里的 `RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30.0))` | `--perf-selftest` 每轮推理后的主线程让出节拍 | 自检验证的是**推理异步回写能否完成**（该循环上方注释：主线程若 sleep 会卡住 `DispatchQueue.main.async` 回写 → `isInferencing` 永真 → 后续提交全被防重叠门挡掉）。**只需「给回写留够时间」，与生产 tick 频率无关** |
| `runTickProfile(seconds:)` 里的同款 `RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30.0))` | `--tick-profile` 同款 RunLoop 让出节拍 | 同上 |
| `runTickBench(seconds:)` 里的 `let budget = 1.0 / 30.0`（配合 `RunLoop.current.run(until: Date().addingTimeInterval(budget - spent))`） | `--tick-bench` 的**每帧预算**，用于补齐到固定 33.3ms 再进下一帧 | **基准测试必须固定节拍**，否则测出的 p50/p99 会随生产频率漂移，跨版本不可比 |

> **结论**：这三处是**测量方法学的固定基线**，跟随 20Hz 反而会让历史基线数据（§九 的 2026-10-02 实测表）失去可比性。**文档 §九 的历史数据也基于 30Hz 节拍**。⚠️ 后续若有人要改成 20Hz，必须同时重测并作废旧基线——否则是「用新尺子量旧数据」。

## 四、用法

```bash
AURORA_UI_LOCAL=1 ./AuroraDrive --perf-selftest              # 空载基线
AURORA_UI_LOCAL=1 ./AuroraDrive --perf-selftest --seconds 20
AURORA_PERF_ROUNDS=12 ./AuroraDrive --perf-selftest          # 指定采样轮数
AURORA_PERF=1 ./AuroraDrive --auto-drive                     # 生产路径打点
```

### 重要边界（文件头 `【重要边界】` 段）
- 本自检**不启动驾驶**，只测量各子系统在其真实触发路径上的耗时
- **需要游戏在跑才能测到"满载"数字**；空载数字用于回归对比同样有效（只要前后两次环境一致）
- 所有测量**不改动生产逻辑**：只在现有调用点外围包计时

## 五、组件（用符号名定位，不含行号）

| 组件 | 职责 |
|---|---|
| `struct PerfStats` | 一组采样值的分位数统计（不引入第三方依赖） |
| `PerfStats.percentile(_:)`（另有 `median` / `p95` / `p99` / `maxValue` / `mean` / `summary` 便捷属性） | 取分位数 |
| `final class PerfRateMeter`（`tick(_:)` / `reset()` / `hz()`；`hz()` 是**方法**不是属性，样本不足（<3）时返回 nil） | 频率计 |
| `final class PerfBus`（`static let shared`） | **全局测量总线（单例）** |
| `PerfBus.record(_:ms:)` | 记一条采样 |
| `PerfBus.measure(_:_:)` | 包住一段代码测量 |
| `PerfBus.stats(_:)` | 取某通道统计 |
| `PerfBus.stamp()` | **取当前时刻（开启计时）** |
| `PerfBus.mark(_:from:)` | 打一个点（结算上一段） |
| `PerfBus.lap(_:from:)` | 打点并返回 |
| `PerfBus.allChannels()` | 全部通道名 |
| `PerfBus.reset()` | 清空（采样窗口后调用，避免启动预热污染） |
| `enum PerfCPU` | CPU 采样 |
| `PerfCPU.processCPUPercent()` | 进程 CPU% |
| `PerfCPU.cpuBetween(_:_:seconds:)` | 区间 CPU% |
| `runPerfSelfTest(seconds:)` | **自检主入口**（`--perf-selftest`） |
| `enum PerfSelfTestImage`（`sharedGrayBuffer` / `make(w:h:)` / `makeGray(w:h:)`） | 测试图生成 |
| `runTickProfile(seconds:)` | `--tick-profile` 入口 |
| `runTickBench(seconds:)` | `--tick-bench` 入口 |

`PerfBus` 另按子系统暴露独立频率计：`tickRate` / `yolopxRate` / `m9Rate` / `assistRate` / `yolo26Rate` / `ocrRate` / `locateRate` / `captureRate`。

## 六、★ 开关：`AURORA_PERF`

```swift
static var enabled: Bool =
    ProcessInfo.processInfo.environment["AURORA_PERF"] == "1"
```

**零开销如何保证**（`PerfBus.enabled` 的文档注释 + `record` 上方「零开销如何保证」注释段）：
`enabled == false` 时所有 `record` 都是**空操作**，
因此**可以安全地把它留在生产代码里**。

## 七、★ 一个必须记住的测量陷阱：`n=1` 会被懒加载骗

`runPerfSelfTest` 的地图先验查询段自己记录了两次踩坑（`RoadCornerGuide.shared.cornerAhead` 预热段注释）：

| 陷阱 | 表现 |
|---|---|
| **`n=1` 撞懒加载** | `cornerAhead` 首测 **31.4 ms**；预热后 p50 **0.000–0.003 ms** —— **差 10000 倍** |
| **`Thread.sleep` 阻塞写回** | 测出来的数**不是产品行为**（`RunLoop.current.run(until:)` 上方注释要求主线程转 RunLoop；`runTickBench` 里同样注明「不用 `Thread.sleep` —— 那会把 tick 一起睡死」） |

**对策**：**必须先跑一次预热探针**（该段注释即「先预热：触发懒加载 + 首次查询（不计量）」），再开始正式采样。

## 八、★ 另一个必须记住的盲区：`PerfBus` 是**进程内**的

> `PerfBus` 是**进程内**单例，从外部另起进程读不到样本
> （实测 `--tick-profile` 独立跑确实**全 0**）。

**对策**：把分段数据**写进日志**，用零新机制的方式在真实负载下取数。
- **UI 侧导出**：`AuroraDriveApp.swift` 的 `if PerfBus.enabled, didLogThisSecond {` 分支——与上方 `[EGO-DIAG]` 摘要共用同一个 1Hz 闸门 `didLogThisSecond`；内含 14 通道数组 `let seg = [...]`（`tick.consumeFrame` … `tick.total`）、`dlog("[PERF] tick分段(p50/p95 ms): " + parts.joined(separator: " "))`，随后 `PerfBus.shared.reset()`。
- **引擎侧导出**：`Core/EngineMain.swift` 的心跳统计块内，`if heartbeatCount % 15 == 0 {` 分支尾部 `if PerfBus.enabled {` —— 同一份 14 通道 `let seg`、`engineLog("[PERF] tick分段(p50/p95 ms): " + parts.joined(separator: " "))`，随后 `PerfBus.shared.reset()`。

> 🔧 **两侧段清单逐项完全相同**（14 个通道名一字不差）：`tick.consumeFrame` / `yoloFast` / `opticalflow` / `nativeROI` / `motion` / `speed` / `degrade` / `confidence` / `ruleDecision` / `laneFallback` / `inject` / `record` / `debugSummary` / `total`。
> 全仓 `PerfBus` 通道名另含 `submit.assist` / `submit.yolopx` / `map.isOnRoad` / `map.nearestRoad` / `map.cornerAhead` / `map.junctionAhead` / `cache.*` / `dlog.write` / `dlog.flush` / `infer.assist` / `infer.yolopx` / `opticalflow` / `tick.loop` 等。
> ⚠️ 两条导出路径的**位置会随文件增长漂移**，请按 `PerfBus.enabled` + `didLogThisSecond` / `heartbeatCount % 15 == 0` 搜索，不要按旧行号跳转。

## 九、实测结果（2026-10-02，`AURORA_PERF=1 --perf-selftest --seconds 10`）

**PASS**。对比性能文档 §6.42.4 基线：

| 指标 | 文档 §6.42.4 | 2026-10-02 实测 |
|---|---|---|
| tick 提交次数 | 241（24.0 Hz） | **265（26.5 Hz）** |
| `submit.yolopx` p50/p95/p99/max | 0.125 / 0.200 / 0.380 / 0.538 | **0.004 / 0.026 / 0.029 / 0.033** |
| `submit.m9` p50 | 0.003 | 0.003 |
| `opticalflow` p50/p95/max | 1.959 / 2.700 / 3.356 | 1.887 / 2.574 / **3.569** |
| `tick.loop` p50/p95/max | 2.064 / 2.890 / 3.555 | 1.927 / 2.626 / **3.666** |
| **R1 yolopx 频率** | 12.00 Hz（120 次） | **13.27 Hz（推理计数=121）** ✅ |
| **R1 m9/assist/yolo26s** | 24.00 Hz | **26.47 Hz（265 次）** ✅ |
| R2 检测框 | 9 个 | **0 个**（纯色测试图，正常） |
| R3 可行驶 / 车道线 | 26.19% / 8.042% | **0.00% / 0.000%**（同上） |
| 引擎 CPU | 61.1% → 66.5% | **64.2%** |
| 加载耗时 | yolopx 155 / yolo26s 35 / M9 397 / assist 260 ms | yolopx **91** / yolo26s **36** / M9 **23** / assist **19** ms |
| **索引对拍** | 91 命中 0 不一致 | **91 命中 0 不一致 ✓** |
| 一帧地图查询合计 | p50 0.004 ms | **p50 0.004 ms** |

**⚠️ R2/R3 为 0 属正常**：自检用的是**纯色测试图**，不是真实游戏帧（自检输出里已注记）。
**⚠️ 空载 ≠ 真机**：本表是空载数据；真机曾观测到推理频率塌陷到 2.4–3.0 Hz（见性能文档 §6.46.3）。

## 十、其它命令行入口

| 入口 | 分发函数 |
|---|---|
| `--perf-selftest` | `runPerfSelfTest(seconds:)` |
| `--tick-profile` | `runTickProfile(seconds:)`（⚠️ 独立跑**全 0**，见 §八） |
| `--tick-bench` | `runTickBench(seconds:)`（主动驱动真实 `tick()`，离屏可重复） |
| `--motion-selftest` | 见 `代码-37`（`EgoMotionModel` 侧断言） |

---

## 附：符号定位表（替代旧「行号锚点表」）

| 符号 / 单元 | 定位方式 |
|---|---|
| `struct PerfStats` | grep `struct PerfStats` |
| `PerfStats.percentile(_:)`（及 `median` / `p95` / `p99`） | grep `func percentile` |
| `final class PerfRateMeter` | grep `final class PerfRateMeter` |
| `PerfRateMeter.tick` / `reset` / `hz` | grep `func tick` / `func reset` / `func hz`（`hz` 是**方法**不是属性） |
| `final class PerfBus` | grep `final class PerfBus` |
| `PerfBus.enabled` | grep `static var enabled`（注释见 `enabled` 的 `///` 块） |
| `record` / `measure` / `stats` | grep `func record` / `func measure` / `func stats` |
| `stamp` / `mark` / `lap` | grep `static func stamp` / `static func mark` / `static func lap` |
| `allChannels` / `reset` | grep `func allChannels` / `func reset` |
| `enum PerfCPU` | grep `enum PerfCPU` |
| `processCPUPercent` / `cpuBetween` | grep 同名 |
| `runPerfSelfTest` | grep `func runPerfSelfTest` |
| `enum PerfSelfTestImage` | grep `enum PerfSelfTestImage` |
| `sharedGrayBuffer` / `make` / `makeGray` | grep 同名（`make(w:h:)` / `makeGray(w:h:)`） |
| `runTickProfile` | grep `func runTickProfile` |
| `runTickBench` | grep `func runTickBench` |
| `n=1` 懒加载陷阱注释 | grep `懒加载的一次性成本`（地图先验查询段） |
| 预热对策注释 | grep `必须先跑一次预热探针` / `先预热` |
| 文件头「为什么先建这个」 | `PerfSelfTest.swift` 顶部方框注释 `【为什么先建这个】` |
| 文件头「测什么」 | 同上方框 `【测什么（对应七条红线）】` |
| 文件头「方法学」 | 同上方框 `【方法学】ABBA 交替` |
| 文件头「重要边界」 | 同上方框 `【重要边界】` |

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。
**2026-10-18 曾做过一轮行号重基准**（当时据 984/992 行版源码逐条 `sed -n` 复验）；
**2026-11-25 去行号化**：全部行号数字移除，改为符号名定位——源码已增长到近千行且仍在变动，行号必然漂移，符号名才是稳定锚点。
