# 车速 OCR 重建 — 交付说明

> 目标：把《异环》车速数字识别做到可用（单帧 ≥95%、时序 ≥99%）
> 开始时间：2026-09-12
> 当前进度：**阶段 0 完成**

---

## 阶段 0｜环境修复 ✅ 已完成

### 问题
`.venv-yolo26` 中 91 个原生库（`.so`）被 macOS 拒载：
```
ImportError: dlopen(...) library load disallowed by system policy
```
原因：这些 `.so` 同时带 `com.apple.quarantine` 扩展属性 + 仅 adhoc/linker 签名，
Gatekeeper 拒绝将其载入进程。

受影响模块（原始状态）：`numpy.random`、`scipy`、`coremltools`（含
`libmilstoragepython.so`）。表现为「明明装了却 import 失败」。

### 修复
```bash
xattr -dr com.apple.quarantine /Users/dupi/Desktop/自动驾驶系统/.venv-yolo26
```
清除后残留 quarantine 数量：**0**。

### 验证结果

| 模块 | 版本 | 状态 |
|---|---|---|
| numpy | 2.3.5 | ✅ |
| numpy.random | 2.3.5 | ✅ |
| scipy | 1.17.1 | ✅ |
| scipy.sparse | 1.17.1 | ✅ |
| coremltools | 8.3.0 | ✅ |
| torch | 2.13.0 | ✅ |
| onnxruntime | 1.28.0 | ✅ |
| PIL | 12.2.0 | ✅ |
| cv2 | 5.0.0 | ✅ |

补充冒烟测试：
- **MPS 训练**：`torch.backends.mps.is_available() == True`，3 步反向传播通过 ✅
- **CoreML 转换**：`torch.jit.trace → ct.convert(mlprogram, macOS15)` 通过，
  产出 147.1 KB 的 .mlpackage ✅

### 最终选用的解释器（后续阶段统一使用）

```
/Users/dupi/Desktop/自动驾驶系统/.venv-yolo26/bin/python3
```
- Python 3.11.9
- 启用方式：`cd /Users/dupi/Desktop/自动驾驶系统 && source .venv-yolo26/bin/activate`

**备用**（venv 再次损坏时）：
```
/Library/Frameworks/Python.framework/Versions/3.11/bin/python3
```
（coremltools 9.0，但**无 torch**，仅供推理/转换使用）

### 已知小瑕疵（不影响使用）
- `scikit-learn 1.9.0` 版本超出 coremltools 支持范围（要求 0.17~1.5.1），
  coremltools 会打印警告并**禁用 sklearn 相关转换 API**。
  本项目不依赖该 API，可忽略；若后续需要，再降级 scikit-learn。

---

## 阶段 1｜重建真值标注 ⏳ 待开始

## 阶段 2｜训练 ⏳ 待开始

## 阶段 3｜验收 ⏳ 待开始
