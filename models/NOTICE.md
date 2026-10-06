# models/ — 模型来源与完整性清单（NOTICE）

> 本文件由 `site-main` 于 **2026-10-04** 新增（P6 侦察第 A 项）。
> 目的：补上 `models/` 根层模型的**来源溯源与完整性指纹**。
> 此前只有 `models/ayolom/README.md` 有溯源，其余模型**无任何来源说明**。
>
> **本文件只做记录，不改动任何模型文件。**
> 所有指纹 = 各 `.mlmodelc/weights/weight.bin` 的 SHA-256。

---

## 1. 根层模型总览

| 目录 | 体积 | 转换日期 | 源框架 | 存储精度 | SHA-256 (weights/weight.bin) |
|---|---|---|---|---|---|
| `m9_mono.mlmodelc` | 15M | 2026-08-24 | torch 2.13.0 | Float16 | `93a51385bab76c98877244628f84a1956358567c4805c92b16d01925ebba0476` |
| `game_assist_control.mlmodelc` | 7.6M | 2026-08-24 | torch 2.13.0 | Mixed (Float16, Int8) | `36f35c1adb940aaed6ed5f7841d0431fa00d8e01931b54e4c259636479395088` |
| `yolo26s.mlmodelc` | 9.4M | 2026-09-30 | torch 2.13.0 | Mixed (Float16, Palettized 8bit) | `8bcb16fc5bc06c282ec900095d7d5b8de9d075838e23e16c5f735de68e4e7240` |
| `speed_digit_cnn.mlmodelc` | 316K | 2026-08-26 | torch 2.13.0 | Float16 | `fa4505cfdb2e076c0fd9806d37bf5f0a8bccc40f1255f6fe64b6532f11e11b67` |
| `speed_digit_cnn_v4.mlmodelc` | 2.3M | 2026-08-28 | torch 2.13.0 | Mixed (Float16, Int8) | `63454b113e9b550f5dd116301660a896db6a78e068b931d7a24bd89125783942` |
| `ppocrv6_tiny_ft_int8.mlmodelc` | 1.2M | 2026-08-14 | torch 2.13.0 (TorchScript) | Mixed (Float16, Int8) | `f49b314e3a89d98fe710b2bb58b1bdbe9738d17da6b5c17de565ea58e4b79962` |

全部为 CoreML **legacy `.mlmodelc`** 格式（`analytics/ coremldata.bin metadata.json model.mil weights/`），
可直接 `MLModel(contentsOf:)`，**无需运行时 `compileModel`**。

---

## 2. 逐模型接口契约

### 2.1 `m9_mono.mlmodelc` — 端到端主驾（M9）
```
输入 image:          MultiArray (Float32 1 × 3 × 180 × 320)   CHW，归一化 [0,1]
输入 vehicle_state:  MultiArray (Float32 1 × 6)
输出 steer:          MultiArray (Float32 1 × 1)   tanh    ∈ [-1, 1]
输出 throttle:       MultiArray (Float32 1 × 1)   sigmoid ∈ [0, 1]
输出 brake:          MultiArray (Float32 1 × 1)   sigmoid ∈ [0, 1]
```
- 消费方：`Sources/AuroraDrive/Inference/InferenceEngine.swift`（`modelFileName = "m9_mono"`）
- 车辆状态 6 维契约见 `InferenceEngine.swift:317-322` 注释
  （`[speed_norm, curvature*5, sin(heading), cos(heading), speed_limit_norm, 0]`）
- ⚠️ `vehicle_state` 当前**无游戏遥测**，speed 用 `DriveState.speed` 估算、rpm/gear 用启发式占位

### 2.2 `game_assist_control.mlmodelc` — 第二司机（YOLO 接管档）
```
输入/输出：与 m9_mono 完全相同（同构，180×320）
```
- 消费方：`InferenceEngine.swift`（`modelFileName = "game_assist_control"`）
- 与 M9 是**两套独立权重**，由 `DegradeStateMachine` 按档位二选一

### 2.3 `yolo26s.mlmodelc` — 目标检测
```
输入 image:    Image (Color 640 × 640)
输出 var_1442: MultiArray (Float32 1 × 300 × 6)   每行 [x1,y1,x2,y2,conf,class_id]
```
- 消费方：`Sources/AuroraDrive/Inference/YoloEngine.swift`（`inputSize = 640`）
- **NMS-free 端到端**（e2e 内置 NMS + Top-K），后处理只做置信度过滤 + 截断
- ⚠️ **来源说明（重要）**：模型自带元数据 `shortDescription` 写着
  > `Ultralytics YOLO26s model trained on /home/lq/codes/ultralytics/ultralytics/cfg/datasets/coco.yaml`

  即这是 **Ultralytics 官方 COCO 预训练权重**（80 类通用目标），
  **未针对本游戏微调**。用户数据（`userDefinedMetadata`）为
  `batch=1, head=Detect, imgsz=[640,640]`。
  - 影响：检测类别是 COCO 的 person/car/… 而非游戏内对象；域内精度有上限。
  - **许可提示**：Ultralytics YOLO 系列为 **AGPL-3.0**。本项目为 `GPL-3.0-or-later`。
    两者组合的许可义务**建议人工复核**（尤其若要分发二进制）。
- 上游：<https://docs.ultralytics.com>（模型元数据 `docs` 字段）

### 2.4 `speed_digit_cnn.mlmodelc` — 速度数字 CNN **v1（旧版）**
```
输入 image:             MultiArray (Float32 1 × 1 × 45 × 25)
输出 classLabel:        Int64
输出 classLabel_probs:  Dictionary (Int64 → Double)
```
- ⚠️ **输入尺寸 45×25 与当前运行期常量不符**：`SpeedOCRReader.templateHeight/Width = 90/50`。
- 全仓 `grep '"speed_digit_cnn"' Sources/` **无命中** → 当前代码只加载 `speed_digit_cnn_v4`，
  本目录属**遗留文件**。保留作回滚参考。

### 2.5 `speed_digit_cnn_v4.mlmodelc` — 速度数字 CNN（当前备用引擎）
```
输入 digit_input:   MultiArray (Float16 1 × 1 × 90 × 50)
输出 digit_output:  MultiArray (Float16 1 × 10)    10 类 softmax 概率
```
- 消费方：`SpeedOCRReader.swift:505-514`（`loadCNNModel`，`relative: "models/speed_digit_cnn_v4"`）
- 用途：PP-OCR 主路径失败时的**降级引擎**（`SpeedOCRReader.swift:426` 附近注释）
- ⚠️ **潜在缺陷（本轮只读侦察发现，未修）**：模型声明输入为 **Float16**，
  而 `SpeedOCRReader` 构造输入时用的是 `dataType: .float32`。
  PP-OCR 路径有明确注释警告过 dtype 不匹配会"被按 fp16 解读成垃圾"，
  本路径是否存在同类问题**未经实测**（`--speed-selftest` 本轮未能取到结果）。
  **建议**：跑一次 `--speed-selftest` 并强制走 CNN 引擎，确认识别率。
- 代码注释里的「构造 MLMultiArray (1, 1, 45, 25)」是 **v1 的尺寸**，已过期。

### 2.6 `ppocrv6_tiny_ft_int8.mlmodelc` — PP-OCRv6 微调整行识别（主引擎）
```
输入 image:   MultiArray (Float16 1 × 3 × 48 × 136)
输出 logits:  MultiArray (Float16 1 × 17 × 6906)   CTC，blank=0
```
- 消费方：`SpeedOCRReader.swift:462-463`（`relative: "models/ppocrv6_tiny_ft_int8"`）
- 字符表：`models/ppocrv6_tiny_ft_keys.txt`
- 解码规则：CTC（blank=0、折叠重复）→ 置信 ≥0.30 → 取后 3 位左补零 → <2 位判无效
- ⚠️ **输入必须是 fp16**：`SpeedOCRReader.swift:918-922` 长注释记录了
  「喂 fp32 数组会被按 fp16 解读成垃圾，自检实测 300/300 失败」。
  运行期按 `model.modelDescription` 声明的 dtype 动态构造，**不要写死 fp32**。

---

## 3. 完整性校验方法

```bash
# 逐个核对 weights 指纹（期望与第 1 节表格一致）
for m in models/*.mlmodelc; do
  w=$(find "$m/weights" -type f | sort | head -1)
  printf "%s  %s\n" "$(shasum -a 256 "$w" | awk '{print $1}')" "$m"
done

# 核对接口契约（不需要 coremltools，直接读 metadata.json）
for m in models/*.mlmodelc; do
  echo "── $m"
  python3 -c "
import json;d=json.load(open('$m/metadata.json'));e=d[0]
for k in ('inputSchema','outputSchema'):
    for i in e.get(k) or []: print('  ',i['name'],i['formattedType'],i['dataType'])
"
done
```

---

## 4. 已知未决项（交接给后续轮次）

| # | 事项 | 位置 | 状态 |
|---|---|---|---|
| 1 | `yolo26s` 是 COCO 预训练、未游戏微调 → 域内精度上限 | 本文件 §2.3 | **待评估** |
| 2 | Ultralytics AGPL-3.0 与本项目 GPL-3.0 的组合许可义务 | 本文件 §2.3 | **待人工复核** |
| 3 | `speed_digit_cnn_v4` 声明 fp16 输入、代码喂 fp32 | `SpeedOCRReader.swift:1183` 附近 | **待实测** |
| 4 | `speed_digit_cnn.mlmodelc`（v1，45×25）为遗留文件，无引用 | 本文件 §2.4 | 保留 |
| 5 | `yolopx3_w8a16.mlmodelc` 结构残缺（只有 `weights/`） | 见 `models/yolopx/NOTICE.md` | **已从候选表移除**（A22） |

---

## 5. 相关文件

- `models/ayolom/NOTICE.md` — A-YOLOM 系列溯源
- `models/yolopx/NOTICE.md` — YOLOPX 三合一系列溯源
- `models/ayolom/README.md` — A-YOLOM 原始溯源（2026-10-02，作者提供）
