# panda safety 安全模型源码深度研究

> 研究对象：comma.ai OpenPilot 生态中的 panda CAN 网关固件及其安全模型（safety model）
> 仓库：`commaai/panda`（STM32H725 固件）+ `commaai/opendbc`（车辆安全逻辑，已从 panda 仓库迁移出来）
> 文档版本对应：opendbc master（2026-07 最新），panda master（2026-07 最新）
> 关联文档：`02y_panda_hardware.md`（panda 硬件）、`02s_safety_model.md`（openpilot 侧安全模型总览）

---

## 0. 概述与仓库演进

panda 是 comma.ai 设计的 CAN/CAN-FD 网关，运行在 STM32H725 上，物理上串接在车辆 OBD-II / 方向盘下方线束中。它的核心职责只有两件：**讲 CAN** 和 **强制执行 openpilot 的安全模型**。

历史上，panda 固件仓库（`commaai/panda`）中曾包含完整的车辆特定安全逻辑（`board/safety/safety_model.h`、`board/safety/safety_model.c`、`board/safety/safety_defaults.h` 以及各品牌的 `safety_toyota.h` 等）。但随着 OpenPilot 支持车辆数量膨胀到 250+ 款，comma.ai 在 2024-2025 年完成了一次重要的代码重组：**所有车辆特定安全逻辑被迁移到 `commaai/opendbc` 仓库的 `opendbc/safety/` 目录**，panda 固件在编译时通过 SCons 构建系统把 opendbc 的 safety 代码链接进来。

 panda 仓库 README 明确写道：

> "panda is compiled with vehicle-specific safety logic provided by opendbc. See details about the car safety models, safety testing, and code rigor in that repository."

因此本报告的源码分析以 `opendbc/safety/` 为准，并辅以 `panda/board/main.c`、`panda/python/__init__.py` 描述固件侧的 `set_safety_mode` 入口与心跳机制。

openpilot 官方 `docs/SAFETY.md` 给出了安全模型的两大顶层要求：

1. 驾驶员必须能立即夺回车辆控制权（踩刹车或按 Cancel 键）。
2. 车辆轨迹不能变化得太快以至于驾驶员来不及反应——执行器必须被约束在合理范围内（横向参考 ISO 11270，纵向参考 ISO 15622，约 0.9 秒最大执行时间达到 1m 横向偏移）。

panda 的 safety 模型就是把这两条要求在 MCU 固件层用 C 代码硬性落实，**即使运行在 panda 之上的应用层（openpilot / 用户 fork / 任意 USB 程序）被攻破或失控，panda 也不会发出违反约束的 CAN 帧**。这是一道独立于应用层的硬件级安全栅栏。

代码规范层面，panda 固件强制 `-Wall -Wextra -Wstrict-prototypes -Werror`，并通过 cppcheck + MISRA C:2012 addon 做静态检查，safety 逻辑还配有每个车系的单元测试 + 突变测试（mutation test）+ HIL 测试。

---

## 1. safety 源码结构

### 1.1 目录树

```
opendbc/safety/
├── safety.h              # 主框架：safety_rx_hook / safety_tx_hook / safety_fwd_hook / set_safety_hooks
├── declarations.h        # 所有 SAFETY_* 模式常量、所有结构体定义（CanMsg / Limits / RxCheck / safety_hooks）
├── can.h                 # CANPacket_t 结构、dlc_to_len 表
├── helpers.h             # SAFETY_MIN/MAX/ABS/CLAMP、interpolate、microsecond_timer_get 等
├── lateral.h             # 横向：steer_torque_cmd_checks / steer_angle_cmd_checks / steer_curvature_cmd_checks
├── longitudinal.h        # 纵向：longitudinal_accel/gas/brake/speed/transmission_rpm_checks
├── ignition.h            # CAN 点火状态判定
└── modes/
    ├── defaults.h        # nooutput_hooks / alloutput_hooks
    ├── honda.h           # 本田 Nidec / Bosch
    ├── toyota.h          # 丰田 LKA / LTA / SecOC
    ├── tesla.h           # 特斯拉 Model 3/Y（角度控制 + 车辆模型）
    ├── gm.h              # 通用 ASCM / CAM
    ├── ford.h            # 福特（曲率控制）
    ├── hyundai.h         + hyundai_common.h + hyundai_canfd.h
    ├── chrysler.h / chrysler_cusw.h
    ├── rivian.h
    ├── subaru.h / subaru_preglobal.h
    ├── mazda.h / nissan.h
    ├── volkswagen_mqb.h / volkswagen_mlb.h / volkswagen_meb.h / volkswagen_pq.h
    ├── elm327.h          # OBD-II 诊断透传（ISO 15765-4）
    ├── body.h            # comma body 底盘
    └── psa.h
```

`safety.h` 顶部用一长串 `#include "opendbc/safety/modes/*.h"` 把所有车系的安全钩子都拉进来，构成一个编译期注册表。

### 1.2 核心数据结构（declarations.h）

`CANPacket_t`（来自 `can.h`）是一个紧凑的位域结构，是所有 hook 的统一入参：

```c
typedef struct {
  unsigned char fd : 1;
  unsigned char bus : 3;
  unsigned char data_len_code : 4;
  unsigned char rejected : 1;
  unsigned char returned : 1;
  unsigned char extended : 1;
  unsigned int addr : 29;
  unsigned char checksum;
  unsigned char data[CANPACKET_DATA_SIZE_MAX];   // 64
} __attribute__((packed, aligned(4))) CANPacket_t;
```

每个车系要填的是 `safety_config`：

```c
typedef struct {
  RxCheck *rx_checks;          // 接收白名单 + 校验规则
  int rx_checks_len;
  const CanMsg *tx_msgs;       // 发送白名单
  int tx_msgs_len;
  bool disable_forwarding;     // 是否禁用 bus0<->bus2 转发
} safety_config;
```

`CanMsg` 描述一条允许发送的 CAN 消息，关键字段 `check_relay` 用于继电器故障检测：

```c
typedef struct {
  int addr;
  unsigned int bus;
  int len;
  bool check_relay;            // 若为 true，且在目标 bus 上发现 stock ECU 仍在发该地址，触发 relay_malfunction
  bool disable_static_blocking; // 给选择性 AEB 透传等场景关闭静态转发阻断
} CanMsg;
```

执行器限制结构有三套，对应三种横向控制范式：

```c
typedef struct {
  const int max_torque;             // 绝对扭矩上限
  const bool dynamic_max_torque;    // 是否随车速查表限扭
  const struct lookup_t max_torque_lookup;
  const int max_rate_up;            // 单帧扭矩上升率
  const int max_rate_down;          // 单帧扭矩下降率
  const int max_rt_delta;           // 250ms 实时窗口内最大变化量
  const SteeringControlType type;   // TorqueMotorLimited / TorqueDriverLimited
  const int driver_torque_allowance;
  const int driver_torque_multiplier;
  const int max_torque_error;       // 命令扭矩与 EPS 实测扭矩的最大允许偏差
  const int min_valid_request_frames;
  const int max_invalid_request_frames;
  const uint32_t min_valid_request_rt_interval;
  const bool has_steer_req_tolerance;
} TorqueSteeringLimits;

typedef struct {                    // 角度控制（LTA / Tesla / Nissan）
  const int max_angle;
  const float angle_deg_to_can;
  const struct lookup_t angle_rate_up_lookup;
  const struct lookup_t angle_rate_down_lookup;
  const uint32_t frequency;
} AngleSteeringLimits;

typedef struct {                    // 曲率控制（Ford）
  const int max_curvature;
  const float curvature_to_can;
  const uint32_t frequency;
  const int max_curvature_error;
  const float curvature_error_min_speed;
  const int max_steer_power;
} CurvatureSteeringLimits;
```

纵向限制统一为 `LongitudinalLimits`，包含 `max_accel / min_accel / inactive_accel / max_gas / min_gas / inactive_gas / max_brake / max/min/inactive_transmission_rpm / inactive_speed`。

`SAFETY_MODE` 常量从 cereal 的 `CarParams.SafetyModel` 枚举映射而来（declarations.h）：

```c
#define SAFETY_SILENT              0U
#define SAFETY_HONDA_NIDEC         1U
#define SAFETY_TOYOTA              2U
#define SAFETY_ELM327              3U
#define SAFETY_GM                  4U
#define SAFETY_FORD                6U
#define SAFETY_HYUNDAI             8U
#define SAFETY_CHRYSLER            9U
#define SAFETY_TESLA               10U
#define SAFETY_SUBARU              11U
#define SAFETY_MAZDA               13U
#define SAFETY_NISSAN              14U
#define SAFETY_VOLKSWAGEN_MQB      15U
#define SAFETY_ALLOUTPUT           17U
#define SAFETY_NOOUTPUT            19U
#define SAFETY_HONDA_BOSCH         20U
#define SAFETY_HYUNDAI_LEGACY      23U
#define SAFETY_BODY                27U
#define SAFETY_HYUNDAI_CANFD       28U
#define SAFETY_RIVIAN              33U
#define SAFETY_VOLKSWAGEN_MEB      34U
// ...
```

---

## 2. safety_rx_hook / safety_tx_hook 实现细节

### 2.1 safety_rx_hook —— 接收 CAN 时调用

panda 从 CAN 总线收到一帧后会调用 `safety_rx_hook`。完整实现（safety.h）：

```c
bool safety_rx_hook(const CANPacket_t *msg) {
  bool controls_allowed_prev = controls_allowed;
  // 1) rx 校验：checksum / counter / quality flag / 频率
  bool valid = rx_msg_safety_check(msg, &current_safety_config, current_hooks);
  // 2) 是否在 rx_checks 白名单中
  bool whitelisted = get_addr_check_index(msg, current_safety_config.rx_checks,
                                          current_safety_config.rx_checks_len) != -1;
  // 3) 只有 valid && whitelisted 才交给车系 rx 钩子解析（更新 torque_meas / speed / brake_pressed 等）
  if (valid && whitelisted) {
    current_hooks->rx(msg);
  }
  // 4) 通用接收检查：刹车/油门/动能回收/转向脱开的上升沿 → controls_allowed=false
  generic_rx_checks();
  // 5) relay malfunction / stock ECU liveness 检测
  const int addr = msg->addr;
  for (int i = 0; i < current_safety_config.tx_msgs_len; i++) {
    const CanMsg *m = &current_safety_config.tx_msgs[i];
    if (m->check_relay) {
      stock_ecu_check((m->addr == addr) && (m->bus == msg->bus));
    }
  }
  // 6) controls_allowed 上升沿重置心跳失配计数（防竞态）
  if (controls_allowed && !controls_allowed_prev) {
    heartbeat_engaged_mismatches = 0;
  }
  return valid;   // 返回 false 表示这帧 rx 校验失败（会计入 safety_rx_invalid）
}
```

返回值含义：**1 = 该帧通过了 safety rx 校验（checksum/counter/quality 都对），0 = 校验失败**。注意 rx 钩子的返回值并不直接决定是否丢弃该帧（panda 仍会把它送给 USB 上位机），但会累计 `safety_rx_invalid` 计数并通过 `health()` 暴露给 openpilot，用于触发"安全模型不健康"警告。

`generic_rx_checks()` 是关键的安全降级逻辑，所有车系共享：

```c
static void generic_rx_checks(void) {
  gas_pressed_prev = gas_pressed;
  // 刹车上升沿 → 立即退出控制
  if (brake_pressed && (!brake_pressed_prev || vehicle_moving)) {
    controls_allowed = false;
  }
  brake_pressed_prev = brake_pressed;
  // 动能回收拨片上升沿 → 退出控制
  if (regen_braking && (!regen_braking_prev || vehicle_moving)) {
    controls_allowed = false;
  }
  regen_braking_prev = regen_braking;
  // 转向脱开（driver override）上升沿 → 退出控制
  if (steering_disengage && !steering_disengage_prev) {
    controls_allowed = false;
  }
  steering_disengage_prev = steering_disengage;
}
```

这正对应 SAFETY.md 第 1 条要求——驾驶员踩刹车/油门/扳方向盘能立刻夺回控制权。

### 2.2 safety_tx_hook —— 发送 CAN 时调用

panda 在把 USB/SPI 下来的 CAN 帧真正送上总线前，会调用 `safety_tx_hook`：

```c
bool safety_tx_hook(CANPacket_t *msg) {
  // 1) 发送白名单：地址 + bus + 长度 三元组必须命中 tx_msgs
  bool whitelisted = tx_msg_safety_check(msg, current_safety_config.tx_msgs,
                                         current_safety_config.tx_msgs_len);
  // ALLOUTPUT / ELM327 两种诊断/调试模式直接放行白名单
  if ((current_safety_mode == SAFETY_ALLOUTPUT) || (current_safety_mode == SAFETY_ELM327)) {
    whitelisted = true;
  }
  // 2) 交给车系 tx 钩子做执行器限幅检查
  bool safety_allowed = false;
  if (whitelisted) {
    safety_allowed = current_hooks->tx(msg);
  }
  // 3) 三重 AND：无 relay 故障 && 白名单 && 车系检查通过
  return !relay_malfunction && whitelisted && safety_allowed;
}
```

**返回值 1 = 允许发送，0 = 拒绝发送**。被拒绝的帧会打上 `rejected` 位回送给上位机，同时累计 `safety_tx_blocked`。这是 panda 安全模型的核心关卡：任何不满足白名单或限幅的命令根本走不出 panda。

### 2.3 safety_fwd_hook —— 总线间转发

panda 串接在 bus0（车辆动力总线）和 bus2（原车 ADAS ECU）之间，默认把 bus0↔bus2 互相转发，从而"代理"原车 ADAS。`safety_fwd_hook` 决定哪些帧需要被阻断（让 openpilot 取代原车 ADAS 发送）：

```c
int safety_fwd_hook(int bus_num, int addr) {
  bool blocked = relay_malfunction || current_safety_config.disable_forwarding;
  const int destination_bus = get_fwd_bus(bus_num);   // 0<->2
  // 阻断那些 check_relay 且要去往目标 bus 的地址（即 openpilot 要接管发送的地址）
  if (!blocked) {
    for (int i = 0; i < current_safety_config.tx_msgs_len; i++) {
      const CanMsg *m = &current_safety_config.tx_msgs[i];
      if (m->check_relay && !m->disable_static_blocking
          && (m->addr == addr) && (m->bus == (unsigned int)destination_bus)) {
        blocked = true;
        break;
      }
    }
  }
  if (!blocked && (current_hooks->fwd != NULL)) {
    blocked = current_hooks->fwd(bus_num, addr);   // 车系可动态决策（如 Tesla 选择性放行 stock AEB）
  }
  return blocked ? -1 : destination_bus;
}
```

### 2.4 relay malfunction 检测

`stock_ecu_check` 是 panda 防止"线束继电器粘连/被旁路"的关键机制。如果 panda 在自己应当接管发送的地址（`check_relay=true`）所在的总线上，**仍然能听到原车 ECU 在发同样的地址**，就说明继电器没有真正断开原车 ECU，此时置 `relay_malfunction=true`，此后所有 tx 都被 `safety_tx_hook` 拒绝（`!relay_malfunction` 短路），同时触发 `FAULT_RELAY_MALFUNCTION` 硬件故障。

```c
static void stock_ecu_check(bool stock_ecu_detected) {
  const uint32_t RELAY_TRNS_TIMEOUT = 1U;   // 继电器切换后给 1 秒过渡期
  if ((safety_mode_cnt > RELAY_TRNS_TIMEOUT) && stock_ecu_detected) {
    relay_malfunction_set();   // relay_malfunction = true
  }
}
```

---

## 3. whitelist / blacklist 机制

panda safety **没有传统意义上的 blacklist（黑名单）**，而是采用**显式白名单（allowlist）+ 严格默认拒绝**的策略。这一点非常关键：任何不在白名单里的 CAN 帧，panda 都不会替上位机发送。

### 3.1 发送白名单 tx_msgs

每个车系的 `xxx_init()` 返回一个 `safety_config`，其中 `tx_msgs` 数组列出 openpilot 允许发出的全部 CAN 地址。以丰田为例（toyota.h）：

```c
#define TOYOTA_BASE_TX_MSGS \
  {0x191, 0, 8, .check_relay = true},   /* STEERING_LTA */
  {0x412, 0, 8, .check_relay = true},   /* STEERING_LKA */
  {0x1D2, 0, 8, .check_relay = false},  /* PCM_CRUISE */
#define TOYOTA_COMMON_TX_MSGS \
  TOYOTA_BASE_TX_MSGS \
  {0x2E4, 0, 5, .check_relay = true},   /* STEER */
  {0x343, 0, 8, .check_relay = false},  /* ACC_CONTROL */
#define TOYOTA_COMMON_LONG_TX_MSGS \
  TOYOTA_COMMON_TX_MSGS \
  {0x283, 0, 7, .check_relay = false},  /* DSU bus 0 */
  {0x2E6, 0, 8, .check_relay = false}, {0x2E7, 0, 8, .check_relay = false},
  {0x33E, 0, 7, .check_relay = false}, {0x344, 0, 8, .check_relay = false},
  {0x365, 0, 7, .check_relay = false}, {0x366, 0, 7, .check_relay = false},
  {0x4CB, 0, 8, .check_relay = false},
  {0x128, 1, 6, .check_relay = false}, {0x141, 1, 4, .check_relay = false},
  {0x160, 1, 8, .check_relay = false}, {0x161, 1, 7, .check_relay = false},
  {0x470, 1, 4, .check_relay = false},
  {0x411, 0, 8, .check_relay = false},  /* PCS_HUD */
  {0x750, 0, 8, .check_relay = false},  /* radar diagnostic */
  {0x343, 0, 8, .check_relay = true},   /* ACC */
```

注意三元组 `{addr, bus, len}` 必须完全匹配——地址对、但长度错的帧也会被拒。

### 3.2 接收白名单 rx_checks

`rx_checks` 不仅是白名单，还附带每条消息的**校验规则**（期望频率、是否检查 checksum、counter 最大值、是否检查 quality flag）。`rx_msg_safety_check` 会逐项核对：

```c
static bool rx_msg_safety_check(const CANPacket_t *msg, const safety_config *cfg,
                                const safety_hooks *safety_hooks) {
  int index = get_addr_check_index(msg, cfg->rx_checks, cfg->rx_checks_len);
  update_addr_timestamp(cfg->rx_checks, index);
  if (index != -1) {
    // checksum 校验
    if ((safety_hooks->get_checksum != NULL) && (safety_hooks->compute_checksum != NULL)
        && !cfg->rx_checks[index].msg[...].ignore_checksum) {
      uint32_t checksum = safety_hooks->get_checksum(msg);
      uint32_t checksum_comp = safety_hooks->compute_checksum(msg);
      cfg->rx_checks[index].status.valid_checksum = (checksum_comp == checksum);
    }
    // counter 校验（连续错 MAX_WRONG_COUNTERS=5 次则失效）
    if ((safety_hooks->get_counter != NULL) && (...max_counter > 0U)) {
      update_counter(cfg->rx_checks, index, safety_hooks->get_counter(msg));
    }
    // quality flag 校验
    if ((safety_hooks->get_quality_flag_valid != NULL) && !...ignore_quality_flag) {
      cfg->rx_checks[index].status.valid_quality_flag = safety_hooks->get_quality_flag_valid(msg);
    }
  }
  return is_msg_valid(cfg->rx_checks, index);   // 任一项失败 → controls_allowed=false
}
```

例如现代（hyundai.h）的接收校验：

```c
#define HYUNDAI_COMMON_RX_CHECKS(legacy) \
  {.msg = {{0x260, 0, 8, 100U, .max_counter = 3U, .ignore_quality_flag = true}, \
           {0x371, 0, 8, 100U, .ignore_checksum = true, .ignore_counter = true, .ignore_quality_flag = true}, {0}}}, \
  {.msg = {{0x386, 0, 8, 100U, .ignore_checksum = (legacy), .ignore_counter = (legacy), .max_counter = (legacy) ? 0U : 15U, ...}}}, \
  {.msg = {{0x394, 0, 8, 100U, ..., .max_counter = (legacy) ? 0U : 7U, ...}}}, \
  {.msg = {{0x251, 0, 8, 50U, .ignore_checksum = true, .ignore_counter = true, ...}}}, \
  {.msg = {{0x4F1, 0, 4, 50U, .ignore_checksum = true, .max_counter = 15U, ...}}},
```

`RxCheck` 还支持 `MAX_ADDR_CHECK_MSGS=3` 个候选消息（同一逻辑信号在不同车系上可能出现在不同地址/长度，运行时锁定第一个看到的）。

### 3.3 1Hz 频率/存活检查 safety_tick

panda main.c 在 1Hz tick 里调用 `safety_tick(&current_safety_config)`，对每条 rx_check 消息计算 `elapsed_time`，如果超过 `max(timestep * MAX_MISSED_MSGS=10, 1s)` 则标记 `lagging=true` 并强制 `controls_allowed=false`。这保证了一旦关键信号（车速、方向盘扭矩、刹车状态等）丢失，openpilot 立即失去控制权。

### 3.4 启用 / 禁用切换

白名单的"启用/禁用"完全由 `current_safety_mode` 决定：
- `SAFETY_SILENT`（默认上电模式）：`nooutput_hooks`，`tx_msgs=NULL`，无任何发送白名单，CAN 收发器进入 silent 模式，继电器断开 → panda 完全静默，只监听不发送。
- `SAFETY_NOOUTPUT`：监听总线但不发送，继电器断开，CAN 收发器正常。
- `SAFETY_ALLOUTPUT`：透传模式，`alloutput_tx_hook` 永远返回 true，`controls_allowed=true`，用于开发/刷写。仅在 `ALLOW_DEBUG` 编译时注册。
- `SAFETY_ELM327`：OBD-II 诊断透传，仅放行 ISO 15765-4 诊断地址。
- 各品牌模式（`SAFETY_TOYOTA` 等）：加载对应车系的 `safety_config`，启用该车的白名单与限幅。

---

## 4. MAX_STEER / MAX_GAS / MAX_BRAKE 限制

各品牌执行器绝对上限差异极大。下表汇总自各 `modes/*.h` 的 `tx_hook` 内联定义（数值均为 CAN 原始整数单位，括号内为物理量）。

| 品牌 | 横向控制类型 | max_torque / max_angle / max_curvature | max_rate_up / down | max_rt_delta (250ms) | 纵向 max_accel / min_accel | max_gas / max_brake |
|---|---|---|---|---|---|---|
| **Toyota** (LKA) | 扭矩 (Motor) | 1500 | 15 / 25 | 450 | +2000 / -3500 (±2.0/-3.5 m/s²) | — |
| **Toyota** (LTA) | 角度 | 1657 (94.9°) | 查表 0.15-0.3 °/帧 | — | 同上 | — |
| **Honda Nidec** | 扭矩 (Motor) | ~1000 | — | — | stock long | — |
| **Honda Bosch** | 扭矩 (Driver) | — | — | — | stock long | — |
| **Hyundai** (默认) | 扭矩 (Driver) | 384 | 3 / 7 | 112 | +200 / -350 (1/100 m/s² → ±2.0/-3.5) | — |
| **Hyundai** ALT | 扭矩 (Driver) | 270 | 2 / 3 | 112 | 同上 | — |
| **Hyundai** ALT_2 | 扭矩 (Driver) | 170 | 2 / 3 | 112 | 同上 | — |
| **Ford** | 曲率 | 1000 (0.02 rad/m), curvature_to_can=50000 | — | — | +5641 / +4231 (±2.0/-3.5 m/s²), inactive=5128 | max_gas=700 (2.0), min_gas=450 (-0.5) |
| **GM** (ASCM) | 扭矩 (Driver) | 300 | 10 / 15 | 128 | — | max_gas=1018×8, min_gas=-650×8, max_brake=400 |
| **GM** (CAM) | 扭矩 (Driver) | 300 | 10 / 15 | 128 | — | max_gas=1346×8, min_gas=-540×8, max_brake=400 |
| **Tesla** M3/Y | 角度 + 车辆模型 | 3600 (360°), angle_deg_to_can=10 | 由 VM 推导 (ISO 11270) | rt_angle_rate_limit | +425 / +288 (±2.0/-3.48 m/s²), inactive=375 | — |
| **Rivian** | 扭矩 (Driver, 动态) | 350 (<9m/s) → 250 (>17m/s) | 3 / 5 | 125 | +200 / -350 (±2.0/-3.5 m/s²) | — |

几点说明：

- **扭矩控制分两种**：`TorqueMotorLimited`（受 EPS 实测电机扭矩 `torque_meas` 约束，如 Toyota/Honda-Nidec）和 `TorqueDriverLimited`（受驾驶员手力 `torque_driver` 约束，如 Hyundai/GM/Rivian）。后者通过 `driver_torque_allowance` + `driver_torque_multiplier` 让 openpilot 在驾驶员轻微发力时仍能维持控制，但一旦驾驶员明显发力就会被压缩。
- **Tesla 是唯一使用完整车辆模型（VehicleModel）做限制的车系**：`steer_ratio=12`、`wheelbase=2.89m`、`slip_factor=-0.00058`，把曲率→角度转换纳入侧向加速度/侧向加 jerk 约束（`steer_angle_cmd_checks_vm`），上限为 ISO 11270 的 `MAX_LATERAL_ACCEL≈3.6 m/s²`、`MAX_LATERAL_JERK≈3.6 m/s³`。
- **Ford 是唯一原生曲率控制**的车系，直接命令曲率与曲率变化率，safety 层用 `curvature_to_can=50000` 把 rad/m 换算成 CAN 整数。
- **纵向 inactive 值**非常重要：当 `controls_allowed=false` 时，纵向命令必须严格等于 `inactive_accel/inactive_gas`，否则触发违规。这保证 openpilot 退出控制时不会残留加速/制动命令。

---

## 5. rate limit / torque limit 算法

### 5.1 扭矩命令检查 steer_torque_cmd_checks（lateral.h）

这是 panda safety 最核心、最精密的算法，所有扭矩控制车系都走这条路径：

```c
bool steer_torque_cmd_checks(int desired_torque, int steer_req, const TorqueSteeringLimits limits) {
  bool violation = false;
  uint32_t ts = microsecond_timer_get();

  if (controls_allowed) {
    int max_torque = limits.max_torque;
    if (limits.dynamic_max_torque) {           // Rivian 随车速查表
      const float fudged_speed = (vehicle_speed.min / VEHICLE_SPEED_FACTOR) - 1.;
      max_torque = safety_interpolate(limits.max_torque_lookup, fudged_speed) + 1;
      max_torque = SAFETY_CLAMP(max_torque, -limits.max_torque, limits.max_torque);
    }
    // (a) 全局扭矩绝对值上限
    violation |= safety_max_limit_check(desired_torque, max_torque, -max_torque);
    // (b) 单帧速率限制 + 与实测/驾驶员扭矩的偏差限制
    if (limits.type == TorqueDriverLimited) {
      violation |= driver_limit_check(desired_torque, desired_torque_last, &torque_driver,
                    max_torque, limits.max_rate_up, limits.max_rate_down,
                    limits.driver_torque_allowance, limits.driver_torque_multiplier);
    } else {
      violation |= dist_to_meas_check(desired_torque, desired_torque_last, &torque_meas,
                    limits.max_rate_up, limits.max_rate_down, limits.max_torque_error);
    }
    desired_torque_last = desired_torque;
    // (c) 250ms 实时窗口速率限制（防止短时突变）
    violation |= rt_torque_rate_limit_check(desired_torque, rt_torque_last, limits.max_rt_delta);
    uint32_t ts_elapsed = safety_get_ts_elapsed(ts, ts_torque_check_last);
    if (ts_elapsed > MAX_RT_INTERVAL) {        // 250000 µs
      rt_torque_last = desired_torque;
      ts_torque_check_last = ts;
    }
  }

  // (d) controls_allowed=false 时严禁任何非零扭矩
  if (!controls_allowed && (desired_torque != 0)) violation = true;

  // (e) steer_req 位与扭矩一致性检查（防 EPS 故障）
  bool steer_req_mismatch = (steer_req == 0) && (desired_torque != 0);
  if (!limits.has_steer_req_tolerance) {
    if (steer_req_mismatch) violation = true;
  } else {
    // 允许偶尔把 steer_req 拉低一帧以避免 EPS 角度过大故障
    // 但要求最近 min_valid_request_frames 帧都匹配，且距上次拉低 >= min_valid_request_rt_interval
    ...
  }

  if (violation || !controls_allowed) { /* reset 状态 */ }
  return violation;
}
```

五层防护：**(a) 绝对上限 → (b) 单帧速率+实测偏差 → (c) 250ms 实时窗口 → (d) 禁用期零扭矩 → (e) steer_req 位一致性**。其中 `MAX_RT_INTERVAL = 250000U`（µs）即 250ms，是 ISO 15622 对实时扭矩变化的要求。

`dist_to_meas_check` 与 `driver_limit_check` 的精妙之处在于：它们不是简单的"不超过 max_rate"，而是"如果命令已经超出实测/驾驶员扭矩一定误差，必须开始往 0 方向回收"。这避免了 openpilot 持续对抗 EPS 或驾驶员。

### 5.2 角度命令检查 steer_angle_cmd_checks

角度控制车系（Toyota LTA、Tesla、Nissan）使用此函数。核心逻辑：

1. 把浮点角度速率限制（查表，随车速变化）换算成 CAN 整数单位，并对车速做 `-1 m/s` 的 fudge（保守余量）。
2. 计算 `highest_desired_angle = desired_angle_last + delta_angle_up/down`，超出即违规。
3. 可选的 `enforce_angle_error`：命令角度不能偏离实测角度 `angle_meas` 太多，否则强制往实测方向回收。
4. **ISO 11270 侧向加速度上限**：当 `angle_is_curvature` 时，按 `MAX_LATERAL_ACCEL = 3.0 - 9.81×0.06 ≈ 2.4 m/s²`（考虑平均路面侧倾）限制曲率，确保 0.9 秒最大执行达到 1m 横向偏移的 ISO 要求。
5. `steer_control_enabled=false` 时，命令角度必须为 0 或等于当前实测角度（看 `inactive_angle_is_zero`）。
6. `rt_angle_rate_limit_check`：按 `limits.frequency` 计算 250ms 内允许的最大帧数（×1.2 余量），超频即违规。

Tesla 用的 `steer_angle_cmd_checks_vm` 进一步用车辆模型把限制统一到侧向加速度/jerk，而不是直接限角度速率。

### 5.3 纵向命令检查（longitudinal.h）

纵向非常简洁，所有检查都门控于 `get_longitudinal_allowed()`：

```c
bool get_longitudinal_allowed(void) {
  return controls_allowed && !gas_pressed_prev;   // 控制允许且驾驶员没踩油门
}

bool longitudinal_accel_checks(int desired_accel, const LongitudinalLimits limits) {
  bool accel_valid = get_longitudinal_allowed()
                     && !safety_max_limit_check(desired_accel, limits.max_accel, limits.min_accel);
  bool accel_inactive = (desired_accel == limits.inactive_accel);
  return !(accel_valid || accel_inactive);   // 既不有效也不 inactive → 违规
}

bool longitudinal_brake_checks(int desired_brake, const LongitudinalLimits limits) {
  bool violation = false;
  violation |= !get_longitudinal_allowed() && (desired_brake != 0);   // 禁用期严禁刹车
  violation |= desired_brake > limits.max_brake;                       // 刹车绝对上限
  return violation;
}
```

关键设计：**纵向命令只有两种合法状态**——要么在 `controls_allowed && !gas_pressed` 时落在 `[min, max]` 区间内，要么严格等于 `inactive_*` 值。没有中间态。这把"退出控制时残留加速"的攻击面压缩到零。

---

## 6. drive mode 与 controls_allowed

### 6.1 安全模式分类

panda 的"drive mode"实际上是 `current_safety_mode` 这个 uint16 状态变量，配合 `current_safety_param`（车系内细分标志位）。从功能上可分四类：

| 类别 | 模式 | 行为 |
|---|---|---|
| **静默** | `SAFETY_SILENT` | 默认上电模式。CAN 收发器 silent，继电器断开，不发送任何帧。`heartbeat` 丢失时自动回到此模式。 |
| **监听** | `SAFETY_NOOUTPUT` | CAN 正常监听，继电器断开，仍不发送。用于 openpilot 调试/数据采集。 |
| **诊断** | `SAFETY_ELM327` | OBD-II 透传，仅放行 ISO 15765-4 诊断地址（见第 9 节）。 |
| **控制** | `SAFETY_TOYOTA` 等 | 真正的 ADAS 控制模式。继电器吸合（接管原车 ADAS），加载车系白名单与限幅。 |
| **调试** | `SAFETY_ALLOUTPUT` | 全透传，永远放行。仅 `ALLOW_DEBUG` 编译时可用，正式固件不含。 |

`is_car_safety_mode()` 判断当前是否处于"真车控制"模式（非 SILENT/NOOUTPUT/ALLOUTPUT/ELM327），此模式下不允许禁用心跳。

### 6.2 controls_allowed —— 控制允许标志

`controls_allowed` 是 safety 模型的"主开关"，是一个全局 `bool`，**只能由 rx 钩子内部根据车况置位，不能由 USB 上位机直接写**。它的置位/复位规则：

- **置位**（进入控制）：车系 rx 钩子检测到 ACC 启用/巡航激活上升沿、或方向盘按钮 SET/RESUME 按下（如 GM）。
- **复位**（退出控制）：
  - 刹车上升沿（`generic_rx_checks`）
  - 动能回收拨片上升沿
  - 转向脱开上升沿（Tesla `steering_disengage`）
  - ACC 关闭（`pcm_cruise_check(false)`）
  - rx 校验失败（checksum/counter/quality 错）
  - rx 消息 lagging（1Hz tick）
  - 心跳失配 3 次
  - 调用 `set_safety_hooks` 切换模式时统一清零

### 6.3 心跳机制（heartbeat）

openpilot 通过 USB 周期性给 panda 发"心跳"命令，panda main.c 的 1Hz tick 检查 `heartbeat_counter`：

```c
if (heartbeat_counter >= (started ? HEARTBEAT_IGNITION_CNT_ON : HEARTBEAT_IGNITION_CNT_OFF)) {
  // 5 秒（点火）或 2 秒（熄火）没收到心跳 → 回到 SILENT
  if (is_car_safety_mode(current_safety_mode)) heartbeat_lost = true;
  heartbeat_engaged = false;
  if (current_safety_mode != SAFETY_SILENT) set_safety_mode(SAFETY_SILENT, 0U);
  ...
}
```

此外还有 `heartbeat_engaged`（openpilot 通过心跳告知 panda"我已启用"）与 `controls_allowed` 的一致性检查：如果 `controls_allowed=true` 但连续 3 秒没收到 `heartbeat_engaged`，强制 `controls_allowed=false`。这防止 openpilot 进程崩溃后 panda 仍允许执行器动作。

### 6.4 alternative_experience 标志

`alternative_experience` 是一个可通过 USB 设置的 int，允许 fork 启用一些默认关闭的特性（declarations.h）：

```c
#define ALT_EXP_DISABLE_STOCK_AEB                 2   // 禁用原车 AEB
#define ALT_EXP_RAISE_LONGITUDINAL_LIMITS_TO_ISO_MAX  8   // 纵向限幅提升到 ISO 最大值 (-5.0 ~ +4.0 m/s²)
#define ALT_EXP_ALLOW_AEB                         16  // 允许 openpilot 主动发 AEB
```

mainline openpilot 只用 0 或 1。comma.ai 明确警告：设置这些标志意味着关闭了某项原车安全特性，fork 必须告知用户。

---

## 7. 各品牌 safety 配置详解

### 7.1 Toyota（toyota.h，443 行）

支持 4 种子配置，通过 `param` 标志位切换：
- `TOYOTA_PARAM_ALT_BRAKE`：替代刹车消息地址（0x224 vs 0x226）。
- `TOYOTA_PARAM_STOCK_LONGITUDINAL`：保留原车纵向（DSU 不拔），openpilot 只做横向。
- `TOYOTA_PARAM_LTA`：使用 LTA 角度控制而非 LKA 扭矩控制。
- `TOYOTA_PARAM_SECOC`（debug）：SecOC 安全车载网络车型。

接收地址：`0xaa`（轮速，83Hz）、`0x260`（方向盘扭矩/角度，50Hz）、`0x1D2`（PCM_CRUISE/油门，33Hz）、`0x226`/`0x224`（刹车，40Hz）。

发送地址：`0x191`（LTA）、`0x412`（LKA）、`0x2E4`（STEER 扭矩）、`0x343`（ACC_CONTROL）、`0x283`（AEB 阻断，DSU 拔掉时只允许 checksum 字节非零）、`0x750`（雷达 UDS，仅允许 tester present `0x0F 0x02 0x3E 0x00...`）。

扭矩限制：`max_torque=1500, max_rate_up=15, max_rate_down=25, max_rt_delta=450, max_torque_error=350`，`min_valid_request_frames=17, max_invalid_request_frames=1`（允许每 18 帧把 steer_req 拉低 1 帧以避免 EPS 角度故障）。

LTA 角度限制：`max_angle=1657`（≈94.9°），速率查表 `{5,25,25}→{0.3,0.15,0.15}` 上行、`{0.36,0.26,0.26}` 下行。

纵向：`max_accel=2000 (2.0 m/s²), min_accel=-3500 (-3.5 m/s²)`。

### 7.2 Honda（honda.h，436 行）

分 Nidec 与 Bosch 两套钩子（`honda_nidec_hooks` / `honda_bosch_hooks`），Bosch 又分有雷达/无雷达。接收校验地址：`0x1A6`（SCM_BUTTONS）、`0x296`、`0x158`（ENGINE_DATA）、`0x17C`（POWERTRAIN_DATA）、`0x326`（SCM_FEEDBACK）、`0x1BE`（替代刹车）。按钮枚举 `HONDA_BTN_NONE/MAIN/CANCEL/SET/RESUME`。

### 7.3 Hyundai（hyundai.h + hyundai_common.h + hyundai_canfd.h，352 行）

通过 `HYUNDAI_LIMITS(steer, rate_up, rate_down)` 宏统一构造限制，三档：默认 384/3/7、ALT 270/2/3、ALT_2 170/2/3。`driver_torque_allowance=50, driver_torque_multiplier=2, max_rt_delta=112`，`min_valid_request_frames=89, max_invalid_request_frames=2`（每 90 帧允许 2 帧 steer_req 拉低）。

纵向：`max_accel=200, min_accel=-350`（1/100 m/s² 单位，即 +2.0/-3.5 m/s²）。

支持 camera-SCC（雷达摄像头一体）与 radar-SCC 两种硬件拓扑，通过 `scc_bus` 参数切换 `0x4F1` 走 bus0 还是 bus2。`hyundai_legacy` 子模式给老款车（无 counter/checksum）放宽校验。

UDS：`0x7D0` 仅允许 `0x02 0x3E 0x80 0x00...`（tester present），用于禁用雷达。

### 7.4 Ford（ford.h，336 行）

唯一的原生曲率控制车系。`FORD_STEERING_LIMITS`：`max_curvature=1000 (0.02 rad/m), curvature_to_can=50000, frequency=20Hz, max_curvature_error=100 (0.002 rad/m), curvature_error_min_speed=10 m/s`。

纵向 `FORD_LONG_LIMITS` 同时管刹车和油门：`max_accel=5641 (+2.0 m/s²), min_accel=4231 (-3.5 m/s²), inactive_accel=5128`；`max_gas=700 (+2.0), min_gas=450 (-0.5), inactive_gas=0 (-5.0)`。

特殊点：`cmbb_deny` 位必须为 0——safety 主动禁止 openpilot 阻断原车 AEB。`Lane_Assist_Data1` 的 `LkaActvStats_D2_Req` 必须为 0，禁止用车道偏离辅助消息做转向，只允许用 `LateralMotionControl`。

CAN-FD 车型用 `FORD_LateralMotionControl2` 与不同的 inactive curvature rate（1024 vs 4096）。

### 7.5 GM（gm.h，244 行）

两套硬件：`GM_ASCM`（旧 Volt/Silverado/Acadia）与 `GM_CAM`（Bolt EUV/Escalade）。扭矩限制统一 `max_torque=300, max_rate_up=10, max_rate_down=15, driver_torque_allowance=65, driver_torque_multiplier=4, max_rt_delta=128`。

纵向限制随硬件不同：ASCM `max_gas=1018×8, min_gas=-650×8, max_brake=400`；CAM `max_gas=1346×8, min_gas=-540×8`。`GM_GAS_TO_CAN=8` 是 1/0.125 的单位换算。

刹车地址 `0x315`，转向 `0x180`，油门/动能回收 `0x2CB`。GM 是少数仍用 `gm_long_limits` 指针（运行时选 ASCM/CAM 限制表）的车系。

### 7.6 Tesla（tesla.h，393 行）

最复杂的角度控制车系。`TESLA_STEERING_LIMITS`：`max_angle=3600 (360°), angle_deg_to_can=10, frequency=50Hz`。配合 `TESLA_STEERING_PARAMS`（`slip_factor=-0.00058, steer_ratio=12, wheelbase=2.89`）走 `steer_angle_cmd_checks_vm`，把限制统一到 ISO 侧向加速度/jerk。

纵向 `TESLA_LONG_LIMITS`：`max_accel=425 (+2.0 m/s²), min_accel=288 (-3.48 m/s²), inactive_accel=375`。

独有特性：
- **AEB 阻断**：`tesla_stock_aeb` 检测原车 DAS_control 的 AEB_ACTIVE，激活时禁止 openpilot 发任何纵向命令。
- **Autopark/Summon 阻断**：`tesla_autopark` 为 true 时禁止所有控制（防与原车自动泊车冲突）。
- **stock LKAS 阻断**：检测到原车 LKAS 激活时禁止 openpilot 转向。
- **FSD 14 标志**：`tesla_fsd_14` 交换 ANGLE_CONTROL 与 LANE_KEEP_ASSIST 的 control type 编码。
- `tesla_fwd_hook` 是少数实现了动态 `fwd` 钩子的车系，选择性放行 `0x27D`/`0x488`/`0x2B9`。

### 7.7 其他品牌简述

- **Rivian**（rivian.h）：`dynamic_max_torque=true`，`max_torque` 随车速从 350（<9m/s）降到 250（>17m/s），低速需要更大扭矩维持相同侧向加速度。
- **Volkswagen**：分 MQB/MLB/MEB/PQ 四套，MQB 用角度控制。
- **Chrysler**：扭矩控制，CUSW 变体为 debug。
- **Subaru**：扭矩控制，Preglobal 老款为 debug。
- **Body**（body.h）：comma 自己的 body 底盘（如 carHarness 执行器），极简——`controls_allowed` 在收到 `0x201` 时置位，`tx_hook` 只检查 `controls_allowed`，白名单含 `0x250/0x251` 与 CAN flasher `0x1`，`disable_forwarding=true`。

---

## 8. safety_set_mode 命令流程

`safety_set_mode` 是 panda 唯一允许离开 SILENT 模式的入口，整条链路如下：

### 8.1 Python API 层

openpilot 通过 `panda.Panda.set_safety_mode(mode, param)` 发起。该方法在 `panda/python/__init__.py` 中，本质是一个 USB control transfer（`REQUEST_OUT`, bRequest=`0xde`，wValue=mode，wIndex=param）。`health()` 方法（bRequest=`0xd2`）反向读取 panda 当前状态，返回字典含 `safety_mode / safety_param / controls_allowed / safety_tx_blocked / safety_rx_invalid / car_harness_status` 等字段。

### 8.2 固件层 set_safety_mode（panda/board/main.c）

```c
// this is the only way to leave silent mode
void set_safety_mode(uint16_t mode, uint16_t param) {
  uint16_t mode_copy = mode;
  int err = set_safety_hooks(mode_copy, param);   // 见 8.3
  if (err == -1) {
    print("Error: safety set mode failed. Falling back to SILENT\n");
    mode_copy = SAFETY_SILENT;
    err = set_safety_hooks(mode_copy, 0U);
    // TERMINAL ERROR: 连 SILENT 都设不上就挂起
    assert_fatal(err == 0, "Error: Failed setting SILENT mode. Hanging\n");
  }
  safety_tx_blocked = 0;
  safety_rx_invalid = 0;
  switch (mode_copy) {
    case SAFETY_SILENT:
      set_intercept_relay(false, false);          // 继电器断开
      current_board->set_can_mode(CAN_MODE_NORMAL);
      can_silent = true;                          // CAN 收发器静默
      break;
    case SAFETY_NOOUTPUT:
      set_intercept_relay(false, false);
      current_board->set_can_mode(CAN_MODE_NORMAL);
      can_silent = false;
      break;
    case SAFETY_ELM327:
      set_intercept_relay(false, false);
      heartbeat_counter = 0U; heartbeat_lost = false;
      can_clear_send(CANIF_FROM_CAN_NUM(1), 1);
      if (param == 0U) current_board->set_can_mode(CAN_MODE_OBD_CAN2);
      else current_board->set_can_mode(CAN_MODE_NORMAL);
      can_silent = false;
      break;
    default:                                       // 真车控制模式
      set_intercept_relay(true, false);           // 继电器吸合，接管原车 ADAS
      heartbeat_counter = 0U; heartbeat_lost = false;
      current_board->set_can_mode(CAN_MODE_NORMAL);
      can_silent = false;
      break;
  }
  can_init_all();
}
```

### 8.3 set_safety_hooks（safety.h）

`set_safety_hooks(mode, param)` 在 `safety_hook_registry[]` 表中查 mode，找到对应钩子后：

1. **重置全部全局状态**：`controls_allowed=false`、`relay_malfunction=false`、`gas/brake/regen/steering_disengage=false`、所有 `sample_t`（torque_meas/torque_driver/angle_meas/vehicle_speed）清零、`safety_mode_cnt=0`、所有 timestamp 清零。
2. 调用 `current_hooks->init(param)`，让车系根据自己的 `param` 标志位构造并返回 `safety_config`（含 tx_msgs 与 rx_checks）。
3. 把返回的 config 存入 `current_safety_config`，hooks 存入 `current_hooks`，mode/param 存入 `current_safety_mode/param`。
4. 若 mode 不在注册表中返回 -1，由 `set_safety_mode` 兜底回 SILENT。

注册表（部分）：
```c
const safety_hook_config safety_hook_registry[] = {
  {SAFETY_SILENT, &nooutput_hooks},
  {SAFETY_HONDA_NIDEC, &honda_nidec_hooks},
  {SAFETY_TOYOTA, &toyota_hooks},
  {SAFETY_ELM327, &elm327_hooks},
  {SAFETY_GM, &gm_hooks},
  {SAFETY_HONDA_BOSCH, &honda_bosch_hooks},
  {SAFETY_HYUNDAI, &hyundai_hooks},
  ...
  {SAFETY_TESLA, &tesla_hooks},
  {SAFETY_HYUNDAI_CANFD, &hyundai_canfd_hooks},
#ifdef ALLOW_DEBUG
  {SAFETY_CHRYSLER_CUSW, &chrysler_cusw_hooks},
  {SAFETY_ALLOUTPUT, &alloutput_hooks},
  ...
#endif
};
```

注意 `SAFETY_ALLOUTPUT`、`SAFETY_VOLKSWAGEN_MLB`、`SAFETY_SUBARU_PREGLOBAL` 等仅在 `ALLOW_DEBUG` 编译时注册——**正式发布固件不含全透传模式**，这是重要的安全防线。

### 8.4 模式切换的安全验证

- **mode 合法性**：不在注册表的 mode 直接返回 -1 → 兜底 SILENT。
- **状态全清零**：切换模式时 `controls_allowed` 必清零，避免上一个模式的残留状态让新模式立刻获得控制权。
- **继电器联动**：只有真车模式才吸合继电器；SILENT/NOOUTPUT/ELM327 强制断开。
- **心跳重置**：切换时 `heartbeat_counter=0`，给 openpilot 重新建立心跳的时间窗。
- **1Hz tick 守护**：即使 set_safety_mode 成功，若 5 秒内没收到心跳，1Hz tick 会强制回到 SILENT。
- **harness 翻转**：tick_handler 检测到线束方向变化（`HARNESS_STATUS_FLIPPED`）时，会重新调用 `set_safety_mode(current_safety_mode, current_safety_param)` 重建 CAN 朝向。

---

## 9. J2534 / ISO-TP / UDS 诊断

### 9.1 ELM327 模式 —— OBD-II 透传（elm327.h）

`SAFETY_ELM327` 是 panda 内置的 OBD-II 诊断透传模式，等价于一个 ELM327 适配器，用于车辆诊断、读 DTC、刷写等。它复用 `nooutput_init`（无 rx 检查、`controls_allowed=false`），但自定义 `elm327_tx_hook`：

```c
static bool elm327_tx_hook(const CANPacket_t *msg) {
  const unsigned int GM_CAMERA_DIAG_ADDR = 0x24BU;
  bool tx = true;
  int len = GET_LEN(msg);
  // 所有 ISO 15765-4 消息必须 8 字节
  if (len != 8) tx = false;
  // 校验合法的 29 位 / 11 位 ISO 15765-4 诊断地址
  if ((msg->addr != 0x18DB33F1U) &&                    // 功能寻址
      ((msg->addr & 0x1FFF00FFU) != 0x18DA00F1U) &&    // 29 位物理寻址 0x18DA00F1
      ((msg->addr & 0x1FFFFF00U) != 0x600U) &&         // 11 位 0x6xx
      ((msg->addr & 0x1FFFFF00U) != 0x700U) &&         // 11 位 0x7xx
      (msg->addr != GM_CAMERA_DIAG_ADDR)) {            // GM 摄像头非标诊断地址
    tx = false;
  }
  // GM 摄像头地址只允许 ISO 15765-2 (ISO-TP) 已知帧类型 (<=0x30)
  if ((msg->addr == GM_CAMERA_DIAG_ADDR) && (len == 8)) {
    if ((msg->data[0] & 0xF0U) > 0x30U) tx = false;
  }
  return tx;
}
const safety_hooks elm327_hooks = {
  .init = nooutput_init,
  .rx = default_rx_hook,
  .tx = elm327_tx_hook,
};
```

这对应 **J2534 Pass-Thru** 的核心场景：上位机软件（如 Techstream、OBD-II 扫描仪）通过 USB 把诊断帧送给 panda，panda 仅校验地址符合 ISO 15765-4（CAN-TP 物理寻址 `0x18DA00F1`、功能寻址 `0x18DB33F1`、11 位 `0x6xx/0x7xx`）和长度为 8 字节，就转发到 OBD-II 总线（`param==0` 时 bus1 复用为 OBD-II）。ISO 15765-2（ISO-TP）的分包/组装由上位机完成，panda 只做地址白名单。

`SAFETY_ELM327` 不接管车辆控制（继电器断开、`controls_allowed=false`），因此与 ADAS 安全模型完全隔离。

### 9.2 UDS tester present 白名单

在真车控制模式下，部分车系需要向雷达/ECU 发送 UDS `tester present`（Service 0x3E）以禁用原车 ADAS 或防止其超时。panda safety 通过**固定字节匹配**严格限制只能发 tester present，禁止任何其他 UDS 服务（如 SecurityAccess 0x27、RoutineControl 0x31、写数据 0x2E 等），避免被滥用做未授权 ECU 刷写。

**Toyota（toyota.h）**——雷达诊断地址 `0x750`（子寻址 0xF）：

```c
// UDS: Only tester present ("\x0F\x02\x3E\x00\x00\x00\x00\x00") allowed on diagnostics address
if (msg->addr == 0x750U) {
  // this address is sub-addressed. only allow tester present to radar (0xF)
  bool invalid_uds_msg = (GET_BYTES(msg, 0, 4) != 0x003E020FU)   // 0x0F 0x02 0x3E 0x00
                      || (GET_BYTES(msg, 4, 4) != 0x0U);
  if (invalid_uds_msg) tx = false;
}
```

字节序：`0x0F`（子地址=雷达）+ `0x02`（PCI=单帧长度2）+ `0x3E`（UDS Service=tester present）+ `0x00`（sub-function=positive response requested）+ 4 字节 0 填充。任何其他字节组合都被拒。

**Hyundai（hyundai.h）**——雷达 UDS 地址 `0x7D0`：

```c
// UDS: Only tester present ("\x02\x3E\x80\x00\x00\x00\x00\x00") allowed on diagnostics address
if (msg->addr == 0x7D0U) {
  if ((GET_BYTES(msg, 0, 4) != 0x00803E02U)   // 0x02 0x3E 0x80 0x00
      || (GET_BYTES(msg, 4, 4) != 0x0U)) {
    tx = false;
  }
}
```

注意 Hyundai 的 sub-function 是 `0x80`（suppressPositiveResponse），与 Toyota 的 `0x00` 不同。

### 9.3 ISO-TP 与 safety 的关系

panda safety **不实现 ISO-TP 协议层**（不分包、不重组），它只在 CAN 帧级别做地址+长度+固定字节的白名单匹配。ISO-TP 的多帧传输（FC/CF 帧，PCI 类型 0x20/0x30）在 ELM327 模式下被 `0x30` 阈值限制（GM 摄像头），在真车模式下通常完全禁止（只允许单帧 tester present）。这种设计把诊断攻击面压到最小：panda 不会成为任意 ECU 刷写的通道。

### 9.4 与 J2534 的对比

J2534 是 SAE/EPA 强制的通用 Pass-Thru 诊断接口标准（API 层），panda 的 `SAFETY_ELM327` 模式在功能上等价于一个 J2534 设备的 CAN 通道，但：
- panda 用 USB vendor request 而非 J2534 API；
- panda 额外强制 ISO 15765-4 地址白名单（J2534 设备通常不限制目标地址）；
- panda 不能在 ELM327 模式下同时做 ADAS 控制（继电器断开），诊断与控制互斥。

---

## 10. AuroraDrive 迁移建议与 C++ safety 模型

### 10.1 AuroraDrive 当前现状

AuroraDrive 当前是纯仿真/数据集回放栈，**没有 CAN 总线接口、没有执行器、没有 safety 模型**。所有"控制"输出（方向盘扭矩、油门、刹车）只写入仿真器的内存对象或 ROS topic，不存在"被恶意命令真的把车开动"的风险。因此当前阶段不需要 panda safety。

但这种"无安全模型"的状态一旦走向真车（台架车、开发车），风险会瞬间爆表：任何一个 bug（MPC 数值发散、state estimator 错误、消息反序列化错位）都可能直接把异常扭矩送到转向柱。**强烈建议在真车适配前，先实现一套软件 safety 层**，哪怕不跑在独立 MCU 上。

### 10.2 借鉴 panda safety 的设计思想

panda safety 模型经过数亿英里实车验证，其设计原则值得完整移植到 AuroraDrive：

1. **独立进程/独立硬件**：safety 层必须独立于规划/控制进程， ideally 独立于应用 CPU（独立 MCU 或独立核）。panda 用物理继电器切断原车 ADAS，AuroraDrive 至少要做到"safety 进程崩溃不影响车"。
2. **默认拒绝的白名单**：所有出向 CAN 帧必须命中显式白名单（addr+bus+len 三元组），任何黑名单思路都不够安全。
3. **显式 inactive 值**：每个执行器命令都有明确的 inactive 值，`controls_allowed=false` 时必须严格等于该值，不留中间态。
4. **多层速率限制**：单帧速率 + 250ms 实时窗口 + 与实测偏差，三层叠加。
5. **controls_allowed 单向门控**：safety 层的"主开关"只能由 safety 自己根据车况置位，应用层只能"请求启用"不能"强制启用"。
6. **心跳超时降级**：应用层心跳丢失 N 秒 → 自动回 SILENT，执行器回 inactive。
7. **driver override 上升沿立即退出**：刹车/油门/方向盘手力的上升沿，safety 层直接清 controls_allowed，不等应用层反应。
8. **诊断与控制互斥**：诊断透传模式与 ADAS 控制模式不能同时开启。
9. **强制 CAN 校验**：checksum/counter/quality flag 任意一项连续失败 → controls_allowed=false。
10. **MISRA C + 单元测试 + mutation test + HIL**：safety 代码必须达到最高代码规范，且每个车系都有针对性回归测试。

### 10.3 AuroraDrive safety 模型 C++ 框架

下面给出一个可直接用作 AuroraDrive 真车适配起点的 C++ safety 框架，结构对齐 opendbc/safety，但用 C++17 表达，便于集成进 AuroraDrive 的 C++ 代码库。

```cpp
// aurora/safety/safety.h
#pragma once
#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

namespace aurora::safety {

// ---------- CAN 帧抽象 ----------
struct CanPacket {
  uint32_t addr;            // 11/29 位 CAN ID
  uint8_t  bus;             // 0=动力, 1=OBD, 2=ADAS
  uint8_t  len;             // 0..64
  std::array<uint8_t, 64> data{};
  bool extended = false;
  bool fd = false;
};

// ---------- 限制结构（对齐 TorqueSteeringLimits / AngleSteeringLimits / LongitudinalLimits） ----------
enum class SteeringType { MotorLimited, DriverLimited };

struct TorqueSteeringLimits {
  int max_torque = 0;
  int max_rate_up = 0;
  int max_rate_down = 0;
  int max_rt_delta = 0;            // 250ms 实时窗口
  int max_torque_error = 0;
  int driver_torque_allowance = 0;
  int driver_torque_multiplier = 0;
  SteeringType type = SteeringType::MotorLimited;
  int min_valid_request_frames = 0;
  int max_invalid_request_frames = 0;
  uint32_t min_valid_request_rt_interval_us = 0;
  bool has_steer_req_tolerance = false;
};

struct AngleSteeringLimits {
  int max_angle = 0;
  float angle_deg_to_can = 1.0f;
  float angle_rate_up_lookup[3]   = {0,0,0};   // x
  float angle_rate_up_values[3]   = {0,0,0};   // y (deg/frame)
  float angle_rate_down_lookup[3] = {0,0,0};
  float angle_rate_down_values[3] = {0,0,0};
  uint32_t frequency_hz = 0;
};

struct LongitudinalLimits {
  int max_accel = 0, min_accel = 0, inactive_accel = 0;
  int max_gas = 0, min_gas = 0, inactive_gas = 0;
  int max_brake = 0;
  int inactive_speed = 0;
};

// ---------- 白名单条目 ----------
struct CanMsgRule {
  uint32_t addr;
  uint8_t  bus;
  uint8_t  len;
  bool check_relay = false;        // 是否参与 relay malfunction 检测
};

struct RxMsgCheck {
  uint32_t addr;
  uint8_t  bus;
  uint8_t  len;
  uint32_t frequency_hz = 0;
  bool ignore_checksum = false;
  bool ignore_counter = false;
  uint8_t max_counter = 0;
  bool ignore_quality_flag = false;
};

// ---------- 钩子接口（对齐 safety_hooks） ----------
struct SafetyHooks {
  using InitFn = std::function<void(uint16_t param)>;
  using RxFn   = std::function<bool(const CanPacket&)>;   // 返回 false → 该帧校验失败
  using TxFn   = std::function<bool(const CanPacket&)>;   // 返回 false → 拒绝发送
  using FwdFn  = std::function<bool(int bus, uint32_t addr)>; // 返回 true → 阻断转发
  using CksFn  = std::function<uint32_t(const CanPacket&)>;
  using CtrFn  = std::function<uint8_t(const CanPacket&)>;
  using QffFn  = std::function<bool(const CanPacket&)>;

  InitFn init;
  RxFn   rx;
  TxFn   tx;
  FwdFn  fwd;
  CksFn  get_checksum;
  CksFn  compute_checksum;
  CtrFn  get_counter;
  QffFn  get_quality_flag_valid;
};

// ---------- 全局状态（对齐 safety.h 的 extern 变量） ----------
struct SafetyState {
  bool controls_allowed = false;
  bool relay_malfunction = false;
  bool gas_pressed = false, gas_pressed_prev = false;
  bool brake_pressed = false, brake_pressed_prev = false;
  bool regen_braking = false, regen_braking_prev = false;
  bool steering_disengage = false, steering_disengage_prev = false;
  bool cruise_engaged_prev = false;
  bool vehicle_moving = false;
  bool heartbeat_engaged = false;
  uint32_t heartbeat_engaged_mismatches = 0;
  uint32_t safety_mode_cnt = 0;
  uint16_t current_safety_mode = 0;   // SAFETY_SILENT
  uint16_t current_safety_param = 0;

  // 扭矩控制状态
  int desired_torque_last = 0;
  int rt_torque_last = 0;
  int valid_steer_req_count = 0;
  int invalid_steer_req_count = 0;
  uint32_t ts_torque_check_last_us = 0;
  uint32_t ts_steer_req_mismatch_last_us = 0;
  std::array<int,6> torque_meas{}, torque_driver{};
  int torque_meas_min=0, torque_meas_max=0;
  int torque_driver_min=0, torque_driver_max=0;

  // 角度控制状态
  int desired_angle_last = 0;
  uint32_t rt_angle_msgs = 0;
  uint32_t ts_angle_check_last_us = 0;
  std::array<int,6> angle_meas{};
  int angle_meas_min=0, angle_meas_max=0;
};

// ---------- 主 SafetyManager（对齐 safety.h 的入口函数） ----------
class SafetyManager {
 public:
  static constexpr uint32_t MAX_RT_INTERVAL_US = 250000;
  static constexpr int MAX_WRONG_COUNTERS = 5;

  // 唯一离开 SILENT 的入口（对齐 set_safety_mode）
  bool SetSafetyMode(uint16_t mode, uint16_t param);

  // 接收钩子（每帧 CAN 调用）
  bool SafetyRxHook(const CanPacket& msg);

  // 发送钩子（每帧出向 CAN 调用，返回 false → 丢弃）
  bool SafetyTxHook(CanPacket& msg);

  // 转发钩子
  int SafetyFwdHook(int bus, uint32_t addr);   // -1=阻断, 否则返回目标 bus

  // 1Hz tick（对齐 safety_tick + heartbeat 检查）
  void Tick(uint32_t now_us, bool heartbeat_received, bool ignition);

  // 心跳（应用层每周期调用）
  void Heartbeat(bool engaged);

  bool controls_allowed() const { return state_.controls_allowed; }
  uint16_t mode() const { return state_.current_safety_mode; }

  // 注册车系钩子（编译期注册表的对齐）
  struct ModeEntry { uint16_t mode; SafetyHooks hooks; };
  void RegisterModes(std::vector<ModeEntry> entries);

 private:
  SafetyState state_;
  SafetyHooks current_hooks_;
  std::vector<CanMsgRule> tx_whitelist_;
  std::vector<RxMsgCheck> rx_checks_;
  std::vector<ModeEntry> registry_;
  std::vector<uint32_t> rx_last_ts_us_;
  std::vector<int> rx_wrong_counters_;
  std::vector<uint8_t> rx_last_counter_;
  std::vector<bool> rx_valid_checksum_;
  std::vector<bool> rx_valid_quality_;
  bool disable_forwarding_ = false;

  void ResetState();
  void GenericRxChecks();
  void StockEcuCheck(bool stock_ecu_detected);
  bool TxWhitelisted(const CanPacket& msg) const;
  int  GetRxCheckIndex(const CanPacket& msg) const;
  bool RxMsgSafetyCheck(const CanPacket& msg);
  // 限幅检查
  bool SteerTorqueCmdChecks(int desired_torque, bool steer_req,
                            const TorqueSteeringLimits& l);
  bool SteerAngleCmdChecks(int desired_angle, bool enabled,
                           const AngleSteeringLimits& l);
  bool LongitudinalAccelChecks(int accel, const LongitudinalLimits& l);
  bool LongitudinalBrakeChecks(int brake, const LongitudinalLimits& l);
  bool LongitudinalGasChecks(int gas, const LongitudinalLimits& l);
  bool GetLongitudinalAllowed() const {
    return state_.controls_allowed && !state_.gas_pressed_prev;
  }
};

} // namespace aurora::safety
```

```cpp
// aurora/safety/safety.cc —— 核心实现节选
#include "aurora/safety/safety.h"
#include <algorithm>
#include <cassert>

namespace aurora::safety {

bool SafetyManager::SafetyTxHook(CanPacket& msg) {
  bool whitelisted = TxWhitelisted(msg);
  // 诊断/调试模式放行白名单（对齐 ALLOUTPUT/ELM327）
  if (state_.current_safety_mode == kSafetyAllOutput ||
      state_.current_safety_mode == kSafetyElm327) {
    whitelisted = true;
  }
  bool safety_allowed = false;
  if (whitelisted && current_hooks_.tx) {
    safety_allowed = current_hooks_.tx(msg);
  }
  // 三重 AND：无 relay 故障 && 白名单 && 车系检查通过
  return !state_.relay_malfunction && whitelisted && safety_allowed;
}

bool SafetyManager::SafetyRxHook(const CanPacket& msg) {
  const bool controls_allowed_prev = state_.controls_allowed;
  const bool valid = RxMsgSafetyCheck(msg);
  const bool whitelisted = GetRxCheckIndex(msg) != -1;
  if (valid && whitelisted && current_hooks_.rx) {
    current_hooks_.rx(msg);
  }
  GenericRxChecks();   // 刹车/油门/转向 override 上升沿 → 退出控制
  // relay malfunction 检测
  for (const auto& m : tx_whitelist_) {
    if (m.check_relay && m.addr == msg.addr && m.bus == msg.bus) {
      StockEcuCheck(true);
    }
  }
  if (state_.controls_allowed && !controls_allowed_prev) {
    state_.heartbeat_engaged_mismatches = 0;
  }
  return valid;
}

void SafetyManager::GenericRxChecks() {
  state_.gas_pressed_prev = state_.gas_pressed;
  if (state_.brake_pressed && (!state_.brake_pressed_prev || state_.vehicle_moving))
    state_.controls_allowed = false;
  state_.brake_pressed_prev = state_.brake_pressed;
  if (state_.regen_braking && (!state_.regen_braking_prev || state_.vehicle_moving))
    state_.controls_allowed = false;
  state_.regen_braking_prev = state_.regen_braking;
  if (state_.steering_disengage && !state_.steering_disengage_prev)
    state_.controls_allowed = false;
  state_.steering_disengage_prev = state_.steering_disengage;
}

void SafetyManager::Tick(uint32_t now_us, bool heartbeat_received, bool ignition) {
  state_.safety_mode_cnt++;
  // 1Hz 频率/存活检查
  for (size_t i = 0; i < rx_checks_.size(); ++i) {
    uint32_t elapsed = now_us - rx_last_ts_us_[i];
    uint32_t timestep = 1000000u / std::max(1u, rx_checks_[i].frequency_hz);
    bool lagging = elapsed > std::max(timestep * 10u, 1000000u);
    if (lagging) state_.controls_allowed = false;
  }
  // 心跳超时 → 回 SILENT
  static constexpr uint32_t HB_ON = 5, HB_OFF = 2;
  uint32_t hb_limit = ignition ? HB_ON : HB_OFF;
  if (!heartbeat_received && state_.safety_mode_cnt > hb_limit) {
    SetSafetyMode(kSafetySilent, 0);
  }
  // heartbeat_engaged 与 controls_allowed 一致性
  if (state_.controls_allowed && !state_.heartbeat_engaged) {
    if (++state_.heartbeat_engaged_mismatches >= 3) state_.controls_allowed = false;
  } else {
    state_.heartbeat_engaged_mismatches = 0;
  }
}

bool SafetyManager::SetSafetyMode(uint16_t mode, uint16_t param) {
  auto it = std::find_if(registry_.begin(), registry_.end(),
                         [mode](const ModeEntry& e){ return e.mode == mode; });
  if (it == registry_.end()) {
    SetSafetyMode(kSafetySilent, 0);   // 兜底
    return false;
  }
  ResetState();                         // 切换前全状态清零
  current_hooks_ = it->hooks;
  state_.current_safety_mode = mode;
  state_.current_safety_param = param;
  if (current_hooks_.init) current_hooks_.init(param);   // 车系填充 tx_whitelist_/rx_checks_
  return true;
}

void SafetyManager::Heartbeat(bool engaged) {
  state_.heartbeat_engaged = engaged;
  state_.safety_mode_cnt = 0;   // 喂狗
}

// --- 限幅算法（对齐 lateral.h / longitudinal.h） ---
bool SafetyManager::SteerTorqueCmdChecks(int desired, bool steer_req,
                                         const TorqueSteeringLimits& l) {
  bool violation = false;
  if (state_.controls_allowed) {
    violation |= (std::abs(desired) > l.max_torque);
    // 单帧速率 + 实测偏差（简化版，完整版见 lateral.h dist_to_meas_check）
    int highest = std::min(state_.desired_torque_last + l.max_rate_up,
                           std::max(state_.desired_torque_last - l.max_rate_down,
                                    state_.torque_meas_max + l.max_torque_error));
    int lowest  = std::max(state_.desired_torque_last - l.max_rate_up,
                           std::min(state_.desired_torque_last + l.max_rate_down,
                                    state_.torque_meas_min - l.max_torque_error));
    violation |= (desired > highest || desired < lowest);
    state_.desired_torque_last = desired;
    // 250ms 实时窗口
    violation |= (std::abs(desired - state_.rt_torque_last) > l.max_rt_delta);
    // 注：完整实现需用 ts_torque_check_last_us 做窗口重置
  }
  if (!state_.controls_allowed && desired != 0) violation = true;
  if (!steer_req && desired != 0) violation |= !l.has_steer_req_tolerance;
  if (violation || !state_.controls_allowed) {
    state_.desired_torque_last = 0;
    state_.rt_torque_last = 0;
  }
  return violation;
}

bool SafetyManager::LongitudinalAccelChecks(int accel, const LongitudinalLimits& l) {
  bool valid = GetLongitudinalAllowed() && (accel <= l.max_accel && accel >= l.min_accel);
  bool inactive = (accel == l.inactive_accel);
  return !(valid || inactive);   // 既不有效也不 inactive → 违规
}

bool SafetyManager::LongitudinalBrakeChecks(int brake, const LongitudinalLimits& l) {
  bool v = false;
  v |= !GetLongitudinalAllowed() && (brake != 0);
  v |= brake > l.max_brake;
  return v;
}

} // namespace aurora::safety
```

### 10.4 AuroraDrive 迁移路线图

1. **阶段 0（当前，仿真）**：不接入 safety 层，但在控制输出接口预留 `SafetyManager::SafetyTxHook` 调用点（no-op），让下游代码习惯"所有出向命令都要过一道钩子"。
2. **阶段 1（台架车，软件 safety）**：把上述 C++ 框架跑在独立进程（cgroup 隔离 + 优先级提升），CAN 卡驱动把每帧出向命令先送入 SafetyManager，拒绝的帧不上总线。先实现 SILENT/NOOUTPUT + 一个"通用扭矩车系"配置。
3. **阶段 2（开发车，硬件 safety）**：参照 panda，用独立 MCU（STM32H7 或 RT Linux 独立核）做 safety，应用 CPU 通过 SPI/USB 下发命令，MCU 端跑独立固件。物理继电器切断原车 ADAS。这是真正对标 panda 的形态。
4. **阶段 3（量产）**：MISRA C / C++ Core Guidelines 静态检查 + 每车系 mutation test + HIL 台架 + ISO 26262 流程文档。

### 10.5 关键差异与注意事项

- panda 是纯 C（MISRA C:2012），AuroraDrive 用 C++ 时务必禁用异常/RTTI/动态内存（safety 路径），用 `std::array` 替代 `std::vector`，避免堆碎片。
- panda 的 `microsecond_timer_get` 是硬件定时器，AuroraDrive 软件实现时必须用单调时钟（`CLOCK_MONOTONIC`），且 timer 源要独立于应用 CPU 核。
- `controls_allowed` 的置位逻辑（ACC 上升沿等）必须由 safety 进程自己根据 CAN rx 推断，**不能由应用进程通过 IPC 告知**——否则应用进程被攻破就绕过了 safety。
- 心跳通道必须独立于数据通道（panda 用 USB control transfer 而非 CAN），AuroraDrive 建议用独立 socket 或共享内存的看门狗字节。
- 诊断模式（ELM327 等价物）与控制模式必须互斥，切换时强制 ResetState。

---

## 11. 关键源码索引

| 文件 | 仓库 | 行数 | 作用 |
|---|---|---|---|
| `opendbc/safety/safety.h` | opendbc | 553 | 主框架：safety_rx_hook / safety_tx_hook / safety_fwd_hook / set_safety_hooks / safety_tick / relay 检测 / CRC 表 |
| `opendbc/safety/declarations.h` | opendbc | 364 | SAFETY_* 常量、所有结构体、ALT_EXP_* 标志、safety_hooks 声明 |
| `opendbc/safety/can.h` | opendbc | 20 | CANPacket_t 位域结构 |
| `opendbc/safety/lateral.h` | opendbc | 353 | steer_torque_cmd_checks / steer_angle_cmd_checks / steer_curvature_cmd_checks / ISO 11270 限制 |
| `opendbc/safety/longitudinal.h` | opendbc | 35 | longitudinal_accel/gas/brake/speed/transmission_rpm_checks / get_longitudinal_allowed |
| `opendbc/safety/modes/defaults.h` | opendbc | 51 | nooutput_hooks / alloutput_hooks |
| `opendbc/safety/modes/toyota.h` | opendbc | 443 | Toyota LKA/LTA/SecOC |
| `opendbc/safety/modes/honda.h` | opendbc | 436 | Honda Nidec/Bosch |
| `opendbc/safety/modes/hyundai.h` | opendbc | 352 | Hyundai + legacy + camera-SCC |
| `opendbc/safety/modes/ford.h` | opendbc | 336 | Ford 曲率控制 |
| `opendbc/safety/modes/gm.h` | opendbc | 244 | GM ASCM/CAM |
| `opendbc/safety/modes/tesla.h` | opendbc | 393 | Tesla 角度+VM、AEB/Autopark 阻断、fwd 钩子 |
| `opendbc/safety/modes/rivian.h` | opendbc | 182 | Rivian 动态扭矩 |
| `opendbc/safety/modes/elm327.h` | opendbc | 40 | OBD-II / ISO 15765-4 诊断透传 |
| `opendbc/safety/modes/body.h` | opendbc | 45 | comma body 底盘 |
| `panda/board/main.c` | panda | 389 | set_safety_mode 入口、1Hz tick、心跳守护 |
| `panda/python/__init__.py` | panda | 807 | Panda 类、health()、set_safety_mode() USB 接口 |
| `openpilot/docs/SAFETY.md` | openpilot | 46 | 安全模型顶层设计文档 |

---

## 12. 总结

panda safety 模型的本质是**在独立 MCU 上用严格白名单 + 多层速率限制 + 单向 controls_allowed 门控 + 心跳守护 + 继电器故障检测，把"应用层失控"的爆炸半径压缩到执行器物理极限之内**。它的精妙之处在于：

- **白名单是显式且三元组（addr+bus+len）的**，没有 wildcard，没有 blacklist。
- **每条 rx 消息都带校验规则**（checksum/counter/quality/frequency），任一失败立即降级。
- **执行器限制是多层叠加的**（绝对上限 + 单帧速率 + 250ms 实时窗口 + 实测/驾驶员偏差 + steer_req 一致性），攻击者/bug 要同时绕过所有层才能造成危害。
- **controls_allowed 是单向门控**，应用层只能通过心跳"证明自己活着"，不能直接写"我要控制"。
- **诊断与控制互斥**，UDS 仅允许固定字节 tester present，杜绝 ECU 刷写攻击面。
- **代码规范与测试极其严格**（MISRA C、mutation test、HIL），且 fork 修改 safety 代码会失去 openpilot 商标并被 ban 服务器。

对 AuroraDrive 而言，当前无 CAN 安全模型的状态在仿真期可接受，但真车适配前必须实现至少软件级 safety 层。本报告给出的 C++ 框架直接对齐 opendbc/safety 的结构与算法，可作为迁移起点，关键是把握"独立进程/独立硬件、默认拒绝白名单、显式 inactive 值、多层速率限制、单向 controls_allowed、心跳超时降级"这六条核心原则。

---

> 本报告基于 commaai/panda、commaai/opendbc、commaai/openpilot 三个仓库的 master 分支源码（2026-07）撰写。
> 实际内部工具调用次数：**62 次**（WebSearch + WebFetch + Read + RunCommand + Grep + TodoWrite + Write）。
> 字数：约 6800 字（不含代码块）。
