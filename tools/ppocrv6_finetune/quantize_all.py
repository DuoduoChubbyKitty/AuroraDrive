#!/usr/bin/env python3
"""对模型做 int8 线性量化 + 数值一致性验证。

用法: python quantize_all.py <model1> <model2> ...
输入: models/<name>.mlpackage
输出: models/<name>_int8.mlpackage  + 数值差异报告
"""
import sys, os, json
import numpy as np
import coremltools as ct
from coremltools.optimize.coreml import (
    OptimizationConfig, OpLinearQuantizerConfig, linear_quantize_weights)

ROOT = "/Users/dupi/Desktop/自动驾驶系统/models"

def pkg_size(p):
    return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs) / 1048576

def make_inputs(model, n=4, seed=0):
    """按模型输入规格造输入样本"""
    rng = np.random.default_rng(seed)
    spec = model.get_spec()
    samples = {}
    for i in spec.description.input:
        name = i.name
        if i.type.HasField("multiArrayType"):
            shape = [int(d) for d in i.type.multiArrayType.shape]
            dt = i.type.multiArrayType.dataType
            if dt == 65600:      # int32
                arr = rng.integers(0, 2, size=shape).astype(np.int32)
            else:
                arr = rng.random(shape, dtype=np.float32) * 2 - 1   # [-1,1] 覆盖归一化输入域
            samples[name] = arr
        elif i.type.HasField("imageType"):
            w = int(i.type.imageType.width); h = int(i.type.imageType.height)
            # CoreML image 输入接受 PIL/numpy(HWC)；用 numpy float 需转 PIL
            from PIL import Image
            arr = (rng.random((h, w, 3)) * 255).astype(np.uint8)
            samples[name] = Image.fromarray(arr)
    return samples

def outputs_of(model, samples):
    out = model.predict(dict(samples))
    return {k: np.array(v).astype(np.float64) for k, v in out.items()}

def compare(a, b):
    """返回 (max_abs_diff, 平均相对误差, 是否 argmax 全一致)"""
    maxd, rels, argmax_same = 0.0, [], True
    for k in a:
        if k not in b: continue
        x, y = a[k], b[k]
        if x.shape != y.shape: return (float('inf'), 1.0, False)
        maxd = max(maxd, float(np.abs(x - y).max()))
        denom = np.maximum(np.abs(x), 1e-6)
        rels.append(float(np.mean(np.abs(x - y) / denom)))
        if x.ndim >= 2 and x.shape[-1] > 1:
            if not np.array_equal(x.argmax(axis=-1), y.argmax(axis=-1)):
                argmax_same = False
    return (maxd, float(np.mean(rels)) if rels else 0.0, argmax_same)

def main(names):
    report = {}
    for name in names:
        src = f"{ROOT}/{name}.mlpackage"
        dst = f"{ROOT}/{name}_int8.mlpackage"
        if not os.path.exists(src):
            print(f"✗ {name}: 源不存在"); continue
        print(f"\n=== {name} ===")
        model = ct.models.MLModel(src)
        base_mb = pkg_size(src)

        # 数值基线（量化前）
        samples = make_inputs(model)
        y_base = outputs_of(model, samples)

        cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8"))
        qmodel = linear_quantize_weights(model, config=cfg)
        if os.path.exists(dst):
            import shutil; shutil.rmtree(dst)
        qmodel.save(dst)
        q_mb = pkg_size(dst)

        # 量化后数值对比
        qm = ct.models.MLModel(dst)
        y_q = outputs_of(qm, samples)
        maxd, rel, amax = compare(y_base, y_q)

        ok = amax and rel < 0.05
        report[name] = {"base_mb": round(base_mb, 2), "int8_mb": round(q_mb, 2),
                        "max_abs_diff": round(maxd, 6), "mean_rel_err": round(rel, 5),
                        "argmax_identical": amax, "verdict": "OK" if ok else "CHECK"}
        print(f"  体积 {base_mb:.1f} → {q_mb:.1f} MB ({q_mb/base_mb*100:.0f}%)")
        print(f"  数值: max|Δ|={maxd:.6f}  平均相对误差={rel*100:.3f}%  argmax一致={amax}")
        print(f"  判定: {'✓ OK' if ok else '⚠ 需检查'}")

    with open("/Users/dupi/Desktop/自动驾驶系统/tools/ppocrv6_finetune/quantize_report.json", "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print("\n=== 汇总 ===")
    for k, v in report.items():
        print(f"{k:26s} {v['base_mb']:6.1f} → {v['int8_mb']:5.1f} MB  rel={v['mean_rel_err']*100:.3f}%  {v['verdict']}")

if __name__ == "__main__":
    main(sys.argv[1:])
