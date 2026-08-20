# [TRAINING-ONLY] 此文件仅用于离线训练，运行时不加载
"""
训练数据生成器 — DAgger 三阶段数据生成管线

DAgger（Dataset Aggregation）解决行为克隆的分布偏移问题：

阶段1（行为克隆预热，50K帧，2D投影）：
  - 专家控制器（Pure Pursuit + PID）独立驾驶
  - 加入噪声注入：给专家转向角加 ±0.05 随机噪声
  - 增强专家对噪声的鲁棒性

阶段2（DAgger 在线采集，20K帧，2D投影）：
  - 使用阶段1训练的模型驾驶
  - 每10帧专家判定偏差，超阈值帧用专家标签覆盖
  - 采集模型偏离时的状态 + 专家纠正标签

阶段3（偏离恢复专项，20K帧，2D投影）：
  - 主动制造偏离状态（偏中心±1.5m/航向±15°/超速20%）
  - 专家从偏离状态纠正回正常
  - 覆盖极端偏离场景

输出格式：HDF5 文件，每帧包含图像/点云/车辆状态/控制标签
"""

import gc
import h5py
import math
import time
import numpy as np
from pathlib import Path
from typing import Optional, Dict, List, Tuple
from tqdm import tqdm

from src.config import (
    DATA_DIR,
    EGO_VEHICLE, DAGGER_NOISE_STEER,
)
from src.sensors import SensorSuite, DataAugmenter
from src.expert_controller import ExpertController, generate_drift_state
from src.cpp_bridge import bike_step as _bike_step


# ==================== 数据生成器基类 ====================

class DataGenerator:
    """
    DAgger 三阶段训练数据生成器
    """

    def __init__(
        self,
        output_dir: Optional[Path] = None,
        seed: int = 42,
    ):
        self.output_dir = Path(output_dir) if output_dir else DATA_DIR / "training_samples"
        self.output_dir.mkdir(parents=True, exist_ok=True)

        self.seed = seed
        self.rng = np.random.RandomState(seed)

        # 传感器套件
        self.sensors = SensorSuite(seed=seed)

        # 专家控制器
        self.expert = ExpertController()

        # 物理量纲（修 S2：accel_cmd [-1,1] → m/s²）
        self.max_accel = float(EGO_VEHICLE["max_accel"])   # m/s²
        self.max_brake = float(EGO_VEHICLE["max_brake"])   # m/s²

        # 数据增强
        self.augmenter = DataAugmenter(seed=seed + 1000)

        # 统计
        self.stats = {
            "stage1_frames": 0,
            "stage2_frames": 0,
            "stage3_frames": 0,
            "expert_corrections": 0,
        }

    # ==================== 共享数据采集循环 ====================

    def _run_loop(
        self,
        stage_dir,
        target_frames: int,
        roads, buildings, world, traffic_manager,
        dt: float, save_every: int,
        control_fn,
        pbar_desc: str, stats_key: str, stage_prefix: str, stage_tag: str,
        ego_pos, ego_heading, ego_speed,
        enable_augment: bool = False,
        random_lookahead: bool = False,
        buffer: dict = None,
        file_idx: int = 0,
    ):
        """共享数据采集循环。control_fn 闭包注入控制信号（专家/模型+Dagger纠正/偏离恢复）。
        buffer/file_idx 可选传入以实现跨循环段的连续缓冲。"""
        if buffer is None:
            buffer = {
                "images": [], "point_clouds": [], "vehicle_states": [],
                "steer_labels": [], "throttle_labels": [], "brake_labels": [],
            }

        pbar = tqdm(total=target_frames, desc=pbar_desc)
        prev_accel = 0.0  # 缓存上一帧加速度，供传感器采集

        for frame in range(target_frames):
            if world is not None:
                world.update(ego_pos)
            if traffic_manager is not None:
                traffic_manager.update(ego_pos, ego_heading, ego_speed, dt)

            road_pts = self._get_road_center_points(ego_pos, roads)
            speed_limit = self._get_speed_limit(ego_pos, world)
            curvature = self.expert.get_road_curvature(ego_pos[:2], road_pts)

            front_dist, front_spd = None, None
            if traffic_manager is not None:
                front_dist, front_spd = self.expert.find_front_vehicle(
                    ego_pos, ego_heading, list(traffic_manager.vehicles.values()))

            # 传感器采集（先于控制：阶段2模型推理需要传感器数据）
            current_roads = roads if roads is not None else []
            current_buildings = buildings if buildings is not None else []
            current_vehicles = (
                list(traffic_manager.vehicles.values()) if traffic_manager else [])

            lookahead = self.rng.uniform(50, 100) if random_lookahead else 50
            target_pt = self._compute_target_point(ego_pos, road_pts, lookahead=lookahead)

            sensor_data = self.sensors.capture(
                ego_pos=ego_pos, ego_heading=ego_heading, ego_speed=ego_speed,
                ego_accel_long=prev_accel, ego_accel_lat=0.0,
                target_point=target_pt,
                roads=current_roads, buildings=current_buildings, vehicles=current_vehicles)

            # 控制信号（闭包注入阶段差异）
            steer, throttle, brake, steer_rad, accel_cmd = control_fn(
                frame, ego_pos, ego_heading, ego_speed, road_pts, speed_limit,
                curvature, front_dist, front_spd, dt, sensor_data)
            prev_accel = accel_cmd  # 缓存供下一帧传感器采集

            # 数据增强（仅阶段1）
            if enable_augment and self.rng.random() < 0.5:
                aug_imgs, aug_pc = self.augmenter.augment(
                    sensor_data["images"], sensor_data["point_clouds"])
            else:
                aug_imgs, aug_pc = sensor_data["images"], sensor_data["point_clouds"]

            buffer["images"].append(aug_imgs)
            buffer["point_clouds"].append(aug_pc)
            buffer["vehicle_states"].append(sensor_data["vehicle_state"])
            buffer["steer_labels"].append(steer)
            buffer["throttle_labels"].append(throttle)
            buffer["brake_labels"].append(brake)

            ego_pos, ego_heading, ego_speed = self._update_ego(
                ego_pos, ego_heading, ego_speed, steer_rad, accel_cmd, dt)

            if (frame + 1) % save_every == 0 or frame == target_frames - 1:
                filepath = stage_dir / f"{stage_prefix}_{file_idx:04d}.h5"
                self._save_hdf5(filepath, buffer, stage_tag)
                file_idx += 1
                for k in buffer:
                    buffer[k] = []
                gc.collect()

            pbar.update(1)
            self.stats[stats_key] += 1

        pbar.close()
        return ego_pos, ego_heading, ego_speed, file_idx

    # ==================== 阶段1：专家独驾 ====================

    def generate_stage1(
        self,
        target_frames: int = 50000,
        roads: List = None,
        buildings: List = None,
        world=None,
        traffic_manager=None,
        dt: float = 0.1,
        save_every: int = 1000,
        enable_noise: bool = True,
    ) -> str:
        """阶段1：专家独驾生成训练数据 + 噪声注入"""
        print(f"\n{'='*60}")
        print(f"DAgger 阶段1：行为克隆预热 | 目标 {target_frames} 帧")
        print(f"{'='*60}")

        stage_dir = self.output_dir / "stage1_bc"
        stage_dir.mkdir(parents=True, exist_ok=True)

        if enable_noise:
            self.expert.set_noise(True, DAGGER_NOISE_STEER)

        ego_pos, ego_heading, ego_speed = self._init_ego(roads)
        self.expert.reset()

        def control_fn(frame, ego_pos, ego_heading, ego_speed, road_pts, speed_limit,
                       curvature, front_dist, front_spd, dt, _sensor_data):
            steer, throttle, brake, info = self.expert.control(
                ego_pos=ego_pos, ego_heading=ego_heading, ego_speed=ego_speed,
                road_center_points=road_pts, speed_limit=speed_limit, dt=dt,
                road_curvature=curvature, front_vehicle_dist=front_dist,
                front_vehicle_speed=front_spd)
            return steer, throttle, brake, info["steer_rad"], self._accel_cmd_to_ms2(info["accel_cmd"])

        self._run_loop(stage_dir, target_frames, roads, buildings, world, traffic_manager,
                       dt, save_every, control_fn,
                       "Stage1 BC", "stage1_frames", "stage1_bc", "stage1",
                       ego_pos, ego_heading, ego_speed,
                       enable_augment=True, random_lookahead=True)

        print(f"阶段1完成: {self.stats['stage1_frames']} 帧 → {stage_dir}")
        return str(stage_dir)

    # ==================== 阶段2：DAgger 在线采集 ====================

    def generate_stage2(
        self,
        target_frames: int = 20000,
        model=None,
        roads: List = None,
        buildings: List = None,
        world=None,
        traffic_manager=None,
        dt: float = 0.1,
        correction_interval: int = 10,
        correction_threshold: float = 0.15,
        save_every: int = 1000,
    ) -> str:
        """阶段2：DAgger 在线采集 — 模型推理 + 每N帧专家判定，偏差超阈值则用专家标签覆盖"""
        print(f"\n{'='*60}")
        print(f"DAgger 阶段2：在线采集 | 目标 {target_frames} 帧")
        print(f"{'='*60}")

        stage_dir = self.output_dir / "stage2_dagger"
        stage_dir.mkdir(parents=True, exist_ok=True)

        if model is None:
            print("[警告] 未提供模型，回退到阶段1模式")
            return self.generate_stage1(
                target_frames, roads, buildings, world, traffic_manager, dt, save_every)

        import torch
        model.eval()
        self.expert.set_noise(False)
        self.expert.reset()

        ego_pos, ego_heading, ego_speed = self._init_ego(roads)
        corrections = 0

        def control_fn(frame, ego_pos, ego_heading, ego_speed, road_pts, speed_limit,
                       curvature, front_dist, front_spd, dt, sensor_data):
            nonlocal corrections

            device = next(model.parameters()).device
            with torch.no_grad():
                img_tensor = torch.from_numpy(sensor_data["images"]).to(device).unsqueeze(0)
                img_tensor = img_tensor.permute(0, 1, 4, 2, 3)
                pc_tensor = torch.from_numpy(sensor_data["point_clouds"]).to(device).unsqueeze(0)
                pc_tensor = pc_tensor[:, :, :, :3]
                state_tensor = torch.from_numpy(sensor_data["vehicle_state"]).to(device).unsqueeze(0)
                pred_steer, pred_throttle, pred_brake = model(img_tensor, pc_tensor, state_tensor)

            m_steer = pred_steer.item()
            m_throttle = pred_throttle.item()
            m_brake = pred_brake.item()

            if frame % correction_interval == 0:
                # 修量纲链：直接用 info["accel_cmd"]（PID 输出 [-1,1]），
                # 不再从 throttle-brake 反推（_accel_to_throttle_brake 是非线性映射，
                # 含 speed_ratio 衰减，反推会丢失量纲，导致 stage2 训练标签物理不自洽）
                e_steer, e_throttle, e_brake, e_info = self.expert.control(
                    ego_pos, ego_heading, ego_speed, road_pts, speed_limit, dt,
                    road_curvature=curvature, front_vehicle_dist=front_dist,
                    front_vehicle_speed=front_spd)
                if max(abs(m_steer - e_steer), abs(m_throttle - e_throttle),
                       abs(m_brake - e_brake)) > correction_threshold:
                    corrections += 1
                    s_rad = e_steer * EGO_VEHICLE["max_steer"]
                    a_cmd = self._accel_cmd_to_ms2(e_info["accel_cmd"])
                    return e_steer, e_throttle, e_brake, s_rad, a_cmd

            # 模型自驱动帧：模型只输出 throttle/brake，无 accel_cmd，
            # 近似反推（throttle-brake ∈ [-1,1] 与 PID 输出范围兼容）。
            # 这些帧的"标签"是模型自身预测（自蒸馏），非专家监督，量纲近似可接受。
            s_rad = m_steer * EGO_VEHICLE["max_steer"]
            a_cmd = self._accel_cmd_to_ms2(m_throttle - m_brake)
            return m_steer, m_throttle, m_brake, s_rad, a_cmd

        self._run_loop(stage_dir, target_frames, roads, buildings, world, traffic_manager,
                       dt, save_every, control_fn,
                       "Stage2 DAgger", "stage2_frames", "stage2_dagger", "stage2",
                       ego_pos, ego_heading, ego_speed,
                       enable_augment=False, random_lookahead=False)

        self.stats["expert_corrections"] = corrections
        print(f"阶段2完成: {self.stats['stage2_frames']} 帧, 专家纠正 {corrections} 次 → {stage_dir}")
        return str(stage_dir)

    # ==================== 阶段3：偏离恢复 ====================

    def generate_stage3(
        self,
        target_frames: int = 20000,
        roads: List = None,
        buildings: List = None,
        world=None,
        traffic_manager=None,
        dt: float = 0.1,
        recovery_steps: int = 20,
        save_every: int = 1000,
    ) -> str:
        """
        阶段3：偏离恢复专项训练

        主动制造偏离状态 + 专家纠正回正常

        target_frames: 目标帧数（默认20K）
        recovery_steps: 每次偏离恢复的帧数
        """
        print(f"\n{'='*60}")
        print(f"DAgger 阶段3：偏离恢复 | 目标 {target_frames} 帧")
        print(f"{'='*60}")

        stage_dir = self.output_dir / "stage3_recovery"
        stage_dir.mkdir(parents=True, exist_ok=True)

        self.expert.set_noise(False)
        self.expert.reset()

        buffer = {
            "images": [], "point_clouds": [], "vehicle_states": [],
            "steer_labels": [], "throttle_labels": [], "brake_labels": [],
        }

        file_idx = 0
        pbar = tqdm(total=target_frames, desc="Stage3 Recovery")

        frame = 0
        while frame < target_frames:
            # 正常驾驶一段
            ego_pos, ego_heading, ego_speed = self._init_ego(roads)
            self.expert.reset()

            # 正常驾驶 30 步建立状态
            for _ in range(30):
                if world is not None:
                    world.update(ego_pos)
                if traffic_manager is not None:
                    traffic_manager.update(ego_pos, ego_heading, ego_speed, dt)

                road_pts = self._get_road_center_points(ego_pos, roads)
                speed_limit = self._get_speed_limit(ego_pos, world)
                curvature = self.expert.get_road_curvature(ego_pos[:2], road_pts)

                _, _, _, info = self.expert.control(
                    ego_pos, ego_heading, ego_speed, road_pts, speed_limit, dt,
                    road_curvature=curvature,
                )

                ego_pos, ego_heading, ego_speed = self._update_ego(
                    ego_pos, ego_heading, ego_speed,
                    info["steer_rad"], self._accel_cmd_to_ms2(info["accel_cmd"]), dt,
                )

            # 制造偏离状态
            road_pts = self._get_road_center_points(ego_pos, roads)
            drift_pos, drift_heading, speed_factor = generate_drift_state(
                ego_pos, ego_heading, road_pts, self.rng
            )
            drift_speed = ego_speed * speed_factor

            # 从偏离状态开始恢复
            ego_pos = drift_pos
            ego_heading = drift_heading
            ego_speed = drift_speed
            self.expert.reset()

            for step in range(recovery_steps):
                if frame >= target_frames:
                    break

                if world is not None:
                    world.update(ego_pos)
                if traffic_manager is not None:
                    traffic_manager.update(ego_pos, ego_heading, ego_speed, dt)

                road_pts = self._get_road_center_points(ego_pos, roads)
                speed_limit = self._get_speed_limit(ego_pos, world)
                curvature = self.expert.get_road_curvature(ego_pos[:2], road_pts)

                # 专家控制（从偏离纠正）
                steer, throttle, brake, info = self.expert.control(
                    ego_pos, ego_heading, ego_speed, road_pts, speed_limit, dt,
                    road_curvature=curvature,
                )

                # 传感器采集
                current_roads = roads if roads is not None else []
                current_buildings = buildings if buildings is not None else []
                current_vehicles = (
                    list(traffic_manager.vehicles.values()) if traffic_manager else []
                )
                target_pt = self._compute_target_point(ego_pos, road_pts)

                sensor_data = self.sensors.capture(
                    ego_pos, ego_heading, ego_speed,
                    ego_accel_long=self._accel_cmd_to_ms2(info.get("accel_cmd", 0.0)), ego_accel_lat=0.0,
                    target_point=target_pt,
                    roads=current_roads, buildings=current_buildings,
                    vehicles=current_vehicles,
                )

                # 存入缓冲区
                buffer["images"].append(sensor_data["images"])
                buffer["point_clouds"].append(sensor_data["point_clouds"])
                buffer["vehicle_states"].append(sensor_data["vehicle_state"])
                buffer["steer_labels"].append(steer)
                buffer["throttle_labels"].append(throttle)
                buffer["brake_labels"].append(brake)

                # 更新自车
                ego_pos, ego_heading, ego_speed = self._update_ego(
                    ego_pos, ego_heading, ego_speed,
                    info["steer_rad"], self._accel_cmd_to_ms2(info["accel_cmd"]), dt,
                )

                frame += 1
                pbar.update(1)
                self.stats["stage3_frames"] += 1

                # 定期保存
                if frame % save_every == 0:
                    filepath = stage_dir / f"stage3_recovery_{file_idx:04d}.h5"
                    self._save_hdf5(filepath, buffer, "stage3")
                    file_idx += 1
                    for k in buffer:
                        buffer[k] = []
                    gc.collect()

        # 保存剩余
        if buffer["images"]:
            filepath = stage_dir / f"stage3_recovery_{file_idx:04d}.h5"
            self._save_hdf5(filepath, buffer, "stage3")
            file_idx += 1

        pbar.close()
        print(f"阶段3完成: {self.stats['stage3_frames']} 帧 → {stage_dir}")
        return str(stage_dir)

    # ==================== 完整管线 ====================

    def generate_all(
        self,
        roads: List = None,
        buildings: List = None,
        world=None,
        traffic_manager=None,
        model=None,
        stage1_frames: int = 50000,
        stage2_frames: int = 20000,
        stage3_frames: int = 20000,
    ) -> Dict[str, str]:
        """
        运行完整 DAgger 三阶段数据生成

        返回: {"stage1": path, "stage2": path, "stage3": path}
        """
        results = {}

        # 阶段1
        results["stage1"] = self.generate_stage1(
            target_frames=stage1_frames,
            roads=roads, buildings=buildings,
            world=world, traffic_manager=traffic_manager,
        )
        gc.collect()

        # 阶段2（需要阶段1训练的模型）
        results["stage2"] = self.generate_stage2(
            target_frames=stage2_frames,
            model=model,
            roads=roads, buildings=buildings,
            world=world, traffic_manager=traffic_manager,
        )
        gc.collect()

        # 阶段3
        results["stage3"] = self.generate_stage3(
            target_frames=stage3_frames,
            roads=roads, buildings=buildings,
            world=world, traffic_manager=traffic_manager,
        )

        return results

    # ==================== 工具方法 ====================

    def _init_ego(self, roads: List) -> Tuple[np.ndarray, float, float]:
        """初始化自车位置"""
        if roads and len(roads) > 0:
            road = roads[self.rng.randint(0, len(roads))]
            pts = getattr(road, 'center_points', None)
            if pts is not None and len(pts) > 0:
                idx = self.rng.randint(0, len(pts))
                pos = np.array([pts[idx, 0], pts[idx, 1], 0.0], dtype=np.float32)
                heading = 0.0 if idx == 0 else math.atan2(
                    pts[idx, 1] - pts[idx - 1, 1],
                    pts[idx, 0] - pts[idx - 1, 0],
                )
                speed = self.rng.uniform(20, 60)
                return pos, heading, speed

        return np.array([0.0, 0.0, 0.0], dtype=np.float32), 0.0, 40.0

    def _get_road_center_points(self, ego_pos: np.ndarray, roads: List) -> np.ndarray:
        """获取当前道路中心线（修 S7：原代码首次命中即 return，总返回第一条路）。
        现按"最近路点到自车"选最近路段。"""
        if roads:
            best_pts = None
            best_d2 = float("inf")
            ex, ey = float(ego_pos[0]), float(ego_pos[1])
            for road in roads:
                pts = getattr(road, 'center_points', None)
                if pts is None or len(pts) < 2:
                    continue
                arr = np.asarray(pts, dtype=np.float64)
                # 该路段所有点到自车的最小平方距离
                dx = arr[:, 0] - ex
                dy = arr[:, 1] - ey
                d2 = float((dx * dx + dy * dy).min())
                if d2 < best_d2:
                    best_d2 = d2
                    best_pts = pts
            if best_pts is not None:
                return best_pts
        # 默认：沿 x 轴直线
        return np.array([[ego_pos[0] + i * 5, ego_pos[1], 0.0] for i in range(-20, 60)])

    def _get_speed_limit(self, ego_pos: np.ndarray, world) -> float:
        """获取当前限速"""
        if world is not None:
            return world.get_speed_limit_at(ego_pos)
        return 60.0

    def _compute_target_point(
        self,
        ego_pos: np.ndarray,
        road_pts: np.ndarray,
        lookahead: float = 75.0,
    ) -> np.ndarray:
        """计算目标点（沿道路前方）"""
        if len(road_pts) < 2:
            return ego_pos[:2] + np.array([100.0, 0.0])

        pts_2d = road_pts[:, :2]
        dists = np.linalg.norm(pts_2d - ego_pos[:2], axis=1)
        nearest_idx = int(np.argmin(dists))

        for i in range(nearest_idx, len(pts_2d)):
            d = np.linalg.norm(pts_2d[i] - ego_pos[:2])
            if d >= lookahead:
                return pts_2d[i]

        return pts_2d[-1]

    def _accel_cmd_to_ms2(self, accel_cmd: float) -> float:
        """专家/模型 PID 输出 [-1,1] → 物理 m/s²（修 S2 量纲不匹配）。
        正值=加速（×max_accel），负值=制动（×max_brake）。"""
        a = float(accel_cmd)
        if a >= 0.0:
            return a * self.max_accel
        return a * self.max_brake

    def _update_ego(
        self,
        pos: np.ndarray,
        heading: float,
        speed: float,
        steer: float,
        accel: float,
        dt: float,
    ) -> Tuple[np.ndarray, float, float]:
        """更新自车状态（标准自行车模型，修 S6 零速转向 + S2 量纲）。
        走 cpp_bridge.bike_step：C++ 可用时零开销，否则纯 Python 等价回退。
        accel 必须是物理 m/s²（调用方用 _accel_cmd_to_ms2 转换）。"""
        return _bike_step(
            pos, heading, speed, steer, accel, dt,
            wheelbase=EGO_VEHICLE["wheelbase"],
            max_steer=EGO_VEHICLE["max_steer"],
            max_speed_kmh=EGO_VEHICLE["max_speed"],
        )

    def _save_hdf5(self, filepath: Path, buffer: dict, stage: str):
        """保存缓冲区到 HDF5 文件"""
        n = len(buffer["images"])
        if n == 0:
            return

        # 堆叠数组
        images = np.stack(buffer["images"])           # [N, 10, 224, 224, 3]
        point_clouds = np.stack(buffer["point_clouds"])  # [N, 2, M, 4]
        vehicle_states = np.stack(buffer["vehicle_states"])  # [N, 6]
        steer_labels = np.array(buffer["steer_labels"], dtype=np.float32).reshape(-1, 1)
        throttle_labels = np.array(buffer["throttle_labels"], dtype=np.float32).reshape(-1, 1)
        brake_labels = np.array(buffer["brake_labels"], dtype=np.float32).reshape(-1, 1)

        with h5py.File(filepath, "w") as f:
            f.create_dataset("images", data=images, compression="gzip", compression_opts=4)
            f.create_dataset("point_clouds", data=point_clouds, compression="gzip", compression_opts=4)
            f.create_dataset("vehicle_states", data=vehicle_states, compression="gzip", compression_opts=4)
            f.create_dataset("steer", data=steer_labels)
            f.create_dataset("throttle", data=throttle_labels)
            f.create_dataset("brake", data=brake_labels)
            f.attrs["stage"] = stage
            f.attrs["num_samples"] = n
            f.attrs["created_at"] = time.strftime("%Y-%m-%d %H:%M:%S")

        size_mb = filepath.stat().st_size / (1024 * 1024)
        print(f"  保存: {filepath.name} ({n} 帧, {size_mb:.1f} MB)")

    def get_stats(self) -> Dict:
        """获取统计数据"""
        return dict(self.stats)


# ==================== 数据加载器 ====================

class HDF5Dataset:
    """从 HDF5 文件加载训练数据的 PyTorch Dataset。

    修 M1：原 __getitem__ 每次调用都 h5py.File(open/close)，I/O 占训练
    时间大头。改为懒加载句柄缓存：每个文件只打开一次，per-worker 各自缓存
    （DataLoader fork 后子进程首次访问自动重开，避免跨进程句柄失效）。
    """

    def __init__(
        self,
        data_dirs: List[str],
        transform=None,
        augment: bool = False,
        seed: int = 42,
    ):
        self.data_dirs = [Path(d) for d in data_dirs]
        self.transform = transform
        self.augment = augment
        self.augmenter = DataAugmenter(seed=seed) if augment else None

        # 扫描所有 HDF5 文件
        self.files = []
        for d in self.data_dirs:
            if d.is_file() and d.suffix == ".h5":
                self.files.append(d)
            elif d.is_dir():
                self.files.extend(sorted(d.glob("*.h5")))

        self._handles: Dict[int, "h5py.File"] = {}   # file_idx → 句柄（懒加载）
        self._build_index()

    def _handle(self, file_idx: int):
        """懒加载文件句柄（DataLoader worker fork 后首次访问自动重开）。"""
        h = self._handles.get(file_idx)
        if h is None:
            h = h5py.File(self.files[file_idx], "r")
            self._handles[file_idx] = h
        return h

    def _build_index(self):
        """构建全局样本索引 (file_idx, sample_idx)"""
        self.index = []
        for file_idx, fpath in enumerate(self.files):
            with h5py.File(fpath, "r") as f:
                n = int(f.attrs.get("num_samples", len(f["steer"])))
            for i in range(n):
                self.index.append((file_idx, i))

    def __len__(self) -> int:
        return len(self.index)

    def __getitem__(self, idx: int) -> Dict[str, np.ndarray]:
        file_idx, sample_idx = self.index[idx]
        f = self._handle(file_idx)                   # 复用缓存句柄

        images = f["images"][sample_idx].astype(np.float32)          # [10, 224, 224, 3]
        point_clouds = f["point_clouds"][sample_idx].astype(np.float32)  # [2, N, 4]
        vehicle_state = f["vehicle_states"][sample_idx].astype(np.float32)  # [6]
        steer = f["steer"][sample_idx].astype(np.float32)            # [1]
        throttle = f["throttle"][sample_idx].astype(np.float32)      # [1]
        brake = f["brake"][sample_idx].astype(np.float32)           # [1]

        # 数据增强
        if self.augment and self.augmenter:
            images, point_clouds = self.augmenter.augment(images, point_clouds)

        # 转换为训练格式
        # 图像: [10, 3, 224, 224] (CHW)
        images = np.transpose(images, (0, 3, 1, 2))
        # 点云: [2, N, 3] (只取 xyz)
        point_clouds = point_clouds[:, :, :3]

        return {
            "images": images,
            "point_clouds": point_clouds,
            "vehicle_state": vehicle_state,
            "steer": steer,
            "throttle": throttle,
            "brake": brake,
        }

    def __del__(self):
        for h in self._handles.values():
            try:
                h.close()
            except Exception:
                pass
