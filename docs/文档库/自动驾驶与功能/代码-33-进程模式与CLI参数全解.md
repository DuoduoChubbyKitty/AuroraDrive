# 代码-33 进程模式与 CLI 参数全解

> ### ⚠️ 2026-10-06 复核块（自检家族 / `--mc-*` 夹具 / 双进程引擎交接，逐行实测）
>
> 本次基于当前工作区快照（`AuroraDriveApp.swift` **8335 行** / `EngineMain.swift` **1154 行** /
> `EngineClient.swift` **875 行** / `WireSelfTest.swift` 222 行 / `QuestPanelReader.swift` 1160 行 /
> `MissionConsole.swift` 7101 行）逐条打开源码核对。**下文旧正文的行号与部分事实已过时**，
> 以本块为准；旧正文保留作历史机制描述。
>
> ## ★ 一、CLI 分流全景（`AuroraDriveApp.swift` Launcher `main()`，:735-1193）
>
> 分流顺序（全部实测）：`setvbuf`（:738）→ `--mc-map`（:745）→ `--mc-map-offline`（:750）→
> `--mc-route`（:757）→ `--mc-route-loading`（:762）→ `--mc-map-bench`（:769）→ `--mc-shot`（:779）→
> `--mc-quest`（:797-807）→ `--engine`（:809-811，`EngineMain.run()` 永不返回）→
> `--set-llm-config`（:815-828）→ `--agent-llm-test`（:833-903）→ oneShotFlags 数组定义（:906-925）→
> `--lanekeep-reality`（:934-944）→ `--wire-selftest`（:945-948）→ `--flags-help`（:953-956）→
> `--cache-selftest`（:960-963）→ `--quest-selftest`（:969-972）→ `--perf-selftest`（:973-984）→
> `--tick-profile`（:987-998）→ `--tick-bench`（:1000-1010）→ `--realshot-selftest`（:1012-1026）→
> `--corner-selftest`（:1028-1033）→ `--egobox-selftest`（:1035-1040）→ `--perception-selftest`（:1042-1048）→
> `--lanekeep-selftest`（:1050-1056）→ `--ayolom-selftest`（:1058-1062）→ `--yolopx-selftest`（:1064-1073）→
> `--proto-selftest`（:1075-1078）→ `--nic-autotest`（:1080-1084）→ `--limit-selftest`（:1086-1090）→
> `--opticalflow-selftest`（:1092-1095）→ `--motion-selftest`（:1097-1101）→ `--fit-selftest`（:1103-1108）→
> `--route-selftest`（:1111-1113）→ `--taxonomy-selftest`（:1117-1119）→ `--map-selftest`（:1124-1127）→
> `--map-window-test`（:1132-1134）→ UI 单实例锁判定（:1136-1142）→ 禁用窗口状态恢复（:1186-1191）→
> `AuroraDriveApp.main()`（:1193）。
> 除 `--engine` 外全部 one-shot：跑完即 `exit()`，不参与 UI 锁（:904-905 注释）。
>
> **oneShotFlags 现为 37 项**（:906-925 实测展开计数；2026-09-29 记录的 17 项之外又新增 20 项）：
> `--corner-selftest`、`--perf-selftest`、`--tick-profile`、`--tick-bench`、`--realshot-selftest`、
> `--egobox-selftest`、`--ayolom-selftest`、`--lanekeep-selftest`、`--perception-selftest`、
> `--wire-selftest`、`--lanekeep-reality`、`--route-selftest`、`--taxonomy-selftest`、`--mc-route`、
> `--mc-route-loading`、`--mc-map-bench`、`--flags-help`、`--cache-selftest`、`--quest-selftest`、`--mc-quest`。
> 注释两处 ⚠️ 强调数组**手写维护**，漏登记会被 UI 单实例锁挡掉（:919-921、:923-925）——
> 新夹具的 `if args.contains(...)` 分支若写在 :1136 判定之后即被锁挡掉，症状是打印
> 「已有 AuroraDrive 实例在运行」退出（:1138-1141）。
>
> `--mc-*` 无头出图必须在 Launcher 无 GUI 阶段同步跑完：截图是纯离屏 ImageRenderer 渲染，
> 放 onAppear 里无窗口时 view 不 layout → 永不触发、进程卡 240s（:742-744 注释）。
>
> ## ★ 二、selftest 家族重点（2026-10-06 实测）
>
> | 夹具 | 入口 | 要点 |
> |---|---|---|
> | `--quest-selftest` | :969-972 → `QuestPanelReader.runSelfTest()`（`Inference/QuestPanelReader.swift:929`） | `models/quest_index.json`：1372 精确文本 → 2938 带坐标目标（`QuestPanelReader.swift:11`）；8 条真实面板文字回归（:909、:954）+ 假阳性反例/投票/链消歧/坐标语义/ROI 提示行过滤（:72-74）；纯索引+纯函数无窗口可跑（:69） |
> | `--taxonomy-selftest` | :1117-1119 → `runTaxonomySelfTest()`（:1729-1933） | 组数=7（:1743）；explore 450 / resource 1045 / travel 28 / monster 254 / shop 0 / service 0 / landmark 0（:1764-1772）；合计=1777（:1793-1794）；1777 全有组（:1810-1811）；**前置防假绿** `!MapDatabase.markers.isEmpty`（:1774-1775） |
> | `--route-selftest` | :1111-1113 → `runRouteSelfTest()`（:1935-2110） | **冻结基线：节点 664（:1974）/ 边 932（:1975）/ 0.61 米每像素（:1976-1977）**；节点 24→36：W=0 距离 5.78 km 拐弯 30（:2045-2046），W=200 距离 6.51 km 拐弯 12（:2050-2056）；字典序 ≤ W=200（:2072-2073，旧等式是巧合已修正）；规划 <5ms（:2081-2082）；300 对随机样本全可达，固定种子 0x5DEECE66D 且**不再对节点数取模**（:2085-2100） |
> | `--wire-selftest` | :945-948 → `runWireSelfTest()`（`Core/WireSelfTest.swift:47`） | 2026-10-02 四处「手切档位静默失效」缺陷的行为级验证（`WireSelfTest.swift:12-30`）；不做源码字符串匹配（:32-33）；**必须 `AURORA_UI_LOCAL=1`**（:36，A1 用例依赖本地模式必然未连引擎，:65-68） |
> | `--mc-quest` | :797-807 | 「当前任务」卡片离屏出图（task-2 验收）；必须走真实 ViewportPanel——`MissionControlShot.renderQuestCardNow(canvas:)`（`MissionConsole.swift:6271`，默认 1470×560），塞 questName + 真实世界坐标，不依赖 OCR 跑通（:794-796 注释） |
>
> 退出码约定：失败项数 `exit(failed == 0 ? 0 : min(failed, 127))`（:946、:962、:971 等）；
> 例外：`--proto-selftest` / `--nic-autotest` / `--limit-selftest` / `--fit-selftest` 无条件 `exit(0)`
> （:1075-1108，实际断言强度**未验证**）。
>
> ## ★ 三、双进程引擎交接（2026-10-06 全量实测）
>
> ### 3.1 生命周期
> 1. UI 启动：`AppDelegate.applicationDidFinishLaunching`（:133-537）→ `EngineClient.shared.startup()`
>    （`AuroraDriveApp.swift:208-210`；daemon 模式跳过，:137-146）。
> 2. 探测（`Core/EngineClient.swift:157-196`）：先连 `~/Library/Application Support/AuroraDrive/engine.sock`
>    （socketPath :137-141）→ 成功 `activate()`（:198-206）；失败 `spawnEngine()`（:321-346）——
>    **同二进制 + `--engine`**，stdout/stderr 重定向到 **`~/Library/Logs/AuroraEngine.log`**
>    （engineLogPath :141-142，旧正文写的 `/tmp/aurora_engine.log` 已过时）；每 0.3s 轮询重连、
>    20 次（6s）超时回退本地模式（:174-196）。
> 3. 引擎侧 `EngineMain.run()`（`Core/EngineMain.swift:608` 起）：flock `engine.lock`（:616-629，
>    重复启动 `exit(0)` :622-625）→ TCC fail-fast（:630-680；观测模式 `AURORA_OBSERVE_ONLY=1`
>    放宽为只查 screen）→ socket server（:710-720）→ `EngineFrameShm()` 共享内存（:749-753）→
>    `DriveState()` + 30Hz tick（:755-792，tick 定时器 :781-792）→ 1Hz 心跳（:794-809）。
> 4. 回退：任一步失败 → 本地模式；`AURORA_UI_LOCAL=1` 则连「想连引擎」都不成立
>    （`EngineClient.swift:157-163`，`wantsEngineMode=false`）。
> 5. UI 退出 `applicationWillTerminate` → `sendByeSync()`（`AuroraDriveApp.swift:542-544`）→
>    引擎 `pauseDriving`：释放按键、停录制，但保持抓屏推理等重连（`EngineMain.swift:1122-1134`）；
>    异常断开有 3s 重连窗口 + 30s 无人使用自动退出（:1070-1114）。
>
> ### 3.2 通道一：UNIX socket（控制面，JSON 行协议）
> - 命令 `EngineMain.handleCommand`（`EngineMain.swift:944-1056`）：
>   `start`(:953) / `stop`(:961) / `bye`(:968，只 pauseDriving 不退出) / `status`(:975) /
>   `upscale`(:981，决定发全分辨率还是缩略帧) / `record`(:990) / `reloadmodel`(:1011) /
>   `config`(:1024，携带 sport/controlDisabled/forceRule/expert/glyph/degradeThreshold/speedLimit，
>   speedLimit 直接参与推理 :1044-1048) / `ping`(:1051)。
> - 心跳 1Hz `sendHeartbeat`（:1061-1069）：fps / detections（**计数**）/ isDriving / isStreaming /
>   mode / modeRaw / speed / speedKmh / confidence / recording / frames / **proto** / pid。
> - 协议版本 `protocolVersion = 3`（`EngineClient.swift:64`）：v1 原始五命令、v2 加
>   record/reloadmodel/config + 心跳 recording/frames/proto、v3 加共享内存掩码区
>   （pixelsOffset 20480→28672）（:51-64 注释）。**版本守卫** `isEngineStale` 必须以
>   `sawHeartbeat` 为前提——旧引擎根本不发 proto 字段（:246-258）；
>   `relaunchStaleEngine()` 真 kill（bye 无效）→ 等死透 → 重启，且必须重置 sawHeartbeat，
>   三个坑记录在 :260-268 注释。
>
> ### 3.3 通道二：POSIX 共享内存（数据面，`/aurora_frame_v1`）
> - 引擎 `EngineFrameShm`（`EngineMain.swift:151`）是唯一创建者与写入者（启动 `shm_unlink`
>   清残留 :193，`O_CREAT|O_RDWR` :194）；UI 只读映射 `O_RDONLY + PROT_READ`
>   （`EngineClient.swift:483, 491`）。
> - 布局（`EngineMain.swift:81-176` 注释 + 常量实测）：头部 0-4095——magic "AURF"@0、
>   version@4、headerSize=4096@8、detOffset@12、detCapacity@16、detStride@20、frameWidth@24、
>   frameHeight@28、generation@32、**activePage@36**、**frameSeq@40**、timestampNs@48、
>   detectionCount@56、flags@60（bit0 isDriving / bit1 isStreaming）、fpsMilli@64、enginePid@68、
>   pageSize@72、**maskSeq@80**、maskW/H@88/92、laneW/H@96/100、maskFlags@104、
>   letterbox ratio/padX/padY/srcW/srcH@108-124、**newW/newH@128/132**（2026-09-28 补传）。
>   检测区 4096-20479（256 条 × 64B：labelId/conf/cx,cy,w,h/rawName 16B）；
>   掩码区 20480 起——da 网格 3200B（160×160 bit-pack，每行 20B）+ ll 网格 3200B
>   （`maskBytes = 3200`，`maskRegionBytes = 6400`，:168-174）；像素区 **28672** 起
>   双缓冲页 A/B（BGRA，max 4096×2304×4/页，总长 = pixelsOffset + pageMax×2，:189-190）。
> - 掩码 bit-pack：25600B/份 → 3200B/份，30Hz 下省 1.5MB/s 无谓拷贝（:139-146 注释）；
>   掩码用世代号 `maskSeq` 判新鲜、只在变化时重写——YOLOPX 15Hz vs tick 30Hz（:148-160 注释）。
> - UI 消费 `EngineClient.poll()`（每 tick 调用，`EngineClient.swift:589-761`）：
>   ① 读 `frameSeq@40`，无变化返回缓存（:598-601）；② 像素按 `activePage@36`+`pageSize@72`
>   定位，插帧开 → CVPixelBuffer 喂 MetalGoose，否则 CGImage 直绘（:604-636）；③ 检测框
>   `detectionCount@56` 上限 256 逐条 64B 解析（:638-672）；④ 掩码 `maskSeq@80` 变化才解析，
>   且**物理边界校验** `shmSize >= maskRegionEnd` 才敢读掩码区（:693-694）——防旧引擎
>   SIGSEGV 的最后一道防线（版本守卫在 tickEngineMode 里的位置晚于 poll，先读后查来不及拦，
>   :678-692 注释）；⑤ flags@60 → isDriving/isStreaming、fpsMilli@64 → engineFPS（:754-758）。
> - 心跳超时 3s → `handleConnectionLoss`（:592-596 调用，实现 :532-550）：关 socket、
>   isActive=false 回落本地模式。
> - **单向性**：共享内存只承载「引擎→UI」帧/检测/掩码；UI→引擎只有 socket 命令。
>   UI 在引擎模式下的显示数据全部镜像自 EngineClient（`AuroraDriveApp.swift:4040, 4768-4775,
>   4876-4877, 4903, 5465-5487`）。
>
> ### 3.4 三个踩坑实录（代码注释逐条核实）
> 1. **新增夹具忘登记 oneShotFlags** → 被 UI 单实例锁静默挡掉（:906-925 手写数组 +
>    :1136-1142 判定；`--quest-selftest` / `--mc-quest` 就是 2026-10-06 补登记的，:923-925）。
> 2. **协议/布局变更不升 protocolVersion** → 新 UI 按新偏移读旧引擎掩码区会读到 mmap 之外
>    直接 SIGSEGV（`EngineClient.swift:678-694` 注释 + 物理边界校验）；版本守卫必须以
>    `sawHeartbeat` 为前提（:246-258）。
> 3. **newW/newH 补传但不守卫事故**（2026-09-28）：MaskOverlay 绘制守卫用了 `metrics.newW > 0`，
>    但协议头从来没传过 newW/newH → 引擎模式掩码一格都不画（`EngineMain.swift:110-128` 注释）；
>    本地模式走 `yolopxEngine.metrics` 一切正常 → **本地自检永远发现不了**，bug 只在双进程暴露。
>    修复双保险：①协议 128/132 真正补传（旧客户端不读，向后兼容）②同时去掉 MaskOverlay 对
>    newW 的守卫依赖（绘制数学本就不用它）。
>
> ## ★ 四、环境变量速查（行号实测）
> `AURORA_UI_LOCAL=1`（`EngineClient.swift:157-163`）、`AURORA_API_KEY`（`AuroraDriveApp.swift:842`）、
> `AURORA_MAP_WINDOW=1`（:1244-1245，仅供无人值守自动化验证）、`AURORA_STUCK_SECONDS`（:5126-5128）、
> `AURORA_DISABLE_OPTICAL_FLOW`（:5400）、`AURORA_OBSERVE_ONLY=1`（:5816 + `EngineMain.swift:637-680`）、
> `AURORA_DAEMON_MODE`（:137-138）、`AURORA_LOG_SYNC`（:8192-8201）、`AURORA_MAP_LEGACY_MARKERS=1`
> （`--mc-map-bench` A/B 用，:767-768 注释）、`AURORA_AYOLOM=1`（`--ayolom-selftest` 必需，:1055-1057 注释）。
> 全表权威来源：`--flags-help` → `AuroraFlags.helpText()`（:953-956）。

> 覆盖源文件：AuroraDriveApp.swift Launcher/main()（**现为 527–875 行区间；文档原写 527–672**）+ EngineMain.swift（**1153 行**，2026-10-02 `wc -l` 实测；原文写 1082 行**，原写 314）+ EngineClient.swift spawnEngine（**现为 291–314 行区间内；文件实测 747 行**，原写 314）+ VisualLocator.swift --locate-live（**491 行**，原写 275）+ 各自检入口。基于当前仓库逐单元编写。grep 全 Sources 实测 **29 个 CLI 参数**（原文写 86 处引用）。
>
> ---
>
> ## ⚠️ 2026-09-29 复核追加：CLI 参数实测 **29 个**（本文原表缺 10 个）
>
> **实测方法**：`grep -rhoE '"--[a-z0-9-]+"' Sources/ | sort -u` → **29 个参数**。
> 本文原表只列了 20 个，且含 1 个**已不存在**的 `--skip`。
>
> ### A. 本文原表缺失的 10 个参数（★ 全部为新增，需补登）
>
> | 参数 | 行为 | 归属 |
> |---|---|---|
> | `--fit-selftest` | 自适应缩放自检（`runFitSelfTest()`，App 层） | 代码-26 |
> | `--limit-selftest` | 限速逻辑自检（三级刹车/SpeedLimitGuard 链路） | 代码-29 |
> | `--motion-selftest` | **运动预测自检**（`runMotionSelfTest()`，α-β 滤波 + 光流补帧） | 新文档 4.9 |
> | `--opticalflow-selftest` | **光流自检**（`runOpticalFlowSelfTest()`，含 `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE)`） | 新文档 4.9 |
> | `--yolopx-selftest` | **YOLOPX 三合一自检**（`runYolopxSelfTest()`，det/da/ll 三输出，含真实推理） | 新文档 4.8 |
> | `--proto-selftest` | **新协议解码自检**——用 `tools/reverse/samples/*.pcap` 固化样本验证 Swift 解码器（**14 项断言**） | 代码-04 |
> | `--nic-autotest` | **自适应网卡自检**——**11 项断言**（探测轮推进 / 注入真实 UDP 30031 命中锁定 / 失流重探 / 自愈重锁） | 代码-04 |> | `--mc-shot` | 任务控制中心 UI 截图（ImageRenderer 无头渲染） | 代码-27 |> | `--mc-map` | 任务控制中心大地图截图 | 代码-27 |
> | `--mc-map-offline` | 大地图**离线模式**（不依赖引擎/定位，用本地地图数据） | 代码-27 |
>
> ### B. 原表中的失效项
>
> - ❌ `--skip_view` / `--skip_yolo`：**不是本程序 CLI 参数**。本文原表自己已注明它们是
>   "Python 训练参数"（传给 `train_game_assist.py`），却被混进 CLI 全集表——
>   它们是**被转发的子进程参数**，不是 AuroraDrive 自己的入口 flag。
>   建议从「CLI 参数全集」表中移出，单列一节「转发给 Python 训练脚本的参数」。
>
> ### C. 新增的自检类参数归属（供交叉引用）
>
> 这批新自检覆盖了项目四条关键链路，是**回归验证的实际入口**：
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
>    与 `pitfalls.md` §15-16（`setNumThreads(2)` 是生产设定）的记载一致
>
> **`--nic-autotest` 的 FAIL 归因**：该自检需**向默认网关注入真实 UDP 30031 包
> 并用 BPF 捕获**（源码注释：「用真实 UDP 30031 包注入做端到端验证」）。
> 当前用户非 root 且沙盒内 `sudo` 不可用 → **无法收包 → 锁定阶段无从触发**。
> 佐证：PASS 的部分（`✓ 停流后判定失流并回到探测`）说明**状态机部分工作正常**，
> 失败的是依赖真实网络的那几步。**要完整验证需 `sudo` + 真实网络环境。**
> | 自适应网卡 | `--nic-autotest` | **11 项** |
> | 自适应缩放 | `--fit-selftest` | — |
> | 限速刹车 | `--limit-selftest` | — |
>
> ---

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

> ### ⚠️ 2026-09-29 订正：oneShotFlags 实际已是 **17 项**（原记 7 项）
>
> **实测**（`AuroraDriveApp.swift:816-820`）：
> ```swift
> let oneShotFlags = ["--speed-selftest", "--tcc-selftest", "--test-xpc",
>                     "--yolo-selftest", "--upscale-selftest", "--yolo-bench",
>                     "--daemon", "--mc-shot", "--mc-map", "--mc-map-offline", "--fit-selftest",
>                     "--limit-selftest", "--nic-autotest", "--proto-selftest",
>                     "--yolopx-selftest", "--opticalflow-selftest", "--motion-selftest"]
> ```
>
> **新增的 10 项**：`--mc-shot`、`--mc-map`、`--mc-map-offline`、`--fit-selftest`、`--limit-selftest`、
> `--nic-autotest`、`--proto-selftest`、`--yolopx-selftest`、`--opticalflow-selftest`、`--motion-selftest`
>
> **含义**：这 10 个新自检**不参与 UI 单实例锁**，可与常驻 UI 并存运行——这是设计上的刻意安排。
> 原注释的语义（"短命进程不参与锁"）仍然成立，只是名单大幅扩张了。
>
> ### ⚠️ 附带订正：YOLOPX 自检的退出码语义（2026-09-26 修）
>
> `AuroraDriveApp.swift:823-828` 注释：
> > ⚠️ 2026-09-26 修：原先无条件 `exit(0)`，自检 FAIL 也返回成功 →
> > CI/脚本无法凭退出码发现问题，自检形同"仅供参考"。
> > 现返回失败项数：0=全过，非0=有失败（>0 即视为失败，上限 127）。
>
> ```swift
> exit(failed == 0 ? 0 : Int32(min(failed, 127)))   // 失败项数截到 127（POSIX 退出码上限）
> ```
>
> **注意退出码语义不一致**：`--yolopx-selftest` 返回**失败项数**，而 `--tcc-selftest` 返回 0/2。
> 写脚本判失败应统一按 `!= 0` 处理。

**环境变量**：`AURORA_API_KEY`（--agent-llm-test 的 Key 来源）/ `AURORA_TCC_TEST`（--tcc-selftest 日志的 mode 字段）/ `AURORA_DAEMON_MODE=1`（--daemon 的等价环境变量）。

## 二、spawnEngine 引擎拉起与 Launcher 分流细节

**`spawnEngine()`（EngineClient.swift，private，第 291–314 行）——spawn 引擎子进程（同二进制 + --engine；stdout/stderr → 引擎日志）**：

1. **可执行路径（292–297 行）**：`CommandLine.arguments[0].standardizedFileURL.resolvingSymlinksInPath()`——**同二进制（含符号链接解析：AuroraDriveUI 可能是 symlink，解析到真实二进制）**；`isExecutableFile` 验证——无效 → engineClientLog"可执行文件路径无效" + false
2. **Process 组装（298–300 行）**：executableURL = exeURL + **arguments = ["--engine"]**——**同一二进制以引擎模式重启自己**
3. **日志重定向（301–305 行）**：`FileHandle(forWritingAtPath: engineLogPath)`（⚠️ 2026-10-06 订正：现为 **`~/Library/Logs/AuroraEngine.log`**，`EngineClient.swift:141-142` 实测；原文写 `/tmp/aurora_engine.log` 已过时）→ seekToEndOfFile（追加）→ **standardOutput + standardError 同一 fh**——"stdout/stderr → 引擎日志"
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
| `~/Library/Logs/AuroraEngine.log` | 引擎进程（spawnEngine 重定向 stdout/stderr，⚠️ 2026-10-06 订正，原记 /tmp/aurora_engine.log） | **引擎侧全部输出**（EngineMain 启动/引擎状态/心跳/命令） |
| `/tmp/aurora_debug.log` | UI 进程（DriveState.dlog，10MB 封顶） | **UI 侧 tick 摘要/决策/诊断**（mode/模型/命令/按键/front/ocr/eff/lag/mem） |
| `/tmp/aurora_anchor_diag.log` | AppDelegate（锚定窗口安装） | stdout 重定向诊断 |
| `/tmp/aurora_iopm_status.log` | AppDelegate（IOPMAssertion） | 系统电源断言状态 |
| `/tmp/aurora_defender.log` | GameModeDefender（双进程） | **[ENGINE]/[UI] 前缀 + 持久战重新主张记录** |
| `~/Library/Logs/AuroraTCCSelfTest.log` | --tcc-selftest | TCC 权限预检结果 |
| `/tmp/upselftest_result.txt` | --upscale-selftest | 插帧自检验定 |

**代码-33 文档至此完整**（spawnEngine 引擎拉起 → Launcher 分流 → GUI 完整启动链 → 两份日志与排障分工）。