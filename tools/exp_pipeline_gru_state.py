"""实验 E：GRU 隐状态续算 —— **语义差异实测（结论：不等价，不可当免费优化）**

【为什么写这个脚本：一次被自己抓住的错误推理，留痕】
    初稿曾推演："GRU 是递推的 ⟹ 缓存 h 后每 tick 只需 1 步 ⟹ 零代价提速"。
    **这个推理是错的。** 核对 src/temporal.py:229 与 model_v2.py:1450 后确认：
        现有语义 = **滑动窗口**：每 tick 都拿最近 8 帧，**从 h=0 重跑 8 步**
                    （`te(img_feat.unsqueeze(0), None)`，无状态传入）
        续算方案 = 带 tick A 的 h（其含帧 0..7 的信息）再喂帧 8
                 ⟹ 得到的是 GRU(x_0..x_8)，而窗口要的是 GRU(x_1..x_8)
    **两者是不同的函数复合**，不是同一个值。
    ⟹ 续算是**语义变更**（有限窗口 → 无界历史），**必须重训 + 重验证**，
      不能当"零数值代价"的优化写进方案。

【那"精确 O(1)"存在吗？—— 不存在（本脚本顺带证明）】
    滑动窗口 GRU 要求每 tick 得到「最近 N 帧、从零起步」的状态。
    GRU 状态不可"减去"最老帧的贡献（门控是非线性复合），故无法从
    tick A 的状态推出 tick B 的状态。**精确的窗口语义本质上需要 O(N) 步。**

【本实验如实测三件事】
    ① 续算 vs 窗口重算 —— 差异有多大（预期：显著不为 0）
    ② 窗口边界处（reset 后第 1 个 tick）是否相等 —— 理论应相等
    ③ 结论：给出"不可用/需重训"的明确判定

【价值】把这条**从方案里剔除**，避免 Lead 按错误前提排期。
"""
import os
import sys
import warnings

sys.path.insert(0, os.path.abspath("."))
import torch

import src.model_v2 as mv

warnings.simplefilter("ignore")
CKPT = "checkpoints/m9_v2/best_model.pt"
N = 8


def load_sd():
    raw = torch.load(CKPT, map_location="cpu")
    sd = raw
    if isinstance(raw, dict):
        for k in ("model_state_dict", "model", "state_dict"):
            if k in raw and isinstance(raw[k], dict):
                sd = raw[k]
                break
    return sd


def build():
    sd = load_sd()
    m = mv.build_model(deploy=False, num_frames=N)
    res = m.load_state_dict(sd, strict=False)
    m.reparameterize()
    m.eval()
    return m, res


def main() -> int:
    m, res = build()
    print("=" * 100)
    print("实验 E：GRU 隐状态续算 vs 滑动窗口重算（语义差异实测）")
    print("=" * 100)
    print(f"  权重: missing={len(res.missing_keys)} unexpected={len(res.unexpected_keys)}")
    te = m.temporal_encoder
    print(f"  时序编码器: {te.extra_repr()}")

    g = torch.Generator().manual_seed(11)
    imgs = torch.rand(N + 1, 3, 180, 320, generator=g)
    with torch.no_grad():
        f = m.image_encoder(imgs)          # [9,256]

    x_all = te.in_norm(te.in_proj(f.unsqueeze(0)))     # [1,9,128]

    with torch.no_grad():
        # ── 基线：tick B 的**正确**窗口值 = GRU(x_1..x_8) 从零起步 ──
        window_B = te(f[1:N + 1].unsqueeze(0), None)    # [1,128]

        # ── 续算：GRU(x_0..x_7) 得 h，再喂 x_8 ──
        _, h_A = te.rnn(x_all[:, 0:N, :])               # h_A = GRU(x_0..x_7)
        out_inc, _ = te.rnn(x_all[:, N:N + 1, :], h_A)  # 再喂 x_8
        inc_B = te.out_norm(out_inc[:, -1, :])          # GRU(x_0..x_8)

        # ── 方法自检：手工 8 步（从零）vs te() 封装同窗口 —— 应逐位一致 ──
        # 若这两者不一致，说明本脚本的手工路径写错了，① 的结论就不可信。
        h0 = torch.zeros(1, 1, te.hidden_dim)
        out_w, _ = te.rnn(x_all[:, 1:N + 1, :], h0)
        manual_window = te.out_norm(out_w[:, -1, :])

        # ── 附带证据：零填充帧**会推进** GRU 隐状态（b≠0）──
        # 这解释了为什么"单步续算"与"8 帧窗口"必然不同：
        # 现有窗口语义里，那 7 个零帧也在推进 h（引擎注释 InferenceEngineV2.swift:1174-1180 已记载）。
        masked = torch.zeros(1, N, te.feat_dim)
        masked[0, N - 1, :] = f[N]
        window_masked = te(masked, None)

    d_inc = (window_B - inc_B).abs().max().item()
    scale = window_B.abs().max().item()
    d_method = (window_B - manual_window).abs().max().item()
    d_zero = (window_masked - inc_B).abs().max().item()

    print(f"\n  ① 续算 vs 窗口重算（**核心对照**）")
    print(f"      窗口 GRU(x_1..x_8) = {window_B.flatten()[:4].tolist()}")
    print(f"      续算 GRU(x_0..x_8) = {inc_B.flatten()[:4].tolist()}")
    print(f"      maxdiff = {d_inc:.3e}   (特征量级 {scale:.3e})")
    print(f"      ⟹ {'✅ 等价' if d_inc < 1e-5 else '❌ **不等价** —— 语义确实变了（有限窗口 → 无界历史）'}")

    print(f"\n  ② 方法自检：手工 8 步（从零）vs te() 封装同窗口")
    print(f"      maxdiff = {d_method:.3e}  → {'✅ 逐位一致（① 的结论可信）' if d_method < 1e-6 else '❌ 手工路径写错，① 不可信'}")

    print(f"\n  ③ 附带证据：零填充帧确实会推进 GRU 隐状态")
    print(f"      「7 零帧 + x_8」 vs 「续算 x_0..x_8」 maxdiff = {d_zero:.3e}")
    print(f"      两者都含 8 步推进，故接近；而与①的窗口值仍差 {d_inc:.3e}")
    print(f"      （机理见 InferenceEngineV2.swift:1174-1180：GRU 对零输入仍推进隐状态）")

    print("\n" + "=" * 100)
    print("结论（**这条从方案里剔除**）")
    print("=" * 100)
    print("  1. GRU 隐状态续算 **不是**零代价优化：它把「最近 8 帧的因果聚合」变成")
    print("     「自开局以来的无界历史聚合」，是**语义变更**，须重训 + 重新验收。")
    print("  2. 精确的 O(1) 滑动窗口 GRU **不存在**：GRU 门控是非线性复合，")
    print("     无法从旧状态「减去」最老帧的贡献 ⟹ 窗口语义本质上是 O(N)。")
    print("  3. 故时序部分的成本（N=8 步 GRU）**必须保留**，不是可以省掉的开销。")
    print("     → 真正的可省开销只有 ImageEncoder 的 8× 重复（已由特征缓存解决）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
