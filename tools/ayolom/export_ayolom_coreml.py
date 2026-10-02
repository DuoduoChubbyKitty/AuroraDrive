#!/usr/bin/env python3
"""A-YOLOM → CoreML 导出（2026-10-02，2026-10-02 二次修订）

目的：把 A-YOLOM(n) 4.43M 参数的三合一模型导成 CoreML，替掉现役
      yolopx(33M 参数) + yolo26s 两个模型。

输出的三个张量（与原模型一致，只是拍平了嵌套结构）：
  det  [1, 5, 8400]      cx,cy,w,h, cls_conf   （YOLOv8 无 obj_conf；YOLOPX 有）
  da   [1, 2, 640, 640]  可行驶区 logits
  ll   [1, 2, 640, 640]  车道线 logits

⚠️ 为什么需要 Wrapper：原模型 forward 返回 list[3]，其中 out[0] 是 tuple(2)
   （第一个是推理输出、第二个是训练用的逐层 list[3]）。这种嵌套 CoreML 无法
   直接表达，故包一层只取推理需要的三个张量。


★★★ 二次修订（2026-10-02）—— 两处必须改，否则 Swift 侧接不上 / 精度不达标
=============================================================================

【修订①】输入类型 TensorType → **ImageType**（不改会直接接不上）

  初版导出用的是：
      inputs=[ct.TensorType(name="image", shape=(1,3,640,640))]
  它要求调用方喂 **MLMultiArray**。但现役 `YolopxEngine.swift` 喂的是：
      MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
  —— **像素缓冲（CVPixelBuffer）**。类型对不上，Swift 侧会加载/推理失败。

  改用与 yolopx **同款**的 ImageType 后：
      · 整条 drawLetterbox / inputBuffer / 像素缓冲链路原样复用，一个字不用动
      · 归一化搬进图内（scale=1/255、bias=[0,0,0]、RGB）
      · A-YOLOM 走 ultralytics 预处理 = 只除 255、无均值方差，故这组参数正确

【修订②】int8 量化方式 linear_quantize_weights → **palette（kmeans 8 位）+ det 头保 fp16**

  本项目**已量产验证**的配方在 `tools/yolopx/exp_quant_palette.py`，
  现役产物 `yolopx3_pal8_detfp.mlmodelc` 就是这套：
      OpPalettizerConfig(mode="kmeans", nbits=8,
                         granularity="per_tensor", group_size=32)
      + det 头消费算子 op_name_configs = mode "none"（保持 fp16）
  理由（该项目历史实测）：det 头对量化最敏感，8 位调色板会把检测召回打下来；
  而 det 头参数量占比小，保 fp16 代价可忽略、收益是检测框不掉。

  ⚠️ op_name_configs 的键必须是**消费该权重的算子名**，不能拿权重张量名当键
     —— 后者会**静默失效**（导出结果与不跳过时逐位相同），这是
     `exp_quant_palette.py:138` 记下的坑。

【模型结构实测（本脚本依赖它）】
  model.46 = Detect   （49 个参数）← det 头，量化时跳过
  model.47 = Segment  （12 个参数）← 可行驶区头
  model.48 = Segment  （12 个参数）← 车道线头
"""
import sys, os, argparse, time, re
import torch
import numpy as np
import coremltools as ct

sys.path.insert(0, "/tmp/A-YOLOM-tmp")

# det 头在模型里的模块序号（实测：model.46 = Detect）。
# 转成 CoreML 后权重名会被重写成下划线形式，形如：
#     model_model_46_cv2_0_2_weight_to_fp16
#     model_model_46_cv3_1_2_weight_to_fp16
#     model_model_46_dfl_conv_weight_to_fp16
# 故用「model_model_46_」做子串匹配。
#
# ⚠️ 一开始本脚本用的是更松的 "_46_"，结果**误命中了 const_46_to_fp16**
#    （一个恰好编号 46 的普通常量，与 det 头无关）—— 假阳性会让
#    op_name_configs 里混进无关算子。收紧成完整前缀后命中数精确。
DET_MARK = "model_model_46_"


class FlatOut(torch.nn.Module):
    """把 A-YOLOM 的嵌套输出拍平成 3 个张量。"""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        out = self.model(x)
        return out[0][0], out[1], out[2]


def all_weight_keys(mlmodel) -> list[str]:
    """列出模型里所有可量化权重的名字（诊断用）。"""
    from coremltools.optimize.coreml import get_weights_metadata
    try:
        md = get_weights_metadata(mlmodel, weight_threshold=1)
        return sorted(md.keys())
    except Exception as e:
        print(f"    ⚠️ get_weights_metadata 失败: {type(e).__name__}: {e}")
        return []


def det_consumer_op_names(mlmodel, det_mark: str) -> list[str]:
    """det 头权重的**消费算子名** —— op_name_configs 真正使用的键。

    ⚠️ 必须用「消费该 const 的 child op 的名字」，用权重张量名会静默失效
       （见文件头修订②的说明）。
    """
    from coremltools.optimize.coreml import get_weights_metadata
    md = get_weights_metadata(mlmodel, weight_threshold=1)
    names: list[str] = []
    hit_w: list[str] = []
    for wk, meta in md.items():
        if det_mark not in wk:
            continue
        hit_w.append(wk)
        for child in getattr(meta, "child_ops", []):
            n = getattr(child, "name", None)
            if n and n not in names:
                names.append(n)
    print(f"    det 头权重命中 {len(hit_w)} 个张量，推出 {len(names)} 个消费算子")
    for w in hit_w[:3]:
        print(f"      权重样例 {w}")
    for n in names[:3]:
        print(f"      算子样例 {n}")
    return sorted(names)


def quantize_palette_int8(mlmodel, det_mark: str):
    """palette 8 位（kmeans）+ det 头跳过 —— 照抄 yolopx3_pal8_detfp 配方。"""
    from coremltools.optimize.coreml import (
        OpPalettizerConfig, OptimizationConfig, palettize_weights,
    )

    op_names = det_consumer_op_names(mlmodel, det_mark)
    if not op_names:
        raise RuntimeError(
            f"det 头算子一个都没匹配到（标记 {det_mark!r}）—— "
            f"拒绝在「det 头没跳过」的情况下量化，否则检测召回会被打下来。"
        )

    global_cfg = OpPalettizerConfig(
        mode="kmeans",
        nbits=8,
        granularity="per_tensor",
        group_size=32,
    )
    # ⚠️ 跳过压缩的写法是**值给 None**，不是 `OpPalettizerConfig(mode="none")`
    #    —— 后者会抛 ValueError（`OpPalettizerConfig.check_mode` 只认
    #    KMEANS/UNIFORM/UNIQUE/CUSTOM）。此写法与 yolopx 的
    #    export_yolopx_detfp.py:174 逐字一致。
    cfg = OptimizationConfig(
        global_config=global_cfg,
        op_name_configs={op: None for op in op_names},
    )
    return palettize_weights(mlmodel, cfg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="models/ayolom/v4.pt")
    ap.add_argument("--out", default="models/ayolom/ayolom_n_fp16.mlpackage")
    ap.add_argument("--size", type=int, default=640)
    ap.add_argument("--quantize", default="fp16", choices=["fp16", "int8", "int8-linear"])
    ap.add_argument("--det-mark", default=DET_MARK,
                    help="det 头权重名子串标记（默认 _46_，对应 model.46 = Detect）")
    ap.add_argument("--list-weights", action="store_true",
                    help="只转换并打印全部权重名，不做量化（诊断用）")
    args = ap.parse_args()

    ck = torch.load(args.weights, map_location="cpu", weights_only=False)
    model = ck["model"].float().eval()
    n_par = sum(p.numel() for p in model.parameters())
    print(f"[1] 载入 {args.weights}  {n_par/1e6:.2f}M 参数")

    wrapped = FlatOut(model).eval()
    dummy = torch.rand(1, 3, args.size, args.size)

    with torch.no_grad():
        ref = wrapped(dummy)
    print(f"[2] 前向 OK  det{tuple(ref[0].shape)} da{tuple(ref[1].shape)} ll{tuple(ref[2].shape)}")

    print("[3] TorchScript trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, dummy, strict=False)

    print("[4] coremltools convert（可能较慢）...")
    t0 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image",
                             shape=(1, 3, args.size, args.size),
                             scale=1 / 255.0,
                             bias=[0, 0, 0],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[
            ct.TensorType(name="det"),
            ct.TensorType(name="da"),
            ct.TensorType(name="ll"),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    print(f"    转换耗时 {time.time()-t0:.1f}s")

    # ── 诊断：权重名总览 ──
    keys = all_weight_keys(mlmodel)
    if keys:
        det_keys = [k for k in keys if args.det_mark in k]
        print(f"[5] 权重张量共 {len(keys)} 个；其中含 {args.det_mark!r} 的 {len(det_keys)} 个")
        if args.list_weights:
            for k in keys:
                flag = " ← det" if args.det_mark in k else ""
                print(f"      {k}{flag}")
            return

    if args.quantize == "int8":
        print("[6] palette 8 位量化（kmeans）+ det 头保 fp16 ...")
        mlmodel = quantize_palette_int8(mlmodel, args.det_mark)
    elif args.quantize == "int8-linear":
        # 旧路线，留作对照（历史结论：det 召回掉、da/ll IoU 不达标）
        print("[6] 线性 int8 量化（对照路线，不推荐）...")
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
        )
        cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric"))
        mlmodel = linear_quantize_weights(mlmodel, cfg)
    else:
        print("[6] 保持 fp16（不量化）")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    mlmodel.save(args.out)
    sz = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, fs in os.walk(args.out) for f in fs
    )
    print(f"[7] 已保存 {args.out}  ({sz/1024/1024:.1f} MB)")
    print(f"    参数量 {n_par/1e6:.2f}M")
    print(f"    输入 image (ImageType, RGB, scale=1/255)  输出 det/da/ll")


if __name__ == "__main__":
    main()
