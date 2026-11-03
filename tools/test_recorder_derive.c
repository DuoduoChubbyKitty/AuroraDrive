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

int main(void) {
    printf("================ 录制器按键推导 穷举压力测试 ================\n");
    test_all_combinations();
    test_arrow_keys();
    test_degenerate();
    test_no_state_leak();
    printf("===========================================================\n");
    printf("共 %d 项断言，失败 %d 项\n", g_checks, g_fail);
    printf("%s\n", g_fail == 0 ? "PASS" : "FAIL");
    return g_fail ? 1 : 0;
}
