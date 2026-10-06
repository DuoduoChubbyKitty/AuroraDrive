# 《异环》(Neverness to Everness / NTE) — 玩法系统资料

> 挖掘代理 #3 · 玩法系统
> 挖掘日期：2026-10-07
> 游戏版本基准：Ver 1.4（2026-09 ~ 10）为最新；核心玩法资料主要来自 1.0 公测期（2026-04/05）
> 国服公测 2026-04-23，国际服 2026-04-29

**资料可信度说明**：
- 🟢 **一手资料**：来自 MaaNTE（《异环》自动化工具，工作目录内 `/Users/dupi/Desktop/自动驾驶系统/MaaNTE`）的 pipeline / 本地化文件。这些是**直接对着游戏 UI 写的识别规则**，里面的 OCR `expected` 文本、按钮名、流程描述就是游戏内的真实文本，可信度最高。
- 🟡 **二手攻略**：来自 neverness.gg（DotGG 旗下 NTE 攻略站）、英文维基百科、中文维基百科、官网 yh.wanmei.com。
- ❌ **未找到**：明确标注，不编造。

---

## 目录

1. [核心玩法循环](#1-核心玩法循环)
2. [任务系统](#2-任务系统)
3. [驾驶系统](#3-驾驶系统)
4. [战斗系统](#4-战斗系统)
5. [收集/探索](#5-收集探索)
6. [生活/休闲玩法（都市闲趣）](#6-生活休闲玩法都市闲趣)
7. [其他系统](#7-其他系统)
8. [每日/每周例行](#8-每日每周例行)
9. [附录：游戏内真实 UI 文本（一手）](#9-附录游戏内真实-ui-文本一手)
10. [附录：术语中英对照表](#10-附录术语中英对照表)
11. [来源 URL 清单](#11-来源-url-清单)

---

## 1. 核心玩法循环

### 1.1 一句话概括

玩家扮演**鉴定师 / 异象猎人（Appraiser / Anomaly Hunter）**，在虚构都市**海特洛市（Hethereau）**中：
白天做都市大亨生意（开咖啡馆、赛车、钓鱼、送货、抢银行）赚钱，晚上打异象刷本推主线。

游戏被多家媒体和玩家称为「二次元 GTA」——开放世界 + 载具驾驶 + 都市生活模拟 + 抽卡动作 RPG 的混合体。

> 🟡 来源：[英文维基 Gameplay 章节](https://en.wikipedia.org/wiki/Neverness_to_Everness) — 原文将本作定义为 open world action RPG / hack and slash，玩家可 run, jump, sprint, climb, swim, and drive various vehicles；除冲刺外特殊移动受可恢复体力条限制。
> 🟡 来源：[中文维基](https://zh.wikipedia.org/wiki/異環) — 「游戏融合高自由度探索、战斗及生活模拟玩法，具备表里世界切换机制，同时包含载具驾驶、店铺经营等互动内容」

### 1.2 两条并行的进度线（双等级系统）

| 等级 | 说明 | 来源 |
|---|---|---|
| **猎人等级（Hunter Level）** | 做任何活动都会涨，每次升级给免费奖励。相当于「账号总进度」 | 🟡 [Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/) |
| **鉴定等级（Appraisal Level）** | 猎人等级达到检查点后解锁，**决定能否进入终局内容**，并解锁角色等级上限 | 🟡 同上 |

> 原文："Think of Hunter Level as your daily progress and Appraisal Level as the gate that opens up the real game."

### 1.3 两套体力系统（关键！）

这是 NTE 最重要也最容易搞混的设计：**游戏有两套完全独立的体力**。

| | **角色像素 / Character Pixels** | **都市活力 / City Stamina** |
|---|---|---|
| 用途 | 刷异象区（Anomaly Zone）等战斗内容 | 都市大亨的一切休闲玩法 |
| 恢复 | 每 **6 分钟**回 1 点，24 小时回满 | **每周一 5:00（服务器时间）完全重置** |
| 上限 | **240**（满槽需 24 小时） | 大亨 1 级起 **100**；5 级 **200**；10 级 **350** |
| 补充手段 | — | 可用安努利斯（Annulith）或充值购买（攻略不建议） |

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)、[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/)、[Server Reset Time](https://neverness.gg/nte-server-reset-time/)、[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/)

**重要换算**：都市活力无论花在哪个玩法上，**1 点活力 = 1,000 方斯**。
> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/) — "No matter which hobby you pick, you always earn 1,000 Fons per 1 City Stamina spent"

### 1.4 日常循环（玩家一天做什么）

**典型一天（约 15–20 分钟）**：

1. 花掉角色像素，打能通关的最高难度异象区
2. 完成日常任务（探索指南 → 日常任务页，目标活跃度 100）
3. 去**纳库佩达之池（Nacupeda's Pool）**许愿，选「真诚许愿」拿 Mhm! 硬币（攒够换免费 S 级弧光）
4. 去**魔女之家（The Witch's House）**占卜，拿当日运势（赐福/寻宝/佚闻三选一结果）
5. 领取**一咖舍（Cafe by Origen）**的营业收益并补货
6. 用**吱（Chiz）**的长按普攻刷方斯，刷到每日上限（40,000 方斯/日，总上限 250,000）
7. 送 10 份礼物给角色（每日上限 10 份，单角色最多 3 份）

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)（完整清单，含每步细节）
> 🟡 补充：[How to Get Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/) — Chiz 长按普攻吸金，"There's a daily cap of 40,000 Fons and a total limit of 250,000 Fons"

### 1.5 核心循环的「第二层」——都市大亨

**都市大亨（City Tycoon）**是嵌在主游戏里的「游戏中的游戏」。攻略站原话：

> "City Tycoon is one of the biggest parts of Neverness to Everness. It's basically a whole game inside a game. You'll be doing things like running a cafe, racing cars, fishing, and even pulling off heists."

**解锁条件**：推主线 → 打完「取景器（Viewfinder）」BOSS → 主线被等级门槛卡住 → 出现任务 **「早安，海特洛」（Good Morning, Hethereau）** → 遇到 **吱（Chiz）** → 买卡解锁都市大亨菜单。

> 🟡 来源：[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/)

**都市大亨升级靠两样东西**：方斯 + 完成指定任务。任务示例（攻略站列举）：
- 买第一辆车（50,000 方斯）
- 花费一些都市活力
- 开咖啡馆
- 买公寓（200,000 方斯）
- 邀请角色（通常是薄荷 Mint）入住公寓
- 激活异象家具
- 提升公寓舒适度与店铺管理等级

**都市大亨长期目标（拿免费 S 级角色 Chiz 及突破）**：
| 等级 | 奖励 |
|---|---|
| 18 级 | 获得 Chiz |
| 21 级 | 获得她的武器 |
| 45 级 | 解锁她的全部突破（dupes） |

> 🟡 来源：[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/)

---

## 2. 任务系统

### 2.1 任务类型总览

| 类型 | 说明 | 来源 |
|---|---|---|
| **主线任务（Main Story）** | 章节式推进，解锁系统与地图。部分主线单次奖励超过 **80,000 方斯** | 🟡 [Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/) |
| **支线任务（Side Quests）** | 一次性内容，做完会耗尽直到新版本 | 🟡 [Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/) |
| **异象委托（Anomaly Commissions）** | 追踪超自然实体的特殊任务，见 §5.1 | 🟡 [Anomalies](https://neverness.gg/nte-anomalies/) |
| **日常任务（Daily Quests）** | 每天 5:00 (UTC+8) 重置，见 §8 | 🟡 [Dailies](https://neverness.gg/nte-dailies-guide/) |
| **周常（Weekly）** | 异象巡礼、都市活力、惠比寿拍卖行、贪婪领域、特别都市委托 | 🟡 同上 |
| **双周常（Bi-Weekly）** | 粉爪大劫案（Pink Paws Heist） | 🟡 同上 |
| **月常 / 版本末** | Beyond the Rails（终局挑战）、商场 Lost Exchange 兑换 | 🟡 同上 |
| **贝果（Bagel）** | 游戏内社交平台发帖（见 §6.8） | 🟢 MaaNTE |

### 2.2 任务怎么接、怎么追踪

**主线/支线**：正常对话推进。部分主线会因等级门槛卡住（例如打完「取景器」后需达标才继续）。

**日常任务入口（关键 UI 信息）**：
- 入口叫 **探索指南（Exploration Guide）**
- 屏幕**顶部有一个带表盘的图标**，点开即是探索指南菜单
- 左侧栏**第二个标签页**是「日常任务」（Daily Tasks）
- 日常任务列表**右下角显示「Refresh Time」倒计时**，即距离每日重置的剩余时间
- 日常任务需要**通关主线「序章 - 第 2 部分」**后才会出现
- 日常奖励包含：安努利斯、猎人等级经验、方斯等
- 活跃度到 **100** 即可解锁全部日常奖励

> 🟡 来源：[Server Reset Time](https://neverness.gg/nte-server-reset-time/) — "The Exploration Guide always displays a timer on the lower right-hand side of the daily tasks list... On the left bar, select the second tab and this will bring you to your Daily Tasks. On the lower right-hand side you will notice a 'Refresh Time'"
> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/) — "check your Daily Quests through the Exploration Guide menu... gets you to Activity Level 100, which unlocks all the daily premium rewards"；"Daily Quests only show up after you clear Prologue - Part 2"

**战斗通行证（环期赏令 / Battle Pass）任务**：
- 三种任务：**每日（Daily）、每周（Weekly）、赛季（Seasonal）**
- 查看方式：点击探索指南图标**右边**的图标 → 第二个像纸片的标签页 = **任务标签页（Quest Tab）**
- 这里可以追踪每日和每周的通行证任务

> 🟡 来源：[Server Reset Time](https://neverness.gg/nte-server-reset-time/)

### 2.3 任务面板长什么样（一手 UI 证据）

来自 MaaNTE 的场景管理器（直接对游戏 UI 编程），确认了以下界面真实存在且名称准确：

| 界面 | 内部标识 | 识别方式 |
|---|---|---|
| 探索指南菜单 | `InExplorationGuideMenu` / `SceneAnyEnterExplorationGuideMenu` | 模板匹配 |
| 环期赏令菜单（第一页） | `InBattlePassMenu` / `SceneAnyEnterBattlePassMenu` | 模板匹配 |
| 都市大亨界面 | `InCityTycoonMenu` | **OCR 识别 "都市大亨"** |
| 都市闲趣界面 | `SceneAnyEnterHethereauHobbiesMenu` | — |
| 背包 / 角色 / 活动菜单 | `InBagMenu` / `InCharactersMenu` / `SceneAnyEnterEventsMenu` | — |
| 大世界 | `InWorld` | — |
| 特殊小世界（粉爪、主线故事、**异象委托**等） | 描述原文："在特殊的小世界中(如粉爪、主线故事、异象委托等)" | — |

> 🟢 一手来源：`MaaNTE/docs/zh_cn/develop/scene-manager.md`、`MaaNTE/assets/resource/base/pipeline/Interface/Scene/Status.json`
> 原文表格：「`InCityTycoonMenu` | 在都市大亨菜单内 | OCR 识别 "都市大亨"」

**探索指南第二页 = 活跃度奖励页**（一手确认）：
MaaNTE 的自动领奖流程会「切换到探索指南第二页」→「领取活跃度点数」→「领取活跃度奖励」。
OCR 匹配的按钮文本：`领取 / 領取 / Claim / 受け取る / 수령`。

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/ClaimRewards.json`
> 原文节点描述：「领取活跃度奖励主流程」「切换到探索指南第二页」「领取活跃度点数」「领取活跃度奖励（活跃度奖励部分结束）」

**环期赏令第二页 = 经验/修行奖励页**（一手确认）：
流程为「切换到环期赏令第二页」→「领取环期赏令经验」（OCR 匹配「全部领取」）→「领取历练奖赏」。

> 🟢 一手来源：同上

**⚠️ 未找到**：任务面板的**具体视觉布局细节**（例如任务条目是否显示距离、奖励预览图标排列、追踪条位置）。攻略站与一手 pipeline 都未覆盖到这一层粒度。建议实机截图确认。

### 2.4 任务相关特殊机制

- **魔女之家占卜「佚闻（Lost Tales）」**：直接揭示一个**隐藏任务**及其奖励
  > 🟡 [Dailies Guide](https://neverness.gg/nte-dailies-guide/) — "Lost Tales — reveals a hidden quest with a reward"
- **异象委托随玩家等级缩放**，不必按固定顺序做
  > 🟡 [Anomalies](https://neverness.gg/nte-anomalies/) — "Anomalies also scale to your level, so you don't have to stress about doing them in a specific order"
- **剧情可跳过**：游戏有「跳过剧情」按钮、跳过确认弹窗（含「今日不再提示」勾选框）、剧情概述对话框、重要剧情提示对话框
  > 🟢 一手来源：`MaaNTE/assets/resource/locales/interface/zh_cn.json` — 选项 `task_realtime_option_auto_skip_story`（自动剧情）、`task_realtime_option_skip_story_dialog`（自动勾选"今日不再提示"）、`task.RealTime.option.RealTimeAutoSkipStorySummary`（自动跳过剧情概述）、`task.RealTime.option.RealTimeAutoSkipImportantStory`（自动跳过重要剧情提示）

---

## 3. 驾驶系统

### 3.1 有车吗？—— 有，而且是核心系统

**载具是 NTE 的主要交通方式**，速度远快于步行，并且带**自定义改装**。

> 🟡 [Vehicles List](https://neverness.gg/nte-vehicles-list/) — "Vehicles serve as the primary transportation method in Neverness to Everness, letting you go around the map rather faster than just walking around. Beyond simple transportation, vehicles add customization options as well."
> 🟡 [英文维基](https://en.wikipedia.org/wiki/Neverness_to_Everness) — "The game features vehicle customization and upgrading business."

### 3.2 怎么解锁开车

1. **序章 II（Prologue II）完成** → 免费获得第一辆车 **Rover A1**（最高速 40，加速 2，教学用车）
2. 推进主线至 **Photo Studio Episode（照相馆篇章）** 完成
3. 在任务「早安，海特洛」中与 **吱（Chiz）** 互动 → 解锁**都市大亨**
4. **都市大亨达到 2 级** → 解锁**车库（Garage）**
5. 在**海特洛市的三家经销商**购车

> 🟡 来源：[Vehicles List](https://neverness.gg/nte-vehicles-list/) — "Unlocking the vehicle purchase system requires reaching City Tycoon Level 2 to access the Garage. City Tycoon becomes available after completing the Photo Studio Episode in the main story and interacting with Chiz during the Good Morning, Hethereau guide quest."

**三家经销商**：
| 经销商 | 位置 |
|---|---|
| Novus Dealership | Bridge Crossings |
| TerraX Dealership | Miguel District |
| Regalia Dealership | New Harland |

> 🟡 来源：同上

### 3.3 全部载具列表（含价格与性能）

| 载具 | 最高速 | 加速 | 价格 | 购买地点 |
|---|---|---|---|---|
| Rover A1 | 40 | 2 | 免费 | 完成序章 II |
| C2000 | 130 | 3 | 50,000 方斯 | Novus（Bridge Crossings） |
| G3 | 138 | 4 | 200,000 方斯 | TerraX（Miguel District） |
| Novis ST-X 950 | 140 | 6 | 250,000 方斯 | Regalia（New Harland） |
| M1000 | 146 | 5 | 350,000 方斯 | Novus（Bridge Crossings） |
| ST79 | 155 | 5 | 600,000 方斯 | Novus（Bridge Crossings） |
| Griffin | 170 | 6 | 1,500,000 方斯 | Regalia（New Harland） |
| Enforcer | 172 | 6 | 1,720,000 方斯 | Novus（Bridge Crossings） |
| Griffin Volante | 170 | 6 | 1,800,000 方斯 | Regalia（New Harland） |
| Blizzard-V4 | 180 | 7 | 2,450,000 方斯 | Regalia（New Harland） |
| Pursuit V8 | 180 | 7 | 4,000,000 方斯 | Regalia（New Harland） |
| K01 | 80 | 8 | $25.99 USD 或 6,800,000 方斯 | 礼品中心/商场（Supersonic Pack） |
| LaVelox | 191 | 8 | 10,800,000 方斯 | Regalia（New Harland） |
| Pendragon | 202 | 9 | 12,000,000 方斯 | Regalia（New Harland） |
| B100 | 132 | 4 | 20,000 爪爪币 | Pink Paws Den（粉爪银行） |
| Tomorrow Rush | 50 | 2 | 30,000 爪爪币 | Pink Paws Den（粉爪银行） |

> 🟡 来源：[Vehicles List](https://neverness.gg/nte-vehicles-list/)（完整表格逐条摘录）

**载具强度榜**：
| 梯队 | 载具 |
|---|---|
| S | LaVelox, Pendragon, Griffin |
| A | Blizzard-V4, K01, ST79, Griffin Volante, Novis ST-X 950 |
| B | Enforcer, Pursuit V8 |
| C | C2000, B100, G3, M1000 |
| D | Rover A1 |
| 待定 | Tomorrow Rush |

攻略评价要点：
- **LaVelox** = 综合最强（手感最好、最均衡，漂移可控，191 极速）
- **Pendragon** = 直线最快（202 极速，加速 9），但操控不如 LaVelox，且贵 120 万
- **Griffin** = 性价比之王（150 万，加速好、手感顺）
- **K01** = 有**氮气加速机制（Nitro）**，但基础极速只有 80
- **Enforcer / Pursuit V8** 被批「转向和操控极差，性价比糟糕」
- **Rover A1** 建议"立即换掉"

> 🟡 来源：[Cars Tier List](https://neverness.gg/nte-vehicles-tier-list/)

### 3.4 驾驶相关玩法

**① 赛车（Races）—— 都市大亨核心玩法**
- 都市大亨 **2 级**解锁
- **共 6 个关卡**，有不同的障碍和难度
- **消耗都市活力**
- 攻略建议：**优先刷赛车**，因为"随着通关会解锁永久奖励（permanent rewards）"

> 🟡 来源：[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/) — "Races — 6 stages with different obstacles and difficulty"；"The best order to spend your stamina: Races first — they unlock permanent rewards as you clear stages"

**② 都市送货（City Delivery）**
- 属于「海特洛闲趣（Hethereau Hobbies）」之一
- 每次送货给 **约 10,000–16,000 方斯**
- 比异象委托更快更稳定，但**不掉额外材料**
- 攻略建议：**优先刷送货直到把「旧邮箱（Old Mailbox）」家具升满**，再转钓鱼

> 🟡 来源：[Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/)、[Dailies Guide](https://neverness.gg/nte-dailies-guide/)

**③ 载客（Picking up passengers）**
- 与送货、钓鱼同属「海特洛闲趣」的杂活

> 🟡 来源：[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/) — "Hethereau Hobbies — odd jobs like deliveries, fishing, and picking up passengers"

**④ 快速传送 / 出租车（Swift Travel / taxi）**
- 消耗都市活力，同属都市大亨玩法

> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/) — "City Stamina is used for: Deliveries, Fishing, Races, Barista mini-game, Swift Travel (taxi)"

**⑤ 联机赛车**
- 多人模式支持赛车

> 🟡 来源：[Co-op Guide](https://neverness.gg/nte-co-op-multiplayer/) — "Multiplayer offers these activities: Combat challenges, Racing, Exploration, Mini Games, Home visits"

**⑥ 交通违法 / 通缉（前瞻信息）**
- 二测前瞻提到「城市飙车乱撞会被通缉」
> 🟡 来源：[游民星空 2025-06-21 报道](https://wap.gamersky.com/news/Content-1948114.html)（中文维基引用）— 标题「真变"二次元GTA"了!《异环》二测前瞻超多优化 城市飙车乱撞会被通缉」
- ⚠️ 这是**二测（2025-06）**的信息，公测是否保留 **未找到** 确认资料。

### 3.5 自动驾驶 / 地图导航（一手技术资料）

MaaNTE 有专门的 **自动驾驶数据集收集**任务和**在线地图实时定位&寻路**系统，间接证明了游戏内的导航机制：

- 游戏**小地图可设置目的地**
- 有**网络定位**（读取游戏原始世界坐标 x/y/z）与**视觉定位**两种方式
- 世界坐标是**大整数尺度**（示例：x=-134394.56, y=199913.53, z=11416.17），大地图源图尺寸 11264×11264
- 传送点包括 **维特海默塔（Wertheimer Tower）** 与 **ReroRero 电话亭（ReroRero Phone Booth）**

> 🟢 一手来源：`MaaNTE/assets/resource/locales/interface/zh_cn.json`（`task_auto_drive_dataset_recorder_desc`："开始此任务前确保小地图已设置好目的地，默认录制时长为 60 秒，每秒采样 2 次。"）、`MaaNTE/docs/zh_cn/introduction/NaviWebSocket.md`

**Porsche 联动**（版本 1.4 期）：
- 联动二期上线全新载具「Porsche 911 Turbo (930)」「Porsche Taycan Turbo GT with Weissach Package」
> 🟡 来源：[《异环》官网 yh.wanmei.com](https://yh.wanmei.com/)（首页当前版本公告文本）

---

## 4. 战斗系统

### 4.1 基础战斗机制

- **3D 第三人称动作 RPG**，砍杀（hack and slash）风格
- **4 人队伍**，战斗中可自由切换角色
- 可执行：**闪避（dodge）**、**完美闪避（perfect dodge）**、**弹反（parry）**
- 每个角色有 4 种招式：**普通攻击（Basic Attack）、长按攻击（Hold Attack）、技能（Skill）、大招（Ultimate）**

> 🟡 来源：[英文维基 Gameplay](https://en.wikipedia.org/wiki/Neverness_to_Everness) — "Players are able to switch between characters in a team of 4, and can perform common hack and slash gameplay mechanics like basic dodges, perfect dodges, and parries."
> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/) — "Every character in Neverness to Everness has four move types: Basic Attack, Hold Attack, Skill, Ultimate"

### 4.2 异能（Esper）元素系统 —— 六元素轮盘

**六个异能属性（Esper types）**：

| 元素 | 颜色 / 概念 |
|---|---|
| **Lakshana**（罗刹那 / 金） | Gold / Order |
| **Cosmos**（宇宙 / 银） | Silver / Light |
| **Anima**（灵 / 绿） | Green / Life |
| **Incantation**（咒 / 红） | Red / Force |
| **Chaos**（混沌 / 紫） | Purple / Dark |
| **Psyche**（心 / 蓝） | Azure / Mind |

> 🟡 来源：[Esper Cycle Explained](https://neverness.gg/nte-element-guide-esper-cycle-explained/)、[英文维基](https://en.wikipedia.org/wiki/Neverness_to_Everness)

**核心规则：只有轮盘上相邻的元素才能发生反应。**

**异能槽（Esper Meter）机制**：
- 每个角色头像旁有一个小圆槽
- 充满后头像发光 → 这是切换该角色触发异能反应的信号
- 充能速度：**普攻慢 / 技能与大招中等 / 闪避反击快 / 弹反瞬间充满**
- 每个角色有 **Cycle Rate（循环率）** 属性，加快充能

> 🟡 来源：[Esper Cycle Explained](https://neverness.gg/nte-element-guide-esper-cycle-explained/)

**基础战斗循环**：
1. 充满某角色的异能槽
2. 等头像发光
3. 切换该角色触发反应
4. 充满下一个角色，重复

> 原文："The key is keeping reactions going. One reaction is fine. A chain of reactions? That's where the real damage happens."

### 4.3 双元素反应（Duo Reactions）— 六种

| 反应名 | 元素组合 | 效果 |
|---|---|---|
| **Blossom**（绽放） | Cosmos + Anima | 放出一个自动攻击的 AOE 炮台，不占场时间 |
| **Hexed**（咒缚） | Anima + Incantation | 基于敌人过去 **12 秒**内受到的所有伤害计算额外伤害，适合大 combo 后 |
| **Scorch**（灼烧） | Incantation + Chaos | 施加持续 **15 秒**的 DoT |
| **Nova**（新星） | Chaos + Psyche | 附着在敌人身上，**5 秒后**引爆造成大爆发 |
| **Stain**（污染） | Psyche + Lakshana | 使敌人受到的 Psyche 和 Lakshana 伤害**提高 50%**，持续 **12 秒** |
| **Remora**（阻滞） | Lakshana + Cosmos | 降低敌人移动速度与攻击速度 |

> 🟡 来源：[Esper Cycle Explained](https://neverness.gg/nte-element-guide-esper-cycle-explained/)、[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/)（两处数据一致）

### 4.4 三元素反应（Trio Reactions）— 两种

触发条件：**同一组三元素中触发两个反应**。

| 反应名 | 元素组合 | 效果 |
|---|---|---|
| **Charge**（充能） | Lakshana + Cosmos + Anima（上三组） | Blossom 炮台每次命中被 Remora 标记的敌人时产生大招能量，适合频繁开大 |
| **Discord**（不谐） | Incantation + Chaos + Psyche（下三组） | 同时受 Nova 和 Scorch 影响的敌人受到**巨额削韧/失衡伤害**，是破 BOSS 韧条的首选 |

> 🟡 来源：[Esper Cycle Explained](https://neverness.gg/nte-element-guide-esper-cycle-explained/)

### 4.5 队伍编成（Team Compositions）

**万金油角色（Flex Picks）**：Adler、Edgar、Fadia
- **Adler**（Incantation, A 级）：全队护盾 + Incantation DoT，两者都吃 DEF 加成，零门槛
- **Edgar**（Cosmos, A 级）：专职奶妈，"如果高难内容老是死，带上 Edgar"
- **Fadia**（Psyche, S 级）：转移队友伤害，快速充能异能循环

**推荐阵容**：

| 阵容名 | 成员 | 核心思路 |
|---|---|---|
| **最佳 F2P 起手队** | Zero（DPS）+ Edgar + Haniel | 稳定、好懂、能带进高难 |
| **Discord 队** | 白藏 Baicang（DPS）+ 达芙蒂尔 Daffodill + Sakiri + Haniel | 达芙蒂尔一人同时挂 Scorch 和 Nova → 直接触发 Discord，韧条持续自掉。白藏伤害极高但**放技能耗自己血**，大招有斩杀阈值要留着收尾 |
| **Discord 队 2** | Adler（DPS）+ Daffodill + Fadia + Nanally | 同时跑三个反应：Adler(Incantation)+Daffodill(Chaos)=Scorch；Daffodill(Chaos)+Fadia(Psyche)=Nova；两者同时在 → Discord。Nanally 的 Underboss 追击**离场也持续输出**，同时 Anima+Incantation 后台刷 Hexed |
| **Blossom 队** | Hotori（DPS）+ Jiuyuan + Zero + Nanally | 围绕 Blossom 爆发。**开大招前确保其他队员都用过技能**以最大化技能复读伤害。Zero 的技能可**瞬间触发**异能反应，让 Blossom 连切更顺 |
| **新手友好队** | — | 攻略站有章节但正文未在本次抓取中获取完整 |

> 🟡 来源：[Best Team Compositions](https://neverness.gg/nte-best-team-compositions/)

**编队核心原则（原文）**：
> "The key is having an elemental lane: two or more characters whose elements chain together to trigger reactions consistently. Teams with a clean lane feel much smoother than random lineups."

### 4.6 装备系统

**弧光（Arcs）= 武器**
- 提供固定**基础攻击力（Base ATK）** + 一个随等级成长的副属性
- 每个弧光有独特战斗效果（被动）
- 两种强化：**Enhancing（用专属材料升级，最高 80 级）**、**Mixing（用同名副本提升被动，最高 Mixing Tier 5）**
- 获取：主要来自抽卡。B/A 级来自角色与弧光卡池；**S 级主要来自用 Tri-Key 的限定弧光池**
- **重要**：每个标准 S 级弧光都可以通过**异象委托**免费获得一次 → 不花 Tri-Key 也能凑齐全队武器

> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/)、[Anomalies](https://neverness.gg/nte-anomalies/)

**卡带（Cartridges）= 圣遗物**
- 1 个主词条 + 4 个副词条，**获取时全部可见**
- 主副词条**可以同属性**，方便堆叠
- 分 B/A/S 三档
- 升级只提升主词条；**每 5 级（+5/+10/+15/+20）解锁一个副词条**，最高 +20
- 主要靠消耗**角色像素**在副本刷取

**模块（Modules）= 次级装备（装入 Console）**
- 2 个固定主词条（固定攻击力 + 固定生命值）+ 4 个随机副词条
- 每 5 级解锁副词条，最高 +20
- 分 B/A/S 稀有度，以及 **Type II / III / IV**（越高占 Console 空间越多但属性越好）
- 主要来自 **Rewind 系统**（Console 菜单内的模块抽卡），消耗**胡萝卜币（Carrota Coins）铜/银/金**
- 刷币方式：在 **New Herland District 兔子洞（Rabbit Hole）传送点附近**清副本，再找附近 NPC 领奖循环

> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/)

### 4.7 角色养成

**觉醒（Awakenings）**：抽到重复角色 → 转化为觉醒点 → 激活额外效果。**可以随时开关**。

**异能能力（Esper Abilities）**：强化角色攻击，并解锁帮助都市大亨赚钱的**生活技能（Life Skills）**。还有支援技能（Support Skills）。升级与**突破等级（Ascension Level）**绑定。

> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/)

### 4.8 异能在大世界的作用（重要！）

异能不只用于战斗，还影响**探索与解谜**：

| 元素 | 大世界能力示例 |
|---|---|
| **Anima** | 娜娜莉（Nanally）可以**爬墙** |
| **Anima** | 薄荷（Mint）可以**空中冲刺**到高处 |
| **Lakshana** | Skia 可以**变成水洼**滑上墙，比正常攀爬快 |
| **Chaos** | 残虹（Lacrimosa）可以**复制敌人能力**并在大世界使用 |

**异象互动**：城市中的异象（扭曲区域）需要特定异能类型才能互动：
- **Cosmos** 可以**稳定**异象
- **Psyche** 处理**精神类谜题**
- **Incantation** 处理**力量类**谜题

> 🟡 来源：[Esper Cycle Explained](https://neverness.gg/nte-element-guide-esper-cycle-explained/)

### 4.9 战斗相关一手补充（MaaNTE）

- 有**音频闪避**机制：MaaNTE 可以「基于音频识别的自动闪避与反击」，说明游戏有明确的**闪避音效**与**反击音效**提示
- 自动战斗实现方式：**检测怪物血条（颜色匹配）**，循环「Space + 鼠标点击」攻击
- 铁门需要「强制开启」（OCR 识别「强制开启」「奋力撬锁中」）—— **有撬锁机制**

> 🟢 一手来源：`MaaNTE/docs/zh_cn/introduction/SoundDodge.md`、`MaaNTE/docs/zh_cn/introduction/PinkPawHeist.md`、`MaaNTE/assets/resource/base/pipeline/PinkPawHeist/`

---

## 5. 收集/探索

### 5.1 异象委托（Anomaly Commissions）—— 核心收集玩法

**定义**：作为与调查局合作的认证异象猎人，寻找并处理散布在海特洛市的超自然实体。有些是探索时偶然撞见的，有些藏得很深需要专门去找。任务形式多样：**解谜**或**打 BOSS**。

**怎么找**：从**世界地图（World Map）**打开 **异象图谱（Anomagram）**——这是所有异象委托的列表，给出每个异象的大致位置。

**奖励（每次委托一次性）**：

| 奖励类型 | 数量范围 |
|---|---|
| 猎人经验 | 120 – 450 |
| 安努利斯 | 10 – 60 |
| 方斯 | 6,000 – 20,000 |
| 胡萝卜（铜/银） | 30 – 160 |
| U-00NE | 10 – 40 |
| 甲虫币（Beetle Coin） | 3,000 – 10,000 |
| 异象材料自选箱 I | 2 – 6 |
| **弧光（武器）掉落** | 各种 S 级弧光 |

**关键结论**：
> "Every standard S-rank Arc in the game can be obtained once through Anomaly Commissions, which means you can fully gear up your team without spending a single Tri-Key on weapon pulls."

**分布区域**：Bridge Crossings、Unheard Shores、Illusion Town、Miguel District、New Herland District

**已收录委托举例**（含掉落弧光）：

| 委托名 | 异象 | 掉落弧光 | 奖励亮点 |
|---|---|---|---|
| After School | Doomscroll | Oraora! | 猎人经验 200 / 安努利斯 30 / 方斯 10,000 |
| Backstreet Boxer | Ora Puncher | Oraora! | 猎人经验 160 / 方斯 8,000 |
| C's Tower | Proliferative C | — | 银胡萝卜 40 |
| Dragon Gate Substitute | Tidal Ascension | A Time Will Come | — |
| Lightspeed Tagger | Bopp Pop | Cosmos Daze, Wild Reverie | 含 Tomorrow Paint 1x |
| Ride Assault | Headless Rider | Raging Flames | **Headless Rider's Competitive Spirit** + 猎人经验 300 / 方斯 15,000 |
| Rhythm Master | Beat King | Blow up the Crowd | 猎人经验 300 / 方斯 15,000 |
| Prepare for Rain | Rainman | Umbrella | 含 Scale Pattern 1x |
| Lonely Player | Wandering Puppets | — | **猎人经验 450 / 安努利斯 60 / 方斯 20,000**（最高档） |
| Nightmare-Bound | Nameless Hospital | — | 含 Staff Elevator Card 1x，**有 4 个不同结局** |
| Where Is Home | Crimson Hexblade | — | 含 Compassion from Foreign Lands、Blade Forging Stone |
| Brand Anniversary | Film | MANISH | — |
| Invasion! Octopus Trailer! | Octowpus | — | — |
| Video Cemetery | Spacetime Projector | Failing You, Heavy in My Heart | — |
| C's Cube | Proliferative C | — | — |

> 🟡 来源：[All Anomalies](https://neverness.gg/nte-anomalies/)（含完整分区表格）

**BOSS 分类**：世界 BOSS（World Bosses）、周常 BOSS（Weekly Bosses）、剧情 BOSS（Story Bosses）

### 5.2 秘密金库（Secret Vaults）—— 9 个隐藏宝箱

**全图共 9 个，合计约 475,000 方斯**，无需消耗体力。

| 位置 | 怎么去 | 收益 |
|---|---|---|
| Pink Paws Bank HQ | New Herland District，进银行，走**东侧楼梯上 2 楼** | **200,000 方斯** |
| Midas Arc Workshop | 传送到 Crocodile Clock Avenue 东边的 ReroRero 电话亭，走**西侧楼梯**上去 | **100,000 方斯** |
| Soleil Road Site（3 楼） | Soleil Road 西北的电话亭，坐电梯上去，**小心敌人** | 1,250 + 2,500 方斯 |
| Soleil Road Site（夹层） | 从电梯侧面跳进 3 楼与 2 楼之间的缝隙，**需要撬锁** | 1,250 方斯 |
| Soleil Road Site（2 楼） | 从夹层跳下，大保险箱但**被敌人包围** | **50,000 方斯** |
| Miguel District 火车站 | 从 Miguel District 维特海默塔往北，找车站后面的仓库 | 50,000 + 1,250 方斯 |
| Houdini's Schemes | 异象区最西边，两个箱子露天摆着 | 50,000 + 1,250 方斯 |
| Nightmare-Bound 委托 | 无名医院内，**有 4 个不同结局，收益不定** | 可变 |

> 🟡 来源：[How to Get Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/)

### 5.3 神谕石（Oracle Stones）与神谕等级（Oracle）

- **神谕石**：游玩过程中被动收集
- 交给魔女之家的 **黑羽（Blackbird）** 提交
- **每偶数等级（2、4、6……）** 奖励 **30,000 方斯**
- 魔女之家占卜的「**寻宝（Treasure Hunt）**」结果会在**地图上标出神谕石的精确位置**

> 🟡 来源：[How to Get Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/)、[Dailies Guide](https://neverness.gg/nte-dailies-guide/)

### 5.4 异象家具（Anomaly Furniture）

- **击败城市中的异象**掉落
- 放进公寓后**不只是装饰**——每件都提供**被动加成**
- 装饰会提升**房屋舒适度（House Comfort）**，进而升级其他家居功能

> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/) — "These are items you get from beating anomalies around the city. They're not just decorative either. Each one gives you a passive bonus."

**已知异象家具举例**（一手确认）：**仓鼠球（Hamster Ball）**、**棉棉（Fluff）**、**破损的木箱（Damaged Crate）**、**盲眼财神（Blind Mammon）**、**旧邮箱（Old Mailbox）**

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/Furniture/FurnitureStatus.json`（OCR expected: "仓鼠球"/"倉鼠球"/"(?i)Hamster\s*Ball"/"ハムスターボール"；"棉棉"/"(?i)Fluff"/"モフンモフン"；"破损的木箱"）
> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)（Blind Mammon、Old Mailbox）

### 5.5 图鉴 / 成就

**物品图鉴**：neverness.gg 有完整的物品数据库，分类包括：
- **食物（Food）**：治疗食物、增益食物、烹饪材料
- **家具与装饰（Furniture and Decor）**：画作、花束与花瓶、照明、沙发座椅、桌子、收纳与架子、咖啡馆专属家具、其他

食物分类详情：
- **治疗食物**：立即回血或持续回血（例：肉包子回 20% 最大生命；Kids Energy Meal 回 30%；Puka Chocoa Ellie Tour Special 回 **56%**）
- **增益食物**：提升攻击/防御/暴击率/暴击伤害/体力恢复
- **注意**：多数增益食物**只在联机模式下影响自己的角色**

食物购买地点：Bigmouth Baozi、Family Restaurant、Marigny Pizza、Felicità Gelato、Ramen Shop、Tofu shops、Bob's Vending Machine、Alice's Bakery、Pharmacy、Puka Vending Machine、Candy Shop 等

> 🟡 来源：[All Items](https://neverness.gg/items/)

**⚠️ 未找到**：独立的「成就系统（Achievements）」资料。攻略站与 wiki 均未提及明确的成就系统。
**⚠️ 未找到**：明确的「宝箱收集进度」百分比系统（只有上文 9 个秘密金库的列表）。

### 5.6 地图区域

**已确认区域**：Bridge Crossings（桥十字）、Unheard Shores（无声海岸）、Illusion Town（幻影镇）、Miguel District（米格尔区）、New Herland District（新荷兰区）、Caltrop Lake（水菱湖）、Azure Vista（湛望角）、Imaginist（理想馆）、Stellar Marina（星渚游艇码头）、Nautili Tunnel East/West（鹦鹉螺隧道东/西）、Raindrop Court（落雨庭）、Cape Square（海角广场）、Puka Land（噗卡乐园，1.4 新区域）

> 🟡 来源：[Anomalies](https://neverness.gg/nte-anomalies/)、[Fishing Guide](https://neverness.gg/nte-fishing-guide/)、[官网](https://yh.wanmei.com/)
> 🟢 一手佐证：`MaaNTE` 钓鱼点选项含「理想馆钓点」「水菱湖钓点」「鹦鹉螺隧道东钓点」「落雨庭钓点」「鹦鹉螺隧道西钓点」「星渚游艇码头钓点」「海角广场钓点」「湛望角钓点」「向阳岛」

**传送点**：维特海默塔（Wertheimer Tower）、ReroRero 电话亭（ReroRero Phone Booth）

---

## 6. 生活/休闲玩法（都市闲趣）

> **都市闲趣 = Hethereau Hobbies**，是都市大亨下的休闲玩法集合，全部消耗**都市活力**。
> 进入方式：都市大亨菜单 → 都市闲趣（Hethereau Hobbies）
> 🟢 一手来源：`MaaNTE` 任务分组 `group.HethereauHobbies.label = "都市闲趣"`、`group.CityTycoon.label = "都市大亨"`；pipeline 有节点「都市大亨界面点击都市闲趣」

### 6.0 都市大亨玩法总览

| 玩法 | 说明 | 解锁条件 |
|---|---|---|
| **一咖舍（The Cafe by Origen）** | 被动收入机器 | 都市大亨 4 级 |
| **都市闲趣（Hethereau Hobbies）** | 送货、钓鱼、载客等杂活 | — |
| **赛车（Races）** | 6 个关卡 | 都市大亨 2 级 |
| **车库（Garage）** | 买车与改装 | 都市大亨 2 级 |
| **猎人交易所（Hunter Exchange）** | 用方斯换升级材料与抽卡券 | 都市大亨 6 级 |
| **财富榜（Wealth Board）** | 方斯收入前 100 名排行榜 | — |
| **粉爪大劫案（Pink Paws Heist）** | 抢银行，零活力消耗 | 都市大亨 10 级 + 房屋收藏 3 级 |
| **超强音（Super Sound）** | 音游 | — |
| **泯除方块（Tetris）** | 俄罗斯方块类 | — |
| **噗卡乐园（Puka Land）** | 游乐园小游戏 | — |
| **拍卖之王（Bid King）** | 拍卖小游戏 | — |
| **自动弹琴（Piano）** | 弹钢琴 | — |
| **做咖啡（Coffee）** | 咖啡制作小游戏 | — |
| **喷泉打卡（Fountain）** | 每日许愿 | — |
| **魔女占卜（Witch Divination）** | 每日占卜 | — |
| **抚摸（Pet/Touch）** | 抚摸宠物/角色 | — |

> 🟡 来源：[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/)（前 6 项）
> 🟢 一手来源：`MaaNTE/assets/resource/tasks/` 全部任务文件 + `locales/interface/zh_cn.json`

---

### 6.1 钓鱼（Fishing / Sea Angler）

**解锁**：都市大亨 **3 级**（解锁顺序：2 级赛车 → 3 级钓鱼 → 4 级咖啡馆）

**怎么玩（小游戏机制）**：
1. 到钓鱼点，交互，**选鱼竿和鱼饵**
2. 点击鱼钩图标抛竿
3. 等几秒鱼上钩
4. 屏幕顶部出现**绿条**，左右移动
5. 用屏幕控制**把黄色标记保持在绿区内**
6. 保持足够久 → 鱼累了 → 钓上来

**鱼舱与卖鱼**：
- 打开底部钓鱼菜单 → **鱼舱（Fish Hold）** 标签页，看所有钓到的鱼和各自价值
- 选中鱼 → 卖出 → 获得**鱼鳞币（Scale Coins）**
- 鱼鳞币用于买更好的鱼竿和鱼饵

**鱼市（Fish Market）**：
- **每天**有 **3 种鱼**处于高需求状态，售价比平时高得多
- 但**每种鱼每天只能卖 2 条** → 每天最多卖 6 条
- 建议先看当天高需求鱼再决定去哪钓

**鱼竿与鱼饵**：全部用鱼鳞币购买，部分需要**钓鱼等级**提升后解锁

**钓点与鱼类**：共收录 **60+ 种鱼**，分布在 **6 个钓点**：
| 钓点 | 示例鱼类 |
|---|---|
| Imaginist（理想馆） | Sunfish、Queen Angelfish、Blueface Angelfish、Flame Angelfish、Emerald Flame Angelfish、Salmon、Flounder、Knight Angelfish、Azure Shimmer、Yellowfin Tuna、Red Sunfish、Sunset Ripple、Blue-spotted Fish |
| Stellar Marina（星渚游艇码头） | Sunfish、Queen Angelfish、Whalehead Fish、Devil Triggerfish、Blue-striped Grouper、Dawn Ripple、Red Sea Bream、Cyan-spotted Fish、Ghost Triggerfish、Purple-striped Grouper、Skeletal Sea Bream、Flame Angelfish、Dawn Shimmer |
| Raindrop Court（落雨庭） | Black-Striped Piranha、Koi、Red Cap、Golden Arowana、Green-Spotted Piranha、Thunder Dragon、Neon Tetra、Lightning Eel、Red Arowana、Prismatic Fan、Betta |
| Caltrop Lake（水菱湖） | Koi、Rosy Barb、Red Cap、Golden Arowana、Calico Goldfish、Living Jade、Underwater Rainbow、Lightning Eel、Bananana、Kohaku Koi、Golden Thunder Dragon、Prismatic Fan、Betta |
| Nautili Tunnel West（鹦鹉螺隧道西） | Blueface Angelfish、Yellowfin Tuna、Puffball Fish、Azure Shimmer、Flounder、Salmon、Blue-striped Angelfish、Yellow Tang、Green-striped Angelfish、Blue-spotted Fish、Cyan Queen Angelfish、Purple Queen Angelfish、Icy Angelfish |
| Nautili Tunnel East（鹦鹉螺隧道东） | Flame Lionfish、Whalehead Fish、Devil Triggerfish、Blue-striped Grouper、Striped Lionfish、Saddleback Angelfish、Rocketfish、Red Sea Bream、Cyan-spotted Fish、Ghost Triggerfish、Venomous Lionfish、Purple-striped Grouper、Skeletal Sea Bream、Dawn Shimmer |
| Cape Square（海角广场） | Flame Lionfish、Whalehead Fish、Devil Triggerfish、Blue-striped Grouper、Striped Lionfish、Saddleback Angelfish、Rocketfish、Red Sea Bream、Cyan-spotted Fish、Ghost Triggerfish、Venomous Lionfish、Purple-striped Grouper、Skeletal Sea Bream、**White Dragon King** |
| Azure Vista（湛望角） | Blueface Angelfish、Yellowfin Tuna、Puffball Fish、Azure Shimmer、Flounder、Salmon、Blue-striped Angelfish、Yellow Tang、Green-striped Angelfish、Blue-spotted Fish、Cyan Queen Angelfish、Purple Queen Angelfish、Icy Angelfish、Peppermint Angelfish |
| **所有钓点** | Mahi-mahi、Blazing Mahi-mahi、Bluefin Tuna、Red-spotted Fish、Chub Mackerel |

**特殊鱼**：White Dragon King（白龙王）、Golden Thunder Dragon（金雷龙）、Thunder Dragon（雷龙）、Skeletal Sea Bream（骷髅海鲷）、Underwater Rainbow（水下彩虹）、Bananana

**钓鱼等级 10 解锁**：**甲虫币（Beetle Coins）** —— 角色升级的关键材料
> 🟡 来源：[Fishing Guide](https://neverness.gg/nte-fishing-guide/)、[Dailies Guide](https://neverness.gg/nte-dailies-guide/)（"Fishing at level 10 unlocks Beetle Coins, which are key to leveling up your characters"）

**⚠️ 已知 bug（攻略站记录）**：抛竿后把光标移到屏幕**左下角、UID 上方一点**，鱼上钩时立刻点击打开聊天框，可**绕过小游戏必定钓上**。攻略站提醒这属于利用 bug。

**一手补充（MaaNTE）**：
- 界面按钮：**鱼钩按钮（F）**、**鱼饵按钮（E）**
- 提示文本：「开始钓鱼」「钓鱼准备」「鱼上钩」「钓到鱼了！」「鱼逃走」「鱼儿溜走了」
- 错误提示：「需要装备鱼饵才可以钓鱼」「鱼舱中渔获已满，请出售一些鱼获再尝试」「鱼鳞币不足，尝试前往卖鱼」「未装备鱼饵，尝试前往装备」
- 有**万能鱼饵**（万能魚餌）
- 功能含**自动卖鱼**、**自动买鱼饵**（每次买 99 个上限）
- 渔具商店叫「渔获市场 / 鮮魚市場」

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/Fish/`、`MaaNTE/docs/zh_cn/introduction/Fish.md`、`locales/interface/zh_cn.json`

---

### 6.2 咖啡（做咖啡小游戏 / 咖啡制作）

> 注意区分两个不同的「咖啡」：**一咖舍（Cafe by Origen）** 是店铺经营系统（§7.1），而这里是**咖啡制作小游戏**。

**玩法**：选择关卡 → 「开始营业」→ 反复点击目标区域完成销售目标 → 领取奖励 → 按 F 继续下一轮

**一手确认的 UI 与机制**：
- 按钮：「开始营业」「领取奖励」
- 关卡类型：**「新品练习 I」（新品）** 等关卡选择
- 目标：**「达标星星图标」**（销售目标以星星显示）
- 消耗：**都市活力**（满星消耗 18 点）
- 有**营业倒计时**
- 需要**特定角色的都市技能达到 3 级**才能高效通关

**已知可用配队（一手）**：
| 方案 | 需求 |
|---|---|
| 自动做咖啡（标准） | 带上**娜娜莉**并将**都市技能点到 3 级** |
| 自动做咖啡（平民版） | **无需特殊角色** |
| 自动做咖啡（安魂曲 / 番茄汁） | 仅支持关卡 **1-1 新品练习 I**；需要**安魂曲**与**达芙蒂尔**的都市技能达 3 级，第三位推荐**海月**或**薄荷** |

**换算参考**：按满星消耗 18 点都市活力计算，消耗 700 点都市活力需要约 **39 次**

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/AutoCoffee/`、`MaaNTE/assets/resource/locales/interface/zh_cn.json`、`MaaNTE/docs/zh_cn/introduction/MakeCoffee.md`

---

### 6.3 钢琴（自动弹琴 / Piano）

**玩法**：游戏内有**可弹奏的钢琴**，玩家用键盘演奏。

**一手确认的键位系统（非常详细）**：
- **完整 36 键模式**：含半音，**推荐**
- **仅白键 21 键模式**（简单模式）：半音会被映射到最近的白键
- 音域范围：**60~95**（超出范围需处理）
- 超域处理三种模式：
  - `fold` = 八度折叠（默认，所有音符保留但可能碰撞）
  - `shift` = 自动移调 + 截断（音程关系正确，推荐多声部）
  - `cut` = 直接截断（只保留 60~95 范围内的音符）
- 支持 MIDI 文件（.mid / .midi），可调**播放速度**、**转调**（半音）、**解析轨道**（all / melody / 指定轨道索引）

**已知曲目**：**「迷星叫」**（音游/弹琴曲目）

> 🟢 一手来源：`MaaNTE/assets/resource/tasks/AutoPiano.json`、`MaaNTE/docs/zh_cn/introduction/AutoPiano.md`
> 原文选项：`task_auto_piano_input_key_mode_desc` = "36 = 完整36键（含半音，推荐）；21 = 仅白键21键（简单模式，半音会被映射到最近白键）"
> 原文选项：`task_auto_piano_input_range_mode_desc` = "fold = 八度折叠（默认，所有音符保留但可能碰撞）；shift = 自动移调+截断（音程关系正确，推荐用于多声部）；cut = 直接截断（只保留 60~95 范围内的音符）"

---

### 6.4 音游（超强音 / Super Sound / Rhythm）

**玩法**：节奏音游，消耗都市活力。

**一手确认**：
- 界面：「选歌界面」→「演奏界面」→「结算界面」
- 按钮：「开始演奏」
- 结算显示「**得分**」（Score / スコア / 점수）
- 有**演奏暂停**功能
- 结算页会**识别消耗的活力值**
- 支持**自动连打直到活力耗尽**
- 已知曲目：**「迷星叫」**

**攻略站补充（Fons 效率）**：
> "If you want the most Fons per City Stamina point spent, Super Sound is your answer. Replay the last track, hit S-Rank, and you earn **20,000 Fons in about 2 minutes**."
> —— 即**音游是每点都市活力收益最高、最快的刷钱方式**

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/Rhythm/`、`MaaNTE/assets/resource/tasks/Rhythm.json`
> 🟡 来源：[How to Get Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/)

---

### 6.5 排球（Volleyball）

**玩法**：排球小游戏，有**难度分级**和**周常联赛**。

**一手确认的完整机制**：
- **难度 1 / 2 / 3 / 4**，完成后继续后续难度
- **星级评价**：有**三星**判定；可选择「非三星胜利也继续下一关」或「仅三星胜利继续，其他胜利重新挑战」
- **需要选择队友**：主控角色 + 队友角色（2 人）
- 可选角色（一手列出）：**薄荷、零、娜娜莉、残虹、卡厄斯、真红、伊洛伊**
- 完成难度四最后一关三星后任务结束

**排球周常联赛（一手）**：
- 名称：**周常联赛**
- 结构：**共五场** = **小组赛两场 + 冠军赛三场**
- 从**联赛界面**启动，有**签表**和**选人**环节

> 🟢 一手来源：`MaaNTE/assets/resource/tasks/Volleyball.json`、`VolleyballWeekly.json`、`locales/interface/zh_cn.json`
> 原文：`task_auto_volleyball_weekly_desc` = "自动挑战周常联赛，共五场（小组赛两场、冠军赛三场），需要从联赛界面启动。"
> 原文：`task_auto_volleyball_option_continue_non_three_star_desc` = "开启后，胜利但不足三星时也继续下一关；关闭时仅三星胜利继续，其他胜利重新挑战。"

---

### 6.6 抚摸（Pet / Touch）

**玩法**：对宠物或角色执行「抚摸」互动。

**一手确认的操作流程**：识别到「抚摸」按钮 → **按 F** → **点击互动区域** → **按 ESC** 退出

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/Touch.json`
> OCR expected: `"抚摸", "撫摸", "(?i)Pet", "なでる"`
> 任务描述：`task_touch_desc` = "检测"抚摸"按钮并自动执行：按F → 点击互动区域 → 按ESC，重复100次"

---

### 6.7 其他生活玩法

#### 泯除方块（Tetris）
俄罗斯方块类小游戏。**一手确认**：
- 有**棋盘**、**对局**、**结算界面**
- 消耗**活力**（可识别活力值，活力耗尽自动停止）
- 支持**速降**（方块平移/旋转结束后按**空格键**快速下落）
- 有**匹配（matching）**流程

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/Tetris/Tetris.json`、`locales/interface/zh_cn.json`

#### 噗卡乐园（Puka Land）
1.4 版本新区域，游乐园。**一手确认**有「**幸运星（Lucky Star）**」小游戏：
- 有「开始游戏」按钮、开场动画
- 可「**再试一次**」重复进行
- 玩法是**敲空格键**命中

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/PukaLand/PukaLandLuckyStar.json`
> 🟡 来源：[官网](https://yh.wanmei.com/) — "全新区域-噗卡乐园 欢迎来到噗卡乐园，奇妙旅程就此开启！收集奇遇印记，解锁你的专属游园记忆吧！"

#### 拍卖之王（Bid King）
拍卖小游戏。**一手确认**：
- 有「**开始匹配**」按钮
- 出价超过 **100 万**时有**二次确认弹窗**
- 有**出价面板**（可关闭）
- 有「**系统保底估价**」机制：系统会按**当轮情报披露**算出最低估价
- 有「**中途撤退**」选项

> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/BidKing/`、`MaaNTE/assets/resource/tasks/BidKing.json`

#### 魔女占卜（Witch Divination / 魔女之家）
**每日**占卜。三种结果：
| 结果 | 效果 |
|---|---|
| **佚闻（Lost Tales）** | 揭示一个隐藏任务及其奖励 |
| **赐福（Bless）** | 当天剩余时间全角色获得战斗增益 |
| **寻宝（Treasure Hunt）** | 在地图上标出神谕石的精确位置 |

一手确认的交互：与 **黑羽（Blackbird）** 对话（按 F 与魔女交互），占卜类型选择项：「赐福」「寻宝」「佚闻」

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)
> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/WitchDivination/`（OCR expected: "黑羽"/"(?i)Blackbird"/"クロバネ"；节点「选择占卜类型 — 赐福/寻宝/佚闻」「魔女之家占卜入口」）

#### 喷泉打卡（Fountain / 纳库佩达之池 Nacupeda's Pool）
**每日**打卡。位于地图**西南部**。两个对话选项：
| 选项 | 效果 |
|---|---|
| **「真诚许愿（Make a Sincere Wish）」** | 给一枚 **Mhm! 硬币**，慢慢攒够换**免费 S 级弧光**（推荐） |
| **「硬币，我爱硬币，拿一些！」** | 给**装饰品**（家具等） |

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)
> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/FountainCheckin.json`（流程：识别喷泉打卡按钮 → 按 F → 等待动画 → 识别许愿选项并点击 → 跳过剧情 → 按 Esc 退出）；OCR 识别「纳库佩达之池」/「納庫佩達之池」/「ナクペイダの池」

#### 贝果（Bagel）—— 游戏内社交平台
**玩法**：游戏内有类似社交平台的「贝果」，可以**拍照、保存、发布内容**。

> 🟢 一手来源：`MaaNTE/assets/resource/tasks/BagelSpam.json`
> 原文：`task_bagel_spam_desc` = "自动完成拍照、保存并发布贝果内容。仅支持前台控制器。"
> 相关选项：「发布前先拍个照」「发布次数」「标题」「正文」（支持**预设随机文本**或 **AI 生成**文本）

#### 送货上门 / 补货（Delivery）
一咖舍管理的一部分：**管理等级 2** 解锁「送货（Delivery）」，可以把食材直接送到店里，但**要收手续费**。

> 🟡 来源：[Cafe by Origen Guide](https://neverness.gg/nte-cafe-by-origen-guide/)
> 🟢 一手佐证：pipeline 中有「送货上门」「确认送货」按钮

#### 粉爪快速拾取
按住 **F** + 滚轮实现**极速拾取**地面物品。

> 🟢 一手来源：`MaaNTE/docs/zh_cn/introduction/AutoFScroll.md`、`assets/resource/tasks/AutoFScroll.json`

---

## 7. 其他系统

### 7.1 一咖舍（The Cafe by Origen）—— 店铺经营

**解锁**：都市大亨 **4 级**（需要累计 **200,200 方斯** + 花费 **10 点都市活力**）
第一家店在 **Bridge Crossings 的 182 Bluebeard Road**，只要 **5,000 方斯**

**可以拥有最多 5 家咖啡馆**：
| 店铺位置 | 所需管理等级 | 价格 |
|---|---|---|
| 182 Bluebeard Road | 1 级 | 5,000 方斯 |
| 106 Fiscus Avenue | 5 级 | 20,000 方斯 |
| 1122 North Davidia Avenue | 10 级 | 40,000 方斯 |
| 88 Moomin Street | 17 级 | 75,000 方斯 |
| 199 Hankaku Street Plaza | 25 级 | 100,000 方斯 |

**核心机制**：
- **管理等级（Management Level）**：最重要的数值。**每次收取营收都会涨**，所以要勤收
- 升级解锁：更多菜单位、更好的商品；**22 级**解锁直接升级现有菜单项
- **店长特供（Owner's Selection）**：主动模式，亲自当咖啡师服务客人，**消耗都市活力**但收益高于被动收入
- **食材库存**：**绝对不能断**，断了咖啡馆**完全停止收入**。仓库最多存 **72 小时**的食材
- **菜单**：不摆商品就不赚钱，新品解锁立刻换掉旧品
- **装修提升人气（Popularity）**，人气直接乘算每小时方斯收入
  - 三个装修类别：**桌椅（Tables & Chairs）**、**墙面（Walls）**、**摆件（Ornaments）**
  - 购买地点：桌椅 → DeLuxur Decor；墙面 → Oops! Chest Gift Shop、Moby-Dick Bookstore 等；摆件 → DSD POP
  - **建议从桌椅开始**（每方斯的人气提升最高）

**员工与生活技能（Life Skills）**：每家店可安排 **2 名角色**当员工，每人有咖啡馆管理相关的生活技能，激活后给店铺**永久增益**：

| 角色 | 技能 | 关键收益 | 评价 |
|---|---|---|---|
| **白藏 Baicang** | Thriving Daily | +18/+27 客流；店长特供中连击保留 | ★★★★★ |
| **Sakiri** | No Work, No Reward | 菜品价格提升；同标签 3 个时 +0.3 方斯 | ★★★★★ |
| **Skia** | Middle Manager | +18/+27 客流；店长特供中顾客耐心 +50% | ★★★★☆ |
| **吱 Chiz** | Lobby Manager | +18/+27 客流；店长特供中每道正确菜品提价（最高 15 倍） | ★★★★☆ |
| **Adler** | Coffee Master | 菜品价格提升；店长特供中自动备咖啡 | ★★★★☆ |
| **娜娜莉 Nanally** | Family Business | 每个主菜标签提升菜品价格；与白藏搭配好 | ★★★★☆ |
| **达芙蒂尔 Daffodill** | The Art of Hospitality | +18/+27 客流；店长特供中高价菜单出现更多 | ★★★☆☆ |
| **薄荷 Mint** | Mint Tornado | +0.12/+0.18 菜品价格；店长特供中小费 | ★★★☆☆ |
| **Aurelia** | Perfect Fit | 每个饮料标签 +1%/+1.5% 客流；顾客离场给小费 | ★★★☆☆ |
| **Edgar** | Knowledge in Action | +18/+27 客流；满级额外客流 | ★★☆☆☆ |
| **Haniel** | A Pro on the Job | +0.12/+0.18 菜品价格；店长特供无特殊加成 | ★★☆☆☆ |

**生活技能解锁**：需要**无梦种子（Dreamless Seeds）**等材料，来自**日常任务**和**管理指南奖励**。
攻略建议：**不要把种子全砸一个角色**，先分散激活多个角色的第一档技能基础。

> 🟡 来源：[Cafe by Origen Guide](https://neverness.gg/nte-cafe-by-origen-guide/)
> 🟢 一手佐证：`MaaNTE` 有「领取一咖舍收益」任务（按 **F5** 打开一咖舍界面 → 一咖舍按钮 → 提取收益 → 确认收益）；自动补货流程含「选择24小时补货周期」「确认补货」「库存已满」「送货上门」；OCR 文本「店长特供」「本次收益」

**一咖舍每日例行（攻略建议）**：
1. 登录先收营收
2. 打开管理，解锁所有新配方
3. 从物品列表切换到最贵的菜品和饮料
4. 点**补货**，选 **24 小时**选项（**不要选 72 小时**，因为明天新配方解锁后要再换）
5. 勾掉店铺界面顶部的**管理指南任务**，拿一次性方斯奖励

> 🟡 来源：[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/)

### 7.2 公寓 / 家园（Apartment / Home System）

**买第一间公寓后**可以放置**异象家具（Anomaly Furniture）**。

**已知公寓/房产类型**（一手确认，共 **6 处**，对应 MaaNTE 家具领取任务的 6 个开关）：
| 中文名 | 英文名 |
|---|---|
| **维纳公寓** | Wiener Apartments |
| **伊登公寓** | Eden Apartments |
| **天景空馆** | Skyview Halls |
| **金都云邸** | Golden Capital |
| **天骏公阁** | （英文名未在本地化文件中给出） |
| **峰林别墅** | Fenglin Villa |

**机制**：
- 异象家具来自击败城市异象，**每件给被动加成**
- 装饰提升**房屋舒适度（House Comfort）**，进而升级其他家居功能
- **可以邀请角色入住**，他们会**与家具互动**，可以一起做活动提升**羁绊等级（Bond Level）**
- 更高羁绊解锁**约会（dates）**、特殊奖励和其他加成
- 公寓购买是**都市大亨升级任务**之一（200,000 方斯那档）
- **盲眼财神（Blind Mammon）**装饰放在家里，交互可进入**贪婪领域（Realm of Greed/Mammon）**副本

**其他家具机制（一手）**：
- **旧邮箱（Old Mailbox）**：接收**特别都市委托**（周常悬赏，奖励方斯，收益取决于邮箱等级）；等级越高收益越高
- 升级盲眼财神家具需要**贪食之眼（Gluttonous Eye）**和**贪婪硬币（Covetous Coins）**（来自惠比寿拍卖行）

> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/)、[Dailies Guide](https://neverness.gg/nte-dailies-guide/)
> 🟢 一手来源：`MaaNTE/assets/resource/tasks/Furniture.json`（6 个 switch 选项：维纳公寓 / 伊登公寓 / 天景空馆 / 金都云邸 / 天骏公阁 / 峰林别墅）
> 🟢 一手来源：`MaaNTE/assets/resource/base/pipeline/Furniture/FurnitureStatus.json`（OCR expected: "维纳公寓"/"維納公寓"/"伊登公寓"/"天景空馆"/"金都云邸"/"天骏公阁"/"峰林别墅"）

**⚠️ 注意**：MaaNTE 的家具领取任务只能识别并领取**3 个已知家具**（仓鼠球 / 棉棉 / 破损的木箱），且「不保证能领取新放置的家具」。这说明游戏内**实际可领取的家具远多于 3 个**，只是自动化工具只覆盖了这 3 个。
> 🟢 一手来源：`MaaNTE` — `task_furniture_desc` = "依次识别并领取三个已知的家具（仓鼠球、棉棉、破损的木箱）。注：不保证能领取新放置的家具。"

### 7.3 好感度 / 羁绊（Affection / Bond）

**送礼机制**：
- **每天最多送 10 份礼物**
- **单个角色每天最多 3 份**
- 提升**好感等级（Affection levels）**很慢，所以每天送很重要
- **攻略建议优先送 Edgar**：把他送到 **Rank 10** 会给你一个有用道具，并且满级后**每周**可以从他那里领取一份随机的**猎人指南（Hunter's Guide）**

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)

**羁绊等级（Bond Level）**：邀请角色入住公寓后，一起做活动可以提升，解锁约会和特殊奖励。

> 🟡 来源：[Beginner's Guide](https://neverness.gg/neverness-to-everness-beginners-guide/)

**⚠️ 争议事件（供参考）**：2026 年 8 月 **1.3 版本**上线后，玩家发现上半限定角色「**残虹**」的**六级好感度剧情**中包含其被审讯人员抽耳光抽至昏迷的内容，引发强烈不满。后续官方账号评论区被冲，**打耳光剧情被删改**。
> 🟡 来源：[中文维基「1.3版本角色好感度剧情争议」章节](https://zh.wikipedia.org/wiki/異環)，引用[游民星空 2026-08-17 报道](https://wap.gamersky.com/news/Content-2190279.html)

### 7.4 商店

| 商店 | 说明 | 解锁 |
|---|---|---|
| **猎人交易所（Hunter Exchange）** | 用**方斯**换升级材料与抽卡券（含**安努利斯**和 **Tri-Key**）。**都市大亨等级越高，可换的东西越好** | 都市大亨 6 级 |
| **惠比寿拍卖行（Ebisu's Auction House）** | **每周**刷新随机库存，部分稀有物品只在这里出现。**出价最高者得**。可拿**贪食之眼**和**贪婪硬币**（升级盲眼财神家具用） | 主线第 3 章后 |
| **商场 Lost Exchange** | 用 **Lost Pieces** 换**抽卡骰子**和 **Tri-Key**。**每月 1 日刷新** | — |
| **爪爪银行（Pink Paws Bank / Pink Paws Den）** | 用**爪爪币（Paw-Paw Coins）**买载具（B100 20,000；Tomorrow Rush 30,000） | — |
| **Rewind（模块抽卡）** | Console 菜单内，消耗**胡萝卜币（Carrota Coins）**铜/银/金 | — |

**购物/生活类店铺**（食物与家具来源）：Bigmouth Baozi、Family Restaurant、Marigny Pizza、Felicità Gelato、Ramen Shop、Tofu shops、Bob's Vending Machine、Alice's Bakery、Pharmacy、Puka Vending Machine、Candy Shop、DeLuxur Decor、Oops! Chest Gift Shop、Moby-Dick Bookstore、DSD POP

> 🟡 来源：[City Tycoon Guide](https://neverness.gg/nte-city-tycoon-guide/)、[Dailies Guide](https://neverness.gg/nte-dailies-guide/)、[Vehicles List](https://neverness.gg/nte-vehicles-list/)、[All Items](https://neverness.gg/items/)、[Currency Guide](https://neverness.gg/the-players-guide-to-every-currency-in-neverness-to-everness/)

### 7.5 抽卡（Scarborough Fair —— 骰子棋盘制）

**这是 NTE 最独特的系统：抽卡不是传统「抽」，而是「掷骰子在棋盘上走格子」。**

**基本规则**：
- 系统名：**Scarborough Fair**
- 分 **限定棋盘（Limited Board）** 与 **标准棋盘（Standard Board）**
- 每次抽卡消耗**骰子**，掷 1~6 点，棋子（**Chuppa**）前进对应格数
- **落在哪格就拿哪格的奖励**：S 级角色、A 级角色、武器（弧光）、时装皮肤、货币、额外骰子
- 棋盘格子布局**根据掉落率随机生成**（玩家无法控制结果，只是表现形式更有趣）

**骰子类型**：
| 骰子 | 用途 |
|---|---|
| **Fabricated Dice（质实骰子）** | 标准棋盘 |
| **Solid Dice（固实骰子）** | 限定棋盘 |
| **Tri-Key** | 弧光/武器池 |

每颗骰子 **160 安努利斯**，**十连 1,600 安努利斯**

**限定棋盘概率与保底**：
- **S 级角色基础概率 1.87%**
- **A 级角色或弧光 22.98%**（角色 11.67% + 弧光 11.31%）
- **100% 保证**：任何抽到的 S 级角色**必定是当期 UP 角色**——**没有 50/50 歪**
- **90 抽保底** S 级角色
- **70 抽触发「棋盘改造（Board Modification）」**：S 级掉率**立即跳到 19.59%**（不是渐进软保底，是一次性跳升）
- 棋盘改造还会把某些格子**变成 S 级角色格**
- **每 10 抽保底 1 个 A 级**（角色或弧光）
- **保底跨池继承**

**棋盘格子类型**：
| 格子 | 效果 |
|---|---|
| **Apprentice Chest（紫）** | 最常见，0.2% 出 UP 的 S 级角色，多数时候给 B 级弧光 |
| **Hero Chest（金）** | 更稀有，**3%** 出 S 级角色；额外给 **2 个 Warp Pieces**；没出角色则 97% 给 B 级弧光 |
| **Journey Together** | 显示角色头像的格子，**落上必得该角色**；70 抽棋盘改造后更常见 |
| **Arc Light Mystery Box** | 随机给当期 A 级弧光 |
| **Warp Pieces / Lost Pieces** | 直接给商店货币，有些格子给最多 **50 Warp Pieces** |
| **Roll Again** | 立刻给一次免费骰子 |
| **Slumberland（守护者遭遇）** | 在**前方 9 格**生成守护灵。你有 **3 次掷骰**机会追上或越过它，但守护灵每次你掷完会**额外前进 2 格**。成功追上给 **30 Warp Pieces**（≈ 一次免费十连的价值） |
| **Card tiles（A / S）** | 保证给 A 级或 S 级物品；**S 级卡格保证给 UP 角色** |

**秘密集市（The Secret Fair）**：通过特定入口格进入的**金色特殊区域**，格子更少但奖励质量更高，含「**多重惊喜**」格（5 个免费骰子）、限定角色时装格、**载具皮肤格**、S 级角色格。相当于抽卡系统的**奖励关卡**。

**保底继承规则**：
| 保底类型 | 是否继承 | 说明 |
|---|---|---|
| 限定棋盘角色保底 | ✅ 是 | 所有限定棋盘之间继承，永不浪费 |
| 标准棋盘角色保底 | ✅ 是 | 永久计数，永不重置 |
| 弧光研究计划保底 | ✅ 是 | 所有轮换之间继承（6 次十连保底 S 级弧光，8 次十连保底 UP） |
| 限定棋盘**时装里程碑** | ❌ 否（有例外） | 50/120/200 抽的时装计数**不跨池继承**，但**该池复刻时保留** |
| 标准棋盘新手折扣 | ❌ 否 | 前 5 次十连 20% 折扣（8 颗骰子代替 10 颗），仅限**十连**，累计 50 抽后失效 |
| 标准棋盘新手奖励 | ✅ 永久 | 50 抽后可**自选一个 S 级角色**，永不过期 |

**时装里程碑系统**：
- 每个限定棋盘有 **3 套专属时装**，分别在 **50 抽 / 120 抽 / 200 抽**获得
- 也可以从特定格子低概率提前掉落（基础 0.33%，保底激活时 0.68%）
- 时装计数**不跨池继承**，但**该池复刻时保留**
- 这是 NTE 主要的付费点：**角色相对好拿（保底且无 50/50），但限定时装要 200 抽**

**标准棋盘新手奖励**：50 抽后可从 6 个起手 S 级中**任选一个**：**Sakiri、Daffodill、Baicang、Jiuyuan、Fadia、Hathor**

> 🟡 来源：[Gacha System and Pity Explained](https://neverness.gg/neverness-to-everness-gacha-system-pity/)（完整数据逐条摘录）

**⚠️ 注意**：上述概率/保底数据来自 **2026-04-22** 的文章（公测前），版本更新后可能有调整。**未找到**更新后的概率表。

### 7.6 货币系统

| 货币 | 性质 | 用途 | 获取 |
|---|---|---|---|
| **安努利斯（Annulith）** | 高级货币（可肝） | 买骰子抽卡；加速城建与大亨进度 | 主线任务、异象实地调查、城市隐藏战利品、活动、每日兑换 |
| **裂隙结晶（Riftcrystals）** | **不可肝**，只能充值 | 直接买**外观**（角色时装、载具皮肤） | 充值，与安努利斯 **1:1** |
| **方斯（Fons）** | 基础货币 | 买房产、买家具、买材料、猎人交易所 | 各种活动、店铺被动收入、劫案、赛车 |
| **质实骰子（Fabricated Dice）** | 抽卡券 | 标准棋盘 | 每个新等级与活动 |
| **固实骰子（Solid Dice）** | 抽卡券 | 限定棋盘 | 安努利斯购买 |
| **Tri-Key** | 抽卡券 | 弧光（武器）池 | — |
| **Warp Pieces** | 商店货币 | 换觉醒材料或额外骰子 | 抽到高阶重复角色/弧光 |
| **Lost Pieces** | 商店货币 | 在 Lost Exchange 换角色升级资源与基础装备材料 | 低阶抽取与基础行为 |
| **胡萝卜币（Carrota）** | 模块抽卡货币 | Rewind 模块抽卡 | 副本刷取（铜/银/金） |
| **甲虫币（Beetle Coin）** | 角色升级材料币 | 角色升级 | 异象委托、钓鱼 10 级 |
| **鱼鳞币（Scale Coins）** | 钓鱼货币 | 买鱼竿与鱼饵 | 卖鱼 |
| **爪爪币（Paw-Paw Coins）** | 粉爪银行货币 | 买载具 | 粉爪相关玩法 |
| **U-00NE** | 材料 | 升级 | 异象委托 |
| **Mhm! 硬币** | 兑换币 | 攒够换免费 S 级弧光 | 每日喷泉许愿 |

> 🟡 来源：[Currency Guide](https://neverness.gg/the-players-guide-to-every-currency-in-neverness-to-everness/)、[Gacha Guide](https://neverness.gg/neverness-to-everness-gacha-system-pity/)、[Anomalies](https://neverness.gg/nte-anomalies/)

### 7.7 战斗通行证（环期赏令 / Battle Pass）

- 三种任务：**每日、每周、赛季**
- 每日/每周任务分别在每天/每周重置
- 查看：探索指南图标右边的图标 → 第二个像纸片的标签页 = 任务标签页
- 奖励分两页：第一页为主，**第二页是经验与修行奖励**（「领取环期赏令经验」→「领取历练奖赏」）
- **环期赠礼**：活动期间签到可得**质实骰子 ×10**

> 🟡 来源：[Server Reset Time](https://neverness.gg/nte-server-reset-time/)、[官网](https://yh.wanmei.com/)
> 🟢 一手来源：`MaaNTE/docs/zh_cn/introduction/ClaimRewards.md`（按 **F1** 打开活动界面，按 **F2** 打开环期赏令界面）

### 7.8 联机 / 多人（Co-op Multiplayer）

**解锁**：约游戏开始 **30–35 分钟**后自然解锁，大约 **猎人等级 7** 时，多人功能出现在**游戏内手机**上。

**怎么用**：
1. 打开游戏内手机
2. 点 **Multiplayer** 按钮（在**第 2 页**，Tutorial 按钮旁边）
3. 打开多人菜单，顶部有搜索栏
4. 输入好友 **UID** 找到对方
5. 发送邀请，对方接受即可加入

**支持最多 4 人**。

**可玩内容**：战斗挑战、**赛车**、探索、小游戏、**家庭访问（Home visits）**
**不支持**：**主线剧情仍为单人**，不能一起推进叙事。

> 🟡 来源：[Co-op Guide](https://neverness.gg/nte-co-op-multiplayer/)

### 7.9 终局内容（Endgame）

| 内容 | 说明 |
|---|---|
| **Beyond the Rails** | NTE 的**终局挑战模式**。奖励极其丰厚，尤其是**安努利斯**。**Special Routes 每个游戏版本轮换**，版本结束前尽量多清关 |
| **贪婪领域（Realm of Greed / Mammon）** | 通过家里的**盲眼财神**装饰进入的特殊异象区。**每周重置**，按难度给方斯，最高 **100,000 方斯**。需完成「Yarnball or Fons?」任务解锁 |
| **异象巡礼（Anomaly Pilgrimages）** | 升级角色**异能能力**材料的主要来源。**每周只有 3 次** |
| **粉爪大劫案（Pink Paws Heist）** | 双周重置，最高 100 万方斯 |

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)、[How to Get Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/)

### 7.10 时装 / 外观

- **角色时装**：可通过抽卡里程碑、裂隙结晶购买、活动获得
- **载具皮肤**：裂隙结晶购买、秘密集市抽卡格
- **滑翔翼皮肤（Glider skins）**：存在该系统
- 已收录多套角色时装，例如：Esper Zero（Beginning of the Story / Hunter off-duty / City Wanderer / Unconventional Attire / School Musings / Graffiti in Progress）、Mint（CSU Prodigy / To Mary / Leisurely Holiday）、Nanally（Family Boss / Phoenix Kick / The Popular Kid / Fluffy Flying Tiger / Reverse Fairy Tale）等

> 🟡 来源：[Outfits and Glider Skins](https://neverness.gg/nte-character-outfits-glider-skins/)
> 🟢 一手佐证：`MaaNTE` 本地化中有「时装」相关选项

---

## 8. 每日/每周例行

### 8.1 重置时间（重要）

| 重置类型 | 时间 |
|---|---|
| **每日重置** | **每天 5:00（服务器当地时间）** |
| **每周重置** | **每周一 5:00（服务器当地时间）** |

**各服务器本地时间**：
| 服务器 | UTC 偏移 | 本地重置时间 |
|---|---|---|
| **Asia** | UTC +8 | CST 5:00 AM / PHT 5:00 AM / JST 6:00 AM / KST 6:00 AM / IST 2:30 AM |
| **America** | UTC −5 | PST 2:00 AM / PDT 3:00 AM / CST 4:00 AM / CDT 5:00 AM / EST 5:00 AM / EDT 6:00 AM |
| **Europe** | UTC +1 | BST 5:00 AM / CET 6:00 AM / EET 7:00 AM |

> 🟡 来源：[Server Reset Time](https://neverness.gg/nte-server-reset-time/)

**⚠️ 注意时区差异**：攻略站（Dailies Guide）写的是「每天 5:00 AM UTC+8」和「每周一 5:00 AM UTC+8」，而 Server Reset Time 页写的是「5:00 AM **服务器时间**」。两者对 Asia 服一致，其他服需以服务器时间为准。

### 8.2 每日清单（完整版）

| # | 任务 | 说明 |
|---|---|---|
| 1 | **花掉角色像素** | 每 6 分钟回 1 点，满 240。**先花掉再去打**，打能通关的**最高难度**异象区（难度越高掉率越好） |
| 2 | **完成日常任务** | 通过**探索指南**菜单查看。通常正常游玩 + 花体力就能到**活跃度 100**，解锁全部日常奖励 |
| 3 | **去纳库佩达之池** | 地图西南部。选「真诚许愿」拿 Mhm! 硬币（攒免费 S 级弧光） |
| 4 | **去魔女之家占卜** | 三种结果：佚闻（隐藏任务）/ 赐福（当日战斗增益）/ 寻宝（标记神谕石位置） |
| 5 | **领取一咖舍收益并补货** | 30 秒的事，长期累积很多。补货选 24 小时 |
| 6 | **吱（Chiz）日常刷方斯** | 长按普攻从敌人身上吸金。**有每日上限**（40,000 方斯/日），尽量打满 |
| 7 | **送礼物** | 每天最多 **10 份**，单角色最多 **3 份**。**优先送 Edgar** 到 Rank 10 |

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)

### 8.3 每周清单（完整版）

> 每周一 5:00 (UTC+8) 重置

| # | 任务 | 说明 |
|---|---|---|
| 1 | **异象巡礼（最高优先级）** | 角色**异能能力**升级材料的主要来源。**每周只有 3 次**，先确认角色需要什么材料再打 |
| 2 | **花光都市活力** | 无论选哪个玩法都是 **1 点 = 1,000 方斯**。**效率建议**：先刷送货直到把**旧邮箱**家具升满，再转**钓鱼**（钓鱼 10 级解锁甲虫币） |
| 3 | **查看惠比寿拍卖行** | **每周**刷新随机库存，部分稀有物品只在这里。**出价最高者得**。要拿**贪食之眼**和**贪婪硬币**（升级盲眼财神家具用） |
| 4 | **清贪婪领域（Realm of Greed）** | 交互家里的**财神装饰**进入。按难度给方斯，**每周重置**，打能打的最高难度 |
| 5 | **完成特别都市委托** | 检查家里的**旧邮箱**。周常悬赏，奖励方斯。**收益取决于邮箱等级**，所以接委托前先把邮箱升满 |
| + | **领取 Edgar 的每周猎人指南** | 前提：Edgar 好感 Rank 10。每周可从他那领一份随机**猎人指南** |

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)

### 8.4 双周清单

| 任务 | 说明 |
|---|---|
| **粉爪大劫案（Pink Paws Heist）** | **每两周**重置。目标：在重置前打满 **100 万方斯**上限。最佳大额赚钱方式之一 |

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)

**粉爪大劫案详细机制**：
- 地点：**New Herland District 的粉爪银行总部（Pink Paws Bank HQ）**
- 设定：与「Vault Heist」导演和 Dvorak 合作的**模拟抢劫**
- **12 分钟**限时，**拾取越多赚越多**
- **不消耗都市活力**，在双周上限内可无限次刷
- **解锁条件**：都市大亨 **10 级**（= 累计 1,510,600 方斯）+ **房屋收藏 3 级**
- 找银行里的 **吱（Chiz）** 开始

**三种跑法目标**：
1. **收集混沌核心（Chaotic Core）与金库卡（Vault Card）** — 新手优先，为后续跑法攒道具。LG1 有最多钥匙卡刷新点
2. **刷 BOSS 与方斯** — 主流跑法，连锁击杀 BOSS 与金色敌人掉落
3. **全程金库 + 最终 BOSS（Mammon）** — 攒够卡后专程跑。**单人要留 8 分钟、组队留 4 分钟**打 Mammon

**收益参考（一手攻略实测）**：
| 结果 | 收益 |
|---|---|
| 差 | 80k+ 方斯 |
| 一般 | 130k+ 方斯 |
| 好 | 180k+ 方斯 |
| 完美 | 230k+ 方斯（单次实测最高 263k） |

**关键机制**：
- **必须在计时结束前撤离**。电话亭（Phone Booths）是撤离点，**会随时间关闭**
- **钥匙卡跨局保留**
- 每局约 **7–8 分钟**
- 单次跑法建议约 1 小时打满 100 万上限
- **Hotori 在大劫案中极其有效**——她能**停止时间，包括劫案计时器本身**
- 金色 BOSS 有：**Golden Spider**、**Golden Elk**、**Phone Booth Boss**、**Golden Lamp Boss**
- 楼层：**LG1 办公层**、**LG2 收藏层**、**LG3 金库层**

> 🟡 来源：[Pink Paws Heist Guide](https://neverness.gg/nte-pink-paws-heist-guide/)、[How to Get Fons Fast](https://neverness.gg/how-to-get-fons-fast-in-nte/)
> 🟢 一手佐证：`MaaNTE/docs/zh_cn/introduction/PinkPawHeist.md`（流程：OCR 识别「小吱」→ 按 F → 点「我要参加」→ 跳过剧情 → 点「进入」→ 等加载（OCR 识别「本局收益」）→ 跑图 → OCR 识别「确认撤离」→ 点击撤离）；OCR 文本「强制开启」「奋力撬锁中」「确认撤离」「撤退確定」

### 8.5 月度 / 版本末清单

| 任务 | 说明 |
|---|---|
| **Beyond the Rails** | 终局挑战。奖励（尤其安努利斯）巨大。**Special Routes 每个版本轮换**，版本结束前尽量清关。确保队伍练满 |
| **商场 Lost Exchange 兑换** | **每月 1 日刷新**。用 **Lost Pieces** 换**抽卡骰子**和 **Tri-Key**。**月底前清空**，不然浪费 |

> 🟡 来源：[Dailies Guide](https://neverness.gg/nte-dailies-guide/)

### 8.6 每日日常耗时

> "Once you get used to this loop, it takes maybe **15–20 minutes a day**."
> —— [Dailies Guide](https://neverness.gg/nte-dailies-guide/)

---

## 9. 附录：游戏内真实 UI 文本（一手）

> 以下全部来自 MaaNTE 的 OCR `expected` 字段与节点描述，是**直接对着游戏截图写的识别规则**，因此就是游戏内真实显示的文本。

### 9.1 按钮 / 界面文本

**通用按钮**：确认 / 確定 / 確認 / 关闭 / 關閉 / 全部领取 / 全部領取 / 领取 / 領取 / 替换 / 替換 / 切换 / 切換 / 更换 / 更換 / 购买 / 購買 / 傳送 / 传送 / 退出 / 进入 / 進入

**钓鱼**：开始钓鱼 / 開始釣魚 / 钓鱼准备 / 釣魚準備 / 鱼钩按钮(F) / 鱼饵按钮(E) / 万能鱼饵 / 萬能魚餌 / 渔获市场 / 鮮魚市場 / 收购 / 收購 / 鱼舱 / 鱼上钩 / 钓到鱼了！/ 鱼逃走 / 鱼儿溜走了 / 鱼鳞币不足，尝试前往卖鱼 / 需要装备鱼饵才可以钓鱼 / 鱼舱中渔获已满，请出售一些鱼获再尝试 / 未装备鱼饵，尝试前往装备

**咖啡**：开始营业 / 開始營業 / 新品 / 新品练习 / 达标星星 / 本次收益 / 店长特供 / 店長精選 / 领取奖励 / 库存已满 / 补货 / 補貨 / 送货上门 / 送貨上門 / 确认送货 / 选择24小时 / 确认补货 / 确认收益 / 提取收益

**大劫案**：小吱 / 我要参加 / 本局收益 / 强制开启 / 強制開啟 / 奋力撬锁中 / 奮力撬鎖中 / 撬锁中 / 确认撤离 / 確認撤離 / 撤离确认 / 撤退確定 / 中途撤退 / 开门 / 開門

**音游**：开始演奏 / 開始演奏 / 得分 / 选歌界面 / 演奏界面 / 结算界面

**其他**：魔女之家 / 占卜 / 赐福 / 寻宝 / 佚闻 / 纳库佩达之池 / 納庫佩達之池 / 都市大亨 / 都市闲趣 / 都市閒趣 / 海上钓客 / 海釣り / 抚摸 / 撫摸 / 赋能总览 / 賦能總覽 / 黑羽 / 迷星叫 / 开始游戏 / 開始遊戲 / 再试一次

**家具识别文本**：仓鼠球 / 倉鼠球 / 棉棉 / 破损的木箱 / 维纳公寓 / 伊登公寓 / 天景空馆 / 金都云邸 / 峰林别墅 / 选择空玻璃杯 / 选择天骏公阁

### 9.2 快捷键（一手确认）

| 按键 | 功能 |
|---|---|
| **F** | 通用交互（对话、拾取、开门、抚摸、喷泉打卡、与小吱对话） |
| **E** | 鱼饵按钮 |
| **Esc** | 关闭界面 / 退出互动 |
| **W / A / S / D** | 移动 |
| **空格（Space）** | 攻击 / 速降 |
| **F1** | 打开**活动界面** |
| **F2** | 打开**环期赏令（Battle Pass）界面** |
| **F5** | 打开**一咖舍界面** |
| **K** | 剧情推进（大劫案中每 0.6 秒按一次） |
| **Alt + 点击** | 大世界中点击探索指南/环期赏令按钮 |

> 🟢 一手来源：`MaaNTE/docs/zh_cn/introduction/*.md`、`MaaNTE/assets/resource/base/pipeline/`

### 9.3 场景管理器确认的界面清单（一手）

| 界面 | 说明 |
|---|---|
| 大世界（InWorld） | 主界面 |
| Esc 菜单 | — |
| 背包（Bag） | — |
| 角色（Characters） | — |
| 环期赏令（Battle Pass） | — |
| **探索指南（Exploration Guide）** | 日常任务 + 活跃度 |
| **都市大亨（City Tycoon）** | 大亨主菜单 |
| **都市闲趣（Hethereau Hobbies）** | 休闲玩法集合 |
| 活动菜单（Events） | — |
| 特殊小世界 | 粉爪大劫案、主线故事、**异象委托**等 |

> 🟢 一手来源：`MaaNTE/docs/zh_cn/develop/scene-manager.md`

---

## 10. 附录：术语中英对照表

| 中文 | 英文 | 说明 |
|---|---|---|
| 异环 | Neverness to Everness (NTE) | 游戏名 |
| 海特洛市 | Hethereau | 主城 |
| 鉴定师 / 异象猎人 | Appraiser / Anomaly Hunter | 玩家身份 |
| 异象 | Anomaly | 超自然实体 |
| 异象委托 | Anomaly Commission | 支线任务类型 |
| 异象图谱 | Anomagram | 异象委托列表 |
| 异能 | Esper | 元素系统 |
| 异能能力 | Esper Ability | 角色技能 |
| 异能循环 | Esper Cycle | 元素反应系统 |
| 弧光 | Arc | 武器 |
| 卡带 | Cartridge | 圣遗物 |
| 模块 | Module | 次级装备 |
| 控制台 | Console | 模块装备栏 |
| 觉醒 | Awakening | 重复角色突破 |
| 方斯 | Fons | 基础货币 |
| 安努利斯 | Annulith | 高级货币 |
| 裂隙结晶 | Riftcrystals | 充值货币 |
| 质实骰子 | Fabricated Dice | 标准池抽卡券 |
| 固实骰子 | Solid Dice | 限定池抽卡券 |
| 都市大亨 | City Tycoon | 经营系统 |
| 都市活力 | City Stamina | 周常体力 |
| 角色像素 | Character Pixels | 日常体力 |
| 都市闲趣 | Hethereau Hobbies | 休闲玩法集合 |
| 一咖舍 | The Cafe by Origen | 咖啡馆经营 |
| 店长特供 | Owner's Selection | 主动经营模式 |
| 猎人交易所 | Hunter Exchange | 方斯商店 |
| 猎人等级 | Hunter Level | 账号等级 |
| 鉴定等级 | Appraisal Level | 终局解锁等级 |
| 探索指南 | Exploration Guide | 日常任务入口 |
| 活跃度 | Activity Level | 日常活跃度（满 100） |
| 环期赏令 | Battle Pass | 通行证 |
| 粉爪大劫案 | Pink Paws Heist | 双周抢银行 |
| 超强音 | Super Sound | 音游 |
| 泯除方块 | — | 俄罗斯方块类 |
| 噗卡乐园 | Puka Land | 游乐园区域 |
| 魔女之家 | The Witch's House | 占卜地点 |
| 纳库佩达之池 | Nacupeda's Pool | 许愿喷泉 |
| 贝果 | Bagel | 游戏内社交平台 |
| 秘密金库 | Secret Vault | 隐藏宝箱（9 个） |
| 神谕石 | Oracle Stone | 收集品 |
| 异象家具 | Anomaly Furniture | 带被动加成的家具 |
| 房屋舒适度 | House Comfort | 家园等级 |
| 羁绊等级 | Bond Level | 角色好感 |
| 生活技能 | Life Skills | 咖啡馆增益技能 |
| 斯卡伯勒集市 | Scarborough Fair | 抽卡系统名 |
| 棋盘改造 | Board Modification | 70 抽触发的保底机制 |
| 秘密集市 | The Secret Fair | 抽卡棋盘的特殊区域 |

---

## 11. 来源 URL 清单

### 一手资料（工作目录内 MaaNTE 项目）

| 路径 | 内容 |
|---|---|
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/develop/scene-manager.md` | 场景管理器：界面清单、跳转接口、状态检测 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/Fish.md` | 钓鱼任务详解 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/MakeCoffee.md` | 做咖啡任务详解 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/AutoPiano.md` | 自动弹琴（键位/音域机制） |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/PinkPawHeist.md` | 粉爪大劫案流程 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/WithdrawMoney.md` | 一咖舍收益与补货 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/ClaimRewards.md` | 活跃度与通行证领奖 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/FountainCheckin.md` | 喷泉打卡 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/SoundDodge.md` | 音频闪避（战斗音效机制） |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/NaviWebSocket.md` | 世界坐标、地图导航、传送点 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/docs/zh_cn/introduction/AutoFScroll.md` | 粉爪快速拾取 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/assets/resource/locales/interface/zh_cn.json` | 全部任务选项与描述文本 |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/assets/resource/tasks/*.json` | 27 个任务定义（含分组、选项、默认值） |
| `/Users/dupi/Desktop/自动驾驶系统/MaaNTE/assets/resource/base/pipeline/**` | 各玩法的 UI 识别规则与中文 OCR 文本 |

### 二手攻略与百科

| URL | 内容 |
|---|---|
| https://en.wikipedia.org/wiki/Neverness_to_Everness | 英文维基：Gameplay 概览、元素类型、载具改装 |
| https://zh.wikipedia.org/wiki/異環 | 中文维基：简介、历程、评价、AI 争议、好感度剧情争议 |
| https://neverness.gg/nte-dailies-guide/ | **日常/周常/双周/月度完整清单**（核心来源） |
| https://neverness.gg/nte-city-tycoon-guide/ | **都市大亨完整指南** |
| https://neverness.gg/neverness-to-everness-beginners-guide/ | **新手指南**（双等级、装备、元素、家园） |
| https://neverness.gg/nte-element-guide-esper-cycle-explained/ | **元素反应系统详解** |
| https://neverness.gg/nte-best-team-compositions/ | 阵容推荐 |
| https://neverness.gg/nte-vehicles-list/ | **全载具列表与价格** |
| https://neverness.gg/nte-vehicles-tier-list/ | 载具强度榜 |
| https://neverness.gg/nte-fishing-guide/ | **钓鱼完整指南**（含全部鱼类与钓点） |
| https://neverness.gg/nte-cafe-by-origen-guide/ | **咖啡馆经营详解**（含员工技能表） |
| https://neverness.gg/nte-pink-paws-heist-guide/ | **粉爪大劫案攻略**（含跑图路线） |
| https://neverness.gg/nte-anomalies/ | **全异象委托列表与奖励** |
| https://neverness.gg/nte-server-reset-time/ | **重置时间与重置内容** |
| https://neverness.gg/how-to-get-fons-fast-in-nte/ | 快速赚方斯（含 9 个秘密金库位置） |
| https://neverness.gg/neverness-to-everness-gacha-system-pity/ | **抽卡系统与保底详解** |
| https://neverness.gg/the-players-guide-to-every-currency-in-neverness-to-everness/ | 货币系统 |
| https://neverness.gg/nte-co-op-multiplayer/ | 联机指南 |
| https://neverness.gg/items/ | 物品图鉴（食物、家具） |
| https://neverness.gg/nte-character-outfits-glider-skins/ | 时装与滑翔翼皮肤 |
| https://yh.wanmei.com/ | 《异环》国服官网（版本公告） |
| https://nte.perfectworld.com/ | 《异环》国际服官网 |
| https://wiki.biligame.com/yihuan/ | B站 wiki（**内容为空，无有效资料**） |
| https://wap.gamersky.com/news/Content-1948114.html | 游民星空：二测前瞻（通缉机制） |
| https://wap.gamersky.com/news/Content-2190279.html | 游民星空：1.3 好感度剧情争议 |

### 搜索工具状态说明

本次挖掘期间，`web_search` 工具**全程返回 HTTP 429（限流）**，因此改以 `curl` 直接抓取已知攻略站（neverness.gg 的 sitemap 提供完整文章列表），并通过工作目录内的 MaaNTE 项目获取一手游戏 UI 数据。中文搜索引擎（Bing / Baidu / DuckDuckGo）对中文查询均返回空结果或被拦截，故中文二手攻略主要来自中文维基与官网。

---

## 12. 明确未找到的内容

以下内容本次**未挖到**，需要后续补充或实机验证：

1. **任务面板的具体视觉布局** — 只知道入口（探索指南、左侧第二标签页、右下角 Refresh Time 倒计时），但不知道任务条目显示哪些字段（距离？奖励预览？追踪标记样式？）
2. **成就系统** — 未找到任何明确的「成就（Achievements）」系统资料
3. **宝箱收集进度系统** — 只找到 9 个「秘密金库」的位置列表，未找到全局宝箱计数/收集度百分比
4. **赛车玩法的具体赛道名称与关卡细节** — 只知道共 6 关、有不同障碍
5. **驾驶操作细节** — 未找到油门/刹车/手刹/漂移的具体按键（一手 pipeline 提到有「Handbrake and braking force」属性差异，说明有手刹机制，但未找到按键说明）
6. **通缉/交通违法系统在公测的确认** — 只有二测前瞻信息
7. **1.4 版本后的抽卡概率调整** — 现有概率数据来自公测前（2026-04-22）
8. **角色好感度等级的具体上限与每级奖励** — 只知道 Edgar Rank 10 有特殊奖励
9. **家园系统的详细装修机制** — 只知道有桌椅/墙面/摆件三类与「房屋舒适度」
10. **体力（角色像素）的具体消耗数值** — 不同副本消耗多少像素未找到
