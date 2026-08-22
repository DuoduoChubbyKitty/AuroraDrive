# 自动驾驶技术研究进度索引

> 目标：累计 5000 次工具调用深度研究，产出白皮书并优化 AuroraDrive
> 机制：子代理直接 Write 磁盘，主代理只读索引恢复进度
> **文件夹结构**：所有研究文件夹直接嵌套在「自动驾驶系统」下，只嵌套一层

## 总体进度

- 已完成章节: 35
- 累计调用次数: 约 1900
- 累计字数: 约 100 万字（35 文件 × 平均 3 万字）

## 文件夹结构

```
自动驾驶系统/
├── Apollo研究/         (30 章, 约 1600 次调用) ← 已完成
├── OpenPilot研究/      (30 章, 约 1500 次调用) ← 进行中（已完成 5 章）
├── UniAD研究/          (1 章, 30 次调用) ← 待开始
├── BEVFormer研究/      (1 章, 30 次调用) ← 待开始
├── NVIDIA研究/         (10 章, 500 次调用) ← 待开始
├── ROS2生态研究/       (10 章, 500 次调用) ← 待开始
├── 纯规则研究/         (10 章, 500 次调用) ← 待开始
└── 研究索引/           (本文件)
```

## Apollo研究 (已完成 30/30 章)

### SR 界面部分
- [x] 01a_dreamview_pipeline.md — Dreamview 渲染管线
- [x] 01b_lane_rendering.md — 车道线渲染
- [x] 01c_road_labels.md — 路名标注与 POI
- [x] 01d_3d_scene.md — 3D 场景元素
- [x] 01e_sr_comparison.md — 小鹏/理想/特斯拉/华为/小米 SR 对比

### 感知部分
- [x] 01f_perception_overview.md — 感知 8.0/9.0/10.0 演进
- [x] 01g_perception_bev.md — Apollo-Lite BEV 感知
- [x] 01h_perception_lidar.md — LiDAR 检测
- [x] 01i_perception_camera.md — 相机检测
- [x] 01j_perception_fusion.md — 多模态融合

### 规划部分
- [x] 01k_planning_overview.md — 规划架构
- [x] 01l_planning_em_planner.md — EM Planner
- [x] 01m_planning_lattice.md — Lattice Planner
- [x] 01n_planning_open_space.md — Open Space Planner
- [x] 01o_planning_scenario.md — Scenario/Stage/Task
- [x] 01p_planning_ref_line.md — Reference Line Provider
- [x] 01q_planning_speed.md — 速度规划

### 控制部分
- [x] 01r_control_mpc.md — MPC Controller
- [x] 01s_control_lqr.md — LQR Controller
- [x] 01t_control_pid.md — PID + 标定表
- [x] 01u_control_vehicle_dyn.md — 车辆动力学 + CAN

### 地图与导航部分
- [x] 01v_hdmap_format.md — HD Map 格式
- [x] 01w_hdmap_engine.md — Map Engine + ROI
- [x] 01x_routing.md — Routing
- [x] 01y_cyberrt.md — CyberRT
- [x] 01z_lane_level_nav.md — 车道级导航

### Apollo 版本演进
- [x] 02a_hdmap_live.md — Live Map
- [x] 02b_dreamview_plus.md — Dreamview Plus
- [x] 02c_adfm_apollo10.md — ADFM 大模型
- [x] 02d_apollo_summary.md — Apollo 全栈总结

## OpenPilot研究 (已完成 5/30 章)

### 模型架构部分
- [x] 02e_supercombo_history.md — 模型演进历史
- [x] 02f_supercombo_arch.md — supercombo 网络结构
- [x] 02g_supercombo_heads.md — 多任务 Head 详解
- [x] 02h_training_data.md — 训练数据闭环
- [x] 02i_inference_onnx.md — ONNX/CoreML/SNPE 推理

### 待完成章节
- [ ] 02j_output_decode.md — Plan/Lane/Lead 输出解码
- [ ] 02k_v9_v10.md — v9/v10/DriveSeg 最新演进
- [ ] 02l_controlsd.md — controlsd 100Hz 控制环
- [ ] 02m_lateral_mpc.md — 横向 MPC
- [ ] 02n_longitudinal_mpc.md — 纵向 MPC
- [ ] 02o_lateral_planner.md — LateralPlanner
- [ ] 02p_long_planner.md — LongitudinalPlanner
- [ ] 02q_car_interface.md — CarInterface 适配器
- [ ] 02r_car_controller.md — CarController CAN 帧
- [ ] 02s_safety_model.md — 安全机制
- [ ] 02t_driver_monitor.md — DMS 驾驶员监控
- [ ] 02u_onroad_ui.md — Onroad UI 架构
- [ ] 02v_lane_projection.md — lane_lines 反向投射
- [ ] 02w_lead_box.md — Lead Vehicle 3D Box
- [ ] 02x_path_render.md — Path 路径渲染
- [ ] 02y_panda_hardware.md — panda 硬件
- [ ] 02z_panda_safety.md — panda 安全模型
- [ ] 03a_panda_dbc.md — DBC 文件解析
- [ ] 03b_panda_fingerprint.md — 车辆识别
- [ ] 03c_iso26262.md — ISO 26262 安全设计
- [ ] 03d_comma_connect.md — Comma Connect 数据闭环
- [ ] 03e_data_labeling.md — 数据标注平台
- [ ] 03f_ota.md — OTA 更新机制
- [ ] 03g_comma_3x.md — Comma 3X/4 硬件安全
- [ ] 03h_openpilot_summary.md — OpenPilot 全栈总结

## UniAD研究 (待开始 0/1 章)
- [ ] uniad_paper.md — UniAD 论文详解（30 次调用）

## BEVFormer研究 (待开始 0/1 章)
- [ ] bevformer_paper.md — BEVFormer v1/v2 详解（30 次调用）

## NVIDIA研究 (待开始 0/10 章)
- [ ] 01_alpamayo_r1.md — Alpamayo-R1 VLA 模型
- [ ] 02_alpamayo_training.md — 三阶段训练
- [ ] 03_driveos.md — DriveOS 安全架构
- [ ] 04_hyperion9.md — Hyperion 9 平台
- [ ] 05_tensorrt.md — TensorRT 推理优化
- [ ] 06_nvidia_safety.md — NVIDIA 安全设计
- [ ] 07_cosmos_reason.md — Cosmos-Reason VLM
- [ ] 08_nv_planning.md — NVIDIA 规划方案
- [ ] 09_nv_control.md — NVIDIA 控制方案
- [ ] 10_nv_summary.md — NVIDIA 全栈总结

## ROS2生态研究 (待开始 0/10 章)
- [ ] 01_autoware.md — Autoware 全栈
- [ ] 02_autoware_planning.md — Autoware 规划
- [ ] 03_autoware_control.md — Autoware 控制
- [ ] 04_dds_fastrtps.md — DDS/FastRTPS
- [ ] 05_ros2_middleware.md — ROS2 middleware
- [ ] 06_apollo_ros2.md — Apollo ROS2 适配
- [ ] 07_apilot_ros2.md — apollo.launcher
- [ ] 08_autoware_universe.md — Autoware.Universe
- [ ] 09_ros2_safety.md — ROS2 安全机制
- [ ] 10_ros2_summary.md — ROS2 全栈总结

## 纯规则研究 (待开始 0/10 章)
- [ ] 01_mobileye_rss.md — Mobileye RSS
- [ ] 02_apollo_rule_planner.md — Apollo rule-based planner
- [ ] 03_nv_drivos_safety.md — DriveOS safety
- [ ] 04_formal_verification.md — 形式化验证
- [ ] 05_cbmc.md — CBMC 模型检查
- [ ] 06_safety_envelope.md — Safety Envelope 设计
- [ ] 07_fallback_detector.md — Fallback Detector 设计
- [ ] 08_emergency_stop.md — Emergency Stop 策略
- [ ] 09_rule_based_design.md — 纯规则自动驾驶设计
- [ ] 10_rule_based_summary.md — 纯规则总结

## 汇总阶段
- [ ] autopilot_whitepaper.md — 最终白皮书
- [ ] project_understanding.md — 项目理解文档

## 执行约定

1. 子代理内部执行 30-50 次 WebSearch/WebFetch
2. 子代理**自己** Write 到目标 md 文件（直接放在对应主题文件夹下）
3. 子代理只返回主代理一句话："已完成 XX, 字数 N"
4. 主代理只维护本索引文件（追加完成标记）
5. 用户发"继续"时，主代理读本索引找下一个未完成章节
6. 全部完成后，主代理 Read 所有 md 汇总成白皮书
