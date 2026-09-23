# Maa-11 Navi 导航系统全链

> 覆盖源文件：`MaaNTE/agent/custom/action/Navi/`（14 文件 3356 行）：map_locator.py（650）+ nte_coordinate_api.py（611）+ route_model.py（340）+ coordinate_position.py（312）+ waypoint_navigator.py（310）+ navigation_server.py（290）+ local_route_navigation.py（281）+ angle_predictor.py（220）+ route_runner.py（145）+ online_map_navigation_action.py（104）+ route_websocket_service.py（57）+ resource_paths.py（14）+ debug_windows.py（11）+ __init__.py（11）。基于当前仓库逐单元编写。

## 一、模块协作总览（14 文件分工）

```
                    ┌─ nte_coordinate_api.py（611）── 抓包解析 UE5 移动包 → 原始坐标/朝向
                    │
坐标来源（二选一）───┤
                    └─ map_locator.py（650）──────── 视觉：小地图模板匹配 + 多尺度
                              ↓
                    coordinate_position.py（312）── 统一出口 CoordinatePositionProvider
                              ↓                    + 标定矩阵（raw → map 像素）
                    angle_predictor.py（220）────── 朝向补正（ONNX 指针模型）
                              ↓
   路线状态 ────────→ route_model.py（340）────── RouteSession + 三种 waypoint 解析
                              ↓
   执行层 ──────────→ waypoint_navigator.py（310）─ PID 转向 + 前进键
                      route_runner.py（145）────── 主循环（帧→定位→导航）
                              ↓
   对外 ────────────→ navigation_server.py（290）─ WebSocket 服务 :14514（状态广播）
                      route_websocket_service.py（57）─ 桥接：帧/路线 → 服务
                      online_map_navigation_action.py（104）┐
                      local_route_navigation.py（281）─────┴→ CustomAction 入口
```

**双定位后端**：**默认 `coordinate`（抓包，精度高、无需视觉）→ 失败自动降级 `map`（视觉模板匹配）**；`position_backend` 只接受 `map` / `auto` / `coordinate` 三值。

## 二、nte_coordinate_api.py（611 行）——UE5 移动包解码器

**模块头注释（1–7 行，逐字）**：

> Open UE5 movement-packet coordinate decoder.
> The game serializes client movement as a bit-packed timestamp, acceleration, location and compressed control rotation. **The movement block is not at a stable bit offset across builds, so this module discovers the block and then locks onto it using time, location and rotation continuity.**

**API 契约（20–22 行）**：`__all__ = ("API_VERSION", "CoordinateCapture")` + **`API_VERSION = "1.3.0"`**——**coordinate_position.py 会强校验该版本（68–73 行），不匹配直接 RuntimeError**。

**位读取原语（33–39 行）**：

```python
def _bits(data: bytes, offset: int, count: int) -> int:
    if offset < 0 or count < 0 or offset + count > len(data) * 8:
        raise ValueError("bit range is outside payload")
    first_byte = offset // 8
    last_byte = (offset + count + 7) // 8
    value = int.from_bytes(data[first_byte:last_byte], "little")
    return (value >> (offset % 8)) & ((1 << count) - 1)
```

**跨字节小端位域提取**（先取整段字节 → 右移偏移 → 掩码）——**越界即抛 ValueError（调用方统一捕获跳过）**。

**UE 向量解码 `_vector`（42–63 行）**：7 位头（**低 6 位 width + 最高位 scaled 标志**）→ 三分量各读 width 位 → **符号位在最高位，负数减模 `1 << width`** → scaled 时除 scale（**加速度 scale=10，位置 scale=100**）；**`width == 0` 抛 "unsupported full-precision vector"（全精度回退形式不支持）**。

**旋转解码 `_rotator`（66–79 行）——FRotator::SerializeCompressedShort**：Pitch/Yaw/Roll 各 **1 位 present 标志 + 16 位压缩角**；`angle = compressed × 360 / 65536`，**> 180 减 360**（归一化到 [-180, 180]）。

**`_has_valid_rotation`（82–106 行）——误匹配过滤的核心**：

- 先扫三组 present 标志（`cursor += 1 + (16 if present else 0)`）→ 再解 rotator
- **判据（96–106 行注释逐字）**："ControlRotation serializes pitch and yaw, while roll is normally omitted by the client. **This presence pattern removes common random alignments.**" → **要求 `flags[1]（Yaw）存在 && flags[2]（Roll）不存在 && |pitch| ≤ 90.001` 且全部分量有限且 ≤ 180.001**

**朝向换算 `_pose`（113–125 行）**：

```python
view_direction = (cos(pitch)·cos(yaw), cos(pitch)·sin(yaw), sin(pitch))
north = dot(view_direction, _NORTH)      # _NORTH = (-0.013752068070295848, -0.9999054358407049, 0)
east  = dot(view_direction, _EAST)       # _EAST  = ( 0.9999054358407049, -0.01375206807029585, 0)
heading = (degrees(atan2(east, north)) + 360) % 360
```

**返回 `(x, y, z, pitch, heading)` 五元组**；`_NORTH` / `_EAST` 是**游戏世界轴到导航坐标系的旋转向量**（两者点积 ≈ -0.0138² + 0.9998² ≈ 1，正交且近轴对齐——**存在约 0.79° 的世界轴偏角**）。

**包方向判定（132–171 行）**：

| 函数 | 语义 |
|---|---|
| `_is_localish_address`（132–146 行） | `is_private or is_loopback or is_link_local or is_reserved`——**注释（136–140 行）："ipaddress.is_private intentionally covers more than RFC1918/ULA ranges in modern Python versions. That is useful here because packet capture adapters may expose local traffic through non-global ranges such as 198.18.0.0/15"** |
| `_packet_direction`（149–171 行） | 本地↔全局 → `c2s` / `s2c`；**其余一律 `unknown`（注释："Ambiguous cases are deliberately left as unknown instead of being guessed"）** |

**`_is_windows_admin`（174–180 行）**：非 win32 直接 False；`ctypes.windll.shell32.IsUserAnAdmin()` 异常也 False。

**`_Decoder`（183–374 行）——状态机核心（9 个 `__slots__` 状态字段）**：

**候选枚举 `_candidates`（260–297 行）**：

- **注释（263–265 行）**："The movement block is bit-packed and can shift when optional replicated fields are added. **Known builds use offsets 197, 213, 230, 233, 236 and 252, but scanning every bit also handles an unseen field insertion.**"
- **扫描区间 `range(190, min(512, len(payload)*8 - 60))`**
- 每偏移试解：32 位 float `client_time` + `_vector(...,10)` 加速度 + `_vector(...,100)` 位置
- **七重过滤**：client_time 有限且 `0 ≤ t < 100000`；**两向量都必须是 scaled**；`1 ≤ acc_bits ≤ 16`；`20 ≤ loc_bits ≤ 32`；`max|acc| < 50000`；`max|loc| ≤ 2_000_000`；**尾部必须有合法 rotation（注释 290–292 行："A false bit alignment can satisfy the two vector headers while producing arbitrary trailing bits. Real movement records always carry a valid compressed control rotation immediately afterwards."）**

**跟踪与重捕获（207–258 行 `decode`）**：

| 场景 | 处理 |
|---|---|
| **流切换**（flow != _flow） | `_new_flow_candidate` → `_confirm_flow`（**两次确认机制**） |
| 首次（无历史） | 同上 |
| **常规跟踪** | `gap = timestamp - _last_capture`；`expected = _last_time + gap`；**优先同偏移候选（`item[1] == _last_offset`），否则全集**；按 `_tracking_key` 取最小 |
| **时间偏差 > 1.0s** | 视为失步 → `_reacquire_candidates` 过滤（`t ≥ 0.01 && offset ≤ 512 && max|acc| ≤ 10000`）→ `_fresh`（**有历史位置时取空间最近，否则取时间最大**）→ 重锁 |

**`_tracking_key`（299–309 行）——双信号打分**：

```python
time_error = abs(item[0] - expected)
spatial_penalty = min(distance_sq / (5000²), 100.0)
return time_error + spatial_penalty, time_error, distance_sq
```

**注释（306–307 行）**："Time remains the primary signal, while the spatial term prevents a different valid-looking record in a large packet from being selected."（**时间为主 + 空间惩罚防大包内错选**）

**`_confirm_flow`（344–368 行）——防抖确认：连续 2 帧一致才切换**：

- 首次 → 记 pending，返回 None
- 再次：`time_ok = Δt ≥ 0.001 && |Δt - gap| ≤ 0.5`；`offset_ok = 同偏移`；`step_ok = 位置变化² ≤ 6.4e9`（**≈ 80000 单位内的位移**）
- 三条件全真 → `_pending_seen += 1`（否则重置为 1）；**`>= 2` 才返回候选**

**解码尾部（247–258 行）**：定位确定后**硬编码跳过 `bit_offset + 32`（时间）再解加速度（scale 10）→ 位置（scale 100）→ rotator**，全程 try 捕获 ValueError/OverflowError → None。

**`CoordinateCapture`（377–611 行）——抓包器（14 `__slots__`）**：

- **构造（399–426 行）**：**默认 `packet_filter = "tcp port 30031 or udp"`（游戏移动包端口 30031）**；`refresh_rate=30` → `_interval = 1/refresh_rate`（**采样节流**）；**backend 别名 `scapy` → `pcap`**；仅接受 `pcap` / `pktmon`
- **`_accept_packet`（436–466 行）**：计数 packet/payload/s2c（锁内）→ **空载荷跳过 → `s2c` 方向跳过（只要客户端上行）** → decode → **`now - _last_sample_wall < _interval` 则丢弃（限速）** → 写 _sample/_sample_at
- **`_start_pcap`（468–522 行）**：`from scapy.all import AsyncSniffer, IP, IPv6, Raw, TCP, UDP, conf`；**`conf.use_pcap = True` + 校验（477–478 行："scapy libpcap provider is unavailable"）**；`on_packet` 取 Raw 层 load + IP/IPv6 源目 + TCP/UDP 端口（**TCP 优先，UDP 次之**）→ `_accept_packet`；**`AsyncSniffer(iface=self._interface or str(conf.iface), filter=..., prn=..., store=False)`**
- **`_start_pktmon`（524–571 行）**：**先查管理员（525–529 行："pktmon capture requires administrator privileges; restart MaaNTE as administrator or use visual positioning"）**；**12 项调优 kwargs**（read_timeout_ms=20 / queue_size=64 / native_queue_capacity=256 / buffer_size_multiplier=4 / **truncation_size=9000** / include_empty_payloads=False / drain_batch_size=512 / callback_batch_size=8）→ **TypeError 时退化为 3 参数极简构造（兼容旧版 pktmon-interface）**
- **`stats()`（573–595 行）**：9 项指标（含 packet_age / payload_age / sample_age **三档新鲜度** + `callback_error` 类型名）
- **`read(max_age=1.0)`（596–605 行）**：锁内判新鲜度，超时返回 None；**docstring 明确定义返回 `(x, y, z, raw_pitch, compass_heading)`，heading 以正北 0°、范围 [0, 360)**
- **`close()`（607–611 行）**：`if getattr(sniffer, "running", False): sniffer.stop(join=True)`

## 三、coordinate_position.py（312 行）——统一坐标出口 + 标定矩阵

**标定块（22–29 行，生成器标记）**：

```python
# BEGIN GENERATED NAVI COORDINATE TRANSFORM
_CALIBRATION_AXES = (0, 1)
_CALIBRATION_A = 0.016394586684750773
_CALIBRATION_B = 5.693519256055879e-08
_CALIBRATION_TX = 6293.474380746091
_CALIBRATION_TY = 3472.664390686138
_CALIBRATION_ERROR = 0.22031967781665318
# END GENERATED NAVI COORDINATE TRANSFORM
```

- **`scripts/update_navi_coordinate_transform.py` 生成（脚本在仓库 scripts/ 下）**——**b 近似 0（5.7e-08）说明两坐标系几乎仅差缩放+平移，无旋转**
- **缩放系数 `sqrt(a² + b²) ≈ 0.0163946`**——**游戏世界单位 → 地图像素的比例**；`error = 0.22`（**拟合残差记录在案**）
- **`COORDINATE_MAP_SIZE = (11264, 11264)`（17 行）——地图像素域边长**

**`_Transform`（84–112 行）——相似变换 + 逆变换**：

```python
def apply(self, point):        # raw → map
    x, y = point[axes[0]], point[axes[1]]
    return (a·x - b·y + tx,  b·x + a·y + ty)

def invert_xy(self, point):    # map → raw（仅 axes == (0,1) 时可用）
    denominator = a² + b²      # <= 1e-12 → None（防退化除零）
    return ((a·dx + b·dy)/den, (-b·dx + a·dy)/den)
```

**`_create_capture`（42–81 行）——动态导入 + 三重校验**：

1. `importlib.import_module(".nte_coordinate_api", package=__package__)` 失败 → **RuntimeError 带全上下文（模块名/包名/Python 版本/解释器路径/异常类型）——排障友好**（46–58 行）
2. 无 `CoordinateCapture` 属性 → RuntimeError + **报告实际加载文件路径**（62–66 行）
3. **`API_VERSION` 不等于 "1.3.0" → RuntimeError**（68–73 行）
4. 构造 `capture_type(refresh_rate=0, capture_backend=...)` + **校验 start/read/close 三个方法可调用**（75–80 行）

**`CoordinatePositionProvider`（150–312 行）——双后端编排**：

- **`__init__`（151–210 行）**：backend 归一化（**仅 map/auto/coordinate，其他抛 ValueError**）；`map` → **直接返回（纯视觉）**；否则**依次尝试 `("pcap", "pktmon")`**：失败则 close 残骸 + 记 errors + warning，成功即 break
  - 全失败：**`coordinate` 模式 → RuntimeError（含各后端失败原因拼接）；`auto` 模式 → warning "using visual positioning" + 返回（降级视觉）**
  - 成功：**info 打印 backend/axes/scale/error**（204–210 行）
- **`locate(locator, frame)`（212–304 行）——四态返回**：

| 态 | 条件 | mode | 返回 |
|---|---|---|---|
| 视觉路径 | 无 capture | locator 结果 | **`result.raw_coordinate = _raw_xy_from_map(result.point)`（视觉反算原始坐标）**；locator 为 None → RuntimeError |
| **采样过期** | `read(max_age=1.0)` → None | **`coordinate_stale`** | found=False + **沿用上次位置（score = 上次存在 ? 1.0 : 0.0）** |
| **变换失败** | 非有限 / pitch/heading 非法 | **`coordinate_invalid`** | 同上 + `_coordinate_active = False` |
| 正常 | — | **`coordinate`** | found=True / score=1.0 + raw_coordinate + pitch + **`heading % 360.0` 归一** |

- **`uses_visual_positioning()`**（306–307 行）：`_capture is None`——**供上层判断当前定位来源**
- **首次成功时的 info（275–277 行）**："Navi position source switched to coordinate-only"

## 四、route_model.py（340 行）——路线状态与三种坐标解析

**三套坐标系常量（10–14 行）**：

| 常量 | 值 | 语义 |
|---|---|---|
| `ONLINE_MAP_SIZE` | (22528, 22528) | **在线地图（maante-map）像素域——坐标域的 2 倍** |
| `ONLINE_WORLD_ORIGIN_PIXEL` | (11264.0, 11264.0) | 世界原点在线地图中的像素位置（**正中心**） |
| `ONLINE_PIXELS_PER_WORLD_UNIT` | 44.0 | 世界单位 → 在线地图像素 |

**`RouteSession`（17–93 行）——线程安全可变路线态**：

- 字段：waypoints / active / current_index / status / **`lock: threading.Lock`（dataclass field default_factory）**
- **7 个状态值**：`waiting`（初值）/ `ready` / `running` / `arrived` / `cleared` / `stopped` / `empty`
- `payload()`（27–36 行）：**锁内快照为 JSON dict**（waypoints 转 `{pixelX, pixelY}` + active + currentIndex + status）
- `reset(waypoints, start, current_point)`（38–52 行）：**`active = bool(start and waypoints)`（两者都真才激活）**；激活且有当前点 → `current_index = nearest_index(...)`；status = running/ready
- `start(current_point)`（54–66 行）：**空路线 → active=False + status="empty"**；有当前点 → 最近索引；否则 **`min(current_index, len-1)`（索引越界钳制）**
- `advance()`（68–73 行）：`current_index += 1`；**越界 → active=False + status="arrived"**
- **`nearest_index`（87–93 行）：欧氏距离平方最小（不开方——只比大小）**

**`parse_waypoint`（96–123 行）——四格式自动识别**：

| 输入键 | 分支 | 结果 |
|---|---|---|
| `pixelX` / `pixelY` | 源码尺寸缩放 | `x·targetW/sourceW` |
| `target_x` / `target_y` | 同上（**别名**） | 同上 |
| `lat` / `lng` | `parse_online_waypoint` | 在线地图坐标 |
| `x` / `y`（+ 可选 z） | `parse_raw_coordinate_waypoint` | **原始游戏坐标 → 标定矩阵 → 地图像素** |
| 其他 | **ValueError**（列出全部四种合法格式） | — |

- `parse_source_size`（163–169 行）：`sourceWidth/sourceHeight` → `sourceSize` 数组 → 默认值（**三级优先**）

**`parse_online_waypoint`（126–140 行）**：

```python
map_x = origin_x + world_lng * 44.0
map_y = origin_y - world_lat * 44.0     # y 轴翻转
x = map_x * target_w / 22528
```

**注释（130 行）**："maante-map stores route points as world coordinates named lat/lng."（**在线地图把世界坐标命名为 lat/lng——不是地理经纬度**）

**`parse_raw_coordinate_waypoint`（143–160 行）**：调 `raw_coordinate_to_map(x, y, z?)` → **None 抛 "raw coordinate waypoint is not finite"** → 按 11264 域缩放到目标尺寸。

**JSON 装载三件套**：

| 函数 | 支持结构 |
|---|---|
| `parse_waypoints_from_json_data`（182–206 行） | list 直接当序列；dict 支持 **`route.waypoints` 嵌套展平（`{**data, **route_data}`）** + `waypoints` / `points` / `path` 三别名 |
| `load_waypoints_from_json`（209–216 行） | `Path(path).expanduser()` + utf-8 |
| `parse_route_segment_from_json_data`（219–254 行） | **多段路线：`select_route` 选路线 → `segments[index]`**；无 segments 则整路线解析；**空 segments 抛 "route has no segments"**；越界抛带 total 的 ValueError；**源尺寸三级回退：segment → route → 文件**（246–249 行） |

**`select_route`（275–294 行）**：无 routes → 原样返回；空数组 → 抛；**route_name 空白 → 取第 0 条**；否则按 **`name` 或 `id`** 匹配（**两者任一命中**）；找不到 → `"route not found: xxx"`。

**`normalize_segment_index`（297–299 行）**：**`index <= 1 → 0`，否则 `index - 1`——外部 1-based、内部 0-based 的兼容转换**。

**`handle_route_message`（302–340 行）——WebSocket 指令处理（5 类 × 双别名）**：

| 消息类型 | 行为 | 响应 |
|---|---|---|
| `navi-route-set` / `route-set` | reset（支持消息自带 sourceSize） | ack + route.payload() |
| `navi-route-add` / `route-add` | **锁内 append 单点**；非激活态 → status="ready" | ack |
| `navi-route-clear` / `route-clear` | clear | ack |
| `navi-route-start` / `route-start` | start(current_point) | ack |
| `navi-route-stop` / `route-stop` | stop | ack |
| 其他 | — | **`{"type": "navi-route-ack", "ok": False, "message": "unknown type"}`** |

## 五、map_locator.py（650 行）+ angle_predictor.py（220 行）——视觉后端

**`MapLocationResult`（18 行）——统一结果结构**：found / point / raw_point / score / **mode** / polygon / **raw_coordinate** / **camera_pitch** / **camera_heading**（后三项由 coordinate_position 填充）——**视觉与抓包两条路径共用同一结构（这就是双后端可热切换的原因）**。

**`MapLocator`（30 行起）关键接口**：

| 方法 | 语义 |
|---|---|
| `shared_assets()` / `load_shared_assets()`（123–170 行） | **类级共享资产（模板图等只加载一次，多实例复用）** |
| `activate_map_crop_size(index)`（194 行） | **切换裁剪尺度档位** |
| `locate(frame)`（224–325 行） | 主定位：小地图裁剪 → 模板匹配 → 输出 result |
| **`match_template_all_scales`（326–358 行）** | **多尺度全扫（缩放不确定时用）** |
| **`recover_from_teleport`（359–400 行）** | **传送后位置跳变恢复** |
| `match_template`（401–510 行） | 单尺度模板匹配 |
| `setup_debug_window` / `show_debug`（511–548 行） | 可视化调试窗 |

**`AnglePredictor`（angle_predictor.py 30 行起）——ONNX 指针模型**：

- `predict(frame)`（52 行）→ `AnglePredictionResult`（20 行）
- **`resolve_backend(backend)`（169–188 行）+ `provider_name()`（165 行）+ `get_session()`（189 行）**——**多推理后端（ONNX Runtime 执行提供者）选择**
- **`show_debug`（100 行）/ `close_debug`（155 行）**：裁剪图 + 结果可视化
- **模型位置（AGENTS.md 载明）：`assets/MaaNTEModels/navi/pointer_model.onnx`**（独立 git 仓库，约 15M）

## 六、waypoint_navigator.py（310 行）——转向 PID 与前进

**`AnglePidController`（22–69 行）**：

- `reset()`（36 行）/ **`update(error, now)`（41 行）——含时间戳参数：dt 由调用方提供，避免内部计时的抖动**
- **PID 输出即转向量（角度误差 → 鼠标/摇杆增量）**

**`WaypointNavigator`（71–308 行）**：

| 方法 | 语义 |
|---|---|
| `__init__`（74–131 行） | 参数装载（含 PID 三系数、到达阈值、前进时长等） |
| **`update()`（132–155 行）** | **主更新：返回 `(location, angle) | None`——供 RouteRunner 与 WebSocket 共用** |
| **`move_to(target)`（156–235 行）** | **单路点闭环：转向 → 前进 → 到达判定** |
| `press_forward()`（236–246 行）/ `release()`（247–253 行） | 前进键按下/释放（**分离，便于内嵌短按**） |
| **`sleep_remaining(started)`（276–288 行）/ `sleep_interruptible(duration)`（289–298 行）** | **可中断睡眠（返回 bool 表示是否被打断）——长循环响应停止信号的关键** |
| `close()`（254 行） | 资源释放 |
| **`load_params(custom_action_param)`（300–309 行，模块级）** | **pipeline `custom_action_param` → dict（容错解析）** |

## 七、route_runner.py（145 行）+ navigation_server.py（290 行）——执行与对外

**`RouteRunner`（145 行）——主循环编排**：

- `__init__`（15–40 行）+ `start()`（41 行）+ **`run_until_stopped(...)`（62–107 行）**
- **`update_current_frame()`（113–118 行）→ Waypoint | None**；`source_size()`（119 行）；`current_point()`（122 行）
- **`_on_frame(location, angle)`（126–132 行）——每帧回调（喂 WebSocket 广播）**
- **`_should_cancel()`（133 行）——停止判据（`context.tasker.stopping` 等）**
- `close()`（108 行）

**`NavigationWebSocketServer`（290 行）——本机 WebSocket 服务**：

- **监听 `0.0.0.0:14514`（13、22–24 行）——默认端口 14514**
- **⚠️ 启动即静默 websockets 库四个 logger（15–18 行）**：`websockets` / `.server` / `.client` / `.protocol` → WARNING（**否则每连接刷屏**）
- **状态结构（35–49 行）**：`type: "navi-state"` / **version: 1** / position / angle / pitch / **angleConfidence** / **route{waypoints, active, currentIndex, status}** / timestamp
- **`start(timeout=5.0)`（51–83 行）——幂等 + 就绪事件**：`_start_lock` 内查重（**已启动但有 start_error → 重抛**）→ 起 daemon 线程 `navi-websocket-server` → **`_ready_event.wait(timeout)` 超时 → stop() + TimeoutError（含 ws URL）**；start_error 非空 → stop() + RuntimeError
- **`stop(timeout=3.0)`（85–109 行）**：`asyncio.run_coroutine_threadsafe(self._close_server(), loop)` + **`future.result(timeout)`** → `loop.call_soon_threadsafe(loop.stop)` → `thread.join(timeout)` → 清态
- **`publish_state(...)`（111–150 行）——每次自动 start()**：位置 dict（x/y/score/mode + 可选 z + **map_point 则补 pixelX/pixelY/sourceWidth/sourceHeight**）→ 锁内写 → `_schedule_broadcast()`
- **`publish_route(...)`（152–169 行）**：覆写 route 块 + 广播
- **`_broadcast_latest`（215–226 行）**：`asyncio.gather(*(client.send(payload)...), return_exceptions=True)` → **异常客户端从集合剔除（自动清理死连接）**
- **`_handle_client`（181–188 行）**：**加入集合 → 立即 send 全量状态（新客户端同步）→ `async for` 收消息 → finally 移除**
- **`_handle_message`（190–213 行）——同步/异步处理器双兼容**：`json.loads` → 处理器 → **`inspect.isawaitable(result)` 则 await** → 非 None 则 send；异常 → **回 `{"type": "navi-error", "message": str(exc)}`**
- **`_run_server`（257–289 行）**：**`from websockets.asyncio.server import serve`（新版 API）ImportError → `_start_error` + 就绪事件仍 set**；`asyncio.new_event_loop()` 独占线程；`loop.run_forever()`；finally 关服务 + 关 loop
- **`_close_server`（228–244 行）**：逐客户端关闭（`_close_client` 246–255 行：**close() 与 wait_closed() 都判 awaitable——兼容不同 websockets 版本**）→ `server.close()` + **`wait_for(server.wait_closed(), timeout=1.0)`**

**`RouteWebSocketService`（route_websocket_service.py 57 行）——桥接层**：`start` / `stop` / **`publish_frame(location, angle)`（30 行）** / **`publish_route()`（42 行）** / **`handle_message(message)`（51 行）→ dict（转发给 route_model.handle_route_message）**。

## 八、两个 CustomAction 入口 + 辅助（local_route_navigation / online_map_navigation_action / resource_paths / debug_windows）

**`local_route_navigation.py`（281 行）——本地路线执行**：

- **模块级工具**：`resolve_route_json_path(json_path)`（37–55 行，**相对路径解析到 resource 根**）、`parse_route_waypoints(...)`（56–74 行）
- **`LocalRouteNavigation`（75–193 行）——上下文管理器**：`load_route_json`（114 行）/ **`run_route`（125–170 行）** / `close`（171 行）/ **`__enter__` / `__exit__`（177–181 行，`with` 语法保证释放）** / `_route_json_for_run`（183–195 行）
- **两个注册动作**：
  - **`@AgentServer.custom_action("local_route_navigation")`（196–197 行）**
  - **`@AgentServer.custom_action("local_route_navigation_unit_test")`（243–244 行）——单测入口：route_model 的解析链可脱离游戏单独验证**

**`online_map_navigation_action.py`（104 行）**：`@AgentServer.custom_action("online_map_navigation")`（15–16 行）→ `run`（17–65 行）+ **`load_option_params(context)`（66–100 行，从 pipeline option 取值）** + **`load_config_attach(context, node_name)`（101–104 行——`attach` 配置装载）**。

**`resource_paths.py`（14 行）**：`resource_base_path()`（4 行）——**Navi 资源定位单一入口**。

**`debug_windows.py`（11 行）**：调试窗口开关（**代码量极小，说明调试可视化统一走 map_locator / angle_predictor 的 show_debug**）。

**`__init__.py`（11 行）**：包导出（**激活全部 `@AgentServer` 装饰器的注册副作用**——见 Maa-09 单元五注册机制）。

---

**Maa-11 文档至此完整**（Navi 14 文件 3356 行全链：抓包解码 → 标定变换 → 路线模型 → PID 导航 → WebSocket 对外；含 UE5 位域解析、双后端降级、多段路线、五类 WS 指令）
