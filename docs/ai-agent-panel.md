# AuroraDrive AI Agent 面板 — 架构与开发文档

> 版本：v2（2026-09-14）
> 本文档介绍 AuroraDrive（macOS 原生驾驶辅助）左侧 AI Agent 面板的：
> 统一技能执行通道、自动登录守护、技能移植状态、自测入口。
> 面向后续开发（尤其端到端 AI 模型直接调用技能）而写。

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
| `auto_login` | 自动登录 | 🔑 | ✅ 真实 | OCR 定位登录按钮 → 鼠标点击 → 守护模式 |
| `volleyball` | 自动排球 | 🏐 | ✅ 真实 | K 键每 0.6s 短按循环（MaaNTE 核心循环直移植） |
| `rewards` | 自动领奖励 | 💎 | ✅ 真实 | OCR 定位「领取/一键领取」→ 循环点击 |
| `furniture` | 自动收家具 | 🪑 | ✅ 真实 | OCR 定位「收取/一键收取」→ 循环点击 |
| `fishing` | 自动钓鱼 | 🎣 | ⏳ 待移植 | 需视觉管线（鱼漂检测），现为快照占位 |
| `coffee` | 自动做咖啡 | 🥤 | ⏳ 待移植 | 需视觉管线 |
| `pinkpaw` | 粉爪大劫案 | 🐾 | ⏳ 待移植 | 依赖 MaaNTE Win32 控制器 |
| `piano` | 自动弹钢琴 | 🎹 | ⏳ 待移植 | 需 MIDI 输入 + 键位注入 |
| `rhythm` | 自动超强音 | 🎵 | ⏳ 待移植 | 需 CNN 音游轨道检测 |
| `dodge` | 自动闪避 | ⚔️ | ⏳ 待移植 | 需 YOLO 障碍联动 |

> 待移植技能点击后执行 `performSnapshotStub`：保存现场截图到
> `/tmp/aurora_agent_<id>.png` + 系统消息如实告知「依赖 MaaNTE 视觉管线，
> macOS 原生版开发中」。UI 上按钮标「待移植」，不做假动作。

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
| `--agent-selftest` | 逻辑链路自测（7 项：登录/排球/停止/领奖励/收家具/同一通道/按键引擎），PASS 数写 stdout 后 exit(0/1) |
| `--agent-ui-shot` | SwiftUI ImageRenderer 无头渲染 AI 面板 → `/tmp/aurora_ui_shot.png`（无需屏幕权限） |
| `--auto-login` | 启动即自动登录守护（run.sh 默认带） |
| `--auto-seconds N` | N 秒后自动退出（无人值守测试用，与 --auto-login 同用时引擎注入后正常） |

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
| `Sources/AuroraDrive/AIAgentPanel.swift` | 技能中心 + 面板 UI + GameWindowDetector + 自测（约 1100 行） |
| `Sources/AuroraDrive/MouseController.swift` | CGEvent 鼠标注入（.hidSystemState + .cghidEventTap） |
| `Sources/AuroraDrive/LoginAssistant.swift` | OCR 定位 + 自动登录 + 守护引擎 |
| `Sources/AuroraDrive/ControlEngine.swift` | 按键注入（含 GameKey 30+ 键） |
| `Sources/AuroraDrive/AuroraDriveApp.swift` | AppDelegate（--auto-login）/ ContentView（面板接入 + configure）/ DriveState |
| `run.sh` | 一键编译 + 部署 + 启动（默认 --auto-login） |