/**
 * 全站文案与数据 —— 唯一内容来源
 *
 * 铁律：所有数字、功能名、技术描述只能引用 BRIEF.md。
 * 本文件不引入 BRIEF 之外的产品事实。
 */

export interface FeatureItem {
  /** 序号标记（仪表盘语汇） */
  index: string
  title: string
  body: string
  /** 底部来源引用，如 `OpticalFlowBridge.swift:88` */
  source?: string
  /** 特性分类，用于图标选择 */
  icon?: FeatureIcon
}

export type FeatureIcon =
  | 'capture'
  | 'inference'
  | 'inject'
  | 'network'
  | 'ocr'
  | 'agent'
  | 'map'
  | 'shield'
  | 'display'
  | 'docs'
  | 'license'
  | 'process'

export interface StatItem {
  /** 主数值（等宽 + tabular-nums） */
  value: number
  /** 小数位数 */
  decimals?: number
  /** 单位，不参与滚动计数 */
  unit?: string
  label: string
  note?: string
  /** 对比型指标：旧值 → 新值并置 */
  compare?: { from: string; to: string; unit?: string }
}

export interface FaqItem {
  q: string
  a: string
}

export interface PricingPlan {
  id: string
  name: string
  tagline: string
  price: string
  priceNote: string
  featured?: boolean
  ctaLabel: string
  ctaHref: string
  /** 该档真实包含的支持 */
  includes: string[]
}

export interface ComparisonRow {
  label: string
  /** 每档的取值：'yes' | 'no' | 'partial' | 文本 */
  values: Array<'yes' | 'no' | 'partial' | string>
}

export interface TeamMember {
  /** 角色位（非虚构人名） */
  role: string
  scope: string
  /** 头像字符（抽象几何头像首字母） */
  initial: string
  /** 头像渐变起止色（CSS 渐变，非人像） */
  gradient: [string, string]
}

export interface Testimonial {
  /** 场景/角色，而非具体人名 */
  persona: string
  role: string
  quote: string
  /** 可验证的事实（等宽），不使用星级评分 */
  fact: string
  /** 头像字符 */
  initial: string
  gradient: [string, string]
}

/* ============================================================
   站点元信息
   ============================================================ */

export const siteMeta = {
  name: 'AuroraDrive',
  tagline: '看得见 → 想得出 → 按得下',
  description:
    'AuroraDrive 是运行在 macOS 上的第三方《异环》(NTE) 视角自动驾驶系统：屏幕实时截屏送入端到端神经网络，推理出转向/油门/刹车，再以真实按键事件注入游戏。',
  license: 'GPL-3.0-or-later',
  repo: 'https://github.com/DuoduoChubbyKitty/AuroraDrive',
  author: 'DuoduoChubbyKitty',
}

/* ============================================================
   导航
   ============================================================ */

export const navigation = [
  { label: '首页', to: '/' },
  { label: '架构与实现', to: '/architecture' },
  { label: '文档与快速开始', to: '/docs' },
  { label: '开源与免费', to: '/pricing' },
  { label: '关于项目', to: '/about' },
  { label: '联系', to: '/contact' },
]

/* ============================================================
   Hero
   ============================================================ */

export const heroContent = {
  eyebrow: 'macOS · 视角自动驾驶',
  title: '让神经网络\n替你踩油门',
  /** 标题中用极光渐变的关键词（仅一个） */
  gradientWord: '踩油门',
  lead: 'AuroraDrive 把《异环》的实时画面送进端到端神经网络，推理出转向、油门与刹车，再用真实按键事件打回游戏。模型不靠谱时，系统会自己退到更笨但更稳的规则档 —— 而不是直接失控。',
  primaryCta: { label: 'git clone 跑起来', to: '/docs#quick-start' },
  secondaryCta: { label: '看三档降级架构', to: '/architecture' },
  /** Hero 右下角免责角标 —— BRIEF 第六节原文 */
  disclaimer:
    '本项目仅供研究与个人学习使用。使用本软件自动控制游戏可能违反游戏服务条款，作者不对封号或其他任何后果负责，请自行评估风险。',
  /** 右侧仪表读数 */
  readouts: [
    { label: '推理 tick', value: '15Hz', tone: 'accent' as const },
    { label: '抓屏帧率', value: '15fps', tone: 'accent' as const },
    { label: '光流 p95', value: '1.91ms', tone: 'plain' as const },
    { label: '当前档位', value: '端到端主驾', tone: 'accent' as const },
  ],
  /** Hero 视觉位右下的真实管线说明 */
  pipelineCaption:
    '捕获 → 推理 → 注入，三段闭环。双进程 + 共享内存 v3。',
}

/* ============================================================
   功能特性网格
   ============================================================ */

export const featureGrid = {
  eyebrow: '核心能力',
  title: '每一档能力，都带一个可验证的数字',
  lead: '下面每张卡片都对应源码里的一处实现与一个实测值。写不出数字的卖点，我们不写。',
  items: [
    {
      index: '01',
      title: '三档降级状态机',
      body: '端到端主驾（E2E / M9 单目模型）→ YOLO 接管 → 纯规则兜底。单调降级配滞回恢复：degradeHealth = 0.65、recoverHysteresis = 0.15，阈值在 UI 上实时可调。',
      source: 'DegradeStateMachine.swift:5-9',
      icon: 'shield' as const,
    },
    {
      index: '02',
      title: '一个模型，三个任务',
      body: 'YOLOPX 单模型同时输出 det（目标检测）、da（可行驶区域）、ll（车道线）三个头。ayolom 档每 tick 都跑，legacy 档偶数帧跑。',
      source: 'YolopxEngine.swift',
      icon: 'inference' as const,
    },
    {
      index: '03',
      title: '双进程 + 共享内存 v3',
      body: 'UI 与引擎是两个长驻进程，经 /aurora_frame_v1 共享内存传帧与检测数据。协议版本 v3；pixelsOffset 从 20480 改为 28672 后会做版本校验，不匹配就明确报错而非静默错位。',
      source: 'EngineClient.swift:61-65',
      icon: 'process' as const,
    },
    {
      index: '04',
      title: '光流补帧，实测选型',
      body: 'OpenCV DIS 光流 ULTRAFAST 在本机 640×640 实测 p95 为 1.91ms，单核退化到 3.78ms。同批对照 Apple VTOpticalFlow 需 10.28ms、Vision 需 27.43ms —— 官方硬件光流反而慢 5 到 14 倍。',
      source: 'OpticalFlowBridge.swift:88-93',
      icon: 'capture' as const,
    },
    {
      index: '05',
      title: '网络坐标定位',
      body: 'libpcap 抓 UE5 移动同步包，过滤器 tcp port 30031 or udp，解码位流得到世界坐标与朝向，映射到 13056×13056 大地图像素空间。三级新鲜度：live ≤18s / recent ≤40s / stale ≤90s / lost >90s。',
      source: 'CoordinateCapture.swift:1052',
      icon: 'network' as const,
    },
    {
      index: '06',
      title: '速度识别，三层校验',
      body: '主路径是 PP-OCRv6 微调整行模型（int8 量化、GPU 推理），备用是逐位 CNN。三层校验依次为 Layer 1 量程、Layer 2 跳变、Layer 3 多帧确认。',
      source: 'SpeedOCRReader.swift:638-653',
      icon: 'ocr' as const,
    },
    {
      index: '07',
      title: 'AI 助手，真对话 + 自主调工具',
      body: '大模型流式对话，增量按 15Hz 节流，候选链最多尝试 4 个，全链失败才回退本地套话并标注「离线回复」。30 个工具挂载，其中 15 个技能已实装。',
      source: 'ToolRegistry.swift:16-23',
      icon: 'agent' as const,
    },
    {
      index: '08',
      title: '路网先验，断头率 19.3% → 5.4%',
      body: 'models/route_graph.json 实测 664 节点 / 932 边。加入先验后节点从 612 增至 664、边从 825 增至 932，断头率从 19.3% 降到 5.4%。',
      source: 'route_graph.json',
      icon: 'map' as const,
    },
    {
      index: '09',
      title: '显示增强，绝不进决策链路',
      body: 'MetalGoose 引擎提供 MetalFX 空间超分与时域插帧，但只作用于人眼观看的叠加层。为了画面更顺滑而给决策链路加延迟，等于让车反应变慢 —— 所以不这么干。',
      source: 'CaptureEngine.swift:128-130',
      icon: 'display' as const,
    },
    {
      index: '10',
      title: '权限自动化，一次输入',
      body: '首次启动在 App 内输入一次管理员密码，自动安装 com.aurora.bpf-setup LaunchDaemon，之后每次开机自动恢复 /dev/bpf* 读写权。',
      source: 'README · 权限说明',
      icon: 'shield' as const,
    },
    {
      index: '11',
      title: '任务面板 OCR',
      body: '读取游戏左侧任务面板文字，查 models/quest_index.json 换算世界坐标目标。默认开启，每 0.7s 一次 Vision OCR。',
      source: 'QuestPanelReader.swift:414-431',
      icon: 'ocr' as const,
    },
    {
      index: '12',
      title: '开源，GPL-3.0-or-later',
      body: '全部原始源码带 SPDX 头，SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty。第三方依赖与许可证在页脚单列致谢，含 MaaNTE 的 AGPL-3.0 传染性说明。',
      source: 'NOTICE · README 致谢表',
      icon: 'license' as const,
    },
  ],
}

/* ============================================================
   数据统计区
   ============================================================ */

export const statsSection = {
  eyebrow: '实测数据',
  title: '这些数字都来自本机跑出来的，不是标称值',
  lead: '光流那一组是 ABBA 交错同批实测，对照组与实验组在同一台机器同一批次里交替跑，避免温度与频率漂移带来的偏差。',
  items: [
    { value: 15, unit: 'Hz', label: '推理 tick 频率', note: '两档一致，应急冲刺时提到 20' },
    { value: 15, unit: 'fps', label: '抓屏帧率', note: '两档一致，与 tick 同频' },
    { value: 1.91, decimals: 2, unit: 'ms', label: 'OpenCV DIS 光流 p95', note: '全核 640×640，单核退化 3.78ms' },
    { value: 664, unit: '', label: '路网节点', note: '932 条边，断头率 5.4%' },
    { value: 30, unit: '', label: 'AI 工具挂载数', note: '15 个技能已实装' },
    { value: 67720, unit: '行', label: '源码规模', note: '74 个 Swift 文件' },
  ] satisfies StatItem[],
}

/* ============================================================
   快速开始（BRIEF 第七节原文，逐字照抄）
   ============================================================ */

export const quickStart = {
  env: '环境要求：macOS 26+ · Apple Silicon · Xcode Command Line Tools · libpcap（系统自带）',
  code: `git clone https://github.com/DuoduoChubbyKitty/AuroraDrive.git
cd AuroraDrive
./run.sh            # 编译 + 签名 + 启动
./run.sh --status   # 只检查环境`,
  permissions: '系统权限：屏幕录制 + 辅助功能（系统设置 → 隐私与安全）',
  statusLine: './run.sh --status  →  environment OK',
}

/* ============================================================
   定价 —— 三档「支持开源」，不卖许可
   ============================================================ */

export const pricingSection = {
  eyebrow: '开源免费',
  title: '全部免费，一分钱不用付',
  lead: 'AuroraDrive 是 GPL-3.0-or-later 开源项目。源码、模型、文档、构建脚本全部公开，任何人可免费获取、修改、分发、运行。下面三档都是 ¥0 —— 没有付费墙，没有功能阉割，也不售卖软件许可。',
  plans: [
    {
      id: 'community',
      name: '社区版',
      tagline: '完整功能，一分不收',
      price: '¥0',
      priceNote: '永久免费 · 无需注册 · 无功能阉割',
      ctaLabel: '直接克隆仓库',
      ctaHref: '/docs#quick-start',
      includes: [
        '完整源码与构建脚本（GPL-3.0-or-later）',
        '全部模型文件与路线先验 route_graph.json',
        '40 篇架构文档，文件:行号 级引用',
        'Issue 区提问与讨论',
        '所有三档降级与工具链功能，无功能阉割',
      ],
    },
    {
      id: 'supporter',
      name: '支持者',
      tagline: '同样免费，只是多一个身份',
      price: '¥0',
      priceNote: '永久免费 · 源码许可不变',
      featured: true,
      ctaLabel: '参与贡献',
      ctaHref: '/contact',
      includes: [
        '社区版全部内容，功能完全一致',
        'Issue 区被优先看见（志愿者身份标识）',
        '参与路线图讨论与功能提案',
        '署名致谢（可选择匿名）',
        '源码许可与义务完全不变，仍为 GPL-3.0-or-later',
      ],
    },
    {
      id: 'enterprise',
      name: '企业定制',
      tagline: '同样免费，只是额外搭把手',
      price: '¥0',
      priceNote: '永久免费 · 源码许可不变',
      ctaLabel: '免费咨询',
      ctaHref: '/contact',
      includes: [
        '支持者全部内容，功能完全一致',
        '二次开发对接：模型替换、工具接入、协议版本对齐',
        '私有分支与内网部署方案',
        '针对自研路网数据的路线先验重建',
        '培训与文档定制（基于你方代码库）',
      ],
    },
  ] satisfies PricingPlan[],
  comparison: [
    {
      label: '完整源码',
      values: ['yes', 'yes', 'yes'],
    },
    {
      label: '本地自行构建运行',
      values: ['yes', 'yes', 'yes'],
    },
    {
      label: '全部功能，无阉割',
      values: ['yes', 'yes', 'yes'],
    },
    {
      label: '价格',
      values: ['¥0', '¥0', '¥0'],
    },
    {
      label: 'Issue 响应',
      values: ['社区讨论区', '社区讨论区', '社区讨论区'],
    },
    {
      label: '环境与权限排查协助',
      values: ['partial', 'partial', 'yes'],
    },
    {
      label: '降级阈值调优建议',
      values: ['partial', 'partial', 'yes'],
    },
    {
      label: '路线先验增量更新',
      values: ['no', 'no', 'yes'],
    },
    {
      label: '二次开发对接',
      values: ['no', 'partial', 'yes'],
    },
    {
      label: '私有分支与内网部署',
      values: ['no', 'no', 'yes'],
    },
    {
      label: '出售软件许可',
      values: ['no', 'no', 'no'],
    },
  ] satisfies ComparisonRow[],
  footnote:
    '三档全部为 ¥0。源码许可始终为 GPL-3.0-or-later，本项目不售卖软件许可，也不以任何形式限制商用。三档之间的差别只在于社区参与程度与协作深度，不在于功能与价格。',
}

/* ============================================================
   FAQ —— ≥8 条，问真问题
   ============================================================ */

export const faqSection = {
  eyebrow: '常见问题',
  title: '那些真正会拦住你上手的问题',
  lead: '下面每条答案都基于仓库里的真实实现。没把握的地方我们直接说「没有」。',
  items: [
    {
      q: '用这个会被封号吗？',
      a: '有可能。项目仅供研究与个人学习使用，使用本软件自动控制游戏可能违反游戏服务条款，作者不对封号或其他任何后果负责，请自行评估风险。我们不会说「绝对不会封号」——那不是我们能保证的事。',
    },
    {
      q: '我能自己跑起来吗？需要什么？',
      a: '能，前提是 macOS 26+、Apple Silicon 芯片、装了 Xcode Command Line Tools，libpcap 系统自带。还需要在系统设置 → 隐私与安全里授予屏幕录制与辅助功能权限，并给一次管理员密码用于自动安装 BPF LaunchDaemon。环境齐了之后 ./run.sh --status 可以只做检查。',
    },
    {
      q: '它和「写个脚本定时按键」有什么区别？',
      a: '脚本按键是开环的：动作和画面无关。AuroraDrive 是闭环 —— 每一帧都重新看、重新判断，再决定按什么键。感知模型不可靠时它会退到规则档继续跑，而不是维持一个已经过时的按键序列。',
    },
    {
      q: '模型从哪来？我能换成自己的吗？',
      a: '仓库自带端到端 M9 单目模型、YOLOPX 三合一模型、PP-OCRv6 int8 量化模型与逐位 CNN 权重，都在 models/ 目录。模型是标准 CoreML 文件，可以换成自己的 CoreML 模型，但需要保持输入输出约定一致，源码位置见 YolopxEngine.swift 与 SpeedOCRReader.swift。',
    },
    {
      q: '性能占用高吗？我的机器扛得住吗？',
      a: '推理 tick 15Hz、抓屏 15fps，光流 p95 1.91ms。但 YOLOPX 单次推理约 60ms（148 GFLOPs，ANE 峰值 9.26 TFLOPS，效率约 26%），这是三档里最重的一档。Apple Silicon 是硬性要求，Intel Mac 不在支持范围内。',
    },
    {
      q: '系统的安全边界在哪？会不会乱按？',
      a: 'AI 助手这边有四道护栏，全部是「明确报错、不静默」：观测模式 AURORA_OBSERVE_ONLY 拒绝一切注入、游戏不可见时拒绝、辅助功能未授权时拒绝、dryRun 模式不注入但返回结构完整的结果。操作游戏界面的唯一可靠路径是 ESC → 截图 → 鼠标点击。',
    },
    {
      q: '30 个工具都能用吗？',
      a: '不能。30 是挂载数：18 技能 + 4 键位 + 1 文本 + 3 鼠标 + 2 观察 + 2 搜索。18 个技能里已实装的是 15 个，pinkpaw、rhythm、preset_realtime 三个尚未移植，调用会返回 ok=false。我们把这个边界写在这里，而不是让你自己撞上。',
    },
    {
      q: '网络断了会怎样？',
      a: '坐标定位有三级新鲜度：live ≤18s、recent ≤40s、stale ≤90s、超过 90s 判为 lost。recent 起不再参与决策（更保守），陈旧状态只如实标注、不闪断。视觉定位不会顶班 —— 那条路径不存在。',
    },
    {
      q: '显示增强会不会拖慢决策？',
      a: '不会，而且这是刻意的架构红线。MetalFX 超分与插帧只作用于人眼观看的叠加层，绝不进入「捕获 → 推理 → 按键注入」的决策链路。为了画面更顺滑而给决策加延迟，等于让车反应变慢。',
    },
    {
      q: '这个项目能商用吗？',
      a: '项目自身是 GPL-3.0-or-later，衍生作品需遵循 GPL 义务。网络定位算法蓝本 MaaNTE 是 AGPL-3.0，具有传染性，其源码不随本仓库分发，仅本地参考并在致谢中标注。如果你要商用，请自行评估这两份许可证的义务 —— 我们提供的是支持服务，不是许可豁免。',
    },
  ] satisfies FaqItem[],
}

/* ============================================================
   团队 —— 角色位，不虚构人名
   ============================================================ */

export const teamSection = {
  eyebrow: '维护结构',
  title: '按角色位划分的维护分工',
  lead: '本项目目前由单一作者维护。下面展示的是代码库真实存在的职能分区，不是虚构的人物列表 —— 所以用角色位而非人名呈现。',
  members: [
    {
      role: '核心维护者 · 感知与推理',
      scope: 'CoreML 模型接入、YOLOPX 三合一推理、PP-OCRv6 速度识别、端到端主驾档的决策链路。全部源码的作者与版权持有人。',
      initial: 'D',
      gradient: ['#35E0A1', '#7C8CF8'],
    },
    {
      role: '端到端主驾 · 训练与评测',
      scope: 'M9 单目模型的训练数据整理、推理耗时与吞吐评测、光流补帧与检测结果的时序对齐。',
      initial: 'E',
      gradient: ['#7C8CF8', '#C56CF0'],
    },
    {
      role: '工具链与 Agent · 交互设计',
      scope: 'ToolRegistry 工具注册表、候选链与 15Hz 节流、大模型流式对话面板与四道护栏的交互呈现。',
      initial: 'T',
      gradient: ['#35E0A1', '#4EA8FF'],
    },
    {
      role: '地图与定位 · 数据工程',
      scope: 'route_graph.json 路线先验的构建与断头率优化、网络坐标解码、大地图像素空间映射与多图层地图渲染。',
      initial: 'M',
      gradient: ['#4EA8FF', '#7C8CF8'],
    },
  ] satisfies TeamMember[],
  note: '全部原始源码带 SPDX 头：SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty',
}

/* ============================================================
   用户评价 —— 场景/角色证言，不用星级
   ============================================================ */

export const testimonialSection = {
  eyebrow: '场景证言',
  title: '按使用场景看，不是按好评数量',
  lead: 'AuroraDrive 尚未广泛发布，以下是典型使用场景的示例证言，不含虚构人名与星级评分。',
  items: [
    {
      persona: '一位做端到端自动驾驶研究的研究者',
      role: '研究场景',
      quote:
        '最有价值的是三档降级的实现细节能直接对照着读：单调降级加上滞回恢复，阈值还能在 UI 上实时调。研究里最怕的是模型一抖动就反复横跳，这里的 recoverHysteresis = 0.15 正是为此设的。',
      fact: '3 档 · degradeHealth 0.65 · recoverHysteresis 0.15',
      initial: 'R',
      gradient: ['#35E0A1', '#4EA8FF'],
    },
    {
      persona: '一位 macOS 视觉工程开发者',
      role: '工程场景',
      quote:
        'CoreML、ScreenCaptureKit、libpcap、CGEvent 怎么拼成一个不打架的实时系统，这个仓库给了完整答案。双进程加共享内存 v3 的设计尤其干净，UI 卡了不影响引擎干活，反过来也一样。',
      fact: '2 进程 · 共享内存 v3 · /aurora_frame_v1',
      initial: 'V',
      gradient: ['#7C8CF8', '#C56CF0'],
    },
    {
      persona: '一位想用 AI 跑日常任务的《异环》玩家',
      role: '使用场景',
      quote:
        '我最大的顾虑是失控。降级状态机给出的答案是模型不靠谱时退到更笨但更稳的规则档，而不是直接乱按。加上 AI 助手有四道护栏、只走 ESC → 截图 → 鼠标点击这一条路，我才敢让它长时间挂着。',
      fact: '3 档降级 · 4 道护栏 · 1 条注入路径',
      initial: 'P',
      gradient: ['#4EA8FF', '#35E0A1'],
    },
    {
      persona: '一位做路线与数据工程的开发者',
      role: '数据场景',
      quote:
        'route_graph.json 是实测数据，不是占位符：664 节点、932 边，加先验之后断头率从 19.3% 降到 5.4%。路线数据能拿出这种前后对比，评审时才有说服力。',
      fact: '664 节点 / 932 边 · 断头率 19.3% → 5.4%',
      initial: 'G',
      gradient: ['#C56CF0', '#35E0A1'],
    },
  ] satisfies Testimonial[],
}

/* ============================================================
   架构页
   ============================================================ */

export type TierKey = 'tier-e2e' | 'tier-yolo' | 'tier-rule'
export type FreshnessKey =
  | 'fresh-live'
  | 'fresh-recent'
  | 'fresh-stale'
  | 'fresh-lost'

export interface ArchitectureContent {
  hero: { eyebrow: string; title: string; lead: string }
  pipeline: {
    eyebrow: string
    title: string
    lead: string
    stages: Array<{
      index: string
      title: string
      source: string
      body: string
      metric: string
    }>
  }
  degrade: {
    eyebrow: string
    title: string
    lead: string
    tiers: Array<{
      tier: TierKey
      name: string
      model: string
      body: string
      level: string
      source: string
    }>
    principles: Array<{ label: string; body: string }>
    caution: string
  }
  flow: {
    eyebrow: string
    title: string
    lead: string
    rows: Array<{
      name: string
      value: string
      unit: string
      verdict: 'adopt' | 'reject'
    }>
    redline: string
  }
  memory: {
    eyebrow: string
    title: string
    lead: string
    facts: Array<{ label: string; value: string; note: string }>
    body: string
  }
  location: {
    eyebrow: string
    title: string
    lead: string
    freshness: Array<{
      key: FreshnessKey
      name: string
      range: string
      body: string
    }>
    graph: Array<{ label: string; before: string; after: string }>
    layers: string[]
    caution: string
  }
  agent: {
    eyebrow: string
    title: string
    lead: string
    breakdown: Array<{ label: string; count: number; note: string }>
    boundaries: Array<{ label: string; body: string }>
    caution: string
  }
  display: {
    eyebrow: string
    title: string
    lead: string
    contrast: Array<{ side: string; tone: 'ok' | 'no'; body: string }>
    reason: string
  }
  stack: {
    eyebrow: string
    title: string
    lead: string
    items: Array<{ group: string; value: string }>
  }
}

export const architectureContent: ArchitectureContent = {
  hero: {
    eyebrow: '架构与实现',
    title: '看得见 → 想得出 → 按得下',
    lead: '三段式闭环：ScreenCaptureKit 抓帧送进 CoreML，推理出转向/油门/刹车，再用 CGEvent 以真实按键事件注入。三段之间有明确的边界与失败处理，每一段的耗时都有实测值。',
  },
  pipeline: {
    eyebrow: '实时管线',
    title: '一段闭环，三段边界',
    lead: '捕获、推理、注入三段各自独立可观测。任意一段失效都不会让其他两段跟着崩 —— 这是双进程 + 共享内存设计要买到的东西。',
    stages: [
      {
        index: '01',
        title: '捕获',
        source: 'ScreenCaptureKit',
        body: 'CVPixelBuffer 流，抓屏帧率 15fps，与推理 tick 同频 15Hz，两档一致。',
        metric: '15fps',
      },
      {
        index: '02',
        title: '推理',
        source: 'CoreML / ANE / Metal',
        body: '端到端 M9 单目模型负责主驾决策；YOLOPX 单模型三头输出 det / da / ll；PP-OCRv6 int8 负责速度识别。',
        metric: '15Hz',
      },
      {
        index: '03',
        title: '注入',
        source: 'CGEvent + AXIsProcessTrusted',
        body: '转向、油门、刹车以真实按键事件注入游戏，辅助功能鉴权通过后才放行；不可见时直接拒绝。',
        metric: '按 tick',
      },
    ],
  },
  degrade: {
    eyebrow: '降级状态机',
    title: '模型不靠谱时，退到更笨但更稳的那一档',
    lead: '这是整个项目最核心的安全设计：能力下降是单调的、有序的，并且带滞回，阈值实时可调。',
    tiers: [
      {
        tier: 'tier-e2e',
        name: '端到端主驾',
        model: 'E2E / M9 单目模型',
        body: '最强能力档。模型直接给出转向、油门与刹车。',
        level: '满格',
        source: 'DegradeStateMachine.swift:5-9',
      },
      {
        tier: 'tier-yolo',
        name: 'YOLO 接管',
        model: 'YOLOPX（一个模型三个头）',
        body: '检测 / 可行驶区 / 车道线三头输出接管决策，能力下降但系统健康。',
        level: '2/3 格',
        source: 'YolopxEngine.swift',
      },
      {
        tier: 'tier-rule',
        name: '纯规则兜底',
        model: '规则策略',
        body: '最保守的一档。不是故障 —— 是系统在工作。',
        level: '1/3 格',
        source: 'DegradeStateMachine.swift:31-38',
      },
    ],
    principles: [
      {
        label: '单调降级',
        body: '只允许向更保守的档位回退，不允许自动升级，避免抖动期反复横跳。',
      },
      {
        label: '滞回恢复',
        body: 'degradeHealth = 0.65、recoverHysteresis = 0.15，跌破才降、回升够才升。',
      },
      {
        label: '阈值实时可调',
        body: '降级阈值在 UI 上可直接调整，不用改代码重编译。',
      },
    ],
    caution:
      '「脱困档」已于 2026-09-30 整体删除。当前只有三档，不存在第四档。',
  },
  flow: {
    eyebrow: '光流实测',
    title: '官方硬件光流反而慢 5 到 14 倍',
    lead: '640×640，ABBA 交错同批实测。这不是堆料，是选型证据 —— 所以项目自己接了 OpenCV 的 C++ 桥。',
    rows: [
      { name: 'OpenCV DISOpticalFlow ULTRAFAST', value: '1.91', unit: 'ms', verdict: 'adopt' },
      { name: '同上，仅单核（极端工况）', value: '3.78', unit: 'ms', verdict: 'adopt' },
      { name: 'Apple VTOpticalFlow（VideoToolbox 硬件）', value: '10.28', unit: 'ms', verdict: 'reject' },
      { name: 'Vision VNGenerateOpticalFlow', value: '27.43', unit: 'ms', verdict: 'reject' },
    ],
    redline: '用户红线是光流 ≤5ms，当前实现 1.91ms，在红线内；单核退化 3.78ms 同样在红线内。',
  },
  memory: {
    eyebrow: '进程与共享内存',
    title: 'UI 卡了不影响引擎干活',
    lead: '两个长驻进程经 /aurora_frame_v1 共享内存传帧与检测数据。协议版本 v3，布局变更会做校验而不是静默错位。',
    facts: [
      { label: '协议版本', value: 'v3', note: 'EngineClient.protocolVersion' },
      { label: '共享内存通道', value: '/aurora_frame_v1', note: '传帧与检测数据' },
      { label: 'pixelsOffset', value: '20480 → 28672', note: '布局变更触发版本校验' },
      { label: '掩码网格', value: '160×160', note: 'bit-pack 传回 UI 叠加' },
    ],
    body: '当布局变更导致偏移量与协议版本不匹配时，引擎明确报错，而不是让 UI 悄悄显示错位的掩码。对一个把画面实时叠加给用户看的工具来说，错的渲染比没有渲染更糟。',
  },
  location: {
    eyebrow: '定位与路网先验',
    title: '网络坐标 + 三级新鲜度 + 664 节点先验',
    lead: 'libpcap 抓 UE5 移动同步包解码世界坐标与朝向，映射到 13056×13056 大地图像素空间。陈旧数据只如实标注，不闪断。',
    freshness: [
      { key: 'fresh-live', name: 'live', range: '≤ 18s', body: '新鲜，坐标参与决策。' },
      { key: 'fresh-recent', name: 'recent', range: '≤ 40s', body: '起不再参与决策，更保守。' },
      { key: 'fresh-stale', name: 'stale', range: '≤ 90s', body: '陈旧，只如实标注，不闪断。' },
      { key: 'fresh-lost', name: 'lost', range: '> 90s', body: '丢失，坐标不可用。' },
    ],
    graph: [
      { label: '路网节点', before: '612', after: '664' },
      { label: '路网边', before: '825', after: '932' },
      { label: '断头率', before: '19.3%', after: '5.4%' },
    ],
    layers: ['传送点', '材料', '宝箱', '谕石'],
    caution:
      '「自愈式定位」与视觉模板匹配定位已于 2026-10-07 整条删除。当前没有视觉定位顶班路径。',
  },
  agent: {
    eyebrow: 'AI 助手',
    title: '30 个工具，15 个技能已实装',
    lead: '真·大模型流式对话，增量按 15Hz 节流。候选链最多尝试 4 个，全链失败才回退本地套话并标注「离线回复」。',
    breakdown: [
      { label: '技能', count: 18, note: '其中 15 个已实装' },
      { label: '键位', count: 4, note: '键盘事件' },
      { label: '文本', count: 1, note: '文本输入' },
      { label: '鼠标', count: 3, note: '移动与点击' },
      { label: '观察', count: 2, note: '截图与状态读取' },
      { label: '搜索', count: 2, note: '知识检索' },
    ],
    boundaries: [
      {
        label: '唯一可靠注入路径',
        body: 'ESC → 截图 → 鼠标点击。这是可靠性设计，不是缺陷。',
      },
      {
        label: '会话滑动窗口',
        body: '上限 200 条，约合 100 轮。',
      },
      {
        label: '四道护栏',
        body: '观测模式拒绝注入 / 游戏不可见拒绝 / 辅助功能未授权拒绝 / dryRun 不注入但返回结构完整结果。全部明确报错，不静默。',
      },
    ],
    caution:
      '30 是挂载数不是可用数。18 个技能中 pinkpaw、rhythm、preset_realtime 三个尚未移植，调用会返回 ok=false。',
  },
  display: {
    eyebrow: '显示增强边界',
    title: '为什么不把 MetalFX 接进决策链路',
    lead: 'MetalGoose 引擎提供 MetalFX 空间超分与时域插帧（GPL-3.0）。它可以让人眼看到的画面更顺滑 —— 但它绝不能进入「捕获 → 推理 → 按键注入」这条链路。',
    contrast: [
      {
        side: '允许',
        tone: 'ok',
        body: '人眼观看的叠加层：空间超分、时域插帧、画面增强。',
      },
      {
        side: '禁止',
        tone: 'no',
        body: '捕获 → 推理 → 按键注入的决策链路。加延迟等于让车反应变慢。',
      },
    ],
    reason:
      '为了画面更顺滑而给决策链路加延迟，等于让车反应变慢 —— 所以我们不这么干。这是可以正面讲的技术价值观。',
  },
  stack: {
    eyebrow: '技术栈',
    title: '真实清单',
    lead: '下面每一项都是仓库里真实使用到的依赖，不含「未来计划」。',
    items: [
      { group: '语言 / 框架', value: 'Swift 6（语言模式 v5）+ SwiftUI · macOS 26+ · Apple Silicon · SPM' },
      { group: '视觉推理', value: 'CoreML（端到端 M9 / YOLOPX 三合一 / PP-OCRv6 int8 / 逐位 CNN）' },
      { group: '采集', value: 'ScreenCaptureKit（CVPixelBuffer 流）' },
      { group: '注入', value: 'CGEvent（键位 / 文本 / 鼠标）· AXIsProcessTrusted' },
      { group: '网络', value: 'libpcap（tcp/30031）· NetworkExtension' },
      { group: '光流', value: 'OpenCV DIS（自建 C++ 桥，Vendor/OpenCVFlow）' },
      { group: '显示增强', value: 'MetalFX（MetalGoose，Metal 管线）' },
      { group: '加速', value: 'ANE / Metal，YOLO 走 GPU 直通' },
      { group: '权限自动化', value: 'BPF + LaunchDaemon' },
      { group: '统计路线图', value: '664 节点 / 932 边有向图 + 大地图像素空间' },
    ],
  },
}

/* ============================================================
   文档页
   ============================================================ */

export const docsContent = {
  hero: {
    eyebrow: '文档与快速开始',
    title: '十分钟跑起来，然后开始读代码',
    lead: '下面是最短路径。跑通之后建议按「架构与实现」页逐层对照源码 —— 每条结论都标了文件与行号。',
  },
  quickStart: {
    eyebrow: '快速开始',
    title: 'Quick Start',
    lead: '以下为仓库 README 中的原始命令与环境要求，逐字照抄。',
  },
  docsIndex: {
    eyebrow: '架构文档库',
    title: '40 篇文档，文件:行号 级引用',
    lead: '文档编号 代码-00 到 代码-39，共 40 篇。每篇都精确到文件与行号，可以直接跳转核对。',
  },
  guides: {
    eyebrow: '上手指南',
    title: '按顺序读，少走弯路',
    lead: '从能跑到看懂，每一步对应仓库里的一处实现。',
    items: [
      {
        index: '01',
        title: '先确认环境',
        body: 'macOS 26+、Apple Silicon、Xcode Command Line Tools。libpcap 系统自带。用 ./run.sh --status 只做环境检查，不启动。',
      },
      {
        index: '02',
        title: '再授权',
        body: '系统设置 → 隐私与安全 → 屏幕录制与辅助功能，两项都要给。首次启动时输入一次管理员密码，自动安装 BPF LaunchDaemon，之后每次开机自动恢复 /dev/bpf* 读写权。',
      },
      {
        index: '03',
        title: '确认降级档位',
        body: '启动后在 UI 里看当前档位。端到端主驾 → YOLO 接管 → 纯规则兜底，三档单调降级，阈值实时可调。',
      },
      {
        index: '04',
        title: '读四份关键源码',
        body: 'DegradeStateMachine.swift 看降级逻辑，YolopxEngine.swift 看三合一模型接入，OpticalFlowBridge.swift 看光流选型数据，ToolRegistry.swift 看 30 个工具的真实边界。',
      },
    ],
  },
  faq: {
    eyebrow: '先看这些',
    title: '上手前最常被问到的几个问题',
    lead: '完整 FAQ 在首页，这里挑出与上手直接相关的几条。',
  },
}

/* ============================================================
   关于页
   ============================================================ */

export const aboutContent = {
  hero: {
    eyebrow: '关于项目',
    title: '一个把「看得见、想得出、按得下」拆开测量的项目',
    lead: 'AuroraDrive 不是通用自动驾驶 SDK，不是网页应用，也不是游戏本体。它是一台跑在 macOS 上的第三方《异环》(NTE) 视角自动驾驶系统 —— 每一个环节的耗时、每个数字的来源，都写进了源码与文档。',
  },
  position: {
    eyebrow: '定位',
    title: '它是什么，它不是什么',
    lead: '边界写清楚，比什么都重要。',
    is: [
      '运行在 macOS 上的第三方《异环》(NTE) 视角自动驾驶系统',
      '把游戏画面实时截屏送给端到端神经网络',
      '推理出转向、油门、刹车，再以真实按键事件注入游戏',
      '附网络抓包定位、速度 OCR 与 MetalFX 显示增强',
      '一个「看得见 → 想得出 → 按得下」的三段式闭环桌面系统',
    ],
    isNot: [
      '一个通用自动驾驶 SDK',
      '一个网页应用',
      '一个游戏本体',
    ],
  },
  audiences: {
    eyebrow: '三类受众',
    title: '你在哪一类，我们各说各的',
    lead: '同一个项目，对不同的人意味着不同的事。',
    items: [
      {
        index: 'A',
        title: '《异环》玩家',
        need: '想让 AI 帮忙跑图、做日常任务，解放双手',
        answer:
          '核心顾虑是「能不能替我开车」和「会不会失控」。三档降级给了第一个问题的答案，滞回恢复与四道护栏给了第二个问题的答案。',
        cta: { label: '看降级状态机', to: '/architecture#degrade' },
      },
      {
        index: 'B',
        title: '端到端自动驾驶研究者',
        need: '想看一套「小模型端到端 + 大模型接管 + 规则兜底」三档梯子的真机实现',
        answer:
          '降级阈值在 UI 上实时可调，滞回参数可读可改。YOLOPX 是一个模型三个头，不是三个模型 —— 说清楚这点很重要。',
        cta: { label: '看架构与实现', to: '/architecture' },
      },
      {
        index: 'C',
        title: 'macOS / 视觉工程开发者',
        need: '想看 CoreML + ScreenCaptureKit + libpcap + MetalFX 如何拼成一个实时系统',
        answer:
          '双进程 + 共享内存 v3 的边界划分、协议版本校验、光流的 ABBA 交错实测选型 —— 每一处都能对照到文件与行号。',
        cta: { label: '看技术栈', to: '/architecture#stack' },
      },
    ],
  },
  scale: {
    eyebrow: '工程规模',
    title: '这些是仓库里的实际体量',
    lead: '不是路线图上的规划值。',
    items: [
      { value: 74, unit: '个', label: 'Swift 文件' },
      { value: 67720, unit: '行', label: '源码' },
      { value: 40, unit: '篇', label: '架构文档（代码-00 ~ 代码-39）' },
      { value: 30, unit: '个', label: 'AI 工具挂载（15 个技能已实装）' },
    ],
  },
  license: {
    eyebrow: '开源与合规',
    title: '许可证写在前面',
    lead: '本项目自身 GPL-3.0-or-later，所有原始源码带 SPDX 头。第三方依赖的许可证同样列出 —— 传染性说明不作辩解，但必须写出来。',
    self: {
      name: 'AuroraDrive',
      license: 'GPL-3.0-or-later',
      usage: '项目本体。全部原始源码带 SPDX 头。',
      note: 'SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty',
    },
    thirdParty: [
      {
        name: 'MaaNTE',
        license: 'AGPL-3.0',
        usage: '网络定位算法蓝本（UE5 移动包位流解析、坐标标定）+ 全收集地图图源。',
        note: 'AGPL-3.0 具有传染性，MaaNTE 源码不随本仓库分发，仅本地参考并在致谢中标注。',
      },
      {
        name: 'MetalGoose',
        license: 'GPL-3.0',
        usage: 'MetalFX 超分 + 插帧引擎（Vendor/MetalGoose）。',
        note: '仅用于显示增强叠加层，不进入决策链路。',
      },
      {
        name: 'nteguide.com',
        license: '经作者许可',
        usage: '全收集地图标记数据。',
        note: '地图数据来源，标记信息经原作者许可使用。',
      },
    ],
  },
}

/* ============================================================
   定价页
   ============================================================ */

export const pricingPageContent = {
  hero: {
    eyebrow: '开源与免费',
    title: '全部免费，没有付费墙',
    lead: '源码、模型、文档、构建脚本全部公开，永久免费使用。源码许可始终是 GPL-3.0-or-later，你随时可以 fork 走人、改名、二次发布甚至闭源商用 —— 只要遵守 GPL 的义务。下面三档都是 ¥0，区别只在于你愿意参与多少社区协作。',
  },
  faq: {
    eyebrow: '关于这三档',
    title: '关于这三档的常见疑问',
    lead: '关于免费这件事，值得先问清楚的几件。',
  },
}

/* ============================================================
   联系页
   ============================================================ */

export const contactContent = {
  hero: {
    eyebrow: '联系',
    title: '有问题、想合作，或者只是想骂两句',
    lead: '我们更希望收到具体的问题 —— 带上 macOS 版本、芯片型号和你遇到的日志片段，比「用不了」三个字有用得多。',
  },
  channels: {
    eyebrow: '其他渠道',
    title: '不一定非得走表单',
    lead: '按你的问题类型选个更快的路。',
    items: [
      {
        index: '01',
        title: '代码问题与 Issue',
        body: '先搜已有 Issue，重复提问会让修复变慢。附上复现步骤与日志片段。',
        action: '打开仓库 Issues',
        href: 'https://github.com/DuoduoChubbyKitty/AuroraDrive/issues',
      },
      {
        index: '02',
        title: '二次开发与对接',
        body: '想替换模型、接入自有工具或对齐协议版本，免费咨询更快。',
        action: '免费咨询',
        href: '/pricing',
      },
      {
        index: '03',
        title: '路线数据与地图',
        body: '全收集地图标记数据来自 nteguide.com，经作者许可使用。',
        action: '查看致谢与许可',
        href: '/about#license',
      },
    ],
  },
  form: {
    title: '发送消息',
    lead: '带 * 为必填。我们通常在几个工作日内回复。',
    topics: [
      { value: 'tech', label: '技术与使用问题' },
      { value: 'feature', label: '功能建议' },
      { value: 'collab', label: '合作与二次开发' },
      { value: 'other', label: '其他' },
    ],
  },
}

/* ============================================================
   页脚
   ============================================================ */

export const footerContent = {
  tagline: 'macOS 上的第三方《异环》(NTE) 视角自动驾驶系统',
  groups: [
    {
      title: '产品',
      links: [
        { label: '架构与实现', to: '/architecture' },
        { label: '文档与快速开始', to: '/docs' },
        { label: '开源与免费', to: '/pricing' },
      ],
    },
    {
      title: '项目',
      links: [
        { label: '关于项目', to: '/about' },
        { label: '开源合规与致谢', to: '/about#license' },
        { label: '联系', to: '/contact' },
      ],
    },
    {
      title: '仓库',
      links: [
        { label: 'GitHub 源码', href: siteMeta.repo, external: true },
        { label: '架构文档（40 篇）', href: siteMeta.repo, external: true },
        { label: '问题反馈', href: `${siteMeta.repo}/issues`, external: true },
      ],
    },
  ],
  /** BRIEF 第六节原文 —— 页脚必须出现 */
  disclaimer:
    '本项目仅供研究与个人学习使用。使用本软件自动控制游戏可能违反游戏服务条款，作者不对封号或其他任何后果负责，请自行评估风险。',
  acknowledgements: [
    {
      name: 'MaaNTE',
      license: 'AGPL-3.0',
      usage: '网络定位算法蓝本 + 全收集地图图源。源码不随本仓库分发。',
    },
    {
      name: 'MetalGoose',
      license: 'GPL-3.0',
      usage: 'MetalFX 超分 + 插帧引擎，仅用于显示层。',
    },
    {
      name: 'nteguide.com',
      license: '经作者许可',
      usage: '全收集地图标记数据。',
    },
  ],
  copyright: 'AuroraDrive · SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty',
}

/* ============================================================
   页面 SEO 元信息
   ============================================================ */

export const pageMeta: Record<string, { title: string; description: string }> = {
  '/': {
    title: 'AuroraDrive · macOS 视角自动驾驶系统',
    description:
      '把《异环》画面实时送进端到端神经网络，推理出转向/油门/刹车并以真实按键事件注入。15Hz 推理、1.91ms 光流、三档降级保底，GPL-3.0 开源。',
  },
  '/architecture': {
    title: '架构与实现 · AuroraDrive',
    description:
      '三档降级状态机、YOLOPX 三合一模型、双进程共享内存 v3、OpenCV DIS 光流实测选型与网络坐标定位的实现细节。',
  },
  '/docs': {
    title: '文档与快速开始 · AuroraDrive',
    description:
      '环境要求、系统权限与 Quick Start 原始命令，以及 40 篇文件:行号 级架构文档的阅读路径。',
  },
  '/pricing': {
    title: '支持与定价 · AuroraDrive',
    description:
      '社区版免费，支持者与企业定制提供响应、环境排查与二次开发对接。源码许可始终为 GPL-3.0-or-later，不售卖软件许可。',
  },
  '/about': {
    title: '关于项目 · AuroraDrive',
    description:
      '项目定位、三类受众、工程规模与开源合规说明 —— 含 MaaNTE 的 AGPL-3.0 传染性说明。',
  },
  '/contact': {
    title: '联系 · AuroraDrive',
    description: '技术问题、功能建议与合作洽谈渠道。',
  },
}
