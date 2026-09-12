#!/usr/bin/env python3
"""CoreML 四档量化模型全量评测（5077 张冻结测试集）+ 推理延迟。

验证 fp16/int8/pal6/pal4 量化是否保精度，并测单帧延迟。
"""
import os, json, time
import numpy as np
import cv2
import coremltools as ct

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
DS = f"{ROOT}/tools/ppocrv6_finetune/dataset"
MD = f"{ROOT}/tools/ppocrv6_finetune/models"

with open(f"{DS}/dict.txt", "rb") as f:
    dict_lines = [l.decode("utf-8").strip("\n").strip("\r\n") for l in f]
idx2char = ["blank"] + dict_lines + [" "]
assert len(idx2char) == 6906

lines = open(f"{DS}/val.txt", encoding="utf-8").read().splitlines()

def preprocess(path):
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    h, w = img.shape[:2]
    rw = max(1, int(np.ceil(48 * w / h)))
    img = cv2.resize(img, (rw, 48)).astype(np.float32).transpose(2, 0, 1)
    return ((img / 255.0 - 0.5) / 0.5)[np.newaxis]  # [1,3,48,136] NCHW

def ctc_extract_speed(logits):
    pred = logits.argmax(axis=-1)
    chars_out = []
    prev = -1
    for idx in pred:
        if idx != 0 and idx != prev:
            chars_out.append(idx2char[idx] if idx < len(idx2char) else "?")
        prev = idx
    digits = "".join(ch for ch in "".join(chars_out) if ch.isdigit())
    if len(digits) < 2:
        return None
    return digits[-3:].zfill(3)

MODELS = ["ppocrv6_tiny_ft", "ppocrv6_tiny_ft_int8", "ppocrv6_tiny_ft_pal6", "ppocrv6_tiny_ft_pal4"]

results = {}
for name in MODELS:
    pkg = f"{MD}/{name}.mlpackage"
    print(f"\n=== {name} ===")
    model = ct.models.MLModel(pkg)
    # 预热
    _ = model.predict({"image": preprocess(os.path.join(DS, lines[0].split("\t")[0]))})

    t0 = time.perf_counter()
    n_ok = 0
    errors = []
    for i, line in enumerate(lines):
        rel, label = line.split("\t")
        out = model.predict({"image": preprocess(os.path.join(DS, rel))})
        logits = out["logits"][0]  # [T, 6906]
        pred = ctc_extract_speed(logits)
        if pred == label:
            n_ok += 1
        elif len(errors) < 5:
            errors.append({"file": os.path.basename(rel), "label": label, "pred": pred})
    dt = time.perf_counter() - t0
    acc = n_ok / len(lines) * 100
    per_img = dt / len(lines) * 1000
    results[name] = {"acc": acc, "n_ok": n_ok, "per_img_ms": round(per_img, 3), "errors": errors}
    print(f"  acc: {n_ok}/{len(lines)} = {acc:.4f}%   {per_img:.2f} ms/img")
    for e in errors:
        print(f"  错例: {e}")

print("\n=== 汇总 ===")
for name, r in results.items():
    print(f"{name:26s} {r['acc']:8.4f}%  {r['per_img_ms']:7.3f} ms/img")
with open(f"{ROOT}/tools/ppocrv6_finetune/eval_coreml_result.json", "w") as f:
    json.dump(results, f, ensure_ascii=False, indent=2)
print("已保存 eval_coreml_result.json")
