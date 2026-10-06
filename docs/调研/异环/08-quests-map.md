# 《异环》任务体系与地图/地点 — 挖掘报告 #8

> 调研目标：让 AI 助手理解「任务在哪、怎么去」。
> 调研时间：2026-10-06 / 10-07
> 调研员：资料挖掘代理 #8

## 0. 来源说明（重要）

本报告有**两类来源**，每条结论都标注了出处：

| 标记 | 含义 |
|---|---|
| **【解包】** | 本机 `tools/nte_datatables/` 下的游戏解包数据表（Unreal `DataTable` JSON），版本标注 1.4.5。这是**游戏客户端原始数据**，可信度最高，但属未公开内部数据。 |
| **【本机】** | 本机项目代码/数据产物（`models/quest_index.json`、`Sources/AuroraDrive/Inference/QuestPanelReader.swift`、`MaaNTE/`），是**实测抓到的游戏行为**。 |
| **【网络】** | 公开网页（主要是 game8.co、interactivemap.app、官网）。附可点击 URL。 |

**网络调研受限说明**：`web_search` 工具全程返回 HTTP 429 限流，无法使用。中文搜索引擎（Bing 国内版）对「异环」二字做了**单字切分**，返回的全是「异」字的字典释义，**完全无法用于中文检索**。因此网络侧主要通过 **game8.co 英文攻略站**（可直接 curl）与 **interactivemap.app 地图 API** 获取。**中文社区（gamekee、biligame wiki、米游社、NGA、TapTap）未能获取到有效内容**——gamekee 页面为 JS 渲染，抓取只得到标题；biligame 的异环 wiki 页面 404；fandom 与 prydwen 被 Cloudflare 拦截（HTTP 403）。

---

## 1. 任务类型全解

### 1.1 官方任务类型枚举（一手数据）

**【解包】** `tools/nte_datatables/DataTable/DT_QuestTypeDetailData.json` 定义了 12 种任务类型，含**是否可追踪**、**是否在任务面板显示**、**类型图标**：

| 类型枚举 | 面板名称 | 可追踪 | 面板显示 | 图标资源 |
|---|---|---|---|---|
| `EQT_MAIN` | **正篇**（主线） | ✅ | ✅ | `UI_mission_zhixian` |
| `EQT_SIDE` | **支线** | ✅ | ✅ | `UI_mission_zhixian02` |
| `EOT_MULT_SHOP` | **支线**（商店类） | ✅ | ✅ | `UI_mission_zhixian02` |
| `EQT_EVERYDAY_COM` | **支线**（日常通用/委托） | ✅ | ✅ | `UI_mission_zhixian04` |
| `EQT_LIKING` | **羁遇** | ✅ | ✅ | `UI_mission_zhixian03` |
| `EQT_FAVORABILITY_ATMOSPHERE` | **羁遇**（好感氛围） | ✅ | ✅ | `UI_mission_zhixian03` |
| `EQT_LEGEND` | **番外** | ✅ | ✅ | `UI_mission_fanwai` |
| `EQT_BREAKTHROUGH` | **引导** | ✅ | ✅ | `UI_mission_YinDao2` |
| `EQT_EVERYDAY` | **日常** | ❌ | ❌ | `UI_mission_zhixian04` |
| `EQT_EVERYDAY_RANDOM` | （无名） | ❌ | ✅ | — |
| `EQT_ADVENTURE_CHAPTER` | （无名） | ❌ | ❌ | — |
| `EQT_ADVENTURE_CHAPTER_REWARD` | （无名） | ❌ | ❌ | — |

> **关键点**：`EQT_EVERYDAY`（日常）**不可追踪、不在任务面板显示**——它是活跃度/登录类的系统任务，不是可导航的剧情任务。这点对 AI 助手很关键：**日常任务不该去找路**。

### 1.2 各类型的实际体量

**【解包】** 汇总 39+ 张 `DT_Quest*.json`（共 4518 个任务行），`QuestType` 分布：

| 类型 | 数量 | 说明 |
|---|---|---|
| `EQT_MAIN` | 1340 | 正篇/主线，体量最大 |
| `EQT_SIDE` | 796 | 支线 |
| `EQT_LEGEND` | 477 | 番外（外传剧情） |
| `EQT_FAVORABILITY_ATMOSPHERE` | 450 | 羁遇（角色好感剧情） |
| `EQT_EASTER_EGG` | 327 | 彩蛋任务 |
| `EQT_LIKING` | 239 | 羁遇 |
| `EQT_EVERYDAY_COM` | 170 | 日常通用/委托 |
| `EQT_EASTER_EGG_WORLD` | 87 | 世界彩蛋 |
| `EQT_ADVENTURE_CHAPTER` | 58 | 冒险手册章节 |
| `EQT_BREAKTHROUGH` | 42 | 引导（等级突破等） |
| `EQT_EVERYDAY` | 9 | 日常（系统任务） |

**各任务表规模**（【解包】）：`DT_QuestMain_wzy` 499、`DT_QuestLegend` 423、`DT_Quest` 238、`DT_QuestMain_LJ` 158、`DT_TakeOrderQuestDataTable` 126（委托）、`DT_QuestSide_wzy` 80、`DT_QuestAdventureManual` 68、`DT_QuestSide_World` 49、`DT_Quest_Pgl` 46、`DT_QuestSide_Sly` 45、`DT_ConstructionSiteQuest` 44（工地委托）、`DT_QuestSide` 30、`DT_QuestLiking` 22、`DT_QuestEveryDay` 8。

### 1.3 章节结构

**【解包】** `DT_QuestChapter.json` 共 **223 个章节**，`ChapterBaseDesc` 字段给出章节归属大类：**正篇 / 支线 / 羁遇 / 番外 / 偶遇 / 引导**。

正篇章节序列（`ChapterBaseDesc=正篇`，按 `ChapterIndex`）：

| # | 章节 ID | 章节名 | 副标题 |
|---|---|---|---|
| 1 | MP01 | 不虞亦先兆 | 序章-上 |
| 2 | MP02 | 生意经与招财宝 | 序章-下 |
| 3 | MU01 | 「写作『既定』的谜面」 | — |
| 4 | MU00_00 | 猎人等级晋升 | 「写作『既定』的谜面」 |
| 6 | MU01_02 | 从捏造开始的恋爱大作战 | 「写作『既定』的谜面」 |
| 7 | MU01_03 | 成交？成交！ | 「写作『既定』的谜面」 |
| 8 | MU01_04 | 红字的研究 | 「写作『既定』的谜面」 |
| 9 | MU01_05 | 游梦洄廊 | 「写作『既定』的谜面」 |
| 140 | MU01_06 | 雾巢游戏 | 「写作『既定』的谜面」 |
| 205 | MU01_08 | **魔女** | 「写作『既定』的谜面」 |
| 210 | MU01_09 | **空号** | 「写作『既定』的谜面」 |
| 215 | MU01_10 | **PUKA** | 「写作『既定』的谜面」 |

> 序章 MP01「不虞亦先兆」/ MP02「生意经与招财宝」与 game8 的 "Prologue I / Prologue II" 对应（【网络】https://game8.co/games/Neverness-to-Everness/archives/592065 ，标题即 "List of All Main Quests (Episodes)"，正文：*"Episodes are Main Quests in Neverness to Everness (NTE)."*）。
>
> **⚠️ 英文名「Episode」= 中文「正篇」**（主线）。这是中英对照的关键映射。

其他大类举例：
- **番外**（`ChapterBaseDesc=番外`）：MU01_01 月光当铺、LC01 不言不知秋、LC02 番茄酱暴走现场实录、LC03 某传奇乐队（吗？）的第一页、MU01_07 勇者斗赤龙、LC04 致那一天的我们
- **偶遇**（`WJxxxx` 系列，共约 60 章）：老大巡视中、常日、不是乖孩子！、甜蜜的毒药、半日闲、非预期会面、都市随想曲、知识获取中、此间百味事、天气预报、三只羊四只羊、赤龙百态、电波同频中！、最闪耀的星、人间事、热心市民卡厄斯
- **引导**（`SU039_xx` 系列，共 11 章）：大亨之路迢迢、传说中的神车手、都市漫游、咖啡主理人、家的味道、本职工作、加班时间、综艺之星、新的委托、补给时间到、祝你「渔」快！

### 1.4 委托（Take Order）

**【解包】** `DT_TakeOrderQuestDataTable.json` 共 **126 个委托**，任务名如「**同城派送**」（`LocalizedString: "City Delivery"`），追踪地图为 `Testmap_liuyang`。

**【解包】** `DT_ConstructionSiteQuest.json` 共 **44 个工地委托**，任务名格式为「**「星沉湾」工地：工程委托**」，类型 `EQT_EVERYDAY_COM`，追踪地图 `XL_map_bigworld_test`（大世界）。

**【网络】** 出租车玩法 "Swift Travel"（快速旅行）是「都市闲趣 Hethereau Hobbies」下的接单玩法，需要 **City Tycoon 等级 3** 解锁。玩法：从手机 → City Tycoon app → Hethereau Hobbies → Swift Travel → 点 "Go Online" 接客，游戏**自动在地图上标记乘客位置并规划路线、把行程设为你当前的任务**；乘客初始耐心 1000，超时/碰撞/危险驾驶会掉耐心；单趟基础车费 2000 方斯（4 星以上车评 3000），最高小费 2000 方斯；每赚 1000 方斯消耗 1 点都市活力。
来源：https://game8.co/games/Neverness-to-Everness/archives/597477

### 1.5 日常任务

**【解包】** `DT_QuestEveryDay.json` 仅 8 条：一咖舍收取 1 次方斯 / 任意消费 1 次方斯 / 累计消耗 180 点本性像素 / 累计击败 5 个敌人 / 释放 3 次极轨攻击 / 赠送 1 次礼物 / **登录游戏** / 提升 1 次弧盘等级。**均无 `TrackMapName`**——确认日常任务不可导航。

**【网络】** 每日四个任务：Daily Login（200 EXP）、Earn 10,000 Fons（200 EXP）、Consume Character Pixels（300 EXP）、Get 100 Daily Activity Points（300 EXP），全做完共 1000 EXP。在 **Quests 标签页**查看与领取。
来源：https://game8.co/games/Neverness-to-Everness/archives/596514

### 1.6 异象委托 / 异象界域（Anomaly Commissions / Zones）

**【网络】** 共 **38 个普通（Common）+ 12 个高危（High-Risk）异象委托**。按区域分布：Bridge Crossings、Unheard Shores、Illusion Town、Miguel District、New Herland District、Duskmoor。
来源：https://game8.co/games/Neverness-to-Everness/archives/592066

异象界域（Anomaly Zone）是战斗竞技场，消耗**角色像素（Character Pixels）**换取猎人指南、染料、甲虫币等养成材料。**异象界域本身也是传送点**，需先发现才能传送。
来源：https://game8.co/games/Neverness-to-Everness/archives/596709

**【解包】** 存在专门的 `DT_Quest_Level.json`（6 行）与 `DT_QuestAdventureManual.json`（68 行，冒险手册）。

---

## 2. 任务面板信息

### 2.1 面板上有什么（实测）

**【本机】** 项目 OCR 链路 `Sources/AuroraDrive/Inference/QuestPanelReader.swift` 明确记录了任务面板的构成：

- **任务目标文字**：面板左侧显示当前目标，如「与路边着急的研究员对话」
- **追踪提示行**：面板上有一行「**V 按下进行追踪**」（PC 端按键提示）
- **ROI（屏幕区域）**：`questROI = CGRect(x: 0.030, y: 0.240, width: 0.370, height: 0.070)`（归一化坐标，左上原点）。换算到 2940×1912 分辨率 = **x 88~1176 / y 458~592**。
- **提示行过滤**：源码注释原文——*"提示行过滤：面板上「V 按下进行追踪」落在 ROI 内，必须剔除，否则会污染查询文本（OCR 拼成「与薄荷对话 V 按下进行追踪」→ 匹配失败）"*。过滤规则：`t.contains("按下") && (t.contains("追踪") || t.contains("跟踪"))`。
- **投票缓冲**：连续 3 次 OCR 结果相同才确认（防抖）。
- **节流**：0.7 秒一次，不是每帧跑。

> **结论**：任务面板显示 **任务名 + 目标描述 + 按键提示**；「V 按下进行追踪」是**提示行不是任务内容**，任何自动化处理都必须剔除。

### 2.2 面板文本 → 坐标 索引（本机已有产物）

**【本机】** `models/quest_index.json`（2.57 MB）是 `tools/quest/build_quest_index.py` 从 39 张任务表编译出的索引：

```
stats: {
  "files": 39,
  "objectives": 3819,        # 任务目标总数
  "with_coord": 2938,        # 带坐标的目标数
  "with_desc": 3086,
  "exact_keys": 1372,        # 完整描述文本 → 条目
  "core_keys": 1984,         # 剥掉动词前缀的核心词 → 条目
  "name_keys": 1128          # 任务名 → 条目
}
```

**索引条目结构**：`{qid, quest, desc, core, otype, x, y, z, force, src}`，其中 `x/y/z` 是**世界坐标（UE5 厘米）**。

**已验证的真实面板文字 + 坐标**（【本机】`verify/REPORT-task-3.md` 验证 1.2，全部候选数 = 1，唯一命中）：

| 面板文字（OCR 目标） | 匹配方式 | 世界坐标 (x, y, z) |
|---|---|---|
| 与路边着急的研究员对话 | exact | (-17869, 125947, 6441) |
| 路边着急的研究员对话 | substr | (-17869, 125947, 6441) |
| 与路边着急的研究员话 | core-sub | (-17869, 125947, 6441) |
| **搭乘电梯** | exact | (30757, 65971, 6258) |
| **走进局长办公室** | exact | (3990, 267360, 31760) |
| 与艾尔菲德交流 | exact | (3990, 267360, 31760) |
| 向眼前之人对话 | exact | (3920, 272093, 4685) |
| **进入电话亭** | exact | (4014, 272683, 4823) |
| 聆听奈丽的介绍 | exact | (3959, 263359, 7151) |

> **「与路边着急的研究员对话」的原始出处**（【解包】）：`DT_QuestLiking_LJ.json` 中的条目 `---活动开始对话---`，`ObjectiveType = EOT_TALK`，`TrackLocation = {X: -17868.69, Y: 125947.41, Z: 6440.8076}`。**坐标完全一致**，交叉验证通过。

**反向验证**：查询「对话」会得到 **364 个候选**（【本机】`verify/REPORT-task-3.md` 验证 1.3）——短查询必须判「存疑」而非「匹配成功」。匹配置信门槛：`exact` / `substr`(长度比≥0.5) / `core` / `core-sub` / `fuzzy`(≥0.62 入选、≥0.75 才可信) / `name`。**只有 `.ok` 允许用于寻路**。

---

## 3. 地图结构

### 3.1 主城

**【解包】** `DT_City.json` 只有一行：

```
City001 → CityName = "海特洛市"（英文 Hethereau），BelongsMapName = "XL_map_bigworld_test"
```

**【网络】** 官网：*"《异环》是 Hotta Studio 自主研发的超超自然都市开放世界 RPG。故事将从**海特洛市**启篇，作为首位「无证上岗」的「异象猎人」…"*
来源：https://yh.wanmei.com/index.html

> 第三方地图站 nteguide 把主城译作「海瑟劳」（`{"id":"hethereau","name":"海瑟劳","nameEn":"Hethereau"}`），**【本机】** `models/nteguide_map-core.json`。官方中文是**海特洛市**。

### 3.2 区域划分

**【解包】** `DT_MiniMapArea.json` + `DT_AreaDataTable.json` 给出完整区域表（`BelongsCityID = City001`，`MapName = XL_map_bigworld_test`）：

| 区域 ID | 中文名 | 英文名 | 对应维特海默塔 |
|---|---|---|---|
| 000 | M10区 | Area M10 | — |
| 001 | **桥间地** | Bridge Crossings | WertheimerTower_001 |
| 002 | **未闻浦** | Unheard Shores | WertheimerTower_002 |
| 003 | **绘空町** | Illusion Town | WertheimerTower_003 |
| 004 | **米格尔区** | Miguel District | WertheimerTower_004 |
| 005 | **新赫兰德区** | New Herland District | WertheimerTower_005 |
| 006 | **泊暮区** | Halfport District | WertheimerTower_006 |
| 008 | 拘留所 | Detention Facility | — |
| 009 | 向阳岛 | Sunni Island | — |
| 010 | 噗卡乐园 | Pukaland | — |

另有子区域：`City01_coffee_200/201/202` = **一咖舍**（The Cafe by Origen）。

**【网络】** interactivemap.app 的 `map_areas/1` API 返回 **8 个区域**（英文名）：Bridge Crossings、Illusion Town、Miguel District、New Herland District、Detention Facility、Unheard Shores、Sunni Island、**Duskmoor**。
来源：`https://interactivemap.app/neverness-to-everness/maps/imapp/api/map_areas/1`（可用 curl 直接取，注意返回带 UTF-8 BOM）

> **⚠️ 命名不一致提醒**：「绘空町」在第三方站被译作 **Illusion Town / 幻镇**；「泊暮区」在 interactivemap 上叫 **Duskmoor**，在 nteguide 上叫 **Halfport District**。**以游戏内中文名为准**：绘空町、泊暮区。

### 3.3 第二块大陆：沃伦大陆（4N）

**【解包】** `DT_MiniMapArea.json` 中有独立的 `Maps_4N` 地图，包含：

| 区域 ID | 名称 |
|---|---|
| 4N_Main | **沃伦大陆**（Warren Continent） |
| 4N_A | 绵绵村 |
| 4N_B | 巧克力火山 |
| 4N_C | 牛奶雪冰山 |
| 4N_D | 琥珀湖 |
| 4N_E | 赤龙古堡 |

**【网络】** 沃伦大陆是 **「999 Nights」（与龙共斗 / Fighting With A Dragon）** 玩法所在地，各区有独立 100% 完成度攻略：Warren Continent、Fuzzy Village（绵绵村）、Chocolate Volcano（巧克力火山）、Milk Ice Mountain（牛奶雪冰山）、Amber Syrup Lake（琥珀湖）。
来源：https://game8.co/games/Neverness-to-Everness/archives/609015 、 https://game8.co/games/Neverness-to-Everness/archives/608910 、 https://game8.co/games/Neverness-to-Everness/archives/609329 、 https://game8.co/games/Neverness-to-Everness/archives/609406 、 https://game8.co/games/Neverness-to-Everness/archives/609448

### 3.4 地图规模

**【本机】** 多来源交叉印证地图尺寸为 **13056 × 13056 像素**：

- `models/map_locations.json`：`"unit": "map-pixels-13056"`, `"mapPixels": 13056`, `"note": "坐标一律为 13056 地图像素（**不是百分比**）"`
- `MaaNTE/agent/custom/action/Navi/map_locator.py`：`MAP_SIZE = (11264, 11264)  # 大地图模板尺寸`
- `models/bigworldmap-13056.jpg`（7.7 MB 全图）
- 【本机】`verify/REPORT-task-3.md` 验证 1.4：「坐标系 = 13056」**PASS（已数字定案）**

> **⚠️ 两套坐标不要混**：`quest_index.json` 里的 x/y/z 是**世界坐标（UE5 厘米）**；`worldToMapPixel` 那套是**地图像素（13056）**。本机 `QuestPanelReader.swift` 顶部红线注释明确警告：*"历史事故正是「两套坐标在同一流程里来回倒置」"*。

**坐标量级**（【本机】`QuestPanelReader.swift` 自检）：世界坐标量级 `|x|,|y| < 1e6 厘米`（10 km 内），实测如 `(-17868, 125947)`、`(3990, 267360)`。

**大地图模板匹配**（【本机】`map_locator.py`）：
- `MINI_MAP_ROI = (28, 15, 150, 150)`（小地图在屏幕左上角）
- `MAP_CROP_SIZES = (268, 530, 660)`（对应不同缩放级别的小地图尺寸）
- `GLOBAL_MIN_SCORE = 0.85`（全局搜索最低置信度）
- `TELEPORT_DISTANCE = 320`（超过此距离建议传送）
- 因地图存在大量纯黑区域，限定搜索范围：`(8976, 9700, 1506, 2644)` 与 `(2561, 8703, 2312, 7719)`

### 3.5 传送点机制（核心）

**【解包】** `DT_TeleportPoint.json` 共 **124 个传送点**，全部 `bCanTeleport = true`，其中 25 个默认激活（`bDefaultActived`）。类型分布：

| 传送点类型 | 数量 | 含义 |
|---|---|---|
| `FinalTowerCampfire` | 47 | 终塔营火 |
| `MapTransfer` | 21 | 地图转移 |
| `FinalTowerPortal` | 15 | 终塔传送门 |
| `CloneTeleport` | 11 | 副本传送 |
| `WorldBossTeleport` | 9 | 世界 Boss 传送 |
| `RealEstate` | 7 | 房产 |
| `Common` | 7 | 通用 |
| **`WertheimerTower`** | **6** | **维特海默塔（区域主传送点）** |
| `FinalTowerCamp` | 1 | 终塔营地 |

**【网络】** 快速旅行（Fast Travel）三种方式，机制明确：
1. **维特海默塔（Wertheimer Tower）**——*"In Hethereau, there is currently one Wertheimer Tower per district."* 每个区一座。**必须先交互发现一次**才能用于传送，发现时给少量猎人 EXP。塔不仅解锁该区地图，还解锁该区的**异象委托**。
2. **ReroRero 电话亭（ReroRero Phone Booth）**——海特洛市**数量最多**的传送点，同样需先发现，发现给猎人 EXP。
3. **异象界域（Anomaly Zone）** 与 **幽灵列车站（Ghost Train Station）**——米格尔区北面森林中，`Beyond the Rails` 玩法的车站，也算传送点，需先发现。

来源：https://game8.co/games/Neverness-to-Everness/archives/596709

**【网络】** 探索度统计口径：Duskmoor 100% 完成度包含 **Oracle Stones（谕石）、Side Quests（支线）、Anomaly Commissions（异象委托）、ReroRero Phone Booths（电话亭）、Wertheimer Towers（维特海默塔）、Check-In Points（打卡点）、Magician's Gifts（魔术师礼物）**。
来源：https://game8.co/games/Neverness-to-Everness/archives/604643

**【本机】** `MaaNTE/assets/resource/base/map_teleport/teleport_points.json` 记录了实际使用的传送点，含**游戏内传送界面的分类名**：

| id | 名称 | 区域 | 分类（selectionName） | 图标 |
|---|---|---|---|---|
| fountain | 喷泉传送点 | 绘空 | **推荐地点** | phone_booth.png |
| lixiangguan | 理想馆 | 未闻浦 | 推荐地点 | tower.png |
| wushoutieyu | 无首铁驭 | 未闻浦 | **异象追猎** | wushoutieyu.png |
| qiaojianditower | 桥间地维特海默塔 | 桥间地 | 推荐地点 | tower.png |
| xingzhuport | 星渚码头 | 新赫兰德区 | 推荐地点 | phone_booth.png |
| huibishoupaimai | 惠比寿拍卖行 | 新赫兰德区 | 推荐地点 | huibishoupaimaihang.png |
| rabbithole | 兔子洞 | 新赫兰德区 | **异象界域** | rabbithole.png |
| migeertower | 米格尔区维特海默塔 | 米格尔区 | 推荐地点 | tower.png |
| xiangyangisland | 向阳岛 | 向阳岛 | 推荐地点 | phone_booth.png |

> **传送界面的三个分类**：**推荐地点 / 异象追猎 / 异象界域**。图标两类：**tower.png（维特海默塔）** 与 **phone_booth.png（电话亭）**。

**【本机】** `MaaNTE/assets/resource/base/image/map_ui/` 有 4 张地图界面图标：`compass.png`（罗盘）、`entrust.png`（**委托**）、`map_index.png`（地图索引）、`weekly_events.png`（周常活动）。

---

## 4. 地点命名规律

### 4.1 完整地名表（85 个）

**【解包】** `DT_QuestDisplayMapNameDetail.json` 是**任务面板显示地图名**的映射表，含 **98 个分组条目**，其中 13 个是**分组标题**（`---xxx---` 格式）：

```
---异象管理局---   ---海特洛市---   ---桥间地---   ---未闻浦---
---绘空町---      ---新赫兰德区---  ---噗卡乐园---  ---半港区---
---米格尔区---     ---真红大陆---   ---向阳岛---   ---泊暮区---   ---空号---
```

> **⚠️ 本机见过的「异象管理局」确认存在**，是**地点分组标题**，与海特洛市平级。
> **⚠️ 本机见过的「卡布罗集市」**：解包与网络资料中出现的都是「**斯卡布罗集市**」（Scarborough Fair）——见【本机】`MaaNTE/assets/resource/base/pipeline/Interface/Scene/SceneMenu.json` 与 `Common/Button/InWorld/ScarboroughFairButton.json`（*"大世界中的斯卡布罗集市按钮"*）。**本机记录的「卡布罗集市」应为「斯卡布罗集市」的漏字**。

**去重后的 85 个地名**（【解包】）：

```
M10区 | Z42环海公路 | 「空号」 | 上晴塔 | 伊亚大道 | 克莱门学园 | 北角镇 | 半港区 |
半角街 | 卡美洛大道 | 卷叶榕大道 | 向阳岛 | 噗卡乐园 | 圣托里斯大道 | 塔林大道 |
塞润尼缇庄园 | 奇诺大道 | 奥利哈刚「理想馆」 | 姆咪街 | 小叶榕路 | 巧克力火山 |
库勒涅步行街 | 弗拉明戈大道 | 愿木坡 | 提卡尔大桥 | 摇曳镇 | 新赫兰德区 | 星沉湾 |
星渚游艇码头 | 月光当铺 | 未闻浦 | 林中路 | 林檎大道 | 柴郡猫路 | 桥间地 |
水晶山大道 | 水梨子大道 | 水菱湖路 | 沃伦大陆 | 泊暮区 | 洋葱头路 | 海松路 |
海特洛市 | 海角巨蛋 | 海马街 | 湛望角 | 湛望角站 | 火炬木大道 | 照相馆 |
牛奶雪冰山 | 狐窗街 | 玉饼街 | 琥珀湖 | 白尾树盘山公路 | 白鹦鹉街 | 盐糊风情码头 |
米格尔区 | 索雷伊路 | 纳库佩达公园 | 绘空町 | 绵绵村 | 绵绵村外 | 绿墙坡 | 老城区 |
胡桃夹公路 | 艾利塔斯桥 | 萝卜头路 | 蒙特制药员工宿舍 | 蓝胡子路 | 西风谷地 |
赤龙古堡 | 轨外之境 | 金苹果藏馆 | 钨丝展厅 | 铁心9号路 | 雪樨大道 | 露天电影院 |
驾校方程式 | 鬼火小步大道 | 鳄鱼钟大道 | 鸢尾大桥 | 鹤径 | 鹦鹉螺隧道 |
麦昆幽灵大道 | 龙尾巴巷
```

### 4.2 命名规律总结

从 85 个地名可归纳出以下模式（【解包】统计）：

> **补充（【解包】`DT_AreaDataTable` 的 Robbank_001）**：还有带楼层前缀的室内区域命名「**G-接待大厅**」「**G-接待大厅 楼下**」（G = Ground，地面层），对应英文 "G – Reception Hall"。这类 `G-`/数字- 前缀用于**大楼内部楼层区域**。

1. **行政区**：`XX区`（米格尔区、新赫兰德区、泊暮区、M10区）、`XX地`（桥间地）、`XX町`（绘空町）、`XX浦`（未闻浦）、`XX岛`（向阳岛）、`XX村`（绵绵村）
2. **道路 / 大道**：`XX大道`（伊亚大道、卡美洛大道、圣托里斯大道、塔林大道、水晶山大道、水梨子大道、火炬木大道、雪樨大道、鳄鱼钟大道、麦昆幽灵大道、鬼火小步大道）、`XX路`（林中路、水菱湖路、海松路、索雷伊路、萝卜头路、蓝胡子路、铁心9号路）、`XX街`（半角街、姆咪街、海马街、狐窗街、玉饼街、白鹦鹉街）、`XX公路`（Z42环海公路、胡桃夹公路、白尾树盘山公路）
3. **桥 / 隧道 / 码头**：`XX大桥`（提卡尔大桥、艾利塔斯桥、鸢尾大桥）、`XX隧道`（鹦鹉螺隧道）、`XX码头`（星渚游艇码头、盐糊风情码头）
4. **建筑 / 场馆**：`XX馆`（金苹果藏馆、奥利哈刚「理想馆」）、`XX展厅`（钨丝展厅）、`XX学园`（克莱门学园）、`XX庄园`（塞润尼缇庄园）、`XX电影院`（露天电影院）、`XX巨蛋`（海角巨蛋）、`XX当铺`（月光当铺）、`XX照相馆`、`XX站`（湛望角站）
5. **自然地貌**：`XX湖`（琥珀湖）、`XX山`（牛奶雪冰山）、`XX谷地`（西风谷地）、`XX坡`（愿木坡、绿墙坡）、`XX湾`（星沉湾）、`XX角`（湛望角）、`XX岛`
6. **趣味 / 童话风命名**（异环特色）：洋葱头路、萝卜头路、玉饼街、胡桃夹公路、柴郡猫路、鳄鱼钟大道、鹦鹉螺隧道、龙尾巴巷、狐窗街、姆咪街、白鹦鹉街、鬼火小步大道、麦昆幽灵大道、三只羊四只羊、噗卡乐园、海马街
7. **玩家熟悉的地名**（本机 OCR/日志见过）：
   - **异象管理局**（地点分组标题，`---异象管理局---`）
   - **局长办公室**（任务目标「走进局长办公室」，坐标 `(3990, 267360, 31760)`）
   - **斯卡布罗集市**（大世界 UI 按钮）
   - **一咖舍**（The Cafe by Origen，子区域，也是都市大亨玩法）
   - **接待大厅** —— **【解包】** 确认存在：`DT_AreaDataTable.json` 的 `Robbank_001` 区域，中文「**G-接待大厅**」/ 英文 "G – Reception Hall"；另有「G-接待大厅 楼下」（地下层）。剧情文本：*"这里是接待大厅，通常受理已有预约的低级异象事件。"*（`DT_Quest.json` 的 `q110001_2` 序章介绍、`DT_IntroduceVoiceMsg.json` 同文）。**G- 前缀表明这是异象管理局/总局大楼内带楼层标识的区域**（本机 `tools/mapweb/MaaNTE-PPH/src/data/layers.js` 也有 `G-接待大厅`、`G-接待大厅 楼下` 两个图层名）。

> **「卡布罗集市」未找到**：全部数据源中只有「**斯卡布罗集市**」（Scarborough Fair），「卡布罗集市」应为笔误。

### 4.3 任务面板的地图名（DisplayMapName）

**【解包】** `DisplayMapName` 用的是**拼音式内部 ID**（不是中文），共 98 个键，例如：

| 内部 ID | 中文 |
|---|---|
| QiaoJianDi | 桥间地 |
| BanJiaoJie | 半角街 |
| XinHeLanDeQu | 新赫兰德区 |
| YeHuIsland | 夜壶岛？ |
| XiFengGuDi | 西风谷地 |
| ShuiLiZiDaDao | 水梨子大道 |
| ZhaoXiangGuan | 照相馆 |
| YouLinLangDao | 幽林廊道？ |
| M10Qu | M10区 |
| HuoShan | 火山 |
| MianMianCun | 绵绵村 |
| WuChao | 雾巢 |
| DeadNumber | 空号 |

**使用频次 TOP5**：QiaoJianDi 308、WuChao 303、BanJiaoJie 300、YeHuIsland 218、DeadNumber 172。

---

## 5. 导航方式

### 5.1 游戏内追踪机制

**【本机】** 任务面板上有「**V 按下进行追踪**」提示（PC 端）——**按 V 键追踪当前任务**。这是游戏内建的追踪功能。

**【解包】** 每个任务目标（`ObjectivesInfo`）都带 `TrackInfo` 结构，字段揭示了**游戏内导航的完整能力**：

```json
"TrackInfo": {
  "bForceTrackLocation": false,
  "TrackLocation": {"X": -90430.35, "Y": 131876.3, "Z": 9457.465},
  "fRange": 0.0,
  "ShowCenter": false,
  "MulTrackLocationArray": [],
  "TrackOffLocation": {"X": 0.0, "Y": 0.0, "Z": 0.0},
  "TrackMapName": "",
  "bNeedCrossBox": false,
  "bTrackGoalEnable": true,          // 追踪目标点启用
  "bNeedPassParking": false,
  "VehicleParkingArray": [],
  "AzimuthIndicatorable": true,      // 可显示方位指示
  "bShowNavigationPath": true        // ★ 显示导航路径
}
```

**统计（2753 条带 TrackInfo 的目标）**：

| 字段 | 为 true 的数量 | 含义 |
|---|---|---|
| **`bShowNavigationPath`** | **2701 / 2753（98%）** | **游戏内会画出导航路径** |
| `bTrackGoalEnable` | 2749 | 追踪目标点启用 |
| `AzimuthIndicatorable` | 2752 | 可显示方位指示 |
| `bForceTrackLocation` | 1046 | 强制追踪到具体位置 |
| `bNeedCrossBox` | 147 | 需要跨「盒」（跨区域/跨地图） |

> **结论：游戏内确实有导航路径绘制**（`bShowNavigationPath`），98% 的任务目标都会显示路径。还有 `AzimuthIndicatorable`（方位指示器）。`fRange` 字段暗示存在**范围型目标**（到达某半径内即算完成）。

### 5.2 有无自动寻路

**【未找到】** —— **在解包数据表、本机代码、网络攻略中，均未找到《异环》存在「自动寻路/自动导航到任务点」的功能证据。**

**【解包】** 仅找到与「寻路」字面相关的内容，均为**任务内的场景名或小目标**，非系统功能：
```
寻路 / 寻路1 / 寻路2 / 寻路3 / 寻路点1 / 寻路点2 / 寻路点3 / 寻路隐藏
寻路】建筑解离 / 寻路回安妮家
```

**【网络】** 出租车玩法 Swift Travel 中：*"the game will automatically mark their location on your map, **plot a route**, and set the trip as your current task"* —— 即**游戏会规划路线**，但这是**载客玩法内的路径规划**，不是玩家角色的自动寻路。
来源：https://game8.co/games/Neverness-to-Everness/archives/597477

> **诚实结论**：游戏提供「追踪 + 导航路径显示 + 方位指示」，但**未找到「点一下自动走过去」的自动寻路功能**。本机项目自己实现的 `Navi/`（本地路线导航 + 在线地图导航）是**第三方自动化**，不是游戏功能。

### 5.3 追踪标记

**【网络】** 战斗锁定标记：*"An enemy will appear locked on when **a small white diamond appears on them**."*（锁定敌人时出现**白色小菱形**）；PC 按**鼠标中键**、PS5 按 **R3** 锁定/切换目标。
来源：https://game8.co/games/Neverness-to-Everness/archives/597615

> 注意：这是**战斗目标锁定**标记，与**任务追踪标记**不是同一回事。任务追踪标记的具体视觉形态 —— **【未找到】** 公开资料描述。

**【解包】** 任务目标可指定怪物追踪图标：`MonsterTrackIcon` 字段（多数为空，指向 `AssetPathName`）。

### 5.4 本机实现的导航（可参考）

**【本机】** `MaaNTE/agent/custom/action/Navi/` 是一套完整的导航实现，含：
- `map_locator.py` —— 小地图模板匹配定位（大地图 13056/11264，多缩放级别）
- `nte_coordinate_api.py` —— *"Open UE5 movement-packet coordinate decoder"*，解码游戏移动包获取实时坐标（`API_VERSION = "1.3.0"`）
- `local_route_navigation.py` / `online_map_navigation.py` / `waypoint_navigator.py` / `route_runner.py`
- `angle_predictor.py` / `coordinate_position.py`

**【本机】** `MaaNTE/agent/custom/action/MapTeleport/`：
- `check_teleport_required.py` —— 判断当前位置是否需要传送
- `teleport_to_point.py` —— 执行传送
- 配置项：`point_id`、`teleport_point_id`、`position_backend: "auto"`、`coordinate_type: "world"`

**【本机】** `MaaNTE/assets/resource/base/map_teleport/check_points.json` 定义「过远则传送」逻辑：喷泉目标点 `worldX: -151702, worldY: 151178`，`threshold: 7000`，注释原文：*"用于判断当前位置距离喷泉目标点是否过远；threshold 为小于该距离时直接使用本地路线。"*

---

## 6. 常见任务目标类型

### 6.1 官方目标类型枚举与分布（一手数据）

**【解包】** 汇总 39+ 张任务表的 `ObjectivesInfo[].ObjectiveType`，共 **3478 条目标**：

| 目标类型 | 数量 | 占比 | 中文含义 | 典型面板文字 |
|---|---|---|---|---|
| **`EOT_TALK`** | **2259** | **65.0%** | **对话** | 与路边着急的研究员对话、与黑羽对话、与雪人小帕交谈 |
| **`EOT_ARRIVE_AREA`** | **433** | **12.5%** | **抵达区域** | 走进局长办公室、进入电话亭、搭乘电梯 |
| `EOT_CONVOY` | 226 | 6.5% | **护送 / 随行** | — |
| `EOT_SEQUENCE` | 152 | 4.4% | 序列（多步） | — |
| **`EOT_KILL`** | **100** | 2.9% | **击败** | 击败虚假的「贝拉」、击败暴走族首领、击败岩熔犀兽 |
| `EOT_CHANGE_TIME` | 74 | 2.1% | **改变时间** | — |
| `EOT_CHAT_END` | 52 | 1.5% | 对话结束 | — |
| `EOT_ARRIVE` | 19 | 0.5% | 抵达 | 抵达漫画家的住所、抵达镇子、抵达空间尽头 |
| `EOT_ITEM_LEVEL` | 18 | — | 物品等级 | — |
| `EOT_INTERACT` | 14 | — | **交互** | 调查大门、调查书架、调查时钟 |
| `EOT_ITEM_BAG` | 13 | — | 背包物品 | 收集辉环、收集浮毛 |
| `EOT_SUB_QUEST` | 12 | — | 子任务 | — |
| `EOT_SEQUENCE_AFTER_DIALOGUE` | 9 | — | 对话后序列 | — |
| **`EOT_ACTIVE_TELEPORT`** | **9** | — | **主动传送** | — |
| `EOT_SLEEP` | 8 | — | **睡觉 / 等待** | 等待塔吉多完成测评、等待电梯抵达临时收容层 |
| `EOT_CLONE_COMPLETED` | 7 | — | 完成副本 | — |
| `EOT_SELFIE_CAPTURED` | 7 | — | **拍照** | — |
| `EOT_TYCOON_LEVEL` | 7 | — | 都市大亨等级 | — |
| `EOT_DIVINATION_LEVEL` | 7 | — | 占卜等级 | — |
| `EOT_ROLE_LEVEL` | 6 | — | 角色等级 | — |
| `EOT_VISION_COMPLETED` | 6 | — | 视觉完成 | — |
| `EOT_DRUM_SONG` | 5 | — | 打鼓/演奏 | — |
| `EOT_LIKEABILITY_LEVEL` | 4 | — | 好感度等级 | — |
| `EOT_PUKALAND_MINIGAME` | 3 | — | 噗卡乐园小游戏 | — |
| `EOT_RACE_PVE` | 3 | — | **赛车** | — |
| `EOT_ABYSS_COMPLETED` | 3 | — | 深渊完成 | — |
| 其余零散 | 各 1-2 | — | 接单、买车、开店、买房、购物、赛果、送礼、签到、雇员工、上菜、收益、抽装备、追目标 | — |

### 6.2 面板文字的动词分布（【本机】1372 条精确文本）

| 动词前缀 | 数量 | 样例 |
|---|---|---|
| 前往… | **217** | 前往影棚区域 / 前往花粉飘来的方向 / 前往离伊波恩最近的药店 / 前往浮冰影院赴约 |
| 与… | 208 | 与雪人小帕交谈 / 与黑羽对话 / 与伊洛伊会合 / 与哈尼娅和伊里卡对话 |
| 跟随… | 65 | — |
| 查看… | 46 | — |
| 击败… | 40 | 击败虚假的「贝拉」/ 击败暴走族首领 |
| 寻找… | 37 | — |
| 调查… | 34 | 调查大门 / 调查书架 / 调查房间里的木偶 |
| 向… | 32 | 向眼前之人对话 |
| 进入… | 32 | 进入夏成豆腐店 / 进入隧道 / 进入黑棺木大门 / 进入「画框」之中 |
| 和… | 31 | — |
| 离开… | 18 | — |
| 找到… | 13 | — |
| 完成… | 13 | — |
| 等待… | 12 | 等待塔吉多完成测评。/ 等待房间升起 |
| 聆听… | 9 | 聆听奈丽的介绍 |
| 查看… | 7 | — |
| 搭乘… | 4 | **搭乘升降机 / 搭乘电梯前往上晴塔天台 / 搭乘九原的车 / 搭乘电梯** |
| 使用… | 4 | 使用万花筒观察 / 使用「灵魂提取器」/ 使用电梯 |
| 抵达… | 3 | 抵达漫画家的住所 / 抵达镇子 / 抵达空间尽头 |
| 收集… | 2 | 收集辉环 / 收集浮毛 |
| 其他 | 519 | — |

> **你问的「搭乘电梯」确认存在**：`搭乘电梯`（exact，坐标 `(30757, 65971, 6258)`，出自 `DT_QuestLegend.json`，类型 `EOT_ARRIVE_AREA`），还有「搭乘升降机」「搭乘电梯前往上晴塔天台」「搭乘九原的车」等变体。

### 6.3 目标的可选性

**【解包】** 每个目标有 `Optional` 字段（是否可选目标）、`Amount`（数量要求）、`NeedShowProgress`（是否显示进度）、`bHideTrackIndicatorInFightState`（战斗中隐藏追踪指示器）。

---

## 7. 跨地图移动

### 7.1 任务是否跨大地图 —— 是

**【解包】** 统计 4518 个任务行：

| 指标 | 数量 | 说明 |
|---|---|---|
| `bNeedCrossBox = true`（任务级） | **78** | 需要跨「盒」（跨区域/跨地图）的任务 |
| `TrackInfo.bNeedCrossBox = true`（目标级） | **147** | 目标级的跨盒需求 |

**任务追踪地图（`TrackMapName`）分布 TOP**：

| 地图 | 任务数 | 说明 |
|---|---|---|
| `XL_map_bigworld_test` | **2256** | **海特洛市大世界（主战场）** |
| `None` | 394 + 359 | 无追踪地图（多为日常/系统任务） |
| `DLC_WuChao` | 300 | 雾巢（DLC 副本地图） |
| **`Maps_4N`** | **276** | **沃伦大陆（第二块大陆）** |
| `DLC_DeadNumber` | 171 | 空号 |
| `DLC_SpiralDreams` | 154 | 游梦洄廊 |
| `DLC_Hotel` | 146 | 旅馆 |
| `DLC_HeiYu` | 103 | 黑羽 |
| `DLC_DunnerHouse` | 78 | — |
| `DLC_FilmOrbit_map_WP` | 52 | 影棚 |
| `DLC_Museum_Lamp_Story2` | 46 | 博物馆 |
| `DLC_Hockshop` | 36 | 当铺 |
| `DLC_Museum_Lamp` | 32 | — |
| `Testmap_liuyang` | 24 | 测试图（委托用） |

### 7.2 地图级别全清单（跨图传送的目标）

**【解包】** `DT_TransferDataTable.json` 共 **695 个传送转移点**，`BelongLevelName` 分布揭示**游戏实际有多少张独立地图**：

| 地图级别 | 转移点数 |
|---|---|
| `XL_map_bigworld_test` | 361 |
| **`Maps_4N`** | **112** |
| `DLC_WuChao` | 42 |
| `DLC_SpiralDreams` | 35 |
| `DLC_Hospital_FB` | 18 |
| `DLC_Museum_Lamp_Story2` | 17 |
| `DLC_Hotel` | 12 |
| `DLC_HeiYu` | 12 |
| `DLC_FilmOrbit_map_WP` | 11 |
| `Testmap_liuyang` | 10 |
| `DLC_Bank_Safety` | 10 |
| `DLC_Hockshop` | 8 |
| `DLC_Museum_Lamp` | 7 |
| 其余（含 `DLC_Castle_Demo`、`DLC_School_boss01_WP`、`DLC_DunnerHouse`、`DLC_WuChao_Art`、`DLC_DeadNumber`、`DLC_MoonDog`、`FilmOrbit_map_WP_World`、`DLC_hotel_Paimaihui` 等） | 各 1-6 |

> **结论：至少 29 张独立地图级别**。主线剧情经常把玩家送入 DLC 副本图（雾巢、空号、游梦洄廊、影棚、博物馆、旅馆等），做完再回大世界。**这就是「跨大地图」的主要形式**。

**【解包】** `QuestSpawnPointOverrideTable.json` 共 **90 行**，定义任务开始时把玩家**强制放置到指定位置**，例如：
```
q110004: BeginQuestID=q110004, EndQuestID=q110005,
         SpawnLocation={X: 4001.03, Y: 272106.1, Z: 7752.925}
K110009: BeginQuestID=K110009, EndQuestID=K110011,
         SpawnLocation={X: -38051.0, Y: 28299.2, Z: 7704.7}
```
> 这是**任务驱动的强制位置转移**——接任务时玩家被瞬移到指定坐标，不需要自己跑。

### 7.3 交通方式

**【解包】** 传送转移点字段揭示交通能力：
- `TransferWithVehicle`（是否带载具一起传送）
- `bKeepVehicelVelocity`（是否保留载具速度）
- `bKeepPlayerRotation`（是否保留朝向）
- `bEnableTeamTransferOffset` / `TeamTransferOffsets`（队伍成员传送偏移）
- `TransformLoadingData`（传送过场：`FadeInOutEffect`、`TransferLoading`、过场媒体 `LoadingPlayMediaIDs`）

**【本机】** 载具相关（`MaaNTE` 与解包）：
- 游戏内载具系统（`DT_Vehicle*`、载具改装、载具拆除施工区建筑）
- **出租车**（同城派送 / Swift Travel）
- 赛车（`EOT_RACE_PVE`、`EOT_RACING_RESULT`、`驾校方程式` 地点名）
- 桥 / 隧道（提卡尔大桥、艾利塔斯桥、鸢尾大桥、鹦鹉螺隧道）——**大地图连通靠桥和隧道**

**【网络】** 载具：game8 有 Best Vehicles Tier List 与 How to Unlock the Blue Flame Bike。
来源：https://game8.co/games/Neverness-to-Everness/archives/598042 、 https://game8.co/games/Neverness-to-Everness/archives/597650

**【网络】** 传送点三方式（维特海默塔 / 电话亭 / 异象界域+幽灵列车站）——见 §3.5。
来源：https://game8.co/games/Neverness-to-Everness/archives/596709

---

## 8. 给 AI 助手的实践结论

1. **任务面板 OCR → 坐标** 这条链路是**已验证可行**的：本机 `quest_index.json` 已有 1372 条精确文本 → 2938 条带坐标目标，9 条真实面板文字全部唯一命中。
2. **必须剔除提示行**「V 按下进行追踪」，否则 OCR 拼接会污染查询。
3. **两套坐标绝不能混**：任务索引是世界坐标（UE5 厘米），地图渲染是 13056 像素。
4. **追踪优先级**：`EQT_EVERYDAY`（日常）不可追踪、不该导航；`bCanTrack=false` 的类型要跳过。
5. **短查询要判存疑**：「对话」有 364 个候选，不能当作匹配成功。
6. **跨图判断**：`bNeedCrossBox=true`（78 个任务 / 147 个目标）意味着需要先传送/切图，不能直线寻路。
7. **传送点选择**：`map_locator.py` 的 `TELEPORT_DISTANCE = 320`（地图像素）是「过远则传送」的既有阈值参考。
8. **任务强制位移**：`QuestSpawnPointOverrideTable` 里 90 个任务会在开始时瞬移玩家，AI 助手不该在这类任务里尝试寻路。

---

## 9. 明确「未找到」的项

| 项目 | 状态 |
|---|---|
| 「卡布罗集市」 | **未找到**；实为「**斯卡布罗集市**」（Scarborough Fair） |
| 游戏内自动寻路（点一下自动走过去） | **未找到**任何证据 |
| 任务追踪标记的具体视觉形态 | **未找到**（只找到战斗锁定的「白色小菱形」） |
| 中文社区攻略（gamekee / biligame / 米游社 / NGA / TapTap） | **未获取到**（JS 渲染 / 404 / Cloudflare 拦截） |
| 地图总面积的官方数字（平方公里） | **未找到**（只知地图纹理 13056×13056 像素、世界坐标量级 ±1e6 厘米） |
| 「异象管理局」的具体位置坐标 | **未找到**（仅确认它是地点分组标题；「G-接待大厅」可能是其内部区域，但无直接证据） |

---

## 10. 来源汇总

### 网络来源（可点击）
- 官网《异环》：https://yh.wanmei.com/index.html
- game8 全部主线任务（Episodes）：https://game8.co/games/Neverness-to-Everness/archives/592065
- game8 全部支线任务：https://game8.co/games/Neverness-to-Everness/archives/596554
- game8 全部异象委托（38 普通 + 12 高危）：https://game8.co/games/Neverness-to-Everness/archives/592066
- game8 异象界域列表：https://game8.co/games/Neverness-to-Everness/archives/597887
- game8 如何快速旅行（维特海默塔/电话亭）：https://game8.co/games/Neverness-to-Everness/archives/596709
- game8 每日必做：https://game8.co/games/Neverness-to-Everness/archives/596514
- game8 出租车玩法 Swift Travel：https://game8.co/games/Neverness-to-Everness/archives/597477
- game8 战斗锁定目标：https://game8.co/games/Neverness-to-Everness/archives/597615
- game8 交互地图：https://game8.co/games/Neverness-to-Everness/archives/597306
- game8 Duskmoor 100% 完成度（含传送点分类）：https://game8.co/games/Neverness-to-Everness/archives/604643
- game8 沃伦大陆 100%：https://game8.co/games/Neverness-to-Everness/archives/609015
- game8 载具排行：https://game8.co/games/Neverness-to-Everness/archives/598042
- interactivemap 区域 API：https://interactivemap.app/neverness-to-everness/maps/imapp/api/map_areas/1
- interactivemap 地图页：https://interactivemap.app/neverness-to-everness/maps/nte

### 本机来源（文件路径，相对 `/Users/dupi/Desktop/自动驾驶系统/`）
- `tools/nte_datatables/DataTable/DT_QuestTypeDetailData.json` — 任务类型定义
- `tools/nte_datatables/DataTable/DT_QuestChapter.json` — 223 个章节
- `tools/nte_datatables/DataTable/DT_QuestSystem.json` — 猎人等级突破
- `tools/nte_datatables/DataTable/DT_AreaDataTable.json` / `DT_MiniMapArea.json` — 区域表
- `tools/nte_datatables/DataTable/DT_City.json` — 主城
- `tools/nte_datatables/DataTable/DT_QuestDisplayMapNameDetail.json` — 85 个地名
- `tools/nte_datatables/DataTable/DT_TeleportPoint.json` — 124 个传送点
- `tools/nte_datatables/DataTable/DT_TransferDataTable.json` — 695 个跨图传送
- `tools/nte_datatables/DataTable/QuestSpawnPointOverrideTable.json` — 90 个任务强制位移
- `tools/nte_datatables/DataTable/DT_TakeOrderQuestDataTable.json` — 126 个委托
- `tools/nte_datatables/DataTable/DT_ConstructionSiteQuest.json` — 44 个工地委托
- `tools/nte_datatables/DataTable/DT_QuestEveryDay.json` — 8 个日常
- `tools/nte_datatables/DataTable/DT_QuestLiking_LJ.json` — 含「与路边着急的研究员对话」原文
- `tools/quest/build_quest_index.py` / `tools/quest/quest_matcher.py` — 索引构建与匹配
- `models/quest_index.json` — 1372 精确文本 → 2938 带坐标目标
- `models/map_locations.json` — 1777 个地点（含世界坐标 + 地图像素）
- `models/nteguide_map-core.json` — 第三方地图区域定义
- `Sources/AuroraDrive/Inference/QuestPanelReader.swift` — 任务面板 OCR 链路（1160 行）
- `verify/REPORT-task-3.md` — 独立验证报告（9 条面板文字 + 坐标）
- `MaaNTE/assets/resource/base/map_teleport/teleport_points.json` — 实传送点配置
- `MaaNTE/assets/resource/base/map_teleport/check_points.json` — 传送阈值
- `MaaNTE/agent/custom/action/Navi/map_locator.py` — 地图定位（11264/13056）
- `MaaNTE/agent/custom/action/Navi/nte_coordinate_api.py` — UE5 坐标解码
- `MaaNTE/assets/resource/base/pipeline/Interface/Scene/Status.json` — 场景状态定义
