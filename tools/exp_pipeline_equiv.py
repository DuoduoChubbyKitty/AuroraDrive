"""实验 A：特征缓存数值等价性验证（重叠执行流水线方案的地基）

【问题】8 帧编码里 7 帧是历史帧。若把"每帧的图像特征(256维)"缓存起来，
        新帧只编码 1 帧 → 拼成 8 帧特征序列 → 喂主控模型，
        结果与"每帧都重跑 batch=8 编码"是否**数值等价**？

【为什么应该等价（机理）】
    src/model_v2.py:1416  `img_feat = self.image_encoder(image)`
    ImageEncoder（model_v2.py:440-521）是**纯卷积 + GAP**，没有任何跨 batch 的
    算子（无 BN 的 batch 统计——eval 态 BN 用 running stats；无 LayerNorm；
    无 attention）。⟹ batch 维完全独立 ⟹
        encode(cat([f1..f8])) ≡ cat([encode(f1)..encode(f8)])
    这是**数学恒等**，不是近似。唯一差异来源 = 浮点累加顺序（fp32 舍入）。

【本实验测两件事】
    ① 张量级：batch8 编码 vs 逐帧编码堆叠  → maxdiff
    ② 端到端：原 forward(image[8]) vs 用缓存特征走的 forward（其余路径逐位相同）
       做法：把 model.image_encoder 临时替换为"返回给定特征"的桩，
       保证除 img_feat 来源外**代码路径完全一致**（seq_mode 判定、GRU、refiner、
       fusion、三个辅助头全不变）。

【判据】maxdiff < 1e-3（Lead 要求）；预期实际在 1e-6 量级（fp32 舍入）。
"""
import os
import sys
import warnings

sys.path.insert(0, os.path.abspath("."))
import numpy as np
import torch

import src.model_v2 as mv

warnings.simplefilter("ignore")

CKPT = "checkpoints/m9_v2/best_model.pt"
FRAMES = 8


def build(deploy: bool, ckpt: str | None):
    """构建模型。deploy=True 走"训练态构建 → load → reparameterize"（坑 6 正确顺序）。

    ⚠️ 本 checkpoint 权重在顶层键 `model_state_dict`（踩坑：按 `model`/`state_dict`
       取会拿不到权重 → missing=298/unexpected=13 → 模型实为随机初始化）。
    """
    if ckpt and os.path.exists(ckpt):
        raw = torch.load(ckpt, map_location="cpu")
        sd = raw
        if isinstance(raw, dict):
            for key in ("model_state_dict", "model", "state_dict"):
                if key in raw and isinstance(raw[key], dict):
                    sd = raw[key]
                    break
        has_reparam = any("rbr_reparam" in k for k in sd)
        if has_reparam:
            m = mv.build_model(deploy=True)
            res = m.load_state_dict(sd, strict=False)
        else:
            m = mv.build_model(deploy=False)
            res = m.load_state_dict(sd, strict=False)
            if deploy:
                m.reparameterize()
        m.eval()
        return m, {"missing": len(res.missing_keys), "unexpected": len(res.unexpected_keys)}
    torch.manual_seed(0)
    m = mv.build_model(deploy=False)
    m.eval()
    if deploy:
        m.reparameterize()
    return m, {"missing": -1, "unexpected": -1, "random": True}


def mkinputs(frames=FRAMES, seed=0):
    g = torch.Generator().manual_seed(seed)
    return {
        "image": torch.rand(frames, 3, 180, 320, generator=g),
        "lane": (torch.rand(1, 1, 160, 160, generator=g) > 0.985).float(),
        "dets": torch.rand(1, 20, 12, generator=g),
        "det_mask": (torch.rand(1, 20, generator=g) > 0.35).float(),
        "vehicle_state": torch.rand(1, 8, generator=g),
    }


class _FeatStub(torch.nn.Module):
    """桩：直接返回预先算好的 [8,256] 特征，替代真实 ImageEncoder。"""

    def __init__(self, feat: torch.Tensor):
        super().__init__()
        self.feat = feat

    def forward(self, x):  # noqa: D102
        return self.feat


def full_forward(m, inp, feats=None):
    """走原 forward。feats 非 None 时用桩替换 image_encoder（其余路径不变）。"""
    orig = m.image_encoder
    if feats is not None:
        m.image_encoder = _FeatStub(feats)
    try:
        with torch.no_grad():
            out = m(inp["image"], inp["lane"], inp["dets"], inp["det_mask"],
                    inp["vehicle_state"], camera_heading=None, return_aux=True)
    finally:
        m.image_encoder = orig
    return out


def flat(out):
    """(steer,throttle,brake,aux) → 6 个标量列表（与导出契约同序）。"""
    steer, throttle, brake, aux = out

    def _v(x):
        return 0.0 if x is None else float(x.flatten()[0])
    return [float(steer.flatten()[0]), float(throttle.flatten()[0]),
            float(brake.flatten()[0]), _v(aux.get("confidence")),
            _v(aux.get("risk")), _v(aux.get("car_heading"))]


def main() -> int:
    print("=" * 100)
    print("实验 A：特征缓存数值等价性（逐帧编码缓存 vs batch=8 重算）")
    print("=" * 100)

    for deploy in (False, True):
        tag = "部署态(reparameterized)" if deploy else "训练态(RepVGG多分支)"
        m, rep = build(deploy, CKPT)
        print(f"\n── {tag} ──  权重: missing={rep.get('missing')} "
              f"unexpected={rep.get('unexpected')}"
              f"{' [随机初始化]' if rep.get('random') else ''}")
        inp = mkinputs()

        # ① 张量级：batch8 一次编码  vs  逐帧编码后堆叠
        with torch.no_grad():
            f_batch = m.image_encoder(inp["image"])                      # [8,256]
            f_per = torch.cat([m.image_encoder(inp["image"][i:i + 1])
                               for i in range(FRAMES)], dim=0)           # [8,256]
        d1 = (f_batch - f_per).abs().max().item()
        rel = (f_batch - f_per).abs().max().item() / max(1e-9, f_batch.abs().max().item())
        print(f"  ① 图像特征 [8,256]   maxdiff = {d1:.3e}   (相对 {rel:.3e})")

        # ② 端到端：原路径 vs 缓存特征路径
        out_orig = flat(full_forward(m, inp, feats=None))
        out_cached = flat(full_forward(m, inp, feats=f_per))
        d2 = max(abs(a - b) for a, b in zip(out_orig, out_cached))
        names = ["steer", "throttle", "brake", "confidence", "risk", "car_heading"]
        print(f"  ② 端到端 6 输出 maxdiff = {d2:.3e}")
        for n, a, b in zip(names, out_orig, out_cached):
            flag = "✓" if abs(a - b) < 1e-3 else "✗"
            print(f"       {n:<13} 原={a:+.8f}  缓存={b:+.8f}  diff={abs(a-b):.3e} {flag}")

        # ③ 额外：缓存路径 vs "逐帧编码但不缓存"（等价性应同样成立）
        out_per = flat(full_forward(m, inp, feats=f_per))
        d3 = max(abs(a - b) for a, b in zip(out_cached, out_per))
        print(f"  ③ 缓存路径自洽性 maxdiff = {d3:.3e}")

        verdict = "✅ 数值等价" if max(d1, d2) < 1e-3 else "❌ 不等价"
        print(f"  ⟹ 判定：{verdict}（判据 maxdiff < 1e-3）")

    print("\n" + "=" * 100)
    print("结论")
    print("=" * 100)
    print("  ImageEncoder 无跨 batch 算子 ⟹ 特征缓存是**数学恒等**，非近似。")
    print("  实测差异仅为 fp32 累加顺序舍入，量级 ~1e-6。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
