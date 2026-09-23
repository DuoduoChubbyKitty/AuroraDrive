# 代码-27 GameMapView 大地图与传送

> 覆盖源文件：`Sources/AuroraDrive/App/GameMapView.swift`（1863 行）。基于当前仓库逐单元编写。

## 一、数据模型与主视图布局（第 1–417 行）

**文件头（4–17 行）**：GameMapView——异环游戏交互式地图 (v3)：顶部三模式分段控件（正常地图/按种类筛选/选择地图）+ 左侧侧边栏（分类选择器 + 索引搜索）+ 三种渲染模式 + 标记详情卡片；**数据：models/nte-game.jpg (4K底图) + models/FINAL_complete_map_database.json**；设计 Tesla FSD 驾驶舱风格。

**引用关系（grep 实测）**：`GameMapView` 唯一调用方 = GameMapCard:1859（`.sheet(isPresented:)`，minWidth 1100 × minHeight 720）；`GameMapCard` 唯一调用方 = SidebarView:3668（侧边栏六面板第五个）。

**`MapDatabase`（Codable，第 26–40 行）**——完整地图数据库（从 FINAL_complete_map_database.json 加载）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `summary` | DatabaseSummary? | 汇总（total_markers/bounds_percent/by_category/marker_types_cn/regions_cn） |
| `markers_all / waypoints / phone_booths / towers / services / shops / bosses / monsters / regions / materials / quests_activities` | `[MapMarker]?` | **11 类标记数组**（全部可选以容错） |
| `marker_types` | `[String: MarkerTypeInfo]?` | 类型元信息（color/label/labelEn） |

**`DatabaseSummary`（42–48 行）**：total_markers/bounds_percent（x_min~y_max）/by_category/marker_types_cn（key→中文名）/regions_cn（key→RegionInfo zh/en/color）。

**`MapMarker`（Codable, Identifiable, Hashable，第 70–140 行）——单个标记（统一结构，所有字段可选以容错）：**

- **id（计算属性，第 71 行）**：`"\(type)_\(Int(x))_\(Int(y))_\(name)"`——**不解码 JSON 中的 id 字段（值类型不统一：有的字符串有的数字），Identifiable 的 id 用计算属性生成，避免解码冲突**（CodingKeys 84–86 行显式排除 id）
- 字段：name/nameEn/type/x/y/subtype/region/icon/link（全部可选）
- **`displayName`（88–93 行）**：**清理 HTML 标签后的显示名**——`replacingOccurrences(of: "<[^>]+>", regex)` + trim
- **`labelName`（95–122 行）**——地图标签简短中文名（**避免重复名拥挤**）：waypoint → **按 subtype 显示「计程车」（taxi）/「传送点」**；tower → "维特海默塔"；phone-booth → "电话亭"；oracle-stone → "谕石"；chest → "宝箱"；**boss/其他 → displayName 保留具体名字**
- `safeX/safeY`：坐标安全取值（nil → 50.0）
- **`indexKey`（128–139 行）**——拼音首字母（**简化版：取 displayName 首字符**；完整拼音转换需引入 CFStringTokenizer，此处用首字符大写分类）：字母 → 大写；数字 → "#"；中文 → "中"

**`MapMode`（enum: String, CaseIterable，第 145–169 行）——三种地图模式**：`.normal`（"正常地图"，map 图标，副标题"传送点 · 地名"）/ `.filter`（"按种类筛选"，decrease.circle，"材料 · BOSS · 怪物"）/ `.selectMap`（"选择地图"，grid.2x2，"区域 · 快速定位"）。

**`MarkerCategory`（Identifiable, Hashable，第 174–192 行）**——标记分类配置（侧边栏筛选用）：id/label/color/icon/isEnabled/count；**`parseColor(_ hex:)`——从 nteguide 颜色字符串解析 SwiftUI Color**（去 # + UInt32 hex → r/g/b；解析失败回退 Theme.cyan）。

**`GameMapView` 状态（第 196–252 行）：**

| 组 | 字段 | 说明 |
|---|---|---|
| 数据路径 | `mapImagePath` / `altMapImagePath` / `dataPath` | **⚠️ 原 yihuan_map_z5.png 为游戏地图，道路拼接错乱，已弃用；主底图改用 IMG_1366 截图 PIL Lanczos 4x 超分；⚠️ 旧底图 enhanced_1366.png 已废弃由用户手动删除；新底图改用 MaaNTE-Map map-2026-08 扩图版 bigworldmap-13056.jpg（13056×13056，2026-09-13 自 Maa-NTE/MapSource 51×51 瓦片拼合，含全部新区域）**——**三条硬编码路径** |
| 缩放/拖拽 | scale/lastScale（**初始 0.11**）/offset/lastOffset | 初始缩放让 13056px 地图缩到适配画面 |
| 数据 | db: MapDatabase? / mapImage: NSImage? / **mapSize（默认 3840，loadData 后更新为实际宽）** / mapAspect（默认 16/9，loadData 后更新） | isLoading 加载动画 |
| 模式 | mode: MapMode（.normal） | 三模式 |
| 筛选 | categories: [MarkerCategory] | buildCategories 构建 |
| 选中/搜索 | selectedMarker/searchText/selectedRegion（默认 nil） | 详情卡片 |
| 其他 | isClosing / sidebarTab（.categories）/ layersOpen（false） | 关闭动画/侧边栏 tab/图层浮层 |
| **normalModeTypes** | `Set<String> = ["waypoint", "phone-booth", "tower", "region"]` | **正常模式下始终显示的类型（轻量底图）** |
| **categoryDefs** | 18 项 (id, label, icon) | **所有支持的分类定义，材料已细分**——用于侧边栏筛选 + 正常模式分层渲染 |

**categoryDefs 18 类**（256–276 行）：waypoint 传送点/region 区域地名/phone-booth 电话亭/tower 维特海默塔/boss 异象BOSS/quest 任务/activity 活动/viewpoint 景点/service 城市服务/shop 商店 + **材料细分 8 类**：oracle-stone 谕石(玉石) 258个紫色/chest 宝箱 109个橙色/collectible 收集品 641个绿色/mystery-box 神秘箱 966个紫色/gift-21 「21」的赠礼 112个粉色/currency 货币战利品 964个黄色/arc-plate 弧盘 27个紫色/monster 怪物 712个红色。

**body 布局（第 278–417 行）——ZStack 八层：**

1. **深空背景**：Color.black + RadialGradient（cyan 0.06，600 半径）——allowsHitTesting(false)
2. **地图画布**：mapCanvas
   - **小地图已迁移（296–298 行注释）**："小地图已迁移至主窗口常驻 FloatingMinimap（AuroraDriveApp.swift，参考坐标系实现：11264 像素、当前瓦片局部视图）；**大地图详情页本身即完整地图，不再嵌套重复的小地图，避免两处坐标系不一致**"
3. **顶部工具条**：topBar + Spacer + **mode != .normal 时 bottomStatusBar**——zIndex(10)
4. **左侧侧边栏**：mode != .normal 时 sidebar（300 宽 + sidebarBackground + leading 移入过渡）——zIndex(20) + spring 动画（0.42/0.86）
5. **图层浮层**：layersOpen 时 layerPanel（284 宽 + trailing 移入）——zIndex(25)；**水平内边距 16px：面板左移，露出右上角缩放控件区域（避免 300px 面板盖住 topBar 的加减按钮）**
6. **三模式分段控件**：顶部正中央独立浮层（zIndex(30)——**放在 topBar 之上，确保可见可点**）+ shadow
7. **关闭按钮**：右下角浮动（zIndex(40)）——**注意：不能用 allowsHitTesting(false) 包裹，否则按钮也点不到**
8. **标记详情浮窗**：selectedMarker 时 markerDetailCard（scale 0.9 + opacity 过渡，zIndex(50)）
9. **加载动画覆盖层**：isLoading 时黑 0.85 + **呼吸圆环 + 旋转弧**（56pt，AngularGradient trim 0.7 + linear 0.9 repeatForever）+ "正在加载地图…"（13pt tracking 2）——zIndex(1000)

**生命周期（408–416 行）**：`.onAppear { loadData() }`；**`.onDisappear`——P1 修复：关闭地图 sheet 时释放 8636×8592 巨图（解码后 ≈280MB 常驻），避免反复开合地图后内存累积**——mapImage = nil + db = nil；两个 spring 动画（selectedMarker 0.3 / mode 0.4）。

## 二、关闭按钮 / 地图画布 / 手势 / 标记层（第 420–696 行）

**引用关系（grep 实测）**：`dragGesture/magnifyGesture` 唯一调用方 = mapCanvas:521/522；`filteredMarkers` 两个调用方 = markerLayer:591 + bottomStatusBar:1656（计数显示）；`buildCategories` 唯一调用方 = loadData:1718；`defaultColor` 两个调用方 = markerView:626 + buildCategories:1779。

**`closeButton`（private，第 420–462 行）——关闭按钮（右下角浮动，带按下动画 + 关闭过渡）**：

- 点击：`withAnimation(.easeIn(0.18)) { isClosing = true }` → **0.18s 后 dismiss()**（**先缩小淡出，再 dismiss**）
- 渲染：**外圈呼吸光晕（红 0.20 圆 52pt + shadow 10）** + 红色径向渐变圆（40pt，1.0/0.40/0.32 → 0.78/0.14/0.14）+ 白 0.55 描边 + xmark（16pt black rounded 白字 + 黑 shadow y0.5）；`scaleEffect(isClosing ? 0.85 : 1.0)` + opacity 0.6

**`sidebarBackground`（private，第 464–491 行）——侧边栏背景：玻璃拟态 + 右侧青色细描边**：主体 `.ultraThinMaterial.opacity(0.92)` + 顶部细微高光（cyan 0.08→clear，120 高）+ 右侧描边发光（cyan 0.4→0.08，宽 1 + shadow 4）——高光/描边都 allowsHitTesting(false)。

**`mapCanvas`（private，第 495–555 行）——地图画布：**

- **有图分支（497–529 行）**：GeometryReader × ZStack——**底图**：Image(nsImage:).resizable().**scaledToFill()** + `.frame(width: mapSize × scale, height: mapSize × scale / mapAspect)` + clipped() + **边缘渐隐遮罩（黑 0.4→clear→clear→黑 0.4 水平，营造无限延伸感）** → **标记层**（markerLayer）→ `.offset(offset)` + frame(geo 尺寸) + clipped() + **`.gesture(dragGesture)` + `.gesture(magnifyGesture)` + `.onTapGesture`（点击空白处取消选中）**
- **无图分支（530–554 行）**：呼吸圆环加载动画（44pt trim 0.7 + linear 1.0 repeatForever，value: mapImage != nil）+ "加载地图数据中…"（12pt tracking 1）

**已删除注释（557–560 行）**：**小地图 minimapView 已删除**——迁移至主窗口 FloatingMinimap（参考坐标系：11264 像素 + 当前瓦片局部视图 + 瓦片内光标）；**三角形指示器已移至 AuroraDriveApp.swift 的 DirectionTriangle，FloatingMinimap 复用同款**。

**`dragGesture`（563–572 行）**：DragGesture——offset = lastOffset + translation（onChanged）；onEnded 时 lastOffset = offset（**松手固定**）。

**`magnifyGesture`（575–582 行）**：MagnificationGesture——`delta = g / lastScale; scale = min(max(lastScale × delta, 0.08), 3.0)`——**缩放范围 0.08~3.0**；onEnded 时 lastScale = scale。

**`markerLayer`（@ViewBuilder，第 587–600 行）**：db 存在时——`renderW = mapSize × scale; renderH = renderW / mapAspect` → `filteredMarkers(db:)` → **ForEach(activeMarkers) { markerView(m, renderW:renderH:) }**（ZStack + frame(renderW×renderH)）。

**`filteredMarkers(db:)`（private，第 604–617 行）——根据图层开关状态返回要渲染的标记（图层浮层 / 筛选侧栏共享同一份 categories 状态）：**

- **⚠️ 标记坐标目前与底图可能未配准（旧数据），待本机重抓 nteguide 最新数据后校准**（603 行注释——诚实标注）
- `enabledTypes = Set(categories.filter { $0.isEnabled }.map { $0.id })`；空 → []（**全关 = 不渲染任何标记**）
- `all.filter { enabledTypes.contains($0.type) }` → **搜索过滤（与侧边栏索引一致）**：name/nameEn `localizedCaseInsensitiveContains(searchText)`

**`markerView(_ m:renderW:renderH:)`（@ViewBuilder，第 621–696 行）——单个标记视图：**

- **坐标换算（622–623 行）**：`px = safeX / 100 × renderW; py = safeY / 100 × renderH`——**标记坐标是百分比（0~100）**（与 13056 像素坐标系的 FloatingMinimap 不同体系）
- **尺寸自适应（632–636 行）**：`baseSize = max(7, min(14, 5 + scale × 30))`——**标记尺寸根据缩放动态调整，确保低缩放也可见**；dotSize：waypoint ×1.3 / boss ×1.4 / 普通 baseSize；**showLabel = isSel \|\| isRegion \|\| isWaypoint \|\| isTower \|\| isBoss \|\| scale > 0.3——核心标记（传送点/塔/区域）始终显示中文标签，其他类型缩放足够大才显示**
- **区域名分支（639–648 行）**：isRegion → **大号文字标签**（`max(13, 20 × scale × 1.4)` heavy rounded + 类别色 + **双层 shadow（类别色 0.8/6 + 黑/3）**）+ position + onTapGesture（**再点取消**）
- **普通标记分支（650–695 行）**：ZStack——选中外圈呼吸光环（`dotSize × 2.2`，color 0.4 描边 + shadow 8）+ 主圆点（**选中放大 ×1.4** + color 0.9 shadow + 白 0.85 描边 0.8）+ **中文标签（674–689 行）**：labelName（`max(9, 11 × scale × 1.1)` semibold 白字 + 黑 0.75 圆角底 + color 0.4 描边 0.5 + offset y -14/-10）→ position + onTapGesture

## 三、topBar / 搜索框 / 缩放控件 / 三模式分段（第 698–872 行）

**引用关系（grep 实测）**：`searchBar` 唯一调用方 = topBar:717（mode != .normal 时显示）；`zoomButton` 三个调用方 = topBar:726/735/741（minus/plus/复位）；`layerToggleButton` 唯一调用方 = topBar:722；`modeSegmentedControl → modeSegment` 唯一调用链 = body 第 5 层浮层:340。

**`topBar`（private，第 700–761 行）——顶部工具条**：

1. **标题（702–711 行）**：map.fill + "异环地图"（13pt bold rounded 白字 + cyan 发光 3）
2. **搜索框（715–719 行）**：`mode != .normal` 时 searchBar（scale + opacity 过渡——**正常地图模式不显示搜索**）
3. **图层开关按钮（721–722 行）**：layerToggleButton（**常驻，点一下从右侧拉下图层面板**）
4. **缩放控制（724–747 行）**：zoomButton("minus")——`scale = max(scale × 0.75, 0.08)`（easeOut 0.2）+ 百分比显示（`Int(scale × 100)%`，monospaced 38 宽）+ zoomButton("plus")——`min(scale × 1.3, 3.0)` + Divider + **zoomButton("location.fill") 复位**——`scale = 0.22; offset = .zero`（spring 0.5/0.8）
5. **外框（749–760 行）**：水平 14/垂直 8 + ultraThinMaterial 0.75 底 + 底部青色细描边（1pt，0.15）

**`modeSegmentedControl`（763–779 行）——三模式分段控件（精致胶囊样式）**：HStack(spacing 2) × ForEach(MapMode.allCases) → modeSegment；padding 3 + 白 0.05 圆角底（9pt）+ 白 0.06 描边 0.5。

**`modeSegment(_ m:)`（782–821 行）——单个模式分段**：

- 点击：spring（0.35/0.82）→ mode = m；**切到正常模式时清空选中**（788 行）
- 渲染：icon（10pt semibold）+ rawValue（11pt medium rounded）——**active：白字压 cyan 渐变底（0.35→0.15）+ 0.5 描边 0.8 + shadow 4**；非 active：textSecondary；help（m.subtitle——"传送点 · 地名"等）

**`searchBar`（824–856 行）——搜索框**：

- magnifyingglass（cyan 0.7）+ TextField（"搜索地名 / 材料…"，12pt rounded 白字，140 宽）+ **清空按钮（searchText 非空时显示，xmark.circle.fill）**
- 外框：白 0.06 圆角底（7pt）+ **描边随搜索状态变色（空 = 白 0.08；非空 = cyan 0.4）**

**`zoomButton(_ icon:action:)`（859–872 行）**：icon（10pt semibold cyan）+ 22×22 圆（白 0.08 底 + 白 0.06 描边 0.5）。

## 四、侧边栏 / 索引 / 选图模式 / 详情浮窗（第 874–1690 行）

**引用关系（grep 实测）**：`sidebarHeader/sidebarTabSwitcher/filterContent/indexContent/selectMapContent` 由 sidebar:880–892 统一编排；`categoryRow` 两个调用方（filterContent:1012 + layerPanel:1190 **共用同一份 categories 状态**）；`zoomToMarker/zoomToRegion` 各唯一调用方 = indexRow:1288 / regionRow:1410；`regionMarkerCount` 唯一调用方 = regionRow:1437。

**`sidebar`（876–897 行）**：ScrollView × VStack——sidebarHeader + **mode == .filter 时双 tab（sidebarTabSwitcher + filterContent/indexContent）**；否则 selectMapContent（选图模式区域列表）；底部 padding 40。

**`sidebarHeader`（900–936 行）**：模式图标（filter → decrease.circle / selectMap → grid.2x2）+ 标题（"分类筛选"/"区域选择"）+ subtitle——**顶部 padding 56（避开三模式分段控件）**。

**`sidebarTabSwitcher`（939–968 行）**：ForEach(SidebarTab.allCases)——"分类"/"索引" 双 tab；**active：白字压 cyan 0.25 底**；spring 0.3/0.85。

**`filterContent`（973–1017 行）——筛选模式分类列表**：

- **全选/清空 + 统计（976–1008 行）**：全选（categories 全 isEnabled=true）/清空（全 false）+ **统计（`reduce(0) { $0 + $1.count }`——已启用分类的标记总数）**
- **分类列表（1011–1013 行）**：`ForEach($categories) { categoryRow($cat) }`（**Binding 遍历——双面板共享**）

**`categoryRow(_ cat: Binding<MarkerCategory>)`（1020–1090 行）——单个分类行（精致卡片样式）**：

- 点击：`cat.wrappedValue.isEnabled.toggle()`（spring 0.25/0.9）
- 渲染：**左侧色条（3×22 + 发光 3 + enabled ? 1 : 0.3）** + 图标圆（24pt，color 0.2/0.05 底）+ 标签（12pt semibold）+ **"N 个标记"（9pt monospaced）** + **自定义开关（30×16 Capsule + 圆点 11pt，offset ±6）**——**开关颜色跟随类别色**（非统一 cyan）
- enabled 时卡片底色 = color 0.06；contentShape(Rectangle())

**`layerToggleButton`（1095–1114 行）——顶部工具栏的图层开关按钮（📑）**：square.stack.3d.up（fill 与否）——**layersOpen ? cyan : textSecondary** + 圆底 + 发光；help（"图层（随时开关各收集层）"）。

**`layerPanel`（1117–1197 行）——图层浮层面板（从右侧弹簧拉下，列出所有图层，可单独开关 + 全选/清空）**：标题（"图层 · 随时开关 · 全收集叠加"）+ 全选/清空 + 统计 + **分类列表（与筛选侧栏共用 categoryRow）**——**与 filterContent 操作同一份 categories 状态，图层浮层独立于模式（正常地图模式也能开）**。

**`indexContent`（1202–1244 行）——索引内容（按首字母/字符分组列出所有可搜索的标记）**：

- **索引提示**：textformat + "按拼音/字母索引" + `totalIndexed`（indexGroupedMarkers 总数）
- **indexJumpBar（1247–1264 行）**：字母快速跳转条（**每个 key 14×14，cyan 0.8——纯显示无滚动定位**）
- **分组列表（1226–1240 行）**：`ForEach(indexGroupedMarkers.keys.sorted())` → indexSectionHeader(key) + **`ForEach(items.prefix(40))`——每组最多 40 行** + **超过时 "… 还有 N 项"**

**`indexSectionHeader`（1267–1280 行）**：key（11pt heavy cyan 发光）+ 细线（0.5pt，0.15）。

**`indexRow(_ m:)`（1283–1312 行）——索引单行**：点击 → selectedMarker = m + **zoomToMarker(m)**（缩放到该标记）；渲染：类别色点（5pt）+ displayName（11pt，lineLimit 1）+ 类别 label（9pt）；选中底 = cyan 0.1。

**`indexGroupedMarkers`（计算属性，1315–1336 行）——索引分组后的标记（按 indexKey 分组）**：

- **索引只在已启用分类的标记中建立**（1317 行）——filter 模式：markers_all 过滤 enabledTypes；其他模式：全量
- 搜索过滤同 filteredMarkers → **`grouped[m.indexKey, default: []].append(m)`**（indexKey：字母大写/数字# /中文"中"）

**`selectMapContent`（1341–1402 行）——选择地图模式内容**：

- **5 区域硬编码表（1343–1349 行）**：new-herland 新赫兰德(蓝, building.2.fill)/bridge-crossings 桥间地(紫, bridge.fill)/miguel-district 米格尔区(绿, tree.fill)/illusion-town 幻镇(橙, sparkles)/unheard-shores 未闻浦(青, water.waves) → regionRow
- **当前区域信息卡（1357–1400 行）**：selectedRegion + db 时——"当前区域" + 中文名（16pt heavy）+ **"N 个标记点"**（`markers_all.filter { $0.region == sel }.count`）——cyan 渐变底 + 0.25 描边

**`regionRow(_ r:)`（1405–1465 行）——单个区域行**：点击 → selectedRegion = r.key + **zoomToRegion(r.key)**；渲染：区域图标（36pt 渐变底）+ zh 名（13pt）+ regionMarkerCount（"N 个标记"）+ **isActive 时 checkmark.circle.fill（cyan 发光）**。

**`regionMarkerCount(_ key:)`（1468–1472 行）**：`markers_all.filter { $0.region == key }.count`。

**`markerDetailCard(_ m:)`（1477–1568 行）——选中标记的详情卡片（右下角浮窗）**：

- 左侧色块（44pt 渐变底 + 0.5 描边）+ 类别 icon（18pt）
- **中间信息**：displayName（14pt bold，lineLimit 1）+ **类型标签（Capsule，color 0.18 底）** + **坐标（`%.1f` monospaced，location 图标）** + **区域（globe 图标，region 非空时）**
- 关闭按钮（xmark.circle.fill → selectedMarker = nil）
- 外框：maxWidth 380 + **ultraThinMaterial 0.95 底 + color 0.35 描边 + color 0.2 shadow 12** + padding 16

**`zoomToRegion(_ key:)`（1573–1599 行）——缩放到指定区域中心**：

1. `markers = markers_all.filter { $0.region == key }`；空 → return
2. **平均中心（1578–1579 行）**：`avgX/avgY = markers.reduce(...) / count`——区域所有标记的平均位置
3. **适度放大（1582–1587 行）**：scale < 0.35 → 0.4（spring 0.5/0.85）
4. **offset（1589–1598 行）**：`targetPx = avgX/100 × renderW` → **屏幕中心（假设窗口约 900x600，侧边栏占 300）**：`centerX = 450 + 150; centerY = 300`——**窗口尺寸硬编码**（地图卡片实际 1163×680，此假设有偏差）；offset = 窗口中心 - targetPx

**`zoomToMarker(_ m:)`（1602–1617 行）**：同构——scale < 0.5 → 0.6；同款硬编码中心。

**`bottomStatusBar`（1621–1690 行）——底部状态栏（mode != .normal 时显示）**：

1. **选中标记信息（1624–1648 行）**：色点 + displayName + 坐标（紧凑版，cyan 0.1 底）
2. **标记统计（1650–1660 行）**：circle.grid.2x2.fill + **`"\(filteredMarkers(db:).count) / \(total_markers ?? 5677)"`**——当前筛选显示数 / 总数
3. **图例（1664–1677 行）**：`ForEach(categories.filter { $0.isEnabled }.prefix(6))`——**最多 6 个已启用分类**的色点 + label
4. 外框：ultraThinMaterial 0.65 + 顶部细线（0.12）

## 五、loadData / buildCategories / GameMapCard 与数据实况（第 1692–1863 行）

**数据实况（本机验证）**：`models/bigworldmap-13056.jpg`（7.4MB，2026-09-13）与 `models/FINAL_complete_map_database.json`（7.2MB）均存在；**JSON 实测 total_markers = 5677、markers_all = 5677、marker_types = 18 个**——UI 卡片文案"三模式 · 5677标记"精确对齐；**样例标记 x=48.08/y=50.71 确认百分比坐标（0~100）**；**type 值域 18 个与 categoryDefs 18 类完全对齐**（单数形式）：mystery-box 966/currency 964/monster 712/shop 677/collectible 641/viewpoint 495/quest 321/oracle-stone 258/service 129/activity 123/gift-21 112/chest 109/waypoint 100/arc-plate 27/phone-booth 17/boss 13/region 7/tower 6；**by_category 的 key 是"waypoints_传送点"复合格式（英文_中文），只做展示统计，与 filteredMarkers 的 type 匹配（单数）是两套口径**。

**`loadData()`（private，第 1694–1739 行）——数据加载（六步）：**

1. **巨图解码移到后台（1695–1703 行）**："巨图（8636×8592 PNG）解码移到后台，主线程零解码阻塞，只回写加载态"——`DispatchQueue.global(.userInitiated)` → mapImagePath 存在 → NSImage(contentsOfFile:)；缺失 → altMapImagePath（yihuan_map_z4.png）回退；都无 → decoded = nil
2. **主线程回写图片 + 尺寸（1705–1711 行）**：mapImage = img + **mapSize = img.size.width（13056）** + **mapAspect = w / max(h, 1)**（≈1.0——13056 方图）
3. **JSON 加载（1713–1722 行）**："JSON 较小（实际 7.2MB，注释口径滞后），保留主线程"→ `JSONDecoder().decode(MapDatabase.self)` → **buildCategories()**；解码失败 print 警告（**不中断，地图照常显示只是无标记**）
4. **默认选中新赫兰德（1724–1725 行）**：selectedRegion == nil → "new-herland"
5. **centerOnDataRegion()（1727–1729 行）**：计算初始 offset 让数据区域居中
6. **关闭加载动画（1731–1736 行）**：0.1s 后 easeOut 0.3 → isLoading = false

**`centerOnDataRegion()`（private，第 1742–1758 行）——计算偏移让数据区域中心居中显示**：

- `renderW/H = mapSize × scale (÷ mapAspect)`；**数据中心在底图坐标 (55%, 40%)**——"数据范围 x:25-85, y:5-75 → 中心 x=55%, y=40%"
- **窗口尺寸（地图卡片区域约 1163×680）硬编码**：`winW = 1163; winH = 680`
- `offset = CGSize(winW/2 - dataCenterX, winH/2 - dataCenterY)` + lastOffset 同步

**`buildCategories()`（private，第 1761–1793 行）——从数据库构建分类列表（使用 categoryDefs，从 markers_all 按 type 统计）**：

1. `all = markers_all; typeColors = marker_types`
2. **coreTypes（1767 行）**：`Set = ["waypoint", "region", "phone-booth", "tower"]`——**核心导航层默认开启，收集类默认关闭**
3. `categories = Self.categoryDefs.map { d in ... }`：
   - **count（1771 行）**：`all.filter { $0.type == d.id }.count`——按 type 统计实际数量
   - **颜色（1773–1780 行）**：**优先用 marker_types 的颜色（JSON 里数据库带的），否则用预设 defaultColor**
   - **isEnabled（1787–1789 行注释）**：**"打开地图默认只开核心导航层（传送点/区域/电话亭/塔），收集类图层（材料/宝箱/谕石/收集品…）默认关闭，全收集时在图层浮层手动开启"**——`coreTypes.contains(d.id)`

**`defaultColor(for type:)`（private，第 1796–1818 行）——各类型的默认颜色（marker_types 缺失时回退）**：18 类各自的 RGB 值——waypoint 黄(0.92,0.70,0.03)/region 灰/phone-booth 青/tower 橙/boss 红/quest 蓝/activity 粉/viewpoint 青/service 青绿/shop 青/oracle-stone 紫(玉石)/chest 橙/collectible 绿/mystery-box 紫/gift-21 粉/currency 黄/arc-plate 紫/monster 红(0.86,0.15,0.15)；**default → Theme.cyan**（未知类型兜底）。

**`GameMapCard`（struct: View，第 1824–1863 行）——可嵌入侧边栏的地图卡片（地图入口按钮）**：

- **`@State showMap = false`——默认关闭，由用户点「打开异环地图」才弹出**
- **打开按钮（1833–1851 行）**：map.fill + "打开异环地图"（13pt medium rounded cyan）+ chevron.right——白 0.05 圆角底（8pt）
- **说明文字（1853–1855 行）**："**三模式 · 5677标记 · 传送/材料/BOSS**"（10pt tertiary）——**与 JSON 实测 5677 精确对齐**
- **`.sheet(isPresented: $showMap) { GameMapView(state:).frame(minWidth: 1100, minHeight: 720) }`**——sheet 弹出（1100×720 最小尺寸）

**GameMapView 文档至此完整**（1863 行全覆盖：数据模型 → 主视图八层 → 画布/手势/标记层 → topBar/搜索/缩放 → 侧边栏/索引/选图/详情 → loadData/buildCategories/GameMapCard）。