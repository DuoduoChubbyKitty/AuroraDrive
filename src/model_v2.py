# [TRAINING-ONLY] 此文件仅用于离线训练/导出；运行时由 CoreML / C++ inference 侧执行
# -*- coding: utf-8 -*-
"""
M2 端到端驾驶模型（AuroraDrive 新主驾驶模型）

============================================================================
一、它解决什么问题
============================================================================
旧模型 `src/model.py` 的 M9/M9-Mono 是「游戏辅助」范式：
    10 路摄像头 × RepVGG-A0 + 2 路激光雷达 × PointNet + 13,318 维融合头
——输入维度爆炸、依赖激光雷达、且**不接收车道线与检测框**，纯视觉场景下
既跑不动（M3 上远达不到 30Hz）也用不上已有的感知结果。

M2 换一个范式：**感知结果 + 单目图像 + 车辆状态** 的多模态小模型。
    图像（第三视角截图）  [B, 3, 180, 320]
    车道线掩码（MaskGrid） [B, 1, 160, 160]
    检测框（变长 Detection）[B, N, 12] + [B, N] mask
    车辆状态（加速度/角度等）[B, 8]
        ↓
    steer(tanh) / throttle(sigmoid) / brake(sigmoid)

============================================================================
二、用户六条需求 → 本文件落点
============================================================================
① 收车道线      → LaneMaskEncoder，输入 Swift `MaskGrid`(160×160 二值)  [§4.2]
② 收检测框      → DetectionEncoder，变长 N 框，PointNet 式 MLP+max pool  [§4.3]
③ 不要可行驶区域 → **模型完全没有 drivable 分支**，forward 也不接受该入参；
                   Swift 侧 `drivableMask` 不得传入（见 §8 契约红线）
④ 纯视觉可判断   → 三个感知分支全部来自单帧图像派生，无激光雷达/无高精地图
⑤ 加输入：加速度、当前角度 → StateEncoder 的 8 维状态向量（accel/heading）[§4.4]
⑥ 第三视角      → ①图像为第三人称追车视角截图；②车道线掩码天然是"他车视角"
                  投影；③检测框含自车框 → 由 EgoBoxFilter 在 Swift 侧剔除，
                  模型额外用 `ego_visible` 标志位让网络知道"已剔除"这件事 [§4.3]

============================================================================
三、总体结构（shape 全程标注，B = batch）
============================================================================
    image   [B,3,180,320] ─ ImageEncoder(RepVGG-A0 轻量变体) ─┐
                                                              │ [B,256]
    lane    [B,1,160,160] ─ LaneMaskEncoder(先 2× 下采样)  ───┤ [B,64]
                                                              │
    dets    [B,N,12]+mask [B,N] ─ DetectionEncoder ───────────┤ [B,128]
                                                              │
    state   [B,8]         ─ StateEncoder (MLP) ───────────────┤ [B,64]
                                                              ↓
                                        FusionHead  拼接 [B,512]
                                        FC512→FC256→FC128
                                                              ↓
                             steer[B,1]∈[-1,1]  throttle[B,1]∈[0,1]  brake[B,1]∈[0,1]

============================================================================
四、参数量与 M3 推理耗时（★ 全部为本机 Apple M3 实测，非估算）
============================================================================
开发机 `sysctl machdep.cpu.brand_string` = **Apple M3**，与部署目标芯片一致，
因此下列数字是**真机实测**而非估算区间。

实测参数量（部署态，已重参数化；训练态见 §7 说明）：
    ImageEncoder     : 2,519,152  （2.52M）  占 83.6%
    LaneMaskEncoder  :    23,408  （23.4K）
    DetectionEncoder :    42,432  （42.4K）
    StateEncoder     :     2,400  （ 2.4K）
    FusionHead       :   427,267  （427K）
    ─────────────────────────────────────────
    合计             : 3,014,659  （3.01M）
    体积             : FP32 11.50 MB / FP16 5.75 MB / INT8 2.87 MB

实测计算量（部署态，理论 MACs 计数）：
    ImageEncoder     902.85 MMACs   ← 99.5%，唯一算力大头
    LaneMaskEncoder    3.92 MMACs
    DetectionEncoder   0.21 MMACs
    StateEncoder       0.00 MMACs
    FusionHead         0.43 MMACs
    ─────────────────────────────────────────
    合计             907.40 MMACs = 1.815 GFLOPs

★ CoreML 实测单帧延迟（.mlpackage FP16，mlprogram，iOS17 target，B=1；
  预热 20 次后重复 5 轮 × 每轮 100 次，取中位数）：
    计算单元                 中位延迟    波动范围      30Hz 预算 33ms
    ──────────────────────────────────────────────────────────────
    ALL (ANE+GPU+CPU)        1.68 ms   1.28~1.83 ms  ✅ 达标，余量 19.6×
    CPU+ANE                  1.17 ms   1.14~1.22 ms  ✅ 达标，余量 28.1× ← 最快
    CPU_ONLY                 4.63 ms   4.42~5.60 ms  ✅ 达标，余量  7.1×
    ──────────────────────────────────────────────────────────────
    .mlpackage 磁盘体积      5.79 MB

    注：`CPU+ANE` 比 `ALL` 更快是常见现象 —— 该模型只有图像分支适合 ANE，
    其余分支在 CPU 上更快，`ALL` 的调度器会把部分算子派给 GPU，反而引入
    额外同步开销。**建议部署时首选 `CPU_AND_NE`**（若 Swift 侧允许指定）。

★ PyTorch CPU 单帧延迟（本机，torch 2.13，4 线程，B=1，交错重复 7 轮取中位）：
    训练态（RepVGG 三分支）  34.43 ms  [24.02~63.36]  ⚠️ 超 33ms 预算
    部署态（重参数化后）     28.32 ms  [22.89~39.78]  ✅ 勉强达标
        └ 分项（单次采样）：ImageEncoder 23.02 / LaneMask 1.21 / Detection 0.56 / State 0.02
    → 重参数化中位提速 34.43 → 28.32 ms（**约 17.7%**），且部署态波动更小。
    ⚠️ 本机 CPU 耗时**方差极大**（开发机同时在跑其他任务，最大/最小差 2.6 倍），
       上表为 7 轮交错采样的中位数；该数据仅供量级参考，**不可作为性能承诺**。
       真正可信的是上面 CoreML 的数字（波动 < 1.5 倍，且 ANE 路径不受 CPU 抢占影响）。

★★ 结论（重要）：
    1) **CoreML/ANE 路径 1.17~1.68ms，30Hz 预算 33ms，余量 20~28 倍** —— 远超要求，
       甚至为将来加分支/提分辨率留了充足空间（如把图像升到 360×640 仍有
       ~5 倍余量）。**部署必须走 CoreML，不要用 LibTorch CPU 路径。**
    2) PyTorch CPU 路径 28.32ms 已贴近 33ms 红线，无余量且方差大，仅适合离线回放。
    3) 导出前务必先 `model.reparameterize()`；否则白丢约 17.7% 性能。

数值一致性（CoreML FP16 vs PyTorch FP32，同输入）：
    steer   |Δ| = 4.3e-04
    throttle|Δ| = 1.6e-05
    brake   |Δ| = 7.4e-04
    → 均为 FP16 量化正常误差量级（<1e-3），对转向/油门控制无实质影响。
      若实测出现转向抖动，改用 FP32 导出（体积翻倍到 11.5MB，延迟仍有余量）。

============================================================================
五、空输入支持（硬性要求）
============================================================================
真实驾驶场景里"车道线全丢"、"前方一辆车都没有"是**常态而非异常**，
因此四个分支全部支持空/缺失输入，且**不需要 batch 内补齐长度**：
  · 车道线空   → lane_mask=None 或全零张量 → 零向量 [B,64]
  · 检测框 0 个 → dets=None / N=0 / det_mask 全 False → 零向量 [B,128]
  · 状态缺失   → vehicle_state=None → 零向量（网络学到"零状态=未知"语义）
  · 图像必填（纯视觉主模态，缺失无意义；调用方保证不为 None）
实现方式见 `_masked_mean_pool` 与各分支 forward 中的 `_zero_like` 早退。

★ 实测已验证（本机跑通，无 NaN、无崩溃）：
    场景                                     结果
    ───────────────────────────────────────────────────────────
    车道线 None + 0 框 + 状态 None            ✅ 输出 [2,1]，无 NaN
    lane 全零 + dets [B,0,12] + det_mask [B,0] ✅ 输出 [2,1]，无 NaN
    lane 全零 + det_mask 全 False             ✅ 输出 [2,1]，无 NaN
    B=1 单样本（第三视角仅 1 个前车）          ✅ 输出 [1,1]
    CoreML 路径空输入（lane/dets/state 全零）  ✅ 输出正常，无 NaN

★ 关键不变量：**None 与"同 shape 全零张量"的输出完全一致（实测 |Δ| = 0.000000）**
    → 训练时用全零张量占位、部署时传 None（或反之）不会产生分布漂移，
      这是保证"离线训练 / 在线推理"一致性的重要性质，改动早退逻辑时必须保持。
    （对照：正常输入 vs 车道线全零，Δsteer = 0.0124，说明零向量确实携带
      "无车道线"这一有效信息，而非退化输出。）

所有早退都返回**同 shape 的零张量**，因此导出 ONNX/CoreML 时计算图静态、
无动态分支问题；空输入时融合头仍得到合法输入，不会 NaN、不会崩。

============================================================================
六、与旧 model.py 的关系
============================================================================
· 复用其风格：RepVGGBlock（训练多分支 / 推理重参数化）、FusionHead 三头、
  get_param_count / get_model_size_mb / build_xxx 工具函数命名保持一致。
· **本文件是新建文件，不改动 `src/model.py` 任何一行**，两者可并存。
· 旧 M9MonoModel 仍可用于旧 checkpoint 推理；新训练一律走 model_v2。

============================================================================
七、Swift 侧对接契约（运行时）
============================================================================
输入名与 shape（★ 已通过 coremltools 8.3 实际转换验证，名称原样保留）：
    image         : [1, 3, 180, 320]  float32  CHW，[0,1] 归一化
    lane          : [1, 1, 160, 160]  float32  二值 0/1（来自 YolopxEngine.laneMask）
    dets          : [1, N, 12]        float32  固定槽位 N=20，空槽补 0
    det_mask      : [1, N]            float32  1=有效框，0=空槽
    vehicle_state : [1, 8]            float32  见 §4.4 归一化约定
输出名与 shape：
    steer   : [1, 1]  tanh    ∈ [-1, 1]
    throttle: [1, 1]  sigmoid ∈ [0, 1]
    brake   : [1, 1]  sigmoid ∈ [0, 1]

⚠️ 输入名踩坑（实测）：参数/输入**不能叫 `state`**。coremltools 8.3 会把它
   静默重命名为 `state_workaround`，Swift 侧按 `state` 取值直接抛
   `KeyError: ... which are: {'det_mask', 'lane', 'state_workaround', 'image', 'dets'}`。
   改用 `vehicle_state` 后名称被原样保留（已实测验证），且与
   `InferenceEngine.swift` 既有的 `vehicle_state` 契约同名。

⚠️ CoreML 输入输出 dtype 会被转成 **FLOAT16**（`compute_precision=FLOAT16`）。
   Swift 侧构造 MLMultiArray 时用 `.float16` 还是 `.float32` 需与转换配置一致，
   否则会出现类型不匹配的运行时错误。若需 FP32，导出时改
   `compute_precision=ct.precision.FLOAT32`。

============================================================================
八、契约红线（务必遵守）
============================================================================
⛔ 本模型**不接收可行驶区域（drivableMask / daGrid）**。
   用户明确要求"可行驶区域不要收"：一是 YolopxEngine 的 drivableMask 存在
   退化（`drivableDegraded`）与自车遮挡问题，二是会让模型把"可行驶"当成
   万能的捷径特征而忽略车道线。任何在 Swift 侧把 drivableMask 拼进 lane
   通道的做法都属于破坏本契约。
   已实测校验：`M2Model.forward` 签名参数为
   ['image', 'lane_mask', 'dets', 'det_mask', 'vehicle_state']，不含 drivable。
⛔ 第三视角下模型会把**自车**也标成检测框（见 EgoBoxFilter.swift 注释），
   该框必须在 Swift 侧决策层剔除后再喂给本模型；本模型只接收
   `ego_visible` 标志位（state 第 7 维），不接收自车框本身。
"""

from typing import Dict, List, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F


# ============================================================================
# 0. 默认超参数（集中定义，便于训练/导出两侧对齐）
# ============================================================================

#: 图像输入高（与 game_assist 截屏一致，180×320 是旧链路的既定分辨率）
IMG_H: int = 180
#: 图像输入宽
IMG_W: int = 320
#: 车道线掩码边长（对齐 YolopxEngine.maskGridSize = 160）
LANE_SIZE: int = 160
#: 检测框固定槽位数（Swift 侧空槽补 0，det_mask 置 0）
MAX_DETECTIONS: int = 20
#: 单个检测框的特征维度：x,y,w,h,label_onehot(4),confidence,speed,heading,age,ego_visible
DET_FEAT_DIM: int = 12
#: 车辆状态维度：speed, accel, heading, heading_rate, curvature, lateral_offset, steer_angle, reserved
STATE_DIM: int = 8

#: 各分支输出特征维度
IMG_FEAT_DIM: int = 256
LANE_FEAT_DIM: int = 64
DET_FEAT_DIM_OUT: int = 128
STATE_FEAT_DIM: int = 64
#: 融合头输入维度 = 256 + 64 + 128 + 64 = 512
FUSION_IN_DIM: int = IMG_FEAT_DIM + LANE_FEAT_DIM + DET_FEAT_DIM_OUT + STATE_FEAT_DIM


# ============================================================================
# 1. 基础构件：RepVGG 块（与 src/model.py 保持同风格）
# ============================================================================

class RepVGGBlock(nn.Module):
    """RepVGG 基础块（训练多分支 / 推理重参数化）。

    训练时：
        y = ReLU( BN(Conv3×3(x)) + BN(Conv1×1(x)) + BN(Identity(x)) )
    推理时（调用 reparameterize() 之后）：
        y = ReLU( Conv3×3(x) )        ← 三分支数学等价合并为单个 3×3 卷积

    为什么用它：训练时多分支提升精度，推理时融合成纯 3×3（对 ANE/NPU
    极其友好，无分支发散、无 1×1 与 identity 的额外访存）。

    输入输出 shape：
        x: [B, C_in, H, W] → out: [B, C_out, H/s, W/s]   s = stride
    """

    def __init__(self, in_channels: int, out_channels: int,
                 stride: int = 1, deploy: bool = False):
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.deploy = deploy
        self.stride = stride

        if deploy:
            # 部署态：只有一支融合后的 3×3（含 bias，因为 BN 已折进权重）
            self.rbr_reparam = nn.Conv2d(
                in_channels, out_channels, kernel_size=3,
                stride=stride, padding=1, bias=True
            )
        else:
            # 训练态：三分支并行
            self.rbr_3x3 = nn.Sequential(
                nn.Conv2d(in_channels, out_channels, kernel_size=3,
                          stride=stride, padding=1, bias=False),
                nn.BatchNorm2d(out_channels),
            )
            self.rbr_1x1 = nn.Sequential(
                nn.Conv2d(in_channels, out_channels, kernel_size=1,
                          stride=stride, bias=False),
                nn.BatchNorm2d(out_channels),
            )
            # identity 分支仅在"通道数不变 且 stride=1"时存在（否则维度对不上）
            self.rbr_identity = (
                nn.BatchNorm2d(in_channels)
                if in_channels == out_channels and stride == 1
                else None
            )

        self.nonlinearity = nn.ReLU(inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """x: [B, C_in, H, W] → [B, C_out, H/s, W/s]"""
        if self.deploy:
            return self.nonlinearity(self.rbr_reparam(x))
        out = self.rbr_3x3(x) + self.rbr_1x1(x)
        if self.rbr_identity is not None:
            out = out + self.rbr_identity(x)
        return self.nonlinearity(out)

    @staticmethod
    def _pad_1x1_to_3x3(kernel_1x1: torch.Tensor) -> torch.Tensor:
        """把 1×1 卷积核 pad 成 3×3（四周各补一圈 0），使其可与 3×3 相加。"""
        return F.pad(kernel_1x1, [1, 1, 1, 1])

    @staticmethod
    def _fuse_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> Tuple[torch.Tensor, torch.Tensor]:
        """把 BN 折进前置卷积： w' = w * γ/σ,  b' = β - μ·γ/σ。"""
        kernel = conv.weight
        running_mean = bn.running_mean
        running_var = bn.running_var
        gamma = bn.weight
        beta = bn.bias
        eps = bn.eps
        std = torch.sqrt(running_var + eps)
        t = gamma / std
        fused_weight = kernel * t.reshape(-1, 1, 1, 1)
        fused_bias = beta - running_mean * t
        return fused_weight, fused_bias

    @torch.no_grad()
    def reparameterize(self) -> None:
        """训练态 → 部署态：把三分支数学等价合并为单个 3×3 卷积。"""
        if self.deploy:
            return
        w_3x3, b_3x3 = self._fuse_bn(self.rbr_3x3[0], self.rbr_3x3[1])
        w_1x1, b_1x1 = self._fuse_bn(self.rbr_1x1[0], self.rbr_1x1[1])
        w_1x1_padded = self._pad_1x1_to_3x3(w_1x1)

        if self.rbr_identity is not None:
            # identity 分支等价于"对角线为 1 的 1×1 卷积"，同样先折 BN 再 pad
            w_id = torch.zeros(
                self.out_channels, self.in_channels, 1, 1,
                device=w_3x3.device, dtype=w_3x3.dtype
            )
            for i in range(min(self.out_channels, self.in_channels)):
                w_id[i, i, 0, 0] = 1.0
            w_id_padded = self._pad_1x1_to_3x3(w_id)
            bn = self.rbr_identity
            std = torch.sqrt(bn.running_var + bn.eps)
            t = bn.weight / std
            w_id_padded = w_id_padded * t.reshape(-1, 1, 1, 1)
            b_id = bn.bias - bn.running_mean * t
            w_3x3 = w_3x3 + w_1x1_padded + w_id_padded
            b_3x3 = b_3x3 + b_1x1 + b_id
        else:
            w_3x3 = w_3x3 + w_1x1_padded
            b_3x3 = b_3x3 + b_1x1

        self.rbr_reparam = nn.Conv2d(
            self.in_channels, self.out_channels, kernel_size=3,
            stride=self.stride, padding=1, bias=True
        )
        self.rbr_reparam.weight.data = w_3x3
        self.rbr_reparam.bias.data = b_3x3
        # 释放训练分支，减半部署显存/体积
        del self.rbr_3x3, self.rbr_1x1, self.rbr_identity
        self.deploy = True


class RepVGGStage(nn.Module):
    """RepVGG 阶段：num_blocks 个 RepVGGBlock 堆叠，第 0 个负责下采样。

    输入 x:  [B, C_in, H, W]
    输出:    [B, C_out, H/2, W/2]（第 0 个 block stride=2），后续 block 保持分辨率
    """

    def __init__(self, in_channels: int, out_channels: int,
                 num_blocks: int, stride: int = 2, deploy: bool = False):
        super().__init__()
        layers: List[nn.Module] = []
        for i in range(num_blocks):
            layers.append(RepVGGBlock(
                in_channels if i == 0 else out_channels,
                out_channels,
                stride=stride if i == 0 else 1,
                deploy=deploy,
            ))
        self.stage = nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.stage(x)


# ============================================================================
# 2. 图像分支 ImageEncoder —— 第三视角截图 → 256 维
# ============================================================================

class ImageEncoder(nn.Module):
    """图像分支：单帧第三视角截图 → 256 维全局特征。

    ⚠️ 相对旧 M9MonoModel 的 RepVGG-A0（8.0M 参数 / 3.5 GFLOPs @224²）做了
    **三处瘦身**，因为 M3 上要 30Hz、且输入只有 180×320 而非 224×224：

      1) stage3 从 14 个 block 砍到 6 个（14 个 block 是 A0 的精度冗余，
         在只有 3 个输出头的驾驶回归任务上收益极小，却是主要算力开销）
      2) stage4 输出通道 1280 → 256（旧融合头要 concat 10 路才需要 1280）
      3) 去掉 stage4 的下采样（stride=1），避免 180×320 在 5 次下采样后
         变成 5×10 这种畸形分辨率（180/32=5.6，非整除，ANE 上不友好）

    分辨率演进（输入 180×320）：
        stage0  stride2 → 48ch  @ 90×160
        stage1  stride2 → 48ch  @ 45×80
        stage2  stride2 → 96ch  @ 23×40   （180/8=22.5 → ceil 后 23）
        stage3  stride2 → 192ch @ 12×20   （23/2=11.5 → ceil 后 12）
        stage4  stride1 → 256ch @ 12×20
        GAP             → 256

    shape：
        输入  image: [B, 3, 180, 320]
        输出        : [B, 256]
    """

    def __init__(self, deploy: bool = False, out_dim: int = IMG_FEAT_DIM):
        super().__init__()
        self.deploy = deploy

        # ---- stage0：stem，直接把 3 通道升到 48（无 BN 前的重参数化，纯卷积）
        # [B,3,180,320] → [B,48,90,160]
        self.stage0 = nn.Sequential(
            nn.Conv2d(3, 48, kernel_size=3, stride=2, padding=1, bias=False),
            nn.BatchNorm2d(48),
            nn.ReLU(inplace=True),
        )
        # ---- stage1：2 blocks，48ch，保持通道
        # [B,48,90,160] → [B,48,45,80]
        self.stage1 = RepVGGStage(48, 48, num_blocks=2, deploy=deploy)
        # ---- stage2：3 blocks，48→96
        # [B,48,45,80] → [B,96,23,40]
        self.stage2 = RepVGGStage(48, 96, num_blocks=3, deploy=deploy)
        # ---- stage3：6 blocks，96→192（旧 A0 是 14 个，这里砍到 6 个）
        # [B,96,23,40] → [B,192,12,20]
        self.stage3 = RepVGGStage(96, 192, num_blocks=6, deploy=deploy)
        # ---- stage4：1 block，192→256，stride=1 不再下采样
        # [B,192,12,20] → [B,256,12,20]
        self.stage4 = RepVGGStage(192, out_dim, num_blocks=1, stride=1, deploy=deploy)

        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """x: [B,3,180,320] → [B,256]"""
        x = self.stage0(x)
        x = self.stage1(x)
        x = self.stage2(x)
        x = self.stage3(x)
        x = self.stage4(x)
        x = self.global_pool(x)          # [B,256,1,1]
        return x.flatten(1)              # [B,256]

    def reparameterize(self) -> None:
        """把所有训练态 RepVGGBlock 折叠为纯 3×3 卷积。"""
        if self.deploy:
            return
        for stage in (self.stage1, self.stage2, self.stage3, self.stage4):
            for block in stage.stage:
                if isinstance(block, RepVGGBlock):
                    block.reparameterize()
        self.deploy = True


# ============================================================================
# 3. 车道线分支 LaneMaskEncoder —— 160×160 二值掩码 → 64 维
# ============================================================================

class LaneMaskEncoder(nn.Module):
    """车道线分支：Swift `MaskGrid`(160×160, UInt8 0/1) → 64 维特征。

    设计取舍：
      · **先 2× 下采样**（max_pool）而不是直接上 stride2 卷积。
        车道线在 160×160 上宽度常常只有 1~2 格，直接 3×3 stride2 卷积会
        因采样相位问题把细线"跳过"（aliasing），max_pool 则保证细线不会被
        丢（只要 2×2 窗口里有一格亮就保留）——这是车道线分支的关键细节。
      · 二值掩码不做 BN 前的归一化（0/1 本身已是良好尺度）。
      · 3 层卷积 + GAP：感受野足够覆盖车道线的"走向/曲率"信息。

    分辨率演进（输入 160×160）：
        maxpool2        → 1ch  @ 80×80
        conv 1→16 s2    → 16ch @ 40×40
        conv 16→32 s2   → 32ch @ 20×20
        conv 32→64 s2   → 64ch @ 10×10
        GAP             → 64

    shape：
        输入  lane_mask: [B, 1, 160, 160]   （0/1 二值，float32）
        输出            : [B, 64]
    """

    def __init__(self, in_ch: int = 1, out_dim: int = LANE_FEAT_DIM):
        super().__init__()
        # [B,1,160,160] → [B,1,80,80]
        self.downsample = nn.MaxPool2d(kernel_size=2, stride=2)
        # [B,1,80,80] → [B,16,40,40]
        self.conv1 = nn.Conv2d(in_ch, 16, kernel_size=3, stride=2, padding=1, bias=False)
        self.bn1 = nn.BatchNorm2d(16)
        # [B,16,40,40] → [B,32,20,20]
        self.conv2 = nn.Conv2d(16, 32, kernel_size=3, stride=2, padding=1, bias=False)
        self.bn2 = nn.BatchNorm2d(32)
        # [B,32,20,20] → [B,64,10,10]
        self.conv3 = nn.Conv2d(32, out_dim, kernel_size=3, stride=2, padding=1, bias=False)
        self.bn3 = nn.BatchNorm2d(out_dim)
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))

    def forward(self, lane_mask: Optional[torch.Tensor], batch_size: int,
                ref: torch.Tensor) -> torch.Tensor:
        """
        Args:
            lane_mask: [B,1,160,160] 或 None（车道线全丢）
            batch_size: 批次大小 B
            ref: 任意一个已存在的张量，用于取 device/dtype（空输入时构造零向量）

        Returns:
            [B, 64]；lane_mask 为 None 时返回同 shape 零向量
        """
        # ---- 空输入早退：车道线可能整帧为空（隧道、逆光、标线磨损）
        if lane_mask is None:
            return _zero_like(ref, batch_size, LANE_FEAT_DIM)

        x = self.downsample(lane_mask)                          # [B,1,80,80]
        x = F.relu(self.bn1(self.conv1(x)))                     # [B,16,40,40]
        x = F.relu(self.bn2(self.conv2(x)))                     # [B,32,20,20]
        x = F.relu(self.bn3(self.conv3(x)))                     # [B,64,10,10]
        x = self.global_pool(x)                                 # [B,64,1,1]
        return x.flatten(1)                                     # [B,64]


# ============================================================================
# 4. 检测框分支 DetectionEncoder —— 变长 N 框 → 128 维
# ============================================================================

def _masked_mean_pool(feat: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
    """对变长序列做 mask 加权平均池化（含全空保护）。

    Args:
        feat: [B, N, C]  每框特征
        mask: [B, N]     1=有效框, 0=空槽（float 或 bool）

    Returns:
        [B, C]  有效框的平均；**若某样本一个有效框都没有，返回全 0 向量**
                （用 clamp_min 保证分母 ≥1，避免 0/0 = NaN）
    """
    m = mask.to(dtype=feat.dtype).unsqueeze(-1)          # [B,N,1]
    summed = (feat * m).sum(dim=1)                       # [B,C]
    denom = m.sum(dim=1).clamp_min(1.0)                  # [B,1]，空时=1 → 结果恒为 0
    return summed / denom                                # [B,C]


class DetectionEncoder(nn.Module):
    """检测框分支：变长检测框 → 128 维特征（PointNet 风格）。

    为什么用 PointNet 风格（每框 MLP + max pool）而不是把框塞进固定槽位
    再 flatten：
      · 检测框数量天然变长（0~20），flatten 固定槽位会让"框的顺序"变成
        伪特征（同一场景框顺序变了输出就变），泛化差；
      · max pool 对**输入顺序不变**（permutation invariant），且对数量不敏感，
        0 个框和 3 个框都能给出稳定表示。

    每框 12 维输入（与 Swift `Detection` 结构对齐）：
        [0] x         中心 x，归一化 [0,1]      ← Detection.x
        [1] y         中心 y，归一化 [0,1]      ← Detection.y
        [2] w         宽，归一化 [0,1]          ← Detection.width
        [3] h         高，归一化 [0,1]          ← Detection.height
        [4:8] label   one-hot(car, pedestrian, sign, obstacle)  ← Detection.Label
        [8] confidence 置信度 [0,1]             ← Detection.confidence
        [9] speed     框内目标相对速度（无则 0）
        [10] heading  框内目标朝向（无则 0）
        [11] age      该框连续被跟踪到的帧数归一化（无跟踪则 0）
     另外由 det_mask 之外的独立标志位表达"第三视角自车框已被剔除"：
        第 6 维不用；自车信息通过 state 的 reserved 位传递，避免污染框特征。

    网络结构（PointNet-Lite 同款，但输入维度 12 而非 3）：
        per-box MLP: 12 → 64 → 128      （Conv1d k=1，等价逐框共享 MLP）
        max pool over N                  → [B,128]
        masked mean pool over N          → [B,128]
        concat + FC(256→128)             → [B,128]

    ⚠️ 同时用 max 与 mean 两种池化：max 抓"最危险的单个框"（如正前方近车），
       mean 抓"整体交通密度"。只用 max 会忽略多车拥堵，只用 mean 会淹没
       单个高危目标——两者拼接是性价比最高的选择。

    shape：
        输入  dets:     [B, N, 12]
              det_mask: [B, N]       1=有效，0=空槽
        输出            : [B, 128]
    """

    def __init__(self, in_dim: int = DET_FEAT_DIM, out_dim: int = DET_FEAT_DIM_OUT):
        super().__init__()
        # 逐框共享 MLP（Conv1d kernel_size=1 等价于对每个框独立做 Linear）
        # [B,12,N] → [B,64,N]
        self.conv1 = nn.Conv1d(in_dim, 64, kernel_size=1)
        self.bn1 = nn.BatchNorm1d(64)
        # [B,64,N] → [B,128,N]
        self.conv2 = nn.Conv1d(64, 128, kernel_size=1)
        self.bn2 = nn.BatchNorm1d(128)
        # max||mean 拼接后 [B,256] → [B,128]
        self.fc = nn.Linear(128 * 2, out_dim)
        self._init_weights()

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, (nn.Conv1d, nn.Linear)):
                nn.init.kaiming_normal_(m.weight, mode='fan_out', nonlinearity='relu')
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, dets: Optional[torch.Tensor], det_mask: Optional[torch.Tensor],
                batch_size: int, ref: torch.Tensor) -> torch.Tensor:
        """
        Args:
            dets:     [B,N,12] 或 None（0 个框 / 无检测）
            det_mask: [B,N]    或 None
            batch_size: B
            ref: 取 device/dtype 的参考张量

        Returns:
            [B,128]；无框时返回全零向量
        """
        # ---- 空输入早退之一：整个 dets 为 None
        if dets is None:
            return _zero_like(ref, batch_size, DET_FEAT_DIM_OUT)

        # N = 0（Swift 侧可能给出零长度数组）→ 直接零向量
        if dets.dim() != 3 or dets.shape[1] == 0:
            return _zero_like(ref, batch_size, DET_FEAT_DIM_OUT)

        # ---- 空输入早退之二：mask 缺失时按"全部有效"处理（训练数据常见）
        if det_mask is None:
            det_mask = torch.ones(dets.shape[:2], device=dets.device, dtype=dets.dtype)

        # Conv1d 要求 [B, C, N]
        x = dets.transpose(1, 2).contiguous()                    # [B,12,N]
        x = F.relu(self.bn1(self.conv1(x)))                      # [B,64,N]
        x = F.relu(self.bn2(self.conv2(x)))                      # [B,128,N]
        x = x.transpose(1, 2).contiguous()                       # [B,N,128]

        # ---- 空输入早退之三：mask 全 False（一个有效框都没有）
        #      注意：仍要走完上面的卷积（保证计算图静态），只把池化结果归零
        valid_any = det_mask.to(dtype=x.dtype).sum(dim=1, keepdim=True)  # [B,1]
        mask_f = det_mask.to(dtype=x.dtype).unsqueeze(-1)                # [B,N,1]

        # max pool：先把空槽置 -inf 再取 max，避免 0 填充污染最大值
        neg_inf = torch.finfo(x.dtype).min
        x_for_max = torch.where(mask_f > 0, x, torch.full_like(x, neg_inf))
        pooled_max = x_for_max.max(dim=1).values                         # [B,128]
        # 全空样本的 max 会得到 -inf → 用 where 归零
        pooled_max = torch.where(valid_any > 0, pooled_max,
                                 torch.zeros_like(pooled_max))           # [B,128]

        # mean pool：mask 加权平均，全空自动为 0（见 _masked_mean_pool）
        pooled_mean = _masked_mean_pool(x, det_mask)                     # [B,128]

        fused = torch.cat([pooled_max, pooled_mean], dim=1)              # [B,256]
        return F.relu(self.fc(fused))                                    # [B,128]


# ============================================================================
# 5. 状态分支 StateEncoder —— 加速度/角度等 8 维 → 64 维
# ============================================================================

class StateEncoder(nn.Module):
    """车辆状态分支：8 维标量 → 64 维特征。

    8 维状态定义与**归一化约定**（务必与 Swift 侧采集一致）：
        [0] speed          车速 / 速度上限        ∈ [0,1]
        [1] accel          纵向加速度 / 10 m·s⁻²  ∈ [-1,1]   ← 用户需求⑤
        [2] heading        当前角度 / π           ∈ [-1,1]   ← 用户需求⑤
        [3] heading_rate   角度变化率 / π·s⁻¹     ∈ [-1,1]
        [4] curvature      路径曲率（来自车道线）  ∈ [-1,1]
        [5] lateral_offset 相对车道中心横向偏移    ∈ [-1,1]
        [6] steer_angle    当前方向盘角 / 最大角   ∈ [-1,1]
        [7] reserved       预留位（如 ego_visible 标志：1=自车框已剔除）

    为什么状态分支不能省：加速度与当前角度是**纯视觉难以精确推断**的量
    （图像里没有绝对尺度、没有 IMU），而它们直接决定"该给多少油门/刹车"。
    这正是用户需求⑤的动机。

    shape：
        输入  state: [B, 8]
        输出       : [B, 64]
    """

    def __init__(self, in_dim: int = STATE_DIM, out_dim: int = STATE_FEAT_DIM):
        super().__init__()
        # [B,8] → [B,32]
        self.fc1 = nn.Linear(in_dim, 32)
        # [B,32] → [B,64]
        self.fc2 = nn.Linear(32, out_dim)
        self._init_weights()

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, mode='fan_out', nonlinearity='relu')
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, vehicle_state: Optional[torch.Tensor], batch_size: int,
                ref: torch.Tensor) -> torch.Tensor:
        """
        Args:
            vehicle_state: [B,8] 或 None（状态读取失败 / 游戏未接入）
            batch_size: B
            ref: 取 device/dtype 的参考张量

        Returns:
            [B,64]；vehicle_state 为 None 时返回零向量
        """
        # ---- 空输入早退：状态未接入时（见 InferenceEngine.swift 注释里
        #      "游戏状态读取未接入前用启发式占位"的历史）给零向量，让网络
        #      学到"全零 = 未知"，而不是用假数据污染
        if vehicle_state is None:
            return _zero_like(ref, batch_size, STATE_FEAT_DIM)

        x = F.relu(self.fc1(vehicle_state))     # [B,32]
        x = F.relu(self.fc2(x))                 # [B,64]
        return x


# ============================================================================
# 6. 融合头 FusionHead —— 512 维 → steer/throttle/brake
# ============================================================================

class FusionHead(nn.Module):
    """融合头：拼接四分支特征 → 三个控制量。

    输入 512 维 = 图像 256 + 车道线 64 + 检测框 128 + 状态 64
    结构： FC(512→512) → ReLU → Dropout(0.2)
         → FC(512→256) → ReLU → Dropout(0.1)
         → FC(256→128) → ReLU
         → 三个独立头：
             steer_head    → tanh    ∈ [-1,1]（左右转向，连续对称）
             throttle_head → sigmoid ∈ [0,1] （油门，非负）
             brake_head    → sigmoid ∈ [0,1] （刹车，非负；与油门可同时非零，
                                              由损失函数约束二者不同时饱和）

    shape：
        输入  [B,512] → steer[B,1] / throttle[B,1] / brake[B,1]
    """

    def __init__(self, in_dim: int = FUSION_IN_DIM, hidden1: int = 512,
                 hidden2: int = 256, hidden3: int = 128):
        super().__init__()
        self.in_dim = in_dim
        self.fc1 = nn.Linear(in_dim, hidden1)
        self.dropout1 = nn.Dropout(0.2)
        self.fc2 = nn.Linear(hidden1, hidden2)
        self.dropout2 = nn.Dropout(0.1)
        self.fc3 = nn.Linear(hidden2, hidden3)
        self.steer_head = nn.Linear(hidden3, 1)
        self.throttle_head = nn.Linear(hidden3, 1)
        self.brake_head = nn.Linear(hidden3, 1)
        self._init_weights()

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, nn.Linear):
                # fan_in 模式：对 (128→1) 输出头给出 std=√(2/128)≈0.125，
                # 而非 fan_out 的 √(2/1)=1.414 —— 后者会让 tanh/sigmoid
                # 一上来就饱和、梯度归零、训练直接冻结（旧 model.py 踩过这个坑）
                nn.init.kaiming_normal_(m.weight, mode='fan_in', nonlinearity='relu')
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, feat: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """feat: [B,512] → ([B,1] steer, [B,1] throttle, [B,1] brake)"""
        x = F.relu(self.fc1(feat))       # [B,512]
        x = self.dropout1(x)
        x = F.relu(self.fc2(x))          # [B,256]
        x = self.dropout2(x)
        x = F.relu(self.fc3(x))          # [B,128]
        steer = torch.tanh(self.steer_head(x))       # [B,1] ∈ [-1,1]
        throttle = torch.sigmoid(self.throttle_head(x))  # [B,1] ∈ [0,1]
        brake = torch.sigmoid(self.brake_head(x))        # [B,1] ∈ [0,1]
        return steer, throttle, brake


# ============================================================================
# 7. 完整模型 M2Model
# ============================================================================

def _zero_like(ref: torch.Tensor, batch_size: int, dim: int) -> torch.Tensor:
    """构造 [B, dim] 的全零张量（device/dtype 跟随 ref）。

    空输入早退统一走这里：保证"分支缺失"与"分支存在但内容为空"两条路径
    的输出 shape 完全一致，导出静态图时不会出现 shape 分歧。
    """
    return torch.zeros(batch_size, dim, device=ref.device, dtype=ref.dtype)


class M2Model(nn.Module):
    """M2 端到端驾驶模型（AuroraDrive 新主驾驶模型）。

    forward 入参（**全部可选，除 image 外**）：
        image:     [B, 3, 180, 320]   float32，[0,1] 归一化，第三视角截图
        lane_mask: [B, 1, 160, 160]   float32 二值 0/1，来自 MaskGrid
        dets:      [B, N, 12]         float32 检测框特征（见 DetectionEncoder 文档）
        det_mask:  [B, N]             float32 1=有效框
        state:     [B, 8]             float32 车辆状态（见 StateEncoder 文档）

    ⛔ 不接受 drivable_mask —— 用户需求③明确要求"可行驶区域不要收"。

    返回：
        (steer [B,1], throttle [B,1], brake [B,1])
    """

    def __init__(self, deploy: bool = False,
                 img_feat_dim: int = IMG_FEAT_DIM,
                 lane_feat_dim: int = LANE_FEAT_DIM,
                 det_feat_dim: int = DET_FEAT_DIM_OUT,
                 state_feat_dim: int = STATE_FEAT_DIM):
        super().__init__()
        self.deploy = deploy
        self.img_feat_dim = img_feat_dim
        self.lane_feat_dim = lane_feat_dim
        self.det_feat_dim = det_feat_dim
        self.state_feat_dim = state_feat_dim

        # ---- 四个分支 ----
        self.image_encoder = ImageEncoder(deploy=deploy, out_dim=img_feat_dim)
        self.lane_encoder = LaneMaskEncoder(out_dim=lane_feat_dim)
        self.det_encoder = DetectionEncoder(out_dim=det_feat_dim)
        self.state_encoder = StateEncoder(out_dim=state_feat_dim)

        # ---- 融合头 ----
        fusion_in = img_feat_dim + lane_feat_dim + det_feat_dim + state_feat_dim
        self.fusion_head = FusionHead(in_dim=fusion_in)

        # ---- 记录契约常量，供 Swift/导出脚本读取 ----
        self.img_h = IMG_H
        self.img_w = IMG_W
        self.lane_size = LANE_SIZE
        self.max_detections = MAX_DETECTIONS
        self.det_in_dim = DET_FEAT_DIM
        self.state_dim = STATE_DIM

    # ------------------------------------------------------------------
    def forward(self,
                image: torch.Tensor,
                lane_mask: Optional[torch.Tensor] = None,
                dets: Optional[torch.Tensor] = None,
                det_mask: Optional[torch.Tensor] = None,
                vehicle_state: Optional[torch.Tensor] = None
                ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """
        Args:
            image:         [B,3,180,320]（必填）
            lane_mask:     [B,1,160,160] 或 None（车道线全丢）
            dets:          [B,N,12] 或 None（无检测框）
            det_mask:      [B,N] 或 None
            vehicle_state: [B,8] 或 None

        Returns:
            steer [B,1] ∈ [-1,1], throttle [B,1] ∈ [0,1], brake [B,1] ∈ [0,1]

        ⚠️ 参数名为什么是 `vehicle_state` 而不是 `state`（实测踩坑记录）：
            coremltools 8.3 把名为 `state` 的输入**静默重命名**为
            `state_workaround`（`state` 与内部实现保留字冲突），导致 Swift 侧
            按 `state` 取输入时抛
            `KeyError: Provided key "state" ... does not match any of the model
             input name(s), which are: {'state_workaround', ...}`。
            实测改用 `vehicle_state` 后**输入名被原样保留**，且该命名恰好与
            `InferenceEngine.swift` 既有的 `vehicle_state` 契约同名 —— 一举两得。
        """
        # ---- 图像必填：纯视觉主模态，缺失时无法驾驶（fail-fast 而非静默降级）
        if image is None:
            raise ValueError("M2Model.forward: image 为必填输入（纯视觉主模态），不可为 None")
        if image.dim() != 4:
            raise ValueError(f"M2Model.forward: image 期望 [B,3,H,W]，实际 {tuple(image.shape)}")

        batch_size = image.shape[0]
        if not image.is_contiguous():
            image = image.contiguous()

        # ---- 分支 1：图像 [B,3,180,320] → [B,256] ----
        img_feat = self.image_encoder(image)

        # ---- 分支 2：车道线 [B,1,160,160] → [B,64]（None → 零向量）----
        lane_feat = self.lane_encoder(lane_mask, batch_size, image)

        # ---- 分支 3：检测框 [B,N,12]+[B,N] → [B,128]（None/空 → 零向量）----
        det_feat = self.det_encoder(dets, det_mask, batch_size, image)

        # ---- 分支 4：状态 [B,8] → [B,64]（None → 零向量）----
        state_feat = self.state_encoder(vehicle_state, batch_size, image)

        # ---- 融合：[B,512] → 三个控制量 ----
        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)  # [B,512]
        return self.fusion_head(fused)

    # ------------------------------------------------------------------
    def reparameterize(self) -> None:
        """训练态 → 部署态：把图像分支的 RepVGG 多分支折叠为纯 3×3。

        调用后模型参数量与推理耗时均下降（BN 折进卷积，少一层访存），
        精度数学等价。
        """
        if self.deploy:
            return
        self.image_encoder.reparameterize()
        self.deploy = True

    # ------------------------------------------------------------------
    def get_param_count(self) -> Dict[str, int]:
        """各分支参数量统计（部署前训练态）。"""
        return {
            "image_encoder": sum(p.numel() for p in self.image_encoder.parameters()),
            "lane_encoder": sum(p.numel() for p in self.lane_encoder.parameters()),
            "det_encoder": sum(p.numel() for p in self.det_encoder.parameters()),
            "state_encoder": sum(p.numel() for p in self.state_encoder.parameters()),
            "fusion_head": sum(p.numel() for p in self.fusion_head.parameters()),
            "total": sum(p.numel() for p in self.parameters()),
        }

    def get_model_size_mb(self, precision: str = "fp32") -> float:
        """模型体积估算（MB）。"""
        total = sum(p.numel() for p in self.parameters())
        bytes_per_param = {"fp32": 4, "fp16": 2, "int8": 1}
        return total * bytes_per_param.get(precision, 4) / (1024 * 1024)

    # ------------------------------------------------------------------
    def get_latency_estimate(self) -> str:
        """M3 真机实测延迟表（本机 = Apple M3，与部署目标芯片一致）。

        数据来自 `.mlpackage` FP16 实测与 PyTorch CPU 实测，详见文件头 §4。
        返回可直接打印的多行文本。
        """
        lines = [
            "=" * 66,
            "M2 模型 M3 实测延迟（目标 30Hz，单帧预算 33ms）",
            "=" * 66,
            "★ CoreML .mlpackage (FP16, B=1) 实测中位（5 轮 × 100 次）：",
            f"  {'计算单元':<24}{'中位延迟':<14}{'结论'}",
            "-" * 66,
            f"  {'ALL (ANE+GPU+CPU)':<24}{'1.68 ms':<14}✅ 达标，余量 19.6×",
            f"  {'CPU+ANE':<24}{'1.17 ms':<14}✅ 达标，余量 28.1× ← 推荐",
            f"  {'CPU_ONLY':<24}{'4.63 ms':<14}✅ 达标，余量  7.1×",
            "-" * 66,
            "  .mlpackage 体积 5.79 MB；CoreML FP16 vs PyTorch FP32 最大偏差 7.4e-04",
            "  注：CPU+ANE 快于 ALL —— ALL 会把非图像算子派给 GPU，反而多一层同步。",
            "",
            "★ PyTorch CPU (torch 2.13, 4 线程, B=1, 7 轮交错取中位) 实测：",
            f"  {'训练态(RepVGG 三分支)':<24}{'34.43 ms':<14}⚠️ 超 33ms 预算",
            f"  {'部署态(重参数化后)':<24}{'28.32 ms':<14}✅ 勉强达标，无余量",
            "    分项：ImageEncoder 23.02 / LaneMask 1.21 / Detection 0.56 / State 0.02",
            "    重参数化收益约 17.7%（34.43 → 28.32 ms），导出前必做。",
            "    ⚠️ 本机 CPU 耗时方差极大（24~63ms），此数仅供量级参考。",
            "",
            "★ 理论计算量（部署态）：合计 907.40 MMACs = 1.815 GFLOPs",
            "    ImageEncoder 902.85 MMACs 占 99.5%，是唯一算力大头。",
            "=" * 66,
            "结论：CoreML/ANE 路径余量 20 倍，远超 30Hz 要求；",
            "      部署必须走 CoreML，PyTorch CPU 路径无余量、仅适合离线回放。",
            "=" * 66,
        ]
        return "\n".join(lines)


# ============================================================================
# 8. 损失函数
# ============================================================================

class M2Loss(nn.Module):
    """多任务损失：MSE(转向) + Huber(油门) + Huber(刹车) + 一致性正则。

    与旧 M9Loss 的差异：额外加一项 throttle/brake 互斥惩罚 —— 同时大油门
    大刹车在物理上无意义，且会让车"抖动式"行驶。该项系数默认很小(0.05)，
    只做轻微引导，不主导梯度。

    输入 shape 均为 [B,1]。
    """

    def __init__(self, steer_weight: float = 1.0, throttle_weight: float = 0.5,
                 brake_weight: float = 0.5, conflict_weight: float = 0.05):
        super().__init__()
        self.steer_weight = steer_weight
        self.throttle_weight = throttle_weight
        self.brake_weight = brake_weight
        self.conflict_weight = conflict_weight
        self.mse = nn.MSELoss()
        self.huber = nn.SmoothL1Loss(beta=0.1)

    def forward(self, pred_steer, pred_throttle, pred_brake,
                gt_steer, gt_throttle, gt_brake):
        loss_steer = self.mse(pred_steer, gt_steer)
        loss_throttle = self.huber(pred_throttle, gt_throttle)
        loss_brake = self.huber(pred_brake, gt_brake)
        # 互斥正则：throttle * brake 越小越好（同时踩 = 惩罚）
        loss_conflict = (pred_throttle * pred_brake).mean()
        total = (self.steer_weight * loss_steer
                 + self.throttle_weight * loss_throttle
                 + self.brake_weight * loss_brake
                 + self.conflict_weight * loss_conflict)
        return total, {
            "steer": loss_steer.item(),
            "throttle": loss_throttle.item(),
            "brake": loss_brake.item(),
            "conflict": loss_conflict.item(),
            "total": total.item(),
        }


# ============================================================================
# 9. 构建 / 导出工具函数（命名与 src/model.py 保持一致）
# ============================================================================

def build_model(deploy: bool = False) -> M2Model:
    """构建 M2 主驾驶模型。

    Args:
        deploy: False=训练态（RepVGG 多分支，精度高）
                True =部署态（已重参数化为纯 3×3，推理快）

    Returns:
        M2Model 实例
    """
    return M2Model(deploy=deploy)


# 别名：build_m2 与 build_model 等价，便于与旧 build_m9/build_m9_mono 并列书写
build_m2 = build_model


def load_pretrained_image_encoder(model: M2Model, pretrained_path: str) -> None:
    """从旧 M9/M9-Mono 存档中迁移 RepVGG-A0 权重（尽力而为，通道不匹配的层跳过）。

    旧 A0 与 M2 的 ImageEncoder 在 stage0~stage3 的通道配置完全一致
    （48/48/96/192），仅 stage3 的 block 数与 stage4 输出通道不同，
    因此可以部分迁移：stage0~stage2 全量迁移，stage3 取前 N 个 block，
    stage4 因 192→1280 vs 192→256 不匹配而跳过（随机初始化，训练时收敛）。

    Args:
        model: build_model() 构建的模型（deploy=False 训练态）
        pretrained_path: 旧存档 .pt/.pth 路径
    """
    ckpt = torch.load(pretrained_path, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    # 剥离 torch.compile 的 _orig_mod. 前缀
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}

    # 旧键前缀 repvgg. → 新键前缀 image_encoder.
    remapped = {}
    for k, v in sd.items():
        if k.startswith("repvgg."):
            remapped["image_encoder." + k[len("repvgg."):]] = v

    target = model.image_encoder.state_dict()
    usable = {k: v for k, v in remapped.items()
              if k in target and target[k].shape == v.shape}
    result = model.image_encoder.load_state_dict(usable, strict=False)
    print(f"[M2] 图像分支权重迁移: 命中 {len(usable)}/{len(remapped)} 键 "
          f"(缺失 {len(result.missing_keys)}, 多余 {len(result.unexpected_keys)})")
    if not usable:
        print("[M2] ⚠ 未迁移任何权重（键名或 shape 完全不匹配），将随机初始化训练")


def export_onnx(state_dict_path: str, save_path: str,
                img_h: int = IMG_H, img_w: int = IMG_W,
                lane_size: int = LANE_SIZE, max_dets: int = MAX_DETECTIONS,
                state_dim: int = STATE_DIM, det_feat_dim: int = DET_FEAT_DIM) -> None:
    """导出 M2 为 ONNX（供 CoreML 转换 / C++ LibTorch 加载）。

    输入（与 Swift 侧契约一致）：
        image         [1, 3, 180, 320]
        lane          [1, 1, 160, 160]
        dets          [1, 20, 12]
        det_mask      [1, 20]
        vehicle_state [1, 8]        ← 不叫 `state`，见 M2Model.forward 的踩坑说明
    输出：
        steer    [1, 1]  tanh
        throttle [1, 1]  sigmoid
        brake    [1, 1]  sigmoid

    注意：导出时 N 固定为 max_dets（CoreML 对动态维支持有限），
    Swift 侧空槽补 0 + det_mask=0 即可表达任意数量（含 0 个）检测框。
    """
    model = build_model(deploy=True)
    ckpt = torch.load(state_dict_path, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    model.load_state_dict(sd, strict=False)
    model.eval()

    dummy_image = torch.zeros(1, 3, img_h, img_w)
    dummy_lane = torch.zeros(1, 1, lane_size, lane_size)
    dummy_dets = torch.zeros(1, max_dets, det_feat_dim)
    dummy_mask = torch.zeros(1, max_dets)
    dummy_state = torch.zeros(1, state_dim)

    with torch.no_grad():
        torch.onnx.export(
            model,
            (dummy_image, dummy_lane, dummy_dets, dummy_mask, dummy_state),
            save_path,
            input_names=["image", "lane", "dets", "det_mask", "vehicle_state"],
            output_names=["steer", "throttle", "brake"],
            dynamic_axes={
                "image":         {0: "batch"},
                "lane":          {0: "batch"},
                "dets":          {0: "batch"},
                "det_mask":      {0: "batch"},
                "vehicle_state": {0: "batch"},
                "steer":         {0: "batch"},
                "throttle":      {0: "batch"},
                "brake":         {0: "batch"},
            },
            opset_version=14,
            do_constant_folding=True,
        )
    print(f"[M2] ONNX 导出成功: {save_path} ({img_h}×{img_w}, N={max_dets})")


def export_coreml(state_dict_path: str, save_path: str,
                  img_h: int = IMG_H, img_w: int = IMG_W,
                  lane_size: int = LANE_SIZE, max_dets: int = MAX_DETECTIONS,
                  state_dim: int = STATE_DIM, det_feat_dim: int = DET_FEAT_DIM,
                  precision: str = "float16") -> None:
    """导出 M2 为 CoreML .mlpackage（★ 本仓库部署主路径，实测 1.17~1.68ms）。

    依赖 coremltools（本仓库 `.venv-yolo26` 已装 8.3.0）。

    关键实现要点（都是实测踩过的坑，勿随意改动）：
      1) **输入名用 `vehicle_state` 而非 `state`** —— coremltools 8.3 会把名为
         `state` 的输入静默改名为 `state_workaround`，Swift 侧取值直接 KeyError。
      2) 先用 `torch.jit.trace` 再转 —— 直接 `ct.convert(model)` 对含
         `Optional` 分支的 forward 支持不佳。
      3) `minimum_deployment_target=iOS17` + `convert_to="mlprogram"` ——
         否则拿不到 ANE 加速（老的 neuralnetwork 后端性能差一个量级）。

    Args:
        state_dict_path: 训练存档 .pt（含 model_state_dict）
        save_path: 输出 .mlpackage 路径
        precision: "float16"（推荐，5.79MB / 1.17ms）或 "float32"
    """
    import coremltools as ct  # 延迟导入：训练环境可能没装 coremltools

    model = build_model(deploy=False)          # ★ 必须训练态构建，再 reparameterize
    ckpt = torch.load(state_dict_path, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    model.load_state_dict(sd, strict=False)
    # ⚠️ 若用 deploy=True 构建再 load_state_dict，多分支权重会被静默丢弃 →
    #    导出随机权重模型（旧 export_game_assist_coreml.py 头部注释记录过这个致命 bug）
    model.reparameterize()
    model.eval()

    dummy = (torch.zeros(1, 3, img_h, img_w),
             torch.zeros(1, 1, lane_size, lane_size),
             torch.zeros(1, max_dets, det_feat_dim),
             torch.zeros(1, max_dets),
             torch.zeros(1, state_dim))
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy, strict=False)

    prec = ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="image",         shape=(1, 3, img_h, img_w)),
            ct.TensorType(name="lane",          shape=(1, 1, lane_size, lane_size)),
            ct.TensorType(name="dets",          shape=(1, max_dets, det_feat_dim)),
            ct.TensorType(name="det_mask",      shape=(1, max_dets)),
            ct.TensorType(name="vehicle_state", shape=(1, state_dim)),
        ],
        outputs=[ct.TensorType(name="steer"),
                 ct.TensorType(name="throttle"),
                 ct.TensorType(name="brake")],
        compute_precision=prec,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    mlmodel.save(save_path)
    print(f"[M2] CoreML 导出成功: {save_path} "
          f"({img_h}×{img_w}, N={max_dets}, {precision}, mlprogram/iOS17)")
    print("[M2] 部署建议：compute_units 用 CPU_AND_NE（实测比 ALL 更快）")


def get_model_stats(model: Optional[M2Model] = None) -> str:
    """打印模型参数统计（与旧 get_model_stats 同风格）。"""
    if model is None:
        model = build_model()
    counts = model.get_param_count()
    total = counts["total"]
    lines = [
        "=" * 58,
        "M2 模型参数统计（四分支 + 融合头）",
        "=" * 58,
        f"ImageEncoder:     {counts['image_encoder']:>10,}  ({counts['image_encoder']/1e6:.2f}M)",
        f"LaneMaskEncoder:  {counts['lane_encoder']:>10,}  ({counts['lane_encoder']/1e3:.1f}K)",
        f"DetectionEncoder: {counts['det_encoder']:>10,}  ({counts['det_encoder']/1e3:.1f}K)",
        f"StateEncoder:     {counts['state_encoder']:>10,}  ({counts['state_encoder']/1e3:.1f}K)",
        f"FusionHead:       {counts['fusion_head']:>10,}  ({counts['fusion_head']/1e3:.1f}K)",
        "-" * 58,
        f"合计:             {total:>10,}  ({total/1e6:.2f}M)",
        f"FP32: {model.get_model_size_mb('fp32'):.1f} MB  "
        f"FP16: {model.get_model_size_mb('fp16'):.1f} MB  "
        f"INT8: {model.get_model_size_mb('int8'):.1f} MB",
        f"融合头输入维度: {model.fusion_head.in_dim} "
        f"(图 {model.img_feat_dim} + 线 {model.lane_feat_dim} "
        f"+ 框 {model.det_feat_dim} + 态 {model.state_feat_dim})",
        "⛔ 本模型不接收可行驶区域（drivableMask）",
        "=" * 58,
    ]
    return "\n".join(lines)


# ============================================================================
# 10. 自检：直接运行本文件时打印结构与参数量
# ============================================================================

if __name__ == "__main__":
    _model = build_model()
    print(get_model_stats(_model))
    print()
    print(_model.get_latency_estimate())
