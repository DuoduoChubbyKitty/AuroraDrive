# 《异环》(NTE / Neverness to Everness) 社区术语·玩家黑话·常见问题 调研报告

> 调研代理 #6 · 主题：社区术语、玩家黑话与常见问题
> 调研时间：2026-10-06 ~ 2026-10-07（北京时间）
> 游戏版本基线：1.4（部分资料含 1.5 / 1.6 前瞻）

---

## 0. 方法与可信度分级（先读这段）

### 0.1 数据来源与采集方式

| 来源类型 | 具体渠道 | 采集方式 | 可靠性 |
|---|---|---|---|
| 官方游戏数据表 | 本地 `tools/nte_datatables/`（来源标注 `Waifus-Grace/NTE_Assets, tagged 1.4.5`） | 直接读取 JSON | ★★★★★ 官方原文 |
| 官方站点 | `yh.wanmei.com` 官网 | 直接抓取 | ★★★★★ |
| 官方索引 | 本地 `models/nteguide_search-index.json`（抓自 nteguide.com） | 直接读取 | ★★★★☆ |
| 玩家视频标题/简介 | B站搜索 API `api.bilibili.com/x/web-interface/search/all/v2` | API 抓取 | ★★★★☆ 真实玩家用语 |
| 玩家弹幕 | B站弹幕池 `api.bilibili.com/x/v1/dm/list.so` | API 抓取 | ★★★★★ 未经修饰的真实口语 |
| 玩家评论 | B站评论 API `/x/v2/reply` | API 抓取 | ★★★★☆ |
| 玩家专栏 | B站专栏搜索 API | API 抓取 | ★★★★☆ |
| 官方 Discord | `discord.com/api/v9/invites/nte` | API 校验 | ★★★★★ |

### 0.2 可信度分级标记（全文通用）

- **【官方原文】**：直接来自游戏数据表或官网，逐字可查。
- **【交叉验证】**：≥2 个独立来源（如弹幕 + 评论 + 视频标题）指向同一结论。
- **【单源】**：仅 1 个来源，可能是个别玩家的叫法，**未必是社区通用**。
- **【推测】**：基于证据的推断，**明确标注，不可当事实用**。
- **【未找到】**：本轮调研确实没挖到，**不编造**。

### 0.3 采集环境限制（影响结论完整性，务必知悉）

本轮以下渠道**无法访问**，相关结论存在盲区：

| 渠道 | 状态 | 说明 |
|---|---|---|
| NGA 论坛 (`bbs.nga.cn` / `nga.178.com`) | **403 拒绝** | 任务点名要求，但服务器对非浏览器请求返回 403；换 UA、换移动端 UA 均失败。**NGA 板块内容本轮未获取** |
| 百度贴吧 (`tieba.baidu.com`) | **403 拒绝** | 同上 |
| Reddit (`reddit.com/r/NevernessToEverness`) | **403 / 需登录** | `.json` 端点与 HTML 均被 Reddit 网络策略拦截；镜像站被 Anubis 反爬挡下 |
| 米游社 | 不适用 | 《异环》是完美世界 / Hotta Studio 产品，**不是米哈游游戏**，因此米游社没有异环专区（详见 §6.3） |
| 萌娘百科 / 百度百科 | **403 拒绝** | 未能获取 |
| `web_search` 内置工具 | **HTTP 429 限流** | 全程不可用；改用 Bing RSS / B站 API / 直接抓取替代 |
| Google / Bing 网页搜索 | 结果被中文字典释义污染 | 中文关键词如「异环 黑话」被搜索引擎拆成「异」字查询，返回大量汉语字典结果，**基本无效**。真正有效的是 B站 API |

> ⚠️ 因此本报告的黑话证据**以 B站生态（视频/弹幕/评论/专栏）为主干**。NGA、贴吧、Reddit 的社区用语本轮**未被覆盖**，属于已知盲区。

---

## 1. 玩家对游戏的昵称

### 1.1 官方名称与英文缩写

| 称呼 | 性质 | 来源 |
|---|---|---|
| **《异环》** | 官方中文名 | 【官方原文】[官网首页](https://yh.wanmei.com/index.html) |
| **Neverness to Everness** | 官方英文全名 | 【官方原文】[官网](https://yh.wanmei.com/index.html)、[NTE Global Official Discord](https://discord.gg/nte) |
| **NTE** | 英文缩写，**全球社区与官方 Discord 均使用** | 【官方原文】官方 Discord 服务器名即 `NTE Global Official`，邀请码 `discord.gg/nte`，描述："Official server of NTE (Neverness to Everness), a supernatural urban open-world RPG developed by Hotta Studio."（经 `discord.com/api/v9/invites/nte` 校验通过） |
| **异环** | 简体 | 【官方原文】 |
| **異環** | 繁体（台港澳服） | 【官方原文】MaaNTE 提供 `docs/README_zh-tw.md` 繁中版；OCR 资源含 `zh_tw` 语言包 |

### 1.2 玩家口语昵称

| 称呼 | 证据 | 可信度 |
|---|---|---|
| **牢环** | B站视频标题：「孩子们，**牢环**这是在干什么」 https://www.bilibili.com/video/BV1sPHs6AE65 | 【单源】"牢X"是中文二游社区通用贬称前缀（源自"牢大"梗），此处指游戏本体 |
| **异环**（直接用，不带书名号） | 绝大多数玩家口语与标题直接写"异环" | 【交叉验证】全站视频标题普遍如此 |
| **环**（简称，如"入坑环""这环"） | 见「环压抑」等二创标题：「【**环**压抑】塔吉多角色PV」 https://www.bilibili.com/video/BV18t94B4ECe | 【单源】"环压抑"是仿"原压抑/崩压抑"的二游社区梗句式 |

### 1.3 游戏内世界/组织名词（AI 需要认识，玩家会直接用）

| 名词 | 含义 | 来源 |
|---|---|---|
| **海特洛市** | 游戏主城 | 【官方原文】[官网](https://yh.wanmei.com/index.html)："故事将从海特洛市启篇" |
| **异象猎人** | 玩家身份（"无证上岗"的异象猎人） | 【官方原文】[官网](https://yh.wanmei.com/index.html) |
| **鉴定师** | **NPC 对玩家的固定称呼**，全游戏语音/任务文本大量使用 | 【官方原文】`DT_VoiceMsg.json`、`DT_IntroduceVoiceMsg.json` 中 `鉴定师` 出现 52+ 次 |
| **伊波恩** | 玩家所属古董店名，NPC 也用它代指主角团 | 【官方原文】[官网](https://yh.wanmei.com/index.html)；`DT_VoiceMsg.json` 有 `「伊波恩」店长`、`「伊波恩」成员` 词条 |
| **异象委托** | 主要任务类型 | 【官方原文】`DT_Description.json` 等，出现 82 次 |
| **收容** | 处理异象的官方说法 | 【官方原文】`DT_AchievementConfigInfo.json` 等，出现 119 次 |
| **歧骸** | 敌对怪物统称 | 【官方原文】`DT_IntroduceVoiceMsg.json`："原来是歧骸……""有伴生的歧骸。" |
| **呗果 (Bagel)** | 游戏内社交平台（影射微博/小红书），玩家会说"发呗果""呗果成瘾" | 【官方原文】`DT_LoadingConfig.json`：「呗果」其一/其二；`DT_AchievementConfigInfo.json`："在「呗果」中累计获得5万个「过奖果酱」"、"呗果红人" |
| **塔吉多 (Taygedo/Tayge)** | 游戏内吉祥物/角色，**同时是官方社区 App 的名字** | 【官方原文】`DT_VoiceMsg.json`："快拍下来发呗果上去！"；B站：「异环社区**塔吉多**首曝！」https://www.bilibili.com/video/BV1AuyhY5Ef8 |

---

## 2. 角色黑话 / 外号

### 2.1 官方角色全表（AI 必须能对上号）

来源：【官方原文】本地 `models/nteguide_search-index.json`（抓自 nteguide.com），共 45 个中文角色词条。

```
娜娜莉 Nanally (anima/S/attack)      咲里 Sakiri (incantation/S/support)
法蒂亚 Fadia (psyche/S/attack)       安魂曲 Lacrimosa (chaos/S/attack)
白藏 Baicang (incantation/S/defense) 零（男/女）Zero (cosmos/S/attack)
穗鸟 Hotori (cosmos/S/buff)          达芙迪尔 Daffodil (chaos/S/attack)
九原 Jiuyuan (anima/S/utility)       哈尼尔 Haniel (psyche/A/support)
阿德勒 Adler (incantation/A/attack)  翳 Skia (lakshana/A/attack)
埃德加 Edgar (cosmos/A/support)      薄荷 Mint (anima/A/support)
奈莉 Nelly (anima/A/support)         梅露拉 Merula (lakshana/A/attack)
阿尔法德 Alphard (lakshana/A/tbd)    泰格多 Taygedo (cosmos/A/support)
哈索尔 Hathor (lakshana/S/attack)    赤子 Chiz (cosmos/S/attack)
莉莉娜 Lilina (cosmos/S/tbd)         凛子 Lingko (incantation/A/attack)
密斯莫 Mismo (chaos/A/support)       沁红 Shinku (anima/A/attack)
尼察 Nitsa (psyche/A/support)        黑鸟 Black Bird (chaos/S/attack)
明虎 Xiaozhen (anima/S/attack)       赤音 Akane (incantation/S/attack)
詹森 Jenson (psyche/A/defense)       伊洛伊 Illica (lakshana/S/support)
风花 Fuuka (anima/A/support)         克劳 Crow (chaos/S/dps)
蕾妮 Renee (psyche/A/support)        吾郎 Goro (incantation/A/dps)
玛丽娜 Marina (cosmos/S/dps)         海斗 Kaito (lakshana/A/dps)
希尔菲 Sylphy (anima/S/support)      奥蕾莉亚 Aurelia (psyche/A/support)
小吱 Xiaozhi (anima/S/attack)        浔 Xun (cosmos/S/support)
卡厄斯 Chaos (lakshana/S/attack)     真红 Zhenhong (light/S/attack)
残虹 Canhong (curse/S/attack)        妮夏 Nixia (cosmos/S/support)
```

**注意译名差异**：本地数据表（`DataTable`，游戏内文本）与 nteguide 索引存在不一致：
- 数据表用 **达芙蒂尔**（214 次），nteguide 索引写 **达芙迪尔**；本地角色图资源文件名是 `Daffodill.png`。
- 数据表用 **埃德嘉**（`DT_IntroduceVoiceMsg_MU0105.json` 有独立条目"埃德嘉"），nteguide 索引写 **埃德加**。
- 数据表有 **咲里**？→ 本地数据表 `咲里` 出现 **0** 次，但 MaaNTE 角色图资源有 `Sakiri.png`，nteguide 索引有「咲里」。说明本地数据表版本（1.4.5）与 nteguide 索引版本不同步。
- 玩家口语中 **妮夏** 常写作 **尼夏**（见 MaaNTE 任务文本"1娜娜莉2任意位3早雾4狼（没有娜娜莉可换埃德加）"附近文案）。

> 💡 **给 AI 的建议**：角色名做**模糊匹配 + 别名表**，不要精确字符串匹配。

### 2.2 角色外号表（分可信度）

#### A. 【交叉验证】高置信度外号

| 外号 | 指谁 | 证据 |
|---|---|---|
| **吱本家** | **小吱** | ①弹幕："？不因该是**吱本家**吗"（BV1cLEQ6fEAx）②评论："小吱不是叫**吱本家**吗？"（同视频，32赞）③独立视频标题：「【异环】小吱的真面目：**吱本家**」https://www.bilibili.com/video/BV119EH6nEYN ④「被**吱本家**做局了」https://www.bilibili.com/video/BV1CGam6HETn ⑤「不要做局了啊坏蛋小吱!(可恶的**吱本家**)」https://www.bilibili.com/video/BV1aP3v62E8G |
| **狗哥** | **翳 (Skia)** | ①弹幕："我一般直接叫**狗哥**。"（BV16XKD6hEeZ）②独立视频：「【异环】翳基础角色攻略：认真尽责的**大狼狗**副队长…」https://www.bilibili.com/video/BV1AQ5L69EKi ③「**狗哥**挂延滞buff疑似已经修复，**大狗叫**时代又回来了」https://www.bilibili.com/video/BV1qDaz6WEgM ④「**狗哥**60级，点完了被动」https://www.bilibili.com/video/BV1WKH46zE63 |
| **牢大** | **娜娜莉** | ①弹幕："不是**牢大**？""**牢大**"（BV16XKD6hEeZ，两条）②视频标题：「加强**牢大**娜娜莉，0+1越来越坚持不下去了」https://www.bilibili.com/video/BV1hYa16FEj7（标题同时出现外号与真名，直接坐实）③「**牢大**依旧是版本T0！」https://www.bilibili.com/video/BV1omHt68EcN ④弹幕"**老大**至今依旧植物人"（BV1cLEQ6fEAx） |
| **这这躺 / 这这莉** | **娜娜莉** | ①弹幕："**这这躺**""不是**这这躺**？""不是这**这这躺**？""**这这莉**"（BV16XKD6hEeZ，多条）②评论："娜娜莉现在不都叫**这这躺**吗[doge]"（78赞）③「厚荷！**这这莉**？异环角色羁绊奖励真的笑死我了」https://www.bilibili.com/video/BV1PDREBYEST |
| **草莓牛奶** | **安魂曲** | ①评论："薄荷说过 **安魂曲是草莓牛奶**"（194赞）②评论："温馨提示：**安魂曲**在薄荷那里的味道是**草莓牛奶**哦"（47赞）③视频主题即"薄荷是按角色身上的味道来起外号的" https://www.bilibili.com/video/BV1gku86bEmu |
| **娜娜虎** | **娜娜莉** | ①【官方原文】`DT_QuestMain_wzy.json` 30 处："追赶**娜娜虎**离开房间"、"继续追赶**娜娜虎**"；`DT_IntroduceVoiceMsg.json`："娜娜莉！呃，**娜娜虎**？""**娜娜虎**！喂！等等！" ②【官方原文】`DT_StorySequenceData.json`："你追赶**娜娜虎**" |
| **虎老大** | **娜娜莉**（游戏内称呼） | 【官方原文】`DT_QuestMain_wzy.json` 5 处："「**虎老大**」请求你，带走「真正的娜娜莉」。"；`DT_IntroduceVoiceMsg.json` 16 处 |
| **小娜娜莉** | 娜娜莉（剧情形态） | 【官方原文】`DT_IntroduceVoiceMsg.json` 词条名 `小娜娜莉` |
| **水母姐 / 水母** | **海月** | ①弹幕："**海月**是**水母姐**""**水母**"（BV1cLEQ6fEAx）②独立视频：「**海月**的腿和**水母**等，这里带大家走进海月的经历」https://www.bilibili.com/video/BV1Ap5Y6qEr9 |
| **御姐** | **早雾** | ①评论："早雾外号不是**御姐**吗[doge]"（22赞）②「【异环】我曹！海特洛第一**御姐**皮肤展示！**早雾**皮肤竟然是凉鞋！」https://www.bilibili.com/video/BV1Loeg6yETc ③「异环第一**御姐**早雾皮肤爆料」https://www.bilibili.com/video/BV1sce26ZEwW |

#### B. 【单源】中置信度外号（可能是个别玩家叫法）

| 外号 | 指谁 | 证据 |
|---|---|---|
| **嘉欣** | **娜娜莉** | 视频标题：「这就是为什么**娜娜莉外号嘉欣**」https://www.bilibili.com/video/BV1ZhdKBDE8L（636 播放）。⚠️ **视频正文未能获取**，"嘉欣"的来源（疑似某真人/角色撞脸梗）**未确认**，仅标题可证 |
| **半拉耄耋** | **娜娜莉**（调侃强度下滑） | 弹幕："不是～**半拉耄耋**吗"（BV16XKD6hEeZ）；视频标题：「牢大，你怎么似了，我的娜娜莉变成**半拉耄耋**了」https://www.bilibili.com/video/BV1uFVp6UE9b |
| **狗人 / 狗狗人** | **翳**（"狗狗人，辛苦！"是官方台词） | 【官方原文】`DT_IntroduceVoiceMsg.json`："（**狗狗人**，辛苦！）"；弹幕："**狗狗人**"（BV1cLEQ6fEAx） |
| **野猫** | 某角色（弹幕语境为角色外号来源讨论） | 弹幕："**野猫**"（BV16XKD6hEeZ）。**指谁未确认** |
| **混子** | 某角色 | 弹幕："**混子**"（BV1cLEQ6fEAx）。**指谁未确认** |
| **向日葵** | 某角色 | 弹幕："**向日葵**"（BV1cLEQ6fEAx）。**指谁未确认** |
| **老糖人** | **哈尼娅** | 评论："哈妮娅我叫他**老糖人**"（BV1ZW3961E8u，0赞）——**极可能是个人叫法，非社区通用** |
| **男娘** | 某角色 | 弹幕："**男娘**在哪？"（BV1cLEQ6fEAx）。**指谁未确认** |
| **这这** | 娜娜莉（"这这躺"的简写） | 见上 |

#### C. 薄荷的"味道外号"体系（社区知名梗）

**证据**：视频「既然薄荷是按角色身上的味道来起外号的，也就是说…」https://www.bilibili.com/video/BV1gku86bEmu（21,224 播放）+ 评论区（194/52/47 赞）。

- 已确认：**安魂曲 = 草莓牛奶**（多源交叉验证）。
- 【未找到】其余角色的"味道"对照表本轮未挖到完整版。搜索"薄荷 外号 味道"未返回系统性清单。

#### D. 【未找到】的角色外号

以下角色本轮**未挖到**社区通用外号，不编造：咲里、法蒂亚、白藏、穗鸟、达芙蒂尔、九原、哈尼尔、阿德勒、埃德加、奈莉、梅露拉、阿尔法德、哈索尔、赤子、莉莉娜、凛子、密斯莫、沁红、尼察、黑鸟、明虎、赤音、詹森、伊洛伊、风花、克劳、蕾妮、吾郎、玛丽娜、海斗、希尔菲、奥蕾莉亚、浔、卡厄斯、真红、残虹、妮夏、零。

> 注：有 UP 主做过系统性盘点，但**视频内容（非标题）无法通过 API 获取**，故正文外号未能提取：
> - 「异环角色都有哪些外号」https://www.bilibili.com/video/BV1cLEQ6fEAx
> - 「异环五大外号来源」https://www.bilibili.com/video/BV16XKD6hEeZ
> - 「异环给角色起外号」https://www.bilibili.com/video/BV1ZW3961E8u
> - 「一天到晚的，伊洛伊都给真红起了多少个外号」https://www.bilibili.com/video/BV1vVTX6fEcq
>
> 💡 **后续建议**：这三条视频的**弹幕/评论**是本主题最富矿，值得用视频转写（ASR）深挖。

---

## 3. 玩法黑话 / 术语

### 3.1 货币与资源

| 黑话 | 官方名 | 说明与证据 |
|---|---|---|
| **方斯** | 方斯 | 主货币。【官方原文】数据表出现 50 次。玩家口语："1.4零氪能领209抽、**1688万方斯**！" https://www.bilibili.com/video/BV1ZApw6tEPM ；"教你用bug轻松**日入上亿方斯**" https://www.bilibili.com/video/BV1bCYY6ZExp |
| **甲硬币** | 甲硬币 | 角色养成货币，**社区公认最紧缺资源**。【官方原文】数据表出现 8 次。玩家："异环现在一直在吵资源紧缺，非常缺**甲硬币**，一个角色就需要100多万**甲硬币**？但其实一个角色到80级就需要**400万甲硬币**" https://www.bilibili.com/read/cv49056324 |
| **环石** | 环石 (Annulith) | 抽卡货币。【官方原文】`DT_OutputDetailSource.json`："**环石**加工" / "Annulith P..."。玩家："合计320**环石**" https://www.bilibili.com/video/BV1QqaP6LEGi |
| **抽**（单位） | — | 玩家用"抽"计资源，如"1.4零氪能领**209抽**"、"白嫖**120抽**" https://www.bilibili.com/video/BV1NCeA6gEXr |

### 3.2 装备与养成系统（**官方名 ↔ 玩家叫法**）

| 官方术语 | 玩家怎么说 | 来源 |
|---|---|---|
| **弧盘** | 弧盘（武器位）。玩家："3个免费自选S级…"、"**角色弧盘**优先级详解" https://www.bilibili.com/video/BV1hHaE6XEux | 【官方原文】数据表 42 次 |
| **空幕** | 空幕（圣遗物/驱动块位）。玩家："技能空幕"、"将1个橙色品质的空幕「驱动块」的等级提升至10级" | 【官方原文】数据表 13 次 |
| **觉醒** | **玩家常类比为"命座"**（沿用原神/鸣潮说法）。视频："**黑羽命座和觉醒效果推荐**！" https://www.bilibili.com/video/BV1ypaH6UEnX ；"抽几**命**合适？" https://www.bilibili.com/video/BV1v1ac6VEbF ；"**3觉6觉**有没有必要？" https://www.bilibili.com/video/BV1Ux8S6YEvr | 【官方原文】数据表 15 次；"命座"在异环数据表中 **0 次**（说明是外来词） |
| **特技** | 特技 | 【官方原文】数据表 5 次 |
| **羁遇** | 羁遇（好感系统官方名）。玩家也会说"**好感度**" | 【官方原文】`DT_QuestTypeDetailData.json`："**羁遇** / Bond"；`DT_AchievementConfigInfo.json`："小吱的**好感度**达到5级" |
| **专武** | 玩家用"专武"指专属弧盘（外来词）。"要不要抽**专武**？" https://www.bilibili.com/video/BV1v1ac6VEbF | 【单源】数据表无"专武" |

### 3.3 战斗机制术语

| 术语 | 含义 | 来源 |
|---|---|---|
| **环合 / 环合反应** | 核心战斗机制，共 **8 种**：**创生 / 覆纹 / 浊燃 / 黯星 / 浸染 / 延滞 / 盈蓄 / 失谐** | 【官方原文】`DT_AchievementConfigInfo.json`："累计触发「创生」环合10次"等 8 条成就；B站详解视频 https://www.bilibili.com/video/BV1nXoSBJESD（24万播放） |
| **倾陷** | 一种敌人异常状态 | 【官方原文】`DT_FT_Item.json`："在战斗中，累计使敌人进入「**倾陷**」状态5次" |
| **拐力 / 拐** | 二游通用黑话：**增益能力**（"拐"=buff 位）。新手直接提问："想问一下**拐力**是什么意思"（BV1SaRxBZE77 评论） | 【交叉验证】B站评论 + 通用二游术语 |
| **调弧** | 玩家提问用词："请问**调弧**是什么意思啊，就是娜娜莉那个像地球的技能"（BV1SaRxBZE77 评论） | 【单源】疑似"调律弧光"之类技能名简称，**官方全称未确认** |
| **3+1 / 0+1 / 31 / 01** | 二游通用黑话：**觉醒等级 + 弧盘精炼等级**。如"**3+1**的一是什么意思？"（BV1SaRxBZE77 评论，玩家自己也不懂）；"**31黑羽01安魂曲**" https://www.bilibili.com/video/BV1c5H46NEtJ ；"**0+1**残虹黑羽拿满奖励" https://www.bilibili.com/video/BV1E7a36VELz | 【交叉验证】大量标题使用 |
| **满命 / 0命到满命** | 满觉醒。"【真红**0命到满命**提升\|3+1完全体】" https://www.bilibili.com/video/BV1YWTp66E12 | 【交叉验证】 |
| **主C / 副C / 奶 / 辅** | 二游通用定位 | 【交叉验证】 |
| **配队** | 队伍搭配。"【异环】各版本入坑最强**配队**推荐！" https://www.bilibili.com/video/BV1s5by6kECN | 【交叉验证】 |
| **刮痧** | 伤害极低。【官方原文】游戏内文本也有"刮痧"？→ 玩家标题："自选S级！这个千万不要选！**刮痧**没伤害！" https://www.bilibili.com/video/BV1cdobBoEGt | 【交叉验证】二游通用 |
| **延滞 buff / 挂 buff** | 上 debuff。"**狗哥挂延滞buff**疑似已经修复，大狗叫时代又回来了" https://www.bilibili.com/video/BV1qDaz6WEgM | 【交叉验证】 |
| **作业** | 抄作业=照抄别人配置/路线。"保姆级教学+3套**作业**" https://www.bilibili.com/video/BV1MHHj6UE98 | 【交叉验证】 |
| **逃课** | 跳过/绕过机制。【官方原文】游戏内文本"逃课"出现 4 次；玩家："碳团的宝藏**逃课**焚决" https://www.bilibili.com/video/BV169ao6LEjx | 【交叉验证】 |
| **焚决 / 焚诀** | **本作特有黑话**：指"极致攻略/最优解"（源自游戏内设定或社区自造，字面"焚决"）。"999夜保姆级，一条龙攻略详解。包含全部**焚决**" https://www.bilibili.com/video/BV1KZKP6rEKC ；"**焚决**，一步到位"；"全网up吹爆…"；"【异环】噗卡乐园迷宫速通终极**焚决**" https://www.bilibili.com/video/BV1thau6REuQ | 【交叉验证】多 UP 独立使用。⚠️ 游戏内数据表 `焚决` **0 次**，属社区自造词 |
| **凹**（凹分/凹层） | 反复重试刷成绩。"全站深境200层满分**代凹**" | 【交叉验证】二游通用 |
| **一条龙** | 一次性跑完全部流程。"【异环**一条龙**全收集】镜中世界的小人国" https://www.bilibili.com/video/BV1yKam6xEkt | 【交叉验证】 |
| **跟跑** | 跟着视频点位跑图。"1.4新异象解谜**跟跑**攻略" https://www.bilibili.com/video/BV1AKaw6fE2J | 【交叉验证】 |
| **一图流** | 单张图讲完的攻略。"配队/弧盘/空幕**一图流**" https://www.bilibili.com/video/BV12NRjBxEKU | 【交叉验证】 |
| **坐牢** | 活动枯燥折磨。"锐评异环全站深境 纯**坐牢**活动" https://www.bilibili.com/video/BV1peHj66EVx | 【交叉验证】 |

### 3.4 日常 / 体力 / 玩法模式

| 黑话 | 含义 | 来源 |
|---|---|---|
| **都市活力**（简称**活力**） | 都市玩法体力 | 【官方原文】`DT_AchievementConfigInfo.json`："累计消耗**都市活力**50点"；`DT_QuestLiking_LJ.json` 同 |
| **体力** | 战斗玩法体力 | 【交叉验证】玩家："体力上限可以加到360点" https://www.bilibili.com/video/BV1WTJW6sE55 |
| **清日常 / 清体力 / 每日必做** | 每日任务 | 【交叉验证】"教你快速**清完日常**实况！每天仅需5分钟下号" https://www.bilibili.com/video/BV1BRY66YES3 ；"最全最细**每日每周必做**事项" https://www.bilibili.com/video/BV1kmMJ6nEfG（18.5万播放） |
| **刮刮乐** | 玩家口中的"每日必做"（评论："每日必做：**刮刮乐**[doge]"，533赞） | 【单源】具体指哪个玩法**未确认** |
| **兔子洞** | 刷取材料的副本 | 【官方原文】`DT_OutputDetailSource.json` 词条名 `兔子洞 / Rabbit Hole`。玩家："该打**兔子洞**就打" https://www.bilibili.com/read/cv49056324 ；"刷**兔子洞**适可而止" https://www.bilibili.com/video/BV1Ad5Q6oEjY |
| **周本** | 每周副本次数 | 【官方原文】`DT_CharacterVoice.json` Remarks: "**周本**完成"。玩家："3次**周本**刷新（必刷）"（评论，175赞） |
| **异象本** | 异象材料副本 | 【官方原文】`DT_LoadingConfig.json`。玩家："**异象本**-数符系列" https://www.bilibili.com/read/cv53036978 |
| **技能本** | 技能材料副本 | 【单源】同上专栏 |
| **全站深境 / 深境** | 爬塔类高难玩法（**200层**为满分线） | 【交叉验证】"【异环】**全站深境**玩法详解，爬塔活动轻松拿满奖励" https://www.bilibili.com/video/BV1bEaq6qEtE ；"**全站深境200层**满分" https://www.bilibili.com/video/BV1c5H46NEtJ 。⚠️ 数据表 `深境` **0 次**，可能为 1.4 新增或名称有出入 |
| **轨外 / 轨外之境** | 高难关卡（"轨外10""轨外12"） | 【官方原文】`DT_QuestDisplayMapNameDetail.json`："**轨外之境**"；玩家："[异环·**轨外10**]" https://www.bilibili.com/video/BV1n9e26pEe5 ；"满星单通**轨外12**" https://www.bilibili.com/video/BV1VeTS6UEqW |
| **深渊** | 玩家把高难本类比"深渊"。"异环最新**深渊**一镜通关" https://www.bilibili.com/video/BV1o4H66aEXE ；"秒**深渊**12BOSS" https://www.bilibili.com/video/BV1DngW6VEc8 | 【交叉验证】外来类比词 |
| **粉爪 / 粉爪大劫案** | 常驻玩法（MaaNTE 支持自动刷） | 【官方原文】`DT_CityGamePlayDataTable.json`："**粉爪大劫案** / Pink Paws"；MaaNTE 任务 `PinkPawHeist` |
| **噗卡乐园 / 噗咔乐园** | 常驻玩法区（两种写法社区混用） | 【官方原文】[官网](https://yh.wanmei.com/index.html)："全新区域-**噗卡乐园**"。玩家写"**噗咔乐园**" https://www.bilibili.com/video/BV1Kkaw6NEtK |
| **一咖舍** | 咖啡店经营玩法 | 【官方原文】`DT_QuestEveryDay.json`："「**一咖舍**」收取1次方斯"；MaaNTE 有 `MakeCoffee` 任务 |
| **都市大亨** | 都市经营等级系统 | 【官方原文】`DT_OutputDetailSource.json`："**都市大亨**6级解锁"。玩家："**都市大亨**激励金"（评论，175赞） |
| **即刻落槌 / 即刻落锤** | 藏品展览玩法（社区两种写法混用） | 【交叉验证】"**即刻落槌**最新答案" https://www.bilibili.com/read/cv53187864 ；"**即刻落锤**大量更新改动速看" https://www.bilibili.com/video/BV1FBaA6oEmE |
| **藏品** | 展览玩法收集品 | 【官方原文】数据表 10 次 |
| **玛门** | 每周必做点之一 | 【官方原文】`DT_OutputDetailSource.json`："博物馆**玛门**异象—开端"；玩家评论："初始小家的**玛门**，75000方斯"（175赞） |
| **云朵** | 家具/舒适度相关资源 | 【官方原文】`DT_DateDataTable.json`；玩家评论："初始小家的**云朵**礼物" |
| **谕石** | 地图收集物 | 【官方原文】`DT_StorySequenceData.json` 出现 1 次；玩家攻略："【异环】**谕石**全收集之桥间地篇" https://www.bilibili.com/read/cv39968143 |
| **星票** | 噗卡乐园奖励票 | 【交叉验证】"速刷**星票**奖励" https://www.bilibili.com/video/BV1Kkaw6NEtK ；"噗卡**星票**快速获取攻略" https://www.bilibili.com/video/BV1oPYF6LEeq |
| **保时捷 / 911 / Taycan / 918** | 联动载具，玩家常讨论 | 【官方原文】[官网](https://yh.wanmei.com/index.html)："异环×Porsche 联动二期"。玩家："异环保时捷**918/911/Taycan**区别和抽取建议" https://www.bilibili.com/video/BV1xHac6fEz7 |
| **云·异环** | 云游戏版本 | 【交叉验证】"还不会下载《**云·异环**》？" https://www.bilibili.com/video/BV1cAVW6iEAB |
| **大转盘** | 某个坑人玩法 | 【单源】"不要碰异环**大转盘**" https://www.bilibili.com/video/BV1hza76HEYJ |

### 3.5 抽卡术语

| 黑话 | 含义 | 来源 |
|---|---|---|
| **走格子** | **本作卡池特有机制**：卡池是棋盘制，54 个普通格 + 18 个特殊格，踩到特殊格进入特殊区域 | 【交叉验证】专栏「异环 卡池模拟分析报告2.0」https://www.bilibili.com/read/cv42220878（详细描述了棋盘机制）；数据表 `走格子` 0 次 |
| **保底** | 通用。本作有"15抽保底"等说法 | 【交叉验证】"全异环最配拥有保时捷之人，**15抽保底**" https://www.bilibili.com/video/BV1bopF6CEec |
| **囤 / 囤囤鼠** | 攒资源不抽卡的玩家 | 【交叉验证】"异环对我们**囤囤鼠**玩家真是太友好了！" https://www.bilibili.com/video/BV1ucaf68EnS |
| **限定 / 常驻** | 卡池类型 | 【交叉验证】"常驻角色自选避坑" https://www.bilibili.com/video/BV1HuHf6oEfQ |
| **自选S级 / 自选箱** | 免费自选高稀有角色 | 【交叉验证】"【异环】**自选S级**！这个千万不要选！" https://www.bilibili.com/video/BV1cdobBoEGt ；"1.4新**自选箱**" https://www.bilibili.com/video/BV1hHaE6XEux |
| **卫星角色** | 已公布未实装角色 | 【交叉验证】"异环新增3位**卫星角色**！" https://www.bilibili.com/video/BV1TpeP6CE33 |
| **大保底 / 小保底** | 通用 | 【交叉验证】UP 主名"宇哲又吃**大保底**" |
| **强度榜 / T0** | 通用 | 【交叉验证】"1.4版本角色**强度榜**速览" https://www.bilibili.com/video/BV1yUaw6FEr5 ；"强度**T0**、大世界跑图T0" https://www.bilibili.com/video/BV1dsaP6WEBy |
| **跑图** | 大世界移动能力 | 【交叉验证】"大世界**跑图**T0" 同上 |
| **轮椅** | 无脑强力配置 | 【交叉验证】"1.4新手开荒必练**轮椅**-明日凛全攻略" https://www.bilibili.com/video/BV1ixaL6pEKg |
| **开服老登** | 开服玩家（自嘲） | 【交叉验证】"异环**开服老登**的萌新教学系列" https://www.bilibili.com/video/BV13HHE6tELz |
| **长草期** | 无内容可玩时期 | 【交叉验证】"第一波**长草期**体力规划分享" https://www.bilibili.com/video/BV1fc91BoEGp |
| **朋友费** | 开服赠送的抽卡资源（社区调侃） | 【单源】评论："靠开服送的**朋友费**撑起了福利神游的称号"（58赞） |
| **搬砖** | 刷资源变现/肝资源 | 【交叉验证】"异环**搬砖**实测第一天真实情况汇报" https://www.bilibili.com/video/BV1HEoYBBEVb |
| **肝** | 大量投入时间 | 【交叉验证】"【异环】最全最细每日每周必做事项" 下的玩家自称"**肝**帝"、UP 主名"二游**肝帝**" |
| **刮痧** | 见 3.3 | |
| **减负** | 官方降低肝度 | 【交叉验证】"异环1.3优化详解，粉爪**减负**" https://www.bilibili.com/video/BV1FQgn6sEog |

### 3.6 官方功能名（玩家直接用，AI 需识别）

- **环期赏令**（`DT_OutputDetailSource.json`）— 通行证/季票
- **活跃度**（`DT_Quest_Level.json`）— 每日活跃任务
- **猎人经验**（`DT_Quest_Level.json`）— 主等级经验
- **都市活力**、**大亨等级**、**探索指南**
- **超强音**（音游玩法，MaaNTE 有 `auto_rhythm` 任务）
- **一咖舍**（咖啡店经营）
- **粉爪大劫案**（劫案玩法）
- **俄罗斯方块**（MaaNTE `Tetris` 任务）
- **排球之星 / Volleyball**（MaaNTE `Volleyball`、`VolleyballWeekly`）
- **女巫占卜 / WitchDivination**（MaaNTE 任务名）
- **粉爪银行**（`DT_QuestLiking_LJ.json`："**粉爪银行**的老板乔望尼先生"）

---

## 4. 常见问题（FAQ）

### 4.1 新手最常问什么（**真实玩家原话**）

以下问题**逐字**取自 B站评论区（`/x/v2/reply` API），是最真实的"新手会怎么问"：

| 玩家原话 | 出处 | 问题类型 |
|---|---|---|
| "大佬们我前两天刚玩，能不能教下**怎么配队**，刷个怪要好久" | BV1cz3X62E7B 评论（43赞） | 配队 |
| "我看有人说就算抽卡全保底只白嫖也能**全图鉴**，是真的吗" | 同上 | 抽卡规划 |
| "可不可以教下**每天都要干什么**才能拿满白嫖奖励" | 同上 | 日常规划 |
| "现在感觉拿的**抽卡资源好少**" | 同上 | 资源 |
| "异环，鸣潮，绝区零，终末地这几个**哪个轻松点**啊，不想太在游戏里投入太多时间" | 同上（95赞） | 选游/时间成本 |
| "我不知道现在**新手入坑**什么" | 同上（58赞） | 入坑时机 |
| "我想问一下，那个**3+1的一是什么意思**？刚才我没听懂" | BV1SaRxBZE77 评论 | 术语不懂 |
| "请问**调弧**是什么意思啊，就是娜娜莉那个像地球的技能" | 同上 | 术语不懂 |
| "想问一下**拐力**是什么意思" | 同上 | 术语不懂 |
| "小吱不是叫**吱本家**吗？" | BV1cLEQ6fEAx 评论（32赞） | 外号纠错 |
| "早雾外号不是**御姐**吗" | 同上（22赞） | 外号补充 |

> 💡 **关键洞察**：新手最高频的痛点是 **①配队 ②每日该做什么 ③资源够不够 ④听不懂术语（3+1、拐力、调弧）**。第 ④ 项正是本报告存在的意义。

### 4.2 老玩家最常解答什么

来自高赞评论（可视为"社区共识答案"）：

**每周必做清单**（评论 175 赞，`BV1kmMJ6nEfG`）：
```
【1】初始小家的玛门，75000方斯（以及初始小家的云朵礼物，可以攒一周一起领一次）
【2】每周邮箱0体力消耗送货，32000方斯
【3】3次周本刷新（必刷，不论打什么都行，反正请别忘记）
【4】每周700都市活力，70w方斯（1.3后活力消耗速度再次加快，会更轻松）
【5】都市大亨激励金，平均100w/2＝50w方斯（可以粉爪…）
```

**轻松流玩法**（评论 171 赞，同视频）：
> "普通材料压根不用刷，商店兑换基本够用了…每天必须要做就是**上线收菜送礼物清体力看电影**，每周清活力玛门两周清粉爪就差不多了，这么玩进度也能玩到90%左右，主打轻松耐玩**每天5分钟搞定**"

**"每日必做：刮刮乐"**（评论 533 赞，同视频）— 社区玩梗式回答。

### 4.3 高频问题主题清单（按视频标题归纳）

| 主题 | 典型标题 | 来源 |
|---|---|---|
| **新手入门/入坑** | 「异环新手快速上手入坑攻略！萌新必看！」 | https://www.bilibili.com/video/BV1cz3X62E7B |
| **零基础全面介绍** | 「【异环入坑指南】第一期：零基础超全面内容介绍：卡池氪金介绍+发展思路+玩法演示+战斗机制」（206万播放，**本主题最高**） | https://www.bilibili.com/video/BV1UPdLBcEJy |
| **术语扫盲** | 「萌新入坑异环必看，三分钟了解异环术语」 | https://www.bilibili.com/video/BV1SaRxBZE77 |
| | 「异环【名词解释】及【战斗机制】」 | https://www.bilibili.com/video/BV1ZKoeBvESL |
| | 「异环新手必看第一期，名词解析」 | https://www.bilibili.com/video/BV1g8dnBUEU7 |
| **体力规划** | 「1-50级，体力规划最优解。角色养成副本刷取建议」 | https://www.bilibili.com/video/BV1Ug5y65Ej6 |
| | 「体力应该刷什么啊？打兔子洞还是点角色技能等级？」 | https://www.bilibili.com/video/BV1H5pc6wEsD |
| **自选S选谁** | 「自选S级！这个千万不要选！刮痧没伤害！选错直接重开！」 | https://www.bilibili.com/video/BV1cdobBoEGt |
| **抽卡规划** | 「抽错必后悔！异环1.4~1.6卡池抽取推荐！」 | https://www.bilibili.com/video/BV1onht6nECD |
| **回坑** | 「异环1.4版本新手入坑回坑攻略」 | https://www.bilibili.com/video/BV1B7hD6QEyx |
| **每日/每周必做** | 「最全最细每日每周必做事项，让你少走弯路」 | https://www.bilibili.com/video/BV1kmMJ6nEfG |
| **技术问题（闪退/卡顿/进不去）** | 「异环手游完美解决黑屏闪退问题！」 | https://www.bilibili.com/video/BV1NhdUBQEQz |
| | 「10月最新异环频繁闪退UE报错崩溃/闪退卡顿掉帧等问题优化解决方法」 | https://www.bilibili.com/video/BV1fNHa6yEz7 |
| | 「异环多次更新后出现卡顿/Low帧/进不去游戏等问题解决方法」 | https://www.bilibili.com/video/BV1zJaS6sEd4 |
| **账号问题** | 「异环手机号换绑教程」 | https://www.bilibili.com/video/BV17WhR6PEDf |
| | 「关于异环游戏账号登录逻辑的一些吐槽和建议」 | https://www.bilibili.com/video/BV1YbTo6NE3x |
| **新手教程卡关（BUG）** | 「异环神了 新手教程直接卡关」 | https://www.bilibili.com/video/BV1A6ooBrEfy |
| | 「【严重恶性bug】异环跳过新手教程不刷怪」 | https://www.bilibili.com/video/BV1ZUooBNEJQ |
| **官方社区在哪** | 「异环，究竟有没有像米游社一样的官方社区」 | https://www.bilibili.com/video/BV1wcSoBXE5m |
| **被通缉怎么消星** | 「在异环中被通缉了，怎么消星？」 | https://www.bilibili.com/video/BV1aVoEB1EeY |
| **兑换码** | 「异环1.1 兑换码」https://www.bilibili.com/read/cv49520620 | |
| **开荒必练** | 「1.4新手开荒必练轮椅-明日凛全攻略教程」 | https://www.bilibili.com/video/BV1ixaL6pEKg |
| **大世界玩法** | 「40秒讲清异环联机玩法有哪些,联机玩法的冷知识」 | https://www.bilibili.com/video/BV1J396B1Eyi |

### 4.4 官方技术 FAQ

来源：【官方原文】MaaNTE README（引述官方《异环》公平游戏宣言）

- 官方明确**严禁第三方工具**："严禁使用任何第三方工具破坏游戏公平性。我们将严厉打击使用外挂、加速器、作弊软件、宏脚本等非法工具的行为，这些行为包括但不限于自动挂机、技能加速、无敌模式、瞬移、修改游戏数据等操作。"
- 出处：https://yh.wanmei.com/news/gamebroad/20260202/260701.html

> ⚠️ **给 AI 助手的重要边界**：玩家问"帮我刷个日常"时，如果意图是**要求 AI 自动操作游戏（脚本/宏）**，官方明确禁止，AI 不应协助自动化操作游戏本体。但**信息查询类**帮助（"日常有哪些""这个任务在哪"）完全正当。

---

## 5. 社区梗 / 表情包文化

### 5.1 塔吉多（Taygedo）—— 全社区最大梗与吉祥物争议

**塔吉多是《异环》社区的第一大梗**，同时是游戏内角色、官方社区 App 名、以及"最被讨厌的吉祥物"争议中心。

| 梗/视频 | 证据 |
|---|---|
| 「【异环】塔吉多是我最看不顺眼的吉祥物」（**60.9万播放**） | https://www.bilibili.com/video/BV17w9CBJEpL |
| 「塔吉多阴叫一小时」（**48.8万播放**） | https://www.bilibili.com/video/BV1ngZcBmEAx |
| 「【OurPlay】从夯到拉锐评二游吉祥物！塔吉多你听着！」（44.2万播放） | https://www.bilibili.com/video/BV1G5RQBTEpY |
| 「【异环】安魂曲 塔吉多Taygedo~10分钟洗脑纯享版」（33.9万播放） | https://www.bilibili.com/video/BV1XhoMBpE8t |
| 「【环压抑】塔吉多角色PV \| 他自杀了······」（29.4万播放，仿《EVA》/压抑系二创） | https://www.bilibili.com/video/BV18t94B4ECe |
| 「🍬异环最唐主线🍬塔吉多的恋爱大作战🤪」 | https://www.bilibili.com/video/BV1HnoGB2Ez7 |
| 「黑粉最多的二游吉祥物，目前境遇如何？」 | https://www.bilibili.com/video/BV18CgP6dEwk |
| 「塔吉多！比咱想象的还要酷！」（游戏内台词，**官方自己也在玩梗**） | 【官方原文】`DT_VoiceCaptionDataTable.json` |
| 「神人异环塔吉多唱片免费领！苏幻还是忘不了塔吉多」 | https://www.bilibili.com/video/BV1H7gP6CE7Y |
| 玩家可以**撞倒/踹塔吉多**（社区娱乐） | https://www.bilibili.com/video/BV1NSaB6KEvu 、https://www.bilibili.com/video/BV19Qpw6REYq |

> **"塔吉多"也是官方社区 App 的名字**：「异环社区塔吉多首曝！」https://www.bilibili.com/video/BV1AuyhY5Ef8 ；但社区评价两极：「异环你这什么鸡肋塔吉多app，一点用没有，wiki也没有」https://www.bilibili.com/video/BV1oTTz6xEug

### 5.2 二游联动/致敬彩蛋梗

| 梗 | 证据 |
|---|---|
| **异环 × 凉宫春日**（联动，社区炸锅） | 「异环x凉宫春日的忧郁官方联动确定！God knows它来了，异环神了！」https://www.bilibili.com/video/BV1caeP6qEJ3 ；「异环×凉宫春日联动曲响起！各地主播集体炸了，日本主播秒答！」https://www.bilibili.com/video/BV1MreN6JEWT |
| **JOJO 彩蛋** | 「异环JOJO彩蛋，神父你这家伙还怕跳楼机啊」https://www.bilibili.com/video/BV1voa86tEXt ；「看到图直接绷不住了 JOJO声优小野贤章玩异环看JOJO梗」https://www.bilibili.com/video/BV11REd6mEx2 |
| **34部动漫场景彩蛋**（129.6万播放） | https://www.bilibili.com/video/BV1yYoaBgEuv |
| **P5 联动** | https://www.bilibili.com/video/BV16Y98BDEDj |
| **保时捷联动**（官方） | 【官方原文】[官网](https://yh.wanmei.com/index.html)："异环×Porsche 联动二期开启" |

### 5.3 其他流行梗

| 梗 | 说明 | 证据 |
|---|---|---|
| **"根本不存在这种异象"** | 热门二创句式 | https://www.bilibili.com/video/BV13xHo6MEXC |
| **"根本没有这种生物！"** | 同上系列 | https://www.bilibili.com/video/BV1SNhR6jEFx |
| **"根本没有这种塔吉多！？"** | 同上 | https://www.bilibili.com/video/BV11kaw6PEUw |
| **八区兄弟 / 十一区兄弟** | "原来我们都是区吗"系列，UP 主"罗老师不要啊"，**78.7万 + 22万播放** | https://www.bilibili.com/video/BV1dM8i6BEiW 、https://www.bilibili.com/video/BV1qVYL6sEzo |
| **异环六大抽象金刚表情包** | 明确的表情包文化证据 | https://www.bilibili.com/video/BV1V6HY66ENR |
| **"异环把细节用在了一些莫名其妙的地方"** | 系列吐槽梗 | https://www.bilibili.com/video/BV1r8HZ6WELp |
| **"以防你不知道…"** | 社区高频标题句式 | 数十条视频使用 |
| **真红的女仆蛋包饭** | 二创热门 | https://www.bilibili.com/video/BV1zgTn6rEYJ |
| **配饰通用导致的节目效果** | 玩家发现配饰可跨角色通用 | https://www.bilibili.com/video/BV1NKaw6fENS |
| **"我的异环坏掉了"** | 玩家自嘲 | https://www.bilibili.com/video/BV1uzHL6EErG |
| **"异环，究竟有没有像米游社一样的官方社区"** | 反映社区归属感缺失 | https://www.bilibili.com/video/BV1wcSoBXE5m |
| **"异环竟被公开批评，后又被予以表扬"** | 舆论反转梗 | https://www.bilibili.com/video/BV1Uuho6HERF |
| **"急报！异环运营换人，完美本部亲自接手"** | 运营变动话题 | https://www.bilibili.com/video/BV18Q8X6VEBF |
| **角色撞脸隔壁游戏** | 曳尔沐被指撞脸《原神》芙宁娜 | https://www.bilibili.com/video/BV15tH46sEh8 、https://www.bilibili.com/video/BV1GCeC6aEaY |
| **"灵可全是梗/梗小鬼"** | 角色灵可是梗密度担当 | https://www.bilibili.com/video/BV1iMt26hEH1 、https://www.bilibili.com/video/BV1EGYb6YE1S |

### 5.4 表情包/二创生态

- **异环六大抽象金刚表情包**：https://www.bilibili.com/video/BV1V6HY66ENR
- B站专栏区有大量二创/表情包标签，例如 `#魔法少女的魔女审判表情包_探头`、`#异环#`（见 https://www.bilibili.com/read/cv52755073）
- **"异环的二创有力气！"** 类口号式标题：https://www.bilibili.com/video/BV1WMpc6KE1N

---

## 6. 攻略站点清单（玩家实际在哪查攻略）

### 6.1 已确认可用/存在的站点

| 站点 | 类型 | 状态 | 证据 |
|---|---|---|---|
| **B站 (bilibili)** | **事实上的第一大攻略阵地**（视频+专栏+弹幕） | ✅ 200，API 可用 | 本报告绝大部分证据来源；有官方账号 [异环](https://space.bilibili.com/3546893080594665) 及 UP 主"异环攻略组""零号攻略组"等 |
| **nteguide.com** | 中文地图/攻略数据站 | ✅ 数据被抓取过（本地 `models/nteguide_*.json`） | 【官方原文】`tools/fetch_complete_map.py` 第 5 行注释："**nteguide.com** (中文站，高质量中文数据)"；抓取端点 `/data/map-core.json`、`/search-index.json`、`/data/map-markers-{region}.json` |
| **interactivemap.app** | 国际互动地图（6800+ 标记点） | ✅ 数据被抓取过 | 【官方原文】`tools/fetch_complete_map.py` 第 6 行："**interactivemap.app** (国际站，6800+标记点)"；路径 `/neverness-to-everness/maps/nte` |
| **官方社区 App「塔吉多」** | 官方社区 | ✅ 已上线 | B站：「异环社区塔吉多首曝！（内含下载方式）」https://www.bilibili.com/video/BV1AuyhY5Ef8 ；「怕你们不知道，异环的官方社区APP已经可以下载了！」https://www.bilibili.com/video/BV1raddBPEqq |
| **官方 Discord: `discord.gg/nte`** | 官方国际社区 | ✅ API 校验通过（`NTE Global Official`，guild id `1224197061889757204`） | 【官方原文】`discord.com/api/v9/invites/nte` 返回服务器描述 |
| **MaaNTE 官方 Discord** | 自动化工具社区 | ✅ | 【官方原文】MaaNTE README：`https://discord.gg/e6mPMRYQpR` |
| **MaaNTE 官网/文档** | 工具文档 | ✅ | 【官方原文】`https://docs.maante.org/` |
| **MaaNTE QQ 群** | 工具交流群 | ✅ | 【官方原文】README："加入 QQ 交流群请前往官网 QQ 群页面 https://docs.maante.org/zh_cn/qq-group/" |
| **异环官网** | 官方资讯/兑换码入口 | ✅ 200 | https://yh.wanmei.com/index.html 、https://yh.wanmei.com/news/index.html |
| **bilibili 游戏 wiki (`wiki.biligame.com/yihuan`)** | BWIKI | ⚠️ 域名存在（301→200）但**首页内容为空白模板**（2025-07-31 最后编辑，无实质内容） | 抓取 `wiki.biligame.com/yihuan/` 返回 1.4MB 但正文为空模板 |
| **GameKee (`gamekee.com/yihuan/`)** | 攻略站 | ⚠️ URL 存在但返回内容仅 3.6KB（"GameKee\|游戏百科攻略"），**疑似需 JS 渲染或该游戏页未建设** | 直接抓取 |
| **百度贴吧「异环吧」** | 论坛 | ✅ 存在（**403 无法抓取**） | B站：「爆了！**异环吧**已沦陷于心月狐广告之中」https://www.bilibili.com/video/BV1F9ap67Ef9 |

### 6.2 玩家自发聚集地（QQ 群 / 微信群）

社区存在大量玩家自建 QQ/微信群（通过 B站视频招人）：

- 「异环交流群，欢迎进来玩喵~」https://www.bilibili.com/video/BV12apP6jEx6
- 「异环交流群求加入」https://www.bilibili.com/video/BV15vuE6eEPd
- 「异环微信交流群，欢迎新老玩家加入」https://www.bilibili.com/video/BV1ghec66E5M
- 「来点异环玩家，新群没多少人」https://www.bilibili.com/video/BV1zoHi6xEP2

> ⚠️ 这些是**个人/小群**，非官方，群号需点进视频获取。

### 6.3 NGA / 米游社 —— 任务点名但结论重要

| 站点 | 结论 | 依据 |
|---|---|---|
| **NGA** | **存在性未证实**。`bbs.nga.cn` 与 `nga.178.com` 对本轮所有请求返回 **403**（含移动端 UA、含指定 fid 的版块 URL）。**无法确认异环是否有 NGA 版块** | 实测 HTTP 403 |
| **米游社** | **不适用**。《异环》由 **Hotta Studio 研发 / 完美世界发行**（官网原文："《异环》是 Hotta Studio 自主研发的超自然都市开放世界 RPG"），**非米哈游产品**，因此米游社不会有异环官方专区 | 【官方原文】[官网](https://yh.wanmei.com/index.html)；社区视频「异环，究竟有没有像米游社一样的官方社区」正是在讨论"没有米游社那样的社区"这一痛点 https://www.bilibili.com/video/BV1wcSoBXE5m |
| **Reddit** | `r/NevernessToEverness` 与 `r/NTE` 域名均返回 200（存在），但 **`.json` API 与 HTML 被 Reddit 网络策略拦截（403 / "whoa there, pardner!"）**，镜像站被 Anubis 反爬拦截。**内容未获取** | 实测 |
| **Discord** | ✅ `discord.gg/nte` = **NTE Global Official**（官方）；`discord.gg/e6mPMRYQpR` = **MaaNTE-Official** | API 校验 |

### 6.4 【未找到】

- 异环的 **NGA 版块 fid**：未找到（403 阻断）。
- 异环的 **官方 Wiki**（类似米游社观测枢 / 库街区）：未找到。社区抱怨"塔吉多 app 一点用没有，**wiki 也没有**"（https://www.bilibili.com/video/BV1oTTz6xEug），**反证官方 Wiki 缺失**。
- **Reddit 社区规模与常用黑话**：未找到（403 阻断）。
- 英文社区攻略站（如 game8、prydwen 等是否有异环专区）：**未找到**（搜索被污染，Bing RSS 对英文关键词返回无关结果）。

---

## 7. AI 助手该懂的上下文（**核心交付物**）

### 7.1 玩家口语 → 意图 → 数据源映射表

| 玩家可能说 | 真实意图 | AI 该做什么 | 需要的数据 |
|---|---|---|---|
| "帮我**刷个日常**" | 问每日/每周必做清单 | ⚠️ **区分意图**：若是"告诉我日常有哪些"→ 给清单；若是"帮我自动操作游戏"→ 官方禁止第三方自动化，应说明并转为信息帮助 | §4.2 清单；`DT_QuestEveryDay.json` |
| "**这任务在哪**" / "「与龙叔交谈」在哪" | 任务目标点坐标 | 查任务索引，给坐标 + 地图 | `verify/evidence/quest_index.rebuilt.json`（3,819 objectives，2,938 带坐标） |
| "**XX 角色怎么养**" | 配队/弧盘/空幕/觉醒建议 | 给养成方案 | 角色名（§2.1）+ 玩家攻略视频 |
| "**3+1** 是什么意思" | 术语解释 | 觉醒等级 + 弧盘精炼 | §3.3 |
| "**拐力**是什么意思" | 术语解释 | 增益能力 | §3.3 |
| "**兔子洞**在哪 / 打兔子洞有用吗" | 副本咨询 | 说明是刷材料的周常副本 | §3.4 |
| "**体力**该刷什么" | 资源分配 | 给规划建议 | §4.2、攻略视频 |
| "**娜娜莉**强不强" / "**牢大**强不强" | 强度咨询 | **需先做别名归一化**："牢大""这这躺""娜娜虎"都是娜娜莉 | §2.2 |
| "**吱本家**怎么打" | 指小吱 | 别名 → 小吱 | §2.2 |
| "**狗哥**配队" | 指翳 (Skia) | 别名 → 翳 | §2.2 |
| "**塔吉多**在哪下载" | 歧义！可能是①游戏内吉祥物 ②官方社区 App | **需澄清** | §5.1 |
| "**呗果**是什么" | 游戏内社交平台 | 说明 | §1.3 |
| "**方斯**怎么赚" | 货币获取 | 给途径 | §3.1 |
| "**甲硬币**不够" | 养成资源短缺 | 说明这是公认紧缺资源 | §3.1 |
| "**全站深境**怎么打" / "爬塔" | 高难玩法 | 给攻略 | §3.4 |
| "**轨外12**满星" | 高难关卡 | 同上 | §3.4 |
| "**粉爪**怎么刷" | 粉爪大劫案玩法 | 给路线 | §3.4、MaaNTE `PinkPawHeist` |
| "**即刻落槌**答案是什么" | 藏品展览最优解 | 给答案（社区有定论："92颗永恒之心+7颗碧波天垂"） | https://www.bilibili.com/read/cv53187864 |
| "**谕石**在哪" | 地图收集物 | 给点位 | §3.4、地图数据 |
| "**异象委托**怎么触发" | 任务触发条件 | 给条件 | 攻略视频 |
| "**逃课** / **焚决**" | 想要捷径攻略 | 给最优解攻略 | §3.3 |
| "这游戏**叫什么** / **NTE 是什么**" | 游戏身份 | 异环 = Neverness to Everness = NTE | §1 |

### 7.2 别名归一化表（**AI 必须内置**）

```
# 游戏
异环 / 異環 / NTE / Neverness to Everness / 牢环 → 游戏本体

# 角色别名（高置信度）
娜娜莉 / Nanally / 牢大 / 这这躺 / 这这莉 / 娜娜虎 / 虎老大 / 小娜娜莉 / 半拉耄耋 → 娜娜莉
小吱 / Xiaozhi / 吱本家 / Chiz → 小吱
翳 / Skia / 狗哥 / 大狼狗 / 狗狗人 → 翳
安魂曲 / Lacrimosa / 草莓牛奶 → 安魂曲
海月 / 水母姐 / 水母 → 海月
早雾 / 御姐 → 早雾
塔吉多 / Taygedo / Tayge / 泰格多 → 塔吉多（注意：也是社区App名）
达芙蒂尔 / 达芙迪尔 / Daffodil / 达芙 → 达芙蒂尔
埃德嘉 / 埃德加 / Edgar → 埃德加
妮夏 / 尼夏 / Nixia → 妮夏
真红 / Zhenhong / 真红 → 真红
残虹 / Canhong → 残虹
黑羽 → 黑羽（1.4 新角色，数据表中尚未收录，见 §8）
明音凛 / 明音 / 明日凛 → 明音凛（1.4 新角色，注意玩家有"明日凛"误写）
```

> ⚠️ **重要提醒**：上表中"黑羽""明音凛""曳尔沐""绘莉""明日凛"等 1.4/1.5 新角色在本地数据表（1.4.5 tagged）中**缺失或极少**（`明音凛` 0 次、`曳尔沐` 2 次、`绘莉` 3 次、`黑羽` 227 次但多为其他语境）。**需补充新版数据表。**

### 7.3 歧义与陷阱清单（AI 容易答错的点）

| 陷阱 | 说明 |
|---|---|
| **"塔吉多"双义** | ①游戏内吉祥物角色 ②官方社区 App 名 ③"塔吉多的售货机""塔吉多的仓库"（游戏内设施） |
| **"深境" vs "轨外"** | 两个不同高难玩法。深境=爬塔（200层）；轨外=轨外之境（轨外10/12层） |
| **"噗卡乐园" vs "噗咔乐园"** | 同一地方，官方写"噗卡"，玩家常写"噗咔" |
| **"即刻落槌" vs "即刻落锤"** | 同一玩法，两种写法都有 |
| **"命座"** | 玩家从原神/鸣潮带来的外来词，异环官方叫**觉醒**。数据表中"命座"出现 0 次 |
| **"专武"** | 外来词，异环官方叫**弧盘** |
| **"拐"** | 外来词（增益位），异环无此官方术语 |
| **"米游社"** | 异环不是米哈游游戏，**没有米游社专区**，官方社区是"塔吉多" |
| **"牢大"** | 在异环语境特指**娜娜莉**（不是篮球梗的原始含义） |
| **"焚决/焚诀"** | 社区自造词，意为"最优解攻略"，游戏内无此词 |
| **角色译名不一致** | 达芙蒂尔/达芙迪尔、埃德嘉/埃德加、海月（数据表有）等，见 §2.1 |

### 7.4 玩家情绪与语气（回答风格参考）

- 社区自称："**开服老登**""**囤囤鼠**""**萌新**""**肝帝**""**牢玩家**"
- 常用语气词：**喵**（如"关注伊波恩喵""欢迎进来玩喵~"——见 MaaNTE 任务文本"关注伊波恩喵 / 关注伊波恩谢谢喵"）、**doge**、**绷不住**、**笑死**、**神了**、**唐**（"异环最唐主线"）
- 常见吐槽：**坐牢**（枯燥）、**刮痧**（伤害低）、**水**（剧情拖沓）、**减负**（求官方降肝）
- 【官方原文】MaaNTE 任务文案里出现的社区语气："关注伊波恩喵""随意简短，带点整活或感叹的味道"——说明**二创/整活语气是本社区主流**

---

## 8. 【未找到】清单（**不编造，如实列出**）

| 主题 | 状态 | 原因/后续建议 |
|---|---|---|
| NGA 异环版块及其中黑话 | **未找到** | 403 阻断。建议：人工浏览器访问 `bbs.nga.cn` 搜索"异环"确认版块 fid |
| 百度贴吧「异环吧」内容 | **未找到** | 403 阻断 |
| Reddit `r/NevernessToEverness` 内容与英文黑话 | **未找到** | Reddit 网络策略拦截 + 镜像被 Anubis 挡。建议：用已登录浏览器访问 |
| 萌娘百科「异环」条目 | **未找到** | 403 阻断 |
| 完整角色外号对照表 | **部分未找到** | 38 个角色无外号。建议：对 4 条外号盘点视频做 **ASR 转写**（BV1cLEQ6fEAx / BV16XKD6hEeZ / BV1ZW3961E8u / BV1vVTX6fEcq） |
| 薄荷"味道外号"完整体系 | **部分未找到** | 仅确认"安魂曲=草莓牛奶" |
| "刮刮乐"具体指哪个玩法 | **未找到** | 社区评论玩梗，无解释 |
| "调弧"官方全称 | **未找到** | 疑似技能名简称 |
| "焚决/焚诀"词源 | **未找到** | 确认为社区自造词（数据表 0 次），但出处不明 |
| 官方 Wiki | **未找到** | 社区反证其缺失 |
| 英文社区攻略站（game8/prydwen 等） | **未找到** | 搜索被污染 |
| 游戏本身的玩家昵称（除"牢环"外） | **基本未找到** | 玩家普遍直接叫"异环"或"NTE"，**没有流行昵称** |
| 1.5/1.6 新角色（曳尔沐、绘莉、EXE）资料 | **极少** | 本地数据表为 1.4.5 版本 |

---

## 9. 参考来源汇总

### 官方来源
1. 《异环》官方网站 — https://yh.wanmei.com/index.html
2. 《异环》官方新闻 — https://yh.wanmei.com/news/index.html
3. 《异环》公平游戏宣言 — https://yh.wanmei.com/news/gamebroad/20260202/260701.html
4. 官方 Discord「NTE Global Official」— https://discord.gg/nte
5. 官方 B站账号 — https://space.bilibili.com/3546893080594665
6. 本地游戏数据表 `tools/nte_datatables/DataTable/*.json`（39 文件，来源标注 `Waifus-Grace/NTE_Assets, tagged 1.4.5`）
7. 本地角色索引 `models/nteguide_search-index.json`（抓自 nteguide.com，45 角色）

### 地图/工具站
8. nteguide.com（中文地图数据）
9. interactivemap.app/neverness-to-everness/maps/nte（国际互动地图）
10. MaaNTE 官网 — https://docs.maante.org/
11. MaaNTE GitHub — https://github.com/1bananachicken/MaaNTE
12. MaaNTE Discord — https://discord.gg/e6mPMRYQpR

### 关键 B站视频/专栏（本报告核心黑话证据）
13. 异环角色都有哪些外号 — https://www.bilibili.com/video/BV1cLEQ6fEAx
14. 异环五大外号来源 — https://www.bilibili.com/video/BV16XKD6hEeZ
15. 异环给角色起外号 — https://www.bilibili.com/video/BV1ZW3961E8u
16. 这就是为什么娜娜莉外号嘉欣 — https://www.bilibili.com/video/BV1ZhdKBDE8L
17. 既然薄荷是按角色身上的味道来起外号的 — https://www.bilibili.com/video/BV1gku86bEmu
18. 【异环】小吱的真面目：吱本家 — https://www.bilibili.com/video/BV119EH6nEYN
19. 【异环】翳基础角色攻略：认真尽责的大狼狗副队长 — https://www.bilibili.com/video/BV1AQ5L69EKi
20. 加强牢大娜娜莉 — https://www.bilibili.com/video/BV1hYa16FEj7
21. 萌新入坑异环必看，三分钟了解异环术语 — https://www.bilibili.com/video/BV1SaRxBZE77
22. 异环【名词解释】及【战斗机制】 — https://www.bilibili.com/video/BV1ZKoeBvESL
23. 【异环】环合反应详细解析 — https://www.bilibili.com/video/BV1nXoSBJESD
24. 【异环入坑指南】第一期（206万播放）— https://www.bilibili.com/video/BV1UPdLBcEJy
25. 【异环】最全最细每日每周必做事项 — https://www.bilibili.com/video/BV1kmMJ6nEfG
26. 异环，究竟有没有像米游社一样的官方社区 — https://www.bilibili.com/video/BV1wcSoBXE5m
27. 【异环】塔吉多是我最看不顺眼的吉祥物 — https://www.bilibili.com/video/BV17w9CBJEpL
28. 异环 卡池模拟分析报告2.0（走格子机制）— https://www.bilibili.com/read/cv42220878
29. 异环：和原神鸣潮相比…缺甲硬币？ — https://www.bilibili.com/read/cv49056324
30. 异环攻略：即刻落槌最新答案 — https://www.bilibili.com/read/cv53187864
31. 异环攻略：1.4版本新角色黑羽+明音凛养成突破材料整理 — https://www.bilibili.com/read/cv53036978
32. 【异环】谕石全收集之桥间地篇 — https://www.bilibili.com/read/cv39968143

---

*报告完 · 调研代理 #6 · 所有结论均标注来源与可信度，未标注【推测】的内容均有可查证据。*
