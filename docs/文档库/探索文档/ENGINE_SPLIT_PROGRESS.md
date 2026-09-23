# AuroraDrive 引擎拆分进度

> 规则：每次续做先读本文件；每步完成追加一行；旧内容永不删除。

- 最后更新：2026-09-11 22:10
- （2026-09-19 档案标注：本日志停更于 9-11；项目其后已演进至 7b7d2db（BidKing PR#434 提取至独立文件夹 BidKing_PR434/），引擎拆分成果已并入主干，旧内容按规则永不删除）
- 当前步骤：5/5 完成 + 回归修复（第2批）
- 上一步 commit：d632559
- 阻塞项：无
- 下一步要做：用户重启（UI+引擎都要新版）验证第2批修复；继续清历史遗留 bug

## 回归修复（第2批，用户真机反馈）
### ③ 状态面板/帧率/自车信息空掉 — 已修 ✅（39d5cda）
根因：引擎模式 `tick()` 提前 return，本地推理路径里那些「显示用状态」不再更新
（`mode`/`speedKmh`/`confidence`/`effectiveSpeed`），且 `speedKmh` 原本是读本地 speedOCR 的计算属性（引擎模式下恒 -1）。
修法：引擎心跳新增 `modeRaw / speed / speedKmh / confidence` 回传；UI 在 tickEngineMode 应用；
`speedKmh` 改为「引擎模式读回传值，本地模式读 speedOCR」。

### ④ 锁定框不跟随、不自动解除 — 已修 ✅（39d5cda）
根因：追踪函数 `trackLock` 只在本地推理流程内部调用；引擎模式 UI 不跑推理 → 锁定框冻住、
丢失超时判定也不跑（所以框永不消失）。
修法：新增 `YoloEngine.trackLockFromRemote(_:)`，引擎模式下用引擎回传检测框逐帧推进追踪。

### ⑤ 全屏游戏时标题栏遮挡画面 — 已修 ✅（cc2f3c5）
修法：隐藏标题栏 chrome（标题条 + 红黄绿按钮）。**拖窗口请拖顶部隐形标题栏区域。**

### ⑥ 拖拽框选被「拖动窗口」抢走 — 已修 ✅（d632559）
根因：⑤ 里顺手加的 `window.isMovableByWindowBackground = true` 让整个窗口背景可拖动，
导致在画面上拖拽 = 拖窗口，框选完全失效。
修法：移除该行（已加注释禁止再犯）。

### ⑦ 检测框叠加层卡顿 — 已减负（6836dbe）
减负：逐帧避免无变化赋值，减少 SwiftUI 刷新 churn。
待确认：若插帧全分辨率档下仍卡，下一步把 21MB 大帧的 shm→CVPixelBuffer 拷贝搬到后台队列。

## 回归修复（第1批）
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

### ⑧ 停止驾驶后插帧不收尾 — 已修 ✅（fbdbf03）
根因：引擎模式下 `isStreaming` 只在"有帧"时被置 true，从不复位 → 停止后 UI 仍以为在推流，
插帧视图一直挂着、徽章一直显示"插帧中"。
修法：引擎报告 isStreaming=false 时 UI 侧收尾（isStreaming=false + upscaleLive=nil + upscaleHost.clear() + frameHost.clear()）；
徽章新增「插帧 · 待机」档（未驾驶时不显示"插帧中"）。

### ⑨ UI 关闭后引擎常驻不退出 — 已修 ✅（fbdbf03，已实测）
修法：UI 断开（无论 bye 还是异常）即启动 30 秒倒计时，无人重连 → `performShutdown("idle-exit")`（先 releaseAll 再退）。
重连即取消倒计时。实测：断开→倒计时→5秒重连取消→再断开→30秒后安全退出 + socket 清理。

### ⑩ 通信链路深度排查（9 项跨进程断点）— 已修 ✅
完整报告见 `COMM_AUDIT_2026-09-12.md`。触发问题：**「录制文件夹/文件能建，但录不进东西」**。

**总根因**：引擎拆分后，`tick()` 在引擎模式下只在**引擎进程**执行；
凡是「只在 tick() 里被读」的状态，UI 改了引擎根本收不到。
`socket` 原命令表只有 `start/stop/bye/status/upscale/ping`，**录制/参数/模型重载三条链路全断**。

| # | 问题 | 等级 | 修复 |
|---|---|---|---|
| P1 | **录制完全录不进**：UI 建目录+文件，但写帧的 `recordFrameIfNeeded()` 只在 tick() 里调，引擎模式下永不执行 | 🔴 | 新增 `record` 命令 + 心跳 `recording`/`frames` + UI 转发/回同步 |
| P2 | **禁用控制失效**（安全）：`expertMode \|\| controlDisabled → releaseAll()` 在 tick 内，UI 拨了引擎不知道 → 以为松手了车还在被开 | 🔴安全 | 新增 `config` 命令下发 |
| P3 | **紧急切纯规则失效**（安全）：`forceRuleMode` 控制停 M9 推理 + 降级状态机强制规则档，同样只在 tick 内 | 🔴安全 | 同上 |
| P4 | 极速模式失效（降级状态机覆盖） | 🟡 | 同上 |
| P5 | 降级阈值失效（`degradeStm.degradeHealth`） | 🟡 | 同上 |
| P6 | **训练后模型热替换未跨进程**：`deployTrainedModel()` 只调 UI 的 `reloadModel()`，引擎仍用内存旧模型 →「训练了没生效」 | 🔴 | 新增 `reloadmodel` 命令 |
| P7 | `pauseDriving` 不停录制 → UI 关闭后多录 30 秒「车停+陈旧标签」垃圾帧，污染训练集 | 🟡 | `pauseDriving` 内停录制并收尾 |
| P8 | `performShutdown` 竞态：`stop()` 的 meta.json 是异步写，紧跟 `exit(0)` → 会话缺 meta.json | 🟡 | 新增 `RecordEngine.flushSync()`，退出前排空写盘队列 |
| P9 | **修复过程中自引入**：录制回同步无宽限期 → 命令发出后 30Hz 的 tick 立刻把开关弹回 | 🟠 | 2 秒宽限期 + 引擎带 `record-ack` 即时回执 |

**修复后命令表**：`start stop bye status upscale record reloadmodel config ping`

**结构性结论**：任何「UI 可改、引擎可读、但无人同步」的第三类状态都是定时炸弹。
跨进程状态必须二选一 —— 引擎权威则**心跳回传**，UI 权威则**命令下发**。P2–P5 全部属于漏网的第三类。

状态：编译 ✅ / 已部署（主程序+app 双份重签名）✅ / 时间戳链校验 ✅ / **运行时 E2E 待用户重启验证** ⏳

**追加发现（同批审计）**：
- **P11【高】「已移除」的网络定位仍在每次启动自动运行**：`.onAppear` 里 10 Hz 定时器**无门控**、`runNetworkLocateStep()` **自身也无 enable 检查**，一启动就 `CoordinateCapture.start()` 开 BPF 抓包。
  运行时铁证：`lsof /dev/bpf1` → `AuroraDri 4954` 持有该设备。
  副作用：`/tmp/aurora_pcap.log` **无轮转**，4 天已 23.6 MB / 40 万行，仍以约 51 MB/天增长。
  ⚠️ **未擅自修复**（属功能性变更，不确定是否仍依赖网络定位）
- **P12【中】旧架构 root 守护进程仍在跑**：`/usr/local/bin/aurora-drive-daemon`（pid 83549，已跑 2 天 21 小时），
  `KeepAlive=true`（杀了自动重启）+ `Nice=-20`（全系统最高优先级），二进制内含旧版抓屏/键盘注入/BPF 全套能力。
  需 sudo 清理；**BPF 两个 plist 必须保留**。
- **XPC 专项结论**：`AuroraDriveUserAgent` 服务端 + `AuroraDriveShared` 协议 + `Package.swift` target 都在，
  但**主程序零 `NSXPCConnection` 客户端代码**，安装 plist 还躺在 `/tmp/`（位置错误）→ **进程从未运行**。
  **XPC 不是「不通」的原因，它根本没有链路**。建议删除或补齐，别留着误导排查。
