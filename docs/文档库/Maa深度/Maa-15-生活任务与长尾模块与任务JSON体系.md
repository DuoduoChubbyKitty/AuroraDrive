# Maa-15 生活任务、长尾模块与任务 JSON 体系

> 覆盖源文件：`MaaNTE/agent/custom/action/`（AutoFish 877 + AutoCoffee 536 + pinkpaw 6507 + Furniture 162 + BagelSpam 338 + Common 676 + DatasetCollection 222 + Movement 109）+ `assets/resource/tasks/`（25 文件 + preset 4 = 29 JSON，**28 个 task 定义 / 78 个 option**）。基于当前仓库逐单元编写。

## 一、Common（676 行）——全项目公用动作与工具

**⚠️ 这是被引用最多的模块**（Maa-12 teleport_to_point 27 行 `from ..Common.utils import match_template_in_region`；排球 `from .Common.utils import get_image`）。

| 文件 | 行 | 内容 |
|---|---|---|
| `CharacterAbility_CityAbility.py` | **370** | **角色能力/城市能力同步（最大文件）** |
| `resize_game_window.py` | 113 | **窗口尺寸动作（CustomAction）** |
| `utils.py` | 90 | **`get_image` / `click_rect` / `match_template_in_region`（三大公用工具）** |
| `click.py` | 31 | **`ClickOverride`（`click_override` 注册：支持显式 target 或 reco_detail box）** |
| `alt_click.py` | 29 | **`AltClick`（Alt+点击）** |
| `enable_node.py` | 27 | **`EnableNode`（运行时启用/禁用 pipeline 节点）** |
| `__init__.py` | 9 | 包导出 |
| `logger.py` | 7 | **`get_logger`（薄封装，供各模块 `from ..Common.logger import get_logger`）** |

**`resize_game_window.py`（113 行）——平台优雅降级范例**：

```python
try:
    from utils.win32_process import ensure_game_window_resolution
except ImportError:
    ensure_game_window_resolution = None
...
if ensure_game_window_resolution is None:      # 98 行
    return RunResult(success=?)                  # 非 Windows 直接短路
```

**与 `pinkpaw_common.py` 的三重 try 导入（`agent.utils.*` → `utils.*` → None）是同一模式**：**win32 能力缺失时动作变 no-op，任务链不中断**——**这是全项目唯一的跨平台降级手段**。

## 二、Movement（109 行）——移动原语

| 文件 | 行 | 内容 |
|---|---|---|
| `character_move.py` | 40 | **角色移动（按键组合）** |
| `mouse_move.py` | 65 | **鼠标移动（相对位移）** |

**两者都注册为 CustomAction**（`agent/custom/action/__init__.py` 25–26 行导入）——**给 pipeline 提供"无法用 Click/Swipe 表达的移动"**。

## 三、AutoFish（877 行）——钓鱼全套（项目最完整的单功能链）

**5 文件**：

| 文件 | 行 | 职责 |
|---|---|---|
| **`auto_fish.py`** | **364** | **主钓鱼逻辑（CV 识别咬钩）** |
| `auto_fish_withoutCV.py` | 120 | **无 CV 版本（纯时序/音频）** |
| `auto_sell_fish.py` | 153 | 卖鱼 |
| `auto_buy_fish_bait.py` | 169 | 买鱼饵 |
| `enter_fishprepare.py` | 71 | **进入钓鱼准备界面** |

**⚠️ 双实现并存（`auto_fish.py` vs `auto_fish_withoutCV.py`）**：CV 版识别浮标/咬钩动画，无 CV 版走固定时序——**两条路径注册为不同动作名**（`AutoFish` / `AutoFishWithoutCV`），**由 pipeline 侧选择**（对应 `Fish.json` 的 option：`task=2, option=9`，**是全项目 option 最多的任务之一**）。

**`screen.update_screen_size` 调用方（Maa-10 己录）**：AutoFish 三文件（auto_fish / auto_buy_fish_bait / auto_sell_fish）——**钓鱼相关坐标随窗口缩放换算**。

## 四、AutoCoffee（536 行）——饮品三连

| 文件 | 行 | 职责 |
|---|---|---|
| `auto_make_tomato_juice.py` | **236** | 番茄汁（最大） |
| `auto_make_coffee_lite.py` | 129 | 咖啡精简版 |
| `auto_make_coffee.py` | 117 | 咖啡完整版 |
| `utils.py` | 54 | 公用（材料选择等） |

**对应三个任务 JSON**：`MakeCoffee.json` / `MakeCoffeeLite.json` / `MakeTomatoJuice.json`（**各 1 task / 1 option**）。

## 五、pinkpaw（6507 行）——粉色爪偷窃任务（全项目最大模块）

**6 文件**：

| 文件 | 关键内容 |
|---|---|
| `pinkpaw_core1/2/3.py` | **三套方案核心逻辑**（对应三个注册动作 Scheme1/2/3） |
| `pinkpaw_common.py` | **公用层（含三重 try 导入 win32）** |
| `pinkpaw_entrance_recovery.py` | **入口恢复（异常回退）** |
| `pinkpaw_reward_logger.py` | **奖励日志记录** |
| `AgentServer` 注册名 | `PinkPawHeistScheme1Action` / `Scheme2` / `Scheme3` / `FindXiaoZhi` / `ReturnToEntrance` / `PinkPawRewardSummary` |

**引用关系（grep 实测）**：

- **`ensure_game_window_resolution(DEFAULT_WIDTH, DEFAULT_HEIGHT)` 在 core1/core2/core3/entrance_recovery 四处调用**——**每次进 pinkpaw 都先强制把窗口拉到标准分辨率**（`path.auto_resize_game_window` 开关控制）
- **core2（352–353 行）/ core3（3757–3758 行）/ entrance_recovery（443–444、468–469 行）**——**core3 达 3700+ 行，是全项目单文件最长者**
- **`PinkPawHeist.json` 有 10 个 option（全项目并列最多）**——**三方案 + 子选项组合爆炸**

## 六、Furniture（162 行）与 BagelSpam（338 行）

**Furniture（家具认领）**：

- `furniture_choose_property.py`（115 行）——**选房产（6 个选项）**
- `furniture_claim.py`（47 行）——**认领**
- **`Furniture.json`：6 个 switch option（每个房产一个 Yes/No 开关）**——**statically 展开的组合，无需 Python 决策**

**BagelSpam（贝果刷屏）**：

- `bagel_spam_llm.py`（255 行）——**LLM 生成文本**（注册 `BagelSpamLLMGenerate`）
- `bagel_spam_text.py`（79 行）——**固定文本**（`BagelSpamPickIndex` / `BagelSpamOutputText`）
- 对应 `BagelSpam.json`（**5 个 option**）

## 七、DatasetCollection（222 行）——自动驾驶数据集录制

**`autonomous_driving_dataset_recorder.py`（222 行）→ 注册 `AutonomousDrivingDatasetRecorder`**

**⚠️ 这是 MaaNTE 与 AuroraDrive 的交叉点**：该动作录制的数据集面向**自动驾驶训练**——对应 `AutonomousDrivingDataset.json`（1 task / 1 option）+ `interface.json` 的 **DatasetCollection group**。

**同组还有**：`tools/demo_coordinate_capture.py`（仓库 tools 下的坐标采集演示）——**与 Navi 抓包链（Maa-11）配套**。

## 八、SyncCharacterAbilityCityAbility（角色/城市能力同步）

- **`SyncCharacterAbilityCityAbility.py`**（顶层单文件）→ 注册 `SyncCharacterAbilityCityAbilityMainAction`
- **`Common/CharacterAbility_CityAbility.py`（370 行）是其核心实现**（**Common 下最大文件**）
- 对应 `SyncCharacterAbilityCityAbility.json`（1 task / 1 option）+ **UserInfo group**
- **同类还有**：`Touch.json`（3 option）/ `FountainCheckin.json`（喷泉签到，0 option）/ `WitchDivination.json`（女巫占卜，0 option）/ `BidKing.json`（竞拍王，1 option）→ **这些多数是纯 pipeline 任务（无需 Python 动作）**

## 九、任务 JSON 体系（29 文件 / 28 task / 78 option）

### 9.1 全量清点（本机实测）

| 任务 | task | option | 主要 option 类型 |
|---|---|---|---|
| **PinkPawHeist** | 1 | **10** | switch（三方案组合） |
| **Fish** | **2** | **9** | switch + input |
| **RealTime** | 1 | 9 | switch（实时辅助开关组） |
| Furniture | 1 | 6 | switch ×6（房产） |
| Rhythm | 1 | 6 | switch + select |
| BagelSpam | 1 | 5 | input + select |
| OnlineMapNavigation | 1 | 4 | input（路线 JSON / 坐标） |
| SoundDodge | 1 | 4 | input（阈值） |
| Tetris | 1 | 4 | switch + input |
| Volleyball | 1 | 4 | select（难度/队友） |
| Touch | 1 | 3 | switch |
| **TestMovement** | **3** | 2 | **开发测试任务（3 个 task 定义）** |
| AutoPiano / ClaimRewards / WithdrawMoney | 1 各 | 2 各 | input（MIDI 路径 / 次数） |
| AutoFScroll / FountainCheckin / WitchDivination / LocalRouteNavigationMemoryTest | 1 各 | **0** | **纯 pipeline 任务** |
| 其余（MakeCoffee 系列 / MakeTomatoJuice / BidKing / Synchronize / AutonomousDrivingDataset） | 1 各 | 1 各 | — |

**option 类型分布（全量统计）**：**input 27 / switch 39 / select 12 = 78**；**其中 72 个 option 带 `pipeline_override`（占 92%）**——**几乎每个 option 都是通过覆写 pipeline 参数生效，而不是走 Python 分支**。

### 9.2 任务 JSON 结构规范（`Furniture.json` 实证）

**task 块（1–25 行）**：

```json
{
  "task": [{
    "name": "Furniture",
    "label": "$task_furniture_label",              // i18n key
    "entry": "FurnitureEntrance",                   // 入口 pipeline 节点
    "description": "$task_furniture_desc",
    "controller": ["Win32-Front"],                  // ← 控制器白名单（本任务必须前台）
    "group": ["Daily", "CityTycoon"],               // ← 可属多个 group
    "option": ["FurnitureChooseWienerApartments", ...]  // 引用的 option 名
  }]
}
```

**⚠️ `controller: ["Win32-Front"]`——任务级控制器约束**：家具任务需要前台独占（`screencap: PrintWindow + mouse/keyboard: Seize`，见 Maa-09 单元四）——**这是唯一在任务 JSON 里锁定控制器的场景**；其余任务用默认 Win32。

**option 块（26 行起，switch 样例）**：

```json
"FurnitureChooseWienerApartments": {
  "type": "switch",
  "label": "$task_furniture_option_wiener",
  "default_case": "Yes",
  "cases": [
    { "name": "Yes", "label": "$option_switch_case_yes",
      "pipeline_override": { "FurnitureChooseWienerApartments": { "enabled": true } } },
    { "name": "No",  "label": "$option_switch_case_no",
      "pipeline_override": { "FurnitureChooseWienerApartments": { "enabled": false } } }
  ]
}
```

**三种 option 类型对照（AGENTS.md 载明 + 本机统计印证）**：

| 类型 | 结构 | 用途 | 实例 |
|---|---|---|---|
| **switch** | `default_case` + `cases[]`（每 case 一个 `pipeline_override`） | 是/否开关（**用 enabled 开关节点**） | Furniture 六房产、RealTime 九开关 |
| **input** | **`verify` 正则 + `pipeline_type`** + `pipeline_override` | **用户输入值（`"{value}"` 模板替换）** | OnlineMapNavigation（路线名）、SoundDodge（阈值） |
| **select** | `items[]` 下拉 | 多选一 | Volleyball（难度/队友）、Rhythm（歌曲） |

**⚠️ `pipeline_override` 的 `"{value}"` 模板替换（AGENTS.md 载明）**：如 `"count": "{count}"`——**用户在 MXU 界面填的数字直接注入 pipeline 参数，无需 Python 解析**。

### 9.3 preset 四件套（`tasks/preset/`）

| preset | 状态 | 用途 |
|---|---|---|
| **AFK.json** | **interface.json 已注册** | 挂机集合 |
| **RealtimeAssistance.json** | **已注册** | **实时辅助集合（配 RealTimeTaskAction 动态调度，Maa-14 单元三）** |
| **FullDaily.json** | **注释停用（interface.json 154 行）** | 完整日常 |
| **QuickDaily.json** | **注释停用（155 行）** | 快速日常 |

**⚠️ FullDaily / QuickDaily 被注释**：**两者是"多任务串联"的高风险 preset**（任一子任务失败会拖垮整链）——**停用是保守选择，代码与 JSON 均保留可随时启用**。

## 十、任务 JSON 与代码的配套修改清单（AGENTS.md 纪律）

**新增/修改一个任务需同步 5 处**：

| # | 文件 | 内容 |
|---|---|---|
| 1 | `assets/resource/tasks/<Task>.json` | task + option 定义 |
| 2 | `assets/resource/base/pipeline/**/*.json` | 对应 pipeline 节点（含 `custom_action` 名） |
| 3 | **`assets/resource/locales/interface/{zh_cn,zh_tw,en_us,ja_jp,ko_kr}.json`** | **5 个语言文件必须同步（label 的 `$key`）** |
| 4 | `assets/interface.json` | **`import` 数组注册**（+ 可选 group） |
| 5 | （若含 Python 动作）`agent/custom/action/<name>.py` + **`agent/custom/action/__init__.py` 的 from-import 与 `__all__`** | 注册生效 |

**⚠️ 5 处漏一处的后果**：
- 漏 3（locale）→ MXU 界面显示 `$task_xxx_label` 原文（**功能正常但界面破相**）
- 漏 4（import）→ **任务在界面上根本不出现**
- 漏 5（__init__）→ **`@AgentServer.custom_action` 装饰器不执行，pipeline 调用时报"未知动作"**（Maa-09 单元五的注册链决定）

## 十一、全项目任务治理观察

| 观察 | 数据 |
|---|---|
| **Python 动作 vs 纯 pipeline** | 48 个注册动作 / 28 个任务——**平均每任务 1.7 个动作**，但**四个零 option 任务（FountainCheckin/WitchDivination/AutoFScroll/LocalRouteNavigationMemoryTest）证明纯 pipeline 也能成任务** |
| **最大模块** | pinkpaw（6507 行，占 agent/ 全部 Python 的约 20%）——**三方案 + 入口恢复 + 奖励日志的完整子系统** |
| **option 复杂度集中在少数任务** | PinkPawHeist(10) + Fish(9) + RealTime(9) = **28 个 option，占全量 36%** |
| **跨模块公用层** | Common/utils.py（90 行）+ Common/logger.py（7 行）被全项目引用；**`get_image` / `click_rect` / `match_template_in_region` 是三大原子操作** |
| **开发测试残留** | `TestMovement.json`（**3 个 task**，是全项目唯一多 task 文件）+ `LocalRouteNavigationMemoryTest.json`（配 `local_route_navigation_unit_test` 动作，Maa-11 单元八）——**保留的单测入口** |

---

**Maa-15 文档至此完整**（生活任务与长尾 9427 行 + 28 task/78 option 全量清点；含 Common 公用层、pinkpaw 6507 行子系统、任务 JSON 三类 option 规范与 5 处配套修改清单）

**Maa 深度文档系列（15 篇）至此完整**：Maa-09 入口核心 / Maa-10 utils 基础 / Maa-11 Navi 导航 / Maa-12 MapTeleport 传送 / Maa-13 小游戏三件套 / Maa-14 实时辅助 / Maa-15 生活任务与任务体系 + 既有 8 篇（功能篇/完整版/扩展篇/架构篇/移植评估/macOS 适配/移植对照表/ROI 规则）
