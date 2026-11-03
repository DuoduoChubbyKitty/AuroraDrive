// test_recorder_derive.c — 录制器按键推导的穷举压力测试
//
// 手法：把 aurora_recorder.c 的 main 改名后 #include 进来，从而直接测到
// **生产代码里的 static derive_and_write**，而不是复刻一份逻辑（复刻会漂移）。
//
// 覆盖：
//   1. W/A/S/D/Shift/Space 六个原子键的 2^6 = 64 种组合穷举
//   2. 每行必须是 10 列
//   3. 原子键列必须与输入逐位一致
//   4. 组合键必须严格等于原子键的逻辑与（super = shift&space，ultimate = shift&space&s）
//   5. t_sec / frame 字段格式正确
//   6. 方向键与字母键等价（A/← 等）
//   7. 连续 10000 帧不崩、不粘滞（每次调用状态独立）
//
// 编译：
//   clang -O2 -I. -mmacosx-version-min=13.0 -o /tmp/test_recorder_derive \
//         tools/test_recorder_derive.c \
//         -framework CoreGraphics -framework CoreFoundation -framework ImageIO

#define main aurora_recorder_main_renamed
#include "aurora_recorder.c"
#undef main

#include <math.h>
#include <string.h>

static int g_fail = 0;
static int g_checks = 0;

#define CHECK(cond, fmt, ...)                                    \
    do {                                                         \
        g_checks++;                                              \
        if (!(cond)) {                                           \
            g_fail++;                                            \
            printf("  [FAIL] " fmt "\n", ##__VA_ARGS__);         \
        }                                                        \
    } while (0)

// 按位设置六个原子键（bit0..bit5 = w,a,s,d,shift,space）
static void set_keys(int mask) {
    for (int i = 0; i < 256; i++) g_pressed[i] = 0;
    if (mask & 1)  g_pressed[0x0D] = 1;  // W
    if (mask & 2)  g_pressed[0x00] = 1;  // A
    if (mask & 4)  g_pressed[0x01] = 1;  // S
    if (mask & 8)  g_pressed[0x02] = 1;  // D
    if (mask & 16) g_pressed[0x38] = 1;  // Shift
    if (mask & 32) g_pressed[0x31] = 1;  // Space
}

// 一条解析出来的记录
typedef struct {
    double t;
    long frame;
    int v[8];   // w,a,s,d,shift,space,super,ultimate
} Row;

// 调用生产函数并以字符串解析回来；成功返回 1
static int call_and_parse(double t, long frame, Row *out) {
    FILE *f = tmpfile();
    if (!f) return 0;
    derive_and_write(f, t, frame);
    rewind(f);
    char line[512];
    if (!fgets(line, sizeof line, f)) { fclose(f); return 0; }

    // 统计列数
    int cols = 1;
    for (char *p = line; *p; p++) if (*p == ',') cols++;
    fclose(f);
    if (cols != 10) return 0;

    // 逐列解析
    out->frame = frame;
    if (sscanf(line, "%lf,%ld,%d,%d,%d,%d,%d,%d,%d,%d",
               &out->t, &out->frame,
               &out->v[0], &out->v[1], &out->v[2], &out->v[3],
               &out->v[4], &out->v[5], &out->v[6], &out->v[7]) != 10)
        return 0;
    return 1;
}

static void test_all_combinations(void) {
    printf("[1] 穷举 2^6 = 64 种按键组合\n");
    for (int mask = 0; mask < 64; mask++) {
        set_keys(mask);
        Row r;
        CHECK(call_and_parse(1.5 + mask * 0.01, mask, &r),
              "mask=%d 解析失败（列数不是 10 或格式坏）", mask);

        int w = (mask >> 0) & 1, a = (mask >> 1) & 1, s = (mask >> 2) & 1;
        int d = (mask >> 3) & 1, sh = (mask >> 4) & 1, sp = (mask >> 5) & 1;

        CHECK(r.v[0] == w, "mask=%d w 错: 期望%d 实际%d", mask, w, r.v[0]);
        CHECK(r.v[1] == a, "mask=%d a 错: 期望%d 实际%d", mask, a, r.v[1]);
        CHECK(r.v[2] == s, "mask=%d s 错: 期望%d 实际%d", mask, s, r.v[2]);
        CHECK(r.v[3] == d, "mask=%d d 错: 期望%d 实际%d", mask, d, r.v[3]);
        CHECK(r.v[4] == sh, "mask=%d shift 错: 期望%d 实际%d", mask, sh, r.v[4]);
        CHECK(r.v[5] == sp, "mask=%d space 错: 期望%d 实际%d", mask, sp, r.v[5]);
        // 组合键必须是原子键的逻辑与
        CHECK(r.v[6] == (sh && sp), "mask=%d super 错: 期望%d 实际%d",
              mask, sh && sp, r.v[6]);
        CHECK(r.v[7] == (sh && sp && s), "mask=%d ultimate 错: 期望%d 实际%d",
              mask, sh && sp && s, r.v[7]);
        // frame 字段
        CHECK(r.frame == mask, "mask=%d frame 错: 实际%ld", mask, r.frame);
    }
}

static void test_arrow_keys(void) {
    printf("[2] 方向键应与字母键等价\n");
    struct { int letter, arrow; const char *name; } pairs[] = {
        {0x00, 0x7B, "A/←"}, {0x02, 0x7C, "D/→"},
        {0x0D, 0x7E, "W/↑"}, {0x01, 0x7D, "S/↓"},
    };
    for (unsigned i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
        for (int pc = 0; pc < 256; pc++) g_pressed[pc] = 0;
        g_pressed[pairs[i].letter] = 1;
        Row r1;
        CHECK(call_and_parse(1.0, 1, &r1), "%s 字母键解析失败", pairs[i].name);

        for (int pc = 0; pc < 256; pc++) g_pressed[pc] = 0;
        g_pressed[pairs[i].arrow] = 1;
        Row r2;
        CHECK(call_and_parse(1.0, 1, &r2), "%s 方向键解析失败", pairs[i].name);

        for (int k = 0; k < 6; k++)
            CHECK(r1.v[k] == r2.v[k], "%s 字母/方向键不一致（列%d）", pairs[i].name, k);
    }
}

static void test_degenerate(void) {
    printf("[3] 退化情况\n");
    // 全不按
    set_keys(0);
    Row r;
    CHECK(call_and_parse(0.0, 0, &r), "全不按解析失败");
    for (int k = 0; k < 8; k++)
        CHECK(r.v[k] == 0, "全不按时列%d 应为0 实际%d", k, r.v[k]);

    // 全按（含 A+D、W+S 同时，录制器应如实记录，不静默改写）
    set_keys(63);
    CHECK(call_and_parse(9.9, 9, &r), "全按解析失败");
    for (int k = 0; k < 6; k++)
        CHECK(r.v[k] == 1, "全按时原子键列%d 应为1（录制器不该改写输入）", k);
    CHECK(r.v[6] == 1 && r.v[7] == 1, "全按时组合键应为1");

    // 时间字段精度
    set_keys(0);
    CHECK(call_and_parse(123.4567, 987654, &r), "大 frame 解析失败");
    CHECK(fabs(r.t - 123.4567) < 1e-4, "t_sec 精度丢失: %f", r.t);
    CHECK(r.frame == 987654, "frame 大数值错: %ld", r.frame);
}

static void test_no_state_leak(void) {
    printf("[4] 连续 10000 帧状态独立性\n");
    FILE *f = tmpfile();
    if (!f) { printf("  [FAIL] tmpfile 失败\n"); g_fail++; return; }
    for (int i = 0; i < 10000; i++) {
        set_keys(i % 64);
        derive_and_write(f, i * 0.01, i);
    }
    rewind(f);
    char line[512];
    int n = 0, bad = 0;
    while (fgets(line, sizeof line, f)) {
        int cols = 1;
        for (char *p = line; *p; p++) if (*p == ',') cols++;
        if (cols != 10) bad++;
        int st = (n % 64);
        int w = st & 1, a = (st >> 1) & 1, s = (st >> 2) & 1, d = (st >> 3) & 1;
        int sh = (st >> 4) & 1, sp = (st >> 5) & 1;
        int v[8]; double t; long fr;
        if (sscanf(line, "%lf,%ld,%d,%d,%d,%d,%d,%d,%d,%d",
                   &t, &fr, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) != 10) {
            bad++;
        } else if (v[0] != w || v[1] != a || v[2] != s || v[3] != d ||
                   v[4] != sh || v[5] != sp ||
                   v[6] != (sh && sp) || v[7] != (sh && sp && s) || fr != n) {
            bad++;
        }
        n++;
    }
    fclose(f);
    CHECK(n == 10000, "应有 10000 行，实际 %d", n);
    CHECK(bad == 0, "10000 帧中有 %d 行错", bad);
}

// [5] 键盘事件层：Shift 只走 flagsChanged（这是 694 项断言覆盖不到的盲区）
//
// 为什么必须单独测这一层：上面的 test_all_combinations 等直接写
// `g_pressed[0x38]=1`，**绕过了事件分发**。所以哪怕录制器根本没订阅
// flagsChanged、真实 Shift 一帧都收不到，那些断言依然全部 PASS。
// 这正是本次审查抓到的安全级 bug：shift 列恒 0 → 三个安全头零正样本。
static void test_modifier_flags_changed(void) {
    printf("[5] 修饰键事件层（flagsChanged）\n");

    for (int i = 0; i < 256; i++) g_pressed[i] = 0;

    // Shift 按下：flagsChanged + Shift 位 = 1
    recorder_handle_event(kCGEventFlagsChanged, 0x38, kCGEventFlagMaskShift, 1.0, NULL);
    CHECK(g_pressed[0x38] == 1, "flagsChanged 带 Shift 位后，g_pressed[0x38] 应为 1");

    // 此时 derive 应输出 shift=1（即使没按空格，shift 单独就是手刹）
    FILE *f = tmpfile();
    if (!f) { printf("  [FAIL] tmpfile 失败\n"); g_fail++; return; }
    derive_and_write(f, 1.0, 0);
    rewind(f);
    char line[512];
    int v[8]; double t; long fr;
    CHECK(fgets(line, sizeof line, f) != NULL, "读行失败");
    CHECK(sscanf(line, "%lf,%ld,%d,%d,%d,%d,%d,%d,%d,%d",
                 &t, &fr, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) == 10,
          "解析失败");
    CHECK(v[4] == 1, "Shift 按下时 shift 列应为 1（实际 %d）", v[4]);
    CHECK(v[6] == 0 && v[7] == 0, "只按 Shift 时组合键应为 0");

    // Shift + Space → super_brake=1（此时 shift 位仍在）
    recorder_handle_event(kCGEventKeyDown, 0x31, kCGEventFlagMaskShift, 2.0, NULL);
    rewind(f); fclose(f); f = tmpfile();
    derive_and_write(f, 2.0, 1);
    rewind(f);
    CHECK(fgets(line, sizeof line, f) != NULL, "读行失败");
    sscanf(line, "%lf,%ld,%d,%d,%d,%d,%d,%d,%d,%d",
           &t, &fr, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]);
    CHECK(v[4] == 1 && v[5] == 1, "Shift+Space 时 shift/space 均应为 1");
    CHECK(v[6] == 1, "Shift+Space 时 super_brake 应为 1");

    // Shift 松开：flagsChanged 且 **不带** Shift 位 → 必须归 0
    recorder_handle_event(kCGEventFlagsChanged, 0x38, 0, 3.0, NULL);
    CHECK(g_pressed[0x38] == 0, "Shift 位清除后 g_pressed[0x38] 应为 0（不能粘滞）");

    // 关键回归：按下 Shift 后再按普通键，也会产生 flagsChanged。
    // 若用"翻转状态位"实现，这里会把 Shift 错误翻成 0 → 手刹丢失。
    recorder_handle_event(kCGEventFlagsChanged, 0x38, kCGEventFlagMaskShift, 4.0, NULL);
    recorder_handle_event(kCGEventKeyDown, 0x0D, kCGEventFlagMaskShift, 4.1, NULL);
    recorder_handle_event(kCGEventFlagsChanged, 0x38, kCGEventFlagMaskShift, 4.2, NULL);
    CHECK(g_pressed[0x38] == 1, "Shift 按住期间再按 W 产生的 flagsChanged 不应清掉 Shift");
    CHECK(g_pressed[0x0D] == 1, "W 应处于按下状态");

    // 清理
    for (int i = 0; i < 256; i++) g_pressed[i] = 0;
    fclose(f);
}

// [6] 有标签帧计数（P1-4）：决定收尾会不会误判「零标签」而拒绝一份好数据
//
// 为什么必须测：main 的收尾健康检查用 g_labeled_frames == 0 判定「本场无任何按键」
// 并返回 1。若计数实现写错（例如多键同帧重复累加、或全零帧也计数），
// 后果分别是「好数据被误判成功」与「好数据被误报失败」，两者都会误导用户。
static void test_labeled_counter(void) {
    printf("[6] 有标签帧计数（g_labeled_frames）\n");
    FILE *f = tmpfile();
    if (!f) { printf("  [FAIL] tmpfile 失败\n"); g_fail++; return; }

    // 全零帧：不应计数
    g_labeled_frames = 0;
    set_keys(0);
    derive_and_write(f, 0.0, 0);
    derive_and_write(f, 0.1, 1);
    CHECK(g_labeled_frames == 0, "全零的 2 帧不应计入，实际 %ld", g_labeled_frames);

    // 六个原子键各自单按 1 帧：应恰好计 6
    g_labeled_frames = 0;
    for (int bit = 0; bit < 6; bit++) {
        set_keys(1 << bit);
        derive_and_write(f, 1.0 + bit * 0.1, 2 + bit);
    }
    CHECK(g_labeled_frames == 6, "6 个原子键各 1 帧应计 6，实际 %ld", g_labeled_frames);

    // 同帧多键：按「帧」计 1，不按「按键个数」重复累加
    long before = (long)g_labeled_frames;
    set_keys(63);
    derive_and_write(f, 2.0, 8);
    CHECK(g_labeled_frames == before + 1, "全按 1 帧应只计 1（多键不能重复计），实际 %ld",
          g_labeled_frames);

    // 64 种组合各 1 帧：0 号是全零（不计），其余 63 帧各计 1
    g_labeled_frames = 0;
    for (int m = 0; m < 64; m++) {
        set_keys(m);
        derive_and_write(f, 3.0 + m * 0.01, 9 + m);
    }
    CHECK(g_labeled_frames == 63, "64 种组合应恰好 63 帧有标签（全零不计），实际 %ld",
          g_labeled_frames);

    set_keys(0);
    fclose(f);
}

int main(void) {
    printf("================ 录制器按键推导 穷举压力测试 ================\n");
    test_all_combinations();
    test_arrow_keys();
    test_degenerate();
    test_no_state_leak();
    test_modifier_flags_changed();
    test_labeled_counter();
    printf("===========================================================\n");
    printf("共 %d 项断言，失败 %d 项\n", g_checks, g_fail);
    printf("%s\n", g_fail == 0 ? "PASS" : "FAIL");
    return g_fail ? 1 : 0;
}
