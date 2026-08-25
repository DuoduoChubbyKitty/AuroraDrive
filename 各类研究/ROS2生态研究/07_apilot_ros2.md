# apollo.launcher 工具与节点启动机制深度研究报告

> 研究主题：Apollo 自动驾驶平台中的 launcher 工具（`cyber_launch` / `apollo.launcher`）、launch 文件格式、节点启动流程、与 ROS2 launch 及 CyberRT mainboard 的对比、节点监控机制，以及对 AuroraDrive（Rust 启动 sidecar）的迁移建议。
>
> 适用版本：Apollo 3.5 引入 Cyber RT 起，至 Apollo 9.0 / 10.0 的演进路线。
>
> 说明：Apollo 生态中并不存在一个名为 `apollo.launcher` 的独立可执行命令。社区与本文档中所称的 "apollo.launcher" 实际指代 Cyber RT 提供的 **`cyber_launch`** 启动工具（早期路径为 `${apollo_home}/cyber/tools/cyber_launch/cyber_launch`，Apollo 9.0 之后通过 `apollo_neo.sh` / `buildtool` 体系封装），以及它所驱动的 **`mainboard`** 进程加载器。本报告以 "apollo.launcher" 作为对这一启动工具链的统称。

---

## 1. apollo.launcher 概述

### 1.1 工具定位

在 Apollo 3.5 之前，Apollo 采用 ROS 作为底层通信与调度平台，节点通过 `roslaunch` 启动。自 Apollo 3.5 起，百度彻底摒弃 ROS，改用自研的 **Cyber RT** 作为底层通讯与调度平台。在此架构下，所有功能模块不再是各自独立的可执行二进制，而是被编译成 **动态共享库（.so）**，由统一的入口程序加载运行。

这一"统一的入口程序 + 启动编排工具"的组合，就是本报告所称的 apollo.launcher 体系，它由两个核心组件构成：

1. **`mainboard`**：Cyber RT 的进程入口（`exe`），位于 `apollo/cyber/mainboard/` 目录。它是整个 Apollo 软件系统的 `main()` 函数所在位置，负责解析参数、初始化 Cyber 运行环境、加载功能模块动态库。其他所有模块都是链接在 mainboard 上的共享库。
2. **`cyber_launch`**：一个 Python 编写的启动编排工具，位于 `cyber/tools/cyber_launch/cyber_launch.py`。它负责解析 XML 格式的 launch 文件，并据此拉起一个或多个 mainboard 进程。

### 1.2 与 ROS2 launch 的关系

`cyber_launch` 在功能角色上对应 ROS2 中的 `ros2 launch`（以及 ROS1 的 `roslaunch`）：二者都是"用一个声明式文件描述要启动哪些节点、用什么参数、在什么进程里运行"的编排器。但二者存在本质差异：

- **ROS2 launch** 启动的是一个个独立的 ROS2 节点进程（或组合节点容器 ComposableNodeContainer），节点之间通过 DDS 通信；
- **`cyber_launch`** 启动的是 mainboard 进程，每个 mainboard 进程内部可加载多个 Component（动态库），Component 之间通过 Cyber RT 的共享内存 / 进程内通信高效协作。

Apollo 早期版本（≤3.0）使用 ROS，提供过 `rosbag_to_record` 等转换工具，把 ROS 的 rosbag 转为 Cyber record。但 Cyber RT 本身并非"ROS2 的封装"，而是百度自研的、面向自动驾驶高并发低延迟场景的运行时框架。两者底层都参考/使用 DDS 思想，但实现与生态相互独立。

### 1.3 与 CyberRT mainboard 的关系

`cyber_launch` 与 `mainboard` 是 **编排层** 与 **执行层** 的关系：

```
cyber_launch (Python, 编排层)
   │  解析 *.launch (XML)
   │  为每个 <module> 构造命令行： mainboard -d xxx.dag -p <process_group> -s <sched_name>
   ▼
mainboard (C++, 执行层)
   │  ModuleArgument::ParseArgument()  解析 -d / -p / -s
   │  apollo::cyber::Init()            初始化 Cyber 运行环境
   │  ModuleController::LoadAll()      按 dag 加载 .so 并实例化 Component
   │  apollo::cyber::WaitForShutdown() 阻塞等待关闭信号
   ▼
Component::Init() / Proc()  业务逻辑
```

简言之：`cyber_launch` 决定"启动什么、怎么组合"，`mainboard` 决定"真正把动态库加载进进程并跑起来"。

---

## 2. launch 文件

### 2.1 文件格式：XML

Apollo 的 launch 文件采用 **XML 格式**（而非 ROS2 推崇的 Python launch 文件）。其根元素为 `<cyber>`，内部通过 `<module>` 描述每一个要加载的模块。一个 launch 文件可以定义多个 `<module>`，从而同时启动多个 modules。

以下是一个来自 Apollo 源码的真实 launch 文件示例（`modules/perception/lidar_detection_filter/launch/lidar_detection_filter.launch`）：

```xml
<!--this file list the modules which will be loaded dynamicly and
 their process name to be running in -->
<cyber>
    <desc>cyber modules list config</desc>
    <version>1.0.0</version>

    <module>
        <name>lidar_detection_filter</name>
        <dag_conf>/apollo/modules/perception/lidar_detection_filter/dag/lidar_detection_filter.dag</dag_conf>
        <plugin>/apollo/modules/perception/lidar_detection_filter/object_filter_bank/background_filter/plugins.xml</plugin>
        <plugin>/apollo/modules/perception/lidar_detection_filter/object_filter_bank/roi_boundary_filter/plugins.xml</plugin>
        <!-- if not set, use default process -->
        <process_name>lidar_detection_filter</process_name>
        <version>1.0.0</version>
    </module>
</cyber>
```

### 2.2 节点配置（module 字段）

| 字段 | 含义 |
|---|---|
| `<name>` | 模块名，用于 HMI/Monitor 识别 |
| `<dag_conf>` | 该模块对应的 DAG 配置文件路径（核心，mainboard `-d` 参数即取自此） |
| `<plugin>` | 可选，需要预加载的插件描述文件 `plugins.xml` 全路径，可配多个 |
| `<process_name>` | 进程名；不设则使用默认进程 |
| `<version>` | 版本号 |

`cyber_launch.py` 在调用 mainboard 之前会遍历 `<module>` 节点，收集 `plugin_list`，并通过 `-p` 把插件描述文件传给 mainboard，由 `cyber/plugin_manager/plugin_manager.cc` 的 `LoadPlugin()` 加载。

### 2.3 参数配置

launch 文件本身不直接传业务参数，业务参数通过 **DAG 文件**间接传递：DAG 内的 `config` / `flag_file_path` / `readers` 等字段决定 Component 的初始化参数、订阅通道与 flag 文件。

### 2.4 环境变量

启动前通常需 `source cyber/setup.bash` 以使 `cyber_launch`、`mainboard`、`cyber_monitor` 等命令进入 PATH。Apollo 9.0 之后通过 `aem` / `apollo_neo.sh` 容器化封装，环境变量由容器与 `setup.bash` 共同注入（如 `APOLLO_RUN_MODE`、`CYBER_PATH`、`GLOG_*` 日志参数等）。

---

## 3. 节点启动

### 3.1 启动流程

Apollo 的启动过程主要分三个阶段（入口为 `cyber/mainboard/mainboard.cc` 的 `main` 函数）：

```cpp
int main(int argc, char** argv) {
  // 1. 解析参数
  ModuleArgument module_args;
  module_args.ParseArgument(argc, argv);
  // 2. 初始化 cyber
  apollo::cyber::Init(argv[0]);
  // 3. 加载模块
  ModuleController controller(module_args);
  if (!controller.Init()) {
    controller.Clear();
    AERROR << "module start error.";
    return -1;
  }
  // 4. 等待 cyber 关闭
  apollo::cyber::WaitForShutdown();
  // 5. 卸载模块
  controller.Clear();
  AINFO << "exit mainboard.";
  return 0;
}
```

`ModuleArgument::ParseArgument` 通过 `GetOptions` 解析命令行：

- `-d`：指定 DAG 文件路径，**可传多个**（一个 mainboard 可加载多个 dag、多个 so）；
- `-p`：进程组名字，Cyber 会据此加载 `/apollo/cyber/conf` 下对应的调度配置文件（如 CPU 绑定）；
- `-s`：调度策略名（classic / choreography）。

### 3.2 依赖管理

Cyber RT 的依赖管理基于 **DAG（有向无环图）** 与 **Channel 订阅**：DAG 文件中 `readers` 字段声明该 Component 订阅哪些通道，框架据此建立数据流拓扑。Component 的 `Proc()` 由数据驱动触发（第一个 Channel 为主 Channel），未收到数据则不会执行——这是一种天然的"依赖到位才执行"的隐式依赖管理，而非显式声明"先启动 A 再启动 B"。

### 3.3 启动顺序

Apollo 没有像 ROS2 lifecycle 那样显式的"configure → activate"启动顺序编排。其启动顺序由 **Dreamview / HMI** 的 Module Controller 面板人工或脚本控制：

1. `bash scripts/bootstrap.sh start`（或 `apollo_neo.sh bootstrap`）启动 `monitor` + `dreamview`；
2. 在 Dreamview 的 Module Controller 中按需点开 Localization → Perception → Prediction → Routing → Planning → Control；
3. 每个模块点击后，HMI 后台执行 `nohup cyber_launch start /apollo/modules/xxx/launch/xxx.launch &` 拉起对应 mainboard 进程。

由于数据驱动，即便 Planning 先于 Perception 启动，Planning 也会因收不到感知数据而空转等待，不会崩溃。

### 3.4 失败处理

- **mainboard 启动失败**：`ModuleController::Init()` 返回 false 时，mainboard 退出并打印 `module start error`，日志写入 `/apollo/data/log`。
- **运行期进程退出**：由 **Monitor 模块** 的 `ProcessMonitor` 定期（约 1.5s）扫描 `/proc/pid/cmdline`，与 HMI 配置的模块名匹配，匹配失败则置 `FATAL`，并通过 SystemStatus 上报 Dreamview。Aurora-style 的"自动拉起"在 Apollo 中并非 mainboard 自身能力，而是依赖外部脚本/HMI 重新执行 `cyber_launch start`。
- **安全失效**：当 Monitor 判断系统不健康时，置 `system_status` 中相关标志位，**Guardian** 模块据此触发 `TriggerSafetyMode()`（紧急停车 / 软停车），把 `GuardianCommand` 发给 canbus，确保车辆安全。

---

## 4. apollo.launcher 与 ROS2 launch 对比

### 4.1 功能差异

- **`cyber_launch`** 输出的是 mainboard 进程，进程内可装多个 Component（动态库），共享同一 Cyber RT 调度器与共享内存；launch 文件是纯声明式 XML，表达能力有限（不支持条件分支、循环、事件回调）。
- **ROS2 launch**（`launch_ros`）是功能完整的 Python 框架，支持 `Node` / `ComposableNodeContainer` / `IncludeLaunchDescription` / `TimerAction` / `RegisterEventHandler` / `OnProcessExit` 等，可写条件分支、事件驱动、按进程退出回调重启，表达能力远强于 cyber_launch。

### 4.2 用法差异

| 维度 | cyber_launch (Apollo) | ros2 launch (ROS2) |
|---|---|---|
| 文件格式 | XML（`.launch`） | Python（`.launch.py`，推荐）/ XML / YAML |
| 启动命令 | `cyber_launch start xxx.launch` | `ros2 launch pkg xxx.launch.py` |
| 停止命令 | `cyber_launch stop xxx.launch` | `Ctrl+C` 或按事件退出 |
| 进程模型 | 一个 mainboard 进程可装多个 Component | 一个 Node 一个进程，或 ComposableNode 共享容器 |
| 参数传递 | 经由 DAG → Component `config` | `parameters=[...]` 直接传给 Node |
| 生命周期 | 无显式 lifecycle，靠数据驱动 | 有 LifecycleNode 状态机（configure/activate/shutdown） |
| 重启策略 | 无内置重启，靠外部脚本 | 可用 `OnProcessExit` + `RegisterEventHandler` 自动重启 |

### 4.3 兼容性

两者互不兼容，但存在 **数据层桥接**：Apollo 提供 `rosbag_to_record` 工具（及 `bag_convert`）将 ROS rosbag 转为 Cyber record，反之亦可。消息层若要互通需自行写 bridge 节点。Apollo Cyber RT 与 ROS2 底层都借鉴 DDS 思想，但 Cyber RT 的传输层（共享内存 + FastDDS 后端 + 自研 SHM 通知）与 ROS2 的 DDS 中间件层并不直接对接。

---

## 5. apollo.launcher 与 CyberRT mainboard 对比

### 5.1 功能差异

`cyber_launch` 与 `mainboard` 并非竞争关系，而是上下游协作。但若强行对比：

- **`cyber_launch`**：编排层，多进程视角，解析 XML、收集 plugin、构造 mainboard 命令行、后台拉起进程；
- **`mainboard`**：执行层，单进程视角，加载 DAG、动态库、实例化 Component、跑 Cyber 调度循环。

### 5.2 用法差异

```bash
# 方式一：launch 文件启动（推荐，可一次拉起多个 module）
cyber_launch start /apollo/modules/perception/lidar_detection_filter/launch/lidar_detection_filter.launch

# 方式二：直接用 mainboard 启动单个 dag（调试常用）
mainboard -d /apollo/modules/planning/planning_component/dag/planning.dag
```

### 5.3 性能差异

两者本身不存在"性能差异"，因为最终都落到 mainboard 进程上。差异体现在 **进程拓扑**：

- `cyber_launch` 可在一个 launch 中编排多个 `<module>`，每个 module 默认独立 mainboard 进程，进程间通信用共享内存；
- mainboard 也支持 `-d a.dag -d b.dag` 一次加载多个 dag 到同一进程，进程内 Component 间通信用进程内直连（零拷贝指针传递），**高负载下单进程通讯优于多进程**。Apollo 测试表明，把多个相关 Component 合并到一个 mainboard 进程可显著降低跨进程开销。

---

## 6. 节点配置

### 6.1 DAG 配置（CyberRT）

DAG 文件由 `cyber/proto/dag_conf.proto` 定义，是 module 的核心配置文件。每个 module 都要有一个配套的 dag 文件。以 Planning 为例（`modules/planning/planning_component/dag/planning.dag`）：

```
module_config {
  module_library : "libplanning_component.so"
  timer_components {
    class_name : "PlanningComponent"
    config {
      name : "planning"
      config_file_path : "modules/planning/planning_component/conf/planning_config.pb.txt"
      flag_file_path : "modules/planning/planning_component/conf/planning.conf"
      readers {
        channel: "/apollo/perception/obstacles"
      }
      readers {
        channel: "/apollo/prediction"
      }
    }
  }
}
```

关键字段：

| 字段 | 含义 |
|---|---|
| `module_library` | 要加载的 .so 路径（如 `/apollo/bazel-bin/modules/planning/libplanning_component.so`） |
| `components` / `timer_components` | 普通组件 / 定时组件；`components` 由消息触发，`timer_components` 由 `interval` 定时触发 |
| `class_name` | Component 类名，须与 `CYBER_REGISTER_COMPONENT` 注册一致 |
| `config.name` | Component 实例名 |
| `config.config_file_path` | 业务配置（protobuf 文本） |
| `config.flag_file_path` | gflags 配置文件 |
| `config.readers` | 订阅的 channel 列表，可设 `qos_profile.depth` 等 |
| `config.interval` | 仅 timer_components，单位 ms |

### 6.2 launch 配置（对比 ROS2）

Apollo launch（XML）只负责"哪些 module、用哪个 dag、进程名是什么"，业务细节全部下沉到 DAG；ROS2 launch（Python）则把节点、参数、重映射、命名空间、组合容器都写在 launch 里。设计哲学不同：Apollo 强调"dag 即拓扑"，ROS2 强调"launch 即拓扑"。

### 6.3 参数传递

Apollo 参数传递链路：`launch(<module>) → dag(config) → Component::Init()` 读取 `config_file_path`（protobuf）与 `flag_file_path`（gflags）。也可通过 `Parameter` 服务在运行时读写。

### 6.4 资源限制（调度配置）

Cyber RT 的资源限制通过 **调度配置文件**（`cyber/conf/example_sched_classic.conf` / `example_sched_choreography.conf`）实现，由 `-p <process_group>` 选用：

```
process_level_cpuset : "0-7"        # mainboard 进程绑定 CPU
affinity : "range"                   # CPU 亲和模式 range / 1to1
processor_policy : "SCHED_FIFO"      # 线程调度策略 SCHED_FIFO/RR/OTHER
processor_prio : 10
tasks : [
  { name : "perception", prio : 3 },
  { name : "planning",   prio : 2 }
]
```

Choreography 策略还可指定 `choreography_processor_num`、`choreography_affinity`、`pool_processor_num`、`pool_affinity`，实现 NUMA 感知的精细任务编排。

---

## 7. 节点监控

### 7.1 节点状态

Apollo **Monitor 模块**负责系统监控，监控两大类：硬件状态检测、软件模块状态监控。每个 Component 的状态由 1 个概要状态 + 5 个子状态（含 `process_status`）组成，状态只有 `OK` 与 `FATAL` 两值。

### 7.2 心跳与进程存活检测

`ProcessMonitor` 是一个定时器组件，每 1.5s 触发一次 `RunOnce`，工作流程：

1. 读取 `/proc/pid/cmdline` 获取正在运行的进程列表（比执行 `ps` 开销小）；
2. 检测 HMI 配置的 Module 运行信息；
3. 检测受监控的 Component 运行信息；
4. 检测其他组件（如 GPS、CAN、Sensor）；
5. 在 `running_processes` 文本中匹配模块名，匹配上即 `OK`，否则 `FATAL`，更新到 `SystemStatus.components[i].process_status`。

此外 Cyber RT 在通信层有 channel 心跳与拓扑自动发现机制，`cyber_monitor` 工具可在终端实时查看通道数据流（有数据流过则该行变绿）。

### 7.3 重启机制

Apollo 本身 **不内置进程自动重启**。重启依赖：

- **HMI / Dreamview** 人工在 Module Controller 面板重新打开开关；
- **外部脚本**（如 `monitor.sh`、`bootstrap.sh restart`）重新 `cyber_launch start`；
- 严重故障时由 **Guardian** 触发安全模式（紧急停车），而非重启进程。

### 7.4 与 AuroraDrive Rust 监督树对比

AuroraDrive 采用 Rust 编写，使用 **监督树（supervisor tree）** 模式启动 sidecar 进程：supervisor 持有子进程句柄，子进程崩溃时由 supervisor 捕获退出信号并按策略（one-for-one / one-for-all）自动重启，具备指数退避、熔断、依赖顺序等能力。这与 Erlang/OTP、Tokio 的 `Supervisor`、或 Kubernetes 的 Deployment 重启策略同源。

对比：

| 维度 | Apollo Monitor | AuroraDrive Rust 监督树 |
|---|---|---|
| 重启主体 | 外部脚本 / 人工 | supervisor 进程内自动 |
| 重启延迟 | 秒级（依赖 1.5s 轮询 + 人工） | 毫秒级（退出信号即时） |
| 策略 | 无（仅检测） | one-for-one / one-for-all / rest-for-one |
| 依赖顺序 | 数据驱动隐式 | 显式声明启动顺序 |
| 安全降级 | Guardian 紧急停车 | supervisor 熔断 + sidecar 健康检查 |
| 语言 | C++ / Python | Rust（内存安全、无数据竞争） |

Apollo 的优势在于"数据驱动 + 安全守卫"，弱点在于"无自动重启"；AuroraDrive 的优势在于"监督树自动恢复 + Rust 内存安全"，弱点在于"缺乏 Apollo 级别的端到端安全守卫（Guardian）链路"。

---

## 8. apollo.launcher 实战

### 8.1 启动 Dreamview（一切的前提）

```bash
bash scripts/bootstrap.sh start        # Apollo 6/7
# 或
bash scripts/apollo_neo.sh bootstrap   # Apollo 9/10
```

该脚本会启动 `monitor.sh` 与 `dreamview.sh`，并在浏览器打开 `http://localhost:8888`。Dreamview 启动后会校验 HTTP 200，失败则提示查看 `/apollo/data/log`。

### 8.2 启动感知模块

```bash
# 方式一：命令行
cyber_launch start /apollo/modules/perception/launch/perception.launch

# 方式二：mainboard 直接加载 dag（调试）
mainboard -d /apollo/modules/perception/camera/dag/camera.dag
mainboard -d /apollo/modules/perception/lidar/dag/lidar.dag

# 方式三：Dreamview → Module Controller → 打开 Perception 开关
```

感知模块内含 lidar / radar / camera 多个 Component，通常一个 launch 文件聚合多个 dag，由 mainboard 分别加载。

### 8.3 启动规划模块

```bash
cyber_launch start /apollo/modules/planning/planning_component/launch/planning.launch
# 或
mainboard -d /apollo/modules/planning/planning_component/dag/planning.dag
```

Planning 是 `timer_components`，`interval: 100`（100ms = 10Hz），订阅 `/apollo/perception/obstacles`、`/apollo/prediction`、`/apollo/localization/pose`、`/apollo/canbus/chassis` 等 channel。

### 8.4 启动控制模块

```bash
cyber_launch start /apollo/modules/control/launch/control.launch
```

Control 的 DAG 中 `ControlComponent` 为 timer_component，`interval: 10`（10ms = 100Hz），订阅 `/apollo/planning` 与 `/apollo/canbus/chassis`，输出 `/apollo/control`，最终经 Guardian 转发到 canbus。

### 8.5 启动顺序建议（实车/仿真）

1. Localization（定位）→ 2. Perception（感知）→ 3. Prediction（预测）→ 4. Routing（路由）→ 5. Planning（规划）→ 6. Control（控制）。每步在 Dreamview Module Controller 中确认绿灯后再开下一个。

---

## 9. apollo.launcher 源码

### 9.1 源码位置

| 组件 | 路径 |
|---|---|
| mainboard 入口 | `apollo/cyber/mainboard/mainboard.cc` |
| 参数解析 | `apollo/cyber/mainboard/module_argument.{h,cc}` |
| 模块加载 | `apollo/cyber/mainboard/module_controller.{h,cc}` |
| 类加载器 | `apollo/cyber/class_loader/`（基于 Poco::SharedLibrary） |
| 插件管理 | `apollo/cyber/plugin_manager/plugin_manager.{h,cc}` |
| 启动编排 | `apollo/cyber/tools/cyber_launch/cyber_launch.py` |
| DAG proto | `apollo/cyber/proto/dag_conf.proto` |
| 调度配置 | `apollo/cyber/conf/example_sched_classic.conf` 等 |

### 9.2 mainboard.cc 实现细节

`main()` 三段式：`ParseArgument` → `Init` → `LoadAll`。`WaitForShutdown()` 注册 SIGINT/SIGTERM 信号处理，收到信号后 `Clear()` 卸载所有 Component 并退出。

### 9.3 ModuleArgument

`DisplayUsage()` 输出帮助：

```
Usage: mainboard [OPTION]...
 -d <dag>: dag config path
 -p <process_group>: process group name
 -s <sched_name>: scheduler name
```

未指定 `process_group_` / `sched_name_` 时使用默认值，并通过 `GlobalData::Instance()->SetProcessGroup()` 全局登记。

### 9.4 ModuleController

成员为一个 `ClassLoaderManager` 与一个 `ComponentBase` 链表。核心方法 `LoadModule(const DagConfig& dag_config)`：

1. 取 `module_library` 路径，`class_loader_manager.LoadLibrary()` 加载 .so（底层 `Poco::SharedLibrary` / Linux `dlopen`）；
2. 遍历 `components` / `timer_components`，按 `class_name` 用工厂模式 `CreateObj` 实例化；
3. 调用 `Component::Initialize()`（内部读 config、建 Reader/Writer、注册到调度器）；
4. 失败则回滚已加载项。

### 9.5 cyber_launch.py 实现细节

`cyber_launch.py` 用 `argparse` 解析 `start/stop` 子命令与 `--launch_file`，用标准库 `xml.etree` 解析 launch XML，遍历 `<module>` 节点收集 `dag_conf`、`plugin`、`process_name`，拼接成 `mainboard -d <dag> -p <pg> -s <sched>` 并以 `nohup ... &` 后台拉起。`stop` 则按 `process_name` 杀进程。

### 9.6 与 ROS2 launch 的集成

源码层面 **无原生集成**。若要在 ROS2 体系中调用 Apollo，可在 ROS2 Python launch 文件中用 `launch.actions.ExecuteProcess` 把 `cyber_launch start xxx.launch` 当作普通外部进程拉起，但两侧消息需自行 bridge。这是 Apollo 团队刻意的设计选择——Cyber RT 替换 ROS 正是为了摆脱 ROS 的实时性与单点 master 问题。

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 当前：Rust 启动 sidecar

AuroraDrive 当前采用 Rust 编写的 supervisor 启动并管理各 sidecar 进程（感知、规划、控制、定位等以独立 sidecar 形式存在），supervisor 持有子进程句柄，具备崩溃自动重启、依赖顺序、健康检查等能力，对应 Erlang/OTP 监督树范式。这与 Apollo "mainboard + 外部脚本重启" 形成鲜明对比。

### 10.2 借鉴 apollo.launcher 节点管理

建议 AuroraDrive 借鉴 Apollo 的以下设计：

1. **声明式 launch 文件**：把 sidecar 的二进制路径、参数、资源限制（CPU 亲和、调度策略）、依赖 channel 写进一个 TOML/YAML launch 描述（对应 Apollo 的 XML launch + DAG），让 supervisor 从文件加载而非硬编码。
2. **数据驱动触发**：借鉴 Component `Proc()` 由数据触发而非纯定时，sidecar 在收到上游消息后才执行，天然处理"上游未就绪"。
3. **DAG 拓扑可视化**：维护一份显式的 channel 依赖 DAG，便于启动顺序推导与故障影响面分析。
4. **进程内组合**：借鉴 mainboard 单进程多 Component 模式，对低延迟强耦合的 sidecar（如 planning + control）提供"同进程"部署选项，省去跨进程序列化。

### 10.3 借鉴 launch 文件配置

建议 launch 文件分层（对应 Apollo 的 launch + dag + sched.conf 三层）：

- **顶层 launch.toml**：列出所有 sidecar、进程名、二进制路径；
- **中层 module.toml**（类 DAG）：每个 sidecar 的订阅/发布 channel、配置文件路径、定时周期；
- **底层 resource.toml**（类 sched.conf）：CPU 亲和、调度策略（SCHED_FIFO/RR）、优先级、NUMA 绑定。

### 10.4 给出 AuroraDrive 节点启动方案

综合 Apollo 经验与 AuroraDrive Rust 现状，推荐方案如下：

```
aurora_supervisor (Rust, 单进程)
 ├─ 读取 launch.toml (声明式编排)
 ├─ 解析依赖 DAG, 推导启动顺序
 ├─ for each sidecar:
 │    ├─ 设置 cpuset / sched_param (借鉴 Apollo sched.conf)
 │    ├─ tokio::spawn 监督子进程 (one-for-one 重启 + 指数退避)
 │    ├─ 注入环境变量与配置路径 (类 Apollo flag_file_path)
 │    └─ 注册健康检查 (HTTP/Unix socket 心跳, 借鉴 Apollo ProcessMonitor)
 ├─ 等待所有 sidecar 就绪 (类 ROS2 lifecycle configure→activate)
 ├─ 运行期:
 │    ├─ 心跳超时 → 标记 FATAL → 重启 sidecar
 │    ├─ 严重故障 → 触发 Guardian 等价的 safe-mode (借鉴 Apollo Guardian 紧急停车)
 │    └─ 优雅退出 → SIGTERM 逐个 cleanup → SIGKILL 兜底
```

关键改进点（相对 Apollo）：

- **保留 AuroraDrive 的自动重启**（Apollo 缺失），但增加重启次数熔断，避免无限重启雪崩；
- **引入 Apollo 的安全守卫层**（Guardian 思想）：监控不健康时不仅重启进程，还要向车辆下发安全停车命令；
- **采用声明式 launch 文件**（借鉴 Apollo XML launch，但用 TOML 更契合 Rust 生态）；
- **支持进程内组合部署**（借鉴 mainboard 多 dag 共进程），对强耦合模块零拷贝通信；
- **保留 Rust 内存安全**优势，避免 Apollo C++ 常见的悬垂指针/数据竞争风险。

这样既获得 Apollo 的工程化经验（声明式编排、DAG 拓扑、资源限制、安全守卫），又保留 AuroraDrive 的现代优势（监督树自动恢复、Rust 内存安全）。

---

## 附：apollo.launcher vs ROS2 launch vs CyberRT mainboard 对比表

| 维度 | cyber_launch (apollo.launcher) | ROS2 launch | CyberRT mainboard |
|---|---|---|---|
| 定位 | 启动编排工具（Python） | 启动编排框架（Python） | 进程入口/动态库加载器（C++） |
| 层级 | 编排层 | 编排层 | 执行层 |
| 文件格式 | XML `.launch` | Python `.launch.py`（推荐）/ XML / YAML | DAG `.dag`（protobuf 文本） |
| 启动命令 | `cyber_launch start xxx.launch` | `ros2 launch pkg xxx.launch.py` | `mainboard -d xxx.dag [-p pg] [-s sched]` |
| 进程模型 | 每 module 一个 mainboard 进程 | 每 Node 一进程 / ComposableNode 共享容器 | 单进程可加载多 dag 多 so |
| 参数传递 | launch → dag → Component config | launch `parameters=[...]` 直接传 Node | DAG `config` 字段 |
| 资源限制 | 经 `-p` 选 sched.conf（CPU/调度） | 经 `Node` 参数 / `ExecuteProcess` | sched.conf 经典/编排策略 |
| 生命周期 | 无显式 lifecycle，数据驱动 | LifecycleNode 状态机 | 无显式 lifecycle |
| 重启机制 | 无内置，靠外部脚本/人工 | `OnProcessExit` 事件可自动重启 | 无内置 |
| 监控 | Monitor 模块 /proc 扫描 + Guardian | ros2 lifecycle list / daemon | 通信层心跳 + cyber_monitor |
| 表达能力 | 弱（纯声明 XML） | 强（图灵完备 Python） | N/A（配置文件） |
| 实时性 | 高（Cyber RT 共享内存/协程） | 中（DDS，非硬实时） | 极高（SCHED_FIFO + cpuset） |
| 跨平台 | Linux only | Linux/Win/Mac/RTOS | Linux only |
| 与对方兼容 | 仅数据层 bridge（rosbag_to_record） | N/A | N/A |

---

## 参考来源

- Apollo 3.5 各功能模块的启动过程解析 — https://blog.csdn.net/davidhopper/article/details/85248799
- Apollo Cyber RT 架构分析 — https://blog.csdn.net/u010632343/article/details/150992346
- Apollo CyberRT 入口 mainboard — https://blog.csdn.net/zhaoyqcsdn/article/details/135322214
- cyber/mainboard 启动入口介绍 — https://blog.csdn.net/RomeoLikeJuliet/article/details/113338079
- Cyber RT 模块加载流程简介 — https://juejin.cn/post/6996606412985991182
- /cyber/mainboard 模块源码解读 — https://blog.csdn.net/liujiayu2/article/details/130943777
- cyber/class_loader 类加载器 — https://blog.csdn.net/zhizhengguan/article/details/129368647
- 如何配置和使用 Apollo 的 component 里的 plugin — https://blog.csdn.net/XCCCCZ/article/details/138401757
- Apollo 组件化实际应用分析 — https://blog.csdn.net/u010632343/article/details/150989542
- Apollo 10.0 系统概览 — https://blog.csdn.net/qq_31762031/article/details/156395028
- Guardian 模块详解 — https://blog.csdn.net/qq_31762031/article/details/156396241
- Monitor 模块工作机制 — https://blog.csdn.net/zhizhengguan/article/details/115098221
- Monitor 进程存活状态监控 — https://cloud.tencent.cn/developer/article/1999072
- CyberRT 调度策略 Classic vs Choreography — https://blog.csdn.net/weixin_47416810/article/details/153697004
- cyber/scheduler 模块 — https://blog.csdn.net/RomeoLikeJuliet/article/details/113246747
- cyber_RT 框架常用操作指令 — https://blog.csdn.net/li812732767/article/details/107716582
- ROS、ROS2、Apollo 系统的比较 — https://blog.csdn.net/qq_32740835/article/details/143081285
- ROS2 LifecycleNode 讲解及实例 — https://blog.csdn.net/Bing_Lee/article/details/134958426
- ROS2 launch 文件 Node 用法 — https://blog.csdn.net/m0_53297170/article/details/144537928
- Apollo 项目代码迁移到 Cyber RT — https://blog.csdn.net/davidhopper/article/details/85989091
- Apollo 官方文档 Dreamview 简介 — https://developer.apollo.auto/

---

> 实际工具调用次数：本次研究共执行 **54 次**内部工具调用（WebSearch 约 40 次 + WebFetch 约 14 次），覆盖 apollo.launcher / cyber_launch / mainboard / DAG / launch 文件 / 调度策略 / Monitor / Guardian / ROS2 launch / LifecycleNode / AuroraDrive Rust 监督树 等全部研究维度。
