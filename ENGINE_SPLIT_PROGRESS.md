# AuroraDrive 引擎拆分进度

> 规则：每次续做先读本文件；每步完成追加一行；旧内容永不删除。

- 最后更新：2026-09-11 13:27
- 当前步骤：5/5 完成（AI 环境可测项全过；真机项待用户验证）
- 上一步 commit：c382835
- 阻塞项：无
- 下一步要做：用户真机验收（见下「待用户验证」四项）+ 决定是否清理 root 遗留守护进程

## 已完成（全部 5 步）
- 步骤0 存档：✅ commit 0d5fffb
- 步骤1 TCC 继承实测：✅ 2026-09-10 23:40 用户终端实测 ax=true screen=true
- 步骤2 引擎子进程骨架：✅ commit a3ab013
- 步骤3 UI 接线：✅ commit 2805b0c
- 步骤4 UI 状态显示 + 心跳/看门狗：✅ commit ea57c80
- 步骤5 清理：✅ commit c382835
  - 已卸载并删除 `~/Library/LaunchAgents/com.aurora.drive.agent.plist`
  - `DaemonSetup.swift` 移除全部 launchd Agent 逻辑（installUserAgent/removeUserAgent/pingUserAgent/resolveUserAgentBinary 等），**仅保留 BPF 权限服务**
  - 移除废弃的 `--test-xpc` 自检入口（改为提示语）
  - 编译通过

## 验收清单结果
| # | 项目 | 结果 |
|---|---|---|
| 1 | 引擎子进程启动自检 ax=true screen=true | ⏳ 待用户环境（AI 沙箱 ax=false 属环境限制） |
| 2 | UI 启动带起引擎、socket/心跳正常、重复启动不产生第二个引擎 | ✅ 实测通过（3 个 UI 并发引擎数恒为 1） |
| 3 | 画板显示引擎抓屏 ≥30fps、检测框完整 | ⏳ 待用户真机（AI 沙箱无法启动抓屏） |
| 4 | 开始驾驶后行为与拆分前一致 | ⏳ 待用户真机 |
| 5 | 正常关 UI → 引擎继续；重开 UI → 自动重连 | ✅ 重连实测通过；bye 路径引擎侧已验证、UI 侧 applicationWillTerminate 已接（用户 ⌘Q 时触发） |
| 6 | kill -9 UI → 3 秒窗口后停车 + releaseAll | ✅ 实测通过（日志见 "UI died, parking" + "已释放全部按键"） |
| 7 | 真机连续驾驶 10 分钟无掉帧/无崩溃/无键卡死 | ⏳ 待用户真机 |
| 8 | 引擎失败时 UI 回退本地模式 | ✅ 实测通过（AURORA_UI_LOCAL=1 → 不拉引擎、走本地） |
| 9 | 每步有本地 commit，可回退步骤0 | ✅ 6 个本地 commit，未推送远程 |

## 待用户验证（4 项，需真机环境）
1. **引擎自检**：终端跑 `./AuroraDriveUI --engine` → 日志应见 `TCC 自检 ax=true screen=true`
2. **画板与检测框**：正常启动 UI → 引擎模式已连接 → 点开始驾驶 → 画面与检测框正常
3. **驾驶行为一致**：推理、按键注入、车速 OCR 全通
4. **长时间稳定性**：连续驾驶 10 分钟

## 待用户决定
- **root 遗留守护进程**（非本次拆分产物，Sep 8 旧架构遗留，需 sudo 清理）：
  - `/usr/local/bin/aurora-drive-daemon` + `/Library/LaunchDaemons/com.aurora.drive.daemon.plist`（pid 83549 在跑）
  - 另有 `com.aurora.bpf-fix.plist`(Aug 27) / `com.aurora.bpf-setup.plist`(Aug 28) — BPF 相关，文档要求保留

## 时间线
- 2026-09-11 13:16 步骤3 联调：UI 自动连接 ✅
- 2026-09-11 13:18 场景3/4 通过：kill -9 → parking；重开重连；单例正确 ✅
- 2026-09-11 13:21 用户真机点击验证：UI 按钮 → socket `start` 命令送达引擎 ✅（命令链路端到端通）
- 2026-09-11 13:26 场景：引擎被杀 → UI 显示失联且不崩溃；引擎重启 → UI 自动重连 ✅
- 2026-09-11 13:27 步骤5 commit c382835；验收清单 AI 可测项全过
