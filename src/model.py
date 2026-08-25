# [TRAINING-ONLY] 此文件仅用于离线训练，运行时由 C++ inference.h (LibTorch) 替代
"""
M9 端到端自动驾驶模型
架构：RepVGG-A0（共享骨干，10路图像各过一遍）
     + PointNet-Lite（共享骨干，2路点云各过一遍）
     + 融合头（13,318维 → 转向/油门/刹车三输出）

特性：
- 训练时 RepVGG 多分支（3×3 + 1×1 + identity），推理时结构重参数化为纯 3×3
- 10 路摄像头共享同一个 RepVGG-A0，输出各自 1280 维特征
- 2 路激光雷达共享同一个 PointNet-Lite，输出各自 256 维特征
- 融合头接收 10×1280 + 2×256 + 6(车辆状态) = 13,318 维
- 目标模型大小 FP16 ≤ 31 MB
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
from typing import Tuple, Dict


# ==================== RepVGG 构建块 ====================

class RepVGGBlock(nn.Module):
    """
    RepVGG 基础块
    训练时：y = ReLU( Conv3×3(x) + Conv1×1(x) + Identity(x) )
    推理时：reparameterize() 后合并为 y = Conv3×3(x)
    """

    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        stride: int = 1,
        deploy: bool = False,
    ):
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.deploy = deploy
        self.stride = stride

        if deploy:
            self.rbr_reparam = nn.Conv2d(
                in_channels, out_channels, kernel_size=3,
                stride=stride, padding=1, bias=True
            )
        else:
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
            self.rbr_identity = (
                nn.BatchNorm2d(in_channels)
                if in_channels == out_channels and stride == 1
                else None
            )

        self.nonlinearity = nn.ReLU(inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.deploy:
            return self.nonlinearity(self.rbr_reparam(x))
        out = self.rbr_3x3(x) + self.rbr_1x1(x)
        if self.rbr_identity is not None:
            out = out + self.rbr_identity(x)
        return self.nonlinearity(out)

    def _pad_1x1_to_3x3(self, kernel_1x1: torch.Tensor) -> torch.Tensor:
        return F.pad(kernel_1x1, [1, 1, 1, 1])

    def _fuse_bn(self, conv: nn.Conv2d, bn: nn.BatchNorm2d) -> Tuple[torch.Tensor, torch.Tensor]:
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

    def reparameterize(self):
        if self.deploy:
            return
        w_3x3, b_3x3 = self._fuse_bn(self.rbr_3x3[0], self.rbr_3x3[1])
        w_1x1, b_1x1 = self._fuse_bn(self.rbr_1x1[0], self.rbr_1x1[1])
        w_1x1_padded = self._pad_1x1_to_3x3(w_1x1)
        if self.rbr_identity is not None:
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
        del self.rbr_3x3, self.rbr_1x1, self.rbr_identity
        self.deploy = True


class RepVGGStage(nn.Module):
    """RepVGG 阶段：多个 RepVGGBlock 堆叠"""

    def __init__(self, in_channels: int, out_channels: int, num_blocks: int, deploy: bool = False):
        super().__init__()
        layers = []
        for i in range(num_blocks):
            stride = 2 if i == 0 else 1
            layers.append(RepVGGBlock(
                in_channels if i == 0 else out_channels, out_channels, stride=stride, deploy=deploy
            ))
        self.stage = nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.stage(x)


class RepVGGA0(nn.Module):
    """
    RepVGG-A0 骨干（共享）
    Stage 0: Conv3×3 stride2, 3→48, 224→112
    Stage 1: 2 blocks, 48→48, 112→56
    Stage 2: 4 blocks, 48→96, 56→28
    Stage 3: 14 blocks, 96→192, 28→14
    Stage 4: 1 block, 192→1280, 14→7
    Global AvgPool → 1280
    """

    def __init__(self, deploy: bool = False):
        super().__init__()
        self.deploy = deploy
        self.stage0 = nn.Sequential(
            nn.Conv2d(3, 48, kernel_size=3, stride=2, padding=1, bias=False),
            nn.BatchNorm2d(48), nn.ReLU(inplace=True),
        )
        self.stage1 = RepVGGStage(48, 48, num_blocks=2, deploy=deploy)
        self.stage2 = RepVGGStage(48, 96, num_blocks=4, deploy=deploy)
        self.stage3 = RepVGGStage(96, 192, num_blocks=14, deploy=deploy)
        self.stage4 = RepVGGStage(192, 1280, num_blocks=1, deploy=deploy)
        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.stage0(x)
        x = self.stage1(x)
        x = self.stage2(x)
        x = self.stage3(x)
        x = self.stage4(x)
        x = self.global_pool(x)
        return x.flatten(1)

    def reparameterize(self):
        if self.deploy:
            return
        for stage in [self.stage1, self.stage2, self.stage3, self.stage4]:
            for block in stage.stage:
                if isinstance(block, RepVGGBlock):
                    block.reparameterize()
        self.deploy = True

    def get_feature_dim(self) -> int:
        return 1280


# ==================== PointNet-Lite ====================

class TNet(nn.Module):
    """T-Net：学习点云空间变换矩阵"""

    def __init__(self, k: int = 3):
        super().__init__()
        self.k = k
        self.conv1 = nn.Conv1d(k, 64, 1)
        self.conv2 = nn.Conv1d(64, 128, 1)
        self.conv3 = nn.Conv1d(128, 1024, 1)
        self.bn1 = nn.BatchNorm1d(64)
        self.bn2 = nn.BatchNorm1d(128)
        self.bn3 = nn.BatchNorm1d(1024)
        self.fc1 = nn.Linear(1024, 512)
        self.fc2 = nn.Linear(512, 256)
        self.fc3 = nn.Linear(256, k * k)
        self.bn4 = nn.BatchNorm1d(512)
        self.bn5 = nn.BatchNorm1d(256)
        nn.init.zeros_(self.fc3.weight)
        self.fc3.bias.data.copy_(torch.eye(k).flatten())

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        bs = x.size(0)
        x = F.relu(self.bn1(self.conv1(x)))
        x = F.relu(self.bn2(self.conv2(x)))
        x = F.relu(self.bn3(self.conv3(x)))
        x = torch.max(x, dim=2, keepdim=False)[0]
        x = F.relu(self.bn4(self.fc1(x)))
        x = F.relu(self.bn5(self.fc2(x)))
        x = self.fc3(x)
        return x.reshape(bs, self.k, self.k)


class PointNetLite(nn.Module):
    """
    PointNet-Lite 轻量版（共享，~108K 参数）
    输入变换 → MLP(3→64→128→256) → MaxPool → FC(256→128→256) → 256
    """

    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv1d(3, 64, 1)
        self.conv2 = nn.Conv1d(64, 128, 1)
        self.conv3 = nn.Conv1d(128, 256, 1)
        self.bn1 = nn.BatchNorm1d(64)
        self.bn2 = nn.BatchNorm1d(128)
        self.bn3 = nn.BatchNorm1d(256)
        self.fc1 = nn.Linear(256, 128)
        self.fc2 = nn.Linear(128, 256)
        self.bn4 = nn.BatchNorm1d(128)
        self._init_weights()
        self.input_transform = TNet(k=3)

    def _init_weights(self):
        for m in self.modules():
            if isinstance(m, (nn.Conv1d, nn.Linear)):
                nn.init.kaiming_normal_(m.weight, mode='fan_out', nonlinearity='relu')
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x.transpose(2, 1).contiguous()
        trans = self.input_transform(x)
        x = torch.bmm(trans, x)
        x = F.relu(self.bn1(self.conv1(x)))
        x = F.relu(self.bn2(self.conv2(x)))
        x = F.relu(self.bn3(self.conv3(x)))
        x = torch.max(x, dim=2, keepdim=False)[0]
        x = F.relu(self.bn4(self.fc1(x)))
        x = self.fc2(x)
        return x

    def get_feature_dim(self) -> int:
        return 256


# ==================== 融合头 ====================

class FusionHead(nn.Module):
    """
    融合头：13,318 维 → 转向(tanh) + 油门(sigmoid) + 刹车(sigmoid)
    FC(512) → ReLU → Drop(0.2) → FC(256) → ReLU → Drop(0.1) → FC(128) → ReLU → 三头
    """

    def __init__(self, cam_feature_dim=1280, cam_count=10,
                 lidar_feature_dim=256, lidar_count=2, state_dim=6):
        super().__init__()
        input_dim = cam_feature_dim * cam_count + lidar_feature_dim * lidar_count + state_dim
        self.input_dim = input_dim

        self.fc1 = nn.Linear(input_dim, 512)
        self.dropout1 = nn.Dropout(0.2)
        self.fc2 = nn.Linear(512, 256)
        self.dropout2 = nn.Dropout(0.1)
        self.fc3 = nn.Linear(256, 128)
        self.steer_head = nn.Linear(128, 1)
        self.throttle_head = nn.Linear(128, 1)
        self.brake_head = nn.Linear(128, 1)
        self._init_weights()

    def _init_weights(self):
        for m in self.modules():
            if isinstance(m, nn.Linear):
                # fan_in 模式：对 (128→1) 输出头给出 std=√(2/128)≈0.125，
                # 而非 fan_out 的 √(2/1)=1.414（会导致 tanh/sigmoid 一上来饱和、梯度归零、训练冻结）
                nn.init.kaiming_normal_(m.weight, mode='fan_in', nonlinearity='relu')
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, cam_features, lidar_features, vehicle_state):
        bs = cam_features.size(0)
        cam_flat = cam_features.reshape(bs, -1)
        lidar_flat = lidar_features.reshape(bs, -1)
        fused = torch.cat([cam_flat, lidar_flat, vehicle_state], dim=1)
        x = F.relu(self.fc1(fused))
        x = self.dropout1(x)
        x = F.relu(self.fc2(x))
        x = self.dropout2(x)
        x = F.relu(self.fc3(x))
        steer = torch.tanh(self.steer_head(x))
        throttle = torch.sigmoid(self.throttle_head(x))
        brake = torch.sigmoid(self.brake_head(x))
        return steer, throttle, brake


# ==================== M9 完整模型 ====================

class M9Model(nn.Module):
    """
    M9 端到端自动驾驶模型
    输入：图像 [B,10,3,H,W] + 点云 [B,2,N,3] + 状态 [B,6]
    输出：steer [-1,1] + throttle [0,1] + brake [0,1]
    """

    def __init__(self, deploy: bool = False):
        super().__init__()
        self.deploy = deploy
        self.repvgg = RepVGGA0(deploy=deploy)
        self.pointnet = PointNetLite()
        self.fusion_head = FusionHead()
        self.cam_count = 10
        self.lidar_count = 2

    def forward(self, images, point_clouds, vehicle_state):
        bs = images.size(0)
        if not images.is_contiguous():
            images = images.contiguous()
        images_flat = images.reshape(bs * images.shape[1], *images.shape[2:])
        cam_features_flat = self.repvgg(images_flat)
        cam_features = cam_features_flat.reshape(bs, images.shape[1], -1)
        pc_flat = point_clouds.reshape(bs * self.lidar_count, *point_clouds.shape[2:])
        lidar_features_flat = self.pointnet(pc_flat)
        lidar_features = lidar_features_flat.reshape(bs, self.lidar_count, -1)
        return self.fusion_head(cam_features, lidar_features, vehicle_state)

    def reparameterize(self):
        if self.deploy:
            return
        self.repvgg.reparameterize()
        self.deploy = True

    def get_param_count(self) -> Dict[str, int]:
        return {
            "repvgg": sum(p.numel() for p in self.repvgg.parameters()),
            "pointnet": sum(p.numel() for p in self.pointnet.parameters()),
            "fusion_head": sum(p.numel() for p in self.fusion_head.parameters()),
            "total": sum(p.numel() for p in self.parameters()),
        }

    def get_model_size_mb(self, precision: str = "fp32") -> float:
        total_params = sum(p.numel() for p in self.parameters())
        bytes_per_param = {"fp32": 4, "fp16": 2, "int8": 1}
        return total_params * bytes_per_param.get(precision, 4) / (1024 * 1024)


# ==================== 损失函数 ====================

class M9Loss(nn.Module):
    """MSE(转向) + Huber(油门) + Huber(刹车) """

    def __init__(self, steer_weight=1.0, throttle_weight=0.5, brake_weight=0.5):
        super().__init__()
        self.steer_weight = steer_weight
        self.throttle_weight = throttle_weight
        self.brake_weight = brake_weight
        self.mse = nn.MSELoss()
        self.huber = nn.SmoothL1Loss(beta=0.1)

    def forward(self, pred_steer, pred_throttle, pred_brake, gt_steer, gt_throttle, gt_brake):
        loss_steer = self.mse(pred_steer, gt_steer)
        loss_throttle = self.huber(pred_throttle, gt_throttle)
        loss_brake = self.huber(pred_brake, gt_brake)
        total = self.steer_weight * loss_steer + self.throttle_weight * loss_throttle + self.brake_weight * loss_brake
        return total, {
            "steer": loss_steer.item(), "throttle": loss_throttle.item(),
            "brake": loss_brake.item(), "total": total.item(),
        }


# ==================== M9-Mono 单目变体（游戏辅助专用）====================

class M9MonoModel(nn.Module):
    """M9 单目变体：单摄像头 + 车辆状态 → 三输出。

    游戏辅助场景只有屏幕截图（单 cam）+ HUD OCR（speed/rpm/gear），
    无激光雷达。RepVGG-A0 共享主干，融合头 1280+6=1286 维。

    输入：image [B,3,H,W] + vehicle_state [B,6]（speed/rpm/gear/speed_norm/gear_norm/reserved）
    输出：steer[-1,1] + throttle[0,1] + brake[0,1]
    """

    def __init__(self, deploy: bool = False):
        super().__init__()
        self.deploy = deploy
        self.repvgg = RepVGGA0(deploy=deploy)
        # 单 cam + 6 维 state → 1280+6=1286
        self.fusion_head = FusionHead(
            cam_feature_dim=1280, cam_count=1,
            lidar_feature_dim=0, lidar_count=0,
            state_dim=6,
        )
        self.cam_count = 1
        self.lidar_count = 0

    def forward(self, image, vehicle_state):
        # 简化路径（CoreML/ONNX 友好）：跳过空 lidar 张量构造，
        # 直接复用 FusionHead 的 fc 链路（lidar_count=0 时输入 dim 仅 1280+6=1286）
        if not image.is_contiguous():
            image = image.contiguous()
        cam_feat = self.repvgg(image)              # [B, 1280]
        # 直接拼接 cam_feat + vehicle_state，绕过 lidar=0 的 reshape/cat
        # FusionHead 的 fc1 期望输入维度 = 1280*1 + 0*0 + 6 = 1286
        fused = torch.cat([cam_feat, vehicle_state], dim=1)
        x = torch.relu(self.fusion_head.fc1(fused))
        x = self.fusion_head.dropout1(x)
        x = torch.relu(self.fusion_head.fc2(x))
        x = self.fusion_head.dropout2(x)
        x = torch.relu(self.fusion_head.fc3(x))
        steer = torch.tanh(self.fusion_head.steer_head(x))
        throttle = torch.sigmoid(self.fusion_head.throttle_head(x))
        brake = torch.sigmoid(self.fusion_head.brake_head(x))
        return steer, throttle, brake

    def reparameterize(self):
        if self.deploy:
            return
        self.repvgg.reparameterize()
        self.deploy = True

    def get_param_count(self) -> Dict[str, int]:
        return {
            "repvgg": sum(p.numel() for p in self.repvgg.parameters()),
            "fusion_head": sum(p.numel() for p in self.fusion_head.parameters()),
            "total": sum(p.numel() for p in self.parameters()),
        }

    def get_model_size_mb(self, precision: str = "fp32") -> float:
        total = sum(p.numel() for p in self.parameters())
        return total * {"fp32": 4, "fp16": 2, "int8": 1}.get(precision, 4) / (1024 * 1024)


# ==================== 工具函数 ====================

def build_m9(deploy: bool = False) -> M9Model:
    return M9Model(deploy=deploy)


def build_m9_mono(deploy: bool = False) -> M9MonoModel:
    """构建 M9 单目变体（游戏辅助专用）。

    用途：屏幕截图 + HUD → 控制输出。
    导出：build_m9_mono(deploy=True) → export_onnx → CoreML。
    """
    return M9MonoModel(deploy=deploy)


def load_pretrained_repvgg(model: M9Model, pretrained_path: str):
    pretrained = torch.load(pretrained_path, map_location="cpu", weights_only=False)
    # 解包 model_state_dict 键（本仓库所有存档均含此键）
    if isinstance(pretrained, dict) and "model_state_dict" in pretrained:
        pretrained = pretrained["model_state_dict"]
    # 仅提取 repvgg.* 前缀的键，其余忽略
    repvgg_state = {k[len("repvgg."):]: v for k, v in pretrained.items()
                    if k.startswith("repvgg.")}
    if repvgg_state:
        _r = model.repvgg.load_state_dict(repvgg_state, strict=False)
        missing, unexpected = _r.missing_keys, _r.unexpected_keys
        print(f"[M9] RepVGG-A0 预训练权重已加载: {pretrained_path} "
              f"(命中 {len(repvgg_state)} 键, 缺失 {len(missing)}, 多余 {len(unexpected)})")
    else:
        print(f"[M9] ⚠ 预训练文件中未找到 repvgg.* 前缀权重: {pretrained_path}")


def export_for_deployment(model: M9Model, save_path: str):
    if not model.deploy:
        model.reparameterize()
    model.eval()
    torch.save({"model_state_dict": model.state_dict(), "deploy": True}, save_path)
    print(f"[M9] 部署模型导出: {save_path}")


def export_torchscript(state_dict_path: str, save_path: str, pc_m: int = 1024):
    """导出 TorchScript 部署模型（供 C++ inference.h::load_model 加载）。

    格式契约：
      - export_for_deployment 产出 state_dict（Python 侧 build_m9+load_state_dict 用）
      - 本函数产出 TorchScript（C++ 侧 torch::jit::load 用）
      两者不可混用：jit::load 加载 state_dict 会抛 "PytorchStreamReader failed"。

    流程：build_m9(deploy=True) → load_state_dict(去 _orig_mod 前缀) → jit.script → save
    若 script 失败（forward 含 *shape 解包等 TorchScript 不支持的语法），回退 jit.trace。

    Args:
        state_dict_path: m9_deploy.pth 路径（export_for_deployment 产出）
        save_path: 输出 *_script.pt 路径
        pc_m: trace 回退时固定的点云点数（C++ 侧 pc_M 须匹配，默认 1024）
    """
    # 1. 构建部署结构（deploy=True → 已重参数化为纯 3×3）
    model = build_m9(deploy=True)

    # 2. 加载 state_dict（剥离 torch.compile 的 _orig_mod. 前缀）
    ckpt = torch.load(state_dict_path, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    model.load_state_dict(sd)
    model.eval()

    # 3. 首选 jit.script（保留控制流，支持动态 shape）
    try:
        scripted = torch.jit.script(model)
        scripted.save(save_path)
        print(f"[M9] TorchScript 导出成功（script）: {save_path}")
        return
    except Exception as e:
        print(f"[M9] jit.script 失败（{type(e).__name__}: {e}），回退 jit.trace")

    # 4. 回退 jit.trace（需 dummy 输入，点云数 pc_m 固定）
    dummy_images = torch.zeros(1, 10, 3, 224, 224)
    dummy_pc = torch.zeros(1, 2, pc_m, 3)
    dummy_state = torch.zeros(1, 6)
    with torch.no_grad():
        traced = torch.jit.trace(model, (dummy_images, dummy_pc, dummy_state))
    traced.save(save_path)
    print(f"[M9] TorchScript 导出成功（trace, pc_m={pc_m}）: {save_path}")
    print(f"  └ 注意：trace 模式下 C++ 侧 pc_M 须固定为 {pc_m}")


def export_onnx_mono(state_dict_path: str, save_path: str,
                     img_h: int = 180, img_w: int = 320) -> None:
    """导出 M9-Mono 为 ONNX 格式（供 C++ inference.h / CoreML 加载）。

    输入：
      image:        [1, 3, H, W]   float32 (NCHW, 0-1 归一化)
      vehicle_state:[1, 6]         float32 (speed/rpm/gear/speed_norm/gear_norm/reserved)
    输出：
      steer:        [1, 1]   tanh
      throttle:     [1, 1]   sigmoid
      brake:        [1, 1]   sigmoid

    Args:
        state_dict_path: 训练保存的 .pth 路径
        save_path: 输出 .onnx 路径
        img_h, img_w: 模型输入分辨率（默认 180×320，匹配 game_assist CAPTURE_H/W）
    """
    model = build_m9_mono(deploy=True)
    ckpt = torch.load(state_dict_path, map_location="cpu", weights_only=False)
    sd = ckpt["model_state_dict"] if isinstance(ckpt, dict) and "model_state_dict" in ckpt else ckpt
    sd = {k[len("_orig_mod."):] if k.startswith("_orig_mod.") else k: v for k, v in sd.items()}
    model.load_state_dict(sd, strict=False)
    model.eval()

    dummy_img = torch.zeros(1, 3, img_h, img_w)
    dummy_state = torch.zeros(1, 6)
    with torch.no_grad():
        torch.onnx.export(
            model, (dummy_img, dummy_state), save_path,
            input_names=["image", "vehicle_state"],
            output_names=["steer", "throttle", "brake"],
            dynamic_axes={
                "image":         {0: "batch"},
                "vehicle_state": {0: "batch"},
                "steer":         {0: "batch"},
                "throttle":      {0: "batch"},
                "brake":         {0: "batch"},
            },
            opset_version=14,
            do_constant_folding=True,
        )
    print(f"[M9-Mono] ONNX 导出成功: {save_path} ({img_h}×{img_w})")


def get_model_stats(model: M9Model) -> str:
    counts = model.get_param_count()
    size_fp32 = model.get_model_size_mb("fp32")
    size_fp16 = model.get_model_size_mb("fp16")
    size_int8 = model.get_model_size_mb("int8")
    lines = [
        "=" * 50, "M9 模型参数统计", "=" * 50,
        f"RepVGG-A0:    {counts['repvgg']:>10,}  ({counts['repvgg']/1e6:.2f}M)",
        f"PointNet-Lite: {counts['pointnet']:>10,}  ({counts['pointnet']/1e3:.1f}K)",
        f"融合头:        {counts['fusion_head']:>10,}  ({counts['fusion_head']/1e6:.2f}M)",
        f"{'─' * 50}",
        f"合计:          {counts['total']:>10,}  ({counts['total']/1e6:.2f}M)",
        f"FP32: {size_fp32:.1f} MB  FP16: {size_fp16:.1f} MB  INT8: {size_int8:.1f} MB",
        "=" * 50,
    ]
    return "\n".join(lines)
