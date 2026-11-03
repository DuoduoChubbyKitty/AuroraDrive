"""Lead 自查：V3 输入尺寸的 ANE 算力预算实测。

目的：在队友设计定稿前，先把「24 帧混合输入到底要花多少 ms」量出来。
因为 yolopx 在 640x640 上实测 10.4ms，而 V3 要处理约 123 万像素（约 3 倍 yolopx），
如果骨干+Transformer 装不进 30ms，整个设计就得推倒重来。

只测推理延迟，不训练、不改任何现役模型文件。
"""
import time
import json
import torch
import torch.nn as nn
import numpy as np
import coremltools as ct

torch.manual_seed(0)

# CoreML 临时产物写到系统临时目录，避免污染仓库
TMP_PREFIX = "/tmp/v3budget"


class RepresentativeBackbone(nn.Module):
    """代表量级的重参数化风格骨干（单分支 3x3，等价于 deploy 态）。

    只用于量延迟，**不是最终设计**。通道配置贴近轻量候选（MobileNetV3-Large
    去头约 2.97M 那一档）：224x384 经 4 次 stride2 降到 14x24。
    """

    def __init__(self, widths=(24, 48, 96, 192)):
        super().__init__()
        c0, c1, c2, c3 = widths

        def blk(cin, cout, stride):
            return nn.Sequential(
                nn.Conv2d(cin, cout, 3, stride, 1, bias=False),
                nn.BatchNorm2d(cout),
                nn.ReLU(inplace=True),
            )

        self.net = nn.Sequential(
            blk(3, c0, 2), blk(c0, c0, 2),
            blk(c0, c1, 2),
            blk(c1, c1, 1),
            blk(c1, c2, 2),
            blk(c2, c2, 1),
            blk(c2, c3, 2),
            blk(c3, c3, 1),
        )

    def forward(self, x):
        return self.net(x)


def count_params(module):
    return sum(p.numel() for p in module.parameters())


def measure_one(name, batch, height, width):
    """构造 -> 导出 CoreML -> 实测延迟。返回结果字典。"""
    model = RepresentativeBackbone().eval()
    dummy = torch.randn(batch, 3, height, width)
    n_params = count_params(model)

    with torch.no_grad():
        out_shape = list(model(dummy).shape)

    try:
        with torch.no_grad():
            traced = torch.jit.trace(model, dummy)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="x", shape=dummy.shape)],
            compute_units=ct.ComputeUnit.ALL,
            minimum_deployment_target=ct.target.macOS13,
        )
        mlmodel.save(f"{TMP_PREFIX}_{batch}_{height}x{width}.mlpackage")

        feed = {"x": dummy.numpy().astype(np.float32)}
        for _ in range(3):  # 预热，避免首次编译/加载计入
            mlmodel.predict(feed)

        repeats = 20
        t0 = time.perf_counter()
        for _ in range(repeats):
            mlmodel.predict(feed)
        elapsed_ms = (time.perf_counter() - t0) / repeats * 1000

        print(f"  {name:22s} 参数{n_params/1e6:5.2f}M  输出{str(out_shape):22s}  {elapsed_ms:7.2f} ms")
        return {"params": n_params, "ms": round(elapsed_ms, 2), "out": out_shape}

    except Exception as exc:  # 导出/推理失败必须如实记录，不能吞掉
        print(f"  {name:22s} 参数{n_params/1e6:5.2f}M  ✗ 失败: {type(exc).__name__}: {str(exc)[:90]}")
        return {"params": n_params, "error": f"{type(exc).__name__}: {str(exc)[:200]}"}


def main():
    cases = [
        ("高清单帧 224x384", 1, 224, 384),
        ("高清3帧 224x384", 3, 224, 384),
        ("低清单帧 112x192", 1, 112, 192),
        ("低清21帧 112x192", 21, 112, 192),
    ]

    print("=" * 78)
    print("V3 输入尺寸 ANE 延迟实测（骨干为代表性量级，非最终设计）")
    print("=" * 78)

    results = {name: measure_one(name, b, h, w) for name, b, h, w in cases}

    print()
    measured = {k: v for k, v in results.items() if "ms" in v}
    if measured:
        total_ms = sum(v["ms"] for v in measured.values())
        print(f"  24 帧混合方案（3高+21低）骨干合计: {total_ms:.2f} ms  ← 仅骨干，不含 Transformer/输出头")
    print()
    print("  参考基准：yolopx 640x640 实测 10.4ms；单帧预算 66.7ms；主模型预算 ≤30ms")

    with open("docs/v3-design/lead-ane-budget.json", "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print("  结果已存 docs/v3-design/lead-ane-budget.json")


if __name__ == "__main__":
    main()
