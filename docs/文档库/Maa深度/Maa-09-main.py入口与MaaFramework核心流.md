# Maa-09 main.py 入口与 MaaFramework 核心流

> 覆盖源文件：`MaaNTE/agent/main.py`（571 行）+ `MaaNTE/assets/interface.json`（159 行）+ `MaaNTE/agent/custom/__init__.py`（1 行）+ `MaaNTE/agent/custom/action/__init__.py`（87 行）+ `MaaNTE/requirements.txt`（17 行）。基于当前仓库逐单元编写。

## 一、入口自举 main()（第 550–571 行）

**顶层自举（1–25 行）**：

1. `sys.stdout.reconfigure(encoding="utf-8")`（10 行）——**Windows 控制台 GBK 编码兼容**
2. CWD 修正（13–20 行）：`os.chdir(project_root_dir)`——**源注释（15 行）："假定的项目根目录"（main.py 上级目录）**；此后所有相对路径（./config、./debug、./assets）都以项目根为锚
3. `sys.path.insert(0, current_script_dir)`（24–25 行）——**让 `import utils` / `import maa` / `import custom` 可解析**

**`MAAHUB_ACCENT`（32–49 行）——MaaHub 客户端品牌注册**：固定 accent id `9e8de7d9-...`、五色 i18n label（zh-CN/zh-TW/en-US/ja-JP/ko-KR 全写 "MaaHub"）、**单一颜色 `#fe9800`（四档 default/hover/light/lightDark 同色）**。

**⚠️ 路径兼容性检测（51–59 行）**：`re.search(r"[一-鿿　-〿＀-￯]", cwd)`——**CJK 统一表意 + 全角标点 + 全角 ASCII 区**命中即 warning："部分组件对此类路径兼容性较差，建议将程序移动至纯英文路径下运行"。**当前 checkout 位于 `/Users/dupi/Desktop/自动驾驶系统`（含中文）——本检测在设计上就是为此类场景预留的**（仅警告，不拦截）。

**main() 流程（550–567 行）**：

| 步 | 条件 | 行为 |
|---|---|---|
| 1 | 恒 | `read_interface_version()`：根 `interface.json` 存在 → 读其 `version` 字段；**只在 `assets/interface.json` 存在（开发布局）→ 返回 "DEBUG"**（195–215 行——**dev 模式判定依据**） |
| 2 | Windows | `_check_admin_privilege()`（436–446 行）：`ctypes.windll.shell32.IsUserAnAdmin()` 非管理员 → **warning "部分输入功能可能无法正常使用。请右键 MaaNTE.exe → 以管理员身份运行"** |
| 3 | Linux 或 dev 模式 | `ensure_venv_and_relaunch_if_needed()`（**Windows 生产构建跳过 venv——依赖打包在 deps/whl**） |
| 4 | 恒 | `check_and_install_dependencies()` |
| 5 | dev 模式 | `os.chdir(Path("./assets"))`——**开发布局：pipeline/resource 相对 assets/ 解析** |
| 6 | 恒 | `agent(is_dev_mode)` |

## 二、venv 自举与依赖安装（第 69–428 行）

**`_is_running_in_venv()`（69–79 行）**：`sys.prefix != sys.base_prefix`——**venv 内的 sys.prefix 指向 .venv，base_prefix 指向系统 Python（标准判定）**。

**`ensure_venv_and_relaunch_if_needed()`（82–156 行）——不在 venv 内则创建并重启**：

- `.venv` 不存在 → `subprocess.run([sys.executable, "-m", "venv", ...])`（**用当前解释器创建**）
- 平台路径（116–126 行）：Windows → `Scripts/python.exe`；Linux → `bin/python3`（缺失退 `bin/python`，再缺失**默认 python3 让后续错误处理捕获**）
- **⚠️ 坑位（136–139 行源注释）**："Use absolute path to this script when relaunching inside the venv. **sys.argv[0] may be a relative path (e.g. './../agent/main.py') which resolves differently when cwd changes.**" → 重启命令恒用 `current_file_path`（绝对）+ `sys.argv[1:]` → `subprocess.run(check=False)` + **`sys.exit(result.returncode)`（子进程退出码直接上抛）**

**`install_requirements()`（326–411 行）——三级安装策略**：

1. **`deps/` 目录不存在 → 直接 return True（329–330 行）——生产环境无本地 whl 时跳过安装**
2. 有 whl → **本地优先：`--find-links deps/ + --no-index`（pip 只认本地文件，禁止在线索引）**；失败 → 回退在线
3. 在线：**主镜像（config/pip_config.json，默认清华源）+ 备用源（中科大，`--extra-index-url` 只挂一个避免冲突）**；无配置 → 裸 pip（用用户全局配置）

**配置持久化 `read_config()`（164–192 行）**：`./config/<name>.json` 不存在 → **mkdir + 写默认值**；读失败 → 默认值兜底。pip 默认：`enable_pip_install: true` + tuna/ustc 双镜像；热更默认 `enable_hot_update: true`（`read_hot_update_config`，227–232 行）。

**requirements.txt（17 项，依赖语义分组）**：

| 组 | 包 | 用途 |
|---|---|---|
| MaaFramework | **`maafw==v5.10.4`** | pip 轮子：提供 `maa.agent.agent_server.AgentServer` / `maa.tasker.Tasker` / `maa.custom_action` / `maa.context` |
| CV | opencv-python + pillow + numpy | 模板匹配/图像 |
| 模型 | **onnxruntime-directml** | **Windows DML 后端（Xbox/核显加速）——macOS 需换 onnxruntime** |
| 音频 | librosa + scipy + soundcard + **scapy + pktmon-interface** | SoundTrigger 听声链路（pktmon 抓包解析音频流） |
| MIDI | **mido** | auto_piano |
| 网络 | requests + **websockets>=14.0,<17.0** | Navi 导航服务 |
| ML | scikit-learn | 节奏/决策模型 |
| 杂 | loguru + pytz | 日志/时区 |

## 三、agent() MaaFramework 核心流（第 483–542 行）

**模块缓存清理（485–496 行）——本文件最怪的代码段**：

```python
utils_modules = [n for n in list(sys.modules.keys()) if n.startswith("utils")]
for module_name in utils_modules:
    del sys.modules[module_name]
import utils
importlib.reload(utils)
for attr_name in dir(utils):
    if not attr_name.startswith("_"):
        globals()[attr_name] = getattr(utils, attr_name)
```

**语义**：venv 重启后旧模块缓存可能指向系统 site-packages 的编译产物——**删除所有 `utils*` 模块 → 重新 import + reload → 把 utils 的全部公共属性注入 agent() 的 globals**（**后续代码可直接 `logger.xxx` 而不再写 `utils.logger`**）。

**核心启动（509–535 行）**：

1. `from maa.agent.agent_server import AgentServer; from maa.tasker import Tasker`（maafw 包）
2. **`import custom`（512 行）——触发 `agent/custom/__init__.py`（内容仅 `from .action import *`）→ 连锁导入 `agent/custom/action/__init__.py` 的 36 个 from-import → 全部 48 个 `@AgentServer.custom_action` 注册生效**（grep 实测 48 custom_action + 1 custom_recognition）
3. `Tasker.set_log_dir("./debug")`（514 行）
4. `i18n_init()`（516–518 行）
5. **`socket_id = sys.argv[-1]`（520–524 行）——AgentServer 与 MaaHub 前端的本地 socket 标识（interface.json `agent.child_args` 传入）**
6. `log_pi_environment()`（527 行）：打印 9 个 PI_* 环境变量快照（PI_INTERFACE_VERSION/PI_CLIENT_NAME/PI_CLIENT_MAAFW_VERSION 等，**>300 字符截断**）
7. **启动序列（528–534 行）**：`AgentServer.start_up(socket_id)` → **`_check_game_resolution()`（控制器连接后跑）** → `AgentServer.join()`（阻塞主循环）→ `finally: AgentServer.shut_down()`

**`_check_game_resolution()`（449–475 行）——1280×720 基准自检**：

- `find_window_by_process("HTGame.exe")`（453 行）——**《异环》Windows 端进程名 HTGame.exe**
- 尺寸 ≠ (1280, 720) → **warning "请将游戏设置为 1280x720 窗口化模式，否则部分功能可能异常"** + `screen.update_screen_size(w, h)` 更新全局缩放因子（`screen.scaling_factors()`）

## 四、interface.json 全局注册（159 行）

**头部（1–19 行）**：`interface_version: 2` / name MaaNTE / **AGPL-3.0** / version 0.0.4 / `mirrorchyan_multiplatform: true` / **5 个 locale 文件映射**（resource/locales/interface/{zh_cn,zh_tw,en_us,ja_jp,ko_kr}.json）。

**4 个 controller（20–71 行）——同一窗体四种抓取/输入姿态**：

| 名称 | screencap | mouse | keyboard | 特权 | 说明 |
|---|---|---|---|---|---|
| **Win32**（默认） | Background | SendMessageWithCursorPos | PostMessage | permission_required | 后台抓取 + 光标定位消息注入 |
| **Win32-Front** | PrintWindow | **Seize** | **Seize** | 无 | 前台独占（截获真实鼠标键盘） |
| **Win32-Background** | PrintWindow | SendMessageWithWindowPos | PostMessage | 有 | 纯后台消息注入 |
| **CloudGame-Front** | **FramePool** | Seize | Seize | 有 | **云游戏场景：class_regex 换 "Qt.*" + FramePool 帧池抓取** |

- **窗体定位（三种 Win32 共用）**：`class_regex: "UnrealWindow"`（**UE5 引擎窗类名**）+ `window_regex: "^\\s*(异环|NTE)\\s*$"`（**窗口标题精确匹配"异环"或"NTE"，首尾空白容忍**）

**其余注册段**：

- `resource: [{官服 → resource/base}]`（72–80 行）——pipeline/图片资源根
- **`agent: {child_exec: "python", child_args: ["../agent/main.py"]}（81–86 行）——MaaFramework 把 main.py 拉起来当子进程，socket 通信（这就是 main.py 只收 socket_id 的原因）**
- 6 个 group（87–118 行）：Daily / CityTycoon / HethereauHobbies / RealTimeAssist / DatasetCollection / UserInfo（**全 default_expand: true**）
- `task: []` + `option: {}`（119、158 行）——**自身不定义任务，全部来自 import**
- **`import`（120–157 行）——21 个任务 JSON 注册**（按 group 注释分组）：
  - Daily：ClaimRewards
  - CityTycoon：Furniture、WithdrawMoney
  - HethereauHobbies：Fish、BidKing、PinkPawHeist、MakeCoffee、MakeCoffeeLite、MakeTomatoJuice、Rhythm、Tetris、Volleyball、BagelSpam
  - RealTimeAssist：RealTime、OnlineMapNavigation、SoundDodge、AutoFScroll
  - others：FountainCheckin、AutoPiano、WitchDivination、Touch
  - DatasetCollection：AutonomousDrivingDataset
  - UserInfo：SyncCharacterAbilityCityAbility
  - preset：**AFK + RealtimeAssistance 启用；FullDaily / QuickDaily 被注释停用（154–155 行）**
  - **注意（151 行注释）：Touch.json 归在 "group:others" 但注册在 UserInfo 注释块之后——注释与 group 实际归属不完全对应，以 interface.json `group` 数组 + 各 task JSON 的 `group` 字段为准**

## 五、CustomAction 注册体系（agent/custom/action/__init__.py 87 行）

**注册模式（Common/click.py 27–45 行样例）**：

```python
@AgentServer.custom_action("click_override")
class ClickOverride(CustomAction):
    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        controller = context.tasker.controller
        params = load_params(argv.custom_action_param)   # pipeline 侧 "param" 透传
        ...
        return CustomAction.RunResult(success=True)      # 或 success=False
```

**`agent/custom/action/__init__.py`——36 条 from-import + 49 个 `__all__` 导出名**：

| 域 | 导出类 |
|---|---|
| 咖啡/钓鱼 | AutoMakeCoffee / AutoMakeCoffeeLite / AutoMakeTomatoJuice / AutoFish / AutoBuyFishBait / AutoSellFish / AutoFishWithoutCV / EnterFishPrepare |
| 节奏/方块 | AutoRhythmPlay / AutoRhythmRepeatDecision / AutoRhythmSelectSong / AutoTetris |
| 实时 | RealTimeTaskAction / OnlineMapNavigationAction / LocalRouteNavigation(+Action/+UnitTestAction) / **parse_route_waypoints / resolve_route_json_path（工具函数也导出）** |
| 传送 | CheckTeleportRequiredAction / TeleportDecision / **check_teleport_required（函数）** |
| 粉色爪 | PinkPawHeistScheme1/2/3Action / FindXiaoZhi / ReturnToEntrance / PinkPawRewardSummary |
| 音游/躲避 | SoundDodgeAction / VolleyballReset/SelectDifficulty/SelectTeammates/Play/AdvanceDifficulty |
| 杂项 | ClickOverride / EnableNode / ResizeGameWindow / AltClick / AutoFScroll / FurnitureClaim / FurnitureChooseProperty / AutoPlayPiano / WithdrawMoneyChooseItem / AutonomousDrivingDatasetRecorder / SyncCharacterAbilityCityAbilityMainAction / BagelSpamPickIndex / BagelSpamOutputText / BagelSpamLLMGenerate |

**AGENTS.md 约定（仓库级纪律）**：注册名 snake_case 且**必须与 pipeline JSON 的 `custom_action` 字段一致**；用户可见消息走 `PrintT(context, key, ...)`（禁 print）；logger 用 **% 格式化**（不用 f-string）；长循环每次迭代查 `context.tasker.stopping`；坐标全部 1280×720 基准；截图 `controller.post_screencap().wait()` → `controller.cached_image`（numpy BGR）；通用工具 `from Common.utils import get_image, click_rect, match_template_in_region`；模块级状态用全局变量 + 独立 `_reset` 动作。

---

**Maa-09 文档至此完整**（main.py 571 行 + interface.json 159 行 + 注册体系 36 from-import/49 导出全量覆盖；maafw==v5.10.4 锁定 MaaFramework 版本基线）
