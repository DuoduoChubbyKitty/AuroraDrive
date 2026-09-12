#!/usr/bin/env python3
"""ONNX 微调模型全量评测（冻结测试集 val.txt = clip_20260827_204437, 5077 张）。

复现训练期 eval 的准确率，验证 Paddle→ONNX 转换数值等价。
输出：总体准确率 + 错误样本清单 + 置信度分布（用于重校准阈值）。
"""
import sys, os, json
import numpy as np
import cv2
import onnxruntime as ort

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
DS = f"{ROOT}/tools/ppocrv6_finetune/dataset"
ONNX = f"{ROOT}/tools/ppocrv6_finetune/output/v6tiny_ft_infer/v6tiny_ft.onnx"

# ---- 字典（与训练/官方 CTCLabelDecode 完全一致：只 strip 换行，不过滤空白字符）----
# 官方逻辑: character = ["blank"] + dict_lines + [" "]
# 注意 dict.txt 第 617 行是全角空格 U+3000，是合法 token，绝不能被 strip 过滤
with open(f"{DS}/dict.txt", "rb") as f:
    dict_lines = [l.decode("utf-8").strip("\n").strip("\r\n") for l in f]
assert len(dict_lines) == 6904, len(dict_lines)
idx2char = ["blank"] + dict_lines + [" "]  # 6906

IMGH = 48

def preprocess(path):
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    assert img is not None, path
    h, w = img.shape[:2]
    ratio = w / h
    rw = max(1, int(np.ceil(IMGH * ratio)))
    img = cv2.resize(img, (rw, IMGH))
    img = img.astype(np.float32).transpose(2, 0, 1)  # CHW
    img = (img / 255.0 - 0.5) / 0.5  # 归一化
    return img[np.newaxis]  # [1,3,48,W]

def ctc_decode(logits):
    """标准 CTC 解码：argmax → 去 blank → 折叠重复。返回 (text, mean_conf)。"""
    pred = logits.argmax(axis=-1)  # [T]
    conf = logits.max(axis=-1)
    chars_out, confs = [], []
    prev = -1
    for t, idx in enumerate(pred):
        if idx != 0 and idx != prev:
            chars_out.append(idx2char[idx] if idx < len(idx2char) else "?")
            confs.append(float(conf[t]))
        prev = idx
    text = "".join(chars_out)
    c = float(np.mean(confs)) if confs else 0.0
    return text, c

def extract_speed(text):
    """项目解码规则：取数字串最后 3 位，左补零；<2 位无效。"""
    digits = "".join(ch for ch in text if ch.isdigit())
    if len(digits) < 2:
        return None
    return digits[-3:].zfill(3)

def main():
    sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
    iname = sess.get_inputs()[0].name

    lines = open(f"{DS}/val.txt", encoding="utf-8").read().splitlines()
    print(f"测试样本: {len(lines)}")

    n_ok = n_err = 0
    errors = []
    confs_all = []
    for i, line in enumerate(lines):
        rel, label = line.split("\t")
        path = os.path.join(DS, rel)
        x = preprocess(path)
        logits = sess.run(None, {iname: x})[0][0]  # [T, 6906]
        text, conf = ctc_decode(logits)
        pred = extract_speed(text)
        confs_all.append(conf)
        if pred == label:
            n_ok += 1
        else:
            n_err += 1
            errors.append({"file": os.path.basename(rel), "label": label,
                           "raw": text, "pred": pred, "conf": round(conf, 4)})
        if (i + 1) % 1000 == 0:
            print(f"  {i+1}/{len(lines)} acc={n_ok/(i+1)*100:.4f}%")

    acc = n_ok / len(lines) * 100
    print(f"\n=== ONNX 全量评测 ===")
    print(f"准确率: {n_ok}/{len(lines)} = {acc:.4f}%")
    print(f"置信度: min={min(confs_all):.4f} p1={np.percentile(confs_all,1):.4f} "
          f"p5={np.percentile(confs_all,5):.4f} median={np.median(confs_all):.4f}")
    print(f"错误 {len(errors)} 条:")
    for e in errors:
        print(f"  {e}")
    with open(f"{ROOT}/tools/ppocrv6_finetune/eval_onnx_result.json", "w") as f:
        json.dump({"acc": acc, "n_ok": n_ok, "n_total": len(lines),
                   "errors": errors,
                   "conf_p1": float(np.percentile(confs_all,1)),
                   "conf_p5": float(np.percentile(confs_all,5)),
                   "conf_median": float(np.median(confs_all))}, f, ensure_ascii=False, indent=2)
    print("已保存 eval_onnx_result.json")

if __name__ == "__main__":
    main()
