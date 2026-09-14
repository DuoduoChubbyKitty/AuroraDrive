# MaaNTE 深度技术文档 — 架构篇

> 本文档基于 MaaNTE 源码深度分析，覆盖核心框架、识别-决策-执行管线、坐标系统、自定义Action开发等。

---

## 目录

1. [系统概述](#1-系统概述)
2. [架构分层](#2-架构分层)
3. [Pipeline 执行引擎](#3-pipeline-执行引擎)
4. [识别系统](#4-识别系统)
5. [动作系统](#5-动作系统)
6. [坐标与定位系统](#6-坐标与定位系统)
7. [自定义 Action 开发规范](#7-自定义-action-开发规范)
8. [任务配置系统](#8-任务配置系统)
9. [界面与控制器](#9-界面与控制器)
10. [高级主题](#10-高级主题)

---

## 1. 系统概述

### 1.1 项目定位

MaaNTE（MaaFramework 异环小助手）是基于 [MaaFramework](https://github.com/MaaXYZ/MaaFramework) 的自动化游戏工具，通过**图像识别 + 模拟输入**的方式对《异环》(Never to Everness/NTE) 进行黑盒自动化控制。

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

### 1.3 基准分辨率

所有坐标、ROI、模板匹配均基于 **1280×720** 基准分辨率。运行时通过 `screen.map_point()` / `screen.map_rect()` 自动缩放到实际窗口尺寸。

---

## 2. 架构分层

### 2.1 三层架构

```
┌─────────────────────────────────────────────────────────────┐
│                     MXU GUI Frontend                        │  ← 用户交互层
│                     (C++/Qt)                                │
├─────────────────────────────────────────────────────────────┤
│                    MaaFramework Core                        │  ← 引擎层
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  Pipeline    │  │  Recognition │  │   Controller     │  │
│  │  Executor    │  │  Engine      │  │   (Input/Screenshot)│
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
│         │                 │                    │            │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌────────▼─────────┐  │
│  │ Custom       │  │ Template     │  │ Win32 SendMessage│  │
│  │ Action Run   │  │ Match / OCR  │  │ / PostMessage    │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                      Python Agent                           │  ← 业务逻辑层
│  agent/custom/action/    ← CustomAction 实现              │
│  agent/utils/            ← 工具函数库                      │
│  assets/resource/        ← 资源配置（Pipeline/模板/本地化）  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 目录结构

```
MaaNTE/
├── agent/                          # Python 自定义逻辑
│   ├── main.py                     # 入口：venv 检测 → 依赖安装 → AgentServer 启动
│   ├── custom/
│   │   ├── action/                 # CustomAction 实现
│   │   │   ├── __init__.py         # 注册所有 CustomAction
│   │   │   ├── AutoFish/           # 自动钓鱼
│   │   │   ├── AutoCoffee/         # 自动咖啡
│   │   │   ├── Furniture/          # 家具收取
│   │   │   ├── Movement/           # 角色移动控制
│   │   │   ├── Navi/               # 导航系统（核心）
│   │   │   ├── MapTeleport/        # 地图传送
│   │   │   ├── SoundTrigger/       # 音频驱动闪避
│   │   │   ├── Tetris/             # 俄罗斯方块 AI
│   │   │   ├── rhythm/             # 节奏游戏
│   │   │   ├── auto_piano/         # 自动钢琴
│   │   │   ├── pinkpaw/            # 粉爪大劫案
│   │   │   ├── Common/             # 通用工具
│   │   │   └── auto_volleyball.py  # 自动排球
│   │   └── utils/                  # 工具函数
│   └── utils/
│       ├── __init__.py
│       ├── screen.py               # 分辨率缩放映射
│       ├── logger.py               # 日志
│       ├── i18n.py                 # 国际化
│       └── maafocus.py             # 前端消息推送
├── assets/
│   ├── interface.json              # 全局配置注册表
│   └── resource/
│       ├── base/pipeline/          # Pipeline JSON（场景/任务/按钮）
│       ├── base/image/             # 模板图片（1280×720基准）
│       ├── tasks/                  # 任务配置 JSON
│       └── locales/interface/      # 5语言本地化
├── deps/                           # 离线依赖（whl 包）
├── docs/                           # 开发者文档
└── build.py                        # 构建脚本
```

### 2.3 进程模型

```
MXU GUI (主进程)
    │
    ├── socket IPC ──→ Python Agent (子进程, main.py)
    │                       │
    │                       ├── CustomAction (Python)
    │                       ├── MaaFramework C++ 引擎
    │                       └── Win32 Controller
    │
    └── (可选) WebSocket ──→ 外部路由服务 (Navi)
```

---

## 3. Pipeline 执行引擎

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

### 3.4 执行原则

1. **识别→动作→重新识别**循环：每次识别后必须重新识别确认状态，禁止"识别一次，连续点 A、B、C"
2. **`next` 首轮命中原则**：next 列表覆盖所有可能画面状态，拒绝重试机制
3. **避免硬延迟**：优先使用中间识别节点或 `pre_wait_freezes`/`post_wait_freezes`
4. **处理中间态**：弹窗、加载、不在目标场景等均需在 next 中处理

### 3.5 命名规范

- Pipeline 节点：**帕斯卡命名**，带任务/模块前缀（如 `FishNewEntrance`）
- 私有节点：`__` 前缀（如 `__ScenePrivate*`），禁止外部引用
- 优先使用 SceneManager 公开接口（`Interface/Scene/`）

---

## 4. 识别系统

### 4.1 模板匹配

核心函数 `match_template_in_region()`（`Common/utils.py`）：

```python
def match_template_in_region(img, region, template, min_similarity=0.8, green_mask=False):
    """
    在指定 ROI 区域内进行模板匹配
    
    Args:
        img: numpy BGR 数组（屏幕截图）
        region: (x, y, w, h) ROI 区域
        template: 模板图像
        min_similarity: 最低匹配阈值
        green_mask: 是否使用绿色遮罩（排除绿色元素）
    
    Returns:
        (matched, max_val, x, y)
    """
```

**关键点**：
- 使用 `cv2.TM_CCOEFF_NORMED` 相关系数匹配
- 支持绿色遮罩（排除绿色高亮元素干扰）
- 返回值包含匹配位置和置信度

### 4.2 OCR 识别

使用 MaaFramework 内置的 PaddleOCR，支持多语言：
- ppocr_v3: zh_cn, en_us, ko_kr, ja_jp, zh_tw
- ppocr_v4: zh_cn, en_us
- ppocr_v5: zh_cn, zh_cn-server
- ppocr_v6: tiny, small, medium

**配置要点**：
- `expected` 填写完整文本
- 部分匹配/正则条目加 `// @i18n-skip` 注释
- CI 自动同步翻译到 5 种语言

### 4.3 自定义识别

```python
@AgentServer.custom_recognition("my_recognition")
class MyRecognition(CustomRecognition):
    def run(self, context: Context, argv: CustomRecognition.RunArg) -> CustomRecognition.AnalyzeResult:
        img = get_image(context.tasker.controller)
        # 自定义识别逻辑
        return CustomRecognition.AnalyzeResult(hit=True, box=(x, y, w, h))
```

---

## 5. 动作系统

### 5.1 CustomAction 注册

```python
from maa.agent.agent_server import AgentServer
from maa.custom_action import CustomAction
from maa.context import Context

@AgentServer.custom_action("auto_fish")
class AutoFish(CustomAction):
    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        controller = context.tasker.controller
        # 实现逻辑...
        return CustomAction.RunResult(success=True)
```

**注册流程**：
1. 在 `agent/custom/action/__init__.py` 中添加 import
2. 在 `__all__` 列表中添加类名
3. 在 Pipeline JSON 中引用 `custom_action_name`

### 5.2 输入控制

| 方法 | 说明 |
|---|---|
| `controller.post_key_down(vk)` | 按下按键 |
| `controller.post_key_up(vk)` | 释放按键 |
| `controller.post_click(x, y)` | 点击坐标 |
| `controller.post_touch_move(x, y)` | 移动鼠标到坐标 |
| `controller.post_relative_move(dx, dy)` | 相对移动 |
| `controller.post_screencap()` | 截取屏幕 |

### 5.3 屏幕截图

```python
# 异步截图
job = controller.post_screencap()
job.wait()
img = controller.cached_image  # numpy BGR 数组
```

---

## 6. 坐标与定位系统

### 6.1 三层坐标体系

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

### 6.2 网络包坐标解码

`nte_coordinate_api.py` 实现 UE5 移动包的 bit-packed 解码：

```
数据包结构：
  [float32 time: 32bit] [accel: 7bit header + 3 signed values] [location: 3 float] [rotation: FRotator::SerializeCompressedShort]

解码步骤：
  1. 扫描 payload[190:512] bit 范围寻找有效位置
  2. 验证时间连续性 + 空间连续性
  3. 提取 location (scale=100) 和 rotation
  4. 计算 compass heading（基于相机朝向）
  
输出：(x, y, z, pitch, heading)
```

**两个后端**：
- `pcap`: 使用 Scapy 的 AsyncSniffer，监听 TCP 30031 / UDP
- `pktmon`: 使用 Windows pktmon，需要管理员权限

### 6.3 视觉定位（MapLocator）

当网络包不可用时，使用小地图模板匹配：

```python
class MapLocator:
    MAP_SIZE = (13056, 13056)      # 大地图尺寸
    MINI_MAP_ROI = (28, 15, 150, 150)  # 小地图区域
    MAP_CROP_SIZES = (268, 530, 660)  # 多尺度模板
    
    def locate(self, frame: np.ndarray) -> MapLocationResult:
        # 1. 裁剪小地图 ROI
        # 2. HSV 颜色过滤 + 圆形掩码
        # 3. 多尺度模板匹配（local + global）
        # 4. 传送恢复（teleport recovery）
        # 5. EMA 平滑坐标
```

**关键算法**：
- **多尺度匹配**：预生成 3 个缩放级别的模板（268/530/660px）
- **邻域搜索**：基于上次位置 ±256px 范围内搜索
- **全局搜索**：在预定义的非黑区域搜索
- **传送恢复**：距离 > 320px 时触发全局重定位
- **EMA 平滑**：α=0.7 减少坐标抖动

### 6.4 方向预测（AnglePredictor）

使用 ONNX 模型检测小地图上的方向指示器：

```python
class AnglePredictor:
    pointer_roi = [73, 60, 64, 64]  # 小地图内方向箭头区域
    
    def predict(self, frame) -> AnglePredictionResult:
        # 1. 裁剪方向箭头 ROI
        # 2. ONNX 推理（CPU/DirectML）
        # 3. 从关键点计算角度
        #    angle = atan2(dx, -dy) % 360
```

### 6.5 PID 控制器

`WaypointNavigator` 使用 PID 控制角色转向：

```python
class AnglePidController:
    kp = 0.85    # 比例增益
    ki = 0.04    # 积分增益
    kd = 0.10    # 微分增益
    output_limit = 35.0   # 最大转向角度
    deadband = 4.0        # 死区
    
    def update(self, error: float, now: float) -> float:
        # PID 计算 → 限制输出 → 转换为鼠标像素偏移
```

---

## 7. 自定义 Action 开发规范

### 7.1 创建步骤

1. **创建 Python 文件**：`agent/custom/action/<Name>/action.py`
2. **注册装饰器**：`@AgentServer.custom_action("snake_case_name")`
3. **导入注册**：在 `__init__.py` 中添加 import 和 `__all__`
4. **创建 Pipeline 节点**：在 `assets/resource/base/pipeline/` 添加 JSON
5. **创建任务配置**：在 `assets/resource/tasks/` 添加 JSON
6. **更新 interface.json**：在 `import` 数组中添加引用
7. **更新本地化**：同步 5 个语言文件

### 7.2 编码规范

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

### 7.3 坐标处理

```python
# 所有坐标基于 1280×720
rect = [x, y, w, h]  # 原始坐标
mapped_rect = screen.map_rect(rect)  # 缩放到实际分辨率
```

### 7.4 长循环处理

```python
while not context.tasker.stopping:
    # 每次迭代检查停止信号
    ...
```

---

## 8. 任务配置系统

### 8.1 任务 JSON 结构

```json
{
  "task": [
    {
      "name": "TaskName",
      "label": "$task_label_key",
      "entry": "PipelineEntryNode",
      "description": "$task_desc_key",
      "option": ["Option1", "Option2"],
      "group": ["GroupName"]
    }
  ],
  "option": {
    "Option1": {
      "type": "switch|input|select",
      "label": "$option_label",
      "default_case": "CaseName",
      "cases": [...],
      "pipeline_override": {
        "NodeName": {"param": {"key": "{value}"}}
      }
    }
  }
}
```

### 8.2 选项类型

| 类型 | 说明 | 示例 |
|---|---|---|
| `switch` | 开关（是/否） | FishLoopInfinite |
| `input` | 文本输入 | FishNumber (count) |
| `select` | 下拉选择 | FishNewNaviLocations |

### 8.3 pipeline_override

通过 `{value}` 模板替换用户输入，动态修改 Pipeline 参数：

```json
"FishNumber": {
  "pipeline_override": {
    "FishGameStart": {
      "custom_action_param": {"count": "{count}"}
    }
  }
}
```

---

## 9. 界面与控制器

### 9.1 控制器类型

| 名称 | Screencap | Mouse | Keyboard | 权限 |
|---|---|---|---|---|
| Win32 | Background | SendMessageWithCursorPos | PostMessage | 需要 |
| Win32-Front | PrintWindow | Seize | Seize | — |
| Win32-Background | PrintWindow | SendMessageWithWindowPos | PostMessage | 需要 |
| CloudGame-Front | FramePool | Seize | Seize | 需要 |

### 9.2 窗口匹配

```json
"window_regex": "^\\s*(异环|NTE)\\s*$"
"class_regex": "UnrealWindow"
```

### 9.3 分辨率适配

```python
# screen.py
BASELINE_WIDTH = 1280
BASELINE_HEIGHT = 720

def update_screen_size(width, height):
    _scale_x = width / BASELINE_WIDTH
    _scale_y = height / BASELINE_HEIGHT

def map_point(x, y):
    return int(round(x * _scale_x)), int(round(y * _scale_y))

def map_rect(rect):
    x, y, w, h = rect
    return map_point(x, y), (int(round(w * _scale_x)), int(round(h * _scale_y)))
```

---

## 10. 高级主题

### 10.1 并发与线程安全

- `CoordinateCapture` 使用 `threading.Lock` 保护共享状态
- `RouteSession` 使用 `threading.Lock` 保护路线数据
- 所有 CustomAction 在主线程中串行执行

### 10.2 错误处理

```python
try:
    # 主逻辑
    return CustomAction.RunResult(success=True)
except Exception as e:
    logger.error("Error: %s", e)
    return CustomAction.RunResult(success=False)
finally:
    # 清理资源
    pass
```

### 10.3 调试模式

```python
# 启用 debug 模式
debug = True
# → 打开 OpenCV 调试窗口
# → 显示坐标、角度、匹配结果
# → 支持交互式缩放和平移
```

### 10.4 i18n 工作流

1. OCR `expected` 填写完整中文
2. `.github/workflows/i18n-sync.yml` 自动同步翻译
3. 新增任务时手动更新 5 个语言文件

---

*文档版本：v1.0 | 最后更新：2025-09-13*
