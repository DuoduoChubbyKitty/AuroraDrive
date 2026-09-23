# 代码-22 LoginAssistant 登录助手

> 覆盖源文件：`Sources/AuroraDrive/Agent/LoginAssistant.swift`（166 行）。基于当前仓库逐单元编写。

## 一、结果类型、关键词表与 OCR 识别（第 1–96 行）

**定位（4–20 行头注释）**：游戏自动登录引擎——解决"异环 NTE 每次启动都停在登录界面，此前每次都要用户手动点登录"。

**工作原理（全真实感知闭环，无盲点击）**：① 从 CaptureEngine 拿当前屏幕帧（整屏截图，引擎已在跑 30fps 流）→ ② Vision 框架 VNRecognizeTextRequest 做中英文 OCR，拿到所有文字块 → ③ 按优先级匹配登录按钮关键词 → ④ 命中 → 文字框归一化坐标 → 截图像素坐标 → 屏幕点坐标 → 鼠标单击 → ⑤ 2 秒后重新截图验证：按钮文字消失 = 登录成功；仍在 = 换下一关键词再试（**有界 3 轮，每轮换关键词，不是无脑死循环**）。

**坐标换算链（三段，16–19 行注释）：**

```
Vision bbox（归一化，左下原点）
  → 截图像素（左上原点）：px = midX·W，py = (1 - midY)·H
  → 屏幕点（CGEvent 左上原点）：point = pixel / backingScaleFactor
```

**类声明（第 27 行）**：`final class LoginAssistant: @unchecked Sendable`。

**`Result`（enum: Equatable，第 30–35 行）**——登录结果四种：

| case | 含义 |
|---|---|
| `success(String)` | 已进入游戏（附命中的按钮文字） |
| `noMatchingText` | 屏幕上没有任何登录关键词（**可能已在游戏内**） |
| `clickedButStillStuck` | 点击了但按钮还在（罕见：需要人工介入） |
| `noFrame` | 拿不到截屏帧（截屏流未启动/无权限） |

**`buttonKeywords`（static let，第 40–43 行）**——登录按钮关键词，**按优先级排列（前面的先点）**：

```swift
["点击进入", "进入游戏", "点击屏幕继续", "登录游戏",
 "登录", "登入", "开始游戏", "开始", "确认", "连接"]
```

「点击进入/进入游戏」是 NTE 登录主按钮；「登录」是账号输入完成后的确认；「开始游戏」兜底；「确认/连接」覆盖弹窗场景。

**`recognizeText(in image: CGImage)`（private，第 46–62 行）**——Vision OCR：

- `VNRecognizeTextRequest` + `recognitionLevel = .accurate` + **`usesLanguageCorrection = false`（游戏按钮是 UI 文字，不要语言纠错）** + `recognitionLanguages = ["zh-Hans", "en-US"]`
- `VNImageRequestHandler(cgImage:options:[:])` + `try handler.perform([request])`
- `observations.compactMap { topCandidates(1).first → (candidate.string, box.midX/midY 中心, box) }`
- **OCR 引擎每次调用新建请求；VNRequest 非线程安全，不复用实例**（45 行注释）

**`locateButton(in:scale:)`（第 66–68 行）**：默认关键词版（调通用版，传 `Self.buttonKeywords`）。

**`locateButton(_:in:scale:) -> (text: String, point: CGPoint)?`（通用版，第 72–96 行）**——**按给定关键词优先级扫描，返回第一个命中（供自动领奖励/收家具等所有 OCR 点击技能复用）**：

- `guard let texts = try? recognizeText(in: image)`——OCR 失败返回 nil
- **按关键词优先级双层循环（82–94 行）**：先看最高优先级的关键词有没有命中，**命中就直接用（避免「开始」按钮盖过「点击进入」时点错）**
- **完整包含即命中**（85 行注释："OCR 偶尔把「点击进入游戏」读全，用包含匹配容错"）：`t.text.contains(keyword)`
- **坐标换算（87–89 行）**：Vision 归一化（左下原点）→ 截图像素（左上原点）：`pixel = (t.center.x × width, (1.0 - t.center.y) × height)` → `MouseController.screenPoint(fromPixel: pixel, scale: scale)`（见 代码-09）
- 打印命中日志 → `(t.text, point)`；无命中 nil

## 二、runAutoLogin 完整流程与自测（第 98–166 行）

**`cgImage(from image: NSImage) -> CGImage?`（第 103–106 行）**——NSImage → CGImage：

- **正确 API：`cgImage(forProposedRect:context:hints:)`**——ScreenCaptureKit 生成的 NSImage 尺寸即像素尺寸，传入 .zero 矩形即可
- **internal：AI Agent 面板的通用 UI 点击技能也复用此转换**（102 行注释）——全项目统一的 NSImage→CGImage 转换入口

**`runAutoLogin(capture:mouse:logger:verifyDelay:maxRounds:) -> Result`（第 115–155 行）**——执行一次完整自动登录：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `capture: CaptureEngine?` | — | 截屏引擎（取当前帧） |
| `mouse: MouseController` | — | 鼠标注入引擎 |
| `logger: @escaping (String) -> Void` | — | 日志回调（写 /tmp/aurora_debug.log + 会话消息） |
| `verifyDelay` | 2.0 秒 | 点击后等待验证的秒数 |
| `maxRounds` | 3 | **有界轮数（每轮按优先级换下一个关键词）** |

**流程（122–155 行）：**

1. `let scale = MouseController.displayScale`（全流程共用）
2. `for round in 1...maxRounds`：
   - `guard let frame = capture?.currentFrame, let cg = cgImage(from: frame)`——拿不到帧 → `.noFrame`（"截屏流未启动？"）
   - **本轮关键词策略（128–129 行注释）**：本轮只认「优先级第 round 个及以后」的关键词——**第 1 轮点主按钮，点了还在才轮到后面的兜底词，避免同一按钮反复狂点**（注释里写了策略但当前代码 locateButton(in:scale:) 用的是完整 buttonKeywords 表——即每轮都从头扫；"第 round 个及以后"的切片策略在注释中声明、实现未做切片。**给别的 AI：若要实现注释所述策略，把 locateButton 调用改为传 `Array(buttonKeywords.dropFirst(round - 1))`**）
   - 命中 → `mouse.click(at: hit.point)` → `usleep(verifyDelay × 1_000_000)` → **验证（136–145 行）**：重新截图 → `locateButton` 仍在且 `still.text == hit.text` → "点击后按钮仍在，下一轮换关键词" + continue；否则 "✅ 按钮已消失，判定登录成功" → `.success(hit.text)`；验证帧拿不到也 `.success`（乐观判定）
   - **无命中（146–151 行）**：屏幕上没有登录关键词——**要么已进游戏（3D 场景 OCR 无文字），要么是别的界面。不盲点，直接如实回报** → `.noMatchingText`
3. 轮数用尽 → "❌ N 轮后仍在登录界面，需要人工介入" → `.clickedButStillStuck`

**`dryRunLocate(capture: CaptureEngine?) -> (text: String, point: CGPoint)?`（第 160–165 行）**——干跑：**只定位不点击**（用于自测 `--agent-selftest`，验证 OCR→坐标链路）：取当前帧 → locateButton。

**LoginAssistant 文档至此完整**（166 行全覆盖）。给别的 AI 的提示：**这个类是所有"OCR 找按钮 → 点"技能的公共底座**（locateButton 通用版 + cgImage 转换），自动领奖励/收家具/传送等技能都复用它；`Result.noMatchingText` 是"可能已进游戏"的正常态，不是失败。