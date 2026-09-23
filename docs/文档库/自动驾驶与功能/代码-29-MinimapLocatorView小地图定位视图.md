# 代码-29 MinimapLocatorView 小地图定位视图

> 覆盖源文件：`Sources/AuroraDrive/App/MinimapLocatorView.swift`（196 行）。基于当前仓库逐单元编写。

## 一、瓦片定位视图与点击交互（第 1–118 行）

**引用关系（grep 实测）**：`MinimapLocatorView` 唯一调用方 = GameViewportView:2988（`.allowsHitTesting(true)`——**移植版，显示网络定位位置，放在左上角**）；`locator 五件套` 唯一写入方 = DriveState.runNetworkLocateStep:1027–1031（主线程异步更新）；`locateCtx` 仅 `networkReady` 一个字段被写（DriveState:995/1003）；**`locateGate` 零调用**（tryBegin/end/isBusy 无人调——并发门控预留）。

**文件头常量（第 11–16 行）——2026-09-13 升级**：MaaNTE-Map map-2026-08 扩图版底图（**11264 → 13056**）：

| 常量 | 值 | 说明 |
|---|---|---|
| `mapSide`（static） | **13056** | 底图边长（像素） |
| `blocksPerEdge`（static） | 8 | 每边块数 |
| `blockSide`（static） | 13056 / 8 = 1632 | 单块像素 |
| `viewSize`（private let） | 220 | 视图显示边长（pt） |

**状态（第 18–20 行）**：`blockImage: CGImage?`（当前块图）/ `loadedBlock: Int = -1`（已加载块索引）/ `blockQueue`（"aurora.minimap.block", .userInitiated——后台裁块队列）。

**三个计算属性（第 22–35 行）——角色在当前块内的位置换算：**

| 属性 | 公式 | 说明 |
|---|---|---|
| `currentBlock` | `by × 8 + bx`（bx/by = min(7, max(0, Int(locatorX/Y / 1632)))） | 当前所在块索引（行优先） |
| `relX` | `(locatorX - 块originX) / 1632`，钳制 [0,1] | **块内相对 x（0~1）** |
| `relY` | 同构 | **块内相对 y（0~1）** |

**body（第 37–111 行）——ZStack 四层：**

1. **底图（40–47 行）**：`blockImage` 存在 → `Image(decorative: img, scale: 1).resizable().interpolation(.medium)`（**220×220 方形**）；否则黑底——**decorative：无障碍跳过，不参与 VoiceOver**
2. **角色标记（49–67 行）**：`state.locatorFound` 时——**Canvas 画朝向三角**：`center = (relX × w, relY × h)` → **CGAffineTransform 旋转（locatorHeading × π/180）** → Path 三角（0,-11 / -7,8 / 7,8 闭合，**尖头朝向 = 朝向角**）→ cyan 填充 + 白 0.8 描边 1pt；**+ 白色中心点**（5pt，position relX/relY）
3. **传送目标（69–83 行）**：`state.locatorTarget` 非空时——**`tx = ((t.x - originX) / 1632) × 220`（目标换算到当前块内；目标不在当前块时 tx/ty 越界 → 不画**）→ **橙色连线（当前点 → 目标，orangeRed 0.7，1.5pt）** + 橙色目标点（8pt）
4. **外框（85–88 行）**：clipShape 圆角 8 + 白 0.25 描边 1pt

**点击交互（第 89–93 行）——点击设置传送目标**：

```swift
.onTapGesture { p in
    let mx = Double(p.x / viewSize) * Self.blockSide + originX
    let my = Double(p.y / viewSize) * Self.blockSide + originY
    state.setLocatorTarget(x: mx, y: my)
}
```

- **视口坐标 → 地图像素**：`p.x / 220 × 1632 + originX`（当前块内偏移 → 全图像素）→ `setLocatorTarget`（DriveState:977）——**点击小地图任意位置 = 设为传送目标（大地图 overlay 画线/目标点联动）**

**底部状态文字（第 95–105 行）**：locatorFound → **"块 N · 地图px(x,y) rel(x.xxx,y.yyy) ↗N°"**（8pt semibold monospaced cyan——**完整调试信息：块索引 + 全图像素 + 块内相对 + 朝向**）；否则 "小地图定位…"（9pt tertiary）。

**外框（107–108 行）**：padding 6 + 黑 0.45 底（圆角 10）。

**生命周期（109–110 行）**：`.onAppear { ensureBlockLoaded() }` + **`.onChange(of: currentBlock) { ensureBlockLoaded() }`——跨块移动时自动换块图**。

**`originX/originY`（private，第 113–118 行）**：当前块的左上角全图像素（`块索引 × 1632`）——换算基线。

## 二、ensureBlockLoaded 与 MinimapBlockCache / LocateGate / LocateContext（第 120–196 行）

**`ensureBlockLoaded()`（private，第 120–144 行）——按当前块懒加载裁块（跨块自动换图）**：

1. `wantBlock = currentBlock`；**`if loadedBlock == wantBlock, blockImage != nil { return }`——已加载当前块不重复裁**
2. `desiredX/Y = 块索引 × 1632`（目标块的左上角）
3. **blockQueue 后台裁块（126–136 行）**：
   - **`MinimapBlockCache.shared.display() == nil` 时 `setDisplay(Self.loadDisplayMap())`**——**显示图懒加载（首次调用才解码大图）**
   - `guard let src` → `scale = src.width / 13056`（**显示图（2816）相对底图（13056）的缩放比 ≈ 0.2158**）
   - `crop = CGRect(x: desiredX × scale, y: desiredY × scale, width/height: 1632 × scale)`——**从 2816 显示图裁出当前块（≈352×352）**
   - `guard let block = src.cropping(to: crop)`
4. **主线程回写（137–143 行）**：**`if self.currentBlock == wantBlock`——回写前复查（后台裁块期间角色可能已跨块，旧块图直接丢弃，只回写当前块）** → blockImage = block + loadedBlock = wantBlock

**`loadDisplayMap()`（private static，第 146–164 行）——显示图加载（四候选路径）：**

```swift
let candidates = [
    "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmap-13056.jpg",
    "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png",
    "\(FileManager.default.currentDirectoryPath)/models/bigworldmap-13056.jpg",
    "\(FileManager.default.currentDirectoryPath)/models/bigworldmapSecond.png",
]
for p in candidates { if FileManager.default.fileExists(atPath: p) { return p } }
return candidates[0]   // 全败返回第一个候选（错误信息里能看到路径）
```

- `CGImageSourceCreateWithURL` + **`kCGImageSourceThumbnailMaxPixelSize: displayMapSide (2816)`**——**缩略加载：13056 大图不完整解码，直接按 2816 上限出缩略图（省内存：完整解码 ≈680MB，2816 ≈32MB）** + CreateThumbnailFromImageAlways + WithTransform
- **`displayMapSide`（static let，第 166 行）= 2816**——显示图边长（**13056 / 4.638…；实际 = 8 块 × 352 ≈ 2816——每块显示后 ≈352px，配合 220pt 视图约 1.6x 采样**）

**`MinimapBlockCache`（private final class，@unchecked Sendable，第 169–175 行）**：

| 成员 | 说明 |
|---|---|
| `static let shared` | 单例 |
| `lock = NSLock()` | 锁（**@unchecked Sendable：跨线程安全由锁保证**） |
| `_display: CGImage?` | 缓存的显示图 |
| `display()/setDisplay(_:)` | 锁内读/写——**display 方法名避免与 SwiftUI 的 display 冲突** |

**与 MinimapTileCache（代码-18，Locate/）的对比**（两套独立缓存，消费者不同）：

| | MinimapTileCache（代码-18） | MinimapBlockCache（本文件） |
|---|---|---|
| 消费者 | FloatingMinimap（常驻左上角小地图） | MinimapLocatorView（GameViewportView 内叠加） |
| 缓存结构 | **64 块预缩 200×200 + overview 全图缩略** | **单张 2816 显示图（懒加载）+ 按块裁剪** |
| 常量 | mapPixelSize 13056/tilesPerSide 8/tilePixelSize 1632/minimapPx 200 | mapSide 13056/blocksPerEdge 8/blockSide 1632/displayMapSide 2816 |
| 队列 | ioQueue（**utility**——低优先级） | blockQueue（**userInitiated**） |
| 线程安全 | @Published（主线程读写） | NSLock（@unchecked Sendable） |
| 加载策略 | ensureLoaded 幂等一次性（onAppear） | ensureBlockLoaded 按 currentBlock 变化重裁（onChange） |

**`LocateGate`（final class，@unchecked Sendable，第 177–188 行）——定位并发门控（⚠️ 预留代码，零调用）**：

- `tryBegin() -> Bool`：锁内 busy 判定——**已 busy 返回 false（防并发定位重复进入）；否则置 true 返回 true**
- `end()`：busy = false；`isBusy`（计算属性）：锁内读
- **grep 实测零调用**——DriveState.runNetworkLocateStep 未用它（网络定位步目前靠 `coordinateCapture == nil` 懒初始化兜底，无并发门控）；**预留价值：若未来加视觉定位（visualLocator）与网络定位双源切换，用这个门保证同一时刻只有一个定位源在跑**

**`LocateContext`（final class，@unchecked Sendable，第 190–196 行）——定位上下文（⚠️ 大部分字段预留）**：

| 字段 | 说明 | 状态 |
|---|---|---|
| `visualLocator: VisualLocator?` | 视觉定位器（代码-17） | **预留——无人写** |
| `networkLocator: NetworkLocator?` | 网络定位器（代码-16） | **预留——无人写（实际用的是 DriveState.coordinateCapture）** |
| `visualReady` | 视觉定位就绪 | **预留——无人写** |
| `networkReady` | 网络定位就绪 | **唯一被写字段**（DriveState:995 懒初始化时置 true / 1003 guard 判定） |
| `activeMode = "fallback"` | 当前定位模式 | **预留——无人写** |

**诚实标注**：LocateContext 的 5 字段里只有 networkReady 参与运行；visualLocator/networkLocator/visualReady/activeMode 是**双源定位架构的预留槽**——网络坐标抓取器实际挂在 DriveState.coordinateCapture，不经过此上下文。

**MinimapLocatorView 文档至此完整**（196 行全覆盖：常量与状态 → 位置换算 → body 四层 → 点击交互 → ensureBlockLoaded → MinimapBlockCache → LocateGate/LocateContext）。