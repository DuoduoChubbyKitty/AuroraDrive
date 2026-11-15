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


def _build_real_input(bin_dir: Path):
    """用真实验证帧（清洗分片重建后第一个样本）作为固定输入，存每路 float16 原始字节。"""
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "v3_exp"))
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
    import export_v3_checkpoint_int4 as E  # 复用分片重建，确保输入是真实且可复现的
    np_inp, _, meta = E.build_calib_inputs(1, seed=7, use_val_clips=True,
                                           ckpt_path=Path(__file__).resolve().parents[2] / "models" / "aurora_v3_best_ep13_20261115.pt")
    if np_inp is None:
        raise RuntimeError("真实输入构建失败")
    bin_dir.mkdir(parents=True, exist_ok=True)
    feed = {}
    for k in SHAPES:
        arr = np.ascontiguousarray(np_inp[k].astype(np.float16))
        (bin_dir / f"{k}.bin").write_bytes(arr.tobytes())
        feed[k] = arr
    return feed, meta


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True)
    ap.add_argument("--out", default="models/v3_fixed_input_ref.json")
    ap.add_argument("--fill", type=float, default=FILL)
    ap.add_argument("--real", action="store_true", help="用真实验证帧作固定输入（推荐，后端稳定）")
    ap.add_argument("--bin-dir", default="models/v3_fixed_input")
    args = ap.parse_args()

    import coremltools as ct
    m = ct.models.MLModel(args.package)
    if args.real:
        feed, meta = _build_real_input(Path(args.bin_dir))
        shapes = {k: list(v.shape) for k, v in feed.items()}
        src = {"mode": "real", "sample": meta.get("per_sample", [{}])[0],
               "data_sha256": meta.get("data_sha256", ""), "bin_dir": str(args.bin_dir)}
    else:
        feed = {k: np.full(shape, args.fill, dtype=np.float16) for k, shape in SHAPES.items()}
        shapes = {k: list(v) for k, v in SHAPES.items()}
        src = {"mode": "constant", "fill": args.fill}
    out = m.predict(feed)

    # —— 校验 --package 与部署 modelc 是同一模型（权重+model.mil 内容一致），否则拒绝生成参考 ——
    import hashlib as _hl
    pkg_dir = Path(args.package)
    def _sha_files(base: Path, names):
        h = _hl.sha256()
        for nm in names:
            fp = base / nm
            if not fp.is_file():
                return None
            h.update(nm.encode()); h.update(fp.read_bytes())
        return h.hexdigest()
    dep_dir = Path(__file__).resolve().parents[2] / "models" / "v3_int4.mlmodelc"
    pkg_wm = _sha_files(pkg_dir / "Data" / "com.apple.CoreML" / "weights", ["weight.bin"])
    dep_wm = _sha_files(dep_dir / "weights", ["weight.bin"])
    # 计算图一致性：package 存的是 model.mlmodel（protobuf），部署是编译后的 model.mil。
    # 二者不可直接比——必须把 package **编译到临时目录**，再比对编译产物的 weight.bin + model.mil
    # 与部署 modelc 逐字节一致（评审 R4 P1#3：旧代码查 model.mil 取不到→跳过图比较）。
    import subprocess, tempfile, shutil
    pkg_mil_h = None
    _stage = Path(tempfile.mkdtemp(prefix="ref_cmp_"))
    try:
        r = subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg_dir), str(_stage)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"[ref] ❌ 无法编译 --package 做图一致性校验：{r.stderr.strip()[:200]}")
        cands = list(_stage.glob("*.mlmodelc"))
        if not cands:
            raise SystemExit("[ref] ❌ 编译 --package 未产出 .mlmodelc，无法校验计算图")
        built = cands[0]
        built_wm = _sha_files(built / "weights", ["weight.bin"])
        built_mil = built / "model.mil"
        pkg_mil_h = _hl.sha256(built_mil.read_bytes()).hexdigest() if built_mil.is_file() else None
    finally:
        shutil.rmtree(_stage, ignore_errors=True)
    dep_mil_h = _hl.sha256((dep_dir / "model.mil").read_bytes()).hexdigest() if (dep_dir / "model.mil").is_file() else None
    if not (pkg_wm and dep_wm):
        raise SystemExit("[ref] ❌ 无法计算权重哈希（package 或部署 modelc 缺 weight.bin），拒绝生成参考")
    if pkg_wm != dep_wm:
        raise SystemExit(f"[ref] ❌ --package 权重({pkg_wm[:12]}) 与部署 modelc({dep_wm[:12]}) 不一致，拒绝生成参考")
    if not (pkg_mil_h and dep_mil_h):
        raise SystemExit("[ref] ❌ 无法计算计算图哈希，拒绝生成参考（不允许跳过图比较）")
    if pkg_mil_h != dep_mil_h:
        raise SystemExit("[ref] ❌ --package 编译图与部署 modelc 的 model.mil 不一致（异图包），拒绝生成参考")
    # 输入字节哈希
    inp_hash = ""
    try:
        ih = _hl.sha256()
        for k in sorted(feed.keys()):
            ih.update(k.encode()); ih.update(np.ascontiguousarray(feed[k].astype(np.float16)).tobytes())
        inp_hash = ih.hexdigest()
    except Exception:
        pass

    # 绑定部署 modelc 内容指纹（T15 会重新计算并比对，确保参考对应的是当前部署产物）
    dep_sha = ""
    try:
        import sys as _sys
        _sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "v3_exp"))
        import export_v3_checkpoint_int4 as _E
        dep = Path(__file__).resolve().parents[2] / "models" / "v3_int4.mlmodelc"
        if dep.is_dir():
            dep_sha = _E.modelc_content_sha(dep)
    except Exception as _exc:
        print(f"[ref] ⚠ 无法计算部署 modelc 指纹：{_exc}")
    ref = {
        "deployed_modelc_content_sha": dep_sha,
        "package_weight_sha": pkg_wm,
        "package_model_mil_sha": pkg_mil_h,
        "input_bytes_sha256": inp_hash,
        "source": src,
        "shapes": shapes,
        "package": str(args.package),
        "outputs": {name: [float(x) for x in np.asarray(out[name], dtype=np.float32).reshape(-1)]
                    for name in OUTPUTS},
    }
    Path(args.out).write_text(json.dumps(ref, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[ref] 已写 {args.out}（source={src['mode']}）")
    for name in OUTPUTS:
        print(f"   {name}: {ref['outputs'][name]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
