# comma.ai OpenPilot panda 硬件深度研究报告

> 研究对象：comma.ai 出品的 panda 系列 CAN 总线接口硬件
> 仓库地址：https://github.com/commaai/panda
> 研究日期：2026-07-23
> 本报告基于 GitHub 仓库源码、comma.ai 官方商店页面、openpilot/opendbc 安全文档以及多份技术解析资料整理而成。

---

## 摘要

panda 是 comma.ai 设计的"史上最优雅的通用汽车接口"（the nicest universal car interfaces ever）。它是一台插在汽车 OBD-II 诊断口（或通过专用 car harness 接入车辆 CAN 总线）上的小型 MCU 设备，承担两个核心职责：第一，作为 CAN / CAN-FD 总线与上层计算平台（comma 3X / comma four / PC）之间的桥梁，把车辆 ECU 的报文透传上来、把控制指令下发给车辆；第二，作为一道"硬件安全门（safety gatekeeper）"，在固件层强制执行车辆相关的安全策略，即便上层 openpilot 软件崩溃或行为异常，panda 也能让车辆回到原始可控状态。

panda 当前主控芯片为 STMicroelectronics 的 STM32 系列（早期 STM32F205、中期 STM32F413、当前主力 STM32H725）。它在板级代码（`board/`）中遵循 MISRA C:2012 规范，并通过 cppcheck 静态分析、HITL（硬件在环）测试、变异测试（mutation test）等多重手段保证代码严谨性，因为 panda 固件直接关系到行车安全。

本报告将依次剖析：panda 仓库结构、硬件版本演进、主控芯片选型、CAN 总线架构、其它外设接口、电源管理、安全特性、固件与升级机制、与 comma 3X / comma four 的集成关系，最后面向 AuroraDrive（基于 Mac 开发 / 树莓派部署的自动驾驶系统）给出借鉴 panda 设计的硬件方案建议。

---

## 1. panda 仓库结构

panda 仓库（github.com/commaai/panda）是一个 MIT 许可证的开源项目，截至本次研究已拥有约 3004 次提交、21 个分支。代码语言构成为 **C 语言 96.1% / Python 3.1% / 其它 0.8%**——可见 panda 本质上是一个嵌入式 C 固件项目，Python 仅作为上位机交互库与测试脚本。

仓库根目录结构如下（来自官方 README）：

```
.
├── board/        # 运行在 STM32 上的固件代码（核心）
├── drivers/      # 上位机驱动（Linux udev 规则等，Python 使用时非必需）
├── python/       # 与 panda 交互的 Python 用户态库
├── tests/        # panda 测试套件（含 MISRA 覆盖表、HITL 测试）
├── scripts/      # 开发与调试用的杂项脚本
└── examples/     # 在真实车辆上使用 panda 的示例脚本
```

### 1.1 board/（板级固件）

`board/` 目录是 panda 的心脏，承载运行在 STM32 上的全部 C 代码。其 README 给出关键操作：

- `./flash.py` —— 烧录应用程序（app）
- `./recover.py` —— 烧录 bootstub（引导存根，相当于 bootloader）
- `tests/debug_console.py` —— 打印 STM32 串口控制台用于调试

故障排查逻辑体现了 panda 的双段启动设计：若 panda 无法烧录且绿灯常亮，用 `recover.py`（刷 bootstub）；若绿灯快闪，用 `flash.py`（刷 app）；若 LED 全灭且 `lsusb` 看不到设备，则需要借助 **panda paw**（comma.ai 出售的专用工具）强制进入 DFU 模式；对于 comma 3X / comma four 这类内置 panda 的设备，还可运行 `../scripts/reflash_internal_panda.py` 重刷内部 panda。

### 1.2 python/（上位机库）

`python/` 提供 `Panda` 类，封装了 USB 通信、CAN 收发、安全模式设置等接口。典型用法：

```python
>>> from panda import Panda
>>> panda = Panda()
>>> panda.can_recv()                       # 接收 CAN 报文

>>> from opendbc.car.structs import CarParams
>>> panda.set_safety_mode(CarParams.SafetyModel.allOutput)
>>> panda.can_send(0x1aa, b'message', 0)   # 在 bus 0 上发送一帧
```

注意发送前必须显式设置安全模式（`set_safety_mode`），否则 panda 默认处于 SILENT（只听不发）状态，这是安全设计的一部分。

### 1.3 tests/（测试与代码严谨性）

panda 的 `board/` 代码因承担安全关键功能，被施加了极高标准的代码严谨性约束（Code Rigor）：

1. **静态分析**：cppcheck 通用分析 + MISRA C:2012 专项插件（见 `tests/misra/coverage_table`）。
2. **严格编译选项**：`-Wall -Wextra -Wstrict-prototypes -Werror`。
3. **安全逻辑单测**：opendbc 中每种车型安全模型都有单元测试，确保行为不漂移。
4. **HITL 硬件在环测试**：覆盖所有活跃 panda 变体，包括安全模型检查、bootstub/app 编译烧录、所有总线上的 CAN 收发与转发、USB 与 SPI 上的 CAN 回环及延迟测试。
5. **变异测试**：对 MISRA 覆盖和安全逻辑分别做 mutation test，确保测试本身有效。
6. **Python 侧**：ruff linter + mypy 类型检查。

这套测试体系本身就是 panda 安全性的重要组成——它不是"写完测一下"，而是把测试和变异测试嵌入 CI，形成对抗式验证。

### 1.4 drivers/（驱动）

主要为 Linux 提供 udev 规则，使普通用户也能访问 panda USB 设备。panda 的 USB VID/PID 组合包括 `0483:df11`（STM32 DFU 模式）、`3801:ddcc`/`3801:ddee`（comma 官方 VID）、`bbaa:ddcc`/`bbaa:ddee`（内部 panda/兼容设备）。panda jungle（测试夹具）使用不同的 udev 规则。

---

## 2. panda 硬件版本

panda 经历了多代演进，外壳颜色（白 / 黑 / 红）是区分版本的直观标识。comma.ai 商店当前在售价格为 **$99**，提供红、黑、白三色（白色已从 openpilot 中废弃）。

### 2.1 版本总览

| 版本 | 主控 MCU | CAN 总线 | CAN-FD | 其它接口 | GPS | 典型用途 | 状态 |
|------|----------|----------|--------|----------|-----|----------|------|
| **white panda**（白熊猫） | STM32F205 | 3× CAN | ❌ | 2× LIN、1× GMLAN、USB-A、Wi-Fi（软件已弃用） | ❌ | 早期 comma two / EON | 已从 openpilot 废弃 |
| **gray panda**（灰熊猫） | STM32F205 | 3× CAN | ❌ | 同白 panda + 高精度 GPS | ✅（外置 GPS） | 早期需要 GPS 的车型 | 已停产 |
| **black panda**（黑熊猫） | STM32F413 | 3× CAN | ❌ | USB-C | ❌ | comma 3 / 3X 主流方案，非 CAN-FD 车型 | 主力在售 |
| **red panda**（红熊猫） | STM32H725 | 3× CAN + 1× 多路复用 | ✅（全部总线） | USB-C | ❌（无 GPS） | comma 3 上跑 CAN-FD 车型 | 主力在售 |
| **internal panda**（内置 panda） | STM32H725 | 3× CAN + 1× 多路复用 | ✅（comma four） | SPI/内部总线 | 依赖主机 | 集成于 comma 3X / comma four | 当前标配 |

### 2.2 white panda（已废弃）

白熊猫是 panda 最早期的量产形态，采用 STM32F205。它提供 3 路 CAN、2 路 LIN、1 路 GMLAN（通用汽车专用单线 CAN）、USB-A 接口，并带有 Wi-Fi 硬件（但 Wi-Fi 软件支持已被官方废弃）。白熊猫现已从 openpilot 支持列表中移除。

### 2.3 gray panda（灰熊猫，已停产）

灰熊猫在白熊猫基础上增加了高精度外置 GPS 模块（社区资料提及 NEO-M8U 级别），用于早期需要 GPS 辅助定位的车型方案。国内改装资料中常将其与"白熊猫（Wi-Fi 版）"并列推荐灰熊猫为首选。

### 2.4 black panda（黑熊猫，主力）

黑熊猫是 comma 3 / 3X 时代的主流外置 panda，主控升级为 **STM32F413**，接口改为 USB-C，提供 3 路 CAN，但不支持 CAN-FD。对于绝大多数传统 CAN 车型（2008 年以后的非 CAN-FD 车辆），黑熊猫 + comma 3X 是标准组合。

### 2.5 red panda（红熊猫，当前旗舰）

红熊猫被官方称为"panda 技术的未来"。核心升级是主控换为 **STM32H725**：

- CPU 性能比旧款快 **4 倍**（Cortex-M7 @ 550MHz vs 旧款 Cortex-M4）；
- 在**全部 3 路 CAN 总线 + 1 路多路复用总线**上支持 CAN-FD。

关键约束：
- **红熊猫不带 GPS**——需要 GPS 的方案不能选红熊猫；
- **不兼容 comma two**；
- **comma 3 在 CAN-FD 车型上必须配红熊猫**（需查 openpilot 的 `docs/CARS.md` 兼容性表确认车型是否要求红熊猫）；
- **comma four 不需要红熊猫**（comma four 内置 panda 已支持 CAN-FD）。

### 2.6 internal panda（内置 panda）

comma 3X 与 comma four 内部都集成了一颗 panda（基于 STM32H725），通过内部总线（comma 3X 早期经 USB，comma 3X/4 主流经 SPI）与主 SoC 通信。内置 panda 不占用外部接口，简化了整机走线。comma four 的内置 panda 已原生支持 CAN-FD，因此**购买 comma four 的用户完全不需要再买外置 panda**。当内置 panda 出现固件异常时，可运行 `scripts/reflash_internal_panda.py` 进行重刷。

### 2.7 panda paw（调试工具）

panda paw 是 comma.ai 出售的专用硬件工具，用于在 panda 完全失联（LED 灭、lsusb 不可见）时强制将 STM32 拉入 DFU 模式，从而完成底层恢复烧录。它是 panda 开发者与售后维修的"最后一道防线"。

### 2.8 关于"panda C3 / C4"的说明

需要澄清一个常见误区：comma 生态中 **C3 / C4 通常指 comma 3 / comma four 主机（计算平台）**，而非 panda 本身的型号。panda 自身按颜色（白/黑/红）与是否内置来区分版本。所谓"panda C3"在社区语境里多指"comma 3 配套的 panda 方案"（comma 3 内置 panda + 可选外置红 panda），"panda C4"则指"comma four 内置 panda"。本报告为避免歧义，统一使用 panda 颜色版本 + 主机型号的组合表述。

---

## 3. 主控芯片

### 3.1 演进路线：STM32F205 → STM32F413 → STM32H725

panda 始终采用 STMicroelectronics 的 STM32 系列单片机，从未使用 ESP32。MCU 演进路线如下：

- **STM32F205**（早期白/灰 panda）：Cortex-M3 内核，主频 120MHz，是 panda 第一代主控。
- **STM32F413**（黑 panda）：Cortex-M4 内核，主频 100MHz，带 FPU，性能与外设较 F205 提升，是 comma 3 时代的主力。
- **STM32H725**（红 panda / 内置 panda）：Cortex-M7 内核，**主频 550MHz**，双精度 FPU，是当前 panda 的主控。

### 3.2 STM32H725 关键规格

STM32H725 是 panda 红版与内置 panda 的核心，其主要参数（来自 ST 官方规格书与 114ic 等渠道）：

| 参数 | 规格 |
|------|------|
| 内核 | ARM Cortex-M7 32-bit |
| 主频 | 最高 550 MHz |
| Flash | 最高 1 MB |
| SRAM | 564 KB |
| CAN | **3× FD-CAN**（硬件原生支持 CAN-FD） |
| 以太网 | MAC（支持 Ethernet） |
| USB | USB OTG |
| ADC | 2× 16-bit ADC |
| 其它 | QSPI、SAI、I2C、SPI、LIN、SDIO、图形加速等 |
| 工作温度 | 最高 125 °C（车规料号） |

最关键的一点是 STM32H725 **片内集成 3 路 FD-CAN 控制器**，这正是红 panda 能在"全部 3 条总线 + 1 条多路复用总线"上支持 CAN-FD 的硬件基础——3 条由片内 FDCAN 直接驱动，第 4 条通过多路复用器（multiplexer）切换接入。

### 3.3 关于"双 MCU / 冗余设计"的澄清

任务描述中提到"双 MCU 设计 / 冗余设计 / ESP32"，但根据对 panda 仓库与官方资料的考证，**panda 本身是单 MCU 设计（一颗 STM32）**，并未采用双 MCU 硬件冗余，也未使用 ESP32。

panda 体系里真正的"双处理器"结构出现在整机层面：**应用 SoC（comma 3X/4 的高通骁龙 845）+ 安全 MCU（panda 的 STM32H725）**。这是一种"功能隔离"而非"硬件冗余"的设计哲学：

- SoC 负责跑 openpilot（感知、规划、神经网络推理），属于"非安全关键"的高性能计算域；
- STM32 panda 负责车辆总线接入与安全策略强制执行，属于"安全关键"的实时控制域；
- 两者通过 USB/SPI 通信，但 panda 的安全逻辑独立于 SoC——即使 SoC 死机，panda 仍会按车型安全模型限制或切断控制输出，使车辆回归驾驶员可控状态。

这种"高性能 SoC + 独立安全 MCU"的隔离架构，比简单的双 MCU 冗余更适合 L2 辅助驾驶场景，也是 panda 设计的精髓所在。AuroraDrive 借鉴时应抓住这一点。

---

## 4. CAN 总线架构

CAN 总线是 panda 的核心使命。panda 提供多条独立 CAN 总线，以适配现代汽车中"多网段隔离"的现实（动力 CAN、底盘 CAN、车身 CAN、诊断 CAN 往往物理隔离）。

### 4.1 三路 CAN + 一路多路复用

panda 标配 **3 路独立 CAN（CAN0 / CAN1 / CAN2）**，外加 **1 路多路复用（multiplexed）总线**。在红 panda 与内置 panda 上，这 4 路全部支持 CAN-FD；在白/黑 panda 上仅支持经典 CAN 2.0。

- **CAN0（bus 0）**：通常接车辆主 CAN（动力/底盘总线，转向、油门、刹车相关 ECU）；
- **CAN1（bus 1）**：通常接辅助 CAN（如雷达、ADAS 模块）；
- **CAN2（bus 2）**：通常接车身/诊断 CAN；
- **多路复用总线**：通过模拟开关在多路信号（如 GMLAN 单线 CAN、第 4 路 CAN 等）间切换，用于兼容通用等需要 GMLAN 的车型。

### 4.2 CAN 总线规格表

| 项目 | 经典 CAN（白/黑 panda） | CAN-FD（红 panda / 内置 panda） |
|------|--------------------------|----------------------------------|
| 协议标准 | ISO 11898-1（CAN 2.0A/B） | ISO 11898-1:2015（CAN-FD） |
| 仲裁段速率 | 最高 1 Mbit/s | 最高 1 Mbit/s |
| 数据段速率 | —（无） | 最高 5–8 Mbit/s（典型 2–5 Mbit/s） |
| 单帧数据长度 | 最多 8 字节 | 最多 64 字节 |
| 总线数量 | 3× CAN（+1 多路复用，部分含 GMLAN/LIN） | 3× CAN-FD + 1× 多路复用 CAN-FD |
| CAN 控制器 | STM32 内置 bxCAN | STM32H725 内置 3× FDCAN |
| CAN 收发器 | 外置 PHY（TJA1044 级别） | 外置 CAN-FD 收发器 |
| 终端电阻 | 120Ω（板载可选/可配置） | 120Ω（板载可选/可配置） |
| 典型车辆网段 | 动力 CAN 500kbps / 车身 CAN 100kbps | 现代车型高速 CAN-FD 总线 |

> 说明：汽车 CAN 总线常见双速结构——驱动系统高速 CAN（500 kb/s，连接发动机 ECU、ABS/ASR）与车身系统低速 CAN（100 kb/s）。panda 的多路设计正是为了同时挂接这些不同速率、不同网段的总线。

### 4.3 CAN 收发器与终端电阻

STM32 的 CAN 控制器输出的是数字逻辑电平（CTX/CRX），需要外置 **CAN 收发器（transceiver）** 转换为差分电平（CANH/CANL）才能上总线。panda 板载多颗 CAN 收发器（业内常见型号如 TJA1044、SN65HVD23x 等）。每条 CAN 总线两端理论上需要 120Ω 终端电阻以抑制信号反射，panda 在板上提供可配置的终端电阻，便于用户根据实际线缆拓扑启用/禁用。

### 4.4 CAN 报文收发与转发

panda 支持在任意总线之间**转发（forward）** CAN 报文——这是 car harness 方案的关键能力：例如把原车 ACC 雷达的报文从 bus 1 转发到 bus 0，让 openpilot "伪装"成雷达介入控制。HITL 测试明确覆盖"所有总线上的接收、发送、转发"。

---

## 5. 其它接口

### 5.1 USB

USB 是外置 panda 与上位机通信的主通道。

- 白 panda：USB-A；
- 黑/红 panda：**USB-C**；
- comma 3X / comma four：OBD-C 端口（USB-C 形态但复用 CAN 信号），comma four 另有 USB 3.1 Gen 2 端口。

panda 的 USB VID/PID 已在前文 udev 规则中列出。Linux 下需配置 udev 规则才能以普通用户访问。

### 5.2 Ethernet（以太网）

STM32H725 片内集成以太网 MAC，理论上具备以太网能力。comma 生态中以太网主要用于高带宽场景（如 comma 主机与 panda 间的高速数据通路备选），但当前 panda 与主机的常态通信仍以 USB/SPI 为主。以太网为 panda 硬件预留了扩展空间。

### 5.3 GPS

GPS 是 panda 版本差异的重要分水岭：

- 白/灰 panda 时代：灰 panda 内置高精度 GPS；
- 红 panda：**明确不带 GPS**（官方商店页面声明）；
- comma 3X / comma four：GPS 集成在主机侧（comma four 标称 High-precision GPS），而非 panda 上。

因此现代方案中 GPS 由主机承担，panda 专注总线接入。

### 5.4 IMU

IMU（惯性测量单元）同样位于**主机侧**而非 panda 上。comma four 标称集成 3D 加速度计 + 3D 陀螺仪。panda 本身不承载 IMU。社区资料中早期灰 panda 方案涉及 LSM6DS3 级别 6 轴 IMU，但现代架构已将 IMU 上移到主机。

### 5.5 OBD-II 与 car harness

panda 通过 **car harness（线束）** 接入车辆。comma 商店为 325+ 车型提供专用 harness（如 Honda Bosch A/B/C、Hyundai K/P/C 等）。harness 一端接 panda 的 OBD-C/USB-C，另一端串接在车辆 ACC 摄像头或 OBD-II 口上，把目标 CAN 总线引到 panda。所有 comma 设备共用同一套 harness，升级 comma four 无需更换线束。

---

## 6. 电源管理

### 6.1 电源输入

panda 从车辆 12V 电源取电（经 OBD-II 的 16 号针脚常电 + 4/5 号地，或经 harness 接钥匙电源）。车载电压名义 12V，实际波动范围约 6–18V（启停、冷启动时可能跌落）。

### 6.2 电源输出与稳压

panda 板载 DC-DC 稳压器，将车载 12V 降压为 5V（USB 供电给主机）与 3.3V（STM32 及外设逻辑供电）。comma 3X/4 主机也通过 panda/线束取电。

### 6.3 点火检测（ignition sense）

panda 监测点火信号（ignition）以判断车辆上电状态，进而决定 openpilot 是否启动/休眠。comma four 强调"wakes up when you engage, hibernates when you disengage"，即基于点火与 engage 状态做电源状态机管理。

### 6.4 备用电源与功耗

panda 本身无大容量备用电池；comma 主机内置电池用于熄火后短暂维持系统（写盘、关机）。整车静态功耗需控制以避免耗尽电瓶——comma 通过"熄火休眠 + 点火唤醒"的状态机将静态电流压到很低。OBD 检测仪类设备典型功耗 ≤1W，panda 同量级，长期停车不致亏电。

---

## 7. 安全特性

安全是 panda 存在的最大理由。panda 的安全体系分多层。

### 7.1 安全模型（Safety Model）

panda 固件编译时链接 **opendbc** 提供的车型专属安全逻辑（`opendbc/safety/safety/`）。每个支持车型对应一个 safety model，定义：

- **允许接收/转发的 CAN 报文 ID 与速率**；
- **允许下发的控制报文（转向、油门、刹车）及其边界**；
- **controls_allowed 标志**：只有当上层明确置位且满足车型约束时，panda 才放行控制报文；
- **心跳（heartbeat）**：上层必须周期性喂心跳，超时则 panda 自动切断控制。

### 7.2 安全模式（SafetyMode）

panda 默认启动进入 **SILENT**（静默/只听不发声）模式，确保上电瞬间不会误发控制报文。常见模式包括：

- `SILENT`：只接收，不发送任何 CAN（默认）；
- `NOOUTPUT`：可收但不允许控制输出；
- `ALLOUTPUT`：完全放开（仅用于开发调试，绝不在真车上用）；
- 各车型专属 safety model（如 Honda、Toyota、Hyundai 等）。

设置安全模式必须显式调用 `set_safety_mode()`，这是"fail-safe 默认安全"原则的体现。

### 7.3 硬件 watchdog（看门狗）

STM32 内置 **IWDG（独立看门狗）**，由独立低速时钟（LSI，约 30–60kHz）驱动，主时钟故障时仍可工作。panda 固件启用 IWDG，若固件死循环/卡死未能周期性喂狗，硬件自动复位 MCU，避免控制输出失控。

### 7.4 失效模式（failsafe）

openpilot 官方安全文档（SAFETY.md）明确两条顶层安全要求：

1. **驾驶员必须随时能立即夺回控制**——踩刹车或按取消键即可；
2. **车辆轨迹变化不能过快**——执行器在合理限值内动作（参照 ISO11270 与 ISO15622，横向约 0.9 秒最大执行达成 1m 横向偏离的限值）。

panda 在硬件/固件层强制这些限值：即使 openpilot 发出超限指令，panda 也会丢弃或钳位；心跳丢失立即切断 controls_allowed。openpilot 整体遵循 ISO26262 指南与 MISRA C:2012，panda `board/` 代码即为安全关键代码域。comma 明确禁止 fork 禁用/弱化驾驶员监控与过度执行检查，违反者将被封禁服务器访问。

### 7.5 安全开关与 panda paw

panda 没有传统"物理安全继电器串联在 CAN 总线上"的设计（CAN 总线本身是广播式，无法像电源那样物理切断）。panda 的"安全开关"体现在固件层的安全模型 + watchdog + 心跳超时三重软件门，以及 panda paw 这类硬件维护工具。这是一种"软件定义安全 + 硬件复位兜底"的方案。

---

## 8. 固件与升级

### 8.1 固件结构：bootstub + app

panda 固件采用双段式：

- **bootstub（引导存根）**：相当于 bootloader，负责硬件初始化与 app 校验/加载，由 `recover.py` 烧录；
- **app（应用）**：panda 主业务逻辑（CAN 收发、安全模型、USB 协议），由 `flash.py` 烧录。

这种分离使 app 升级失败时仍可用 bootstub 恢复。

### 8.2 升级方式

- **常规 USB 烧录**：`flash.py` / `recover.py`，配合 STM32 的内置 USB DFU（VID `0483:df11`）；
- **DFU 强制模式**：设备失联时用 panda paw 拉低 BOOT0 进入 DFU；
- **内部 panda**：`scripts/reflash_internal_panda.py`，专为 comma 3X/4 内置 panda 设计；
- **OTA（在线升级）**：openpilot 在系统升级流程中会一并更新 panda 固件，保证 panda 安全模型与 openpilot 车型适配同步。

### 8.3 编译与测试

```bash
git clone https://github.com/commaai/panda.git
cd panda
./setup.sh      # 配置环境（pip 安装 libusb 等）
./test.sh       # 编译固件 + 跑测试
```

CI 在 GitHub Actions 上跑全部测试，包括 MISRA、HITL、变异测试。

---

## 9. 与 comma 3X / comma four 的集成

### 9.1 comma 3X

comma 3X 是 comma 3 的小幅迭代主力机型，主控为 **Qualcomm Snapdragon 845**（与 comma four 同款 SoC 系列），带 OLED 屏、双摄（广角 + 窄角长焦）、3D 加速度计/陀螺仪、高精度 GPS、LTE/Wi-Fi、IR 夜视。comma 3X **内置 panda**（STM32H725），经内部总线与 SoC 通信。

关键约束：comma 3X 的内置 panda 若不支持 CAN-FD，则在 CAN-FD 车型上**必须外接红 panda**（红 panda 的 STM32H725 提供 CAN-FD）。用户需查 `docs/CARS.md` 确认车型是否要求红 panda。

### 9.2 comma four

comma four 是当前最新一代主机，售价 $899–999，主打"comma 3X 同等算力/传感器，但体积仅 1/5"。核心规格：

| 项目 | comma four 规格 |
|------|-----------------|
| 处理器 | Qualcomm Snapdragon 845 MAX（强散热，持续峰值） |
| 摄像头 | 双摄 360° 视野 + 窄角长焦 |
| 传感器 | 3D 加速度计、3D 陀螺仪、高精度 GPS、麦克风 |
| CAN-FD | **原生支持，无需额外硬件**（内置 panda 已含 CAN-FD） |
| 存储 | 128GB 内置（约 10 小时录像） |
| 连接 | LTE + Wi-Fi |
| 夜视 | IR LED 内部夜视 |
| 显示 | 1.9" 300 PPI OLED |
| 端口 | OBD-C（USB-C 带 CAN）、USB 3.1 Gen 2 |
| 兼容 | 325+ 车型，沿用同款 car harness |

**comma four 内置 panda 已支持 CAN-FD，因此用户完全不需要再购买外置 panda**——这是 comma four 相对 comma 3X 的重要简化。comma four 出厂不预装可控制车辆的软件，需用户自行安装 openpilot。

### 9.3 内置 panda 的连接方式

comma 3X 早期经 USB 连接内置 panda，后逐步转向 **SPI**（更低的延迟与更稳定的总线占用）。HITL 测试明确包含"通过 USB 与 SPI 的 CAN 回环及延迟测试"。comma four 沿用 SPI 内连。这种 SoC↔SPI↔STM32 的内部链路是整机安全架构的主动脉。

### 9.4 整机数据流

```
[车辆 ECU] ⇄ CAN/CAN-FD ⇄ [panda STM32H725 (安全门)] ⇄ SPI/USB ⇄ [comma 3X/4 SoC (openpilot)]
                                       ↑
                            opendbc 车型安全模型（固件内强制）
```

感知/规划在 SoC 跑，控制指令经 panda 安全模型校验后下发车辆；车辆报文经 panda 透传/转发上 SoC。panda 是唯一与车辆总线物理接触且具备安全否决权的一环。

---

## 10. AuroraDrive 硬件方案建议

### 10.1 AuroraDrive 现状

AuroraDrive 当前为开发态（Mac）+ 部署态（树莓派）的架构，目前无真车硬件接入层。若未来要支持真车，必须补齐"安全的车载总线接入"这一环。panda 的设计是现成的最佳参考样板。

### 10.2 借鉴 panda 的 CAN 总线设计

建议 AuroraDrive 的车载网关采用：

1. **多路独立 CAN 隔离**：至少 3 路独立 CAN（动力/底盘/车身），物理隔离不同网段，避免单总线故障波及全车。选 MCU 时优先选片内集成 **3× FDCAN** 的型号（如 STM32H725/H723），省外置控制器。
2. **CAN-FD 前瞻**：即使初期只接经典 CAN 车型，也直接上 CAN-FD 收发器与 FDCAN MCU，兼容未来车型，避免换板。
3. **可配置终端电阻**：每路 CAN 板载 120Ω 终端电阻并设跳线/开关，适配不同线束拓扑。
4. **多路复用扩展**：为 GMLAN/LIN 等特殊总线预留一路多路复用通道。

### 10.3 借鉴 panda 的安全特性

AuroraDrive 真车方案必须复刻 panda 的安全门思想：

1. **独立安全 MCU**：绝不把车辆总线直接接到树莓派/Mac 这类非实时、非安全关键的 SoC 上。必须加一颗车规 MCU（STM32H7 级别）作为唯一车辆总线入口与安全否决点。
2. **SoC + 安全 MCU 隔离架构**：树莓派（或未来车规 SoC）跑感知规划，安全 MCU 跑车型安全模型，二者经 SPI/USB 通信。SoC 崩溃时 MCU 自动切断控制——这正是 panda 的精髓，比双 MCU 冗余更适合 L2。
3. **默认 SILENT + 心跳 + controls_allowed**：安全 MCU 上电默认只听不发；上层必须周期喂心跳并显式置 controls_allowed 才允许控制输出；超时立即切断。
4. **硬件 IWDG 看门狗**：启用 STM32 独立看门狗，固件卡死自动复位。
5. **执行器限值**：参照 ISO11270/ISO15622，在安全 MCU 固件层硬限制横向/纵向执行速率与幅度。
6. **代码严谨性**：安全 MCU 固件遵循 MISRA C:2012，加 cppcheck、HITL、变异测试 CI。
7. **驾驶员夺回通道**：确保踩刹车/按取消键能绕过软件直接恢复原车控制（panda 通过转发原车报文实现，AuroraDrive 需在 harness 层保留原车信号通路）。

### 10.4 AuroraDrive 推荐硬件方案（若未来支持真车）

| 层级 | 推荐选型 | 角色 |
|------|----------|------|
| 安全 MCU 网关 | STM32H725（或 H723） + 3× CAN-FD 收发器 + 可选 GMLAN 多路复用 | 唯一车辆总线入口，强制安全模型，IWDG 看门狗，默认 SILENT |
| 上层计算 | 树莓派 5（部署）/ Mac（开发），未来可升级车规 SoC | 跑 AuroraDrive 感知规划，经 SPI/USB 与安全 MCU 通信 |
| 车辆接入 | 定制 car harness（OBD-II / ACC 摄像头串接） | 引出目标 CAN 总线到安全 MCU，保留原车夺回通路 |
| 调试 | ST-Link + DFU + 串口 console | 仿 panda 的 flash/recover/debug 工作流 |
| 电源 | 车 12V → DC-DC 5V/3.3V，点火检测 | 仿 panda 电源状态机，熄火休眠 |

### 10.5 与 panda 的差异

- AuroraDrive 不必照搬 panda 的"外置 USB-C 形态"——可直接把安全 MCU 集成到树莓派扩展板（HAT）上，缩短 SPI 走线；
- 但必须保留 panda 的"安全 MCU 独立否决权"——这是不可妥协的安全底线；
- 初期可考虑直接复用 comma panda 硬件（红 panda + 树莓派）做原型验证，降低自研风险，待方案稳定后再自研车规网关板。

### 10.6 渐进式路线建议

1. **Phase 1（原型）**：红 panda + 树莓派，跑通 CAN 读写与安全模型，验证车型接入；
2. **Phase 2（自研网关）**：基于 STM32H725 自研安全 MCU 板，移植 opendbc 安全模型思路，接入 AuroraDrive；
3. **Phase 3（车规化）**：换车规料号 MCU，做 ISO26262 流程对标，HITL 测试体系成型。

---

## 11. 结论

panda 是 comma.ai openpilot 体系中"小而精"的安全基石。它以一颗 STM32（演进至 H725 / Cortex-M7 @ 550MHz）承担车辆总线接入与安全策略强制执行，与高性能 SoC（骁龙 845）形成"算力域 + 安全域"的功能隔离架构。红 panda 凭借 STM32H725 的 3× FDCAN 实现全总线 CAN-FD 支持；comma four 进一步将 panda 内置并原生支持 CAN-FD，使整机方案大幅简化。

panda 的工程价值不仅在于硬件本身，更在于其安全方法论：默认 SILENT、心跳超时切断、controls_allowed 门控、车型专属安全模型、IWDG 硬件看门狗、MISRA C:2012 + HITL + 变异测试的代码严谨性体系。这些是任何想上真车的自动驾驶项目（包括 AuroraDrive）都应当直接借鉴的"安全基线"。

对 AuroraDrive 而言，最关键的迁移启示是：**永远不要让非实时的应用 SoC 直连车辆总线，必须经由独立安全 MCU 网关**。这条原则比"用哪款 MCU"更重要，是 panda 留给开源自动驾驶社区最宝贵的设计遗产。

---

## 参考资料

- panda 仓库：https://github.com/commaai/panda
- panda board README：https://github.com/commaai/panda/blob/master/board/README.md
- comma.ai 商店 panda：https://comma.ai/shop/products/panda
- comma.ai 商店 comma four：https://comma.ai/shop/comma-four
- openpilot SAFETY.md：https://github.com/commaai/openpilot/blob/master/docs/SAFETY.md
- opendbc safety：https://github.com/commaai/opendbc/tree/master/opendbc/safety
- STM32H725 规格书（ST 官方 RM0468）
- CSDN / 社区多份 comma.ai 与 STM32 技术解析资料

---

> **本报告工具调用统计**：本次研究共执行约 56 次内部工具调用（WebSearch + WebFetch + Read），涵盖 panda 仓库结构、硬件版本、主控芯片、CAN 总线、接口、电源、安全、固件、comma 3X/4 集成与 AuroraDrive 方案等十大主题。
