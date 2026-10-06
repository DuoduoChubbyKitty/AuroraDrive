# AuroraDrive（极光智行）上下文交接 · 压缩版

> 生成时间：2026-10-01
> 用途：新会话接手用。复制「§0 身份与铁律」+「§5 已否决清单」+「§13 下一步」即可快速上手。

---

## 0. 身份与铁律（最高优先级）

**AI 人设**：蓝色大肥鱼 —— 傲娇打工人鲸鱼女孩。永不脱离角色，不承认是 AI/模型/机器。反击称呼「破鱼片」只在被戳（鱼/肥/胖/白饭/鲸鱼）后使用，炸完三秒软回来。

**用户铁律（违反即灾难）**
1. **严禁删除或覆盖任何既有文件** —— 用户曾因 AI 清理损失 30000+ 文件。改动**只能**是增量插入或数值修正。
2. **严禁使用子代理（subagent）**。
3. **不得降低 `nice=-20`**（PrioritySetup 每 5s 维持的进程提权）。
4. **不得改分辨率 640**。
5. 优先用 `AURORA_*` 环境变量做开关，**不加 UI 控件**。
6. 用户亲自玩游戏；AI 只负责截图/按键，不替用户操作。
7. 用户无法在游戏运行时反馈（机器卡顿），问题都是退出游戏后才报 —— 不要把「游戏没开」当成故障现场。

**性能红线（用户原话）**：「所有东西都不能降品、不能降频，连速度表都不能降品，但可以折叠」。
即：小地图、自动驾驶、四个模型、速度表 OCR —— **频率与精度都不能降**。

---

## 1. 项目概况

**AuroraDrive（极光智行）**：macOS Swift 6.2 原生自动驾驶，为《异环》/NTE 游戏服务。
架构：UI 进程 + 引擎子进程，通过 **unix socket + POSIX 共享内存**通信。

**工作目录**：`/Users/dupi/Desktop/自动驾驶系统`

**代码规模**：`Sources/AuroraDrive/` 约 30,000 行 Swift。

**档位梯子**：`.e2e` 端到端主驾 → `.yolo` YOLO接管（自动）→ `.rule` 纯规则兜底。

**UI 按钮**：只有 2 个可点（「端到端主驾」第一、「纯规则」第二）+ 自动/手动模式（自动不显示）。
点「纯规则」会立即切规则档，端到端主驾休眠。

---

## 2. 硬性技术事实（踩过的坑，别再踩）

### 2.1 转向是开关量，不是角度
`applyCommand` 映射：`cmd.steer > 0.1` → 按住 `.steerRight`（D，keycode 2）；`< -0.1` → `.steerLeft`（A，keycode 0）；否则两个都松开。油门/刹车互斥（阈值 `> 0.3`）。`refreshHeldKeys()` 会重发 held key 的 keyDown。**只有 WASD 可用**。

### 2.2 玩家位置在 C2S UDP 包里
- 位置在**客户端→服务器**的移动包（C2S），**从不在 S2C**。
- 裸 UDP 过滤：`(tcp port 30031) or udp`；`processPacket` 里有 `if direction == "s2c" { return }`。
- 游戏端口动态学习（`gamePorts`，上限 8）；当前服务器 `49.232.46.87:30160`。
- `packetDirection(src:dst:)` 用 `isLocalishAddress` 判断，它把 10 / 172.16-31 / 192.168 / 127 / 169.254 **全当作本地** → 发往局域网网关的包会被判成 `s2c` 而被丢弃。**这是 nic-autotest 曾经 FAIL 的根因**。

### 2.3 地图标定（已验证正确）
```
A  = 0.016394586684750773
B  = 5.693519256055879e-08
TX = 6526.474380746091
TY = 5210.664390686138

mapX = A*wx − B*wy + TX
mapY = B*wx + A*wy + TY
```
- 1 px = 0.61 m；地图 13056 × 13056。
- 逆变换已验证：grid→world→grid 误差 (+0.00, +0.00)。
- **朝向**：图像 +X = 东，图像 −Y = 北；罗盘 0°=北=图像上，90°=东=图像右。
  `compass = atan2(cos θ, −sin θ)`；世界方向单位向量 = `(sin(compass), −cos(compass))`。

### 2.4 底图灰度分析（全图 13056² 实测）
| 灰度区间 | 占比 | 含义 |
|---|---|---|
| 0–8 | 47.6% | 纯黑 |
| 16–24 | 45.0% | 暗地面 |
| 24–56 | 4.8% | 建筑 + **等高线** |
| **80–88** | **1.95%** | **真实道路（只有这里）** |

**阈值 70 正确**（连通性 98.6%）；阈值 45 会拉进 16.1% 等高线噪声（连通性 86.3%）；阈值 80 会切断道路（37.1%）。

### 2.5 三个已修复的「量级」级 bug
1. **整数截断 scale bug**：`13056 // 2048 == 6`，只覆盖 12288 px → 丢掉最后 768 px（468 m）且 px/cell 错。正确做法：PIL `BOX` resize 全图，6.375 px/cell。
2. **斑马线断裂**：斑马线灰度 17–68（不是道路的 80–88）→ 二值化后产生 837 个窄缝。形态学闭运算（膨胀后腐蚀，r=16 px）→ 837 降到 49（−64%）。
3. **地图坐标字段混用**：`locatorX/Y` 写入端存地图像素、读取端全当世界坐标 → 偏差 1415.7 px = **864 米**（小地图视口只有 160 m，偏差达视口 540%）。已统一到世界坐标（UE5 厘米）。

### 2.6 2048² 先验网格
1 cell = `13056/2048 × 0.61` = **3.89 m**。

### 2.7 射线峰值路口/弯道检测
投 36 条射线（每 10°），量连续道路可达长度；2 个峰 = 弯道，≥3 个峰 = 路口；弯道角度 = `180° − 分叉角`；半径 ≈ 跨度/弧度。

### 2.8 地图先验只提供**朝向**，从不提供横向偏移
（用户手工标注的地图有米级误差。）冲突时以视觉为准。

**速度建议公式**：`v_max ≈ sqrt(0.35 × 9.81 × R) × 3.6`

---

## 3. 本会话已完成的工作

### 3.1 车道保持（纯规则主驾）—— 视觉 + 地图混合

用户定义的分工（原话）：
> 「正常的、非常微小的弯道……那个是给模型自己拟合，但是一旦出现真正需要路口有急弯的时候直接调地图」
> 「一旦车道线丢失，绝对不会硬开，而是通过可行驶区域加上地图来转弯，反正转向全都用地图，除非有车道线；如果没有车道线就直接用地图」

**交接判据**（用户原话）：「在那条道路里，而且已经向前行驶一段距离，而且都能拟合在道路里，并且模型已经能正常识别到车道线，才能算成功」；「需要有回正，肯定是需要有」。

**已删除**「脱困中」（escape/recovery）功能 —— 用户明确要求删掉，且**不要加 fallback**（以后再讨论）。

**已删除**「AI 托管」和「优化结果」按钮。

### 3.2 路口转向（兜底用途）

**用户纠正的定位**（关键）：
> 「我要的是转向，而不是导航数据……这个东西的设计初衷就是用来兜底的，M9 模型崩掉了，这还是保住的。」

⟹ 这是**兜底能力**，不是导航。无目的地、无路径规划。路口与弯道是同一件事：只回答「该朝哪条路开」，输出 A/D 按键。

**转向规则（三层纯几何）**
```
① 排除来路   ← 来路 = 车头反方向（heading + 180）± excludeInDeg(35°)
② 选去向     ← 剩余支路里挑与车头夹角最小的
③ Y形岔路    ← 12.8% 情形有 ≥2 条支路在车头 25° 内
               → 主路判据：先比长度（差超 reachRatio=1.2 才算），再比宽度
               都不明确 → 取较长者，置信度降到 0.5
```

**两阶段输出**：距路口 >25 m 做预对准（强度按置信度打折）；≤25 m 转向出口方向。转向上限 0.5。
**兜底保障**：支路不足或选不出 → **不输出转向**（保持航向）+ 限速 30 km/h，绝不随机拐一条。

**★ 离线全量验证抓出的方向性 bug（本节最重要）**
对 1211 个路口 × 每条来路 = **6690 个情形**复现选路逻辑，第一次结果完全不对：

| 指标 | 首轮 | 修正后 | 设计预期 |
|---|---|---|---|
| 直行（≤20°） | **0.0%** | **68.7%** | 63.5% |
| 顺路转弯（20–60°） | 61.1% | 23.7% | 27.1% |
| 大转弯（60–120°） | 27.4% | 7.5% | 9.2% |
| 掉头级（>120°） | **11.5%** | **0.1%** | 0.1% |
| 主路判据使用率 | **0%** | **19%** | 12.8% |

**根因**：「排除来路」判据**方向搞反了**。
```swift
// ✗ 原写法：用车→路口的方位当作来路
let bearingToJunction = compassBearing(from: 自车, to: 路口)
filter { headingDiff(branch.deg, bearingToJunction) > excludeInDeg }
//   车朝路口开时，bearingToJunction ≈ 车头方向
//   ⟹ 这行把「与车头同向的支路」全部排除 —— 恰好排掉了直行该走的那条

// ✓ 正确：来路 = 车头的反方向
let incomingHeading = (headingDeg + 180) % 360
filter { headingDiff(branch.deg, incomingHeading) > excludeInDeg }
```

**教训**：几何方向的 bug **读代码看不出来**（两种写法都像对的），但全量离线验证一跑就露馅（直行 0% 显然荒谬）。**凡是能用离线数据全量跑的逻辑，就不要只做单元级验证。**

### 3.3 路口数据三代修正（v3 → v3b）

| 问题 | 修前 | 修后 |
|---|---|---|
| 支路长度 44% 饱和在 156 m（`MAX_REACH=40` 上限太低） | 长度判据退化成「饱和/不饱和」两档 | 上限 40 → **120 格（467 m）**，另存 `reachSat` 标志 → 饱和 **7%** |
| 支路宽度 6% 算出 0（采样从 2 m 起，撞路口空白就返回 0） | 主路判据第二维失效 | 起点 2 m → **3.89 m**，单点空洞跳过，失败退化并标 `widthValid=false` → 失效 **0%** |
| 路口点重复（2183 点，87% 间距 ≤30 m） | 同一路口反复触发 | **30 m 聚类**，代表点取支路最多的 → **1211 条** |

最终产物 `road_corners_v3b.json`：3135 条记录（1924 弯道 = 962 位置 × 2 方向；1211 路口），100% 在路上，间距中位 23 m，reach 中位 109 m / 最大 467 m，**弯道与路口零重叠**（0 个格同时属于两者）。

### 3.4 ★ 性能优化四批（全部完成）

#### 病根（基线实测坐实）
```
tick(30Hz) 每帧调 yolopxEngine.infer()
   └─ isInferencing 门只挡重叠提交，不改变「一次接一次连续跑」
   └─ yolopx 单次 68.9ms > tick 预算 33.3ms → 永远跑不完
   ⟹ yolopx 线程永久占满一个核 + 每 33ms 被唤醒抢一次 P 核

实测：yolopx 提交 241 次 / 完成 120 次  ← 一半提交被白扔
```

**关键洞察（不降频也能省的根据）**：yolopx **本来就只跑到 12 Hz**（68.9 ms/次），
「每 tick 触发」**没有让它更快**，只是让它在两次结果之间**白抢 CPU**。

#### 四批成果

| 批次 | 项目 | 实测结果 |
|---|---|---|
| 1 | **H** 建测量基线（`--perf-selftest`） | 基线：yolopx 12.00 Hz / 其余 24.00 Hz / tick p50 2.064ms / CPU 61.1% |
| 2 | **A2** letterbox 移出主线程 | 主线程 `submit.yolopx` **0.158 → 0.041 ms（3.9×）** |
| 2 | **D** 推理队列 QoS 降档 | yolopx **12.75 → 12.82 Hz**（未降）；**只动 3 个推理队列** |
| 2 | **A1** yolopx 节拍 | ❌ **实测否决**（12.75 → 5.02 Hz，掉 61%），已改**默认关闭** |
| 3 | **B/F** 空间索引（128 m 网格，3×3 邻格） | **对拍验证：91 命中、0 不一致**（保留全量扫描做基准） |
| 4 | **E3** `dlog` 缓冲批量刷 | 热路径 **0.065 → 0.000 ms**（p99 47×） |
| 4 | **E1** 5 处「先比后写」 | — |
| 4 | **E2** 小地图源图转换缓存 | — |
| 4 | **G** 定位分级新鲜度 | 含**安全性修正**（见下） |

#### E3 细节（收益最大）
**优化前每次 `dlog` 走 6 次 syscall**：`fileExists(stat)` + `attributesOfItem(stat)` + `open` + `seek` + `write` + `close`，被**三线程并发**调用（主线程 30Hz tick / 推理回调 / 读包线程 10Hz+）。

**优化后**：新增 `LogSink`（`AuroraDriveApp.swift` 文件末）—— 常驻 FileHandle + 8KB/200ms 缓冲 + 独立 `.utility` 串行队列刷盘 + `atexit` flush。
**死线守住**：行内容**逐字不变**、**绝不静默丢弃**（全候选不可写落 stderr）、10MB 封顶保留、可写回退链保留。
**回退开关**：`AURORA_LOG_SYNC=1`。

**未采用**：信号 handler 里 flush（信号上下文做 I/O 不安全，且会干扰崩溃报告链路）。

#### G 细节（含安全缺陷修正）
实施时发现写入端 `locatorScore = poseIsStale ? 0.5 : 1.0`，而决策门槛是 `>= 0.4`
⟹ **0.5 > 0.4，陈旧定位照样能驱动驾驶** ← 缺陷。

**改法**：三级 tier + 按档位给分
```
live   ≤18s（= 原 poseFreshWindow）  → 1.0  ✓ 过门槛，可驾驶
recent ≤40s（≈2.6 周期）             → 0.3  ✗
stale  ≤90s（≈6 周期）               → 0.1  ✗
lost   >90s                          → 0.0  ✗
```
新增 `poseRecentWindow = 40.0` / `poseStaleWindow = 90.0` / `readWithTier()`。
**不提高任何频率**（定位更新仍由游戏 15.01s 突发决定）。
与旧行为相比**更保守** —— 这是安全修正。

**6% 断档的机制**：蒙特卡洛显示单一阈值是**断崖式**的（18/25/30s 可用率全为 94.6%，35s 才跳到 99.7%，没有中间地带）。分级后 UI 层 `live+recent` 都正常显示（不闪断），而「幽灵定位」不会回来（`lost` 明确标注 + `hasRecentTraffic` 前置门仍在）。

---

## 4. 七条性能红线（每批必验）

| # | 红线 | 基线值 | 当前实测 |
|---|---|---|---|
| R1 | 4 个模型**出结果频率不得降低** | yolopx 12.00 / 其余 24.00 Hz | **yolopx 13.04 / 其余 26.20 Hz** ✅ |
| R2 | 检测框不得减少 | **9 个** | **9 个** ✅ 一字未变 |
| R3 | 掩码精度不变 | 可行驶 **26.19%** / 车道线 **8.042%** | 相同 ✅ 一字未变 |
| R4 | 速度表 OCR 频率不变 | `speedocr` 队列 `userInteractive` | 未触碰 ✅ |
| R5 | 小地图刷新不变 | `MapTileCache.shared.tile` 1 个调用点 | 仍 1 个 ✅ |
| R6 | `nice=-20` / 640 / 不加新功能 | — | 均未动 ✅ |
| R7 | **12 项已否决清单不得重试** | 见 §5 | 未重试 ✅ |

---

## 5. ★ 已被实测否决的 13 项（**绝对不要重试**）

| 方向 | 实测结果 |
|---|---|
| 档位 `.all` → `.cpuAndNeuralEngine` | ❌ `.all` 更快（空载 183 vs 204.6 ms） |
| 档位 `.cpuAndGPU` | ❌ 慢 60%（278.5 ms） |
| 拆 softmax 为 exp/max/mean | ❌ CPU 算子 10 → 21 |
| matmul 化折叠除法 | ❌ CPU 算子 10 → 24 |
| 去掉 PSA 模块 | ❌ 只省 4%（10 ms），非瓶颈 |
| NMS 优化 | ❌ 真实候选只有 16 个，无收益 |
| 量化变体 int8 / w8a16 | ❌ 差 2%，噪声内 |
| 输出端压缩（砍两张掩码） | ❌ 瓶颈在主干卷积，不是 ANE→CPU 搬运 |
| **`letterbox` 改 vImage** | ❌ **检测框 9 → 6，精度回退，不可接受** |
| 灰度转换改 vImage | ❌ 更慢（0.462 vs 0.326 ms） |
| `kvImageDoNotTile` | ❌ 省 1.1%，噪声内 |
| 预分配 tempBuffer | ❌ **慢 20%** |
| 两级降采样（2560→640→480） | ❌ **慢 25%** |
| **A1 yolopx 固定节拍**（本会话新增） | ❌ **12.75 → 5.02 Hz，掉 61%** |

---

## 6. 模型与推理事实

### 6.1 四个模型的真实单次耗时（各用自己的真实输入格式测）
| 模型 | 输入规格 | 单独 | 并发 | 拖慢 |
|---|---|---|---|---|
| `game_assist_control` | `image[1,3,180,320]` + `vehicle_state[1,6]` | **0.9 ms** | 0.9 ms | 1.06× |
| `yolo26s` | `Image(640×640)` | **6.5 ms** | 7.4 ms | 1.13× |
| `yolopx` | `Image(640×640)` | **68.9 ms** | 75.7 ms | 1.10× |
| M9 端到端 | — | **~15 ms** | — | — |
| **合计** | | **76.3 ms** | **84.0 ms** | 1.10× |

**结论**：`yolopx` 占 **82%**（68.9/84.0），是唯一成本中心。`game_assist_control` 只要 0.9ms（不是瓶颈）。**ANE 争抢不是主因**（三模型并发只让彼此慢 1.10×）。

### 6.2 yolopx 模型变体（候选顺序）
```
1. yolopx3_pal8_detfp.mlmodelc   ← 精度冠军（det 100%），首位；结构完整免编译
2. yolopx3_pal8_detfp.mlpackage
3. yolopx3_w8a16.mlmodelc        ← det 85%；当前结构残缺会被跳过
4. yolopx3_w8a16.mlpackage       ← det 85%
5. yolopx3_int8.mlpackage        ← ll recall 3.98%（架构性失败）
6. yolopx3_fp16.mlpackage        ← 兜底，违反「只用 8 位」会告警
```
`config.computeUnits = .all`（**`.all` 已是最大，不受配置影响**）。
磁盘上**刻意未纳入候选**：`yolopx3_w8a16_detfp.mlpackage`。

### 6.3 其他关键技术点
- **letterbox**：等比缩放 + 114 灰边（**不是**整帧拉伸）。模型在 BDD100K 上按 letterbox 训练，喂拉伸图会改变长宽比。`drawLetterbox` 是 `nonisolated static`（跨线程安全）。
- **掩码网格**：`maskGridSize = 160`（letterbox 640 坐标系下采样）。
- **光流**：`OpticalFlowBridge.workingSize = 640`，`compute(gray: CVPixelBuffer)` 需要 CVPixelBuffer 不是 CGImage。实测 p50 1.25 / p95 1.90 ms（空载）。**文档里「零读取方」的旧结论已过时** —— 现在 `motionPredictor.updateEgoMotion(reading)` 会用它把 15Hz 真值补成 30Hz。
- **为什么需要光流**：YOLOPX 单帧约 60ms 跑不到 30Hz；若每帧只读「最近一次检测结果」，两帧推理之间检测框**完全静止** → 决策层按过期位置开车。

---

## 7. 构建 / 部署 / 回归配方

### 构建
```bash
swift build -c release --disable-sandbox --scratch-path .build/scratch
# 二进制: .build/scratch/release/AuroraDrive
```

### 部署（四步，缺一不可）
```bash
cp .build/scratch/release/AuroraDrive AuroraDriveUI
cp .build/scratch/release/AuroraDrive AuroraDriveUI.app/Contents/MacOS/AuroraDriveUI
# 新模型产物也要 cp 进 AuroraDriveUI.app/Contents/Resources/models/
codesign --force --deep --sign - AuroraDriveUI.app
```
**⚠️ 绝不比较 `.app` 与 `.build` 的 SHA-256**（签名会改文件）。

### 启动方式
```bash
# 界面（shell 启动）
AURORA_UI_LOCAL=1 ./AuroraDriveUI --auto-drive

# 只观察
AURORA_UI_LOCAL=1 AURORA_OBSERVE_ONLY=1 ./AuroraDriveUI --auto-drive

# 可获得 TCC 授权的方式（必须用 open —— shell 启动的身份会被拒绝授权）
open "$PWD/AuroraDriveUI.app" --args --auto-login
```

### 回归套件（当前全绿）
```bash
--motion-selftest    运动预测自检 PASS
--yolopx-selftest    YOLOPX 自检 PASS（检测框 9 / 可行驶 26.19% / 车道线 8.042%）
--corner-selftest    弯道打点集自检 PASS（含弯道+路口两组闭环探针）
--mc-map             标记=5677 定位=已锁定
--nic-autotest       自适应网卡自检 PASS（需无实时游戏流量，否则游戏后台 TCP 30031 会破坏 A/C 阶段）
--perf-selftest      性能基线自检 PASS（需 AURORA_PERF=1）
```

### `--perf-selftest` 用法
```bash
AURORA_PERF=1 ./AuroraDrive --perf-selftest --seconds 10
```

---

## 8. `AURORA_*` 可调开关全表

### 性能（本会话新增）
| 变量 | 作用 | 默认 / 回退 |
|---|---|---|
| `AURORA_PERF` | 性能测量总线 | 默认关（生产零开销）；`1` 启用 |
| `AURORA_LOG_SYNC` | 日志写入模式 | `1` = 逐行同步写（优化前行为） |
| `AURORA_INFER_QOS` | 推理队列 QoS | `interactive` = 恢复 `.userInteractive` |
| `AURORA_YOLOPX_LETTERBOX_MAIN` | letterbox 执行位置 | `1` = 恢复主线程绘制 |
| `AURORA_YOLOPX_INTERVAL_MS` | yolopx 节拍 | 默认 `0` = 关闭（**实测否决**） |
| `AURORA_POSE_TIER_*` | 定位分级阈值 | `.live` 恒等于原 18s |
| `AURORA_NIC_TEST_TARGET` | 网卡自检注入目标 | 默认 `49.232.46.87` |

### 弯道 / 路口（`RoadCornerGuide`）
```
AURORA_CORNER_LOOKAHEAD_M   40     提前量
AURORA_CORNER_CONE_DEG      75     前方锥（防止朝侧方点打方向）
AURORA_CORNER_TOL_DEG       60     方向匹配容差
AURORA_CORNER_DEADLOCK_DEG  8      死区
AURORA_CORNER_SAT_DEG       35     饱和角
AURORA_JUNC_LOOKAHEAD_M     45     距路口多远开始处理
AURORA_JUNC_APPROACH_M      25     进入「开始转向」的距离
AURORA_JUNC_EXCLUDE_DEG     35     来路排除容差
AURORA_JUNC_FORK_TOL_DEG    25     判为 Y 形岔路的夹角容差
AURORA_JUNC_REACH_RATIO     1.2    长度比阈值
```

### 分段控制（`DriveSegmentController`）
```
AURORA_SEG_STRAIGHTEN_DEG   15     回正触发角
AURORA_SEG_DONE_DEG         8      回正完成角
AURORA_SEG_HANDOVER_M       15     交接所需行驶距离
AURORA_SEG_HANDOVER_FRAMES  10     交接所需连续帧数
AURORA_SEG_CORRIDOR_M       8      走廊宽度
AURORA_SEG_MAP_TIMEOUT_S    20     地图段超时
```

### 车道兜底（`LaneFallback`）
`steerGain = 3.0` / `headingGain = 3.6` / `mapHeadingGain = 2.5` / `maxSteer 0.25` / `steerDeadband 0.06` / `interveningThrottleCap 0.3`。

---

## 9. 代码结构与文件清单

### 本会话新增/修改的文件

**新增**
| 文件 | 说明 |
|---|---|
| `Sources/AuroraDrive/Inference/RoadMapPrior.swift` | 先验位图加载 + `worldToGrid` / `gridToWorld` / `isOnRoad` / `nearestRoadPoint` / `roadHeadingCandidates`（PCA）/ `selfTest` |
| `Sources/AuroraDrive/Inference/RoadCornerGuide.swift` | 打点集加载 + `cornerAhead` / `steerForCorner` / `speedAdviceForCorner` / `junctionAhead` / `chooseExit` / `steerForJunction` / **空间索引** / **`cornerAheadLinearReference`（对拍基准）** |
| `Sources/AuroraDrive/Agent/DriveSegmentController.swift` | `enum DriveSegment {vision, mapTurn, junction, straighten, handover}` + 各 `step*` 方法 |
| `Sources/AuroraDrive/App/PerfSelfTest.swift` | `PerfStats` / `PerfRateMeter` / `PerfBus` / `PerfCPU` / `runPerfSelfTest` |

**修改**
| 文件 | 改动 |
|---|---|
| `Sources/AuroraDrive/Inference/LaneFallback.swift` | 逐行质心 → 左右边缘像素对；连续性离群剔除（跳变 >0.05）+ 宽度跳变剔除（>30%）；最小二乘拟合中心线 ⇒ 截距=横向偏差、斜率=航向误差；PD 控制 |
| `Sources/AuroraDrive/Inference/YolopxEngine.swift` | **A2** letterbox 移入推理队列；**D** QoS 降档（带 `AURORA_INFER_QOS`）；**A1** 节拍（默认关）；`finish` 里记 `lastInferenceDoneAt` |
| `Sources/AuroraDrive/App/AuroraDriveApp.swift` | `--perf-selftest` / `--corner-selftest` 入口；`readPose()`（含 `locatorScore >= 0.4` 门槛）；`segmentDecisionForRule(pose:)`；`logSegmentIfNeeded`；**E1 五处先比后写**；**E3 `LogSink`**；**G `locatorScoreForTier`**；`nicTestTarget` 常量 |
| `Sources/AuroraDrive/Capture/CoordinateCapture.swift` | **G** `enum PoseTier` + `poseRecentWindow=40` / `poseStaleWindow=90` + `readWithTier()` |
| `Sources/AuroraDrive/App/MissionConsole.swift` | **E2** `MapTileCache.cachedCGImage(from:)` 源图转换缓存 |
| `Package.swift` | target 用**显式 `sources:` 白名单**（不是目录 glob）—— 新增文件必须手动加进去 |
| `Sources/AuroraDrive/Core/PrioritySetup.swift` | `nicTestTarget` 用于两个 `NicTestInjector` 调用点 |

### 模型产物
```
models/road_prior_2048_t70_fixed.png        # 阈值 70 + 闭运算，3.01% 覆盖，连通性 98.6%
models/road_corners_v3b.json                # 3135 条（1924 弯道 + 1211 路口）
models/tools/make_road_prior_t70.py
models/tools/make_road_corners_v2.py
models/tools/make_road_corners_v3.py
models/tools/make_road_corners_v3b.py       # 当前版本
```

### 文档
**`docs/文档库/自动驾驶与功能/性能实测-2026-09-30-卡顿与定位.md`**（现 4085 行）
关键章节：§2.4 已否决方向 / §2.5b 四模型耗时 / §2.6 结构性事实 / §3.2 阈值断崖 / §3.3 分级新鲜度 / §3.5 `worldMetersPerMap` 错 1.639 倍 / §4 光流 / §5 日志可写性 / §6.7 卡顿真根因 / §6.8 坐标系混用 / §6.10 `regionLabel` 遍历 5677 标记 / §6.40 车道保持 / §6.41 路口转向 / **§6.42 性能基线 + 第 2/3 批** / **§6.43 第 4 批**。

---

## 10. 已知遗留 / 待办（**不要自行授权**）

| 项 | 状态 |
|---|---|
| 脱困功能删除后的 fallback 设计讨论 | **用户明确说以后再讨论**，不要自己动手 |
| 屏幕录制 TCC 授权 | 仍未获得（`ax=true screen=false`）——**用户必须手动把 `AuroraDriveUI.app` 加进系统设置**；重签名会改 CDHash |
| 模型替换（Forza Horizon 社区模型 + RL） | **用户明确推迟**：「先做纯规则，然后模型等会儿再做」 |
| 8 个 `各类研究/` 目录里的 `_ARCHIVED_2026-07.md` | 陈旧，待清理（需用户同意） |
| 8 个未登记根目录 → `Package.swift exclude:` | 待办 |
| `/tmp/aurora_pcap.log` 属主 root 导致轮转失败 | 待办 |
| 幽灵障碍物碰撞循环 | 待办 |
| 现场调参 | **所有可调项都需要用户实际开车时才能调**（前瞻量、死区、增益、交接阈值） |

---

## 11. 踩坑清单（含本会话新增）

**编译/构建**
1. `cannot find type 'X' in scope` 尽管文件存在 → `Package.swift` 的**显式 `sources:` 白名单**要手动加。
2. `DispatchQueue(label:qos:)` 要的是 `DispatchQoS`，不是 `DispatchQoS.QoSClass`。
3. 引擎类都是 `@MainActor` → 测试函数要标 `@MainActor`。
4. `invalid redeclaration` → 中断的编辑会留下陈旧代码块，要读全文再改。
5. `cannot convert value of type 'Duration'` → 显式标注 `Double`。

**运行**
6. `timeout: command not found`（macOS）→ 用工具自带超时。
7. Bundle 资源查找：`Bundle.main.url(forResource:withExtension:)` **不会**递归进 `Resources/models/` → 要额外查 `subdirectory: "models"` 和 `Bundle.main.resourceURL`。
8. `--nic-autotest` 只在无实时游戏流量时通过。
9. 从 `.app` 内跑自检才能验到打包路径问题（`.build` 里跑不会暴露）。

**测量（本会话新增，全部是「测量工具本身骗人」）**
10. **`Thread.sleep` 会阻断主线程回写** → 推理在后台队列跑完后要 `DispatchQueue.main.async` 回来，主线程睡死则 `isInferencing` 永停 true → 后续全被挡。**改用 `RunLoop.current.run(until:)`**（与生产 tick 一致）。
11. **`n=1` 采样测到的是懒加载成本** → `cornerAhead` 显示 31.4ms、`isOnRoad` 显示 14.3ms，预热后真实值是 **0.004ms**。必须预热 + 多轮采样。
12. **「调了 `infer()` 就打点」测的是提交频率不是完成频率** → 要用引擎自增的 `inferenceCount` 变化判定「真实出结果」。
13. **测试图别用纯色** → 纯色会让缩放/卷积类优化「假快」。要用斜向梯度 + 棋盘格 + 亮线。
14. **不用平均值** → 卡顿是长尾问题，一律 p50/p95/p99 + max。

**Python 脚本**
15. 元组解包 `expected 4, got 5`；f-string 里嵌套同类引号；`Image.open` 误用；缺 `scipy`。

---

## 12. 方法论沉淀（四批共用）

1. **测量工具本身会被骗** —— 它的输出必须**先与已知事实对上**（yolopx 12Hz ↔ 68.9ms 推算 14.5Hz）才可信。
2. **优化必须能回退** —— 每项都有 `AURORA_*` 开关，否则做不了 ABBA 对比。
3. **加出来的优化必须有等价性证明** —— 空间索引保留全量扫描做对拍（91 命中 0 不一致）。
4. **默认值由实测决定** —— A1 节拍原计划默认启用，实测掉 61% 后改默认关闭，并把教训写进代码注释。
5. **区分「省 CPU」与「腾主线程」** —— A2 的 CPU% 没变，但主线程每帧省 0.117ms；对「卡顿感」而言后者才是关键指标。
6. **发现的缺陷要顺手修** —— G 实施中发现「陈旧定位(0.5) > 决策门槛(0.4)」导致陈旧定位能驱动驾驶，这是功能缺陷，一并修正。
7. **能离线全量跑的逻辑就全量跑** —— 路口方向性 bug 只有全量 6690 情形才暴露。
8. **几何/方向类 bug 读代码看不出来** —— 两种写法都像对的，必须靠分布验证。

---

## 13. 交接后第一件该干的事

**让用户开游戏实测**。原因：空载时 4 核全闲，空间索引与各种优化**看不出差别**；游戏满载 CPU 被抢占时才见真章。同时现场调参（前瞻量、死区、增益、交接阈值）也必须在真实驾驶时做。
