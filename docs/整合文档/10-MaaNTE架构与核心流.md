# 10 · MaaNTE 架构与核心流

> 整合自 4 篇：`MAA深度文档_架构篇.md`（582 行）+ `Maa-09-main.py入口与MaaFramework核心流.md`（153）+ `Maa-10-agent-utils基础设施六件套.md`（280）+ `00-本目录说明.md`（34）。
> 整合日期：2026-10-18。**只读整合，未删改任何原文档**。
> 所有 `file.py:N` 引用均来自 MaaNTE 源码（本地 `MaaNTE/` 目录，未随本仓库分发），已逐条核对。

---

## 1. 一句话定位

MaaNTE 是基于 [MaaFramework](https://github.com/MaaXYZ/MaaFramework) 的《异环》(Never to Everness / NTE) 黑盒自动化工具：**MXU Qt 前端 → MaaHub Socket IPC → Python Agent 子进程 → Pipeline JSON 状态机（识别→动作→next 跳转）+ Win32 输入**。

对 AuroraDrive 的价值不是「整体移植」，而是**三类可复用资产**：① ROI/模板与偏移规则 ② 任务/选项 JSON 编排范式 ③ 逆向出的 UE5 移动包解码与标定常量。

---

## 2. 模块清单表

### 2.1 架构分层（三层）

| 层 | 内容 | 代码位置 |
|---|---|---|
| 用户交互层 | MXU GUI（C++/Qt）+ MaaHub | 前端，不在 agent/ |
| 引擎层 | MaaFramework Pipeline Executor / Recognition / Controller | `maafw==v5.10.4`（pip 轮子） |
| 业务逻辑层 | Python CustomAction + utils + assets/resource | `MaaNTE/agent/custom/action/` |

### 2.2 目录结构（`MAA深度文档_架构篇.md:77-114`）

```
MaaNTE/
├── agent/main.py               # 入口：venv → 依赖 → AgentServer
├── agent/custom/action/        # 全部 CustomAction（20 个子目录 + 6 个顶层单文件）
├── agent/utils/                # 六件套基础设施（1300 行）
├── assets/interface.json       # 全局配置注册表（161 行）
├── assets/resource/{base/pipeline, base/image, tasks, locales}
├── deps/                       # 离线 whl
└── build.py
```

### 2.3 进程模型（`架构篇:118-128`）

```
MXU GUI (主进程, C++/Qt)
   │
   ├── socket IPC ──→ Python Agent (子进程, agent/main.py)
   │                      ├── CustomAction (Python)
   │                      ├── MaaFramework C++ 引擎
   │                      └── Win32 Controller
   └── (可选) WebSocket ──→ 外部路由服务 (Navi, port 14514)
```

### 2.4 agent/ Python 规模（本地实测，2026-10-18）

| 指标 | 实测值 |
|---|---|
| `agent/` Python 总行数 | **23,233 行** |
| `custom/action/__init__.py` from-import 数 | **40 条** |
| `__all__` 导出名数 | **56 个** |
| `@AgentServer.custom_action` 注册数 | **57 个** |
| `@AgentServer.custom_recognition` 注册数 | **1 个** |
| `requirements.txt` | 16 行（17 个包？实际 15 个包，见 §4.2） |

> ⚠️ **与原文的差异（重要）**：`Maa-09:79` 称「36 个 from-import → 全部 48 个 custom_action 注册」；`Maa-15:219` 称「48 个注册动作」。**本地实测是 40 条 from-import / 57 个注册 / `__all__` 56 项**。上游已新增 `auto_volleyball_weekly.py`（226 行）、`lucky_star_round.py`（116 行）、`BidKing/place_bid.py` 等，文档未跟上。**以本节实测为准。**

### 2.5 技术栈（`架构篇:32-40`）

| 层次 | 技术 | 说明 |
|---|---|---|
| GUI 前端 | MXU (MaaFramework Next UI) | C++/Qt |
| 中间件 | MaaFramework | 识别引擎 + 输入模拟 + Pipeline 编排 |
| 自定义逻辑 | Python 3.x | CustomAction / CustomRecognition |
| 图像处理 | OpenCV (cv2) + NumPy | 模板匹配 / 颜色过滤 / 姿态检测 |
| 深度学习 | ONNX Runtime | `onnxruntime-directml`（Windows DML） |
| 网络抓包 | Scapy / pktmon | UE5 移动包解码 |
| 音频 | Librosa + scipy + soundcard | 闪避/反击音效匹配 |
| MIDI | mido | auto_piano |
| 通信 | MaaHub Socket IPC + websockets | GUI↔Agent / Navi 对外 |
| ML | scikit-learn | 节奏/决策模型 |

---

## 3. 核心流程一：main.py 入口自举（`agent/main.py`，571 行）

### 3.1 顶层自举（1-25 行，本地核对）

1. `sys.stdout.reconfigure(encoding="utf-8")`（:10）—— **Windows 控制台 GBK 兼容**。
2. **CWD 修正**（:18-20）：`os.chdir(project_root_dir)`，源注释 `# 假定的项目根目录`（:15）。此后所有相对路径（`./config`、`./debug`、`./assets`）以项目根为锚。
3. `sys.path.insert(0, current_script_dir)`（:24-25）—— 让 `import utils` / `import maa` / `import custom` 可解析。
4. `from utils import setup_logger; logger = setup_logger()`（:27-29）—— **import 即完成日志系统初始化**。

### 3.2 路径兼容性检测（:51-59）——对本项目直接相关

```python
_cwd = os.getcwd()
if re.search(r"[一-鿿　-〿＀-￯]", _cwd):   # CJK + 全角标点 + 全角 ASCII
    logger.warning(f"当前运行目录含中文或全角字符: {_cwd}\n"
                   "部分组件对此类路径兼容性较差，建议将程序移动至纯英文路径下运行。")
```

**当前 checkout 位于 `/Users/dupi/Desktop/自动驾驶系统`（含中文）**——该检测正是为这类场景预留的（仅 warning，不拦截）。

### 3.3 MaaHub 品牌注册（:32-49）

固定 accent id `9e8de7d9-ab2b-4784-a082-63110b986d90`；五语言 label 全写 "MaaHub"；**单一颜色 `#fe9800`**（default/hover/light/lightDark 四档同色）。

### 3.4 `main()` 流程（:550-567，本地核对）

| 步 | 条件 | 行为 |
|---|---|---|
| 1 | 恒 | `read_interface_version()`：`assets/interface.json` 存在（dev 布局）→ 返回 `"DEBUG"` |
| 2 | Windows | `_check_admin_privilege()`（:436）—— 非管理员 warning |
| 3 | Linux 或 dev | `ensure_venv_and_relaunch_if_needed()`（**Windows 生产构建跳过 venv，依赖打包在 deps/whl**） |
| 4 | 恒 | `check_and_install_dependencies()` |
| 5 | dev 模式 | `os.chdir(Path("./assets"))`（:564）—— pipeline/resource 相对 assets/ 解析 |
| 6 | 恒 | `agent(is_dev_mode)` |

### 3.5 venv 自举与依赖安装（`Maa-09:30-44`，关键工程点）

- `_is_running_in_venv()`（:69-79）：`sys.prefix != sys.base_prefix`。
- `ensure_venv_and_relaunch_if_needed()`（:82-156）：**重启命令恒用 `current_file_path`（绝对路径）**，源注释（:136-139）说明原因——"sys.argv[0] may be a relative path (e.g. './../agent/main.py') which resolves differently when cwd changes."
- `install_requirements()`（:326-411）**三级策略**：
  1. `deps/` 不存在 → **直接 return True**（:329-330，生产环境无本地 whl 时跳过安装）
  2. 有 whl → **本地优先 `--find-links deps/ --no-index`**（禁止在线索引）
  3. 在线 → 主镜像清华源 + 备用中科大（`--extra-index-url` 只挂一个）
- `read_config()`（:164-192）：`./config/<name>.json` 不存在 → mkdir + 写默认值。

### 3.6 ⚠️ `_check_game_resolution()`（:449-475）—— macOS 不适用

`find_window_by_process("HTGame.exe")` → **《异环》Windows 端进程名**；尺寸 ≠ (1280,720) 即 warning 并更新 `screen.update_screen_size`。**macOS 上此函数不可用**（依赖 win32_process）。对标 AuroraDrive：`CaptureEngine.makeStreamConfiguration` 用屏幕宽高比动态算输出尺寸，不依赖游戏窗口句柄。

---

## 4. 核心流程二：agent() 与 AgentServer 启动序列

### 4.1 agent()（`main.py:483-542`，本地逐行核对）

```python
def agent(is_dev_mode=False):
    try:
        # ① 清理 utils 模块缓存（venv 重启后旧缓存可能指向系统 site-packages）
        utils_modules = [n for n in list(sys.modules.keys()) if n.startswith("utils")]
        for module_name in utils_modules: del sys.modules[module_name]

        import utils, importlib
        importlib.reload(utils)

        # ② 把 utils 全部公共属性注入 agent() 的 globals
        for attr_name in dir(utils):
            if not attr_name.startswith("_"):
                globals()[attr_name] = getattr(utils, attr_name)

        from maa.agent.agent_server import AgentServer
        from maa.tasker import Tasker
        import custom                      # ③ 触发 40 条 from-import → 57 个 custom_action 注册
        Tasker.set_log_dir("./debug")
        from utils.i18n import init as i18n_init
        i18n_init()
        socket_id = sys.argv[-1]           # ④ MaaHub 传入的本地 socket 标识
        log_pi_environment()
        try:
            AgentServer.start_up(socket_id)
            _check_game_resolution()       # 控制器连接后才跑
            AgentServer.join()             # 阻塞主循环
        finally:
            AgentServer.shut_down()
    except ImportError as e:
        logger.error(f"导入模块失败: {e}"); sys.exit(1)
    except Exception as e:
        logger.exception("agent运行过程中发生异常"); raise
```

### 4.2 启动序列要点

| 序 | 动作 | 行号 | 说明 |
|---|---|---|---|
| ① | 清 `utils*` 模块缓存 + reload | :486-496 | **本文件最怪的代码段**；目的是让 utils 指向 venv 内的副本 |
| ② | `globals()` 注入 utils 公共属性 | :499-501 | **只注入 logger + pienv 公共名 + screen 模块对象**（`utils/__init__.py` 只 `from .logger import *` / `from .pienv import *` / `from . import screen`）→ 后续可裸写 `logger.xxx` / `screen.map_point(...)`，但 **i18n 的 `T()` 必须自己 import** |
| ③ | `import custom` | :512 | 触发 `agent/custom/__init__.py`（仅 `from .action import *`）→ 40 条 from-import 连锁生效 |
| ④ | `socket_id = sys.argv[-1]` | :524 | `interface.json` 的 `agent.child_args: ["../agent/main.py"]` 传入 |
| ⑤ | `start_up` → `_check_game_resolution` → `join` | :529-532 | try/finally 保证 `shut_down()` |

### 4.3 requirements.txt（16 行，本地核对）

| 组 | 包 | 用途 |
|---|---|---|
| MaaFramework | **`maafw==v5.10.4`** | `AgentServer` / `Tasker` / `custom_action` / `context` |
| CV | opencv-python + pillow + numpy | 模板匹配 / 图像 |
| 模型 | **onnxruntime-directml** | **Windows DML 后端——macOS 需换 onnxruntime** |
| 音频 | librosa + scipy + soundcard + scapy + pktmon-interface | SoundTrigger 听声链路 |
| MIDI | **mido** | auto_piano |
| 网络 | requests + **websockets>=14.0,<17.0** | Navi 导航服务 |
| ML | scikit-learn | 节奏/决策模型 |
| 杂 | loguru + pytz | 日志/时区 |

> ⚠️ 原文 `Maa-09:46-57` 写「17 项」，本地实测 **15 个包 / 16 行**（含两行约束）。以实测为准。

### 4.4 interface.json 全局注册（161 行）

**头部**：`interface_version: 2` / name `MaaNTE` / **AGPL-3.0** / version `0.0.4` / 5 个 locale 映射。

**4 个 controller（同一窗体四种抓取/输入姿态）**：

| 名称 | screencap | mouse | keyboard | 特权 |
|---|---|---|---|---|
| **Win32**（默认） | Background | SendMessageWithCursorPos | PostMessage | permission_required |
| **Win32-Front** | PrintWindow | **Seize** | **Seize** | 无 |
| **Win32-Background** | PrintWindow | SendMessageWithWindowPos | PostMessage | 有 |
| **CloudGame-Front** | **FramePool** | Seize | Seize | 有 |

窗体定位（三种 Win32 共用）：`class_regex: "UnrealWindow"`（UE5 引擎窗类名）+ `window_regex: "^\s*(异环|NTE)\s*$"`。

**import 注册 28 个任务 JSON**（本地 grep `assets/interface.json:122-158` 实测）：Daily(ClaimRewards) / CityTycoon(Furniture, WithdrawMoney) / HethereauHobbies(Fish, BidKing, PinkPawHeist, MakeCoffee, MakeCoffeeLite, MakeTomatoJuice, Rhythm, Tetris, Volleyball, VolleyballWeekly, BagelSpam, **PukaLand**) / RealTimeAssist(RealTime, OnlineMapNavigation, SoundDodge, AutoFScroll) / others(FountainCheckin, AutoPiano, WitchDivination) / DatasetCollection(AutonomousDrivingDataset) / UserInfo(SyncCharacterAbilityCityAbility, Touch)。
**preset**：AFK + RealtimeAssistance 启用；**FullDaily / QuickDaily 被注释停用**（:156-157）。

> ⚠️ **与原文差异**：`Maa-09:112-121` 称「21 个任务 JSON」，本地实测 **28 个**（上游新增 `VolleyballWeekly.json`、`PukaLand.json`、`BidKing` 细化）。以实测为准。

---

## 5. 核心流程三：agent/utils 六件套（1300 行）

### 5.1 导出面（`utils/__init__.py`，3 行，本地核对）

```python
from .logger import *
from .pienv import *
from . import screen
```

**只有 logger / pienv / screen 进 `utils` 命名空间**；`i18n` / `maafocus` / `win32_process` **不导出**——必须显式 `from utils.i18n import T`。这解释了 §4.2 ② 的 globals 注入为何不含 `T()`。

### 5.2 screen.py（41 行）——分辨率基准与坐标换算

**这是全项目 ROI/坐标的唯一基准**：

| 函数 | 语义 |
|---|---|
| `BASELINE_WIDTH/HEIGHT` | 1280 / 720（:4-5） |
| `update_screen_size(w, h)` | 写当前尺寸 + `_scale_x = w/1280`、`_scale_y = h/720`（**各自独立，非等比也正确**；分母除零防护 :30-31） |
| `map_point(x, y)` | `(round(x·sx), round(y·sy))` 基准→实机 |
| `map_rect(rect)` | 四元组同比例换算（w/h 用各自轴比例） |
| `uniform_scale()` | `min(sx, sy)`——**需要单标量的场景（圆半径/字号）取小值保证不溢出** |

调用方：`main.py _check_game_resolution()` + AutoFish 三文件。

### 5.3 pienv.py（354 行）—— PI v2.5.0 环境协议

8 个环境变量（:11-19）：`PI_INTERFACE_VERSION` / `PI_CLIENT_NAME` / `PI_CLIENT_VERSION` / `PI_CLIENT_LANGUAGE` / `PI_CLIENT_MAAFW_VERSION` / `PI_VERSION` / **`PI_CONTROLLER`(JSON)** / **`PI_RESOURCE`(JSON)**。

**4 个冻结 dataclass —— 注意它已含 macOS 配置**：

| 类 | 字段 | 平台 |
|---|---|---|
| `Win32Config` | class_regex / window_regex / screencap / mouse / keyboard | Windows |
| **`MacOSConfig`** | **title_regex / screencap / input** | **macOS** |
| `PlayCoverConfig` | uuid | PlayCover（iOS 投屏） |
| `GamepadConfig` | class_regex / window_regex / gamepad_type / screencap | 手柄 |

- 全部 `from_dict` 先 `isinstance(data, dict)` 判定，非 dict 返回 **None（不抛）**。
- **唯一抛异常**的是 `Controller.from_dict` / `Resource.from_dict`（:142、:177）：`raise TypeError(...)`——但外层 `_parse_json_env` 用 `except Exception` 兜住 → **最终仍返回 None + warning（双层防御）**。
- 单例 + 双检锁（:203-260）：`init(force=True)` 强制重读（测试/环境切换用）。
- 20 个访问器（:263-321）：`resource_label()` label 空则回退 name；`resource_paths()` 返回副本防外部改内部状态。

> 💡 **对本项目的启示**：MaaFramework 的 PI 协议**原生设计了 macOS controller 配置槽位**（`title_regex` / `screencap` / `input`）。若将来要在 macOS 上跑 MaaNTE，这是官方预留的入口，而非 hack。

---

## 6. 六件套其余三件：logger / i18n / maafocus / win32_process

### 6.1 logger.py（242 行）—— 三客户端自适应日志

**同一份日志按客户端能力三态输出**（:39-62）：

| 客户端判定 | 输出流 | 格式 |
|---|---|---|
| **MFAAvalonia** | stderr | `{level_short}:{message}`（MFAA 解析短级别名） |
| **MXU** | stdout | `{mxu_html_message}`（HTML span 着色） |
| 其他 | stderr | ANSI 真彩色转义 |

- `_enrich_record`（:78-88）loguru filter：写入前把 `level_short` / `level_color` / `color_reset` / `mxu_html_message` 塞进 `record["extra"]`；`_format_mxu_html_message` 对 message 做 `html.escape`（**防注入**）。
- **loguru 优先 + 标准 logging 回退**（:91-100）。
- 双 sink：控制台（`colorize=False`，交给 extra 转义串）+ 文件（`rotation="00:00"` 零点切 / `retention="2 weeks"` / `compression="zip"` / **`enqueue=True` 多线程安全** / backtrace + diagnose，:161-193）。
- **`_InterceptHandler`（:106-120）**：标准 logging → loguru 桥，`while` 循环沿 `f_back` 上溯跳过 logging 模块内部帧，**修正调用点行号**；`_ROOT_LOGGER.handlers = [_InterceptHandler()]`（:186）**劫持根 logger**——第三方库（MaaFramework/opencv）的输出也进 loguru。
- 噪音压制（:152-154）：cv2 / numpy / PIL / matplotlib / urllib3 / asyncio → WARNING。
- **import utils.logger 即完成日志系统初始化**（:239-242）：`setup_logger(console_level="INFO")` + `logger = get_logger("maante")`。

### 6.2 i18n.py（124 行）—— 五语言查表

- 语言常量：zh_cn / zh_tw / en_us / ja_jp / ko_kr，**DefaultLang = zh_cn**（:17）。
- `_resolve_locale_dir()`（:31-57）**双向六层上溯搜索**：起点两个（`Path.cwd()` + `__file__` 上三级），每起点最多上溯 6 层，每层试 `assets/resource/locales/agent`（生产）与 `resource/locales/agent`（dev）两条相对路径；**判定凭据 `{dir}/zh_cn.json` 存在**；全失败返回兜底路径（后续 warning 不抛）。**设计意图：兼容 `chdir(项目根)` 与 `chdir(assets)` 两种 cwd。**
- 叠加式加载（:60-83）：先 load 默认语言打底 → 非默认则覆盖 → **缺失 key 自动回退中文**（五个语言文件不必逐 key 对齐）；默认文件都读不到 → `{}`（`T()` 原样返回 key）。
- `T(key, *args)`（:107-114）：没翻译 → 直接返回 key；有 args → `%` 格式化。
- `separator()`（:117-119）：**CJK 用 "、"；en_us/ko_kr 用 ", "**。
- `RenderHTML(key, data)`（:122-124）：**注释明写"当前简化实现，直接返回 T(key)"——`data` 参数被忽略（预留未实现）**。

### 6.3 maafocus.py（33 行）—— 借 pipeline 协议发消息（全项目最有巧思的设计）

```python
_FOCUS_NODE = "_MAANTE_FOCUS_"

pipeline_override = {
    _FOCUS_NODE: {
        "focus": {"Node.Action.Starting": content},   # focus 协议字段
        "action": "DoNothing",                        # 不做任何操作
        "pre_delay": 0, "post_delay": 0,              # 零延迟
    }
}
context.run_action(_FOCUS_NODE, pipeline_override=pipeline_override)
```

**这是 MaaNTE 的"消息总线"技巧**：MaaFramework 的 `focus` 字段本是给客户端 UI 显示进度用的，这里临时造一个节点 + override 注入，让文本直达 MXU 界面。节点名用单下划线开头（与 pipeline 私有节点 `__` 前缀约定不同，全局唯一）。

- `context is None` → warning 跳过；`run_action` 异常 → warning（**消息失败不炸任务**）。
- `PrintT(context, key, *args)` = `Print(context, T(key, *args))`，**96 处调用点的标准入口**（`Maa-10:19`）。

### 6.4 win32_process.py（503 行）—— Win32 底层（**macOS 完全不可用，但有两个设计值得学**）

**① ctypes 全量显式绑定（:6-64）**：`user32` / `kernel32` 全局句柄 + 20+ 个函数的 `argtypes` / `restype` 逐个声明。
**⚠️ 坑位（:59-60 源注释）**："使进程感知 DPI，避免 GetClientRect 返回缩放后的虚拟坐标。**150% 缩放时未设置此项会导致返回值只有实际分辨率的 2/3**" → `user32.SetProcessDPIAware()` **模块级 import 即执行**。不设则 1920×1080 客户区被读成 1280×720，分辨率自检会误判为"正常"。

**② 平台优雅降级模式**（全项目唯一）：
```python
try:    from utils.win32_process import ensure_game_window_resolution
except ImportError:  ensure_game_window_resolution = None
...
if ensure_game_window_resolution is None:   # 98 行
    return RunResult(success=?)             # 非 Windows 直接短路
```
**win32 能力缺失时动作变 no-op，任务链不中断**——`pinkpaw_common.py` 用三重 try（`agent.utils.*` → `utils.*` → None）同模式。

**关键函数**：`get_pids_by_name`（:126-143，小写比对）/ `find_windows_by_process`（:175-218，**五重过滤**）/ `find_window_by_process`（:221-250，**三级选择：显式 > 稳定（沿用上次，面积 ≤1.1×）> 最大**——避免多窗口时选错）/ `resize_window`（:312-363，收敛轮询 50×100ms + 固定 Sleep(500)）/ `resize_client_area`（:366-411，**边框补偿**：`border = 窗口宽 - 客户宽`）/ `ensure_game_window_resolution`（:489-503，薄封装，默认 `HTGame.exe` + settle 300ms）。

---

## 7. Pipeline 执行引擎（架构篇第三章）

### 7.1 Pipeline JSON 格式（JSON 定义的状态机）

```json
{
  "name": "FishGameStart",
  "recognition": { "type": "TemplateMatch",
    "param": { "template": ["Fish/FishGameSign3.png"], "roi": [1141,609,87,84], "threshold": [0.7] } },
  "action": { "type": "Custom",
    "param": { "custom_action_name": "auto_fish", "custom_action_param": {"count": 10} } },
  "next": ["FishGameLoop", "FishHandleBaitLack"]
}
```

**识别类型**：`TemplateMatch`(CCoeffNormed) / `OCR`(PaddleOCR, threshold ~0.3) / `ColorMatch` / `DirectHit` / `And`/`Or` / `Custom`。
**动作类型**：`Click` / `LongPress` / `Swipe` / `ClickKey` / `Custom` / `DoNothing` / `StopTask`。

### 7.2 执行原则（AGENTS.md 规范，架构篇:183-188）

1. **识别→动作→重新识别**循环：每次识别后必须重新识别确认，禁止"识别一次，连续点 A、B、C"
2. **`next` 首轮命中原则**：next 列表覆盖所有可能画面状态，**拒绝重试机制**
3. **避免硬延迟**：优先用中间识别节点或 `pre_wait_freezes`/`post_wait_freezes`
4. **处理中间态**：弹窗、加载、不在目标场景均需在 next 中处理

### 7.3 命名规范

Pipeline 节点**帕斯卡命名**带任务/模块前缀（`FishNewEntrance`）；私有节点 `__` 前缀（`__ScenePrivate*`）**禁止外部引用**；跳转节点 `[JumpBack]NodeName`。

---

## 8. 任务配置系统与控制器

### 8.1 任务 JSON 结构（`架构篇:453-477`）

```json
{ "task": [{ "name": "TaskName", "label": "$task_label_key", "entry": "PipelineEntryNode",
             "option": ["Option1"], "group": ["GroupName"] }],
  "option": { "Option1": { "type": "switch|input|select", "default_case": "CaseName",
             "cases": [...], "pipeline_override": { "NodeName": {"param": {"key": "{value}"}} } } } }
```

**三种选项类型**：`switch`（是/否）/ `input`（文本输入，带 `verify` 正则 + `pipeline_type`）/ `select`（下拉）。**`{value}` 模板替换**让用户在 MXU 填的数字直接注入 pipeline 参数，**无需 Python 解析**。

### 8.2 控制器选择（`架构篇:507-511`）

| 名称 | Screencap | Mouse | Keyboard | 权限 |
|---|---|---|---|---|
| Win32 | Background | SendMessageWithCursorPos | PostMessage | 需要 |
| Win32-Front | PrintWindow | Seize | Seize | — |
| Win32-Background | PrintWindow | SendMessageWithWindowPos | PostMessage | 需要 |
| CloudGame-Front | FramePool | Seize | Seize | 需要 |

### 8.3 分辨率适配（`架构篇:523-538`）—— 即 §5.2 的 `screen.map_rect()`

### 8.4 高级主题（`架构篇:544-578`）

- **并发与线程安全**：`CoordinateCapture` / `RouteSession` 均用 `threading.Lock`；**所有 CustomAction 在主线程串行执行**。
- **错误处理**：`try: ... return RunResult(success=True) except: logger.error(...); return RunResult(success=False) finally: 清理资源`。
- **调试模式**：`debug=True` 打开 OpenCV 调试窗口（坐标/角度/匹配结果，支持交互缩放平移）。
- **i18n 工作流**：OCR `expected` 填完整中文 → `.github/workflows/i18n-sync.yml` 自动同步 5 语言。

---

## 9. 对本项目的可借鉴点

| # | 借鉴点 | 项目对应现状 |
|---|---|---|
| 1 | **`next` 首轮命中 + 禁止重试** | AuroraDrive 的 `tick()` 是连续反馈回路，无任务队列/状态机跳转（`MAA移植难度评估报告:55`）——**Pipeline 范式完全不存在对应物** |
| 2 | **`screen.map_rect()` 单一基准缩放** | AuroraDrive 用 `speedROINorm` 归一化 float ROI + `scalesToFit=false` 保持宽高比，思路不同但同样避免错位 |
| 3 | **maafocus 借 focus 字段发消息** | AuroraDrive 自有 Unix socket + 共享内存，不需要此技巧；但「不新增机制、复用既有协议」的思路一致 |
| 4 | **平台优雅降级（win32 缺失 → no-op）** | AuroraDrive 在 macOS 上无此需求；但 `EngineClient` 的「回退本地模式」是同类模式 |
| 5 | **DPI 感知 / 客户区边框补偿** | macOS 无此问题（`NSScreen.backingScaleFactor` 已显式处理） |
| 6 | **`enqueue=True` + 噪音压制 + 根 logger 劫持** | 值得学：AuroraDrive 的多子系统日志（pcapLog / engineLog / engineClientLog）各自为政，未见统一 loguru 化 |
| 7 | **pienv 的 `MacOSConfig` 槽位** | 若将来 macOS 上跑 MaaNTE，这是官方入口 |

---

## 10. 已过期 / 待验证项

| 项 | 状态 |
|---|---|
| `Maa-09` 称「36 from-import / 48 custom_action」 | ⚠️ **已过期** → 实测 40 / 57（上游新增 VolleyballWeekly、PukaLand、lucky_star） |
| `Maa-09` 称「21 个任务 JSON 注册」 | ⚠️ **已过期** → 实测 28 |
| `Maa-09` 称「requirements 17 项」 | ⚠️ **已过期** → 实测 15 包 |
| `Maa-10` 称 `pienv.py`(355) / `logger.py`(242) / `i18n.py`(124) / `screen.py`(41) / `maafocus.py`(33) / `win32_process.py`(503) | ✅ 本地核对一致（354/242/124/41/33/503，仅 pienv 差 1 行） |
| `Maa-10` 称 `agent/utils/` 共 1300 行 | ✅ 实测 1300 |
| `Maa-10` 称 `main.py` 571 行 + `interface.json` 159 行 | ⚠️ `interface.json` 实测 **161 行**（差 2 行） |
| `架构篇:582` 文档版本写「最后更新 2026-09-13（原文误写 2025）」 | ⚠️ 原文自认的笔误 |
| `_check_game_resolution()` 在 macOS 的等价物 | **未验证**（依赖 win32_process，需重写为 NSWindow/CGWindowList 方案） |

---

## 11. 原文处置建议

| 原文 | 处置 | 理由 |
|---|---|---|
| `MAA深度文档_架构篇.md`（582） | **保留**，但标注 3 处数量已过期 | 架构分层 / Pipeline 原则 / 开发者规范仍然准确且有价值 |
| `Maa-09-main.py入口与MaaFramework核心流.md`（153） | **保留，需更新 3 处数字** | 逐单元分析质量高，但 from-import / custom_action / 任务 JSON 数与上游漂移 |
| `Maa-10-agent-utils基础设施六件套.md`（280） | **保留** | 六件套逐文件分析准确（本地核对一致），DPI 与降级模式是宝贵工程记录 |
| `00-本目录说明.md`（34） | **保留** | 目录导航 + 时效性声明，是整组的索引 |

**本篇新增的核对结论（原文没有的）**：
1. 实测 40 from-import / 57 custom_action / 56 `__all__` / 28 任务 JSON，推翻原文的 36/48/21。
2. `utils/__init__.py` 只导出 logger/pienv/screen 三件，解释了 `agent()` globals 注入为何不含 `T()`。
3. `pienv.py` 原生含 `MacOSConfig(title_regex/screencap/input)` —— macOS 是官方预留路径。
4. `maafocus.py` 的 `focus` 字段技巧已本地核对逐字一致。

---

*本篇为整合文档，未删改任何原文件。代码引用均已去本地 `MaaNTE/` 核对。*
