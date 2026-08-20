# [TRAINING-ONLY] 运行时已被 C++ controller.h 取代；仅被训练层（data_generator 等）引用，勿删。
"""
专家控制器 — Pure Pursuit（横向）+ PID（纵向）
为 DAgger 训练生成专家驾驶标签（转向角、油门、刹车）

Pure Pursuit 横向控制:
  δ = arctan(2·L·sin(α) / l_d)
  L = 轴距, α = 航向与预瞄点的夹角, l_d = 预瞄距离

弯道限速:
  v_safe = √(μ·g·r)

PID 纵向控制:
  u(t) = Kp·e + Ki·∫e dt + Kd·de/dt
  速度误差 e = v_target - v_current
"""

import math
import numpy as np
from typing import Optional, Tuple, List

from src.config import (
    EXPERT_PURE_PURSUIT, EXPERT_PID, EXPERT_CURVE_MU, G,
    EGO_VEHICLE, DAGGER_NOISE_STEER, DRIFT_CONFIG,
)


# ==================== PID 控制器 ====================

class PIDController:
    """
    离散 PID 控制器
    用于纵向速度控制（输出油门/刹车）
    """

    def __init__(
        self,
        Kp: float = 0.8,
        Ki: float = 0.05,
        Kd: float = 0.1,
        output_min: float = -1.0,
        output_max: float = 1.0,
        integral_clamp: float = 0.5,
    ):
        self.Kp = Kp
        self.Ki = Ki
        self.Kd = Kd
        self.output_min = output_min
        self.output_max = output_max
        self.integral_clamp = integral_clamp

        self._integral = 0.0
        self._prev_error = 0.0
        self._first_call = True

    def reset(self):
        """重置 PID 状态"""
        self._integral = 0.0
        self._prev_error = 0.0
        self._first_call = True

    def update(self, target: float, current: float, dt: float) -> float:
        """
        计算控制输出

        target: 目标值（如目标速度 km/h）
        current: 当前值（如当前速度 km/h）
        dt: 时间步长 (s)

        返回: 控制输出 [-1, 1]，正值=油门，负值=刹车
        """
        error = target - current

        if self._first_call:
            self._first_call = False
            self._prev_error = error
            derivative = 0.0
        else:
            derivative = (error - self._prev_error) / max(dt, 1e-6)

        # 积分项 + 钳制防饱和
        self._integral += error * dt
        self._integral = np.clip(self._integral, -self.integral_clamp, self.integral_clamp)

        # PID 输出
        output = (
            self.Kp * error
            + self.Ki * self._integral
            + self.Kd * derivative
        )

        self._prev_error = error

        # 钳制输出
        return np.clip(output, self.output_min, self.output_max)


# ==================== Pure Pursuit 横向控制器 ====================

class PurePursuitController:
    """
    Pure Pursuit 路径跟踪控制器
    根据预瞄点计算转向角
    """

    def __init__(
        self,
        wheelbase: float = 2.7,
        lookahead_min: float = 8.0,
        lookahead_max: float = 25.0,
        k_lookahead: float = 0.3,
        max_steer: float = 0.6,
    ):
        self.wheelbase = wheelbase
        self.lookahead_min = lookahead_min
        self.lookahead_max = lookahead_max
        self.k_lookahead = k_lookahead
        self.max_steer = max_steer

    def compute_lookahead_distance(self, speed: float) -> float:
        """
        根据速度计算预瞄距离
        l_d = k_lookahead * speed
        """
        l_d = self.k_lookahead * speed
        return np.clip(l_d, self.lookahead_min, self.lookahead_max)

    def find_lookahead_point(
        self,
        ego_pos: np.ndarray,
        road_center_points: np.ndarray,
        lookahead_distance: float,
    ) -> Optional[np.ndarray]:
        """
        在道路中心线上查找预瞄点

        ego_pos: [x, y] 自车位置
        road_center_points: [N, 2] 或 [N, 3] 道路中心线
        lookahead_distance: 预瞄距离

        返回: 预瞄点 [x, y] 或 None
        """
        if len(road_center_points) < 2:
            return None

        # 确保是 2D 坐标
        pts = road_center_points[:, :2]

        # 找到最近点
        dists = np.linalg.norm(pts - ego_pos[:2], axis=1)
        nearest_idx = int(np.argmin(dists))

        # 从最近点向前搜索，找到第一个距离 ≥ lookahead 的点
        for i in range(nearest_idx, len(pts)):
            d = np.linalg.norm(pts[i] - ego_pos[:2])
            if d >= lookahead_distance:
                # 在最近点和当前点之间插值
                if i > nearest_idx:
                    d_prev = np.linalg.norm(pts[i - 1] - ego_pos[:2])
                    if d_prev < lookahead_distance and d > d_prev:
                        frac = (lookahead_distance - d_prev) / (d - d_prev)
                        interp_pt = pts[i - 1] + frac * (pts[i] - pts[i - 1])
                        return interp_pt
                return pts[i]

        # 如果不够，返回最远点
        return pts[-1]

    def compute_steer(
        self,
        ego_pos: np.ndarray,
        ego_heading: float,
        lookahead_point: np.ndarray,
    ) -> float:
        """
        计算转向角

        ego_pos: [x, y]
        ego_heading: 航向角 (rad)
        lookahead_point: [x, y] 预瞄点

        返回: 转向角 (rad)，范围 [-max_steer, max_steer]
        """
        # 预瞄点方向
        dx = lookahead_point[0] - ego_pos[0]
        dy = lookahead_point[1] - ego_pos[1]
        l_d = math.sqrt(dx * dx + dy * dy)

        if l_d < 0.01:
            return 0.0

        # 预瞄点与航向的夹角 α
        target_heading = math.atan2(dy, dx)
        alpha = target_heading - ego_heading

        # 角度归一化到 [-π, π]
        while alpha > math.pi:
            alpha -= 2 * math.pi
        while alpha < -math.pi:
            alpha += 2 * math.pi

        # 限制目标角偏差：|α| > π/2 说明目标在车后方，
        # 不限制会导致车辆调头转圈。限制到 π/2 让车以最大转向角掉头而非原地转
        if alpha > math.pi / 2:
            alpha = math.pi / 2
        elif alpha < -math.pi / 2:
            alpha = -math.pi / 2

        # Pure Pursuit 公式: δ = arctan(2·L·sin(α) / l_d)
        steer = math.atan2(2.0 * self.wheelbase * math.sin(alpha), l_d)

        return np.clip(steer, -self.max_steer, self.max_steer)

    # ==================== 一步聚合：预瞄 + 转向（供 ExpertController.control 调用） ====================
    def compute(self, ego_pos, ego_heading, ego_speed, road_center_points):
        """根据速度选预瞄距离 → 找预瞄点 → 算转向角。

        返回 (steer_rad, lookahead_pt)；无预瞄点时返回 (0.0, None)。
        """
        l_d = self.compute_lookahead_distance(ego_speed)
        lp = self.find_lookahead_point(ego_pos, road_center_points, l_d)
        if lp is None:
            return 0.0, None
        steer = self.compute_steer(ego_pos, ego_heading, lp)
        return float(steer), lp


    # ==================== 弯道限速 ====================

def compute_curve_safe_speed(
    curvature: float,
    mu: float = EXPERT_CURVE_MU,
    min_speed: float = 10.0,
) -> float:
    """
    计算弯道安全速度

    v_safe = √(μ·g·r)
    curvature: 曲率 (1/m)
    mu: 路面摩擦系数
    min_speed: 最低速度 (km/h)

    返回: 安全速度 (km/h)
    """
    if abs(curvature) < 1e-6:
        return float("inf")

    radius = 1.0 / abs(curvature)
    v_safe_ms = math.sqrt(mu * G * radius)   # m/s
    v_safe_kmh = v_safe_ms * 3.6             # km/h

    return max(v_safe_kmh, min_speed)


# ==================== 完整专家控制器 ====================

class ExpertController:
    """
    专家控制器 = Pure Pursuit（横向）+ PID（纵向）+ 弯道限速
    为 DAgger 训练生成专家标签

    输出：
    - steer: 转向角（归一化到 [-1, 1]）
    - throttle: 油门（归一化到 [0, 1]）
    - brake: 刹车（归一化到 [0, 1]）
    """

    def __init__(
        self,
        pure_pursuit_cfg: dict = None,
        pid_cfg: dict = None,
    ):
        pp_cfg = pure_pursuit_cfg or EXPERT_PURE_PURSUIT
        pid_cfg = pid_cfg or EXPERT_PID

        self.pure_pursuit = PurePursuitController(
            wheelbase=EGO_VEHICLE["wheelbase"],
            lookahead_min=pp_cfg["lookahead_min"],
            lookahead_max=pp_cfg["lookahead_max"],
            k_lookahead=pp_cfg["k_lookahead"],
            max_steer=EGO_VEHICLE["max_steer"],
        )

        self.pid = PIDController(
            Kp=pid_cfg["Kp"],
            Ki=pid_cfg["Ki"],
            Kd=pid_cfg["Kd"],
        )

        self.max_speed = EGO_VEHICLE["max_speed"]
        self.max_accel = EGO_VEHICLE["max_accel"]
        self.max_brake = EGO_VEHICLE["max_brake"]
        self.max_steer = EGO_VEHICLE["max_steer"]

        # 噪声注入（DAgger 阶段1）
        self.noise_std_steer = DAGGER_NOISE_STEER
        self.inject_noise = False

    def reset(self):
        """重置控制器状态"""
        self.pid.reset()

    def set_noise(self, enable: bool = True, std: float = None):
        """启用/禁用转向噪声注入"""
        self.inject_noise = enable
        if std is not None:
            self.noise_std_steer = std

    def compute_target_speed(
        self,
        speed_limit: float,
        road_curvature: Optional[float],
        front_vehicle_dist: Optional[float],
        front_vehicle_speed: Optional[float],
    ) -> float:
        """
        计算目标速度：限速、弯道限速、前车跟车的最小值

        speed_limit: 道路限速 (km/h)
        road_curvature: 当前道路曲率 (1/m)
        front_vehicle_dist: 前车距离 (m)，None=无前车
        front_vehicle_speed: 前车速度 (km/h)

        返回: 目标速度 (km/h)
        """
        targets = [speed_limit]

        # 弯道限速
        if road_curvature is not None:
            curve_speed = compute_curve_safe_speed(road_curvature)
            targets.append(curve_speed)

        # 前车跟车（2秒时距）+ 安全距离
        if front_vehicle_dist is not None and front_vehicle_speed is not None:
            # 基于2秒安全时距计算跟车目标速度
            safe_dist = max(5.0, front_vehicle_speed / 3.6 * 2.0)  # 2s时距 → 米
            if front_vehicle_dist < safe_dist:
                follow_speed = front_vehicle_speed * (front_vehicle_dist / safe_dist)
                targets.append(follow_speed)

        return min(targets)

    def control(
        self,
        ego_pos: np.ndarray,
        ego_heading: float,
        ego_speed: float,
        road_center_points: np.ndarray,
        speed_limit: float,
        dt: float,
        road_curvature: Optional[float] = None,
        front_vehicle_dist: Optional[float] = None,
        front_vehicle_speed: Optional[float] = None,
    ) -> Tuple[float, float, float, dict]:
        """
        计算专家控制指令

        ego_pos: [x, y, z] 自车位置
        ego_heading: 航向角 (rad)
        ego_speed: 当前速度 (km/h)
        road_center_points: [N, 3] 道路中心线
        speed_limit: 当前路段限速 (km/h)
        dt: 时间步长 (s)
        road_curvature: 道路曲率
        front_vehicle_dist: 到前车距离
        front_vehicle_speed: 前车速度

        返回: (steer, throttle, brake, debug_info)
        steer: 归一化 [-1, 1]
        throttle: 归一化 [0, 1]
        brake: 归一化 [0, 1]
        """
        # 1. 横向控制：Pure Pursuit
        steer_rad, lookahead_pt = self.pure_pursuit.compute(
            ego_pos[:2], ego_heading, ego_speed, road_center_points,
        )

        # 噪声注入
        if self.inject_noise:
            noise = np.random.normal(0, self.noise_std_steer)
            steer_rad += noise
            steer_rad = np.clip(steer_rad, -self.max_steer, self.max_steer)

        # 2. 目标速度计算
        target_speed = self.compute_target_speed(
            speed_limit, road_curvature, front_vehicle_dist, front_vehicle_speed,
        )

        # 3. 纵向控制：PID
        accel_cmd = self.pid.update(target_speed, ego_speed, dt)

        # 4. 加速度 → 油门/刹车
        throttle, brake = self._accel_to_throttle_brake(accel_cmd, ego_speed)

        # 5. 转向归一化 → [-1, 1]
        steer = np.clip(steer_rad / self.max_steer, -1.0, 1.0)

        debug_info = {
            "steer_rad": steer_rad,
            "target_speed": target_speed,
            "accel_cmd": accel_cmd,
            "lookahead_pt": lookahead_pt,
        }

        return steer, throttle, brake, debug_info

    def _accel_to_throttle_brake(
        self, accel_cmd: float, current_speed: float,
    ) -> Tuple[float, float]:
        """
        将 PID 输出的加速度命令转换为油门/刹车信号

        accel_cmd: PID 输出 [-1, 1]，正=加速，负=减速
        current_speed: 当前速度 (km/h)

        返回: (throttle [0,1], brake [0,1])
        """
        if accel_cmd >= 0:
            # 加速 → 油门
            throttle = min(accel_cmd, 1.0)
            brake = 0.0

            # 速度越高油门效率越低（非线性映射）
            speed_ratio = current_speed / max(self.max_speed, 1.0)
            throttle = throttle * (1.0 - 0.5 * speed_ratio)

        else:
            # 减速 → 刹车
            throttle = 0.0
            brake = min(abs(accel_cmd), 1.0)

        return throttle, brake

    # ==================== 高级感知辅助 ====================

    def find_front_vehicle(
        self,
        ego_pos: np.ndarray,
        ego_heading: float,
        vehicles: List,
        max_lookahead: float = 150.0,
    ) -> Tuple[Optional[float], Optional[float]]:
        """
        查找自车前方最近的车辆

        vehicles: TrafficVehicle 列表

        返回: (距离, 速度) 或 (None, None)
        """
        best_dist = max_lookahead
        best_speed = None

        for veh in vehicles:
            state = getattr(veh, 'state', None)
            if state is None:
                continue

            dx = state.x - ego_pos[0]
            dy = state.y - ego_pos[1]
            dist = math.sqrt(dx * dx + dy * dy)

            if dist >= best_dist:
                continue

            # 投影到自车前方
            proj = dx * math.cos(ego_heading) + dy * math.sin(ego_heading)
            if proj <= 0:
                continue  # 在后方

            # 横向距离检查（同车道 ±3m）
            lateral = abs(-dx * math.sin(ego_heading) + dy * math.cos(ego_heading))
            if lateral > 3.0:
                continue

            best_dist = dist
            best_speed = state.speed

        if best_speed is not None:
            return best_dist, best_speed
        return None, None

    def get_road_curvature(
        self,
        ego_pos: np.ndarray,
        road_center_points: np.ndarray,
        lookahead: float = 20.0,
    ) -> Optional[float]:
        """
        估算自车前方道路曲率
        使用三点圆法

        ego_pos: [x, y] 或 [x, y, z]
        road_center_points: [N, 3]
        lookahead: 前方采样距离

        返回: 曲率 (1/m)
        """
        if len(road_center_points) < 3:
            return None

        pts = road_center_points[:, :2]

        # 找到三个采样点：最近点、中点、远点
        dists = np.linalg.norm(pts - ego_pos[:2], axis=1)
        nearest_idx = int(np.argmin(dists))

        def find_point_at_dist(start_idx: int, target_dist: float) -> int:
            for i in range(start_idx, len(pts)):
                d = np.linalg.norm(pts[i] - ego_pos[:2])
                if d >= target_dist:
                    return i
            return min(start_idx, len(pts) - 1)

        idx_near = nearest_idx
        idx_mid = find_point_at_dist(nearest_idx, lookahead / 2)
        idx_far = find_point_at_dist(nearest_idx, lookahead)

        # 三点圆法计算曲率: κ = 1/R = 4*面积/(边长a*边长b*边长c)
        a = pts[idx_near]
        b = pts[idx_mid]
        c = pts[idx_far]

        ab = np.linalg.norm(b - a)
        bc = np.linalg.norm(c - b)
        ca = np.linalg.norm(a - c)

        if ab < 1e-6 or bc < 1e-6 or ca < 1e-6:
            return 0.0

        # 海伦公式求面积
        s = (ab + bc + ca) / 2
        area = math.sqrt(max(0, s * (s - ab) * (s - bc) * (s - ca)))

        if area < 1e-6:
            return 0.0

        curvature = 4 * area / (ab * bc * ca)
        return curvature


# ==================== 偏离状态生成 ====================

def generate_drift_state(
    ego_pos: np.ndarray,
    ego_heading: float,
    road_center_points: np.ndarray,
    rng: np.random.RandomState = None,
) -> Tuple[np.ndarray, float, float]:
    """
    生成 DAgger 阶段3 的偏离状态

    ego_pos: 当前自车位置 [x, y, z]
    ego_heading: 当前航向
    road_center_points: [N, 3] 道路中心线

    返回: (drift_pos, drift_heading, drift_speed_factor)
    """
    if rng is None:
        rng = np.random.RandomState()

    cfg = DRIFT_CONFIG

    # 横向偏移 ±1.5m
    lateral_offset = rng.uniform(-cfg["lateral_offset"], cfg["lateral_offset"])

    # 沿道路垂直方向偏移
    perp_dir_x = -math.sin(ego_heading)
    perp_dir_y = math.cos(ego_heading)

    drift_pos = ego_pos.copy()
    drift_pos[0] += lateral_offset * perp_dir_x
    drift_pos[1] += lateral_offset * perp_dir_y

    # 航向偏移 ±15°
    heading_offset = math.radians(rng.uniform(-cfg["heading_offset"], cfg["heading_offset"]))
    drift_heading = ego_heading + heading_offset

    # 速度偏移因子
    speed_factor = 1.0 + rng.uniform(-cfg["speed_excess"], cfg["speed_excess"])
    speed_factor = max(0.5, min(speed_factor, 1.3))

    return drift_pos, drift_heading, speed_factor
