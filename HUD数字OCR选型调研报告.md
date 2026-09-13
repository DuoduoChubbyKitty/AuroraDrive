# 游戏 HUD 车速数字 OCR 选型调研报告

> 场景：macOS (Apple Silicon) + Apple CoreML，读《异环》NTE HUD 右上角车速（0~300，三位前导零）
> 核心难点：**空心字/描边字**（outline/hollow，笔画稀疏、内部空洞、灰度非纯白、上下半部亮度不均）
> 报告日期基准：2026-09（已核实 PP-OCRv6 于 2026-06-11 随 PaddleOCR v3.7.0 发布）
> 标注约定：✅ = 有一手链接证据已验证；⚠️ = 需进一步确认

---

## 0. 先说结论（TL;DR）

**你大概率不需要换模型，你需要先修预处理。** "000" 被读成 "NTO0U" 不是 OCR 引擎的锅，是**空心字在二值化后会断裂成互相独立的笔画片段**——"0" 的轮廓在 Vision 眼里就是「左竖 / 右竖 / 上弧 / 下弧」四段碎片，于是它很合理地拼出了 N/T/U/O 五个字母。

**决定性的一步**：闭运算封缺口 → `fill_holes` 填内部 → 空心字变成**拓扑结构完全正确的实心字**（"0" 仍是实心环，"8" 仍是两瓣，"6/9" 仍有尾巴）。这一步之后，通用 OCR 和你的自制 CNN 都会"突然能用"。**这是零训练成本、约 50 行代码的改动，请第一个做。**

---

## 1. 方案总表

### 方向 1：通用 OCR 引擎

| 名称 | 仓库链接 | 类型 | 输入规格 | 输出规格 | 许可证 | 转 CoreML 可行性 | 空心数字适配难度 | 推荐度 |
|---|---|---|---|---|---|---|---|---|
| **PP-OCRv6 / PaddleOCR 3.7.0** | [PaddlePaddle/PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) | 通用 OCR | det 动态尺寸；rec 典型 3×48×320 | det: 概率图；rec: CTC logits (T×V) | Apache-2.0 ✅ | 中（无官方路径；有 v5 的社区 CoreML 先例） | 高（需先修预处理 + 自定义字典） | ⭐⭐⭐ |
| **coreml-paddleocr (PP-OCRv5)** | [gsdali/coreml-paddleocr](https://github.com/gsdali/coreml-paddleocr) | 通用 OCR（已转 CoreML） | det 1×3×960×960；rec 1×3×48×320 | det 1×1×960×960；rec 1×40×18385 logits | Apache-2.0 ✅ | **已完成** ✅ | 高（同上；但 logits 可掩码到数字类） | ⭐⭐⭐⭐ |
| **ppocrv6_onnx** | [AIwork4me/ppocrv6_onnx](https://github.com/AIwork4me/ppocrv6_onnx) | 通用 OCR（纯 ONNX） | tiny det + tiny rec，ONNX | 文本 + 置信度 | ⚠️ 未查到明确 license | 中（ONNX→coremltools） | 高 | ⭐⭐⭐ |
| **RapidOCR** | [RapidAI/RapidOCR](https://github.com/RapidAI/RapidOCR) | 通用 OCR（ONNX 化 PaddleOCR） | 同 PP-OCR | 文本框 + 文本 + 置信度 | Apache-2.0 ✅ | 中（ONNX 已有，**无官方 Swift 绑定** ⚠️） | 高 | ⭐⭐⭐ |
| **EasyOCR** | [JaidedAI/EasyOCR](https://github.com/JaidedAI/EasyOCR) | 通用 OCR | CRAFT det + CRNN rec | 框 + 文本 + 置信度 | Apache-2.0 ✅ (v1.7.2, 2024-09) | 差（无官方 ONNX/CoreML 导出 ⚠️） | 高 | ⭐⭐ |
| **docTR** | [mindee/doctr](https://github.com/mindee/doctr) | 通用 OCR | DB/CRAFT det + CRNN/SVTR rec | 框 + 文本 | Apache-2.0 ✅ | 差（无官方 ONNX 导出 ⚠️） | 高 | ⭐⭐ |
| **Surya** | [datalab-to/surya](https://github.com/datalab-to/surya) | 通用 OCR(VLM) | 650M 参数 VLM，Apple Silicon 需 llama.cpp | 文本 | 代码 Apache-2.0；**权重 modified AI Pubs Open Rail-M（$5M 营收以下免费）** ✅ | 不现实（650M VLM） | — | ⭐ |
| **MMOCR** | [open-mmlab/mmocr](https://github.com/open-mmlab/mmocr) | 通用 OCR 工具箱 | 多种 | 多种 | Apache-2.0 ✅ | 差 | 高 | ⭐⭐（仅作架构参考） |
| **TrOCR** | [microsoft/trocr-base-printed](https://huggingface.co/microsoft/trocr-base-printed) | 通用 OCR | **固定 384×384** | 自回归文本 | MIT ⚠️ | 差 | 高（你已实测失败） | ⭐ |
| **Apple Vision (VNRecognizeTextRequest)** | 系统框架 | 通用 OCR | CVPixelBuffer / CGImage | 文本 + bbox + confidence | 系统 | 原生 | **高，但预处理后可救** | ⭐⭐⭐⭐⭐（配合预处理） |

### 方向 2：数字专用 / 计数字符识别

| 名称 | 仓库链接 | 类型 | 输入规格 | 输出规格 | 许可证 | 转 CoreML 可行性 | 空心数字适配难度 | 推荐度 |
|---|---|---|---|---|---|---|---|---|
| **fast-plate-ocr** | [ankandrew/fast-plate-ocr](https://github.com/ankandrew/fast-plate-ocr) | 数字专用（车牌 STR，可自训） | **可配置** `img_height`/`img_width`/`image_color_mode: grayscale` | **固定 slot 数 × 字符集** softmax（head 数 = `max_plate_slots`） | ⚠️ 未在页面确认（HF 数据集侧为 MIT） | **官方支持 `--format coreml` → .mlpackage** ✅ | 中（靠合成数据解决） | ⭐⭐⭐⭐⭐ |
| **LPRNet (PyTorch 实现)** | [sirius-ai/LPRNet_Pytorch](https://github.com/sirius-ai/LPRNet_Pytorch) · [arXiv:1806.10447](https://arxiv.org/abs/1806.10447) | 数字专用（车牌） | **94×24** RGB | CTC 序列 | ⚠️ 未明确标注 | 中（需自写 ONNX→CoreML） | 中高 | ⭐⭐⭐ |
| **racing-gears 数据集** | [tobil/racing-gears](https://huggingface.co/datasets/tobil/racing-gears) | 数据集（赛车 HUD 档位数字） | 32×32 灰度 PNG | 10 类 | **MIT** ✅ | — | — | ⭐⭐⭐⭐（直接对口先例） |
| **opencv_zoo text_recognition_crnn** | [opencv/opencv_zoo](https://github.com/opencv/opencv_zoo/tree/main/models/text_recognition_crnn) | CRNN（现成 ONNX） | 32×100 典型 | CTC 序列 | Apache-2.0 ✅ | 中 | 高 | ⭐⭐ |
| **OCR7SD** | [NickTrossa/OCR7SD](https://github.com/NickTrossa/OCR7SD) | 七段数码管（模板匹配） | ROI 手选 | 数字串 | ⚠️ 未确认 | 不适用（纯 OpenCV） | 中（思路可借鉴） | ⭐⭐ |
| **segment-display-ocr / ocr-digital-display / Seven-Segment-OCR** | [lcferrum/segment-display-ocr](https://github.com/lcferrum/segment-display-ocr) · [zhuzhenLi/ocr-digital-display](https://github.com/zhuzhenLi/ocr-digital-display) · [kylekanderson/Seven-Segment-OCR](https://github.com/kylekanderson/Seven-Segment-OCR) | 七段数码管 | — | — | 未确认 | 不适用 | 中 | ⭐（多为小/停滞项目） |
| **OCRCoreMLDetector（Nemotron OCR v2 的 CoreML 移植）** | [mweinbach/OCRCoreMLDetector](https://github.com/mweinbach/OCRCoreMLDetector) | 通用（SwiftPM/CoreML） | 需确认 | 文本 | 需确认 | 已是 CoreML | 未知 | ⭐⭐（值得一看，仅供备选） |

### 方向 3：自训框架

| 名称 | 仓库链接 | 类型 | 输入规格 | 输出规格 | 许可证 | 转 CoreML 可行性 | 空心数字适配难度 | 推荐度 |
|---|---|---|---|---|---|---|---|---|
| **TextRecognitionDataGenerator (TRDG)** | [Belval/TextRecognitionDataGenerator](https://github.com/Belval/TextRecognitionDataGenerator) | 合成数据生成器 | — | 图像 + 标签（含 `--output_mask` 字符级 mask） | MIT ✅ | — | **低（关键武器）** | ⭐⭐⭐⭐⭐ |
| **PARSeq** | [baudm/parseq](https://github.com/baudm/parseq) | STR 框架 | 32×128 典型 | 自回归序列 | Apache-2.0（CRNN/ABINet 部分为 BSD/MIT）✅ | 差（纯 Transformer，自回归解码不适合 ANE） | 中 | ⭐⭐ |
| **CRNN (论文)** | [arXiv:1507.05717](https://arxiv.org/abs/1507.05717) | 架构 | 32×W | CTC logits | — | 中 | 中 | ⭐⭐⭐ |
| **MMOCR 内 CRNN/SVTR/SATRN 实现** | 见上 | 架构参考 | — | — | Apache-2.0 | 差 | — | ⭐⭐ |
| **自制 CNN（现有方案）** | 你的代码 | 自训 | 90×50 灰度 | 10 类 | — | **已是 CoreML** | 修预处理后应能救活 | ⭐⭐⭐⭐ |

---

## 2. TOP 3 推荐

### 🥇 第一名：**「修预处理 + 保留现有 CNN」**（不是换模型）

**理由**：
- 你现有 CNN 已经是 CoreML、已经跑通、输入输出完全对口（固定位置固定字体）。它表现不好的**最可能原因不是架构，而是喂进去的图本身是错的**——空心字经过朴素灰度化/二值化后，同一颗"0"在不同帧里可能断裂成 2 段或 4 段，对模型来说是**同一类标签下完全不同的形状**，这会让任何分类器都学不好。
- 修预处理的成本是几十行代码 + 半天调试；换模型的成本是数据采集、标注、训练、转 CoreML、集成、回归测试，以周计。
- 见第 3 节的完整预处理管线。**请先做这个，再决定要不要换。**

### 🥈 第二名：**fast-plate-ocr 微调 + 官方 CoreML 导出**

**理由**（这是真换模型时的最优解）：
- **场景同构**：车牌识别 = 固定长度 + 小字符集 + 小输入图 + 无字符分割。你的需求 = 固定 3 位 + 字符集 `0123456789` + 小图。**几乎完美一致**。
- **官方 CoreML 导出**（✅ 已核实文档）：`fast-plate-ocr export --model best.keras --plate-config-file config.yaml --format coreml` 直接产出 `.mlpackage`。这是我在整个调研中唯一找到的「专门做固定格式数字 OCR 且官方支持 CoreML 导出」的库。
- **字符集/槽位数完全可配**（✅ 已核实 `PlateConfig` schema）：`alphabet: "0123456789"`、`max_plate_slots: 3`、`img_height`/`img_width` 自定、`image_color_mode: grayscale`、`keep_aspect_ratio`、`interpolation`。字符集只有 10 类，模型可以做到极小。
- **架构是 CCT（Compact Convolutional Transformer）**，XS/S 两档，b=1 延迟 0.32~0.68ms（RTX 3090 基准，M 系列上会慢一些但仍是亚毫秒到毫秒级）。
- **有完整的微调教程 notebook**：[examples/tutorial_fine_tune_plate_model.ipynb](https://github.com/ankandrew/fast-plate-ocr/blob/master/examples/tutorial_fine_tune_plate_model.ipynb)
- ⚠️ 唯一需要确认：仓库 LICENSE 我未在页面直接看到明确声明（HF 数据集侧是 MIT），用前请确认一次。

### 🥉 第三名：**coreml-paddleocr（PP-OCRv5 的成品 CoreML）**

**理由**：
- 这是**唯一一个「已经帮你转好 CoreML、并且给了 Swift 调用代码」**的通用 OCR 方案（✅ 已核实）：
  - det `1×3×960×960 → 1×1×960×960`，rec `1×3×48×320 → 1×40×18385`，FP16 mlprogram，macOS 15+
  - M4 上 `MLComputeUnits.cpuAndNeuralEngine`：det 13.8ms / rec **1.5ms**
  - 附带 `test_ane.swift` 冒烟测试；预处理好（归一化、resize、padding）全部文档化了
  - 转换链：Paddle → ONNX → PyTorch → CoreML（coremltools 9.0 + onnx2torch 1.5.15，需 monkeypatch LayerNormalization bug）
- **关键工程技巧**：rec 输出 18385 类，但你只需要数字。**在做 CTC 解码之前，把 logits 掩码到「数字类 + blank」，其余置 -inf**。这把一个 18385 类的通用识别问题**变成一个 11 类的数字识别问题**，误识别空间被砍掉 99.9%。这是本方案最值钱的一招。
- ⚠️ 风险：该仓库只有 **4 个 star**，属于个人早期项目，未经大规模验证；且它转的是 **PP-OCRv5**，PP-OCRv6（2026-06 发布）尚无 CoreML 版本。同作者还有 [gsdali/coreml-edocr2](https://github.com/gsdali/coreml-edocr2)，说明他确实在持续做 CoreML OCR 转换，可信度尚可。**建议作为并行实验，不要作为唯一主线。**
- 使用方式：因为位置固定，**跳过 det 模型**，直接裁 ROI → warp 成 48×320 → 只跑 rec。

> **不推荐**：Surya（650M VLM + 权重商用受限）、TrOCR（你已实测失败，且 384×384 固定输入对 HUD 小字是浪费）、EasyOCR/docTR/MMOCR（无 CoreML 路径，为固定字体数字上通用框架属于过度工程）。

---

## 3. 针对「空心数字」的技术建议（本报告核心价值）

### 3.1 为什么现在会失败（根因诊断）

空心字 = **只有笔画轮廓的闭合曲线**。对 "0" 而言：
- 灰度化 → 得到一条细的椭圆环
- 二值化 → 环上任何一处抗锯齿导致的灰度凹陷都可能**断成 2~4 段**
- 于是 Vision 看到的不是 "0"，而是「左弧 / 右弧 / 上弧 / 下弧」几个独立片段 → 它非常合理地输出 `N`、`T`、`U`、`O`
- 更糟的是「上下半部亮度不均」（UE HUD 常见的 bloom/glow 垂直渐变）：上半亮下半暗 → **同一个字的上下半部落在不同的二值化侧**，断裂位置逐帧漂移

**这意味着：你的自制 CNN 和模板匹配也一定在受同样的苦**（同一标签下形状不一致 = 类别内方差爆炸）。这不是模型容量问题。

### 3.2 决定性手段：拓扑修复（闭运算 + 填洞）

⚠️ 注意：**不要用大核闭运算去"填实"空心字**——那会把 "0" 变成一坨、把 6/8/9 的区别抹掉。正确做法是**保留内部空洞、只填笔画轮廓的中间**：

```
1. 裁固定 ROI（2940×1912 下硬编码坐标，别缩放原图）
2. textness = min(R, G, B)          ← 关键！别用灰度
3. p = percentile(textness, 99); textness' = clamp(textness / p, 0, 1)
4. 局部对比度归一化（CLAHE）或 逐行百分位归一化   ← 治"上下半部亮度不均"
5. 二值化（Otsu 或 Sauvola/Niblack 局部阈值）
6. 闭运算（3×3，或核半径 ≈ 笔画宽度）  ← 封住抗锯齿造成的笔画缺口
7. binary_fill_holes                   ← 空心 → 实心，且保留内部空洞
8. （可选）开运算去噪点；等比 pad 成固定长宽比；resize / 放大
```

**第 2 步 `min(R,G,B)` 的重要性常被低估**：游戏 HUD 文字通常是近白/浅色，而天空、草地、路面都是高饱和色。`min(R,G,B)` 对白色文字给出高值、对饱和背景给出接近 0 的值——**天然就是一个"文字概率图"**，比分通道灰度干净得多。这一行改动本身就可能让你的 CNN 明显变好。

**第 6+7 步是拓扑修复的核心**：
- 闭运算先把断裂的轮廓重新连成**闭合曲线**
- `fill_holes` 再把闭合曲线内部的"孔洞"填实
- 结果："0" → 实心环（1 个洞）、"8" → 实心双瓣（2 个洞）、"6"/"9" → 带尾实心瓣（1 个洞）、"1" → 竖条
- **拓扑信息（洞的个数、位置）被完整保留，但字形变成了任何 OCR 都认识的实心黑体**

**这一步之后，请立刻回头重测 Apple Vision**。

### 3.3 Apple Vision 的正确调参（很可能一步救命）

⚠️ 以下参数名来自官方 API 约定，请以 `developer.apple.com/documentation/vision/vnrecognizetextrequest` 为准核对：

- **`usesLanguageCorrection = false`** ← **最重要**。语言纠错是个"把奇怪字形序列映射成词"的词典后处理，正是它会主动把 `000` 往 `NTO0U` 这类"词"上凑。关掉它，输出会老实很多。
- `recognitionLevel = .accurate`（不要用 `.fast`）
- **`minimumTextHeight` 显式调小**：默认约为图像高度的 1/32，HUD 小字可能直接被忽略
- `regionOfInterest`：直接指定归一化 ROI，避免全图干扰
- `customWords = ["000", ..., "300"]` / `customWordsWeight`：把 301 个合法值作为白名单提示
- `revision`：用最新版
- **放大再喂**：裁出 ROI 后用 Lanczos **放大 3~5 倍**再交给 Vision。小字上采样对 Vision 的提升通常很显著，成本几乎为零。

### 3.4 时序滤波（被严重低估的廉价大招）

车速是**物理连续量**，而误读是**瞬态**的。这两点结合起来能白拿一大截准确率：

- **变化率约束**：`|Δspeed| ≤ K`（K 按帧率与最大加速度预算），越界的读数直接判为非法
- **多帧加权投票**：对最近 N 帧按置信度加权投票
- **低置信度保持**：置信度 < τ 时沿用上一帧值，而不是采信
- **回弹剔除**：若读数变为远离趋势的值后**立刻又变回来**，说明中间那帧是误读，丢弃

效果方向：单帧 97% × 时序一致性 → 系统级 99.5%+。**这一层的性价比远高于换模型**，务必和预处理一起做。

### 3.5 数据：合成数据是主要杠杆，但必须"合成到真背景上"

- **字体现成即可渲染**：TRDG（MIT）**原生支持描边字** —— ✅ 已核实它有 `--stroke_width`（描边宽度）和 `--stroke_fill`（描边颜色）两个参数，正是为教你造空心字而加的。还有 `--font`/`--font_dir`（锁死真实字体）、`-tc`（文字色范围）、`-b`（背景类型）、`-bl/-rbl`（高斯模糊）、`-k/-rk`（倾斜）、`-d/-do`（扭曲）、`--character_spacing`、`--output_mask`（字符级 mask）。
- **只有 301 个合法取值**（000~300）。每个值生成 200~500 个增强变体 = 6 万~15 万张图，完全够用。
- **致命细节**：把合成字形**叠加到从游戏里真实截取的背景裁片上**，不要用纯白/纯噪背景。绝大多数"合成数据训得好、上真机就崩"都是因为这一步偷懒。
- **字体拿不到怎么办**：NTE 是 UE 项目，字体多在 `.pak` 里，提取是另一个逆向任务。退路是从自己的录像里**批量收割真实字形**（位置固定，裁几千帧做聚类，自然得到每个数字的干净样本），既可以当训练集，也能反过来校准你的渲染器。
- **真实数据量**：固定字体 + 固定位置 + 10 个字形的任务，**几千张标注裁片**通常足够（前提是预处理对了 + 有合成预训练）。你现在 90×50→10 类的失败更可能是"类别内形状不一致 + 真实数据太窄"，而非样本量绝对值不够。
- **冷启动标注技巧**：用你现有的模板匹配当**自动标注器**批量生成伪标签，人工只修分歧样本。

### 3.6 架构选择（真要换模型时）

**结论：用「整字段多槽位 softmax」，不要用 CTC。**

- **推荐 A：3 槽位序列模型**。输入 = 整块三位数字裁片（如灰度 48×144 或 32×96），输出 = 3 个槽位 × 10 类。**完全不需要字符分割**，因此对"笔画粘连/断裂"免疫。fast-plate-ocr 的 `max_plate_slots=3` + `alphabet="0123456789"` 就是这个形态。
- **推荐 C（很有吸引力）：单头 301 类分类器**。只在 000~300 这 301 个合法值上做 softmax。因为整个定义域只有 301 种可能，模型**永远不会输出非法读数**（不会出现 "7#2"），且天然利用"1000 种三位组合里只有 301 种合法"这个强先验。缺点是 "001"/"010"/"100" 必须分别学、无部分信用。**可与 A 做双头集成**。
- **关于 CRNN + CTC**：能用，但**不是这个问题的自然解法**。CTC 的存在意义是解决**变长、未分割**的序列；你已经确切知道是 3 位。用槽位 softmax 训练更快、收敛更稳，而且**每个槽位都有独立的置信度**（做时序滤波时非常有用，CTC 给不了这么干净的粒度）。除非你预期将来要读变长字段，否则别用 CTC。
- **不要用回归**：AIcrowd 的 F1 速度识别方案把「OCR + 图像回归」做了集成，回归作为集成成员/一致性校验有一定价值，但直接回归数值对"精确整数匹配"这个指标通常更差。

---

## 4. 务实路线：要 99%+ 准确率，最短路径

### Phase 0（半天，零训练，可能性最高）—— 先做这个
1. 裁固定 ROI，**不缩放原图**
2. 预处理管线：`min(R,G,B)` → P99 归一化 → CLAHE → 二值化 → **闭运算(3×3)** → **fill_holes** → 等比 pad
3. **放大 3~5×** 后送 Apple Vision，同时设 `usesLanguageCorrection = false`、`recognitionLevel = .accurate`、调小 `minimumTextHeight`、设 `regionOfInterest`
4. **同时**把同一批预处理后的图标 **喂回你的现有 CNN** 重训一版对比

> 出口判据：如果 Phase 0 让单帧准确率超过 99%，**收工，不要换模型**。这一步概率不低。

### Phase 1（1~2 天，零训练，近乎白拿）
5. 加时序约束层：变化率约束 + 多帧加权投票 + 低置信度保持上一帧 + 回弹剔除
6. 出口判据：单帧 97~98% × 时序一致性 → 系统级 99%+

### Phase 2（1~2 周，仅在 Phase 0/1 不够时）
7. **首选**：fast-plate-ocr 微调，`alphabet="0123456789"`、`max_plate_slots=3`，灰度输入，`export --format coreml` 出 `.mlpackage`
8. 训练数据 = TRDG 合成（`--stroke_width` 描边 + 真实背景合成）× 301 值 × 200~500 变体 + 几千张真实标注裁片（模板匹配自动打伪标签 + 人工修分歧）
9. **并行实验**（低成本、可能高回报）：接上 [coreml-paddleocr](https://github.com/gsdali/coreml-paddleocr) 的 rec 模型，**把 logits 掩码到数字类 + blank 再 CTC 解码**，与你自己的模型对比

### Phase 3（兜底）
10. 保留模板匹配/NCC 作为**低置信度时的仲裁器**，与主模型投票

---

## 5. 避坑提醒

1. **最大的坑：以为要换模型。** 先把根因（空心字拓扑不一致）修掉。换模型而不修预处理，你会用新模型复现同一个失败，只是花了两周。
2. **别用大核闭运算"填实"空心字。** 那会毁掉 0/6/8/9 的区分度。必须是「小核闭运算封缺口 + `fill_holes` 保留内部空洞」的组合。
3. **别用朴素灰度。** 游戏背景色彩多变，`min(R,G,B)` 这类"白度"图才干净。
4. **别忘了关 Vision 的语言纠错。** `usesLanguageCorrection = true` 会主动把数字往字母词上凑，这是 "NTO0U" 的直接推手之一。
5. **别在小字上直接喂 Vision。** 先放大 3~5×，成本为零、收益明显。
6. **别用 CTC 解固定 3 位。** 槽位 softmax 更简单、更快、每槽位自带置信度。
7. **别把合成数据叠在纯白背景上。** 必须合成到真实游戏背景裁片，否则上真机必崩。
8. **别忽略时序一致性。** 物理连续 + 误读瞬态 = 免费的准确率，很多人硬啃单帧指标却漏掉这一层。
9. **别选许可证有雷的模型。** Surya 的**代码**是 Apache-2.0 但**模型权重是 modified AI Pubs Open Rail-M**（$5M 营收以下免费），且是 650M VLM，Apple Silicon 上还得跑 llama.cpp —— 直接排除。
10. **注意仓库成熟度。** `coreml-paddleocr` 只有 4 star。它是真实可用且有文档的，但属于个人早期项目，**当并行实验而不是唯一主线**。
11. **PP-OCRv6 是 2026-06 才发布的**（PaddleOCR v3.7.0），社区尚无 CoreML 版本；`coreml-paddleocr` 转的是 v5。别指望"直接下 v6 CoreML"。
12. **分辨率别浪费。** 2940×1912 下固定 ROI 裁出来的数字其实不算太小——**只要你别先把整图缩到 720p 再去裁**。
13. **确认 license 再上线。** 上表里标 ⚠️ 的（fast-plate-ocr 仓库 license、LPRNet_Pytorch license、ppocrv6_onnx license）请在采用前逐个核对。

---

## 6. 确定信息 vs 待确认信息

**✅ 已一手核验（有链接证据）**
- PP-OCRv6 于 2026-06-11 随 PaddleOCR v3.7.0 发布；medium 档 det +4.6% / rec +5.1%；PP-OCRv6_medium_rec 精度 83.2；参数量 1.5M~34.5M；论文 [arXiv:2606.13108](https://arxiv.org/html/2606.13108v1)；HF blog 2026-06-22
- [gsdali/coreml-paddleocr](https://github.com/gsdali/coreml-paddleocr) 真实存在，Apache-2.0，PP-OCRv5 mobile det(1×3×960×960→1×1×960×960, 13.8ms) + rec(1×3×48×320→1×40×18385, 1.5ms) @ M4 cpuAndNeuralEngine，转换链 Paddle→ONNX→PyTorch→CoreML
- [fast-plate-ocr](https://github.com/ankandrew/fast-plate-ocr) 官方支持 `export --format coreml` → `.mlpackage`；`PlateConfig` 可配 `alphabet`/`max_plate_slots`/`img_height`/`img_width`/`image_color_mode`；架构 CCT；有微调教程 notebook
- [TRDG](https://github.com/Belval/TextRecognitionDataGenerator) 具备 `--stroke_width` / `--stroke_fill` 描边字生成能力；许可证 MIT
- EasyOCR = Apache-2.0 v1.7.2 (2024-09)；docTR = Apache-2.0，由 t2k GmbH 维护；MMOCR = Apache-2.0 v1.0.0 (2023-04-06)；RapidOCR = Apache-2.0
- Surya 代码 Apache-2.0 / 权重 modified AI Pubs Open Rail-M（$5M 以下免费），650M VLM
- [tobil/racing-gears](https://huggingface.co/datasets/tobil/racing-gears)：MIT，32×32 灰度，10 类，5,964 train / 1,003 val，赛车 HUD 档位数字（**直接对口的先例**）
- LPRNet 论文 [arXiv:1806.10447](https://arxiv.org/abs/1806.10447)（Zherzdev & Gruzdev, 2018）：无 RNN，端到端无字符分割，中国车牌 95%，GTX1080 上 3ms / i7-6700K 上 1.3ms
- CRNN 论文 [arXiv:1507.05717](https://arxiv.org/abs/1507.05717)（Shi, Bai, Yao, 2015）
- [AIwork4me/ppocrv6_onnx](https://github.com/AIwork4me/ppocrv6_onnx)：纯 ONNX Runtime 的 PP-OCRv6，零 PaddlePaddle 依赖，~200MB，M4 上平均 282ms（多行文档场景），提供 tiny det + tiny rec 的 ONNX 下载地址
- [opencv/opencv_zoo text_recognition_crnn](https://github.com/opencv/opencv_zoo/tree/main/models/text_recognition_crnn)：现成 CRNN ONNX（含 int8 版本）
- [mweinbach/OCRCoreMLDetector](https://github.com/mweinbach/OCRCoreMLDetector)：Nemotron OCR v2 神经部分的 SwiftPM/CoreML 包

**⚠️ 需进一步确认**
- `fast-plate-ocr` 仓库 LICENSE 的具体名称（未在页面看到明确声明）
- `LPRNet_Pytorch`、`OCR7SD`、`ppocrv6_onnx` 的 license
- `RapidOCR` 是否有官方 Swift/macOS 绑定（未找到证据，倾向"无"）
- `docTR` / `EasyOCR` 是否有官方 ONNX 导出（未找到证据，倾向"无"）
- Apple Vision 参数名与当前最新 revision 的准确清单（需以 developer.apple.com 官方文档页为准；本次抓取该页需 JS 未成功渲染）
- `coreml-paddleocr` 是否已跟进 PP-OCRv6（本次未找到证据）
- Valorant HUD OCR 社区讨论帖（[r/computervision](https://www.reddit.com/r/computervision/comments/1pswefa/ocrrecognition_bottleneck_for_valorant_live_hud/)）本次抓取为空，未能提取内容
- 未找到针对「空心字/描边字 OCR」的专门论文（搜索 "outline text recognition" / "hollow font OCR" 未获得有效结果——**这本身是个信息：学术界基本没人为这个细分场景做过工作，所以自训是合理的**
