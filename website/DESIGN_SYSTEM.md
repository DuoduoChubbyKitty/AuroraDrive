# AuroraDrive 官网视觉系统（DESIGN_SYSTEM.md）

> **适用对象**：Phase 3 前端落地工程师（1:1 实现本文档）
> **唯一事实来源**：`BRIEF.md`。本文档不引入任何 BRIEF 之外的产品事实；所有出现的数字均来自 BRIEF。
> **技术栈约束**：Vite + React 19 + TypeScript + Tailwind CSS v4 + framer-motion 14 + react-router-dom 7。
> 本文只定义**规范与令牌**，不含 React 组件实现。

---

## 0. 快速索引（给 Phase 3 的落地映射）

| 主题 | 章节 |
| --- | --- |
| 美学定位与信条 | §1 |
| 配色体系 + 实测对比度 | §2 |
| 字体体系与字号阶梯 | §3 |
| 栅格与留白 | §4 |
| 组件视觉规范 | §5 |
| 动效令牌与页面过渡 | §6 |
| 深色模式策略 | §7 |
| AI 配图清单 | §8 |
| 反面清单（禁止项） | §9 |
| 自检清单 | §10 |

---

## 1. 美学定位

### 1.1 一句话性格

> **「深色为主的高精度工程仪表盘 —— 用真实测量值和代码说话，用极光渐变做唯一的一点点情绪。」**

AuroraDrive 不是 SaaS，是一台 macOS 上的实时系统。它的说服力来自「实测选型」「三档降级」「架构红线」这些硬核工程事实。所以视觉必须像一台**示波器 / 飞行仪表**：深色底、极细分隔线、等宽数字、状态灯、刻度感。极光（Aurora）意象只出现在**品牌强调色**与**插画渐变**中，是点缀而非主体。

### 1.2 三类受众的视觉优先级

| 受众 | 他们扫的第一眼 | 视觉承载方式 |
| --- | --- | --- |
| 《异环》玩家 | "它能不能替我开车？会不会失控？" | Hero 主副标题 + 降级状态机可视化（用档位色 + 状态灯语言） |
| 端到端研究者 | "这套梯子是真机实现吗？" | 性能数字用等宽大号数字 + 表格化的实测对照 |
| macOS / 视觉开发者 | "CoreML + ScreenCaptureKit + libpcap 怎么拼起来的？" | 代码窗口（真实语法高亮）+ 架构层级用直角折线图，不是插画 |

**结论**：网站首页的主视觉重心是**数字与代码**，不是插画。AI 插画只承担氛围与分区过渡，不承担信息。

### 1.3 五条设计信条

1. **数字与代码是视觉主角之一。**
   任何卖点后面必须跟着一个可验证的数字或机制（BRIEF 写作红线 1）。视觉上兑现这条信条：所有关键指标用**等宽字体 + tabular-nums** 排版，与正文的比例区分明确，形成"仪表读数感"。禁止用图标代替数字。

2. **不用大面积圆角卡片堆砌。**
   卡片圆角上限 **6px**（见 §5.3），阴影几乎不用，靠 **1px 描边 + 层级色差** 划分区域。渐变只允许出现在极光渐变（§2.7）与 AI 插画里，**禁止**把渐变铺在卡片上、禁止 hero 背后大面积紫粉铺色。

3. **动效服务于理解，不服务于装饰。**
   每个动效必须回答"它解释了什么"。滚动渐入=建立阅读顺序；页面过渡=维持空间连续性；状态灯脉冲=表达活性；没有第三种理由做动效。禁止视差滚动、禁止无限循环动画（状态灯除外）、禁止元素飞入。

4. **直角与网格优先，曲线只给"数据"。**
   边框、图标、分隔线一律直角或 ≤2px 微圆角；只有"曲线"出现在真实数据语境（光流曲线、坐标轨迹）。这让"路线图 / 路网先验"这类内容天然像工程图。

5. **诚实呈现边界，不做营销修辞。**
   已删除的功能不画、不暗示；30 个工具 / 15 个技能实装这种"挂载数 ≠ 可用数"的关系，用**并置的对照呈现**（两个数字 + 一条分隔），而不是用一句漂亮话掩盖。合规与免责声明在视觉上给予固定位置与固定层级（§5.12）。

### 1.4 明确避免（防止 Phase 3 走偏）

| 禁止 | 原因 |
| --- | --- |
| 玻璃拟态（glassmorphism）大面积模糊卡片 | 2000 年代 Web 2.0 感，与工程仪表气质冲突 |
| 紫蓝粉 SaaS 渐变铺底 + 大圆角 + 阴影卡 | 一眼模板化，掩盖技术感 |
| 3D 等距插画 / emoji 图标 | 廉价感，与"精密仪器"相悖；图标一律用 1.5px 线性 SVG |
| Hero 大字占满两行以上 + 居中排版 | 居中大标题是落地页模板默认解法 |
| 无限循环的光效/呼吸/旋转 | 除非是表示"运行中"的状态灯 |
| 视差滚动（parallax） | 移动端性能差，且与"可测量"气质冲突 |
| 任何未经 BRIEF 核实的数字或图标 | BRIEF 铁律 |

---

## 2. 配色体系

### 2.1 双模式策略速览

- **深色是默认模式**（`prefers-color-scheme: dark` 或用户显式选择）。理由：产品是 macOS 上的实时引擎深色工具，且"极夜/极光"是项目名的直接意象。
- **亮色是完整对等模式**，不是把深色反相。所有语义色在亮色下重新取色以保证对比度达标。
- 实现方式：`class` 切换 + `data-theme` 属性双写（见 §7）。

### 2.2 完整 CSS 变量清单

**深色（默认）**

```css
[data-theme="dark"] {
  /* ── 背景层级 ───────────────────────────── */
  --bg-base:        #070A0F;  /* 页面底：极夜蓝黑 */
  --bg-surface:     #0B1017;  /* 区块底：交替分区 */
  --bg-card:        #101823;  /* 卡片面 */
  --bg-elevated:    #16202D;  /* 浮层：下拉 / 弹窗 / 吸顶导航 */
  --bg-inset:       #0A0E14;  /* 内陷：代码窗、终端、表单控件 */
  --bg-scrim:       rgba(7, 10, 15, 0.72);  /* 遮罩 */

  /* ── 文本层级 ───────────────────────────── */
  --text-primary:   #E9EEF7;
  --text-secondary: #A9B4C4;
  --text-tertiary:  #8A97A8;
  --text-disabled:  #687484;
  --text-inverse:   #04120C;  /* 反色文字：用于强调色实底之上 */

  /* ── 描边层级 ───────────────────────────── */
  --stroke-subtle:  #18202B;  /* 区块内部分隔线 */
  --stroke-default: #232E3D;  /* 卡片边框 */
  --stroke-strong:  #3A4A60;  /* 强调边框 / hover 边框 */
  --stroke-input:   #5F748F;  /* 表单控件边界（≥3:1） */
  --stroke-focus:   #35E0A1;  /* 焦点环 */

  /* ── 品牌强调色 ─────────────────────────── */
  --accent:         #35E0A1;  /* 主强调：极光青绿 */
  --accent-hover:   #2ECB93;
  --accent-fill:    #35E0A1;  /* 高饱和填充（配 --text-inverse 深字） */
  --accent-subtle:  rgba(53, 224, 161, 0.12);
  --accent-line:    rgba(53, 224, 161, 0.32);
  --accent-2:       #7C8CF8;  /* 次强调：极光靛紫 */
  --accent-3:       #C56CF0;  /* 极光洋红：仅用于渐变第三停靠点 */

  /* ── 语义色 ─────────────────────────────── */
  --success:        #3DD68C;
  --warning:        #F5A524;
  --danger:         #FF5A5F;
  --info:           #4EA8FF;
  --success-bg:     rgba(61, 214, 140, 0.12);
  --warning-bg:     rgba(245, 165, 36, 0.12);
  --danger-bg:      rgba(255, 90, 95, 0.12);
  --info-bg:        rgba(78, 168, 255, 0.12);

  /* ── 降级状态机三档（关键） ───────────────── */
  --tier-e2e:       #35E0A1;  /* 档位 1：端到端主驾 —— 最佳 */
  --tier-yolo:      #7C8CF8;  /* 档位 2：YOLO 接管 —— 降级但可用 */
  --tier-rule:      #8A97A8;  /* 档位 3：纯规则兜底 —— 最保守 */
  --tier-e2e-bg:    rgba(53, 224, 161, 0.10);
  --tier-yolo-bg:   rgba(124, 140, 248, 0.10);
  --tier-rule-bg:   rgba(138, 151, 168, 0.10);

  /* ── 网络新鲜度四档（brief 第三节：live/recent/stale/lost） ── */
  --fresh-live:     #3DD68C;
  --fresh-recent:   #4EA8FF;
  --fresh-stale:    #F5A524;
  --fresh-lost:     #FF5A5F;

  /* ── 语法高亮 ───────────────────────────── */
  --syn-comment:    #76849A;
  --syn-keyword:    #A78BFA;
  --syn-string:     #35E0A1;
  --syn-number:     #F5A524;
  --syn-function:   #4EA8FF;
  --syn-type:       #7C8CF8;
  --syn-punct:      #8A97A8;
  --syn-path:       #E9EEF7;

  /* ── 阴影与发光（暗色下靠描边分层，阴影极轻） ── */
  --shadow-sm:  0 1px 2px rgba(0, 0, 0, 0.40);
  --shadow-md:  0 8px 24px -8px rgba(0, 0, 0, 0.55);
  --shadow-lg:  0 24px 64px -16px rgba(0, 0, 0, 0.70);
  --glow-accent: 0 0 0 1px rgba(53, 224, 161, 0.30),
                  0 0 24px -6px rgba(53, 224, 161, 0.35);
  --grid-line: rgba(233, 238, 247, 0.045);  /* 仪表网格底纹 */
}
```

**亮色**

```css
[data-theme="light"] {
  /* ── 背景层级 ───────────────────────────── */
  --bg-base:        #F6F8FB;  /* 页面底 */
  --bg-surface:     #FFFFFF;  /* 区块底 */
  --bg-card:        #FFFFFF;  /* 卡片面 */
  --bg-elevated:    #FFFFFF;  /* 浮层 */
  --bg-inset:       #EDF1F6;  /* 内陷 */
  --bg-scrim:       rgba(11, 17, 25, 0.40);

  /* ── 文本层级 ───────────────────────────── */
  --text-primary:   #0B1119;
  --text-secondary: #445061;
  --text-tertiary:  #5A6675;
  --text-disabled:  #7A8593;
  --text-inverse:   #FFFFFF;

  /* ── 描边层级 ───────────────────────────── */
  --stroke-subtle:  #E4E9F0;
  --stroke-default: #D3DAE4;
  --stroke-strong:  #AEB8C6;
  --stroke-input:   #7F8C9B;
  --stroke-focus:   #0A7A55;

  /* ── 品牌强调色（降明以保证亮底 4.5:1） ───── */
  --accent:         #0A7A55;
  --accent-hover:   #08684A;
  --accent-subtle:  rgba(10, 122, 85, 0.10);
  --accent-line:    rgba(10, 122, 85, 0.28);
  --accent-2:       #4F5FD6;
  --accent-3:       #8E2FB0;
  --accent-fill:    #35E0A1;  /* 亮色下唯一可用的高饱和填充（配 --text-inverse 深字） */

  /* ── 语义色 ─────────────────────────────── */
  --success:        #0A7343;
  --warning:        #8F5B04;
  --danger:         #C62A2F;
  --info:           #1A5FBF;
  --success-bg:     rgba(10, 115, 67, 0.10);
  --warning-bg:     rgba(143, 91, 4, 0.10);
  --danger-bg:      rgba(198, 42, 47, 0.10);
  --info-bg:        rgba(26, 95, 191, 0.10);

  /* ── 降级状态机三档 ─────────────────────── */
  --tier-e2e:       #0A7A55;
  --tier-yolo:      #4F5FD6;
  --tier-rule:      #5A6675;
  --tier-e2e-bg:    rgba(10, 122, 85, 0.10);
  --tier-yolo-bg:   rgba(79, 95, 214, 0.10);
  --tier-rule-bg:   rgba(90, 102, 117, 0.10);

  /* ── 网络新鲜度四档 ─────────────────────── */
  --fresh-live:     #0A7343;
  --fresh-recent:   #1A5FBF;
  --fresh-stale:    #8F5B04;
  --fresh-lost:     #C62A2F;

  /* ── 语法高亮 ───────────────────────────── */
  --syn-comment:    #5A6675;
  --syn-keyword:    #7A3FB0;
  --syn-string:     #0A7A55;
  --syn-number:     #8F5B04;
  --syn-function:   #1A5FBF;
  --syn-type:       #4F5FD6;
  --syn-punct:      #5A6675;
  --syn-path:       #0B1119;

  /* ── 阴影与发光 ─────────────────────────── */
  --shadow-sm:  0 1px 2px rgba(11, 17, 25, 0.06);
  --shadow-md:  0 8px 24px -8px rgba(11, 17, 25, 0.12);
  --shadow-lg:  0 24px 64px -16px rgba(11, 17, 25, 0.16);
  --glow-accent: 0 0 0 1px rgba(10, 122, 85, 0.28),
                  0 0 20px -6px rgba(10, 122, 85, 0.22);
  --grid-line: rgba(11, 17, 25, 0.035);
}
```

### 2.3 颜色角色映射表（可直接给 Tailwind 用）

| 角色 | 变量 | 深色 | 亮色 | 允许用途 |
| --- | --- | --- | --- | --- |
| 页面底 | `--bg-base` | `#070A0F` | `#F6F8FB` | body 背景、Hero 底层 |
| 区块底 | `--bg-surface` | `#0B1017` | `#FFFFFF` | 交替分区背景 |
| 卡片面 | `--bg-card` | `#101823` | `#FFFFFF` | 卡片、表格行、面板 |
| 浮层 | `--bg-elevated` | `#16202D` | `#FFFFFF` | 吸顶导航、下拉、弹窗 |
| 内陷 | `--bg-inset` | `#0A0E14` | `#EDF1F6` | 代码窗、终端、表单控件、引用块 |
| 主标题 | `--text-primary` | `#E9EEF7` | `#0B1119` | h1–h3、关键数字 |
| 正文 | `--text-secondary` | `#A9B4C4` | `#445061` | 段落、列表说明 |
| 次要 | `--text-tertiary` | `#8A97A8` | `#5A6675` | 元信息、脚注、标签 |
| 禁用 | `--text-disabled` | `#687484` | `#7A8593` | disabled 控件、不可用项 |
| 主强调 | `--accent` | `#35E0A1` | `#0A7A55` | 链接、焦点、关键数字、状态灯 |
| 次强调 | `--accent-2` | `#7C8CF8` | `#4F5FD6` | 渐变次停靠点、YOLO 档位、图表第二序列 |
| 极光第三色 | `--accent-3` | `#C56CF0` | `#8E2FB0` | **仅**渐变停靠点与插画，禁止单独用于文字 |

### 2.4 实测对比度验证（WCAG 2.1）

计算公式（sRGB 相对亮度）：

```
L = 0.2126·R + 0.7152·G + 0.0722·B
  其中 c = s/255, s = c≤0.04045 ? c/12.92 : ((c+0.055)/1.055)^2.4
对比度 = (L_lighter + 0.05) / (L_darker + 0.05)
```

判定标准：正文/次要文字 ≥ 4.5:1（AA）；≥24px 或 ≥19px 加粗的大字、图标、图形边界 ≥ 3:1；禁用态文字豁免但仍按 ≥3:1 校准。

**深色模式实测结果**

| 前景 / 背景 | `--bg-base`<br>`#070A0F` | `--bg-surface`<br>`#0B1017` | `--bg-card`<br>`#101823` | `--bg-elevated`<br>`#16202D` | `--bg-inset`<br>`#0A0E14` |
| --- | --- | --- | --- | --- | --- |
| `text-primary` `#E9EEF7` | **17.03** | **16.39** | **15.33** | **14.11** | **16.61** |
| `text-secondary` `#A9B4C4` | **9.45** | **9.10** | **8.51** | **7.83** | **9.22** |
| `text-tertiary` `#8A97A8` | **6.68** | **6.43** | **6.01** | **5.53** | **6.51** |
| `text-disabled` `#687484` | 3.87 | 3.70 | 3.46 | 3.26 | 3.63 |
| `accent` `#35E0A1` | **11.64** | **11.20** | **10.47** | **9.64** | **11.35** |
| `accent-2` `#7C8CF8` | **6.57** | **6.33** | **5.92** | **5.45** | **6.41** |
| `accent-3` `#C56CF0` | **6.40** | **6.16** | **5.76** | **5.30** | **6.24** |
| `success` `#3DD68C` | **10.57** | **10.17** | **9.51** | **8.76** | **10.31** |
| `warning` `#F5A524` | **9.71** | **9.35** | **8.74** | **8.05** | **9.48** |
| `danger` `#FF5A5F` | **6.49** | **6.25** | **5.85** | **5.38** | **6.34** |
| `info` `#4EA8FF` | **7.90** | **7.60** | **7.11** | **6.55** | **7.71** |
| `tier-e2e` `#35E0A1` | **11.64** | **11.20** | **10.47** | **9.64** | **11.35** |
| `tier-yolo` `#7C8CF8` | **6.57** | **6.33** | **5.92** | **5.45** | **6.41** |
| `tier-rule` `#8A97A8` | **6.68** | **6.43** | **6.01** | **5.53** | **6.51** |
| `stroke-input` `#5F748F` | 4.14 | 3.98 | 3.72 | 3.43 | 4.04 |

**亮色模式实测结果**

| 前景 / 背景 | `--bg-base`<br>`#F6F8FB` | `--bg-surface`<br>`#FFFFFF` | `--bg-card`<br>`#FFFFFF` | `--bg-inset`<br>`#EDF1F6` |
| --- | --- | --- | --- | --- |
| `text-primary` `#0B1119` | **17.81** | **18.95** | **18.95** | **16.70** |
| `text-secondary` `#445061` | **7.69** | **8.18** | **8.18** | **7.22** |
| `text-tertiary` `#5A6675` | **5.49** | **5.85** | **5.85** | **5.15** |
| `text-disabled` `#7A8593` | 3.58 | 3.75 | 3.75 | 3.30 |
| `accent` `#0A7A55` | **5.03** | **5.35** | **5.35** | **4.71** |
| `accent-2` `#4F5FD6` | **5.01** | **5.33** | **5.33** | **4.70** |
| `accent-3` `#8E2FB0` | **6.20** | **6.60** | **6.60** | **5.82** |
| `success` `#0A7343` | **5.57** | **5.92** | **5.92** | **5.22** |
| `warning` `#8F5B04` | **5.38** | **5.73** | **5.73** | **5.05** |
| `danger` `#C62A2F` | **5.23** | **5.57** | **5.57** | **4.91** |
| `info` `#1A5FBF` | **5.75** | **6.12** | **6.12** | **5.39** |
| `tier-e2e` `#0A7A55` | **5.03** | **5.35** | **5.35** | **4.71** |
| `tier-yolo` `#4F5FD6` | **5.01** | **5.33** | **5.33** | **4.70** |
| `tier-rule` `#5A6675` | **5.49** | **5.85** | **5.85** | **5.15** |
| `stroke-input` `#7F8C9B` | 3.22 | 3.43 | 3.43 | 3.02 |

**关键组合实测**

| 组合 | 深色 | 亮色 |
| --- | --- | --- |
| 主按钮文字 / 强调底 | `#04120C` / `#35E0A1` = **11.24** | `#FFFFFF` / `#0A7A55` = **5.35** |
| 主按钮 hover | `#04120C` / `#2ECB93` = **9.19** | `#FFFFFF` / `#08684A` = **6.80** |
| 次按钮文字 / 浮层底 | `#E9EEF7` / `#16202D` = **14.11** | `#0B1119` / `#EDF1F6` = **16.70** |
| 焦点环 / 卡片底（≥3:1） | `#35E0A1` / `#101823` = **10.47** | `#0A7A55` / `#FFFFFF` = **5.35** |
| 代码文字 / 内陷底 | `#E9EEF7` / `#0A0E14` = **16.61** | `#0B1119` / `#EDF1F6` = **16.70** |
| 渐变文字端点 / 页面底（≥3:1） | 11.64 / 6.57 / 6.40 | 5.03 / 5.01 / 6.20 |

**语法高亮实测**

| 令牌 | 深色 on `#0A0E14` | 亮色 on `#EDF1F6` |
| --- | --- | --- |
| `syn-comment` | `#76849A` = **4.95** | `#5A6675` = **5.15** |
| `syn-keyword` | `#A78BFA` = **7.11** | `#7A3FB0` = **5.85** |
| `syn-string` | `#35E0A1` = **11.35** | `#0A7A55` = **4.71** |
| `syn-number` | `#F5A524` = **9.48** | `#8F5B04` = **5.05** |
| `syn-function` | `#4EA8FF` = **7.71** | `#1A5FBF` = **5.39** |
| `syn-type` | `#7C8CF8` = **6.41** | `#4F5FD6` = **4.70** |
| `syn-punct` | `#8A97A8` = **6.51** | `#5A6675` = **5.15** |
| `syn-path` | `#E9EEF7` = **16.61** | `#0B1119` = **16.70** |

**结论**：所有正文级组合 ≥ 4.5:1，所有大字/图形/焦点环/输入边界 ≥ 3:1，无 FAIL 项。禁用态文字按 WCAG 豁免，但已按 ≥3:1 校准以保证可辨识。

### 2.5 降级状态机三档配色逻辑

三档必须"一眼可分"且"顺序可感"：

```
档位 1  E2E 端到端主驾    #35E0A1 (青绿)  ── 最强能力 → 用品牌主色 + 满格进度条
档位 2  YOLO 接管        #7C8CF8 (靛紫)  ── 能力下降 → 用次强调色 + 2/3 格
档位 3  纯规则兜底       #8A97A8 (钢灰)  ── 最保守 → 用中性灰，视觉上"退后"
```

**为什么规则档是灰而不是红？** 因为规则兜底是**系统正常工作**（BRIEF：模型不靠谱时系统会自己退到更笨但更稳的规则档），不是故障。红/橙只保留给真正的异常（协议版本不匹配、权限缺失、网络定位 lost）。这条区分是专业度的关键，视觉上必须清晰。

**为什么档位 2 用靛紫而不是橙？** 因为橙色在本站已被 `--warning` 占用（降级阈值告警 / 需要人工干预）。若档位 2 也用橙，用户会误以为"YOLO 接管 = 出问题了"，与事实相反。靛紫是中性偏冷，能表达"能力不同但系统健康"。

**同理，网络新鲜度四档** 独立于降级三档，用绿→蓝→橙→红的标准序列（`--fresh-live/recent/stale/lost`），因为它表达的是时间衰减而非能力等级。

**两套状态色不得混用**：降级三档永远出现在"档位"上下文中，新鲜度四档永远出现在"坐标/网络"上下文中。实现上建议各自用独立组件（`TierBadge` / `FreshnessIndicator`），不要共用一个通用的 `StatusBadge`。

### 2.6 强调色的克制使用规则

`--accent` 的出现密度上限：**同一屏内不超过 3 处显著强调**（不含焦点态与状态灯）。具体分配：

- 允许：主 CTA 按钮、链接、关键数字、当前档位指示、focus ring、复制成功提示
- 禁止：整段文字着色、卡片整块着色、图标统一上色、导航项全部高亮
- `--accent-2` 与 `--accent-3` 的唯一职责是**渐变停靠点**；单独出现时只用于图表第二数据系列

### 2.7 极光渐变定义（唯一允许的渐变）

```css
--aurora-gradient: linear-gradient(
  100deg,
  var(--accent) 0%,
  var(--accent-2) 48%,
  var(--accent-3) 100%
);
```

允许用途（仅 3 处）：
1. Hero 背景层的一层**极低透明度光晕**（`opacity ≤ 0.18`，`filter: blur(120px)`），置于背景层，不承载文字。
2. 区块之间的 1px **渐变分隔线**（`height: 1px`）。
3. 关键数字 / 品牌字标的**文字渐变**（`background-clip: text`），仅当字号 ≥ 32px 时使用（渐变中段 `#7C8CF8` 在深色底仅 6.57:1，不满足正文标准，故限制为大字）。

禁止：卡片背景渐变、按钮渐变（按钮一律实色）、大面积全屏渐变、hero 背后铺满的紫粉。

---

## 3. 字体体系

### 3.1 字体栈（零加载成本，纯系统字体）

```css
:root {
  /* 西文正文 / UI */
  --font-sans:
    -apple-system, BlinkMacSystemFont,
    "SF Pro Text", "Segoe UI", Roboto,
    "Helvetica Neue", Arial,
    "Noto Sans", sans-serif;

  /* 中文回退（紧跟西文之后） */
  --font-sans-cn:
    -apple-system, BlinkMacSystemFont,
    "SF Pro Text", "Segoe UI", Roboto,
    "Helvetica Neue", Arial,
    "PingFang SC", "Hiragino Sans GB",
    "Microsoft YaHei", "Source Han Sans SC",
    "Noto Sans SC", sans-serif;

  /* 标题（同栈但优先 SF Display / 可用不同的字重光学尺寸） */
  --font-display:
    -apple-system, BlinkMacSystemFont,
    "SF Pro Display", "Segoe UI", Roboto,
    "Helvetica Neue", Arial,
    "PingFang SC", "Hiragino Sans GB",
    "Microsoft YaHei", "Noto Sans SC", sans-serif;

  /* 等宽：所有代码、命令、数字读数、版本号、路径 */
  --font-mono:
    ui-monospace, "SF Mono", SFMono-Regular,
    "JetBrains Mono", Menlo, Monaco,
    "Cascadia Mono", "Roboto Mono",
    "Courier New", monospace;
}
```

**规则**：
- **零 Web Font**。不使用 Inter / Space Grotesk / Geist 等外链字体（避免 FOUT、避免额外请求、避免 CDN 依赖）。系统栈在 macOS 上解析为 SF Pro，在 Windows 上解析为 Segoe UI，视觉一致度可接受。
- **数字读数一律用 `--font-mono`**（`font-variant-numeric: tabular-nums`），包括 Hero 外的所有统计数字、表格数字、代码、参数值。标题数字可用 `--font-display` 但仍需 `tabular-nums`。
- 中文正文用 `--font-sans-cn`；**等宽文本内的中文注释**用 `--font-mono` + 系统中文等宽回退（`"Sarasa Mono SC"` 若可用则优先，否则接受系统中文字体）。
- 徽章 / 标签 / 章节编号使用 `--font-mono` + `letter-spacing: 0.08em` + 全大写（拉丁文）。

### 3.2 字号阶梯（9 级）

| 令牌 | font-size | line-height | letter-spacing | font-family | font-weight | 用途 |
| --- | --- | --- | --- | --- | --- | --- |
| `--text-display` | `clamp(40px, 6.5vw, 72px)` | 1.04 | `-0.03em` | display | 700 | Hero 主标题（仅 1 处/页） |
| `--text-h1` | `clamp(32px, 4.5vw, 52px)` | 1.08 | `-0.025em` | display | 700 | 区块主标题 |
| `--text-h2` | `clamp(26px, 3vw, 34px)` | 1.15 | `-0.02em` | display | 650 | 三级标题 / 大卡片标题 |
| `--text-h3` | `clamp(21px, 2.2vw, 26px)` | 1.25 | `-0.015em` | display | 600 | 特性卡标题 / 小组件标题 |
| `--text-lead` | `clamp(17px, 1.6vw, 20px)` | 1.55 | `-0.01em` | sans | 400 | Hero 副标题、区块导语 |
| `--text-body` | `16px` | 1.65 | `0` | sans | 400 | 正文 |
| `--text-sm` | `14px` | 1.6 | `0` | sans | 400 | 卡片正文、表格、辅助说明 |
| `--text-xs` | `12.5px` | 1.5 | `0.01em` | sans | 500 | 元信息、脚注、免责声明 |
| `--text-mono` | `13px` | 1.6 | `0` | mono | 400 | 代码、参数、路径 |
| `--text-mono-lg` | `15px` | 1.7 | `0` | mono | 400 | 大号代码块 |
| `--text-label` | `11px` | 1.4 | `0.1em` | mono | 600 | 全大写标签 / 章节眉标 / 档位名 |

### 3.3 H1 尺寸上限与移动端缩放策略

- **桌面端（≥1280px）H1 上限 72px**（`--text-display` 的 clamp 上界）。再大就脱离"仪表读数"气质，开始像营销落地页。
- **移动端（<640px）H1 下限 40px**，用 `clamp(40px, 6.5vw, 72px)` 线性缩放，在 390px 宽屏上约 40px。
- **缩放用 `clamp()` 的 vw 中间值，不用媒体查询硬切**。这保证 640px–1280px 区间平滑无跳变。
- **移动端行高需要额外放松**：中文标题在窄屏容易折成 3 行，标题行高从 1.04 提到 1.12（`@media (max-width: 640px) { .h1 { line-height: 1.12 } }`）。
- **Hero 标题最大宽度**：桌面 14 个中文字符宽（`max-width: 14em`），移动端 100%。Hero 标题最多 2 行，超过则必须改写文案而非缩字号。
- **禁止**用 `vw` 让 h1 在 320px 屏上小于 32px。

### 3.4 排印规则

- **中文正文行宽**：45–75 个汉字。容器正文列 `max-width: 34em`（约 68 个中文字符），超过则居左不居中。
- **数字与单位不换行**：`.num { white-space: nowrap }`，例如 `1.91ms`、`15Hz`、`13056×13056`。
- **千分位**：按 BRIEF 写作红线 6，所有 ≥1000 的数字用 `,` 分隔（`67,720`、`13056` 中的 13,056）。CSS 侧用 `font-variant-numeric: tabular-nums` 保证列对齐。
- **中英文混排**：数字/英文与中文之间留 0.15em 空隙（用 `text-spacing-trim` 或手动插入 `&nbsp;`/`<span class="latin">`）。
- **标题不用斜体、不用全大写**（除标签外）。全大写只允许出现在 11px mono 标签上。

---

## 4. 栅格与留白

### 4.1 容器与栅格

| 令牌 | 值 | 说明 |
| --- | --- | --- |
| `--container-max` | `1200px` | 主内容容器上限 |
| `--container-wide` | `1440px` | Hero / 全宽视觉区上限 |
| `--container-narrow` | `760px` | FAQ / 表单 / 单栏正文上限 |
| `--container-pad` | `24px` (桌面) / `20px` (≤640px) / `32px` (≥1536px) | 容器左右内边距 |
| `--grid-cols` | `12` | 栅格列数 |
| `--gutter` | `24px` (桌面) / `16px` (≤1024px) | 栅格列间距 |
| `--grid-margin` | `= --container-pad` | 栅格外边距 |

**断点**

| 名称 | 范围 | 布局变化 |
| --- | --- | --- |
| `xs` | `<480px` | 单列，卡片全宽，Hero 标题 40px |
| `sm` | `480–767px` | 单列 |
| `md` | `768–1023px` | 特性网格 2 列，gutter 16px |
| `lg` | `1024–1279px` | 特性网格 3 列，Hero 左右分栏 |
| `xl` | `1280–1535px` | 特性网格 4 列 |
| `2xl` | `≥1536px` | 容器 padding 32px，统计区 4 列 |

### 4.2 间距阶梯（4/8 基数）

```
--space-1:   4px
--space-2:   8px
--space-3:  12px
--space-4:  16px
--space-5:  24px
--space-6:  32px
--space-7:  40px
--space-8:  48px
--space-9:  64px
--space-10: 80px
--space-11: 96px
--space-12: 128px
```

**只允许使用阶梯中的值。** 禁止 10px / 18px / 22px / 30px 这类"看起来差不多"的值。`gap` 优先用 `--space-5`（24px）与 `--space-6`（32px）；卡片内 padding 用 `--space-5`；卡片之间 gap 用 `--space-5` 或 `--space-6`。

### 4.3 区块垂直节奏

| 场景 | 桌面 (≥1024px) | 平板 | 移动 (<768px) |
| --- | --- | --- | --- |
| Section 上下 padding | `--space-12` (128px) | `--space-10` (80px) | `--space-9` (64px) |
| 相邻 Section 之间的视觉分隔 | 1px `--stroke-subtle` 线 + 上方 128px / 下方 128px | 同 | 64px |
| 区块标题 → 下方内容 | `--space-8` (48px) | 40px | 32px |
| 区块标题组（眉标→标题→导语） | 16px / 24px | 同 | 同 |
| 卡片网格行间距 | `--space-6` (32px) | 24px | 16px |
| 段落间距 | `--space-4` (16px) | 16px | 16px |
| 列表项间距 | `--space-3` (12px) | 12px | 12px |

### 4.4 "高级感来自留白"的量化做法

这不是感觉，是可检查的四条硬规则：

1. **每屏元素 ≤ 7 个可交互/可读块。** 超了就说明该拆区块。
2. **正文列宽 ≤ 68 中文字符**（`max-width: 34em`），行高 ≥ 1.6。中文长行是"廉价感"的头号来源。
3. **区块标题上方留白 ≥ 下方留白 × 1.6。** 上 128px / 下 48px，视觉重心自然落在标题上。
4. **卡片内 padding ≥ 24px，且卡片之间 gap ≥ 24px。** 常见 SaaS 模板是 16px padding + 16px gap —— 全站禁用这个密度。
5. **Hero 内容高度 ≤ 700px**（笔记本屏必须一屏看完核心信息），Hero 上下 padding 各 96px。

**留白自检**：截图后若去掉所有元素仍觉得"空得不过分"，就是对的；若觉得"还能再塞点东西"，就是错了。

---

## 5. 组件视觉规范

### 5.0 通用令牌

```css
--radius-xs:   2px;   /* 徽章、状态点、色块 */
--radius-sm:   4px;   /* 按钮、输入框、小卡片 —— 默认 */
--radius-md:   6px;   /* 大卡片、面板、代码窗 —— 上限 */
--radius-pill: 999px; /* 仅状态点 / 极小标签，禁止用于卡片 */

--border-hairline: 1px solid var(--stroke-default);
--border-strong:   1px solid var(--stroke-strong);
--border-focus:    1px solid var(--stroke-focus);
```

**三态规范（所有可交互元素通用）**

| 态 | 变化 | 时长 / 缓动 |
| --- | --- | --- |
| Default | 基线 | — |
| Hover | 描边 `--stroke-default`→`--stroke-strong`；背景 +4% 亮度；**位移仅 `translateY(-1px)`** | 160ms / `cubic-bezier(0.2, 0, 0, 1)` |
| Focus-visible | 2px `--stroke-focus` 外环（`box-shadow: 0 0 0 2px var(--bg-base), 0 0 0 4px var(--stroke-focus)`），**不移除原生 outline** | 120ms / linear |
| Active | `translateY(0)` + `scale(0.985)` + 描边回到 `--stroke-default` | 90ms / `cubic-bezier(0.4, 0, 1, 1)` |
| Disabled | `opacity: 0.45`（深色）/ `0.5`（亮色），`cursor: not-allowed`，**移除 hover 效果** | 无过渡 |

**焦点环必须对深浅两套背景都可见**：深色用 `--stroke-focus`（#35E0A1），亮色用 #0A7A55。焦点环外圈用 `--bg-base` 填充形成 2px 间隙，保证在任何背景上都不与元素描边混在一起。

### 5.1 导航栏

```
高度：          64px（桌面）/ 56px（移动）
位置：          sticky top: 0, z-index: 100
背景（顶部）：   transparent
背景（滚动后）：backdrop-filter: blur(20px) saturate(160%)；
                 background: color-mix(in srgb, var(--bg-base) 78%, transparent);
边框：          底部 1px，滚动前 transparent → 滚动后 var(--stroke-subtle)
过渡：          background-color 240ms, border-color 240ms, backdrop-filter 240ms
```

- **滚动切换用 IntersectionObserver 打在页面顶部的 1px 哨兵元素上**（`threshold: 0`），不要绑 `scroll` 事件。
- 滚动后加 `box-shadow: 0 1px 0 0 var(--stroke-subtle)`，不加投影。
- Logo：文字标 `AuroraDrive`，`--font-display` 700，18px，`letter-spacing: -0.02em`。左侧可加 20×20 极光标记 SVG（一个 3px 圆点 + 20° 弧线，**不用图标字体**）。
- 导航项：14px，`--text-secondary`；hover → `--text-primary`（160ms）；当前页 → `--text-primary` + 下方 2px `--accent` 指示条（宽度 = 文字宽度，`scaleX` 从 0 到 1，200ms `cubic-bezier(0.2,0,0,1)`）。
- 右侧：主题切换图标按钮（36×36，`--radius-sm`，hover 显示 `--bg-elevated`）+ 主 CTA 按钮（small 尺寸，32px 高）。
- 移动端：汉堡按钮 → 右侧抽屉（`--bg-elevated`，左边框 1px `--stroke-default`，宽度 `min(88vw, 360px)`），从右滑入 280ms `cubic-bezier(0.16, 1, 0.3, 1)`，背景 `rgba(7,10,15,0.6)` 遮罩 240ms 淡入。抽屉内导航项 44px 触控高。

### 5.2 Hero

**布局**：桌面 `lg` 以上为**左右分栏**（左文 5 列 / 右视觉 7 列，gap `--space-8`）；`md` 及以下为**上下**（文案在上、视觉在下）。**禁止居中排版**（居中大标题是模板默认解法）。

**主标题**
- `--text-display`（clamp 40→72px），`--font-display` 700，`--text-primary`
- 允许对**其中一个关键词**使用 `--aurora-gradient` 文字渐变（`background-clip: text; -webkit-text-fill-color: transparent`），仅当字号 ≥ 32px
- `max-width: 14em`，`margin-bottom: var(--space-5)`

**副标题**
- `--text-lead`，`--text-secondary`，`max-width: 46em`，`margin-bottom: var(--space-8)`

**双 CTA**
```
主按钮：height 48px, padding 0 24px, --radius-sm, bg --accent, color --text-inverse,
        font-weight 600, 15px
        hover: bg --accent-hover, translateY(-1px), box-shadow --glow-accent
        active: translateY(0), scale(0.985)
次按钮：height 48px, padding 0 24px, --radius-sm,
        bg transparent, border 1px --stroke-strong, color --text-primary
        hover: bg --bg-elevated, border-color --accent
```
- 两个按钮 gap `--space-3`（12px），移动端垂直堆叠 gap `--space-3`，按钮宽度 100%。
- **按钮文案禁止双 CTA 并列时都是"开始使用"这类模糊词**：主按钮必须是具体动作（对应 BRIEF 第七节 Quick Start 的 `git clone`），次按钮是次要路径（看架构 / 看数据）。

**背景视觉层（4 层，自下而上）**

| 层 | 内容 | 实现 |
| --- | --- | --- |
| L0 | `--bg-base` 纯色 | 底 |
| L1 | 极光光晕 | `--aurora-gradient` + `filter: blur(120px)` + `opacity: 0.18`，尺寸 120%×60%，定位右上 |
| L2 | 仪表网格底纹 | 双向 `repeating-linear-gradient`，`--grid-line`，格 48px，`mask-image: radial-gradient(ellipse at 50% 0%, black, transparent 72%)` 渐隐 |
| L3 | 颗粒噪点 | 内联 SVG `feTurbulence`，`opacity: 0.035`，`mix-blend-mode: overlay`，尺寸 160×160 平铺 |

- **AI 生成图不得作为 Hero 背景铺底再压文字**（LAYOUT GUIDELINES 明令）。AI 插画必须放在**独立的容器帧内**，与文字是**兄弟关系**而非叠加关系。
- 右侧视觉位：放一个"实时管线示意"的**代码/图形构件**（管线图 + 状态灯 + 数字），不是放一张氛围插画。真正的插画放在下方"架构"区块。
- **免责角标（BRIEF 强制）**：Hero 右下角固定一枚 `--radius-xs` 描边小徽标，`--text-xs`，`--text-tertiary`，宽度 ≤ 320px，左侧一个 `--warning` 色 8px 竖条。文案用 BRIEF 第六节原文。

### 5.3 功能特性网格卡片

```
背景：   --bg-card
边框：   1px solid --stroke-default
圆角：   --radius-md (6px)
padding: var(--space-5) (24px)
阴影：   无（默认）；hover 时 --shadow-md
```

**卡片内部结构（从上到下）**
1. **序号 / 标记**：`--text-mono` 11px，`--text-tertiary`，形如 `01` `02`。这是仪表盘语汇，强化"分节列举"而非"卖点罗列"。
2. **图标**（可选）：24×24，1.5px 线性 SVG，`stroke: --accent`，**仅在图标承载独立含义时使用**（如"抓屏"/"推理"/"注入"），不用装饰性图标。
3. **标题**：`--text-h3`，`--text-primary`
4. **正文**：`--text-sm`，`--text-secondary`，行高 1.6，**每张卡必须包含一个具体数字或机制**（BRIEF 红线 1）
5. **底部元信息**（可选）：`--text-mono` 12px，`--text-tertiary`，例如 `OpticalFlowBridge.swift:88`

**Hover 三态**
- 描边 `--stroke-default` → `--accent-line`（200ms）
- `translateY(-2px)`
- `box-shadow: --shadow-md`
- **禁止** hover 时缩放、禁止改变背景色（会闪）、禁止描边加粗到 2px（会引起 1px 布局抖动，用 inset box-shadow 模拟）

**网格**：`md` 2 列 / `lg` 3 列 / `xl` 4 列，`gap: var(--space-6)`。卡片高度用 `align-items: stretch` 但内部内容顶部对齐（不要 vertical-center）。

**避免**：不要做成"每卡一个图标 + 一个标题 + 一行字"的均匀三行模板 —— 那正是 AI 味来源。差异化做法：**部分卡片改为横向条目**（左侧 40% 是数字/图形，右侧是文字），与常规卡片混排，形成节奏。

### 5.4 数据统计区

**这是全站最重要的视觉资产。数字必须看起来像仪表读数。**

```
布局：   4 列（xl）/ 3 列（lg）/ 2 列（md）/ 1 列（xs）
分隔：   列间 1px 竖线 --stroke-subtle（不用卡片包裹）
外框：   上下各一条 1px --stroke-default，组成一条"仪表横条"
```

**单个指标规格**

| 元素 | 规格 |
| --- | --- |
| 数值 | `--font-mono`, `clamp(34px, 4vw, 56px)`, `font-weight: 600`, `font-variant-numeric: tabular-nums`, `letter-spacing: -0.03em`, `--text-primary` |
| 单位 | 同字体，`0.5em` 大小，`--text-tertiary`，与数值之间 0.15em（如 `1.91ms`、`15Hz`、`664`） |
| 标签 | `--text-label`（11px mono 全大写，`letter-spacing 0.1em`），`--text-tertiary` |
| 补充说明 | `--text-xs`，`--text-tertiary`，1 行以内 |

- **单位不参与滚动计数**，只让主数值滚动（避免 `ms` 忽大忽小）。
- **千分位与等宽对齐**：所有数值必须 `tabular-nums`，否则滚动时数字宽度变化导致抖动。
- **滚动计数动效**：
  - 触发：IntersectionObserver，`threshold: 0.4`，进入视口触发一次（`once: true`），**不因上滚重播**
  - 时长：**1200ms**，缓动 `cubic-bezier(0.16, 1, 0.3, 1)`（easeOutExpo 类），即前 40% 时间走完 80% 数值
  - 小数处理：保留原小数的位数（`1.91` 不能滚成 `2`），用 `toFixed(digits)`
  - 千分位：每帧格式化
  - 起始值从 0 开始，**不做"从 -100 飞入"** 这类装饰
  - `prefers-reduced-motion` 下直接呈现终值（见 §6.7）
- **对比数字的呈现方式**（BRIEF 有 `19.3% → 5.4%`、`612→664` 这类前后对比）：用**两段并置**（旧值 `--text-tertiary` + 箭头 + 新值 `--text-primary`），不要做成动画对撞。

### 5.5 代码 / 命令展示窗口

```
背景：   --bg-inset
边框：   1px solid --stroke-default
圆角：   --radius-md (6px)
阴影：   --shadow-md（可选，浮出页面感）
```

**结构（从上到下）**
1. **标题栏**（height 40px，背景 `--bg-card`）：
   - 左侧：三个 8px 圆点（`--stroke-strong` 填充，无红黄绿，避免拟物 macOS 红绿灯 —— 那是"复制 VSCode"的味道）
   - 中左：文件名 `--text-mono` 12px，`--text-tertiary`（如 `run.sh`）
   - 右侧：**复制按钮** 32×28，`--radius-xs`，`--text-mono` 12px
2. **代码区**：`--font-mono`，`--text-mono-lg`（15px），行高 1.7，`padding: var(--space-5)`，横向可滚动（`overflow-x: auto`），**不换行**（代码换行会破坏可复制性）
3. **底部状态条**（可选，height 32px，背景 `--bg-card`）：显示运行状态，如 `$ ./run.sh --status  →  environment OK`

**语法高亮**：使用 §2.4 表中的 `--syn-*` 变量。至少区分：注释、字符串、数字、关键字、函数名、路径、提示符 `$`。

**复制按钮交互**
- 默认：图标 + "复制"（`--text-tertiary`）
- hover：`--text-primary`，背景 `--bg-elevated`
- 点击后：图标变为 ✓ 或"已复制"，`--success` 色，**保持 1600ms** 后用 200ms 淡回默认
- **必须同时写剪贴板**（`navigator.clipboard.writeText`）并提供 `document.execCommand('copy')` 回退
- **必须有 `aria-live="polite"` 的隐藏文本**宣告"已复制"，因为图标变化对读屏用户不可感知
- 失败态：文案变"复制失败"，`--danger` 色，2000ms 后恢复

**快速开始区块**（BRIEF 第七节逐字内容）：命令以 `$` 提示符开头，`$` 用 `--syn-prompt` 色，后面的命令用 `--text-primary`。注释行用 `--syn-comment`。代码块下方用 `--text-xs` `--text-tertiary` 列出环境要求。

### 5.6 定价方案对比表

**布局**
- 桌面：三列并排方案卡（`--bg-card`，`--radius-md`，1px 描边），下方一个**全宽功能对比表**
- 移动：方案卡纵向堆叠，对比表横向滚动（首列 sticky，`position: sticky; left: 0`，背景 `--bg-card`，`z-index: 1`）

**推荐方案卡**
- 边框 1px `--accent`（不是 2px，不是发光大阴影）
- 顶部一枚 `--radius-xs` 标签 `推荐`，`--accent-subtle` 底 + `--accent` 文字，`--text-label` 字体
- 卡顶有一条 2px `--aurora-gradient` 细线（高度 2px，全宽）
- 其余卡片保持 1px `--stroke-default`

**对比表**
- 表头 `--text-label`（11px mono 全大写），`--text-tertiary`
- 行标签 `--text-sm` `--text-secondary`，左对齐
- 单元格：`✓` 用 `--success`（16px SVG 描边，不可用 emoji ✓）、`✕` 用 `--text-disabled`、`—` 用 `--text-tertiary`
- 行高 48px（`--space-9`），行分隔 1px `--stroke-subtle`
- 斑马纹：**不用背景色斑马**，只用 `--stroke-subtle` 分隔线（更工程化）
- 悬停行：整行背景 `--bg-surface`

### 5.7 FAQ 手风琴

```
容器：  --bg-card（或透明），1px --stroke-default 描边，--radius-md
条目：  上下 1px --stroke-subtle 分隔（最后一个无下边框）
触发器：height 56px，padding 0 var(--space-5)，全宽 flex
        问题文字 --text-h3 (21-26px) → 实际 FAQ 用 --text-body 16px 500
图标：  12px 箭头/chevron，--text-tertiary，hover → --accent
```

- **展开动画**：`grid-template-rows: 0fr → 1fr` 技巧（CSS 侧），配合 `overflow: hidden`，时长 **260ms**，`cubic-bezier(0.4, 0, 0.2, 1)`。这样高度自动适配，无需测量。
- 箭头旋转 180°，260ms，`cubic-bezier(0.4, 0, 1, 1)`。
- 展开后答案区 `--text-sm` `--text-secondary`，`padding-bottom: var(--space-5)`。
- **一次只展开一项**（可选但推荐），切换时前一项收起与后一项展开**重叠 60ms**，避免"先合再开"的顿挫。
- 语义：`<button aria-expanded>` + `<div role="region" aria-labelledby>`。
- FAQ 容器 `max-width: var(--container-narrow)`（760px）。

### 5.8 团队成员卡

**不做圆形头像卡片堆砌。** 用**横向条目**：

```
布局：  flex row, gap --space-5, align-items: start
头像：  72×72, --radius-sm (4px) —— 方形微圆角，不用圆形
        1px --stroke-default 边框
        失败占位：--bg-inset + --text-mono 姓名首字母，--text-tertiary
姓名：  --text-h3 (21px), --text-primary
角色：  --text-mono 12px, --accent, letter-spacing 0.04em
简介：  --text-sm, --text-secondary, max-width 42em
```

- **头像用方形微圆角**，避免"团队页 = 圆形头像 + 圆角卡"的模板感。
- 移动端：头像缩到 56×56，纵向堆叠。
- 不做 hover 上浮（团队成员不是可点击目标就不该有 hover 态）。

### 5.9 用户评价卡

```
背景：   --bg-card
边框：   1px --stroke-default
圆角：   --radius-md (6px)
padding: var(--space-6) (32px)
```

**结构**
1. **引号标记**：`--text-label` 尺寸的 `"` 字符，`--accent`，`--text-tertiary`（不用大号引号图标）
2. **正文**：`--text-body` 16px，行高 1.7，`--text-primary`
3. **分隔**：1px `--stroke-subtle`
4. **署名行**：`flex row`，头像 40×40（`--radius-xs`），姓名 `--text-sm` 600 `--text-primary`，身份 `--text-xs` `--text-tertiary`

**规则**
- **不使用星级评分**（虚构评分违背 BRIEF 诚实原则，也不符合工程气质）。如果需要表达强度，用 `--text-mono` 的具体事实（"用了 3 周，跑完 664 个节点路线"）。
- 卡片顶部**不加彩色条**（避免彩虹卡）。
- 引用超过 4 行时截断 + "阅读全文"链接。
- 网格：`lg` 3 列 / `md` 2 列 / 移动 1 列，`gap: var(--space-6)`。

### 5.10 联系表单

**布局**：`--container-narrow`（760px）单列居中（表单是例外，可以用居中窄列），字段垂直堆叠 `gap: var(--space-5)`。

**字段规格**
```
label:  --text-label (11px mono 全大写), --text-secondary, margin-bottom --space-2
        必填项后加 --accent 的 "*"
input:  height 48px, padding 0 var(--space-4), --radius-sm
        bg --bg-inset, border 1px --stroke-input, color --text-primary
        placeholder --text-tertiary
textarea: min-height 140px, padding var(--space-4), 同上但垂直 padding
```

**状态机**

| 态 | 边框 | 附加 | 时长 |
| --- | --- | --- | --- |
| Default | `--stroke-input` (1px) | 无 | — |
| Hover | `--stroke-strong` | 无 | 120ms |
| Focus | `--stroke-focus` (1px) | `box-shadow: 0 0 0 3px var(--accent-subtle)` | 140ms |
| Invalid | `--danger` (1px) | 下方错误文字 `--text-xs` `--danger` + 左侧 2px `--danger` 竖条 | 140ms |
| Valid | `--stroke-input` | 右侧 16px `--success` 对勾 SVG | 140ms |
| Disabled | `--stroke-subtle` | `--text-disabled` | — |
| Submitting | — | 按钮内联 spinner（1.5px 描边圆环，1s/圈旋转）+ 文案改"发送中…"，按钮禁用 | — |
| Success | — | 整块表单替换为成功态面板：16px `--success` 图标 + 标题 + 说明；**面板淡入 240ms**（不做高度跳变，用 `min-height` 预留） | 240ms |

**校验时机**
- **失焦时校验**（`onBlur`），**输入时清除错误**（`onChange` 清 error，不重新校验，避免边打字边报红）
- 提交时校验全部字段，不通过则聚焦第一个错误字段并滚动到它（`scrollIntoView({ behavior: 'smooth', block: 'center' })`）
- 错误信息用 `aria-describedby` 关联，`aria-invalid="true"` 标记字段
- 提交按钮宽度固定（避免文案变化导致按钮跳动）

### 5.11 页脚

```
背景：   --bg-surface（比页面底略亮一档，或反之用 --bg-base + 顶部 1px 线）
顶部：   1px --stroke-default 横线（full-bleed）
上区：   4 列（品牌 + 3 组链接），gap --space-8
下区：   1px --stroke-subtle 分隔线 + 版权 / 许可证 / 社交
```

**品牌列**
- Logo + 一句话定位（≤ 24 字，`--text-sm` `--text-secondary`）
- **许可徽章**：`--font-mono` 11px，`--radius-xs`，1px `--stroke-default` 描边，`--text-tertiary`，写 `GPL-3.0-or-later`

**链接组**
- 组标题 `--text-label`（11px mono 全大写）`--text-tertiary`
- 链接 `--text-sm` `--text-secondary`，hover → `--text-primary` + 下划线
- 组间距 `--space-8`

**底部区**
- 版权 `--text-xs` `--text-tertiary`
- 许可证与致谢链接

**免责与合规区（BRIEF 强制 + 红线 4）**
- 单独一块，`--bg-inset` 底，1px `--warning` 左边框（3px），`--radius-sm`，`padding: var(--space-4)`
- 标题 `--text-label` "使用须知 / DISCLAIMER"
- 正文 `--text-xs` `--text-secondary`，用 BRIEF 第六节**原文**
- **致谢区块单列**：列出 MaaNTE（AGPL-3.0）、MetalGoose（GPL-3.0）、nteguide.com，每项含用途 + 许可证；**MaaNTE 的 AGPL 传染性说明必须写出**（红线 4），措辞中性不作辩解

### 5.12 AI 配图使用规则

1. **AI 图不做背景填充 + 压文字**（LAYOUT GUIDELINES 明令）。图与文字必须是**兄弟容器**，不是叠加。
2. **每张 AI 图必须放在独立容器帧内**，容器有 1px `--stroke-default` 描边 + `--radius-md` 圆角 + `--bg-inset` 底，图片 `object-fit: cover`。
3. **不出现真实游戏画面、不出现人脸、不出现可辨识的 UI 截图**。风格锚点见 §8。
4. **图片本身必须与主题配色协调**：统一要求"深色底 + 青绿/靛紫渐变"，即使在亮色模式下也保留深色底图（作为"暗色仪器"的视觉锚点），靠 1px 描边与 `--radius-md` 与页面区分。**亮色模式下图片不加蒙版变亮**。
5. **配图不承载唯一信息**。任何关键事实都必须有文字/数字冗余表达。
6. **统一裁切比例**：Hero 视觉 `4:3`、区块插图 `16:9`、小图标块 `1:1`、页脚装饰 `21:9`。生成时按此比例出图，避免二次裁切。
7. **加载**：`loading="lazy"` + `decoding="async"` + 明确 `width/height` 防止 CLS；首屏 Hero 图 `fetchpriority="high"` + preload。
8. **无障碍**：每张图必须有 `alt`，描述其传达的概念而非"装饰图片"。

---

## 6. 动效规范

### 6.1 动效令牌

```css
/* 时长阶梯 */
--dur-micro:   120ms;   /* 颜色、透明度、小图标 */
--dur-fast:    160ms;   /* hover、按钮按下、复制反馈 */
--dur-base:    240ms;   /* 展开/收起、抽屉、下拉 */
--dur-element: 420ms;   /* 单元素入场 */
--dur-section: 640ms;   /* 区块入场（含子元素错峰） */
--dur-page:    480ms;   /* 页面过渡（退出 + 进入合计） */

/* 缓动曲线 */
--ease-out:    cubic-bezier(0.16, 1, 0.3, 1);    /* 进场：快出慢收，主力 */
--ease-in:     cubic-bezier(0.5, 0, 0.9, 0.5);    /* 出场：慢入快出 */
--ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);   /* 位置互换、双向 */
--ease-linear: linear;                            /* 进度条、spinner */
```

**选择规则**
| 场景 | 曲线 | 理由 |
| --- | --- | --- |
| 元素进场 | `--ease-out` | 快进慢停，元素"落位"感 |
| 元素出场 | `--ease-in` | 加速离场，不拖沓 |
| 双向变化（hover 往返、箭头旋转） | `--ease-in-out` | 往返不突兀 |
| 手风琴展开 | `cubic-bezier(0.4, 0, 0.2, 1)` | 匀速偏 ease，内容展开不跳跃 |
| 数字滚动 | `--ease-out` | 末段减速，读数像仪表归位 |
| 页面过渡 | 出场 `--ease-in` / 进场 `--ease-out` | 见 §6.6 |
| Spinner / 进度 | `linear` | 匀速才有机械感 |

**时长律**：位移类动效时长与位移量正相关，但**位移越大不一定时长越长** —— 位移 > 32px 的必须搭配 `--ease-out` 且时长 ≥ 320ms，否则会显得"弹出来"而非"浮现"。

### 6.2 滚动渐入（Scroll Reveal）

**触发机制**
- `IntersectionObserver`，`threshold: 0.15`，`rootMargin: "0px 0px -10% 0px"`（元素进入视口底部 10% 内即触发，避免"已经滚过头了才出现"）
- `once: true`（触发后 unobserve），**上滚不重播**
- 不支持 IO 的浏览器直接呈现最终态（`opacity: 1`）

**参数**
```
位移：    translateY(20px) → 0        （移动端 16px）
透明度：  0 → 1
时长：    --dur-section (640ms)
缓动：    --ease-out
组合：    opacity + transform 在同一次 transition 中完成（不要拆成两段）
```

**错峰延迟（stagger）**
- 同一区块内的同级元素：`delay = index * 70ms`
- **最大总延迟 280ms**（超过 4 个元素后，后续元素统一用 `min(index, 4) * 70ms`，防止长列表末尾等太久）
- 区块容器本身：`delay: 0`
- 相邻区块之间不做联动延迟（滚动本身已产生时间差）

**分方向**
- 从下往上进入：`translateY(20px) → 0`
- 左侧栏 / 侧边元素：`translateX(-16px) → 0`
- **禁止**从屏幕外飞入、从下方大距离冲入、缩放弹出（`scale: 1.05 → 1`）、旋转入场

**Reduced motion 降级**：直接 `opacity: 1, transform: none`，无时长（§6.7）。

### 6.3 悬停反馈规范

| 元素 | 悬停变化 | 时长 |
| --- | --- | --- |
| 按钮（主） | `translateY(-1px)` + `--glow-accent` 阴影 + bg `--accent-hover` | 160ms |
| 按钮（次） | bg → `--bg-elevated`，边框 → `--accent-line` | 160ms |
| 卡片 | `translateY(-2px)` + 边框 → `--accent-line` + `--shadow-md` | 200ms |
| 文字链接 | 颜色 → `--accent`，下划线从左展开（`background-size: 0% → 100%`，220ms） | 160ms |
| 导航项 | 颜色 → `--text-primary` | 160ms |
| 复制按钮 | 文字 → `--text-primary` + bg `--bg-elevated` | 120ms |
| 表格行 | 背景 → `--bg-surface` | 120ms |
| 主题切换按钮 | 图标旋转 180°（`rotate`）or 图标交叉淡化 | 240ms |
| 任何图标按钮 | 背景 `--bg-elevated` + 图标 `scale(1.06)` | 120ms |

**通用红线**
- 悬停位移**不超过 2px**。
- 悬停**不得**改变元素尺寸（会引起兄弟元素抖动）。
- 悬停**不得**改变布局属性（width/height/padding）—— 只用 transform / box-shadow / 颜色。
- 触屏设备（`@media (hover: hover)` 保护）不挂 hover 效果。
- 悬停效果**不得**降低文字对比度（例如把正文变灰）。

### 6.4 加载与骨架

- 页面级：顶部 2px `--accent` 进度条，`transform: scaleX()` 由路由 `useNavigation().state === 'loading'` 驱动，`--dur-base`。
- 区块级：不用灰骨架屏闪烁（skeleton shimmer 是模板味）。改用**静态 `--bg-inset` 占位块 + `--text-mono` 12px 文本占位**（如 `⟨ loading route_graph.json ⟩`），与仪表气质一致。
- 数据加载中（AI 面板流式对话等）：三点逐个亮起，每点 240ms 循环，间隔 120ms，**只在真实等待时使用**。

### 6.5 元素级动效细则

- **复制成功**：图标切换 + 文字变化，160ms 淡入，**保持 1600ms**，再 200ms 淡回。
- **手风琴**：260ms，`cubic-bezier(0.4, 0, 0.2, 1)`。
- **抽屉/移动菜单**：滑入 280ms `--ease-out`，遮罩淡入 240ms，关闭时反向且更快（200ms `--ease-in`）。
- **状态灯（脉冲）**：`opacity: 1 → 0.35 → 1`，**1600ms**，`--ease-in-out`，`infinite`。仅用于表达"运行中"。**这是全站唯一允许的无限循环动效**。
- **降级档位切换**：档位指示条宽度变化 320ms `--ease-out` + 颜色渐变 320ms `linear`（颜色用 linear 避免过冲）。
- **Toast/通知**：从右侧滑入 240ms `--ease-out`，停留 3200ms，淡出 200ms `--ease-in`。

### 6.6 页面过渡动画方案（重点）

**目标**：站内多页切换必须"过渡极好" —— 用户感知到的是**同一部机器的不同面板**，而不是两个网页互相替换。

**技术选型**
- **主方案：Framer Motion `AnimatePresence` + `react-router-dom` 的 `useLocation`**。理由：项目已装 framer-motion 14；`AnimatePresence` 可精确控制出场/进场的时间轴关系，比 View Transitions API 更可控（后者不支持"新页面先入场再旧页面出场"的编排，只有一个全局快照）。
- **增强方案：View Transitions API 作为降级/增强的第三条路径**，当浏览器支持 `document.startViewTransition` 且用户未开启 reduced-motion 时启用同源视图过渡（用于带 `view-transition-name` 的元素，例如 Logo、主题按钮、代码窗口标题栏保持"同一元素"的连续性）。**两者不叠加使用**：`AnimatePresence` 是主路径；View Transitions 仅在不支持 framer-motion 的场景（或仅对少量具名元素）启用，避免双重动画打架。

**核心结构（伪代码级描述，Phase 3 照做）**

```
<AnimatePresence mode="wait" initial={false}>
  <motion.main
    key={location.pathname}
    initial={{ opacity: 0, y: 12 }}
    animate={{ opacity: 1, y: 0 }}
    exit={{ opacity: 0, y: -8 }}
    transition={{
      enter: { duration: 0.36, ease: [0.16, 1, 0.3, 1] },
      exit:  { duration: 0.20, ease: [0.5, 0, 0.9, 0.5] },
    }}
  />
</AnimatePresence>
```

**出场 → 进场的衔接叙事（连贯性的核心）**

| 阶段 | 时长 | 发生什么 | 感知 |
| --- | --- | --- | --- |
| T0 | 0ms | 用户点击链接。**立即**锁定滚动位置并把新页面 `scrollTop` 归零（见下） | 无闪烁 |
| T0 | 0ms | 旧页面开始 exit：`opacity 1→0`（200ms，`--ease-in`），`y 0→-8px`（轻微向上"离场"） | 旧页面上浮淡出 |
| T0+200ms | — | 旧页面完全卸载。`mode="wait"` 确保**同一时刻只有一版 DOM**，不会出现两层内容叠加导致的"重影" | 无叠加 |
| T0+200ms | — | 新页面挂载，`initial={{opacity:0, y:12}}`，开始 animate（360ms，`--ease-out`） | 新页面从下方 12px 淡入上浮 |
| T0+560ms | — | 动画完成，`y:0, opacity:1` | 稳定 |

**总时长 560ms**（退出 200 + 进入 360）。这个配比是刻意的：**出场短、进场长**。出场快是为了"响应感"（用户点击后立刻有反馈），进场慢是为了"落位感"（新页面从容就位）。若反过来（出场慢、进场快），整个切换会显得拖沓。

**关键：为什么 `mode="wait"` 而不是 `"popLayout"`**
`popLayout` 会让新旧页面同时存在于 DOM，新页面"顶开"旧页面 —— 那会产生高度突变与滚动跳动。`mode="wait"` 强制串行，配合下面的滚动处理，切换是干净的。

**滚动位置处理（最容易做错的地方）**

```
1. 在 <Layout> 顶层监听 location.pathname 变化
2. 变化发生的瞬间（useLayoutEffect，早于浏览器绘制）：
     window.scrollTo({ top: 0, left: 0, behavior: 'instant' })
3. 关键：使用 behavior: 'instant'，不要 'smooth'
   —— smooth 会让旧页面在退出动画期间缓慢上滚，
     用户会看到"页面一边淡出一边滑动"，是典型的廉价感
4. 浏览器原生 scrollRestoration 设为 'manual'，
   由我们接管，避免浏览器在 popstate 时做自己的异步恢复（会与动画打架）
5. 带 hash 的跳转（如 /docs#install）：等进场动画结束（delay 360ms）后再
   scrollIntoView({ behavior: 'smooth', block: 'start' })，并给目标加
   scroll-margin-top: 96px（避开吸顶导航）
6. 浏览器前进/后退（POP）时，若需要恢复历史滚动位置，
   在 location.key 上挂一个 Map 缓存（key → scrollY），
   在进场动画结束后用 behavior: 'instant' 恢复。
   注意：恢复用 instant，避免与进场动画的位移叠加成"双重运动"
```

**避免闪烁的 6 条硬规则**

1. **新页面背景色必须与旧页面一致**。页面根容器用 `background: var(--bg-base)`，不随路由改变。否则退场最后一帧与进场第一帧之间会闪一下白/黑。
2. **绝不在 `initial` 上设 `scale`**。`scale` 会在亚像素渲染时产生边缘模糊与抖动，只用 `opacity` + `translateY`。
3. **进场位移 ≤ 16px**。超过 16px 的入场会读作"页面飞进来"而非"切换"。
4. **路由切换期间锁死 `scroll-behavior`**。全局 `html { scroll-behavior: smooth }` 会与 `instant` 冲突 —— 页面根不要设 smooth，只在明确需要平滑滚动的地方（锚点、回到顶部按钮）用 `behavior: 'smooth'`。
5. **首屏不做入场动画**。`AnimatePresence` 必须设 `initial={false}`，否则刷新页面时整页会从下往上飘 —— 这是"过渡极好"最常见的破坏方式。
6. **不做交叉淡入（crossfade）**。旧页淡出 + 新页淡入在同一位置叠加 = 视觉上"两层半透明重影"，是网页模板感的来源。`mode="wait"` 串行是正解。

**共享元素的连续性（可选增强）**

如果某个元素在两个路由都存在（如 Logo、主题切换按钮、页脚），给它设 `view-transition-name`（配合 View Transitions API），或在 Framer Motion 中用 `layoutId` 做共享布局过渡。**建议只对 Logo 与主题按钮做**，其他元素不要 —— `layoutId` 用多了会产生诡异的滑行动画。

**移动端与降级**
- 移动端把进场时长压到 **280ms**、位移减到 **8px**（小屏上大幅位移容易晕）。
- 不支持 View Transitions 的浏览器：只走 Framer Motion 路径，功能完整。
- JS 尚未加载（首屏白屏期）：在 `index.html` 内联一段最小 CSS，保证 `--bg-base` 立即生效，避免"白闪一下再变黑"。这是最重要的一条防闪烁措施。

### 6.7 `prefers-reduced-motion` 降级策略

**判定**：`window.matchMedia('(prefers-reduced-motion: reduce)').matches`，配合 framer-motion 的 `useReducedMotion()`。

**降级映射表**

| 动效 | 正常 | Reduced motion |
| --- | --- | --- |
| 滚动渐入 | opacity + translateY(20px)，640ms | **仅 opacity 0→1，200ms**，无位移 |
| 元素 hover 位移 | translateY(-1/-2px) | **取消位移**，仅保留颜色/阴影变化 |
| 数字滚动计数 | 1200ms 递增 | **直接呈现终值**，无动画 |
| 页面过渡 | 退出 200ms + 进场 360ms | **单次 opacity 交叉，160ms**（无位移，无 `mode="wait"` 等待串行，用 `mode="popLayout"` 或直接 `instant` 切换） |
| 状态灯脉冲 | 1600ms infinite | **常亮**（opacity 1），不再循环 |
| 手风琴展开 | 260ms 高度动画 | **即时展开**（0ms）或 100ms opacity |
| 抽屉滑入 | 280ms 滑入 | **即时出现** |
| 视差 / 任何 transform 动画 | 正常 | **完全禁用** |
| View Transitions API | 启用 | **禁用**（`document.startViewTransition` 不调用） |
| 复制成功提示 | 淡入淡出 | **即时切换文案** |
| 锚点平滑滚动 | `behavior: 'smooth'` | `behavior: 'instant'` |

**实现要点**
- CSS 侧同步写媒体查询，覆盖 Tailwind 生成的 `transition-*`：
  ```css
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      animation-duration: 0.01ms !important;
      animation-iteration-count: 1 !important;
      transition-duration: 0.01ms !important;
      scroll-behavior: auto !important;
    }
  }
  ```
- **但不要用 `!important` 干掉所有过渡** —— 上面的 0.01ms 方案会让 hover 的背景色瞬切，这没问题；但页面过渡的 opacity 淡入淡出若被压成 0.01ms，会变成硬切 —— 对于 reduced motion 用户这是**可接受甚至更好**的（他们要的就是无运动）。若想保留 160ms 的淡入淡出，需要在 JS 侧用 framer-motion 的 `useReducedMotion()` 显式覆盖（该 hook 的 duration 不受 CSS `!important` 影响，因为 framer-motion 用 JS 驱动 transform/opacity）。
- **提供一个"减少动效"开关**吗？不必额外加 UI 开关，`prefers-reduced-motion` 覆盖 95% 的需求。但**主题切换**按钮应始终可用（不是动效）。

---

## 7. 深色模式策略

### 7.1 方案选择

**采用：`data-theme` 属性 + class 双写的手动切换，以系统偏好为默认，用户可覆盖。**

```html
<!-- index.html 内联（防闪烁，必须在 <head> 最前） -->
<script>
  (function () {
    var t = localStorage.getItem('aurora-theme');
    if (t !== 'light' && t !== 'dark') {
      t = matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    }
    document.documentElement.dataset.theme = t;
    document.documentElement.classList.toggle('dark', t === 'dark');
  })();
</script>
```

- **不是纯 `prefers-color-scheme`**：用户主动切换后如果仅跟随系统，会在系统变化时被"打回"，这是明确的体验缺陷。必须持久化选择。
- **不是纯 class 切换**：`data-theme` 作为**语义化主开关**（Tailwind v4 用 `[data-theme="dark"]` 选择器更可靠），class 作为兼容兜底。
- **存储键**：`aurora-theme`，值为 `'light' | 'dark'`；首次访问读系统偏好并写入。
- **无 JS 时的兜底**：`<meta name="color-scheme" content="dark light">`，让原生滚动条与表单控件跟随。

### 7.2 切换时的过渡处理

**推荐：圆形扩散（circular reveal），用 View Transitions API 实现。**

```
点击切换按钮 → 计算按钮中心到视口最远角的距离 → 
document.startViewTransition(() => { 切换 data-theme }) 
→ 用 clip-path: circle(r) 从 0 扩散到 r，时长 420ms，--ease-out
```

- 半径计算：`r = max(dx_left, dx_right, dy_top, dy_bottom)`，保证完全覆盖视口。
- **不支持 View Transitions 的浏览器**：退化为**全局颜色交叉淡化 240ms**（给 `body` 加一个 240ms 的 `background-color`/`color` transition，切换时临时开启）。
- **必须避免**：整页元素同时变化导致的"闪烁感"。扩散动画天然解决这个问题 —— 新主题从点击点"生长"出来。
- 切换期间**锁定页面滚动**（`overflow: hidden` on body）防止用户误滚。

**Reduced motion 下**：不做扩散，直接瞬时切换（不加分毫秒淡入淡出）。

### 7.3 深浅两套的视觉重心调整

**深色（默认）**
- 层级靠**描边 + 极小量阴影**建立，不靠大投影
- 强调色亮度高（`#35E0A1` 在 `#070A0F` 上 11.64:1），数字可以"发光"但不实际加发光滤镜
- `--shadow-*` 的不透明度保持在 0.40–0.70，不要更重（重阴影在深底上会显脏）
- 图片（AI 插画）本身就是深色，天然融入，不需要额外蒙版
- **视觉重心：数字与代码**。深色让等宽数字和代码块成为最亮的元素，符合"仪表读数"叙事

**亮色**
- 层级靠**阴影 + 描边加强**建立（`--shadow-md` 不透明度提到 0.12）
- 强调色必须降明到 `#0A7A55`（保证 4.5:1），代价是"发光感"消失 —— 用**极细的 1px 强调边框**补偿
- 代码窗口用 `--bg-inset`（`#EDF1F6`）而非纯白，与页面底（`#F6F8FB`）拉开
- 卡片白底 + 页面灰底，形成"卡片浮起"的经典但克制的层次
- **视觉重心：排版与留白**。浅色下文字权重感增强，标题字重可提至 700，正文字号可保持 16px 但行高提到 1.7（浅底上长行更易疲劳）
- **AI 插画在亮色下仍保持深色底**，作为"暗色仪器"锚点存在，靠 1px `--stroke-default` 描边区分

**两套都要保留的**
- 区块交替（`--bg-base` ↔ `--bg-surface`）的节奏
- 强调色出现密度上限（§2.6）
- 所有对比度门槛

---

## 8. AI 生成配图清单（7 张）

### 8.1 统一风格锚点（每张图的 prompt 都必须包含这段，逐字不变）

```
STYLE ANCHOR (must be included verbatim in every prompt):
"abstract technical illustration, extreme close-up of a precision engineering
instrument, deep near-black background (#070A0F), single luminous aurora ribbon
of mint-green (#35E0A1) flowing into indigo-violet (#7C8CF8), thin precise
1px geometric line work, faint measurement grid, subtle volumetric glow,
shallow depth of field, matte finish, cinematic low-key lighting,
high detail, no text, no words, no letters, no numbers, no logos,
no human figures, no faces, no hands, no screenshots, no game footage,
no realistic rendering, abstract data-flow geometry"
```

**风格纪律**
- 全站 AI 图**必须**是深色底 + 极光渐变 + 抽象几何 + 数据流意象
- **禁止**：真实游戏画面、人脸、手部、真实设备照片、可辨识 UI、任何文字
- 渐变只允许 `--accent` → `--accent-2`（必要时第三停靠点 `--accent-3`），不引入第四种色相
- 线条、网格、刻度是主要造型语言 —— 与"仪表盘"气质一致
- 生成后若出现文字或人脸，直接重生成，不要裁切掩盖

### 8.2 图片清单

| # | 用途区块 | 尺寸/比例 | 构图要求 |
| --- | --- | --- | --- |
| 1 | **Hero 右侧视觉区** | 1200×900 (4:3) | 中心偏右，极光缎带从右上向左下贯穿，冷调深底，右侧留出较暗区域承载视觉纵深 |
| 2 | **三档降级状态机** 区块 | 1600×900 (16:9) | 三条平行光带由亮至暗垂直排列，暗示"阶梯/层级"，顶部最亮 |
| 3 | **光流实测对比** 区块 | 1600×900 (16:9) | 密集的矢量流线场，局部一段明显稀疏 —— 表达"实测选型/对比" |
| 4 | **网络坐标定位 / 大地图像素空间** | 1600×900 (16:9) | 俯视的矩形像素网格平面，其中一个点被光标状标记锁定，远处淡出 |
| 5 | **双进程 + 共享内存** 架构 | 1600×900 (16:9) | 两个并列的方形模块，中间一条横向数据传输带，能量沿带流动 |
| 6 | **AI 助手 / 工具注册表** 区块 | 1200×900 (4:3) | 中心一个核心节点，向外辐射 30 条细光线，部分光线末端黯淡（对应"15 个已实装"） |
| 7 | **页脚视觉锚点** | 2400×1030 (21:9) | 极低饱和的极光带，接近纯抽象，适合做页脚上方的分隔意象 |

### 8.3 逐张 prompt

**图 1 · Hero 视觉**
```
Abstract technical illustration of a precision optical sensor assembly,
viewed at a shallow three-quarter angle, a single luminous aurora ribbon
sweeping diagonally from upper right to lower left, thin precise 1px
geometric line work forming concentric measurement rings, faint
measurement grid in the lower left, subtle volumetric glow, deep
near-black background (#070A0F), mint-green (#35E0A1) ribbon transitioning
into indigo-violet (#7C8CF8), matte finish, cinematic low-key lighting,
high detail, no text, no words, no letters, no numbers, no logos,
no human figures, no faces, no hands, no screenshots, no game footage,
no realistic rendering, abstract data-flow geometry
```

**图 2 · 三档降级**
```
Abstract technical illustration of three stacked horizontal energy strata,
the top stratum bright and luminous, the middle dimmer and cooler, the
bottom a desaturated steel grey, thin precise 1px geometric line work
delimiting each stratum, faint measurement grid, subtle volumetric glow,
deep near-black background (#070A0F), mint-green (#35E0A1) on the top
stratum, indigo-violet (#7C8CF8) on the middle, deep near-black background (#070A0F),
matte finish, cinematic low-key lighting, high detail, no text, no words,
no letters, no numbers, no logos, no human figures, no faces, no hands,
no screenshots, no game footage, no realistic rendering, abstract
data-flow geometry
```

**图 3 · 光流对比**
```
Abstract technical illustration of a dense vector flow field, long parallel
streamlines flowing left to right, with one distinct region where the
streamlines become sparse and fragmented, thin precise 1px geometric line
work, faint measurement grid, subtle volumetric glow, deep near-black
background (#070A0F), mint-green (#35E0A1) on the dense flow lines,
indigo-violet (#7C8CF8) on the sparse region, matte finish, cinematic
low-key lighting, high detail, no text, no words, no letters, no numbers,
no logos, no human figures, no faces, no hands, no screenshots, no game
footage, no realistic rendering, abstract data-flow geometry
```

**图 4 · 坐标定位**
```
Abstract technical illustration of a vast flat rectangular pixel grid plane
receding into darkness, seen from a high overhead angle, one single point
on the grid locked by a precise crosshair marker with a thin vertical
beam, thin precise 1px geometric line work, faint measurement grid,
subtle volumetric glow, deep near-black background (#070A0F), mint-green
(#35E0A1) crosshair marker, indigo-violet (#7C8CF8) grid falloff,
matte finish, cinematic low-key lighting, high detail, no text, no words,
no letters, no numbers, no logos, no human figures, no faces, no hands,
no screenshots, no game footage, no realistic rendering, abstract
data-flow geometry
```

**图 5 · 双进程共享内存**
```
Abstract technical illustration of two parallel rectangular processing
modules connected by a single horizontal data bus, luminous energy
travelling along the bus between them, thin precise 1px geometric line
work, faint measurement grid, subtle volumetric glow, deep near-black
background (#070A0F), mint-green (#35E0A1) energy flow along the bus,
indigo-violet (#7C8CF8) module edges, matte finish, cinematic low-key
lighting, high detail, no text, no words, no letters, no numbers, no logos,
no human figures, no faces, no hands, no screenshots, no game footage,
no realistic rendering, abstract data-flow geometry
```

**图 6 · 工具注册表**
```
Abstract technical illustration of a central luminous node emitting thirty
thin radiating lines, fifteen of the lines terminate in bright small
points, the remaining fifteen fade out into darkness before reaching an
endpoint, thin precise 1px geometric line work, faint measurement grid,
subtle volumetric glow, deep near-black background (#070A0F), mint-green
(#35E0A1) active connections, indigo-violet (#7C8CF8) central node core,
matte finish, cinematic low-key lighting, high detail, no text, no words,
no letters, no numbers, no logos, no human figures, no faces, no hands,
no screenshots, no game footage, no realistic rendering, abstract
data-flow geometry
```

**图 7 · 页脚抽象锚**
```
Abstract technical illustration of a very wide low-saturation aurora band
drifting horizontally across a vast empty near-black field, extremely
minimal, thin precise 1px geometric line work fading out at both edges,
faint measurement grid barely visible, subtle volumetric glow, deep
near-black background (#070A0F), mint-green (#35E0A1) fading into
indigo-violet (#7C8CF8), matte finish, cinematic low-key lighting, high
detail, no text, no words, no letters, no numbers, no logos, no human
figures, no faces, no hands, no screenshots, no game footage, no realistic
rendering, abstract data-flow geometry
```

---

## 9. 反面清单（Phase 3 直接对照打勾）

**配色**
- [ ] 没有 `#6366F1` / `#8B5CF6` 这类通用 SaaS 紫作为主色
- [ ] 同一屏内 `--accent` 显著强调 ≤ 3 处
- [ ] 没有大面积渐变卡片、没有渐变按钮
- [ ] 三档降级色（青绿 / 靛紫 / 钢灰）语义正确，规则档**不是**红色
- [ ] 亮色模式是重新取色，不是深色反相

**排版**
- [ ] 零 Web Font（全部系统字体）
- [ ] 所有关键数字用 `--font-mono` + `tabular-nums`
- [ ] H1 桌面 ≤ 72px，移动 ≥ 40px
- [ ] 正文行宽 ≤ 68 中文字符
- [ ] 没有居中大段正文（表单除外）

**布局**
- [ ] 卡片圆角 ≤ 6px
- [ ] 卡片内 padding ≥ 24px，卡片间 gap ≥ 24px
- [ ] Section 桌面上下 padding = 128px
- [ ] 没有 10px / 18px / 30px 之类非 4/8 阶梯值
- [ ] Hero 高度 ≤ 700px

**组件**
- [ ] 表格行高 48px，无斑马纹背景
- [ ] FAQ 用 `0fr→1fr` 展开，不用固定 max-height
- [ ] 复制按钮有 `aria-live` 宣告
- [ ] 表单错误用 `aria-invalid` + `aria-describedby`
- [ ] 所有可交互元素有 `:focus-visible` 焦点环（不移除 outline）
- [ ] 免责声明在 Hero 角标 + 页脚两处均出现
- [ ] 致谢区块含 MaaNTE 的 AGPL 传染性说明

**动效**
- [ ] 进场用 `--ease-out`，出场用 `--ease-in`
- [ ] 滚动渐入位移 ≤ 20px，错峰 ≤ 70ms，总延迟 ≤ 280ms
- [ ] 页面过渡 `mode="wait"`、`initial={false}`、进场 ≤ 360ms、位移 ≤ 12px（移动 8px）
- [ ] 路由切换时 `scrollTo` 用 `behavior: 'instant'`
- [ ] `scrollRestoration = 'manual'`
- [ ] 唯一无限循环动效是状态灯（1.6s）
- [ ] `prefers-reduced-motion` 全量降级表已实现
- [ ] 无视差、无无限滚动加载、无元素飞入

**AI 配图**
- [ ] 7 张图全部含统一 STYLE ANCHOR
- [ ] 无文字 / 人脸 / 游戏画面
- [ ] 图与文字是兄弟容器，不是叠加
- [ ] 有 `alt`、有 `width/height`、有 lazy loading

---

## 10. 交付自检清单（Phase 3 完成后逐条打勾）

1. [ ] `index.html` 内联脚本已设置 `data-theme`，无首屏白闪
2. [ ] 所有对比度实测通过（本文档 §2.4 的表即验收标准）
3. [ ] 键盘可完整操作全站，焦点环在深浅两套都清晰可见
4. [ ] 375px / 768px / 1440px 三个宽度无横向滚动、无文字截断
5. [ ] 路由切换无闪烁、无重影、滚动位置正确（前进/后退可恢复）
6. [ ] Reduced motion 下无位移动画、无无限循环
7. [ ] 所有数字与 BRIEF 一致（15Hz / 15fps / 1.91ms / 664 / 932 / 30 / 15 / GPL-3.0-or-later 等）
8. [ ] 未出现 BRIEF 明令禁止的内容（自愈定位 / 脱困第四档 / 20Hz / 30 技能全可用）
9. [ ] Lighthouse：Performance ≥ 90、Accessibility ≥ 95、Best Practices ≥ 90、SEO ≥ 90（深浅两套都测）
10. [ ] AI 图 7 张全部生成、风格一致、无文字无人物

---

*本文档所有颜色对比度数值均由脚本实测得出（WCAG 2.1 相对亮度公式）。验证脚本已随仓库归档于 `website/contrast-check.py`，覆盖 184 项组合（深浅两套 × 文本/强调/语义/三档状态/语法高亮/输入描边/按钮/焦点环），当前全部通过、0 失败。Phase 3 修改任何颜色后须重跑该脚本验收：`python3 website/contrast-check.py`。*
