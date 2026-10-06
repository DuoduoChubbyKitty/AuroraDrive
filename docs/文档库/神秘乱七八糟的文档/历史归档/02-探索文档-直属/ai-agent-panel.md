# AuroraDrive AI Agent 面板 — 架构与开发文档

> 版本：v2（2026-09-14）
> 本文档介绍 AuroraDrive（macOS 原生驾驶辅助）左侧 AI Agent 面板的：
> 统一技能执行通道、自动登录守护、技能移植状态、自测入口。
> 面向后续开发（尤其端到端 AI 模型直接调用技能）而写。

> 【2026-09-19 现状更新】① legacy 按键循环（volleyball/fishing/dodge/auto_scroll）已补「启动前 + 每轮」双层 `GameWindowDetector.isGameVisible()` 护栏（adb63ad，`docs/文档库/自动驾驶与功能/legacy-guard-patch.md` 已被代码实现取代）；② 自测由 9 项扩至 **21 项**（PASS=21 FAIL=0，含 10 项新技能路由 + ported 一致性 2 项，见 `docs/文档库/探索文档/最终报告.md`）；③ 无 API Key 时输入区上方出现「未配置模型·点我填写」CTA（6ddb752）；④ 新增 `--agent-command "<指令>"` 真实 LLM 规划入口（d9132fe）且命令模式不抢焦点（7913546）、派发与引擎注入移至 AppDelegate 不依赖视图渲染（fa798e3）；⑤ 技能库现为 **18 条**（15 已移植 + 3 待移植，与代码 `AgentSkillLibrary.all` 逐条一致）。

---

## 目录

1. [总体架构](#1-总体架构)
2. [统一执行通道（核心概念）](#2-统一执行通道核心概念)
3. [技能清单与移植状态](#3-技能清单与移植状态)
4. [自动登录与守护模式](#4-自动登录与守护模式)
5. [安全护栏：GameWindowDetector](#5-安全护栏gamewindowdetector)
6. [新增一个技能（开发指南）](#6-新增一个技能开发指南)
7. [自测与调试](#7-自测与调试)
8. [文件地图](#8-文件地图)

---

## 1. 总体架构

```
┌─────────────────────────────────────────────────────────┐
│                    AuroraDrive App (SwiftUI)             │
│                                                          │
│  ┌──────────────┐    ┌───────────────────────────────┐   │
│  │ AIAgentEdgeTab│→→→│      AIAgentPanelView         │   │
│  │ (左侧边缘箭头) │    │  技能网格 / 对话 / 输入区      │   │
│  └──────────────┘    └──────────────┬────────────────┘   │
│                                     │ 点击按钮 (source:.human)│
│                                     ▼                     │
│  ┌───────────────────  AgentSkillCenter (单例)  ───────┐  │
│  │  toggleSkill(_:source:) / runSkill(_:source:)       │  │
│  │  —— 人类点击 与 AI 指令共用的「唯一执行通道」          │  │
│  └──────────┬──────────────────────────────────────────┘  │
│             │ execute(skill) 派发到具体处理器             │
│     ┌───────┼──────────┬───────────────┬──────────────┐  │
│     ▼       ▼          ▼               ▼              ▼  │
│ LoginAssist 排球循环  OCR点击循环    快照占位        (未来  │
│ autoLogin  K键0.6s   rewards/      待移植技能       模型直 │
│ (登录守护)  (真实)    furniture       (如实标注)      接调用 │
│                       (真实)                          )   │
│                                                          │
│  引擎注入: ControlEngine(capture/按键) CaptureEngine(截屏)│
│           在 DriveState / ContentView.onAppear          │
└─────────────────────────────────────────────────────────┘
```

### 依赖注入时点

- **AppDelegate**（applicationDidFinishLaunching）：处理 `--auto-login` 参数，
  调用 `AgentSkillCenter.shared.requestAutoLoginOnStartup()`。
  此时引擎可能尚未注入，技能中心会**排队**，等 ContentView.onAppear
  调 `configure(control:capture:)` 后自动补启。
- **ContentView.onAppear**：`AgentSkillCenter.shared.configure(control: state.controlEngine, capture: state.captureEngine)`
  这是引擎（按键注入 + 截屏）注入到技能中心的唯一入口。

---

## 2. 统一执行通道（核心概念）

**设计意图**：人类点按钮与 AI 指令必须走**同一条**代码路径，
这样任何技能都「人类可调 / AI 可调 / 行为一致」——为将来大模型
端到端调用技能铺路（模型只发指令字符串，不关心底层差异）。

### 调用方式

| 调用者 | 入口 | source |
|---|---|---|
| 人类点击技能按钮 | `toggleSkill(id, source: .human)` | `.human` |
| AI 收到「帮我领奖励」 | `sendUserMessage(text, source: .ai)` → 解析 → `runSkill(id, source: .ai)` | `.ai` |
| 启动参数 `--auto-login` | AppDelegate → `requestAutoLoginOnStartup()` | `.ai` |

### 消息解析（sendUserMessage）

1. 停止指令优先：文本含「停止/停一下/停下」→ `stopAll`
2. 技能关键词匹配：遍历 `AgentSkillLibrary.all`，`keywords` 任一命中即调技能
   （如「钓鱼」→ fishing；「帮我领奖励」→ rewards）
3. 否则本地命令回复（状态汇总 / 模型信息 / 帮助），不做假 LLM 承诺

### dryRun 快照语义

`execute(_:source:)` 在**启动瞬间捕获 `isDryRun` 快照**并传给处理器——
异步队列执行时自测标记可能已被外部重置，必须用启动时的值决定是否真发
输入/点击，保证自测确定、绝不误动真机。

---

## 3. 技能清单与移植状态

定义在 `AgentSkillLibrary.all`（`AIAgentPanel.swift`）。

| id | 名称 | emoji | 状态 | 真实实现 |
|---|---|---|---|---|
| `auto_login` | 自动登录 | 🔑 | ✅ 已移植 | OCR 定位登录按钮 → 鼠标点击 → 守护模式 |
| `volleyball` | 自动排球 | 🏐 | ✅ 已移植 | K 键每 0.6s 短按循环（MaaNTE 核心循环直移植） |
| `fishing` | 自动钓鱼 | 🎣 | ✅ 已移植 | F 抛竿/收杆节奏循环（基础版，后续接 CV） |
| `coffee` | 自动做咖啡 | 🥤 | ✅ 已移植 | F 键交互 ×20 轮循环（MaaNTE AutoMakeCoffee 简化版，MaaNTE原版需视觉管线） |
| `coffee_lite` | 轻量做咖啡 | 🥛 | ✅ 已移植 | F 键交互 ×10 轮循环（MaaNTE AutoMakeCoffeeLite，make_count=10 快速版） |
| `bagel_spam` | 贝果刷屏 | 🥯 | ✅ 已移植 | 内置文案 6 轮 × 2s（ControlEngine.typeText，MaaNTE BagelSpam 简化版，需聊天框聚焦） |
| `furniture` | 自动收家具 | 🪑 | ✅ 已移植 | OCR 定位「收取/一键收取」→ 循环点击 |
| `rewards` | 自动领奖励 | 💎 | ✅ 已移植 | OCR 定位「领取/一键领取」→ 循环点击 |
| `piano` | 自动弹钢琴 | 🎹 | ✅ 已移植 | 内置曲目 G/H/I/Y/U 音键序列（MaaNTE MIDI 文件解析未做） |
| `dodge` | 自动闪避 | ⚔️ | ✅ 已移植 | Space 跳跃 + Shift 疾跑组合循环 |
| `auto_scroll` | 自动滚动 | 📜 | ✅ 已移植 | F 连点 + 鼠标滚轮向下（拾取/翻页类交互） |
| `touch` | 自动抚摸 | ✋ | ✅ 已移植 | 游戏窗口内安全点击序列（MaaNTE TouchDetect 简化版） |
| `drive_dataset` | 驾驶数据采集 | 🎬 | ✅ 已移植 | 复用 RecordEngine：CGEventSource 采样 WASD → steer/throttle/brake 标签 + 帧 JPEG（MaaNTE B 类，2fps/5帧序） |
| `preset_afk` | 挂机预设 | 🛋️ | ✅ 已移植 | 串联 rewards→furniture→fishing 三段定时启动（D 类编排，无新注入） |
| `tomato_juice` | 自动做番茄汁 | 🍅 | ✅ 已移植 | F 键 ×20 轮循环（MaaNTE AutoMakeTomatoJuice 简化版，倒计时/双份服务未实现） |
| `pinkpaw` | 粉爪大劫案 | 🐾 | ⏳ 待移植 | C 类：多阶段 UI 识别（缺 OCR/CV 适配层，Win32 控制器不适用） |
| `rhythm` | 自动超强音 | 🎵 | ⏳ 待移植 | C 类：音游轨道实时检测（缺 60fps 级 YOLO 集成） |
| `preset_realtime` | 实时辅助预设 | ⚡ | ⏳ 待移植 | D 类依赖 C 类 `realtime`（未实现），保守标 false |

> 待移植技能（`ported: false`）点击后执行 `performSnapshotStub`：保存现场截图到
> `/tmp/aurora_agent_<id>.png` + 系统消息如实告知。UI 按钮标「待移植」，
> LLM tools 按 `.filter { $0.ported }` 动态过滤（不暴露给模型），AgentLoop
> 执行前三重校验（存在 + 已移植 + 未在运行）拦截越界调用。
> `ported` 默认值为 `false`（漏标即视为待移植），一致性由自测检查项覆盖。

### OCR 点击全家桶（新增 OCR 类技能只需配关键词）

```swift
LoginAssistant.locateButton(_ keywords: [String], in: CGImage, scale: CGFloat)
  → (text: String, point: CGPoint)?
```

`performUIClickLoop(skill:source:dryRun:)` 是通用执行器：
截图 → OCR 定位「领取/收取」按钮 → 鼠标点击 → 等 UI 反应重试，最多 8 轮；
按钮消失即完成；找不到按钮如实回报「需要先打开对应界面」；可中途停止。

---

## 4. 自动登录与守护模式

### 触发链

```
--auto-login (run.sh 默认带)
  → AppDelegate.applicationDidFinishLaunching
  → AgentSkillCenter.requestAutoLoginOnStartup()
  → (引擎未注入则排队；configure 后补启 / 8s 兜底)
  → runSkill("auto_login", .ai)
  → performAutoLogin
  → 第一轮立即尝试
      ├─ 有游戏窗口 → LoginAssistant.runAutoLogin(全 3 轮关键词)
      ├─ 无游戏窗口 → startLoginWatch（守护等待）
      └─ 截屏不可用 → 如实报告，停止
```

### 守护模式（startLoginWatch）

- 每 **8 秒** tick 一次，最多 **10 次 = 80 秒** 上限
- 每轮先 `GameWindowDetector.isGameVisible()`：
  - 有游戏窗口 → 尝试点击（maxRounds 1，只认主按钮，避免狂点）
  - 无游戏窗口 → **安静等待下一轮**（游戏未启动，不点击不等于状态错误）
- 成功（按钮消失）→ 停止；超时 → 停止并提示
- 用户再点技能按钮可随时取消

### LoginAssistant 关键词优先级

```
点击进入 > 进入游戏 > 点击屏幕继续 > 登录游戏 > 登录/登入 > 开始游戏 > 开始 > 确认 > 连接
```

坐标换算链（全部已验证）：
```
Vision bbox（归一化，左下原点）
  → 截图像素（左上原点）：px = midX·W，py = (1 − midY)·H
  → 屏幕点（CGEvent 左上原点）：point = pixel / backingScaleFactor
```

---

## 4. AgentLoop — 端到端任务循环（原生 Tool-Calling）

```
用户指令 → LLM 规划 → [技能1] → 结果回传 LLM → [技能2] → ... → 完成总结
         ↑                                            ↓
     MockLLMPlanner                              RealLLMPlanner
     (无 API Key 时)                             (有 API Key 时)
```

### 4.1 双规划器设计

| 规划器 | 触发条件 | 行为 |
|---|---|---|
| `MockLLMPlanner` | 无 API Key | 关键词匹配 → 确定性技能序列 |
| `RealLLMPlanner` | 有 API Key | 调用云端 LLM → 返回 `tool_use` JSON → 逐个执行 |

### 4.2 用户配置流程（小白友好）

1. 打开 AuroraDrive，点击左侧 AI 面板顶部 ⚙️ **设置**按钮
2. 粘贴 API Key（如 `sk-xxxxxxxx`）
3. 填入 BaseUrl（如 `https://api.deepseek.com`）
4. 填入 Model（如 `deepseek-chat`）
5. 点击「保存」→ 密钥存入 **本地小本本文件**（`~/Library/Application Support/AuroraDrive/llm-key-notebook.txt`，0600，**不再访问 macOS 钥匙串**——2026-09-15 起，启动路径 0 钥匙串接触）

### 4.3 支持的云端 LLM

所有 OpenAI 兼容协议接口：
- **DeepSeek**: `https://api.deepseek.com` / `deepseek-chat`
- **OpenAI**: `https://api.openai.com` / `gpt-4o-mini`
- **Anthropic**: `https://api.anthropic.com` / `claude-3-5-haiku-20241022`

### 4.4 安全设计

- API Key 存 **本地小本本文件**（0600，`~/Library/Application Support/AuroraDrive/llm-key-notebook.txt`）——2026-09-15 起不再使用 Keychain（每次启动读 Keychain 是启动异常根因，用户指令移除）
- BaseUrl / Model 存 **UserDefaults**（非敏感，可同步）
- 每次调用 LLM 前检查 `apiKey.isEmpty`，未配置时降级到 Mock
- 不记录、不传输、不缓存 API Key

### 4.5 面板 UI 改进（2026-09-15，commit d43b253 / 039daba）

- **模型菜单 = 真实清单**：原硬编码假模型（Claude 3.5/GPT-4o/Gemini 2.0/DeepSeek-V3，从未连通）已移除；改为从 API `/models` 实时拉取（15s 硬超时，过滤 image/video 非对话模型），选中直写 `aiSettings.model`（真实生效）+ UserDefaults 持久化；拉取失败显示当前模型兜底 + 「刷新模型列表」入口
- **⚡ 一键自动化挂机**：技能网格上方大号按钮，一条指令启动 `preset_afk` 链（领奖励→收家具→钓鱼），运行中变 ⏸ 红色可点停（同一执行通道 `toggleSkill`）
- **技能网格降噪**：待移植技能（3 项：pinkpaw/rhythm/preset_realtime）默认隐藏，底部「显示/收起待移植技能」开关可展开；默认视图只显示 15 个可用技能
- **快速填充修正**（1980bc9）：示例按钮（新增 Agnes 默认项）不再清空已填 API Key（原行为清空 key → 保存按钮禁用，是"设置页没法填"的根因之一）

---

## 5. 安全护栏：GameWindowDetector

**为什么必须有它**：登录守护是全屏 OCR，会把屏幕上所有文字都识别。
没有护栏时，浏览器 / QQ / 甚至 DSH 自己窗口里的「登录」二字都会被当成
游戏登录按钮点掉 —— 灾难。

```swift
GameWindowDetector.isGameVisible() -> Bool
// CGWindowListCopyWindowInfo 枚举所有前台窗口，
// owner 或 title 含「异环 / NTE」即判定为游戏窗口
```

应用点：
- `performAutoLogin` 第一轮：无游戏窗口 → 直接进守护（绝不 OCR 点击）
- 守护每轮 tick：无游戏窗口 → 等待；有才允许点击
- （2026-09-16 adb63ad）legacy 按键循环 volleyball/fishing/dodge/auto_scroll 均已补「启动前 + 每轮」双层 `isGameVisible()` guard，游戏中途消失自动停；`docs/文档库/自动驾驶与功能/legacy-guard-patch.md`（3 处 1 行 guard 补丁）已被代码实现取代

---

## 6. 新增一个技能（开发指南）

### 6.1 加技能定义（AgentSkillLibrary.all）

```swift
AgentSkill(id: "my_skill", emoji: "✨", name: "我的技能",
           keywords: ["我的", "米"]),   // AI 指令触发词
```

### 6.2 加处理器分发（execute 的 switch）

```swift
case "my_skill":
    performMySkill(skill: skill, source: source, dryRun: dryRun)
```

### 6.3 写处理器（三个原则）

1. **走 workQueue 异步执行**（`execute` 已在 workQueue，直接在里面做耗时工作）
2. **dryRun 分支最先判断**：自测时只验证链路，不真发输入/点击
3. **如实回报**：开始/进度/结果都 appendSystem 到会话，UI 自动显示

```swift
private func performMySkill(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
    guard !dryRun else {
        appendSystem("✅ 自测：\(skill.name) 链路就绪")
        runningSkills.remove(skill.id)
        return
    }
    // ... 真实逻辑（ControlEngine / MouseController / LoginAssistant）...
    runningSkills.remove(skill.id)
}
```

### 6.4 需要鼠标点击的：复用 OCR 全家桶

```swift
// LoginAssistant.locateButton(任意关键词, in: cg, scale:) 已有通用版
let hit = loginAssistant.locateButton(["一键领取", "领取"], in: cg, scale: scale)
if let hit { mouse.click(at: hit.point) }
```

### 6.5 加自测（AgentSelfTest）

`AgentSelfTest.run` 里加一条（dryRun 模式验证路由即可）：

```swift
center.isDryRun = true
center.sendUserMessage("我的技能", source: .ai)
let routed = center.messages.contains { $0.text.contains("命中技能") }
center.stopAll(source: .ai)
center.isDryRun = false
log(routed, "指令解析→我的技能", routed ? "命中 my_skill" : "未命中")
```

---

## 7. 自测与调试

### 7.1 启动参数

| 参数 | 作用 |
|---|---|
| `--agent-selftest` | 逻辑链路自测（**21 项**；2026-09-15 起真实 GUI 会话 PASS=21 FAIL=0，含 10 项新技能路由 + ported 一致性 2 项），PASS 数写 stdout 后 exit(0/1) |
| `--agent-command "<指令>"` | 走与对话框相同的 `sendUserMessage(.human)` 管线，由真实云端 LLM 规划（tool_calls）后执行技能（d9132fe）；命令模式 `.accessory` 不抢焦点（7913546），派发与引擎注入移至 AppDelegate、不依赖视图渲染（fa798e3） |
| `--agent-ui-shot` | SwiftUI ImageRenderer 无头渲染 AI 面板 → `/tmp/aurora_ui_shot.png`（无需屏幕权限） |
| `--agent-layout-shot` | 折叠/展开两帧布局对比图 → `/tmp/aurora_layout_compare.png`（验证往外扩展） |
| `--auto-login` | 启动即自动登录守护（run.sh 默认带） |
| `--auto-seconds N` | N 秒后自动退出（无人值守测试用） |

> 注意：`--auto-seconds` 是测试辅助参数。`--auto-login` 的守护不依赖
> UI 渲染，两者共用时先由 AppDelegate 起守护、ContentView 注入引擎后补跑。

### 7.2 运行时日志

- stdout 已是**行缓冲**：重定向到文件时 print 实时落盘，不丢日志
- 技能中心写 `/tmp/aurora_debug.log`（与 DriveState.dlog 同款 10MB 封顶策略）
- AI 面板消息同时进 UI 会话区

---

## 8. 文件地图

| 文件 | 内容 |
|---|---|
| `Sources/AuroraDrive/AIAgentPanel.swift` | 技能中心 + 面板 UI + AgentSettings + GameWindowDetector + 自测（约 1700 行） |
| `Sources/AuroraDrive/AgentLoop.swift` | AgentLoop 主循环 + MockLLMPlanner + RealLLMPlanner（~230 行） |
| `Sources/AuroraDrive/MouseController.swift` | CGEvent 鼠标注入（含 scrollWheel 滚轮） |
| `Sources/AuroraDrive/LoginAssistant.swift` | OCR 定位 + 自动登录 + 守护引擎 |
| `Sources/AuroraDrive/ControlEngine.swift` | 按键注入（含 GameKey 30+ 键） |
| `Sources/AuroraDrive/AuroraDriveApp.swift` | AppDelegate（--auto-login）/ ContentView（HStack 往外扩展布局 + configure）/ DriveState |
| `run.sh` | 一键编译 + 部署 + 启动（默认 --auto-login） |