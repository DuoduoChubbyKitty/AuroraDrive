# 四、视觉与推理子系统

> 覆盖源码：`CaptureEngine.swift`(639) `InferenceEngine.swift`(432) `YoloEngine.swift`(807) `ConfidenceEstimator.swift`(248) `RecordEngine.swift`(424) `Vendor/MetalGoose/`
> 上级：[开发者文档](DEVELOPER_GUIDE.md) ｜ English: [Vision & Inference](../英文版/04-vision-inference.en.md)

> **档案标注（2026-09-19 核对更新，基线 7b7d2db）**：本文件各节内容与代码核对一致，仅行数/底图订正（InferenceEngine 432 / YoloEngine 807 / RecordEngine 424；大地图底图 2026-09-13 升级 13056×13056 map-2026-08 扩图版）；速度 OCR 双模型细节见三级文档三（3.7 为字模移除档案）。

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
