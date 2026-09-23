# 代码-09 MouseController 鼠标控制

> 覆盖源文件：`Sources/AuroraDrive/Control/MouseController.swift`（192 行）。基于当前仓库逐单元编写。

## 一、注入策略与坐标系说明（第 1–51 行）

**定位（4–13 行头注释）**：鼠标注入引擎（CGEvent）——移动 / 单击 / 双击 / 拖拽。用途：AI Agent 自动登录（识别登录按钮坐标后点击）、UI 自动化技能。

**与 ControlEngine 完全同源的注入策略**：

- `CGEventSource` 用 **`.hidSystemState`**（HID 系统状态层）——实测异环 NTE 的输入层只读取该层的合成事件（见 ControlEngine 注释），`.combinedSessionState` / `.privateState` 会被游戏忽略，**禁止使用**
- 投递 tap 用 **`.cghidEventTap`**（硬件事件层，最底层，游戏必响应）

**坐标系说明（15–20 行注释，"重要，曾在这里差点犯错"）**：

- CGEvent 鼠标事件的坐标是「**全局显示坐标**」，单位为**点（point）**，原点在**主显示器左上角，y 轴向下增长**——与截图像素坐标（同样左上原点）只差一个 backingScaleFactor（Retina 下 2x），**方向完全一致**
- `NSScreen.frame` 的坐标才是「**左下原点**」的 AppKit 坐标，**两者不要混用**
- 换算：**CGEvent 点坐标 = 截图像素坐标 ÷ backingScaleFactor**（主屏时）

**类声明与状态（第 27–51 行）**：`@Observable final class MouseController: @unchecked Sendable`——@Observable 供 UI 观察最近一次操作。

| 成员 | 说明 |
|---|---|
| `lastClickPoint: CGPoint`（private(set)） | 最近一次注入的坐标（诊断展示用） |
| `postedEventCount: Int`（@ObservationIgnored） | 累计成功注入的鼠标事件数（诊断用） |
| `eventSource: CGEventSource?` | 与 ControlEngine 同层：HID 系统状态 |
| `displayScale`（static） | 主显示器缩放系数（`NSScreen.screens.first ?? NSScreen.main` 的 `backingScaleFactor`，缺省 1.0）——**截图像素 ÷ 本值 = CGEvent 点坐标**（CaptureEngine 配置截屏分辨率 = screen.frame.width × backingScaleFactor 真像素，所以除以本值即换算） |
| `displaySize`（static） | 主显示器逻辑尺寸（点），缺省 `1920×1080` |

## 二、move / click / doubleClick / scrollWheel 与坐标换算（第 53–192 行）

**`move(to point: CGPoint) -> Bool`（@discardableResult，第 57–70 行）**——移动鼠标到全局点坐标（不点击）：

- `CGEvent(mouseEventSource: mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)`——参数标签是 **`mouseButton:` 不是 `button:`**
- `event.post(tap: .cghidEventTap)` → `postedEventCount &+= 1`；创建失败打印 + false

**`click(at point: CGPoint, settleDelay: TimeInterval = 0.08) -> Bool`（@discardableResult，第 79–107 行）**——左键单击（**移动 → down → up**）：

1. `move(to: point)`——**先移动过去，部分游戏 UI 只在光标悬停时才响应点击**；失败即 false
2. `usleep(settleDelay × 1_000_000)`——移动后到按下的缓冲（默认 80ms），给游戏 UI 光标跟随留时间
3. `leftMouseDown` + `leftMouseUp` 两个 CGEvent；**`usleep(40_000)` 按住 ~40ms**——源注释：0ms 的 down→up 会被部分 UI 判定为抖动
4. `lastClickPoint = point`、`postedEventCount &+= 2`、打印 click 坐标、true

**`doubleClick(at point: CGPoint) -> Bool`（@discardableResult，第 111–148 行）**——左键双击（四个事件 down/up/down2/up2）：

- **双击第二击的 `clickCount` 标记为 2（系统判定双击的依据）**：`down2.setIntegerValueField(.mouseEventClickState, value: 2)` + `up2` 同
- 节奏：down → `usleep(30_000)` → up → `usleep(60_000)` → down2 → `usleep(30_000)` → up2
- `postedEventCount &+= 4`

**`scrollWheel(lines: Int32, at point: CGPoint? = nil) -> Bool`（@discardableResult，第 156–173 行）**——滚动鼠标滚轮（游戏内场景：自动滚动拾取/翻页等）：

- `lines`：滚动行数（**正值向下，负值向上；-120 约等于一格**）
- 位置：`point ?? NSEvent.mouseLocation.flippedScreenPoint()`——默认用当前鼠标位置（AppKit 坐标翻转后）
- `CGEvent(scrollWheelEvent2Source: units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)` → `event.location = pos` → post .cghidEventTap

**`screenPoint(fromPixel:scale:) -> CGPoint`（static，第 181–183 行）**——截图像素坐标 → 全局点坐标：

```swift
static func screenPoint(fromPixel pixel: CGPoint, scale: CGFloat) -> CGPoint {
    CGPoint(x: pixel.x / scale, y: pixel.y / scale)
}
```

- `pixel`：截图中的像素坐标（**左上原点，与 Vision 归一化框换算后的方向一致**）；`scale`：截图像素/屏幕点的缩放比（Retina 主屏 = 2.0）

**`flippedScreenPoint()`（private extension NSPoint，第 187–192 行）**：`NSEvent.mouseLocation` 是**左下原点**（AppKit），转 CGEvent 的**左上原点**：`CGPoint(x: x, y: screenH - y)`（`screenH` 取 `NSScreen.screens.first?.frame.height ?? 0`）。

**给别的 AI 的调用提示**：从截图（Vision/OCR 归一化框）拿到的像素坐标 → `screenPoint(fromPixel:scale:)` 换算成点坐标 → `click(at:)`。若目标是多显示器，注意点坐标是**全局**的（跨屏连续，副屏 x 为负值），别用主屏尺寸取模。滚轮 `-120` 一格用于翻页/拾取类技能。

**MouseController 文档至此完整**（192 行全覆盖）。