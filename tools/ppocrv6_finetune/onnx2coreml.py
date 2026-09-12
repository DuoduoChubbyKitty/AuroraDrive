#!/usr/bin/env python3
"""阶段3.2 ONNX → CoreML（显式命名输入输出 + 固定动态维度）"""
import os, sys, numpy as np
import coremltools as ct
import onnx
FT='/Users/dupi/Desktop/自动驾驶系统/tools/ppocrv6_finetune'
ONNX=f'{FT}/models/ppocrv6_tiny_ft.onnx'
OUT=f'{FT}/models'
H, W = 48, 136   # 裁片恒为 51x18，高48时宽 = ceil(51*48/18) = 136，与 ONNX 评测条件一致

if not os.path.exists(ONNX):
    print(f'ONNX 不存在: {ONNX}'); sys.exit(1)

m = onnx.load(ONNX)
print('=== ONNX 规格 ===')
for i in m.graph.input:  print('  输入:', i.name, [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim])
for o in m.graph.output: print('  输出:', o.name, [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim])

print(f'\n=== ONNX → CoreML（固定输入 1x3x{H}x{W}）===')
from onnx2torch import convert as o2t
import torch
torch_model = o2t(ONNX).eval()
dummy = torch.randn(1, 3, H, W)
with torch.no_grad(): out = torch_model(dummy)
print('  输出 shape:', tuple(out.shape) if hasattr(out,'shape') else type(out))

class Wrap(torch.nn.Module):
    def __init__(self, mo): super().__init__(); self.mo = mo
    def forward(self, x):
        y = self.mo(x)
        return y[0] if isinstance(y, (list, tuple)) else y

wrapped = Wrap(torch_model).eval()
traced = torch.jit.trace(wrapped, dummy)
mlm = ct.convert(traced,
    inputs=[ct.TensorType(name='image', shape=(1,3,H,W))],
    outputs=[ct.TensorType(name='logits')],
    convert_to='mlprogram', minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16)
pkg=f'{OUT}/ppocrv6_tiny_ft.mlpackage'
mlm.save(pkg)
sp=mlm.get_spec()
print(f'  ✅ {pkg}')
print(f'  输入: {[i.name for i in sp.description.input]}  输出: {[o.name for o in sp.description.output]}')
sz=sum(os.path.getsize(os.path.join(r,f)) for r,_,fs in os.walk(pkg) for f in fs)/1048576
print(f'  体积: {sz:.2f} MB')

# 量化对比
from coremltools.optimize.coreml import (OptimizationConfig, OpLinearQuantizerConfig,
                                         linear_quantize_weights, OpPalettizerConfig, palettize_weights)
print(f'\n=== 量化 ===')
for label,cfg,fn,nm in [
  ('int8 线性', OptimizationConfig(global_config=OpLinearQuantizerConfig(mode='linear_symmetric', dtype='int8')), linear_quantize_weights, 'ppocrv6_tiny_ft_int8.mlpackage'),
  ('6-bit 调色板', OptimizationConfig(global_config=OpPalettizerConfig(mode='kmeans', nbits=6)), palettize_weights, 'ppocrv6_tiny_ft_pal6.mlpackage'),
  ('4-bit 调色板', OptimizationConfig(global_config=OpPalettizerConfig(mode='kmeans', nbits=4)), palettize_weights, 'ppocrv6_tiny_ft_pal4.mlpackage'),
]:
    try:
        p=f'{OUT}/{nm}'; fn(mlm, config=cfg).save(p)
        s=sum(os.path.getsize(os.path.join(r,f)) for r,_,fs in os.walk(p) for f in fs)/1048576
        print(f'  ✅ {label:12s} {s:6.2f} MB  → {nm}')
    except Exception as e:
        print(f'  ❌ {label:12s} {type(e).__name__}: {str(e)[:50]}')
