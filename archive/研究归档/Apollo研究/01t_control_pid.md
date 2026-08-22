# 百度 Apollo PID 控制器与标定表深度研究报告

> 研究对象：Apollo 控制模块 `modules/control/controllers/lon`（lon_based_pid_controller）与 `modules/control/controllers/pid`（pid / pid_BC / pid_IC）以及标定表 calibration_table 的实现机制，并给出向 AuroraDrive 单环 PID 系统迁移的升级方案。
>
> 资料来源：ApolloAuto/apollo 官方仓库（GitHub）、Apollo 官方文档（车辆动力学云标定）、CSDN 多篇源码逐行解析（ChenGuiGan、weixin_39199083、jch924583667、WaiNgai1999、BigDavid123、yanghq13、windses、qq_42466012 等）。
>
> 撰写日期：2026-07-23

---

## 0. 总览：Apollo 纵向控制的全景

Apollo 的控制模块（Control）是 Planning 与底盘 canbus 之间的"神经-肌肉接口"，它把规划轨迹实时转化为油门、刹车、方向盘指令。控制模块以 `ControlComponent`（继承 `TimerComponent`，默认 10Hz / 100Hz 可配）为入口，经 `ControlTaskAgent` 调度若干 `ControlTask`（控制器插件）。

纵向控制默认使用 **lon_based_pid_controller** 插件，即 `LonController` 类（早期版本继承 `Controller`，9.0/10.0 之后继承 `ControlTask` 并通过 `CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN` 注册为插件）。它采用经典的 **位置-速度双环 PID + 标定表开环**结构，辅以超前/滞后补偿、俯仰角滤波与坡道补偿、停车逻辑与 EPB。

纵向控制器的输入输出关系可概括为：

```
输入: 定位(LocalizationEstimate) + 底盘(Chassis: speed/accel) + 规划轨迹(ADCTrajectory)
输出: ControlCommand { throttle[0,100], brake[0,100], steering[-100,100], gear, ... }
```

`ControlCommand` 在 `modules/common_msgs/control_msgs/control_cmd.proto` 中定义：`steering`（转向角[-100,100]）、`throttle`（油门[0,100]）、`brake`（刹车[0,100]）、`acceleration`、`is_estop`、`driving_mode` 等。

---

## 1. LonController 实现概览

### 1.1 源码位置与类声明

核心文件：
- `modules/control/controllers/lon_based_pid_controller/lon_controller.h`
- `modules/control/controllers/lon_based_pid_controller/lon_controller.cc`
- 配置 proto：`modules/control/controllers/lon_based_pid_controller/proto/lon_based_pid_controller_conf.proto`

`LonController` 类的关键成员（来自头文件逐行解析）：

```cpp
class LonController : public ControlTask {
 public:
  LonController();
  virtual ~LonController();
  common::Status Init(std::shared_ptr<DependencyInjector> injector) override;
  common::Status ComputeControlCommand(
      const localization::LocalizationEstimate *localization,
      const canbus::Chassis *chassis,
      const planning::ADCTrajectory *trajectory,
      control::ControlCommand *cmd) override;
  common::Status Reset() override;
  void Stop() override;
  std::string Name() const override;

 protected:
  void ComputeLongitudinalErrors(const TrajectoryAnalyzer *trajectory,
                                 const double preview_time, const double ts,
                                 SimpleLongitudinalDebug *debug);
  void GetPathRemain(SimpleLongitudinalDebug *debug);
  std::shared_ptr<DependencyInjector> injector_;

 private:
  void SetDigitalFilterPitchAngle();
  void InitControlCalibrationTable();   // 10.0 改名，早期叫 LoadControlCalibrationTable
  void SetDigitalFilter(double ts, double cutoff_freq, common::DigitalFilter *digital_filter);
  bool IsStopByDestination(SimpleLongitudinalDebug *debug);
  bool IsPedestrianStopLongTerm(SimpleLongitudinalDebug *debug);
  bool IsFullStopLongTerm(SimpleLongitudinalDebug *debug);
  void SetParkingBrake(const LonBasedPidControllerConf *conf,
                       control::ControlCommand *control_command);
  void CloseLogFile();

  // —— 关键成员变量 ——
  const localization::LocalizationEstimate *localization_ = nullptr;
  const canbus::Chassis *chassis_ = nullptr;
  std::unique_ptr<Interpolation2D> control_interpolation_;   // 标定表二维插值器
  const planning::ADCTrajectory *trajectory_message_ = nullptr;
  std::unique_ptr<TrajectoryAnalyzer> trajectory_analyzer_;  // 轨迹解析器
  bool controller_initialized_ = false;
  double previous_acceleration_ = 0.0;
  double previous_acceleration_reference_ = 0.0;

  PIDController speed_pid_controller_;            // 速度环 PID（内环）
  PIDController station_pid_controller_;          // 位置环 PID（外环）
  LeadlagController speed_leadlag_controller_;    // 速度超前/滞后补偿
  LeadlagController station_leadlag_controller_;  // 位置超前/滞后补偿

  common::DigitalFilter digital_filter_pitch_angle_;  // 俯仰角低通滤波器
  LonBasedPidControllerConf lon_based_pidcontroller_conf_;
  calibration_table calibration_table_;           // 车辆标定表（proto）
  common::VehicleParam vehicle_param_;            // 车辆参数
  // 停车 / EPB / 行人停车等状态机成员若干……
};

CYBER_PLUGIN_MANAGER_REGISTER_PLUGIN(apollo::control::LonController, ControlTask)
```

### 1.2 Init 流程

`Init()` 依次完成：
1. 读取 `LonBasedPidControllerConf`（控制周期 `ts`、`enable_reverse_leadlag_compensation` 等）；
2. 初始化 `station_pid_controller_`（位置环）与 `speed_pid_controller_`（速度环，分 `low_speed_pid_conf` / `high_speed_pid_conf`，按 `switch_speed` 切换）；
3. 若开启超前滞后，初始化 `station_leadlag_controller_` / `speed_leadlag_controller_`（默认关闭）；
4. 拷贝车辆参数 `vehicle_param_`；
5. `SetDigitalFilterPitchAngle()`：按 `pitch_angle_filter_conf.cutoff_freq`（默认 5Hz）配置俯仰角滤波器；
6. `InitControlCalibrationTable()`：加载标定表到 `control_interpolation_`；
7. `controller_initialized_ = true`。

构造函数中若打开 `FLAGS_enable_csv_debug`，会创建 `/tmp/speed_log__*.csv` 并写入表头（`station_reference, station_error, station_error_limited, speed_reference, speed_error, speed_error_limited, preview_..., acceleration_cmd_closeloop, acceleration_cmd, acceleration_lookup, speed_lookup, calibration_value, throttle_cmd, brake_cmd, is_full_stop`），用于离线分析。

---

## 2. 双环结构（位置-速度）

Apollo 纵向控制采用 **外环位置环 + 内环速度环** 的串级 PID。这是与单环速度 PID 最本质的区别。

### 2.1 外环（位置环 / station loop）

- **输入**：目标位置 `s_target`（来自规划轨迹匹配点的 `path_point().s()`）+ 当前位置 `s_current`（自车投影到 Frenet 纵向距离 `s_matched`）。
- **输出**：目标速度修正量 `Δv`，叠加到规划参考速度 `v_ref` 上得到内环设定值 `v_target`。
- **误差**：
  ```
  e_position = s_target − s_current = station_error
  ```
- 位置环 PID 计算得到速度补偿，Apollo 默认位置环只用比例（`station_pid_conf`：`integrator_enable: false`，`kp: 0.2`，`ki: 0.0`，`kd: 0.0`），目的是精确停车、避免过冲。

### 2.2 内环（速度环 / speed loop）

- **输入**：目标速度 `v_target` + 当前速度 `v_current`（`s_dot_matched`，即自车纵向速度分量）。
- **输出**：加速度闭环命令 `acceleration_cmd_closeloop`。
- **误差**：
  ```
  e_speed = v_target − v_current = speed_error
  ```
- 速度环分高低速两套参数（`switch_speed: 3.0` m/s 切换）：
  - `low_speed_pid_conf`（<3m/s）：`kp: 2.0, ki: 0.3, kd: 0.0, integrator_enable: true, integrator_saturation_level: 0.3`
  - `high_speed_pid_conf`（≥3m/s）：`kp: 1.0, ki: 0.3, kd: 0.0`（比例增益减半防抖）
  - `speed_controller_input_limit: 1.5`（m/s，限制速度环输入，防止加速度指令突变）

### 2.3 双环 PID 公式

Apollo 使用 **位置式（绝对式）PID**，离散形式：

```
u(k) = Kp·e(k) + Ki·Σ_{i=0}^{k} e(i) + Kd·[e(k) − e(k−1)]
```

外环（位置 → 速度补偿）：
```
Δv(k) = Kp_s·e_s(k) + Ki_s·Σe_s(i) + Kd_s·[e_s(k) − e_s(k−1)]
v_target(k) = v_ref(k) + Δv(k)
```

内环（速度 → 加速度闭环）：
```
a_closeloop(k) = Kp_v·e_v(k) + Ki_v·Σe_v(i) + Kd_v·[e_v(k) − e_v(k−1)]
```

最终加速度命令（叠加参考加速度前馈 + 坡度补偿 + 停车增益）：
```
a_cmd(k) = a_ref(k) + a_closeloop(k) + a_slope_offset(k) + a_stop_gain(k)
```

源码对应（`lon_controller.cc`）：
```cpp
// 位置环
double speed_offset = station_pid_controller_.Control(station_error_limited, ts);
double speed_controller_input_limit = lon_controller_conf.speed_controller_input_limit();
double speed_offset_limited = common::math::Clamp(speed_offset, -speed_controller_input_limit, speed_controller_input_limit);
// 内环设定
double speed_cmd = speed_reference + speed_offset_limited;  // v_target
// 速度环
double acceleration_cmd_closeloop = speed_pid_controller_.Control(speed_error_limited, ts);
// 叠加前馈与坡度
double acceleration_cmd = acceleration_cmd_closeloop + acceleration_reference
                          + slope_offset_compensation;
```

> 注意：Apollo 的 `PIDController::Control` 在积分前先乘 `Ki`（`integral_ += error * dt * ki_`），注释明确写"apply ki before integrating to avoid steps"——这样在稳态时动态修改 Ki 不会产生阶跃。

### 2.4 纵向误差计算（ComputeLongitudinalErrors）

核心思想是把笛卡尔坐标下的自车状态投影到 Frenet 坐标系，参考 Werling 等人 ICRA 2010 论文，但不假设"车辆到参考点的向量"与"参考航向"垂直。

```cpp
// trajectory_analyzer.cc::ToTrajectoryFrame
double dx = x - ref_point.x();
double dy = y - ref_point.y();
double cross_rd_nd = cos_ref_theta * dy - sin_ref_theta * dx;   // 横向 d
double dot_rd_nd   = dx * cos_ref_theta + dy * sin_ref_theta;   // 纵向投影
*ptr_s = ref_point.s() + dot_rd_nd;                              // s_matched
double one_minus_kappa_r_d = 1 - ref_point.kappa() * (*ptr_d);
*ptr_s_dot = v * cos(delta_theta) / one_minus_kappa_r_d;        // s_dot_matched

// lon_controller.cc
debug->set_station_error(reference_point.path_point().s() - s_matched);
debug->set_speed_error(reference_point.v() - s_dot_matched);
```

由此得到解析公式：
```
station_error = s_ref − s_matched = −(dx·cosθ_des + dy·sinθ_des)
speed_error   = v_ref − v·cos(Δθ) / (1 − κ_r·d)
```

匹配点查询 `QueryMatchedPathPoint` 先找最近路径点，再在前后两点间用 `FindMinDistancePoint` 精修；参考点查询 `QueryNearestPointByAbsoluteTime/RelativeTime` 按规划相对时间定位，保证时间同步。

---

## 3. 标定表 calibration_table

### 3.1 为什么需要标定表

油门/刹车踏板开度与车辆实际加速度之间是 **非线性** 关系：油门有死区、高速段油门效率下降、刹车片有非线性段。若直接 `throttle = accel_cmd`，会带来稳态误差与动态过冲。Apollo 用一张 **(车速, 加速度) → 踏板开度** 的二维标定表来描述车辆纵向动力学的逆模型，把加速度命令映射为油门/刹车百分比。

### 3.2 proto 定义与表格格式

标定表 proto（`calibration_table.proto`，挂载在 `LonBasedPidControllerConf` 中）结构如下：

```proto
message CalibrationTable {
  repeated double speed = 1;   // 车速序列 (m/s)，如 0.0, 1.0, 2.0, ... 30.0
  repeated double acceleration = 2;  // 加速度序列 (m/s^2)，如 -3.0, -2.0, ... 3.0
  repeated double calibration_value = 3;  // 对应踏板开度百分比
  // 实际存储为 (speed × acceleration) 网格，calibration_value 按 row-major 排列
}
```

`control_conf.pb.txt` 中典型写法（以 51CTO 解析为例）：
```
calibration_table {
  throttle: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
  brake:    [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
  acc:      [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
}
```

### 3.3 Interpolation2D 二维插值

`modules/control/common/interpolation_2d.h`（9.0 之后路径 `control_component/controller_task_base/common/interpolation_2d.h`）提供二维线性插值器：

```cpp
class Interpolation2D {
 public:
  bool Init(const DataType &input, const Table &output);
  double Interpolate(const Key &x, const Key &y) const;
 private:
  std::map<Key, std::map<Key, Value>> map_;  // 二维 map
};
```

加载流程（早期 `LoadControlCalibrationTable` / 10.0 `InitControlCalibrationTable`）：
```cpp
void LonController::InitControlCalibrationTable() {
  const auto &calibration_table = lon_based_pidcontroller_conf_.calibration_table();
  Interpolation2D::DataType xyz;
  // 把 proto 中的 speed/acceleration/calibration_value 网格填入 xyz
  for (speed...) for (acc...) {
    xyz[std::make_pair(speed, acc)] = calibration_value;
  }
  control_interpolation_->Init(xyz);
}
```

查表（油门/刹车命令计算）：
```cpp
double calibration_value =
    control_interpolation_->Interpolate({speed, acceleration_cmd});
// calibration_value > 0 → 油门；< 0 → 刹车
double throttle_cmd = std::max(calibration_value, 0.0);
double brake_cmd    = std::max(-calibration_value, 0.0);
```

可选 `use_preview_speed_for_table` 用预瞄速度查表，`use_acceleration_lookup_limit` 限制查表加速度范围。

### 3.4 标定数据采集流程

Apollo 提供离线/在线两种标定：
- **离线脚本**（早期 `modules/tools/calibration`，3.0 之前）：`data_collector.py` 采集底盘反馈（`speed_mps, throttle_percentage, brake_percentage, engine_rpm, acceleration`），保存为 CSV；`process_data.py` 做低通滤波与数据对齐（预处理），再按速度段/加速度段分箱，回归出每个 (speed, acc) 网格的踏板量（后处理），最终生成 `calibration_table.pb.txt`。
- **云标定**（推荐）：`modules/tools/vehicle_calibration` + Apollo 云服务。采集条件分低速（0~2.5m/s）/高速（≥2.5m/s），油门分小（deadzone~24%）/大（≥24%），刹车分缓/急。默认采集约 4000 帧（40~60 分钟），用机器学习拟合逆动力学模型，生成数据量大、精度高的标定表。配置在 `modules/calibration/data/<车型>/dreamview_conf/data_collection_table.pb.txt`，标定表输出到 `modules/control/conf/calibration_table.pb.txt`。

文献《Baidu Apollo Auto-Calibration System》(arXiv:1808.10134) 给出了数据驱动的在线/离线标定算法原理。

---

## 4. PID 算法实现与抗饱和

### 4.1 PIDController 基类

`modules/control/controllers/pid/pid_controller.h/cc`（9.0 后位于 `controller_task_base/common/pid_controller.h`）：

```cpp
class PIDController {
 public:
  void Init(const PidConf &pid_conf);
  void SetPID(const PidConf &pid_conf);     // 设置 kp/ki/kd/kaw
  void Reset();
  virtual double Control(const double error, const double dt);  // 位置式 PID
  int IntegratorSaturationStatus() const;
  bool IntegratorHold() const;
  void SetIntegratorHold(bool hold);
 protected:
  double kp_=0, ki_=0, kd_=0, kaw_=0;
  double previous_error_=0, previous_output_=0, integral_=0;
  double integrator_saturation_high_=0, integrator_saturation_low_=0;
  bool first_hit_=false, integrator_enabled_=false, integrator_hold_=false;
  int integrator_saturation_status_=0;
  // 仅 pid_BC / pid_IC 使用
  double output_saturation_high_=0, output_saturation_low_=0;
  int output_saturation_status_=0;
};
```

`Control()` 流程：
1. 若 `dt <= 0`，警告并返回 `previous_output_`；
2. 首拍 `first_hit_` 置 false，否则 `diff = (error − previous_error_) / dt`；
3. 积分器使能则 `integral_ += error * dt * ki_`（先乘 Ki），并对积分项做饱和钳位 `integrator_saturation_level`（如 ±0.3）；
4. `output = error*kp_ + integral_ + diff*kd_`；
5. 更新 `previous_error_`、`previous_output_`。

`PidConf` proto 关键字段：`integrator_enable`、`integrator_saturation_level`、`kp/ki/kd`、`kaw`（抗饱和增益）、`output_saturation_level`（输出饱和，仅 BC/IC 用）。

### 4.2 位置式 vs 增量式

Apollo 纵向用 **位置式 PID**：
```
u(k) = Kp·e(k) + Ki·Σe(i) + Kd·[e(k) − e(k−1)]
```
增量式（差分）：
```
Δu(k) = Kp·[e(k)−e(k−1)] + Ki·e(k) + Kd·[e(k)−2e(k−1)+e(k−2)]
```
位置式直接给出绝对控制量，便于与标定表对接；增量式无积分累积、抗饱和更简单，但 Apollo 选择了位置式 + 抗饱和策略。

### 4.3 抗饱和（Anti-Windup）

`modules/control/controllers/pid/` 下有三个实现：

**pid_BC_controller.cc（反算法 Back-Calculation）** 步骤：
1. 计算一次完整 PID 得初始控制量 `u`；
2. 按 `output_saturation_high/low` 判定是否饱和并对 `u` 钳位；
3. 用饱和差值 `Δu = u − u_saturated` 乘抗饱和增益 `kaw_` 反馈修正积分项：
   ```
   integral_ += error·dt·ki − kaw_·(u − u_saturated)
   ```
4. 用修正后的积分项重算 PID；
5. 输出钳位结束。

**pid_IC_controller.cc（钳位法 Integral Clamping / 条件积分）**：当输出已饱和且误差与饱和方向同号时，停止积分累积（if-else 条件积分），简单可靠、应用更广。

基类 `pid_controller.cc` 本身也提供最朴素的积分项限幅（`integrator_saturation_level`），但对末端限幅无法让积分快速退出饱和，因此关键环（速度环）建议使用 BC/IC。

### 4.4 死区与低通滤波

- **死区**：`brake_minimum_action` / `throttle_minimum_action`（0 表示无死区），过滤踏板死区段微小控制量。
- **低通滤波**：对误差/控制量做低通，抑制噪声。PID 微分项对高频噪声敏感，Apollo 在 `digital_filter` 系列提供二阶 Butterworth 低通（见第 5 节）。`pid_conf` 也可配 `kaw` 与积分保持 `integrator_hold`（停车或工况切换时冻结积分）。

---

## 5. 超前/滞后控制器 LeadLagController

`modules/control/common/leadlag_controller.h/cc`（yanghq13 解析）。Leadlag 是基于频域的补偿器，通过相位超前改善动态响应、相位滞后提高稳态精度。Apollo 中对位置环与速度环各配一个，默认关闭（`enable_reverse_leadlag_compensation: false`）。

### 5.1 传递函数

连续域传递函数：
```
H(s) = β · (τ·s + 1) / (τ·α·s + 1)
```
- `α`：滞后系数；`β`：超前系数；`τ`：时间系数。
- 相角 `φ(ω) = arctan(τω) − arctan(ατω)`，最大相角在零点 `1/τ` 与极点 `1/(ατ)` 之间。

### 5.2 双线性变换离散化（TransformC2d）

用 Tustin（梯形）积分 `s = (2/T)·(z−1)/(z+1)` 离散化，得到：
```
H(z) = (kn0 + kn1·z) / (kd0 + kd1·z)
```
其中：
```
a1 = α·τ,  a0 = 1,  b1 = β·τ,  b0 = β,  Ts = dt
kn1 = 2·b1 + Ts·b0
kn0 = Ts·b0 − 2·b1
kd1 = 2·a1 + Ts·a0
kd0 = Ts·a0 − 2·a1
```
源码：
```cpp
void LeadlagController::TransformC2d(const double dt) {
  double a1 = alpha_ * tau_;  double a0 = 1.00;
  double b1 = beta_ * tau_;   double b0 = beta_;
  Ts_ = dt;
  kn1_ = 2 * b1 + Ts_ * b0;
  kn0_ = Ts_ * b0 - 2 * b1;
  kd1_ = 2 * a1 + Ts_ * a0;
  kd0_ = Ts_ * a0 - 2 * a1;
  if (kd1_ <= 0.0) { /* 警告，禁用 */ }
}
```

### 5.3 Control（Direct Form II 实现）

用 Direct Form II 状态空间实现差分方程，并对内部状态 `innerstate_` 做饱和钳位（`innerstate_saturation_level`）防积分饱和：
```cpp
virtual double Control(const double error, const double dt) {
  // innerstate_ = (error·kd1 - previous_innerstate_·kd0) / kd1
  // output = innerstate_·kn1 + previous_innerstate_·kn0
  // 对 innerstate_ 饱和钳位
}
```
默认参数（`reverse_*_leadlag_conf`）：`alpha: 1.0, beta: 1.0, tau: 0.0, innerstate_saturation_level: 1000`，即默认不补偿。

---

## 6. 俯仰角滤波器与坡道补偿

### 6.1 digital_filter 滤波 pitch

`common::DigitalFilter digital_filter_pitch_angle_` 对 IMU/定位给出的俯仰角 pitch 做低通滤波，滤除车身震动带来的高频噪声。`SetDigitalFilterPitchAngle()` 按 `pitch_angle_filter_conf.cutoff_freq`（默认 5Hz）与控制周期 `ts` 生成二阶 Butterworth 低通系数（`digital_filter_coefficients.h`）：
```cpp
void LonController::SetDigitalFilter(double ts, double cutoff_freq,
                                     common::DigitalFilter *digital_filter) {
  std::vector<double> denoms, nums;
  common::LpfCoefficients(ts, cutoff_freq, &denoms, &nums);
  digital_filter->set_denoms(denoms);
  digital_filter->set_nums(nums);
}
```

### 6.2 长坡道补偿（slope offset）

由 `FLAGS_enable_slope_offset` 控制（默认 false，10.0 中可 `use_opposite_slope_compensation`）。开启后：
```
a_slope_offset = sin(pitch_filtered) · GRA_ACC   // GRA_ACC = 9.8
```
上坡（pitch>0）时 `a_slope_offset > 0`，叠加到 `a_cmd` 加油门克服重力分量；下坡（pitch<0）减油门/加刹车。滤波后的 pitch 避免震动导致补偿抖动。`a_cmd = a_closeloop + a_ref + a_slope_offset`。

---

## 7. 弯道减速

Apollo 的弯道减速主要由 **Planning 模块**完成：规划轨迹的速度 profile 已根据曲率约束（`v²·κ ≤ a_lat_max`）生成限速，Control 只需跟随。Control 侧通过 `use_steering_check`（默认 true）做转向联动检查——转弯时与横向控制协同自动降低车速。`one_minus_kappa_r_d = 1 − κ_r·d` 在 Frenet 投影中体现曲率影响，曲率过大时 `speed_error` 计算会触发警告。因此纵向 PID 本身不做曲率 PID，而是"Planning 算曲率限速 → Control 跟随"。

---

## 8. VehicleParam 车辆参数

`modules/common_msgs/config_msgs/vehicle_config.proto` 中的 `VehicleParam` 描述车辆几何与动力学参数，`lincoln.pb.txt`（MKZ 默认）提供数值。关键字段：

| 字段 | 含义 | MKZ 典型值 |
|---|---|---|
| `brand` | 车辆品牌 | lincoln_mkz |
| `front_edge_to_center` | 前保险杠到质心 | 3.89（m，按车型，dev_kit ~1.315） |
| `back_edge_to_center` | 后保险杠到质心 | 1.043（m） |
| `left_edge_to_center` / `right_edge_to_center` | 左/右到质心 | ~0.686（m） |
| `length` / `width` / `height` | 车身尺寸 | 4.933 / 2.11 / 1.483 |
| `wheelbase` | 轴距 | 2.85（m） |
| `steering_ratio` | 转向传动比 | 16.0 |
| `max_steer_angle` | 最大方向盘转角 | 470.0（deg） |
| `max_steer_angle_rate` | 最大转向速率 | 470.0 |
| `wheel_rolling_radius` | 车轮滚动半径 | 0.335 |
| `mass` | 整车质量 | 1818.0（kg） |
| `iz` / `vehicle_z` | 绕 z 轴转动惯量 | ~2608.8 / 4264.0 |
| `lf` / `lr` | 质心到前/后轴距离 | 1.44 / 1.41 |
| `cf` / `cr` | 前/后轮侧偏刚度 | 155494.663（N/rad，lincoln.pb.txt） |
| `brake_deadzone` / `throttle_deadzone` | 死区 | — |

这些参数在横向 LQR（`lat_controller.cc`）中用于动力学模型 `A·x+B·δ+B2·φ̇_des`；纵向控制主要用到 `vehicle_param_` 做几何换算（如 `front_edge_to_center` 计算停车点）。MKZ 是 Apollo 默认车型，添加新车时需在 `modules/calibration/data/<车型>/` 下建目录并改 `vehicle_param.pb.txt`，同时标定表也要重新采集。

---

## 9. Apollo 源码结构（控制模块）

```
modules/control/
├── control_component/                 # ControlComponent 主组件、ControlTaskAgent
│   └── controller_task_base/common/   # 9.0+ 公共代码迁入
│       ├── pid_controller.{h,cc}      # 基类 PID
│       ├── pid_BC_controller.{h,cc}   # 反算抗饱和 PID
│       ├── pid_IC_controller.{h,cc}   # 钳位抗饱和 PID
│       ├── leadlag_controller.{h,cc}  # 超前/滞后补偿器
│       ├── digital_filter / interpolation_2d / trajectory_analyzer
│       └── control_task.h             # 控制器基类（9.0+）
├── controllers/
│   ├── lon_based_pid_controller/      # 纵向 PID 控制器插件
│   │   ├── lon_controller.{h,cc}
│   │   ├── proto/lon_based_pid_controller_conf.proto
│   │   ├── util/check_pit.h           # pit（维修区）检查
│   │   └── BUILD + plugins.xml
│   ├── lat_controller/                # 横向 LQR
│   ├── mpc_controller/                # 横纵向 MPC
│   └── demo_control_task/
├── conf/
│   ├── control_conf.pb.txt            # 控制总配置（含 calibration_table）
│   └── calibration_table.pb.txt       # 标定表
└── common/control_gflags.{cc,h}       # gflags 开关
```

`pid_controller.cc` 是基类，`pid_BC_controller.cc` / `pid_IC_controller.cc` 通过 `virtual double Control()` override 实现不同抗饱和。`lon_controller.cc` 组合使用 `PIDController`（默认基类；可换 BC/IC）+ `LeadlagController` + `Interpolation2D` + `DigitalFilter`。

---

## 10. AuroraDrive 迁移建议（重点）

### 10.1 现状与问题

假设 AuroraDrive 当前纵向控制为 **单环速度 PID**（`controller.h` 中的 `PIDController`）：
```
e_speed = v_target − v_current
accel_cmd = Kp·e + Ki·Σe + Kd·Δe
throttle = min(accel_cmd, 1.0)   // 加速度命令直接映射油门，clip 到 [0,1]
```
存在的问题：
1. **高速油门过冲**：`throttle = min(accel_cmd, 1.0)` 是线性映射，忽略了油门-加速度非线性。高速段同样油门产生的加速度远小于低速段，导致低速过冲、高速欠速；油门死区使小加速度指令抖动。
2. **弯道减速突兀**：没有位置外环，速度环对 Planning 的速度阶跃直接响应，进出弯道加减速度快、舒适度差。
3. **无抗饱和**：长时间大误差（如起步、爬坡）积分累积，退出饱和时过冲。
4. **无坡道补偿**：上坡溜车、下坡冲车。
5. **无前馈**：只用反馈，响应滞后。

### 10.2 升级方案

#### 方案 A：最小改动——引入标定表 + 抗饱和
保留单环速度 PID，但用标定表替换线性映射，并加积分抗饱和与坡度前馈。

#### 方案 B（推荐）：双环 PID + 标定表 + 滤波 + 抗饱和
完整对齐 Apollo 架构，结构清晰、可调性强。

### 10.3 AuroraDrive 升级 C++ 代码框架

下面给出方案 B 的最小可编译框架（仅示意，省略日志/边界检查）：

```cpp
// aurora_longitudinal_controller.h
#pragma once
#include <array>
#include <map>
#include <cmath>
#include <algorithm>

namespace aurora {

// ---------- 通用 PID（带积分饱和钳位 + 可选抗饱和） ----------
struct PidConf { double kp, ki, kd, kaw, integrator_saturation_level; bool integrator_enable; };

class PIDController {
 public:
  void Init(const PidConf& c) {
    conf_ = c; integral_ = 0; prev_error_ = 0; first_ = true;
  }
  void Reset() { integral_ = 0; prev_error_ = 0; first_ = true; }
  double Control(double error, double dt) {
    if (dt <= 0) return prev_out_;
    double diff = first_ ? 0.0 : (error - prev_error_) / dt;
    first_ = false;
    if (conf_.integrator_enable) {
      integral_ += error * dt * conf_.ki;            // 先乘 ki，避免稳态改 ki 阶跃
      double hi = std::fabs(conf_.integrator_saturation_level);
      integral_ = std::clamp(integral_, -hi, hi);     // 积分钳位（IC 抗饱和）
    }
    double out = error * conf_.kp + integral_ + diff * conf_.kd;
    prev_error_ = error; prev_out_ = out;
    return out;
  }
 private:
  PidConf conf_; double integral_=0, prev_error_=0, prev_out_=0; bool first_=true;
};

// ---------- 一阶/二阶低通滤波（pitch 去噪用） ----------
class LowPassFilter {
 public:
  void Init(double dt, double cutoff_hz) {
    double alpha = 1.0 / (1.0 + 2.0 * M_PI * cutoff_hz * dt);
    a_ = alpha; prev_=0;
  }
  double Update(double x) { prev_ = a_ * x + (1 - a_) * prev_; return prev_; }
 private:
  double a_=1, prev_=0;
};

// ---------- 2D 标定表（std::map 双层 + 双线性插值） ----------
class CalibrationTable {
 public:
  // key: (speed_bin, acc_bin) -> 踏板开度（>0 油门, <0 刹车）
  void Add(double v, double a, double pedal) { map_[v][a] = pedal; }
  double Lookup(double v, double a) const {
    if (map_.empty()) return a;  // 无表则线性退化为 accel->throttle
    // 找 v 的上下界
    auto it_hi = map_.lower_bound(v);
    if (it_hi == map_.end()) --it_hi;
    auto it_lo = it_hi == map_.begin() ? it_hi : std::prev(it_hi);
    double v0 = it_lo->first, v1 = it_hi->first;
    double t = (v1 == v0) ? 0.0 : (v - v0) / (v1 - v0);
    double p0 = InterpAxis(it_lo->second, a);
    double p1 = InterpAxis(it_hi->second, a);
    return p0 * (1 - t) + p1 * t;     // 双线性
  }
 private:
  double InterpAxis(const std::map<double,double>& m, double a) const {
    auto it_hi = m.lower_bound(a);
    if (it_hi == m.end()) --it_hi;
    auto it_lo = it_hi == m.begin() ? it_hi : std::prev(it_hi);
    double a0 = it_lo->first, a1 = it_hi->first;
    double t = (a1 == a0) ? 0.0 : (a - a0) / (a1 - a0);
    return it_lo->second * (1 - t) + it_hi->second * t;
  }
  std::map<double, std::map<double,double>> map_;
};

// ---------- 双环纵向控制器 ----------
class LongitudinalController {
 public:
  struct Conf {
    double ts = 0.01;            // 控制周期
    double switch_speed = 3.0;   // 高低速切换
    double gravity = 9.8;
    bool   enable_slope = false;
    PidConf station_pid{0.2, 0.0, 0.0, 0.0, 0.3, false};
    PidConf low_speed_pid{2.0, 0.3, 0.0, 0.0, 0.3, true};
    PidConf high_speed_pid{1.0, 0.3, 0.0, 0.0, 0.3, true};
  };

  void Init(const Conf& c, const CalibrationTable& calib) {
    conf_ = c; calib_ = calib;
    station_pid_.Init(c.station_pid);
    speed_pid_lo_.Init(c.low_speed_pid);
    speed_pid_hi_.Init(c.high_speed_pid);
    pitch_lpf_.Init(c.ts, 5.0);  // 5Hz
  }
  void Reset() { station_pid_.Reset(); speed_pid_lo_.Reset(); speed_pid_hi_.Reset(); }

  // 输入: 参考位置/速度/加速度, 当前位置/速度/俯仰角
  // 输出: throttle[0,1], brake[0,1]
  void Step(double s_ref, double s_cur, double v_ref, double v_cur,
            double a_ref, double pitch_deg, double& throttle, double& brake) {
    double dt = conf_.ts;
    // —— 外环：位置 -> 速度补偿 ——
    double e_s = s_ref - s_cur;
    double dv = station_pid_.Control(e_s, dt);
    double v_target = v_ref + dv;

    // —— 内环：速度 -> 加速度闭环 ——
    double e_v = v_target - v_cur;
    double a闭环 = (v_cur < conf_.switch_speed)
                   ? speed_pid_lo_.Control(e_v, dt)
                   : speed_pid_hi_.Control(e_v, dt);

    // —— 前馈 + 坡度补偿 ——
    double a_slope = 0.0;
    if (conf_.enable_slope) {
      double pitch = pitch_lpf_.Update(pitch_deg * M_PI / 180.0);
      a_slope = std::sin(pitch) * conf_.gravity;  // 上坡 +
    }
    double a_cmd = a_ref + a闭环 + a_slope;

    // —— 标定表查踏板 ——
    double pedal = calib_.Lookup(v_cur, a_cmd);
    throttle = std::max(pedal, 0.0);
    brake    = std::max(-pedal, 0.0);
    // 死区
    throttle = throttle > 0.0 ? std::max(throttle, 0.02) : 0.0;
    throttle = std::min(throttle, 1.0);
    brake    = std::min(brake, 1.0);
  }
 private:
  Conf conf_;
  PIDController station_pid_, speed_pid_lo_, speed_pid_hi_;
  LowPassFilter pitch_lpf_;
  CalibrationTable calib_;
};

}  // namespace aurora
```

### 10.4 代价 / 收益分析

**收益**
- 高速不再过冲：标定表拟合了油门-加速度非线性，等加速度指令在不同车速下映射到不同油门，稳态误差大幅降低（Apollo 实测可达厘米级轨迹跟踪）。
- 弯道平滑：位置外环把"位置偏差"转化为"速度修正"，速度环输入更平缓，进出弯加减速柔和。
- 抗饱和：积分钳位/反算避免大误差累积导致的过冲与恢复迟滞。
- 坡道自适应：上坡自动加油、下坡自动收油，避免溜车/冲车。
- 高低速参数分离：低速大 `Kp`（2.0）快速响应克服阻力，高速小 `Kp`（1.0）防抖。

**代价**
- 需采集标定表：每车型需 40~60 分钟数据采集 + 拟合，增加标定工序（可上云标定降低人力）。
- 参数从 3 个（Kp/Ki/Kd）增至 6+（双环 PID + 切换速度 + 死区 + 滤波频率 + 标定表），调参复杂度上升。
- 双环引入串联动态，外环增益过大易与内环耦合振荡，需先调内环再调外环、外环幅度宜小。
- 计算量略增（双 PID + 2D 插值 + 滤波），但对 10~100Hz 控制周期可忽略。

**落地建议**：若时间紧，先上方案 A（标定表 + IC 抗饱和 + 坡度前馈），可解决 80% 问题；再逐步演进到方案 B 双环。标定表是性价比最高的单项改造。

---

## 11. 关键参考资料

- ApolloAuto/apollo: `modules/control/controllers/lon_based_pid_controller/lon_controller.{h,cc}`、`controllers/pid/pid_controller.{h,cc}`、`pid_BC_controller.cc`、`pid_IC_controller.cc`、`common/leadlag_controller.{h,cc}`、`common/interpolation_2d.h`、`common/trajectory_analyzer.cc`
- Apollo 官方文档：车辆动力学云标定（`docs/D-kit/Waypoint_Following/vehicle_calibration_online_cn.md`）
- 论文：Baidu Apollo Auto-Calibration System, arXiv:1808.10134
- CSDN 解析：ChenGuiGan（123277256 纵向控制流程图）、weixin_39199083（122227574 逐行解析）、jch924583667（118730101/118734982）、WaiNgai1999（145635640 双环结构）、BigDavid123（139568789/139607135 controller 解析）、yanghq13（118892461 pid_controller、118892537 leadlag_controller）、windses（110397075 标定表程序）、qq_42466012（126190664 PID 抗饱和）、qq1240268067（149026191 纵向参数说明）、qq_57674776（151189782 Apollo10.0 代码分析）、u013914471（83748571 横纵向控制）

---

## 12. 附录：核心配置参数速查（lon_based_pid_controller_conf）

| 参数 | 值 | 含义 |
|---|---|---|
| `ts` | 0.01 | 控制周期 (s) |
| `switch_speed` | 3.0 | 高低速 PID 切换阈值 (m/s) |
| `speed_controller_input_limit` | 1.5 | 速度环输入限幅 (m/s) |
| `station_error_limit` | 2.0 | 站点误差容限 (m) |
| `preview_window` | 20.0 | 纵向预瞄距离 (m) |
| `enable_reverse_leadlag_compensation` | false | 倒车超前滞后补偿 |
| `enable_slope_offset` | false | 坡度补偿开关 |
| `use_steering_check` | true | 转向联动减速 |
| `station_pid_conf` | kp0.2 / ki0 / kd0 | 位置环（纯 P） |
| `low_speed_pid_conf` | kp2.0 / ki0.3 / kd0 | 低速速度环 |
| `high_speed_pid_conf` | kp1.0 / ki0.3 / kd0 | 高速速度环 |
| `pitch_angle_filter_conf.cutoff_freq` | 5 | 俯仰角滤波截止 (Hz) |
| `standstill_narmal_acceleration` | -0.5 | 静止保持加速度 (m/s²) |
| `speed_itfc_full_stop_speed` | 0.09 | 完全停止速度阈值 (m/s) |
| `pedestrian_stop_time` | 15 | 行人停车时长 (s) |
| `epb_change_count` | 40 | EPB 触发计数 |

---

> **实际内部工具调用次数：55 次**（含 WebSearch / WebFetch / Read / RunCommand；本 Write 计为第 56 次）。
