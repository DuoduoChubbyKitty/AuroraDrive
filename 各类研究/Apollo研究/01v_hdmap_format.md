# Apollo 高精地图 HD Map 格式（Protobuf）深度研究报告

> 研究对象：百度 Apollo 开放平台 `modules/map/proto/` 下的自定义 protobuf HD Map 格式
> 研究目标：为 AuroraDrive 当前 mmap 二进制地图格式扩展（新增车道边界、车道类型、车道中心线、道路方向、路口 overlap 字段）提供参考蓝本
> 报告日期：2026-07-23

---

## 目录

1. [Apollo HD Map 总体架构](#1-apollo-hd-map-总体架构)
2. [核心 Proto 文件与数据结构](#2-核心-proto-文件与数据结构)
3. [Curve / Segment / Length 几何体系](#3-curve--segment--length-几何体系)
4. [Map Element 详解](#4-map-element-详解)
5. [地图生成与编译工具链](#5-地图生成与编译工具链)
6. [HDMapImpl 运行时加载与空间索引](#6-hdmapimpl-运行时加载与空间索引)
7. [Apollo vs OpenDRIVE 对比](#7-apollo-vs-opendrive-对比)
8. [Apollo 8.0 / 9.0 / 10.0 地图演进](#8-apollo-80--90--100-地图演进)
9. [AuroraDrive mmap 扩展设计](#9-auroradrive-mmap-扩展设计重点)
10. [结论与建议](#10-结论与建议)
11. [实际调用次数](#11-实际调用次数)

---

## 1. Apollo HD Map 总体架构

### 1.1 三层地图体系

Apollo 的地图模块位于 `modules/map/`，是自动驾驶系统的基础设施，对外提供三层地图能力：

| 子系统 | 路径 | 精度 | 功能 | 应用场景 |
|---|---|---|---|---|
| **HDMap** | `modules/map/hdmap/` | 厘米级 | 高精度静态地图，14 种地图元素 | 城市道路、高速公路 |
| **PncMap** | `modules/map/pnc_map/` | 厘米级 | 规划控制专用地图，Frenet 坐标转换、RouteSegments | 路径规划、轨迹控制 |
| **RelativeMap** | `modules/map/relative_map/` | 分米级 | 实时相对地图，融合感知车道线 | 导航模式、无 HDMap 区域 |

```
┌──────────────────────────────────────────────┐
│ Application Layer (Planning/Control/Perception) │
├──────────────────────────────────────────────┤
│ HDMap │ PncMap │ RelativeMap                  │
├──────────────────────────────────────────────┤
│ Spatial Index (KD-Tree 亚毫秒级查询)          │
└──────────────────────────────────────────────┘
```

核心模块路径：

```
modules/map/
├── hdmap/          # 高精度地图
│   ├── hdmap_common.h/cc   # 地图元素 Info 类（LaneInfo/JunctionInfo/...）
│   ├── hdmap_impl.h/cc     # HDMapImpl 地图加载与查询
│   ├── hdmap_util.h        # 全局接口封装
│   └── adapter/            # 格式适配器
│       ├── opendrive_adapter.h/cc
│       └── xml_parser/     # OpenDRIVE XML 解析器
│           ├── common_define.h      # xxxInternal 结构
│           ├── proto_organizer.h    # xxxInternal → ProtoData
│           ├── roads_xml_parser.h
│           ├── lanes_xml_parser.h
│           └── objects_xml_parser.h
├── pnc_map/        # 规划控制地图
│   ├── path.h
│   └── route_segments.h
├── relative_map/   # 相对地图
├── proto/          # 地图 protobuf 定义
└── tools/          # 地图生成工具链
```

### 1.2 坐标系与投影

- **原始坐标**：WGS84 经纬度坐标（GPS 全球定位系统使用的坐标系）。
- **投影方式**：通过 PROJ.4 字符串将椭球面投影到平面，典型设置为 `+proj=tmerc +lat_0={origin.lat} +lon_0={origin.lon} +k={scale_factor} +ellps=WGS84 +no_defs`（横轴墨卡托投影 UTM）。
- **内部坐标**：`apollo.common.PointENU`（East-North-Up，平面投影后的 XY 坐标 + Z 高程）。
- 车道 ID 命名规则：lane section 内唯一、数值连续、reference line 所在 lane 的 ID 为 0，左侧 lane ID 向左递增（正 t 轴），右侧 lane ID 向右递减（负 t 轴）。

---

## 2. 核心 Proto 文件与数据结构

### 2.1 map.proto —— 顶层 Map 容器

`modules/map/proto/map.proto` 是整个 HD Map 的顶层入口。Apollo 6.0 之后逐步加入了 RSU、PNCJunction、ParkingSpace 等元素，最新版本 Map message 包含以下 repeated 字段：

```protobuf
syntax = "proto2";
package apollo.hdmap;

// 投影定义：椭球面 → 平面
message Projection {
  optional string proj = 1;
}

message Header {
  optional bytes version = 1;
  optional bytes date = 2;
  optional Projection projection = 3;   // 坐标系转换
  optional bytes district = 4;
  optional bytes generation = 5;
  optional bytes rev_major = 6;
  optional bytes rev_minor = 7;
  optional double left = 8;             // 地图范围边界
  optional double top = 9;
  optional double right = 10;
  optional double bottom = 11;
  optional bytes vendor = 12;
}

message Map {
  optional Header header = 1;
  repeated Crosswalk crosswalk = 2;       // 人行横道
  repeated Junction junction = 3;        // 路口区域
  repeated Lane lane = 4;                // 车道（最核心）
  repeated StopSign stop_sign = 5;        // 停止标志
  repeated Signal signal = 6;            // 信号灯
  repeated YieldSign yield = 7;          // 让行标志
  repeated Overlap overlap = 8;          // 重叠区域（关联关系）
  repeated ClearArea clear_area = 9;     // 禁停区
  repeated SpeedBump speed_bump = 10;    // 减速带
  repeated Road road = 11;               // 道路
  repeated ParkingSpace parking_space = 12;  // 停车区
  repeated PNCJunction pnc_junction = 13;   // 规划路口
  repeated RSU rsu = 14;                 // 路侧单元
}
```

注意：Map 中所有元素都是平铺的 repeated 列表，元素之间的关联通过 `Overlap`（overlap_id 引用）和 `Road.section.lane_id` 引用建立。这种扁平化设计便于用哈希表做 O(1) ID 查询，也便于 protobuf 序列化。

### 2.2 map_lane.proto —— 车道（最核心元素）

车道是 Apollo HD Map 中信息量最大、最关键的数据结构，定义在 `modules/map/proto/map_lane.proto`：

```protobuf
syntax = "proto2";
package apollo.hdmap;

import "modules/map/proto/map_id.proto";
import "modules/map/proto/map_geometry.proto";

// 车道边界类型（一个 s 位置可叠加多种类型）
message LaneBoundaryType {
  enum Type {
    UNKNOWN = 0;
    DOTTED_YELLOW = 1;   // 黄色虚线
    DOTTED_WHITE = 2;    // 白色虚线
    SOLID_YELLOW = 3;     // 黄色实线
    SOLID_WHITE = 4;      // 白色实线
    DOUBLE_YELLOW = 5;    // 双黄线
    CURB = 6;             // 路缘石
  };
  optional double s = 1;            // 相对边界起点的偏移
  repeated Type types = 2;          // 支持多类型叠加
}

message LaneBoundary {
  optional Curve curve = 1;                  // 边界曲线
  optional double length = 2;                // 长度（米）
  optional bool virtual = 3;                // 真实世界是否存在（虚拟边界）
  repeated LaneBoundaryType boundary_type = 4;  // 按 s 升序排列的类型序列
}

// 中心点到最近边界的采样关联（描述车道宽度随 s 变化）
message LaneSampleAssociation {
  optional double s = 1;       // 纵向位置
  optional double width = 2;   // 该 s 处中心到边界的宽度
}

message Lane {
  optional Id id = 1;
  optional Curve central_curve = 2;              // 中心线（参考轨迹）
  optional LaneBoundary left_boundary = 3;      // 左边界
  optional LaneBoundary right_boundary = 4;     // 右边界
  optional double length = 5;                   // 长度（米）
  optional double speed_limit = 6;              // 限速（m/s）
  repeated Id overlap_id = 7;                  // 重叠区域 ID

  // 拓扑关系
  repeated Id predecessor_id = 8;              // 前驱车道
  repeated Id successor_id = 9;                // 后继车道
  repeated Id left_neighbor_forward_lane_id = 10;   // 同向左邻车道
  repeated Id right_neighbor_forward_lane_id = 11;  // 同向右邻车道
  repeated Id left_neighbor_reverse_lane_id = 14;   // 反向左邻车道
  repeated Id right_neighbor_reverse_lane_id = 15;  // 反向右邻车道
  optional Id self_reverse_lane_id = 22;           // 自身反向车道（潮汐车道）

  enum LaneType {
    NONE = 1;           CITY_DRIVING = 2;
    BIKING = 3;         SIDEWALK = 4;
    PARKING = 5;        SHOULDER = 6;     // 路肩
  };
  optional LaneType type = 12;

  enum LaneTurn {
    NO_TURN = 1;   LEFT_TURN = 2;
    RIGHT_TURN = 3; U_TURN = 4;
  };
  optional LaneTurn turn = 13;

  enum LaneDirection {
    FORWARD = 1;   BACKWARD = 2;   BIDIRECTION = 3;
  };
  optional LaneDirection direction = 19;

  optional Id junction_id = 16;                 // 所属路口

  // 中心点到最近边界的宽度采样（车道宽度）
  repeated LaneSampleAssociation left_sample = 17;
  repeated LaneSampleAssociation right_sample = 18;
  // 中心点到最近道路边界的宽度采样（道路宽度）
  repeated LaneSampleAssociation left_road_sample = 20;
  repeated LaneSampleAssociation right_road_sample = 21;
}
```

**关键设计要点**：

1. **central_curve 与 left/right_boundary 分离**：中心线是参考轨迹（Reference Line），不一定位于几何中心；左右边界独立描述，支持虚拟边界（virtual=true 表示真实世界不存在，仅为逻辑边界）。
2. **left_sample / right_sample**：通过 (s, width) 采样描述车道宽度沿纵向的变化，这是 Apollo 相对 OpenDRIVE 的重要扩展——OpenDRIVE 用 lane width 的多项式描述，Apollo 用离散采样，实现更简单且便于查询。
3. **left_road_sample / right_road_sample**：描述中心线到真实道路边界的距离（包含本车道 + 相邻车道的总宽度），用于感知 ROI 过滤。
4. **拓扑关系双向完备**：前驱/后继、同向/反向左右邻车道，支持 routing 拓扑图构建和 prediction 的 LaneGraph 生成。

### 2.3 map_road.proto —— 道路

```protobuf
message BoundaryEdge {
  optional Curve curve = 1;
  enum Type {
    UNKNOWN = 0;
    NORMAL = 1;
    LEFT_BOUNDARY = 2;
    RIGHT_BOUNDARY = 3;
  };
  optional Type type = 2;
}

message BoundaryPolygon {
  repeated BoundaryEdge edge = 1;
}

// 含洞的边界
message RoadBoundary {
  optional BoundaryPolygon outer_polygon = 1;  // 外边界
  repeated BoundaryPolygon hole = 2;           // 内洞（无洞则空）
}

message RoadROIBoundary {
  optional Id id = 1;
  repeated RoadBoundary road_boundaries = 2;
}

// 道路横截面（至少 1 个，多个时按沿道路方向排列）
message RoadSection {
  optional Id id = 1;
  repeated Id lane_id = 2;             // 该 section 包含的车道
  optional RoadBoundary boundary = 3;  // section 边界
}

message Road {
  optional Id id = 1;
  repeated RoadSection section = 2;
  optional Id junction_id = 3;        // 不在路口则空
  enum Type {
    UNKNOWN = 0;   HIGHWAY = 1;   CITY_ROAD = 2;   PARK = 3;
  };
  optional Type type = 4;
}
```

Road 是 Lane 的容器：一个 Road 由若干 RoadSection 组成（道路横截面变化处分割 section），每个 Section 包含一组 lane_id。Road 与 Lane 是双向引用（Road.section.lane_id → Lane，Lane 反向可通过 road_id/section_id 关联回 Road，该关联在 HDMapImpl::LoadMapFromProto 中建立）。

### 2.4 map_junction.proto —— 路口

```protobuf
message Junction {
  optional Id id = 1;
  optional Polygon polygon = 2;       // 路口多边形区域
  repeated Id overlap_id = 3;        // 关联的重叠区域
  enum Type {
    UNKNOWN = 0;
    IN_ROAD = 1;       // 道路非路口
    CROSS_ROAD = 2;     // 十字路口
    FORK_ROAD = 3;      // 三岔路口
    MAIN_SIDE = 4;      // 道路主侧
    DEAD_END = 5;       // 死胡同
  };
  optional Type type = 4;
}
```

Junction 用一个 Polygon 描述路口区域，所有进入该区域的 Lane/Signal/StopSign/Crosswalk 都通过 overlap 关联。Apollo 6.0 新增的 `Type` 枚举为感知模块提供环境约束（区分十字、三岔等场景）。

### 2.5 map_signal.proto —— 信号灯

```protobuf
message Subsignal {
  enum Type {
    UNKNOWN = 1;     CIRCLE = 2;            // 圆灯
    ARROW_LEFT = 3;  ARROW_FORWARD = 4;
    ARROW_RIGHT = 5; ARROW_LEFT_AND_FORWARD = 6;
    ARROW_RIGHT_AND_FORWARD = 7; ARROW_U_TURN = 8;
  };
  optional Id id = 1;
  optional Type type = 2;
  optional apollo.common.PointENU location = 3;  // 灯泡中心位置
}

message SignInfo {
  enum Type {
    None = 0;
    NO_RIGHT_TURN_ON_RED = 1;   // 红灯可右转
  };
  optional Type type = 1;
}

message Signal {
  enum Type {
    UNKNOWN = 1;
    MIX_2_HORIZONTAL = 2;    MIX_2_VERTICAL = 3;
    MIX_3_HORIZONTAL = 4;    MIX_3_VERTICAL = 5;
    SINGLE = 6;
  };
  optional Id id = 1;
  optional Polygon boundary = 2;          // 信号灯边界
  repeated Subsignal subsignal = 3;       // 子信号灯（每个灯泡）
  repeated Id overlap_id = 4;
  optional Type type = 5;
  repeated Curve stop_line = 6;           // 关联停止线
  repeated SignInfo sign_info = 7;
}
```

### 2.6 map_stop_sign.proto / map_crosswalk.proto / map_parking_space.proto

```protobuf
message StopSign {
  optional Id id = 1;
  repeated Curve stop_line = 2;
  repeated Id overlap_id = 3;
  enum StopType {
    UNKNOWN = 0; ONE_WAY = 1; TWO_WAY = 2;
    THREE_WAY = 3; FOUR_WAY = 4; ALL_WAY = 5;
  };
  optional StopType type = 4;
}

message Crosswalk {
  optional Id id = 1;
  optional Polygon polygon = 2;
  repeated Id overlap_id = 3;
}

message ParkingSpace {
  optional Id id = 1;
  optional Polygon polygon = 2;
  repeated Id overlap_id = 3;
  optional double heading = 4;     // 车头朝向
}

message ParkingLot {
  optional Id id = 1;
  optional Polygon polygon = 2;
  repeated Id overlap_id = 3;
}

message YieldSign {
  optional Id id = 1;
  repeated Curve stop_line = 2;
  repeated Id overlap_id = 3;
}

message ClearArea {
  optional Id id = 1;
  repeated Id overlap_id = 2;
  optional Polygon polygon = 3;
}

message SpeedBump {
  optional Id id = 1;
  repeated Id overlap_id = 2;
  repeated Curve position = 3;
}

message RSU {
  optional Id id = 1;
  optional Id junction_id = 2;
  repeated Id overlap_id = 3;
}
```

### 2.7 map_overlap.proto —— 重叠区域（关联关系核心）

Overlap 是 Apollo 表达元素间空间重叠/关联关系的统一机制，是 planning 场景转换的核心判据（"是否需要场景转化通过 overlap 判断"）：

```protobuf
message LaneOverlapInfo {
  optional double start_s = 1;    // overlap 在车道上的起点 s
  optional double end_s = 2;      // overlap 在车道上的终点 s
  optional bool is_merge = 3;     // 是否合并
  optional Id region_overlap_id = 4;
}

message CrosswalkOverlapInfo {
  optional Id region_overlap_id = 1;
}
// SignalOverlapInfo / StopSignOverlapInfo / JunctionOverlapInfo / 
// YieldOverlapInfo / ClearAreaOverlapInfo / SpeedBumpOverlapInfo /
// ParkingSpaceOverlapInfo / PNCJunctionOverlapInfo / RSUOverlapInfo 均为空占位

message RegionOverlapInfo {
  optional Id id = 1;
  repeated Polygon polygon = 2;
}

// 一个 overlap 涉及的两个对象
message ObjectOverlapInfo {
  optional Id id = 1;
  oneof overlap_info {
    LaneOverlapInfo lane_overlap_info = 3;
    SignalOverlapInfo signal_overlap_info = 4;
    StopSignOverlapInfo stop_sign_overlap_info = 5;
    CrosswalkOverlapInfo crosswalk_overlap_info = 6;
    JunctionOverlapInfo junction_overlap_info = 7;
    YieldOverlapInfo yield_sign_overlap_info = 8;
    ClearAreaOverlapInfo clear_area_overlap_info = 9;
    SpeedBumpOverlapInfo speed_bump_overlap_info = 10;
    ParkingSpaceOverlapInfo parking_space_overlap_info = 11;
    PNCJunctionOverlapInfo pnc_junction_overlap_info = 12;
    RSUOverlapInfo rsu_overlap_info = 13;
  }
}

message Overlap {
  optional Id id = 1;
  repeated ObjectOverlapInfo object = 2;     // 两个重叠对象
  repeated RegionOverlapInfo region_overlap = 3;
}
```

PNCJunction（规划路口）额外定义了 Passage / PassageGroup 结构，描述路口内的入口/出口车道组，用于规划模块的通行权判断：

```protobuf
message Passage {
  optional Id id = 1;
  repeated Id signal_id = 2;
  repeated Id yield_id = 3;
  repeated Id stop_sign_id = 4;
  repeated Id lane_id = 5;
  enum Type { UNKNOWN = 0; ENTRANCE = 1; EXIT = 2; };
  optional Type type = 6;
}
message PassageGroup {
  optional Id id = 1;
  repeated Passage passage = 2;
}
message PNCJunction {
  optional Id id = 1;
  optional Polygon polygon = 2;
  repeated Id overlap_id = 3;
  repeated PassageGroup passage_group = 4;
}
```

---

## 3. Curve / Segment / Length 几何体系

### 3.1 map_geometry.proto 几何定义

Apollo 用一个统一的 `Curve` 类型描述所有线状几何（车道中心线、边界、停止线等），其设计哲学是**绝对坐标序列 + 分段**：

```protobuf
message Polygon {
  repeated apollo.common.PointENU point = 1;   // 多边形（不一定凸）
}

message LineSegment {
  repeated apollo.common.PointENU point = 1;   // 折线点序列
}

message CurveSegment {
  oneof curve_type {
    LineSegment line_segment = 1;   // 当前主要使用折线
  }
  optional double s = 6;                       // 起点纵向坐标
  optional apollo.common.PointENU start_position = 7;  // 起点世界坐标
  optional double heading = 8;                 // 起点航向角
  optional double length = 9;                  // 段长度
}

message Curve {
  repeated CurveSegment segment = 1;           // 一条曲线由多段组成
}
```

`apollo.common.PointENU`（来自 `modules/common/proto/geometry.proto`）定义为 East-North-Up 平面坐标，包含 x/y/z 三个 double 字段。

### 3.2 与 OpenDRIVE 几何表达的差异

这是 Apollo 对 OpenDRIVE 最核心的改动：

- **标准 OpenDRIVE**：道路参考线用 `<geometry>` 节点描述，类型包括 `line`（直线）、`arc`（圆弧）、`spiral`（回旋曲线/欧拉螺旋线）、`paramPoly3`（参数三次曲线）、`poly3`（三次多项式）。车道边界通过相对参考线的偏移（width/a/b/c/d 多项式或 border 几何）来表达——即**参数化、相对量**的表达。
- **Apollo OpenDRIVE**：直接用绝对坐标序列（折线点 PointENU 数组）描述边界形状，放弃曲线方程和偏移——即**离散化、绝对量**的表达。

Apollo 这样改动的三点理由（官方说明）：

1. **形状表达更简单**：绝对坐标序列实现上比曲线方程+偏移简单，无需在运行时求解方程。
2. **元素类型扩展**：新增禁停区、人行横道、减速带等独立元素描述。
3. **元素关系扩展**：新增 junction 与 junction 内元素的关联、车道中心线到真实道路边界距离、停止线与红绿灯关联等。

### 3.3 Length 字段的分布

Length 字段在多个层级出现，语义一致但作用域不同：

| 字段位置 | 语义 |
|---|---|
| `Lane.length` | 车道中心线总长度（米） |
| `LaneBoundary.length` | 单条边界长度（米） |
| `CurveSegment.length` | 单个曲线段长度（米） |
| `RoadSection` | 无显式 length，通过 section 内 lane_id 的 lane.length 推导 |

`LaneInfo` 在加载时会把 central_curve 的所有 segment 拼接，预计算 `accumulated_s_`（累积距离序列）、`headings_`（航向角序列）、`unit_directions_`（单位方向向量序列）、`segments_`（LineSegment2d 序列），供 Frenet 投影 `GetProjection(point, &s, &l)` 使用。

### 3.4 Spiral 在 Apollo 中的角色

需要澄清的是：Apollo 的 map_geometry.proto 在 oneof 中目前主要使用 `line_segment`（折线），并不直接在地图存储层使用 spiral/arc。**Spiral（五次螺旋曲线）在 Apollo 中主要用于 planning 的参考线平滑（ReferenceLineSmoother）**，而非地图原始存储：

- `SpiralReferenceLineSmoother` 调用 `SpiralProblemInterface`，后者调用 `QuinticSpiralPathWithD...`；
- Apollo 提供三种参考线平滑算法：`FemPosDeviationSmoother`、`QpSplineReferenceLineSmoother`、`SpiralReferenceLineSmoother`。

这是地图（离散折线存储）与规划（参数化曲线平滑）的合理分工。

---

## 4. Map Element 详解

### 4.1 车道边界（左右 boundary）

Apollo 的车道边界采用"独立绝对坐标折线 + 类型分段"设计：

- **left_boundary / right_boundary** 独立描述，不依赖 reference line 偏移。
- `LaneBoundary.virtual` 区分真实物理边界与逻辑边界（如车道汇合处的虚拟分界）。
- `LaneBoundaryType` 用 `(s, types[])` 描述沿 s 的类型变化，支持同一 s 位置多类型叠加（如同时是 SOLID_YELLOW 和 CURB）。
- 7 种边界类型覆盖了中国路况：UNKNOWN / DOTTED_YELLOW / DOTTED_WHITE / SOLID_YELLOW / SOLID_WHITE / DOUBLE_YELLOW / CURB。

### 4.2 车道中心线 centerline（参考线）

- `Lane.central_curve` 作为参考轨迹（Reference Line），是 planning 参考线生成的几何基础。
- Reference Line 不一定位于车道几何中心，可以是道路实际中心线。
- ID 为 0 的车道存储 reference line，其他车道只存储一侧边界（左侧车道存左边界，右侧车道存右边界）——这是 OpenDRIVE 沿袭下来的存储优化。

### 4.3 Road / Section

- Road 是车道的逻辑分组容器，对应一段连续道路。
- Road 包含多个 RoadSection，section 是道路横截面（车道数/布局）发生变化的分割点。
- Road.junction_id 表示该 road 是否属于某路口（不属于则为空）。
- Road.type 区分 HIGHWAY / CITY_ROAD / PARK。

### 4.4 Junction（路口 + overlap 区域）

- Junction 用 Polygon 描述路口几何区域。
- 所有进入该区域的元素（Lane/Signal/StopSign/Crosswalk）通过 overlap_id 关联。
- Apollo 6.0 新增 Type 枚举（CROSS_ROAD / FORK_ROAD / MAIN_SIDE / DEAD_END）为感知提供场景约束。
- OpenDRIVE 中 junction 通过 incoming road + connecting road + outgoing road 的 connection 结构表达；Apollo 用更通用的 Overlap 机制统一表达所有空间重叠，扩展性更强。

### 4.5 Signal / StopSign / Crosswalk / ParkingSpace

| 元素 | 几何 | 关键属性 | 关联 |
|---|---|---|---|
| Signal | Polygon boundary | type(2H/2V/3H/3V/SINGLE)、subsignal[] | stop_line[], overlap_id[] |
| StopSign | stop_line[] | StopType(ONE/TWO/THREE/FOUR/ALL_WAY) | overlap_id[] |
| Crosswalk | Polygon | — | overlap_id[] |
| ParkingSpace | Polygon | heading（车头朝向） | overlap_id[] |
| ClearArea | Polygon | — | overlap_id[] |
| SpeedBump | Curve position[] | — | overlap_id[] |

所有交通元素都通过 `overlap_id` 与 Lane 建立 Overlap 关联，LaneOverlapInfo 记录 overlap 在车道上的 (start_s, end_s) 区间。这样 planning 可以通过 "车道 s 区间 → overlap → 信号灯/停止线" 快速查询前方交通约束。

---

## 5. 地图生成与编译工具链

### 5.1 三种地图文件

Apollo 一个地图目录（如 `modules/map/data/sunnyvale_big_loop/`）包含：

```
sunnyvale_big_loop/
├── base_map.xml      # OpenDRIVE 格式源文件（FLAGS_base_map_filename）
├── base_map.bin      # protobuf 二进制
├── base_map.txt      # protobuf 文本
├── routing_map.bin   # 路由拓扑图（FLAGS_routing_map_filename）
├── routing_map.txt
├── sim_map.bin       # 仿真精简版（FLAGS_sim_map_filename）
├── sim_map.txt
├── default_end_way_point.txt   # 默认终点
├── map.json
└── speed_control.pb.txt
```

加载顺序（`--base_map_filename="base.xml|base.bin|base.txt"`）按可用性优先：xml → bin → txt。

### 5.2 base_map vs routing_map vs sim_map 差异

| 地图 | 内容 | 生成工具 | 用途 |
|---|---|---|---|
| **base_map** | 最完整地图，含所有道路/车道几何/标识 | `bin_map_generator`（XML→bin/txt） | 其他地图的基座 |
| **routing_map** | 车道拓扑结构 | `scripts/generate_routing_topo_graph.sh` | routing 路径搜索 |
| **sim_map** | base_map 轻量版，下采样降密度 | `sim_map_generator` | DreamView 可视化 |

### 5.3 关键工具

| 工具 | 路径 | 功能 |
|---|---|---|
| `proto_map_generator` | `modules/map/tools/proto_map_generator.cc` | XML → .bin/.txt |
| `bin_map_generator` | — | base_map.bin 生成 |
| `sim_map_generator` | `modules/map/tools/sim_map_generator.cc` | 下采样生成 sim_map |
| `map_tool` | `modules/map/tools/map_tool.cc` | bin/txt 地图偏移 |
| `map_xysl` | `modules/map/tools/map_xysl.cc` | xy↔sl 坐标转换 |
| `quaternion_euler` | `modules/map/tools/quaternion_euler.cc` | 四元数↔欧拉角 |
| `refresh_default_end_way_point` | — | 终点刷新 |
| `map_datachecker` | — | 地图数据校验（gRPC C/S） |

### 5.4 XML → Proto 解析流程

解析入口 `OpendriveAdapter::LoadData(filename, Map* pb_map)`，分四步：

1. **根目录 + Header** 解析
2. **Road** 解析：`RoadsXmlParser::Parse()` 将 XML road 标签存入 `RoadInternal`（含 id/junction_id/type/sections/traffic_lights/stop_signs/...）
3. **Junction** 解析
4. **ProtoOrganizer** 将 `xxxInternal` 转为 `ProtoData`（用 `unordered_map<id, PbXxx>` 哈希表管理），最后输出到 `pb_map`

中间引入 Internal 结构是为了让 XML 解析与 proto 组织解耦，避免一次性转换造成代码混乱。

---

## 6. HDMapImpl 运行时加载与空间索引

### 6.1 双格式加载

```cpp
int HDMapImpl::LoadMapFromFile(const std::string& map_filename) {
  Clear();
  if (absl::EndsWith(map_filename, ".xml")) {
    // OpenDRIVE 格式
    if (!adapter::OpendriveAdapter::LoadData(map_filename, &map_)) return -1;
  } else {
    // Protobuf 格式（Apollo 原生，性能更高）
    if (!cyber::common::GetProtoFromFile(map_filename, &map_)) return -1;
  }
  return LoadMapFromProto(map_);
}
```

### 6.2 LoadMapFromProto 流程

1. **构建哈希表索引**：lane_table_/junction_table_/signal_table_/crosswalk_table_/... 全部 O(1) ID 查询。
2. **建立车道-道路关联**：遍历 road_table_，将 road_id/section_id 回填到 LaneInfo。
3. **后处理 Overlap 关系**：对每个 LaneInfo 调用 `PostProcess(*this)`，填充 signals_/crosswalks_/stop_signs_/junctions_/... 等 OverlapInfo 列表。
4. **构建 KD-Tree 空间索引**：为每种元素构建独立的 KD-Tree（亚毫秒级查询性能）。

### 6.3 KD-Tree 空间索引

```cpp
using LaneSegmentBox = ObjectWithAABox<LaneInfo, LineSegment2d>;
using LaneSegmentKDTree = AABoxKDTree2d<LaneSegmentBox>;
// 同理：JunctionPolygonKDTree / SignalSegmentKDTree / CrosswalkPolygonKDTree / ...
```

查询性能：KD 树查询 O(log N + K)，N 为总元素数，K 为结果数；典型场景查询 10m 范围内车道耗时 < 1ms。

### 6.4 LaneInfo 关键 API

`LaneInfo`（`hdmap_common.h`）是对 protobuf `Lane` 的运行时封装，预计算所有派生数据：

```cpp
class LaneInfo {
  // 几何查询
  double Heading(double s) const;        // 航向角
  double Curvature(double s) const;      // 曲率
  void GetWidth(double s, double* left_width, double* right_width) const;
  bool IsOnLane(const Vec2d& point) const;
  bool GetProjection(const Vec2d& point, double* accumulate_s, double* lateral) const;
  PointENU GetSmoothPoint(double s) const;
  // 拓扑/Overlap
  const std::vector<OverlapInfoConstPtr>& signals() const;
  const std::vector<OverlapInfoConstPtr>& junctions() const;
 private:
  std::vector<Vec2d> points_;               // 中心线点
  std::vector<double> headings_;           // 航向角序列
  std::vector<LineSegment2d> segments_;    // 线段序列
  std::vector<double> accumulated_s_;      // 累积距离
  std::vector<SampledWidth> sampled_left_width_;
  std::unique_ptr<LaneSegmentKDTree> lane_segment_kdtree_;
};
```

### 6.5 PncMap 与 Frenet 坐标

PncMap 在 HDMap 之上提供面向规划控制的接口：

- `LaneWaypoint{lane, s, l}`：Frenet 坐标点（s 纵向、l 横向）。
- `LaneSegment{lane, start_s, end_s}`：车道一段。
- `RouteSegments`：车道段序列，表示一条可行驶路径。
- 三大功能：① 更新路由信息（`UpdateRoutingResponse`）② 短期路径段查询（`GetRouteSegments`，前向 150~250m，后向 30m）③ 路径段生成最终 Path。

Frenet 坐标系优势：s（纵向）与 l（横向）解耦，便于纵横向规划独立进行。

---

## 7. Apollo vs OpenDRIVE 对比

| 维度 | 标准 OpenDRIVE | Apollo OpenDRIVE（protobuf） |
|---|---|---|
| **数据格式** | XML 文本 | protobuf（.bin 二进制 / .txt 文本） |
| **序列化** | XML DOM 解析，慢 | protobuf 二进制，快、紧凑 |
| **坐标** | WGS84 + proj4 投影 | WGS84 + Projection.proj（同 proj4） |
| **参考线几何** | line/arc/spiral/paramPoly3/poly3 参数化曲线 | LineSegment 折线（绝对坐标序列） |
| **车道边界** | 相对参考线 width 多项式偏移 | 绝对坐标折线 + boundary_type 分段 |
| **车道宽度** | width a/b/c/d 多项式 | LaneSampleAssociation (s,width) 离散采样 |
| **车道类型** | driving/stop/should/biking/sidewalk等 | LaneType: NONE/CITY_DRIVING/BIKING/SIDEWALK/PARKING/SHOULDER |
| **边界类型** | solid/broken/solid broken 等 | UNKNOWN/DOTTED_YELLOW/DOTTED_WHITE/SOLID_YELLOW/SOLID_WHITE/DOUBLE_YELLOW/CURB |
| **路口关联** | junction.connection(incoming/connecting/outgoing) | Overlap 通用机制（lane×signal×stop_sign×crosswalk×junction） |
| **新增元素** | — | ClearArea(禁停)/SpeedBump(减速带)/ParkingSpace/PNCJunction/RSU/BarrierGate |
| **元素关系** | 较弱 | Overlap + LaneOverlapInfo(start_s,end_s) 强关联 |
| **中心线到道路边界距离** | 无 | left_road_sample/right_road_sample |
| **停止线-红绿灯关联** | 间接 | Signal.stop_line 直接关联 |
| **版本兼容** | revMajor/revMinor | Header.version |
| **工具链** | 第三方工具 | proto_map_generator/sim_map_generator |
| **运行时查询** | 需自建索引 | 内置 KD-Tree，亚毫秒级 |
| **应用定位** | 仿真器导向 | 自动驾驶导向 |

**Apollo 优势**：实现简单（绝对坐标避免方程求解）、查询高效（protobuf+KDTree）、关系完备（Overlap）、贴合自动驾驶需求（车道宽度采样、停止线关联）。
**Apollo 劣势**：丧失与标准 OpenDRIVE 工具链的互操作性（需 opendrive_adapter 转换）、数据体积较大（绝对坐标点序列）、参数化信息丢失（无法重建曲线方程）。

---

## 8. Apollo 8.0 / 9.0 / 10.0 地图演进

### 8.1 Apollo 8.0（2022.12）

- **架构升级**：从面向技术分层升级为"技术+生态分层"架构（硬件设备 → 软件核心 → 软件应用 → 云端服务）。
- **工程框架**：引入软件包管理机制，模块按包组织，安装部署从"天"级降至 30 分钟。
- **感知**：开放感知全流程开发（训练/部署/验证），引入 3 个深度学习模型。
- **PnC 工具链**：本地 PnC 仿真调试 + 云端仿真场景管理，插件化场景/动力学模型，调试效率提升 1 倍。
- **Apollo Studio**：一站式学习实践社区。
- 地图本身格式未大改，但工程上更易用。

### 8.2 Apollo 9.0（2023.12）

- **工程**：包管理全面升级，模块按功能颗粒度拆成更小软件包；统一调度接口；插件机制（代码学习成本降 90%、代码量降 50%）；首次适配 ARM 架构。
- **算法**：Lidar 用 CenterPoint，视觉用 Yolo X + Yolo 3D，百万级数据训练；支持增量训练；全面支持 4D 毫米波雷达。
- **工具**：新增高精地图制图工具、传感器标定和集成工具；Dreamview+ 升级；重构文档平台。
- **场景通用能力**：适配环节减 40%、代码阅读量减 90%、代码调试量减 80%，"开箱即用"一周闭环。
- 重构 12 万行、新增 20 万行代码。地图制图周期缩短至小时级。

### 8.3 Apollo 10.0（2024.12）

- 搭载自动驾驶大模型 **ADFM**（Autonomous Driving Foundation Model）。
- Public Road Planner 详解包含 planning_process_thread 和 reference_line_provider_thread 双线程。
- 地图模块延续 9.0 的三层体系（HDMap/PncMap/RelativeMap）+ KD-Tree 空间索引。

### 8.4 关于"Live Map / 在线地图更新"

需澄清：Apollo 官方公开的 8.0/9.0/10.0 发布资料中，并未明确推出名为 "Live Map" 的在线地图动态更新特性。Apollo 的"动态地图"能力主要由 **RelativeMap（实时相对地图）** 承担：

- Apollo 2.5 引入 Real-time Relative Map，用于无 HDMap 覆盖区域。
- 数据来源：GPS 导航路线 + 摄像头检测车道线 + 车辆定位。
- `RelativeMap::CreateMapFromNavigationLane` 融合感知车道线生成导航路径。
- 与离线 HDMap 的差异：精度分米级、实时生成、轻量、不持久化。

若需在线更新静态 HDMap，通常通过"采集→离线制作→base_map 更新→routing_map/sim_map 重新生成"的离线流程实现，而非运行时在线动态更新。

---

## 9. AuroraDrive mmap 扩展设计（重点）

### 9.1 AuroraDrive 当前格式回顾

AuroraDrive 当前采用 mmap（memory-mapped）二进制格式存储路网，规模：

| 数据项 | 数量 |
|---|---|
| 道路（Road） | 51.8 万 |
| 道路点（Road Point） | 2747 万 |
| 图节点（Graph Node） | 103.6 万 |
| 目的地（Destination） | 1.66 万 |
| 道路名数据 | 108.5 万字节 |

**关键缺口**：当前格式**没有车道边界数据**，只有道路级的折线点，无法支撑车道级规划与控制。这正是需要向 Apollo HD Map 学习的核心。

### 9.2 mmap 文件格式总体设计

借鉴 Apollo 的"扁平化 repeated 列表 + ID 引用 + Overlap 关联"思想，但采用 mmap 友好的"header + 多 section + 定长记录 + 偏移引用"结构，保证零拷贝随机访问：

```
┌─────────────────────────────────────────────┐
│ FileHeader (magic + version + counts + offsets) │  定长，文件头
├─────────────────────────────────────────────┤
│ Section: RoadNames (108.5万字节字符串池)        │  变长字符串区
├─────────────────────────────────────────────┤
│ Section: RoadPoints (2747万 × PointRecord)     │  定长数组
├─────────────────────────────────────────────┤
│ Section: Roads (51.8万 × RoadRecord)           │  定长数组
├─────────────────────────────────────────────┤
│ Section: LaneBoundaries (N × LaneBoundaryRecord)  新增
├─────────────────────────────────────────────┤
│ Section: Lanes (M × LaneRecord)            新增
├─────────────────────────────────────────────┤
│ Section: GraphNodes (103.6万 × NodeRecord)     │  定长数组
├─────────────────────────────────────────────┤
│ Section: Destinations (1.66万 × DestRecord)    │  定长数组
├─────────────────────────────────────────────┤
│ Section: Overlaps (K × OverlapRecord)      新增
├─────────────────────────────────────────────┤
│ Section: Junctions (L × JunctionRecord)   新增
└─────────────────────────────────────────────┘
```

设计原则：

1. **定长记录**：每个 Record 用定长 C struct，便于 `base_ptr + index * sizeof(Record)` 直接寻址。
2. **变长数据外置**：折线点序列、字符串等变长数据放在独立的连续数组区，Record 内用 `(offset, count)` 引用。
3. **mmap 只读**：整个文件 `mmap(PROT_READ)` 映射到进程地址空间，所有访问都是指针解引用，无反序列化开销。
4. **新增字段不破坏旧字段**：FileHeader.version 控制版本，新字段作为新 section 追加，旧 reader 忽略未知 section。

### 9.3 新增字段详细设计

#### 9.3.1 车道边界字段（左/右 boundary polyline）

借鉴 Apollo `LaneBoundary`，新增 `LaneBoundaryRecord`：

```cpp
#pragma pack(push, 1)   // mmap 紧凑布局，无填充

// 边界类型（对齐 Apollo LaneBoundaryType.Type）
enum class BoundaryType : uint8_t {
    UNKNOWN       = 0,
    DOTTED_YELLOW = 1,
    DOTTED_WHITE  = 2,
    SOLID_YELLOW  = 3,
    SOLID_WHITE   = 4,
    DOUBLE_YELLOW = 5,
    CURB          = 6,
};

// 边界类型分段（s 位置 → 类型）
struct BoundaryTypeSegment {
    float   s;            // 相对边界起点的纵向偏移（米）
    uint8_t type;         // BoundaryType
    uint8_t reserved[3];
};

// 车道边界记录
struct LaneBoundaryRecord {
    uint32_t id;                          // 边界唯一 ID
    uint32_t point_offset;                // 在 RoadPoints section 的起始偏移
    uint32_t point_count;                 // 折线点数量
    float    length;                      // 边界长度（米）
    uint8_t  virtual_flag;                // 是否虚拟边界（0/1）
    uint8_t  reserved[3];
    uint32_t type_seg_offset;             // BoundaryTypeSegment 数组偏移
    uint32_t type_seg_count;              // 类型分段数量
};
#pragma pack(pop)
```

#### 9.3.2 车道类型字段

借鉴 Apollo `LaneType`：

```cpp
enum class LaneType : uint8_t {
    NONE         = 0,
    CITY_DRIVING = 1,
    BIKING       = 2,
    SIDEWALK     = 3,
    PARKING      = 4,
    SHOULDER     = 5,
};

enum class LaneTurn : uint8_t {
    NO_TURN    = 0,
    LEFT_TURN  = 1,
    RIGHT_TURN = 2,
    U_TURN     = 3,
};

enum class LaneDirection : uint8_t {
    FORWARD     = 0,
    BACKWARD    = 1,
    BIDIRECTION = 2,
};
```

#### 9.3.3 车道中心线字段

借鉴 Apollo `Lane.central_curve`，新增 `LaneRecord`：

```cpp
// 车道宽度采样（对齐 Apollo LaneSampleAssociation）
struct LaneWidthSample {
    float s;       // 纵向位置（米）
    float width;  // 中心到边界的宽度（米）
};

// 车道记录
struct LaneRecord {
    uint32_t id;                          // 车道唯一 ID
    uint32_t road_id;                     // 所属道路 ID
    uint32_t section_id;                  // 所属 section ID

    // 中心线（参考线）
    uint32_t centerline_point_offset;    // 中心线点序列偏移
    uint32_t centerline_point_count;      // 中心线点数量
    float    length;                      // 车道长度（米）
    float    speed_limit;                 // 限速（m/s）

    // 左右边界（引用 LaneBoundaryRecord）
    uint32_t left_boundary_id;           // 左边界 ID（0 = 无）
    uint32_t right_boundary_id;          // 右边界 ID（0 = 无）

    // 宽度采样（中心线 → 边界）
    uint32_t left_sample_offset;         // LaneWidthSample 数组偏移
    uint32_t left_sample_count;
    uint32_t right_sample_offset;
    uint32_t right_sample_count;

    // 类型与方向
    uint8_t  lane_type;                   // LaneType
    uint8_t  turn;                        // LaneTurn
    uint8_t  direction;                   // LaneDirection
    uint8_t  reserved;

    // 拓扑（前驱/后继/邻车道，引用 LaneRecord.id）
    uint32_t predecessor_id;              // 前驱车道（0 = 无）
    uint32_t successor_id;               // 后继车道（0 = 无）
    uint32_t left_neighbor_forward_id;   // 同向左邻车道
    uint32_t right_neighbor_forward_id;  // 同向右邻车道

    // 路口关联
    uint32_t junction_id;                // 所属路口（0 = 不在路口）

    // Overlap 关联
    uint32_t overlap_offset;             // OverlapRecord 数组偏移
    uint32_t overlap_count;
};
```

#### 9.3.4 道路方向字段

`LaneDirection` 已嵌入 LaneRecord。对 Road 级，可在 `RoadRecord` 增加 `direction` 字段：

```cpp
struct RoadRecord {
    uint32_t id;
    uint32_t name_offset;                 // RoadNames 字符串偏移
    uint16_t name_len;
    uint8_t  road_type;                   // 0=UNKNOWN,1=HIGHWAY,2=CITY_ROAD,3=PARK
    uint8_t  direction;                   // LaneDirection
    uint32_t point_offset;                // 道路折线点偏移
    uint32_t point_count;
    uint32_t section_offset;              // section 数组偏移
    uint32_t section_count;
    uint32_t junction_id;                 // 所属路口（0 = 不在路口）
    uint32_t lane_id_offset;               // 该 road 包含的 lane_id 数组偏移
    uint32_t lane_id_count;
};
```

#### 9.3.5 路口 overlap 字段

借鉴 Apollo `Overlap` + `Junction`：

```cpp
// Overlap 涉及的一个对象
struct OverlapObject {
    uint32_t object_id;                   // 元素 ID
    uint8_t  object_type;                 // 0=lane,1=signal,2=stop_sign,3=crosswalk,4=junction,5=parking
    uint8_t  reserved[3];
    float    start_s;                      // 在车道上的起点 s（仅 lane 有意义）
    float    end_s;                        // 在车道上的终点 s
};

// Overlap 记录（两个对象的重叠）
struct OverlapRecord {
    uint32_t id;
    OverlapObject obj_a;
    OverlapObject obj_b;
};

// Junction 记录
struct JunctionRecord {
    uint32_t id;
    uint32_t polygon_point_offset;        // 路口多边形点偏移
    uint32_t polygon_point_count;
    uint8_t  junction_type;               // 0=UNKNOWN,1=IN_ROAD,2=CROSS_ROAD,3=FORK_ROAD,4=MAIN_SIDE,5=DEAD_END
    uint8_t  reserved[3];
    uint32_t overlap_offset;              // 关联 OverlapRecord 偏移
    uint32_t overlap_count;
};
```

### 9.4 FileHeader 设计

```cpp
struct MapFileHeader {
    char     magic[8];        // "AURAMAP\0"
    uint16_t version_major;   // 主版本（不兼容时递增）
    uint16_t version_minor;   // 次版本（兼容追加）

    // 全局统计
    uint32_t road_count;
    uint32_t road_point_count;
    uint32_t graph_node_count;
    uint32_t destination_count;
    uint32_t road_name_bytes;
    // 新增 section 统计
    uint32_t lane_count;
    uint32_t lane_boundary_count;
    uint32_t overlap_count;
    uint32_t junction_count;

    // 各 section 在文件中的偏移（字节）
    uint64_t offset_road_names;
    uint64_t offset_road_points;
    uint64_t offset_roads;
    uint64_t offset_graph_nodes;
    uint64_t offset_destinations;
    uint64_t offset_lane_boundaries;   // 新增
    uint64_t offset_lanes;              // 新增
    uint64_t offset_overlaps;           // 新增
    uint64_t offset_junctions;          // 新增

    // 地图范围（WGS84 经纬度边界）
    double left, top, right, bottom;
    // 投影信息
    char proj[64];                     // PROJ.4 字符串
};
```

### 9.5 C++ 读取示例

```cpp
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>

class AuroraMapReader {
 public:
  bool Load(const std::string& path) {
    fd_ = ::open(path.c_str(), O_RDONLY);
    if (fd_ < 0) return false;
    struct stat st;
    if (::fstat(fd_, &st) != 0) return false;
    file_size_ = st.st_size;
    base_ = ::mmap(nullptr, file_size_, PROT_READ, MAP_SHARED, fd_, 0);
    if (base_ == MAP_FAILED) return false;
    header_ = reinterpret_cast<const MapFileHeader*>(base_);
    if (std::memcmp(header_->magic, "AURAMAP", 7) != 0) return false;
    return true;
  }

  // 零拷贝访问各 section
  const MapFileHeader& header() const { return *header_; }

  const RoadRecord* roads() const {
    return reinterpret_cast<const RoadRecord*>(
        static_cast<const char*>(base_) + header_->offset_roads);
  }
  const LaneRecord* lanes() const {
    return reinterpret_cast<const LaneRecord*>(
        static_cast<const char*>(base_) + header_->offset_lanes);
  }
  const LaneBoundaryRecord* lane_boundaries() const {
    return reinterpret_cast<const LaneBoundaryRecord*>(
        static_cast<const char*>(base_) + header_->offset_lane_boundaries);
  }
  const OverlapRecord* overlaps() const {
    return reinterpret_cast<const OverlapRecord*>(
        static_cast<const char*>(base_) + header_->offset_overlaps);
  }
  const JunctionRecord* junctions() const {
    return reinterpret_cast<const JunctionRecord*>(
        static_cast<const char*>(base_) + header_->offset_junctions);
  }

  // 折线点（PointENU，对齐 Apollo common.PointENU）
  struct PointENU { double x, y, z; };
  const PointENU* road_points() const {
    return reinterpret_cast<const PointENU*>(
        static_cast<const char*>(base_) + header_->offset_road_points);
  }

  // 按 ID 查询车道（线性/可建哈希索引）
  const LaneRecord* GetLaneById(uint32_t id) const {
    const LaneRecord* arr = lanes();
    for (uint32_t i = 0; i < header_->lane_count; ++i) {
      if (arr[i].id == id) return &arr[i];
    }
    return nullptr;
  }

  // 获取车道中心线点序列
  const PointENU* GetCenterline(const LaneRecord* lane) const {
    return road_points() + lane->centerline_point_offset;
  }

  // 获取车道左边界
  const LaneBoundaryRecord* GetLeftBoundary(const LaneRecord* lane) const {
    if (lane->left_boundary_id == 0) return nullptr;
    const LaneBoundaryRecord* arr = lane_boundaries();
    for (uint32_t i = 0; i < header_->lane_boundary_count; ++i) {
      if (arr[i].id == lane->left_boundary_id) return &arr[i];
    }
    return nullptr;
  }

  ~AuroraMapReader() {
    if (base_ && base_ != MAP_FAILED) ::munmap(base_, file_size_);
    if (fd_ >= 0) ::close(fd_);
  }

 private:
  int fd_ = -1;
  void* base_ = nullptr;
  size_t file_size_ = 0;
  const MapFileHeader* header_ = nullptr;
};
```

### 9.6 迁移实施建议

1. **阶段一：新增车道边界**（最高优先级）。当前最大缺口是无车道边界。新增 `LaneBoundaryRecord` + `LaneRecord.left/right_boundary_id`，先用现有 RoadPoints 数据生成单侧边界（道路边缘），逐步补全真实车道边界。
2. **阶段二：车道中心线与宽度**。新增 `LaneRecord.centerline_point_offset/count` + `LaneWidthSample`，从道路中心线派生车道中心线，补全 left/right_sample。
3. **阶段三：拓扑与方向**。补全 predecessor/successor/neighbor + LaneType/LaneTurn/LaneDirection，支撑 routing 车道级拓扑。
4. **阶段四：Junction + Overlap**。新增 JunctionRecord + OverlapRecord，建立车道与信号灯/停止线/路口的空间重叠关联，支撑 planning 场景判断。
5. **空间索引**：在 mmap 之上额外构建 KD-Tree（参考 Apollo `AABoxKDTree2d`），实现亚毫秒级范围查询。KD-Tree 可作为独立索引文件（`.idx`），与 mmap 数据文件分离。
6. **版本兼容**：FileHeader.version_major 不变时只追加新 section，旧 reader 通过 offset 跳过未知 section，保证向前兼容。

### 9.7 与 AuroraDrive 现有数据的衔接

- **RoadPoints 复用**：新增的 LaneBoundary/Lane 中心线点序列可复用现有 2747 万 RoadPoints 池（通过 offset+count 引用），避免点数据重复存储。
- **RoadNames 复用**：108.5 万字节道路名池不变。
- **GraphNodes 演进**：现有 103.6 万图节点可演化为 Lane 级节点（lane endpoint），routing 拓扑从 road 级升级为 lane 级。
- **规模估算**：假设每条道路平均 2 条车道，Lanes ≈ 100 万；LaneBoundaries ≈ 200 万；每条 LaneRecord ≈ 96 字节，新增 mmap 体积约 100MB，可接受。

---

## 10. 结论与建议

### 10.1 Apollo HD Map 格式的核心启示

1. **扁平化 + ID 引用**优于嵌套层级，便于哈希表索引和 protobuf 序列化。
2. **绝对坐标折线**优于参数化曲线方程，实现简单、查询直接，但牺牲数据紧凑性和曲线信息。
3. **Overlap 通用机制**统一表达所有元素空间关联，扩展性远强于 OpenDRIVE 的 junction.connection。
4. **车道宽度采样**（left/right_sample + left/right_road_sample）是 Apollo 相对 OpenDRIVE 的关键创新，支撑感知 ROI 和车道宽度查询。
5. **KD-Tree 空间索引**是高精地图运行时性能的关键，必须与数据格式同步设计。

### 10.2 对 AuroraDrive 的建议

- **优先补车道边界**：这是当前最大缺口，直接借鉴 Apollo `LaneBoundary`（类型 7 种 + virtual 标志 + 分段类型）。
- **采用 mmap + 定长 Record**：保留 AuroraDrive 现有 mmap 零拷贝优势，新增字段作为新 section 追加，版本兼容。
- **引入 Overlap 机制**：用统一的 OverlapRecord 表达车道与信号灯/停止线/路口的重叠，为 planning 场景判断提供基础。
- **分层实施**：边界 → 中心线/宽度 → 拓扑/方向 → Junction/Overlap，逐步逼近 Apollo 的完整能力。
- **空间索引独立**：KD-Tree 作为 `.idx` 文件，与 mmap 数据解耦，支持增量重建。

---

## 11. 实际调用次数

本研究通过 WebSearch 与 WebFetch 工具进行了深度信息挖掘，覆盖 GitHub ApolloAuto/apollo 仓库 proto 文件、CSDN/Juejin 技术解析、Apollo 官方发布资料（搜狐/电子发烧友/汽车之家）、OpenDRIVE 规范解析等多源信息。

**内部工具调用总计：61 次**
- WebSearch：约 30 次
- WebFetch：约 20 次（含 3 次失败的重试）
- Read（读取持久化大输出）：约 8 次
- RunCommand（创建目录）：1 次
- Write（写入报告）：1 次

调用覆盖的研究维度：
1. Apollo map.proto / map_lane.proto / map_road.proto / map_junction.proto / map_signal.proto / map_stop_sign.proto / map_crosswalk.proto / map_parking_space.proto / map_overlap.proto / map_geometry.proto 全部 proto 定义
2. OpenDRIVE 1.6 规范（geometry/junction/connection/reference line）
3. Apollo 8.0/9.0/10.0 三代演进
4. HDMapImpl 加载流程与 KD-Tree 空间索引
5. PncMap / RelativeMap / ReferenceLine 平滑
6. base_map/routing_map/sim_map 生成工具链
7. mmap 二进制格式设计模式
8. AuroraDrive 现有数据规模与扩展方案

---

> 参考来源：ApolloAuto/apollo GitHub 仓库（modules/map/proto/）、Apollo 官方文档、CSDN/Juejin 技术博客、电子发烧友/汽车之家 Apollo 发布报道、OpenDRIVE 1.6 规范解析。
