# Comma Connect 数据闭环深度研究报告

> 研究对象：comma.ai OpenPilot / Comma Connect / comma 3X / comma four 的数据闭环体系
> 研究方法：WebSearch + WebFetch 多轮挖掘（官方站点、GitHub 仓库、博客、隐私政策、release notes）
> 配套文件：本报告隶属于 `03x` 数据与生态系列，承接 `03c_iso26262.md`，并与 `02h_training_data.md`（训练数据）、`02t_driver_monitor.md`（驾驶员监控）相互印证

---

## 0. 执行摘要

comma.ai 是一家由 George Hotz 创立的纯视觉自动驾驶公司，其核心产品 openpilot 是一个开源的驾驶辅助操作系统（OS for robotics），目前能升级 300+ 车型的 ADAS（ACC / ALC / FCW / LDW + 驾驶员监控 DM）。与 Tesla 的封闭车队学习、Waymo 的自营 Robotaxi 车队不同，comma 走的是"后装硬件 + 开源软件 + 众包车队 + 自建数据中心 + 世界模型仿真训练"的独特路线。

其数据闭环的核心特征是：
1. **设备即采集器**：comma 3X / comma four 后装到用户车上，默认开启路采数据上传；
2. **Comma Connect 作为枢纽**：Web/App（PWA）让用户管理设备、查看行程、远程控制，同时也是数据回云与模型下发的通道；
3. **众包激励**：免费 3 天云存储 + comma prime 订阅（1 年存储 / LTE / 远程拍照 / SSH）换取用户持续贡献数据；
4. **自建数据中心**：约 500 万美元自建 600 GPU + 4PB SSD 的数据中心，所有训练/指标/数据都在自己机房，不上云；
5. **世界模型仿真训练**：从 tinysim 重投影仿真器演进到 mlsim 世界模型仿真器，实现 on-policy 训练，0.11.0 起驾驶模型完全用学习型仿真器训练；
6. **OTA 分级发布**：release / staging / nightly / nightly-dev 四级分支，通过 openpilot.comma.ai 等 URL 触发设备侧自动更新。

本报告将逐层拆解该闭环，并在末尾给出对 AuroraDrive（当前以仿真模式采集数据）的迁移建议。

---

## 1. Comma Connect 整体架构

### 1.1 三段式数据通路：设备 →（手机/Web）→ 云

Comma Connect 并不是一个简单的"手机 App"，而是 comma 整个数据闭环对外的统一入口与控制面。其物理与逻辑链路如下：

```
┌────────────────────────────────────────────────────────────────────┐
│                       用户侧（车端）                                │
│  ┌──────────────┐    CAN/GPS/IMU/磁力计/温度    ┌─────────────────┐ │
│  │  车辆 OBD-II │ ───────────────────────────► │  comma 3X/four  │ │
│  │  + car harness│                              │  (Snapdragon    │ │
│  └──────────────┘                               │   845 MAX)      │ │
│                                                 │  三摄 360° 视觉  │ │
│                                                 │  LTE + Wi-Fi    │ │
│                                                 └────────┬────────┘ │
└──────────────────────────────────────────────────┼─────────────────┘
                                                   │ loggerd 记录
                                                   │ uploader 上传
                                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                    comma 云（自建数据中心，San Diego）              │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────────┐ │
│  │ 数据接入 │──►│ mkv 分布 │──►│ slurm/   │──►│ pytorch FSDP     │ │
│  │ ingestion│   │ 式存储   │   │ miniray  │   │ + on-policy 仿真 │ │
│  │ 3PB SSD  │   │ ~1TB/s读 │   │ 任务调度 │   │ 训练（mlsim）    │ │
│  └──────────┘   └──────────┘   └──────────┘   └────────┬─────────┘ │
│       ▲                                                │            │
│       │              reporter 实验追踪 + 模型权重库     │            │
│       │              commaai.github.io/model_reports   │            │
│       └────────────────────────────────────────────────┘            │
│                   模型与 release 分支产物                            │
└───────────────────────────┬────────────────────────────────────────┘
                            │ OTA（release/staging/nightly URL）
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│              Comma Connect（控制面 / 用户面）                       │
│  connect.comma.ai (Web PWA)  +  iOS/Android App (ai.comma.connect)  │
│  ─ 行程回放与路线 ─ 远程拍照 ─ 实时 GPS ─ 电池电压 ─ SSH ─ 订阅管理─ │
└────────────────────────────────────────────────────────────────────┘
```

关键点：
- **设备 → 云是直连的**：comma 设备自带 LTE（comma prime 含数据流量，仅美国/波多黎各）或 BYO SIM（prime lite，国际可用），同时也支持 Wi-Fi。数据并不强依赖手机中转；手机/Web 端的 Comma Connect 主要承担"管理 + 查看 + 远程控制"的角色，而非数据中继。
- **手机/App 的真实定位**：Comma Connect 的代码仓库 `commaai/connect` 是一个基于 React + Redux + Material-UI 的渐进式 Web 应用（PWA），用 Vite 构建、bun 管理依赖，同时打包为 iOS/Android 原生壳。stable 部署在 `connect.comma.ai`，latest 部署在 Cloudflare Pages。
- **数据上传机制**：openpilot 默认上传驾驶数据到 comma 服务器；用户也可通过 Comma Connect 访问自己的数据。官方在 README 中明确："We use your data to train better models and improve openpilot for everyone."

### 1.2 数据上传机制

openpilot 端侧由 `loggerd`（日志守护进程）负责把传感器流落盘成"段（segment）"，再由 `uploader` 后台进程在网络可用时把段上传到 comma 云。每段通常为 1 分钟左右，包含：
- 路面摄像头视频（HEVC 压缩，默认开启）；
- CAN 总线报文（车速、转向角、油门/刹车、档位等）；
- GPS、IMU、磁力计、温度传感器；
- 崩溃日志与操作系统日志；
- 一个低分辨率的预览视频（`qcamera`，用于 Connect 端快速回放）；
- 驾驶员摄像头（`dcamera`）与麦克风——**仅当用户在设置中显式 opt-in 才记录上传**。

值得注意的两个增强上传通道：
1. **Firehose Mode（消防栓模式）**：自 0.9.8 引入，开启后会最大化上传训练数据（含更完整的高质量流），官方明确建议 Experimental Mode 用户同时开启 Firehose，因为"更多数据意味着更大的模型，也意味着更好的实验模式"。
2. **Wi-Fi 回拉**：CONTRIBUTING.md 中呼吁社区"定期把设备连到 Wi-Fi，以便我们拉取数据训练更好的驾驶模型"。

### 1.3 用户参与机制

comma 的用户参与设计非常"赤裸"且高效：
- **默认 opt-in**：路采数据默认上传，用户必须主动关闭才能停止；
- **免费增值（Freemium）**：免费用户数据在云端保留 3 天；订阅 comma prime（$24/月，含美国数据流量）或 prime lite（$14/月，自带 SIM）则保留 1 年，并解锁实时 GPS、远程拍照、SSH 等功能；
- **隐性激励**：comma prime 自动附带 commacare（comma four 标准一年保修再延长一年），用保修绑定持续订阅，进而绑定持续数据贡献；
- **众包标注**：comma10k 数据集由社区通过 PR 公开标注语义分割掩码；
- **fork 数据准入**：第三方 fork 的数据若要进入训练集，必须保持 cereal 消息结构兼容、不改动 stock 字段定义、不引入上游不支持的车型——这保证了数据"语义一致性"。

### 1.4 隐私保护（详见第 6 节）

comma 的隐私模型对 comma 自身非常宽松（用户授予"不可撤销、永久、全球范围"的数据使用权），但对敏感通道做了分级：
- 路面摄像头、CAN、定位等默认上传（可关闭）；
- 驾驶员摄像头与麦克风必须显式 opt-in；
- 用户可在 openpilot 设置中调整隐私配置文件。

---

## 2. comma 3X / comma four 数据上传

### 2.1 硬件采集能力

| 维度 | comma 3X | comma four（2025-11-25 发布） |
|------|----------|------------------------------|
| 算力 | Snapdragon 845 | Snapdragon 845 MAX（同代 MAX 版） |
| 体积 | 基准 | 3X 的 1/5，可完全藏于后视镜后 |
| 摄像 | 三摄 360°（路/内/鱼眼） | 三摄 360°，全部收入 1.9" 显示器足迹内 |
| 散热 | 标准设计 | 自研 MAX 冷却，挡风玻璃高温下持续 turbo 零降频 |
| 屏幕 | — | 300 PPI OLED，全新 UI |
| 连接 | Wi-Fi + LTE | 内置 Wi-Fi + LTE，开机即可收 OTA |
| 配置 | — | 设备端完全配置，无需 App/订阅/账号 |
| 售价 | — | $999（旧机置换 $699） |
| 制造 | San Diego | San Diego，60% 零件、一半工序 |

comma four 的关键设计哲学："**engages 时唤醒，disengages 时休眠**"——这不仅省电（0.11.0 把待机功耗降到 52mW，降低 77%），也天然界定了"有效数据段"的边界：engage 期间的段才是 openpilot 真正在控车的段，是训练最关心的正样本来源。

### 2.2 数据采集

openpilot 在车端订阅 cereal 消息总线上的所有服务，`loggerd` 把它们按段（segment）打包。每段约 1 分钟，落盘到设备本地存储。采集内容（README 明示）：
- 路面摄像头（road-facing cameras）
- CAN 总线
- GPS
- IMU
- 磁力计（magnetometer）
- 温度传感器（thermal sensors）
- 崩溃日志（crashes）
- 操作系统日志
- **驾驶员摄像头与麦克风：仅 opt-in 记录**

### 2.3 数据压缩

为在有限 LTE 带宽下高效回传，openpilot 采用了多级压缩策略：
- **视频**：路面/驾驶员视频用 HEVC（H.265）编码；同时生成一个低码率预览流 `qcamera`，供 Comma Connect 在手机端流畅回放；
- **CAN/日志**：采用 Cap'n Proto 二进制序列化（cereal 即基于 capnp），紧凑且零拷贝；
- **段切分**：按分钟切分使得上传可断点续传、可并行。

### 2.4 数据上传与频率

- **常态上传**：每段完成后由 `uploader` 在网络可用时上传；连接 Wi-Fi 时优先大流量回拉；
- **Firehose 模式**：开启后尽可能上传全部高质量流，是训练数据的主要来源；
- **bootlog**：每次开机/重启会上传一个 bootlog，用于追踪设备健康度与崩溃。
- **保留策略**：免费 3 天 / prime 1 年；超过保留期的视频会被清理，但 comma 内部仍可基于已入库的段继续训练。

---

## 3. Comma Connect App

### 3.1 形态与分发

Comma Connect 是"一套代码、多端分发"：
- **Web PWA**：`connect.comma.ai`（stable）+ `latest.connect-d5y.pages.dev`（latest）。基于 React + Redux + Material-UI + react-router-redux，Vite 构建，nginx 托管，Docker 化部署；
- **移动端**：iOS / Android 原生壳包裹 PWA，Android 包名 `ai.comma.connect`；
- **开源**：仓库 `commaai/connect`，MIT 协议，社区可贡献。

### 3.2 设备配对

comma four 起进一步弱化了 App 的"必备性"——设备端即可完成全部配置，无需 App/订阅/账号。但 Comma Connect 仍是远程能力的唯一入口：
- 通过 comma 账号关联设备 dongle ID；
- comma prime 订阅在 Connect 内的"Prime Settings"中开通/取消，按月计费，取消立即生效并按比例退款。

### 3.3 数据查看

- **行程列表与回放**：最近行程、路线、视频回放（基于 qcamera 流）；
- **电池电压**：远程查看设备电池电压，判断车辆/设备健康；
- **远程快照（Remote Snapshots）**：远程触发拍照，查看车周情况；comma four 配备 HD 路面摄像头 + 夜视增强的座舱摄像头。

### 3.4 远程控制

- **24/7 连接**：Always-on LTE（prime 含数据）；
- **实时 GPS 跟踪**：地图实时查看车辆位置；
- **远程拍照**：路面 + 座舱双摄；
- **开发者 SSH**：Simple SSH for developers，方便部署代码到设备；
- **comma body teleop**：connect 仓库近期合并了 "body teleop" 相关改动（tailwind 配置、bug 修复），表明 Comma Connect 正在扩展为 comma body 机器人的遥操作前端——这是其从"车"走向"通用机器人 OS"的重要信号。

---

## 4. comma.ai 云服务（自建数据中心）

comma 在 2026-02-03 的博客《Owning a $5M data center》中详细披露了其云端基础设施，这是理解其数据闭环规模的关键。

### 4.1 为何不上云

comma CTO Harald Schäfer 给出三点理由：
1. **掌控命运**：云厂商"入驻容易、迁出极难"，长期会"梦游式"陷入高成本锁定；
2. **工程激励**：自有算力下，工程师最快的改进路径是"优化代码/修根本问题"，而非"加预算"，避免低效方案；
3. **成本**：自建约花 500 万美元，同样工作量上云需 2500 万美元以上。

### 4.2 物理规模

- **算力**：600 块 GPU，装在 75 台自研 TinyBox Pro 机器中（每台 2 CPU + 8 GPU），既作训练机也作通用计算节点；
- **存储**：数架 Dell R630/R730，SSD 共约 4PB。主存储阵列 3PB、**无冗余**，专门存放训练用驾驶数据，可按 ~1TB/s 读取——**直接在原始数据上训练，无需缓存**；另有 ~300TB 无冗余阵列缓存中间结果；最后有一个**有冗余**的阵列存放训练好的模型与训练指标；
- **网络**：3 台 100Gbps Z9264F 以太网交换机 + 2 台 InfiniBand 交换机用于跨机 all-reduce；
- **功耗**：峰值约 450kW，2025 年电费 54 万美元（San Diego 电价 >40¢/kWh）；
- **制冷**：San Diego 气候温和，采用纯外进风冷却（双 48" 进/排风扇 + 循环风扇控湿），仅几十 kW。

### 4.3 软件栈

- **装机**：Ubuntu + PXE boot + salt 管理；
- **分布式存储**：自研 `minikeyvalue (mkv)`，3PB 主阵列 ~1TB/s 读，无冗余（驾驶数据不关键）；
- **任务调度**：slurm 管理计算节点与作业；
- **分布式训练**：PyTorch `torch.distributed` FSDP，两套训练分区，InfiniBand 互联，自研训练框架封装样板代码；
- **实验追踪**：自研 reporter（类 wandb/tensorboard），托管模型权重（按 uuid 下载），**最新模型指标对公众开放**：`commaai.github.io/model_reports`；
- **分布式计算**：自研开源任务调度器 `miniray`（类极简版 dask），slurm 把空闲机调度为 miniray worker，中央 redis 协调；GPU worker 会拉起 triton inference server 做动态批推理；
- **代码**：单仓 monorepo（<3GB），通过 NFS 共享缓存，分布式作业用与本地完全一致的代码与 UV 同步的依赖，整过程约 2 秒。

### 4.4 数据索引与查询

- 段（segment）是基本索引单元，按 dongle ID + 时间戳组织成 route；
- `cabana`（openpilot tools 内）用于查看/绘制 CAN 报文，可实时或离线；
- `plotjuggler`、`replay` 用于回放段并 mock openpilot 服务；
- 训练时通过 dataset 列表文件（如 `train_500k_20250717.txt`）指定数据集版本与切片。

### 4.5 数据安全

comma 的"安全"策略颇具工程师实用主义：
- **驾驶数据无冗余**——丢得起，因为数据持续在产生；
- **模型与指标有冗余**——丢不起；
- **不上云**——物理与网络边界自己掌控；
- 官方隐私政策坦言"没有任何数据采集/传输/存储系统 100% 安全"，用户需自行承担被截获风险。

---

## 5. 用户参与机制（深度）

comma 的用户参与是一套精心设计的"默认贡献 + 增值换数据 + 社区协作"组合拳：

### 5.1 用户授权分层

| 通道 | 默认 | 关闭方式 |
|------|------|----------|
| 路面摄像头 | 上传 | 设置中关闭数据采集 |
| CAN/GPS/IMU 等 | 上传 | 同上 |
| 驾驶员摄像头 | 不上传 | 设置中 opt-in 开启 |
| 麦克风 | 不上传 | 设置中 opt-in 开启 |
| Firehose 全量 | 不开启 | 设置中手动开启 |

### 5.2 数据共享与 fork 准入

CONTRIBUTING.md 的"Contributing Training Data"明确：fork 产生的数据若要进入 comma 训练集，必须满足：
1. cereal 消息结构兼容；
2. **所有 stock 消息结构定义不得修改**（从 `selfdriveState.enabled` 到 `carState.steeringAngleDeg` 都不能改字段语义，要自定义请新建 struct）；
3. 不得包含上游不支持的车型（应建新 opendbc platform）。

这保证了不同 fork 上传的数据在语义上"同构"，可被同一套训练管线消化——这是 comma 众包数据能真正闭环的关键契约。

### 5.3 用户激励（免费服务）

- **免费 3 天云存储 + 行程查看**：让用户先尝到"看见自己驾驶"的甜头；
- **comma prime / prime lite**：1 年存储 + 实时 GPS + 远程拍照 + SSH + LTE 流量（prime）；
- **commacare 延保**：prime 订阅自动延长 comma four 保修至 2 年，但取消 prime 即失效——强绑定持续订阅；
- **免费 1 个月 prime**：买 comma four 赠送 1 个月 prime 试用；
- **社区认同感**：Discord `#driving-feedback`、`#comma-pencil`、bounties 悬赏、外部贡献者被雇佣。

---

## 6. 隐私保护

### 6.1 数据脱敏

comma 并未对上传视频做自动化人脸/车牌脱敏——其隐私政策直言"comma 拥有用户通过服务传来的所有数据，可任意方式使用与修改"。脱敏责任实际上由"默认不上传驾驶员摄像头"这一开关承担。

### 6.2 位置信息保护

- GPS/行程/停车位置属于默认上传数据（隐私政策 A 节）；
- 用户无法对 comma 隐藏位置而又继续使用 openpilot——位置是训练与服务的核心输入；
- 用户可联系 support@comma.ai 查询/更新个人信息，但"停止上传"基本等同于"停止使用"。

### 6.3 人脸信息保护

- 驾驶员监控（DM）默认**只跟踪头部与眼睛姿态**（用于判断分心/疲劳），**不存储视频**；
- 只有用户在设置中开启"Record and Upload Driver Camera"后，DM 视频才会被上传，用于训练 DM 模型；
- 0.10.3 release 笔记专门呼吁 comma four 用户开启该开关，因为 four 的驾驶员摄像头位置与 comma 3/3X 不同，需要 four 的真实段来改进 DM 模型。

### 6.4 用户控制

- 隐私配置文件在 openpilot 设置按钮内可调；
- 可整体关闭数据采集（openpilot 是开源软件，用户可自行修改/禁用上传）；
- 支持地域：openpilot 官方兼容性声明仅限美国境内（条款层面），但 prime lite + 自带 SIM 可国际使用。

---

## 7. 数据筛选

### 7.1 engage / disengage 信号

comma 的核心筛选信号是 `selfdriveState.enabled`（即 openpilot 是否在控车）。comma four "engage 唤醒 / disengage 休眠"的设计在硬件层强化了这一点：
- **engage 段**：openpilot 在控车，是"模型输出被真实执行"的正样本，价值最高；
- **disengage 段**：用户接管，可能意味着模型犯错或场景超出 ODD，是"负样本/接管样本"，价值同样高（用于学习何时该退出）；
- **手动驾驶段**：openpilot 关闭，仅作环境感知数据。

CONTRIBUTING.md 强调 stock 字段语义不可改，正是因为 `enabled` 这类信号是数据筛选的契约。

### 7.2 PR（Positive Ratio）/ 置信度筛选

comma four 的新 UI 引入了"**confidence ball（置信度球）**"：当 openpilot 对场景理解置信度上升，球会上升并变绿；接近转向极限时，转向弧会生长警示用户。这暗示端侧模型持续输出"置信度/质量分"。在云端，类似的"模型置信度 + 接管信号"被用作数据筛选依据——低置信度段、接管段会被优先拉取进入下一轮训练集。社区资料中将此类筛选与"PR（Positive Ratio）"概念关联：即模型在一段中输出"可接受/正面"决策的比例，比例异常的段更值得回炉。

### 7.3 数据质量评分

- **fork 准入契约**本身就是质量门（语义一致才进训练集）；
- **comma10k 标注质量**：有 CI 检查（如 `files_trainable`、文件大小检查、mask 调色板模式校验），PR 需通过测试；
- **bootlog/崩溃**：设备健康度差、频繁崩溃的段会被降权；
- **segment 完整性**：缺失关键流的段会被丢弃。

---

## 8. 训练数据集构建

### 8.1 数据标注

comma 的标注策略是"自动标注为主 + 众包标注为辅"：
- **自动标注**：内部 segnet（未开源，太大）对 comma10k 图像产出概率分割；
- **众包标注**：comma10k 由公众通过 PR 标注掩码，6 类（road / lane markings / undrivable / movable / my car / movable in my car）；
- **驾驶员监控标注**：DM 数据集"增量加入 incoming comma four segments"，标注头部/眼睛姿态；
- **世界模型训练**：用真实段训练 VAE 压缩模型与驾驶视觉模型，再在仿真中 on-policy 生成更多"标注"。

### 8.2 公开数据集

- **comma10k**：10,000 张真实驾驶 PNG（来自 comma 车队），MIT 协议，社区标注；imgs（路面）/ imgs2（配对鱼眼）/ imgsd（Comma3 驾驶员摄像头）；
- **comma2k19**：加州 I-280 高速 San Jose↔San Francisco 之间 20km 路段，2019 段、每段 1 分钟、共 33+ 小时通勤，完全可复现可扩展；
- **模型报告**：`commaai.github.io/model_reports` 公开最新模型指标。

### 8.3 数据集划分与版本管理

- **train/val/test**：comma10k 以文件名以 "9.png" 结尾的图像作验证集（CCE loss 0.051 基线，被社区刷到 0.045）；
- **版本管理**：通过 dataset 列表文件显式版本化，如训练命令中 `dataset=/home/batman/xx/datasets/lists/train_500k_20250717.txt`（50 万段、2025-07-17 版本）；
- **模型版本**：训练产物按 uuid 存入 mkv 模型阵列，reporter 追踪全生命周期；
- **driver monitoring 数据集**：按设备类型分布（comma 3/3X/four）切片，0.10.3 起显式纳入 comma four 段。

---

## 9. 模型发布与 OTA

### 9.1 模型训练

comma 的训练已从"纯离线模仿学习"演进到"**on-policy 世界模型仿真训练**"：
- **Vision Model**：从真实段学习视觉特征；
- **VAE Compression Model**：把视觉帧压缩到低维 latent（0.10.1 起新架构与训练目标）；
- **Driving Vision Model**：在 latent 空间预测未来（0.10.1 起 4x 段训练）；
- **World Model**：0.10.1 移除全局定位输入、参数量 2x、段数 4x；0.11.0 起驾驶模型**完全用学习型仿真器训练**；
- **on-policy 训练**：训练中用最新权重跑仿真 rollout 生成新训练数据，引入物理噪声模型（0.10.3 起噪声从无噪声初值开始，是 mlsim 训练的必要改动）；训练命令示例：
  ```
  ./training/train.sh N=4 partition=tbox2 trainer=mlsimdriving \
    dataset=.../train_500k_20250717.txt vision_model=<uuid>/500 \
    data.shuffle_size=125k optim.scheduler=COSINE bs=4
  ```
- **Driver Monitoring Model**：独立训练，0.11.1 改进驾驶员摄像头图像处理流水线。

### 9.2 模型验证

- **SIL 测试**：openpilot 每次提交跑软件在环测试（`.github/workflows/tests.yaml`）；
- **HIL 测试**：内部 Jenkins 硬件在环测试套件；panda 有独立 HIL 安全测试；
- **回放测试壁橱**：一个含 10 台 comma 设备的测试壁橱持续回放 route，跑最新 openpilot；
- **指标公开**：model_reports 对公众开放，社区可监督；
- **controls challenge leaderboard**：`comma.ai/leaderboard`，用 miniray 在 ~1 小时内跑完大规模并行验证。

### 9.3 模型发布（分级分支）

openpilot 的发布遵循四级分支策略（comma four 用 `release-mici` 系列，comma 3X 用 `release-tizi` 系列）：

| 分支 | comma four | comma 3X | 安装 URL | 说明 |
|------|-----------|----------|----------|------|
| release | release-mici | release-tizi | openpilot.comma.ai | 正式发布版 |
| staging | release-mici-staging | release-tizi-staging | openpilot-test.comma.ai | 预发布，略提前 |
| nightly | nightly | nightly | openpilot-nightly.comma.ai | 前沿开发版，不稳定 |
| nightly-dev | nightly-dev | nightly-dev | installer.comma.ai/commaai/nightly-dev | 含实验性车型特性 |

设备首次安装时，在 comma four 配置向导中输入上述 URL 即可拉取对应分支；也可用 `bash <(curl -fsSL openpilot.comma.ai)` 快速启动。

### 9.4 OTA 更新

- **通道**：comma four 内置 Wi-Fi + LTE，开机即可收 OTA；
- **触发**：设备周期性检查所在分支的更新；
- **web flasher**：`flash.comma.ai` 提供向导式恢复出厂，0.10.3 起用自定义 USB Vendor ID 简化 comma four 刷写步骤；
- **发布节奏**：约每 2~3 个月一个 minor 版本——0.10.1（2025-09）、0.10.2（2025-11，comma four 支持）、0.10.3（2025-12）、0.11.0（2026-03）、0.11.1（2026-05）、0.11.2（2026-06）。每个版本几乎都带"新驾驶模型 / 新 DM 模型"，OTA 即模型迭代下发。

---

## 10. 与 Tesla / Waymo 数据闭环对比

### 10.1 三家路线速览

- **Tesla**：整车厂前装，纯视觉，车队学习（Fleet Learning），221 条 rule-based triggers 挖掘难例，7 轮影子模式产出 ~100 万个 10s 视频片段，自动标注 + 超算（Dojo/Cortex），端到端大模型，闭源。
- **Waymo**：自营 Robotaxi 车队，激光雷达+摄像头+雷达多模态，Waymo Open Dataset 开源样本，仿真（Surfel/Block-NeRF 场景重建、Chanandler 知识挖掘），闭源，L4 级。
- **comma**：后装硬件 + 开源软件，纯视觉，众包车队（用户自有车），自建数据中心 600 GPU，世界模型仿真 on-policy 训练，Firehose 全量上传，MIT 开源。

### 10.2 对比表

| 维度 | Tesla Shadow Mode | Waymo 数据闭环 | comma.ai 数据闭环 |
|------|-------------------|----------------|-------------------|
| 数据来源 | 前装量产车（数百万辆） | 自营 Robotaxi 车队（数千辆） | 后装用户车（comma 3X/four，10k+ 台） |
| 传感器 | 纯视觉（8 摄像头）+ 雷达 | 激光雷达 + 摄像头 + 雷达 + 音频 | 纯视觉（三摄 360°）+ CAN/GPS/IMU |
| 采集方式 | 触发式（triggers）+ 影子模式 | 全量 + 任务驱动 | 默认全量上传 + Firehose 模式 |
| 标注 | 自动标注为主（Auto Labeling） | 自动标注 + 人工复核 | 自动标注 + comma10k 众包 |
| 筛选信号 | 221 条 rule triggers、7 轮影子 | 接管、难例挖掘 | engage/disengage、置信度（PR）、接管 |
| 训练算力 | Dojo / Cortex 超算 | Google 自有算力 | 自建 600 GPU 数据中心（~$5M） |
| 仿真 | 仿真 + 真实数据 | Surfel/Block-NeRF 重建仿真 | tinysim 重投影 → mlsim 世界模型仿真（on-policy） |
| 模型分发 | OTA（整车厂通道） | OTA（自营车队） | OTA（release/staging/nightly URL） |
| 开源程度 | 闭源 | 闭源（仅开放数据集样本） | openpilot MIT 开源 + connect 开源 + 模型指标公开 |
| 隐私 | 用户授权车队学习 | 自营数据，无 C 端隐私问题 | 默认上传，可关闭；驾驶员摄像头 opt-in |
| 激励 | 车价内含 | 无（公司自营） | 免费 3 天 + prime 订阅 + commacare 延保 |
| ODD | 广泛（FSD 城市/高速） | 限定区域 L4 | 300+ 车型高速/城市辅助（L2+） |
| 数据所有权 | Tesla | Waymo | comma（用户授予不可撤销使用权） |

### 10.3 comma 的差异化本质

1. **"开源 + 后装"绕开了整车厂壁垒**：comma 不造车，却通过 car harness 接入 300+ 车型，把存量车变成数据采集器；
2. **"默认上传 + Firehose"最大化数据吞吐**：相比 Tesla 的触发式采集，comma 在带宽允许时近乎全量上传；
3. **"世界模型仿真"替代超大规模真实车队**：comma 没有百万辆车，但用 mlsim 在 on-policy 训练中合成无限 rollout，把"数据规模"问题转化为"仿真逼真度"问题；
4. **"自建数据中心"把边际成本压到接近零**：1TB/s 直读原始数据、无冗余存储、slurm + miniray 极简调度，让小团队也能跑大规模训练；
5. **"模型指标公开"建立信任**：model_reports 对公众开放，是开源生态的信任基石。

---

## 11. AuroraDrive 迁移建议

### 11.1 AuroraDrive 现状定位

AuroraDrive 当前以"**仿真模式采集数据**"为主：即在仿真环境中生成驾驶场景与传感器数据，用于训练与评测。这一模式的优点是可控、可复现、低成本、可无限生成边缘场景；但核心短板是：
- **仿真到真实的 sim-to-real gap**：仿真数据的视觉/物理真实度有限，模型在仿真上表现好不代表真路好；
- **缺乏真实接管信号**：仿真中没有真实人类驾驶员的"修正轨迹"作为模仿学习目标，难以学到"人类式稳健"的驾驶策略；
- **ODD 长尾覆盖依赖仿真场景设计**：仿真能覆盖的"未知长尾"受限于设计者想象力；
- **缺少设备健康度/真实环境噪声**：真实车的振动、光照突变、传感器脏污、CAN 延迟等噪声难以完全仿真。

### 11.2 借鉴 Comma Connect 数据闭环的核心思路

comma 的成功证明了一个关键命题：**对纯视觉 L2+ 辅助驾驶，"小规模真实车队 + 全量上传 + 世界模型仿真 on-policy 训练"可以匹敌甚至超越"超大规模真实车队 + 触发式采集"**。其可迁移要素：

1. **从"纯仿真"走向"仿真 + 真实数据"双轮**：仿真负责扩规模与长尾，真实数据负责校准 sim-to-real gap；
2. **世界模型仿真器（mlsim 模式）**：用真实数据训练世界模型，再在世界模型里 on-policy rollout 生成训练数据，把仿真从"人工建场景"升级为"学习型仿真";
3. **自建轻量数据中心**：不必上云，600 GPU + 4PB SSD 的规模对中型团队可行；
4. **分级 OTA + 公开指标**：release/staging/nightly 分级放量，指标公开建立内部信任与外部公信;
5. **数据契约先行**：在采集之初就固定消息结构语义（comma 的 cereal stock 字段不可改契约），保证后续数据可被统一管线消化。

### 11.3 AuroraDrive 数据闭环方案（建议）

**阶段一：真实数据采集层（补齐"真实"短板）**
- **采集载体**：参考 comma 后装路线，为 AuroraDrive 配置少量测试车（或合作车辆），搭载与仿真一致的传感器套件（纯视觉三摄 + CAN + GPS/IMU）；
- **采集契约**：定义不可变的 stock 消息结构（类比 cereal），明确 `enabled/engage`、转向角、车速等字段语义，所有采集车辆与仿真侧必须同构；
- **默认全量 + Firehose**：测试车默认全量上传段（1 分钟/段），关键车型开启 Firehose 模式上传高质量流；
- **engage/disengage 标注**：记录每次 AuroraDrive 接管/退出的事件，作为高价值负样本。

**阶段二：云端基础设施（参考 comma 数据中心）**
- **存储**：mkv 风格分布式 KV 存储，无冗余主阵列（真实段可再采）+ 有冗余模型阵列；按段（segment）索引，dongle ID + 时间戳；
- **算力**：自建 GPU 集群（哪怕从几十块 GPU 起步），slurm 调度 + PyTorch FSDP 分布式训练；
- **任务调度**：引入 miniray 风格轻量调度器，把测试/推理/数据预处理/on-policy rollout 都统一到"空闲机即 worker"模型；
- **实验追踪**：自建 reporter，模型按 uuid 管理，指标内部公开（条件成熟时对外开放）。

**阶段三：世界模型仿真训练（核心迁移点）**
- **第一阶段（tinysim）**：先用重投影式仿真器，把真实段的重投影作为 rollout 环境，跑通 on-policy 训练管线；
- **第二阶段（mlsim）**：用真实段训练 VAE 压缩模型 + 驾驶视觉模型 + 世界模型，再在世界模型 latent 空间做 on-policy rollout；引入"从无噪声初值开始的物理噪声模型"（comma 0.10.3 的关键改动），保证 rollout 稳定；
- **训练命令范式**：沿用 `trainer=mlsimdriving dataset=...txt vision_model=<uuid> bs=4` 的解耦设计——数据集、视觉模型、训练器、batch size 全部参数化；
- **数据集版本化**：用显式列表文件（如 `train_NNNk_YYYYMMDD.txt`）管理每次训练的数据切片，可回溯。

**阶段四：数据筛选与质量门**
- **PR/置信度筛选**：端侧输出置信度，云端优先拉取低置信度段与接管段；
- **fork/外部数据准入**：若引入第三方数据，强制 stock 字段语义不变，保证可消化；
- **bootlog/健康度**：采集设备健康度，降权不健康段；
- **comma10k 式众包**：对感知标注任务开放众包 PR，CI 校验掩码质量。

**阶段五：分级 OTA 与验证**
- **四级分支**：release / staging / nightly / nightly-dev，对应不同 URL/通道；
- **SIL + HIL + 回放壁橱**：每次提交跑 SIL，定期跑 HIL，建设"10 台设备回放壁橱"持续跑最新版本；
- **指标 dashboard**：对内/对外公开模型指标，建立信任；
- **web flasher**：提供向导式设备恢复工具，降低现场维护成本。

**阶段六：用户/合作方参与（若走向 C 端）**
- **Freemium 存储**：免费短期存储 + 订阅长期存储，换取持续数据贡献；
- **远程能力**：实时 GPS、远程拍照、SSH，提升合作方/用户黏性；
- **延保绑定**：参考 commacare，用保修绑定持续订阅与数据贡献。

### 11.4 迁移路线图（建议节奏）

| 阶段 | 周期 | 关键里程碑 |
|------|------|-----------|
| 1. 真实采集层 | 0~3 月 | 采集契约定稿，首批测试车上路，全量上传跑通 |
| 2. 云端基础设施 | 1~4 月 | mkv 存储 + slurm + reporter 上线，可训练 |
| 3. tinysim on-policy | 3~6 月 | 重投影仿真训练管线跑通，首个模型产出 |
| 4. mlsim 世界模型 | 6~12 月 | VAE + 世界模型训练完成，on-policy 训练稳定 |
| 5. 筛选与质量门 | 持续 | PR 筛选、置信度筛选、众包标注上线 |
| 6. 分级 OTA | 6 月起 | release/staging/nightly 上线，回放壁橱运转 |
| 7. C 端参与（可选） | 12 月+ | 订阅制、远程能力、延保绑定 |

### 11.5 风险与取舍

- **sim-to-real 不会消失**：世界模型仿真再好，仍需真实数据持续校准，AuroraDrive 不应放弃仿真优势，而应"仿真为主 + 真实校准"；
- **数据合规**：comma 的隐私模型对用户宽松（数据归 comma），AuroraDrive 若在国内运营需符合《个人信息保护法》《汽车数据安全管理若干规定》，对人脸/位置/车外敏感数据需做脱敏与本地化处理，比 comma 更严；
- **小车队数据规模**：comma 靠 mlsim 弥补车队规模不足，AuroraDrive 同样必须把"世界模型仿真"作为核心，否则真实数据量不足以训练强模型；
- **开源 vs 闭源**：comma 的开源生态是其数据飞轮的重要推手（社区贡献车型/标注/数据），AuroraDrive 需权衡是否开源部分组件以换取生态。

---

## 12. 关键事实索引（供后续核查）

| 事实 | 来源 |
|------|------|
| openpilot 默认上传驾驶数据，驾驶员摄像头需 opt-in | github.com/commaai/openpilot README（User Data and comma Account） |
| 免费存 3 天 / prime 存 1 年；prime $24/mo、lite $14/mo | comma.ai/connect |
| comma four：Snapdragon 845 MAX，1/5 体积，$999，2025-11-25 发布 | blog.comma.ai/comma-four |
| 自建数据中心 600 GPU / 75 TinyBox Pro / ~4PB SSD / ~$5M / 450kW | blog.comma.ai/datacenter |
| mkv 存储 ~1TB/s 直读原始数据训练；slurm + miniray + pytorch FSDP | blog.comma.ai/datacenter |
| 0.11.0 驾驶模型完全用学习型仿真器训练 | github.com/commaai/openpilot RELEASES.md |
| 0.10.3 Cool People's Model，temporal policy 改因果注意力，mlsim 训练 | blog.comma.ai/0103release |
| Firehose Mode 最大化上传训练数据 | blog.comma.ai/098release + 0.10.3 引导 |
| connect 是 React+Redux+Material-UI PWA，bun+Vite | github.com/commaai/connect README |
| comma10k：10k PNG 众包语义分割，MIT | github.com/commaai/comma10k |
| comma2k19：I-280 20km，2019 段，33+ 小时 | cloud.tencent.com/developer/news/374939 |
| 模型指标公开：commaai.github.io/model_reports | blog.comma.ai/datacenter |
| 四级分支：release-mici/tizi、staging、nightly、nightly-dev | github.com/commaai/openpilot README |
| fork 数据准入契约：cereal 兼容、stock 字段不改、不引入未支持车型 | CONTRIBUTING.md "Contributing Training Data" |
| comma 拥有所有数据，不可撤销永久全球使用权 | comma.ai/privacy |

---

## 13. 结论

comma.ai 的数据闭环是一个"**用开源换车队、用订阅换持续上传、用世界模型仿真换数据规模、用自建数据中心换边际成本**"的精巧工程闭环。它既没有 Tesla 的整车厂体量，也没有 Waymo 的自营 L4 车队，却通过四个关键设计——**后装硬件 + 默认全量上传 + 世界模型 on-policy 仿真 + 自建轻量数据中心**——在纯视觉 L2+ 赛道上跑出了独立路线。

对 AuroraDrive 而言，最具启发性的不是 comma 的某个单点技术，而是其"**把真实数据当作仿真的校准器、把仿真当作真实数据的放大器**"的双轮哲学。AuroraDrive 当前以仿真为主的路线不必推倒重来，但应当尽快补齐"真实数据采集 + 世界模型仿真 on-policy 训练"这一环，并辅以分级 OTA、数据契约、自建轻量数据中心，才能从"仿真可用"迈向"真路可靠"。

---

> **实际工具调用次数：66 次**
> （WebSearch × 33，WebFetch × 17，Read × 4，RunCommand × 1，Write × 1，其中部分 WebFetch 因 deadline 重试）
