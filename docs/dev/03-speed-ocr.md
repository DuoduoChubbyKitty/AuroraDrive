# 三、速度识别子系统

> 覆盖源码：`Sources/AuroraDrive/SpeedOCRReader.swift`（1061 行）
> 上级：[开发者文档](../DEVELOPER_GUIDE.md) ｜ English: [Speed Recognition](en/03-speed-ocr.en.md)

## 3.1 一句话看懂

速度表上的三位数字（如 `120`）被切成 3 个小图，每个小图喂给一个 **5 层卷积神经网络**认出 0~9，三次结果拼成速度值；再经过**三道闸门**过滤掉明显不合理的读数，才最终显示在 UI 上。

网络认不出时（比如画面里根本没有速度表），有一个**字模模板匹配**作为备胎——但它当前处于停用状态（原因见 3.6）。

## 3.2 双引擎架构

`infer(nativePixelBuffer:)` 是唯一入口，每帧走三道闸：

| 闸 | 条件 | 不过时 |
|---|---|---|
| 闸 1 | 距上次推理 ≥ `inferInterval`（1/30 秒） | 静默跳过（正常节流，不记诊断） |
| 闸 2 | 上一帧还没推理完（`!isInferencing`） | 静默跳过 |
| 闸 3 | `cnnModel != nil` **或** 字模库非空 | `lastOCRDiagnostic = "CNN模型和字模均未加载"` |

通过闸门后进后台队列 `ocrQueue`，按 **CNN 优先、字模降级** 选择引擎：

```swift
if let cnn = cnnSnapshot {
    result = Self.recognizeCNN(slotImages: slotImages, model: cnn)   // 主引擎
} else {
    result = Self.recognize(slotImages: slotImages, glyphs: glyphsSnapshot)  // 降级
}
```

## 3.3 主引擎：CNN 推理（recognizeCNN）

模型：`models/speed_digit_cnn_v4.mlpackage`（5 层卷积 16→32→64→128→256 + 全连接，INT4 量化，1.2MB）。

**模型加载**（`loadCNNModel()`）——这里有个新版 macOS 的坑：

```swift
let compiledURL = try MLModel.compileModel(at: url)   // 先编译 .mlpackage → .mlmodelc
let model = try MLModel(contentsOf: compiledURL)       // 再加载编译产物
```

> 新版 macOS 的 `MLModel(contentsOf:)` 直接喂 `.mlpackage` 会抛 *"Compile the model with Xcode or MLModel.compileModel(at:)"*——必须先编译。候选路径两个（相对 `models/…` 与绝对路径），任一成功即返回；全部失败则静默（闸 3 会在 UI 显示诊断）。

**单槽推理流程**（`recognizeCNN`）：

1. 灰度化 `grayscalePixels`
2. Otsu 二值化统计前景像素（只用于 fg 检测，不参与推理）
3. `resizeNearest` 缩放到 **90 高 × 50 宽**（`templateHeight=90`，`templateWidth=50`）
4. `resizeGray` 灰度同步缩放，像素值 `/255.0` 归一化到 0~1
5. 填入 `MLMultiArray`，shape `[1, 1, 90, 50]`，float32，输入名 `"digit_input"`
6. `model.prediction(...)` → 输出 `"digit_output"` 形状 `(1, 10)`
7. argmax 取数字 + softmax 算置信度

三个槽各跑一次，拼成 `百位×100 + 十位×10 + 个位`，置信度取三槽均值。

## 3.4 槽位从哪来（cropSlots）

速度表三位数字在画面里的归一化位置（与 `tools/build_speed_glyphs.py` 同源，改一边必须同步另一边）：

```swift
slotCentersNorm = [0.479, 0.496, 0.512]  // 百/十/个位的中心 x
slotWidthNorm   = 0.014                   // 槽宽
slotYMinNorm    = 0.897                   // 槽上边界 y
slotYMaxNorm    = 0.932                   // 槽下边界 y
```

裁剪用 **CIImage 路径**（纯裁剪、不插值），输入是 CaptureEngine 环 1 降采样后的速度表 ROI 切片，槽位坐标按 `CaptureEngine.speedROINorm` 换算成 ROI 内相对坐标。CI 坐标系 y 轴向上，所以裁剪矩形做了一次 `y = sh - yMax` 的镜像换算。

## 3.5 三层校验（finish）

CNN 的原始输出**不会**直接上 UI，要过三道闸：

| 层 | 规则 | 不过时 |
|---|---|---|
| Layer 1 量程 | 速度必须在 `speedRange = 0...400` | 记 `errorMessage`，丢弃本帧 |
| Layer 2 跳变 | 与上一有效值差 > `maxJumpKmh`（60 km/h） | 本帧 `confidence = 0`，让下游 `speedValid` 判 false 走降级；`lastValidSpeed` 不更新（防污染） |
| Layer 3 多帧确认 | 1 秒窗口（`confirmWindowSec`）内最近 `confirmCount=3` 帧投票，容差 `confirmToleranceKmh=2` km/h，至少 `minConfirmAgreement = confirmCount/2+1 = 2` 帧一致 | 暂不输出，保留上一有效值 |

> **为什么要容差投票**：整数速度在匀加速时逐帧 ±1~2 km/h，要求"严格相等"永远凑不齐 3 帧。容差把相邻读数归为"同一个读数"，才能稳定确认。平票时取组内**最新**时间戳的候选（`confirmedSpeed`）。

**全部常量速查**：

| 常量 | 值 | 含义 |
|---|---|---|
| `speedRange` | 0.0...400.0 | Layer 1 量程 |
| `minSpeed` / `maxSpeed` | 0 / 300 | 三位数枚举范围 |
| `maxJumpKmh` | 60.0 | Layer 2 跳变阈值 |
| `confirmCount` | 3 | Layer 3 窗口帧数 |
| `confirmWindowSec` | 1.0 | Layer 3 时间窗 |
| `confirmToleranceKmh` | 2 | Layer 3 投票容差 |
| `minValidForegroundPixels` | 80 | 三槽前景像素下限（低于 = 画面无速度表） |
| `maxSlotResidualRatio` | 0.30 | 字模匹配残差上限（仅降级引擎） |
| `inferInterval` | 1/30 s | 推理节流 |

## 3.6 降级引擎：字模模板匹配（当前停用）

`recognize(slotImages:glyphs:)`：灰度 → Otsu 二值化 → 最近邻缩放 → 枚举 0~300 做三位数整体匹配（±1 像素九宫格投票取最小残差）。

**当前状态：不可用。** 原因链：

1. 字模库 `models/speed_glyphs.json` 是 **45×25** 尺寸（旧版生成）
2. CNN 版把 `templateHeight/Width` 升到 **90×50**
3. `loadGlyphsSync` 的尺寸校验 `45 != 90` 失败 → 静默拒绝 → 字模库为空
4. 字模重采样原始数据（`data/glyph_clips/*/frames/`）已丢失，无法重新生成 90×50 字模

**影响评估：无。** CNN 主引擎加载成功后，`infer` 永远走 CNN 分支，字模路径不会被触发。若未来想恢复降级路径：用 `RecordEngine` 的 `glyph_mode` 重新采样字模帧，再以 `tools/build_speed_glyphs.py`（模板尺寸已同步为 50×90）重新生成。

## 3.7 自检与排障

- fg 过低时自动存盘 `/tmp/aurora_ocr_dbg_*.png`（全屏缩略图 + 三槽裁图），用于定位"到底截到了什么"
- `lastOCRDiagnostic` 记录最近一次失败原因：字模/CNN 均未加载、槽位裁剪失败、fg 过低、CNN 推理失败等
- `--speed-selftest <目录>` 命令行自检：跑完整个目录输出每帧的速度与置信度
