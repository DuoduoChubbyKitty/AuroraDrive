# models/ayolom — A-YOLOM 预训练权重（2026-10-02 入手）

## 来源（官方）
- 论文：[arXiv:2310.01641](https://arxiv.org/abs/2310.01641) · IEEE TVT · DOI 10.1109/TVT.2024.3394350
- 仓库：https://github.com/JiayuanWang-JW/YOLOv8-multi-task
- 权重：README 第 138 行 SharePoint 分享（作者 Jiayuan Wang 本人）
  目录 `/personal/wang621_uwindsor_ca/Documents/pre-trained models/`

## 为什么用浏览器下载
SharePoint 分享链接对 `curl` 直接返回 **403**（需 JS 会话）。
用 ego-browser 打开分享页 → `page.fetch()` 带上会话 cookie → `saveAs` 落盘。
**直链对 curl 无效，必须走浏览器会话。**

## 文件
| 文件 | 体积 | 档位 | 说明 |
|---|---|---|---|
| `v4.pt`  | 7,569,606 B (7.2M)  | **n** | YOLOv8n 骨架，3.64M 参数 |
| `v4s.pt` | 27,524,934 B (26M)  | s   | YOLOv8s 骨架，13.61M 参数 |

两者均为标准 PyTorch zip 容器（魔数 `PK\x03\x04`），已验证。

## CoreML 产物（2026-10-02 导出）

| 文件 | 体积 | 用途 |
|---|---|---|
| `ayolom_n_int8.mlmodelc`  | 3.8M | **生产首位**（编译形态，免运行时编译） |
| `ayolom_n_int8.mlpackage` | 3.8M | 同上，包形态（需运行时编译） |
| `ayolom_n_fp16.mlmodelc`  | 7.2M | 仅**对拍基准**，不进生产候选表 |
| `ayolom_n_fp16.mlpackage` | 7.2M | 同上 |

### 导出命令
```bash
# INT8（生产）—— palette 8 位 kmeans + det 头保 fp16
PYTHONPATH=/tmp/ayolom_sklearn tools/ayolom/.venv/bin/python \
  tools/ayolom/export_ayolom_coreml.py --weights models/ayolom/v4.pt \
  --out models/ayolom/ayolom_n_int8.mlpackage --quantize int8

# 编译成 .mlmodelc（免运行时编译）
xcrun coremlcompiler compile models/ayolom/ayolom_n_int8.mlpackage /tmp/c8
cp -R /tmp/c8/ayolom_n_int8.mlmodelc models/ayolom/
```

### 接口契约（Swift 侧按此读取）
```
输入  image   ImageType  RGB  scale=1/255  bias=[0,0,0]   640×640
输出  det     [1, 5, 8400]   cx, cy, w, h, cls_conf
                            ⚠️ 与 yolopx 的 [1,8400,6] 不同：无 obj_conf，且是列优先
      da      [1, 2, 640, 640]   可行驶区 logits（与 yolopx 逐位相同）
      ll      [1, 2, 640, 640]   车道线 logits（与 yolopx 逐位相同）
```

⚠️ **输入必须是 `ImageType` 而不是 `TensorType`** —— Swift 侧
`YolopxEngine.infer` 喂的是 `MLFeatureValue(pixelBuffer:)`（像素缓冲），
`TensorType` 要的是 `MLMultiArray`，类型对不上会直接加载/推理失败。

### INT8 等价性实测（200 帧真游戏画面，ANE）
| 指标 | 值 |
|---|---|
| 可行驶区 da 掩码 IoU（vs fp16） | **0.9942** |
| 车道线 ll 掩码 IoU（vs fp16） | **0.9749** |
| 检测召回（vs fp16，IoU>0.5） | **99.1%** |
| 推理 p50 / p99 | **10.4 / 13.1 ms** → 95.9 Hz |
| 30Hz 预算占用 | 31% |

产物由 `tools/ayolom/verify_int8_final.py` 验证；接入方式见
`YolopxEngine.swift` 的 `family` 开关（`AURORA_AYOLOM=1` 启用）。

## ⚠️ 使用前必读（官方 README 原话）
> PS: If you want to use our provided pre-trained model, please make sure that
> your input images are **(720,1280)** size and keep **`imgsz=(384,672)`** to
> achieve the best performance.

- **训练输入 1280×720**，推理用 `imgsz=(384,672)`（≠ 整数倍缩放，是作者的特定选择）
- 本项目**实际用 640 letterbox**，实测在游戏画面上工作正常
  （真实游戏图：3 个框、可行驶 15.75%、车道线 3.285%，落在 yolopx 实测带内）
- `tnc: 3` = 车 + 可行驶区 + 车道线，三类
- 模型结构（导出脚本依赖）：`model.46 = Detect`（det 头，量化时跳过）、
  `model.47 / model.48 = Segment`（两个分割头）
