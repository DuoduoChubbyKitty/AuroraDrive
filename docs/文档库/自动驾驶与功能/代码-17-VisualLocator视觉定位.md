# 代码-17 VisualLocator 视觉定位

> ✅ **2026-10-18 复核**（merge-arch）：源码自 mtime 2026-08-26 后未变。三个常量逐字对上：`workSizes=[2048,1536,1024]`、`globalScanSize=192`、`scoreThreshold=0.80`（`locate()` 的默认参数）。
>
> **本次仅强化一处现状描述（§现状 ②）**：原文说「`LocateContext.visualLocator` 当前无产品级装配/调用路径」——实测可精确到：**该字段全仓只有声明处一行，从未被赋值**（全仓 grep `visualLocator` 仅命中 `LocateRuntime.swift` 的声明）；而 `LocateContext` 本身**仍在用**（`AuroraDriveApp` 持有 `locateCtx`），但它只消费 `networkReady`。故结论不变但更硬：**视觉定位这条路是「类型在、字段在、装配不在」**。（2026-11 补充：`LocateRuntime.swift` 注释已明确 `visualLocator`/`networkLocator` 恒 nil、`visualReady`/`activeMode` 零读写，只有 `networkReady` 被真实驱动。）
>
> **死代码确认（lead 指定核对项）**：`VisualLocator()` 全仓**零实例化**（`grep -rn "VisualLocator(" Sources/` 无输出）；`.locate(template:` 零产品调用；`runSelfTest` / `cleanup` / `minimapBytes` 均零外部调用。**主定位走 `CoordinateCapture`**（网络抓包解 UE5 位流）。

> ✅ **2026-10-18 独立复核**（infer-reader，与上方 merge-arch 复核并立，结论一致）：
>
> 对 lead 点名的 4 项**逐条独立实测**，全部命中：
>
> | # | 核对项 | 实测命令 | 结果 |
> |---|---|---|---|
> | 1 | `VisualLocator()` 零实例化 | `grep -rn "VisualLocator(" Sources/ --include=*.swift` | **零命中** ✅ 死代码 |
> | 2 | `workSizes=[2048,1536,1024]` | grep `workSizes` | `workSizes: [CGFloat] = [2048, 1536, 1024],` ✅ |
> | 3 | `globalScanSize=192` | grep `globalScanSize` | `private static let globalScanSize: CGFloat = 192` ✅（`private static let`，非 computed） |
> | 4 | `scoreThreshold=0.80` | grep `scoreThreshold` | `scoreThreshold: Double = 0.80) -> LocateResult {` ✅（是 `locate()` 的**默认参数**，非类属性——文档措辞「常量」略宽，实质无误） |
>
> **补充实测（文档未记，本轮新增）**：
> - `.locate(` 全仓**零调用**（`grep -rn "\.locate(" Sources/ --include=*.swift` 无输出）——比文档「`.locate(template:` 零产品调用」更严：连**非产品调用也不存在**。
> - `visualLocator` 字段全仓**仅 1 处**：`LocateRuntime.swift` 声明 `var visualLocator: VisualLocator? = nil`，**零赋值、零读取**。
> - **平行佐证**：`NetworkLocator()` 同样**零实例化**（`grep -rn "NetworkLocator(" Sources/` 无输出）——两条定位链**同时废弃**，与 lead 的判断一致。
>
> **废弃定级建议**（⚠️ 待确认，需 lead 决策）：本文件（含 `runSelfTest` 自检）是**完整可用但零装配**的能力。两种处置：① 保留为「降级备用」并在类头注明「当前无装配」；② 若确认不再需要视觉定位，整文件移入 `docs/老旧文档/` 对应的归档区。**不建议直接删除**——它是唯一不依赖网络抓包的定位实现，未来 pcap 失效时是备选。

---

> 覆盖源文件：`Sources/AuroraDrive/Locate/VisualLocator.swift`。基于当前仓库逐单元编写；本档所有代码位置按**真实符号名**引用，不再使用会漂移的行号。
>
> **✅ 2026-10-17 行号复核（历史记录）**：源文件内容自 2026-08-26（mtime）后未再修改（最后一次 git 提交 `25e3c18`，2026-09-20，源码树整理仅移动文件）；本文所有位置引用已改为按符号名核对（§三「搜索窗口」见 `matchOneScale` 内 `sw/sh` 字段赋值与 `hintPixel` 窗口计算）。
>
> **🔄 2026-10-06 现状说明**：
> ① 符号复核：本文引用的 `workSizes`、`smoothAlpha=0.7`、`globalScanSize=192`、`matchOneScale` 内 hint ±120px 窗口、`locate()` 内 EMA 平滑、`nccAt`、`buildIntegral`、`runSelfTest` 均逐条核实无误；
> ② **当前产品代码未接入**：全仓 grep 无任何 `VisualLocator(` 构造调用与 `.locate(template` 调用（2026-10-06 实测）。旧文档所称的接入方 `DualModeLocator` 已从 NetworkLocator.swift 中删除（见 代码-16）；现存持有它的类型是 `LocateContext.visualLocator`，但其当前无产品级装配/调用路径——**本类当前是备用/降级能力，主定位走 CoordinateCapture**（未验证是否存在测试夹具外的隐藏调用）；
> ③ 文中 `minimapBytes`「与 MinimapTileCache 配合」的说法已过时：`Sources/AuroraDrive/Locate/MinimapTileCache.swift` 已删除（见 代码-18 废弃说明），该函数仍在本文件内（**已废弃用途**）。

## 一、数据类型与 prepare() 多尺度建档

**定位**：视觉定位器——把"小地图模板"（150px 侧长的模板块）在**大地图底图**上做多尺度 NCC（归一化互相关）匹配，输出模板在底图上的坐标。设计意图是与 NetworkLocator（网络包坐标）互补：网络断了用视觉找位置。

> ⛔ **2026-10-18 复核：本类当前是死代码（零装配）。** `VisualLocator()` 全仓零实例化、`.locate(` 零调用、`visualLocator` 字段（`LocateRuntime.swift` 声明）零赋值零读取；平行的 `NetworkLocator()` 亦零实例化。**生产主定位走 `CoordinateCapture`**（网络抓包解 UE5 位流）。以下全部内容为「能力说明」而非「现役行为」，阅读时请以此为背景。

**数据类型：**

| 类型 | 字段 | 说明 |
|---|---|---|
| `LocatorScale` | `scale / width / height / gray: [Float] / luminanceMean: Float / integral: [Float] / integralSq: [Float]` | 一个匹配档：缩放比 + 灰度图 + 灰度均值 + **积分图（和/平方和，供 boxSum O(1) 区块求和）** |
| `LocateResult` | `found / x / y / score / scaleIndex` | 定位结果（默认 found=false、score=0） |

**类声明：**

| 成员 | 默认值 | 说明 |
|---|---|---|
| `mapPath`（let） | — | 大地图底图路径 |
| `workSizes: [CGFloat]` | `[2048, 1536, 1024]` | 匹配档的目标像素尺寸（三档金字塔） |
| `scales: [LocatorScale]` | [] | 建好的匹配档（**isReady = !scales.isEmpty**） |
| `wasLastCentered: Bool` | false | 上次是否成功定位（hint 连续性判定） |
| `lastSmoothX/Y: Double` | 0 | 上次平滑后的位置 |
| `smoothAlpha` | 0.7 | 位置平滑系数 |
| `originWidth/Height`（private(set)） | 0 | 底图原始尺寸 |

**`prepare() -> String?`**——多尺度建档（返回错误串，nil = 成功）：

1. `CGImageSourceCreateWithURL` + `CGImageSourceCreateImageAtIndex` 打开底图首帧——失败各自返回错误
2. 记 originWidth/Height（非法尺寸返回错误）
3. **逐档缩略图**：`kCGImageSourceThumbnailMaxPixelSize: target` + CreateThumbnailFromImageAlways + WithTransform → `Self.tryAppendScale(thumb:originWidth:to:)`
4. **P修复：全局粗扫档**——源注释："**NCC峰宽~2px、stride=16跨峰顶漏检**；追加全局粗扫档，仅当最粗档仍远大于192时追加（防小图重复建档）"：`coarsest.width > Int(Self.globalScanSize * 1.4)` 时再建一档 192px
5. `guard !built.isEmpty`——失败返回"未能生成任何匹配档"；成功 `scales = built` 返回 nil

**`tryAppendScale(thumb:originWidth:to:)`（private static）**：宽高 > 8 防御 → `grayFloatPixels(thumb)` 灰度 Float（0~1）→ 均值 → `buildIntegral`（积分图）→ `LocatorScale(scale: Double(w)/Double(originWidth), ...)` 追加。

**工具常量**：`globalScanSize: CGFloat = 192`（全局粗扫档尺寸）、`inv255f: Float = 1.0/255.0`（nonisolated static）、`floatToUInt8(_:)`（clamp + 缩放回 0~255）。

## 二、locate() 主入口与两阶段匹配

**`locate(template: [UInt8], tw: Int, th: Int, scoreThreshold: Double = 0.80) -> LocateResult`**——主入口。**两阶段：无 hint 时先粗扫定位，再全档细匹配**：

**预处理与防御：**

- `--locate-live` 诊断：defer 里打印 locate 总耗时（stderr，仅命令行参数存在时）
- `templateFloat(template, tw:th:)` 失败 / scales 空 / tw 或 th < 8 → 返回空结果
- **模板方差校验**：`sumSqErr` → `tVar = sqrt(sumSq)`，`tVar > 1e-6` 否则空结果；**`perStd = sqrt(sumSq/(tw*th))`，`perStd >= 0.02` 否则空结果**——纯色模板（无纹理）直接拒绝
- `best.score = -1`（初始，与 NCC [-1,1] 一致）

**阶段 1：hint 生成：**

- `wasLastCentered` 时 hint = 上次平滑位置（连续定位直接用）
- **无 hint 时最粗档全局粗扫（P修复）**——源注释："**无hint时最细档全图粗扫~1.1亿次NCC内循环会卡死；模板150px是finest档，更粗档需按scale缩小否则NCC永远低分**"：
  1. `finest = scales.max(by: scale)`（最细档）→ `coarse = scales.min(by: scale)`（最粗档）
  2. **模板按 scale 缩小**：`coarseSide = max(8, Int((tw × coarse.scale / finest.scale).rounded()))` → `resizeTemplate` → `centeredTemplate` → coarseVar
  3. `matchOneScale(..., hintPixel: nil, strideOverride: 2)`——**全局扫必须 stride=2**（NCC 峰宽 ~2px，stride=16 跨峰顶漏检）
  4. 命中 → hint = 粗扫中心换算回原图坐标（`(x + side/2) / coarse.scale`）、best = 粗扫结果；**未命中 → wasLastCentered = false 直接返回**（不进入细匹配）

**阶段 2：全档细匹配：**

- 逐档 `scaledSide = max(8, Int((tw × scale.scale / finest.scale).rounded()))` → resizeTemplate → centeredTemplate → matchOneScale（**hintPixel = hint 换算到该档坐标**，走 ±120px 局部窗口）
- `result.found && result.score > best.score` 才更新 best

**阈值与输出：**

- `best.score < scoreThreshold` → best.found = false + wasLastCentered = false + 返回（threshold reject 诊断）
- 命中：**像素换算**：`px = (best.x + bestSide/2) / bestScale.scale`——匹配框左上角 + 半边长 = 中心，再除以该档缩放比回到原图坐标
- **位置平滑**：wasLastCentered 时 `lastSmoothX = lastSmoothX × (1-0.7) + px × 0.7`（EMA），否则直接采用
- 返回 `(found: true, x/y: 平滑后, score, scaleIndex)`

**`reset()`**：wasLastCentered = false、lastSmoothX/Y = 0——清连续性状态（新会话重新粗扫）。

## 三、matchOneScale 单档匹配与 nccAt NCC 核心

**`matchOneScale(scale:template:tMean:tVar:tw:th:hintPixel:strideOverride: Int? = nil) -> LocateResult`（private static）**——单档匹配：

1. **搜索窗口（`matchOneScale` 开头的 `sw/sh` 档尺寸计算与 guard）**：`sw/sh` 档尺寸、`tcount = tw*th`；`guard tcount > 0, sw >= tw, sh >= th`（档比模板小则返回空）；**hintPixel 非空时 ±120px 局部窗口**（`r: Double = 120`，x0/y0/x1/y1 clamp 到边界）；`guard x1 >= x0, y1 >= y0`
2. **粗扫 stride（P修复）**：`coarseStride = strideOverride ?? ((hintPixel != nil) ? 2 : 16)`——**NCC峰宽~2px、stride=16跨峰漏检；全局扫必须 stride=2（strideOverride 传入）**
3. **top-K 候选维护**：`topK = 8`；`offer(_ s:_ X:_ Y:)` 闭包——不足 K 个直接 append（满 K 后排序）；超过时与末位比较、替换 + 插入排序（candidates 按分降序保持）
4. **粗扫循环**：双 while（yy/xx 步进 coarseStride）逐点 `Self.nccAt(...)` → offer
5. **精修循环**：对每个候选 ±(coarseStride-1) 邻域**逐像素** nccAt → `ncc > best.score` 更新 best——粗扫漏峰由精修补回
6. **返回**：`found: best.found && best.score > -0.5 && best.score.isFinite`（**分数下限 -0.5 + 有限性**）

**`nccAt(scale:template:tMean:tVar:tw:th:tcount:startX:startY:rowBase:work:) -> Double`（private static）**——NCC（归一化互相关）单点计算：

- **积分图求和**：`boxSum(scale.integral, w: sw, x: startX, y: startY, tw: tw, th: th)` 求 ΣV 与 ΣV²——**O(1) 区块和**（不用逐像素）
- **窗口拷贝**：`work` 缓冲复用（`withUnsafeBufferPointer` + `update(from:count:)` 逐行拷贝模板窗口）
- **点积**：`vDSP_dotpr(wb, 1, tb, 1, &sumVT, vDSP_Length(tcount))`——vDSP 向量化（Accelerate）
- **NCC 公式**：
  ```swift
  let meanV = sumV / n
  let varV = sumV2 - n * meanV * meanV       // Σv² - n·μ²（平方和展开）
  let stdV = sqrt(max(0, varV))              // max(0,·) 防 float 误差负值
  let denom = stdV * Double(tVar)
  guard denom > 1e-8 else { return -1 }
  let cov = Double(sumVT) - n * meanV * Double(tMean)
  return max(-1, min(1, cov / denom))        // NCC ∈ [-1, 1]
  ```
- `max(0, varV)`：浮点舍入可能算出微负方差，sqrt 前 clamp；`max(-1, min(1, ...))`：夹到 [-1, 1]

**性能要点**：积分图（boxSum O(1)）+ vDSP 点积 + top-K 候选 + 粗扫/精修两遍——单档 2048px 图 ≈ 400 万像素、窗口 150px 时 NCC 内循环 1 次约 22500 次乘加，粗扫 stride=2 时约 100 万次 offer——这是"金字塔 + stride=2 粗扫"避免 1.1 亿次内循环卡死的设计。

## 四、工具函数与合成自检

**六个工具函数（private static）：**

| 函数 | 说明 |
|---|---|
| `buildIntegral(_ gray:w:h:) -> (sum: [Float], sq: [Float])` | **积分图构建**：`(w+1)×(h+1)` 布局（首行/列全 0），递推 `sum[i] = v + sum[i-1] + sum[prev+x+1] - sum[prev+x]`（和图）与 `sq[i] = v² + ...`（平方和图）——供 boxSum O(1) 区块求和 |
| `boxSum(_ integral:w:x:y:tw:th:) -> Float` | **O(1) 区块和**：四角差值 `integral[a+th*stride+tw] - integral[a+th*stride] - integral[a+tw] + integral[a]` |
| `grayFloatPixels(_ img:targetW:targetH:) -> [Float]?` | CGImage → 灰度 Float（0~1）：DeviceGray 上下文 + `ctx.draw`（**targetW 非 nil 时 `interpolationQuality = .high`** + `byTiling: targetH == nil`）→ `Float($0) * inv255f` |
| `minimapBytes(from:side:) -> [UInt8]?`（**static**） | **P4优化：直接在灰度图中写入 UInt8，跳过 Float32 中转分配（~22.5KB）**——小地图瓦片提取用（原设计与 MinimapTileCache 配合，**该类已删除，此用途已废弃**，函数本身仍在）；DeviceGray 上下文 + .high 插值 + draw → 返回 `[UInt8]` |
| `templateFloat(_ t:tw:th:) -> ([Float], Float)?` | 模板字节 → Float（0~1）+ 均值——`t.prefix(tw*th)`（**模板字节数可能大于 tw×th，只取前段**） |
| `resizeTemplate(_ t:fromW:fromH:toW:toH:) -> [Float]?` | 模板缩放（**双线性手写版**）：`sx = (fromW-1)/(toW-1)`（**端点对齐**——与 SpeedOCRReader 的中心对齐不同，这里 x0=Int(fx) 直接取左邻）→ 四邻域加权 |
| `centeredTemplate(_ t:side:) -> ([Float], Float)?` | 模板均值（**不做中心化减均值，只算均值**——NCC 公式里减） |
| `sumSqErr(_ a:mean:) -> Double` | 平方和误差 Σ(v-mean)²——模板方差用 |

**`runSelfTest(expectedX:expectedY:templateSide: Int = 150) -> String`**——合成自检：

1. `guard !scales.isEmpty` + finest 档 + 读地图原图
2. **合成模板构造**：`srcSpan = Int(templateSide / fine.scale + 0.5)`——**把 150px 模板尺寸反推回原图上的 span**（原图坐标系）；cx/cy/rx/ry clamp 到边界 → `full.cropping(to: ...)` 裁出模板区域 → `grayFloatPixels(cropped, targetW: 150, targetH: 150)` → `floatToUInt8` 转字节
3. `locate(template: tmplBytes, tw: 150, th: 150, scoreThreshold: 0.5)`——**自检阈值 0.5（比运行期 0.80 宽松）**
4. **误差判定**：`err = sqrt(dx² + dy²)`（期望中心 vs 定位中心）；**`pass = err <= 300`（px）**——300px 是原图坐标系的容差
5. 返回 `SELFTEST PASS/FAIL err=...px expected=...,... got=...,... score=... 档#N`

**用途**：验证"从已知位置裁模板 → 能定位回同一位置"的闭环（**零外部依赖的纯视觉自检**，不联网、不用模型）。

**`cleanup()`**：`scales.removeAll()`——释放全部匹配档（灰度 Float + 积分图内存，2048px 档约 33MB）。

**VisualLocator 文档至此完整**（数据类型 → `prepare()` 建档 → `locate()` 两阶段 → `matchOneScale`/`nccAt` → 工具与自检）。