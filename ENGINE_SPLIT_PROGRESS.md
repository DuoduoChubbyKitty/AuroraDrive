# AuroraDrive 引擎拆分进度

> 规则：每次续做先读本文件；每步完成追加一行；旧内容永不删除。

- 最后更新：2026-09-11 13:45
- 当前步骤：5/5 完成 + 回归修复中
- 上一步 commit：8b3f92f
- 阻塞项：无
- 下一步要做：用户重启 UI 验证「插帧」与「框选」两项修复；随后清历史遗留 bug

## 回归修复（拆分后用户实测反馈）
### ① 插帧不可用（一直显示"插帧中 · 等待"）— 已修 ✅
根因：引擎模式下 UI 不采集，`upscaleHost` 拿不到帧 → 插帧无数据源。
修法：新增「画面档位」机制（socket 命令 `upscale`）——
- 开插帧 → 引擎发**全分辨率帧**（它从 CaptureEngine.onUpscaleFrame 拿），UI 读成 CVPixelBuffer 直接喂 MetalGoose
- 关插帧 → 引擎发 480 宽缩略帧（省带宽，与拆分前默认一致）
- UI（重）连上引擎时自动同步一次档位（onActivated 回调）
实测验证：`480×312/0.57MB ⇄ 2940×1912/21.44MB` 档位切换生效，**全分辨率下仍稳定 30.0 fps**；命令链路通。

### ② 框选点空白生成"幽灵框"且永不消失 — 已修 ✅
根因：引擎模式下检测结果在 `remoteDetections`，而框选逻辑读的是 `yoloEngine.detections`（恒为空）
→ 每次都走「兜底建一个 0.12 的框」分支。
修法：改用 `effectiveDetections`（统一起见本地/引擎两种模式）；并且**点空白不再建框**，
只有点在真实检测框上（含 3% 余量）才锁定该目标。

## 重要：引擎必须由 UI 启动
引擎子进程继承的是**父进程的 TCC 权限链**。从终端/AI 会话直接跑 `--engine` 会继承那条链
（ax=false）从而 fail-fast 自保退出。正确用法：**启动 UI**，由 UI 自动拉起引擎（或先你手动
跑 `./AuroraDriveUI --engine`，此时继承你的终端链）。

## 已完成（全部 5 步，时间线）
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

## 真机验证进展（2026-09-11 13:30 实测用户会话）
用户实际启动 UI（pid 88621）+ 引擎（pid 88622）后，从引擎日志与共享内存读到：
- ✅ **引擎自检通过**（否则会 fail-fast 退出；引擎持续运行即证明 ax/screen 均通过）
- ✅ **帧管道打通**：帧尺寸 480×312（480 宽为设计值，等比），页字节 0.57MB
- ✅ **抓屏 30fps 稳定**：25 秒内 seq 2401→3151（正好 30 帧/秒）
- ✅ **开始驾驶 → 按键权限通过**：13:30:16 driving=true；13:30:18 收到 stop → driving=false
- ✅ **单例保护真实生效**：我们另起的测试引擎被 flock 拒绝（"已有引擎实例在运行，本进程退出"）
- ⏳ 仍待验证：画面在窗口里的观感流畅度、YOLO 检测框（桌面画面无目标，det=0 属正常）、10 分钟稳定性

## 本轮额外修复（commit 663c784）
- **修复隐患**：引擎模式下若开启「插帧/超分」开关，UI 会去显示 upscaleHost（引擎模式下无该数据源）→ **会黑屏**。已改为引擎模式强制走 frameHost 显示引擎帧。
- 新增 UI 侧「收到引擎首帧 WxH」日志（帧管道自证）
- 新增引擎 `AURORA_ENGINE_DIAG_CAPTURE_ONLY=1` 仅抓屏诊断模式（无按键权限环境也能验证帧管道）

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
