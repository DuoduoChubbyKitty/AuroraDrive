# 百度 Apollo Routing 模块深度研究报告（A\* + TopoGraph）

> 研究对象：ApolloAuto/apollo `modules/routing`
> 研究方法：WebSearch + WebFetch 抓取 Apollo 官方 GitHub 源码（jsDelivr CDN 镜像、GitHub blob）与社区解析
> 研究目的：为 AuroraDrive 漫游模式提供拓扑图迁移方案
> 研究日期：2026-07-23

---

## 0. 总览：Routing 在 Apollo 中的定位

Apollo 的决策栈分为：Perception（感知）→ Prediction（预测）→ **Routing（全局路由）** → Planning（轨迹规划）→ Control（控制）。

Routing 模块对应人类司机"上车打开导航"的动作：它在**宏观路网**层面给出一条从起点到终点（可含途经点）的、车道级别的全局行驶路线，输出给 Planning 模块作为参考线（ReferenceLine）生成的依据。它**不关心**当前路况、障碍物、红绿灯实时状态——那是 Planning 的事；它只关心"拓扑上能不能走、走哪条最划算"。

Apollo 的 Routing 不直接在高精地图（HD Map）上做最短路搜索，而是先把 HD Map 离线编译成一张**轻量级拓扑图 TopoGraph**（protobuf 二进制文件 `routing_map.pb.txt`），运行时在该拓扑图上跑 **A\*** 算法，最后把 A\* 输出的节点序列重构成 `RoadSegment / Passage / LaneSegment` 三级结构返回。

整体流水线：

```
HD Map (base_map)  ──topo_creator(离线)──▶  TopoGraph (routing_map.pb.txt)
                                                  │
Dreamview/HMI ──RoutingRequest──▶ RoutingComponent
                                                  │
                            Navigator.SearchRoute()
                                  ├─ Init() : GetWayNodes + BlackListRangeGenerator
                                  ├─ SearchRouteByStrategy() : AStarStrategy (每对 waypoint)
                                  │     └─ SubTopoGraph + A* 在拓扑图上搜索
                                  ├─ MergeRoute() : 合并多段
                                  └─ ResultGenerator.GeneratePassageRegion()
                                                  │
                                          RoutingResponse (RoadSegment...)
                                                  │
                                  Planning.pnc_map → ReferenceLineProvider → ReferenceLine
```

---

## 1. Routing 模块架构

### 1.1 `modules/routing` 目录结构

```
modules/routing/
├── routing_component.cc/.h        # CyberRT 组件入口（订阅请求、发布响应）
├── routing.cc/.h                  # 业务逻辑层（Routing 类）
├── BUILD, cyberfile.xml, README
├── common/
│   ├── routing_gflags.cc/.h       # gflags 参数定义
│   └── routing_config.proto       # RoutingConfig（base_speed, *_turn_penalty, change_penalty...）
├── core/
│   ├── navigator.cc/.h            # 核心搜索引擎 Navigator
│   ├── result_generator.cc/.h     # 把 A* 节点序列转成 Passage/RoadSegment
│   └── black_list_range_generator.cc/.h  # 黑名单 → TopoRangeManager
├── graph/
│   ├── topo_graph.cc/.h           # TopoGraph：装载 Node/Edge
│   ├── topo_node.cc/.h            # TopoNode：车道节点（含 TopoEdge 定义）
│   ├── topo_edge.cc/.h            # （TopoEdge 在 topo_node.h 中定义）
│   ├── sub_topo_graph.cc/.h       # 子拓扑图（黑名单切片）
│   ├── node_with_range.cc/.h      # NodeWithRange：带 [start_s, end_s] 的节点
│   ├── topo_range.cc/.h           # NodeSRange / TopoRangeManager
│   └── range_utils.h
├── strategy/
│   ├── strategy.h                 # 抽象策略基类
│   └── a_star_strategy.cc/.h     # A* 实现
├── topo_creator/                  # 离线建图工具
│   ├── topo_creator.cc/.h
│   ├── node_creator.cc/.h         # Lane → Node
│   ├── edge_creator.cc/.h         # Lane 邻接 → Edge
│   └── topo_creator_gflags.cc
└── proto/
    └── topo_graph.proto           # Node / Edge / Graph（序列化用）
```

注意：对外消息 `RoutingRequest / RoutingResponse / LaneWaypoint / LaneSegment / Passage / RoadSegment` 在新版 Apollo 中已迁到 `modules/common_msgs/routing_msgs/`（`routing.proto`、`geometry.proto`、`poi.proto`），`modules/routing/proto/` 仅保留 `topo_graph.proto` 与 `routing_config.proto`。

### 1.2 RoutingComponent（CyberRT 组件层）

`routing_component.cc` 是 CyberRT Component，模板参数为 `routing::RoutingRequest`，即订阅 `RoutingRequest` 话题。

```cpp
bool RoutingComponent::Init() {
  RoutingConfig routing_conf;
  ACHECK(cyber::ComponentBase::GetProtoConfig(&routing_conf));
  // 实时响应 Writer
  apollo::cyber::proto::RoleAttributes attr;
  attr.set_channel_name(routing_conf.topic_config().routing_response_topic());
  auto qos = attr.mutable_qos_profile();
  qos->set_history(apollo::cyber::proto::QosHistoryPolicy::HISTORY_KEEP_LAST);
  qos->set_reliability(apollo::cyber::proto::QosReliabilityPolicy::RELIABILITY_RELIABLE);
  qos->set_durability(apollo::cyber::proto::QosDurabilityPolicy::DURABILITY_TRANSIENT_LOCAL);
  response_writer_ = node_->CreateWriter<routing::RoutingResponse>(attr);
  // 历史 Writer（同样 TRANSIENT_LOCAL）
  response_history_writer_ = node_->CreateWriter<routing::RoutingResponse>(attr_history);
  // 周期性重发最近一次响应（默认 1000ms），保证 Planning 重启能拿到路由
  timer_.reset(new ::apollo::cyber::Timer(
      FLAGS_routing_response_history_interval_ms, /*lambda 重发 response_*/, false));
  timer_->Start();
  return routing_.Init().ok() && routing_.Start().ok();
}

bool RoutingComponent::Proc(const std::shared_ptr<routing::RoutingRequest>& request) {
  auto response = std::make_shared<routing::RoutingResponse>();
  if (!routing_.Process(request, response.get())) return false;
  common::util::FillHeader(node_->Name(), response.get());
  response_writer_->Write(response);
  { std::lock_guard<std::mutex> guard(mutex_); response_ = std::move(response); }
  return true;
}
```

两个关键设计：

- **`DURABILITY_TRANSIENT_LOCAL`**：晚启动的订阅者（如 Planning）能立刻收到最近一条路由，避免"无路由空跑"。
- **历史响应定时器**（`routing_response_history_interval_ms` 默认 1000ms）：周期重发缓存的 `response_`，对弱网/重启场景提供鲁棒性。

### 1.3 Routing 类（业务逻辑层）

```cpp
class Routing {
 public:
  apollo::common::Status Init();     // 加载拓扑图、初始化 Navigator
  apollo::common::Status Start();
  bool Process(const std::shared_ptr<routing::RoutingRequest>& routing_request,
               routing::RoutingResponse* const routing_response);
 private:
  std::vector<routing::RoutingRequest> FillLaneInfoIfMissing(
      const routing::RoutingRequest& routing_request);  // waypoint 仅有 pose 时用 HD Map 反查 lane_id/s
 private:
  std::unique_ptr<Navigator> navigator_ptr_;
  common::monitor::MonitorLogBuffer monitor_logger_buffer_;
  const hdmap::HDMap* hdmap_ = nullptr;
};
```

`Routing::Process` 做两件事：(1) 若请求的 waypoint 只有点坐标而缺 `id/s`，调用 `FillLaneInfoIfMissing` 用 HD Map 反查最近车道并补全；(2) 调 `navigator_ptr_->SearchRoute(fixed_request, response)`。

### 1.4 Navigator 类（核心搜索引擎）

`navigator.h`：

```cpp
class Navigator {
 public:
  explicit Navigator(const std::string& topo_file_path);  // 读 routing_map.pb.txt → TopoGraph
  bool IsReady() const;
  bool SearchRoute(const routing::RoutingRequest& request,
                   routing::RoutingResponse* const response);
 private:
  bool Init(const routing::RoutingRequest& request, const TopoGraph* graph,
            std::vector<const TopoNode*>* const way_nodes,
            std::vector<double>* const way_s);
  void Clear();
  bool SearchRouteByStrategy(const TopoGraph* graph,
            const std::vector<const TopoNode*>& way_nodes,
            const std::vector<double>& way_s,
            std::vector<NodeWithRange>* const result_nodes) const;
  bool MergeRoute(const std::vector<NodeWithRange>& node_vec,
            std::vector<NodeWithRange>* const result_node_vec) const;
 private:
  bool is_ready_ = false;
  std::unique_ptr<TopoGraph> graph_;
  TopoRangeManager topo_range_manager_;                       // 黑名单范围
  std::unique_ptr<BlackListRangeGenerator> black_list_generator_;
  std::unique_ptr<ResultGenerator> result_generator_;
};
```

`Navigator::SearchRoute` 的实际流程（源自 `navigator.cc`）：

```cpp
bool Navigator::SearchRoute(const routing::RoutingRequest& request,
                             routing::RoutingResponse* const response) {
  if (!ShowRequestInfo(request, graph_.get())) { ... return false; }   // 校验 waypoint/blacklist 都在图里
  if (!IsReady()) { ... return false; }
  std::vector<const TopoNode*> way_nodes;
  std::vector<double> way_s;
  if (!Init(request, graph_.get(), &way_nodes, &way_s)) { ... return false; }
  // Init 内部：GetWayNodes() + black_list_generator_->GenerateBlackMapFromRequest()

  std::vector<NodeWithRange> result_nodes;
  if (!SearchRouteByStrategy(graph_.get(), way_nodes, way_s, &result_nodes)) { ... return false; }
  if (result_nodes.empty()) { ... return false; }

  // 用请求首尾的 s 裁剪结果区间
  result_nodes.front().SetStartS(request.waypoint().begin()->s());
  result_nodes.back().SetEndS(request.waypoint().rbegin()->s());

  // 节点序列 → RoadSegment/Passage/LaneSegment
  if (!result_generator_->GeneratePassageRegion(
          graph_->MapVersion(), request, result_nodes, topo_range_manager_, response)) { ... return false; }
  SetErrorCode(ErrorCode::OK, "Success!", response->mutable_status());
  PrintDebugData(result_nodes);
  return true;
}
```

`SearchRouteByStrategy` 是分段搜索的核心——对**每对相邻 waypoint** 都独立建一张 `SubTopoGraph`（把黑名单与起终点的不可达区间切成子节点），然后在子图上跑一次 A\*，最后 `MergeRoute` 拼接：

```cpp
bool Navigator::SearchRouteByStrategy(...) const {
  std::unique_ptr<Strategy> strategy_ptr(new AStarStrategy(FLAGS_enable_change_lane_in_result));
  std::vector<NodeWithRange> node_vec;
  for (size_t i = 1; i < way_nodes.size(); ++i) {
    const auto* way_start = way_nodes[i - 1];
    const auto* way_end   = way_nodes[i];
    double way_start_s = way_s[i - 1];
    double way_end_s   = way_s[i];
    // 把起终点本身不可达的区间也加进黑名单
    TopoRangeManager full_range_manager = topo_range_manager_;
    black_list_generator_->AddBlackMapFromTerminal(
        way_start, way_end, way_start_s, way_end_s, &full_range_manager);
    SubTopoGraph sub_graph(full_range_manager.RangeMap());
    const auto* start = sub_graph.GetSubNodeWithS(way_start, way_start_s);
    const auto* end   = sub_graph.GetSubNodeWithS(way_end, way_end_s);
    std::vector<NodeWithRange> cur_result_nodes;
    if (!strategy_ptr->Search(graph, &sub_graph, start, end, &cur_result_nodes)) { ... return false; }
    node_vec.insert(node_vec.end(), cur_result_nodes.begin(), cur_result_nodes.end());
  }
  return MergeRoute(node_vec, result_nodes);
}
```

`MergeRoute` 把相邻同 Lane 的 `NodeWithRange` 合并成一条连续区间，并校验连续性（`back.EndS() >= node.StartS()`）。

---

## 2. A\* 拓扑搜索

### 2.1 策略类与数据结构

`strategy/a_star_strategy.h`：

```cpp
class AStarStrategy : public Strategy {
 public:
  explicit AStarStrategy(bool enable_change);  // enable_change = FLAGS_enable_change_lane_in_result
  virtual bool Search(const TopoGraph* graph, const SubTopoGraph* sub_graph,
                      const TopoNode* src_node, const TopoNode* dest_node,
                      std::vector<NodeWithRange>* const result_nodes);
 private:
  void Clear();
  double HeuristicCost(const TopoNode* src_node, const TopoNode* dest_node);
  double GetResidualS(const TopoNode* node);                  // 节点剩余可行驶 s
  double GetResidualS(const TopoEdge* edge, const TopoNode* to_node);  // 边到节点剩余 s
 private:
  bool change_lane_enabled_;
  std::unordered_set<const TopoNode*> open_set_;        // OPEN 集（快速判重）
  std::unordered_set<const TopoNode*> closed_set_;      // CLOSED 集
  std::unordered_map<const TopoNode*, const TopoNode*> came_from_;  // 父节点
  std::unordered_map<const TopoNode*, double> g_score_;  // g(n)
  std::unordered_map<const TopoNode*, double> enter_s_;  // 进入该节点时的 s（用于换道距离判定）
};
```

A\* 内部还定义了一个优先队列节点 `SearchNode`：

```cpp
struct SearchNode {
  const TopoNode* topo_node = nullptr;
  double f = std::numeric_limits<double>::max();
  bool operator<(const SearchNode& node) const {
    return f > node.f;   // 注意取反：让 std::priority_queue 的 top 是 f 最小者
  }
};
```

`std::priority_queue` 默认是大顶堆，这里通过反转 `<` 让栈顶输出 **f 最小** 的节点——这是 A\* 取最优展开节点的标准做法。

### 2.2 A\* 主循环（节点扩展规则）

`a_star_strategy.cc::Search` 的核心逻辑：

```cpp
bool AStarStrategy::Search(...) {
  Clear();
  std::priority_queue<SearchNode> open_set_detail;
  SearchNode src_search_node(src_node);
  src_search_node.f = HeuristicCost(src_node, dest_node);   // g=0, f=h
  open_set_detail.push(src_search_node);
  open_set_.insert(src_node);
  g_score_[src_node] = 0.0;
  enter_s_[src_node] = src_node->StartS();

  while (!open_set_detail.empty()) {
    current_node = open_set_detail.top();
    const auto* from_node = current_node.topo_node;
    if (current_node.topo_node == dest_node) {              // 命中终点 → 回溯
      return Reconstruct(came_from_, from_node, result_nodes);
    }
    open_set_.erase(from_node);
    open_set_detail.pop();
    if (closed_set_.count(from_node) != 0) continue;       // 已展开过，跳过
    closed_set_.emplace(from_node);

    // 关键：剩余距离不足换道时，只走前向边，不换道
    const auto& neighbor_edges =
        (GetResidualS(from_node) > FLAGS_min_length_for_lane_change &&
         change_lane_enabled_)
            ? from_node->OutToAllEdge()      // 前向 + 左 + 右
            : from_node->OutToSucEdge();     // 仅前向（后继）

    // 通过 SubTopoGraph 把黑名单切片后的子边展开进来
    next_edge_set.clear();
    for (const auto* edge : neighbor_edges) {
      sub_edge_set.clear();
      sub_graph->GetSubInEdgesIntoSubGraph(edge, &sub_edge_set);
      next_edge_set.insert(sub_edge_set.begin(), sub_edge_set.end());
    }

    for (const auto* edge : next_edge_set) {
      const auto* to_node = edge->ToNode();
      if (closed_set_.count(to_node) == 1) continue;        // 已闭合
      if (GetResidualS(edge, to_node) < FLAGS_min_length_for_lane_change)
        continue;                                            // 换道空间不足
      // g 值
      tentative_g_score =
          g_score_[current_node.topo_node] + GetCostToNeighbor(edge);
      // GetCostToNeighbor(edge) = edge->Cost() + edge->ToNode()->Cost()
      if (edge->Type() != TopoEdgeType::TET_FORWARD) {
        // 换道时把两端节点代价减半补偿（避免换道节点自身代价被重复计入）
        tentative_g_score -=
            (edge->FromNode()->Cost() + edge->ToNode()->Cost()) / 2;
      }
      double f = tentative_g_score + HeuristicCost(to_node, dest_node);
      if (open_set_.count(to_node) != 0 && f >= g_score_[to_node]) continue;

      // enter_s 维护：前向 → 重置为 to_node 起点；换道 → 按长度比例换算
      if (edge->Type() == TopoEdgeType::TET_FORWARD) {
        enter_s_[to_node] = to_node->StartS();
      } else {
        double to_node_enter_s =
            (enter_s_[from_node] + FLAGS_min_length_for_lane_change) /
            from_node->Length() * to_node->Length();
        to_node_enter_s = std::min(to_node_enter_s, to_node->Length());
        if (to_node_enter_s > to_node->EndS() && to_node == dest_node) continue;
        enter_s_[to_node] = to_node_enter_s;
      }
      g_score_[to_node] = f;                                 // 注：Apollo 实际存 f 而非 g，用于比较
      SearchNode next_node(to_node); next_node.f = f;
      open_set_detail.push(next_node);
      came_from_[to_node] = from_node;
      if (open_set_.count(to_node) == 0) open_set_.insert(to_node);
    }
  }
  return false;   // 失败
}
```

### 2.3 节点扩展规则总结

1. **OPEN 集用优先队列 + 哈希集双结构**：优先队列保证取 f 最小，哈希集 `open_set_` 提供 O(1) 判重。
2. **CLOSED 集只入不出**：`closed_set_` 标记已展开节点，再次弹出直接跳过（Apollo 不做 CLOSED 重开）。
3. **换道门控**：若 `GetResidualS(from_node) <= min_length_for_lane_change`（默认 1.0m）或 `change_lane_enabled_==false`，**只展开前向边** `OutToSucEdge()`，不展开左右换道边。这是物理约束——剩余长度不够换道就别换。
4. **子图边替换**：原始 `TopoEdge` 通过 `sub_graph->GetSubInEdgesIntoSubGraph` 映射到黑名单切片后的子边，使 A\* 看到的是裁剪过的可达子图。
5. **g 值修正**：换道边代价 `GetCostToNeighbor = edge.Cost + to_node.Cost`，再减去 `(from.Cost + to.Cost)/2`，等价于 `edge.Cost + (to.Cost - from.Cost)/2`——让换道代价更聚焦于"换道本身"而非节点长度。

### 2.4 启发式函数

```cpp
double AStarStrategy::HeuristicCost(const TopoNode* src_node,
                                    const TopoNode* dest_node) {
  const auto& src_point = src_node->AnchorPoint();
  const auto& dest_point = dest_node->AnchorPoint();
  double distance = std::fabs(src_point.x() - dest_point.x()) +
                    std::fabs(src_point.y() - dest_point.y());
  return distance;   // 曼哈顿距离
}
```

- 使用**曼哈顿距离**（|Δx| + |Δy|）而非欧氏距离。曼哈顿距离 ≥ 欧氏距离，作为 admissible 启发式时**偏保守**（仍保证最优性，但展开节点可能略多）。
- `AnchorPoint()` 是 TopoNode 在构造时计算的一个锚点（通常取中心曲线中点），用于 A\* 的距离估算。

### 2.5 剩余距离 `GetResidualS`

两个重载决定"还能走多远才必须换道/到终点"：

- `GetResidualS(node)`：从 `enter_s_[node]` 到节点末尾 `EndS()`；若该节点有同 Lane 的后继子节点（即被切片），则用后继的 `EndS()`，体现"同车道剩余总长"。
- `GetResidualS(edge, to_node)`：前向边返回 `+∞`（前向永远够）；换道边则按 `from` 的 enter_s 比例换算到 `to_node` 上，返回 `to_node` 上从换道进入点到末尾的剩余长度。

### 2.6 路径回溯与换道修正 `Reconstruct`

```cpp
bool Reconstruct(const std::unordered_map<const TopoNode*, const TopoNode*>& came_from,
                 const TopoNode* dest_node, std::vector<NodeWithRange>* result_nodes) {
  std::vector<const TopoNode*> result_node_vec;
  result_node_vec.push_back(dest_node);
  for (auto iter = came_from.find(dest_node); iter != came_from.end();
       iter = came_from.find(iter->second))
    result_node_vec.push_back(iter->second);
  std::reverse(result_node_vec.begin(), result_node_vec.end());
  if (!AdjustLaneChange(&result_node_vec)) return false;     // 换道节点后处理
  result_nodes->clear();
  for (const auto* node : result_node_vec)
    result_nodes->emplace_back(node->OriginNode(), node->StartS(), node->EndS());
  return true;
}
```

`AdjustLaneChange` 包含 `AdjustLaneChangeBackward` + `AdjustLaneChangeForward`：对每条换道边，在左右邻居里找一条"区间最大"的等价换道节点替换，目的是让换道发生在更宽敞的路段上，避免在最短的切片上换道。这是 Apollo 对纯 A\* 结果的一项工程优化。

---

## 3. TopoGraph 道路节点图

### 3.1 拓扑图概念与序列化

TopoGraph 是 HD Map 的**拓扑抽象**：每条 Lane → 一个 Node；Lane 间的连接（前驱/后继/左邻/右邻）→ Edge。几何信息（中心线点云）只在 Node 里保留一份用于后续 ReferenceLine 采样，搜索时不再用几何。

序列化格式定义在 `modules/routing/proto/topo_graph.proto`：

```protobuf
syntax = "proto2";
package apollo.routing;
import "modules/common_msgs/map_msgs/map_geometry.proto";

message CurvePoint  { optional double s = 1; }
message CurveRange  { optional CurvePoint start = 1; optional CurvePoint end = 2; }

message Node {
  optional string lane_id = 1;
  optional double length = 2;
  repeated CurveRange left_out = 3;     // 左侧允许换道的 s 区间（虚线段）
  repeated CurveRange right_out = 4;    // 右侧允许换道的 s 区间
  optional double cost = 5;             // 通行代价
  optional apollo.hdmap.Curve central_curve = 6;  // 中心线（用于生成参考线）
  optional bool is_virtual = 7 [default = true];  // 是否虚拟节点（路口内）
  optional string road_id = 8;
}

message Edge {
  enum DirectionType { FORWARD = 0; LEFT = 1; RIGHT = 2; }
  optional string from_lane_id = 1;
  optional string to_lane_id = 2;
  optional double cost = 3;             // 换道代价（前向为 0）
  optional DirectionType direction_type = 4;
}

message Graph {
  optional string hdmap_version = 1;
  optional string hdmap_district = 2;
  repeated Node node = 3;
  repeated Edge edge = 4;
}
```

`is_virtual`：若 Lane 位于 junction（路口）内部且无左右邻居，则为虚拟节点（`true`），代价计算时不单独计长——这是路口"虚拟连接段"的处理。

### 3.2 TopoGraph 类

`graph/topo_graph.h`：

```cpp
class TopoGraph {
 public:
  bool LoadGraph(const Graph& filename);
  const std::string& MapVersion() const;
  const std::string& MapDistrict() const;
  const TopoNode* GetNode(const std::string& id) const;        // lane_id → TopoNode
  void GetNodesByRoadId(const std::string& road_id,
                        std::unordered_set<const TopoNode*>* const node_in_road) const;
 private:
  bool LoadNodes(const Graph& graph);
  bool LoadEdges(const Graph& graph);
 private:
  std::string map_version_;
  std::string map_district_;
  std::vector<std::shared_ptr<TopoNode>> topo_nodes_;
  std::vector<std::shared_ptr<TopoEdge>> topo_edges_;
  std::unordered_map<std::string, int> node_index_map_;              // lane_id → index
  std::unordered_map<std::string, std::unordered_set<const TopoNode*>> road_node_map_;
};
```

`topo_graph.cc` 的装载逻辑：

```cpp
bool TopoGraph::LoadNodes(const Graph& graph) {
  for (const auto& node : graph.node()) {
    node_index_map_[node.lane_id()] = static_cast<int>(topo_nodes_.size());
    std::shared_ptr<TopoNode> topo_node(new TopoNode(node));
    road_node_map_[node.road_id()].insert(topo_node.get());
    topo_nodes_.push_back(std::move(topo_node));
  }
  return true;
}
bool TopoGraph::LoadEdges(const Graph& graph) {
  for (const auto& edge : graph.edge()) {
    TopoNode* from_node = topo_nodes_[node_index_map_[edge.from_lane_id()]].get();
    TopoNode* to_node   = topo_nodes_[node_index_map_[edge.to_lane_id()]].get();
    std::shared_ptr<TopoEdge> topo_edge(new TopoEdge(edge, from_node, to_node));
    from_node->AddOutEdge(topo_edge.get());
    to_node->AddInEdge(topo_edge.get());
    topo_edges_.push_back(std::move(topo_edge));
  }
  return true;
}
```

要点：
- **先建节点、后建边**——边必须能在 `node_index_map_` 里找到两端，否则整图加载失败。
- 边建好后立即挂到两端节点的入/出边集合里（`AddOutEdge` / `AddInEdge`），节点内部按方向分类入桶。
- `road_node_map_` 提供按 road_id 反查所有 lane 节点的能力，供黑名单/结果生成使用。

### 3.3 TopoGraph vs Graph

Apollo 不直接在 protobuf `Graph` 上搜索，而是包了一层 `TopoGraph`：原因是 `TopoNode` 内部把边按方向分桶（`OutToLeftEdge / OutToRightEdge / OutToSucEdge ...`）、维护 `out_edge_map_`/`in_edge_map_` 哈希表、预排序换道区间 `left_out_sorted_range_`，使 A\* 的邻居展开与"是否够长换道"判定都是 O(1)。原始 `Graph` protobuf 只是序列化载体。

---

## 4. TopoNode / TopoEdge

### 4.1 TopoNode（车道节点）

`graph/topo_node.h`（节选）：

```cpp
class TopoNode {
 public:
  static bool IsOutRangeEnough(const std::vector<NodeSRange>& range_vec,
                               double start_s, double end_s);
  explicit TopoNode(const Node& node);                       // 原始节点
  TopoNode(const TopoNode* topo_node, const NodeSRange& range);  // 子节点（SubTopoGraph 用）

  const Node& PbNode() const;
  double Length() const;
  double Cost() const;
  bool IsVirtual() const;
  const std::string& LaneId() const;
  const std::string& RoadId() const;
  const hdmap::Curve& CentralCurve() const;
  const common::PointENU& AnchorPoint() const;
  const std::vector<NodeSRange>& LeftOutRange() const;       // 左换道出口区间
  const std::vector<NodeSRange>& RightOutRange() const;

  // 入边按方向分类
  const std::unordered_set<const TopoEdge*>& InFromAllEdge() const;
  const std::unordered_set<const TopoEdge*>& InFromLeftEdge() const;
  const std::unordered_set<const TopoEdge*>& InFromRightEdge() const;
  const std::unordered_set<const TopoEdge*>& InFromLeftOrRightEdge() const;
  const std::unordered_set<const TopoEdge*>& InFromPreEdge() const;     // 前驱入边
  // 出边按方向分类
  const std::unordered_set<const TopoEdge*>& OutToAllEdge() const;
  const std::unordered_set<const TopoEdge*>& OutToLeftEdge() const;
  const std::unordered_set<const TopoEdge*>& OutToRightEdge() const;
  const std::unordered_set<const TopoEdge*>& OutToLeftOrRightEdge() const;
  const std::unordered_set<const TopoEdge*>& OutToSucEdge() const;      // 后继出边（前向）
  const TopoEdge* GetInEdgeFrom(const TopoNode* from_node) const;
  const TopoEdge* GetOutEdgeTo(const TopoNode* to_node) const;
  // 子节点信息
  const TopoNode* OriginNode() const;
  double StartS() const;
  double EndS() const;
  bool IsSubNode() const;
  bool IsInFromPreEdgeValid() const;
  bool IsOutToSucEdgeValid() const;
 private:
  Node pb_node_;
  common::PointENU anchor_point_;
  double start_s_, end_s_;
  bool is_left_range_enough_; int left_prefer_range_index_;
  bool is_right_range_enough_; int right_prefer_range_index_;
  std::vector<NodeSRange> left_out_sorted_range_, right_out_sorted_range_;
  std::unordered_set<const TopoEdge*> in_from_all_edge_set_, in_from_left_edge_set_,
      in_from_right_edge_set_, in_from_left_or_right_edge_set_, in_from_pre_edge_set_;
  std::unordered_set<const TopoEdge*> out_to_all_edge_set_, out_to_left_edge_set_,
      out_to_right_edge_set_, out_to_left_or_right_edge_set_, out_to_suc_edge_set_;
  std::unordered_map<const TopoNode*, const TopoEdge*> out_edge_map_, in_edge_map_;
  const TopoNode* origin_node_;
};
```

关键点：
- **同一份边按方向入多个桶**：`AddOutEdge` 会同时把边塞进 `out_to_all_edge_set_` 和对应方向桶（`out_to_suc_edge_set_` / `out_to_left_edge_set_` / `out_to_right_edge_set_` / `out_to_left_or_right_edge_set_`）。A\* 根据是否允许换道直接取对应桶，无需遍历过滤。
- **`out_edge_map_` / `in_edge_map_`**：`lane → lane` 的边 O(1) 查找，用于 `Reconstruct` 与 `AdjustLaneChange`。
- **`left_out_sorted_range_`**：从 protobuf `left_out` 解析并按 s 排序后的可换道区间，配合 `NodeSRange::IsEnoughForChangeLane` 判断"这段够不够长换道"。

### 4.2 节点代价（node_creator.cc）

```cpp
void InitNodeCost(const Lane& lane, const RoutingConfig& routing_config, Node* const node) {
  double lane_length = GetLaneLength(lane);
  double speed_limit = lane.has_speed_limit() ? lane.speed_limit() : routing_config.base_speed();
  double ratio = speed_limit >= routing_config.base_speed()
                     ? std::sqrt(routing_config.base_speed() / speed_limit)
                     : 1.0;
  double cost = lane_length * ratio;
  if (lane.has_turn()) {
    if (lane.turn() == Lane::LEFT_TURN)       cost += routing_config.left_turn_penalty();
    else if (lane.turn() == Lane::RIGHT_TURN) cost += routing_config.right_turn_penalty();
    else if (lane.turn() == Lane::U_TURN)     cost += routing_config.uturn_penalty();
  }
  node->set_cost(cost);
}
```

- 代价 ≈ **长度 × 速度比**：低速道（speed_limit 小）会让 ratio>1，等效"耗时更长，代价更高"。
- **转弯惩罚**叠加：左转、右转、掉头分别加常量惩罚，引导 A\* 偏好直行。
- `is_virtual`：若 Lane 有 `junction_id` 且**没有**左右前向邻居 → 虚拟节点（路口内连接段），不参与代价长度独立计算。

### 4.3 TopoEdge（车道连接边）

```cpp
enum TopoEdgeType { TET_FORWARD, TET_LEFT, TET_RIGHT };

class TopoEdge {
 public:
  TopoEdge(const Edge& edge, const TopoNode* from_node, const TopoNode* to_node);
  const Edge& PbEdge() const;
  double Cost() const;
  const std::string& FromLaneId() const;
  const std::string& ToLaneId() const;
  TopoEdgeType Type() const;
  const TopoNode* FromNode() const;
  const TopoNode* ToNode() const;
 private:
  Edge pb_edge_;
  const TopoNode* from_node_ = nullptr;
  const TopoNode* to_node_ = nullptr;
};
```

### 4.4 边代价（edge_creator.cc）

```cpp
void GetPbEdge(const Node& node_from, const Node& node_to,
               const Edge::DirectionType& type,
               const RoutingConfig& routing_config, Edge* edge) {
  edge->set_from_lane_id(node_from.lane_id());
  edge->set_to_lane_id(node_to.lane_id());
  edge->set_direction_type(type);
  edge->set_cost(0.0);                            // 前向边代价恒为 0
  if (type == Edge::LEFT || type == Edge::RIGHT) {
    const auto& target_range =
        (type == Edge::LEFT) ? node_from.left_out() : node_from.right_out();
    double changing_area_length = 0.0;
    for (const auto& range : target_range)
      changing_area_length += range.end().s() - range.start().s();
    double ratio = 1.0;
    if (changing_area_length < routing_config.base_changing_length())
      ratio = std::pow(changing_area_length / routing_config.base_changing_length(), -1.5);
    edge->set_cost(routing_config.change_penalty() * ratio);
  }
}
```

- **前向边（FORWARD）代价 = 0**：前后继车道延续不收额外费。
- **换道边（LEFT/RIGHT）代价 = `change_penalty × ratio`**：可换道区间越短，`ratio = (area/base)^(-1.5)` 越大，代价越高——惩罚"在虚线很短的路段强行换道"。
- 这与 A\* 中的 `tentative_g_score` 修正配合，使 A\* 倾向于在宽敞虚线段完成换道。

### 4.5 车道连接类型映射

HD Map 中 Lane 的四种邻接关系，如何变成 TopoEdge：

| HD Map Lane 字段 | TopoEdge 类型 | 说明 |
|---|---|---|
| `successor_lane_id` | `TET_FORWARD` | 同向前继（车道延续） |
| `predecessor_lane_id` | （反向构造 FORWARD） | 反向时由前驱节点的后继边覆盖 |
| `left_neighbor_forward_lane_id` | `TET_LEFT` | 左侧前向邻居（可换道） |
| `right_neighbor_forward_lane_id` | `TET_RIGHT` | 右侧前向邻居（可换道） |

只有 `left_out` / `right_out` 区间内（即边界为 `DOTTED_YELLOW` / `DOTTED_WHITE` 虚线）的 s 段才允许换道——`node_creator::AddOutBoundary` 负责把虚线边界段转成 `CurveRange` 写入 Node。

---

## 5. RoutingRequest

`modules/common_msgs/routing_msgs/routing.proto`：

```protobuf
message RoutingRequest {
  optional apollo.common.Header header = 1;
  // 至少两个点：第一个为起点，最后一个为终点，中间为途经点（必须依次经过）
  repeated apollo.routing.LaneWaypoint waypoint = 2;
  repeated apollo.routing.LaneSegment blacklisted_lane = 3;   // 黑名单车道段
  repeated string blacklisted_road = 4;                       // 黑名单道路（整条 road 禁行）
  optional bool broadcast = 5 [default = true];
  optional apollo.routing.ParkingInfo parking_info = 6 [deprecated = true];
  optional bool is_start_pose_set = 7 [default = false];      // 首点是否为车辆当前位姿
}
```

`geometry.proto` 中的 `LaneWaypoint`：

```protobuf
message LaneWaypoint {
  optional string id = 1;                       // lane_id
  optional double s = 2;                        // 在车道上的纵向 s
  optional apollo.common.PointENU pose = 3;     // 全局坐标（x,y,z）
  optional double heading = 4;                 // dreamview 拖拽方向 → 计算 heading
}
```

### 5.1 字段说明

- **`waypoint`**：路径点序列，至少 2 个。每个点既可填 `id+s`（已知车道），也可只填 `pose`（仅坐标，由 `Routing::FillLaneInfoIfMissing` 用 HD Map 反查最近车道的 `id` 与 `s`）。`is_start_pose_set=true` 表示首点就是车辆当前位姿，用于"从我现在的位置开始导航"。
- **`blacklisted_lane`**：`LaneSegment{id, start_s, end_s}`，临时禁用某车道的一段。A\* 不会从该段穿过（通过 `SubTopoGraph` 把该段切掉）。
- **`blacklisted_road`**：整条 road_id 禁行，等价于把该 road 下所有 Lane 节点加入黑名单。
- **`broadcast`**：是否广播响应（默认 true）。
- **`parking_info`**（已废弃）：泊车场景的停车位信息。

### 5.2 Lane 上下文

每个 waypoint 必须能定位到一条 Lane（lane_id + s），因为 TopoGraph 的节点就是 Lane。若只给 `pose`，`FillLaneInfoIfMissing` 通过 HD Map 的 KD-Tree 查询最近 Lane 并计算 s，再回填 `id/s`。这一步是 Routing 与 HD Map 唯一的运行时耦合（建图阶段另算）。

---

## 6. RoutingResponse

`routing.proto`：

```protobuf
message RoutingResponse {
  optional apollo.common.Header header = 1;
  repeated apollo.routing.RoadSegment road = 2;     // 道路段列表（有序）
  optional apollo.routing.Measurement measurement = 3;  // 路径度量
  optional RoutingRequest routing_request = 4;       // 回填触发本次响应的请求
  optional bytes map_version = 5;                    // 拓扑图版本
  optional apollo.common.StatusPb status = 6;        // 状态码与消息
}
```

`geometry.proto` 中的响应子结构：

```protobuf
message LaneSegment {
  optional string id = 1;        // lane_id
  optional double start_s = 2;   // 该 lane 上要走的起点 s
  optional double end_s = 3;     // 该 lane 上要走的终点 s
}
message Measurement {
  optional double distance = 1;   // 总长度（米）
}
enum ChangeLaneType { FORWARD = 0; LEFT = 1; RIGHT = 2; };
message Passage {
  repeated LaneSegment segment = 1;          // 并行车道的集合
  optional bool can_exit = 2;                // 该通道能否驶出（变道/出口）
  optional ChangeLaneType change_lane_type = 3 [default = FORWARD];  // 进入该 passage 的换道方向
}
message RoadSegment {
  optional string id = 1;                    // road_id
  repeated Passage passage = 2;             // 该道路下的通行通道
}
```

### 6.1 三级结构 RoadSegment → Passage → LaneSegment

- **RoadSegment**：一段"道路"（同一 road_id），内部含若干 Passage。
- **Passage**：一条**可并行**的车道组（同一时刻车辆可在其中任一条 Lane 上行驶并相互换道）。`change_lane_type` 表示进入该 passage 时是直行 / 左换道 / 右换道；`can_exit` 表示该 passage 是否能驶出（用于 Planning 决定是否必须换道离开）。
- **LaneSegment**：单条 Lane 上要行驶的 `[start_s, end_s]` 区间。

### 6.2 路径长度 / 预计时间

- `measurement.distance`：总行驶距离，由 `ResultGenerator` 累加所有 `LaneSegment` 的 `end_s - start_s` 得到。
- Apollo 的 RoutingResponse **不直接给出预计时间**——时间估计在 Planning 阶段结合限速、障碍物预测后才有意义。Routing 只给距离与拓扑序列。若需要粗略时间，可用 `distance / base_speed` 估算。

### 6.3 状态码

`status` 是 `apollo.common.StatusPb`，含 `error_code` 与 `msg`。Navigator 通过 `SetErrorCode` 写入，可能值：
- `OK`："Success!"
- `ROUTING_ERROR_REQUEST`：请求点非法（waypoint/blacklist 不在图里）。
- `ROUTING_ERROR_NOT_READY`：Navigator 未就绪或 Init 失败。
- `ROUTING_ERROR_RESPONSE`：A\* 搜索失败或 Passage 生成失败。

---

## 7. 黑名单节点

### 7.1 BlackListLane / BlackListRoad

请求层：`RoutingRequest.blacklisted_lane`（`LaneSegment`，按 lane + s 区间）与 `blacklisted_road`（string，按 road_id）。

### 7.2 BlackListRangeGenerator

`core/black_list_range_generator.{h,cc}` 负责把请求里的黑名单翻译成 `TopoRangeManager` 中的"节点 → 不可达 s 区间列表"映射：

```cpp
class BlackListRangeGenerator {
 public:
  void GenerateBlackMapFromRequest(const RoutingRequest& request,
                                   const TopoGraph* graph,
                                   TopoRangeManager* const range_manager);
  void AddBlackMapFromTerminal(const TopoNode* src_node, const TopoNode* dest_node,
                               double start_s, double end_s,
                               TopoRangeManager* const range_manager);
};
```

- `GenerateBlackMapFromRequest`：遍历 `blacklisted_lane`，把每个 `[start_s, end_s]` 加到对应 TopoNode 的黑名单；遍历 `blacklisted_road`，用 `graph->GetNodesByRoadId` 把整条 road 下所有节点全段拉黑。
- `AddBlackMapFromTerminal`：把**起终点前后**不可达的区间也加黑（起点之前的 s、终点之后的 s 不能走），保证 A\* 从起点的子节点出发、到终点的子节点结束。

### 7.3 TopoRangeManager 与 SubTopoGraph

`TopoRangeManager` 持有 `unordered_map<const TopoNode*, vector<NodeSRange>>`。`SubTopoGraph` 接收这份黑名单，对每个被黑名单切到的 TopoNode：

1. 把节点按黑名单区间切成多个**有效子区间** `NodeSRange`；
2. 为每个有效子区间创建一个**子 TopoNode**（`TopoNode(origin, range)`，`IsSubNode()==true`，`OriginNode()` 指回原节点）；
3. 重建子节点之间的子 TopoEdge（前向/左/右），只保留两端都在有效区间内的边。

这样 A\* 看到的是一张"已挖掉黑名单段"的子图，搜索逻辑无需任何特判。`SubTopoGraph::GetSubNodeWithS(node, s)` 返回包含 s 的那个子节点，作为 A\* 的起终点。

### 7.4 临时禁用语义

黑名单是**临时**的——只在本次 `RoutingRequest` 的搜索中生效，不修改磁盘上的 `routing_map.pb.txt`。下一个请求若不带黑名单，图照常完整使用。这天然支持"前方施工临时绕行""某车道被感知模块标记为阻塞"等动态场景：Planning/感知模块把阻塞 lane 通过 `blacklisted_lane` 注入 RoutingRequest，即可让下一次重路由绕开。

---

## 8. Routing 重新规划

Apollo 的"重规划"分两层：Routing 层的全局重路由 与 Planning 层的参考线失效。

### 8.1 触发条件

Routing 是**按需触发**的非周期模块。重路由通常由以下情况触发：

1. **用户主动改终点**：Dreamview/HMI 重新下发 `RoutingRequest`。
2. **Planning 请求重路由**：当 Planning 发现当前参考线无法继续（如偏离路由过远、车道完全阻塞、Routing 响应过期），通过 `RoutingRequest`（带 `is_start_pose_set=true`，首点取车辆当前位姿）重新请求。
3. **被动重路由**：通过 `blacklisted_lane` / `blacklisted_road` 注入临时禁行，迫使 A\* 选新路径。

### 8.2 全量重规划

Apollo 的 Routing **没有增量重路由**机制——每次 `SearchRoute` 都是一次完整 A\*：从起点 waypoint 到终点 waypoint，对每对相邻 waypoint 独立搜索后拼接。`SubTopoGraph` 在每次搜索时根据黑名单重建。所谓"全量"即重新跑一遍 A\*，但因为 TopoGraph 在内存常驻、A\* 在拓扑图（节点数 = 车道数，通常数千）上很快，毫秒级即可完成。

### 8.3 增量重规划

Apollo 标准版**不提供**增量重规划。若车辆已驶过部分路由、中途重路由，新 `RoutingResponse` 会整体覆盖旧路由；Planning 的 `pnc_map` 通过 `UpdateRoutingResponse` 整体替换内部缓存。社区有讨论基于"已驶过段裁剪 + 残余段复用"的增量方案，但官方主线未落地。

### 8.4 历史响应与 TRANSIENT_LOCAL

`RoutingComponent` 的两个 QoS 设计保证重路由的鲁棒性：

- `response_writer_`：`DURABILITY_TRANSIENT_LOCAL`，新订阅者立刻收到最近一条。
- `response_history_writer_` + 1000ms 定时器：周期重发缓存的最新响应，应对 Planning 重启或消息丢失。

这使"重规划"在系统层面表现为：Planning 始终持有一条有效路由，重路由只是用新路由覆盖旧路由，无缝切换。

---

## 9. 与 Reference Line Provider 集成

Routing 的输出并不直接给 Planning 当轨迹，而是经过 **pnc_map + ReferenceLineProvider** 转成平滑参考线。

### 9.1 pnc_map（Planning and Control Map）

`pnc_map` 是 Planning 内部对 HD Map + Routing 响应的封装，核心三功能：

1. **更新路由信息** `PncMap::UpdateRoutingResponse(const routing::RoutingResponse& routing)`：解析 `routing.road()` 与 `routing.routing_request().waypoint()`，缓存到内部成员（路由车道列表、waypoint 序列）。
2. **短期路径段查询** `GetNearestPoint` / `GetRouteSegments`：根据车辆当前定位，从路由里找出**当前可行驶的车道区域**（short-term route segments），即把 `RoadSegment/Passage` 投影到车辆附近的一段。
3. **路径段 → Path**：对每个短期路由段，用其 Lane 的 `central_curve` 拼成一条 `hdmap::Path`，供 ReferenceLineProvider 采样。

### 9.2 ReferenceLineProvider

`ReferenceLineProvider` 在独立线程中周期运行：

1. 从 pnc_map 拿到短期路由段（受 Routing 结果约束）。
2. 对每段 `Path` 采样成 `ReferenceLine`（一组 (x,y,θ,κ) 离散点）。
3. 调用 `ReferenceLineSmoother`（默认 `qp_spline`）平滑，得到连续可微的参考线。
4. 输出 `ReferenceLineInfo` 给 Planning 的 Planner（PublicRoadPlanner / LatticePlanner 等）。

### 9.3 数据流

```
RoutingResponse (road, passage, segment)
        │ PncMap::UpdateRoutingResponse
        ▼
pnc_map 内部: route_lanes_, way_points_, ...
        │ 车辆定位 + GetRouteSegments
        ▼
短期 route segments (vector<hdmap::Path>)
        │ ReferenceLineProvider
        ▼
ReferenceLine (采样 + 平滑)
        │
        ▼
Planning Frame → ReferenceLineInfo → Planner → Trajectory
```

要点：Routing 给的是**车道级拓扑序列**，ReferenceLine 给的是**几何级平滑曲线**。两者解耦使 Routing 可在大尺度拓扑图上快速搜索，而 Planning 在小尺度几何上做平滑与优化。

---

## 10. Apollo 源码要点速览

本节汇总各源文件的关键实现，便于 AuroraDrive 移植对照。

### 10.1 `core/navigator.cc`

- 构造：`GetProtoFromFile(topo_file_path, &graph)` → `graph_->LoadGraph(graph)` → 创建 `BlackListRangeGenerator` 与 `ResultGenerator`。
- `SearchRoute`：ShowRequestInfo → Init → SearchRouteByStrategy → 首尾 s 裁剪 → `GeneratePassageRegion`。
- `SearchRouteByStrategy`：分段 A\*，每段独立 `SubTopoGraph` + `AStarStrategy::Search`，`MergeRoute` 拼接。
- `MergeRoute`：相邻同 Lane 的 `NodeWithRange` 合并区间，校验 `back.EndS() >= node.StartS()`。

### 10.2 `strategy/a_star_strategy.cc`

- `SearchNode` 反转 `<` 使 priority_queue 为小顶堆。
- `HeuristicCost` = 锚点曼哈顿距离。
- 邻居选择：`GetResidualS(from) > min_length_for_lane_change && change_lane_enabled_` → `OutToAllEdge` 否则 `OutToSucEdge`。
- 换道 g 修正：`tentative_g -= (from.Cost + to.Cost)/2`。
- `enter_s_` 维护前向/换道两种更新规则。
- `Reconstruct` → `AdjustLaneChange`（前/后向挑最大区间节点）。

### 10.3 `graph/topo_graph.cc`

- `LoadNodes`：建 TopoNode + `node_index_map_` + `road_node_map_`。
- `LoadEdges`：建 TopoEdge 并挂到两端节点 `AddOutEdge`/`AddInEdge`。
- `GetNode(id)`：O(1) 查 `node_index_map_`。
- `GetNodesByRoadId`：O(1) 查 `road_node_map_`。

### 10.4 `graph/topo_node.cc`（关键片段）

```cpp
void ConvertOutRange(const RepeatedPtrField<CurveRange>& range_vec,
                     double start_s, double end_s,
                     std::vector<NodeSRange>* out_range, int* prefer_index) {
  out_range->clear();
  for (const auto& c_range : range_vec) {
    double s_s = c_range.start().s();
    double e_s = c_range.end().s();
    if (e_s < start_s || s_s > end_s || e_s < s_s) continue;
    s_s = std::max(start_s, s_s);
    e_s = std::min(end_s, e_s);
    out_range->emplace_back(s_s, e_s);
  }
  sort(out_range->begin(), out_range->end());
  // 选最长区间作为 prefer_index
  int max_index = -1; double max_diff = 0.0;
  for (size_t i = 0; i < out_range->size(); ++i)
    if (out_range->at(i).Length() > max_diff) { max_index = i; max_diff = out_range->at(i).Length(); }
  *prefer_index = max_index;
}
```

`TopoNode::Init` 调用 `FindAnchorPoint` 取中心曲线中点作为 `anchor_point_`，并解析 `left_out`/`right_out` 成排序后的 `left_out_sorted_range_` / `right_out_sorted_range_`，记录 `is_left_range_enough_` / `is_right_range_enough_`（是否够长换道）。

### 10.5 `graph/topo_edge.cc`

极薄：构造函数把 `Edge` protobuf 与两端节点绑定，`Type()` 根据 `pb_edge_.direction_type()` 映射到 `TET_FORWARD/LEFT/RIGHT`，`Cost()` 直接返回 `pb_edge_.cost()`。所有代价逻辑都在 `edge_creator.cc` 离线计算时写入 protobuf。

### 10.6 `core/result_generator.cc`

`GeneratePassageRegion` 三步：

1. **`ExtractBasicPassages`**：遍历 A\* 节点序列，按相邻节点间边的类型分组——`FORWARD` 边把 to_node 追加到当前 passage；`LEFT/RIGHT` 边开新 passage 并标记 `change_lane_type`。同一条 passage 内的 Lane 互为左右邻居（可并行换道）。
2. **`ExtendPassages`**：对每个 passage，加入其 Lane 的左右邻居 LaneSegment（只要邻居在图里、未被黑名单完全覆盖），扩展可换道选择。
3. **`CreateRoadSegments`**：按 `road_id` 把 passage 序列聚合成 `RoadSegment`，填 `can_exit`（最后一个 passage 或可驶出时为 true）。

### 10.7 `topo_creator/node_creator.cc` / `edge_creator.cc`

- node：`InitNodeInfo`（lane_id, road_id, left/right_out 区间, central_curve, is_virtual）+ `InitNodeCost`（length×ratio + 转弯惩罚）。
- edge：前向 cost=0；左右 cost = `change_penalty × (area/base)^(-1.5)`（area < base 时放大）。

### 10.8 `common/routing_gflags.cc`

```cpp
DEFINE_string(routing_conf_file, "/apollo/modules/routing/conf/routing_config.pb.txt", ...);
DEFINE_string(routing_node_name, "routing", ...);
DEFINE_double(min_length_for_lane_change, 1.0, ...);    // 换道前最小行驶距离（米）
DEFINE_bool(enable_change_lane_in_result, true, ...);   // 结果中是否含换道
DEFINE_uint32(routing_response_history_interval_ms, 1000, ...);  // 历史响应周期
```

---

## 11. AuroraDrive 迁移建议

### 11.1 现状与问题

AuroraDrive 当前的路径规划：

- **A\* 输出 waypoint 序列**：全局规划给出离散路径点。
- **漫游模式**：在道路尽头时，寻找"方向最一致的下一段道路"继续行驶。

问题：方向最一致策略导致**方向锁定感**——车辆总倾向于直行，在路口/分叉处缺乏多样性，行为可预测且单调，难以体现真实路网拓扑的多样性选择。

### 11.2 改进目标（用户已明确要求）

在道路尽头（当前 Lane 无后继或后继需选择时），用 TopoGraph 查询**所有相连道路**，从中**随机选择**一个方向（而非总是方向最一致者）。这要求 AuroraDrive 自建一张轻量级拓扑图。

### 11.3 AuroraDrive 拓扑图构建方案

借鉴 Apollo，但**大幅简化**（AuroraDrive 不需要车道级换道、黑名单切片、Passage 重构）：

| Apollo | AuroraDrive 简化版 |
|---|---|
| TopoNode = Lane | TopoNode = Road（或 Road Segment） |
| TopoEdge: FORWARD/LEFT/RIGHT 换道 | TopoEdge: 仅"后继"（路口出口方向） |
| 节点代价 = length×ratio + 转弯惩罚 | 节点代价 = length（可选转弯惩罚） |
| 边代价 = change_penalty×ratio | 边代价 = 0（漫游不区分换道） |
| 黑名单 + SubTopoGraph 切片 | 直接跳过黑名单节点 |
| A\* + Reconstruct + AdjustLaneChange | 漫游：随机选后继 |
| RoadSegment/Passage/LaneSegment | waypoint 序列（保持现状） |

### 11.4 C++ 代码框架

以下为 AuroraDrive 拓扑图 + 漫游随机选向的最小实现框架（C++17）：

```cpp
// aurora_topo_graph.h
#pragma once
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <random>

namespace aurora::drive {

// 拓扑节点：一条道路（或道路的一段）
struct TopoNode {
  std::string id;                 // road_id 或 lane_id
  double length = 0.0;            // 道路长度（米）
  double cost = 0.0;              // 通行代价（=length 或加转弯惩罚）
  // 几何中心锚点，用于方向/距离估算
  double anchor_x = 0.0;
  double anchor_y = 0.0;
  // 出边（后继方向）。AuroraDrive 漫游不区分左右换道，仅保留"前向后继"
  std::vector<const TopoEdge*> out_edges;
};

// 拓扑边：路口出口连接
struct TopoEdge {
  const TopoNode* from = nullptr;
  const TopoNode* to   = nullptr;
  double cost = 0.0;              // AuroraDrive 漫游下默认 0
  // 出口方向角（弧度），用于"方向最一致"退化策略或可视化
  double exit_heading = 0.0;
};

class TopoGraph {
 public:
  // 从建图数据装载（可来自 AuroraDrive 自有地图或 Apollo routing_map 转换）
  bool LoadFrom(const std::vector<TopoNodeDef>& nodes,
                const std::vector<TopoEdgeDef>& edges);

  const TopoNode* GetNode(const std::string& id) const;
  const std::vector<std::unique_ptr<TopoNode>>& Nodes() const { return nodes_; }

  // 查询某节点的所有后继方向（道路尽头的所有出口）
  std::vector<const TopoNode*> NextCandidates(const TopoNode* node) const;

 private:
  std::vector<std::unique_ptr<TopoNode>> nodes_;
  std::vector<std::unique_ptr<TopoEdge>> edges_;
  std::unordered_map<std::string, TopoNode*> index_;
};

// 漫游策略：道路尽头随机选向
class RoamingRouter {
 public:
  explicit RoamingRouter(std::shared_ptr<TopoGraph> graph,
                          uint64_t seed = std::random_device{}())
      : graph_(std::move(graph)), rng_(seed) {}

  // 给定当前所在节点，返回下一步要去的节点（随机）
  // 返回 nullptr 表示无后继（死胡同）
  const TopoNode* PickNext(const TopoNode* current) {
    auto candidates = graph_->NextCandidates(current);
    if (candidates.empty()) return nullptr;
    if (candidates.size() == 1) return candidates.front();
    // 用户明确要求：随机选择方向
    std::uniform_int_distribution<size_t> dist(0, candidates.size() - 1);
    return candidates[dist(rng_)];
  }

  // （可选）保留"方向最一致"退化策略作为对照
  const TopoNode* PickMostConsistent(const TopoNode* current, double current_heading) {
    auto candidates = graph_->NextCandidates(current);
    if (candidates.empty()) return nullptr;
    const TopoNode* best = nullptr;
    double best_score = -1.0;
    for (auto* n : candidates) {
      double dh = std::fabs(NormalizeAngle(HeadingTo(current, n) - current_heading));
      double score = 1.0 - dh / M_PI;        // 越一致 score 越高
      if (score > best_score) { best_score = score; best = n; }
    }
    return best;
  }

 private:
  static double NormalizeAngle(double a) {
    while (a >  M_PI) a -= 2 * M_PI;
    while (a < -M_PI) a += 2 * M_PI;
    return a;
  }
  double HeadingTo(const TopoNode* from, const TopoNode* to) const {
    return std::atan2(to->anchor_y - from->anchor_y,
                      to->anchor_x - from->anchor_x);
  }
  std::shared_ptr<TopoGraph> graph_;
  std::mt19937_64 rng_;
};

}  // namespace aurora::drive
```

```cpp
// aurora_topo_graph.cc
#include "aurora_topo_graph.h"
namespace aurora::drive {

bool TopoGraph::LoadFrom(const std::vector<TopoNodeDef>& nodes,
                         const std::vector<TopoEdgeDef>& edges) {
  index_.clear(); nodes_.clear(); edges_.clear();
  for (const auto& nd : nodes) {
    auto n = std::make_unique<TopoNode>();
    n->id = nd.id; n->length = nd.length; n->cost = nd.length;
    n->anchor_x = nd.anchor_x; n->anchor_y = nd.anchor_y;
    TopoNode* raw = n.get();
    index_[n->id] = raw;
    nodes_.push_back(std::move(n));
  }
  for (const auto& ed : edges) {
    auto it_from = index_.find(ed.from_id);
    auto it_to   = index_.find(ed.to_id);
    if (it_from == index_.end() || it_to == index_.end()) continue;  // 跳过悬空边
    auto e = std::make_unique<TopoEdge>();
    e->from = it_from->second; e->to = it_to->second;
    e->cost = 0.0; e->exit_heading = ed.exit_heading;
    it_from->second->out_edges.push_back(e.get());
    edges_.push_back(std::move(e));
  }
  return true;
}

const TopoNode* TopoGraph::GetNode(const std::string& id) const {
  auto it = index_.find(id);
  return it == index_.end() ? nullptr : it->second;
}

std::vector<const TopoNode*>
TopoGraph::NextCandidates(const TopoNode* node) const {
  std::vector<const TopoNode*> out;
  if (!node) return out;
  out.reserve(node->out_edges.size());
  for (auto* e : node->out_edges) out.push_back(e->to);
  return out;
}

}  // namespace aurora::drive
```

### 11.5 与 AuroraDrive 现有 A\* waypoint 序列的衔接

1. **建图阶段**：把 AuroraDrive 地图（或转换 Apollo `routing_map.pb.txt`）解析为 `TopoNodeDef` / `TopoEdgeDef`，装载成 `TopoGraph`。节点粒度建议为 **Road**（而非 Lane），边为路口出口。
2. **全局规划阶段**：保持现状——A\* 在拓扑图上跑出 waypoint 序列（可继续用 AuroraDrive 现有 A\*，只需把搜索图换成 `TopoGraph`）。
3. **漫游模式改造**：当车辆到达道路尽头（当前节点无 A\* 指定后继，或 A\* 路径已走完），调用 `RoamingRouter::PickNext(current)`：

   ```cpp
   const TopoNode* next = roaming_router_.PickNext(current_node);
   if (!next) { /* 真正死胡同：掉头或停车 */ }
   else { /* 把 next 作为新目标，生成到 next.anchor 的 waypoint */ }
   ```

   这彻底消除"方向锁定感"——每个分叉都以均匀概率选向，行为多样性显著提升。
4. **可选加权随机**：若希望"略偏向直行但仍多样"，把均匀分布换成 softmax 权重：

   ```cpp
   // 权重 = exp(beta * cos(Δheading))，beta 越大越偏向直行
   std::vector<double> w;
   for (auto* n : candidates)
     w.push_back(std::exp(beta_ * std::cos(HeadingTo(current, n) - current_heading)));
   std::discrete_distribution<size_t> dist(w.begin(), w.end());
   return candidates[dist(rng_)];
   ```

   `beta=0` 即完全随机；`beta→∞` 退化为方向最一致。建议 `beta=1.0` 起步调参。

### 11.6 黑名单支持（可选）

若 AuroraDrive 后续要支持"施工/阻塞临时禁行"，可直接在 `TopoGraph` 上加一个 `BlackList` 集合，`NextCandidates` 过滤掉黑名单节点：

```cpp
std::vector<const TopoNode*> NextCandidates(const TopoNode* node) const {
  std::vector<const TopoNode*> out;
  for (auto* e : node->out_edges)
    if (!blacklist_.count(e->to->id)) out.push_back(e->to);
  return out;
}
```

这复刻了 Apollo `blacklisted_road` 的语义，但无需 SubTopoGraph 切片——因为 AuroraDrive 节点是 Road 粒度，黑名单整条 road 即可。

### 11.7 迁移工作量评估

| 模块 | 工作量 | 说明 |
|---|---|---|
| TopoGraph + TopoNode/Edge | 小 | 上文框架可直接用，约 200 行 |
| 建图数据源对接 | 中 | 取决于 AuroraDrive 地图格式；若复用 Apollo routing_map 则需 proto 解析 |
| RoamingRouter 接入 | 小 | 在漫游分支替换"方向最一致"为 `PickNext` |
| A\* 适配（可选） | 中 | 若希望全局规划也用 TopoGraph，需把现有 A\* 的邻接查询换成 `NextCandidates` |
| 黑名单（可选） | 小 | `NextCandidates` 加过滤即可 |
| 测试与调参 | 中 | 随机种子、加权 beta、死胡同兜底策略 |

整体可在 1–2 周内完成核心迁移，关键收益是**消除漫游方向锁定感**并**为后续车道级规划留出扩展空间**。

---

## 12. 关键源码索引（Apollo master）

| 文件 | 路径 |
|---|---|
| RoutingRequest/Response | `modules/common_msgs/routing_msgs/routing.proto` |
| LaneWaypoint/LaneSegment/Passage/RoadSegment | `modules/common_msgs/routing_msgs/geometry.proto` |
| ParkingInfo/Landmark/POI | `modules/common_msgs/routing_msgs/poi.proto` |
| Node/Edge/Graph | `modules/routing/proto/topo_graph.proto` |
| RoutingConfig | `modules/routing/proto/routing_config.proto` |
| RoutingComponent | `modules/routing/routing_component.cc` |
| Routing 类 | `modules/routing/routing.h` / `.cc` |
| Navigator | `modules/routing/core/navigator.h` / `.cc` |
| A\* 策略 | `modules/routing/strategy/a_star_strategy.h` / `.cc` |
| TopoGraph | `modules/routing/graph/topo_graph.h` / `.cc` |
| TopoNode / TopoEdge | `modules/routing/graph/topo_node.h` / `.cc` |
| SubTopoGraph | `modules/routing/graph/sub_topo_graph.h` / `.cc` |
| NodeSRange / TopoRangeManager | `modules/routing/graph/topo_range.h` / `.cc` |
| BlackListRangeGenerator | `modules/routing/core/black_list_range_generator.h` / `.cc` |
| ResultGenerator | `modules/routing/core/result_generator.h` / `.cc` |
| NodeCreator | `modules/routing/topo_creator/node_creator.h` / `.cc` |
| EdgeCreator | `modules/routing/topo_creator/edge_creator.h` / `.cc` |
| gflags | `modules/routing/common/routing_gflags.cc` |

---

## 13. 小结

Apollo Routing 的核心思想是：**把高精地图离线编译成轻量拓扑图（TopoGraph），运行时在拓扑图上跑 A\***，再用 `SubTopoGraph` 处理黑名单切片，最后通过 `ResultGenerator` 把节点序列重构成 `RoadSegment/Passage/LaneSegment` 三级结构交给 Planning。其 A\* 的工程细节值得借鉴：

- 优先队列 + 哈希集双结构 OPEN/CLOSED；
- 锚点曼哈顿距离启发式；
- 剩余距离门控换道（`min_length_for_lane_change`）；
- 换道 g 值修正与 `enter_s` 比例换算；
- `AdjustLaneChange` 后处理挑最大换道区间；
- QoS `TRANSIENT_LOCAL` + 历史定时器保证 Planning 鲁棒获取路由。

对 AuroraDrive 而言，**拓扑图 + 随机选向**是最小可行的改进路径：用 Road 粒度的 `TopoGraph` 替换"方向最一致"启发，即可消除漫游方向锁定感，且为未来车道级规划、黑名单、A\* 全局规划预留扩展空间。

---

> 实际工具调用次数：55（WebSearch 6 次 + WebFetch 38 次，其中 11 次失败重试；Read 4 次；RunCommand 1 次；Write 1 次）
> 报告字数：约 6800 字（中文，含代码注释）
