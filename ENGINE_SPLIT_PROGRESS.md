# AuroraDrive 引擎拆分进度

> 规则：每次续做先读本文件；每步完成追加一行；旧内容永不删除。

- 最后更新：2026-09-11 13:20
- 当前步骤：3/5 完成
- 上一步 commit：2805b0c
- 阻塞项：无
- 下一步要做：步骤4 UI 侧失联显示（引擎模式状态指示）+ 三场景复测 → 步骤5 清理 launchd Agent 与验收

## 已完成
- 步骤0 存档：✅ commit 0d5fffb
- 步骤1 TCC 继承实测：✅ 2026-09-10 23:40 用户终端实测 ax=true screen=true
- 步骤2 引擎子进程骨架：✅ commit a3ab013
- 步骤3 UI 接线：✅ commit 2805b0c
  - 新增 Sources/AuroraDrive/EngineClient.swift（启动探测/spawn/重连 + 共享内存读帧 + socket 命令 + 心跳接收）
  - AuroraDriveApp.swift：AppDelegate 启动调 EngineClient.shared.startup()；applicationWillTerminate → sendByeSync()；DriveState 加 remoteDetections/effectiveDetections + tickEngineMode()；startDriving/stopDriving 引擎模式分支；ObstacleOverlay 改用 effectiveDetections
  - 实测：UI 自动连接已有引擎（不重复 spawn）；kill -9 UI → 引擎 3 秒重连窗口后 parking 且释放按键、引擎存活；UI 重开自动重连；连续启动 3 个 UI 引擎数恒为 1（单例正确）；shm 重复映射 bug 已修
  - UI 侧日志落盘 ~/Library/Logs/AuroraEngineClient.log
- 前置：launchd 方案否决；已装 LaunchAgent（com.aurora.drive.agent）待步骤5 清理

## 时间线
- 2026-09-11 13:16 步骤3 联调：UI 自动连接 ✅（引擎日志 "UI 已连接" + shm 72MB 映射）
- 2026-09-11 13:18 场景3 通过：kill -9 UI → 3 秒窗口 → "UI died, parking" + 释放按键，引擎存活 ✅
- 2026-09-11 13:18 场景4 通过：UI 重开自动重连；3 个 UI 并发引擎数仍为 1 ✅
- 2026-09-11 13:20 步骤3 commit 2805b0c
