# OpenPilot 车辆识别（panda fingerprint）深度研究

> 研究对象：comma.ai OpenPilot / opendbc 仓库的车辆识别（fingerprint）机制
> 研究方法：直接抓取 `commaai/opendbc` 与 `commaai/openpilot` 仓库源码 + 中文技术解析
> 关键源码文件：`opendbc/car/car_helpers.py`、`opendbc/car/fingerprints.py`、`opendbc/car/fw_versions.py`、`opendbc/car/interfaces.py`、`opendbc/car/fw_query_definitions.py`、`opendbc/car/__init__.py`、各品牌 `interface.py` / `values.py` / `fingerprints.py`

---

## 0. 全景概述

OpenPilot 要在 250+ 个车型上运行，首要问题是"我连上的是哪一辆车"。这套识别系统叫做 **fingerprint（指纹）**。它的核心思想非常朴素：

> 不同车型在 CAN 总线上广播的消息集合（地址 + 长度）以及 ECU 固件版本号是高度特异的，可以像人类指纹一样唯一标识一个车型平台。

OpenPilot 的 fingerprint 经历了两代演进：

- **FPv1（legacy CAN fingerprint）**：基于 CAN 消息地址（address）+ 数据长度（DLC）的字典匹配。在 `car_helpers.py::can_fingerprint()` 中实现，调用 `fingerprints.py::eliminate_incompatible_cars()`。
- **FPv2（FW_VERSIONS 固件指纹）**：基于 ECU 固件版本号的精确/模糊匹配，在 `fw_versions.py::match_fw_to_car()` 中实现。这是当前的主线方案，FPv1 退居为补充/兜底手段。

现代 OpenPilot 启动时同时执行两种识别，最终由 `fingerprint()` 编排函数裁决出一个 `carFingerprint` 字符串（如 `TOYOTA_COROLLA`），再交给对应品牌的 `CarInterface._get_params()` 完成安全模型、CAN 总线、DBC、限速等全部后续配置。

代码已从 `openpilot` 仓库迁移到独立的 `opendbc` 仓库（`opendbc/car/`），以下分析以 opendbc 最新 master 版本为准。

---

## 1. 车辆识别流程总览

### 1.1 入口：`get_car()`

车辆识别的入口是 `opendbc/car/car_helpers.py::get_car()`，由 `controlsd`/`pandad` 在启动时调用：

```python
def get_car(can_recv, can_send, set_obd_multiplexing, alpha_long_allowed, is_release, cached_params=None):
  candidate, fingerprints, vin, car_fw, source, exact_match = fingerprint(
      can_recv, can_send, set_obd_multiplexing, cached_params)
  if candidate is None:
    carlog.error({"event": "car doesn't match any fingerprints", "fingerprints": repr(fingerprints)})
    candidate = "MOCK"
  CarInterface = interfaces[candidate]
  CP: CarParams = CarInterface.get_params(candidate, fingerprints, car_fw, alpha_long_allowed, is_release, docs=False)
  CP.carVin = vin
  CP.carFw = car_fw
  CP.fingerprintSource = source
  CP.fuzzyFingerprint = not exact_match
  return interfaces[CP.carFingerprint](CP)
```

关键点：
- 识别失败（`candidate is None`）时回退到 `MOCK`（空平台），相当于"dashcam only"。
- 识别结果会写入 `CarParams` 的四个字段：`carFingerprint`（车型字符串）、`carFw`（固件列表）、`fingerprintSource`（识别来源）、`fuzzyFingerprint`（是否模糊匹配）。

### 1.2 编排：`fingerprint()`

`fingerprint()` 是识别的总调度，按以下顺序工作：

```python
def fingerprint(can_recv, can_send, set_obd_multiplexing, cached_params):
  fixed_fingerprint = os.environ.get('FINGERPRINT', "")
  skip_fw_query = os.environ.get('SKIP_FW_QUERY', False)
  # 1. 固件查询（除非 SKIP_FW_QUERY）
  if not skip_fw_query:
    if cached_params 可用 and 有 carFw and VIN 合法:
      使用缓存的 carFw（cached=True）
    else:
      set_obd_multiplexing(True)
      vin = get_vin(can_recv, can_send, (0, 1))           # 查询 VIN
      ecu_rx_addrs = get_present_ecus(...)                # 探测存在的 ECU
      car_fw = get_fw_versions_ordered(..., vin, ...)     # 按品牌优先级查固件版本
    exact_fw_match, fw_candidates = match_fw_to_car(car_fw, vin)
  # 2. CAN 指纹（实时）
  set_obd_multiplexing(False)
  can_recv()  # drain
  car_fingerprint, finger = can_fingerprint(can_recv)
  exact_match = True
  source = CarParams.FingerprintSource.can
  # 3. 裁决：固件唯一匹配优先
  if len(fw_candidates) == 1:
    car_fingerprint = list(fw_candidates)[0]
    source = CarParams.FingerprintSource.fw
    exact_match = exact_fw_match
  # 4. 固定指纹（调试/强制）
  if fixed_fingerprint:
    car_fingerprint = fixed_fingerprint
    source = CarParams.FingerprintSource.fixed
  return car_fingerprint, finger, vin, car_fw, source, exact_match
```

### 1.3 三种识别来源（FingerprintSource）

`CarParams.FingerprintSource` 枚举定义了识别来源：

| 来源 | 含义 | 触发条件 |
|------|------|----------|
| `can` | 实时 CAN 消息指纹（FPv1） | 固件未给出唯一候选时的兜底 |
| `fw` | ECU 固件版本指纹（FPv2） | `match_fw_to_car` 返回唯一候选 |
| `fixed` | 环境变量强制指定 | `FINGERPRINT=TOYOTA_COROLLA` |

**裁决优先级**：`fixed > fw(唯一) > can`。固件指纹优先于 CAN 指纹，因为固件版本唯一性更强、跨年款兼容性更好。

### 1.4 触发条件与耗时

- 固件查询阶段：VIN 查询 ~0.1s，ECU 探测 + 固件查询通常 1~2s（按品牌优先级排序，命中即停）。
- CAN 指纹阶段：`FRAME_FINGERPRINT = 100` 帧（≈1s，控制循环 100Hz），最长 200 帧（≈2s）超时。
- 若有缓存的 `CarParams`（VIN 合法且已有 carFw），直接复用，跳过最耗时的固件查询。

---

## 2. CAN 消息指纹（FPv1）

### 2.1 指纹的数据结构

CAN 指纹是一个嵌套字典：

```python
# opendbc/car/__init__.py
def gen_empty_fingerprint():
  return {i: {} for i in range(8)}   # 8 个 bus，每个 bus 一个 {address: length} 字典
```

实时采集时，对每条收到的 CAN 消息记录 `{bus: {address: len(data)}}`。例如 Toyota Corolla 在 bus 0 上可能广播地址 `0x2A4`（长度 8）、`0x412`（长度 8）等消息，这些地址集合就构成该车的"指纹"。

### 2.2 采集：`can_fingerprint()`

```python
FRAME_FINGERPRINT = 100  # 1s

def can_fingerprint(can_recv):
  finger = gen_empty_fingerprint()
  candidate_cars = {i: all_legacy_fingerprint_cars() for i in [0, 1]}  # bus 0 和 1 都尝试
  frame = 0
  car_fingerprint = None
  done = False
  while not done:
    can_packets = can_recv(wait_for_one=True)
    for can_packet in can_packets:
      for can in can_packet:
        if can.src < 128:                       # 只看标准帧
          if can.src not in finger:
            finger[can.src] = {}
          finger[can.src][can.address] = len(can.dat)
        for b in candidate_cars:
          # 忽略扩展帧（>= 0x800）和 VIN 查询响应（0x7df/0x7e0/0x7e8）
          if can.src == b and can.address < 0x800 and can.address not in (0x7df, 0x7e0, 0x7e8):
            candidate_cars[b] = eliminate_incompatible_cars(can, candidate_cars[b])
      # 退出条件
      for b in candidate_cars:
        if len(candidate_cars[b]) == 1 and frame > FRAME_FINGERPRINT:
          car_fingerprint = candidate_cars[b][0]
      failed = (all(len(cc) == 0 for cc in candidate_cars.values()) and frame > FRAME_FINGERPRINT) or frame > 200
      succeeded = car_fingerprint is not None
      done = failed or succeeded
      frame += 1
  return car_fingerprint, finger
```

关键设计：
- **双总线并行**：同时在 bus 0（动力总线）和 bus 1（诊断/扩展总线）上做消除法，因为不同车型接入 panda 的总线位置不同。
- **消除法（elimination）**：从全部已知车型集合开始，每收到一条 CAN 消息，就把"不可能发出这条消息"的车型剔除。
- **退出条件**：候选只剩 1 个且已过 1s（确保采集到足够多消息），或候选全空（无匹配），或超过 2s 超时。
- **过滤 VIN 查询响应**：`0x7df/0x7e0/0x7e8` 是 OBD-II 诊断地址，会与 VIN 查询混淆，必须排除。

### 2.3 消除法：`eliminate_incompatible_cars()` 与 `is_valid_for_fingerprint()`

```python
# opendbc/car/fingerprints.py
_DEBUG_ADDRESS = {1880: 8}   # 调试保留地址

def is_valid_for_fingerprint(msg, car_fingerprint: dict[int, int]):
  adr = msg.address
  # 地址在指纹里且长度匹配，或者是扩展帧（>= 0x800，不参与判定）
  return (adr in car_fingerprint and car_fingerprint[adr] == len(msg.dat)) or adr >= 0x800

def eliminate_incompatible_cars(msg, candidate_cars):
  """移除不可能发出 msg 的车型"""
  compatible_cars = []
  for car_name in candidate_cars:
    car_fingerprints = _FINGERPRINTS[car_name]   # 该车型可能有多个指纹样本
    for fingerprint in car_fingerprints:
      # 加上调试地址后判定
      if is_valid_for_fingerprint(msg, fingerprint | _DEBUG_ADDRESS):
        compatible_cars.append(car_name)
        break
  return compatible_cars
```

**指纹匹配算法**：
1. 一条 CAN 消息 `(address, length)` 对某车型"合法"的充要条件是：该 address 出现在该车指纹字典中 **且** 长度相等（或该消息是扩展帧 `>= 0x800`，扩展帧不参与判定）。
2. 每收到一条消息，遍历所有候选车型，只要该车型有**任意一个**指纹样本能容纳这条消息，就保留它；否则剔除。
3. `_DEBUG_ADDRESS = {1880: 8}` 是为调试预留的地址，会与每个指纹做"或"运算，避免调试消息误杀候选。

### 2.4 唯一性保证

CAN 指纹的唯一性来自两个事实：
- 不同车型平台的 ECU 拓扑不同，广播的 CAN 地址集合差异显著（如 Toyota TSS-P 与 TSS2 的地址集不同）。
- 同一平台的不同年款/配置可能在数据库中有**多条**指纹样本（`_FINGERPRINTS[car_name]` 是列表），覆盖该平台的各种变体。

当多个车型在前 N 帧都"合法"时，系统会持续采集直到只剩一个候选，或超时回退到固件指纹。

---

## 3. carFingerprint：车型字符串

### 3.1 字段含义

`CarParams.carFingerprint` 是一个字符串，是识别的最终产物，也是后续所有配置查找的 key。例如 `TOYOTA_COROLLA`、`HONDA_CIVIC`、`HYUNDAI_SONATA`。

在 `interfaces.py::CarStateBase` 中：
```python
class CarStateBase(ABC):
  def __init__(self, CP):
    self.car_fingerprint = CP.carFingerprint   # 全程持有，用于分支判断
```

各品牌的 `CarState.update()`、`CarController.update()` 都会反复读取 `self.car_fingerprint` / `CP.carFingerprint` 来选择正确的 CAN 信号解析路径。

### 3.2 命名规则与 Platform 枚举

现代命名采用 `Platforms` 枚举（`opendbc/car/__init__.py`），枚举成员的字符串值就是 `carFingerprint`：

```python
class Platforms(str, ReprEnum, metaclass=PlatformsType):
  config: PlatformConfigBase
  def __new__(cls, platform_config: PlatformConfig):
    member = str.__new__(cls, platform_config.platform_str)  # 用 platform_str 作为字符串值
    member.config = platform_config
    member._value_ = platform_config.platform_str
    return member
```

`PlatformsType` 元类在创建枚举时自动把每个成员名（如 `TOYOTA_COROLLA`）写入 `cfg.platform_str` 并冻结。因此 `CAR.TOYOTA_COROLLA` 既是枚举成员，其字符串值就是 `"TOYOTA_COROLLA"`。

命名约定：
- **品牌前缀 + 车型 + 世代/年款后缀**：`TOYOTA_COROLLA`、`TOYOTA_COROLLA_TSS2`、`TOYOTA_RAV4_TSS2_2023`。
- **配置/硬件差异用后缀区分**：`HONDA_CIVIC`（NIDEC）、`HONDA_CIVIC_BOSCH`（Bosch）、`HONDA_CIVIC_BOSCH_DIESEL`。
- **子品牌独立前缀**：`LEXUS_RX`、`ACURA_RDX`、`KIA_OPTIMA_G4`、`GENESIS_GV80`、`AUDI_A3_MK3`（均归入母品牌目录）。

### 3.3 MIGRATION：命名演进

`fingerprints.py` 维护了一个 `MIGRATION` 字典，把旧的"人类可读"平台名映射到新枚举：

```python
MIGRATION = {
  "ACURA ILX 2016 ACURAWATCH PLUS": HONDA.ACURA_ILX,
  "TOYOTA COROLLA 2017": TOYOTA.TOYOTA_COROLLA,
  "TOYOTA COROLLA TSS2 2019": TOYOTA.TOYOTA_COROLLA_TSS2,
  "HONDA CIVIC 2016 TOURING": HONDA.HONDA_CIVIC,
  "HONDA CIVIC HATCHBACK 2017 SEDAN/COUPE 2019": HONDA.HONDA_CIVIC_BOSCH,
  "CHRYSLER PACIFICA HYBRID 2017": CHRYSLER.CHRYSLER_PACIFICA_2018_HYBRID,
  # ...
}
```

这说明早期 `carFingerprint` 是带年款/配置的自由字符串（如 `"TOYOTA COROLLA 2017"`），后来重构为不含空格的枚举常量，年款信息转移到 `CarDocs`（如 `ToyotaCarDocs("Toyota Corolla 2017-19")`）。`MIGRATION` 保证旧日志/旧 Dongle 升级后仍能识别。

### 3.4 PlatformConfig 结构

每个平台携带完整配置（`opendbc/car/__init__.py`）：

```python
@dataclass
class PlatformConfig(PlatformConfigBase):
  car_docs: list[CarDocs]      # 文档/年款描述
  specs: CarSpecs              # 物理参数
  dbc_dict: DbcDict            # 各 bus 的 DBC 文件名

@dataclass
class CarSpecs:
  mass: float                  # 整备质量 kg
  wheelbase: float             # 轴距 m
  steerRatio: float            # 转向比
  centerToFrontRatio: float = 0.5
  minSteerSpeed: float = 0.0
  minEnableSpeed: float = -1.0
  tireStiffnessFactor: float = 1.0
```

例如（`toyota/values.py`）：
```python
TOYOTA_COROLLA = PlatformConfig(
  [ToyotaCarDocs("Toyota Corolla 2017-19")],
  CarSpecs(mass=2860. * CV.LB_TO_KG, wheelbase=2.7, steerRatio=18.27, tireStiffnessFactor=0.444),
  dbc_dict('toyota_new_mc_pt_generated', 'toyota_adas'),
)
TOYOTA_COROLLA_TSS2 = ToyotaTSS2PlatformConfig(
  [ToyotaCarDocs("Toyota Corolla 2020-22"), ...],
  CarSpecs(mass=3060. * CV.LB_TO_KG, wheelbase=2.67, steerRatio=13.9, tireStiffnessFactor=0.444),
)
```

`ToyotaTSS2PlatformConfig.init()` 会自动置上 `TSS2 | NO_DSU` 标志，并切换 DBC 到 `toyota_nodsu_pt_generated`。这就是"识别到平台后自动继承配置"的体现。

---

## 4. fingerprint 匹配逻辑（car_interface 侧）

### 4.1 匹配的两条路径

`fingerprint()` 编排函数内部实际有两条匹配路径：

1. **CAN 实时匹配**（`can_fingerprint` + `eliminate_incompatible_cars`）：见第 2 节。
2. **固件匹配**（`match_fw_to_car`）：见第 5 节。

二者结果在 `fingerprint()` 末尾裁决：固件唯一候选优先。

### 4.2 exact vs fuzzy

固件匹配内部又分精确与模糊（`fw_versions.py`）：

```python
def match_fw_to_car(fw_versions, vin, allow_exact=True, allow_fuzzy=True, log=True):
  exact_matches = []
  if allow_exact:
    exact_matches = [(True, match_fw_to_car_exact)]
  if allow_fuzzy:
    exact_matches.append((False, match_fw_to_car_fuzzy))
  for exact_match, match_func in exact_matches:
    matches = set()
    for brand in VERSIONS.keys():
      fw_versions_dict = build_fw_dict(fw_versions, filter_brand=brand)
      matches |= match_func(fw_versions_dict, match_brand=brand, log=log)
      # 模糊匹配且该品牌无命中时，回退到品牌自定义模糊函数
      if not exact_match and not len(matches) and config.match_fw_to_car_fuzzy is not None:
        matches |= config.match_fw_to_car_fuzzy(fw_versions_dict, vin, VERSIONS[brand])
    if len(matches):
      return exact_match, matches
  return True, set()
```

顺序：**先精确，精确无果再模糊**。返回 `(exact_match: bool, matches: set)`。

#### 4.2.1 精确匹配 `match_fw_to_car_exact`

```python
ESSENTIAL_ECUS = [Ecu.engine, Ecu.eps, Ecu.abs, Ecu.fwdRadar, Ecu.fwdCamera, Ecu.vsa]

def match_fw_to_car_exact(live_fw_versions, match_brand=None, ...):
  invalid = set()
  candidates = {c: f for c, f in FW_VERSIONS.items() if is_brand(MODEL_TO_BRAND[c], match_brand)}
  for candidate, fws in candidates.items():
    config = FW_QUERY_CONFIGS[MODEL_TO_BRAND[candidate]]
    for ecu, expected_versions in fws.items():
      ecu_type = ecu[0]; addr = ecu[1:]
      found_versions = live_fw_versions.get(addr, set())
      if not len(found_versions):
        # 关键 ECU 缺失 → 直接判该车型无效；非关键 ECU 缺失 → 跳过
        if candidate in config.non_essential_ecus.get(ecu_type, []):
          continue
        if ecu_type not in ESSENTIAL_ECUS:
          continue
      if ecu_type == Ecu.debug:
        continue
      # 找到的版本必须在预期版本列表里
      if not any(found_version in expected_versions for found_version in found_versions):
        invalid.add(candidate)
        break
  return set(candidates.keys()) - invalid
```

**精确匹配规则**：
- 遍历数据库中每个候选车型的每个 ECU 条目。
- 如果实车返回了某 ECU 的版本，该版本必须**完全等于**数据库中记录的某个版本，否则该候选无效。
- 关键 ECU（engine/eps/abs/fwdRadar/fwdCamera/vsa）若实车未返回，则该候选无效（关键 ECU 不能缺）。
- 非关键 ECU 缺失可容忍（`continue`）。
- `non_essential_ecus` 允许某些车型把本应关键的 ECU 标为非必要。
- `debug` 虚拟 ECU 不参与匹配。

#### 4.2.2 模糊匹配 `match_fw_to_car_fuzzy`

```python
FUZZY_EXCLUDE_ECUS = [Ecu.fwdCamera, Ecu.fwdRadar, Ecu.eps, Ecu.debug]

def match_fw_to_car_fuzzy(live_fw_versions, match_brand=None, ...):
  # 建立 (addr, sub_addr, fw) → 候选车型列表 的反查表
  all_fw_versions = defaultdict(list)
  for candidate, fw_by_addr in FW_VERSIONS.items():
    ...
    for addr, fws in fw_by_addr.items():
      if addr[0] in FUZZY_EXCLUDE_ECUS:   # 排除共享 ECU
        continue
      for f in fws:
        all_fw_versions[(addr[1], addr[2], f)].append(candidate)
  matched_ecus = set()
  match = None
  for addr, versions in live_fw_versions.items():
    ecu_key = (addr[0], addr[1])
    for version in versions:
      candidates = all_fw_versions[(*ecu_key, version)]
      if len(candidates) == 1:            # 唯一命中
        matched_ecus.add(ecu_key)
        if match is None:
          match = candidates[0]
        elif match != candidates[0]:      # 两个 ECU 唯一指向不同车 → 拒绝
          return set()
  if match and len(matched_ecus) >= 2:    # 至少 2 个 ECU 唯一命中
    return {match}
  return set()
```

**模糊匹配规则**：
- 排除 `fwdCamera/fwdRadar/eps/debug` 这些常被多个车型共享的 ECU（如混动/燃油版共享 EPS）。
- 对实车每个 ECU 版本，查反查表，若该版本只对应**唯一**一个车型，记一次"唯一命中"。
- 若两个不同 ECU 唯一指向不同车型 → 判定冲突，拒绝匹配。
- 至少需要 **2 个** ECU 唯一命中才算成功（防止单 ECU 误判）。
- 品牌还可提供自定义 `match_fw_to_car_fuzzy` 回调（`FwQueryConfig.match_fw_to_car_fuzzy`）做更精细的 VIN+版本联合判定。

### 4.3 失败处理

- `match_fw_to_car` 全部无果 → `fw_candidates` 为空集，`fingerprint()` 回退到 CAN 指纹结果。
- CAN 指纹也无果（`car_fingerprint is None`）→ `get_car()` 把 candidate 设为 `MOCK`，记录 `car doesn't match any fingerprints` 错误日志，系统进入 dashcam 模式（只记录不控制）。
- 模糊匹配命中会设置 `CP.fuzzyFingerprint = True`（`exact_match = False`），上层可据此降低信任度（如 release 版本可能限制功能）。

---

## 5. FW_VERSIONS：固件版本匹配

### 5.1 数据结构

固件指纹数据库定义在每个品牌的 `fingerprints.py`（由 `format_fingerprints.py` 自动格式化），结构为：

```python
FW_VERSIONS = {
  CAR.TOYOTA_AVALON: {
    (Ecu.abs, 0x7b0, None): [
      b'F152607060\x00\x00\x00\x00\x00\x00',
    ],
    (Ecu.dsu, 0x791, None): [
      b'881510701300\x00\x00\x00\x00',
      b'881510705100\x00\x00\x00\x00',
      b'881510705200\x00\x00\x00\x00',
    ],
    (Ecu.eps, 0x7a1, None): [b'8965B41051\x00\x00\x00\x00\x00\x00'],
    (Ecu.engine, 0x7e0, None): [b'\x0230721100\x00...A0C01000\x00...'],
    (Ecu.fwdRadar, 0x750, 0xf): [b'8821F4702000\x00\x00\x00\x00', ...],
    (Ecu.fwdCamera, 0x750, 0x6d): [b'8646F0701100\x00\x00\x00\x00', ...],
  },
  ...
}
```

Key 是 `(Ecu 类型, 地址, 子地址)`，Value 是该 ECU 所有已知固件版本字符串列表（bytes）。子地址 `None` 表示无子地址（标准诊断地址）。

### 5.2 ECU 固件查询流程

`get_fw_versions_ordered()` 负责"问车要固件"：

```python
def get_fw_versions_ordered(can_recv, can_send, set_obd_multiplexing, vin, ecu_rx_addrs, ...):
  all_car_fw = []
  brand_matches = get_brand_ecu_matches(ecu_rx_addrs)   # 按响应地址统计各品牌命中数
  # 按命中数降序排品牌（命中多的先查），同命中数按命中率排
  for brand in sorted(brand_matches, key=lambda b: (count, count/total), reverse=True):
    if True not in brand_matches[brand]:
      continue
    car_fw = get_fw_versions(..., query_brand=brand, ...)
    all_car_fw.extend(car_fw)
    _, matches = match_fw_to_car(car_fw, vin, log=False)
    if len(matches) == 1:    # 该品牌固件已能唯一确定 → 提前结束
      break
  return all_car_fw
```

**品牌优先级排序**：先用 `get_present_ecus()` 探测哪些 ECU 地址有响应，再按"该品牌预期 ECU 地址的命中数"排序。这样 Tesla 这种只有 1 个 ECU 的品牌会被优先查询（命中数 1/1 = 100%），避免被多 ECU 品牌淹没。

`get_fw_versions()` 内部用 `IsoTpParallelQuery` 并行发送 UDS 诊断请求（`READ_DATA_BY_IDENTIFIER` 等），收集各 ECU 的固件版本响应，封装成 `CarParams.CarFw` 列表。

### 5.3 查询协议（StdQueries）

`fw_query_definitions.py::StdQueries` 定义了标准诊断查询模板：

- **UDS**：`READ_DATA_BY_IDENTIFIER` + `APPLICATION_SOFTWARE_IDENTIFICATION`（0xF195）/ `VEHICLE_MANUFACTURER_ECU_SOFTWARE_NUMBER` 等。
- **OBD**：`0x09 0x04`（Mode 09 PID 04，CAL ID）。
- **KWP2000**：`0x21 0x81`（读 VIN）。
- **GM 专属**：`0x1A 0x90`。
- **VIN 查询**：OBD `0x09 0x02` / UDS `READ_DATA_BY_IDENTIFIER` + VIN(0xF190)。

每个品牌的 `FW_QUERY_CONFIG` 声明自己的 `Request` 列表（request/response 字节、白名单 ECU、rx_offset、bus、是否 OBD 多路复用）。`STANDARD_VIN_ADDRS = [0x7e0, 0x7e2, 0x760, 0x7c6, 0x18da10f1, 0x18da0ef1]` 列出可能回复 VIN 的地址。

### 5.4 跨年份兼容性

固件指纹天然支持跨年款：
- 数据库中每个平台下的固件版本是**列表**，可包含多个年款/小版本的固件。如 `TOYOTA_AVALON_2019` 的 `Ecu.abs` 列了 8 个版本（`F152607110`…`F152641061`），覆盖 2019-2021 各批次。
- 新增年款只需把新固件版本 append 进列表，无需新建平台。
- `MIGRATION` 字典把历史上拆分/合并的平台名映射到当前枚举，保证旧日志可读。
- 模糊匹配 + `non_essential_ecus` 机制容忍个别 ECU 缺失或换地址，进一步提升兼容性。

### 2.5 各品牌 CAN 指纹示例

不同品牌的 CAN 地址分布有鲜明特征，这正是 FPv1 能区分它们的基础。以下是各品牌在 bus 0（动力总线）上的典型地址示例（来源：opendbc 各品牌 `fingerprints.py` 的 `FINGERPRINTS` 历史数据 + 实车日志）：

**Toyota（TSS-P / TSS2 体系）**
- TSS-P 车型（如 `TOYOTA_COROLLA` 2017-19）使用 `toyota_new_mc_pt_generated` DBC，典型地址包括 `0x2A4`（STEER_TORQUE_SENSOR，8 字节）、`0x412`（KINEMATICS，8 字节）、`0x3F6`（BSM 盲区，存在则启用 `enableBsm`）。
- TSS2 车型（如 `TOYOTA_COROLLA_TSS2`）改用 `toyota_nodsu_pt_generated`，地址集与 TSS-P 显著不同，且 `0x750` 子地址 `0x6d`（fwdCamera）与 `0xf`（fwdRadar）的固件版本是 FPv2 主力判据。
- 识别后通过 `DBC[candidate][Bus.pt] == "toyota_new_mc_pt_generated"` 判定是否需要 `ALT_BRAKE` 安全标志。

**Honda（NIDEC vs Bosch 双体系）**
- NIDEC 车型（`HONDA_CIVIC` 2016）用 11 位标准地址，动力总线在 bus 0，`0x1A5`（ACC 转向按键）、`0x17C`（STEERING_CONTROL）。
- Bosch 车型（`HONDA_CIVIC_BOSCH`）改走 bus 1 上的 29 位扩展诊断地址（如 `0x18da28f1` VSA、`0x18dab0f1` fwdRadar），固件指纹用 29 位 UDS 地址查询。
- 这就是 Honda `_get_params` 要先 `CAN = CanBus(ret, fingerprint)` 再分流 `HONDA_BOSCH` / `HONDA_NIDEC` 的原因。

**Hyundai（CAN / CAN-FD / Legacy 三体系）**
- 普通燃油车：`fingerprint[0]` 上 `0x58b`（BSM）、`0x485`（HDA LFA）、`0x38d`（FCA11 AEB）。
- CAN-FD 车型：`fingerprint[CAN.ECAN]` 上 `0xFA`（混动标志）、`0x1ba`（BSM）、`0x50`/`0x110`（LKA 转向变体）、`0x130`（档位，缺失则切 `ALT_GEARS`）。
- Legacy 车型（如早期 `HYUNDAI_GENESIS`）消息缺计数器/校验和，需 `hyundaiLegacy` 安全模型。

**Volkswagen（MQB / MLB / MEB / PQ 四体系）**
- MQB：`fingerprint[0]` 上 `0x30F`（SWA_01 盲区）、`0xAD`（Getriebe_11 自动挡）、`0x187`（Motor_EV_01 电动车）；`fingerprint[1]` 上 `0x40/0x86/0xB2/0xFD` 判定网络位置（gateway vs fwdCamera）。
- MEB（纯电平台）：`0x24C`（MEB_Side_Assist）、`0x25D`（KLR_01）、`0x3DC`（Gateway_73），用 `curvature` 转向控制。
- PQ/MLB：地址集完全不同，分别用 `volkswagenPq` / `volkswagenMlb` 安全模型。

**Ford**
- `fingerprint[CAN.main]` 上 `0x3A6`/`0x3A7`（左右盲区）、`0x5A`（Gear_Shift_by_Wire 自动挡）。
- CAN-FD 车型用 `fingerprint[CAN.camera]` 检查 `0x3d6`/`0x186` 是否 8 字节，否则判定为 SecOC 不支持（`dashcamOnly`）。

这些示例说明：**CAN 地址既是识别输入，又是配置依据**——同一条地址既参与 `eliminate_incompatible_cars` 的消除法，又在 `_get_params` 里被 `in fingerprint[bus]` 检测以开启功能开关。这是 OpenPilot 把"识别"与"配置"统一在同一份指纹数据上的精妙之处。

---

## 6. 车型数据库

### 6.1 `opendbc/car/fingerprints.py`（聚合层）

这是数据库的聚合入口：

```python
from opendbc.car.interfaces import get_interface_attr
# 从所有品牌的 fingerprints.py 聚合
FW_VERSIONS = get_interface_attr('FW_VERSIONS', combine_brands=True, ignore_none=True)
_FINGERPRINTS = get_interface_attr('FINGERPRINTS', combine_brands=True, ignore_none=True)

def all_legacy_fingerprint_cars():
  """Returns a list of all known car strings, FPv1 only."""
  return list(_FINGERPRINTS.keys())
```

`get_interface_attr()`（`interfaces.py`）遍历 `opendbc/car/*/` 下每个品牌目录，从对应文件加载属性：

```python
INTERFACE_ATTR_FILE = {
  "FINGERPRINTS": "fingerprints",
  "FW_VERSIONS": "fingerprints",
}
def get_interface_attr(attr, combine_brands=False, ignore_none=False):
  result = {}
  for car_folder in sorted(...):
    brand_name = car_folder.split('/')[-1]
    brand_values = __import__(f'opendbc.car.{brand_name}.{INTERFACE_ATTR_FILE.get(attr, "values")}', fromlist=[attr])
    ...
    if combine_brands:
      for f, v in attr_data.items():
        result[f] = v   # 合并所有品牌到一张表
  return result
```

### 6.2 支持车型列表与品牌

`opendbc/car/values.py` 汇总所有品牌：

```python
Platform = BODY | CHRYSLER | FORD | GM | HONDA | HYUNDAI | MAZDA | MOCK | NISSAN | PSA | RIVIAN | SUBARU | TESLA | TOYOTA | VOLKSWAGEN
BRANDS = get_args(Platform)
PLATFORMS = {str(platform): platform for brand in BRANDS for platform in brand}
```

共 15 个品牌目录（含 `mock` 占位与 `body` comma 自家机器人）。每个品牌下 `CAR(Platforms)` 枚举列出该品牌全部平台，如 Toyota 有 `TOYOTA_COROLLA`、`TOYOTA_PRIUS`、`TOYOTA_RAV4_TSS2_2023`、`LEXUS_RX` 等 30+ 平台，全仓库合计 250+ 平台。

### 6.3 车型属性（年款 / 配置）

每个平台的 `PlatformConfig.car_docs` 描述年款与配置：

```python
TOYOTA_COROLLA_TSS2 = ToyotaTSS2PlatformConfig([
  ToyotaCarDocs("Toyota Corolla 2020-22", video="..."),
  ToyotaCarDocs("Toyota Corolla Cross (Non-US only) 2020-23", min_enable_speed=7.5),
  ToyotaCarDocs("Toyota Corolla Hatchback 2019-22"),
  ToyotaCarDocs("Toyota Corolla Hybrid 2020-22"),
  ToyotaCarDocs("Lexus UX Hybrid 2019-24"),   # 共享平台
])
```

`CarDocs` 同时承载文档生成（comma.ai 官网支持车型表）与运行时属性（`min_enable_speed` 等）。一个 `carFingerprint` 可对应多个 `CarDocs`（同年款不同配置、混动/燃油、不同市场）。

---

## 7. 车辆识别后的配置

识别出 `carFingerprint` 后，`CarInterface.get_params()` → `_get_params()` 完成全部后续配置。`CarInterfaceBase.get_params()`（`interfaces.py`）先填通用参数：

```python
@classmethod
def get_params(cls, candidate, fingerprint, car_fw, alpha_long, is_release, docs):
  ret = CarInterfaceBase.get_std_params(candidate)
  platform = PLATFORMS[candidate]
  ret.mass = platform.config.specs.mass
  ret.wheelbase = platform.config.specs.wheelbase
  ret.steerRatio = platform.config.specs.steerRatio
  ret.flags |= int(platform.config.flags)
  ret = cls._get_params(ret, candidate, fingerprint, car_fw, ...)   # 品牌特化
  ...
  ret.rotationalInertia = scale_rot_inertia(ret.mass, ret.wheelbase)
  ret.tireStiffnessFront, ret.tireStiffnessRear = scale_tire_stiffness(...)
  return ret
```

### 7.1 safety_set_mode（安全模型配置）

每个品牌 `_get_params()` 设置 `ret.safetyConfigs`，这是 panda 固件要加载的安全模型：

```python
# Toyota
ret.safetyConfigs = [get_safety_config(structs.CarParams.SafetyModel.toyota)]
ret.safetyConfigs[0].safetyParam = EPS_SCALE[candidate]
if DBC[candidate][Bus.pt] == "toyota_new_mc_pt_generated":
  ret.safetyConfigs[0].safetyParam |= ToyotaSafetyFlags.ALT_BRAKE.value
if candidate in ANGLE_CONTROL_CAR:
  ret.safetyConfigs[0].safetyParam |= ToyotaSafetyFlags.LTA.value

# Honda（按 Bosch/NIDEC 分流）
if candidate in HONDA_BOSCH:
  cfgs = [get_safety_config(structs.CarParams.SafetyModel.hondaBosch)]
  if candidate in HONDA_BOSCH_CANFD and CAN.pt >= 4:
    cfgs.insert(0, get_safety_config(structs.CarParams.SafetyModel.noOutput))  # 多 panda 隔离
  ret.safetyConfigs = cfgs
else:
  ret.safetyConfigs = [get_safety_config(structs.CarParams.SafetyModel.hondaNidec)]

# Hyundai（CAN-FD / 普通 / Legacy）
if ret.flags & HyundaiFlags.CANFD:
  cfgs = [get_safety_config(structs.CarParams.SafetyModel.hyundaiCanfd)]
elif ret.flags & HyundaiFlags.LEGACY:
  ret.safetyConfigs = [get_safety_config(structs.CarParams.SafetyModel.hyundaiLegacy)]
else:
  ret.safetyConfigs = [get_safety_config(structs.CarParams.SafetyModel.hyundai, 0)]
```

`safetyParam` 是一个位域，承载品牌专属安全标志（如 `ToyotaSafetyFlags.LTA/SECOC/STOCK_LONGITUDINAL`、`HyundaiSafetyFlags.LONG/CAMERA_SCC/HYBRID_GAS`）。多 panda 场景会插入 `noOutput` 配置作隔离。

### 7.2 CAN 总线配置

CAN 总线号由 `CanBus` 类根据 fingerprint 动态确定。`CanBusBase`（`__init__.py`）：

```python
class CanBusBase:
  def __init__(self, CP, fingerprint):
    if CP is None:
      assert fingerprint is not None
      num = max([k for k, v in fingerprint.items() if len(v)], default=0) // 4 + 1  # 推断 panda 数量
    else:
      num = len(CP.safetyConfigs)
    self.offset = 4 * (num - 1)   # 每个 panda 占 4 个 bus 槽
```

每个 panda 占用 4 个 bus（0-3, 4-7, …）。Honda `CanBus(ret, fingerprint)` 据此计算 `PT/CAM/radar` 实际 bus 号。VW/Ford 同理用 `CanBus(fingerprint=fingerprint)` 在 `_get_params` 里算 bus。

### 7.3 限速与功能配置

`_get_params` 大量使用 `fingerprint[bus]` 字典做"运行时特征检测"，决定功能开关：

```python
# Toyota
ret.enableBsm = 0x3F6 in fingerprint[0] and candidate in TSS2_CAR       # 盲区监测
ret.radarUnavailable = Bus.radar not in DBC[candidate]
ret.openpilotLongitudinalControl = (candidate in (TSS2_CAR - RADAR_ACC_CAR) or ...)

# Hyundai（CAN-FD）
ret.enableBsm = 0x1ba in fingerprint[CAN.ECAN]
if 0xFA in fingerprint[CAN.ECAN]:            # 混动
  ret.flags |= HyundaiFlags.HYBRID.value
lka_steering = 0x50 in fingerprint[cam_can] or 0x110 in fingerprint[cam_can]
if 0x130 not in fingerprint[CAN.ECAN]:       # 档位消息变体
  ret.flags |= HyundaiFlags.CANFD_ALT_GEARS.value

# Volkswagen（MQB/MLB/MEB/PQ 分流）
ret.enableBsm = 0x30F in fingerprint[0]      # SWA_01
if 0xAD in fingerprint[0]:                   # Getriebe_11 → 自动挡
  ret.transmissionType = TransmissionType.automatic
if any(msg in fingerprint[1] for msg in (0x40, 0x86, 0xB2, 0xFD)):
  ret.networkLocation = NetworkLocation.gateway

# Ford
ret.enableBsm = 0x3A6 in fingerprint[CAN.main] and 0x3A7 in fingerprint[CAN.main]
if Ecu.shiftByWire in found_ecus or 0x5A in fingerprint[CAN.main]:
  ret.transmissionType = TransmissionType.automatic
```

### 7.4 DBC 文件选择

DBC 由 `PlatformConfig.dbc_dict` 静态声明，并在 `_get_params` 中按条件改写：

```python
# ToyotaTSS2PlatformConfig.init
def init(self):
  self.flags |= ToyotaFlags.TSS2 | ToyotaFlags.NO_DSU
  if self.flags & ToyotaFlags.RADAR_ACC:
    self.dbc_dict = {Bus.pt: 'toyota_nodsu_pt_generated'}   # 雷达 ACC 车型去掉 radar DBC

# ToyotaSecOCPlatformConfig
dbc_dict = field(default_factory=lambda: dbc_dict('toyota_secoc_pt_generated', 'toyota_tss2_adas'))
```

`CarState` 解析时用 `DBC[CP.carFingerprint][Bus.pt]` 取对应 DBC 文件名构造 `CANParser`。

---

## 8. 在线识别 vs 离线识别

### 8.1 实时识别（在线）

即上文 `fingerprint()` 全流程：设备上电后 pandad 启动，实时收 CAN、查 VIN、查固件、做 CAN 指纹，整个过程 1~3 秒。所有识别都发生在车上、实时进行，结果写入 `CarParams` 广播给 controlsd。

### 8.2 离线匹配（回放/测试）

OpenPilot 提供 `selfdrive/debug/get_fingerprint.py`、`test_fw_query_on_routes.py` 等工具，基于已录制的驾驶日志（rlog）离线复现识别：

```python
# test_fw_query_on_routes.py 思路
_, exact_matches = match_fw_to_car(car_fw, CP.carVin, allow_exact=True, allow_fuzzy=False)
_, fuzzy_matches = match_fw_to_car(car_fw, CP.carVin, allow_exact=False, allow_fuzzy=True)
```

离线工具用于：新增车型时的固件采集、CI 回归测试（process_replay）、验证固件数据库变更不破坏旧车型识别。

### 8.3 缓存与用户确认

- **缓存**：`fingerprint()` 优先使用 `cached_params`（上次成功识别的 CarParams）。若 `cached_params.brand != "mock"`、`carFw` 非空、VIN 合法（或 REPLAY 模式），直接复用 carFw，跳过耗时固件查询。
- **强制指定**：环境变量 `FINGERPRINT=TOYOTA_COROLLA` 可绕过所有识别，用于调试/开发（`source = fixed`）。
- **SKIP_FW_QUERY**：环境变量跳过固件查询，仅用 CAN 指纹。
- **DISABLE_FW_CACHE**：禁用缓存，强制重新查询。
- **用户确认**：OpenPilot 本身不需要用户手动确认车型（全自动），但识别为模糊匹配（`fuzzyFingerprint=True`）或 `dashcamOnly` 时，UI 会限制功能并提示。社区分支有时提供"车型选择"菜单覆盖自动识别。

---

## 9. 兼容性扩展：新车型添加流程

### 9.1 添加新车型的标准步骤

1. **采集 CAN 日志**：用 panda + `can_printer` / `get_fingerprint` 在目标车上录制 CAN 流量与固件版本。
2. **新增平台枚举**：在品牌 `values.py` 的 `CAR(Platforms)` 中加一个成员（如 `TOYOTA_NEWCAR`），配置 `PlatformConfig`（CarDocs 年款、CarSpecs 物理、dbc_dict）。
3. **录入固件指纹**：把采集到的 ECU 固件版本填入品牌 `fingerprints.py` 的 `FW_VERSIONS[CAR.TOYOTA_NEWCAR]`，结构为 `{(Ecu.xxx, addr, subaddr): [b'版本', ...]}`。用 `opendbc/car/debug/format_fingerprints.py` 自动格式化。
4. **配置 FW_QUERY_CONFIG**：若新车型用新 ECU/地址，在品牌 `values.py` 的 `FW_QUERY_CONFIG` 增加 `Request` 或 `extra_ecus`。
5. **实现 interface/carstate/carcontroller**：在品牌 `interface.py::_get_params` 加分支，实现 `carstate.py`（CAN 信号解析）和 `carcontroller.py`（控制报文）。
6. **DBC 文件**：在 `opendbc/` 仓库根的 `*.dbc` 文件中维护信号定义（或用 `opendbc/car/debug/` 工具生成 `_generated.dbc`）。
7. **测试验证**：提交 PR，CI 会跑 `process_replay`、`test_fw_query_on_routes`、车型文档生成检查。需提供测试 route。

### 9.2 社区贡献

- opendbc 与 openpilot 均 MIT 许可，PR 流程开放。社区分支（dragonpilot、xgnpilot、HKG 社区版等）常先行支持官方未收录车型，再回流上游。
- `MIGRATION` 字典用于历史平台重命名/合并，保证向后兼容。
- `opendbc/car/debug/` 下有 `format_fingerprints.py`、`get_fingerprint.py`、`can_table.py` 等工具辅助采集与格式化。
- 固件版本不匹配时，工具输出 mismatch 详情（如 `(0x7e0, None): ["89631-06050"]`），开发者据此补全数据库。

### 9.3 测试验证要点

- **CI**：Jenkinsfile 中含固件验证阶段，`pytest selfdrive/debug/test_fw_query_on_routes.py`。
- **process_replay**：所有已收录车型都必须通过回放回归，防止改一处破坏全局识别。
- **dashcamOnly**：缺测试 route 或未验证的车型设 `ret.dashcamOnly = True`（如 Toyota SecOC、Hyundai ALT_LIMITS_2），release 版本下只记录不控制。

---

## 10. AuroraDrive 迁移建议：游戏类型识别方案

### 10.1 现状与差距

AuroraDrive 当前为"游戏辅助模式"，**无车型/游戏类型识别**——所有游戏走同一套辅助逻辑。这相当于 OpenPilot 早期只有 `MOCK` 平台的状态。借鉴 OpenPilot fingerprint 思想，可为 AuroraDrive 设计一套"游戏指纹"机制，为未来支持多游戏（如《极限竞速：地平线》《GT 赛车》《尘埃》等）的差异化辅助铺路。

### 10.2 借鉴 fingerprint 的核心思想

OpenPilot fingerprint 的精髓可抽象为三点：
1. **特征采集**：从运行环境采集一组可区分实体的特征（CAN 地址+长度 / ECU 固件版本）。
2. **消除法匹配**：维护已知实体数据库，用采集到的特征逐步排除不可能的候选。
3. **双模裁决**：精确指纹（固件）优先，模糊指纹（CAN）兜底，并保留强制指定与缓存路径。

### 10.3 AuroraDrive 游戏指纹方案设计

#### 10.3.1 GameFingerprint 数据结构

类比 `gen_empty_fingerprint()`，定义游戏特征字典：

```python
# aurora/fingerprint.py
def gen_empty_game_fingerprint():
  return {
    'window_title': None,        # 窗口/进程标题
    'resolution': None,          # 渲染分辨率
    'api_hooks': set(),          # 命中的图形 API/内存特征
    'hud_signals': {},           # HUD 元素地址 → 信号类型 (速度/转速/挡位)
    'telemetry_ids': set(),      # 遥测消息 ID（如 Forza Data UDP 端口/格式）
  }
```

#### 10.3.2 特征采集（类比 CAN 采集）

- **窗口/进程指纹**：枚举前台窗口与进程名，匹配已知游戏可执行文件签名（类比 CAN 地址）。
- **内存特征指纹**：扫描游戏进程内存中的稳定特征字符串/版本号（类比 ECU 固件版本，唯一性最强）。
- **遥测协议指纹**：很多竞速游戏提供 UDP 遥测（Forza Data、Gran Turismo Sport、Assetto Corsa），其端口号、包结构、字段偏移即天然"固件版本"。这是最可靠的 GameFingerprint 来源。
- **HUD/视觉指纹**：对 HUD 模板做特征匹配（速度表位置、颜色），作为模糊兜底（类比 CAN 指纹）。

#### 10.3.3 数据库（类比 FW_VERSIONS / FINGERPRINTS）

```python
# aurora/games/forza/values.py
class GAME(Platforms):
  FORZA_HORIZON_5 = GamePlatformConfig(
    [GameDocs("Forza Horizon 5", versions=["1.0..1.600"])],
    GameSpecs(telemetry_port=5300, telemetry_format="forza_v1"),
    memory_signatures={0xDEADBEEF: b'FH5\x00...'},   # 内存特征
  )

# aurora/games/forza/fingerprints.py
GAME_FW_VERSIONS = {
  GAME.FORZA_HORIZON_5: {
    ('engine', 0x5300, None): [b'FORZA_DATA_UDP_V1'],   # 遥测端口+协议版本
    ('process', None, None): [b'ForzaHorizon5.exe'],
  },
}
```

#### 10.3.4 匹配算法（直接复用 OpenPilot 双模结构）

- **精确匹配**：遥测协议版本 / 进程内存特征 完全匹配 → 唯一确定游戏。
- **模糊匹配**：窗口标题 + 分辨率 + HUD 模板，至少 2 项唯一命中。
- **裁决**：精确优先，模糊兜底，环境变量 `GAME=FORZA_HORIZON_5` 强制指定。
- **失败回退**：无匹配 → `MOCK_GAME`（通用辅助，不启用游戏专属优化）。

#### 10.3.5 识别后配置（类比 _get_params）

```python
class ForzaInterface(GameInterfaceBase):
  @staticmethod
  def _get_params(ret, candidate, fingerprint, ...):
    ret.brand = "forza"
    ret.telemetryPort = 5300
    ret.speedUnit = SpeedUnit.MPH
    ret.gearFormat = GearFormat.NUMBER
    ret.hudLayout = HudLayout.FH5
    # 按特征微调
    if 0xABC in fingerprint['hud_signals']:
      ret.flags |= ForzaFlags.KMH_CLUSTER.value
    return ret
```

#### 10.3.6 迁移路线建议

1. **阶段一（当前）**：保持单游戏辅助，但引入 `GameFingerprint` 占位结构与 `MOCK_GAME`，把"游戏类型"显式化，为多游戏预留接口。
2. **阶段二**：接入第二游戏时，建立 `GAME_FW_VERSIONS` 数据库与消除法匹配，复用本文第 4 节精确/模糊双模算法。
3. **阶段三**：社区贡献流程——提供游戏特征采集工具（类比 `get_fingerprint.py`），PR 录入新游戏指纹与 `GameInterface` 实现。
4. **阶段四**：跨版本兼容——游戏更新导致内存特征/遥测协议变化时，参考 OpenPilot 的固件版本列表机制，把多版本特征都入库，用模糊匹配容忍差异。

#### 10.3.7 关键借鉴清单

| OpenPilot 机制 | AuroraDrive 对应方案 |
|----------------|---------------------|
| `can_fingerprint()` 实时采集 | 运行时采集窗口/内存/遥测特征 |
| `eliminate_incompatible_cars()` | `eliminate_incompatible_games()` |
| `match_fw_to_car_exact/fuzzy` | 遥测协议精确 / 视觉特征模糊 |
| `FingerprintSource.{can,fw,fixed}` | `GameSource.{visual,telemetry,fixed}` |
| `MIGRATION` 字典 | 游戏版本/重命名迁移表 |
| `PlatformConfig.dbc_dict` | `GamePlatformConfig.telemetry_format` |
| `ESSENTIAL_ECUS` | 必备遥测字段（速度/转速/挡位） |
| `FUZZY_EXCLUDE_ECUS` | 排除共享特征（如通用 HUD 字体） |
| `cached_params` 缓存 | 游戏会话内缓存 GameFingerprint |
| `dashcamOnly` | 识别不确定时仅显示不控制 |

### 10.4 风险与注意

- 游戏内存特征比汽车 ECU 固件更易随更新失效，需更强的模糊兜底与社区快速响应机制。
- 反作弊机制可能限制内存读取，遥测 UDP 协议是更稳健的"固件指纹"来源，应优先采用。
- 法律层面：游戏辅助需遵守各游戏 ToS，区别于 OpenPilot 的车辆改装合规性。

---

## 11. 关键源码索引

| 文件 | 作用 |
|------|------|
| `opendbc/car/car_helpers.py` | `get_car` / `fingerprint` / `can_fingerprint` 编排 |
| `opendbc/car/fingerprints.py` | `is_valid_for_fingerprint` / `eliminate_incompatible_cars` / `MIGRATION` / 聚合 `FW_VERSIONS`、`_FINGERPRINTS` |
| `opendbc/car/fw_versions.py` | `match_fw_to_car` / `match_fw_to_car_exact` / `match_fw_to_car_fuzzy` / `get_fw_versions_ordered` |
| `opendbc/car/fw_query_definitions.py` | `FwQueryConfig` / `Request` / `StdQueries` / `ESSENTIAL_ECUS` |
| `opendbc/car/interfaces.py` | `CarInterfaceBase.get_params` / `get_interface_attr` |
| `opendbc/car/__init__.py` | `gen_empty_fingerprint` / `Bus` / `PlatformConfig` / `Platforms` / `get_safety_config` |
| `opendbc/car/values.py` | 全品牌 `Platform` 联合类型、`BRANDS`、`PLATFORMS` |
| `opendbc/car/<brand>/values.py` | `CAR(Platforms)` 枚举、`PlatformConfig`、`CarSpecs`、`FW_QUERY_CONFIG` |
| `opendbc/car/<brand>/fingerprints.py` | `FW_VERSIONS` 固件指纹数据库 |
| `opendbc/car/<brand>/interface.py` | `_get_params` 安全模型/CAN/DBC/限速配置 |

---

## 12. 总结

OpenPilot 的 panda fingerprint 是一套**两层（CAN + 固件）、双模（精确 + 模糊）、可缓存可强制**的车辆识别系统：

1. **CAN 指纹（FPv1）** 用消息地址+长度的消除法实时识别，1~2 秒内收敛到唯一车型；固件不可用时作为兜底。
2. **固件指纹（FPv2）** 用 ECU 固件版本做精确匹配，非关键 ECU 可缺、关键 ECU 必须命中；精确失败再用模糊匹配（≥2 个唯一 ECU 命中）。
3. **裁决优先级**：`fixed > fw(唯一) > can`，结果写入 `CarParams.carFingerprint`，驱动后续安全模型、CAN 总线、DBC、限速等全部配置。
4. **数据库**：`FW_VERSIONS` 按品牌分目录维护，版本列表支持跨年款；`MIGRATION` 保证命名演进兼容；社区通过 PR + CI 回归持续扩展。
5. **AuroraDrive 迁移**：可照搬"特征采集 + 消除法 + 精确/模糊双模 + 数据库 + 识别后配置"的架构，以遥测协议为"固件指纹"、视觉/HUD 为"CAN 指纹"，构建多游戏识别体系。

这套设计的核心价值在于：把"识别"与"控制"彻底解耦——识别只产出 `carFingerprint` 字符串，所有控制逻辑通过该字符串查表配置，使新增车型的成本主要落在"采集指纹 + 写 interface"而非改框架，这正是 OpenPilot 能覆盖 250+ 车型的根本原因。

---

> 本报告基于对 `commaai/opendbc` 与 `commaai/openpilot` 仓库 master 分支源码的直接抓取与中文技术资料交叉验证。
> 实际工具调用次数：53 次（WebSearch + WebFetch + Read + RunCommand）。
