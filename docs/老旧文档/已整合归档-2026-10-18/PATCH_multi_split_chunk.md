# `export_multi_split.py::_Chunk` 等价性 Bug 修复方案（S4 验证产出）

## 结论

现版 `tools/export_multi_split.py` 的 `_Chunk`（第 36–76 行）**与单模型
`src/model_v2.py::IterationRefiner.forward` 不等价**。Lead 之前单 seed
`maxdiff=0` 是**零权重导致的 trivially 等价**，掩盖了结构错误。

## 根因

单模型 refiner（`src/model_v2.py:1124-1133`）中，`fused` 是**常量**，24 步全程：

```python
h = fused
for step in range(1, self.num_steps + 1):
    cell = self.cells[0] if self.shared else self.cells[step - 1]
    h = cell(fused, h)              # ← 第一入参永远是「原始 fused」
    delta = self.refiner_proj(h)
    refined = fused + delta         # ← 残差基址永远是「原始 fused」
    ...
    h = refined                     # ← 只有隐状态 h 跨步传递
```

现版 `_Chunk` 把「块输入」同时当作 cell 第一入参**和**残差基址：

```python
def forward(self, fused):          # fused 是「块输入」
    h = fused
    for step in ...:
        h = self.cell(fused, h)    # ← 对 chunk2+ 这里是「上一块的 refined」，错
        refined = fused + delta    # ← 同上，错
        ...
        h = refined
    return h
```

- **chunk1**（输入恰为原始 fused）→ 前 4 步逐位一致（step4 diff = 0）
- **chunk2+**（输入是上一块的 refined）→ cell 第一入参 / 残差基址被污染
  → 从 step5 起不等价，误差随步数**指数放大**

实测（注入非零权重，排除零权重陷阱）：

| 步 | 现版 chunk 边界 maxdiff |
|----|------------------------|
| step4 | 0 |
| step8 | 1.4e2 ~ 1.9e2 |
| step12 | 5.2e2 ~ 6.5e2 |
| step16 | 1.5e3 ~ 2.7e3 |
| step20 | 2.4e4 ~ 3.6e4 |
| step24 | 3.5e5 ~ 6.7e5 |

## 修复

`_Chunk` 改为**双输入** `(fused_base, h)`：`fused_base` 全程透传原始 fused，
`h` 为跨块隐状态。

```python
class _Chunk(nn.Module):
    """refiner 的一小块。显式携带原始 fused，跨块只传隐状态 h。

    串联：h = fused0
          for chunk in chunks: h = chunk(fused0, h)
    """
    def __init__(self, refiner, step_start, step_end):
        super().__init__()
        self.shared = refiner.shared
        self.cells = refiner.cells          # 保留 ModuleList，兼容 shared/indep
        self.refiner_proj = refiner.refiner_proj
        self.expert_out_proj = refiner.expert_out_proj
        self.step_start = step_start
        self.step_end = step_end
        self.moe_steps = [s for s in refiner.moe_steps if step_start <= s <= step_end]
        if self.moe_steps and refiner.experts is not None:
            self.router = refiner.router
            self.experts = refiner.experts
            self.num_experts = refiner.num_experts
        else:
            self.router = None
            self.experts = None
            self.num_experts = 0

    def forward(self, fused_base, h):
        """fused_base [B,512]（不变） + h [B,512]（跨块隐状态） → h_new [B,512]"""
        for step in range(self.step_start, self.step_end + 1):
            cell = self.cells[0] if self.shared else self.cells[step - 1]
            h = cell(fused_base, h)              # ★ 第一入参 = 原始 fused
            refined = fused_base + self.refiner_proj(h)   # ★ 基址 = 原始 fused
            if self.experts is not None and step in self.moe_steps:
                route_logits = self.router(refined)
                expert_weights = torch.softmax(route_logits, dim=-1)
                expert_out = torch.zeros_like(refined)
                for e in range(self.num_experts):
                    w = expert_weights[:, e:e + 1]
                    expert_out = expert_out + w * self.experts[e](refined)
                refined = refined + self.expert_out_proj(expert_out)
            h = refined
        return h
```

## 需要同步改的地方

1. **导出脚本的 trace/convert**（`export_multi_split.py` 第 220–225 行）：

   ```python
   chunk_ex = torch.jit.trace(chunk_model, (torch.rand(1, FUSED_DIM),
                                            torch.rand(1, FUSED_DIM)))
   chunk_ml = ct.convert(chunk_ex,
       inputs=[ct.TensorType(name="fused", shape=(1, FUSED_DIM), dtype=np.float32),
               ct.TensorType(name="h",     shape=(1, FUSED_DIM), dtype=np.float32)],
       outputs=[ct.TensorType(name="refined", dtype=np.float32)], ...)
   ```

2. **脚本内等价性验证循环**（第 265–267 行）：

   ```python
   fused0 = fused          # 保存原始 fused（tf 输出）
   h = fused
   for i, (s, e) in enumerate(chunks):
       h = _Chunk(m.refiner, s, e).eval()(fused0, h)   # ★ 每块都收到 fused0
   fused = h
   ```

3. **Swift 侧调用契约**：每个 chunk 两个输入
   - `fused` ← **时序融合模型输出的 fused（每个 chunk 都喂同一个）**
   - `h` ← 上一块输出；**第一块 h 初值 = fused**
   - 输出 `refined` → 作为下一块的 h

## 验证证据

`tools/verify_multi_split.py` 用 `_ChunkFixed`（即上述修复）验证：
- PyTorch：seed 0/1/2，最终输出 & chunk 边界（step4/8/12/16/20/24）maxdiff **全为 0**
- CoreML：特征级相对误差 < 4e-4（< 1e-3 阈值；fp16 精度极限）

运行：

```bash
./.venv-yolo26/bin/python3 tools/verify_multi_split.py
```

## 附带发现

- 现版 `_Chunk.__init__` 在 `shared=False`（24 个独立 cell）时 `self.cell=None`，
  forward 会崩。修复版用 `self.cells` + `cells[step-1]` 一并解决。
- CoreML 端用**大尺度随机权重**（如 scale=0.1）验证时，24 步迭代把特征放大
  60×（101 → 6149），fp16 误差被放大，且 `tanh/sigmoid` 输出饱和到 0/1，
  最终标量 maxdiff 会假性达 1.0。**这不是结构不等价**，应看特征级相对误差
  （scale=0.005 时 rel < 4e-4）。真实训练权重不会这么炸，但验证方法上要注意。
