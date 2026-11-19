# Codex 代码审查任务书 — 车速表 OCR 低置信度处理 + 短期外推

你是一位严格的资深代码审查员。请审查下面这个改动，找出**逻辑漏洞、边界问题、安全风险、与现有代码风格不一致之处**。只审查、不要改代码（除审查结论外不要产出补丁），最后给出「能否上生产 + 必须修项」的明确判断。

## 一、项目背景

项目：AuroraDrive（macOS 第三方自动驾驶/auto-play 工具，SwiftPM，Swift 6，macOS 26）。
- 双进程架构：UI 进程（SwiftUI，有 runloop）+ engine 进程（`--engine`，dispatchMain，唯一真正注入按键者）。
- `DriveState.tick()` 以约 30Hz 运行，是决策主循环。
- 车速来自「速度表 OCR」：`SpeedOCRReader`（PP-OCRv6 微调整行模型，输入 384×224 原生帧的速度表 ROI）每帧读出 `speedKmh` / `confidence`。

## 二、这次改动要解决的问题

1. **低置信度会产出假车速**：原来 `ppocrMinConfidence = 0.30`。实测「有速度表」帧置信度中位数 0.84，「无速度表」帧（菜单/遮挡/HUD 暂隐）中位数仅 0.36。阈值 0.30 会把 0.33~0.34 这类「模型瞎猜」的读数当有效值，造成假车速。
2. **速度表短暂丢失时假减速**：原来 tick 在 OCR 失效时执行 `effectiveSpeed *= 0.9`（每帧向 0 衰减）。但速度表读不到 ≠ 车停了（可能被遮挡/菜单切换），假减速会让**限速判断、卡死判据**读到错误的速度轨迹。

## 三、改动清单（请逐个文件核对）

### 文件 1（新增）：`Sources/AuroraDrive/Agent/SpeedExtrapolator.swift`
纯逻辑结构体（无 I/O，时间由调用方传入）：
- `init`：对 `sampleWindowSec`/`maxExtrapolationSec`/`maxSpeedKmh` 做「有限且为正」合法化（非法回落默认 2/2/300），`minSamplesForSlope` 归一为 ≥1。
- `recordValid(speed:at:)`：记录有效车速样本；拒绝负值/NaN/Inf 速度、非有限时刻；把 speed clamp 到 maxSpeedKmh 后入样本数组，并按样本时刻裁剪窗口。
- `estimatedSpeed(at:)`：若有最后有效值：非有限查询时刻 → 退化为最后值；`elapsed = max(0, now-lastT)`；超过 `maxExtrapolationSec`（默认 2s）→ 冻结在最后有效值；否则用 `recentSlopeKmhPerSec(at:)` 对**查询时刻前 sampleWindowSec 内**样本做最小二乘斜率，`last + slope*elapsed`，`projected` 非有限则退化为最后值，最后 clamp 到 [0, maxSpeedKmh]。样本不足（<minSamplesForSlope，默认 2）时退化为保持最后值。
- `reset()`：清空样本与最后有效值。
- **注意**：以下 4 个边界缺陷已被边界测试发现并修复，请你确认修复是否正确、有无引入新问题：
  1. 无穷外推窗 + 无穷查询时刻 + 斜率0 曾触发 `0×∞=NaN`（已加 `projected.isFinite` 与查询时刻有限性守卫）；
  2. `maxSpeedKmh=+∞` 曾让 clamp 失效返回 inf（已加 init 合法化）；
  3. 查询时不按窗口裁剪样本、陈旧趋势可跨数十秒外推（已改为 `recentSlopeKmhPerSec(at:)` 按查询时刻裁剪）；
  4. 记录时间乱序会让斜率符号翻转（生产中单调时钟不可达，保留为已知特性；仍保证结果有限且在 [0,maxSpeed]）。
- 完整源码见仓库文件（请务必实际打开阅读，不要只看本摘要）。

### 文件 2：`Sources/AuroraDrive/App/AuroraDriveApp.swift`（DriveState）
- 新增属性 `@ObservationIgnored private var speedExtrapolator = SpeedExtrapolator()`。
- `tick()` 里「有效车速」更新段（搜索 `ocrFresh`）：把原 `effectiveSpeed *= 0.9` 衰减，改成：
  - OCR 新鲜（`speedKmh>=0 && confidence>0.6 && lastResultTime<0.5s`）→ EMA 追读数 + `speedExtrapolator.recordValid(...)`；
  - 否则若有外推值 → `effectiveSpeed = estimated`；
  - 否则保持原样。
- `speedValid` 仍严格等于 `ocrFresh`（低置信/外推期间为 false）。
- 待机分支与 `reset()` 里都调用 `speedExtrapolator.reset()`。

### 文件 3：`Sources/AuroraDrive/Inference/SpeedOCRReader.swift`
- `ppocrMinConfidence` 0.30 → 0.60（含注释、诊断文案同步）。

## 四、设计意图与安全约束（判断是否符合的金标准）

- **安全红线**：`speedValid` 必须严格等于「OCR 本身是否新鲜」。原因：`SpeedLimitGuard.update(...)`（在 `Sources/AuroraDrive/App/ControlWiring.swift`）要求 `guard speedValid, speedKmh >= 0` 才会拿速度去踩刹车。外推值绝不能让限速刹车误动作。
- **界面**：`MissionConsole.swift` 用 `speedValid ? 数值 : "—"`，外推期间应显示「—」。
- 外推值只用于「需要连续车速的非安全用途」，不改变 `speedValid` 语义。

## 五、必须逐条给出结论的审查点（✓无问题 / ⚠️需关注 / ✗有问题，并附文件:行号与理由）

1. **限速刹车安全**：顺藤摸瓜读 `ControlWiring.swift` 的 `SpeedLimitGuard.update`。确认「外推期间 speedValid=false」真的会让限速刹车不动作。有没有任何路径让外推值绕过 speedValid 进入刹车决策？
2. **阈值一致性**：`ocrFresh` 的 0.6 与 `SpeedOCRReader.ppocrMinConfidence` 的 0.6 是否一致？是否存在语义断层——例如 PP-OCR 内部返回了 confidence 但被上游丢弃、或 CNN 备用路径的 confidence 量纲不同导致 0.6 不适用（读 `SpeedOCRReader` 的备用 CNN 分支）。
3. **最小二乘斜率正确性**：`recentSlopeKmhPerSec()` 对时间乱序、同刻样本去重、分母为 0、返回 NaN/Inf 的处理是否完备？`recordValid` 里样本时间可能乱序吗（调用方 tick 用单调时间 tickNow，但要确认）？
4. **作用域与变量**：tick 里速度段用到的 `tickNow` 是否在该段之前已定义且在同一函数作用域（读 tick 开头）？`dt` 可用性？
5. **状态清理**：待机分支、`reset()` 是否都清 `speedExtrapolator`？有没有跨会话/跨驾驶污染（比如停车待机后再次开驾沿用旧样本）？
6. **@ObservationIgnored**：加在 `speedExtrapolator` 上是否合适（它不参与 UI 展示，逐帧变更不应触发 SwiftUI 重绘；但也要确认它不是 @Observable 类型本身导致的问题）。
7. **其它 effectiveSpeed 消费者**：全文搜索 `effectiveSpeed`，逐个判断「不再向 0 衰减」是否改变了安全性。重点：限速刹车、卡死判据（`isDriving && speedValid && effectiveSpeed < 1.0`）、降级状态机 `degradeStm.update(speedKmh:speedValid:)`、辅助模型 `assistEngine.infer(speedKmh:)`、rollover guard `applyRolloverGuard(...speedKmh:speedValid:)`。
8. **内存/资源**：样本数组是否被裁剪（不会无限增长）？1000 帧会不会 OOM？
9. **冻结语义**：超过 2s 后「冻结在最后有效值」——若此时车实际已停/已加速，是否会长期显示/使用一个过期的车速？这在设计上是否可接受（注意 speedValid=false，安全模块不动作，但辅助模型/rollover guard 会吃到这个值——请评估）。
10. **代码风格**：是否符合项目现有风格（注释用中文「为什么」、命名表达意图、无多余抽象）。

## 六、输出要求
- 逐条结论 + 证据（文件:行号 + 关键代码片段引用）。
- 明确列出「必须修（blocker）」「建议修（nice to have）」「可忽略」三类。
- 最后一句总体判断：**能上生产 / 不能上生产**，并在不能时给出最小修改点。

仓库根：`/Users/dupi/Desktop/自动驾驶系统`。请实际打开上述文件阅读（尤其 SpeedExtrapolator.swift 全文、ControlWiring.swift 的 SpeedLimitGuard.update、SpeedOCRReader.swift 的备用 CNN 分支），不要凭空推断。
