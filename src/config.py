"""
全局配置常量 — 自动驾驶模拟系统
所有路径、超参数、物理常量集中管理
"""

import os
import sys
from pathlib import Path

# ===================== 项目根路径 =====================
# 修 N1：原硬编码 /Users/dupi/Desktop/自动驾驶系统，改为相对路径（config.py 在 src/ 下）
ROOT_DIR = Path(__file__).resolve().parent.parent
# _MEIPASS 保留用于下方 MAP_DIR 的 sidecar 模式检测（PyInstaller 打包后）
_MEIPASS = getattr(sys, "_MEIPASS", None)
DATA_DIR = ROOT_DIR / "data"
MODELS_DIR = ROOT_DIR / "models"
SRC_DIR = ROOT_DIR / "src"
CONFIGS_DIR = ROOT_DIR / "configs"
# DOCS_DIR removed — unused

# ===================== 地图文件 =====================
# Sidecar 模式支持环境变量覆盖地图目录：
# AURORA_MAP_DIR → 指定地图目录（如 ~/Library/Application Support/AuroraDrive/）
# 未设置时回退到 DATA_DIR（开发模式）或 App Support（sidecar 模式）
_MAP_DIR_ENV = os.environ.get("AURORA_MAP_DIR")
if _MAP_DIR_ENV:
    MAP_DIR = Path(_MAP_DIR_ENV)
elif _MEIPASS:
    # 打包后优先 App Support（首启解压位置）
    _app_support = Path.home() / "Library" / "Application Support" / "AuroraDrive"
    MAP_DIR = _app_support if _app_support.exists() else DATA_DIR
else:
    MAP_DIR = DATA_DIR

MAP_FILE = MAP_DIR / "fujian_map.bin"
MAP_MAX_SIZE = 700 * 1024 * 1024  # 700 MB

# ===================== 地图数据常量 =====================
ROAD_TYPES = {
    0: "高速",
    1: "国道",
    2: "省道",
    3: "县道",
    4: "乡道",
    5: "村道",
}

# ===================== 程序化道路世界 =====================
WORLD_LOAD_RADIUS = 500.0    # 自车周围加载半径 (m)
WORLD_UNLOAD_RADIUS = 800.0  # 超出此半径释放 (m)

# ===================== 车辆参数 =====================
# 自车
EGO_VEHICLE = {
    "length": 4.5,
    "width": 1.8,
    "height": 1.5,
    "wheelbase": 2.7,
    "max_speed": 180.0,     # km/h
    "max_accel": 3.0,       # m/s²
    "max_brake": 8.0,       # m/s²
    "max_steer": 0.6,       # rad (~35°)
}

# AI车辆类型分布
VEHICLE_TYPES = {
    "car": {
        "prob": 0.60,
        "length": 4.5,
        "width": 1.8,
        "height": 1.5,
        "max_speed": 180.0,  # km/h
        "wheelbase": 2.7,
    },
    "suv": {
        "prob": 0.20,
        "length": 5.0,
        "width": 2.0,
        "height": 1.8,
        "max_speed": 160.0,
        "wheelbase": 2.9,
    },
    "truck": {
        "prob": 0.10,
        "length": 12.0,
        "width": 2.5,
        "height": 4.0,
        "max_speed": 100.0,
        "wheelbase": 6.5,
    },
    "bus": {
        "prob": 0.05,
        "length": 12.0,
        "width": 2.5,
        "height": 3.5,
        "max_speed": 80.0,
        "wheelbase": 6.5,
    },
    "motorcycle": {
        "prob": 0.05,
        "length": 2.0,
        "width": 0.8,
        "height": 1.2,
        "max_speed": 120.0,
        "wheelbase": 1.4,
    },
}

# ===================== 交通管理 =====================
TRAFFIC_MAX_VEHICLES = 150       # 活跃车辆上限
TRAFFIC_UPDATE_HZ = 10           # 更新频率
TRAFFIC_SPAWN_FRONT_MIN = 200.0  # 生成范围前端 (m)
TRAFFIC_SPAWN_FRONT_MAX = 300.0  # 生成范围后端 (m)
TRAFFIC_DESPAWN_REAR = 200.0     # 销毁范围后方 (m)

# 生成密度 (辆/km)
TRAFFIC_DENSITY = {
    "highway": 30.0,   # 高速
    "urban": 15.0,     # 城市
    "rural": 5.0,      # 县道/村道
}

# ===================== IDM 参数 =====================
IDM_PARAMS = {
    "v0_factor": 0.9,      # 期望速度 = 限速 × 0.9
    "a_max": 2.0,          # 最大加速度 (m/s²)
    "b": 1.5,              # 舒适减速度 (m/s²)
    "s0": 2.0,             # 最小间距 (m)
    "T": 1.5,              # 安全时距 (s)
    "delta": 4,            # 加速指数
}

# ===================== MOBIL 参数 =====================
MOBIL_PARAMS = {
    "p": 0.5,              # 礼貌因子
    "delta_a_th": 0.2,     # 换道阈值 (m/s²)
    "b_safe": 4.0,         # 最大安全减速度 (m/s²)
}

# ===================== 特殊场景生成概率 =====================
SCENARIO_PROBS = {
    "normal_follow": 0.50,    # 正常跟车
    "hard_brake": 0.10,       # 前车急刹
    "cut_in": 0.10,           # 旁车切入
    "traffic_jam": 0.10,      # 拥堵缓行
    "open_road": 0.10,        # 空旷路段
    "curve_overtake": 0.05,   # 弯道超车
    "intersection": 0.05,     # 路口交互
}

# ===================== 路口行为规则 =====================
INTERSECTION_RULES = {
    "signalized": {
        "ego": "recognize_light",
        "ai": {"yellow_run_prob": 0.50, "red_stop": True},
    },
    "unsignalized": {
        "ego": "yield_rules",
        "ai": "random_yield_or_go",
    },
    "roundabout": {
        "ego": "slow_enter",
        "ai": "inside_priority",
    },
    "ramp": {
        "ego": "accelerate_merge",
        "ai": "main_road_may_yield",
    },
}

# ===================== 摄像头 =====================
CAMERA_COUNT = 10
CAMERA_RESOLUTION = (224, 224, 3)  # H, W, C
CAMERA_FOV_HORIZONTAL = 36.0       # 每路水平FOV (度)
CAMERA_FOV_VERTICAL = 45.0         # 垂直FOV (度)
CAMERA_MOUNT_HEIGHT = 1.6          # 安装高度 (m)
CAMERA_FPS = 30

# 10路摄像头方位角 (度) — 均匀覆盖 360°
CAMERA_AZIMUTHS = [0, 36, 72, 108, 144, 180, 216, 252, 288, 324]

# ===================== 激光雷达 =====================
LIDAR_COUNT = 2
LIDAR_MAX_POINTS = 2048            # 每帧最大点数
LIDAR_MAX_RANGE = 80.0             # 最大探测距离 (m)
LIDAR_HORIZONTAL_FOV = 180.0       # 水平FOV (度)
LIDAR_VERTICAL_FOV = 30.0          # 垂直FOV (±15°)
LIDAR_LINES = 32
LIDAR_ACCURACY = 0.02              # 精度 (m)

# LiDAR安装
LIDAR_CONFIGS = [
    {"position": "front", "yaw": 0.0},     # 前方
    {"position": "rear", "yaw": 180.0},    # 后方
]

# ===================== 车辆状态向量 =====================
STATE_DIM = 6
STATE_RANGES = {
    "speed": (0.0, 200.0),           # km/h
    "accel_long": (-10.0, 10.0),     # m/s²
    "accel_lat": (-10.0, 10.0),      # m/s²
    "heading": (-3.14159, 3.14159),  # rad
    "target_dir_x": (-1.0, 1.0),
    "target_dir_y": (-1.0, 1.0),
}

# ===================== 训练参数 =====================
TRAIN_TOTAL_FRAMES_2D = 90_000      # 2D阶段总帧数
TRAIN_TOTAL_FRAMES_3D = 15_000      # 3D微调帧数上限

TRAIN_BATCH_SIZE = 4
TRAIN_GRADIENT_ACCUM = 4            # 梯度累积步数
TRAIN_EFFECTIVE_BATCH = 16          # 有效batch = 4 × 4

TRAIN_EPOCHS_2D = 80
TRAIN_EPOCHS_3D = 10

TRAIN_LR_2D = 3e-4
TRAIN_LR_3D = 1e-5

TRAIN_WARMUP_EPOCHS = 5
TRAIN_WEIGHT_DECAY = 5e-4  # 防过拟合 S1：1e-4 → 5e-4（配合 param group 分离，BN/bias 不衰减）
TRAIN_GRAD_CLIP_NORM = 1.0

TRAIN_RESOLUTION_LOW = (112, 112)   # epoch 1-50
TRAIN_RESOLUTION_HIGH = (224, 224)  # epoch 51-80

TRAIN_SPLIT_RATIO = 0.9             # 训练/验证 90/10

# 损失权重
LOSS_WEIGHTS = {
    "steer_weight": 1.0,
    "throttle_weight": 0.5,
    "brake_weight": 0.5,
}

# ===================== 数据增强 =====================
DATA_AUGMENTATION = {
    "brightness": {"range": 0.20, "prob": 0.50},
    "contrast": {"range": 0.15, "prob": 0.50},
    "gaussian_noise": {"sigma": 0.02, "prob": 0.30},
    "blur": {"kernel": 3, "prob": 0.20},
    "horizontal_flip": {"prob": 0.10},
    "lidar_noise": {"sigma": 0.05, "prob": 0.30},
    "lidar_dropout": {"rate": 0.10, "prob": 0.20},
}

# ===================== 专家控制器 =====================
EXPERT_PURE_PURSUIT = {
    "lookahead_min": 8.0,   # m
    "lookahead_max": 25.0,  # m
    "k_lookahead": 0.3,     # lookahead = k * speed
}

EXPERT_PID = {
    "Kp": 0.8,
    "Ki": 0.05,
    "Kd": 0.1,
}

EXPERT_CURVE_MU = 0.7       # 路面摩擦系数(干燥)

# ===================== 推理部署 =====================
INFERENCE_FPS_TARGET = 30
INFERENCE_INPUT_PRECISION = "FP16"

# ===================== 模型文件路径 =====================
MODEL_CHECKPOINT_DIR = ROOT_DIR / "checkpoints"
MODEL_REPVGG_PRETRAINED = MODELS_DIR / "repvgg_a0_pretrained.pth"  # RepVGG ImageNet 预训练（可选，train.py --pretrained 使用）

# ===================== 物理常量 =====================
G = 9.81  # 重力加速度 (m/s²)

# ===================== 阶段1 DAgger 噪声 =====================
DAGGER_NOISE_STEER = 0.05  # ±0.05 rad

# ===================== 阶段3偏离恢复 =====================
DRIFT_CONFIG = {
    "lateral_offset": 1.5,    # m
    "heading_offset": 15.0,   # 度
    "speed_excess": 0.20,     # 20%
}
