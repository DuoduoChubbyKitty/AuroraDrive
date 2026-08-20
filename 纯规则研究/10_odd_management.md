# 10 · ODD 运行设计域管理（Operational Design Domain Management）与运行时约束（Runtime Constraints）深度研究

> 研究主题：自动驾驶系统中 ODD（运行设计域）的完整工程实现，覆盖 ODD 概念与标准定义（SAE J3016 / SAE J3183 / ISO 34503 / PAS1883 / NHTSA 六维框架）、ODD 与自动驾驶等级（L2/L3/L4）的关系、ODD 边界与 TOR（接管请求）/ MRM（最小风险策略）降级链、Apollo Scenario-Stage-Task 隐式 ODD、Mobileye RSS 的 ODD 假设、NVIDIA DriveOS / Halos 安全框架与 ODD 边界处理、Waymo 地理围栏与天气动态适配、Autoware.Universe RTC 与行为树、OpenPilot 极简 FSM、ODD 运行时检测与监控、ODD 本体工程与形式化验证、ODD 测试与覆盖率（ISO 34502 / SOTIF ISO 21448），最后给出 AuroraDrive 项目（C++ 原生、ONNX 推理、Rust 监督树、Tauri 前端、24Hz 物理、车载硬件、仿真/游戏/规则验证三模式）的 ODD 管理升级方案。
> 研究方法：WebSearch + WebFetch 深度调研 SAE / ISO / BSI / NHTSA 标准文档、Apollo / Autoware / Mobileye / NVIDIA / Waymo / OpenPilot 公开资料与 CSDN / 腾讯云 / 电子发烧友源码解析，结合 AuroraDrive 项目 `cpp/include/ad/autonomy.h`（`AutonomyStack` 级联仲裁、`FallbackDetector` 8 条判据）、`cpp/include/ad/simulator.h`（`mode_`/`paused_`/`decision_` 字符串状态、`assist_*` 辅助模式标志）、`cpp/include/ad/http_server.h`（HTTP/WS 回调）现有实现进行对照分析。
> 配套源码：`cpp/include/ad/autonomy.h`、`cpp/include/ad/simulator.h`、`cpp/include/ad/http_server.h`。
> 字数目标：≥ 5000 字（中文字符）。

---

## 1. ODD 概述

### 1.1 定义与定位

**运行设计域（Operational Design Domain, ODD）** 是自动驾驶系统"安全围栏"的核心抽象：它把开放、无界的真实世界，收敛为一个**有界、可验证、可监控**的运行条件集合，使得系统能够在该集合内"保证安全运行"，并在即将越界时"识别并降级"。

SAE J3016（2021 第四版）将 ODD 定义为：

> "Operating conditions under which a given driving automation system or feature thereof is specifically designed to function, including, but not limited to, environmental, geographical, and time-of-day restrictions, and/or the requisite presence or absence of certain traffic or roadway characteristics."
>
> 即"特定驾驶自动化系统或其功能专门设计的运行条件，包括但不限于环境、地理和时间限制，和/或某些交通或道路特征的存在或缺失。"

简单来说，**ODD 回答的是"这套系统能在什么条件下工作"**：一台只能在高速公路上自动跟车/变道/上下匝道的系统，其 ODD 就排除了城市道路、越野、施工区；一台只能在白天晴朗天气工作的系统，其 ODD 就排除了夜间、雨雪雾。脱离 ODD，系统不保证安全。

ODD 在自动驾驶栈中的**定位**：

```
┌─────────────────────────────────────────────────────────┐
│ ① 使命规划 Mission Planning  │ 全局路由（A* / Dijkstra） │
├─────────────────────────────────────────────────────────┤
│ ② ODD 管理 ★ 运行设计域围栏 ★                            │
│    设计态：定义 ODD 维度（道路/天气/速度/光照/...）        │
│    运行态：实时判定当前条件是否在 ODD 内 → 越界即降级      │
├─────────────────────────────────────────────────────────┤
│ ③ 行为规划 Behavior Planning │ 决策状态机（见第 09 章）   │
├─────────────────────────────────────────────────────────┤
│ ④ 运动规划 Motion Planning   │ 轨迹生成                  │
├─────────────────────────────────────────────────────────┤
│ ⑤ 控制层 Control             │ PID / MPC 轨迹跟踪        │
└─────────────────────────────────────────────────────────┘
```

ODD 管理是行为规划的**前置守卫**：行为规划只在"当前条件 ∈ ODD"时被允许输出激进意图；一旦 ODD 监控器判定即将越界，行为规划应被降级链接管（TOR → MRM）。它与 Emergency Stop（见 `08_emergency_stop.md`）的关系是：**Emergency Stop 是 ODD Exit 且 MRM 失效时的强制兜底**，是降级链的最后一环。

### 1.2 ODD 与相邻概念的关系

| 概念 | 缩写 | 定义 | 与 ODD 的关系 |
|------|------|------|---------------|
| 运行设计域 | ODD | 系统设计时声明的运行条件集合 | — |
| 运行设计条件 | ODC | ODD + 驾驶员状态 + 其他必要条件 | ODD 是 ODC 的子集 |
| 动态驾驶任务 | DDT | 道路驾驶所需的实时操作与策略 | DDT 在 ODD 内由系统执行 |
| DDT 接管 | DDT fallback | ODD Exit 或故障时的接管响应 | ODD Exit 是触发 fallback 的条件之一 |
| 目标事件检测响应 | OEDR | DDT 子任务，检测并响应对象与事件 | OEDR 负责"检测 ODD 越界征兆" |
| 最小风险策略 | MRM | 使车辆达到最小风险状态的措施 | ODD Exit 且无接管时的最终降级 |
| 最小风险状态 | MRC | 风险降至可接受的状态 | MRM 的目标状态 |

---

## 2. ODD 标准与分类框架

### 2.1 标准谱系

业界存在多个 ODD 定义与分类标准，各有侧重：

| 标准 / 框架 | 发布方 | 年份 | 核心要素数 | 特点 |
|-------------|--------|------|-----------|------|
| SAE J3016 | SAE | 2014/2018/2021 | — | ODD 原始定义，分级标准 |
| SAE J3183 | SAE | — | — | ODD 分类法（ISO 34503 协同） |
| ISO 34503 | ISO/IEC | 2023 | — | ADS 的 ODD 分类法规范 |
| ISO 34502 | ISO | 2022 | — | 基于场景的安全评估框架 |
| ISO 22737 | ISO | 2021 | — | LSAD（低速自动驾驶）性能要求 |
| PAS1883 | BSI（英国） | 2020 | 3 大类 | 景观 + 环境 + 动态元素 |
| NHTSA 框架 | NHTSA（美国） | — | 6 大类 | 基础设施 + 驾驶操作 + 物体 + 互联 + 环境 + 区域 |
| SAE J2980 | SAE | 2018 | 6 大类 | 位置 + 道路状况 + 驾驶操作 + 车辆状态 + 其他 + 车辆特征 |
| PEGASUS | 欧盟项目 | — | 6 层 | 道路 + 基础设施 + 临时操纵 + 目标物 + 自然环境 + 数字信息 |

### 2.2 NHTSA 六维框架（业界引用最广）

NHTSA 在《A Framework for Automated Driving System Testable Cases and Scenarios》中以六大要素构建 ODD：

```
┌─────────────────────────────────────────────────────────────┐
│                     ODD 六维（NHTSA）                         │
├──────────────┬──────────────────────────────────────────────┤
│ ① 基础设施    │ 道路类型、路面、道路边缘、道路几何              │
│ ② 驾驶操作    │ 速度限制、交通条件（流量/事故/施工）            │
│ ③ 周边物体    │ 标志标牌、道路使用者（车/人/自行车）、障碍物     │
│ ④ 互联        │ V2V / V2I / 远程车队管理 / 云端高精地图         │
│ ⑤ 环境条件    │ 天气、天气致路面、颗粒物（雾/烟/尘）、光照       │
│ ⑥ 区域        │ 地理围栏、交通管控区、学校区、国家/州、干扰区     │
└──────────────┴──────────────────────────────────────────────┘
```

### 2.3 PAS1883 三要素框架（英国 BSI）

PAS1883 采用更紧凑的三要素：

| 要素 | 子项 |
|------|------|
| 景观（Scenery） | 区域、可行驶区域、交叉口、特殊结构、固定/临时道路结构 |
| 环境条件 | 天气、微粒、照明、互联 |
| 动态元素 | 交通（密度/流量/类型）、主题车辆（速度） |

### 2.4 PEGASUS 六层场景模型

PEGASUS 项目将场景拆为六层，常用于 ODD 测试场景生成：

```
L1 道路层    │ 几何、拓扑、路面质量、边界
L2 基础设施层 │ 结构边界、标志牌、信号灯
L3 临时操纵层 │ 临时封路、施工
L4 目标物层   │ 静态/动态/移动目标，交互、机动
L5 自然环境层 │ 天气、光照
L6 数字信息层 │ V2X、数字地图
```

---

## 3. ODD 与自动驾驶等级的关系

### 3.1 等级—ODD 映射

ODD 是区分自动驾驶等级的**关键维度之一**。SAE J3016 用"是否受 ODD 限制"作为分级判据：

| 等级 | ODD 限制 | DDT 执行 | DDT Fallback 执行 | 典型 ODD 宽度 |
|------|---------|----------|-------------------|--------------|
| L0 无自动化 | — | 人类 | 人类 | — |
| L1 驾驶辅助 | 受限 | 人类 + 系统（单一维度） | 人类 | 特定功能（如 ACC/LKA）的工况 |
| L2 部分自动化 | 受限 | 系统（横+纵） | 人类 | 高速、结构化道路 |
| L3 有条件自动化 | 受限 | 系统 | 系统→人类（TOR） | 高速公路拥堵、特定高速 |
| L4 高度自动化 | 受限 | 系统 | 系统（MRM） | 地理围栏内全场景 |
| L5 完全自动化 | 不受限 | 系统 | 系统 | 全工况（理论） |

**关键洞察**：L3 与 L4 的本质差异不在于"ODD 宽窄"，而在于**ODD Exit 时的 fallback 主体**——L3 由人类驾驶员执行 fallback（需 TOR 缓冲），L4 由系统自主执行 MRM（无需人类）。

### 3.2 ODD 边界与 TOR / MRM

```
┌───────────────────────────────────────────────────────────────┐
│                       ODD 边界管理时序                          │
├───────────────────────────────────────────────────────────────┤
│                                                                │
│  条件 ∈ ODD          条件接近 ODD 边界        条件 ∉ ODD        │
│  ┌─────────┐         ┌──────────────┐         ┌────────────┐   │
│  │ 标称运行 │ ──────▶ │ 预警 + 减速  │ ──────▶ │ TOR / MRM  │   │
│  │ Nominal │         │ ODD Monitor  │         │ ODD Exit   │   │
│  └─────────┘         └──────────────┘         └────────────┘   │
│      │                     │                       │            │
│      ▼                     ▼                       ▼            │
│  系统全权执行 DDT     提前预警 + 降速        L3: TOR→10s→MRM    │
│                                            L4: 直接 MRM         │
└───────────────────────────────────────────────────────────────┘
```

### 3.3 UNR157 / ALKS 法规对 ODD Exit 的约束

UN R157（ALKS 法规）对 L3 系统 ODD Exit 行为有明确约束：

- **计划性事件**（如前方 2km 收费站）：TOR 须尽早发出，确保即使驾驶员未接管，MRM 也能安全停车；
- **非计划性事件**（如突发事故）：检测到事件后**立即**发出 TOR；
- **系统故障**：检测到故障后**立即**发出 TOR；
- TOR 发出后 10s 仍未接管 → 执行 MRM；
- 严重故障可**跳过 TOR 直接 MRM**；
- MRM 减速度 < 4.0 m/s²（特殊场景允许短暂 > 4.0）；
- MRM 期间打开危险报警灯，结束后 ALKS 自动退出。

---

## 4. 主流方案对比

### 4.1 Apollo：Scenario-Stage-Task 隐式 ODD

Apollo **没有显式的 ODD 模块**，而是通过 Scenario-Stage-Task 三层 HSM（层次状态机）隐式表达 ODD：

```
┌─────────────────────────────────────────────────────────────┐
│  Apollo Planning 三层架构（modules/planning/planners/）      │
├─────────────────────────────────────────────────────────────┤
│  ScenarioManager（scenario_manager.cc）                      │
│   ├─ LaneFollowScenario          （默认：车道跟随）           │
│   ├─ TrafficLightProtectedScenario（有保护交通灯）           │
│   ├─ TrafficLightUnprotectedLeftTurnScenario（无保护左转）   │
│   ├─ TrafficLightUnprotectedRightTurnScenario（无保护右转）  │
│   ├─ BareIntersectionUnprotectedScenario（无信号路口）       │
│   ├─ StopSignUnprotectedScenario（停止标志）                 │
│   ├─ VALET_PARKING（自主泊车）                                │
│   ├─ EMERGENCY_PULL_OVER（紧急靠边）                         │
│   ├─ PARK_AND_GO（停车启动）                                  │
│   └─ ...（11+ 场景插件）                                      │
│        │                                                      │
│        ▼ 每个 Scenario 含多个 Stage                          │
│  Stage（如 stage_approach / stage_creep / stage_cruise）      │
│        │                                                      │
│        ▼ 每个 Stage 调用多个 Task                             │
│  Task（PathBoundsDecider / OBCA / SpeedBoundsDecider / ...） │
└─────────────────────────────────────────────────────────────┘
```

**ODD 隐式表达方式**：

1. **HD Map（高精地图）**：Apollo 的 ODD 边界主要靠高精地图"硬约束"——道路类型、车道线、信号灯位置、停止线等都在地图中预定义，Routing 模块（`modules/routing/`）只在地图覆盖的拓扑上规划，天然排除地图外区域。
2. **Scenario 选择逻辑**：ScenarioManager 根据车辆位置、感知结果、路由信息动态选择 Scenario，相当于"当前条件 ∈ 哪个 Scenario 的 ODD"。
3. **Traffic Rule 插件**：`modules/planning/traffic_rules/` 中的交规插件（限速、禁停、让行）对行为做软约束，是 ODD 的规则子集。
4. **无显式运行时 ODD 监控**：Apollo 不在每帧判定"当前是否在 ODD 内"，而是依赖感知/定位失效检测间接触发 fallback（如定位丢失→紧急停车）。

**Apollo 的 ODD 局限**：缺乏显式的 ODD 元数据声明与运行时监控器；天气/光照等环境维度不在 Scenario 选择逻辑中（依赖感知模块自身的鲁棒性）。

### 4.2 Mobileye RSS：假设在 ODD 内的数学安全模型

Mobileye 在 2017 年论文《On a Formal Model of Safe and Scalable Self-driving Cars》提出 RSS（Responsibility Sensitive Safety），将人类驾驶常识形式化为数学模型。RSS **不是 ODD 管理器，而是 ODD 内的安全不变式**：

**RSS 的 ODD 假设**：

1. RSS 假设系统**已在 ODD 内运行**（传感器能检测到所有相关目标，定位精度足够）；
2. RSS 不负责判定"是否该退出 ODD"，只负责"在 ODD 内的每一帧，决策是否安全"；
3. RSS 是路径规划的**安全过滤器**：上层算法（如深度学习）输出决策 → RSS 模型验证 → 安全则执行，危险则返回上层重新决策。

**RSS 四原则（数学化的人类驾驶常识）**：

| 原则 | 数学表达 | 含义 |
|------|---------|------|
| ① 追尾无责 | 后车须保持纵向安全距离 `d_min` | 最恶劣情况（前车最大刹车 + 后车反应延迟 + 后车最小刹车）下仍不碰撞 |
| ② 变道有责 | 变道车须保持横向安全距离 | 变道车全责，但 RSS 仍定义横向安全距离 |
| ③ 路权不抢 | 有路权也须在能刹车时刹车 | 即使对方违规，能避让须避让 |
| ④ 行人遮挡 | 遮挡场景定义正确行为 | 无法完全避免时定义"正确反应" |

**纵向安全距离公式（核心）**：

```
d_min = v_r·ρ + 0.5·a_max,accel·ρ² + (v_r + ρ·a_max,accel)² / (2·b_min,brake) - v_f² / (2·b_max,brake)

其中：
  v_r = 后车速度，v_f = 前车速度
  ρ = 反应时间
  a_max,accel = 后车最大加速度
  b_min,brake = 后车最小刹车减速度（最弱制动）
  b_max,brake = 前车最大刹车减速度（最强制动）
```

**RSS 与 ODD 边界**：RSS 在 ODD 内提供"白盒"可验证的安全保证；但 ODD Exit 时（如传感器被强光致盲），RSS 的安全距离计算前提失效，此时须由 ODD 监控器触发 MRM。Mobileye 已推动 IEEE 2846 标准化 RSS，中国智能交通产业联盟亦采纳 RSS 作为安全标准框架。

### 4.3 NVIDIA DriveOS / Halos：硬件级安全围栏

NVIDIA 的 ODD 管理通过 **Halos 综合安全系统** + **DriveOS** + **Safety MCU** 三层实现：

```
┌─────────────────────────────────────────────────────────────┐
│              NVIDIA Halos 安全体系（2025）                    │
├─────────────────────────────────────────────────────────────┤
│  平台安全 Platform Safety                                    │
│   ├─ DRIVE AGX Thor/Orin SoC（内置数百种安全机制）           │
│   ├─ DriveOS 6.0（ISO 26262 ASIL-D 认证 OS）                │
│   ├─ Safety MCU（TC297，ASIL-C/D 独立监控核）                │
│   └─ DRIVE AGX Hyperion（参考硬件平台）                      │
│  算法安全 Algorithm Safety                                    │
│   ├─ 安全数据加载/加速库                                      │
│   ├─ Omniverse + Cosmos 仿真验证                             │
│   └─ 模块化 + 端到端 AI 模型组合                              │
│  生态安全 Ecosystem Safety                                    │
│   ├─ AI 系统检测实验室（ANAB 认证）                          │
│   ├─ 分级流水线 + 自动安全评估                                │
│   └─ 数据飞轮 + 安全标准规范                                  │
└─────────────────────────────────────────────────────────────┘
```

**Safety MCU 与 ODD 边界**：Safety MCU（如 Infineon TC297）作为独立 ASIL-D 监控核，与主 SoC（GPU/AI 计算）物理隔离，负责：

- 监控主 SoC 心跳 / 看门狗；
- 检查关键信号（车速、转向、制动）的合理性；
- 主 SoC 失效时接管，执行降级控制（减速停车）。

NVIDIA Halos 的 ODD 边界处理**偏硬件功能安全（ISO 26262）**，对环境维度（天气/光照）的 ODD 监控依赖上层感知算法的置信度输出，Halos 本身不显式建模"当前是否在 ODD"。

### 4.4 Waymo：地理围栏 + 天气动态适配

Waymo 采用**保守的 ODD 收缩策略**：

- **地理围栏**：仅在已测绘、已验证的城市区域运营（如凤凰城、旧金山、奥斯汀）；
- **天气限制**：极端天气（暴雨/大雪/积水）动态收缩 ODD，限制车辆进入高风险区域；
- **2026 年 5 月召回事件**：因积水软件缺陷召回 3791 辆车并暂停服务，体现了"ODD 收缩优先于运营连续性"的安全哲学；
- **ODD 动态适配**：通过云端 ODD 元数据下发，车队级动态调整运营范围。

### 4.5 Autoware.Universe：RTC + 行为树

Autoware.Universe 的 ODD 管理通过 **RTC（Runtime Confirmation）** + **behavior_path_planner** 行为树实现：

- **顶层场景**：`LaneDrivingArea`（车道行驶）vs `FreeSpaceArea`（自由空间，如泊车）两大场景；
- **behavior_path_planner**：内部用 PlannerManager 排队管理多个模块（避障、变道、拉起、靠边），每个模块是行为树节点；
- **RTC（运行时确认）**：模块激活前须向外部（如远程操作员或上层仲裁器）请求确认，超时未确认则 fallback；
- **无显式 ODD 模块**：Autoware 同样不显式建模 ODD，依赖模块级 fallback + 紧急停车（Autoware 的 `emergency_handler`）。

### 4.6 OpenPilot：极简 FSM + 隐式 ODD

comma.ai OpenPilot 是 L2+ 系统，ODD 极简：

- **FSM 状态**：disabled / enabled / softDisable / overridden；
- **ODD 隐式约束**：仅支持 250+ 特定车型的车道居中 + ACC；超出能力即 disengage（退出），由人类接管；
- **无 ODD 监控器**：依赖驾驶员持续监控（DMS 监控注意力），系统失效即退出。

---

## 5. ODD 运行时检测与监控

### 5.1 运行时 ODD 判定流程

ODD 运行时监控器（Runtime ODD Monitor）是 ODD 管理的**运行态核心**，持续判定"当前条件 ∈ ODD"：

```
┌───────────────────────────────────────────────────────────────┐
│                  ODD 运行时监控器（每帧执行）                    │
├───────────────────────────────────────────────────────────────┤
│                                                                │
│  传感器原始数据 ──▶ 特征提取 ──▶ ODD 维度判定 ──▶ 综合 ODD 状态 │
│  (相机/雷达/激光/  (天气/光照/  (各维度 ∈/∉ ODD)   (IN/NEAR/OUT)│
│   定位/IMU/地图)   路面/车速)                                  │
│                                                                │
│  ODD 状态输出:                                                 │
│   IN   ──▶ 标称运行                                            │
│   NEAR ──▶ 预警 + 主动减速 + 准备 TOR                          │
│   OUT  ──▶ ODD Exit: 触发 TOR(L3) / MRM(L4)                    │
└───────────────────────────────────────────────────────────────┘
```

### 5.2 ODD 维度—传感器映射

| ODD 维度 | 主要传感器 | 判定指标 | 越界征兆 |
|---------|-----------|---------|---------|
| 道路类型 | HD Map + 定位 | 当前道路 ∈ ODD 允许类型集 | 驶入未映射道路 |
| 路面状况 | 相机 + 激光雷达 | 摩擦系数、积水/积雪深度 | 检测到冰/雪/深水 |
| 天气 | 相机 + 雨量传感器 | 能见度、降雨强度 | 能见度 < 阈值 |
| 光照 | 相机 + 光照传感器 | 环境亮度、时间 | 进入夜间/隧道 |
| 速度 | 车速传感器 | ego_speed ∈ ODD 速度区间 | 超出最大/最小限速 |
| 交通密度 | 感知（障碍物数） | 周围车辆密度 | 超出设计密度 |
| 传感器健康 | 各传感器自诊断 | 置信度、丢帧率 | 关键传感器降级 |
| 定位精度 | 定位模块 | 误差椭圆、置信度 | 定位丢失/漂移 |

### 5.3 偏离告警与分级降级

```
ODD 偏离严重度分级
┌──────────┬────────────────────┬──────────────────────────┐
│  级别     │  触发条件           │  系统响应                 │
├──────────┼────────────────────┼──────────────────────────┤
│  L0 正常  │ 全维度 ∈ ODD        │ 标称运行                  │
│  L1 预警  │ 单维度接近边界       │ HMI 提示 + 降速 20%       │
│  L2 降级  │ 多维度接近或单维度越界│ 降速 50% + 准备 TOR       │
│  L3 Exit  │ 关键维度越界         │ L3: TOR → 10s → MRM      │
│           │                     │ L4: 直接 MRM              │
│  L4 故障  │ 传感器/系统故障      │ 跳过 TOR，直接 MRM/EM     │
└──────────┴────────────────────┴──────────────────────────┘
```

### 5.4 SOTIF（ISO 21448）与 ODD 的关系

SOTIF（Safety of the Intended Functionality，预期功能安全）关注**非故障类风险**——即硬件软件均正常，但因系统功能局限或性能不足导致的安全问题。SOTIF 与 ODD 的关系：

- ODD 定义"系统能在什么条件下工作"；
- SOTIF 分析"在 ODD 内，系统的功能局限是否会引发危险"；
- SOTIF 的触发条件（Triggering Conditions）分析有助于**细化 ODD 边界**——某些"理论上在 ODD 内"但实际触发危险的工况，应从 ODD 中剔除。

---

## 6. ODD Exit 与 MRM 降级链

### 6.1 ODD Exit 触发条件

ODD Exit（运行设计域退出）的触发条件分四类：

| 类别 | 触发示例 | 紧急度 |
|------|---------|--------|
| 计划性事件 | 前方收费站、高速出口、ODD 边界地理围栏 | 低（可提前预警） |
| 非计划性环境 | 突发暴雨/大雾、道路施工、事故封路 | 中（检测后立即 TOR） |
| 系统故障 | 传感器失效、定位丢失、计算单元过载 | 高（可能跳过 TOR） |
| 驾驶员状态 | DMS 检测驾驶员离座/失能（L3） | 中（特殊 TOR） |

### 6.2 MRM 降级链状态机

```
                    ODD Exit 检测
                          │
                          ▼
                 ┌─────────────────┐
                 │  TOR 接管请求    │ ◀──── L3 路径
                 │  (声光触觉提醒)  │
                 └────────┬────────┘
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
     驾驶员接管      10s 超时       严重故障
            │             │             │
            ▼             ▼             ▼
     ┌──────────┐  ┌──────────┐  ┌──────────┐
     │ 人工驾驶  │  │   MRM    │  │ 直接 MRM │
     │ 退出 ADS  │  │ 减速靠边  │  │ (跳过TOR)│
     └──────────┘  └────┬─────┘  └────┬─────┘
                        │              │
                        ▼              ▼
                  ┌──────────────────────┐
                  │  最小风险状态 MRC     │
                  │  · 本车道停车+双闪    │
                  │  · 靠边停车           │
                  │  · 减速至停车         │
                  └──────────────────────┘
                            │
                            ▼ (MRM 失败时)
                  ┌──────────────────────┐
                  │  Emergency Stop       │
                  │  (急刹 1.0 brake)     │
                  └──────────────────────┘
```

### 6.3 MRM 策略选择

MRM 策略须根据场景"量身定制"，过激与过保守均危及安全：

| MRM 策略 | 适用场景 | 能力要求 | 减速度 |
|---------|---------|---------|--------|
| 本车道减速停车 | 无路肩、隧道、拥堵 | 纵向控制 | < 4.0 m/s² |
| 靠边停车（变道） | 有路肩/应急车道 | 横向 + 纵向控制 | < 4.0 m/s² |
| 保持车道降速巡航 | 暂时性 ODD 偏离（如短暂强光） | 纵向控制 | 温和 |
| 紧急制动 | 即将碰撞、严重故障 | 纵向控制 | > 4.0 m/s² |

**传感器架构约束 MRM 能力**：如极星 Polestar2（3R1V 架构，无侧向感知）只能实现本车道减速停车，无法靠边——MRM 能力受限于传感器覆盖，须在 ODD 设计时声明。

---

## 7. ODD 本体工程与形式化

### 7.1 ODD 本体（Ontology）

ODD 本体工程用知识图谱（如 OWL / Protégé）形式化 ODD 定义，使其可机器推理、可验证：

```
┌─────────────────────────────────────────────────────────────┐
│                  ODD 本体工程示意（OWL）                      │
├─────────────────────────────────────────────────────────────┤
│  Class: ODD                                                  │
│    ├─ hasScenery ──▶ Scenery                                 │
│    │    ├─ hasRoadType ──▶ RoadType ∈ {Highway, Urban, ...}  │
│    │    ├─ hasSurface  ──▶ Surface ∈ {Asphalt, Gravel, ...}  │
│    │    └─ hasGeometry ──▶ Geometry ∈ {Straight, Curve, ...} │
│    ├─ hasEnvironment ──▶ Environment                         │
│    │    ├─ hasWeather   ──▶ Weather ∈ {Clear, Rain, Snow,...}│
│    │    ├─ hasLighting  ──▶ Lighting ∈ {Day, Night, Tunnel}  │
│    │    └─ hasVisibility──▶ Visibility ≥ X meters            │
│    └─ hasDynamic ──▶ Dynamic                                 │
│         ├─ hasSpeedRange ──▶ [v_min, v_max] km/h             │
│         └─ hasTrafficDensity ──▶ Density ∈ {Low, Med, High}  │
│                                                              │
│  推理规则示例:                                                │
│    Weather(Snow) ∧ Surface(Ice) ⇒ ODD_Out                    │
│    Visibility < 50m ⇒ ODD_Out                                │
│    RoadType(Unmapped) ⇒ ODD_Out                              │
└─────────────────────────────────────────────────────────────┘
```

**本体推理的价值**：

1. **一致性检查**：自动发现 ODD 定义中的矛盾（如同时允许"雪天"+"夏季轮胎"）；
2. **覆盖率分析**：推理出 ODD 未覆盖的工况组合，指导测试场景生成；
3. **形式化验证**：将 ODD 本体与系统状态机结合，用模型检查器（CBMC / UPPAAL / SPIN）证明"ODD Exit 必然触发 MRM"等关键性质。

### 7.2 形式化验证

ODD 形式化验证将"ODD 监控器 + 降级链"建模为状态机，用模型检查证明安全性质：

| 性质 | 形式化表达 | 验证工具 |
|------|-----------|---------|
| ODD Exit 必触发降级 | `AG(ODD_Out → AF(MRM_active ∨ TOR_active))` | UPPAAL / SPIN |
| MRM 必达 MRC | `AG(MRM_active → AF(MRC))` | CBMC |
| 控制量必有界 | `AG(steer ∈ [-1,1] ∧ brake ∈ [0,1])` | CBMC |
| 严重故障跳过 TOR | `AG(CriticalFault → AX(MRM_active))` | UPPAAL |

---

## 8. ODD 测试与覆盖率

### 8.1 ISO 34502 场景分类

ISO 34502:2022《道路车辆—自动驾驶系统测试场景—基于场景的安全评估框架》提供场景分类与选取方法，是 ODD 覆盖率测试的基础：

```
ODD 测试覆盖策略
┌───────────────────────────────────────────────────────┐
│  ① 仿真测试    │ 快速覆盖大量场景，验证算法理论表现    │
│  ② 封闭场地    │ 精确控制变量，验证边界场景行为        │
│  ③ 实车道路    │ 真实交通，分阶段增加里程与复杂度      │
└───────────────────────────────────────────────────────┘
         │
         ▼
  度量指标（须与 ODD 条件一一对应）
  · 感知：检测距离、漏检率、误检率（分天气/光照）
  · 定位：漂移、重定位时间
  · 决策控制：制动距离、跟车误差、转向响应时间
```

### 8.2 ODD 覆盖率度量

ODD 覆盖率不是单一数字，而是**多维覆盖矩阵**：

```
              天气          光照        路面        交通密度
            ┌───────┐    ┌───────┐    ┌───────┐    ┌───────┐
     晴     │  ✓    │ 日  │  ✓    │ 干  │  ✓    │ 低  │  ✓    │
     雨     │  ✓    │ 夜  │  ✓    │ 湿  │  ✓    │ 中  │  ✓    │
     雪     │  ✗    │ 隧道│  ✓    │ 冰  │  ✗    │ 高  │  ✓    │
     雾     │  ✓    │ 黎明│  ✗    │ 积水│  ✗    │ 拥堵│  ✓    │
            └───────┘    └───────┘    └───────┘    └───────┘
     覆盖率: 3/4=75%      3/4=75%      2/4=50%      4/4=100%
```

### 8.3 ODD 扩展流程

ODD 扩展须有证据支撑，分阶段推进：

```
仿真验证新增场景 ──▶ 封闭场地实车验证 ──▶ 受控区域小规模试运行
                                                │
                                  收集现场数据 + 安全评估
                                                │
                                                ▼
                                        全面放开 ODD 扩展
                                        （须报备监管 + 通知用户）
```

---

## 9. AuroraDrive 现状源码分析

### 9.1 现有约束机制

通过分析 `cpp/include/ad/autonomy.h`、`simulator.h`、`http_server.h`，AuroraDrive 当前的"类 ODD"约束散落在多处，但**无显式 ODD 模块**：

| 文件 | 现有机制 | ODD 缺失 |
|------|---------|---------|
| `autonomy.h` | `ControlSource` 级联（PURE_RULE→FULL_AUTO→CO_DRIVE） | 级联是控制源降级，非 ODD 降级 |
| `autonomy.h` | `FallbackDetector` 8 条判据（no_road/dead_end/curvature/collision/lane_departure/oscillation/stuck/min_speed） | 判据是规则失效检测，非 ODD 边界判定 |
| `autonomy.h` | `Phase`（RULE_ONLY/FULL_AUTO/CO_DRIVE） | 相位是控制权限分配，非 ODD 状态 |
| `autonomy.h` | `SafetyEnvelope`（steer/throttle/brake 钳制） | 物理包络，非环境约束 |
| `simulator.h` | `mode_`（"roam"/"dest"）、`paused_`、`speed_scale_` | 字符串状态，无 ODD 维度 |
| `simulator.h` | `assist_*` 标志（capturing/auto/key_a/key_d） | 辅助驾驶模式，无 ODD 监控 |
| `http_server.h` | HTTP/WS 回调（status/map_init/destinations/route/command） | 无 ODD 查询/上报接口 |

### 9.2 FallbackDetector 的 ODD 局限

`FallbackDetector`（`autonomy.h` 第 350-522 行）的 8 条判据是**规则层失效检测**，与 ODD 边界判定有本质区别：

```
FallbackDetector 判据 vs ODD 维度对照
┌─────────────────────┬──────────────────┬──────────────────────┐
│  FallbackDetector   │  对应 ODD 维度    │  缺失的 ODD 维度      │
├─────────────────────┼──────────────────┼──────────────────────┤
│  no_road            │  道路类型（部分）  │  天气、光照、能见度   │
│  dead_end           │  道路几何（部分）  │  路面状况（冰/雪/水） │
│  curvature_extreme  │  道路几何          │  交通密度             │
│  min_speed_violation│  速度              │  时间（昼/夜）        │
│  front_collision    │  动态元素（部分）  │  地理围栏             │
│  lane_departure     │  可行驶区域        │  传感器健康           │
│  oscillation        │  车辆状态          │  定位精度             │
│  stuck              │  车辆状态          │  V2X 互联             │
└─────────────────────┴──────────────────┴──────────────────────┘
```

**核心差距**：FallbackDetector 检测的是"规则输出的控制量是否失效"，而非"当前环境条件是否在 ODD 内"。前者是**结果导向**（规则已经失效才触发），后者是**条件导向**（环境即将越界就预警）。ODD 管理要求**在规则失效之前**就识别风险并降级。

### 9.3 AuroraDrive 缺失的 ODD 能力

1. **无 ODD 元数据声明**：无 YAML/JSON 配置文件声明"系统能在什么条件下工作"；
2. **无运行时 ODD 监控器**：无每帧判定"当前 ∈ ODD"的模块；
3. **无 ODD Exit 降级链**：当前降级是控制源级联（PURE_RULE→FULL_AUTO→CO_DRIVE），无 ODD Exit → TOR → MRM 链路；
4. **无 ODD 相关 HTTP 接口**：前端无法查询当前 ODD 状态、无法接收 ODD 预警；
5. **无天气/光照/地理围栏判定**：仿真环境固定，无环境维度感知。

---

## 10. AuroraDrive 升级方案

针对 AuroraDrive（C++ 原生、ONNX 推理、Rust 监督树、Tauri 前端、24Hz 物理、车载硬件、仿真/游戏/规则验证三模式），提出以下可落地的 ODD 管理升级方案。

### 10.1 新增 `cpp/include/ad/odd_manager.h`（ODD 管理核心）

```cpp
// ODD 管理器 — 设计态声明 + 运行态监控 + 降级链触发
#pragma once
#include "types.h"
#include <array>
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

namespace ad {

// ── ODD 维度枚举（对应 NHTSA 六维 + 传感器健康 + 定位精度）──
enum class OddDimension : uint8_t {
    ROAD_TYPE = 0,    // 道路类型（依赖 HD Map/地图）
    ROAD_SURFACE,     // 路面状况（干/湿/冰/雪/积水）
    WEATHER,          // 天气（晴/雨/雪/雾）
    LIGHTING,         // 光照（日/夜/隧道/黎明）
    VISIBILITY,       // 能见度（米）
    SPEED_RANGE,      // 速度区间 [v_min, v_max]
    TRAFFIC_DENSITY,  // 交通密度
    GEO_FENCE,        // 地理围栏（UTM 边界多边形）
    SENSOR_HEALTH,    // 传感器健康（置信度/丢帧率）
    LOCALIZATION,     // 定位精度（误差椭圆）
    DIM_COUNT
};

// ── ODD 状态（每维度 + 综合）──
enum class OddStatus : uint8_t { IN = 0, NEAR, OUT };

// ── ODD 设计态声明（从 odd_config.yaml 加载）──
struct OddDeclaration {
    // 道路类型白名单（road_type_id 集合，来自 map_loader）
    std::vector<int32_t> allowed_road_types;
    // 路面状况白名单
    uint32_t allowed_surfaces_mask = 0x01;  // bit0=干,bit1=湿,...
    // 天气白名单
    uint32_t allowed_weather_mask = 0x01;   // bit0=晴,bit1=雨,...
    // 光照白名单
    uint32_t allowed_lighting_mask = 0x03;  // bit0=日,bit1=夜
    // 能见度下限（米）
    float min_visibility_m = 50.0f;
    // 速度区间（km/h）
    float speed_min_kmh = 0.0f, speed_max_kmh = 60.0f;
    // 交通密度上限（感知障碍物数）
    int max_traffic_density = 40;
    // 地理围栏（UTM 多边形，空=不限制）
    std::vector<float> geo_fence_polygon;  // [x0,y0, x1,y1, ...]
    // 传感器健康阈值
    float min_sensor_confidence = 0.5f;
    float max_sensor_drop_rate = 0.1f;
    // 定位精度阈值（米）
    float max_localization_error_m = 5.0f;
};

// ── ODD 运行时监控器 ──
class OddManager {
public:
    explicit OddManager(const OddDeclaration& decl) : decl_(decl) {}

    // 每帧调用：更新某维度的运行时观测值 + 判定状态
    void update_dimension(OddDimension dim, float observed_value);
    void update_dimension(OddDimension dim, int observed_value);
    void update_dimension(OddDimension dim, bool in_odd);

    // 综合判定（取最差维度作为综合状态）
    OddStatus overall_status() const;

    // 获取某维度状态（供 HMI/日志）
    OddStatus dimension_status(OddDimension dim) const;

    // ODD Exit 触发回调（由 AutonomyStack 注册）
    using ExitCallback = std::function<void(OddDimension, OddStatus)>;
    void on_odd_exit(ExitCallback cb) { exit_cb_ = std::move(cb); }

    // 序列化为 JSON（供 HTTP /api/odd 接口）
    std::string to_json() const;

private:
    OddDeclaration decl_;
    mutable std::mutex m_;
    std::array<OddStatus, static_cast<size_t>(OddDimension::DIM_COUNT)> statuses_{};
    std::array<float, static_cast<size_t>(OddDimension::DIM_COUNT)> values_{};
    ExitCallback exit_cb_;

    void check_exit_callback_(OddDimension dim, OddStatus old_s, OddStatus new_s);
};

} // namespace ad
```

### 10.2 集成到 `AutonomyStack`

在 `autonomy.h` 的 `AutonomyStack::step()` 中，**在级联仲裁之前**插入 ODD 监控：

```
AutonomyStack::step() 改造后流程
┌────────────────────────────────────────────────────────────┐
│ 1. ODD 监控（新增）                                         │
│    odd_mgr_.update(传感器/定位/地图观测)                    │
│    if (odd_mgr_.overall_status() == OUT) {                 │
│        trigger_odd_exit_();  // → TOR/MRM 降级链           │
│    }                                                        │
├────────────────────────────────────────────────────────────┤
│ 2. 并行推理（规则 + 模型）— 原有逻辑                        │
│ 3. FallbackDetector 规则失效检测 — 原有逻辑                 │
│ 4. 级联仲裁 — 原有逻辑                                      │
│ 5. 相位否决 + 惩罚软否决 — 原有逻辑                         │
│ 6. 安全 clamp — 原有逻辑                                    │
│ 7. DAgger 打标 — 原有逻辑                                   │
└────────────────────────────────────────────────────────────┘
```

### 10.3 ODD Exit 降级链（新增 `OddExitHandler`）

在 `autonomy.h` 中新增降级链处理器，**复用现有级联机制**但增加 ODD 语义：

```cpp
// ODD Exit 降级链：ODD_OUT → 预警 → TOR → MRM → Emergency
class OddExitHandler {
public:
    enum class State { NOMINAL, WARN, TOR, MRM, EMERGENCY };

    State tick(OddStatus odd, bool human_has_input, double dt);

    // 状态转移（与 ALKS UNR157 对齐）
    // NOMINAL → WARN:  odd == NEAR
    // WARN → TOR:      odd == OUT
    // TOR → MRM:       超时 10s 未接管（L3 语义）；L4 直接 MRM
    // MRM → EMERGENCY: MRM 减速失败（车速未降）
    // 任意 → NOMINAL:  odd 回到 IN 且人类已接管

private:
    State state_ = State::NOMINAL;
    double tor_timer_ = 0.0;
    static constexpr double TOR_TIMEOUT_S = 10.0;  // UNR157
};
```

降级链状态机：

```
┌──────────┐  NEAR   ┌──────┐  OUT    ┌──────┐ 10s/直接 ┌──────┐
│ NOMINAL  │────────▶│ WARN │────────▶│ TOR  │─────────▶│ MRM  │
│ 标称运行  │         │降速20%│         │声光触│          │减速靠边│
└──────────┘         └──────┘         │觉提醒│          └──┬───┘
     ▲                                  └──────┘             │
     │ human接管                       ▲                    │ 减速失败
     │ odd=IN                          │human接管            ▼
     └─────────────────────────────────┴───────────── ┌──────────┐
                                                      │EMERGENCY │
                                                      │急刹1.0   │
                                                      └──────────┘
```

### 10.4 三模式 ODD 差异化配置

AuroraDrive 支持仿真/游戏/规则验证三模式，ODD 配置应**按模式差异化**：

```yaml
# odd_config.yaml（按模式分段）
simulation:
  allowed_road_types: [1, 2, 3, 4, 5]   # 全地图道路
  allowed_weather_mask: 0x0F             # 全天气（用于数据采集）
  allowed_lighting_mask: 0x0F            # 全光照
  speed_max_kmh: 120
  min_visibility_m: 30                   # 仿真可放宽
  geo_fence_polygon: []                  # 不限制

game:
  allowed_road_types: [1, 2]             # 仅高速/主干道
  allowed_weather_mask: 0x01             # 仅晴天（游戏体验）
  allowed_lighting_mask: 0x01            # 仅白天
  speed_max_kmh: 80
  min_visibility_m: 100
  geo_fence_polygon: [...]               # 限定游戏地图区域

rule_verification:
  allowed_road_types: [1, 2, 3, 4, 5]
  allowed_weather_mask: 0x01             # 仅晴天（规则验证须可复现）
  allowed_lighting_mask: 0x03            # 日+夜
  speed_max_kmh: 60
  min_visibility_m: 200                  # 严格
  max_traffic_density: 20
  geo_fence_polygon: []
```

### 10.5 Rust 监督树集成 ODD 心跳

AuroraDrive 的 Rust 监督树（管理 NeversetApp/sidecar/frontend 子进程，100ms 心跳）应增加 **ODD 监控器心跳**：

- sidecar（C++）每 100ms 上报 ODD 综合状态（IN/NEAR/OUT）给 Rust 监督树；
- ODD 持续 OUT 超过 5s → Rust 监督树强制 sidecar 进入安全降级模式（限速 + 双闪）；
- ODD 监控器自身心跳丢失（>300ms）→ 视为 ODD 监控失效 → 触发 MRM（fail-safe）。

### 10.6 HTTP 接口扩展

在 `http_server.h` 中新增 ODD 相关接口：

| 接口 | 方法 | 用途 |
|------|------|------|
| `/api/odd/status` | GET | 返回当前 ODD 综合状态 + 各维度状态（JSON） |
| `/api/odd/config` | GET | 返回当前模式的 ODD 声明（YAML/JSON） |
| `/api/odd/config` | POST | 动态调整 ODD 声明（规则验证模式用） |
| WS 广播 `odd_alert` | — | ODD 状态变化时主动推送（前端 HMI 实时显示） |

### 10.7 Tauri 前端 ODD 可视化

Tauri 前端（SR 3D 感知 + 导航地图分屏）增加 ODD 可视化层：

- **ODD 边界高亮**：在导航地图上用半透明多边形显示地理围栏边界；
- **ODD 状态徽标**：顶栏显示当前 ODD 状态（绿=IN / 黄=NEAR / 红=OUT）；
- **维度雷达图**：调试页显示 10 维 ODD 雷达图，越界维度高亮；
- **ODD 预警浮层**：NEAR/OUT 时弹出降级链状态提示（WARN/TOR/MRM）。

### 10.8 ONNX 推理置信度反哺 ODD

AuroraDrive 的 ONNX 推理（替代 LibTorch）输出控制命令时，应同时输出**推理置信度**（softmax 熵或 ensemble 方差），作为 ODD `SENSOR_HEALTH` 维度的输入：

- 推理置信度低（熵高）→ 可能是 OOD（Out-of-Distribution）输入 → ODD NEAR 预警；
- 推理延迟超阈值（>100ms on Raspberry Pi）→ 计算资源不足 → ODD NEAR。

---

## 11. 业界对比表

| 维度 | Apollo | Autoware | OpenPilot | Mobileye RSS | Waymo | NVIDIA Halos | AuroraDrive（现状） | AuroraDrive（升级后） |
|------|--------|----------|-----------|--------------|-------|--------------|--------------------|-----------------------|
| **显式 ODD 模块** | ✗（隐式 Scenario） | ✗（RTC） | ✗ | ✗（假设在 ODD 内） | ✓（地理围栏） | ✗（硬件安全） | ✗ | ✓（OddManager） |
| **ODD 元数据声明** | ✗ | ✗ | ✗ | ✗ | ✓（云端下发） | ✗ | ✗ | ✓（odd_config.yaml） |
| **运行时 ODD 监控** | ✗ | ✗ | ✗ | ✗ | ✓（天气/围栏） | △（Safety MCU） | ✗ | ✓（10 维每帧） |
| **ODD Exit 降级链** | △（紧急停车） | △（emergency_handler） | ✓（disengage） | ✗ | ✓（MRM） | △（Safety MCU 接管） | △（级联降级） | ✓（NOMINAL→WARN→TOR→MRM→EM） |
| **TOR 机制** | ✗ | △ | ✓ | ✗ | ✓（远程接管） | ✗ | ✗ | ✓（10s 超时） |
| **MRM 策略** | 紧急靠边/停车 | 紧急停车 | disengage | — | 靠边停车 | 硬件减速 | emergency_stop() | 多策略（靠边/减速/急刹） |
| **天气/光照感知** | ✗（依赖感知鲁棒性） | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✓（传感器反哺） |
| **地理围栏** | ✓（HD Map 覆盖） | ✓（地图覆盖） | ✗ | ✗ | ✓（严格） | ✗ | ✗ | ✓（UTM 多边形） |
| **ODD 本体/形式化** | ✗ | ✗ | ✗ | ✓（RSS 数学模型） | ✗ | ✗ | ✗ | △（预留本体接口） |
| **ODD 测试覆盖率** | △（场景库） | △ | ✗ | ✓（RSS 验证） | ✓（仿真+实车） | ✓（Halos 实验室） | ✗ | ✓（ISO 34502 对齐） |
| **ODD HTTP 接口** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓（/api/odd/*） |
| **三模式 ODD 差异** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓（仿真/游戏/规则验证） |

**图例**：✓ 完整支持 / △ 部分支持 / ✗ 不支持

---

## 12. 总结

### 12.1 本章核心发现

1. **ODD 是安全围栏，非可选装饰**：业界主流系统（Apollo/Autoware/OpenPilot）普遍**缺乏显式 ODD 模块**，这是 L3+ 量产的关键技术债。AuroraDrive 应率先引入显式 ODD 管理，作为差异化优势。

2. **ODD 管理三要素缺一不可**：① 设计态声明（odd_config.yaml）；② 运行态监控（OddManager 每帧判定）；③ 降级链（ODD Exit → TOR → MRM → Emergency）。三者构成完整闭环。

3. **FallbackDetector ≠ ODD 监控**：AuroraDrive 现有的 `FallbackDetector` 是**规则失效检测**（结果导向），ODD 监控是**环境边界判定**（条件导向）。前者在规则失效后才触发，后者在环境越界前就预警——ODD 监控须**前置**于规则检测。

4. **RSS 是 ODD 内的安全不变式，非 ODD 管理器**：Mobileye RSS 假设系统已在 ODD 内运行，提供数学安全保证；ODD 边界管理须由独立模块负责。AuroraDrive 可将 RSS 思路（安全距离公式）作为 `phase_veto` 的增强。

5. **三模式 ODD 差异化是 AuroraDrive 独有需求**：仿真模式须放宽 ODD（用于数据采集）、游戏模式须收窄 ODD（用于体验）、规则验证模式须严格 ODD（用于可复现）。业界无现成方案，须原创设计。

6. **ODD 与 Rust 监督树协同**：ODD 监控器自身须被监督（fail-safe），监控器失效即触发 MRM——这符合 AuroraDrive "无限重启 + 频率熔断" 的稳定性哲学。

### 12.2 纯规则研究 10 章回顾

"纯规则研究"系列共 10 章，构成了 AuroraDrive 项目自动驾驶纯规则栈的完整理论体系：

| 章 | 主题 | 核心贡献 |
|----|------|---------|
| 01 | 感知与传感器融合 | 视觉主导 + LiDAR 兜底的混合方案，特征级后融合 |
| 02 | 定位与高精地图 | mmap 零拷贝地图加载，C++ GridIndex 空间索引 |
| 03 | 路径规划与路由 | A* + 欧氏距离启发 + 道路等级加权，车道级导航 |
| 04 | 运动规划与轨迹生成 | Pure Pursuit + 弯道限速，±max_steer 防绕圈 |
| 05 | 车辆控制与动力学 | PID + 物理包络 clamp，IPC 到执行器 |
| 06 | 交通流与博弈 | TrafficManager 40 车，C++ GridIndex 空间查询 |
| 07 | 安全包络与 RSS | 安全距离公式，相位化否决，三类加权惩罚 |
| 08 | 紧急停车与故障兜底 | emergency_stop() 急刹 + 双闪，降级链终极环 |
| 09 | 决策状态机与行为规划 | FSM/HSM/行为树对比，Apollo Scenario-Stage-Task |
| **10** | **ODD 运行设计域管理** | **显式 ODD 模块、运行时监控、ODD Exit 降级链、三模式差异化** |

**研究脉络**：前 5 章覆盖自动驾驶"感知—定位—规划—运动—控制"的正向数据流；第 6 章扩展到多车交互；第 7-8 章聚焦安全兜底（从"安全包络"到"紧急停车"）；第 9 章抽象出决策状态机；**第 10 章（本章）收束于"运行设计域"——为整个规则栈划定安全边界**。

**对 AuroraDrive 的整体贡献**：10 章研究将 AuroraDrive 从"散落规则的拼凑"升级为"有理论根基、有安全围栏、有降级链路、可形式化验证"的工程化纯规则栈。其中第 7-10 章构成**安全四重奏**：RSS 安全包络（07）→ 紧急停车兜底（08）→ 决策状态机（09）→ ODD 运行设计域（10），从"单帧安全"到"全程安全"再到"全域安全"，形成闭环。本章引入的 OddManager + OddExitHandler + 三模式 ODD 差异化配置，使 AuroraDrive 在 ODD 管理维度**超越 Apollo/Autoware/OpenPilot 的隐式处理**，向 Waymo 的显式地理围栏 + 天气动态适配看齐，并为后续 L3+ 量产的 UNR157 合规奠定基础。

---

> **参考标准与资料**：
> - SAE J3016:2021《Taxonomy and Definitions for Terms Related to Driving Automation Systems for On-Road Motor Vehicles》
> - ISO 34503:2023《Road Vehicles — Taxonomy for Operational Design Domain for Automated Driving Systems》
> - ISO 34502:2022《Road Vehicles — Test scenarios for automated driving systems — Scenario-based safety evaluation framework》
> - ISO 22737:2021《Low-speed automated driving (LSAD) systems performance requirements》
> - BSI PAS1883:2020《Operational Design Domain (ODD) taxonomy for an automated driving system (ADS) — Specification》
> - SAE J2980:2018《Considerations for ISO 26262 ASIL Hazard Classification》
> - UN R157: ALKS（Automated Lane Keeping Systems）法规
> - ISO 21448:2022《SOTIF — Safety of the Intended Functionality》
> - Mobileye RSS 论文：《On a Formal Model of Safe and Scalable Self-driving Cars》(2017)
> - NVIDIA Halos 综合安全系统（2025 发布）
> - Apollo 源码：`modules/planning/planners/public_road/scenario_manager.cc`
> - Autoware.Universe：`behavior_path_planner` / RTC / `emergency_handler`
> - AuroraDrive 源码：`cpp/include/ad/autonomy.h` / `simulator.h` / `http_server.h`
