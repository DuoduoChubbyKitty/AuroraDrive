# OCR 性能与资源占用（踩坑记录）

> 【2026-09-19 核对标注】本文档为 2026-09-18 `data/mac_shots/`（208 张）批次 Python 批跑 OCR 的踩坑记录：文中 `build/ocr_shots.py`、`.venv-yolo26` 仍在本地可复现；批跑中间目录 `build/ocr_batch`/`ocr_batch2` 已随 9-19 磁盘清理移至外置硬盘 删除_20260919 目录。本文结论（det=CoreML MLProgram + rec=CPU 4 线程）是**Python 批跑工具链**的最优配置；与 Swift app 内 SpeedOCRReader 的"OCR 必须 GPU"（CPU 会卡死）结论不冲突——后者指 app 运行期 CoreML 通路。

## 事故
第一次跑 208 张截图 OCR 时，把用户机器压到 **load average 31**（8 核 M3），系统卡死。

## 根因
```python
# ❌ 错误写法：onnxruntime 默认用满所有 CPU 核心
sess = ort.InferenceSession(model_path, providers=['CPUExecutionProvider'])
```
`intra_op_num_threads` 默认为**核心数**，8 核全占 → 叠加 DSH/其他应用直接过载。

**不是 GPU vs CPU 的问题，是线程数没限制。**

## 实测数据（Apple M3, 8 核, onnxruntime 1.28.0）

### det 阶段单次推理（输入 608×960）
| 配置 | ms | 备注 |
|---|---|---|
| CPU 默认 | 64 | 基线 |
| **CoreML `MLProgram` + `ALL`** | **39** | **快 1.64×** ✅ |
| CoreML `NeuralNetwork` + `ALL` | 113 | 慢（这是默认格式） |
| CoreML `MLProgram` + `CPUAndNeuralEngine` | 128 | ANE 反而慢 |
| CoreML `CPUOnly`（对照） | 113 | — |

### 完整 det+rec 流程（真实 1470×923 截图，每图约 30 个文本框）
| 配置 | ms/图 | 备注 |
|---|---|---|
| 全 CPU 8 线程 | 257 | 快但压死机器 |
| **全 CPU 4 线程** | **273** | **仅慢 6%** ✅ |
| det=CoreML + rec=CPU | 267 | 无明显优势 |
| 全 CoreML | — | **崩溃** |

### 为什么 rec 不能用 CoreML
```
E5RT: Input has unbounded dimension which is not supported
E5RT: Failed to PropagateInputTensorShapes ... shapes of x and y are not broadcastable
```
rec 模型是动态宽度输入（按文本框宽高比 reshape），CoreML 的 MIL 编译不支持无界维度。
且 rec 是逐框调用（每图 ~30 次），GPU 调度开销大于收益。

## 正确配置（`build/ocr_shots.py`）
```python
so = ort.SessionOptions()
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
so.intra_op_num_threads = 4        # ← 防卡死的关键
so.inter_op_num_threads = 1

det_prov = [('CoreMLExecutionProvider',
             {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'ALL'}),
            'CPUExecutionProvider']
rec_prov = ['CPUExecutionProvider']    # rec 必须 CPU

det = ort.InferenceSession(DET_P, so, providers=det_prov)
rec = ort.InferenceSession(REC_P, so, providers=rec_prov)
```

## 效果
| | 修复前 | 修复后 |
|---|---|---|
| 208 张截图耗时 | 未完成（卡死） | **45 秒** |
| load average | **31.10** | **4.67** |

## 复用方式
```python
import sys; sys.path.insert(0, 'build')
from ocr_shots import build_sessions, scan

det, rec = build_sessions()
texts = scan('path/to/img.png', det, rec)
# → [{'t': '确认', 'c': 0.998, 'x': 1740, 'y': 707, 'w': 106, 'h': 55}, ...]
```

## 命令行
```bash
# 全量
.venv-yolo26/bin/python build/ocr_shots.py

# 测试 20 张
.venv-yolo26/bin/python build/ocr_shots.py --limit 20

# 机器紧张时关掉 CoreML + 加休眠
.venv-yolo26/bin/python build/ocr_shots.py --no-coreml --sleep 0.05
```

---

# 另一条教训：不要甩锅给子代理

事故发生时我有 6 个子代理在跑，我第一反应是"它们也在跑 CPU OCR"并把它们全部中断了。

**事实**：子代理当时处于调查/搜索阶段，并没有大量占用 CPU。真正吃满 CPU 的是**我自己那个没限制线程数的进程**。

**教训**：
1. 资源问题时先量测，不要先假设
2. 中断子代理是不可逆的副作用，代价高，不能凭猜测做
3. 别把自己造成的问题归因给并行任务
