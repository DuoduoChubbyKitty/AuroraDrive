#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wm_align.py — 对齐层：把静态世界模型与动态世界模型接到同一个潜空间

================================================================================
0. 它要解决什么问题
================================================================================
    task-1 的静态世界模型（无动作标签，视频训练）与 task-2 的动态世界模型
    （带动作标签，录制训练）是**各自独立训练**的，两边潜空间没有任何共享结构。
    这不是猜测，是实测：把同一帧喂给两个主干，输出向量的余弦相似度
        · 录制域帧：mean = −0.0295（std 0.0158）
        · 视频域帧：mean = +0.0191（std 0.0279）
    即两个 256 维向量在方向上**互相正交**。所以「直接拿两边 latent 做相似度」
    必然失败，必须学一对投影头把两边映到同一个共享空间。

    对齐层的职责边界（必须说清，否则会被误解成万能胶）：
        · 负责：让「同一画面的静态表征」与「同一画面的动态表征」在共享空间可互检。
        · 不负责：让动态模型的动作因果变强。动作信号本身很弱（task-2 实测动作
          消融仅约 2%，Δ速度(8帧)按 w 仅 +1.52 km/h 而 std 15.65），对齐层
          只能搬运表征，不能凭空造出因果信号。详见 data/wm_align/report.md。

================================================================================
1. 为什么用「同一画面双侧对比」而不是「预测一致性」作为主损失
================================================================================
    卡片要求的是一致性损失，但「用哪两个量做一致性」有两个候选：

    候选甲（采用，主损失）：同一帧 x 同时喂两个主干
        u_s = proj_s(static.encode(x)),  u_d = proj_d(dynamic.encode(x))
        要求 u_s ≈ u_d。这是**成对监督**：配对关系由「同一帧」直接给出，
        不依赖任何标签，也不需要动作正确。

    候选乙（采用，辅助损失，权重可调）：两边各预测 t+8 帧
        u_s_next = proj_s(static.predict_next(static.encode(x)))
        u_d_next = proj_d(dynamic.predict_next(dynamic.encode(x), action_block))
        要求两者相近。这条才是「静态模型预测的未来」与「动态模型在正确动作下
        预测的未来」对齐，是卡片字面要求。

    为什么主损失必须用甲：乙的正确性完全建立在「动态模型的动作分支真的有效」
    之上，而 task-2 实测该分支仅带来约 2% 改善，静态 predictor 更是没超过恒等
    基线（headroom_c = −0.0024）。若把乙当主损失，对齐目标里混进大量
    「两边恒等映射的近似」成分，测出来的对齐分数会很好看，但它度量的其实是
    「两个模型都把输入近似照抄一遍」——这正是本任务最需要避免的假指标。
    甲没有这个问题：它是纯粹的跨模型配对，好坏只取决于投影头是否找到了
    共享结构，与动作信号强弱无关。

    乙保留但降权（AlignConfig.future_weight 默认 0.5，并做有/无消融），
    理由：它确实把「未来状态」这一层语义带进共享空间，对下游预判特征有用；
    降权是为了不让它主导。消融数据见 report.md。

================================================================================
2. 防塌缩：为什么是「对称 InfoNCE + VICReg」，而不是单边 stop-gradient
================================================================================
    卡片要求「双边 stop-gradient / 对称化」。本实现选**对称**，不选 EMA：

    (a) 为什么需要负样本
        如果损失只有「正样本对拉近」（cos(u_s, u_d) → 1），全局最优解是
        「两个头都把任何输入映射成同一个常数向量」——cos 恒为 1，loss 为 0，
        表征彻底无效。加负样本后，这个解会被 in-batch 负样本狠狠惩罚：
        把所有样本映射到同一点，正负样本无法区分，InfoNCE 损失达到 log(N)。
        所以在同一 batch 内用其余样本作负样本，是**让塌缩变成最差解**，
        而不是靠某个正则项去「求」它别塌。batch 越大负样本越多、约束越硬，
        这也是训练脚本先把主干特征缓存下来、再用大 batch 训头的原因。

    (b) 为什么对称而不是单边 stop-gradient / EMA
        单向 stop-gradient（BYOL 式）需要 EMA 慢锚 + 预测头不对称，是为了在
        「没有负样本」时也能防塌缩；我们既然有 in-batch 负样本，就不必引入
        EMA 这个额外活动部件（多一套参数、多一个动量超参、多一处可能写错）。
        对称做法是：把同一份 InfoNCE 双向各算一次（A→B 与 B→A）再平均，
        两侧受完全相同的约束 ⇒ 不存在「一侧塌缩去迎合另一侧」的方向，
        这正是卡片「不要只优化一侧」要求的一个更彻底形式：
        不是用 stop-grad 禁止某一侧更新，而是让两侧的约束严格等价。

    (c) 为什么 InfoNCE 之外还要 VICReg 的 variance/covariance
        InfoNCE 只保证「样本之间可分」，并不保证**逐维**都撑开：
        256 维里只用 8 维、其余维度常量化，仍然可以做到样本可分，
        但有效秩很低、下游线性探针受限（task-1/task-2 都实测到低秩：
        16.9/256 与约 13/256）。VICReg 两项直接对分布下手：
            variance  逐维 std 低于下限就罚 —— 逼每一维都有变化（塌缩下限）；
            covariance 压非对角相关 —— 逼各维编码互不重复的信息（治低秩）。
        在单位球上这两项的口径要特别说明，见 vicreg_terms_on_sphere()。

================================================================================
3. 跨域：静态主干在录制域上推理，是**有代价**的选择（实测，不是假设）
================================================================================
    静态模型用无 UI 视频训练，动态模型用带 UI 录制训练。本层按卡片方案 (a)：
    用**录制帧**同时喂两个主干（静态侧属跨域推理），这样配对天然成立。
    另一方案 (b)「用视频帧喂动态主干、动作置零」被实测否掉了：

        录制帧 → 静态主干:  std_mean=0.1180  死维 23/256   有效秩 3.94/32
        视频帧 → 动态主干:  std_mean=0.0439  死维 155/256  有效秩 2.21/32

    (b) 的退化（155/256 维死掉）远严重于 (a)（23/256），且 (b) 还要把动作块
    置零，属于动态模型的训练分布外输入。所以取 (a)。

    但 (a) 的代价必须写进结论：静态主干在录制域有 **约 9% 的维度死掉**、
    逐维 std 从 0.5284 掉到 0.1180。对齐层不能修复主干本身的退化，
    只能把这部分退化如实带进下游。report.md 里给的是录制域上的数字，
    不是视频域上的好看数字。

================================================================================
4. 归一化契约：两侧预处理**不同**（这是本任务踩过的真实坑，务必照此实现）
================================================================================
    任务卡最初写「两边都是仅 /255」，实测证明对静态侧是错的：
        · 静态侧（tools/train_wm_static.py:140）:
              (x/255 − PIXEL_MEAN) / PIXEL_STD
          证据：同一批视频帧，仅 /255 得 latent norm 5.634，
                (x−mean)/std 得 10.612，而 task-1 的 analysis.json 记录 10.6024。
        · 动态侧（tools/train_wm_dynamic.py:185）: x/255，无 mean/std。
    所以本文件的做法是：**归一化常数不在 src 里硬抄第二份**，而是由
    AlignConfig 强制外部传入（无默认值），训练脚本从 train_wm_static.py
    同源 import 并断言，避免将来训练侧改常数后这里静默漂移。

    这一步做错的后果：喂进静态主干的张量是分布外的，跨域表征直接变成噪声，
    而投影头仍然能把噪声映射得像模像样 —— 训练 loss 会正常下降，
    只有下游指标会莫名其妙地差。这类 bug 不报错，只掉点，所以必须硬编码在
    契约里并由断言守着。

================================================================================
5. 维度/时程契约（与两侧主干一致，改动前先通知 Lead）
================================================================================
    两边 latent  ：[B, 256]       （src/wm_static.py 的 latent_dim=256、
                                   src/wm_dynamic.py 的 LATENT_DIM=256）
    两边输入      ：[B, 3, 224, 384]（高 224、宽 384）
    两边 horizon  ：8 帧 ≈ 0.53s @15fps —— 这是「未来一致性」项能成立的前提：
                    若两边 horizon 不同，u_s_next 与 u_d_next 预测的不是同一时刻，
                    那一项就该按插值或按不同权重处理，而不是现在这样直接对齐。
    动态动作块    ：[B, horizon×8] = [B, 64]，**不是 [B,8]**（WMConfig.action_block_dim）
    两侧 predict_next 输出均**未 L2 归一化**，需要余弦时调用方自己归一化
    （本层的投影头输出端已做 L2 归一化，所以共享空间里可以直接点积算余弦）。

================================================================================
6. 本文件只定义结构与损失，不产生任何精度结论
================================================================================
    所有数字（对齐损失、检索命中率、探针准确率、有效秩）必须由
    tools/train_wm_align.py 实测并写进 data/wm_align/report.md。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

#: 潜空间维度。与 src/wm_static.py、src/wm_dynamic.py 三方约定的同一个数。
LATENT_DIM = 256

#: 输入帧尺寸（高, 宽）。注意不是 (384, 224)。
IMAGE_HEIGHT = 224
IMAGE_WIDTH = 384


# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------


@dataclass
class AlignConfig:
    """对齐层超参。

    static_pixel_mean / static_pixel_std **故意没有默认值**：它们必须由调用方
    （tools/train_wm_align.py）从 tools/train_wm_static.py 同源 import 后传入。
    理由见模块 docstring §4 —— 若这里给一份写死的默认值，就存在「训练侧改了
    常数、对齐侧还在用旧值」的静默漂移路径，而这类错配不会报错、只会掉点。
    """

    #: 静态主干的输入归一化常数，**必须**来自 tools/train_wm_static.py。
    static_pixel_mean: Tuple[float, float, float]
    static_pixel_std: Tuple[float, float, float]

    #: 契约维度，不允许改（改成别的值会让两侧主干输出无法接入）。
    latent_dim: int = LATENT_DIM

    #: 投影头隐层宽度。256→512→256 约 262k 参数/头，两侧合计约 0.5M。
    #: 为什么不更大：训练样本只有万级、且主干冻结，投影头再大就是纯过拟合；
    #: 为什么不更小：它要把两个**低秩**空间（实测有效秩 16.9 与约 13）
    #: 的非线性对应关系学出来，256→256 的单层线性映射表达力不够。
    hidden: int = 512

    #: 共享空间维度。保持 256 与两侧 latent 对齐：下游若要把静态/动态特征
    #: 与「原始 latent」混用，维度一致可以少一层适配；也不靠降维来伪造好看的相关性。
    proj_dim: int = LATENT_DIM

    #: InfoNCE 温度。输出经过 L2 归一化，同类配对的余弦接近 1、异类接近 0，
    #: 温度 0.10 对应「余弦差 0.1 ⇒ logit 差 1.0」，在 512 batch 下梯度不饱和。
    #: 太小（0.02）会让早期随机映射的 logits 爆到几十、训练发散；
    #: 太大（0.5）会让正负样本几乎不可分，学不到东西。
    temperature: float = 0.10

    #: 未来一致性项（docstring §1 的候选乙）权重。默认 0.5 而非 1.0：
    #: 该项的正确性依赖动态模型动作分支有效，而实测该分支仅约 2% 改善，
    #: 权重给满了会让「两边恒等近似」主导对齐目标。训练脚本提供 --future-weight 消融。
    future_weight: float = 0.5

    #: VICReg 两项权重。与 InfoNCE 同量级即可：InfoNCE 收敛后约 0.3~1.0，
    #: 这两项在健康状态下本就应该接近 0（它们只管「别塌/别低秩」），
    #: 权重给大会反过来压过对齐目标。口径见 vicreg_terms_on_sphere()。
    var_weight: float = 1.0
    cov_weight: float = 0.2

    #: 逐维 std 的塌缩下限（单位球口径）。各向同性时单位球上逐维 std ≈ 1/√D
    #: = 1/16 = 0.0625；取 0.02 ≈ 该期望值的 1/3，作为**塌缩探测器**而非
    #: 「把 std 撑到多大」的目标 —— 与 task-2 把 var_gamma 从 1.0 降到 0.25 同理。
    var_gamma: float = 0.02

    def validate(self) -> None:
        """开跑前把所有契约不一致炸出来，而不是训到一半才发现。"""
        if self.latent_dim != LATENT_DIM:
            raise ValueError(
                f"latent_dim={self.latent_dim} 违反三方契约（必须 {LATENT_DIM}）"
            )
        if self.proj_dim != LATENT_DIM:
            raise ValueError(
                f"proj_dim={self.proj_dim} 必须等于 {LATENT_DIM}：共享空间维度要与"
                f"两侧 latent 一致，降维会让下游多一层适配且掩盖真实相关度"
            )
        if len(self.static_pixel_mean) != 3 or len(self.static_pixel_std) != 3:
            raise ValueError(
                "static_pixel_mean/std 必须是 3 通道；收到 "
                f"{self.static_pixel_mean} / {self.static_pixel_std}"
            )
        # 全零 std 会让 x/std 变成 inf，且这种常数一定是从别处抄错的信号。
        if any(s <= 0.0 for s in self.static_pixel_std):
            raise ValueError(f"static_pixel_std 必须全为正，收到 {self.static_pixel_std}")
        if not 0.0 < self.temperature < 2.0:
            raise ValueError(f"temperature={self.temperature} 必须落在 (0,2)")
        if not 0.0 <= self.future_weight <= 5.0:
            raise ValueError(f"future_weight={self.future_weight} 必须落在 [0,5]")
        if not 0.0 <= self.var_gamma < 1.0:
            raise ValueError(f"var_gamma={self.var_gamma} 必须落在 [0,1)")


# ---------------------------------------------------------------------------
# 投影头
# ---------------------------------------------------------------------------


class ProjectionHead(nn.Module):
    """把一侧主干输出的 256 维 latent 映到共享空间（仍 256 维，单位球上）。

    为什么是「MLP + LayerNorm + L2 归一化」这个组合，每一段都有理由：

    · 为什么 MLP 而不是纯线性：
        两个主干都是低秩的（实测有效秩 16.9/256 与约 13/256），且非线性
        结构不同（一边 GELU+GroupNorm 的 ResNet 式塔，一边 SiLU+GroupNorm 的
        直筒塔）。从「低秩子空间 A」到「低秩子空间 B」的对应关系一般是非线性的，
        单层线性映射只能做旋转/缩放，拟合不了。隐层 512 足够，再大过拟合。

    · 为什么输出端 LayerNorm：
        实测教训（task-2 踩过同一个坑）：当 latent 的范数很大而逐维 std 很小
        （norm 12.5 vs std 0.0025）时，余弦相似度会被「所有样本共享的公共偏移」
        主导 —— 任意两帧的余弦都能到 0.99，判别力丧失。
        LayerNorm 逐样本把 256 维归一到零均值单位方差，公共偏移被直接扣掉，
        余弦才真正度量「方向差异」。它只用单样本统计量、不含跨样本信息，
        因此不破坏「同参数⇒同输出」这条性质。

    · 为什么再做 L2 归一化：
        (1) InfoNCE 的温度只在单位球上有明确刻度；若输出范数可自由漂移，
            优化器可以靠「整体放大范数」来压低 loss（把 logits 整体拉大 ⇒
            正样本 logit 占比升高），但那不改善对齐质量，只是数值作弊。
        (2) 与两侧主干的输出口径解耦：下游拿共享向量做点积即余弦，
            不需要再记「记得先归一化」这条隐性约定。

    为什么末层不零初始化：
        若 fc2 权重全零，输出恒为 0 向量；LayerNorm(0) 仍是 0，再 L2 归一化
        得到 0（被 eps 兜住），梯度路径上正样本与负样本的 logits 全部相同，
        相当于 batch 里所有样本完全不可分，早期学不动。默认初始化配合
        LayerNorm 已能保证输出尺度稳定，不需要零初始化这个技巧。
    """

    def __init__(self, cfg: AlignConfig) -> None:
        super().__init__()
        self.fc1 = nn.Linear(cfg.latent_dim, cfg.hidden)
        self.norm1 = nn.LayerNorm(cfg.hidden)
        self.act = nn.GELU()
        self.fc2 = nn.Linear(cfg.hidden, cfg.proj_dim)
        self.out_norm = nn.LayerNorm(cfg.proj_dim)

    def forward(self, latent: torch.Tensor) -> torch.Tensor:
        if latent.dim() != 2 or latent.shape[1] != self.fc1.in_features:
            raise ValueError(
                f"投影头期望 [B,{self.fc1.in_features}]，收到 {tuple(latent.shape)}"
            )
        h = self.fc2(self.act(self.norm1(self.fc1(latent))))
        return F.normalize(self.out_norm(h), dim=-1)


# ---------------------------------------------------------------------------
# 损失
# ---------------------------------------------------------------------------


def symmetric_info_nce(
    u_a: torch.Tensor,
    u_b: torch.Tensor,
    temperature: float,
) -> Tuple[torch.Tensor, Dict[str, float]]:
    """对称 InfoNCE：A→B 与 B→A 各算一次交叉熵再平均。

    下标 i 的 u_a[i] 与 u_b[i] 是**同一帧**的两个视图，其余 j≠i 是 in-batch 负样本。

    为什么用同一 batch 内的其他样本作负样本（而不是维护负样本队列）：
        本任务每次实验都是从头训一个小投影头，队列带来的动量/滞后会引入
        额外不变量；同 batch 负样本在 batch=512 时已足够硬（每个正样本 511 个负样本），
        且完全确定、可复现。代价是大 batch 需要大量样本 —— 这也是训练脚本
        先缓存主干特征的原因（主干前向贵、投影头前向便宜）。

    返回 (loss, 诊断)。
    诊断里 bidirect_acc_a2b / a2b 的 top-1 命中率就是「检索命中率」的 batch 版：
        它衡量「用静态视图去检索同帧的动态视图」的准确率，随机猜是 1/B。
        训练日志里盯着它，比盯 loss 直观（loss 的单位是 nats，不适合直觉判断）。
    """
    n = u_a.shape[0]
    if n < 2:
        raise ValueError(f"InfoNCE 需要 batch ≥ 2，收到 {n}")
    if u_b.shape[0] != n:
        raise ValueError(f"两侧 batch 不一致: {u_a.shape[0]} vs {u_b.shape[0]}")

    # 两侧都已 L2 归一化，点积即余弦；除以温度得到 logits。
    logits = (u_a @ u_b.t()) / temperature
    labels = torch.arange(n, device=u_a.device)

    loss_a2b = F.cross_entropy(logits, labels)
    loss_b2a = F.cross_entropy(logits.t(), labels)
    loss = 0.5 * (loss_a2b + loss_b2a)

    with torch.no_grad():
        # 检索命中率：对角线是否为该行最大值。
        # 注意 B→A 方向必须用 logits.t()：行是 B 视图、列是 A 视图，
        # 与上方 loss_b2a 的口径保持一致。这里曾经写成 logits，
        # 结果 acc_b2a 恒等于 acc_a2b，「对称平均」退化成单向值 ——
        # 它不会报错、只会让日志里的命中率看起来比实际略好（A→B 通常略高），
        # 属于「指标失真但不崩」的典型 bug。
        acc_a2b = float((logits.argmax(dim=1) == labels).float().mean())
        acc_b2a = float((logits.t().argmax(dim=1) == labels).float().mean())
        # 正样本对的平均余弦：直接看对齐质量，单位是 [−1,1]，比 loss 好解释。
        pos_cos = float((u_a * u_b).sum(dim=-1).mean())

    return loss, {
        "nce": float(loss.detach()),
        "nce_a2b": float(loss_a2b.detach()),
        "nce_b2a": float(loss_b2a.detach()),
        "retrieval_acc": 0.5 * (acc_a2b + acc_b2a),
        "pos_cos": pos_cos,
        # 随机基线：B 选 1。
        "retrieval_acc_random": 1.0 / n,
    }


def vicreg_terms_on_sphere(
    u: torch.Tensor,
    var_gamma: float,
    eps: float = 1e-6,
) -> Tuple[torch.Tensor, torch.Tensor, Dict[str, float]]:
    """在**单位球**表征上算 VICReg 的 variance / covariance 两项。

    ⚠️ 这里与 task-1/task-2 在原始 latent 上算的那两项目标值不同，必须分清：

    为什么不能直接照搬 var_gamma≈1 或 0.25：
        那两处的表征未做 L2 归一化，逐维 std 的量级是 0.5 上下；
        本层输出是单位球向量，各向同性时逐维 std ≈ 1/√D = 1/16 = 0.0625。
        若沿用 gamma=0.25，hinge 会**永远激活**、持续输出巨大梯度把投影头
        往某个奇怪的方向压 —— 这正是 task-2 实测过的失败模式
        （gamma=1.0 时 hinge 永不饱和，预测损失被淹没）。
        所以 gamma 的正确取值必须跟着「表征尺度的约定」走：本层取 0.02。

    为什么 variance 项是 hinge 而不是平方：
        hinge(relu) 让「已经撑开的维度」不再产生梯度，把优化压力留给快死的维度；
        平方项则会对健康维度持续施压，把一个「只需保证不塌」的正则项
        变成主导损失 —— 权重再小也会在后期压过对齐目标。

    为什么 covariance 项用相关系数矩阵（除以逐维 std）而不是原始协方差：
        原始协方差随表征尺度平方增长。单位球上各维 std 天生很小（≈0.06），
        原始协方差量级 ≈0.004；若不归一化，该项几乎恒为 0、完全不起作用，
        等于没有低秩约束。除以 denom=outer(std,std) 后非对角元素落回 [−1,1]，
        量级与尺度无关，才是「平均冗余度」。

    为什么不再加 mean 项（task-1 有、这里没有）：
        LayerNorm 已经把每个样本的 256 维去均值了，batch 层面的 DC 偏移
        被 L2 归一化进一步吸收（所有输出都在单位球上，没有「整体偏大」的自由度）。
        再加 mean 项是重复约束，且会与 LayerNorm 的仿射参数打架。

    返回 (var_loss, cov_loss, 诊断)。
    """
    if u.dim() != 2:
        raise ValueError(f"VICReg 期望 [B,D]，收到 {tuple(u.shape)}")
    n, d = u.shape
    if n < 2:
        raise ValueError(f"VICReg 需要 batch ≥ 2（要估方差），收到 {n}")

    std = torch.sqrt(u.var(dim=0, unbiased=False) + eps)      # [D]
    var_loss = F.relu(var_gamma - std).mean()

    centered = u - u.mean(dim=0, keepdim=True)
    cov = (centered.t() @ centered) / (n - 1)
    denom = torch.outer(std, std)
    corr = cov / (denom + eps)
    off_diag = corr - torch.diag_embed(torch.diagonal(corr))
    cov_loss = off_diag.pow(2).mean()

    # 诊断字典全部先 detach：std 带计算图，直接 float() 会触发
    # 「Converting a tensor with requires_grad=True to a scalar」警告。
    # 这些值只进日志、不进损失，detach 不改变任何优化行为。
    std_detached = std.detach()
    diag = {
        "std_mean": float(std_detached.mean()),
        "std_min": float(std_detached.min()),
        # 两个阈值都报：0.05 是仓库既有的「死维」口径（用于原始 latent），
        # 0.01 才是单位球上有意义的塌缩阈值（期望值 0.0625 的约 1/6）。
        "dead_dims_lt_0.05": int((std_detached < 0.05).sum()),
        "dead_dims_lt_0.01": int((std_detached < 0.01).sum()),
        "var_raw": float(var_loss.detach()),
        "cov_raw": float(cov_loss.detach()),
    }
    return var_loss, cov_loss, diag


def alignment_loss(
    u_static: torch.Tensor,
    u_dynamic: torch.Tensor,
    cfg: AlignConfig,
    u_static_next: Optional[torch.Tensor] = None,
    u_dynamic_next: Optional[torch.Tensor] = None,
) -> Tuple[torch.Tensor, Dict[str, float]]:
    """对齐主损失 = 状态一致性 + 未来一致性 + VICReg 防塌缩。

    参数
        u_static / u_dynamic:      同一批帧在共享空间里的两个视图 [B, proj_dim]
        u_static_next / u_dynamic_next:
                                   两边各预测的 t+h 帧视图（可缺省，缺省则不含该项）

    结构上的一个刻意选择：**VICReg 分别作用在两侧**，而不是只作用在共享空间
    「平均后」的那个向量上。因为要回答的验收问题是「两边都没塌缩」，
    若只对平均向量做正则，完全可能出现「一侧撑开、另一侧常量化」而平均
    看起来正常的情况 —— 那种塌缩恰好是最危险的（一侧偷偷退化成常数，
    检索命中率仍然可能很高，因为另一侧在提供全部可区分性）。
    """
    if u_static.shape != u_dynamic.shape:
        raise ValueError(
            f"两侧共享向量形状不一致: {tuple(u_static.shape)} vs {tuple(u_dynamic.shape)}"
        )

    loss_state, diag_state = symmetric_info_nce(
        u_static, u_dynamic, cfg.temperature
    )

    # 未来一致性：两侧的预测视图同样构成配对（同一帧 t 的两个预测）。
    # 注意这里**不**把 (t 视图, t+h 视图) 混进同一个 InfoNCE batch：
    # 那会让「同一帧的当前状态」变成「未来状态的负样本」，语义混乱。
    if (u_static_next is None) != (u_dynamic_next is None):
        raise ValueError("未来一致性项的两侧必须同时给出或同时缺省")
    if u_static_next is not None:
        loss_future, diag_future = symmetric_info_nce(
            u_static_next, u_dynamic_next, cfg.temperature
        )
        weighted_future = cfg.future_weight * loss_future
    else:
        loss_future = u_static.new_zeros(())
        weighted_future = loss_future
        diag_future = {
            "nce_future": float("nan"),
            "retrieval_acc_future": float("nan"),
            "pos_cos_future": float("nan"),
        }

    var_s, cov_s, diag_s = vicreg_terms_on_sphere(u_static, cfg.var_gamma)
    var_d, cov_d, diag_d = vicreg_terms_on_sphere(u_dynamic, cfg.var_gamma)

    total = (
        loss_state
        + weighted_future
        + cfg.var_weight * (var_s + var_d)
        + cfg.cov_weight * (cov_s + cov_d)
    )

    total_detached = float(total.detach())
    details: Dict[str, float] = {
        "loss": total_detached,
        **diag_state,
        **diag_future,
        "loss_future": float(loss_future.detach()),
        # 加权后的贡献与占比：与 task-1/task-2 的日志口径一致，
        # 便于一眼看出「对齐项是不是被正则项淹没」（那边踩过 2.1% 的坑）。
        "term_state": float(loss_state.detach()),
        "term_future": float(weighted_future.detach()),
        "term_var": float((cfg.var_weight * (var_s + var_d)).detach()),
        "term_cov": float((cfg.cov_weight * (cov_s + cov_d)).detach()),
    }
    safe_total = max(total_detached, 1e-12)
    details["share_state"] = details["term_state"] / safe_total
    details["share_future"] = details["term_future"] / safe_total
    details["share_var"] = details["term_var"] / safe_total
    details["share_cov"] = details["term_cov"] / safe_total
    # 两侧分开的健康诊断，用于证明「没有一侧塌缩去迎合另一侧」。
    for key, value in diag_s.items():
        details[f"static_{key}"] = value
    for key, value in diag_d.items():
        details[f"dynamic_{key}"] = value
    return total, details


# ---------------------------------------------------------------------------
# 组合模型
# ---------------------------------------------------------------------------


class AlignedWorldModel(nn.Module):
    """静态 + 动态两个主干（冻结）+ 两个投影头（可训练）的组合模型。

    为什么把「两侧预处理」放进这个类而不是留给调用方：
        两侧预处理**不同**（静态侧要 mean/std，动态侧只要 /255），这是本任务
        实测确认过的坑（模块 docstring §4）。如果把预处理留在调用方，
        每个调用点都要记得「静态侧要另外归一化」，而这正是最容易写错、
        且错了不报错只掉点的地方。把它收进类里，调用方只提供**原始 [0,1] 图像**，
        错配的可能从「每个调用点」收缩到「这一个方法」。

    为什么主干冻结：
        1) 训练样本只有万级，主干参数量 7.2M + 2.5M，微调必然过拟合；
        2) 主干的对齐价值在于它们已经学到的表征，改动它们会把 task-1/task-2
           的验收结论一起作废；
        3) 冻结后主干可以一次性缓存特征，训头变得极快且可反复消融
           （tools/train_wm_align.py 正是这么做的），这是工程上的直接收益。
        注意 requires_grad_(False) 只关梯度，**不会**让 backbone 进 eval 模式，
        所以下面的 train() 覆盖是必要的（GroupNorm 虽无 running stats，
        但 LayerNorm 的 dropout 之类以后若加进来会出问题；显式保持 eval 更稳）。
    """

    def __init__(
        self,
        cfg: AlignConfig,
        static_model: nn.Module,
        dynamic_model: nn.Module,
    ) -> None:
        super().__init__()
        cfg.validate()
        self.cfg = cfg
        self.static_model = static_model
        self.dynamic_model = dynamic_model

        # 冻结 + 显式 eval：见类注释「为什么主干冻结」。
        for model in (self.static_model, self.dynamic_model):
            model.eval()
            for param in model.parameters():
                param.requires_grad_(False)

        self.static_head = ProjectionHead(cfg)
        self.dynamic_head = ProjectionHead(cfg)

        # 预处理常数注册成 buffer：随 .to(device) 一起搬，且会被 state_dict 记录，
        # 导出时不会与训练时的常数脱钩。view(3,1,1) 是为了对 [B,3,H,W] 逐通道广播。
        self.register_buffer(
            "static_mean",
            torch.tensor(cfg.static_pixel_mean, dtype=torch.float32).view(3, 1, 1),
        )
        self.register_buffer(
            "static_std",
            torch.tensor(cfg.static_pixel_std, dtype=torch.float32).view(3, 1, 1),
        )

    # -- 预处理（跨域契约的唯一实现点）-----------------------------------

    def preprocess_static(self, image01: torch.Tensor) -> torch.Tensor:
        """录制/视频帧 [0,1] → 静态主干期望的输入：((x − mean) / std)。

        为什么只吃 [0,1] 而不是任意张量：把「/255」这一步固化在调用方的读取里，
        本方法只负责 mean/std，避免重复除 255（那是静默的尺度错误，2 倍差会让
        表征整体偏移，肉眼看不出来）。
        """
        if image01.dim() != 4 or image01.shape[1] != 3:
            raise ValueError(f"期望 [B,3,H,W]，收到 {tuple(image01.shape)}")
        return (image01 - self.static_mean) / self.static_std

    def preprocess_dynamic(self, image01: torch.Tensor) -> torch.Tensor:
        """录制/视频帧 [0,1] → 动态主干期望的输入：原样（该主干训练时只做 /255）。

        为什么这里不做任何事、也要写成函数：让两侧预处理在代码里**成对出现**，
        读者一眼能看到「两侧不一样」，而不是在一个地方看到归一化、在另一个地方
        看到没有归一化而以为是遗漏。
        """
        if image01.dim() != 4 or image01.shape[1] != 3:
            raise ValueError(f"期望 [B,3,H,W]，收到 {tuple(image01.shape)}")
        return image01

    # -- 前向 -----------------------------------------------------------

    @torch.no_grad()
    def encode_backbones(
        self, image01: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """一趟拿到两侧的原始 latent（主干冻结，所以整体 no_grad）。

        返回 (z_static, z_dynamic)，均为 [B, 256]，**未归一化**
        （与两侧主干的契约一致；共享空间里才归一化）。
        """
        from wm_static import StaticWorldModel  # 仅用于类型可读性，不做 isinstance 校验
        _ = StaticWorldModel  # noqa: F841  说明性引用，避免读者以为这里依赖具体类
        z_static = self.static_model.encode(self.preprocess_static(image01))
        z_dynamic = self.dynamic_model.encode(self.preprocess_dynamic(image01))
        return z_static, z_dynamic

    def heads_from_latents(
        self, z_static: torch.Tensor, z_dynamic: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """两侧原始 latent → 共享空间向量。

        为什么单独暴露这个方法：训练时主干特征已缓存，直接喂 latent 给投影头
        可以省掉全部主干前向（本方法就是训头阶段的前向入口）。
        """
        return self.static_head(z_static), self.dynamic_head(z_dynamic)

    def predict_shared(
        self, image01: torch.Tensor, action_block: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """两侧各预测 t+h 帧，返回共享空间里的两个预测视图。

        action_block 形状必须是 [B, horizon×8] = [B, 64]，**不是 [B,8]**。
        这里显式校验而不是靠动态主干报错：主干报的是
        「动作块形状应为 [B,64]，收到 [B,8]」，但如果我们传的是 [B,64] 却把
        batch 维搞错（例如 batch=8 时误传 [8,64] 而 image 只有 2 条），
        报错信息会指向拼接处、很难定位 —— 见下面 batch 一致性校验。
        """
        expected = self.dynamic_model.cfg.action_block_dim
        if action_block.dim() != 2 or action_block.shape[1] != expected:
            raise ValueError(
                f"动作块应为 [B,{expected}]（= horizon {self.dynamic_model.cfg.horizon}"
                f" × 8），收到 {tuple(action_block.shape)}"
            )
        if action_block.shape[0] != image01.shape[0]:
            raise ValueError(
                f"动作块 batch {action_block.shape[0]} 与图像 batch "
                f"{image01.shape[0]} 不一致 —— 拼接会在主干里报一个难定位的维度错误"
            )
        z_static, z_dynamic = self.encode_backbones(image01)
        z_static_next = self.static_model.predict_next(z_static)
        z_dynamic_next = self.dynamic_model.predict_next(z_dynamic, action_block)
        return self.heads_from_latents(z_static_next, z_dynamic_next)

    def forward(
        self, image01: torch.Tensor, action_block: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """训练用前向：返回 (u_static_now, u_dynamic_now) —— 状态一致性那一项。

        未来一致性那一项另走 predict_shared()，因为要额外一次 predict_next，
        把两条路径拆开可以让训练脚本按需只算其中一条（消融要用）。
        """
        z_static, z_dynamic = self.encode_backbones(image01)
        return self.heads_from_latents(z_static, z_dynamic)

    # -- 训练辅助 -------------------------------------------------------

    def train(self, mode: bool = True) -> "AlignedWorldModel":
        """覆盖 train()：主干永远保持 eval，只有投影头跟随外层模式。

        为什么必须覆盖：`requires_grad_(False)` 只影响梯度，不影响模块的
        training 标志。若外层调用 model.train()，主干内部的归一化层会切到训练行为
        （现在 GroupNorm/LayerNorm 都没有 running stats，暂时无害，但这是
        一个只需要一次架构改动就会变致命的隐性依赖）。冻结主干是「它就是一个
        固定的特征提取器」，那它在语义上也应该永远 eval。
        """
        super().train(mode)
        self.static_model.eval()
        self.dynamic_model.eval()
        return self

    def trainable_parameters(self):
        """只返回两个投影头的参数（供优化器选择）。

        显式列出而不是 filter(requires_grad) 让「哪些参数会被训练」在代码里
        一眼可见，避免将来有人放开主干的 requires_grad 后忘了这层语义。
        """
        yield from self.static_head.parameters()
        yield from self.dynamic_head.parameters()

    def param_counts(self) -> Dict[str, int]:
        """参数量账本，供 report.md 引用（体积 = 参数量 × 4 字节）。

        ⚠️ 必须把**推理期真的用到的参数**与**训练期脚手架**分开报，否则账目会虚高：
        两个主干各自都带一个 EMA target 副本（静态 target 7,019,264、
        动态 target_encoder 1,287,984），它们只在各自训练时提供 stop-grad 目标，
        推理与导出都**不用**。若把整个 nn.Module 的参数直接相加（早期版本就是这么写的），
        「冻结主干」会被报成 17,991,392，而实际推理只走 9,684,144 —— 差了 8.3M，
        读者会以为对齐层依赖一个 72MB 的模型，这个数字会一路写进报告并误导容量评估。
        """
        def count(module: nn.Module) -> int:
            return sum(p.numel() for p in module.parameters())

        static_deploy = count(self.static_model.online) + count(self.static_model.predictor)
        static_scaffold = count(self.static_model.target)
        dynamic_deploy = (
            count(self.dynamic_model.encoder)
            + count(self.dynamic_model.action_encoder)
            + count(self.dynamic_model.predictor)
        )
        dynamic_scaffold = count(self.dynamic_model.target_encoder)

        return {
            # 推理期真实存在的冻结参数：主干 online + predictor（两侧之和）
            "static_backbone_deploy": static_deploy,
            "dynamic_backbone_deploy": dynamic_deploy,
            "backbone_deploy_total": static_deploy + dynamic_deploy,
            # 训练期脚手架（EMA 副本），不参与推理、也不参与对齐层训练
            "static_backbone_scaffold": static_scaffold,
            "dynamic_backbone_scaffold": dynamic_scaffold,
            "static_head_trainable": count(self.static_head),
            "dynamic_head_trainable": count(self.dynamic_head),
            "trainable_total": count(self.static_head) + count(self.dynamic_head),
        }


class ExportWrapper(nn.Module):
    """CoreML 导出用的薄壳：只导出两个投影头。

    为什么只导出投影头、不导出整个组合模型：
        主干已经分别导出为 models/wm_static.mlmodelc（13.9MB）与
        models/wm_dynamic.mlmodelc。把它们再打包一遍等于交付 40MB+ 的重复模型，
        而推理时本来就要先跑主干拿到 latent —— 重复的卷积计算是纯浪费。
        正确做法是 Swift 侧串联：主干输出 latent → 本模型把 latent 映到共享空间。
        report.md 里有串联顺序与张量名的完整说明。

    输入是两个原始 latent（未归一化的 [B,256]）：这与主干 CoreML 的输出**直接**
    对接，中间不做任何变换 —— 变换（如果将来需要）必须也是 CoreML 图的一部分，
    不能留在 Swift 侧手工做，否则又是一处「训练/部署不一致」的风险点。
    """

    def __init__(self, model: AlignedWorldModel) -> None:
        super().__init__()
        self.static_head = model.static_head
        self.dynamic_head = model.dynamic_head

    def forward(
        self, z_static: torch.Tensor, z_dynamic: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        return self.static_head(z_static), self.dynamic_head(z_dynamic)


# ---------------------------------------------------------------------------
# 构建 / 自检
# ---------------------------------------------------------------------------


def build_aligned_model(
    cfg: AlignConfig,
    static_ckpt: str,
    dynamic_ckpt: str,
    device: torch.device,
) -> AlignedWorldModel:
    """从两份断点组装组合模型（主干冻结），并打印参数账本。

    为什么把断点加载写在这里而不是训练脚本里：加载逻辑与「两侧契约」强耦合
    （cfg 从断点里的 dict 重建、state_dict 的顶层 key 名不同），
    放在 src 里可以保证训练脚本与自检脚本用完全相同的加载路径。
    两个断点的顶层 key 不同（task-1: online/predictor/cfg，
    task-2: model/config），这里按各自的格式处理，不做统一化 ——
    统一化会掩盖「两套训练代码产物格式不同」这一事实，而它其实是重要的信息。
    """
    import sys
    from pathlib import Path

    from wm_dynamic import DynamicWorldModel, WMConfig
    from wm_static import StaticWmConfig, StaticWorldModel

    root = Path(__file__).resolve().parent.parent
    for extra in (root / "tools",):
        if str(extra) not in sys.path:
            sys.path.insert(0, str(extra))

    # ---- 静态主干 ----
    ckpt_static = torch.load(static_ckpt, map_location=device, weights_only=False)
    static_cfg = StaticWmConfig(
        **{
            k: tuple(v) if isinstance(v, list) else v
            for k, v in ckpt_static["cfg"].items()
        }
    )
    static_model = StaticWorldModel(static_cfg)
    static_model.online.load_state_dict(ckpt_static["online"])
    static_model.predictor.load_state_dict(ckpt_static["predictor"])

    # ---- 动态主干 ----
    ckpt_dynamic = torch.load(dynamic_ckpt, map_location=device, weights_only=False)
    dynamic_cfg = WMConfig(
        **{
            k: tuple(v) if isinstance(v, list) else v
            for k, v in ckpt_dynamic["config"].items()
        }
    )
    dynamic_model = DynamicWorldModel(dynamic_cfg)
    dynamic_model.load_state_dict(ckpt_dynamic["model"])

    model = AlignedWorldModel(cfg, static_model, dynamic_model).to(device)
    model.eval()

    counts = model.param_counts()
    print("[wm_align] 参数量：")
    for name, value in counts.items():
        print(f"  {name:<26} {value:>10,}  ({value * 4 / 1024 / 1024:.2f} MB fp32)")
    # 这句话刻意把「推理期真实存在」与「不参与推理」分开说：
    # 早期版本直接相加 nn.Module 参数，把两个 EMA target 副本也算进了冻结主干，
    # 报出 17,991,392（72MB），而推理实际只走 9,684,144（38.7MB）。
    print(
        f"[wm_align] 主干冻结（推理期 {counts['backbone_deploy_total']:,} 参数不训练；"
        f"另有 {counts['static_backbone_scaffold'] + counts['dynamic_backbone_scaffold']:,}"
        f" 参数是 EMA 训练脚手架、不参与推理），"
        f"只训 {counts['trainable_total']:,} 个投影头参数"
    )
    return model


def _selftest() -> int:
    """结构与损失自检：不依赖权重文件，验证形状契约与「塌缩会被惩罚」。"""
    cfg = AlignConfig(
        static_pixel_mean=(0.2717, 0.3074, 0.3251),
        static_pixel_std=(0.2099, 0.1870, 0.1888),
    )
    cfg.validate()
    torch.manual_seed(0)

    head = ProjectionHead(cfg)
    z = torch.randn(16, cfg.latent_dim)
    u = head(z)
    print(f"[selftest] ProjectionHead {tuple(z.shape)} → {tuple(u.shape)}")
    # 先 detach 再转标量：直接 float(带梯度的张量) 会触发
    # 「Converting a tensor with requires_grad=True to a scalar」警告，
    # 自检这样干净、也不影响任何数值。
    print(f"[selftest] 输出范数（应恒为 1）: {float(u.detach().norm(dim=-1).mean()):.6f}")
    if not torch.allclose(u.detach().norm(dim=-1), torch.ones(16), atol=1e-5):
        print("❌ L2 归一化未生效")
        return 1

    # 完美对齐：两侧视图完全相同 ⇒ 正样本余弦 1、检索命中率 1。
    loss, diag = alignment_loss(u, u.clone(), cfg)
    print(
        f"[selftest] 完美配对 nce={diag['nce']:.4f} 检索={diag['retrieval_acc']:.4f} "
        f"pos_cos={diag['pos_cos']:.4f}"
    )
    if diag["retrieval_acc"] < 0.99:
        print("❌ 完美配对时检索命中率应接近 1")
        return 1

    # 塌缩检查：把一侧压成常数，损失必须显著变大（证明防塌缩项真的在起作用）。
    collapsed = F.normalize(torch.ones(16, cfg.proj_dim), dim=-1)
    loss_c, diag_c = alignment_loss(collapsed, u, cfg)
    print(
        f"[selftest] 一侧塌缩(常数) loss={diag_c['loss']:.4f} vs 健康 {diag['loss']:.4f} "
        f"static_std_min={diag_c['static_std_min']:.5f} static_dead={diag_c['static_dead_dims_lt_0.01']}"
    )
    if not diag_c["loss"] > diag["loss"]:
        print("❌ 塌缩表征的损失没有变大 —— 防塌缩项失效")
        return 1

    print("[selftest] ✅ 形状契约 / L2 归一化 / 完美配对 / 塌缩惩罚 全部通过")
    print(f"[selftest] 参数量 static_head={sum(p.numel() for p in ProjectionHead(cfg).parameters()):,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_selftest())
