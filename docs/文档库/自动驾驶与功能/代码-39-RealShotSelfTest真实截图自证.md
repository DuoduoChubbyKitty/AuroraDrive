# 代码-39 RealShotSelfTest 真实截图红线自证

> 覆盖源文件：`Sources/AuroraDrive/App/RealShotSelfTest.swift`（**257 行**，2026-10-02 实测）
> ⚠️ **未在 git 跟踪**（untracked）。
> 关联：[`代码-38-PerfSelfTest性能自检.md`](代码-38-PerfSelfTest性能自检.md)、
> [`性能实测-2026-09-30-卡顿与定位.md`](性能实测-2026-09-30-卡顿与定位.md)

---

## 一、★ 为什么需要这个文件（`:5–17` 原文，**本文档最重要的一段**）

> **2026-10-01 审计发现的验证可信度缺陷**：
> `--perf-selftest` 与 `--yolopx-selftest` 都用 `PerfSelfTestImage.make()` 构造的**合成图**
> （斜向梯度 + 棋盘格 + 亮线）。合成图里没有任何真实目标，所以它们跑出来的 R2/R3 必然是：
>
> ```
> R2 检测框 = 0 个
> R3 可行驶 = 0.00% / 车道线 = 0.000%
> ```
>
> ⟹ 这两个红线的**数字本身不构成验证**。上一轮「N R2 9→9 / R3 一字未变」的结论
> 实际来自**离线拿同一张真实截图做前后对比**，而不是自检给出的。
> 自检报告里那两个 0 容易被误读成"回归通过"，属**误导性输出**。

**⟹ 结论：`--perf-selftest` 输出的 R2/R3 是 0，是设计使然，不是回归失败；
但也不能当作红线通过的证据。**（本小姐 2026-10-02 跑出的 `R2=0 / R3=0.00%` 就是这个原因。）

## 二、本自检做什么（`:19–21`）

用**用户提供的真实游戏截图**跑 YOLOPX，输出 R2/R3 的**真实数值**，
并与历史记录做**逐位对比**。**同图前后一致 = 红线守住。**

## 三、用法

```bash
# 单张图
AURORA_UI_LOCAL=1 ./AuroraDrive --realshot-selftest --image <路径.jpg>

# 目录（跑该目录下所有 jpg/png，逐张对比）
AURORA_UI_LOCAL=1 ./AuroraDrive --realshot-selftest --dir data/nte_test_frames
```

## 四、★ 历史真值（2026-09-29 实测，同一批图）

| 红线 | 数值 |
|---|---|
| R2 检测框 | **9 个** |
| R3 可行驶 | **26.19%** |
| R3 车道线 | **8.042%** |

### ⚠️ 判据不是"等于固定值"（`:29–32`）

> 这两个数字是**特定图 + 特定模型**下的结果，换图就会变。
> 故本自检的判据是「**同一张图**前后一致」，不是「等于某个固定值」——
> 后者在换图时会产生**假失败**，那种"自检判红但实际正常"的噪声正是要避免的。

**这是本项目里少见的、把判据设计想清楚的例子。**

## 五、与 `--yolopx-selftest` 的分工（`:34–37`）

| 自检 | 验什么 | 图的来源 | 真值可控性 |
|---|---|---|---|
| `--yolopx-selftest` | **接口 / 坐标变换 / NMS / 兜底门控** | 合成图 | ✅ 可控真值 |
| `--realshot-selftest` | **精度红线 R2/R3** | 真实游戏截图 | ❌ 不可控，但**可信** |

> **两者互补，不能互相替代。**

## 六、API

| 成员 | 行号 | 说明 |
|---|---|---|
| `struct RealShotResult` | `:47` | 单张图的测量结果 |
| `loadCGImage(path:)` | `:62` | 读图 |
| `runRealShotSelfTest(image:dir:)` | `:116` | **主入口**（`--realshot-selftest`） |

### `RealShotResult` 字段（`:47–58`）

```swift
var path: String
var ok: Bool
var boxCount: Int = 0        // R2
var drivablePct: Double = 0  // R3-a
var lanePct: Double = 0      // R3-b
var drivableCells: Int = 0
var laneCells: Int = 0
var latencyMs: Double = 0
var modelName: String = ""
var errorMessage: String?
```

## 七、一个实现细节值得记（`:61–63`）

> 读图**用 `ImageIO` 而不是 `NSImage`** —— 后者依赖 AppKit 上下文，
> 在**无窗口的 CLI 进程里可能拿到空图**。

⟹ 同类陷阱：任何 CLI 自检都**不要依赖 AppKit 上下文**。

## 八、⚠️ 未做的事

- **`data/nte_test_frames` 是否存在、内容为何，本次未核实。**
- 本自检**不在本次 7 项自检的实测清单内**（未运行），故**无 2026-10-02 实测数据**。
  若要验证 R2/R3 红线，**必须**跑它并指向真实截图 —— 这是**目前唯一可信的 R2/R3 验证途径**。

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。所有行号均写前 `sed -n` 回读确认。
