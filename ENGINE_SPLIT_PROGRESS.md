# AuroraDrive 引擎拆分进度

> 规则：每次续做先读本文件；每步完成追加一行；旧内容永不删除。

- 最后更新：2026-09-11 13:00
- 当前步骤：2/5 完成
- 上一步 commit：a3ab013
- 阻塞项：无
- 下一步要做：步骤3 UI 接线（applicationDidFinishLaunching 探测 socket → 已有健康引擎直接连，没有则 spawn；ContentView 改 socket 命令 + 共享内存画板）

## 已完成
- 步骤0 存档：✅ commit 0d5fffb（ENGINE_SPLIT_GUIDE.md + 本进度文件，仅本地）
- 步骤1 TCC 继承实测：✅ 2026-09-10 23:40 用户终端实测 `./AuroraDriveUI --tcc-selftest` → ax=true screen=true
- 步骤2 引擎子进程骨架：✅ commit a3ab013
  - 新增 Sources/AuroraDrive/EngineMain.swift（flock单例 + TCC自检 fail-fast + beginActivity + socket + 共享内存 + DriveState 闭环 + 30Hz tick + 心跳 + 看门狗 + SIGTERM/SIGINT 安全退出）
  - @main 移到 AuroraDriveLauncher（--engine 分流，SwiftUI 结构原样保留）
  - Package.swift 增加 EngineMain.swift
  - AI 沙箱验证结果：编译通过；ax=false 环境 fail-fast 正确；诊断旁路下 socket/shm/DriveState/30Hz发布(seq=151/5s)全通；单例锁生效；ping/pong 正常；bye 语义正确（引擎继续）；异常断开 3 秒窗口停车（看门狗提前工作）；SIGTERM 释放按键 + socket 清理；UI 模式入口未破坏
  - 待用户环境验证：真实 TCC（ax=true）下 --engine 完整启动（AI 环境 ax=false）
- 前置：launchd 方案否决（实测 ax=false screen=false）；已装 LaunchAgent（com.aurora.drive.agent）待步骤5 清理

## 时间线
- 2026-09-11 步骤0 开始：创建进度文件，准备本地存档 commit（禁止 push）
- 2026-09-11 12:55 步骤2 冒烟测试：fail-fast ✓、诊断旁路启动 ✓、socket ✓、单例锁 ✓、shm 30Hz ✓
- 2026-09-11 13:00 步骤2 commit a3ab013；修复 shm 残留对象问题（启动先 unlink 重建）
