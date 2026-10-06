# -*- coding: utf-8 -*-
import os, sys
import AppKit, Quartz
from Foundation import NSURL, NSMakeRect, NSMakeSize

DPI = 200.0
PW, PH = 595.28, 841.89
SC = DPI / 72.0
W, H = int(PW*SC), int(PH*SC)

SONG='Songti SC'; HEI='Heiti SC'; LAT='Helvetica'

def F(name, size, bold=False):
    f = AppKit.NSFont.fontWithName_size_(name, size)
    if f is None: f = AppKit.NSFont.systemFontOfSize_(size)
    if bold:
        f2 = AppKit.NSFontManager.sharedFontManager().convertFont_toHaveTrait_(f, AppKit.NSBoldFontMask)
        if f2: f = f2
    return f

def A(size, name=SONG, bold=False, color=None, align=0, ls=None):
    p = AppKit.NSMutableParagraphStyle.alloc().init()
    p.setLineSpacing_(ls if ls is not None else size*0.42)
    p.setAlignment_(align)
    return {AppKit.NSFontAttributeName: F(name, size, bold),
            AppKit.NSForegroundColorAttributeName: color or AppKit.NSColor.blackColor(),
            AppKit.NSParagraphStyleAttributeName: p}

def h_of(t, a, w):
    s = AppKit.NSAttributedString.alloc().initWithString_attributes_(t, a)
    r = s.boundingRectWithSize_options_(NSMakeSize(w, 1e7),
        AppKit.NSStringDrawingUsesLineFragmentOrigin | AppKit.NSStringDrawingUsesFontLeading)
    return r.size.height + 1.2

ctx = Quartz.CGBitmapContextCreate(None, W, H, 8, 0,
        Quartz.CGColorSpaceCreateDeviceRGB(), Quartz.kCGImageAlphaNoneSkipLast)
Quartz.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1)
Quartz.CGContextFillRect(ctx, Quartz.CGRectMake(0, 0, W, H))
Quartz.CGContextScaleCTM(ctx, SC, SC)
ns = AppKit.NSGraphicsContext.graphicsContextWithCGContext_flipped_(ctx, False)
AppKit.NSGraphicsContext.saveGraphicsState()
AppKit.NSGraphicsContext.setCurrentContext_(ns)

MG = 32.0
CW = PW - 2*MG
GUT = 13.0
COLW = (CW - GUT)/2
COLX = [MG, MG + COLW + GUT]

def put(t, a, x, yTop, w):
    h = h_of(t, a, w)
    s = AppKit.NSAttributedString.alloc().initWithString_attributes_(t, a)
    s.drawWithRect_options_(NSMakeRect(x, PH - yTop - h, w, h + 4),
        AppKit.NSStringDrawingUsesLineFragmentOrigin | AppKit.NSStringDrawingUsesFontLeading)
    return h

def hline(x, y, w, lw=1.0, gray=0.0):
    yy = PH - y
    Quartz.CGContextSetLineWidth(ctx, lw)
    Quartz.CGContextSetRGBStrokeColor(ctx, gray, gray, gray, 1)
    Quartz.CGContextMoveToPoint(ctx, x, yy); Quartz.CGContextAddLineToPoint(ctx, x+w, yy)
    Quartz.CGContextStrokePath(ctx)

y = MG
put('AI 科 技 新 闻 报', A(26, SONG, True, align=AppKit.NSTextAlignmentCenter, ls=0), MG, y, CW)
y += 33
hline(MG, y, CW, 1.0); y += 2.5
hline(MG, y, CW, 2.2); y += 5
put('第 01 期      2026 年 10 月 1 日      整理给妈妈看',
    A(8, HEI, align=AppKit.NSTextAlignmentCenter, ls=0), MG, y, CW)
y += 13
hline(MG, y, CW, 2.2); y += 2.5
hline(MG, y, CW, 0.6); y += 10

put('亲爱的妈妈，最近 AI 科技圈多了好多新闻，我特地整理一下给你看。以下新闻：',
    A(10, SONG, True, ls=2.6), MG, y, CW)
y += 17
hline(MG, y, CW, 0.6); y += 9

TOP = y
FS = 8.0     # 正文字号（内容翻倍后调小一档）
col, cy = 0, TOP

def place(kind, text):
    global col, cy
    if kind == 'head':   a = A(11.5, HEI, True, ls=2.0)
    elif kind == 'sub':  a = A(9.0, HEI, True, ls=1.6)
    elif kind == 'meta': a = A(6.5, LAT, color=AppKit.NSColor.grayColor(), ls=0.8)
    else:                a = A(FS, SONG, ls=2.2)
    w = COLW
    hh = h_of(text, a, w)
    if cy + hh > PH - MG - 30:
        if col == 0:
            col, cy = 1, TOP
        else:
            print('  [溢出]', text[:18]); return
    put(text, a, COLX[col], cy, w)
    cy += hh + (6.0 if kind in ('head','sub') else 3.4)

# ============ 左栏 ============
place('head', '英伟达 129.3 亿美元收购 Hugging Face，承诺保持开放')
place('meta', '2026-09-03 · 英伟达官方博客（黄仁勋署名）')
place('body', '英伟达创始人黄仁勋在官方博客亲笔宣布：将以 12,930,300,000 美元收购 Hugging Face。这个数字精确到个位，是他自己写出来的。')
place('body', 'Hugging Face 是全世界开源 AI 模型的集散地。十年间，Clem、Julien、Thomas 和他们的团队把它建成了一座开放模型开发者的家园：超过 1800 万开发者、300 万个模型、50 万个数据集、100 万个应用，20 万家企业用它来发现、评估、定制和部署 AI。')
place('body', '黄仁勋在公告里做了几项明确承诺：Hugging Face 将继续作为面向整个 AI 生态的开放平台；开发者可以自由选择模型、框架、云服务和推理服务商；在 Hugging Face 上构建和部署，不要求使用英伟达的算力；将继续支持来自所有模型厂商的开源与开放权重模型，并继续支持多云、多加速器。')
place('body', '他还提到，不久前自己刚联合业界写了一封公开信，讲开放权重对 AI 经济的重要性。这笔收购被外界解读为：英伟达在给自己最核心的硬件生意，买一条通往开源社区的通道。')

place('head', '谷歌开源完整果蝇大脑：16.6 万个神经元')
place('meta', '2026-09 · Google Research 官方博客 / HHMI Janelia')
place('body', 'Google Research 与 HHMI Janelia 研究园合作，发布了完整的雄性果蝇大脑连接组——16.6 万个神经元，全部接线图。')
place('body', '这是神经科学的一个里程碑。此前人类只完整测绘过线虫（302 个神经元），而果蝇有十几万个，能飞、能导航、能求偶、能学习。要把它一个突触一个突触地重建出来，靠人工几乎不可能，是 AI 图像分割技术把这块硬骨头啃下来的。')
place('body', '更有意思的是开源之后的连锁反应：没几天，网友已经拿它去打《毁灭战士》(Doom) 了——他们把这套连接组接进模拟环境，让"果蝇"真的开起了游戏里的枪。')
place('body', '我最近在做自动驾驶，看到这条新闻第一反应是：能不能把它拿来做兜底？毕竟它只有 16 万个神经元，却能做到实时感知与决策。不过这事我还在琢磨，等想明白了再跟你说。')

# ============ 右栏 ============
col = 1; cy = TOP

place('head', 'OpenAI DevDay：一口气发布 20 多项')
place('meta', '2026-09-29 · 旧金山')
place('body', '这场发布会信息量很大，我挑最重要的几件讲。')

place('sub', '一、dots：常驻智能体，每个配一台云电脑')
place('body', 'dots 由 GPT-6 Astra 驱动，是持久化的智能体。每一个 dot 都分到一台云电脑，可以跨多个应用持续工作、在对话之间保留上下文、同时推进好几个项目。')
place('body', '你可以在 ChatGPT、Slack、微软 Teams 里找到它，甚至能语音通话（短信方式稍后上线）。经你授权，它还能连上你的笔记本。现场演示了它代理处理 Slack 请求、排查 bug、准备代码合并请求。它的"主动研究"用的是只读工具；所有动作都要走权限和审批规则。')
place('body', '首批面向 Pro 和 Business Premium 用户开放，企业和教育版可由管理员开启测试。第一个 dot 不收额外订阅费。同时预览了"专家型 dot"——它们有自己的身份、凭据和系统访问权，正与微软合作接入 Agent 365 的治理与安全控制。')

place('sub', '二、GPT-6.1 Sol：价格只有 Astra 的五分之一')
place('body', '它在编程、电脑操作和专业任务上接近 Astra 的水平，但输入输出 token 价格只有 Astra 的五分之一。官方 API 定价为：输入每百万 token 2 美元，缓存输入 0.10 美元，输出 10 美元。舞台上说的"95% 折扣"指的是缓存输入相对标准输入。也就是说，重复使用同一段上下文，比每次重新发送便宜得多。')
place('body', '模型可通过 API 以 gpt-6.1-sol 调用，也进入 ChatGPT Work 和 Codex，面向 Plus、Pro、Business、Enterprise、Edu 用户。但它还没进普通版 ChatGPT 聊天。')

place('sub', '三、Astra Ultrafast：用钱换速度')
place('body', '这是 GPT-6 Astra 的高速推理档。现场说的是每秒 300 token、价格为标准价的六倍；官方复盘写的是 Codex 里最多快八倍、API 里最多快六倍。注意这些数字说的是"生成速度"，一个任务的总耗时还要看工具调用等其他环节。该档已在 API、ChatGPT Work 和 Codex 的 Pro 500 与 Enterprise 计划上线。')

place('sub', '四、Pro 500 上线，Pro 200 重新开放')
place('body', '新的 Pro 500 订阅每月 500 美元，包含 Astra Ultrafast，额度约为 Plus 的 25 倍，符合条件的用量还能花在合作方的应用里。同时重新向新用户开放每月 200 美元的 Pro 档——但条款变了：新订阅没有"祖父条款"保护，额度比以前低；符合条件的老用户在 2026 年 10 月 29 日之前保留原有额度，之后在同样月费下切换到减少后的额度。')

place('sub', '五、两个新 API')
place('body', 'Decisions API 把 Luna 聚焦在"答案已经限定好"的问题上：开发者提交文字或图片，拿回一个可直接用于分类、请求路由或决定智能体下一步动作的决策。现场描述响应时间在零点几秒，还提到用视觉输入帮硬件快速反应。目前已进入小范围预览。')
place('body', 'Agents API 则把 Codex 的执行框架做成托管服务：会话、编排、上下文压缩、故障恢复都由 OpenAI 负责，开发者提供工具并选择执行环境。智能体能执行代码、编辑文件、连接 MCP 服务器，还能把工作转给其他智能体。已进入公开测试。')

place('sub', '六、Sign in with ChatGPT')
place('body', '这一项比较低调，但可能影响最广——它悄悄改变了"谁来为你的用户付 token 钱"这件事。')

place('head', 'JEV：一个不会写字的 AI')
place('meta', '2026-09 · TypeSafe AI')
place('body', 'TypeSafe AI 发布了 JEV，定位是全球首个非生成式商用 AI 模型。它的特别之处在于：不生成自然语言，只返回类型化数值、概率分布与置信度，直接给程序消费。')
place('body', '它提供三种原语：Choice（从选项里挑一个）、Score（按标尺打分）、Noul（判断某事是否成立）。三者可以在一次请求里混用，每个问题并行且独立地评估，因此增加问题几乎不增加响应时间，也不会互相干扰。')
place('body', '定价方面：每十亿输入 token 42 美元，即每百万 token 0.042 美元；输出 token 免费——因为它根本不输出文本。上下文 64k token，速率 100K token/秒、40 请求/秒。创始人 Diogo Almeida 在 OpenAI 待过约四年，参与过 RLHF、InstructGPT、ChatGPT 和 GPT-4，2026 年 9 月发布，已获 DCVC 领投的 4000 万美元种子轮。')

place('head', '一个月 66 个发布，价格直接腰斩')
place('meta', '2026 年 9 月 · 月度汇总')
place('body', '9 月 AI 圈一共发生 66 次发布。最戏剧性的一幕是：Anthropic 和 OpenAI 相隔 101 分钟先后发布更便宜的模型。')
place('body', 'Claude Opus 5.5 能做到 Fable 级别的活，价格比 Opus 5 便宜 40%，为每百万 token 4 / 20 美元；GPT-6 Sol 为 2 / 10 美元；Luna 更是低到 0.10 / 0.50 美元。')
place('body', '而 9 月 3 日发布的 GPT-6 Astra，OpenAI 称其为最智能、最对齐的模型：ARC-AGI-3 拿到 99.9，FrontierMath Tier 4 拿到 97.6%。同月还发布了 Gemini 3.8 Flash、Meta Muse、DeepSeek V4.1 Flash、GLM-5.3 全部权重、小米 MiMo V2.6 Pro、Grok 4.7、Gemini 3.8 Flash TTS（30 秒音频就能克隆声音）等等。')
place('body', '这个月的开局也很有意思：几家实验室的负责人公开表态说要"给前沿模型降速"，然后谁也没降。')

place('head', '写在最后')
place('body', '这些新闻离你那边可能有点远，但我想让你知道我每天在忙什么。等下次写信，我再说说我自己那个项目做到哪一步了。')
place('body', '你在那边照顾好自己，别熬夜。家里都好，放心。')

# 栏线
Quartz.CGContextSetLineWidth(ctx, 0.4)
Quartz.CGContextSetRGBStrokeColor(ctx, 0.75, 0.75, 0.75, 1)
mx = MG + COLW + GUT/2
Quartz.CGContextMoveToPoint(ctx, mx, PH - TOP)
Quartz.CGContextAddLineToPoint(ctx, mx, MG + 26)
Quartz.CGContextStrokePath(ctx)

hline(MG, PH - MG - 22, CW, 0.6)
put('资料来源：NVIDIA 官方博客（黄仁勋署名）· Google Research 官方博客 · RuntimeWire 与 dev.to 对 OpenAI DevDay 2026 的逐项报道 · TypeSafe AI 官方文档 · ThursdAI 月度发布汇总',
    A(6.2, SONG, color=AppKit.NSColor.grayColor(), ls=0.8), MG, PH - MG - 18, CW)

AppKit.NSGraphicsContext.restoreGraphicsState()
img = Quartz.CGBitmapContextCreateImage(ctx)
out = 'desktop-out/AI科技新闻报-第01期-加厚版.png'
d = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(os.path.abspath(out)), 'public.png', 1, None)
Quartz.CGImageDestinationAddImage(d, img, None); Quartz.CGImageDestinationFinalize(d)
print('生成:', out, W, 'x', H, os.path.getsize(out), 'bytes')
