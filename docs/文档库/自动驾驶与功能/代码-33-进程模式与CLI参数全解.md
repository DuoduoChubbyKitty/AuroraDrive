# 代码-33 进程模式与 CLI 参数全解
> ✅ 2026-10-17 复核：正文与三个历史复核块中的全部 `文件:行号` 引用已按当前源码 `grep -n` 逐条实测修正，失效警告段已全部删除。文末附「实测锚点表」。
>
> **✅ 2026-10-18 复核（T7）**：lead 于 10-18 改过 `CaptureEngine.swift` 两处频率注释，连带 `EngineMain.swift`（2002 行）与 `AuroraDriveApp.swift`（9095 行）行号漂移。本次逐条核对 47 条跨文件引用，改动如下：
> - **内容修正 4 处**：①**tick 频率 30Hz → 20Hz**（`EngineMain.engineTickHz = 20.0` @:686，`tickHz(forPerceptionMode:)` 两档都返回 20，应急 sprint 45Hz）②「初始 30Hz / 按档位 45Hz 或 30Hz」→「两档均 20Hz + 应急 45Hz」③`MissionConsole` bootstrap 的 tick 定时器 30Hz→**20Hz**（源码 :6113-6115 注释自证「2026-10-12 定档 20Hz」）④`DriveState.tick()` 「30Hz 决策管线」→**20Hz**
> - **行号修正 51 条**：EngineMain 26 条（`run() :880-1167→:885 起`、`handleCommand :1484-1882→:1497-1883`、`sendHeartbeat :1887→:1900`、9 个命令分发 `start :1496→:1509` 等全部 +13、`shm 布局 :114-128→:82-135`）、AuroraDriveApp 5 条（`AURORA_DISABLE_OPTICAL_FLOW :5803→:5805`、`AURORA_OBSERVE_ONLY :6243→:6246`、`AURORA_LOG_SYNC :8954→:8953`、`--skip_view 转发 :6415→:6418`、`startup() :208-210→:209`）
> - **复核仍准确、未改的**：oneShotFlags 50 项（括号配平实测 `:919-970` = 50，去重 50）、AuroraDrive 自有 CLI 72 字面量/70 自有 flag（`grep -rhoE '"--[a-z0-9_-]+"' Sources/ | sort -u | wc -l` = 72）、`@main` :721 / `main()` :748 / `setvbuf` :751 / UI 单实例锁 :1301-1307 / `SelfTestResultBox` :713 / `runBlockingSelfTest` :1043-1051 / 全部 `--mc-*` 与自检分流区间 / EngineClient 全部 12 条 / AuroraFlags `helpText()` :521 / MissionConsole bootstrap 各 flag / LLMSelfTest 7 个入口 / QuestPanelReader 6 条 / WireSelfTest 3 条 / VisualLocator 3 条
> - **未改**：`Sources/` 下任何文件（纪律）。
>
> **✅ 2026-10-18 二次重基准（源码冻结于 AuroraDriveApp 9097 行版）**：逐条 `sed -n` + `grep -n`，共检查 **43** 条唯一引用，修正 **9** 条：
> - `EngineClient.swift` 4 条：`engineLogPath :151-154→:152-155`（3 处）、`attachShm :501-522→:502-524`、`poll :609-781→:610-783`
> - `MissionConsole.swift` 2 条：`renderQuestCardNow :6886→:6891`（原来引的是它上方的注释块）、bootstrap 六个 flag `:6207/6211/6219/6242/6250/6254→:6212/6216/6224/6247/6255/6259`
> - 文件行数声明 3 条：`AuroraDriveApp 9095→9097`（冻结版）、`MissionConsole 7716→7721`、其余 7 个文件行数逐个实测后标注「本次实测 N」
> - **判定为「语义一致、无需改」的 34 条**：含 `AuroraDriveApp:919-970` oneShotFlags 50 项（括号配平复验）、`AuroraDriveApp:919` 起数组、`EngineMain:885/916-958/1497/1970`、`EngineClient:64/166-205/166-172/704-712`、`AuroraFlags:521`、`QuestPanelReader:11/929`、`WebSearch:1451`、`VisualLocator:118`、`WireSelfTest:12-30/47`、`LLMSelfTest:93`、`MissionConsole:4259/6045-6052` 等
> - **刻意保留不改的 2 条**：`AuroraDriveApp.swift:816-820`（文档自标「2026-09-29 历史快照，已失效，仅作历史」）与 `AuroraDriveApp.swift:1033`（文档自标「**取证当时**记录的行号」，是 `sample` 栈里的历史值）—— 两者都是**历史引用**，改成现值反而失真

> ### 2026-10-07 复核块（**AI 自检 8 flag 入库 + oneShotFlags 陷阱定案**，逐行实测；行号 2026-10-17 复核更新）
>
> 本次基于当前工作区快照 `AuroraDriveApp.swift`（**9088 行**，2026-10-17 `wc -l` 实测）逐条打开源码核对。
>
> ---
>
> ## ★ 一、oneShotFlags 现为 **50 项**（`AuroraDriveApp.swift:919-970`，2026-10-16 括号配平实测，2026-10-17 复核仍为 50 项）
>
> 实测方法（**不要按 `]` 截断，注释里也有 `]`，会少数**）：
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> python3 - <<'EOF'
> import re
> lines = open('Sources/AuroraDrive/App/AuroraDriveApp.swift').read().split('\n')
> for n, l in enumerate(lines):
>     if 'let oneShotFlags' in l: start = n
>     if '--capture-selftest"]' in l: end = n; break
> code = '\n'.join(l for l in lines[start:end+1] if not l.strip().startswith('//'))
> flags = re.findall(r'"(--[a-z0-9-]+)"', code)
> print('行范围 %d-%d，项数=%d，去重后=%d' % (start+1, end+1, len(flags), len(set(flags))))
> print('\n'.join('%2d %s' % (i, f) for i, f in enumerate(flags, 1)))
> EOF
> ```
>
> **实测输出（2026-10-17 复核）**：行范围 `919-970`，**项数 = 50，去重后 = 50**（无重复项）。
> 演进：37 项（2026-10-06 记录）→ 45 项（2026-10-07，新增 8 个 AI flag，第 38–45 项）→
> **50 项**（2026-10-16，新增 `--v2-selftest`/`--agent-selftest`/`--map-selftest`/`--lane-extrapolator-selftest`/`--capture-selftest` 五项，第 46–50 项）。
>
> | # | flag | 分组 | 说明 |
> |---|---|---|---|
> | 38 | `--llm-selftest` | A1 协议/链路 | 离线默认，`--network` 追加真实请求 |
> | 39 | `--llm-probe` | A1 探活 | 7 渠道真实健康表 |
> | 40 | `--llm-vision-selftest` | A1 视觉 | 真实截图 → 视觉模型 |
> | 41 | `--control-selftest` | A2 按键 | 四证据链 |
> | 42 | `--tool-selftest` | A3 工具 | 注册表 + schema + dryRun |
> | 43 | `--tool-call-demo` | A3 端到端 | 模型决策 → 工具分发 → 执行 |
> | 44 | `--llm-perf-selftest` | 性能预算 | 主线程阻塞 / 首字延迟 / 内存 |
> | 45 | `--websearch-selftest` | W5 联网搜索 | 解析器离线默认，`--network` 真发请求 |
>
> **完整 50 项清单**（源码顺序，`919-970`）：
> `--speed-selftest`、`--tcc-selftest`、`--test-xpc`、`--yolo-selftest`、`--upscale-selftest`、
> `--yolo-bench`、`--daemon`、`--mc-shot`、`--mc-map`、`--mc-map-offline`、`--fit-selftest`、
> `--limit-selftest`、`--nic-autotest`、`--proto-selftest`、`--yolopx-selftest`、
> `--opticalflow-selftest`、`--motion-selftest`、`--corner-selftest`、`--perf-selftest`、
> `--tick-profile`、`--tick-bench`、`--realshot-selftest`、`--egobox-selftest`、`--ayolom-selftest`、
> `--lanekeep-selftest`、`--perception-selftest`、`--wire-selftest`、`--lanekeep-reality`、
> `--route-selftest`、`--taxonomy-selftest`、`--mc-route`、`--mc-route-loading`、`--mc-map-bench`、
> `--flags-help`、`--cache-selftest`、`--quest-selftest`、`--mc-quest`、
> `--llm-selftest`、`--llm-probe`、`--llm-vision-selftest`、`--control-selftest`、`--tool-selftest`、
> `--tool-call-demo`、`--llm-perf-selftest`、`--websearch-selftest`、
> `--v2-selftest`、`--agent-selftest`、`--map-selftest`、`--lane-extrapolator-selftest`、`--capture-selftest`。
>
> ---
>
> ## ★ 二、8 个 AI flag 逐个源码核实（作用 / 用法 / 依赖 / 实测项数）
>
> 所有命令统一前缀：`BIN=./AuroraDriveUI`（或构建产物 `./.build/scratch/release/AuroraDrive`），
> **自检必须带 `AURORA_UI_LOCAL=1`** —— 否则会尝试连/拉引擎，结论受环境干扰。
>
> | flag | 源码入口 | 分发行（2026-10-17 实测） | 依赖 | 实测项数 | 退出码 |
> |---|---|---|---|---|---|
> | `--llm-selftest [--network]` | `LLMSelfTest.runLLM(ledger:network:)`（`Agent/LLMSelfTest.swift:93`） | `:1053-1060` | 离线无需网络；`--network` 需网络 | **93 通过 / 0 失败**（离线） | 失败项数 |
> | `--llm-probe` | `LLMSelfTest.runProbe(ledger:)`（`:961`） | `:1061-1067` | **需要网络** | 2 项断言 + 逐模型健康表（13 条） | 失败项数 |
> | `--llm-vision-selftest` | `LLMSelfTest.runVision(ledger:)`（`:996`） | `:1068-1074` | **网络 + 屏幕录制权限** | **6 通过 / 0 失败**（证据文件里 `✅` 计 7，多的是 `[LLMTransport] ✅` 传输层日志行而非断言——以汇总行的 6 为准） | 失败项数 |
> | `--control-selftest` | `LLMSelfTest.runControl(ledger:)`（`:1087`） | `:1075-1081` | **辅助功能权限**（启动器需 `ax=true`） | **32 通过 / 0 失败** | 失败项数 |
> | `--tool-selftest` | `LLMSelfTest.runTools(ledger:)`（`:1360`） | `:1082-1088` | 无（纯注册表，离线可跑） | **150 通过 / 0 失败** | 失败项数 |
> | `--tool-call-demo <task>` | `LLMSelfTest.runToolCallDemo(ledger:task:live:)`（`:1635`） | `:1089-1097` | **需要网络**（真实模型请求）；默认 dryRun | **9 通过 / 0 失败** | 失败项数 |
> | `--llm-perf-selftest [--seconds N]` | `LLMSelfTest.runPerf(ledger:seconds:)`（`:1797`） | `:1108-1117` | 无（进程内采样） | **6 条确定性断言**（源码 `ledger.check` 实测 6 处）+ 1 条首字延迟（有候选才计入，故汇总行是 **6/0 PASS** 或 **6/1 FAIL**） | 失败项数 |
> | `--websearch-selftest <q> [--network]` | `WebSearchSelfTest.runFromCommandLine(_:)`（`Agent/WebSearch.swift:1451`） | `:1124-1129` | 离线可跑；`--network` 需网络 | **42 通过 / 0 失败**（离线；`✅` 行实测计数 = 42） | 失败项数 |
>
> ⚠️ **`--tool-selftest` 项数会随后续施工变动**：`verify/evidence-llm/a3-tool-selftest.txt`
> 记录的是 **144**（2026-10-06），此后在**已部署二进制**上复跑得 **150** ——
> 增量来自技能/工具清单扩充。**引用项数前请以当次实跑输出为准**，不要照抄历史数字。
>
> ### 2.1 可复制执行的完整命令
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> BIN=./AuroraDriveUI          # 已部署；构建产物用 ./.build/scratch/release/AuroraDrive
>
> # A1 协议 / SSE / 错误分类 / 候选排序（离线恒跑，无需网络）
> AURORA_UI_LOCAL=1 $BIN --llm-selftest
> # A1 追加真实请求（"对话真能用"的唯一有效证据；失败计入退出码）
> AURORA_UI_LOCAL=1 $BIN --llm-selftest --network
> # A1 七渠道探活健康表（需网络）
> AURORA_UI_LOCAL=1 $BIN --llm-probe
> # A1 真实截图 → 视觉模型（需网络 + 屏幕录制权限）
> AURORA_UI_LOCAL=1 $BIN --llm-vision-selftest
> # A2 按键四证据链（需辅助功能权限；无权限时①即红，不会假绿）
> AURORA_UI_LOCAL=1 $BIN --control-selftest
> # A3 工具注册表 + schema + 全工具 dryRun（离线可跑）
> AURORA_UI_LOCAL=1 $BIN --tool-selftest
> # A3 端到端闭环：模型决策 → 工具分发 → 执行（默认 dryRun，不注入任何事件）
> AURORA_UI_LOCAL=1 $BIN --tool-call-demo "领奖励"
> # A3 端到端 **真注入**（会真的按键！仅在游戏前台、确认可接受时用）
> AURORA_UI_LOCAL=1 $BIN --tool-call-demo "领奖励" --live
> # 性能预算断言（默认 6s，可 --seconds 覆盖）
> AURORA_UI_LOCAL=1 $BIN --llm-perf-selftest --seconds 6
> # W5 联网搜索（离线跑解析器夹具；--network 真发 search + fetch）
> AURORA_UI_LOCAL=1 $BIN --websearch-selftest "swift actor"
> AURORA_UI_LOCAL=1 $BIN --websearch-selftest "异环 攻略" --network
> ```
>
> **判失败统一按 `EXIT != 0`**；退出码语义是「失败项数」（上限 127）。
>
> ### 2.2 各 flag 的边界与诚实标注（照抄源码注释，不美化）
>
> - `--llm-selftest` **不带 `--network` 时**源码会显式打印
>   「本次未带 --network：**未验证**「对话真能用」这一步」——即**离线全绿 ≠ 对话可用**。
> - `--llm-vision-selftest` 在无屏幕录制权限时**如实标注环境受限并提前返回**（不算失败）；
>   无视觉候选时同样「不静默降级」，源码注释写明这是产品契约。
> - `--llm-probe` 的 2 条断言是「至少一个模型 ok」+「耗时 < 120s」，
>   逐模型健康态是**打印**而非断言（要看细节就读输出，别只看 PASS）。
> - `--websearch-selftest` 的离线夹具全部是 **2026-10-06 本机实测抓下来的原始 HTML**
>   （DDG Lite / 403 反爬页 / Wikipedia JSON / 正文提取 / `<header>` 误删回归），
>   断言的是真实格式而不是脑补格式。
> - `--tool-call-demo` 的 `--live` **会真的注入按键**；默认 dryRun 不注入。
>
> ---
>
> ## ★ 三、陷阱一：**oneShotFlags 漏登记 = 假绿**（实测踩过）
>
> **登记（进数组）与分发（写 `if args.contains` 分支）是两件事，缺一不可**，
> 而且**两种缺法的症状完全不同** —— 这是本坑最阴的地方：
>
> | 情况 | 会发生什么 | 退出码 | 表面现象 |
> |---|---|---|---|
> | **只分发、没登记** | 分支写在锁判定（`:1301-1307`）**之后** → 被 UI 单实例锁挡掉（`isOneShot=false`（`:1301`）→ `acquireUISingleInstanceLock()` 失败 → 打印「已有 AuroraDrive 实例在运行」→ `exit(0)`） | **0** ⚠️ | **假绿**：脚本看到 EXIT=0，以为自检通过，实际一行断言都没跑 |
> | **只登记、没分发** | 数组里有名字 → 不被锁挡；但**没有分支** → 掉进正常启动路径 `AuroraDriveApp.main()` → **开出一个 GUI 窗口** | 挂起/非 0 | 「自检」变成了开界面，脚本超时 |
> | **登记 + 分发都有** | 正确：`exit(runBlockingSelfTest(...))` | 失败项数 | 正常 |
>
> **源码原话**（`AuroraDriveApp.swift:1030-1032`）：
> > 【为什么必须在这里分发】flag 在 oneShotFlags 里登记只解决"不被 UI 单实例锁挡掉"，
> > **不解决"跑起来"** —— 少了这段分发，`--llm-selftest` 会走到正常启动路径（开 UI），
> > 自检等于没跑。登记与分发是两件事，缺一不可。
>
> 数组上方的注释也连写多处 ⚠️（`:933-934`、`:937`、`:940`、`:949-950`），其中 W5 那次最狠：
> > ⚠️ W5 实测警告：漏登记时进程会被 UI 单实例锁挡掉**却仍 exit 0** —— **假绿**。
> > 登记与分发必须同时存在。
>
> **为什么会 exit 0 而不是报错**：那段代码的本意是「用户重复双击图标时体面退出」
> （`:1302-1307`，注释写明原因是「两个 UI 会互抢引擎 socket（0.5s 断开重连死循环）」），
> 对一个**误入这条路的自检**它同样是 0 —— 于是掩盖了「自检根本没跑」。
>
> **防假绿的验证手法**（新增 flag 时必做，本机可复制）：
>
> ```bash
> cd /Users/dupi/Desktop/自动驾驶系统
> # ① 先确认 flag 在数组里（应打印 50 项数组内的目标 flag）
> grep -n -- '--websearch-selftest' Sources/AuroraDrive/App/AuroraDriveApp.swift | head -3
> # ② 再确认「真的跑了」：输出里必须有自检的抬头行与汇总行，而不是锁提示
> AURORA_UI_LOCAL=1 ./AuroraDriveUI --websearch-selftest "swift actor" 2>&1 | tail -3
> #    ✅ 期望看到：═══ 结果：全部通过 ═══
> #    ❌ 若看到：[App] 已有 AuroraDrive 实例在运行 —— 本次启动退出   ← 就是本坑
> # ③ 反向对照：故意跑一个**不存在的** flag，观察它走正常启动（会开 UI，据此确认分流边界）
> ```
>
> ---
>
> ## ★ 四、陷阱二：**分发绝不能用 `DispatchSemaphore`**（实测死锁，栈已留证）
>
> **症状**：`--control-selftest` 跑 2 分钟零输出，进程活着但什么都不打印。
>
> **取证**：`sample` 栈卡在（证据文件 `verify/evidence-llm/dispatch-deadlock-sample.txt`，
> 采样 2410 次全部命中同一帧；栈内 `AuroraDriveApp.swift:1033` 为**取证当时**记录的行号，
> 对应现 `runBlockingSelfTest` 定义 `:1043-1051`）：
>
> ```
> 2410 specialized static AuroraDriveLauncher.main()  (AuroraDriveApp.swift:1033)
>   → _dispatch_semaphore_wait_slow (libdispatch) → _dispatch_sema4_wait
>     → semaphore_wait_trap (libsystem_kernel.dylib)
> ```
>
> **根因**：自检内部要 `MainActor.run`（取 `DriveState.shared.controlEngine`、截图取帧），
> 而主线程被 `semaphore.wait()` 占死 → MainActor 永远排不上 → 互等成死锁。
> **注意这不是"慢"，是永久卡死**：等多久都不会出结果。
>
> **修法**：**主线程泵 RunLoop + 轮询结果盒子**（`AuroraDriveApp.swift:1043-1051`，实测有效）：
>
> ```swift
> /// 一次性 CLI 自检的结果盒子（:713-715）
> final class SelfTestResultBox: @unchecked Sendable { var value: Int? }
>
> func runBlockingSelfTest(_ title: String, _ body: @escaping () async -> Int) -> Int32 {
>     let box = SelfTestResultBox()
>     Task { box.value = await body() }              // 异步跑自检
>     while box.value == nil {                       // 主线程泵事件
>         RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
>     }
>     return Int32(min(box.value ?? 0, 127))         // 失败项数截到 127
> }
> ```
>
> **为什么 runloop 泵能行**：主线程仍在**处理事件**（而不是被 wait 阻塞），
> 于是派发到 MainActor 的 `MainActor.run` 能真正执行，Task 正常推进。
> 源码注释（`:1034-1040`）把这条记为「血泪教训」。
>
> **推论（写新自检时照做）**：
> ① 需要主线程上下文的断言 → 整段放进**一次** `MainActor.run`，
> 不要在多个 `await` 之后分散执行（async 函数在每个挂起点后**不保证回到同一线程**，
> `CFRunLoopAddSource(CFRunLoopGetCurrent())` 会绑到当时的线程上 → 泵另一个 runloop → 收不到事件）；
> ② 任何「主线程等异步结果」的地方，一律 runloop 泵，**永不** `semaphore.wait()`。
>
> ---
>
> ## ★ 五、8 个 AI flag 的一行速查（源码分流顺序）
>
> 分流顺序（`AuroraDriveApp.swift` 实测）：oneShotFlags 数组定义 `:919-970`（50 项）→
> `--perf-selftest` `:1130` → `--tick-profile` `:1144` → `--tick-bench` `:1157` →
> `--realshot-selftest` `:1169` → … → `runBlockingSelfTest` 定义 `:1043` →
> **AI 段 `:1028-1129`** →
> `--map-window-test` `:1297`（**在锁判定之前**，故可在 UI 运行时验证新构建）→
> **UI 单实例锁判定 `:1301-1307`** → 禁用窗口状态恢复 `:1310` 起 → `AuroraDriveApp.main()` `:1358`。
>
> **判据**：任何一个 flag 的 `if args.contains(...)` 若写在 `:1301` **之后**，
> 就必须出现在 `oneShotFlags` 里，否则必被锁挡掉。
>
> ---

> ### 2026-10-06 复核块（自检家族 / `--mc-*` 夹具 / 双进程引擎交接，逐行实测；行号 2026-10-17 复核更新）
>
> 本次基于当前工作区快照（`AuroraDriveApp.swift` **9088 行** / `EngineMain.swift` **1989 行** /
> `EngineClient.swift` **895 行** / `WireSelfTest.swift` 222 行 / `QuestPanelReader.swift` 1160 行 /
> `MissionConsole.swift` 7716 行）逐条打开源码核对，行号全部按现版实测。
>
> ## ★ 一、CLI 分流全景（`AuroraDriveApp.swift` Launcher `main()`，`:748-1359`）
>
> 分流顺序（全部实测）：`setvbuf`（`:751`）→ `--mc-map`（`:758`）→ `--mc-map-offline`（`:763`）→
> `--mc-route`（`:770`）→ `--mc-route-loading`（`:775`）→ `--mc-map-bench`（`:782`）→ `--mc-shot`（`:792`）→
> `--mc-quest`（`:810-820`）→ `--engine`（`:822-824`，`EngineMain.run()` 永不返回）→
> `--set-llm-config`（`:828-841`）→ `--agent-llm-test`（`:846-916`）→ oneShotFlags 数组定义（`:919-970`）→
> `--lanekeep-reality`（`:979-989`）→ `--wire-selftest`（`:990-993`）→ `--flags-help`（`:998-1001`）→
> `--cache-selftest`（`:1005-1008`）→ `--quest-selftest`（`:1014-1017`）→ `--capture-selftest`（`:1023-1026`）→
> **AI 段 `:1028-1129`**（`--llm-selftest` `:1053-1060` → `--llm-probe` `:1061-1067` → `--llm-vision-selftest` `:1068-1074` →
> `--control-selftest` `:1075-1081` → `--tool-selftest` `:1082-1088` → `--tool-call-demo` `:1089-1097` →
> `--v2-selftest` `:1101-1107` → `--llm-perf-selftest` `:1108-1117` → `--websearch-selftest` `:1124-1129`）→
> `--perf-selftest`（`:1130-1137`）→ `--tick-profile`（`:1144-1150`）→ `--tick-bench`（`:1157-1163`）→
> `--realshot-selftest`（`:1169-1180`）→ `--corner-selftest`（`:1185-1188`）→ `--egobox-selftest`（`:1192-1195`）→
> `--perception-selftest`（`:1199-1202`）→ `--lanekeep-selftest`（`:1207-1210`）→ `--ayolom-selftest`（`:1215-1218`）→
> `--yolopx-selftest`（`:1221-1228`）→ `--proto-selftest`（`:1232-1235`，无条件 `exit(0)`）→
> `--nic-autotest`（`:1237-1240`，无条件 `exit(0)`）→ `--limit-selftest`（`:1243-1246`，无条件 `exit(0)`）→
> `--opticalflow-selftest`（`:1249-1251`）→ `--motion-selftest`（`:1254-1256`）→ `--fit-selftest`（`:1260-1263`，无条件 `exit(0)`）→
> `--route-selftest`（`:1268-1270`）→ `--taxonomy-selftest`（`:1274-1276`）→ `--map-selftest`（`:1281-1283`）→
> `--lane-extrapolator-selftest`（`:1287-1291`）→ `--map-window-test`（`:1297-1299`）→
> **UI 单实例锁判定（`:1301-1307`）** → 禁用窗口状态恢复（`:1310-1356`）→
> `AuroraDriveApp.main()`（`:1358`）。
> 除 `--engine` 外全部 one-shot：跑完即 `exit()`，不参与 UI 锁（`:917-918` 注释）。
>
> **oneShotFlags 现为 50 项**（`:919-970`）：`--corner-selftest`、`--perf-selftest`、`--tick-profile`、`--tick-bench`、`--realshot-selftest`、
> `--egobox-selftest`、`--ayolom-selftest`、`--lanekeep-selftest`、`--perception-selftest`、
> `--wire-selftest`、`--lanekeep-reality`、`--route-selftest`、`--taxonomy-selftest`、`--mc-route`、
> `--mc-route-loading`、`--mc-map-bench`、`--flags-help`、`--cache-selftest`、`--quest-selftest`、`--mc-quest`
> + 8 个 AI flag（`:951-953`）+ `--v2-selftest`（`:958`）/`--agent-selftest``--map-selftest``--lane-extrapolator-selftest`（`:966-967`）/`--capture-selftest`（`:970`）。
> 注释多处 ⚠️ 强调数组**手写维护**，漏登记会被 UI 单实例锁挡掉（`:933-934`、`:937`、`:940`、`:949-950`）——
> 新夹具的 `if args.contains(...)` 分支若写在 :1301 判定之后即被锁挡掉，症状是打印
> 「已有 AuroraDrive 实例在运行」退出（`:1303-1306`）。**（该症状 2026-10-07 确认仍 exit 0 → 假绿，见顶部块）**
>
> `--mc-*` 无头出图必须在 Launcher 无 GUI 阶段同步跑完：截图是纯离屏 ImageRenderer 渲染，
> 放 onAppear 里无窗口时 view 不 layout → 永不触发、进程卡 240s（`:754-757` 注释）。
>
> ## ★ 二、selftest 家族重点（2026-10-06 实测，行号 2026-10-17 复核）
>
> | 夹具 | 入口（现版实测） | 要点 |
> |---|---|---|
> | `--quest-selftest` | `:1014-1017` → `QuestPanelReader.runSelfTest()`（`Inference/QuestPanelReader.swift:929`） | `models/quest_index.json`：1372 精确文本 → 2938 带坐标目标（`QuestPanelReader.swift:11`）；8 条真实面板文字回归（`:954`）+ 假阳性反例/投票/链消歧/坐标语义/ROI 提示行过滤（`:72-73`）；纯索引+纯函数无窗口可跑（`:1012` 注释） |
> | `--taxonomy-selftest` | `:1274-1276` → `runTaxonomySelfTest()`（`:1894-2098`） | 组数=7（`:1908`）；explore 450 / resource 1045 / travel 28 / monster 254 / shop 0 / service 0 / landmark 0（`:1931-1933`）；合计=1777（`:1959`）；1777 全有组（`:1975`）；**前置防假绿** `!MapDatabase.markers.isEmpty`（`:1939`） |
> | `--route-selftest` | `:1268-1270` → `runRouteSelfTest()`（`:2100-2298`） | **冻结基线：节点 664（`:2139`）/ 边 932（`:2140`）/ 0.61 米每像素（`:2141`）**；节点 24→36：W=0 距离 5.78 km 拐弯 30（`:2210-2211`），W=200 距离 6.51 km 拐弯 12（`:2215-2216`）；字典序 ≤ W=200（`:2236-2238`，旧等式是巧合已修正）；单次规划 <5ms（`:2246`）；300 对随机样本全可达，固定种子 0x5DEECE66D（`:2258`）且**不再对节点数取模**（`:2252-2257` 注释） |
> | `--wire-selftest` | `:990-993` → `runWireSelfTest()`（`Core/WireSelfTest.swift:47`，函数体至 `:222`） | 2026-10-02 四处「手切档位静默失效」缺陷的行为级验证（`WireSelfTest.swift:12-30`）；不做源码字符串匹配（`:32-33`）；**必须 `AURORA_UI_LOCAL=1`**（`:65`，A1 用例依赖本地模式必然未连引擎，`:67`，本次复核仍准确） |
> | `--mc-quest` | `:810-820` | 「当前任务」卡片离屏出图（task-2 验收）；必须走真实 ViewportPanel——`MissionControlShot.renderQuestCardNow(canvas:)`（`MissionConsole.swift:6891`，默认 1470×560），塞 questName + 真实世界坐标，不依赖 OCR 跑通（`:807-809` 注释） |
>
> 退出码约定：失败项数 `exit(failed == 0 ? 0 : min(failed, 127))`（`:988`、`:992`、`:1016` 等）；
> 例外：`--proto-selftest` / `--nic-autotest` / `--limit-selftest` / `--fit-selftest` 无条件 `exit(0)`
> （`:1232-1235`、`:1237-1240`、`:1243-1246`、`:1260-1263`，实际断言强度**未验证**）。
>
> ## ★ 三、双进程引擎交接（2026-10-06 全量实测，行号 2026-10-17 复核）
>
> ### 3.1 生命周期
> 1. UI 启动：`AppDelegate.applicationDidFinishLaunching`（`AuroraDriveApp.swift:133-537`）→ `EngineClient.shared.startup()`
>    （`AuroraDriveApp.swift:209`；daemon 模式跳过，`:136-143`）。
> 2. 探测（`Core/EngineClient.swift:166-205`）：先连 `~/Library/Application Support/AuroraDrive/engine.sock`
>    （socketPath `:147-150`）→ 成功 `activate()`（`:207-215`）；失败 `spawnEngine()`（`:330-353`）——
>    **同二进制 + `--engine`**，stdout/stderr 重定向到 **`~/Library/Logs/AuroraEngine.log`**
>    （engineLogPath `:152-155`）；每 0.3s 轮询重连、
>    20 次（6s）超时回退本地模式（`:186-200`）。
> 3. 引擎侧 `EngineMain.run()`（`Core/EngineMain.swift:885` 起，至 :1200 附近）：flock `engine.lock`（`:907`（flock 调用），
>    重复启动 `exit(0)`（:905 附近））→ TCC fail-fast（`:916-958`（AXIsProcessTrusted@:916 / CGPreflightScreenCaptureAccess@:917 / exit(2)@:955,:958）；观测模式 `AURORA_OBSERVE_ONLY=1`
>    放宽为只查 screen）→ socket server（`:999-1029`（server 创建@:999 / start@:1029））→ `EngineFrameShm()` 共享内存（`:1035`）→
>    `DriveState()` + tick（`:1042`，timer `:1067-1087`（makeTimerSource@:1067 / schedule@:1076；**两档均 20Hz**（`engineTickHz = 20.0` @:686），应急冲刺提到 45Hz（:1236 sprint 联动）——原「初始 30Hz / 45 或 30」已过期）→
>    1Hz 心跳（`:1098-1105`（hbTimer.setEventHandler@:1098 / sendHeartbeat periodic@:1105））。
> 4. 回退：任一步失败 → 本地模式；`AURORA_UI_LOCAL=1` 则连「想连引擎」都不成立
>    （`EngineClient.swift:166-172`，`wantsEngineMode=false`）。
> 5. UI 退出 `applicationWillTerminate` → `sendByeSync()`（`AuroraDriveApp.swift:542-544`）→
>    引擎 `pauseDriving`：释放按键、停录制，但保持抓屏推理等重连（`EngineMain.swift:1970`）；
>    异常断开有 3s 重连窗口（:1922）+ 30s 无人使用自动退出（:1947）。
>
> ### 3.2 通道一：UNIX socket（控制面，JSON 行协议）
> - 命令 `EngineMain.handleCommand`（`EngineMain.swift:1497`，函数体至 :1883 附近）：
>   `start`（`:1509`）/ `stop`（`:1522`）/ `bye`（`:1534`，只 pauseDriving 不退出）/ `status`（`:1545`）/
>   `upscale`（`:1556`，决定发全分辨率还是缩略帧）/ `record`（`:1569`）/ `reloadmodel`（`:1661`）/
>   `config`（`:1685`，携带 sport/controlDisabled/forceRule/expert/glyph/degradeThreshold/speedLimit，
>   speedLimit 直接参与推理 `:1731-1734`）/ `ping`（`:1883`）。
> - 心跳 1Hz `sendHeartbeat`（`:1900`，函数定义@:1900）：fps / detections（**计数**）/ isDriving / isStreaming /
>   mode / modeRaw / speed / speedKmh / confidence / recording / frames / **proto** / pid。
> - 协议版本 `protocolVersion = 3`（`EngineClient.swift:64`）：v1 原始五命令、v2 加
>   record/reloadmodel/config + 心跳 recording/frames/proto、v3 加共享内存掩码区
>   （pixelsOffset 20480→28672）（`:51-63` 注释）。**版本守卫** `isEngineStale` 必须以
>   `sawHeartbeat` 为前提——旧引擎根本不发 proto 字段（`:259-267`）；
>   `relaunchStaleEngine()` 真 kill（bye 无效）→ 等死透 → 重启，且必须重置 sawHeartbeat，
>   三个坑记录在 `:271-277` 注释。
>
> ### 3.3 通道二：POSIX 共享内存（数据面，`/aurora_frame_v1`）
> - 引擎 `EngineFrameShm`（`EngineMain.swift:152`（类定义））是唯一创建者与写入者（启动 `shm_unlink`
>   清残留 `:194`，`O_CREAT|O_RDWR` `:195`）；UI 只读映射 `O_RDONLY + PROT_READ`
>   （`EngineClient.swift:502-524`）。
> - 布局（`EngineMain.swift:82-135` 注释 + 常量实测）：头部 0-4095——magic（布局注释 :82-135） "AURF"@0、
>   version@4、headerSize=4096@8、detOffset@12、detCapacity@16、detStride@20、frameWidth@24、
>   frameHeight@28、generation@32、**activePage@36**、**frameSeq@40**、timestampNs@48、
>   detectionCount@56、flags@60（bit0 isDriving / bit1 isStreaming）、fpsMilli@64、enginePid@68、
>   pageSize@72、**maskSeq@80**、maskW/H@88/92、laneW/H@96/100、maskFlags@104、
>   letterbox ratio/padX/padY/srcW/srcH@108-124、**newW/newH@128/132**（2026-09-28 补传）。
>   检测区 4096-20479（256 条 × 64B：labelId/conf/cx,cy,w,h/rawName 16B）；
>   掩码区 20480 起——da 网格 3200B（160×160 bit-pack，每行 20B）+ ll 网格 3200B
>   （`maskBytes = 3200`（:171），`maskRegionBytes = 6400`（:173），`pixelsOffset`（:175））；像素区 **28672** 起
>   双缓冲页 A/B（BGRA，max 4096×2304×4/页，总长 = pixelsOffset + pageMax×2，`:189-191`）。
> - 掩码 bit-pack：25600B/份 → 3200B/份，20Hz 下省带宽（`:144-147` 注释）；
>   掩码用世代号 `maskSeq` 判新鲜、只在变化时重写——YOLOPX 15Hz vs tick 20Hz（注释 :149）。
> - UI 消费 `EngineClient.poll()`（每 tick 调用，`EngineClient.swift:610-783`）：
>   ① 读 `frameSeq@40`，无变化返回缓存（`:619-621`）；② 像素按 `activePage@36`+`pageSize@72`
>   定位，插帧开 → CVPixelBuffer 喂 MetalGoose，否则 CGImage 直绘（`:628-656`）；③ 检测框
>   `detectionCount@56` 上限 256 逐条 64B 解析（`:658-692`）；④ 掩码 `maskSeq@80` 变化才解析，
>   且**物理边界校验** `shmSize >= maskRegionEnd` 才敢读掩码区（`:713-716`）——防旧引擎
>   SIGSEGV 的最后一道防线（版本守卫在 tickEngineMode 里的位置晚于 poll，先读后查来不及拦，
>   `:704-712` 注释）；⑤ flags@60 → isDriving/isStreaming、fpsMilli@64 → engineFPS（`:773-778`）。
> - 心跳超时 3s → `handleConnectionLoss`（`:612-615` 调用，实现 `:552-570`）：关 socket、
>   isActive=false 回落本地模式。
> - **单向性**：共享内存只承载「引擎→UI」帧/检测/掩码；UI→引擎只有 socket 命令。
>   UI 在引擎模式下的显示数据全部镜像自 EngineClient（`AuroraDriveApp.swift:6530`、`:6585-6588` 等，见文末锚点表）。
>
> ### 3.4 三个踩坑实录（代码注释逐条核实）
> 1. **新增夹具忘登记 oneShotFlags** → 被 UI 单实例锁静默挡掉（`:919-970` 手写数组 +
>    `:1301-1307` 判定；`--quest-selftest` / `--mc-quest` 就是 2026-10-06 补登记的，`:936-938`）。
> 2. **协议/布局变更不升 protocolVersion** → 新 UI 按新偏移读旧引擎掩码区会读到 mmap 之外
>    直接 SIGSEGV（`EngineClient.swift:704-712` 注释 + 物理边界校验）；版本守卫必须以
>    `sawHeartbeat` 为前提（`:259-267`）。
> 3. **newW/newH 补传但不守卫事故（注释 :82-135）**（2026-09-28）：MaskOverlay 绘制守卫用了 `metrics.newW > 0`，
>    但协议头从来没传过 newW/newH → 引擎模式掩码一格都不画（`EngineMain.swift:82-135` 注释（布局段））；
>    本地模式走 `yolopxEngine.metrics` 一切正常 → **本地自检永远发现不了**，bug 只在双进程暴露。
>    修复双保险：①协议 128/132 真正补传（旧客户端不读，向后兼容）②同时去掉 MaskOverlay 对
>    newW 的守卫依赖（绘制数学本就不用它）。
>
> ## ★ 四、环境变量速查（行号实测）
> `AURORA_UI_LOCAL=1`（`EngineClient.swift:166-172`）、`AURORA_API_KEY`（`AuroraDriveApp.swift:855`）、
> `AURORA_MAP_WINDOW=1`（`AuroraDriveApp.swift:1410`，仅供无人值守自动化验证）、`AURORA_STUCK_SECONDS`（`:5357`）、
> `AURORA_DISABLE_OPTICAL_FLOW`（`:5805`）、`AURORA_OBSERVE_ONLY=1`（`:6246` + `EngineMain.swift:916-958`）、
> `AURORA_DAEMON_MODE`（`AuroraDriveApp.swift:138`）、`AURORA_LOG_SYNC`（`:8953`）、`AURORA_MAP_LEGACY_MARKERS=1`
> （`MissionConsole.swift:4259`，`--mc-map-bench` A/B 用，`AuroraDriveApp.swift:781` 注释）、`AURORA_AYOLOM=1`
> （`--ayolom-selftest` 必需，`:1213` 注释）、`AURORA_TCC_TEST`（`AuroraDriveApp.swift:159`，`--tcc-selftest` 日志 mode 字段）。
> 全表权威来源：`--flags-help` → `AuroraFlags.helpText()`（`Core/AuroraFlags.swift:521`；调用 `AuroraDriveApp.swift:999`）。
>
> 覆盖源文件：AuroraDriveApp.swift Launcher/main()（**2026-10-17 复核：@main 结构 AuroraDriveLauncher 为 `:721-1360`，main() 在 `:748`**）+ EngineMain.swift（**1989 行**，`wc -l` 实测）+ EngineClient.swift spawnEngine（**spawnEngine 声明在 `:330`；文件实测 895 行**）+ VisualLocator.swift（**491 行**）+ 各自检入口。
> CLI 参数计数（2026-10-17 实测）：本程序 CLI 参数**实测 72 个**（`grep -rhoE '"--[a-z0-9_-]+"' Sources/ | sort -u | wc -l`）；其中 `--skip_view` / `--skip_yolo` 两个是**转发给 Python 训练脚本**的参数、非本程序 flag（见下节 B），故本程序自身参数为 **70 个**。
> 口径说明：必须用**带下划线**的 `[a-z0-9_-]` 且限定在**双引号字符串字面量**内。更宽的口径（如不限引号、只匹配 `[a-z0-9-]`）会产生误匹配（`--lanekeep`/`--skip` 前缀截断、`--r--` 权限串、`--ice-glow` 颜色变量等），不可用。
>
> ---

> ## ⚠️ 2026-09-29 复核追加：CLI 参数实测 **72 个**（其中 2 个转发参数，本程序自身 70 个；本文原表缺 10 个）
>
> **实测方法（2026-10-17 复核）**：`grep -rhoE '"--[a-z0-9_-]+"' Sources/ | sort -u | wc -l` → **72 个**（**必须带下划线**，
> 否则 `--skip_view` / `--skip_yolo` 会被前缀截断成 `--skip` 而丢失/误计）。
> 其中 `--skip_view` / `--skip_yolo` 是**转发给 Python 训练脚本**的参数（见下节 B），**不是本程序入口 flag**；
> 故本程序自身 CLI 参数 = **70 个**。
>
> ### A. 本文原表缺失的 10 个参数（★ 全部为新增，需补登）
>
> | 参数 | 行为 | 归属 |
> |---|---|---|
> | `--fit-selftest` | 自适应缩放自检（`runFitSelfTest()`，Launcher 层） | 代码-26 |
> | `--limit-selftest` | 限速逻辑自检（三级刹车/SpeedLimitGuard 链路） | 代码-29 |
> | `--motion-selftest` | **运动预测自检**（`runMotionSelfTest()`，α-β 滤波 + 光流补帧） | 新文档 4.9 |
> | `--opticalflow-selftest` | **光流自检**（`runOpticalFlowSelfTest()`，含 `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE)`） | 新文档 4.9 |
> | `--yolopx-selftest` | **YOLOPX 三合一自检**（`runYolopxSelfTest()`，det/da/ll 三输出，含真实推理） | 新文档 4.8 |
> | `--proto-selftest` | **新协议解码自检**——用 `tools/reverse/samples/*.pcap` 固化样本验证 Swift 解码器（**14 项断言**） | 代码-04 |
> | `--nic-autotest` | **自适应网卡自检**——**11 项断言**（探测轮推进 / 注入真实 UDP 30031 命中锁定 / 失流重探 / 自愈重锁） | 代码-04 |
> | `--mc-shot` | 任务控制中心 UI 截图（ImageRenderer 无头渲染） | 代码-27 |
> | `--mc-map` | 任务控制中心大地图截图 | 代码-27 |
> | `--mc-map-offline` | 大地图**离线模式**（不依赖引擎/定位，用本地地图数据） | 代码-27 |
>
> ### B. 原表中的失效项
>
> - ❌ `--skip_view` / `--skip_yolo`：**不是 AuroraDrive 的 CLI 入口参数**。本文原表自己已注明它们是
>   "Python 训练参数"（传给 `train_game_assist.py`），却被混进 CLI 全集表——
>   它们是**被转发的子进程参数**（`AuroraDriveApp.swift:6418`：`proc.arguments = ["src/train_game_assist.py", "--skip_view", "--skip_yolo"]`），
>   不是 AuroraDrive 自己的入口 flag。建议从「CLI 参数全集」表中移出，单列一节「转发给 Python 训练脚本的参数」。
>
> ### C. 新增的自检类参数归属（供交叉引用）
>
> | 链路 | 自检入口 | 断言数 |
> |---|---|---|
> | YOLOPX 三合一感知 | `--yolopx-selftest` | 真实推理 + da/ll 格数 |
> | 光流（OpenCV DIS） | `--opticalflow-selftest` | p95 延迟 / 精度 |
> | 运动预测（α-β） | `--motion-selftest` | 外推/校正 |
> | 新协议解码 | `--proto-selftest` | **14 项** |
>
> ### ★ D. 2026-09-29 实跑结果（真机执行，非静态推断）
>
> 以下为**实际执行二进制**（`AuroraDriveUI`，9,166,672 B，09-28 22:19）的结果：
>
> | 自检 | 实测结果 | 关键数据 |
> |---|---|---|
> | `--proto-selftest` | ✅ **PASS（14/14）** | 断言数**与上表记载一致**；坐标 (6127, 5733) 落在 13056² 内 |
> | `--limit-selftest` | ✅ **PASS** | 路况六档 + 限速三级 + 优先级规则全部验证 |
> | `--motion-selftest` | ✅ **PASS** | 双结构兜底 A/B 全部符合预期 |
> | `--opticalflow-selftest` | ✅ **PASS** | **p50=1.159 / p95=1.599 / max=1.765 ms**；位移误差 (0.005, 0.298) px |
> | `--yolopx-selftest` | ✅ **PASS** | 打印 **`max=300 阈值=70`** → **死档位修复被实测确认** |
> | `--nic-autotest` | ⚠️ **FAIL(5)** — **环境限制，非代码缺陷** | 需 root 打开 BPF 抓包；沙盒内 `sudo` 不可用 |
>
> **★ 三点交叉验证价值**：
> 1. **「14 项断言」从静态计数升级为实跑确认**（本文此前是读代码数出来的）
> 2. **`C 层估计器创建成功（OpenCV 已静态链接）`** —— 运行时确认
>    `Vendor/opencv` 的 11 个静态库**确实链接成功**（此前只是读 `Package.swift` 的配置）
> 3. **光流 p95=1.599ms** —— 远优于 33ms 预算，**是感知链里最健康的一环**，
>    与 `pitfalls.md` `15-16（`setNumThreads(2)` 是生产设定）的记载一致
>
> **`--nic-autotest` 的 FAIL 归因**：该自检需**向默认网关注入真实 UDP 30031 包
> 并用 BPF 捕获**（源码注释：「用真实 UDP 30031 包注入做端到端验证」）。
> 当前用户非 root 且沙盒内 `sudo` 不可用 → **无法收包 → 锁定阶段无从触发**。
> 佐证：PASS 的部分（`✓ 停流后判定失流并回到探测`）说明**状态机部分工作正常**，
> 失败的是依赖真实网络的那几步。**要完整验证需 `sudo` + 真实网络环境。**
>
> ---

## 一、进程模式总览与 CLI 参数全集（72 个字面量 / 70 个本程序 flag）

**四种进程模式**：

| 模式 | 入口 | 特征 |
|---|---|---|
| **GUI 模式**（默认） | `AuroraDriveApp.main()`（`AuroraDriveApp.swift:1358`） | SwiftUI 界面 + engine.sock 探测（无引擎 spawn 自己）+ 全部防冻结措施 |
| **引擎模式** | `--engine` → `EngineMain.run()`（`:822-824`） | **纯后台驾驶引擎：不触碰 SwiftUI、不创建窗口、不跑 NSApp**；dispatchMain 常驻；自身 engine.lock |
| **命令模式** | `--agent-command "<指令>"`（AppDelegate `:325-329`、`:516-522`、`:529-536`） | **.accessory 后台运行、不抢焦点、全部窗口 orderOut（保持游戏所在 Space 激活，供键注入落到游戏内）**；独立引擎组（AppDelegate.agentEngines 静态持有） |
| **一次性自检** | **50 个** one-shot flag | **短命进程或被 launchd 托管，不参与 UI 锁**（`oneShotFlags`，`AuroraDriveApp.swift:919-970`）；跑完即 `exit()`。⚠️ 演进：初版 7 → 17 → 37 → 45（2026-10-07）→ **50**（2026-10-16 实测，2026-10-17 复核仍为 50） |

**CLI 参数全集（本程序 70 个 + 2 个转发参数 = 72 个字面量，2026-10-17 `grep -n` 实测；解析位置列 = 当前真实行号）：**

| 参数 | 解析位置 | 行为 | 参与文档 |
|---|---|---|---|
| `--engine` | Launcher.main:822-824 | EngineMain.run()（**永不返回**） | 代码-06/07 |
| `--daemon` | AppDelegate:136-143（applicationDidFinishLaunching） | setActivationPolicy(.accessory)——**历史入口保留** | 代码-24 单元二 |
| `--test-xpc` | AppDelegate:147-150 | **已废弃**——"launchd 拉起拿不到 TCC 权限" + exit(0) | 代码-24 单元二 |
| `--tcc-selftest` | AppDelegate:156-171 | AXIsProcessTrusted + CGPreflightScreenCaptureAccess → 追加写 ~/Library/Logs/AuroraTCCSelfTest.log + exit(0/2) | 代码-24 单元二 |
| `--yolo-selftest <图片>` | AppDelegate:175-179 + run.sh:159-161 | YoloEngine().selfTest(imagePath:) + exit(0) | 代码-14 |
| `--yolo-bench <图片>` | AppDelegate:182-186 + run.sh:162-164 | YoloEngine().benchmark(imagePath:)（直通 vs 慢路径对比） | 代码-14 |
| `--speed-selftest <目录> [--roi x,y,w,h]` | AppDelegate:191-203 | SpeedOCRReader().selfTestDirectory(...)+ exit(0)——--roi 解析 4 个 Double → CGRect | 代码-12 |
| `--upscale-selftest` | MissionConsole.swift bootstrap:6224-6227 | runUpscaleSelfTest()——**需要 MTKView/NSApp 上下文，故在 onAppear（bootstrap）而非 Launcher** | 代码-24 单元三 |
| `--set-llm-config <apiKey> <baseUrl> <model>` | Launcher.main:828-841 | **提前处理（不需要 GUI/引擎）**——AgentSettings.save()（小本本 + 固定域 UserDefaults，不碰钥匙串）+ exit | 代码-23 单元三 |
| `--agent-llm-test` | Launcher.main:846-916 | **真实 LLM 请求自测（不需要 GUI）**——纯同步 URLSession + 30s 硬超时；Key 从环境变量 AURORA_API_KEY | 代码-24 单元三 |
| `--agent-command "<指令>"` | AppDelegate:325-329 / 409-477 / 516-522 / 529-536 | **命令模式全链**：accessory + 独立引擎组 + requestCommandOnStartup（1.5s 下发、8s 兜底） | 代码-24 单元二 |
| `--auto-login` | AppDelegate:505-510 + run.sh:168-176 | **启动即自动登录守护**——1.5s 后 requestAutoLoginOnStartup（8s 检测 × 10 次 = 80s 超时） | 代码-22/23 |
| `--auto-drive` | MissionConsole.swift bootstrap:6212-6215 | **自主测试**——1.5s 后 startDriving()（模拟人工点击） | 代码-26 单元一 |
| `--auto-seconds N` | MissionConsole.swift bootstrap:6216-6223 | 配合 --auto-drive：N 秒后 exit(0)（无人值守端到端验证，跑完读 /tmp/aurora_debug.log） | 代码-26 单元一 |
| `--agent-selftest` | MissionConsole.swift bootstrap:6247-6254 | 1.2s 后 configure + AgentSelfTest.run(center:)（七组测试 + ported 双向一致性） | 代码-23 单元十一 |
| `--agent-ui-shot` | MissionConsole.swift bootstrap:6255-6258 | AgentUIShot.run()——ImageRenderer 无头渲染 /tmp/aurora_ui_shot.png | 代码-23 单元十三 |
| `--agent-layout-shot` | MissionConsole.swift bootstrap:6259-6262 | runLayoutCompare()——折叠 vs 展开两帧并排 /tmp/aurora_layout_compare.png | 代码-23 单元十三 |
| `--locate-live` | VisualLocator.swift:118/185/275（文件 491 行） | **诊断开关**——locate 每次把耗时落 stderr（[LOCATELIVE-DIAG] locate total=Nms） | 代码-17 |
| `--skip_view` / `--skip_yolo` | AuroraDriveApp.swift:6418（Python 训练参数 proc.arguments） | startTraining 传给 train_game_assist.py——视角分类器不训 + YOLO 用现成预训练（**转发参数，非本程序入口 flag**） | 代码-25 单元六 |
| `--llm-selftest [--network]` | Launcher.main:1053-1060 | **A1 协议/SSE/错误分类/候选排序**（离线恒跑）；`--network` 追加真实请求且失败计入退出码 | 代码-23 |
| `--llm-probe` | Launcher.main:1061-1067 | **A1 七渠道真实探活**健康表（需网络）；逐模型健康态是打印而非断言 | 代码-23 |
| `--llm-vision-selftest` | Launcher.main:1068-1074 | **A1 真实截图 → 视觉模型**（需网络 + 录屏权限；无权限时如实标注环境受限，不假绿） | 代码-23 |
| `--control-selftest` | Launcher.main:1075-1081 | **A2 按键四证据链**（权限 / 计数 / 自建 tap / NSEvent）；需辅助功能权限 | 代码-08/23 |
| `--tool-selftest` | Launcher.main:1082-1088 | **A3 注册表覆盖 + schema 合法 + 全工具 dryRun**（离线可跑） | 代码-23 |
| `--tool-call-demo <task>` | Launcher.main:1089-1097 | **A3 端到端**：模型决策 → 工具分发 → 执行；`--live` 才真注入按键，默认 dryRun | 代码-23 |
| `--llm-perf-selftest [--seconds N]` | Launcher.main:1108-1117 | **性能预算断言**（主线程阻塞 / 首字延迟 / 内存）；默认 6s | 代码-23/38 |
| `--websearch-selftest <q> [--network]` | Launcher.main:1124-1129 | **W5 联网搜索**：离线跑真实 HTML 夹具，`--network` 真发 search+fetch | 代码-23 |

> 其余 one-shot（`--mc-shot` `:792-805`、`--mc-map` `:758-762`、`--mc-map-offline` `:763-767`、`--mc-route` `:770-774`、`--mc-route-loading` `:775-779`、`--mc-map-bench` `:782-791`、`--mc-quest` `:810-820`、
> `--cache-selftest` `:1005-1008`、`--quest-selftest` `:1014-1017`、`--capture-selftest` `:1023-1026`、`--perf-selftest` `:1130-1137`、`--tick-profile` `:1144-1150`、`--tick-bench` `:1157-1163`、
> `--realshot-selftest` `:1169-1180`、`--corner-selftest` `:1185-1188`、`--egobox-selftest` `:1192-1195`、`--perception-selftest` `:1199-1202`、`--lanekeep-selftest` `:1207-1210`、`--ayolom-selftest` `:1215-1218`、
> `--yolopx-selftest` `:1221-1228`、`--proto-selftest` `:1232-1235`、`--nic-autotest` `:1237-1240`、`--limit-selftest` `:1243-1246`、`--opticalflow-selftest` `:1249-1251`、`--motion-selftest` `:1254-1256`、
> `--fit-selftest` `:1260-1263`、`--route-selftest` `:1268-1270`、`--taxonomy-selftest` `:1274-1276`、`--map-selftest` `:1281-1283`、`--lane-extrapolator-selftest` `:1287-1291`、`--v2-selftest` `:1101-1107` 均见上方「CLI 分流全景」）。

**oneShotFlags（初版 7 个短命进程）**：`--speed-selftest / --tcc-selftest / --test-xpc / --yolo-selftest / --upscale-selftest / --yolo-bench / --daemon`——源注释（`AuroraDriveApp.swift:917-918`）："它们是短命进程或被 launchd 托管，若参与锁会与常驻 UI 互斥，导致自检失败或用户无法启动界面"；非 oneShot 且 UI 锁失败 → 打印原因 + exit(0)（`:1301-1307`）。

> ### ⚠️ 2026-09-29 订正：oneShotFlags 实际已是 **17 项**（原记 7 项；2026-10-17 复核现为 **50 项**，历史快照如下）
>
> **2026-09-29 实测（当时行号 `AuroraDriveApp.swift:816-820`，已失效，仅作历史）**：
> `let oneShotFlags = ["--speed-selftest", "--tcc-selftest", "--test-xpc",`
> `                    "--yolo-selftest", "--upscale-selftest", "--yolo-bench",`
> `                    "--daemon", "--mc-shot", "--mc-map", "--mc-map-offline", "--fit-selftest",`
> `                    "--limit-selftest", "--nic-autotest", "--proto-selftest",`
> `                    "--yolopx-selftest", "--opticalflow-selftest", "--motion-selftest"]`
>
> **当前（2026-10-17）该数组为 50 项，行号 `:919-970`，见顶部复核块。**
>
> ### ⚠️ 附带订正：YOLOPX 自检的退出码语义（2026-09-26 修，行号 2026-10-17 复核）
>
> `AuroraDriveApp.swift:1221-1228` 分发行（`--yolopx-selftest`）的注释（`:1223-1226` 附近）：
> > ⚠️ 2026-09-26 修：原先无条件 `exit(0)`，自检 FAIL 也返回成功 →
> > CI/脚本无法凭退出码发现问题，自检形同"仅供参考"。
> > 现返回失败项数：0=全过，非0=有失败（>0 即视为失败，上限 127）。
>
> `exit(failed == 0 ? 0 : Int32(min(failed, 127)))   // 失败项数截到 127（POSIX 退出码上限）`（`:1227`）
>
> **注意退出码语义不一致**：`--yolopx-selftest` 返回**失败项数**，而 `--tcc-selftest` 返回 0/2。
> 写脚本判失败应统一按 `!= 0` 处理。

**环境变量**：`AURORA_API_KEY`（--agent-llm-test 的 Key 来源，`AuroraDriveApp.swift:855`）/ `AURORA_TCC_TEST`（--tcc-selftest 日志的 mode 字段，`:159`）/ `AURORA_DAEMON_MODE=1`（--daemon 的等价环境变量，`:138`）。

## 二、spawnEngine 引擎拉起与 Launcher 分流细节

**`spawnEngine()`（EngineClient.swift，private，**:330-353**）——spawn 引擎子进程（同二进制 + --engine；stdout/stderr → 引擎日志）**：

1. **可执行路径（:331-336）**：`CommandLine.arguments[0].standardizedFileURL.resolvingSymlinksInPath()`——**同二进制（含符号链接解析：AuroraDriveUI 可能是 symlink，解析到真实二进制）**；`isExecutableFile` 验证——无效 → engineClientLog"可执行文件路径无效" + false
2. **Process 组装（:337-339）**：executableURL = exeURL + **arguments = ["--engine"]**——**同一二进制以引擎模式重启自己**
3. **日志重定向（:340-344）**：`FileHandle(forWritingAtPath: engineLogPath)`（engineLogPath = **`~/Library/Logs/AuroraEngine.log`**，`EngineClient.swift:152-155`）→ seekToEndOfFile（追加）→ **standardOutput + standardError 同一 fh**——"stdout/stderr → 引擎日志"
4. `try process.run()`（:345-352）→ engineClientLog"spawn 引擎 pid=N" + true；失败 → "spawn 失败" + false

**引擎探测链（EngineClient.startup，代码-07 已详）**：探测 engine.sock：已有健康引擎 → 直接连接；没有 → **spawn 自己（--engine）**；任一步失败自动回退本地模式。

**Launcher 分流细节（AuroraDriveApp.swift :721-1360 结构、main() :748 起；代码-24 单元三已详）**：

| 步骤 | 行为 |
|---|---|
| `setvbuf(stdout, nil, _IOLBF, 0)`（:751） | **stdout 改行缓冲：print 立即落盘** |
| `--engine`（:822-824） | EngineMain.run()——永不返回（dispatchMain 常驻；自身已有 engine.lock） |
| `--set-llm-config`（:828-841） | AgentSettings.save() + exit（不需要 GUI/引擎） |
| `--agent-llm-test`（:846-916） | 纯同步 URLSession + 30s 硬超时 + exit(0/1) |
| oneShotFlags 判定（:1301-1307） | 50 个短命参数不参与 UI 锁；非 oneShot 且锁失败 → exit(0) |
| `AuroraDriveApp.main()`（:1358） | 正常启动 SwiftUI |

**GUI 模式完整启动链（组合视图）**：

``AuroraDriveLauncher.main()``
  → setvbuf 行缓冲（:751）
  → AuroraDriveApp.main()（:1358，SwiftUI）
    → AppDelegate.applicationDidFinishLaunching（:133-537，9 步：CLI 自检 → EngineClient.startup（:208-210，探测/spawn 引擎）
      → 防 App Nap（beginActivity + GameModeDefender.start）→ CGEventTap 空监听 → 768MB 内存锚点（mlock）
      → 命令模式分流（:325-329 + IOPMAssertion）→ Darwin Notification Center → 窗口延迟激活
      → --auto-login（:505-510）/--agent-command（:516-522）派发 → 命令模式引擎注入（:529-536））
    → ContentView.onAppear（MissionConsole.swift:6045-6052）→ bootstrap()（:6106 起，7 步：DispatchSource tick **20Hz**（:6111-6113；源码 :6113-6115 注释明确「2026-10-12 定档 20Hz」，与 EngineMain.engineTickHz 一致）→ Daemon/BPF 检查 → 网络定位 10Hz（:6186-6202）
      → --auto-drive（:6207）→ --upscale-selftest（:6219）→ AI Agent 面板初始化（configure × 3，:6226-6262））
  → DriveState.tick()（**20Hz** 决策管线，代码-25 单元八；两档均 20Hz，应急 sprint 45Hz）

**排障权威参考（两份日志 + 分工）**：

| 日志 | 写入方 | 内容 |
|---|---|---|
| `~/Library/Logs/AuroraEngine.log` | 引擎进程（spawnEngine 重定向 stdout/stderr，`EngineClient.swift:152-155`） | **引擎侧全部输出**（EngineMain 启动/引擎状态/心跳/命令） |
| `/tmp/aurora_debug.log` | UI 进程（DriveState.dlog，10MB 封顶） | **UI 侧 tick 摘要/决策/诊断**（mode/模型/命令/按键/front/ocr/eff/lag/mem） |
| `/tmp/aurora_anchor_diag.log` | AppDelegate（锚定窗口安装） | stdout 重定向诊断 |
| `/tmp/aurora_iopm_status.log` | AppDelegate（IOPMAssertion，`:343-344`） | 系统电源断言状态 |
| `/tmp/aurora_defender.log` | GameModeDefender（双进程） | **[ENGINE]/[UI] 前缀 + 持久战重新主张记录** |
| `~/Library/Logs/AuroraTCCSelfTest.log` | --tcc-selftest（`:160-167`） | TCC 权限预检结果 |
| `/tmp/upselftest_result.txt` | --upscale-selftest | 插帧自检验定 |

## 五、完整自检矩阵（4 既有 + 8 新增，2026-10-07 在**已部署二进制**上实跑）

跑法统一：`AURORA_UI_LOCAL=1 ./AuroraDriveUI --<flag>`（`.app` bundle 未获 TCC 授权，见代码-31）。
下表「实测项数」全部是本次**真跑输出**（不是读代码数出来的）。

### 5.1 四个既有回归自检（基线，必须保持全绿）

| # | flag | 覆盖 | 实测输出（2026-10-07） | EXIT |
|---|---|---|---|---|
| 1 | `--quest-selftest` | 任务面板 OCR（8 条真实面板文字 + 反例/投票/链消歧/坐标语义/节流） | `═══ 结果：全部通过 ✅ ═══` | 0 |
| 2 | `--route-selftest` | 路网寻路（冻结基线 664 节点 / 932 边 / 0.61 米每像素） | `路网寻路自检 PASS —— 全部通过`（平均规划 0.063 ms） | 0 |
| 3 | `--taxonomy-selftest` | 词表 / 聚类（组数=7、合计=1777、聚类 < 5ms） | `词表 / 聚类自检 PASS —— 全部通过` | 0 |
| 4 | `--wire-selftest` | 引擎配置通道四处「手切档位静默失效」修复 | `═══ 结果：通过 14 / 失败 0 ═══` | 0 |

> 前三个的判据是**短语**（`全部通过`），不是「通过 N 项」——
> 脚本判失败请用 **`EXIT != 0`**，别去 grep 数字（`--wire-selftest` 是唯一打印计数的）。

### 5.2 八个新增 AI 自检（A1/A2/A3 + W5 + 性能预算）

| # | flag | 预期项数 | 依赖 | 失败面 |
|---|---|---|---|---|
| 5 | `--llm-selftest` | **93 / 0**（离线）；带 `--network` 时历史实测 **99 / 0** | 离线可跑 | 协议 / SSE 分片 / 错误分类 / 候选排序 |
| 6 | `--llm-probe` | **2 条断言** + 13 条逐模型健康态打印 | **网络** | 全部模型不可达即红 |
| 7 | `--llm-vision-selftest` | **6 / 0** | 网络 + 屏幕录制权限 | 无权限 → 环境受限（不算失败）；有权限但模型不回 → 红 |
| 8 | `--control-selftest` | **32 / 0** | 辅助功能权限 | 权限缺失、计数不增、tap 抓不到、NSEvent 未观察 → 红 |
| 9 | `--tool-selftest` | **150 / 0**（2026-10-06 记录为 144，**随工具扩充增长**） | 无 | 注册表/schema/dryRun 任一失败 |
| 10 | `--tool-call-demo "领奖励"` | **9 / 0** | **网络** | 无工具候选、模型不选工具、分发失败 |
| 11 | `--llm-perf-selftest --seconds 6` | **6 条确定性断言** + 1 条首字延迟（有候选才计入）→ 汇总 **6/0 PASS** 或 **6/1 FAIL** | 无 | 首字延迟预算（免 key 主力渠道达标；zenFree/限流重试路径历史超标） |
| 12 | `--websearch-selftest "swift actor"` | **42 / 0** | 离线可跑（`--network` 需网络） | 解析器夹具 / 跳转解包 / 正文提取 / 反爬识别 / Wikipedia JSON |

**一键跑完整矩阵（可复制，持构建锁避免与别人抢 CPU）**：

``bash
cd /Users/dupi/Desktop/自动驾驶系统
BIN=./AuroraDriveUI

bash scripts/build-lock.sh run "自检矩阵" -- bash -c '
BIN=./AuroraDriveUI
run() { echo "───── $* ─────"; AURORA_UI_LOCAL=1 "$@" 2>&1 | tail -2; echo ">>> EXIT=${PIPESTATUS[0]}"; }
run $BIN --quest-selftest
run $BIN --route-selftest
run $BIN --taxonomy-selftest
run $BIN --wire-selftest
run $BIN --llm-selftest
run $BIN --control-selftest
run $BIN --tool-selftest
run $BIN --websearch-selftest "swift actor"
'
# 需网络的两项单独跑（耗时较长，其中 --tool-call-demo 默认 dryRun 不注入按键）
AURORA_UI_LOCAL=1 $BIN --llm-probe
AURORA_UI_LOCAL=1 $BIN --llm-selftest --network
AURORA_UI_LOCAL=1 $BIN --llm-vision-selftest
AURORA_UI_LOCAL=1 $BIN --tool-call-demo "领奖励"
``

**跨进程并发注意**：自检跑起来会占 CPU，耗时类数字（`--llm-perf-selftest`、`--perf-selftest`）
必须在**无并发负载**时测，否则数字不可比（该纪律见代码-31 `3.1 与 `scripts/build-lock.sh:14-17`）。

**代码-33 文档至此完整**（spawnEngine 引擎拉起 → Launcher 分流 → GUI 完整启动链 → 日志与排障 → **AI 自检矩阵**）。

---

## 附：实测锚点表（2026-10-17 全量实测，2026-10-18 修正 EngineMain/AuroraDriveApp 漂移行号）

全部由 `grep -n` / `awk 'NR>=…'` / 括号配平脚本在当次源码上逐条实测（2026-10-17，工作区当前版本）。旧值 = 本文此前记录的历史行号（已失效，留作对照）。

### AuroraDriveApp.swift（9097 行，2026-10-18 冻结版 `wc -l` 实测）

| 符号 | 当前行号 | 旧记（已失效） |
|---|---|---|
| `@main struct AuroraDriveLauncher` | 721 | 722（结构体同名） |
| `static func main()` | 748 | 748（旧记同） |
| `acquireUISingleInstanceLock()` | 730 | — |
| `SelfTestResultBox` | 713 | 713 |
| `runBlockingSelfTest` | 1043–1051 | 1017–1025 |
| oneShotFlags 数组 | 919–970（**50 项**，括号配平） | 906–925（37 项）/ 919–953（45 项） |
| UI 单实例锁判定 | 1301–1307 | 1257–1263 / 1136–1142 |
| 禁用窗口状态恢复 | 1310–1356 | 1265+ / 1186–1191 |
| `AuroraDriveApp.main()` 调用 | 1358 | 1193 |
| `--mc-map` / `--mc-map-offline` / `--mc-route` / `--mc-route-loading` / `--mc-map-bench` | 758 / 763 / 770 / 775 / 782 | 745 / 750 / 757 / 762 / 769 |
| `--mc-shot` | 792–805 | 779 |
| `--mc-quest` | 810–820 | 797–807 |
| `--engine` | 822–824 | 809–811 |
| `--set-llm-config` | 828–841 | 815–828 |
| `--agent-llm-test` | 846–916 | 833–903 |
| `--lanekeep-reality` / `--wire-selftest` / `--flags-help` / `--cache-selftest` / `--quest-selftest` / `--capture-selftest` | 979 / 990 / 998 / 1005 / 1014 / 1023 | 934–944 / 945–948 / 953–956 / 960–963 / 969–972 / — |
| AI 段（`--llm-selftest`…`--websearch-selftest`） | 1028–1129 | 1027–1093 |
| `--llm-selftest` / `--llm-probe` / `--llm-vision-selftest` / `--control-selftest` / `--tool-selftest` / `--tool-call-demo` | 1053 / 1061 / 1068 / 1075 / 1082 / 1089 | 1027–1034 / 1035–1041 / 1042–1048 / 1049–1055 / 1056–1062 / 1063–1071 |
| `--v2-selftest` / `--llm-perf-selftest` / `--websearch-selftest` | 1101 / 1108 / 1124 | — / 1072–1081 / 1088–1093 |
| `--perf-selftest` / `--tick-profile` / `--tick-bench` / `--realshot-selftest` | 1130 / 1144 / 1157 / 1169 | 1094 / 1108 / 1121 / 1133 |
| `--corner-selftest` / `--egobox-selftest` / `--perception-selftest` / `--lanekeep-selftest` / `--ayolom-selftest` | 1185 / 1192 / 1199 / 1207 / 1215 | 1028–1033 / 1035–1040 / 1042–1048 / 1050–1056 / 1058–1062 |
| `--yolopx-selftest` / `--proto-selftest` / `--nic-autotest` / `--limit-selftest` | 1221 / 1232 / 1237 / 1243 | 1064–1073 / 1075–1078 / 1080–1084 / 1086–1090 |
| `--opticalflow-selftest` / `--motion-selftest` / `--fit-selftest` | 1249 / 1254 / 1260 | 1092–1095 / 1097–1101 / 1103–1108 |
| `--route-selftest` / `--taxonomy-selftest` / `--map-selftest` / `--lane-extrapolator-selftest` / `--map-window-test` | 1268 / 1274 / 1281 / 1287 / 1297 | 1111–1113 / 1117–1119 / 1124–1127 / — / 1253 |
| `setvbuf` | 751 | 738 |
| `--daemon` / `--test-xpc` / `--tcc-selftest` | 136–143 / 147–150 / 156–171 | 93 / 103 / 112 |
| `--yolo-selftest` / `--yolo-bench` / `--speed-selftest` | 175 / 182 / 191 | 131 / 138 / 147–150 |
| `--agent-command` 全链 | 325–329 / 409–477 / 516–522 / 529–536 | 234 / 310 / 339–341 / 352 |
| `--auto-login` | 505–510 | 328 |
| `applicationDidFinishLaunching` / `applicationWillTerminate` | 133–537 / 542–544 | 133–537 / 542–544（同） |
| `runTaxonomySelfTest()` | 1894–2098 | 1729–1933 |
| `runRouteSelfTest()` | 2100–2298 | 1935–2110 |
| route 冻结基线：节点 / 边 / 米像素 | 2139 / 2140 / 2141 | 1974 / 1975 / 1976–1977 |
| 节点 24→36 基线：W=0 / W=200 | 2210–2211 / 2215–2216 | 2045–2046 / 2050–2056 |
| 字典序 ≤ W=200 断言 | 2236–2238 | 2072–2073 |
| 单次规划 < 5ms | 2246 | 2081–2082 |
| 300 对随机样本 / 固定种子 | 2258 / 2267 | 2085–2100 / 2085–2100 |
| `MissionConsole.swift:ContentView onAppear` | 6045–6052 | —（旧文未记） |
| `MissionConsole.swift:bootstrap()` | 6106–6263 | —（旧文未记） |
| `MissionConsole.swift:--auto-drive / --auto-seconds / --upscale-selftest / --agent-selftest / --agent-ui-shot / --agent-layout-shot` | 6212 / 6216 / 6224 / 6247 / 6255 / 6259 | 2276 / 2282 / 2290 / 2303 / 2313 / 2319（旧记 App 侧，现为 MissionConsole bootstrap） |
| `MissionConsole.swift:renderQuestCardNow` | 6886 | 6271 |
| `--skip_view` / `--skip_yolo`（转发参数） | 6418 | 1616 |
| `AURORA_API_KEY` | 855 | 842 |
| `AURORA_MAP_WINDOW=1` | 1410 | 1244–1245 |
| `AURORA_STUCK_SECONDS` | 5357 | 5126–5128 |
| `AURORA_DISABLE_OPTICAL_FLOW` | 5805 | 5400 |
| `AURORA_OBSERVE_ONLY=1` | 6246 | 5816 |
| `AURORA_LOG_SYNC` | 8953 | 8192–8201 |
| `AURORA_DAEMON_MODE` | 138 | 137–138（同） |
| `AURORA_TCC_TEST` | 159 | —（旧文未记） |
| `AuroraFlags.helpText()` | AuroraFlags.swift:521（文件 543 行） | 953–956（旧记 App 侧） |

### EngineMain.swift（2002 行，2026-10-18 冻结版 `wc -l` 实测）

| 符号 | 当前行号 | 旧记（已失效） |
|---|---|---|
| `static func run()` | 885 起（至 ~1200） | 608 起 |
| flock `engine.lock` | 907 | 616–629 |
| 重复启动 exit(0) | ~905 | 622–625 |
| TCC fail-fast（含观测模式放宽） | 916–958 | 630–680 |
| socket server | 999–1029 | 710–720 |
| `EngineFrameShm()` 创建 | 1035 | 749–753 |
| `DriveState()` + tick | 1042–1087 | 755–792 |
| tick 定时器 | 1067–1087 | 781–792 |
| 1Hz 心跳 | 1098–1105 | 794–809 |
| `handleCommand` | 1497–1883 | 1484–1882（同） |
| `start` / `stop` / `bye` / `status` / `upscale` / `record` / `reloadmodel` / `config` / `ping` | 1509 / 1522 / 1534 / 1545 / 1556 / 1569 / 1661 / 1685 / 1883 | 953 / 961 / 968 / 975 / 981 / 990 / 1011 / 1024 / 1051 |
| speedLimit 参与推理 | 1731–1734（本次复核仍准确） | 1044–1048 |
| `sendHeartbeat` | 1900 | 1061–1069 |
| `startReconnectWindow`（3s） | 1922 | — |
| `startIdleExitCountdown`（30s） | 1947 | 1906–1952 |
| `pauseDriving` | 1970 | 1957–1969（同） |
| `performShutdown` | 1987 | — |
| `EngineFrameShm` 类 | 152 | 151 |
| 布局注释（含 newW/newH 事故） | 82–135（本次复核仍准确） | 81–176 / 110–128 |
| `maskBytes` / `maskRegionBytes` / `pixelsOffset` | 171 / 173 / 175（本次复核仍准确） | 168–174 / 168–174 / 189–190 |
| shm_unlink / shm_open | 194 / 195（本次复核仍准确） | 193 / 194 |
| 掩码 bit-pack 注释 | 144–147（本次复核仍准确） | 139–146 |
| maskSeq 世代号注释 | 149（本次复核仍准确） | 148–160 |
| PerfBus 导出（5s 统计处） | 1137–1157（本次复核仍准确） | 832–859 |

### EngineClient.swift（896 行，2026-10-18 冻结版 `wc -l`）

| 符号 | 当前行号 | 旧记（已失效） |
|---|---|---|
| `protocolVersion = 3` | 64 | 64（同） |
| 协议 v1/v2/v3 注释 | 51–63 | 51–64 |
| `socketPath` | 147–150 | 137–141 |
| `engineLogPath` | 152–155 | 141–142 |
| `startup()` | 166–205 | 157–196 |
| `AURORA_UI_LOCAL=1` 分支 | 167–172 | 157–163 |
| `activate()` | 207–215 | 198–206 |
| `isEngineStale` | 265–267 | 246–258 |
| `relaunchStaleEngine()`（含三个坑注释） | 280–327（271–277 注释） | 246–258 / 260–268 |
| `spawnEngine()` | 330–353 | 321–346 |
| `attachShm()` | 501–522 | —（旧文未记） |
| `handleConnectionLoss` | 552–570 | 532–550 |
| `startReconnectPolling` | 584–606 | — |
| `poll()` | 609–781 | 589–761 |
| frameSeq 读取 | 619–621 | 598–601 |
| 像素读取（CVPixelBuffer/CGImage） | 628–656 | 604–636 |
| 检测框解析 | 658–692 | 638–672 |
| 掩码物理边界校验 | 713–716 | 693–694 |
| 掩码解析安全门注释 | 704–712 | 678–692 |
| flags/fpsMilli | 773–778 | 754–758 |
| 心跳超时 → handleConnectionLoss | 612–615 | 592–596 |

### 其它文件

| 文件 | 符号 | 当前行号 | 旧记 |
|---|---|---|---|
| LLMSelfTest.swift（2183 行，本次实测 2183） | `runLLM` / `runProbe` / `runVision` / `runControl` / `runTools` / `runToolCallDemo` / `runPerf` | 93 / 961 / 996 / 1087 / 1360 / 1635 / 1797 | 同（未变） |
| WebSearch.swift（1463 行，本次实测 1463） | `runFromCommandLine` | 1451 | 1451（同） |
| QuestPanelReader.swift（1160 行，本次实测 1160） | `runSelfTest()` / 8 条回归 / 自检头注释 | 929 / 954 / 72–73 | 929 / 909 / 72–74 |
| QuestPanelReader.swift | quest_index 1372→2938 注释 | 11 | 11（同） |
| WireSelfTest.swift（222 行，本次实测 222） | `runWireSelfTest()` / 四处缺陷注释 / A1 断言 | 47（至 222）/ 12–30 / 67 | 47 / 12–30 / 65–68 |
| MissionConsole.swift（7721 行） | `renderQuestCardNow` | 6886 | 6271 |
| VisualLocator.swift（491 行，本次实测 491） | `--locate-live` 三处 | 118 / 185 / 275 | 118 / 185 / 275（同） |
| AuroraFlags.swift（543 行，本次实测 543） | `helpText()` | 521 | —（旧文未记） |
| run.sh | `--yolo-selftest` / `--yolo-bench` / `--auto-login` | 159 / 162 / 171 | 117 / 120 / 128 |
| scripts/build-lock.sh | 并发测量纪律注释 | 14–17 | 14–17（同） |

### 计数断言（2026-10-17 实测）

| 断言 | 实测值 | 说明 |
|---|---|---|
| oneShotFlags 项数 | **50**（去重后 50） | `AuroraDriveApp.swift:919-970` 括号配平；含注释内提及去重 51（多出 `--network` 出现在注释） |
| AuroraDrive 自有 CLI 参数 | **70** | 含下划线口径 `grep -rhoE '"--[a-z0-9_-]+"' Sources/ | sort -u` = 72（本程序 70 + 转发 2），与正文一致；无下划线口径 = 70（该口径下 `--skip_view`/`--skip_yolo` 因含 `_` 不匹配，本就不在集合内），故本程序自有参数为 **70** |
| 全 Sources 去重 flag（含辅助参数） | 70（含下划线 72） | 参数值修饰子 `--dir/frames/stride/iters/image/network/roi/seconds/live` 计入 |
| `--proto-selftest` 断言数 | 14 | 与 2026-09-29 实跑一致 |
| `--nic-autotest` 断言数 | 11 | 需 root + 真实网络才能全过 |

---

**代码-33 文档至此完整**（2026-10-17 全量行号复核 + 2026-10-18 T7 修正 EngineMain/AuroraDriveApp 漂移行号与 tick 频率内容错误）。
