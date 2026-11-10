# V3 视觉骨干 + 多阶段 Transformer 主干设计

> 任务：`task-8` ｜ 作者：v3-backbone ｜ 日期：2026-11-03
> 论文：*Addressing Limitations of State-Aware Imitation Learning for Autonomous Driving*（arXiv:2310.20650）。⚠️ 2026-11-10 文档清理：原本地全文 `docs/v3-design/papers/state_aware.txt`（746 行）及同目录 PDF 已随 `papers/` 目录删除，论文内容不再随仓库分发（按 arXiv 编号自查）。
> 配套代码：`tools/v3_exp/backbone_v3.py`（结构）、`tools/v3_exp/measure_backbone_v3.py`（实测）、`tools/v3_exp/measure_ane_threshold.py`、`tools/v3_exp/measure_quant_v3.py`、`tools/v3_exp/measure_conv_5x5_vs_3x3.py`、`tools/v3_exp/measure_report_tables.py`

**一句话结论**：推荐 **D=192 / 每 stage 深度 4 / 6 头 / 14×24=336 token / RepVGG 重参数化骨干**，部署态 **6.166M 参数**、**6.126 GFLOPs**、**218 个计算算子 100% 派到 ANE**、**ABBA 实测 2.114 ms**（本机 Apple M3）；4-bit palettize 后 **3.23 MB**，计算算子仍 **100% 在 ANE**。

> ⚠️ **2026-11-10 现状注记（以代码为准）**：本文是**设计阶段**报告，推荐配置 D=192 / 每 stage 深度 4 / 6 头 / 6.166M。最终整合实现 `src/model_v3.py` 实为 **D=256（`MODEL_DIM=256`）/ stage1 深度 5、stage2 深度 6 / 8 头 / 12.187M**（`model_v3.py:275-322`，详见 `04-model-code.md` §5.3）。本文的参数量与 ANE 延迟结论仅对应「单帧骨干+主干 D=192/depth4×2」这一设计配置，**不适用于最终整合模型**。

---

## §1 我读到了什么（论文精读复述）

我在写任何设计之前通读了全文（746 行，含 §III / §IV.A–D / §V / §VI / §VII 与消融表 III–VII）。这篇论文要解决的是模仿学习（IL）做自动驾驶的两个顽疾，而它的解法是一套「把车辆自身状态当成 Transformer 的一个 token，并在多阶段之间传递」的架构。具体五点：

**1）状态 token 怎么初始化 —— 用上一时刻的 4 个物理量。**
论文的初始状态 token 是 **t−1 时刻的 steer、throttle、brake、speed** 四个标量（原文 :196-197 "The initial state token is the embedding of steer, throttle, brake and speed at time t − 1"）。初始化方式不是简单拼接后做一次线性投影，而是**四个标量各自升维到 D/4 维，再拼接成 D 维**（原文 :225-226 "The four scalar quantities ... are lifted to a dimension of D/4 and concatenated into the D-dimensional state token"）。它扮演的角色与标准 ViT 的 CLS token 相同（:193 "the state token fulfills the same role as the CLS token in standard ViTs"），区别在于 CLS 是学出来的、它的内容由图像决定，而 state token 一开始就装着**车辆的真实测量值**。

**2）它如何跨 stage 传播 —— 只传 state token 本身，不传视觉 token。**
架构是多阶段（multi-stage）的，每个 stage 是一个独立的 Transformer encoder。传播方式是：**stage i 的 encoder 输出序列中，对应 state token 的那一个输出，直接作为 stage i+1 的输入 state token**（原文 :178-181 "the i−th stage can inform stage i+1 by taking the output of the encoder corresponding to the state token and propagating it as the new state token"）。也就是说 state token 是一条贯穿全网的「主干线」，每经过一个 stage 就被注入一层新的语义。每个 stage 再把当前的 state token 用各自专属的 FFN 解码成不同的输出（:181-183），实现由粗到细（coarse-to-fine, :176）的层级任务。

**3）为什么用多阶段而不是单阶段 —— 为了打断「惯性」这条伪相关。**
单阶段模型的病根是**惯性问题（inertia problem）**：训练数据里「车速低」和「不给油」高度共现，模型学到了这条伪相关，于是车一旦停下（红灯、堵车）就再也起不来（:63-67）。论文的解法是把决策拆成两级：**stage 1 只回答「该停还是该走」（stop/go），stage 2 才输出 steer/throttle/brake**（:184-191）。stage 1 不产生任何控制量，被期望专注去看红绿灯、行人、其他车辆（:187-188）；stage 2 借助传下来的 state token，在「已经知道该不该走」的前提下生成控制量。这样「该不该动」被显式建模成一个独立任务，而不是让回归头从车速的数值分布里自己猜。表 III 显示这直接把闯红灯率从单阶段的 38% 降到 14%，表 V 显示惯性导致的失败率（New Weather-Empty）从 40% 降到 8%，表 VI 里 time-out 失败从 17/12/16 降到 1/1/6。

**4）pixel-state attention 与普通 ViT 的区别 —— 注意力场里多了「车自己」这一个 token。**
普通 ViT（原文引 [14]）的 token 全是图像 patch，注意力只在像素之间发生。这篇论文把卷积骨干输出的特征图 f（Hf×Wf×C）拍平成 N=Hf·Wf 个 C 维 token，线性投影到 D 维，然后**在序列最前面拼上 state token**，整体加可学习位置编码（Eq.(1), :229-234）。于是 self-attention 变成「**每个像素都能注意到其他像素 + 车辆状态**」（:236-237 "a pixel-state attention, where every pixel of the feature map can attend to each other plus the state token"）。这带来两个直接好处：一是模型可以把「我现在多快、在往哪打方向」和「画面里有什么」显式关联起来；二是**内建可解释性**——直接看 state token 与各视觉 token 的注意力权重，就能知道这一帧模型是靠画面还是靠状态做的决策（§V，图 2/图 3）。论文用这个现象给出了很漂亮的一个证据：红灯时 stage 2 的注意力集中在 state token 上，绿灯起步时注意力转回图像 patch（:404-418 "In presence of a halt cue ... the attention scheme of the second stage focuses on the state token rather than on the image patches"）。

**5）CCM 解决什么问题 —— 让三个控制量不再是三件互不相干的事。**
steer、throttle、brake 如果各自独立回归，就缺少一个「把车从当前状态带到目标状态」的共同目标，会出现自相矛盾的输出，最典型的是**同时踩油门和刹车**（:248-253、图 8）。CCM（Command Coherency Module, §IV.C）的做法很巧：它**不直接约束控制量之间的关系，而是让模型去预测未来速度**。它输入 t 时刻的 steer/throttle/brake/speed，回归 t+1 时刻的 speed；先单独在真实测量数据上把它训好，然后**冻结**，再作为一个额外的损失项去约束主模型（:259-263 "Once the module is trained, we freeze it and use it as a regularizer"）。直觉是：如果模型同时给出「大油门 + 大刹车」，那么 CCM 预测出的下一时刻速度就会与真实物理不符，损失会变大，于是模型被逼着输出物理上自洽的控制组合。它只用三层 MLP + ELU（:263-265），**只在训练时使用**（:191-192 "the third and final stage ... acts as a regularizer, thus we use it only at training time"）。图 8 显示开启 CCM 后 (throttle, brake) 散点里「两者同时 > 0」的区域基本消失。

**另外两条对我设计有直接约束的细节**（不是主线但必须记住）：
- **状态噪声增强**（:198-203）：训练时往 state token 上注入零均值高斯噪声，控制量 σ=0.1（取值在 [0,1]），速度 σ=1（取值在 [0,10]）。这不是锦上添花——图 7 显示它把「离线 MAE 与在线成功率」的相关系数从 −0.64 提升到 −0.92，这正是缓解离线/在线差距的关键手段。V3 必须保留。
- **消融结论（表 IV，我逐格核对过）**：NoCrash **Dense / 训练条件**成功率 —— 完整模型 **50**，去掉 state token（w/o ST）跌到 **20**，去掉 stop/go 损失跌到 **28**，去掉 CCM 跌到 **28**，单阶段基线 **30**。**state token 是单项影响最大的机制**。这决定了 V3 放大时这三样必须原样保留，不能因为「时代变了」就简化掉。

---

## §2 与论文的差异对照表

| 维度 | 论文原始（§IV.D, :212-224） | V3 设计 | 差异理由 |
|---|---|---|---|
| 输入分辨率 | 200×88（宽×高） | **384×224** | 用户已确认；游戏画面细节比 CARLA 干净渲染更杂，需要更高分辨率 |
| 骨干卷积层数 | 5 层（3 层 stride2 + 2 层 stride1） | **stem + 3 stage，共 4 次 stride-2** | 见下方「下采样论证」 |
| 骨干 kernel | 5×5 / 5×5 / 5×5 / 3×3 / 3×3 | **全部 3×3**（RepVGG 块） | 实测参数对齐后 5×5 与 3×3×2 的 ANE 延迟无差异（见 §5.4），但 3×3 是 ANE 最成熟的形态、且重参数化只支持 3×3/1×1/identity 三种分支 |
| 激活函数 | ELU | **ReLU**（骨干）+ **GELU**（Transformer） | RepVGG 的标准配方是 ReLU；ELU 在 ANE 上无原生算子，会被拆解。Transformer 内部 GELU 实测 8/8 在 ANE（§5.2） |
| 骨干参数量 | **131,112（0.131M）**（我按原文通道×kernel 逐层相乘复现，非论文自报） | **2,490,752（2.49M）** | 用户要求放大到 2–3M |
| 特征图 / token 数 | 4×18 = **72** | 14×24 = **336** | 见下方「下采样论证」 |
| 主干宽度 D | 64 | **192** | 论文 D=64 是配合 0.13M 骨干的；放大骨干后需要更宽的主干承载 |
| head 数 | 3（head_dim=21.3） | **6**（head_dim=32） | 论文 3 头配 D=64 后 head_dim 非整数（64/3），实际需取整；V3 用 192/6=32 保持整除 |
| 每 stage 深度 | 4 | **4**（另有 3/5 的实测对照，见 §4.3） | 与论文一致 |
| stage 数 | 3（stage3 仅训练期 CCM） | **2 个 Transformer stage + 独立 CCM 模块** | 论文的「第 3 个 stage」本质是训练期正则器，不是同一个参数量的 encoder。V3 用两层 MLP 实现 CCM（同 §IV.C 原文），不占部署图 |
| 状态 token 初始化 | 4 标量各升维到 D/4 后拼接 | **单个 Linear(5→D)** | 数学等价推广（§3.2 说明），但导出图只有 1 个 matmul、无 concat/slice——那些算子容易掉 CPU |
| 状态 token 传播 | stage i 的 state token 输出 → stage i+1 输入 | **保留**（`forward` 中 `state_token_1` 显式传递） | 论文精髓，消融证明影响最大 |
| stage2 的视觉 token | 论文未明说是否传递视觉 token | **重新拼原始视觉 token**（可配置） | 让 stage1 的 state token 作为唯一的层级信息载体，图像可被「带着新问题重看一遍」；`propagate_visual_tokens=True` 可切换做消融 |
| 位置编码 | 可学习 Epos ∈ R^{(N+1)×D} | **同**（`pos_emb`，64,704 参数） | 与论文 Eq.(1) 一致 |
| 位置编码编码方式 | 可学习 embedding | 可学习 embedding | 与论文一致 |
| 主干归一化 | 论文未写明 | **pre-LN** | 深层更稳；LN 在 ANE 上实测 16/16 原生支持（§5.2） |
| 数据增强 | 噪声注入 σ=0.1 / σ=1 | **必须保留**（由数据侧实现，不在本篇代码内） | 图 7：离线/在线相关性 −0.64 → −0.92 |
| 输出 | stop/go 3 路 + steer/throttle/brake 3 路 | 同（本模块只到这一步） | 离散按键输出的映射见 `03-output-head.md` |
| 骨干结构范式 | 普通卷积堆叠 | **RepVGG 重参数化**（复用 `src/model_v2.py:298`） | 用户明确禁止「最普通的 CNN」但允许重参数化变体；推理态折叠为纯 3×3，ANE 友好 |
| 部署格式 | 未涉及 | 4-bit palettization | 用户已确认 4-bit 部署（约 6.5MB） |

### 2.1 下采样路径论证（Lead 明确要求）

论文 200×88 → 4×18 这一步，**原文文字与它自己给的特征图尺寸对不上**，我实测核对过：
§IV.D 说「前 3 层 stride 2」，但若卷积补边（SAME padding），88×200 走 3 次 stride-2 只能得到 **11×25**；只有**不补边（valid padding）**才是 88×200 --(k5,s2)×3--> 10×24 --(k3,s1)×2--> **4×18**。所以原文的 4×18 隐含了 valid 卷积语义。（本段为按原文参数逐层推演的实测，见 `measure_backbone_v3.py` 的 `[0]` 段与形状推演。）

对我们 224×384 而言，若照搬「5 次降采样」：

| 下采样次数 | 224×384 下特征图 | token 数 | 每 token 对应原图 | 评价 |
|---|---|---|---|---|
| 3 次 | 28×48 | **1344** | 8×8 px | token 过多，attention 成本平方增长，且远超 12M 预算下主干能承受的宽度 |
| **4 次** | **14×24** | **336** | **16×16 px** | **推荐**：整除、粒度合适 |
| 5 次（照搬论文） | 7×12 | 84 | 32×32 px | 太粗：384 宽画面里红绿灯/远处行人可能只占十几像素，降到 7×12 后基本糊掉 |

**结论：采用 4 次 stride-2 → 14×24 = 336 token。** 该方案 224/16=14、384/16=24 **均整除**，无 ceil 畸形尺寸（畸形尺寸在 ANE 上不友好，仓库 `model_v2.ImageEncoder` 的注释里已记录过 180/32=5.6 踩坑）。

另有一个代价必须写清楚：**336 token 的 attention 是 O(N²) 的**。实测数据（§4）显示 N=336 时主干贡献 3.116 GFLOPs，占总 6.126 GFLOPs 的 50.9%——主干已经和骨干一样贵。这是选择 336 而非 1344 的量化依据。

---

## §3 逐层结构表

以下全部为 `tools/v3_exp/measure_report_tables.py` 的**真实输出**（deploy 态、已重参数化折叠，D=192、depth/stage=4、336 token）。

### 3.1 骨干：RepVGG 视觉编码器（224×384 → 14×24×256）

| 层 | 类型 | 输入形状 | 输出形状 | 参数量 | 累计 |
|---|---|---|---|---|---|
| stem | RepVGGBlock(C3→32, s2) | [1,3,224,384] | [1,32,112,192] | 896 | 896 |
| stage0 | RepVGGStage(32→64, **2 blocks**, s2) | [1,32,112,192] | [1,64,56,96] | 55,424 | 56,320 |
| stage1 | RepVGGStage(64→128, **3 blocks**, s2) | [1,64,56,96] | [1,128,28,48] | 369,024 | 425,344 |
| stage2 | RepVGGStage(128→256, **4 blocks**, s2) | [1,128,28,48] | [1,256,14,24] | 2,065,408 | **2,490,752** |

> 骨干 2.49M，占部署态总参数（6.166M）的 **40.4%**；落在任务要求的 2–3M 区间。
> 各 stage 内部单块展开（deploy 态已折叠为单 3×3）：stage0 = 1×(32→64,s2)=18,496 + 1×(64→64,s1)=36,928；
> stage1 = 1×(64→128,s2)=73,856 + 2×(128→128,s1)=147,584×2；stage2 = 1×(128→256,s2)=295,168 + 3×(256→256,s1)=590,080×3。

### 3.2 主干：多阶段 state-token Transformer

| 模块 | 类型 | 输入形状 | 输出形状 | 参数量 | 累计 |
|---|---|---|---|---|---|
| backbone | RepVGGVisualBackbone | [1,3,224,384] | [1,256,14,24] | 2,490,752 | 2,490,752 |
| token_proj | Linear(256→192) | [1,336,256] | [1,336,192] | 49,344 | 2,540,096 |
| state_lift | Linear(5→192) | [1,5] | [1,192] | 1,152 | 2,541,248 |
| stage1 | TransformerEncoderStage(depth=4) | [1,337,192] | [1,337,192] | 1,779,456 | 4,320,704 |
| stage2 | TransformerEncoderStage(depth=4) | [1,337,192] | [1,337,192] | 1,779,456 | 6,100,160 |
| stop_go_head | Linear(192→3) | [1,192] | [1,3] | 579 | 6,100,739 |
| ctrl_head | Linear(192→3) | [1,192] | [1,3] | 579 | 6,101,318 |
| pos_emb | 可学习参数 | — | [1,337,192] | 64,704 | 6,166,022 |
| ccm（仅训练） | MLP(4→64→64→1) | [1,4] | [1,1] | 4,545 | — |

**部署态总参数 = 6,166,022（6.166M）**（含 pos_emb 64,704；不含 ccm——ccm 仅训练期用，不进部署图）。
若把训练期的 ccm 也算上，全模型参数为 **6,170,567（6.171M）**。

单个 TransformerBlock（×8）：LayerNorm×2（各 384）+ q/k/v/out 四个 Linear(192→192)（各 36,864+192）+ FFN(192→768→192)（147,456+768 + 147,456+192），**444,864 参数/块**，8 块共 **3,558,912**。

### 3.3 前向数据流

```
image [1,3,224,384]
  └→ RepVGG 骨干（4×stride2）→ [1,256,14,24]
     └→ flatten(2).transpose(1,2) → [1,336,256]
        └→ token_proj → [1,336,192]                    ← 视觉 token
state [1,5]
  └→ state_lift.unsqueeze(1) → [1,1,192]               ← 状态 token（论文 CLS 角色）

tokens1 = cat([state_token, visual_tokens]) + pos_emb → [1,337,192]
  └→ stage1（4 个 TransformerBlock，pixel-state attention）
     ├→ out1[:, 0] → stop_go_head → stop_go [1,3]      ← 论文 Eq.(2) 三路 stop 信号
     └→ state_token_1 = out1[:, 0:1, :]                ← §IV.A 状态传播

tokens2 = cat([state_token_1, visual_tokens]) + pos_emb → [1,337,192]
  └→ stage2（4 个 TransformerBlock）
     └→ out2[:, 0] → ctrl_head → ctrl [1,3]            ← steer/throttle/brake（原始 logits）
```

**关键实现细节（都是踩坑后的决定，不是风格偏好）：**
- **全程不用 `x.shape` 形状解包**。我第一版用了 `b, n, d = x.shape` 和 `reshape(b,c,h*w)`，`torch.jit.trace` 会把它记成 `aten::Int`，CoreML 转换直接失败：`ERROR - converting 'int' op` / `TypeError: only 0-dimensional arrays can be converted to Python scalars`。改成 `flatten(2)` / `unflatten(2, (heads, head_dim))` 这些纯张量算子后，转换通过（这是实测踩到并修掉的，见 §6）。
- **q/k/v 用三个独立 Linear，不用 `nn.MultiheadAttention`**。参数量完全相同，但后者会把 qkv 合并成一次 Linear 再 chunk，导出后产生 `slice_by_index`——这是项目历史实测里容易掉 CPU 的算子。当前导出图中 `slice_by_index` 只有 2 个且 100% 在 ANE（§5.2）。
- **stage2 重新拼原始视觉 token**（默认），而非 stage1 输出。理由见 §2 表格与 `propagate_visual_tokens` 开关。

---

## §4 参数分配表

### 4.1 推荐配置（D=192）分区

| 分区 | 参数量 | 占部署态 | 说明 |
|---|---|---|---|
| 视觉骨干（RepVGG） | 2,490,752 | 40.4% | 任务要求 2–3M ✓ |
| token 投影 | 49,344 | 0.8% | 256→192 |
| 状态升维 | 1,152 | 0.02% | 5→192 |
| stage1（4 块） | 1,779,456 | 28.8% | |
| stage2（4 块） | 1,779,456 | 28.8% | |
| 位置编码 | 64,704 | 1.0% | 337×192 |
| 两个头 | 1,158 | 0.02% | |
| **部署态合计** | **6,166,022** | **100%** | |
| CCM（训练期，不进图） | 4,545 | — | 仅训练时作为正则器 |

按任务给的 12M 总预算，视觉+主干占 **6.17M（51.4%）**，剩余 **5.83M** 留给时序模块（`02-temporal.md`）与输出头（`03-output-head.md`）。这个配比落在任务建议的「视觉 6–8M」下半区，偏保守——理由是 §2.1 实测发现 336 token 下主干已与骨干等贵，若再加大骨干边际收益不明。

### 4.2 候选配置横向实测对比

全部为实跑（`measure_backbone_v3.py`）。CPU/MPS 是**本机 PyTorch** 参考值，不代表 ANE 延迟；ANE 列是**真实 CoreML 派发**。

| tag | D | tokens | depth | 参数量 | FLOPs | ANE 占比 | 结论 |
|---|---|---|---|---|---|---|---|
| D128_t336_d4x2 | 128 | 336 | 4 | 4,159,047 | 4.557 G | **10.1%** ❌ | 派发到 GPU，否决 |
| D160_t336_d4x2 | 160 | 336 | 4 | 5,066,503 | 5.275 G | **100%** ✅ | 备选（更省） |
| D192_t336_d4x2 | 192 | 336 | 4 | 6,170,567\* | 6.126 G | **100%** ✅ | **推荐** |
| D192_t336_d3x2 | 192 | 336 | 3 | 5,280,839 | 5.355 G | 100% ✅ | 预算紧时可退 |
| D192_t336_d5x2 | 192 | 336 | 5 | 7,060,295 | 6.897 G | 100% ✅ | 超 7M，无必要 |
| D192_t84_d4x2 | 192 | **84** | 4 | 7,351,495 | 3.871 G | **10.4%** ❌ | token 太少→落 GPU，否决 |

> \* 候选表该列为 `sum(p.numel() for p in model.parameters())`，**含仅训练期的 ccm（4,545）**；部署态实际为 6,166,022。
> `D192_t84` 是通过**仅增加一次 stride-2**（`extra_downsample=True`，骨干通道与主干宽度不变）得到的，确保 token 数是唯一变量。

### 4.3 深度选择

D=192 下 depth 3/4/5 分别 5.28M / 6.17M / 7.06M（同为含 ccm 口径），FLOPs 5.36/6.13/6.90 G，**全部 100% ANE**。选 4 是因为它与论文一致、且 depth=5 已超 7M（挤占时序预算）而 depth=3 相对论文削减了容量。**注意：深度未做精度验证（无训练），此为结构决策，非精度结论。**

---

## §5 ANE 风险清单（全部为实测，附出处）

### 5.1 测量方法学（先说清工具可信度）

本机为 **Apple M3 / 16GB / macOS 27.0.1**（与部署目标芯片一致），torch 2.13.0、coremltools 9.0。ANE 派发用官方 `MLComputePlan` 读取**逐算子最终派发设备**，流程：

1. `torch.jit.trace` → `ct.convert(convert_to="mlprogram", compute_units=ALL)` → 存 `.mlpackage`
2. `ct.models.utils.compile_model` → `.mlmodelc`
3. `MLComputePlan.load_from_path(.mlmodelc)` → 遍历 `block.operations`，对每个算子调 `get_compute_device_usage_for_mlprogram_operation(op)` 取 `preferred_compute_device` 的类名（`MLNeuralEngineComputeDevice` / `MLGPUComputeDevice` / `MLCPUComputeDevice`）

**工具可信度我做了对照验证**：先拿微型模型测出"全 CPU"，怀疑工具失效；换 224×384 大卷积后 10/10 全 ANE、337-token attention 8/8 全 ANE——证明工具正常，微型模型落 CPU 是因为规模太小。这一步不能省，否则会把"模型太小"误判成"算子不支持"。

**⚠️ 计数口径（我修正过一次错误）**：`operations` 里混有非计算条目——`const`（权重常量）与 `ios16.constexpr_lut_to_dense`（4-bit palettize 的 LUT→稠密权重解压，模型内部还原权重用，**不是掉到 CPU 的计算**）。若计入分母，4-bit 模型的 ANE 占比会被错算成 78.7%。本报告所有 ANE 占比均**只统计真正参与前向计算的算子**。

### 5.2 推荐配置的逐算子派发（fp16，D=192，336 token）

| 算子类型 | ANE | GPU | CPU | 合计 |
|---|---|---|---|---|
| ios17.conv | 10 | 0 | 0 | 10 |
| ios17.linear | 52 | 0 | 0 | 52 |
| ios17.matmul | 16 | 0 | 0 | 16 |
| ios16.softmax | 8 | 0 | 0 | 8 |
| ios16.gelu | 8 | 0 | 0 | 8 |
| ios16.relu | 10 | 0 | 0 | 10 |
| ios17.layer_norm | 16 | 0 | 0 | 16 |
| ios17.add | 18 | 0 | 0 | 18 |
| ios17.mul | 8 | 0 | 0 | 8 |
| ios17.reshape | 33 | 0 | 0 | 33 |
| ios17.transpose | 33 | 0 | 0 | 33 |
| ios17.concat / expand_dims / slice_by_index / squeeze | 6 | 0 | 0 | 6 |
| **计算算子合计** | **218** | **0** | **0** | **218 = 100% ANE** |

**结论：推荐配置的部署图里，218 个计算算子全部落在 ANE，0 个掉 CPU、0 个掉 GPU。** 这是硬结论，不是估算。

### 5.3 风险清单

| 风险项 | 实测结果 | 等级 | 处置 |
|---|---|---|---|
| **① 主干宽度 D 存在 ANE 下界** | 折叠部署图实测：**D≤136 → 仅 10.1% 上 ANE**（22/218，其余 196 个落 GPU）；**D≥144 → 100%**。把 D=128 的深度从 4 加到 10（算力 4.56→6.85 GFLOPs）ANE 占比仍只有 4.5–10.1%，**证明这不是算力阈值而是宽度阈值** | 🔴 高 | **D 必须 ≥144**。推荐 192，最低配也取 160 |
| **② token 数过少会整体落 GPU** | 84-token 配置 ANE 仅 10.4%（23/220），196 个算子落 GPU；336-token 配置 100% | 🔴 高 | 保持 336；若后续要减 token 必须重测派发 |
| **③ 4-bit palettize 不破坏 ANE** | fp16 12.42MB → **int4 3.23MB**（3.85×），149 个权重量化；**计算算子 ANE 仍 218/218 = 100%**；int6 为 4.77MB、同样 100% | 🟢 低 | 4-bit 可放心用。体积比用户预期 6.5MB 更小（整个骨干+主干只有 3.23MB），余量可让给时序模块 |
| **④ 4-bit 量化精度漂移** | 与 fp16 输出最大绝对误差 **0.1445**（输出范围约 [−1.31, 2.62]，相对误差约 5.5%）；int6 误差 0.03125 | 🟡 中 | **这是随机初始化模型的量化误差，不代表训练后模型的误差**（未测：需训练后复测）。建议训练落地后按层敏感度做 per-op 位宽分配（仓库 `tools/exp_quant_tune.py` 已有 `op_name_configs` 能力可复用） |
| **⑤ 输入名 `state` 会被 CoreML 静默改名** | 导出时若把输入命名为 `state`，CoreML 会改成 **`state_workaround`**（`state` 是 mlprogram 保留概念），下游按原名会 KeyError | 🟡 中 | 输入统一命名 **`vehicle_state`**（本设计已采用，与仓库 `convert_e2e_v3.py` 一致）。实测改名后消失 |
| **⑥ 形状解包产生 aten::Int 导致转换失败** | `b,n,d = x.shape` / `reshape(b,c,h*w)` 会被 trace 成 `int` 算子，CoreML 报 `converting 'int' op` | 🟡 中 | 用 `flatten(2)` / `unflatten` 替代。已在代码中固化并注释 |
| **⑦ 含 while_loop 必 ANE_FAIL** | 项目既有实测（`models/exp_quant_report.json`）：891 算子中 453 落 CPU、ANE 可用 **0**，判 `ANE_FAIL`；改 static/unroll 后 609 ANE / 52 CPU（PARTIAL） | 🔴 高 | 本设计**全部 Python 层循环静态展开**（`TransformerEncoderStage` 的 for 循环在 trace 时展开为 depth 个节点），图中无任何动态控制流。实测 218 算子全 ANE 即为佐证 |
| **⑧ 5×5 卷积 vs 3×3 分解** | 见 §5.4 | 🟢 低 | 用 3×3（重参数化要求） |
| **⑨ 本机延迟非真机延迟** | ABBA 实测 ANE：D=160 **1.678 ms**、D=192 **2.114 ms**（5 轮×40 次取中位）；CPU-only 5.87/6.62 ms | — | 本机 M3 与部署芯片一致，但**不含**图像预处理、内存拷贝、CoreML 调度、App 内竞争。真机端到端**未测** |

### 5.4 5×5 单层 vs 两层 3×3 分解（Lead 要求实测）

参数已对齐（5×5: 205,056；3×3×2: 204,396，差 0.32%），输入 64×112×192，输出 128 通道：

| 方案 | 参数 | FLOPs | ANE 派发 | ANE 延迟 | CPU 延迟 |
|---|---|---|---|---|---|
| 5×5 单层 | 205,056 | 137.626 M | 2/2 = **100%** | **1.283 ms** | 2.828 ms |
| 3×3 两层分解 | 204,396 | 137.023 M | 4/4 = **100%** | **1.280 ms** | 2.276 ms |

**结论：两者都能 100% 上 ANE，ANE 延迟比 0.998×——实测无差异**（远低于测量噪声）。所以"5×5 在 ANE 上效率更低"在这个规模下**不成立**，不能作为选型理由。
（附一个方法论提醒：同一实验先用 28×48 小特征图测时，两个方案 ANE 派发都是 **0%**，全落 CPU——纯属模型太小的阈值假象。这类"小模型测出全 CPU"的坑必须用大分辨率复核，否则会得出完全错误的结论。）
**V3 选 3×3 的真实理由是**：RepVGG/MobileOne 的重参数化分支只能是 3×3 / 1×1 / identity（5×5 无法与 1×1 分支等价合并），而用户要求必须可折叠。**不是因为 5×5 慢。**

### 5.5 24 帧时序的算力红线（给 `02-temporal.md` 的硬约束）

实测（D=192、单帧 224×384）：全模型 **6.126 GFLOPs**，其中骨干 **3.010 G**（49.1%）、主干+头 **3.116 G**（50.9%）；低清 112×192 过同一骨干只要 **0.752 G**（高清的 25.0%）。

若**每帧都过骨干**（3 高清 + 21 低清）+ 主干只跑一次：
```
3×3.010 + 21×0.752 = 24.831 GFLOPs
+ 主干/头 3.116 = 27.947 GFLOPs   ← 是单帧的 4.56×
```
**这个量级不可能在 30ms 内跑完。** 因此 24 帧方案必须复用骨干特征（每帧过骨干、时序模块只在特征层做融合），或者只让少数帧过骨干、其余走缓存。**这是本模块给时序设计的红线，请 `02-temporal.md` 明确回应。**

---

## §6 未测项（诚实清单）

以下内容**没有测**，报告里不会用任何数字粉饰：

1. **训练后的精度**：本模块只做了结构与部署验证，**没有训练任何权重**。所有精度相关结论（论文表 IV 的成功率、CCM 带来的增益）都是**论文在 CARLA/NoCrash 上的结果**，不能迁移到本项目游戏画面上。
2. **训练后模型的 4-bit 量化误差**：§5.3 ④ 的 0.1445 是**随机初始化权重**的量化漂移，仅证明"流程可跑通、ANE 不掉"，**不能代表训练后精度损失**。需训练落地后复测，并考虑 per-op 位宽。
3. **真机端到端延迟**：§5.3 ⑨ 的 1.678/2.114 ms 是 CoreML 纯推理（Python `MLModel.predict`），**不含**：图像 resize/letterbox、CPU→ANE 内存拷贝、多模型调度、App 内与 yolopx（已占 10.4ms）竞争、24 帧时序模块。**是否满足 30ms 总预算 = 未测**。
4. **24 帧混合时序下的实际算力与延迟**：§5.5 只做了静态 FLOPs 叠加推算（27.9 GFLOPs），**没有实现也没有跑过 24 帧版本**。真实成本取决于时序模块如何复用骨干特征，属 `02-temporal.md` 范围。
5. **336 token 的精度收益**：选了 14×24 而非 7×12，依据是"远距离小目标会被糊掉"的**工程判断 + token 数对比的算力实测**，**没有做过精度对照实验**（需要训练两版模型）。
6. **深度/宽度的精度权衡**：depth 3/4/5 与 D 160/192 只测了参数量、FLOPs、ANE 派发，**没有精度数据**。选 D=192/depth=4 是结构决策（对齐论文 + 预算约束），非精度最优证明。
7. **`propagate_visual_tokens` 的取舍**：两种传播方式都实现了（开关），但**未做训练对比**，默认取 False 是设计推理（§3.3），不是实验结论。
8. **CCM 的实际效果**：只实现了模块结构与参数（4,545），**未训练、未验证**它能减少油门刹车冲突。论文的图 8 结论属原论文环境。
9. **状态噪声增强的实现**：σ=0.1/σ=1 的注入属数据管线，**本模块未实现**（不在 `backbone_v3.py` 内），需数据侧配合。
10. **lane / dets 输入的融合**：本模块只处理 image + state，**未接入** V2 继承的 `lane [1,1,160,160]` 与 `dets [1,20,12]`。这两路如何进入 V3（拼 token 还是走独立分支）**未设计**，依赖 `03-output-head.md`/`04-model-code.md` 的整合决定。
11. **输入分辨率 224×384 的 ANE 预处理开销**：resize/letterbox 由 Swift 侧完成，未测其成本。

---

## 附录：复现命令

```bash
cd /Users/dupi/Desktop/自动驾驶系统

# 结构 + 参数量 + FLOPs + 重参数化等价性 + 6 配置 ANE 派发（约 6 分钟）
/usr/local/bin/python3.11 tools/v3_exp/measure_backbone_v3.py

# 快速版（跳过 CoreML，只算参数量/FLOPs）
/usr/local/bin/python3.11 tools/v3_exp/measure_backbone_v3.py --no-ane

# ANE 派发阈值定位 + ABBA 干净延迟
/usr/local/bin/python3.11 tools/v3_exp/measure_ane_threshold.py --latency

# 4-bit 量化体积 / ANE / 误差
/usr/local/bin/python3.11 tools/v3_exp/measure_quant_v3.py

# 5×5 vs 3×3×2 对比
/usr/local/bin/python3.11 tools/v3_exp/measure_conv_5x5_vs_3x3.py

# 生成本文档 §3/§5.2 的表格
/usr/local/bin/python3.11 tools/v3_exp/measure_report_tables.py
```

**关键实测数字出处**：
- 参数量/FLOPs/分区：`measure_backbone_v3.py` 输出 + `/tmp/v3_bb_measure.json`
- 重参数化等价性：`measure_backbone_v3.py` `[1]` 段（折叠前后最大相对误差 8.6e-07，26 个 BN 层折叠，10 个 Conv2d）
- ANE 逐算子派发：`measure_report_tables.py` T2 表 + `/tmp/v3_*_measure/*.mlmodelc`
- ABBA 延迟：`measure_ane_threshold.py --latency` + `/tmp/v3_bb_threshold.json`
- 量化：`measure_quant_v3.py` + `/tmp/v3_quant/quant_report.json`
