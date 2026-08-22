# 08 · Emergency Stop 策略（紧急停车流程）深度研究

> 研究主题：自动驾驶系统中 Emergency Stop（紧急停车）策略的完整工程实现，覆盖定义、触发条件、处理流程、恢复流程，并对 Apollo Guardian、OpenPilot 30 秒规则、NVIDIA DriveGuard / Safety MCU、Mobileye RSS Proper Response、AuroraDrive 当前 `emergency_stop()` 进行源码级拆解，最后给出 AuroraDrive Emergency Stop 升级方案。
> 研究方法：WebSearch + WebFetch 深度调研 Apollo / OpenPilot / NVIDIA / Mobileye / Autoware / SAE 标准公开资料与 CSDN / 腾讯云源码解析，结合 AuroraDrive 项目 `cpp/include/ad/autonomy.h`、`cpp/include/ad/simulator.h`、`cpp/include/ad/http_server.h` 现有实现进行对照分析。
> 配套源码：`cpp/include/ad/autonomy.h`（`emergency_stop()` 终极兜底）、`cpp/include/ad/simulator.h`（FallbackDetector critical 分支）、`cpp/include/ad/http_server.h`（`/api/assist/emergency_stop` 端点）。
> 字数目标：≥ 5000 字（中文字符）。

---

## 1. Emergency Stop 概述

### 1.1 定义

**Emergency Stop（紧急停车）** 是自动驾驶系统在检测到**不可恢复的异常**或**即将发生碰撞**时，主动切断正常控制流，按下"急停按钮"——以最快可执行的方式让车辆进入**最小风险状态（Minimum Risk Condition, MRC）**的终极安全动作。它对应 SAE J3206-2021 中定义的 MRC：*"用户或 ADS 在执行 DDT 后备后可以将车辆带入的稳定、停止状态，以在无法或不应当继续行程时减少碰撞风险"*。

与三个相邻概念的区别：

| 概念 | 职责 | 触发时机 | 行为 |
|------|------|----------|------|
| **Safety Envelope（安全包络）** | 对单帧输出做物理钳制 | 每帧无条件 | steer/throttle/brake 限幅 |
| **Fallback Detector（降级检测）** | 判定控制源是否可信 | 帧级 / 短窗级 | 切换控制源、降级 |
| **Emergency Stop（紧急停车）** | 终极兜底，进入 MRC | critical 严重度 | throttle=0, brake=MAX, steer=0 |
| **MRM（最小风险机动）** | L3+ 系统级降级策略 | 系统失效 / 用户未接管 | 靠边停车 / 缓停 / 急停 |

一句话：**Safety Envelope 钳的是"量"，Fallback Detector 判的是"源"，Emergency Stop 是"源已不可信且量已无法挽救时的最后一脚刹车"。** 它不诊断"为什么错了"，只在"错误已无法挽回时"把车辆强制带到静止状态。

### 1.2 三层定位

Emergency Stop 在自动驾驶安全栈中处于**最底层**，是纵深防御（Defense in Depth）的最后一道软件防线：

```
┌─────────────────────────────────────────────────────────┐
│ L0 规划层 Planning    │ 路径规划检查、障碍物避让         │
├─────────────────────────────────────────────────────────┤
│ L1 控制层 Control     │ 轨迹跟踪、PID/MPC 输出          │
├─────────────────────────────────────────────────────────┤
│ L2 监控层 Monitor     │ 模块心跳、资源、通信监控         │
├─────────────────────────────────────────────────────────┤
│ L3 包络层 Envelope    │ 输出 clamp、限幅                │
├─────────────────────────────────────────────────────────┤
│ L4 降级层 Fallback    │ 控制源切换、规则/模型仲裁        │
├─────────────────────────────────────────────────────────┤
│ L5 ⛔ 紧急停车 Emergency Stop │ throttle=0, brake=MAX, steer=0 │
├─────────────────────────────────────────────────────────┤
│ L6 硬件层 Hardware    │ CAN watchdog、ESP、ABS、机械刹车 │
└─────────────────────────────────────────────────────────┘
```

### 1.3 触发条件总览

Emergency Stop 不是单一触发，而是**多源 OR 逻辑**的汇总。任何一条满足即触发：

- 传感器失效（帧无数据 / 全黑 / 全白 / 心跳超时）
- 模型失效（输出超界 / 推理延迟 / OOD / 输出不合理）
- 控制失效（无转向响应 / 无制动响应 / 执行器饱和）
- 通信失效（消息超时 / 丢包 / 数据损坏）
- 操作手干预（踩刹车 / 按取消键 / 急停按钮）
- 即将碰撞（TTC < 阈值 / 距离 < 安全距离）
- 系统崩溃（关键模块进程消失 / 看门狗超时）
- 30 秒规则（驾驶员长时间无响应，OpenPilot 风格渐进告警）

### 1.4 处理流程与恢复流程

**处理流程**（典型）：检测异常 → 判定严重度 → 触发 emergency_stop → 输出 `throttle=0, brake=MAX, steering=0` → 车辆减速 → 停车 → 保持停车状态。

**恢复流程**（典型）：停车保持 → 等待用户确认（按键 / 踩油门 / 发指令）→ 系统复位（清零 FallbackDetector 状态、重置控制源）→ 重启规划 → 恢复正常驾驶。

---

## 2. 紧急停车流程

### 2.1 标准紧急停车流程图（文字）

```
                    ┌──────────────────────────┐
                    │  传感器 / 模型 / 控制 / 通信 │
                    │  持续运行中（10ms / 100Hz） │
                    └─────────────┬────────────┘
                                  │
                                  ▼
                    ┌──────────────────────────┐
                    │  ① 检测异常               │
                    │  - FallbackDetector.check()│
                    │  - Monitor 模块心跳        │
                    │  - 超声波 / 雷达近距        │
                    │  - 操作手刹车踏板          │
                    └─────────────┬────────────┘
                                  │
                                  ▼
                    ┌──────────────────────────┐
                    │  ② 判定严重度             │
                    │  severity = none/warn/critical│
                    └─────────────┬────────────┘
                                  │
                ┌─────────────────┴─────────────────┐
                │                                   │
          severity==critical                  severity==warn
                │                                   │
                ▼                                   ▼
   ┌────────────────────────┐         ┌────────────────────────┐
   │ ③ 触发 emergency_stop() │         │ 标记 warn，继续运行     │
   │   - 切断正常控制流       │         │ 累计 N 帧升级 critical  │
   │   - 设置 is_in_safe_mode │         └────────────────────────┘
   └────────────┬───────────┘
                │
                ▼
   ┌────────────────────────┐
   │ ④ 输出急停指令          │
   │   throttle = 0          │  ← 停止加速
   │   brake    = MAX (1.0)  │  ← 最大制动
   │   steering = 0          │  ← 保持直行 / 回正
   │   steering_rate = 25°/s │  ← 快速回正速率
   └────────────┬───────────┘
                │
                ▼
   ┌────────────────────────┐
   │ ⑤ CANBUS / 执行器下发   │
   │   - CAN 帧发送          │
   │   - 制动系统响应 (~60ms) │
   │   - 刹车力度爬升到 MAX   │
   └────────────┬───────────┘
                │
                ▼
   ┌────────────────────────┐
   │ ⑥ 车辆减速至停止        │
   │   - 取决于初速度         │
   │   - 20km/h @ 0.5g ≈ 5m  │
   │   - 20km/h @ 1.0g ≈ 1.6m│
   └────────────┬───────────┘
                │
                ▼
   ┌────────────────────────┐
   │ ⑦ 保持停车状态          │
   │   - 持续下发 brake=MAX  │
   │   - 拒绝任何加速指令     │
   │   - 等待用户确认         │
   └────────────────────────┘
```

### 2.2 关键时间预算

从异常发生到车辆完全停止的时间链（以 Apollo Guardian 为典型）：

```
t = 0ms    异常发生（如 Planning 进程崩溃）
t = 10ms   Monitor 检测到 Planning 失联（1 个检测周期）
t = 20ms   Monitor 发布 SystemStatus（含 safety_mode_trigger_time）
t = 30ms   Guardian 接收 SystemStatus（10ms 周期）
t = 30ms   Guardian 触发安全模式，发布 GuardianCommand（brake=50%）
t = 40ms   Canbus 接收命令
t = 45ms   Canbus 通过 CAN 发送刹车命令
t = 60ms   车辆制动系统响应（机械延迟）
t = 100ms  刹车力度达到目标值
t = 100~2000ms  车辆减速至停止（取决于初速度）

总反应时间：~100ms（从崩溃到开始刹车）
```

这是 Apollo Guardian 的实测预算。AuroraDrive 在仿真模式下周期为 24Hz（~42ms），最坏反应时间约 84ms（2 帧）+ 渲染延迟。

### 2.3 三档停车力度

工业级系统通常区分三档停车，对应不同严重度：

| 档位 | 刹车力度 | 减速度 | 触发场景 | 舒适性 |
|------|---------|--------|---------|--------|
| **Soft Stop（软停）** | 25% | ~0.25g | 规划失败、通信中断、Monitor 触发但无紧急 | 高（平缓） |
| **Emergency Stop（急停）** | 50% | ~0.5g | Monitor 要求急停、超声波检测到障碍物、传感器故障 | 中（强烈减速） |
| **Hard Stop（硬停 / MAX）** | 100% | ~1.0g | 即将碰撞、TTC<临界、操作手急停按钮 | 低（最大制动，可能触发 ABS） |

Apollo Guardian 默认 emergency=50%、soft=25%；AuroraDrive 当前 `emergency_stop()` 直接返回 brake=1.0（100%），属于 Hard Stop 档位。

---

## 3. 触发条件

### 3.1 触发条件总表

| 大类 | 子类 | 典型表现 | 检测手段 | 严重度 | 典型系统响应 |
|------|------|---------|---------|--------|-------------|
| **传感器失效** | 帧无数据 | 相机/雷达 topic 无新消息 | 心跳超时（>2.5s） | critical | Emergency Stop |
| | 全黑/全白 | 图像像素方差=0 | 像素方差阈值 | critical | Emergency Stop |
| | 噪声突增 | 图像模糊、点云稀疏 | 梯度方差、点数阈值 | warn→critical | Soft Stop |
| | 漂移 | IMU 零偏累积 | 残差监测、双源差异 | warn→critical | Soft Stop |
| **模型失效** | 输出超界 | steer>1 / throttle<0 | 物理包络 clamp + 计数 | warn | Derate / Soft Stop |
| | 推理延迟 | inference_ms 超阈值 | 计时 + 滑窗 P99 | warn→critical | Soft Disable |
| | OOD | 输入偏离训练分布 | 置信度、ensemble 方差 | warn→critical | Soft Stop |
| | 输出不合理 | TTC<阈值却加速 | 语义一致性检查 | critical | Emergency Stop |
| **控制失效** | 无转向响应 | 命令≠反馈 | 命令-状态比对 | critical | Emergency Stop |
| | 无制动响应 | brake 命令≠减速度 | 命令-状态比对 | critical | Emergency Stop + 报警 |
| | 执行器饱和 | 持续满舵 / 满油门 | 持续时长计数 | warn→critical | Derate / Soft Stop |
| **通信失效** | 消息超时 | topic 长时间无新消息 | 心跳 / last_msg_age | warn→critical | Soft Stop → Emergency |
| | 丢包 | 帧号不连续 | frame_id 跳变 | warn | Derate |
| | 数据损坏 | checksum 不匹配 | CRC / SHA256 校验 | critical | Emergency Stop |
| **操作手干预** | 踩刹车踏板 | brake pedal > 阈值 | CAN 信号读取 | immediate | 立即 disengage（OpenPilot R1） |
| | 按取消键 | Cancel 按钮 | HMI 事件 | immediate | 立即 disengage |
| | 急停按钮 | 物理急停 | 硬件信号 | immediate | Hard Stop + 断电 |
| **即将碰撞** | TTC < 临界 | 前车急刹 | TTC = dist / rel_vel | critical | Emergency Stop / AEB |
| | 距离 < 安全距离 | RSS 违反 | RSS 公式判定 | critical | Proper Response（reasonable brake） |
| | 超声波近距 | <2.5m 障碍物 | 超声波雷达 | critical | Emergency Stop（硬件触发） |
| **系统崩溃** | 关键进程消失 | PID 不存在 | 进程监控 | critical | Emergency Stop |
| | 看门狗超时 | watchdog 未喂狗 | 硬件 watchdog | critical | Hard Stop / 复位 |
| **30 秒规则** | 驾驶员无响应 | DMS 检测走神 + 手离盘 | DMS + 计时 | warn→critical | 渐进告警 → Soft Disable → Emergency |

### 3.2 触发逻辑的 OR 与去抖

实际系统中触发条件不是裸 OR，而是**分级 + 去抖**：

1. **立即触发（immediate）**：操作手干预、即将碰撞、硬件急停——无去抖，单帧即触发。
2. **快速触发（critical，1~3 帧）**：传感器失效、控制失效、系统崩溃——短窗去抖防误触发。
3. **渐进触发（warn→critical，N 秒）**：30 秒规则、推理延迟、执行器饱和——先 warn 告警，持续升级才 critical。

AuroraDrive 当前 `FallbackDetector` 已实现分级（`severity = critical ? "critical" : (failures.empty() ? "none" : "warn")`）与部分去抖（`lane_departure_count_>=3`、`oscillation` 5 帧），但缺少"持续 N 秒 warn → 自动升级 critical"的渐进机制，也缺少传感器层与通信层异常的覆盖（详见 `07_fallback_detector.md`）。

---

## 4. Apollo Emergency Stop

### 4.1 Apollo Guardian 紧急刹车

Apollo 的 Emergency Stop 由 **Guardian 模块**统一执行。Guardian 是 Apollo 自动驾驶系统中的"最后一道安全防线"，作为 `TimerComponent` 以 100Hz（10ms 周期）独立运行，不依赖其他模块触发。

**核心职责**：
- 实时监控系统健康状态
- 检测 Control 模块失效
- 监控超声波传感器数据
- 触发安全模式（Safe Mode）
- 执行紧急停车（Emergency Stop）/ 软停车（Soft Stop）

**数据流**：

```
Monitor Module ──SystemStatus──> Guardian Module ──GuardianCommand──> Canbus Module
Control Module ──ControlCommand──>      │
Canbus  Module ──Chassis──────>         │
                                        ▼
                              ┌─────────────────────┐
                              │ 决策逻辑：           │
                              │ - 检查 Monitor 超时  │
                              │ - 检查安全模式触发   │
                              │ - 检查超声波障碍物   │
                              │ - 透传 OR 安全模式   │
                              └─────────────────────┘
```

### 4.2 触发条件（Guardian 侧）

Guardian 的触发条件就两条，但每条背后都连着 Monitor 的全套监控：

1. **Monitor 超时**：`Time::Now() - last_status_received_s_ > kSecondsTillTimeout`（2.5 秒未收到 SystemStatus）
2. **Monitor 主动触发**：`system_status_.has_safety_mode_trigger_time()`（SystemStatus 中含 `safety_mode_trigger_time` 字段）

Monitor 自身的触发则来自：模块进程消失、CyberRT 通道无更新、资源耗尽（CPU/内存）、定位/感知错误升级（`CRITICAL_ERROR` / `FATAL_ERROR`）。注释明确：*"ERROR and FATAL will trigger safety mode in current settings"*。

### 4.3 处理流程（`TriggerSafetyMode()`）

```cpp
// 第 1 轮：传感器与障碍物检测
if (传感器失效 || 超声波检测到 <2.5m 障碍物 || 超声波数据异常) {
    obstacle_detected = true;
}

// 第 1 轮控制命令设置（无论是否检测到障碍物）
guardian_cmd_.set_throttle(0.0);           // 油门归零
guardian_cmd_.set_steering_target(0.0);    // 转向回正
guardian_cmd_.set_steering_rate(25.0);     // 转向速率 25°/s
guardian_cmd_.set_is_in_safe_mode(true);   // 安全模式标志

// 第 2 轮：选择 Emergency Stop 还是 Soft Stop
if (system_status 申请 Emergency Stop || 传感器失效 || obstacle_detected) {
    guardian_cmd_.set_brake(guardian_conf_.guardian_cmd_emergency_stop_percentage());  // 50%
} else {
    guardian_cmd_.set_brake(guardian_conf_.guardian_cmd_soft_stop_percentage());       // 25%
}
```

**关键设计**：
- `throttle=0, brake=50 或 25, steering_target=0, steering_rate=25`——这正是任务书所要求的 `throttle=0, brake=MAX, steering=0` 的工业版（MAX 在 Apollo 里是 50% 而非 100%，出于舒适性考虑）。
- Guardian 为定时模块，会**持续下发**安全模式命令直到车辆停止，避免单帧下发后被覆盖。
- 10ms 周期最大增加 Control 命令 10ms 延迟。

### 4.4 透传模式（Pass-Through）

正常情况下 Guardian 处于透传模式，零延迟复制 ControlCommand：

```cpp
void GuardianComponent::PassThroughControlCommand() {
    std::lock_guard<std::mutex> lock(mutex_);
    guardian_cmd_.mutable_control_command()->CopyFrom(control_cmd_);
}
```

这是 Guardian 设计的精髓——**正常时不增延迟，异常时才接管**。

### 4.5 Planning 层的 Emergency Stop Scenario

除了 Guardian 的硬件级急停，Apollo Planning 模块还有软件级的 **EmergencyStopScenario**：

- **触发**：收到 `PadMessage::STOP` 命令（远程/手动下发）
- **行为**：主车计算停车距离，在**当前车道**直接减速停车
- **优先级**：高优先级场景（紧急情况）

与之对比的 **EmergencyPullOverScenario**：
- **触发**：收到 `PadMessage::PULL_OVER` 命令
- **行为**：就近找到合适位置**靠边停车**（比直接停车更安全）
- **适用**：行驶过程中需要停车但当前车道不安全

### 4.6 Dreamview 中的 e 键急停

Apollo Dreamview 提供手动急停：**按 e 键（大写）**可进行车辆紧急停车，默认执行 **50% 刹车**。官方建议测试时少用此功能（体感差），发生突发情况时及时用外接踩刹车踏板的方式。

### 4.7 冗余保护与多层防御

Apollo 采用纵深防御，Guardian 是第 4 层（共 5 层）：

```
L1 Planning  → L2 Control → L3 Monitor → L4 Guardian ⭐ → L5 Canbus/车辆
（规划失败）  （控制失败）  （监控触发）  （接管急停）    （CAN watchdog/ESP/ABS）
```

**故障树示例**：
- Planning 崩溃 → Monitor 检测 → Guardian 软停车（25%）
- Control 崩溃 → Monitor 检测 → Guardian 软停车（25%）
- **Monitor 崩溃 → Guardian 超时（2.5s）→ Guardian 紧急停车（50%）** ← 这是最关键的冗余：Guardian 不依赖 Monitor，Monitor 挂了 Guardian 自己也能兜底
- 即将碰撞 → 超声波检测 → Guardian 紧急停车（50%）
- 通信中断 → Guardian 超时 → Guardian 紧急停车（50%）

**ASIL 等级**：Guardian 设计满足 ISO 26262 部分要求，达 **ASIL-B**（中等安全完整性），未达 ASIL-D。局限性：依赖单一 Monitor 实例、超声波传感器未冗余、缺少硬件独立 watchdog。

---

## 5. OpenPilot Emergency Stop

### 5.1 OpenPilot 30 秒规则与渐进告警

OpenPilot（comma.ai）是 L2+ 辅助驾驶系统，其 Emergency Stop 哲学与 Apollo 截然不同——**它不主动急停，而是把控制权交还驾驶员**。OpenPilot 官方 `docs/SAFETY.md` 把自己定位为 *"failsafe passive system... driver alertness is necessary, but not sufficient"*（失效安全的被动系统，驾驶员警觉性必要但不充分）。

两条顶层安全要求：
- **R1**：驾驶员必须能**立即**夺回手动控制（踩刹车或按取消键）。
- **R2**：车辆不得过快改变轨迹——执行器被约束在合理限值内（横向 ISO 11270：0.9 秒最大作动达成 1m 横向偏移）。

**30 秒规则**（实际为渐进告警，非硬性 30 秒）的典型流程：

```
驾驶员走神 / 手离方向盘
        │
        ▼
  ① alert（提示，~1s）   → 屏幕黄色提示
        │ 持续未响应
        ▼
  ② warning（警告，~5s） → 屏幕红色警告 + 蜂鸣
        │ 持续未响应
        ▼
  ③ softDisable（软禁用，3s 倒计时）
     - soft_disable_timer = 300 步 @ 100Hz = 3 秒
     - 期间逐步退出控制，保留制动
        │ 倒计时结束
        ▼
  ④ overridden（强制人工接管）
     - openpilot 完全退出
     - 控制权回到原厂 ADAS / 驾驶员
        │ 仍无响应（极端情况）
        ▼
  ⑤ disabled（完全禁用）
     - panda controls_allowed = false
     - CAN 总线不再接受 openpilot 指令
```

### 5.2 driver disengage

OpenPilot 的"紧急停车"本质是 **driver disengage**（驾驶员脱离）——任何时候驾驶员都能立即夺回控制：

- **踩刹车踏板**：panda 通过 CAN 检测 brake pedal 信号 → 立即 `controls_allowed=false` → openpilot 退出，控制权回到原厂。这是 R1 的硬件级实现，**不经过应用层**，即使 openpilot 主 SoC 完全死机也有效。
- **按 Cancel 键**：原厂方向盘取消键 → 同上立即退出。
- **大转角方向盘输入**：检测到驾驶员主动转向 → overridden 状态。

### 5.3 Events 系统 + 状态机

OpenPilot 的异常检测核心是 **Events 系统**（`selfdrive/selfdrived/events.py`）。所有异常统一建模为 `Event`，每个 Event 有 `name` / `severity`（alert/warning/critical）/ `type`。`StateManager` 据此驱动状态机：

```
disabled ←──── user_disable / canTimeout / commIssue
   │
   ▼
enabled ──── softDisable ←── modeldLag / driverUnresponsive
   │            │
   │            ▼
   └────── overridden ←── steerUnavailable / brakeUnavailable / driverDistraction
                │
                ▼
            alertOff
```

典型映射：
- `canTimeout` / `commIssue` → 直接 `disabled`（通信异常）
- `modeldLag`（推理延迟超阈值）→ `softDisable`（模型异常，软退出保留制动）
- `steerUnavailable` / `brakeUnavailable` → `disabled`（控制异常）
- `driverUnresponsive`（DMS 走神 + 手离盘超时）→ `alert` → `warning` → `overridden`

### 5.4 panda 硬件安全关卡

OpenPilot 把安全切成两个执行域：

1. **应用域**（comma 设备主 SoC，Python/C++）：可崩溃、可重启，"善意但非充分"。
2. **功能安全域**（panda，STM32H725，C 固件）：汽车 CAN 总线与 openpilot 之间的**唯一强制关卡**，不可被 fork 改动。

panda 固件的 `safety_tick(1Hz)` 做滞后/心跳检测：若主 SoC 心跳停止 → `controls_allowed=false` → 控制权回到原厂。这就是"failsafe passive"的字面含义——**应用层挂了，硬件层自动交还控制权**。

### 5.5 OpenPilot 与 Apollo 的本质区别

| 维度 | Apollo Guardian | OpenPilot |
|------|----------------|-----------|
| 定位 | L4 主动急停 | L2+ 被动交还 |
| 急停动作 | throttle=0, brake=50%, steer=0 | 退出控制，由驾驶员/原厂接管 |
| 驾驶员角色 | 可选（无驾驶员也能停） | 必须（R1 立即夺回） |
| 硬件兜底 | 超声波 + CAN watchdog | panda STM32 + 原厂 ADAS |
| 失效哲学 | fail-operational（继续运行到停） | fail-safe（交还控制） |
| ASIL 等级 | ASIL-B | 遵循 ISO 26262 但非认证 |

---

## 6. NVIDIA Emergency Stop

### 6.1 DriveGuard 紧急处理

NVIDIA 官方公开文档中，**"DriveGuard"并非独立产品**，而是其安全监控/护栏机制集合的工程化称呼。在现代 NVIDIA 体系中，这一角色由三层共同承担，并于 2025 年 GTC 统一收编进 **NVIDIA Halos** 综合安全系统：

1. **片内层**：FSI（Functional Safety Island，功能安全岛）集中监控 SoC 安全错误
2. **片外层**：Safety MCU（Infineon Aurix TC297，ASIL-D）+ 外部 Safety Watchdog
3. **算法层**：Safety Force Field（SFF）数学护栏

### 6.2 Safety MCU 触发

NVIDIA 的 Emergency Stop 由 **Safety MCU + FSI 双重触发**：

- **FSI（片内）**：4 组 Lockstep（锁步）Cortex-R52 核对 + 1 个 Cortex-R5F。锁步核同步执行同一指令流，输出经比较器实时比对，**任一比特不一致即触发安全中断**（单时钟周期检出 CPU 故障）。FSI 提供 ~10K ASIL D DMIPS 算力，可集中监控 SoC 内部安全错误。
- **Safety MCU（片外）**：Infineon Aurix TC297（ASIL-D）+ 外部 Safety Watchdog。主 SoC 失效时由 Safety MCU 触发 **MRC（Minimum Risk Condition，最小风险状态）**——即 Emergency Stop + 靠边停车。

**触发流程**：

```
主 SoC 内部故障
   │
   ▼
FSI Lockstep 比较器检出比特不一致
   │
   ▼
触发安全中断 → FSI 上报 Safety MCU
   │
   ▼
Safety MCU 判定不可恢复
   │
   ▼
触发 MRC（Minimum Risk Condition）
   │
   ├──→ 下发 brake=MAX 到执行器
   ├──→ 通知原厂 ADAS 接管横向
   └──→ 点亮危险报警灯
   │
   ▼
车辆进入稳定停止状态
```

### 6.3 Safety Force Field（SFF）

SFF 是 NVIDIA 的算法层 Emergency Stop 触发器，基于 RSS 思想的实时碰撞避免层。它独立于主规划器，对感知-规划输出做"前方可达范围"安全校验：

- 一旦预测轨迹会侵犯其他道路使用者的安全包络 → **立即接管制动**
- 数学可证明零碰撞（mobileye 曾指责 NVIDIA SFF 抄袭其 RSS 模型，指出数十处与 RSS 2017 论文相似的部分）
- 兼顾制动 + 转向限制，不仅是刹车

SFF 相当于给系统装了一个"**数学上可证明安全**的底线"——即使主规划器完全失效，SFF 也能强制 Proper Response。

### 6.4 Fail-safe vs Fail-operational

| 模式 | 定义 | 适用等级 | NVIDIA 实现 |
|------|------|----------|-------------|
| **Fail-safe** | 失效后转入安全状态（靠边停车/制动停车） | L2/L3 | Safety MCU + FSI 触发 MRC |
| **Fail-operational** | 失效后仍能以降级模式继续运行一段时间 | L3+/L4 | 双 SoC 冗余 + Thor 异构隔离，单模块失效后剩余算力可支撑安全行驶约 **3 秒**（足以完成高速紧急变道） |

Hyperion 9 平台采用**双 Thor 通道**主备冗余，实现 fail-operational。Thor 芯片"三明治"异构架构：底层 Blackwell GPU 做 AI 推理、中层 ASIC 处理传感器信号、顶层 CPU 集群做决策控制。硬件隔离保证任一模块故障时，剩余算力仍可支撑车辆安全行驶。

### 6.5 ASIL D 认证

- **DriveOS 6.0**：通过 ISO 26262 **ASIL D** 认证，可从 CPU 扩展到 GPU
- **DRIVE AGX SoC（Orin/Thor）**：芯片本体 ASIL-D Random + 系统级 ASIL D；片内 FSI 单独做到完整 ASIL D（含系统性失效）。这就是 NVIDIA 反复强调的 **"岛屿与水"类比**——岛（FSI）是完整 ASIL D 的安全陆地，水（GPU/AI 计算域）是 ASIL-D Random 的海洋
- **DRIVE AGX Hyperion 平台**：2025 年 1 月通过 TÜV SÜD 与 TÜV Rheinland 双机构功能安全 + 网络安全评估，业内首个端到端双评估平台

---

## 7. Mobileye RSS Emergency

### 7.1 RSS Proper Response

Mobileye 的 Responsibility-Sensitive Safety（RSS，2017）不是"异常检测器"，而是一套**"应该怎么做才不担责"的数学模型**。它定义了四种危险场景（纵向同向、纵向对向、横向、行人），为每种场景定义安全距离与安全响应（Proper Response）。

RSS 的"紧急情况"定义是**"距离 < Safe Distance"**——这是一个纯几何/运动学的判定，与模型无关、与传感器无关。它的价值在于：即使感知完全正确、规划完全合理，只要 RSS 判定危险，就强制 Proper Response。

### 7.2 两大公理

1. **不要成为事故的原因（Do not cause an accident / blame）**：自动驾驶汽车永不因自身原因引发碰撞，只可能被卷入事故而非肇责。
2. **不要疏忽（Do not be negligent / inattentive）**：当潜在风险由他人造成时，必须做出"合理的反应"（Proper Response），避免本可避免的事故。

### 7.3 紧急情况处理（Proper Response）

**纵向安全距离**（同向行驶，定义 1）：

```
d_min^long = max{ 0,
    v_r · ρ + ½ · a_{max,accel} · ρ²
    + (v_r + ρ · a_{max,accel})² / (2 · a_{min,brake})
    − v_f² / (2 · a_{max,brake})
}
```

各项物理含义：
- `v_r · ρ`：后车在反应时间 ρ 内匀速行驶距离
- `½ · a_{max,accel} · ρ²`：后车在反应时间内仍以最大加速度加速走过的距离（**最坏意图假设**——RSS 不信任任何车辆的意图）
- `(v_r + ρ·a_{max,accel})² / (2·a_{min,brake})`：后车反应结束后以"最小合规刹车"刹停的距离
- `v_f² / (2·a_{max,brake})`：前车以"最大可能刹车"急刹所缩短的距离

**Proper Response 触发**：一旦实际距离 `d < d_min^long`，后车必须执行 **"合理制动"（reasonable brake）**——即不早于、不晚于合理时机。RSS 不要求最大制动，而是要求"合理"制动，这与 Apollo Guardian 的 50% 刹车理念一致。

### 7.4 RSS 紧急情况与 Emergency Stop 的关系

RSS Proper Response 是 **Emergency Stop 的数学触发器**：

| 维度 | RSS Proper Response | Apollo Emergency Stop |
|------|---------------------|----------------------|
| 触发依据 | 数学公式（d < d_min） | 系统状态（Monitor/Guardian） |
| 制动强度 | reasonable brake（合理） | 50% 或 25%（配置） |
| 可证明性 | 数学可证明不肇责 | 工程经验值 |
| 适用场景 | 纵向/横向/行人 | 系统失效 + 即将碰撞 |
| 局限 | 不感知传感器失效 | 不数学证明 |

理想方案是**两者结合**：RSS 管行车安全（数学底线），Guardian 管系统安全（工程底线）。NVIDIA SFF 正是这种结合的产物。

### 7.5 RSS 演进

RSS 后续演进为 **Mobileye SuperVision / Ride** 中的 RSS+（加了场景泛化）和 **DSSC（Dynamic Scenario Coverage）**。Mobileye 称：基于 RSS 已收集 2 亿公里实际行驶数据，将假阳性出现概率降至万分之 2.5（每 5 万公里一次），并在 10 万次路测模拟中以 10Hz 频率响应，零事故。

---

## 8. AuroraDrive Emergency Stop

### 8.1 当前 `emergency_stop()` 实现

AuroraDrive 的 Emergency Stop 实现极简，位于 `cpp/include/ad/autonomy.h:263-265`：

```cpp
// 终极兜底：急刹 + 双闪
inline std::array<float, 3> emergency_stop() noexcept {
    return {0.0f, 0.0f, 1.0f};
}
```

返回 `std::array<float, 3>`，语义为 `[steer, throttle, brake]`：
- `steer = 0.0`：转向回正（保持直行）
- `throttle = 0.0`：油门归零（停止加速）
- `brake = 1.0`：刹车满量程（MAX 制动，对应 Apollo 的 100% / Hard Stop 档）

注释标注"急刹 + 双闪"，但当前实现**只返回控制量，并未实际触发双闪**（双闪需在 simulator 侧额外置位 hazard 灯标志）。

### 8.2 触发条件

AuroraDrive 的 `emergency_stop()` 在两处被调用：

**① 仿真主循环（`simulator.h:387-394`）**——FallbackDetector 判定 critical 时：

```cpp
auto health = fallback_detector_.check(...);
if (health.severity == "critical") {
    auto e = emergency_stop();  // 急刹 (0,0,1)
    r.steer = e[0]; r.throttle = e[1]; r.brake = e[2];
} else {
    auto c = clamp_command({r.steer, r.throttle, r.brake}, safety_env_);
    ...
}
```

FallbackDetector 触发 critical 的判据（详见 `07_fallback_detector.md`）：
- `no_road`：道路中心点 <2（无路可走）
- `front_collision_imminent`：TTC < 1.5s 且 brake < 0.3（即将碰撞却未刹车）

**② AutonomyStack 级联仲裁（`autonomy.h:947-951`）**——规则层与模型层双失效时：

```cpp
if (rule_failed) {
    if (model_ok) {
        chosen = {h.steer, h.throttle, h.brake};
    } else {
        chosen = emergency_stop();   // 规则+模型都失效 → 急停
        fallback_();
    }
}
```

**③ HTTP API（`http_server.h:323-325`）**——用户手动触发：

```cpp
} else if (path == "/api/assist/emergency_stop") {
    if (on_assist_emergency) on_assist_emergency();
    send_json(fd, 200, R"({"ok":true})");
}
```

前端 / Tauri 命令可通过 `POST /api/assist/emergency_stop` 手动触发急停。

### 8.3 当前实现的问题

| 问题 | 描述 | 影响 |
|------|------|------|
| **无渐进告警** | critical 直接急停，无 warn → critical 升级 | 误触发体验差，可能不必要急停 |
| **无停车保持** | 急停后未持续下发 brake=MAX | 仿真中可能漂移，真机中可能溜车 |
| **无恢复流程** | 急停后无明确的"等待确认 → 复位 → 重启"流程 | 系统可能卡在急停状态 |
| **无双闪联动** | 注释说"双闪"但未实际触发 | 后车无警示 |
| **brake=1.0 过激** | 直接 100% 制动，无 Soft Stop 档 | 高速下可能触发 ABS / 失控 |
| **无硬件触发** | 仅依赖 FallbackDetector 软件判定 | 传感器断流时可能漏触发 |
| **无 30 秒规则** | 无驾驶员无响应渐进告警 | 辅助驾驶模式下安全隐患 |
| **无通信超时触发** | FallbackDetector 不监控 topic 心跳 | 通信中断时仍用陈旧数据决策 |

---

## 9. 紧急停车恢复

### 9.1 停车保持

Emergency Stop 触发后，系统必须**持续保持停车状态**，不能因为单帧下发后被覆盖而溜车：

- **Apollo Guardian**：定时模块（100Hz），持续下发 GuardianCommand 直到车辆停止 + 系统重启
- **OpenPilot**：panda `controls_allowed=false` 后硬件级锁死，必须驾驶员主动操作才能恢复
- **NVIDIA**：Safety MCU 锁定 MRC 状态，必须复位

### 9.2 用户确认

恢复必须经用户确认，防止系统自动恢复后再次进入危险状态。典型确认方式：

| 系统 | 确认方式 |
|------|---------|
| Apollo | Dreamview 终端输入 `start` 命令 → 恢复 `lane follow` 场景 |
| OpenPilot | 驾驶员踩油门 / 按 Set 键重新 enable |
| NVIDIA | 系统复位（重启动力系统） |
| SAE L3 MRM | 必须重新启动动力系统才能再次激活 |
| SAE L4 MRM | 允许自主处置且无重启限制 |

### 9.3 重启流程

**Apollo 恢复流程**（典型）：

```
车辆处于 Emergency Stop 状态（brake=50%, is_in_safe_mode=true）
        │
        ▼
用户在 Dreamview 终端输入 "start"
        │
        ▼
HMI 下发 PadMessage::START
        │
        ▼
Planning 模块收到 START → 退出 EmergencyStopScenario
        │
        ▼
切换回 LaneFollowScenario（默认驾驶场景）
        │
        ▼
Control 恢复正常轨迹跟踪
        │
        ▼
Guardian 收到 SystemStatus（无 safety_mode_trigger_time）
        │
        ▼
Guardian 切换回透传模式（PassThroughControlCommand）
        │
        ▼
车辆恢复正常驾驶
```

### 9.4 系统复位

更严重的故障（如 Safety MCU 触发 MRC）需要完整系统复位：

1. **状态清零**：FallbackDetector.reset()、stuck_timer_=0、lane_departure_count_=0
2. **控制源重置**：source_ = ControlSource::PURE_RULE（回到最保守源）
3. **相位重置**：phase_ = Phase::FULL_AUTO 或 CO_DRIVE
4. **历史清空**：steer_history_.clear()、模型推理缓存清空
5. **健康自检**：FallbackDetector 首帧必须返回 severity==none 才能恢复

---

## 10. AuroraDrive 迁移建议（Emergency Stop 升级方案）

### 10.1 借鉴 Apollo Guardian

**升级点 ①：独立 Guardian 组件**

将 `emergency_stop()` 从 `autonomy.h` 内联函数升级为独立的 `GuardianComponent` 类，以固定频率（如 24Hz 匹配仿真周期）独立运行，不依赖 FallbackDetector 触发：

```cpp
class GuardianComponent {
    // 独立监控
    bool check_monitor_timeout() { return now - last_status_s_ > 2.5; }
    bool check_operator_intervention() { return brake_pedal_ > 0.3; }
    bool check_ultrasonic_obstacle() { return min_dist_ < 2.5; }

    // 三档停车
    enum class StopLevel { NONE, SOFT, EMERGENCY, HARD };
    StopLevel decide_level();
    ControlCommand build_stop_command(StopLevel lvl);
};
```

**升级点 ②：三档停车力度**

替代当前固定 `brake=1.0`，引入 Soft / Emergency / Hard 三档：

```cpp
inline std::array<float, 3> emergency_stop(StopLevel lvl = StopLevel::EMERGENCY) noexcept {
    switch (lvl) {
        case StopLevel::SOFT:       return {0.0f, 0.0f, 0.25f};  // 25%，规划失败
        case StopLevel::EMERGENCY:  return {0.0f, 0.0f, 0.50f};  // 50%，传感器故障
        case StopLevel::HARD:       return {0.0f, 0.0f, 1.00f};  // 100%，即将碰撞
        default:                    return {0.0f, 0.0f, 0.00f};
    }
}
```

**升级点 ③：透传模式**

正常情况下 Guardian 透传 Control 命令，零延迟；异常时才接管。这避免 Guardian 成为性能瓶颈。

**升级点 ④：2.5 秒超时冗余**

不依赖 FallbackDetector，独立监控关键 topic 心跳：simulator 状态、控制器输出、感知帧。任一超时 2.5s 即触发 Emergency Stop。

### 10.2 借鉴 OpenPilot 30 秒规则

**升级点 ⑤：渐进告警状态机**

为辅助驾驶模式引入 OpenPilot 风格的渐进告警：

```cpp
enum class DriverAlertState { NORMAL, ALERT, WARNING, SOFT_DISABLE, OVERRIDDEN };

class DriverMonitor {
    DriverAlertState state_ = DriverAlertState::NORMAL;
    int warn_timer_ = 0;  // 帧计数

    void update(bool distracted, bool hands_off, float dt) {
        if (distracted || hands_off) {
            warn_timer_++;
            if (warn_timer_ > 60)       state_ = DriverAlertState::OVERRIDDEN;   // ~2.5s @ 24Hz
            else if (warn_timer_ > 30)  state_ = DriverAlertState::SOFT_DISABLE; // ~1.25s
            else if (warn_timer_ > 12)  state_ = DriverAlertState::WARNING;      // ~0.5s
            else                         state_ = DriverAlertState::ALERT;
        } else {
            warn_timer_ = 0;
            state_ = DriverAlertState::NORMAL;
        }
    }
};
```

**升级点 ⑥：driver disengage**

辅助驾驶模式下，任何驾驶员主动操作（踩刹车 / 打方向 / 按 Esc）应立即 disengage，不等渐进告警。这是 OpenPilot R1 原则的本地化。

**升级点 ⑦：failsafe passive 定位**

辅助驾驶模式明确"failsafe passive"定位——系统失效时交还控制权给用户（键盘注入停止），而非主动急停（急停在游戏场景中不必要且突兀）。仿真模式才适用主动急停。

### 10.3 借鉴 NVIDIA Safety MCU

**升级点 ⑧：硬件级 watchdog 概念**

虽然 AuroraDrive 是仿真系统无真车硬件，但可引入"软件 watchdog"概念：

- 独立线程以 10Hz 检查主仿真循环是否在 100ms 内更新过状态
- 若超时 → 强制 `emergency_stop()` 并通知前端
- watchdog 线程独立于 simulator 主循环，主循环挂掉时仍能工作

**升级点 ⑨：Fail-operational 降级链**

借鉴 NVIDIA fail-operational，AuroraDrive 已有的降级链 `PURE_RULE → FULL_AUTO → CO_DRIVE` 应延伸到 Emergency Stop：

```
PURE_RULE（正常）→ FULL_AUTO（规则失效）→ CO_DRIVE（模型失效）→ EMERGENCY_STOP（双失效）→ HOLD（停车保持）→ RESET（用户确认）→ PURE_RULE
```

### 10.4 借鉴 Mobileye RSS Proper Response

**升级点 ⑩：RSS 数学触发器**

在 FallbackDetector 的 `check_collision_` 判据中引入 RSS 安全距离公式，替代简单的 TTC 阈值：

```cpp
// 当前：TTC < 1.5s 即 critical
// 升级：d < d_min_rss 即 critical（更严格的数学底线）
float d_min_rss = ego_speed_ms * rho + 0.5f * a_max_accel * rho * rho
                + std::pow(ego_speed_ms + rho * a_max_accel, 2) / (2 * a_min_brake)
                - std::pow(front_speed_ms, 2) / (2 * a_max_brake);
if (*fd < d_min_rss) { critical = true; }
```

### 10.5 完整升级方案：EmergencyStop v2

整合上述借鉴，给出 AuroraDrive Emergency Stop v2 完整设计：

```cpp
// autonomy.h 升级版
enum class StopLevel { NONE, SOFT, EMERGENCY, HARD };
enum class StopReason {
    NONE, NO_ROAD, COLLISION_IMMINENT, SENSOR_FAILURE,
    MODEL_FAILURE, CONTROL_FAILURE, COMM_TIMEOUT,
    OPERATOR_INTERVENTION, DRIVER_UNRESPONSIVE, RSS_VIOLATION
};

struct EmergencyStopState {
    StopLevel level = StopLevel::NONE;
    StopReason reason = StopReason::NONE;
    bool hold = false;              // 停车保持
    bool hazard = false;            // 双闪
    int hold_frames = 0;            // 保持帧计数
    bool user_confirmed = false;    // 用户确认恢复
};

class EmergencyStopController {
public:
    // 24Hz 调用
    EmergencyStopState update(const FallbackDetector::RuleHealth& health,
                              const DriverMonitorState& dms,
                              float brake_pedal,
                              const ChannelHealth& channels) {
        EmergencyStopState s;

        // ① 立即触发：操作手干预 / 硬件急停
        if (brake_pedal > 0.3f) {
            return {StopLevel::HARD, StopReason::OPERATOR_INTERVENTION, true, true};
        }

        // ② RSS 数学触发：距离 < 安全距离
        if (rss_violated_) {
            return {StopLevel::EMERGENCY, StopReason::RSS_VIOLATION, true, true};
        }

        // ③ FallbackDetector critical
        if (health.severity == "critical") {
            StopLevel lvl = (health.front_collision_imminent || health.no_road)
                          ? StopLevel::HARD : StopLevel::EMERGENCY;
            return {lvl, map_reason(health), true, true};
        }

        // ④ 通信超时（独立于 FallbackDetector）
        if (channels.any_timeout(2.5f)) {
            return {StopLevel::EMERGENCY, StopReason::COMM_TIMEOUT, true, true};
        }

        // ⑤ 驾驶员无响应渐进告警
        if (dms.state == OVERRIDDEN) {
            return {StopLevel::SOFT, StopReason::DRIVER_UNRESPONSIVE, true, false};
        }

        // ⑥ 停车保持（已触发急停）
        if (active_) {
            s.hold = true;
            s.hazard = true;
            s.hold_frames++;
            // 等待用户确认
            if (user_confirmed_) { reset(); }
        }

        return s;
    }

private:
    bool active_ = false;
    bool rss_violated_ = false;
    bool user_confirmed_ = false;
    void reset() noexcept { active_ = false; user_confirmed_ = false; }
};
```

**流程图**：

```
                    ┌────────────────────────────┐
                    │ EmergencyStopController.update() 24Hz │
                    └──────────────┬─────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
   brake_pedal>0.3            rss_violated            health.severity==critical
   (操作手干预)               (RSS 数学底线)          (FallbackDetector)
        │                          │                          │
        ▼                          ▼                          ▼
   HARD Stop                  EMERGENCY Stop            HARD/EMERGENCY Stop
   brake=1.0                  brake=0.5                 brake=0.5/1.0
        │                          │                          │
        └──────────────────────────┼──────────────────────────┘
                                   │
                                   ▼
                    ┌────────────────────────────┐
                    │ 设置 active_=true, hold=true │
                    │ hazard=true（双闪）          │
                    │ 持续下发 brake=MAX           │
                    └──────────────┬─────────────┘
                                   │
                                   ▼
                    ┌────────────────────────────┐
                    │ 等待 user_confirmed_        │
                    │ （HTTP /api/assist/resume） │
                    └──────────────┬─────────────┘
                                   │
                                   ▼
                    ┌────────────────────────────┐
                    │ reset() → 状态清零          │
                    │ FallbackDetector.reset()    │
                    │ source_ = PURE_RULE         │
                    │ 恢复正常驾驶                 │
                    └────────────────────────────┘
```

### 10.6 升级优先级

按投入产出比排序的升级优先级：

| 优先级 | 升级项 | 投入 | 收益 |
|--------|--------|------|------|
| P0 | 三档停车力度（Soft/Emergency/Hard） | 低 | 高（避免不必要急停） |
| P0 | 停车保持（hold + 持续下发） | 低 | 高（防漂移/溜车） |
| P0 | 用户确认 + 恢复流程 | 中 | 高（避免卡死） |
| P1 | 双闪联动（hazard 标志） | 低 | 中（警示后车） |
| P1 | 通信超时独立触发 | 中 | 高（覆盖传感器断流） |
| P1 | 软件 watchdog 独立线程 | 中 | 高（主循环挂掉时兜底） |
| P2 | RSS 数学触发器 | 中 | 中（数学底线） |
| P2 | 渐进告警状态机（30 秒规则） | 高 | 中（辅助驾驶模式） |
| P2 | driver disengage（辅助模式） | 中 | 中（OpenPilot R1） |
| P3 | 独立 GuardianComponent | 高 | 中（架构清晰度） |

### 10.7 与现有模块的协同

Emergency Stop v2 不是孤立模块，需与现有 AuroraDrive 安全栈协同：

- **FallbackDetector**：作为 EmergencyStopController 的主要输入源（health.severity）
- **SafetyEnvelope**：在 EmergencyStop 输出后仍做最终 clamp（保证不超物理极限）
- **AutonomyStack**：`emergency()` 方法（`autonomy.h:982-985`）改为调用 EmergencyStopController
- **HTTP Server**：新增 `/api/assist/resume` 端点用于用户确认恢复
- **前端 UI**：急停时显示红色"EMERGENCY STOP"覆盖层 + 恢复按钮

---

## 11. 总结

Emergency Stop 是自动驾驶系统的"最后一脚刹车"，其设计核心是**多源触发、分级处理、持续保持、用户恢复**。

- **Apollo Guardian** 给出工业级模板：独立组件、100Hz 监控、透传/安全模式双模、Soft/Emergency 双档、2.5s 超时冗余、ASIL-B 认证。
- **OpenPilot** 给出 L2+ 哲学：failsafe passive、driver disengage、30 秒渐进告警、panda 硬件关卡、应用域/功能安全域双隔离。
- **NVIDIA Halos** 给出最重方案：FSI 锁步核 + Safety MCU + SFF 数学护栏、fail-operational 双 SoC 冗余、ASIL-D 全栈认证。
- **Mobileye RSS** 给出数学底线：Proper Response、Safe Distance、不肇责公理、白盒可验证。
- **AuroraDrive 当前**：`emergency_stop()` 极简（`{0,0,1}`）、无渐进、无保持、无恢复，需升级到 v2。

AuroraDrive Emergency Stop v2 升级方案的核心是：**借鉴 Apollo 三档停车 + 停车保持，借鉴 OpenPilot 渐进告警 + driver disengage，借鉴 NVIDIA watchdog 独立线程，借鉴 RSS 数学触发器**，在保持仿真系统简洁性的同时，补齐工业级 Emergency Stop 的关键缺口。

---

## 参考资料

- Apollo Guardian 源码解析：https://cloud.tencent.com/developer/article/1999057
- Apollo Guardian 模块详解：https://blog.csdn.net/qq_31762031/article/details/156396241
- Apollo guardian 紧急处置：https://blog.csdn.net/qq_32378713/article/details/128126473
- Apollo Planning 场景插件：https://blog.csdn.net/qq1240268067/article/details/148082392
- Apollo 远程启动车辆：https://blog.csdn.net/weixin_46052663/article/details/139002854
- Apollo 项目场景化应用：https://blog.csdn.net/u010632343/article/details/150989272
- OpenPilot selfdrived 守护进程：https://blog.csdn.net/2301_80171004/article/details/150771695
- OpenPilot 安全模型（本地研究）：`OpenPilot研究/02s_safety_model.md`
- panda safety 源码研究（本地）：`OpenPilot研究/02z_panda_safety.md`
- NVIDIA Halos 安全：https://www.nvidia.cn/ai-trust-center/halos/autonomous-vehicles/
- NVIDIA 安全报告解析：https://blog.csdn.net/m0_56661101/article/details/147403527
- NVIDIA FSI 功能安全岛：https://juejin.cn/post/7330165211523055625
- NVIDIA Safety Force Field：https://m.elecfans.com/article/889041.html
- NVIDIA 安全力场专利：https://m.toutiao.com/group/7646814404269212223/
- NVIDIA 安全设计研究（本地）：`NVIDIA研究/06_nvidia_safety.md`
- Mobileye RSS 模型研究（本地）：`纯规则研究/01_mobileye_rss.md`
- Mobileye RSS 原始论文：https://arxiv.org/abs/1708.06374
- SAE J3206 MRC 定义：https://m.antpedia.com/standard/8467428-9.html
- 自动驾驶 MRM 详解：https://www.42how.com/en/article/2493
- Mobileye 自动驾驶分级：https://m.12365auto.com/news/20230913/512626.shtml
- fail-safe vs fail-operational：https://www.eet-china.com/mp/a168438.html
- AuroraDrive FallbackDetector 研究（本地）：`纯规则研究/07_fallback_detector.md`
- AuroraDrive Safety Envelope 研究（本地）：`纯规则研究/06_safety_envelope.md`
- AuroraDrive 安全设计说明（本地）：`chapters/29_安全设计说明.md`
- AuroraDrive 项目交接文档（本地）：`AuroraDrive项目交接文档.md`

---

> 实际工具调用次数：53 次（1 次 LS + 28 次 WebSearch + 5 次 WebFetch + 12 次 Read/Grep 本地文件 + 7 次其他）
> 字数：约 8500 字（中文字符）
