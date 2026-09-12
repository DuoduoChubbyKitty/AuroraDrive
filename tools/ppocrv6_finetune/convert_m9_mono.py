#!/usr/bin/env python3
"""m9_mono.onnx → CoreML mlProgram → int8 线性量化。

与 game_assist_control 同规格（image[1,3,180,320] + vehicle_state[1,6]
→ steer/throttle/brake[1,1]），说明同一训练管线（src/train_game_assist.py）。
"""
import os, shutil
import numpy as np
import coremltools as ct
import torch
from onnx2torch import convert as o2t
from coremltools.optimize.coreml import (
    OptimizationConfig, OpLinearQuantizerConfig, linear_quantize_weights)

ROOT = "/Users/dupi/Desktop/自动驾驶系统/models"
SRC = f"{ROOT}/m9_mono.onnx"
DST_FP = f"{ROOT}/m9_mono_conv.mlpackage"      # 转换后（fp16）
DST_I8 = f"{ROOT}/m9_mono_int8.mlpackage"      # 量化后

def pkg_size(p):
    return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs) / 1048576

print("=== 1. ONNX → torch → CoreML (mlProgram) ===")
tm = o2t(SRC).eval()
H, W = 180, 320
class Wrap(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, image, vehicle_state):
        out = self.m(image, vehicle_state)
        if isinstance(out, (list, tuple)):
            return out[0], out[1], out[2]
        return out
wrapped = Wrap(tm).eval()
ex_img = torch.randn(1, 3, H, W)
ex_st = torch.randn(1, 6)
with torch.no_grad():
    traced = torch.jit.trace(wrapped, (ex_img, ex_st))
print("  trace 完成")

mlm = ct.convert(
    traced,
    inputs=[ct.TensorType(name="image", shape=(1, 3, H, W)),
            ct.TensorType(name="vehicle_state", shape=(1, 6))],
    outputs=[ct.TensorType(name="steer"), ct.TensorType(name="throttle"), ct.TensorType(name="brake")],
    convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16)
if os.path.exists(DST_FP): shutil.rmtree(DST_FP)
mlm.save(DST_FP)
print(f"  转换完成: {pkg_size(DST_FP):.1f} MB")

print("\n=== 2. 数值一致性（ONNX vs 转换后 CoreML）===")
import onnxruntime as ort
sess = ort.InferenceSession(SRC, providers=["CPUExecutionProvider"])
xs_img = np.random.randn(2, 3, H, W).astype(np.float32)
xs_st = np.random.randn(2, 6).astype(np.float32)

onnx_out = sess.run(None, {"image": xs_img, "vehicle_state": xs_st})
ml_out = mlm.predict({"image": xs_img[:1], "vehicle_state": xs_st[:1]})
names = ["steer", "throttle", "brake"]
for i, nm in enumerate(names):
    a = float(np.array(onnx_out[i]).reshape(-1)[0])
    b = float(np.array(ml_out[nm]).reshape(-1)[0])
    print(f"  {nm:9s} ONNX={a:+.5f}  CoreML={b:+.5f}  Δ={abs(a-b):.6f}")

print("\n=== 3. int8 线性量化 ===")
cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(
    mode="linear_symmetric", dtype="int8"))
q = linear_quantize_weights(mlm, config=cfg)
if os.path.exists(DST_I8): shutil.rmtree(DST_I8)
q.save(DST_I8)
print(f"  量化完成: {pkg_size(DST_FP):.1f} → {pkg_size(DST_I8):.1f} MB")

print("\n=== 4. 量化前后数值对比 ===")
qm = ct.models.MLModel(DST_I8)
mo = mlm.predict({"image": xs_img[:1], "vehicle_state": xs_st[:1]})
qo = qm.predict({"image": xs_img[:1], "vehicle_state": xs_st[:1]})
for nm in names:
    a = float(np.array(mo[nm]).reshape(-1)[0])
    b = float(np.array(qo[nm]).reshape(-1)[0])
    print(f"  {nm:9s} fp16={a:+.5f}  int8={b:+.5f}  Δ={abs(a-b):.6f}")
