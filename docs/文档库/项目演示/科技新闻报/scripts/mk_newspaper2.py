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
    p.setLineSpacing_(ls if ls is not None else size*0.45)
    p.setAlignment_(align)
    return {AppKit.NSFontAttributeName: F(name, size, bold),
            AppKit.NSForegroundColorAttributeName: color or AppKit.NSColor.blackColor(),
            AppKit.NSParagraphStyleAttributeName: p}

def h_of(t, a, w):
    s = AppKit.NSAttributedString.alloc().initWithString_attributes_(t, a)
    r = s.boundingRectWithSize_options_(NSMakeSize(w, 1e7),
        AppKit.NSStringDrawingUsesLineFragmentOrigin | AppKit.NSStringDrawingUsesFontLeading)
    return r.size.height + 1.5

def put(t, a, x, yTop, w):
    # yTop 为顶部，转成 AppKit 底部基线坐标
    h = h_of(t, a, w)
    s = AppKit.NSAttributedString.alloc().initWithString_attributes_(t, a)
    s.drawWithRect_options_(NSMakeRect(x, H/SC - yTop - h, w, h + 4),
        AppKit.NSStringDrawingUsesLineFragmentOrigin | AppKit.NSStringDrawingUsesFontLeading)
    return h

ctx = Quartz.CGBitmapContextCreate(None, W, H, 8, 0,
        Quartz.CGColorSpaceCreateDeviceRGB(), Quartz.kCGImageAlphaNoneSkipLast)
Quartz.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1)
Quartz.CGContextFillRect(ctx, Quartz.CGRectMake(0, 0, W, H))
Quartz.CGContextScaleCTM(ctx, SC, SC)
ns = AppKit.NSGraphicsContext.graphicsContextWithCGContext_flipped_(ctx, False)
AppKit.NSGraphicsContext.saveGraphicsState()
AppKit.NSGraphicsContext.setCurrentContext_(ns)

MG = 36.0
CW = PW - 2*MG
GUT = 15.0
COLW = (CW - GUT)/2
COLX = [MG, MG + COLW + GUT]

def hline(x, y, w, lw=1.0, gray=0.0):
    # y 为从页顶算的坐标
    yy = PH - y
    Quartz.CGContextSetLineWidth(ctx, lw)
    Quartz.CGContextSetRGBStrokeColor(ctx, gray, gray, gray, 1)
    Quartz.CGContextMoveToPoint(ctx, x, yy); Quartz.CGContextAddLineToPoint(ctx, x+w, yy)
    Quartz.CGContextStrokePath(ctx)

y = MG
# 报头
h = put('AI 科 技 新 闻 报', A(28, SONG, True, align=AppKit.NSTextAlignmentCenter, ls=0), MG, y, CW)
y += h + 3
hline(MG, y, CW, 1.0); y += 2.5
hline(MG, y, CW, 2.0); y += 5
h = put('第 01 期      2026 年 10 月 1 日      整理给妈妈看',
        A(8.5, HEI, align=AppKit.NSTextAlignmentCenter, ls=0), MG, y, CW)
y += h + 4
hline(MG, y, CW, 2.0); y += 2.5
hline(MG, y, CW, 0.6); y += 12

# 开场白
h = put('亲爱的妈妈，最近 AI 科技圈多了好多新闻，我特地整理一下给你看。以下新闻：',
        A(10.5, SONG, True, ls=3.0), MG, y, CW)
y += h + 7
hline(MG, y, CW, 0.6); y += 12

TOP = y
col, cy = 0, TOP

def place(kind, text):
    global col, cy
    if kind == 'head':   a = A(12.5, HEI, True, ls=2.4)
    elif kind == 'meta': a = A(7.0, LAT, color=AppKit.NSColor.grayColor(), ls=1.0)
    else:                a = A(8.8, SONG, ls=2.5)
    w = COLW
    hh = h_of(text, a, w)
    if cy + hh > PH - MG - 34:
        if col == 0:
            col, cy = 1, TOP
        else:
            print('  溢出，未放置:', text[:20]); return
    put(text, a, COLX[col], cy, w)
    cy += hh + (6.5 if kind else 4.0)

place('head', '英伟达 129.3 亿美元收购 Hugging Face')
place('meta', '2026-09-03 · 黄仁勋官方博客')
place('body', '英伟达创始人黄仁勋在官方博客亲笔宣布：将以 129.3 亿美元收购 Hugging Face。')
place('body', 'Hugging Face 是全世界开源 AI 模型的集散地——超过 1800 万开发者、300 万个模型、50 万个数据集、100 万个应用，20 万家企业用它来发现、评估、定制和部署 AI。')
place('body', '黄仁勋承诺：它将继续作为面向整个 AI 生态的开放平台。开发者可自由选择模型、框架、云服务和推理服务商；在 Hugging Face 上构建和部署，不要求使用英伟达的算力。')

place('head', '谷歌开源完整果蝇大脑')
place('meta', '2026-09 · Google Research 官方博客')
place('body', 'Google Research 与 HHMI Janelia 合作，发布了完整的雄性果蝇大脑连接组——16.6 万个神经元。')
place('body', '这是神经科学的一个里程碑：人类第一次完整测绘出一只成体动物的大脑接线图。有意思的是，开源没几天，网友已经拿它去打《毁灭战士》了。')
place('body', '我最近在做自动驾驶，正想着能不能把它拿来做兜底——不过这事我还在琢磨。')

place('head', 'OpenAI DevDay 发布 20 多项')
place('meta', '2026-09-29 · 旧金山')
place('body', 'dots 常驻智能体：由 GPT-6 Astra 驱动，每个 dot 配一台云电脑，能跨应用持续工作、在对话间保留上下文。可通过 ChatGPT、Slack、微软 Teams 找到它，甚至语音通话；经授权还能连上你的笔记本。')
place('body', '同时发布 GPT-6.1 Sol（面向编程与办公的低成本模型）、500 美元的 Pro 订阅，以及 Sign in with ChatGPT。')

# 强制换到第二栏，平衡版面
col = 1; cy = TOP
place('head', 'JEV：一个不会写字的 AI')
place('meta', '2026-09 · TypeSafe AI')
place('body', 'TypeSafe AI 发布了 JEV，全球首个非生成式商用 AI 模型。它不会写字，只做判断：你给它状态和结构化问题，它直接返回类型化数值、概率分布和置信度，供程序调用。三种原语：Choice 选择、Score 打分、Noul 是否判断。')
place('body', '定价每百万 token 仅 0.042 美元，输出免费——因为它根本不输出文本。创始人 Diogo Almeida 是 ChatGPT 的核心成员，已获 DCVC 领投的 4000 万美元种子轮。')

place('head', '一个月 66 个发布，价格腰斩')
place('meta', '2026 年 9 月 · 月度汇总')
place('body', '9 月 AI 圈发生 66 次发布。最戏剧性的一幕：Anthropic 和 OpenAI 相隔 101 分钟先后发布更便宜的模型。')
place('body', 'Claude Opus 5.5 为每百万 token 4 / 20 美元（比 Opus 5 便宜 40%）；GPT-6 Sol 为 2 / 10 美元；Luna 为 0.10 / 0.50 美元。')
place('body', '而 9 月 3 日发布的 GPT-6 Astra，OpenAI 称其为最智能、最对齐的模型，ARC-AGI-3 拿到 99.9，FrontierMath Tier 4 拿到 97.6%。')
place('body', '同月还有 Gemini 3.8 Flash、Meta Muse、DeepSeek V4.1 Flash、GLM-5.3、小米 MiMo V2.6 Pro、Grok 4.7……最强的模型没活过五天就被新的比下去，一个月大爆炸一次。')


# 收尾
cy += 8
place('head', '写在最后')
place('body', '这些新闻离你那边可能有点远，但我想让你知道我每天在忙什么。等下次写信，我再说说我自己那个项目做到哪一步了。')
place('body', '你在那边照顾好自己，别熬夜。家里都好，放心。')

# 栏线
Quartz.CGContextSetLineWidth(ctx, 0.4)
Quartz.CGContextSetRGBStrokeColor(ctx, 0.75, 0.75, 0.75, 1)
mx = MG + COLW + GUT/2
Quartz.CGContextMoveToPoint(ctx, mx, PH - TOP)
Quartz.CGContextAddLineToPoint(ctx, mx, MG + 30)
Quartz.CGContextStrokePath(ctx)

# 页脚
hline(MG, PH - MG - 26, CW, 0.6)
put('资料来源：NVIDIA 官方博客（黄仁勋署名）· Google Research 官方博客 · OpenAI DevDay 2026 报道 · TypeSafe AI 官方文档 · ThursdAI 月度汇总',
    A(6.8, SONG, color=AppKit.NSColor.grayColor(), ls=1.0), MG, PH - MG - 22, CW)

AppKit.NSGraphicsContext.restoreGraphicsState()

img = Quartz.CGBitmapContextCreateImage(ctx)
d = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(os.path.abspath('desktop-out/AI科技新闻报-第01期.png')), 'public.png', 1, None)
Quartz.CGImageDestinationAddImage(d, img, None); Quartz.CGImageDestinationFinalize(d)
print('生成 PNG:', W, 'x', H, os.path.getsize('desktop-out/AI科技新闻报-第01期.png'), 'bytes')
