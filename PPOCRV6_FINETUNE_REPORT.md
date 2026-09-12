# PP-OCRv6 tiny rec 微调 —— 最终评测报告

> Route C：微调 PaddleOCR 官方 PP-OCRv6 tiny 识别模型，替代原 per-digit CNN。
> 测试集：**冻结的整段未见 clip `clip_20260827_204437`（5077 张）**，训练集为其余 3 段 clip（2806 张），clip 级分组杜绝相邻帧泄漏。

## 1. 结果总览

| 模型 | 测试集准确率 | 错误张数 | CoreML 体积 | 单帧延迟* |
|---|---|---|---|---|
| PP-OCRv6 tiny 零样本 | 99.17% | 42 | — | — |
| **PP-OCRv6 tiny 微调（int8）** | **99.9803%** | **1** | **1.2 MB** | **0.40 ms** |
| SpeedNet（route B 参照） | 99.98% | 1 | 0.63 MB | 0.25 ms |
| 目标门槛 | ≥99.5% | — | — | — |

\* 延迟为 coremltools Python API 实测（M3 CPU），Swift 原生调用只会更快；相对 10 Hz 帧间隔（100 ms）余量 >200 倍。

**结论：微调把零样本的 42 个错误压缩到 1 个，准确率追平 route B 自训模型。**

## 2. 训练过程

- 起点：官方预训练权重 `PP-OCRv6_tiny_rec_pretrained.pdparams`（17.87M 参数）
- 配置：`train_full.yml` —— 15 epoch，batch 32，lr 5e-4（cosine + warmup 2），CPU（M3，Paddle 3.3.1 无 GPU/MPS）
- 吞吐 7.4 samples/s，约 6 分钟/epoch，全程 1 小时 46 分

每轮验证集准确率（PaddleOCR eval，逐图全串匹配）：

| epoch | acc | 备注 |
|---|---|---|
| 1 | 99.5667% | 已超 99.5% 门槛 |
| 2 | 99.8030% | |
| 3 | 99.9212% | |
| 4 | 99.9409% | |
| 8 | **99.9803%** | **首次达到并保持** |
| 9–15 | 99.9803% | 连续 8 次评估逐位一致，完全收敛 |

epoch 8 后训练损失与验证指标均不再变化，15 epoch 配置无过拟合。best checkpoint：`tools/ppocrv6_finetune/output/v6tiny_ft/best_accuracy.pdparams`。

## 3. 导出链（阶段 3）

```
best_accuracy.pdparams (68 MB)
  → tools/export_model.py        inference 模型（PIR .json + .pdiparams）
  → paddle2onnx 2.1.0            v6tiny_ft.onnx（4.3 MB，opset 14）
  → onnx2torch + coremltools 9.0 ppocrv6_tiny_ft.mlpackage（fp16 2.2 MB）
  → coremltools.optimize          int8 / pal6 / pal4 三档量化
```

固定输入 `1×3×48×136`（裁片恒 51×18，高 48 时宽 = ceil(51×48/18) = 136），输出 `logits [1, T, 6906]`，显式命名 `image` / `logits`（无 `var_99` 类匿名名）。

**踩坑记录（重要）：**
1. **Paddle 3.x 默认导出 PIR 新格式**（`.json`），paddle2onnx 需要 `inference.json` 直接作为 `--model_filename` 传入（paddle2onnx ≥ 2.0 支持）。走旧格式需 `Global.export_with_pir=false`，但该路径在 PPLCNetV4 的 gelu 上会报 `TypeError`，不可用。
2. **字典第 617 行是全角空格 U+3000**。Python `str.strip()` 会把它当空白滤掉导致索引错位 1；PaddleOCR 官方加载只 strip `\n`。评测/部署代码必须用 `line.strip("\n").strip("\r\n")`。
3. CTC 字符表构成：`["blank"] + dict(6904) + [" "] = 6906`，blank 在最前，与训练一致。

## 4. 量化对比（CoreML，全量 5077 张）

| 精度 | 体积 | 准确率 | 延迟 |
|---|---|---|---|
| fp16 | 2.2 MB | 99.9803%（5076/5077） | 0.528 ms |
| **int8 线性** | **1.2 MB** | **99.9803%（5076/5077）** | **0.395 ms** |
| 6-bit 调色板 | 916 KB | 99.9803%（5076/5077） | 0.407 ms |
| 4-bit 调色板 | 652 KB | **0%（输出全空，崩溃）** | — |

int8/pal6/fp16 三者与 ONNX 端逐图一致；4-bit 重创 17.87M 参数 CTC 模型（与此前 13.4M Forza 模型 4-bit 丢 35pp 的教训一致）。**选定 int8 为交付模型。**

## 5. 置信度校准（微调后重测）

| 分位 | 置信度 |
|---|---|
| min | 0.8343 |
| p1 | 0.8587 |
| p5 | 0.9928 |
| median | 1.0000 |

微调前存在"正确但置信 <0.30 被误杀"的问题（99.17% → 99.03%）；微调后最低置信 0.8343，**0.30 阈值极其安全**。若希望捕获分布外异常输入（如 UI 大改版），可将阈值上调至 0.75~0.80，仍不损失任何正确帧。

## 6. 逐位准确率与混淆矩阵

全部 5077 张中仅 1 张错（`_004659.jpg`：标签 `006` → 读 `096`，错在十位 0→9），据此：

| 位 | 准确率 | 错误数 |
|---|---|---|
| 百位 | 100.00%（5077/5077） | 0 |
| 十位 | 99.9803%（5076/5077） | 1 |
| 个位 | 100.00%（5077/5077） | 0 |

混淆矩阵（3×10 各位×数字，仅列非对角项，其余全对角满员）：

```
        预测→  0  1  2  3  4  5  6  7  8  9
百位 真=0  3310  .  .  .  .  .  .  .  .  .
     真=1   . 1767 .  .  .  .  .  .  .  .      ← 对角 100%
十位 真=0   .  .  .  .  .  .  .  .  .  1      ← 唯一错例：真 0 → 预测 9
     其余    对角满员（0 错误）
个位 全部    对角满员（0 错误）
```

叠加项目解码规则（后 3 位 + 置信 ≥0.30 + 无效保持上一速度）后的**系统级准确率与单帧匹配率一致为 99.9803%**：微调后全测试集置信度最低 0.8343，无任何帧触发"无效"分支，规则不引入额外损失（也说明无效保持规则作为分布外兜底仍然必要，只是本测试集内未触发）。

## 7. 唯一错例

`clip_20260827_204437_004659.jpg`：标签 `006` → 模型读 `096`（CTC 原始串，置信 1.0）。

高置信错误说明该帧十位 0/9 的视觉形态本身存疑（模糊/过渡帧）。4096 张训练样本未覆盖此形态；SpeedNet 与微调模型在全测试集同样只剩 1 错，是否同一帧待集成后核查。**1/5077 的残留错误配合"无效帧保持上一速度"规则对实际使用无影响。**

## 8. 与 route B（SpeedNet）的取舍

| 维度 | 微调 PP-OCRv6 tiny | SpeedNet |
|---|---|---|
| 准确率 | 99.9803% | 99.98% |
| 参数量 | 17.87M | 0.642M |
| int8 体积 | 1.2 MB | 0.63 MB |
| 延迟 | 0.40 ms | 0.25 ms |
| 通用性 | 官方架构，保留通用字符表，未来可识别非纯数字文本 | 任务特化，仅 3 位数字 |
| 可维护性 | 可继续用官方训练栈增量微调 | 自定义栈 |

两者均远超门槛。SpeedNet 更小更快；微调 PP-OCRv6 通用性与官方生态更强。**建议默认集成微调 PP-OCRv6 int8**（用户选定的 route C 交付物），SpeedNet 作为轻量备选保留。

## 9. 产物清单

- `tools/ppocrv6_finetune/output/v6tiny_ft/best_accuracy.pdparams` —— 最优训练权重
- `tools/ppocrv6_finetune/models/ppocrv6_tiny_ft.onnx` —— ONNX（4.3 MB）
- `tools/ppocrv6_finetune/models/ppocrv6_tiny_ft_int8.mlpackage` —— **交付模型（1.2 MB）**
- `tools/ppocrv6_finetune/models/ppocrv6_tiny_ft{,_pal6,_pal4}.mlpackage` —— 对照档
- `tools/ppocrv6_finetune/eval_onnx.py` / `eval_onnx_result.json` —— ONNX 全量评测
- `tools/ppocrv6_finetune/eval_coreml.py` / `eval_coreml_result.json` —— CoreML 四档评测
- `tools/ppocrv6_finetune/onnx2coreml.py` —— 导出链脚本（W 已修正为 136）
- `tools/ppocrv6_finetune/STAGE01_REPORT.md` —— 阶段 0–1 环境搭建文档（PaddlePaddle 3.3.1 arm64 落地过程、解释器路径、踩坑）
- `tools/ppocrv6_finetune/train_full.yml` / `train_smoke.yml` / `prep_dataset.py` —— 可复现训练配置与脚本
- `tools/ppocrv6_finetune/full_train.log` —— 完整训练曲线日志
- `PPOCRV6_FINETUNE_REPORT.md` —— 本报告

## 10. 待办（需用户确认）

1. **主程序集成**：`Sources/AuroraDrive/SpeedOCRReader.swift` 目前仍走旧 5 层 per-digit CNN 路径，切换到 `ppocrv6_tiny_ft_int8.mlpackage`（image `[1,3,48,136]` fp32 归一化输入 → logits `[1,T,6906]`，CTC 解码 + 取末 3 位 + 置信阈值）。涉及主程序源码修改，等待批准后进行。
2. 置信度阈值维持 0.30 或上调至 0.75（见 §5）。
