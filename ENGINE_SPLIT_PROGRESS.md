# AuroraDrive 引擎拆分进度

> 规则：每次续做先读本文件；每步完成追加一行；旧内容永不删除。

- 最后更新：2026-09-11
- 当前步骤：0/5（步骤0 进行中）
- 上一步 commit：（无，本次为初始）
- 阻塞项：无
- 下一步要做：步骤0 完成（本地 commit 存档）→ 步骤2 引擎子进程骨架（EngineMain.swift + --engine 分支）

## 已完成
- 步骤1 TCC 继承实测：✅ 2026-09-10 23:40 用户终端实测 `./AuroraDriveUI --tcc-selftest` → ax=true screen=true，权限继承成立
- 前置：launchd 方案否决（实测 ax=false screen=false）；已装 LaunchAgent（com.aurora.drive.agent）待步骤5 清理

## 时间线
- 2026-09-11 步骤0 开始：创建进度文件，准备本地存档 commit（禁止 push）
