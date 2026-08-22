# 06 · Safety Envelope 设计深度研究（输出 clamp / 限幅 / 边界保护）

> 研究主题：自动驾驶系统中 Safety Envelope（安全包络）的设计方法，覆盖输出 clamp、限幅策略、边界保护，并对 Apollo Guardian、OpenPilot steer_limited_by_safety、NVIDIA DriveGuard / Safety Force Field、Autoware Safety 四大开源/工业方案进行源码级拆解，最后给出 AuroraDrive 现有 SafetyEnvelope 的升级方案。
>
> 研究方法：WebSearch + WebFetch 检索 Apollo / OpenPilot / NVIDIA / Autoware / Mobileye / Aurora 公开资料与 CSDN 源码解析，结合 AuroraDrive 项目 cpp/include/ad/autonomy.h 现有实现进行对照分析。

---

## 1. Safety Envelope 概述

### 1.1 定义

**Safety Envelope（安全包络）** 是自动驾驶控制栈中位于"规划/控制算法输出"与"执行器物理下发"之间的**最后一道软件安全防线**。它的核心职责是：无论上游算法（PID / LQR / MPC / 神经网络）产生什么指令，包络层都要保证下发到执行器（转向、油门、刹车）的量值始终落在物理可行、动力学稳定、乘员舒适的边界之内。

与"功能安全"（ISO 26262，管硬件/软件失效）和"预期功能安全"（ISO 21448 SOTIF，管算法能力不足）不同，Safety Envelope 属于**运行时输出约束层**：它不诊断"为什么错了"，只在"错误已经发生时"把错误输出钳制到安全范围。它假设上游可能出错，因此对所有输出做无条件约束。

### 1.2 输出 clamp / 限幅 / 边界保护三层概念

| 概念 | 作用层 | 触发时机 | 行为 | 类比 |
|------|--------|----------|------|------|
| **边界保护（Boundary Protection）** | 静态设计 | 编译期/配置期 | 定义物理边界（MAX_STEER / MAX_THROTTLE / 速度上限 / 加速度上限） | 道路的护栏 |
| **限幅策略（Limiting Strategy）** | 运行时策略 | 接近边界（软）/ 超过边界（硬）/ 紧急条件 | 软限幅告警、硬限幅钳制、紧急限幅急停 | 限速牌 + 减速带 + 急刹 |
| **输出 clamp（输出钳制）** | 运行时执行 | 每帧无条件 | cmd = clamp(cmd, lo, hi) 数值钳制 | 物理闸门 |

三者是**递进关系**：边界保护定义"红线在哪"，限幅策略定义"接近红线怎么办"，输出 clamp 是"无论如何都不能越线"的最终数值保证。一个完整的 Safety Envelope 必须同时具备这三层，缺一不可——只有 clamp 没有 soft/hard 策略会导致控制突变（阶跃式钳制引发 jerk 尖峰），只有策略没有 clamp 则在策略失效时无兜底。

### 1.3 与 Guardian 的关系

**Guardian（守护者）** 是 Safety Envelope 的一种**主动监控实现形态**，由 Apollo 系统提出并命名。两者的关系可总结为：

- **Safety Envelope 是概念，Guardian 是实现**：Safety Envelope 描述"应该做什么"（约束输出），Guardian 描述"具体怎么做"（独立进程 + 监控 + 接管）。
- **Guardian 是 Safety Envelope 的"主动版"**：普通 Safety Envelope 是被动的数值钳制（每帧 clamp），Guardian 是主动的——它监控整个系统健康状态，在检测到上游失效时主动接管（emergency stop / soft stop），而不仅仅是钳制。
- **层级关系**：Control 输出 → Safety Envelope（数值 clamp）→ Guardian（健康监控 + 接管）→ CANBUS / 执行器。Guardian 通常位于 clamp 之后，作为更高层的安全仲裁者。

在 Apollo 中，Guardian 模块是"最后一道安全防线"，相当于保险丝的熔断作用；在 OpenPilot 中，等价角色由 panda 硬件安全模型 + steer_limited_by_safety 闭环承担；在 NVIDIA 中由 Safety Force Field（SFF）承担；在 Autoware 中由 motion_velocity_*_module 系列 + vehicle_cmd_gate 承担。

---

## 2. 输出 clamp 设计

输出 clamp 是 Safety Envelope 的数值执行核心。一个完整的 clamp 设计需要覆盖所有控制自由度，并区分**归一化边界**与**物理边界**两个层次。

### 2.1 转向 clamp（MAX_STEER）

转向是最容易引发危险的自由度（高速大转角→侧滑/翻车），因此转向 clamp 必须多层：

1. **物理最大转角 MAX_STEER**：由车辆转向系机械极限决定，通常 ±500°~±900° 方向盘角，或 ±35°~±45° 前轮角。Apollo 在 vehicle_param 中配置 max_steer_angle；OpenPilot 在 CarControllerParams 中按车系定义 MAX_STEER（如 Honda 0x1000 torque units）。
2. **归一化转向**：上层控制器输出 steer ∈ [-1, 1]，由 max_steer 反归一化到物理量。AuroraDrive PurePursuit 即采用 r.steer = clamp_val(steer_rad / pp.max_steer, -1.0f, 1.0f)。
3. **转向速率 clamp（steer_rate）**：限制单帧转向变化量，防止阶跃式打方向引发 jerk 尖峰。Apollo Guardian 在安全模式下设置 set_steering_rate(25.0)（25°/s），AuroraDrive dynamics.h 中用速度自适应横摆角速度限制（低速 ±1.5 rad/s，高速 ±0.5 rad/s）间接限制转向速率。
4. **激进上限 cap**：在全自动驾驶阶段额外收紧。AuroraDrive full_auto_steer_cap = 0.9f，即全自段转向不超过 90% 满量程，留 10% 余量给人工接管。

### 2.2 油门 clamp（MAX_THROTTLE）

油门 clamp 相对简单，因为油门只增不害（除非超速）：

1. **物理上限**：throttle ∈ [0, 1]（归一化百分比），Apollo 用 throttle_minimum_action 设死区，calibration_table 把加速度映射到 throttle 百分比。
2. **速度自适应限幅**：高速时收紧油门上限，防止超速。Apollo control_conf 中 speed_controller_input_limit = 1.5（±1.5 m/s² 输入限制）间接限制油门。
3. **互锁**：油门与刹车互斥——throttle > 0 时 brake 必须为 0。OpenPilot panda safety 与 AuroraDrive emergency_stop()（返回 {0, 0, 1}）都遵循此约束。

### 2.3 刹车 clamp（MAX_BRAKE）

刹车 clamp 需要区分**舒适刹车**与**紧急刹车**两个力度：

1. **舒适刹车上限**：日常减速用，通常对应 -2.0~-3.0 m/s²，避免乘员不适。Apollo Guardian 的 soft_stop_percentage 即此级别。
2. **紧急刹车上限**：AEB 级别，可达 -6~-10 m/s²（法规上限约 -10 m/s²，再大会触发 ABS 且乘员受伤风险上升）。Apollo emergency_stop_percentage 与 AuroraDrive emergency_stop()（brake=1.0 满量程）属于此级别。
3. **刹车死区**：brake_minimum_action 防止微小刹车抖动，Apollo 配置为 0.0（无死区）或小正值。
4. **静止保持刹车**：停车后维持小刹车力防溜车。Apollo standstill_acceleration = -0.3 m/s²、standstill_narmal_acceleration = -0.5 m/s²。

### 2.4 jerk clamp（急动度限幅）

jerk（急动度，加速度的导数，单位 m/s³）是衡量乘坐舒适性的核心指标。jerk clamp 限制加速度的变化率，避免"猛踩/猛松"带来的前仰后合：

- **舒适 jerk 上限**：业界共识纵向 jerk ≤ 2.0~3.0 m/s³，横向 jerk ≤ 1.0~2.0 m/s³。
- **实现方式**：在加速度输出后加一阶低通滤波器（Apollo digital_filter）或速率限制器。Apollo 纵向控制用 DigitalFilter 平滑加速度指令，等效 jerk clamp。
- **AuroraDrive 现状**：未显式实现 jerk clamp，靠 PID 的 out_alpha 低通滤波（prev_out_ = out_alpha * out + (1-out_alpha) * prev_out_）间接平滑，但无硬 jerk 边界。

### 2.5 加速度 clamp

加速度 clamp 限制纵向/横向加速度的绝对值：

- **纵向加速度**：舒适上限 ±2.0 m/s²，紧急上限 -6~-10 m/s²（刹车）/ +2~+3 m/s²（油门）。
- **横向加速度**：舒适上限 3.0 m/s²（乘员开始有侧倾感），极限上限 6~8 m/s²（接近轮胎抓地极限，超此易侧滑）。Mobileye RSS 与 NVIDIA SFF 都以横向加速度上限作为安全距离计算的输入。
- **AuroraDrive 关键设计取舍**：源码注释明确写道——"物理加速度（m/s²）不在此处限制，由 BicycleModel 的 throttle/brake→accel 映射（simulator: accel = throttle*3.0 - brake*5.0）+ clamp_command 的 [0,1] 钳制共同兜底。原 accel_limit/full_auto_accel_cap 为死字段（从未被读取），删除以消除'伪安全'印象"。这是典型的**归一化 clamp 兜底物理量**的简化设计——在仿真语境下可行，但真车迁移时必须补显式加速度 clamp。

---

## 3. 限幅策略

限幅策略定义"接近/超过边界时如何响应"，分为软、硬、紧急三级。

### 3.1 软限幅（warning）

**触发条件**：输出接近边界（如 |steer| > 0.8 * steer_limit）但未越界。
**行为**：仅告警，不修改输出。让上游算法知道"快到边界了"，有机会主动回退。
**典型实现**：Apollo Monitor 模块的 system_status 报告；Autoware behavior_velocity_planner 在接近停止点前提前减速（非硬切）；AuroraDrive FallbackDetector 的 severity="warning" 级别。
**价值**：避免硬限幅导致的控制突变，给系统"软着陆"机会。

### 3.2 硬限幅（clamp）

**触发条件**：输出超过边界。
**行为**：直接钳制到边界值，丢弃越界部分。
**典型实现**：clamp_command() 每帧无条件执行；Apollo calibration_table 查表把超限加速度截断；OpenPilot clip_curvature 把期望曲率钳制到物理可行范围。
**风险**：硬限幅会丢失积分信息→引发 windup（见第 6 节）。必须配合饱和检测与积分冻结。
**AuroraDrive 实现**：clamp_command 是纯硬限幅，无饱和反馈闭环。

### 3.3 紧急限幅（emergency stop）

**触发条件**：检测到严重异常（碰撞风险 TTC<阈值、传感器失效、控制模块超时、驾驶员紧急干预）。
**行为**：覆盖所有正常输出，下发固定紧急指令（全刹 + 转向归零 + 双闪）。
**典型实现**：
- Apollo Guardian TriggerSafetyMode()：根据 emergency_stop_percentage 或 soft_stop_percentage 设置刹车。
- AuroraDrive emergency_stop()：返回 {0.0f, 0.0f, 1.0f}（steer=0, throttle=0, brake=1.0 满刹）。
- AEB：TTC < 临界值时主动制动，减速度可达 -6~-10 m/s²。
**与硬限幅区别**：紧急限幅是**状态切换**（进入 emergency 模式并保持），硬限幅是**单帧钳制**（下一帧仍正常计算）。

### 3.4 限幅触发条件汇总

| 条件类型 | 具体判据 | 触发限幅级别 | 来源 |
|----------|----------|--------------|------|
| 数值越界 | steer/throttle/brake > limit | 硬限幅 | 所有系统 |
| 超时 | Control 心跳丢失 > 2.5s（Apollo）/ > N 帧 | 紧急限幅 | Apollo Guardian |
| 传感器失效 | 超声波/雷达/GPS 异常 | 紧急限幅 | Apollo Guardian |
| 近距障碍 | 2.5m 内有障碍物 | 紧急限幅 | Apollo Guardian |
| TTC 临界 | TTC < 1.5s | 紧急限幅 | AuroraDrive FallbackDetector / AEB |
| 曲率超限 | curvature > 0.3 rad/m | 软→硬限幅 | AuroraDrive FallbackDetector |
| 速度超限 | v > speed_limit | 硬限幅（油门） | 所有系统 |
| 振荡 | 5 帧内转向翻转 ≥3 次 | 紧急限幅 | AuroraDrive FallbackDetector |
| 卡死 | throttle>0.05 且速度无增长 | 紧急限幅 | AuroraDrive FallbackDetector |
| 驾驶员干预 | 刹车/油门上升沿 | 紧急限幅（退出 AUTO） | OpenPilot driver_disengage |

---

## 4. 边界保护

边界保护是 Safety Envelope 的静态设计层，定义"红线在哪"。完整的边界保护应覆盖运动学四维。

### 4.1 速度边界

- **上限**：法定限速 + 车辆物理极限（AuroraDrive dynamics.h 硬编码 180 km/h = 50 m/s 上限）。Apollo 由 Planning 模块根据道路限速 + 曲率计算 speed_limit。
- **下限**：0（不允许倒车，除非显式倒车场景）。Apollo standstill_acceleration 维持静止。
- **速度边界与曲率耦合**：弯道前必须减速，使横向加速度 a_lat = v²/R ≤ 3.0 m/s²。Apollo use_steering_check 启用转向联动检查，转弯时自动降速。

### 4.2 加速度边界

| 加速度类型 | 舒适范围 | 极限范围 | 用途 |
|------------|----------|----------|------|
| 纵向加速 | +1.0~+2.0 m/s² | +3.0 m/s² | 油门 |
| 纵向减速 | -2.0~-3.0 m/s² | -6~-10 m/s² | 刹车/AEB |
| 横向加速度 | ±2.0~3.0 m/s² | ±6~8 m/s² | 转向 |
| 静止保持 | -0.3~-0.5 m/s² | -0.5 m/s² | 防溜车 |

Apollo 纵向控制 speed_controller_input_limit = 1.5 限制 PID 输入（等效加速度限幅）；Mobileye RSS 用横向加速度上限 a_lat,max 计算横向安全距离；NVIDIA SFF 同时考虑纵向与横向加速度边界做碰撞避免。

### 4.3 转向角边界

- **物理极限**：前轮转角 ±35°~45°，方向盘 ±500°~900°。AuroraDrive kMaxSteer 常量定义。
- **速度自适应**：低速放宽（泊车需大转角），高速收紧（高速大转角→侧滑）。AuroraDrive dynamics.h 的横摆角速度限制（低速 ±1.5 rad/s，高速 ±0.5 rad/s）等效此机制。
- **转向速率**：Apollo Guardian 安全模式 steering_rate=25.0（25°/s），防止突变。
- **全自段收紧**：AuroraDrive full_auto_steer_cap=0.9f，留 10% 余量。

### 4.4 距离边界

距离边界是 Safety Envelope 与感知/规划的安全接口：

- **纵向安全距离**：Mobileye RSS 定义"最恶劣情况下的避撞距离"——前车以最大减速度刹车，后车反应时间内仍加速，再以最小减速度刹车，能刚好不碰撞。公式：d_min = v_front²·ρ + v_rear·ρ·reaction + 0.5·a_max·reaction² + (v_rear + a_max·reaction)²/(2·b_min) - v_front²/(2·b_max)。
- **横向安全距离**：变道时与旁车保持的横向间距，由横向加速度上限与反应时间推导。
- **静止距离**：Apollo Guardian 超声波 2.5m 内有障碍即触发紧急限幅。
- **TTC 边界**：TTC < 1.5s（AuroraDrive TTC_CRITICAL）触发紧急限幅。

---

## 5. Apollo Guardian

### 5.1 设计概述

Apollo Guardian 是 Apollo 自动驾驶系统中**最后一道安全防线**，作为安全监护者负责监控系统状态并在异常情况下接管车辆控制。它位于 Control 模块与 CANBUS 模块之间：

```
Control 模块 ──ControlCommand──▶ Guardian ──GuardianCommand──▶ CANBUS
                                    ▲
                                    │ system_status
                                 Monitor 模块
```

Guardian 是 TimerComponent，定时触发（配置文件指定 10ms 一次，即 100Hz）。核心职责：实时监控系统健康状态、检测 Control 模块失效、监控超声波传感器数据、触发安全模式（Safe Mode）、执行紧急停车（Emergency Stop）与软停车（Soft Stop）。

### 5.2 输出异常检测

Guardian 的异常检测有两个数据源：

1. **Monitor 模块的 system_status**：Monitor 监控硬件（ESD CAN / GPS / Resource / SocketCAN）与软件（模块状态 / 数据完整性 / 数据频率 / 系统资源 CPU/内存/磁盘），汇总成 system_status。Guardian 据此判断是否需要紧急停车。
2. **超时检测**：Proc() 中指定 timeout = 2.5s，若状态接收时延 > 2.5s，safety_mode_triggered = true。这个 2.5s 是关键阈值——超过此即认为 Control 或 Monitor 已失效。

### 5.3 紧急刹车机制

TriggerSafetyMode() 执行两轮判断 + 两轮控制命令设置：

**第 1 轮判断（传感器失效 vs 障碍物检测）**：
- 传感器（UltraSonic 超声波）失效判据：传感器未正常使能 / 传感器自身异常。
- 障碍物检测判据：2.5m 范围内有障碍物 / 超声波数据异常 → 障碍物标志位置 true。

**第 1 轮控制命令设置**（复位油门转向）：
```cpp
guardian_cmd_.mutable_control_command()->set_throttle(0.0);      // 油门归零
guardian_cmd_.mutable_control_command()->set_steering_target(0.0); // 转向归零
guardian_cmd_.mutable_control_command()->set_steering_rate(25.0);  // 转向速率 25°/s
guardian_cmd_.mutable_control_command()->set_is_in_safe_mode(true);
```

**第 2 轮判断（Emergency Stop vs Soft Stop）**：
- system_status 申请 Emergency Stop / 传感器失效 / 近距障碍 → **Emergency Stop**
- 否则 → **Soft Stop**

**第 2 轮控制命令设置**（设置刹车力度）：
```cpp
// Emergency Stop
guardian_cmd_.mutable_control_command()->set_brake(
    guardian_conf_.guardian_cmd_emergency_stop_percentage());
// Soft Stop
guardian_cmd_.mutable_control_command()->set_brake(
    guardian_conf_.guardian_cmd_soft_stop_percentage());
```
两者区别仅在刹车百分比——Emergency Stop 力度大，Soft Stop 柔和。

### 5.4 透传模式

若 safety_mode_triggered == false，Guardian 调用 PassThroughControlCommand()，**包装透传** ControlCommand 到 CANBUS。也就是说，正常情况下 Guardian 是透明的，只在异常时才接管。这是 Guardian 与普通 Safety Envelope 的关键区别——它是"平时透明、异常接管"的主动监控者，而非每帧都钳制的被动 gate。

### 5.5 冗余保护

Guardian 的冗余体现在：
- **数据源冗余**：Control 命令 + Monitor system_status + 超声波数据，三路独立。
- **超时冗余**：2.5s 超时兜底 Monitor 失效。
- **CANBUS 隔离**：开启 FLAGS_receive_guardian 后，CANBUS 不再直接订阅 ControlCommand，只订阅 GuardianCommand，保证 Control 失效时 Guardian 仍能下发安全命令。

---

## 6. OpenPilot steer_limited_by_safety

### 6.1 设计概述

OpenPilot 的 Safety Envelope 分散在多层，其中 steer_limited_by_safety 是**横向控制饱和检测闭环**的核心。它解决一个关键问题：当安全模型（panda 硬件）clamp 了转向指令后，如何告诉上层控制器"你被限幅了"，以避免积分饱和（windup）。

### 6.2 steer_limited_by_safety 检测

在 controlsd.py 中，每帧比较"控制器期望输出"与"panda 实际下发"：

```python
if self.sm['selfdriveState'].active:
    CO = self.sm['carOutput']
    if self.CP.steerControlType == car.CarParams.SteerControlType.angle:
        # 角度控制模式：比较期望转向角与实际转向角
        self.steer_limited_by_safety = abs(CC.actuators.steeringAngleDeg - CO.actuatorsOutput.steeringAngleDeg) > 2.5
    else:
        # 扭矩控制模式：比较期望扭矩与实际扭矩
        self.steer_limited_by_safety = abs(CC.actuators.torque - CO.actuatorsOutput.torque) > 1e-2
```

carOutput 是 panda 实际下发到 CAN 的值（可能被安全模型 clamp 过）。比较"controlsd 期望"与"panda 实际"，超过阈值（角度模式 2.5°，扭矩模式 0.01）说明被 clamp。

### 6.3 饱和检测

steer_limited_by_safety 是布尔标志，下一帧被两个横向控制器消费：

1. **LatControlPID**：freeze_integrator = steer_limited_by_safety or ... → 冻结积分，防止 windup。
2. **LatControlTorque**：饱和计数 _check_saturation 累加，达阈值后上报 steerSaturated 事件。

### 6.4 积分冻结

积分冻结是抗 windup 的关键。当转向被安全模型 clamp 时，若积分继续累加误差，一旦 clamp 解除，积分项会输出巨大过冲。OpenPilot 的做法是：**被 clamp 期间冻结积分**（不增不减），等 clamp 解除后再恢复累加。

这与经典抗 windup 方法一致：
- **积分限幅（Integral Clipping）**：直接限制积分项大小，达到上下限后不再增减。AuroraDrive controller.h 的 integral_ = clamp_val(integral_, -i_clamp, i_clamp) 即此方法。
- **积分暂停（Integral Freeze / Hold）**：输出饱和时暂停累加。OpenPilot 用此方法。
- **反算抗饱和（Back-calculation Anti-windup）**：饱和时用 (饱和输出 - 未饱和输出) 反馈修正积分。

OpenPilot 选择 freeze 而非 clipping，因为 freeze 更保守——被 clamp 期间积分完全不变化，避免任何潜在过冲。

### 6.5 安全限制层级

OpenPilot 的转向安全限制共 4 层（从软到硬）：

1. **clip_curvature**：在 LatControl.update() 中把期望曲率钳制到物理可行范围（基于车速与横向加速度上限）。
2. **accel_limits**：纵向加速度上下限，由 LongControl 状态机管理。
3. **NaN/Inf 兜底**：任何数值异常 → 0.0，防止 NaN 传播到执行器。
4. **Panda 硬件安全模型**：独立 MCU 上的白名单 + 扭矩/速率限制 + controls_allowed 门控，软件再怎么出错硬件兜底。

steer_limited_by_safety 正是连接第 1 层（软件 clamp）与第 4 层（硬件 clamp）的反馈闭环——它检测第 4 层是否真的 clamp 了，并反馈给第 1 层的积分器。

---

## 7. NVIDIA DriveGuard / Safety Force Field

### 7.1 DriveGuard 设计

NVIDIA 的安全架构围绕 **DRIVE Hyperion** 平台展开，其安全设计可概括为"DriveGuard = Safety Force Field + 冗余硬件 + ASIL-D 流程"：

- **冗余 SoC**：DRIVE Hyperion 8 采用冗余 NVIDIA DRIVE Orin 系统级芯片，即使一台计算机发生故障，备份设备仍能确保自动驾驶汽车将乘客安全带到目的地。
- **冗余传感器**：12 个外部摄像头 + 9 个雷达 + 12 个超声波 + 1 个前置激光雷达 + 3 个内部摄像头，多样化传感器套件提供 360° 冗余覆盖。
- **ASIL-D + ISO 21434**：2025 年 1 月通过 TÜV SÜD 与 TÜV Rheinland 的功能安全与网络安全评估，符合 ASIL-D 功能安全等级与 ISO 21434 网络安全标准。
- **安全岛（FSI）**：Orin 内置功能安全岛，可为任何安全功能（传感器融合、车辆控制等）提供约 10K ASIL D MIPS，减少外部 MCU 的 MIPS 需求。

### 7.2 Safety Force Field（SFF）

SFF 是 NVIDIA DRIVE AV 软件套件的核心安全组件，是一套**计算型防御驾驶策略**：

- **数学严谨性**：SFF 基于物理学计算，逐帧对传感器数据做基于碰撞避免的计算，而非依赖有限统计数据。目标是"数学上零碰撞验证"。
- **兼顾制动与转向**：SFF 独特之处在于同时考虑制动和转向限制。此双重考虑消除了只考虑单一自由度时可能出现的异常车辆行为（如只刹车不转向导致追尾，或只转向不刹车导致冲出车道）。
- **核心原则**：遵循"避免碰撞"这一核心原则，而非遵守大量规则与期望。SFF 监控并预防不安全操作——使配备 SFF 的车辆像磁铁一样相互排斥，彼此保持安全距离，且不会助长不安全情况。
- **开放平台**：SFF 可与任何驾驶软件结合，作为运动规划堆栈中的安全决策策略。它让避障机制从复杂的道路规则机制中独立出来。
- **冗余层**：SFF 在 NVIDIA DRIVE 高性能计算平台上运行时，为平台再增加一层分集和冗余功能。

### 7.3 安全监控

NVIDIA 的安全监控体现在硬件冗余 + 软件仲裁：

- **硬件冗余**：双 Orin 互为备份，任一失效另一接管。
- **传感器冗余**：摄像头 + 雷达 + 激光雷达 + 超声波多模态融合，单模态失效不影响整体感知。
- **SFF 仲裁**：SFF 作为独立安全决策层，监控规划层输出，若检测到不安全操作则强制修正。

### 7.4 异常处理

NVIDIA 的异常处理遵循 ASIL-D 流程：
- **故障检测**：硬件级 BIST（内建自测）、ECC、锁步核检测硬件故障。
- **故障隔离**：FSI 隔离安全相关计算与非安全计算。
- **降级运行**：任一 SoC/传感器失效，系统降级到冗余通道，继续安全运行而非直接停车。
- **安全状态**：极端失效下进入安全状态（最小风险策略 MRM），如靠边停车。

---

## 8. Autoware Safety

### 8.1 设计概述

Autoware 的 Safety 设计**不集中在单一 Guardian 模块**，而是分散在规划层的多个 motion_velocity_*_module 与 behavior_velocity_*_module 中，再由 vehicle_cmd_gate 做最终命令门控。这是一种"分布式安全 + 集中门控"的架构。

### 8.2 输出限制模块群

Autoware Universe 的安全相关模块主要包括：

1. **autoware_motion_velocity_dynamic_obstacle_stop_module**：负责动态障碍物的检测和处理，计算停止点，确保与动态障碍物的安全距离。流程：障碍物过滤 → 碰撞检测 → 停止决策 → 输出停止点。
2. **autoware_motion_velocity_obstacle_velocity_limiter_module**：根据障碍物情况计算速度限制，实现速度曲线的平滑处理。通过前向投影预测潜在碰撞，动态调整车辆速度以确保安全距离。流程：障碍物检测（点云处理 + 占用栅格分析 + 障碍物分类）→ 速度限制计算（碰撞风险评估 + 安全距离计算 + 速度上限确定）→ 轨迹调整（重采样 + 速度平滑 + 安全性验证）。
3. **autoware_motion_velocity_out_of_lane_module**：处理车辆偏离车道的情况，计算减速点，确保车辆在安全区域内行驶。
4. **autoware_behavior_velocity_occlusion_spot_module**：检测视线被遮挡的区域（盲区），预测可能从遮挡区域突然出现的行人，计算安全速度以避免碰撞，实现预防性制动。用 TTV（Time to Vehicle）与 TTC（Time to Collision）两个时间指标做风险评估。
5. **vehicle_cmd_gate**：最终命令门控，多源切换（autonomous / joystick / MRM），是 Autoware 的 Safety Envelope 执行点。

### 8.3 输出限制策略

Autoware 的输出限制是**规划级预防**而非控制级钳制：

- **预防性制动**：在 occlusion_spot_module 中，检测到盲区后不是等碰撞再刹，而是提前减速到"即使有行人冲出也能刹停"的安全速度。
- **前向投影**：obstacle_velocity_limiter 用前向投影预测未来轨迹与障碍物的潜在碰撞，提前调整速度。
- **平滑处理**：所有速度限制都经过轨迹重采样与速度平滑，避免阶跃式减速。
- **多模块串联**：多个 motion_velocity_*_module 串联处理，每个模块只负责一类安全场景，最后汇总成安全速度曲线。

### 8.4 紧急处理

Autoware 的紧急处理通过 vehicle_cmd_gate 的 MRM（Minimal Risk Manoeuvre）通道实现：

- **多源命令切换**：autonomous（正常）/ joystick（遥控）/ MRM（最小风险）三路命令，gate 根据系统状态选择下发哪一路。
- **MRM 触发**：检测到不可恢复故障时，切换到 MRM 通道，执行靠边停车或就地停车。
- **lane_departure_checker**：检测车道偏离，触发降级。

与 Apollo Guardian 的"主动接管 + 紧急刹车"不同，Autoware 更偏向"规划级预防 + 命令门控"——它在规划层就把不安全速度过滤掉，控制层只做执行。

---

## 9. AuroraDrive SafetyEnvelope 现状

### 9.1 现有实现（cpp/include/ad/autonomy.h）

AuroraDrive 当前的 SafetyEnvelope 是一个**极简的归一化数值钳制**实现：

```cpp
struct SafetyEnvelope {
    float steer_limit = 1.0f;            // |steer| ≤ 1
    float throttle_limit = 1.0f;         // throttle ∈ [0,1]
    float brake_limit = 1.0f;            // brake ∈ [0,1]
    float full_auto_steer_cap = 0.9f;   // 全自段转向激进上限（phase_veto 检查）
};

inline std::array<float, 3> clamp_command(std::array<float, 3> cmd,
                                          const SafetyEnvelope& env) noexcept {
    return {
        clamp_val(cmd[0], -env.steer_limit, env.steer_limit),
        clamp_val(cmd[1], 0.0f, env.throttle_limit),
        clamp_val(cmd[2], 0.0f, env.brake_limit),
    };
}

// 终极兜底：急刹 + 双闪
inline std::array<float, 3> emergency_stop() noexcept {
    return {0.0f, 0.0f, 1.0f};  // steer=0, throttle=0, brake=1.0 满刹
}
```

### 9.2 clamp 实现分析

clamp_command 是纯硬限幅，特点：

1. **归一化边界**：steer ∈ [-1,1]，throttle ∈ [0,1]，brake ∈ [0,1]，全部归一化。物理量限制由下游 BicycleModel 的 accel = throttle*3.0 - brake*5.0 映射兜底。
2. **无物理量 clamp**：源码注释明确——"物理加速度（m/s²）不在此处限制，由 BicycleModel 的 throttle/brake→accel 映射 + clamp_command 的 [0,1] 钳制共同兜底。原 accel_limit/full_auto_accel_cap 为死字段（从未被读取），删除以消除'伪安全'印象"。
3. **无 jerk clamp**：依赖 PID 的 out_alpha 低通滤波间接平滑，无显式 jerk 边界。
4. **无饱和反馈**：clamp 后不告知上游"你被限幅了"，存在 windup 风险（虽然 AuroraDrive PID 用 integral_ = clamp_val(integral_, -i_clamp, i_clamp) 做了积分限幅，但无 freeze 机制）。

### 9.3 emergency_stop 实现

emergency_stop() 返回固定的 {0.0f, 0.0f, 1.0f}——转向归零、油门归零、刹车满量程。这是一个**无条件急刹**，无 Soft Stop 区分。调用路径：

- AutonomyStack 在 severity==critical 且无模型备份时调用 emergency_stop()。
- emergency() 方法包装为 ControlCommand 供上层调用。
- HTTP API /api/assist/emergency_stop 可远程触发。

### 9.4 phase_veto 相位化否决

AuroraDrive 独有的是 phase_veto() 机制，按相位（CO_DRIVE / FULL_AUTO / RULE_ONLY）差异化否决：

```cpp
inline std::pair<bool, std::string> phase_veto(std::array<float, 3> cmd,
                                               std::array<float, 3> rule_cmd,
                                               Phase phase,
                                               const SafetyEnvelope& env) noexcept {
    constexpr float kVetoTolerance = 0.05f; // 共驾偏离容差
    // CO_DRIVE: 偏离规则即否
    // FULL_AUTO: 只否不安全/超激进上限
    // RULE_ONLY: 永不否
    if (phase == Phase::FULL_AUTO) {
        if (std::abs(steer) > env.steer_limit || throttle > env.throttle_limit
            || brake > env.brake_limit) {
            return {true, "exceeds_physics_envelope"};
        }
        if (std::abs(steer) > env.full_auto_steer_cap) {
            return {true, "exceeds_full_auto_aggressive_cap"};
        }
    }
    // ...
}
```

这是一个**相位感知的软限幅**——FULL_AUTO 阶段额外检查 full_auto_steer_cap=0.9，比纯 clamp 更精细。但否决后直接 chosen = rule_cmd（回退到规则输出），若规则输出也异常则无第二道 clamp 兜底（实际上 clamp_command 会在更下游执行）。

### 9.5 FallbackDetector 失效检测

FallbackDetector 是 AuroraDrive 的"轻量 Guardian"，纯规则失效检测：

```cpp
class FallbackDetector {
    static constexpr float MAX_CURVATURE = 0.3f;       // rad/m
    static constexpr float MIN_SPEED_LIMIT = 5.0f;     // km/h
    static constexpr float TTC_CRITICAL = 1.5f;        // s
    static constexpr int   OSCILLATION_WINDOW = 5;     // 帧
    static constexpr int   OSCILLATION_FLIPS = 3;      // 次
    static constexpr float STUCK_THROTTLE = 0.05f;
    static constexpr float COLLISION_BRAKE = 0.3f;
    // 检测项：curvature超限 / 速度超限 / TTC临界 / 振荡 / 卡死 / 车道偏离
};
```

检测项包括曲率超限、速度超限、TTC 临界、振荡（5 帧内转向翻转 ≥3 次）、卡死（throttle>0.05 但速度无增长）、车道偏离。severity==critical 时触发降级（CO_DRIVE）或 emergency_stop()。

### 9.6 现状评估

| 维度 | AuroraDrive 现状 | 差距 |
|------|------------------|------|
| 数值 clamp | ✅ 归一化 [-1,1] clamp | 无物理量 clamp（加速度/jerk） |
| emergency_stop | ✅ 固定 {0,0,1} | 无 Soft/Emergency 区分 |
| 相位化否决 | ✅ phase_veto | 独有优势，但仅 FULL_AUTO 检查 |
| 失效检测 | ✅ FallbackDetector | 纯规则，无硬件/通信监控 |
| 饱和反馈 | ❌ 无 | 无 steer_limited_by_safety 闭环 |
| 积分冻结 | ❌ 无 | 仅积分限幅，无 freeze |
| 超时检测 | ❌ 无 | 无心跳/通信健康检测 |
| 速度自适应 | ⚠️ 间接 | 横摆角速度限制间接限转向，无显式速度-转向耦合 clamp |
| Soft Stop | ❌ 无 | emergency_stop 无力度分级 |
| 冗余 | ❌ 无 | 单进程，无独立 Guardian |

**核心结论**：AuroraDrive SafetyEnvelope 是"够用但单薄"的最小实现——归一化 clamp + 固定 emergency_stop + 相位化否决构成了基本安全闭环，但缺少物理量 clamp、饱和反馈、超时检测、Soft/Emergency 分级等关键能力。在仿真语境下可接受，真车迁移前必须升级。

---

## 10. AuroraDrive 迁移建议

基于对 Apollo Guardian、OpenPilot steer_limited_by_safety、NVIDIA DriveGuard/SFF、Autoware Safety 的研究，给出 AuroraDrive SafetyEnvelope 的分阶段升级方案。

### 10.1 借鉴 Apollo Guardian

**核心借鉴点**：独立监控 + 超时检测 + Soft/Emergency 分级。

1. **引入 Soft Stop 与 Emergency Stop 分级**：
   ```cpp
   inline std::array<float, 3> soft_stop() noexcept {
       return {0.0f, 0.0f, 0.5f};  // 50% 刹车，柔和
   }
   inline std::array<float, 3> emergency_stop() noexcept {
       return {0.0f, 0.0f, 1.0f};  // 满刹
   }
   ```
   触发条件区分：TTC 临界 / 振荡 / 卡死 → Soft Stop；传感器失效 / 超时 / 碰撞即将发生 → Emergency Stop。

2. **引入超时检测**：在 AutonomyStack::step() 中记录上次 rule_input 时间戳，若 > 2.5s（沿用 Apollo 阈值）未更新，自动 emergency_stop()。这能兜底"线程崩了静默失效"。

3. **引入转向速率 clamp**：在 clamp_command 后加速率限制，防 jerk 尖峰：
   ```cpp
   struct SafetyEnvelope {
       // ... 现有字段
       float steer_rate_limit = 0.1f;  // 单帧（1/24s）转向变化上限
   };
   // clamp_command 中：steer = clamp_val(steer, prev_steer - rate, prev_steer + rate)
   ```

4. **借鉴 Guardian 的"平时透明、异常接管"模式**：AuroraDrive 的 phase_veto 已有此思想（FULL_AUTO 才否决），可进一步把 emergency_stop 包装成独立"安全仲裁器"，只在异常时覆盖正常输出。

### 10.2 借鉴 OpenPilot steer_limited_by_safety

**核心借鉴点**：饱和检测闭环 + 积分冻结。

1. **引入 steer_limited 标志**：在 clamp_command 中记录是否发生 clamp：
   ```cpp
   struct ClampResult {
       std::array<float, 3> cmd;
       bool steer_limited;
       bool throttle_limited;
       bool brake_limited;
   };
   inline ClampResult clamp_command_ex(std::array<float, 3> cmd,
                                        const SafetyEnvelope& env) noexcept {
       float s = clamp_val(cmd[0], -env.steer_limit, env.steer_limit);
       return {{s, clamp_val(cmd[1], 0.0f, env.throttle_limit),
                clamp_val(cmd[2], 0.0f, env.brake_limit)},
               std::abs(s - cmd[0]) > 1e-4f,
               cmd[1] > env.throttle_limit,
               cmd[2] > env.brake_limit};
   }
   ```

2. **PID 积分冻结**：在 controller.h 的 PID::step 中接受 freeze_integrator 参数：
   ```cpp
   float step(float setpoint, float pv, float dt, bool freeze_integrator = false) {
       float err = setpoint - pv;
       float deriv = first_ ? 0.0f : (err - prev_err_) / std::max(dt, 1e-6f);
       first_ = false;
       if (!freeze_integrator) {  // 仅在未冻结时累加
           integral_ += err * dt;
           integral_ = clamp_val(integral_, -i_clamp, i_clamp);
       }
       // ...
   }
   ```
   调用方传入 clamp_result.steer_limited，被 clamp 期间冻结积分。

3. **饱和事件上报**：连续 N 帧 steer_limited==true 时，通过 FallbackDetector 上报 steerSaturated 事件，触发降级（FULL_AUTO → CO_DRIVE）。

### 10.3 借鉴 NVIDIA DriveGuard

**核心借鉴点**：SFF 数学安全验证 + 物理量 clamp。

1. **补显式加速度 clamp**：这是 AuroraDrive 当前最大的"伪安全"隐患。建议在 SafetyEnvelope 加物理量字段：
   ```cpp
   struct SafetyEnvelope {
       // 现有归一化字段...
       float max_accel = 3.0f;       // m/s²，纵向加速上限
       float min_accel = -6.0f;      // m/s²，纵向减速上限（舒适）
       float emergency_decel = -10.0f; // m/s²，紧急减速上限
       float max_lat_accel = 3.0f;   // m/s²，横向加速度上限
       float max_jerk = 2.0f;        // m/s³，jerk 上限
   };
   ```
   在 clamp_command 后加物理量校验层，把归一化 cmd 反算成加速度，clamp 到物理边界。

2. **借鉴 SFF 的"兼顾制动与转向"**：AuroraDrive 当前 emergency_stop 只刹不转（steer=0），但高速时纯刹可能不够——应允许紧急限幅时保留少量转向（避障）。可设计 emergency_stop_with_steering(steer_offset) 变体。

3. **引入安全距离验证**：借鉴 SFF 与 RSS 的思想，在 FallbackDetector 中加"前向投影"——预测未来 1s 轨迹，若与障碍物 TTC < 阈值，提前触发 Soft Stop 而非等 TTC_CRITICAL 才 Emergency Stop。

### 10.4 借鉴 Autoware Safety

**核心借鉴点**：规划级预防 + 命令门控。

1. **引入 vehicle_cmd_gate 思想**：在 AutonomyStack 输出与 clamp_command 之间加命令门控层，支持多源切换（rule / model / emergency / manual），按优先级选择下发哪一路。
2. **预防性减速**：借鉴 occlusion_spot_module，在 FallbackDetector 中加盲区检测——感知到遮挡区域时提前减速到"即使有障碍冲出也能刹停"的速度，而非等检测到障碍再刹。
3. **平滑速度限制**：所有 FallbackDetector 触发的减速都应经过轨迹级平滑（借鉴 obstacle_velocity_limiter 的速度平滑），避免阶跃式刹车。

### 10.5 AuroraDrive SafetyEnvelope 升级方案（综合）

**分三阶段升级**：

**阶段 1（短期，仿真内即可完成）**：
1. 补 steer_rate_limit 转向速率 clamp（防 jerk 尖峰）。
2. 补 steer_limited 饱和检测标志 + PID 积分冻结（防 windup）。
3. 补 Soft Stop 与 Emergency Stop 分级（soft_stop() 返回 0.5 刹车，emergency_stop() 保持 1.0）。
4. 补超时检测（rule_input > 2.5s 未更新 → emergency_stop）。

**阶段 2（中期，真车迁移前必须完成）**：
5. 补显式物理量 clamp（max_accel / min_accel / max_lat_accel / max_jerk）。
6. 补速度自适应转向限幅（低速放宽、高速收紧，显式而非间接）。
7. 补前向投影 TTC 预测（提前 Soft Stop，减少 Emergency Stop 触发）。
8. 补饱和事件上报与降级（连续饱和 → FULL_AUTO 降 CO_DRIVE）。

**阶段 3（长期，真车量产级）**：
9. 引入独立 Guardian 进程/线程，"平时透明、异常接管"。
10. 引入心跳与通信健康检测（all_alive / all_freq_ok）。
11. 引入硬件安全模型（panda 等价物），软件 clamp 之外加硬件兜底。
12. 引入冗余通道（双 Control / 双传感器），任一失效另一接管。

**升级后的 SafetyEnvelope 结构示意**：

```cpp
struct SafetyEnvelope {
    // 归一化边界（现有）
    float steer_limit = 1.0f;
    float throttle_limit = 1.0f;
    float brake_limit = 1.0f;
    float full_auto_steer_cap = 0.9f;

    // 速率边界（新增）
    float steer_rate_limit = 0.1f;      // 单帧转向变化上限
    float throttle_rate_limit = 0.05f;  // 单帧油门变化上限
    float brake_rate_limit = 0.1f;      // 单帧刹车变化上限

    // 物理量边界（新增）
    float max_accel = 3.0f;             // m/s²
    float soft_decel = -3.0f;           // m/s²，Soft Stop
    float emergency_decel = -10.0f;     // m/s²，Emergency Stop
    float max_lat_accel = 3.0f;         // m/s²
    float max_jerk = 2.0f;              // m/s³

    // 超时边界（新增）
    float control_timeout = 2.5f;       // s，沿用 Apollo
};

struct ClampResult {
    std::array<float, 3> cmd;
    bool steer_limited;
    bool throttle_limited;
    bool brake_limited;
    std::string veto_reason;
};

// 分级 emergency
inline std::array<float, 3> soft_stop() noexcept { return {0.0f, 0.0f, 0.5f}; }
inline std::array<float, 3> emergency_stop() noexcept { return {0.0f, 0.0f, 1.0f}; }

// 带饱和检测与速率限制的 clamp
inline ClampResult clamp_command_v2(std::array<float, 3> cmd,
                                     std::array<float, 3> prev_cmd,
                                     const SafetyEnvelope& env) noexcept;
```

### 10.6 Safety Envelope 设计对照表

| 维度 | Apollo Guardian | OpenPilot steer_limited | NVIDIA SFF | Autoware Safety | AuroraDrive 现状 | AuroraDrive 升级目标 |
|------|----------------|------------------------|------------|----------------|------------------|---------------------|
| **架构形态** | 独立 TimerComponent | controlsd + panda 硬件 | 独立安全决策层 | 分布式模块 + gate | 结构体 + inline 函数 | 结构体 + 独立仲裁器 |
| **数值 clamp** | brake/throttle 百分比 | clip_curvature + accel_limits | 数学约束 | 速度曲线平滑 | 归一化 [-1,1] | 归一化 + 物理量 |
| **饱和检测** | ❌ | ✅ steer_limited_by_safety | ❌ | ❌ | ❌ | ✅ ClampResult |
| **积分冻结** | ❌ | ✅ freeze_integrator | ❌ | ❌ | ❌（仅限幅） | ✅ PID freeze |
| **超时检测** | ✅ 2.5s | ✅ 心跳 | ✅ 硬件 BIST | ✅ 模块频率 | ❌ | ✅ control_timeout |
| **Soft/Emergency 分级** | ✅ 两种刹车百分比 | ❌ | ❌ | ✅ MRM | ❌（仅 emergency） | ✅ soft/emergency |
| **物理量 clamp** | ✅ 加速度查表 | ✅ accel_limits | ✅ 数学约束 | ✅ 速度平滑 | ❌（归一化兜底） | ✅ 显式加速度/jerk |
| **jerk clamp** | ⚠️ 滤波器间接 | ❌ | ❌ | ✅ 速度平滑 | ❌ | ✅ max_jerk |
| **速度自适应** | ✅ steering_check | ✅ clip_curvature | ✅ SFF 计算 | ✅ 曲率减速 | ⚠️ 横摆间接 | ✅ 显式耦合 |
| **相位化否决** | ❌ | ❌ | ❌ | ❌ | ✅ phase_veto | ✅ 保留+增强 |
| **冗余** | ✅ 三路数据源 | ✅ 软硬件双层 | ✅ 双 SoC+多传感器 | ✅ 多源 gate | ❌ | ✅ 独立 Guardian |
| **预防性** | ❌（被动接管） | ❌ | ✅ 前向计算 | ✅ 前向投影 | ⚠️ TTC 临界 | ✅ 前向投影 |

### 10.7 升级优先级建议

按"投入产出比"排序，建议 AuroraDrive 按以下顺序实施：

1. **最高优先级**：PID 积分冻结 + 饱和检测（防 windup，代码量小，收益大，借鉴 OpenPilot）。
2. **高优先级**：超时检测 + Soft/Emergency 分级（防静默失效，借鉴 Apollo）。
3. **高优先级**：转向速率 clamp（防 jerk 尖峰，代码量小）。
4. **中优先级**：显式物理量 clamp（加速度/jerk，真车迁移必需，借鉴 NVIDIA）。
5. **中优先级**：前向投影 TTC 预测（预防性减速，借鉴 Autoware/SFF）。
6. **低优先级**：独立 Guardian 进程 + 冗余通道（量产级，长期目标）。

---

## 附：关键数据点速查

| 参数 | 数值 | 来源 |
|------|------|------|
| Apollo Guardian 定时周期 | 10ms（100Hz） | guardian_component 配置 |
| Apollo Guardian 超时阈值 | 2.5s | Proc() timeout |
| Apollo Guardian 超声波近距阈值 | 2.5m | TriggerSafetyMode() |
| Apollo Guardian 转向速率（安全模式） | 25.0°/s | set_steering_rate |
| Apollo 纵向 speed_controller_input_limit | ±1.5 m/s² | control_conf |
| Apollo 静止保持加速度 | -0.3~-0.5 m/s² | standstill_acceleration |
| OpenPilot steer_limited 角度阈值 | 2.5° | controlsd.py |
| OpenPilot steer_limited 扭矩阈值 | 0.01 | controlsd.py |
| AuroraDrive steer_limit | 1.0（归一化） | autonomy.h |
| AuroraDrive full_auto_steer_cap | 0.9 | autonomy.h |
| AuroraDrive emergency_stop | {0, 0, 1.0} | autonomy.h |
| AuroraDrive TTC_CRITICAL | 1.5s | FallbackDetector |
| AuroraDrive MAX_CURVATURE | 0.3 rad/m | FallbackDetector |
| AuroraDrive 振荡判据 | 5 帧内翻转 ≥3 次 | FallbackDetector |
| AuroraDrive 速度上限 | 180 km/h（50 m/s） | dynamics.h |
| AuroraDrive 横摆角速度 | 低速 ±1.5 / 高速 ±0.5 rad/s | dynamics.h |
| NVIDIA Hyperion SoC | 冗余双 Orin / 双 Thor | DRIVE Hyperion 8/10 |
| NVIDIA 安全等级 | ASIL-D + ISO 21434 | TÜV 认证 |
| Mobileye RSS 安全距离 | 最恶劣情况避撞距离 | RSS 论文 |
| 舒适纵向加速度 | ±2.0 m/s² | 业界共识 |
| 舒适横向加速度 | 3.0 m/s² | 业界共识 |
| AEB 紧急减速度 | -6~-10 m/s² | 法规上限 |
| 舒适 jerk | 2.0~3.0 m/s³ | 业界共识 |

---

## 附：研究调用次数

**实际内部工具调用次数：约 64 次**

包括：
- WebSearch：约 35 次（Safety Envelope / output clamp / Apollo Guardian / OpenPilot steer_limited / NVIDIA DriveGuard SFF Hyperion / Autoware safety / Mobileye RSS / Aurora safety case / AEB / jerk / watchdog / ISO 26262 SOTIF / lateral acceleration / redundant brake 等）
- WebFetch：约 22 次（CSDN Guardian 详解 / Tencent Apollo 源码 / OpenPilot controlsd / NVIDIA SFF / Apollo control 纵向控制器 / Autoware motion_velocity 系列 / Aurora 安全案例 / Mobileye RSS / NVIDIA Hyperion / Apollo Monitor / Watchdog / Apollo 横向 LQR 等）
- SearchCodebase：1 次（定位 AuroraDrive SafetyEnvelope 实现）
- Grep：2 次（确认 autonomy.h 中 SafetyEnvelope/emergency_stop/phase_veto/FallbackDetector 细节）
- Read：4 次（持久化输出读取，部分超时）

核心资料来源：Apollo 官方文档与 CSDN 源码解析、OpenPilot GitHub 与 controlsd 解析、NVIDIA 官方 SFF 发布与 Hyperion 百科、Autoware Universe 源码梳理系列、Mobileye RSS 论文解读、Aurora 安全案例框架、AuroraDrive 项目 cpp/include/ad/autonomy.h 源码。
