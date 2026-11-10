# V3 模型代码实现报告

> 任务：`task-11` ｜ 作者：v3-code ｜ 日期：2026-11-03
> 产出：`src/model_v3.py`（1,846 行，可运行；行数 2026-11-10 `wc -l` 实测）、本报告
> 上游设计：`docs/v3-design/01-backbone.md`、`02-temporal.md`、`03-output-head.md`
> 验证脚本：`tools/v3_exp/v3code_count.py`、`tools/v3_exp/v3code_export.py`
> 环境：Apple M3 / macOS / Python 3.11.9 / torch 2.13.0 / coremltools 9.0（全部本地实测，未联网）

**一句话结论**：`build_v3_model()` 可实例化，**部署态实测 12,187,420 参数（12.187M）**，落在要求的 12.0–12.2M 区间；forward 8 个输出 shape 全部符合契约；`reparameterize()` 折叠后与训练态**数学等价（最大相对误差 9.42e-06）**；CoreML 导出 **fp16 23.39MB / 4-bit palettize 6.05MB**，**372 个计算算子中 369 个派到 ANE（99.2%）、0 个 GPU**，p50 **4.590ms**。

---

## §1 我读到了什么（论文精读复述）

我先完整通读了论文 *Addressing Limitations of State-Aware Imitation Learning for Autonomous Driving*（arXiv:2310.20650，原文 746 行；本地 txt/pdf 已于 2026-11-10 随 `papers/` 目录清理删除）全文（含 §III、§IV.A–D、§V、§VI、§VII 与表 I–VII），再动手写代码。这篇论文要解决模仿学习（IL）做自动驾驶的两个顽疾——**惯性问题（inertia）** 与 **离线/在线性能差距**——它的解法是一套「把车辆自身状态做成 Transformer 的一个 token，并在多阶段之间传递」的架构。我读到的核心有五点：

**1）state token 怎么初始化：用 t−1 的四个物理量，并且是各自升维再拼。**
初始状态 token 装的是 **t−1 时刻的 steer、throttle、brake、speed** 四个标量（原文 :196-197 "The initial state token is the embedding of steer, throttle, brake and speed at time t − 1"）。实现上不是简单拼接后一次线性投影，而是**四个标量各自升到 D/4 维再拼成 D 维**（原文 :225-226）。它扮演的角色与标准 ViT 的 CLS token 完全相同（:193），区别在于 CLS 是学出来的、内容由图像决定，而 state token 一开始就装着**车辆的真实测量值**。

**2）怎么跨 stage 传播：只传 state token 这一枚，视觉 token 不传。**
stage i 的 Transformer 输出序列里，对应 state token 的那一个位置，**直接作为 stage i+1 的输入 state token**（原文 :179-181 "taking the output of the encoder corresponding to the state token and propagating it as the new state token"）。所以 state token 是一条贯穿全网的「主干线」，每过一 stage 就注入一层新语义，每个 stage 再用各自专属的 FFN 解码成不同输出，实现由粗到细（coarse-to-fine，:176）。

**3）为什么必须多阶段：为了打断「低速 ⇔ 不给油」这条伪相关。**
单阶段的病根是训练数据里「车速低」与「不给油」高度共现，模型学到这条捷径，于是车停在红灯前就再也起不来（:63-67）。论文把决策拆成两级：**stage1 只回答「该停还是该走」（stop/go），不产生任何控制量**，被期望专注看红绿灯/行人/其他车（:187-188）；stage2 在「已经知道该不该走」的前提下才生成 steer/throttle/brake。这样「该不该动」被显式建模成独立任务，而不是让回归头从车速数值里自己猜。消融表 IV（Dense 任务）给了最硬的证据：**去掉 state token，成功率 50→20；去掉 stop/go 损失，50→28** —— 这两项是本架构收益最大的来源，我实现时原样保留。

**4）pixel-state attention 与普通 ViT 的差别：注意力场里多了一个「车自己」。**
骨干输出的特征图 f（Hf×Wf×C）拍平成 N=Hf·Wf 个 C 维 token，投影到 D 维，然后**在序列最前面拼上 state token**，整体加可学习位置编码（公式 (1)，:229-234）。于是 self-attention 变成「每个像素都能注意到其他像素 + 车辆状态」（:236-237）。两个直接好处：① 模型能把「我现在多快、在往哪打方向」与「画面里有什么」显式关联；② **内建可解释性** —— 直接看 state token 与各视觉 token 的注意力权重，就知道这一帧是靠画面还是靠状态做的决策。论文还给了一个很漂亮的证据：红灯时 stage2 注意力集中在 state token 上，绿灯起步时转回图像 patch（:404-418）。

**5）CCM 解决什么：让三个控制量不再各管各的。**
steer/throttle/brake 若各自独立回归，就缺少「把车从当前状态带到目标状态」的共同目标，会出现自相矛盾输出，最典型是**同时踩油门和刹车**（:248-253、图 8）。CCM 的巧处在于**不直接约束控制量之间的关系，而是让模型预测未来速度**：输入 t 时刻的 steer/throttle/brake/speed，回归 t+1 的 speed；先单独训到收敛、**冻结**，再作为额外损失项约束主模型（:259-263）。直觉是：若模型同时给「大油门 + 大刹车」，CCM 预测的下一帧速度就会与真实物理不符，损失变大，于是模型被逼输出物理自洽的组合。它只用三层 MLP + ELU，且**只在训练时使用**（:191-192）。

**另外两条直接约束我设计的细节**：
- **状态噪声增强**（:198-203）：训练时往 state token 注入零均值高斯噪声，控制量 σ=0.1（范围 [0,1]）、速度 σ=1（范围 [0,10]）。这不是锦上添花——图 7 显示它把「离线 MAE vs 在线成功率」的相关系数从 **−0.64 提到 −0.92**。我在 `V3Model.forward` 里实现了（仅训练态生效，见 §6.4）。
- **论文没做的事**：全文没有帧缓冲、没有 RNN/LSTM/GRU/TCN/时间维 attention、没有时间位置编码（只有空间位置编码 Epos）。所以**我们的 24 帧混合时序属于纯增量，不能拿论文给选型背书** —— 这一点我以为 `02-temporal.md` 的处理是对的。

---

## §2 交付物与验证口径

### 2.1 交付物

| 文件 | 行数 | 说明 |
|---|---|---|
| `src/model_v3.py` | 1,846 | 模型 + 损失 + 导出工具，可 `python3 src/model_v3.py` 自检（行数 2026-11-10 实测；原记 1,541 为提交时快照） |
| `tools/v3_exp/v3code_count.py` | 231 | 参数量 / forward shape 脚手架（带 `--selftest` 自校验） |
| `tools/v3_exp/v3code_export.py` | 412 | CoreML 导出 + 体积 / ANE 派发 / 延迟 / 数值一致性实测 |
| `docs/v3-design/04-model-code.md` | 本文件 | 实测报告 |

### 2.2 测量口径（避免下游对不上数）

- **参数量** = `sum(p.numel() for p in model.parameters())`，分「训练态」「折叠部署态」两个口径报告，且把仅训练用的 `intent_head` / `ccm` 单列。
- **体积**：`.mlpackage` = 目录递归求和（1024 进制）；另有「理论体积」= 参数量 × 每参数字节数，**两者不是一回事**（图结构/元数据有开销，实测差 0.14MB）。
- **ANE 派发** = `MLComputePlan` 逐算子读 `preferred_compute_device` 的**类名**（`MLComputeDevice` 没有 `.type` 属性，用 `str(dev)` 会统计出「ANE 0%」的假象）。
  ⚠️ **必须剔除两类非计算条目**：`const`（权重常量）与 `constexpr_lut_to_dense`（4-bit palettize 的 LUT→稠密权重解压）。
- **延迟** = `MLModel.predict` 计时，warmup 10 次后采 40 次取 p50/p95。**含 Python 绑定开销**，非真机 App 端到端。
- **数值一致性** = CoreML fp16 输出 vs PyTorch fp32 输出，同一输入逐元素比。

---

## §3 实测数据（核心验证）

### 3.1 参数量（真实打印，非预算值）

```
训练态（RepVGG 三分支，deploy=False）:
  模型总计 total          = 12,492,581
  部署口径 deploy_total   = 12,470,876   （= total − intent_head − ccm）

折叠部署态（reparameterize() 之后）:
  模型总计 total          = 12,209,125
  部署口径 deploy_total   = 12,187,420   ← 12.187M（导出 .mlpackage 的参数量）
```

> **三个口径为什么不同（跑 `python3 src/model_v3.py` 时会对上）**：
> - **12.493M**（训练态 total）：含 RepVGG 三分支 + `intent_head` + `ccm`，是训练时实际占显存的量。
> - **12.471M**（训练态 deploy_total）：减掉两个仅训练模块，但仍是三分支。
> - **12.187M**（折叠后 deploy_total）← **这才是导出到 CoreML 的参数量**。
> 差额 283,456 全部来自骨干折叠（1×1 分支 + identity 分支的 BN 折进 3×3 后消失）：
> `骨干 2,774,208 → 2,490,752`。自检脚本会自动打印这段折叠对比，无需手算。

分部件（折叠后）：

| 部件 | 参数量 | 占比 |
|---|---|---|
| RepVGG 视觉骨干 | 2,490,752 | 20.4% |
| stage1 主干（depth=5） | 3,948,800 | 32.4% |
| stage2 主干（depth=6） | 4,738,560 | 38.9% |
| 时序模块（层级 3 段×8 帧 + TCN） | 571,008 | 4.7% |
| 位置编码（339×256） | 86,784 | 0.7% |
| 输出头 | 69,036 | 0.6% |
| token 投影 + 低清投影 | 98,816 | 0.8% |
| lane/det 编码器 + token 投影 | 131,952 | 1.1% |
| state token 投影 + 历史残差投影 | 51,712 | 0.4% |
| **部署态合计** | **12,187,420** | **100%** |

> **交叉验证**：折叠后骨干实测 **2,490,752**，与 `01-backbone.md` §3.1 逐层表的总计 **2,490,752** 逐位一致 —— 说明重参数化折叠与 01 的结构设计完全吻合。
> **与 Lead 估算的差异**：Lead 按标准 pre-norm block 公式估 12.09M，实测 12.187M，差约 0.1M。原因是估算式 `12D²+13D` 只覆盖 Transformer block，未含 lane/det 编码器（82,288）、低清投影（33,024）、token 投影（65,792）等整合时新增的模块。**所有数字以实测为准。**

### 3.2 forward 输出 shape（真实跑通）

```
B=1: vertical=(1,3)  horizontal=(1,3)  handbrake=(1,1)  brake=(1,1)
     super_brake=(1,1)  ultimate=(1,1)  confidence=(1,1)  risk=(1,1)
B=3: vertical=(3,3)  horizontal=(3,3)  handbrake=(3,1)  brake=(3,1)
     super_brake=(3,1)  ultimate=(3,1)  confidence=(3,1)  risk=(3,1)
```

与 Lead 拍板的 8 输出契约逐项一致。`return_prob=True` 时额外验证了 softmax 行和 =1.0、sigmoid 落在 [0,1]。

### 3.3 重参数化等价性（deploy 正确性的硬证据）

同一套随机权重、同一输入，训练态 vs 折叠部署态：

| 输出 | \|Δ\|max | 相对误差 |
|---|---|---|
| vertical | 7.15e-07 | 4.43e-07 |
| horizontal | 1.67e-06 | 7.76e-07 |
| handbrake | 4.77e-07 | 1.54e-07 |
| brake | 1.19e-07 | 1.09e-07 |
| super_brake | 2.18e-06 | 9.42e-06 |
| ultimate | 4.77e-07 | 1.58e-07 |
| confidence | 1.91e-06 | 1.09e-06 |
| risk | 1.19e-06 | 1.10e-06 |

**最大相对误差 9.42e-06**，在 float32 精度极限内 → 折叠数学等价 ✅。

### 3.4 边界测试

| 场景 | 结果 |
|---|---|
| `lane=None` + `dets=None` + `det_mask=None` + `vehicle_state=None` | ✅ 8 输出 shape 正确，无 NaN |
| 车道线全零 + `dets [B,0,12]` + `det_mask [B,0]` | ✅ 无 NaN |
| `None` vs 同 shape 全零张量 | ✅ `|Δ| = 0.000000`（8 项全 0） |
| B=1 / B=3 | ✅ 输出首维随 B 变化 |
| `return_intent` / `return_prob` | ✅ 键完整，概率归一 |

> **关于「None 与全零完全一致」的诚实说明**：这是 V2 记录过的关键不变量，但本项目在**随机初始化**下如此严格成立，是因为 `lane_encoder` / `det_encoder` 的输出头 bias 初始为 0 且 BN 尚未训练。**训练后两者会有差异**（零向量会携带「该模态缺失」的语义），这属于正常现象，不是保证。
> **训练/推理噪声隔离已验证**：`eval()` 态同输入两次前向输出完全一致；`train()` 态因噪声注入而不同（`vertical` 差异 5.7e-01）。

---

## §4 CoreML 导出实测

### 4.1 体积

| 格式 | 实测体积 | 理论体积 | 说明 |
|---|---|---|---|
| fp16（mlprogram / iOS18） | **23.39 MB** | 23.246 MB | 差 0.14MB = 图结构/元数据/bias 开销 |
| **4-bit palettize（kmeans, per_tensor）** | **6.05 MB** | 5.811 MB | 压缩比 3.87×，**满足 6.5MB 预算** |

### 4.2 ANE 派发（4-bit palettize 包，逐算子实测）

```
计算算子 372 个：ANE=369  GPU=0  CPU=3   →  ANE 占比 99.2%
const / 非计算条目 570 个（已剔除，含 93 个 LUT 解压算子）
```

**⚠️ 这里我踩了 `01-backbone.md` §5.1 明确警告过的统计陷阱**：第一版脚本只剔除了 `const`，没剔除 `constexpr_lut_to_dense`（93 个 4-bit LUT→权重解压算子，不是计算），算出的 ANE 占比是 **79.4%** —— 与文档记录的「错误算法会得到 78.7%」几乎完全吻合，反向印证了文档结论正确。修正口径后是 **99.2%**。

落在 CPU 的 3 个算子实测明细：`ios18.transpose`、`ios18.conv`、`ios18.relu`（各 1 个）。
对照：**fp16 包是 372/372 = 100% ANE**，说明这 3 个是 4-bit 量化引入的调度偏移，不是结构性问题。

### 4.3 延迟

| 包 | p50 | p95 | min | 口径 |
|---|---|---|---|---|
| fp16 | **4.302 ms** | 4.509 ms | 4.248 ms | 40 次，含 Python 绑定 |
| 4-bit palettize | **4.590 ms** | 4.861 ms | 4.478 ms | 40 次，含 Python 绑定 |

**对 30Hz（33ms）预算的余量约 7.2×**（按 p95 4.861ms 算 6.8×）。但**这是纯模型推理，不含预处理、内存拷贝、与 yolopx（已占 10.4ms）的竞争** → 端到端是否达标 **未测**。

### 4.4 4-bit 量化的一个反例（重要教训）

我最初用 `linear_quantize_weights` 做 4-bit **线性量化**，实测结果是：

| 量化方式 | 体积 | ANE 派发 | 延迟 |
|---|---|---|---|
| 4-bit 线性量化 | 6.10 MB | **66.0%（307 ANE / 64 GPU / 1 CPU）** | **p50 6.667 ms（更慢）** |
| **4-bit palettize（最终采用）** | **6.05 MB** | **99.2%（369 ANE / 0 GPU / 3 CPU）** | **p50 4.590 ms** |

线性量化的体积更小一点点，但**64 个算子落到 GPU、延迟反而从 4.30ms 恶化到 6.67ms**。原因是它把权重量化拆成 `constexpr_blockwise_shift_scale` 类算子，破坏了 ANE 的连续派发。
**结论：4-bit 部署应走 palettization，不要用线性量化。** 这条已固化进 `v3code_export.py` 的 `--quant-mode` 注释。

### 4.5 数值一致性（CoreML fp16 vs PyTorch fp32）

| 输出 | \|Δ\|max | 相对误差 |
|---|---|---|
| vertical | 8.01e-03 | 2.01e-03 |
| horizontal | 1.21e-02 | 4.43e-03 |
| handbrake | 2.76e-03 | 2.61e-03 |
| brake | 4.45e-03 | 3.04e-03 |
| super_brake | 1.02e-03 | 1.31e-03 |
| ultimate | 3.95e-03 | 4.47e-03 |
| confidence | 1.18e-03 | 1.90e-03 |
| risk | 4.82e-03 | 1.10e-03 |

最大相对误差 **4.43e-03**，属 fp16 量化正常量级。**但必须说明**：这是**随机初始化权重**的误差，不代表训练后模型的误差；且只用全零输入测了一组，**未做多样本统计**。

### 4.6 部署契约（Swift 端必须照此实现，逐项实测）

> 这一节是 2026-11-03 补的：此前**没有任何文档**写部署端该怎么喂数据，
> 而这些约定一旦搞错，模型不会报错、只会静默输出错误指令。
> 以下每条都是**实测**（用导出包读 spec / 用构造帧反推），不是从代码推断。

**① 输入类型是 `MLMultiArray`，不是图像**

读 4-bit 包的 spec 实测：6 个输入**全部是 `multiArrayType` / `FLOAT16`**，
**没有一个 `imageType`**。这意味着：

- 部署端**不能**直接塞 `CVPixelBuffer` 给 `MLFeatureValue`；
- 必须自己转成 **float16、通道在前（NCHW）** 的 `MLMultiArray`；
- 布局与 PyTorch 一致，**不需要**做 NHWC↔NCHW 转置。

| 输入 | 形状（含 batch=1） | dtype |
|---|---|---|
| `image_hi` | `[1, 3, 3, 224, 384]` | FLOAT16 |
| `image_lo` | `[1, 21, 3, 112, 192]` | FLOAT16 |
| `lane` | `[1, 1, 160, 160]` | FLOAT16 |
| `dets` | `[1, 20, 12]` | FLOAT16 |
| `det_mask` | `[1, 20]` | FLOAT16 |
| `vehicle_state` | `[1, 8]` | FLOAT16 |

输出 8 个，全部 `multiArrayType` / `FLOAT16`：`vertical[1,3]`、`horizontal[1,3]`、
`handbrake`/`brake`/`super_brake`/`ultimate`/`confidence`/`risk` 各 `[1,1]`。
（**输出是 logits，不是概率**——`vertical`/`horizontal` 要 argmax 或 softmax，
其余 4 个 sigmoid 头要在部署端自己做 `sigmoid`。）

**② 缩放是「纯拉伸」，不是 letterbox**（实测）

`dataset_v3` 对 640×360 原帧做的是 `PIL.resize((384, 224))`，即**直接拉伸、不保比例、
不裁切、不补边**。实测缩放比：

```
x 方向 384/640 = 0.6000
y 方向 224/360 = 0.6222
```

两者**不相等**（y 比 x 大 3.7%），也就是存在各向异性。部署端若用 letterbox
（保比例缩到 398×224 再裁掉两侧 7px），输入分布会与训练分布不同——
**这是会静默降低精度、且不会报错的那类错误**。必须用纯拉伸。

**③ 归一化只有 `/255`**

无 mean/std 减除。实测数据集张量值域落在 `[0, 1]`。

**④ 帧窗口顺序：**索引 0 = 最新帧（最贵的一处，错了会学成反向因果）**

用「红通道编码帧号」的构造帧反推实测（30 帧 clip）：

```
hi[0] = t      hi[1] = t−1    hi[2] = t−2        （t=10 时实测 10/9/8）
lo[0] = t−3    lo[1] = t−4 …                      （t=10 时实测 lo[0..5] = 7,6,5,4,3,2）
```

即整个 24 帧窗口是 **[t, t−1, …, t−23]，新→旧**。
模型侧同一约定写在 `V3Model._encode_hi`：
`feats.unflatten(0, (-1, T))[:, 0]` 就是当前帧。

历史不足时（`frame_idx < 23`）**用第 0 帧重复填充**（`clamp_frame = max(0, fi)`）。

**⑤ `lane` / `dets` / `det_mask` 在训练时恒为全零 —— 部署必须保持一致**

`dataset_v3.__getitem__` 返回的是
`lane=zeros(1,160,160)`、`dets=zeros(20,12)`、`det_mask=zeros(20)`。
也就是说**这三路输入目前没有参与训练**。部署端有两种正确做法：

- 也喂全零（与训练一致，安全但浪费了感知输入）；
- 或者先把训练端接上真实感知、重训之后再喂真实值。

**错误做法**：直接喂真实的 YOLO 检测/车道线——输入分布与训练时完全不同，
模型见到它从没见过的非零输入，行为不可预期。

**⑥ `vehicle_state[0]`（speed）训练时也恒为 0**

`dataset_v3.py` 明确写「录制数据里没有速度 → 恒 0」，只填了 `[6]`（t−1 的 A/D）。
部署端若喂真实归一化速度，同样构成训练/部署分布不一致。
（`model_v2.StateEncoder` 的注释约定 `[0] = 车速/速度上限 ∈ [0,1]`，那是 V2 的口径。）

**⑦ 磁盘体积 vs 精确体积的口径差异**

`report.json` 里的 6.05 / 23.39 MB 是递归字节求和；`du -sm` 实测分别为 **7MB / 24MB**
（含目录对齐与元数据）。两个口径都对，报告数字时须说明用的是哪个——
打包预算若按 `du` 算，6.5MB 上限对应的是 6.05MB 那个口径，**余量约 0.45MB**。

---

## §5 与三份设计的对照（哪里照做、哪里偏离、为什么）

### 5.1 严格照做的定案

| 定案项 | 来源 | 实现位置 |
|---|---|---|
| D=256 / 8 头（head_dim=32） | Lead 拍板 | `MODEL_DIM=256`, `NUM_HEADS=8` |
| stage1 深度 5 + stage2 深度 6（共 11 块） | Lead 拍板 | `STAGE1_DEPTH=5`, `STAGE2_DEPTH=6` |
| 336 视觉 token（14×24） | 01 文档 | `feature_hw()` 校验整除 |
| RepVGG 重参数化骨干 2.49M | 01 文档 | `RepVGGVisualBackbone`，复用 `model_v2.RepVGGBlock` |
| state token 跨 stage 传播 | 论文 §IV.A | `forward` 中 `state_token_1 = out1[:, 0:1, :]` |
| pixel-state attention | 论文 §IV.B | `TransformerBlock`，state/lane/det/visual 同场 |
| 21 帧低清只走骨干前 2 层 | 02 文档 | `forward_truncated()` + `lores_proj(128→256)` |
| 3 段 × 8 帧层级时序 + TCN 段间 | 02 文档 | `TemporalModuleV3` |
| 时间位置编码 24×hidden 可学习 | 02 文档 | `time_emb` |
| 最近 3 帧静态选帧 | 02 文档 | `_encode_hi` 取 `image_hi[:, 0]` 作末帧空间图 |
| 8 输出契约（vertical/horizontal + 4 修饰键 + 2 安全头） | Lead 拍板 | `V3OutputHead` |
| stage1 意图头仅训练、CCM 先训后冻结 | 03 文档 | `intent_head` / `ccm` / `freeze_ccm()` |
| 零初始化历史残差投影 | 02 文档 §8 | `hist_proj` 零初始化 |
| 状态噪声 σ_ctrl=0.1 / σ_speed=1 | 论文 §IV.A | `_inject_state_noise()`，仅训练态 |
| 损失权重 λ=0.8 / κ=0.1 / τ=0.1 | 论文 §IV.D | `V3Loss` |
| 序数 EMD 做意图监督 | 03 文档 §3.3 | `_ordinal_emd_loss()` |
| 输入名 `vehicle_state`（不叫 `state`） | 01/02 文档 | forward 签名 + CoreML 导出 |
| 禁形状解包 / 禁 nn.GRU / 禁 TransformerEncoderLayer | 01/02 文档 | 全程 `flatten`/`unflatten`，手写 attention |
| fan_in 初始化 + risk bias=−2.197 / confidence bias=0.405 | 03 文档 §2.5 | `V3OutputHead._init_weights()` |

### 5.2 整合时必须新增的决定（文档未覆盖，我做的取舍）

| 决定 | 理由 | 风险 |
|---|---|---|
| **lane / dets 各投影成 1 个 token 放进序列** | 01 §6.10 与 02 §7.10 都承认「这两路如何进 V3 未设计」。论文的 pixel-state attention 天然支持序列里混非视觉 token；02 §4.3 实测多 1 个 token 只增加 0.4% 注意力算力 | **未做精度验证**。也可能应该走独立分支而非 token |
| **高清 3 帧只跑一次骨干**，用 `adaptive_avg_pool2d` 取逐帧向量、末帧空间图出 visual token | 同一批卷积若要「时序向量 + 视觉 token」跑两遍，等于白烧 3 帧算力 | 视觉 token 只来自当前帧 t，t−1/t−2 的空间信息不进 attention（只经时序摘要） |
| **state 与 hist 分成两条投影**（`state_token_proj(8→D)` + `hist_proj(192→D)` 零初始化） | 若把 state 与 hist concat 后过单个 Linear，输入维度 200 里有 192 是 hist，随机初始化下历史立刻主导 state token，等于「注入」变「覆盖」 | 比 02 建议的 `Linear(196→192)` 多一个矩阵（51,712 参数），但梯度行为可控 |
| **时序 hidden 保持 192、不随 D 升到 256** | 02 文档的时序结构与实测都建立在 hidden=192 上；靠 `hist_proj(192→256)` 投到主干维度，改动最小 | 历史摘要容量相对主干略窄（192 vs 256） |

### 5.3 ⚠️ 换骨干带来的失效声明（Lead 明确要求如实写）

**`02-temporal.md` §5.5 的延迟数字在本实现下全部失效，不得沿用。**

02 文档的 `p50 = 2.06ms / p95 = 3.30ms / 100% ANE` 是在 **`model_v2.ImageEncoder`**（5 stage、输出 256 维、12×20 特征图）上测的。本实现按 Lead 定案改用 **`01-backbone.md` 的 `RepVGGVisualBackbone`**（4 次 stride-2、14×24=336 token、骨干 2.49M）。骨干结构不同 → 算子数、算力、延迟都不同。

本报告所有 CoreML 数字（23.39MB / 6.05MB / 99.2% ANE / p50 4.590ms）都是**在最终整合模型（含 11 块 Transformer 主干）上重新实测**的，不是从任何文档抄来的。

同理，`01-backbone.md` 的「单帧部署态 2.114ms」也不适用于本模型——那个是「骨干 + 主干」且 depth 4×2、D=192 的配置；本模型是 D=256、depth 5+6，并额外含 24 帧时序与 8 个头。

---

## §6 训练期模块验证

### 6.1 V3Loss 实跑（随机初始化，单 step，B=4）

```
vertical       1.531430      horizontal     1.023563
handbrake      0.739280      brake          0.539860
super_brake    1.114483      ultimate       1.639220
confidence     0.816838      risk           0.603033
ccm            0.428979      intent         0.432251
------------------------------------------------
total          3.433101
```

11 个分项全部正常产出、量纲可比（同一数量级），没有被某一项吃掉的迹象。**这是随机初始化的一次前向值，不代表收敛后的数值**（真实收敛值未测）。

### 6.2 梯度流通

反向传播后 **310/323 个参数张量有非零梯度**。

剩下 13 个（`lores_proj` 2 个 + `temporal` 11 个）**首步梯度为 0**，根因是 `hist_proj` 零初始化：`dL/d(hist) = dL/dx_state @ hist_proj.weight = 0`，所以整条时序链路第一步拿不到梯度。

**我验证了这不是缺陷，而是 ResNet 残差层的标准行为**（3 个不同随机种子复现一致）：

```
step 1: temporal 梯度 11 个张量全为 0，总梯度 = 0.000e+00，hist_proj|W| = 0.000
step 2: temporal 梯度 11 个张量全部非零，总梯度 = 1.555e+01，hist_proj|W| = 4.915
step 3: temporal 梯度全部非零，总梯度 = 1.395e+01，hist_proj|W| = 7.501
```

从第 2 步起时序模块正常学习。`hist_proj` 首步梯度范数 26.8（是 `state_token_proj` 3.25 的 8 倍），因为它的输入来自 LayerNorm 输出（范数 ≈√192 = 13.86），量级合理；Adam 在 lr=1e-4 下单步把这个零矩阵推到 |W|≈4.9，是正常的 Adam 步长行为。

### 6.3 CCM 冻结（两阶段训练法的第 ② 步）

```
CCM 全部 requires_grad=False : True
CCM 处于 eval 模式           : True
冻结后 CCM 梯度总和          : 0.000000
```

与 `03-output-head.md` §3.4 实测的「不冻结时首层梯度 0.007066」形成对照，证明冻结环节实现正确。

### 6.4 状态噪声注入

- 仅 `self.training=True` 且 `enable_state_noise=True` 时生效（推理态不加噪）。
- 第 0 维（speed）用 σ=1.0，其余 7 维用 σ=0.1（按论文「速度范围 [0,10]、控制量 [0,1]」的量级差异分列施加）。
- **实测确认隔离有效**：`eval()` 态同输入两次前向逐位相同；`train()` 态不同。
- ⚠️ 02 §4.3 实测指出逐维独立加噪会造出物理不自洽组合（不自洽比例 7.2%→9.4%），**建议训练后期退火到 0**（`enable_state_noise=False`）。本实现提供该开关但**未实现自动退火调度**（属训练脚本职责）。

---

## §7 已知问题与风险

| # | 问题 | 严重度 | 说明与处置 |
|---|---|---|---|
| 1 | 4-bit 部署有 3 个算子落 CPU（fp16 是 0） | 🟢 低 | `transpose`/`conv`/`relu` 各 1 个，占 372 的 0.8%；实测延迟 4.59ms 仍远低于预算 |
| 2 | `ultimate` 输出来自 `Shift+Space+S` 组合，但**与 vertical 的 S 类存在语义重叠** | 🟡 中 | `ultimate` 的标签定义（03 文档 §4.2 记为 `Shift+Space+S`）可能与 vertical 的 S（后退）冲突，**标签构造时需明确互斥规则**，否则两路监督打架 |
| 3 | lane/det token 的接入方式未经精度验证 | 🟡 中 | 见 §5.2；若训练后这两路贡献为 0，应改为独立分支或直接移除 |
| 4 | `AURORA` 一侧键位定义两套矛盾（`aurora_recorder.c` vs `ControlEngine.swift`） | 🟡 中 | 03 文档 §7.3 已发现：录制器 Space=刹车、Shift=手刹，而 `ControlEngine.swift:49,56` 是反的。**本任务不改 Sources/**，仅标注：闭环控制前必须统一 |
| 5 | 视觉 token 只取当前帧 t 的空间图 | 🟢 低 | t−1/t−2 的空间信息只经时序摘要进 state token。若精度不足可改为 3 帧各出 token（token 数 336→1008，attention 成本 ×9，需重评） |
| 6 | `int4` 导出脚本依赖 iOS18 目标 | 🟢 低 | 4-bit palettize 在 `minimum_deployment_target=iOS17` 下会被拒绝（实测报错 "supported since iOS18"）。部署设备需 ≥iOS18 |

---

## §8 未测项（诚实清单）

**以下内容没有测，报告里不用任何数字粉饰：**

1. **训练后的精度** —— 全程用随机初始化权重，**没有训练任何一步**。所有精度相关结论（论文表 IV 的 50 vs 20/28、CCM 减少油门刹车冲突）都是论文在 CARLA/NoCrash 上的结果，**不能迁移到本项目游戏画面**。
2. **真机端到端延迟** —— §4.3 的 4.590ms 是 Python `MLModel.predict` 纯推理，**不含**：图像 resize/letterbox、CPU→ANE 内存拷贝、多模型调度、与 yolopx（已占 10.4ms）竞争、Swift 侧绑定开销。**是否满足 30ms 总预算 = 未测。**
3. **D=256 / depth 5+6 的精度收益** —— 这是「把 12M 预算用满」的结构决策，**未做与 D=192/depth4×2 的精度对照**。
4. **4-bit 量化后的精度损失** —— §4.5 的 4.43e-03 是**随机初始化权重**的偏差，只证明「流程可跑通、ANE 不掉」。训练后的量化损失需重测，并考虑 per-op 位宽分配。
5. **lane / dets 两路 token 的实际贡献** —— 未做消融（去掉这两路 token 对比精度）。
6. **时序模块的真实价值** —— 24 帧历史是否真的缓解 inertia，需训练 + 闭环评测（参考论文表 V 口径：统计「静止 8 秒未起步」的失败率）。
7. **截断骨干（低清前 2 层）的特征对齐质量** —— 需训练后监控 `f_hi` 与 `f_lo` 的分布距离（MMD / 余弦相似度）。
8. **CCM 的实际正则效果** —— 只验证了结构与冻结，未验证它能减少自相矛盾输出。
9. **真实标签分布与类权重** —— 03 文档 §5.4 的 `{W:0.80, A:0.10, D:0.07, S:0.03}` 是**假设值**；`V3Loss` 的类权重/`pos_weight` 默认全是 1.0，**真实权重必须由训练集统计后回填**。
10. **`ultimate` 与 vertical-S 的标签互斥规则** —— 见 §7 #2。
11. **多 batch 下的数值一致性** —— §4.5 只用全零输入、B=1 测了一组。
12. **CoreML 在 B>1 的导出** —— 只导了 B=1（部署契约如此）。

---

## §9 复现命令

```bash
cd "/Users/dupi/Desktop/自动驾驶系统"

# 1) 模型自检：打印参数量 + 8 个输出 shape
/usr/local/bin/python3.11 src/model_v3.py

# 2) 参数量 / shape 脚手架（含自校验，可用 --deploy 看折叠后）
/usr/local/bin/python3.11 tools/v3_exp/v3code_count.py --selftest
/usr/local/bin/python3.11 tools/v3_exp/v3code_count.py
/usr/local/bin/python3.11 tools/v3_exp/v3code_count.py --deploy --batch 3

# 3) CoreML 导出全流程（体积 / ANE 派发 / 延迟 / 一致性，约 40s）
/usr/local/bin/python3.11 tools/v3_exp/v3code_export.py --ios 18 --quant-mode palettize

# 4) 只看 fp16（不做 4-bit，速度更快）
/usr/local/bin/python3.11 tools/v3_exp/v3code_export.py --skip-quant

# 5) 复现 4-bit 线性量化的反例（ANE 掉到 66%、延迟变慢）
/usr/local/bin/python3.11 tools/v3_exp/v3code_export.py --ios 18 --quant-mode linear
```

产物落在 `/tmp/v3_model_code/`（`.mlpackage` 与 `report.json`），不污染仓库。

**关键实测数字出处**：
- 参数量 / 折叠等价性 / 边界测试：本文 §3，由 `/usr/local/bin/python3.11 src/model_v3.py` 与 §9 命令 2 产出
- CoreML 体积 / ANE 派发 / 延迟 / 一致性：`/tmp/v3_model_code/report.json`
- 训练期 loss / 梯度 / CCM 冻结：本文 §6，内联脚本实跑

---

## 附录：`src/model_v3.py` 结构索引

| 行号区间 | 内容 |
|---|---|
| 1–258 | 文件头 docstring（论文依据 / 设计决策 / ANE 红线 / 输出契约 / 未测项） |
| 260–323 | 默认超参数与输入契约常量 |
| 325–440 | `V3Config`（含 `validate()` fail-fast 校验：heads 整除、D≥144、帧数整除） |
| 442–514 | `RepVGGVisualBackbone`（含 `forward_truncated()` 供低清帧） |
| 516–601 | `TransformerBlock`(520) / `TransformerEncoderStage`(584) |
| 603–682 | `TemporalModuleV3`(607)（3 段×8 帧 + TCN 段间 + 时间位置编码） |
| 684–811 | `V3OutputHead`(688) / `IntentHead`(759) / `CommandCoherencyModule`(782) |
| 813–1166 | `V3Model`(817)（`__init__` / `forward` / `_encode_hi` / `_encode_lo` / 噪声注入 / `reparameterize` / `freeze_ccm` / `get_param_count`） |
| 1168–1333 | `V3Loss`(1172)（含序数 EMD） |
| 1335–1494 | `build_v3_model`(1339) / `get_model_stats`(1368) / `export_coreml`(1415) |
| 1496–1541 | `__main__` 自检（含折叠前后参数量对比） |
