# DDS 与 FastRTPS/FastDDS 通信中间件深度研究报告

> 本报告面向 AuroraDrive 自动驾驶系统通信架构升级，系统梳理 DDS 标准、FastRTPS/FastDDS 实现、QoS 策略、通信模型、序列化、传输、服务发现，并与 Apollo CyberRT、ROS1（TCPROS）进行横向对比，最后给出 AuroraDrive 通信升级方案。

---

## 1. DDS 概述

### 1.1 DDS 标准与 OMG 规范

**DDS（Data Distribution Service，数据分发服务）** 是由 OMG（Object Management Group，对象管理组织）发布和维护的一套**中间件协议和 API 标准**，采用发布/订阅（Publish/Subscribe）体系架构，强调"以数据为中心（Data-Centric）"，提供丰富的 QoS（Quality of Service）服务质量策略，以保障数据在分布式系统中实时、高效、灵活地分发。

DDS 规范的目的可以概括为一句话："**在正确的时间，将正确的信息，有效且稳健地传递到正确的位置**（Efficiently and robustly deliver the right information to the right place at the right time）"。它广泛应用于航空航天、汽车工程（智能网联/自动驾驶）、智能制造、金融、医疗等需要高效、可靠数据交换的领域。

DDS 并非单一文档，而是一个**协议族**，包含 13 份左右规范，核心包括：

- **DCPS**（Data-Centric Publish-Subscribe，以数据为中心的发布订阅）：定义核心 API 与实体模型。
- **DDSI-RTPS**（Real-Time Publish-Subscribe Wire Protocol）：定义线协议，保证不同厂商 DDS 互操作。
- **IDL**（Interface Definition Language）：接口定义语言，描述数据类型。
- **DDS-XTypes**：扩展类型系统（XCDR v1/v2 序列化即由此而来）。
- **DDS-Security**：安全规范（认证、访问控制、加密等插件）。
- **DDS-RPC**：远程调用规范。
- **DDS-XRCE**：面向资源受限设备（MCU）的精简协议，micro-ROS 即基于 DDS-XRCE。
- **DDS-TSN**：与时间敏感网络结合规范。
- 各语言 PSM：DDS C++ API、DDS Java API、DDS C# API 等。

DDS 规范采用 **PIM（平台无关模型）+ PSM（平台特定模型）** 双层设计：PIM 描述实体与行为，PSM 把 PIM 落到具体语言（典型为基于 IDL 的 C++ PSM）。

### 1.2 DCPS（以数据为中心的发布订阅）

DCPS 是 DDS 的核心 API 层，其"以数据为中心"的含义是：**通信的语义围绕"数据对象（data-object）"本身**，而非"远程方法调用"。系统直接描述数据类型与数据流，中间件负责把数据从生产者送到所有感兴趣的消费者，并按 QoS 约束其行为（是否可靠、是否保留历史、是否持久化、超时如何处理等）。

DCPS 的 PIM 主要组成包括：

- **Topic 定义模块**：Topic 类、ContentFilteredTopic（内容过滤主题）、MultiTopic，以及把 QoS 策略附加到 Topic 的接口。
- **发布模块（Publication Module）**：Publisher 类、DataWriter 类、PublisherListener、DataWriterListener。
- **订阅模块（Subscription Module）**：Subscriber 类、DataReader 类、SubscriberListener、DataReaderListener。
- **域模块（Domain Module）**：DomainParticipant 类、DomainParticipantFactory。
- **QoS 策略**：每个实体（DomainParticipant / Topic / Publisher / DataWriter / Subscriber / DataReader）都通过 `qos_list` 提供各自有意义的策略集合。

DCPS 实体必须由每个派生实体类提供 QoS 设置，从而可以针对每个实体配置有意义的策略。

### 1.3 DDS 与 ROS2 的关系

**ROS2 的核心通信机制就是 DDS**。ROS2 相对 ROS1 最重大的架构变化之一，就是用 DDS 取代了 ROS1 自有的 TCPROS/UDPROS 与中心化 master 机制。具体关系如下：

- ROS2 直接把 DDS 作为默认实时通信中间件，应用层不再与通信层耦合，中间通过 **RMW（ROS Middleware Abstraction Layer，ROS 中间件抽象层）** 隔离。
- RMW 是为兼容多种 DDS 组件而设计的抽象层：上层是 `rclcpp`/`rclpy` 等客户端库，下层对接具体 DDS 实现。用户可以根据性能、许可、平台等约束自由切换 DDS 实现，而无需改动应用代码。
- ROS2 支持的 RMW 实现包括：eProsima **Fast DDS**（`rmw_fastrtps_cpp`，默认）、RTI **Connext DDS**、Eclipse **Cyclone DDS**（`rmw_cyclonedds_cpp`）、GurumNetworks **GurumDDS**，以及非 DDS 的 **Zenoh**（`rmw_zenoh`）。
- DDS 的 Domain ID 成为 ROS2 的逻辑网络隔离机制：同一 Domain ID 内的节点可自由发现并通信，不同 Domain ID 之间互不干扰（默认 Domain ID = 0）。ROS2 通过 `ROS_DOMAIN_ID` 环境变量控制。

DDS 的去中心化自动发现、丰富 QoS、多传输（含共享内存/零拷贝）等特性，正是 ROS2 相对 ROS1 在实时性、可靠性和多机器人协作能力上的根本提升来源。

---

## 2. FastRTPS / FastDDS

### 2.1 eProsima FastRTPS

**FastRTPS** 由西班牙公司 **eProsima** 开发，是一个开源的实时发布-订阅中间件实现。它最初只实现了 RTPS 线协议层，是 ROS2 早期（Ardent/Bouncy/Crystal/Dashing/Eloquent/Foxy 等）的默认中间件，对应 RMW 包 `rmw_fastrtps_cpp`。

FastRTPS 的设计目标：高性能、轻量级、跨平台、与 RTPS 标准完全兼容，可与其它 DDS 厂商产品互操作。

### 2.2 FastDDS 的演进

随着 DDS 标准完整 API（DCPS）的需求增长，eProsima 在 FastRTPS 基础上叠加了完整的 DDS 层，演进为 **Fast DDS**：

- **FastRTPS**：只提供 RTPS 层 API（Publisher/Subscriber 较底层）。
- **Fast DDS**：在 RTPS 之上提供标准 DDS DCPS API（DomainParticipant / Topic / Publisher / DataWriter / Subscriber / DataReader 等），同时保留底层 RTPS。
- 二者常被混称，ROS2 中的 `rmw_fastrtps_cpp` 在新版本中底层已切到 Fast DDS。Fast DDS 库同时提供了 DDS 协议的 API 和用于部署以数据为中心的发布者-订阅者模型的数据通信能力。

Fast DDS 优点：

- **高性能**：支持零拷贝传输、共享内存（Shared Memory）、UDP 多播优化，延迟可低至微秒级，吞吐量可达 Gbps 级。
- **轻量级**：核心库体积小（编译后约 1–2MB），内存占用低，可裁剪。
- **标准与互操作**：基于 DDS 标准，遵循 RTPS 线协议，可与 RTI Connext、Cyclone DDS 等互操作。
- **跨平台**：Linux / macOS / Windows。
- **配置灵活**：支持代码内显式设置 QoS，也支持 XML 配置文件（`FASTRTPS_DEFAULT_PROFILES_FILE`）全局配置。

### 2.3 与 ROS2 默认中间件的关系

Fast DDS 是 ROS2 长期以来的**默认 RMW**。在大多数 ROS2 发行版（含 Humble）中，官方二进制包默认携带 Fast DDS。从 Jazzy 开始，Fast DDS 与 Cyclone DDS 都得到深度优化，开发者可基于性能/资源/功能需求二选一或多 RMW 共存。

切换方式：设置环境变量 `RMW_IMPLEMENTATION=rmw_fastrtps_cpp`（或 `rmw_cyclonedds_cpp`）。多 RMW 可共存于同一 `install/` 目录，运行时按需切换。

### 2.4 性能定位

根据 eProsima 官方对 Fast DDS 与 Eclipse Cyclone DDS 的性能对比测试（相同硬件、相同 QoS 配置）：

- **延迟（Latency）**：以乒乓（ping-pong）测量，Fast DDS 在进程内（intra-process）和进程间（inter-process）两种场景下延迟均低于 Cyclone DDS。
- **吞吐量（Throughput）**：以批量发送测量，Fast DDS 吞吐量更高，尤以进程间场景优势明显。

总体上：**Fast DDS 强调高性能与丰富功能，适合服务器级/工控机应用；Cyclone DDS 注重轻量化与嵌入式支持，适合资源受限场景**。两者都兼容 DDS 标准，理论上可互操作。

---

## 3. DDS QoS

QoS（Quality of Service）策略是 DDS 通信的核心，决定了节点间数据传输的性能、可靠性和实时性。其设计哲学与传统通信的"一刀切（one size fits all）"不同：**为每个 Topic / 每个端点单独配置合适的 QoS**，从而让传感器流、控制指令、状态数据、日志等各取所需。

### 3.1 核心 QoS 策略

- **Reliability（可靠性）**：控制消息是否保证送达。
  - `BEST_EFFORT`：尽力而为，不保证送达，适合高频、可丢帧数据（激光雷达点云、图像、IMU）。
  - `RELIABLE`：使用确认/重传机制确保送达，适合关键数据（导航目标点、控制指令）。
  - 匹配规则：RELIABLE 订阅者不能订阅 BEST_EFFORT 发布者（即 Writer 为 BEST_EFFORT 时 Reader 必须也 BEST_EFFORT）。

- **History（历史记录）**：控制保留的消息数量与方式。
  - `KEEP_LAST`：保留最近 N 条（depth，如 1/10/100）。
  - `KEEP_ALL`：保留所有（受资源限制）。

- **Durability（持久性）**：控制新订阅者是否接收历史消息。
  - `VOLATILE`：新订阅者只接收订阅之后的"新"消息，适合瞬时数据流。
  - `TRANSIENT_LOCAL`：新订阅者可收到发布者最后发送的（缓存的）消息，适合状态数据（机器人位姿、地图、配置）。
  - `TRANSIENT` / `PERSISTENT`：消息存入持久化介质，需 DDS 实现支持。

- **Deadline（截止时间）**：指定消息发送/接收的期望周期（如 10ms），超时触发回调（`on_offered_deadline_missed` / `on_requested_deadline_missed`），适合周期性实时控制（电机指令需每 10ms 更新）。

- **Liveliness（活跃性）**：检查发布者是否"活着"，防止节点故障影响系统。
  - `AUTOMATIC`：DDS 基于底层传输自动判定。
  - `MANUAL_BY_PARTICIPANT`：参与者需定期发心跳。
  - `MANUAL_BY_TOPIC`：主题需定期更新。
  - 配合 lease duration（租约时长），超时触发 `on_liveliness_lost`。

- **Lifespan（消息生存时间）**：消息有效期，过期即丢弃，避免过时传感器数据污染决策，常与 History 配合。

- **Ownership（所有权）**：是否允许多个 DataWriter 更新同一实例（topic+key）。
  - `SHARED`：多个 Writer 都可更新。
  - `EXCLUSIVE`：仅所有权强度（ownership strength）最高的 Writer 生效，用于冗余/主备切换。

- **Destination Order（目标顺序）**：多 Writer 同一实例的排序策略（按源/按接收时间戳）。

- **Partition（分区）**：逻辑分组，匹配分区才通信，类似"逻辑通道"。

- **Presentation（呈现）**：控制订阅端访问样本的顺序与原子性（按实例/按主题/按组，是否 coherent access）。

- **ResourceLimits（资源限制）**：限制样本数/实例数，防止内存溢出，常用于嵌入式。

- **TransportPriority / LatencyBudget / TimeBasedFilter / UserData / TopicData / GroupData** 等其它策略。

### 3.2 DDS QoS 策略总览表

| QoS 策略 | 取值 | 作用 | 典型自动驾驶场景 |
|---|---|---|---|
| Reliability | BEST_EFFORT / RELIABLE | 是否保证送达 | 点云/图像=BEST_EFFORT；控制指令=RELIABLE |
| History | KEEP_LAST(depth) / KEEP_ALL | 缓存条数与方式 | 传感器=KEEP_LAST(1)；日志=KEEP_ALL |
| Durability | VOLATILE / TRANSIENT_LOCAL / TRANSIENT / PERSISTENT | 新订阅者是否收历史 | 状态/地图/配置=TRANSIENT_LOCAL；传感器流=VOLATILE |
| Deadline | 周期时长 | 超时回调 | 周期控制（电机指令 10ms） |
| Liveliness | AUTOMATIC / MANUAL_BY_PARTICIPANT / MANUAL_BY_TOPIC + lease | 检测发布者存活 | 安全关键传感器/MCU 心跳 |
| Lifespan | 有效期 | 过期丢弃 | 防止陈旧感知数据被消费 |
| Ownership | SHARED / EXCLUSIVE(+strength) | 多源择优 | 冗余传感器主备切换 |
| Destination Order | BY_SOURCE / BY_RECEPTION | 多源排序 | 多雷达融合时序 |
| Partition | 字符串列表 | 逻辑分组 | 域内分域/功能隔离 |
| Presentation | 实例/主题/组 + coherent/ordered | 访问原子性 | 一组关联样本原子提交 |
| ResourceLimits | max_samples/max_instances/... | 资源上限 | 嵌入式内存约束 |
| TransportPriority | int | 传输优先级 | 控制帧优先于感知帧 |
| LatencyBudget | 时长 | 延迟偏好提示（非强制） | 实时链路偏好 |
| TimeBasedFilter | 最小间隔 | 订阅端采样过滤 | 高频源降采样消费 |
| UserData/TopicData/GroupData | octet seq | 附加元数据 | 安全凭证/标签 |

### 3.3 与 CyberRT QoS 对比

Apollo CyberRT 也提供 QoS 概念，定义在 `qos_profile.proto` 中。CyberRT 的 QoS 基本上负责了 DDS 的所有配置——无论是心跳、消息可靠性、流量控制，还是安全配置，甚至通道配置，都通过 Qos 来实现。但 CyberRT 的 QoS 子集相对较小，主要暴露：

- `depth`（对应 KEEP_LAST depth）；
- `reliability`（BEST_EFFORT / RELIABLE）；
- `durability`（VOLATILE / TRANSIENT_LOCAL）；
- `history`（KEEP_LAST / KEEP_ALL）；
- 部分流量控制/调度相关字段。

相比 DDS，CyberRT QoS **缺少 Deadline、Liveliness、Lifespan、Ownership、Partition、Presentation 等细粒度策略**，且大多策略是"开/关"或"枚举"层面，缺少租约时长、所有权强度、内容过滤等运行时可调参数。这是 AuroraDrive 借鉴 DDS QoS 的重点空间。

---

## 4. DDS 通信模型

DDS DCPS 的核心实体及其协作关系如下：

### 4.1 Domain（域）

- **DomainParticipant**：加入某个 DDS Domain 的入口实体，由 `DomainParticipantFactory` 创建。
- **Domain ID**：域标识。同一 Domain ID 内的参与者可自由发现并通信；不同 Domain 之间互不干扰，是天然的隔离机制。ROS2 用 `ROS_DOMAIN_ID` 映射此概念。
- 一个进程可创建多个 DomainParticipant（分属不同 Domain）。

### 4.2 Topic（主题）

- **Topic**：以数据类型 + 名称标识的逻辑数据流，绑定 QoS。
- **ContentFilteredTopic**：在订阅端按 SQL-like 表达式过滤样本，减少不必要的数据投递。
- **MultiTopic**：多 Topic 聚合/重分发。
- Topic 必须有数据类型，类型通过 IDL 描述并 `register_type` 注册到 Participant。

### 4.3 Publisher / DataWriter

- **Publisher**：负责创建并管理其下属的 DataWriter，是发布侧的 DCPS 实体。
- **DataWriter**：实际发布消息的实体，绑定一个 Topic，按 QoS 写入数据。`write()` 将样本交给中间件。

### 4.4 Subscriber / DataReader

- **Subscriber**：负责创建并管理其下属的 DataReader，是订阅侧实体。
- **DataReader**：实际接收消息的实体，绑定 Topic，按 QoS 接收。提供 `read()`/`take()` 接口或回调通知。

### 4.5 Listener（监听器）

DDS 提供分层 Listener 回调机制，由底层向高层逐级上报：

- `DomainParticipantListener`（参与者级：发现、liveliness 等）
- `PublisherListener` / `SubscriberListener`
- `DataWriterListener`（写入侧：matched、ACK 等）
- **`DataReaderListener`**（最常用）：`on_data_available`（有新数据）、`on_requested_deadline_missed`、`on_requested_incompatible_qos`、`on_sample_lost`、`on_liveliness_changed`、`on_subscription_matched` 等。

### 4.6 通信流程

1. 创建 `DomainParticipantFactory` → `DomainParticipant`；
2. 注册数据类型 → 创建 `Topic`；
3. 创建 `Publisher` → `DataWriter`；创建 `Subscriber` → `DataReader`；
4. **发现**：通过组播/单播自动发现域内其它 Participant 及其 Topic、QoS（PDP + EDP）；
5. **匹配**：Writer 与 Reader 在 Topic、类型、QoS 兼容时建立匹配；
6. **发布**：DataWriter 写入 → 序列化为 RTPS DATA 子消息 → 经传输层（UDP/TCP/SHM）投递；
7. **接收**：DataReader 收到 → 反序列化 → 入历史缓存 → 触发 `on_data_available` 回调或被 `read/take`。

---

## 5. DDS 序列化

### 5.1 CDR（Common Data Representation）

**CDR（通用数据表示）** 是 OMG 制定的**二进制数据序列化标准**，定义了如何将 IDL 描述的数据结构转换为平台无关的字节流，以及如何从字节流恢复原始数据结构。

CDR 的核心特点：

- **跨平台**：自动处理不同硬件架构的字节序（大小端）和对齐差异。
- **跨语言互操作**：支持 C++、Java、Python、C# 等主流语言。
- **高性能**：二进制编码，无冗余元数据开销，接近内存拷贝（memcpy）速度。
- **强类型安全**：基于 IDL 静态类型检查，避免运行时类型错误。
- **标准性**：唯一的国际标准二进制序列化格式，保证不同厂商 DDS 产品互操作。

CDR 标准经历了三次演进：

| 版本 | 标准来源 | 时间 | 核心特性 | 应用 |
|---|---|---|---|---|
| 原始 CDR | OMG formal/02-06-51（CORBA 3.0） | 2002 | 基础/复合类型、对齐规则 | CORBA、早期 DDS |
| XCDR v1 | DDS-XTypes v1.0 | 2010 | 扩展类型、PL_CDR（参数化）、可选成员 | DDS v1.4、ROS2 Humble 及更早 |
| XCDR v2 | DDS-XTypes v1.3 | 2018 | 64 位类型 4 字节对齐、DELIMITED_CDR、PL_CDR2、wchar 优化 | DDS v1.6、ROS2 Iron 及以后 |

RTPS 协议规定数据需通过 CDR 格式序列化（二进制编码），确保不同节点间数据兼容。

### 5.2 Protobuf / JSON

- **Protobuf**：Google 的二进制序列化，广泛用于 gRPC、Apollo CyberRT 等。需 `.proto` 描述与代码生成。编码紧凑但带字段编号元数据，需完整编解码。
- **JSON**：文本格式，可读性好但体积大、解析慢，常用于配置、调试、与 Web 交互，不适合高频实时数据。

### 5.3 与 CyberRT Protobuf 对比

CyberRT 使用 **Protobuf** 作为消息序列化格式，拓扑消息中夹带 Channel 的 `proto_type`、`proto_desc` 用于序列化/反序列化。对比：

| 维度 | DDS CDR | CyberRT Protobuf |
|---|---|---|
| 标准化 | OMG 国际标准，跨厂商互操作 | Google 开源事实标准 |
| 编码 | 二进制，对齐+可选 PL_CDR | 二进制，字段编号+变长 |
| 元数据开销 | 极小（接近裸结构体） | 较小但有字段 tag |
| 性能 | 接近 memcpy，零拷贝友好 | 需完整编解码，零拷贝不直接支持 |
| 类型系统 | IDL + XTypes（可选成员、可演进） | `.proto`，schema 演进有规范 |
| 零拷贝 | DataSharing 支持 loan 直接传递 CDR buffer | 不直接支持，需自定义内存管理 |

CDR 的"接近内存拷贝"特性使其天然适合与共享内存/零拷贝结合——这是 AuroraDrive 大消息（点云、图像）传输可借鉴的关键点。

---

## 6. DDS 传输

DDS（Fast DDS）的传输层支持多种协议，根据通信双方的相对位置选择：

### 6.1 UDP

- 默认传输，基于 UDPv4/UDPv6。
- **组播（multicast）**用于服务发现（SPDP 默认组播），单播用于数据。
- 适合局域网内跨机器通信。受协议栈影响，大消息需分片/组装。

### 6.2 TCP

- 用于 LAN/WAN，支持监听端口（`add_listener_port`）与 WAN 地址（`set_wan_address`）。
- 适合跨网段、广域、NAT 穿透等场景。
- 相对 UDP 有连接建立与可靠性开销，但适合不可靠网络上的可靠传输。

### 6.3 共享内存（Shared Memory, SHM）

- 依靠主机 OS 共享内存机制，实现**同机器跨进程**快速通信。
- 相比 UDP/TCP（即使走环回接口）有两大优势：
  1. **减少系统调用次数**：SHM 建好后直接内存操作，而 UDP/TCP 每次收发都走系统调用，有上下文保存/恢复开销。
  2. **支持超长消息**：UDP/TCP 受协议栈影响需分片组装，SHM 仅受机器内存限制，可整条消息拷贝。
- Fast DDS 利用 DomainParticipant 的 `GuidPrefix_t` 识别同主机对等方（前 4 字节相同视为同主机），提供 `is_on_same_host_as()` API。
- 实现要点：进程间同步（信号量）、buffer/segment 管理需自行实现（比 UDP/TCP 复杂）。

### 6.4 Data Sharing Delivery（零拷贝）

Fast DDS 在 SHM 之上提供更进一步的 **Data Sharing（数据共享交付）**，实现真正的**零拷贝（ZERO-COPY）**：

- **共享内存传输（SHM Transport）**：基础版本，仍有一次内存拷贝（写到段缓冲区）。
- **数据共享交付（Data Sharing Delivery）**：Writer 直接在共享内存段中"借出（loan）"buffer 写入，Reader 直接读取，避免 Writer/Reader 内部的拷贝。
- 通过 `DataSharingQosPolicy` 配置，可按 Topic 启用。

### 6.5 Intra-Process（进程内）

- Writer 与 Reader 在同一进程时，Writer 线程直接调用 Reader 的回调函数（同线程内调用），完全无跨进程开销，是最快的传输方式。

### 6.6 传输选择矩阵

| 通信双方位置 | 推荐传输 |
|---|---|
| 跨机器 | UDP / TCP |
| 同机器跨进程 | SHM / Data Sharing（零拷贝） |
| 同进程 | Intra-Process（直接回调） |

### 6.7 与 CyberRT ShmChannel 对比

CyberRT 的 Transport 在构造时即创建三种 dispatcher：**intra、shm、rtps**，对应三种通信方式：

- **Intra（SAME_PROC）**：同进程 Writer/Reader 直接用指针传参。
- **Shm（DIFF_PROC，同主机不同进程）**：使用共享内存（ShmChannel）+ Notifier（通知机制）+ 监听线程。默认同主机跨进程走 SHM。
- **Rtps（DIFF_HOST）**：跨主机走 FastRTPS/UDP。

CyberRT 通过拓扑发现判断 Writer/Reader 关系：`SAME_PROC` / `DIFF_PROC` / `DIFF_HOST` / `NO_RELATION`，据此自动选择传输。

对比 DDS：

| 维度 | DDS（Fast DDS） | CyberRT |
|---|---|---|
| 同进程 | Intra-Process 直接回调 | Intra 指针传参 |
| 同主机跨进程 | SHM / Data Sharing 零拷贝 | ShmChannel + Notifier |
| 跨主机 | UDP / TCP | RTPS（FastRTPS） |
| 零拷贝 | Data Sharing loan 机制 | 仅 SHM 段共享，无标准 loan API |
| 传输选择 | 基于 GuidPrefix 同主机判定 + QoS | 基于拓扑关系判定 |
| 大消息 | SHM/DataSharing 无分片 | SHM 段，但 notifier/缓冲管理自实现 |

CyberRT 的 SHM 思路与 DDS 高度一致，但 DDS 的 **Data Sharing 零拷贝 + 标准 loan API** 是 AuroraDrive 可重点借鉴的：把"序列化结果直接落在共享内存可读区"以避免拷贝。

---

## 7. DDS 服务发现

### 7.1 RTPS 协议

**RTPS（Real-Time Publish-Subscribe Wire Protocol）**，又称 **DDSI-RTPS**，是 DDS 标准的"有线协议（wire protocol）"。DDS 是更高层的实时数据共享规范，而 RTPS 负责定义 DDS 数据在网络上的具体传输格式、报文结构与行为。

RTPS 产生的脉络：DDS 接口（DCPS）规范 → 不同厂商实现各自 DDS 产品 → 不同厂商产品需要互操作 → 提出 RTPS 规范定义底层报文格式与行为。RTPS 基于 UDP（默认），可选 TCP/SHM。

RTPS 规范包含 4 个模块：

- **结构模块**：定义概念与数据结构（Participant、Endpoint、Writer、Reader、GUID/GuidPrefix 等）。
- **报文模块**：定义报文格式。
- **行为模块**：定义不同配置下传输行为（何时发何报文、如何响应）。
- **发现模块**：综合前三者，定义简单发现协议。

**RTPS 消息结构**：每个消息包含 **Header**（协议版本、vendor id、GUID prefix）+ 多个 **Submessage**（子消息头 SubmessageHeader + 子消息元素）。子消息按功能分三类，常见包括：

- **DATA**：携带用户数据样本（CDR 序列化）。
- **HEARTBEAT**：Writer 告知 Reader 当前可用数据范围。
- **ACKNACK**：Reader 向 Writer 确认/请求重传。
- **INFO_DST / INFO_SRC / INFO_TS**：路由/时间戳辅助信息。
- **GAP**：告知某些序列号无效。

### 7.2 SDP（Simple Discovery Protocol）

DDS 标准的服务发现分为两个阶段/两个协议（满足 OMG 标准的所有 RTPS 实现至少需提供）：

- **PDP（Participant Discovery Protocol，参与者发现协议）**：参与者确认彼此存在。参与者定期发送公告（包含名称、ID、进程信息、主机信息、监听 IP/Port 等）。
  - 标准实现即 **SPDP（Simple Participant Discovery Protocol）**：默认组播周期公告。
- **EDP（Endpoint Discovery Protocol，端点发现协议）**：确认 DataWriter / DataReader 的信息（Topic、数据类型、QoS 等），完成端点匹配。
  - 标准实现即 **SEDP（Simple Endpoint Discovery Protocol）**。

发现流程：SPDP 发现 Participant → SEDP 交换端点信息 → QoS/类型匹配 → 建立 Writer↔Reader 数据链路。

### 7.3 FastDDS 的发现机制

Fast DDS 提供四种服务发现机制：

1. **SIMPLE（简单发现）**：标准 SPDP+SEDP，保证与其它 DDS 互操作。默认组播，可配置 initial peers。
2. **STATIC（静态发现）**：在 XML 配置文件中预先指定端点信息，无需运行时交换 EDP，启动快，适合确定性部署。
3. **DISCOVERY_SERVER（发现服务器）**：C/S 结构，由一个或多个 Discovery Server 集中管理元数据流量，大幅降低大规模系统的发现广播风暴，适合大集群/车队。ROS2 可用 `fast-discovery-server` 部署。
4. **MANUAL（手动发现）**：用户手动匹配 RTPS 组件，灵活但繁琐。

### 7.4 与 CyberRT 服务发现对比

CyberRT 使用**动态去中心化拓扑发现**，底层借助第三方 eProsima FastRTPS 进行通信管理：

- 使用 FastRTPS 组播接口，通过 `CYBER_DOMAIN_ID` 建立 DOMAIN，不同 DOMAIN 互不干扰。
- **TopologyManager** 单例管理三张拓扑网：
  - **NodeManager**：管理/查询系统中的 Node。
  - **ChannelManager**：管理/查询 Channel 相关拓扑（Node/Writer/Reader），可获取某 Channel 的所有 Writer/Reader，判断对端是否就绪。
  - **ServiceManager**：管理/查询 Server/Client。
- 拓扑角色（Role）：Node / Reader-Writer / Server-Client，用 `RoleAttributes` 标识。
- 有向图存储：边为 Channel 名称，顶点为 Node；关系分 UPSTREAM / DOWNSTREAM / UNREACHABLE。
- 拓扑发现处理 Join/Leave：每个 Manager 创建对应 Publisher/Subscriber（Channel 名 `*_change_broadcast`），QoS 设为 `HISTORY_KEEP_ALL`，使新加入者能收到历史拓扑消息，保证连续性。
- 通过 `AddChangeListener` 监听拓扑变化；节点唯一命名，冲突时比较时间戳保留较新者；Participant 退出时移除其相关拓扑。
- 拓扑消息夹带 Channel 的 `proto_type`/`proto_desc` 用于序列化。

对比 DDS：

| 维度 | DDS（标准 + Fast DDS） | CyberRT |
|---|---|---|
| 发现方式 | 去中心化 SPDP/SEDP（组播）+ 可选 DS 中心化 | 去中心化，借 FastRTPS 组播 |
| 两阶段 | PDP（参与者）+ EDP（端点） | 拓扑 Join/Leave 广播 + KEEP_ALL 历史 |
| 大规模 | Discovery Server 集中元数据 | 无集中式，依赖组播 |
| 静态配置 | STATIC XML | 静态拓扑发现（配置文件） |
| 域隔离 | Domain ID | CYBER_DOMAIN_ID |
| 拓扑存储 | 内置主题（BIT） | TopologyManager + 有向图 |
| 角色模型 | Participant/Writer/Reader | Node/Reader/Writer/Server/Client |

两者发现哲学相似，但 DDS 的 **Discovery Server 大规模方案**与**标准互操作**是 CyberRT 所缺——CyberRT 的发现本质是"跑在 FastRTPS 之上的自定义拓扑层"，与 DDS 生态不直接互通。

---

## 8. DDS vs CyberRT vs ROS1

### 8.1 DDS vs ROS1（TCPROS）

**ROS1** 通信特点：

- **中心化 master**：`rosmaster` 作为名字/发现服务（基于 XMLRPC），所有节点先向 master 注册再建立点对点连接。**单点故障**——master 挂了整个系统瘫痪。
- **TCPROS**：默认基于 TCP 的点对点数据传输（连接前经 master 协商握手，交换 connection header）。
- **UDPROS**：可选 UDP 传输，少用。
- 无标准 QoS（仅有 `queue_size` 这类粗粒度参数）、无标准多传输抽象、无标准共享内存/零拷贝、实时性弱。
- 单 master 限制了多机器人/大规模部署（虽有 multimaster 方案但复杂）。

**DDS** 相对 ROS1 的优势：

- **去中心化**：无单点 master，自动发现（SPDP/EDP）。
- **丰富 QoS**：可靠性、持久性、截止时间、活跃性等全维度。
- **多传输**：UDP/TCP/SHM/零拷贝/进程内，按位置自动选择。
- **实时性**：微秒级延迟、Gbps 吞吐、零拷贝，适合实时嵌入式。
- **域隔离**：Domain ID 天然多套系统共存。
- **标准互操作**：RTPS 线协议保证跨厂商互通。
- **安全**：DDS-Security 规范（认证/访问控制/加密），SROS2 基于 DDS Security 提供 ROS2 安全。

ROS2 用 DDS 正是为了解决 ROS1 这些根本缺陷。

### 8.2 DDS vs CyberRT

CyberRT 是百度为自动驾驶自研的高性能运行时框架，针对高并发、低延迟、高吞吐深度优化。两者定位接近（都是自动驾驶通信中间件），但 CyberRT 更"自成一派"，DDS 更"标准化生态"。

**DDS vs CyberRT 对比表**：

| 维度 | DDS（Fast DDS） | Apollo CyberRT |
|---|---|---|
| 标准化 | OMG 国际标准 + RTPS 互操作 | 自研，非标准 |
| 通信模型 | Domain/Topic/Publisher-DataWriter/Subscriber-DataReader | Node/Channel/Writer-Reader/Server-Client |
| 序列化 | CDR（XCDR v1/v2） | Protobuf |
| QoS | 全维度（Reliability/History/Durability/Deadline/Liveliness/Lifespan/Ownership/...） | 子集（depth/reliability/durability/history） |
| 同进程 | Intra-Process 直接回调 | Intra 指针传参 |
| 同主机跨进程 | SHM / Data Sharing 零拷贝 | ShmChannel + Notifier |
| 跨主机 | UDP / TCP | RTPS（FastRTPS） |
| 零拷贝 | Data Sharing loan 标准 API | 无标准 loan |
| 服务发现 | SPDP+SEDP / Discovery Server / STATIC | TopologyManager（借 FastRTPS 组播） |
| 域隔离 | Domain ID | CYBER_DOMAIN_ID |
| 安全 | DDS-Security 规范（SROS2） | 较弱，依赖部署 |
| 跨厂商互通 | 是（RTPS） | 否 |
| 调度 | 中间件不绑定调度 | 与协程/调度深度耦合（RT 之"RT"） |
| 生态 | ROS2 默认 + 工业/车规 | Apollo 生态 |
| 适用场景 | 标准、多供应商、跨平台、需互操作 | Apollo 单一栈、极致优化 |

**关键差异点**：

1. **标准化与互操作**：DDS 是标准，可跨厂商；CyberRT 自研封闭。AuroraDrive 若要对接 ROS2 生态或多家供应商，DDS 路径更顺。
2. **QoS 完备性**：DDS 的 Deadline/Liveliness/Lifespan/Ownership 是安全关键场景（自动驾驶）非常有用但 CyberRT 缺失的能力。
3. **零拷贝**：DDS Data Sharing 有标准 loan API；CyberRT SHM 无标准零拷贝接口。
4. **调度耦合**：CyberRT 把"通信"与"协程调度"绑定，是其低延迟优势来源，但也是耦合点；DDS 仅做通信，调度由上层决定。
5. **发现大规模**：DDS Discovery Server 明显优于 CyberRT 纯组播方案。

### 8.3 性能与适用场景

- **DDS（Fast DDS）**：延迟微秒级、吞吐 Gbps 级；进程内/进程间延迟优于 Cyclone DDS；适合标准、多供应商、跨平台、需互操作与丰富 QoS 的场景。
- **Cyclone DDS**：轻量、嵌入式友好、调试信息多；适合资源受限 MCU/边缘节点。
- **CyberRT**：与 Apollo 调度深度耦合，单栈极致优化；适合 Apollo 全栈。
- **ROS1（TCPROS）**：实时性弱、单点 master；已不适合新自动驾驶项目，仅遗留维护。

---

## 9. Cyclone DDS

### 9.1 Eclipse Cyclone DDS

**Eclipse Cyclone DDS** 是 Eclipse 基金会下的开源 DDS 实现（源自 ADLINK），快速、可靠且小巧，完全兼容 OMG DDS 标准。特点：

- **轻量级**：特别适合系统资源有限的嵌入式设备和对低延迟要求较高的场景。
- **调试友好**：相对 Fast DDS 提供更多调试信息。
- **ROS2 支持**：`rmw_cyclonedds` / `rmw_cyclonedds_cpp`，可一键切换。
- **DDS-Security**：提供安全认证/访问控制/加密插件。
- **共享内存**：支持 SHM 传输（ROS2 同主机跨进程不占网络带宽）。

### 9.2 与 FastDDS 对比

| 维度 | Fast DDS | Cyclone DDS |
|---|---|---|
| 厂商/社区 | eProsima | Eclipse（ADLINK） |
| 定位 | 高性能 + 丰富功能，服务器/工控机 | 轻量化，嵌入式/资源受限 |
| 延迟 | 更低（进程内/进程间均优） | 略高 |
| 吞吐 | 更高 | 略低 |
| 功能丰富度 | 更全（Data Sharing 零拷贝、Discovery Server、XML 配置成熟） | 较精简 |
| 调试信息 | 一般 | 更丰富 |
| 嵌入式/MCU | 一般 | 更友好 |
| 许可 | Apache 2 | EPL（Eclipse） |
| ROS2 默认 | 是（多数发行版） | 可切换，部分场景首选 |

### 9.3 ROS2 默认中间件切换

ROS2 通过 RMW 抽象层实现 DDS 切换，方法：

```bash
# 安装对应 RMW
sudo apt install ros-<distro>-rmw-fastrtps-cpp      # Fast DDS
sudo apt install ros-<distro>-rmw-cyclonedds-cpp    # Cyclone DDS

# 运行时切换
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
# 或
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
```

多 RMW 可共存于同一 `install/` 目录（`librmw_fastrtps_cpp.so` 与 `librmw_cyclonedds_cpp.so` 并存），运行时按环境变量选择。Cyclone DDS 还可通过配置文件（`CYCLONEDDS_URI`）调优。

选型建议：服务器级/工控机/丰富功能 → Fast DDS；嵌入式/MCU/资源受限/需更多调试 → Cyclone DDS。两者都兼容 DDS 标准，理论上可互操作（实际可能需注意序列化/类型兼容性）。

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 当前架构

AuroraDrive 当前通信架构为 **Unix Socket + 二进制帧**：

- 基于 Unix Domain Socket（`AF_UNIX`，`sockaddr_un`，套接字文件路径如 `/tmp/xxx`）做同主机进程间通信。
- 不经过网络协议栈，比 TCP loopback 更高效（无需协议栈封解包）。
- 消息以自定义二进制帧（binary frame）承载。
- 优点：简单、跨进程、无需中心 master、比 TCP 环回高效。
- 缺点：
  1. **无标准 QoS**：可靠性/历史/持久性/截止时间/活跃性等需自行实现或缺失。
  2. **无零拷贝**：每条消息需 `send/recv` 拷贝（用户态↔内核态），大消息（点云、图像）开销大。
  3. **无标准服务发现**：连接对端需硬编码路径或自研发现。
  4. **无类型安全/IDL**：二进制帧靠口头约定，易出错、难演进。
  5. **无跨主机能力**：Unix Socket 仅同主机，跨机器需另起一套。
  6. **无标准互操作**：与 ROS2/DDS 生态不互通。

### 10.2 借鉴 DDS QoS

AuroraDrive 应在自有通信层引入 DDS 风格的 QoS 抽象，按 Topic 配置：

- **Reliability**：传感器流（点云/图像/IMU）用 `BEST_EFFORT` 降负载、防堆积；控制指令/规划轨迹用 `RELIABLE` 保证送达。
- **History + depth**：传感器 `KEEP_LAST(1)` 只消费最新值；事件/日志 `KEEP_ALL`。
- **Durability**：状态/地图/配置 `TRANSIENT_LOCAL`，让新启动模块立即拿到当前状态，避免冷启动空窗。
- **Deadline**：周期控制链路（如 10ms 控制环）设 Deadline，超时触发降级/报警。
- **Liveliness**：关键模块（感知/规划/控制）设 Liveliness + lease，崩溃及时感知并切换。
- **Lifespan**：高频感知数据设短 Lifespan，杜绝陈旧数据被消费导致错误决策。
- **Ownership**：冗余传感器/主备模块用 `EXCLUSIVE + strength`，自动主备切换。

实现上可在 AuroraDrive 现有"帧头"中扩展 QoS 字段（参照 CyberRT `qos_profile.proto`，但补齐 Deadline/Liveliness/Lifespan/Ownership）。

### 10.3 借鉴 DDS 共享内存 / 零拷贝

Unix Socket 的根本瓶颈是**每帧两次拷贝 + 系统调用**。对大消息应升级为 **SHM + 零拷贝**：

1. **SHM 段 + 环形缓冲池**：为每个高频大消息 Channel 创建共享内存段，内含固定数量的 Segment Buffer（参考 Fast DDS SHM 的 BufferNode + segment_size）。
2. **Notifier 通知机制**：写者写完后通过轻量通知（eventfd / futex / 共享内存原子变量，参考 CyberRT Notifier）唤醒读者监听线程，避免轮询。
3. **零拷贝 loan 模式**（重点借鉴 DDS Data Sharing）：
   - 写者向 SHM 池"借"一个 buffer（loan），直接把序列化结果写入该 buffer（甚至让生产者直接在该 buffer 上构造数据，零中间拷贝）；
   - 只把 buffer 的索引/offset 通过小帧（仍可走 Unix Socket 或 SHM 控制通道）传给读者；
   - 读者按索引直接读 SHM buffer，处理完归还；
   - 引用计数/Epoch 机制管理 buffer 生命周期，多读者共享同一份。
4. **小消息保留 Unix Socket**：控制帧/小状态仍走 Unix Socket，避免 SHM 池碎片化。

### 10.4 AuroraDrive 通信升级方案

综合以上，给出分阶段升级方案：

**阶段一：QoS 抽象层（低风险，立即收益）**

- 在 AuroraDrive 通信 API 中引入 `QoSProfile`（reliability/history(depth)/durability/deadline/liveliness/lifespan/ownership）。
- 在二进制帧头扩展 QoS 字段；发送侧按 QoS 决定丢弃/缓存/重传；接收侧按 QoS 缓存历史、超时回调。
- 收益：关键链路可靠性 + 冷启动状态同步 + 故障感知，不改动传输层。

**阶段二：共享内存大消息通道（中风险，大消息性能跃升）**

- 新增 SHM Transport：高频大消息 Channel（点云/图像）走 SHM 段 + 环形缓冲 + Notifier。
- 保留 Unix Socket 作为控制/小消息与 SHM 通知的 fallback。
- 自动选择：同进程→直接回调；同主机跨进程大消息→SHM；小消息/控制→Unix Socket；跨主机→（阶段四）。
- 收益：大消息延迟与 CPU 占用大幅下降，消除 send/recv 拷贝。

**阶段三：零拷贝 loan + 类型化（IDL/Protobuf）**

- 引入 loan API：写者借 SHM buffer 直接写入，传索引而非数据。
- 引入 IDL/Protobuf 类型注册（借鉴 DDS IDL register_type / CyberRT proto_type+proto_desc），帧自带类型描述，强类型安全与演进。
- 收益：真正零拷贝 + 类型安全 + 防御性编程。

**阶段四：标准服务发现 + 跨主机 + DDS 互通（可选，生态对接）**

- 引入去中心化服务发现（组播 PDP/EDP 风格或轻量 Discovery Server），替代硬编码 socket 路径。
- 跨主机链路引入 UDP/TCP（RTPS 兼容）传输。
- 视生态需求，可直接引入 Fast DDS 作为底层（通过 RMW 思路做抽象），或保持自研但兼容 RTPS 线协议，实现与 ROS2/DDS 生态互通。
- 收益：动态发现、跨主机、ROS2 生态对接、多供应商互操作。

**选型建议**：

- 若 AuroraDrive 需深度对接 ROS2 生态/多供应商 → 直接采用 Fast DDS（`rmw_fastrtps_cpp` 路径）+ 自研调度适配层，最大化复用标准。
- 若 AuroraDrive 倾向自研可控、仅借鉴思想 → 按阶段一~三自研 QoS+SHM+零拷贝，阶段四视需求再定。
- 中间件抽象层（RMW 思路）务必保留，使未来可在"自研 SHM/QoS"与"Fast DDS"间切换，避免锁死。

### 10.5 升级收益预期

| 指标 | 当前（Unix Socket+二进制帧） | 升级后（QoS+SHM+零拷贝） |
|---|---|---|
| 大消息延迟 | 受 send/recv 拷贝限制 | 微秒级（接近 memcpy/直接读） |
| CPU 占用 | 高（每帧系统调用+拷贝） | 低（SHM 直接内存访问） |
| 可靠性 | 无保证 | 按 QoS（RELIABLE/BEST_EFFORT） |
| 冷启动状态 | 空窗 | TRANSIENT_LOCAL 立即同步 |
| 故障感知 | 无/慢 | Liveliness/Deadline 秒级感知 |
| 跨主机 | 不支持 | 阶段四支持 |
| 生态互通 | 无 | 阶段四可通 ROS2/DDS |
| 类型安全 | 弱（口头约定） | IDL/Protobuf 强类型 |

---

## 参考来源

- OMG DDS 规范（DCPS / DDSI-RTPS / XTypes / Security / IDL 等）
- eProsima Fast DDS 官方文档与性能对比（Fast DDS vs Cyclone DDS）
- Eclipse Cyclone DDS 文档
- ROS2 RMW 抽象层与多 RMW 切换实践
- 百度 Apollo CyberRT 源码分析（Transport/Dispatcher/TopologyManager/QoS）
- DDS CDR 序列化标准演进、RTPS 报文结构、服务发现 PDP/EDP 解析等公开技术资料

---

> 本报告基于 WebSearch + WebFetch 工具调用累计完成，涵盖 DDS 标准、FastRTPS/FastDDS、QoS、通信模型、CDR 序列化、传输（UDP/TCP/SHM/零拷贝）、服务发现（SPDP/SEDP/Discovery Server）、Cyclone DDS、ROS1 TCPROS 对比、CyberRT 对比及 AuroraDrive 迁移方案。
>
> **实际工具调用次数：55 次**
