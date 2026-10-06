# 模型 int8 线性量化报告

> **档案标注（2026-09-19）**：本报告为 2026-09-12 量化交付记录，正文结论保留。2026-09-19 磁盘清理已把可再生/中间产物移向外置硬盘 `/Volumes/代码项目/自动驾驶项目半成品版本1.0到10.0/删除_20260919/自动驾驶系统清理/（⚠️ 2026-09-29 路径订正：实际在「自动驾驶项目半成品版本1.0到10.0」目录内，原文少两级）`（对照表见 `docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md` §七）；int8 量化模型本体（`models/yolo26s_int8.mlpackage`、`models/game_assist_control_int8.mlpackage`、`models/speed_digit_cnn_v4_int8.mlpackage`、`tools/ppocrv6_finetune/models/ppocrv6_tiny_ft_int8.mlpackage`）仍在本地。

> 目标：把项目在用的模型全部做 int8 线性量化。
> 执行时间：2026-09-12 | 工具：coremltools 9.0（`.venv-yolo26`）
> 回滚：`models/_backup_fp16/`（69 MB，五个原始模型全量备份）

## 一、最终结果：5 个模型

| # | 模型 | 用途 | 量化前 | 量化后 | 状态 |
|---|---|---|---|---|---|
| 1 | `ppocrv6_tiny_ft_int8` | 速度表**主**（PP-OCRv6 微调）| 1.2 MB | 1.2 MB | ✅ 早已是 int8 |
| 2 | `speed_digit_cnn_v4` | 速度表**备用**（降级路径）| 4.6 MB | **2.3 MB** | ✅ 本次量化并部署 |
| 3 | `yolo26s` | YOLO 环境检测 | 9.4 MB | 9.4 MB | ✅ 权重本就是 uint8（无可量化空间）|
| 4 | `game_assist_control` | 驾驶**档2**（YOLO 接管）| 15.0 MB | **7.6 MB** | ✅ 本次量化并部署 |
| 5 | `m9_mono` | 驾驶**档1**（端到端主驾）| 15.0 MB | 15.0 MB | ⛔ 跳过（源不可得，见 §4）|

**合计：45.2 MB → 35.5 MB**；其中**可量化的两个模型 19.6 → 9.9 MB（减半）**。

## 二、量化配置

```python
OptimizationConfig(global_config=OpLinearQuantizerConfig(
    mode="linear_symmetric", dtype="int8"))
```

- **int8 线性量化**（Apple 首选）：per-channel scale，ANE 原生支持，无需运行时解压
- 未使用调色板量化：8-bit 体积与 int8 相同但多解压开销；4-bit 已在 PP-OCR 上实测崩溃（0% 准确率）

## 三、验证（三层）

**① 数值一致性**（同源对比，20 组随机输入）

| 模型 | 最大绝对差 | 结论 |
|---|---|---|
| `speed_digit_cnn_v4` | argmax **19/20 一致**，最大概率差 0.078 | ✓ |
| `game_assist_control` | steer 0.0005 / throttle 0.0005 / brake 0.0001 | ✓ |
| `yolo26s` | 0.000000（未量化） | — |

**② Swift 端加载 + 推理**（模拟 app 的 `loadIfNeeded` 路径）

```
✓ m9_mono             mlmodelc  输入[image,vehicle_state] 输出[brake,steer,throttle]
✓ game_assist_control mlmodelc  输入[image,vehicle_state] 输出[brake,steer,throttle]
✓ yolo26s             mlmodelc  输入[image] 输出[var_1442]
✓ speed_digit_cnn_v4  mlpackage 输入[digit_input] 输出[digit_output]
```
IO 接口完全不变（量化只改权重精度，不动签名/结构）✓

**③ 端到端**（`--speed-selftest` 真实代码路径）

```
主路径  PP-OCRv6 整行 (int8) → 097 / 129 ✓
降级路径 CNN 备用 (3槽)      → 097 / 129 ✓（量化后精度未降）
```

## 四、m9_mono 为何跳过（技术依据）

**问题**：现役文件是编译产物 `.mlmodelc`，coremltools 无法加载（无 Manifest/spec）；唯一的源 `m9_mono.onnx` 与现役**行为不一致**。

**证据链**（同一固定输入）：

```
现役 m9_mono.mlmodelc          steer=-0.80078  throttle=+1.00000  brake=+0.00016   ← 目标
m9_mono.onnx（2026-07-26 旧）  steer=-0.99600  throttle=+0.76102  brake=+0.01756   ← 差异巨大
从 checkpoints 重新权威导出      steer=-1.00000  throttle=+1.00000  brake=+0.00000   ← 也不匹配
7/31 备份 .float16              steer=-0.00657  throttle=+0.98730  brake=+0.01214   ← 不匹配
```

**四个候选源全部不匹配** → 无法在"不改变驾驶行为"的前提下量化。用任一错误源替换 = **静默换掉主驾模型**（有安全含义），因此选择不动。

**根因（供后续排查）**：
1. `models/m9_mono.onnx` 是 7/26 历史产物，早于现役 `.mlmodelc`
2. 代码里存在 hot-reload 逻辑（`AuroraDriveApp.swift` 训练完成后把 `game_assist_control.*` 复制为 `m9_mono.*`），现役 `.mlmodelc` 可能来自某次训练后被复制的版本，**原始 .mlpackage 已不存在**
3. `src/train_mono.py` 曾有一个已修复的缺陷（P0-4：旧版 `deploy=True` 导出会静默忽略训练权重 → 导出随机权重模型），历史产物因此不可信

**将来替换 m9_mono 时随时可补量化的方法**：
```python
# 在 src/train_mono.py 的 convert_torch_to_coreml 末尾（保存 .mlpackage 之后）加：
from coremltools.optimize.coreml import (OptimizationConfig,
    OpLinearQuantizerConfig, linear_quantize_weights)
q = linear_quantize_weights(mlmodel, config=OptimizationConfig(
    global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")))
q.save(str(mlpackage_path.with_name(mlpackage_path.stem + "_int8.mlpackage")))
```
这样新训练产出的 m9_mono 天生就是 int8，体积减半。

## 五、部署与回滚

**部署**：原子替换（`cp` 到临时名 + `mv`），未触碰运行中的进程；`.mlmodelc` 用 `xcrun coremlcompiler` 从量化包重编译（因为加载器优先读 `.mlmodelc`）。

**回滚**（任何异常时）：
```bash
cd ~/Desktop/自动驾驶系统
cp -R models/_backup_fp16/* models/          # 五个原始模型全量恢复
# 若加载器读 .mlmodelc，需重新编译原始 .mlpackage：
xcrun coremlcompiler compile models/yolo26s.mlpackage models/
```

> 档案注（2026-09-19）：`models/_backup_fp16/` 回滚备份目录现已不在本地（不在 `docs/文档库/自动驾驶与功能/DEVELOPER_GUIDE.md` §七 清理清单内，何时移除待核实），上述回滚命令**不可再执行**；需要 fp16 原版时须重新导出。

**生效方式**：重启 AuroraDriveUI（模型在启动时加载）。

## 六、风险与后续

| 项 | 说明 |
|---|---|
| 驾驶模型量化 | `game_assist_control` 数值差 0.0005（可忽略），但**行为级验证需要实跑**（方向盘/油门是连续控制）|
| YOLO | 权重本就是 uint8，无需处理；若要进一步压可用 6-bit 调色板（需 mAP 验证）|
| m9_mono | 未量化（源不可得）；替换时按 §4 方法补做 |
| 废弃文件 | `speed_digit_cnn.mlpackage/.mlmodelc`（旧版，0 处代码引用）、`m9_mono.onnx*`（30.6 MB 历史产物）可清理 |
