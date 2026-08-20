# 百度 Apollo CyberRT 通信框架深度研究报告

> 研究范围：CyberRT 架构、服务发现、数据传输、QoS、Tasks 调度、时间与日志、与 ROS2 对比、关键类、Apollo 源码、AuroraDrive 迁移建议
> 数据来源：Apollo 官方文档、ApolloAuto/apollo GitHub 源码、CSDN/掘金深度源码解析、Apollo 10.0 Release 说明等
> 文档版本：v1.0  生成日期：2026-07-23

---

## 0. 概述与历史定位

Apollo Cyber RT（下文统称 CyberRT）是百度在 Apollo 3.5（2019 CES 发布）中推出的、专为自动驾驶场景设计的开源高性能运行时框架，用以替代此前基于 ROS 1 的通信与调度层。在 v3.0 及之前，Apollo 直接基于 ROS 进行开发并做了若干改进（共享内存传输、RTPS 适配等），但 ROS 1 的中心化 master、基于 TCP 的进程间通信、缺乏实时性保证、深拷贝开销等问题在量产自动驾驶场景下逐渐无法满足需求。

CyberRT 的核心设计目标三件事：**高并发、低延迟、高吞吐**，并为自动驾驶提供**确定性（determinism）**而非单纯峰值性能。其总体特征包括：

- 基于**中心化计算模型**（集中式计算），针对自动驾驶的高并发/低延迟/高吞吐做深度优化；
- 引入 **Component 组件化** 概念，实现模块封装；
- 引入**协程（Coroutine）**与用户态调度器，避免内核态切换开销；
- 引入**无锁对象**与共享内存传输，提升通信效率；
- 基于 **FastRTPS / DDS** 实现去中心化的服务发现与跨主机通信，**No Broker**（不同于 ROS 1 的 master）；
- 借鉴 ROS 的 Publish/Subscribe 与 Service/Client 双通信模式，但底层全部重写。

从 Apollo 5.5 到 9.0，CyberRT 内核基本稳定；Apollo 10.0（2024-12 发布）罕见地对 CyberRT 做了较大升级：引入基于 **Protobuf Arena** 的内存优化（据称性能提升 10 倍）、引入 **ICEORYX POD 零拷贝**通道重构跨进程 IPC、并新增 **ROS 互通桥（ros-bridge）** 适配 ROS 2 通信接口。

---

## 1. CyberRT 架构

### 1.1 modules/cyber 目录结构

CyberRT 源码位于 `modules/cyber/`，采用模块化设计，各子目录职责明确。结合官方文档与多篇源码解析，主要目录如下：

| 目录 | 职责 |
|------|------|
| `cyber.h` / `cyber.cc` | 框架入口，`Init()`/`CreateNode()`/`WaitForShutdown()`/`OK()` 等顶层 API |
| `common/` | 通用工具：`GlobalData`、`log.h`（AINFO/AERROR 等宏）、`macro.h`、`util.h` |
| `init.h` | 框架初始化（注册 shutdown handler、初始化 scheduler 等） |
| `node/` | `Node`、`NodeChannelImpl`、`NodeServiceImpl`，通信句柄 |
| `channel/` | `ChannelManager`（reader/writer 创建辅助） |
| `service/` / `service_discovery/` | Service/Client 实现 + 拓扑发现 |
| `transport/` | 底层数据传输：intra/shm/rtps/hybrid + dispatcher + endpoint |
| `message/` | `MessageHeader`、`MessageTypeTraits`、`RawMessage`、protobuf 包装 |
| `record/` | `RecordWriter`/`RecordReader`/`RecordViewer`，离线录制与回放 |
| `time/` / `timer/` | `Time`/`Duration`/`Clock`/`Rate` + `TimingWheel` 时间轮定时器 |
| `croutine/` | 协程 `CRoutine`、`RoutineContext`、`RoutineFactory`、context pool |
| `scheduler/` | `Scheduler` 基类、`SchedulerClassic`、`SchedulerChoreography`、`Processor` |
| `component/` | `ComponentBase`、`Component<>`（0~4 模板）、`TimerComponent` |
| `mainboard/` | 进程主函数（mainboard）、`ModuleArgument`、`ModuleController` |
| `class_loader/` | 动态库 `.so` 加载与组件实例化（POCO 风格 class loader） |
| `data/` | `DataDispatcher`、`DataVisitor`、`DataNotifier`、`CacheBuffer`（多通道融合） |
| `event/` / `task/` | 事件驱动、`TaskManager` 异步任务池 |
| `parameter/` | Parameter Server-Client 参数服务 |
| `logger/` | 基于 glog 的日志封装 |
| `tools/` | `cyber_recorder`、`cyber_monitor`、`cyber_visualizer`、`cyber_node` 等命令行工具 |
| `python/` | Python 绑定（`cyber.python`） |

程序入口 `cyber.h` 暴露的核心 API 包括：`Init()`、`CreateNode()`、`WaitForShutdown()`、`IsShutdown()`、`OK()`、`Duration`、`Rate`、`Time`、`Clock` 等。一个典型的 Cyber 程序结构是 `Init → CreateNode → CreateWriter/CreateReader → spin → WaitForShutdown`。

### 1.2 Node / Channel / Writer / Reader

**Node（节点）** 是 CyberRT 通信拓扑中的基本单元，类似于 ROS 中的 Node，但**无 master**。Node 充当"句柄"角色，负责创建 Reader/Writer/Service/Client。一个 Component 内部有且仅有一个 Node。`CreateNode()` 接口在 `cyber.cc` 中实现，最终 `new Node(node_name, name_space)`，节点名全局唯一，命名空间默认为空，格式为 `/namespace/node_name`。Node 在内部委托给 `NodeChannelImpl`（创建 reader/writer）与 `NodeServiceImpl`（创建 service/client）。

**Channel（通道）** 类似 ROS 中的 topic，是 publish/subscribe 的逻辑通道。Channel 通过名称标识，内部会 hash 成 `channel_id`（uint64）。CyberRT 支持三种通信模式：
- **Writer/Reader**：发布订阅模式，常用于数据流；
- **Service/Client**：请求响应模式，常用于命令式调用；
- **Parameter Server-Client**：参数服务。

**Writer（写者）** 由 `Node::CreateWriter<M>(channel_name, qos_depth)` 创建，内部持有 `Transmitter`（发送端抽象）。`Writer::Write(msg)` 调用 `Transmitter::Transmit()` 实际发送。Writer 初始化时会调用 `JoinTheTopology()`，向 `ChannelManager` 注册自身，并通过 `AddChangeListener` 监听 channel 拓扑变化（如新 Reader 上线则 `Enable(reader)`）。

**Reader（读者）** 由 `Node::CreateReader<M>(ReaderConfig)` 创建，内部持有 `Receiver`（接收端抽象）与 `pending_queue`（待处理队列）。Reader 在收到消息后，通过 `DataDispatcher` 将消息放入对应 channel 的 `CacheBuffer`，并触发 `DataNotifier` 通知绑定的 `DataVisitor`。Reader 还提供 `Observe()`/`GetLatestObserved()`/`GetOldestObserved()` 等接口供用户主动拉取。

### 1.3 mainboard 调度器与组件加载

`mainboard` 是 CyberRT/Apollo 软件系统的进程入口（相当于"exe"），其他模块都是链接在 mainboard 上的共享库（.so）。其处理流程分三阶段：

1. **启动参数解析**：`ModuleArgument` 解析 `-d`（dag 文件路径，支持多个）、`-p`（进程组名，用于加载 `/apollo/cyber/conf/<group>.conf` 调度配置）、`-s`（调度策略名）等参数。
2. **Cyber 运行环境初始化**：调用 `apollo::cyber::Init()`。
3. **模块加载**：`ModuleController`（持有 `ClassLoaderManager` 与 `ComponentBase` 链表）解析 dag 内容，通过 class_loader 动态加载 `.so`，实例化 Component，调用 `Initialize()`。

典型命令：`mainboard -d modules/perception/radar/contiRadar/contiRadar_component.dag -p cpu_one_sched`。

一个 mainboard 可加载多个 dag、多个 so。**单进程加载多个 so 的意义**：把进程间通信（共享内存）转为进程内通信（智能指针传递），效率更高。实测在 10 通道、50 帧、每帧 10MB 的负载下，多进程会异常而单进程正常；且多进程打开 `cyber_monitor` 观察时会影响进程内通信稳定性。**代价**是单进程占用资源多，需要 `cpu_one_sched.conf` 等调度配置增大协程并发数（默认 8）。

### 1.4 Component 注册机制

Component 是构建应用模块的基类。`ComponentBase`（`cyber/component/component_base.h`）是纯虚基类，继承自 `enable_shared_from_this`，有两个子类：
- `Component<M0, M1, M2, M3>`：常规组件，模板支持 0~4 个输入 channel，用户需重写 `Init()` 与 `Proc(msg0, msg1, ...)`；
- `TimerComponent`：定时组件，用户重写 `Init()` 与 `Proc()`，由定时器周期触发。

Component 的 `Initialize()` 流程（以双通道为例）：
1. 创建 Node（`node_.reset(new Node(config.name()))`）；
2. `LoadConfigFiles()` 加载 dag 中指定的配置文件路径；
3. 调用用户自定义 `Init()`；
4. 根据 dag 中 `readers` 字段创建若干 `Reader`（含 qos_profile 与 pending_queue_size）；
5. 创建回调 lambda，内部执行用户 `Proc()`；
6. 创建 `data::DataVisitor<M0, M1>`（融合多通道数据），绑定回调；
7. 通过 `croutine::CreateRoutineFactory` 创建协程工厂，`scheduler->CreateTask(factory, node_->Name())` 创建协程任务。

**Component 注册宏**：在 `.cpp` 末尾添加 `CYBER_REGISTER_COMPONENT` 或 `CLASS_LOADER_REGISTER_CLASS(name, apollo::cyber::ComponentBase)`，将组件类注册到 class_loader，使其可被 dag 文件按 `class_name` 动态加载实例化。这种动态加载机制让 DreamView 中的"模块开关"实际上是动态加载/卸载对应 .so。

### 1.5 DAG（有向无环图）

DAG（Directed Acyclic Graph）是 CyberRT 描述模块拓扑结构的配置文件（protobuf 文本格式，`.dag`）。其核心字段：

```protobuf
module_config {
  module_library : "/apollo/bazel-bin/modules/planning/libplanning_component.so"
  components {
    class_name : "PlanningComponent"
    config {
      name: "planning"
      readers: [ { channel: "/apollo/perception/obstacles", qos_profile:{depth:10} } ]
      config_file_path: "modules/planning/conf/planning_config.pb.txt"
    }
  }
  timer_components { ... }  # 定时组件
}
```

DAG 声明了：加载哪个 .so、实例化哪个类、订阅哪些 channel、qos 配置、配置文件路径。框架在运行时刻根据所有预定义 Component 生成有向无环图，把融合好的传感器数据和 Component 打包成用户级轻量任务（协程），由调度器根据资源可用性与优先级派发。

---

## 2. 服务发现 Service Discovery

### 2.1 总体结构

服务发现与拓扑管理的实现集中在 `cyber/service_discovery/`，核心类是 `TopologyManager`（单例，每进程一个）。它有三个子管理器，共同基类 `Manager`：

- **NodeManager**：管理拓扑中的节点（顶点）；
- **ChannelManager**：管理 channel（边）；
- **ServiceManager**：管理 Service 与 Client。

底层完全依赖 **FastDDS（FastRTPS）** 的发现机制。节点间通过读端/写端建立数据通路，以 channel 为边构成动态数据流网络（节点可能退出、订阅可能改变，故网络动态），需监控拓扑。

### 2.2 两种拓扑监控机制

CyberRT 有**两层**拓扑变化监控：

**① 基于 FastRTPS 的自动发现（被动）**：
- `TopologyManager::CreateParticipant()` 创建 `transport::Participant`，名称为 `HostName + ProcessId`，监听端口默认 11511，domain_id 默认 80（可由环境变量 `CYBER_DOMAIN_ID` 覆盖）。
- `ParticipantListener` 监听网络变化，FastRTPS 上报 `ParticipantDiscoveryInfo`，经 `TopologyManager::Convert()` 转成 CyberRT 的 `ChangeMsg`，调用 `OnParticipantChange()`，进而触发各子管理器 `OnTopoModuleLeave()` 更新信息（如 NodeManager 删除节点）。
- 优点：进程崩溃或设备断开也能工作；缺点：粒度粗、不及时（如断开时）。

**② 基于主动广播（主动）**：
- `TopologyManager::Init()` 中初始化各子管理器，调用 `StartDiscovery()`，基于 `RtpsParticipant` 创建 subscriber/publisher，channel 名分别为 `node_change_broadcast`、`channel_change_broadcast`、`service_change_broadcast`。
- Subscriber 回调 `Manager::OnRemoteChange()` 解析变更消息并 `Dispose()` 处理。
- 主动触发点：`NodeChannelImpl` 创建时调 `NodeManager::Join()`；Reader/Writer 初始化时调 `JoinTheTopology()` → `ChannelManager::Join()`；退出调 `LeaveTheTopology()`。
- `Manager::AddChangeListener()` 注册拓扑变化回调，如 `Reader::JoinTheTopology()` 注册 `Reader::OnChannelChange()`，当有新 Writer 上线时 Reader 会 enable 对应 receiver。

### 2.3 Warehouse（角色仓库）

`cyber/service_discovery/warehouse/` 提供 `WarehouseBase`（纯虚）、`SingleValueWarehouse`（内部 `unordered_map<uint64_t, RolePtr>`，一个 key 对应一个 role）、`MultiValueWarehouse`（`unordered_multimap`，允许重复 key）。它们是子管理器维护角色（RoleBase/RoleAttributes）的存储容器，提供 Add/Remove/Search/GetAllRoles 接口。

### 2.4 Channel 发现与建链

当 Writer Join 拓扑时，会通过 `ChannelManager::GetReadersOfChannel()` 查询现有 Reader，对每个 Reader 调用 `Transmitter::Enable(reader)`；当新 Reader Join 时，通过 change listener 通知所有 Writer enable。这样就动态建立了 Writer-Reader 数据通路，无需中心化 broker。`RoleAttributes`（`role_attributes.proto`）含 host_name、process_id、uuid hash 作为 id，用于判断双方相对位置（SAME_PROC / DIFF_PROC / DIFF_HOST）。

---

## 3. 数据传输

### 3.1 三种传输模式 + Hybrid

`Transport`（单例）在构造时一次性创建好三种 dispatcher：`intra_dispatcher_`、`shm_dispatcher_`、`rtps_dispatcher_`。根据 `CommunicationMode` 选择传输后端：

| 模式 | 场景 | 实现 | 说明 |
|------|------|------|------|
| **INTRA** | 同进程内 | `IntraTransmitter`/`IntraReceiver` + `IntraDispatcher` | 直接传智能指针/指针，零拷贝，最高效 |
| **SHM** | 同主机跨进程 | `ShmTransmitter`/`ShmReceiver` + `ShmDispatcher` | 共享内存 + Notifier 通知 |
| **RTPS** | 跨主机 | `RtpsTransmitter`/`RtpsReceiver` + `RtpsDispatcher` | 基于 FastRTPS/DDS，网络传输 |
| **HYBRID** | 默认混合 | `HybridTransmitter`/`HybridReceiver` | 根据双方位置关系选择上述三者 |

`CreateTransmitter`/`CreateReceiver` 时 `switch(mode)` 创建对应派生类（不填默认 hybrid）。Hybrid 模式包含 RTPS+SHM+INTRA 三种 Transmitter 实例，`Enable(reader)` 时根据 `GetRelation(opposite_attr)` 决定 enable 哪个；`Transmit()` 时遍历所有已 enable 的 transmitter 各发一次。

### 3.2 共享内存传输（ShmChannel）详解

SHM 是同主机跨进程的主力传输方式，实现位于 `cyber/transport/shm/`。

**数据共享结构**：
- 每个 Transmitter 根据当前 `channel_id` 创建 `Segment`（由 `SegmentFactory::CreateSegment`），有两种平台实现 `PosixSegment`/`XsiSegment`。
- 单例 `ShmDispatcher` 根据 Receiver 注册时的 `channel_id` 建立 `<channel_id, Segment>` 容器；同一 `channel_id` 的 Segment 在不同进程中映射同一物理内存。
- Segment 内存布局：`EXTRA_SIZE(4K) + STATE_SIZE(1K) + (BLOCK_SIZE(1K) + block_buf_size) * block_num`。
- block 大小分级：16K(512 blocks)/128K(128)/1M(64)/8M(32)/16M(16)/32M(8)。msg 越大，队列越短。
- 每个 Block 通过原子变量 `lock_num_` 实现读写互斥（类似 AtomicRWLock），等价于在共享内存上实现读写安全队列。
- `State` 共享当前状态：下一个可写 Block 下标、是否需 remap 等，全部用原子类型保证进程间同步安全。

**写入流程**：
1. Transmitter 调 `Segment::AcquireBlockToWrite()`，通过 `State::FetchAddSeq(1) % block_num` 得到候选 index，`TryLockForWrite()` 加写锁；
2. 若 msg 大小超过当前 Block 的 `MESSAGE_SIZE_n`，触发 **remap**：Segment 重新创建更大内存，其他进程读取 State 时发现需 remap 也重新映射（Segment 创建时默认用最小 16K，所以大 msg 首次写入必触发 remap）；
3. 在 `WritableBlock.buf` 写入 protobuf 序列化的 msg，再写 `msg_info`；
4. 通过 `Notifier::Notify(ReadableInfo)` 写入共享通知区，`ReadableInfo` 含 `host_id_`、`block_index_`、`channel_id_`。

**通知机制（ConditionNotifier）**：
- `Indicator` 在共享内存中全局唯一（key = `Hash("/apollo/cyber/transport/shm/notifier")`），所有进程的 Transmitter/Dispatcher 共用一份。
- 结构：`std::atomic<uint64_t> next_seq` + `ReadableInfo infos[kBufLength=4096]` + `uint64_t seqs[kBufLength]`。
- `Notify()`：`seq = next_seq.fetch_add(1)`，`idx = seq % kBufLength`，写 `infos[idx]` 和 `seqs[idx]`。
- `Listen(timeout, *info)`：Dispatcher 线程周期调用，对比本地 `next_seq_` 与共享 `next_seq`，不等则有新数据，按本地 `next_seq_` 取 idx 读 `infos[idx]`，校验 `actual_seq >= next_seq_` 后返回（保证多进程并发安全）。

**读取流程**：
- `ShmDispatcher::Init()` 创建监听线程 `ThreadFunc`，循环 `Listen()`；
- 拿到 `ReadableInfo` 后，按 `channel_id` 找 Segment、按 `block_index` 找 Block（加读锁），读出 msg+msg_info，反序列化；
- 调用 `ShmDispatcher::OnMessage()` 按 channel_id 派发到对应回调。

另有 `MulticastNotifier` 通过指定 socket 广播通知，区别于共享内存 ConditionNotifier。

### 3.3 Intra 与 RTPS

- **INTRA**：`IntraTransmitter::Transmit()` 直接调读端 `IntraDispatcher::OnMessage()`，零拷贝指针传递。
- **RTPS**：`RtpsTransmitter` 封装 FastRTPS publisher，`Transmit()` 将消息序列化为 `UnderlayMessage`（FastRTPS 格式）发出；`RtpsReceiver` 的 `dispatcher_` 指向单例 `RtpsDispatcher`，维护 channel_id→subscriber 表，回调统一 `RtpsDispatcher::OnMessage()` 派发。

### 3.4 Protobuf 序列化与消息层

`cyber/message/` 提供：
- `MessageHeader`：序列化时放在 protobuf 内存前面，记录消息序列号、消息体大小等属性；
- `MessageTypeTraits`：类型萃取，判断是否有 serializer；
- `RawMessage`：通用包装类型，含 `data`(bytes) + `data_type`(string)，让不支持模板的传输通道（如 RTPS）能透传任意 protobuf；
- `PyMessageWrap`：Python 消息包装。

序列化使用标准 protobuf `SerializeToString`/`ParseFromString`。**Apollo 10.0 关键优化**：引入 **Protobuf Arena**（一次性分配大块内存，集中管理小对象，减少频繁 malloc/内存碎片），针对深拷贝场景性能提升约 10 倍。注意 Arena 不支持 string/bytes 这类自管理数据结构，重度依赖 string 的 message 收益有限。

---

## 4. QoS 服务质量

CyberRT 的 QoS 借鉴 DDS 标准，通过 `QosProfile`（`qos_profile.proto`）配置，在 dag 的 `readers` 字段或 `CreateWriter/CreateReader` 时指定。

### 4.1 QoS 策略表

| 策略 | 取值 | 含义 | 典型场景 |
|------|------|------|----------|
| **Reliability** | `RELIABLE` | 保证送达，可能重传（类 TCP） | 控制命令、配置、低频关键消息 |
| | `BEST_EFFORT` | 尽力送达，不保证（类 UDP） | 高频传感器数据（点云/图像），丢一帧无所谓 |
| **History** | `KEEP_LAST` | 保留最近 N 条（depth 指定） | 实时数据流，只关心最新 |
| | `KEEP_ALL` | 保留全部历史 | 录制/回放、需要完整序列 |
| **Durability** | `VOLATILE` | 不为晚加入的订阅者保留数据 | 默认，实时数据 |
| | `TRANSIENT_LOCAL` | 为后订阅者保留数据（如 latched topic） | 地图、静态配置发布一次后新节点也能收到 |
| **Depth** | 整数 | KEEP_LAST 时缓存条数 | 如 depth=10 缓存 10 帧供插值 |
| **Mps（消息率）** | int32 | 每秒最大消息数，流控 | 限速防雪崩 |

`QosProfile` 在 `ReaderConfig` 中随 reader 创建传入，protobuf 定义含 `depth`、`history(QosHistoryPolicy)`、`reliability(QosReliabilityPolicy)`、`durability(QosDurabilityPolicy)`、`mps` 等字段。例如 routing 模块 dag：`readers:[{channel:"/apollo/raw_routing_request", qos_profile:{depth:10}}]`。

### 4.2 死锁检测与流控

- **流控**：通过 `mps`（messages per second）限制发布速率；History KEEP_LAST + depth 防止积压；`pending_queue_size` 控制 reader 待处理队列长度，溢出时丢老帧。
- **死锁/背压**：DataVisitor 融合多通道数据时，若某通道长期无数据会阻塞协程唤醒；CyberRT 通过 CacheBuffer + Notifier 解耦，配合调度器协程 yield 避免线程阻塞。ChannelManager 监控拓扑，节点离开时 `OnTopoModuleLeave` 释放等待。
- **SHM 读写互斥**：Block 用原子 `lock_num_` 实现读写锁，写满时 `GetNextWritableBlockIndex` 循环尝试下一个，避免死锁；存在已知 bug（如 `condition_notifier` 包重复/丢包）需注意。

---

## 5. Tasks 调度

### 5.1 协程（CRoutine）

协程实现位于 `cyber/croutine/`，核心类 `CRoutine`。CyberRT 协程属于**非共享栈（stackfull）、非对称（asymmetric）、汇编切换**的方式：

- `RoutineContext` 存放上下文：一块 8MB 栈空间 + 栈指针 `sp`。所有 RoutineContext 由全局 `CCObjectPool`（lock-free，`concurrent_object_pool.h`）预分配管理，避免运行时动态分配（动态分配是实时性杀手）。
- `MakeContext(f, arg, ctx)`：在栈顶依次放 7 个 callee-saved 寄存器空间（rdi, rbx, rbp, r12-r15）与 `CRoutineEntry` 函数指针，符合 x86_64 ABI calling convention。
- `SwapContext(src_sp, dest_sp)` → 汇编 `ctx_swap`（swap.S）：pushq 保存当前 callee-saved 寄存器到 src 栈，`movq %rsp, (%rdi)` 保存 rsp；`movq (%rsi), %rsp` 切到 dest 栈，popq 恢复寄存器，`ret` 跳到 `CRoutineEntry`。
- `Resume()`：调度器切到目标协程；`Yield()`：协程交出控制权回调度器。两个 thread_local 变量：`current_routine_`（当前协程）、`main_stack_`（系统栈）。
- 协程状态机：READY / RUNNING / FINISHED / WAITING 等。

**协程切换开销**：完全在用户态，不陷入内核，开销接近普通函数调用（数十纳秒级），远小于线程切换（微秒级 + 内核态切换）。缺点：单协程不主动 yield 无法被抢占；不能利用多 CPU 并行（需配合多线程 Processor）。

### 5.2 调度器 Scheduler（Classic / Choreography）

`cyber/scheduler/` 核心类层次：

- **Scheduler**（基类）：4 个纯虚函数 `RemoveTask`/`DispatchTask`/`NotifyProcessor`/`RemoveCRoutine`；`CreateTask(factory, name)` 创建协程并入队；`ProcessLevelResourceControl` 设调度线程 CPU 亲和性；`SetInnerThreadAttr` 设特殊线程（如日志线程）属性。
- **Processor**（执行器）：持有 `std::thread` + `ProcessorContext`，`Run()` 循环取下一协程 Resume 执行。
- **ProcessorContext**（抽象）：`NextRoutine`/`Wait`/`Shutdown`，两实现 `ClassicContext`/`ChoreographyContext`。
- **policy/**：`SchedulerClassic`、`SchedulerChoreography`、`ClassicContext`、`ChoreographyContext`。

**SchedulerClassic（经典模式）**：
- 默认模式。协程按组（group）划分，每组按优先级（20 档）分小组。
- `ClassicContext` 用**静态成员**（所有线程共用一套协程队列）：`cr_group_`（组→优先级→协程列表 multimap）、`rq_locks_`（读写锁组）、`cv_wq_`/`mtx_wq_`（条件变量/互斥锁组）、`notify_grp_`。
- 任意协程可在该组任意线程执行。`NextRoutine` 按优先级从大到小取协程。
- `CreateProcessor`：执行器个数 = 分组数 × 每组执行器数，设 CPU 亲和性与调度策略（SCHED_OTHER/SCHED_RR/SCHED_FIFO）。

**SchedulerChoreography（编排模式）**：
- 高级模式。两套执行器：默认的 `ChoreographyContext` + pool 系列的 `ClassicContext`。
- `ChoreographyContext`：每个执行器独占，`cr_queue_`（multimap<优先级, 协程>），`Notify`/`Wait`/`Shutdown` 控制阻塞唤醒（notify 标志位 + 条件变量）。
- 支持把指定 task 名的协程绑定到特定执行器（`cr_confs_`），实现核心链路独占 CPU。
- 适合对延迟确定性要求极高的关键链路（如感知→规划→控制）。

### 5.3 线程池与 DAG 编排

- **TaskManager**（`cyber/task/`）：单例，构造时创建 `task_pool_size_` 个协程，执行体为从任务队列取异步任务执行。
- **DAG 编排**：Component 间通过 channel 形成数据依赖图（DAG）。DataVisitor 负责多通道数据融合：当 Component 订阅的所有主 channel 都有新数据时，唤醒绑定协程执行 `Proc()`。每个 Reader 有独立协程读数据，n 通道 Component 至少 n+1 个协程。
- **inner thread 配置**：`threads` 字段可为非协程线程（日志、网络）设 cpuset/policy/prio；`process_level_cpuset` 设主线程亲和性。

### 5.4 协程切换开销实测意义

协程切换接近函数调用成本（几十 ns），虚拟线程/线程因涉及堆栈复制或内核态切换高一个数量级。CyberRT 用协程 + 用户态调度器避免了 Linux 线程 user/kernel space 切换开销，结合 CPU affinity 减少 cache miss，提供业务级调度（按优先级、按链路绑定），是实时性保证的关键。

---

## 6. 时间和日志

### 6.1 时间模块

`cyber/time/`：
- **Time**：封装 C++11 chrono，成员仅一个 `int64_t`（纳秒）。三种构造：`uint64_t`(纳秒)、`int`(纳秒)、`double`(秒)。支持加减比较、转字符串、转秒/毫秒、`SleepUntil`。`Time::Now()` 默认用 `steady_clock`（单调时钟，适合测耗时）。
- **Duration**：时间差，`int64_t` 纳秒。
- **Clock**：**专为仿真设计**，可让"当前时间"任意指定（`SetNow`），支持 `MODE_CYBER`（仿真时钟）/`MODE_REALITY`（真实时钟）。`Clock::NowInSeconds()` 返回 double 秒。仿真模式下所有模块用同一 Clock，保证回放一致性。
- **Rate**：精确帧率控制，`Sleep()` 用 `sleep_until(next_start)`，扣除任务执行时间，保证实际帧率不漂移。

C++11 时钟区别：`system_clock`（系统时钟，可改/可网络对时，测时差不准）、`steady_clock`（单调不可改，测耗时首选）、`high_resolution_clock`（高精度，实际是前两者别名）。

### 6.2 GPS PPS 时间同步

自动驾驶需全局统一时间基准。CyberRT 配合 GPS 授时：
- **1PPS（Pulse Per Second）**：GPS 模块每秒输出一个脉冲，ns 级精度，作为硬件同步信号；
- **NMEA 报文**：含秒级时间信息，经串口传输有延迟；
- **软件对时**：通过 `gpsd` + `chrony` + `pps-tools`，`refclock PPS /dev/pps1` 把 1PPS 作为参考时钟锁相，把系统时钟同步到 GPS 时间；
- **业务层**：CyberRT 各消息 `header.timestamp_sec` 取自 `Clock::NowInSeconds()`，全机统一。多传感器硬件触发同步（如相机 external trigger）也基于 PPS。

### 6.3 Cyber Log

`cyber/logger/` 基于 **glog** 封装，提供宏：`ADEBUG`/`AINFO`/`AWARN`/`AERROR`/`AFATAL`。支持配置输出目录、是否输出到 stderr、日志级别。日志宏采用流式写法（`AINFO << "..."`），内部异步写入，避免阻塞业务线程。Apollo 10.0 仍沿用 glog 风格，并提供结构化日志扩展。

### 6.4 Cyber Recorder（离线录制/回放）

`cyber_recorder` 工具录制报文到文件，文件格式由 `cyber/proto/record.proto` 描述。**文件结构**：

```
[Section: HEADER]  [Section: CHANNEL]...  [Section: CHUNK_HEADER + CHUNK_BODY]...  [Section: INDEX]
```

- **Section**（`cyber/record/file/section.h`）：统一包裹，含 `type`(SectionType) + `length`，便于按单位读取。
- **Header**：文件头，最大 2048 字节（`HEADER_LENGTH`），含 `index_position`（指向 Index 起始）、`chunk_number`、`chunk_interval`(默认 20s) 等。内存维护一份，关闭前回写。
- **Channel**：`{name, message_type, proto_desc}`。`proto_desc` 是 FileDescriptorProto，回放时无需依赖额外 proto 文件即可反序列化。Channel 在该通道首次上线时写入，位置不固定，需靠 Index 定位。
- **Chunk**：报文存储区，由 `ChunkHeader`（起止时间、数量）+ `ChunkBody`（多条 `SingleMessage`）组成。按 20s 或大小切片。
- **SingleMessage**：`{channel_name, time(接收时刻), content(RawMessage/protobuf bytes)}`。
- **Index**：尾部，含指向 Channel/ChunkHeader/ChunkBody 的索引，按时间/通道查找报文。

工具链：`cyber_recorder play/record/info/view/split`、`cyber_monitor`（实时通道监控）、`cyber_visualizer`（点云/图像可视化）、`rosbag_to_record`（ROS bag 转 record）。`RecordViewer` 处理多通道/多文件回放的时间同步。

---

## 7. CyberRT 与 ROS2 对比

### 7.1 总体对比表

| 维度 | ROS 1 | ROS 2 | Apollo CyberRT |
|------|-------|-------|----------------|
| **架构** | 中心化 master | 去中心化 DDS | 去中心化 FastRTPS/DDS，No Broker |
| **通信底层** | TCPROS/UDPROS（自研） | DDS（FastDDS/Cyclone/RTI 等可换） | FastRTPS（DDS 实现） + 自研 SHM/INTRA |
| **进程内通信** | 有但不跨进程 | rclcpp Intra-process（需配置） | INTRA 模式，传指针，零拷贝 |
| **跨进程同主机** | 共享内存（改进版） | DDS SHM 传输 | SHM（Segment+Block+Notifier，自研） |
| **跨主机** | 网络 | DDS 网络 | RTPS 网络 |
| **消息序列化** | 自定义 + msg | IDL(dds) + msg | Protobuf（+ RawMessage 包装） |
| **调度模型** | 线程（回调） | 线程（Executor: Single/Multi/Static） | 协程 + 用户态调度器（Classic/Choreography） |
| **实时性** | 差（TCP，无保证） | 较好（DDS QoS + RTOS 支持） | 好（协程 + CPU 亲和性 + 优先级 + 业务级调度） |
| **QoS** | 基本无 | 完整 DDS QoS（Reliability/History/Durability/...） | 借鉴 DDS 的 QoS 子集（Reliability/History/Durability/Depth/Mps） |
| **组件模型** | Node + pub/sub | Node + Component(Composition) | Component/TimerComponent + DAG 动态加载 |
| **配置驱动** | launch(xml) | launch(py) | dag + launch(conf) + scheduler conf |
| **OS 支持** | Linux | Linux/Win/Mac/RTOS | Linux 为主 |
| **语言** | C++/Python2 | C++/Python3 | C++ 为主 + Python 绑定 |
| **录制格式** | rosbag | ros2 bag（sqlite3/mcap） | cyber record（自定义 protobuf） |
| **生态工具** | 极丰富 | 较丰富（rviz2/ros2 bag） | 自成体系（cyber_recorder/monitor/visualizer） |
| **面向场景** | 学术/机器人 | 机器人/工业 | 自动驾驶量产 |

### 7.2 DDS 的不同

- **ROS 2**：DDS 作为"中间件的中间件"，rclcpp 之下是 rmw（ROS middleware interface），可插拔 FastDDS/Cyclone DDS/RTI Connext 等。ROS 2 的进程内通信自己实现，其余走 DDS。QoS 不匹配时会**静默拒绝通信**（节点正常、话题存在但收不到数据，需 `--verbose` 看穿）。
- **CyberRT**：直接绑定 FastRTPS（eProsima 的 DDS 开源实现），未做 rmw 抽象层，但额外自研 SHM/INTRA 后端与 Hybrid 模式，性能可控性更强。domain_id 默认 80（ROS2 默认 0），leaseDuration/announcement_period 需差 30% 以上。

### 7.3 Apollo 9.0/10.0 适配 ROS2 的尝试

Apollo 9.0 开始引入 **ros-bridge**：适配 ROS 2 通信接口（基于 rclcpp），用插件方式降低 ROS message 的学习/开发成本，实现 cyber→ros_bridge→ros 与 ros→ros_bridge→cyber 双向通路。Apollo 10.0 进一步强化该桥。但业界评价其工程化价值有限：
1. 成型方案不会双中间件并存，维护成本指数上升；
2. 两套调度/环境单机运行工程性问题多；
3. 端到端大模型趋势下中间件性能需求弱化，多中间件互通是阶段性/伪需求；
4. 离线数据转换工具已能满足工具链需求。

### 7.4 性能对比要点

- **进程内**：Cyber INTRA 传指针 ≈ ROS2 intra-process（都接近零开销）；
- **跨进程同主机**：Cyber SHM 自研 Segment+Block+ConditionNotifier，理论单拷贝；Apollo 10.0 引入 **ICEORYX POD 真零拷贝**，CPU 减半、跨进程 IPC 极限性能大幅提升；ROS2 依赖 DDS SHM（FastDDS 也支持 iceoryx）；
- **调度延迟**：Cyber 协程切换 ns~低 μs 级，ROS2 线程 Executor 切换 μs 级；
- **protobuf 深拷贝**：Cyber 10.0 用 Arena 优化提升 10×；
- **实测**：一对多场景（1 发 3 收，10KB/帧，2ms 即 500Hz 发送）Cyber 可保持 2ms 间隔，>10ms 间隔无乱序抖动；多进程大负载（10 通道 50 帧 10MB）下 SHM 不稳，单进程 INTRA 稳定。

---

## 8. CyberRT 关键类索引

| 命名空间/类 | 位置 | 职责 |
|-------------|------|------|
| `apollo::cyber::Init/CreateNode/WaitForShutdown` | `cyber.h/cc` | 框架入口 |
| `cyber::Node` | `cyber/node/node.h` | 通信句柄，创建 reader/writer/service/client |
| `cyber::NodeChannelImpl`/`NodeServiceImpl` | `cyber/node/` | Node 内部委托实现 |
| `cyber::Writer<M>` | `cyber/node/writer.h` | 写者，持 Transmitter，`Write()` 发送 |
| `cyber::Reader<M>` | `cyber/node/reader.h` | 读者，持 Receiver + pending_queue，`Observe()` 拉取 |
| `cyber::Component<M0..M3>` / `TimerComponent` / `ComponentBase` | `cyber/component/` | 组件基类，用户继承实现 Init/Proc |
| `cyber::service::Service`/`Client` | `cyber/service/` | 请求响应通信 |
| `cyber::service_discovery::TopologyManager` | `service_discovery/topology_manager.h` | 拓扑单例，含 Node/Channel/Service 三个子管理器 |
| `cyber::service_discovery::specific_manager::Manager` | `service_discovery/specific_manager/` | 子管理器基类，Join/Leave/AddChangeListener |
| `cyber::service_discovery::RoleAttributes` | `role_attributes.proto` | 角色 ID/属性（host/pid/uuid hash） |
| `cyber::transport::Transport` | `transport/transport.h` | 传输单例，创建 transmitter/receiver/dispatcher |
| `cyber::transport::Transmitter`/`Receiver`/`Endpoint` | `transport/` | 收发端抽象，4 派生：Intra/Shm/Rtps/Hybrid |
| `cyber::transport::IntraDispatcher`/`ShmDispatcher`/`RtpsDispatcher` | `transport/` | 派发器，channel_id→回调 |
| `cyber::transport::shm::Segment`/`Block`/`State`/`ConditionNotifier`/`MulticastNotifier` | `transport/shm/` | 共享内存传输核心 |
| `cyber::message::MessageHeader`/`RawMessage`/`MessageTypeTraits` | `message/` | 消息头/通用包装/类型萃取 |
| `cyber::record::RecordWriter`/`RecordReader`/`RecordViewer` | `record/` | 录制/回放/多通道时间同步 |
| `cyber::time::Time`/`Duration`/`Clock`/`Rate` | `time/` | 时间封装 |
| `cyber::timer::TimingWheel`/`Timer`/`TimerTask` | `timer/` | 时间轮定时器（work_wheel 512 + assistant_wheel 64） |
| `cyber::croutine::CRoutine`/`RoutineContext`/`RoutineFactory` | `croutine/` | 协程 |
| `cyber::scheduler::Scheduler`/`SchedulerClassic`/`SchedulerChoreography`/`Processor`/`ProcessorContext` | `scheduler/` | 调度器 |
| `cyber::data::DataDispatcher`/`DataVisitor`/`DataNotifier`/`CacheBuffer` | `data/` | 多通道数据融合 |
| `cyber::mainboard::ModuleArgument`/`ModuleController` | `mainboard/` | 进程入口 + 模块加载 |
| `cyber::class_loader::ClassLoader`/`ClassLoaderManager` | `class_loader/` | 动态库加载与组件实例化 |

---

## 9. Apollo 源码导览

| 路径 | 内容摘要 |
|------|----------|
| `modules/cyber/cyber.h` | 顶层 API：`Init`/`CreateNode`/`WaitForShutdown`/`OK`/`IsShutdown`/`Duration`/`Rate`/`Time`/`Clock` |
| `modules/cyber/node/` | `Node`、`NodeChannelImpl`、`NodeServiceImpl`、`Writer`、`Reader` |
| `modules/cyber/service_discovery/` | `TopologyManager`、`NodeManager`、`ChannelManager`、`ServiceManager`、`specific_manager/Manager`、`warehouse/`、`communication/`(participant_listener/subscriber_listener) |
| `modules/cyber/transport/` | `Transport`、`Endpoint`、`Transmitter`/`Receiver`、`intra/`、`shm/`、`rtps/`、`message/`、`hybrid/` |
| `modules/cyber/message/` | `MessageHeader`、`RawMessage`、`MessageTypeTraits`、`PyMessageWrap`、protobuf 包装 |
| `modules/cyber/record/` | `RecordWriter`/`RecordReader`/`RecordViewer`、`file/`(RecordFileBase/Section/HeaderBuilder)、`record.proto` |
| `modules/cyber/time/` | `Time`/`Duration`/`Clock`/`Rate`/`time.h` |
| `modules/cyber/timer/` | `TimingWheel`/`Timer`/`TimerTask`/`TimerBucket` |
| `modules/cyber/croutine/` | `CRoutine`/`RoutineContext`/`RoutineFactory`/`swap.S`(汇编切换) |
| `modules/cyber/scheduler/` | `Scheduler`/`policy/`(SchedulerClassic/Choreography/ClassicContext/ChoreographyContext)/`Processor`/`processor_context`/`scheduler_factory`/`common/`(pin_thread/CvWrapper) |
| `modules/cyber/component/` | `ComponentBase`/`Component<>`/`TimerComponent`/`component_macro.h` |
| `modules/cyber/mainboard/` | `mainboard.cc`/`module_argument`/`module_controller` |
| `modules/cyber/class_loader/` | `ClassLoader`/`ClassLoaderManager`/`class_loader_register_macro.h` |
| `modules/cyber/data/` | `DataDispatcher`/`DataVisitor`/`DataNotifier`/`CacheBuffer`/`data_visitor.h` |

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 现状

依据 `AuroraDrive项目交接文档.md`，AuroraDrive 是 macOS 原生（Tauri + C++ sidecar + Swift）的自动驾驶**仿真+辅助驾驶**系统，关键 IPC 现状：

- **传感器数据 IPC**：Swift `ScreenCaptureKit` 捕获窗口 → **Unix Socket** 传输 JPEG **二进制帧 + 时间戳** → C++ sidecar。这是单进程内/进程间的高频图像流通道。
- **前端通信**：React ↔ C++ sidecar 走 **WebSocket（24Hz 广播帧）+ HTTP（路由/状态）**。
- **Rust 监督树**：`src-tauri/src/sidecar.rs` 用 Rust 管理 sidecar 子进程，**100ms 心跳**监控存活，detached thread 同步用 atomic + condition_variable。
- **地图加载**：mmap 零拷贝（`autodrive_map.bin` ~500MB）。
- **仿真主循环**：24Hz `sim_loop`，`next_t += dt; sleep_until` 帧率控制。
- **AUTO 接管**：横向复用 `compute_road_guidance` + PurePursuit，纵向 PID 速度闭环，输出键盘注入（A/D/W/S）。
- **代码风格**：最小化实现、零第三方依赖（仅 macOS 系统框架）、inline 头文件、复用成员缓冲避免热路径堆分配。

### 10.2 AuroraDrive 是否需要 CyberRT？

**明确结论：不需要。** 理由：

1. **场景不匹配**：AuroraDrive 是单机 macOS 仿真/辅助驾驶应用，所有模块（仿真/控制/感知/前端）在同一 sidecar 进程或紧邻进程，无 Apollo 那样跨多主机/数十进程的分布式需求。
2. **依赖冲突**：CyberRT 强依赖 FastRTPS/Protobuf/Bazel/Linux 体系，与 AuroraDrive "零第三方依赖、仅 macOS 系统框架、CMake" 的核心约束直接冲突，引入会破坏打包体积（当前 .app 702MB / dmg 144MB）与启动速度。
3. **语言不匹配**：CyberRT 是 C++ 框架，AuroraDrive 的监督层是 Rust、捕获层是 Swift，跨语言 FFI 接入 CyberRT 成本远高于收益。
4. **过度工程**：CyberRT 的 Component/DAG/服务发现/协程调度是为量产车多模块而生，AuroraDrive 当前 24Hz 单循环 + WebSocket 已能胜任，强行替换会违背"最小化实现"原则。

**但 CyberRT 的思想值得借鉴**，下文给出具体借鉴点与改进方案。

### 10.3 借鉴点一：QoS 策略

CyberRT 的 QoS（Reliability/History/Durability/Depth/Mps）本质是"**按数据重要性分级传输**"。AuroraDrive 当前 Unix Socket 帧传输是单一 best-effort 通道，可借鉴分级：

| AuroraDrive 数据 | 建议 Reliability | 建议 History/Depth | 理由 |
|------------------|------------------|---------------------|------|
| 屏幕捕获 JPEG 帧 | BEST_EFFORT | KEEP_LAST depth=2 | 24Hz 视频流，丢帧无所谓，只关心最新 |
| 键盘注入命令（A/D/W/S） | RELIABLE | KEEP_LAST depth=1 | 控制命令必须送达，但只需最新 |
| AUTO 状态切换 | RELIABLE + TRANSIENT_LOCAL | KEEP_ALL | 晚加入者也要知道当前模式 |
| 心跳（Rust→sidecar） | BEST_EFFORT | KEEP_LAST depth=3 | 100ms 心跳丢一两次不应误判死亡 |
| 仿真广播帧（WebSocket） | BEST_EFFORT | KEEP_LAST depth=1 | 前端 24Hz，丢帧可补 |

**落地建议**：在 Unix Socket 协议头中加 1 字节 `priority`（0=控制命令可靠重传 / 1=视频流尽力而为 / 2=状态持久），C++ 侧为高优先级帧实现 ACK+重传，低优先级帧直接覆盖最新。这无需引入 DDS，纯应用层即可获得 QoS 分级收益。

### 10.4 借鉴点二：数据陈旧分级降级

CyberRT 通过 timestamp + Clock 保证消息新鲜度，业务侧据此降级。AuroraDrive 可直接落地一套**数据陈旧降级表**（针对 AUTO 辅助驾驶接管）：

| 数据陈旧度 | 判定 | 行为 | AuroraDrive 落地 |
|-----------|------|------|-------------------|
| **新鲜** `< 50ms` | 屏幕帧/Clock 在 1~2 帧内 | 正常 PurePursuit + PID | 当前逻辑不变 |
| **轻微陈旧** `50~200ms` | 帧 3~5 帧未更新 | **减速**：目标速度降级到 20km/h，前瞻距离加大 | `assist_auto_longitudinal()` 目标速度查表降级，`lookahead` ×1.5 |
| **严重陈旧** `> 200ms` | 帧超 5 帧未更新 | **停车**：注入 S 键刹车，松开 W/A/D | `assist_auto_*()` 全部置 false，强制 `assist_post_key(1, true)` |
| **心跳丢失** `> 1s` | Rust 监督树检测 sidecar 无响应 | 进程级重启 | 现有 100ms 心跳 + atomic 已具备，加 timeout 分级 |

**实现要点**：在 `simulator.h` 加 `last_frame_ts_`（atomic<int64_ms>），每次 Swift 帧到达更新；`assist_auto_*()` 入口先算 `now - last_frame_ts_`，按上表分支。比单纯依赖车道线检测鲁棒得多——这正呼应 CyberRT"实时性=确定性"思想：宁可确定地减速/停车，也不要不确定地继续。

### 10.5 借鉴点三：协程调度思想

CyberRT 协程调度的精髓不是"用协程"，而是"**用户态、按优先级、按链路绑定 CPU**"的确定性调度。AuroraDrive 当前是 `std::thread` + `sleep_until` 模式，借鉴建议：

1. **关键链路线程隔离**：把 `sim_loop`（24Hz 物理+广播）与 `assist_auto_*()`（控制注入）绑到独立 CPU 核（macOS 用 `pthread_set_qos_class_self_np` 或 `thread_policy_set`），避免被前端 JPEG 编码/网络 IO 抢占。对应 CyberRT 的 `cpuset` + `SCHED_RR` 思想。
2. **优先级**：控制注入线程 QoS 高于渲染线程，对应 CyberRT 的 `processor_prio`。macOS 用 `qos_class_t`：控制链路用 `.userInteractive`，渲染用 `.userInitiated`，地图加载用 `.utility`。
3. **避免热路径阻塞**：CyberRT 协程绝不阻塞、用 yield。AuroraDrive 的 `sim_loop` 内同步 HTTP/编码应异步化（已有 `thread_local` 帧缓冲复用，可进一步把 JPEG 编码丢到独立线程）。
4. **DAG 思想显式化**：当前 `simulator.h` 是巨型单文件（L1256-1362 辅助驾驶线程内联），可借鉴 DAG 把"感知帧→横向控制→纵向控制→键盘注入"显式声明为有依赖的任务图，便于后续插拔（如车道线检测作为可选节点）。

**不建议**直接引入协程库（boost::context/asio::co_spawn）：与"零第三方依赖"冲突，且 macOS GCD 已足够。但可借鉴"用户态任务编排"思想，用 `std::function` 链 + 优先级队列在 sidecar 内实现轻量任务图。

### 10.6 AuroraDrive 改进方案汇总（优先级排序）

| 优先级 | 改进项 | 借鉴自 CyberRT | 工作量 | 说明 |
|--------|--------|----------------|--------|------|
| P1 | **数据陈旧分级降级** | Clock + timestamp 判活 | 2h | `simulator.h` 加 `last_frame_ts_` + `assist_auto_*()` 分支，直接提升 AUTO 安全性 |
| P1 | **Unix Socket QoS 分级** | QoS Reliability/Depth | 3h | 协议头加 priority 字段，控制命令可靠重传，视频流覆盖 |
| P2 | **关键链路 CPU/QoS 隔离** | scheduler cpuset + prio | 4h | `pthread_set_qos_class_self_np` 绑核，控制链路 userInteractive |
| P2 | **心跳超时分级** | leaseDuration 思想 | 2h | Rust 监督树 100ms 心跳加 200ms/1s/3s 多级阈值，分级重启 |
| P3 | **JPEG 编码异步化** | 协程不阻塞思想 | 3h | 编码丢独立线程，sim_loop 仅调度，参考 thread_local 缓冲 |
| P3 | **任务图显式化** | DAG | 8h | 把 sim_loop 拆成显式任务节点，便于插拔车道线/前车检测 |
| P4 | **结构化日志** | Cyber Log AINFO 宏 | 4h | 已在交接文档 P3-002 列出，加 spdlog 或自研轻量宏 |
| P4 | **录制回放** | Cyber Recorder | 16h | 可选：仿 record.proto 录制 Unix Socket 帧，便于离线复现 bug |

**核心建议**：AuroraDrive 不引入 CyberRT，但应吸收其"**确定性优先于峰值性能**"的哲学——通过 QoS 分级、数据陈旧降级、关键链路隔离三招，把当前"24Hz 能跑就行"提升为"任何扰动下都有确定的安全行为"，这正是从仿真玩具走向类量产鲁棒性的关键一步。

---

## 11. 总结

CyberRT 是百度用十年自动驾驶工程经验换来的"车载自适应中间件"，其核心贡献在于：用**协程 + 用户态调度器**取代 OS 线程调度获得确定性；用**SHM/INTRA/Hybrid 三模传输 + 自研共享内存**把同主机通信压到接近零拷贝；用**Component + DAG + class_loader**实现模块热插拔与拓扑编排；用**FastRTPS 双层拓扑发现**做到 No Broker 的去中心化；用**Clock/Time/Recorder**统一时间与离线复现。Apollo 10.0 的 Arena + ICEORYX 升级证明其仍在向更低延迟演进。

对 AuroraDrive 而言，CyberRT 是"思想宝库"而非"依赖候选"：QoS 分级、数据陈旧降级、协程调度的确定性思想都可低成本移植到 Unix Socket + Rust 监督树 + macOS QoS 的现有架构中，在不破坏"零第三方依赖、最小化实现"原则下显著提升系统鲁棒性与安全边界。

---

> **实际工具调用次数：约 51 次**（WebSearch × 28 + WebFetch × 11 + Read 持久化输出 × 8 + LS × 1 + Write × 1 + 其他读取 × 2）
> **字数：约 8800 字（含表格）**
