# 代码-33 进程模式与 CLI 参数全解

> 覆盖源文件：AuroraDriveApp.swift Launcher/main()（527–672 行）+ EngineMain.swift + EngineClient.swift spawnEngine（290–314 行）+ VisualLocator.swift --locate-live（118/185/275 行）+ 各自检入口。基于当前仓库逐单元编写。grep 全 Sources 实测 86 处 CLI 引用。

## 一、进程模式总览与 CLI 参数全集（86 处引用）

**四种进程模式**：

| 模式 | 入口 | 特征 |
|---|---|---|
| **GUI 模式**（默认） | `AuroraDriveApp.main()` | SwiftUI 界面 + engine.sock 探测（无引擎 spawn 自己）+ 全部防冻结措施 |
| **引擎模式** | `--engine` → `EngineMain.run()` | **纯后台驾驶引擎：不触碰 SwiftUI、不创建窗口、不跑 NSApp**；dispatchMain 常驻；自身 engine.lock |
| **命令模式** | `--agent-command "<指令>"` | **.accessory 后台运行、不抢焦点、全部窗口 orderOut（保持游戏所在 Space 激活，供键注入落到游戏内）**；独立引擎组（AppDelegate.agentEngines 静态持有） |
| **一次性自检** | 7 个自检 flag | **短命进程或被 launchd 托管，不参与 UI 锁**（oneShotFlags） |

**CLI 参数全集（grep 86 处引用整理）：**

| 参数 | 解析位置 | 行为 | 参与文档 |
|---|---|---|---|
| `--engine` | Launcher.main:564 | EngineMain.run()（**永不返回**） | 代码-06/07 |
| `--daemon` | App:93（applicationDidFinishLaunching） | setActivationPolicy(.accessory)——**历史入口保留** | 代码-24 单元二 |
| `--test-xpc` | App:103 | **已废弃**——"launchd 拉起拿不到 TCC 权限" + exit(0) | 代码-24 单元二 |
| `--tcc-selftest` | App:112 | AXIsProcessTrusted + CGPreflightScreenCaptureAccess → 追加写 ~/Library/Logs/AuroraTCCSelfTest.log + exit(0/2) | 代码-24 单元二 |
| `--yolo-selftest <图片>` | App:131 + run.sh:117 | YoloEngine().selfTest(imagePath:) + exit(0) | 代码-14 |
| `--yolo-bench <图片>` | App:138 + run.sh:120 | YoloEngine().benchmark(imagePath:)（直通 vs 慢路径对比） | 代码-14 |
| `--speed-selftest <目录> [--roi x,y,w,h]` | App:147–150 | SpeedOCRReader().selfTestDirectory(...)+ exit(0)——--roi 解析 4 个 Double → CGRect | 代码-12 |
| `--upscale-selftest` | ContentView.onAppear:2290 | runUpscaleSelfTest()——**需要 MTKView/NSApp 上下文，故在 onAppear 而非 Launcher** | 代码-24 单元三 |
| `--set-llm-config <apiKey> <baseUrl> <model>` | Launcher.main:570 | **提前处理（不需要 GUI/引擎）**——AgentSettings.save()（小本本 + 固定域 UserDefaults，不碰钥匙串）+ exit | 代码-23 单元三 |
| `--agent-llm-test` | Launcher.main:588 | **真实 LLM 请求自测（不需要 GUI）**——纯同步 URLSession + 30s 硬超时；Key 从环境变量 AURORA_API_KEY | 代码-24 单元三 |
| `--agent-command "<指令>"` | App:234/310/339–341/352 | **命令模式全链**：accessory + 独立引擎组 + requestCommandOnStartup（1.5s 下发、8s 兜底） | 代码-24 单元二 |
| `--auto-login` | App:328 + run.sh:128 | **启动即自动登录守护**——1.5s 后 requestAutoLoginOnStartup（8s 检测 × 10 次 = 80s 超时） | 代码-22/23 |
| `--auto-drive` | ContentView.onAppear:2276 | **自主测试**——1.5s 后 startDriving()（模拟人工点击） | 代码-26 单元一 |
| `--auto-seconds N` | ContentView.onAppear:2282 | 配合 --auto-drive：N 秒后 exit(0)（无人值守端到端验证，跑完读 /tmp/aurora_debug.log） | 代码-26 单元一 |
| `--agent-selftest` | ContentView.onAppear:2303 | 1.2s 后 configure + AgentSelfTest.run(center:)（七组测试 + ported 双向一致性） | 代码-23 单元十一 |
| `--agent-ui-shot` | ContentView.onAppear:2313 | AgentUIShot.run()——ImageRenderer 无头渲染 /tmp/aurora_ui_shot.png | 代码-23 单元十三 |
| `--agent-layout-shot` | ContentView.onAppear:2319 | runLayoutCompare()——折叠 vs 展开两帧并排 /tmp/aurora_layout_compare.png | 代码-23 单元十三 |
| `--locate-live` | VisualLocator:118/185/275 | **诊断开关**——locate 每次把耗时落 stderr（[LOCATELIVE-DIAG] locate total=Nms） | 代码-17 |
| `--skip_view` / `--skip_yolo` | App:1616（Python 训练参数） | startTraining 传给 train_game_assist.py——视角分类器不训 + YOLO 用现成预训练 | 代码-25 单元六 |

**oneShotFlags（7 个短命进程，Launcher.main:661–663）**：`--speed-selftest / --tcc-selftest / --test-xpc / --yolo-selftest / --upscale-selftest / --yolo-bench / --daemon`——源注释："**它们是短命进程或被 launchd 托管，若参与锁会与常驻 UI 互斥，导致自检失败或用户无法启动界面**"；非 oneShot 且 UI 锁失败 → 打印原因 + exit(0)。

**环境变量**：`AURORA_API_KEY`（--agent-llm-test 的 Key 来源）/ `AURORA_TCC_TEST`（--tcc-selftest 日志的 mode 字段）/ `AURORA_DAEMON_MODE=1`（--daemon 的等价环境变量）。

## 二、spawnEngine 引擎拉起与 Launcher 分流细节

**`spawnEngine()`（EngineClient.swift，private，第 291–314 行）——spawn 引擎子进程（同二进制 + --engine；stdout/stderr → 引擎日志）**：

1. **可执行路径（292–297 行）**：`CommandLine.arguments[0].standardizedFileURL.resolvingSymlinksInPath()`——**同二进制（含符号链接解析：AuroraDriveUI 可能是 symlink，解析到真实二进制）**；`isExecutableFile` 验证——无效 → engineClientLog"可执行文件路径无效" + false
2. **Process 组装（298–300 行）**：executableURL = exeURL + **arguments = ["--engine"]**——**同一二进制以引擎模式重启自己**
3. **日志重定向（301–305 行）**：`FileHandle(forWritingAtPath: engineLogPath)`（/tmp/aurora_engine.log）→ seekToEndOfFile（追加）→ **standardOutput + standardError 同一 fh**——"stdout/stderr → 引擎日志"
4. `try process.run()` → engineClientLog"spawn 引擎 pid=N" + true；失败 → "spawn 失败" + false

**引擎探测链（EngineClient.startup，代码-07 已详）**：探测 engine.sock：已有健康引擎 → 直接连接；没有 → **spawn 自己（--engine）**；任一步失败自动回退本地模式。

**Launcher 分流细节（AuroraDriveApp.swift 527–672，代码-24 单元三已详）**：

| 步骤 | 行为 |
|---|---|
| `setvbuf(stdout, nil, _IOLBF, 0)` | **stdout 改行缓冲：print 立即落盘** |
| `--engine` | EngineMain.run()——永不返回（dispatchMain 常驻；自身已有 engine.lock） |
| `--set-llm-config` | AgentSettings.save() + exit（不需要 GUI/引擎） |
| `--agent-llm-test` | 纯同步 URLSession + 30s 硬超时 + semaphore 35s + exit(0/1) |
| oneShotFlags 判定 | 7 个短命参数不参与 UI 锁；非 oneShot 且锁失败 → exit(0) |
| `AuroraDriveApp.main()` | 正常启动 SwiftUI |

**GUI 模式完整启动链（组合视图）**：

```
AuroraDriveLauncher.main()
  → setvbuf 行缓冲
  → AuroraDriveApp.main()（SwiftUI）
    → AppDelegate.applicationDidFinishLaunching（9 步：CLI 自检 → EngineClient.startup（探测/spawn 引擎）
      → 防 App Nap（beginActivity + GameModeDefender.start）→ CGEventTap 空监听 → 768MB 内存锚点（mlock）
      → 命令模式分流 + IOPMAssertion → Darwin Notification Center → 窗口延迟激活
      → --auto-login/--agent-command 派发 → 命令模式引擎注入）
    → ContentView.onAppear（7 步：DispatchSource tick 30Hz → Daemon/BPF 检查 → 网络定位 10Hz
      → --auto-drive → --upscale-selftest → AI Agent 面板初始化（configure × 3））
  → DriveState.tick()（30Hz 决策管线，代码-25 单元八）
```

**排障权威参考（两份日志 + 分工）**：

| 日志 | 写入方 | 内容 |
|---|---|---|
| `/tmp/aurora_engine.log` | 引擎进程（spawnEngine 重定向 stdout/stderr） | **引擎侧全部输出**（EngineMain 启动/引擎状态/心跳/命令） |
| `/tmp/aurora_debug.log` | UI 进程（DriveState.dlog，10MB 封顶） | **UI 侧 tick 摘要/决策/诊断**（mode/模型/命令/按键/front/ocr/eff/lag/mem） |
| `/tmp/aurora_anchor_diag.log` | AppDelegate（锚定窗口安装） | stdout 重定向诊断 |
| `/tmp/aurora_iopm_status.log` | AppDelegate（IOPMAssertion） | 系统电源断言状态 |
| `/tmp/aurora_defender.log` | GameModeDefender（双进程） | **[ENGINE]/[UI] 前缀 + 持久战重新主张记录** |
| `~/Library/Logs/AuroraTCCSelfTest.log` | --tcc-selftest | TCC 权限预检结果 |
| `/tmp/upselftest_result.txt` | --upscale-selftest | 插帧自检验定 |

**代码-33 文档至此完整**（spawnEngine 引擎拉起 → Launcher 分流 → GUI 完整启动链 → 两份日志与排障分工）。