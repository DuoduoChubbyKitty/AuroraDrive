# Maa-10 agent/utils 基础设施六件套

> 覆盖源文件：`MaaNTE/agent/utils/`（6 文件 1300 行）：pienv.py（355）+ win32_process.py（503）+ logger.py（242）+ i18n.py（124）+ screen.py（41）+ maafocus.py（33）+ `__init__.py`（3）。基于当前仓库逐单元编写。

## 一、utils 包导出面（__init__.py 3 行）

```python
from .logger import *
from .pienv import *
from . import screen
```

**⚠️ 关键结构事实**：**只有 logger / pienv / screen 进 `utils` 命名空间**；`i18n` / `maafocus` / `win32_process` **不导出**——必须显式 `from utils.i18n import T` 或相对导入 `from . import pienv`（logger.py 6 行用的就是相对导入）。

**这解释了 main.py 的 `globals()` 注入（代码 Maa-09 单元三）**：agent() 里 `for attr_name in dir(utils): globals()[attr_name] = ...` 注入的只是 **logger + pienv 的全部公共名 + screen 模块对象**——所以后续代码能裸写 `logger.xxx` / `screen.map_point(...)`，但 i18n 的 `T()` 必须自己 import。

**全仓调用关系（grep 实测）**：

| 工具 | 调用方 | 规模 |
|---|---|---|
| `PrintT` / `Print` | 各 CustomAction 用户可见消息 | **96 处** |
| `screen.*` | main.py（分辨率自检）+ AutoFish 三文件（坐标换算） | 4 文件 |
| `ensure_game_window_resolution` | pinkpaw 四文件 + Common/resize_game_window.py | 5 文件 |
| `pienv.*` | logger.py（客户端判定）+ i18n.py（语言判定） | 2 文件 |

## 二、pienv.py（355 行）——PI v2.5.0 环境协议解析

**8 个环境变量常量（11–19 行）**：`PI_INTERFACE_VERSION` / `PI_CLIENT_NAME` / `PI_CLIENT_VERSION` / `PI_CLIENT_LANGUAGE` / `PI_CLIENT_MAAFW_VERSION` / `PI_VERSION` / **`PI_CONTROLLER`（JSON 串）** / **`PI_RESOURCE`（JSON 串）**。

**容错转换器（22–48 行）**——**全线不抛异常**：

| 函数 | 规则 |
|---|---|
| `_as_string` | None → ""，其余 str() |
| `_as_int` | None/bool → None（**bool 显式排除**）；int 直返；str 试 int() 失败 → None |
| `_as_bool` | **只有真 bool 才返回，其他一律 None**（字符串 "true" 不认——避免歧义） |
| `_as_string_list` | 非 list → []；逐项 `_as_string` 且**过滤 None 项** |

**4 个冻结配置 dataclass（51–116 行）——跨平台 controller 模型**：

| 类 | 字段 | 平台 |
|---|---|---|
| `Win32Config` | class_regex / window_regex / screencap / mouse / keyboard | Windows |
| `MacOSConfig` | **title_regex / screencap / input** | macOS |
| `PlayCoverConfig` | **uuid** | PlayCover（iOS 投屏） |
| `GamepadConfig` | class_regex / window_regex / gamepad_type / screencap | 手柄 |

- **⚠️ 全部 `from_dict` 都先 `isinstance(data, dict)` 判定，非 dict 返回 None（不抛）**——**唯一抛异常的是 `Controller.from_dict` / `Resource.from_dict`（139–142、174–177 行）：`raise TypeError("PI_CONTROLLER is not a JSON object")`**——但外层 `_parse_json_env`（207–215 行）用 `except Exception` 兜住 → **最终仍返回 None + warning**（双层防御）

**`Controller`（119–161 行）——含未使用平台字段**：name/label/description/icon/type/**display_short_side/display_long_side/display_raw**（显示尺寸约束）/permission_required/attach_resource_path/option + 五平台配置 + **`adb` / `wlroots` 以 `Any` 原样保留（不做解析——项目不用 Android/Linux）**。

**`Resource`（164–186 行）**：name/label/description/icon/**path（资源目录列表）**/controller（**该资源适用的 controller 白名单**）/option。

**单例与线程锁（203–260 行）**：

```python
_global_env: Env | None = None
_init_lock = threading.Lock()

def init(force: bool = False) -> Env:
    global _global_env
    with _init_lock:
        if force or _global_env is None:
            _global_env = _build_env()
    return _global_env

def get() -> Env: return init()
```

- **惰性 + 双检**：首次访问才解析环境；`force=True` 强制重读（**测试/环境切换用**）
- **`_build_env()`（218–248 行）**：读 8 变量 → **`controller_raw` / `resource_raw` 原样留档（供调试）** + JSON 解析后的对象 → **一行 info 打印 8 字段 + controller_ok/resource_ok 布尔**

**20 个访问器（263–321 行）**：`interface_version()` / `client_name()` / `client_version()` / `client_language()` / `client_maafw_version()` / `project_version()` / `controller()` / `resource()` / `controller_type()` / `controller_name()` / `resource_name()` / `resource_label()`（**label 空则回退 name**，310–314 行）/ `resource_paths()`（**返回副本 list(current.path)——防外部改内部状态**）。

## 三、logger.py（242 行）——三客户端自适应日志

**核心设计：同一份日志按客户端能力三态输出（51–62 行）**：

| 客户端判定（客户端名大写匹配） | 输出流 | 格式 |
|---|---|---|
| **MFAAvalonia**（`_is_mfaa_client`） | **stderr** | `{extra[level_short]}:{message}`——如 `info:xxx`（**MFAA 解析短级别名**） |
| **MXU**（`_is_mxu_client`） | **stdout** | `{extra[mxu_html_message]}`——**HTML span 着色（MXU 富文本渲染）** |
| 其他 | stderr | ANSI 真彩色转义 |

**三色表（8–36 行）**：ANSI（TRACE 蓝 34 / DEBUG 青 36 / INFO+SUCCESS 绿 32 / WARNING 黄 33 / ERROR 红 31 / **CRITICAL 红底白字 41+37**）+ HTML（royalblue/deepskyblue/forestgreen/darkorange/crimson/firebrick）+ 短名表（INFO→info、ERROR→err、WARNING→warn…）。

**`_enrich_record`（78–88 行）——loguru filter 注入 extra**：**每次记录写入前把 level_short / level_color / color_reset / mxu_html_message 四个字段塞进 record["extra"]**——格式串里的 `{extra[...]}` 才能取到值；**`_format_mxu_html_message` 对 message 做 `html.escape`（防注入/防标签破坏）**。

**loguru 优先 + 标准 logging 回退（91–100、226–230 行）**：

```python
try:
    from loguru import logger as _imported_loguru_logger
    _HAS_LOGURU = True
except ImportError:
    pass

def setup_logger(log_dir="debug/custom", console_level="INFO"):
    if _HAS_LOGURU:
        return _setup_loguru_logger(...)
    return _setup_std_logger(...)
```

**`_setup_loguru_logger`（161–193 行）——双 sink**：

| sink | 参数 |
|---|---|
| 控制台 | `_resolve_console_stream()` + 客户端格式 + **`colorize=False`（自己不染，交给 extra 里的转义串）** + level=console_level + filter |
| 文件 | `{log_dir}/{time:YYYY-MM-DD}.log` + **rotation="00:00"（零点切）+ retention="2 weeks" + compression="zip"（自动压缩归档）** + level 恒 DEBUG + **`enqueue=True`（多线程/多进程安全）+ backtrace + diagnose** |

- **`_InterceptHandler`（106–120 行）——标准 logging → loguru 桥**：`logging.currentframe(), depth = 2` 后 **while 循环沿 f_back 上溯跳过 logging 模块内部帧（`frame.f_code.co_filename == logging.__file__`）**——**修正调用点行号（否则日志全指向 logging/__init__.py）**；`opt(depth=depth, exception=record.exc_info)` 保留异常栈
- `_ROOT_LOGGER.handlers = [_InterceptHandler()]`（186 行）——**劫持根 logger：第三方库（MaaFramework/opencv）走标准 logging 的输出也进 loguru**
- **噪音压制（143、152–154 行）**：cv2 / numpy / PIL / matplotlib / urllib3 / asyncio → WARNING

**`_setup_std_logger`（196–223 行）——无 loguru 时**：StreamHandler（`_ConsoleFormatter` 复刻同样的三态逻辑，123–135 行）+ **`TimedRotatingFileHandler(when="midnight", backupCount=14)`**（**保留 14 天——与 loguru 版 "2 weeks" 语义对齐**）+ `_FILE_FORMAT`（138–140 行）：`时间 | 级别-8 | 模块:函数:行号 | 消息`。

**模块级立即执行（239–242 行）**：`setup_logger(console_level="INFO")` + `logger = get_logger("maante")`——**import utils.logger 即完成日志系统初始化**；`change_console_level("DEBUG")`（233–236 行）供 `main.py --dev` 用（**内部是重新 setup_logger，会重建 sink**）。

## 四、i18n.py（124 行）——五语言查表

**语言常量（12–17 行）**：zh_cn / zh_tw / en_us / ja_jp / ko_kr，**DefaultLang = zh_cn**。

**`_resolve_locale_dir()`（31–57 行）——双向六层上溯搜索**：

- 候选起点两个：**`Path.cwd()`（运行时工作目录）+ `Path(__file__).resolve().parent.parent.parent`（本文件上三级 = 项目根）**
- 每起点**最多上溯 6 层**，逐层试两相对路径：`assets/resource/locales/agent`（生产布局）/ `resource/locales/agent`（dev 布局）
- **判定凭据：`{dir}/zh_cn.json` 存在**
- 全失败 → 返回 `cwd/assets/resource/locales/agent`（**兜底路径，后续加载会 warning 但不再抛**）
- **设计意图：兼容 `main.py` 生产运行时 chdir(项目根) 与 dev 模式 chdir(assets) 两种 cwd**

**`_load_messages(lang)`（60–83 行）——叠加式加载**：

```
先 load(DefaultLang=zh_cn) 打底 → 若 lang != 默认 → load(lang) 覆盖
```

- **缺失 key 自动回退中文**（`msgs.update` 语义）——**五个语言文件不必逐 key 对齐**
- 默认语言文件都读不到 → 返回 `{}`（**T() 随后原样返回 key**）

**`init()`（86–100 行）**：`pienv.client_language()` → `_normalize_lang`（**去空白 + 小写 + 白名单外一律 zh_cn**）→ 解析目录 → 加载 → **一行 info 记录 raw 值/解析值/目录/条目数**（**排障三要素齐备**）。调用点在 `main.py agent()` 的 `AgentServer.start_up()` 之前。

**`T(key, *args)`（107–114 行）**：

```python
val = _messages.get(key)
if val is None: return key      # 没这条翻译 → 直接把 key 当文本（不抛）
if args: return val % args      # %-格式化（与 logger 的 % 风格一致）
```

**`separator()`（117–119 行）**：**CJK（zh_cn/zh_tw/ja_jp）用 "、"，en_us/ko_kr 用 ", "**——列表拼接的语种标点适配。

**`RenderHTML(key, data=None)`（122–124 行）**：**注释明写"当前简化实现，直接返回 T(key)"——`data` 参数被忽略（预留未实现）**。

## 五、screen.py（41 行）——分辨率基准与坐标换算

**基准常量（4–5 行）**：`BASELINE_WIDTH = 1280` / `BASELINE_HEIGHT = 720`——**全项目 pipeline 图片/ROI/坐标的唯一基准（AGENTS.md 明令）**。

**四全局态（7–10 行）**：`_current_width/_current_height`（当前实际）+ `_scale_x/_scale_y`（相对基准比例，初值 1.0）。

**`update_screen_size(w, h)`（25–31 行）**：写当前尺寸 + **`_scale_x = w / 1280`、`_scale_y = h / 720`（各自独立——非等比缩放也正确）**；**分母做了 `if BASELINE_WIDTH else 1.0` 的除零防护**。

**换算 API**：

| 函数 | 语义 |
|---|---|
| `map_point(x, y)` | `(round(x·sx), round(y·sy))`——**基准坐标 → 实机坐标** |
| `map_rect(rect)` | 四元组 (x,y,w,h) 同比例换算（**w/h 用各自轴比例**） |
| `uniform_scale()` | `min(sx, sy)`——**需要单标量的场景（圆形半径/字号）取小值保证不溢出** |
| `current_size()` / `scaling_factors()` | 只读访问 |

**调用点**：`main.py _check_game_resolution()`（非 720p 时 warning + 更新）+ AutoFish 三文件（**钓鱼按钮/进度条坐标随窗口换算**）。

## 六、maafocus.py（33 行）——MXU 用户消息通道

**机制（10–28 行）——借 pipeline 协议发消息**：

```python
_FOCUS_NODE = "_MAANTE_FOCUS_"

pipeline_override = {
    _FOCUS_NODE: {
        "focus": {"Node.Action.Starting": content},   # focus 协议字段
        "action": "DoNothing",                        # 不做任何操作
        "pre_delay": 0, "post_delay": 0,              # 零延迟（不拖慢流程）
    }
}
context.run_action(_FOCUS_NODE, pipeline_override=pipeline_override)
```

- **⚠️ 这是本项目的"消息总线"技巧**：MaaFramework 的 `focus` 字段是给客户端 UI 显示进度用的——**这里临时造一个 `_MAANTE_FOCUS_` 节点 + override 注入，让文本直达 MXU 界面**；节点名以下划线开头（**与 pipeline 私有节点 `__` 前缀约定不同，这里用单下划线且全局唯一**）
- **`action: DoNothing` + 双 delay 0**：只为传消息，不影响任务时序
- `context is None` → warning 跳过；`run_action` 异常 → warning（**消息失败不炸任务**）

**`PrintT(context, key, *args)`（31–33 行）**：`Print(context, T(key, *args))`——**i18n 版本（96 处调用点的标准入口）**；`Print` 为原样文本版（不做 i18n）。

## 七、win32_process.py（503 行）——Win32 窗口操作底层

**ctypes 全量显式绑定（6–64 行）——本文件最重要的工程质量点**：

- `user32` / `kernel32` 全局句柄 + **20+ 个函数的 `argtypes` / `restype` 逐个声明**（GetWindowRect / GetClientRect / GetWindowThreadProcessId / GetWindowTextLengthW / GetWindowTextW / GetClassNameW / GetWindowLongW / SetWindowLongW / SetWindowPos / MonitorFromWindow / GetMonitorInfoW / IsIconic / IsZoomed / IsWindow / IsWindowEnabled / IsWindowVisible / ShowWindow / GetSystemMetrics / Sleep）
- **⚠️ 坑位（源注释 58–60 行）**："使进程感知 DPI，避免 GetClientRect 返回缩放后的虚拟坐标。**150% 缩放时未设置此项会导致返回值只有实际分辨率的 2/3**" → `user32.SetProcessDPIAware()`（**模块级 import 即执行**）——**不设则 1920×1080 客户区被读成 1280×720，分辨率自检会误判为"正常"**

**Win32 常量表（66–82 行）**：TH32CS_SNAPPROCESS=0x2 / **DEFAULT_GAME_PROCESS_NAME="HTGame.exe"** / DEFAULT_WINDOW_RESIZE_SETTLE_MS=300 / SW_RESTORE=9 / GWL_STYLE=-16 / WS_CAPTION=0x00C00000 / WS_POPUP=0x80000000 / SM_CXSCREEN/SM_CYSCREEN / SWP_*（NOSIZE/NOREPOSITION/NOZORDER/NOACTIVATE/NOMOVE/FRAMECHANGED/SHOWWINDOW）/ MONITOR_DEFAULTTONEAREST=0x2。

**两个结构体**：`PROCESSENTRY32W`（**szExeFile 用 `c_wchar * 260`——Unicode 路径**）+ `MONITORINFO`（cbSize 必须先填）。

**进程枚举 `get_pids_by_name`（126–143 行）**：CreateToolhelp32Snapshot → Process32FirstW/NextW 循环 → **`entry.szExeFile.lower() in process_names`（小写比对）** → CloseHandle；**`_normalize_process_names`（113–123 行）先 `os.path.basename` 剥路径 + 小写 + 去重**（**允许传完整路径**）。

**窗口枚举 `find_windows_by_process`（175–218 行）——五重过滤**：

| 过滤 | 条件 |
|---|---|
| 1 | `IsWindow` + `IsWindowEnabled`（**禁用的窗口不算**） |
| 2 | `IsWindowVisible` |
| 3 | `GetWindowThreadProcessId` ∈ pid 集合 |
| 4 | **`_match_class_name`（161–172 行）：精确等值 OR `re.search` 正则**（支持 str 或 list，None 表示不限） |
| 5 | 客户区存在且 **宽高均 > 10px**（滤掉工具窗/隐藏窗） |

→ 返回 dict 列表（hwnd / client_size / **client_area（面积，供排序）** / window_rect / title / class_name / **order（枚举序）**）。

**`find_window_by_process`（221–250 行）——三级选择策略**：

```
selected_hwnd 显式指定命中 → 直接返回
否则 last_hwnd 命中 且 最大窗口面积 <= last 面积 × 1.1 → 返回 last（面积接近时优先沿用上次窗口）
否则返回最大客户区窗口
```

**设计意图**：显式 > 稳定（沿用上次）> 最大——**避免多窗口（登录器/启动器）时选错**。

**窗口样式 `show_title_bar`（289–309 行）**：已有 WS_CAPTION → true；否则 **`new_style = (cur | WS_CAPTION) & ~WS_POPUP`** + SetWindowPos(FRAMECHANGED|NOMOVE|NOSIZE|SHOWWINDOW) + Sleep(10) → **回读校验**（不返回盲信）。

**`resize_window`（312–363 行）——"跟随 OK-NTE 的时序"（源注释）**：

1. SetWindowPos 设尺寸（SHOWWINDOW|NOZORDER|NOMOVE）+ Sleep(10)
2. 居中：读当前 rect + **`_get_window_work_area`（277–286 行：MonitorFromWindow 取工作区，失败退 GetSystemMetrics 全屏）** → **工作区小于窗口 → 直接 False**；算出 expected_left/top → 二次 SetWindowPos（NOSIZE|NOZORDER|SHOWWINDOW）
3. **收敛轮询：最多 50 次 × Sleep(100ms) 检查尺寸+位置完全相等，跳出后固定 Sleep(500)**——**总计最多 ~5.5s**

**`resize_client_area`（366–411 行）——客户区精确尺寸**：

- 最小化/最大化 → `ShowWindow(SW_RESTORE)` + Sleep(100)
- **补标题栏（show_title_bar）——否则后续 border/title 差值算不准**
- **容差短路（381–385 行）**：客户区与目标差 ≤ tolerance（默认 2）→ 直接 True
- **边框补偿（387–393 行）**：`border = 窗口宽 - 客户宽`、`title_height = 窗口高 - 客户高` → `resized = target + border/title`（**目标设的是客户区，SetWindowPos 设的是外框——必须补差**）
- 工作区容纳检查 → 调 resize_window → **20 次 × Sleep(50ms) 复查客户区**
- **⚠️ 返回 False 的语义（397–398、411 行）**：工作区装不下 / 轮询超时——**调用方可据此回退**

**`ensure_process_client_size`（414–486 行）——统一结果 dict**：

```python
{"success": bool, "reason": str, "hwnd": ..., "before": ..., "after": ...}
```

| reason | 触发 |
|---|---|
| `window_not_found` | 找不到窗口 |
| `client_size_unavailable` | GetClientRect 失败 |
| `already_matched` | 已在容差内（**不重复 resize，success=True**） |
| `resized` | 成功（**success 后 Sleep(settle_ms=300) 稳定 + `_log` 打印 `before→target`**） |
| `resize_failed` | resize 失败 |

**`ensure_game_window_resolution(width, height, ...)`（489–503 行）**：薄封装，**默认 process_name = "HTGame.exe" + settle_ms = 300**。

**调用方（grep 实测）**：**pinkpaw 四文件 + `Common/resize_game_window.py`**；**⚠️ pinkpaw_common.py（16–22 行）用双路径 import 兜底**：

```python
try:
    from agent.utils.win32_process import ensure_game_window_resolution
except ImportError:
    try:
        from utils.win32_process import ensure_game_window_resolution
    except ImportError:
        ensure_game_window_resolution = None      # 非 Windows / 缺 ctypes → 置 None
```

**`resize_game_window.py` 同样在 ImportError 时置 None + 98 行 `if ensure_game_window_resolution is None:` 短路**——**这是全项目唯一的"平台缺失优雅降级"模式：win32 能力缺失时动作变 no-op，任务链不中断**。

---

**Maa-10 文档至此完整**（utils 六件套 1300 行 + 导出面 + 全仓调用关系；含 DPI 感知、客户区边框补偿、loguru 桥接、i18n 六层上溯等关键工程点）
