# OpenPilot controlsd 100Hz 控制环深度研究报告

> 研究对象：commaai/openpilot `selfdrive/controls/controlsd.py`（master 分支，commit 389b639，2026-04-18，231 行 / 187 loc / 9.89 KB）
> 关联模块：`selfdrive/selfdrived/selfdrived.py`、`selfdrive/selfdrived/state.py`、`selfdrive/selfdrived/events.py`、`selfdrive/controls/lib/{longcontrol,latcontrol*}.py`、`openpilot/common/realtime.py`
> 研究方法：WebSearch + WebFetch（GitHub raw / grep.app 代码搜索 / CSDN 与 51CTO 解析文），共约 60 次内部工具调用

---

## 0. 架构演进重要前提

OpenPilot 在近一年内对控制栈做了一次关键解耦：**旧的 `controlsd.py` 同时承担"决策（状态机/事件/警报）"和"执行（PID/MPC/CarControl）"两个职责**，新版本把"决策"整体抽离到独立的 `selfdrived` 守护进程，`controlsd` 现在只保留"执行"。因此本报告分两条主线：

- **controlsd（执行器）**：100Hz 闭环，读 `selfdriveState`/`carState`/`modelV2`/`longitudinalPlan`，跑 LatControl + LongControl，发布 `carControl` + `controlsState`。
- **selfdrived（决策器）**：同样 100Hz，跑 `data_sample → update_events → state_machine.update → update_alerts → publish_selfdriveState`，发布 `selfdriveState` + `onroadEvents`。

两者通过 cereal 消息总线（SubMaster/PubMaster，基于 ZMQ）解耦，controlsd 以 `poll='selfdriveState'` 阻塞等待决策结果。理解 controlsd 必须同时理解 selfdrived，否则状态机/事件/警报部分会完全断片。

---

## 1. controlsd.py 整体结构

### 1.1 文件头与依赖

```python
#!/usr/bin/env python3
import math
from numbers import Number
from cereal import car, log
import cereal.messaging as messaging
from openpilot.common.constants import CV
from openpilot.common.params import Params
from openpilot.common.realtime import config_realtime_process, DT_CTRL, Priority, Ratekeeper
from openpilot.common.swaglog import cloudlog
from opendbc.car.car_helpers import interfaces
from opendbc.car.vehicle_model import VehicleModel
from openpilot.selfdrive.controls.lib.drive_helpers import clip_curvature
from openpilot.selfdrive.controls.lib.latcontrol import LatControl
from openpilot.selfdrive.controls.lib.latcontrol_pid import LatControlPID
from openpilot.selfdrive.controls.lib.latcontrol_angle import LatControlAngle, STEER_ANGLE_SATURATION_THRESHOLD
from openpilot.selfdrive.controls.lib.latcontrol_torque import LatControlTorque
from openpilot.selfdrive.controls.lib.longcontrol import LongControl
from openpilot.selfdrive.modeld.modeld import LAT_SMOOTH_SECONDS
from openpilot.selfdrive.locationd.helpers import PoseCalibrator, Pose

State = log.SelfdriveState.OpenpilotState
LaneChangeState = log.LaneChangeState
LaneChangeDirection = log.LaneChangeDirection
ACTUATOR_FIELDS = tuple(car.CarControl.Actuators.schema.fields.keys())
```

要点：
- `DT_CTRL = 0.01`（10ms，100Hz），定义在 `openpilot/common/realtime.py` 第 14 行，注释 "controlsd"。对比 `DT_MDL = 0.05`（20Hz，modeld）。
- `State` 直接复用 cereal 里 `SelfdriveState.OpenpilotState` 枚举，与 selfdrived 共享。
- `ACTUATOR_FIELDS` 在 NaN/Inf 兜底时遍历用。

### 1.2 Controls 类初始化 `__init__`

```python
class Controls:
  def __init__(self) -> None:
    self.params = Params()
    cloudlog.info("controlsd is waiting for CarParams")
    self.CP = messaging.log_from_bytes(self.params.get("CarParams", block=True), car.CarParams)
    cloudlog.info("controlsd got CarParams")
    self.CI = interfaces[self.CP.carFingerprint](self.CP)

    self.sm = messaging.SubMaster([
        'liveDelay', 'liveParameters', 'liveTorqueParameters', 'modelV2', 'selfdriveState',
        'liveCalibration', 'livePose', 'longitudinalPlan', 'lateralManeuverPlan', 'carState', 'carOutput',
        'driverMonitoringState', 'onroadEvents', 'driverAssistance'], poll='selfdriveState')
    self.pm = messaging.PubMaster(['carControl', 'controlsState'])

    self.steer_limited_by_safety = False
    self.curvature = 0.0
    self.desired_curvature = 0.0
    self.pose_calibrator = PoseCalibrator()
    self.calibrated_pose: Pose | None = None

    self.LoC = LongControl(self.CP)
    self.VM = VehicleModel(self.CP)
    self.LaC: LatControl
    if self.CP.steerControlType == car.CarParams.SteerControlType.angle:
      self.LaC = LatControlAngle(self.CP, self.CI, DT_CTRL)
    elif self.CP.lateralTuning.which() == 'pid':
      self.LaC = LatControlPID(self.CP, self.CI, DT_CTRL)
    elif self.CP.lateralTuning.which() == 'torque':
      self.LaC = LatControlTorque(self.CP, self.CI, DT_CTRL)
```

**输入订阅清单（14 路）**：

| 消息 | 发布者 | 用途 |
|------|--------|------|
| `carState` | card | 速度/转向角/踏板/档位/CruiseState/steerFault 等车辆状态 |
| `carOutput` | card | 上一帧 panda 实际下发的 actuator 值，用于饱和检测 |
| `selfdriveState` | selfdrived | enabled/active/state/alertText/personality（**poll 源**） |
| `onroadEvents` | selfdrived | 当前帧事件列表，用于 `overrideLongitudinal` 判断 |
| `modelV2` | modeld | 期望曲率 `action.desiredCurvature`、变道状态 `meta.laneChangeState` |
| `longitudinalPlan` | plannerd | `aTarget`/`shouldStop`/`hasLead` |
| `lateralManeuverPlan` | plannerd | 高级横向机动期望曲率（优先级高于 modelV2） |
| `liveParameters` | locationd | stiffnessFactor / steerRatio / angleOffsetDeg / roll 实时估计 |
| `liveTorqueParameters` | torqued | latAccelFactor / latAccelOffset / friction 实时学习值 |
| `liveDelay` | liveDelayd | lateralDelay 实测延迟 |
| `liveCalibration` / `livePose` | locationd | 设备→车体标定与位姿 |
| `driverMonitoringState` | dmonitoringd | alertLevel（用于 forceDecel） |
| `driverAssistance` | dmonitoringd | 左右车道偏离 `leftLaneDeparture/rightLaneDeparture` |

**输出发布（2 路）**：`carControl`（给 card→panda→CAN）、`controlsState`（给 UI/日志/调试）。

### 1.3 实时调度

```python
def main():
  config_realtime_process(4, Priority.CTRL_HIGH)
  controls = Controls()
  controls.run()
```

`config_realtime_process(4, Priority.CTRL_HIGH)` 把进程绑到 CPU 4、设为 SCHED_FIFO 高实时优先级 `CTRL_HIGH`。同优先级的还有 `selfdrived`、`card`、`ui`，均高于 plannerd/modeld/radard。这是 controlsd 能稳定跑 100Hz 的系统级保障。

---

## 2. 主循环（100Hz）

### 2.1 run 方法

```python
def run(self):
  rk = Ratekeeper(100, print_delay_threshold=None)
  while True:
    self.update()
    CC, lac_log = self.state_control()
    self.publish(CC, lac_log)
    rk.monitor_time()
```

`Ratekeeper(100)` 即 100Hz 节拍器，`monitor_time()` 统计抖动（`print_delay_threshold=None` 表示不打印告警，但内部仍记录）。每帧严格 10ms，三步流水线：**update（拉数据）→ state_control（算控制）→ publish（发报文）**。

### 2.2 update（输入对齐）

```python
def update(self):
  self.sm.update(15)  # 最多阻塞 15ms 等 poll 源 selfdriveState
  if self.sm.updated["liveCalibration"]:
    self.pose_calibrator.feed_live_calib(self.sm['liveCalibration'])
  if self.sm.updated["livePose"]:
    device_pose = Pose.from_live_pose(self.sm['livePose'])
    self.calibrated_pose = self.pose_calibrator.build_calibrated_pose(device_pose)
```

`sm.update(15)` 以 `selfdriveState` 为 poll 源阻塞等待（最长 15ms），保证每帧都有最新决策。校准位姿只在对应消息更新时重算，避免 100Hz 重复计算。

### 2.3 state_control（核心控制计算）

完整伪代码（按源码顺序）：

```python
def state_control(self):
  CS = self.sm['carState']

  # 1) 更新车辆模型（实时估计的刚度系数与转向比）
  lp = self.sm['liveParameters']
  x = max(lp.stiffnessFactor, 0.1)
  sr = max(lp.steerRatio, 0.1)
  self.VM.update_params(x, sr)
  steer_angle_without_offset = math.radians(CS.steeringAngleDeg - lp.angleOffsetDeg)
  self.curvature = -self.VM.calc_curvature(steer_angle_without_offset, CS.vEgo, lp.roll)

  # 2) 实时扭矩参数学习值回灌（仅 torque 模式）
  if self.CP.lateralTuning.which() == 'torque':
    torque_params = self.sm['liveTorqueParameters']
    if self.sm.all_checks(['liveTorqueParameters']) and torque_params.useParams:
      self.LaC.update_live_torque_params(
          torque_params.latAccelFactorFiltered,
          torque_params.latAccelOffsetFiltered,
          torque_params.frictionCoefficientFiltered)

  long_plan = self.sm['longitudinalPlan']
  model_v2 = self.sm['modelV2']

  # 3) 构造 CarControl 并决定 latActive / longActive
  CC = car.CarControl.new_message()
  CC.enabled = self.sm['selfdriveState'].enabled
  standstill = abs(CS.vEgo) <= max(self.CP.minSteerSpeed, 0.3) or CS.standstill
  CC.latActive = (self.sm['selfdriveState'].active
                  and not CS.steerFaultTemporary
                  and not CS.steerFaultPermanent
                  and (not standstill or self.CP.steerAtStandstill))
  CC.longActive = (CC.enabled
                   and not any(e.overrideLongitudinal for e in self.sm['onroadEvents'])
                   and self.CP.openpilotLongitudinalControl)

  actuators = CC.actuators
  actuators.longControlState = self.LoC.long_control_state

  # 4) 变道转向灯
  if model_v2.meta.laneChangeState != LaneChangeState.off:
    CC.leftBlinker = model_v2.meta.laneChangeDirection == LaneChangeDirection.left
    CC.rightBlinker = model_v2.meta.laneChangeDirection == LaneChangeDirection.right

  # 5) 失活时复位控制器（关键！避免积分饱和残留）
  if not CC.latActive:
    self.LaC.reset()
  if not CC.longActive:
    self.LoC.reset()

  # 6) 纵向 PID
  pid_accel_limits = self.CI.get_pid_accel_limits(self.CP, CS.vEgo, CS.vCruise * CV.KPH_TO_MS)
  actuators.accel = float(self.LoC.update(CC.longActive, CS, long_plan.aTarget,
                                          long_plan.shouldStop, pid_accel_limits))

  # 7) 横向：先 clip 曲率（jerk + lat accel 限制），再算转向
  if self.sm.valid['lateralManeuverPlan']:
    new_desired_curvature = self.sm['lateralManeuverPlan'].desiredCurvature if CC.latActive else self.curvature
  else:
    new_desired_curvature = model_v2.action.desiredCurvature if CC.latActive else self.curvature
  self.desired_curvature, curvature_limited = clip_curvature(
      CS.vEgo, self.desired_curvature, new_desired_curvature, lp.roll)

  lat_delay = self.sm["liveDelay"].lateralDelay + LAT_SMOOTH_SECONDS
  actuators.curvature = self.desired_curvature
  steer, steeringAngleDeg, lac_log = self.LaC.update(
      CC.latActive, CS, self.VM, lp,
      self.steer_limited_by_safety, self.desired_curvature,
      curvature_limited, lat_delay)
  actuators.torque = float(steer)
  actuators.steeringAngleDeg = float(steeringAngleDeg)

  # 8) NaN/Inf 兜底（防止 MPC/PID 数值病态导致 CAN 异常）
  for p in ACTUATOR_FIELDS:
    attr = getattr(actuators, p)
    if not isinstance(attr, Number):
      continue
    if not math.isfinite(attr):
      cloudlog.error(f"actuators.{p} not finite {actuators.to_dict()}")
      setattr(actuators, p, 0.0)

  return CC, lac_log
```

关键设计点：

1. **engage 时曲率复位**：`new_desired_curvature = ... if CC.latActive else self.curvature`。当横向刚激活时使用模型曲率，未激活时把期望曲率钉死在当前实际曲率，避免激活瞬间违反 clip_curvature 限制产生跳变。
2. **latActive 比 enabled 更严格**：即使 selfdrived 说 active，controlsd 还会再次校验 `steerFaultTemporary/Permanent` 和 `standstill`，是双保险。
3. **longActive 受 onroadEvents 拦截**：任何带 `overrideLongitudinal` 的事件（如驾驶员踩油门 `gasPressedOverride`）都会让纵向让权给驾驶员，但横向保持。
4. **失活必 reset**：LatControl/LongControl 都有积分项，不复位会导致下次激活时输出爆冲。
5. **延迟建模**：`lat_delay = liveDelay.lateralDelay + LAT_SMOOTH_SECONDS`，把实测 CAN 延迟 + 模型平滑时间一起喂给 LaC，用于前馈补偿（angle 模式做 Smith 预估器式补偿）。
6. **NaN/Inf → 0**：遍历所有 actuator 字段，非有限值一律清零并 cloudlog 报错，是最后一道数值安全网。

### 2.4 publish（构造并发送 CarControl / controlsState）

```python
def publish(self, CC, lac_log):
  CS = self.sm['carState']
  CC.currentCurvature = self.curvature
  if self.calibrated_pose is not None:
    CC.orientationNED = self.calibrated_pose.orientation.xyz.tolist()
    CC.angularVelocity = self.calibrated_pose.angular_velocity.xyz.tolist()

  CC.cruiseControl.override = CC.enabled and not CC.longActive and self.CP.openpilotLongitudinalControl
  CC.cruiseControl.cancel  = CS.cruiseState.enabled and (not CC.enabled or not self.CP.pcmCruise)
  CC.cruiseControl.resume = CC.enabled and CS.cruiseState.standstill and not self.sm['longitudinalPlan'].shouldStop

  hudControl = CC.hudControl
  hudControl.setSpeed       = float(CS.vCruiseCluster * CV.KPH_TO_MS)
  hudControl.speedVisible   = CC.enabled
  hudControl.lanesVisible   = CC.enabled
  hudControl.leadVisible    = self.sm['longitudinalPlan'].hasLead
  hudControl.leadDistanceBars = self.sm['selfdriveState'].personality.raw + 1
  hudControl.visualAlert    = self.sm['selfdriveState'].alertHudVisual
  hudControl.rightLaneVisible = True
  hudControl.leftLaneVisible  = True
  if self.sm.valid['driverAssistance']:
    hudControl.leftLaneDepart  = self.sm['driverAssistance'].leftLaneDeparture
    hudControl.rightLaneDepart = self.sm['driverAssistance'].rightLaneDeparture

  # 饱和检测：比较期望与 panda 实际下发
  if self.sm['selfdriveState'].active:
    CO = self.sm['carOutput']
    if self.CP.steerControlType == car.CarParams.SteerControlType.angle:
      self.steer_limited_by_safety = abs(CC.actuators.steeringAngleDeg - CO.actuatorsOutput.steeringAngleDeg) > STEER_ANGLE_SATURATION_THRESHOLD  # 2.5°
    else:
      self.steer_limited_by_safety = abs(CC.actuators.torque - CO.actuatorsOutput.torque) > 1e-2

  # controlsState（给 UI / 调试 / rlogd）
  dat = messaging.new_message('controlsState')
  dat.valid = CS.canValid
  cs = dat.controlsState
  cs.curvature = self.curvature
  cs.longitudinalPlanMonoTime = self.sm.logMonoTime['longitudinalPlan']
  cs.lateralPlanMonoTime     = self.sm.logMonoTime['modelV2']
  cs.desiredCurvature = self.desired_curvature
  cs.longControlState = self.LoC.long_control_state
  cs.upAccelCmd = float(self.LoC.pid.p)
  cs.uiAccelCmd = float(self.LoC.pid.i)
  cs.ufAccelCmd = float(self.LoC.pid.f)
  cs.forceDecel = bool((self.sm['driverMonitoringState'].alertLevel == log.DriverMonitoringState.AlertLevel.three)
                       or (self.sm['selfdriveState'].state == State.softDisabling))
  # lateralControlState：按控制类型回填 pidState/angleState/torqueState
  ...
  self.pm.send('controlsState', dat)

  # carControl（给 card → panda → CAN）
  cc_send = messaging.new_message('carControl')
  cc_send.valid = CS.canValid
  cc_send.carControl = CC
  self.pm.send('carControl', cc_send)
```

亮点：
- **`steer_limited_by_safety`** 是闭环反馈：controlsd 算出的期望值 vs panda 实际下发值（`carOutput.actuatorsOutput`）做差，超过阈值（角度 2.5°、扭矩 0.01）就置位。下一帧 LatControl 拿到这个标志后会**冻结积分器**，防止 Panda 安全模型 clamp 导致积分饱和。
- **`forceDecel`**：驾驶员监控 alertLevel==three（严重分心）或处于 softDisabling 时，UI 会显示强减速提示，纵向逻辑也会据此加大制动。
- **`cruiseControl.override/cancel/resume`**：对 pcmCruise 车型（借用原车 ACC），openpilot 通过这三个信号控制原车 PCM；对 openpilotLongitudicalControl 车型则直接发 accel。

---

## 3. 状态机（核心，位于 selfdrived/state.py）

### 3.1 状态枚举与常量

```python
State = log.SelfdriveState.OpenpilotState   # disabled / preEnabled / enabled / overriding / softDisabling
SOFT_DISABLE_TIME = 3   # seconds
ACTIVE_STATES  = (State.enabled, State.softDisabling, State.overriding)
ENABLED_STATES = (State.preEnabled, *ACTIVE_STATES)

MAINTAIN_STATES = {
  State.enabled:      (None,),
  State.disabled:     (None,),
  State.softDisabling:(ET.SOFT_DISABLE,),
  State.preEnabled:   (ET.PRE_ENABLE,),
  State.overriding:   (ET.OVERRIDE_LATERAL, ET.OVERRIDE_LONGITUDINAL),
}
ENABLE_EVENT_TYPES = (ET.ENABLE, ET.PRE_ENABLE, ET.OVERRIDE_LATERAL, ET.OVERRIDE_LONGITUDINAL)
```

注意：**没有显式 `hardDisabling` 状态**。硬禁用（IMMEDIATE_DISABLE）是"事件→动作"，直接把 state 置为 `disabled`，不经过中间态。softDisabling 才是带倒计时的中间态（3 秒 = 300 步 @ 100Hz）。

### 3.2 StateMachine.update 核心逻辑

```python
class StateMachine:
  def __init__(self):
    self.state = State.disabled
    self.soft_disable_timer = 0

  def update(self, events: Events):
    # 每步递减（进入 softDisabling 时重置为 300）
    self.soft_disable_timer = max(0, self.soft_disable_timer - 1)

    # --- 当前非 disabled：检查退出触发 ---
    if self.state != State.disabled:
      if events.contains(ET.USER_DISABLE):           # 驾驶员主动取消
        self.state = State.disabled
      elif events.contains(ET.IMMEDIATE_DISABLE):    # 关键故障，立即退
        self.state = State.disabled
      elif self.state == State.enabled:
        if events.contains(ET.SOFT_DISABLE):         # 非关键问题，软退
          self.state = State.softDisabling
          self.soft_disable_timer = int(SOFT_DISABLE_TIME / DT_CTRL)   # 300
      elif self.state == State.softDisabling:
        if not events.contains(ET.SOFT_DISABLE):
          self.state = State.enabled                 # 条件清除，恢复
        elif self.soft_disable_timer <= 0:
          self.state = State.disabled                # 倒计时归零，彻底退

    # --- 当前 disabled：检查激活触发 ---
    elif self.state == State.disabled:
      if events.contains(ET.ENABLE) and not events.contains(ET.NO_ENTRY):
        self.state = State.enabled

    # --- preEnabled / overriding 分支（简化） ---
    elif self.state == State.preEnabled:
      if not events.contains(ET.PRE_ENABLE):
        self.state = State.enabled
    # overriding：OVERRIDE_LATERAL/OVERRIDE_LONGITUDINAL 事件清除后回 enabled

    enabled = self.state in ENABLED_STATES
    active  = self.state in ACTIVE_STATES
    return enabled, active
```

### 3.3 状态转换图（文字版）

```
                       ET.ENABLE (且无 NO_ENTRY)
        ┌──────────────────────────────────────────────────┐
        │                                                  ▼
┌───────────────┐   ET.PRE_ENABLE    ┌──────────────┐  PRE_ENABLE 清除   ┌──────────┐
│   disabled    │ ─────────────────▶ │  preEnabled  │ ────────────────▶ │ enabled  │
│ (初始/终态)   │ ◀───────────────── │ (等松刹车等) │ ◀──────────────── │ (主控态) │
└───────────────┘   PRE_ENABLE 失效  └──────────────┘                    └──────────┘
        ▲                                                                     │
        │                                                                     │
        │  ET.IMMEDIATE_DISABLE (硬禁用，立即)                                 │
        │  ET.USER_DISABLE (驾驶员主动取消)                                    │
        │  soft_disable_timer <= 0 (3 秒倒计时结束)                            │
        └─────────────────────────────────────────────────────────────────────┘
                                                                              │
                                              ET.SOFT_DISABLE (软禁用)        │
                                                                              ▼
                                                                       ┌───────────────┐
                                              SOFT_DISABLE 清除 (恢复)   │  softDisabling │
                                       ┌────────────────────────────────  │ (3 秒倒计时)   │
                                       │      (倒计时未到且条件消失)       └───────────────┘
                                       └──────────────────────────────────────────▶ enabled

        ET.OVERRIDE_LATERAL (转向覆盖) / ET.OVERRIDE_LONGITUDINAL (油门覆盖)
        enabled ────────────────────────────────────────────────▶ overriding
        overriding ─────────── OVERRIDE 事件清除 ───────────────▶ enabled
```

**enabled vs active 的区别**：
- `enabled = state in (preEnabled, enabled, softDisabling, overriding)` → "系统开着"
- `active = state in (enabled, softDisabling, overriding)` → "系统正在主动控制执行器"

controlsd 用 `selfdriveState.active` 决定 `latActive`，用 `selfdriveState.enabled` 决定 `CC.enabled`。preEnabled 期间 enabled=True 但 active=False，所以不会真的发转向/油门指令，只是"预备"。

---

## 4. 事件系统 Events（selfdrived/events.py）

### 4.1 EventType（ET）枚举

事件类型是"事件对状态机的作用类别"，共 9 种：

| ET 类型 | 中文含义 | 对状态机的作用 |
|---------|----------|----------------|
| `ET.ENABLE` | 启用 | disabled → enabled（前提：无 NO_ENTRY） |
| `ET.PRE_ENABLE` | 预启用 | disabled → preEnabled |
| `ET.OVERRIDE_LATERAL` | 横向覆盖 | enabled → overriding（横向让权） |
| `ET.OVERRIDE_LONGITUDINAL` | 纵向覆盖 | enabled → overriding（纵向让权） |
| `ET.USER_DISABLE` | 用户主动退 | 任意非 disabled → disabled（立即） |
| `ET.IMMEDIATE_DISABLE` | 立即退（硬禁用） | 任意非 disabled → disabled（立即，关键故障） |
| `ET.SOFT_DISABLE` | 软退 | enabled → softDisabling（3 秒倒计时） |
| `ET.NO_ENTRY` | 禁止进入 | 阻止 ENABLE 生效 |
| `ET.WARNING` | 警告 | 不改变状态，仅触发警报 |
| `ET.PERMANENT` | 永久 | 系统级不可用（如传感器失效），不进 onroad |

### 4.2 Events 容器

```python
class Events:
  def __init__(self):
    self.events: list[OnroadEvent] = []
    ...
  def add(self, event_name, static=False):
    ...
  def contains(self, event_type) -> bool: ...
  def clear(self): ...
```

selfdrived 每帧 `self.events.clear()` 后重新填充，是无状态的"当前帧快照"。

### 4.3 EventName → {ET: Alert} 映射表（EVENTS dict 摘录）

事件名（`log.OnroadEvent.EventName`）通过 `EVENTS` 大字典映射到"该事件会触发哪些 ET、对应哪个 Alert"。下面是研究期间从 grep.app 检索到的真实条目：

| EventName | ET | Alert 类 | alertText2 |
|-----------|-----|----------|------------|
| `buttonEnable` | ENABLE | EngagementAlert(engage.wav) | — |
| `buttonCancel` | USER_DISABLE, NO_ENTRY | EngagementAlert(disengage.wav) / NoEntryAlert("Cancel Pressed") | — |
| `pedalPressed` | USER_DISABLE | EngagementAlert(disengage.wav) | — |
| `pcmDisable` | USER_DISABLE | EngagementAlert(disengage.wav) | — |
| `parkBrake` | USER_DISABLE | EngagementAlert(disengage.wav) | — |
| `gasPressedOverride` | OVERRIDE_LONGITUDINAL | Alert(...) | — |
| `steerOverride` | OVERRIDE_LATERAL | Alert(...) | — |
| `steerUnavailable` | IMMEDIATE_DISABLE | ImmediateDisableAlert | "LKAS Fault: Restart the Car" |
| `canError` | IMMEDIATE_DISABLE | ImmediateDisableAlert | "Unknown Vehicle Variant" |
| `controlsMismatch` | IMMEDIATE_DISABLE | ImmediateDisableAlert | "Controls Mismatch" |
| `commIssue` | SOFT_DISABLE, NO_ENTRY | soft_disable_alert | "Communication Issue Between Processes" |
| `commIssueAvgFreq` | SOFT_DISABLE | soft_disable_alert | "Low Communication Rate Between Processes" |
| `doorOpen` | SOFT_DISABLE | user_soft_disable_alert | "Door Open" |
| `wrongGear` | SOFT_DISABLE | user_soft_disable_alert | "Gear not D" |
| `reverseGear` | PERMANENT | Alert(...) | — |
| `belowSteerSpeed` | WARNING | below_steer_speed_alert | — |
| `speedTooLow` | WARNING / NO_ENTRY | — | — |
| `invalidLkasSetting` | PERMANENT | invalid_lkas_setting_alert | — |
| `sensorDataInvalid` | PERMANENT | Alert(...) | — |
| `lowBattery` | SOFT_DISABLE | soft_disable_alert | "Low Battery" |
| `driverDistracted1/2/3` | WARNING | DM 序列警报 | — |
| `manualRestart` | WARNING | — | — |
| `outOfSpace` | PERMANENT | NormalPermanentAlert | "Out of Storage", "{perc}% full" |
| `overheat` | PERMANENT（注释中）/ WARNING | — | — |

### 4.4 Alert 体系（alerts.py）

```python
@dataclass
class Alert:
  text1: str = ""
  text2: str = ""
  status: AlertStatus = AlertStatus.normal      # normal / userPrompt / critical
  size: AlertSize = AlertSize.mid               # none / small / mid / full
  priority: Priority = Priority.LOWEST          # LOWEST / LOW / MID / HIGH / HIGHEST
  visual_alert: VisualAlert = VisualAlert.none
  audible_alert: AudibleAlert = AudibleAlert.none
  duration: float = 0.0
  ...
```

Alert 子类（构造模式）：

| Alert 子类 | 用途 | 典型场景 |
|-----------|------|----------|
| `EmptyAlert` | 空警报（LOWEST, none, none） | 占位 |
| `EngagementAlert(AudibleAlert)` | 启用/禁用提示音 | buttonEnable/pedalPressed |
| `NoEntryAlert(text2)` | 拒绝启用 | NO_ENTRY 事件 |
| `ImmediateDisableAlert(text2)` | 立即退（红色全屏） | IMMEDIATE_DISABLE |
| `SoftDisableAlert(text2)` | 软退（3 秒倒计时全屏） | SOFT_DISABLE |
| `UserSoftDisableAlert(text2)` | 用户触发的软退（语气更温和） | doorOpen/wrongGear |
| `NormalPermanentAlert(text1, text2)` | 永久性提示 | outOfSpace/sensorDataInvalid |

`soft_disable_alert` 工厂函数会根据剩余倒计时切换：若 `soft_disable_time < 0.5/DT_CTRL`（即 < 50 步）退化为 `ImmediateDisableAlert`，否则用 `SoftDisableAlert`。

### 4.5 AlertManager

```python
class AlertManager:
  def __init__(self) -> None:
    self.alerts: dict[int, AlertEntry] = {}    # event_type → AlertEntry
  def add_many(self, frame, alerts): ...
  def process_alerts(self, frame, clear_event_types):
    ae = AlertEntry()
    ...
```

selfdrived 每帧调用：
```python
self.AM.add_many(self.sm.frame, alerts)
self.AM.process_alerts(self.sm.frame, clear_event_types)
```

AlertManager 维护"每个 ET 当前对应的 Alert"，按 Priority 排序选出最高优先级警报，写入 `selfdriveState.alertText1/alertText2/alertStatus/alertSound/alertHudVisual`，供 UI 显示与 controlsd 的 `hudControl.visualAlert` 回填。

AudibleAlert 声音资源（`sounds.py`）：

```python
AudibleAlert.engage:           ("engage.wav", 1, MAX_VOLUME)
AudibleAlert.disengage:        ("disengage.wav", 1, MAX_VOLUME)
AudibleAlert.refuse:           ("refuse.wav", 1, MAX_VOLUME)        # NO_ENTRY
AudibleAlert.prompt:           ("prompt.wav", 1, MAX_VOLUME)        # 单次握手提醒
AudibleAlert.promptRepeat:     ("prompt.wav", None, MAX_VOLUME)     # 重复握手提醒
AudibleAlert.promptDistracted: ("prompt_distracted.wav", None, MAX_VOLUME)
AudibleAlert.preAlert:         ("pre_alert.wav", 1, MAX_VOLUME)
...
```

---

## 5. driver_disengage（驾驶员主动干预）

位于 `selfdrived.py` 的 `update_events`，核心在 L226-230：

```python
# Disable on rising edge of accelerator or brake. Also disable on brake when speed > 0
if (CS.gasPressed and not self.CS_prev.gasPressed and self.disengage_on_accelerator) or \
   (CS.brakePressed and (not self.CS_prev.brakePressed or not CS.standstill)) or \
   (CS.regenBraking and (not self.CS_prev.regenBraking or not CS.standstill)):
  self.events.add(EventName.pedalPressed)
```

同时在 `car/car_specific.py`（card 进程，预填一部分事件）：

```python
if CS.gasPressed:
  events.add(EventName.gasPressedOverride)        # 持续按油门 → 纵向覆盖（不退出）
if CS.steeringPressed:
  events.add(EventName.steerOverride)             # 转方向盘 → 横向覆盖（不退出）
if CS.steeringDisengage and not CS_prev.steeringDisengage:
  events.add(EventName.steerOverrideDisengage)    # 某些车型大力转方向盘 → 退出
```

**设计哲学**：
- **油门上升沿 / 刹车**：触发 `pedalPressed` → `ET.USER_DISABLE` → 立即退出（除非 `DisengageOnAccelerator` 参数关闭，部分地区法规不允许踩油门退出）。
- **持续踩油门**：触发 `gasPressedOverride` → `ET.OVERRIDE_LONGITUDINAL` → 进入 overriding 态，纵向让权但**横向继续居中**，松开油门自动恢复 enabled。
- **轻转方向盘**：触发 `steerOverride` → `ET.OVERRIDE_LATERAL` → 横向让权但**纵向继续 ACC**，松手恢复。
- **大力转方向盘**（车型特定 `steeringDisengage`）：直接退出。

这套"覆盖 vs 退出"的二分设计让 openpilot 在驾驶员轻微干预时不必整体退出，体验远胜传统 ACC 一碰方向盘就 resign 的方案。

---

## 6. comm issues（通信问题）

`selfdrived.py` L339-361 集中处理通信健康：

```python
# 1) 雷达 CAN 错误
if self.sm['radarState'].radarErrors.canError:
  self.events.add(EventName.canError)
elif self.sm['radarState'].radarErrors.radarUnavailableTemporary:
  ...
# 2) CarState CAN 无效
elif not CS.canValid:
  self.events.add(EventName.canError)

# 3) 进程间消息存活/频率
if not self.sm.all_alive():
  self.events.add(EventName.commIssue)
elif not self.sm.all_freq_ok():
  self.events.add(EventName.commIssueAvgFreq)
else:
  self.events.add(EventName.commIssue)   # 兜底

# 4) 传感器数据 10 秒超时
if any((self.sm.frame - self.sm.recv_frame[s]) * DT_CTRL > 10. for s in self.sensor_packets):
  self.events.add(EventName.sensorDataInvalid)
```

判定规则：
- **canError** → `ET.IMMEDIATE_DISABLE`（"Unknown Vehicle Variant"，立即退。注释"This is usually caused by faulty wiring"）。
- **commIssue**（任一订阅消息死活检测失败）→ `ET.SOFT_DISABLE` + `ET.NO_ENTRY`（"Communication Issue Between Processes"）。
- **commIssueAvgFreq**（频率低于阈值，如某进程超过 10× 期望间隔或平均间隔超 10%）→ `ET.SOFT_DISABLE`（"Low Communication Rate Between Processes"）。
- **sensorDataInvalid**（加速度计/陀螺仪 10 秒没更新）→ `ET.PERMANENT`（永久不可用，不进 onroad）。

`sm.all_alive()` / `sm.all_freq_ok()` 是 cereal messaging 内置的看门狗：每个 SubMaster 跟踪所有订阅消息的 `recv_frame` 与期望频率，自动判定 alive/freq_ok。这是 openpilot 分布式架构能容错的关键——任何一个守护进程卡死都不会让 controlsd "盲开"。

---

## 7. LatControl / LongControl

### 7.1 LatControl 三种模式

controlsd 在 `__init__` 按 `CP.steerControlType` 和 `CP.lateralTuning.which()` 选择：

```python
if self.CP.steerControlType == car.CarParams.SteerControlType.angle:
  self.LaC = LatControlAngle(self.CP, self.CI, DT_CTRL)       # 角度模式
elif self.CP.lateralTuning.which() == 'pid':
  self.LaC = LatControlPID(self.CP, self.CI, DT_CTRL)         # PID 模式
elif self.CP.lateralTuning.which() == 'torque':
  self.LaC = LatControlTorque(self.CP, self.CI, DT_CTRL)      # 扭矩模式（现代主流）
```

抽象基类 `LatControl(ABC)`：

```python
class LatControl(ABC):
  @abstractmethod
  def update(self, active, CS, VM, params, steer_limited_by_safety,
             desired_curvature, curvature_limited, lat_delay):
    ...
  def _check_saturation(self, saturated, CS, steer_limited_by_safety, curvature_limited):
    # 饱和计数：连续饱和则 sat_count 累加，否则衰减
    if (saturated or curvature_limited) and CS.vEgo > self.sat_check_min_speed \
       and not steer_limited_by_safety and not CS.steeringPressed:
      self.sat_count += self.sat_count_rate
    else:
      self.sat_count -= self.sat_count_rate
    self.sat_count = np.clip(self.sat_count, 0.0, self.sat_limit)
    return self.sat_count > (self.sat_limit - 1e-3)
```

#### A. LatControlPID（latcontrol_pid.py）

```python
class LatControlPID(LatControl):
  def __init__(self, CP, CI):
    self.ff_factor = CP.lateralTuning.pid.kf
    self.get_steer_feedforward = CI.get_steer_feedforward_function()
    self.pid = PIDController((kpBP, kpV), (kiBP, kiV), k_f=kf)

  def update(self, active, CS, VM, params, steer_limited_by_safety,
             desired_curvature, curvature_limited, lat_delay):
    angle_steers_des = math.degrees(VM.get_steer_from_curvature(desired_curvature, CS.vEgo)) + params.angleOffsetDeg
    angle_steers_des_no_offset = angle_steers_des - params.angleOffsetDeg
    error = angle_steers_des - CS.steeringAngleDeg

    ff = self.ff_factor * self.get_steer_feedforward(angle_steers_des_no_offset, CS.vEgo)
    freeze_integrator = steer_limited_by_safety or CS.steeringPressed or CS.vEgo < 5
    output = self.pid.update(error, feedforward=ff, speed=CS.vEgo, freeze_integrator=freeze_integrator)
    ...
```

`get_steer_feedforward_default`：`return desired_angle * (v_ego**2)`（回正力矩正比于横向加速度）。雪佛兰 Volt 有专门 sigmoid 模型。**积分冻结条件**：安全饱和、驾驶员转方向盘、车速 < 5m/s，防止低速/干预时积分漂移。

#### B. LatControlAngle（latcontrol_angle.py）

直接发期望转向角度给车辆（如福特、部分丰田）。`STEER_ANGLE_SATURATION_THRESHOLD = 2.5°`。带 `lat_delay` 做前馈补偿（Smith 预估器风格），把期望角按延迟时间前推，抵消 CAN 传输 + 执行器响应滞后。

#### C. LatControlTorque（latcontrol_torque.py，现代主流）

基于横向加速度闭环：

```python
desired_lateral_accel = desired_curvature * CS.vEgo ** 2
actual_lateral_accel  = actual_curvature  * CS.vEgo ** 2
# 低速非线性补偿
low_speed_factor = np.interp(CS.vEgo, LOW_SPEED_X, LOW_SPEED_Y) ** 2
setpoint     = desired_lateral_accel + low_speed_factor * desired_curvature
measurement  = actual_lateral_accel  + low_speed_factor * actual_curvature

# 摩擦力补偿 + 死区
ff = gravity_adjusted_lateral_accel
ff -= self.torque_params.latAccelOffset
ff += get_friction(desired_lateral_accel - actual_lateral_accel, ...)
```

实时学习值通过 `update_live_torque_params(latAccelFactor, latAccelOffset, friction)` 回灌，torqued 守护进程在后台用驾驶日志在线辨识这三参数。

#### D. 横向 MPC（lat_mpc.py，运行在 plannerd 不在 controlsd）

虽然 controlsd 不直接调 MPC，但 `lateralManeuverPlan.desiredCurvature` 由 plannerd 用 LateralMpc 生成。MPC 模型：

```python
# 状态：x_ego, y_ego, psi_ego, psi_rate_ego
# 控制：psi_accel_ego
# 5 项成本：path / heading / lat_accel / lat_jerk / steering_rate
# Acados C 代码生成，32 步滚动时域，0.05s/步，SQP-RTI 求解器，<10ms
```

### 7.2 clip_curvature（drive_helpers.py，关键 clamp）

```python
def clip_curvature(v_ego, prev_curvature, new_curvature, roll) -> tuple[float, bool]:
  # 1) 横向加加速度（jerk）限制
  max_curvature_rate = MAX_LATERAL_JERK / (v_ego ** 2)
  new_curvature = np.clip(new_curvature,
                          prev_curvature - max_curvature_rate * DT_CTRL,
                          prev_curvature + max_curvature_rate * DT_CTRL)
  # 2) 横向加速度限制（含道路侧倾补偿）
  roll_compensation = roll * ACCELERATION_DUE_TO_GRAVITY
  max_lat_accel = MAX_LATERAL_ACCEL_NO_ROLL + roll_compensation
  min_lat_accel = -MAX_LATERAL_ACCEL_NO_ROLL + roll_compensation
  new_curvature, limited_accel = clamp(new_curvature,
                                       min_lat_accel / v_ego ** 2,
                                       max_lat_accel / v_ego ** 2)
  return float(new_curvature), limited_accel or limited_max_curv
```

两层限制：
- **Jerk 限制**：曲率变化率 ≤ `MAX_LATERAL_JERK / v²`，保证横向加加速度（舒适度指标）有界。
- **Lat accel 限制**：曲率 ≤ `MAX_LATERAL_ACCEL / v²`，且叠加道路侧倾补偿（上坡弯道允许更大曲率）。

### 7.3 LongControl（longcontrol.py）

```python
LongCtrlState = car.CarControl.Actuators.LongControlState   # off / stopping / starting / pid

class LongControl:
  def __init__(self, CP):
    self.long_control_state = LongCtrlState.off
    self.pid = PIDController(...)
    self.last_output_accel = 0.0

  def update(self, active, CS, a_target, should_stop, accel_limits):
    # 1) 状态机切换
    self.long_control_state = long_control_state_trans(
        self.CP, active, self.long_control_state,
        CS.vEgo, should_stop, CS.brakePressed, CS.cruiseState.standstill)

    # 2) 按状态输出
    output_accel = 0.0
    if self.long_control_state == LongCtrlState.stopping:
      output_accel = self.last_output_accel - self.CP.stoppingDecelRate * DT_CTRL   # 受控减速
    elif self.long_control_state == LongCtrlState.starting:
      output_accel = self.CP.startAccel                                            # 起步加速度
    elif self.long_control_state == LongCtrlState.pid:
      error = a_target - CS.aEgo
      output_accel = self.pid.update(error, speed=CS.vEgo, feedforward=a_target)

    # 3) clamp 到安全范围
    self.last_output_accel = np.clip(output_accel, accel_limits[0], accel_limits[1])
    return self.last_output_accel
```

`accel_limits = CI.get_pid_accel_limits(CP, vEgo, vCruise*KPH_TO_MS)` 返回 `(ACCEL_MIN, ACCEL_MAX)`，按车型与巡航速度动态收窄（接近巡航速度时上限变小，模拟原车 PCM 行为）。

纵向规划（`aTarget`/`shouldStop`/`hasLead`）由 plannerd 的 LongitudinalPlanner + LongitudinalMPC 生成，controlsd 只做"跟踪 aTarget"这一层。

---

## 8. CarControl 构造与输出限制

### 8.1 CarControl 字段全景

```
CarControl
├── enabled: bool                    # 系统是否启用
├── latActive: bool                  # 横向是否主动控制
├── longActive: bool                 # 纵向是否主动控制
├── actuators
│   ├── longControlState: enum       # off/stopping/starting/pid
│   ├── accel: float                 # 期望加速度 (m/s²)
│   ├── curvature: float             # 期望曲率 (1/m)
│   ├── torque: float                # 期望转向扭矩 (某些车型)
│   └── steeringAngleDeg: float      # 期望转向角 (angle 模式)
├── cruiseControl
│   ├── override: bool               # 覆盖原车 PCM
│   ├── cancel: bool                 # 取消原车巡航
│   └── resume: bool                 # 恢复原车巡航
├── leftBlinker / rightBlinker: bool # 变道转向灯
├── hudControl
│   ├── setSpeed: float              # HUD 显示设定速度
│   ├── speedVisible / lanesVisible / leadVisible: bool
│   ├── leadDistanceBars: int        # 跟车距离条数（personality + 1）
│   ├── visualAlert: enum            # 视觉警报类型
│   ├── leftLaneVisible / rightLaneVisible: bool
│   └── leftLaneDepart / rightLaneDepart: bool
├── currentCurvature: float          # 当前实际曲率（反馈）
├── orientationNED: list[3]          # 校准姿态
└── angularVelocity: list[3]         # 角速度
```

### 8.2 输出限制（clamp）四层防线

| 层级 | 位置 | 限制内容 |
|------|------|----------|
| 1. 曲率 clamp | `clip_curvature`（controlsd） | jerk ≤ MAX_LATERAL_JERK/v²；lat_accel ≤ MAX_LATERAL_ACCEL/v²（+roll 补偿） |
| 2. 加速度 clamp | `LongControl.update` | `np.clip(output, ACCEL_MIN, ACCEL_MAX)`，按车型/巡航速度动态 |
| 3. NaN/Inf 兜底 | `state_control` 末尾 | 遍历 ACTUATOR_FIELDS，非有限值 → 0.0 + cloudlog 报错 |
| 4. Panda 硬件安全模型 | panda 固件（CAN 发送前） | steer 角度变化率、扭矩上限、方向盘转角 delta、gas/brake 互斥、controls_allowed 心跳超时 → 0 |

第 4 层是**硬件级**的，controlsd 无法绕过。即使 controlsd 进程崩溃或被破解，panda 安全模型也会在 100ms 心跳超时后自动切断 actuator。这是 openpilot 安全设计的基石。

### 8.3 反馈延迟建模

```python
lat_delay = self.sm["liveDelay"].lateralDelay + LAT_SMOOTH_SECONDS
```

- `liveDelay.lateralDelay`：由 liveDelayd 实测的"期望曲率 → 实际转向角"延迟（CAN 传输 + EPS 响应）。
- `LAT_SMOOTH_SECONDS`：模型输出的平滑时间常数。

两者相加喂给 LatControl（特别是 LatControlAngle），用于前馈补偿——把当前期望角按延迟时间"前推"到未来时刻，抵消滞后。这是 openpilot 在高速大曲率弯道仍能精确居中的关键。

### 8.4 steer_limited_by_safety 闭环

```python
if self.sm['selfdriveState'].active:
  CO = self.sm['carOutput']
  if self.CP.steerControlType == car.CarParams.SteerControlType.angle:
    self.steer_limited_by_safety = abs(CC.actuators.steeringAngleDeg - CO.actuatorsOutput.steeringAngleDeg) > 2.5
  else:
    self.steer_limited_by_safety = abs(CC.actuators.torque - CO.actuatorsOutput.torque) > 1e-2
```

`carOutput` 是 panda 实际下发到 CAN 的值（可能被安全模型 clamp 过）。比较"controlsd 期望"与"panda 实际"，超过阈值说明被 clamp。下一帧：
- LatControlPID：`freeze_integrator = steer_limited_by_safety or ...` → 冻结积分，防止 windup。
- LatControlTorque：饱和计数 `_check_saturation` 累加，达阈值后上报 `steerSaturated` 事件。

---

## 9. AuroraDrive 迁移建议

### 9.1 AuroraDrive 当前控制环现状（来自项目交接文档）

| 维度 | AuroraDrive 现状 | OpenPilot controlsd |
|------|------------------|---------------------|
| 控制频率 | 24Hz（`simulator.h:284` `dt = 1.0/24.0`） | 100Hz（DT_CTRL=0.01） |
| 传感器频率 | 1Hz（已降频减少负载） | modeld 20Hz / radard 20Hz / card 100Hz |
| 状态机 | **无**（只有 `assist_auto_.load()` 布尔开关） | 5 态 + 倒计时 |
| 事件系统 | **无** | 9 种 ET + 数十种 EventName + AlertManager |
| driver_disengage | **无**（A/D/W/S 是注入键，无反向输入检测） | 上升沿检测 + 覆盖 vs 退出二分 |
| 通信健康 | **无**（线程崩了就静默失效） | sm.all_alive/all_freq_ok + commIssue 事件 |
| 输出 clamp | **无**（直接映射 A/D 键，无曲率/加速度限制） | 4 层防线 + Panda 硬件安全模型 |
| 横向控制 | PurePursuit + A/D 键（阈值 0.5m） | LatControl 三模式 + clip_curvature |
| 纵向控制 | PID 40km/h + W/S 键 | LongControl 4 态状态机 + accel_limits |
| 饱和检测 | **无** | steer_limited_by_safety 闭环 |
| 数值兜底 | **无** | NaN/Inf → 0.0 |

**核心结论**：AuroraDrive AUTO 模式目前是"裸奔"控制环——没有状态机意味着无法优雅降级，没有事件系统意味着无法告诉用户为什么退出，没有 clamp 意味着理论上可能发出危险指令（虽然映射成键盘后影响有限，但一旦未来接真实 CAN 就是隐患）。

### 9.2 借鉴 controlsd 状态机设计

**建议引入 5 态状态机**（适配 AuroraDrive 仿真语境）：

```
disabled（初始）
  │ assist_auto_.load() && 无 NO_ENTRY
  ▼
preEnabled（等条件，如车速 > 5km/h）
  │ 条件满足
  ▼
enabled（主控）
  │ 用户踩刹车/按取消/规划失败
  ├──▶ softDisabling（3 秒倒计时，UI 提示"接管"）
  │       │ 倒计时结束
  │       ▼
  │    disabled
  │ 用户轻转方向盘/踩油门
  ▼
overriding（让权但保持 enabled，松手恢复）
```

对应 C++ 实现（在 `simulator.h` 加 `enum class AutoState`）：

```cpp
enum class AutoState { Disabled, PreEnabled, Enabled, SoftDisabling, Overriding };
struct AutoStateMachine {
  AutoState state = AutoState::Disabled;
  int soft_disable_timer = 0;  // 24Hz × 3s = 72 步
  void update(const AutoEvents& events) {
    soft_disable_timer = std::max(0, soft_disable_timer - 1);
    if (state != AutoState::Disabled) {
      if (events.user_disable) state = AutoState::Disabled;
      else if (events.immediate_disable) state = AutoState::Disabled;
      else if (state == AutoState::Enabled && events.soft_disable) {
        state = AutoState::SoftDisabling;
        soft_disable_timer = 72;
      } else if (state == AutoState::SoftDisabling) {
        if (!events.soft_disable) state = AutoState::Enabled;
        else if (soft_disable_timer <= 0) state = AutoState::Disabled;
      }
    } else if (events.enable && !events.no_entry) {
      state = AutoState::Enabled;
    }
  }
  bool enabled() const { return state != AutoState::Disabled; }
  bool active()  const { return state == AutoState::Enabled
                              || state == AutoState::SoftDisabling
                              || state == AutoState::Overriding; }
};
```

### 9.3 借鉴 Events 系统

定义 `EventType` 枚举与事件→类型映射表：

```cpp
enum class EventType {
  Enable, PreEnable, OverrideLateral, OverrideLongitudinal,
  UserDisable, ImmediateDisable, SoftDisable, NoEntry, Warning, Permanent
};

struct AutoEvent { EventType type; std::string text; };

// 每帧填充
std::vector<AutoEvent> update_events(const SimulationState& s, const SimulationState& prev) {
  std::vector<AutoEvent> ev;
  // 驾驶员干预（键盘反向输入检测）
  if (s.user_brake && !prev.user_brake) ev.push_back({EventType::UserDisable, "Brake"});
  if (s.user_throttle) ev.push_back({EventType::OverrideLongitudinal, "Throttle Override"});
  if (s.user_steer)    ev.push_back({EventType::OverrideLateral, "Steer Override"});
  // 通信健康
  if (!s.sim_thread_alive) ev.push_back({EventType::SoftDisable, "Sim Thread Dead"});
  if (s.fps < 15)          ev.push_back({EventType::SoftDisable, "Low FPS"});
  // 规划失败
  if (!s.has_path)         ev.push_back({EventType::ImmediateDisable, "No Path"});
  // 速度过低
  if (s.vEgo < 1.0 && s.active) ev.push_back({EventType::Warning, "Speed Too Low"});
  return ev;
}
```

### 9.4 借鉴 driver_disengage

AuroraDrive 当前用 CGEvent 注入 A/D/W/S 键，但**完全不检测用户的反向输入**。建议：

1. **检测用户键盘/手柄反向输入**：若 AUTO 在转 A（左转）但用户按 D（右转），触发 `OverrideLateral` 而非直接退出。
2. **油门上升沿退出**：用户从松开到踩油门（W 键按下沿）→ `UserDisable`；持续踩油门 → `OverrideLongitudinal`（纵向让权，横向保持居中）。
3. **刹车立即退**：S 键或 Space → `UserDisable`（仿真里刹车即停，无需 soft）。
4. **Space 紧急停**：`ImmediateDisable` + 强制 `forceDecel`。

这能让 AUTO 模式从"一碰就 resign"升级到"轻干预让权、重干预退出"，体验质变。

### 9.5 控制环频率与分层建议

**不要直接把 AuroraDrive 物理从 24Hz 提到 100Hz**——物理积分 100Hz 会显著增加 CPU 负担且对自行车模型收益有限。建议**分离决策/控制/物理三层**：

| 层级 | 频率 | 内容 |
|------|------|------|
| 决策层（selfdrived 等价） | 24Hz（复用现有 sim_loop） | 状态机 + Events + Alert |
| 控制层（controlsd 等价） | 50-100Hz（新线程） | LatControl + LongControl + clamp + CarControl 构造 |
| 物理层 | 24Hz（保持） | BicycleModel::step 积分 |

控制层从决策层读 `AutoState` + `desired_curvature` + `aTarget`，独立跑高频 PID，把输出写回物理层。这样：
- 24Hz 决策够用（人类反应 ~250ms，24Hz=42ms 远快于反应）。
- 50-100Hz 控制让 PID 微分项更平滑，转向不再"一格一格"。
- 物理保持 24Hz，CPU 不爆。

### 9.6 引入输出 clamp（安全护城河）

即使仿真里撞了不疼，也建议加 clamp，培养"安全肌肉记忆"，未来接真实 CAN 时无缝迁移：

```cpp
struct ActuatorLimits {
  float max_lat_accel = 3.0f;       // m/s²，对应 MAX_LATERAL_ACCEL_NO_ROLL
  float max_lat_jerk  = 2.0f;       // m/s³
  float accel_min = -4.0f, accel_max = 2.0f;
};

float clip_curvature(float v_ego, float prev_curv, float new_curv, float roll) {
  float max_rate = limits.max_lat_jerk / std::max(v_ego*v_ego, 1.0f);
  new_curv = std::clamp(new_curv, prev_curv - max_rate*dt, prev_curv + max_rate*dt);
  float max_accel = limits.max_lat_accel + roll * 9.81f;
  new_curv = std::clamp(new_curv, -max_accel/(v_ego*v_ego), max_accel/(v_ego*v_ego));
  return new_curv;
}
```

把 PurePursuit 输出的转向角先转成曲率，过 clip_curvature，再映射 A/D 键——这样即使 PurePursuit 算出激进转弯，也会被 jerk/accel 限制削平，转向更平滑。

### 9.7 引入饱和检测与积分冻结

当前 AuroraDrive 的 PID 速度环若长时间饱和（目标 40km/h 但上坡达不到），积分会 windup，下坡时爆冲。借鉴 controlsd：

```cpp
bool steer_limited = std::abs(desired_steer - actual_steer) > 5.0f;  // 度
if (steer_limited || user_steer || vEgo < 2.0f) {
  pid.freeze_integrator();  // 冻结积分
}
```

### 9.8 引入 comm issue 检测

AuroraDrive 当前线程崩了会静默失效（交接文档 BUG-003 提到 detached thread 同步不可靠）。建议加看门狗：

```cpp
struct CommWatchdog {
  std::atomic<uint64_t> sim_frame{0}, capture_frame{0}, planner_frame{0};
  bool all_alive() const {
    auto now = global_frame.load();
    return now - sim_frame < 10 && now - capture_frame < 100 && now - planner_frame < 50;
  }
};
// 每个线程每帧 ++自己的计数器
// 决策层每帧检查，任一超时 → 添加 commIssue 事件 → SoftDisable
```

### 9.9 迁移路线图（建议优先级）

| 优先级 | 任务 | 工时 | 收益 |
|--------|------|------|------|
| P1 | 引入 AutoStateMachine（disabled/enabled/softDisabling） | 4h | 优雅降级，告别"裸奔" |
| P1 | 引入 driver_disengage 键盘反向输入检测 | 3h | 体验质变 |
| P1 | 引入输出 clamp（clip_curvature + accel_limits） | 3h | 安全护城河 |
| P2 | 引入 Events 系统 + AlertManager + HUD 提示 | 6h | 用户可感知失败原因 |
| P2 | 引入 comm issue 看门狗 | 3h | 线程崩了不再静默 |
| P2 | 控制层分离到 50-100Hz 独立线程 | 6h | 转向平滑度提升 |
| P3 | LatControl 多策略（保留 PurePursuit 为 angle 模式，加 PID/torque） | 8h | 控制精度提升 |
| P3 | steer_limited_by_safety 饱和检测 + 积分冻结 | 3h | 防 windup |
| P3 | NaN/Inf 兜底 | 1h | 数值安全网 |

---

## 10. 总结

OpenPilot controlsd 是一个**经过百万公里实车验证的 100Hz 控制环**，其设计精髓不在于单个算法多复杂，而在于**系统级的防御性设计**：

1. **决策/执行解耦**：selfdrived 管"该做什么"，controlsd 管"怎么做"，任一崩溃另一个能安全降级。
2. **5 态状态机**：disabled/preEnabled/enabled/overriding/softDisabling，配合 3 秒软禁用倒计时，让退出过程可预测、可恢复。
3. **9 种 EventType + 数十种 EventName**：把所有异常情况标准化为事件，状态机只看 ET，警报由 AlertManager 按 Priority 选最高级显示。
4. **driver_disengage 二分设计**：油门/刹车上升沿退出，转向/持续油门覆盖，体验远胜传统 ACC。
5. **4 层输出 clamp**：clip_curvature → accel_limits → NaN/Inf 兜底 → Panda 硬件安全模型，软件再怎么出错硬件兜底。
6. **steer_limited_by_safety 闭环**：期望 vs 实际比较，冻结积分防 windup。
7. **实时调度保障**：config_realtime_process + Ratekeeper(100) + CPU 亲和性，确保 10ms 节拍。

AuroraDrive 当前 AUTO 模式相比之是"裸奔"控制环——没有状态机、没有事件、没有 clamp、没有 driver_disengage、没有通信健康检测。借鉴 controlsd 的设计不需要照搬全部代码，关键是引入**状态机思维、事件驱动、输出 clamp、驾驶员覆盖**这四件套，即可让 AuroraDrive 从"能跑"升级到"安全可降级"。完整的 100Hz 实时调度与 Panda 硬件安全模型对仿真非必需，可作为未来接真实车辆时的进阶目标。

---

## 附：研究调用次数

**实际内部工具调用次数：约 60 次**

包括：
- WebSearch：约 18 次（controlsd / selfdrived / events / alerts / longcontrol / latcontrol / driver_disengage / panda safety / DT_CTRL 等）
- WebFetch：约 38 次（GitHub controlsd.py 源码、grep.app 代码搜索 30+ 次、CSDN/51CTO 解析文 8 次）
- Read：约 4 次（读取大输出文件）
- LS / Grep / TodoWrite：辅助工具若干

主要信息源：
- `github.com/commaai/openpilot/blob/master/selfdrive/controls/controlsd.py`（完整源码）
- `grep.app` 检索 `openpilot/selfdrived/events.py`、`state.py`、`selfdrived.py`、`car_specific.py`、`realtime.py`、`alerts.py` 关键片段
- CSDN `2301_80171004` 的 sunnypilot 系列解析（selfdrived/controlsd/LatControl/CarInterface/pandad 五章）
- 51CTO OpenPilot Common 模块深度分析
- 项目内 `AuroraDrive项目交接文档.md`
