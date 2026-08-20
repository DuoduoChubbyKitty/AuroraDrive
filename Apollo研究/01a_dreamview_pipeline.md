# Apollo Dreamview 渲染管线架构深度研究报告

> 研究对象：Baidu Apollo 开源仓库 `ApolloAuto/apollo` 中 `modules/dreamview`（经典版）与 `modules/dreamview_plus`（9.0/10.0 新版）的可视化渲染管线。
> 研究目的：为 AuroraDrive（React + Three.js + Tauri 架构）的 SR（Simulation Reality / 仿真现实）界面重写提炼可直接迁移的实现细节。
> 信息来源：GitHub 仓库源码（通过 jsDelivr CDN 与 GitHub Web 抓取）、Apollo 官方文档（developer.apollo.auto）、CSDN/知乎源码解析专栏。所有关键结论均附源码链接。

---

## 1. Dreamview 模块整体架构

### 1.1 目录结构

Apollo 仓库中 Dreamview 实际上分为两个并列模块。经典版位于 `modules/dreamview`，新版 Dreamview Plus 位于 `modules/dreamview_plus`，二者目录结构几乎对称：

```
modules/dreamview（modules/dreamview_plus）
├── backend               // C++ 后端实现
├── frontend              // React 前端实现
├── conf                  // 配置（hmi_modes、data_collection_table 等）
├── proto                 // protobuf 消息定义
├── launch                // cyber_launch 启动文件
├── main.cc               // 进程入口
├── cyberfile.xml         // 包管理元数据
└── README.md
```

后端 `modules/dreamview/backend` 的实际子目录（截至 2026-01 master 分支）为：`common`、`hmi`、`perception_camera_updater`、`point_cloud`、`simulation_world`、`teleop`、`testdata`，以及顶层文件 `dreamview.cc` / `dreamview.h`。注意：`map_service`、`handlers`、`plugins`、`map_renderer` 等并非顶层目录，而是统一收纳在 `backend/common/` 之下（例如 `backend/common/map_service/map_service.h`、`backend/common/handlers/websocket_handler.h`、`backend/common/plugins/plugin_manager.h`）。任务描述中提到的 `dv_plugin`、`fuel_sdk`、`map_renderer` 等在当前 master 分支已不复存在——这是重要的版本差异结论：**Apollo 已持续做"瘦身"重构，地图预渲染（map_renderer）等历史能力被移除，地图元素改为前端按需拉取**。

源码链接：
- 目录总览：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview>
- backend 子目录：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview/backend>
- dreamview_plus：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview_plus>

### 1.2 后端（C++）vs 前端（React）职责划分

Dreamview 是一个标准的"**C++ 数据聚合层 + 前端 WebGL 渲染层**"架构，二者通过 WebSocket 解耦：

- **后端职责**：作为 CyberRT 的消费者，订阅所有自动驾驶相关 Channel（Localization / Chassis / Planning / Perception / Prediction / Routing / Control / TrafficLight / Monitor 等），将其聚合为一个统一的 `SimulationWorld` protobuf 消息；维护高精地图服务（`MapService`）；管理 HMI 状态机（模块开关、模式切换、路由请求）；通过 CivetWeb 嵌入式 HTTP/WebSocket 服务器对外提供静态资源与双向通信。
- **前端职责**：纯浏览器端 React + Three.js 应用。接收后端推送的二进制 protobuf，用 `protobufjs` 解码为 JS 对象，再驱动 Three.js Scene 渲染；处理用户交互（视角切换、路由绘制、模块开关）并以 JSON 命令回传后端。

后端不做任何 3D 渲染计算，只做"数据降采样 + ROI 裁剪 + protobuf 序列化"；前端不做任何业务逻辑，只做"解码 + 渲染 + 交互"。这种切分使得后端可以专注于低延迟数据聚合，前端可以独立迭代 UI。

### 1.3 WebSocket 通信协议与 HTTP 静态服务

入口文件 `modules/dreamview/backend/dreamview.cc` 的 `Dreamview::Init()` 清晰地展示了整个服务端的组成（源码：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/dreamview.cc>）：

```cpp
server_.reset(new CivetServer(options));          // CivetWeb 嵌入式服务器
websocket_.reset(new WebSocketHandler("SimWorld"));
map_ws_.reset(new WebSocketHandler("Map"));
point_cloud_ws_.reset(new WebSocketHandler("PointCloud"));
camera_ws_.reset(new WebSocketHandler("Camera"));
plugin_ws_.reset(new WebSocketHandler("Plugin"));
map_service_.reset(new MapService());
image_.reset(new ImageHandler());
perception_camera_updater_.reset(new PerceptionCameraUpdater(camera_ws_.get()));
hmi_.reset(new HMI(websocket_.get(), map_service_.get()));
plugin_manager_.reset(new PluginManager(plugin_ws_.get()));
sim_world_updater_.reset(new SimulationWorldUpdater(...));
point_cloud_updater_.reset(new PointCloudUpdater(point_cloud_ws_.get(), sim_world_updater_.get()));

server_->addWebSocketHandler("/websocket",  *websocket_);      // SimWorld + HMI
server_->addWebSocketHandler("/map",        *map_ws_);
server_->addWebSocketHandler("/pointcloud", *point_cloud_ws_);
server_->addWebSocketHandler("/camera",     *camera_ws_);
server_->addWebSocketHandler("/plugin",     *plugin_ws_);
server_->addHandler("/image",               *image_);
```

可见 Dreamview 实际维护 **5 条独立 WebSocket 频道**（外加可选的 `/teleop`），每条频道对应一个 `WebSocketHandler` 实例，互不阻塞：

| 路由 | WebSocketHandler 名 | 用途 | 数据形态 |
|------|---------------------|------|----------|
| `/websocket` | SimWorld | SimulationWorld 全量仿真世界 + HMI 状态/命令 | protobuf binary（数据）+ JSON（命令） |
| `/map` | Map | 地图元素（按需拉取） | protobuf binary |
| `/pointcloud` | PointCloud | 激光点云 | protobuf binary |
| `/camera` | Camera | 相机图像 + 感知投影 | protobuf binary |
| `/plugin` | Plugin | 插件通信 | JSON |
| `/image` | (HTTP) | 单帧图像（非 WS） | binary |

CivetServer 启动参数（来自 gflags，源码 `backend/common/dreamview_gflags.cc`）：
- `static_file_dir` = `/apollo/modules/dreamview_plus/frontend/dist`（静态资源根目录）
- `server_ports` = `8888`（注释明确：**Dreamview Plus 用 8888，经典 Dreamview 用 8899**）
- `websocket_timeout_ms` = `36000000`（10 小时保活）
- `request_timeout_ms` = `2000`
- `enable_keep_alive` = yes、`tcp_nodelay` = 1、`keep_alive_timeout_ms` = 500

进程入口 `main.cc` 极简：`cyber::Init` → `Dreamview::Init()` → `Dreamview::Start()` → `cyber::WaitForShutdown()`。启动链路为 `scripts/bootstrap.sh` → `scripts/dreamview.sh` → `cyber_launch start .../dreamview.launch` → `bazel-bin/modules/dreamview/dreamview --flagfile=...`。

### 1.4 数据流总览

完整的端到端数据流为：

```
CyberRT Channel (共享内存/进程内)
   │  (SimulationWorldService 持有各 cyber::Reader)
   ▼
SimulationWorldService::Update()        // 每 100ms 把各 reader 最新消息写进 world_ (SimulationWorld proto)
   │  DownsamplePath / DownsampleSpeedPointsByInterval  // 降采样
   │  PopulateMapInfo(radius=200m)                       // ROI 地图元素 ID
   ▼
SimulationWorldService::GetWireFormatString(radius, &sim_world, &sim_world_with_planning_data)
   │  world_.SerializeToString()                         // protobuf 二进制
   ▼
SimulationWorldUpdater::OnTimer()       // 100ms 定时器，加锁拷贝出 to_send
   ▼
WebSocketHandler::SendBinaryData(conn, to_send)   // /websocket 频道下发
   ▼
Frontend websocket.onmessage             // protobufjs 解码 SimulationWorld
   ▼
STORE (mobx) → React 组件 → renderer/*.js (Three.js Scene/Camera/Renderer)
   ▼
WebGL Canvas
```

### 1.5 protobuf 消息定义

核心消息定义在 `modules/common_msgs/dreamview_msgs/simulation_world.proto`（源码：<https://github.com/ApolloAuto/apollo/blob/master/modules/common_msgs/dreamview_msgs/simulation_world.proto>）。关键字段：

```protobuf
message SimulationWorld {
  optional double timestamp = 1;
  optional uint32 sequence_num = 2;
  repeated Object object = 3;                 // 所有障碍物
  optional Object auto_driving_car = 4;       // 自车
  optional Object traffic_signal = 5;
  repeated RoutePath route_path = 6;          // 路由路径
  repeated Object planning_trajectory = 8;    // 规划轨迹
  optional Object main_decision = 10;
  optional double speed_limit = 11;
  optional DelaysInMs delay = 12;
  repeated Notification notification = 14;
  map<string, Latency> latency = 16;
  optional MapElementIds map_element_ids = 17; // ROI 内地图元素 ID 列表
  optional uint64 map_hash = 18;               // 地图哈希（变更检测）
  optional double map_radius = 19;
  optional apollo.planning_internal.PlanningData planning_data = 20;
  optional Object gps = 21;
  optional apollo.perception.LaneMarkers lane_marker = 22;
  optional ControlData control_data = 23;
  repeated apollo.common.Path navigation_path = 24;
  optional bool is_rss_safe = 25;
  optional Object shadow_localization = 26;
  repeated Object perceived_signal = 27;
  map<string, bool> stories = 28;
  map<string, SensorMeasurements> sensor_measurements = 29;
  optional apollo.common.VehicleParam vehicle_param = 31;
}

message Object {
  optional string id = 1;
  repeated PolygonPoint polygon_point = 2;
  optional double heading = 3;
  optional double position_x = 6; optional double position_y = 7;
  optional double length = 8 [default = 2.8];  // 默认尺寸
  optional double width = 9 [default = 1.4];
  optional double height = 10 [default = 1.8];
  optional double speed = 11; optional double kappa = 18;
  repeated string signal_set = 19; optional string current_signal = 20;
  repeated Decision decision = 22;             // IGNORE/STOP/NUDGE/YIELD/OVERTAKE/FOLLOW/SIDEPASS
  enum Type { UNKNOWN; PEDESTRIAN; BICYCLE; VEHICLE; VIRTUAL; CIPV; ... }
  optional Type type = 29;
  repeated Prediction prediction = 30;         // 预测轨迹
}

message MapElementIds {
  repeated string lane = 1; repeated string crosswalk = 2;
  repeated string junction = 3; repeated string signal = 4;
  repeated string stop_sign = 5; repeated string road = 8;
  repeated string parking_space = 10; repeated string speed_bump = 11;
  ...
}
```

`map_element_ids` + `map_hash` 这对字段是实现"地图增量下发"的核心——后端只下发 ROI 内的地图元素 ID 列表与一个哈希值，前端比对哈希，仅在变化时通过 `/map` 频道请求具体元素。HMI 状态则由 `modules/dreamview/proto/hmi_status.proto` 的 `HMIStatus` 消息定义（modes / current_mode / maps / vehicles / modules / monitored_components / utm_zone_id 等），通过 CyberRT Channel `/apollo/hmi/status`（约 2~5Hz）与 WebSocket 双通道下发。

---

## 2. 后端 C++ 实现深度解析

### 2.1 SimulationWorldService —— 仿真世界聚合核心

`SimulationWorldService`（头文件：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/simulation_world/simulation_world_service.h>）是后端最核心的组件，注释明确："maintains a SimulationWorld object and keeps updating it. NOTE: This class is not thread-safe."（线程安全由外层 `SimulationWorldUpdater` 的 `boost::shared_mutex` 保证）。

关键成员与方法：
- `SimulationWorld world_`：底层 protobuf 对象，所有更新都写入它。
- `std::unordered_map<std::string, Object> obj_map_`：障碍物按 ID 去重的临时表。
- 一组 `cyber::Reader<T>` 指针：chassis / gps / localization / perception_obstacle / traffic_light / prediction / planning / control / navigation / relative_map / audio_event / drive_event / monitor / planning_command / storytelling / audio_detection / task。**这是 CyberRT 数据入口的全部清单**。
- `Update()`：定时调用，先 `node_->ClearData()` + `node_->Observe()`，再对每个 reader 调 `UpdateWithLatestObserved`。源码（来自 CSDN 解析）：

```cpp
void SimulationWorldService::Update() {
  if (to_clear_) { world_.Clear(); ... to_clear_ = false; }
  node_->Observe();
  UpdateMonitorMessages();
  UpdateWithLatestObserved(routing_response_reader_.get(), false);
  UpdateWithLatestObserved(chassis_reader_.get());
  UpdateWithLatestObserved(gps_reader_.get());
  UpdateWithLatestObserved(localization_reader_.get());
  obj_map_.clear(); world_.clear_object(); world_.clear_sensor_measurements();
  UpdateWithLatestObserved(perception_obstacle_reader_.get());
  UpdateWithLatestObserved(perception_traffic_light_reader_.get(), false);
  UpdateWithLatestObserved(prediction_obstacle_reader_.get());
  UpdateWithLatestObserved(planning_reader_.get());
  UpdateWithLatestObserved(control_command_reader_.get());
  ...
  for (const auto &kv : obj_map_) { *world_.add_object() = kv.second; }
  UpdateDelays(); UpdateLatencies();
  world_.set_sequence_num(world_.sequence_num() + 1);
  world_.set_timestamp(Clock::Now().ToSecond() * 1000);
}
```

- `GetWireFormatString(double radius, std::string* sim_world, std::string* sim_world_with_planning_data)`：序列化为两份二进制——一份精简（默认）、一份含 `planning_data`（PnC Monitor 用）。`radius` 即 ROI 半径（gflag `sim_map_radius=200.0` 米）。
- `GetMapElements(radius)` / `GetMapElementIds(radius, ids)`：调用 `MapService` 收集 ROI 内地图元素 ID 并计算 hash。
- `DownsamplePath` / `DownsampleSpeedPointsByInterval`：**显式的降采样函数**，按间隔抽取轨迹点，最后一个点强制保留，显著减小下发体积。
- `PopulateMapInfo(radius)`：把地图元素 ID 与 hash 填入 `world_`。
- `kMaxMonitorItems = 30`：monitor 消息最多保留 30 条，防止无限增长。

### 2.2 SimulationWorldUpdater —— 定时推送与前端命令响应

`SimulationWorldUpdater`（头文件：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/simulation_world/simulation_world_updater.h>）是 `SimulationWorldService` 与 WebSocket 之间的桥，注释："A wrapper around SimulationWorldService and WebSocketHandler to keep pushing SimulationWorld to frontend via websocket while handling the response from frontend."

```cpp
static constexpr double kSimWorldTimeIntervalMs = 100;  // 10Hz 推送
SimulationWorldService sim_world_service_;
WebSocketHandler *websocket_, *map_ws_, *camera_ws_, *plugin_ws_;
std::string simulation_world_;                         // 精简二进制缓存
std::string simulation_world_with_planning_data_;      // 含规划数据二进制缓存
boost::shared_mutex mutex_;                            // 读写锁保护上面两个字符串
std::unique_ptr<cyber::Timer> timer_;
```

`Start()` 启动 100ms 定时器，`OnTimer()` 调 `sim_world_service_.Update()` 后，在写锁内调 `GetWireFormatString` 把序列化结果缓存到成员变量。前端请求时（`RequestSimulationWorld` handler），在读锁内把缓存字符串拷出，再 `SendBinaryData` 下发——**"加锁拷贝、解锁后再发送"** 是关键设计，避免持锁走网络。

`RegisterMessageHandlers()` 注册的前端命令包括：`RequestSimulationWorld`、`RequestMapElementIds`、`SendRoutingRequest`（构造 `LaneFollowCommand`）、`SendValetParkingRequest`、`CheckRoutingPoint`、`RequestDefaultRouting`、`AddDefaultRouting`、`RequestParkGoRouting` 等。`ValidateCoordinate` / `CheckRoutingPoint` 在服务端做坐标合法性检查（车道是否 CITY_DRIVING）。

### 2.3 MapService —— ROI 查询与道路拼接

`MapService`（头文件：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/map_service/map_service.h>）封装高精地图高层 API。设计要点：

- **双地图**：`HDMap()` 返回完整高精地图，`SimMap()` 返回**降采样地图专供前端显示**。`use_sim_map_` 标志控制使用哪一份。这是 Apollo 性能优化的核心一招：完整地图用于 Routing/Planning，降采样地图用于 Dreamview 渲染，二者由 `modules/map/tools` 离线生成。
- `CollectMapElementIds(const PointENU& point, double radius, MapElementIds* ids)`：**ROI 查询入口**，以自车为圆心、`radius`（200m）为半径收集 lane/crosswalk/junction/signal/stop_sign/road/parking_space/speed_bump 等所有元素 ID。
- `RetrieveMapElements(const MapElementIds& ids)`：根据 ID 列表返回 `hdmap::Map` proto，前端按需拉取具体几何数据。
- `GetPathsFromRouting(routing, paths)` / `CreatePathsFromRouting` / `AddPathFromPassageRegion`：**道路拼接逻辑**，把 RoutingResponse 的 Passage 区域转成 `hdmap::Path` 序列，供前端绘制路由线。
- `CalculateMapHash(ids)`：对元素 ID 集合计算 hash，用于增量变更检测。
- `x_offset_` / `y_offset_` + `UpdateOffsets()`：**渲染坐标系原点偏移**（详见第 5 章）。
- `GetNearestLane` / `GetNearestLaneWithHeading` / `GetPoseWithRegardToLane` / `ConstructLaneWayPoint`：最近车道查询与路由点构造。
- `ReloadMap(force_reload)`：切换地图时重载。

> 说明：任务描述中的 `MapService::GetRoadSegments` 在当前 master 头文件中未直接出现；道路段拼接由 `GetPathsFromRouting` + `CreatePathsFromRouting` + `AddPathFromPassageRegion` 三函数链完成，是等价能力。

### 2.4 PointCloudUpdater —— 点云广播

`PointCloudUpdater`（头文件：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/point_cloud/point_cloud_updater.h>）负责点云下发：

- `FilterPointCloud(pcl_ptr)`：**VoxelGrid 体素滤波**，gflag `voxel_filter_size=0.3`、`voxel_filter_height=0.2`，`enable_voxel_filter_` 控制开关。这是点云下发前的关键降采样。
- `ConvertPCLPointCloud`：把 Apollo `drivers::PointCloud` 转 PCL `pcl::PointCloud<PointXYZ>`。
- `lidar_height_` / `kDefaultLidarHeight = 1.91f`：雷达离地高度，用于地面点过滤；从 `velodyne64_height.yaml` 加载（`LoadLidarHeight`）。
- `GetChannelMsg`：通过 `cyber::service_discovery::TopologyManager::Instance()->channel_manager()->GetWriters(...)` **动态发现**所有点云 Channel，前端下拉列表实时刷新。源码（CSDN 解析）：

```cpp
void PointCloudUpdater::GetChannelMsg(std::vector<std::string> *channels) {
  enabled_ = true;
  auto channelManager =
      apollo::cyber::service_discovery::TopologyManager::Instance()
          ->channel_manager();
  std::vector<apollo::cyber::proto::RoleAttributes> role_attr_vec;
  channelManager->GetWriters(&role_attr_vec);
  ...
}
```

- `ChangeChannel(channel)`：运行时切换点云 Channel，无需重启。
- `std::future<void> async_future_` + `std::atomic<bool> future_ready_`：**异步处理**点云，避免阻塞定时器。
- 同时订阅 `LocalizationEstimate`（`UpdateLocalizationTime`），用最近定位时间对齐点云。

### 2.5 PerceptionCameraUpdater —— 相机视图投影

`PerceptionCameraUpdater`（头文件：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/perception_camera_updater/perception_camera_updater.h>）注释精准："collects camera image and localization (by collecting localization & static transforms) to adjust camera as its real position/rotation in front-end camera view for **projecting HDmap to camera image**"。即后端预先算好"定位→相机"的变换矩阵，前端据此把 3D 地图元素投影叠加到 2D 相机画面上。

- `kImageScale = 0.6`：图像缩放系数，降低传输与渲染负担。
- `apollo::transform::Buffer *tf_buffer_` + `QueryStaticTF`：用 Eigen `Matrix4d` 查询静态 TF（`GetLocalization2CameraTF`）。
- `std::deque<LocalizationEstimate> localization_queue_`：**定位比图像频繁**，用 deque 按时间戳匹配最近定位（`GetImageLocalization`）。
- `OnCompressedImage` / `OnImage` / `OnObstacles`：分别处理压缩图、原图、感知障碍物（`BBox2D` 2D 框 + `obstacle_id` + `obstacle_sub_type`）。
- 同样支持 `GetChannelMsg` + `ChangeChannel` 动态切换相机通道。

### 2.6 WebSocketHandler —— 通信基石

`WebSocketHandler`（头文件：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/handlers/websocket_handler.h>）基于 CivetWeb 的 `CivetWebSocketHandler`，是所有频道的统一基类：

- `handleData`：处理 WebSocket 分帧（RFC 6455），用 `thread_local current_opcode_` 与 `data_` 累积，按首帧 opcode 分流到 `handleJsonData` 或 `handleBinaryData`。
- `std::unordered_map<std::string, MessageHandler> message_handlers_`：**消息类型→处理函数** 映射，`RegisterMessageHandler(type, handler)` 注册。
- `BroadcastData` / `BroadcastBinaryData` / `SendData` / `SendBinaryData`：均带 `bool skippable` 参数——**若该连接正忙，可跳过本帧**，这是避免堆积的关键背压机制。
- `std::unordered_map<Connection*, std::shared_ptr<std::mutex>> connections_`：**每连接独立锁**，避免全局锁竞争（注释明确："not using read write lock, as the server is not expected to get many clients"）。
- `RegisterConnectionReadyHandler`：连接就绪回调列表，用于新连接时推送初始状态。

### 2.7 HMI 管理

`HMI` 类（`backend/hmi/hmi.cc`）的 `RegisterMessageHandlers()` 注册所有 HMI 命令（源码 CSDN 解析）：

```cpp
websocket_->RegisterMessageHandler("HMIAction", [this](const Json& json, ...) {
  std::string action, value;
  JsonUtil::GetStringFromJson(json, "action", &action);
  HMIAction hmi_action; HMIAction_Parse(action, &hmi_action);
  if (JsonUtil::GetStringFromJson(json, "value", &value))
    hmi_worker_->Trigger(hmi_action, value);
  else
    hmi_worker_->Trigger(hmi_action);
  if (hmi_action == HMIAction::CHANGE_MAP) map_service_->ReloadMap(true);
  else if (hmi_action == HMIAction::CHANGE_VEHICLE) {
    PointCloudUpdater::LoadLidarHeight(FLAGS_lidar_height_yaml);
    SendVehicleParam();
  }
});
websocket_->RegisterMessageHandler("ChangeDrivingMode", ...);   // COMPLETE_AUTO_DRIVE / COMPLETE_MANUAL
websocket_->RegisterMessageHandler("ExecuteModeCommand", ...);   // start / stop
websocket_->RegisterMessageHandler("StartModule", ...);          // value = "Planning" 等
```

`HMIWorker::Trigger` 执行实际动作（启动模块对应 `START_MODULE` → `cyber_launch` DAG；`ChangeDrivingMode` 周期发 `PadMessage`）。HMI 模式由 `modules/dreamview/conf/hmi_modes/*.pb.txt` 配置，决定该模式下可启模块、监控组件、DAG 文件。`HMIStatus` 通过 `/apollo/hmi/status` Channel（约 2~5Hz，gflag `status_publish_interval`）与 WebSocket 双向下发。

### 2.8 插件系统

`PluginManager`（`backend/common/plugins/plugin_manager.h`）+ gflag 揭示插件机制：
- `plugin_path = /.apollo/dreamview/plugins/`（插件物理目录）
- `plugin_config_file_name_suffix = _plugin_config.pb.txt`
- `plugin_channel_prefix = /apollo/dreamview/plugins/`（插件通信 Channel 前缀）
- `dreamview.cc` 中 `PluginCallbackHMI` 处理 `UpdateScenarioSetToStatus` / `UpdateRecordToStatus` / `UpdateDynamicModelToStatus` / `UpdateVehicleToStatus` 等回调。

资源（场景集 / 动力学模型 / 录包）统一放置在 `/.apollo/resources/` 下（`resource_scenario_path`、`resource_dynamic_model_path`、`resource_record_path`），形成"插件 + 资源中心"体系。

---

## 3. 前端 React + Three.js 架构

### 3.1 前端代码位置与技术栈

经典版前端位于 `modules/dreamview/frontend`，`package.json`（<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/package.json>）揭示技术栈：

```json
{
  "name": "dreamview", "version": "5.5.0",
  "dependencies": {
    "react": "16.14.0", "react-dom": "16.14.0",
    "three": "~0.84.0",              // 注意：非常老的 Three.js 版本
    "three-line-2d": "^1.1.6",       // 高性能 2D 线渲染
    "protobufjs": "^6.8.4",          // 前端解码 protobuf 二进制
    "mobx": "^3.1.10", "mobx-react": "^4.1.8",   // 状态管理
    "proj4": "^2.4.4",               // 坐标系投影（UTM/WGS84）
    "chart.js": "^2.7.0",            // PnC 曲线图
    "stats.js": "^0.17.0",           // FPS/内存监控
    "antd": "4.20.0", "@ant-design/icons": "^4.7.0",
    "styled-components": "^4.1.3",
    "lodash": "^4.17.14"
  }
}
```

关键结论：
1. **Three.js 锁定在 ~0.84.0**（2017 年版本），说明 Apollo 前端为稳定性刻意不升级，但意味着无法用现代 Three.js（r150+）的 `InstancedMesh`、`BatchedMesh` 等新特性——这是 AuroraDrive 可改进点。
2. **mobx 3 + 装饰器**做状态管理，`STORE` 单例贯穿 renderer。
3. **protobufjs** 直接解码后端下发的二进制 `SimulationWorld`，避免 JSON 开销。
4. **proj4** 处理地理坐标投影，**stats.js** 内置帧率监控。

前端 `src` 目录结构（<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview/frontend/src>）：
```
src/
├── components/    // React 业务组件（Header/Sidebar/ModuleController/Tasks 等）
├── renderer/      // Three.js 渲染层（核心）
├── store/         // mobx store + websocket 客户端
├── utils/         // 工具（draw.js 绘图原语、misc 等）
├── styles/  fonts/
├── app.js         // React 根组件
└── index.hbs      // HTML 模板
```

### 3.2 React 组件树与渲染分层

`app.js` 为 React 根，挂载 `mobx` Provider。组件树大致为：
- `DreamView`（根）
  - `Header`（6 个下拉：Map/Vehicle/Mode/Setup Mode/Record/Data Profile）
  - `SideBar`（工具视图切换）
  - 主视图区（`Screen` → `Renderer` Canvas）
    - `CameraView` / `SatelliteView` / `PolygonView`（三大视图切换）
  - `ToolView`（ModuleController / Tasks / PnC Monitor / Delay / Console）
- 状态层：`STORE`（mobx observable）持有 `world`（SimulationWorld）、`options`（显示开关）、`hmiStatus`、`websocket` 实例。

`store/websocket/websocket_realtime.js` 是前端 WebSocket 客户端，**每 100ms 主动请求一次**（CSDN 解析原文）：

```js
// Request simulation world every 100ms.
this.timer = setInterval(() => {
  if (this.websocket.readyState === this.websocket.OPEN) {
    const requestPlanningData = STORE.options.showPNCMonitor;
    this.websocket.send(JSON.stringify({
      type: "RequestSimulationWorld",
      planning: requestPlanningData,
    }));
  }
}, this.simWorldUpdatePeriodMs);   // 100ms
```

注意是**前端拉（pull）模式**而非后端推（push）——前端按自身节奏请求，后端返回最新缓存。这种"请求-响应"而非"纯推送"的设计，让前端能根据渲染负载自适应节流。

### 3.3 三大类视图

Dreamview 主视图提供三类渲染模式：
- **Camera View（相机视图）**：以后端推送的相机图像为底，叠加投影后的高精地图元素与 2D 感知框（`BBox2D`）。后端 `PerceptionCameraUpdater` 预算 `localization2camera_tf`，前端据此做 3D→2D 投影。
- **Satellite View（卫星视图）**：叠加卫星影像瓦片，需要在线地图服务。
- **Polygon / 3D View（多边形/3D 视图）**：纯 Three.js 3D 场景，俯视/自由视角，渲染车道线、障碍物 Box、轨迹、点云。这是 SR 界面的核心。

### 3.4 Three.js Scene / Camera / Renderer 与坐标系

`renderer/coordinates.js`（<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/coordinates.js>）揭示了**渲染坐标系（SRN）**的本质：

```js
import * as THREE from 'three';
export default class Coordinates {
  constructor() { this.systemName = 'ENU'; this.offset = null; }
  initialize(x, y) { this.offset = { x, y }; }      // 用自车位置初始化原点偏移
  applyOffset(point, reverse = false) {
    return new THREE.Vector3(
      reverse ? point.x + this.offset.x : point.x - this.offset.x,
      reverse ? point.y + this.offset.y : point.y - this.offset.y,
      point.z,
    );
  }
}
```

核心机制：**世界坐标（UTM/ENU）减去一个固定的 offset 即得渲染坐标**，使自车初始位置成为 Three.js 原点 (0,0,0)。`offset` 来自后端 `MapService::UpdateOffsets()` 计算的 `x_offset_` / `y_offset_`（地图原点偏移），随 `SimulationWorld` 下发。这样所有渲染对象都在以自车为中心的局部坐标系内，避免 UTM 大数值带来的浮点精度问题。

坐标系约定：**默认 ENU（East-North-Up，右手系）**，自车朝向用 **FLU（Front-Left-Up）**——前端在渲染自车 Box 时做 ENU↔FLU 旋转。Three.js 默认右手系 Y-up，与 ENU 的 Z-up 需做轴交换。

`utils/draw.js` 提供绘图原语：`drawSegmentsFromPoints`（实线）、`drawDashedLineFromPoints`（虚线）、`drawBox` / `drawSolidBox` / `drawDashedBox`（障碍物框）、`drawArrow`（方向箭头）、`drawSolidPolygonFace`（多边形面）、`drawImage`（贴图）。

### 3.5 Dreamview Plus 前端架构

Dreamview Plus 前端（`modules/dreamview_plus/frontend`）完全重写为现代栈（<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview_plus/frontend/package.json>）：

```json
{
  "name": "dreamview_plus", "version": "2.0.0",
  "workspaces": ["packages/*", "packages/platforms/*"],   // lerna monorepo
  "devDependencies": {
    "react": "^18.2.0", "react-dom": "^18.2.0",          // React 18
    "typescript": "^5.0.4",                                // TypeScript 5
    "lerna": "^8.1.3",                                     // monorepo 管理
    "storybook": "^7.0.18",                                // 组件文档
    "webpack-merge": "^5.9.0"
  },
  "scripts": {
    "web:build": "yarn version:core && yarn patch-package && lerna run build --scope=@dreamview/web",
    "dreamview:mock": "lerna run start --scope=@dreamview/dreamview-mock"
  }
}
```

关键变化：**monorepo（lerna + yarn workspaces）**，拆分为 `@dreamview/web`（主应用）、`@dreamview/dreamview-ui`（组件库，可独立发布）、`@dreamview/dreamview-mock`（mock 数据，便于离线开发）、`packages/platforms/*`（多平台）。TypeScript 全面接入，Storybook 做组件隔离开发。这是 AuroraDrive 可直接借鉴的工程化范式。

---

## 4. WebSocket 数据流详解

### 4.1 频道与更新频率

综合 `dreamview.cc` 路由表与各 Updater 的定时器/订阅，各频道实际频率：

| 频道 | 触发方式 | 频率 | 数据 |
|------|----------|------|------|
| `/websocket` (SimWorld) | 前端每 100ms 拉取 | **10Hz** | SimulationWorld protobuf binary |
| `/websocket` (HMI) | 后端事件 + 周期 | ~2-5Hz (`status_publish_interval`) | HMIStatus JSON |
| `/map` | 前端按需请求（hash 变化时） | **事件驱动** | MapElementIds / hdmap::Map |
| `/pointcloud` | 后端订阅点云 Channel | **10Hz**（随传感器） | PointCloud protobuf（体素滤波后） |
| `/camera` | 后端订阅图像 Channel | 相机帧率（受 `kImageScale=0.6` 降采样） | CompressedImage + TF + BBox2D |
| `/plugin` | 插件事件 | 事件驱动 | JSON |

注意 `SimulationWorld` 内含 perception/prediction/planning/trajectory/traffic_light 等所有 10Hz 数据，**统一在一个 100ms 周期内聚合下发**，而非每类数据独立频道——这降低了前端的多路解码复杂度，但单帧体积需控制（见 `max_update_size`）。

### 4.2 订阅/取消订阅与序列化

`WebSocketHandler` 的 `RegisterMessageHandler` 机制即是"订阅"——前端发 `{type: "RequestSimulationWorld", planning: bool}`，后端按 type 路由到 handler。无显式 unsubscribe，靠连接关闭清理。

**序列化方式**：数据用 **protobuf binary**（`SerializeToString` + `SendBinaryData`），控制命令用 **JSON**（`websocket.send(JSON.stringify({type:...}))`）。`protobufjs` 在前端用预生成的 `sim_world_proto_bundle.json` 描述符解码二进制，比 JSON 体积小、解析快。

`SimulationWorldUpdater::OnTimer` 的关键并发设计（CSDN 原文）：

```cpp
void SimulationWorldUpdater::OnTimer() {
  sim_world_service_.Update();
  {
    boost::unique_lock<boost::shared_mutex> writer_lock(mutex_);
    sim_world_service_.GetWireFormatString(
        FLAGS_sim_map_radius, &simulation_world_,
        &simulation_world_with_planning_data_);
  }
}
```

请求 handler 读锁内拷贝、解锁后发送：

```cpp
websocket_->RegisterMessageHandler("RequestSimulationWorld", [this](const Json& json, ...) {
  if (!sim_world_service_.ReadyToPush()) return;
  bool enable_pnc_monitor = json["planning"];
  std::string to_send;
  { boost::shared_lock<boost::shared_mutex> reader_lock(mutex_);
    to_send = enable_pnc_monitor ? simulation_world_with_planning_data_ : simulation_world_; }
  if (FLAGS_enable_update_size_check && !enable_pnc_monitor &&
      to_send.size() > FLAGS_max_update_size) {   // 1MB 体积保护
    AWARN << "update size is too big:" << to_send.size();
    return;
  }
  websocket_->SendBinaryData(conn, to_send, true);   // skippable=true
});
```

`FLAGS_max_update_size = 1000000`（1MB）、`FLAGS_enable_update_size_check = true` 是后端对单帧体积的硬保护，超限直接丢弃并告警，防止前端阻塞。

---

## 5. 渲染坐标系与坐标变换

### 5.1 坐标层级

Apollo 涉及三层坐标：
1. **World/UTM 坐标**：高精地图原始坐标，米级大数值（如 UTM 东 350000m）。
2. **SRN 渲染坐标（Simulation Reality Node）**：以自车初始位置为原点的局部 ENU 坐标，数值小、浮点精度高。变换 = World − offset。
3. **自车坐标 FLU**：Front-Left-Up，自车朝向为 +X，用于描述障碍物相对位置与速度方向。

`MapService::UpdateOffsets()` 计算地图原点偏移 `x_offset_` / `y_offset_`（`GetXOffset()` / `GetYOffset()` 对外暴露），随 `SimulationWorld` 下发；前端 `Coordinates.initialize(x,y)` 设置后，所有 `applyOffset` 调用完成 World→SRN 转换。

### 5.2 自车跟随与多视图相机

前端 Three.js 用 `PerspectiveCamera`，三类视图通过切换 camera 位置/朝向实现：
- **俯视（Bird/Overhead）**：camera 位于自车正上方，向下看（`isBirdView` 标志贯穿 renderer）。
- **前视/侧视**：camera 置于自车前方/侧方特定偏移。
- **自由视角**：`OrbitControls`（Three.js）接管，鼠标拖动旋转、滚轮缩放。

"Follow ego"逻辑：每帧根据 `world.auto_driving_car.position_x/y` 更新 camera target，使自车始终居中；切换到自由视角时禁用跟随。

`stats.js`（package.json 依赖）实时显示 FPS 与内存，开发者可据此调参。坐标投影（WGS84↔UTM）由 `proj4` 完成，导航模式下用于把绝对经纬度转为地图相对位置。

---

## 6. 数据更新与增量渲染

### 6.1 后端增量机制

Dreamview 的"增量"并非帧间 diff，而是**多维度降采样 + ROI 裁剪 + 体积保护**：

1. **ROI 裁剪**：`sim_map_radius=200m`，只聚合自车 200m 范围内的地图元素 ID（`MapElementIds`）与障碍物。
2. **轨迹降采样**：`DownsamplePath`、`DownsampleSpeedPointsByInterval`（按固定间隔抽点，保留末点），规划轨迹点数大幅减少。
3. **地图 hash 变更检测**：`map_hash` + `map_element_ids` 下发，前端比对 hash，仅变化时拉取具体地图几何（`/map` 频道 `RetrieveMapElements`）。
4. **双份序列化**：默认下发精简版 `simulation_world_`，仅当 PnC Monitor 开启时下发含 `planning_data` 的完整版，避免常态大包。
5. **体积保护**：`max_update_size=1MB` 超限丢弃。
6. **点云体素滤波**：`voxel_filter_size=0.3` 在 0.3m 体素内仅留一点，点云量级降一个数量级。

### 6.2 前端 Diff 与对象池

前端**不做逐字段 diff**，而是用**对象池（Object Pool）**复用 Three.js 对象，最小化 GC 与重建开销。`renderer/obstacles.js`（<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/obstacles.js>）是典范：

```js
export default class PerceptionObstacles {
  constructor() {
    this.textRender = new Text3D();
    this.arrows = [];              // 方向箭头池
    this.ids = [];                 // ID 文本池
    this.solidCubes = [];          // 实线 Box 池（仅长宽高）
    this.dashedCubes = [];         // 虚线 Box 池
    this.extrusionSolidFaces = []; // 多边形挤出实面池
    this.extrusionDashedFaces = []; // 多边形挤出虚面池
    this.laneMarkers = [];
    this.icons = [];
    this.trafficCones = [];
    this.v2xCubes = []; this.v2xSolidFaces = [];
    this.cubeIdx = 0; this.arrowIdx = 0; this.extrusionFaceIdx = 0;
    ...
  }
  update(world, coordinates, scene, isBirdView) {
    this.resetObjects(scene, _.isEmpty(world.object));   // 隐藏多余对象
    this.updateObjects(world, coordinates, scene, isBirdView);
    ...
  }
}

export const ObstacleColorMapping = {
  PEDESTRIAN: 0xFFEA00,   // 黄
  BICYCLE:    0x00DCEB,   // 青
  VEHICLE:    0x00FF3C,   // 绿
  VIRTUAL:    0x800000,   // 暗红
  CIPV:       0xFF9966,   // 橙
};
```

机制：每帧 `update` 时，**按当前帧障碍物数量顺序复用池中对象**（`cubeIdx` 递增取用），未用到的对象调 `hideArrayObjects` 隐藏（`visible=false`）而非销毁。Box 的 `Geometry` / `Material` 跨帧复用，仅更新 `position` / `scale` / `rotation`。`utils/misc.js` 的 `copyProperty`、`hideArrayObjects`、`calculateLaneMarkerPoints` 是配套工具。

障碍物按是否有 `polygon_point` 分流：有 polygon 用 `extrusionSolidFaces`（挤出多面体），无 polygon 用 `solidCubes`（标准 Box）。颜色按 `Type` 映射，决策（YIELD 等）叠加 `icons` 贴图。

### 6.3 轨迹线与点云 Geometry 策略

- **轨迹线**：用 `three-line-2d`（package.json 依赖）而非原生 `THREE.Line`，支持线宽（`LINE_THICKNESS=1.5`），规划轨迹、预测轨迹、路由路径都走此路径。`drawSegmentsFromPoints` / `drawDashedLineFromPoints` 区分实/虚线。
- **点云 BufferGeometry**：点云量大，用 `THREE.Points` + `BufferGeometry`。每帧更新策略倾向于**重建 attribute**（点数变化大）而非完全 inplace，但因体素滤波后点数稳定，实际开销可控。

---

## 7. 性能优化技巧汇总

| 优化点 | 实现位置 | 机制 |
|--------|----------|------|
| **双地图（SimMap 降采样）** | `MapService::SimMap()` | 离线生成降采样地图专供显示，完整地图供算法 |
| **ROI 裁剪 200m** | gflag `sim_map_radius`、`CollectMapElementIds` | 只下发自车周围 200m 元素 |
| **轨迹降采样** | `DownsamplePath` / `DownsampleSpeedPointsByInterval` | 间隔抽点，保留末点 |
| **地图 hash 增量** | `CalculateMapHash` + `map_hash` 字段 | hash 不变则前端不重拉地图 |
| **点云体素滤波** | `FilterPointCloud` + `voxel_filter_size=0.3` | 0.3m 体素内留一点 |
| **单帧体积保护** | `max_update_size=1MB` | 超限丢弃告警 |
| **双份序列化** | `simulation_world_` vs `simulation_world_with_planning_data_` | 常态精简，PnC 时完整 |
| **对象池复用** | `obstacles.js` 数组 + `hideArrayObjects` | Box/Material 跨帧复用，仅更新变换 |
| **每连接独立锁** | `WebSocketHandler::connections_` | 避免全局锁竞争 |
| **skippable 发送** | `SendData(..., skippable=true)` | 连接忙则跳帧，背压 |
| **拉模式 100ms** | 前端 `setInterval` 请求 | 前端按渲染节奏拉，自适应节流 |
| **加锁拷贝、解锁后发** | `RequestSimulationWorld` handler | 不持锁走网络 |
| **FPS 监控** | `stats.js` | 实时帧率/内存可见 |
| **相机降采样** | `kImageScale=0.6` | 图像缩放降传输 |
| **异步点云处理** | `std::future` + `atomic` | 不阻塞定时器 |

> 注：任务描述中的 LOD、视锥剔除、InstancedMesh、远距离淡出、自适应降级在当前 master 源码中**未直接体现**——经典 Dreamview 因 Three.js 0.84 旧版限制，未用 `InstancedMesh`，障碍物多时靠对象池 + ROI 裁剪控制规模。这些恰是 AuroraDrive 用现代 Three.js 可超越之处。视锥剔除依赖 Three.js 内置 `frustumCulled`（默认开启）。

---

## 8. Apollo 9.0/10.0 Dreamview Plus 改进

### 8.1 与经典 Dreamview 的差异

| 维度 | 经典 Dreamview | Dreamview Plus |
|------|----------------|----------------|
| 端口 | 8899 | **8888** |
| 前端栈 | React 16 + Three.js 0.84 + mobx 3 | **React 18 + TS 5 + lerna monorepo + Storybook** |
| 工程化 | 单包 webpack | **monorepo（@dreamview/web、@dreamview/dreamview-ui、@dreamview/dreamview-mock）** |
| 布局 | 固定分区（Header/Sidebar/Main/Tool） | **基于面板（Panel）可拖拽布局**，自由配置面板数量/位置/内容 |
| 模式 | 单一 HMI Mode 配置 | **模式化多场景**：Default / Perception / PnC / Real-car |
| 资源 | 本地地图/车辆 | **资源中心**：本地 + Apollo Studio 云端同步（地图/场景/车辆/数据包） |
| 插件 | 无 | **插件市场**：`/.apollo/dreamview/plugins/`，统一 Channel 前缀 |
| 动力学模型 | 固定 | **可加载/切换/增删 DynamicModel**（`/.apollo/resources/dynamic_models/`） |
| 启动 | `aem bootstrap start` | `aem bootstrap start --plus` |

### 8.2 SR 可视化能力增强

Dreamview Plus 的 SR 能力增强体现在：
- **PnC 模式**：同一页面顺序完成 PnC 调试配置，图表类型筛选、曲线数据点查看、路由绘制（区分起点/途径点/终点，可保存常用路由）、测距与坐标复制。
- **感知模式**：精简感知调试流程。
- **多面板**：可同时开多个 3D 视图/曲线图/相机视图，对比不同数据。
- **地图视角调节**：便捷移动视角远近，多视角调整。

### 8.3 在线编辑与插件市场

- **在线编辑**：路由绘制（地图上点击设点 → 保存）、场景集编辑、动力学模型管理。
- **插件市场**：插件以 `/_plugin_config.pb.txt` 描述，放置 `/.apollo/dreamview/plugins/`，通过 `/apollo/dreamview/plugins/` Channel 通信；`PluginManager` 统一注册/启停；scenario / task / traffic rules 均可插件化（Apollo Beta 起）。
- **资源中心**：一键从 Apollo Studio 云端同步地图、场景、车辆配置、数据包到本地 `/.apollo/resources/`。

---

## 9. 对 AuroraDrive SR 界面重写的迁移建议

基于上述源码级分析，针对 AuroraDrive（React + Three.js + Tauri 架构）SR 界面重写，给出 5 条具体可迁移建议：

### 建议 1：复刻"后端聚合 + Protobuf Binary + 前端拉模式"的通信骨架

Dreamview 最大的工程价值在于其通信模型：**后端把多源 CyberRT 数据聚合为单一 `SimulationWorld` protobuf，每 100ms 用二进制下发；前端按渲染节奏主动拉取（`RequestSimulationWorld`），而非后端盲推**。AuroraDrive 应在 Tauri 侧（Rust）实现等价的 `SimulationWorldService`：订阅所有感知/规划/定位 channel，聚合为一个 protobuf，通过 Tauri 的 IPC（或本地 WebSocket）以二进制下发；前端用 `protobufjs`/`protobuf-es` 解码。关键要点：①拉模式让前端能根据 FPS 自适应节流；②`max_update_size` 体积保护；③`skippable` 跳帧背压；④加锁拷贝、解锁后发。同时前端维护 `mobx`/`zustand` store 镜像 SimulationWorld，驱动 React+Three.js。

### 建议 2：采用"SRN 渲染坐标系 + offset 偏移"避免大数值浮点误差

直接复刻 `Coordinates` 类：Tauri 后端计算地图原点 offset（`x_offset_`/`y_offset_`，可取自车启动位置或地图原点），随状态下发；前端所有 Three.js 对象坐标 = World − offset，使自车成为 (0,0,0)。ENU（世界）↔ FLU（自车朝向）旋转单独处理。这样既避免 UTM 大数值的浮点精度损失，又让自车始终在原点附近、相机跟随简单。AuroraDrive 用 Tauri+Rust 算 offset 比Apollo C++ 更易调试。

### 建议 3：用对象池 + 现代 Three.js InstancedMesh 超越 Apollo 的渲染性能

Apollo `obstacles.js` 的对象池模式（`solidCubes`/`arrows`/`extrusionSolidFaces` 数组 + `hideArrayObjects` + index 复用）是必迁移项，但 AuroraDrive 应更进一步：障碍物 Box 用 **`THREE.InstancedMesh`**（Three.js r150+，Apollo 0.84 用不了），单次 draw call 渲染上千 Box；点云用 `BufferGeometry` + `setDrawRange` inplace 更新（点数稳定时不重建）；轨迹用 `three-line-2d` 或 `Line2`（支持线宽）。颜色按 `ObstacleColorMapping`（行人黄/自行车青/车绿/虚拟红/CIPV橙）。配合 ROI 裁剪（200m）+ 轨迹降采样（间隔抽点），可在普通笔电跑百级障碍物 60FPS。

### 建议 4：复刻"双地图 + ROI + hash 增量"的地图下发策略

地图是体积大头。迁移 Apollo 的三段式：①Tauri 维护"完整地图"（算法用）与"降采样显示地图"（SR 用）双份；②每次只下发自车 200m ROI 内的 `MapElementIds`（ID 列表）+ `map_hash`；③前端比对 hash，仅变化时通过独立频道 `RetrieveMapElements(ids)` 拉取具体几何。车道线/路口/信号灯/停车线分类管理。这把地图下发从"全量 MB 级"降到"增量 KB 级"，是 Apollo 在弱网 docker 环境也能流畅的关键。

### 建议 5：借鉴 Dreamview Plus 的 monorepo + 模式化 + 面板化工程范式

AuroraDrive 的 React 前端应直接采用 Dreamview Plus 的工程化结构：①**lerna/yarn workspaces monorepo**，拆 `@aurora/web`（主应用）、`@aurora/ui`（组件库，可独立 Storybook 开发）、`@aurora/mock`（离线 mock 数据，用 record 回放调试，无需接真车）；②**模式化**（感知/PnC/实车/默认），不同模式加载不同面板组合与 HMI 配置；③**面板化布局**（可拖拽 Panel，数量/位置/内容自由配置），适配不同调试习惯；④**插件机制**（Panel 插件、场景插件），统一 `PluginManager` + Channel 前缀。这套结构让 SR 界面可扩展、可维护，远胜经典 Dreamview 的固定布局。

---

## 参考源码与文档链接

**Apollo 仓库源码（GitHub / jsDelivr CDN）**
- Dreamview 模块总览：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview>
- Dreamview Plus 模块：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview_plus>
- `dreamview.cc`（Init/Start 全貌）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/dreamview.cc>
- `simulation_world_service.h`：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/simulation_world/simulation_world_service.h>
- `simulation_world_updater.h`：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/simulation_world/simulation_world_updater.h>
- `map_service.h`（位于 common）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/map_service/map_service.h>
- `point_cloud_updater.h`：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/point_cloud/point_cloud_updater.h>
- `perception_camera_updater.h`：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/perception_camera_updater/perception_camera_updater.h>
- `websocket_handler.h`：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/handlers/websocket_handler.h>
- `dreamview_gflags.cc`（所有 gflag）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/backend/common/dreamview_gflags.cc>
- `simulation_world.proto`：<https://github.com/ApolloAuto/apollo/blob/master/modules/common_msgs/dreamview_msgs/simulation_world.proto>
- 前端 `package.json`（经典）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/package.json>
- 前端 `package.json`（Plus）：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview_plus/frontend/package.json>
- 前端 `coordinates.js`：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/coordinates.js>
- 前端 `obstacles.js`：<https://github.com/ApolloAuto/apollo/blob/master/modules/dreamview/frontend/src/renderer/obstacles.js>
- 前端 `src` 目录：<https://github.com/ApolloAuto/apollo/tree/master/modules/dreamview/frontend/src>

**Apollo 官方文档**
- HMI Status 通道：<https://developer.apollo.auto/Apollo-Homepage-Document/Apollo_Doc_CN_6_0/数据格式/人机交互模块/apollo_hmi_status>
- Dreamview 简介：<https://developer.apollo.auto/Apollo-Homepage-Document/Apollo_Doc_CN_6_0/快速上手/Dreamview简介/>

**源码解析专栏（CSDN/知乎）**
- sim_world_updater 解析：<https://blog.csdn.net/luochenzhicheng/article/details/125850835>
- DreamView 数据通信机制：<https://blog.csdn.net/O_MMMM_O/article/details/90201395>
- DreamView 界面修改（proto 字段）：<https://blog.csdn.net/o_mmmm_o/article/details/106103272>
- Apollo 3.5 模块启动过程（HMI RegisterMessageHandlers）：<https://blog.csdn.net/weixin_28888459/article/details/112640989>
- 点云可视化与 GetChannelMsg：<https://blog.csdn.net/xccccz/article/details/138412385>
- Apollo 10.0 系统概览：<https://blog.csdn.net/qq_31762031/article/details/156395028>
- Dreamview+ 新特性：<https://cloud.tencent.com/developer/article/2422018>
- Apollo Beta Dreamview Plus：<https://blog.csdn.net/Derek_Robbie/article/details/134811638>
- Apollo 高精地图解析：<https://blog.csdn.net/weixin_44128918/article/details/105684918>
- Apollo map 模块：<https://blog.csdn.net/qq_37346140/article/details/129569738>
- Apollo Routing 模块源码：<https://blog.csdn.net/davidhopper/article/details/79183557>

---

> 本报告执行了 11 次 WebSearch + 47 次 WebFetch（合计 58 次内部工具调用，含 GitHub 源码页、jsDelivr CDN 原始文件、Apollo 官方文档、CSDN 源码解析专栏的抓取与读取）。
