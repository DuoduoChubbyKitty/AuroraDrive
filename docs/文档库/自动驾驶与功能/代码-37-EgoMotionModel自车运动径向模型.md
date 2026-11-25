# 代码-37 EgoMotionModel 自车运动径向模型
> **引用纪律（本篇已重写为名字锚点）**：不再用「文件:行号」定位。本篇所有代码位置一律引用源码里**真实存在的名字**（类型 / 方法签名 / 属性 / 常量 / 枚举 case / 环境变量）。
>
> **本次重写一并校正的两处**：① `typicalDt` 的值以源码为准（`1.0 / 20.0`）；② `maskShift(for:ego:)` 仍是**零调用死代码**——`grep -rn 'maskShift' Sources/` 只有定义处与 `LaneBridge` 的两行「尚未落地」注记，从未被 LaneExtrapolator 或任何调用方接线。

> 覆盖源文件：`Sources/AuroraDrive/Inference/EgoMotionModel.swift`（当前 git 已跟踪）。
> 2026-10-01 新增（性能文档 §6.45「光流接线 · 路线2」的实现）。
> 关联：[`代码-38-PerfSelfTest性能自检.md`](代码-38-PerfSelfTest性能自检.md)（`--motion-selftest` 在 `PerfSelfTest` 侧）

---

## 一、它解决什么问题

**问题（文件头注释）**：`OpticalFlowBridge` 算了很久的光流，输出 `dx/dy/divergence`
**在全项目零读取方**（2026-09-30 静态核查）。
它的设计用途写的是「交叉校验全局运动方向」，但**那段校验从未实现** ——
接口预留了、数据喂进来了、**消费端没接线**。

⟹ 本文件就是那段缺失的消费端：把光流估的**自车运动**变成可用判据，
用来校验 `MotionPredictor` 从**检测框差分**算出的目标速度。

## 二、★ 为什么必须是「径向」而不是平移

`MotionPredictor` 的速度来自 α-β 滤波对检测框差分的更新。天生弱点（文件头注释）：

> **目标静止、自车在动**时，它会把「自己的运动」误算成「目标在动」。

直觉上可以拿光流的 `dx/dy`（全局中位平移）去减，但**那是错的**（文件头注释）：

| 自车动作 | 画面表现 | `dx` 能否描述 |
|---|---|---|
| **横移** | 画面内容整体平移 | ✅ 能 |
| **前进** | 画面内容向**消失点径向扩散** | ❌ **不是平移** |

前进时**画面中央的目标几乎不动、边缘的目标向外飞** —— 这正是 `divergence` 度量的量。
**故必须建径向扩张场，而不是简单平移相减。**

## 三、几何模型

以画面中心为消失点（相机光轴水平时成立）。设某点相对中心的半径向量
`r = (px − cx, py − cy)`，自车以速度 v 前进时该点因自车运动产生的位移：

```
u_ego(px, py) = forwardRate · r_x
v_ego(px, py) = forwardRate · r_y
```

其中 `forwardRate` = 「本帧自车前进导致视野扩张的比例」（`EgoMotionEstimate.forwardRate`），与
`OpticalFlowBridge.divergence` **同量纲**（正 = 内容向外扩张 = 前进）。

### ★ 非等比拉伸 —— 本项目的关键几何事实（文件头注释）

`CaptureEngine` 明确注释：直通帧是
「**非等比拉伸到 640×640**（与训练/慢路径一致，不保持宽高比）；」，调用 `vImageScale_ARGB8888`。故：

- x/y 两方向**焦距不同**（`fx ≠ fy`），需按屏幕宽高比拆分
- 但**消失点恒在画面中心**（拉伸不改变中心）
- ⟹ **只需 2 个参数即可标定** —— 这是本项目比常规标定简单的地方

## 四、参数（全部 `AURORA_EGO_*`；声明为 `EgoMotionModel` 的 let 属性，在 `init()` 里从 `AuroraFlags` 读取）

| 参数 | 默认 | 含义 |
|---|---|---|
| `AURORA_EGO_MAX_FWD`（`AuroraFlags.egoMaxFwd` 读取，`EgoMotionModel.maxForwardRate`） | **0.5** | forwardRate 上限 |
| `AURORA_EGO_MAX_FLOW_PX`（`AuroraFlags.egoMaxFlowPx` 读取，`EgoMotionModel.maxFlowPixels`） | **80.0** | 光流像素上限（超限即 fail-open） |
| `AURORA_EGO_RESIDUAL_RATIO`（`AuroraFlags.egoResidualRatio` 读取，`EgoMotionModel.residualRatioThreshold`） | **0.6** | 残差比阈值 |
| `AURORA_EGO_MIN_CONF`（`AuroraFlags.egoMinConf` 读取，`EgoMotionModel.minConfidence`） | **0.35** | 最低置信度 |
| `AURORA_EGO_CHECK`（读取 `AuroraFlags.egoCheck`，写入 `EgoMotionModel.enabled`） | `off` = 关闭 | 总开关（关闭后行为与接线前一致） |

### ★ `typicalDt = 1.0 / 20.0` —— 20Hz 迁移已正确

`estimate(from:dt:)` 内部用 `typicalDt` 计算 `dtDeviation`，判定帧间隔是否偏离典型值。源码注释明确写：「2026-10-11 主循环最终定档 20Hz → typicalDt 必须与实际 tick 频率一致 → 20Hz → dt=0.05s」。**这是已正确落地的迁移**，不是漏改项——若 typicalDt 仍写 `1/30=0.0333`，dtDeviation 会误判 50% 偏离 → 误降置信度。

> 注：`1.0 / 20.0` 是**本模型内部的时间基准**，与 `EngineMain.engineTickHz`（当前 15.0，2026-10-22 由 20 降到 15）不是同一个量。若 tick 频率继续变化，这里是需要一并复核的硬编码点。

### ⚠️ 一个踩过的坑：**不要缓存环境变量字典**（源码注释）

> 初版写的是 `private static let env = ProcessInfo.processInfo.environment`，
> 结果 `AURORA_EGO_CHECK=off` 在 `--motion-selftest` 的 ④-8 项验证里**不生效**
> —— `static let` 只在**首次访问时初始化一次**，之后再 `setenv` 读到的还是旧值。

现在的做法：4 个阈值走 `static let`（`AuroraFlags.egoMaxFwd` 等，省掉每次 init 的环境变量读取），`AURORA_EGO_CHECK` 保持现读（`AuroraFlags.egoCheck` 是计算属性）——因为只有它需要在运行时切换（自检里用 `setenv("AURORA_EGO_CHECK", "off", 1)` 验证可回退）。

## 五、API

| 方法 | 用途 |
|---|---|
| `==(EgoVerdict, EgoVerdict)`（`Equatable` 合成） | 判定相等（`EgoVerdict` 是 `struct ... : Equatable`） |
| `estimate(from:dt:)` | 从光流估算自车运动（含置信度计算：`forwardRate` / `lateralRate` / 多因子相乘的 `conf`） |
| `predictedImageShift(for:ego:)` | 预测某检测框因自车运动产生的位移 |
| `verdict(for:ego:...)` | **给出裁决**（是否拦截该目标的速度更新，产出 `EgoVerdict.blocksPrediction`） |
| `maskShift(for:ego:)` | 预测自车运动让整张 `MaskGrid` 平移多少格；⚠️ **零调用（死代码）**——`grep -rn 'maskShift' Sources/` 排除定义后只剩 `LaneBridge` 两行「尚未落地」注记，从未被 LaneExtrapolator 或任何调用方接线 |

## 六、语义（三态）

| 裁决 | 含义 |
|---|---|
| `blocksPrediction = true`（文档旧称 `egoBlocked`） | 目标静止、自车在动 → **拦截** `MotionPredictor` 的速度更新 |
| `blocksPrediction = false` | 目标自身在动 |
| `nil` | **fail-open**（光流失效 / 超限 / dt 异常） |

## 七、自检实测（`--motion-selftest`，2026-10-02）

**PASS**。要点：

| 项 | 结果 |
|---|---|
| 径向模型对拍 | ±0.002500 |
| 静止目标 + 自车前进 | 残差比 **0.00**（→ 正确判定拦截） |
| 目标自身运动 | **0.90** → 不拦截 ✓ |
| fail-open | nil / oversized flow / bad dt **全部 fail-open** ✓ |
| 拦截计数前置条件 | 真的触发 ✓（`--motion-selftest` 里的 `lastEgoBlockedCount` 断言） |
| `AURORA_EGO_CHECK=off` | 判定关闭 ✓ |
| 性能 | p50 **0.0001 ms** / p95 **0.0001 ms** |

## 八、⚠️ 诚实边界（性能文档 §6.45.9 自述，此处忠实转述）

1. **相机参数未真机标定**：中心 `(320,320)`、`pitch=0` 是保守初值（由 `centerX` / `centerY` 从 `flowSize` 派生得到）。
   第三人称视角若有俯仰，径向模型会有系统偏差 —— 需真机数据修正。
2. **残差比阈值 0.6 是初值**（`residualRatioThreshold`）：太松会误拦真实运动目标，太紧抓不住「目标静止」。**必须用真实驾驶数据标定。**
3. **真机验证仍依赖 TCC**：光流只在 YOLO 直通帧到达时触发，
   而直通帧需**屏幕录制权限**（本机 `screen=false`）。
   ⟹ **本轮无法在真实驾驶中验证接线效果**，需开游戏实测。
4. **本轮可证明的**：几何正确性（对拍误差 `0.00e+00`）+ 不误拦 + fail-open 完备
   + 性能达标（1/250 预算）+ 一键回退可验证。
   **不能证明的**：真实驾驶中的精度提升幅度。

---

**本文件创建于 2026-10-02**（补 `代码-NN` 覆盖缺口）。本次重写：全部行号引用改为源码真实名字；`maskShift` 死代码记录与 `typicalDt` 20Hz 迁移说明保留。
