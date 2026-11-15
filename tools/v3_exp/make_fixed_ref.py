#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「固定常量输入」下 INT4 mlpackage 的八路参考 logits，供 Swift 自检对
**编译后 .mlmodelc** 做数值一致性核验（评审 P1-F）。

coremltools 无法读取编译后的 .mlmodelc（无 Manifest），故 mlpackage 与 mlmodelc 的数值
一致性只能在 Swift 运行时里比对：本脚本用 mlpackage 算参考值落 JSON，Swift 自检加载
mlmodelc 用同一固定输入再算一遍，逐路比对。

用法：
  /usr/local/bin/python3.11 tools/v3_exp/make_fixed_ref.py \
    --package /tmp/v3_ckpt/v3_int4_protect_backbone.mlpackage \
    --out models/v3_fixed_input_ref.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OUTPUTS = ["vertical", "horizontal", "handbrake", "brake",
           "super_brake", "ultimate", "confidence", "risk"]
# 固定输入形状（与模型契约一致，batch=1）与填充常量（非全零，避免退化分支）
SHAPES = {
    "image_hi": (1, 3, 3, 224, 384),
    "image_lo": (1, 21, 3, 112, 192),
    "lane": (1, 1, 160, 160),
    "dets": (1, 20, 12),
    "det_mask": (1, 20),
    "vehicle_state": (1, 8),
}
FILL = 0.25


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True)
    ap.add_argument("--out", default="models/v3_fixed_input_ref.json")
    ap.add_argument("--fill", type=float, default=FILL)
    args = ap.parse_args()

    import coremltools as ct
    m = ct.models.MLModel(args.package)
    feed = {k: np.full(shape, args.fill, dtype=np.float16) for k, shape in SHAPES.items()}
    out = m.predict(feed)
    ref = {
        "fill": args.fill,
        "shapes": {k: list(v) for k, v in SHAPES.items()},
        "package": str(args.package),
        "outputs": {name: [float(x) for x in np.asarray(out[name], dtype=np.float32).reshape(-1)]
                    for name in OUTPUTS},
    }
    Path(args.out).write_text(json.dumps(ref, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[ref] 已写 {args.out}（fill={args.fill}）")
    for name in OUTPUTS:
        print(f"   {name}: {ref['outputs'][name]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
