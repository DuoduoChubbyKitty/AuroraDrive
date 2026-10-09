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

# ── M4 集成（2026-10-08）：三个新头的导入 ──────────────────────────────
# 延迟导入写在 try 里：这三个模块由 w3/w4/w5 并行产出，若某个尚未落盘，
# 缺失的头自动置 None（build_model 的 enable_* 开关会跳过它），
# **不让 model_v2 因缺模块而整个 import 失败**（向后兼容旧环境）。
#
# ★ 2026-10-08（T1 独立验证修复）：**双路径导入 + 降级必须告警**
# ----------------------------------------------------------------
# 原实现只有 `from src.xxx import ...`，且 `except ImportError: XXX = None`
# **完全静默**。实测存在一个极具误导性的陷阱：
#
#     python3 -c "import model_v2"      → cwd 在 sys.path → `src.xxx` 可解析 → 三头挂载 ✅
#     python3 src/train_v2.py           → sys.path[0] = src/，repo root **不在** path
#                                        → ModuleNotFoundError: No module named 'src'
#                                        → 被 except 吞掉 → **三头全变 None，无任何告警** 🔴
#
# 后果：任何以「脚本方式」运行的下游（python3 src/xxx.py）都会**静默丢掉三个头**，
# 产生假红（误判"没集成"）或假绿（误判"集成好了"）。T1 验证脚本首次运行即被坑到，
# 报了 15 个 FAIL，实际只是导入环境问题。
#
# 修法：① 双路径回退（`src.xxx` 失败 → 回退顶层 `xxx`）
#       ② 两条路径都失败时**必须发 RuntimeWarning**，绝不静默
import warnings as _warnings


def _import_head(mod_name: str, attrs: str):
    """双路径导入一个感知头模块。

    Args:
        mod_name: 模块名（如 "heading_head"）
        attrs:    逗号分隔的属性名（如 "HeadingHead"）

    Returns:
        tuple：按 attrs 顺序的属性元组；全失败则返回 (None,) * len(attrs)
    """
    names = [a.strip() for a in attrs.split(",") if a.strip()]
    for path in (f"src.{mod_name}", mod_name):     # ① 包内路径 ② 脚本运行回退
        try:
            import importlib
            mod = importlib.import_module(path)
            if all(hasattr(mod, n) for n in names):
                return tuple(getattr(mod, n) for n in names)
        except ImportError:
            continue
    # ② 两条路径都失败 → 必须告警（不静默！）
    _warnings.warn(
        f"[model_v2] ⚠ 无法导入 {mod_name}（{names}）—— 该感知头将被禁用"
        f"（enable_{mod_name.replace('_head', '')}=True 也不会生效）。"
        f"请检查 sys.path 是否包含 repo root 或 src 目录；"
        f"脚本方式运行（python3 src/xxx.py）会导致 'from src.xxx' 解析失败。",
        RuntimeWarning, stacklevel=2)
    return (None,) * len(names)


HeadingHead, = _import_head("heading_head", "HeadingHead")
TemporalEncoder, = _import_head("temporal", "TemporalEncoder")
RiskHead, RiskHeadConfig = _import_head("risk_head", "RiskHead, RiskHeadConfig")


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
#: 单个检测框的特征维度（★ 12，不是 13）
#: 布局：[0]x [1]y [2]w [3]h [4:8]label_onehot4 [8]confidence [9]speed [10]heading [11]age
#: ⚠️ 2026-10-08 修正（w3-health 发现）：原注释误列 ego_visible 为第 13 项，
#:    但实现（DetectionEncoder 文档 :552-560）第 6 维不用、自车信息走
#:    `vehicle_state[7]`（reserved 位），故维度恒为 12。
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
# ── M4 集成新增常量 ──
#: 时序窗口 N（吃前 N 帧；1 = 退化为单帧，与旧模型等价）
TEMPORAL_FRAMES: int = 8
#: 时序编码器隐藏维度（GRU hidden；w5 默认 128）
TEMPORAL_HIDDEN: int = 128


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

    def __init__(self, deploy: bool = False, out_dim: int = IMG_FEAT_DIM,
                 stage3_blocks: int = 6, stage2_blocks: int = 3):
        """ImageEncoder 构造。

        Args:
            deploy: 是否部署态（RepVGG 已重参数化）
            out_dim: 输出特征维度
            stage3_blocks: stage3 的 block 数（**M4 加大骨干的旋钮**）。
                原值 6（A0 从 14 砍到 6，为轻量）；参数量预算允许时调到
                10~14 可提升容量。每加 1 个 block ≈ +0.22M 参数。
            stage2_blocks: stage2 的 block 数（默认 3）；每加 1 个 ≈ +0.08M。
        """
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
        self.stage2 = RepVGGStage(48, 96, num_blocks=stage2_blocks, deploy=deploy)
        # ---- stage3：6 blocks，96→192（旧 A0 是 14 个，这里砍到 6 个）
        # [B,96,23,40] → [B,192,12,20]
        # M4：block 数改为可配（加大骨干的旋钮，见 __init__ 文档）
        self.stage3 = RepVGGStage(96, 192, num_blocks=stage3_blocks, deploy=deploy)
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
        # ── T7 修复（2026-10-08）：GAP(1,1) → GAP(2,2) + 投影 ──
        # 原 `AdaptiveAvgPool2d((1,1))` 是全局平均池化，对空间求平均 → 平移不变，
        # 抹掉车道线「横向位置」信息：单条车道线从图左移到图右，池化后向量差严格
        # = 0.0（见 verify_lane_usage.py 实验 4，以及 Lead 独立复现「左 vs 右差 0」）。
        # 这就是「模型看得见车道线、却分不清左右、会开出车道线」的架构根源。
        #
        # 修复：GAP(2,2) 保留 2×2 位置块（左上/右上/左下/右下），flatten 后再用
        # FC 投影回 out_dim。左右位置信息进入 4 个空间块的相对强度，得以传给 steer。
        # 输出维度不变（[B, out_dim]），FusionHead 的 512 契约 / _zero_like(64)
        # / LaneSteerProbe(in_dim=64) 全部保持兼容；仅新增的 spatial_proj 随机初始化，
        # 旧 checkpoint 的卷积权重仍可加载（strict=False），需重新训练才让投影生效。
        self.global_pool = nn.AdaptiveAvgPool2d((2, 2))
        # spatial_proj 初始化决策（T7，2026-10-08）——**与 temporal_proj 不同，不零初始化**：
        #   · temporal_proj 是**残差相加**：随机初始化会把一个 ≈7.8 倍于主干的大项
        #     叠加进 img_feat → 必须零初始化（见 M2Model.__init__ 内注释）
        #   · spatial_proj 是**通道替换**（GAP2x2 展平后投影回 64 维）：不存在叠加放大；
        #     但**零初始化会让 GAP 修复彻底失效**（实测：零初始化后 lane_feat 恒为 0，
        #     「左 vs 右」差退回 0.000000，位置信息再次被抹平）
        #   → 采用**确定性 4 块平均初始化**：每通道 = 4 个位置块的均值（等价于
        #     GAP(1,1) 的旧行为作为起点），既保留位置信息（左 vs 右差 ≈ 3.27），
        #     又不依赖随机种子、不放大尺度（lane/img 比 ≈ 3.67，与随机初始化同量级；
        #     lane 分支本就因 has_lane=False 从未训练，训练时会随梯度重新学）。
        self.spatial_proj = nn.Linear(out_dim * 4, out_dim)
        with torch.no_grad():
            w = self.spatial_proj.weight          # [out_dim, out_dim*4]
            w.zero_()
            for c in range(out_dim):
                for blk in range(4):
                    w[c, blk * out_dim + c] = 0.25  # 4 块平均 → 等价旧 GAP(1,1) 起点
            self.spatial_proj.bias.zero_()

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
        x = self.global_pool(x)                                 # [B,64,2,2]
        x = x.flatten(1)                                        # [B,256]
        x = self.spatial_proj(x)                                # [B,64]
        return x


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
# 7.4. MoE 专家 + 每步输出头（2026-10-08 用户新需求）
# ============================================================================

class _Expert(nn.Module):
    """单个场景专家：MLP(512→512→512)，出"辅助决策"向量。

    用户原话：「给模型加一个感知头可以得到专家决策，然后那个 24 步迭代中每一步
    都会带一些专家决策，动态选一个的那种」

    6 个专家建议分工（可训练中自动分化，此处仅为初始语义标签）：
        0 直道巡航 / 1 弯道过弯 / 2 跟车避障 / 3 急转救车 / 4 起步加速 / 5 复杂场景
    """

    def __init__(self, feat_dim: int = FUSION_IN_DIM, hidden: int = FUSION_IN_DIM):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(feat_dim, hidden), nn.ReLU(inplace=True),
            nn.Linear(hidden, feat_dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


class _StepOutputHead(nn.Module):
    """每步共享的输出头（供 t1 逐步递减监督）。

    用户/Lead 规格（return_intermediate 的每步 dict）：
        step1..24   : {steer, throttle, brake}
        step8       : + {lane_offset}（线性 ∈[-1,1]）
        step16      : + {ttc}（线性，秒）

    共享一个头 → 参数量小（≈66K）；steer→tanh / throttle,brake→sigmoid
    与 FusionHead 同款激活。
    """

    def __init__(self, feat_dim: int = FUSION_IN_DIM, hidden: int = 128):
        super().__init__()
        self.fc = nn.Linear(feat_dim, hidden)
        self.steer_head = nn.Linear(hidden, 1)
        self.throttle_head = nn.Linear(hidden, 1)
        self.brake_head = nn.Linear(hidden, 1)
        # 中间步辅助任务头（只在指定步启用）
        self.lane_offset_head = nn.Linear(hidden, 1)
        self.ttc_head = nn.Linear(hidden, 1)

    def forward(self, feat: torch.Tensor) -> Dict[str, torch.Tensor]:
        x = F.relu(self.fc(feat))
        return {
            "steer": torch.tanh(self.steer_head(x)),          # ∈[-1,1]
            "throttle": torch.sigmoid(self.throttle_head(x)),  # ∈[0,1]
            "brake": torch.sigmoid(self.brake_head(x)),        # ∈[0,1]
            "lane_offset": self.lane_offset_head(x),           # 线性 ∈[-1,1]（未裁剪）
            "ttc": self.ttc_head(x),                           # 线性（秒）
        }


# ============================================================================
# 7.5. 迭代精修头 IterationRefiner（24 步向量版思维链，2026-10-08）
# ============================================================================

class _StrictGRUStep(nn.Module):
    """单步严格 GRU，用 Linear+sigmoid+tanh+mul 显式实现。

    ★ 为什么不直接用 nn.GRUCell（2026-10-08，w5 实测导出阻断）：
      coremltools 8.3 把 nn.GRUCell trace 拆成 unsafe_chunk / uninitialized /
      loop 算子，**CoreML 不认识** → 导出必失败（shared/indep 两种都炸）。
      手工展开成基础算子（Linear/sigmoid/tanh/mul）后 coremltools 全支持。

    ★ 与 nn.GRUCell **逐位等价**（实测最大差 5.96e-08 = float32 精度极限）：
      PyTorch GRUCell 的实际公式（注意与论文版有两处易错差异）：
        r = σ(W_ir·x + b_ir + W_hr·h + b_hr)      重置门
        z = σ(W_iz·x + b_iz + W_hz·h + b_hz)      更新门
        n = tanh(W_in·x + b_in + r ⊙ (W_hn·h + b_hn))   ★ r 乘在 (U h + b) 外层
        h' = (1 − z) ⊙ n + z ⊙ h                  ★ 注意是 (1−z)·n + z·h
      【两处易错差异，实测踩过】：
        ① 门顺序是 (r, z, n)，不是论文的 (z, r, n)
        ② 更新式是 (1−z)⊙n + z⊙h（z 是"保留旧状态"的比重），
           不是常见的 (1−z)⊙h + z⊙n —— 写反会导致数值不一致（实测差 0.59）
        ③ h_r/h_z/h_n **都带 bias**（PyTorch 的 bias_hh 是独立参数，不是折进权重）
    """

    def __init__(self, input_dim: int, hidden_dim: int):
        super().__init__()
        self.hidden_dim = hidden_dim
        # 三个门各一对 (x_proj, h_proj)，**都带 bias**（与 nn.GRUCell 的
        # weight_ih/weight_hh + bias_ih/bias_hh 布局一致）
        self.x_r = nn.Linear(input_dim, hidden_dim, bias=True)
        self.h_r = nn.Linear(hidden_dim, hidden_dim, bias=True)
        self.x_z = nn.Linear(input_dim, hidden_dim, bias=True)
        self.h_z = nn.Linear(hidden_dim, hidden_dim, bias=True)
        self.x_n = nn.Linear(input_dim, hidden_dim, bias=True)
        self.h_n = nn.Linear(hidden_dim, hidden_dim, bias=True)

    def forward(self, x: torch.Tensor, h_prev: torch.Tensor) -> torch.Tensor:
        r = torch.sigmoid(self.x_r(x) + self.h_r(h_prev))
        z = torch.sigmoid(self.x_z(x) + self.h_z(h_prev))
        n = torch.tanh(self.x_n(x) + r * self.h_n(h_prev))   # ★ r⊙(U h + b)
        return (1.0 - z) * n + z * h_prev                    # ★ (1−z)⊙n + z⊙h


class IterationRefiner(nn.Module):
    """24 步内部迭代精修（向量版思维链 / Chain-of-Thought）。

    设计（见 docs/24步迭代精修-CoT-需求-2026-10-08.md §2.2）：
        fused [B,512] → _StrictGRUStep×24（展开为静态图，方案二）→ refined [B,512]
    每步重新审视融合特征，逐步精修；24 步全程残差相加。

    ── 权重模式（Lead 拍板：shared 优先）──
        shared=True  : 24 步**共享一个 _StrictGRUStep**（参数量 ≈ 1.57M → INT8 +1.50MB）
                       —— 必须采用：indep 模式 24 个独立 Cell 达 38M/36MB，超 10MB 7 倍
        shared=False : 24 个独立 Cell（参数量 38M → **超 10MB 硬约束，不可用**）
                       仅作 fallback 占位，实际不应启用

    ── CoreML 导出（w5 实测，2026-10-08）──
        用 _StrictGRUStep（手工展开）而非 nn.GRUCell：后者 trace 出 unsafe_chunk/
        uninitialized/loop 算子，coremltools 8.3 不认识 → 导出必失败。
        手工展开版导出 ✅，真机 M3 p50=0.159ms，体积 3.56MB，24 步在图里（380 算子）。

    ── 真机 M3 整模型实测（w5 导出验证，2026-10-09）──
        配置                        总算子   p50          p95(最差)      体积(fp16)
        12步/4步MoE（本类新默认）    891     15.7~19.3ms  20.3~29.3ms   16.08MB
        24步/全MoE（旧默认）        2223     25.1ms       39.57ms ❌     16.29MB
        ★ 24 步全 MoE 的 p95 = 39.57ms = 25.3Hz，**跌破 30Hz 预算**；
          12 步/4 步 MoE 救了这条线（1.89× 提速，算子降 60%）。
        ⚠️ 但 p95 抖动明显（20.3~29.3ms，最差 29.28ms ≈ 34.2Hz，逼近 33ms 线）：
           这是 MacBook Air **无风扇热漂移**（测试中 p50 从 15.7 涨到 19.3ms）。
           真机（有风扇/更大机身）可能更稳，但**余量仅 1.1~1.6×，不宽裕**。
           若要再压余量：`moe_steps` 减到 2 步，或 `num_steps` 减到 8（未实测）。
        ⚠️ 上述耗时/算子是**图结构真实**的，但导出产物 65.7% 随机初始化
           （checkpoint 缺 refiner/experts/heads 权重）→ steer 输出无意义，
           仅用于性能/图结构验证。

    ── 零初始化（与 temporal_proj 同理，w5/Lead 实测坐实的 bug）──
        refiner_proj（残差投影）零初始化 → 起步 refined = fused + 0 = fused
        → 与无迭代逐位一致，旧 checkpoint 不破坏，训练中梯度从零起步逐步学
        迭代修正量（ResNet 残差标准做法）。

    shape：
        输入  fused: [B, feat_dim]   （M2Model 的 4 分支拼接特征）
        输出        : [B, feat_dim]   （精修后特征，喂给 FusionHead）
    """

    def __init__(self, feat_dim: int = FUSION_IN_DIM, hidden: int = FUSION_IN_DIM,
                 num_steps: int = 24, shared: bool = True,
                 num_experts: int = 6, enable_moe: bool = True,
                 step_head: bool = True,
                 lane_offset_step: int = 8, ttc_step: int = 16,
                 moe_steps: Optional[List[int]] = None):
        """迭代精修 + MoE 专家。

        ★ 用户拍板（2026-10-09 最高依据，最新）：
            「变回 8 步专家 + 16 步自己」
          → num_steps 默认 **24**；前 16 步纯自己精修，第 17~24 步调 MoE 专家。
            （前一次拍板是「12 步=8自己+4专家」，后因余量够大（p95 3.25ms/余量10×）
              又改回 24 步并加大专家到 8 步 —— 实测 p95 3.95ms/余量 8.35×，仍远低于 16ms）

        Args:
            num_steps: 总迭代步数（默认 12 = 用户拍板值；24 为备用配置）
            moe_steps: **哪些步启用 MoE 专家**（可配）。
                None（默认）→ 自动取**最后 4 步**（12 步时 = [9,10,11,12]）。
                传 [] → 全程不用专家（等价 enable_moe=False）。
                传 [9,10,11,12] → 显式指定。
                越界步号会被过滤（并打印提示），保证不越界访问。
        """
        super().__init__()
        self.feat_dim = feat_dim
        self.hidden = hidden
        self.num_steps = num_steps
        self.shared = shared
        self.enable_moe = enable_moe
        self.num_experts = num_experts
        # 辅助任务的落点步骤。**钳制到 [1, num_steps]**（T12 导出配置支持）：
        #   · num_steps=12（用户拍板）：lane_offset@8（自己精修完成）、ttc@12（专家介入后）
        #   · num_steps=24（备用）：lane_offset@8、ttc@16 —— 原设计
        #   · 更短（如 num_steps=2）：都落到最后一步，保证两个辅助监督信号不丢
        # 这样任何 N 都保住 lane_offset + ttc 两路监督，只是落点步不同。
        self.lane_offset_step = max(1, min(lane_offset_step, num_steps))
        self.ttc_step = max(1, min(ttc_step, num_steps))

        # ── MoE 生效步（用户拍板：12 步中「4 步给专家，8 步给自己」）──
        # 默认 = 最后 4 步（num_steps=12 → [9,10,11,12]）。
        # 前 num_steps-4 步纯 GRU 精修，不调专家 → 计算量比"每步都调"少很多。
        if moe_steps is None:
            n_moe = min(8, max(0, num_steps - 1))   # ★ 2026-10-09 用户拍板「8步专家+16步自己」
            self.moe_steps: List[int] = list(range(num_steps - n_moe + 1, num_steps + 1))
        else:
            self.moe_steps = sorted({s for s in moe_steps if 1 <= s <= num_steps})
            dropped = sorted(set(moe_steps) - set(self.moe_steps))
            if dropped:
                print(f"[IterationRefiner] ⚠ moe_steps 中 {dropped} 超出 [1,{num_steps}]，已忽略")

        # 残差投影：把 GRU 隐状态投回 feat_dim 维，作为每步的增量修正。
        # 零初始化 → 起步修正 = 0 → refined = fused（不破坏旧行为）。
        self.refiner_proj = nn.Linear(hidden, feat_dim)

        # _StrictGRUStep：shared=True 时 24 步共用一个；False 时 24 个独立。
        # ⚠️ 必须用 _StrictGRUStep（手工展开），不可用 nn.GRUCell（导出阻断，见类注释）。
        if shared:
            self.cells = nn.ModuleList([_StrictGRUStep(feat_dim, hidden)])
        else:
            # ⚠️ 24 个独立 Cell = 38M 参数 / 36MB INT8，超 10MB 硬约束 7 倍，不可用。
            # 仅作 fallback 占位；启用前必须重新评估参数预算。
            self.cells = nn.ModuleList(
                [_StrictGRUStep(feat_dim, hidden) for _ in range(num_steps)])

        # ── MoE（用户新需求）：6 个场景专家 + 路由器，每步动态选 1 个 ──
        # 路由器看"精修特征" → 选 1 个专家 → 专家出辅助决策 → 与精修特征融合。
        # 参数量：6 专家 × MLP(512→512→512) ≈ 3.15M（INT8 3.0MB）+ 路由器 ~0.5K。
        self.experts = None
        self.router = None
        self.expert_out_proj = None
        if enable_moe and num_experts > 1:
            self.experts = nn.ModuleList(
                [_Expert(feat_dim, hidden) for _ in range(num_experts)])
            # 路由器：精修特征 → num_experts 个 logit（选 1 个 = argmax / softmax 采样）
            self.router = nn.Linear(feat_dim, num_experts)
            # 专家辅助决策 → 投回 feat_dim 做残差融合。零初始化起步不影响主干；
            # 与 refiner_proj 同理：**零初始化**避免专家输出一开始淹没主干。
            self.expert_out_proj = nn.Linear(feat_dim, feat_dim)
            nn.init.zeros_(self.expert_out_proj.weight)
            nn.init.zeros_(self.expert_out_proj.bias)

        # ── 每步共享输出头（供 t1 逐步递减监督）──
        self.step_head = _StepOutputHead(feat_dim, hidden=128) if step_head else None

        # ★ 零初始化（关键 bug 修复，与 temporal_proj 同源）：
        # 不零初始化时 refiner_proj 随机权重会让 24 步的残差量叠加放大，
        # 淹没 fused 主干（temporal_proj 那条 bug 就是 7.8~50 倍）。
        # 零初始化后：起步每步修正 = 0 → refined 逐位等于 fused（实测可验证）；
        # 训练中梯度逐步学出迭代修正量。
        nn.init.zeros_(self.refiner_proj.weight)
        nn.init.zeros_(self.refiner_proj.bias)

    def forward(self, fused: torch.Tensor,
                return_intermediate: bool = False
                ) -> torch.Tensor | Tuple[torch.Tensor, List[Dict[str, torch.Tensor]]]:
        """fused [B,512] → refined [B,512]。

        Args:
            fused: 融合特征 [B, feat_dim]
            return_intermediate: True 时同时返回每步的**输出 dict**（供 t1 逐步递减监督）。
                格式（Lead/t1 规格）：
                    step1..24 : {"steer","throttle","brake"}
                    step8     : + {"lane_offset"}（线性 ∈[-1,1]）
                    step16    : + {"ttc"}（线性，秒）
                另附 "expert_weights"（软路由权重 [B,E]，**可微**）与
                "route_logits"，供训练加负载均衡 / 专家分化正则（t1 可选使用）。

        Returns:
            refined [B, feat_dim]；或 (refined, [step1_dict, ..., stepN_dict])。
        """
        # h0 = fused 作为初始隐状态（让迭代从"当前融合理解"起步）
        h = fused
        intermediates: List[Dict[str, torch.Tensor]] = []
        for step in range(1, self.num_steps + 1):
            # ① GRU 精修（shared：24 步共用一套权重）
            cell = self.cells[0] if self.shared else self.cells[step - 1]
            h = cell(fused, h)                              # [B, hidden]
            # 残差修正：refined = fused + proj(h)；零初始化起步 → proj(h)=0
            delta = self.refiner_proj(h)                   # [B, feat_dim]
            refined = fused + delta                        # [B, feat_dim]

            # ② MoE（用户拍板）：**只在 moe_steps 指定的步**调 6 个场景专家 + 路由器，
            #    软路由（softmax 加权）。
            # ★ 用户原话：「12 步，然后给 4 步给专家，剩下 8 步给自己」
            #   → 默认 num_steps=12、moe_steps=[9,10,11,12]：
            #     第 1~8 步纯 GRU 精修（不调专家），第 9~12 步 GRU + 专家辅助。
            #   ★ Lead 裁决（2026-10-08，w5 预验）：必须用 softmax 软路由，**不用 argmax**：
            #   1. **可微** —— argmax 不可微，训练梯度传不过去，硬路由根本训不了（决定性）
            #   2. 更快（p50 3.68ms vs 4.27ms）
            #   3. 图更小（少 216 算子）
            #   且 coremltools 会把硬路由的 argmax/gather 降级成 select 算子，
            #   分支照样全算（relu=144 两种路由一样）→ 硬路由**省不了计算**还不可微。
            expert_weights = None
            route_logits = None
            if self.experts is not None and step in self.moe_steps:
                route_logits = self.router(refined)                  # [B, num_experts]
                expert_weights = torch.softmax(route_logits, dim=-1)  # [B,E] 可微权重
                # 6 专家各自输出 → 按软权重加权求和（全算，但可微且 CoreML 友好）
                expert_out = torch.zeros_like(refined)
                for e in range(self.num_experts):
                    w = expert_weights[:, e:e + 1]                   # [B,1]
                    expert_out = expert_out + w * self.experts[e](refined)
                # ③ 专家辅助决策 → 与精修特征融合（零初始化起步 → 不影响主干）
                refined = refined + self.expert_out_proj(expert_out)

            # ④ 每步输出（共享头）—— 供 t1 逐步递减监督
            if return_intermediate and self.step_head is not None:
                step_out = self.step_head(refined)
                # 按步裁剪：只在该步保留对应辅助字段（规格：step8 有 lane_offset、
                # step16 有 ttc，其余步只有三主输出）
                entry: Dict[str, torch.Tensor] = {
                    "steer": step_out["steer"],
                    "throttle": step_out["throttle"],
                    "brake": step_out["brake"],
                }
                if step == self.lane_offset_step:
                    entry["lane_offset"] = torch.tanh(step_out["lane_offset"])  # ∈[-1,1]
                if step == self.ttc_step:
                    entry["ttc"] = F.softplus(step_out["ttc"])                  # ≥0 秒
                if expert_weights is not None:
                    # 软路由权重 [B, num_experts]（可微）—— 供 t1 加负载均衡正则/诊断
                    entry["expert_weights"] = expert_weights
                    entry["route_logits"] = route_logits
                intermediates.append(entry)

            # 下一步的隐状态用 refined（把修正后的特征带进下一轮审视）
            h = refined

        if return_intermediate:
            return refined, intermediates
        return refined


# ============================================================================
# 8. 完整模型 M2Model
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
                 state_feat_dim: int = STATE_FEAT_DIM,
                 enable_temporal: bool = True,
                 enable_heading: bool = True,
                 enable_risk: bool = True,
                 num_frames: int = TEMPORAL_FRAMES,
                 temporal_hidden: int = TEMPORAL_HIDDEN,
                 stage3_blocks: int = 6,
                 stage2_blocks: int = 3,
                 heading_unit: str = "compass",
                 enable_refiner: bool = True,
                 refiner_steps: int = 24,
                 refiner_shared: bool = True,
                 moe_steps: Optional[List[int]] = None,
                 num_steps: Optional[int] = None):
        """M2Model 构造。

        ★ 用户拍板（2026-10-09 最新）：「变回 8 步专家 + 16 步自己」
          → refiner_steps 默认 **24**；MoE 默认只在最后 8 步（[17..24]）生效。

        ⚠️ `num_steps` 与 `refiner_steps` 是**同一参数的两个名字**（别名）：
           · `refiner_steps` —— M2Model 的主名（与 IterationRefiner 的 num_steps 区分）
           · `num_steps`     —— 兼容别名（导出脚本/Lead 习惯写 build_model(num_steps=N)）
           实测踩坑：仅支持 refiner_steps 时，`build_model(num_steps=8)` 会被
           **静默当成未知 kwarg 忽略**（仍构建 24 步）→ 导出错误的模型却不报错。
           这里显式收下 num_steps 并覆盖 refiner_steps，消除这个静默陷阱。
           （两者同时传且不一致时以 num_steps 为准并打 warning。）
        """
        if num_steps is not None:
            if num_steps != refiner_steps and refiner_steps != 12:
                import warnings
                warnings.warn(
                    f"M2Model: num_steps={num_steps} 与 refiner_steps={refiner_steps} 不一致，"
                    f"以 num_steps 为准。", stacklevel=2)
            refiner_steps = num_steps
        super().__init__()
        self.deploy = deploy
        self.img_feat_dim = img_feat_dim
        self.lane_feat_dim = lane_feat_dim
        self.det_feat_dim = det_feat_dim
        self.state_feat_dim = state_feat_dim

        # ---- 四个分支 ----
        self.image_encoder = ImageEncoder(deploy=deploy, out_dim=img_feat_dim,
                                          stage3_blocks=stage3_blocks,
                                          stage2_blocks=stage2_blocks)
        self.lane_encoder = LaneMaskEncoder(out_dim=lane_feat_dim)
        self.det_encoder = DetectionEncoder(out_dim=det_feat_dim)
        self.state_encoder = StateEncoder(out_dim=state_feat_dim)

        # ---- 融合头 ----
        fusion_in = img_feat_dim + lane_feat_dim + det_feat_dim + state_feat_dim
        self.fusion_head = FusionHead(in_dim=fusion_in)

        # ---- M4 集成：三个新头（均为可选；模块缺失时自动置 None）----
        # 时序（w5）：吃「前 N 帧的图像特征」序列 → 时序特征，注入融合。
        #   · num_frames=1 时退化为单帧（向后兼容既有单帧调用）
        #   · 只在调用方传入 history_feats 时才真正参与前向
        self.num_frames = num_frames
        self.temporal_hidden = temporal_hidden
        self.temporal_encoder = None
        if enable_temporal and TemporalEncoder is not None:
            self.temporal_encoder = TemporalEncoder(
                feat_dim=img_feat_dim, hidden_dim=temporal_hidden,
                num_frames=num_frames)
            # 时序特征 → 拼回融合输入。用一个小投影把它并进 fusion 维度，
            # 保持 FusionHead 的既有 512 契约（不改变其 in_dim）。
            self.temporal_proj = nn.Linear(temporal_hidden, img_feat_dim)
            # ★ T7 修复（2026-10-08，w5 发现 + Lead 复现）：temporal_proj 必须
            # **零初始化**。原随机初始化（kaiming）下 temporal_proj.weight 范数
            # ≈ 9.22，时序修正范数 ≈ 9.28，而图像特征范数仅 ≈ 1.19 ——
            # **修正/基础 ≈ 7.8 倍（w5 测 50.1 倍，同量级）**，所谓"残差增量修正"
            # 实际是"主导项覆盖"：
            #   1. 旧 checkpoint 无 temporal_proj 权重 → 加载时随机初始化 →
            #      一上来 img_feat 就被放大数倍 → **旧模型行为立刻被破坏**
            #   2. 训练时残差项比主干大数倍 → 梯度被时序分支支配
            #   3. 违背 ResNet 残差标准做法（残差层最后一层应零初始化）
            # 零初始化后：时序修正范数 = 0.0 → img_feat = base + 0 = base，
            # **与旧单帧模型逐位一致**；训练中梯度从零起步逐步学到时序修正量。
            nn.init.zeros_(self.temporal_proj.weight)
            nn.init.zeros_(self.temporal_proj.bias)
        else:
            self.temporal_proj = None

        # 车头朝向（w3）：从图像特征学 Δheading，合成 carHeading。
        # heading_unit 透传（w3 建议，2026-10-08）：默认 **"compass"** ——
        # 本项目两个数据源（NetworkLocator.cameraHeading / dataset_v2）的实际口径
        # 都是 compass（0=正北顺时针）。不用 "auto"：auto 有语义歧义
        # （compass 与 deg 数值范围相同，永远分不出），且对全 <6.78° 的样本会
        # 误判为 rad（差 57.3 倍）；显式声明消除全部猜测，零成本。
        #
        # ⚠️ T7 实测澄清（2026-10-08，穷举 0~360° 720 点）：当前 heading_head 的
        # "compass" 分支与 "deg" 分支输出**恒等**（compass 只做 +180 wrap + ×π/180，
        # 与 deg 的 wrap_to_pi 数学等价）—— 即 compass 分支**没有**做罗盘→数学系的
        # 90° 旋转/镜像。对本集成**无影响**：cameraHeading 与 carHeading 同为 compass
        # 口径，normalize 对两者施加**相同**变换 → Δ = car − camera 的差值语义保持
        # （同口径相减成立，这是 HeadingHead 设计的关键前提，w3 文档已注明）。
        # 若未来训练标签 carHeading 改用数学角口径，需在两侧先统一（转 M1）。
        self.heading_head = None
        if enable_heading and HeadingHead is not None:
            try:
                self.heading_head = HeadingHead(in_dim=img_feat_dim,
                                                heading_unit=heading_unit)
            except TypeError:
                # 兼容旧签名（无 heading_unit 参数）
                self.heading_head = HeadingHead(in_dim=img_feat_dim)

        # 风险/接管（w4）：从融合特征出 confidence + risk。
        self.risk_head = None
        if enable_risk and RiskHead is not None:
            try:
                self.risk_head = RiskHead(RiskHeadConfig(
                    fused_dim=fusion_in, det_feat_dim=det_feat_dim))
            except TypeError:
                # 兼容 RiskHead 构造签名差异（无参 / 不同 kwarg）
                self.risk_head = RiskHead()

        # ---- 迭代精修头（向量版思维链）----
        # fused → 严格GRU×N → refined → FusionHead
        # 零初始化残差 → 起步 refined = fused（不破坏旧行为，旧 checkpoint 兼容）
        # refiner_steps=1 退化为单步（≈无迭代，逐位一致）
        # ★ 用户拍板（2026-10-09）：12 步 = 8 步自己精修 + 4 步专家（moe_steps 默认最后 4 步）
        self.refiner = None
        if enable_refiner:
            self.refiner = IterationRefiner(
                feat_dim=fusion_in, hidden=fusion_in,
                num_steps=refiner_steps, shared=refiner_shared,
                moe_steps=moe_steps)

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
                vehicle_state: Optional[torch.Tensor] = None,
                camera_heading: Optional[torch.Tensor] = None,
                return_aux: bool = False,
                # ↓ 方案 A 后已废弃（时序改为模型内部消化）；保留仅向后兼容
                history_feats: Optional[torch.Tensor] = None,
                frame_mask: Optional[torch.Tensor] = None,
                **kwargs):
        """
        Args:
            image:         [B,3,180,320]（必填）。
                           ⚠️ M4 方案 A（2026-10-08）：**dim0 语义自动判定**——
                           推理时传 [8,3,180,320]（8 帧时序窗口）而其他分支为单帧
                           → 进入时序模式（内部消化，无需外部 history_feats）；
                           训练时传 [B,3,180,320] 且其他分支 batch 一致 → 单帧模式
                           （旧行为，逐位兼容）。
            lane_mask:     [B,1,160,160] 或 None（车道线全丢）
            dets:          [B,N,12] 或 None（无检测框）
            det_mask:      [B,N] 或 None
            vehicle_state: [B,8] 或 None

        Returns:
            steer [B,1] ∈ [-1,1], throttle [B,1] ∈ [0,1], brake [B,1] ∈ [0,1]

        ⚠️ 方案 A 废弃参数：`history_feats` / `frame_mask` 已不再需要（时序改为
           模型内部消化：image batch 维度即时序窗口）。保留参数仅向后兼容——
           旧调用传入时不崩，打一次 warning 后忽略。

        ⚠️ 参数名为什么是 `vehicle_state` 而不是 `state`（实测踩坑记录）：
            coremltools 8.3 把名为 `state` 的输入**静默重命名**为
            `state_workaround`（`state` 与内部实现保留字冲突），导致 Swift 侧
            按 `state` 取输入时抛
            `KeyError: Provided key "state" ... does not match any of the model
             input name(s), which are: {'state_workaround', ...}`。
            实测改用 `vehicle_state` 后**输入名被原样保留**，且该命名恰好与
            `InferenceEngine.swift` 既有的 `vehicle_state` 契约同名 —— 一举两得。
        """
        # ---- 方案 A：废弃参数兼容（打 warning 后忽略，旧调用不崩）----
        if history_feats is not None or frame_mask is not None or kwargs:
            import warnings
            warnings.warn(
                "M2Model.forward: history_feats/frame_mask 已废弃（方案 A：时序改为"
                "模型内部消化，image batch 维度即时序窗口）。本次调用忽略这些参数。",
                DeprecationWarning, stacklevel=2)

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

        # ---- M4 方案 A（Lead 拍板，2026-10-08）：batch 维度即时序窗口 ----
        # image = [8,3,180,320] 的 dim0 是**时序窗口**（w5 实测 batch=8
        # ImageEncoder 1.62ms，预算 5.1%）：8 帧原图一次 batch 跑完 → [8,256] 特征
        # → 视作 [1,8,256] 序列喂 TemporalEncoder → [1,128] → 投影残差回 img_feat。
        #
        # 【自动判定 dim0 是"时序窗口"还是"训练 batch"】
        #   · 推理：image[8] 而 其他分支 batch=1（lane/det/state 只有一帧）→ 时序模式
        #   · 训练：lane/det/state 的 batch 与 image 一致（>1）→ 单帧模式（旧行为）
        #   规则：其他分支的有效 batch（取 lane_mask 的 dim0；None 时用 image 的）
        #   ≠ image.shape[0] 且 image.shape[0] > 1 → 判定时序窗口。
        #   这让**训练脚本完全不用改**（[B,3,H,W] 照旧走单帧），而推理侧只需
        #   把 8 帧叠在 batch 维传入。
        seq_len = image.shape[0]
        lane_batch = lane_mask.shape[0] if lane_mask is not None else batch_size
        det_batch = dets.shape[0] if dets is not None else batch_size
        state_batch = vehicle_state.shape[0] if vehicle_state is not None else batch_size
        other_batch = lane_batch if lane_mask is not None else (
            det_batch if dets is not None else state_batch)
        # 时序窗口判定：image 的 dim0 与其他分支不一致（其他分支是 1，image 是 8）
        # → dim0 是时序窗口；一致 → dim0 是训练 batch（旧单帧行为，逐位兼容）。
        seq_mode = (other_batch != seq_len and seq_len > 1
                    and self.temporal_encoder is not None)

        temporal_feat = None
        if seq_mode:
            # ★ 方案 A 修复（w5 发现，2026-10-08）：时序模式下其他三个分支
            # （lane/det/state）只给**当前帧**（[1,...]），而 img_feat 是 [8,256]。
            # torch.cat(dim=1) 要求 dim0 一致 → 8 vs 1 抛
            # "Sizes of tensors must match except in dimension 1"。
            # 修法：把 img_feat 降到**当前帧**（[8,256] → [1,256]，取最后一帧）
            # 再与单帧分支融合；时序信息经 TemporalEncoder 聚合到 projected 上。
            current_img_feat = img_feat[-1:]                     # [1,256] 当前帧
            temporal_feat = self.temporal_encoder(
                img_feat.unsqueeze(0), None)                     # [1, hidden]
            projected = self.temporal_proj(temporal_feat)        # [1,256]（零初始化 → 0）
            # 残差相加到当前帧：img_feat_new = 当前帧 + 时序修正（零初始化 → 逐位等于当前帧）
            img_feat = current_img_feat + projected              # [1,256]
            # 供后续分支对齐：时序模式下模型有效 batch = 1
            batch_size = 1

        # ---- 分支 2：车道线 [B,1,160,160] → [B,64]（None → 零向量）----
        lane_feat = self.lane_encoder(lane_mask, batch_size, image)

        # ---- 分支 3：检测框 [B,N,12]+[B,N] → [B,128]（None/空 → 零向量）----
        det_feat = self.det_encoder(dets, det_mask, batch_size, image)

        # ---- 分支 4：状态 [B,8] → [B,64]（None → 零向量）----
        state_feat = self.state_encoder(vehicle_state, batch_size, image)

        # ---- 融合：[B,512] → 迭代精修 → 三个控制量 ----
        fused = torch.cat([img_feat, lane_feat, det_feat, state_feat], dim=1)  # [B,512]
        # 迭代精修（24 步向量版思维链）：零初始化起步 → refined = fused + 0 = fused
        # refiner=None（禁用）或 num_steps=1（单步）时退化为无迭代（逐位一致）
        refiner_intermediates: Optional[List[torch.Tensor]] = None
        if self.refiner is not None:
            if return_aux:
                # 训练侧需要每步输出做逐步递减监督 → 取中间步
                fused, refiner_intermediates = self.refiner(fused, return_intermediate=True)
            else:
                fused = self.refiner(fused)
        steer, throttle, brake = self.fusion_head(fused)

        # ---- 三个主输出：契约不变（向后兼容）----
        if not return_aux:
            return steer, throttle, brake

        # ---- M4 新增辅助输出（不参与主契约，仅 return_aux=True 时返回）----
        aux: Dict[str, Optional[object]] = {
            "steer": steer, "throttle": throttle, "brake": brake,
            "car_heading": None, "confidence": None, "risk": None,
            "temporal_feat": temporal_feat,
            "refiner_intermediates": refiner_intermediates,
        }
        # 车头朝向（w3）：从图像特征学 Δheading；camera_heading 由调用方给（rad）
        if self.heading_head is not None:
            try:
                aux["car_heading"] = self.heading_head(img_feat, camera_heading)
            except Exception:
                # 头内部校验失败（如 camera_heading 单位/形状异常）→ 如实置 None，
                # 不让可选辅助输出拖垮主驾驶链路
                aux["car_heading"] = None
        # 风险/接管（w4）：从融合特征出 confidence + risk ∈ [0,1]
        if self.risk_head is not None:
            try:
                confidence, risk = self.risk_head(
                    fused, det_feat=det_feat, det_mask=det_mask,
                    speed=(vehicle_state[:, 0] if vehicle_state is not None
                           and vehicle_state.dim() == 2 and vehicle_state.shape[1] > 0
                           else None))
                aux["confidence"] = confidence
                aux["risk"] = risk
            except Exception:
                pass
        return steer, throttle, brake, aux

    # ------------------------------------------------------------------
    def reparameterize(self) -> None:
        """训练态 → 部署态：把图像分支的 RepVGG 多分支折叠为纯 3×3。

        调用后模型参数量与推理耗时均下降（BN 折进卷积，少一层访存），
        精度数学等价。

        ⚠️⚠️ **加载 checkpoint 的正确顺序（T13 实测踩坑，静默失败）**：
            ❌ 错误：`m = build_model(deploy=True); m.load_state_dict(ckpt)`
               → 部署态 RepVGG 只有折叠后的单个 3×3（键名 `...conv.weight`），
                 而 checkpoint 存的是**训练态多分支**（`rbr_3x3/rbr_1x1/rbr_identity`
                 及其 BN）→ **184 个键静默失配**（`strict=False` 不报错），
                 已训练的图像骨干被当随机权重 → 导出产物看着正常但精度全废。
            ✅ 正确：`m = build_model(deploy=False)`      # ① 训练态构建
                     `m.load_state_dict(ckpt, strict=False)`  # ② missing=96, unexpected=0
                     `m.reparameterize()`                  # ③ 折叠 → 部署态
            实测：训练态 9,086,774 参数 → 折叠后 8,799,446（差 287,328）
            建议导出脚本**断言 `unexpected` 为空**（正常应 0），否则说明用错了 deploy 态。
        """
        if self.deploy:
            return
        self.image_encoder.reparameterize()
        self.deploy = True

    # ------------------------------------------------------------------
    def get_param_count(self) -> Dict[str, int]:
        """各分支参数量统计（部署前训练态）。"""
        out = {
            "image_encoder": sum(p.numel() for p in self.image_encoder.parameters()),
            "lane_encoder": sum(p.numel() for p in self.lane_encoder.parameters()),
            "det_encoder": sum(p.numel() for p in self.det_encoder.parameters()),
            "state_encoder": sum(p.numel() for p in self.state_encoder.parameters()),
            "fusion_head": sum(p.numel() for p in self.fusion_head.parameters()),
        }
        # M4 集成新增头（可选；None 时报 0，保持键稳定供 Swift/脚本读取）
        out["temporal_encoder"] = (sum(p.numel() for p in self.temporal_encoder.parameters())
                                    + sum(p.numel() for p in self.temporal_proj.parameters())
                                    if self.temporal_encoder is not None else 0)
        out["heading_head"] = (sum(p.numel() for p in self.heading_head.parameters())
                                if self.heading_head is not None else 0)
        out["risk_head"] = (sum(p.numel() for p in self.risk_head.parameters())
                             if self.risk_head is not None else 0)
        out["total"] = sum(p.numel() for p in self.parameters())
        return out

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

def build_model(deploy: bool = False, **kwargs) -> M2Model:
    """构建 M2 主驾驶模型。

    Args:
        deploy: False=训练态（RepVGG 多分支，精度高）
                True =部署态（已重参数化为纯 3×3，推理快）
        **kwargs: 透传给 M2Model 的可选参数（M4 集成新增）：
            · enable_temporal / enable_heading / enable_risk —— 三个新头开关
            · num_frames / temporal_hidden —— 时序窗口与隐藏维度
            · stage2_blocks / stage3_blocks —— 骨干宽度旋钮（加大容量用）

    Returns:
        M2Model 实例

    ⚠️ 向后兼容：`build_model(deploy=...)` 的旧调用逐字不变；
    未知 kwarg 会被忽略并打印警告（不让训练脚本因多传参数而崩）。
    """
    try:
        return M2Model(deploy=deploy, **kwargs)
    except TypeError as e:
        # 旧环境/拼错 kwarg：退化为默认参数构建，不让训练链路断
        if kwargs:
            print(f"[M2Model] ⚠ 忽略无法识别的构造参数 {sorted(kwargs)}：{e}")
            return M2Model(deploy=deploy)
        raise


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
