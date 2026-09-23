# 代码-18 MinimapTileCache 小地图瓦片缓存

> 覆盖源文件：`Sources/AuroraDrive/Locate/MinimapTileCache.swift`（179 行）。基于当前仓库逐单元编写。

## 一、常量、状态与对外接口（第 1–90 行）

**定位（4–17 行头注释）**：左上角小地图瓦片缓存——坐标语义移植自参考项目 MaaNTE `agent/custom/action/Navi/coordinate_position.py`。

- **2026-09-13 起底图升级为 MaaNTE-Map map-2026-08 扩图版（13056×13056，bigworldmap-13056.jpg）**，抓包解码后经标定变换输出的 point.x/y ∈ [0, 13056) 像素
- 本类把 13056×13056 底图**预切成 8×8=64 块**（每块 1632×1632），并各自缩到 minimapPx×minimapPx 缓存
- **小地图只显示角色当前所在瓦片**（局部放大视图，与参考 MapLocator.MINI_MAP_ROI 的"局部小地图"语义一致），**瓦片切换 = 数组索引 O(1)**
- **切图在后台 utility 队列一次性完成；主线程（30Hz tick / SwiftUI body）只读缓存，绝不重复解码大图**——13056 大图解码数百毫秒级，放热路径必卡顿

**类声明（第 22 行）**：`final class MinimapTileCache: ObservableObject`（SwiftUI ObservableObject）。

**常量（第 26–34 行，来源：参考项目坐标系 + 用户需求）：**

| 常量 | 值 | 说明 |
|---|---|---|
| `mapPixelSize` | **13056** | 参考项目 COORDINATE_MAP_SIZE：游戏世界→地图像素的变换目标尺寸；2026-09-13 升级（11264 → 13056） |
| `tilesPerSide` | 8 | **用户需求**：把地图切成 8×8 = 64 块 |
| `tilePixelSize` | `mapPixelSize / tilesPerSide`（=1632） | 单瓦片像素尺寸 |
| `minimapPx` | `200`（CGFloat） | 小地图显示边长（pt） |

**状态（主线程读写，第 36–51 行，全部 @Published）：**

| 成员 | 说明 |
|---|---|
| `tiles: [CGImage?]` | 64 块预缩瓦片，**索引 `[row * tilesPerSide + col]`**，已缩到 200×200；初始全 nil |
| `overview: CGImage?` | 全图缩略图（**无网络定位时兜底，让小地图始终是可用地图，而非空白**） |
| `isReady` | 切图完成标志 |
| `loadError: String?` | 加载失败原因（nil = 未失败）——**UI 占位时展示，避免静默失败** |
| `loadMs: Double` | 全图加载耗时（ms），用于自检与性能观测 |

**私有（第 53–57 行）**：`ioQueue`（`DispatchQueue("aurora.minimap.tileio", qos: .utility)`）、`didLoad`（防重入：ensureLoaded 只生效一次）。

**对外接口（第 59–90 行）：**

| 方法 | 签名 | 说明 |
|---|---|---|
| `ensureLoaded()` | `()` | 触发后台切图。**幂等**（didLoad 防重入），重复调用无副作用。**应在小地图 onAppear 时调用** |
| `tileAt(mapPixelX:mapPixelY:) -> CGImage?` | 像素坐标 | **O(1) 纯数组索引**：`tileIndex` 换算 col/row → `tiles[row * 8 + col]`；越界/未就绪返回 nil |
| `inTileOffset(mapPixel:) -> CGFloat`（static） | — | **角色在当前瓦片内的相对偏移（0~200），用于画光标**：`r = mapPixel % tilePixelSize` → `r / tilePixelSize × minimapPx` |
| `tileIndex(mapPixel:) -> Int`（static） | — | **像素坐标→瓦片索引（夹紧到 [0, 7]）**：`min(max(mapPixel, 0), mapPixelSize-1)` → `Int(clamped) / 1632` → 再夹紧 |

**调用链**：CoordinateCapture/NetworkLocator 输出地图像素（0~13056）→ `tileAt` 取当前瓦片图 + `inTileOffset` 画光标 → SwiftUI 小地图显示。**瓦片切换零成本**（数组索引），位置连续时永远同一瓦片。

## 二、buildTiles 与辅助函数（第 92–179 行）

**`buildTiles()`（private，第 94–135 行）**——后台切图（非主线程，ioQueue 调用）：

1. `let t0 = Date()`——计时起点
2. `resolveMapURL()` 为 nil → 主线程 `loadError = "未找到 bigworldmap-13056.jpg（13056×13056 底图）"` 并 return（**失败显式可见，不静默**）
3. `loadFullCGImage(url:)` 失败 → `loadError = "底图解码失败：…"` 并 return
4. **全图缩略（109–110 行）**：`downscale(full, to: 200)`——无定位兜底
5. **64 块切图（112–125 行）**：双层循环（row × col）→ `CGRect(x: col × 1632, y: row × 1632, w/h: 1632)` → `full.cropping(to: rect)` → `downscale(crop, to: 200)` → 存 `arr[row * 8 + col]`——**CGImage cropping 的矩形坐标系原点在左上、y 向下，与参考项目 pixelY 语义一致**（114 行注释：不需要翻转）
6. 主线程一次性发布（127–134 行）：overview/tiles/isReady/loadMs 全部 @Published 更新（**单次 objectWillChange**，不逐块刷 UI）

**`resolveMapURL() -> URL?`（private，第 141–154 行）**——解析底图路径，**七候选多级回退**：

```
/Users/dupi/Desktop/自动驾驶系统/models/bigworldmap-13056.jpg   （开发机源码目录，首选）
/Users/Shared/AuroraDrive/bigworldmap-13056.jpg                 （共享安装位）
/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png   （旧图备选）
/Users/Shared/AuroraDrive/bigworldmapSecond.png
Bundle.main bigworldmap-13056.jpg / bigworldmapSecond.png / map.png  （Bundle 资源）
```

- 覆盖交付场景（140 行注释）：**根目录裸可执行文件运行时 cwd 不确定，故多级回退**
- `compactMap { URL } .first { fileExists }`——第一个存在的入选
- **注意候选 1/3 是硬编码用户路径**（与 AuroraPaths 的候选 4 同风格）——换机器靠候选 2/4/5-7 兜底

**`loadFullCGImage(url:) -> CGImage?`（private，第 157–161 行）**：`NSImage(contentsOfFile:)` → `cgImage(forProposedRect:context:hints:)`——后台线程调用。

**`downscale(_ src: CGImage, to px: Int) -> CGImage?`（private，第 164–178 行）**：

- CGContext（`data: nil`、`bytesPerRow: 0` 自动、**premultipliedLast** RGBA）→ **`interpolationQuality = .high` 高质量插值** → `ctx.draw(src, in: 0,0,px,px)` → `ctx.makeImage()`
- **预缩一次供热路径复用**（163 行注释）——主线程 tick 只读缓存，绝不在热路径重复缩放

**MinimapTileCache 文档至此完整**（179 行全覆盖）。给别的 AI 的提示：**底图升级（13056）后 NetworkLocator 的旧标定值（TX/TY）若未同步，tileAt 拿到的瓦片会错位**——见 代码-16 单元一的坐标系不同步警告；本类自身只做"像素 → 瓦片"的纯索引，坐标变换不在本类。