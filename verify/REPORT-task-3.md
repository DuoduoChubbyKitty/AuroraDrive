# task-3 独立验证报告（验证方：verifier）

工作目录：`/Users/dupi/Desktop/自动驾驶系统`
仓库版本：`70b4d17`（工作区有大量未提交改动，属正常在研状态）
报告时间：2026-10-06
验证方声明：**本报告只读产品代码，未修改任何仓库源码**；所有脚本与证据写入 `verify/`。

---

## 结论速览

| # | 验证项 | 结论 | 严重级别 |
|---|--------|------|----------|
| 1.1 | quest_index stats 与重建一致 | **PASS** | — |
| 1.2 | 9 条面板文字唯一命中 | **PASS** | — |
| 1.3 | 反向测试（对话364 / miss / empty） | **PASS** | — |
| 1.4 | **坐标系 = 13056** | **PASS（已数字定案）** | — |
| 1.5 | 匹配器假阳性（1–3 字输入） | **已修复 → CLOSED** | ~~HIGH~~ → 解除 |
| 1.6 | 匹配器无 CI 退出码 | **已修复 → CLOSED** | ~~LOW~~ → 解除 |
| 1.7 | B 项符号两处不一致 | **存疑** | LOW（实际影响 ≤0.05px） |
| 2.1 | 基线归属（4 个红线文件零改动） | **PASS** | — |
| 2.2 | locatorTarget 语义未改 | **PASS** | — |
| 2.3 | swift build（全量干净编译 72.02s） | **PASS** | — |
| 2.4 | --quest-selftest 20/20 exit 0 | **PASS** | — |
| 2.5 | ratio / CRLF / core-sub 三条深挖 | **PASS** | — |
| 2.6 | 全流水线对拍 1454 条（验证方新增） | **PASS**（833 可寻路 100% 一致） | — |
| 3.1 | 卡片位置 / 居中 / 贴顶 | **PASS** | — |
| 3.2 | 银白辉光（读像素） | **PARTIAL PASS**（3面已修好，下方仍有 ViewportPanel 投影） | **LOW** |
| 3.3 | 空任务卡片消失 | **PASS** | — |
| 3.4 | TagChip 未被挤动 | **PASS** | — |
| 3.5 | 三分支 + 单位「米」 | **PASS** | — |
| 3.6 | 对比度 WCAG | **PASS** | — |
| 3.7 | --mc-shot 覆盖边界说明 | **PASS**（ui 说法成立） | — |

**总计：PASS 17 项 / PARTIAL 1 项（LOW）/ 存疑 1 项（LOW）/ FAIL 0 项。**
**总体判定：可以上（有条件）—— 详见文末「最终总结」。**

---

## 验证 1.1 —— 索引 stats 与重建一致

**结论：PASS**

命令（重跑 build 脚本，输出重定向到 verify/，不动 models/ 产物）：

```bash
python3 verify/rebuild_to_tmp.py
```

关键输出：

```
✅ /Users/dupi/Desktop/自动驾驶系统/verify/evidence/quest_index.rebuilt.json  2.57 MB
   统计: {'files': 39, 'objectives': 3819, 'with_coord': 2938, 'with_desc': 3086,
          'exact_keys': 1372, 'core_keys': 1984, 'name_keys': 1128}

现有 stats : {"core_keys": 1984, "exact_keys": 1372, "files": 39, "name_keys": 1128,
              "objectives": 3819, "with_coord": 2938, "with_desc": 3086}
重建 stats : {"core_keys": 1984, "exact_keys": 1372, "files": 39, "name_keys": 1128,
              "objectives": 3819, "with_coord": 2938, "with_desc": 3086}
stats 相等 : True
sha256 现有: 160dbf8c9edc7c496bcb656815911e8175fa1c570fce64f1752b2e8db8762eec
sha256 重建: 160dbf8c9edc7c496bcb656815911e8175fa1c570fce64f1752b2e8db8762eec
字节级相同 : True
```

比要求更严：不仅 6 项 stats 全等，**重建结果与现有文件 sha256 完全一致（字节级可复现）**。

证据路径：`verify/evidence/v1_rebuild.txt`、`verify/rebuild_to_tmp.py`

---

## 验证 1.2 —— 9 条面板文字唯一命中

**结论：PASS**

命令：

```bash
python3 tools/quest/quest_matcher.py --selftest
```

关键输出（节选，全部 9 条）：

```
✅ 与路边着急的研究员对话   exact          1   (-17869, 125947, 6441)
✅ 路边着急的研究员对话     substr:与路边着急   1   (-17869, 125947, 6441)
✅ 与路边着急的研究员话     core-sub:路边着   1   (-17869, 125947, 6441)
✅ 搭乘电梯                exact          1   (30757, 65971, 6258)
✅ 走进局长办公室           exact          1   (3990, 267360, 31760)
✅ 与艾尔菲德交流           exact          1   (3990, 267360, 31760)
✅ 向眼前之人对话           exact          1   (3920, 272093, 4685)
✅ 进入电话亭               exact          1   (4014, 272683, 4823)
✅ 聆听奈丽的介绍           exact          1   (3959, 263359, 7151)

唯一命中: 9 / 15
```

**9 条必需唯一命中的全部为候选数 = 1**，且三条「与路边着急的研究员对话」的 OCR 变体（丢「与」、丢「对」）都收敛到同一坐标 `(-17869, 125947, 6441)`，行为正确。

证据路径：`verify/evidence/v1_matcher_selftest.txt`

---

## 验证 1.3 —— 反向测试（不许假阳性）

**结论：PASS**

命令与输出：

```bash
$ python3 tools/quest/quest_matcher.py "对话"
=== 对话
    方式=core:对话  分数=0.90  候选=364        ← 要求 364，实测 364 ✅

$ python3 tools/quest/quest_matcher.py "[剧情HeroicApearan"
=== [剧情HeroicApearan
    方式=miss  分数=0.00  候选=0             ← 要求 miss ✅

$ python3 tools/quest/quest_matcher.py ""
=== 
    方式=empty  分数=0.00  候选=0             ← 要求 empty ✅
```

三条反向测试全部符合预期，**无假阳性**。

证据路径：`verify/evidence/v1_matcher_selftest.txt`

---

## 验证 1.4 —— 坐标系交叉验证（重点，已数字定案）

### 结论：**正确的地图尺寸是 13056**（不是 11264 / 22528 / 26112）

**先修正一个符号约定问题**：任务描述里给的公式 `mapX = A*wx + B*wy + TX / mapY = A*wy - B*wx + TY`
与 `NetworkLocator.swift:68` 的 `(a*x - b*y + tx, b*x + a*y + ty)` 符号相反。
我用 1777 条**已知双坐标**（world + map）反解，确定生成数据的是**任务描述/MapWiring 那一版**：

```
参与比对条数            : 1777
Swift 约定 平均误差(px) : 0.018982   最大 0.052773
文档 约定 平均误差(px)  : 0.000390   最大 0.000700   ← 与 JSON 保留 3 位小数吻合
```

（两者差异 ≤0.05px，因为 `B=5.7e-8` 极小，**实际影响可忽略**，见 1.7。）

### 证据链 A —— 1777 个真实地图点的覆盖范围（一票否决 11264）

```
map_locations.json（声明 mapPixels=13056）
mapX 范围: 1269.6 .. 7706.6
mapY 范围: 1298.1 .. 11393.5      ← 11393.5 > 11264

尺寸       X内点数         Y内点数         结论
11264    1777/1777      1772/1777     溢出 5   ❌
13056    1777/1777      1777/1777     可行     ✅
22528    1777/1777      1777/1777     可行
26112    1777/1777      1777/1777     可行
```

### 证据链 B —— 124 个传送点换算落点

```
传送点总数: 124
换算后 mapX 范围: 841.0 .. 9374.7
换算后 mapY 范围: 2246.8 .. 10972.8
```

样例（world → map）：

| 传送点 | worldX | worldY | mapX | mapY |
|---|---|---|---|---|
| WertheimerTower_001 | -94823.0 | 165376.0 | 4971.9 | 7921.9 |
| WertheimerTower_002 | -184528.3 | 211012.4 | 3501.2 | 8670.1 |
| WertheimerTower_003 | -171144.4 | 106510.4 | 3720.6 | 6956.9 |
| WertheimerTower_004 | -30515.8 | 7779.3 | 6026.2 | 5338.2 |
| WertheimerTower_005 | 10521.6 | 65394.4 | 6699.0 | 6282.8 |
| WertheimerTower_006 | -280851.2 | 104839.2 | 1922.0 | 6929.5 |

> ⚠️ 注意：**单看「是否落在 0..S 范围内」无法区分 4 个尺寸**——124 个传送点对 4 个尺寸都「全部落内」。
> 所以「范围检查」是**弱证据**，不能作为结论依据。真正定案的是证据链 C/D。

### 证据链 C —— 语义判别（决定性，不依赖尺寸假设）

用「传送点名字」去找「同名 POI 的官方地图坐标」，看公式落点能否对上：

```
传送点                          公式落点X     公式落点Y | 最近同名POI        距离px
WertheimerTower_001             4971.9      7921.9 | 维特海默塔 #004       9.1
WertheimerTower_002             3501.2      8670.1 | 维特海默塔 #005      11.4
WertheimerTower_003             3720.6      6956.9 | 维特海默塔 #003      15.6
WertheimerTower_004             6026.2      5338.2 | 维特海默塔 #002       8.9
WertheimerTower_005             6699.0      6282.8 | 维特海默塔 #001      29.3
WertheimerTower_006             1922.0      6929.5 | 维特海默塔 #006      14.8

公式落点 ↔ 同名POI官方坐标 距离: 平均 14.8 px, 最大 29.3 px
≤60px 命中: 6/6 (100.0%)

反证（把 POI 坐标按别的地图尺寸换算）：
  尺寸 11264  : 平均距离    938.7 px, ≤60px 命中 0/6
  尺寸 13056  : 平均距离     14.8 px, ≤60px 命中 6/6   ✅
  尺寸 22528  : 平均距离   4728.4 px, ≤60px 命中 0/6
  尺寸 26112  : 平均距离   6703.7 px, ≤60px 命中 0/6
```

### 证据链 D —— 第二组独立语义样本（任务文字 ↔ POI）

用任务面板文字里出现的 POI 名（如「魔女之家」）反向验证：

```
文字与 POI 名匹配上的样本: 5
距离分布: min 7 / 中位 13 / max 20   px
≤30px : 5/5 (100.0%)

  尺寸 11264  : 平均距离   1286.0 px, ≤60px 0/5
  尺寸 13056  : 平均距离     12.6 px, ≤60px 5/5   ✅
  尺寸 22528  : 平均距离   6865.7 px, ≤60px 0/5
  尺寸 26112  : 平均距离   9459.4 px, ≤60px 0/5
```

### 证据链 E —— 上游元数据 + 运行时常量（旁证）

```
tools/mapweb/MaaNTE-Map/src/data/map-data.json → map:
  {"width": 26112, "height": 26112, "tileSize": 512,
   "mapLocatorSourceWidth": 13056, "mapLocatorSourceHeight": 13056,
   "coordinateSystem": "game-affine-v1"}

Sources/AuroraDrive/App/MissionConsole.swift:1911
  static let mapPixels: Double = 13056

Sources/AuroraDrive/App/MapWiring.swift:29-36
  worldToMapPixelX = kCalibA*wx + kCalibB*wy + kCalibTX
  worldToMapPixelY = kCalibA*wy - kCalibB*wx + kCalibTY

models/bigworldmap-13056.jpg → 13056 × 13056（sips 实测）
models/map_tiles → 24 × 24 瓦片 @ 544px = 13056（576 张）
```

**26112 的来历**：那是上游 MaaNTE-Map 的**瓦片金字塔**尺寸（51×51 @512，用于多级缩放），
不是坐标空间。上游明确区分 `width: 26112`（瓦片）与 `mapLocatorSourceWidth: 13056`（坐标）。
把 26112 当坐标空间是典型的踩坑点。

### 定案

> **坐标系 = 13056。依据：**
> 1. `map_locations.json` 的 1777 个真实点中 mapY 最大 **11393.5**，**11264 装不下（5 点出界）**；
> 2. 124 个传送点换算落点经**语义配对**（同名 POI）在 13056 下平均偏差 **14.8px**，其余 3 个尺寸偏差 **938 ~ 6704px**；
> 3. 第二组独立样本（任务文字↔POI，5 条）在 13056 下平均 **12.6px**，其余尺寸 **1286 ~ 9459px**；
> 4. 上游元数据 `mapLocatorSourceWidth: 13056`，运行时 `MapTileImage.mapPixels = 13056`，底图实测 13056×13056。
>
> 4 个尺寸的数值对比见上表；**13056 是唯一同时满足「全部落内」且「语义重合到几十像素」的尺寸。**

证据路径：`verify/evidence/v1_coord.txt`、`v1_coord_semantic.txt`、`v1_coord_broad.txt`、`v1_coord_image.txt`
脚本：`verify/coord_check.py`、`verify/coord_semantic.py`、`verify/coord_broad.py`、`verify/coord_image_check.py`

### ⚠️ 坐标系边界（必须写清楚，避免后人误用）

**13056 只作用于「地图像素」那条链路，不要套到任务坐标上。**

| 链路 | 数据 | 是否经过 mapX/mapY 换算 |
|---|---|---|
| 地图渲染 / worldToMapPixel / routeGraph | 世界坐标 → 地图像素 | **是**，用 A/B/TX/TY，输出范围 0..13056 |
| `quest_index.json` 的 x/y/z | **世界坐标（UE5 厘米）** | **否**，直接喂 `setLocatorTarget` |

即：`quest_index` 里的 `x/y/z` 与 `locatorX/locatorY` 同系（世界坐标），
`setLocatorTarget(x:y:)` 直接接收，**不得做任何 mapX/mapY 换算**。
本次验证 1.4 的换算只是为了**交叉验证坐标系自洽性**（把传送点世界坐标换算到地图像素，
再与已知 POI 的地图像素比对），**不是**要求接线方对 quest 坐标做换算。

两条链路混用正是历史上出过 bug 的地方（见 `MissionConsole.swift:3794` 注释：
「目标点缺一次 worldToMapPixel 变换」的修复记录）。

---

## 验证 1.5 —— 匹配器假阳性（**已修复 → CLOSED**）

> **状态更新（2026-10-06 15:0x）**：lead 已修复，验证方**独立复现通过**，本项关闭。
> 复验脚本 `verify/recheck_falsepos.py`（验证方自写），证据 `verify/evidence/v1_falsepos_recheck.txt`。
> 下文保留**原始问题记录**以备追溯。

### 原始问题（修复前）

**结论：FAIL。发现任务描述未覆盖的一类假阳性：1–3 字短输入会被误判为「唯一命中」。**

命令与输出：

```bash
$ python3 tools/quest/quest_matcher.py "前往"
    方式=core-sub:跟随奈丽前  分数=0.85  候选=1     ← 2 字输入，唯一命中

$ python3 tools/quest/quest_matcher.py "的"
    方式=name:迎接的熏风  分数=0.80  候选=1        ← 1 字输入，唯一命中

$ python3 tools/quest/quest_matcher.py "E"
    方式=name:神器，GET！  分数=0.80  候选=1       ← 单字符，唯一命中
```

穷举索引里出现过的**全部 1591 个单个汉字**：

```
=== 全部 1591 个「索引中出现过的单个汉字」作为输入 ===
  唯一命中(假阳性): 892      ← 56% 的汉字会假报唯一
  歧义(安全)      : 384
  miss(安全)      : 315

  假阳性样例:
    '一' → name:另一位来客        → 另一位来客
    '下' → name:下落不明          → 下落不明
    '与' → name:「枷锁」与「转机」  → 「枷锁」与「转机」
    '专' → name:专家会议          → 专家会议
    '丢' → name:走丢的小狗        → 走丢的小狗
```

**根因**：`quest_matcher.py:152-154` 的任务名兜底是纯 `in` 判断，没有长度门槛：

```python
# 5. 任务名
for nm, v in self.byname.items():
    if nm and (nm in t or t in nm):     # ← 单字符 t 必然命中含该字的任何任务名
        return v, "name:" + nm[:16], 0.8, len(v) > 1
```

对比：子串分支（`quest_matcher.py:123`）有 `len(t) >= 4` 守卫、核心词子串分支（`:142`）有 `len(k) >= 4` 守卫，
**唯独任务名分支没有守卫** —— 属于遗漏，不是设计取舍。

**爆炸半径**（用真实面板文字长度分布抽样，模拟 OCR 只识别出前几个字）：

```
=== OCR 只认出前 2/3 个字时（模拟部分识别）===
  取 300 条真实面板文字的前2字 → 假唯一 237/300 (79%)
  取 300 条真实面板文字的前3字 → 假唯一 222/300 (74%)
```

真实面板文字长度分布（`exact` key）：4 字 155 条、5 字 204 条、6 字 219 条、7 字 228 条……
即**短文本是主流形态**，OCR 抖动丢字后极易落进 2–3 字区间。

**严重级别：HIGH —— 但为「有条件 HIGH」**：
- 若 task-1 的接线把 `match()` 的**唯一命中直接用于自动寻路/自动传送** → **HIGH（会导致角色跑错点）**；
- 若接线只做「显示提示、不自动执行」或对短文本另有长度门槛 → 降为 MEDIUM/LOW。

**验证方建议（不改代码，仅报告）**：
1. 在任务名兜底分支加与其它分支一致的长度门槛（如 `len(t) >= 4`），并加 `ratio` 限制；
2. 对最终返回结果加统一最低置信门槛：候选数 > 1 或 输入长度 < 4 时返回「存疑」而非「唯一」；
3. 补充回归用例：`"前往"` / `"的"` / `"E"` 必须**不得**报唯一。

**这是本次验证发现的最重要问题，建议 task-1 接线前先堵。**

证据路径：`verify/evidence/v1_falsepos_sweep.txt`、`v1_falsepos_singlechar.txt`、`v1_falsepos_blast.txt`

### 修复后独立复验（验证方执行）

lead 的修复：任务名兜底分支加 `len(t)>=4` + `len(nm)>=4` + 长度比 `>=0.5`；
新增 `match_confident(text, min_len=4)` 返回 verdict ∈ {ok, ambiguous, low, miss}。

验证方**自己重写脚本**复现（未使用 lead 的脚本）：

```
A) 穷举 1591 个单汉字 → verdict 分布 {'miss': 1574, 'low': 17}，ok = 0        ✅（修复前 892）
B) 随机 3000 个双字组合 → verdict 分布 {'miss': 2994, 'low': 6}，ok = 0      ✅
C) 9 条真实面板文字 → 全部 verdict=ok（候选数全为 1）                        ✅
D) 与薄荷对话→ambiguous(23) / 与龙叔交谈→ambiguous(3) / 对话→low(364) / 前往→low  ✅
E) 原 3 条反向测试无回归（对话仍 364 且 ambiguous、miss、empty）              ✅
F) 原 9 条唯一命中未被误伤 9/9                                              ✅
G) 爆炸半径复测：真实面板文字前2字→ok 0/300（修复前 237）；前3字→0/300（前 222）✅
H) 功能未退化：200 条真实面板文字(≥6字) → ok 155 / ambiguous 45 / miss+low 0，异常率 0.0% ✅
```

**一处口径差异（非缺陷，已与 lead 确认关闭）**：
「的」「E」「异」实测为 **miss** 而非 `low` —— 因任务名分支 `len(t)>=4` 直接跳过，
连候选都拿不到。这**完全符合修复意图**（不得再报唯一），且 wiring 只认 `verdict=="ok"`，
miss/low 均被挡住，**无安全影响**。验证方原建议「把 len 检查提到 `if not e` 之前」经 lead 说明后
**已撤销**：那会让「没匹配上」与「文本太短」混淆，降低可诊断性。

**结论：HIGH 解除。**

---

## 验证 1.6 —— 匹配器 CI 退出码（**已修复 → CLOSED**）

> **状态更新**：lead 已修复（用例表加「期望 verdict」列、判定改为 `verdict == 期望`、`sys.exit(selftest())`），
> 验证方**独立复验通过并做了负向对照**，本项关闭。

### 修复前（原始记录）

```
$ python3 tools/quest/quest_matcher.py --selftest; echo "EXIT=$?"
唯一命中: 9 / 15
EXIT=0        ← 即使出现 ❌ 也返回 0，无法作为 CI 门禁
```

### 修复后独立复验

**正向**：
```
$ python3 tools/quest/quest_matcher.py --selftest; echo "EXIT=$?"
verdict 正确: 15 / 15
EXIT=0        ✅
```
15 条覆盖 4 类 verdict：ok 9 条 / ambiguous 3 条 / low 1 条 / miss 2 条。

**负向对照（关键 —— 证明退出码不是硬编码 0）**：
产品代码零改动，把 `quest_matcher.py` 复制两份到 `verify/tmp_negctl/` 后变异，跑完即删。
复验前后产品文件 sha256 一致：`df24e01231c1bf13a9b6c1ccde7f8bdce25d97ae3e2f8b1408e8b9748e3b8efb`。

| 对照 | 变异 | 结果 |
|---|---|---|
| 1 | 「与龙叔交谈」期望 ambiguous → 改成 `ok` | `❌ 与龙叔交谈 ambiguous want=ok`，`verdict 正确: 14/15`，**EXIT=1** ✅ |
| 2 | 「搭乘电梯」期望 ok → 改成 `ambiguous` | `❌ 搭乘电梯 ok want=ambiguous`，`verdict 正确: 14/15`，**EXIT=1** ✅ |

**两个方向都验证了退出码随失败翻转，门禁可用。结论：CLOSED。**

---

## 验证 1.7 —— B 项符号两处不一致（存疑，LOW）

**结论：存疑（数值影响可忽略，但属文档/实现不一致）**

| 位置 | 公式 | 对 1777 条参考数据平均误差 |
|---|---|---|
| `MapWiring.swift:29-36` | `x = A*wx + B*wy + TX`；`y = A*wy - B*wx + TY` | **0.00039 px** |
| `NetworkLocator.swift:68` (`CoordinateTransform.apply`) | `x = a*x - b*y + tx`；`y = b*x + a*y + ty` | 0.018982 px |
| `CoordinateCapture.swift:112-115` | 只定义常量，未定义公式 | — |

`map_locations.json` 的生成脚本 `tools/map/build/build_locations.py:188-189` 与 `MapWiring` 一致（正确那版）。
`NetworkLocator.apply()` 的 B 项符号与之相反。

**影响评估**：`B = 5.693519256055879e-08`，world 坐标量级 ≤4e5 → 交叉项 `B*wy ≤ 0.023 px`，
两式最大差 **0.053 px**。对 13056 像素地图而言**完全不可见**，不构成功能缺陷。

**但**：`NetworkLocator.apply()` 的注释声称「与 CoordinateCapture.kCalibTX/TY 同步」，
实际公式符号不同，属于**注释与实现不符**，将来若有人放大 B 或缩小地图会踩坑。建议统一符号或补注释说明。

严重级别：LOW（信息性）。

证据路径：`verify/evidence/v1_coord.txt`（步骤 0）

---

> 📌 **本文档结构**：验证 1（Python 侧）→ 验证 2（Swift 构建/自检/diff）→ 验证 3（UI 像素）→ 最终总结。
> 其中「最终总结」在文档末尾；中间的阶段性小结已随进度更新为 CLOSED 状态。

---

# 验证 2 —— Swift 构建 / 自检 / git diff

## 2.1 基线归属比对 —— PASS ✅

**方法**：用验证方 14:59 存的基线 sha256（`verify/evidence/v2_baseline.txt`）逐文件比对，
区分「wiring 改的」「ui 改的」「lead 改的」与「不该被碰的」。

```bash
shasum -a 256 <files>   # 与 verify/evidence/v2_baseline.txt 逐行比对
```

| 文件 | 归属 | 基线 sha256 | 现在 | 判定 |
|---|---|---|---|---|
| `SpeedOCRReader.swift` | **红线：不该碰** | `4e6c8b6a…` | `4e6c8b6a…` | **完全一致 ✅** |
| `NetworkLocator.swift` | 红线：不该碰 | `defe0f29…` | `defe0f29…` | **完全一致 ✅** |
| `CoordinateCapture.swift` | 红线：不该碰 | `ff4e1216…` | `ff4e1216…` | **完全一致 ✅** |
| `MapWiring.swift` | 红线：不该碰 | `bd6852c6…` | `bd6852c6…` | **完全一致 ✅** |
| `MissionConsole.swift` | ui 作用域 | `ccc074ef…` | `5e39c17b…` | 已变（ui 的卡片）✅ 预期内 |
| `AuroraFlags.swift` | wiring 作用域 | `471e0707…` | `1ea2f068…` | 已变（加 questOCR flag）✅ |
| `AuroraDriveApp.swift` | wiring+lead 作用域 | `d08fc0c8…` | `42aed542…` | 已变（接线 + lead 路网基线）✅ |

**归属明确：4 个红线文件零改动，`SpeedOCRReader.swift` 一个字没变 ✅**

> 关于 `AuroraDriveApp.swift`：lead 已声明其并行改动（route-selftest 基线值 + 随机种子 + 一条断言）。
> 验证方接受该声明，未把该文件的变更归到 wiring 越界。

## 2.2 locatorTarget / setLocatorTarget 语义 —— PASS ✅

```bash
git diff -U0 -- Sources/AuroraDrive/App/AuroraDriveApp.swift \
  | grep -E "^[+-].*(var locatorTarget|func setLocatorTarget)"
# （无输出）
```

→ 定义行**无 +/- 变化**。当前签名：
```
AuroraDriveApp.swift:4111  var locatorTarget: (x: Double, y: Double)? = nil
AuroraDriveApp.swift:4248  func setLocatorTarget(x: Double, y: Double) { locatorTarget = (x, y) }
```

新调用点唯一，**零换算**：
```swift
AuroraDriveApp.swift:5533
if let t = reading.target { self.setLocatorTarget(x: t.x, y: t.y) }
```

语义契约（存档于 `verify/evidence/v2_baseline.txt`）：`locatorTarget` = **世界坐标（UE5 厘米）**，
由三处消费点佐证（`MissionConsole.swift:2365` 的 `(t.x - locatorX)/100` 得米、
`:3794` 与 `:772` 的注释原文）。task-1 直接喂 quest 世界坐标是**正确**的。

## 2.3 Swift 构建 —— PASS ✅（全量干净编译）

```bash
bash scripts/build-lock.sh run "verify-quest-2" -- \
  swift build -c release --disable-sandbox --scratch-path .build/scratch
```
第一次只跑了增量（`Build complete! (1.44s)`），为排除「拿旧二进制冒充」，
验证方 touch 了 3 个 wiring 文件（**仅改 mtime，sha256 前后 diff 一致**）强制重编译，
但被 ui 并发编辑 `MissionConsole.swift` 打断：
```
error: input file '.../MissionConsole.swift' was modified during the build
BUILD_EXIT=1
```
→ 这是**并发写冲突**（ui 当时正在改，锁也被 ui 持着），**不是 wiring 的编译错误**。

ui 冻结后重跑**全量干净编译**（独立 scratch，不碰 ui 的构建产物）：
```bash
bash scripts/build-lock.sh run "verify-quest-2-clean" -- \
  swift build -c release --disable-sandbox --scratch-path .build/verify-scratch
```
```
[6/10] Compiling AuroraDriveShared AuroraDriveShared.swift
[7/12] Compiling AuroraDriveUserAgent main.swift
[10/12] Compiling AuroraDrive AIAgentPanel.swift
Build complete! (72.02s)
BUILD_EXIT=0
```
**从零全量编译通过，72.02s，exit 0 ✅**

## 2.4 自检 —— PASS ✅

```bash
./.build/scratch/release/AuroraDrive --quest-selftest
# ═══ 结果：全部通过 ✅ ═══
# SELFTEST_EXIT=0
```

20 项全过（逐项核对，非只看尾部）。关键项：
- 8 条真实面板文字：**verdict 与 Python 一致 8/8**；可寻路 6/8；**ok 5 / ambiguous 2 / low 1**
  → 与 lead 更正后的真值一致（验证方按真值断言，未照抄原先「8 条全 ok」的错误说法）
- 反向：`对话`→low(364)、`[剧情HeroicApearan`→miss、空串→miss、单字`的`→miss、**单字抽样 2963 个 ok=0**
- 投票 3 次确认、链消歧 chain-next、坐标等价放行、ROI 88~1176/458~592、节流 0.7s

## 2.5 重点深挖三条 —— 全部 PASS ✅

### (a) ratio 与 difflib 一致性 —— 独立复算
把 `sequenceRatio` 函数**逐字提取**（源码 353-401 行）编成独立探针，与 Python `difflib.SequenceMatcher` 对拍：
```
对拍对数: 1491（真实 key + 截断/丢字变体 + CRLF + ASCII/数字/空串边界）
不一致对数: 0 / 1491
✅ 逐位一致（容差 1e-12）；其中含 CRLF 的 35 对全部一致
```
比 wiring 报的 5157 对更独立（用的是提取出的真实源码，不是重写实现）。

### (b) CRLF 字素簇 —— 关键点，wiring 选对了 ✅
```
索引里含 \r\n 的 exact key: 4 条（core 同 4 条，byname 0 条）
"前往琥珀湖\r\n（小队成员均达到25级）"
  Python len()           = 19   ← Python 3 str 长度 = 码点数
  Swift unicodeScalars   = 19   ✅ 一致
  Swift .count (grapheme)= 18   ❌ 差 1（\r\n 合并成 1 个字素簇）
```
→ **Python `len()` 是码点数，Swift 必须用 `unicodeScalars.count` 才等价。**
wiring 全文用 `unicodeScalars.count`（8 处），**选对了 ✅**。
用真实二进制对 4 条 CRLF key 及变体实跑：**12/12 verdict 与候选数全部一致 ✅**

### (c) core-sub 比对对象 —— bug 真实存在，修复验证正确 ✅
验证方复现两种写法在真实索引上的差异：
```
进入藏馆     候选 c=藏馆     → 用 t 命中=[]                 用 c 命中=['前往金苹果藏馆','金苹果藏馆']
抵达异象管理局  候选 c=异象管理局 → 用 t 命中=['异象管理局']        用 c 命中=['前往异象管理局','异象管理局']
```
→ 用核心词 `c` 比确实会漏命中（wiring 第一版的 bug **可复现**）。
→ 现 Swift 源码（`:768` 附近）明确用整条查询 `t`：`Self.contains(t, ks) || Self.contains(ks, t)`，
   与 Python `k in t or t in k` **对齐 ✅**

## 2.6 验证方额外新增：全流水线对拍（wiring 未做）

把 `match()` 函数体 + `pickCoreSub` + `contains` + `QuestIndex.load` **逐字提取**编成独立探针，
喂真实索引，与 Python 参考实现对拍 **1454 条**查询：

```
verdict 不一致   : 0 / 1451     ✅ 逐条一致
候选数 n 不一致  : 28 / 1454
首选 qid 不一致  : 60 / 1454
```

按长度拆解：

| 查询长度 | 条数 | qid/候选数不一致 | 率 |
|---|---|---|---|
| 1-2 字 | 14 | 2 | 14.3% |
| 3-4 字 | 466 | 58 | 12.4% |
| **5-7 字** | 544 | **0** | **0.0%** |
| **8+ 字** | 430 | **0** | **0.00%** |

**★ 最关键的安全性质：**
```
verdict=ok（可寻路）的查询: 833 条 → qid/候选数不一致: 0
不一致的 60 条 verdict 分布: {'low': 60}
```
→ **所有 833 条「可寻路」结果与 Python 100% 一致，零风险。**
→ 60 条分歧**全部是 `low`**（3-4 字短查询），被 `verdict=="ok"` 门槛**全部拦住**，永不到达 `setLocatorTarget`。
→ 分歧根因即 wiring 注释自述的「同族兄弟任务 + Python 靠 JSON 插入序决出」不可移植问题，**不是 bug**。
→ 若这些分歧被误用会偏 2870~4758 米 —— 但被 low 挡住，实际不可达。**置信门槛在此起了决定性作用。**

## 2.7 覆盖边界（明确声明）

| 内容 | 覆盖状态 |
|---|---|
| 索引加载 / 四路匹配 / 置信门槛 / 投票 / 链消歧 / 坐标语义 / ROI 几何 / 节流 | **自检覆盖**（20 项，实跑通过）|
| 中文 Vision OCR 真实识别 | **仅探针证据**（/tmp/qprobe1-3，wiring 提供，验证方未独立重跑）|
| Swift↔Python 匹配语义等价 | **验证方独立对拍 1454 条**（新增证据）|
| 真机游戏内实际面板 | **完全未验** —— 需开 `AURORA_QUEST_OCR=1` 实机跑 |

---

# 验证 3 —— UI 像素级验证

## 3.0 渲染可复现性（前置）—— 重要修正

ui 警告「占位图每次渲染不同，不要用 on/off 相减」。验证方**实测两次渲染**：
```
$ ./.build/scratch/release/AuroraDrive --mc-quest 1470 560   # 第二次
run1_on.png  sha256 = 0d31558d0b97846d97ad4ad6529b2b56d20ae5692b0bcce451adf774ecded6c7
run2_on.png  sha256 = 0d31558d0b97846d97ad4ad6529b2b56d20ae5692b0bcce451adf774ecded6c7
run1_off.png sha256 = 2be1f8bbbd7dfc53df9b978ce8c401d7e78cc4ca89b44f9492671e16949f22f6
run2_off.png sha256 = 2be1f8bbbd7dfc53df9b978ce8c401d7e78cc4ca89b44f9492671e16949f22f6
```
→ **同一 tag 两次渲染字节级完全相同，渲染是确定性的。**
且 on/off 两图在**远离卡片**的区域差异 ≤4（`>10` 的像素为 0）→ **占位图是同一张，相减有效**。
**ui 的噪声警告不成立**（其顾虑对辉光结论影响不大，但方法上可以更精确）。

## 3.1 卡片位置 / 居中 / 贴顶 —— PASS ✅

命令：`python3 verify/ui_measure.py`（证据 `verify/evidence/v3_ui_measure.txt`）

| 项 | ui 报 | 验证方实测 | 判定 |
|---|---|---|---|
| 卡片上沿 y | 77.0 pt | **77.0 pt**（y=154px）| ✅ |
| 卡片下沿 y | 122.5 pt | **122.5 pt**（y=245px）| ✅ |
| 外框高度 | 46.0 pt | **45.5 pt** | ✅（0.5pt 差=抗锯齿，可接受）|
| 预览框内容区 x | 13.0..1457.0 | **13.0..1456.5 pt** | ✅ |
| 预览框中心 x | 735.0 pt | **734.8 pt** | ✅ |
| 卡片中心 x | — | **734.8 pt** | ✅ |
| **居中偏差** | 0.0 pt | **0.00 pt** | ✅ |
| **贴顶间距** | 10.0 pt | **10.0 pt** | ✅ |

**卡片在预览框内、水平居中、贴顶 —— 三项全部确认 ✅**

宽度证据：代码 `QuestCard.cardWidth = 176`（`MissionConsole.swift:872`）。
实测银白描边直段 151.5pt → 反解圆角 r=(176−151.5)/2 = **12.25pt**，
与 `AuroraSilver.radius = Aurora.radiusCard = 12` 吻合 ✅（ui 的圆角解释成立）。

## 3.2 银白辉光 —— PARTIAL PASS（LOW）：加法混合已修好三面，下方仍有 ViewportPanel 投影

> **状态更新（2026-10-06 15:40）**：lead 已按验证方的方法修复（`.blendMode(.plusLighter)` + 删 QuestCard 投影），
> 验证方**独立复验**：上/左/右由暗转亮 ✅，但**下方仍暗**，并定位到真正来源（`ViewportPanel:742`）。
> 严重级别从 MEDIUM **降为 LOW**。下文保留原始问题记录。

### 原始问题（修复前）

**验证方实测（`verify/evidence/v3_glow_definitive.txt`、`v3_halo_character.txt`）：**

辉光确实存在，但**方向是「压暗」而不是「增亮」**：
```
环带内 Δ亮度(on−off): min=-67.7  max=+0.7  均值=-15.3
变亮(Δ>2)像素: 0 ; 变暗(Δ<-2)像素: 57376
```
反解等效合成色（模型 `on = off*(1-a) + C*a`）：
```
a ≈ 0.504 ; C ≈ RGB(97, 98, 95)
C 的 B−R = -2.0  → 中性无彩 ✅（「银白」的色相要求满足）
C 的亮度 = 97    → 中灰偏暗，在亮背景上表现为【压暗】
```
**根因（验证方判定）**：SwiftUI `.shadow(color:radius:)` 只做 alpha lerp、不做加法，
亮背景下必然压暗。lead 据此改用 `.blendMode(.plusLighter)` 加法混合。

### 修复后独立复验（验证方执行）

基线：修复前 = 验证方 15:27 的 `run2_{on,off}.png`；修复后 = 15:39 重跑。
**两版 off 图 sha256 完全相同** → 对比公平 ✅

**① 三面净变亮 —— PASS ✅**

| 方向 | 修复前 Δ | 修复后 Δ | 判定 |
|---|---|---|---|
| 上 5-25px | −5.05 | **+17.54** | ✅ 变亮 5280 / 变暗 0 |
| 左 5-25px | −18.08 | **+9.69** | ✅ 变亮 1556 / 变暗 2 |
| 右 5-25px | −17.41 | **+9.79** | ✅ 变亮 1530 / 变暗 2 |
| **下 5-25px** | −54.99 | **−27.05** | ❌ 仍暗（变亮 0 / 变暗 7040）|

全环带：修复前 变亮 0 / 变暗 37633 → 修复后 **变亮 14709** / 变暗 21115。加法混合确实生效。

**② 下方仍暗的根因 —— 不在 QuestCard，在 `ViewportPanel:742` ❌**

变暗区几何与卡片吻合（是「卡片形状的投影」）：
```
y=250: 变暗 x 1275..1666 (中心 1470, 宽 391) | 卡片 x 1294..1646 (中心 1470, 宽 352)
y=260: 变暗 x 1262..1679 (中心 1470, 宽 417) | 卡片 x 1294..1646
```
方向性极强（上 +17.5 / 下 −27.1，|上−下| = 28.6；|左−右| 仅 0.15）= **带 y 偏移的黑色投影特征**。

**来源**：
```swift
// MissionConsole.swift:731-742（ViewportPanel 修饰符链末端）
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { ... strokeBorder ... }
        .shadow(color: .black.opacity(0.78), radius: 17, y: 14)   // ← 就是这行
```
卡片经 `.overlay(alignment: .top)`（`:631`）挂在 ViewportPanel 内部 ZStack，
而该 `.shadow` 作用于整个 ViewportPanel（含 overlay 内容）→ **卡片被连带投了黑色投影**。

**已排除**：QuestCard 内部无 `.shadow(black)`（仅 `:890` 一个银白 `glowFar r4`）；ViewportPanel 内部无 shadow。
**排除「背景假象」**：同 y 行远处（x300-600）Δ = **+0.02**，背景在 on/off 间一致，
故下方变暗**确实由卡片造成**，非圆弧/占位噪声。

**③ 色相 —— 需用「增量色」量（修正验证方首次量法）**

首次量法有误（选区域最亮像素 → 选中黄色背景）。改用**增量色 (on−off) 均值**：
```
上 (y134-152)  增量色 [−17.3, +30.7, +71.4]   B−R +88.7
左 (x1234-1292) 增量色 [−18.6, +21.9, +44.6]   B−R +63.3
右 (x1648-1706) 增量色 [−18.0, +22.1, +44.4]   B−R +62.4
```
→ 增量是「R 减、G/B 加」= 补蓝压黄 → **视觉上确实往中性/银白方向走 ✅**
→ 但**不能说 B−R 是个位数**：那是「加法前的光源色」（`glowNear 0xF2F4F8` B−R=+6）；
   叠加后的**增量色** B−R 为 +62~+89。在纯黄底上无法达到完全中性（背景过饱和，加法补不回来）——
   属物理限制，非缺陷。

**④ 对比度未退化 —— PASS ✅**
```
修复前: 文字vs顶底 8.52:1   文字vs底底 14.43:1
修复后: 文字vs顶底 8.16:1   文字vs底底 15.56:1   （仍远超 AA 4.5）
```

**⑤ 几何回归 —— PASS ✅**
银白外框行：修复前 `[154,155,244,245]` / 修复后 `[154,155,244,245]` → **位置尺寸零变动**

**严重级别：LOW（观感，非功能缺陷）**
三面发光 + 下方投影，观感已是「发光卡片带立体投影」，远好于修复前的「四面全压暗」。
是否继续消除下方投影取决于是否要求「四面纯发光」。可选修法（验证方不改代码）：
把 `.shadow` 从 ViewportPanel 移到其 `.background` 层，使 overlay 内容不被投影。

**外扩范围对比：**
| 方向 | ui 报 | 验证方实测 |
|---|---|---|
| 左 | 35 pt | **44.0 pt** |
| 右 | 35.5 pt | **35.0 pt** |
| 上 | 10 pt | **10.5 pt** |
| 下 | 32.5 pt | **64.5 pt** |

→ 左/下差异较大，属**测量口径差异**（ui 用「首帧不可见」，验证方用 `|Δ|<1.5`），不影响功能判定。
上方 10.5pt 与 ui 的 10pt 一致，且被预览框上沿（y=67pt）**裁切** —— 与「贴顶 10pt」自洽 ✅

> ⚠️ 验证方另发现：lead 报「上 20~50px Δ+14.21」的取样区间 y104~134 **是黑色控制台**（预览框上沿 y=134），
> Δ 恒为 0.00。真正的上方辉光区是 **y134~154**，实测 **Δ+24.18**。

## 3.3 任务为空时卡片消失 —— PASS ✅

```
卡片矩形(含辉光) 区域 on/off 差异>30 的像素: 59149 (90.67%)
off 图【卡片外框内部】银白描边像素: 0 / 10677
→ ✅ 卡片完全消失，无空框残留
```
视觉确认（`/tmp/card_3way.png` 第三格）：off 图中卡片区域 100% 是游戏画面，无任何残留边框或空框。

## 3.4 现有 TagChip 未被挤动 —— PASS ✅

```
TagChip 带 y=25..65px 亮块列范围:
  on     : 55..2880 px
  off    : 55..2880 px
  noroute: 55..2880 px
on vs off    该带最大像素差(通道和): 1 ; 差异>10 的像素: 0
on vs noroute 该带最大像素差(通道和): 1 ; 差异>10 的像素: 0
```
→ 三张图 TagChip 带的列范围**完全一致**（55..2880），最大像素差 1（量化噪声）。
**TagChip 零位移 ✅**（ui 报「最大差 0~1、列范围 55..2880」，验证方复算一致）

代码佐证：卡片用 `.overlay(alignment: .top)`（`MissionConsole.swift:631`）挂在 ZStack 层，
**不参与布局流**，故不推挤标签 —— 设计正确 ✅

## 3.5 三条必验分支 —— PASS ✅

视觉确认 `/tmp/card_3way.png`：

| 分支 | 期望 | 实测 |
|---|---|---|
| **on** | 任务名 + 直线 + 弯道 | 「迎接的熏风」/「直线 **2535 米**」/「弯道 **559 米**」✅ |
| **off** | 整卡消失 | 无卡片、无空框 ✅ |
| **noroute** | 有任务 + 无路线 → 弯道显示「--」 | 「与薄荷对话」/「直线 2535 米」/「弯道 **--**」✅ |

```
[MC-QUEST] 直线距离 2534.9 m（世界坐标 (-77000,31865) → (3920,272093)，÷100）
[MC-QUEST] 弯道距离 559.0 m（RoutePlan.distanceMeters，已是米）
[MC-QUEST] saved=true tag=noroute ... 任务=与薄荷对话
```
→ 直线 2534.9m → 显示「2535 米」✅（四舍五入正确）
→ **noroute 分支确实渲染出「--」，未编造数字** ✅（ui 补的第三张图有效）

### (b) 单位是「米」不是「公里」—— PASS ✅
图上文字为「直线 **2535 米** ｜ 弯道 **559 米**」，**未出现「公里」** ✅
代码佐证 `MissionConsole.swift:852-861`：注释明确「一律用『米』，不做公里换算」，
`metersText` 返回 `String(format: "%.0f 米", m)` ✅

## 3.6 对比度（WCAG 独立计算）—— PASS ✅

验证方用 WCAG 2.x 公式独立计算（证据 `verify/evidence/v3_contrast_final.txt`）：

| 组合 | 对比度 | AA(4.5:1) |
|---|---|---|
| 任务名 vs 卡片顶部底 | **8.52 : 1** | ✅ |
| 任务名 vs 卡片底部底 | **14.43 : 1** | ✅ |
| 距离数字 vs 卡片底部底 | **15.32 : 1** | ✅ |

实测色值：任务名文字 `RGB(236,238,242)`（银白）、卡片底 `RGB(34,28,33)`（深色玻璃）。
→ **全部远超 AA 门槛 ✅**（ui 报 8.5/9.2/11.1，验证方实测 8.52~15.32，同量级，**不是编的**）

## 3.7 `--mc-shot` 验不了这张卡 —— ui 的说法成立 ✅

代码佐证：
```
AuroraDriveApp.swift:795  // 必须走真实 ViewportPanel：`--mc-shot` 那份是手抄版预览框，没有卡片。
MissionConsole.swift:6137 //   **根本没有** ViewportPanel，所以任务卡片在那里永远渲染不出来
```
`MissionControlShot.renderNow`（`:5955`）与 `ViewportPanel`（`:562`）是两套渲染路径；
新夹具 `renderQuestCard`（`:6259`）复用**真实** `ViewportPanel`（`:6263`）出图。
→ **ui 的说明属实 ✅**，验证方采信。

---

# 最终总结：能不能上，还差什么

## 总体判定：**可以上（有条件）**

### 验证 1（Python 侧）—— 全部收口
- ✅ 索引字节级可复现；9 条面板文字全部唯一命中；3 条反向测试符合预期
- ✅ **坐标系 = 13056 已数字定案**（4 条独立证据链）；边界已写明
- ✅ 假阳性 HIGH **已修复并独立复现**（ok=0/1591、0/3000、爆炸半径 237→0）
- ✅ selftest 退出码 **已修复并负向对照双向验证**

### 验证 2（Swift 侧）—— PASS，无 FAIL
- ✅ **全量干净编译通过**（72.02s, exit 0）
- ✅ 自检 20/20，exit 0
- ✅ 4 个红线文件零改动；`SpeedOCRReader.swift` 一个字没变
- ✅ `locatorTarget` 语义未改，调用点零换算
- ✅ ratio 与 difflib 逐位一致（1491 对）；CRLF 用 `unicodeScalars.count` 正确；core-sub bug 已修
- ✅ **833 条可寻路结果与 Python 100% 一致**；60 条分歧全为 `low` 被门槛拦住

### 验证 3（UI）—— 通过，1 条 LOW 残留
- ✅ 卡片在预览框内 / 居中偏差 **0.00pt** / 贴顶 **10.0pt**
- ✅ 空任务整卡消失、无空框残留
- ✅ TagChip **零位移**（三图列范围一致，最大差 1）
- ✅ 三条分支（on/off/noroute）全对；单位为「米」；对比度 8.16~15.56:1 全过 AA
- ✅ 辉光加法混合修复生效：上/左/右 **由暗转亮**（上 −5.05→+17.54 等）；几何零变动
- ⚠️ **LOW（残留）：卡片下方仍被 `ViewportPanel:742` 的 `.shadow(black 0.78, y14)` 压暗**
  （−27.05，较修复前改善 51%）。该投影作用于 ViewportPanel 整体、连带 overlay 卡片。
  观感已是「三面发光 + 下方立体投影」，非功能缺陷；可选修法见 3.2。

## 还差什么

1. **真机未验（最重要）**：`--quest-selftest` 不含真实 Vision OCR；真机游戏内面板需开
   `AURORA_QUEST_OCR=1` 实机跑一次。当前 OCR 段只有 wiring 的 `/tmp/qprobe{1,2,3}` 探针证据。
2. **LOW 观感残留**：卡片下方仍有 ViewportPanel 投影（`MissionConsole.swift:742`）。
   若要求「四面纯发光」，可把该 `.shadow` 从 ViewportPanel 移到其 `.background` 层；
   若接受「发光+投影」的立体观感，可不动。**需产品/用户决策，非阻塞项。**
3. **信息性 LOW**：`NetworkLocator.apply()` 的 B 项符号与 `MapWiring` 相反
   （影响 ≤0.05px，属注释与实现不符，不影响功能）。

## 验证方声明
本报告所有结论均基于**可复现命令 + 原始输出**；验证方**未修改任何产品代码**
（所有脚本与证据写入 `verify/`）。验证 3 期间对 `--mc-quest` 夹具的重跑仅覆盖 `/tmp` 下截图。
