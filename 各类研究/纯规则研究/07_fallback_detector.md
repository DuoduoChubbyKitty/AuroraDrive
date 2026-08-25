# 07 · Fallback Detector 设计（异常检测 / 降级触发）

> 研究主题：自动驾驶系统中"何时该放弃当前控制源、降级到更安全层级"的判定机制。
> 研究方法：WebSearch + WebFetch 深度调研 Apollo / OpenPilot / NVIDIA / Mobileye 的异常检测与降级策略，对照 AuroraDrive 现有 `FallbackDetector` 实现，给出迁移升级方案。
> 配套源码：`cpp/include/ad/autonomy.h`（FallbackDetector 类、8 条判据、AutonomyStack 级联仲裁）。
> 字数目标：≥ 5000 字（中文字符）。

---

## 0. 为什么需要 Fallback Detector

自动驾驶系统不是"感知—规划—控制"的线性流水线，而是一个**有失败可能性的级联系统**：传感器会失效、模型会输出 OOD（分布外）结果、控制器会延迟、通信会丢包。如果在任一环节失效后仍"硬撑"输出，轻则画龙、绕圈、卡死，重则碰撞、冲出路面。

**Fallback Detector**（降级触发器）的核心职责就是回答一个问题：

> *当前主导控制源（纯规则 / 全自模型 / 共驾）是否仍然可信？若不可信，应在何时、以何种方式、降级到哪一层？*

它与两个相邻概念的区别：

| 概念 | 职责 | 关系 |
|------|------|------|
| **Guardian / Safety Envelope** | 对*输出*做物理边界钳制（steer/throttle/brake 不超限） | 最后一道硬墙，不关心"为什么超限" |
| **Fallback Detector** | 对*输入与中间状态*做异常判定，决定*控制源切换* | 在 Guardian 之前，决定"用谁的输出" |
| **Monitor** | 长周期健康监控（模块心跳、资源占用） | 软件级、秒级粒度，Fallback Detector 是帧级 |

一句话：**Guardian 钳的是"量"，Fallback Detector 判的是"源"。** Guardian 保证单帧输出不致命，Fallback Detector 保证持续多帧后系统不会"带病狂奔"。

AuroraDrive 的设计红线是"**永不退化为纯人驾**"——降级路径是 `PURE_RULE → FULL_AUTO → CO_DRIVE`，CO_DRIVE 仍共驾（见 `autonomy.h:69-76` 的 `next_source_on_fallback`）。这意味着 FallbackDetector 是这条降级链的"判官"：它说降级，系统才降；它不说话，系统按当前源继续跑。

---

## 1. Fallback Detector 概述

### 1.1 设计目标

一个合格的 Fallback Detector 需同时满足三个相互制约的目标：

1. **敏感性（Sensitivity）**：在真实异常发生时尽快触发，不漏检。漏检 = 带病运行 = 碰撞风险。
2. **特异性（Specificity）**：在正常工况下不误触发。误触发 = 频繁降级 = 用户体验崩坏、模型永远学不到数据。
3. **可解释性（Explainability）**：触发原因必须可追溯（哪条判据、什么阈值、哪一帧），否则无法调参、无法通过形式化验证。

这三者天然冲突：阈值设严则漏检，设松则误触发；纯统计异常（如孤立森林）敏高但不可解释。工业级系统普遍采用**"规则判据 + 状态机去抖 + 分级降级"**的混合方案，而非单一机器学习异常检测。

### 1.2 Fallback Detector 在系统中的位置

以 AuroraDrive 的 `AutonomyStack::step()`（`autonomy.h:913-979`）为例，FallbackDetector 处于级联仲裁之前：

```
传感器帧 → 并行推理(规则+模型) → [FallbackDetector 检测]
         → 级联仲裁(选主导源) → 相位否决 → 惩罚软否决 → 安全clamp → DAgger打标
```

关键点：FallbackDetector 在**选主导源之前**就跑了一遍——`health.severity == "critical"` 直接调 `fallback_()`（`autonomy.h:934`），不等仲裁结果。这是"先判健康，再选源"的防御式设计：哪怕规则层没失效，只要 FallbackDetector 判定 critical，就提前降级，避免把不可信的规则输出送进仲裁。

### 1.3 三层判定粒度

| 层级 | 粒度 | 触发动作 | AuroraDrive 对应 |
|------|------|---------|-----------------|
| L0 帧级 | 单帧异常 | 标记 warn，继续运行 | `check_*_` 单判据 |
| L1 短窗级 | 滑窗 N 帧 | 标记 critical，触发降级 | `lane_departure_count_>=3`、`oscillation` 5 帧 |
| L2 长周期 | 秒级持续 | 紧急停车 / 移交人工 | `stuck_timer_>=3s`、emergency_stop() |

AuroraDrive 当前覆盖 L0 与部分 L1（去抖计数器），L2 仅有 `emergency_stop()` 这一终极兜底，缺少"持续 N 秒 warn → 自动升级 critical"的渐进机制。这是后续升级的重点之一。

---

## 2. 异常检测（Anomaly Detection）

异常检测是 Fallback Detector 的"眼睛"。按被观测对象，自动驾驶异常可分为四大类：传感器异常、模型异常、控制异常、通信异常。

### 2.1 异常检测类型表

| 大类 | 子类 | 典型表现 | 检测手段 | 严重度 | AuroraDrive 现状 |
|------|------|---------|---------|--------|-----------------|
| **传感器异常** | 传感器失效 | 帧无数据 / 全黑 / 全白 | 帧率监控、像素方差、心跳超时 | critical | ❌ 未检测（SensorSlot 仅计数） |
| | 传感器噪声突增 | 图像模糊、点云稀疏 | 图像梯度方差、点云点数阈值 | warn | ❌ 未检测 |
| | 传感器漂移 | IMU 零偏累积、里程计误差 | 残差监测、双源融合差异 | warn→critical | ❌ 未检测 |
| | 数据陈旧 | timestamp 过期 | `now - ts > 阈值`（分级降级） | warn→critical | ⚠️ KeyboardHumanInput 有 stale_，但传感器帧无 |
| **模型异常** | 输出超界 | steer>1 / throttle<0 | 物理包络 clamp + 计数 | warn | ⚠️ clamp 有，超界计数无 |
| | 输出不合理 | TTC<阈值却加速、无路却给油 | 语义一致性检查 | critical | ⚠️ 仅 collision 判据间接覆盖 |
| | 推理延迟 | inference_ms 超阈值 | 计时 + 滑窗 P99 | warn→critical | ⚠️ 采集了 inference_ms 但未据此降级 |
| | OOD（分布外） | 输入偏离训练分布 | 置信度、重构误差、ensemble 方差 | warn→critical | ❌ 未检测 |
| **控制异常** | 控制延迟 | 命令到执行 > 阈值 | 时间戳差 | warn→critical | ❌ 未检测 |
| | 控制失效 | 无转向响应 / 无制动响应 | 命令-状态反馈比对 | critical | ❌ 未检测 |
| | 执行器饱和 | 持续满舵 / 持续全油门 | 持续时长计数 | warn | ⚠️ stuck 判据部分覆盖 |
| **通信异常** | 消息超时 | topic 长时间无新消息 | 心跳 / last_msg_age | warn→critical | ❌ 未检测 |
| | 丢包 | 帧号不连续 | frame_id 跳变检测 | warn | ⚠️ SensorSlot 有 frame_id 但未做跳变告警 |
| | 数据损坏 | checksum 不匹配 / magic 错 | SHA256 / CRC 校验 | critical | ⚠️ mmap 有 SHA256，IPC 帧无 |

**关键发现**：AuroraDrive 的 FallbackDetector 当前**只覆盖了"规划/控制层语义异常"**（无路、死胡同、曲率过大、TTC、车道偏离、振荡、卡死），而对**传感器层与通信层异常几乎零覆盖**。这在仿真模式（数据可信）下可接受，但在真机模式（Swift 读硬件 → IPC → sidecar）下是重大缺口——传感器断流时系统仍会用最后一帧陈旧数据"盲目"决策。

### 2.2 各系统异常检测策略对比

#### Apollo：Monitor + Guardian 双层

Apollo 的异常检测分散在两个子系统：

- **Monitor 模块**（`modules/monitor/`）：软件级健康监控。它订阅各模块状态 topic（如 `localization_msf_status`、`SmartRecorderStatus`），用 `SummaryMonitor::EscalateStatus` 把模块状态映射为 `ComponentStatus`（OK / WARN / ERROR / FATAL）。例如定位监控（`LocalizationMonitor::RunOnce`）读取 `fusion_status`，将 `CRITICAL_ERROR` 映射为 `ComponentStatus::ERROR`、`FATAL_ERROR` 映射为 `FATAL`。注释明确指出"**ERROR and FATAL will trigger safety mode in current settings**"——即 Monitor 的告警会触发安全模式。
- **Guardian 模块**（`modules/guardian/`）：帧级安全守护。它监听 Monitor 汇总的状态、感知的障碍物、底盘状态，综合判定是否进入 `SafetyMode`。一旦进入，Guardian 会向 Control 模块下发紧急停车指令（最大制动 + 回正方向盘）。

Apollo 的设计哲学是**"Monitor 管软件健康（秒级），Guardian 管行车安全（帧级）"**。Monitor 负责发现"模块挂了"，Guardian 负责"模块没挂但行车危险"。两者通过 `SystemStatus` proto 串联，Guardian 是最终的执行者。

#### OpenPilot：Events 系统 + 状态机

OpenPilot（comma.ai）的异常检测核心是 **Events 系统**（`selfdrive/selfdrived/events.py`）。它把所有异常（传感器、模型、控制、驾驶员状态）统一建模为 `Event`，每个 Event 有：

- `name`：事件名（如 `sensorDataInvalid`、`modeldLag`、`controlsMismatch`、`canError`、`driverDistraction`）
- `severity`：`alert`（提示）/ `warning`（警告）/ `critical`（严重，立即退出）
- `type`：事件类别（用于状态机判定）

`Events` 类聚合当前帧所有事件，`StateManager` 据此驱动状态机切换：`disabled → enabled → softDisable → overridden → alertOff`。例如：

- `canTimeout` / `commIssue` → 直接 `disabled`（通信异常）
- `modeldLag`（推理延迟超阈值）→ `softDisable`（模型异常，软退出保留制动）
- `steerUnavailable` / `brakeUnavailable` → `disabled`（控制异常）
- `driverUnresponsive`（DMS 检测驾驶员走神 + 手离方向盘超时）→ `alert` 升级到 `warning` 再到 `overridden`（强制人工接管）

OpenPilot 的设计哲学是**"所有异常都是事件，状态机是唯一的决策中枢"**。优点是可扩展性强（加异常只需加 Event），缺点是事件间交互复杂，需小心"事件风暴"导致状态机抖动。

#### NVIDIA：Halos 全栈 + Safety Force Field

NVIDIA 的安全体系是**全栈式**的，分三层护栏（design-time / validation-time / deploy-time）：

- **设计时护栏**（DGX）：训练数据安全、模型可解释性。
- **验证时护栏**（Omniverse + Cosmos）：仿真测试、场景覆盖。
- **部署时护栏**（DRIVE AGX + Halos OS）：**运行时监控 + 实时内省**。

运行时层的关键组件：

- **Safety Force Field（SFF）**：基于 RSS 思想的实时碰撞避免层。它独立于主规划器，对感知-规划输出做"前方可达范围"安全校验，一旦预测轨迹会侵犯其他道路使用者的安全包络，立即接管制动。
- **功能安全岛（FSI）**：硬件级冗余。Thor-X SoC 内置独立的安全 island，监控主计算簇的状态，主簇失效时由 island 触发 ASIL-D 级安全状态（最小风险机动 MRC）。
- **Halos OS**：ASIL-D 认证的三层安全基础（Halos Core OS + Halos SDK + Halos App），所有安全相关代码运行在 ASIL-D 隔离分区，不受 QM 级应用干扰。

NVIDIA 的设计哲学是**"纵深防御 + 硬件兜底"**。软件层 SFF 做帧级安全，硬件层 FSI 做芯片级兜底，认证层 Halos OS 保证安全代码不被干扰。这是目前业界最重的方案，代价是开发与认证成本极高（18600+ 工程年、210 亿安全评估晶体管、700 万行安全评估代码）。

#### Mobileye RSS：Proper Response 责任模型

Mobileye 的 Responsibility-Sensitive Safety（RSS）不是"异常检测器"，而是一套**"应该怎么做才不担责"的数学模型**。它定义了四种危险场景（纵向同向、纵向对向、横向、行人），为每种场景定义安全距离与安全响应（Proper Response）：

- **Safe Distance**：当前车紧急制动时，后车仍能刹停不碰撞的最小距离。
- **Proper Response**：一旦实际距离 < Safe Distance，后车必须执行"合理制动"（reasonable brake），即不早于、不晚于合理时机。

RSS 的"异常"定义是**"距离 < Safe Distance"**——这是一个纯几何/运动学的判定，与模型无关、与传感器无关。它的价值在于：即使感知完全正确、规划完全合理，只要 RSS 判定危险，就强制 Proper Response。这相当于给系统装了一个**"数学上可证明安全"的底线**。

RSS 后续演进为 **Mobileye SuperVision / Ride** 中的 RSS+（加了场景泛化）和 **DSSC（Dynamic Scenario Coverage）**。

---

## 3. 降级触发（Degradation Triggering）

异常检测回答"出没出问题"，降级触发回答"出了问题怎么办"。降级不是一个二元开关，而是一组**分级、分场景**的策略。

### 3.1 降级策略谱系

按"降级后系统做什么"，可分为五档（从轻到重）：

| 档位 | 名称 | 动作 | 适用场景 |
|------|------|------|---------|
| D0 | 降权（Derate） | 限制模型激进度（如 steer_cap 收紧），不切换源 | 模型略激进、轻微 OOD |
| D1 | 软降级（Soft Disable） | 切到更保守的控制源，保留动力 | 模型推理延迟、置信度低 |
| D2 | 硬降级（Fallback） | 切到下一级联源（规则→全自→共驾） | 规则失效、模型失效 |
| D3 | 最小风险机动（MRC） | 减速靠边停车 | 多源均失效、无法共驾 |
| D4 | 紧急停车（Emergency Stop） | 最大制动 + 回正 | 立即碰撞风险、控制失效 |

### 3.2 各场景降级触发条件

#### 单传感器降级

- **摄像头失效**（全黑/全白）：感知降级到仅 LiDAR，模型 steer 输出降权（D0）。持续 3 帧无效 → 模型层整体软降级（D1）。
- **LiDAR 失效**：仅视觉主导，前车距离检测精度下降，TTC 阈值放大 1.5 倍（更保守）。
- **IMU/里程计漂移**：定位置信度下降，规划层缩短前瞻距离（从 50m → 20m）。

AuroraDrive 现状：无单传感器降级逻辑。`SensorSlot` 只做读写计数，帧失效不触发任何降级。这是真机模式的最大风险点。

#### 多传感器降级

- **视觉 + LiDAR 双失效**：感知完全失明 → D4 紧急停车。这是"感知层 critical"的标准处置。
- **视觉失效 + 定位漂移**：D3 最小风险机动（无法规划路径，只能减速靠边）。

Apollo Guardian 对此有明确分级：单模块 FATAL 触发 safety mode（减速），多模块 FATAL 触发 emergency stop（急刹）。

#### 模型降级

- **推理延迟**：`inference_ms > 100ms`（AuroraDrive 目标 <100ms on Raspberry Pi）→ D1 软降级，规则层接管主导。
- **输出超界持续**：连续 N 帧 steer 超 `full_auto_steer_cap` → D2 降级到规则。
- **OOD**：模型置信度低 → D0 降权，收紧 steer_cap。

AuroraDrive 现状：`autonomy.h:944-951` 处理了"模型未加载"的硬降级（有人接管→共驾，无人→急刹+降级），但**推理延迟与 OOD 完全未处理**。`inference_ms` 字段被采集（`autonomy.h:977`）却从未参与降级判定——这是典型的"采而不用"。

#### 控制降级

- **控制延迟**：命令下发到执行 > 50ms → D0 降权（减小油门幅度）；> 200ms → D4 停车。
- **执行器无响应**：下发制动但车速不降 → D4 紧急停车 + 告警。
- **持续饱和**：满舵 > 2s → D2 降级（怀疑控制器振荡）。

AuroraDrive 现状：`check_stuck_`（`autonomy.h:507-517`）覆盖了"低油门却不动"的卡死场景，但**无控制延迟与无响应检测**。仿真模式下执行器即时响应，掩盖了这一问题；真机模式必现。

#### 通信降级

- **消息超时**：`last_msg_age > 200ms` → D1 软降级（用上一帧）；> 500ms → D3 MRC。
- **丢包率突增**：帧号跳变 > 10% → D0 降权；> 30% → D2 降级。
- **数据损坏**：checksum 失败 → 丢弃该帧，用上一帧；连续 3 帧损坏 → D4 停车。

这与 AuroraDrive 的"陈旧数据分级降级"约束一致（`<50ms 用上一帧 / 50-200ms 减速 / >200ms 停车`），但该约束目前只在项目记忆中，代码未落地。

### 3.3 降级触发的去抖与防抖

降级最忌讳"抖动"——频繁在源之间切换会导致车辆行为不可预测（忽而规则忽而模型）。三种去抖机制：

1. **计数去抖**：异常连续 N 帧才触发（AuroraDrive 的 `lane_departure_count_ >= 3`）。
2. **时间去抖**：异常持续 T 秒才触发（AuroraDrive 的 `stuck_timer_ >= 3.0s`）。
3. **滞后回退**：触发降级后，需异常**完全消失持续 M 帧**才允许升回原源。AuroraDrive 当前**只有降没有升**——`fallback_()` 单向推进，永不自动回升。这是合理的保守设计（避免抖动），但也意味着一次瞬时异常会导致永久降级直到人工重置。

OpenPilot 的状态机用了"延迟生效 + 立即失效"：`softDisable` 后需驾驶员主动重新 enable，不会自动回 `enabled`；而 `disabled` 是瞬时的（critical 事件立即生效）。这种"单向门"设计与 AuroraDrive 一致。

---

## 4. AuroraDrive FallbackDetector 现状剖析

### 4.1 现有 8 条判据

AuroraDrive `FallbackDetector`（`autonomy.h:350-522`）实现了 8 条纯规则失效检测判据：

| # | 判据 | 阈值 | 严重度 | 触发条件 |
|---|------|------|--------|---------|
| 1 | `no_road` | 道路点 < 2 | critical | 无道路中心线（OOD / 无路） |
| 2 | `dead_end` | 距终点 < 30m 且点数 < 20 | warn | 道路即将结束 |
| 3 | `curvature_extreme` | \|曲率\| > 0.3 rad/m | warn | 弯道过急，超出规划能力 |
| 4 | `min_speed_violation` | 限速 < 5 km/h | warn | 限速异常低（疑似错误数据） |
| 5 | `front_collision_imminent` | TTC < 1.5s 且 brake < 0.3 | critical | 前车碰撞迫近却未制动 |
| 6 | `lane_departure` | 横向偏离 > 5m，连续 3 帧 | warn | 车道偏离（计数去抖） |
| 7 | `oscillation` | 5 帧内方向翻转 ≥ 3 次 | warn | 转向振荡（画龙） |
| 8 | `stuck` | 速度 < 1km/h 且油门 > 0.05 持续 3s | warn | 卡死（时间去抖） |

### 4.2 现有触发流程

`AutonomyStack::step()` 中（`autonomy.h:929-934`）：

```cpp
RuleHealth health = detector_.check(...);
if (health.severity == "critical") fallback_();
```

降级动作 `fallback_()`（`autonomy.h:1048-1052`）仅做控制源推进：

```cpp
void fallback_() noexcept {
    source_ = next_source_on_fallback(source_);  // PURE_RULE→FULL_AUTO→CO_DRIVE
    if (source_ == ControlSource::FULL_AUTO) phase_ = Phase::FULL_AUTO;
    else if (source_ == ControlSource::CO_DRIVE) phase_ = Phase::CO_DRIVE;
}
```

### 4.3 现状的优势与缺口

**优势**：
1. **判据纯规则、零依赖**：8 条判据全是确定性数学（距离、曲率、TTC、计数），无 ML，可形式化验证。
2. **critical / warn 分级清晰**：`no_road` 与 `front_collision_imminent` 是 critical（立即降级），其余 warn（记录但不立即降级）。
3. **去抖机制完备**：lane_departure 计数去抖、stuck 时间去抖、oscillation 滑窗去抖，三种类别都覆盖。
4. **与级联仲裁解耦**：FallbackDetector 独立于仲裁逻辑，可单独测试。

**缺口**（按严重度排序）：

| 缺口 | 严重度 | 说明 |
|------|--------|------|
| 1. 无传感器异常检测 | **高** | 传感器断流/陈旧不触发降级，真机模式致命 |
| 2. 无通信异常检测 | **高** | IPC 丢包/超时不检测，sidecar 崩溃靠 watchdog 兜底 |
| 3. inference_ms 采而不用 | **中** | 推理延迟超阈值不降级，Pi 上模型慢会"盲目"输出 |
| 4. warn 不自动升级 critical | **中** | 持续 warn 不累积升级，长期异常被静默忽略 |
| 5. 无控制反馈校验 | **中** | 命令下发后不校验执行器是否响应 |
| 6. 单向降级无回升 | **低** | 一次瞬时误触发=永久降级（保守但影响体验） |
| 7. 无 OOD 检测 | **低** | 模型分布外输入无感知（依赖 no_road 间接覆盖） |

---

## 5. 各系统降级策略对比

### 5.1 降级策略对比表

| 维度 | AuroraDrive | Apollo | OpenPilot | NVIDIA (Halos) | Mobileye RSS |
|------|-------------|--------|-----------|----------------|--------------|
| **检测粒度** | 帧级（规划语义） | 秒级(Monitor)+帧级(Guardian) | 帧级(Events) | 帧+硬件级(FSI) | 帧级（几何） |
| **异常建模** | 8 条硬编码判据 | ComponentStatus 枚举 | Event 列表（可扩展） | SFF 可达集 + FSI 硬件 | Safe Distance 公式 |
| **降级档位** | D2(降级)+D4(急刹) | D2+D3+D4 | D1(soft)+D2+D4 | D2+D3+D4(MRC) | D4(Proper Response) |
| **去抖机制** | 计数+时间+滑窗 | 状态聚合 | 状态机延迟门 | 硬件级（无抖动） | 无（瞬时判定） |
| **回升机制** | ❌ 无 | ✅ 状态恢复 | ❌ 需人工 enable | ✅ FSI 复位 | ✅ 距离恢复即停 |
| **传感器异常** | ❌ | ✅ Monitor | ✅ Events | ✅ FSI | ❌（假设感知正确） |
| **模型异常** | ⚠️ 间接 | ✅ Guardian | ✅ modeldLag | ✅ SFF | ❌ |
| **控制异常** | ⚠️ stuck | ✅ 底盘状态 | ✅ controlsMismatch | ✅ FSI | ❌ |
| **通信异常** | ❌ | ✅ 心跳 | ✅ canTimeout | ✅ FSI | ❌ |
| **可解释性** | ✅ 高（规则） | ✅ 高（状态机） | ✅ 中（事件名） | ⚠️ 中（黑盒 SFF） | ✅ 高（公式） |
| **形式化可验证** | ✅ 可 | ⚠️ 部分 | ⚠️ 难（事件多） | ✅ ASIL-D 认证 | ✅ 可证明 |
| **资源开销** | 极低（constexpr） | 中（多模块） | 低（事件聚合） | 高（独立硬件） | 极低（几何运算） |
| **适用场景** | 仿真+轻量真机 | L4 全栈 | L2 辅助驾驶 | L4 量产 | L2-L4 通用底线 |

### 5.2 关键差异解读

**AuroraDrive vs Apollo**：Apollo 的 Monitor-Guardian 双层是"软件健康 + 行车安全"分工，AuroraDrive 把两者揉在 FallbackDetector 一个类里。Apollo 优势是模块化（加监控点只需加 Monitor 子类），劣势是跨模块通信开销大、状态聚合延迟。AuroraDrive 优势是单类内联、零延迟、可 constexpr，劣势是扩展性差（加判据需改类）。

**AuroraDrive vs OpenPilot**：OpenPilot 的 Events 系统把"异常"和"降级"解耦——Events 只管"发生了什么"，StateManager 管"怎么办"。AuroraDrive 把两者耦合在 `check()` 里（判据直接写死降级语义）。OpenPilot 优势是事件可组合、可复用，劣势是状态机复杂度高。AuroraDrive 优势是直白，劣势是改一个判据可能影响整体语义。

**AuroraDrive vs NVIDIA**：NVIDIA 的 SFF 是"独立安全层"——它不信任主规划器，自己重新算一遍安全包络。AuroraDrive 的 FallbackDetector 信任规则层输出，只检测"规则失效"（如无路），不重新校验"规则输出是否安全"。这是定位差异：AuroraDrive 假设规则层本身是安全的（由 SafetyEnvelope clamp 兜底），NVIDIA 假设主栈不可信（需独立校验）。

**AuroraDrive vs Mobileye**：RSS 是"底线思维"——不管你用什么感知、什么规划，只要距离 < Safe Distance 就 Proper Response。AuroraDrive 的 `front_collision_imminent`（TTC < 1.5s）本质是 RSS 纵向场景的简化版，但缺横向与对向场景。RSS 的价值是"数学可证明"，AuroraDrive 的 TTC 判据是经验阈值，不可证明。

---

## 6. AuroraDrive FallbackDetector 升级方案

基于上述对比，提出分阶段升级方案。原则：**保持纯规则、零依赖、可形式化验证的底色，补齐传感器/通信/模型三类缺口，引入 Events 解耦但不引入 ML 异常检测**。

### 6.1 阶段一：补齐传感器与通信异常（高优先级）

**目标**：让 FallbackDetector 在真机模式下能感知传感器断流与 IPC 异常。

**改动 1：SensorSlot 增加健康度上报**

在 `SensorSlot`（`autonomy.h:773-811`）增加 `HealthReport`：

```cpp
struct SensorHealth {
    bool stale = false;          // now - timestamp > stale_thresh
    double age_ms = 0.0;         // 帧龄
    int dropped_frames = 0;      // 自上次读取后跳变帧数
    bool checksum_ok = true;     // 帧完整性（IPC 侧填）
};
```

`SensorSlot::read()` 返回时附带 health，`AutonomyStack::step()` 据此判定：

```cpp
if (sensor_health.stale) {
    if (sensor_health.age_ms < 50.0) { /* D0: 用上一帧，降权 */ }
    else if (sensor_health.age_ms < 200.0) { /* D1: 减速 */ detector_.raise_warn("sensor_stale"); }
    else { /* D4: 停车 */ detector_.raise_critical("sensor_dead"); }
}
```

这落地了项目记忆中的"陈旧数据分级降级（<50ms/50-200ms/>200ms）"约束。

**改动 2：FallbackDetector 增加 sensor 通道**

将 `check()` 签名扩展，接收 `SensorHealth`：

```cpp
RuleHealth check(..., const SensorHealth& sh, double inference_ms);
```

新增判据：
- `sensor_dead`：age > 200ms → critical
- `sensor_degraded`：50ms < age < 200ms → warn
- `inference_lag`：inference_ms > 100ms → warn（软降级到规则）
- `inference_timeout`：inference_ms > 300ms → critical

这把"采而不用"的 `inference_ms` 接入降级链。

### 6.2 阶段二：引入 Events 解耦（中优先级）

**目标**：借鉴 OpenPilot，把"判据"与"降级动作"解耦，提升可扩展性。

**改动**：定义 `AnomalyEvent` 轻量结构（不引入事件总线，保持单类内聚）：

```cpp
struct AnomalyEvent {
    std::string name;        // "no_road" / "sensor_dead" / ...
    std::string severity;    // warn / critical
    int persist_frames = 0;  // 已持续帧数（去抖）
};
```

`FallbackDetector::check()` 内部把每条判据产出一个 `AnomalyEvent`，存入 `std::vector<AnomalyEvent>`，由 `AutonomyStack` 统一消费。好处：
1. 加判据只需加一个 `check_xxx_` 并 push 一个 event，不动 `check()` 主干。
2. DAgger 打标可记录 event 列表，便于离线分析"降级时发生了什么"。
3. 为后续"warn 累积升级 critical"提供数据基础。

**改动 3：warn 累积升级**

```cpp
// 同一 event 持续 > N 帧的 warn 自动升级 critical
if (event.persist_frames > WARN_ESCALATION_FRAMES && event.severity == "warn") {
    event.severity = "critical";
}
```

修复缺口 4（warn 不升级）。`WARN_ESCALATION_FRAMES` 建议 30 帧（约 1.25s @ 24Hz）。

### 6.3 阶段三：补齐控制反馈校验（中优先级）

**目标**：检测执行器无响应。

**改动**：`AutonomyStack::step()` 增加"命令-状态比对"。利用车辆动力学模型预测下一帧速度，与实际速度比对：

```cpp
float predicted_speed = ego_speed + (throttle*3.0 - brake*5.0) * dt * 3.6;  // km/h
float actual_speed = rule_input.ego_speed;
float speed_error = std::abs(predicted_speed - actual_speed);
if (speed_error > 10.0f && std::abs(throttle) > 0.3f) {
    detector_.raise_critical("actuator_no_response");
}
```

这落地了缺口 5（无控制反馈校验）。注意：仿真模式下执行器即时响应，此判据需在真机模式才启用，可用编译宏或运行时 flag 控制。

### 6.4 阶段四：借鉴 RSS 增强碰撞判据（低优先级）

**目标**：把 `front_collision_imminent` 从单一 TTC 扩展到 RSS 纵向 + 横向场景。

**改动**：参考 Mobileye RSS，新增：
- `rss_longitudinal`：后车 Safe Distance 判定（当前是前车 TTC，方向相反，补齐"被追尾"场景的保守减速）。
- `rss_lateral`：横向安全距离，车道偏离判据的 RSS 化（用公式替代经验 5m 阈值）。

RSS 公式纯数学，符合 AuroraDrive"可形式化验证"的底色。但优先级低，因为现有 TTC + lane_departure 已覆盖主要场景，RSS 是"锦上添花"。

### 6.5 阶段五：回升机制（低优先级）

**目标**：解决"一次瞬时误触发=永久降级"。

**改动**：引入"健康持续期"——连续 M 帧 health.ok 且无 critical，允许升回上一级源：

```cpp
if (health.ok) {
    healthy_streak_++;
    if (healthy_streak_ > RECOVERY_FRAMES && source_ != original_source_) {
        source_ = prev_source_;  // 谨慎回升一档
    }
} else {
    healthy_streak_ = 0;
}
```

`RECOVERY_FRAMES` 建议 300 帧（约 12.5s @ 24Hz），远长于降级去抖（3-30 帧），确保"回升比降级难得多"。需配合形式化验证，证明不会引入抖动环。此改动优先级最低，因为单向降级是保守安全的，回升是体验优化。

### 6.6 升级后的判据总表（目标态）

| # | 判据 | 来源 | 严重度 | 阶段 |
|---|------|------|--------|------|
| 1-8 | 现有 8 条 | 现状 | — | — |
| 9 | sensor_dead | 阶段一 | critical | 传感器 |
| 10 | sensor_degraded | 阶段一 | warn | 传感器 |
| 11 | inference_lag | 阶段一 | warn | 模型 |
| 12 | inference_timeout | 阶段一 | critical | 模型 |
| 13 | actuator_no_response | 阶段三 | critical | 控制 |
| 14 | rss_longitudinal | 阶段四 | warn→critical | RSS |
| 15 | rss_lateral | 阶段四 | warn | RSS |
| 16 | comm_timeout | 阶段一 | critical | 通信 |
| 17 | comm_packet_loss | 阶段一 | warn | 通信 |

升级后判据从 8 条增至 17 条，覆盖传感器/模型/控制/通信/规划全链路，且保持纯规则、零 ML 依赖、可形式化验证。

---

## 7. 关键设计原则总结

综合五家系统的得失，AuroraDrive FallbackDetector 升级应恪守以下原则：

1. **规则优先，ML 不入判据链**。所有判据保持确定性数学，便于 CBMC 形式化验证（项目已规划用 CBMC 验证 AutonomyStack 状态转移）。ML 仅用于"采而不用"的观测（如 OOD 置信度可作为 warn 的辅助参考，但不直接驱动 critical）。

2. **降级单向门，回升严格滞后**。借鉴 OpenPilot 的"立即失效、延迟生效"，降级瞬时完成，回升需持续健康远长于降级去抖。避免抖动环。

3. **Events 解耦，但不开事件总线**。借鉴 OpenPilot 的 Events 建模，但不引入跨模块事件总线（那是 Apollo 的重方案）。Events 作为单类内的中间数据结构，保持零进程间通信。

4. **分层降级，分级处置**。D0 降权 → D1 软降级 → D2 硬降级 → D3 MRC → D4 急刹，五档分明，不同异常走不同档位，避免"一刀切急刹"破坏体验。

5. **传感器/通信是第一缺口**。仿真模式掩盖了传感器与通信异常，真机模式这两个缺口是致命的。阶段一必须优先补齐。

6. **RSS 作为可证明的底线**。TTC 是经验阈值，RSS 是数学证明。长期看，把碰撞判据 RSS 化是提升"可证明安全"的关键路径，但短期优先级低于传感器缺口。

7. **inference_ms 必须接入降级链**。已采集的数据不参与决策是浪费，Pi 上模型慢会"盲目"输出，必须用 inference_ms 驱动软降级。

8. **保留 critical / warn 二级，新增 warn 累积升级**。单帧 warn 不降级，但持续 warn 必须升级 critical，避免长期异常被静默忽略。

---

## 8. 与 AuroraDrive 现有架构的契合点

升级方案与项目既有约束深度契合：

- **"永不纯人驾"红线**：所有降级路径仍止于 CO_DRIVE，阶段一到五均不引入 PURE_HUMAN。
- **"分级降级 <50ms/50-200ms/>200ms"约束**：阶段一的 sensor_dead/sensor_degraded 判据直接落地该约束。
- **"CBMC 形式化验证 AutonomyStack 状态转移"**：所有新增判据保持纯规则，可被 CBMC 建模。
- **"inference_ms <100ms on Raspberry Pi"目标**：阶段一的 inference_lag 判据把该目标从"性能指标"升级为"安全判据"。
- **"崩溃恢复：无限重启 + 频率熔断"**：FallbackDetector 的 critical 降级与 sidecar 崩溃重启是两层兜底——前者管"软件没崩但行为危险"，后者管"软件崩了"。互补不冲突。
- **"Watchdog 5 分钟超时"**：长周期健康由 watchdog 兜底，FallbackDetector 专注帧级，分工清晰。

---

## 9. 研究结论

Fallback Detector 是自动驾驶系统从"能跑"到"安全地跑"的分水岭。AuroraDrive 现有的 8 条判据在仿真模式下已能覆盖主要规划层失效场景，但在真机模式下，传感器与通信异常的零覆盖是致命缺口。

通过对照 Apollo（Monitor-Guardian 双层）、OpenPilot（Events 状态机）、NVIDIA（Halos 全栈 + SFF + FSI）、Mobileye（RSS Proper Response），本报告提出五阶段升级方案：补传感器/通信 → Events 解耦 → 控制反馈 → RSS 化 → 回升机制。升级后判据从 8 条增至 17 条，覆盖全链路，且保持纯规则、零依赖、可形式化验证的底色，与项目"永不纯人驾"、"CBMC 验证"、"Pi <100ms"等硬约束完全契合。

核心洞察：**Fallback Detector 的本质不是"检测更多异常"，而是"在正确的时机、以正确的档位、降级到正确的层级"**。敏而不抖、严而不滥、可解释、可验证——这才是工业级降级触发器的标准。

---

> 本报告基于 WebSearch + WebFetch 对 Apollo / OpenPilot / NVIDIA Halos / Mobileye RSS 的深度调研，以及对 AuroraDrive `cpp/include/ad/autonomy.h` 源码的逐行剖析。
>
> **实际工具调用次数**：本研究累计执行约 58 次工具调用，其中 WebSearch 约 22 次、WebFetch 约 21 次（含 Apollo 源码、OpenPilot 源码、NVIDIA Halos 文档、CSDN 解析文章、Mobileye RSS 论文）、本地文件 Read 约 9 次（autonomy.h / safety_envelope / OpenPilot safety_model / 项目交接文档等）、Glob/LS/RunCommand 等辅助调用约 6 次。最终通过 Write 工具写入目标文件。
