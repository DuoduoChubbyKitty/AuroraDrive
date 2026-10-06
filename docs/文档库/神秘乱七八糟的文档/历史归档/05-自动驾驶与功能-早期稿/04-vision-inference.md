# 四、视觉与推理子系统

> 覆盖源码：`CaptureEngine.swift`(639) `InferenceEngine.swift`(432) `YoloEngine.swift`(807) `ConfidenceEstimator.swift`(248) `RecordEngine.swift`(424) `YolopxEngine.swift` `OpticalFlowBridge.swift` `MotionPredictor.swift` `FallbackGuard.swift` `Vendor/MetalGoose/` `Vendor/OpenCVFlow/`
> 上级：[开发者文档](DEVELOPER_GUIDE.md) ｜ English: [Vision & Inference](../英文版/04-vision-inference.en.md)

> **档案标注（2026-09-19 核对更新，基线 7b7d2db）**：本文件各节内容与代码核对一致，仅行数/底图订正（InferenceEngine 432 / YoloEngine 807 / RecordEngine 424；大地图底图 2026-09-13 升级 13056×13056 map-2026-08 扩图版）；速度 OCR 双模型细节见三级文档三（3.7 为字模移除档案）。
>
> **档案标注（2026-09-27 新增）**：补 4.8 YOLOPX 三合一感知、4.9 光流与运动预测。
> 这两块此前未进本文件（4.1~4.7 的基线早于它们落地）。
> 详细交付说明（实测数据/生产配置/13 个踩坑）见
> [探索文档/光流-运动预测-兜底-交付说明.md](../探索文档/光流-运动预测-兜底-交付说明.md)。

## 4.1 屏幕捕获（CaptureEngine）

- **引擎**：ScreenCaptureKit（SCStream），帧格式 `32BGRA`，帧队列深度 3，**30 fps 上限**
- **权限**：屏幕录制。首次用 `SCShareableContent.current` 触发系统授权，拒绝 → `.permissionDenied`
- **速度表 ROI**：`speedROINorm = CGRect(x:0.455, y:0.885, w:0.080, h:0.050)`——速度识别的裁剪区域由此定义

**帧分发**：每帧从捕获队列直发 4 条回调（「只存最新帧」的 pendingFrame 缓冲机制在 `AuroraDriveApp.swift`（DriveState 内），CaptureEngine 本身不做跳帧缓冲；YOLO 直通/ROI 回调经自持缓冲池与 SCStream 生命周期解耦）：

| 回调 | 消费者 |
|---|---|
| `onFrame` | UI 主画面 |
| `onYoloFrame` | YOLO 推理 |
| `onUpscaleFrame` | MetalGoose 显示层 |
| `onNativeFrame` | 速度 OCR（环 1 只拷 ROI ≈100KB） |

> pendingFrame「只存最新帧」的缓冲机制在 `AuroraDriveApp.swift`（DriveState 内），CaptureEngine 本身不做缓冲。

## 4.2 E2E 驾驶模型（InferenceEngine）

- **模型**：`m9_mono`（默认）；`assistEngine` 用同类的 `game_assist_control`。加载顺序：`.mlmodelc` 优先 → `.mlpackage` 回退
- **输入**：
  - `image` `[1,3,180,320]`（CHW，/255 归一化）
  - `vehicle_state` `[1,6]`，按 v2_new 契约填 `[speed_norm, curv*5=0, sin=0, cos=1, limit_norm, 0]`——头注释里的 11 维旧契约已废弃
- **输出**：`steer` / `throttle` / `brake` 三个标量，`readScalar` 从 `MLMultiArray[1,1]` 读 `[0,0]`
- **infer 签名**：`infer(image: CGImage, speedKmh: Double, speedLimitKmh: Double)`

## 4.3 YOLO 检测（YoloEngine）

- **模型**：`yolo26s.mlmodelc` 优先 → `.mlpackage` 回退；`inputSize = 640`
- **两条推理路径**：
  - `infer(image:)`：CGImage → `draw()` 拉伸进 640×640 BGRA（慢路径）
  - `inferFast(pixelBuffer:)`：640 BGRA 直通 memcpy（快路径，要求上游已缩放）
- **输出解析**（parse）：每行 `[x1,y1,x2,y2,conf,cls]` /640 归一化
- **置信度阈值**：`0.22`
- **CocoLabels**：COCO 80 类映射到 4 个业务标签——person[0]→`pedestrian`，vehicle[1..8]→`car`，sign[9,11,12]→`sign`，其余→`obstacle`

## 4.4 E2E 置信度估算（ConfidenceEstimator）

E2E 模型没有置信度头，用三路启发式信号加权出 [0,1] 分数，供降级状态机使用：

| 信号 | 权重 | 计算 |
|---|---|---|
| 输出一致性 | 0.5 | steer 标准差 → `1 - std×2` |
| 转向极端度 | 0.3 | `\|steer\|>0.95` 帧占比 |
| 画面有效性 | 0.2 | `CIAreaAverage` 亮度，有效窗 [0.08, 0.95] |

- `update(command:image:isLive:)` 第一步是 **isLive 门控**：链路死了置信度直接归零（修复过"死模型算 0.70 卡住 e2e 档"的 bug）
- 长窗惩罚：90 帧（3s@30Hz）内极端度 >70% → 置信度压到 `min(conf, 0.30)`
- 亮度在后台队列 `com.aurora.confidence.brightness` 计算，不阻塞主线程

## 4.5 录屏引擎（RecordEngine）——训练数据的源头

**标准录制**（`start(perspective:)`）输出到 `data/raw_clips/clip_<时间戳>/`：
- `frames/%06d.jpg`（640×360）
- `controls.csv`（表头 `t_sec,frame,steer,throttle,brake`，与键盘监听帧级对齐）
- `meta.json` + `view.txt`（FPV/TPV 视角）

**字模模式**（`glyphMode`）：只录 `speedROINorm` 原生 ROI 的 PNG 到 `data/glyph_clips/`——这是字模库重生成的数据源（字模路径已移除，帧数据此前已丢失，见三级文档三 3.7 档案）。

**背压控制**：`maxPendingWrites = 1`，磁盘写不过来时丢帧不堆积。

**磁盘护栏**：录制启动时删除最旧目录（`raw_clips` 与 `glyph_clips` 共用同一上限，防 640×360 JPEG 30fps 无上限累积撑爆磁盘）。

## 4.6 MetalFX 显示增强（Vendor/MetalGoose）

上游 <https://github.com/Stallion77RepoOfficial/MetalGoose>（GPL-3.0）。MGUP-1 Spatial 超分三档（Performance/Balanced/Quality）+ 插帧，呈现于无边框 overlay。

**架构红线**：

```
捕获(原生帧) → 推理 → 按键     ← 决策链，MetalFX 永不进入
        ↓
   MetalFX 超分/插帧 → overlay   ← 只给人眼
```

## 4.7 全收集地图（GameMapView）

大地图层：`bigworldmap-13056.jpg`（**13056×13056，MaaNTE 图源 map-2026-08 扩图版，2026-09-13 升级**；旧 11264×11264 `bigworldmapSecond.png` 仍留在 models/ 作回退候选）；标记层：`FINAL_complete_map_database.json`（nteguide 数据）。图层开关（传送点/材料/宝箱/谕石等）、手势缩放平移、玩家位置实时叠加。与 `MinimapTileCache`（8×8 瓦片缓存，详见三级文档二 2.8）配合渲染。

## 4.8 YOLOPX 三合一感知（YolopxEngine）

> ⚠️ **核心资产，模型文件一个字节都不能换。** 甲方围绕 YOLOPX 投资，
> 换模型 = 项目解散。本节及 4.9 的所有改动都只在外围，不动模型。

- **模型**：`models/yolopx/yolopx3_pal8_detfp.mlmodelc`（候选表首位，逐个回退）
- **规模**：33.03M 参数 / 148.11 GFLOPs；`inputSize = 640`（自有 letterbox，不复用 YoloEngine 的拉伸直通）
- **三输出**：`det`（YOLOX 检测，nc=1 只有车）/ `da`（可行驶区）/ `ll`（车道线）
- **掩码**：下采样到 `maskGridSize = 160` 的 `MaskGrid`（省 1.0~2.4ms，数学等价）
- **实测**：`pal8_detfp` 62.15ms min / 66.86 med → **15.0 Hz**；`w8a16` 15.1Hz；`int8` 12.6Hz
- **物理地板**：148.11 GFLOPs ÷ 9.26 TFLOPS（ANE 实测峰值）= **16.0ms**；整网 10ms 需 14.81 TFLOPS（≈160% 峰值，物理不可能）
- **降级**：`isDegraded` 初始为 true（模型没跑起来前一律不可信）；`loadAttemptLog` 记录候选逐个尝试结果
- **防重叠**：`isInferencing` 守卫 + 独立串行队列 `com.aurora.yolopx`

> ⚠️ 已实测否决的优化方向（勿重试）：量化（w8 无收益 / w4 ll IoU 0.7808 / w8a8 ll IoU 0.4395 / a8 93.58ms）、
> stem 改 stride（74.37ms 更慢）、关 decode（无变化）、归一化烧进卷积（58.18ms 无收益）。

### 4.8.1 掩码失效判定：下限 + **上限**双向判据（2026-09-27 R2 补，t47）

> 本文 4.8 节原只覆盖模型/性能，**未记载掩码判据**。此处补上——这是 seg 头
> 可信度的核心防线，涉及一次公开的自我纠错。

**判据常量**（`YolopxEngine.swift:202–254`）：

| 常量 | 值 | 含义 |
|---|---|---|
| `lanePositiveFloor` | **0.002** | 车道线正像素占比下限（< 此判头失效） |
| `drivablePositiveFloor` | **0.02** | 可行驶区下限 |
| `lanePositiveCeil` | **0.25** | 车道线**上限**（> 此判异常膨胀） |
| `drivablePositiveCeil` | **0.70** | 可行驶区**上限** |

**为什么需要上限**（源码 209–215 行注释）：
> 原判定**只有下限没有上限**。实测（t31 §3.1 前景占比扫描）：
> ll 前景占比从 1.70% 一路涨到 **38.89%**（= 真实上限的 10 倍），
> `isDegraded` **全程为 false**，`LaneFallback` 全程照给建议、`confidence` 可达 1.00。
> 而「大面积前景」正是 seg 头失效最典型的形态之一……一个"满屏都是车道线"
> 的掩码会产出看似合法（steer=±0.25、conf=1.00）的建议，**下游无从识别**。

**★ 自我纠错记录（源码 219–228 行，务必保留）**：
> ⚠️ 2026-09-27 自我纠错记录：
> v1 稿按 t31 报告转述的「真实 ll 仅 1.3~3.9%」把 ll 上限设为 **0.10**。
> 随后用 pal8_detfp + **169 张真实行车图**（data/validation_clips，8 类工况）实测真实分布，
> 发现该值**会被真实帧触发**：
> ```
> ll coverage  min=0.0000 P05=0.0002 P50=0.0266 P95=0.0694 max=0.1072
> da coverage  min=0.0000 P05=0.0102 P50=0.1159 P95=0.3237 max=0.3812
> ```
> 即 0.10 的上限会在真实行驶中误判"降级"→ 兜底闭嘴（fail-open 方向安全，
> 但属于**功能无谓失效**）。故上调 ll 至 0.25、da 至 0.70。
> **教训**：t31 报告的 1.3~3.9% 是 t30 时期少量素材的口径；用它的上限去定阈值
> 等于把"样本上限"当"总体上限"。**阈值必须以当期全量实测为准。**

**v2 取值**：
- ll 上限 0.25 = 真实 max 0.1072 的 **2.33 倍**，169/169 真实帧全部放行
- da 上限 0.70 = 真实 max 0.3812 的 **1.84 倍**

**⚠️ 诚实局限（源码 237–246 行，勿删）**：
1. 这是**边距法**（真实上限 × 安全系数），**不是**分布分位标定——现有素材不足以定分位数
2. **未覆盖区间**：ll 的 10.7%~25%、da 的 38.1%~70% 仍会被采纳。**这是已知缺口，不是"已解决"**
3. 偏离方向有意选保守：上限偏松只漏掉部分塌陷；偏紧会误判降级
4. 待有「真实 seg 头崩塌」素材后应按分位数重标（属精度线任务）

**★ 对本文 4.8 节「降级」条目的补充**：`isDegraded` 不只是"模型没跑起来"（初始 true），
运行期还由**上下限双向判据**驱动——低于下限（塌陷）或高于上限（膨胀）都判降级。

## 4.9 光流 + 运动预测（OpticalFlowBridge / MotionPredictor / FallbackGuard）

**要解决的问题**：YOLOPX 约 15Hz，主循环 30Hz。若每帧只读「最近一次检测结果」，
两次推理之间检测框**完全静止** —— 目标在动、框不动，决策层按过期位置开车。

**解法**：光流估计帧间运动 → α-β 滤波维护每个目标 (位置, 速度) → 真值到达时校正、
缺席时外推。把 15Hz 真值补成 30Hz。

### 4.9.1 光流实现（`Vendor/OpenCVFlow` + `OpticalFlowBridge.swift`）

- **算法**：OpenCV `cv::DISOpticalFlow` **PRESET_ULTRAFAST**（Dense Inverse Search，**CVPR 2016 论文算法**，OpenCV 官方 `video` 模块内建，**非自研**）
- **为什么不用 Apple 官方**（用户红线 ≤5ms，本机 640×640 同批实测）：

  | 方案 | p95 | 判定 |
  |---|---|---|
  | Apple `VTOpticalFlow`（VideoToolbox 硬件） | 10.28 ms | ✗ |
  | Vision `VNGenerateOpticalFlow` | 27.43 ms | ✗ |
  | **OpenCV DIS ULTRAFAST** | **1.91 ms** | ✓ |

- **生产配置（两处关键调优，勿改）**：
  1. **4:1 抽样求中位数**（`kMedianSampleStep`）：全量 p99 5.32ms 卡红线 → 抽样后 p95 1.91ms。行车光流场高度平滑，中位数对抽样不敏感
  2. **`setNumThreads(2)`**（`kOpenCVThreads`）：线程多≠快。默认满核在 7 路负载下 p95 达 20.9ms；固定 2 线程 3.53ms
- **精度**：合成图误差 0.07px；**真实行车纹理**误差 0.12~0.33px（红线 0.5px）
- **静态场景不产生假运动**：静止录制帧输出 dx=0.000（正确 —— 没有编造运动）
- **接口**：纯 C（`ad_dis_create/destroy/compute`），只回传「自车运动摘要」（dx/dy/散度），不回传稠密流场（3.3MB 跨语言搬运比计算本身还贵）
- **线程安全**：`ad_dis_compute` **非线程安全**，同一 ctx 不可并发；Swift 侧用私有锁串行化
- **fail-open**：失败一律 `valid=0`，不抛异常不崩溃；调用方退化为「不预测」

### 4.9.2 运动预测（`MotionPredictor.swift`）

- **滤波器**：α-β（卡尔曼在「匀速模型 + 稳态增益」下的解析解）。α=0.55 / β=0.25
- **速度单位统一为「归一化坐标 / 秒」**，帧率变化不用改参数
- **关联**：IoU 贪心匹配，门限 0.25
- **外推门槛**：速度需连续 3 帧一致才启用（防单帧抖动造出假运动）
- **硬限幅**：单帧外推位移 ≤0.15（视野 15%），防滤波器发散把框甩飞
- **超时**：10 帧无真值停止外推；30 帧无真值移除目标
- **帧驱动语义**：**每 tick 恰好调用一次 `predict`** —— 它代表「时间前进一帧」；
  `ingest` 只做校正不做计时。`missedFrames` 在 `predict` 里自增（初版放 `ingest` 导致外推永不触发）
- **实测**：外推 3 帧误差 **0.0009**（阈值 0.03）

### 4.9.3 双结构几何兜底（`FallbackGuard.swift`）

用户提的两个判据（纯几何，不依赖模型置信度）：

- **结构 A —— 自车/前车位置**：画面中心带（`egoCenterHalfWidth=0.25`）内**面积最大**的框。
  面积是距离的单调代理，中心带是横向偏移的门 —— 二者结合等价于「正前方最近的障碍」
- **结构 B —— 框叠加 = 碰撞**：IoU ≥0.15 **或** 中心距 ≤0.06 → 判定重叠 → 紧急避让
  （中心距补 IoU 盲区：大框套小框时 IoU 可能很低但同样危险）

**与 `LaneFallback` 的两点关键区别**：

1. **不限定 `decided` 状态** —— 碰撞是硬安全约束，不是「某状态下的驾驶风格」。
   主驾再健康，看到两个框叠一起也必须刹
2. **降级时照常工作** —— 只依赖检测框不依赖掩码；掩码降级往往意味着「模型半坏」，
   恰恰最需要几何兜底（与 LaneFallback 的 fail-open 方向相反）

**防误触靠内部门**：连续 3 帧确认 + 几何合法性校验（越界数据丢弃）+ 保守输出
（油门压到 0.2、转向限幅 ±0.25）。

### 4.9.4 接线（tick 内）

```
CaptureEngine 直通帧(640×640 BGRA)
       │
       ├─→ runOpticalFlow() ─→ 转灰度 ─→ DIS ─→ (dx, dy, 散度)
       │        ⚠️ 必须在帧消费点同步执行：直通缓冲是池化私有缓冲，
       │           跨步骤持有会 use-after-recycle
       ↓
YOLOPX / yolo26s 真值 ──→ MotionPredictor.ingest()
                                │
                    predict(dt) ← 每 tick 恰好一次
                                │
                    predictorDetections（本 tick 缓存快照）
                                │
                    ├─→ effectiveDetections（决策层）
                    └─→ FallbackGuard ─→ advice() ─→ applyLaneAdvice（第 5.5 步）
```

- ⚠️ `effectiveDetections` **只读缓存**，不能自己调 `predict()` —— 该属性每 tick 被读多次，
  会多推进帧计数导致速度估计错乱
- 真值来源：YOLOPX 优先，回落 yolo26s

### 4.9.5 自检

```bash
./AuroraDriveUI --opticalflow-selftest   # C层可用性 / 位移精度 / 延迟红线 / 退化路径
./AuroraDriveUI --motion-selftest        # 外推精度 / fail-open / 双结构判据
./AuroraDriveUI --yolopx-selftest        # 模型精度未回归
```

三个自检**全部 0 失败**。极端工况边界（如实记录，勿误读）：

| 场景 | p95 | 判定 |
|---|---|---|
| 空载 | 1.7 ms | ✓ |
| 7 路负载 @ **UTILITY**（模拟游戏/后台，生产即如此） | 3.7 ms | ✓ |
| 7 路负载 @ **与光流同优先级**（把 8 核占死） | ~9 ms | ✗ |

生产 tick 由 `DispatchQueue(qos: .userInteractive)` 驱动，游戏是普通优先级 → 属于第二行。
第三行在真实场景不存在（真有 7 个 userInteractive 满载线程，App 的 30Hz 早就先崩了）。
自检已显式提升线程优先级（`elevateCurrentThreadPriority()`），否则会测出假超标。

> **状态（2026-09-27）**：已实现并自检通过，**尚未真机跑过驾驶**。光流目前只在 YOLO 直通
> 活跃时执行；直通失效会退化为「不预测」（fail-open，不出错但少一层）。
