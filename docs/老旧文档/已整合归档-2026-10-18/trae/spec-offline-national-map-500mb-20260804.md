# 全国离线地图 500MB 方案 Spec

> 档案标注（2026-09-19）：本 spec 属 C++ 路线历史方案（2026-08-04 备份）。其中引用的 `cpp/include/ad/*`、`cpp/src/sidecar_main.cpp`、`AuroraDriveApp/NavigationView.swift` 等路径现已全部不存在（C++ 为中间路线，当前架构为 Swift 原生：`Sources/AuroraDrive` 等 33 个 Swift 文件，见 `docs/dev/01-architecture.md`）。本文件仅作存档，不作为现状依据。

## Why
项目硬盘预算从 5GB 一路压缩到 1.3GB,最终用户拍板 500MB。500MB 内必须装下全国地图数据(路网+建筑+POI),且画质零损失、纯离线、零网络依赖。核心矛盾:全国 OSM 原始数据 4.55GB,要压进 500MB(含引擎 100MB + 数据 288MB + 缓存 110MB),压缩比需 16x。同时街道级显示瓦片不能预存(650MB 装不下),必须从 Valhalla tiles 现场生成,延迟需控制在用户无感知范围。

## What Changes
- **新增**:基于 Valhalla tiles 的现场瓦片生成器(显示瓦片不预存,运行时从路网拓扑提取几何生成 MVT)
- **新增**:马里奥瓦片法建筑压缩(100 模板 + 翻转变换,500 万建筑压到 58MB,零画质损失)
- **新增**:视觉优先级加载策略(中心先、边缘后,替代热门预生成)
- **新增**:渐进式渲染(低精度过渡 25ms,最终完整画质,不做瓦片简化)
- **新增**:R-tree 内存索引(瓦片查询 50ms → 5ms)
- **新增**:后台预取 + 并行生成(用户感知零延迟)
- **新增**:POI 地址三层方案(10% OSM 精确 + 90% 程序化生成"XX路附近" + 用户手动补)
- **修改**:Valhalla tiles 精简配置(只 car costing,砍自行车/人行/transit/shortcuts 元数据,LZ4 压缩,3.4GB → 200MB)
- **修改**:POI 精简(只 name+lon+lat+10%地址,前缀字典编码,zstd 压缩,400MB → 62MB)
- **删除**:path_planner.h 的 A*(全国 Valhalla 已覆盖,A* 降级备用废弃)
- **删除**:预生成显示瓦片方案(pmtiles zoom 0-12 650MB,装不下,改为现场生成)
- **删除**:热门区域预生成(用户否决,改为视觉优先级)
- **删除**:瓦片简化(道格拉斯-普克,用户否决,保画质)

## Impact
- 受影响 spec:fix-24-issues-layered(地图加载相关)、sync-project-documentation(文档同步)
- 受影响代码:
  - `cpp/include/ad/valhalla_router.h`(精简配置 + LZ4 加载)
  - `cpp/include/ad/path_planner.h`(废弃删除)
  - `cpp/include/ad/simulator.h`(A* 调用点改为 Valhalla 独占)
  - `cpp/include/ad/map_loader.h`(建筑参数化加载)
  - `cpp/src/sidecar_main.cpp`(瓦片生成端点)
  - 新增 `cpp/include/ad/tile_generator.h`(现场瓦片生成)
  - 新增 `cpp/include/ad/building_atlas.h`(马里奥瓦片法建筑)
  - 新增 `cpp/include/ad/visual_priority_loader.h`(视觉优先级加载)
  - 新增 `cpp/include/ad/poi_store.h`(POI 存储+地址生成)
  - 新增离线工具 `cpp/tools/build_offline_data.cpp`(构建期数据压缩)
  - `AuroraDriveApp/NavigationView.swift`(MVT 渲染 + 视觉优先级)
- 新增依赖:pmtiles C++ 库(8.6% 代码,BSD 许可,零外部运行时依赖)

## ADDED Requirements

### Requirement: 现场瓦片生成器
系统 SHALL 在运行时从 Valhalla tiles 提取道路几何,生成 MVT 矢量瓦片用于显示,不预存显示瓦片。

#### Scenario: 用户浏览某区域
- **WHEN** 用户缩放/平移到某区域(zoom ≥ 12)
- **THEN** 检查 LRU 缓存(78MB)是否命中
- **AND** 命中则直接返回(< 50ms)
- **AND** 未命中则从 Valhalla tiles 提取 bbox 内道路几何,切割+编码成 MVT,存入 LRU
- **AND** 生成延迟 ≤ 200ms(优化后)

### Requirement: 马里奥瓦片法建筑压缩
系统 SHALL 使用模板复用 + 翻转变换压缩全国建筑数据,500 万建筑压到 58MB,画质零损失。

#### Scenario: 建筑数据构建
- **WHEN** 离线工具处理 osm.pbf 建筑数据
- **THEN** 识别 100 种基础形状模板(矩形/L形/T形/梯形等)
- **AND** 每模板支持 4-8 种翻转变换,共 300 变体
- **AND** 95% 建筑参数化存储(15 字节/个:模板ID+朝向+中心XY+宽高+楼层)
- **AND** 5% 异形建筑单独存 polygon
- **AND** zstd 压缩到 58MB
- **AND** 位置精度 0.001 米,尺寸精度 0.1 米,楼层 0-255

#### Scenario: 建筑渲染
- **WHEN** 前端请求某 bbox 内建筑
- **THEN** mmap 查询参数文件,返回建筑参数列表
- **AND** 前端用模板库重建 polygon(缩放+旋转+平移)
- **AND** 渲染零延迟(< 1ms/建筑)

### Requirement: 视觉优先级加载
系统 SHALL 按人类视觉注意力分布决定瓦片加载顺序,中心先、边缘后,不预生成热门区域。

#### Scenario: 加载优先级
- **WHEN** 触发多张瓦片请求
- **THEN** 优先级 1:中心瓦片(ego 位置),0ms 必须有
- **AND** 优先级 2:中心相邻 4 张,200ms 内完成
- **AND** 优先级 3:中心对角 4 张,400ms 内完成
- **AND** 优先级 4:边缘瓦片,600ms 内完成
- **AND** 用户感知零延迟(第一眼位置最先加载)

### Requirement: 渐进式渲染
系统 SHALL 先显示低精度过渡版,后替换完整精度,最终画质零损失,不做瓦片简化。

#### Scenario: 渐进式显示
- **WHEN** 瓦片生成中
- **THEN** t=25ms:显示 zoom-2 几何低精度版(用户看到路)
- **AND** t=200ms:替换成完整精度版(所有顶点)
- **AND** 最终画质完整,不做道格拉斯-普克简化

### Requirement: R-tree 内存索引
系统 SHALL 启动时构建 R-tree 索引加速瓦片查询,查询延迟 50ms → 5ms。

#### Scenario: 索引构建
- **WHEN** sidecar 启动
- **THEN** 读取 Valhalla tiles 所有道路 bbox
- **AND** 构建 R-tree(耗时 ~2 秒)
- **AND** 查询时 O(log n) 定位视野内道路

### Requirement: 后台预取
系统 SHALL 根据用户移动方向预测下一张瓦片并提前生成。

#### Scenario: 预取命中
- **WHEN** 用户向某方向拖动地图
- **THEN** 检测移动方向,预测前方 2 张瓦片
- **AND** 后台线程提前生成
- **AND** 用户拖到该位置时缓存命中,0ms

### Requirement: 并行生成
系统 SHALL 多线程并行生成多张瓦片,Mac 8 核上 4 并行。

#### Scenario: 并行处理
- **WHEN** 一次触发 4 张新瓦片
- **THEN** 4 线程并行生成(每张 200ms)
- **AND** 总耗时 200ms(非 800ms)

### Requirement: POI 地址三层方案
系统 SHALL 提供三层地址能力:OSM 精确 + 程序化生成 + 用户手动补。

#### Scenario: 地址查询
- **WHEN** 用户查询某 POI 地址
- **THEN** 若 OSM 有 addr:street(10%),返回精确地址
- **AND** 若无,从 Valhalla 找最近道路,生成"XX路附近XX米"
- **AND** 用户可手动标注常去地,存本地 SQLite

## MODIFIED Requirements

### Requirement: Valhalla tiles 精简配置
Valhalla tiles 构建配置 SHALL 只保留 car costing,砍掉自行车/人行/transit/shortcuts 元数据,LZ4 压缩打包。

- 原配置:include_bicycle=true, include_pedestrian=true, include_driveways=true
- 新配置:全部 false
- 体积:3.4GB → 200MB
- 画质:零损失(只砍自动驾驶不需要的数据)

### Requirement: POI 精简存储
POI SQLite SHALL 只存 name+lon+lat+10%地址,前缀字典编码,zstd 压缩。

- 原方案:完整字段 400MB
- 新方案:精简 62MB
- 坐标:uint24(精度 3.7 米)
- 名称:前缀字典("路/街/号/小区"压缩)

## REMOVED Requirements

### Requirement: path_planner.h A* 降级备用
**Reason**: 全国 Valhalla 已覆盖,A* 只有福建且性能差,降级备用无意义。
**Migration**: simulator.h 调用点改为 Valhalla 独占,失败报错不降级。

### Requirement: 预生成显示瓦片(pmtiles zoom 0-12)
**Reason**: 650MB 装不进 500MB 预算,改为现场生成。
**Migration**: 显示瓦片运行时从 Valhalla tiles 提取,LRU 缓存 78MB。

### Requirement: 热门区域预生成
**Reason**: 用户否决,改为视觉优先级加载(中心先、边缘后)。
**Migration**: 加载顺序按视觉注意力动态决定,不预存任何区域。

### Requirement: 瓦片简化(道格拉斯-普克)
**Reason**: 用户要求画质零损失,简化会降画质。
**Migration**: 保留所有顶点,不做简化,靠渐进式渲染+并行+预取降延迟。

## 500MB 预算分配

| 数据 | 体积 | 说明 |
|------|------|------|
| 引擎(不压缩) | 100MB | libvalhalla 30MB + ONNX 50MB + sidecar 15MB + pmtiles 5MB |
| Valhalla tiles(LZ4+精简) | 200MB | 全国路网,规划+显示数据源 |
| 全国建筑(马里奥法) | 58MB | 100模板+翻转,零画质损失 |
| POI(含10%地址) | 62MB | name+lon+lat+前缀字典+zstd |
| LRU 缓存 | 78MB | 街道级瓦片缓存,~400 张 |
| 缓冲 | 2MB | — |
| **合计** | **500MB** | — |

## 延迟优化(不降画质)

| 优化 | 效果 | 降画质 |
|------|------|--------|
| R-tree 索引 | 查询 50ms → 5ms | ❌ |
| 视觉优先级 | 中心 0ms | ❌ |
| 渐进式渲染 | 感知 25ms | ❌(最终完整) |
| 后台预取 | 移动 0ms | ❌ |
| 并行生成 | 4 张并行 200ms | ❌ |
| MVT 编码缓存 | 编码 30ms → 10ms | ❌ |

## 全国能力

| 功能 | 能力 | 代价 |
|------|------|------|
| 路径规划 | ✅ 全国完整 | 零 |
| POI 搜索 | ✅ 全国 | 只名字+坐标+10%地址 |
| 主干道显示 | ✅ 全国 | 缓存命中秒开 |
| 街道级显示 | ✅ 全国 | 首次 25-200ms(渐进+预取) |
| 建筑轮廓 | ✅ 全国 | 马里奥法零损失 |
| 小区名 | ✅ 全国 | POI 画点 |
| 地址 | ⚠️ 10%精确+90%生成 | 无门牌号 |
| 地形/水系 | ❌ | 500MB 装不下 |
