# AuroraDrive 通信链路深度排查报告

> 排查时间：2026-09-12
> 触发问题：「文件夹能建、文件能建，但录不进任何东西」+「模型/训练/录制好多都没法通讯」
> 排查方法：全源码静态审计（`Sources/AuroraDrive/`，25 个 Swift 文件）+ 逐条验证

---

## 1. 排查范围概览

### 1.1 系统进程模型

引擎拆分后是**双进程架构**，代码同源（同一份 `DriveState`），靠运行时分支区分角色：

| 进程 | 判定条件 | 职责 |
|---|---|---|
| **UI 进程** | `EngineClient.shared.isActive == true` | 只显示；tick 走 `tickEngineMode()` 后**提前 return** |
| **引擎进程** | `EngineClient.shared.isActive == false` | 抓屏 / 推理 / 按键注入 / 录制；tick 走**完整决策管线** |

→ **判据**：任何「只在 `tick()` 里被读」的状态，在引擎模式下**只有引擎进程能看到**；UI 改了必须显式推送。

### 1.2 通信链路清单

| 编号 | 链路 | 机制 | 方向 | 状态 |
|---|---|---|---|---|
| L1 | UI → 引擎 命令 | Unix socket，JSON 行协议 | 单向 | 部分缺失（本报告重点） |
| L2 | 引擎 → UI 心跳 | Unix socket，1 Hz JSON | 单向 | 字段不全（本报告补齐） |
| L3 | 引擎 → UI 画面/检测 | POSIX 共享内存 `shm_open` + 双缓冲 | 单向 | 正常 |
| L4 | 引擎 → 游戏 按键 | CGEvent (HID) | 单向 | 正常 |
| L5 | 屏幕 → 引擎 抓屏 | ScreenCaptureKit | 单向 | 正常 |
| L6 | UI → Python 训练进程 | `Process` 派生 + stdout 重定向 `train.log` | 单向 | 启动正常，**结果回传缺失**（P6） |
| L7 | 双进程 → 磁盘 | 文件系统（models / data/raw_clips） | 双向 | 路径一致（`AuroraPaths` 编译期 `#filePath` 解析） |
| L8 | 引擎单实例 | `flock(~/Library/Application Support/AuroraDrive/engine.lock)` | — | 正常 |
| L9 | 引擎空闲退出 | UI 断开 → 30 s 倒计时 | — | 正常 |

### 1.3 修复前 socket 命令表

```
start  stop  bye  status  upscale  ping      ← 只有 6 条
```

---

## 2. 发现的问题列表

### P1 — 录制命令未跨进程【严重 · 功能完全失效】

| 项 | 内容 |
|---|---|
| **问题描述** | 用户点「开始录制」→ 目录与 `controls.csv`/`frames/` 被创建，但**永远没有帧写入**，录出空目录 |
| **风险等级** | 🔴 严重（功能完全不可用） |
| **定位依据** | ① `AuroraDriveApp.swift:1508` `if EngineClient.shared.isActive { tickEngineMode(); return }` —— 引擎模式下 tick 提前返回<br>② 同文件 `recordFrameIfNeeded()` 是唯一写帧入口，**只被 `tick()` 调用**，故引擎模式下永不执行<br>③ `isRecording` 的 `didSet`（`:832`）在**两个进程里都**调用本地 `recordEngine.start()` —— UI 进程建了目录/文件<br>④ 引擎进程持有另一份 `DriveState`/`RecordEngine`，但 socket 命令表（`EngineMain.swift:644-684`）**没有 record 命令**，无人调用它的 `start()` |
| **根因** | 引擎拆分时，录制落在了 UI 侧，而帧只存在于引擎侧 |

### P2 — 「禁用控制」未跨进程【严重 · 安全】

| 项 | 内容 |
|---|---|
| **问题描述** | UI 拨「禁用控制」后，引擎仍持续注入 AI 按键 → 用户以为已松手，车还在被 AI 开 |
| **风险等级** | 🔴 严重（人身/车辆安全语义失效） |
| **定位依据** | `AuroraDriveApp.swift:1694`<br>`if expertMode \|\| controlDisabled { controlEngine.releaseAll() } else { applyCommand(currentCommand) }`<br>该语句位于 `tick()` 内 → 引擎模式下**只有引擎进程执行**；而 `controlDisabled` 是 UI 进程的 DriveState 变量，从未下发 |

### P3 — 「紧急切纯规则」未跨进程【严重 · 安全】

| 项 | 内容 |
|---|---|
| **问题描述** | UI 点「紧急切纯规则」实际无效：M9 推理不停、降级状态机不切规则档 |
| **风险等级** | 🔴 严重（用户以为已进安全兜底，实际仍在跑模型） |
| **定位依据** | ① `AuroraDriveApp.swift:1576` `if !forceRuleMode { inferenceEngine.infer(...) }`（省资源停 M9）<br>② `:1638` `forceRule: forceRuleMode` 传入 `degradeStm.update(...)` 强制规则档<br>两处均在 `tick()` 内 |

### P4 — 「极速模式」未跨进程【中】

| 项 | 内容 |
|---|---|
| **问题描述** | 拨极速模式无反应（不强制 E2E、不关避障） |
| **风险等级** | 🟡 中 |
| **定位依据** | `DegradeStateMachine.swift:144` `if sportMode { transition(to: .e2e, ...) }`，由 `AuroraDriveApp.swift:1637` 的 `sportMode: sportMode` 传入，调用点在 `tick()` 内 |

### P5 — 「降级阈值」未跨进程【中】

| 项 | 内容 |
|---|---|
| **问题描述** | 拖动阈值滑杆无反应 |
| **风险等级** | 🟡 中 |
| **定位依据** | `AuroraDriveApp.swift:1559` `degradeStm.degradeHealth = degradeThreshold`，在 `tick()` 内 |

### P6 — 训练完成后的模型热替换未跨进程【高】

| 项 | 内容 |
|---|---|
| **问题描述** | 训练成功 → 模型文件正确落盘为 `m9_mono.*` → **但引擎仍用内存里的旧模型**，即「训练了却没生效」。这解释了用户说的「模型没法通讯」 |
| **风险等级** | 🔴 高（训练投入全部白费，且被误判为训练效果差） |
| **定位依据** | `AuroraDriveApp.swift:1389` `deployTrainedModel()` 末尾只调 `inferenceEngine.reloadModel()`（UI 进程实例）。`InferenceEngine.reloadModel()` 仅置空本进程 `model = nil`；引擎进程的 `inferenceEngine`/`assistEngine` 从未被通知 |

### P7 — `pauseDriving` 不停录制【中 · 数据污染】

| 项 | 内容 |
|---|---|
| **问题描述** | UI 关闭（bye / 看门狗超时）后引擎继续录制约 30 秒，内容为「车已停 + 标签仍是上一刻 AI 决策」的垃圾帧。这批帧进入 `data/raw_clips`，会被下次训练当作有效样本 |
| **风险等级** | 🟡 中（污染模仿学习数据集，且难以事后识别） |
| **定位依据** | `EngineMain.swift:805` 原 `pauseDriving()` 仅 `isDriving = false` + `releaseAll()`，未处理 `isRecording` |

### P8 — `performShutdown` 竞态丢 `meta.json`【中】

| 项 | 内容 |
|---|---|
| **问题描述** | 引擎退出时，录制会话缺少 `meta.json`（帧数与时长信息丢失） |
| **风险等级** | 🟡 中 |
| **定位依据** | `RecordEngine.swift:187` `stop()` 中 `meta.json` 由 `writeQueue.async` 异步写出；`EngineMain.swift:815` `performShutdown()` 在其后**立即 `exit(0)`** → 异步块可能来不及执行 |

### P9 — 【修复过程中自引入并已修正】录制开关按下即回弹

| 项 | 内容 |
|---|---|
| **问题描述** | 加完录制回同步后，用户点录制 → 开关立刻自己弹回 |
| **风险等级** | 🟠 高（功能性回归） |
| **定位依据** | 心跳周期 1 s，命令发出后引擎尚未上报；UI 的 `tickEngineMode()` 以 30 Hz 运行，下一次 tick 即读到 `engineRecording == false`，把 `isRecording` 镜像回 false |
| **备注** | 已在同批次修复（宽限期 + 引擎即时回执），记录在此以说明「回同步必须配套宽限期」这一模式 |

### P10 — 「速度上限」未跨进程【中高 · 静默影响驾驶】

| 项 | 内容 |
|---|---|
| **问题描述** | UI 拖动「速度上限」滑杆，引擎侧模型**完全不知情**：界面显示 40 km/h，AI 仍按 120 km/h 决策 |
| **风险等级** | 🟠 中高（非显示项 —— 直接进入模型输入，静默改变驾驶行为） |
| **定位依据** | ① `AuroraDriveApp.swift:914` `var speedLimit: Double = 120`<br>② `:3600` 绑定 UI 滑杆 `value: $state.speedLimit, range: 40...200, step: 5`<br>③ `tick()` 内（`:1610` / `:1612`）作为 `speedLimitKmh: speedLimit` 传入 `inferenceEngine.infer(...)` 与 `assistEngine.infer(...)`<br>④ `InferenceEngine.swift:320` `speed_limit_norm = speedLimit / 120` → 成为 `vehicle_state[4]` → **直接参与 steer/throttle 推理** |
| **发现方式** | 全量状态清点：提取 `tick()` 函数体（1537–1794 行），逐个统计所有 UI 可绑定的状态变量引用次数，再逐一核对是否已同步。**这是本轮唯一一个靠"逐条清点"才挖出来的缺口**——前 9 项都是顺着"录制"这条线牵出来的 |

### P11 — 「已移除」的网络定位仍在每次启动时自动运行【高 · 非预期行为】

| 项 | 内容 |
|---|---|
| **问题描述** | `networkLocate` 被认为已废弃（`startDriving()` 里 `networkLocator.start()` 已注释、代码注释写「旧网络抓包定位已移除」）。但实际上：**每次启动 App 都会自动开启 BPF 网络抓包**，且持续运行 |
| **风险等级** | 🟠 高（非预期行为 + 隐私面 + 性能 + 磁盘） |
| **定位依据** | ① `AuroraDriveApp.swift:1944-1951` — `.onAppear` 中创建 10 Hz 定时器，**无任何开关门控**，回调里先 `pcapLog(...)` 再 `state.runNetworkLocateStep()`<br>② `runNetworkLocateStep()` **自身也没有 enable 检查**，第一件事就是 `coordinateCapture == nil` → `CoordinateCapture()` → `cc.start()`（打开 BPF 设备）<br>③ **运行时铁证**：`lsof /dev/bpf1` → `AuroraDri 4954 dupi 9u CHR 23,1 /dev/bpf1` —— **新 UI 进程此刻正持有 BPF 抓包设备**<br>④ 日志铁证：`/tmp/aurora_pcap.log` 中 `[NETWORK-LOCATE] CoordinateCapture已启动` 共 141 条，最近一条 `2026-09-12T01:16:38Z`（= 本地 09:16，正是本次启动时刻） |

**副作用（实测）**：
- **日志无轮转、无封顶**：`/tmp/aurora_pcap.log` 已 **400,898 行 / 23.6 MB**（09-08 → 09-12，约 4 天），当前仍在以约 **590 B/s ≈ 51 MB/天** 增长
- 10 Hz 无条件写盘 + 10 Hz 抓包，即使没人用网络定位

### P12 — 旧架构 root 守护进程仍在运行【中 · 架构残留】

| 项 | 内容 |
|---|---|
| **问题描述** | 旧单进程架构编译出的 root 守护进程仍在运行，与新双进程架构并存 |
| **风险等级** | 🟡 中 |
| **定位依据** | ① `ps` → `root 83549 /usr/local/bin/aurora-drive-daemon --daemon`，**已运行 2 天 21 小时**，累计 CPU 5:26<br>② `/Library/LaunchDaemons/com.aurora.drive.daemon.plist`：`RunAtLoad=true` + `KeepAlive=true`（**杀了会自动重启**）+ `Nice=-20`（**全系统最高调度优先级**）<br>③ 二进制（Sep 8 22:17）字符串中包含完整的旧 App 组件：`CaptureEngine` / `KeyboardMonitor` / `CGEventSource` / `CoordinateCapture` / `/dev/bpf0` / `pcap_compile` / `/tmp/aurora_pcap.log` |

**为何列入通信排查**：它以最高优先级常驻，且内含抓屏/键盘注入/BPF 全套能力，与新的引擎进程**功能重叠**。虽然实测当前 `%CPU 0.0`（多数时间空闲），但它是一个「随时可能介入」的未知变量，排查通信问题时应先排除。

**清理需 sudo**（本会话审批已禁用，无法执行）：
```
sudo launchctl bootout system/com.aurora.drive.daemon
sudo rm /Library/LaunchDaemons/com.aurora.drive.daemon.plist /usr/local/bin/aurora-drive-daemon
```
⚠️ **`com.aurora.bpf-setup.plist` 与 `com.aurora.bpf-fix.plist` 必须保留**（BPF 设备权限依赖它们，删了会导致 `/dev/bpf*` 权限丢失）。

### 2.1 【专项】XPC 链路排查结论 —— 存在但完全未接线（死代码）

用户明确提到「XPC 那边很多问题」，故单独核实。**结论：XPC 不是问题源，因为它根本没有链路。**

| 检查项 | 结果 | 依据 |
|---|---|---|
| 服务端实现 | ✅ 存在且可编译 | `Sources/AuroraDriveUserAgent/main.swift`（52 行）：`NSXPCListenerDelegate` + `NSXPCListener(machServiceName:)`，实现 `ping` / `startDriving` / `stopDriving` |
| 共享协议 | ✅ 已定义 | `Sources/AuroraDriveShared/AuroraDriveShared.swift:8` `machServiceName = "com.aurora.drive.agent"` |
| 构建目标注册 | ✅ 已注册 | `Package.swift:13-17` `executableTarget(name: "AuroraDriveUserAgent")` |
| **客户端调用** | ❌ **完全没有** | 全源码 grep `NSXPCConnection` → **只命中 UserAgent 自身**；主程序 `AuroraDrive` 侧零引用 |
| **安装** | ❌ **从未安装** | 安装用 plist 位于 `/tmp/com.aurora.drive.agent.plist` —— **位置错误**（launchd 只加载 `~/Library/LaunchAgents/` 或 `/Library/LaunchDaemons/`），故永不被加载 |
| **运行** | ❌ **从未运行** | `ps` 无 `AuroraDriveUserAgent` 进程（只有系统自带的 `searchpartyuseragent` / `mbuseragent`） |

**判定**：这是一个**未完成的设计残留** —— 服务端写好了，客户端从未编写，也从未安装运行。
**对当前通信问题零影响**。用户体感的「各种不通」实际来自 P1–P10（socket 命令表缺 `record`/`config`/`reloadmodel` 三条链路），与 XPC 无关。

**建议**：要么补齐客户端并正式安装（若确有多用户会话隔离需求），要么**直接删除** `Sources/AuroraDriveUserAgent/` + `AuroraDriveShared/` + `Package.swift` 对应 target，消除误导。当前状态最坏 —— 看起来有、实际没有，会让后续排查反复走弯路（本次即为实例）。

### 2.2 已确认正常、无需修改的链路


- `startDriving` / `stopDriving` 已有引擎分支并正确转发（`AuroraDriveApp.swift:1187` / `:1220`）
- 插帧开关 `upscaleEnabled` 已通过 `setUpscale` 下发（`:1152`）
- 检测框、档位、车速、置信度、有效车速已通过心跳回传并在 UI 镜像
- 锁定目标追踪已用 `trackLockFromRemote` 推进
- `enableNetworkLocate` 已废弃（`locator.start()` 被注释），**不构成断链**

---

## 3. 改进建议与修复方案

### 3.1 已实施的修复（本批次）

| 编号 | 修复内容 | 落点 |
|---|---|---|
| P1 | 新增 socket 命令 **`record`**（携带 `on`/`glyph`/`expert`），由引擎执行 `st.isRecording = ...` | `EngineMain.swift` `handleCommand` |
| P1 | 心跳新增 **`recording`** / **`frames`** 字段 | `EngineMain.swift` `sendHeartbeat` |
| P1 | `EngineClient` 新增 `engineRecording` / `engineRecordFrames` 并解析 | `EngineClient.swift:80-83`、`:291-293` |
| P1 | UI `isRecording` didSet：引擎模式**只转发命令**，不再本地建目录 | `AuroraDriveApp.swift:836-843` |
| P1 | `tickEngineMode()` 回同步录制状态与帧数（含 `applyingRemoteRecord` 防回环） | `AuroraDriveApp.swift:1495-1501` |
| P2–P5 | 新增 socket 命令 **`config`**，统一下发 `sport` / `controlDisabled` / `forceRule` / `expert` / `glyph` / `degradeThreshold` / `speedLimit`；UI 侧 `pushEngineConfigIfChanged()` 变化时才发 | `EngineMain.swift`、`AuroraDriveApp.swift` |
| P6 | 新增 socket 命令 **`reloadmodel`**；`deployTrainedModel()` 在引擎模式下转发 | `EngineMain.swift`、`AuroraDriveApp.swift` |
| P7 | `pauseDriving()` 中一并停止录制并收尾 | `EngineMain.swift:805` |
| P8 | `RecordEngine.flushSync()`（`writeQueue.sync` 屏障），`performShutdown()` 在 `exit(0)` 前排空写盘队列 | `RecordEngine.swift`、`EngineMain.swift` |
| P9 | 录制宽限期 `lastRecordCommandTime`（2 s）+ 引擎带 `record-ack` 即时回执 | `AuroraDriveApp.swift`、`EngineMain.swift` |
| P10 | `speedLimit` 并入 `config` 下发（进 `vehicle_state[4]`） | `EngineMain.swift`、`AuroraDriveApp.swift` |

**修复后 socket 命令表**：
```
start  stop  bye  status  upscale  record  reloadmodel  config  ping
```

### 3.2 结构性建议（防止同类问题复发）
1. **建立「跨进程状态清单」并纳入交接检查**
   凡是在 `tick()` 内被读取的可变状态，都必须二选一：
   - 由引擎作为权威源，通过心跳**回传**（如 `mode`/`speedKiNh`/`recording`）
   - 由 UI 作为权威源，通过命令**下发**（如 `config`/`record`）
   **禁止**存在「UI 可改、引擎可读、但无人同步」的第三类状态 —— P2/P3/P4/P5 全部属于这一类。

2. **给 `DriveState` 的属性加显式标注**
   建议对 `sportMode` / `controlDisabled` / `forceRuleMode` / `expertMode` / `glyphMode` / `degradeThreshold` 统一加 `// [跨进程:下发]` 注释，或抽成 `EngineLinkConfig` 结构体集中管理，避免新增属性时再次遗漏。

3. **安全开关加「生效回执」**
   P2/P3 是安全开关，建议除下发外，还在心跳里回传引擎侧的实际值，UI 显示「已生效 / 未生效」状态，杜绝静默失效。

4. **命令行验证工具**
   建议给引擎 socket 加一个 CLI（如 `--cmd record --on`），便于在不启动 UI 的情况下验证命令链路 —— 本次排查受限于「无法在不动用户运行中实例的前提下做 E2E 验证」。

5. **心跳字段宁多勿少**
   本次 P1/P6 的根因都是「状态变了但没上报」。心跳是 1 Hz、负载只有几百字节，**多加字段的成本远低于漏一个字段的代价**。建议把引擎侧所有会影响 UI 显示的 DriveState 字段都纳入心跳。

6. **P11 建议（未实施，需用户确认）**
   `runNetworkLocateStep()` 与那个 10 Hz 定时器**缺少 enable 门控**。建议二选一：
   - 若网络定位确实已废弃 → 删掉定时器与 `CoordinateCapture` 调用链
   - 若仍需保留 → 至少加 `guard enableNetworkLocate else { return }`，并把 `pcapLog` 改成按需写（当前 10 Hz 无条件写盘、无轮转，约 51 MB/天）
   **未擅自修改**：这属于功能性行为变更，不确定用户是否仍依赖该能力。

### 3.3 验证状态

| 项 | 状态 |
|---|---|
| 编译 | ✅ `swift build -c release` 通过 |
| 部署 | ✅ 主程序 + `.app` 双份已原子替换并重签名（`codesign -v` 通过） |
| 时间戳链 | ✅ 源码 → 编译产物 → 部署文件 严格递增 |
| **运行时 E2E** | ⏳ **待用户重启验证**（用户当前实例仍在运行旧二进制，未打断） |

**建议的验证步骤**：
1. 完整重启（UI + 引擎都要换新二进制）
2. 点「开始录制」→ 应看到帧数从 0 开始递增（引擎日志出现 `[ENGINE] 录制开始`）
3. 停止录制 → `data/raw_clips/clip_*/` 下应有 `frames/00000.jpg...` + `controls.csv` + `meta.json`
4. 拨「禁用控制」→ 引擎日志出现 `[ENGINE] 参数同步：... 禁控=true`，车应立即松手
5. 关闭 UI → 引擎日志应先出现「录制已停止」，再 30 s 后「30 秒无人使用，自动退出」
