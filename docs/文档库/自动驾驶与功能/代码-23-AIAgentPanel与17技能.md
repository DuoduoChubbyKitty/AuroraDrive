# 代码-23 AIAgentPanel 与 AgentSkillLibrary 17+ 技能

> 覆盖源文件：`Sources/AuroraDrive/Agent/AIAgentPanel.swift`（2639 行）。基于当前仓库逐单元编写。

## 一、数据模型与 AgentSettings「小本本」（第 1–134 行）

**架构灵魂（4–22 行头注释）**：AI 助手侧边面板 + 技能统一执行通道——

```
AgentSkillCenter 是「人类」与「AI」共用的唯一执行通道：
  人类点技能按钮  →  run(skillID, source: .human)
  AI 发送指令     →  sendUserMessage("帮我钓个鱼") → 解析 → run(skillID, source: .ai)
两条路最终都汇入 run(skillID, source:) 这一个入口，任何技能都
可被双方调用，行为完全一致（状态、日志、会话消息都同源）。
```

**技能真实度说明（诚实标注，不做假按钮，15–20 行）**：auto_login/volleyball 全真实；其余依赖 MaaNTE 视管线（Windows Win32 控制器），macOS 原生版为"现场快照 + 状态回报"占位，**UI 上如实显示「待移植」**。坐标系见 LoginAssistant.swift 头注释。

**数据模型（第 31–68 行）：**

| 类型 | 字段 | 说明 |
|---|---|---|
| `AgentMessage`（Identifiable, Equatable） | `role: Role`（`user`（人类）/ `assistant`（AI 回复）/ `system`（技能启动/停止/结果））/ `text` / `time` / `source: AgentInvokeSource`（这条消息从哪来，诊断用） | 会话消息 |
| `AgentInvokeSource`（enum: String） | `.human = "👤"` / `.ai = "🤖"` | 调用来源：人类点击 or AI 指令（同一通道的两类调用者） |
| `AgentSkill`（Identifiable） | `id`（**稳定 ID，AI 指令解析也用**）/ `emoji` / `name` / `warn`（高危/最凶标记，默认 false）/ `ported`（**false=待移植占位（默认值防止漏标）；true 必须显式声明**）/ `keywords`（AI 指令解析关键词） | 技能定义 |
| `AgentModel`（enum: String, CaseIterable） | `claude35 / gpt4o / gemini / deepseek` | AI 模型选择（UI 按钮显示；**实际请求用的是 AgentSettings.model 字符串**） |

**`AgentSettings`（Codable, Sendable，第 71–134 行）——API Key/模型/端点，用户自己填写，安全存「小本本」文件：**

| 成员 | 默认值 | 说明 |
|---|---|---|
| `apiKey / baseUrl / model / thinkingDepth` | "" / `https://api.deepseek.com` / `deepseek-chat` / 1 | 配置四件套；thinkingDepth 1-4 映射到 temperature |
| `service / keyApi / keyBase / keyModel / keyDepth` | `"com.aurora.drive.aiagent"` 等 | Keychain 常量（**历史遗留——现在不碰钥匙串**，见下） |
| `suiteName` + `defaults` | `"com.aurora.drive.aiagent"` | **固定 suite 的 UserDefaults（CLI 与 .app 共用同一份，避免进程名不同域不同）** |
| `notebookURL`（static） | `~/Library/Application Support/AuroraDrive/llm-key-notebook.txt` | **API Key「小本本」文件——用户指令：不再访问钥匙串（启动路径每次读 Keychain 是启动异常根因；改存用户目录 0600 文件，启动路径零 Keychain 接触）** |

**`save()`（第 99–111 行）**：非敏感字段（baseUrl/model/thinkingDepth）→ 固定域 UserDefaults + synchronize；**apiKey → 本地小本本文件（atomic 写 + `posixPermissions: 0o600`）**——**全程不碰钥匙串**；空 key 跳过。

**`load()`（第 114–128 行）**：小本本读 apiKey（`try? Data(contentsOf:)`，读取失败不崩）+ 固定域读其余字段；thinkingDepth < 1 归 3（缺省值兜底）。

**`deleteKeychain()`（第 131–133 行）**：**函数名保留兼容，实际只删小本本文件**（`removeItem(notebookURL)`），不再碰钥匙串。

## 二、AgentSkillLibrary 技能清单全表（第 136–177 行）

**`AgentSkillLibrary.all: [AgentSkill]`（static let，第 139–176 行）**——**人类 + AI 共用同一份**技能清单。**19 个技能**（比文件头注释的"17 项"多 2 个——清单是权威，头注释口径滞后）：

| id | emoji | name | ported | warn | 关键词（AI 指令解析） |
|---|---|---|---|---|---|
| `auto_login` | 🔑 | 自动登录 | **true** | — | 登录/登陆/进游戏/上线 |
| `volleyball` | 🏐 | 自动排球 | **true** | — | 排球 |
| `fishing` | 🎣 | 自动钓鱼 | **true** | — | 钓鱼/钓个鱼 |
| `coffee` | 🥤 | 自动作咖啡 | **true** | — | 咖啡 |
| `coffee_lite` | 🥛 | 轻量做咖啡 | **true** | — | 轻量/lite |
| `bagel_spam` | 🥯 | 贝果刷屏 | **true** | — | 贝果/刷屏 |
| `pinkpaw` | 🐾 | 粉爪大劫案 | **false** | **warn=true** | 粉爪/大劫案 |
| `furniture` | 🪑 | 自动收家具 | **true** | — | 家具/收家具/收取 |
| `rewards` | 💎 | 自动领奖励 | **true** | — | 奖励/领奖/领取 |
| `piano` | 🎹 | 自动弹钢琴 | **true** | — | 钢琴/弹琴 |
| `rhythm` | 🎵 | 自动超强音 | **false** | — | 超强音/音游 |
| `dodge` | ⚔️ | 自动闪避 | **true** | — | 闪避/躲避 |
| `auto_scroll` | 📜 | 自动滚动 | **true** | — | 滚动/拾取/捡东西/翻页 |
| `touch` | ✋ | 自动抚摸 | **true** | — | 抚摸/摸/宠物/touch |
| `drive_dataset` | 🎬 | 驾驶数据采集 | **true** | — | 数据集/采集/录制/驾驶数据/drive |
| `preset_afk` | 🛋️ | 挂机预设 | **true** | — | 挂机/AFK/预设/一键全做 |
| `preset_realtime` | ⚡ | 实时辅助预设 | **false** | — | 实时/辅助/realtime |
| `tomato_juice` | 🍅 | 自动作番茄汁 | **true** | — | 番茄/番茄汁/tomato |

**ported 统计**：16 个 ported=true（真实技能）、3 个 false（pinkpaw 粉爪大劫案、rhythm 超强音、preset_realtime 实时辅助预设——**待移植占位**）。

**ported=false 的语义**（AgentSkill 定义 57 行）：**false=待移植占位（默认值防止漏标）；true 必须显式声明**——即**漏标时技能自动被当成"待移植"拒绝执行**，不会出现"假按钮真执行"。AgentLoop.execute 的三重校验里 `guard skill.ported` 挡住这三个；callLLM 的 tools 声明也 `.filter { $0.ported }` **动态过滤——只给已移植的技能（防线 2）**，模型根本看不到待移植技能。

**warn 的语义**：高危/最凶标记（pinkpaw 是三阶段潜行动作，误触发会浪费游戏资源）——UI 上红色警示；AI 路径不因 warn 拒绝（只在 ported=true 后才可见）。

**关键词与 MockLLMPlanner 的关系**：MockLLMPlanner（代码-19）有自己的规则表（9 条），与本清单 keywords 是**两套独立的关键词匹配**——AgentSkillCenter.sendUserMessage 先走关键词直配（本清单），失败才落 AgentLoop（Mock/Real）。

## 三、AgentSkillCenter 状态与 callLLM（第 179–450 行）

**`AgentSkillCenter`（@Observable final class，第 182 行起）**——技能执行中心（**单例** `static let shared`，人类点击与 AI 指令的唯一入口）。

**注入的引擎（第 230–234 行）**：`control: ControlEngine?` / `capture: CaptureEngine?`（**由 DriveState 在启动时配置**）、`recordEngine: RecordEngine?`（@ObservationIgnored，**可选注入；nil 时 drive_dataset 报未注入**）。

**会话状态（第 236–245 行，UI 直接观察）：** `messages: [AgentMessage]`（会话消息）、`runningSkills: Set<String>`（正在运行的技能集合）、`currentModel`（UI 模型按钮显示）、`thinkingDepth`（思考强度滑块 1-10）、`isPanelOpen`（面板是否打开）。

**技能定时器与队列（第 247–266 行）**：`loginAssistant`（@Observable 不支持 lazy，用普通存储属性）、volleyballTimer/touchTimer/touchLoopCount/driveDatasetTimer/pianoTimer/pianoStepIndex/coffeeTimer/coffeeIter/coffeeLiteTimer/coffeeLiteIter/bagelSpamTimer/bagelSpamIter/tomatoTimer/tomatoIter（**每个循环技能一个 DispatchSourceTimer + 迭代计数，全部 @ObservationIgnored**）、`workQueue`（`DispatchQueue("agent.skill", qos: .userInteractive)`——技能执行队列）。

**`llmSession`（第 269–275 行）**：LLM 专用 URLSession——**30s 请求超时 + 45s 资源总超时（防挂起占满线程）**、ephemeral、waitsForConnectivity = false。

**`fetchLiveModels(completion:)`（第 199–228 行）**——从 API 拉取真实模型清单（面板模型菜单用）：

- `guard !s.apiKey.isEmpty` → 空；baseUrl 归一化（去尾 `/`、补 `/v1`）→ `{base}/models` GET + Bearer 头
- **15s 硬超时**（timeoutInterval 15 + ephemeral config 同值）；**过滤非对话模型**：id 里含 "image"/"video" 的剔除
- **失败不崩**：回传空数组，UI 显示当前模型兜底；`($0["id"] ?? $0["name"])` 兼容两种响应字段

**`callLLM(task:history:) async -> [AgentToolCall]`（第 284–413 行）**——调用云端 LLM（**OpenAI 兼容协议**，DeepSeek/OpenAI/Claude 等均支持）：

1. **配置校验（286–293 行）**：空 apiKey → "⚠️ 未配置 API Key，请先在设置中填写" + []；空 baseUrl/model → "⚠️ 未配置模型端点" + []
2. **messages 构建（297–312 行）**：system 提示（"你是异环游戏自动化助手。用提供的工具完成用户任务。**一次只调用一个工具**。不要解释，不要输出 JSON 文本。"——**与 tool calling 协议一致，不再要求输出 JSON 数组**）+ user task + **history 逐条 `role: "tool"` + `tool_call_id`**（OpenAI 工具协议）
3. **tools 声明（315–338 行）**：`AgentSkillLibrary.all.filter { $0.ported }` 动态过滤（防线 2）→ `toolDecl(name, desc)`——`{"type": "function", "function": {name, description, parameters: {type: object, properties: {}}}}`；desc 按技能 id 精确映射（auto_login="自动登录游戏" 等，default="自动\(name)"）
4. **temperature 映射（341–346 行）**：思考深度 4 档 → 1: 0.9（Low）/ 2: 0.5（Mid）/ 3: 0.2（High）/ 4+: 0.05（Max）——**想得越深，输出越收敛**
5. **请求体（348–356 行）**：model/messages/tools/temperature/max_tokens: 1024；**dlog 可观测（防线 10）**：规划请求落文件日志（task 前 60 字 + model + 端点 + tools 数 + **key 打码**（前 4+…+后 2））
6. **baseUrl 归一化（359–366 行）**：已含 /v1 不再重复拼接（OpenAI 兼容约定）→ `{base}/chat/completions` POST + Bearer + Content-Type json
7. **响应校验（375–380 行）**：200...299 外 → "❌ LLM 调用失败：\(response)" + dlog（"网络/401/限流"）+ []
8. **tool_calls 解析（383–401 行）**：choices[0].message.tool_calls → `compactMap` 取 id/function.name → `AgentToolCall(id: skillID: name, args: [:])`（**args 当前恒空，技能无参**）；appendSystem "🧠 请求 N 个工具，解析出 M 个调用" + dlog
9. **无 tool_calls（403–406 行）**：**"LLM 判定任务完成，或响应结构解析失败"——如实告知，不静默**
10. catch → "❌ LLM 请求异常" + []

## 四、plainAnswer / runLLMTest / 依赖注入 / 统一入口（第 415–612 行）

**`plainAnswer(question: String) async -> String`（第 416–450 行）**——**纯文本 LLM 问答（不带工具）**：返回模型的回答文本。

- 配置校验：空 key → "(未配置 API Key)"；无效端点 → "(无效端点)"
- temperature 映射同 callLLM（1:0.9/2:0.5/3:0.2/4+:0.05）；max_tokens: 256（比工具调用少——纯文本问答短回答）
- 解析 choices[0].message.content；解析失败 "(解析失败)"；异常 "(请求异常：…)"

**`runLLMTest() async -> Bool`（第 455–480 行）**——**真实 LLM 端到端自测**（不依赖主 actor，CLI 里也能跑）：

1. 打印配置（model/端点/密钥打码——**前 6+…+后 4**/思考深度）；空 key → 打印"先运行：--set-llm-config <key> <base> <model>" + false
2. ① 纯文本问答：`plainAnswer(question: "用一句话回答：1+1 等于几？")`
3. ② 工具调用：`callLLM(task: "帮我打排球", history: [])`——验证 AgentLoop 的技能路由；空 → "(模型未返回工具调用，任务视为纯对话)"
4. `fflush(stdout)` + true——**调用方决定退出码**

**`isDryRun`（@ObservationIgnored，第 483 行）**：是否处于自测模式（**跳过真实点击/按键，只验证链路**）。

**`private init()`（第 485–490 行）**：欢迎消息 appendSystem（"AI 助手就绪。可以点左侧技能按钮，或直接输入「登录」「排球」「钓鱼」等指令让我干活。"）。

**依赖注入与启动排队（第 492–557 行）：**

| 成员/方法 | 说明 |
|---|---|
| `pendingAutoLogin`（@ObservationIgnored） | **引擎未注入前排队的自动登录请求**（--auto-login 在 AppDelegate 触发，而截屏/按键引擎属于 DriveState，在 ContentView.onAppear 才注入） |
| `configure(control:capture:)`（第 498–515 行） | 注入 control/capture + `checkPermission()`；**引擎就绪后补上启动期间排队的自动登录**；**补发启动期间排队的 --agent-command 指令（与视图渲染解耦：命令模式 .accessory 下窗口可能被 orderOut，视图 onAppear 不触发 → 派发不能依赖视图）** |
| `pendingCommand`（@ObservationIgnored） | **AppDelegate 调用：启动下发 --agent-command 指令（引擎可能还没注入，先排队）**——命令模式（.accessory，窗口不可见）下视图 onAppear 可能永不触发，**故派发放在 AppDelegate + 引擎注入时补发，双保险** |
| `requestCommandOnStartup(_ cmd:)`（第 522–539 行） | 打印"1.5s 后经 sendUserMessage 管线下发"；引擎已注入 → workQueue.async 直接下发；未注入 → 排队 + **8 秒兜底**（asyncAfter：引擎一直没注入也直接下发） |
| `requestAutoLoginOnStartup()`（第 542–557 行） | `guard !runningSkills.contains("auto_login")`；未注入 → pendingAutoLogin 排队 + 8 秒兜底；已注入 → 直接 runSkill |

**统一入口（第 559–611 行）：**

| 方法 | 说明 |
|---|---|
| `toggleSkill(_ id:source:)` | 启动（或停止）一个技能——**人类点击与 AI 指令共用**：runningSkills 含则 stop、否则 run |
| `runSkill(_ id:source:)` | **三重校验**：存在（未知 → "未知技能「X」"）+ 未在运行（→ "已在运行中"）→ `runningSkills.insert` + appendSystem("\(source.rawValue) 启动「X」") + dlog → **`workQueue.async` 真实动作必须在工作队列执行（避免阻塞 UI 线程）** |
| `stopSkill(_ id:source:)` | `guard runningSkills.contains` → remove + `teardown(id: id)`（清定时器）+ appendSystem + dlog |
| `stopAll(source:)` | 遍历 runningSkills 逐个 remove + teardown；非空才 appendSystem("已停止全部技能") |

## 五、execute() 技能路由与登录守护（第 613–776 行）

**`execute(_ skill: AgentSkill, source: AgentInvokeSource)`（private，第 615–663 行）**——技能执行路由（workQueue 调用）：

- **dryRun 快照（616–618 行）**：`let dryRun = isDryRun`——**捕获启动瞬间的自测状态：异步队列执行时自测标记可能已被外部重置，必须用启动时的快照决定是否真发输入，保证自测语义确定**
- **16 个 case 路由**：auto_login / volleyball / rewards+furniture（纯 UI 点击型）/ fishing / dodge / auto_scroll / touch / drive_dataset / preset_afk / piano / tomato_juice / coffee / coffee_lite / bagel_spam / **default（待移植技能：真实快照 + 如实状态回报，不做假动作）**

**`performAutoLogin(skill:source:dryRun:)`（private，第 669–714 行）**——自动登录（**全真实链路 + 守护模式**）：

1. `guard let mouse = makeMouse()`——**辅助功能权限未授权 → "❌ 无法注入鼠标" + 移除 runningSkills**
2. `guard !dryRun`——自测模式：`dryRunLocate` 只定位不点击（"✅ 自测：定位成功「X」→ 坐标" 或 "ℹ️ 当前屏幕未发现登录按钮"）+ 移除
3. **安全前提（690–697 行）**：`if !GameWindowDetector.isGameVisible()`——**只自动操作游戏窗口。屏幕上没有【异环/NTE】窗口时绝不点击任何「登录」按钮（否则会误点浏览器/QQ 等窗口的登录按钮）**；游戏可能还在启动中 → 进入守护模式 `startLoginWatch`
4. **第一轮：立即尝试（700–713 行）**：`runAutoLogin(capture:mouse:logger:)`（完整 3 轮关键词）→ success → "✅ 登录成功" + 移除；noFrame → "❌ 截屏权限未授权？" + 移除；noMatchingText/clickedButStillStuck → 进入守护模式

**登录守护（第 716–776 行）——80 秒上限：**

| 成员 | 值 | 说明 |
|---|---|---|
| `loginWatchTimer`（@ObservationIgnored） | — | 守护定时器 |
| `loginWatchAttempts` | 计数 | 已检测次数 |
| `loginWatchMaxAttempts`（static = 10） | **10 × 8s = 80s** | 超时上限 |

**`startLoginWatch(mouse:logger:source:)`（第 722–776 行）**——守护模式：每 8s 检测登录界面并点击，直到成功或超时：

1. `guard loginWatchTimer == nil`（防重复守护）+ attempts 归零 + logger"🔍 守护启动（最多 10 次，再次点击技能可停止）"
2. DispatchSourceTimer（workQueue，8s 间隔）→ 事件：
   - **超时停止（738–744 行）**：attempts > 10 → "⏹️ 守护 80 秒未发现登录界面，自动停止（可能已在游戏内或游戏未启动）" + 移除 + cancel
   - **窗口护栏（746–752 行）**：`guard GameWindowDetector.isGameVisible()`——**只有检测到游戏窗口才允许点击（防止误点其他窗口的「登录」）；无游戏窗口 = 不点击、不停止，安静等待下一轮（超时兜底已在上面）**
   - **每轮只认主按钮（754–758 行）**：`runAutoLogin(maxRounds: 1)`——**避免反复狂点**
   - success → "✅ 守护点击成功" + 移除 + cancel；noFrame → "❌ 守护中断：截屏不可用" + 移除 + cancel；其余 → "仍在等待登录界面…"

## 六、循环技能实现：排球 / 抚摸 / 驾驶数据采集（第 778–900 行）

**`startVolleyballLoop(skill:source:dryRun:)`（private，第 779–812 行）**——自动排球（**真实 K 键循环，MaaNTE auto_volleyball 核心循环直移植**）：

1. dryRun → "✅ 自测：排球循环（K 键 0.6s）链路就绪" + 移除
2. `guard let control`（"❌ 按键引擎未注入"）+ **`guard GameWindowDetector.isGameVisible()`（"🎮 未检测到游戏窗口，排球已取消（安全护栏）"）**
3. **0.6s 一次 K 键短按——与 MaaNTE auto_volleyball.py 的节奏一致**（796 行注释）：DispatchSourceTimer（workQueue，0.6s）→ 事件：
   - `guard runningSkills.contains("volleyball")`（停止后不再执行）
   - **窗口护栏逐轮复检（801–806 行）**：游戏窗口消失 → "🎮 游戏窗口消失，排球已自动停止（安全护栏）" + teardown + 移除
   - `control.pressGameKey(.k, duration: 0.05)`——K 键短按（GameKey 枚举，见 代码-08）
4. appendSystem "🏐 排球循环运行中（每 0.6s 击球一次，再次点击或输入「停止」结束）"

**`startTouchLoop(skill:source:dryRun:)`（private，第 816–867 行）**——自动抚摸（**MaaNTE Touch 直移植**，序列：F 交互 → 点击抚摸区域 → ESC 退出，**循环最多 10 轮**）：

1. dryRun/引擎/护栏三重校验（同排球）
2. `touchLoopCount = 0` + `maxLoops = 10` + **每 3 秒一轮（F→0.5s→点击→0.5s→ESC）**：DispatchSourceTimer（1.0s 后首次、repeating 3.0）→ 事件：
   - `touchLoopCount += 1` > 10 → "✋ 抚摸完成（10 轮），自动停止" + teardown + 移除
   - `control.pressGameKey(.f, duration: 0.05)`——F 交互
   - **0.5s 后点击抚摸区（849–857 行）**：模拟 MaaNTE 的 `Click [660,480]`——`MouseController.screenPoint(fromPixel: (660, 480), scale:)` → `mouse.click(at: point, settleDelay: 0.3)`
   - **1.5s 后 ESC 退出交互（859–862 行）**：`pressGameKey(.esc, duration: 0.05)`
3. appendSystem "✋ 抚摸循环运行中（每 3s 一轮 ×10）"

**`startDriveDatasetLoop(skill:source:dryRun:)`（private，第 871–900 行）**——驾驶数据采集（**MaaNTE AutonomousDrivingDataset 直移植 · 复用 RecordEngine**，采样率 2Hz，每帧记录 steer/throttle/brake 按键状态）：

1. dryRun → "✅ 自测：驾驶数据采集（RecordEngine 2Hz）链路就绪"
2. `guard let recorder = recordEngine`——**"❌ 录制引擎未注入，无法采集驾驶数据"**（recordEngine 是可选注入，nil 时此技能不可用）+ 护栏校验
3. `recorder.start(perspective: "first")`——启动录制（见 代码-05）
4. **2Hz 采样（0.5s 间隔）**：DispatchSourceTimer + `elapsed` 累计 + `maxDuration = 60.0`——60 秒自动停止（"🎬 采集完成（60s），自动停止"）
5. **停止收尾（901–905 行）**：`recorder.stop()` + `recorder.flushSync()`（**等 meta.json 落盘，见 代码-05**）+ teardown + 移除
6. **按键状态采样（907–917 行）**：**macOS 按键状态采样（替代 Windows GetAsyncKeyState）**——`CGEventSource.keyState(.combinedSessionState, key: 13/0/1/2)` 读 W/A/S/D 物理状态 → `steer = d ? 1 : 0 - (a ? 1 : 0)`、`throttle = w ? 1.0 : 0.0`、`brake = s ? 1.0 : 0.0` → `recorder.appendFrame(image: capture?.currentFrame, steer:throttle:brake:)`——**采集的是用户（人类）正在按的键**（模仿学习数据）

## 七、挂机预设与钢琴（第 924–1052 行）

**`startPresetAFK(skill:source:dryRun:)`（private，第 926–955 行）**——挂机预设（**MaaNTE preset/AFK**）：依次启动 rewards → furniture → fishing：

1. dryRun → "✅ 自测：挂机预设（rewards→furniture→fishing）链路就绪"；护栏校验
2. **依次启动子技能（938–946 行）**：`subSkills = ["rewards", "furniture", "fishing"]`——**每个子技能间隔 5s 启动（给前一个时间稳定运行）**：`workQueue.asyncAfter(.now() + i × 5.0)` → `runSkill(sid, source: .ai)`（**source: .ai**——预设启动的子技能算 AI 调用）
3. **30s 后自动标记完成（947–954 行）**：`asyncAfter(.now() + 30.0)` → runningSkills 含 preset_afk → "🛋️ 挂机预设子技能已全部启动，自动标记完成" + 移除——**各子技能有自己上限，预设本身只负责"启动完"**（不等待子技能跑完）

**钢琴曲目（第 959–969 行）**——`pianoSongs: [(name: String, notes: [ControlEngine.GameKey])]`——**内置 3 首曲目**（每首为 GameKey 序列，节拍 0.4s/音符，完整循环播放）：

| 曲名 | 音符序列 |
|---|---|
| 小星星 | g,g,i,i,g,g,i,i / h,h,g,g,i,i / g,g,i,i,h,h,g,g |
| 欢乐颂 | g,g,h,h,i,i,h,g / g,g,h,h,y,y,u,i |
| 生日快乐 | i,i,g,g,h,h,i,y / g,g,u,u,h,h,i,g |

- GameKey 音键：G=中音1、H=中音2、I=中音3、Y=高音1、U=高音2（见 代码-08 的钢琴键分组）

**`startPianoLoop(skill:source:dryRun:)`（private，第 971–1014 行）**：

1. dryRun/引擎/护栏三重校验
2. `pianoStepIndex = 0` + `song = pianoSongs[0]`（**默认第一首**）+ `interval = 0.4`
3. DispatchSourceTimer（0.5s 后首音、repeating 0.4）→ 事件：
   - `idx >= totalNotes` → "🎹 \(song.name) 一轮完成，2s 后重播" + pianoStepIndex = 0 + asyncAfter(2.0) 重置（**timer 继续跑，只是暂停 2s**）
   - `control.pressGameKey(key, duration: 0.08)` + pianoStepIndex += 1
4. appendSystem "🎹 钢琴运行中：X（N 音符 × 0.4s）"

**注意**：pianoSongs 只有第一首被用（`pianoSongs[0]`）——欢乐颂/生日快乐是预留曲目（无切歌 UI/参数）。

## 八、coffee / coffee_lite / bagel_spam / tomato_juice 循环（第 1016–1166 行）

**`startCoffeeLoop(skill:source:dryRun:)`（private，第 1018–1052 行）**——自动做咖啡（**MaaNTE AutoMakeCoffee**）：**每 2s 按一次 F（交互），最多 20 轮（≈40s 制作周期）**：

1. dryRun/引擎/护栏三重校验（"✅ 自测：做咖啡链路就绪" / "❌ 按键引擎未注入" / "🎮 护栏"）
2. `coffeeIter = 0` + `maxIter = 20` + DispatchSourceTimer（1.0s 后首次、repeating 2.0）→ 事件：
   - `guard runningSkills.contains("coffee")`
   - `control.pressGameKey(.f, duration: 0.1)`——F 交互
   - `coffeeIter >= 20` → "☕ 做咖啡完成（20 轮 F 交互），自动停止" + cancel + 移除
3. appendSystem "☕ 做咖啡运行中（每 2s 按 F × 20 轮）"

**`startCoffeeLiteLoop(skill:source:dryRun:)`（private，第 1055–1089 行）**——轻量做咖啡（**MaaNTE AutoMakeCoffeeLite**）：**快速 10 轮 × 1s 的 F 交互（对应 MaaNTE make_count=10）**：

- 与 coffee 同构，差异：`maxIter = 10`、repeating **1.0**（快一倍）、首次 0.6s——"🥛 轻量做咖啡运行中（每 1s 按 F × 10 轮，快速版）"

**`startBagelSpamLoop(skill:source:dryRun:)`（private，第 1093–1130 行）**——贝果刷屏（**MaaNTE BagelSpam**）：向当前焦点聊天框输入内置文案：

- **限制（如实说明，1092 行注释）**：**macOS 版使用内置中性文案（MaaNTE 原版文本由 LLM/参数提供，需先开聊天窗口）**
1. dryRun/引擎/护栏三重校验
2. **内置文案（1109 行）**：`phrases = ["早上好呀", "今天天气真好", "贝果很好吃"]`
3. `bagelSpamIter = 0` + `maxIter = phrases.count × 2`（=6，**防止刷屏失控**）+ DispatchSourceTimer（2.0s 间隔）→ 事件：
   - `phrase = phrases[(bagelSpamIter - 1) % phrases.count]`——循环取文案
   - `control.typeText(phrase)`——**Unicode 文本注入当前焦点输入框（调用前需聊天框已打开并聚焦）**
   - appendSystem "🥯 贝果刷屏第 N/M 句：X"
   - `bagelSpamIter >= maxIter` → "🥯 贝果刷屏完成（6 句），自动停止" + cancel + 移除
4. appendSystem "🥯 贝果刷屏运行中（每 2s 输入一句内置文案 × 6 句；**需聊天框已打开并聚焦**）"

**`startTomatoJuiceLoop(skill:source:dryRun:)`（private，第 1132–1166 行）**——自动做番茄汁：

- 与 coffee 完全同构（`maxIter = 20`、2.0s 间隔、F 交互 duration 0.1）——"🍅 番茄汁完成（20 轮 F 交互），自动停止"

**四个循环技能的共同骨架**（给别的 AI 的速查）：dryRun 校验 → control/护栏校验 → 迭代计数归零 → DispatchSourceTimer（workQueue）→ 事件（guard runningSkills + 动作 + 超限停止/cancel/移除）→ resume + timer 记录 → appendSystem 运行提示。**全部有界**（轮数/时长上限）+ **全部逐轮护栏复检**（volleyball/drive_dataset 在事件里复检窗口；coffee 系在启动时检一次）+ **全部可中途停止**（runningSkills 移除即停）。

## 九、performUIClickLoop 与 performFishingLoop（第 1168–1326 行）

**`performUIClickLoop(skill:source:dryRun:)`（private，第 1175–1281 行）**——通用 UI 点击技能（自动领奖励 / 自动收家具）：

**真实链路（1168–1174 行注释）**：（可选）按入口热键开界面 → 截图 → Vision OCR 定位「领取/收取」按钮 → 鼠标点击 → 等 UI 反应后重试；**按钮消失即完成，换下一入口键**。

**入口键依据（1171–1174 行注释，诚实标注）**：
- rewards: **F4=活动页（实测✓，含「环期赠礼」签到 tab）**/ F1、F2=MaaNTE 文档的活动/环期赏令入口（**版本待实证**）
- furniture: **MaaNTE 原义=开放世界家具物（仓鼠球/棉棉/木箱），非 UI 菜单；此处保留 UI 关键词循环作兜底（面板已标注语义差异，找到即点、找不到安全停）**

**参数表（1182–1203 行）：**

| 技能 | keywords（优先级） | entryKeys | maxRounds | clickInterval |
|---|---|---|---|---|
| rewards | 一键领取/免费领取/立即领取/领取奖励/领取/签到/确认 | `[.f4, .f1, .f2]` | 6 | 1.2s |
| furniture | 一键收取/收取家具/收取/回收 | `[nil]`（**无 UI 入口，直接扫当前屏**） | 8 | 1.0s |

**流程（1219–1273 行）**：

1. 鼠标权限（"❌ 无法注入鼠标"）+ **护栏（1205–1210 行，"游戏窗口不在前台就取消——与 fishing/volleyball 同款"）** + logger（appendSystem + dlog 双写）
2. **逐入口循环（1219–1233 行）**：`guard runningSkills`（用户中断）；**切入口界面**：首个直接按，**其先 ESC 关旧界面再按新键**（0.6s 间隔）→ 按入口键 → "⌨️ 入口 N/M：按 X 开界面" → 0.9s 等界面切换
3. **逐轮点击循环（1235–1270 行）**：
   - 帧拿不到 → continue（重试）
   - **`loginAssistant.locateButton(keywords, in: cg, scale:)` 无命中** → "ℹ️ 入口 N 未找到按钮（换下一入口…/全部入口扫完）" → break（换入口）
   - dryRun → "✅ 自测：定位到「X」→ 坐标，链路就绪" + 移除 + return
   - `mouse.click(at: hit.point)` → clicked/totalClicked 累计 → clickInterval + 0.5s 等待
   - **点击后复查（1262–1269 行）**：重新截图 → locateButton == nil → "🏁 入口 N：共点击 X 次，按钮已消失（领完/收完）" + 移除 + return
4. 本入口没点任何东西 → continue 下一个入口；**收尾（1275–1280 行）**：totalClicked > 0 → "✅ 完成：共点击 N 次"；否则 "ℹ️ 未在任何入口找到按钮（可能已领完，或需手动打开对应界面）" + 移除

**`performFishingLoop(skill:source:dryRun:)`（private，第 1287–1326 行）**——自动钓鱼基础版（**MaaNTE AutoFish 核心循环移植**）：

- **真实链路**：F 抛竿 → 等收杆节奏 → F 收杆 → 再抛（**循环，最多 12 轮**）
- **说明（1283–1286 行注释，诚实标注）**：**MaaNTE 完整版带 CV 鱼漂检测；macOS 基础版按游戏节奏固定时间，真实动作 + 可中途停止，后续可接 Vision 升级**

**流程（1306–1325 行）**：`maxRounds = 12` → 逐轮：
- `guard runningSkills`（用户中断）+ **逐轮护栏复检（1311–1315 行，"游戏窗口消失，钓鱼已自动停止"）**
- **抛竿**：`control.pressGameKey(.f, duration: 0.08)` → `usleep(2.0 × 1_000_000)`（**等鱼漂落水**）
- **收杆**：F 短按（**游戏内抛竿/收杆同一键**）→ `usleep(1.0 × 1_000_000)`
- "🎣 第 N 轮：抛竿→收杆完成"
- 12 轮完 → "🏁 钓鱼 12 轮完成" + 移除

**节奏参数**：抛竿 2s 等落水 + 收杆 1s——固定时间节奏（无 CV 鱼漂检测），单轮约 3.2 秒；12 轮约 40 秒。

## 十、dodge / auto_scroll / snapshotStub / teardown（第 1328–1473 行）

**`performDodgeLoop(skill:source:dryRun:)`（private，第 1331–1367 行）**——自动闪避（**MaaNTE SoundDodge 思路移植**）：

- **真实链路**：周期性快速闪避（**空格跳跃 + Shift 疾跑闪避组合**），用于躲红圈/追踪弹；可中途停止
- `maxRounds = 20` → 逐轮：runningSkills/护栏双校验 → **闪避动作（1360–1363 行）**：`pressGameKey(.space, duration: 0.12)` + `pressGameKey(.shift, duration: 0.10)` → `usleep(0.9s)`——单轮约 1.1 秒
- "🏁 闪避 20 轮完成" + 移除

**`performAutoScroll(skill:source:dryRun:)`（private，第 1371–1411 行）**——自动滚动（**MaaNTE auto_f_scroll 移植**）：周期性 F 连点 + 鼠标滚轮向下（拾取/翻页类交互）：

- `maxRounds = 15` → 逐轮：双校验 → **F 连点 2 次（1402–1404 行）**：`pressGameKey(.f, duration: 0.06)` × 2（间隔 0.12s）→ **滚轮向下**：`mouse?.scrollWheel(lines: -3)`（**-3 行 ≈ 拾取幅度**，见 代码-09 的 scrollWheel）→ `usleep(0.5s)`
- "🏁 滚动 15 轮完成" + 移除

**`performSnapshotStub(skill:source:)`（private，第 1414–1427 行）**——**待移植技能：现场快照 + 如实回报**：

1. 快照路径 `/tmp/aurora_agent_\(skill.id).png`
2. `capture?.currentFrame` 存在 → tiffRepresentation → NSBitmapImageRep → PNG 写盘 → "已保存现场快照 X"（否则 "无快照（截屏不可用）"）
3. appendSystem "⚙️ 「X」：**该技能依赖 MaaNTE 视觉管线（Windows），macOS 原生版开发中**。\(...)——**不做假动作**" + 移除 runningSkills

**`teardown(id: String)`（private，第 1431–1473 行）**——技能收尾（stopSkill/stopAll 调用），**九个 case 分别清对应定时器与状态**：

| id | teardown 动作 |
|---|---|
| volleyball | volleyballTimer cancel + nil |
| touch | touchTimer cancel + nil + touchLoopCount = 0 |
| drive_dataset | driveDatasetTimer cancel + nil + **recordEngine?.stop() + flushSync()**（等 meta.json 落盘） |
| piano | pianoTimer cancel + nil + pianoStepIndex = 0 |
| tomato_juice / coffee / coffee_lite / bagel_spam | 各自 timer cancel + nil + 迭代计数归零 |
| auto_login | **loginWatchTimer cancel + nil + loginWatchAttempts = 0**（守护定时器一并清） |
| default | 无（快照类无定时器） |

- **收尾兜底（1471–1472 行）**：`control?.releaseAllGameKeys()`——**停止时释放所有按键（防角色卡住）**——无论哪个技能停止，都清一次合成按键状态

**AIAgentPanel 逻辑层文档至此完整**（1–1604 行：数据模型 → 技能清单 → SkillCenter/LLM → 依赖注入 → 统一入口 → 全部技能实现 → teardown）。剩余 1605–2639 行是自测（AgentSelfTest）与 UI 视图（AIAgentEdgeTab/AIAgentPanelView），见单元十一/十二。

## 十一、AgentSelfTest 自测（第 1606–1739 行）

**`AgentSelfTest`（enum，第 1609 行）**——AI Agent 组件自测（`--agent-selftest` CLI 入口）：验证 OCR→坐标链路、指令解析、技能路由。`run(center:)` 打印 PASS/FAIL 并 `exit(fail == 0 ? 0 : 1)`。

**测试组（1611–1733 行）：**

| 组 | 内容 | 判定 |
|---|---|---|
| 1–3 | 指令解析：登录/排球/停止 | runningSkills 命中 / stopAll 清空 |
| 3.5 | UI 点击型技能路由（**dryRun：只验证链路不真点**）：领奖励/收家具/滚动 | messages 含 "命中技能" + 技能名 |
| 3.7 | **新移植技能路由（dryRun）**：抚摸/咖啡/轻量咖啡/番茄汁/钢琴/钓鱼/闪避/数据集/挂机/贝果 | 同上（10 个技能逐一验证路由） |
| 3.6 | **AgentLoop 端到端规划（复合任务）**：`sendUserMessage("先登录然后再领奖励")` | messages 含 "端到端规划"（isComplexTask 顺序词判定触发） |
| 4 | **人类点击同一通道**：`toggleSkill("auto_login", source: .human)` | runningSkills 或自测消息 |
| 5 | 键盘技能注入存在性 | `controlEngineAvailable()` |
| 6 | **ported 一致性①**：ported==true 的技能必须有 execute case | `unimplementedPorted.isEmpty`（漏标检测） |
| 7 | **ported 一致性②**：ported==false 的技能应走 snapshotStub | `wronglyPorted.isEmpty`（错标检测） |

- **knownImplemented 集合（1719 行）**：`["auto_login","rewards","furniture","fishing","volleyball","dodge","auto_scroll","touch","drive_dataset","preset_afk","piano","coffee","coffee_lite","tomato_juice","bagel_spam"]`（15 个有 execute case 的技能）——一致性①②用它双向校验：**漏标（ported=true 但无 case）与错标（ported=false 但有 case）都会被抓**
- **dryRun 用法**：`center.isDryRun = true` 包住整组路由测试 → stopAll → `isDryRun = false`——路由验证不真点/不真按键
- 汇总：`[AGENT-SELFTEST] 汇总: PASS=N FAIL=M` + `exit(fail == 0 ? 0 : 1)`

**`controlEngineAvailable()`（extension，第 1737–1739 行）**：`control != nil`——引擎注入存在性（自测用）。

## 十二、UI 视图：EdgeTab / 面板 / 设置 Sheet / 技能按钮（第 1741–2434 行）

**`AIAgentEdgeTab`（struct: View，第 1747–1796 行）**——屏幕最左缘的小箭头（常驻，点击展开/收回 AI 面板）——**与右侧 Sidebar 完全独立：各自开关互不影响**：

- `@Bindable var center` + `panelWidth: CGFloat` + `@State hovering`
- 点击：`center.isPanelOpen.toggle()`（spring 动画 0.45/0.68）；箭头 `rotationEffect(.degrees(isPanelOpen ? 180 : 0))`——展开时翻转 180°
- **箭头跟随面板位置（1790–1793 行注释）**："**收起贴屏幕左缘，展开移到面板右侧边缘**（面板是 HStack 首元素占 348pt，箭头不能叠在面板上）"——`.offset(x: isPanelOpen ? panelWidth : 0)` + `.zIndex(20)`

**`AIAgentPanelView`（struct: View，第 1798–2171 行）**——AI Agent 面板（**左侧滑出，占屏约 1/4，独立开关**）：

**状态（1802–1811 行）**：columns（3 列 GridItem）、draftText/showModelPicker/showSettings、liveModels（**真实模型清单，从 API /models 拉取；空 = 未拉到，菜单显示当前模型兜底**）、showUnportedSkills（**技能网格是否显示「待移植」技能——默认隐藏，降低视觉噪音；用户反馈"太乱了没法用"**）。

**body 布局（1813–2009 行，自上而下）**：

1. **头部**：🤖 图标 + "AI AGENT" 标题 + 状态点（runningSkills 空=青色，非空=橙红）+ 副标题（"空闲 · model" / "运行中 · runningNames"）+ 设置按钮 + 收起按钮；appeared 入场动画（offset -24→0）
2. **一键自动化按钮（1884–1914 行）**：`center.toggleSkill("preset_afk", source: .human)`——"⚡️ 一键自动化挂机 领奖励·收家具·钓鱼"；运行中变 "⏸️ 一键自动化运行中（点击停止）"（青→danger 配色）
3. **技能网格（1916–1927 行）**：`LazyVGrid(columns: 3)` × `showUnportedSkills ? all : all.filter { ported }`——**默认只显示已实现技能**；`AgentSkillButton(skill:active:action: toggleSkill(skill.id, source: .human))`——**人类点 = AI 也能调，同一通道**
4. **待移植显示开关（1931–1942 行）**："显示待移植技能（N）"（默认隐藏，用户可展开）
5. **对话区**：`AgentConversationView`（单对话，无历史列表）
6. **输入区**：`agentInputArea`
7. **底部**：新建对话按钮 + 状态条（messages.last 前 28 字符）
- `.frame(width: 348)` + 黑底 + 右缘发光分隔线 + `.onAppear`：appeared 动画 + `center.fetchLiveModels { liveModels = ids }`（**失败静默**）

**`agentInputArea`（第 2017–2164 行）——输入区三行：**

1. **配置状态条（2020–2057 行）**：**未配置时醒目 CTA 直达设置（小白友好，一键配模型）**——"未配置模型 · 点我填写 API Key 启用 AI 指令"（orangeRed）→ showSettings；**已配置显示就绪**——"AI 已就绪 · model" + "配置"小按钮
2. **输入框（2059–2089 行）**：TextEditor（62 高，placeholder "给 AI 下达指令，或直接输入技能名…"）+ 发送按钮（`sendDraft()`——draftText 清空 + `sendUserMessage(text, source: .human)`；空禁用）
3. **第二行（2091–2159 行）**：**模型 Menu（真实模型清单替换原硬编码假列表）**——liveModels 逐项（点击切换 model + 写 UserDefaults + appendSystem "模型已切换"；**空清单显示"⚠️ 未拉到模型列表（API Key 未配置或网络不可用）"**）+ Divider + 刷新 + 自定义配置；**思考深度滑块（2142–2157 行）**：Slider 1...4 step 1 → aiSettings.thinkingDepth（**直接驱动真实 API 的 temperature**）+ "低/中/高/Max" 标签
- `.sheet(isPresented: $showSettings) { AgentSettingsSheet(center:) }`

**`sendDraft()`（第 2166–2170 行）**：取 text → 清空 → sendUserMessage（**source: .human**）。

**`AgentSettingsSheet`（struct: View，第 2175–2282 行）**——AI 配置 Sheet（NavigationView + Form）：

| Section | 内容 |
|---|---|
| API 配置（本地小本本存储） | API Key TextField（`textContentType(.password)` + monospaced + autocorrectionDisabled）+ **"存储在本地小本本文件（0600），不再访问钥匙串"** |
| 端点 & 模型 | Base URL / Model TextField + 思考深度 Picker（segmented 4 档） |
| **AI 规划（弱模型防线 8 熔断）** | **"复位 AI 规划熔断（恢复 LLM 规划）"按钮 → `AgentLoop.shared.resetLLMDowngrade()`** + 说明文字（"连续失败 3 次自动降级为本地规则模式（零幻觉），降级日志见面板，可随时手动恢复"） |
| 快速填充（示例配置） | **4 个预设按钮：Agnes（当前默认，agnes-2.5-flash）/ DeepSeek / OpenAI（gpt-4o-mini）/ Anthropic Claude（claude-3-5-haiku-20241022）**——**已填的 API Key 会保留**（`apiKey: center.aiSettings.apiKey` 透传，不抹掉） |

- **保存（2268–2277 行）**：`try center.aiSettings.save()` → "✅ API Key 已保存（本地小本本，不再访问钥匙串）" + dismiss；**`.disabled(apiKey.isEmpty)`——空 key 不许保存**；失败 "❌ 保存失败"

**`AgentSkillButton`（private struct，第 2285–2342 行）**——技能按钮（人类点击 = 启动/停止；AI 指令走同一执行通道）：

- emoji（hover 发光）+ name + **`if !skill.ported { Text("待移植") }` 灰色标签** + 状态点（active=青 / **warn=danger 红** / 普通=白 0.15）
- hover/active 背景 + RadialGradient + 描边 + help（"X（点击启动/停止）" / **"X（待移植，点击会报告当前状态）"**）

**`AgentConversationView`（private struct，第 2345–2368 行）**——对话视图（单对话流，ScrollViewReader + LazyVStack）：`onChange(of: messages.count)` 自动滚到底（easeOut 0.2）。

**`AgentBubble`（private struct，第 2371–2434 行）**——单条消息气泡：

- **三角色配色**：user（右对齐，textPrimary + cyan 0.10 填充）/ assistant（左对齐，cyan）/ system（textSecondary + 白 0.04）
- 头部：HH:mm:ss 时间 + source（👤/🤖）+ 正文（11.5pt，textSelection 可选中）

## 十三、AgentUIShot 无头渲染与 GameWindowDetector（第 2436–2639 行）

**`AgentUIShot`（enum，第 2443 行）**——UI 无头渲染自测（`--agent-ui-shot`）：

**用途（2437–2441 行注释）**：用 SwiftUI **ImageRenderer** 把 AIAgentPanelView 直接渲染成 PNG 存到 `/tmp/aurora_ui_shot.png`，用于验证真实布局——**完全无头、无屏幕权限依赖、不影响桌面**。**与 `--agent-selftest` 互补：后者验证逻辑链路，前者验证视觉呈现**。

**`run(delay: TimeInterval = 1.0)`（@MainActor，第 2447–2456 行）**：Task 延迟 1s（等面板渲染稳定）→ `renderPanel(to:)` → `print("[UI-SHOT] saved=... path=...")` + `fflush(stdout)` + **`exit(ok ? 0 : 1)`**——渲染失败以退出码 1 表达。

**`renderPanel(to:)`（private @MainActor，第 2460–2501 行）**：

1. **注入示例数据（2462–2473 行）**：4 条示例会话（system/user/system/assistant——覆盖全部角色配色）+ `runningSkills = ["volleyball"]`（验证运行中状态点/副标题）——"让渲染内容更充分"
2. **渲染整个面板（2476–2486 行）**：`AIAgentPanelView(center:).frame(width: 348, height: 880).background(Theme.bgPure).preferredColorScheme(.dark)` + `ImageRenderer` + **`scale = 2.0`（@2x，验证 Retina 布局）**
3. nsImage → tiff → NSBitmapImageRep → PNG 写盘；失败打印原因 false（"ImageRenderer 渲染失败"/"转 PNG 失败"/"写文件失败"）

**`runLayoutCompare()`（@MainActor，第 2506–2604 行）**——**布局对比自测：折叠 vs 展开两帧并排，验证「往外扩展」语义**（展开时 AI 面板占左 348pt，主 UI 右移；箭头移到面板右侧边缘）：

1. 注入示例数据（2 条会话，runningSkills 空）
2. **主 UI 占位（2518–2532 行）**：色块标注区域（"真实 ContentView 无法无头渲染 DriveState"）——GAME VIEWPORT（"主 UI，右移后保持可见"）+ SIDEBAR 360pt 占位
3. **帧 A：折叠（2538–2549 行）**：HStack——AIAgentEdgeTab（panelWidth: 348，箭头贴最左，offset 0）+ mainPlaceholder（frameW-360）+ sidebarPlaceholder（360）
4. **帧 B：展开（2552–2568 行）**：HStack——AIAgentPanelView（占 348，**真实面板**）+ AIAgentEdgeTab（**offset x: -22——对齐到面板右缘（348 - 22/2 附近）**）+ mainPlaceholder（frameW-360-348）+ sidebarPlaceholder；`center.isPanelOpen = true`（让面板内箭头旋转状态正确）
5. **上下两帧并排渲染（2571–2604 行）**：VStack + 标注文字 → ImageRenderer scale 2.0 → `/tmp/aurora_layout_compare.png` → `exit(0)`

**`GameWindowDetector`（enum，第 2617 行）——游戏窗口检测（自动登录的安全护栏）：**

**为什么必须有它（2610–2615 行注释，本文件的灵魂）**：自动登录守护是全屏 OCR，会把屏幕上所有文字都识别一遍。**如果没有这道护栏，浏览器、QQ、甚至 DSH 自己窗口里的「登录」二字都会被当成游戏登录按钮点掉——那是灾难**。只有确认屏幕上存在【异环/NTE】游戏窗口时，才被允许执行任何鼠标点击。

```swift
static func isGameVisible() -> Bool {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    for w in windows {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let name  = w[kCGWindowName as String] as? String ?? ""
        // 异环 NTE：窗口标题或进程名含「异环 / NTE」即命中
        // （NTE 全大写的窗口层名，owner 可能是 launcher 进程）
        let hit = owner.contains("NTE") || owner.contains("异环")
               || name.contains("NTE") || name.contains("异环")
        if hit { return true }
    }
    return false
}
```

- **实现**：`CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)`——只看**在屏**窗口；owner/name 双字段匹配「NTE」或「异环」
- **无屏幕权限时**：CGWindowListCopyWindowInfo 返回空/权限受限列表 → 返回 false（保守判定 = 不点击）——**这保证权限被拒时技能安全取消而非乱点**
- **调用方**：AIAgentPanel 的全部真实动作技能（performAutoLogin/volleyball/touch/drive_dataset/preset_afk/UIClickLoop/fishing/dodge/auto_scroll——**每个技能启动前 + 循环事件里逐轮复检**）

**AIAgentPanel 文档至此完整**（2639 行全覆盖：数据模型 → 技能清单 → SkillCenter/LLM → 依赖注入 → 统一入口 → 16 个技能实现 → teardown → 自测 → UI 视图 → 无头渲染 → GameWindowDetector）。