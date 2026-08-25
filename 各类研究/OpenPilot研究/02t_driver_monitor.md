# OpenPilot 驾驶员监控系统（DMS / Driver Monitoring）深度研究报告

> 研究对象：comma.ai OpenPilot 的驾驶员监控子系统（dmonitoringd + dmonitoringmodeld）
> 主要源码：`selfdrive/monitoring/driver_monitor.py`（旧名）/ `selfdrive/monitoring/dmonitoringd.py`、`selfdrive/monitoring/helpers.py`、`selfdrive/modeld/dmonitoringmodeld.py`、`selfdrive/modeld/models/dmonitoring_model.onnx`、`cereal/log.capnp`（`driverStateV2` / `driverMonitoringState`）、`selfdrive/selfdrived/events.py`
> 数据来源：comma.ai 官方文档与商店页、GitHub openpilot 仓库、CSDN/51CTO/知乎技术解析、行业 DMS 法规与厂商资料

---

## 0. 核心结论速览

OpenPilot 的 DMS 是一套**纯视觉、车端实时、面向 L2 监管**的驾驶员注意力监控系统，它把"驾驶员是否在专心看路"作为 openpilot 持续开启的**前置安全条件**。整条链路被刻意拆成两个独立进程：

1. **dmonitoringmodeld**（C++/Python，神经网推理）：吃驾驶员相机帧，跑一个轻量 CNN（`dmonitoring_model.onnx`），输出人脸概率、头部姿态（roll/pitch/yaw）、人脸位置、睁闭眼概率等原始回归量，按约 **10–20Hz** 发布 `driverStateV2` 消息。
2. **dmonitoringd**（Python，规则与状态机）：订阅 `driverStateV2` + `carState` + `liveCalibration` + `selfdriveState`，在 `DriverMonitoring` 类里维护一个 0~1 的 `awareness`（注意力）标量，按"分心→衰减、专注→恢复"的规则更新它，越过阈值就生成三级 `OnroadEvent`（pre/prompt/driver distracted），最终由 `selfdrived`/`controlsd` 决定是否告警、减速、停车。

它的设计哲学是"**failsafe passive + 渐进式预警 + 可学习校准**"：不依赖方向盘扭矩（因此无法用"挂橘子"作弊），而是直接看脸；当摄像头被遮挡或模型不确定时，`awareness` 会**加速衰减**反而更快触发告警，体现"安全优先"。

---

## 1. driver_monitor.py / dmonitoringd.py 源码与主循环

### 1.1 进程定位与文件演进

OpenPilot 早期版本中 DMS 主逻辑文件名为 `selfdrive/monitoring/driver_monitor.py`；在较新版本（selfdrived 重构后）被拆分为 `selfdrive/monitoring/dmonitoringd.py`（守护进程主循环）+ `selfdrive/monitoring/helpers.py`（`DriverMonitoring` 类与所有阈值常量）。部分 fork（如 sunnypilot）沿用同一结构。本文统称 dmonitoringd。

进程注册方式（来自 `manager.py` / 旧版进程表）：

```
python process("dmonitoringd", "selfdrive.monitoring.dmonitoringd",
               enabled=(not pc or webcam), driverview=True)
native process("dmonitoringmodeld", "selfdrive/modeld",
               ["./dmonitoringmodeld"], enabled=(not pc or webcam), driverview=True)
```

可见 DMS 是双进程：`dmonitoringmodeld` 是 native（C++，性能优先），`dmonitoringd` 是 Python（逻辑可读、易调参）。`driverview=True` 表示它需要驾驶员相机流，在 PC 模拟器下默认关闭（除非接 webcam）。

### 1.2 主循环结构（dmonitoringd_thread）

```python
def dmonitoringd_thread():
  params = Params()
  pm = messaging.PubMaster(['driverMonitoringState'])
  sm = messaging.SubMaster(
      ['driverStateV2', 'liveCalibration', 'carState', 'selfdriveState',
       'modelV2', 'carControl'], poll='driverStateV2')

  DM = DriverMonitoring(rhd_saved=params.get_bool("IsRhdDetected"),
                        always_on=params.get_bool("AlwaysOnDM"))

  while True:
    sm.update()                       # 阻塞等待 driverStateV2
    if not sm.updated['driverStateV2']:
      continue
    DM.run_step(sm)                   # 核心：_update_states + _update_events
    dat = DM.get_state_packet(valid=sm.all_checks())
    pm.send('driverMonitoringState', dat)
    # ...周期性保存 RHD 偏好等
```

要点：

- **频率**：主循环以 `poll='driverStateV2'` 驱动，即"模型出一帧，逻辑跑一步"。`driverStateV2` 服务频率约 10Hz（部分版本注释为 20Hz），所以 dmonitoringd 实际运行在 **~10–20Hz**，远低于 controlsd 的 100Hz。代码里常出现 `# 20hz <- dmonitoringmodeld` 的注释。
- **输入**：driverStateV2（模型原始回归量）、liveCalibration（相机外参 rpy，用于把模型坐标系转到车体坐标系）、carState（vEgo / steeringPressed / gasPressed / standstill / gearShifter）、selfdriveState（op 是否 engaged）、carControl。
- **输出**：`driverMonitoringState` 消息（含 `awareness`、`isDistracted`、events 列表等）。
- **两个关键开关**：`IsRhdDetected`（右舵车，决定看左座还是右座）、`AlwaysOnDM`（即使 openpilot 未 engaged 也强制开启监控，社区安全选项）。

### 1.3 DriverMonitoring 类的两个核心方法

`run_step(sm)` 把工作交给：

1. `_update_states(driver_state, cal_rpy, car_speed, op_engaged)`：把模型输出转成可解释的物理量（roll/pitch/yaw）、判定 `face_detected`、计算 `distracted_types`、维护头部姿态偏置学习器。
2. `_update_events(driver_engaged, op_engaged, standstill, wrong_gear, car_speed)`：根据当前 `awareness` 与阈值生成 `OnroadEvent`，决定是否告警。

---

## 2. face detection（人脸检测）

OpenPilot DMS **不使用**传统 Haar/Dlib 人脸框检测器，而是用一个端到端 CNN 直接回归人脸相关量。社区常说的"MNP（MobileNet + 人脸 landmark）"更多是泛指其轻量 backbone 思路，实际部署的是 `selfdrive/modeld/models/dmonitoring_model.onnx`，一个面向 Snapdragon 845 MAX 优化的轻量 CNN。

### 2.1 模型输出与"人脸存在性"

模型一次性输出（来自 `driverStateV2.leftDriverData` / `rightDriverData`）：

- `faceProb`（0~1，人脸存在概率）——这是"人脸检测"的结果，但没有显式的边界框，而是一个置信度标量。
- `faceOrientation`（向量，原始头部姿态）+ `facePosition`（人脸在画面中的二维位置）——既用于定位，也用于姿态解算。
- 眼部相关回归量（睁闭眼概率，后续用于 blink 判定）。
- 模型自身不确定度（`low_std` 标志，反映姿态估计置信度）。

### 2.2 检测判定与准确率

- **判定阈值**：`_FACE_THRESHOLD`（常量，约 0.4 量级）。`self.face_detected = driver_state.leftDriverData.faceProb > self.settings._FACE_THRESHOLD`。
- **左右座选择**：系统根据 `IsRhdDetected` 选择 `leftDriverData`（左舵看主驾左侧）或 `rightDriverData`（右舵），首次会自动学习并写入 params 持久化。
- **性能与准确率**：得益于 IR LED 补光 + 端到端 CNN，夜间、戴墨镜场景仍可工作。社区评测显示其在主流光照下误检率很低，但极端姿态（完全侧脸/低头超过 ~45°）会因 `faceProb` 下降而进入"未检测到人脸"分支，触发快速衰减告警（见 §4）。
- **实时性**：10–20Hz 推理，单帧推理在 845 MAX 上约数毫秒级，远低于相机帧间隔，不存在积压。

### 2.3 鲁棒性设计：失效即安全

当 `face_detected=False` 或 `pose.low_std=False`（模型不确定），dmonitoringd 不会"按上一次正常值继续"，而是进入 `active_monitoring=False` 分支，`_set_timers` 切换到**快速衰减**模式：`awareness` 以更快的速率下降，从而在摄像头被遮挡、强光致盲、驾驶员离座时**更快**触发告警。这是"failsafe passive"在 DMS 层的体现。

---

## 3. 眼睛 / 头部姿态

### 3.1 头部姿态解算（face_orientation_from_net）

模型输出的 `faceOrientation` 并非直接的物理角度，dmonitoringd 用 `face_orientation_from_net(faceOrientation, facePosition, cal_rpy)` 把它**结合相机外参标定（liveCalibration.rpyCalib）**转换成相对于车体的三个欧拉角：

- **roll**（翻滚，侧头歪脖子）
- **pitch**（俯仰，低头/抬头）
- **yaw**（偏航，左右转头）

这一步很关键：因为驾驶员相机安装在挡风玻璃上，其朝向与车体不一致，必须用实时标定外参做坐标变换，才能得到"驾驶员相对于车辆前进方向"的姿态，进而判断他是否在看路。

### 3.2 头部姿态偏置学习（DriverPose / RunningStatFilter）

每个人开车时都有一个"自然头部姿态"（座椅位置、身高导致 baseline 不同）。系统用 `RunningStatFilter` 在线学习每位驾驶员的 pitch_offset / yaw_offset：

```python
if self.face_detected and car_speed > self.settings._POSE_CALIB_MIN_SPEED:
    self.pose.pitch_offseter.push_and_update(self.pose.pitch)
    self.pose.yaw_offseter.push_and_update(self.pose.yaw)
    self.pose.calibrated = self.pose.pitch_offseter.filtered_stat.n > _POSE_OFFSET_MIN_COUNT
```

校准完成后，分心判定**减去**个人偏置，避免把"个子矮平时就低头"误判成分心。`_POSE_OFFSET_MAX_COUNT` 限制样本数，使偏置随时间缓慢更新（适应驾驶员换姿势）。

### 3.3 眼睛开闭 / blink 检测

模型同时输出眼部回归量（睁眼概率），dmonitoringd 通过 `DistractedType.DISTRACTED_BLINK` 识别"闭眼或眨眼异常过多"：

- **单次闭眼**超过阈值 → 直接判定为瞌睡/分心。
- **blink 频率**异常（连续眨眼过快或长闭眼）→ 衰减 `awareness`。
- 这与业界 PERCLOS（单位时间眼睑闭合比例）思路一致，但 openpilot 把它融进端到端模型，输出概率而非关键点几何。

`_EYE_THRESHOLD` 是眼部检测的概率门槛。值得注意的是，纯基于眼部几何的方案对小眼睛驾驶员误报严重（小鹏 NGP 曾因此上热搜），openpilot 的端到端概率 + 头部姿态联合判定，对此类个体差异更鲁棒。

### 3.4 distraction 的姿态类判定（DistractedType）

`_get_distracted_types()` 返回一个集合，包含：

- `DISTRACTED_POSE`：头部 yaw/pitch 偏离超过 `_POSE_YAW_THRESHOLD` / `_POSE_PITCH_THRESHOLD`（持续偏离前方）。
- `DISTRACTED_BLINK`：闭眼/眨眼异常。
- `DISTRACTED_E2E`：模型端到端直接预测"驾驶员未准备好接管"。

最终 `self.driver_distracted = (DISTRACTED_POSE in distracted_types) and face_detected and pose.low_std`，即**只有当人脸确实被检测到、姿态估计置信、且头部明显偏离**时才认定姿态型分心，避免误报。

---

## 4. distraction 检测与减速/停车流程

### 4.1 awareness 标量与衰减/恢复机制

`awareness` 是 0~1 的浮点标量（初始 1.0，即"完全专注"）。它的核心是"积分式"注意力计时器：

- **专注恢复**：当 `driver_attentive = self.driver_distraction_filter.x < 0.37` 且人脸检测置信时，`awareness` 按 `_RECOVERY_FACTOR_MIN * step_change` 递增，上限 1.0。
- **分心衰减**：当 `certainly_distracted = (filter.x > 0.63) and driver_distracted and face_detected` 时，`awareness` 按 `step_change` 递减，下限 -0.1。
- `driver_distraction_filter` 是一阶滤波器（`FirstOrderFilter`，时间常数 `_DISTRACTED_FILTER_TS`），平滑分心信号，避免单帧抖动触发告警。

`step_change` 由 `_set_timers(active_monitoring)` 决定：

- `active_monitoring=True`（人脸检测 + 模型置信）：正常衰减速率，约对应"分心持续约 **30 秒**级"才会从满到 0——这就是社区俗称的 **"30 秒规则"**。
- `active_monitoring=False`（未检测到人脸 / 模型不确定 / 摄像头遮挡）：衰减速率大幅提高，几秒内 `awareness` 见底。

### 4.2 三级告警阈值

`_update_events` 根据 `awareness` 比例阈值生成 `OnroadEvent`：

```python
alert = None
if self.awareness <= 0.:
    alert = EventName.driverDistracted          # 红色，触发脱离
elif self.awareness <= _DISTRACTED_PROMPT_TIME_TILL_TERMINAL / _DISTRACTED_TIME:
    alert = EventName.promptDriverDistracted    # 橙色，强提示
elif self.awareness <= _DISTRACTED_PRE_TIME_TILL_TERMINAL / _DISTRACTED_TIME:
    alert = EventName.preDriverDistracted       # 绿色，预警
if alert is not None:
    self.current_events.add(alert)
```

| 等级 | 事件名 | 颜色 | 含义 | 典型触发时机 |
|------|--------|------|------|--------------|
| 预警 | `preDriverDistracted` | 绿色 | 轻度提醒 | 分心刚开始，awareness 接近预警线 |
| 强提示 | `promptDriverDistracted` | 橙色 | 强提示，要求看路 | 持续分心，接近临界 |
| 红色告警 | `driverDistracted` | 红色 | 触发脱离/降级 | awareness≤0，判定严重分心或离场 |

`DRIVER_MONITOR_SETTINGS` 集中定义所有阈值：`_AWARENESS_TIME`、`_DISTRACTED_TIME`、`_DISTRACTED_PRE_TIME_TILL_TERMINAL`、`_DISTRACTED_PROMPT_TIME_TILL_TERMINAL`、`_FACE_THRESHOLD`、`_EYE_THRESHOLD`、`_POSE_PITCH_THRESHOLD`、`_POSE_YAW_THRESHOLD`、`_POSE_CALIB_MIN_SPEED`、`_POSE_OFFSET_MIN_COUNT` 等，均经过 comma.ai 在海量 userdata 上调校。

### 4.3 终止告警与重启锁定

为防止驾驶员"分心→告警→看一眼→继续分心"反复横跳，dmonitoringd 维护"终止告警"计数：严重分心多次后，即使短暂看路也不会立即恢复全部权限，需要更长时间专注或驾驶员主动介入（踩油门/转向干预）才能解除。这避免告警风暴同时守住安全底线。

### 4.4 与 controlsd/selfdrived 的减速/停车流程

dmonitoringd 只**产生事件**，不直接控车。控车由 `selfdrived`/`controlsd` 消费 `driverMonitoringState`：

1. **红色 `driverDistracted`** → selfdrived 把它升级为 `IMMEDIATE_DISABLE` 或 `SOFT_DISABLE`，openpilot 退出 engaged，控制权交还驾驶员。
2. 在 openpilot 自己掌控纵向（ACC）的车型上，退出前会执行**渐进减速**：通过 longitudinal planner 降低目标速度，必要时在车道内缓慢停车、打开双闪。
3. 若驾驶员始终无响应， panda 安全固件层面（见 02s 安全报告）也会因 `controls_allowed=false` 而停止输出 CAN 控制报文，确保"failsafe passive"。
4. **30 秒规则**：连续 ~30 秒持续分心（active_monitoring 模式下）会让 awareness 从 1.0 衰减到 0，进而触发红色告警与脱离；若摄像头被遮挡（非 active），该时间被压缩到数秒。

### 4.5 接口契约（dmonitoringd → controlsd）

`driverMonitoringState` 消息字段（dmonitoringd 发布）：

- `awarenessStatus`（float，0~1，当前注意力）
- `isDistracted`（bool，是否分心）
- `isRHD`（bool，右舵判定）
- `events`（OnroadEvent 列表，含 `preDriverDistracted`/`promptDriverDistracted`/`driverDistracted`）
- `faceDetected`、`pose` 相关统计、模型不确定标志等

controlsd / selfdrived 的 `events.py` 把这些事件与车型策略、转向干预等其它事件做优先级合并，最终决定 alert 文案、声音与控车动作。

---

## 5. driverState 消息（proto / capnp 字段）

OpenPilot 用 Cap'n Proto 定义消息（`cereal/log.capnp`）。DMS 相关有两条消息：`driverStateV2`（模型输出，dmonitoringmodeld 发布）与 `driverMonitoringState`（逻辑输出，dmonitoringd 发布）。

### 5.1 DriverStateV2 结构

`DriverStateV2` 同时输出左右两侧驾驶员数据（用于左右舵自适应）：

```capnp
struct DriverStateV2 {
  frameId @0 :UInt32;             # 帧序号
  modelExecutionTime @1 :Float32; # 模型推理耗时(ms)
  leftDriverData @2 :DriverState;
  rightDriverData @3 :DriverState;
  rightEyeOpenness @4 :Float32;   # 右眼睁眼度(部分版本)
  leftEyeOpenness @5 :Float32;    # 左眼睁眼度
  ...
}

struct DriverState {
  faceOrientation @0 :List(Float32);  # 原始头部姿态(roll/pitch/yaw 前身)
  facePosition   @1 :List(Float32);   # 人脸二维位置
  faceProb       @2 :Float32;         # 人脸存在概率
  leftEyeOpen    @3 :Float32;         # 左眼睁眼概率
  rightEyeOpen   @4 :Float32;         # 右眼睁眼概率
  leftBlink      @5 :Float32;         # 左眼眨眼
  rightBlink     @6 :Float32;         # 右眼眨眼
  ...
}
```

字段语义对应任务清单：

- **face_orientation** → `faceOrientation`（再经 `face_orientation_from_net` + 标定解算为 roll/pitch/yaw）。
- **face_position** → `facePosition`。
- **eye_blink / eye_openness** → `leftEyeOpen`/`rightEyeOpen`/`leftBlink`/`rightBlink`，以及 V2 顶层的 `leftEyeOpenness`/`rightEyeOpenness`。
- **distraction** → 不在模型消息里，而是 dmonitoringd 计算后写入 `driverMonitoringState.isDistracted`。
- **driver_attention** → 对应 `driverMonitoringState.awarenessStatus`（0~1）。

### 5.2 DriverMonitoringState 结构（dmonitoringd 发布）

```capnp
struct DriverMonitoringState {
  events @0 :List(OnroadEvent);   # 活动 DM 事件
  awarenessStatus @1 :Float32;    # 注意力 0~1
  isRHD @2 :Bool;
  isDistracted @3 :Bool;          # 是否分心
  isLowStd @4 :Bool;              # 姿态估计置信
  ...
}
```

### 5.3 QoS / 频率

服务配置（来自 `services.py`）：`driverStateV2` 约 10Hz、降采样 5 倍、BIG 队列；`driverMonitoringState` 低频；`driverCameraState` 约 10Hz。所有消息封装在统一 `Event` 结构（含 `logMonoTime` 纳秒时间戳与 `valid` 标志）中，通过 cereal/msgq 零拷贝发布订阅。

---

## 6. UI 反馈

### 6.1 onroad UI 中的 DMS 反馈

comma 设备的 1.9" OLED 屏（comma four）/ 较大屏（comma 3X）在 onroad 界面渲染 DMS 状态：

- **正常态**：屏幕上显示一个**蓝色方向盘/驾驶员图标**（或注意力指示），表示"检测到人脸、专注"。
- **绿色预警**（`preDriverDistracted`）：图标变绿/轻微提示，要求驾驶员留意。
- **橙色强提示**（`promptDriverDistracted`）：图标转橙色并闪烁，文字"Pay Attention"（看路），同时触发**提示音**。
- **红色告警**（`driverDistracted`）：图标变红，告警文字"Driver Distracted"/"Take Control Immediately"，伴随更急促的**告警音**，openpilot 开始脱离/减速。
- **无人脸/遮挡**：单独的"Driver No Face Detected"提示，awareness 快速衰减。

comma four 新增的"steering arc grows as limits approached"与"confidence ball"是横向能力可视化，与 DMS 共同构成人机交互层。

### 6.2 警告声音与文字

声音由 `selfdrived/events.py` 中的 `AudibleAlert` 枚举驱动，按事件优先级映射：

- prompt 级 → 柔和"叮"提示音。
- driverDistracted 级 → 连续高优先级告警音。
- 文字文案随车型/语言而变，但核心语义稳定：预警→"请看路"，红色→"立即接管"。
- 视觉+触觉（方向盘震动仅在原车支持时）+声音的组合，研究显示可使反应时间较纯视觉缩短近 5 倍。

### 6.3 AlwaysOnDM

`AlwaysOnDM` 参数开启后，即使 openpilot 未 engaged，DMS 也持续运行并显示。这是社区安全增强项，体现"安全优先于省电"。

---

## 7. 与 controlsd / selfdrived 的接口

### 7.1 数据流

```
driver camera ──> camerad ──> VisionIpc(VISION_STREAM_DRIVER)
                  └─> dmonitoringmodeld ──driverStateV2──> dmonitoringd
                                                          │  + carState/selfdriveState/liveCalibration
                                                          ▼
                                                   driverMonitoringState
                                                          │
                                                          ▼
                                                selfdrived / controlsd
                                                  (events 合并 + 控车决策)
                                                          │
                                                          ▼
                                              panda(safety) ── CAN ── 车辆执行器
```

### 7.2 30 秒规则与脱离

如 §4 所述，dmonitoringd 把"分心持续时间"编码进 `awareness` 的衰减。**30 秒规则**的本质是：在 active_monitoring（人脸可见、模型置信）模式下，`awareness` 从 1.0 衰减到 0 约需 30 秒级窗口；衰减到 0 即发 `driverDistracted`，selfdrived 据此 `SOFT_DISABLE`/`IMMEDIATE_DISABLE` openpilot，controlsd 退出控车，纵向规划器执行减速直至停车（在 openpilot 控纵向的车型上）。这与 ISO 26262 的 R1（驾驶员可立即夺回）一致：踩刹车/按取消键随时退出。

### 7.3 与其它事件的优先级

`driverDistracted` 与"转向干预""油门干预""通信故障""过激作动"等事件在 selfdrived 的 `events.py` 中按 `AlertSeverity`/`EventType` 合并。驾驶员主动介入（steeringPressed/gasPressed）会立即重置 awareness，体现"驾驶员始终拥有最高优先级"。

---

## 8. DMS 模型（dmonitoring_model.onnx）

### 8.1 模型架构

- **文件位置**：`selfdrive/modeld/models/dmonitoring_model.onnx`（与 `driving_policy.onnx`/`driving_vision.onnx`/历史 `supercombo.onnx` 同目录）。
- **backbone**：基于轻量 CNN（社区分析 supercombo 主干用 EfficientNet-B2，dmonitoring 模型同为轻量化卷积主干，面向 845 MAX 的 SNPE/OpenCL 推理优化）。
- **输入**：驾驶员相机帧（经 `frame.prepare(buf, transform)` 做去畸变与归一化），单帧图像。
- **输出**：人脸概率、头部姿态向量、人脸位置、左右眼睁闭/眨眼概率、不确定度——一组回归量，无显式 landmark 关键点（端到端回归而非 68 点几何）。

### 8.2 推理时间

`modelExecutionTime` 字段记录每帧 GPU 执行耗时。在 Snapdragon 845 MAX 上单帧约数毫秒，满足 10–20Hz 实时性，不会成为瓶颈。推理用 tinygrad/OpenCL（comma 自家栈），支持 fp16。

### 8.3 模型更新与数据闭环

comma.ai 通过用户上传的驾驶片段（userdata）持续迭代 DMS 模型，覆盖不同人种、眼镜、口罩、光照、座椅位置。新模型随 openpilot 版本下发。`AlwaysOnDM` 收集的统计也用于评估误报率。模型训练细节非开源，但推理代码与权重在设备上可被社区审视（开源仓库可读）。

---

## 9. 与其他厂商 DMS 对比

| 厂商/系统 | 监控手段 | 触发与响应 | 特点与差异 |
|-----------|----------|------------|-----------|
| **OpenPilot** | 驾驶员 IR 相机 + 端到端 CNN（face/yaw/pitch/blink）+ awareness 状态机；**不依赖方向盘扭矩** | 三级 pre/prompt/driverDistracted；~30s 规则（active）或数秒（遮挡）；脱离+减速停车 | 纯视觉、开源、无法用配重作弊；端到端回归对个体差异鲁棒；failsafe passive |
| **特斯拉 (Autopilot/FSD)** | 早期仅方向盘扭矩（可被"配重"欺骗）；2021.4.15.11 起启用**车内后视镜上方摄像头**监测注意力，数据本地处理不上传 | 视线偏离/离座 → 警告；多次无视 → 踢出 FSD Beta | 力矩为主、视觉为辅；曾被 NHTSA 调查 83 万辆；FSD 驾驶员监控仍偏宽松 |
| **丰田 (TSS 3.0 PRO / 4.0)** | TSS 4.0 新增**驾驶员状态监测 DMS（红外摄像头）**；TSS 3.0 PRO 无 DMS | 疲劳/分神 → 警报 | 主流合资油车下放；硬件为红外摄像头+算法 |
| **福特 (BlueCruise 1.2/1.4)** | 双区电容方向盘（离手检测）+ 车内摄像头眼动追踪（Hands-Free 区段） | 视线偏离 → 提示；持续无响应 → 降级退出 | 真正"解放双手"区段用眼动追踪兜底；1.4 延长松手时间 |
| **通用 Super Cruise（凯迪拉克 LYRIQ）** | **红外摄像头眼球追踪 + 红外补光 + 双区电容方向盘** | 视线偏离 → Lightbar 闪烁；无响应 → 声音+座椅震动；仍无响应 → 车道内缓慢停车+双闪+安吉星呼叫 | 业内首个眼球追踪量产；毫秒级电容感知；冗余最完善 |
| **小鹏 (NGP / GX)** | 车内 DMS 摄像头（眼/头）+ 方向盘扭矩；GX 升级多通道：安全带射频测心率/呼吸、方向盘光电、摄像头 rPPG | 分神→警告；NGP 因"眼睛小"误判上热搜；GX 检测生理异常 → 自动靠边停车+呼叫救援 | 视觉为主，扭矩为辅；GX 向"防猝死"生理监测演进 |

**OpenPilot 的差异化定位**：

1. **开源可审计**：模型推理、阈值、状态机全在仓库，社区可调参（fork 如 sunnypilot/dragonpilot）。
2. **反作弊**：纯视觉，方向盘扭矩只是辅助信号（steeringPressed 用于"驾驶员介入"重置，不作为"是否在看路"判据），无法用配重欺骗。
3. **轻量**：单 CNN + 规则状态机，跑在手机级 SoC（845 MAX）上。
4. **保守安全**：遮挡即快速告警，分心即脱离，绝不让"机器自己开而你睡着"。
5. **弱项**：无生理监测（心率/呼吸）、无 rPPG、无车队管理后端；与 Super Cruise/小鹏 GX 的多通道冗余相比偏简朴。

---

## 10. AuroraDrive 迁移建议

### 10.1 AuroraDrive 现状

根据 `AuroraDrive项目交接文档.md`：AuroraDrive（原 FSD）是"自动驾驶仿真系统 + 辅助驾驶模式"，v1.1.0。仿真模式（24Hz 物理仿真 + A* + Pure Pursuit + IDM/MOBIL 交通流 + Web UI）完整可用；**辅助驾驶模式**通过 Swift ScreenCaptureKit 捕获真实游戏画面 → Canny/Hough 车道线 → CGEvent 键盘注入（A/D/W/S）控制游戏车辆，AUTO 接管已修复（横向 PurePursuit + 纵向 PID 40km/h）。**当前完全无 DMS**，也无驾驶员相机。

### 10.2 游戏辅助模式是否需要 DMS？

需区分两种语义：

1. **仿真模式（用户在自家虚拟城市里开车）**：责任主体就是用户自己，车辆是虚拟的，**不需要 DMS**。强行加 DMS 反而是过度设计。
2. **辅助驾驶模式（AUTO 替用户操控真实游戏画面里的车）**：本质是"机器在帮玩家开车"。此时存在一个真实的"接管责任"问题——若 AUTO 失效或遇到边界，玩家必须立即接手键盘。如果玩家此时走神/离开屏幕，AUTO 失效就会导致游戏内事故。因此**在辅助驾驶模式引入轻量 DMS 是有价值的**，但其风险等级远低于真实汽车（最坏情况是游戏内撞车，无人身安全）。

结论：**可选，非必需**。可作为"体验增强 + 安全文化对齐"功能，借鉴 OpenPilot 思想做轻量化版本，而非照搬。

### 10.3 借鉴 OpenPilot DMS 的核心思想

值得移植的设计原则：

1. **感知与逻辑分离**：把"看人"（模型/检测）与"判分"（状态机）拆成两个模块，便于独立调参。
2. **awareness 积分标量**：用一个 0~1 的衰减/恢复标量表达"玩家是否在场"，简单、可解释、易调阈值。
3. **三级渐进预警**：pre/prompt/red，避免一上来就硬脱离，给玩家反应窗口。
4. **失效即安全**：检测不到玩家（离开屏幕）→ awareness 快速衰减 → 自动降级到手动，而不是"按上一次状态继续 AUTO"。
5. **校准**：允许玩家标定"自然坐姿/视线"，减少误报。
6. **可关闭**：DMS 作为可选开关（类比 AlwaysOnDM 反向），尊重玩家选择。

### 10.4 AuroraDrive DMS 方案（可选 / 未来）

**方案 A：基于屏幕交互的"软 DMS"（零额外硬件，推荐 MVP）**

不引入摄像头，直接用玩家是否在操作电脑作为代理信号：

- 输入信号：鼠标移动、键盘按下（非 AUTO 注入的 A/D/W/S）、游戏窗口是否前台聚焦、可选的 macOS `CGEventSource` 空闲时间。
- awareness 状态机：玩家有输入 → awareness 恢复；AUTO 开启但 N 秒无任何玩家输入/窗口失焦 → awareness 衰减。
- 响应：pre（UI 黄色提示"请留意"）→ prompt（橙色 + 提示音）→ red（暂停 AUTO 注入，把控制权交还玩家键盘，车辆滑行减速）。
- 优点：零成本、零隐私、与现有 CGEvent 键盘注入栈天然契合；缺点：只能判"在场/不在场"，无法判"看没看路"。

**方案 B：基于前置摄像头的"视觉 DMS"（可选增强）**

若要更接近 OpenPilot 体验，可接入 Mac 摄像头：

- 用轻量人脸/姿态模型（MediaPipe Face Mesh / Iris，或 ONNX 轻量 CNN）做 faceProb + 头部 yaw/pitch + 睁闭眼。
- 复用 OpenPilot 的 awareness 衰减/恢复逻辑与三级告警。
- 接口：在 C++ 侧新增 `DMS::run_step(frame)`，输出 `DmsState{awareness, isDistracted, events}`，`simulator.h` 辅助驾驶线程据此决定是否暂停 AUTO。
- 隐私：图像本地处理即丢，不上传；可物理/软件关闭。
- 适配 AuroraDrive 的 Swift 捕获栈：可在 `src-tauri/src/swift/` 增加 `FaceCapture`，复用 ScreenCaptureKit 的相机权限路径。

**方案 C：游戏内"接管就绪度"评分（无监控、纯行为）**

不监控人，而监控"玩家最近一次接管延迟"作为就绪度反向指标：AUTO 退出后若玩家长期不接管 → 下次 AUTO 启用前要求确认；连续多次延迟 → 限制 AUTO 可用时长。这是 OpenPilot"终止告警锁定"思想的简化版。

**落地建议**：先做方案 A（1–2 天工作量，与现有 `assist_auto_` 线程对接），把"玩家在场性"纳入 AUTO 安全闭环；若后续要做"接近真车 DMS 的体验"，再上方案 B。务必保持 DMS 为**可选**，且失败时降级为手动而非卡死 AUTO。

### 10.5 与 AuroraDrive 现有架构的对接点

- 状态注入：在 `simulator.h` 辅助驾驶线程的 `if (assist_auto_.load())` 前增加 `if (dms_.allow_auto())` 闸门；`dms_` 由 awareness 状态机驱动。
- UI 反馈：在 `AssistStatusPanel` / `CaptureCanvas` HUD 增加三色 DMS 指示，复用 `TurnArrow` 同款提示样式。
- 配置：`AssistPage` 增加"DMS 灵敏度/开关"项，写入现有 params 体系。
- 降级动作：复用 `assist_auto_longitudinal` 的 PID，把"红色告警"映射为"目标速度渐降至 0 并停止 A/D 注入"，与 OpenPilot 的"车道内减速停车"语义一致。

---

## 11. 总结

OpenPilot DMS 用"**端到端轻量 CNN 出回归量 + Python 状态机做 awareness 积分 + 三级渐进告警 + controlsd 脱离减速**"的组合，在手机级 SoC 上实现了不依赖方向盘扭矩的纯视觉驾驶员注意力监控。它的工程价值在于：感知/逻辑解耦、个人姿态在线校准、失效即安全的快速衰减、以及与 panda 安全固件联动的 failsafe passive 闭环。相比特斯拉的力矩为主、Super Cruise 的眼球追踪+电容冗余、小鹏 GX 的多通道生理监测，OpenPilot 走的是"开源、轻量、反作弊、保守"路线。对 AuroraDrive 而言，DMS 非必需但值得借鉴其状态机与渐进预警思想，以"软 DMS（在场性）"作为 MVP，未来可扩展到摄像头视觉 DMS，始终遵循"失败降级为手动"的安全原则。

---

> 本报告基于 comma.ai 官方文档/商店页、GitHub openpilot 仓库源码与进程表、CSDN/51CTO/知乎技术解析、以及丰田/特斯拉/福特/通用/小鹏 DMS 公开资料综合整理。
>
> 实际工具调用次数：**WebSearch 27 次 + WebFetch 24 次 = 51 次研究类工具调用**；另含若干次 Read/LS/TodoWrite 辅助调用，合计约 57 次工具调用。文中模型字段名与阈值常量以 openpilot master 分支为准，不同版本/fork 可能有命名差异（如 `driver_monitor.py` ↔ `dmonitoringd.py`、`driverState` ↔ `driverStateV2`）。
