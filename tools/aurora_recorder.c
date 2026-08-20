// aurora_recorder.c — 屏幕画面 + 键盘动作 同时录制的 C 录制器
// 编译:
//   clang -O2 -mmacosx-version-min=13.0 -o aurora_recorder aurora_recorder.c \
//        -framework CoreGraphics -framework CoreFoundation -framework ImageIO
//
// 用法:
//   aurora_recorder list                       列出在线屏幕 (DISPLAYS N + 每行 idx w h isMain isBuiltin)
//   aurora_recorder --now                      3秒倒计时后录内建屏(默认), 靠 /tmp/aurora_video_stop 停止
//   aurora_recorder --display 1 --now          录第 1 号屏
//   aurora_recorder --view TPV --now            录第三视角 (默认 FPV, 写入 view.txt)
//   aurora_recorder --display builtin --source mixed --now
//   aurora_recorder --now --max-frames 300     只录 300 帧自动停(也用于测试)
//
// 输出: <项目>/data/raw_clips/clip_<ts>/
//   frames/000000.jpg ...   画面帧 (0 基, 与 controls.csv 行号对齐, 喂 MonoClipsDataset)
//   controls.csv            t_sec,frame,steer,throttle,brake,handbrake,strong_brake   (每帧一行, 直接喂训练)
//   keylog.csv              t_sec,keycode,event(down/up)       (原始按键边沿, 备用)
//   clip.json               元数据
//
// 权限: 系统设置→隐私→屏幕录制 (给终端) + 系统设置→隐私→输入监控 (给终端, 抓键盘用)
//       给完权限要退出重启终端才生效。

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

// ── 全局配置 ──
static int g_w = 640, g_h = 360, g_fps = 10, g_max_frames = 0;
static int g_skip_countdown = 0;
static const char *g_display_spec = "builtin";
static const char *g_source = "mixed";
static const char *g_view = "FPV";
static char g_out_dir[2048];
static char g_stop_file[512] = "/tmp/aurora_video_stop";

// ── 键盘状态(共享) ──
static pthread_mutex_t g_kb_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_pressed[256];        // keycode -> 1 表示当前按住
static FILE *g_raw_keys = NULL;   // 原始按键边沿日志
static CFRunLoopRef g_kb_rl = NULL;

// 按键映射 (复用项目 collect.py 的 VK_MAP: W=0x0D A=0x00 S=0x01 D=0x02 SPACE=0x31 SHIFT(左)=0x38)
// 同时支持方向键。Shift=手刹漂移; Shift+空格=强力刹车 (仅左Shift, 右Shift不绑)
static int is_left(int k)  { return k == 0x00 || k == 0x7B; } // A / LeftArrow
static int is_right(int k) { return k == 0x02 || k == 0x7C; } // D / RightArrow
static int is_thr(int k)   { return k == 0x0D || k == 0x7E; } // W / UpArrow
static int is_brk(int k)   { return k == 0x01 || k == 0x7D || k == 0x31; } // S / DownArrow / Space
static int is_shift(int k) { return k == 0x38; }              // 仅左 Shift = 手刹漂移 / 强力刹车

static double now_sec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + tv.tv_usec / 1e6;
}

// ── 选屏 ──
static int resolve_display(const char *spec, CGDirectDisplayID *out) {
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, ids, &count);
    CGDirectDisplayID main = CGMainDisplayID();
    if (spec == NULL || strcmp(spec, "builtin") == 0) {
        for (uint32_t i = 0; i < count; i++) {
            if (CGDisplayIsBuiltin(ids[i])) { *out = ids[i]; return 0; }
        }
        if (spec && strcmp(spec, "builtin") == 0)
            fprintf(stderr, "[warn] 无内建屏, 退回主屏\n");
        *out = main;
        return 0;
    }
    if (strcmp(spec, "main") == 0) { *out = main; return 0; }
    int idx = atoi(spec);
    if (idx >= 0 && idx < (int)count) { *out = ids[idx]; return 0; }
    fprintf(stderr, "[error] 无效 display: %s\n", spec);
    return -1;
}

// ── 抓一帧到 JPEG ──
static int capture_frame(CGDirectDisplayID did, const char *outpath) {
    CGImageRef img = CGDisplayCreateImage(did);
    if (!img) return 0;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        NULL, g_w, g_h, 8, g_w * 4, cs,
        kCGImageByteOrder32Big | kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { CGImageRelease(img); return 0; }
    CGRect rect = CGRectMake(0, 0, g_w, g_h);
    CGContextDrawImage(ctx, rect, img);
    CGImageRelease(img);
    CGImageRef resized = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!resized) return 0;
    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    CFStringRef uti = CFSTR("public.jpeg");
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, uti, 1, NULL);
    CGImageDestinationAddImage(dest, resized, NULL);
    bool ok = CGImageDestinationFinalize(dest);
    CGImageRelease(resized);
    if (!ok) { CFRelease(dest); CFRelease(data); return 0; }
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    FILE *f = fopen(outpath, "wb");
    if (!f) { CFRelease(dest); CFRelease(data); return 0; }
    fwrite(bytes, 1, len, f);
    fclose(f);
    CFRelease(dest);
    CFRelease(data);
    return 1;
}

// ── 键盘事件回调 ──
static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *refcon) {
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        int64_t kc = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        int down = (type == kCGEventKeyDown) ? 1 : 0;
        double t = now_sec();
        pthread_mutex_lock(&g_kb_lock);
        if (kc >= 0 && kc < 256) g_pressed[kc] = down;
        if (g_raw_keys) {
            fprintf(g_raw_keys, "%.4f,%lld,%s\n", t, (long long)kc, down ? "down" : "up");
            fflush(g_raw_keys);
        }
        pthread_mutex_unlock(&g_kb_lock);
    }
    return event;
}

static void *kb_thread(void *arg) {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    CFMachPortRef port = CGEventTapCreate(
        kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, tap_callback, NULL);
    if (!port) {
        fprintf(stderr, "[warn] 键盘 tap 创建失败 → 不会录到键盘。\n"
                        "       需: 系统设置→隐私与安全性→输入监控, 给\"终端\"打勾并重启终端。\n");
        return NULL;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, port, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(port, true);
    g_kb_rl = CFRunLoopGetCurrent();
    CFRunLoopRun();
    return NULL;
}

// 按帧推导 (steer,throttle,brake,handbrake,strong_brake)
static void derive_and_write(FILE *controls, double t, long frame) {
    pthread_mutex_lock(&g_kb_lock);
    int left = 0, right = 0, thr = 0, brk = 0, shift = 0, space = 0;
    for (int k = 0; k < 256; k++) {
        if (!g_pressed[k]) continue;
        if (is_left(k))  left = 1;
        if (is_right(k)) right = 1;
        if (is_thr(k))   thr = 1;
        if (is_brk(k))   brk = 1;
        if (is_shift(k)) shift = 1;
        if (k == 0x31)   space = 1;   // 空格键(区分手刹/强力刹车)
    }
    pthread_mutex_unlock(&g_kb_lock);
    double steer = (left && !right) ? -1.0 : (right && !left) ? 1.0 : 0.0;
    double throttle = thr ? 1.0 : 0.0;
    double brake = brk ? 1.0 : 0.0;
    double handbrake = (shift && !space) ? 1.0 : 0.0;   // 手刹漂移: 仅 Shift(不按空格)
    double strong_brake = (shift && space) ? 1.0 : 0.0; // 强力刹车: Shift+空格
    fprintf(controls, "%.4f,%ld,%.1f,%.1f,%.1f,%.1f,%.1f\n", t, frame, steer, throttle, brake, handbrake, strong_brake);
}

int main(int argc, char **argv) {
    int do_list = 0, now = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "list") == 0) { do_list = 1; }
        else if (strcmp(argv[i], "--now") == 0) { now = 1; }
        else if (strcmp(argv[i], "--no-countdown") == 0) { now = 1; g_skip_countdown = 1; }
        else if (strcmp(argv[i], "--display") == 0 && i + 1 < argc) { g_display_spec = argv[++i]; }
        else if (strcmp(argv[i], "--source") == 0 && i + 1 < argc) { g_source = argv[++i]; }
        else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) { g_w = atoi(argv[++i]); }
        else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) { g_h = atoi(argv[++i]); }
        else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) { g_fps = atoi(argv[++i]); }
        else if (strcmp(argv[i], "--max-frames") == 0 && i + 1 < argc) { g_max_frames = atoi(argv[++i]); }
        else if (strcmp(argv[i], "--stop-file") == 0 && i + 1 < argc) { snprintf(g_stop_file, sizeof(g_stop_file), "%s", argv[++i]); }
        else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) { snprintf(g_out_dir, sizeof(g_out_dir), "%s", argv[++i]); }
        else if (strcmp(argv[i], "--view") == 0 && i + 1 < argc) { g_view = argv[++i]; }
    }

    if (do_list) {
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

    CGDirectDisplayID did;
    if (resolve_display(g_display_spec, &did) != 0) return 3;

    // 输出目录
    if (g_out_dir[0] == '\0') {
        time_t t = time(NULL);
        struct tm *tm = localtime(&t);
        char ts[64];
        strftime(ts, sizeof(ts), "%Y%m%d_%H%M%S", tm);
        char proj_root[2048];
        char resolved[2048];
        char *rp = realpath(argv[0], resolved);
        if (rp) {
            char *last = strrchr(resolved, '/');
            if (last) *last = '\0';   // 去 aurora_recorder -> tools/
            last = strrchr(resolved, '/');
            if (last) *last = '\0';   // 去 tools -> 项目根
            snprintf(proj_root, sizeof(proj_root), "%s", resolved);
        } else {
            snprintf(proj_root, sizeof(proj_root), ".");
        }
        snprintf(g_out_dir, sizeof(g_out_dir),
                 "%s/data/raw_clips/clip_%s", proj_root, ts);
    }
    char frames_dir[2048];
    snprintf(frames_dir, sizeof(frames_dir), "%s/frames", g_out_dir);
    mkdir(g_out_dir, 0755);
    mkdir(frames_dir, 0755);

    // view.txt: 视角标注 (FPV/TPV), 训练端 MonoClipsDataset._clip_view 读取
    char view_path[2048];
    snprintf(view_path, sizeof(view_path), "%s/view.txt", g_out_dir);
    FILE *vf = fopen(view_path, "w");
    if (vf) { fprintf(vf, "%s\n", g_view); fclose(vf); }

    // 自检: 抓一帧, 太小=空屏/权限/错屏
    char testp[2048];
    snprintf(testp, sizeof(testp), "%s/_test.jpg", g_out_dir);
    if (!capture_frame(did, testp)) {
        fprintf(stderr, "[error] 截屏失败: 权限未给终端(系统设置→隐私→屏幕录制) 或显示器不可用\n");
        return 1;
    }
    long sz = 0;
    FILE *tf = fopen(testp, "rb"); if (tf) { fseek(tf,0,SEEK_END); sz=ftell(tf); fclose(tf); }
    remove(testp);
    if (sz < 12000) {
        fprintf(stderr, "[error] 截屏返回的是空帧(%.0fKB): 多半选错屏 或 权限未生效。\n"
                        "        用 'aurora_recorder list' 看游戏在哪块屏, 再加 --display N。\n"
                        "        若双击启动, 先 xattr -cr ~/Desktop/AuroraRecorder.command 并改 bash 启动。\n", sz/1024.0);
        return 1;
    }
    fprintf(stderr, "[ok] 截屏正常 (%.0fKB)\n", sz/1024.0);

    // 打开输出文件
    char ctrl_path[2048], keylog_path[2048], json_path[2048];
    snprintf(ctrl_path, sizeof(ctrl_path), "%s/controls.csv", g_out_dir);
    snprintf(keylog_path, sizeof(keylog_path), "%s/keylog.csv", g_out_dir);
    snprintf(json_path, sizeof(json_path), "%s/clip.json", g_out_dir);
    // E1/E2 根治：fopen 返回值必须检查，失败则报错退出，避免 fprintf(NULL) 段错误
    FILE *controls = fopen(ctrl_path, "w");
    if (!controls) {
        fprintf(stderr, "[error] 无法创建 %s: %s\n", ctrl_path, strerror(errno));
        return 1;
    }
    fprintf(controls, "t_sec,frame,steer,throttle,brake,handbrake,strong_brake\n");
    g_raw_keys = fopen(keylog_path, "w");
    if (!g_raw_keys) {
        fprintf(stderr, "[error] 无法创建 %s: %s\n", keylog_path, strerror(errno));
        fclose(controls);
        return 1;
    }
    fprintf(g_raw_keys, "t_sec,keycode,event\n");

    // 启动键盘线程
    pthread_t kt;
    pthread_create(&kt, NULL, kb_thread, NULL);

    // 倒计时
    if (now && !g_skip_countdown) {
        fprintf(stderr, "3 秒后开始 — 切到游戏!\n");
        for (int i = 3; i >= 1; i--) { fprintf(stderr, "  %d...\n", i); sleep(1); }
    }

    double interval = 1.0 / g_fps;
    long frame = 0;
    double t0 = now_sec();
    fprintf(stderr, "[录制中] 停止: touch %s  或 Ctrl+C\n", g_stop_file);
    while (1) {
        double ts = now_sec();
        char fp[2048];
        snprintf(fp, sizeof(fp), "%s/%06ld.jpg", frames_dir, frame);
        if (!capture_frame(did, fp)) {
            fprintf(stderr, "[warn] 第 %ld 帧截屏失败, 重试\n", frame);
            usleep(50000);
            if (access(g_stop_file, F_OK) == 0) break;
            continue;
        }
        derive_and_write(controls, ts - t0, frame);
        frame++;
        fflush(controls);

        if (g_max_frames > 0 && frame >= g_max_frames) break;
        if (access(g_stop_file, F_OK) == 0) break;
        double dt = now_sec() - ts;
        if (dt < interval) usleep((useconds_t)((interval - dt) * 1e6));
    }

    // 收尾
    if (g_kb_rl) CFRunLoopStop(g_kb_rl);
    double dur = now_sec() - t0;
    fclose(controls);
    if (g_raw_keys) fclose(g_raw_keys);

    char *bname = strrchr(g_out_dir, '/');
    const char *clip_name = bname ? bname + 1 : g_out_dir;

    FILE *jf = fopen(json_path, "w");
    // E3 根治：jf fopen 失败时跳过元数据写入，避免 fprintf(NULL) 段错误
    if (!jf) {
        fprintf(stderr, "[error] 无法创建 %s: %s（元数据未写入，但录制数据已保存）\n",
                json_path, strerror(errno));
    } else {
        fprintf(jf,
            "{\n  \"name\": \"%s\",\n  \"drive_source\": \"%s\",\n"
            "  \"fps\": %d,\n  \"width\": %d,\n  \"height\": %d,\n"
            "  \"total_frames\": %ld,\n  \"duration_seconds\": %.1f,\n"
            "  \"has_keyboard\": true,\n  \"display\": \"%s\",\n"
            "  \"created_at\": \"%s\"\n}\n",
            clip_name, g_source, g_fps, g_w, g_h, frame, dur, g_display_spec, "");
        fclose(jf);
    }

    fprintf(stderr, "\n[完成] 帧数=%ld 时长=%.0fs\n  画面: %s/frames/\n  控制: %s\n  %s\n",
            frame, dur, g_out_dir, ctrl_path, g_out_dir);
    return 0;
}
