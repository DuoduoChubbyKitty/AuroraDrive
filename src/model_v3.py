# [TRAINING-ONLY] 此文件仅用于离线训练/导出；运行时由 CoreML / C++ inference 侧执行
# -*- coding: utf-8 -*-
"""
V3 端到端驾驶模型（state-token 多阶段 Transformer + 24 帧混合时序）

本文件是 `docs/v3-design/` 三份设计文档的**整合实现**：
    · `01-backbone.md` —— 视觉骨干 + 多阶段 state-token Transformer 主干
    · `02-temporal.md` —— 24 帧混合分辨率时序模块（3 高清 + 21 低清）
    · `03-output-head.md` —— 离散按键输出头 + 损失函数

============================================================================
一、论文依据（`docs/v3-design/papers/state_aware.txt`，arXiv:2310.20650）
============================================================================
骨架直接来自论文 *Addressing Limitations of State-Aware Imitation Learning
for Autonomous Driving*，三个必须原样保留的机制：

1. **State Token Propagation（§IV.A，:173-207）**
   把车辆自身状态（t−1 的 steer/throttle/brake/speed）做成 Transformer 的一个
   特殊 token，角色等同标准 ViT 的 CLS token（原文 :193），但内容来自**真实测量
   值**而非学出来。相邻 stage 之间**只传递这一枚 state token**（原文 :179-181：
   "taking the output of the encoder corresponding to the state token and
   propagating it as the new state token"），视觉 token 不传 —— 让每个 stage
   都能"带着新问题把图重看一遍"。

2. **Pixel-State Attention（§IV.B，:208-245）**
   卷积骨干输出的特征图拍平成 N 个视觉 token，在序列最前面拼上 state token，
   一起做 self-attention。于是"每个像素都能注意到其他像素 + 车辆状态"
   （原文 :236-237）。这既是多阶段的信息通路，也是内建可解释性的来源。

3. **粗到细的多阶段（§III / §IV.D）**
   stage1 只回答"该停还是该走"（stop/go，不产生控制量），stage2 才生成控制量。
   论文消融（表 IV，Dense 任务）证明这是最关键的机制：**去掉 state token
   成功率 50→20，去掉 stop/go 损失 50→28**。所以两者都必须在。

论文**没有**做的事（我们自己的增量，不能引用论文背书）：多帧历史窗口、
RNN/TCN/时间维 attention、时间位置编码（原文只有空间位置编码 Epos）。
V3 的 24 帧混合时序属新增设计，取舍依据见 `02-temporal.md` 的实测。

============================================================================
二、它解决什么问题（相对 V2 的三处升级）
============================================================================
V2（`src/model_v2.py`）是「四分支各自池化成向量 → 拼接 → MLP」的范式：
图像/车道线/检测框/状态四条支路**只在最后一步融合**，彼此之间没有交互；
时序靠 `IterationRefiner` 的 24 步 GRU 在**特征层**反复精修（并没有看到历史画面）。

V3 换成论文的范式：**所有模态进同一个 token 序列，靠 attention 交互**。
    · 图像 → 336 个视觉 token（14×24 网格，每 token 对应原图 16×16 像素）
    · 车道线 / 检测框 → 各 1 个 token（复用 V2 已验证的编码器，投影到 D 维）
    · 车辆状态 + 24 帧历史摘要 → 1 个 state token
    → 共 339 个 token 一起做 pixel-state attention

三处升级及其理由：
  ① **多模态从"末端拼接"改成"同场 attention"**：车道线 token 可以被某个视觉
     token 直接注意到，不需要把它们压成一个向量再相加。
  ② **时序从"特征层 GRU 迭代"改成"输入层 24 帧混合分辨率"**：V3 真的吃 24 帧
     图像（1.6 秒 @15Hz），历史信息在**输入侧**就完整。
  ③ **输出从"连续油门/刹车"改成"原生按键标签"**：用户要求直接输出
     W/A/S/D/Shift/Space 的按键状态（理由见 §六）。

============================================================================
三、总体结构（shape 全程标注，B = batch，D = 256）
============================================================================
    image_hi [B,3,3,224,384] ─┐
                              ├─ ① 共享 RepVGG 骨干（**一次前向同时产出两种粒度**）
    image_lo [B,21,3,112,192]─┘   高清 3 帧走完整骨干 → 14×24×256 特征图
                                  低清 21 帧只走前 2 层 → 14×24×128 → proj → 256
                                        │ GAP（时序用）/ 末帧空间图（视觉 token 用）
                                        ↓
                                   ┌────┴─────────────────────┐
                                   ↓                          ↓
                    ② 24 帧层级时序                 视觉 token [B,336,256]
                       hist [B,192]                        │
                            │                              │
    vehicle_state [B,8] ────┤ ③ state token               │
                            ↓    = lift(8→256) + hist(192→256, 零初始化)
                        x_state [B,1,256]                  │
    lane [B,1,160,160] → LaneMaskEncoder → lane_tok [B,1,256] ─┤
    dets [B,20,12]+mask → DetectionEncoder → det_tok [B,1,256] ─┤
                            ↓                                  ↓
         tokens = [x_state; lane_tok; det_tok; 336 visual] + Epos   [B,339,256]
                                        │
                              ┌─────────┴──────────┐
                              │ stage1 (depth=5)   │
                              └─────────┬──────────┘
                                        ├→ intent [B,3]  ← 仅训练（§IV.D 的 stop/go）
                                        │   state_token_1 = out1[:,0:1,:] ← §IV.A 传播
                              ┌─────────┴──────────┐
                              │ stage2 (depth=6)   │
                              └─────────┬──────────┘
                                        ↓ out2[:,0,:]（传播后的 state token）
                                  按键输出头（见 §六）

============================================================================
四、关键设计决策与理由（每条都对应一次踩坑或一份实测）
============================================================================
① **为什么骨干用 RepVGG 重参数化块**：训练时 3×3+1×1+identity 三分支提升精度，
   推理时数学等价折叠成单个 3×3 卷积 —— 部署图里没有分支发散、没有额外访存，
   是 ANE 最友好的卷积形态。折叠实现直接复用 `src/model_v2.py:298 RepVGGBlock`
   与 `:417 RepVGGStage`，**不另写一套**（两份实现必然产生数值分歧）。

② **为什么是 4 次 stride-2 → 14×24=336 token**（不是论文的 5 次 → 84 token）：
   224/16=14、384/16=24 均整除，无 ceil 畸形尺寸（180/32=5.6 这类畸形分辨率在
   ANE 上不友好，V2 注释记录过）。而 84 token 实测只有 10.4% 上 ANE
   （`01-backbone.md` §5.3 ②），会整体落 GPU。336 是实测验证过 100% ANE 的档位。

③ **为什么 D=256 / 8 头**：`01-backbone.md` §5.3 ① 实测出 ANE 存在**宽度阈值**
   —— D≤136 只有 10.1% 上 ANE（196 个算子落 GPU），D≥144 才 100%，且把 D=128
   的深度从 4 加到 10 后占比仍只有 4.5~10.1%，证明这是宽度阈值不是算力阈值。
   D=256 远离该阈值。**头数必须是 8 而不是 6**：256/6=42.67 非整数，head_dim
   必须整除；8 头给出 head_dim=32，与 D=192/6 头时的 head_dim 完全一致，
   不引入新的注意力形状风险。

④ **为什么 stage1 深度 5、stage2 深度 6（共 11 块，而不是各 4 块）**：
   三份设计文档在 D=192/depth4×2 下的参数合计只有约 6.80M，而本项目要求的参数
   预算**是 12M**，缺口 5.2M 只能花在骨干或主干上。花在主干是**偏离最小**的
   选择：D、token 数、heads 比例、骨干、时序结构、输出头全部保持文档已验证的
   形态，只放大主干宽度与深度。stage1 略浅、stage2 略深，符合论文
   「stage1 管 stop/go（粗）、stage2 管具体控制（细）」的由粗到细分工。
   ⚠️ 这是**结构决策，不是精度结论** —— 深度 5/6 的精度未经训练验证。

⑤ **为什么低清帧只走骨干前 2 层**：`02-temporal.md` §5.2 实测，24 帧全过完整
   骨干是 21.67 GMACs（混合方案的 4.2 倍），30ms 预算绝无可能。低清 112×192
   本身只有高清 1/4 面积，前 2 层已足以表达"车道线走向/前车位置趋势"。
   低清与高清**共享同一份卷积权重**（真共享，不是两个并行网络），跨分辨率特征
   的语义天然对齐，不需要额外学习对齐模块。

⑥ **为什么全流程禁止形状解包**：`b, n, d = x.shape` 这类写法会被
   `torch.jit.trace` 记录成 `aten::Int` 算子，CoreML 转换直接失败
   （`TypeError: only 0-dimensional arrays can be converted to Python scalars`，
   `01-backbone.md` §5.3 ⑥ 实测）。本文件全程用 `flatten` / `unflatten` /
   `transpose` 这些**纯张量算子**，形状全部由常量（或 -1 推断）决定。

⑦ **为什么不用 `nn.MultiheadAttention` / `F.scaled_dot_product_attention`**：
   前者会把 q/k/v 合并成一次 Linear 再 chunk，导出后产生 `slice_by_index`
   （项目历史实测该算子容易掉 CPU）。这里用三个独立 Linear，**参数量完全相同**，
   但图上没有切片。`scaled_dot_product_attention` 会走融合算子路径，可控性差；
   显式 softmax 的图更可预测。

⑧ **为什么不用 `nn.GRU` / `nn.GRUCell` / `nn.TransformerEncoderLayer`**：
   前两者 trace 出 `while_loop`，项目实测 891 个算子中 453 个掉 CPU、
   ANE 可用 0 个（`ANE_FAIL`）；后者 coremltools 9.0 直接
   `NotImplementedError: '_transformer_encoder_layer_fwd'`。本文件所有循环都是
   Python 层 `for` 循环（trace 时静态展开成固定节点序列），图里 0 个动态控制流。

⑨ **为什么输入参数叫 `vehicle_state` 而不是 `state`**：coremltools 会把名为
   `state` 的输入**静默重命名**为 `state_workaround`（`state` 与 mlprogram 的
   内部概念冲突），Swift 侧按 `state` 取值直接 KeyError。V2 已踩过并记录
   （`model_v2.py:164-168`），V3 沿用 `vehicle_state`。

⑩ **为什么历史摘要走零初始化残差、并且 state 与 hist 分成两条投影**：
   state token 的构成是 `lift(t−1 状态) + hist_residual(历史)`，后者的最后一层
   `hist_proj` **零初始化**。若把 state 与 hist 直接 concat 后过单个 Linear，
   192/200 的输入维度是历史 → 随机初始化下历史项会立刻主导 state token，等于
   "历史注入"变成"历史覆盖"。零初始化后起步 `x_state = 仅 t−1 状态`（与"无历史"
   逐位一致），训练中梯度从零学会该加多少历史 —— 这正是 V2 `temporal_proj`
   踩过的坑（实测修正/基础 ≈ 7.8~50 倍，`model_v2.py:1294-1306`）。

⑪ **为什么高清帧只跑一次骨干**：高清 3 帧既要出"时序用的逐帧向量"，又要出
   "视觉 token 用的空间特征图"。把帧数并进 batch 维跑**一次**骨干，再用
   `adaptive_avg_pool2d` 取逐帧向量、用末帧的空间图出视觉 token，避免同一批
   卷积算两遍（那是白烧 3 帧的算力）。

============================================================================
五、ANE 硬约束清单（改代码前先读这一段）
============================================================================
    ⛔ 禁止 `b,n,d = x.shape` / `reshape(b,c,h*w)`  → 用 flatten/unflatten
    ⛔ 禁止 `nn.GRU` / `nn.LSTMCell` / `nn.TransformerEncoderLayer`
    ⛔ 禁止 `while` / 数据依赖的 `for` / 动态选帧     → 固定 shape
    ⛔ 禁止双边 `clamp`（会被编译成 logical_and，整个模型被踢出 ANE）
    ⛔ CoreML 输入名禁止叫 `state`                    → 用 `vehicle_state`
    ✅ 激活：骨干 ReLU（RepVGG 配方）、Transformer 内 GELU（实测 8/8 上 ANE）
    ✅ 归一化：LayerNorm（实测 16/16 上 ANE）、BatchNorm（折叠进卷积）
    ✅ 注意力：显式 softmax + matmul（实测 100% 上 ANE）

============================================================================
六、输出契约（离散按键，用户需求）
============================================================================
用户需求原文：W=前进 / S=后退 / A=左转 / D=右转 / Shift=手刹 / Space=刹车 /
             Shift+Space 同时按=紧急刹车 / 长按=超级刹车

本模型输出（**全部为 logits**，训练侧直接喂 CE / BCEWithLogitsWithLogits）：
    vertical    [B,3]  W / NONE / S 三分类互斥 logits   ← 满足"不能同时 W 和 S"
    horizontal  [B,3]  A / NONE / D 三分类互斥 logits   ← 录制器保证左右互斥
    handbrake   [B,1]  Shift 手刹
    brake       [B,1]  Space 正常刹车
    super_brake [B,1]  Shift+Space 超级刹车（短按）
    ultimate    [B,1]  Shift+Space+S 极致刹车
    confidence  [B,1]  决策置信度
    risk        [B,1]  场景风险

**为什么纵向/横向拆成两个 3 类而不是一个 4 类 softmax**（Lead 拍板，
`03-output-head.md` §7.1 的实测依据）：录制器把 throttle 与 steer 写成两个独立
列，真实驾驶里 `W+A`（边给油边左转）是同一帧成立的两个事实。单一 4 类 softmax
只能表达 9 种合法组合中的 4 种（44.4%），两个 3 类可表达 9/9（100%），参数量仅
多 194 个。用户原话只约束"不能同时 W 和 S"（纵向互斥），把 A/D 也塞进同一个
softmax 属于理解偏差。

**紧急刹车不设独立头**：它是 `Shift ∧ Space` 的逻辑与，由 `handbrake × brake`
两个 sigmoid 相乘即可表达，加独立头反而破坏"修饰键独立"语义。
**长按超级刹车不作为主输出**：其定义依赖"这段总共按了多少帧"（含未来信息），
作为监督目标存在标签泄漏；由下游按连续帧数累积判定（`03-output-head.md` §6）。

============================================================================
七、训练期专用模块（不进部署图）
============================================================================
    · `intent_head`  [B,256] → [B,3]（GO/SLOW/STOP）论文 stop/go 的对应物
    · `ccm`          [B,7] → [B,6]   按键版 Command Coherency Module

两者都在 `get_param_count()` 里单列，导出时由 `export_coreml()` 不输出。
CCM **必须先单独训到收敛再冻结**（`03-output-head.md` §3.4 实测：不冻结时首层
梯度范数 0.007066 会被主损失带偏，等于"用一把自己在动的尺子量自己"）。
本文件提供 `freeze_ccm()` 显式执行冻结。

============================================================================
八、未测项（诚实清单，与 04-model-code.md 一致）
============================================================================
    1. **训练后的精度**：本文件只做结构与部署验证，未训练任何权重。
    2. **深度 5/6 与 D=256 的精度收益**：填预算的结构决策，未做精度对照。
    3. **换骨干后 02-backbone 的延迟数字全部失效**：`02-temporal.md` 的
       p50 2.06ms / p95 3.30ms 是在 `model_v2.ImageEncoder`（5 stage、256 维）上
       测的；本文件用 `01-backbone.md` 的 RepVGG 骨干（4 次 stride-2、14×24），
       骨干不同 → **必须重测，不得沿用**。
    4. **真机端到端延迟**：只测 CoreML 纯推理，不含预处理/调度/与 yolopx 竞争。
    5. **4-bit 量化误差**：未做量化后精度验证。
    6. **lane/dets 两路 token 的实际收益**：01/02 文档都未设计这两路的接入方式，
       "各投影成 1 个 token 放进序列"是整合时的设计决定，**未做精度验证**。
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

# ── 复用 V2 已验证的实现（只读 import，不改 model_v2.py 任何一行）──────────
# 为什么用双路径导入：本文件既可被 `from src.model_v3 import ...` 导入（包内路径），
# 也可被 `python3 src/model_v3.py` 直接运行（sys.path[0] = src/，包路径不可用）。
# 只支持单一路径会让"以脚本方式运行"时直接 ImportError
# （model_v2.py:201-216 记录过这个陷阱）。
try:                                        # ① 包内路径
    from src.model_v2 import (
        RepVGGBlock,
        RepVGGStage,
        LaneMaskEncoder,
        DetectionEncoder,
    )
except ImportError:                         # ② 脚本运行回退
    from model_v2 import (                  # type: ignore[no-redef]
        RepVGGBlock,
        RepVGGStage,
        LaneMaskEncoder,
        DetectionEncoder,
    )


# ============================================================================
# 0. 默认超参数与输入契约（集中定义，便于训练/导出/文档三侧对齐）
# ============================================================================

#: 高清帧分辨率（224/16=14、384/16=24 均整除 → 特征图无畸形尺寸）
IMG_HI_H: int = 224
IMG_HI_W: int = 384
#: 低清帧分辨率（112 走 2 个 stage → 28；192 → 48，均整除）
IMG_LO_H: int = 112
IMG_LO_W: int = 192
#: 高清帧数（最近 3 帧：t / t−1 / t−2）
NUM_HI_FRAMES: int = 3
#: 低清帧数（t−3 … t−24）
NUM_LO_FRAMES: int = 21
#: 时序总窗口 = 3 + 21 = 24 帧（@15Hz ≈ 1.6 秒）
NUM_TOTAL_FRAMES: int = NUM_HI_FRAMES + NUM_LO_FRAMES
#: 车道线掩码边长（对齐 V2 的 Swift `MaskGrid` 160×160）
LANE_SIZE: int = 160
#: 检测框固定槽位数（空槽补 0 + det_mask=0）
MAX_DETECTIONS: int = 20
#: 单框特征维度（★ 12，不是 13；布局见 model_v2.DetectionEncoder 文档）
DET_FEAT_DIM: int = 12
#: 车辆状态维度
STATE_DIM: int = 8

#: 骨干各 stage 输出通道（4 次 stride-2：32 → 64 → 128 → 256）
STEM_CHANNELS: int = 32
STAGE_CHANNELS: Tuple[int, ...] = (64, 128, 256)
#: 骨干各 stage 的 RepVGGBlock 数（对齐 01-backbone.md §3.1 的 2/3/4）
STAGE_BLOCKS: Tuple[int, ...] = (2, 3, 4)

#: Transformer 主干宽度（ANE 宽度阈值 D≥144，256 远高于阈值）
MODEL_DIM: int = 256
#: 注意力头数（256/8=32，head_dim 整除，与 D=192/6 头的 head_dim 一致）
NUM_HEADS: int = 8
#: stage1 / stage2 深度（见文件头 §四④ 的预算论证）
STAGE1_DEPTH: int = 5
STAGE2_DEPTH: int = 6
#: FFN 扩张比（D→4D→D）
MLP_RATIO: float = 4.0

#: 时序模块隐藏维度（02-temporal.md 推荐值 192；最后经 hist_proj 投到 D=256）
TEMPORAL_HIDDEN: int = 192
#: 段内帧数（3 段 × 8 帧 = 24 帧）
TEMPORAL_GROUP: int = 8

#: 输出头隐藏层（03-output-head.md §2.2 的 192→96）
HEAD_HIDDEN1: int = 192
HEAD_HIDDEN2: int = 96
#: 训练期意图头隐藏层
INTENT_HIDDEN: int = 64
#: CCM 隐藏层与输入维度（7 = 6 键 + 速度）
CCM_HIDDEN: int = 64
CCM_IN_DIM: int = 7
#: CCM 输出维度（6 键的下一帧状态）
CCM_OUT_DIM: int = 6

#: 非视觉 token 数量：state token(1) + lane token(1) + det token(1) = 3
NUM_PREFIX_TOKENS: int = 3

#: lane / det 编码器输出维度（与 V2 的 FUSION 契约一致：64 / 128）
LANE_FEAT_DIM: int = 64
DET_FEAT_DIM_OUT: int = 128


# ============================================================================
# 1. 配置
# ============================================================================

@dataclass
class V3Config:
    """V3 模型全部结构超参（默认值 = 三份设计文档 + 12M 预算的定案配置）。

    为什么用 dataclass 集中管理而不是散落的常量：训练脚本/导出脚本/消融实验
    都要能改单个字段而不动代码（例如把 stage1_depth 调回 4 做对照）。
    """

    # ── 输入 ──
    image_hi_h: int = IMG_HI_H
    image_hi_w: int = IMG_HI_W
    image_lo_h: int = IMG_LO_H
    image_lo_w: int = IMG_LO_W
    num_hi_frames: int = NUM_HI_FRAMES
    num_lo_frames: int = NUM_LO_FRAMES
    lane_size: int = LANE_SIZE
    max_detections: int = MAX_DETECTIONS
    det_feat_dim: int = DET_FEAT_DIM
    state_dim: int = STATE_DIM

    # ── RepVGG 骨干 ──
    in_channels: int = 3
    stem_channels: int = STEM_CHANNELS
    stage_channels: Tuple[int, ...] = STAGE_CHANNELS
    stage_blocks: Tuple[int, ...] = STAGE_BLOCKS
    #: 低清帧走骨干的前几个 stage（2 = stem + stage[0] + stage[1]）
    lores_stages: int = 2

    # ── Transformer 主干 ──
    dim: int = MODEL_DIM
    heads: int = NUM_HEADS
    stage1_depth: int = STAGE1_DEPTH
    stage2_depth: int = STAGE2_DEPTH
    mlp_ratio: float = MLP_RATIO

    # ── 时序 ──
    temporal_hidden: int = TEMPORAL_HIDDEN
    temporal_group: int = TEMPORAL_GROUP

    # ── 输出头 ──
    head_hidden1: int = HEAD_HIDDEN1
    head_hidden2: int = HEAD_HIDDEN2
    intent_hidden: int = INTENT_HIDDEN
    ccm_hidden: int = CCM_HIDDEN

    # ── 正则 ──
    #: 状态噪声注入 σ（论文值：控制量 0.1 / 速度 1.0；只在训练态施加）
    state_noise_sigma_ctrl: float = 0.1
    state_noise_sigma_speed: float = 1.0
    #: 是否启用状态噪声注入（论文 §IV.A :198-203；图 7：离线/在线相关性 −0.64→−0.92）
    enable_state_noise: bool = True

    # ── 计算属性 ──
    def total_frames(self) -> int:
        """时序窗口总帧数（必须能被 temporal_group 整除，否则段内卷积丢帧）。"""
        return self.num_hi_frames + self.num_lo_frames

    def feature_hw(self) -> Tuple[int, int]:
        """高清帧过完整骨干后的特征图 (H, W)。

        下采样次数 = 1（stem）+ len(stage_channels)（每个 stage 一次 stride-2）。
        """
        stride_total = 2 ** (1 + len(self.stage_channels))
        n_h = self.image_hi_h // stride_total
        n_w = self.image_hi_w // stride_total
        if n_h * stride_total != self.image_hi_h or n_w * stride_total != self.image_hi_w:
            raise ValueError(
                f"高清输入 {self.image_hi_h}×{self.image_hi_w} 不能被 {stride_total} "
                f"整除，会得到畸形特征图 {self.image_hi_h / stride_total:.1f}×"
                f"{self.image_hi_w / stride_total:.1f}（ANE 不友好）。"
                f"请改用可整除的分辨率或调整下采样次数。")
        return n_h, n_w

    def num_visual_tokens(self) -> int:
        """视觉 token 数（14×24=336）。"""
        n_h, n_w = self.feature_hw()
        return n_h * n_w

    def num_tokens(self) -> int:
        """送进 Transformer 的总 token 数（3 个前缀 token + 336 视觉 token）。"""
        return NUM_PREFIX_TOKENS + self.num_visual_tokens()

    def lores_out_channels(self) -> int:
        """低清帧走前 `lores_stages` 个 stage 后的输出通道数。

        lores_stages=2 → 走 stem + stage[0] + stage[1] → stage_channels[1] = 128。
        """
        if self.lores_stages <= 0:
            return self.stem_channels
        return self.stage_channels[self.lores_stages - 1]

    def validate(self) -> None:
        """启动即校验配置自洽（fail-fast，而不是训练到一半才炸）。"""
        if self.dim % self.heads != 0:
            raise ValueError(
                f"dim={self.dim} 不能被 heads={self.heads} 整除"
                f"（head_dim={self.dim / self.heads:.2f} 非整数，注意力 reshape 会失败）")
        if self.dim < 144:
            # 01-backbone.md §5.3 ①：D≤136 实测只有 10.1% 算子派到 ANE
            raise ValueError(
                f"dim={self.dim} < 144：实测该宽度下 ANE 派发率只有约 10%"
                f"（其余落 GPU），这是宽度阈值不是算力阈值。请用 D≥144。")
        if self.total_frames() % self.temporal_group != 0:
            raise ValueError(
                f"时序窗口 {self.total_frames()} 帧不能被段长 "
                f"{self.temporal_group} 整除，段内卷积会丢帧")
        if not (0 <= self.lores_stages <= len(self.stage_channels)):
            raise ValueError(
                f"lores_stages={self.lores_stages} 超出 [0, {len(self.stage_channels)}]")
        if self.num_hi_frames < 1 or self.num_lo_frames < 0:
            raise ValueError("num_hi_frames 必须 ≥1，num_lo_frames 必须 ≥0")


# ============================================================================
# 2. 视觉骨干：RepVGG 重参数化（224×384 → 14×24×256）
# ============================================================================

class RepVGGVisualBackbone(nn.Module):
    """4 次 stride-2 的 RepVGG 视觉骨干（训练多分支 / 推理折叠为纯 3×3）。

    分辨率演进（高清输入 224×384）：
        stem       stride2 →  32ch @ 112×192
        stages[0]  stride2 →  64ch @  56×96    × 2 blocks
        stages[1]  stride2 → 128ch @  28×48    × 3 blocks
        stages[2]  stride2 → 256ch @  14×24    × 4 blocks  ← 输出 14×24 = 336 token

    低清输入 112×192 走 stem + 前 2 个 stage（forward_truncated）：
        stem       stride2 →  32ch @  56×96
        stages[0]  stride2 →  64ch @  28×48
        stages[1]  stride2 → 128ch @  14×24                ← 输出 128ch @ 14×24

    为什么复用 `model_v2.RepVGGBlock/RepVGGStage` 而不重写：折叠逻辑（BN 折进
    卷积、1×1 pad 成 3×3、identity 折算）是数值敏感的，两份实现必然产生分歧。
    V2 的折叠已实测等价（最大相对误差 8.6e-07）。

    shape：
        高清  image_hi: [N, 3, 224, 384] → [N, 256, 14, 24]
        低清  image_lo: [N, 3, 112, 192] → [N, 128, 14, 24]（forward_truncated）
    """

    def __init__(self, cfg: V3Config, deploy: bool = False):
        super().__init__()
        self.cfg = cfg
        self.out_channels = cfg.stage_channels[-1]

        # stem 单独拿出来：低清帧要"只走前 N 层"，需要能逐层调用的结构
        self.stem = RepVGGBlock(
            cfg.in_channels, cfg.stem_channels, stride=2, deploy=deploy)
        # 后续每个 stage：若干个 RepVGGBlock，第 0 个负责下采样
        self.stages = nn.ModuleList([
            RepVGGStage(
                cfg.stem_channels if i == 0 else cfg.stage_channels[i - 1],
                out_ch, n_blocks, stride=2, deploy=deploy)
            for i, (out_ch, n_blocks) in enumerate(
                zip(cfg.stage_channels, cfg.stage_blocks))
        ])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """完整骨干：x [N,3,224,384] → [N,256,14,24]"""
        y = self.stem(x)
        for stage in self.stages:      # Python 循环：trace 时静态展开
            y = stage(y)
        return y

    def forward_truncated(self, x: torch.Tensor) -> torch.Tensor:
        """截断骨干：只走 stem + 前 `cfg.lores_stages` 个 stage（低清帧用）。

        为什么低清走截断而不是完整骨干：`02-temporal.md` §5.2 实测，21 帧低清
        全过完整骨干会让总 MACs 从 5.19G 涨到 21.67G（4.2 倍），30ms 预算不可能。
        """
        y = self.stem(x)
        for i, stage in enumerate(self.stages):
            if i >= self.cfg.lores_stages:
                break
            y = stage(y)
        return y

    def reparameterize(self) -> None:
        """训练态 → 部署态：所有 RepVGGBlock 的三分支折叠成单个 3×3 卷积。

        折叠后参数量与推理耗时都会下降（BN 折进卷积，少一层访存），数学等价。
        """
        for m in self.modules():
            if isinstance(m, RepVGGBlock):
                m.reparameterize()


# ============================================================================
# 3. Transformer 主干（pixel-state attention 的载体）
# ============================================================================

class TransformerBlock(nn.Module):
    """Pre-LN Transformer 编码块。

    结构（与论文的 encoder layer 同构，但全部手工搭建）：
        x = x + Attn(LN(x))
        x = x + FFN(LN(x))

    为什么 pre-LN 而不是 post-LN：pre-LN 梯度更稳、深层（本模型 stage2 有 6 层）
    不易发散；且 LayerNorm 在 ANE 上是原生算子（01-backbone.md §5.2 实测 16/16）。

    为什么 q/k/v 用三个独立 Linear 而不是 nn.MultiheadAttention：后者把 qkv
    合并成一次 Linear 再 chunk，导出后产生 `slice_by_index` 算子（项目实测该算子
    容易掉 CPU）。独立 Linear **参数量完全相同**，但图上没有切片。

    shape：x [B, N, D] → [B, N, D]
    """

    def __init__(self, dim: int, heads: int, mlp_ratio: float = 4.0):
        super().__init__()
        if dim % heads != 0:
            raise ValueError(f"dim={dim} 不能被 heads={heads} 整除")
        self.dim = dim
        self.heads = heads
        self.head_dim = dim // heads
        #: 注意力缩放（1/√head_dim，Python float 常量，进图后是常量乘法）
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
            nn.GELU(),          # GELU 在 ANE 上实测 8/8 原生支持
            nn.Linear(hidden, dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """x: [B,N,D] → [B,N,D]

        ⚠️ 全程不用 `b, n, d = x.shape`（见文件头 §四⑥）：用 unflatten/flatten/
           transpose 这些纯张量算子，形状全由常量决定，导出图里没有 int 转换节点。
        """
        h = self.norm1(x)

        # [B,N,D] → [B,N,heads,head_dim] → [B,heads,N,head_dim]
        q = self.q_proj(h).unflatten(2, (self.heads, self.head_dim)).transpose(1, 2)
        k = self.k_proj(h).unflatten(2, (self.heads, self.head_dim)).transpose(1, 2)
        v = self.v_proj(h).unflatten(2, (self.heads, self.head_dim)).transpose(1, 2)

        # 显式 softmax + matmul（不用 scaled_dot_product_attention：导出图更可控）
        attn = torch.softmax((q @ k.transpose(-1, -2)) * self.scale, dim=-1)
        # [B,heads,N,head_dim] → [B,N,D]：transpose 后 flatten(2) 自动合并最后两维
        ctx = (attn @ v).transpose(1, 2).flatten(2)

        x = x + self.out_proj(ctx)
        x = x + self.ffn(self.norm2(x))
        return x


class TransformerEncoderStage(nn.Module):
    """一个 stage = depth 个 TransformerBlock 堆叠。

    ⚠️ 这里的 `for blk in self.blocks` 是 **Python 层循环**：`torch.jit.trace`
    会把它展开成 depth 个独立节点，图里**没有循环算子**。这与项目实测的
    `while_loop` 导致 ANE_FAIL（891 算子中 453 掉 CPU）是完全不同的东西。
    """

    def __init__(self, dim: int, depth: int, heads: int, mlp_ratio: float = 4.0):
        super().__init__()
        self.blocks = nn.ModuleList(
            [TransformerBlock(dim, heads, mlp_ratio) for _ in range(depth)])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        for blk in self.blocks:
            x = blk(x)
        return x


# ============================================================================
# 4. 24 帧混合时序模块（3 高清 + 21 低清 → 历史摘要）
# ============================================================================

class TemporalModuleV3(nn.Module):
    """24 帧混合分辨率时序模块：层级融合（3 段 × 8 帧 + TCN 段间）。

    为什么是层级融合而不是 24 步 unroll GRU / 24 帧 TCN / 时间维 attention
    （`02-temporal.md` §2.1 实测对比）：
        · 层级方案 MACs 1.60M，是 4 层因果 TCN（10.67M）的 **15%**
        · 24 步 unroll GRU 递推链 24 步、图中 573 个算子，作为整图一部分会让图
          过深；层级方案把段间递推压到 2 层卷积
        · 时间维 attention 手写版「ALL 比 CPU 慢 3.8×」（小张量在 ANE 上搬运开销
          大于计算收益），且 `nn.TransformerEncoderLayer` 直接无法转换

    核心思路：段内 `Conv1d(k=8, stride=8)` 一次性把 8 帧压成 1 个段 token，
    之后所有段间计算只作用在 3 个 token 上，而不是 24 个 —— 这是算力省 6.7 倍
    的根本原因。

    时间位置编码（必须显式编码，`02-temporal.md` §4.2）：
        段内卷积 + 段池化后，模型无法区分"这段是最近还是最远"。因果卷积只保证
        不看未来，不保证知道远近。所以给 24 帧特征加可学习 `time_emb [24, hidden]`。

    shape：
        f_hi: [B, 3,  C_in]  最近 3 帧高清特征（t / t−1 / t−2）
        f_lo: [B, 21, C_in]  前 21 帧低清特征（t−3 … t−24）
        hist: [B, hidden]    24 帧历史摘要
    """

    def __init__(self, in_dim: int, hidden: int, num_frames: int,
                 group: int = TEMPORAL_GROUP):
        super().__init__()
        if num_frames % group != 0:
            raise ValueError(f"帧数 {num_frames} 不能被段长 {group} 整除")
        self.in_dim = in_dim
        self.hidden = hidden
        self.num_frames = num_frames
        self.group = group
        self.num_segments = num_frames // group

        # 帧特征 → 时序隐藏维度（逐帧独立，等价 Conv1d k=1）
        self.in_proj = nn.Linear(in_dim, hidden)

        # 可学习时间位置编码（24 × hidden）。为什么不用正弦编码：15Hz 固定采样下
        # 没有外推到更长窗口的需求，可学习编码更灵活（02-temporal.md §4.2）。
        self.time_emb = nn.Parameter(torch.zeros(1, num_frames, hidden))
        nn.init.trunc_normal_(self.time_emb, std=0.02)

        # 段内融合：8 帧 → 1 个段 token
        self.seg_conv = nn.Conv1d(hidden, hidden, kernel_size=group, stride=group)
        # 段间因果膨胀卷积（dilation 1 / 2，感受野覆盖 3 段）。
        # 因果 = 只在左侧 padding，所以输出末位"看到了全部已发生的段"。
        self.inter_convs = nn.ModuleList([
            nn.Conv1d(hidden, hidden, kernel_size=3, dilation=d, padding=2 * d)
            for d in (1, 2)
        ])
        self.out_norm = nn.LayerNorm(hidden)

    def forward(self, f_hi: torch.Tensor, f_lo: torch.Tensor) -> torch.Tensor:
        """f_hi [B,3,C] + f_lo [B,21,C] → hist [B,hidden]

        时间序：按 (t, t−1, t−2, t−3, …, t−24) 拼接 —— 最新帧在最前。
        """
        seq = torch.cat([f_hi, f_lo], dim=1)                 # [B,24,C_in]
        seq = self.in_proj(seq)                              # [B,24,hidden]
        seq = seq + self.time_emb                            # 加时间位置编码

        # [B,24,hidden] → [B,hidden,24]（Conv1d 要求通道在 dim1）
        x = seq.transpose(1, 2)
        x = F.relu(self.seg_conv(x))                         # [B,hidden,3] 段 token

        for conv in self.inter_convs:                        # 段间因果膨胀卷积
            x = F.relu(conv(x))                              # [B,hidden,3+2d]
            # 因果：只取最后一位（它已聚合全部历史段），保持 shape 固定。
            # 之所以能这么取：左侧 padding=2*d 使末位恰好覆盖全部段 token。
            x = x[:, :, -1:]

        hist = x.squeeze(2)                                  # [B,hidden]
        return self.out_norm(hist)


# ============================================================================
# 5. 输出头（离散按键）
# ============================================================================

class V3OutputHead(nn.Module):
    """离散按键输出头：state token [B,D] → 8 路输出（见文件头 §六）。

    结构（03-output-head.md §2.1/§2.2）：
        trunk: Linear(D→192) → ReLU → Dropout(0.1) → Linear(192→96) → ReLU
        然后 8 个独立头，**全部输出 logits**。

    为什么纵向/横向各用 3 类 softmax：见文件头 §六（4 类只能表达 9 种合法组合
    中的 4 种）。为什么修饰键用独立 sigmoid：Shift 与 Space 是**可同时成立的
    独立事件**，不是互斥类（V2 的 risk_head 已确立该约定：softmax 给互斥多类，
    sigmoid 给单值独立量）。

    shape：x [B,D] → dict（vertical[B,3] / horizontal[B,3] / 其余 [B,1]）
    """

    def __init__(self, dim: int, hidden1: int = HEAD_HIDDEN1,
                 hidden2: int = HEAD_HIDDEN2, dropout: float = 0.1):
        super().__init__()
        self.trunk = nn.Sequential(
            nn.Linear(dim, hidden1),
            nn.ReLU(inplace=True),
            nn.Dropout(dropout),
            nn.Linear(hidden1, hidden2),
            nn.ReLU(inplace=True),
        )
        # 纵向：W / NONE / S（互斥，满足"不能同时 W 和 S"）
        self.vertical = nn.Linear(hidden2, 3)
        # 横向：A / NONE / D（互斥，录制器的 left&&!right 已保证）
        self.horizontal = nn.Linear(hidden2, 3)
        # 四个修饰/安全键：独立 sigmoid（B,1）
        self.handbrake = nn.Linear(hidden2, 1)      # Shift
        self.brake = nn.Linear(hidden2, 1)          # Space
        self.super_brake = nn.Linear(hidden2, 1)    # Shift+Space 短按
        self.ultimate = nn.Linear(hidden2, 1)       # Shift+Space+S
        self.confidence = nn.Linear(hidden2, 1)
        self.risk = nn.Linear(hidden2, 1)
        self._init_weights()

    def _init_weights(self) -> None:
        """fan_in 初始化 + 零 bias + 两个安全头的特定 bias。

        为什么 fan_in 而不是 fan_out（model_v2.py:856-859 记录的坑）：
          fan_out 对 (96→1) 输出头给出 std=√(2/1)=1.414，会让 sigmoid 一上来就
          饱和、梯度归零、训练直接冻结（旧 model.py 踩过）。
        为什么 risk/confidence 用特定 bias（03-output-head.md §2.5 / risk_head.py:207）：
          risk bias=log(0.1/0.9)≈−2.197 → 起步时风险≈0.1，避免一上来疯狂请求接管；
          confidence bias=log(0.6/0.4)≈0.405 → 起步时置信度≈0.6。
        """
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, mode='fan_in', nonlinearity='relu')
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
        nn.init.constant_(self.risk.bias, -2.197224577)         # log(0.1/0.9)
        nn.init.constant_(self.confidence.bias, 0.405465108)    # log(0.6/0.4)

    def forward(self, state_token: torch.Tensor) -> Dict[str, torch.Tensor]:
        """state_token [B,D] → 8 路 logits。"""
        h = self.trunk(state_token)
        return {
            "vertical": self.vertical(h),          # [B,3] W/NONE/S
            "horizontal": self.horizontal(h),      # [B,3] A/NONE/D
            "handbrake": self.handbrake(h),        # [B,1]
            "brake": self.brake(h),                # [B,1]
            "super_brake": self.super_brake(h),    # [B,1]
            "ultimate": self.ultimate(h),          # [B,1]
            "confidence": self.confidence(h),      # [B,1]
            "risk": self.risk(h),                  # [B,1]
        }


class IntentHead(nn.Module):
    """训练期意图头：state token [B,D] → [B,3]（GO / SLOW / STOP）。

    这是论文 stage1 stop/go 的对应物（§IV.D 公式 (2)）。论文消融（表 IV，Dense）
    证明「同样 state-aware、只去掉 stop/go 损失，成功率 50→28」——
    **这是抗 inertia 的主手段，不能省**。

    ⚠️ **仅训练用，不进部署图**（与论文一致：stage1 输出不是控制量，
       它的信息通过 state token 传播给 stage2）。
    """

    def __init__(self, dim: int, hidden: int = INTENT_HIDDEN):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(dim, hidden),
            nn.ReLU(inplace=True),
            nn.Linear(hidden, 3),
        )

    def forward(self, state_token: torch.Tensor) -> torch.Tensor:
        return self.net(state_token)      # [B,3] logits（GO/SLOW/STOP）


class CommandCoherencyModule(nn.Module):
    """按键版 CCM（论文 §IV.C 的移植）：t 时刻 6 键 + 速度 → t+1 时刻 6 键。

    论文原版是「控制量组合 → 下一帧速度」，用来惩罚自相矛盾的控制组合
    （同时大油门大刹车）。我们的输出是离散键，没有"下一帧速度"这个监督目标，
    所以换成「6 键 @t → 6 键 @t+1」—— 语义等价：惩罚"当前按键组合推不出下一帧
    真实按键"的组合。

    ⚠️ **两阶段训练法（必须按此顺序，03-output-head.md §3.4 有实测证据）**：
        ① 先在训练集上把 CCM 单独训到收敛；
        ② 再冻结（`freeze_ccm()`），作为正则项接入主损失。
       实测不冻结时首层梯度范数 = 0.007066（非零）—— 相干性判据本身在漂移，
       等于"用一把自己在动的尺子量自己"。冻结后梯度 = 0.000000。
    """

    def __init__(self, in_dim: int = CCM_IN_DIM, hidden: int = CCM_HIDDEN,
                 out_dim: int = CCM_OUT_DIM):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_dim, hidden),
            nn.ELU(),
            nn.Linear(hidden, hidden),
            nn.ELU(),
            nn.Linear(hidden, out_dim),
        )

    def forward(self, keys_and_speed: torch.Tensor) -> torch.Tensor:
        """[B,7] → [B,6]（下一帧 6 键状态）"""
        return self.net(keys_and_speed)


# ============================================================================
# 6. 完整模型
# ============================================================================

class V3Model(nn.Module):
    """V3 端到端驾驶模型（论文 state-token 多阶段架构 + 24 帧混合时序）。

    forward 入参：
        image_hi:      [B, 3, 3, 224, 384]   最近 3 帧高清（必填）
        image_lo:      [B, 21, 3, 112, 192]  前 21 帧低清（必填）
        lane:          [B, 1, 160, 160]      车道线掩码（None → 零 token）
        dets:          [B, 20, 12]           检测框（None / N=0 → 零 token）
        det_mask:      [B, 20]               1=有效框
        vehicle_state: [B, 8]                t−1 车辆状态（None → 零向量）

    forward 返回（dict，全部 logits）：
        vertical / horizontal / handbrake / brake / super_brake / ultimate /
        confidence / risk                                    见文件头 §六

    为什么 lane/dets 也做成 token（01/02 文档都未设计这两路的接入）：
      论文的 pixel-state attention 天然支持"序列里混入非视觉 token"。把车道线、
      检测框各投影成 1 个 token 放进序列，它们就能被任何视觉 token 直接 attend
      （而不是像 V2 那样压成向量在末端拼接）。02-temporal.md §4.3 实测：
      多 1 个 token 只增加 0.4% 注意力算力，代价可忽略。
      ⚠️ 这是整合时的设计决定，**未做精度验证**（见文件头 §八 第 6 项）。
    """

    def __init__(self, cfg: Optional[V3Config] = None, deploy: bool = False):
        super().__init__()
        self.cfg = cfg or V3Config()
        self.cfg.validate()
        c = self.cfg
        self.deploy = deploy

        # ── ① 视觉骨干（高清/低清共享同一份卷积权重）──
        self.backbone = RepVGGVisualBackbone(c, deploy=deploy)
        #: 低清截断骨干输出通道（128）→ 骨干输出通道（256），让两种分辨率落在同一空间
        self.lores_proj = nn.Linear(
            c.lores_out_channels(), self.backbone.out_channels)

        # ── ② 视觉 token 投影：骨干通道 → D ──
        self.token_proj = nn.Linear(self.backbone.out_channels, c.dim)

        # ── ③ 24 帧混合时序 ──
        self.temporal = TemporalModuleV3(
            in_dim=self.backbone.out_channels,
            hidden=c.temporal_hidden,
            num_frames=c.total_frames(),
            group=c.temporal_group)
        #: state token 初始化：t−1 状态标量 → D（论文 :223-234 的"各标量升维再拼"
        #: 的等价推广：单 Linear 在图上只有 1 个 matmul，无 concat/slice）
        self.state_token_proj = nn.Linear(c.state_dim, c.dim)
        #: 历史摘要 → state token 的**零初始化残差**（见文件头 §四⑩）。
        #: 为什么不把 state 与 hist concat 后过单个 Linear：192/200 的输入维度是
        #: 历史，随机初始化下历史会立刻主导 state token，等于"注入"变"覆盖"。
        self.hist_proj = nn.Linear(c.temporal_hidden, c.dim)
        nn.init.zeros_(self.hist_proj.weight)
        nn.init.zeros_(self.hist_proj.bias)

        # ── ④ 车道线 / 检测框 token（复用 V2 已验证的编码器）──
        self.lane_encoder = LaneMaskEncoder(out_dim=LANE_FEAT_DIM)
        self.det_encoder = DetectionEncoder(out_dim=DET_FEAT_DIM_OUT)
        self.lane_token_proj = nn.Linear(LANE_FEAT_DIM, c.dim)
        self.det_token_proj = nn.Linear(DET_FEAT_DIM_OUT, c.dim)

        # ── ⑤ 可学习位置编码（论文 Eq.(1) 的 Epos）──
        #: [1, 总 token 数, D]；覆盖 state/lane/det/visual 全部 token
        self.pos_emb = nn.Parameter(torch.zeros(1, c.num_tokens(), c.dim))
        nn.init.trunc_normal_(self.pos_emb, std=0.02)

        # ── ⑥ 多阶段主干（stage1 → intent，stage2 → 控制）──
        self.stage1 = TransformerEncoderStage(
            c.dim, c.stage1_depth, c.heads, c.mlp_ratio)
        self.stage2 = TransformerEncoderStage(
            c.dim, c.stage2_depth, c.heads, c.mlp_ratio)

        # ── ⑦ 输出头 ──
        self.output_head = V3OutputHead(c.dim, c.head_hidden1, c.head_hidden2)

        # ── ⑧ 训练期专用（不进部署图）──
        self.intent_head = IntentHead(c.dim, c.intent_hidden)
        self.ccm = CommandCoherencyModule()

        # ── 契约常量（供 Swift/导出脚本读取）──
        self.num_visual_tokens = c.num_visual_tokens()
        self.num_tokens = c.num_tokens()

    # ------------------------------------------------------------------
    # 内部：特征编码
    # ------------------------------------------------------------------

    def _encode_hi(self, image_hi: torch.Tensor,
                   batch_size: int) -> Tuple[torch.Tensor, torch.Tensor]:
        """高清帧 [B,T,3,H,W] → (逐帧向量 [B,T,C], 末帧空间图 [B,C,h,w])。

        为什么一次骨干前向同时产出两种粒度：3 帧既要"时序用的逐帧向量"（GAP），
        又要"视觉 token 用的空间特征图"（末帧 t）。把帧数并进 batch 维跑一次，
        再分别 pooling / 取末帧，避免同一批卷积算两遍（那是白烧 3 帧的算力）。

        `unflatten(0, (-1, T))` 用常量 -1 推断 batch，不读 shape（见文件头 §四⑥）。
        """
        flat = image_hi.flatten(0, 1)                     # [B*T, 3, H, W]
        feats = self.backbone(flat)                       # [B*T, C, 14, 24]
        # 逐帧向量：全局平均池化（ANE 原生算子）
        pooled = F.adaptive_avg_pool2d(feats, 1).flatten(1)          # [B*T, C]
        f_hi = pooled.unflatten(0, (-1, self.cfg.num_hi_frames))     # [B, T, C]
        # 末帧空间图：时间序第一帧 = 当前帧 t（见 TemporalModuleV3 的时间序约定）
        feat_t = feats.unflatten(0, (-1, self.cfg.num_hi_frames))[:, 0]  # [B,C,14,24]
        return f_hi, feat_t

    def _encode_lo(self, image_lo: torch.Tensor) -> torch.Tensor:
        """低清帧 [B,T,3,H,W] → 逐帧向量 [B,T,C]。

        低清只走骨干前 `lores_stages` 个 stage（省算力的关键，见文件头 §四⑤），
        再用 `lores_proj` 投影到骨干输出通道，与高清特征落在同一语义空间。
        """
        flat = image_lo.flatten(0, 1)                     # [B*21, 3, H, W]
        feats = self.backbone.forward_truncated(flat)     # [B*21, 128, 14, 24]
        pooled = F.adaptive_avg_pool2d(feats, 1).flatten(1)          # [B*21, 128]
        pooled = self.lores_proj(pooled)                             # [B*21, 256]
        return pooled.unflatten(0, (-1, self.cfg.num_lo_frames))     # [B, 21, 256]

    def _build_state_token(self, vehicle_state: torch.Tensor,
                           hist: torch.Tensor) -> torch.Tensor:
        """t−1 状态 + 24 帧历史摘要 → state token [B,1,D]。

        构成：`lift(t−1 状态) + hist_residual(历史)`，后者最后一层零初始化。
        零初始化后起步 `x_state = 仅 t−1 状态`（与"无历史"逐位一致），
        训练中梯度从零学会该加多少历史（见文件头 §四⑩）。
        """
        x_state = self.state_token_proj(vehicle_state)     # [B,D]
        x_state = x_state + self.hist_proj(hist)           # 零初始化 → 起步为 0
        return x_state.unsqueeze(1)                        # [B,1,D]

    def _build_prefix_tokens(self, lane: Optional[torch.Tensor],
                             dets: Optional[torch.Tensor],
                             det_mask: Optional[torch.Tensor],
                             batch_size: int,
                             ref: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        """构造 lane / det 两个 token：[B,1,D] 各一。

        复用 V2 的 `LaneMaskEncoder` / `DetectionEncoder`（它们已处理
        None / 全零 / 0 个框三种空输入，返回同 shape 零向量 —— 这是运行时
        真实会发生的输入，比如刚开局没有检测框）。
        """
        lane_feat = self.lane_encoder(lane, batch_size, ref)          # [B,64]
        det_feat = self.det_encoder(dets, det_mask, batch_size, ref)  # [B,128]
        lane_tok = self.lane_token_proj(lane_feat).unsqueeze(1)       # [B,1,D]
        det_tok = self.det_token_proj(det_feat).unsqueeze(1)          # [B,1,D]
        return lane_tok, det_tok

    # ------------------------------------------------------------------
    # 前向
    # ------------------------------------------------------------------

    def forward(self,
                image_hi: torch.Tensor,
                image_lo: torch.Tensor,
                lane: Optional[torch.Tensor] = None,
                dets: Optional[torch.Tensor] = None,
                det_mask: Optional[torch.Tensor] = None,
                vehicle_state: Optional[torch.Tensor] = None,
                return_intent: bool = False,
                return_prob: bool = False) -> Dict[str, torch.Tensor]:
        """完整前向。

        Args:
            image_hi:      [B,3,3,224,384] 最近 3 帧高清（必填，纯视觉主模态）
            image_lo:      [B,21,3,112,192] 前 21 帧低清（必填）
            lane:          [B,1,160,160] 或 None（车道线全丢）
            dets:          [B,20,12] 或 None（无检测框）
            det_mask:      [B,20] 或 None
            vehicle_state: [B,8] 或 None（状态读取失败）
            return_intent: True 时额外返回 "intent" [B,3]（训练期用）
            return_prob:   True 时把 logits 过 softmax/sigmoid（部署期用）

        Returns:
            dict，键见文件头 §六。默认全部为 **logits**（训练侧直接喂
            CE / BCEWithLogits，数值更稳 —— PyTorch 内部做 log-sum-exp）。
        """
        # ---- 主模态必填：缺失时无法驾驶，fail-fast 而非静默降级 ----
        if image_hi is None or image_lo is None:
            raise ValueError(
                "V3Model.forward: image_hi / image_lo 均为必填输入（纯视觉主模态），"
                "不可为 None")
        if image_hi.dim() != 5:
            raise ValueError(
                f"V3Model.forward: image_hi 期望 [B,T,3,H,W]，实际 {tuple(image_hi.shape)}")
        if image_lo.dim() != 5:
            raise ValueError(
                f"V3Model.forward: image_lo 期望 [B,T,3,H,W]，实际 {tuple(image_lo.shape)}")

        batch_size = image_hi.shape[0]
        ref = image_hi

        # ---- 状态缺失 → 零向量（"全零 = 未知"与 V2 一致的约定）----
        if vehicle_state is None:
            vehicle_state = torch.zeros(
                batch_size, self.cfg.state_dim, device=ref.device, dtype=ref.dtype)

        # ---- 训练期：状态噪声注入（论文 §IV.A :198-203）----
        # 为什么必须做：论文图 7 实测它把"离线 MAE 与在线成功率"的相关系数
        # 从 −0.64 提升到 −0.92 —— 缓解离线/在线差距的关键手段。
        # 只在训练态施加（self.training），推理时不能加噪。
        if self.training and self.cfg.enable_state_noise:
            vehicle_state = self._inject_state_noise(vehicle_state)

        # ---- ① 逐帧视觉特征（高清走完整骨干，低清走截断骨干）----
        f_hi, feat_t = self._encode_hi(image_hi, batch_size)   # [B,3,256] / [B,256,14,24]
        f_lo = self._encode_lo(image_lo)                       # [B,21,256]

        # ---- ② 24 帧层级时序 → 历史摘要 ----
        hist = self.temporal(f_hi, f_lo)        # [B,192]

        # ---- ③ state token = t−1 状态 + 历史摘要（零初始化残差）----
        x_state = self._build_state_token(vehicle_state, hist)      # [B,1,D]

        # ---- ④ lane / det token ----
        lane_tok, det_tok = self._build_prefix_tokens(
            lane, dets, det_mask, batch_size, ref)                  # 各 [B,1,D]

        # ---- ⑤ 视觉 token：末帧空间图 [B,256,14,24] → [B,336,D] ----
        # 用 flatten(2) 而不是 reshape(b,c,h*w)：后者要读 shape 得 int，
        # 会被 trace 成 aten::Int 导致 CoreML 转换失败（文件头 §四⑥）。
        visual = self.token_proj(feat_t.flatten(2).transpose(1, 2))  # [B,336,D]

        prefix = [x_state, lane_tok, det_tok]
        tokens1 = torch.cat(prefix + [visual], dim=1) + self.pos_emb  # [B,339,D]

        # ---- ⑥ stage1：pixel-state attention + 意图（论文 stop/go）----
        out1 = self.stage1(tokens1)                                # [B,339,D]
        state_token_1 = out1[:, 0:1, :]                            # 论文 §IV.A 传播
        intent = self.intent_head(state_token_1.squeeze(1))        # [B,3] 仅训练用

        # ---- ⑦ stage2：用传播过来的 state token 重新读图 ----
        # 为什么视觉 token 重新用原始 visual 而不是 out1 的视觉部分：
        # 论文原文只说传 state token；若视觉 token 也传，stage2 就只是对 stage1
        # 特征做二次加工，图像不会再被"带着新问题重看一遍"（01-backbone.md §3.3）。
        tokens2 = torch.cat([state_token_1, lane_tok, det_tok, visual],
                            dim=1) + self.pos_emb                  # [B,339,D]
        out2 = self.stage2(tokens2)                                # [B,339,D]
        state_token_2 = out2[:, 0, :]                              # [B,D]

        # ---- ⑧ 输出头 ----
        out = self.output_head(state_token_2)
        if return_prob:
            out = self._to_probabilities(out)
        if return_intent:
            out["intent"] = intent
        return out

    # ------------------------------------------------------------------
    def _inject_state_noise(self, vehicle_state: torch.Tensor) -> torch.Tensor:
        """训练期状态噪声注入（论文 §IV.A :198-203）。

        论文实测参数：控制量（范围 [0,1]）σ=0.1；速度（范围 [0,10]）σ=1。
        本项目 state 8 维里第 0 维是 speed、其余是控制量/角度类，故按列分别施加。

        ⚠️ 逐维独立加高斯噪声会造出物理上不自洽的组合（如"油门 0.9 + 速度 0 +
           加速度极大"）。`02-temporal.md` §4.3 实测：噪声用"物理不自洽"换覆盖率
           （不自洽比例 7.2%→9.4%）。所以**建议训练后期退火到 0**
           （`enable_state_noise=False` 即可关闭）。
        """
        c = self.cfg
        sigma = torch.full(
            (1, c.state_dim), c.state_noise_sigma_ctrl,
            device=vehicle_state.device, dtype=vehicle_state.dtype)
        sigma = sigma.clone()
        sigma[:, 0:1] = c.state_noise_sigma_speed      # 第 0 维 speed 用 σ_speed
        return vehicle_state + torch.randn_like(vehicle_state) * sigma

    @staticmethod
    def _to_probabilities(out: Dict[str, torch.Tensor]) -> Dict[str, torch.Tensor]:
        """logits → 概率（部署侧用）。

        vertical / horizontal 用 softmax（互斥多类）；
        其余 6 路用 sigmoid（独立二值）。
        """
        prob = dict(out)
        prob["vertical"] = torch.softmax(out["vertical"], dim=-1)
        prob["horizontal"] = torch.softmax(out["horizontal"], dim=-1)
        for key in ("handbrake", "brake", "super_brake", "ultimate",
                    "confidence", "risk"):
            prob[key] = torch.sigmoid(out[key])
        return prob

    # ------------------------------------------------------------------
    # 重参数化 / 统计
    # ------------------------------------------------------------------

    def reparameterize(self) -> None:
        """训练态 → 部署态：骨干的 RepVGG 三分支折叠成单 3×3 卷积。

        ⚠️⚠️ **加载 checkpoint 的正确顺序（V2 实测踩坑，静默失败）**：
            ❌ 错误：`m = build_v3_model(deploy=True); m.load_state_dict(ckpt)`
               → 部署态骨干只有折叠后的 `conv.weight`，而 checkpoint 存的是
                 **训练态多分支**（`rbr_3x3/rbr_1x1/rbr_identity` 及 BN）
                 → 键名全部静默失配（`strict=False` 不报错），
                 已训练的骨干被当成随机权重 → 导出产物看着正常但精度全废。
            ✅ 正确：`m = build_v3_model(deploy=False)`      # ① 训练态构建
                     `m.load_state_dict(ckpt, strict=False)`  # ② 加载
                     `m.reparameterize()`                     # ③ 折叠 → 部署态
            导出脚本应**断言 unexpected_keys 为空**，否则说明用错了 deploy 态。
        """
        if self.deploy:
            return
        self.backbone.reparameterize()
        self.deploy = True

    def freeze_ccm(self) -> None:
        """冻结 CCM（两阶段训练法的第 ② 步，见 `CommandCoherencyModule` 文档）。"""
        for p in self.ccm.parameters():
            p.requires_grad_(False)
        self.ccm.eval()

    def get_param_count(self) -> Dict[str, int]:
        """各部件参数量统计（训练期专用模块单列，部署/训练两侧口径分开）。

        为什么分 "deploy_total" 与 "total" 两个口径：
          训练脚本关心能学多少参数（含 intent_head / ccm）；
          导出脚本关心 .mlpackage 多大（不含训练期模块）。
        """
        def count(module: Optional[nn.Module]) -> int:
            return 0 if module is None else sum(p.numel() for p in module.parameters())

        out: Dict[str, int] = {
            "backbone": count(self.backbone),
            "lores_proj": count(self.lores_proj),
            "token_proj": count(self.token_proj),
            "temporal": count(self.temporal),
            "state_token_proj": count(self.state_token_proj),
            "hist_proj": count(self.hist_proj),
            "lane_encoder": count(self.lane_encoder),
            "det_encoder": count(self.det_encoder),
            "lane_token_proj": count(self.lane_token_proj),
            "det_token_proj": count(self.det_token_proj),
            "pos_emb": self.pos_emb.numel(),
            "stage1": count(self.stage1),
            "stage2": count(self.stage2),
            "output_head": count(self.output_head),
            # ── 训练期专用（不进部署图）──
            "intent_head": count(self.intent_head),
            "ccm": count(self.ccm),
        }
        out["total"] = sum(p.numel() for p in self.parameters())
        out["deploy_total"] = out["total"] - out["intent_head"] - out["ccm"]
        return out

    def get_model_size_mb(self, precision: str = "fp32") -> float:
        """部署态体积估算（MB）。precision: fp32 / fp16 / int8 / int4。"""
        bytes_per_param = {"fp32": 4.0, "fp16": 2.0, "int8": 1.0, "int4": 0.5}
        deploy_total = self.get_param_count()["deploy_total"]
        return deploy_total * bytes_per_param.get(precision, 4.0) / (1024 * 1024)


# ============================================================================
# 7. 损失函数（03-output-head.md §3）
# ============================================================================

class V3Loss(nn.Module):
    """V3 多任务损失（离散按键）。

    结构对齐论文 §IV-D 的三层（主任务 / 正则 / 中间监督）：

        L_total = λ·L_key + κ·L_ccm + τ·L_intent + λ_sb·L_super + λ_safe·L_safe

    权重来源（论文 :251-253 的 λ=0.8 / κ=0.1 / τ=0.1，新增两项按 03 文档）：
        λ=0.8     主任务（沿用论文）
        κ=0.1     CCM 正则（沿用论文）
        τ=0.1     中间监督（沿用论文，对应 stop/go）
        λ_sb=0.05 长按辅助（新增，小权重）
        λ_safe=0.1 安全头（新增，与 risk_head.py:1110 的"先 0.1 起调"一致）

    ⚠️ **类别不平衡**：主任务必须用类加权 CE + pos_weight（`03-output-head.md` §5）。
       实测证据：一个"永远输出 W"的平凡解准确率就有 80.8%，但 S 类一帧都不会。
       所以**模型选择禁用总准确率，必须看 per-class recall / 混淆矩阵**。
       Focal 在本任务实测无改善（S 召回 44→45），不采用。

    ⚠️ **中间监督用序数 EMD 而不是普通 CE**（03 文档 §3.3 实测）：
       普通 CE 对"跨 1 档"与"跨 2 档"给同样惩罚（9.0002 vs 9.0002，比值 1.00）；
       序数 EMD 严格随档距递增（1.0000 vs 1.9996，比值 2.00）。
       对安全系统，`GO↔STOP` 必须罚得比 `GO↔SLOW` 重。
    """

    def __init__(self, lambda_key: float = 0.8, kappa_ccm: float = 0.1,
                 tau_intent: float = 0.1, lambda_super: float = 0.05,
                 lambda_safe: float = 0.1,
                 lambda_coh: float = 0.05, lambda_roll: float = 2.0,
                 v_low: float = 20.0, v_high: float = 30.0,
                 enable_safety: bool = True,
                 vertical_weights: Optional[torch.Tensor] = None,
                 horizontal_weights: Optional[torch.Tensor] = None,
                 pos_weight_handbrake: float = 1.0,
                 pos_weight_brake: float = 1.0,
                 pos_weight_super: float = 1.0,
                 pos_weight_ultimate: float = 1.0,
                 enable_ccm: bool = True,
                 enable_intent: bool = True):
        super().__init__()
        self.lambda_key = lambda_key
        self.kappa_ccm = kappa_ccm
        self.tau_intent = tau_intent
        self.lambda_super = lambda_super
        self.lambda_safe = lambda_safe
        # ── 安全项（03-output-head.md §3.7，★用户 2026-11-03 硬约束）──
        #   λ_coh=0.05：四键头逻辑自洽（super_brake 必须 = handbrake∧brake）
        #   λ_roll=2.0：防侧翻。高速想按超级刹车却不按 S → 重罚，与主任务同量级
        self.lambda_coh = lambda_coh
        self.lambda_roll = lambda_roll
        self.v_low = v_low
        self.v_high = v_high
        self.enable_safety = enable_safety
        # 「整批无有效车速」的告警只打一次 —— 必须是**实例级**标志。
        # 写成类属性会让同一进程里第二个 V3Loss 实例的告警被第一个静默掉
        # （例如先跑评测再跑训练，训练里真正的数据缺口就再也看不见了）。
        self._rollover_disabled_warned = False
        self.enable_ccm = enable_ccm
        self.enable_intent = enable_intent

        # 类权重：默认等权。真实权重必须由训练集统计得到
        # （03 文档 §5.4：其假设分布是假设值，真实分布未测）。
        self.register_buffer(
            "vertical_weights",
            vertical_weights if vertical_weights is not None
            else torch.ones(3), persistent=False)
        self.register_buffer(
            "horizontal_weights",
            horizontal_weights if horizontal_weights is not None
            else torch.ones(3), persistent=False)

        # pos_weight 用 buffer 而非 float，方便随数据统计更新
        for name, val in (("handbrake", pos_weight_handbrake), ("brake", pos_weight_brake),
                          ("super_brake", pos_weight_super), ("ultimate", pos_weight_ultimate)):
            self.register_buffer(
                f"pw_{name}", torch.tensor([val], dtype=torch.float32), persistent=False)

    def forward(self, pred: Dict[str, torch.Tensor],
                target: Dict[str, torch.Tensor],
                ccm_pred: Optional[torch.Tensor] = None,
                ccm_target: Optional[torch.Tensor] = None) -> Tuple[torch.Tensor, Dict[str, float]]:
        """计算总损失。

        Args:
            pred:   模型输出 dict（logits）。vertical [B,3] / horizontal [B,3] /
                    handbrake|brake|super_brake|ultimate|confidence|risk [B,1] /
                    intent [B,3]（当 enable_intent=True 且模型 return_intent=True）
            target: 真值 dict，键与 pred 对应：
                    vertical [B] (long, 0=W 1=NONE 2=S)
                    horizontal [B] (long, 0=A 1=NONE 2=D)
                    handbrake|brake|super_brake|ultimate [B,1] (float 0/1)
                    confidence|risk [B,1] (float 0/1，代理真值)
                    intent [B] (long, 0=GO 1=SLOW 2=STOP)
            ccm_pred:   CCM 预测 [B,6]（可选）
            ccm_target: CCM 真值 [B,6]（可选）

        Returns:
            (total_loss, 分项 dict)
        """
        metrics: Dict[str, float] = {}

        # ── 主任务：纵向/横向两个 3 类 CE（类加权）──
        loss_v = F.cross_entropy(
            pred["vertical"], target["vertical"], weight=self.vertical_weights)
        loss_h = F.cross_entropy(
            pred["horizontal"], target["horizontal"], weight=self.horizontal_weights)

        # ── 四个修饰/安全键：BCEWithLogits（pos_weight 处理正负不平衡）──
        loss_hb = F.binary_cross_entropy_with_logits(
            pred["handbrake"], target["handbrake"], pos_weight=self.pw_handbrake)
        loss_br = F.binary_cross_entropy_with_logits(
            pred["brake"], target["brake"], pos_weight=self.pw_brake)

        loss_key = loss_v + loss_h + loss_hb + loss_br
        metrics.update({
            "vertical": loss_v.item(), "horizontal": loss_h.item(),
            "handbrake": loss_hb.item(), "brake": loss_br.item(),
        })

        total = self.lambda_key * loss_key

        # ── 长按辅助（可选，λ_sb=0.05）──
        if "super_brake" in target and "super_brake" in pred:
            loss_sb = F.binary_cross_entropy_with_logits(
                pred["super_brake"], target["super_brake"],
                pos_weight=self.pw_super_brake)
            total = total + self.lambda_super * loss_sb
            metrics["super_brake"] = loss_sb.item()
        if "ultimate" in target and "ultimate" in pred:
            loss_ul = F.binary_cross_entropy_with_logits(
                pred["ultimate"], target["ultimate"], pos_weight=self.pw_ultimate)
            total = total + self.lambda_super * loss_ul
            metrics["ultimate"] = loss_ul.item()

        # ── 安全头（confidence / risk，λ_safe=0.1）──
        if "confidence" in target and "confidence" in pred:
            loss_conf = F.binary_cross_entropy_with_logits(
                pred["confidence"], target["confidence"])
            loss_risk = F.binary_cross_entropy_with_logits(
                pred["risk"], target["risk"])
            total = total + self.lambda_safe * (loss_conf + loss_risk)
            metrics["confidence"] = loss_conf.item()
            metrics["risk"] = loss_risk.item()

        # ── CCM 正则（κ=0.1）：惩罚"推不出下一帧真实按键"的控制组合 ──
        if self.enable_ccm and ccm_pred is not None and ccm_target is not None:
            loss_ccm = F.l1_loss(ccm_pred, ccm_target)      # 论文用 L1
            total = total + self.kappa_ccm * loss_ccm
            metrics["ccm"] = loss_ccm.item()

        # ── 中间监督（τ=0.1）：序数 EMD ──
        if self.enable_intent and "intent" in pred and "intent" in target:
            loss_intent = self._ordinal_emd_loss(pred["intent"], target["intent"])
            total = total + self.tau_intent * loss_intent
            metrics["intent"] = loss_intent.item()

        # ── 安全项（03-output-head.md §3.7）：一致性 + 防侧翻 ──
        if self.enable_safety:
            loss_coh, loss_roll = self._safety_losses(pred, target)
            if loss_coh is not None:
                total = total + self.lambda_coh * loss_coh
                metrics["coh"] = loss_coh.item()
            if loss_roll is not None:
                total = total + self.lambda_roll * loss_roll
                metrics["rollover"] = loss_roll.item()

        metrics["total"] = float(total.detach())
        return total, metrics

    #: 纵向三分类里 S（制动/防翻稳定键）的下标。
    #: 与 `dataset_v3.vertical_from_keys`（0=W 1=NONE 2=S）及
    #: `tools/v3_exp/exp_rollover_guard.py:VERT_S` 严格一致，改一处必须改三处。
    VERT_S_INDEX = 2

    def _safety_losses(self, pred, target):
        """一致性项 L_coh + 防侧翻项 L_rollover（03-output-head.md §3.7）。

        L_coh（λ=0.05）：四个修饰键头是**独立** sigmoid，彼此无结构约束，
            完全可能输出「没按 Shift、没按空格，却按了 Shift+空格」——物理上不存在。
            约束来自录制器定义：super_brake = shift∧space、ultimate = shift∧space∧S。
            用 MSE（概率空间）：这是**自洽性约束**，没有真值可做 BCE。

        L_rollover（λ=2.0，★用户 2026-11-03 硬约束「不按 S 可能侧翻，车毁人亡」）：
            violation = w(speed) · P(super_brake) · (1 − P(S))
            三项相乘的语义：只有「高速」且「想按超级刹车」且「不想按 S」
            三者同时成立才重罚。低速严格为 0（不干扰正常驾驶）。

        ★ 梯度必须只流向 vertical（抬 P(S)），不许压 super_brake：
            对 `p_super` 做 detach。否则模型会走另一条更省力的路——
            「高速时别踩超级刹车」，把侧翻风险换成刹不住/撞车风险，一样致命。
            实测梯度证据见 §3.7.3：不 detach 时 super_logit 梯度为 +0.0168
            （正值 = 梯度下降会压低它）。

        ★ 速度缺失的 fail-safe（两张情况严格区分，都是「不许静默」）：
            ① 个别帧读不到速度 → w=1（按高速保守惩罚）。安全系统的通行原则是
               宁可误报不可漏报；若按 0 处理，速度一缺失安全项就静默失效。
            ② **整批都没有速度** → 关闭本轮 L_rollover 并告警一次。
               为什么不也按 w=1：那会让所有帧都受同等重罚，等于教模型
               「不管什么情况都踩 S」→ 永远刹车，同样是危险的方向。
               注：录制数据接入 speed_kmh 列后会自动生效。

        Returns:
            (loss_coh 或 None, loss_rollover 或 None)
        """
        if "vertical" not in pred:
            return None, None

        p_S = torch.softmax(pred["vertical"], dim=-1)[..., self.VERT_S_INDEX]

        # ── L_coh ──
        loss_coh = None
        if all(k in pred for k in ("handbrake", "brake", "super_brake", "ultimate")):
            hb = torch.sigmoid(pred["handbrake"].reshape(-1))
            br = torch.sigmoid(pred["brake"].reshape(-1))
            sb = torch.sigmoid(pred["super_brake"].reshape(-1))
            ul = torch.sigmoid(pred["ultimate"].reshape(-1))
            loss_coh = (F.mse_loss(sb, hb * br)
                        + F.mse_loss(ul, hb * br * p_S))

        # ── L_rollover ──
        if "super_brake" not in pred or "speed_kmh" not in target:
            return loss_coh, None

        speed = target["speed_kmh"].reshape(-1).to(p_S.dtype)
        speed_valid = target.get("speed_valid")
        valid = (speed_valid.reshape(-1).to(p_S.dtype) > 0.5
                 if speed_valid is not None else torch.ones_like(speed) > 0.5)

        # 整批无有效速度 → 本轮关闭（并只告警一次）。见上方 ①② 的区分。
        if not bool(valid.any()):
            if not self._rollover_disabled_warned:
                self._rollover_disabled_warned = True
                print("[V3Loss] ⚠ 本批数据没有任何有效车速（speed_kmh 全缺失）"
                      "→ 本轮 L_rollover 关闭。\n"
                      "          防侧翻约束需要速度；录制 CSV 含 speed_kmh 列后自动生效。"
                      "（不是静默跳过：此消息只打一次）")
            return loss_coh, None

        # 线性斜坡：v ≤ v_low → 0；v ≥ v_high → 1；中间线性。
        # 用斜坡而不是硬阈值：硬阈值在 v_high 处阶跃、梯度不连续，训练易震荡。
        span = max(self.v_high - self.v_low, 1e-6)
        w = ((speed - self.v_low) / span).clamp(0.0, 1.0)
        # 个别帧缺失 → 该帧按满罚（保守）。缺失不能当作「速度 0」把安全项关掉。
        w = torch.where(valid, w, torch.ones_like(w))

        p_super_raw = torch.sigmoid(pred["super_brake"].reshape(-1))
        # ★ 梯度切断（本设计最关键的一处安全考量，见 docstring）
        p_super = p_super_raw.detach()

        return loss_coh, (w * p_super * (1.0 - p_S)).mean()

    @staticmethod
    def _ordinal_emd_loss(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
        """序数 EMD 损失（GO/SLOW/STOP 是**有序**类别，不是无序标签）。

        做法：把类别 logits 过 softmax 得到分布，再与真值的 one-hot 做累积和
        （CDF）差，取 L1 平均。这是一维有序类别上 EMD（Earth Mover's Distance）
        的闭式解，天然让"跨 2 档"罚得比"跨 1 档"重。

        ⚠️ 用 `cumsum` 实现：cumsum 的 ANE 友好性**未测**，但本损失**只在训练侧**
           用（不进部署图），故不影响 ANE 派发。类别数固定为 3（GO/SLOW/STOP）。
        """
        n_cls = 3
        prob = torch.softmax(logits, dim=-1)                        # [B,3]
        onehot = F.one_hot(target.long(), num_classes=n_cls).to(prob.dtype)
        # CDF 差的 L1（去掉最后一列：CDF 末位恒为 1，差恒为 0，无信息）
        cdf_diff = (torch.cumsum(prob, dim=-1) - torch.cumsum(onehot, dim=-1)).abs()
        return cdf_diff[:, :-1].mean()


# ============================================================================
# 8. 构建 / 导出工具函数（命名与 model_v2.py 保持一致）
# ============================================================================

def build_v3_model(deploy: bool = False, cfg: Optional[V3Config] = None,
                   **kwargs) -> V3Model:
    """构建 V3 主驾驶模型。

    Args:
        deploy: False=训练态（RepVGG 多分支，精度高）
                True =部署态（已重参数化为纯 3×3，推理快）
        cfg: V3Config；None → 用默认配置
        **kwargs: 透传给 V3Config 的字段覆盖（如 dim=256, stage1_depth=5）
    Returns:
        V3Model 实例

    为什么支持 **kwargs 覆盖 cfg 字段：消融实验/导出脚本要改单个超参
    （例如把 stage1_depth 调回 4 做精度对照），不该为此改代码。
    未知字段会被忽略并打印警告（不让训练脚本因多传参数而崩，同 V2 策略）。
    """
    if cfg is None:
        cfg = V3Config()
    if kwargs:
        known = {f.name for f in cfg.__dataclass_fields__.values()}
        unknown = sorted(set(kwargs) - known)
        if unknown:
            print(f"[V3Model] ⚠ 忽略无法识别的配置字段 {unknown}")
        for k, v in kwargs.items():
            if k in known:
                setattr(cfg, k, v)
    return V3Model(cfg=cfg, deploy=deploy)


def get_model_stats(model: Optional[V3Model] = None) -> str:
    """打印模型参数统计（与 V2 的 get_model_stats 同风格）。"""
    if model is None:
        model = build_v3_model()
    counts = model.get_param_count()
    total = counts["total"]
    deploy_total = counts["deploy_total"]
    t = counts
    lines = [
        "=" * 70,
        "V3 模型参数统计（state-token 多阶段 Transformer + 24 帧混合时序）",
        "=" * 70,
        f"{'RepVGG 骨干:':<26}{t['backbone']:>12,}  ({t['backbone']/1e6:.3f}M)",
        f"{'  低清投影:':<26}{t['lores_proj']:>12,}  ({t['lores_proj']/1e3:.1f}K)",
        f"{'  token 投影:':<26}{t['token_proj']:>12,}  ({t['token_proj']/1e3:.1f}K)",
        f"{'时序模块:':<26}{t['temporal']:>12,}  ({t['temporal']/1e3:.1f}K)",
        f"{'  state token 投影:':<26}{t['state_token_proj']:>12,}  "
        f"({t['state_token_proj']/1e3:.1f}K)",
        f"{'  历史残差投影:':<26}{t['hist_proj']:>12,}  ({t['hist_proj']/1e3:.1f}K)",
        f"{'车道线编码器:':<26}{t['lane_encoder']:>12,}  ({t['lane_encoder']/1e3:.1f}K)",
        f"{'检测框编码器:':<26}{t['det_encoder']:>12,}  ({t['det_encoder']/1e3:.1f}K)",
        f"{'  lane/det token 投影:':<26}{t['lane_token_proj']+t['det_token_proj']:>12,}  "
        f"({(t['lane_token_proj']+t['det_token_proj'])/1e3:.1f}K)",
        f"{'位置编码:':<26}{t['pos_emb']:>12,}  ({t['pos_emb']/1e3:.1f}K)",
        f"{'stage1 主干:':<26}{t['stage1']:>12,}  ({t['stage1']/1e6:.3f}M)",
        f"{'stage2 主干:':<26}{t['stage2']:>12,}  ({t['stage2']/1e6:.3f}M)",
        f"{'输出头:':<26}{t['output_head']:>12,}  ({t['output_head']/1e3:.1f}K)",
        "-" * 70,
        f"{'部署态合计:':<26}{deploy_total:>12,}  ({deploy_total/1e6:.3f}M)",
        f"{'  意图头(仅训练):':<26}{t['intent_head']:>12,}  ({t['intent_head']/1e3:.1f}K)",
        f"{'  CCM(仅训练):':<26}{t['ccm']:>12,}  ({t['ccm']/1e3:.1f}K)",
        f"{'训练态合计:':<26}{total:>12,}  ({total/1e6:.3f}M)",
        "-" * 70,
        f"体积(部署态): FP32 {model.get_model_size_mb('fp32'):.2f} MB / "
        f"FP16 {model.get_model_size_mb('fp16'):.2f} MB / "
        f"INT8 {model.get_model_size_mb('int8'):.2f} MB / "
        f"4bit {model.get_model_size_mb('int4'):.2f} MB",
        f"主干: D={model.cfg.dim} heads={model.cfg.heads} "
        f"stage1_depth={model.cfg.stage1_depth} stage2_depth={model.cfg.stage2_depth} "
        f"视觉token={model.num_visual_tokens} 总token={model.num_tokens}",
        f"时序: {model.cfg.total_frames()} 帧（{model.cfg.num_hi_frames} 高清 + "
        f"{model.cfg.num_lo_frames} 低清），段长 {model.cfg.temporal_group}",
        "=" * 70,
    ]
    return "\n".join(lines)


def export_coreml(state_dict_path: str, save_path: str,
                  cfg: Optional[V3Config] = None,
                  precision: str = "float16") -> None:
    """导出 V3 为 CoreML .mlpackage（部署主路径）。

    关键实现要点（都是项目实测踩过的坑，勿随意改动）：
      1) **输入名用 `vehicle_state` 而非 `state`** —— coremltools 会把名为
         `state` 的输入静默改名为 `state_workaround`，Swift 侧取值直接 KeyError。
      2) **先用 `torch.jit.trace` 再转** —— 直接 `ct.convert(model)` 对含
         Optional 分支的 forward 支持不佳。
      3) `minimum_deployment_target=iOS17` + `convert_to="mlprogram"` ——
         否则拿不到 ANE 加速（老的 neuralnetwork 后端性能差一个量级）。
      4) **必须训练态构建再 reparameterize** —— 见 `V3Model.reparameterize()` 的
         checkpoint 加载顺序告警，用 deploy=True 构建再 load 会静默丢权重。

    Args:
        state_dict_path: 训练存档 .pt（含 model_state_dict）
        save_path: 输出 .mlpackage 路径
        cfg: 模型配置（必须与训练时一致，否则 shape 不符）
        precision: "float16"（推荐）或 "float32"
    """
    import coremltools as ct  # 延迟导入：训练环境可能没装 coremltools

    c = cfg or V3Config()
    model = build_v3_model(deploy=False, cfg=c)
    ckpt = torch.load(state_dict_path, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    result = model.load_state_dict(sd, strict=False)
    if result.unexpected_keys:
        # 用 deploy=True 构建再 load 的典型症状：多分支权重对不上
        print(f"[V3] ⚠ load_state_dict 有 {len(result.unexpected_keys)} 个 unexpected keys "
              f"（前 5 个：{result.unexpected_keys[:5]}）——"
              f"检查是否误用 deploy=True 构建后加载训练态 checkpoint")
    model.reparameterize()
    model.eval()

    # 构造符合输入契约的 dummy 输入（batch=1，固定 shape）
    dummy = (
        torch.zeros(1, c.num_hi_frames, 3, c.image_hi_h, c.image_hi_w),
        torch.zeros(1, c.num_lo_frames, 3, c.image_lo_h, c.image_lo_w),
        torch.zeros(1, 1, c.lane_size, c.lane_size),
        torch.zeros(1, c.max_detections, c.det_feat_dim),
        torch.zeros(1, c.max_detections),
        torch.zeros(1, c.state_dim),
    )
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy, strict=False)

    prec = ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="image_hi",
                          shape=(1, c.num_hi_frames, 3, c.image_hi_h, c.image_hi_w)),
            ct.TensorType(name="image_lo",
                          shape=(1, c.num_lo_frames, 3, c.image_lo_h, c.image_lo_w)),
            ct.TensorType(name="lane", shape=(1, 1, c.lane_size, c.lane_size)),
            ct.TensorType(name="dets", shape=(1, c.max_detections, c.det_feat_dim)),
            ct.TensorType(name="det_mask", shape=(1, c.max_detections)),
            ct.TensorType(name="vehicle_state", shape=(1, c.state_dim)),
        ],
        outputs=[
            ct.TensorType(name="vertical"),
            ct.TensorType(name="horizontal"),
            ct.TensorType(name="handbrake"),
            ct.TensorType(name="brake"),
            ct.TensorType(name="super_brake"),
            ct.TensorType(name="ultimate"),
            ct.TensorType(name="confidence"),
            ct.TensorType(name="risk"),
        ],
        compute_precision=prec,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    mlmodel.save(save_path)
    print(f"[V3] CoreML 导出成功: {save_path} "
          f"({c.image_hi_h}×{c.image_hi_w}, 24 帧, {precision}, mlprogram/iOS17)")


# ============================================================================
# 9. 自检：直接运行本文件时打印结构、参数量与 forward shape
# ============================================================================

if __name__ == "__main__":
    _model = build_v3_model()
    print(get_model_stats(_model))
    print()

    # 构造符合输入契约的随机输入（B=1），真实跑一次前向
    _c = _model.cfg
    _inputs = {
        "image_hi": torch.rand(1, _c.num_hi_frames, 3, _c.image_hi_h, _c.image_hi_w),
        "image_lo": torch.rand(1, _c.num_lo_frames, 3, _c.image_lo_h, _c.image_lo_w),
        "lane": torch.ones(1, 1, _c.lane_size, _c.lane_size),
        "dets": torch.rand(1, _c.max_detections, _c.det_feat_dim),
        "det_mask": torch.ones(1, _c.max_detections),
        "vehicle_state": torch.rand(1, _c.state_dim),
    }
    _model.eval()
    with torch.no_grad():
        _out = _model(**_inputs)
    print("forward 输出 shape（实测）：")
    for _k, _v in _out.items():
        print(f"  {_k:<14}: {tuple(_v.shape)}")

    # ── 重参数化折叠：打印**部署态**真实参数量 ────────────────────────
    # 为什么自检要同时打印两个口径：训练态含 RepVGG 三分支（12.49M），而导出到
    # .mlpackage 的是折叠后的大小（12.19M），两者差 0.28M —— 全部在骨干的
    # 1×1 分支与 identity 分支上。只报训练态会让人误以为模型超了 12M 预算。
    _bb_before = _model.get_param_count()["backbone"]
    _total_before = _model.get_param_count()["total"]
    _model.reparameterize()
    _cnt_after = _model.get_param_count()
    print()
    print("=" * 70)
    print("重参数化折叠（训练态 → 部署态）")
    print("=" * 70)
    print(f"  骨干:     {_bb_before:>12,} → {_cnt_after['backbone']:>12,}"
          f"（差 {_bb_before - _cnt_after['backbone']:,} = 1×1 / identity 分支）")
    print(f"  模型总计: {_total_before:>12,} → {_cnt_after['total']:>12,}"
          f"（差 {_total_before - _cnt_after['total']:,}）")
    print(f"  部署口径: {_cnt_after['deploy_total']:>12,} "
          f"({_cnt_after['deploy_total']/1e6:.3f}M)  ← 导出 .mlpackage 的参数量")
    print(f"  4bit 理论体积: {_model.get_model_size_mb('int4'):.3f} MB")
    print("=" * 70)
