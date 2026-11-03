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
//   controls.csv            t_sec,frame,w,a,s,d,shift,space,super_brake,ultimate_brake
//                           (每帧一行, 直接喂训练; 列名即原始按键, 无物理量转换)
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
// fps 默认 15：**必须与部署端 tick 一致**，否则训练/部署的时序分布不一致。
//   依据（均为实测，非推断）：
//     · `Sources/AuroraDrive/Core/EngineMain.swift:709` 定档：
//       「tick（推理+控制+录制）：15Hz（两档都是）」，`tickHz()` 两档都返回 15.0。
//     · `src/model_v3.py:274`：V3 时序窗口按 15Hz 设计
//       （24 帧 = 3 高清 + 21 低清 ≈ 1.6 秒）。
//   若按旧的 10fps 录：同样 24 帧实际跨 2.4 秒，训练时每帧位移比部署时小
//   → 模型学到"偏慢"的动态 → 部署时刹车偏晚。这是分布不一致，不是风格问题。
static int g_w = 640, g_h = 360, g_fps = 15, g_max_frames = 0;
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
// 同时支持方向键。
//
// 【2026-11-03 定稿】键位语义以用户口头确认为准（用户是实际驾驶者）：
//   Shift = 手刹；空格 = 正常刹车；Shift+空格 = 超级刹车；Shift+空格+S = 极致刹车。
//   S 单独按 = 后退。
//
// 旧实现的致命 bug：把 S/↓/空格 全并进一个 is_brk，导致 controls.csv 无法区分
// 「后退」和「刹车」—— 训练 V3 时 S 类与 space 头永远学不到。实测证据：只按
// Space 与只按 S 会产出完全相同的行。
//
// 现在每个键独立匹配，推导逻辑见 derive_and_write：
//   W / ↑            → w 列
//   A / ←            → a 列
//   S / ↓            → s 列（后退）
//   D / →            → d 列
//   空格             → space 列（正常刹车）
//   左 Shift         → shift 列（手刹）
//   Shift+空格       → super_brake 列（超级刹车）
//   左 Shift+空格+S  → ultimate_brake 列（极致刹车）
static int is_left(int k)  { return k == 0x00 || k == 0x7B; } // A / LeftArrow
static int is_right(int k) { return k == 0x02 || k == 0x7C; } // D / RightArrow
static int is_thr(int k)   { return k == 0x0D || k == 0x7E; } // W / UpArrow
static int is_reverse(int k) { return k == 0x01 || k == 0x7D; } // S / DownArrow（后退，不含空格）
static int is_space(int k) { return k == 0x31; }              // 空格 = 正常刹车
static int is_shift(int k) { return k == 0x38; }              // 仅左 Shift = 手刹

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

// ── 键盘事件处理（抽成独立函数，便于单测；见 test_recorder_derive.c）──
//
// ⚠️ 2026-11-03 安全级修复：**macOS 的修饰键（Shift）只走 flagsChanged 通道**
//    实测证据（零风险探针，只读合成事件 type、不投递按键）：
//        W(0x0D)      down/up → type=10 keyDown(2) / type=11 keyUp(3)
//        A/S/Space/←  同上
//        Shift(0x38)  down/up → type=12 **flagsChanged(12)**  ← 两个方向都是 12
//    而旧代码只订阅 `kCGEventKeyDown | kCGEventKeyUp`，**永远收不到 Shift** →
//    `shift` 列恒为 0 → handbrake / super_brake / ultimate 三个安全头
//    **从训练第一天起就没有任何正样本**（且 loss 完全正常，看不出来）。
//
//    仓库内早有同类记录：`Sources/AuroraDrive/Agent/LLMSelfTest.swift:1940-1964`
//    写明「修饰键只投 flagsChanged(12)。若 tap 只订阅 keyDown/keyUp 就收不到」，
//    并已在该处同时订阅 flagsChanged —— 录制器此前没有照做。
//
// 为什么不靠 event 里的 keycode 判断 Shift 的按下/松开：
//    flagsChanged 事件不带 "down/up"，只带**当前修饰键位图**（CGEventFlags）。
//    唯一可靠的判据是读 flags 里有没有 kCGEventFlagMaskShift。
//    另外：按下 Shift 后再按别的键，也会产生新的 flagsChanged，所以这里
//    每次都按"当前 flags 全量刷新"，而不是翻转某个状态位（翻转会失控）。
static void recorder_update_modifier_state(CGEventFlags flags) {
    int shift_now = (flags & kCGEventFlagMaskShift) ? 1 : 0;
    pthread_mutex_lock(&g_kb_lock);
    g_pressed[0x38] = shift_now;   // 左 Shift = 手刹
    pthread_mutex_unlock(&g_kb_lock);
}

static void recorder_handle_event(CGEventType type, int64_t keycode,
                                  CGEventFlags flags, double t,
                                  int *out_down) {
    int down = -1;
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        down = (type == kCGEventKeyDown) ? 1 : 0;
        pthread_mutex_lock(&g_kb_lock);
        if (keycode >= 0 && keycode < 256) g_pressed[keycode] = down;
        pthread_mutex_unlock(&g_kb_lock);
    } else if (type == kCGEventFlagsChanged) {
        recorder_update_modifier_state(flags);
        // 修饰键的 down/up 由 flags 位反推（仅用于日志可读性）
        down = (flags & kCGEventFlagMaskShift) ? 1 : 0;
    }

    if (down >= 0 && g_raw_keys) {
        pthread_mutex_lock(&g_kb_lock);
        fprintf(g_raw_keys, "%.4f,%lld,%s\n", t, (long long)keycode,
                down ? "down" : "up");
        fflush(g_raw_keys);
        pthread_mutex_unlock(&g_kb_lock);
    }
    if (out_down) *out_down = down;
}

// ── 键盘事件回调 ──
static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *refcon) {
    if (type == kCGEventKeyDown || type == kCGEventKeyUp
        || type == kCGEventFlagsChanged) {
        int64_t kc = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags fl = CGEventGetFlags(event);
        recorder_handle_event(type, kc, fl, now_sec(), NULL);
    }
    return event;
}

static void *kb_thread(void *arg) {
    // 必须同时订阅 flagsChanged，否则 Shift 永远收不到（见 recorder_handle_event 上方说明）
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)
                     | CGEventMaskBit(kCGEventKeyUp)
                     | CGEventMaskBit(kCGEventFlagsChanged);
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

// 按帧推导并按【原始按键】写一行 CSV
//
// 列（共 10 列）：t_sec, frame, w, a, s, d, shift, space, super_brake, ultimate_brake
//
// 为什么用原始按键名而不是物理量：V3 输出本身就是离散按键标签，
// 中间不需要「连续量→按键」的翻译层。CSV 直接记录「这一帧哪些键按着」，模型直接学。
// 旧命名是 V2 连续量模型时代的遗留，会让人误以为还要做回归。
// 旧实现还把 S/↓/空格 全并进 brake 一列，导致「后退」与「刹车」永远无法区分。
//
// 列（共 10 列）：t_sec, frame, w, a, s, d, shift, space, super_brake, ultimate_brake
//
// 为什么既留原子键又留组合键：模型有 8 个输出头，super_brake / ultimate 是独立头，
// 需要直接监督信号；w/a/s/d/shift/space 是原子事实。两者都从同一份 g_pressed 推导，
// 不可能不一致；verify_recording.py 再用「组合键 == 原子键的逻辑与」交叉校验，多一道保险。
//
// 为什么不在这里强制 a/d 互斥（旧版用 left && !right 强行二选一）：记录原始事实。
// 真实操作里同时按 A+D 是退化情况，由训练侧构造标签时映射为 horizontal=NONE
// （游戏内也是相互抵消），而不是在录制时静默改写用户输入。
static void derive_and_write(FILE *controls, double t, long frame) {
    pthread_mutex_lock(&g_kb_lock);
    int w = 0, a = 0, s = 0, d = 0, shift = 0, space = 0;
    for (int k = 0; k < 256; k++) {
        if (!g_pressed[k]) continue;
        if (is_thr(k))     w = 1;   // W / 上箭头
        if (is_left(k))    a = 1;   // A / 左箭头
        if (is_reverse(k)) s = 1;   // S / 下箭头
        if (is_right(k))   d = 1;   // D / 右箭头
        if (is_shift(k))   shift = 1;
        if (is_space(k))   space = 1;
    }
    pthread_mutex_unlock(&g_kb_lock);
    // Shift+空格 = 超级刹车（短按）；长按由下游按时长升格为极致刹车
    int super_brake = (shift && space) ? 1 : 0;
    // Shift+空格+S = 极致刹车（S 同时是防翻车稳定键，见 03-output-head.md 安全约束）
    int ultimate_brake = (shift && space && s) ? 1 : 0;
    fprintf(controls, "%.4f,%ld,%d,%d,%d,%d,%d,%d,%d,%d\n",
            t, frame, w, a, s, d, shift, space, super_brake, ultimate_brake);
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

    // ── 参数合法性校验（fail-fast，必须在开始录制前）──
    // 为什么必须有：`--fps abc` 经 atoi 得 0 → 后面的 `double interval = 1.0 / g_fps;`
    // 除零（IEEE754 得 inf，再 usleep((useconds_t)(inf*1e6)) 是未定义行为）；
    // `--width 0` 会让截屏尺寸为 0，写出的 jpg 全部无效。
    // 这类错误若不在录制前炸掉，用户会录完一整场才发现数据不可用。
    if (g_fps <= 0 || g_fps > 240) {
        fprintf(stderr, "[error] --fps 必须在 1~240 之间，收到 %d\n", g_fps);
        return 2;
    }
    if (g_w <= 0 || g_h <= 0) {
        fprintf(stderr, "[error] --width/--height 必须为正数，收到 %d x %d\n", g_w, g_h);
        return 2;
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
    fprintf(controls, "t_sec,frame,w,a,s,d,shift,space,super_brake,ultimate_brake\n");
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
