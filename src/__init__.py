"""
自动驾驶模拟系统 — 源代码包

运行时已切换至 C++ Route B sidecar，以下模块仅被训练层引用，标注 [TRAINING-ONLY]：

模块清单:
  config.py             全局配置常量
  cpp_bridge.py         [TRAINING-ONLY] C++ 核心桥接层封装（运行时由 C++ sidecar 直接调用）
  map_loader.py         [TRAINING-ONLY] 地图加载与空间查询（运行时由 C++ map_loader.h 取代）
  path_planner.py       [TRAINING-ONLY] 路径规划器 Dijkstra（运行时由 C++ path_planner.h 取代）
  sensors.py            [TRAINING-ONLY] 传感器模拟器（运行时由 C++ sensors.h 取代）
  expert_controller.py  [TRAINING-ONLY] 专家控制器 Pure Pursuit+PID（运行时由 C++ controller.h 取代）
  model.py              M9模型定义(RepVGG+PointNet+融合头)
  data_generator.py     DAgger训练数据生成
  dagger.py             DAgger 训练流程
  trainer.py            训练循环(AMP+梯度累积)
  train.py              训练入口

以下模块已删除并被 C++ Route B 取代，不再存在于本包:
  world.py / vehicle_ai.py / traffic_manager.py /
  scenario_generator.py / renderer.py / inference.py / map_cache.py
"""
