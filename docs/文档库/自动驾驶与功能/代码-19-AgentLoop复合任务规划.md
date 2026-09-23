# 代码-19 AgentLoop 复合任务规划

> 覆盖源文件：`Sources/AuroraDrive/Agent/AgentLoop.swift`（325 行）。基于当前仓库逐单元编写。

## 一、架构与协议类型（第 1–89 行）

**定位（4–26 行头注释）**：原生 Tool-Calling 端到端任务循环（**零框架**，用户点名的设计）——用户一句话 → LLM 把任务拆成一系列技能调用（tool_use）→ AgentLoop 逐个执行 AgentSkillCenter 的技能 → 结果回传 LLM → LLM 继续规划直到任务完成。

**三个核心设计（源注释原文）：**

1. **与 AgentSkillCenter 完全解耦**：AgentLoop 只做「调度」，技能执行全部走既有的统一执行通道（人类 + AI 共用）
2. **工具协议（ToolProtocol）与真实 LLM 的 tool_use 一致**，方便将来接 DeepSeek/GPT/Claude 任意一家
3. **MockLLM（内置模拟调度器）**：无 API key 也能端到端自测，验证「指令→规划→执行→回传→完成」整条链路；有 key 时自动用真模型

**调用链（20–26 行）：**

```
AgentSkillCenter.sendUserMessage("帮我登录然后领奖励")
  └─ 关键词直配失败 → AgentLoop.shared.handle(task, from: .ai)
       └─ MockLLM / RealLLM.plan(task) → [ToolCall]
            └─ 逐个执行 execute(toolCall) → 结果回传
                 └─ LLM.finalize(...) → 总结 → 完成
```

**协议类型（第 30–57 行）：**

| 类型 | 字段 | 说明 |
|---|---|---|
| `AgentToolCall`（Codable） | `id: String`（LLM 回传用）/ `skillID: String`（与 AgentSkillLibrary 对应）/ `args: [String: String]`（当前技能大多无参，预留） | 一次技能调用 |
| `AgentToolResult`（Codable） | `id / skillID / ok: Bool / summary: String`（执行摘要，回传给 LLM） | 技能执行结果 |
| `AgentPlanner`（protocol） | `plan(task:) async -> [AgentToolCall]`（第一步：拆任务）/ `nextStep(task:history:) async -> AgentToolCall?`（中间步：看结果定下一步）/ `finalize(task:history:) async -> String`（收尾：总结） | 规划器协议——三个方法对应规划循环的三个阶段 |

**`AgentLoop` 主循环（final class，第 61–89 行）**——端到端任务循环（**单例** `static let shared`，`private init()`）：

| 成员 | 说明 |
|---|---|
| `var planner: AgentPlanner?` | 当前规划器：**nil = 未配置（走 MockLLM 离线自测）** |
| `llmFailureStreak: Int`（private） | **弱模型防线 8：熔断降级状态（连续 LLM 任务失败计数）**——由 handle 内部按"任务成败"维护；handle 有 isRunning 互斥，无并发写 |
| `aiPlanningEnabled`（private(set)，默认 true） | 是否处于降级中 |
| `resetLLMDowngrade()` | **手动恢复 AI 规划**（面板"AI 规划"开关/CLI 调用此方法）：连败清零 + 恢复 true |
| `isRunning`（private(set)） | 是否正在运行任务 |
| `maxSteps = 8`（private let） | **最多连续工具调用步数（防模型死循环）** |
| `onProgress: ((String) -> Void)?` | 执行过程中的进度回调（UI 显示用） |

## 二、handle() 主循环与弱模型防线（第 91–250 行）

**`handle(task:from:progress:) async -> String`（第 93–207 行）**——处理一个任务：规划 → 循环执行 → 总结，返回最终总结文本。

**入口与规划器选择（95–112 行）：**

1. `guard !isRunning else { return "⚠️ 已有任务在运行…" }`（互斥）→ `isRunning = true` + `defer { isRunning = false }`
2. **规划器选择**：`useLLM = hasAPIKey && aiPlanningEnabled`——优先真 LLM（有 Key）；**降级中时即使有 Key 也走本地规则（零幻觉兜底）**；降级中且有 Key 时 progress 提示"⚠️ AI 规划处于降级状态：本次使用本地规则规划（MockLLM，零幻觉）"
3. `var calls = await planner.plan(task: task)`——空则直接 `finalize` 返回总结

**循环执行（129–187 行）——防线参数表：**

| 防线 | 参数 | 语义 |
|---|---|---|
| 4 单步化 | `calls.count > 1 → [calls[0]]` | **模型一次返回多个调用时只执行第一个（防发散/重复/顺序错乱）** |
| 5 单技能封顶 | `callCounts[skillID] > 3 → 跳过` | **同一技能调用次数封顶（防弱模型反复调用同一技能）** |
| 6 总时长熔断 | `maxDuration = 120` 秒 | 超时强制终止（"已执行 N 步"） |
| 6 连续失败熔断 | `maxFailedSteps = 2` | 连续 2 步失败 → `aborted = true` 终止任务 |
| 7 上下文裁剪 | `trimmedHistory` | **只喂最近 3 步（每条 summary 截断 120 字符），防弱模型丢指令 + 省 token** |
| 10 可观测 | 失败必打日志 | **被拒绝/失败的调用必须打 progress 日志（否则用户看不到"模型越界"）** |

**执行循环细节（140–187 行）**：`while steps < maxSteps` → 总时长熔断 → `steps += 1` → 逐个执行（防线 5/10/6）→ `if aborted { break }` → **`planner.nextStep(task:task, history: trimmedHistory(history))`**——让 LLM 看结果决定下一步（无 → 任务完成，`calls = []`）。

**`execute(call:) -> AgentToolResult`（private，第 210–235 行）**——执行一次技能调用（**走 AgentSkillCenter 统一通道**），**三重校验：**

| 校验 | 失败摘要 |
|---|---|
| 存在（`AgentSkillLibrary.all.first(id == skillID)`） | "未知技能「X」（模型幻觉，已丢弃）" |
| 已移植（`skill.ported`） | "技能「X」尚未移植（模型越界，已拒绝）" |
| 未在运行（`!center.runningSkills.contains`） | "技能「X」已在运行（重复调用，已跳过）" |

- 通过后：记录执行前消息数 → `center.runSkill(call.skillID, source: .ai)` → **`Thread.sleep(forTimeInterval: 0.6)` 给 start 日志落进 messages** → 新增消息 join 做 summary（空则"已启动"）→ `(ok: true, summary)`

**熔断统计（第 189–203 行，弱模型防线 8）**：本任务用 LLM 且失败（`aborted || executed.isEmpty || history.allSatisfy { !$0.ok }`）→ `llmFailureStreak += 1`；**连败 ≥ 3 自动降级本地规则**（progress 提示"可在面板重新开启"）；任务成功则清零（**降级后需手动 resetLLMDowngrade 恢复**）。

**`trimmedHistory`（第 239–245 行，防线 7）**：`history.suffix(3)` + 每条 summary `prefix(120)`——模型不需要全部历史，只需要"刚刚发生了什么"。

**`skillName(_ id:)`（第 247–249 行）**：查 AgentSkillLibrary 取显示名，未知返回 id。

## 三、MockLLMPlanner 与 RealLLMPlanner（第 252–325 行）

**`MockLLMPlanner`（final class，第 252–296 行）**——离线自测规划器：

- 定位（254–255 行注释）：**模拟 LLM：根据任务关键词做确定性技能规划。与真实 LLM 走完全相同的 tool_use 协议，用于无 key 时验证整条链路**

**规则表（第 259–269 行，优先级从高到低，`rules` 数组第一条命中即停）：**

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

- **`plan(task:) async -> [AgentToolCall]`（271–282 行）**：`for rule in rules where calls.isEmpty`——**只取第一条命中规则**；`rule.skills.enumerated().map { AgentToolCall(id: "mock-\(sid)-\(i)", skillID: sid, args: [:]) }`；无命中返回 []
- **`nextStep`（284–287 行）**：**Mock 模式单轮规划即完成（无多步依赖），恒返回 nil**
- **`finalize`（289–295 行）**：history 空 → "我没有找到匹配的技能。当前可用：登录、排球、领奖励、收家具（真实），钓鱼/咖啡/钢琴/闪避/超强音（待移植）。试试说「帮我领奖励」或「打排球」"；非空 → "任务完成：共执行 N 个技能" + 摘要串接

**注意**：finalize 文案里"待移植"的口径是**编写时的状态**（当时 fishing/coffee 等标记 ported=false）；当前 AgentSkillLibrary 的 ported 标记以 代码-23 文档的清单为准——MockLLMPlanner 不查 ported（plan 直接返回调用，execute 里三重校验兜底拒绝）。

**`RealLLMPlanner`（final class，第 298–325 行）**——真实 LLM 调用：

- 定位（300 行注释）：**通过 OpenAI 兼容 API 调用云端模型**
- `private let center: AgentSkillCenter` + `init(center:)`——持有 AgentSkillCenter 引用（API 配置与 callLLM 都在 Center 侧，见 代码-25 文档）

| 方法 | 实现 |
|---|---|
| `plan(task:) async -> [AgentToolCall]` | `await center.callLLM(task: task, history: [])`——空历史首规划 |
| `nextStep(task:history:) async -> AgentToolCall?` | `guard !history.isEmpty else { return nil }` → `center.callLLM(task:history:)` → **`calls.first`（只取第一个，与防线 4 单步化对齐）** |
| `finalize(task:history:) async -> String` | history 空 → "LLM 未返回任何技能调用…"；非空 → "LLM 完成任务：共调用 N 个技能" + 逐条列表 |

**AgentLoop 文档至此完整**（325 行全覆盖：架构与协议 → handle 主循环与防线 → 双规划器）。