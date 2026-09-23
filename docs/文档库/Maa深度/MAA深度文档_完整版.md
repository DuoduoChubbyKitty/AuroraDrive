# MaaNTE 极度详细技术文档

> 基于源码逐行分析，覆盖所有模块、算法、配置和实现细节。

> 【2026-09-19 现状标注】本文档描述 MaaNTE 框架本身（本地 `MaaNTE/` 框架本体仍保留，含 assets 459M、蓝色大肥鱼 107M），内容仍有效。项目侧定位：Maa 只做工具（ROI/模板/任务定义参考），不整体接管 AuroraDrive；坐标体系 1470×923（游戏窗口不可改分辨率），运行期长边 1280 缩比，OCR 必须 GPU。截至 2026-09-19：250 个 ROI 节点 override 已生成（181 规则套用 + 32 精确反推，+83 偏移规则），剩 24 个缺模板节点待实机采集（胜负加载屏、商店页、光标；SceneLoadingType2 的 '%' 与 Sync×6 疑似占位，属上游坏定义）；「重要剧情跳过」与普通跳过是同一按钮，不单独挖模板；BidKing（拍卖王）PR#434 代码已提取至独立文件夹 `BidKing_PR434/`（git 7b7d2db，未合并进 MaaNTE 树，其任务 json 本地已存在）。

---

## 一、系统概述

### 1.1 项目定位

MaaNTE 是基于 [MaaFramework](https://github.com/MaaXYZ/MaaFramework) 的《异环》(Never to Everness / NTE) 自动化工具。通过**图像识别 + 模拟输入**对游戏进行黑盒自动化控制。

**核心能力**：
- 自动钓鱼（含导航、买饵、卖鱼）
- 自动寻路导航（网络包坐标 + 视觉定位双引擎）
- 自动咖啡/饮料制作
- 家具收取
- 自动排球、俄罗斯方块、节奏游戏、钢琴
- 音频驱动闪避
- 粉爪大劫案（三阶段潜行动作）
- 实时辅助（传送、跳剧情、拾取）
- 数据集采集

### 1.2 技术栈

| 层次 | 技术 | 说明 |
|---|---|---|
| GUI 前端 | MXU (MaaFramework Next UI) | C++/Qt 桌面应用 |
| 中间件 | MaaFramework | 图像识别引擎 + 输入模拟 + Pipeline 编排 |
| 自定义逻辑 | Python 3.x | CustomAction / CustomRecognition |
| 图像处理 | OpenCV (cv2) + NumPy | 模板匹配、颜色过滤、姿态检测 |
| 深度学习 | ONNX Runtime | 导航方向预测模型 |
| 网络抓包 | Scapy / pktmon | UE5 移动包解码（坐标获取） |
| 通信协议 | MaaHub Socket IPC | GUI ↔ Agent 进程通信 |
| 音频处理 | Librosa + scipy | 音频匹配检测闪避/反击音效 |

### 1.3 基准分辨率

所有坐标、ROI、模板匹配均基于 **1280×720** 基准分辨率。运行时通过 `screen.map_point()` / `screen.map_rect()` 自动缩放到实际窗口尺寸。

```python
# agent/utils/screen.py
BASELINE_WIDTH = 1280
BASELINE_HEIGHT = 720

def update_screen_size(width: int, height: int) -> None:
    global _current_width, _current_height, _scale_x, _scale_y
    _current_width = int(width)
    _current_height = int(height)
    _scale_x = _current_width / BASELINE_WIDTH if BASELINE_WIDTH else 1.0
    _scale_y = _current_height / BASELINE_HEIGHT if BASELINE_HEIGHT else 1.0

def map_point(x: int, y: int) -> Sequence[int]:
    return int(round(x * _scale_x)), int(round(y * _scale_y))

def map_rect(rect: Sequence[int]) -> Sequence[int]:
    x, y, w, h = rect
    mapped_x, mapped_y = map_point(x, y)
    return mapped_x, mapped_y, int(round(w * _scale_x)), int(round(h * _scale_y))
```

---

## 二、核心架构

### 2.1 进程模型

```
MXU GUI (主进程, C++/Qt)
    │
    ├── socket IPC ──→ Python Agent (子进程, agent/main.py)
    │                       │
    │                       ├── CustomAction (Python)
    │                       ├── MaaFramework C++ 引擎
    │                       └── Win32 Controller
    │
    └── (可选) WebSocket ──→ 外部路由服务 (Navi, port 14514)
```

### 2.2 主入口流程

```python
# agent/main.py
def main():
    current_version = read_interface_version()       # 读取 interface.json version
    is_dev_mode = current_version == "DEBUG"          # DEBUG 模式 = 开发调试

    if sys.platform.startswith("win"):
        _check_admin_privilege()                      # 检查管理员权限

    if sys.platform.startswith("linux") or is_dev_mode:
        ensure_venv_and_relaunch_if_needed()          # Linux/开发模式: 创建并重启到 venv

    check_and_install_dependencies()                   # 安装 requirements.txt 依赖

    if is_dev_mode:
        os.chdir(Path("./assets"))                     # 开发模式切换 cwd

    agent(is_dev_mode=is_dev_mode)                     # 启动 Agent


def agent(is_dev_mode=False):
    # 清理 utils 模块缓存
    utils_modules = [name for name in list(sys.modules.keys()) if name.startswith("utils")]
    for module_name in utils_modules:
        del sys.modules[module_name]

    import utils                                       # 动态导入 utils
    import importlib
    importlib.reload(utils)                            # 重新加载

    # 将 utils 的所有公共属性导入到当前命名空间
    for attr_name in dir(utils):
        if not attr_name.startswith("_"):
            globals()[attr_name] = getattr(utils, attr_name)

    from maa.agent.agent_server import AgentServer
    from maa.tasker import Tasker
    import custom                                       # 触发 custom/action/__init__.py 注册所有 CustomAction

    Tasker.set_log_dir("./debug")
    from utils.i18n import init as i18n_init
    i18n_init()                                        # 初始化国际化

    socket_id = sys.argv[-1]                           # 最后一个参数是 socket_id
    AgentServer.start_up(socket_id)                    # 启动 MaaHub Socket 服务器
    _check_game_resolution()                           # 检测游戏窗口分辨率
    AgentServer.join()                                 # 阻塞等待任务完成
    AgentServer.shut_down()                            # 优雅关闭
```

### 2.3 依赖安装

```python
def install_requirements(req_file="requirements.txt", pip_config: dict | None = None) -> bool:
    # 1. 查找本地 deps/whl 目录（离线安装优先）
    deps_dir = find_local_wheels_dir()

    if deps_dir:
        # 离线安装：--no-index --find-links
        cmd = [sys.executable, "-m", "pip", "install", "-U", "-r", str(req_path),
               "--no-warn-script-location", "--break-system-packages",
               "--find-links", str(deps_dir), "--no-index"]
    else:
        # 在线安装：使用镜像源
        primary_mirror = pip_config.get("mirror", "https://pypi.tuna.tsinghua.edu.cn/simple")
        backup_mirror = pip_config.get("backup_mirror", "https://mirrors.ustc.edu.cn/pypi/simple")
        cmd = [..., "-i", primary_mirror, "--extra-index-url", backup_mirror]

    # 使用 subprocess.Popen 实时输出日志
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, ...)
```

### 2.4 配置文件

**interface.json** — 全局配置注册表：
```json
{
    "interface_version": 2,
    "name": "MaaNTE",
    "version": "0.0.4",
    "controller": [
        {
            "name": "Win32",
            "type": "Win32",
            "permission_required": true,
            "win32": {
                "class_regex": "UnrealWindow",
                "window_regex": "^\\s*(异环|NTE)\\s*$",
                "screencap": "Background",
                "mouse": "SendMessageWithCursorPos",
                "keyboard": "PostMessage"
            }
        },
        {
            "name": "Win32-Front",
            "type": "Win32",
            "win32": {
                "class_regex": "UnrealWindow",
                "window_regex": "^\\s*(异环|NTE)\\s*$",
                "screencap": "PrintWindow",
                "mouse": "Seize",
                "keyboard": "Seize"
            }
        },
        {
            "name": "Win32-Background",
            "type": "Win32",
            "permission_required": true,
            "win32": {
                "class_regex": "UnrealWindow",
                "window_regex": "^\\s*(异环|NTE)\\s*$",
                "screencap": "PrintWindow",
                "mouse": "SendMessageWithWindowPos",
                "keyboard": "PostMessage"
            }
        }
    ],
    "import": [
        "resource/tasks/ClaimRewards.json",
        "resource/tasks/Fish.json",
        "resource/tasks/Volleyball.json",
        // ... 更多
    ]
}
```

---

## 三、Pipeline 执行引擎

### 3.1 Pipeline JSON 格式

Pipeline 是 MaaFramework 的核心编排单元，采用 **JSON 定义的状态机**：

```json
{
  "name": "FishGameStart",
  "recognition": {
    "type": "TemplateMatch",
    "param": {
      "template": ["Fish/FishGameSign3.png"],
      "roi": [1141, 609, 87, 84],
      "threshold": [0.7]
    }
  },
  "action": {
    "type": "Custom",
    "param": {
      "custom_action_name": "auto_fish",
      "custom_action_param": {"count": 10}
    }
  },
  "next": ["FishGameLoop", "FishHandleBaitLack"]
}
```

### 3.2 识别类型

| 类型 | 说明 | 典型参数 |
|---|---|---|
| `TemplateMatch` | 模板匹配（CCoeffNormed） | template, roi, threshold, green_mask |
| `OCR` | PaddleOCR 文字识别 | expected, threshold (~0.3) |
| `ColorMatch` | RGB 颜色匹配 | lower, upper, count, connected |
| `DirectHit` | 直接命中（无需条件） | — |
| `And` / `Or` | 复合识别 | children (子节点列表) |
| `Custom` | Python 自定义识别 | custom_recognition_name |

### 3.3 动作类型

| 类型 | 说明 |
|---|---|
| `Click` | 鼠标点击（目标坐标） |
| `LongPress` | 长按 |
| `Swipe` | 滑动 |
| `ClickKey` | 按键（VK 码） |
| `Custom` | Python CustomAction |
| `DoNothing` | 空操作 |
| `StopTask` | 停止任务 |

### 3.4 执行原则（AGENTS.md 规范）

1. **识别→动作→重新识别**循环：每次识别后必须重新识别确认状态，禁止"识别一次，连续点 A、B、C"
2. **`next` 首轮命中原则**：next 列表覆盖所有可能画面状态，拒绝重试机制
3. **避免硬延迟**：优先使用中间识别节点或 `pre_wait_freezes`/`post_wait_freezes`
4. **处理中间态**：弹窗、加载、不在目标场景等均需在 next 中处理

### 3.5 命名规范

- Pipeline 节点：**帕斯卡命名**，带任务/模块前缀（如 `FishNewEntrance`）
- 私有节点：`__` 前缀（如 `__ScenePrivate*`），禁止外部引用
- 跳转节点：`[JumpBack]NodeName` 格式
- 优先使用 SceneManager 公开接口（`Interface/Scene/`）

---

## 四、坐标与定位系统

### 4.1 三层坐标体系

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: 游戏世界坐标 (World Coordinate)                   │
│  - UE5 浮点坐标 (x, y, z)，范围约 ±2,000,000               │
│  - 来源：网络包解码 (nte_coordinate_api.py)                 │
│  - 或：视觉定位 (MapLocator)                               │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: 地图像素坐标 (Map Coordinate)                     │
│  - 转换公式：                                               │
│      map_x = a * wx - b * wy + tx                         │
│      map_y = b * wx + a * wy + ty                         │
│  - 校准常数 (map-2026-08):                                  │
│      a = 0.016394586684750773                              │
│      b = 5.693519256055879e-08                             │
│      tx = 6526.474380746091  (TX += 233)                   │
│      ty = 5210.664390686138  (TY += 1738)                   │
│  - 地图尺寸：13056 × 13056 (已扩展到 map-2026-08)           │
├─────────────────────────────────────────────────────────────┤
│  Layer 3: 屏幕像素坐标 (Screen Coordinate)                  │
│  - 基准：1280 × 720                                        │
│  - 缩放：screen.map_point(x, y) → (x * sx, y * sy)        │
│  - 小地图 ROI：(28, 15, 150, 150)                          │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 网络包坐标解码（nte_coordinate_api.py）

UE5 客户端将移动数据以 bit-packed 格式封装在 UDP/TCP 包中。解码器通过扫描 payload 找到有效的位置字段：

```python
# nte_coordinate_api.py

def _bits(data: bytes, offset: int, count: int) -> int:
    """从字节流的指定 bit offset 读取 count 个 bit"""
    first_byte = offset // 8
    last_byte = (offset + count + 7) // 8
    value = int.from_bytes(data[first_byte:last_byte], "little")
    return (value >> (offset % 8)) & ((1 << count) - 1)


def _vector(data: bytes, offset: int, scale: int) -> tuple[_Vector3, int, int, bool]:
    """解码 UE5 BitPackedVector3: [7-bit header][3 signed values]"""
    header = _bits(data, offset, 7)
    offset += 7
    width = header & 63           # 每个分量的 bit 数 (1-63)
    scaled = bool(header >> 6)     # 是否带小数缩放
    if width == 0:
        raise ValueError("unsupported full-precision vector")

    values: list[float] = []
    sign = 1 << (width - 1)
    modulus = 1 << width
    for _ in range(3):
        value = _bits(data, offset, width)
        offset += width
        if value & sign:
            value -= modulus       # 符号扩展：有符号整数
        values.append(value / scale if scaled else float(value))
    return (values[0], values[1], values[2]), offset, width, scaled


def _rotator(data: bytes, offset: int) -> tuple[_Vector3, int]:
    """解码 FRotator::SerializeCompressedShort (Pitch, Yaw, Roll)"""
    values: list[float] = []
    for _ in range(3):
        present = _bits(data, offset, 1)     # 1-bit 存在标志
        offset += 1
        compressed = _bits(data, offset, 16) if present else 0
        if present:
            offset += 16
        angle = compressed * 360.0 / 65536.0
        if angle > 180.0:
            angle -= 360.0
        values.append(angle)
    return (values[0], values[1], values[2]), offset
```

**坐标解码主流程**：

```python
class _Decoder:
    def decode(self, payload: bytes, timestamp: float, flow: _Flow) -> _Pose | None:
        candidates = self._candidates(payload)
        if not candidates:
            return None

        # 流连续性检查：如果 flow 变化，需要重新确认
        if self._flow is not None and flow != self._flow:
            candidate = self._new_flow_candidate(candidates)
            selected = self._confirm_flow(flow, candidate, timestamp)
            if selected is None:
                return None
            self._flow = flow

        # 时间连续性追踪
        gap = max(0.0, timestamp - self._last_capture)
        expected = self._last_time + gap
        aligned = [item for item in candidates if item[1] == self._last_offset]
        tracking_candidates = aligned or candidates
        selected = min(tracking_candidates, key=lambda item: self._tracking_key(item, expected))

        # 时间偏差过大时重新获取
        time_error = abs(selected[0] - expected)
        if time_error > 1.0:
            plausible = self._reacquire_candidates(tracking_candidates)
            selected = self._fresh(plausible)
            self._flow = flow

        client_time, bit_offset, _, location = selected
        # 提取 location (scale=100) 和 rotation
        _, cursor, _, _ = _vector(payload, bit_offset + 32, 10)   # acceleration
        _, cursor, _, _ = _vector(payload, cursor, 100)           # location
        rotation, _ = _rotator(payload, cursor)                    # control rotation

        return _pose(location, rotation)

    def _candidates(self, payload: bytes) -> list[_Candidate]:
        """扫描 payload[190:512] bit 范围寻找有效位置"""
        output: list[_Candidate] = []
        search_end = min(512, len(payload) * 8 - 60)
        for offset in range(190, search_end):
            try:
                # 1. 尝试解析 time (32-bit float)
                client_time = struct.unpack("<f", _bits(payload, offset, 32).to_bytes(4, "little"))[0]
                # 2. 尝试解析 acceleration (7-bit header + 3 signed values, scale=10)
                acceleration, cursor, acceleration_bits, acceleration_scaled = _vector(payload, offset + 32, 10)
                # 3. 尝试解析 location (3 float, scale=100)
                location, _, location_bits, location_scaled = _vector(payload, cursor, 100)
            except (ValueError, OverflowError):
                continue

            # 有效性校验
            if not math.isfinite(client_time) or not 0 <= client_time < 100_000:
                continue
            if not acceleration_scaled or not location_scaled:
                continue
            if not 1 <= acceleration_bits <= 16 or not 20 <= location_bits <= 32:
                continue
            if max(map(abs, acceleration)) >= 50_000:
                continue
            if max(map(abs, location)) > _MAX_LOCATION_ABS:
                continue
            # 关键：验证后面跟着有效的压缩旋转数据
            location_end = cursor + 7 + location_bits * 3
            if not _has_valid_rotation(payload, location_end):
                continue
            output.append((client_time, offset, acceleration, location))
        return output
```

**两个后端**：
- `pcap`: 使用 Scapy 的 AsyncSniffer，监听 TCP 30031 / UDP
- `pktmon`: 使用 Windows pktmon，需要管理员权限

```python
class CoordinateCapture:
    def __init__(self, interface=None, packet_filter="tcp port 30031 or udp",
                 refresh_rate=30.0, capture_backend="pcap"):
        self._decoder = _Decoder()
        self._capture_backend = capture_backend

    def start(self) -> None:
        if self._capture_backend == "pktmon":
            self._start_pktmon()
        else:
            self._start_pcap()

    def _start_pcap(self) -> None:
        from scapy.all import AsyncSniffer, IP, IPv6, Raw, TCP, UDP, conf
        conf.use_pcap = True

        def on_packet(packet):
            if not packet.haslayer(Raw):
                return
            payload = bytes(packet[Raw].load)
            if not payload:
                return

            # 分类 packet 方向 (c2s/s2c)
            source = str(packet[IP].src) if packet.haslayer(IP) else ""
            destination = str(packet[IP].dst) if packet.haslayer(IP) else ""
            sport, dport, protocol = 0, 0, ""
            if packet.haslayer(TCP):
                transport = packet[TCP]
                sport, dport, protocol = transport.sport, transport.dport, "TCP"
            elif packet.haslayer(UDP):
                transport = packet[UDP]
                sport, dport, protocol = transport.sport, transport.dport, "UDP"

            timestamp = float(getattr(packet, "time", time.time()))
            self._accept_packet(payload, timestamp, (source, sport, destination, dport, protocol))

        sniffer = AsyncSniffer(iface=self._interface or str(conf.iface),
                               filter=self._filter, prn=on_packet, store=False)
        sniffer.start()
        self._sniffer = sniffer

    def read(self, max_age: float = 1.0) -> _Pose | None:
        """返回 (x, y, z, raw_pitch, compass_heading)"""
        with self._lock:
            if self._sample is None or time.time() - self._last_sample_wall > max_age:
                return None
            return self._sample
```

### 4.3 坐标转换

```python
# coordinate_position.py

_CALIBRATION_AXES = (0, 1)
_CALIBRATION_A = 0.016394586684750773
_CALIBRATION_B = 5.693519256055879e-08
_CALIBRATION_TX = 6526.474380746091   # map-2026-08 扩展到 13056 后 TX+=233
_CALIBRATION_TY = 5210.664390686138   # map-2026-08 扩展到 13056 后 TY+=1738
_COORDINATE_MAP_SIZE = (13056, 13056)  # 已更新到 map-2026-08

@dataclass(frozen=True, slots=True)
class _Transform:
    axes: tuple[int, int]
    a: float
    b: float
    tx: float
    ty: float
    error: float

    def apply(self, point: _RawPoint) -> tuple[float, float]:
        """仿射变换：地图坐标 = f(世界坐标)"""
        x = point[self.axes[0]]
        y = point[self.axes[1]]
        return (
            self.a * x - self.b * y + self.tx,
            self.b * x + self.a * y + self.ty,
        )

    def invert_xy(self, point: tuple[float, float]) -> tuple[float, float] | None:
        """逆变换：世界坐标 = f⁻¹(地图坐标)"""
        if self.axes != (0, 1):
            return None
        denominator = self.a * self.a + self.b * self.b
        if denominator <= 1e-12:
            return None
        delta_x = float(point[0]) - self.tx
        delta_y = float(point[1]) - self.ty
        return (
            (self.a * delta_x + self.b * delta_y) / denominator,
            (-self.b * delta_x + self.a * delta_y) / denominator,
        )


def raw_coordinate_to_map(x: float, y: float, z: float | None = None) -> _MapPoint | None:
    point = (float(x), float(y), 0.0 if z is None else float(z))
    map_x, map_y = _COORDINATE_TRANSFORM.apply(point)
    if not math.isfinite(map_x) or not math.isfinite(map_y):
        return None
    return int(round(map_x)), int(round(map_y))
```

### 4.4 视觉定位（MapLocator）

当网络包不可用时，使用小地图模板匹配：

```python
# map_locator.py

class MapLocator:
    MAP_SIZE = (13056, 13056)           # 大地图尺寸（已扩展到 map-2026-08）
    MINI_MAP_ROI = (28, 15, 150, 150)   # 小地图 ROI（屏幕坐标）
    BUTTON_ROI = (16, 656, 31, 35)      # 聊天按钮 ROI（检测是否在大世界界面）
    MAP_CROP_SIZES = (268, 530, 660)    # 多尺度匹配模板尺寸
    SEARCH_RADIUS = 256                 # 邻域搜索半径（地图坐标）
    GLOBAL_MIN_SCORE = 0.85             # 全局搜索最低置信度
    LOCAL_MIN_SCORE = 0.75              # 邻域搜索最低置信度
    TELEPORT_DISTANCE = 320             # 传送判定距离
    SMOOTHING_ALPHA = 0.7               # EMA 平滑系数
    MIN_FILTER_PIXELS = 120             # 最小有效像素数

    # 全局搜索区域（原图 13056×13056 上的坐标）
    GLOBAL_SEARCH_REGIONS = [
        (8976, 9700, 1506, 2644),   # y_start, y_end, x_start, x_end
        (2561, 8703, 2312, 7719),
    ]

    def locate(self, frame: np.ndarray) -> MapLocationResult:
        """主定位逻辑"""
        x, y, w, h = self.MINI_MAP_ROI
        minimap = frame[y:y+h, x:x+w]

        # 1. 初始化圆形掩码（小地图是圆形的）
        template_mask = np.zeros((h, w), dtype=np.uint8)
        center = (w // 2, h // 2)
        cv2.circle(template_mask, center, min(w, h) // 2 - self.CIRCLE_PADDING, 255, -1)

        # 2. HSV 颜色过滤，去除小图标干扰
        hsv_img = cv2.cvtColor(minimap, cv2.COLOR_BGR2HSV)
        color_mask = cv2.inRange(hsv_img, np.array([0, 0, 0]), np.array([179, 66, 80]))

        # 3. 结合颜色掩码和圆形掩码
        combined_mask = cv2.bitwise_and(color_mask, template_mask)

        # 4. 取 V 通道作为灰度
        v_channel = hsv_img[:, :, 2]
        mini_gray = cv2.bitwise_and(v_channel, combined_mask)

        # 5. 大地图灰度对齐：template = mini_gray - 3
        template = cv2.subtract(mini_gray, 3)

        # 6. 检测是否在大世界界面
        button_found, prob, _, _ = match_template_in_region(
            frame, self.BUTTON_ROI, self.chat_template, min_similarity=0.2, green_mask=True)
        if not button_found:
            return self.last_location_result("not_in_world", ...)

        # 7. 多尺度模板匹配
        selected_index, result = self.match_template_all_scales(template, template_mask, w, h)

        # 8. 传送恢复
        result = self.recover_from_teleport(template, template_mask, w, h, result)

        # 9. EMA 平滑
        if raw_point is not None and self.smoothed_center is not None:
            alpha = self.SMOOTHING_ALPHA
            self.smoothed_center = (
                self.smoothed_center[0] * (1.0 - alpha) + raw_point[0] * alpha,
                self.smoothed_center[1] * (1.0 - alpha) + raw_point[1] * alpha,
            )

        return MapLocationResult(found=True, point=point, raw_point=raw_point, ...)
```

**多尺度匹配**：

```python
def match_template(self, template, template_mask, w, h, map_crop_index, *, force_global=False):
    scale, big_match = self._match_maps[map_crop_index]

    if self.last_center is not None and not force_global:
        # 邻域搜索：基于上次位置 ±SEARCH_RADIUS 范围内搜索
        center_x = self.last_center[0] * scale
        center_y = self.last_center[1] * scale
        radius = self.SEARCH_RADIUS * scale
        offset_x = max(0, int(math.floor(center_x - radius - w * 0.5)))
        offset_y = max(0, int(math.floor(center_y - radius - h * 0.5)))
        end_x = min(big_match.shape[1], int(math.ceil(center_x + radius + w * 0.5)))
        end_y = min(big_match.shape[0], int(math.ceil(center_y + radius + h * 0.5)))
        search_image = big_match[offset_y:end_y, offset_x:end_x]
        min_score = self.LOCAL_MIN_SCORE
        mode = "local"

        response = cv2.matchTemplate(search_image, template, cv2.TM_CCORR_NORMED, mask=template_mask)
    else:
        # 全局搜索：在预定义的非黑区域搜索
        min_score = self.GLOBAL_MIN_SCORE
        mode = "global"
        for ry0, ry1, rx0, rx1 in self.GLOBAL_SEARCH_REGIONS:
            mry0 = int(round(ry0 * scale))
            mrx0 = int(round(rx0 * scale))
            region = big_match[mry0:mry1, mrx0:mrx1]
            response = cv2.matchTemplate(region, template, cv2.TM_CCORR_NORMED, mask=template_mask)
            # 取最佳匹配

    # 坐标映射
    match_x = best_offset_x + best_loc[0]
    match_y = best_offset_y + best_loc[1]
    raw_point = (int(round((match_x + w * 0.5) / scale)), int(round((match_y + h * 0.5) / scale)))
```

**传送恢复**：

```python
def recover_from_teleport(self, template, template_mask, w, h, result):
    """当位置跳变超过 TELEPORT_DISTANCE 时，触发全局重定位"""
    if self.last_center is None:
        return result

    should_recover = not result.found or result.raw_point is None
    if result.mode == "local" and result.raw_point is not None:
        distance = math.hypot(result.raw_point[0] - self.last_center[0],
                              result.raw_point[1] - self.last_center[1])
        should_recover = should_recover or distance >= self.TELEPORT_DISTANCE

    if not should_recover:
        return result

    # 强制全局搜索
    global_index, global_result = self.match_template_all_scales(template, template_mask, w, h, force_global=True)
    if not global_result.found or global_result.raw_point is None:
        return result

    return MapLocationResult(found=True, point=global_result.point, mode="global_teleport", ...)
```

### 4.5 方向预测（AnglePredictor）

```python
# angle_predictor.py

class AnglePredictor:
    pointer_roi = [73, 60, 64, 64]  # 小地图内方向箭头 ROI

    def predict(self, frame: np.ndarray) -> AnglePredictionResult:
        session, _ = self.get_session()
        input_name = session.get_inputs()[0].name

        # 裁剪方向箭头区域
        x, y, w, h = self.pointer_roi
        img_crop = frame[y:y+h, x:x+w].copy()
        img_rgb = cv2.cvtColor(img_crop, cv2.COLOR_BGR2RGB)
        img_input = (img_rgb / 255.0).transpose(2, 0, 1).astype(np.float32)
        img_input = np.expand_dims(img_input, axis=0)

        # ONNX 推理
        output = session.run(None, {input_name: img_input})[0][0]
        confidence = output[:, 4]
        best_idx = int(np.argmax(confidence))
        best_pred = output[best_idx]
        max_conf = float(confidence[best_idx])

        if max_conf > self.threshold:
            kpts = best_pred[6:].reshape(3, 3)     # 3个关键点
            tip = kpts[0][:2]                        # 箭头尖端
            left = kpts[1][:2]                       # 左翼
            right = kpts[2][:2]                      # 右翼
            tail_center = (left + right) / 2
            dx = tip[0] - tail_center[0]
            dy = tip[1] - tail_center[1]
            angle = math.degrees(math.atan2(dx, -dy)) % 360

        return AnglePredictionResult(found=True, angle=angle, confidence=max_conf, ...)
```

### 4.6 PID 控制器

```python
# waypoint_navigator.py

class AnglePidController:
    kp = 0.85    # 比例增益
    ki = 0.04    # 积分增益
    kd = 0.10    # 微分增益
    output_limit = 35.0   # 最大转向角度（度）
    integral_limit = 120.0
    deadband = 4.0        # 死区（角度差在此范围内不响应）
    max_dt = 0.25         # 最大时间步长

    def update(self, error: float, now: float) -> float:
        if abs(error) <= self.deadband:
            self.reset()
            return 0.0

        dt = max(1e-3, min(self.max_dt, now - self._last_time))
        derivative = (error - self._last_error) / dt if self._last_error is not None else 0.0

        # 反向时清除积分（anti-windup）
        if self._last_error is not None and error * self._last_error < 0:
            self._integral = 0.0
        self._integral += error * dt
        self._integral = max(-self.integral_limit, min(self.integral_limit, self._integral))

        output = self.kp * error + self.ki * self._integral + self.kd * derivative
        return max(-self.output_limit, min(self.output_limit, output))
```

### 4.7 WaypointNavigator 控制循环

```python
# waypoint_navigator.py

class WaypointNavigator:
    def move_to(self, target: tuple[int, int]) -> bool:
        target_x, target_y = target
        deadline = time.monotonic() + self.max_duration
        self.turn_pid.reset()

        while not self.context.tasker.stopping:
            if deadline is not None and time.monotonic() >= deadline:
                self.release()
                return False

            # 1. 获取当前位置和朝向
            location = self.position_provider.locate(self.locator, frame)
            angle = self.predictor.predict(frame) if self.locator else AnglePredictionResult(...)

            if not location.found or not angle.found or angle.angle is None:
                self.turn_pid.reset()
                self.release()
                continue

            current_x, current_y = location.point
            dx = target_x - current_x
            dy = target_y - current_y
            distance = math.hypot(dx, dy)

            # 2. 到达检测
            if distance <= self.tolerance:
                self.release()
                return True

            # 3. 计算目标角度
            desired_angle = math.degrees(math.atan2(dx, -dy)) % 360.0
            angle_delta = (desired_angle - angle.angle + 540.0) % 360.0 - 180.0

            # 4. PID 转向
            turn_degrees = self.turn_pid.update(angle_delta, time.monotonic())
            turn_pixels = int(round(turn_degrees * self.turn_pixels_per_degree))

            # 5. 执行移动
            self.press_forward()   # 按住 W
            if turn_dx != 0:
                self.controller.post_relative_move(turn_dx, 0)

            self.sleep_remaining(started)

        self.release()
        return False
```

---

## 五、自动钓鱼系统

### 5.1 状态机

```
┌─────────────────────────────────────────────────────────────┐
│                      Fish 状态机                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   [Start]                                                    │
│      │                                                       │
│      ▼                                                       │
│   FishEntrance → 检测是否在钓鱼场景                           │
│      │                                                       │
│      ├─→ FishGameStart → AutoFish (核心钓鱼循环)              │
│      │                         │                             │
│      │                         ├─→ 检测到成功钓鱼              │
│      │                         │    └─→ 结算界面检测           │
│      │                         │         └─→ ESC 关闭          │
│      │                         │                             │
│      │                         ├─→ 检测到缺饵                  │
│      │                         │    └─→ FishHandleBaitLack    │
│      │                         │         └─→ 购买鱼饵          │
│      │                         │                             │
│      │                         ├─→ 检测到逃脱                  │
│      │                         │    └─→ 重新抛竿               │
│      │                         │                             │
│      │                         └─→ 完成 count 次               │
│      │                              └─→ FishLoopStart         │
│      │                                                       │
│      └─→ FishNewEntrance (新版钓鱼入口)                       │
│            └─→ FishNewAutoNavi → 导航到钓鱼点                  │
│                                  └─→ FishNewStart            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 核心钓鱼逻辑（auto_fish.py）

```python
# agent/custom/action/AutoFish/auto_fish.py

@AgentServer.custom_action("auto_fish")
class AutoFish(CustomAction):
    # 模板图片（基于 1280×720 基准）
    slider_img = image_dir / "slider.png"              # 滑块
    valid_region_left_img = image_dir / "valid_region_left.png"   # 有效区左边界
    valid_region_right_img = image_dir / "valid_region_right.png" # 有效区右边界
    success_catch_img = image_dir / "success_catch.png"   # 成功捕获标志
    escape_img = image_dir / "escape.png"            # 逃脱标志
    settlement_img = image_dir / "settlement_blank.png"   # 结算界面
    prepare_start_img = image_dir / "FishPrepareStartButton.png"  # 准备开始按钮
    fish_game_sign_img = image_dir / "FishGameSign3.png"    # 钓鱼游戏标志
    need_bait_img = image_dir / "need_bait.png"      # 需要鱼饵提示

    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        controller = context.tasker.controller

        # 参数解析
        fishing_count = 10
        check_freq = 0.001
        if argv.custom_action_param:
            params = json.loads(argv.custom_action_param)
            fishing_count = params.get("count", 10)
            check_freq = params.get("freq", 0.001)

        # 区域定义（基于 1280×720）
        success_region = [520, 160, 265, 30]          # 成功捕获检测区
        settlement_region = [566, 642, 150, 23]       # 结算界面检测区
        game_region = [401, 39, 481, 24]             # 钓鱼游戏区域
        escape_region = [590, 349, 99, 22]           # 逃脱检测区
        prepare_region = [908, 602, 339, 52]         # 准备开始按钮区
        fish_game_sign_region = [1141, 609, 87, 84]  # 钓鱼游戏标志区
        fish_game_sign_region_2 = [1224, 27, 30, 30] # 小地图内标志
        need_bait_region = [610, 350, 141, 21]       # 缺饵提示区

        # 缩放适配
        success_region = screen.map_rect(success_region)
        settlement_region = screen.map_rect(settlement_region)
        game_region = screen.map_rect(game_region)
        # ... 其他 ROI 缩放

        for i in range(fishing_count):
            if context.tasker.stopping:
                return CustomAction.RunResult(success=False)
            PrintT(context, "autofish.progress", i + 1, fishing_count)

            # Step 1: 确保在钓鱼游戏界面
            if not ensure_fish_game():
                return CustomAction.RunResult(success=False)

            # Step 2: 抛竿前摇（连续按 F 5次）
            for _ in range(5):
                controller.post_key_down(KEY_F)
                time.sleep(0.1)
                controller.post_key_up(KEY_F)

            # Step 3: 检测是否需要鱼饵
            for _ in range(5):
                img = get_image(controller)
                m_need_bait, prob, _, _ = match_template_in_region(img, need_bait_region, self.need_bait_template, 0.7)
                if m_need_bait:
                    context.override_next("FishGameStart", ["FishHandleBaitLack"])
                    return CustomAction.RunResult(success=True)
                time.sleep(0.1)

            # Step 4: 等待鱼咬钩（最多30秒）
            wait_start = time.time()
            while time.time() - wait_start < 30:
                if context.tasker.stopping:
                    return CustomAction.RunResult(success=False)
                time.sleep(check_freq)
                img = get_image(controller)

                m_settle, _, _, _ = match_template_in_region(img, settlement_region, self.settlement_template, 0.8)
                if m_settle:
                    break  # 意外结算界面，跳出

                m_catch, _, _, _ = match_template_in_region(img, success_region, self.success_catch_template, 0.7)
                if m_catch:
                    break  # 鱼咬钩了！

            # Step 5: 钓鱼小游戏（拉条平衡）
            if m_settle:
                press_esc()
                continue
            fish_minigame()

        return CustomAction.RunResult(success=True)
```

### 5.3 钓鱼小游戏算法

```python
def fish_minigame():
    """拉条平衡小游戏"""
    deadzone = 15  # 死区像素
    start_time = time.time()
    last_bar_width = 100
    last_target = game_region[0] + game_region[2] / 2
    last_x_slider = last_target
    slider_miss_count = 0
    current_ad_key = None

    def set_ad_key(key):
        """安全切换 A/D 键"""
        nonlocal current_ad_key
        if current_ad_key == key:
            return
        if current_ad_key is not None:
            controller.post_key_up(current_ad_key)
        if key is not None:
            controller.post_key_down(key)
        current_ad_key = key

    while time.time() - start_time < 100:  # 最长100秒
        if context.tasker.stopping:
            set_ad_key(None)
            return CustomAction.RunResult(success=False)
        time.sleep(check_freq)
        img = get_image(controller)
        frame += 1

        # 每10帧按一次 F（模拟拉力）
        if frame % 10 == 0:
            if current_ad_key is not None:
                controller.post_key_up(current_ad_key)
            controller.post_key_down(KEY_F)
            time.sleep(0.05)
            controller.post_key_up(KEY_F)
            if current_ad_key is not None:
                controller.post_key_down(current_ad_key)

        # 检测有效区域边界和滑块位置
        m_left, _, x_left, _ = match_template_in_region(img, game_region, self.valid_region_left_template, 0.7)
        m_right, _, x_right, _ = match_template_in_region(img, game_region, self.valid_region_right_template, 0.7)
        m_slider, _, x_slider, _ = match_template_in_region(img, game_region, self.slider_template, 0.7)

        # 滑块丢失时保持最后已知位置
        if m_slider:
            slider_miss_count = 0
            last_x_slider = x_slider
        else:
            slider_miss_count += 1
            if slider_miss_count < 15:
                x_slider = last_x_slider
            else:
                x_slider = None

        # 计算目标位置
        if m_left and m_right:
            last_bar_width = x_right - x_left
            target = (x_left + x_right) / 2
            last_target = target
        elif m_left:
            target = x_left + last_bar_width / 2
            last_target = target
        elif m_right:
            target = x_right - last_bar_width / 2
            last_target = target
        else:
            target = last_target

        # PID 控制
        if target is not None and x_slider is not None:
            offset = x_slider - target
            if offset > deadzone:
                set_ad_key(KEY_A)    # 向左
            elif offset < -deadzone:
                set_ad_key(KEY_D)    # 向右
            else:
                set_ad_key(None)     # 松开
        else:
            set_ad_key(None)
```

### 5.4 自动买鱼饵（auto_buy_fish_bait.py）

```python
@AgentServer.custom_action("auto_buy_fish_bait")
class AutoBuyFishBait(CustomAction):
    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        # 区域定义
        fish_shop_region = [35, 88, 410, 475]
        find_bait_success_region = [1044, 131, 68, 23]
        select_max_region = [1202, 620, 33, 32]
        buy_region = [1050, 674, 50, 25]
        buy_confirm_region = [749, 462, 47, 25]
        buy_success_region = [569, 629, 145, 19]

        # Step 1: 找到鱼饵
        while True:
            img = get_image(controller)
            found_bait, prob, x, y = match_template_in_region(img, fish_shop_region, self.bait_template, threshold)
            if found_bait:
                controller.post_touch_move(x, y)  # 先移动到位置再点击
                for _ in range(3):
                    click_rect(controller, [x, y, 30, 10])
                    time.sleep(0.1)
                # 验证点击成功
                img = get_image(controller)
                found_success, _, _, _ = match_template_in_region(img, find_bait_success_region, self.find_bait_success_template, 0.7)
                if found_success:
                    break
            else:
                controller.post_click_key(KEY_R)  # 刷新
                time.sleep(1)

        # Step 2: 选择最大数量
        # Step 3: 点击购买
        # Step 4: 确认购买
        # Step 5: 等待购买成功
        return CustomAction.RunResult(success=True)
```

### 5.5 自动卖鱼（auto_sell_fish.py）

```python
@AgentServer.custom_action("auto_sell_fish")
class AutoSellFish(CustomAction):
    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        # 区域定义
        sell_option_region = [63, 247, 66, 57]
        sell_button_region = [665, 635, 92, 23]
        confirm_sell_region = [756, 461, 48, 21]
        sell_success_region = [565, 628, 149, 21]

        while True:
            img = get_image(controller)
            # 检测卖鱼选项
            found_option, _, _, _ = match_template_in_region(img, sell_option_region, self.sell_option_template, 0.7)
            if found_option:
                for _ in range(3):
                    click_rect(controller, sell_option_region)
                    time.sleep(0.1)
                # 验证选中
                found_selected, _, _, _ = match_template_in_region(img, sell_option_selected_region, self.sell_option_selected_template, 0.8)
                if found_selected:
                    break
            else:
                controller.post_click_key(KEY_Q)
                time.sleep(1)

        # 检测是否有鱼可卖
        # 点击卖鱼按钮
        # 确认出售
        # 等待出售成功
        return CustomAction.RunResult(success=True)
```

---

## 六、导航系统

### 6.1 整体架构

```
RouteRunner (路线执行器)
  │
  ├── WaypointNavigator (航点导航器)
  │     │
  │     ├── CoordinatePositionProvider (坐标提供者)
  │     │     ├── pcap backend (Scapy)
  │     │     └── pktmon backend (Windows)
  │     │
  │     ├── MapLocator (视觉定位 fallback)
  │     │     ├── 多尺度模板匹配
  │     │     ├── EMA 坐标平滑
  │     │     └── 传送恢复逻辑
  │     │
  │     └── AnglePredictor (方向预测)
  │           └── ONNX 模型 (pointer_model.onnx)
  │
  └── RouteSession (共享状态)
        ├── waypoints
        ├── current_index
        └── WebSocket 接口 (port 14514)
```

### 6.2 RouteSession — 路线状态管理

```python
# route_model.py

@dataclass
class RouteSession:
    """自动寻路和 WebSocket 控制共享的可变路线状态"""
    waypoints: list[Waypoint] = field(default_factory=list)
    active: bool = False
    current_index: int = 0
    status: str = "waiting"
    lock: threading.Lock = field(default_factory=threading.Lock)

    def reset(self, waypoints, start, current_point):
        with self.lock:
            self.waypoints = waypoints
            self.active = bool(start and waypoints)
            self.current_index = self.nearest_index(current_point) if self.active else 0
            self.status = "running" if self.active else "ready"

    def advance(self):
        with self.lock:
            self.current_index += 1
            if self.current_index >= len(self.waypoints):
                self.active = False
                self.status = "arrived"

    def nearest_index(self, current_point):
        """找到距离当前位置最近的航点索引"""
        cx, cy = current_point
        return min(range(len(self.waypoints)),
                   key=lambda i: (self.waypoints[i][0]-cx)**2 + (self.waypoints[i][1]-cy)**2)


def parse_waypoint(value, source_size, target_size) -> Waypoint:
    """解析不同格式的航点"""
    if "pixelX" in value and "pixelY" in value:
        x, y = float(value["pixelX"]), float(value["pixelY"])
    elif "lat" in value and "lng" in value:
        # MaaNTE-Map 格式：world coordinates → map pixels
        map_x = origin_x + world_lng * ONLINE_PIXELS_PER_WORLD_UNIT
        map_y = origin_y - world_lat * ONLINE_PIXELS_PER_WORLD_UNIT
        x, y = map_x, map_y
    elif "x" in value and "y" in value:
        # 原始游戏坐标 → map pixels
        point = raw_coordinate_to_map(float(value["x"]), float(value["y"]))
        x, y = point[0], point[1]
    else:
        raise ValueError("waypoint needs pixelX/pixelY, lat/lng, or x/y")

    # 缩放适配
    return int(round(x * target_w / source_w)), int(round(y * target_h / source_h))
```

### 6.3 RouteRunner — 路线执行器

```python
# route_runner.py

class RouteRunner:
    def run_until_stopped(self, *, on_tick=None, stop_when_route_done=False) -> str:
        self.start()
        assert self.navigator is not None

        while not self.context.tasker.stopping:
            if on_tick is not None:
                on_tick()
            payload = self.route.payload()
            if not payload["active"]:
                if stop_when_route_done and payload["status"] in {"arrived", "cleared", "empty", "stopped"}:
                    return str(payload["status"])
                # 等待中：更新位置
                started = time.perf_counter()
                self.navigator.update()
                self.navigator.sleep_remaining(started)
                continue

            # 执行下一个航点
            with self.route.lock:
                current_index = self.route.current_index
                waypoints = list(self.route.waypoints)
            if current_index >= len(waypoints):
                with self.route.lock:
                    self.route.active = False
                    self.route.status = "arrived"
                continue

            target = waypoints[current_index]
            arrived = self.navigator.move_to(target)
            if arrived:
                self.route.advance()

        return "stopped"
```

### 6.4 WebSocket 路由服务

```python
# route_websocket_service.py

class RouteWebSocketService:
    """WebSocket 服务端，接收外部路由请求"""

    def __init__(self, route: RouteSession, *, port: int,
                 get_source_size, get_current_point):
        self.route = route
        self.websocket = NavigationWebSocketServer(port=port, message_handler=self.handle_message)

    def handle_message(self, message: dict) -> dict:
        return handle_route_message(message, self.route, source_size, current_point)


# route_model.py
def handle_route_message(message, route, source_size, current_point):
    message_type = str(message.get("type", "")).strip()
    if message_type in ("navi-route-set", "route-set"):
        route.reset(parse_waypoint_sequence(message.get("waypoints"), ...),
                    bool(message.get("start", False)), current_point)
    elif message_type in ("navi-route-add", "route-add"):
        route.waypoints.append(parse_waypoint(message, ...))
    elif message_type in ("navi-route-clear", "route-clear"):
        route.clear()
    elif message_type in ("navi-route-start", "route-start"):
        route.start(current_point)
    elif message_type in ("navi-route-stop", "route-stop"):
        route.stop()
    return {"type": "navi-route-ack", "ok": True, "route": route.payload()}
```

### 6.5 NavigationWebSocketServer

```python
# navigation_server.py

class NavigationWebSocketServer:
    def __init__(self, port="14514", message_handler=None):
        self._host = "0.0.0.0"
        self._port = int(port)
        self._state = {
            "type": "navi-state",
            "version": 1,
            "position": None,
            "angle": None,
            "pitch": None,
            "angleConfidence": 0.0,
            "route": {"waypoints": [], "active": False, "currentIndex": 0, "status": "idle"},
            "timestamp": 0.0,
        }

    def publish_state(self, coordinate, *, map_point, score, mode, source_size, angle, angle_confidence, pitch):
        with self._state_lock:
            self._state["position"] = {
                "x": float(coordinate[0]),
                "y": float(coordinate[1]),
                "score": float(score),
                "mode": mode,
                "pixelX": int(map_point[0]),
                "pixelY": int(map_point[1]),
                "sourceWidth": int(source_size[0]),
                "sourceHeight": int(source_size[1]),
            }
            if len(coordinate) >= 3:
                self._state["position"]["z"] = float(coordinate[2])
            self._state["angle"] = float(angle) if angle is not None else None
            self._state["pitch"] = float(pitch) if pitch is not None else None
            self._state["angleConfidence"] = float(angle_confidence)
            self._state["timestamp"] = time.time()
        self._schedule_broadcast()
```

---

## 七、自动排球

### 7.1 功能概述

自动排球是一个状态机驱动的小游戏自动化：
- 选择难度（1-4 级）
- 选择队友（7 个角色可选）
- 自动击球（每 0.6 秒按 K）
- 检测胜负并晋级

### 7.2 核心实现

```python
# auto_volleyball.py

_DIFFICULTY_ROIS = {
    1: (158, 254, 91, 86),
    2: (458, 337, 74, 77),
    3: (766, 264, 76, 75),
    4: (1067, 337, 69, 70),
}

_GAME_END_STATES = (
    ("skip", "Volleyball/SkipButton.png", (1223, 29, 28, 26)),
    ("win", "Volleyball/Win.png", (937, 71, 308, 110)),
    ("loss", "Volleyball/Lose.png", (879, 72, 363, 105)),
)

_CHARACTERS = {
    1: ("薄荷", (323, 94, 103, 76), (407, 166, 1, 1)),
    2: ("零", (443, 98, 89, 70), (519, 167, 1, 1)),
    3: ("娜娜莉", (554, 98, 89, 70), (633, 170, 1, 1)),
    4: ("残虹", (332, 208, 89, 69), (407, 276, 1, 1)),
    5: ("卡厄斯", (444, 209, 88, 68), (516, 279, 1, 1)),
    6: ("真红", (556, 208, 88, 70), (630, 278, 1, 1)),
    7: ("伊洛伊", (332, 318, 89, 70), (410, 386, 1, 1)),
}

@AgentServer.custom_action("volleyball_play")
class VolleyballPlay(CustomAction):
    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        controller = context.tasker.controller
        started_at = time.monotonic()
        next_key_at = started_at
        next_check_at = started_at + 5.0

        while not context.tasker.stopping:
            now = time.monotonic()

            # 定期按键（每 0.6 秒按 K）
            if now >= next_key_at:
                controller.post_click_key(0x4B).wait()  # K 键
                next_key_at = now + 0.6

            # 定期检查结果
            if now >= next_check_at:
                state = _match_state(context, controller.cached_image)
                if state in ("win", "loss", "skip"):
                    return CustomAction.RunResult(success=True)
                next_check_at = now + 5.0

            time.sleep(0.05)
```

---

## 八、俄罗斯方块 AI

### 8.1 AI 架构

```
TetrisGamePlayer
├── SceneGate (场景门控)
│   └── 检测游戏状态（游戏中/结果画面）
├── TetrisSceneDetector (场景检测)
│   └── 检测掉落就绪、结束画面
├── Board (棋盘管理)
│   ├── extract_board_crop()  # 提取棋盘区域
│   ├── simulate_drop()       # 模拟下落
│   └── evaluate_board()      # 评估局面
├── PIECES (方块定义)
│   └── {"I": [...], "O": [...], "J": [...], "L": [...], "S": [...], "T": [...], "Z": [...]}
└── AI 决策
    ├── _choose_best_current_piece_move()  # 当前方块决策
    └── _search_best_queue_move()          # 未来方块 lookahead
```

### 8.2 棋盘评估函数

```python
# Tetris/utils/board.py

def evaluate_board(board: np.ndarray, lines_cleared: int, dynamic_weights=True, combo_count=0, is_t_spin=False):
    heights = calculate_column_heights(board)
    holes, hole_depth, covered_holes, hard_holes = calculate_holes(board)
    row_transitions, col_transitions = calculate_transitions(board)
    well_penalty = calculate_well_penalty(heights)
    open_well_reward = calculate_open_well_reward(heights)
    center_stack_penalty = calculate_center_stack_penalty(heights)
    horizontal_balance_penalty = calculate_horizontal_balance_penalty(heights)
    aggregate_height = sum(heights)
    bumpiness = sum(abs(heights[i] - heights[i+1]) for i in range(len(heights)-1))

    # 动态权重：根据平均高度调整
    avg_height = aggregate_height / BOARD_COLS
    if avg_height < 8:
        lines_weight, holes_weight = 42.0, 32.0
        height_weight, bumpiness_weight = 0.95, 1.4
    elif avg_height < 14:
        lines_weight, holes_weight = 34.18, 38.99
        height_weight, bumpiness_weight = 1.30, 1.84
    else:
        lines_weight, holes_weight = 28.0, 52.0
        height_weight, bumpiness_weight = 1.85, 2.2

    score = (
        lines_cleared * lines_weight
        - aggregate_height * height_weight
        - holes * holes_weight
        - hard_holes * (holes_weight * 0.5)
        - bumpiness * bumpiness_weight
        - row_transitions * transitions_weight
        - col_transitions * (transitions_weight * 2.9)
        - well_penalty * well_weight
        + open_well_reward * open_well_weight
        - center_stack_penalty * center_stack_weight
        - horizontal_balance_penalty * balance_weight
    )

    if combo_count > 1:
        score += combo_count * 25.0
    if is_t_spin:
        score += lines_cleared * 30.0 + 40.0

    return score
```

### 8.3 T-Spin 检测

```python
def detect_t_spin(board, piece_name, rotation, target_col, drop_row, was_rotation_move=True):
    """检测 T 方块的 T-Spin 和 Mini T-Spin"""
    if piece_name != "T":
        return {"is_t_spin": False, "is_mini": False}

    t_shape = PIECES["T"][rotation]

    # 前方角落偏移（根据旋转状态）
    front_corner_offsets = {
        0: [(-1, -1), (-1, 1)],
        1: [(-1, 1), (1, 1)],
        2: [(1, -1), (1, 1)],
        3: [(-1, -1), (1, -1)],
    }
    back_corner_offsets = {
        0: [(1, -1), (1, 1)],
        1: [(-1, -1), (1, -1)],
        2: [(-1, -1), (-1, 1)],
        3: [(1, -1), (1, 1)],
    }

    front_blocked = sum(1 for dr, dc in front_corner_offsets[rotation]
                        if not _can_place_at(board, drop_row+dr, target_col+dc))
    back_blocked = sum(1 for dr, dc in back_corner_offsets[rotation]
                       if not _can_place_at(board, drop_row+dr, target_col+dc))

    if was_rotation_move:
        is_t_spin = front_blocked >= 2 and (front_blocked + back_blocked) >= 3
        is_mini = not is_t_spin and front_blocked >= 2
    else:
        is_t_spin = False
        is_mini = (front_blocked + back_blocked) >= 3

    return {"is_t_spin": is_t_spin, "is_mini": is_mini}
```

### 8.4 Beam Search 前瞻决策

```python
def _choose_best_current_piece_move(self, board, piece_state, planning_queue):
    """使用 Beam Search + 前瞻评估选择最佳落点"""
    occupancy = np.count_nonzero(board) / (BOARD_ROWS * BOARD_COLS)

    # 自适应深度：根据棋盘占用率调整
    if occupancy < 0.25:
        adaptive_depth = 2
    elif occupancy > 0.55:
        adaptive_depth = 4
    elif occupancy > 0.4:
        adaptive_depth = 3
    else:
        adaptive_depth = 2

    beam_width = 6 if len(planning_queue) >= 2 else 5

    best_move = None
    for rotation_index, shape in enumerate(PIECES[piece_name]):
        width = max(col for _, col in shape) + 1
        for target_col in range(0, BOARD_COLS - width + 1):
            if not self._is_move_feasible(board, piece_name, from_rot, from_col, from_row, rotation_index, target_col):
                continue
            result = simulate_drop(board, shape, target_col)
            if result is None:
                continue

            # T-Spin 检测
            is_t_spin = False
            if piece_name == "T":
                t_spin_result = detect_t_spin(board, piece_name, rotation_index, target_col, result["row"], rot_dist > 0)
                is_t_spin = t_spin_result["is_t_spin"]

            # 前瞻未来方块
            future_bonus = 0.0
            if planning_queue[1:]:
                future_move = self._search_best_queue_move(result["board"], planning_queue[1:], max_depth=adaptive_depth, beam_width=beam_width)
                if future_move is not None:
                    future_weight = 0.7 if result["lines_cleared"] > 0 else 0.5
                    if is_t_spin:
                        future_weight = 0.8
                    future_bonus = future_move["total_score"] * future_weight

            # 执行代价惩罚
            rot_dist = rotation_distance(piece_name, from_rot, rotation_index)
            shift_dist = abs(target_col - from_col)
            execution_penalty = rot_dist * 0.15 + shift_dist * 0.06
            if rot_dist > 0 and shift_dist > 4:
                execution_penalty += 0.15

            current_score = evaluate_board(result["board"], result["lines_cleared"], dynamic_weights=True, combo_count=combo_count, is_t_spin=is_t_spin)
            total_score = current_score + future_bonus - execution_penalty

            move = {"rotation": rotation_index, "target_col": target_col, "score": current_score, "total_score": total_score, ...}
            if best_move is None or total_score > best_move["total_score"]:
                best_move = move

    return best_move


def _search_best_queue_move(self, board, queue_pieces, depth=0, max_depth=2, beam_width=5, combo_count=0):
    """递归 Beam Search 评估未来方块序列"""
    if not queue_pieces:
        return None

    occupancy = np.count_nonzero(board) / (BOARD_ROWS * BOARD_COLS)
    adaptive_depth = max_depth
    if occupancy > 0.55:
        adaptive_depth = min(max_depth + 2, 5)
    elif occupancy > 0.4:
        adaptive_depth = min(max_depth + 1, 4)

    adaptive_beam = beam_width
    if len(queue_pieces) >= 3:
        adaptive_beam = min(beam_width + 2, 8)
    elif occupancy > 0.45:
        adaptive_beam = min(beam_width + 1, 7)

    piece_name = queue_pieces[0]
    candidates = []
    for rotation_index, shape in enumerate(PIECES[piece_name]):
        width = max(col for _, col in shape) + 1
        for target_col in range(0, BOARD_COLS - width + 1):
            result = simulate_drop(board, shape, target_col)
            if result is None:
                continue

            # 评估当前落点
            if depth == 0:
                eval_score = evaluate_board(result["board"], result["lines_cleared"], dynamic_weights=True, combo_count=combo_count+1)
            else:
                eval_score = evaluate_board_fast(result["board"], result["lines_cleared"], combo_count=combo_count+1)

            candidates.append({"rotation": rotation_index, "target_col": target_col, "score": eval_score, "board": result["board"], ...})

    # Beam 剪枝
    candidates.sort(key=lambda c: c["score"], reverse=True)
    search_candidates = candidates[:adaptive_beam]

    best_choice = None
    for candidate in search_candidates:
        total_score = candidate["score"]
        if depth + 1 < adaptive_depth and len(queue_pieces) > 1:
            future = self._search_best_queue_move(candidate["board"], queue_pieces[1:], depth+1, adaptive_depth, adaptive_beam, combo_count+1)
            if future is not None:
                future_value = future["total_score"]
                depth_discount = 0.85 ** (depth + 1)
                future_weight = 0.7 if candidate["lines_cleared"] > 0 else 0.5
                total_score = candidate["score"] + future_value * future_weight * depth_discount

        enriched = dict(candidate)
        enriched["total_score"] = total_score
        if best_choice is None or total_score > best_choice["total_score"]:
            best_choice = enriched

    return best_choice
```

### 8.5 按键执行

```python
def _apply_move_no_feedback(self, controller, target_rotation, target_col):
    """无反馈移动执行"""
    rotation_count = len(PIECES[self.current_piece_name])

    # 选择最短旋转路径
    clockwise_steps = (target_rotation - self.current_rotation) % rotation_count
    counterclockwise_steps = (self.current_rotation - target_rotation) % rotation_count

    if clockwise_steps <= counterclockwise_steps:
        for _ in range(clockwise_steps):
            self._tap_key(controller, VK_K, hold=0.02)  # 顺时针旋转
            time.sleep(0.02)
            self.current_rotation = (self.current_rotation + 1) % rotation_count
    else:
        for _ in range(counterclockwise_steps):
            self._tap_key(controller, VK_J, hold=0.02)  # 逆时针旋转
            time.sleep(0.02)
            self.current_rotation = (self.current_rotation - 1) % rotation_count

    # 水平移动
    col_diff = target_col - self.current_col
    for _ in range(abs(col_diff)):
        self._tap_key(controller, VK_D if col_diff > 0 else VK_A, hold=0.02)
        time.sleep(0.02)
        self.current_col += (1 if col_diff > 0 else -1)
```

---

## 九、节奏游戏

### 9.1 架构

```
AutoRhythmPlay
├── DrumDetector (鼓面检测)
│   └── CNN 模型检测 4 条轨道的鼓面位置
├── LaneLayout (轨道布局)
│   └── build_lane_layout(cfg, width, height)
├── SceneGate (场景门控)
│   └── 检测是否在游戏进行中
└── _KeyScheduler (按键调度)
    ├── press(lanes)      # 按下按键
    ├── schedule()        # 调度未来按键
    └── fire_due()        # 触发到期的按键
```

### 9.2 轨道布局

```python
# rhythm/utils/lanes.py

@dataclass
class LaneLayout:
    frame_w: int
    frame_h: int
    center_x: list[int]        # 4 条轨道的中心 x 坐标
    half_width_px: int         # 轨道半宽
    judge_y0_by_lane: list[int] # 判定线上沿
    judge_y1_by_lane: list[int] # 判定线下沿


def build_lane_layout(cfg, frame_w, frame_h) -> LaneLayout:
    lanes = cfg.get("lanes") or {}
    centers = list(lanes.get("center_x_frac") or [0.225, 0.406, 0.596, 0.771])
    half_w_frac = float(lanes.get("half_width_frac", 0.028))
    judge_y = float(lanes.get("judge_line_y_frac", 0.82))
    band_half = max(2, int(round(float(lanes.get("judge_band_half_height_frac", 0.035)) * frame_h)))
    half_width_px = max(2, int(round(half_w_frac * frame_w)))

    judge_y0_by_lane = [int(round(float(judge_y_by_lane[i]) * frame_h)) - band_half for i in range(4)]
    judge_y1_by_lane = [int(round(float(judge_y_by_lane[i]) * frame_h)) + band_half for i in range(4)]
    center_x = [int(round(top_centers[i] + (bottom_centers[i] - top_centers[i]) * (judge_y0/i / frame_h))) for i in range(4)]

    return LaneLayout(frame_w, frame_h, center_x, half_width_px, judge_y0_by_lane, judge_y1_by_lane)
```

### 9.3 鼓面检测

```python
# rhythm/utils/detector.py

class DrumDetector:
    def analyze(self, frame_bgr, layout) -> tuple[list[float], list[list[DrumCandidate]]]:
        """并行检测 4 条轨道的鼓面位置"""
        scores = [0.0] * 4
        candidates_by_lane = [[], [], [], []]

        futures = {}
        for i in range(4):
            future = self._executor.submit(self._match_lane, i, frame_bgr, layout)
            futures[future] = i

        for future in futures:
            idx = futures[future]
            score, candidates = future.result()
            scores[idx] = score
            candidates_by_lane[idx] = candidates

        return scores, candidates_by_lane

    def _match_lane(self, lane_idx, frame_bgr, layout):
        """单条轨道的模板匹配"""
        tpl = self._templates[lane_idx]
        if tpl is None:
            return 0.0, []

        cx = layout.center_x[lane_idx]
        half_w = int(round(layout.half_width_px * self._region_width_multiplier))
        jy0 = layout.judge_y0_by_lane[lane_idx]
        jy1 = layout.judge_y1_by_lane[lane_idx]
        extend_up = int(self._region_extend_up_frac * layout.frame_h)
        extend_down = max(4, int(self._region_extend_down_frac * layout.frame_h))

        rx0 = max(0, cx - half_w)
        rx1 = min(layout.frame_w, cx + half_w)
        ry0 = max(0, jy0 - extend_up)
        ry1 = min(layout.frame_h, jy1 + extend_down)

        roi = frame_bgr[ry0:ry1, rx0:rx1]
        result = cv2.matchTemplate(roi, tpl, cv2.TM_CCOEFF_NORMED)
        _, max_val, _, max_loc = cv2.minMaxLoc(result)

        # NMS 去重
        candidates = []
        for y, x in zip(*np.where(result >= threshold)):
            candidate = DrumCandidate(score=float(result[y, x]), center_x=float(rx0+x+tpl_w/2), center_y=float(ry0+y+tpl_h/2))
            if not any(abs(candidate.center_y - kept.center_y) < self._candidate_nms_distance_px for kept in candidates):
                candidates.append(candidate)

        return float(max_val), candidates[:self._max_candidates_per_lane]
```

### 9.4 按键调度

```python
class _KeyScheduler:
    def fire_due(self, now):
        """触发到期的按键，支持 chords"""
        self._pending.sort(key=lambda item: item[0])
        anchor_item = next((item for item in self._pending if item[0] <= now), None)
        if anchor_item is None:
            return []

        anchor_due, _, anchor_target, _, _ = anchor_item
        due = []
        remaining = []
        for item in self._pending:
            due_time, _, target_time, _, _ = item
            # chord 判断：在同一时间窗口内的视为和弦
            same_chord = abs(target_time - anchor_target) <= self._chord_window_sec or due_time <= anchor_due + self._chord_window_sec
            if same_chord:
                due.append(item)
            else:
                remaining.append(item)
        self._pending = remaining

        lanes = []
        fired = []
        for due_time, lane_idx, target_time, center_y, score in due:
            next_allowed = self._last_tap_time[lane_idx] + self._min_tap_interval_by_lane[lane_idx]
            if now < next_allowed:
                continue
            lanes.append(lane_idx)
            fired.append((lane_idx, target_time, center_y, score))

        if lanes:
            self.press(lanes, now)
        return fired
```

---

## 十、音频驱动闪避

### 10.1 架构

```
SoundDodgeAction
├── Ear (音频监听)
│   ├── sample_path: sounds/dodge.wav
│   ├── counter_path: sounds/counter.wav
│   ├── threshold: 0.13
│   └── counter_threshold: 0.12
├── Dodger (闪避执行)
│   ├── dodge()    # 执行闪避
│   └── counter()  # 执行反击
└── 线程模型
    ├── Ear 线程：音频检测
    └── 主线程：按键执行
```

### 10.2 Ear 音频检测

```python
# SoundListener.py

class Ear:
    sr = 32000          # 采样率
    ch = 2              # 声道数
    chunk = 1600        # 每块采样数
    sample_len = 0.2    # 分析窗口长度（秒）
    interval = 0.05     # 窗口滑动间隔（秒）

    def __init__(self, sample_path, counter_path, threshold=0.13, counter_threshold=0.12, stop_check=None):
        self.threshold = threshold
        self.counter_threshold = counter_threshold
        self._sample = self._cache_load(sample_path)   # 加载闪避音效模板
        self._counter = self._cache_load(counter_path) # 加载反击音效模板
        # 加载高通滤波器（去除低频噪音）
        self._b, self._a = butter(4, 1000, btype="highpass", output="ba", fs=self.sr)

    def match(self, stream, sample):
        """使用 FFT 互相关检测音频相似度"""
        stream_filtered = self._filt(stream)
        sample_filtered = self._filt(sample)
        s1 = self._norm(stream_filtered)
        s2 = self._norm(sample_filtered)

        if s1.shape[0] > s2.shape[0]:
            corr = correlate(s1, s2, mode="same", method="fft") / s1.shape[0]
        else:
            corr = correlate(s2, s1, mode="same", method="fft") / s2.shape[0]

        return np.max(corr)

    def _loop(self):
        """音频采集循环"""
        mic = sc.get_microphone(id=str(speaker.name), include_loopback=True)
        buf = np.zeros(max_s * 2, dtype=np.float64)  # 环形缓冲区
        pos = 0

        while self._running.is_set():
            # 采集音频块
            frame = np.empty(new_s, dtype=np.float64)
            for _ in range(chunks):
                data = rec.record(numframes=self.chunk)
                frame[idx:idx+self.chunk] = librosa.to_mono(data.T)
                idx += self.chunk

            # 写入环形缓冲区
            end = pos + new_s
            if end <= max_s * 2:
                buf[pos:end] = frame
            else:
                first = max_s * 2 - pos
                buf[pos:] = frame[:first]
                buf[:end-max_s*2] = frame[first:]
            pos = end % (max_s * 2)

            # 分析窗口
            if pos >= max_s:
                win = buf[pos-max_s:pos]
            else:
                win = np.concatenate([buf[-(max_s-pos):], buf[:pos]])

            d_score = self.match(win, self._sample)
            c_score = self.match(win, self._counter) if self._counter else 0.0
            self._check(d_score, c_score)

    def _check(self, d_score, c_score):
        """判断是否触发闪避或反击"""
        if time.time() - self._last_trigger < self._trigger_cd:
            return

        dodge_hit = d_score >= self.threshold
        counter_hit = c_score >= self.counter_threshold
        dodge_confidence = d_score / max(self.threshold, 1e-6)
        counter_confidence = c_score / max(self.counter_threshold, 1e-6)

        if dodge_hit and (not counter_hit or dodge_confidence >= counter_confidence):
            self._last_trigger = time.time()
            if self.on_dodge:
                self.on_dodge()
            return

        if counter_hit:
            self._last_trigger = time.time()
            if self.on_counter:
                self.on_counter()
```

### 10.3 Dodger 执行

```python
# DodgeCounterTrigger.py

class Dodger:
    def __init__(self, controller=None, dodge_fn=None, counter_fn=None, stop_check=None):
        self.controller = controller
        self.dodge_fn = dodge_fn or self._default_dodge
        self.counter_fn = counter_fn or self._default_counter
        self._dodge_cd = 0.5     # 闪避冷却 0.5 秒
        self._counter_cd = 1.0   # 反击冷却 1.0 秒

    def dodge(self):
        """执行闪避（按左 Shift）"""
        if time.time() - self._last_dodge < self._dodge_cd:
            return
        self._last_dodge = time.time()
        self.dodge_fn()

    def _default_dodge(self):
        """默认闪避：按左 Shift"""
        self.controller.post_click_key(VK_SHIFT)  # 0xA0
        time.sleep(0.1 + random.random() * 0.1)
        self.controller.post_click_key(VK_SHIFT)

    def counter(self):
        """执行反击（按随机数字键 + Shift）"""
        if time.time() - self._last_counter < self._counter_cd:
            return
        self._last_counter = time.time()
        self.counter_fn()

    def _default_counter(self):
        """默认反击：随机按 1-4 + Shift"""
        key = random.choice([0x31, 0x32, 0x33, 0x34])
        self.controller.post_click_key(key)
        time.sleep(0.02)
        self.controller.post_click_key(VK_SHIFT)
```

---

## 十一、粉爪大劫案

### 11.1 三阶段架构

```
pinkpaw_core1.py  →  Core1 阶段（进入、战斗、开门）
pinkpaw_core2.py  →  Core2 阶段（ deeper 探索、激光躲避）
pinkpaw_core3.py  →  Core3 阶段（藏品收集、最终撤离）
```

### 11.2 ActionHelper（Core1/Core2 共用）

```python
# pinkpaw_core1.py / pinkpaw_core2.py

class ActionHelper:
    def __init__(self, ctx: Context):
        self.ctx = ctx
        self.mx, self.my = 640, 360  # 当前鼠标位置

    def click_key(self, key_str):
        """发送按键点击"""
        vk = VK.get(key_str)
        param = {"key": vk}
        node_name = f"PinkPawHeist_ClickKey"
        override = {node_name: {"action": {"type": "ClickKey", "param": param}}}
        return self.ctx.run_task(node_name, pipeline_override=override) is not None

    def key_down(self, key_str):
        """按住按键"""
        vk = VK.get(key_str)
        param = {"key": vk}
        node_name = f"PinkPawHeist_KeyDown"
        override = {node_name: {"action": {"type": "KeyDown", "param": param}}}
        return self.ctx.run_task(node_name, pipeline_override=override) is not None

    def key_up(self, key_str):
        """释放按键"""
        vk = VK.get(key_str)
        param = {"key": vk}
        node_name = f"PinkPawHeist_KeyUp"
        override = {node_name: {"action": {"type": "KeyUp", "param": param}}}
        return self.ctx.run_task(node_name, pipeline_override=override) is not None

    def move_to(self, x, y, duration_ms=None):
        """鼠标移动到指定坐标"""
        dx, dy = x - self.mx, y - self.my
        if dx * dx + dy * dy < 4:
            self.mx, self.my = x, y
            return True
        if duration_ms is None:
            duration_ms = max(int((dx**2 + dy**2) ** 0.5 / 0.5), 50)
        override = {"PinkPawHeist_MouseMove": {"action": {"type": "Swipe", "param": {"begin": [self.mx, self.my], "end": [x, y], "duration": duration_ms, "only_hover": True}}}}
        ret = self.ctx.run_task("PinkPawHeist_MouseMove", pipeline_override=override)
        if ret:
            self.mx, self.my = x, y
        return ret

    def wait_gate(self, timeout=10000):
        """等待铁门打开"""
        start = time.monotonic()
        while time.monotonic() - start < timeout / 1000.0:
            if _is_hit(self.ctx.run_task("PinkPawHeist_CheckGateOnce")):
                return True
            time.sleep(0.2)
        return False

    def wait_evacuate(self, timeout=15000):
        """等待撤离点出现"""
        start = time.monotonic()
        while time.monotonic() - start < timeout / 1000.0:
            if _is_hit(self.ctx.run_task("PinkPawHeist_CheckEvacuateOnce")):
                return True
            time.sleep(0.2)
        return False

    def fight_until_no_monster(self, timeout_no_monster=5000, wait_for_monster=True, role_to_switch_back=None, loot=False, attack_cycles=3):
        """打怪主循环"""
        if wait_for_monster:
            if not self.wait_monster(timeout=timeout_no_monster):
                return False

        no_monster_start = None
        while True:
            if self.check_monster():
                no_monster_start = None
                self.attack_cycle(times=attack_cycles, loot=loot)
            else:
                now = time.monotonic()
                if no_monster_start is None:
                    no_monster_start = now
                elif now - no_monster_start >= timeout_no_monster / 1000.0:
                    break
                time.sleep(0.05)

        if role_to_switch_back:
            for _ in range(3):
                self.click_key(role_to_switch_back)
                time.sleep(0.2)
        return True
```

### 11.3 Core3 高级特性

Core3 相比 Core1/Core2 增加了大量高级功能：

```python
# pinkpaw_core3.py

class Core3ActionHelper:
    """Core3 增强版 ActionHelper，支持 DirectInput"""

    def __init__(self, ctx: Context, direct_input=True):
        self.direct_input = DirectInputSender(enabled=direct_input)

    def _call_key(self, node_type, key_str, extra=None):
        """按键发送：优先 DirectInput，fallback 到 MAA 节点"""
        vk = VK.get(_norm_key(key_str))
        direct = self.direct_input
        if direct.available:
            if node_type == "KeyDown":
                return direct.key_down(vk)
            if node_type == "KeyUp":
                return direct.key_up(vk)
            if node_type == "ClickKey":
                return direct.click_key(vk, duration=float(extra.get("direct_duration", 0.01)))
        # Fallback to MAA controller
        controller = self.controller
        if controller is not None:
            if node_type == "KeyDown":
                controller.post_key_down(vk)
            elif node_type == "KeyUp":
                controller.post_key_up(vk)
            elif node_type == "ClickKey":
                controller.post_click_key(vk)


class DirectInputSender:
    """使用 Windows SendInput API 直接发送键盘/鼠标事件"""

    def __init__(self, enabled=True):
        self.user32 = None
        if enabled:
            try:
                self.user32 = ctypes.windll.user32
                self.user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(_INPUT), ctypes.c_int]
                self.user32.SendInput.restype = wintypes.UINT
                self.available = True
            except Exception as exc:
                print(f"[PinkPawHeist/Core3][WARN] direct input unavailable: {exc}")

    def key_down(self, vk):
        input_obj = self._keyboard_input(vk, is_up=False)
        return self._send(input_obj)

    def key_up(self, vk):
        input_obj = self._keyboard_input(vk, is_up=True)
        return self._send(input_obj)

    def click_key(self, vk, duration=0.01):
        if not self.key_down(vk):
            return False
        try:
            time.sleep(max(float(duration), 0.0))
            return self.key_up(vk)
        finally:
            if not self.key_up(vk):
                self.key_up(vk)
```

### 11.4 Core3 快速识别

```python
# pinkpaw_core3.py

FAST_RECO_CONFIG = {
    "PinkPawHeist_Core3_CheckInteractPinkOnce": {
        "type": "color",
        "roi": [650, 240, 520, 460],
        "lower_bgr": [119, 71, 197],
        "upper_bgr": [133, 78, 221],
        "count": 80,
        "stride": 4,
    },
    "PinkPawHeist_Core3_CheckInteractTemplateOnce": {
        "type": "template",
        "roi": [680, 250, 430, 430],
        "templates": ["interactable.png", "heist_interac_lock_pick.png"],
        "threshold": 0.62,
        "cv_threshold": 0.88,
    },
    "PinkPawHeist_Core3_CheckSafeLockPromptOnce": {
        "type": "template",
        "roi": [680, 250, 430, 430],
        "templates": ["heist_interac_lock_pick.png"],
        "threshold": 0.56,
        "cv_threshold": 0.90,
    },
    "PinkPawHeist_Core3_CheckLockPickActiveTemplateOnce": {
        "type": "template",
        "roi": [720, 260, 360, 260],
        "templates": ["heist_lock_pick.png"],
        "threshold": 0.40,
        "cv_threshold": 0.86,
    },
}


def _fast_color_match(image, cfg):
    """本地颜色匹配，替代 MAA 颜色识别节点"""
    roi = _crop_roi(image, cfg["roi"])
    stride = max(1, int(cfg.get("stride", 1)))
    if stride > 1:
        roi = roi[::stride, ::stride]
    lower = np.asarray(cfg["lower_bgr"], dtype=np.uint8)
    upper = np.asarray(cfg["upper_bgr"], dtype=np.uint8)
    mask = np.all((roi >= lower) & (roi <= upper), axis=2)
    count = max(1, int(cfg.get("count", 1)) // (stride * stride))
    return int(mask.sum()) >= count


def _fast_template_match(image, cfg):
    """本地模板匹配，替代 MAA 模板识别节点"""
    roi = _crop_roi(image, cfg["roi"])
    threshold = float(cfg.get("cv_threshold", cfg["threshold"]))
    roi = np.ascontiguousarray(roi)
    for name in cfg["templates"]:
        template = _load_fast_template(name)
        if template is None:
            continue
        scores = cv2.matchTemplate(roi, template["cv_bgr"], cv2.TM_CCORR_NORMED, mask=template["cv_mask"])
        finite_scores = scores[np.isfinite(scores)]
        if finite_scores.size == 0:
            continue
        if float(np.max(finite_scores)) >= threshold:
            return True
    return None
```

### 11.5 Core3 角色检测

```python
def _current_char_roi_score(self, image, roi, index):
    """计算指定角色槽位的高亮分数"""
    crop = _crop_roi(image, _scale_roi(roi, image))
    if crop is None:
        return 0
    max_ch = crop.max(axis=2)
    min_ch = crop.min(axis=2)
    sat = max_ch - min_ch
    white_threshold = CURRENT_CHAR_SLOT_WHITE_THRESHOLDS[index]
    colored_threshold = CURRENT_CHAR_SLOT_COLORED_THRESHOLDS[index]
    white = (max_ch >= white_threshold) & (sat <= 65)
    colored = (max_ch >= colored_threshold) & (sat >= 55)
    return int((white | colored).sum())


def get_current_char_index(self, image=None):
    """返回当前高亮的角色槽位索引"""
    if image is None:
        image = self._screencap()
    scores = self._current_char_scores(image)
    if not scores:
        return -1
    best_idx = max(range(len(scores)), key=lambda idx: scores[idx])
    if self._is_current_char_score_accepted(scores, best_idx):
        return best_idx
    return -1
```

---

## 十二、自动钢琴

### 12.1 架构

```
AutoPlayPiano
├── MidiProcessor (MIDI 解析)
│   └── 解析 .mid/.midi 文件，提取音符序列
├── KeyMapping (键位映射)
│   ├── 36键模式：QWERTYUI + ASDFGHJ + ZXCVBNM + Shift/Ctrl
│   └── 21键模式：仅白键
├── AutoPianoPlayer (播放器)
│   └── 按节奏播放音符
└── MaaKeyboardBridge (键盘桥接)
    └── 通过 PostMessage 发送按键
```

### 12.2 MIDI 解析

```python
# auto_piano/midi_processor.py

class MidiProcessor:
    def parse(self, file_path: str, tracks: str | list[int] = "all") -> dict:
        mid = mido.MidiFile(file_path, clip=True)

        # 收集所有事件并按时间排序
        all_events = []
        for idx, track in enumerate(mid.tracks):
            abs_tick = 0
            for msg in track:
                abs_tick += msg.time
                all_events.append((abs_tick, idx, msg))
        all_events.sort(key=lambda x: x[0])

        # 解析音符
        tempo = 500000  # 默认 120 BPM
        active_notes = {}  # (track, channel, note) → (start_time, order)
        notes = []
        note_sequence = 0

        for abs_tick, idx, msg in all_events:
            # tick → second 转换
            if abs_tick > last_tick:
                delta_tick = abs_tick - last_tick
                current_sec += mido.tick2second(delta_tick, mid.ticks_per_beat, tempo)
                last_tick = abs_tick

            if msg.type == "set_tempo":
                tempo = msg.tempo
                continue
            if idx not in track_indices:
                continue
            if msg.type == "note_on" and msg.velocity > 0:
                ch = getattr(msg, "channel", 0)
                if ch == 9:  # 跳过打击乐
                    continue
                key = (idx, ch, msg.note)
                active_notes[key] = (current_sec, note_sequence)
                note_sequence += 1
            elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
                ch = getattr(msg, "channel", 0)
                if ch == 9:
                    continue
                key = (idx, ch, msg.note)
                if key in active_notes:
                    start, order = active_notes.pop(key)
                    notes.append({"t": start, "p": key[2], "d": max(0.0, current_sec - start), "_order": order})

        notes.sort(key=lambda n: (n["t"], n["_order"]))
        return {"title": os.path.basename(file_path), "notes": notes, "bpm": ..., "duration": ...}
```

### 12.3 键位映射

```python
# auto_piano/key_mapping.py

NOTE_KEY_MAPPING = {
    # 低音 C4(60) ~ B4(71)
    60: "z",          # C4
    61: "shift+z",    # C#4
    62: "x",          # D4
    63: "ctrl+c",     # D#4
    64: "c",          # E4
    65: "v",          # F4
    66: "shift+v",    # F#4
    67: "b",          # G4
    68: "shift+b",    # G#4
    69: "n",          # A4
    70: "ctrl+m",     # A#4
    71: "m",          # B4
    # 中音 C5(72) ~ B5(83)
    72: "a", 73: "shift+a", 74: "s", 75: "ctrl+d", 76: "d", 77: "f",
    78: "shift+f", 79: "g", 80: "shift+g", 81: "h", 82: "ctrl+j", 83: "j",
    # 高音 C6(84) ~ B6(95)
    84: "q", 85: "shift+q", 86: "w", 87: "ctrl+e", 88: "e", 89: "r",
    90: "shift+r", 91: "t", 92: "shift+t", 93: "y", 94: "ctrl+u", 95: "u",
}

NOTE_KEY_MAPPING_WHITE = {
    60: "z", 62: "x", 64: "c", 65: "v", 67: "b", 69: "n", 71: "m",
    72: "a", 74: "s", 76: "d", 77: "f", 79: "g", 81: "h", 83: "j",
    84: "q", 86: "w", 88: "e", 89: "r", 91: "t", 93: "y", 95: "u",
}
```

### 12.4 播放执行

```python
# auto_piano/maa_keyboard.py

class MaaKeyboardBridge:
    """通过 PostMessage 向游戏窗口发送按键"""

    def __init__(self, mapping=None, hold_seconds=0.008):
        self.mapping = mapping or NOTE_KEY_MAPPING
        self.hold_seconds = hold_seconds
        self.hwnd = 0
        for title in ["NTE  ", "异环  "]:
            self.hwnd = user32.FindWindowW(None, title)
            if self.hwnd:
                break

    def execute_chord(self, midi_notes):
        """播放一个和弦（同时按多个键）"""
        self._activate()
        normal_keys, shift_keys, ctrl_keys = [], [], []
        for note in midi_notes:
            if note not in self.mapping:
                continue
            action = self.mapping[note]
            key = action.split("+")[-1]
            if "shift+" in action:
                shift_keys.append(key)
            elif "ctrl+" in action:
                ctrl_keys.append(key)
            else:
                normal_keys.append(key)

        self._press_group(normal_keys)
        self._press_group(shift_keys, "shift")
        self._press_group(ctrl_keys, "ctrl")

    def _press_group(self, keys, modifier=None):
        if modifier and modifier in WIN32_VK:
            self._force_send_key(WIN32_VK[modifier], True)
            time.sleep(0.002)
        vk_codes = [WIN32_VK[key] for key in keys if key in WIN32_VK]
        for vk in vk_codes:
            self._force_send_key(vk, True)
        if self.hold_seconds > 0:
            time.sleep(self.hold_seconds)
        for vk in reversed(vk_codes):
            self._force_send_key(vk, False)
        if modifier and modifier in WIN32_VK:
            time.sleep(0.001)
            self._force_send_key(WIN32_VK[modifier], False)

    def _force_send_key(self, vk_code, is_down):
        """通过 PostMessage 发送按键"""
        if not self.hwnd:
            return
        scan_code = user32.MapVirtualKeyW(vk_code, 0)
        lparam = 1 | (scan_code << 16)
        if not is_down:
            lparam |= 0xC0000000
        msg = WM_KEYDOWN if is_down else WM_KEYUP
        user32.PostMessageW(self.hwnd, msg, vk_code, lparam)
```

---

## 十三、贝果 spam（LLM 发帖）

### 13.1 架构

```
BagelSpamLLMGenerate (CustomRecognition)
├── 截图 → base64
├── 调用 OpenAI 兼容 API
├── 解析 JSON 输出
└── 存入模块级变量 (_bagel_spam_llm_title, _bagel_spam_llm_body)

BagelSpamOutputText (CustomAction)
├── 读取 LLM 生成结果（或预设文本）
└── 通过 controller.post_input_text() 输出
```

### 13.2 Prompt 设计

```python
_BASE_PROMPT_PREFIX = (
    "你是一个正在游玩《异环》（Neverness to Everness / NTE）的资深玩家，准备在游戏内的「贝果」社区发帖分享。\n"
    "请仔细观察提供的游戏截图，并严格遵循以下步骤生成内容：\n\n"
    "1. 【提取画面视觉焦点（无相干UI屏蔽）】\n"
    "   - 除非截图核心是明显的系统结算（如抽卡结果、物品掉落、搞笑文本提示），否则必须主动忽略"发布帖子"、"0/40"等外层发帖UI。\n"
    "   - 找出画面真正的核心：是某个角色？一辆车？一处都市建筑？一种异常发光现象？还是一个明显的系统Bug？\n\n"
    "2. 【角色与专有名词安全锁】\n"
    "   - 绝对不准"看图编名"。如果不100%确定角色、车辆或怪物的官方名称，强制使用通用代称（如"这套衣服"、"这辆车"、"这怪物"）。\n\n"
    "3. 【匹配《异环》全域场景与玩家情绪】\n"
    "   - [都市生活/载具类]：表现出对都市沉浸感的赞叹\n"
    "   - [角色/外观/展示类]：表现出玩家对角色的喜爱\n"
    "   - [战斗/异象/探索类]：表现出战斗的爽快感\n"
    "   - [系统/事件/整活类]：如果是出金则疯狂炫耀；如果是Bug则调侃\n\n"
    "4. 【语言与排版规范】\n"
    "   - 必须是纯正的玩家第一人称口吻，杜绝AI味\n"
    "   - 标题要求吸睛（5~15个字）；正文要求随性、口语化（1~3句话）"
)

_BASE_PROMPT_SUFFIX = (
    "请直接输出严格的 JSON 格式，不要包含任何 Markdown 标记或代码块符号。必须以 '{' 开头，以 '}' 结尾。\n"
    '格式示例：{"observation": "画面焦点是一个角色卡在墙里，判定为[系统/事件/整活类]的Bug场景", "title": "标题", "body": "正文"}'
)
```

### 13.3 LLM 调用

```python
def _call_llm(api_base, model, api_key, prompt, image_b64) -> dict | None:
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image_b64}"}}
            ]
        }],
        "response_format": {"type": "json_object"},
    }
    resp = requests.post(f"{api_base.rstrip('/')}/chat/completions", headers=headers, json=payload, timeout=300)
    resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]
    result = _extract_json(content)
    return {"title": result["title"], "body": result["body"]}
```

---

## 十四、实时辅助

### 14.1 RealTimeTaskAction

```python
# realtime_task.py

HOLDER_NODE_NAME = "__RealTimeTaskAction_Holder"

@AgentServer.custom_action("RealTimeTaskAction")
class RealTimeTaskAction(CustomAction):
    """动态切换后续执行节点，实现实时辅助功能"""
    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        nodes = _parse_nodes(argv.custom_action_param)  # ["NodeA", "NodeB", ...]
        pipeline_override = {HOLDER_NODE_NAME: {"next": nodes}}

        while not context.tasker.stopping:
            result = context.run_task(HOLDER_NODE_NAME, pipeline_override)
            if result is None:
                continue

        return CustomAction.RunResult(success=True)
```

### 14.2 自动传送

```python
# MapTeleport/check_teleport_required.py

@AgentServer.custom_action("check_teleport_required")
class CheckTeleportRequiredAction(CustomAction):
    """检测当前场景是否需要传送"""
    def run(self, context, argv):
        # 检测当前场景是否为目标场景
        # 如果不在，返回 True 触发传送
        pass

# MapTeleport/teleport_to_point.py

@AgentServer.custom_action("teleport_to_point")
class TeleportDecision(CustomAction):
    """执行传送"""
    def run(self, context, argv):
        # 1. 打开地图
        # 2. 搜索目标传送点
        # 3. 点击传送
        pass
```

---

## 十五、数据集采集

### 15.1 AutonomousDrivingDatasetRecorder

```python
# DatasetCollection/autonomous_driving_dataset_recorder.py

class AutonomousDrivingDatasetRecorder(CustomAction):
    """采集自动驾驶数据集"""
    _EXAMPLES_PER_SECOND = 2.0
    _SEQUENCE_LENGTH = 5
    _IMAGE_SIZE = (480, 270)

    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        params = _parse_params(argv.custom_action_param)
        dataset_dir = _resolve_output_dir(params.get("output_dir"))
        output_dir = _make_session_dir(dataset_dir)

        metadata = {
            "format": "K<number>%<label>_<label>_...jpeg",
            "labels": _KEY_LABELS,
            "sequence_length": _SEQUENCE_LENGTH,
            "image_width": _IMAGE_SIZE[0],
            "image_height": _IMAGE_SIZE[1],
            "examples_per_second": _EXAMPLES_PER_SECOND,
        }
        (output_dir / "metadata.json").write_text(json.dumps(metadata, indent=2))

        frames = [np.zeros((_IMAGE_SIZE[1], _IMAGE_SIZE[0], 3), dtype=np.uint8) for _ in range(_SEQUENCE_LENGTH)]
        labels = [0] * _SEQUENCE_LENGTH
        sample_no = 0
        captured_count = 0

        while not context.tasker.stopping:
            image = controller.post_screencap().wait().get()
            frame = _prepare_frame(image, _IMAGE_SIZE)
            if frame is None:
                continue

            # 检测当前按下的键
            pressed = _pressed_keys()  # 通过 GetAsyncKeyState 检测
            label = _label_from_keys(pressed)

            # 滑动窗口
            frames = frames[1:] + [frame]
            labels = labels[1:] + [label]
            captured_count += 1

            if captured_count >= _SEQUENCE_LENGTH:
                _save_sample(output_dir, frames, labels, sample_no)
                sample_no += 1
```

---

## 十六、工具函数库

### 16.1 Common/utils.py

```python
def load_params(custom_action_param) -> dict:
    """兼容 None / dict / JSON 字符串的 custom_action_param 解析"""
    if not custom_action_param:
        return {}
    if isinstance(custom_action_param, dict):
        return custom_action_param
    try:
        params = json.loads(custom_action_param)
    except Exception:
        return {}
    return params if isinstance(params, dict) else {}


def get_image(controller):
    """获取当前屏幕截图"""
    job = controller.post_screencap()
    job.wait()
    img = controller.cached_image
    return img


def click_rect(controller, rect, delay=0.001):
    """点击矩形区域中心"""
    x, y, w, h = rect
    cx = x + w // 2
    cy = y + h // 2
    controller.post_touch_move(cx, cy).wait()
    time.sleep(delay)
    controller.post_touch_down(cx, cy).wait()
    time.sleep(delay)
    controller.post_touch_up().wait()


def match_template_in_region(img, region, template, min_similarity=0.8, green_mask=False):
    """在指定 ROI 内进行模板匹配"""
    x1, y1, w, h = region
    x2, y2 = x1 + w, y1 + h
    h_img, w_img = img.shape[:2]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w_img, x2), min(h_img, y2)

    if x2 <= x1 or y2 <= y1:
        return False, 0.0, 0, 0

    roi = img[y1:y2, x1:x2]
    if len(roi.shape) == 3 and roi.shape[2] == 4:
        roi = cv2.cvtColor(roi, cv2.COLOR_BGRA2BGR)

    if green_mask:
        lower_green = np.array([0, 255, 0], dtype=np.uint8)
        mask = cv2.bitwise_not(cv2.inRange(template, lower_green, lower_green))
        res = cv2.matchTemplate(roi, template, cv2.TM_CCOEFF_NORMED, mask=mask)
    else:
        res = cv2.matchTemplate(roi, template, cv2.TM_CCOEFF_NORMED)

    res = np.nan_to_num(res, nan=-1.0, posinf=-1.0, neginf=-1.0)
    res[(res < -1e-6) | (res > 1.0 + 1e-6)] = -1.0
    np.clip(res, 0.0, 1.0, out=res)
    min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(res)

    if max_val >= min_similarity:
        return True, max_val, x1 + max_loc[0], y1 + max_loc[1]
    return False, max_val, 0, 0
```

---

## 十七、其他功能模块

### 17.1 拍卖王（BidKing）

```json
// assets/resource/tasks/BidKing.json
{
    "task": [{
        "name": "BidKing",
        "entry": "BidKingEntrance",
        "option": ["BidKingLoopCount"],
        "controller": ["Win32-Front"],
        "group": ["HethereauHobbies"]
    }]
}
```

**配置选项**：
- `BidKingLoopCount` — 循环竞拍次数（input，默认 1，正则 `^[1-9]\\d{0,3}$`）
- `pipeline_override` 将 `{count}` 注入到 `BidKingRound` 节点的 `max_hit`

**流程**：进入拍卖行 → 检测当前竞拍项 → 自动出价 → 等待结果 → 循环

### 17.2 领取奖励（ClaimRewards）

```json
// assets/resource/tasks/ClaimRewards.json
{
    "task": [{
        "name": "ClaimRewards",
        "entry": "ClaimRewardsEntrance",
        "option": ["ClaimRewardsActivity", "ClaimRewardsBattlePass"],
        "group": ["Daily"]
    }]
}
```

**配置选项**：
- `ClaimRewardsActivity` — 领取活跃度奖励（switch，默认 Yes）
- `ClaimRewardsBattlePass` — 领取环期赏令奖励（switch，默认 Yes）

**Pipeline 节点**：
- `ClaimRewardsActivity` — 检测活跃度界面并领取
- `ClaimRewardsBattlePass` — 检测环期赏令界面并领取
- `ClaimRewardsEntrance` — 入口：打开奖励界面

### 17.3 喷泉打卡（FountainCheckin）

```json
// assets/resource/tasks/FountainCheckin.json
{
    "task": [{
        "name": "FountainCheckin",
        "entry": "FountainCheckinEntrance",
        "group": ["Daily"]
    }]
}
```

**功能**：自动前往指定喷泉位置打卡，完成后领取奖励。

### 17.4 女巫占卜（WitchDivination）

```json
// assets/resource/tasks/WitchDivination.json
{
    "task": [{
        "name": "WitchDivination",
        "entry": "WitchDivinationEntrance",
        "controller": ["Win32-Front"]
    }]
}
```

**Pipeline 节点**（`assets/resource/base/pipeline/WitchDivination/`）：
- `WitchDivination.json` — 主流程
- `ShuffleStep.json` — 洗牌步骤识别
- `WitchDivinationAction.json` — 占卜执行
- `WitchDivinationChat.json` — 聊天确认

**流程**：选择占卜师 → 洗牌动画识别 → 选择卡牌 → 等待结果

### 17.5 提款机（WithdrawMoney）

```python
# withdraw_money_choose_item.py

@AgentServer.custom_action("withdraw_money_choose_item")
class WithdrawMoneyChooseItem(CustomAction):
    """自动选择提款机商品，按价格/小时排序选取最优"""

    def run(self, context, argv):
        controller = context.tasker.controller

        def _screencap():
            return controller.post_screencap().wait().get()

        def _filtered_boxes(result):
            """从 OCR 结果中提取所有命中框"""
            if result is None or not result.hit:
                return []
            return [r.box for r in result.filtered_results if r.box is not None]

        def _parse_value(text):
            """从 OCR 文本解析价格，支持 1,234 / 1.5K 格式"""
            if not text:
                return None
            text = text.strip().upper().replace(",", "").replace("，", "")
            m = re.search(r"(\d+(?:\.\d+)?)\s*(K)?\s*/", text)
            if not m:
                return None
            value = float(m.group(1))
            if m.group(2) == "K":
                value *= 1000
            return value

        # Step 0: 向上滑动到列表顶部
        context.run_action("WithdrawMoneySwipeUp")
        time.sleep(1)

        # Step 1-3: 关闭灰色背景角标（上下各一次）
        # Step 4: 向下位置匹配商品价格 /h
        down_items = [(v, r, "down") for v, r in collect_product_values("WithdrawMoneyItemValueDown")]

        # Step 5-6: 向上滑动并匹配
        up_items = [(v, r, "up") for v, r in collect_product_values("WithdrawMoneyItemValueUp")]

        # Step 7: 按 value 降序排序，只点前五个
        all_items = down_items + up_items
        sorted_items = sorted(all_items, key=lambda x: x[0], reverse=True)
        top5 = sorted_items[:5]

        current_swipe = "up"
        for value, rect, item_swipe in top5:
            if item_swipe != current_swipe:
                if item_swipe == "up":
                    context.run_action("WithdrawMoneySwipeUp")
                else:
                    context.run_action("WithdrawMoneySwipeDown")
                current_swipe = item_swipe
                time.sleep(1)
            _click_rect(controller, rect)
            time.sleep(0.5)
```

**Task 配置**：
- `Restock` — 自动补货（switch，默认 No）
- `ChooseProduct` — 自动选择商品（switch，默认 Yes）

**智能选品逻辑**：
1. OCR 识别所有商品的价格/小时
2. 按价格降序排序
3. 选取 top 5 点击
4. 自动处理上下翻页

### 17.6 自动滚书（AutoFScroll）

```python
# auto_f_scroll.py

@AgentServer.custom_action("auto_f_scroll")
class AutoFScroll(CustomAction):
    """长按 F 键触发极速连点 + 滚轮联动"""

    def run(self, context, argv):
        controller = context.tasker.controller
        KEY_F = 70       # MAA 控制器用的 F 键码
        VK_F = 0x46      # Windows API 用的 F 键码
        MOUSEEVENTF_WHEEL = 0x0800

        while not context.tasker.stopping:
            # 检测物理键盘 F 键是否按下
            is_f_pressed = ctypes.windll.user32.GetAsyncKeyState(VK_F) & 0x8000
            if is_f_pressed:
                # 发送 MAA 按键
                controller.post_key_down(KEY_F)
                time.sleep(0.1)
                controller.post_key_up(KEY_F)

                # 同时发送鼠标滚轮下滚
                try:
                    ctypes.windll.user32.mouse_event(
                        MOUSEEVENTF_WHEEL, 0, 0, -120, 0
                    )
                except Exception:
                    pass
                time.sleep(0.1)
            else:
                time.sleep(0.05)

        return CustomAction.RunResult(success=True)
```

**原理**：通过 `GetAsyncKeyState` 检测物理键盘 F 键状态，长按 F 时同时发送 MAA 按键和 Windows 滚轮事件，实现极速翻页。

### 17.7 自动咖啡 Lite（AutoMakeCoffeeLite）

```python
# AutoCoffee/auto_make_coffee_lite.py

@AgentServer.custom_action("auto_make_coffee_lite")
class AutoMakeCoffeeLite(CustomAction):
    """简化版咖啡制作：依次制作三道菜（可颂、蛋糕、面包）"""

    def run(self, context, argv):
        # 参数
        make_count = params.get("count", 10)
        check_freq = params.get("freq", 0.5)
        timeout = params.get("timeout", 5)

        for count in range(make_count):
            # Step 1: 选择关卡并开始营业
            while True:
                img = get_image(controller)
                start_result = context.run_recognition("MakeCoffeeStart", img)
                if start_result and start_result.hit:
                    # 滚动到目标并点击
                    context.run_action("MakeCoffeeScrollToTop")
                    time.sleep(1)
                    target_result = context.run_recognition("MakeCoffeeTargetCoffeeMaster", img)
                    if target_result and target_result.hit:
                        click_rect_multiple(controller, [target_result.box.x, ...])
                    break
                time.sleep(check_freq)

            # Step 2: 制作三道菜
            make_croissant(context)   # 可颂
            make_cake(context)        # 蛋糕
            make_bread(context)       # 面包

            # Step 3: 等待营业额达标
            # Step 4: 领取奖励
            wait_and_claim(context, controller, check_freq)
            press_key_f(controller)
```

### 17.8 番茄汁制作（AutoMakeTomatoJuice）

```python
# AutoCoffee/auto_make_tomato_juice.py

@AgentServer.custom_action("auto_make_tomato_juice")
class AutoMakeTomatoJuice(CustomAction):
    """特调番茄汁：连续制作两杯，等待第二位客人到店"""

    # 常量
    TOMATO_JUICE_SERVINGS = 2        # 每次制作 2 杯
    SECOND_GUEST_REMAINING_SECONDS = 111  # 等待第二位客人的阈值
    COUNTDOWN_DETECT_TIMEOUT = 20     # 倒计时检测超时

    def run(self, context, argv):
        make_count, check_freq = _load_params(argv.custom_action_param)

        for count in range(make_count):
            # Step 1: 选择"新品练习 I"并开始营业
            # Step 2: 等待第二位客人到店（检测营业倒计时 ≤ 111秒）
            if not _wait_for_customers_ready(context, controller, check_freq):
                return CustomAction.RunResult(success=False)

            # Step 3: 连续制作两杯番茄汁
            for _ in range(TOMATO_JUICE_SERVINGS):
                context.run_action("MakeTomatoJuiceSelectGlass")
                context.run_action("MakeTomatoJuiceAddTomato")

            # Step 4: 检测营业额星标，未达标则继续制作
            while True:
                img = get_image(controller)
                star_result = context.run_recognition("MakeCoffeeStar", img)
                if star_result and star_result.hit:
                    break
                _make_tomato_juice(context)

            # Step 5: 领取奖励
            wait_and_claim(context, controller, check_freq)
            press_key_f(controller)
```

**倒计时解析**：支持多种语言格式 `X分Y秒` / `X:Y` / `X m Y s`

### 17.9 角色都市技能同步（SyncCharacterAbilityCityAbility）

```python
# SyncCharacterAbilityCityAbility.py

_TEMPLATE_TO_NAME = {
    "Adler.png": "阿德勒",
    "Aurelia.png": "海月",
    "Baicang.png": "白藏",
    "Chaos.png": "卡厄斯",
    "Chiz.png": "小吱",
    "Daffodill.png": "达芙蒂尔",
    "Edgar.png": "埃德嘉",
    "Fadia.png": "法帝娅",
    "Haniel.png": "哈尼娅",
    "Hathor.png": "哈索尔",
    "Hotori.png": "浔",
    "Jiuyuan.png": "九原",
    "Lacrimosa.png": "安魂曲",
    "Mint.png": "薄荷",
    "Nanally.png": "娜娜莉",
    "Sakiri.png": "早雾",
    "Skia.png": "翳",
    "Zero.png": "零",
}

@AgentServer.custom_action("SyncCharacterAbilityCityAbilityMainAction")
class SyncCharacterAbilityCityAbilityMainAction(CustomAction):
    """遍历角色列表，OCR 识别名字+技能等级，持久化存储"""

    def run(self, context, argv):
        fresh_record = params.get("fresh_record", False)

        # 设置锚点防止递归
        context.set_anchor("CityAbilityAfterClick", "")

        last_name = None
        no_change = 0

        for iteration in range(300):  # 安全上限
            if context.tasker.stopping:
                break

            # 1. 识别角色名（OCR → TemplateMatch 优先）
            name = _get_character_name(context)

            if name is None:
                no_change += 1
            else:
                # 2. OCR 技能等级
                levels = _ocr_skills(context)  # [skill0, skill1]

                if fresh_record:
                    results[name] = levels
                else:
                    set_character_abilities(name, levels)

                if name == last_name:
                    no_change += 1
                else:
                    no_change = 0
                    last_name = name

            # 3. 列表末尾检测
            if no_change >= 3:
                self._scan_remaining_characters(context, results if fresh_record else None)
                break

            # 4. 切换到下一个角色
            context.run_task("SyncCharacterAbilityCityAbilityOpenInfoPage")
            context.run_task("SyncCharacterAbilityCityAbilityNextCharacter")

        # 5. 全新记录模式：清空旧数据 + 批量存入
        if fresh_record and results:
            clear_all()
            for char_name, levels in results.items():
                set_character_abilities(char_name, levels)
```

**角色名识别策略**：
1. OCR 先在信息页识别名字
2. 进入技能页后，TemplateMatch 以 ≥0.9 置信度优先采用
3. TM 失败时回退 OCR

**数据存储**：通过 `CharacterAbility_CityAbility` 管理器持久化，支持全新记录模式（`fresh_record: true`）

### 17.10 在线地图导航（OnlineMapNavigation）

```python
# Navi/online_map_navigation_action.py

@AgentServer.custom_action("online_map_navigation")
class OnlineMapNavigationAction(CustomAction):
    """启动 WebSocket 服务，接收外部路由请求并执行寻路"""

    def run(self, context, argv):
        params = self.load_option_params(context)
        port = int(params.get("port", 14514))
        tolerance = float(params.get("tolerance", 5.0))
        frame_interval = max(0.05, float(params.get("frame_interval", 0.1)))
        angle_backend = str(params.get("angle_backend", "auto"))
        position_backend = str(params.get("position_backend", "auto"))
        debug = bool(params.get("debug", False))

        route = RouteSession()
        runner = RouteRunner(context, route,
            angle_backend=angle_backend,
            position_backend=position_backend,
            tolerance=tolerance,
            frame_interval=frame_interval,
            debug=debug)
        network = RouteWebSocketService(route, port=port,
            get_source_size=runner.source_size,
            get_current_point=runner.current_point)
        runner.on_frame = network.publish_frame

        try:
            network.start()
            runner.start()
            logger.info("OnlineMapNavigation service started: ws://0.0.0.0:%s", port)
            runner.run_until_stopped(on_tick=network.publish_route)
        finally:
            runner.close()
            network.stop()
```

**WebSocket 协议**（port 14514）：

| 消息类型 | 说明 |
|---|---|
| `navi-route-set` | 设置完整路线并开始 |
| `navi-route-add` | 添加单个航点 |
| `navi-route-clear` | 清除路线 |
| `navi-route-start` | 开始执行 |
| `navi-route-stop` | 停止执行 |
| `navi-route-ack` | 操作确认响应 |
| `navi-state` | 推送当前位置/朝向/路线状态 |

**位置推送格式**：
```json
{
    "type": "navi-state",
    "version": 1,
    "position": {"x": 6500.5, "y": 5200.3, "pixelX": 6520, "pixelY": 5210, "score": 0.95, "mode": "coordinate"},
    "angle": 180.5,
    "pitch": -15.2,
    "angleConfidence": 0.98,
    "route": {"waypoints": [...], "active": true, "currentIndex": 2, "status": "running"},
    "timestamp": 1726234567.0
}
```

---

## 十八、新增功能开发指南

### 16.1 Common/utils.py

```python
def load_params(custom_action_param) -> dict:
    """兼容 None / dict / JSON 字符串的 custom_action_param 解析"""
    if not custom_action_param:
        return {}
    if isinstance(custom_action_param, dict):
        return custom_action_param
    try:
        params = json.loads(custom_action_param)
    except Exception:
        return {}
    return params if isinstance(params, dict) else {}


def get_image(controller):
    """获取当前屏幕截图"""
    job = controller.post_screencap()
    job.wait()
    img = controller.cached_image
    return img


def click_rect(controller, rect, delay=0.001):
    """点击矩形区域中心"""
    x, y, w, h = rect
    cx = x + w // 2
    cy = y + h // 2
    controller.post_touch_move(cx, cy).wait()
    time.sleep(delay)
    controller.post_touch_down(cx, cy).wait()
    time.sleep(delay)
    controller.post_touch_up().wait()


def match_template_in_region(img, region, template, min_similarity=0.8, green_mask=False):
    """在指定 ROI 内进行模板匹配"""
    x1, y1, w, h = region
    x2, y2 = x1 + w, y1 + h
    h_img, w_img = img.shape[:2]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w_img, x2), min(h_img, y2)

    if x2 <= x1 or y2 <= y1:
        return False, 0.0, 0, 0

    roi = img[y1:y2, x1:x2]
    if len(roi.shape) == 3 and roi.shape[2] == 4:
        roi = cv2.cvtColor(roi, cv2.COLOR_BGRA2BGR)

    if green_mask:
        lower_green = np.array([0, 255, 0], dtype=np.uint8)
        mask = cv2.bitwise_not(cv2.inRange(template, lower_green, lower_green))
        res = cv2.matchTemplate(roi, template, cv2.TM_CCOEFF_NORMED, mask=mask)
    else:
        res = cv2.matchTemplate(roi, template, cv2.TM_CCOEFF_NORMED)

    res = np.nan_to_num(res, nan=-1.0, posinf=-1.0, neginf=-1.0)
    res[(res < -1e-6) | (res > 1.0 + 1e-6)] = -1.0
    np.clip(res, 0.0, 1.0, out=res)
    min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(res)

    if max_val >= min_similarity:
        return True, max_val, x1 + max_loc[0], y1 + max_loc[1]
    return False, max_val, 0, 0
```

---

## 十七、新增功能开发指南

### 17.1 完整流程

1. **创建 Python 文件**：`agent/custom/action/<Name>/action.py`
2. **注册装饰器**：`@AgentServer.custom_action("snake_case_name")`
3. **导入注册**：在 `agent/custom/action/__init__.py` 中添加 import 和 `__all__`
4. **创建 Pipeline 节点**：在 `assets/resource/base/pipeline/` 添加 JSON
5. **创建任务配置**：在 `assets/resource/tasks/` 添加 JSON
6. **更新 interface.json**：在 `import` 数组中添加引用
7. **更新本地化**：同步 5 个语言文件

### 17.2 编码规范

```python
# ✅ 正确
from utils.logger import logger
logger.debug("message %s", value)  # % 格式化

from utils.maafocus import PrintT
PrintT(context, "key", arg1)  # 向界面推送消息

# ❌ 错误
print("message")  # 禁止使用 print
logger.debug(f"message {value}")  # 禁止 f-string
```

### 17.3 坐标处理

```python
# 所有坐标基于 1280×720
rect = [x, y, w, h]  # 原始坐标
mapped_rect = screen.map_rect(rect)  # 缩放到实际分辨率
```

---

*文档版本：v2.0 | 最后更新：2026-09-13（原文误写 2025）；2026-09-19 加现状标注 | 总行数：5000+*
