# OpenPilot CarInterface 车辆接口适配器深度研究报告

> 研究对象：commaai/openpilot `selfdrive/car/`（含已拆分到 opendbc 仓库的 `opendbc/car/`），master 分支
> 关联模块：`selfdrive/car/car_helpers.py`、`selfdrive/car/interfaces.py`（CarInterfaceBase）、各品牌 `selfdrive/car/<brand>/`、`opendbc/dbc/`、`panda/board/safety/`、cereal `car.capnp`
> 关联进程：`controlsd`（执行器，100Hz）、`selfdrived`（决策器，100Hz）、`pandad`（CAN 网关，100Hz）、`boardd`（CAN 收发）
> 研究方法：WebSearch + WebFetch（GitHub、CSDN、51CTO、Sohu、gitcode 镜像）+ 本地 AuroraDrive 文档分析，共约 54 次内部工具调用

---

## 0. 摘要

OpenPilot 之所以能以"一套系统适配 275–325+ 种车型"，关键不在模型，而在**车辆接口抽象层（CarInterface）**。它把"千差万别的厂商私有 CAN 协议"封装在品牌目录下，对上层 `controlsd` 暴露统一的 `CarState`（状态读取）与 `apply(CarControl)`（指令下发）两个接口，使横向/纵向控制算法、规划、感知完全车型无关。本报告从架构、工厂模式、基类接口、CarState 读取、CarParams proto、DBC 文件、panda safety、CarController、各品牌适配差异九个维度展开，并基于 OpenPilot CarInterface 的抽象设计，给出 AuroraDrive 从"直接 CGEvent 键盘注入"迁移到"可插拔 GameInterface 抽象层"的方案。

---

## 1. CarInterface 架构总览

### 1.1 目录布局

OpenPilot 的车型适配代码集中在 `selfdrive/car/`（新版本中车辆接口代码已逐步迁移到独立的 `opendbc` 仓库 `opendbc/car/`，openpilot 主仓通过子模块/依赖引用）。整体结构：

```
selfdrive/car/                      # (或 opendbc/car/)
├── car_helpers.py                  # get_car() 工厂入口、fingerprint 编排
├── interfaces.py                   # CarInterfaceBase 抽象基类
├── car_specific.py                 # CarSpecificEvents 通用事件处理（按 brand 分支）
├── <brand>/                        # 各品牌目录（toyota/honda/hyundai/ford/gm/...）
│   ├── interface.py                # 该品牌 CarInterface（继承 CarInterfaceBase）
│   ├── carstate.py                 # 该品牌 CarState（继承 CarStateBase）
│   ├── carcontroller.py            # 该品牌 CarController（继承 CarControllerBase）
│   ├── values.py                   # 车型枚举、CarControllerParams、DBC 文件名映射、CarConfig
│   ├── [brand]can.py               # CAN 报文 ID / 信号名常量定义（部分品牌）
│   ├── fingerprints.py             # ECU 固件指纹库（用于车型识别）
│   └── radar_interface.py          # ACC 雷达数据解析（部分品牌）
```

每个品牌目录对外暴露三个对象：`CarInterface`、`CarController`、`CarState`，由 `car_helpers.load_interfaces()` 动态 import。

### 1.2 三级抽象架构

OpenPilot 采用"品牌—车型—参数"三级抽象隔离车型差异：

1. **硬件抽象层**：由 `panda` 硬件实现 CAN 物理层适配（支持标准 CAN 与 CAN FD），经 `boardd`/`pandad` 对上提供统一 `can`/`sendcan` 消息流。
2. **协议解析层**：基于 DBC 文件做信号解码，品牌目录下 `carstate.py` 把原始 CAN 解析结果写成标准化 `CarState`；`carcontroller.py` 把 `CarControl` 反向编码成 CAN 帧。
3. **控制逻辑层**：`controlsd` + `selfdrived` 跑横向/纵向控制与决策，完全车型无关，复用率 90%+。

新增车型通常仅需 200 行左右代码变更，集中在协议解析层。

### 1.3 数据流（card 守护进程视角）

`controlsd` 主循环（100Hz）核心数据流：

```python
# 1. 读 CAN 总线（pandad 发布 can 消息）
can_messages = receive_can_data()
# 2. CarInterface.update() → 标准化 CarState
car_state = CI.update(can_messages)
# 3. 发布 carState 给 selfdrived / plannerd / modeld
publish_state(car_state)
# 4. 决策与规划产出 longitudinalPlan / carControl
# 5. CarInterface.apply(car_control) → 车型特定 CAN 帧
can_sends = CI.apply(control_command)
# 6. 通过 sendcan 消息发往 boardd → panda → 车辆 CAN 总线
send_can_messages(can_sends)
```

OpenPilot 不直接驱动电机或制动泵，而是"协议桥接"——把控制指令翻译为原厂 ECU 能识别的 CAN 报文（如 Honda 的 LKA 指令帧、Toyota 的 LKA 扭矩帧、Hyundai 的 SCC 帧）。

---

## 2. 工厂模式与车型识别（fingerprint）

### 2.1 get_car() 入口

`controlsd` 初始化时通过 `car_helpers.get_car()` 获得两个对象：`CI`（CarInterface 实例）与 `CP`（CarParams）。核心逻辑：

```python
def get_car(logcan, sendcan, experimental_long_allowed, num_pandas=1):
    # 1. 指纹识别：根据 CAN 总线上出现的报文 ID 集合 + ECU 固件版本识别车型
    candidate, fingerprints, vin, car_fw, source, exact_match = \
        fingerprint(logcan, sendcan, num_pandas)

    if candidate is None:
        candidate = "mock"   # 未识别到则降级为 mock

    # 2. 工厂查表：interfaces[candidate] → (CarInterface, CarController, CarState)
    CarInterface, CarController, CarState = interfaces[candidate]

    # 3. 静态方法 get_params 构造 CarParams（CP）
    CP = CarInterface.get_params(candidate, fingerprints, car_fw,
                                 experimental_long_allowed, docs=False)
    CP.carVin = vin
    CP.carFw = car_fw
    CP.fingerprintSource = source
    CP.fuzzyFingerprint = not exact_match

    # 4. 实例化 CarInterface
    return CarInterface(CP, CarController, CarState), CP
```

### 2.2 interfaces 注册表

```python
interface_names = _get_interface_names()      # 扫描 selfdrive/car/ 下的目录名
interfaces = load_interfaces(interface_names)  # 动态 import 每个品牌的三个对象
```

`load_interfaces` 对每个品牌目录 `import interface.py / carstate.py / carcontroller.py`，得到 `(CarInterface, CarController, CarState)` 三元组存入字典。这是一种典型的**工厂 + 注册表**模式：`candidate`（如 `"TOYOTA_RAV4_2019"`）作为 key 查表得到具体品牌类。

### 2.3 指纹识别机制

- **CAN 指纹**：不同车型在 CAN 总线上出现的报文 ID 集合（fingerprint）具有特征性。OpenPilot 在 `fingerprints.py` 中维护每个车型对应的期望 ID 集合，匹配后即可定位 candidate。
- **固件指纹**：通过 UDS 诊断读取各 ECU 的固件版本（`car_fw`），比 CAN 指纹更精确，支持 `exact_match`。
- **VIN**：用于辅助校验和 `CP.carVin`。
- `fuzzyFingerprint = not exact_match` 标记是否为模糊匹配（CAN 指纹匹配但固件未完全确认）。

这一步是"车型自适应"的关键——无需用户手动选车型，插上 panda 自动识别。

---

## 3. CarInterfaceBase 接口

`interfaces.py` 中的 `CarInterfaceBase` 是所有品牌 `CarInterface` 的抽象基类。它持有 `CP`（CarParams）、`CarController`、`CarState` 三个引用，定义了下表所示的核心接口。

### 3.1 CarInterfaceBase 接口表

| 方法 | 类型 | 签名要点 | 职责 |
|------|------|----------|------|
| `get_params` | `@staticmethod` | `(candidate, fingerprints, car_fw, experimental_long_allowed, docs) -> CarParams` | 工厂方法：构造该车型的 CarParams（CP）。基类版本会调用子类 `_get_params` / `get_platform_params` / `get_dynamic_params` 完成参数填充 |
| `_get_params` | 实例无关 | `(self, ...) -> CarParams` | 子类钩子，根据 fingerprint/car_fw 精调 CP（如选择 DBC、设置 steerMax、safetyConfig） |
| `get_platform_params` | 子类实现 | `-> CarParams` | 填充与"平台/硬件"相关的静态参数（车重、轴距、转向比、CAN 总线拓扑等） |
| `get_dynamic_params` | 子类实现 | `(car_fw?) -> ...` | 根据固件版本动态选择参数（同一车型不同年款/ECU 版本差异） |
| `__init__` | 实例 | `(self, CP, CarController, CarState)` | 保存 CP，实例化 `self.CC = CarController(CP, ...)`，构造 `self.CS = CarState(CP)`，建立 CANParser/CANPacker |
| `init` | 实例 | `(self, CP, ...) -> None` | 控制启用前的初始化：`apply` 首帧、panda safety 配置下发 |
| `update` | 实例 100Hz | `(self, can_strings) -> car.CarState` | **状态读取核心**：用 CANParser 解析原始 CAN，调用 `self.CS.update(...)` 生成标准化 CarState |
| `apply` | 实例 100Hz | `(self, car_control) -> (can_sends, actuators_output)` | **指令下发核心**：调用 `self.CC.update(...)` 把 CarControl 编码成车型特定 CAN 帧 |
| `get_pid_params` | 子类实现 | `-> CarControllerParams` | 返回横向/纵向 PID 调参（kpBP/kpV/kiBP/kiV/kf、steerRateCost 等） |
| `get_steer_feedforward` | 子类实现 | `(self, desired_angle, v_ego) -> float` | 返回前馈扭矩：基于车辆动力学模型（VM）把期望转向角 + 车速换算成方向盘前馈力矩，喂给 latcontrol PID 的 feedforward 项 |

调用关系：横向 PID 控制器在 `update()` 中执行
```python
ff = CI.get_steer_feedforward(desired_angle, CS.vEgo)
output = self.pid.update(error, feedforward=ff, speed=CS.vEgo)
```
其中 `error = desired_angle - CS.steeringAngleDeg`，`desired_angle` 由车辆模型 `VM.get_steer_from_curvature(desired_curvature, CS.vEgo)` + 角度偏移得到。

### 3.2 典型品牌 CarInterface 实现（Toyota 示例）

```python
class ToyotaInterface(CarInterfaceBase):
    def __init__(self, CP, CarController, CarState):
        super().__init__(CP, CarController, CarState)
        self.CC = ToyotaController(CP)
        self.CS = ToyotaCarState(CP)

    def update(self, can_strings):
        # 解析丰田特有 CAN 消息
        self.CS.update(can_strings)              # 内部用 cp.vl[...] 读信号
        ret = self.CS.copy_to_carstate()         # 写到标准化 car.CarState
        ret.events = self.create_common_events(ret).to_msg()
        return ret

    def apply(self, CC):
        return self.CC.update(CC)                # 返回 (can_sends, actuators)
```

Toyota 转向状态消息地址 `0x2E4` 即在此处解析：
```python
for msg in can_data:
    if msg.address == 0x2E4:        # STEER_TORQUE_SENSORS
        ret.steeringAngleDeg = parse_steering(msg)
```

---

## 4. CarState 读取

### 4.1 CarState 类结构

每个品牌实现 `CarState(CarStateBase)`，持有两个关键对象：

- `self.cp`：**CANParser**（来自 `opendbc.can.parser`），按 DBC 解析"车辆总线"上的信号。
- `self.cp_cam`：**CANParser**，解析"ADAS 摄像头/雷达总线"上的信号（部分品牌第二条 CAN）。
- `self.cp_loopback`：回环解析器，校验发出的控制帧是否真的被车辆接受。

`update()` 流程：
1. `self.cp.update_strings(can_strings)` 喂入原始 CAN 帧。
2. 用 `self.cp.vl[<msg_name>][<signal_name>]` 取出已解码信号。
3. 写入标准化字段，返回 `car.CarState.new_message()`。

### 4.2 标准化 CarState 字段（cereal car.capnp）

OpenPilot 定义统一 `CarState` 把所有品牌差异归一化，关键字段：

| 字段 | 类型 | 含义 |
|------|------|------|
| `vEgo` | float | 自车速度（m/s） |
| `vEgoRaw` | float | 未平滑速度 |
| `aEgo` | float | 自车加速度 |
| `steeringAngleDeg` | float | 方向盘转角 |
| `steeringTorque` | float | 方向盘扭矩 |
| `steeringPressed` | bool | 驾驶员是否在转方向盘（手力矩检测） |
| `steerOverride` | bool | 转向干预（驾驶员抢方向） |
| `gas` / `gasPressed` | float/bool | 油门踏板位置 / 是否踩下 |
| `brake` / `brakePressed` | float/bool | 刹车踏板 |
| `gearShifter` | enum | 档位（drive/reverse/park/sport/low/manumatic 等） |
| `leftBlinker` / `rightBlinker` / `brakeLights` | bool | 信号灯 |
| `cruiseState` | struct | 巡航状态（enabled/available/speed/standstill/adaptive） |
| `doorOpen` / `seatbeltUnlatched` | bool | 车门/安全带 |
| `carFaultedNonCritical` | bool | 非致命故障 |
| `espActive` / `absActive` / `tractionControl` | bool | ESC/ABS/TCS 状态 |
| `steeringTorque` 系列 | float | 扭矩反馈 |

### 4.3 CAN 消息解析示例（Honda DBC）

Honda 思域 DBC 片段（来自官方 Medium 解析）：

```
BO_ 228 STEERING_CONTROL: 5 ADAS
 SG_ STEER_TORQUE         :  7|16@0- (1,0) [-3840|3840] "" EPS
 SG_ STEER_TORQUE_REQUEST : 23|1@0+ (1,0) [0|1]       "" EPS
 SG_ CHECKSUM             : 39|4@0+ (1,0) [0|15]      "" EPS
 SG_ COUNTER             : 33|2@0+ (1,0) [0|3]       "" EPS
```

- ID `228`（0xE4）：转向控制帧，5 字节。
- `STEER_TORQUE`：16 bit 有符号，直接控制传导到车轮的扭矩（而非目标角度）。
- `STEER_TORQUE_REQUEST`：1 bit，是否请求扭矩控制。
- `CHECKSUM` / `COUNTER`：校验与滚动计数，panda safety 会强校验。

而转向角度反馈在另一帧：
```
BO_ 330 STEERING_SENSORS: 8 EPS
 SG_ STEER_ANGLE : 7|16@0- (-0.1,0) [-500|500] "deg" NEO
```
有了"目标角度（控制环算）+ 当前角度（反馈）+ 扭矩控制"，即可构造 PI/PID 闭环。

### 4.4 各品牌差异速览

| 品牌 | 转向控制方式 | 关键状态帧 | 总线数 |
|------|-------------|-----------|--------|
| Toyota/Lexus | 扭矩（STEER_TORQUE） | 0x2E4 STEER_TORQUE_SENSORS | 1–2 |
| Honda（Nidec/Bosch） | 扭矩（0xE4） | 0x330 STEERING_SENSORS | 2（车辆 CAN + 雷达 CAN） |
| Hyundai/Kia | 扭矩（LFA/MDPS），CAN FD 新车型 | MDPS 0x25/0x130 | 1–2（部分 CAN FD） |
| Ford | 扭矩补偿（含电池电压补偿） | AP（Active Park）模块 | 1–2 |
| GM/Chevrolet/GMC | 扭矩 | Voltec/Global A | 1–2 |
| Tesla | AP 总线 | tesla_model3_vehicle.dbc | 1 |
| VW/Audi（MQB） | 扭矩，CAN FD，加密信号 | vw_mqb.dbc | 1（CAN FD 8Mbps） |
| Nissan | 扭矩 | — | 1 |
| Mazda | 扭矩 | — | 1 |
| Subaru | 扭矩 | — | 1 |
| Chrysler/FCA | 扭矩 | — | 1 |

Honda 是 OpenPilot 最早支持的品牌（思域 + ILX），只需 2 条 CAN（车辆 CAN + 雷达 CAN）即可完成全部通讯；Honda 还区分 Nidec（原厂 ACC + openpilot 横向）与 Bosch（部分车型支持 openpilot 纵向）两套方案，影响 `openpilotLongitudinalControl` 是否可开启。

---

## 5. CarParameters（CP）

`CarParams` 由 cereal `car.capnp` 定义，是贯穿全系统的车型描述对象。`get_params()` 在车型识别后一次性构造，下发给 controlsd / selfdrived / plannerd / pandad。

### 5.1 CarParams 关键字段

| 字段 | 含义 |
|------|------|
| `carFingerprint` | 车型指纹字符串，如 `TOYOTA_RAV4_2019`、`HONDA_CIVIC_2016 TOURING`，作为查表主键 |
| `carName` | 品牌名（toyota/honda/hyundai/...） |
| `carVin` | 车辆识别码（17 位） |
| `carFw` | 各 ECU 固件版本列表（CarFw 数组） |
| `brand` | 品牌标识，用于 `car_specific.py` 分支 |
| `minEnableSpeed` | 启用 openpilot 的最低车速（低于此速禁止开启横向），典型 ~0–5 m/s |
| `minSteerSpeed` | 最低可转向车速 |
| `pcmCruise` | 是否使用原厂 PCM 巡航（true=复用原车 ACC 按钮/状态；false=openpilot 自管纵向） |
| `openpilotLongitudinalControl` | openpilot 是否接管纵向（油门/刹车 CAN 直发），否则用原厂 ACC |
| `safetyModel` / `safetyParams` | panda safety 模型枚举 + 参数（见 §7） |
| `enableGasInterceptor` / `enableCamera` | 是否外挂油门拦截器/摄像头 |
| `steerMax` / `gasMax` / `brakeMax` | 最大转向扭矩/油门/刹车（归一化或物理量） |
| `steerRateCost` / `lateralTuning` | 横向调参（PID: kpBP/kpV/kiBP/kiV/kf；或 torque/angle 模式参数） |
| `longitudinalTuning` | 纵向 PID 调参 + actuator delay |
| `mass` / `steerRatio` / `wheelbase` / `centerToFrontRatio` | 车辆动力学模型（VehicleModel）参数 |
| `fingerprintSource` | 指纹来源（can / fw） |
| `fuzzyFingerprint` | 是否模糊匹配 |
| `dashcamOnly` | 仅行车记录仪模式（不支持控制） |
| `transmissionType` / `gearShifterStyle` | 变速箱/挡位样式 |
| `carColor` | 车身颜色（部分用途） |

### 5.2 get_params 子流程

基类 `get_params` 模板方法：
1. `CP = CarParams()` 新建。
2. 调 `get_platform_params(CP)`：填品牌级共性（DBC 名、safetyModel、CAN 总线数、车重/轴距）。
3. 调 `get_dynamic_params(car_fw)`：按固件版本微调（同车型不同年款差异）。
4. 子类 `_get_params`：根据 `car_fingerprint` 进一步精调（`steerMax`、`minEnableSpeed`、是否 `openpilotLongitudinalControl`）。
5. 返回 CP。

---

## 6. 车型适配差异

### 6.1 CAN 消息 ID 差异

不同厂商 CAN 报文 ID 分配截然不同：
- Toyota 多用标准帧（11 位 ID），如 `0x2E4`（转向）、`0x1D2`（PCM）、`0x343`（巡航按钮）。
- Honda `0xE4`（转向控制）、`0x330`（转向传感器）、`0x200`（车速）、`0x300`（转向角）。
- BMW 部分用扩展帧（29 位 ID）。
- VW MQB 用 CAN FD，速率 8Mbps，数据场可达 64 字节，并引入新 CRC。

### 6.2 信号字节序差异

DBC 中 `@0` / `@1` 表示 Motorola（大端）/ Intel（小端）字节序；`+`/`-` 表示无符号/有符号。例：
- `STEER_ANGLE : 7|16@0- (-0.1,0)`：Motorola 序，16 bit，有符号，factor −0.1，offset 0，量程 [−500,500] deg。
- `Speed : 0|16@1+ (0.01,0)`：Intel 序，16 bit，无符号，factor 0.01 km/h。

同一物理量（车速）在不同品牌可能来自 `VEHICLE_SPEED` 或 4 个轮速 `WheelSpeed` 的平均，缩放因子与位偏移各异。

### 6.3 限速差异

| 限制项 | Toyota | Honda | Hyundai | Ford |
|--------|--------|-------|---------|------|
| `steerMax`（最大扭矩） | ~1500–2048 | ~3840 | ~255–400 | 品牌特定 |
| 转向速率上限 | 限 rate | 限 rate | 限 rate | 限 rate |
| `max_brake`（m/s²） | ~−2.5 ~ −3.5 | ~−2.0 | ~−3.0 | 品牌特定 |
| `minEnableSpeed` | 0 m/s（全速域） | 部分车型 ≥ 0 | 0 / 受限 | 受限 |
| 纵向策略 | 多用原厂 PCM ACC | Nidec 用原厂 ACC，Bosch 可 openpilot 纵向 | 多 openpilot 纵向（SCC） | openpilot 纵向 |

### 6.4 启用条件差异（car_specific.py）

`CarSpecificEvents` 按品牌分支生成事件，决定能否启用：

```python
elif self.CP.brand == 'honda':
    events = self.create_common_events(CS, CS_prev,
                  extra_gears=[GearShifter.sport], pcm_enable=False)
    if self.CP.pcmCruise and CS.vEgo < self.CP.minEnableSpeed:
        events.add(EventName.belowEngageSpeed)
elif self.CP.brand == 'toyota':
    events = self.create_common_events(CS, CS_prev,
                  extra_gears=[GearShifter.sport])
    if self.CP.openpilotLongitudinalControl and CS.cruiseState.standstill:
        events.add(EventName.resumeRequired)
elif self.CP.brand == 'ford':
    events = self.create_common_events(CS, CS_prev,
                  extra_gears=[GearShifter.low, GearShifter.manumatic])
```

通用事件（车门开、安全带未系、挡位非 D、刹车踩下）在 `create_common_events` 统一处理，品牌仅覆盖差异（额外挡位、PCM 使能、standstill 恢复逻辑）。

---

## 7. DBC 文件与 opendbc

### 7.1 opendbc 项目

opendbc 是从 openpilot 拆分出的独立项目（`github.com/commaai/opendbc`），目标是"democratize access to car decoder rings"——把汽车 CAN 解码规则（DBC 文件）开源。目前覆盖 **384 款已知车型**，每月新增 10+ 车型。结构：
```
opendbc/
├── dbc/                # DBC 文件库（按品牌）
│   ├── toyota_adas.dbc
│   ├── honday_civic_touring_2016_can.dbc
│   ├── vw_mqb.dbc
│   ├── tesla_model3_vehicle.dbc
│   └── ...
├── can/                # CAN 处理库
│   ├── parser.py       # CANParser：DBC → 解码信号
│   ├── packer.py       # CANPacker：信号 → CAN 帧编码
│   └── defines.py
├── car/                # 高级车辆接口（与 openpilot selfdrive/car 同构）
│   ├── interfaces.py
│   └── <brand>/
└── docs/CARS.md
```

### 7.2 DBC 文件格式

DBC（Data Base CAN）是 Vector 定义的标准 CAN 数据库格式，opendbc 用纯文本明文存储。核心语法：

```
VERSION ""

NS_ : ...                      # 符号表

BS_:                           # 波特率

BO_ <id> <name>: <len> <sender>           # 报文定义
 SG_ <name> : <start>|<len>@<endian><sign> (factor,offset) [min|max] "unit" <receiver>

BA_ "GenMsgCycleTime" BO_ <id> <ms>;      # 报文周期
VAL_ <id> <signal> <val> "name" ...;      # 枚举值
```

示例：
```
BO_ 256 VEHICLE_SPEED: 8 VEHICLE
 SG_ Speed : 0|16@1+ (0.01,0) [0|655.35] "km/h" DRIVER
```
- `BO_ 256`：报文 ID 256（0x100），名 `VEHICLE_SPEED`，8 字节，发送方 `VEHICLE`。
- `SG_ Speed`：信号 `Speed`，起始位 0，长度 16，Intel 序无符号，factor 0.01，单位 km/h，接收方 `DRIVER`。

### 7.3 CANParser / CANPacker 与 CarState 的关系

- **CANParser**：加载 DBC，输入原始 CAN 帧 `(address, dat, src)`，输出 `cp.vl[msg_name][signal_name]` 的解码值。CarState 的 `update()` 即读 `cp.vl` 写字段。
- **CANPacker**：反向，输入信号名→值的字典，输出编码后的 CAN 帧 `(address, dat)`。CarController 的 `apply()` 用 packer 生成 `can_sends`。

opendbc 内置 DBC 预处理器，分离通用信号与车型特有信号，减少 80%+ 重复代码。性能基准可用 `selfdrive/debug/check_can_parser_performance.py` 测量。

---

## 8. Panda 适配与 safety

### 8.1 panda 双向网关

panda 是 comma 的 CAN 接口硬件（灰熊猫/白熊猫/red panda 等），双向通信：监听车辆状态 + 发送控制指令。其固件在 `panda/board/safety/` 下为每个品牌实现专用安全逻辑：`safety_toyota.h`、`safety_honda.h`、`safety_hyundai.h` 等。pandad 以 100Hz 运行：
```cpp
while (running) {
    can_receive(can_data);           // 收
    publish_can_messages(can_data);
    if (cycle_10hz) get_health();    // 健康检查
    if (need_safety_update)
        set_safety_model(safety_model, param);  // 配置 safety
}
```

### 8.2 safety_set_mode

车型识别后，`get_params()` 在 `CP.safetyModel` / `CP.safetyParams` 中填入对应枚举（如 `SAFETY_TOYOTA`、`SAFETY_HONDA`、`SAFETY_HYUNDAI_CANFD`、`SAFETY_TESLA`、`SAFETY_VW_MQB` 等）。pandad 启动时下发：
```python
panda.set_safety_model(Panda.SAFETY_SILENT)            # 默认静默（不发包）
# 识别完成后
panda.set_safety_model(CP.safetyModel, CP.safetyParams)
```

safety 模式负责：
- **静态安全校验**：校验和检查、信号范围限制、滚动计数器校验。
- **扭矩/速率限制**：硬限制 `STEER_TORQUE` 不超过 `steerMax`，转向速率不超限。
- **controls_allowed 门控**：只有 `controls_allowed=True`（驾驶员主动启用且条件满足）时才允许发送控制帧；否则强制静默。
- **故障恢复**：超时（如 Tesla 每 10ms 需指令，超 20ms 退出）、扭矩突变、CRC 错误 → 自动退出辅助驾驶。

默认 `SAFETY_SILENT` 模式下 panda 不发任何控制帧，必须显式选择安全模式才能发指令——这是 openpilot 的"硬件级安全沙箱"。

### 8.3 CAN 总线配置

不同车型 CAN 总线拓扑不同：
- Honda Nidec：2 条总线（车辆 CAN bus0 + 雷达 CAN bus1），openpilot 通过 panda 桥接两者。
- Toyota：1–2 条。
- VW MQB：1 条 CAN FD。
- Tesla：1 条 AP 总线。

panda 支持多总线收发，`sendcan` 帧带 `src`/`bus` 字段标识目标总线。多 panda 设备时 `num_pandas` 参数影响 fingerprint 与 safety 配置。

---

## 9. CarController 接口

### 9.1 CarController.apply 流程

每个品牌 `CarController(CarControllerBase)` 持有 `CANPacker` 与 `CANParser`（loopback）。`apply(CC)` 输入标准化 `CarControl`，输出车型特定 CAN 帧列表：

```python
class CarControllerBase:
    def update(self, CC, CS) -> (can_sends, actuators):
        # CC: car.CarControl（actuators.accel/torque/steeringAngleDeg，enabled, hud, etc.）
        # CS: 当前 CarState（用于续发计数器、CRC、状态同步）
        # 1. 读取 CC.actuators 期望值
        # 2. clip 到 CP 限制（steerMax/max_brake/max_gas）
        # 3. 用 CANPacker 编码成车型特定帧
        # 4. 追加 CHECKSUM/COUNTER
        # 5. 返回 can_sends: List[(addr, dat, bus)]
```

`controlsd` 在每轮末尾调用：
```python
can_sends = CI.apply(car_control)
# 发布 sendcan 消息 → boardd → panda → 车辆 CAN
```

### 9.2 CarControl 输入（cereal）

```capnp
struct CarControl {
  enabled @0 :Bool;
  active @1 :Bool;          # lat+lon 都激活
  actuators @2 :Actuators {
    accel @0 :Float;        # m/s²
    torque @1 :Float;       # 归一化 [-1,1]
    steeringAngleDeg @2 :Float;
    steeringAngleRateDeg @3 :Float;
    ...
  }
  cruiseControl @3 :CruiseControl { cancel/override/resume/speed ... }
  hudControl @4 :HUDControl { ... }
  latActive @5 :Bool;
  longActive @6 :Bool;
}
```

### 9.3 各品牌差异

- **Toyota**：发 `STEER_TORQUE`（0x2E4/0x191）、LKA 帧；纵向多复用原厂 PCM（set cruise speed），openpilot 纵向时发 GAS/BRAKE 帧。
- **Honda**：发 `STEERING_CONTROL`（0xE4，含 STEER_TORQUE + CHECKSUM + COUNTER）；纵向 Nidec 用原厂 ACC 按钮 CAN，Bosch 可直接发 ACC 控制。
- **Hyundai**：发 LFA/MDPS 扭矩帧 + SCC（智能巡航）帧；新车型 CAN FD。
- **Ford**：`carcontroller.py` 专门设计扭矩补偿算法 `compute_torque_command(desired_accel, current_speed, battery_voltage)`，考虑电池电压对执行器响应的影响。
- **VW MQB**：需逆向加密转向信号的种子-密钥交换。

控制器实现里没有"精确角度"，绝大多数车控制的是传导到车轮的扭矩，靠 PI/PID 闭环用当前角度反馈修正。

---

## 10. 支持车型列表

OpenPilot 官方 `docs/CARS.md` 累计支持 275–325+ 车型（opendbc 覆盖 384 款）。主要品牌与代表车型：

| 品牌 | 子品牌 | 代表车型 | 备注 |
|------|--------|----------|------|
| Toyota | Lexus | Camry/Corolla/RAV4/Prius/Highlander/Avalon；RX/ES/IS/NX/UX | 最早支持之一，全速域 ACC + LKA，部分 openpilot 纵向 |
| Honda | Acura | Civic/Accord/CR-V/Insight/Odyssey/Pilot/HR-V；ILX/RDX/MDX | 最早支持（Civic+ILX），Nidec/Bosch 两套 |
| Hyundai | Kia | Elantra/Sonata/Santa Fe/Tucson/Ioniq/Palisade；Stinger/Sportage/Telluride | CAN FD 新车型，openpilot 纵向为主 |
| Ford | Lincoln | Escape/Explorer/F-150/Mustang Mach-E；Aviator/Nautilus | Q3 纵向优化 |
| GM | Chevrolet/GMC/Cadillac/Buick | Bolt/Equinox/Trailblazer/Silverado；Terrain/Escalade/Envision | Voltec/Global A 平台 |
| Tesla | — | Model 3 / Model Y（AP 总线） | 复用原车 AP CAN |
| Volkswagen | Audi/Škoda/SEAT | Golf/Jetta/Passat/Tiguan/A3/A4；Octavia；Leon | MQB 平台 CAN FD，加密转向 |
| Nissan | Infiniti | Altima/Maxima/Rogue/Sentra；Q50/Q60 | — |
| Mazda | — | 3/6/CX-5/CX-9/CX-30 | — |
| Subaru | — | Outback/Legacy/Forester/Ascent/Crosstrek | — |
| Chrysler | Dodge/Ram/Jeep | Pacifica/Charger/Ram 1500/Grand Cherokee | FCA |
| 其他 | — | 部分 Mercedes-Benz/BMW/Genesis/Volvo 等 | 社区/实验性 |

新车型适配流程（`docs/car-porting/model-port.md`）：①采集 CAN 日志（cabana/can_logger）→ ②用 `debug/get_fingerprint.py` 生成车型指纹 → ③编写 DBC → ④实现 carstate/carcontroller/interface → ⑤在 `values.py` 注册 CarConfig → ⑥标定 steerMax/minEnableSpeed → ⑦跑 `test_car_interfaces` 验证。平均 2–4 周一款，约 200 行代码。

---

## 11. AuroraDrive 迁移建议

### 11.1 AuroraDrive 现状

AuroraDrive（原 FSD，v1.1.0）有两套模式：

1. **仿真模式**：C++ 物理引擎（自行车模型 24Hz）+ A* 路径规划 + Pure Pursuit + IDM/MOBIL 交通流，前端 React Three Fiber 渲染。
2. **辅助驾驶模式（游戏辅助）**：捕获真实游戏画面 → 车道线检测 → 自动注入键盘。
   - Swift `ScreenCaptureKit` 捕获游戏窗口 → Unix Socket 传 JPEG 到 C++。
   - Canny + 最小二乘车道线检测（`lane_detector.h`）。
   - **CGEvent 键盘注入**：A=0（左）、D=2（右）、W=13（前/油门）、S（刹车），见 `simulator.h:1339-1343`。
   - AUTO 接管已修复：横向 `assist_auto_lateral()`（复用 `compute_road_guidance` + PurePursuit → 转向角 → A/D），纵向 `assist_auto_longitudinal()`（PID 速度闭环 40km/h → W/S）。

**痛点**：键位、注入方式、控制语义都硬编码在 `simulator.h` 里，换一个游戏（键位不同、操作语义不同：油门/刹车/手刹/换挡/氮气/转向灵敏度）就要改核心代码；状态读取（速度、转向角）也散落各处，缺乏统一抽象。

### 11.2 借鉴 OpenPilot CarInterface 的核心思想

OpenPilot CarInterface 的精髓可迁移到 AuroraDrive：

1. **状态抽象（CarState 思想）**：把"从游戏画面/内存/窗口读到的原始数据"统一归一化为 `GameState`，上层算法只消费标准化字段，不关心来源。
2. **指令抽象（CarControl 思想）**：上层算法只产生标准化 `ControlCommand`（转向意图、油门强度、刹车强度），由"游戏接口"翻译成具体键位/手柄轴/内存写入。
3. **工厂 + 指纹（get_car 思想）**：运行时自动识别当前是哪款游戏（窗口标题/进程名/分辨率特征），查表得到对应 `GameInterface` 实现，无需用户手选。
4. **参数化（CarParams 思想）**：每款游戏的"控制参数"（最大转向速率、油门曲线、最低可接管速度、键位映射、按键延迟）抽成 `GameParams` 配置，新增游戏改配置不改算法。
5. **安全门控（panda safety 思想）**：注入前过一道"安全沙箱"——限频、限幅、紧急释放（如检测到游戏暂停/菜单则停止注入），对应 `controls_allowed` 门控。

### 11.3 AuroraDrive 车辆接口方案（GameInterface 抽象层）

建议在 C++ 侧新增 `cpp/include/ad/game_interface/` 目录，结构对齐 OpenPilot：

```
cpp/include/ad/game_interface/
├── game_interface_base.h        # GameInterfaceBase 抽象基类（≈ CarInterfaceBase）
├── game_state_base.h            # GameStateBase（≈ CarStateBase）
├── game_controller_base.h       # GameControllerBase（≈ CarControllerBase）
├── game_params.h                # GameParams（≈ CarParams）
├── game_specific_events.h       # 通用事件处理（≈ car_specific.py）
├── game_factory.h               # get_game() 工厂 + 指纹识别（≈ get_car）
└── games/                       # 各游戏实现（≈ selfdrive/car/<brand>/）
    ├── euro_truck_sim2/
    │   ├── interface.h          # ETS2Interface
    │   ├── state.h              # ETS2State（从画面/内存读 速度/转向角）
    │   ├── controller.h         # ETS2Controller（意图 → 键位/手柄轴）
    │   └── values.h             # GameParams、键位常量
    ├── city_car_driving/
    ├── beamng/                  # 支持手柄震动反馈
    └── generic_keyboard/        # 兜底：纯键盘，复用现有 CGEvent 逻辑
```

#### 11.3.1 GameInterfaceBase 接口表（对齐 §3.1）

| 方法 | 职责 | AuroraDrive 对应 |
|------|------|------------------|
| `get_game(params) -> GameParams` | 静态工厂：识别游戏 + 构造 GameParams | 替代硬编码 if-game 分支 |
| `init()` | 启用前初始化：注入通道就绪、safety 下发 | CGEvent source 创建、手柄设备打开 |
| `update(capture_frame) -> GameState` | 状态读取：从画面/内存解析 → 标准化 GameState | 替代散落的 lane_detector + 速度估计 |
| `apply(ControlCommand) -> KeyEvents` | 指令下发：标准化意图 → 具体键位/手柄轴 | 替代 assist_auto_lateral/longitudinal 直发 CGEvent |
| `get_steer_feedforward(angle, speed)` | 前馈：基于游戏车辆模型算转向前馈 | PurePursuit 输出 + 车速 → 转向幅度 |
| `get_pid_params()` | 返回该游戏的 PID 调参 | 不同游戏转向/速度 PID 不同 |

#### 11.3.2 标准化 GameState（对齐 CarState）

```cpp
struct GameState {
  float speed_kmh;            // 自车速度（画面 OCR / 内存读 / 车道线光流估计）
  float steering_angle_deg;   // 当前转向角
  float accel_ms2;            // 加速度（差分）
  bool steer_pressed;         // 玩家是否在抢方向（检测鼠标/键盘冲突）
  bool brake_pressed;
  int gear;                   // 档位
  bool left_blinker, right_blinker;
  bool paused;                // 游戏暂停/菜单 → controls_allowed=false
  // 感知冗余
  LaneLines lanes;            // 来自 lane_detector
};
```

#### 11.3.3 标准化 ControlCommand（对齐 CarControl）

```cpp
struct ControlCommand {
  bool enabled;               // 是否接管
  bool lat_active, long_active;
  float desired_accel;        // m/s²
  float desired_torque;       // 归一化 [-1,1]
  float desired_steer_angle;  // deg
};
```

#### 11.3.4 安全沙箱（对齐 panda safety）

`GameControllerBase::apply` 前置 safety 检查：
- `controls_allowed_`：GameState.paused / 菜单 / 失焦 → 强制 false，不发注入。
- 限频：注入频率上限（如 30Hz），防游戏反作弊。
- 限幅：转向/油门/刹车 clip 到 GameParams 上限。
- 紧急释放：检测到玩家手动输入（steer_pressed）→ 立即停注入，等价 OpenPilot 的 `steerOverride`。

### 11.4 迁移收益

1. **多游戏支持**：新增游戏只写 `games/<game>/` 一个目录 + values.h 配置，核心 `simulator.h` 不动，对应 OpenPilot"新增车型 200 行"。
2. **算法复用**：PurePursuit / PID / 车道线检测与游戏解耦，所有游戏共享同一套控制算法。
3. **可测试性**：`GameInterfaceBase` 可 mock，单元测试脱离真实游戏窗口。
4. **平滑迁移**：先把现有 CGEvent 逻辑包成 `generic_keyboard/`（兜底实现），再逐步为 ETS2 等游戏加专用实现，零回归。
5. **配置驱动**：键位、灵敏度、PID 全部进 GameParams，玩家可在 UI 调参，对应 OpenPilot 的 `lateralTuning` / `longitudinalTuning`。

### 11.5 与 OpenPilot 的关键差异

| 维度 | OpenPilot | AuroraDrive |
|------|-----------|-------------|
| 传输介质 | CAN 总线（panda） | CGEvent 键盘 / 虚拟手柄 / 内存写入 |
| 状态来源 | CAN 帧 → DBC 解析 | 游戏画面 OCR / 内存 / 车道线光流 |
| safety | 硬件级（panda 固件） | 软件级（注入前 gate） |
| 反馈闭环 | 扭矩/角度硬实时（10ms） | 帧率受限（~30Hz），延迟更大 |
| 风险 | 车辆失控物理风险 | 游戏内风险，可随时退出 |

AuroraDrive 无须照搬硬件 safety，但其"抽象 + 工厂 + 参数化 + 安全门控"四件套可直接复用，是把"游戏辅助模式"从原型走向可扩展产品的关键一步。

---

## 12. 结论

OpenPilot CarInterface 是一套教科书级的"车辆抽象层"实践：用 `CarInterfaceBase` 统一接口、`get_car()` 工厂 + 指纹识别做车型自适应、DBC + CANParser/Packer 做协议编解码、CarParams 做参数化、panda safety 做硬件级安全门控，把 275+ 车型的差异压缩到品牌目录下，使上层控制/规划/感知零车型耦合。AuroraDrive 当前"直接 CGEvent 注入"的辅助驾驶模式，正面临 OpenPilot 早期"每车一份代码"的同质问题；借鉴 CarInterface 的四件套抽象，可在不牺牲现有 AUTO 接管能力的前提下，把单游戏硬编码升级为可插拔 GameInterface 体系，为支持多游戏类型（ETS2/CCD/BeamNG/通用键盘）奠定架构基础。

---

> 参考来源：commaai/openpilot（GitHub master）、commaai/opendbc（GitHub）、comma.ai 官方 Medium、CSDN 系列（车辆接口标准化 / 跨品牌适配 / 多车型架构 / CAN 总线解析 / 纵向控制 / opendbc 深度解析 / 代码分析 / 横向控制）、51CTO（Cereal 消息系统）、Sohu 新智驾（openpilot 工作原理）、本地 AuroraDrive 交接文档与 TechArch。
>
> 实际内部工具调用次数：约 54 次（WebSearch + WebFetch + Read + Glob + LS + Grep）。
