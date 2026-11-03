#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 视觉骨干 + 多阶段 state-token 主干（结构定义）

============================================================================
论文依据（docs/v3-design/papers/state_aware.txt，arXiv:2310.20650）
============================================================================
  §III   OVERVIEW            —— 多阶段层级：粗（stop/go）→ 细（steer/throttle/brake）
  §IV.A  State Token Propagation —— stage i 的 state token 输出作为 stage i+1 的输入
  §IV.B  Pixel-State Attention   —— 视觉 patch 与 state token 同场做 self-attention
  §IV.C  Command Coherency Module—— 训练期正则：由 t 时刻控制量回归 t+1 速度
  §IV.D  Architecture and Training —— 原始逐层参数（见下）

论文原始骨干（§IV.D，:216-224）：
    5 层卷积，24/36/48 个 5×5 kernel stride2，然后 2 层 64 个 3×3 kernel stride1，
    ELU 激活；输入 200×88 → 特征图 4×18×64 → N=72 个 visual token，D=64。

⚠️ 一个必须写进报告的核对结果：
    §IV.D 的文字「5 层…前 3 层 stride 2」如果配 SAME padding，88×200 只能得到
    11×25，**推不出原文声称的 4×18**。只有 **valid padding（不补边）** 才是
    88×200 --(k5,s2)×3--> 10×24 --(k3,s1)×2--> 4×18。本文件按 valid 语义复现，
    见 tools/v3_exp/measure_backbone_v3.py 的实测。

============================================================================
V3 的三处结构决策（详见 01-backbone.md §2）
============================================================================
1. 下采样 4 次 stride-2：224/16=14、384/16=24 → **14×24 = 336 token**（整除，
   无 ceil 畸形尺寸）。不照搬论文的 5 次（224/32=7、384/32=12 → 7×12=84 token，
   对 384 宽的驾驶画面太粗）。
2. 骨干换成 RepVGG 重参数化块（复用 src/model_v2.py:298 已验证的折叠实现）：
   训练三分支 → deploy 折叠成单个 3×3 Conv+bias，推理图无分支、ANE 友好。
3. 主干保留论文精髓：state token 作为 CLS 同场参与 pixel-state attention，
   并在 stage 之间**只传递 state token**（论文 §IV.A 原文："taking the output of
   the encoder corresponding to the state token and propagating it as the new
   state token"）。

============================================================================
shape 契约（B = batch）
============================================================================
    image   [B, 3, 224, 384]  ──RepVGG 骨干 4×stride2──> [B, 256, 14, 24]
                                                             │ flatten+proj
    state   [B, 5]            ──Linear──> [B, 1, D]           │
                                                             ↓
                       tokens = [state_token; 336 visual tokens] + pos_emb
                                                             │
                                    ┌────────────────────────┴────────┐
                                    │ stage1 (depth× TransformerBlock)│
                                    └────────────────┬────────────────┘
                                                     ├──> stop/go  [B, 3]
                                    ┌────────────────┴────────────────┐
                                    │ state token 传递 → stage2        │
                                    └────────────────┬────────────────┘
                                                     └──> steer/throttle/brake [B, 3]
    （训练期额外）CCM: [steer,throttle,brake,speed] → 预测 t+1 speed，用作正则
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import List, Tuple

import torch
import torch.nn as nn

# 复用仓库已验证的重参数化块（三分支 → 单 3×3），不另写一套折叠逻辑，
# 避免两份实现产生数值分歧。见 src/model_v2.py:298 RepVGGBlock / :417 RepVGGStage。
from src.model_v2 import RepVGGBlock, RepVGGStage


# ═══════════════════════════════════════════════════════════════════════════
# 1. 配置
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class BackboneConfig:
    """V3 骨干 + 主干配置。

    默认值即 01-backbone.md §4 推荐方案（D=192）。其它候选通过覆盖字段实测。
    """

    # ── 输入 ──
    image_h: int = 224
    image_w: int = 384
    in_channels: int = 3
    state_dim: int = 5          # speed/steer/throttle/brake/accel

    # ── RepVGG 骨干（4 次 stride-2，通道逐步翻倍）──
    stem_channels: int = 32
    stage_channels: Tuple[int, ...] = (64, 128, 256)
    stage_blocks: Tuple[int, ...] = (2, 3, 4)

    # ── 额外一次 stride-2（仅用于 token 数消融：隔离"token 变少"这一个变量）──
    extra_downsample: bool = False

    # ── Transformer 主干 ──
    dim: int = 192
    depth_per_stage: int = 4
    heads: int = 6              # head_dim = dim/heads = 32
    mlp_ratio: float = 4.0

    # ── 头 ──
    stop_go_dim: int = 3        # 论文 Eq.(2)：红绿灯 / 行人 / 其它车辆 三路 stop 信号

    # ── 训练期正则（CCM，不进部署图）──
    ccm_hidden: int = 64

    def token_grid(self) -> Tuple[int, int]:
        """返回骨干输出特征图的 (H, W)。每层 stride-2 → 各除 2。"""
        stride_total = 2 ** (1 + len(self.stage_channels) + int(self.extra_downsample))
        n_h = self.image_h // stride_total
        n_w = self.image_w // stride_total
        if n_h * stride_total != self.image_h or n_w * stride_total != self.image_w:
            raise ValueError(
                f"输入 {self.image_h}×{self.image_w} 不能被 {stride_total} 整除："
                f"会得到畸形特征图 {self.image_h / stride_total:.1f}×"
                f"{self.image_w / stride_total:.1f}，ANE 上不友好。"
                f"请改用可整除的输入尺寸或调整下采样次数。"
            )
        return n_h, n_w

    def num_visual_tokens(self) -> int:
        n_h, n_w = self.token_grid()
        return n_h * n_w


# ═══════════════════════════════════════════════════════════════════════════
# 2. RepVGG 骨干
# ═══════════════════════════════════════════════════════════════════════════

class RepVGGVisualBackbone(nn.Module):
    """4 次 stride-2 的 RepVGG 风格视觉骨干（训练多分支 / 推理折叠为纯 3×3）。

    分辨率演进（输入 224×384）：
        stem    stride2 →  32ch @ 112×192
        stage0  stride2 →  64ch @  56×96    × stage_blocks[0] 个 block
        stage1  stride2 → 128ch @  28×48    × stage_blocks[1]
        stage2  stride2 → 256ch @  14×24    × stage_blocks[2]   ← 输出 14×24
    token 网格 = 14×24 = 336。

    为什么用 RepVGG 而不是普通 CNN：训练时 3×3+1×1+identity 三分支提升精度，
    推理时数学等价折叠成单个 3×3 卷积——部署图里没有分支发散、没有额外访存，
    对 ANE 是最友好的卷积形态（复用 model_v2 已验证的折叠实现）。
    """

    def __init__(self, cfg: BackboneConfig, deploy: bool = False):
        super().__init__()
        self.cfg = cfg
        self.out_channels = cfg.stage_channels[-1]

        layers: List[nn.Module] = [
            RepVGGBlock(cfg.in_channels, cfg.stem_channels, stride=2, deploy=deploy)
        ]
        in_ch = cfg.stem_channels
        for out_ch, n_blocks in zip(cfg.stage_channels, cfg.stage_blocks):
            layers.append(RepVGGStage(in_ch, out_ch, n_blocks, stride=2, deploy=deploy))
            in_ch = out_ch
        self.stages = nn.Sequential(*layers)

        # 可选的额外一次 stride-2（带通道翻倍），仅用于「token 数」消融：
        # 让它成为唯一变化的变量，而不是像之前那样连带把通道也加宽。
        self.extra_down: nn.Module | None = None
        if cfg.extra_downsample:
            self.extra_down = RepVGGBlock(in_ch, in_ch * 2, stride=2, deploy=deploy)
            self.out_channels = in_ch * 2

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """x: [B, 3, H, W] → [B, C, H/16, W/16]（extra_downsample 时为 /32）"""
        y = self.stages(x)
        if self.extra_down is not None:
            y = self.extra_down(y)
        return y

    def reparameterize(self) -> None:
        """训练态 → 部署态：把所有 RepVGGBlock 的三分支折叠成单 3×3。"""
        for m in self.modules():
            if isinstance(m, RepVGGBlock):
                m.reparameterize()


# ═══════════════════════════════════════════════════════════════════════════
# 3. Transformer 块
# ═══════════════════════════════════════════════════════════════════════════

class TransformerBlock(nn.Module):
    """Pre-LN Transformer 编码块（pixel-state attention 的载体）。

    为什么 pre-LN 而不是论文可能用的 post-LN：pre-LN 梯度更稳、深层不易发散，
    且 LN 在 ANE 上是原生算子（实测见 §5 派发表）。层结构：
        x = x + Attn(LN(x));  x = x + FFN(LN(x))

    ⚠️ 刻意不用 F.scaled_dot_product_attention / nn.MultiheadAttention：
       它们会把 qkv 合并成一次 Linear 再 chunk，导出后产生 slice_by_index
       （项目实测该算子容易掉 CPU）。这里用三个独立 Linear，参数量完全相同，
       但图上没有切片。
    """

    def __init__(self, dim: int, heads: int, mlp_ratio: float = 4.0):
        super().__init__()
        if dim % heads != 0:
            raise ValueError(f"dim={dim} 不能被 heads={heads} 整除")
        self.dim = dim
        self.heads = heads
        self.head_dim = dim // heads
        self.scale = 1.0 / math.sqrt(self.head_dim)

        self.norm1 = nn.LayerNorm(dim)
        self.q_proj = nn.Linear(dim, dim)
        self.k_proj = nn.Linear(dim, dim)
        self.v_proj = nn.Linear(dim, dim)
        self.out_proj = nn.Linear(dim, dim)

        self.norm2 = nn.LayerNorm(dim)
        hidden = int(dim * mlp_ratio)
        self.ffn = nn.Sequential(
            nn.Linear(dim, hidden),
            nn.GELU(),
            nn.Linear(hidden, dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """x: [B, N, D] → [B, N, D]

        ⚠️ 全程不用 `b, n, d = x.shape` 这种形状解包：它会被 torch.jit.trace
           记录成 `aten::Int` 算子，进而导致 CoreML 转换报
           「converting 'int' op / only 0-dimensional arrays can be converted」。
           改用 unflatten / flatten / transpose 这些纯张量算子，形状全由常量决定，
           导出图里没有 int 转换节点（见 01-backbone.md §5）。
        """
        h = self.norm1(x)

        # [B,N,D] → [B,N,heads,head_dim] → [B,heads,N,head_dim]
        q = self.q_proj(h).unflatten(2, (self.heads, self.head_dim)).transpose(1, 2)
        k = self.k_proj(h).unflatten(2, (self.heads, self.head_dim)).transpose(1, 2)
        v = self.v_proj(h).unflatten(2, (self.heads, self.head_dim)).transpose(1, 2)

        # 显式 softmax 而不是 scaled_dot_product_attention：导出图更可控
        attn = torch.softmax((q @ k.transpose(-1, -2)) * self.scale, dim=-1)
        # [B,heads,N,head_dim] → [B,N,D]，flatten 自动合并最后两维
        ctx = (attn @ v).transpose(1, 2).flatten(2)

        x = x + self.out_proj(ctx)
        x = x + self.ffn(self.norm2(x))
        return x


class TransformerEncoderStage(nn.Module):
    """一个 stage = depth 个 TransformerBlock 堆叠（无动态循环，纯静态展开）。"""

    def __init__(self, dim: int, depth: int, heads: int, mlp_ratio: float = 4.0):
        super().__init__()
        self.blocks = nn.ModuleList(
            [TransformerBlock(dim, heads, mlp_ratio) for _ in range(depth)]
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        for blk in self.blocks:      # Python 层循环，trace 时静态展开为 depth 个节点
            x = blk(x)
        return x


# ═══════════════════════════════════════════════════════════════════════════
# 4. Command Coherency Module（训练期正则，不进部署图）
# ═══════════════════════════════════════════════════════════════════════════

class CommandCoherencyModule(nn.Module):
    """论文 §IV.C：三层 MLP + ELU，输入 t 时刻 [steer, throttle, brake, speed]，
    回归 t+1 时刻 speed。训练时先单独训好、冻结，再作为正则项约束主模型。

    为什么需要它（原文 :248-253）：steer/throttle/brake 若各自独立回归，会缺少
    "把车从当前状态带到目标状态"的共同目标，出现同时踩油门和刹车的自相矛盾输出。
    """

    def __init__(self, hidden: int = 64):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(4, hidden),
            nn.ELU(),
            nn.Linear(hidden, hidden),
            nn.ELU(),
            nn.Linear(hidden, 1),
        )

    def forward(self, controls_and_speed: torch.Tensor) -> torch.Tensor:
        """[B, 4] → [B, 1]（预测的 t+1 speed）"""
        return self.net(controls_and_speed)


# ═══════════════════════════════════════════════════════════════════════════
# 5. 完整模型：骨干 + 多阶段 state-token 主干
# ═══════════════════════════════════════════════════════════════════════════

class V3BackboneModel(nn.Module):
    """V3 视觉骨干 + 多阶段 Transformer 主干。

    前向数据流（B=batch，N=336 visual tokens，D=dim）：
        image [B,3,224,384] → backbone → [B,256,14,24]
        → flatten → [B,336,256] → Linear → [B,336,D]
        state [B,5] → Linear → [B,1,D]
        tokens = cat([state, visual]) + pos_emb → [B,337,D]
        stage1(tokens) → 取 token[0] → stop/go [B,3]
        stage2([stage1_state; visual] + pos_emb) → 取 token[0] → ctrl [B,3]

    ⚠️ stage2 为什么重新拼原始 visual token 而不是用 stage1 的输出：
       论文 §IV.A 原文只说把 **state token** 的输出传下去（"taking the output of
       the encoder corresponding to the state token and propagating it as the new
       state token"），没有说视觉 token 也传。若视觉 token 也传，就等于 stage2
       只对 stage1 特征做二次加工，图像信息不会再被"带着新问题重看一遍"。
       这里保留原始视觉 token，让每个 stage 用不同的任务重新读图——这与论文
       "coarse-to-fine / 每级解码成不同输出"的描述一致。该选择可配置
       （propagate_visual_tokens），留作消融。
    """

    def __init__(self, cfg: BackboneConfig | None = None, deploy: bool = False,
                 propagate_visual_tokens: bool = False):
        super().__init__()
        self.cfg = cfg or BackboneConfig()
        c = self.cfg
        self.propagate_visual_tokens = propagate_visual_tokens

        n_h, n_w = c.token_grid()
        self.token_h, self.token_w = n_h, n_w
        self.num_visual = n_h * n_w

        # ── 视觉骨干 ──
        self.backbone = RepVGGVisualBackbone(c, deploy=deploy)
        self.token_proj = nn.Linear(self.backbone.out_channels, c.dim)

        # ── 状态 token 初始化：论文 Eq.(1) 把 4 个标量各升维到 D/4 再拼。
        # 这里是它的等价推广：单个 Linear(state_dim → D)。当 state_dim 能整除 D
        # 且权重初始化为块对角时，与论文写法逐元素等价；用单个 Linear 的好处是
        # 图上只有 1 个 matmul，没有 concat/slice（那些算子容易掉 CPU）。
        self.state_lift = nn.Linear(c.state_dim, c.dim)

        # ── 可学习位置编码（论文 Eq.(1) 的 Epos ∈ R^{(N+1)×D}）──
        self.pos_emb = nn.Parameter(torch.zeros(1, 1 + self.num_visual, c.dim))
        nn.init.trunc_normal_(self.pos_emb, std=0.02)

        # ── 两个 transformer encoder stage（论文 §IV.D：depth 4、3 heads）──
        self.stage1 = TransformerEncoderStage(c.dim, c.depth_per_stage, c.heads, c.mlp_ratio)
        self.stage2 = TransformerEncoderStage(c.dim, c.depth_per_stage, c.heads, c.mlp_ratio)

        # ── 头：stage1 → stop/go（3 路），stage2 → 三个控制量 ──
        self.stop_go_head = nn.Linear(c.dim, c.stop_go_dim)
        self.ctrl_head = nn.Linear(c.dim, 3)

        # ── CCM：仅训练期用 ──
        self.ccm = CommandCoherencyModule(c.ccm_hidden)

    # ─────────────────────────── 内部 ───────────────────────────

    def _visual_tokens(self, image: torch.Tensor) -> torch.Tensor:
        """image [B,3,H,W] → visual tokens [B,N,D]"""
        feat = self.backbone(image)                       # [B,C,h,w]
        # [B,C,h,w] → [B,C,N] → [B,N,C]：flatten 从第 2 维起，不读 shape，
        # 避免 trace 出 aten::Int（CoreML 转换会因此失败）
        flat = feat.flatten(2).transpose(1, 2)            # [B,N,C]
        return self.token_proj(flat)                      # [B,N,D]

    def _state_token(self, state: torch.Tensor) -> torch.Tensor:
        """state [B,S] → [B,1,D]"""
        return self.state_lift(state).unsqueeze(1)

    # ─────────────────────────── 前向 ───────────────────────────

    def forward(self, image: torch.Tensor, state: torch.Tensor
                ) -> Tuple[torch.Tensor, torch.Tensor]:
        """部署前向：返回 (stop_go [B,3], ctrl [B,3])。

        ctrl 的三列依次是 steer / throttle / brake 的**原始 logits**
        （steer 用 tanh、throttle/brake 用 sigmoid 由下游头决定，见 03-output-head.md）。
        """
        visual = self._visual_tokens(image)               # [B,N,D]
        st = self._state_token(state)                     # [B,1,D]

        tokens1 = torch.cat([st, visual], dim=1) + self.pos_emb
        out1 = self.stage1(tokens1)                       # [B,1+N,D]
        state_token_1 = out1[:, 0:1, :]                   # 论文 §IV.A：取出 state token
        stop_go = self.stop_go_head(state_token_1.squeeze(1))

        # 状态 token 传播：stage1 的 state token 作为 stage2 的输入 state token
        if self.propagate_visual_tokens:
            tokens2 = torch.cat([state_token_1, out1[:, 1:, :]], dim=1) + self.pos_emb
        else:
            tokens2 = torch.cat([state_token_1, visual], dim=1) + self.pos_emb

        out2 = self.stage2(tokens2)
        ctrl = self.ctrl_head(out2[:, 0, :])
        return stop_go, ctrl

    def forward_with_ccm(self, image: torch.Tensor, state: torch.Tensor,
                         speed: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """训练前向：额外用 CCM 由预测控制量回归 t+1 速度（仅训练期）。

        speed: [B,1]，当前时刻速度（CCM 的输入之一）
        返回 (stop_go, ctrl, speed_pred)
        """
        stop_go, ctrl = self.forward(image, state)
        steer = torch.tanh(ctrl[:, 0:1])
        throttle = torch.sigmoid(ctrl[:, 1:2])
        brake = torch.sigmoid(ctrl[:, 2:3])
        speed_pred = self.ccm(torch.cat([steer, throttle, brake, speed], dim=1))
        return stop_go, ctrl, speed_pred

    def reparameterize(self) -> None:
        """把骨干从训练态折叠成部署态（单 3×3 conv）。"""
        self.backbone.reparameterize()

    # ─────────────────────────── 统计 ───────────────────────────

    @torch.no_grad()
    def layer_table(self) -> List[dict]:
        """逐层参数表：层名 / 参数形状 / 参数量 / 累计。用于 01-backbone.md §3。"""
        rows: List[dict] = []
        total = 0
        for name, p in self.named_parameters():
            n = p.numel()
            total += n
            rows.append({
                "name": name,
                "shape": tuple(p.shape),
                "params": n,
                "cumulative": total,
            })
        return rows


def build_v3_backbone(cfg: BackboneConfig | None = None, deploy: bool = False,
                      propagate_visual_tokens: bool = False) -> V3BackboneModel:
    """按配置构建模型（未加载权重）。deploy=True 时为已折叠的单 3×3 形态。"""
    return V3BackboneModel(cfg, deploy=deploy,
                           propagate_visual_tokens=propagate_visual_tokens)


__all__ = [
    "BackboneConfig",
    "RepVGGVisualBackbone",
    "TransformerBlock",
    "TransformerEncoderStage",
    "CommandCoherencyModule",
    "V3BackboneModel",
    "build_v3_backbone",
]
