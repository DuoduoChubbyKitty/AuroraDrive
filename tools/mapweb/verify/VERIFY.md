# 三站完整还原 · 独立对抗性验证报告

- **验证者**：`verifier`（第 4 个智能体，独立于 site-main / site-999 / site-pph）
- **任务**：共享任务板 `task-5`
- **验证时间**：2026-10-04 12:20 – 12:40（Asia/Shanghai）
- **工作目录**：`/Users/dupi/Desktop/自动驾驶系统/tools/mapweb`
- **写入范围**：仅 `tools/mapweb/verify/`（本报告）
- **隔离构建区**：`/tmp/mwv/`（**全程未在工作副本内构建**）

## 0. 验证方法学（关键前提）

**没有拿 `_pristine/` 当唯一基线。** 我直接从 GitHub 拉了三站上游仓库
（`Maa-NTE/MaaNTE-Map` / `Maa-NTE/MaaNTE-999` / `Maa-NTE/MaaNTE-PPH`）作为**权威基线**：

```bash
curl -sL -o MaaNTE-Map.tar.gz https://codeload.github.com/Maa-NTE/MaaNTE-Map/tar.gz/refs/heads/main
```

顺带验证了 Lead 的 `_pristine/` 本身可信：

```
_pristine/MaaNTE-Map vs 上游: 0 处不一致
_pristine/MaaNTE-999 vs 上游: 0 处不一致
_pristine/MaaNTE-PPH vs 上游: 0 处不一致
（_pristine 是上游的忠实子集：Map 52 文件 / 999 34 / PPH 12，逐个逐字节一致）
```

> 若只对 `_pristine/` 做 `cmp`，C1 是**循环论证**（`_pristine` 由 Lead 自己生成）。
> 本报告的 C1 全部以**上游 GitHub** 为准。

---

## 1. 🔴 工具链复核（最高优先项）——结论：**site-999 的根因归因被证伪**

### 1.1 锁文件与实装版本对照

| 站 | 上游仓库里的锁文件 | 锁内 rollup / esbuild / vue | 工作副本实装 | 一致? |
|---|---|---|---|---|
| 主图 | `package-lock.json`(44486B) + `bun.lock`(21551B) | rollup **4.61.0** / esbuild 0.25.12 / vue 3.5.35 | rollup **4.61.0** / esbuild 0.25.12 / vue 3.5.35 | ✅ 一致 |
| 999夜 | **仅** `pnpm-lock.yaml`(26575B) | rollup **4.62.2** / esbuild **0.25.0** / vue **3.5.39** | rollup **4.64.0** / esbuild **0.25.12** / vue **3.5.43** | ❌ **不一致** |
| 粉爪 | **仅** `package-lock.json`(43586B) | rollup **4.62.2** / esbuild 0.25.12 / vue 3.5.38 | rollup **4.62.2** / esbuild 0.25.12 / vue 3.5.38 | ✅ 一致 |

锁文件与上游的 `cmp`：

```
IDENTICAL  MaaNTE-Map/package-lock.json      (vs 上游)
IDENTICAL  MaaNTE-Map/bun.lock               (vs 上游)
IDENTICAL  MaaNTE-999/pnpm-lock.yaml         (vs 上游)
IDENTICAL  MaaNTE-PPH/package-lock.json      (vs 上游)
上游 MaaNTE-999 目录下【不存在】package-lock.json
```

**三站 CI 口径**（`.github/workflows/`）：
- 主图 `deploy.yml` → `npm ci`（npm，Node 22）
- 999 `deploy-pages.yml` → `pnpm install --frozen-lockfile`（pnpm 10，Node 22）
- 粉爪 `deploy-pages.yml` → `npm ci`（npm，Node 20）

→ **999 的权威工具链是 pnpm**；工作副本里那个 `package-lock.json` 是本地 npm install 生成的私货。

### 1.2 隔离重建（`/tmp/mwv/iso/`，rsync 源码 + 软链/独立 node_modules）

线上真实产物名（curl 抓取）：

| 站 | 线上 bundle |
|---|---|
| 主图 | `index-daM5xuNa.js`(339113) `markers-CweXpjdM.js`(503846) `index-CJ9dEJGJ.css`(50551) `browser-BzBbrBKd.js`(32140) |
| 999 | `index-DDUSdHA-.js`(356752) `markers-D4UqI9Dz.js`(242375) `index-BDiMfgNR.css`(53443) |
| 粉爪 | `index-Ctad0RAI.js`(316420) `index-CQtNdf68.css`(46752) |

| 实验 | 工具链 | 结果 |
|---|---|---|
| A1 主图·**原版 config**（`_pristine` 的 vite.config.js，无 `.env.production`） | 工作副本 node_modules（rollup 4.61.0） | **4 个 chunk 全部 `cmp` 逐字节 = 线上** ✅ |
| A2 主图·**本地化 config**（现 vite.config.js + `.env.production`） | 同上 | `markers` / `css` / `browser` 逐字节相同；**index chunk 不同**（`index-B92mz6tD.js` 339137 vs 线上 339113）❌ |
| B1 999 | 工作副本 npm node_modules（rollup **4.64.0**） | index js **不同**（`index-C5x8Q0ro.js` 358974）+ CSS **不同**（`index-BpAEMgtN.css` 53437）❌ |
| B2 999 | `pnpm install --frozen-lockfile`（rollup **4.62.2**） | **3 个产物全部 `cmp` 逐字节 = 线上** ✅ |
| C1 粉爪 | 工作副本 node_modules（rollup **4.62.2**） | **2 个产物全部 `cmp` 逐字节 = 线上** ✅ |

### 1.3 主图 index chunk 差异定位（本地化代价，非回归）

```
first diff at byte 862
local: ...**/function Qa(e){const n=Object.create(null);...
live : ...**/function tl(e){const n=Object.create(null);...
common suffix len 1711
```

差异是**压缩器标识符分配**（`Qa` vs `tl`），起因是 `.env.production` 把
`VITE_MAP_TILE_URL` 注入为 `/mapsource-tiles/{z}/{x}/{y}.jpg`（原版回落值是
`https://raw.githubusercontent.com/...`），字面量变化改变了 esbuild 的字符频率统计
→ 全量标识符重排。**A1 实验证明：去掉这两处本地化改动，产物 100% 逐字节等于线上。**

### 1.4 归因反转：rollup 版本对 999 产物**零影响**

site-999 的原始结论是「rollup 4.64.0 vs pnpm-lock 锁的 4.62.2 导致哈希对不上」。
我用两个方向的单变量实验证伪：

**实验一（npm 树内降级）**

```
B1  fresh npm install        -> rollup=4.64.0  -> index-C5x8Q0ro.js
B2  npm i --no-save rollup@4.62.2 (实装确认 4.62.2) -> index-C5x8Q0ro.js   ← 文件名/大小完全不变
```

**实验二（能复现线上的 pnpm 树内升级）**

```
pnpm install --frozen-lockfile 基线     -> index-DDUSdHA-.js  = 线上 ✅
pnpm-workspace.yaml 写入 overrides: rollup: 4.64.0
  .pnpm 实装确认: rollup@4.64.0 / esbuild@0.25.0 / vue@3.5.39
  重建                                   -> index-DDUSdHA-.js  = 线上 ✅  ← 依然逐字节相同
```

→ **rollup 版本被排除。** 差异来自**整组依赖版本**：

- `vue` / `@vue/compiler-sfc` 3.5.43 vs 3.5.39 → 改变 JS（B1→B3 换 vue 后哈希确实变了）
- `esbuild` 0.25.12 vs 0.25.0 → 改变 CSS。首个差异在 **CSS 第 49812 字节**：

```
npm : @media(max-width:900px){
live: @media (max-width: 900px){
```

（site-999 观察到的「首个差异在第 12 字节」本身**复现无误**：
`import{m as wa}` vs `import{m as ya}` —— 但它不是 rollup 造成的。）

> 补充：我未能把 JS 差异归约到**单一**包（把 vue、esbuild、@vitejs/plugin-vue 逐一降到锁内版本后，
> JS 仍与线上不同）。可确证的结论是：**rollup 无关；vue 与 esbuild 是已证实的贡献因素；
> 唯一能 100% 复现线上的方式是严格按上游锁安装。**

### 1.5 「逐字节相同」是必然还是碰巧？——**锁驱动，且很脆弱**

把上游锁文件删掉、做一次全新 `npm install`：

| 站 | 新装 rollup | 新装 vue | 重建结果 |
|---|---|---|---|
| 粉爪 | 4.64.0 | 3.5.43 | `index-D_cALxXT.js`(318807) ≠ 线上 316420 ❌ |
| 主图 | 4.64.0 | 3.5.43 | `index-CDtp7hT1.js`(341523) ≠ 线上 339113 ❌（markers/css/browser 仍相同） |

- **粉爪「逐字节相同」是真成立，但不是碰巧**：它上游 `package-lock.json` 锁死 rollup 4.62.2，
  工作副本正是按该锁安装的；只要走 `npm ci` / 尊重 lock 的 `npm install` 就必然复现。
- **一旦锁丢失（或改用 npm 装一个只有 pnpm-lock 的仓库），复现立刻失效。**
- 主图同理：它的 `package-lock.json` 也来自上游，所以现有 node_modules 能复现**原版构建**。

---

## 2. C1 源码逐字节 = 原版 —— **通过（例外逐条列明）**

命令：`diff -rq --exclude=node_modules --exclude=dist <工作副本> <上游>`

### 主图 `MaaNTE-Map/` —— 2 处例外

| # | 例外 | 性质 | 是否本地化必需 |
|---|---|---|---|
| 1 | `.env.production`（新增，331B） | `VITE_MAP_TILE_URL=/mapsource-tiles/{z}/{x}/{y}.jpg` | ✅ **必需**。否则生产构建回落到 `raw.githubusercontent.com`（C4 会失败）。代价：index chunk 哈希改变（见 1.3） |
| 2 | `vite.config.js`（+31 行 `localMapTilesPlugin`） | 构建结束时把 `MapSource/tiles` 复制进 `dist/mapsource-tiles` | ✅ **必需**。与 #1 成对，缺一则生产产物自带瓦片缺失 |

其余**全部逐字节一致**，含：
- `index.html` ✅ · `package.json` ✅ · `bun.lock` ✅ · `package-lock.json` ✅
- `src/**` 全树 ✅（**注意**：`src/data/locations.js` 里的 `VITE_MAP_TILE_URL` 那一行
  **本来就是上游代码**，不是 Lead 加的 —— 已与上游 `cmp` 确认，避免误判）
- `public/icons` **36 个文件** ✅ · `public/images` **478 个** ✅ · `public/tiles` **2591 个** ✅

### 999夜 `MaaNTE-999/` —— 1 处例外

| # | 例外 | 性质 | 是否本地化必需 |
|---|---|---|---|
| 1 | `package-lock.json`（45048B，上游**不存在**） | 本地 `npm install` 生成，把 rollup 解析到 4.64.0、vue 到 3.5.43 | ❌ **非必需，且有害**。它是「用 npm 装就装错版本」的根源，建议删除（见未通过项 U2） |

其余全部逐字节一致（`index.html` ✅ `src/**` ✅ `pnpm-lock.yaml` ✅ `pnpm-workspace.yaml` ✅ `public/**` ✅）。

### 粉爪 `MaaNTE-PPH/` —— **0 处例外**

`diff -rq` 输出为空。完美还原。

---

## 3. C2 UI 元素齐全 —— **通过（PPH 部分项 N/A，非缺失）**

浏览器内实测（非仅看 DOM），主证据为 DOM 清点 + 交互后状态变化：

| 项 | 主图 :15530 | 999 :15531 | 粉爪 :15532 |
|---|---|---|---|
| 公告面板 | ✅ 3 条，可收起/展开 | ✅ 3 条，可收起/展开 | ⚪ **上游本就没有**（`grep 公告` 上游 0 命中） |
| 实时定位 | ✅ 有开关行 | ✅ 有开关行 | ✅ 有（独立分区，非 `.switch-row`） |
| 箭头保持居中 | ✅ 有（`v-if="realtimeNavigationEnabled"`），**实测可用** | ✅ 同源 | ⚪ 上游无 |
| 监听地址 | ✅ `ws://127.0.0.1:14514` | ✅ 同源 | ⚪ 上游无 |
| 品牌 logo | ✅ `/logo.png` 已加载 1024×1024 | ✅ 同 | ✅ `/images/logo.png` 已加载 |
| 原版图标 | ✅ **36 个文件，内容逐字节 = 上游** | ✅ 12 个文件，逐字节 = 上游 | ⚪ 无 icons 目录（上游亦无） |
| 跨站外链 | ✅ 粉爪 + 999 + GitHub | ✅ 主图 + 粉爪 + GitHub | ✅ 主图 + 999 |
| 悬浮小窗 | ✅ **真 Document PiP**（见下） | ✅ 有按钮 | ⚪ 上游无 |
| 编辑模式 | ✅ 按钮 → 「编辑已开启」 | ✅ 同 | ✅ 「连接/编辑」 |

**「箭头保持居中」真实性实测**（自建 WS stub，见 §5.5）：
- `NAVI CONNECTED`，`.navigation-arrow-shell` 元素存在，内含 `map_webview_pointer.png` 且带旋转角
- 位置静止时收敛到 **Δ=(16,-17)px，距离 23.3px < 设计容差 28px**（`NAVIGATION_CENTER_TOLERANCE_PX = 28`）
- ⚠️ 口径提醒：它是**收敛到 28px 容差内**，不是像素级居中

**「悬浮小窗」真实性实测**：
```
pipOpen: true   pipSize: {w:320, h:260}   pipMapEls: 1（PiP 窗口内含真实 Leaflet 实例）
按钮文案: 悬浮小窗 → 关闭小窗
```

**999 多出的 2 个侧边栏块**：已独立确认是 dev-only 门控，**不是私货**：
- `src/composables/useMapApp.js:82` → `const isLocalEditor = import.meta.env.DEV`
- 线上 bundle 里该常量被内联为 false，`grep -c "import.meta.env.DEV"` 线上 bundle = **0**

---

## 4. C3 功能可用 —— **通过**

全部在浏览器里**触发真实状态变化**后判定：

| 功能 | 站点 | 证据 |
|---|---|---|
| 搜索 | 主图 | 输入「谕石」→ 显示标记 **1357 → 269** |
| 分类筛选 | 主图 | 37 个分类按钮；点「谕石」→ 标记 **203 → 154 → 还原 203** |
| 区域筛选 | 主图 | 8 个区域；点「绘空町」→ 标记 **203 → 51 → 还原** |
| 收藏 | 主图 | 真实鼠标点 marker → `.detail-card` 打开（谕石 #023 / 米格尔区）；点「☆ 收藏」→ **「★ 已收藏」**，计数器 **1 → 2** |
| 完成度 | 主图 | 点「标记完成」→ 按钮变「✓ 已完成」，footer **0 / 1357 → 1 / 1357**，撤销后回到 0 |
| 路线 | 主图 | 路线面板打开：`ROUTES 路线规划 / 锄大地路线 10 个路段 / 导入 JSON / 导出 JSON` |
| 编辑 | 主图 / 999 | 按钮 `编辑地图` → **`编辑已开启`** |
| 导出 | 主图 | 真实 download 事件：`MaaNTE-completed-2026-10-04.json`（blob URL），内容合法 JSON `{"version":1,"completedIds":[]}` |
| 导入 | 主图 / 999 / 粉爪 | 三站均存在 file input（`.toolbar-file-input` / 路线 `导入 JSON`） |
| 悬浮小窗 | 主图 | 见 §3，真 PiP 打开 |
| 粉爪图层切换 | 粉爪 | `.layer-list` = **1 个「全地图总览」+ 16 个区域按钮 = 17 个可选图层**；点「LG1-办公层 W2」→ CURRENT LAYER 变更，网络侧新增 `map-tiles/g1-office-w2/*` 请求 |

---

## 5. C4 资源全本地 —— **通过（三站均 0 外站请求）**

`performance.getEntriesByType('resource')` 全量清单 + 交互一轮后复采：

| 站 | 请求总数 | 请求来源 origin | **外站请求** |
|---|---|---|---|
| 主图 | 70 | `http://127.0.0.1:15530` | **0** |
| 999 | 65 | `http://127.0.0.1:15531` | **0** |
| 粉爪 | 30 | `http://127.0.0.1:15532` | **0** |

主图瓦片全部来自 `/mapsource-tiles/...`（本地）。
`raw.githubusercontent.com` 只作为 `map-data.json` 的**生产回落常量**存在；DEV 分支走
`/mapsource-tiles`，生产由 `.env.production` 覆盖 —— 运行时实测确认**一次都没发出去**。

---

## 6. C5 三站都活着 —— **通过（附带 1 项偏差）**

```
:15530 -> HTTP 200   title "MaaNTE在线地图工具"          app HTML 85950 B，可交互
:15531 -> HTTP 200   title "MaaNTE 999夜在线地图"        app HTML 26104 B，可交互
:15532 -> HTTP 200   title "MaaNTE粉爪大劫案在线地图"    app HTML 95494 B，可交互
```

**偏差 U4**：任务书写主图有 `4173`（PREVIEW 构建产物），实测
`lsof -nP -iTCP:4173` **无监听**，`curl` 返回 `000`。当前只有 15530/15531/15532
（+ 我临时起的 14514 导航 stub，已停）。三站必需端口不受影响。

---

## 7. C6 与线上一致 —— **通过（方法论修正后）**

### ⚠️ 方法论修正（重要）

**第一次对比出现大量"差异"，全部是 localStorage 残留状态污染**，不是源码差异：

| 站 | 初测差异字段 | 典型假差异 |
|---|---|---|
| 主图 | 4 | `★已收藏1` vs `0`；缺「箭头保持居中」行（实为 `实时定位` 默认关 → `v-if` 不渲染） |
| 999 | 5 | 标记数 `68` vs `37`（本地残留了区域筛选状态） |
| 粉爪 | 3 | app HTML `12788` vs `62103`（本地残留折叠状态） |

→ **清空两个 origin 的 `localStorage`/`sessionStorage` 后重测**：

```
===== main 差异字段数: 0 / 11 =====
===== s999 差异字段数: 1 / 11 =====
  expanderToggles: 仅本地=["3点坐标映射当前图层独立保存READY","3D Coordinate Plane当"]  仅线上=[]
===== pph  差异字段数: 0 / 11 =====
```

对比字段：`title` / `headings` / `categories` / `announcement` / `announcementDate` /
`links` / `progressFooter` / `filterSummary` / `switchRows` / `expanderToggles` / `layerRows`

- **主图 0/11** ✅ · **粉爪 0/11** ✅
- **999 唯一差异 = 2 个 dev-only 面板**（`isLocalEditor = import.meta.env.DEV`，见 §3）→ **已判定为非缺陷**

线上 HTML 的 Cloudflare 注入脚本（`</body>` 前）已确认存在，不影响比对。

---

## 8. 对抗性验证记录

### 8.1 负向对照：改坏 → 必须报失败 → 立即还原 + `cmp` 证明

对象：`MaaNTE-999/src/data/announcements.json`（改前已确认与上游逐字节一致）

```
BEFORE: 与上游逐字节一致 ✓          md5 = ad0e24e2c3102fb213bf72e064ed2d5b
注入故障: items = []                md5 = 29165ec8eb3b2545dad203d25bb6639c
核验结果: {"panelFound":true,"itemCount":0,"expect":3,"verdict":"FAIL"}   ← 流程真的会报失败 ✅
还原:
  ✓ 与备份逐字节一致
  ✓ 与上游 GitHub 逐字节一致
  ✓ 与 _pristine 逐字节一致
  md5 还原后 = ad0e24e2c3102fb213bf72e064ed2d5b
还原后复检: {"itemCount":3,"verdict":"PASS"}
全树 diff 回到只剩 package-lock.json（已知项）
```

**我的会话内（12:20 起）对三站源码/资源的修改数 = 0**（`find -newermt` 扫描为空）。

### 8.2 抽查「看起来对但其实错」的 3 个点

| # | 表面现象 | 深挖后 | 判定 |
|---|---|---|---|
| 1 | 图标「36 个文件都在」 | `diff -rq` 逐字节比内容：`public/icons` 36 个文件与上游**0 差异**；另 `public/images` 478 个、`public/tiles` 2591 个也 0 差异 | ✅ 内容也是原版 |
| 2 | 公告面板「DOM 里有」 | 真点 toggle：收起后 `aria-expanded=false`、`h=0`、`display:none`；再展开 `h=240`、**3 条**内容可见（开源地址 / 数据维护提示 / 使用提醒）+ 更新日期 | ✅ 真能展开收起 |
| 3 | 瓦片「请求 200」 | 像素级：主图 12 张 `img` 瓦片全部 `naturalWidth=512`、`opaquePct=100`、颜色桶 15–20、无 broken；粉爪 8 个 `<canvas class="map-image-tile">` 采样 opaque 12–38%、颜色桶 37–65（非空白/非纯黑块）。另：主图瓦片 **HTTP 响应 md5 == 磁盘文件 md5**（`29409321297bf4d62b219ced1892ad04`） | ✅ 真出图 |

### 8.3 端口串台检查 —— 三站各服务自己的目录

**铁证 1：各端口 `/package.json` 的 name 字段**

```
:15530 -> maante-map      0.1.0
:15531 -> maante-999      0.1.0
:15532 -> maante-pph-map  0.1.0
```

**铁证 2：进程工作目录**

```
:15530 pid=65987 cwd=.../tools/mapweb/MaaNTE-Map
:15531 pid=53349 cwd=.../tools/mapweb/MaaNTE-999
:15532 pid=53347 cwd=.../tools/mapweb/MaaNTE-PPH
```

**铁证 3：站点独有字符串**（999 独有的 `finaltower_coords_with_area.csv`）

```
:15530 -> <!doctype html> ...            (SPA fallback)
:15531 -> ﻿category,level_name,area_id,... (真 CSV)
:15532 -> <!doctype html> ...            (SPA fallback)
```

**铁证 4：独有静态资源的字节一致性**

```
:15530 /icons/teleport/pinkpaw.png  served=f08c35adb6  磁盘(Map)=f08c35adb6  MATCH
```

→ **互不串台，各服务自己的目录。**

### 8.4 实时定位 / 箭头居中：自建 WebSocket 服务端真跑通

本机无 `ws` 包，手写 RFC6455 握手 + 服务端帧（`/tmp/mwv/nav_stub.js`），
按 `useMapApp.js:handleNavigationMessage` 的协议发
`{"type":"navi-state","version":1,"position":{x,y},"angle":n}`：

```
navStatus: "NAVI CONNECTED"（class navigation-status--connected）
arrow: <div class="navigation-arrow"><img src="/images/map_webview_pointer.png"
        style="transform: translateZ(0px) rotate(595deg)">
gameCoord: "XYZ 1150, 625, --" → "XYZ 1300, 700, --"（跟随推送更新）
静止位置收敛: Δ=(16,-17)px → 距离 23.3px < 容差 28px ✅
```

### 8.5 反向验证「锁驱动」假说

删掉 `package-lock.json` + `bun.lock` 做全新 `npm install`：
主图/粉爪都装到 rollup 4.64.0 + vue 3.5.43，**重建产物立刻与线上不一致**。
→ 证明 §1.5 的「必然但脆弱」结论。

---

## 9. 未通过项清单（不粉饰）

| # | 严重度 | 项 | 说明 |
|---|---|---|---|
| **U1** | 🔴 高（**口径**） | **主图当前交付的生产构建产物，index chunk 与线上不同** | `dist/assets/index-B92mz6tD.js`(339137) ≠ 线上 `index-daM5xuNa.js`(339113)，首个差异在第 862 字节（压缩器标识符 `Qa` vs `tl`）。**这是 `.env.production` 本地化的必然结果，不是回归**（去掉本地化改动后 4/4 chunk 逐字节相同）。但「构建产物 3 个 bundle + logo 与线上逐字节相同」这句话若不加限定即**不成立**：实际是 markers/css/browser **3 个 chunk + logo + 全部 public 资源**逐字节相同，**index chunk 必然不同**。 |
| **U2** | 🟠 中（**真实缺陷**） | **999 工作副本的 node_modules 与上游锁不一致，且多出上游不存在的 `package-lock.json`** | 实装 rollup 4.64.0 / vue 3.5.43 / esbuild 0.25.12，上游 `pnpm-lock.yaml` 锁的是 4.62.2 / 3.5.39 / 0.25.0。任何人用 npm 重建 999 都会得到**与线上不同**的产物。**建议：删除 `MaaNTE-999/package-lock.json`，改用 `pnpm install --frozen-lockfile`。** |
| **U3** | 🟠 中（**结论纠错**） | **site-999 的根因归因（rollup 4.64.0 vs 4.62.2）被证伪** | 两个方向的单变量实验都证明 rollup 版本对该 bundle **零影响**（npm 树降级后产物不变；pnpm 树 overrides 升到 4.64.0 后仍逐字节 = 线上）。真实原因是**整组依赖版本差异**，其中 vue/@vue/compiler-sfc（JS）与 esbuild（CSS）已证实为贡献因素。「首个差异在第 12 字节的标识符命名」这个**现象**复现无误，但**归因错了**。 |
| **U4** | 🟡 低 | **主图 4173 PREVIEW 未监听** | 任务书标称 `4173（PREVIEW 构建产物）`，实测无监听、curl 返回 000。三站必需端口 15530/15531/15532 不受影响。 |
| **U5** | 🟡 低（**口径**） | C2/C3 清单中若干项对粉爪**不适用**，不能算缺失 | 粉爪上游从来没有：公告面板、悬浮小窗（PiP）、编辑地图、icons 目录、`实时定位` 开关行。已用 `grep` 对上游源码逐一确认（命中数 0）。 |
| **U6** | ⚪ 信息 | 粉爪图层数 = **17**（1 总览 + 16 区域），非任务书写的 19 | 与「16 个瓦片目录 + manifest」吻合，Lead 的口径修正**正确**。 |

**结论：C1 ~ C6 六条判据全部通过**（C1/C2/C3/C4/C5/C6 各有已列明的例外与口径修正）。
**但 U1、U2 是必须让 Lead 知道的实质问题**：U2 是真正需要动手修的工作副本缺陷，
U1 是「逐字节相同」这句话的适用范围必须写清楚。

---

## 10. 环境清洁声明

- 三站源码/资源：**零残留改动**（`find -newermt` 扫描 + 全树 `diff -rq` 双重确认）
- 负向对照唯一改动的 `MaaNTE-999/src/data/announcements.json`：已还原，三方 `cmp` 一致
- 所有构建均在 `/tmp/mwv/iso/` 隔离目录完成，**未在工作副本内执行任何 build**
- 临时导航 stub（:14514）验证结束后已停止
- 交付物：本文件 `tools/mapweb/verify/VERIFY.md`
