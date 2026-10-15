# -*- coding: utf-8 -*-
import os
import AppKit, Quartz
from Foundation import NSURL, NSMakeRect, NSMakeSize

# 测试：位图 CGContext + NSGraphicsContext 画中文
DPI = 150.0
PW, PH = 595.28, 841.89
W, H = int(PW*DPI/72), int(PH*DPI/72)
print('位图', W, 'x', H)

ctx = Quartz.CGBitmapContextCreate(None, W, H, 8, 0,
        Quartz.CGColorSpaceCreateDeviceRGB(), Quartz.kCGImageAlphaNoneSkipLast)
Quartz.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1)
Quartz.CGContextFillRect(ctx, Quartz.CGRectMake(0, 0, W, H))
s = DPI/72.0
Quartz.CGContextScaleCTM(ctx, s, s)

ns = AppKit.NSGraphicsContext.graphicsContextWithCGContext_flipped_(ctx, False)
AppKit.NSGraphicsContext.saveGraphicsState()
AppKit.NSGraphicsContext.setCurrentContext_(ns)

f = AppKit.NSFont.fontWithName_size_('Songti SC', 20)
if f is None:
    f = AppKit.NSFont.systemFontOfSize_(20)
print('字体:', f.fontName())

a = {
  AppKit.NSFontAttributeName: f,
  AppKit.NSForegroundColorAttributeName: AppKit.NSColor.blackColor(),
}
txt = '测试中文绘制：AI 科技新闻报 2026'
at = AppKit.NSAttributedString.alloc().initWithString_attributes_(txt, a)
at.drawWithRect_options_(NSMakeRect(40, 700, 500, 100),
    AppKit.NSStringDrawingUsesLineFragmentOrigin | AppKit.NSStringDrawingUsesFontLeading)

AppKit.NSGraphicsContext.restoreGraphicsState()

# 检查有没有画上（统计暗像素）
data = Quartz.CGBitmapContextGetData(ctx)
buf = data.as_buffer(W*H*4)
dark = sum(1 for k in range(0, W*H*4, 4*7) if buf[k] < 128)
print('暗像素采样:', dark, '->', '有文字!' if dark > 50 else '空白!')

img = Quartz.CGBitmapContextCreateImage(ctx)
d = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(os.path.abspath('desktop-out/_test_text.png')), 'public.png', 1, None)
Quartz.CGImageDestinationAddImage(d, img, None)
Quartz.CGImageDestinationFinalize(d)
print('测试图已存')
