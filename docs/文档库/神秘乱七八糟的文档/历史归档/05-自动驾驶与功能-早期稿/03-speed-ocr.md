# 三、速度识别子系统

> 覆盖源码：`Sources/AuroraDrive/Inference/SpeedOCRReader.swift`（**1244 行**实测；本文写 1243 行，属末行计数差异，**架构零变化**）
> 上级：[开发者文档](DEVELOPER_GUIDE.md) ｜ English: [Speed Recognition](../英文版/03-speed-ocr.en.md)

> **档案标注（2026-09-19 核对更新）**：2026-09 双模型改造后架构为 **PP-OCRv6 整行主路径 + per-digit CNN 备用**（字模模板匹配已删除）；推理节流由 1/30 改为 1/15（15Hz）。下文 3.1~3.6 按新架构订正（3.3 PP-OCR 主 / 3.4 CNN 备 / 3.5 槽位 / 3.6 三层校验），3.7 为字模路径的移除档案。

## 3.1 一句话看懂

速度表读数由**双模型**识别：**主路径 PP-OCRv6 微调整行模型**（ROI 切片整帧推理 → CTC 解码 → 取数字串后 3 位），**备用路径 per-digit CNN**（三位数字切成 3 个小图，各喂 5 层 CNN 认 0~9）。PP-OCR 发生运行时系统级故障（推理 throw / 输出缺失）时同帧自动降级 CNN 并在 UI 橙色警示（`engineNotice`）；"读不到"类业务诊断不算故障、不切换。

识别结果再经过**三层校验**（量程 / 跳变 / 多帧确认，见 3.6）才显示在 UI 上。

**档案**：早期的**字模模板匹配**（speed_glyphs.json + 0~300 枚举）已被双模型完全取代并删除（见 3.7）。

## 3.2 双引擎架构

`infer(nativePixelBuffer:)` 是唯一入口（15Hz：每帧走三道闸；节流常量 `inferInterval = 1/15`，代码中闸 1 注释仍残留旧 "5Hz/200ms" 说法，以常量为准）：

| 闸 | 条件 | 不过时 |
|---|---|---|
| 闸 1 | 距上次推理 ≥ `inferInterval`（1/15 秒） | 静默跳过（正常节流，不记诊断） |
| 闸 2 | 上一帧还没推理完（`!isInferencing`） | 静默跳过 |
| 闸 3 | 当前引擎模型可用（`.ppocr` → `ppocrModel != nil`；`.cnn` → `cnnModel != nil`） | `lastOCRDiagnostic = "当前引擎 X 模型不可用"` |

通过闸门后进后台队列 `ocrQueue`，按 **PP-OCR 优先、CNN 备用** 执行（`activeEngine` 由 init 加载结果与运行时故障切换决定）：

```swift
switch engineSnapshot {
case .ppocr where ppocrSnapshot != nil:
    result = Self.recognizePPOCR(roiBuffer:nativePixelBuffer, model: ppocrSnapshot!, keys: ppocrKeysSnapshot, isROISlice: true)  // 主路径
    if let err = result.error, let cnn = cnnSnapshot {
        // 系统级故障 → 同帧补跑 CNN，不丢帧（engineNotice 提示）
        result = Self.recognizeCNN(slotImages: slots, model: cnn)
    }
case .cnn:
    result = Self.recognizeCNN(slotImages: slots, model: cnn)  // 备用路径（3 槽裁剪）
}
```

> 双模型加载失败在 `init` 即写 `errorMessage` / `engineNotice`（如「CNN 备用模型未加载（speed_digit_cnn_v4 缺失），PP-OCR 故障时无降级」），绝不静默。

## 3.3 主引擎：PP-OCRv6 整行推理（recognizePPOCR）

模型：`models/ppocrv6_tiny_ft_int8.mlpackage`（PP-OCRv6 微调 INT8，约 1.2MB）+ 字符表 `models/ppocrv6_tiny_ft_keys.txt`（6904 行；解析时**只去换行、不能 trim**——第 617 行是全角空格 U+3000，合法 token）。

- **输入**：灰度 → 双线性缩放到 **48×136**（`ppocrInputHeight/Width`）→ 复制 3 通道（NCHW）
- **输出**：CTC logits `[1, T, 6906]`（6906 = blank + 6904 keys + space），贪心解码取**数字串后 3 位**
- **门槛**：`ppocrMinDigits=2`（数字串长度下限）/ `ppocrMinConfidence=0.30` / `ppocrMinForegroundRatio=80/3375≈2.37%`（Otsu 前景占比低于此判「画面无速度表」，返回 fg 诊断）
- **静止帧复用**：ROI 灰度做 16×6 块均值 hash，与上一帧一致 → 直接返回缓存结果，跳过 Otsu/缩放/ANE 推理/CTC 全链（实测可跳过一半以上帧）

**模型加载**（`loadPPOCRModel()`）——新版 macOS 的坑（CNN 路径同样适用）：

```swift
let compiledURL = try MLModel.compileModel(at: url)   // 先编译 .mlpackage → .mlmodelc
let model = try MLModel(contentsOf: compiledURL)       // 再加载编译产物
```

> 新版 macOS 的 `MLModel(contentsOf:)` 直接喂 `.mlpackage` 会抛 *"Compile the model with Xcode or MLModel.compileModel(at:)"*——必须先编译。候选路径（`AuroraPaths.projectRoot()/models/…` 与相对路径），任一成功即返回。

## 3.4 备用引擎：per-digit CNN（recognizeCNN）

模型：`models/speed_digit_cnn_v4.mlpackage`（5 层卷积 16→32→64→128→256 + 全连接，INT4 量化，1.2MB）。

**单槽推理流程**（`recognizeCNN`）：

1. 灰度化 `grayscalePixels`
2. Otsu 二值化统计前景像素（只用于 fg 检测，不参与推理）
3. `resizeNearest` 缩放到 **90 高 × 50 宽**（`templateHeight=90`，`templateWidth=50`）
4. `resizeGray` 灰度同步缩放，像素值 `/255.0` 归一化到 0~1
5. 填入 `MLMultiArray`，shape `[1, 1, 90, 50]`，float32，输入名 `"digit_input"`
6. `model.prediction(...)` → 输出 `"digit_output"` 形状 `(1, 10)`
7. argmax 取数字 + softmax 算置信度

三个槽各跑一次，拼成 `百位×100 + 十位×10 + 个位`，置信度取三槽均值。

## 3.5 槽位从哪来（cropSlots，仅 CNN 备用路径用）

速度表三位数字在画面里的归一化位置（槽位常量与 `tools/build_speed_glyphs.py` 同源，改一边必须同步另一边）：

```swift
slotCentersNorm = [0.479, 0.496, 0.512]  // 百/十/个位的中心 x
slotWidthNorm   = 0.014                   // 槽宽
slotYMinNorm    = 0.897                   // 槽上边界 y
slotYMaxNorm    = 0.932                   // 槽下边界 y
```

裁剪用 **CIImage 路径**（纯裁剪、不插值），输入是 CaptureEngine 环 1 原生拷贝（≈100KB，非降采样）的速度表 ROI 切片，槽位坐标按 `CaptureEngine.speedROINorm` 换算成 ROI 内相对坐标。CI 坐标系 y 轴向上，所以裁剪矩形做了一次 `y = sh - yMax` 的镜像换算。（PP-OCR 主路径不需要裁槽——ROI 切片整帧直接喂模型。）

## 3.6 三层校验（finish）

识别引擎（PP-OCR 或 CNN）的原始输出**不会**直接上 UI，要过三道闸：

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
| `minSpeed` / `maxSpeed` | 0 / 300 | 三位数枚举范围（现存于自检路径；字模枚举已删） |
| `maxJumpKmh` | 60.0 | Layer 2 跳变阈值 |
| `confirmCount` | 3 | Layer 3 窗口帧数 |
| `confirmWindowSec` | 1.0 | Layer 3 时间窗 |
| `confirmToleranceKmh` | 2 | Layer 3 投票容差 |
| `minValidForegroundPixels` | 80 | 三槽前景像素下限（CNN 路径；PP-OCR 用比例版 `ppocrMinForegroundRatio=80/3375`） |
| `inferInterval` | 1/15 s | 推理节流（原 1/30） |

## 3.7 字模模板匹配（已删除，档案）

> **档案（2026-09 双模型改造移除；2026-09-19 核对）**：`recognize(slotImages:glyphs:)` 字模引擎（灰度 → Otsu → 最近邻缩放 → 枚举 0~300 三位数整体匹配）与 `loadGlyphsSync`/`maxSlotResidualRatio` 一并从 SpeedOCRReader 删除，由 PP-OCRv6 主路径取代。`models/speed_glyphs.json`（45×25，旧版生成）仍留在仓库但**代码已不再引用**；字模重采样原始数据（`data/glyph_clips/*/frames/`）此前已丢失（目录现为空），90×50 字模无法重新生成。若未来要恢复字模路径：需先用 `RecordEngine` 的 `glyphMode` 重新采样字模帧，再以 `tools/build_speed_glyphs.py` 重新生成。

## 3.8 自检与排障

- fg 过低（`diag` 以 `fg=` 开头）时自动存盘 `/tmp/aurora_ocr_dbg_*.png`（ROI 缩略图，覆盖写不阻塞主线程），用于定位「到底截到了什么」
- `lastOCRDiagnostic` 记录最近一次失败原因：当前引擎模型不可用、槽位裁剪失败、fg 过低、置信度不足、数字串过短、无法识别等；引擎切换/加载提示走 `engineNotice`（UI 橙色警示）
- `--speed-selftest <目录>` 命令行自检（`selfTestDirectory`）：跑完整个目录输出每帧的速度与置信度
