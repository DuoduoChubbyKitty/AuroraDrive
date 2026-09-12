# 方案C：微调 PP-OCRv6 rec —— 阶段 0~1 报告

## 阶段 0｜Paddle 训练环境 ✅ 完成

### 环境
| 项 | 值 |
|---|---|
| 解释器 | `/Users/dupi/Desktop/自动驾驶系统/.venv-paddle/bin/python3` |
| PaddlePaddle | **3.3.1**（macOS arm64 wheel，104.5 MB） |
| Python | 3.11.9 / arm64 |
| 设备 | **cpu**（无 GPU/MPS） |
| 附加 | paddleocr、paddlenlp、pyyaml |

**为什么另建 venv**：`.venv-yolo26` 里的 torch/coremltools 是可用状态，装 104MB 的 paddle 有污染风险。新建 `.venv-paddle` 隔离。

### R1 风险实测结论：**排除**
训练链路完整验证通过：
```
可学习性测试：loss 0.7669 → 0.0153，训练准确率 100%
CTC Loss（6906 类）：前向+反向 ✅
算子全通：Conv2D/BatchNorm/ReLU/LSTM/MultiheadAttention/GlobalAvgPool
权重保存加载 ✅  推理模式 ✅
```

### 约束与踩坑
| # | 问题 | 处理 |
|---|---|---|
| 1 | `paddlex --install PaddleOCR` 崩溃（`repos` 目录不存在） | PaddleX 已知 bug，先 `mkdir repos` 再装 |
| 2 | PaddleX CLI **不支持** `-c config.yaml` | 训练须走 PaddleOCR 仓库的 `tools/train.py` |
| 3 | `timeout` 命令 macOS 不存在 | 改用后台任务 `nohup ... &` |
| 4 | 训练在 CPU 上慢 | 7 samples/s，1 epoch ≈ 6 分钟 |

---

## 阶段 1｜训练权重与数据 ✅ 完成

### 1.1 训练权重（R3 风险排除）
官方公开提供，已下载验证：
```
tools/ppocrv6_finetune/pretrained/
  PP-OCRv6_tiny_rec_pretrained.pdparams    68.22 MB   290 张量   17.87 M 参数
  PP-OCRv6_small_rec_pretrained.pdparams  119.13 MB   422 张量   31.22 M 参数
```
来源：`https://paddle-model-ecology.bj.bcebos.com/paddlex/official_pretrained_model/`

**架构**（从官方配置确认）：`PPLCNetV4(tiny) + MultiHead(CTCHead + NRTRHead)`，损失 `MultiLoss(CTC + NRTR)`。

### 1.2 数据集
```
tools/ppocrv6_finetune/dataset/
  train.txt   2806 行   images/xxx.jpg<TAB>三位数字
  val.txt     5077 行
  dict.txt    6904 字符  ← 与项目 keys.txt 逐字节相同
  images/     → 软链到 data/speed_crops_v3（不复制）
```
- 格式：`images/相对路径<TAB>文本`，含前导零
- 字典：6904 字符 = 官方 `ppocrv6_tiny_dict.txt`（已验证完全相同）
- 输出维度 6906 = 6904 + blank + space（`use_space_char: true`）

### 1.3 划分（沿用，未改）
- 训练：其余 3 个 clip = 2806 张
- 测试：整个 `clip_20260827_204437` = 5077 张

### 1.4 零样本基线（完整 5077 张，非抽样）
| 判据 | 准确率 |
|---|---|
| **原生全串匹配**（PaddleOCR RecMetric 口径） | **99.17%**（5035/5077） |
| 加解码规则后 | 99.03%（5028/5077） |

单张耗时 2.62 ms；输出长度分布 `{1:5, 2:14, 3:5037, 4:18, 5:3}`。

> ⚠ **重要发现**：把此前标定的"置信度 < 0.30 判无效"套在 PP-OCRv6 原版上，
> 会把 7 张**预测正确但置信度偏低**的判成无效（99.17% → 99.03%）。
> **该门槛是针对旧模型标定的，微调后必须重新标定。**

---

## 阶段 2｜微调（进行中）

### 冒烟验证（2 epoch）
链路全通。**第 1 个 epoch 即达测试集 99.88%**：
```
best metric, acc: 0.9988181977569073, best_epoch: 1
```
训练集上 loss 6.87 → 1.35（100 步），acc 0.375 → 1.000。
（acc 从 0.375 起步而非 0，证明预训练权重成功载入）

### 正式训练（进行中）
- 配置：`train_full.yml`
- `epoch_num: 15`，`batch_size: 32`，`lr: 5e-4`（Cosine + 2 epoch warmup）
- `use_gpu: false`，`distributed: false`
- 多尺度 `scales: [[320,32],[320,48],[320,64]]`（保持官方默认，与基线可比）
- 日志：`full_train.log`

### 已知性能约束
我们的裁片 51×18 → 缩放到高 48 后仅 **136 宽**，而固定 padding 到 320，
**有效占比仅 42.5%，57.5% 是无效 padding**。
→ 后续可探索窄宽度（160/144）以提速约 2 倍，但会偏离官方输入规格，
   需在报告中说明并单独验证。
