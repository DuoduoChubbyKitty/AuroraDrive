// hid_look.c — HID 层相对转视角（与 MouseController 同层）
// 编译: clang -O2 -o tools/hid_look tools/hid_look.c -framework CoreGraphics
// 用法: hid_look <dx> [dy] [steps]
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: hid_look <dx> [dy=0] [steps=20]\n"); return 1; }
    double dx = atof(argv[1]);
    double dy = (argc >= 3) ? atof(argv[2]) : 0;
    int steps = (argc >= 4) ? atoi(argv[3]) : 20;
    if (steps < 1) steps = 1;

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!src) { fprintf(stderr, "source 失败\n"); return 1; }

    CGEventRef loc = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(loc);
    CFRelease(loc);

    /* 异环视角：按住右键拖动（与物理鼠标同层） */
    CGEventRef down = CGEventCreateMouseEvent(src, kCGEventRightMouseDown, p, kCGMouseButtonRight);
    if (down) { CGEventPost(kCGHIDEventTap, down); CFRelease(down); }
    usleep(30000);

    for (int i = 1; i <= steps; i++) {
        CGPoint q = CGPointMake(p.x + dx * i / steps, p.y + dy * i / steps);
        CGEventRef e = CGEventCreateMouseEvent(src, kCGEventRightMouseDragged, q, kCGMouseButtonRight);
        if (!e) continue;
        CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)(dx / steps));
        CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)(dy / steps));
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
        usleep(8000);
    }
    CGPoint end = CGPointMake(p.x + dx, p.y + dy);
    CGEventRef up = CGEventCreateMouseEvent(src, kCGEventRightMouseUp, end, kCGMouseButtonRight);
    if (up) { CGEventPost(kCGHIDEventTap, up); CFRelease(up); }
    printf("look dx=%.0f dy=%.0f steps=%d from (%.0f,%.0f)\n", dx, dy, steps, p.x, p.y);
    CFRelease(src);
    return 0;
}
