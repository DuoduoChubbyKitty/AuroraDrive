# 百度 Apollo 车辆动力学模型与 CAN 下发 深度研究报告

> 研究对象：百度 Apollo `modules/control`（横/纵向控制器、MPC）、`modules/common_msgs/basic_msgs/vehicle_param.proto`（车辆参数）、`modules/common_msgs/control_msgs/control_cmd.proto`（控制指令）、`modules/common_msgs/chassis_msgs/chassis.proto`（底盘反馈）、`modules/guardian`（安全守护）、`modules/canbus`（CAN 通信与协议适配）。
> 研究目的：吃透 Apollo 控制栈底层的车辆动力学建模（单轨/双轨、Pacejka 轮胎模型）、车辆参数标定体系、CAN 下发协议链路（Control → Guardian → CANBUS）、安全守护机制，并给出 AuroraDrive（当前为运动学自行车模型）升级到动力学模型 + Guardian 简化版的工程迁移方案。
> 参考谱系：Rajamani《Vehicle Dynamics and Control》第 2/3/13 章 + Apollo 6.0/9.0/10.0 源码 + CSDN/官方文档解析。本报告与同目录 `01s_control_lqr.md`（LQR 横向）、`01r_control_mpc.md`（MPC）、`01t_control_pid.md`（PID 纵向）形成互补，本篇聚焦"动力学模型 + 车辆参数 + CAN 链路 + Guardian"四块底层基建。

---

## 0. 一句话定位

Apollo 的控制栈建立在 **二自由度线性化动力学单车模型（Dynamic Bicycle Model）** 之上：横向控制器（LQR）/ 横纵向综合控制器（MPC）把"轨迹跟踪误差"组织成状态空间 `ẋ = A·x + B·u`，其中 A/B 的元素完全由 `vehicle_param`（轴距、质心位置、质量、转动惯量）与 `lat_controller_conf`（前后轮侧偏刚度 cf/cr）决定；控制器输出前轮转角 δ_f（横向）与加速度 a_x（纵向），封装成 `ControlCommand`（throttle/brake/steering_target，100Hz），经 **Guardian**（安全守护，10ms 周期）透传或紧急刹车拦截，最终由 **CANBUS** 模块按车型 DBC 协议编码成 CAN 报文下发到底盘执行，底盘再以 `Chassis` 消息（100Hz）反馈车速/转向百分比/驾驶模式，形成闭环。

---

## 1. 单轨（自行车）模型

### 1.1 模型假设与自由度

单车模型（Bicycle Model / Single-Track Model）是 Apollo 控制层的数学基石，它把左右轮合并为前后各一个等效轮，在以下假设下成立：

1. **纯侧偏轮胎特性**：忽略轮胎力的纵横向耦合（不联合纵向滑移与侧偏），只考虑侧向力—侧偏角关系；
2. **单车假设**：不考虑载荷的左右转移（无侧倾自由度），前后轴各等效为单轮；
3. **忽略空气动力学**与悬架动力学；
4. **前轮转向 + 后轮驱动**：只前轮有转向自由度 δ_f，后轮无转向；纵向力由后轴（或四轮）驱动产生；
5. **小角度线性化**：侧偏角 α 较小，Pacejka 公式退化为 F_y ≈ C_α·α；曲率连续可微。

在该假设下车辆有 **2 个自由度**：沿车体 y 轴的 **横向运动**（lateral）与绕 z 轴的 **横摆运动**（yaw）。纵向速度 v_x 在单步内视为常数参数（横向/纵向解耦），仅随控制周期更新。

> 注意：完整的单车模型本有 3 自由度（纵向 + 横向 + 横摆），Apollo 横向控制器把纵向速度当作"慢变参数"，使横向问题降为 2 自由度（横向 + 横摆）；纵向由独立的 PID 控制器处理。MPC 控制器则把横纵向耦合进 6 维状态一起优化。

### 1.2 受力分析与运动方程

设车辆坐标系 oxyz 固连车身（x 向前、y 向左、z 向上），惯性坐标系 OXY 固连地面。整车质量 m，绕 z 轴转动惯量 I_z，质心到前轴距离 l_f（前悬），质心到后轴距离 l_r（后悬），轴距 L = l_f + l_r。前轮转角 δ_f，横摆角速度 r = φ̇，质心横向速度 v_y，纵向速度 v_x。

**前/后轮胎侧偏角**（slip angle，轮胎朝向与轮胎速度方向之夹角）：

$$
\alpha_f = \delta_f - \theta_{vf}, \qquad \alpha_r = -\theta_{vr}
$$

其中 θ_vf、θ_vr 为前/后轮速度方向角。由几何关系（小角度近似 tanθ≈θ）：

$$
\theta_{vf} = \frac{v_y + l_f \dot\varphi}{v_x}, \qquad \theta_{vr} = \frac{v_y - l_r \dot\varphi}{v_x}
$$

**横向力平衡**（牛顿第二定律，y 轴方向，注意 a_y = v̇_y + v_x·φ̇ 含向心加速度）：

$$
m(\dot v_y + v_x \dot\varphi) = F_{yf} + F_{yr} = 2 C_f \alpha_f + 2 C_r \alpha_r
$$

**横摆力矩平衡**（绕 z 轴）：

$$
I_z \ddot\varphi = l_f F_{yf} - l_r F_{yr} = l_f \cdot 2 C_f \alpha_f - l_r \cdot 2 C_r \alpha_r
$$

其中 C_f、C_r 为 **单侧** 前/后轮侧偏刚度，乘 2 是因为前后轴各有左右两轮。Apollo 代码中 `cf_`/`cr_` 直接存"左右两轮之和"（即 2C_f / 2C_r），故公式里不再写系数 2。

### 1.3 路径误差坐标系下的状态空间

Apollo 横向控制不以绝对位置为状态，而以 **相对于参考轨迹的误差** 为状态（Rajamani 教材第 3 章 *Dynamic Model in Terms of Error with Respect to Road*）：

- e_1：横向误差（车辆质心到参考轨迹的横向距离，m）
- ė_1：横向误差变化率（m/s）
- e_2：航向误差（车辆航向 φ 与参考点航向 φ_des 之差，rad）
- ė_2：航向误差变化率（横摆角速度误差，rad/s）

参考横摆角速度 φ̇_des = v_x / R = v_x·κ（κ 为参考曲率），参考横向加速度 a_y_des = v_x²/R。代入误差定义并整理得连续状态空间 `ẋ = A·x + B·u`（Apollo 忽略道路曲率前馈项 B1·ψ̇_des，交给前馈单独处理）：

$$
x = \begin{bmatrix} e_1 \\ \dot e_1 \\ e_2 \\ \dot e_2 \end{bmatrix}, \quad
u = \delta_f
$$

**A 矩阵（4×4，连续）**——这是 Apollo `lat_controller.cc` 的 `Init()`/`UpdateMatrix()` 的数学来源：

$$
A = \begin{bmatrix}
0 & 1 & 0 & 0 \\
0 & -\dfrac{C_f+C_r}{m \cdot v_x} & \dfrac{C_f+C_r}{m} & \dfrac{-(l_f C_f - l_r C_r)}{m \cdot v_x} \\
0 & 0 & 0 & 1 \\
0 & -\dfrac{l_f C_f - l_r C_r}{I_z \cdot v_x} & \dfrac{l_f C_f - l_r C_r}{I_z} & -\dfrac{l_f^2 C_f + l_r^2 C_r}{I_z \cdot v_x}
\end{bmatrix}
$$

**B 矩阵（4×1，连续，前轮转向故只含 C_f 与 l_f）**：

$$
B = \begin{bmatrix} 0 \\ \dfrac{C_f}{m} \\ 0 \\ \dfrac{l_f C_f}{I_z} \end{bmatrix}
$$

观察：A 的第 0 行仅 (0,1)=1，第 2 行仅 (2,3)=1（积分关系）；含 1/v_x 的项是"速度相关阻尼"；A(1,2) 与 A(3,2) 是侧偏刚度直接耦合到横向/横摆的"弹性恢复项"（不随速度变化）；B 只有前轮项（后轮不转向）。

### 1.4 离散化与速度调度

车辆状态方程是连续的，但控制是离散的（10ms 周期）。Apollo 对 **A 用双线性变换（Tustin，保能量、稳定性好）**，对 **B 用前向欧拉**：

$$
A_d = (I + \tfrac{t_s}{2} A)\,(I - \tfrac{t_s}{2} A)^{-1}, \qquad B_d = B \cdot t_s
$$

t_s 默认 0.01s（100Hz）。由于 A 中含 1/v_x 项，**每个控制周期都用最新车速 v 重新更新 A 并重新离散化**（`UpdateMatrix()`）：当 v < minimum_speed_protection_（0.1 m/s）时用保护速度代入，避免 1/v 爆炸导致 A 数值奇异。LQR 据此在线求反馈增益 K（或用预存的增益调度表），MPC 则把离散 A_d/B_d 放入预测时域构造 QP。

> 与运动学自行车模型（`ω = v/L·tan(δ)`，纯几何，无轮胎力）的根本区别：动力学模型引入了侧偏刚度 C_f/C_r、质量 m、转动惯量 I_z，能描述"转向输入→侧偏角→侧向力→横摆"的力学因果链，从而在高速、大曲率下比运动学模型更准确；代价是需要标定轮胎参数，且小角度假设在急转弯时会失真。Apollo 之所以选动力学模型，是因为其控制目标是城市道路 60+ km/h 实车，运动学模型在 30 km/h 以上误差显著。

---

## 2. 双轨模型

### 2.1 模型结构

双轨模型（Two-Track Model / Four-Wheel Model）把四个车轮分别独立建模，每个轮都有自己的侧偏角、垂向载荷、纵向/侧向力：

- 4 个车轮独立：前左(FL)、前右(FR)、后左(RL)、后右(RR)；
- 每轮侧偏角 α_ij 由该轮速度方向与轮胎朝向之差决定，需考虑转向角 δ_i 与车轮相对质心的几何位置；
- 垂向载荷 F_z_ij 随纵向/横向加速度动态转移（纵向加速→后轴加载，横向转弯→外侧加载）；
- 总侧向力/横摆力矩 = Σ 各轮力 × 对应力臂。

### 2.2 与单轨模型的差异

| 维度 | 单轨模型（Apollo 控制） | 双轨模型（高精度仿真） |
|------|------------------------|------------------------|
| 车轮数 | 2（前后各 1 等效轮） | 4（独立） |
| 自由度 | 2（横向 + 横摆） | 6~14（含侧倾、俯仰、各轮转速） |
| 载荷转移 | 忽略左右转移 | 显式建模纵向/横向载荷转移 |
| 轮胎力 | 线性化 F_y≈C_α·α | 非线性 Pacejka，含纵横向耦合 |
| 适用场景 | 实时控制（LQR/MPC，100Hz） | 离线仿真、车辆动力学分析（CarSim/TruckSim） |
| 计算量 | O(1) 矩阵乘 | 需解刚性 ODE，计算量大 |

Apollo 在 **控制层** 用单轨模型（实时性优先），在 **仿真与车辆动力学云标定** 中用更精细的模型（包括基于机器学习的 14 自由度模型，误差比传统方式可减少近 80%）。双轨模型不是控制器的内模，而是"真值生成器"——用于在 Dreamview/Carsim 联合仿真中验证控制算法在极限工况（急转、紧急制动、路面 μ 变化）下的表现。AuroraDrive 当前纯仿真且为演示/采集场景，运动学模型已足够；若未来要做高速侧滑仿真或实车部署，需引入双轨 + Pacejka。

---

## 3. 轮胎模型

### 3.1 Pacejka 魔术公式（Magic Formula）

轮胎侧向力与侧偏角的关系是非线性的，业界标准经验模型是 Pacejka 魔术公式：

$$
F_y = D \cdot \sin\!\Big(C \cdot \arctan\!\big(B\alpha - E(B\alpha - \arctan(B\alpha))\big)\Big)
$$

四个参数的物理含义：

| 参数 | 名称 | 含义 |
|------|------|------|
| **B** | Stiffness Factor（刚度因子） | 决定原点处曲线斜率，与垂向载荷 F_z、胎压相关 |
| **C** | Shape Factor（形状因子） | 决定曲线峰形，一般轮胎 C ≈ 1.65 |
| **D** | Peak Factor（峰值因子） | D = μ·F_z（μ 路面附着系数，F_z 垂向载荷），决定最大侧向力 |
| **E** | Curvature Factor（曲率因子） | 控制峰后回落形状，E 越小曲线越平、越接近理想饱和 |

**原点处侧偏刚度**（cornering stiffness，曲线零点斜率）：

$$
C_\alpha = \left.\frac{\partial F_y}{\partial \alpha}\right|_{\alpha=0} = B \cdot C \cdot D
$$

### 3.2 小角度线性化

当侧偏角 α 很小时，arctan(Bα)≈Bα、sin(C·arctan(·))≈C·Bα，魔术公式退化为线性：

$$
F_y \approx B \cdot C \cdot D \cdot \alpha = C_\alpha \cdot \alpha
$$

这就是 Apollo 动力学模型中 `F_{yf} = 2 C_f \alpha_f`、`F_{yr} = 2 C_r \alpha_r` 的来源——线性化把"侧偏角→侧向力"简化为比例关系，比例系数即侧偏刚度 C_α。

### 3.3 前后轮侧偏刚度 Cf / Cr

- **C_f（cf_）**：前轴左右两轮侧偏刚度之和（2·C_αf），单位 N/rad；
- **C_r（cr_）**：后轴左右两轮侧偏刚度之和（2·C_αr），单位 N/rad；
- 物理上侧偏刚度为负（负侧偏力产生正侧偏角），Apollo 代码取绝对正值，方向在动力学方程符号中处理。

Apollo 默认配置（Lincoln MKZ / D-KIT）：`cf_ = cr_ = 155494.663 N/rad`（前后轴对称，简化标定）。该值来自 `control_conf.pb.txt` 的 `lat_controller_conf` 段，而非 `vehicle_param`（注意：早期版本 cf/cr 在 lat_controller_conf 里，新版本部分迁到 vehicle_param，需以实际版本为准）。

### 3.4 轮胎侧偏角定义

前轮侧偏角（侧向力产生的几何根源）：

$$
\alpha_f = \delta_f - \arctan\!\left(\frac{v_y + l_f \cdot r}{v_x}\right)
$$

后轮侧偏角（后轮不转向 δ_r=0）：

$$
\alpha_r = -\arctan\!\left(\frac{v_y - l_r \cdot r}{v_x}\right)
$$

物理含义：α 是"轮胎朝向"与"轮胎实际速度方向"之夹角。当 α>0（侧偏），轮胎产生反向侧向力（回正力），这就是车辆能转弯的力学本质——方向盘转 δ_f → 前轮速度方向偏离轮胎朝向 → 产生侧偏力 → 推车身横摆。线性化后侧偏力正比于 α，故侧偏刚度 C_α 越大，同样转角产生的侧向力越大，车辆响应越灵敏。

---

## 4. 车辆参数（vehicle_param.proto）

### 4.1 proto 结构

`modules/common_msgs/basic_msgs/vehicle_param.proto` 定义了 `VehicleParam` 消息，是全车物理参数的唯一真源（被 planning/control/canbus 共享）。关键字段（按工程语义分组）：

| 字段 | 含义 | 单位 |
|------|------|------|
| `brand` | 车辆品牌（枚举：LINCOLN_MKZ / GEM / LEXUS / TRANSIT / GE3 / DKIT / NEOLIX …） | — |
| `front_edge_to_center` | 车辆前缘到质心距离（用于停车线/碰撞检测前向偏移） | m |
| `back_edge_to_center` | 车辆后缘到质心距离 | m |
| `left_edge_to_center` | 左轮到质心距离 | m |
| `right_edge_to_center` | 右轮到质心距离 | m |
| `length` / `width` / `height` | 车长 / 车宽 / 车高 | m |
| `min_turn_radius` | 最小转弯半径 | m |
| `max_acceleration` | 最大加速度 | m/s² |
| `max_deceleration` | 最大减速度（负值） | m/s² |
| `wheelbase` | 轴距 L = l_f + l_r | m |
| `front_axle_to_center` | 质心到前轴距离 l_f（部分版本用此字段） | m |
| `rear_axle_to_center` | 质心到后轴距离 l_r | m |
| `steering_ratio` | 方向盘↔前轮转角比（方向盘转角 = 前轮转角 × ratio） | — |
| `max_steer_angle` | 方向盘最大转角（单方向） | rad |
| `max_steer_angle_rate` | 方向盘最大转角速率 | rad/s |
| `wheel_rolling_radius` | 车轮滚动半径 | m |
| `mass` | 整车质量 m | kg |
| `iz` | 绕 z 轴转动惯量 I_z | kg·m² |
| `cf` / `cr` | 前/后轮侧偏刚度（部分版本在 lat_controller_conf） | N/rad |
| `max_abs_speed_when_stopped` | 判定停车的速度阈值 | m/s |

横向控制器读取参数的典型代码（`lat_controller.cc::LoadControlConf`）：

```cpp
double l_r = vehicle_param_.rear_axle_to_center();   // l_r
double l_f = vehicle_param_.front_axle_to_center();  // l_f
double c_f = lat_controller_conf_.cf();              // 前轮侧偏刚度
double c_r = lat_controller_conf_.cr();              // 后轮侧偏刚度
double m   = vehicle_param_.mass();                  // 质量
double i_z = vehicle_param_.iz();                    // 转动惯量
double wheelbase_ = vehicle_param_.wheelbase();      // L
double steer_ratio_ = vehicle_param_.steering_ratio();
```

### 4.2 默认车型参数表

#### Lincoln MKZ（Apollo 经典默认车型，从 DreamView 前端 vehicleParam JSON 实测）

| 参数 | MKZ 默认值 | 说明 |
|------|-----------|------|
| front_edge_to_center | 3.89 m | 前缘到质心 |
| back_edge_to_center | 1.04 m | 后缘到质心 |
| left_edge_to_center | 1.055 m | 左轮到质心 |
| right_edge_to_center | 1.055 m | 右轮到质心 |
| length | 4.933 m | 车长 |
| width | 2.11 m | 车宽 |
| height | 1.48 m | 车高 |
| steering_ratio | 16 | 方向盘↔前轮转角比 |
| wheelbase | 2.85 m | 轴距（lat_controller_conf 给 2.85，D-KIT 给 1.73） |
| cf / cr | 155494.663 N/rad | 前后轮侧偏刚度（对称） |
| mass_fl/fr/rl/rr | 520 kg（每轮） | 四轮载荷，总质量 ≈ 2080 kg |
| iz | ≈ 2150 kg·m² | 转动惯量（教材典型值，MKZ 量级） |

#### Apollo D-KIT 开发者套件（微型车，标定文件示例）

| 参数 | D-KIT 值 |
|------|---------|
| front_edge_to_center | 1.373 m |
| back_edge_to_center | 1.402 m |
| length | 2.775 m |
| width | 1.01 m |
| height | 1.672 m |
| min_turn_radius | 3.75 m |
| max_acceleration | 2.5 m/s² |
| max_deceleration | −7.0 m/s² |
| max_steer_angle | 6.6323 rad |
| max_steer_angle_rate | 6.98131700798 rad/s |
| steer_ratio | 10.85 |
| wheelbase | 1.73 m |
| wheel_rolling_radius | 0.286 m |
| max_abs_speed_when_stopped | 0.2 m/s |

> 工程提示：`steering_ratio` 是把控制器输出的"前轮转角 δ_f"换算成"方向盘转角"的关键——`cmd->set_steering_target(steer_angle * steer_ratio)`。`steer_single_direction_max_degree_` 则用于方向盘转角限幅。MKZ 的 ratio=16 意味着前轮转 1° 方向盘转 16°，这是为了在控制指令的百分比量纲（[-100,100]）与物理角度之间建立映射。

---

## 5. CAN 下发

### 5.1 控制指令协议 control_cmd.proto

`modules/common_msgs/control_msgs/control_cmd.proto` 定义 `ControlCommand` 消息（核心字段，已从源码 proto 核对）：

```protobuf
message ControlCommand {
  optional apollo.common.Header header = 1;
  optional double throttle = 3;          // 油门百分比 [0, 100]
  optional double brake = 4;             // 刹车百分比 [0, 100]
  optional double steering_rate = 6;     // 转向速率 [0, 100] %/s
  optional double steering_target = 7;   // 目标转向角 [-100, 100]（满量程百分比）
  optional bool   parking_brake = 8;     // 驻车制动（true: 拉起 EPB）
  optional double speed = 9;             // 目标速度 m/s
  optional double acceleration = 10;     // 目标加速度 m/s²
  optional bool   engine_on_off = 17;    // 发动机开关
  optional double trajectory_fraction = 18;
  optional Chassis.GearPosition gear_location = 20;  // 档位
  optional Debug debug = 22;
  optional VehicleSignal signal = 23;    // 转向灯/喇叭
  optional LatencyStats latency_stats = 24;
  optional PadMessage pad_msg = 25;
  optional EngageAdvice engage_advice = 26;
  optional bool is_in_safe_mode = 27;    // 是否处于安全模式（Guardian 触发）
}
```

关键量纲约定（来自实测与文档）：
- `throttle`：[0.0, 100.0] 百分比（不是 0~1）；
- `brake`：[0.0, 100.0] 百分比；
- `steering_target`：[-100, 100] 满量程百分比（不是弧度！控制器算出的弧度 δ_f × steer_ratio 再归一化到 ±100）；
- `steering_rate`：[0, 100] 转向速率百分比；
- `speed` / `acceleration`：物理量（m/s、m/s²），供纵向控制器参考/底盘校验。

### 5.2 控制频率与周期

- **控制周期 10ms（100Hz）**：`lat_controller_conf` 的 `ts` 默认 0.01s，控制主循环以 100Hz 调用 `ComputeControlCommand`，输出 `ControlCommand` 发布到 `/apollo/control` 通道；
- **底盘反馈 100Hz**：CANBUS 以 100Hz 发布 `/apollo/canbus/chassis`，形成 100Hz 闭环；
- Guardian 同样是 10ms 定时器（TimerComponent），与控制同频。

### 5.3 底盘反馈 chassis.proto

`modules/common_msgs/chassis_msgs/chassis.proto` 定义 `Chassis` 消息，是控制器的反馈来源。核心字段：

| 字段 | 含义 |
|------|------|
| `speed_mps` | 车速 m/s |
| `throttle_percentage` | 实际油门百分比 [0,100] |
| `brake_percentage` | 实际刹车百分比 [0,100] |
| `steering_percentage` | 实际转向百分比 [-100,100] |
| `gear_location` | 档位（GEAR_DRIVE/GEAR_REVERSE/GEAR_PARKING/GEAR_NEUTRAL/GEAR_LOW） |
| `driving_mode` | 驾驶模式枚举（见下） |
| `engine_started` | 发动机是否启动 |
| `engine_rpm` | 发动机转速 |
| `odometer_m` | 里程表 m |
| `fuel_range_m` | 续航里程 m |
| `chassis_error_mask` | 底盘错误位掩码 |
| `parking_brake` | 驻车制动状态 |

**DrivingMode 枚举**（驾驶模式，决定控制权归属）：

| 模式 | 含义 |
|------|------|
| `COMPLETE_AUTO_DRIVE` | 完全自动驾驶（转向+速度都由 Apollo 控制） |
| `AUTO_STEER_ONLY` | 仅自动转向（速度人控） |
| `AUTO_SPEED_ONLY` | 仅自动速度（转向人控） |
| `MANUAL_DRIVE` | 完全手动 |
| `EMERGENCY_MODE` | 紧急模式（Guardian 触发） |
| `SECURITY_MODE` | 安全模式 |

控制器在 `ComputeControlCommand` 入口会检查 `chassis.driving_mode()`，只有 `COMPLETE_AUTO_DRIVE` 或 `AUTO_SPEED_ONLY` 才下发纵向指令，避免在人控时抢夺控制权。

---

## 6. Guardian 模块（安全守护）

### 6.1 模块定位

Guardian 是 Apollo 的 **最后一道安全防线**（保险丝/熔断器），代码位于 `modules/guardian`。它作为 `TimerComponent`（10ms 周期触发），订阅 Control 模块的 `ControlCommand` 与 Monitor 模块的 `SystemStatus`，输出 `GuardianCommand` 给 CANBUS。开启 Guardian 后（`FLAGS_receive_guardian=true`），CANBUS 不再直接订阅 `ControlCommand`，而是订阅 `GuardianCommand`——所有控制指令必须经 Guardian 包装透传或拦截。

数据流：`Control → Guardian → CANBUS`（Guardian 在中间做安全裁决）。

### 6.2 触发逻辑（Proc → TriggerSafetyMode）

Guardian `Proc()` 每个 10ms 周期执行：

1. **超时检测**：设 timeout = 2.5s。若 SystemStatus 接收时延 > 2.5s，或 SystemStatus 本身内置了安全模式触发标志，则 `safety_mode_triggered = true`；
2. **分支**：若 `safety_mode_triggered` → `TriggerSafetyMode()`；否则 → `PassThroughControlCommand()`（透传 ControlCommand）。

`TriggerSafetyMode()` 内部两轮判断 + 两轮命令设置：

**第 1 轮（传感器/障碍物）**：判断超声波（UltraSonic）传感器失效或 2.5m 范围内探测到障碍物。

**第 1 轮命令**（无论后续紧急还是柔和，都先复位油门转向）：
```cpp
guardian_cmd_.mutable_control_command()->set_throttle(0.0);
guardian_cmd_.mutable_control_command()->set_steering_target(0.0);
guardian_cmd_.mutable_control_command()->set_steering_rate(25.0);
guardian_cmd_.mutable_control_command()->set_is_in_safe_mode(true);
```

**第 2 轮（紧急 vs 柔和）**：若 SystemStatus 申请 Emergency Stop，或传感器失效，或探测到近距离物体 → **Emergency Stop**；否则 → **Soft Stop**。

**第 2 轮命令**（设刹车力度）：
```cpp
// Emergency Stop
guardian_cmd_.mutable_control_command()->set_brake(
    guardian_conf_.guardian_cmd_emergency_stop_percentage());  // 默认 100
// Soft Stop
guardian_cmd_.mutable_control_command()->set_brake(
    guardian_conf_.guardian_cmd_soft_stop_percentage());       // 默认 ~25
```

### 6.3 紧急刹车指令总结

Apollo 10.0 中 Guardian 紧急刹车的标准指令（与本任务要求一致）：

| 字段 | Emergency Stop | Soft Stop |
|------|---------------|-----------|
| `throttle` | 0.0 | 0.0 |
| `brake` | 100.0（满刹） | ~25.0（柔和） |
| `steering_target` | 0.0 | 0.0 |
| `steering_rate` | 25.0 | 25.0 |
| `is_in_safe_mode` | true | true |

Guardian 的设计哲学是 **冗余保护**：Control 模块可能因算法发散、轨迹异常、传感器抖动输出危险指令（如急转 + 油门），Guardian 作为独立进程在 10ms 内检测到系统级异常（超时、底盘错误、超声波近距）即强制接管，输出"清零油门 + 回正转向 + 满刹/柔刹"的安全指令，与 Control 解耦，避免单点失效导致失控。

---

## 7. CANBUS 模块

### 7.1 模块结构

代码位于 `modules/canbus`（部分版本拆到 `modules/drivers/canbus`）。核心组件：

- **CanClient**：CAN 卡驱动抽象（支持 ESD_CAN / FAKE_CAN / USB_CAN 等），负责底层 CAN 帧收发；
- **CanSender / CanReceiver**：发送/接收管理器。`CanSender` 维护 `SenderMessage` 列表（ProtocolData ↔ CanFrame 耦合），周期性 `Update()` + `Send()`；`CanReceiver` 收帧后交给 MessageManager 解析；
- **MessageManager**：管理某车型的所有协议报文（按 message id 注册接收/发送协议），解析底盘反馈、装配控制命令；
- **VehicleFactory**：工厂模式，按 `vehicle_param.brand` 创建对应车型的 `VehicleController` + `MessageManager`。Apollo 注册的车型：LINCOLN_MKZ、GEM、LEXUS、TRANSIT、GE3、ZHONGYUN、CH、DKIT、NEOLIX 等；
- **VehicleController**：车型控制器虚基类，子类（如 `LincolnController`）实现 `Brake()/Throttle()/Steer()/SetControlCommand()` 等虚函数，把 ControlCommand 的百分比指令翻译成各协议报文（如 brake_68、throttle_70、steering_74、gear_66）的 signal 值。

### 7.2 CAN 下发流程

1. Control 模块 100Hz 发布 `ControlCommand`（或 Guardian 透传/拦截后的 `GuardianCommand`）；
2. CANBUS `CanbusComponent` 收到命令，调用 `VehicleFactory::CreateVehicle()` 拿到对应 `VehicleController`；
3. `VehicleController::Update()`（如 LincolnController）把 `ControlCommand` 的 throttle/brake/steering_target/gear 转成各 `ProtocolData` 子类（如 `Brake68`、`Throttle70`、`Steering74`）的 signal 值（DBC 编码）；
4. `CanSender::Update()` 把所有 `SenderMessage` 序列化成 `CanFrame`，通过 `CanClient::SendSingleFrame()` 下发到底盘；
5. 底盘回传 CAN 帧 → `CanReceiver` → `MessageManager::ParseRecvMessage()` 解析成 `Chassis` 消息 → 100Hz 发布到 `/apollo/canbus/chassis`。

### 7.3 协议适配（DBC）

不同车型的 CAN 报文 ID、字节序（Motorola/Intel）、signal 位宽与缩放都不同。Apollo 用 DBC 文件描述每车型的协议，自动生成 `ProtocolData` 子类。例如 Lincoln MKZ 的刹车协议 `brake_68.h`、油门 `throttle_70.h`、转向 `steering_74.h`、档位 `gear_66.h`；LEXUS/TRANSIT 各有独立协议目录。新增车型需：① 在 `modules/canbus/vehicle/<brand>/` 下实现 controller + message_manager + protocol；② 在 `VehicleFactory` 注册品牌。这是 Apollo "车辆开放平台"的扩展点。

---

## 8. Apollo 源码路径索引

| 功能 | 源码路径 |
|------|---------|
| 横向 LQR 控制器 | `modules/control/controllers/lat/lat_controller.{h,cc}` |
| 纵向 PID 控制器 | `modules/control/controllers/lon/lon_controller.{h,cc}`（早期 `lon_based_pid_controller`） |
| MPC 横纵向综合控制器 | `modules/control/controllers/mpc/mpc_controller.{h,cc}` + `mpc_osqp.cc` |
| 控制器公共（动力学/轨迹分析/滤波） | `modules/control/controllers/common/`（含 `trajectory_analyzer`、`leadlag_controller`、`pid_controller`、`filters`） |
| 车辆参数 proto | `modules/common_msgs/basic_msgs/vehicle_param.proto` |
| 控制指令 proto | `modules/common_msgs/control_msgs/control_cmd.proto` |
| 底盘反馈 proto | `modules/common_msgs/chassis_msgs/chassis.proto` |
| Guardian | `modules/guardian/guardian_component.{h,cc}` |
| CANBUS | `modules/canbus/`（`can_comm/`、`vehicle/<brand>/`、`canbus_component.{h,cc}`） |
| LQR 求解器 | `modules/common/math/math_util.cc::SolveLQRProblem` |
| 车辆状态提供器 | `modules/common/vehicle_state/vehicle_state_provider.{h,cc}` |

控制器继承关系：`LatController/LonController/MPCController : public Controller`（早期 `ControlTask`），核心入口均为 `ComputeControlCommand(localization, chassis, trajectory, cmd)`。

---

## 9. AuroraDrive 迁移建议

### 9.1 AuroraDrive 当前状态审视

AuroraDrive 当前的车辆模型位于 `cpp/include/ad/dynamics.h`，是一个 **运动学自行车模型（Kinematic Bicycle Model）**，不是动力学模型：

```cpp
struct BicycleModel {
    static void step(EgoState& ego, float steer_rad, float accel_ms2, float dt) noexcept {
        float v = ego.speed_kmh * kKmhToMs;
        v += accel_ms2 * dt;
        v = clamp_val(v, 0.0f, 180.0f * kKmhToMs);
        if (v > 0.5f) {
            float delta = clamp_val(steer_rad, -kMaxSteer, kMaxSteer);
            float yaw_rate = (v / kWheelbase) * std::tan(delta);  // 纯几何，无轮胎力
            ego.heading += yaw_rate * dt;
        }
        ego.pos.x += v * std::cos(ego.heading) * dt;
        ego.pos.y += v * std::sin(ego.heading) * dt;
        // ...
    }
};
```

当前物理常量（`cpp/include/ad/types.h`）：

| 常量 | 值 | 说明 |
|------|-----|------|
| `kWheelbase` | 2.7 m | 轴距 |
| `kMaxSteer` | 0.6 rad（≈34.4°） | 前轮最大转角 |
| `kMaxAccel` | 3.0 m/s² | 最大加速度 |
| `kMaxBrake` | 8.0 m/s² | 最大减速度 |
| `kKmhToMs` | 1/3.6 | 单位换算 |

当前控制输出（`controller.h::ExpertController::Result`）：

```cpp
struct Result { float steer, throttle, brake, steer_rad, target_speed; };
// steer[-1,1], throttle[0,1], brake[0,1], steer_rad(前轮转角 rad)
```

由 `simulator.h` 消费：`accel = r.throttle * 3.0f - r.brake * 5.0f; BicycleModel::step(ego_, r.steer_rad, accel, dt);`

**关键差距**（与 Apollo 对比）：
1. 纯运动学，**无 cf/cr/mass/iz**——无法描述侧偏、转向不足/过度；
2. **无正式 Guardian**——仅有 `autonomy.h::FallbackDetector`（规则失效检测，severity==critical 触发 fallback_()），无独立安全进程；
3. 控制输出是 [-1,1] 归一化，非 Apollo 的 [0,100] 百分比；
4. 无 CAN 链路（纯仿真，直接调 `BicycleModel::step`）。

### 9.2 车辆参数标定方案

若 AuroraDrive 要升级到动力学模型（为实车部署或高速仿真铺路），建议分两阶段标定：

**阶段一：几何参数（直接测量，0 成本）**

| 参数 | 标定方法 | AuroraDrive 建议值 |
|------|---------|-------------------|
| `wheelbase` L | 实测前后轴中心距 | 2.7 m（已标定） |
| `front_axle_to_center` l_f | 质心到前轴（称重法：l_f = L·(后轴载荷/总质量)） | ~1.35 m（若质心居中） |
| `rear_axle_to_center` l_r | L − l_f | ~1.35 m |
| `front_edge_to_center` | 车前缘到质心 | ~2.0 m |
| `back_edge_to_center` | 车后缘到质心 | ~1.0 m |
| `steering_ratio` | 方向盘转角 / 前轮转角（实车打方向测量） | 仿真可设 1.0（直接前轮角） |
| `max_steer_angle` | 前轮最大转角 | 0.6 rad（已标定） |

**阶段二：动力学参数（需实验或借用）**

| 参数 | 标定方法 | AuroraDrive 建议值 |
|------|---------|-------------------|
| `mass` m | 整车称重 | ~1500 kg（乘用车量级） |
| `iz` I_z | 惯量摆测试，或经验公式 I_z ≈ m·L²/12 | ~1500×2.7²/12 ≈ 911 kg·m²（保守取 1000） |
| `cf` / `cr` | 轮胎台架测试，或借用 Apollo 默认 155494.663 | 先用 155494.663 N/rad 对称值 |

**标定验证**：在动力学模型上线后，做阶跃转向测试（固定速度 + 阶跃 δ），记录横摆角速度响应，与运动学模型 `ω = v/L·tan(δ)` 对比。动力学模型应出现"响应有滞后 + 稳态横摆略低于运动学预测"（侧偏效应），若两者完全一致说明 cf/cr 过大（退化为运动学）。

**实施建议**：在 `types.h` 新增动力学参数结构体：
```cpp
struct VehicleDynParam {
    float mass = 1500.0f;       // kg
    float iz = 1000.0f;         // kg·m²
    float lf = 1.35f;           // m
    float lr = 1.35f;           // m
    float cf = 155494.663f;     // N/rad
    float cr = 155494.663f;     // N/rad
};
```
并新增 `DynamicBicycleModel::step()` 实现 1.3 节的 A/B 矩阵积分（先用前向欧拉，dt=仿真步长），与现有 `BicycleModel` 并存，通过配置切换。

### 9.3 Guardian 简化版（输出越界 → 紧急刹车）

Apollo Guardian 是独立进程 + 超声波 + SystemStatus 的重型方案，AuroraDrive 作为单进程仿真无需如此复杂，建议实现一个 **轻量级输出越界守护**，直接嵌入控制输出环节：

**触发条件**（任一满足即紧急刹车）：
1. **输出越界**：steer/throttle/brake 超出物理范围（steer∉[-1,1]、throttle∉[0,1]、brake∉[0,1]）；
2. **NaN/Inf**：控制输出含非有限值（模型发散）；
3. **超时**：控制周期超时（如 >50ms 未更新，仿真 24Hz 下）；
4. **碰撞 imminent**：现有 FallbackDetector 的 critical 信号（前车 TTC 过小）。

**紧急刹车指令**（对齐 Apollo Emergency Stop 语义）：
```cpp
struct GuardianResult {
    float throttle = 0.0f;      // 清零油门
    float brake = 1.0f;         // 满刹（AuroraDrive 用 [0,1]，对应 Apollo 的 100）
    float steer = 0.0f;         // 回正转向
    float steer_rad = 0.0f;     // 前轮转角归零
    bool in_safe_mode = true;
};

GuardianResult apply_guard(const ExpertController::Result& r, bool critical) {
    GuardianResult g;
    bool out_of_bounds = (std::abs(r.steer) > 1.0f) || (r.throttle < 0) || (r.throttle > 1)
                         || (r.brake < 0) || (r.brake > 1)
                         || !std::isfinite(r.steer) || !std::isfinite(r.throttle);
    if (out_of_bounds || critical) {
        return g;  // 紧急刹车（默认值即紧急刹车）
    }
    // 透传
    g.throttle = r.throttle; g.brake = r.brake;
    g.steer = r.steer; g.steer_rad = r.steer_rad; g.in_safe_mode = false;
    return g;
}
```

在 `simulator.h` 控制消费处插入守护：
```cpp
auto r = expert.control(...);
auto g = apply_guard(r, (health.severity == "critical"));
float accel = g.throttle * 3.0f - g.brake * 5.0f;
BicycleModel::step(ego_, g.steer_rad, accel, dt);
```

这样 AuroraDrive 就获得了 Apollo Guardian 的核心能力——**输出异常即熔断**，且零额外进程开销。与现有 `FallbackDetector`（侧向失效检测）互补：FallbackDetector 管"感知/规划层失效"，Guardian 简化版管"控制输出层异常"。

### 9.4 迁移路线图

1. **短期（保留运动学）**：加 Guardian 简化版（9.3），先获得安全熔断能力；
2. **中期（动力学可选）**：加 `DynamicBicycleModel` + `VehicleDynParam`，配置切换，在高速场景验证侧偏效应；
3. **长期（实车）**：若上实车，引入 CAN 链路（仿 Apollo `control_cmd → canbus → dbc`），把 [0,1] 归一化输出转成 [0,100] 百分比 + 转向比换算，并标定真实 cf/cr/mass/iz。

---

## 10. 关键结论与对 AuroraDrive 的启示

1. **Apollo 控制的数学根基是 2 自由度动力学单车模型**，A/B 矩阵元素完全由 cf/cr/mass/iz/lf/lr 决定，小角度线性化 Pacejka 是其前提。AuroraDrive 当前运动学模型在低速演示足够，高速/实车必须升级动力学。

2. **车辆参数是真源**：`vehicle_param.proto` 被 planning/control/canbus 共享，cf/cr 决定横向响应、steering_ratio 决定输出换算、mass/iz 决定横摆惯性。AuroraDrive 缺这套参数体系，迁移第一步是把 `VehicleDynParam` 补齐。

3. **CAN 链路是 Control → Guardian → CANBUS 三段式**：Control 算指令、Guardian 做安全裁决、CANBUS 做协议编码。100Hz 闭环，10ms 周期。AuroraDrive 纯仿真无 CAN，但 Guardian 的"输出越界熔断"思想值得直接移植。

4. **Guardian 的核心是冗余 + 紧急刹车**（throttle=0, brake=100, steering_target=0），与控制解耦。AuroraDrive 用轻量级 `apply_guard` 即可获得等价能力，无需独立进程。

5. **Pacejka 公式是轮胎力的金标准**，但 Apollo 控制层只用其线性化形式 F_y≈C_α·α；完整 Pacejka 用于仿真。AuroraDrive 若做侧滑仿真才需完整公式，控制层用线性化即可。

6. **MKZ 默认 cf=cr=155494.663 N/rad** 是 Apollo 社区的事实标准值，AuroraDrive 迁移动力学模型时可直接借用作为初值，再按实车标定修正。

---

## 参考资料

- Apollo 官方源码：`github.com/ApolloAuto/apollo`（modules/control、modules/canbus、modules/guardian、modules/common_msgs）
- Rajamani R. *Vehicle Dynamics and Control*. Springer, 2006.（第 2/3/13 章）
- 龚建伟 等. 《无人驾驶车辆模型预测控制》. 北京理工大学出版社, 2014.
- Apollo 开放平台官方文档：车辆动力学云标定、控制能力实践、Dreamland 调试
- CSDN 深度解析：Apollo 车辆动力学模型、横纵向控制、Guardian 模块、CANBUS 模块、标定模块

---

> 本报告实际内部工具调用次数：**约 87 次**（WebSearch + WebFetch + Read/Grep/Glob 本地代码探查）。
> 字数：约 6500 字（含公式与表格）。
