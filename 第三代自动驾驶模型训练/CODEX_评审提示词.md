你是资深 Swift / CoreML / 机器学习评审员。请评审一次「把 INT4 量化的 V3 驾驶模型接入 AuroraDrive 引擎」的改动。

工作目录：/Users/dupi/Desktop/自动驾驶系统
⚠️ 这是**首次评审**，你无需任何前置上下文——所需背景都写在下面的材料里。

══════════ 一、先读这些文件 ══════════

材料（必读，自包含）：
  /tmp/v3_review/BRIEF_FIRST.md                        项目背景与契约
  /Users/dupi/Downloads/v3_int4_report.md              上一版 INT4 量化报告（对照）

核心代码：
  Sources/AuroraDrive/Inference/InferenceEngineV3.swift        引擎（约 1180 行，新增）
  Sources/AuroraDrive/Inference/V3EngineSelfTest.swift         三个测试入口（约 1700 行，新增）
  Sources/AuroraDrive/Inference/ConfidenceEstimator.swift      健康度（约 560 行，改）
  git diff Sources/AuroraDrive/App/AuroraDriveApp.swift        tick 驱动与命令仲裁（+340/-16）
  git diff Sources/AuroraDrive/Core/EngineMain.swift           reload 清单（+5/-1）

训练侧口径（权威基准，只读）：
  src/dataset_v3.py   帧窗口 :551-573 / vehicle_state :606-638 / 标签 :684-687 / 帧率 :88
  src/model_v3.py     V3Loss（含 L_coh / L_rollover）、_masked_bce
  src/train_v3.py     类权重、训练循环

键位映射（**枚举名与物理键相反**，最容易静默接错）：
  Sources/AuroraDrive/Control/ControlEngine.swift  Action :35-42、KeyMap :45-56
  `.handbrake` → 键码 49 = Space    `.boost` → 键码 56 = Shift
  而训练标签是 handbrake←shift列、brake←space列 → 模型 handbrake 头必须发 .boost(Shift)

══════════ 二、本次要审的完整改动链 ══════════

这是一次跨「数据 → 训练 → 量化 → 引擎接线」的完整修复，请**分段评审**：

【第 1 段：数据层修复】src/dataset_v3.py
  背景：录制器在部分片段把 shift/space 粘住了。实测 clip_20261104_131750
        帧 1190-2254 共 1065 帧（约 71 秒）shift 与 space 恒为 1，期间车速
        0→191km/h、玩家一直在按 W。人不可能连续 71 秒不松手刹与空格。
  修法：新增 modifier_valid_from_rows()，把「连续 ≥75 帧 shift∧space 同时为 1」
        的段标记为 modifier_valid=0；这些帧的 super_brake/ultimate 目标置 0。
        **vertical/horizontal 完全不动**（卡键只坏两个修饰键，不删帧）。
  请你判断：判定规则是否会误伤正常数据？mask 是否真的到达 loss？

【第 2 段：损失层修复】src/model_v3.py
  背景：原 L_rollover 的 violation = w(speed)·P(super_brake)·(1−P(S))，
        λ=2.0，而模仿损失 λ_key=0.8。只要标签里 super_brake=1 且高速，
        梯度就把 P(S) 往 1 推，与「该按 W」的 CE 标签直接对冲。
        我在 4 个 P(S) 取样点（0.05/0.2/0.5/0.9）实测 rollover 梯度
        绝对值全部大于 CE 反向梯度 → 模型被教成「看到超级刹车就踩 S」。
  修法：① 四个修饰键 BCE 走新增的 _masked_bce（按 modifier_valid 过滤）；
        ② L_rollover 增加「真实减速」硬门：只有 (上一帧车速 − 本帧车速) > 0.5km/h
           时才生效（卡键段车速平稳 → 不触发；真急刹 → 照常保护）。
  请你判断：0.5km/h 死区是否合理？decel 门是否削弱了防侧翻保护？

【第 3 段：类权重】src/train_v3.py
  背景：vertical 分布 W/NONE/S = 48637/3859/4366（W 占 85.5%，这是真实驾驶常态，
        不能改平数据）。纯逆频率权重给出 [0.121, 1.528, 1.351]，
        使「真 W 判成 NONE」的代价只有判对 W 的 12.6 倍，而 W 类正确与否
        在损失里几乎无足轻重 → 实测模型把 113 帧真 W 里的 85 帧压成 NONE。
  修法：改用平方根逆频率 [0.380, 1.350, 1.269]，比值降到 3.6 倍。
  请你判断：这个改动是否有依据？会不会导致「永远输出 W」的捷径？

【第 4 段：量化】新 INT4 模型
  方式：4-bit palettize（kmeans, nbits=4, granularity=per_tensor），iOS18。
        **纯权重量化**——coremltools 对 int4 激活抛
        "unrecognized output dtype"，int8 激活是 quantize→dequantize 假量化（只增开销）。
        源码确认：palettize_weights(mlmodel, config, joint_compression=False)，
        无任何校准参数；只有 linear_quantize_activations 才需要 sample_data。
  结果：93 个 constexpr_lut_to_dense 算子，6.08MB（fp16 23.43MB，压缩 3.85×）。

【第 5 段：引擎接线】
  models/v3_int4.mlmodelc 已替换为新训练权重。
  computeUnits = .cpuAndNeuralEngine（M3 实测 ANE 4.80ms / CPU 21.75ms / GPU 18.62ms）。
  编译 exit=0，--v3-selftest 20/20，--v3-integration 160帧/160推理/零注入。

══════════ 三、当前实测数据（请自行复跑核对，不要采信我的说法）══════════

【量化偏移：fp16 vs INT4，同一批真实帧、同一预处理、均 CPU_ONLY】
  六键最终动作（按生产链路推导：ultimate 强制 S；super_brake 蕴含 Shift+Space）
    片段      帧数   六键全同   一致率   仅修饰键不同   方向/纵向不同
    seg_a     137      125     91.24%        10              2
    seg_b     137       96     70.07%        29             12
    seg_c     137      126     91.97%         0             11
    seg_d     137       97     70.80%        37              3
    seg_e     137      137    100.00%         0              0
    合计      685      581     84.82%        76             28 (4.09%)
  方向头 argmax 一致率：98.54% ~ 100%
  ⚠️ 上一版 INT4 的安全头决策翻转率最高 2.1%；本版各头翻转率明显更高
     （seg_d 的 brake 头达 27%）。请评估这个退化是否可接受。

【引擎端质检 --v3-qc（注意：这里有个我必须主动交代的问题）】
    seg_a vertical 91.18% / horizontal 91.18%
    seg_b vertical 46.32% / horizontal 97.06%
    seg_c vertical 94.12% / horizontal 86.03%
    seg_d vertical 98.53% / horizontal 80.15%
    seg_e vertical 72.79% / horizontal 91.91%

  ⚠️⚠️ **重要：我复现了训练时的验证集划分（seed=42, val_ratio=0.1），
     11 个 clip 里只有 1 个是验证集：clip_20261107_110525（6889 样本，
     与日志 train=49973 val=6889 吻合）。而上面 5 个质检片段中：
        seg_a / seg_b / seg_c / seg_e  ← 全部来自**训练集**（模型见过）
        seg_d                          ← 唯一来自验证集
     也就是说上面大部分数字是「背答案」的成绩，不能代表泛化能力。
     请把这一点纳入你的判断：不要把它们当作泛化指标。

【训练日志实测（~/Downloads/train (1).log 最后一次启动）】
  best_epoch = 1（15 轮里第 1 轮最好），best_select = 0.8393
  val_loss: 1.79(ep1) → 1.66 → 1.57 → 1.78 → ... → 2.76(ep15)
  train_loss: 2.24 → 1.49 → ... → 0.48
  → 严重过拟合；且验证集只有 1 个 clip，模型选择本身不可靠。
  上一版（纯逆频率权重）best_epoch=4, select=0.8428。

══════════ 四、请重点评审 ══════════

A. 数据/训练侧（第 1-3 段）
   1. modifier_valid 判定是否会误伤正常数据？mask 在 __getitem__ 与 loss 两侧是否一致？
   2. L_rollover 的「真实减速」硬门是否削弱了原本的防侧翻保护？
      原来的安全意图是「高速想按超级刹车却不按 S 会侧翻」——现在只在减速时罚，
      真的足够吗？
   3. 平方根逆频率是否有依据？会不会重新引入「永远输出 W」的捷径？

B. 量化（第 4 段）
   4. 4-bit palettize 后方向头 98.5%+ 一致、但六键动作只有 84.82% 一致
      （4.09% 帧方向/纵向不同）。这个量化偏移是否可接受？
   5. 过拟合（best_epoch=1）是否正是量化偏移变大的原因？（我怀疑权重更尖锐，
      4-bit 每张量仅 16 个代表值，聚类破坏更大。）请判断这个推测是否成立。

C. 引擎接线（第 5 段）
   6. 请把上一版的 P0/P1 项逐条复核是否仍成立：输入新鲜度（currentFrameCGAt >1s 不推理）、
      决策时效（v3DecisionFresh 1.0s，刹车头与四向命令同一判据）、
      执行反馈（finish() 不再覆盖 previousHorizontalClass，由 noteExecutedSteer 回填）、
      控制权仲裁（mayDriveByV3 = v3ReadyForControl && decided == .e2e，
      停控时 laneAssistAllowed 挡住车道/地图改写）。
   7. 内存安全：本类已发生过真实崩溃——某属性漏 @ObservationIgnored，
      被 @Observable 宏包装成 _ManagedCriticalState，后台队列访问 → SIGSEGV(exit=139)。
      请审计本类**全部**存储属性：凡在 queue.async 闭包内访问的，是否都带 @ObservationIgnored？
   8. 键位映射：`.handbrake`=Space / `.boost`=Shift 这个反直觉映射，
      在 applyV3BrakeHeads 与 ultimate 强制 S 的逻辑里是否正确？

D. 未解决/未验证的部分（请勿当作已验证）
   9. **真实游戏场景完全未验证**：测试时游戏没运行，引擎抓到的是桌面窗口。
   10. 泛化能力未验证：唯一干净验证集只有 1 个 clip（seg_d）。
   11. 无 frame-level 时间对齐验证。
   12. QC 的 handbrake/super_brake 头在 seg_a 报失败，是因为该段真值
       因卡键恒为 1（模型不输出 1 反而对），这三个头在该段不可作为验收依据。

══════════ 五、可自行复跑的只读命令 ══════════
  swift build --product AuroraDrive
  ./.build/arm64-apple-macosx/debug/AuroraDrive --v3-selftest
  ./.build/arm64-apple-macosx/debug/AuroraDrive --v3-integration --dir /tmp/v3_qc_multi/seg_a
  ./.build/arm64-apple-macosx/debug/AuroraDrive --v3-qc --dir /tmp/v3_qc_multi/seg_d
  grep / sed 读代码

  测试数据：/tmp/v3_qc_multi/seg_{a,b,c,d,e}/  每个 160 帧真实训练帧 + labels.csv

══════════ 六、硬纪律 ══════════
- **不要修改任何文件**，只做评审。
- **不要提没有依据的意见**。任何"可能会/也许是"必须标「推测」并说明无法验证的原因。
- **绝不运行**会启动 GUI、注入按键、修改系统状态的命令。禁止联网。
- 若某处属于**有意保留的设计**（如「V3 失效不自动降级」是用户明确要求），
  不要按缺陷报，可提风险提示。

══════════ 七、输出格式 ══════════
### P0（必须修：错误驾驶行为 / 崩溃 / 数据竞争）
### P1（应该修）
### P2（建议）
每条含：**结论** / **证据（文件:行号）** / **后果** / **建议修法**。某级无问题写「无」。
最后总评：**能否交付**，若不交付还差哪几项。
特别回答：**这个模型现在能不能上车用？如果不能，最关键的 1-2 项是什么？**
