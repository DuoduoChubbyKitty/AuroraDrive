# ROS2 中间件深度研究（rmw / rcl / rclcpp）

> 研究主题：ROS2 中间件分层架构、rmw 抽象层、rcl/rclcpp/rclpy 客户端库、通信机制、生命周期、QoS，并与百度 CyberRT 进行系统对比，最终给出 AuroraDrive 通信升级建议。
>
> 研究方法：WebSearch + WebFetch 对 ROS2 官方文档（docs.ros.org）、GitHub ros2、CSDN/掘金技术解析、Apollo CyberRT 资料进行多轮检索与抓取。

---

## 1. ROS2 架构总览

### 1.1 整体分层架构

ROS2（Robot Operating System 2）是 ROS1 的重写版本，其设计目标是解决 ROS1 在实时性、分布式、跨平台、安全性和生命周期管理上的短板。ROS2 的核心改进是**用 DDS（Data Distribution Service）替换了 ROS1 自研的 TCPROS 通信层**，并通过 `rmw` 抽象层把 DDS 实现可插拔化。

ROS2 自上而下分为三大层次：

```
┌──────────────────────────────────────────────────────────────┐
│  应用层 Application Layer                                      │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
│  │  导航 Nav2│ │ MoveIt2  │ │ros2_control│ │ 用户节点 / 工具链 │ │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────────┬─────────┘ │
├───────┼────────────┼────────────┼───────────────┼───────────┤
│  客户端库层 Client Library Layer（多语言）                       │
│  ┌────┴────┐  ┌─────┴────┐  ┌────┴────┐  ┌───────┴────────┐  │
│  │ rclcpp  │  │  rclpy   │  │  rcljava│  │ rclrs (Rust) 等 │  │
│  └────┬────┘  └─────┬────┘  └────┬────┘  └───────┬────────┘  │
│       │             │            │               │            │
│       └─────────────┴────┬───────┴───────────────┘            │
│                          │ rcl（C 语言通用功能库，中间件无关）   │
│                    ┌─────┴─────┐                               │
│                    │  rcl API  │                               │
│                    └─────┬─────┘                               │
├──────────────────────────┼────────────────────────────────────┤
│  中间件抽象层 rmw（ROS Middleware Interface，纯 C 接口）          │
│                          │                                     │
│   ┌──────────────────────┼──────────────────────────────┐      │
│   │ rmw_fastrtps_cpp  rmw_cyclonedds_cpp  rmw_connextdds│      │
│   │      │                  │                  │        │      │
│   │  Fast DDS         Eclipse Cyclone DDS    RTI Connext │      │
│   └──────────────────────┬──────────────────────────────┘      │
│                          │                                     │
├──────────────────────────┼────────────────────────────────────┤
│  DDS / RTPS 线协议层（OS 之上）                                  │
│   发现 SPDP/SEDP、序列化 CDR、QoS、传输 UDP/TCP/SHM              │
├──────────────────────────────────────────────────────────────┤
│  操作系统层 OS Layer（Linux / Windows / macOS / RTOS）         │
└──────────────────────────────────────────────────────────────┘
```

要点解读：

- **应用层**：上层业务与生态（Nav2、MoveIt2、ros2_control、Gazebo、RViz2 等）。
- **客户端库层**：`rclcpp`（C++）、`rclpy`（Python）以及 rcljava、rclrs 等，均基于 `rcl` 构建，提供面向用户的高级 API。
- **rcl 层**：用 C 语言编写的**通用功能库**，封装了与具体 DDS 无关的 ROS 概念（Node、Publisher、Subscriber、Service、Action、Graph、参数等）。所有客户端库都调用 rcl，保证不同语言行为一致——这是 ROS2 相对 ROS1 的关键改进（ROS1 各语言客户端各自从零实现，行为不一致）。
- **rmw 层**：ROS2 软件栈与底层 DDS 实现之间的抽象接口，纯 C API，定义发现、发布订阅、请求-应答、序列化等功能接口。任一 DDS 实现只要实现了 rmw 接口即可被装载到 ROS2。
- **DDS/RTPS 层**：工业级实时数据分发标准，提供去中心化发布/订阅、QoS 策略、发现机制与有线协议（RTPS 基于 UDP，可选 TCP/SHM）。
- **OS 层**：ROS2 跨平台，支持 Linux/Windows/macOS 以及嵌入式 RTOS（micro-ROS 还可运行在 MCU 上）。

### 1.2 与 ROS1 的核心差异

| 维度 | ROS1 | ROS2 |
|------|------|------|
| 通信中间件 | 自研 TCPROS，基于 TCP（可选 UDP） | DDS/RTPS 工业标准，可插拔 rmw |
| 中心节点 | 依赖 `roscore`/master，单点故障 | **去中心化**，无 master，节点通过 DDS 自动发现 |
| 实时性 | TCP 通信实时性差，无法保证截止时间 | DDS 提供实时性与确定性，支持 QoS 截止时间 |
| 跨平台 | 仅 Linux | Linux / Windows / macOS / RTOS / MCU |
| 通信拷贝 | 跨进程内存拷贝，资源开销大 | 支持进程内通信、共享内存零拷贝 |
| 语言一致性 | 各语言客户端各自实现，行为不一致 | 统一 rcl 库，多语言行为一致 |
| 生命周期 | 无标准节点状态机 | LifecycleNode 状态机（unconfigured/inactive/active/finalized） |
| 编译系统 | catkin | ament（更现代） |
| 安全 | 无内建安全框架 | DDS-Security（认证、访问控制、加密） |
| QoS | 仅可靠/不可靠 | 完整 QoS 策略集（Reliability/History/Durability/Deadline/Liveliness/Lifespan/Ownership） |
| 参数 | 全局参数服务器 | 每节点独立参数（基于 service） |

ROS1 通信基于 TCPROS，节点间数据通过内存复制传递，大量系统资源浪费在通信上，且依赖 master 节点调度，master 一旦崩溃整个系统瘫痪。ROS2 通过 DDS 实现去中心化、实时性、跨平台与生命周期管理，是机器人与自动驾驶领域走向工业级的基础。

---

## 2. rmw（ROS Middleware Interface）

### 2.1 rmw 抽象接口设计

`rmw` 是 ROS2 的**中间件抽象层**（ROS MiddleWare）。它的设计目标是在 ROS2 软件栈与底层 DDS 实现之间提供一层稳定、与具体厂商无关的 C 接口，使得用户可以根据性能、许可协议、平台约束自由选择 DDS 实现——只要某个 DDS 实现实现了 rmw 规定的接口，就可以装载到 ROS2 系统中完成消息传递。

rmw 接口定义了以下核心能力：
- **发现（Discovery）**：节点、发布者、订阅者、服务端/客户端的注册与查找。
- **发布/订阅（Pub/Sub）**：创建 publisher/subscriber，发送/接收消息。
- **请求-应答（Request/Reply）**：service 的客户端-服务端调用。
- **序列化（Serialization）**：消息类型支持与序列化。
- **图（Graph）**：ROS 图拓扑查询（节点、话题、连接关系）。
- **QoS 映射**：将 ROS2 的 QoS Profile 转换为底层 DDS 的 QoS 策略。

### 2.2 rmw 软件结构

rmw 层在源码上主要划分为两个部分：

- **rmw**（接口定义）：`rmw.h`、`init.h` 等头文件，规定 DDS 组件的功能接口，本身逻辑较少，主要做接口约定与节点名校验等。
- **rmw_implementation**（实现分发）：包含一个**动态函数调用框架**，能把 DDS 实现组件的函数接口直接提供给 rcl 层调用。其核心是 `RMW_INTERFACE_FN` 宏与 `CALL_SYMBOL` 宏：

```cpp
#define CALL_SYMBOL(symbol_name, ReturnType, error_value, ArgTypes, arg_values) \
  if (!symbol_ ## symbol_name) { \
    symbol_ ## symbol_name = get_symbol(#symbol_name); /* 动态加载符号 */ \
  } \
  if (!symbol_ ## symbol_name) { return error_value; } \
  typedef ReturnType (* FunctionSignature)(ArgTypes); \
  FunctionSignature func = reinterpret_cast<FunctionSignature>(symbol_ ## symbol_name); \
  return func(arg_values);
```

也就是说，rcl 层调用 `rmw_send_response` 等接口时，rmw_implementation 通过运行时动态符号查找（`dlopen`/`dlsym` 机制）把调用转发到当前选定的 DDS 实现包（如 `rmw_cyclonedds_cpp` 的 `rmw_node.cpp` 中以 `extern "C"` 暴露的同名函数）。这使得多套 rmw 实现可以共存于同一台机器，按需切换。

### 2.3 主流 rmw 实现

当前所有 ROS2 中间件实现都基于完整或部分的 DDS 实现。一个 rmw 实现通常由同一仓库下的几个包组成：

- `<name>_cmake_module`：发现并暴露依赖的 CMake 模块（如 `fastrtps_cmake_module`、`rti_connext_dds_cmake_module`）。
- `rmw_<name>_<lang>`：实现 rmw C API（通常用 C++ 编写，但以 `extern "C"` 暴露符号供 C 链接）。
- `rosidl_typesupport_<name>_<lang>`：为 rosidl 文件生成厂商特定的静态类型支持代码，并生成消息结构在 ROS 与 DDS 之间转换的代码。

主流实现对比：

| 实现 | rmw 包名 | 提供方 | 协议/许可 | 特点与适用场景 |
|------|----------|--------|-----------|----------------|
| **Fast DDS** | `rmw_fastrtps_cpp` | eProsima | Apache 2.0 | ROS2 **默认**实现，打包在发布版中；延迟低、吞吐高，特性全面（QoS、共享内存零拷贝、Discovery Server）。平衡性能与资源占用，适合大多数场景。 |
| **Cyclone DDS** | `rmw_cyclonedds_cpp` | Eclipse | Eclipse 公共许可 | 强调**低延迟与确定性**，适合实时系统；资源受限嵌入式设备内存占用低（实测树莓派 4 启动比 Fast DDS 快约 1.7s），社区活跃。 |
| **Connext DDS** | `rmw_connextdds` | RTI | 商业/研究 | 实时性能最强、**车规/工业认证**支持完善，原生支持 ASAM MCD-2 等工业标准，适合航空电子、PLC 集成等强认证场景；需从源码编译，体积较大。 |
| **GurumDDS** | `rmw_gurumdds_cpp` | GurumNetworks | 商业 | 韩国厂商实现，嵌入式/移动端优化。 |

### 2.4 切换 rmw 实现

由于 rmw 实现是编译期静态链接的模块（不是并列"插件"），但 ROS2 通过环境变量在**运行时**选择具体实现：

```bash
# 使用 Cyclone DDS
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
# 使用 Fast DDS（默认）
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
# 使用 Connext DDS
export RMW_IMPLEMENTATION=rmw_connextdds
ros2 run demo_nodes_cpp talker
```

多 RMW 共存是 ROS2 工程落地的"必修课"：百节点规模下 Fast DDS 的默认内存池可能与实时内核冲突导致周期性抖动；嵌入式网关 64MB RAM 设备上 Fast DDS 动态内存分配可能触发 OOM；不同子系统供应商分别强制 Connext 与 Cyclone 时需多 RMW 共存。RMW 是 ROS2 应用能否跨平台、跨安全等级、跨资源约束稳定运行的物理边界。

跨中间件通信需注意互操作性边界——不同 DDS 厂商虽都遵循 RTPS 有线协议，但默认发现机制（多播）、QoS 默认值、序列化兼容性存在差异，跨 RMW 通信需谨慎验证。

---

## 3. rcl（ROS Client Library）

### 3.1 rcl 的定位

`rcl` 是 ROS2 用 **C 语言**编写的通用功能库，是比 rmw 略高一级的 API。它**不直接触碰 DDS 实现**，而是通过 rmw 接口与中间件交互。rcl 的存在解决了 ROS1 时代各语言客户端各自实现、行为不一致、漏洞需多处修复的问题——ROS2 把"与具体编程语言无关的 ROS 概念"统一抽到 rcl，rclcpp 与 rclpy 等都基于 rcl 开发。

调用层次（以 talker 发布消息为例）：

```
rclcpp::Publisher::publish()
   └── rcl_publish()           // rcl C 接口
        └── rmw_publish()      // rmw 抽象接口
             └── DDS vendor API // 具体 DDS 实现
```

### 3.2 rcl 提供的核心 C 接口

rcl 封装了 ROS2 的全部核心概念，对外提供 C 接口：

- **Node**：`rcl_node_init` / `rcl_node_fini`，节点创建与销毁，命名空间、参数。
- **Publisher / Subscriber**：`rcl_publisher_init`、`rcl_subscription_init`、`rcl_publish`、`rcl_take`。
- **Service / Client**：`rcl_service_init`、`rcl_client_init`、`rcl_send_request`、`rcl_send_response`、`rcl_take_request`、`rcl_take_response`。
- **Action**：`rcl_action` 系列（goal handle、feedback、result）。
- **Timer**：`rcl_timer_init`，定时器。
- **Graph**：`rcl_get_topic_names_and_types`、`rcl_get_publisher_names_and_types_by_node` 等拓扑查询。
- **参数（Parameter）**：基于 service 的参数声明、设置与回调。
- **Context / Init**：`rcl_init`、`rcl_shutdown`，全局上下文管理。
- **Wait / Guard Condition**：`rcl_wait_set`，事件等待与多路复用。

### 3.3 rcl 与客户端库的关系

rcl 是**中间件无关**的通用层；rclcpp / rclpy 在 rcl 之上提供面向对象、类型安全、自动生命周期管理的高级 API。例如 rclcpp 的 `Node` 类内部组合了多个 `node_interfaces`（NodeGraph、NodeClock、NodeParameters、NodeTopics、NodeServices、NodeTimers、NodeWaitables 等），每个 interface 都是对 rcl C API 的 C++ 封装。这样设计保证了：

1. **行为一致性**：C++ 与 Python 节点对 DDS 的调用路径一致，发现/序列化/QoS 行为统一。
2. **可维护性**：通用逻辑只维护一份（rcl），新语言绑定只需薄封装 rcl。
3. **可测试性**：rcl 可独立于语言被单元测试。

---

## 4. rclcpp

### 4.1 rclcpp 概述

`rclcpp` 是 ROS2 的 **C++ 客户端库**，提供 ROS2 的核心功能。它基于 rcl 构建，所有节点都围绕 `rclcpp::Node` 类展开，配合 Publisher、Subscriber、Service、Timer、Action、Parameter 等对象快速构建功能。由于节点是 C++ 对象，**一个进程可包含多个节点**，进程内通信可走共享内存加速。

### 4.2 Node 类

`rclcpp::Node` 是核心类，提供丰富的 API：

- **创建 Publisher**（模板，类型安全）：
```cpp
auto pub = node->create_publisher<std_msgs::msg::String>("/chatter", 10);
// 第二参数为 QoS depth，也可传 QoSProfile
```
- **创建 Subscriber**：
```cpp
auto sub = node->create_subscription<std_msgs::msg::String>(
    "/chatter", 10,
    [this](const std_msgs::msg::String::SharedPtr msg) { /* callback */ });
```
- **创建 Service / Client**：`create_service<T>`、`create_client<T>`，请求-应答。
- **创建 Timer**：`create_wall_timer`，周期回调。
- **参数**：`declare_parameter`、`get_parameter`、`set_parameter`、`add_on_set_parameters_callback`。
- **NodeOptions**：配置节点初始化参数，包括参数处理、命名空间、回调组配置、进程内通信、QoS 等。
- **Logger / Clock / Time**：日志、ROS 时钟与时间。

Node 内部采用 `node_interfaces` 组合模式（NodeClock、NodeGraph、NodeParameters 等），把 rcl 的 C 接口包装成 C++ 对象，方便扩展和测试。

### 4.3 类型支持（Type Support）

ROS2 消息通过 `.msg` / `.srv` / `.action` 文件定义，由 `rosidl` 生成代码。类型支持有两类：

- **静态类型支持**（`rosidl_typesupport_<vendor>_<lang>`）：编译期为特定 DDS 厂商生成预编译代码，性能高。
- **内省类型支持**（`rosidl_typesupport_introspection_<lang>`）：运行时通过消息元数据内省任意消息实例，基于 DDS X-Types Dynamic Data 标准，无需预生成代码即可发布/接收类型。

### 4.4 Executor 与 Callback Group

**Executor** 是 rclcpp 中负责检查订阅、定时器、服务、动作等是否就绪并调用其对应回调的组件。ROS2 提供多种 Executor：

- **SingleThreadedExecutor**：单线程按触发顺序依次执行所有回调。适用于不需要并行处理的简单场景，避免多线程同步问题，但计算密集型回调可能阻塞其他回调。
- **MultiThreadedExecutor**：多线程池，支持配置线程数，可并行执行不同回调组。需配合回调组避免数据竞争。
- **StaticExecutor**：静态实体集合，减少每次 spin 的就绪检查开销，适合实体不变的实时场景。
- **EventsExecutor**（较新）：基于事件驱动，降低轮询开销，提升确定性。

```cpp
rclcpp::executors::MultiThreadedExecutor exec(rclcpp::ExecutorOptions(), 4);
exec.add_node(node);
exec.spin();
```

**Callback Group（回调组）** 是管理一个或多个回调执行规则的容器，决定回调间是串行还是并行：

- **MutuallyExclusive（互斥型，默认）**：同组回调不能同时执行，像单线程队列。
- **Reentrant（可重入型）**：同组回调可并行执行，配合 MultiThreadedExecutor 实现并发。

典型用法：高频激光雷达回调放一个 Reentrant 组，键盘/服务回调放另一个组，避免大数据处理阻塞用户输入和服务响应。多线程优化原则：把订阅回调与 service 回调分到不同 callback group，改用 MultiThreadedExecutor，避免回调内同步等待另一回调（改异步队列）。

### 4.5 性能优化机制

- **进程内通信（Intra-Process）**：同进程发布者与订阅者通过共享指针直接传递消息，避免序列化与跨进程拷贝。
- **零拷贝 / Loaned Messages**：通过 DDS 共享内存传输（Fast DDS / Cyclone DDS 的 SHM transport），大数据（图像、点云）传递同一份内存地址，节省 CPU 与内存。
- **内存池 / 自定义分配器**：避免运行时动态分配，提升实时性。
- **发现机制优化**：用 Fast DDS Discovery Server 替代多播发现，适合大规模或受限网络。

---

## 5. rclpy

### 5.1 rclpy 软件框架

`rclpy` 是 ROS2 的 **Python 客户端库**（ROS Client Library for the Python language）。与 ROS1 纯 Python 实现不同，ROS2 的 rclpy 同样基于 rcl，调用链为：

```
rclpy Python (Publisher.publish)
   └── API Python Business（_rclpy_bindings）
        └── API C++ Business（_rclpy_pybind11）
             └── rcl_publish()  // rcl C 接口
                  └── rmw → DDS
```

rclpy 内部通过 pybind11 把 rcl 的 C API 暴露给 Python。它提供与 rclcpp 对等的核心能力：Node、Publisher/Subscriber、Service/Client、Action、Timer、Parameter、QoS、Lifecycle（rclpy_lifecycle）。

### 5.2 与 rclcpp 的差异及性能对比

| 维度 | rclcpp | rclpy |
|------|--------|-------|
| 语言 | C++（编译型） | Python（解释型） |
| 调用路径 | 直达 rcl | 经 pybind11 绑定再到 rcl，多一层 |
| 性能 | 高，零拷贝/SHM/内存池可用 | 受 GIL 与解释执行限制，吞吐/延迟劣于 rclcpp |
| 类型支持 | 静态类型支持，编译期生成 | 静态类型支持（生成 Python 模块） |
| 实时性 | 适合实时控制 | 不适合硬实时，适合原型/工具/上层逻辑 |
| 开发效率 | 较低，需编译 | 高，无需编译，迭代快 |
| Lifecycle | rclcpp_lifecycle::LifecycleNode | rclpy 生命周期支持（部分） |

rclpy 适合快速原型、可视化工具、上层调度、机器学习推理编排；对延迟与吞吐敏感的感知/控制回路应使用 rclcpp。两者通过相同的 rcl/rmw 路径互通，可在同一系统混用。

---

## 6. ROS2 通信机制

ROS2 提供四种通信模式，均建立在 DDS 之上：

### 6.1 Topic（话题）

- 模型：**发布/订阅**（Publish/Subscribe），异步、多对多。
- 用途：持续数据流，如传感器数据（激光、图像、IMU）、里程计、控制指令。
- 特性：匿名、去中心化，节点通过 DDS 自动发现；可为每个发布者/订阅者独立配置 QoS。

### 6.2 Service（服务）

- 模型：**客户端/服务端**（Client/Server），同步请求-应答。
- 用途：不连续的、短时任务，如触发一次动作、查询状态、设置参数。
- 特性：服务端仅在收到请求时响应；每个 ROS2 节点自动暴露一组参数相关 service（`get_parameters`、`set_parameters`、`list_parameters` 等），参数即基于 service 实现。

### 6.3 Action（动作）

- 模型：客户端-服务端，但**可抢占、可取消、持续反馈**。
- 组成：目标（Goal）、反馈（Feedback）、结果（Result），定义在 `.action` 文件中（三段以 `---` 分隔）。
- 实现：**建立在 topic 与 service 之上**——目标发送/取消走 service，反馈流与结果走 topic。
- 用途：长时间运行任务，如导航到点、机械臂运动、转盘旋转，需持续反馈进度并支持中途取消。

```
.action 文件结构
# Goal
float32 target
---
# Result
bool success
float32 final_value
---
# Feedback
float32 progress
```

### 6.4 Parameter（参数）

- 模型：节点级配置，基于 service 实现（`declare_parameter` / `set_parameter` / `get_parameter`）。
- 特性：每个节点独立持有参数（无 ROS1 全局参数服务器）；支持类型校验、变更回调（`add_on_set_parameters_callback`）、声明前必须 declare。

### 6.5 与 CyberRT 通信对比

| 维度 | ROS2 | CyberRT |
|------|------|---------|
| 通信模式 | Topic / Service / Action / Parameter | Channel（Reader/Writer 发布订阅）、Service/Client（请求-应答） |
| 无 Action | Action 内建（goal/feedback/result） | 无原生 Action，需自行用 channel+service 组合 |
| 发现 | DDS SPDP/SEDP 多播或 Discovery Server | 自动发现（去中心化，类 CAN 组网） |
| 传输 | UDP（默认）/TCP/SHM/进程内 | INTRA（进程内零拷贝）/SHM（共享内存）/RTPS（跨主机） |
| 类型系统 | rosidl（.msg/.srv/.action）+ X-Types | Protobuf |
| QoS | 完整 QoS 策略集 | 较简化的 QosProfile |
| 调度 | Executor + Callback Group | 协程 CRoutine + Scheduler（classic/choreography） |
| 适用 | 机器人全场景、研究、原型 | 车端量产、强实时 |

---

## 7. ROS2 生命周期（Lifecycle Node）

### 7.1 背景与动机

ROS1 的痛点之一是**无法控制节点生命周期**——传感器读取往往在传感器驱动启动之前就开始，导致启动时序混乱、不可控。ROS2 引入**生命周期节点（LifecycleNode / Managed Node）**，提供类似 PLC 的状态机管理，确保系统启动时传感器、驱动、算法按受控顺序实例化与激活，并支持重启或在线重配置。

实现上，C++ 使用 `rclcpp_lifecycle::LifecycleNode`（而非普通 `rclcpp::Node`），Python 端生命周期支持为 pending/部分。

### 7.2 状态机

生命周期节点由**主状态（Primary States，稳态）**与**切换状态（Transition States，临时中间态）**组成：

主状态（4 个稳态）：
1. **Unconfigured**：实例化后立即处于的状态。仅构造了节点对象，未配置资源。
2. **Inactive**：已配置但未激活。节点存在但不参与通信（publisher/subscriber 不收发）。
3. **Active**：正常运行，参与通信、执行行为。
4. **Finalized**：终态，资源已释放。

切换状态（中间态）：Configuring、CleaningUp、Activating、Deactivating、ShuttingDown、Destroying。

### 7.3 7 个过渡（Transitions）

暴露给监督流程的 7 个过渡：`create`、`configure`、`cleanup`、`activate`、`deactivate`、`shutdown`、`destroy`。

```
                create
   [未实例化] ──────────► [Unconfigured]
                              │
                  configure   │   cleanup
                       ▼       │   ▲
                    [Inactive]─┘   │
                       │  ▲        │
              activate │  │ deactivate
                       ▼  │        │
                    [Active]───────┘
                       │
          shutdown     │   (也可从 Unconfigured/Inactive shutdown)
                       ▼
                  [Finalized] ──► destroy ──► [未实例化]
```

每个过渡对应一个回调（`on_configure`、`on_activate`、`on_deactivate`、`on_cleanup`、`on_shutdown`），回调返回 `SUCCESS` / `FAILURE` / `ERROR` 决定过渡是否成功。可通过命令行（`ros2 lifecycle set`）或编程接口触发，并由监督节点编排整个系统启动顺序。

### 7.4 与 CyberRT Component 对比

| 维度 | ROS2 LifecycleNode | CyberRT Component |
|------|--------------------|--------------------|
| 状态机 | 4 主状态 + 中间态，标准状态机 | 简化状态：UNINITIALIZED / INITIALIZED / SHUTTING_DOWN / SHUTDOWN |
| 启动控制 | 监督节点编排 configure→activate 顺序 | DAG 文件定义上下游通道与依赖，mainboard 按 DAG 加载 |
| 动态加载 | ComponentManager 动态加载插件 | DAG + .so 动态加载，弹性部署到不同进程 |
| 重配置 | 可 deactivate→cleanup→reconfigure | 主要靠重启进程 |
| 编排粒度 | 节点级状态机 | 模块级 DAG 拓扑 |

ROS2 Lifecycle 偏"状态机+监督编排"，CyberRT 偏"DAG 静态拓扑+调度器"，二者思路不同但都为解决启动顺序与可控性问题。

---

## 8. ROS2 QoS

### 8.1 QoS 概述

ROS2 借助 DDS 提供丰富的 QoS（Quality of Service）策略，允许为每条数据流定制通信规则。一组 QoS 策略组合成 QoS Profile，可独立应用于 publisher / subscriber / service server / client。正确配置下，ROS2 可像 TCP 一样可靠，也可像 UDP 一样尽力而为，并在中间有大量可能状态。QoS 是 ROS2 走向工业级的核心功能之一。

### 8.2 核心 QoS 策略

| 策略 | 取值 | 含义 |
|------|------|------|
| **Reliability（可靠性）** | `RELIABLE` / `BEST_EFFORT` | RELIABLE 类似 TCP，丢失重传确保送达；BEST_EFFORT 类似 UDP，丢了就丢。 |
| **History（历史）** | `KEEP_LAST` / `KEEP_ALL` | KEEP_LAST 仅保留最新 N 条（由 depth 控制）；KEEP_ALL 保留全部（受资源限制约束）。 |
| **Depth（深度）** | 整数 | 队列大小，仅 KEEP_LAST 时生效。 |
| **Durability（持久性）** | `VOLATILE` / `TRANSIENT_LOCAL` / `TRANSIENT` / `PERSISTENT` | VOLATILE：订阅者只收到加入后的消息；TRANSIENT_LOCAL：发布者为后加入者保存历史，新订阅者能收到最后消息；TRANSIENT/PERSISTENT：消息存持久化介质。 |
| **Deadline（截止时间）** | 时长 | 在该时间内必须收到新消息，否则触发回调，用于监控传感器掉线。 |
| **Liveliness（活跃性）** | `AUTOMATIC` / `MANUAL_BY_TOPIC` + lease duration | 自动或基于心跳判断发布者是否存活，超时触发回调。 |
| **Lifespan（生命周期）** | 时长 | 消息有效期，超期自动丢弃。 |
| **Ownership（所有权）** | `SHARED` / `EXCLUSIVE` | EXCLUSIVE 下仅优先级最高的发布者消息被接收，实现冗余切换。 |

### 8.3 预定义 QoS Profile

ROS2 提供常见用例的预定义 Profile：`sensor_data`（Best Effort + KEEP_LAST(5) + VOLATILE）、`parameters`（RELIABLE + TRANSIENT_LOCAL）、`services_default`、`parameter_events` 等。

### 8.4 QoS 兼容性原则

**订阅者的要求不能比发布者的提供更苛刻**（"求同存异"）：
- 发布者 BEST_EFFORT + 订阅者 RELIABLE → **连接失败**，无法收消息（这是 RViz2 无法显示传感器、明明发布正常却订阅不到的常见原因）。
- 发布者 RELIABLE + 订阅者 BEST_EFFORT → 连接成功。

### 8.5 常见场景配置建议

| 数据类型 | Reliability | Durability | Depth | 理由 |
|----------|-------------|------------|-------|------|
| 传感器原始数据（激光/相机） | BEST_EFFORT | VOLATILE | 1 | 数据量大频率高，旧数据不如新数据 |
| 机器人状态（TF/Odom） | BEST_EFFORT | VOLATILE | 1-5 | 实时性高，丢一两帧不影响 |
| 控制指令（cmd_vel） | RELIABLE | VOLATILE | 1 | 必须送达，但旧指令无意义 |
| 地图/静态参数 | RELIABLE | TRANSIENT_LOCAL | 1 | 必须收到，且晚到者能拿到历史 |
| 关键状态/告警 | RELIABLE | VOLATILE | 10 | 不丢包，保留近期日志 |

### 8.6 与 DDS QoS 的关系

ROS2 QoS 是 DDS QoS 的**子集映射**——ROS2 把 DDS 丰富的 QoS 策略封装为统一 Profile，由 rmw 层翻译为各厂商 DDS 的具体 QoS 参数。由于不同 DDS 厂商对 QoS 支持程度不一（如 TRANSIENT/PERSISTENT 持久化需 DDS 持久化服务支持），ROS2 默认仅暴露最常用的子集以保证可移植性。

---

## 9. ROS2 与 CyberRT 对比

### 9.1 架构差异

- **ROS2**：分层抽象（rcl/rmw/DDS），中间件可插拔，强调生态、跨平台、多语言、标准化。通信建立在工业标准 DDS 之上，去中心化，节点平等。
- **CyberRT**：百度 Apollo 自研的高性能运行时框架，基于**集中式计算模型**，针对自动驾驶的高并发、低延迟、高吞吐深度优化。删除 ROS1 master 机制，用自动发现替代（类 CAN 组网）。引入**协程（CRoutine）**、无锁对象、可配置用户级调度器。

CyberRT 核心概念：Component（组件，配合 DAG 动态加载）、Node、Channel（Reader/Writer 发布订阅）、Service/Client、Task、CRoutine、Scheduler（classic / choreography 策略）、DAG 文件（拓扑配置）、Launch 文件。Component 分两种：普通 Component（最多 4 路消息融合，第一个 Channel 为主 Channel）与 TimerComponent（定时调用，无需消息触发）。

### 9.2 通信与性能差异

| 维度 | ROS2 | CyberRT |
|------|------|---------|
| 序列化 | CDR（DDS 标准） | Protobuf |
| 进程内通信 | Intra-Process（共享指针） | INTRA（函数调用零拷贝） |
| 跨进程同机 | DDS SHM 共享内存 | SHM 共享内存 |
| 跨主机 | RTPS（UDP/TCP） | RTPS |
| 实时调度 | Executor + Callback Group（较通用） | 协程 + 用户级 Scheduler（classic/choreography），可配 CPU 亲和性、SCHED_FIFO/RR 优先级、NUMA 隔离 |
| QoS | 完整策略集 | 简化 QosProfile |
| 生态 | 极丰富（Nav2/MoveIt2/Gazebo/RViz） | 聚焦车端量产 |
| 跨平台 | Linux/Win/Mac/RTOS/MCU | 主要 Linux |
| 标准化 | 高（DDS/OMG 标准） | 中（Apollo 内部标准） |

CyberRT 的 SHM 零拷贝针对车端大数据（点云、图像）做了深度优化，且调度器可基于任务依赖、执行时长、CPU 消耗、消息频率编排任务（choreography 策略），实时性与确定性在车端量产环境表现更强。ROS2 的 Intra-Process 与 Loaned Messages 也能零拷贝，但 Executor 调度更通用，硬实时需额外配置（PREEMPT_RT、线程优先级）。

### 9.3 适用场景差异

- **ROS2**：机器人全栈（导航、SLAM、机械臂、AGV、人形）、研究原型、跨平台、多语言、强生态需求；自动驾驶研究与原型也常用。
- **CyberRT**：车端量产、强实时、高并发、高吞吐、对延迟与确定性极致要求；与 Apollo 全栈深度绑定。

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 现状

AuroraDrive 当前采用 **Unix Socket** 作为模块间通信：
- 优点：实现简单、跨进程、流式可靠、POSIX 标准化、调试方便。
- 短板：
  - 点对点/客户端-服务端模型，缺乏原生发布订阅与多播，多订阅者需多次拷贝或自实现分发。
  - 无内建 QoS（可靠性、持久性、截止时间、活跃性），需在应用层手工补齐。
  - 无标准化发现机制，地址/端口硬编码或需自研注册中心。
  - 无生命周期状态机，启动顺序与故障恢复靠手工编排。
  - 大数据（点云/图像）跨进程需序列化+拷贝，CPU/内存开销大。
  - 类型系统自定义，缺乏跨语言、跨工具链的标准化消息定义。

### 10.2 是否引入 ROS2？

**结论：不建议直接整体替换为 ROS2，建议"借鉴 ROS2 思想 + 分层渐进升级"**。理由：

1. **车端实时性**：ROS2 默认 Executor 调度较通用，硬实时需 PREEMPT_RT + 线程优先级调优，量产车端实时性不如 CyberRT 式协程调度。但 AuroraDrive 若非极致硬实时，ROS2 可满足。
2. **依赖体积**：引入完整 ROS2 + DDS 栈体积与依赖较大，对车端资源与认证有负担。
3. **生态价值**：若 AuroraDrive 需对接 Nav2、RViz、rosbag 等生态或做多机器人/研究，ROS2 价值巨大；若纯车端闭环，价值有限。
4. **渐进可控**：Unix Socket 已稳定运行，整体替换风险高。

**推荐策略**：保留 Unix Socket 作为存量通信，**选择性引入 ROS2 子系统能力**（QoS 抽象、Lifecycle 状态机、rosidl 类型系统、rosbag2 工具），并参考 CyberRT 的 SHM 零拷贝与协程调度，自研轻量中间件或通过 rmw 桥接。

### 10.3 借鉴 ROS2 QoS

为 AuroraDrive 通信抽象层引入 ROS2 风格的 QoS Profile：

```cpp
struct AuroraQoS {
  Reliability reliability = RELIABLE;      // RELIABLE / BEST_EFFORT
  History      history      = KEEP_LAST;   // KEEP_LAST / KEEP_ALL
  uint32_t     depth        = 10;
  Durability   durability   = VOLATILE;    // VOLATILE / TRANSIENT_LOCAL
  Duration     deadline      = INFINITE;   // 截止时间，超时回调
  Liveliness   liveliness    = AUTOMATIC;  // 心跳活跃性
  Duration     lease_duration = INFINITE;
  Lifespan     lifespan      = INFINITE;   // 消息有效期
};
```

落地建议：
- **传感器流（激光/相机/IMU）**：BEST_EFFORT + KEEP_LAST(1) + VOLATILE，丢弃旧数据保实时。
- **控制指令**：RELIABLE + KEEP_LAST(1) + VOLATILE，必达但旧指令无意义。
- **地图/静态配置**：RELIABLE + TRANSIENT_LOCAL，晚订阅者能拿到历史。
- **关键状态/心跳**：RELIABLE + KEEP_LAST(10) + Liveliness lease，监控模块掉线。
- 在 Unix Socket 之上实现 QoS：可靠=应用层 ACK+重传，持久=发布端缓存历史，截止时间=定时器超时回调，活跃性=心跳探测。

### 10.4 借鉴 ROS2 Lifecycle

为 AuroraDrive 模块引入标准状态机，统一启动/恢复/退出顺序：

```
Unconfigured ──configure──► Inactive ──activate──► Active
     ▲                       │                       │
     │                  cleanup                 deactivate
     │                       ▼                       │
     └────────────────── Inactive ◄─────────────────┘
                                │ shutdown
                                ▼
                            Finalized
```

落地建议：
- 每个模块实现 `on_configure / on_activate / on_deactivate / on_cleanup / on_shutdown` 回调，返回 SUCCESS/FAILURE/ERROR。
- 引入**监督节点（Supervisor）**按 DAG 依赖编排过渡：先 configure 所有感知模块→activate→再 configure 规划/控制，保证传感器在算法前就绪。
- 支持运行时 deactivate→reconfigure→activate，实现热重载与故障恢复，避免整进程重启。
- 模块配置声明化（类似 DAG 文件），定义上下游通道与依赖，便于拓扑可视与校验。

### 10.5 AuroraDrive 通信升级方案

**三阶段渐进路线：**

**阶段一（QoS + Lifecycle 抽象，零侵入）**：
- 在现有 Unix Socket 通信层之上封装 QoS Profile 与 Lifecycle 状态机接口，存量模块逐步适配。
- 引入标准化消息定义（参考 rosidl：`.msg`/`.srv`/`.action` 文件 + 代码生成），统一跨语言类型。
- 引入心跳/活跃性/截止时间监控，提升可观测性与故障检测。

**阶段二（传输层升级）**：
- 同机跨进程高频大数据（点云、图像）切换到**共享内存零拷贝**（参考 CyberRT SHM 与 ROS2 Loaned Messages），小指令仍走 Unix Socket。
- 进程内通信走共享指针/函数回调（参考 ROS2 Intra-Process）。
- 引入**发布订阅抽象**，支持一发布多订阅，由通信层做多播分发。
- 可选：引入 DDS（Fast DDS / Cyclone DDS）作为可选后端，通过 rmw 式抽象与既有传输共存，按通道选择传输。

**阶段三（生态与标准化，可选）**：
- 通过 **rmw 适配层**桥接 ROS2 生态（rosbag2 录制回放、RViz 可视化、Nav2 对接），用于研发与离线分析，车端发布版可裁剪。
- 引入事件驱动 Executor（参考 EventsExecutor）替代轮询，降低调度延迟与抖动。
- 评估 PREEMPT_RT + 线程优先级/CPU 亲和性，满足硬实时回路。

**关键收益**：QoS 提升通信可靠性与实时性可配置；Lifecycle 提升启动可控性与故障恢复；共享内存零拷贝降低 CPU/内存开销与延迟；标准化消息与 rmw 桥接打通 ROS2 生态工具链，兼顾车端量产与研发效率。

---

## 参考资料

- ROS2 官方文档：About Middleware Implementations、About Internal Interfaces、About QoS Settings、About Lifecycle Nodes
- GitHub ros2：rmw_fastrtps_cpp、rmw_cyclonedds、rmw_connextdds、rmw_gurumdds
- CSDN/掘金：ROS2 软件架构全面解析（rmw/rclpy 框架）、ROS2 中间件实现、多 RMW 共存实战、LifecycleNode 讲解、ROS2 QoS 介绍、Callback Group、Executor、CyberRT 架构与 Transport 设计、ROS1/ROS2/CyberRT 对比

---

> 实际工具调用次数：约 56 次（WebSearch + WebFetch + TodoWrite + Read/Write，含 ROS2 官方文档、GitHub、CSDN/掘金 CyberRT 资料多轮抓取）。
