# Apollo 9.0 Dreamview Plus 与 SR 可视化架构深度研究报告

> 文档定位：AuroraDrive 项目技术调研子模块（02b）
> 调研对象：百度 Apollo 开放平台 9.0 / 10.0 的 Dreamview Plus 工具链、SR 可视化能力、插件市场、PnC 2.0 集成与 ADFM 演进，以及对 AuroraDrive（React + Three.js + Tauri 游戏驾驶辅助器）的可借鉴价值
> 调研日期：2026-07-23
> 调研方法：WebSearch + WebFetch 多源交叉验证（Apollo 官方文档、CSDN、腾讯云开发者社区、阿里云开发者社区、百度百科、ApolloAuto/apollo GitHub、Apollo Studio 等）

---

## 一、Dreamview Plus 的版本定位与历史脉络

百度 Apollo 的可视化 HMI 经历了三个阶段：

1. **Dreamview（早期 ~ 8.0）**：基于 React + WebGL 的单页 Web 应用，由 `modules/dreamview` 提供，后端 C++ 通过 CivetWeb HTTP Server + WebSocket 双通道与前端通信，前端监听 49923 端口在 WebWorker 中接收 message。其核心定位是"模块输出可视化 + 人机交互接口 + PnC Monitor 调试工具"。
2. **Dreamview Plus（Beta ~ 9.0）**：随 2023 年 12 月 19 日发布的 Apollo 9.0 正式推出，代码迁移到新的 `modules/dreamview_plus` 目录。Beta 版率先落地"默认模式 / 感知模式 / PnC 模式"三种场景模式，9.0 进一步在多场景使用、自由布局、数据资源三个维度全面升级，官方宣称"代码调试量减少 80%"。
3. **Dreamview Plus in 10.0**：与 ADFM 大模型协同，作为端到端模型可解释性的可视化入口，强化实时轨迹生成与安全冗余展示。

启动方式从 `aem bootstrap start`（旧 Dreamview）演进为 `aem bootstrap start --plus` 或源码模式下的 `bash scripts/bootstrap.sh start_plus`，浏览器访问 `localhost:8888` 进入模式选择页。

---

## 二、Dreamview Plus 架构总览

### 2.1 模块在 Apollo 仓库中的位置

Apollo 10.0 仓库共 28 个核心功能模块，`modules/` 下与可视化相关的两个并列模块为：

```
modules/
├── dreamview/                  # 旧版可视化 HMI（保留兼容）
│   └── backend/
│       ├── handlers/           # HTTP 处理器（image.cc 等）
│       ├── websocket/          # WebSocket 通信
│       ├── simulation_world/   # 仿真世界封装（simulation_world_service.cc）
│       └── point_cloud/        # 点云更新（point_cloud_updater.cc）
└── dreamview_plus/             # 新版可视化工具（Apollo 9.0+）
    ├── backend/                # C++ 后端服务
    │   ├── base/               # 服务基类与公共组件
    │   ├── handlers/           # HTTP / WebSocket 处理器
    │   │   ├── simulation_world_handler
    │   │   ├── websocket_handler
    │   │   ├── image_handler
    │   │   ├── point_cloud_handler
    │   │   ├── map_handler
    │   │   ├── plugin_handler
    │   │   ├── profile_handler
    │   │   └── offlinedata_handler
    │   ├── simulation_world/   # 仿真世界对象聚合
    │   ├── point_cloud/        # 点云渲染数据源
    │   ├── map/                # 地图服务
    │   ├── plugin_manager/     # 插件加载与管理
    │   ├── resource_center/    # 资源中心（云端同步）
    │   └── conf/               # 模式配置（default/perception/pnc）
    ├── frontend/               # 前端工程
    │   ├── src/
    │   │   ├── components/     # 面板组件
    │   │   ├── views/          # 模式视图
    │   │   ├── store/          # 状态管理
    │   │   ├── services/       # WebSocket / HTTP 封装
    │   │   └── assets/
    │   ├── package.json
    │   └── vite.config.ts
    └── conf/                   # 启动配置、模式定义
```

### 2.2 三层架构（文字架构图）

```
┌──────────────────────────────────────────────────────────────────────┐
│                         浏览器前端（Frontend）                        │
│   React + Three.js + Vite + TypeScript  （多面板可拖拽布局）          │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│   │ 车辆可视 │ │ 模块控制 │ │ 路由编辑 │ │ PnC监视  │ │ 资源中心 │   │
│   │ 3D SR    │ │ Tasks    │ │ Routing  │ │ Monitor  │ │ Profile  │   │
│   └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘   │
│        │            │            │            │            │          │
│        └────────────┴──────┬─────┴────────────┴────────────┘          │
│                              │ WebSocket(wss) + REST(https)            │
└──────────────────────────────┼────────────────────────────────────────┘
                               │
┌──────────────────────────────┼────────────────────────────────────────┐
│                       后端 C++（Backend）                              │
│   CivetWeb HTTP Server :8888  +  WebSocket Server                      │
│   ┌─────────────────────────────────────────────────────────────┐    │
│   │            DreamviewPlus 主进程（dviplus_main）              │    │
│   │  ┌───────────────┐  ┌──────────────┐  ┌────────────────┐   │    │
│   │  │ HMI 模式引擎  │  │ 插件管理器   │  │ 资源中心       │   │    │
│   │  │ ModeManager   │  │ PluginMgr    │  │ ResourceCenter │   │    │
│   │  └──────┬────────┘  └──────┬───────┘  └────────┬───────┘   │    │
│   │         │                  │                   │            │    │
│   │  ┌──────▼──────────────────▼───────────────────▼────────┐  │    │
│   │  │      SimulationWorldService（仿真世界对象聚合）       │  │    │
│   │  │  point_cloud / map / obstacle / planning / prediction │  │    │
│   │  └────────────────────────┬──────────────────────────────┘  │    │
│   └───────────────────────────┼─────────────────────────────────┘    │
└────────────────────────────────┼─────────────────────────────────────┘
                                 │ CyberRT Reader/Writer
┌────────────────────────────────▼─────────────────────────────────────┐
│                    CyberRT 通信总线（零拷贝、微秒级）                  │
│   perception / planning / control / prediction / routing / localization│
│                 modules/*  +  apollo-neo-* 软件包                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.3 后端 C++ API 与通信协议

后端沿用旧 Dreamview 的双通道通信模型并扩展：

- **HTTP REST**：`/websocket`（握手）、`/map`、`/pointcloud`、`/obstacles`、`/prediction`、`/planning`、`/poilist`、`/checkrouting`、`/simcontrol/start`、`/simcontrol/stop`、`/profile/*`、`/plugin/*`、`/offlinedata/*` 等端点。所有响应统一以 JSON 封装。
- **WebSocket**：双工通道。前端 `new WebSocket("ws://...")` 后注册 `onopen/onmessage/onclose/onerror`，后端通过 `WebSocketHandler` 广播 `SimulationWorld` 增量数据，前端 WebWorker 解析后驱动 Three.js 渲染。消息按 channel 名分发（pointcloud、map、prediction、planning、obstacle 等）。
- **SimulationWorldService**：核心聚合层。后端订阅 CyberRT 多个 channel，把 Chassis、Localization、PerceptionObstacles、PredictionObstacles、PlanningTrajectory、RoutingResponse 等异构 protobuf 消息统一抽象为 `SimulationWorld` 对象，再序列化为 JSON 推给前端，避免前端直接耦合 CyberRT。

### 2.4 前端技术栈

Dreamview Plus 前端在旧 Dreamview（React 15 时代）基础上做了现代化重构，核心栈为：

- **React + TypeScript**：组件化面板体系，每个面板（车辆可视化、模块控制、PnC Monitor、资源中心等）是独立可拖拽组件。
- **Three.js / WebGL**：3D SR 渲染、点云、车道线、障碍物 3D 框、规划轨迹、路由红线。
- **Vite**：构建工具，热更新友好，dev 体验优于旧版 webpack。
- **状态管理**：基于 React Context / Store 模式管理 WebSocket 数据流与面板布局状态。
- **国际化**：原生支持中英文切换（旧版 DV 仅英文）。

> 注：Apollo 早期 Dreamview frontend 是纯 React 方案，社区曾有 Vue3 + Element Plus 的猜测，但仓库内 `modules/dreamview_plus/frontend` 实际仍为 React 系。AuroraDrive 同样使用 React + Three.js，技术栈高度对齐，便于直接借鉴。

### 2.5 与原 Dreamview 的兼容性

- 两套模块并存：`modules/dreamview` 与 `modules/dreamview_plus` 在 9.0/10.0 仓库中同时存在，通过 `bootstrap.sh start` 与 `bootstrap.sh start_plus` 分别启动，端口均为 8888（互斥）。
- 后端大量复用旧 Dreamview 的 `SimulationWorldService`、`PointCloudUpdater`、地图加载逻辑，新增 `plugin_manager`、`resource_center`、`profile_handler` 等模块。
- 数据通道兼容旧 record 包：Dreamview Plus 可直接播放 Apollo 6.0_edu 的 `demo_3.5.record` 等历史数据包，无需转换。

---

## 三、SR 可视化能力

### 3.1 车道级渲染

Dreamview Plus 的 SR 渲染底层依赖 `sim_map`（基于 `base_map` 抽稀生成的轻量可视化地图），避免加载全量高精地图导致界面卡顿。在 SR 视图上：

- **车道线**：区分实线 / 虚线 / 双线 / 道路边缘，颜色与样式与 `modules/map/proto/map_lane.proto` 中的 `lane_boundary_type` 一致。
- **路由红线（Routing）**：粗红线叠加在车道上，表示全局路由搜索结果（Routing 模块 A* 在 `routing_map` 拓扑图上的输出）。
- **规划蓝线（Planning）**：实时局部轨迹，由 Planning 模块每周期输出，前端以蓝色折线 + 速度色阶渲染。
- **车道级导航 SR**：在 PnC 模式下，可高亮当前主车应行驶车道，配合 Apollo 9.0 的车道级导航能力（见 `01z_lane_level_nav.md`）。

### 3.2 多传感器同步播放（感知模式核心升级）

旧版 DV 只支持单传感器窗口，Dreamview Plus 升级为**多传感器窗口**：

- 可同屏同步播放多个摄像头（前/后/左/右）数据；
- 同屏叠加激光雷达点云；
- 支持多种传感器感知方案（纯视觉 / Lidar + Camera / Lidar + Camera + Radar 融合）；
- 多视角调整地图，便捷移动视角远近。

这是感知模式（Perception Mode）最显著的 SR 改进——开发者可在同一页面观察原始传感器数据与感知输出障碍物是否匹配，无需切换窗口。

### 3.3 障碍物建模改进

- **3D Bounding Box**：障碍物以 3D 框渲染，支持类别颜色区分（车辆/行人/自行车/未知）；
- **预测轨迹叠加**：每个动态障碍物叠加 Prediction 模块输出的未来轨迹（多假设概率线）；
- **栅栏区与停止原因**：继承旧 DV 的决策栅栏区（fence）可视化，新增停止原因文字标注；
- **图表类型筛选 + 数据点查看**：车辆数据监测支持图表类型筛选，支持曲线上数据点的查看，便于观测算法表现。

### 3.4 多视图切换与录制回放

- **多视图**：默认模式 / 感知模式 / PnC 模式三种顶层视图，每种模式预置不同面板组合；
- **自由面板布局**：可拖拽添加、复制、删除面板，自由设置面板数量、位置与大小；
- **录制回放**：支持本地 record 包播放（`cyber_recorder play -f xxx.record -l` 循环回放），也支持通过资源中心一键下载云端 record 包；回放时所有模块输出（定位、感知、预测、规划、控制、Canbus）同步可视化。

---

## 四、在线编辑能力

### 4.1 在线路径编辑（Route Editing）

Route Editing 是 Dreamview 系列一直保留的核心在线编辑能力，Plus 版做了显著增强：

- **起点 / 途径点 / 终点分离**：区分起点和途径点，最后一个点为终点；
- **保存常用路由**：可保存常用路由，下次一键复用；
- **快捷绘制**：可在地图上快捷绘制一系列点，方便地发送到规划算法；
- **测距与复制坐标**：支持测量两点之间的距离，或多个点组成的折线长度总和；同时支持将这段路中的地图坐标点信息复制到剪贴板，便捷地传递到算法（这对 AuroraDrive 的路径脚本化非常友好）。

编辑完成后点击 `Send Routing Request`，前端通过 HTTP `POST /routing` 发送至后端，后端转发给 Routing 模块，Routing 在 `routing_map` 拓扑图上跑 A*，结果以红线返回前端。

### 4.2 在线场景配置（Apollo Studio 协同）

Dreamview Plus 本身没有交通流场景制作功能，但通过 **Apollo Studio 云端场景编辑器 + Profile 插件** 形成在线场景配置闭环：

1. 在 Apollo Studio Web 端创建场景集（系统场景 / 个人场景），编辑带障碍物信息的交通流；
2. 通过 Profile 插件将场景集同步到本地 Dreamview Plus；
3. 在 Dreamview Plus 的 `Scenario Profiles` 中选择场景，配合 `Sim Control` 仿真运行。

### 4.3 在线标注与协同编辑

- 场景标注与编辑主要在 Apollo Studio 云端完成，支持多人协同；
- 本地 Dreamview Plus 通过 `Profile` 同步获取最新场景，实现"云端编辑 → 同步 → 本地仿真"的协同链路；
- 资源中心可实时同步各类资源（地图、场景、车辆配置、数据包）的更新状态，便于快速迭代测试。

### 4.4 编辑历史

编辑历史的管理粒度在云端 Apollo Studio 工作台（场景集版本管理），本地 Dreamview Plus 主要消费最新版本。Profile 插件支持场景集类型的过滤（线下测评场景集才同步到本地，线上仿真类型不一定可用）。

---

## 五、插件市场与插件化机制

### 5.1 Apollo 插件化机制基础

Dreamview Plus 的插件能力建立在 Apollo 基于 CyberRT 的统一插件化机制之上：

- **PluginManager**：单例核心类，负责插件加载、注册、实例化、生命周期管理；
- **PluginDescription**：插件描述信息（名称、描述文件路径、库路径、类与基类映射）；
- **注册宏**：`CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN(DerivedClass, BaseClass)`；
- **描述文件**：XML 格式，声明 `.so` 库与其中包含的插件类；
- **延迟加载**：`PluginManager::LoadInstalledPlugins()` 扫描 `APOLLO_PLUGIN_INDEX_PATH`，仅解析索引，实例化时才 `dlopen` 真实库。

### 5.2 插件市场类型表

| 插件类型 | 基类 | 典型插件 | 在 Dreamview Plus 中的入口 | 用途 |
| --- | --- | --- | --- | --- |
| 规划场景 | `apollo::planning::Scenario` | ParkAndGoScenario、BareIntersection、TrafficLight、PullOver、ValetParking、Emergency、LaneFollow | PnC 模式 → 模块配置 → 场景流水线 | 处理特定驾驶场景 |
| 规划阶段 | `apollo::planning::Stage` | StageApproach、StageCruise、StageIntersection | 同上（ScenarioPipeline 配置） | 场景内阶段切换 |
| 规划任务 | `apollo::planning::Task` | LaneBorrowPath、PathBoundsDecider、SpeedBoundsDecider、PiecewiseJerkSpeed | PnC 模式 → Task 列表 | 轨迹/速度生成 |
| 交通规则 | `apollo::planning::TrafficRule` | BacksideVehicle、Crosswalk、KeepClear、StopSign | PnC 模式 → Traffic Rules | 规则约束 |
| 控制器 | `apollo::control::ControlTask` | MPCController、LonControl、LatControl | PnC Monitor → 控制器 | 横纵向控制 |
| 感知检测器 | `apollo::perception::BaseDetector` | CenterPoint、PointPillars、SMOKE、YOLO3D、BEVFormer | 感知模式 → 模型选择 | 障碍物检测 |
| 仿真工具 | `SimControl`、`sim_obstacle` | Sim Control、交通流仿真 | Tasks → Others → Sim Control | 仿真回放 |
| 资源同步 | Profile 插件 | Profile | 资源中心 → Profile → Download | 云端场景同步 |
| 调试工具 | PnC Monitor | PncMonitor | Tasks → PNC Monitor | 规控调试 |
| 数据工具 | OfflineData 插件 | record 播放器 | Operations → Record | 离线数据包播放 |

### 5.3 插件开发 SDK

开发一个 Apollo 插件的固定流程：

1. **继承基类**：实现 `Scenario` / `Stage` / `Task` / `TrafficRule` 等基类接口（如 `Init`、`Process`、`IsTransferable`、`Reset`、`Enter`、`Exit`）；
2. **注册插件**：`CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN(apollo::planning::MyScenario, Scenario)`；
3. **配置描述文件**：`plugins.xml` 声明 `.so` 与类；
4. **编译打包**：使用 `apollo_plugin` 构建规则编译为动态库；
5. **分级参数配置**：全局参数在 `conf/*.conf`，局部参数放在插件内独立管理，便于查询修改。

### 5.4 插件管理与第三方集成

- **统一对外接口**：Apollo 9.0 将接口统一封装在 `external_command` 模块，隔离上层业务调用与 PnC 模块接口变化，第三方可方便地自定义扩展接口与底盘命令；
- **配置驱动**：通过配置流程启动运行插件，无需重新编译核心代码即可改变系统行为；
- **热插拔能力**：支持运行时动态加载/卸载插件；
- **Dreamview Plus 内的插件入口**：`plugin_handler` 提供 HTTP `/plugin/*` 端点，前端可枚举已加载插件、查看插件配置、切换插件实现。

### 5.5 知名插件案例

- **Profile 插件**：场景集云端同步必备，安装方式 `aem profile use <key>`；
- **PnC 竞赛插件**（pnc-competition）：Apollo 城市道路自动驾驶虚拟仿真大赛标准包；
- **仿真插件**：将 Apollo Studio 云端线下仿真场景集同步到本地；
- **CenterPoint / YOLO3D 模型插件**：感知 2.0 的核心检测器，可替换为自训练增量模型。

---

## 六、用户界面改进

### 6.1 界面布局

- **自由面板布局**：拖拽添加面板、一键复制 / 删除、自由设置面板数量 / 位置 / 大小；
- **模式预设**：默认模式 / 感知模式 / PnC 模式，每种模式预置不同面板组合，开发者可随意切换；
- **左侧任务栏**：Tasks、Profile、Route Editing、Module Controller、PNC Monitor 等入口；
- **底部播放控制条**：播放 / 暂停 / 倍速 / 进度条；
- **顶部模式切换 + 资源中心入口**。

### 6.2 主题与国际化

- **中英文切换**：全量功能支持中英文，降低专有名词理解难度；
- **新人引导**：根据各模式开发需求提供可视化使用引导，协助新开发者快速学习操作流程；
- **主题色**：以 Apollo 蓝（#1890ff 系）为主色调，深色 / 浅色背景可切换。

### 6.3 与原 Dreamview 操作对比

| 维度 | 原 Dreamview | Dreamview Plus |
| --- | --- | --- |
| 启动 | `aem bootstrap start` | `aem bootstrap start --plus` |
| 场景模式 | 单一界面，所有功能堆叠 | 三种模式分离，流程精简 |
| 面板布局 | 固定布局 | 自由拖拽、复制、删除、缩放 |
| 传感器窗口 | 单传感器 | 多传感器同屏同步 |
| 路由编辑 | 基础起点终点 | 起点途径点分离、保存常用路由、测距、复制坐标 |
| 资源获取 | 手动上传下载 | 资源中心一键同步云端（地图/场景/车辆/数据包） |
| 国际化 | 仅英文 | 中英文切换 |
| 新人引导 | 无 | 模式化使用引导 |
| 调试步骤 | 多页面跳转 | 同一页面顺序完成 PnC 调试配置 |

---

## 七、PnC 2.0 与 Dreamview Plus 集成

### 7.1 PnC 2.0 插件化要点

Apollo 9.0（Beta 起）的 PnC 2.0 核心改造：

- **scenario / task / traffic rules 全面插件化**：便于用户独立开发部署自己的插件；
- **双状态机**：Scenario（顶层场景切换）+ Stage（场景内阶段切换），均通过 `ScenarioManager::Update` 动态切换；
- **统一对外接口**：`external_command` 模块隔离上层业务与 PnC 接口变化；
- **分级参数配置**：全局参数 + 局部参数（局部参数放在插件内独立管理）。

### 7.2 规划插件化在 Dreamview Plus 中的可视化

- 在 PnC 模式下，开发者可在同一页面顺序完成 PnC 调试配置（选场景 → 选车辆 → 选地图 → 开模块 → 设路由），减少配置步骤；
- ScenarioPipeline 配置可视化：展示当前激活的 Scenario → Stage → Task 链路；
- 实时显示场景切换事件（Enter/Exit/Reset），便于理解双状态机行为。

### 7.3 控制插件化与实时调试

- 控制器以 `ControlTask` 插件形式存在（MPC / LQR / PID）；
- PnC Monitor 实时显示控制器输出（方向盘转角、油门、刹车）、误差曲线、状态量；
- **参数调优界面**：通过修改 `modules/planning/conf/planning.conf`（如 `planning_upper_speed_limit`、`default_cruise_speed`）或控制 conf，重启模块即可生效；PnC Monitor 速度单位 km/h，配置文件速度单位 m/s，需注意换算。

### 7.4 实时调试闭环

```
修改 conf/插件参数 → 重启 Planning/Control 模块 → 重新 Send Routing Request
        ↑                                              ↓
        └──── PnC Monitor 观察曲线/轨迹 ←── SR 可视化观察行为 ←─┘
```

---

## 八、Apollo 9.0 总体改进

### 8.1 感知 2.0 插件化

- **激光雷达**：CenterPoint 替换 CNNSeg（OpenVINO 合作沉淀，Apollo 原生激光雷达支持模型）；
- **相机**：YOLOX + YOLO3D 替换原 YOLO；
- **模型即插件**：感知检测器以插件形式注册，可替换为自训练增量模型；
- **增量训练**：提供完整增量训练教程，少量标注数据 + Apollo 预训练模型即可提升特定场景检测能力，训练代码完全开源；
- **4D 毫米波雷达**：从硬件驱动到感知模型层全面支持，可测目标高度、更高角度分辨率、更密集点云，提升雨雪雾天气安全性。

### 8.2 PnC 2.0 插件化

见第七章。核心是 scenario / task / traffic rules 插件化 + external_command 统一接口 + 分级参数配置，调试效率再提升一倍。

### 8.3 标定改进

- 传感器标定工具支持 Lidar 与 Camera 的**可视化标定**；
- 标定成功率 90% 以上；
- 企业开发者无需车端采集数据再上传云端等待解算，**标定时长由天级别缩短为小时级别**。

### 8.4 仿真工具升级

- Dreamview Plus 集成本地模拟器（Sim Control / ControlSim），为 PnC 开发者提供强大调试工具；
- 支持场景集同步（Profile 插件），云端编辑场景一键到本地；
- Sim Control 可选 Mkz Standard Debug 等模式，配合 Apollo Virtual Map 进行纯仿真调试。

### 8.5 数据工具

- 资源中心整合本地 + 云端资源（地图、场景、车辆配置、数据包）；
- Apollo Studio 工作台一键同步；
- record 包支持 `cyber_recorder play` 与 Dreamview Plus 内置播放器两种方式。

---

## 九、Apollo 10.0 ADFM 集成

### 9.1 ADFM 概述

Apollo ADFM（Autonomous Driving Foundation Model）是百度 Apollo 于 **2024 年 5 月 15 日** 在武汉 Apollo Day 2024 发布的**全球首个支持 L4 级别自动驾驶的大模型**：

- 基于大模型技术构建的新型自动驾驶系统；
- 通过**全链路模型化**综合输出多元环境信息，**直接生成执行轨迹**（端到端）；
- 安全性能超出人类驾驶员 10 倍以上；
- 10 重安全冗余方案 + 6 重 MRC 安全策略，安全水平接近国产大飞机 C919；
- 萝卜快跑第六代无人车全面应用"ADFM 大模型 + 硬件产品 + 安全架构"方案。

### 9.2 ADFM 在 Dreamview Plus 中的可视化

- Apollo 10.0 应用层仍以 **Dreamview（可视化 HMI）** 作为入口，10.0 的 Dreamview Plus 承担 ADFM 端到端输出的可视化职责；
- 由于 ADFM 直接生成轨迹（而非传统 Planning 多阶段输出），SR 视图从"感知→预测→规划"分段渲染，演进为"环境理解 → 单条端到端轨迹"的一体化展示；
- 应用层架构图中明确将 Dreamview 列为应用层核心，承载 ADFM 的可解释性需求。

### 9.3 端到端模型的可解释性

端到端模型的"黑盒"特性是其工程化最大障碍，Dreamview Plus 通过以下手段提升可解释性：

- **环境信息多元输出可视化**：ADFM 综合输出的多元环境信息（障碍物、车道、可行驶区域、信号灯）在 SR 上分层渲染；
- **轨迹生成过程对比**：可对比 ADFM 直接生成的轨迹与传统模块化 Planning 的轨迹差异；
- **安全冗余状态展示**：10 重冗余 / 6 重 MRC 的触发状态可在监控面板呈现；
- **回放 + 因果分析**：结合 record 包回放，对端到端决策进行事后复盘。

### 9.4 与 9.0 的差异

| 维度 | Apollo 9.0 | Apollo 10.0 |
| --- | --- | --- |
| 核心范式 | 模块化 + 插件化（感知 2.0 / PnC 2.0） | 大模型端到端（ADFM）+ 模块化兼容 |
| 规划输出 | Scenario/Stage/Task 多阶段轨迹 | ADFM 直接生成执行轨迹 |
| SR 渲染重点 | 分段渲染（感知/预测/规划） | 一体化环境理解 + 单轨迹 |
| 安全机制 | 模块级 guardian | 10 重冗余 + 6 重 MRC |
| Dreamview Plus 角色 | PnC/感知调试工具 | ADFM 可解释性入口 |
| 技术栈 | C++17 + CyberRT + PyTorch | + 大模型推理栈 |

---

## 十、Apollo 源码结构补充

Apollo 10.0 仓库核心技术栈：C++17 / Python 3.6 / Bazel 3.7+ / CyberRT（零拷贝、微秒级延迟）/ PyTorch 1.7+ / TensorRT / PaddlePaddle / OpenCV 4 / PCL / IPOPT / OSQP / CUDA 11.8 / cuDNN。

与 Dreamview Plus 直接相关的源码路径：

- `modules/dreamview_plus/backend/handlers/`：HTTP/WebSocket 处理器，新增 `plugin_handler`、`profile_handler`、`offlinedata_handler`、`map_handler`、`point_cloud_handler`；
- `modules/dreamview_plus/backend/simulation_world/`：`SimulationWorldService` 聚合层，10.0 起需兼容 ADFM 端到端输出 channel；
- `modules/dreamview_plus/backend/plugin_manager/`：插件加载与枚举，对接 CyberRT `PluginManager`；
- `modules/dreamview_plus/backend/resource_center/`：资源中心，对接 Apollo Studio 云端；
- `modules/dreamview_plus/frontend/`：React + Three.js + Vite + TypeScript 工程；
- `modules/dreamview_plus/conf/`：模式配置（default_mode / perception_mode / pnc_mode），定义各模式预置面板与默认模块；
- `modules/planning/scenarios/`：规划场景插件源码（ParkAndGo、BareIntersection 等），每个场景一个 `.so`；
- `modules/planning/scenarios/park_and_go/`：典型场景插件示例，含 `ParkAndGoScenario`、`ParkAndGoStageAdjust`、`ParkAndGoStagePreCruise` 等类，通过 `CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN` 注册；
- `modules/perception/`：感知 2.0 插件化检测器（CenterPoint、PointPillars、YOLO3D 等）。

旧 Dreamview 源码参考点（用于理解 Plus 的继承关系）：

- `modules/dreamview/backend/point_cloud/point_cloud_updater.cc`：`PointCloudUpdater::GetChannelMsg`，Plus 版沿用点云 channel 发现逻辑；
- `modules/dreamview/backend/simulation_world/simulation_world_service.cc`：模板化 `UpdateSimulationWorld`，Plus 版扩展为多模式聚合；
- `modules/dreamview/backend/handlers/image.cc`：图像 handler，Plus 版拆分为多传感器窗口。

---

## 十一、AuroraDrive 迁移建议

AuroraDrive 当前栈为 **React + Three.js + Tauri**（游戏驾驶辅助器，兼容所有设备），与 Dreamview Plus 前端栈高度对齐。以下给出可借鉴方向。

### 11.1 借鉴插件化思想

- **后端插件总线**：参考 Apollo `PluginManager` 单例 + `CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN` 宏 + XML 描述文件 + 延迟加载，为 AuroraDrive 设计游戏适配插件（不同游戏 = 不同插件包），实现"核心 + 插件"解耦；
- **统一对外接口**：借鉴 `external_command` 思想，定义 AuroraDrive 的统一命令接口（如 `DriveCommand`、`PathCommand`），隔离上层游戏逻辑与下层控制实现；
- **分级参数配置**：全局参数（屏幕分辨率、帧率）+ 插件局部参数（某游戏的转向灵敏度），局部参数随插件独立管理；
- **配置驱动**：插件组合通过 JSON 配置文件切换，无需重新编译核心。

### 11.2 借鉴 SR 改进

- **多传感器窗口范式**：AuroraDrive 可借鉴"多窗口同屏"思路，同时展示游戏画面 + SR 3D 感知 + 小地图，对应小鹏"分屏式 SR"目标布局（见 `01e_sr_comparison.md`）；
- **车道级渲染**：Dreamview Plus 的车道线类型（实/虚/双/边缘）+ 路由红线 + 规划蓝线三色体系，可直接迁移到 AuroraDrive 的 SR；
- **障碍物 3D 框 + 预测轨迹叠加**：游戏内车辆/行人 3D 框 + 多假设预测线，提升辅助驾驶可信度；
- **图表类型筛选 + 数据点查看**：AuroraDrive 调试模式下，对速度/转向/油门曲线提供数据点查看，便于调参；
- **sim_map 抽稀思想**：AuroraDrive 渲染地图时可维护"轻量可视化版"地图，避免全量数据卡顿。

### 11.3 借鉴在线编辑能力

- **路径编辑器**：借鉴 Route Editing 的"起点/途径点/终点分离 + 保存常用路由 + 测距 + 复制坐标"，为 AuroraDrive 提供游戏内路径脚本编辑器（玩家可手绘路径并保存）；
- **坐标复制到剪贴板**：极大便于把游戏内坐标传递到算法/脚本，是低成本高收益功能；
- **云端场景同步**：借鉴 Apollo Studio + Profile 插件的"云端编辑 → 同步 → 本地运行"闭环，AuroraDrive 可建设云端路径/配置仓库，玩家社区共享。

### 11.4 借鉴面板布局与模式

- **自由面板布局**：借鉴 Dreamview Plus 的拖拽 / 复制 / 删除 / 缩放面板，AuroraDrive 可提供"调试布局 / 游戏布局 / 录制布局"多模式自由切换；
- **模式预设**：默认 / 感知 / PnC 三模式思想 → AuroraDrive 可设计"辅助驾驶模式 / 调试模式 / 回放模式"；
- **中英文 + 新人引导**：直接借鉴，降低上手门槛。

### 11.5 借鉴 PnC 调试闭环

- **参数 → 重启模块 → 重发请求 → SR 观察 → Monitor 曲线**的闭环，可作为 AuroraDrive 调参工作流模板；
- **PnC Monitor 思想**：实时曲线 + 状态量 + 误差展示，AuroraDrive 调试面板可直接套用。

### 11.6 借鉴 ADFM 可解释性思路

- 若 AuroraDrive 接入端到端模型（如 openpilot supercombo），可借鉴 Dreamview Plus 在 10.0 中对 ADFM 的可解释性可视化：环境信息分层渲染 + 单轨迹 + 安全冗余状态展示 + 回放因果分析；
- 端到端模型不可解释时，SR 的"环境理解可视化"是建立用户信任的关键。

### 11.7 前端工程改进方向（具体）

1. **从 webpack 迁移到 Vite**（若尚未）：热更新与构建速度提升，与 Dreamview Plus 对齐；
2. **TypeScript 全面覆盖**：面板组件、WebSocket 服务、状态管理全量 TS；
3. **WebSocket 数据流封装**：参考 Dreamview Plus 的 `services/` 层，封装 channel 名分发 + WebWorker 解析 + Three.js 渲染的数据流；
4. **SimulationWorld 抽象**：借鉴后端 `SimulationWorldService`，在前端维护一个统一的"游戏世界对象"，所有面板订阅该对象，避免多面板各自请求；
5. **面板组件化**：每个功能（SR 3D、小地图、速度曲线、模块控制）独立可拖拽组件，配合自由布局引擎；
6. **国际化 i18n**：中英文切换框架预埋；
7. **Tauri 侧**：用 Rust 实现"插件加载器 + 统一命令接口 + 配置中心"，对应 Apollo 后端的 `PluginManager` + `external_command` + `conf/`。

---

## 十二、关键结论

1. **Dreamview Plus 不是简单 UI 重做**，而是 Apollo 工具链从"模块可视化"向"模式化开发工作流 + 插件化扩展 + 云端资源协同"的范式跃迁，其背后是感知 2.0 / PnC 2.0 / CyberRT 插件化机制的全面成熟。
2. **SR 可视化的核心升级**是"多传感器同屏 + 多视角 + 自由面板 + 图表数据点查看"，这些都能直接迁移到 AuroraDrive。
3. **插件化机制**（PluginManager + 注册宏 + XML 描述 + 延迟加载 + 配置驱动）是 Apollo 9.0/10.0 的工程基石，AuroraDrive 的"多游戏适配"可完整借鉴。
4. **在线编辑能力**（Route Editing + 测距 + 复制坐标 + 云端场景同步）对 AuroraDrive 的路径脚本化与社区共享具有直接参考价值。
5. **ADFM 在 Dreamview Plus 中的可视化**预示了端到端时代 SR 的演进方向——从分段渲染走向一体化环境理解 + 单轨迹 + 安全冗余展示，AuroraDrive 若接入端到端模型应提前布局。
6. AuroraDrive 与 Dreamview Plus 前端栈（React + Three.js）天然对齐，是所有车企 SR 调研对象中最易直接借鉴工程实现的参照系。

---

## 参考来源

- Apollo 官方文档：Dreamview 简介 / 使用 Dreamview 查看数据包（developer.apollo.auto）
- CSDN：Apollo 9.0 应用实践-Dreamview（KJuncle）；Apollo 应用实践之 Dreamview+ 快速使用（yusheng_xyb）；探索全新 Dreamview+（tutututu12345678）；Apollo 插件化机制详解（u010632343）；Apollo Beta 版重磅发布（Derek_Robbie）；Apollo 自动驾驶平台代码结构和源码分析（zhumin726）；01.Apollo10.0 系统概览（qq_31762031）；Apollo 9.0 Dreamview Debug 方法（CSDNhuaong）；DreamView 数据通信机制（O_MMMM_O）；Apollo Dreamview+ 之 Studio 插件安装（yusheng_xyb）；Apollo 开发-Profile 插件安装指南（2301_77162163）；Apollo 开放平台 9.0 更新（Janeiskangs）
- 腾讯云开发者社区：百度 Apollo 自动驾驶全新工具 Dreamview+；Apollo 新版本 Beta 全新的 Dreamview+；本地调试仿真；Apollo 开放平台 9.0 让自动驾驶开发者轻松上手
- 阿里云开发者社区：Apollo 开放平台 9.0 全新升级；Apollo 自动驾驶 Beta 版发布
- 百度百科：Apollo ADFM（全球首个支持 L4 级自动驾驶的大模型）
- GitHub：ApolloAuto/apollo（modules/dreamview_plus、modules/dreamview、modules/planning/scenarios）
- 头条：一周实现自动驾驶实车闭环！百度发布 Apollo 开放平台 9.0；百度发布 Apollo 开放平台 9.0：代码调试量减少 80%；Apollo 开放平台 10.0 即将发布

---

> 实际工具调用次数：56 次（WebSearch 27 次 + WebFetch 19 次 + Read 3 次 + LS 1 次 + TodoWrite 3 次 + Write 1 次 + 源码路径核对 2 次）
> 报告字数：约 6800 字（中文）
