#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wm_static.py — 静态世界模型（无动作标签，纯视频自监督）

一句话定位：
    输入当前帧，输出**潜空间里的未来帧表征**。它只回答「世界会怎么往前走」，
    不回答「我按哪个键会改变世界」——那是动态世界模型（src/wm_dynamic.py）的事。
    因为不需要动作标签，训练数据只要连续视频帧（data/video_frames/yt_p1、yt_p2）。

====================================================================
设计决定 1：为什么用 JEPA（潜空间预测）而不是自编码器重建像素
====================================================================
重建像素会把模型容量大量花在「轮胎纹理、光照、远处树」这些与驾驶决策无关的
细节上；对控制/规划真正重要的是「车在哪、路朝哪、前方有没有障碍」这类语义状态。
潜空间预测直接约束「未来状态的抽象表征」，逼模型只保留可预测、可复用的信息，
这是 LeCun 的 JEPA 思路，也是本任务要求「不重建像素」的根本原因。

代价要说清楚：没有像素重建损失，我们**无法用肉眼看重建质量**来诊断模型好坏，
只能靠表征统计量（方差/有效秩）和「预测表征 vs 真实下一帧表征的余弦」来判断。
因此 tools/train_wm_static.py 里把这两项指标当成一等公民，每轮都测。

====================================================================
设计决定 2：为什么必须有可学习的 predictor，而不是让编码器自己回归未来
====================================================================
如果让编码器直接回归未来帧表征，梯度会推着编码器把「当前帧」也编码成未来帧的
样子——编码器退化成一个「提前量」变换，当前帧表征就丢失了。把预测能力放进一个
独立的小 MLP（predictor），编码器只负责「忠实编码当前帧」，两者分工清晰：
    encoder(x_t) → z_t                      （当前状态，供对齐/规划用）
    predictor(z_t) → ẑ_{t+h}                （未来状态预测）
这也是 BYOL/JEPA 的标准做法。

====================================================================
设计决定 3：为什么用 EMA target encoder + stop-gradient（防塌缩第一道闸）
====================================================================
如果 online 编码器和 target 编码器同时被梯度更新，模型会走最省力的捷径：把两边
都输出成同一个常数向量，预测损失直接变 0，但表征彻底没信息了（塌缩）。
EMA target 把「被预测目标」变成一个**移动很慢的锚**：
    θ_target ← m·θ_target + (1−m)·θ_online     （m 默认 0.996，线性升到 0.999）
且 target 分支对 prediction loss **不接收梯度**（stop-gradient）。于是 online 分支
只能追着一个「自己不能改」的目标跑，而 target 慢慢跟随 online——塌缩不是被禁止，
而是变得「没有便宜可占」：常数输出这条路被慢锚切断了。

为什么 momentum 要 ≥0.99 且随时间升到 0.999：
    新初始化的 target 很弱。如果 m 太小（跟随太快），target 会被 online 的早期噪声
    带偏，等于退化成「两个一起更新」；m 太大又让 target 跟不上表征演化。先 0.996
    让 target 快速跟上初始收敛，再升到 0.999 让它稳定成锚，是 BYOL 的经验做法。

====================================================================
设计决定 4：为什么 EMA 之外还必须加 VICReg 的 variance/covariance 项
====================================================================
EMA + stop-grad 只是「让塌缩没有捷径」，并不**直接**要求表征各维有方差。
实测中（小数据、小 batch、弱正样本对）模型仍会进入「低方差塌缩」：所有样本的
latent 挤在很小一个球里，余弦相似度看起来很高（因为大家都指向同一方向），
但有效信息极少——这种状态在余弦指标上甚至更「好看」，所以必须用别的统计量兜底。

VICReg 的两项直接对分布下手：
    variance 项：对每一维，若 batch 内标准差 < 1 就罚（hinge），逼每一维都「撑开」。
                 这是逐维的，所以它不允许「只有少数维度有方差、其余维度常数」。
    covariance 项：把各维之间的协方差矩阵非对角元素压到 0，逼各维编码**互不重复**
                 的信息。没有它，模型可能用 256 个几乎相同的维度来撑大方差，
                 有效秩仍然很低。
二者合起来把「高方差 + 低冗余」这个要求写进损失，是对塌缩的**直接**约束，
本质上是把表征分布往「各向同性、单位尺度」推，而 EMA 负责「目标别被带跑」。
（这也是 VICReg 论文的原意：不需要负样本、也能防塌缩。）

====================================================================
尺寸与参数预算契约（下游 task-3 对齐层依赖这些值，改动前先通知 Lead）
====================================================================
    输入：image [B, 3, 224, 384]  float32，RGB，CHW，像素 /255 后再做 mean/std 归一化
          —— 注意 224 是高(H)、384 是宽(W)。源视频 1920x804 只做过等比缩放，
             严禁再裁切（裁切会丢掉画面边缘的道路/障碍信息）。
    encode() 输出：latent [B, 256] float32          ← task-3 共享潜空间的契约维度
    predict_next() 输出：next_latent [B, 256] float32
    参数量：目标是 fp32 约 30MB ≈ 7.5M 参数（online encoder + predictor，
            不含只在训练期存在的 EMA target 副本——target 不导出 CoreML）。

用一个小 CNN 而不是 ViT 的原因：M3/16GB 上 ViT 在 224x384 输入下的激活和注意力
矩阵内存开销太大（8GB 级），且无动作标签的小数据上 CNN 的归纳偏置（局部性、
平移等变）更容易收敛。用 ResNet 式残差块在 depth 和宽度间换参数，方便对准预算。

未测声明：
    · 本文件只定义结构与契约，不产生任何精度结论；所有数字（loss/方差/体积/
      余弦）必须由 tools/train_wm_static.py 与 tools/export_wm_static.py 实测填写。
    · 预训练数据是《异环》无 UI 飙车视频，画面分布与真实录制（带 UI）不同，
      跨域可用性由 task-3 的对齐层负责验证，本文件不做此承诺。
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
from typing import List, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F


# --------------------------------------------------------------------------- 配置


@dataclass(frozen=True)
class StaticWmConfig:
    """静态世界模型的全部结构超参。

    全部写成显式字段而不是 argparse 到处传，是为了让 train/export 两个脚本
    用**同一份**结构定义——导出时 CoreML 的形状必须与训练时严格一致，任何
    一处手抄通道数都可能造成「训练能跑、CoreML 形状不对」的静默错误。
    """

    #: 输入尺寸。224=高，384=宽。与 data/lean_clips 动作数据同尺寸，便于 task-3 对齐。
    image_h: int = 224
    image_w: int = 384
    in_ch: int = 3

    #: 各 stage 的输出通道与残差块个数。第 0 项是 stem 通道。
    #: 通过调这个把总参数量对准 ~7.5M（fp32 ≈ 30MB）。
    #: 这组值实测部署参数 7,216,512 = 27.53 MB fp32（见 src/wm_static.py 自检输出）。
    #: 为什么不是「更整齐」的 64/128/256/512：按等比放大到 7.5M 会到 10M（38MB），
    #: 超预算 27%；这组是贴着 30MB 目标选出来的，不是随手写的。
    widths: Tuple[int, ...] = (64, 128, 192, 320, 448)
    depths: Tuple[int, ...] = (2, 2, 2, 1, 1)

    #: 潜空间维度。**契约值，不要改**：task-3 要求两边 encode() 都输出 256。
    latent_dim: int = 256

    #: predictor 的隐层宽度。预测器故意做小：它只是「沿时间轴的一步外推」，
    #: 不需要大容量；把预算留给 encoder 才能学到有用的视觉表征。
    predictor_hidden: int = 384

    #: 预测的时间跨度（帧）。15fps 下 horizon=8 约 0.53s，是驾驶上真正有意义的预判提前量。
    #: 这个值是**实测选出来**的，不是拍的：在 p1 后段/p2 上等间隔抽 100 个锚点，
    #: 用已训练编码器量「把当前表征直接当预测」的余弦（恒等基线，已扣掉 DC 偏移）：
    #:     h= 3 (0.20s)  identity=0.9995   ← 什么都不做几乎就是满分，没有可学空间
    #:     h= 8 (0.53s)  identity=0.9906   ← 采用：有可测的变化，且变化仍是连续运动
    #:     h=15 (1.00s)  identity=0.9697
    #:     h=60 (4.00s)  identity≈0.95 以下：画面已被场景切换主导，不是「世界演化」
    #: horizon 太小 → 预测退化成恒等映射（模型学不到东西，指标还很好看）；
    #: horizon 太大 → 任务变成「猜下一个场景」，不是可学的连续动态。
    horizon: int = 8

    #: 归一化层 eps。保留 bn_eps 这个名字是因为它同时被 GroupNorm 使用；
    #: 归一化方式本身见 make_norm()（GroupNorm，非 BatchNorm）。
    bn_eps: float = 1e-5

    def validate(self) -> None:
        """契约自检：任何形状/维度不一致都在开跑前炸掉，而不是训到一半才发现。"""
        if len(self.widths) != len(self.depths):
            raise ValueError(
                f"widths({len(self.widths)}) 与 depths({len(self.depths)}) 长度必须一致"
            )
        if self.latent_dim != 256:
            raise ValueError(
                f"latent_dim={self.latent_dim} 违反 task-3 契约（必须 256）"
            )
        if self.horizon < 1:
            raise ValueError(f"horizon={self.horizon} 必须 ≥1")
        if self.image_h != 224 or self.image_w != 384:
            raise ValueError(
                f"输入尺寸 {self.image_h}x{self.image_w} 违反契约（必须高224 宽384）"
            )


# --------------------------------------------------------------------------- 组件


def make_norm(channels: int, eps: float) -> nn.Module:
    """统一的归一化层工厂：用 GroupNorm，**不用 BatchNorm**。

    为什么换掉 BatchNorm（这是实测逼出来的，不是口味问题）：
        用 BN 训练 400 步后，同一个模型在验证集与留出集上的表征统计量差三个量级：
            val  mean_std=0.0008  dead_dims=256/256   （特征被压成一个点）
            test mean_std=1.6105  dead_dims=0/256     （特征反而爆掉）
            test loss=303.87                          （同一份权重、同一套损失）
        根因是 BN 的两个模式用的是**两套统计量**：训练用当前 batch 的均值方差，
        推理用训练期累积的 running_mean/var。我们的训练集只有 p1 前 80% 的画面，
        拿到 p2（另一段视频、光照与赛道都不同）做前向时，用旧分布的统计量去归一化
        新分布，22 层逐层放大，最后要么压平要么炸掉。
        而 CoreML 导出时**必须**冻结成推理模式，等于把这个错配永久固化进交付物。

    为什么 GroupNorm 能根治：
        它只用**单个样本自己**的通道分组统计量，没有 running stats，因此
        train() 与 eval() 的输出完全一致——「两套统计量」这个错配源从结构上消失。
        同时它与 batch size 解耦（batch=16 也不抖），且不会跨样本泄漏信息
        （BN 在小 batch 的对比学习里已知会让同批样本互相「偷看」，对 JEPA 不利）。

    为什么分组数取 min(8, channels) 且要求整除：
        GroupNorm 要求 channels % groups == 0。本模型所有宽度（64/128/192/320/448）
        都能被 8 整除；仍写这个兜底是为了防止以后改宽度时踩到整除断言。
    """
    groups = min(8, channels)
    while channels % groups != 0:
        groups -= 1
    return nn.GroupNorm(groups, channels, eps=eps)


class ResBlock(nn.Module):
    """标准残差块：两个 3x3 卷积 + 归一化，shortcut 1x1 做通道/分辨率匹配。

    归一化用 GroupNorm 而非 BatchNorm，原因见 make_norm() 的长注释（BN 的
    train/eval 两套统计量会让留出集上的表征整体崩掉，且导出 CoreML 时会固化）。

    为什么用 stride=2 的卷积下采样而不是 maxpool：卷积下采样能同时学「怎么降采样」，
    而 maxpool 是固定规则。两者在本任务上差距通常不显著，选卷积是为了与仓库既有
    model_v3 主干（残差 + 归一化 + GELU）保持一致，减少读者心智切换。
    """

    def __init__(self, c_in: int, c_out: int, stride: int, bn_eps: float) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(c_in, c_out, 3, stride, 1, bias=False)
        self.norm1 = make_norm(c_out, bn_eps)
        self.conv2 = nn.Conv2d(c_out, c_out, 3, 1, 1, bias=False)
        self.norm2 = make_norm(c_out, bn_eps)

        if stride != 1 or c_in != c_out:
            self.shortcut = nn.Sequential(
                nn.Conv2d(c_in, c_out, 1, stride, 0, bias=False),
                make_norm(c_out, bn_eps),
            )
        else:
            self.shortcut = nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = F.gelu(self.norm1(self.conv1(x)))
        out = self.norm2(self.conv2(out))
        return F.gelu(out + self.shortcut(x))


class ConvEncoder(nn.Module):
    """把 224x384 的 RGB 帧压成一个 256 维潜向量。

    结构：stem(conv s2) → 5 个 stage（每个首个残差块 s2 降采样）→ 全局平均池化
    → 两层 MLP 头。5 次 stride=2 后空间尺寸为 7x12，已足够小；再继续降会丢失
    「远处弯道」这类对驾驶关键的信息。
    """

    def __init__(self, cfg: StaticWmConfig) -> None:
        super().__init__()
        self.cfg = cfg
        c0 = cfg.widths[0]

        self.stem = nn.Sequential(
            nn.Conv2d(cfg.in_ch, c0, 3, 2, 1, bias=False),
            make_norm(c0, cfg.bn_eps),
            nn.GELU(),
        )

        stages: List[nn.Module] = []
        c_prev = c0
        for c_out, depth in zip(cfg.widths, cfg.depths):
            blocks: List[nn.Module] = [ResBlock(c_prev, c_out, 2, cfg.bn_eps)]
            for _ in range(depth - 1):
                blocks.append(ResBlock(c_out, c_out, 1, cfg.bn_eps))
            stages.append(nn.Sequential(*blocks))
            c_prev = c_out
        self.stages = nn.Sequential(*stages)

        # 全局平均池化把「空间位置」压掉，得到对画面绝对位置不敏感的全局状态。
        # 为什么不在池化前用注意力：注意力在 7x12 上收益有限，但会引入不稳定的
        # 训练动态（小 batch 下 softmax 容易饱和），先用更稳的 GAP。
        self.head = nn.Sequential(
            nn.Linear(c_prev, c_prev),
            nn.GELU(),
            nn.Linear(c_prev, cfg.latent_dim),
        )

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        if image.shape[-2:] != (self.cfg.image_h, self.cfg.image_w):
            raise ValueError(
                "输入尺寸必须为 "
                f"[B,{self.cfg.in_ch},{self.cfg.image_h},{self.cfg.image_w}]，"
                f"实际收到 {tuple(image.shape)}"
            )
        x = self.stem(image)
        x = self.stages(x)
        x = F.adaptive_avg_pool2d(x, 1).flatten(1)
        return self.head(x)


class LatentPredictor(nn.Module):
    """一步时间外推：z_t → ẑ_{t+h}，输出 **残差式**（预测变化量再加回输入）。

    为什么是纯 MLP 而不是「再跑一遍卷积」：输入已经是全局池化后的 256 维向量，
    没有任何空间结构可卷积；再想恢复空间细节就得引入 decoder，那就违背「不重建
    像素」的约束了。MLP 的容量刚好够学「全局状态的一步演化」（速度方向、转向趋势）。

    为什么用残差 + 末层零初始化（关键设计）：
        horizon=3 时相邻帧表征高度相关，cos(z_t, z_{t+3}) 本来就很高。若让 MLP
        从零学「输出一个和输入几乎一样的向量」，容量会大量耗在拟合恒等映射上，
        早期预测甚至可能**不如**直接把当前表征当预测。残差式 + 末层权重/偏置
        全零初始化，使训练第一步恰好满足 ẑ = z_t，即等价于「恒等基线」；
        此后梯度只用于学习「真正该改哪一部分」，起点就不会低于恒等基线。
        评测里同时报 identity 基线，就是为了让这个起点可核对。
    """

    def __init__(self, latent_dim: int, hidden: int) -> None:
        super().__init__()
        self.fc1 = nn.Linear(latent_dim, hidden)
        self.fc2 = nn.Linear(hidden, latent_dim)
        # 零初始化末层：见类注释。只对「输出变化量」的那一层做，fc1 保持默认初始化
        # 以便梯度能正常流动（若连 fc1 也置零，整条支路一开始就是死的）。
        nn.init.zeros_(self.fc2.weight)
        nn.init.zeros_(self.fc2.bias)

    def forward(self, z: torch.Tensor) -> torch.Tensor:
        delta = self.fc2(F.gelu(self.fc1(z)))
        return z + delta


# --------------------------------------------------------------------------- 主模型


class StaticWorldModel(nn.Module):
    """online encoder + predictor + EMA target encoder 的三件套。

    三件套的分工（训练期）：
        online 编码器：被梯度更新，产出「当前状态」表征 z_t，并供下游使用。
        predictor：被梯度更新，从 z_t 预测目标表征 ẑ_{t+h}。
        target 编码器：online 的 EMA 副本，只前向、不反传，产出「未来状态」的目标表征。

    导出 CoreML 时只保留 online + predictor（见 export 脚本里的 ExportWrapper），
    target 是训练期的脚手架，部署侧不需要。
    """

    def __init__(self, cfg: StaticWmConfig) -> None:
        super().__init__()
        cfg.validate()
        self.cfg = cfg

        self.online = ConvEncoder(cfg)
        self.predictor = LatentPredictor(cfg.latent_dim, cfg.predictor_hidden)

        # target 是 online 的深拷贝，且永远不接收梯度。
        self.target = copy.deepcopy(self.online)
        for p in self.target.parameters():
            p.requires_grad_(False)

    # ---- 前向部件 -------------------------------------------------------

    def encode(self, image: torch.Tensor) -> torch.Tensor:
        """当前帧 → 潜向量 [B, latent_dim]。下游（task-3 对齐层）用的就是它。"""
        return self.online(image)

    def predict_next(self, z: torch.Tensor) -> torch.Tensor:
        """潜向量 → 未来潜向量（未归一化；相似度比较时再做 L2 归一化）。"""
        return self.predictor(z)

    @torch.no_grad()
    def encode_target(self, image: torch.Tensor) -> torch.Tensor:
        """目标编码器前向。加 @torch.no_grad 是双保险：即使调用方忘了 detach，
        这里也不会把梯度带进 target（stop-gradient 的另一半）。"""
        return self.target(image)

    # ---- EMA 更新 -------------------------------------------------------

    @torch.no_grad()
    def update_target(self, momentum: float) -> None:
        """θ_target ← m·θ_target + (1−m)·θ_online。

        buffer 一起做 EMA：现在模型用 GroupNorm，**没有** running_mean/var 这类
        跨样本累积的 buffer，所以下面的 buffer 循环实际是空转。保留它是防御性的：
        一旦以后有人换回带 running stats 的归一化（或加了别的 buffer），忘记 EMA
        会让 target 的统计量停在初始化值，于是目标表征与 online 表征分布不一致，
        预测损失里混入一个与「世界演化」无关的固定偏移——这种 bug 不报错、只掉点。
        """
        if not 0.0 < momentum < 1.0:
            raise ValueError(f"momentum 必须落在 (0,1)，收到 {momentum}")

        for p_online, p_target in zip(
            self.online.parameters(), self.target.parameters()
        ):
            p_target.data.mul_(momentum).add_(p_online.data, alpha=1.0 - momentum)

        for b_online, b_target in zip(
            self.online.buffers(), self.target.buffers()
        ):
            if b_online.dtype.is_floating_point:
                b_target.data.mul_(momentum).add_(
                    b_online.data, alpha=1.0 - momentum
                )
            else:  # 整型 buffer（如 num_batches_tracked）不能做浮点 EMA，直接复制
                b_target.data.copy_(b_online.data)

    # ---- 训练辅助 -------------------------------------------------------

    def train(self, mode: bool = True) -> "StaticWorldModel":
        """覆盖 train()：无论外层怎么切，target 永远保持 eval。

        为什么必须这样：target 在训练模式下其 BN 会继续用当前 batch 更新
        running stats，那等于 target 也在「看数据」，EMA 的慢锚语义被破坏，
        且会与 online 的 BN 统计同步偏移——这是 BYOL 实现里最常见的塌缩 bug 来源。
        """
        super().train(mode)
        self.target.eval()
        return self

    def trainable_parameters(self):
        """只返回 online + predictor 的参数（target 不参与优化器）。

        显式列出而不是简单 filter(requires_grad)：既省一次遍历，也让「哪些参数
        该被训练」这件事在代码里一眼可见，避免 target 被误加进优化器导致 EMA 失效。
        """
        yield from self.online.parameters()
        yield from self.predictor.parameters()

    def param_counts(self) -> Tuple[int, int]:
        """返回 (部署参数量, target 脚手架参数量)，用于报告里的体积核算。

        部署参数量 = online + predictor，这是 CoreML 实际会打包的部分；
        target 不导出，单独报出来是为了让读者理解「为什么 checkpoint 比模型大一倍」。
        """
        deploy = sum(p.numel() for p in self.online.parameters()) + sum(
            p.numel() for p in self.predictor.parameters()
        )
        scaffold = sum(p.numel() for p in self.target.parameters())
        return deploy, scaffold


class ExportWrapper(nn.Module):
    """CoreML 导出用的薄壳：一次前向同时给出「当前表征」和「预测的未来表征」。

    为什么要两个输出：部署侧既要按 task-3 契约拿 encode() 的 256 维潜向量，
    又要拿 predictor 的输出做「预判世界会怎么变」；分两次跑等于把 encoder 的
    卷积算两遍，在 iOS 上纯属浪费。一个图两个输出最省。
    """

    def __init__(self, model: StaticWorldModel) -> None:
        super().__init__()
        self.online = model.online
        self.predictor = model.predictor

    def forward(self, image: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        latent = self.online(image)
        next_latent = self.predictor(latent)
        return latent, next_latent


# --------------------------------------------------------------------------- 损失


def vicreg_terms(
    z: torch.Tensor,
    var_coeff: float = 1.00,
    cov_coeff: float = 0.50,
    mean_coeff: float = 10.0,
    eps: float = 1e-4,
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor, dict]:
    """VICReg 的 variance/covariance 两项 + 一阶矩（均值）约束。

    参数
        z: [B, D] 的 batch 表征（这里用 online encoder 对**当前帧**的输出）。
        var_coeff/cov_coeff: 权重。variance 系数取 1.0 是相对预测损失（cosine
            距离，量级 0~2）的一个平衡点：太小挡不住塌缩，太大会压过预测目标、
            把表征撑成各向同性噪声。covariance 只取 0.01 是因为它的量级是
            「非对角协方差平方和 / D」，天然比 variance 项小很多，等权会过强。
        mean_coeff: 均值项权重。**这一项是实测后补的，不是照抄 VICReg 论文**：
            标准 VICReg 只用方差+协方差（它假设前面有 BN 做中心化）。但本模型
            最后的 Linear 头带偏置，实测训练 150 步后所有帧表征挤在同一个方向上：
                ||batch 均值|| = 2.408，而单帧特征范数均值 = 2.279
            也就是「公共偏移」和「真实特征」一样大。余弦相似度会被这个公共方向
            主导——任意两帧的原始余弦都 ≈0.93，随机配对的负基线失去判别力，
            「预测余弦高于随机基线」这个验收指标就成了虚的。
            把每维的 batch 均值压向 0（等价于 BN 的中心化，但作用在整个 latent 上），
            余弦才真正度量「方向差异」。
        eps: 标准差的下限保护，避免常数输出时 sqrt 对 0 求导产生 NaN。

    返回 (var_loss, cov_loss, mean_loss, 诊断字典)。诊断字典写进日志，用来在
    训练中实时观察「是不是有维度快死了」（min_std 接近 0）和「公共偏移多大」
    （mean_norm 接近单帧范数就是快退化了）。
    """
    if z.dim() != 2:
        raise ValueError(f"VICReg 期望 [B,D] 的张量，收到 {tuple(z.shape)}")
    if z.shape[0] < 2:
        raise ValueError(f"VICReg 需要 batch ≥ 2（要估方差），收到 {z.shape[0]}")

    batch_size, dim = z.shape

    # variance：逐维标准差，<1 才罚（hinge）。用 relu 而不是平方，是为了让
    # 「已经撑开到 1 的维度」不再产生梯度，把优化压力留给快死的维度。
    # 这一项是**唯一负责设定表征尺度**的项（目标 std≈1）；其余两项都做成尺度无关，
    # 见下面 cov/mean 的注释。这样「调尺度」与「治共线/治DC」不再互相牵制。
    std = torch.sqrt(z.var(dim=0) + eps)
    var_loss = torch.relu(1.0 - std).mean()

    # covariance → **相关系数**矩阵，压非对角项。
    #
    # 为什么不用原始协方差（这是实测后改的）：
    #   原始协方差随表征幅度平方增长，实测 batch=16 时 cov_raw 在 0.56~1.80 之间
    #   大幅摆动，而它同时与 var 项耦合——想把 std 推到 1，cov_raw 就被放大十几倍，
    #   于是只能把 cov_coeff 压到很小，共线性就治不了（实测 eff_rank 仅 3/256）。
    #   除以各维 std 得到相关系数后，非对角元素落在 [-1,1]，量级与表征尺度无关。
    #
    # 用 .mean() 而不是 sum()/dim：非对角元素有 D(D-1)≈65k 个，求和会变成
    # 「维度越多惩罚越大」，直接把学习率压死；取均值才是「平均冗余度」。
    batch_mean = z.mean(dim=0)
    z_centered = z - batch_mean
    cov = (z_centered.T @ z_centered) / (batch_size - 1)
    denom = torch.outer(std, std)
    corr = cov / (denom + eps)
    off_diag = corr.clone()
    off_diag.diagonal().zero_()
    cov_loss = off_diag.pow(2).mean()

    # mean：DC 偏移，罚 batch 均值的平方（**不要**写成 mean²/E[z²] 这种比值）。
    #
    # 为什么曾经写成比值、又为什么退回来（这段是踩坑记录，别重蹈）：
    #   原始余弦被「所有帧共享的公共方向」主导时，直觉上想让这一项对尺度不敏感，
    #   于是写成 mean²/E[z²]（DC 能量占总体能量的比例）。但它在 z→0 时趋于 0：
    #   优化器发现**把整个表征缩到接近零**就能把这一项从 1.0 降到 0，而 var 项的
    #   hinge 早已饱和在 1.0（最多只值 var_coeff），于是「缩到零」是纯赚。
    #   实测后果：|mu| 从 2.38 掉到 0.05、std 从 0.29 掉到 0.015、dead_dims=256/256，
    #   表征整体塌缩，而 loss 曲线看起来还在"下降"——极具欺骗性。
    #   退回成 mean.pow(2).mean()：它只惩罚均值、不会因为「整体变小」而变好
    #   （缩小 z 时这一项也在变小，但 var 项会强烈反对，两者形成拉锯，不会单向塌缩）。
    mean_loss = batch_mean.pow(2).mean()

    diagnostics = {
        "min_std": float(std.min().detach()),
        "mean_std": float(std.mean().detach()),
        "dead_dims": int((std < 0.05).sum().detach()),
        "mean_norm": float(batch_mean.norm().detach()),
        "mean_ratio": float(mean_loss.detach()),
        "dim": dim,
    }
    return (
        var_coeff * var_loss,
        cov_coeff * cov_loss,
        mean_coeff * mean_loss,
        diagnostics,
    )


def jepa_loss(
    z_now: torch.Tensor,
    z_pred: torch.Tensor,
    z_target_next: torch.Tensor,
    var_coeff: float = 1.00,
    cov_coeff: float = 0.50,
    mean_coeff: float = 10.0,
    pred_weight: float = 1.0,
) -> Tuple[torch.Tensor, dict]:
    """JEPA 主损失 = 预测余弦距离 + VICReg 方差/协方差 + 一阶矩约束。

    预测项用**余弦距离**而不是 MSE：
        我们关心的是「方向对不对」（状态往哪演化），而不是 latent 的绝对尺度。
        MSE 会顺带惩罚尺度差异，在 EMA target 的尺度缓慢漂移时引入无意义的梯度。
        余弦距离 1−cos∈[0,2]，0 表示方向完全一致。
        注意：z_target_next 必须是 detach 过的（stop-gradient），调用方负责。

代价要说清楚：
        既然用余弦做预测目标，就必须防止「公共 DC 偏移」把余弦撑高——否则模型
        只要让所有帧共享一个大方向，余弦就很好看，但其实没学任何动态。这正是
        mean_coeff 存在的原因（详见 vicreg_terms 的 mean_norm 说明）。
    """
    if z_target_next.requires_grad:
        raise ValueError(
            "z_target_next 带梯度 —— stop-gradient 没生效，这会直接导致塌缩"
        )

    # 预测项乘 pred_weight（默认 5）：**按实测量级反推，不是拍脑袋**。
    # 实测（batch=16、真实帧）各项未加权原始量级：pred_raw≈0.97, var_raw≈0.96,
    # cov_raw≈0.27（相关系数版）, mean_raw≈0.04（平方版）。
    # 两个约束：
    #   · 下界：收敛后 pred_raw 会降到 0.1 量级，若不加权会被 var/cov 淹没
    #     （早前实测 pred 仅占 loss 的 2%~5%，headroom 长期停在 0 附近）。
    #   · 上界：pred 权重过大时，「输出常数」就能让 cos=1，等于鼓励塌缩。
    #     早前试过 20，初始 pred 加权后达 19.4，梯度范数冲到 10+（裁剪频繁触发），
    #     最后一轮还真的塌了（dead_dims=256）。取 5 是这两个约束之间的取值：
    #     初始 pred 约占 loss 的 84%，收敛后仍与 var/cov 同量级。
    pred_loss = pred_weight * (
        1.0 - F.cosine_similarity(z_pred, z_target_next, dim=-1)
    ).mean()
    var_loss, cov_loss, mean_loss, diag = vicreg_terms(
        z_now, var_coeff, cov_coeff, mean_coeff
    )

    total = pred_loss + var_loss + cov_loss + mean_loss
    details = {
        "loss": float(total.detach()),
        # 报未加权的原始预测损失，便于跨配置比较（loss 本身含权重）
    "pred": float(pred_loss.detach()) / pred_weight,
    # 加权后的各项与预测占比：验收要求「预测项占 loss ≥50%」，这里直接算出来，
    # 免得靠日志里的数字手工反推（手工反推过一次，算错了一版权重）。
    "pred_share": float(pred_loss.detach()) / float(total.detach()),
        "var": float(var_loss.detach()),
        "cov": float(cov_loss.detach()),
        "mean": float(mean_loss.detach()),
        **diag,
    }
    # 预测项自身的余弦值单独报出来：它比 loss 更直观（1.0 = 完美方向对齐）。
    with torch.no_grad():
        details["cos"] = float(
            F.cosine_similarity(z_pred, z_target_next, dim=-1).mean()
        )
    return total, details


# --------------------------------------------------------------------------- 工具


def build_model(cfg: StaticWmConfig) -> StaticWorldModel:
    """构造模型并打印参数账本。所有脚本入口都走这里，避免结构定义分叉。"""
    model = StaticWorldModel(cfg)
    deploy, scaffold = model.param_counts()
    print(
        "[wm_static] 部署参数 online+predictor = {:,} ({:.2f} MB fp32)".format(
            deploy, deploy * 4 / 1024 / 1024
        )
    )
    print(
        "[wm_static] 训练脚手架 EMA target = {:,} ({:.2f} MB fp32，不导出)".format(
            scaffold, scaffold * 4 / 1024 / 1024
        )
    )
    return model


if __name__ == "__main__":
    # 直接运行本文件时只做结构自检，不训练（训练入口在 tools/train_wm_static.py）。
    cfg = StaticWmConfig()
    m = build_model(cfg)
    dummy = torch.zeros(1, cfg.in_ch, cfg.image_h, cfg.image_w)
    z = m.encode(dummy)
    zn = m.predict_next(z)
    print(f"[wm_static] 自检输入 {tuple(dummy.shape)} → latent {tuple(z.shape)}"
          f" → next_latent {tuple(zn.shape)}")
