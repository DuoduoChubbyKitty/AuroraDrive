// aurora_capture.c — 稳定的屏幕抓帧工具 (替代 Python ctypes 调 CoreGraphics, 避免段错误)
// 编译: clang -O2 -o aurora_capture aurora_capture.c \
//        -framework CoreGraphics -framework CoreFoundation -framework ImageIO
//
// 用法:
//   aurora_capture list                      列出在线屏幕: "DISPLAYS N" + 每行 "idx w h isMain isBuiltin"
//   aurora_capture <spec> <w> <h> <out.jpg>  抓指定屏到 JPEG
//     <spec>: 数字索引(0/1) | "builtin"(内建屏) | "main"(菜单栏主屏)

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int resolve_display(const char *spec, CGDirectDisplayID *out) {
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, ids, &count);
    CGDirectDisplayID main = CGMainDisplayID();
    if (spec == NULL || strcmp(spec, "builtin") == 0) {
        for (uint32_t i = 0; i < count; i++) {
            if (CGDisplayIsBuiltin(ids[i])) { *out = ids[i]; return 0; }
        }
        if (spec && strcmp(spec, "builtin") == 0) {
            fprintf(stderr, "warn: no builtin display, fallback to main\n");
        }
        *out = main;
        return 0;
    }
    if (strcmp(spec, "main") == 0) { *out = main; return 0; }
    int idx = atoi(spec);
    if (idx >= 0 && idx < (int)count) { *out = ids[idx]; return 0; }
    fprintf(stderr, "bad display spec: %s\n", spec);
    return -1;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "list") == 0) {
        CGDirectDisplayID ids[16];
        uint32_t count = 0;
        CGGetOnlineDisplayList(16, ids, &count);
        CGDirectDisplayID main = CGMainDisplayID();
        printf("DISPLAYS %u\n", count);
        for (uint32_t i = 0; i < count; i++) {
            CGRect b = CGDisplayBounds(ids[i]);
            int isbuiltin = CGDisplayIsBuiltin(ids[i]);
            int ismain = (ids[i] == main) ? 1 : 0;
            printf("%u %d %d %d %d\n",
                   i, (int)b.size.width, (int)b.size.height, ismain, isbuiltin);
        }
        return 0;
    }

    if (argc < 5) {
        fprintf(stderr, "usage: %s <spec|list> [w h out.jpg]\n", argv[0]);
        return 2;
    }
    const char *spec = argv[1];
    int w = atoi(argv[2]);
    int h = atoi(argv[3]);
    const char *outpath = argv[4];
    if (w <= 0 || h <= 0) { fprintf(stderr, "bad dimensions\n"); return 2; }

    CGDirectDisplayID did;
    if (resolve_display(spec, &did) != 0) return 3;

    CGImageRef img = CGDisplayCreateImage(did);
    if (!img) {
        fprintf(stderr, "capture failed: no permission or display unavailable\n");
        return 1;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        NULL, w, h, 8, w * 4, cs,
        kCGImageByteOrder32Big | kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CGImageRelease(img);
        fprintf(stderr, "bitmap context failed\n");
        return 1;
    }

    CGRect rect = CGRectMake(0, 0, w, h);
    CGContextDrawImage(ctx, rect, img);
    CGImageRelease(img);

    CGImageRef resized = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!resized) {
        fprintf(stderr, "resize failed\n");
        return 1;
    }

    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    CFStringRef uti = CFSTR("public.jpeg");
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, uti, 1, NULL);
    CGImageDestinationAddImage(dest, resized, NULL);
    bool ok = CGImageDestinationFinalize(dest);
    CGImageRelease(resized);
    if (!ok) {
        fprintf(stderr, "jpeg finalize failed\n");
        CFRelease(dest);
        CFRelease(data);
        return 1;
    }

    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    FILE *f = fopen(outpath, "wb");
    if (!f) {
        fprintf(stderr, "cannot open output: %s\n", outpath);
        CFRelease(dest);
        CFRelease(data);
        return 1;
    }
    fwrite(bytes, 1, len, f);
    fclose(f);

    CFRelease(dest);
    CFRelease(data);
    return 0;
}
