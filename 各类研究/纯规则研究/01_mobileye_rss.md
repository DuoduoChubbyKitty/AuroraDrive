# Mobileye RSS（Responsibility-Sensitive Safety）模型深度研究

> 研究主题：Mobileye 责任敏感安全模型
> 研究方法：WebSearch + WebFetch 深度检索 Mobileye 官方文档、arXiv 原始论文、Intel 开源实现、行业解析
> 关联项目：AuroraDrive 安全架构迁移（FallbackDetector + SafetyEnvelope → RSS 风格安全监督）

---

## 1. RSS 概述

### 1.1 模型定位

RSS（Responsibility-Sensitive Safety，责任敏感安全模型）是 Mobileye（2017 年被英特尔以 153 亿美元收购）于 **2017 年** 提出的一套**白盒、可解释、可数学验证的形式化安全模型**。其核心目的是：把人类驾驶员对"安全"与"责任"的直觉常识，**翻译成一组精确的数学公式与责任判定规则**，从而让自动驾驶系统在任何场景下都能判断自身是否处于"安全状态"，并明确一旦发生事故，自身是否应当承担责任。

Mobileye CTO 阿姆农·沙舒瓦（Amnon Shashua）将其类比为自动驾驶界的"阿西莫夫机器人三定律"——它不是用来"开得更好"，而是用来"永远不主动造成事故，并对他人不当行为做出合理反应"。英特尔官方把 RSS 定位为 **nominal safety（名义安全 / 系统设计层安全）**，而非 functional safety（功能安全）。功能安全解决的是"系统有没有故障、故障后能否兜底"，而 RSS 解决的是"在系统正常工作时，设计本身是否会带来安全事故隐患"。这是它与传统冗余/备份设计本质区别所在。

### 1.2 发表与论文

RSS 的奠基性论文为：

- **标题**：《On a Formal Model of Safe and Scalable Self-Driving Cars》（论安全和可大规模部署自动驾驶汽车的形式化模型）
- **作者**：Shai Shalev-Shwartz、Shaked Shammah、Amnon Shashua
- **arXiv 编号**：[arXiv:1708.06374](https://arxiv.org/abs/1708.06374)
- **首次提交**：2017-08-21，最终修订 v6：2018-10-27，发表于 RSS 2017（Robotics: Science and Systems）
- **学科分类**：cs.RO / cs.AI / stat.ML

> 说明：任务书提及的"A Machine Learning-Based Approach for Automated Driving Safety"并非 RSS 的正式标题，RSS 的官方论文即上述《On a Formal Model of Safe and Scalable Self-Driving Cars》。论文明确自述：第一部分提出一个**白盒、可解释的数学安全保证模型 RSS**；第二部分描述一套符合该安全保证要求且可大规模扩展到数百万辆车的系统设计。论文强调两个被行业忽视的关键参数——**安全保证标准化**与**可扩展性（scalability）**。

### 1.3 与端到端 / 统计模型的根本对立

Mobileye 认为，单纯依赖"里程数堆叠"的统计思维存在两个致命缺陷：

1. **不透明**：装满数据的"黑匣子"无法在事故后解释决策原因，监管和公众无法接受；
2. **不可证伪**：只有当统计量级远优于人类（人类事故率约 10⁻⁶，行业普遍认为自动驾驶需达到 10⁻⁹ 航空级）才有效，而所需数据量极其庞大。

RSS 选择相反路径——**每一步都经过数学验证、完全开放透明**，事故后可清晰复盘"为什么如此决策"。

---

## 2. RSS 核心思想

### 2.1 责任敏感安全

"责任敏感"的含义是：把人类交通法规中模糊的"注意义务（duty of care）"转化为**可测量、可计算**的参数与公式。Mobileye 从三个维度重新定义"保持注意"：

| 维度 | 含义 | 失败案例 |
|------|------|----------|
| **合理性（Reasonableness）** | 定义必须符合人类对"保持注意"的常识判定，而非天方夜谭 | —— |
| **有效性（Effectiveness）** | 定义在真实世界中可落地（如"变道时其他车不许变速"在中国/以色列不可行，无效） | 听似谨慎但无法执行 |
| **可验证性（Verifiability）** | 定义可与机器结合验证，并证明无蝴蝶效应（小无心之举经系统放大导致车祸） | 无法验证的定义无用 |

### 2.2 安全状态（Safe State）

RSS 的核心概念是**安全状态**：在此状态下，**无论其他车辆如何操作，自动驾驶汽车都不可能引发事故**。只要车辆始终处于安全状态，它就"不可能成为事故的责任方"。

### 2.3 两大公理（Axioms）

RSS 建立在两条不可违背的铁律之上：

1. **不要成为事故的原因（Do not cause an accident / blame）**：自动驾驶汽车永不因自身原因引发碰撞，只可能被卷入事故而非肇责。
2. **不要疏忽（Do not be negligent / inattentive）**：当潜在风险由他人造成时，自动驾驶汽车必须做出"合理的反应"（Proper Response），避免本可避免的事故，不扩大事故后果。

### 2.4 RSS 四原则（常识形式化）

Mobileye 把人类驾驶常识归纳为四条可计算原则：

1. 与前车保持安全距离（追尾永远是后车责任）；
2. 不要危险变道/加塞（不要"切入"他人安全空间）；
3. 路权是被让出的，不是抢来的（合理使用路权，不滥用）；
4. 在视线受限区域（行人可能从遮挡后闯入）要谨慎保守驾驶。

### 2.5 与端到端模型的对比

| 维度 | RSS（规则化） | 端到端 / 统计模型 |
|------|----------------|---------------------|
| 形式 | 白盒数学公式 | 黑盒神经网络 |
| 可解释性 | 每一步可数学验证、可向监管解释 | 事后难以归因 |
| 安全保证 | 形式化"不可能肇责" | 统计概率（里程数驱动） |
| 数据需求 | 极少（参数化） | 海量（百万英里） |
| 失效模式 | 假阳性（不该刹而刹，可调参） | 假阴性（该刹未刹，致命） |
| 扩展性 | 可规模化到百万辆车 | 受限于数据采集成本 |

Mobileye 称：基于 RSS 已收集 2 亿公里实际行驶数据，将假阳性出现概率降至万分之 2.5（每 5 万公里一次），并在 10 万次路测模拟中以 10Hz 频率响应，零事故。

---

## 3. RSS 安全距离

RSS 用"最恶劣情况下的最小可避碰距离"定义安全距离。**最恶劣情况假设**：前车以最大刹车加速度急刹，后车在反应时间 ρ 内仍以最大加速度加速（最坏意图假设），反应结束后以最小刹车加速度刹车，直至危险解除。

### 3.1 纵向安全距离

#### 3.1.1 同向行驶（定义 1）

后车 r 与前车 f 同向，最小纵向安全距离：

```
d_min^long = max{ 0,
    v_r · ρ + ½ · a_{max,accel} · ρ²
    + (v_r + ρ · a_{max,accel})² / (2 · a_{min,brake})
    − v_f² / (2 · a_{max,brake})
}
```

**各项物理含义**：

- `v_r · ρ`：后车在反应时间 ρ 内以当前速度匀速行驶的距离；
- `½ · a_{max,accel} · ρ²`：后车在反应时间内仍以最大加速度加速走过的距离（最坏意图假设——RSS 不信任任何车辆的意图，假设其在反应时间内仍猛踩油门）；
- `(v_r + ρ·a_{max,accel})² / (2·a_{min,brake})`：后车反应结束后以"最小合规刹车"a_{min,brake}刹停的距离；
- `v_f² / (2·a_{max,brake})`：前车以"最大可能刹车"a_{max,brake}急刹所缩短的距离（前车停得更早，安全距离可抵减）。

#### 3.1.2 对向行驶（定义 2）

两车相向，双方都需刹停：

```
d_min^long = (v_1 + v_2) · ρ + ½ · a_{max,accel} · ρ²
    + (v_1 + ρ · a_{max,accel})² / (2 · a_{min,brake})
    + (v_2 + ρ · a_{max,accel})² / (2 · a_{min,brake})
```

对向场景无"前车"可抵减，故两车刹停距离相加。

#### 3.1.3 错向行驶（同车道逆行，定义 3）

合法车辆需主动避让，使用更宽松的 `a_{brake,min,correct}`（默认 3 m/s²），给合法方更长的反应余地，惩罚违规方。

### 3.2 横向安全距离

横向安全距离定义两车并排时不发生侧向碰撞的临界距离，引入波动余量 μ（δ^lat_min）：

```
d_min^lat = μ
    + [ v^lat · ρ + ½ · a^{lat}_{max,accel} · ρ²
        + (v^lat + ρ · a^{lat}_{max,accel})² / (2 · a^{lat}_{min,brake}) ]   （本车侧）
    + [ 对侧同形式项 ]   （对侧车，对称处理）
```

其中 `v^lat` 为横向速度，`a^{lat}_{max,accel}` 为最大横向加速度，`a^{lat}_{min,brake}` 为最小合规横向刹车减速度。**关键工程约束**：为使两辆 2m 宽车在 3m 车道（边距 0.5m）内能并行通过，必须令横向刹车减速度大于横向加速度（默认 0.8 vs 0.2 m/s²），否则变道需 ~8 秒、不可接受。

### 3.3 关键参数（Intel ad-rss-lib 官方默认值）

Intel 开源实现 ad-rss-lib 中 RSS 参数为可配置项，官方建议初值如下（依据《RSS paper》与德国驾校经验值）：

| 参数 | 符号 | 默认值 | 说明 |
|------|------|--------|------|
| 自车反应时间 | ρ_ego | **1 s** | AV 比人快 |
| 他车反应时间 | ρ_other | **2 s** | 安全假设所有他车由人驾驶 |
| 最大加速度 | α_accel,max | **3.5 m/s²** | 反应时间内最坏加速假设 |
| 最小合规刹车（纵向） | α_brake,min | **4 m/s²** | 德国驾校经验，正常人不会超此 |
| 最大可能刹车（纵向） | α_brake,max | **8 m/s²** | 现代车可达 12，但限制更稳 |
| 纵向纠偏刹车 | α_brake,min,correct | **3 m/s²** | 对向/逆行场景合法方 |
| 最小横向刹车 | α^lat_brake,min | **0.8 m/s²** | 保证并行通过 |
| 最大横向加速度 | α^lat_accel,max | **0.2 m/s²** | 保证变道可接受时长 |
| 横向波动余量 | δ^lat_min | **10 cm** | 仅覆盖微小抖动 |

**工程启示**：在 50 km/h 城市速度、α_brake,min=4 / α_brake,max=8 / ρ=2s 下，所需安全距离约 40m；若允许反应时间内加速 4 m/s²，距离翻倍到 ~80m，远超德国"速度/2"（25m）惯例。因此 ad-rss-lib 建议引入"限速约束"（车辆不允许加速超过当前限速）以降低安全距离，使密集车流可行。

---

## 4. RSS 场景

RSS 把多智能体驾驶情境形式化为 **"星座（Constellation）"**——自车与每个周围物体配对，逐一计算纵向与横向冲突。星座类型分三大类（来自 ad-rss-lib 官方实现）：

### 4.1 RSS 场景表

| 场景类型 | 子类型 | 路权/责任 | 安全距离公式 | Proper Response（合理反应） |
|----------|--------|-----------|--------------|------------------------------|
| **同向行驶（Same Direction）** | 自车在后 | 后车负责保持安全距离 | 定义 1（同向 d_min^long） | 自车以 α_brake,min 纵向刹车 |
| | 自车在前 | 前车无纵向责任 | 同上 | 无纵向反应（他车责任） |
| **对向行驶（Opposite Direction）** | 同车道相向 | 双方共同刹车 | 定义 2（对向 d_min^long） | 双方各以 α_brake,min 刹车 |
| | 错向（逆行） | 合法方 α_brake,min,correct | 定义 3 | 合法方用更宽松刹车避让 |
| **横向冲突（Lateral）** | 并行/变道 | 横向安全距离决定 | d_min^lat | 横向速度归零方向刹车，向安全侧移动 |
| **路口（Intersection）** | 自车有优先权 | 他车让行 | 路口 d_min | 自车保持，他车刹车 |
| | 他车有优先权 | 自车让行 | 路口 d_min | 自车刹车让行 |
| | 同等优先权 | 双方都让 | 路口 d_min | 双方都刹车 |
| **非结构化（Unstructured）** | 停车场等 | VRU 特殊保护 | Unstructured 计算 | 谨慎保守行为 |

### 4.2 场景补充说明

- **同向**：对应论文定义 1/3/4，是追尾场景的形式化。RSS 保证"后车永远能刹停，即便前车 8 m/s² 急刹"。
- **对向**：对应定义 2/3/4，覆盖借道超车、逆行等。
- **横向**：定义 5，处理并线、变道、并行。横向安全距离要求"变道至少耗时 2ρ"。
- **路口**：基于路权（priority），无路权方必须能在自身反应时间内停车；同等优先权时双方都保守刹车。
- **非结构化**：停车场、施工区等无车道线区域，对行人（VRU，Vulnerable Road User）采用更保守的特殊处理，因为行人路径不可预测。
- **遮挡场景**：RSS 单独处理"视线被遮挡"——当行人可能从遮挡物后闯入时，要求车辆在"合理谨慎"范围内降速，这是公理 2（不疏忽）的具体化。

---

## 5. RSS 决策

### 5.1 三个核心问题

沙舒瓦指出 RSS 数学模型解决三个问题：①什么是危险情况；②什么是正确的反应；③事故责任方是谁。

### 5.2 Danger Threshold（危险阈值）

车辆"必须做出反应"的特定时刻称为**危险阈值（Danger Threshold）**。在此之前车辆处于安全状态；一旦安全距离被打破（实际距离 < d_min），车辆进入**危险状态（Dangerous Situation）**，必须立即执行 Proper Response。

### 5.3 Proper Response（合理反应）

RSS 的精髓在于：**它不替代规划，而是给规划施加"加速度约束"**。当处于危险状态时，RSS 对纵向/横向加速度施加限制，把车辆拉回安全状态。ad-rss-lib 官方对 Proper Response 的实现要点：

1. RSS 持续监测当前环境状态，判断自车是否安全；
2. 安全状态定义为：即使自车在反应时间内以最大加速度运动（最坏假设），也无法与他物碰撞——**RSS 不参考驾驶策略输出**，而用最坏反应时间/加速度等保证"驾驶策略任何合法动作都无法把车带入不安全状态"；
3. 危险状态时，RSS 强制纵向/横向加速度限制；但驾驶策略仍可在 RSS 限制内用更精细路径规划化解险情（RSS 只有基础信息，策略可用更多信息）；
4. 纵向/横向冲突分别处理，响应不同；
5. 区分普通道路、路口、非结构化道路；
6. 物体分为 VRU（行人）与普通动态物体，前者需特殊安全考量。

### 5.4 合理行为 vs 不合理行为

RSS 把"责任"形式化为"行为是否在合理范围内"：

- **合理行为（Reasonable）**：保持在安全距离内、对危险阈值做 Proper Response。此类行为下发生事故，**自车不可被指责（cannot be blamed）**——这正是 RSS 的核心保证。
- **不合理行为（Unreasonable）**：进入危险状态却未做 Proper Response（疏忽），或主动打破他人安全空间（肇责）。事故责任归于不合理方。

> 关键洞察：RSS 不保证"零碰撞"——当他人完全不可预测的 erratic 行为发生时，碰撞可能无法避免。RSS 保证的是**"自车不可被指责"**，即只要自车遵守 RSS，事故责任必不在自车。这是其相对端到端"零事故"承诺的诚实之处。

### 5.5 RSS 的边界（不做什么）

ad-rss-lib 官方明确 RSS **不是**：

- 解决"如何获得足够好的传感器数据"——它只定义数据如何使用（间接提出传感器需求）；
- 在他人完全 erratic 驾驶时避免碰撞——它只保证自车不被指责；
- 驾驶策略本身——它是叠加在规划之上的**安全约束层/安全监督层**。

---

## 6. RSS 与 Mobileye SuperVision / Chauffeur / Drive

Mobileye 当前的量产产品矩阵分三层，RSS 作为统一的安全底座贯穿其中：

| 平台 | 等级 | 传感器 | 量产节奏 | 代表车型 | RSS 角色 |
|------|------|--------|----------|----------|----------|
| **Mobileye SuperVision™** | L2+ | 纯视觉（摄像头为主，EyeQ5H） | 2021 年首发量产 | 极氪 001（全球首发）、宝马 iX | 安全监督层 |
| **Mobileye Chauffeur™** | L2++/可脱眼脱手 | 摄像头 + 激光雷达 | 2025 年底量产 | 红旗（中国一汽） | 安全冗余 + RSS |
| **Mobileye Drive™** | L4 端到端 | 多传感融合 | 2026 年起（17 款车型订单） | 蔚来 ES8（在美底特律测试） | RSS + 形式化安全保证 |

**SuperVision 集成 RSS**：SuperVision 把摄像头子系统"降维"为 L2+ 方案，RSS 作为"安全监督层"持续检查规划输出的轨迹是否在安全包络内。Mobileye 与中国一汽合作，红旗 2024 年底量产 SuperVision 车型，2025 年底量产 Chauffeur；与极氪深化合作将新技术融入下一代车型；Drive 平台已获某西方主流车企 17 款车型量产订单，2026 年起陆续落地。

**Drive 与 Chauffeur 的关系**：Chauffeur 是 SuperVision 的能力上探（仍需驾驶员监督），Drive 是全无人 L4（彻底脱手脱眼脱脑）。Mobileye Drive 已于 2026 年 2 月集成 Elektrobit 的 EB corbos Linux for Safety Applications（符合功能安全标准的 Linux），并获 TÜV 南德（TÜV SÜD）对其面向 SAE L4 级自动驾驶系统安全方法的认证——RSS 是该认证的形式化安全基础。

---

## 7. RSS 开源实现

### 7.1 Intel ad-rss-lib（C++ 官方实现）

- **仓库**：[github.com/intel/ad-rss-lib](https://github.com/intel/ad-rss-lib)
- **语言**：C++（含 Python 绑定）
- **状态**：**Public archive（已归档，2025-08-08 起停止维护）**——Intel 声明不再提供开发或支持，补丁不再接受，建议社区自行 fork
- **设计基础**：严格依据 arXiv:1708.06374 论文
- **架构**：接收（后处理的）传感器物体列表 → 为每个物体与自车配对生成"星座（Constellation）"→ 对所有星座执行 RSS 检查并计算 Proper Response → 合并为一个总体响应 → 输出纵向/横向**加速度限制**（actuator command restrictions）

**核心特性**：

- 输入是物体列表，输出是加速度约束（不直接输出驾驶指令，强制由上层转换为实车控制）；
- 覆盖多车道道路与路口；
- 自动化测试覆盖：方法 100%、分支 80%，外加静态代码分析；
- 支持地图集成（ad_rss_map_integration），用 OpenDRIVE 格式地图；
- 参数全部可配置（非硬编码）。

### 7.2 生态集成

| 项目 | 集成方式 |
|------|----------|
| **CARLA** | 提供原生 RSS sensor，可在仿真器中验证 RSS 模型行为 |
| **百度 Apollo** | 作为 planning 的 `RSS_DECIDER` task 集成（`modules/planning/tasks/deciders/rss_decider`），依赖 `@ad_rss_lib//` |
| **OpenDRIVE** | 用 OpenDRIVE 地图进行环境建模与路径规划 |

### 7.3 Python 实现

ad-rss-lib 通过 Python 绑定提供 Python 接口（PyPI 包），便于研究社区与 CARLA/Jupyter 等结合做参数实验与可视化。

---

## 8. RSS 与 Apollo 规则对比

### 8.1 Apollo 的规则体系

Apollo 规划采用 **PublicRoadPlanner + Scenario/Stage/Task** 架构，规则散布在多个层级：

- **traffic_rules/**：交规插件（红绿灯、人行道、停止线、减速带）生成 virtual obstacle；
- **deciders/**：决策器，包括 `RULE_BASED_STOP_DECIDER`（依据交规决策停车点）、`PATH_DECIDER`（nudge/overtake/ignore）、`PATH_ASSESSMENT_DECIDER`（路径安全性评估）；
- **RSS_DECIDER**：调用 ad-rss-lib 做安全检查的专用 task；
- **optimizers/**：路径/速度优化（PIECEWISE_JERK_PATH_OPTIMIZER、DP/QP 速度规划）。

Apollo 的"rule-based"是**面向驾驶行为与交规**的工程化规则集，规则与优化器耦合，安全边界隐式存在于代价函数（如安全距离内/外分级 cost）与 `rule_based_stop_decider` 中。

### 8.2 RSS 与 Apollo rule-based planner 对比

| 维度 | RSS | Apollo rule-based planner |
|------|-----|---------------------------|
| **定位** | 纯安全监督层（加速度约束） | 完整规划栈（路径+速度+决策） |
| **形式化程度** | 数学公式可证明、形式化 | 工程化规则，无形式化证明 |
| **责任判定** | 显式 blame 概念，保证不肇责 | 隐式（cost/stop decider） |
| **安全距离** | 最坏情况闭式公式（d_min） | 安全距离作为 cost 分级参数 |
| **参数化** | 物理参数（ρ、a_min/max） | 调参 flag/配置文件 |
| **可验证性** | 数学可验证、IEEE 2846 标准化 | 需场景测试验证 |
| **适用场景** | 任意多智能体场景的安全底线 | 结构化道路全场景规划 |
| **关系** | Apollo 用 ad-rss-lib 作为 RSS_DECIDER | RSS_DECIDER 是 Apollo 一个可选 task |
| **失败模式** | 假阳性（过度保守刹车） | 依赖调参，可能假阴性 |

**关键差异**：RSS 是"纯安全底线"——它不规划轨迹，只保证任何规划输出在安全包络内；Apollo rule-based 是"完整规划"——它直接产生可执行轨迹，安全是其中一环。二者非互斥：Apollo 把 RSS 作为 `RSS_DECIDER` 集成，本质是"用 RSS 给 Apollo 规划加一层形式化安全监督"。Apollo 10.0 引入 ADFM 大模型向端到端演进，但结构化道路仍以 PublicRoadPlanner 为安全兜底——RSS 思想与之互补。

---

## 9. RSS 与形式化验证

### 9.1 RSS 的数学证明

RSS 论文本身即一篇"形式化模型"论文，其安全保证来自**最坏情况假设**的不变式：

> 若自车处于安全状态（满足 d_min），则无论自车在反应时间内如何加速、他车如何刹车，自车总能在反应结束后以 α_brake,min 停下且不与他车碰撞。

这是基于物理运动学方程的**演绎证明**，而非统计归纳。ad-rss-lib 官方 Overview 把 RSS 总结为 7 条，其中第 2 条明确："RSS 用最坏反应时间/加速度假设，保证驾驶策略的任何合法动作都无法把车带入不安全状态"——即**安全状态是关于驾驶策略输出的不变式（invariant）**。

### 9.2 与 IEEE 2846 标准化

RSS 已被推向标准化：**IEEE 2846**（《Assuring Acceptable Behavior of Automated Vehicles》）标准即基于英特尔提出的 RSS 模型，由英特尔资深首席工程师 Jack Weast 担任工作组负责人。该标准试图把"自动驾驶可接受行为"用形式化、可验证方式定义，RSS 是其学术基础。Mobileye 还与中、美、以监管机构积极沟通，推动 RSS 成为监管认可的"注意义务"定义。

### 9.3 与 CBMC 的关系

RSS 的"形式化"分两层：

1. **模型层（论文）**：运动学演绎证明，安全状态不变式——这部分用纸笔/定理证明器即可。
2. **代码层（ad-rss-lib）**：C++ 实现是否忠实实现公式——这部分需要**软件形式化验证**，典型工具是 **CBMC（C Bounded Model Checker）**，通过有界模型检查穷举 C 代码所有执行路径，验证无数组越界、整数溢出、空指针等缺陷，保证实现与数学模型等价。

因此 RSS 与 CBMC 的关系是：**RSS 提供可形式化的数学模型（待验证目标），CBMC 是验证其 C++ 实现（ad-rss-lib）正确性的工具链一环**。ad-rss-lib 项目声明其代码质量由自动化测试（方法 100%/分支 80%）+ 静态代码分析保证，CBMC 类有界模型检查可作为其静态分析的补充，进入更高级别安全认证（如 ISO 26262 ASIL-D）。这正是本项目后续章节（04_formal_verification.md / 05_cbmc.md）的研究衔接点。

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 现状

根据 `全文合并_AuroraDrive技术白皮书.md`，AuroraDrive 当前的安全设计是**自定义的"多阶段 fallback + 工程兜底"**模式，而非形式化安全模型：

- **纵向无闭环 PID**：仿真模式的专家控制器有基于前车距离的闭环，但实车辅助模式（AUTO 开关）的纵向控制是"盲踩油门"，存在安全风险，故默认关闭、需 3 秒倒计时手动开启；
- **安全阀依赖人工**：`assist_emergency()` 依赖用户主动触发或帧过期/车道丢失自动暂停（`assist_runner.py`），**无全自动兜底**；
- **控制层四阶段 fallback**：Pure Pursuit 控制器 `controller.h` 用"最近道路点 → 取道路点 → 前方点偏好 → 虚拟点兜底"四阶段保证始终有可执行动作，但这是"不崩溃"兜底，非"不碰撞"兜底；
- **IDM 跟车**：用平方项 `s*/s` 提供"接近越近、刹车越猛"的非线性防撞屏障，`s0`=2m 静止净距、车时距 T=1.5s，是"两秒法则"的工程化，但**无形式化安全保证**；
- **已知缺陷**：`curvature_` 恒 0 导致弯道限速被旁路，高速过急弯仅靠"大转向角降速"被动兜底（仅到 15km/h），急弯高速仍有风险。

**核心问题**：AuroraDrive 有"防御性驾驶"的工程直觉（IDM、min 合成、多阶段 fallback），但缺乏 RSS 式的**形式化安全状态定义与责任边界**，无法回答"当前是否安全""事故责任归谁"。

### 10.2 借鉴 RSS 安全距离公式

建议把 AuroraDrive 的"经验安全距离"升级为 RSS 风格闭式公式：

```python
# AuroraDrive RSS 风格纵向安全距离（同向）
def d_min_long(v_ego, v_lead, params):
    rho = params.rho_ego          # 默认 1.0s（AV 比人快）
    a_acc = params.a_max_accel    # 默认 3.5 m/s²（最坏加速假设）
    a_min = params.a_min_brake    # 默认 4.0 m/s²（合规刹车）
    a_max = params.a_max_brake    # 默认 8.0 m/s²（前车最坏急刹）
    term_acc = v_ego * rho + 0.5 * a_acc * rho**2
    term_brake = (v_ego + rho * a_acc)**2 / (2 * a_min)
    term_lead = v_lead**2 / (2 * a_max)
    return max(0.0, term_acc + term_brake - term_lead)

# 横向安全距离
def d_min_lat(v_lat_ego, v_lat_other, params):
    mu = params.delta_lat_min     # 默认 0.1m 波动余量
    rho = params.rho_other        # 默认 2.0s
    a_acc = params.a_lat_max_accel      # 0.2 m/s²
    a_min = params.a_lat_min_brake      # 0.8 m/s²
    def term(v):  # 单侧最坏距离
        return v*rho + 0.5*a_acc*rho**2 + (v+rho*a_acc)**2/(2*a_min)
    return mu + term(abs(v_lat_ego)) + term(abs(v_lat_other))
```

这可直接替代 IDM 的 `s*` 期望间距，作为"安全状态"的硬判定：**实际间距 ≥ d_min ⇒ 安全；< d_min ⇒ 危险状态，触发 Proper Response**。

### 10.3 借鉴 RSS Proper Response

把 AuroraDrive 的"assist_emergency 人工触发"升级为 RSS 式"加速度约束监督层"：

```python
# AuroraDrive RSS 风格 Proper Response（安全监督层）
def proper_response(state, planning_cmd):
    # state: 各物体的距离/速度/方向; planning_cmd: 规划输出的加速度
    long_safe = all(d >= d_min_long(...) for obj in state.objects_longitudinal)
    lat_safe  = all(d >= d_min_lat(...)  for obj in state.objects_lateral)
    if long_safe and lat_safe:
        return planning_cmd          # 安全状态，放行规划输出
    # 危险状态：施加加速度约束，把车拉回安全状态
    constrained = constrain_accel(planning_cmd,
                                  a_long_min_brake=params.a_min_brake,
                                  a_lat_safe_dir=safe_lateral_dir(state))
    return constrained              # 规划仍可在 RSS 限制内做更精细避让
```

**关键设计原则（取自 RSS 公理）**：
1. **不参考规划意图**——安全监督用最坏假设（反应时间内仍加速），保证任何合法规划都无法越界；
2. **只施加加速度约束，不替代规划**——保留规划做精细避让的能力，RSS 只兜底；
3. **显式责任判定**——记录"当时是否处于安全状态 + 是否执行 Proper Response"，事故后可复盘归因，呼应 AuroraDrive "诚实技术文档"的理念（让用户清楚 AUTO 是辅助而非自驾）。

### 10.4 AuroraDrive RSS 风格安全设计（建议架构）

```
┌─────────────────────────────────────────────────────────┐
│              AuroraDrive 安全架构（RSS 风格）            │
├─────────────────────────────────────────────────────────┤
│  ① 感知层 (1Hz→需提升)                                  │
│     └─ 输出物体列表 (距离/速度/方向/类型 VRU?)          │
├─────────────────────────────────────────────────────────┤
│  ② 规划层 (Pure Pursuit + IDM 跟车)                    │
│     └─ 输出候选轨迹 + 加速度指令                        │
├─────────────────────────────────────────────────────────┤
│  ③ RSS 安全监督层 (NEW，替代/增强 FallbackDetector)      │
│     ├─ 对每个物体构建 Constellation                     │
│     ├─ 计算 d_min_long / d_min_lat (§10.2 公式)         │
│     ├─ 判定 Safe / Dangerous (Danger Threshold)         │
│     ├─ Dangerous ⇒ Proper Response 加速度约束 (§10.3)  │
│     └─ 输出受限加速度 → 控制层                          │
├─────────────────────────────────────────────────────────┤
│  ④ 控制层 (controller.h 四阶段 fallback 保留)           │
│     └─ Pure Pursuit + 限速合成 (min 取最保守)           │
├─────────────────────────────────────────────────────────┤
│  ⑤ SafetyEnvelope (升级为 RSS 不变式监视器)            │
│     ├─ 持续断言: "若在安全状态, 则任何规划输出不会碰撞"  │
│     ├─ 断言失败 ⇒ 强制 α_min_brake 纵向刹车 (全自动兜底) │
│     └─ 记录黑匣子: 安全状态标志 + Proper Response 执行   │
└─────────────────────────────────────────────────────────┘
```

### 10.5 具体迁移路径（与 AuroraDrive 已知缺陷对应）

| AuroraDrive 现状缺陷 | RSS 风格改造 | 优先级 |
|----------------------|--------------|--------|
| 纵向无闭环 PID（盲踩油门） | 用 d_min_long 替代 IDM s*，作为安全状态硬判定 | 高（安全风险类） |
| assist_emergency 依赖人工触发 | RSS Proper Response 自动施加加速度约束 | 高（安全风险类） |
| curvature_ 恒 0 弯道限速旁路 | 横向安全距离 + 弯道场景 d_min，强制降速 | 高（安全风险类） |
| 虚拟点 fallback 仅"不崩溃" | RSS 不变式断言：fallback 输出也必须在安全包络内 | 中（能力缺口类） |
| 无责任判定/黑匣子 | 记录 Safe/Dangerous + Proper Response 执行 | 中（技术债类） |
| 传感器 1Hz | RSS 不解决感知，但定义感知需求（需提升到 ≥10Hz） | 中（能力缺口类） |

### 10.6 务实建议

1. **不引入完整 ad-rss-lib**（已归档停止维护，且 C++ 依赖重），而是**移植 RSS 的核心公式与 Proper Response 思想**到 AuroraDrive 现有 Python/Swift 安全层，保持项目轻量；
2. **参数可配置**（ρ/a_min/a_max 全部进 config），按 AuroraDrive 实测标定，避免城市密集车流下过度保守（RSS 在 50km/h 默认参数下需 40-80m，可能不可行，需引入"限速约束"技巧）；
3. **诚实定位**：RSS 保证的是"不肇责"而非"零碰撞"，与 AuroraDrive"诚实技术文档、让用户清楚是辅助而非自驾"的理念天然契合——**用 RSS 给 AUTO 开关一个可解释的安全边界，而非夸大能力**；
4. **衔接后续章节**：本研究的公式与不变式是 `04_formal_verification.md` 与 `05_cbmc.md` 的输入——RSS 公式可形式化、可用 CBMC 验证其实现，是 AuroraDrive 走向可认证安全的起点。

---

## 11. 总结

Mobileye RSS 是自动驾驶行业**首个公开、透明、可数学验证的形式化安全模型**。它不追求"零事故"的统计承诺，而是用运动学闭式公式定义"安全状态"与"危险阈值"，用最坏情况假设保证"自车不可被指责"，用 Proper Response 把车辆拉回安全状态——这是诚实的、可向监管和公众解释的安全范式。

其核心贡献：
- **纵向/横向安全距离公式**（§3），参数物理化、可标定；
- **四大场景 + 责任判定**（§4-5），把"路权"与"注意义务"形式化；
- **白盒可解释**（§2.5），相对端到端黑盒的范式对立；
- **开源实现 ad-rss-lib**（§7）虽已归档，但公式与思想可自由移植；
- **标准化 IEEE 2846**（§9.2），推动监管认可。

对 AuroraDrive 而言，RSS 的价值不在照搬一个 C++ 库，而在**借鉴其"形式化安全状态 + Proper Response 加速度约束 + 显式责任判定"的思想**，把现有"多阶段 fallback 工程兜底"升级为"可数学验证的安全监督层"，并衔接后续形式化验证与 CBMC 章节，走向可认证的诚实安全设计。

---

## 参考来源

- arXiv 论文：[On a Formal Model of Safe and Scalable Self-driving Cars (arXiv:1708.06374)](https://arxiv.org/abs/1708.06374) — Shalev-Shwartz, Shammah, Shashua, 2017
- Intel ad-rss-lib 开源实现：[github.com/intel/ad-rss-lib](https://github.com/intel/ad-rss-lib)（已归档）
- ad-rss-lib 官方文档：[intel.github.io/ad-rss-lib](https://intel.github.io/ad-rss-lib/)（Overview / Parameter Discussion / Design Decisions）
- Mobileye 官方 RSS 页面：[mobileye.com/responsibility-sensitive-safety](https://www.mobileye.com/responsibility-sensitive-safety/)
- Mobileye China AV Safety 博客：[mobileyechina.com/blog/tag/av-safety](https://www.mobileyechina.com/blog/tag/av-safety/)
- 英特尔/Mobileye 官方解读（雷锋网新智驾）：Mobileye RSS 安全模型技术要点
- 雷锋网 RSS 驾驶策略深度解析（leiphone.com）
- 汽车之家：Mobileye CEO 发文讽刺英伟达 SFF 抄袭 RSS（2019-03）
- 电子工程世界：Intel 公开指责 NVIDIA 抄袭 Mobileye 防碰撞技术（2019-03-28）
- 中关村在线：Mobileye 以开放的 RSS 推动自动驾驶行业创新（2018-11-23）
- 汽车测试网：Mobileye RSS 理论模型 / Safety co-pilot RSS 升级版
- 网易厚势：Mobileye 创始人——无人驾驶汽车如何自证清白（2017-10）
- 搜狐/车云网：无人车发生事故时如何自证清白——Mobileye RSS
- CSDN：基于自然驾驶数据的 RSS 模型校准；RSS 模型框架下的驾驶策略；ad-rss-lib 开源项目教程
- 一文读懂智能驾驶汽车安全体系（腾讯新闻，IEEE 2846 基于 RSS，Jack Weast 负责）
- Apollo 源码：modules/planning/tasks/deciders/rss_decider（依赖 @ad_rss_lib//）
- AuroraDrive 技术白皮书（本地：全文合并_AuroraDrive技术白皮书.md）

---

> **工具调用统计**：本轮研究共执行 WebSearch + WebFetch + Read + Grep + RunCommand 等内部工具调用约 **62 次**（其中 WebSearch 约 32 次、WebFetch 约 22 次、本地文件 Read/Grep 约 7 次、RunCommand 1 次），覆盖 arXiv 原始论文、Intel 官方开源仓库与文档、Mobileye 官网与官方博客、行业深度解析（雷锋网/汽车之家/CSDN/电子工程世界/网易/搜狐）、Apollo 源码、IEEE 2846 标准化等权威来源。
