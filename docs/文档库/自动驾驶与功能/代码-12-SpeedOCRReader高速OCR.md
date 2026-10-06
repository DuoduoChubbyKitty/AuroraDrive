# 代码-12 SpeedOCRReader 高速 OCR

> 覆盖源文件：`Sources/AuroraDrive/Inference/SpeedOCRReader.swift`（**1540 行**，2026-10-06 `wc -l` 实测重核；本篇原按 1452 行版本编写，行号已按当前快照校正，含 2026-09-30「模型加载移出 init」改造）。基于当前仓库逐单元编写。

## 一、双模型架构与常量（第 1–152 行）

**架构（3–20 行头注释）：**

| 路径 | 模型 | 流程 |
|---|---|---|
| **主路径** | PP-OCRv6 整行推理 | ROI 切片整帧 → 灰度 → 双线性 48×136 → 复制 3 通道 → CTC 解码 → 取数字串后 3 位 → 置信度门槛 |
| **备用** | per-digit CNN（speed_digit_cnn_v4） | cropSlots 裁 3 槽 → 逐槽 90×50 → softmax 取位 |
| **切换** | — | PP-OCR **运行时系统级故障**（推理 throw / 输出缺失）→ 同帧自动降级 CNN 并写 engineNotice（UI 橙色警示 + 车速旁引擎标签变橙）；**"读不到"类业务诊断（fg 低 / 置信低 / 数字串短）不算故障不切换** |
| **历史** | — | 早期「字模模板匹配」（speed_glyphs.json + 0~300 枚举残差）已被双模型完全取代并删除；cropSlots 的槽位常量仍被 CNN 路径使用 |

**为什么主路径用 PP-OCRv6 微调整行模型（22–27 行注释）**：通用 Vision OCR 对游戏 HUD 空心数字误识别率高（"000"→"NTO0U"）；自训 per-digit CNN（99.98%）是分布内成绩，换分辨率/游戏/UI 可能崩。PP-OCRv6 微调模型 = 官方通用预训练表征 + 本项目场景对齐，**冻结测试集（整段未见 clip，5077 张）99.9803%，泛化性最强**（见 PPOCRV6_FINETUNE_REPORT.md）。

**线程模型**：`main` 入口 `infer()`（:531）→ 后台 `ocrQueue`（:199-201，`com.aurora.speedocr`, .userInteractive）推理 → Task @MainActor `applyEngineUse()`（:615，引擎状态）+ `finish()`（:624）写最新快照。**generation 计数器（:204-205）防 reset() 后在途结果过期**。

**无效帧前置检测**：载入/视角错位帧画面里没有速度表 → Otsu 前景比例过低直接判无效，**不进入推理（防乱报）**；PP-OCR 侧另有置信度门槛与数字串长度规则兜底。

**类声明（第 47–50 行）**：`@Observable @MainActor final class SpeedOCRReader`——输入是 CaptureEngine `onNativeFrame` 的原生 CVPixelBuffer（环1 后为速度表 ROI 切片，槽位坐标经 speedROINorm 换算到 ROI 相对坐标，:45-46 注释）。

**槽位常量（CNN 备用路径用；与 tools/build_speed_glyphs.py 同步，第 65–85 行）：**

| 常量 | 行号 | 值 | 说明 |
|---|---|---|---|
| `slotCentersNorm` | :71 | `[0.479, 0.496, 0.512]` | 3 个数字槽的归一化 x 中心（左上角原点）；2026-08-15 由 clip_20260815_130055 实测校准：ROI 内 digit centers ≈ [71,120,169]px |
| `slotWidthNorm` | :75 | `0.014` | 每槽归一化宽度（覆盖数字 + 抖动余量）；实测最大数字宽度 ≈ 41px/2940px = 0.014；**旧 0.022 导致相邻槽重叠 17~21px** |
| `slotYMinNorm` | :79 | `0.897` | 数字本体归一化 y 上界——**y_min 必须跳过仪表台顶部反光带，否则 Otsu 把整张判定为前景** |
| `slotYMaxNorm` | :81 | `0.932` | y 下界——由实测数字底部 0.9319 取 0.932，**避免旧 0.924 切掉下半段笔画** |
| `templateHeight / templateWidth` | :84-85 | 90 / 50 | 模板缩放尺寸（H×W）；与字模库 JSON 里 template_height/template_width 一致 |

全部 `nonisolated static let`——静态常量跨并发域可访问。

**节流 / 范围 / 校验常量（第 87–125 行，行号已重核）：**

| 常量 | 行号 | 值 | 说明 |
|---|---|---|---|
| `inferInterval` | :93 | `1.0/15.0` 秒 | **OCR 时间闸：15Hz**。2026-09-12 由 30Hz 降为 15Hz：速度是缓变量，15Hz 对控制闭环绰绰有余，游戏满载时（线程被挤到效率核）每秒推理次数减半 = 卡顿痛感减半。多帧确认 confirmCount=3 在 15Hz 下窗口 200ms，依然远快于驾驶反应需求 |
| `speedRange` | :96 | `0.0...400.0` | 车速合理范围（km/h），超出视为识别噪声 |
| `minSpeed / maxSpeed` | :100-101 | 0 / 300 | 速度匹配范围（用户要求；游戏速度表量程 0~400，>300 由量程校验拦截）；匹配时枚举 301 个三位数组合（:99） |
| `minValidForegroundPixels` | :105 | 80 | 无效帧前置检测：3 槽二值化前景像素总数 < 此值 = 画面里没有速度表。有效帧前景 ~450+ 像素；载入/视角错位帧 < 50 |
| `maxJumpKmh` | :109 | 60.0 | 跳变阈值：与上一帧有效读数差值上限；跨阈值视为噪声帧（置信度置 0，走降级路径），不更新 speedKmh |
| `confirmCount` | :114 | 3 | 多帧确认：最近 N 帧参与投票；**注意（:112-113）：整数速度在单调加减速时逐帧 ±1~2 km/h，靠 confirmToleranceKmh 容差把相邻读数归为"同读数"，否则平台值之外永无确认** |
| `confirmWindowSec` | :117 | 1.0 | 多帧确认窗口：仅最近 1 秒内的样本参与投票 |
| `confirmToleranceKmh` | :121 | 2 | 多帧确认读数容差：\|a-b\| <= 2 视为"同读数"；大跳变已由 maxJumpKmh=60 挡住，此容差只针对逐帧微扰 |
| `minConfirmAgreement` | :125 | `confirmCount/2 + 1`（派生计算属性） | 多帧确认最少一致帧数（**严格多数**）：confirmCount=3 → 2；confirmCount=5 → 3 |

## 二、PP-OCR 路径常量、状态输出与双模型加载（第 127–530 行）

**PP-OCRv6 整行路径常量（第 127–152 行）：**

| 常量 | 行号 | 值 | 说明 |
|---|---|---|---|
| `ppocrInputHeight / ppocrInputWidth` | :132-133 | 48 / 136 | 推理输入（NCHW）：高 48 固定，**宽 136 = ceil(51×48/18)**。训练裁片为 51×18（= speedROINorm ROI @640×360 录制帧），高 18→48 放大时宽 51×(48/18) = 136，**与评测脚本 eval_onnx.py / eval_coreml.py 完全同参** |
| `ppocrNumClasses` | :136 | 6906 | CTC 解码输出类别数 = **blank(1) + keys.txt(6904) + space(1)** |
| `ppocrKeysLines` | :140 | 6904 | keys.txt 行数校验值（防字典/模型错位）。**keys.txt 第 617 行是全角空格 U+3000，属合法 token——加载时只去换行符、绝不能用 trim——否则行内容漂移 +1，全部索引错位** |
| `ppocrMinDigits` | :143 | 2 | 解码规则 2：数字串长度 < 2 → 判无效（模型输出噪声帧常解成单字符） |
| `ppocrMinConfidence` | :148 | 0.30 | 解码规则 3：置信度 < 0.30 → 判无效。微调后全测试集最低置信 0.8343（PPOCRV6_FINETUNE_REPORT.md §5），0.30 极安全；同时下游 speedValid(conf>0.3) 语义保持一致 |
| `ppocrMinForegroundRatio` | :152 | `80.0/3375.0` | 前置无效检测的**等比例阈值**：旧路径 3 槽 3375 像素上 fg<80 ≈ 2.37%，整行路径按比例换算（窗口分辨率随全屏分辨率变化，**绝对像素数不可比**） |

**状态输出（第 154–197 行，主线程读）：**

| 成员 | 行号 | 说明 |
|---|---|---|
| `speedKmh: Double`（private(set)，默认 -1） | :157 | 最新读取到的车速（km/h）；无结果时为 -1 |
| `confidence: Double`（private(set)，默认 0） | :160 | 最新读取的置信度（0~1）；失败为 0 |
| `isInferencing`（private(set)） | :163 | 是否正在 OCR（防重叠） |
| `errorMessage: String?`（private(set)） | :168 | 最近一次错误描述（预留字段，暂未接入 UI）——**仅记录系统级错误与校验拒绝原因；"缺模板/残差过高"属正常情况不写入** |
| `engineNotice: String?`（private(set)） | :65 | 引擎切换警示（UI 橙色提示，PP-OCR 故障降级 CNN 时写入） |
| `lastResultTime: Date?`（private(set)） | :171 | 最近一次成功读取时间（判断快照新鲜度） |
| `cnnModel: MLModel?`（@ObservationIgnored） | :175 | CNN 模型（speed_digit_cnn_v4.mlpackage），替代模板匹配 |
| `ppocrModel: MLModel?`（@ObservationIgnored） | :182 | PP-OCRv6 微调整行模型（ppocrv6_tiny_ft_int8.mlpackage，1.2 MB）——输入 image [1,3,48,136] fp32（灰度复制 3 通道，归一化 (v/255-0.5)/0.5）、输出 logits [1,T,6906]（CTC 头）；加载成功时为最高优先级路径 |
| `ppocrKeys: [String]`（@ObservationIgnored） | :186 | keys.txt 字符表——**下标 0..6903 ↔ CTC index 1..6904；0=blank、6905=space 不入表** |
| `lastOCRDiagnostic: String`（private(set)） | :191 | 最近一次 OCR 诊断（为什么没出结果）；成功读出时清空。取值示例：字模未加载 / 裁剪失败 / fg=45 过低(画面无速度表) / 残差=1520 超阈值 |
| `lastNativeSize: CGSize`（private(set)） | :195 | 最近一次原生帧尺寸（调试用；0×0 表示尚未收到帧） |

**内部状态（第 199–224 行）**：`ocrQueue`（:199-201）、`generation`（:204-205，**reset() 时递增，在途 OCR 完成后比对，丢弃过期结果**）、`lastInferTime`（:209，时间闸）、`lastValidSpeed`（:213，跳变过滤）、`candidates`（:217，多帧确认候选历史）、`modelLoadSerial` 串行加载队列（:223-224，2026-09-30 修复配套）。

**`init()`（第 226 行起）——模型加载已移出 init（2026-09-30 修复，:229-260 注释）**：原实现 init 内同步 `loadCNNModel()/loadPPOCRModel()`（主线程同步 MLModel I/O）导致 Finder/open 启动时**进程永久空转**（AttributeGraph 更新阻塞在 DriveState.init → SpeedOCRReader.init → MLModel(contentsOf:)）。现改为**后台异步加载 + 惰性补加载**（`ensureModelsLoaded()` :318，由 `infer()` 闸 0 调用 :534）；双模型加载结果仍经 activeEngine / engineNotice / errorMessage 审计（activeEngine :61，SpeedOCREngine 枚举 :55），**绝不静默**——任一缺失都显式提示。

**`loadPPOCRModel()`（第 247–288 行）**：

- 模型路径候选：`projectRoot()/models/ppocrv6_tiny_ft_int8.mlpackage` 与相对路径双候选
- **字符表先于模型加载**（缺表则模型无法解码）：keys.txt 双候选；**加载语义（263–264 行注释）**：与训练端 PaddleOCR 一致——只去换行（`\n` / `\r\n`），**绝不能 trim**——第 617 行是全角空格 U+3000（合法 token），trim 会把它滤掉导致行数 6903、索引错位
- 尾随空串去掉（文件末尾换行产生，不计入 6904 行）
- `guard lines.count == ppocrKeysLines`（行数校验，防字典/模型错位）
- **新版 macOS 对 .mlpackage 需先编译再加载**：`try MLModel.compileModel(at:)` → `MLModel(contentsOf: compiledURL)`
- 模型加载失败则 **ppocrKeys 也清空**（保持"整组可用"语义，285 行）+ ppocrLoadFailure 记原因

**`loadCNNModel()`（第 291–309 行）**：双候选路径（相对 + 硬编码绝对）→ 编译加载；**加载失败静默**（infer 闸门会显示"CNN模型未加载"）——与 PP-OCR 的显式提示不同（因为 CNN 只是备用）。

## 三、infer() 闸 0 + 三闸门与同帧降级链（第 531–613 行）

**`infer(nativePixelBuffer: CVPixelBuffer)`（第 531–612 行）**——喂入一帧原生速度表 ROI 缓冲：CIImage 路径裁 3 槽（不插值）→ 后台 OCR → 主线程写快照。

**闸 0 + 主线程三闸门（532–551 行）：**

| 闸 | 行号 | 条件 | 行为 |
|---|---|---|---|
| 闸 0 | :534 | — | `ensureModelsLoaded()`（:318）——模型可能还在后台加载，首次推理前兜底等一次（2026-09-30 修复配套，正常情况零开销） |
| 调试 | :536-539 | — | `lastNativeSize = CGSize(width: sw, height: sh)`——记录原生帧尺寸（**无论后续是否被节流都更新**） |
| 闸 1 | :542-545 | `lastInferTime == nil \|\| Date().timeIntervalSince(lastInferTime!) >= Self.inferInterval` | **15Hz 时间节流**（200ms 内不入队新推理）——正常现象，不记诊断 |
| 闸 2 | :547 | `guard !isInferencing` | **防重叠**（上一帧 OCR 还没跑完） |
| 闸 3 | :549-553 | `activeEngine == .ppocr ? ppocrModel != nil : cnnModel != nil` | 当前引擎模型必须可用——失败写 `lastOCRDiagnostic = "当前引擎 X 模型不可用"` |

**后台队列推理（554–612 行）**——快照先行：`lastInferTime = Date()`（:554）、`gen = generation`（:555）、`cnnSnapshot/ppocrSnapshot/ppocrKeysSnapshot/roiNorm/engineSnapshot` 全部快照捕获（:556-560，防主线程并发修改），`isInferencing = true`，`ocrQueue.async { [weak self] in ... }`：

- **主路径分支**：`case .ppocr where ppocrSnapshot != nil`——
  - `Self.recognizePPOCR(roiBuffer: nativePixelBuffer, ...)`（:571-573）——nativePixelBuffer 已是 speedROINorm ROI 切片，与训练裁片覆盖同一物理区域 → **直接整帧推理，无需裁槽**
  - **同帧降级（:577-582）**：`result.error` 非空且 `cnnSnapshot` 存在 → `switchNotice = "PP-OCR 推理失败（err），已自动切换 CNN"`、`usedEngine = .cnn`，同帧补跑 `cropSlots + recognizeCNN` **不丢帧**；槽位裁剪失败则 `RecognitionResult(diag: "CNN 降级帧槽位裁剪失败")`
  - **"读不到"类业务诊断（fg 低 / 置信低 / 串短）不算故障，不切换**（源注释）
- **备用路径分支**：`case .cnn`（:589-594）——`cnnSnapshot` 存在且裁槽成功 → `recognizeCNN`；cnn 为 nil → `RecognitionResult(error: "CNN 备用模型不可用且 PP-OCR 已故障")`；裁槽失败 → diag"槽位裁剪失败"
- **default**：`RecognitionResult(error: "无可用速度识别引擎")`

**死诊断存盘（:603-604）**：`result.speed == nil` 且 `diag.hasPrefix("fg=")` → `Self.saveOCRDebug(buffer: slots: fg:)`（实现 :1345）——ROI 缩略图存 `/tmp/aurora_ocr_dbg_*.png` 供定位（**覆盖写，不阻塞主线程**）。

**结果回主线程（:606-610）**：`Task { @MainActor in self?.applyEngineUse(usedEngine, notice: switchNotice); self?.finish(gen, result) }`。

**`applyEngineUse(_:notice:)`（第 615–618 行）**——主线程应用引擎切换结果：`engine != activeEngine` 时更新（UI 可观察 activeEngine 实时刷新）；notice 非空时写 engineNotice。

**降级链设计要点**：系统级故障（throw/输出缺失）→ 同帧降级 + 提示；业务诊断（读不到）→ 只写 lastOCRDiagnostic 不切换——**两个语义分开**是防"假故障"乱切引擎的关键：fg 低可能只是画面里没有速度表（载入画面），不是 PP-OCR 坏了。

## 四、finish() 三层校验与 confirmedSpeed 多帧确认（第 624–724 行）

**`finish(_ gen: Int, _ result: RecognitionResult)`（第 624–676 行）**——主线程写最新快照（仿 YoloEngine.finish）：

1. **`guard gen == generation else { return }`**（:625）——reset() 后在途结果过期，直接丢弃（generation 防过期机制）
2. `isInferencing = false`（:626）
3. `result.error` 非空 → `errorMessage = error`（仅系统级错误如灰度转换失败）→ return（:627-630）
4. `guard let speed = result.speed, result.unknownSlots.isEmpty else { lastOCRDiagnostic = result.diag ?? "无法识别"; return }`（:632-635）——无法识别记录诊断并**静默丢弃**（正常情况：画面无速度表/整体残差过高）
5. `lastOCRDiagnostic = ""`（:637）——成功读出，清空诊断
6. **三层校验（任一不通过则保留旧值，:638 起）：**

| Layer | 行号 | 校验 | 失败行为 |
|---|---|---|---|
| Layer 1 量程 | :640 | `speedRange.contains(Double(speed))`（0...400） | `errorMessage = "out of range"`，return |
| Layer 2 跳变 | :648-655 | `abs(speed - lastValidSpeed) > maxJumpKmh`（60） | `errorMessage = "jump too large"` + **`confidence = 0`**——源注释（:645-647）：**不再静默沿用旧值假装新鲜读数，而是把本帧置信度置 0，让下游 speedValid（conf>0.3）判 false，走正规的"读不到→降级"路径**；speedKmh 保留旧值仅供显示；lastValidSpeed 不更新，避免错误读数污染下一帧基准 |
| Layer 3 多帧确认 | :653-664 | `confirmedSpeed(in: recent, tolerance: 2, minAgreement: 2)` 非空 | 候选不足或不一致，暂不输出（保留上一帧有效值） |

7. 全部通过（:667-673）：`speedKmh = Double(confirmed)`、`confidence = result.confidence`、`lastValidSpeed = Double(confirmed)`、`lastResultTime = now`、`errorMessage = nil`

**Layer 3 的候选管理（:655-659）**：`candidates.append((speed, now))` → 截断超出时间窗的旧候选（`confirmWindowSec = 1.0`）→ `recent = Array(candidates.suffix(confirmCount))`。

**`confirmedSpeed(in:tolerance:minAgreement:) -> Int?`（static，第 684 行起）**——多帧确认：在容差范围内分组投票：

- 对每个候选，统计列表内与它差值 <= tolerance 的"同读数"个数；个数 >= minAgreement 才算确认，**取同读数最多者**
- **平票时直接比较候选自身 `item.time`，取组内最新成员**（:679-681 注释）：**不能用组内最大时间 latest 作平票键：同一连通组所有成员 latest 相同，永远平票，会错误返回最旧候选**
- 容差解决"整数速度单调加减速时逐帧 ±1~2 km/h、永远凑不齐严格相等"的问题
- O(n²)，但 n = confirmCount（默认 3），开销可忽略

```swift
if count > bestCount || (count == bestCount && item.time > bestTime) { ... }
guard bestCount >= minAgreement else { return nil }
return bestSpeed
```

**`reset()`（第 710–724 行）**——停止驾驶时清空：`generation += 1`（**让所有在途 OCR 写回失败**）、speedKmh=-1、confidence=0、isInferencing=false、errorMessage/lastResultTime/lastInferTime/lastValidSpeed/lastOCRDiagnostic 全清、candidates 清空（keepingCapacity :720）、**静止帧复用缓存一并清空**（`Self.lastFrameHash = []`、`Self.lastFrameResult = nil`，:722-723——新会话从干净状态开始）。

## 五、cropSlots CIImage 裁剪与 RecognitionResult（第 726–825 行）

**`cropSlots(from src: CVPixelBuffer, roiNorm: CGRect? = nil) -> [CGImage]?`（nonisolated static，第 741–794 行）**——从原生 CVPixelBuffer 裁出 3 个槽位，按 slot 顺序返回 `[CGImage]`。**CIImage 路径**（替代裸 memcpy 按行拷贝）：零拷贝区域裁剪，无插值无放大，**由 Core Image 自动处理 ScreenCaptureKit 行序/方向问题，根治行序不一致 bug**。

**四个关键约定（:728-740 注释）：**

1. **CIImage 坐标系原点在左下角（y 向上）**，而归一化坐标是左上角原点 y 向下——所以对 y 做镜像：`ciRect.y = H - yMax`（顶部 yMin 对应 CIImage 的 H-yMax）
2. **量化与 Python 端 crop_slot 完全一致**：xCenter / halfW / yMin / yMax 都用 `round()` 取整，宽度 = 2·round(halfW)，高度 = round(yMax)-round(yMin)。这样训练窗与运行时裁剪窗**像素级一致**（round 而非 floor/ceil，避免 1~2px 错位）
3. **roiNorm 参数**（可选）：传非 nil 表示输入帧是「速度表 ROI 切片」（字模模式录帧/自检目录），把全屏归一化槽位坐标换算为 ROI 相对坐标再裁剪——与 Python 端 `crop_slot(roi=...)` 的换算逻辑完全一致。运行时 CaptureEngine 喂全屏帧时保持 nil
4. **返回 [CGImage?]，任一槽位裁剪失败则整组返回 nil**（防御性，避免部分槽位静默错位）

**换算实现（:752-772）：**

```swift
// ROI 切片模式：全屏归一化坐标 → ROI 相对坐标（:762-767）
cxNorm = (cxNorm - roi.origin.x) / roi.width
halfWNorm = halfWNorm / roi.width
yMinNorm = (yMinNorm - roi.origin.y) / roi.height
yMaxNorm = (yMaxNorm - roi.origin.y) / roi.height
// 与 Python 端一致的 round() 量化（银行家舍入，.5 取偶 → .rounded(.toNearestOrEven) 完全等价，:769-772）
let xCenter = (cxNorm * CGFloat(sw)).rounded(.toNearestOrEven)
let halfW   = (halfWNorm * CGFloat(sw)).rounded(.toNearestOrEven)
let yMin    = (yMinNorm * CGFloat(sh)).rounded(.toNearestOrEven)
let yMax    = (yMaxNorm * CGFloat(sh)).rounded(.toNearestOrEven)
```

- **银行家舍入注意**（:756-757 注释）：Python 内建 `round()` 是「银行家舍入」（.5 取偶），Swift 用 `.rounded(.toNearestOrEven)` **完全等价**，避免 .5 边界上的同源漂移

**裁剪（:774-792）**：`ciRect = CGRect(x: xCenter - halfW, y: CGFloat(sh) - yMax, width: halfW * 2.0, height: yMax - yMin)`（:776-777，y 镜像 :774 注释）——边界校验（:780-782，任一失败整组 return nil）→ `input.cropped(to: ciRect)`（:784）→ `ciContext.createCGImage(cropped, from: cropped.extent)`（:785-786）。

**`ciContext`（static，第 796 行）**：复用的 CoreImage 渲染上下文（**线程安全，可跨线程共享**）——P1 修复：CIContext 默认缓存中间渲染结果，长时间 OCR 累积缓存内存；**`[.cacheIntermediates: false]` 关掉缓存**避免中间位图常驻。

**`RecognitionResult`（private struct，第 801 行起）——单次识别结果：**

| 字段 | 说明 |
|---|---|
| `speed: Int?` | 识别出的三位数速度（0~300）；无法识别时为 nil |
| `unknownSlots: [Int]` | 无法识别的原因（nil speed 时的补充信息） |
| `confidence: Double` | 置信度（基于整体残差比，1 - dist / 总像素数） |
| `diag: String?` | 诊断信息（为什么没识别出来，如 fg 过低 / 残差超阈值） |
| `fgTotal: Int` | 三槽二值化前景像素总数（调试用，fg 过低时随 diag 透出） |
| `error: String?` | 错误信息（OCR 系统级失败，如 CGImage 渲染异常）——**error 与 diag 的语义区分**：error 触发同帧降级 CNN，diag 不触发 |

## 六、recognizePPOCR 与静止帧复用（第 827–961 行）

**`recognizePPOCR(roiBuffer:model:keys:isROISlice:) -> RecognitionResult`（nonisolated private static，第 827–874 行）**——对 ROI 切片（或全屏帧先裁 ROI）跑 PP-OCRv6 微调模型整行推理：

**几何依据（文件头 :7-10 与 :819-821 注释）**：训练裁片 = speedROINorm ROI @640×360 录制帧 = **51×18px**（实测数字笔画 bounding box 占比与槽位常量双向吻合），运行时 ROI 切片覆盖同一物理区域 → **无需任何槽位裁剪**。

**预处理与解码同参**：与 eval_onnx.py / eval_coreml.py 完全同参——灰度 → 双线性 resize 48×136（对齐 cv2.INTER_LINEAR）→ (v/255-0.5)/0.5 → 灰度值复制 3 通道 NCHW（:982 注释）；解码与训练期规则一致：CTC（blank=0、折叠重复）→ 置信 ≥0.30 → 取数字串**后 3 位**左补零（:1043-1046，模型常在前部多读 1~2 个字符：1018→018、14→014）→ <2 位判无效；**多帧级决策由上游 finish 三层校验负责**。

**输入分支（:834-840）**：

- `isROISlice == true`：`CIImage(cvPixelBuffer: roiBuffer)` 直接整帧
- false（全屏帧，自检路径）：按 speedROINorm 裁出速度表区域——**CIImage 原点左下（y 向上），归一化坐标左上原点 → `ciRect.y = sh - (r.origin.y + r.height) * sh`**（y 镜像 :838）+ `.integral`；ROI 越界 → error

**主流程（:840-874）**：

1. `ciContext.createCGImage(input, from: input.extent)`——失败 error"PP-OCR: ROI 渲染失败"
2. `grayscalePixels(cgImage: cg)`（:857）——失败 error"PP-OCR: 灰度转换失败"
3. **静止帧复用（:859-873）**：`hash = frameHash(gray:w:h:)`（:864）与 `lastFrameHash` 一致且有缓存 → **直接返回上次结果，跳过 Otsu/缩放/ANE 推理/CTC 全链**——速度数字绝大多数帧静止，实测平均可跳过一半以上帧；**游戏满载被挤到效率核时收益成倍放大**（ocrQueue 串行执行；selfTest 与运行期互斥，无并发竞争）
4. 走核心：`recognizePPOCRCore(gray:grayW:grayH:model:keys:)`（:868-869）→ 更新 lastFrameHash/lastFrameResult（:871-872）→ 返回

**静止帧复用缓存（第 877-880 行）**：`lastFrameHash: [UInt8]` + `lastFrameResult: RecognitionResult?`——`nonisolated(unsafe) private static`——**仅 ocrQueue 串行写读**；selfTest 与运行期互斥。

**`frameHash(gray:w:h:) -> [UInt8]`（nonisolated private static，第 944 行起）**——**16×6 块均值下采样 hash**：

- `bw = 16, bh = 6`；每块求均值（`sum / ((x1-x0) × (y1-y0))`，`min(255, ...)`）
- **单像素噪声不改变块均值，对捕捉抖动鲁棒**（源注释）——速度数字轻微抗锯齿抖动不会导致 hash 变化，静止帧判定稳定

**调用链小结**：`infer()`（闸 0 + 三闸门）→ ocrQueue → `recognizePPOCR`（ROI 渲染 → 灰度 → hash 复用）→ `recognizePPOCRCore`（Otsu → resize → 归一化 → 推理 → CTC，第 963 行起）→ Task @MainActor → `applyEngineUse` + `finish`（三层校验）→ speedKmh/confidence。

## 七、ctcDecode 主体与 bilinearResizeGray（第 1057–1163 行）

**`ctcDecode(logits:keys:) -> (text, conf)?`（nonisolated private static，第 1057–1131 行）**——逐时间步 argmax + 折叠：

```swift
for t in 0..<steps {
    let rowBase = t * rowStride
    var best = 0
    var bestVal = read(rowBase)
    for c in 1..<classes {
        let v = read(rowBase + c * colStride)
        if v > bestVal { bestVal = v; best = c }
    }
    if best != 0 && best != prev {      // 跳 blank(index 0)、折叠相邻重复
        confs.append(Double(min(1.0, max(0.0, bestVal))))
        if best <= keys.count { chars.append(contentsOf: keys[best - 1]) }
        else { chars.append(" ") }
    }
    prev = best
}
guard !chars.isEmpty, !confs.isEmpty else { return nil }
return (String(chars), confs.reduce(0, +) / Double(confs.count))
```

- **置信度直接取该步最大概率值**（:1119-1122 注释）：本模型输出已是概率分布（**CTC 头 softmax 已烘焙进模型，实测 max-logit 恒为 1.0000**）。若再套一层 softmax（1/Σexp(v-max)）会得到"分布锐度"而非置信度，对 6906 类约等于 1/2540 ≈ 0.0004 → 全部低于阈值判无效（**自检实测：文本解码正确但置信度 0.000、300/300 全失败**）
- `best <= keys.count` → 查表；越界（如 6905 space）→ 空格字符（非数字，后续 digits 过滤忽略）
- 返回 `(解码文本, 解码字符的**平均** argmax 概率)`（:1129）；无字符输出时 nil
- **必须按 dataType 读取**（:1059-1061 注释）：模型以 compute_precision=FLOAT16 转换，输出是 fp16（2 字节/元素）；按 Float（4 字节）指针读会越界段错误（自检实测 SIGSEGV）

**`bilinearResizeGray(src:srcH:srcW:dstH:dstW:) -> [UInt8]`（nonisolated private static，第 1133 行起）**——灰度双线性缩放：

- **像素中心对齐 + 边缘 clamp，对齐 OpenCV INTER_LINEAR**（:1130-1132 注释）：训练/评测端预处理为 `cv2.resize` 默认 INTER_LINEAR，**此处必须同插值，否则 18→48 放大后的笔画边缘灰度分布不一致（模型对插值敏感）**
- 实现：`xRatio/yRatio = src/dst`；每目标像素 `sy = (y+0.5)*yRatio - 0.5`（**中心对齐**）→ y0/y1 邻域 + fy 权重（`max(0.0, min(sy - y0, 1.0))`）→ 四邻域加权：`top = p00 + (p01-p00)*fx`、`bot = p10 + (p11-p10)*fx`、`out = (top + (bot-top)*fy).rounded()`
- 边界 clamp：`min(max(Int(sy.rounded(.down)), 0), srcH - 1)` + `x1 = min(y0+1, srcH-1)`
- 防御：尺寸非正或 `src.count != srcH*srcW` 返回 `[]`

## 八、recognizeCNN 与 lanczosResize（第 1165–1274 行）

**`recognizeCNN(slotImages: [CGImage], model: MLModel) -> RecognitionResult`（nonisolated private static，第 1167–1257 行）**——对 3 槽 CGImage 跑 CNN 推理（**替代模板匹配**的备用路径）：

- 每槽：灰度 → resize 90×50 → 归一化 0-1 → CoreML 推理 → argmax（:1165 注释）
- 前置无效检测：3 槽前景像素总数 < minValidForegroundPixels → 判无效

**逐槽流程（:1170-1240）：**

1. `guard cg.width > 0, cg.height > 0`——坏槽 error"invalid slot N"（:1177）
2. **Lanczos 缩放（:1179-1181）**：`Self.lanczosResize(cg, toWidth: templateWidth, toHeight: templateHeight)` → `grayscalePixels`——源注释：**对齐训练端 PIL LANCZOS，用 CoreImage 高质量缩放替代最近邻，消除「训练 LANCZOS vs 推理最近邻」的插值不一致（速度模型乱读的病根）**
3. **fg 检测**：`binarizeOtsu(gray:)` 二值化统计前景像素（gray 已是 90×50），累加 fgTotal
4. 归一化到 0-1：`floatPixels[i] = Float(gray[i]) / 255.0`（:1189-1191，无需再缩放）
5. `MLMultiArray` [1,1,90,50] **fp32**（与 PP-OCR 的 fp16 不同；A9 复用输入缓冲，:1193-1195）；dataPointer 直写
6. `["digit_input": inputArray]`（:1205）→ `model.prediction`
7. **输出读取（:1214-1219）**：`output.featureValue(for: "digit_output")?.multiArrayValue`——输出 (1, 10)；**用 NSNumber 桥接读取**（:1216-1218，仅 10 个元素开销可忽略）——源注释：避免假设 fp32——模型若以 fp16 导出，按 Float 指针读会越界段错误
8. **argmax（:1221-1229）**：10 类取最大概率 → bestDigit
9. **softmax 置信度（:1233-1237）**：`conf = 1/sumExp`（max-shift 技巧：`expf(maxVal - maxVal) / sumExp`）——注意与 PP-OCR 不同：**CNN 输出是 logits 不是概率分布，所以这里套 softmax 是对的**（PP-OCR 那边 softmax 已烘焙进模型不能再套）
10. digits.append + maxConfidences.append（:1238-1240）

**后置判定（:1242-1257）：**

- `fgTotal < minValidForegroundPixels`（80）→ `RecognitionResult(unknownSlots: all, diag: "fg=N 过低(画面无速度表)", fgTotal:)`（:1243-1247）
- `guard digits.count == 3` → "CNN槽位数不足"（:1250-1253）
- **组合三位数**：`speed = digits[0] * 100 + digits[1] * 10 + digits[2]`（:1254，CNN 路径是**逐位组合**，无"后 3 位"规则——与 PP-OCR 的取后 3 位不同）；`avgConf = 平均置信度`（:1255）
- 成功：`RecognitionResult(speed: speed, unknownSlots: [], confidence: avgConf)`（:1256）

**`lanczosResize(_ cg: CGImage, toWidth: Int, toHeight: Int) -> CGImage?`（nonisolated private static，第 1260 行起）**：

- CIImage + `CGAffineTransform(scaleX:scaleY:)` 变换 → `ciContext.createCGImage(scaled, from: rect)`——**Lanczos 近似**（CI 默认高质量采样）
- 防御：目标/源尺寸非正返回 nil（:1261）
- 复用共享的 `ciContext`（cacheIntermediates 关闭，见单元五）

**两条识别路径的对照**（给别的 AI 的速查）：

| 维度 | PP-OCRv6 主路径 | CNN 备用路径 |
|---|---|---|
| 输入 | ROI 整帧（48×136 resize） | 3 槽独立裁剪（90×50） |
| 数值类型 | **fp16**（compute_precision=FLOAT16） | fp32 |
| 解码 | CTC 整行 → 后 3 位左补零 | 逐位 argmax → 三位组合 |
| 置信度 | 直接取最大概率（softmax 已烘焙） | softmax(logits) = 1/sumExp |
| 缩放 | 双线性（对齐 cv2.INTER_LINEAR） | Lanczos（对齐 PIL LANCZOS） |

## 九、grayscalePixels / binarizeOtsu / saveOCRDebug（第 1275–1383 行）

**`grayscalePixels(cgImage: CGImage) -> [UInt8]?`（nonisolated private static，第 1275 行起）**——CGImage → 灰度像素：

- **复用 CGContext 把 CGImage 画到灰度 buffer（最稳的跨版本做法）**：`CGColorSpaceCreateDeviceGray()`（:1281）+ `bytesPerRow = w` + `bitmapInfo: .none` → `ctx.draw(cgImage, in: ...)`
- 失败返回 nil（极端情况下 CGImage 数据不可读）；输出长度 = width×height，0~255

**`binarizeOtsu(gray: [UInt8]) -> [UInt8]`（nonisolated private static，第 1300 行起）**——Otsu 自适应二值化：

- **原理（:1297 注释）**：灰度直方图分两类的**类间方差最大化**对应的阈值即为 Otsu 阈值
- **单色退化保护（:1298-1299 注释）**：非零灰度级 < 2（如全白帧/全黑帧）直接返回全 0（视为无前景）——**避免 thr=0 时 `gray>0` 全成立 → 输出全 1 的语义错误**
- 实现：256 级直方图 → 遍历阈值 t（wB/wF 类内权重、mB/mF 类内均值、`v = wB × wF × (mB-mF)²` 类间方差）→ `v > varMax` 时记录 thr
- **应用阈值**：`gray[i] > thr ? 1 : 0`——**大于阈值视为前景（数字笔画）**

**`saveOCRDebug(buffer:slots:fg:)`（nonisolated private static，第 1345 行起）**——死诊断：fg 过低时把「App 实际截到的画面 + 三槽裁图」存盘：

- **参数语义（:1338-1344 注释）**：buffer 是原生 CVPixelBuffer（**与 cropSlots 同一份，走同一 CIImage 路径，忠实反映 OCR 所见**；环1 后为速度表 ROI 切片，故"全屏"缩略实为 ROI 缩略）；slots 是 cropSlots 已裁出的 3 张 CGImage（即 OCR 实际喂给匹配的画面）
- 输出（覆盖写，:1355-1361）：
  - `/tmp/aurora_ocr_dbg_full.png`（ROI 缩略，便于直接看/发图）
  - `/tmp/aurora_ocr_dbg_slot{0,1,2}.png`（三槽裁图）
  - `/tmp/aurora_ocr_dbg.txt`（`fg=N native=WxH`）
- **一锤定音定位法（:1344 注释）**：若 ROI 缩略里能看到速度表数字 → 不是截错区域；若三槽裁图全空 → 坐标/朝向错位

**`writePNG(_ cg: CGImage, to path: String)`（nonisolated private static，第 1366 行起）**：`CGImageDestinationCreateWithURL` → AddImage → Finalize——调试写盘用，失败静默。

## 十、selfTestDirectory 自检（第 1385–1540 行）

**`selfTestDirectory(_ dirPath: String, roiNorm: CGRect? = nil) -> String`（@MainActor，第 1385 行起）**——命令行 `--speed-selftest <目录>`：同步跑一个目录下所有 PNG/JPG 原生分辨率帧：

- 流程：加载 → CVPixelBuffer → （PP-OCR 整帧 / CNN 裁槽）→ 打印每张的速度
- **期望**：能识别出 0~300 内的速度值（画面无速度表的帧判无效属正常）
- **用途（:1380-1381 注释）**：验证 Swift 侧的 CIImage 裁剪路径 + Otsu + 识别与 Python 端字模库生成结果一致；**任何不一致都会在残差里暴露**
- `roiNorm`：输入帧为「速度表 ROI 切片」时传其归一化位置（如字模模式录帧 0.455,0.885,0.080,0.050）；全屏帧传 nil

**自检流程细节：**

1. 列目录 → **按文件名排序，结果可复现**（:1394）
2. 过滤 png/jpg/jpeg 扩展；空目录返回"✗ 目录里没有 PNG/JPG"
3. **双引擎自检**：PP-OCR 可用则走主路径，否则 CNN 备用；**两者皆无 → 拒绝自检**（"✗ PP-OCRv6 与 CNN 模型均未加载（检查 models/ 目录）"）
4. 头部报告：目录/引擎（"PP-OCRv6 整行 (int8)" 或 "CNN 备用 (3槽)"）/ PP-OCR 输入 shape + keys 行数或槽位常量/帧数
5. 逐张：`loadCGImage(from:)` 失败 [skip]；`makeBGRABuffer(from:)` 失败 [skip]；PP-OCR 路径 `recognizePPOCR(roiBuffer: pb, isROISlice: roiNorm != nil)`——**roiNorm 非 nil 表示输入已是 ROI 切片 → 整帧即窗口**；CNN 路径 `cropSlots` + `recognizeCNN`
6. 结果分类：error → `[FAIL] name: err`；speed 为 nil → `[FAIL] name: 无法识别 [slots] — why`（**带上诊断原因（fg/置信度/解码串），自检可直接定位失败环节**）；成功 → `[✓/✗] name: speed=%03d conf=%.3f`（0~300 内 ✓）
7. 汇总：`passCount/images.count 通过, failCount 失败`

**`loadCGImage(from url: URL) -> CGImage?`（private nonisolated static，第 1498 行起）**：`CGImageSourceCreateWithURL` + `CGImageSourceCreateImageAtIndex`——自检用读图。

**`makeBGRABuffer(from cg: CGImage) -> CVPixelBuffer?`（private nonisolated static，第 1510 行起）**——把任意 CGImage 打包成全屏原生 BGRA CVPixelBuffer（自检用）：

- **自检需要未缩放的原始像素缓冲**，与 CaptureEngine 原生帧路径一致
- `CVPixelBufferCreate`（32BGRA + CGImage/CGBitmapContext/**Metal** 兼容）→ 锁 base → `CGContext.draw 1:1 写入`（`bytesPerRow = width*4`——**避免 padding 干扰后续 CIImage 路径**）
- bitmapInfo：`premultipliedFirst | byteOrder32Little`（BGRA 通道序，与 CaptureEngine 原生池一致）

**SpeedOCRReader 文档至此完整**（1540 行全覆盖：双模型架构 → 常量 → 2026-09-30 后台加载修复 → infer 闸 0+三闸门 → finish 三层校验 → cropSlots → recognizePPOCR 与静止帧复用 → ctcDecode → recognizeCNN → 图像处理 → 自检）。这是 Inference 层最复杂的文件，也是"读不到速度"排障的权威参考。任务面板 OCR 的同层姊妹模块见 [代码-13](<代码-13-InferenceEngine端到端推理.md>) 第五节。