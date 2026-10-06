# models/ayolom/ — A-YOLOM CoreML 产物溯源（NOTICE）

> 本文件由 `site-main` 于 **2026-10-04** 新增（P6 侦察第 A 项）。
> **只做记录，不改动任何模型文件。**
>
> `README.md` 已完整记录 **PyTorch 原始权重（`v4.pt` / `v4s.pt`）** 的来源
> （论文 / 上游仓库 / SharePoint 下载方式 / 文件大小 / 魔数校验）。
> **本文件补充 README 未覆盖的部分：导出的 CoreML 产物、接口契约、量化配方与实测指标。**

---

## 1. CoreML 产物清单

| 文件 | 体积 | 格式 | 结构 | SHA-256 (weights/weight.bin) |
|---|---|---|---|---|
| `ayolom_n_int8.mlmodelc` | 3.8M | legacy `.mlmodelc` | ✅ 完整 | `9df0b7ea00ca1d39d163edfafcb9c96013d8f5919891acf7b386c0ca82c9c01d` |
| `ayolom_n_fp16.mlmodelc` | 7.2M | legacy `.mlmodelc` | ✅ 完整 | `29b09b0cd650dd84aef80faf9ebd49e4c3a770fecc598b42c7a771a8b76b021b` |
| `ayolom_n_int8.mlpackage` | 3.8M | `.mlpackage` | ✅ 完整（`Manifest.json` + `Data/`） | — |
| `ayolom_n_fp16.mlpackage` | 7.2M | `.mlpackage` | ✅ 完整 | — |
| `v4.pt` | 7,569,606 B | PyTorch (YOLOv8n 骨架) | — | 见 README |
| `v4s.pt` | 27,524,934 B | PyTorch (YOLOv8s 骨架) | — | 见 README |

导出日期 `2026-10-02`，coremltools 源框架 `torch==2.14.1`。

---

## 2. 接口契约（`metadata.json` 实测）

```
输入 image:   Image (Color 640 × 640)              ← ImageType，非 MLMultiArray
输出 det:     MultiArray (Float16 1 × 5 × 8400)    cx, cy, w, h, cls_conf
输出 da:      MultiArray (Float16 1 × 2 × 640 × 640)  可行驶区 logits
输出 ll:      MultiArray (Float16 1 × 2 × 640 × 640)  车道线 logits
```

### ⚠️ 与 YOLOPX 的两处必须区分的差异（接错会静默出错）

| 项 | A-YOLOM | YOLOPX |
|---|---|---|
| `det` 形状 | `[1, **5**, 8400]` | `[1, 8400, **6**]` |
| 置信度字段 | **无 obj_conf**，第 5 维直接是 `cls_conf` | 有 `obj_conf` + `cls_conf` |
| 转置需求 | 需转置为 `[8400, 5]` | 原生 `[8400, 6]` |

见 `Sources/AuroraDrive/Inference/YolopxEngine.swift:172-173`。

---

## 3. 量化配方（`tools/ayolom/export_ayolom_coreml.py` 头注释）

### 【修订①】输入类型 `TensorType` → **`ImageType`**
初版导出用 `ct.TensorType(name:"image", shape:(1,3,640,640))`，要求调用方喂 **MLMultiArray**；
但 `YolopxEngine.swift` 喂的是 **`CVPixelBuffer`**（`MLFeatureValue(pixelBuffer:)`）——
类型对不上，Swift 侧会加载/推理失败。

改用与 yolopx 同款 `ImageType` 后：
- 整条 `drawLetterbox` / `inputBuffer` / 像素缓冲链路**原样复用**
- 归一化搬进图内（`scale=1/255`、`bias=[0,0,0]`、RGB）
- A-YOLOM 走 ultralytics 预处理 = 只除 255、无均值方差，故这组参数正确

### 【修订②】int8 量化方式 `linear_quantize_weights` → **palette（kmeans 8 位）+ det 头保 fp16**
配方来自本项目已量产验证的 `tools/yolopx/exp_quant_palette.py`。
`metadata.json` 显示存储精度为 `Mixed (Float16, Palettized (8 bits))`。

---

## 4. 实测精度 / 速度（`README.md` 与 `verify_int8_final.py`）

| 指标 | 实测值 |
|---|---|
| 可行驶区 da 掩码 IoU（vs fp16） | **0.9942** |
| 车道线 ll 掩码 IoU（vs fp16） | **0.9749** |
| 检测召回（vs fp16，IoU>0.5） | **99.1%** |
| 推理 p50 / p99 | **10.4 / 13.1 ms** → **95.9 Hz** |
| 30Hz 预算占用 | **31%** |

对比同目录 YOLOPX 族（`models/yolopx/NOTICE.md`）：`w8a16` 118ms、`fp16` 147ms。
**A-YOLOM(n) 10.4ms vs YOLOPX 118ms ≈ 11 倍差距** —— 这正是 `.ayolom` 被设为默认档的原因。

---

## 5. 上游使用约束（README 官方原话，务必遵守）

> PS: If you want to use our provided pre-trained model, please make sure that
> your input images are **(720,1280)** size and keep **`imgsz=(384,672)`** to
> achieve the best performance.

- **训练输入 1280×720**，官方建议推理 `imgsz=(384,672)`（**≠ 整数倍缩放**，是作者的特定选择）
- 本项目**实际用 640 letterbox**，实测在游戏画面上工作正常
  （真实游戏图：3 个框、可行驶 15.75%、车道线 3.285%，落在 yolopx 实测带内）
- `tnc: 3` = 车 + 可行驶区 + 车道线，三类
- 模型结构（导出脚本依赖）：`model.46 = Detect`（det 头，量化时跳过）、
  `model.47 / model.48 = Segment`（两个分割头）

⚠️ **未按官方建议的 `imgsz=(384,672)` 推理** —— 这是一个**已实测可用的偏离**，
但意味着当前精度**不是该模型的官方最优**。若后续要做"更高质量"优化，
**优先试 `imgsz=(384,672)` 或 720×1280 输入**，而不是先动量化档位。

---

## 6. 运行期接入

- 默认档：`PerceptionModelFamily.ayolom`（`YolopxEngine.swift:195`
  「`.ayolom`（默认）：只跑 A-YOLOM(n) int8 一个三合一模型」）
- 显式启用开关：`AURORA_AYOLOM=1`（见 README）
- 候选表：`YolopxEngine.swift` 的 `ayolomCandidates`
  ```swift
  "ayolom_n_int8.mlmodelc",    // ← 生产首位（编译形态，免运行时编译）
  "ayolom_n_int8.mlpackage",   // ← 同上，包形态（需编译）
  "ayolom_n_fp16.mlmodelc",    // ⚠️ 兜底（7.2MB，非 int8），命中会告警
  "ayolom_n_fp16.mlpackage",
  ```
- 命中 fp16 兜底时会打告警（`YolopxEngine.isUsingFp16Fallback`），
  因为用户要求「只做 8 位」。

---

## 7. 完整性校验

```bash
for m in models/ayolom/*.mlmodelc; do
  w=$(find "$m/weights" -type f | sort | head -1)
  printf "%s  %s\n" "$(shasum -a 256 "$w" | awk '{print $1}')" "$(basename $m)"
done

# 精度验证
python tools/ayolom/verify_int8_final.py
```

---

## 8. 相关文件

- `models/ayolom/README.md` — PyTorch 原始权重溯源（2026-10-02）
- `models/NOTICE.md` — 根层模型溯源
- `models/yolopx/NOTICE.md` — YOLOPX 族（`.legacy` 档）
- `tools/ayolom/export_ayolom_coreml.py` — 导出脚本
- `tools/ayolom/verify_int8_final.py` — 精度验证
