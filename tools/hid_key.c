// hid_key.c — 与 ControlEngine 同一套注入：HID 系统状态层 + cghidEventTap + 30Hz 新按下
// 编译:
//   clang -O2 -o tools/hid_key tools/hid_key.c -framework CoreGraphics -framework ApplicationServices
// 用法:
//   hid_key hold w 2.0     按住 W 2 秒（30Hz 重发）
//   hid_key tap  t         短按 T
//   hid_key tap  esc
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static CGKeyCode code_of(const char *n) {
    if (!strcasecmp(n, "w")) return 13;
    if (!strcasecmp(n, "a")) return 0;
    if (!strcasecmp(n, "s")) return 1;
    if (!strcasecmp(n, "d")) return 2;
    if (!strcasecmp(n, "f")) return 3;
    if (!strcasecmp(n, "e")) return 14;
    if (!strcasecmp(n, "q")) return 12;
    if (!strcasecmp(n, "r")) return 15;
    if (!strcasecmp(n, "t")) return 17;
    if (!strcasecmp(n, "v")) return 9;
    if (!strcasecmp(n, "m")) return 46;
    if (!strcasecmp(n, "z")) return 6;
    if (!strcasecmp(n, "space")) return 49;
    if (!strcasecmp(n, "esc") || !strcasecmp(n, "escape")) return 53;
    if (!strcasecmp(n, "tab")) return 48;
    if (!strcasecmp(n, "shift")) return 56;
    if (!strcasecmp(n, "f1")) return 122;
    if (!strcasecmp(n, "f3")) return 99;
    if (!strcasecmp(n, "f4")) return 118;
    if (!strcasecmp(n, "f5")) return 96;
    fprintf(stderr, "未知键: %s\n", n);
    exit(2);
}

static CGEventSourceRef src;

static void post_key(CGKeyCode kc, int down) {
    CGEventRef e = CGEventCreateKeyboardEvent(src, kc, down ? true : false);
    if (!e) { fprintf(stderr, "CGEventCreateKeyboardEvent 失败\n"); return; }
    CGEventSetIntegerValueField(e, kCGKeyboardEventAutorepeat, 0);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "用法: hid_key hold <键> <秒>\n       hid_key tap  <键> [秒=0.05]\n");
        return 1;
    }
    src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!src) { fprintf(stderr, "CGEventSourceCreate 失败\n"); return 1; }

    const char *cmd = argv[1];
    CGKeyCode kc = code_of(argv[2]);

    if (!strcmp(cmd, "tap")) {
        double dur = (argc >= 4) ? atof(argv[3]) : 0.05;
        post_key(kc, 1);
        usleep((useconds_t)(dur * 1e6));
        post_key(kc, 0);
        printf("tap %s %.3fs\n", argv[2], dur);
    } else if (!strcmp(cmd, "hold")) {
        double dur = (argc >= 4) ? atof(argv[3]) : 1.0;
        int n = (int)(dur * 30.0 + 0.5);
        if (n < 1) n = 1;
        for (int i = 0; i < n; i++) {
            post_key(kc, 1);               // 新按下，游戏才认
            usleep(33333);                 // ~30Hz
        }
        post_key(kc, 0);
        printf("hold %s %.2fs  (%d ticks)\n", argv[2], dur, n);
    } else {
        fprintf(stderr, "未知命令: %s\n", cmd);
        return 2;
    }
    CFRelease(src);
    return 0;
}
