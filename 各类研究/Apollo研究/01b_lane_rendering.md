# Apollo Dreamview 车道线渲染（Lane Marker / Lane Boundary）深度研究报告

> 研究对象：Baidu Apollo 开源仓库 `ApolloAuto/apollo` 中 Dreamview（经典版 `modules/dreamview`）的车道线数据链路与前端 Three.js 渲染实现。
> 研究目的：为 AuroraDrive（React + Three.js + Tauri 架构）的 SR 界面车道线渲染重写提炼可直接迁移的实现细节，并修复当前 `RoadNetwork.tsx` 用 `lineSegments` 导致道路"崎岖断续"以及 `simulator.h` 车道边界为空数组的问题。
> 信息来源：GitHub 仓库源码（通过 jsDelivr CDN 与 GitHub Contents API 抓取）、Apollo 官方文档、CSDN/掘源码解析专栏、Three.js 官方文档与社区。所有关键结论均附源码链接。

---

## 0. TL;DR（核心结论）

1. Apollo 车道线渲染走的是"**HD Map 静态车道边界**"路径，而非感知实时车道线。`MapService::RetrieveMapElements` 从 **sim_map**（base_map 的下采样轻量版）中按自车为中心 **200 米半径 ROI** 取出 `Lane`，仅保留 `left_boundary` / `right_boundary` 的 `Curve`，丢弃 `left_sample/right_sample` 等宽度关联数据，序列化为 protobuf 经 `Map` WebSocket 推给前端。
2. 前端 `utils/draw.js` 是车道线渲染的"原子库"：**实线用 `THREE.Line` + `LineBasicMaterial`（连续折线，不是 LineSegments）**；**虚线用 `THREE.Line` + `LineDashedMaterial`，且必须调用 `geometry.computeLineDistances()`**；**规划轨迹用 `three-line-2d` 库生成三角带 Mesh（粗带状）**，而不是细线。
3. 颜色编码采用"工程可视化"配色而非消费级 SR 配色：`YELLOW=0xDAA520`（金黄）、`WHITE=0xCCCCCC`（浅灰）、`PURE_WHITE=0xFFFFFF`、`CORAL=0xFF7F50`。
4. AuroraDrive 的两个核心缺陷与此直接对应：后端 `simulator.h:1553` 把 `left_boundary/right_boundary` 写成空数组（无数据源）；前端 `RoadNetwork.tsx` 用 `<lineSegments>` 把每相邻两点压成独立段，导致连续道路被切成断续线段。**修复方向：后端补边界点序列；前端实线改用 `<line>`（或 `Line2`），虚线用 `Line2`+`LineMaterial({dashed:true})`。**

---

## 1. 车道线数据来源

### 1.1 HD Map 车道边界 proto 定义

Apollo 高精地图采用"绝对坐标序列"描述边界形状（区别于标准 OpenDRIVE 的参考线+偏移方程）。车道相关 proto 定义（历史路径 `modules/map/proto/map_lane.proto`，在当前 master 已随 map 模块重组；以下为 proto 内容，源码解析参见 [CSDN: Apollo map 模块地图元素介绍](https://blog.csdn.net/qq_37346140/article/details/129569738)）：

```protobuf
// modules/map/proto/map_lane.proto
message LaneBoundaryType {
  enum Type {
    UNKNOWN = 0;
    DOTTED_YELLOW = 1;  // 黄色虚线
    DOTTED_WHITE = 2;   // 白色虚线
    SOLID_YELLOW = 3;   // 黄色实线
    SOLID_WHITE = 4;    // 白色实线
    DOUBLE_YELLOW = 5;  // 双黄线
    CURB = 6;           // 路缘
  };
  optional double s = 1;       // 相对边界起点的 s 偏移
  repeated Type types = 2;     // 同一 s 位置可支持多种类型
}

message LaneBoundary {
  optional Curve curve = 1;
  optional double length = 2;
  optional bool virtual = 3;   // 现实世界中是否存在该边界
  repeated LaneBoundaryType boundary_type = 4;  // 按 s 升序
}

message Lane {
  optional Id id = 1;
  optional Curve central_curve = 2;        // 中心线（参考轨迹）
  optional LaneBoundary left_boundary = 3;
  optional LaneBoundary right_boundary = 4;
  optional double length = 5;
  optional double speed_limit = 6;
  // ... predecessor_id / successor_id / 邻居车道 / type / turn 等
}
```

几何描述在 `modules/map/proto/map_geometry.proto`：

```protobuf
message LineSegment { repeated apollo.common.PointENU point = 1; }
message CurveSegment {
  oneof curve_type { LineSegment line_segment = 1; }
  optional double s = 6;                       // 起点 s 坐标
  optional apollo.common.PointENU start_position = 7;
  optional double heading = 8;
  optional double length = 9;
}
message Curve { repeated CurveSegment segment = 1; }
```

要点：
- `Lane.left_boundary.curve.segment[0].line_segment.point` 是一组 `PointENU`（UTM 平面坐标 x/y/z），这就是前端画线所用的点序列。
- `boundary_type` 是**按 s 分段的数组**，即同一条边界在不同 s 区间可以是不同类型（如先实线后虚线），前端需要按 s 切分绘制。
- `DOUBLE_YELLOW` 只是一个枚举值，proto 里**没有第二条线的几何**——前端需自行按法向偏移渲染第二条平行黄线。

### 1.2 感知输出的车道线（CameraLaneLine）

感知侧车道线定义在 `modules/common_msgs/perception_msgs/perception_camera.proto`（[GitHub](https://github.com/ApolloAuto/apollo/blob/master/modules/common_msgs/perception_msgs/perception_camera.proto)），由 `PerceptionLanes`（[perception_lane.proto](https://github.com/ApolloAuto/apollo/blob/master/modules/common_msgs/perception_msgs/perception_lane.proto)）承载：

```protobuf
enum LaneLineType {
  WHITE_DASHED = 0;  WHITE_SOLID = 1;
  YELLOW_DASHED = 2; YELLOW_SOLID = 3;
}
enum LaneLinePositionType {
  EGO_LEFT = -1;   // 自车道左线
  EGO_RIGHT = 1;   // 自车道右线
  ADJACENT_LEFT = -2;  ADJACENT_RIGHT = 2;
  // ... BOLLARD / THIRD / FOURTH / OTHER / UNKNOWN
}
message LaneLineCubicCurve {  // 三次多项式 a + b*x + c*x^2 + d*x^3
  optional float longitude_min = 1; optional float longitude_max = 2;
  optional float a = 3; optional float b = 4; optional float c = 5; optional float d = 6;
}
message CameraLaneLine {
  optional LaneLineType type = 1;
  optional LaneLinePositionType pos_type = 2;
  optional LaneLineCubicCurve curve_camera_coord = 3;   // 车辆坐标系拟合曲线
  repeated apollo.common.Point3D curve_camera_point_set = 5;  // 离散点
  optional int32 track_id = 8;
  optional float confidence = 9;          // 车道线置信度 0~1
  optional LaneLineUseType use_type = 10; // REAL / VIRTUAL
}
```

关键区别：
- **感知车道线**是相机实时检测的，带 `confidence`、三次曲线系数（`a/b/c/d`）、`track_id`，用于规划/控制，Dreamview 中作为次要叠加层（可切换显示）。
- **HD Map 车道边界**是离线高精地图的静态几何，无置信度，点密度受 sim_map 下采样控制，是 Dreamview 道路网渲染的**主数据源**。
- AuroraDrive 当前**两条路径都没有**：既无 HD Map 边界（simulator.h 空数组），也无感知车道线通道。

---

## 2. 后端车道线数据广播

### 2.1 三张地图：base_map / routing_map / sim_map

Apollo 维护三份地图（[CSDN: base_map/routing_map/sim_map 差异](https://blog.csdn.net/qq_37346140/article/details/129569738)）：
- `base_map`：最完整，包含所有道路与车道几何/标识。
- `routing_map`：base_map 的车道拓扑图，供路由搜索。
- **`sim_map`**：基于 base_map 的**下采样轻量版**，专供 Dreamview 可视化，降低数据密度以提升运行时性能。由 `modules/map/tools/sim_map_generator` 生成（[CSDN: sim_map_generator 解析](https://blog.csdn.net/tinamao______/article/details/146801954)）。

`MapService` 构造时 `use_sim_map_=true`，可视化取图一律走 `SimMap()`（[map_service.cc](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/map_service/map_service.cc)）：

```cpp
const hdmap::HDMap *MapService::SimMap() const {
  return use_sim_map_ ? HDMapUtil::SimMapPtr() : HDMapUtil::BaseMapPtr();
}
```

### 2.2 ROI 内车道线过滤：CollectMapElementIds

`CollectMapElementIds(point, radius, ids)` 以自车 PointENU 为圆心、`radius` 为半径，调用 `SimMap()->GetLanes(point, radius, &lanes)` 取出区域内所有车道，并抽取 lane_id / road_id（[map_service.cc](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/map_service/map_service.cc)）：

```cpp
void MapService::CollectMapElementIds(const PointENU &point, double radius,
                                      MapElementIds *ids) const {
  std::vector<LaneInfoConstPtr> lanes;
  if (SimMap()->GetLanes(point, radius, &lanes) != 0) {
    AERROR << "Fail to get lanes from sim_map.";
  }
  ExtractRoadAndLaneIds(lanes, ids->mutable_lane(), ids->mutable_road());
  // ... 同时取 crosswalk / junction / signal / stop_sign / yield / ...
}
```

半径由 gflag `sim_map_radius` 控制，**默认 200.0 米**（[dreamview_gflags.cc](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/dreamview_gflags.cc)）：

```cpp
DEFINE_double(sim_map_radius, 200.0,
              "The radius within which Dreamview will find all the map "
              "elements around the car.");
```

### 2.3 RetrieveMapElements：车道线提取算法

`RetrieveMapElements(ids)` 按 id 逐条 `GetLaneById` 取出 Lane，**清除宽度关联字段**后塞入返回 Map（[map_service.cc](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/map_service/map_service.cc)）：

```cpp
Map MapService::RetrieveMapElements(const MapElementIds &ids) const {
  Map result;
  Id map_id;
  for (const auto &id : ids.lane()) {
    map_id.set_id(id);
    auto element = SimMap()->GetLaneById(map_id);
    if (element) {
      auto lane = element->lane();
      lane.clear_left_sample();       // 丢弃中心点-边界宽度关联
      lane.clear_right_sample();
      lane.clear_left_road_sample();
      lane.clear_right_road_sample();
      *result.add_lane() = lane;      // left_boundary / right_boundary 的 Curve 保留
    }
  }
  // ... road / junction / signal / ...
}
```

关键结论：
- **前端拿到的 Lane 只剩 `central_curve` + `left_boundary` + `right_boundary`**（外加拓扑/限速元数据），宽度采样数据被剥离以减小体积。
- 同一物理边界在相邻 Lane 间会重复（A 的 right_boundary ≈ B 的 left_boundary），前端按 id 去重或接受重复绘制。
- 端点对齐由 HD Map 制作保证（base_map 的 polyline 端点在共享 Lane 处对齐）；sim_map 下采样后端点仍对齐，但中间点变稀疏。

### 2.4 车道线点密度与下采样

`SimulationWorldService` 在序列化曲线时会再做一次"按角度下采样"（[simulation_world_service.cc](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/simulation_world/simulation_world_service.cc)）：

```cpp
// Angle threshold is about 5.72 degree.
static constexpr double kAngleThreshold = 0.1;
void DownsampleCurve(Curve *curve) {
  if (curve->segment().empty()) return;
  auto *line_segment = curve->mutable_segment(0)->mutable_line_segment();
  std::vector<PointENU> points(line_segment->point().begin(),
                               line_segment->point().end());
  line_segment->clear_point();
  std::vector<size_t> sampled_indices = DownsampleByAngle(points, kAngleThreshold);
  for (const size_t index : sampled_indices)
    *line_segment->add_point() = points[index];
}
```

即：**相邻三点若转向角变化 < 0.1 rad（约 5.72°）则丢弃中间点**，直线段被大幅抽稀，弯道保留更多点。这是 Apollo 地图车道线"直段稀疏、弯道密集"的成因。base_map 原始点密度通常约每 0.5~2 米一个点，经 sim_map + DownsampleByAngle 后直段可能稀疏到每 10+ 米一个点。

### 2.5 数据推送通道

地图元素走独立 `Map` WebSocket（`WebSocketHandler("Map")`），与每帧 `SimulationWorld` 解耦——地图只在自车移动到新区域、`MapElementIds` 哈希变化时增量推送（`diffMapElements`）。这是 AuroraDrive 应借鉴的"**地图静态 + 状态动态**"分层推送模型。

---

## 3. 前端车道线渲染（Three.js 实现）

### 3.1 渲染组件结构

经典版 Dreamview 前端是原生 React + Three.js（非 R3F），渲染逻辑在 `modules/dreamview/frontend/src/renderer/`（[GitHub](https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview/frontend/src/renderer)）：
- `map.js`（28KB）：地图元素渲染入口，含车道线绘制（[GitHub](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/map.js)）。
- `trajectory.js`：规划轨迹渲染（[GitHub](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/trajectory.js)）。
- `utils/draw.js`：**Three.js 画线原子库**（[GitHub](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/utils/draw.js)）。

`map.js` 顶部的颜色映射表是消费级 SR 与工程可视化的分水岭：

```js
// map.js
const colorMapping = {
  YELLOW:     0XDAA520,  // 金黄（非纯黄 0xFFFF00）
  WHITE:      0xCCCCCC,  // 浅灰（非纯白 0xFFFFFF）
  CORAL:      0xFF7F50,
  RED:        0xFF6666,
  GREEN:      0x006400,
  BLUE:       0x30A5FF,
  PURE_WHITE: 0xFFFFFF,
  DEFAULT:    0xC0C0C0,
};
```

Apollo 选 0xDAA520/0xCCCCCC 是为了在深色背景下降低饱和度、减少视觉疲劳，这与小鹏/特斯拉消费级 SR 的高饱和配色刻意不同。

### 3.2 utils/draw.js：三条核心画线函数

这是本次研究最关键的源码（[GitHub](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/utils/draw.js)），直接决定了 AuroraDrive 的修复方案：

```js
// 实线（连续折线）—— 注意是 THREE.Line，不是 LineSegments！
export function drawSegmentsFromPoints(
  points, color = 0xff0000, linewidth = 1, zOffset = 0,
  matrixAutoUpdate = true, transparent = false, opacity = 1,
) {
  const path = new THREE.Path();
  const geometry = path.createGeometry(points);
  const material = new THREE.LineBasicMaterial({
    color, linewidth, transparent, opacity,
  });
  const pathLine = new THREE.Line(geometry, material);   // 连续折线
  addOffsetZ(pathLine, zOffset);
  pathLine.matrixAutoUpdate = matrixAutoUpdate;
  if (matrixAutoUpdate === false) pathLine.updateMatrix();
  return pathLine;
}

// 虚线 —— 必须先 computeLineDistances()，否则虚线不显示
export function drawDashedLineFromPoints(
  points, color = 0xff0000, linewidth = 1, dashSize = 4, gapSize = 2,
  zOffset = 0, opacity = 1, matrixAutoUpdate = true,
) {
  const path = new THREE.Path();
  const geometry = path.createGeometry(points);
  geometry.computeLineDistances();                        // 关键！
  const material = new THREE.LineDashedMaterial({
    color, dashSize, linewidth, gapSize, transparent: true, opacity,
  });
  const mesh = new THREE.Line(geometry, material);
  addOffsetZ(mesh, zOffset);
  mesh.matrixAutoUpdate = matrixAutoUpdate;
  if (!matrixAutoUpdate) mesh.updateMatrix();
  return mesh;
}

// 粗带状线（规划轨迹用）—— three-line-2d 库生成三角带 Mesh
import ThreeLine2D from 'three-line-2d';
import ThreeLine2DBasicShader from 'three-line-2d/shaders/basic';
const Line = ThreeLine2D(THREE);
const BasicShader = ThreeLine2DBasicShader(THREE);

export function drawThickBandFromPoints(
  points, thickness = 0.5, color = 0xffffff, opacity = 1, zOffset = 0,
) {
  const geometry = Line(points.map((p) => [p.x, p.y]));
  const material = new THREE.ShaderMaterial(BasicShader({
    side: THREE.DoubleSide, diffuse: color, thickness, opacity, transparent: true,
  }));
  const mesh = new THREE.Mesh(geometry, material);       // 是 Mesh，不是 Line
  addOffsetZ(mesh, zOffset);
  return mesh;
}

// Z 层级偏移，避免 z-fighting（每单位 0.04）
const DELTA_Z_OFFSET = 0.04;
export function addOffsetZ(mesh, value) {
  if (value) mesh.position.z += value * DELTA_Z_OFFSET;
}
```

关键结论：
1. **车道实线 = `THREE.Line` + `LineBasicMaterial`**：`THREE.Path().createGeometry(points)` 生成连续折线几何体，`THREE.Line` 把所有点连成一条连续路径。`LineBasicMaterial.linewidth` 在 WebGL 下被绝大多数平台忽略，**实际渲染为 1px**——Apollo 接受这一点（车道线就是细线）。
2. **车道虚线 = `THREE.Line` + `LineDashedMaterial`**：必须调用 `geometry.computeLineDistances()`，否则虚线显示为实线。`dashSize`/`gapSize` 控制虚实周期。
3. **轨迹粗带 = `three-line-2d` 三角带 Mesh**：当需要真正可控的"线宽"时，Apollo 不用 `LineBasicMaterial`，而是用 `three-line-2d` 把折线展开为带厚度的三角网格 Mesh。这正是 Three.js 官方 `Line2`/`LineMaterial` 的同思路替代方案。
4. **Z 层级**用 `DELTA_Z_OFFSET=0.04` 的整数倍偏移避免不同图层（地面/车道线/轨迹/障碍物）之间的 z-fighting。

### 3.3 Line vs LineSegments（AuroraDrive Bug 的根因）

Three.js 三种线对象（[深入理解 Three.js 线条](https://www.cnblogs.com/gaozhiqiang/)）：
- `THREE.Line`：把 `position` 数组中的点**依次首尾相连**成一条连续折线（N 个点 → N-1 段，共享顶点）。**车道线必须用它。**
- `THREE.LineSegments`：把 `position` 数组**两两配对**成独立线段（第 0-1 点一段、第 2-3 点一段…），段与段之间**不连接**。适合画障碍物包围盒的 12 条边。
- `THREE.LineLoop`：同 `Line` 但首尾闭合。

AuroraDrive `RoadNetwork.tsx` 的 `appendLine` 每相邻两点压入一对顶点，再交给 `<lineSegments>` 渲染——结果就是一条本该连续的道路被切成 N-1 段独立短线，在视角变化或抗锯齿不足时表现为"崎岖断续"。这是对象类型选错的典型 bug。

### 3.4 现代方案：Line2 / LineMaterial（推荐 AuroraDrive 采用）

Apollo 经典版用 `LineBasicMaterial`（1px）+ `three-line-2d`（粗带）是 Three.js 旧版本的妥协。现代 Three.js（r125+）官方提供 `Line2` + `LineMaterial`（`three/examples/jsm/lines/`），可同时支持**真线宽 + 虚线**，是 AuroraDrive 的首选（[PHP: LineMaterial 分辨率设置](https://m.php.cn/faq/1571936.html)、[CSDN: Line2 绘制](https://blog.csdn.net/weixin_55041114/article/details/132364067)）：

```js
import { Line2 } from 'three/examples/jsm/lines/Line2.js';
import { LineMaterial } from 'three/examples/jsm/lines/LineMaterial.js';
import { LineGeometry } from 'three/examples/jsm/lines/LineGeometry.js';

const mat = new LineMaterial({
  color: 0xFFFF00,
  linewidth: 3,           // 像素单位，真线宽（LineBasicMaterial 做不到）
  dashed: true,           // 虚线开关
  dashSize: 1,            // 虚线周期（worldUnits=true 时为世界单位米）
  gapSize: 1,
  dashScale: 1,
  worldUnits: true,       // 推荐：dashSize 按米计，与地图尺度一致
  transparent: true,
  opacity: 0.9,
  alphaToCoverage: true,
});
// 必须设置 resolution，否则线宽计算错误（线会消失或变细）
mat.resolution.set(window.innerWidth, window.innerHeight);
window.addEventListener('resize', () =>
  mat.resolution.set(window.innerWidth, window.innerHeight));

const geo = new LineGeometry();
geo.setPositions([x0,y0,z0, x1,y1,z1, ...]);  // 扁平 [x,y,z,x,y,z,...]
const line = new Line2(geo, mat);
line.computeLineDistances();   // 虚线必须
scene.add(line);
```

`LineMaterial` 关键属性：`linewidth`（像素，若 `worldUnits=false`）、`dashed/dashSize/gapSize/dashScale/worldUnits`、`resolution`（**必须随窗口 resize 更新**）、`alphaToCoverage`（MSAA 抗锯齿）。`Line2` 底层是三角带 Mesh，与 Apollo 的 `three-line-2d` 同思路，但是官方维护、兼容性更好。

### 3.5 虚线周期与线条平滑

- **虚线周期**：Apollo `drawDashedLineFromPoints` 默认 `dashSize=4, gapSize=2`（世界单位），`trajectory.js` 中虚线轨迹用 `dashSize=1, gapSize=1`。中国国标车道虚线通常"实 4m 空 6m"或"实 2m 空 4m"，AuroraDrive 应按真实交规设置 `dashSize/gapSize` 并开 `worldUnits:true`。
- **线条平滑**：Apollo **不做样条平滑**，直接连线（地图点已足够密）。若点过稀出现折角，可用 `THREE.CatmullRomCurve3` 过控制点生成三次样条再 `getPoints(n)` 重采样（[掘金: CatmullRomCurve3](https://juejin.cn/post/7597722671084601378)）：
  ```js
  const curve = new THREE.CatmullRomCurve3(points.map(p => new THREE.Vector3(p.x, 0, p.z)));
  curve.curveType = 'centripetal';   // 避免自交
  const smooth = curve.getPoints(200);
  ```
  注意：Catmull-Rom 会"穿过"所有控制点，适合车道线；但会改变端点位置，需手动钳制首尾。

---

## 4. 车道线在 SR 界面的视觉呈现

### 4.1 俯视图与 3D 贴地

Dreamview 支持 perspective / top-down 两种相机。车道线点来自 UTM 平面坐标（x/y），z 通常是海拔。渲染时：
- **3D 视图**：直接用 PointENU 的 (x, y, z)，车道线随地形起伏。但为避免与地面 z-fighting，用 `addOffsetZ(mesh, zOffset)` 抬高一个小量。
- **俯视图**：相机正下方俯视，y 轴朝前、x 轴朝右，车道线投影到 xz 平面（Apollo 前端坐标系常把地图 y 映射为 Three.js z）。
- AuroraDrive 现状把 y 强制设为 `0.02`（`positions.push(x1-origin[0], 0.02, z1-origin[1])`），即"贴地"渲染——这是简化做法，适合纯平面 SR，但会丢失坡道信息。

### 4.2 远端淡出与前方裁剪

- **远端淡出**：Apollo 经典 Dreamview **不做透明度渐变**，靠 200m ROI 自然截断（超出半径的 Lane 根本不下发）。消费级 SR（小鹏/特斯拉）则用着色器按距离衰减 alpha 实现远端淡出。AuroraDrive 若要消费级观感，需在 `LineMaterial` 上用 `vertexColors` + 按距离设顶点 alpha。
- **前方 N 米裁剪**：Apollo ROI 是以自车为圆心的圆，不区分前后。消费级 SR 通常只渲染前方扇区。AuroraDrive 可在 ROI 基础上按自车朝向裁剪前方 180°。
- **与参考线（Reference Line）区别**：`Lane.central_curve` 是车道中心线（参考线），Dreamview 用更暗的颜色或虚线绘制；车道边界（left/right boundary）才是"车道线"。AuroraDrive 当前只画了 `center_points`（中心线），把边界留空——本末倒置。

---

## 5. 路径规划轨迹的车道线渲染

### 5.1 ADCTrajectory 与轨迹渲染

Planning 模块输出 `ADCTrajectory`（含 `trajectory_point` 序列，每点有 x/y/z/v/a/θ）。前端 `trajectory.js` 把它渲染为**与车同宽的彩色带状物**（[GitHub](https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/trajectory.js)）：

```js
// 轨迹宽度 = 自车车宽
let width = world.autoDrivingCar.width;
// ...
if (property.style === 'dash') {
  this.paths[name] = drawDashedLineFromPoints(points, property.color,
    width * property.width, 1, 1, property.zOffset, property.opacity);
} else {
  this.paths[name] = drawThickBandFromPoints(points, width * property.width,
    property.color, property.opacity, property.zOffset);
}
```

要点：
- **轨迹用 `drawThickBandFromPoints`（三角带 Mesh）**，宽度取自 `autoDrivingCar.width`，视觉上是一条与车同宽的"光带"，远比细线醒目。
- 轨迹点先经 `normalizePlanningTrajectory` 过滤：跳过无法转到本地坐标的点、跳过与上一点 L1 距离小于 `PARAMETERS.planning.minInterval` 的点（降密度）。
- `PARAMETERS.planning.pathProperties[name]` 按轨迹名（如 `trajectory` / `path_0` / `st_boundary`）配不同 color/style/width/opacity/zOffset。

### 5.2 视觉层级与变道交互

- **层级**：轨迹（zOffset 较大，盖在最上）> 车道线 > 地面。Apollo 通过 `zOffset` 整数倍 × 0.04 控制，确保轨迹永远在车道线之上。
- **速度编码**：经典 Dreamview 轨迹单色；消费级 SR 常按速度上色（低速绿/高速蓝/减速红），用 `vertexColors` 实现。
- **变道**：轨迹会跨越车道线，Apollo 不做特殊"穿越"渲染，仅如实画轨迹带；变道决策由 `LANE_CHANGE_DECIDER` 产生，可在前端叠加变道箭头。AuroraDrive 可在变道时给目标车道线高亮（如 CORAL 色）增强提示。

---

## 6. AuroraDrive 当前问题对照与修复

### 6.1 现状（已核实源码）

- **后端** `cpp/include/ad/simulator.h:1553`（已确认）：
  ```cpp
  // left/right boundary 空数组（简化）
  jb.raw(R"(],"left_boundary":[],"right_boundary":[],"name":)");
  ```
  即后端只下发 `center_points`，左右边界恒为空数组——**车道线无数据来源**。
- **前端** `frontend/src/components/three/RoadNetwork.tsx`（已确认）：
  ```tsx
  function appendLine(pts, origin, color, positions, colors) {
    for (let i = 0; i < pts.length - 1; i++) {
      positions.push(x1-org[0], 0.02, z1-org[1]);   // 段起点
      positions.push(x2-org[0], 0.02, z2-org[1]);   // 段终点
      colors.push(...); colors.push(...);
    }
  }
  return (
    <lineSegments geometry={geometry}>
      <lineBasicMaterial vertexColors transparent opacity={0.7} />
    </lineSegments>
  );
  ```
  两点一pair 喂给 `<lineSegments>` → 道路被切成断续独立段；且 `lineBasicMaterial` 无 `linewidth`，永远 1px。

### 6.2 可直接复用的修复代码（React + Three.js / R3F）

**Step 1：后端补边界点序列**（`simulator.h` 仿照 Apollo，从地图 lane 取 left/right boundary 点序列下发，结构与 `center_points` 一致）。

**Step 2：前端用 Line2 + LineMaterial 重写 `RoadNetwork.tsx`**：

```tsx
// frontend/src/components/three/LaneBoundaries.tsx
import { useMemo, useRef, useEffect } from "react";
import * as THREE from "three";
import { Line2 } from "three/examples/jsm/lines/Line2.js";
import { LineMaterial } from "three/examples/jsm/lines/LineMaterial.js";
import { LineGeometry } from "three/examples/jsm/lines/LineGeometry.js";
import { useSimStore } from "@/store/useSimStore";

// 仿 Apollo colorMapping（消费级可改高饱和）
const BOUNDARY_STYLE: Record<string, { color: number; dashed: boolean }> = {
  SOLID_WHITE:   { color: 0xFFFFFF, dashed: false },
  SOLID_YELLOW:  { color: 0xFFFF00, dashed: false },
  DOTTED_WHITE:  { color: 0xFFFFFF, dashed: true  },
  DOTTED_YELLOW: { color: 0xFFFF00, dashed: true  },
  DOUBLE_YELLOW: { color: 0xFFFF00, dashed: false }, // 法向偏移再画一条
  CURB:          { color: 0xFF8800, dashed: false },
  UNKNOWN:       { color: 0xCCCCCC, dashed: false },
};

function buildLine(points: [number, number, number][], origin: [number, number]) {
  const flat: number[] = [];
  for (const [x, , z] of points) flat.push(x - origin[0], 0.05, z - origin[1]); // 贴地+微小抬高
  const geo = new LineGeometry();
  geo.setPositions(flat);
  return geo;
}

export default function LaneBoundaries() {
  const roads = useSimStore((s) => s.roads);
  const egoOrigin = useSimStore((s) => s.egoOrigin);
  const matRef = useRef<LineMaterial | null>(null);

  // 按 boundary 类型分组（这里假设 road 带 left_boundary_type/right_boundary_type）
  const segments = useMemo(() => {
    if (!egoOrigin) return [];
    const groups: { type: keyof typeof BOUNDARY_STYLE; pts: number[] }[] = [];
    const push = (pts, type) => {
      if (!pts?.length) return;
      const flat: number[] = [];
      for (const [x, , z] of pts)
        flat.push(x - egoOrigin[0], 0.05, z - egoOrigin[1]); // y=0 贴地平面投影
      groups.push({ type, pts: flat });
    };
    for (const road of roads.values()) {
      push(road.left_boundary,  road.left_boundary_type  ?? "SOLID_WHITE");
      push(road.right_boundary, road.right_boundary_type ?? "SOLID_WHITE");
    }
    return groups;
  }, [roads, egoOrigin]);

  // resolution 必须随窗口更新
  useEffect(() => {
    const onResize = () => matRef.current?.resolution.set(innerWidth, innerHeight);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  if (!segments.length) return null;
  return (
    <group>
      {segments.map((seg, i) => {
        const style = BOUNDARY_STYLE[seg.type] ?? BOUNDARY_STYLE.UNKNOWN;
        const geo = useMemo(() => {
          const g = new LineGeometry(); g.setPositions(seg.pts); return g;
        }, [seg.pts]);
        const mat = useMemo(() => {
          const m = new LineMaterial({
            color: style.color,
            linewidth: 2.5,                  // 真线宽（像素）
            dashed: style.dashed,
            dashSize: 2, gapSize: 2,         // worldUnits=false 时为像素
            transparent: true, opacity: 0.9,
            alphaToCoverage: true,
          });
          m.resolution.set(innerWidth, innerHeight);
          return m;
        }, [style]);
        const line = new Line2(geo, mat);
        line.computeLineDistances();        // 虚线必需
        return <primitive key={i} object={line} />;
      })}
    </group>
  );
}
```

> 注：R3F 中 `Line2`/`LineMaterial` 也可用 `@react-three/drei` 的 `<Line>` 组件（内部就是 Line2），更简洁。上面用 `primitive` 包裹原生对象是为了显式展示 Apollo 的修复要点。

**Step 3：中心线（参考线）单独画**，用更暗的颜色（如 `0x3a4a6a`）和更细线宽，避免与边界混淆。

### 6.3 修复清单

| 问题 | 根因 | 修复 |
|---|---|---|
| 道路崎岖断续 | `<lineSegments>` 把连续点切成独立段 | 实线改 `<line>`/`Line2`；虚线改 `Line2`+`dashed` |
| 边界为空 | `simulator.h` 写死空数组 | 仿 `RetrieveMapElements` 从地图取 boundary 点序列下发 |
| 线宽 1px | `LineBasicMaterial.linewidth` 被忽略 | 用 `LineMaterial`（真线宽） |
| 虚线不显示 | 未调 `computeLineDistances()` | `Line2`/`Line` 都要调 |
| 无类型区分 | 前端无 boundary_type 字段 | 后端按 `LaneBoundaryType` 下发，前端按类型选色/虚实 |
| 远端无淡出 | 直接全透明度 | 按距离设顶点 alpha 或随距离衰减 opacity |

---

## 7. 与小鹏 / 理想 / 特斯拉的对比

| 维度 | Apollo Dreamview | 小鹏 XNGP / MONA | 理想 AD Max | 特斯拉 FSD |
|---|---|---|---|---|
| 数据来源 | HD Map 静态边界（sim_map） | 无图，感知实时车道线 | 地图+感知叠加（[新出行](https://m.xchuxing.com/ins/415366)：理想 SR 叠加地图信息，可渲染被遮挡车道） | 纯视觉感知（Occupancy + Lane） |
| 颜色编码 | 0xDAA520 金黄 / 0xCCCCCC 浅灰（工程配色） | 高饱和：白线亮白、黄线亮黄 | 高饱和，蓝/青色基调为主 | 早期蓝/青色车道线，v12+ 多彩 |
| 虚线呈现 | `LineDashedMaterial`，dashSize/gapSize 世界单位 | 按真实交规虚实比，远端虚线缩短 | 透视收缩，远端虚线密度递减 | 透视收缩，符合相机透视 |
| 远端淡出 | 无渐变，靠 200m ROI 硬截断 | 距离 alpha 衰减 + 透视收缩 | 距离衰减 + 雾化 | 距离衰减 + 雾化 |
| 线宽 | 1px（LineBasicMaterial） | 粗带，有立体感 | 粗带，发光 | 粗带，发光 |
| 3D 透视 | 弱（工程俯视为主） | 强（[MONA M03 3D 渲染地图大世界氛围](https://m.toutiao.com/group/7424821857758495273/)） | 强（SR 拟真） | 强（FSD v14 全新 3D 视觉架构） |
| 被遮挡渲染 | 不支持（静态地图无遮挡概念） | 不支持（纯感知） | **支持**（地图车道+宽度补全被遮挡车道） | 不支持（纯感知） |

关键差异结论：
- **Apollo = 工程调试工具**：配色低饱和、线细、无淡出，目标是"看清每个点"，不是"好看"。
- **小鹏/理想/特斯拉 = 消费级 SR**：高饱和、粗带、远端淡出+透视收缩，目标是"沉浸感"。
- 理想"被遮挡车道渲染"是独特能力——靠地图车道几何+车道宽度推算被前车遮挡的车道线，与 Apollo 纯地图渲染异曲同工但更智能。AuroraDrive 若定位消费级，应向小鹏/理想靠拢；若定位工程调试，沿用 Apollo 配色即可。

---

## 8. 给 AuroraDrive 的迁移建议

1. **后端**：在 `simulator.h` 的 `map_init_json` 中，仿 Apollo `RetrieveMapElements`，为每条 road 填充 `left_boundary`/`right_boundary` 点序列（与 `center_points` 同构），并新增 `left_boundary_type`/`right_boundary_type` 字段（值为 `SOLID_WHITE`/`DOTTED_YELLOW` 等枚举字符串）。ROI 半径可复用现有 `roads_in_radius`，参考 Apollo 取 200m。
2. **前端**：拆分 `RoadNetwork.tsx` 为 `LaneBoundaries`（边界，Line2+LineMaterial）+ `CenterLines`（参考线，细 Line2）。实线/虚线/双黄线/路缘按类型分流。
3. **线宽**：车道线 `linewidth=2~3`（像素），轨迹用 `drawThickBandFromPoints` 同思路的三角带或 `Line2` 配 `worldUnits:true` + 车宽。
4. **虚线**：开 `worldUnits:true`，`dashSize=4, gapSize=6`（贴近国标），务必 `computeLineDistances()`。
5. **层级**：地面 z=0 → 车道线 y=0.05 → 参考线 y=0.04 → 轨迹 y=0.1，避免 z-fighting。
6. **远端淡出**（可选）：用 `LineMaterial.vertexColors` + 按距离设顶点颜色 alpha。
7. **增量更新**：借鉴 Apollo `diffMapElements`，地图按 id 哈希增量推送，不要每帧全量。

---

## 9. 源码链接索引

- Apollo 仓库根：<https://github.com/ApolloAuto/apollo>
- map 模块：<https://github.com/ApolloAuto/apollo/tree/master/modules/map>
- dreamview 后端：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview/backend>
- SimulationWorldService：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/simulation_world/simulation_world_service.cc>
- MapService：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/map_service/map_service.cc>
- dreamview gflags：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/dreamview_gflags.cc>
- dreamview 前端 renderer：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview/frontend/src/renderer>
- map.js（车道线渲染）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/map.js>
- trajectory.js（轨迹渲染）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/trajectory.js>
- utils/draw.js（画线原子库）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/utils/draw.js>
- perception_camera.proto（CameraLaneLine）：<https://github.com/ApolloAuto/apollo/blob/master/modules/common_msgs/perception_msgs/perception_camera.proto>
- perception_lane.proto（PerceptionLanes）：<https://github.com/ApolloAuto/apollo/blob/master/modules/common_msgs/perception_msgs/perception_lane.proto>
- map_lane / map_geometry proto 解析：<https://blog.csdn.net/qq_37346140/article/details/129569738>
- sim_map_generator 解析：<https://blog.csdn.net/tinamao______/article/details/146801954>
- Three.js Line2/LineMaterial：<https://threejs.org/docs/#examples/en/lines/Line2>
- Line vs LineSegments：<https://www.cnblogs.com/gaozhiqiang/p/13926264.html>
- CatmullRomCurve3：<https://juejin.cn/post/7597722671084601378>

---

> 本报告共调用内部工具约 68 次（WebSearch 21 次 + WebFetch 27 次 + 本地 Read/Glob/LS/TodoWrite/Write/RunCommand 20 次），覆盖 Apollo 后端 proto/MapService/SimulationWorldService、前端 map.js/trajectory.js/utils/draw.js、Three.js Line2/LineMaterial 文档、AuroraDrive 本地源码、以及小鹏/理想/特斯拉 SR 对比。
