# 代码-19 AgentLoop 复合任务规划
> 🔄 2026-10-16 复核：正文 `AuroraDriveApp.swift:NNNN` 已按当前 9088 行版重测（effectiveDetections=4233-4234）；`EgoBoxFilter.swift` 118 行不变。
>
> ✅ **2026-10-18 复核（agent-reader）**：逐条 `read` + `grep -n` 核实 AgentLoop.swift（657 行不变）。本次修订：
> - **新增**：`onProgress`（:136）是**死接线**——`AIAgentPanel.swift:1524` 赋值，但 `handle` 内部 11 处 `progress(...)` 调用全用**闭包参数**，从不读 `onProgress` 属性（§一末尾补注）。
> - **新增**：`RuleController.fuse(detections:e2e:)`（:182-199）**全仓零调用**（§4.1 表补注）——`grep -rn "fuse(" Sources/` 只命中定义行，无消费点。
> - **修正 4 处 `AuroraDriveApp.swift` 行号漂移**（文件已 9094 行）：`effectiveDetections` 消费点 :4233-4234 → **:4235-4236**；FallbackGuard 消费者删除块 :6726-6737 → **:6729-6740**；施加点删除块 :7691-7716 → **:7697-7719**。
> - **确认无误**：`maxDuration = 120`（:212）原文档已正确（旧版曾写 60s，本版已修）；657 行已正确；18 技能 / 15 true / 3 false 已正确。
>
> 覆盖源文件：`Sources/AuroraDrive/Agent/AgentLoop.swift`（**657 行**，2026-10-07 `wc -l` 实测）。
> ♻️ **行号已按 9097 行版重基准（2026-10-18）**：源码冻结后对全部 **11 条** `X.swift:N` 逐条 `sed -n` 比语义 + `grep -n` 定真值。**11 条行号全部命中、零漂移**（`AgentLoop.swift` 657 行未变；`AIAgentPanel.swift` 的 68 / 90-128 / 96 / 98 / 110 / 112 / 114 / 263 / 1500 / 1524 / 1529-1538，以及 `AuroraDriveApp.swift:4235-4236`、`AgentLoop.swift:144-146` / `:385` 均正确）。
> 但**发现并修正 1 处语义错误**（非行号问题）：原文称 `:385` 文案里 5 个技能「早已是 `ported: true`」——实际 `rhythm`（`:112`）是 `ported: false`，只有其余 4 个已移植。详见 §三「文案口径」条。
> 🔁 **2026-10-07 由文档核对代理 E4 按当前源码重写**：本文旧版描述的是 **325 行**版本（2026-10-06 A5 复核稿），
> 现源文件已增至 **657 行**——本次改造为 **W7「规划/执行复用新传输层与工具注册表」**：
> `RealLLMPlanner` 不再自带 HTTP、不再调 `AgentSkillCenter.callLLM`，改走 **`LLMTransport`(W2) + `ToolRegistry`(W4)**，
> 可用模型来自 **`LLMHealthMonitor`(W3) 候选链**。弱模型防线 4/5/6/7/8/10 **逐条保留**（源码 :31-38 明文要求"不许删"）。
> 全文按当前源码重写（2026-10-07 E4 初版 + **2026-10-17 T7 逐条 `grep -n` 复测**）；行号全部为实测值。
>
> ⚠️ **技能清单勘误**：旧文写「18 个技能、其中 17 个 `ported:true`」**有误**。实测（AIAgentPanel.swift:90-128）：
> 18 个技能里**只有 15 个显式 `ported: true`**，唯一显式 `ported: false` 的是 `preset_realtime`（:124）；
> 另有 **`pinkpaw`（:104）与 `rhythm`（:112）未写 `ported`** —— `AgentSkill` 的 `ported` 默认值是
> **`false`**（AIAgentPanel.swift:68「默认值防止漏标」），故这两个也是**未移植**，实际可用 **15 个**。

## 一、架构与协议类型（第 1–106 行）

**定位（4–38 行头注释）**：原生 Tool-Calling 端到端任务循环（**零框架**，用户点名的设计）——用户一句话 → LLM 把任务拆成一系列工具调用（tool_use）→ AgentLoop 经 `ToolRegistry` 统一分发执行 → 结果回传 LLM → LLM 继续规划直到任务完成。

**W7 三条核心设计（:12-22）：**

1. **规划与执行复用新传输层与工具注册表**（:13-18）：模型调用 → `LLMTransport`（W2）；可用模型 → `LLMHealthMonitor`（W3，候选链 + 实时记账，**最多轮换 4 个**）；工具清单 → `ToolRegistry.shared.specs()`（W4）；工具执行 → `ToolRegistry.shared.invoke(name:args:dryRun:)`（W4）。**旧路径 `AgentSkillCenter.callLLM` 不再被本文件用于规划**（W6 面板过渡期可继续用）
2. **与 AgentSkillCenter 解耦**（:19-20）：AgentLoop 只做「调度」，技能执行走统一执行通道，**并按工具名区分技能类 / 键鼠文本类 / 观察搜索类工具**
3. **MockLLM（内置模拟调度器）**（:21-22）：**无可用候选时**也能端到端自测，验证「指令→规划→执行→回传→完成」整条链路

**调用链（:24-29）：**

```
AgentSkillCenter.sendUserMessage("帮我登录然后领奖励")
  └─ 关键词直配失败 → AgentLoop.shared.handle(task, from: .ai)
       └─ 候选链（W3）→ RealLLMPlanner（LLMTransport）→ [AgentToolCall]
            └─ ToolRegistry.invoke → 结果回传
                 └─ LLM.finalize(...) → 总结 → 完成
```

**协议类型（第 52–106 行）：**

| 类型 | 字段 / 方法 | 说明 |
|---|---|---|
| `AgentToolCall`（Codable，:52-84） | `id: String` / `skillID: String` / `args: [String: String]` | 一次工具调用。**`skillID` 语义在 W7 后放宽为「工具名」**（:46-51）：技能类为 `skill__rewards`（`skillPrefix = "skill__"`，:58）；键鼠/文本/观察/搜索类为 `press_key`/`mouse_click`/`web_search` 等（`nonSkillTools` 冻结清单，:61-67：press_key、hold_key、release_key、release_all_keys、type_text、mouse_move、mouse_click、mouse_scroll、screenshot、get_status、web_search、web_fetch）；**MockLLMPlanner 仍产出裸技能 id**（`rewards`）。两个派生属性：`registryToolName`（:71-75，补前缀归一化）、`bareSkillID`（:78-83，非技能工具返回 nil，供查中文名与三重校验） |
| `AgentToolResult`（Codable，:87-94） | `id / skillID / ok: Bool / summary: String` + **`postedEvents: Int?`（:93，W4 `ToolResult.postedEvents`，A2/A3 证据字段）** | 工具执行结果 |
| `AgentPlanner`（protocol，:99-106） | `plan(task:) async -> [AgentToolCall]` / `nextStep(task:history:) async -> AgentToolCall?` / `finalize(task:history:) async -> String` | 规划器协议——三个方法对应规划循环的三个阶段 |

**`AgentLoop` 主循环（final class，:111-344）**——端到端任务循环（**单例** `static let shared`（:113），`private init()`（:138））：

| 成员 | 说明 |
|---|---|
| `var planner: AgentPlanner?`（:116） | 当前规划器：**nil = 未配置（走 MockLLM 离线自测）** |
| `llmFailureStreak: Int`（private，:120） | **弱模型防线 8：熔断降级状态（连续 LLM 任务失败计数）**——由 handle 内部按"任务成败"维护；handle 有 isRunning 互斥，无并发写（:118-119） |
| `aiPlanningEnabled`（private(set)，默认 true，:121） | 是否处于降级中 |
| `resetLLMDowngrade()`（:124-127） | **手动恢复 AI 规划**（面板"AI 规划"开关/CLI 调用此方法）：连败清零 + 恢复 true |
| `isRunning`（private(set)，:130） | 是否正在运行任务 |
| `maxSteps = 8`（private let，:133） | **最多连续工具调用步数（防模型死循环）** |
| `onProgress: ((String) -> Void)?`（:136） | 执行过程中的进度回调（UI 显示用）。⚠️ **死接线**：`AIAgentPanel.swift:1524` 赋值 `loop.onProgress = { … }`，但 `handle` 内部 11 处 `progress(...)` 调用全用**闭包参数**（`progress: @escaping (String) -> Void`，:143），从不读 `onProgress` 属性 → 该属性赋值后**从未被调用**。保留但不影响功能（UI 进度靠闭包参数 :1533 的 `DispatchQueue.main.async` 驱动）。 |

## 二、handle() 主循环与弱模型防线（第 140–287 行）

**`handle(task:from:progress:) async -> String`（:142-287）**——处理一个任务：规划 → 循环执行 → 总结，返回最终总结文本。

**入口与规划器选择（:144-177）：**

1. `guard !isRunning else { return "⚠️ 已有任务在运行，请等待完成或先停止。" }`（:144，互斥）→ `isRunning = true`（:145）+ `defer { isRunning = false }`（:146）
2. **候选链（W7，:148-156）**：`let settings = AgentSkillCenter.shared.aiSettings`（:148）；仅当 `aiPlanningEnabled && settings.currentBackendUsable`（:154）才 `candidates = await LLMHealthMonitor.shared.candidates(requireTools: true)`（:155）。**调用前先取候选链，候选为空不是任务失败**（:151-152 注释）
3. **规划器选择（:158-173）**：降级中（`!aiPlanningEnabled`）→ 有 key 或候选时 progress 提示"⚠️ [LLM] AI 规划处于降级状态：本次使用本地规则规划（MockLLM，零幻觉）"（:163）→ `MockLLMPlanner()`（:165）；候选为空 → 提示"降级链无可用候选（渠道全挂或未配置，非任务失败）"（:167）→ `MockLLMPlanner()`（:168）；否则 `let tools = await ToolRegistry.shared.specs()`（:170）→ `RealLLMPlanner(settings:candidates:tools:)`（:171）+ `usedRealLLM = true`（:172）
4. `var calls = await planner.plan(task: task)`（:177）——空则直接 `finalize` 返回总结（:196-199，**并带上渠道回退说明**）

**降级链感知（W7，:179-194）**：`if let real = planner as? RealLLMPlanner, real.channelExhausted`（:186）→ **候选全部失败才回退 MockLLM**，置 `usedRealLLM = false`（:187）+ 组 `channelFallbackNote`（:189-190）+ progress 如实说明（:192）+ **重跑 `planner.plan`**（:193）。关键：**这种情况不计入防线 8 的"任务连败"**（:181-182）——"否则一次渠道抽风会把用户永久打进本地模式"。

**循环执行（:201-266）——防线参数表：**

| 防线 | 参数（行号） | 语义 |
|---|---|---|
| 4 单步化（:201-205） | `calls.count > 1 → [calls[0]]` | **模型一次返回多个调用时只执行第一个（防发散/重复/顺序错乱）** |
| 5 单技能封顶（:229-236） | `callCounts[key] > 3 → 跳过`（key = `call.registryToolName`） | **同一技能调用次数封顶（防弱模型反复调用同一技能）** |
| 6 总时长熔断（:212、:220-224） | `maxDuration = 120` 秒 | 超时强制终止（"已执行 N 步"） |
| 6 连续失败熔断（:213、:245-255） | `maxFailedSteps = 2` | 连续 2 步失败 → `aborted = true` 终止任务 |
| 7 上下文裁剪（:260-265、:331-337） | `trimmedHistory` | **只喂最近 3 步（每条 summary 截断 120 字符），防弱模型丢指令 + 省 token** |
| 10 可观测（:239-242） | 失败必打日志 | **被拒绝/失败的调用必须打 progress 日志（否则用户看不到"模型越界"）** |

**执行循环细节（:207-266）**：`while steps < maxSteps`（:218）→ 总时长熔断（:221-224）→ `steps += 1`（:225）→ 逐个执行（防线 5/10/6，:228-256）→ `if aborted { break }`（:257）→ **`planner.nextStep(task:task, history: trimmedHistory(history))`**（:261）——让 LLM 看结果决定下一步（无 → `calls = []`，:264）。

**`execute(call:) -> AgentToolResult`（private，:294-327）**——执行一次工具调用（**W7 起走 `ToolRegistry.shared.invoke`**，与聊天路径、CLI 自检共用同一入口，:291-292）：

**技能类工具保留原三重校验（:298-312，`if let bare = call.bareSkillID` 才做）：**

| 校验 | 失败摘要 |
|---|---|
| 存在（`AgentSkillLibrary.all.first(id == bare)`，:300） | "未知技能「X」（模型幻觉，已丢弃）"（:302） |
| 已移植（`skill.ported`，:304） | "技能「X」尚未移植（模型越界，已拒绝）"（:306） |
| 未在运行（`!center.runningSkills.contains(bare)`，:308） | "技能「X」已在运行（重复调用，已跳过）"（:310） |

- 非技能工具（键鼠/文本/观察/搜索）**跳过三重校验**，直接进注册表（护栏在注册表内：辅助功能权限 / 游戏窗口 / OBSERVE_ONLY / dryRun，:314-315）
- 统一调用：`await ToolRegistry.shared.invoke(name: toolName, args: call.args, dryRun: false)`（:316）
- 摘要组装（:318-324）：`ok` 时 `result.text` 为空则"技能「X」已启动"；`postedEvents > 0` 追加"（注入 N 个事件）"（:321）；失败时 `result.text` 为空则"工具「X」调用失败"（:323）
- ⚠️ **旧文写的 `Thread.sleep(forTimeInterval: 0.6)` 已不存在**——W7 版 execute 里没有任何 sleep（全文 grep 无 `Thread.sleep`）

**熔断统计（:268-283，弱模型防线 8）**：**仅当 `usedRealLLM`**（:271）才统计——`taskFailed = aborted || executed.isEmpty || history.allSatisfy { !$0.ok }`（:272-273）→ `llmFailureStreak += 1`；**连败 ≥ 3 自动降级本地规则**（:276-279，progress 提示"可在面板重新开启 AI 规划"）；任务成功则清零（:281，**降级后需手动 resetLLMDowngrade 恢复**）。**渠道回退（usedRealLLM 已置 false）不计入**（:270 注释）。

**`trimmedHistory`（:331-337，防线 7）**：`history.suffix(3)`（:332）+ 每条 summary `prefix(120)`（:335）——模型不需要全部历史，只需要"刚刚发生了什么"。

**`displayName(for:)`（:340-343，旧名 `skillName(_:)`）**：技能类工具查 AgentSkillLibrary 中文名，非技能工具直接用 `registryToolName`。

## 三、MockLLMPlanner 与 RealLLMPlanner（第 346–657 行）

**`MockLLMPlanner`（final class，:350-390）**——离线自测规划器：

- 定位（:348-349 注释）：**模拟 LLM：根据任务关键词做确定性技能规划。与真实 LLM 走完全相同的 tool_use 协议，用于无可用候选时验证整条链路**

**规则表（:353-363，优先级从高到低，`rules` 数组第一条命中即停）：**

| 关键词 | 技能序列 |
|---|---|
| 领奖励 / 领奖 / 领取 | `["rewards"]` |
| 收家具 / 收一收 / 收取 | `["furniture"]` |
| 登录 / 进游戏 / 上线 | `["auto_login"]` |
| 排球 | `["volleyball"]` |
| 钓鱼 / 钓个鱼 | `["fishing"]` |
| 咖啡 | `["coffee"]` |
| 钢琴 / 弹琴 | `["piano"]` |
| 闪避 | `["dodge"]` |
| 音游 / 超强音 / 节奏 | `["rhythm"]` |

- **`plan(task:) async -> [AgentToolCall]`（:365-376）**：`for rule in rules where calls.isEmpty`——**只取第一条命中规则**；`rule.skills.enumerated().map { i, sid in AgentToolCall(id: "mock-\(sid)-\(i)", skillID: sid, args: [:]) }`；无命中返回 []
- **`nextStep`（:378-381）**：**Mock 模式单轮规划即完成（无多步依赖），恒返回 nil**
- **`finalize`（:383-389）**：history 空 → "我没有找到匹配的技能。当前可用：登录、排球、领奖励、收家具（真实），钓鱼/咖啡/钢琴/闪避/超强音（待移植）。…"（:385）；非空 → "任务完成：共执行 N 个技能。" + 摘要串接（:387-388）
- ⚠️ **文案口径已过期（且原描述有一处说反了，♻️ 2026-10-18 修正）**：`AgentLoop.swift:385` 仍说"钓鱼/咖啡/钢琴/闪避/超强音（待移植）"。其中 **4 个确已 `ported: true`**（`AIAgentPanel.swift:96` fishing / `:98` coffee / `:110` piano / `:114` dodge），但 **`rhythm`（超强音）实为 `ported: false`**——`:112-113` 未写 `ported` 字段，走 `:68` 的默认值 `false`，与文档原先把这 5 个并列为 "早已是 ported: true" **不符**（原文把 :112 也当成了已移植例证）。⟹ 该处文案对 4 个技能确实过期，对 `rhythm` **仍然正确**。MockLLMPlanner 也不查 `ported`（plan 直接返回调用，靠 execute 三重校验兜底）。本文只如实记录该漂移，未改代码。

**`RealLLMPlanner`（final class，:396-657）**——真实 LLM 调用（**W7 复用新传输层**）：**本类不做 HTTP、不手工拼 tools**（:394-395）。

| 成员 | 说明 |
|---|---|
| `maxCandidateAttempts = 4`（static，:399） | **单次任务内最多轮换的候选数**（"本模型连续失败时自动换候选，最多 4 个"） |
| `requestTimeout = 30`（static，:403） | 单次规划请求超时。**选 30s 而非传输层默认 60s**：候选最多 4 个，若每个都等满 60s，用户会以为面板卡死（:401-402） |
| `settings / candidates / tools`（:405-407） | 依赖注入：配置、候选链、工具清单 |
| `activeIndex`（private，:410） | 当前候选下标：**成功后粘住**（同任务后续步骤继续用同一模型，避免反复跳） |
| `lastUsedCandidate`（private(set)，:412） | 最近一次真实可用的候选（finalize 如实报告用） |
| `channelExhausted`（private(set)，:414） | 候选链是否已全部失败 |
| `lastTriedIndex` / `triedToEnd`（:416、:418） | 区分「走完链」与「撞上 4 次上限」 |
| `failureReasons` / `failureReasonText`（:420、:422-430） | 逐条如实记录失败原因；**撞上限时如实说明还有候选项未尝试，不谎报"全部失败"**（:424-427） |
| `init(settings:candidates:tools:)`（:432-436） | 三步注入 |

**三个 AgentPlanner 方法（:440-464）**：`plan` → `run(messages: buildMessages(task:history: nil))`（:440-442）；`nextStep` → `guard !history.isEmpty` → `run(...)` → **`calls.first`（只取第一个，与防线 4 单步化对齐）**（:444-448）；`finalize`（:450-464）——**channelExhausted 时如实说明"是渠道问题，不是任务失败"**（:451-455）；history 空 → "LLM 未返回任何工具调用。当前可用：登录、排球、领奖励、收家具（真实）。"（:458）；非空 → "LLM 完成任务：共调用 N 个工具（模型 backend/model）。" + 逐条列表（:460-463）。

**`run(messages:)`（private，:471-525）——单次请求 + 候选轮换**：

- 起点 `index = min(activeIndex, max(0, candidates.count - 1))`（:474）；`while attempted < maxCandidateAttempts && index < candidates.count`（:475）
- 逐候选：`makeTransport` 返回 nil（渠道不可用或缺 Key）→ 记 reason（:481-482）+ `lastTriedIndex = index + 1` + `continue`（:483-485）
- `transport.complete(LLMRequest(...))`（:487-498）：`stream: false`、`temperature: temperature(settings.thinkingDepth)`、`maxTokens: 1024`、`timeout: requestTimeout`、`providerName: candidate.backend.displayName`
- 成功：`LLMHealthMonitor.shared.noteSuccess(candidate, latencyMs:)`（:500，**真实请求即探活**）→ `activeIndex = index` / `lastUsedCandidate` / `channelExhausted = false` / `triedToEnd = false`（:501-504）→ `return Self.toolCalls(from: completion)`（:505）
- 失败：**取消不是模型问题**（:507-512）——`isCancellation` 时仍 `noteFailure` 但置 `cancelled = true` 并 break（不换候选、不误报"渠道全挂"）；其余 `noteFailure`（:513）+ 记 reason（:514）+ 换下一个（:515-516）
- 收尾：`triedToEnd = !cancelled && lastTriedIndex >= candidates.count`（:521）；`channelExhausted = !cancelled`（:522）；`if cancelled || channelExhausted { lastUsedCandidate = nil }`（:523）；返回 []（:524）

**渠道适配（:527-568，本文件唯一依赖 W1/W2 API 形状的地方）**：`descriptor(for:settings:)` → `LLMBackendRegistry.shared.descriptor(for:baseURLOverride:)`（:532-535）；`baseURL` 优先用描述符、拿不到回退 `settings.baseUrl`（:539-542）；`extraHeaders` 取描述符（:545-547，Zen 的 UA / x-opencode-session / Bearer public 等）；`apiKey` **免 key 渠道传 nil**，需 key 渠道但 key 为空也返回 nil（:551-554）；`makeTransport` 用 `LLMTransportFactory.make(baseURL:apiKey:extraHeaders:timeout:providerName:)`，**需 key 渠道无 key 时本地拦截（根本没发请求）**（:557-568）。

**消息与解析（:570-656）**：

- `temperature(_ depth:)`（:572-580）：思考深度 4 档 → 0.9 / 0.5 / 0.2 / 0.05（**想得越深输出越收敛**，与面板/旧 callLLM 同表）
- `systemPrompt`（:588-599）：**复用 `AgentChatService.systemPrompt`（单一来源，领域知识只维护一份）** —— 2026-10-07 修复提示词漂移（:584-587：原提示词只有"你是游戏助手规划器"，对《异环》一无所知），再追加 4 条规划器执行规则（每步只调一个工具 / 只用清单内工具名 / 完成即停 / 界面操作走「ESC → screenshot → mouse_click」且**绝不按 F1–F12**）
- `buildMessages(task:history:)`（:602-609）：系统提示 + 用户任务 + 历史结果（"成功/失败：summary"逐行，末尾"请判断下一步：若任务已完成，不要再返回工具调用。"）
- `toolCalls(from: LLMCompletion)`（:613-617）：`completion.toolCalls` → `AgentToolCall(id: call.id, skillID: call.name, args: parseArguments(call.argumentsJSON))`
- `parseArguments(_ json:)`（:620-640）：JSON 字符串 → `[String: String]`（标量转字符串、嵌套保留 JSON 文本），解析失败返回 [:]
- `isCancellation`（:643-647）：`CancellationError` 或 `LLMError.kind == .cancelled`
- `describe`（:650-656）：`LLMError` → `"kind（message）"`，如实展示上游原话

## 四、Agent/ 目录全貌与 AI 任务链（2026-10-07 由 E4 按 `wc -l` / `grep` 重测）

### 4.1 文件职责一览（行数 2026-10-07 `wc -l` 实测）

- **AgentLoop.swift**（**657 行**）：本文主体——零框架原生 Tool-Calling 任务循环（W7 复用 LLMTransport + ToolRegistry）。
- **RuleController.swift**（200 行）：YOLO 检测→控制量的规则控制器（:79 类声明）。核心语义（2026-10-02 用户要求，:139-152 注释）：**绝不自动刹车**（本游戏 brake = S 键兼倒车），危险时只压油门 + 反向转向（b 恒 0）；三档危险分级 :153-174。`fuse(detections:e2e:)`（:182-199）做「危险规则覆盖、安全信 E2E」融合。⚠️ **✅ 2026-10-18 复核**：`fuse` **全仓零调用**（`grep -rn "fuse(" Sources/` 只命中定义行 :182，无消费点）→ 该方法是**死代码**。`dangerLevel`/`nearestDetection` 两个 `@Observable` 状态同样只写不读。
- **DegradeStateMachine.swift**（165 行）：三档降级梯子 e2e → yolo → rule（:6）。优先级：forceRule（:92-97）> 极速模式强制 e2e（:101-104）> 暖机保持（:108-110）> 健康度+滞回驱动（:113-137，恢复阈值 0.99 上限防死锁 :114）。**脱困档 .recover 已删**（:7-8、:36-38），详见 代码-20。
- **DriveSegmentController.swift**（430 行）：驾驶分段状态机 vision→mapTurn/junction→straighten→handover→vision（:37-50 枚举）。交接**四条件 AND**（:340-362）：走廊内 :343-348、位移达标 :350-351、拟合稳定 :353、车道线置信 >0.25 :355；连续帧累计 :357-361（破裂则退不硬凑），12s 凑不齐退回回正段 :378-382。6 个参数全部来自 AURORA_SEG_*（init :104-113，走 AuroraFlags）。
- **EgoBoxFilter.swift**（118 行）：按**面积**剔除第三视角自车框（纯函数 struct，:53）。阈值 4.0%（:63，实测依据 :29-39：自车框 min 4.25% / 真车中位 0.17%，差 33 倍）；fail-open（异常面积保留 :42、:91-95）；**只作用于决策层，UI 照画全部框**（:45-46；消费点 `effectiveDetections` 计算属性 = `egoBoxFilter.filter(displayDetections)`，**AuroraDriveApp.swift:4235-4236**，✅ 2026-10-18 复核修正：原写 :4233-4234，那两行是注释不是代码）。
- **FallbackGuard.swift**（280 行）：双结构几何兜底（结构 A 中心带内面积最大框 :220-234、结构 B IoU≥0.15（:104）或中心距≤0.06（:110）判碰撞 :166-176），连续 3 帧确认 :113、:183-186。⚠️ **主链路已停用**：AuroraDriveApp.swift 有两处删除记录——tick 内消费者删除块 **:6729-6740**（结论句 **:6739-6740**：实例与类型保留仅供自检、不再参与任何控制），施加点删除块 **:7697-7719**（结论句 **:7717-7719**：几何兜底原理不成立、**整体删除不留任何脱困措施**、脱困唯一途径改为请求人工介入）。✅ 2026-10-18 复核修正行号（原写 :6726-6737 / :7691-7716 / 结论句 :6736-6737 / :7710-7716 —— `AuroraDriveApp.swift` 已增至 9094 行，全部漂移 3~7 行）。附带：`FallbackGuard.evaluate` 的 `isDegraded` 形参、`lastResult`、`collisionStreak` 均无消费者。
- **AIAgentPanel.swift**（**3273 行**，2026-10-16 `wc -l` 实测；原文写 3253 行）：AI 面板 + 技能中枢。`AgentSkillLibrary`（:90-128）18 个技能清单（**15 个 `ported: true`**，见文首勘误）；`AgentSkillCenter`（:135 起，`static let shared` :137）是「人类点击与 AI 指令的唯一执行通道」（:133 注释），`workQueue = DispatchQueue(label: "agent.skill", qos: .userInteractive)`（:263）、LLM 调用 `callLLM` :281、`runSkill` :583、`sendUserMessage` :1500；AgentLoop 调用点在 :1532（复合判据 :1521），自检 3.6「AgentLoop 端到端规划」:1862-1868。
- **LoginAssistant.swift**（166 行）：OCR 自动登录引擎（:27 类声明），Vision OCR（:47 `VNRecognizeTextRequest`）→ 关键词优先级匹配（`buttonKeywords` :40-44）→ 屏幕点击 → 2s 后重截图验证（`verifyDelay = 2.0` :118、:133-138），有界 3 轮（`maxRounds: Int = 3` :119）。`locateButton`（:66/:72）也被领奖励/收家具等技能复用。
- **W1–W4 新传输层（2026-10-07 复核，本目录）**：`AgentSettings.swift`（262 行，`LLMBackendKind` :29）、`LLMBackend.swift`（884 行，`LLMBackendDescriptor` :94、`LLMBackendRegistry`）、`LLMTransport.swift`（1580 行，`LLMErrorKind` :62、`LLMToolSpec` :375、`LLMCompletion` :451、`LLMRequest` :478、`protocol LLMTransport` :526、`LLMTransportFactory.make` :1567）、`LLMHealth.swift`（1791 行，`LLMCandidate` :112、`LLMHealthMonitor`、`candidates(preferred:…)` :840）、`ToolRegistry.swift`（1065 行，`shared` :119、`specs()` :372、`invoke(name:args:dryRun:)` :388）、`WebSearch.swift`（1463 行）、`AgentChatService.swift`（618 行，`systemPrompt` :151）、`LLMSelfTest.swift`（2183 行）。

### 4.2 AI 任务链（非驾驶）

```
AgentSkillCenter.sendUserMessage(text)（AIAgentPanel.swift:1500）
  ├─ 停止指令优先（:1506-1512）
  ├─ 关键词直配成功（单技能且非复合）→ 直接 runSkill（:1543-1548）
  └─ 复合任务（matchedCount >= 2 或 单技能带任务动词 isComplexTask，:1521）
       → AgentLoop.shared.handle(task, from: .ai)（调用点 AIAgentPanel.swift:1532，Task 内 await，不阻塞 workQueue）
            → 候选链（W3）→ RealLLMPlanner（LLMTransport）plan → 执行循环 → nextStep → finalize
            → execute() → ToolRegistry.invoke（:316）统一执行（技能类先过三重校验）
  └─ 自由聊天（无技能命中）→ `sendChatMessage`（:1555 调用；内部走 AgentChatService.reply :1591，独立于 AgentLoop）
```

### 4.3 线程要点（本目录相关）

- `AgentSkillCenter.workQueue = DispatchQueue(label: "agent.skill", qos: .userInteractive)`（AIAgentPanel.swift:263）——所有技能循环定时器（`DispatchSourceTimer`，声明 :248-262）与异步任务都在它上面串行跑；AgentLoop 的 handle 走独立 `Task`（AIAgentPanel.swift:1529-1538 注释：**已去掉会永久阻塞 workQueue 的 semaphore**）。
- `AgentLoop.handle` 有 `isRunning` 互斥（AgentLoop.swift:144-146），任务不并发。
- **W7 后 execute 内已无 `Thread.sleep`**：旧文"阻塞调用方 0.6s"的描述随 `AgentSkillCenter.callLLM` 路径一并作废。
- DegradeStateMachine / RuleController / DriveSegmentController / EgoBoxFilter 均在**主线程 tick** 里被调用（见 代码-25 第八节），无自带队列。
