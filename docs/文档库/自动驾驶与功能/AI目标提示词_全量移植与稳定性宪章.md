# AuroraDrive 目标模式提示词（超详细·全量版）
# 用途：粘贴进 DSH 目标模式（Goal Mode），长时间自主执行
# 版本：v3.2 会话交接版（2026-09-14：全项目深度核对 + API 实测 + 25 项移植清单核实 + 上下文交接）
#
# 【2026-09-19 状态标注】本提示词驱动的 4 个稳定性缺陷修复 + 全量移植任务已执行完毕（PASS=21 自测，15 已移植 + 3 待移植，
# 详见 docs/最终报告.md、docs/PROGRESS.md、docs/ai-agent-panel.md）；git 现 HEAD 7b7d2db（BidKing PR#434 已提取至独立
# 文件夹 BidKing_PR434/）。磁盘清理后 data/web_frames、build/vid_*.mp4 等已移至外置硬盘 删除_20260919 目录。
# 第 -2/0/4 章等正文仍按 2026-09-14 时点书写（历史输入文档），与现状冲突时以最终报告 + 上述目录实际状态为准。
#
# 【章节导航】
#   第 -2 章  会话交接摘要 —— ★新对话第一件事就读这个★（上一个对话的全部上下文）
#   第 -1 章  强制执行协议 —— 动手前必须过的四道门（读→想→写→验）
#   第  0 章  事实档案 —— 项目规模/架构/行号/命令（唯一真相源）
#   第  1 章  目标 —— 完整目标陈述（防跑偏）
#   第  2 章  稳定性宪章 —— 4 个已确证缺陷 + 怎么避免（最高优先级）
#   第  3 章  防"脑子一抽"协议 —— 证据规则/禁止事项/歧义自决
#   第  4 章  任务清单 —— 阶段0基线 / 阶段1修缺陷 / 阶段2移植25项 / 阶段3验收
#   第  5 章  验收标准 —— 13 条硬性标准
#   第  6 章  工作循环 —— 每轮照此执行
#   第  7 章  扩展指南 —— 以后怎么加技能/模型/UI
#   第  8 章  交付物 —— 最终报告的 6 个部分
#   第  9 章  最后的话
#   第 10 章  API 凭证与测试手册 —— 凭证 + 11 模型 + 3 条测试路径 + 8 项矩阵
#   第 11 章  快速开始 —— 复制粘贴就能跑
#   第 12 章  弱模型容错架构 —— 10 道防线（防 Agnes 突然炸掉）
# ============================================================================
#
# ⚠️⚠️⚠️  本文件含明文 API 凭证，严禁外传  ⚠️⚠️⚠️
#   1. 禁止 git add / git commit 本文件（已加入 .gitignore 保护）
#   2. 禁止把本文件内容粘贴到任何公开渠道
#   3. 报告/日志里引用 key 时一律用掩码 sk-ZVb…uSSb
#   4. key 允许存在：本文件（供你测试用）+ 项目根 `.llm-key-notebook.md`（gitignored）+ 运行时小本本
#      `~/Library/Application Support/AuroraDrive/llm-key-notebook.txt`（0600）。macOS Keychain 自 1b06802 起已整体移除（0 钥匙串访问）
# ============================================================================

你即将接手一个**已上线运行、用户日常在用**的 macOS 自动化项目。你写的每一行代码都
可能影响用户游戏时是否被乱点、是否卡死、是否崩溃。因此本提示词的第 2 章（稳定性
宪章）优先级高于第 4 章（任务清单）——**任务做不完可以，稳定性出问题不行**。

================================================================================
# 第 -2 章  会话交接摘要 ★新对话必须先读这一章★
================================================================================

> **这一章是"上一个对话的完整上下文快照"。**
> 用户开了一个新对话来继续这项工作。你（新对话里的模型）**没有**上一个对话的记忆，
> 所以这一章把**所有已经确认的事实、已经踩过的坑、用户的原话要求**都写在这里。
>
> **阅读规则**：
> - 这一章里写的都是**已经验证过的事实**，**不要重新验证**（省时间）
> - 这一章里写的**坑**，是**真的踩过**的，别再踩一遍
> - 读完这一章 → 读第 -1 章（强制执行协议）→ 就可以直接开工

## -2.1 这次对话到底做了什么（时间线）

**背景**：用户有个 macOS 应用 `AuroraDrive`（在 `/Users/dupi/Desktop/自动驾驶系统`），
是一个游戏自动化工具（用于游戏「异环 / Neverness to Everness」）。用户要给它加一个
**AI Agent 面板**，让 AI 能通过自然语言指挥游戏自动化技能。

**这次对话完成的事（按顺序）**：

1. **把 AI Agent 面板做进了真实 app UI**
   - 面板在窗口**左侧**，向外扩展（主 UI 右移，不遮挡网络地图）
   - 用户原话："我想要的是往外扩展的，是往那个左手边扩展的，而不是往里边停的"
   - 对应 commit：`c65189d`（**这是已验证的稳定基线版本**）

2. **选定技术路线：零框架原生 Tool-Calling**
   - 用户明确选择：不用任何第三方 Agent 框架，自己写
   - 成果：`Sources/AuroraDrive/AgentLoop.swift`（227 行）
   - 结构：`AgentToolCall` / `AgentToolResult` / `protocol AgentPlanner` /
     `MockLLMPlanner`（离线关键词规则）/ `RealLLMPlanner`（云端 LLM）

3. **接入真实云端 LLM 并实测通过**
   - 用户提供了凭证：`agnes-2.5-flash` @ `https://api.agnes-ai.cn/v1`
   - 本次对话**实测验证**：基础对话 ✅、Tool-Calling ✅、11 个可用模型 ✅
   - 配置存入 Keychain（service `com.aurora.drive.aiagent` / account `apiKey`）
   - 用户要求：**不能硬编码 key 进源码**（"不能让别人白嫖我的额度"）

4. **修了 3 个 LLM 相关 bug**（这次对话中修的）
   - baseUrl 双 `/v1` 拼接 → 加了归一化
   - tools 定义缺 `parameters` 字段 → agnes 返回 400 → 补上
   - 思考深度原本只有 2 档 → 用户要求 4 档（Low/Mid/High/Max）→ 改为 1/2/3/4

5. **发现致命死锁 → 用户震怒 → 决定冻结架构**
   - `--agent-llm-test` 用「主线程信号量 + Task」导致**永久卡死**
   - 用 `sample <pid>` 抓到现场：主线程卡在 `semaphore_wait_trap`，
     协作线程池全空闲，Task 闭包**从未执行**
   - 用户原话："你不考虑稳定性直接拿这玩意儿跑跑，你是想让我的程序全部飞起来对吧？"
   - 用户决策：**"我是不接受任何改变整体架构的方式…必须极致稳定"**
   - → 停止写代码，转为**共同设计这份目标模式提示词**

6. **深度核对整个项目**（这次对话做了 3 轮核对）
   - 核对了 31 个 Swift 文件 / 18,169 行
   - 核对了 MaaNTE 目录：86 个 py / 45 个 CustomAction / 25 个任务
   - 核对了构建部署链路（`run.sh` 真实行为）
   - 修正了 2 处行号错误（`GameKey` 在 `:233` 不是 `:281`）
   - **发现第 4 个缺陷**：`ported` 默认值 `true` 导致 4 个未实现技能被误标为"已实现"

7. **产出这份提示词文档**（就是你现在读的这份）
   - 用户要求："你要非常详细写提示词非常详细，确保模型不会脑子一抽"
   - 用户要求："无论多长无所谓"
   - 用户要求："稳定性是最高基础，而且不能只是一句一句稳定是最高基础，
     而是怎么才能避免稳定性出问题"
   - 用户要求："还有用电脑操作插件测试"
   - 用户要求："把所有就是 MAA 功能也给移植过来"
   - 用户要求："写代码前必须先深度阅读这一部分的模块"→ 第 -1 章门禁 1
   - 用户要求："必须先阅读，然后再深度思考，思考完之后才能干活"→ 门禁 1/2
   - 用户要求："一定要给他限制住，让他写出来代码极度好"→ 门禁 3/4
   - 用户要求：把 API 各种信息也给模型，"你不给他怎么测试？"→ 第 10 章

**这次对话没做的事**：
- 阶段 1 的 4 个缺陷修复 → **还没修**（这是你接手后的第一件事）
- 阶段 2 的 19 项技能移植 → **一项都没做**
- 阶段 3 的电脑操作验收 → **还没做**
- 上述都是**待办**，不是"已完成"

## -2.2 用户的原话要求（逐条保留，一条都不能漏）

| # | 用户原话（节选）| 已落到文档哪里 |
|---|---|---|
| 1 | "我想要的是往外扩展的，是往那个左手边扩展的，而不是往里边停的" | 第 1.5 节（不改布局）|
| 2 | "我是不接受任何改变整体架构的方式" | 第 2.2 节（架构冻结清单）|
| 3 | "必须极致稳定" | 第 2 章（稳定性宪章，含具体机制）|
| 4 | "稳定性是最高基础，而且不能只是一句一句稳定是最高基础，而是怎么才能避免稳定性出问题给我写" | 第 2.3-2.7 节（4 个缺陷 + 编码规范 + 护栏 + 部署规范 + 强制流程）|
| 5 | "你把所有就是 MAA 功能也给移植过来" | 第 4 章阶段 2（25 项清单）|
| 6 | "还有用电脑操作插件测试" | 第 4 章阶段 3（8 项走查）|
| 7 | "写代码前必须先深度阅读这一部分的模块" | 第 -1 章门禁 1（阅读证据 8 项）|
| 8 | "必须先阅读，然后再深度思考，思考完之后才能干活" | 第 -1 章门禁 1 + 门禁 2（思考 8 问）|
| 9 | "一定要给他限制住，让他写出来代码极度非常非常好" | 第 -1 章门禁 3 + 门禁 4 + 12 条约束 |
| 10 | "那个小模型太蠢了" | 第 12 章（弱模型容错架构，10 道防线）|
| 11 | "他的那个 API 各种也要给他给模型，让他来测试，你不给他怎么测试？" | 第 10 章（凭证 + 11 模型 + 3 路径 + 8 项测试矩阵）|
| 12 | "不能找我"（不要来问我） | 第 3.4 节（歧义自决规则）|
| 13 | 只做本地 git，"不许 push" | 第 1.5 节 + 第 5 章验收第 11 条 |
| 14 | "项目以后怎么扩展什么都要写" | 第 7 章（扩展指南）|
| 15 | "你（目标）就这么一点目标模型脑子一 OK 又忘了目标也给我写全" | 第 1 章（完整目标陈述）+ 第 -1 章约束第 10 条（每轮回头看一眼目标）|
| 16 | 思考深度不能只有两档："思考深度不应该封分为 Max 和 Haig，还有还有 low" | 已改为 4 档（第 10.4 节 temperature 映射）|
| 17 | 关于"车子"：**"那个车子并不是什么导航类功能，而是那个驾驶"** | 第 4 章 2.4 节（B 类 = 自动驾驶数据集采集，**不是导航**）|

## -2.3 已确认的项目事实（不要重新验证，直接用）

### 项目与代码
- 路径：`/Users/dupi/Desktop/自动驾驶系统`
- 源码：`Sources/AuroraDrive/`，**31 个 Swift 文件 / 18,169 行**
- 当前 git HEAD：`5776c38`
- **稳定基线 commit：`c65189d`**（面板往外扩展布局，已验证稳定）
- 最近 6 个 commit：
  ```
  5776c38 docs: 更新AgentLoop架构/安全配置流程/技能清单(7个真实)+文件地图
  dce7c95 feat(AI面板): 原生Tool-Calling端到端AgentLoop + 云端LLM接入 + 安全配置
  c65189d fix(AI面板): 面板改为'往外扩展'布局(主UI右移, 不遮挡网络地图)  ← 稳定基线
  1ce1cfc docs: AI Agent 面板架构与开发文档
  73ab26f fix(AI面板): 修复登录守护误停 + 自动登录与 UI 解耦 + stdout 行缓冲
  4f09bea feat(AI面板): 自动领奖励/自动收家具升级为真实技能（OCR 点击循环）
  ```

### 工作区状态（截至交接时刻）
```
 M .dsh-edit-review.json          （工具产生的元数据，无意义）
 M .gitignore                      （本次对话加的：忽略含凭证的提示词文件）
 M Sources/AuroraDrive/AIAgentPanel.swift
 M Sources/AuroraDrive/AuroraDriveApp.swift
?? docs/MAA深度文档_功能篇.md       （未跟踪，本次对话生成）
?? docs/MAA深度文档_架构篇.md       （未跟踪）
?? docs/MAA深度文档_扩展篇.md       （未跟踪）
```

### ⚠️ 部署不同步问题（待修，验收第 10 条）
```
裸二进制  AuroraDriveUI                              5,220,824 字节  Sep 14 21:17
.app 内   AuroraDriveUI.app/Contents/MacOS/…         4,334,752 字节  Sep 13 14:58
md5: fe77609e3ff4e7fad85b4eb54a8deb3a  vs  6dcf5e9ea8b5007c81dda752dc509edc
```
→ **`.app` 里是 9/13 的旧版本**。`./run.sh` 会同时更新两个目标，跑一次即可同步。

### 构建 / 部署 / 自测
```bash
# 编译（开发用）
/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch

# 部署（用户日常用，走这个）
./run.sh      # rm -rf .build → build → codesign → 原子替换 → 双目标 → open

# 自测（需 GUI，1.2s 延迟）
./AuroraDriveUI --agent-selftest      # 基线 PASS=9 FAIL=0
```

### 进程卫生（重要）
- 测试前必须 `pkill -9 -f "AuroraDrive"`
- 有残留实例时会打印「已有 AuroraDrive 实例在运行」，且自测**静默 exit 0 无输出**

### LLM 配置（已实测可用）
| 项 | 值 |
|---|---|
| API Key | `sk-ZVbxX8ItZyV9n04XDvBshFlVGWKbfRl0Y2concpzmfA5uSSb` |
| Base URL | `https://api.agnes-ai.cn/v1` |
| Model | `agnes-2.5-flash`（默认）|
| Keychain | service=`com.aurora.drive.aiagent`, account=`apiKey` |
| UserDefaults | suite `com.aurora.drive.aiagent`（baseUrl/model/thinkingDepth）|

### MaaNTE 参考源（只读）
- 路径：`MaaNTE/`（已在 `.gitignore` 里，不入库）
- **86** 个 action `.py` / **45** 个已注册 CustomAction / **25** 个任务 JSON
- **25 个可执行项**（23 任务 + 2 预设），详见第 4 章 2.2 完整对照表
- ⚠️ `interface.json` 含 `//` 注释，**不是合法 JSON**，用 grep/sed 读

## -2.4 已发现的 6 个缺陷（含证据 · 都要修）

### 稳定性缺陷（4 个）

**① `--agent-llm-test` 死锁**（用 `sample` 已确证）
- 位置：`AuroraDriveApp.swift` 的 launcher `main()` 里 `--agent-llm-test` 分支
- 证据：`sample <pid>` 显示主线程卡在 `semaphore_wait_trap`，协作线程池全空闲
  （`__workq_kernreturn`），Task 闭包从未执行；日志文件 25 秒后仍 0 字节
- 修法：改**纯同步 HTTP + 30s 硬超时**，或全程 async/await

**② GUI 主链路同型死锁**
- 位置：`AIAgentPanel.swift:922`（`DispatchSemaphore(value: 0)`）/ `:930`（`semaphore.wait()`）
- 在 `sendUserMessage` 的复合任务分支里
- 后果：**workQueue 是串行队列**，一旦卡死 → 后续所有技能点了没反应
  （不冻结 UI，但静默废掉整个面板，更危险）
- 修法：改 `Task { }` 全程 async/await + `MainActor.run` 更新 UI

**③ 网络请求无超时**
- 位置：`AIAgentPanel.swift:313`（`callLLM`）与 `:370`（`plainAnswer`）
- 都是 `URLSession.shared.data(for:)`，默认超时 60s
- 修法：专用 `URLSession` + `timeoutIntervalForRequest = 30`

**④ `ported` 默认值导致标记错误**（本次核对新发现）
- 位置：`AIAgentPanel.swift:57` — `var ported: Bool = true`
- `coffee`/`pinkpaw`/`piano`/`rhythm` 没写 `ported`（`:161 :163 :169 :171`）
  → 它们 `ported == true`，但 `execute()` 没 case → 走 `default: performSnapshotStub()`
- 后果：UI tooltip（`:1566`）显示"点击启动/停止"（骗用户）；待移植角标（`:1530`）不显示
- 修法：**默认值改 `false`**（已实现的 7 个都显式写了 `true`，不会误伤）

### 弱模型缺陷（2 个 · 详见第 12 章）

**⑤ 系统提示词与协议打架**
- 位置：`AIAgentPanel.swift` 的 `callLLM` 系统提示词
- 内容写着"返回 JSON 数组，每个元素包含 skillID 和 args"
- 但代码用的是 **tool calling**（`tools` 字段 + `tool_calls` 解析）
- 后果：**这是 Agnes"指令遵循差"的直接原因**——提示词让它输出 JSON 文本，
  协议却期待工具调用，弱模型必然困惑/发散
- 修法：改成极简 tool calling 提示（见第 12.2 防线 1）

**⑥ `AgentLoop` 校验不严**
- 位置：`AgentLoop.swift:133`
- 只检查 `AgentSkillLibrary.all.contains(where: { $0.id == call.skillID })`（存在性）
- **没检查 `ported`** → 模型可以调用未移植技能
- 修法：补三重校验（存在 + 已移植 + 未在运行）

## -2.5 已经踩过的坑（血泪教训 · 别再踩）

| # | 坑 | 后果 | 教训 |
|---|---|---|---|
| 1 | **用 `sed` 做多行插入/范围删除** | **静默摧毁了一个 tool-call 解析代码块**（代码结构被破坏，且没报错）| 改 Swift 一律用 edit 工具，**绝不用 sed** |
| 2 | `run.sh` 用 `.build/release`，但手动编译用了 `--scratch-path .build/scratch` | 路径不一致，run.sh 以为自己有新产物 | 编译产物路径要分清：开发用 scratch，部署用 run.sh |
| 3 | **用普通 `cp` 覆盖正在运行的二进制** | 内核按需分页 → 新旧页混合 → CDHash 校验失败 → **SIGKILL** | 必须用**原子替换**：`cp tmp && mv -f`（run.sh 里已实现）|
| 4 | `.app` 内二进制与裸二进制**不同步** | 跑的是旧版本，改了代码"没生效" | 部署后必须 `md5` 比对两个目标 |
| 5 | 有残留实例时跑自测 | 打印「已有 AuroraDrive 实例在运行」后**静默 exit 0 无输出** | 测试前先 `pkill -9 -f AuroraDrive` |
| 6 | 把 CLI flag 放在 `ContentView.onAppear` | 需要完整 GUI 启动才能触发 → **挂住** | 启动期 CLI flag 必须放 launcher `main()`（`--set-llm-config` 就是这样修好的）|
| 7 | 用 `json.load()` 读 `interface.json` | `JSONDecodeError`（文件含 `//` 注释）| 用 grep/sed 文本解析，或 JSON5 |
| 8 | 用 `swiftc` 做临时编译验证 | 被沙箱阻止 | 用 Python/PIL 或直接跑构建好的二进制 |
| 9 | tools 定义里漏 `parameters` 字段 | agnes 返回 HTTP 400 `missing field 'parameters'` | 每个 function 必须有 `"parameters": {"type":"object","properties":{}}` |
| 10 | baseUrl 末尾再拼 `/v1` | 变成 `/v1/v1/chat/completions` → 404 | 归一化：已含 `/v1` 就不再拼 |
| 11 | Vision OCR / `vision_describe` 被限流 | `VISION_RATE_LIMITED` | 同一轮内不要reworded重试，等下一轮或换手段 |
| 12 | 凭记忆写行号 | 本次核对发现 `GameKey` 写 `:281` 实际 `:233` | **行号必须来自真实 read/grep 输出**（第 -1 章门禁 1 就是为这个）|

## -2.6 用户沟通注意事项（语音转写错误对照表）

用户的输入是**语音转写**，经常出错。以下是本次对话中已确认的对照：

| 转写结果 | 真实含义 |
|---|---|
| "驾驶证" | "这" 或 "驾驶" |
| "Haig" / "嗨格" | High |
| "封分为" | 分为 |
| "M A" / "M AAA" / "M AA" | MaaNTE |
| "遗址" | 移植 |
| "价格" | 架构（语境相关）|
| "车子" | 自动驾驶数据集采集功能（**不是导航**）|
| "不能找我" | 不要问用户问题 |
| "纹纹" | 文体/文字/形式 |
| "小孩着" | 然后再 |
| "回家跟我说" | 回头跟我说 |
| "指标对话给我" | 直接贴到对话里 |

**当遇到无法理解的转写时**：结合上下文推断，**不要问用户**（用户明确禁止提问），
按第 3.4 节规则自决并在报告里记录。

## -2.7 当前进度（做到哪了）

| 阶段 | 状态 | 说明 |
|---|---|---|
| 阶段 0 基线复核 | ⏳ **没做** | 本次对话做了非正式的核对，但没有产出正式报告 |
| 阶段 1 修 4 个缺陷 | ❌ **没做** | 一项都没修 |
| 阶段 2 移植 19 项 | ❌ **没做** | 一项都没移植 |
| 阶段 3 电脑操作验收 | ❌ **没做** | 没做过 |
| 提示词文档 | ✅ **已完成** | 就是你现在读的这份 |

**⚠️ 重要：这份文档本身是"计划"，不是"成果"。** 上面所有阶段都还没执行。

## -2.8 下一步从哪继续（接手后按顺序做）

```
第 1 步：跑第 4 章「阶段 0 基线复核」，把实测数字写进报告
        （对比本摘要的 -2.3 节，不一致的地方标出来）

第 2 步：修第 -2.4 节的 4 个稳定性缺陷（阶段 1）
        - ① --agent-llm-test 死锁 → 改纯同步 + 30s 超时
        - ② AIAgentPanel.swift:922/930 信号量 → 改 async/await
        - ③ AIAgentPanel.swift:313/370 超时 → 改专用 URLSession
        - ④ AIAgentPanel.swift:57 ported 默认值 → 改 false
        每修完一个：编译 → 自测 → 提交

第 3 步：跑第 10.6 节的 API 测试矩阵（8 项），验证 LLM 链路真实可用

第 4 步：按第 4 章 2.2 对照表逐项移植 19 项
        从最简单的 touch 开始（练手验证模式）
        每个技能：读 MaaNTE 源码 → 编译 → 自测 → 提交

第 5 步：修第 -2.4 节的两个弱模型缺陷（第 12 章防线 1/3）

第 6 步：第 4 章「阶段 3」电脑操作验收（8 项走查，用 computer-use 技能）

第 7 步：输出第 8.3 节格式的最终报告
```

## -2.9 一句话总结（如果上面都没记住，记住这句）

> **这是一个用户每天在用的游戏自动化工具。稳定性 > 完成度。**
> **19 项技能还没移植，4 个缺陷还没修。**
> **动手前先读代码（门禁 1），想清楚（门禁 2），再改（门禁 3），改完必须验证（门禁 4）。**
> **不许问用户。不许碰架构冻结清单。只本地 git。**

================================================================================
# 第 -1 章  强制执行协议 ★最高优先级★（动手前必须过四道门）
================================================================================

> 这一章**先于所有其他内容执行**。它存在的唯一原因：**再聪明的模型也会跳步，
> 而跳步 = 写出烂代码 = 用户 app 崩掉。** 所以用硬门禁把流程锁死。

## -1.0 三条铁律（违反任意一条 = 本轮工作作废，必须回退重来）

1. **没读代码 = 不许写代码**。读代码不是"翻一眼"，是必须输出阅读证据（见门禁 1）
2. **没思考 = 不许写代码**。必须输出思考模板全部 8 条（见门禁 2）
3. **没验证 = 不许提交**。必须输出验证证据（见门禁 4）

**违规自纠**：发现自己跳过了门禁 → ① 立刻停止 → ② `git checkout .` 回退未提交改动
→ ③ 从头走门禁 1。**不许"下次注意"，不许"这次算了"。**

## -1.1 门禁 1：读（READ GATE）

**写任何一行代码之前，必须先真实读取相关文件。** 用 read/grep 工具，不许凭记忆。

**必须逐字输出以下模板并填空（8 项全填，缺 1 项不许进入门禁 2）：**

```
【门禁1 · 阅读证据】
1. 我要改的文件：____________（完整路径）
2. 我实际读的行范围：第 ___ 行 到 第 ___ 行
3. 我读到的事实（每条必须附 文件:行号）：
   - ____________________________________（文件:行号）
   - ____________________________________（文件:行号）
   - ____________________________________（文件:行号）
   - ____________________________________（文件:行号）
4. 目标函数的完整签名（原样抄写）：
   ____________________________________
5. 谁调用了它？（跑的 grep 命令：____________；结果：____________）
6. 它调用了谁？（列出直接依赖：____________）
7. 它有没有副作用？（写文件/发按键/改状态/网络请求：____________）
8. 我读到的代码里，有没有"我看不懂"的部分？
   - 有 → 写出是哪里：____________ → 只读不改，继续读其他相关文件
   - 没有 → 进入门禁 2
```

❌ **以下行为一律判违规**：
- 说"我已经了解了"但不给行号
- 行号凭记忆写（必须来自真实 read 输出）
- 只读自己要改的那 10 行，不看调用方和被调用方
- 看到函数名就假设它的行为

## -1.2 门禁 2：想（THINK GATE）

**读完之后，必须深度思考并输出以下模板（8 问全答，缺 1 问不许动手）：**

```
【门禁2 · 深度思考】
1. 这个改动要达到什么目的？（一句话，不超过 30 字）
   → ____________________________________
2. 有几种实现方案？分别是什么？
   方案A：____________________________________
   方案B：____________________________________
   （至少 2 个，哪怕另一个显然更差也要写出来对比）
3. 选哪个方案？为什么？（必须按"稳定性优先"论证）
   → ____________________________________
4. 这个改动可能破坏什么？（至少列 2 个具体风险 + 缓解措施）
   风险1：____________ → 缓解：____________
   风险2：____________ → 缓解：____________
5. 它是否触碰「架构冻结清单」？（第 2.2 节）
   → 是 / 否 （如果是"是" → 立刻停手，改做别的任务）
6. 能否用"新增"代替"修改"？（新增优先原则）
   → 能 / 不能（不能的话，写出必须修改的理由：____________）
7. 如果失败，怎么回退？（写出具体命令）
   → ____________________________________
8. 影响哪些已有功能？逐一列出并说明为何不受影响
   → ____________________________________
```

❌ **以下行为一律判违规**：
- 跳过第 2 问直接给方案（= 没做方案对比）
- 第 4 问写"没有风险"（**任何改动都有风险，写"没有"= 没认真想**）
- 第 7 问写"不会有问题"（= 没准备回退）

## -1.3 门禁 3：写（WRITE GATE）

**满足以下全部条件才允许动手：**
- [ ] 门禁 1 的 8 项已全部填写输出
- [ ] 门禁 2 的 8 问已全部回答输出
- [ ] 已确认不触碰架构冻结清单

**写代码时必须遵守的 8 条：**
1. **最小改动**：只改必须改的行。改完跑 `git diff`，问"有没有一行是顺便改的？"→ 有就撤掉
2. **不用 `sed` 改 Swift**（多行结构会被改坏，本项目已因此毁过一次代码）→ 用 edit 工具
3. **新增优先**：能加新方法就不改老方法，能加 case 就不改 switch 结构
4. **每个新技能函数必须有 guard 三连**：dryRun → 依赖检查 → 游戏窗口护栏
5. **所有异步回调必须 `[weak self]`**（防循环引用/崩溃）
6. **所有循环必须有上限**（轮数或超时，防死循环）
7. **不许写 `// TODO`**：要么完整实现，要么不改
8. **不许留半成品**：改一半比不改危险 10 倍

## -1.4 门禁 4：验（VERIFY GATE）

**改完必须逐项验证并输出（6 项全填）：**

```
【门禁4 · 验证证据】
1. 编译结果：
   命令：/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch
   输出：____ 个 "error:"（**必须 0**）
2. 自测结果：
   命令：./AuroraDriveUI --agent-selftest
   输出原文：____（PASS=____ FAIL=____，**FAIL 必须 0 且 PASS 不许减少**）
3. 本次新增的自测项（如适用）：____________
4. 实际行为验证（命令 + 真实输出原文，不许写"应该没问题"）：
   ____________________________________
5. git diff --stat 输出原文：
   ____________________________________
6. 回退命令：____________________________________
```

❌ **以下行为一律判违规**：
- 没跑编译就说改完了
- 只跑编译不跑自测
- 用"应该能行""理论上没问题"代替真实输出
- 自测 PASS 数减少还继续往下做（**必须立刻回退**）

## -1.5 每轮工作的粒度与节奏

**一轮 = 一个最小改动**，必须满足：
- 只涉及**一个文件**（最多两个，且必须说明为何不能拆）
- 只涉及**一个函数/一个 case**
- 能**一次编译通过**
- 能**一次提交**

**任务太大就拆**：
```
❌ 错误："移植 MaaNTE 的 13 个技能"
✅ 正确："移植 touch 技能" → 编译 → 自测 → 提交 → 下一个
```

**禁止一轮内做多件事**：
```
❌ "我顺便把这个也改了" → 违规
❌ "改完这个再改那个" → 违规（除非是同一函数的必然连带改动）
```

## -1.6 小模型专属约束（因为知道你会犯错，所以提前锁死）

| # | 约束 | 原因 |
|---|---|---|
| 1 | **不许猜** | 不确定的行号/函数名，用 `grep -n` 查，不许凭印象写 |
| 2 | **不许假设** | 函数名叫 `performXxx` 不等于知道它干什么，必须读实现 |
| 3 | **不许跳步** | 门禁 1→2→3→4 顺序执行，不许合并、不许跳过 |
| 4 | **不许一次改多处** | 注意力分散的典型表现就是"顺手全改了" |
| 5 | **不许写 TODO** | 要么做完，要么不做 |
| 6 | **不许留半成品** | 改一半 = 埋雷 |
| 7 | **编译不过不许提交** | 绝对 |
| 8 | **自测 FAIL 不许继续** | 先回退再说 |
| 9 | **看不懂就先别改** | 只读不改，记录下来；理解三遍再说 |
| 10 | **每完成一轮，回头看一眼总目标** | 防跑偏（第 1 章目标陈述）|
| 11 | **每轮结束写 3 行小结** | 改了什么 / 验证了什么 / 下一步 |
| 12 | **遇到歧义按第 3.4 节自决，不许问用户** | 用户明确要求 |

## -1.7 一句话流程（每次开工前默念）

```
读（8项证据）→ 想（8问思考）→ 检查（3条门禁）→ 写（最小改动）
   → 编译（0 error）→ 自测（FAIL=0）→ 验证（真实输出）→ 提交（1个commit）
   → 3行小结 → 下一轮
```

**再重复一次：跳过任何一步 = 本轮作废 = 回退重来。**

================================================================================
# 第 0 章  事实档案（唯一真相源 · 禁止凭记忆干活）
================================================================================

## 0.1 项目规模（实测）
- 路径：`/Users/dupi/Desktop/自动驾驶系统`
- 源码：`Sources/AuroraDrive/` **31 个 Swift 文件 / 18,169 行**
- 最大的文件（改动风险最高的，动之前必须三思）：
  | 文件 | 行数 | 职责 | 风险 |
  |---|---|---|---|
  | `AuroraDriveApp.swift` | 4,269 | 主布局 + 所有面板 + 自测入口 + 启动器 | 🔴 极高 |
  | `AIAgentPanel.swift` | 1,865 | AI 面板 + 技能中心 + 执行通道 + LLM | 🔴 高（你的主战场）|
  | `GameMapView.swift` | 1,863 | 网络地图 | 🔴 极高（用户明确要求不许遮挡）|
  | `SpeedOCRReader.swift` | 1,243 | 速度 OCR | 🟠 中 |
  | `EngineMain.swift` | 849 | 引擎子进程主循环 | 🔴 极高 |
  | `YoloEngine.swift` | 807 | YOLO 推理 | 🟠 中 |
  | `CaptureEngine.swift` | 639 | 屏幕捕获（SCStream）| 🟠 中 |
  | `ControlEngine.swift` | 351 | 键鼠注入（CGEvent）| 🔴 高 |
  | `AgentLoop.swift` | 227 | 原生 Tool-Calling 循环 | 🟢 低（新代码，可自由改）|

## 0.2 架构（必须理解的 3 条链路）

**链路 A：进程架构**
```
AuroraDriveUI (UI 进程)  ──Unix socket──>  AuroraDrive --engine (引擎子进程)
   负责：SwiftUI 界面              负责：屏幕捕获、YOLO、地图定位、录制
   持有：ControlEngine             持有：共享内存 (shm) 帧缓冲
        CaptureEngine
```
- UI 侧单实例保护：`~/Library/Application Support/AuroraDrive/ui.lock`（flock）
- 引擎侧保护：`engine.lock`
- ⚠️ 两个 UI 实例会互抢 socket → 0.5s 断开重连死循环，所以有锁

**链路 B：技能执行链路（唯一通道，人类点击和 AI 指令都走这里）**
```
人类点击按钮 ──┐
              ├──> AgentSkillCenter.runSkill(id, source:) / toggleSkill(id, source:)
AI 输入文字 ──┘         │
                        ├──> runningSkills.insert(id)      // 去重
                        ├──> appendSystem("启动「技能名」")  // 面板日志
                        └──> workQueue.async { execute(skill, source) }
                                  │
                                  └──> switch skill.id → 各技能私有实现
```
- `workQueue`：**串行** DispatchQueue（`AgentSkillCenter` 私有）
- `runningSkills: Set<String>`：运行中技能集合，`stopSkill/stopAll` 移除
- `isDryRun: Bool`：自测标记。**必须在 execute 入口取快照**（见 `AIAgentPanel.swift:518`），
  不能在异步回调里读实时值——否则自测会突然真按键
- `appendSystem(text)`：给面板加系统消息（UI 线程安全由调用方保证）

**链路 C：AI 指令解析链路**
```
sendUserMessage(text, source:)
   ├── 停词命中（停/取消/别动）→ stopAll → 返回
   ├── 关键词匹配 AgentSkillLibrary.all → matchedSkills
   │     ├── matchedCount >= 2  → AgentLoop（复合任务，多步规划）
   │     ├── matchedCount == 1 且 isComplexTask（含"然后/接着/先/再/依次/最后/顺"）
   │     │                       → AgentLoop
   │     ├── matchedCount == 1  → runSkill（单技能直配）
   │     └── matchedCount == 0  → 本地兜底回复
   └── LLM 可用时由 RealLLMPlanner 接管；不可用时 MockLLMPlanner（关键词规则）兜底
```

## 0.3 关键 API 签名（照抄，别自己发明）
```swift
// 技能中心（单例）
AgentSkillCenter.shared.runSkill(_ id: String, source: AgentInvokeSource)
AgentSkillCenter.shared.toggleSkill(_ id: String, source: AgentInvokeSource)
AgentSkillCenter.shared.stopSkill(_ id: String, source: AgentInvokeSource)
AgentSkillCenter.shared.stopAll(source: AgentInvokeSource)
AgentSkillCenter.shared.sendUserMessage(_ text: String, source: AgentInvokeSource)
AgentSkillCenter.shared.isDryRun = true/false

// 技能定义
AgentSkill(id: String, emoji: String, name: String, ported: Bool?,
           warn: Bool?, keywords: [String])

// 控制引擎（键鼠注入）
control.pressGameKey(.k, duration: 0.05)     // 短按
control.holdGameKey(.w)                      // 按住
control.releaseGameKey(.w)                   // 松开
control.releaseAllGameKeys()                 // 全部松开（停止时必调）
mouse.click(at: CGPoint)                     // 鼠标点击
mouse.scrollWheel(lines: -3, at: point)      // 滚轮

// 捕获引擎
capture.currentFrame                         // NSImage? 当前帧
capture.onFrame = { nsImage, cgImage in }    // 帧回调

// 游戏窗口护栏（安全命门）
GameWindowDetector.isGameVisible()           // true=屏幕上有「异环/NTE」窗口
```

## 0.4 GameKey 可用键位（`ControlEngine.swift:233` 枚举定义 / `:281` 映射表 实测）
```
W A S D          移动
F E Space        交互/跳跃
Esc Q R M B T    功能键
Shift Ctrl       修饰键
1 2 3 4 5 6 7    数字
J K L Z X C V N  动作键（K=排球击球）
G H I            钢琴中音
Y U              钢琴高音
```
**新增技能只能用这些键**；要加新键必须先改 `GameKey` 枚举 + 映射表（属于架构改动，需报备）。

## 0.5 MaaNTE 参考源（只读，禁止修改）
- 路径：`MaaNTE/`
- 规模：**86 个 action 文件 / 45 个已注册 CustomAction / 24 个任务 JSON**
- 任务清单文件：`MaaNTE/assets/interface.json`（注意：含 `//` 注释，不是标准 JSON，
  用 `sed/grep` 读，别用 `json.load`）
- 任务定义：`MaaNTE/assets/resource/tasks/*.json`
- 动作实现：`MaaNTE/agent/custom/action/**/*.py`
- ⚠️ MaaNTE 是 **Windows 专用**（Win32 控制器 + GetAsyncKeyState + PrintWindow），
  移植到 macOS 必须换实现手段，**禁止直接照抄 Win32 API**

## 0.6 构建 / 部署 / 自测（真实命令，别自己编）

**编译（开发用，快）**
```bash
cd /Users/dupi/Desktop/自动驾驶系统
/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch
# 产物：.build/scratch/release/AuroraDrive
```

**一键编译+签名+部署+启动（用户日常用，必须走这个）**
```bash
./run.sh          # 会 rm -rf .build，全量重编 → 部署 → open app
```
`run.sh` 做的 5 件事（顺序不能变）：
1. `rm -rf .build && swift build -c release`（产物 `.build/release/AuroraDrive`）
2. `codesign --force --deep --sign - <二进制>`
3. **原子替换**：`cp 二进制 目标.tmp.$$ && mv -f 目标.tmp.$$ 目标`
   ⚠️ 绝对不能用普通 `cp` 覆盖正在运行的二进制：
   内核按需分页，原地覆盖会导致新旧页混合 → CDHash 校验失败 → **SIGKILL**
   （项目 9/10 的真实事故，见 run.sh 注释）
4. 同时更新两个目标：`./AuroraDriveUI` 和 `./AuroraDriveUI.app/Contents/MacOS/AuroraDriveUI`
   ⚠️ 当前两者**不同步**（裸二进制 9/14 5.22MB，.app 内 9/13 4.33MB）——这是待修问题
5. `pkill -f AuroraDriveUI` → `open AuroraDriveUI.app --args --auto-login`

**自测命令（全部需要 GUI 启动，有 1.2s 延迟）**
```bash
./AuroraDriveUI --agent-selftest       # 逻辑链路自测，输出 [AGENT-SELFTEST] PASS/FAIL
./AuroraDriveUI --agent-ui-shot        # 无头渲染 AI 面板 PNG
./AuroraDriveUI --agent-layout-shot    # 折叠/展开布局对比 PNG（验证主 UI 右移）
./AuroraDriveUI --auto-login           # 启动即自动登录守护
./AuroraDriveUI --set-llm-config <key> <baseUrl> <model>   # 写配置（launcher 级，秒回）
./AuroraDriveUI --agent-llm-test       # 真实请求模型（当前有死锁 BUG，见 2.3）
```

**当前自测基线：9 项（PASS=9 FAIL=0）**，清单见 `AIAgentPanel.swift:1026-1090`：
1. 指令解析→登录  2. 指令解析→排球  3. 指令解析→停止
4. 指令解析→领奖励（dryRun）5. 指令解析→收家具 6. 指令解析→滚动
7. AgentLoop 复合任务规划（"先登录然后再领奖励"）
8. 人类点击走同一通道  9. 按键引擎可用

================================================================================
# 第 1 章  目标（完整目标陈述 · 全部写全）
================================================================================

## 1.1 一句话目标
在**不破坏任何现有功能、不改变整体架构、不影响稳定性**的前提下：
① 修好 LLM 链路的 3 个已确证缺陷；
② 把 MaaNTE 的 **24 个任务全部**做完整评估并移植能在 macOS 稳定运行的；
③ 用**电脑操作工具真实操作 app** 完成端到端验收；
④ 全程本地 git 提交，交付一份逐项对照的完整报告。

## 1.2 三个子目标的完整展开

**子目标 A：LLM 链路修好并用真实 API 验证**
- 现状：框架已通，但 3 处稳定性缺陷（见 2.3 详述）
- 要求：`--agent-llm-test` 30 秒内返回**真实模型回答**（不是"(未配置)"不是"(解析失败)"）
- 要求：修复后 GUI 主链路（复合任务）**永不卡死**
- 要求：LLM 不可用时自动回退关键词路径，用户**无感知降级**
- 已配置凭证（已写入 Keychain，勿在日志中打印完整 key）：
  model = `agnes-2.5-flash`，baseUrl = `https://api.agnes-ai.cn/v1`
- 禁止把 key 硬编码进源码（用户明确要求：不能让别人白嫖他的额度）

**子目标 B：MaaNTE 全量移植（24 任务，逐项给结论）**

已移植 7 项（**不许破坏**）：
| 面板 ID | MaaNTE 对应 | 实现方式 |
|---|---|---|
| `auto_login` | （本项目特有）| OCR 定位登录按钮 + 守护模式（8s×10 次）+ 游戏窗口护栏 |
| `rewards` | ClaimRewards | OCR 定位"一键领取"→ 点击循环，最多 8 轮，间隔 1.2s |
| `furniture` | Furniture | OCR 定位"一键收取"→ 点击循环 |
| `fishing` | Fish | F 抛竿 → 等收杆节奏 → F 再抛，12 轮 |
| `volleyball` | Volleyball | 0.6s 一次 K 键短按（0.05s），与 MaaNTE 节奏一致 |
| `dodge` | SoundDodge | Space+Shift 组合循环，20 轮 |
| `auto_scroll` | AutoFScroll | F×2 连点 + 滚轮 -3，15 轮 |

面板内待移植 4 项：`coffee` `pinkpaw` `piano` `rhythm`

完全缺失 13 项（含用户特别点名的"车子"）：
| 缺失项 | MaaNTE 源 | 分类 | 移植路径 |
|---|---|---|---|
| **自动驾驶数据集** | `DatasetCollection/autonomous_driving_dataset_recorder.py` | B | **用户点名要的**：轮询 W/A/S/D 状态 + 录帧（2 帧/秒、序列长 5、480×270），标签 0-8。macOS 用 `CGEventSource.keyState(.combinedSessionState, key:)` 替代 `GetAsyncKeyState`；帧用 `capture.currentFrame`；存 `recordings/dataset/<时间戳>/`，文件名 `K<序号>%<标签序列>.jpeg` |
| 提款机 | `withdraw_money_choose_item.py` | A | 固定菜单导航点击（OCR 定位金额选项）|
| 拍卖王 | `BidKing.json` | C | 需识别拍卖 UI，先评估 `VisualLocator` 能否覆盖 |
| 番茄汁 | `MakeTomatoJuice.json` | A | 键序（参考 coffee 流程）|
| 俄罗斯方块 | `auto_tetris.py`（用 cv2+JOCR）| C | 需棋盘识别，评估 YoloEngine |
| 贝果刷屏 | `bagel_spam_text.py` | A | 文本刷屏（键盘输入序列）|
| 实时任务 | `realtime_task.py` | C | 实时辅助（dodge/fish 的基础上叠加）|
| 在线导航 | `Navi/online_map_navigation_action.py` | C | 地图定位，本项目有 `NetworkLocator` 基础 |
| 喷泉签到 | `FountainCheckin.json` | A | 固定点击序列 |
| 女巫占卜 | `WitchDivination.json` | A | 固定点击序列 |
| 触摸 | `Touch.json` | A | 简单点击 |
| 角色能力同步 | `SyncCharacterAbilityCityAbility.py` | C | 多步骤 UI 操作 |
| preset: AFK / 实时辅助 | `preset/AFK.json` `preset/RealtimeAssistance.json` | D | 用已有技能组合编排 |

分类规则：
- **A 类（纯输入序列）**：能稳 → 必须真实实现
- **B 类（录制/采集）**：能稳 → 必须真实实现
- **C 类（需 CV/实时识别）**：先评估现有 `YoloEngine`/`VisualLocator`/`NetworkLocator`/
  `SpeedOCRReader` 能否覆盖；能覆盖就做，不能就**如实标注待移植 + 写清缺什么**
- **D 类（组合编排）**：纯串联已有技能

🔴 **铁律：宁可不实现，绝不写假实现。**
判断标准：如果这个技能在游戏里会乱按键/乱点击（可能让用户的角色死掉/误操作），
就必须标"待移植"，不许为了凑数假装做好。

**子目标 C：电脑操作真实验收**
- 必须用 `computer-use` 技能/插件，真实操作运行中的 app
- 走查项：启动 → 观察面板 → 开设置 → 填配置 → 逐个点新技能 → 看日志如实回报 →
  发复合指令 → 确认游戏未开时行为安全
- 每一项留证据（截图路径 + 日志文本）

## 1.3 明确不做的事（防范围蔓延）
- 不改「往外扩展」布局（用户明确要求：面板占左侧 348pt，主 UI 右移，不遮挡网络地图）
- 不引入任何第三方框架/依赖（用户已选定"零框架·原生 Tool-Calling"）
- 不做本地 LLM 推理（用户明确：玩游戏时 CPU 会被占满）
- 不改动驾驶模型/checkpoints 相关代码
- 不 push 到任何远程仓库（用户明令禁止）

================================================================================
# 第 2 章  稳定性宪章（最高优先级 · 附"怎么避免"的具体机制）
================================================================================

## 2.0 为什么稳定性是最高基础（先理解后果）
用户是**在玩游戏时用这个工具**。稳定性出问题 = 真实后果：
- 面板卡死 → 用户不能停止正在跑的技能 → 角色在游戏里持续乱按键 → 用户账号/进度受损
- 主线程冻结 → 整个 app 卡住 → 用户只能强杀 → 可能丢配置
- 崩溃 → 引擎子进程变孤儿 → 下次启动抢 socket → 死循环
- 构建/部署出错 → 用户的 app 直接打不开

所以：**任何"可能会卡住/崩溃/乱按键"的改动，一律不做。**

## 2.1 稳定性第一原则：最小改动（Minimum Diff）
- 能新增文件解决的，不改现有文件
- 能加一个方法解决的，不改现有方法
- 能加一个 `case` 解决的，不改 `switch` 结构
- 每次改动后跑 `git diff --stat`，问自己：**这个 diff 里有没有一行是"顺便改的"？**
  有 → 撤掉那行

## 2.2 架构冻结清单（这些绝对不能碰）

🔴 **绝对禁止改动（改了就会出系统性风险）**
| 文件/位置 | 原因 |
|---|---|
| `AuroraDriveApp.swift` 的 `AuroraDriveLauncher.main()` 结构 | 启动顺序、UI 锁、引擎 spawn 都在这里 |
| `AuroraDriveApp.swift` 的 ContentView body 布局（HStack 结构）| 用户明确要求的面板往外扩展布局 |
| `EngineMain.swift` 引擎主循环 | 捕获/推理/共享内存全依赖 |
| `EngineClient.swift` 的 socket 协议 | 改了会导致 UI↔引擎不兼容 |
| `ControlEngine.swift` 的 `GameKey` 枚举与映射表 | 全局键位 |
| `CaptureEngine.swift` 的 SCStream 配置 | 屏幕捕获权限/性能 |
| `GameMapView.swift` | 用户明确要求的不许遮挡 |
| `AgentSkillCenter.runSkill/toggleSkill/stopAll` 签名与语义 | 人类+AI 唯一通道，改了全线崩 |

🟢 **允许改动（改动成本低、风险可控）**
| 位置 | 允许的操作 |
|---|---|
| `AgentLoop.swift` | 可自由重写（新文件，227 行，独立性强）|
| `AIAgentPanel.swift` 的 `callLLM` / `plainAnswer` / `runLLMTest` | 可重写（LLM 相关）|
| `AIAgentPanel.swift` 的 `execute()` switch | 只能**加 case**，不能改已有 case |
| `AIAgentPanel.swift` 的 `AgentSkillLibrary.all` | 只能**加条目**，不能改已有条目 |
| `AIAgentPanel.swift` 的技能实现（`performXxx`）| 加新方法，不改老方法 |
| `AIAgentPanel.swift` 的 `AgentSelfTest.run` | 只能**加检查项**，不能删/改已有项 |
| 新增独立文件（新技能、新工具）| 自由 |
| `docs/` | 自由 |

## 2.3 已确证的 3 个稳定性缺陷（必须修，且不许扩散）

**缺陷 1：主线程信号量 + Task 死锁（`sample` 已确证）**
- 位置：`AuroraDriveApp.swift` launcher 的 `--agent-llm-test` 分支
- 现场证据：`sample <pid>` 抓到主线程卡在 `semaphore_wait_trap`，
  而协作线程池全空闲（`__workq_kernreturn`），Task 闭包**从未执行**
- 机理：主线程 `semaphore.wait()` 阻塞时，被排队的工作无法获得执行机会
- 修法：**改纯同步 HTTP**（`URLSession.dataTask` + 带超时的 semaphore，
  或 `Data(contentsOf:)` 同步请求），或全程 async/await 不阻塞任何线程
- 🔴 **禁止模式**（写进红线）：
  ```swift
  // ❌ 禁止：主线程/串行队列上等待 Task
  let sem = DispatchSemaphore(value: 0)
  Task { ...; sem.signal() }
  sem.wait()          // 主线程或 workQueue 上这样写 = 可能永久卡死
  ```

**缺陷 2：同型模式存在于 GUI 主链路**
- 位置：`AIAgentPanel.swift:921-931`（`sendUserMessage` 复合任务分支）
  ```swift
  workQueue.async {
      let semaphore = DispatchSemaphore(value: 0)
      Task { summary = await loop.handle(...); semaphore.signal() }
      semaphore.wait()        // ⚠️ 同型风险
      DispatchQueue.main.async { self?.replyAssistant(summary) }
  }
  ```
- 后果：若同型卡死发生，`workQueue`（**串行队列**）被永久占用 →
  **后续所有技能启动全部失效**（面板点了没反应）
- 注意：这不冻结 UI（主线程没被阻塞），但会**静默废掉整个面板**——更隐蔽更危险
- 修法：改为 `Task { ... }` 内部全程 async/await，UI 更新用
  `await MainActor.run { ... }` 或 `DispatchQueue.main.async`，
  **不阻塞 workQueue 线程**

**缺陷 3：网络请求无超时**
- 位置：`AIAgentPanel.swift:313`（`callLLM`）与 `:370`（`plainAnswer`），
  均用 `URLSession.shared.data(for:)`
- 后果：默认超时 60s，请求挂起时占用 AgentLoop 一个完整周期
- 修法：建专用会话
  ```swift
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForRequest = 30      // 单次请求总超时
  config.timeoutIntervalForResource = 45     // 资源总超时
  config.waitsForConnectivity = false        // 不等待网络恢复
  let session = URLSession(configuration: config)
  ```
  并在 `request` 上额外设 `request.timeoutInterval = 30`

**缺陷 4：`ported` 字段默认值与实际行为不一致（本次深度核对新发现）**
- 位置：`AIAgentPanel.swift:57` — `var ported: Bool = true // true=原生已实现；false=待移植占位`
- 问题：`coffee` / `pinkpaw` / `piano` / `rhythm` 这 4 个技能**没写 `ported` 参数**
  （见 `:161` `:163` `:169` `:171`），因此它们 **`ported == true`**，但 `execute()` 里
  **没有对应 case** → 走 `default: performSnapshotStub()`（只截图 + 打印"开发中"，不做真实动作）
- 后果链：
  1. 技能库里"是否已实现"的标记 **不可信**（coffee 声称已实现，其实没有）
  2. UI 按钮 tooltip 由 `ported` 决定（`:1566`），错误显示为"（点击启动/停止）"
     而不是"（待移植，点击会报告当前状态）"→ **用户被骗**
  3. 主面板待移植角标同理（`:1530` `if !skill.ported`）→ 角标不显示
- **修法（1 行，最小改动）**：把默认值反过来
  ```swift
  // AIAgentPanel.swift:57
  var ported: Bool = false   // 默认 false：未显式声明即为待移植（防止漏标）
  ```
  安全性论证：已实现的 7 个技能**全都显式写了 `ported: true`**
  （`:155` `:157` `:159` `:165` `:167` `:173` `:175`），改默认值不会误伤它们，
  只会让那 4 个漏标的自动变正确。
- **配套自测（必须加）**：遍历技能库做一致性检查
  ```
  加到 AgentSelfTest.run：
  ① ported==true 的技能，execute() 里必须有对应 case（否则是漏标）
  ② ported==false 的技能，必须 NOT 有 case（否则是漏实现）
  ```
  这条自测能**永久防止**"标记与实现漂移"这一类错误。
- ⚠️ **顺序不能反**：修完这个之后，防线 2/3（按 `ported` 过滤给模型 / 校验 `ported`）才真正有效

## 2.4 网络/并发编码规范（白名单 vs 黑名单）

✅ **允许**
- `async/await` 全程不阻塞
- `DispatchQueue.main.async { }` 做 UI 更新
- `DispatchSource.makeTimerSource(queue: workQueue)` 做周期任务（现有技能都这么写）
- 专用 `URLSession` + 显式超时
- `Task.detached { }` + `await task.value`（有界等待）

❌ **禁止**
- 任何线程上 `semaphore.wait()` 等待一个需要该线程空闲才能跑的 Task
- `Thread.sleep` / `usleep` 在主线程或 workQueue（除了极短 0.05-0.1s 的节奏等待）
- 无超时的网络请求
- 在 `execute()` 里同步阻塞（技能动作必须走 timer 或 workQueue）
- 强引用循环（技能回调必须 `[weak self]`，现有代码全是这个模式）

## 2.5 技能安全护栏（乱按键 = 最严重事故）
每个技能**必须**满足：
1. **游戏窗口护栏**：真实注入按键/点击前检查 `GameWindowDetector.isGameVisible()`；
   没有游戏窗口 → 打印提示 + 温柔退出，**绝不盲按键**
2. **dryRun 分支**：`execute` 入口取 `let dryRun = isDryRun` 快照；
   dryRun 时只打印链路就绪日志，**不做任何真实注入**
3. **停止即释放**：`teardown(id:)` 里必须 `control.releaseAllGameKeys()` +
   取消 timer + 清理回调，防止按键卡住（角色一直往前走）
4. **上限保护**：所有循环必须有轮数上限或超时上限（现有：fishing 12 轮、
   dodge 20 轮、scroll 15 轮、rewards 8 轮、登录守护 80s）
5. **如实日志**：日志必须反映真实状态。"已启动"就真的启动了；
   没实现就写"待移植"，**禁止假装成功**

## 2.6 构建/部署安全规范
- **绝不**用普通 `cp` 覆盖正在运行的二进制（会 SIGKILL，见 0.6）
- 部署一律走 `./run.sh`（内含原子替换）
- 部署前确保没有正在跑的实例：`pkill -9 -f AuroraDriveUI`
- 改完必须重编 + 部署 + 验证 md5/size 一致，不能只编不部署
- 沙箱环境编译慢，可用 `--scratch-path .build/scratch` 加速，但**最终部署必须用 `./run.sh`**
  保证两个目标（裸二进制 + .app）同步

## 2.7 每步强制流程（一步都不能省）
```
1. 读代码（读真实文件，不是回忆）→ 记录 文件:行号
2. 写最小改动
3. 编译：/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch
   必须 grep "error:" 确认 0 error（不能只看 exit code）
4. 自测：./AuroraDriveUI --agent-selftest → PASS 数只增不减
5. 部署：./run.sh（或按 2.6 手动原子替换）
6. 验证：实际运行确认行为
7. git add + git commit（信息写清：改了什么/为什么/验证了什么）
8. 若任一步失败 → 回退（git checkout）→ 重新分析根因，禁止"再试一次"式瞎改
```

## 2.8 回滚预案（随时可退）
- 稳定基线 commit：`c65189d`（面板往外扩展布局，已验证稳定）
- 回滚命令：`git checkout c65189d -- <文件>` 或整体 `git reset --hard c65189d`
- **必须保持的性质**：删掉 `AgentLoop.swift` + `AIAgentPanel.swift` 的 LLM 段
  = 完整回到稳定版功能。每次改完 LLM 相关代码都要自问这一条还成立吗
- 每完成一个阶段打一个 tag 或写清 commit hash 到报告里，方便定点回退

## 2.9 危险操作清单（做之前必须先说明再执行）
- `pkill` 杀进程（会影响用户正在跑的实例）
- 修改 `Package.swift`
- 修改任何「架构冻结清单」里的文件
- 强制 git 操作（reset --hard / clean -fd）
- 删除任何现有文件
- 修改用户已配置的 Keychain 内容

================================================================================
# 第 3 章  防"脑子一抽"协议（Anti-Drift Protocol）
================================================================================

## 3.1 事实优先原则
- **任何断言必须附证据**：`文件路径:行号` 或 `命令输出原文`
- 写不出证据的断言 = 猜测 = 禁止写进报告、禁止据此改代码
- 报告里区分三类内容：
  - ✅【已核实】附 文件:行号
  - ⚠️【推测】必须标明"未核实"并说明如何核实
  - ❌【不确定】直接说不知道，去查，别编

## 3.2 禁止事项（这些是"脑子一抽"的典型症状）
- ❌ 凭记忆说"这个功能已经实现了"（必须去读代码确认）
- ❌ 看到函数名就假设它的行为（必须读实现）
- ❌ 改完不编译就提交
- ❌ 编译报错后反复瞎试（超过 2 次失败必须重新读代码 + 写清根因分析）
- ❌ 用 `sed` 改 Swift 代码（多行结构会改坏；用 edit 工具）
- ❌ 声称"已测试通过"但实际只编译过
- ❌ 把"应该能行"当"已经验证"
- ❌ 遇到不确定就跳过（必须写进报告的"未解决/待确认"）

## 3.3 每轮开工自检（复制粘贴执行）
```bash
cd /Users/dupi/Desktop/自动驾驶系统
git log --oneline -3              # 确认起点
git status --short                # 确认工作区状态
grep -n "你的目标函数" Sources/AuroraDrive/xxx.swift   # 确认真实行号
# 复跑基线
/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch 2>&1 | grep -c "error:"
```

## 3.4 遇到歧义时的决策规则（不许问用户）
用户明确要求：**不要来问我**。决策优先级：
1. 稳定性优先：选对现有功能影响最小的方案
2. 保守优先：不确定能不能稳 → 标"待移植"，不硬做
3. 最小改动优先：能加不改
4. 可回退优先：优先选能一键回退的方案
5. 记录决策：把"为什么这么选"写进报告，用户回来能看懂

## 3.5 报告格式（每阶段结束必须写）
```markdown
## 阶段 N 报告
### 改了什么
- 文件:行号 — 改动内容 — 原因
### 验证了什么
- 证据：命令 + 输出原文（截取关键行）
### 剩余风险
- 一句话一条
### 未解决
- 明确列出（别藏）
```

================================================================================
# 第 4 章  任务清单（按顺序执行 · 每项含目标/方法/验收）
================================================================================

## 阶段 0：基线复核（必须最先做，禁止跳过）
**目标**：确认起点状态，杜绝凭记忆
**方法**：
1. `git log --oneline -20` 记录当前 HEAD
2. `grep -c "" Sources/AuroraDrive/*.swift` 复核文件规模
3. `find MaaNTE -path "*custom/action*" -name "*.py" | wc -l` 复核 86
4. 编译 + `--agent-selftest` 复跑，记录 PASS/FAIL 数
5. 读 `MaaNTE/assets/interface.json` 复核 24 任务清单
**验收**：报告里写出实测数字，与本文档第 0 章对比，不一致的地方标出来

## 阶段 1：修复 3 个稳定性缺陷（最高优先级）
| 编号 | 目标 | 位置 | 验收 |
|---|---|---|---|
| 1.1 | `--agent-llm-test` 改纯同步 + 30s 硬超时 | `AuroraDriveApp.swift` launcher | 命令 30s 内返回真实模型回答（agnes-2.5-flash 的实际文本）|
| 1.2 | 去掉 `sendUserMessage` 复合任务的信号量模式 | `AIAgentPanel.swift:921-931` | 自测第 7 项 PASS；连续发 5 次复合指令不卡 |
| 1.3 | 两处 URLSession 换带超时专用会话 | `AIAgentPanel.swift:313,370` | 断网测试：30s 内返回失败并回退，不卡 60s |

**阶段 1 完成后必须**：跑全量自测（PASS ≥ 9）+ 连续发 5 次复合指令验证不卡。

## 阶段 2：MaaNTE 全量移植（核实后：25 个可执行项 · 逐项清单）

### 2.0 核实数据（先看这个，别信记忆）

| 项 | 实测值 | 核实命令 |
|---|---|---|
| MaaNTE action 文件 | **86** 个 `.py` | `find MaaNTE/agent/custom/action -name "*.py" \| wc -l` |
| 已注册 CustomAction | **45** 个 | `grep -rn "@custom_action" MaaNTE/agent/custom/action \| wc -l` |
| 任务定义 JSON | **25** 个 | `ls MaaNTE/assets/resource/tasks/*.json \| wc -l` |
| interface.json import 引用 | **27** 条（其中 `preset/FullDaily`、`preset/QuickDaily` 被 `//` 注释）| 见 `MaaNTE/assets/interface.json` |
| **实际可执行项** | **25 个**（23 个任务 + 2 个预设）| — |
| 未进 import 的开发测试任务 | 2 个：`LocalRouteNavigationMemoryTest`、`TestMovement` | **不需要移植** |

⚠️ 早期文档写"24 任务"是**错的**，正确数字是 **25 个可执行项**。以本表为准。

### 2.1 总账：一共要移植 19 项

| 状态 | 数量 | 明细 |
|---|---|---|
| ✅ 已移植（来自 MaaNTE）| **6** | ClaimRewards / Furniture / Fish / Volleyball / SoundDodge / AutoFScroll |
| ✅ 已移植（本项目特有，MaaNTE 没有）| **1** | auto_login |
| ⚠️ 面板有按钮但**功能未实现** | **4** | MakeCoffee / PinkPawHeist / AutoPiano / Rhythm |
| ❌ 完全缺失（面板里连按钮都没有）| **15** | 见 2.2 表 |
| **合计待完成** | **19** | 4 + 15 |

### 2.2 全量对照表（25 项，一项不漏 · 这是工作路线图）

| # | MaaNTE 任务 | entry | 面板 ID | 类 | 状态 | 移植方法 |
|---|---|---|---|---|---|---|
| 1 | ClaimRewards | `ClaimRewardsEntrance` | `rewards` | — | ✅ 已移植 | — |
| 2 | Furniture | `FurnitureEntrance` | `furniture` | — | ✅ 已移植 | — |
| 3 | WithdrawMoney | `WithdrawMoneyEntrance` | `withdraw_money` | A | ❌ 缺失 | OCR 定位金额选项 → 点击；循环 |
| 4 | Fish | `FishEntrance` | `fishing` | — | ✅ 已移植 | — |
| 5 | BidKing | `BidKingEntrance` | `bid_king` | C | ❌ 缺失 | 拍卖 UI 识别（见 2.5）|
| 6 | PinkPawHeist | `PinkPawHeist_Main` | `pinkpaw` | C | ⚠️ 待移植 | 多阶段流程（见 2.5）|
| 7 | MakeCoffee | `AutoMakeCoffee` | `coffee` | A | ⚠️ 待移植 | 键序循环（见 2.3）|
| 8 | MakeCoffeeLite | `AutoMakeCoffeeLiteEntrance` | `coffee_lite` | A | ❌ 缺失 | 轻量键序（见 2.3）|
| 9 | MakeTomatoJuice | `AutoMakeTomatoJuice` | `tomato_juice` | A | ❌ 缺失 | 键序循环（见 2.3）|
| 10 | Rhythm | `RhythmEntrance` | `rhythm` | C | ⚠️ 待移植 | 音游识别（见 2.5）|
| 11 | Tetris | `TetrisEntrance` | `tetris` | C | ❌ 缺失 | 棋盘识别（见 2.5）|
| 12 | Volleyball | `VolleyballEntrance` | `volleyball` | — | ✅ 已移植 | — |
| 13 | BagelSpam | `BagelSpamEntrance` | `bagel_spam` | A | ❌ 缺失 | 文本输入（见 2.3）|
| 14 | RealTime | `RealTimeTaskMain` | `realtime` | C | ❌ 缺失 | 实时辅助（见 2.5）|
| 15 | OnlineMapNavigation | `OnlineMapNavigation` | `online_nav` | C | ❌ 缺失 | 复用 `NetworkLocator`（见 2.5）|
| 16 | SoundDodge | `SoundDodgeMain` | `dodge` | — | ✅ 已移植 | — |
| 17 | AutoFScroll | `AutoFScroll` | `auto_scroll` | — | ✅ 已移植 | — |
| 18 | FountainCheckin | `FountainCheckinEntrance` | `fountain` | A | ❌ 缺失 | 点击序列（见 2.3）|
| 19 | AutoPiano | `AutoPiano` | `piano` | A | ⚠️ 待移植 | 曲目键序（见 2.3）|
| 20 | WitchDivination | `WitchDivinationEntrance` | `witch` | A | ❌ 缺失 | 点击序列（见 2.3）|
| 21 | **AutonomousDrivingDataset** | `AutonomousDrivingDatasetRecorder` | `drive_dataset` | **B** | ❌ 缺失 | ★**复用 RecordEngine**（见 2.4）|
| 22 | SyncCharacterAbilityCityAbility | `SyncCharacterAbilityCityAbilityEntrance` | `sync_ability` | C | ❌ 缺失 | 多步 UI（见 2.5）|
| 23 | Touch | `TouchDetect` | `touch` | A | ❌ 缺失 | 点击（见 2.3）|
| 24 | preset/AFK | — | `preset_afk` | D | ❌ 缺失 | 串联已有技能（见 2.6）|
| 25 | preset/RealtimeAssistance | — | `preset_realtime` | D | ❌ 缺失 | 串联已有技能（见 2.6）|

**统计**：A 类 9 项 / B 类 1 项 / C 类 7 项 / D 类 2 项 / 已完成 6 项 = **25 项** ✓

### 2.3 A 类细则（9 项，纯输入序列 → 必须真实实现）

**共同实现步骤（每项都按这 5 步改，漏一个就不工作）**：
1. `AgentSkillLibrary.all` 加 `AgentSkill(id:emoji:name:ported:true,keywords:[...])`
2. `AIAgentPanel.swift` 加 `private func startXxxLoop(skill:source:dryRun:)`（照抄排球模板 `:656`）
3. `execute()` switch（`:515`）加 `case "xxx": startXxxLoop(...)`
4. 加 `@ObservationIgnored private var xxxTimer: DispatchSourceTimer?`；`teardown(id:)`（`:874`）加取消 + `control.releaseAllGameKeys()`
5. `AgentSelfTest.run`（`:1026`）加 1 条路由自测

**标准技能结构（照抄 `AIAgentPanel.swift:656` 排球模板 · 顺序不能变）**：
```swift
private func startXxxLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
    // ① dryRun 分支（必须在最前，防自测真实按键）
    guard !dryRun else {
        appendSystem("✅ 自测：XXX 链路就绪")
        runningSkills.remove(skill.id)
        return
    }
    // ② 依赖检查（按键/鼠标引擎是否注入）
    guard let control else {
        appendSystem("❌ 按键引擎未注入")
        runningSkills.remove(skill.id)
        return
    }
    // ③ 游戏窗口护栏（涉及真实注入的技能必须有）
    guard GameWindowDetector.isGameVisible() else {
        appendSystem("🎮 未检测到游戏窗口，已取消（安全护栏）")
        runningSkills.remove(skill.id)
        return
    }
    // ④ 周期任务用 timer（queue 必须是 workQueue）
    let timer = DispatchSource.makeTimerSource(queue: workQueue)
    timer.schedule(deadline: .now() + 0.6, repeating: 0.6)
    timer.setEventHandler { [weak self] in          // ⑤ [weak self] 防循环引用
        guard let self, self.runningSkills.contains("xxx") else { return }
        control.pressGameKey(.k, duration: 0.05)     // ⑥ 循环必须有上限保护
    }
    timer.resume()
    xxxTimer = timer                                 // ⑦ 存起来供 teardown 取消
    appendSystem("🎯 XXX 运行中（如实描述行为与停止方式）")   // ⑧ 日志必须如实
}
```
⚠️ 每个技能**必须**同时具备：dryRun 分支、依赖检查、游戏窗口护栏、`[weak self]`、
循环上限、teardown 释放按键（`control.releaseAllGameKeys()`）、如实日志。**缺一不可。**

**每项的具体做法**：

| 面板 ID | MaaNTE 源文件 | 具体实现 |
|---|---|---|
| `touch` | `Touch/TouchDetect.py` | 最简单：`mouse.click(at:)` 单次点击。**先做这个练手**，验证整套模式 |
| `fountain` | `FountainCheckin/FountainCheckin.py` | 固定点击序列：读源文件抄坐标序列 → 转屏幕坐标 → 逐个 `mouse.click` |
| `witch` | `WitchDivination/WitchDivination.py` | 同上，固定点击序列 |
| `bagel_spam` | `HethereauHobbies/BagelSpam/bagel_spam_text.py` | 文本刷屏：`control` 输入文本序列 → 需确认 `ControlEngine` 是否支持文本输入（**不支持则先加 `typeText` 方法**）|
| `coffee` | `MakeCoffee/auto_make_coffee.py` | 键序循环：读源文件抄键序列 → `pressGameKey` 循环 |
| `coffee_lite` | `MakeCoffee/auto_make_coffee_lite.py` | 轻量版，步骤更少 |
| `tomato_juice` | `MakeTomatoJuice/auto_make_tomato_juice.py` | 键序循环 |
| `withdraw_money` | `CityTycoon/withdraw_money_choose_item.py` | 菜单导航：OCR 定位金额选项 → 点击；循环 |
| `piano` | `AutoPiano/action.py` | **曲目键序**：MaaNTE 用 MIDI 文件 → macOS 版先做**内置曲目的键序列**（用 GameKey 的 G/H/I/Y/U 音键）；进阶再做 MIDI 解析 |

**验收（每项）**：
- `--agent-selftest` 新增 1 条 PASS
- dryRun 下打印"链路就绪"，不真实按键
- 真实运行时：无游戏窗口 → 被护栏拦下并打印提示
- 面板日志如实反映状态

### 2.4 B 类细则（1 项 · 用户点名的"车子"）★最高优先级

**AutonomousDrivingDataset / `AutonomousDrivingDatasetRecorder` / 面板 ID `drive_dataset`**

**MaaNTE 源**：`MaaNTE/agent/custom/action/DatasetCollection/autonomous_driving_dataset_recorder.py`（222 行）

**MaaNTE 原规格（已核对源码）**：
- 采样率 `_EXAMPLES_PER_SECOND = 2.0`（每秒 2 个样本）
- 序列长度 `_SEQUENCE_LENGTH = 5`（每样本含 5 帧）
- 单帧尺寸 `_IMAGE_SIZE = (480, 270)`
- 标签表 `_KEY_LABELS = {0:"none", 1:"A", 2:"D", 3:"W", 4:"S", 5:"AW", 6:"AS", 7:"DW", 8:"DS"}`
- 虚拟键码 `_VK = {W:0x57, A:0x41, S:0x53, D:0x44}`
- 轮询方式：`GetAsyncKeyState`（**Windows 专用，必须换**）
- 输出：`K<序号>%<标签序列>.jpeg`（5 帧横向拼接成一张宽图）

**★★ 关键发现：本项目已有 `RecordEngine`，不要从零写 ★★**

`Sources/AuroraDrive/RecordEngine.swift`（约 400 行）已提供：
```swift
final class RecordEngine: @unchecked Sendable {
    var glyphMode = false
    private(set) var isRecording = false
    private(set) var frameCount: Int = 0
    private(set) var sessionURL: URL?
    private var recordingsRoot: URL      // 录制根目录
    private var csvHandle: FileHandle?   // CSV 标签写入

    func start(perspective: String = "first")     // 开始录制
    func stop()                                    // 停止
    func flushSync()                               // 同步落盘
    func appendFrame(image: NSImage, steer: Double, throttle: Double, brake: Double)  // ★帧+标签
    func appendGlyphNative(pixelBuffer: CVPixelBuffer)
    private func resizeAndEncodeJPEG(image: NSImage, size: CGSize) -> Data?  // ★已有缩放+JPEG编码
}
```
→ **已具备**：帧录制、标签（steer/throttle/brake）、JPEG 缩放编码、目录管理、CSV 写盘

**移植策略（复用优先，禁止从零重写）**：
1. **不要**重写录制管线 → **复用 `RecordEngine`**
2. 需要新增的只是**按键状态采样 → 标签映射**这一层：
   ```swift
   // macOS 等价物（替代 GetAsyncKeyState）
   func keyDown(_ vk: CGKeyCode) -> Bool {
       CGEventSource.keyState(.combinedSessionState, key: vk) != 0
   }
   let w = keyDown(0x0D), a = keyDown(0x00), s = keyDown(0x01), d = keyDown(0x02)
   // 注意：macOS 的 CGKeyCode 与 Windows VK 不同！
   // W=0x0D, A=0x00, S=0x01, D=0x02（ANSI 布局）
   ```
   ⚠️ **不要直接抄 Windows 的 0x57/0x41/0x53/0x44**（那是 VK 码，macOS 不认）
3. 标签映射（MaaNTE 用 0-8 单值，本项目 RecordEngine 用 steer/throttle 浮点）：
   - 方案 A（推荐，贴合本项目）：`steer = (d ? 1 : 0) - (a ? 1 : 0)`、`throttle = w ? 1 : 0`、`brake = s ? 1 : 0`
   - 方案 B（贴合 MaaNTE）：保持 0-8 标签，在 CSV 里加一列 label
   - **两个方案都要能在报告里说清选了哪个、为什么**
4. 采样循环：`DispatchSource.makeTimerSource(queue: workQueue)`，间隔 `1/2.0 = 0.5s`
5. 帧来源：`capture.currentFrame`（CaptureEngine 已有）
6. 输出目录：复用 `RecordEngine.recordingsRoot`，不要另起目录

**面板集成**：
- 技能 ID：`drive_dataset`
- 关键词：`["dataset","数据集","采集","录制","驾驶数据"]`
- 参数：时长（默认 60s）、perspective（默认 "first"）
- 图标：🎬

**验收标准（全部满足才算过）**：
1. 跑 10 秒 → 输出目录出现 **≥20 个 jpeg**（2/秒 × 10 秒）
2. 文件名格式正确（含标签）
3. `file <文件名>` 验证是有效 JPEG
4. CSV 标签列写入了按键状态
5. 停止后 `isRecording == false`，文件句柄已关闭（`flushSync`）
6. 无游戏窗口时不启动（护栏生效）
7. `--agent-selftest` 新增 1 条 PASS

### 2.5 C 类细则（7 项，需 CV/识别 → 先评估再决定）

**评估流程（每项必须走完这 4 步，不许跳）**：
```
第 1 步：读 MaaNTE 源实现，写出它"到底在识别什么"
        （具体到图像元素：按钮？数字？颜色块？轮廓？）
第 2 步：读本项目对应模块的代码，写出它"能提供什么"
        （必须真读，不许凭模块名猜）
第 3 步：写出"差什么"（具体到功能，不是"差一点"）
第 4 步：给结论：可移植（写明怎么做）/ 待移植（写明缺什么）
```

**本项目可用的识别能力（已核实存在）**：

| 模块 | 行数 | 能力 |
|---|---|---|
| `SpeedOCRReader.swift` | 1,243 | 快速 OCR（文字识别，`VNRecognizeTextRequest`）|
| `VisualLocator.swift` | 491 | 视觉定位（模板/特征匹配）|
| `NetworkLocator.swift` | 626 | 网络地图定位 |
| `YoloEngine.swift` | 807 | YOLO 目标检测（已有 checkpoints）|
| `InferenceEngine.swift` | 432 | 推理封装 |
| `CaptureEngine.swift` | 639 | 屏幕捕获（SCStream）|
| `MouseController.swift` | — | `click(at:)` / `doubleClick` / `scrollWheel` / `screenPoint(fromPixel:scale:)` |
| `MinimapLocatorView.swift` | — | 小地图定位（OnlineMapNavigation 可能直接相关）|

**逐项评估指引**：

| 项 | 面板 ID | 需要识别什么 | 优先看的现有模块 | 评估要点 |
|---|---|---|---|---|
| BidKing | `bid_king` | 拍卖 UI 的**价格数字**、加价按钮、倒计时 | `SpeedOCRReader`（数字 OCR）| 能否稳定读价格？读到后如何决策加价？ |
| PinkPawHeist | `pinkpaw` | **多阶段 UI**：入口/选择/结算三阶段 | `VisualLocator` + `SpeedOCRReader` | 读 MaaNTE `PinkPawHeist*.py` 拆出有几个阶段 |
| Rhythm | `rhythm` | 音游**轨道/音符**（动态、快速）| `YoloEngine` | 60fps 下 YOLO 够快吗？先测帧率 |
| Tetris | `tetris` | **棋盘格 + 方块形状** | `YoloEngine` + `VisualLocator` | 网格能否稳定切分？|
| RealTime | `realtime` | 实时战斗状态 | `YoloEngine` | 与 dodge 的关系（叠加还是独立）|
| OnlineMapNavigation | `online_nav` | 地图定位 + 路线 | `NetworkLocator` (626) + `MinimapLocatorView` | **本项目已有地图能力**，评估复用度 |
| SyncCharacterAbilityCityAbility | `sync_ability` | 多步骤 UI（角色能力面板）| `SpeedOCRReader` + `MouseController` | 步骤是否固定？固定则可降级为 A 类 |

🔴 **铁律：评估结论是"待移植"时，必须写清"缺什么能力"，不许含糊。**
并且面板里该项必须 `ported: false` — 但**注意**：要先把缺陷 4（`ported` 默认值）修掉，
否则标了也不生效（见第 2.3 节缺陷 4）。

### 2.6 D 类细则（2 项，组合编排）

| 面板 ID | MaaNTE 源 | 编排内容 | 实现 |
|---|---|---|---|
| `preset_afk` | `preset/AFK.json` | 领奖励 → 收家具 → 钓鱼 | `AgentLoop` 串联 `AgentToolCall` |
| `preset_realtime` | `preset/RealtimeAssistance.json` | dodge + 实时任务 | 同上 |

**实现方式**：不需要新的注入代码，只需：
1. `AgentSkillLibrary.all` 加两个技能条目
2. `execute()` 加 `case "preset_afk":` → 依次 `runSkill` 各子技能
3. 注意**顺序 + 间隔**（子技能之间要给启动时间）
4. ⚠️ `preset_realtime` 依赖 C 类 `realtime`，若 `realtime` 未实现 → 该预设也标 `ported: false`

### 2.7 每项完成的统一验收

| # | 检查项 | 标准 |
|---|---|---|
| 1 | 编译 | 0 error |
| 2 | 自测 | 新增 1 条 PASS，FAIL 仍为 0，PASS 总数只增不减 |
| 3 | dryRun | 打印"链路就绪"，**不真实注入** |
| 4 | 游戏窗口护栏 | 无游戏时被拦下 + 打印提示，**0 乱点** |
| 5 | 停止释放 | `stopSkill` 后按键全部释放 + timer 取消 |
| 6 | 日志如实 | 状态描述与真实行为一致 |
| 7 | 文档同步 | `docs/ai-agent-panel.md` 技能表更新 |
| 8 | 提交 | 单独 1 个 commit，信息写清改了什么/验证了什么 |

### 2.8 面板与文档同步（漏了等于没做）

- 每个新技能：面板按钮 + 关键词 + 自测项
- 更新 `docs/ai-agent-panel.md`：技能表（**真实状态**）、新参数、文件地图
- 新增 `docs/MaaNTE移植对照表.md`：把 2.2 的表填上最终结论
- 文档里禁止含糊描述；已实现的要写清真实行为与限制
- ⚠️ 每个技能都必须显式写 `ported:`（不要依赖默认值，见缺陷 4）

## 阶段 3：电脑操作真实验收（最终关卡）
**必须用 computer-use 技能真实操作，不许只跑 CLI 自测。**

走查清单（每项留证据）：
1. 启动 app（`./run.sh` 或 open .app）→ 观察主窗口是否正常显示
2. 观察左侧 AI 面板是否**往外扩展**（主 UI 右移，网络地图不被遮挡）
3. 点齿轮图标 → 打开设置 → 确认配置项可见（API Key 已配置状态、Base URL、Model、思考深度 4 档）
4. 逐个点击**新移植的技能按钮** → 观察面板日志是否如实回报
5. 输入复合指令「先登录然后再领奖励」→ 确认 AgentLoop 触发、不卡死、有结果
6. 输入「停止」→ 确认所有技能停止、按键释放
7. 确认**游戏未启动时**的行为安全：技能被护栏拦下（提示"未检测到游戏窗口"），无乱点
8. app 连续运行 60 秒：无崩溃、无 UI 冻结、引擎连接稳定（观察日志无 0.5s 断开重连循环）

**证据要求**：每一步的截图或日志原文。禁止只写"已验证通过"。

================================================================================
# 第 5 章  验收标准（逐条可验证 · 全满足才算完成）
================================================================================

| # | 标准 | 验证方法 | 硬性 |
|---|---|---|---|
| 1 | 编译 0 error | `swift build ... 2>&1 \| grep -c "error:"` = 0 | ✅ |
| 2 | 自测全 PASS 且只增不减 | `./AuroraDriveUI --agent-selftest` → FAIL=0，PASS ≥ 9+新增数 | ✅ |
| 3 | LLM 链路真实可用 | `--agent-llm-test` 30s 内返回 agnes-2.5-flash 真实回答 | ✅ |
| 4 | GUI 不卡死 | 连续发 5 次复合指令，每次都有响应；自测第 7 项 PASS | ✅ |
| 5 | 24 个 MaaNTE 任务逐项有结论 | 对照表每行都填：已移植（含文件:行号）/ 待移植（含缺什么）| ✅ |
| 6 | 电脑操作走查全通过 | 阶段 3 的 8 项，每项有证据 | ✅ |
| 7 | 游戏未开时 0 乱点 | 走查第 7 项；日志有护栏提示 | ✅ |
| 8 | 架构未变 | `git diff c65189d -- Sources/AuroraDrive/{EngineMain,EngineClient,CaptureEngine,ControlEngine,GameMapView}.swift` 输出为空 | ✅ |
| 9 | 执行通道未变 | `git diff c65189d -- AIAgentPanel.swift` 里 `runSkill/toggleSkill/stopAll` 签名 0 改动 | ✅ |
| 10 | 部署同步 | 裸二进制与 `.app` 内二进制 md5 一致 | ✅ |
| 11 | 无远程操作 | `git log --all --oneline` 无 push 痕迹；`git remote -v` 未动 | ✅ |
| 12 | 文档同步 | `docs/ai-agent-panel.md` 技能表与实际一致 | ✅ |

================================================================================
# 第 6 章  工作循环（每轮照此执行）
================================================================================

```
┌─ 每轮开始 ────────────────────────────────────────┐
│ 1. 读任务清单，取下一个未完成项                    │
│ 2. 读相关代码文件（确认真实行号与现状）             │
│ 3. 检查这条改动是否触碰「架构冻结清单」→ 是则跳过    │
└───────────────────────────────────────────────────┘
                    ↓
┌─ 实现 ────────────────────────────────────────────┐
│ 4. 写最小改动（新增优先，改老代码需理由）           │
│ 5. 编译 → grep "error:" 确认 0                     │
│ 6. 修错（超过 2 次失败必须停下来写根因分析）        │
└───────────────────────────────────────────────────┘
                    ↓
┌─ 验证 ────────────────────────────────────────────┐
│ 7. 跑 --agent-selftest，确认 PASS 只增不减          │
│ 8. 针对本次改动写 1 条新自测（如适用）              │
│ 9. 部署 ./run.sh（或原子替换）                      │
│10. 实际运行验证行为（必要时用电脑操作工具）          │
└───────────────────────────────────────────────────┘
                    ↓
┌─ 收尾 ────────────────────────────────────────────┐
│11. git add + commit（信息：改了什么/原因/验证方式） │
│12. 写本轮小结（3 行内）                            │
│13. 更新对照表与进度                                │
└───────────────────────────────────────────────────┘
    ↓  全部任务完成后
┌─ 终验 ────────────────────────────────────────────┐
│14. 跑第 5 章全部 12 条验收                          │
│15. 电脑操作走查 8 项                                │
│16. 输出最终报告（见第 8 章模板）                    │
└───────────────────────────────────────────────────┘
```

================================================================================
# 第 7 章  扩展指南（以后怎么加东西 · 用户明确要求要写清）
================================================================================

## 7.1 加一个新技能（标准 5 步）
```
1. AgentSkillLibrary.all 加一条：
   AgentSkill(id: "new_id", emoji: "🎮", name: "中文名", ported: true,
              warn: false, keywords: ["关键词1", "关键词2"])
2. AIAgentPanel.swift 加实现方法：private func startNewIdLoop(skill:source:dryRun:)
   （照抄第 4 章 2.2 的标准结构：dryRun → 依赖检查 → 游戏窗口护栏 → timer → 日志）
3. execute() switch 加 case "new_id": startNewIdLoop(...)
4. 加成员变量 @ObservationIgnored private var newIdTimer: DispatchSourceTimer?
   teardown(id:) 里加取消 + control.releaseAllGameKeys()
5. AgentSelfTest.run 加 1 条路由自测（仿第 3.5 节写法）
```
**注意**：`ported: false` 的技能会走 `performSnapshotStub`（只回报不动作），
这是"待移植"的合法表示，不是失败。

## 7.2 加一个新 LLM 提供方
- 配置层：`AgentSettings.baseUrl` + `model` 已支持任意 OpenAI 兼容端点
- 注意：`callLLM` 里 baseUrl 归一化逻辑（已含 `/v1` 不重复拼接）
- 支持要求：OpenAI 兼容 `/chat/completions` + `tools` 字段（tool calling）
- 工具定义**必须**带 `parameters` 字段（`{"type":"object","properties":{}}`），
  否则部分服务返回 400（agnes 实测）
- 思考深度映射：1=Low(0.9) 2=Mid(0.5) 3=High(0.2) 4=Max(0.05) → temperature

## 7.3 加一个新的面板功能/UI
- 布局：面板宽 348pt，位于 HStack 最左；改宽度要同步改 `AIAgentEdgeTab` 的 offset
- 新增 UI 组件：加在 `AIAgentPanelView` 内，用现有 Theme 色板（`Theme.cyan` 等）
- 设置类新增项：加在 `AgentSettingsSheet` 的 Form 里 + `AgentSettings` 结构体
  + `save()/load()`（Keychain 存敏感、固定域 UserDefaults 存普通）
- ⚠️ `AgentSettings.defaults` 用的是固定 suite `com.aurora.drive.aiagent`，
  不要改回 `UserDefaults.standard`（会因进程名不同导致 CLI 与 GUI 读到不同配置）

## 7.4 加新的 MaaNTE 任务移植
```
1. 在 MaaNTE/assets/resource/tasks/<Name>.json 找到任务定义（读 entry 字段）
2. 在 MaaNTE/agent/custom/action/ 找到对应 .py 实现
3. 判断分类：A(纯输入) / B(录制) / C(需CV) / D(组合)
4. A/B 类：按第 4 章 2.2 标准结构实现
   C 类：先评估现有 YoloEngine/VisualLocator/NetworkLocator/SpeedOCRReader
5. ⚠️ MaaNTE 是 Windows 专用，禁止照抄 Win32 API（GetAsyncKeyState/PrintWindow/
   PostMessage）——必须换成 macOS 等价物：
   GetAsyncKeyState → CGEventSource.keyState
   PrintWindow      → SCStream (本项目 CaptureEngine 已有)
   PostMessage      → CGEvent (.cghidEventTap)
```

## 7.5 出问题时怎么定位（排障手册）
| 症状 | 首查位置 |
|---|---|
| app 起不来 | `~/Library/Application Support/AuroraDrive/ui.lock` 是否有残留锁；`pkill -9 -f AuroraDriveUI` 后重试 |
| 面板点了没反应 | workQueue 是否被阻塞（检查是否有同步等待）；技能是否已在 runningSkills 里 |
| 出现「已有 AuroraDrive 实例在运行」| 有残留进程，`pkill -9 -f AuroraDrive` |
| 按键不生效 | AppDelegate 辅助功能权限：系统设置 → 隐私 → 辅助功能 |
| 截图失败 | 屏幕录制权限：系统设置 → 隐私 → 屏幕录制 |
| 引擎频繁断开重连 | 是否开了两个 UI 实例 |
| LLM 无响应 | `--agent-llm-test` 单独跑，看是网络还是解析 |
| 编译通过但行为没变 | 是否忘了部署（`./run.sh`）；是否跑的是 `.app` 里的旧二进制 |
| 自测 PASS 数变少 | 立刻回退到上一个 commit，重新分析 |

================================================================================
# 第 8 章  交付物（全部必须有）
================================================================================

## 8.1 代码
- 修好的 LLM 链路（3 个缺陷）
- 新移植的技能（A/B 类全部 + C 类能做的 + D 类）
- 每个新技能配 1 条自测
- 本地 git 提交历史（每项一个 commit，信息清晰）

## 8.2 文档
- 更新 `docs/ai-agent-panel.md`（技能表真实状态、新参数、文件地图）
- 新增 `docs/MaaNTE移植对照表.md`（24 任务逐项结论）

## 8.3 最终报告（必须包含以下 5 部分）
```markdown
# 最终报告

## 一、24 项对照表（全量，无遗漏）
| MaaNTE 任务 | 分类 | 状态 | 实现位置(文件:行号) | 验证方式 | 备注 |
（每行必填，待移植的写清缺什么）

## 二、验收清单（第 5 章 12 条逐条打勾 + 证据）
| # | 标准 | 结果 | 证据 |

## 三、电脑操作走查记录（8 项，每项含截图路径/日志原文）

## 四、改动清单（git diff --stat 输出 + 每个 commit 说明）

## 五、剩余风险与未解决项（如实列出，禁止藏）

## 六、下一步建议（用户后续可以做什么）
```

================================================================================
# 第 9 章  最后的话（给执行的模型）
================================================================================

1. **稳定性 > 完成度**。任务做不完，用户能接受；把 app 搞崩，用户不能接受。
2. **证据 > 记忆**。每个断言都要有 `文件:行号`。不确定就去读代码。
3. **最小改动 > 优雅重构**。这是用户的日常工具，不是练手项目。
4. **如实 > 好看**。"待移植 + 缺什么" 比 "假装做好了" 有价值一万倍。
5. **不提问**。用户要求自主执行，遇到歧义按第 3.4 节规则决策并记录。
6. **每步都要能回退**。保持"删掉新代码 = 回到稳定版"这个性质。
7. **做完一个就提交一个**。别攒着，攒着就丢。

开始吧。第一件事：跑第 4 章「阶段 0：基线复核」，把实测数字写进报告。

================================================================================
# 第 10 章  API 凭证与测试手册（实测验证 · 照此测试）
================================================================================

## 10.1 凭证（完整，直接用）

| 项 | 值 |
|---|---|
| **API Key** | `sk-ZVbxX8ItZyV9n04XDvBshFlVGWKbfRl0Y2concpzmfA5uSSb` |
| **Base URL** | `https://api.agnes-ai.cn/v1` |
| **默认 Model** | `agnes-2.5-flash` |
| **协议** | OpenAI 兼容（`/chat/completions` + `tools`）|
| **当前配置状态** | 已写入 Keychain（service=`com.aurora.drive.aiagent`, account=`apiKey`）与固定域 UserDefaults |

日志/报告里引用 key 时**必须用掩码**：`sk-ZVb…uSSb`（前 6 位 + … + 后 4 位）。

## 10.2 可用模型清单（实测 11 个）

| 模型 | 类型 | Tool-Calling 实测 |
|---|---|---|
| `agnes-2.5-flash` | 对话 | ✅ **已验证**（当前默认，速度快）|
| `agnes-2.5-pro` | 对话 | ✅ **已验证**（能力更强）|
| `agnes-3.0-flash` | 对话 | ✅ **已验证**（新一代）|
| `agnes-2.0-flash` | 对话 | 未测（老版本，可作对照）|
| `agnes-2.5-pro-alpha` | 对话 | 未测 |
| `agnes-2.5-pro-beta` | 对话 | 未测 |
| `agnes-image-2.1-flash` | 图像生成 | N/A（非对话模型）|
| `agnes-image-2.5-flash` | 图像生成 | N/A |
| `agnes-video-2.5` | 视频生成 | N/A |
| `agnes-video-2.5-flash` | 视频生成 | N/A |
| `agnes-video-v2.0` | 视频生成 | N/A |

**推荐**：AgentLoop 默认用 `agnes-2.5-flash`（快）；复杂规划任务可让用户切 `agnes-2.5-pro` 或 `agnes-3.0-flash`。

## 10.3 三条测试路径（从快到慢，全部要跑）

### 路径 A：curl 直连（最快，先验证 API 本身可用）
```bash
API_KEY="sk-ZVbxX8ItZyV9n04XDvBshFlVGWKbfRl0Y2concpzmfA5uSSb"
BASE="https://api.agnes-ai.cn/v1"

# ① 基础对话 —— 期望：返回"1+1等于2。"（本次实测输出）
curl -s -m 30 -X POST "$BASE/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"agnes-2.5-flash","messages":[{"role":"user","content":"用一句话回答：1+1等于几？"}],"max_tokens":100}'

# ② Tool-Calling（AgentLoop 的核心依赖）—— 期望：finish_reason=tool_calls
curl -s -m 30 -X POST "$BASE/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"agnes-2.5-flash","messages":[{"role":"user","content":"帮我打排球"}],"tools":[{"type":"function","function":{"name":"volleyball","description":"自动排球循环","parameters":{"type":"object","properties":{}}}}],"max_tokens":200}'
# 本次实测输出：finish_reason: tool_calls → tool_calls[0].function.name = volleyball
#                tool_calls[0].id = call_17a2364dbd0a4d978e899a75

# ③ 模型清单 —— 期望：返回 11 个模型 id
curl -s -m 20 "$BASE/models" -H "Authorization: Bearer $API_KEY"
```

### 路径 B：app 内 CLI 测试（验证 app 自己的链路）
```bash
cd /Users/dupi/Desktop/自动驾驶系统

# ① 写配置（launcher 级，不需要 GUI，秒回）
./AuroraDriveUI --set-llm-config \
  "sk-ZVbxX8ItZyV9n04XDvBshFlVGWKbfRl0Y2concpzmfA5uSSb" \
  "https://api.agnes-ai.cn/v1" "agnes-2.5-flash"
# 期望：[LLM-CONFIG] ✅ 已保存到 Keychain：model=agnes-2.5-flash  base=...  key=sk-ZVb…uSSb

# ② 端到端真实请求（当前有死锁 BUG，修完必须通过）
./AuroraDriveUI --agent-llm-test
# 期望输出：
# [LLM-TEST] 模型=agnes-2.5-flash  端点=https://api.agnes-ai.cn/v1  密钥=sk-ZVb…uSSb  思考深度=N
# [LLM-TEST] ① 纯文本回答：1+1等于2。
# [LLM-TEST] ② 工具调用：volleyball
# [LLM-TEST] ✅ 真实 LLM 链路验证完成
# 🔴 硬性要求：30 秒内必须结束（现在是永久卡死）

# ③ 验证配置真的落盘了
security find-generic-password -s "com.aurora.drive.aiagent" -a "apiKey" | grep -E "svce|acct"
defaults read com.aurora.drive.aiagent
# 期望输出（本次实测）：baseUrl = "https://api.agnes-ai.cn/v1"; model = "agnes-2.5-flash"; thinkingDepth = N
```

### 路径 C：GUI 面板测试（最终用户视角）
1. 启动 app → 点面板右上角齿轮图标
2. 关掉"⚠️ 本文件含明文 API 凭证"警告后，确认表单里：API Key 已填（圆点显示）、Base URL、Model、思考深度（4 档）
3. 保存 → 输入框输入「帮我打排球」→ 观察是否命中技能
4. 输入「先登录然后再领奖励」→ 观察 AgentLoop 是否触发

## 10.4 API 规格细节（已实测，写代码必须遵守）

| 项 | 规则 |
|---|---|
| 端点 | `POST {base}/chat/completions` |
| 认证 | `Authorization: Bearer <key>` |
| Content-Type | `application/json` |
| **baseUrl 归一化** | 已含 `/v1` 就**不重复拼接**（sefer `hasSuffix("/v1")` 检查）|
| ⚠️ **tools 必填 parameters** | 每个 function 必须有 `"parameters": {"type":"object","properties":{}}`，否则返回 400 `missing field 'parameters'`（实测）|
| temperature 映射 | 思考深度 1=Low→0.9 / 2=Mid→0.5 / 3=High→0.2 / 4=Max→0.05 |
| max_tokens | 1024（AgentLoop）/ 256（纯问答）|
| 响应解析（tool_calls）| `choices[0].message.tool_calls[].{id, function.name}` |
| 响应解析（文本）| `choices[0].message.content` |
| 用量校验 | `usage.{prompt_tokens, completion_tokens, total_tokens}`（本次实测：基础对话 63 tokens、工具调用 323 tokens）|

## 10.5 错误码排查表（实测归纳）

| 现象 | 原因 | 处理 |
|---|---|---|
| `(未配置 API Key)` | Keychain 没读到 | 查 `service=com.aurora.drive.aiagent` / `account=apiKey`；重跑 `--set-llm-config` |
| HTTP **401** | key 无效/过期/未授权 | 重新 `--set-llm-config`，或 curl 路径 A① 单独验证 |
| HTTP **400** `missing field 'parameters'` | tools 定义缺 `parameters` | 每个 function 加 `{"type":"object","properties":{}}` |
| HTTP **404** | baseUrl 拼错（双 `/v1` 或漏 `/v1`）| 检查归一化逻辑：`https://api.agnes-ai.cn/v1` → `/v1/chat/completions` |
| HTTP **429** | 频率限制 | 加间隔重试（不要紧密循环）|
| **超时无响应** | 网络问题 / 未设超时 | 必须设 30s 硬超时（第 2.3 节缺陷 3）|
| `(解析失败)` | 响应结构不符 | 打印原始 `data` 前 500 字节调试 |
| `tool_calls` 为空 | 模型认为不需要工具（纯聊天回复）| **正常**，回退关键词路径，不是 bug |
| 日志里有 key 明文 | 安全违规 | 立刻改成掩码形式 |

## 10.6 测试矩阵（8 项必须全跑，每项留证据）

| # | 测试 | 命令/操作 | 通过标准 |
|---|---|---|---|
| 1 | API 连通 | 路径 A① | 返回中文回答（如"1+1等于2。"）|
| 2 | Tool-Calling 能力 | 路径 A② | `finish_reason=tool_calls` + 函数名正确 |
| 3 | 模型清单 | 路径 A③ | 返回 11 个模型 |
| 4 | 配置写入 | 路径 B① | 打印已保存 + `security`/`defaults` 可查 |
| 5 | **app 端到端** | 路径 B② | 30s 内打印真实模型回答 + 工具调用 |
| 6 | **降级回退** | 改错 key（如 `sk-invalid`）后发指令 | 回退关键词路径，**不卡死**，有错误提示 |
| 7 | 多模型切换 | 换 `agnes-2.5-pro` / `agnes-3.0-flash` 重跑 5 | 同样通过 |
| 8 | GUI 面板 | 路径 C | 命中技能 / 触发 AgentLoop，UI 不冻结 |

**额外压力测试（稳定性验证）**：
- 连续发 5 次复合指令「先登录然后再领奖励」→ 每次都有响应，第 5 次和第 1 次一样快
- 断网 30 秒后发指令 → 有超时提示，不发散，UI 可操作
- `--agent-llm-test` 跑 3 次 → 每次都在 30s 内结束

## 10.7 安全要求（违反 = 严重事故）

❌ **禁止**
- 把 `apiKey` 硬编码进 Swift 源码（用户明确要求：**不能让别人白嫖他的额度**）
- 把 key 打印到日志、报告、console（一律用掩码 `sk-ZVb…uSSb`）
- 把本提示词文件 `git add`（含明文凭证，已加 .gitignore）
- 把 key 写进 `docs/` 任何会被提交的文件
- 把 key 传到任何第三方服务/粘贴板

✅ **允许/必须**
- key 存 macOS Keychain（service `com.aurora.drive.aiagent`, account `apiKey`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）
- 代码只通过 `AgentSettings.load()` 读 key
- 测试时用 shell 变量传 key（`API_KEY="..."`），避免出现在 `ps` 输出里

## 10.8 如果 API 挂了/额度用尽（备用方案）
1. 先确认是不是网络问题：`curl -s -m 10 https://api.agnes-ai.cn/v1/models -H "Authorization: Bearer $API_KEY"`
2. 若是 402/额度问题 → **不要自行换供应商或花钱**，在报告里标注"LLM 链路待用户续费后验证"
3. 若 API 不可用：**继续做阶段 2 的技能移植**（那部分不依赖 LLM），最后统一验证 LLM
4. LLM 不可用**绝不允许**阻塞其他任务进度

================================================================================
# 第 11 章  快速开始（复制粘贴就能跑的第一批命令）
================================================================================

```bash
cd /Users/dupi/Desktop/自动驾驶系统

# ── 0. 基线复核 ──
git log --oneline -5
git status --short
grep -c "" Sources/AuroraDrive/*.swift | tail -3
find MaaNTE -path "*custom/action*" -name "*.py" | wc -l

# ── 0.1 基线编译 + 自测 ──
pkill -9 -f AuroraDrive 2>/dev/null; sleep 1
/usr/bin/swift build -c release --disable-sandbox --scratch-path .build/scratch 2>&1 | grep -c "error:"
cp .build/scratch/release/AuroraDrive AuroraDriveUI && chmod +x AuroraDriveUI
./AuroraDriveUI --agent-selftest 2>&1 | grep AGENT-SELFTEST

# ── 0.2 API 可用性（30 秒内出结果）──
API_KEY="sk-ZVbxX8ItZyV9n04XDvBshFlVGWKbfRl0Y2concpzmfA5uSSb"
curl -s -m 30 -X POST "https://api.agnes-ai.cn/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"agnes-2.5-flash","messages":[{"role":"user","content":"用一句话回答：1+1等于几？"}],"max_tokens":100}'

# ── 1. 开始修缺陷 1（--agent-llm-test 死锁）──
#     位置：AuroraDriveApp.swift launcher 的 --agent-llm-test 分支
#     手法：去掉「主线程信号量 + Task」，改纯同步 HTTP + 30s 硬超时
#     验收：./AuroraDriveUI --agent-llm-test 30s 内打印真实模型回答

# ── 2. 开始修缺陷 2（GUI 复合任务信号量）──
#     位置：AIAgentPanel.swift:921-931
#     验收：自测第 7 项 PASS + 连续 5 次复合指令不卡

# ── 3. 开始修缺陷 3（网络超时）──
#     位置：AIAgentPanel.swift:313 / :370
#     验收：断网测试 30s 内返回失败并回退

# ── 4. 阶段 2：按对照表逐项移植 ──
#     从最简单的 touch 开始，一个一个来，每个都：编译→自测→提交

# ── 5. 阶段 3：电脑操作验收 ──
#     用 computer-use 技能真实操作 app，8 项走查，每项留证据
```

**记住三条**：
1. 🔴 稳定性 > 完成度
2. ✅ 证据 > 记忆（每个断言附 `文件:行号`）
3. 📝 如实 > 好看（"待移植+缺什么" 胜过 "假装做好了"）

================================================================================
# 第 12 章  弱模型容错架构（Agnes 专项 · 防"突然炸掉"）
================================================================================

## 12.0 背景：为什么必须专门设计
本项目用的云端模型 `agnes-2.5-flash` 已知弱点：
- **注意力分散**：长提示词/长上下文里丢指令
- **上下文管理弱**：多轮历史喂回去会"忘记"前面说了什么
- **指令遵循差**：给了格式要求也可能不遵守，容易自由发挥

同时它要驱动的是**会真实按键/点击游戏**的系统。它一旦"想歪"，后果是用户的
角色被乱操作。所以必须：**假设模型随时会犯错，系统必须在它犯错时兜住。**

## 12.1 核心原则：弱模型只做选择题，不做填空题

| 弱模型的强项 | 弱模型的弱项 |
|---|---|
| 从 3-7 个有限选项里挑一个 | 自由生成内容 |
| 短提示下的简单判断 | 长上下文里的多步推理 |
| 单轮明确指令 | 多轮状态跟踪 |

**设计后果**：
1. 每一步只让它**选一个技能**（不要求它输出计划序列）
2. 系统提示**越短越好**（一句话一个技能，不用长描述）
3. 状态由**代码维护**，不由模型维护（代码告诉它"已经做过 X 了"）
4. 格式由 **API 协议强制**（tool calling ≈ 结构化输出），不靠模型自觉

## 12.2 十道防线（分层防护 · 从外到内）

### 防线 1：提示词与协议必须一致（最高优先级）
🔴 **已发现缺陷**：`AIAgentPanel.swift` 的 `callLLM` 系统提示词写着
```
返回 JSON 数组，每个元素包含 skillID 和 args。
只返回技能 ID，不要多余解释。
```
但代码实际用的是 **tool calling**（`tools` 字段 + `tool_calls` 解析）。
**两者打架 = 弱模型必然困惑/发散。**

✅ **修法**：系统提示改成与 tool calling 一致的极简版：
```
你是异环游戏自动化助手。用提供的工具完成用户任务。
一次只调用一个工具。不要解释，不要输出 JSON 文本。
```
**原则**：能用 API 协议约束的，绝不写在提示词里求模型自觉。

### 防线 2：只把"真实可用"的技能给模型
```swift
// 生成 tools 数组时，从 AgentSkillLibrary 动态过滤
let tools = AgentSkillLibrary.all
    .filter { $0.ported == true }          // ← 只给已移植的
    .map { toolDecl($0.id, $0.name) }      // 描述用短名字，不用长描述
```
✅ 现状：`callLLM` 里硬编码了 7 个真实技能，**这一点是对的**。但改技能表时
必须同步，建议直接改成上面这种动态过滤，避免漏改。

### 防线 3：执行前三重校验（存在 + 已移植 + 未在运行）
```swift
private func validate(_ call: AgentToolCall) -> String? {
    guard let skill = AgentSkillLibrary.all.first(where: { $0.id == call.skillID }) else {
        return "未知技能「\(call.skillID)」（模型幻觉，已丢弃）"
    }
    guard skill.ported == true else {
        return "技能「\(skill.name)」尚未移植（模型越界，已拒绝）"
    }
    guard !AgentSkillCenter.shared.runningSkills.contains(call.skillID) else {
        return "技能「\(skill.name)」已在运行（重复调用，已跳过）"
    }
    return nil   // 校验通过
}
```
🔴 **现状缺陷**：`AgentLoop.swift:133` 只检查了"存在"，**没检查 `ported`**。
→ 弱模型可以调用未移植技能（会走 snapshotStub 假装动作）。**必须补上。**

### 防线 4：单步化（不让弱模型做序列规划）
🔴 **现状风险**：`AgentLoop.handle` 的 `plan()` 返回**数组** `[AgentToolCall]`，
弱模型容易一次生成 3-5 个工具调用（发散/重复/顺序错乱）。

✅ **修法**（二选一，推荐 A）：
- **A（推荐）**：`plan()` 只取第一个调用，其余丢弃并记日志
  ```swift
  var calls = await planner.plan(task: task)
  if calls.count > 1 {
      progress("⚠️ 模型一次返回 \(calls.count) 个调用，只执行第一个（防发散）")
      calls = [calls[0]]
  }
  ```
- **B**：后续步骤全部走 `nextStep()`（每步一个），不再用批量 plan

### 防线 5：防重复死循环
```swift
// 记录每个技能被调用次数
var callCounts: [String: Int] = [:]
// 执行前
let n = (callCounts[call.skillID] ?? 0) + 1
callCounts[call.skillID] = n
if n > 3 {
    progress("⚠️ 技能「\(skillName(call.skillID))」已调用 \(n) 次，强制停止（防死循环）")
    break
}
```
弱模型的典型病症：反复调用同一个技能（因为看不到进展）。
必须由**代码**兜住，不能指望模型自己停。

### 防线 6：硬熔断（三个上限，任一触发即终止）
```swift
let maxSteps = 8                    // 已有：步数上限
let maxDuration: TimeInterval = 60  // 新增：总时长上限
let maxFailedSteps = 2              // 新增：连续失败上限

let startTime = Date()
var consecutiveFailures = 0

// 循环内检查
if Date().timeIntervalSince(startTime) > maxDuration {
    progress("⏱️ 任务超过 60s 上限，强制终止")
    break
}
// 每次执行后
if result.ok { consecutiveFailures = 0 }
else {
    consecutiveFailures += 1
    if consecutiveFailures >= maxFailedSteps {
        progress("❌ 连续 \(maxFailedSteps) 步失败，终止任务")
        break
    }
}
```

### 防线 7：上下文裁剪（针对"上下文管理弱"）
🔴 **现状风险**：`history` 全量累积后喂回模型，弱模型会因上下文变长而"失忆"。

✅ **修法**：
```swift
// 只保留最近 3 步喂给模型
let recentHistory = Array(history.suffix(3))
// 每条 summary 截断，防止单条过长
let trimmed = recentHistory.map {
    AgentToolResult(id: $0.id, skillID: $0.skillID, ok: $0.ok,
                    summary: String($0.summary.prefix(120)))
}
```
**原则**：模型不需要知道全部历史，只需要知道"刚刚发生了什么"。

### 防线 8：熔断开关 + 一键降级
- `AgentSkillCenter` 加 `@ObservationIgnored var llmFailureStreak = 0`
- 连续 3 次 LLM 调用失败（超时/解析失败/校验全被拒）→ 自动
  `useLLM = false`，后续任务走 `MockLLMPlanner`（关键词规则，零幻觉）
- 面板加开关：**"AI 规划"** 开/关，用户可随时手动切
- 降级时**必须在面板打印**："⚠️ AI 规划连续失败，已自动降级为本地规则模式"
- 恢复：用户手动开启，或下一轮成功后重置计数

### 防线 9：最坏情况封顶（根本安全边界）
**即使模型完全失控，最坏结果是"调用了白名单里的某个真实技能"。**

这条成立的三个前提（必须一直保持）：
1. **模型永远不能直接生成按键序列**——只能调用预定义技能 ID
2. **每个技能内部都有**：dryRun 检查 + 游戏窗口护栏 + 轮数上限 + 停止即释放
3. **技能白名单是代码常量**（`AgentSkillLibrary`），模型无法新增

→ 所以在最坏情况下，用户受到的伤害上限 = "某个安全技能跑了一轮"，
而不是"角色被无限乱按"。**这个性质就是整个系统的安全地基，禁止破坏。**

### 防线 10：可观测（出问题能查）
每次 LLM 调用记录（打到面板日志）：
```
[LLM] 步 3/8 | prompt=312tok | 耗时=1.8s | 返回=volleyball | 校验=通过
[LLM] 步 4/8 | prompt=380tok | 耗时=2.1s | 返回=pinkpaw   | 校验=拒绝（未移植）
```
- `callLLM` 里打印：请求的 tool 数量、响应 `finish_reason`、解析出的调用数
- 校验失败的调用**必须打日志**（否则"模型被拒绝"这件事用户看不到）
- 便于用户判断"是模型问题还是系统问题"

## 12.3 已发现的 2 个具体缺陷（必须修）

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 1 | `AIAgentPanel.swift` `callLLM` 系统提示词 | 写着"返回 JSON 数组…"，与实际 tool calling 协议**打架** → 弱模型指令遵循差的直接原因 | 改成极简 tool calling 提示（防线 1）|
| 2 | `AgentLoop.swift:133` | 只校验技能**存在**，未校验 `ported` → 模型可越界调用未移植技能 | 补三重校验（防线 3）|

## 12.4 四级降级策略（清晰的分级）
```
第 0 级：关键词直配        零 LLM，确定性，永远可用（保底）
第 1 级：单技能 LLM 选择    工具调用 + 白名单校验（默认路径）
第 2 级：本地规则规划       MockLLMPlanner（LLM 挂了自动降级到这）
第 3 级：本地兜底回复       连关键词都没命中时的提示
```
**关键洞察**：第 0 级必须永远能独立工作。任何 LLM 故障都不许影响第 0 级。
设计任何 LLM 功能时都要问：**"如果 LLM 返回垃圾，用户还能正常用吗？"**
答案必须是"能"。

## 12.5 双模型策略（可选优化）
弱模型贵在快，强模型贵在准。可以让用户按任务类型选：
| 场景 | 建议模型 | 理由 |
|---|---|---|
| 单技能选择（"打排球"）| `agnes-2.5-flash` | 简单选择题，快就行 |
| 多步复合规划（"先登录再领奖再钓鱼"）| `agnes-2.5-pro` 或 `agnes-3.0-flash` | 已验证支持 tool calling，规划更稳 |
- 设置页可加"规划模型"下拉（默认跟随主模型）
- 不做自动切换（自动切换会引入不确定性，违反稳定性优先）

## 12.6 弱模型提示词工程要点（写提示时遵守）
1. **短**：系统提示 ≤ 150 字。越长越容易丢指令。
2. **一次一件事**：不说"你可以做 A 也可以做 B 还可以做 C"，而是"当前该做什么"。
3. **用协议不用嘴**：格式要求交给 tool calling 的 schema，不在提示词里描述格式。
4. **状态由代码注入**：已经执行过什么，由代码拼进 prompt，不要让模型自己记。
5. **few-shot 优于长描述**：给 2 个例子比写 200 字说明管用。
6. **禁止开放生成**：不给"你也可以自由发挥"这类口子。
7. **失败要说人话**：模型返回空/乱码时，日志写清"模型未返回工具调用"，
   不要静默当成功。

## 12.7 验收（弱模型容错专项）
| # | 测试 | 期望 |
|---|---|---|
| 1 | 故意让模型返回不存在的技能名 | 被防线 3 拒绝 + 打日志 + 不崩 |
| 2 | 故意让模型返回未移植技能（如 pinkpaw）| 被拒绝 + 提示"尚未移植" |
| 3 | 连续发同一个指令 5 次 | 第 4 次被防线 5 拦住，不无限循环 |
| 4 | 把 API key 改成错的 | 30s 内失败 → 降级关键词路径 → 指令仍可用 |
| 5 | 断开网络后发指令 | 同上，UI 可操作 |
| 6 | 发超长/乱码指令 | 不崩，有兜底回复 |
| 7 | 复合任务跑满 8 步 | 到上限自动停 + 打印终止原因 |
| 8 | 复合任务超过 60s | 自动终止 + 打印原因 |

**这一章的核心**：不要指望弱模型变聪明，**要让它犯错时系统不倒**。
