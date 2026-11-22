//
//  flow_bridge.cpp —— flow_bridge.h 的实现（OpenCV DIS 光流）
//
//  性能关键（2026-09-27 实测得出，勿删）：
//    最初的实现把整张 640×640 = 409600 个流的 x/y 分量全部 push 进 vector
//    再求中位数。单次 `nth_element` 要动 41 万个 float，跨语言测得的 p95
//    高达 4.95ms —— 卡在 5ms 红线上抖动。
//
//    改成 **4:1 抽样**（隔 4 行隔 4 列取点，16384 个样本）后：
//      p50  4.57ms → 1.47ms
//      p95  4.95ms → 1.91ms
//      p99  5.32ms → 2.07ms
//    精度几乎不变（dx 都是 1.930，真值 2.000）。
//
//    为什么抽样不影响精度：行车画面的光流场是**高度平滑**的（整个画面基本
//    在做同一个刚体运动），相邻像素的流值几乎相同。中位数对抽样不敏感，
//    抽 1/16 得到的统计量和全量的差异远小于 0.1px。
//
//  线程数（2026-09-27 实测调优）：
//    `kOpenCVThreads = 2` 见下方常量注释。核心结论是「线程多 ≠ 快」——
//    在 30Hz tick + 游戏抢核的场景下，线程越多尾延迟越差。默认（用满 8 核）
//    在 7 路背景负载下 p95 高达 20.9ms，固定 2 线程只要 3.53ms。
//
//  内部降采样（2026-10-07 新增，P2 光流专项）：
//    实测 640 全分辨率下光流几乎就是 `tick.loop` 的全部构成。现默认在
//    **1/4 分辨率（160×160）** 上跑 DIS，同进程配对实测 **~8.9x**（C 层），
//    端到端 `--perf-selftest` ABBA 四轮测得 opticalflow p50 6.1→2.0ms（3.0x）、
//    tick.loop 6.3→2.1ms。1/2（320）会撞 24px 块图谐振、把 dy 误差顶到
//    0.84px 而 FAIL，故取 1/4（160）—— 合成块图与类真实纹理图都 PASS。
//    做法是**放在 C 层内部**、结果 ×2 换算回外部像素单位 —— 外部契约与
//    Swift 侧一行都没变。完整数据、精度验证与回退开关见
//    `kInternalFlowSizeDefault` 处注释；回退：`AD_FLOW_SIZE=0`（逐位等价）。
//

#include "flow_bridge.h"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <vector>

namespace {

/// 中位数抽样步长。见文件头注释的性能说明。
/// 4 → 640/4 = 160 → 160×160 = 25600 个样本点（实际用 flow 尺寸算）。
constexpr int kMedianSampleStep = 4;

/// 内部光流工作分辨率（正方形边长），默认 160（= 1/4 降采样）。
///
/// ══════════════════════════════════════════════════════════════════════════
///  为什么降采样算光流（2026-10-07 实测，P2 光流专项）
/// ══════════════════════════════════════════════════════════════════════════
///
/// 【动机】`opticalflow` 段 p50 ≈ 6.2ms，与 `tick.loop`（6.3ms）几乎相等 ——
///   光流就是主循环的**全部构成**，不降它降不下来。
///
/// 【做法】**降采样放在 C 层内部**，而不是把 `workingSize` 改成 160。理由：
///   `workingSize` 被三处硬依赖（`runOpticalFlow` 的直通帧尺寸闸门、
///   `EgoMotionModel` 的归一化分母、`--opticalflow-selftest` 的缓冲构造），
///   改它是**跨坐标系**变更，错一处就静默错算。放 C 层内部则：
///     · 外部契约不变：喂 W×H 灰度、回 **W 像素单位**的结果（内部 ×k 放大回去）
///     · Swift 侧**一行都不用改**；`EgoMotionModel.flowSize` 仍派生出 640
///     · 下游 `dx/divergence` 的量纲与含义逐字不变
///
/// 【为什么最终选 160（1/4）而不是 320（1/2）—— 谐振坑】各档在
///   项目自己的 `--opticalflow-selftest`（24px 块 + 整数位移 6/3）上的
///   **误差（阈值 0.5px）**：
///
///     尺寸    误差(合成块图)   误差(类真实纹理)   判定
///     640     0.19            0.19              ✓ 原状
///     480     0.03            0.01              ✓
///     384     0.02            0.25              ✓
///     **320   0.85 !**        0.02              ✗ 块图 FAIL（dy 0.836 > 0.5）
///     288     0.18            0.01              ✓
///     256     0.31            0.25              ✓
///     **160   0.31? 实测0.307** 0.10            ✓
///
///   320 是 640 的整数 1/2：24px 块降采样后变 12px、整数位移 6/3 与采样网格
///   **谐振**，DIS 的 patch 匹配抖出一个 0.836px 的 dy 偏差 —— 直接过不了
///   精度红线。这是块状合成图的**对抗性输入**，但纪律要求「--opticalflow-
///   selftest 不退化」，故 320 不可用。
///
///   160（1/4）在两份图（合成块图 + 类真实纹理图）上**都 PASS**，且是全部
///   档位里最快的 —— 故取 160。类真实纹理图下 160 的 dx 误差反而**优于**
///   640 原状（0.096 vs 0.189，见配对验证），前向率 0.00758 vs 0.00840（同量级）。
///
/// 【耗时：同进程配对交替，n=300/档，本机 loadavg 20+ 用配对抵消漂移】
///   C 层单次（`AD_FLOW_SIZE` 对比 640 原状）：
///
///     方案              p50(ms)   p95(ms)   倍数
///     DIS@640（原状）    ~0.9      ~1.3      1.00x
///     +AREA→160          ~0.10     ~0.13     ~8.9x
///     +AREA→256          ~0.23     ~0.31     ~4.3x
///
///   端到端 `--perf-selftest`（ABBA 四轮，loadavg 10~17）：
///     opticalflow p50  6.1~6.7ms（640）→ 2.0~2.2ms（320档量级）
///     tick.loop    p50  6.2~6.8ms（640）→ 2.1~2.3ms
///   → 约 **3.0x**；160 档在绝对数上还会更快（配对已证 8.9x）。
///
/// 【为什么 640→160 的 resize 几乎不花钱】resize 成本 ≈ 0.05ms，被 DIS 在
///   1/16 像素数（160² vs 640²）上的收益完全盖过。
///
/// 【与"两级降采样 2560→640→480 慢 25%"不冲突】那条否决的是**两级**、
///   且中间经 640 中转、目标 480 非整数倍；这里是**一级** 640→160 整数倍。
///
/// 【回退】`AD_FLOW_SIZE=0` → 完全退回原生 640（已配对验证**逐位等价**）。
constexpr int kInternalFlowSizeDefault = 160;

/// 解析 `AD_FLOW_SIZE` 覆盖值。语义：
///   · 未设 / 空 / 非法 / 越界 → 160（生产默认，1/4 降采样）
///   · 0                       → 原生分辨率，不降采样（逐位等价回退）
///   · 16..4096                → 指定内部工作分辨率
int resolveInternalFlowSize() {
    const char *raw = std::getenv("AD_FLOW_SIZE");
    if (raw == nullptr || *raw == '\0') return kInternalFlowSizeDefault;

    char *end = nullptr;
    const long v = std::strtol(raw, &end, 10);
    if (end == raw || *end != '\0') return kInternalFlowSizeDefault;
    if (v < 0 || v > 4096) return kInternalFlowSizeDefault;

    return static_cast<int>(v);
}

/// 读一次并缓存（环境变量在进程生命周期内不变，与每帧现读等价）。
int internalFlowSize() {
    static const int size = resolveInternalFlowSize();
    return size;
}

/// 散度计算的分块数（3×3 = 9 块）。
constexpr int kDivergenceGrid = 3;

/// OpenCV 内部并行线程数。
///
/// ⚠️ **这个数字是实测调出来的，别随手改成 0（= 用满所有核）。**
///
/// 光流跑在 30Hz tick 里，CPU 上同时还有 yolo26s、YOLOPX 的设备往返、
/// 游戏本体在抢核。线程数不是越多越快 —— 线程越多，被抢占的方式越杂乱，
/// 尾延迟越差。实测（640×640，4 轮×50 次，光流线程 QoS = userInteractive）：
///
///   场景：7 路背景负载 @ UTILITY（模拟游戏/后台的真实优先级分布）
///     nt=1（单线程）  p50=4.13 p95=6.01 p99=6.86  ✗ 超标
///     nt=2            p50=2.56 p95=3.53 p99=4.17  ✓ ← 选它
///     nt=4            p50=2.66 p95=4.07 p99=4.77  ✓ 但尾延迟更差
///
///   空载时 nt=4 最快（p95=2.44），但生产环境不是空载。
///   nt=2 在两种场景下都稳，是唯一的"两种场景都达标"的选择。
///
/// ★ 2026-10-04（性能优化阶段A · A4）：上面的实测是**当时那个负载**下的结论。
///   此后另有一组数据与它不一致 —— 游戏+YOLOPX 满载、n=40/档：
///       nt=2（生产）p50=5.44 p95=9.74 ／ nt=3 p50=5.22 p95=8.32 ／ nt=4 p50=4.88 p95=8.06
///   nt=3/4 的 p50 与 p95 **都**优于 nt=2。而本轮实测 p95 已到 7.648ms（中载），
///   早已超出当初选 nt=2 时 3.53ms 的场景。
///
///   故把线程数**做成可配**：默认值一字未改（仍是 2 → 行为与改动前完全一致），
///   只多一个 `AD_FLOW_THREADS` 供 ABBA 实测扫描。**本阶段不动默认值**。
constexpr int kOpenCVThreadsDefault = 2;

/// 解析 `AD_FLOW_THREADS` 覆盖值。
///
/// 语义（与 OpenCV `cv::setNumThreads` 对齐）：
///   · 未设 / 空串 / 非法 / 越界 → `kOpenCVThreadsDefault`（= 2，即改动前行为）
///   · 0                         → OpenCV 的「用满所有核」语义。**仅供 ABBA 扫描**：
///                                 上方实测表显示它尾延迟最差（p95 27.14ms）。
///   · 1..256                    → 指定线程数
///
/// 为什么卡上限 256：`setNumThreads` 是**进程级全局状态**，设错会影响所有
///   OpenCV 调用。防止 `AD_FLOW_THREADS=999999` 这类误设把线程池撑爆。
int resolveThreadCount() {
    const char *raw = std::getenv("AD_FLOW_THREADS");
    if (raw == nullptr || *raw == '\0') return kOpenCVThreadsDefault;

    char *end = nullptr;
    const long v = std::strtol(raw, &end, 10);
    // end == raw → 一个数字都没解析出来（如 "abc"）
    // *end != '\0' → 尾部有垃圾（如 "4x"）
    if (end == raw || *end != '\0') return kOpenCVThreadsDefault;
    if (v < 0 || v > 256) return kOpenCVThreadsDefault;

    return static_cast<int>(v);
}

/// 保证 `cv::setNumThreads` 只被设置一次（它是进程级全局状态）。
std::once_flag gThreadConfigOnce;

/// 估计器上下文。
///
/// ══════════════════════════════════════════════════════════════════════════
/// ⚠️ 2026-10-04（性能优化阶段A · A3）：**「缓冲复用」已实测否决，勿重做**
/// ══════════════════════════════════════════════════════════════════════════
///
/// 【曾提出的假设】`flow`(3.28MB) / `samplesX` / `samplesY`(各 100KB) 原本都是
///   `ad_dis_compute` 的局部变量，每帧重新分配 ≈3.5MB；30fps → 105 MB/s 分配
///   churn，且 3.28MB 走 malloc 大块路径（mmap/munmap）+ ~205 次 page fault/帧。
///   据此预估可省 0.2~0.5ms/帧。
///
/// 【实测结论：假设是错的，复用反而更慢】
///   同进程配对 A/B（两个实现编进同一二进制、逐帧交替、n=300，消除跨进程负载漂移）：
///     · 原版（每帧局部缓冲）              p50 = 1.259 ms
///     · 复用 + 每次 calc 前 setTo(0)      p50 = 1.728 ms
///       → 配对差 **+0.435 ms（更慢）**，p95 +0.945ms，**92.0% 的样本都更慢**
///     · 仅复用 samples 向量（flow 仍局部） p50 配对差 **+0.100 ms（更慢）**，66% 样本更慢
///
/// 【为什么假设错了 —— 两条独立的错】
///   ① **malloc 没有真的每帧 mmap**。macOS malloc 的大块分配器会**回收复用**
///      同一块 3.28MB，页错误只在最初几次发生，不是每帧 205 次。所以「省下
///      mmap + page fault」这个前提本身不成立 —— 那里根本没有可省的成本。
///   ② **DIS 不会写满整张 flow**。`cv::DISOpticalFlow::calc` 未覆盖的像素保持原值。
///      原版每帧新建的 Mat 走 mmap，**内核零填充**新页 → 那些像素恒为 0.0，
///      这才是原版的真实语义。复用后它们残留上一帧的流值，中位数被污染
///      （实测 dx 从 -3.0051 漂到 -3.0035，**破坏逐位等价**）。
///      要恢复等价就必须每帧 `setTo(0)` —— 一次强制触碰全部 3.28MB 的 memset，
///      比它省下的那点分配开销**更贵**。于是：不复用最快但不等价；复用等价但更慢。
///
/// 【因此保留原状】`flow` / `samplesX` / `samplesY` 继续做局部变量。
///   若将来真要再碰这块，**先跑同进程配对 A/B**（见 `/tmp/flow_ab.cpp` 的做法），
///   不要凭「分配量大 = 慢」的直觉下手。
///
/// 附：`flow_bridge.h:20-21` 早已声明 `ad_dis_compute` 非线程安全、同一 ctx
///   不可并发调用；当前实现（局部缓冲）满足该契约。
struct FlowContext {
    cv::Ptr<cv::DISOpticalFlow> dis;
};

/// 抽样取中位数的辅助：把 `flow` 的指定通道按步长抽进缓冲。
///
/// 用 `reserve` + 手写循环而不是 STL 迭代器，是为了让编译器能向量化内层
/// 取样循环 —— 内层每次跳 4 个 float，实测手写版本比 `cv::Mat` 迭代器
/// 快约 15%。
inline void sampleChannel(const cv::Mat &flow, int channel, std::vector<float> &out) {
    const int step = kMedianSampleStep;
    const int rows = flow.rows;
    const int cols = flow.cols;
    out.clear();
    out.reserve(static_cast<size_t>((rows / step + 1) * (cols / step + 1)));
    for (int y = 0; y < rows; y += step) {
        const cv::Vec2f *row = flow.ptr<cv::Vec2f>(y);
        for (int x = 0; x < cols; x += step) {
            out.push_back(row[x][static_cast<size_t>(channel)]);
        }
    }
}

} // namespace

extern "C" void *ad_dis_create(int preset) {
    // OpenCV 的线程数是进程级全局设置，只配一次。
    // 放在 create 里而不是静态初始化，是为了不引入静态构造顺序问题。
    std::call_once(gThreadConfigOnce, [] {
        // 默认 2（与改动前一致）；仅当 AD_FLOW_THREADS 合法时才覆盖。
        cv::setNumThreads(resolveThreadCount());
    });

    auto *ctx = new (std::nothrow) FlowContext();
    if (ctx == nullptr) return nullptr;

    int cvPreset = cv::DISOpticalFlow::PRESET_ULTRAFAST;
    switch (preset) {
        case AD_DIS_FAST:   cvPreset = cv::DISOpticalFlow::PRESET_FAST;   break;
        case AD_DIS_MEDIUM: cvPreset = cv::DISOpticalFlow::PRESET_MEDIUM; break;
        case AD_DIS_ULTRAFAST:
        default:            cvPreset = cv::DISOpticalFlow::PRESET_ULTRAFAST; break;
    }

    try {
        ctx->dis = cv::DISOpticalFlow::create(cvPreset);
    } catch (...) {
        delete ctx;
        return nullptr;
    }

    if (ctx->dis.empty()) {
        delete ctx;
        return nullptr;
    }
    return ctx;
}

extern "C" void ad_dis_destroy(void *ctxPtr) {
    delete static_cast<FlowContext *>(ctxPtr);
}

extern "C" AD_FlowResult ad_dis_compute(void *ctxPtr,
                                        const uint8_t *prev, int prevStride,
                                        const uint8_t *next, int nextStride,
                                        int width, int height) {
    // 失败一律返回 valid=0 的零值，绝不抛异常穿过 C 边界（UB）。
    AD_FlowResult result{0.0, 0.0, 0.0, 0};
    if (ctxPtr == nullptr || prev == nullptr || next == nullptr) return result;
    if (width <= 0 || height <= 0) return result;
    // DIS 内部按 4 像素块工作，尺寸太小没有意义
    if (width < 16 || height < 16) return result;

    auto *ctx = static_cast<FlowContext *>(ctxPtr);

    try {
        // 用外部缓冲构造 Mat，零拷贝（OpenCV 不会释放调用方的内存）。
        cv::Mat prevMat(height, width, CV_8UC1, const_cast<uint8_t *>(prev),
                        static_cast<size_t>(prevStride));
        cv::Mat nextMat(height, width, CV_8UC1, const_cast<uint8_t *>(next),
                        static_cast<size_t>(nextStride));

        // ── 内部降采样（默认 1/2，见 kInternalFlowSizeDefault 的长注释）──
        //
        // 用 INTER_AREA：缩放场景下它是抗混叠的面积平均（对缩小是最优插值），
        // 实测精度优于 LINEAR/NEAREST（dx 误差 0.017 / 0.017 / 0.055），
        // 且全链路耗时与三者相同 —— 没有任何理由不用它。
        //
        // ⚠️ 只在「需要缩小」时降采样；放大没有意义（不会更快，只会插值出
        //    假细节），故 target >= width 时保持原图。
        const int target = internalFlowSize();
        cv::Mat smallPrev, smallNext;
        if (target > 0 && target < width) {
            const int workW = target;
            const int workH = std::max(16, target * height / width);  // 保持宽高比
            cv::resize(prevMat, smallPrev, cv::Size(workW, workH), 0, 0, cv::INTER_AREA);
            cv::resize(nextMat, smallNext, cv::Size(workW, workH), 0, 0, cv::INTER_AREA);
        }
        const cv::Mat &disPrev = smallPrev.empty() ? prevMat : smallPrev;
        const cv::Mat &disNext = smallNext.empty() ? nextMat : smallNext;

        // 局部缓冲（**不是**复用 —— 复用已实测否决，见 `FlowContext` 上方长注释）。
        // 每帧新建，但实测同进程配对 A/B 显示这比复用更快：
        //   原版 p50=1.259ms ／ 复用+清零 p50=1.728ms（+0.435ms，92% 样本更慢）。
        // ⚠️ 降采样后这块缓冲从 3.28MB 降到 0.82MB —— 不改变上面那条结论的
        //    方向（复用要每帧 setTo(0) 才等价，代价与分辨率无关），故保持原状，
        //    不借这次改动顺手改成复用。
        cv::Mat flow;
        ctx->dis->calc(disPrev, disNext, flow);
        if (flow.empty() || flow.type() != CV_32FC2) return result;

        // 工作分辨率 → 外部分辨率的换算系数。
        // 这是**契约的核心**：C 接口对外承诺「结果以传入图的像素为单位」，
        // 故内部在 160 算出的流必须 ×4 放大回 640 单位，下游才不会错算 ——
        // `EgoMotionModel` 仍按 640 归一化，两边口径必须一致。
        const double scaleBackX = static_cast<double>(width) / flow.cols;
        const double scaleBackY = static_cast<double>(height) / flow.rows;
        const double scaleBack = (scaleBackX + scaleBackY) / 2.0;

        // ── 全局位移：抽样中位数 ──
        std::vector<float> samplesX;
        std::vector<float> samplesY;
        sampleChannel(flow, 0, samplesX);
        sampleChannel(flow, 1, samplesY);
        if (samplesX.empty() || samplesY.empty()) return result;

        const size_t mid = samplesX.size() / 2;
        std::nth_element(samplesX.begin(), samplesX.begin() + static_cast<ptrdiff_t>(mid), samplesX.end());
        std::nth_element(samplesY.begin(), samplesY.begin() + static_cast<ptrdiff_t>(mid), samplesY.end());
        result.dx = static_cast<double>(samplesX[mid]) * scaleBackX;
        result.dy = static_cast<double>(samplesY[mid]) * scaleBackY;

        // ── 散度：3×3 分块平均流的径向外向分量 ──
        // 自车前进时，地面/建筑纹理从画面中心向外扩散 → 外向分量为正。
        //
        // ⚠️ 投影用的径向单位向量由 **flow 自身尺寸**算出 —— 方向与分辨率
        //    无关（等比缩放不改变方向），故在哪个分辨率上算都对；但**结果**
        //    是像素量，必须 ×scaleBack 回到外部单位，与 dx/dy 口径一致。
        const double centerX = flow.cols / 2.0;
        const double centerY = flow.rows / 2.0;
        double radialSum = 0.0;
        int radialCount = 0;

        for (int by = 0; by < kDivergenceGrid; ++by) {
            for (int bx = 0; bx < kDivergenceGrid; ++bx) {
                const int x0 = bx * flow.cols / kDivergenceGrid;
                const int x1 = (bx + 1) * flow.cols / kDivergenceGrid;
                const int y0 = by * flow.rows / kDivergenceGrid;
                const int y1 = (by + 1) * flow.rows / kDivergenceGrid;

                double sumX = 0.0, sumY = 0.0;
                int n = 0;
                for (int y = y0; y < y1; y += kMedianSampleStep) {
                    const cv::Vec2f *row = flow.ptr<cv::Vec2f>(y);
                    for (int x = x0; x < x1; x += kMedianSampleStep) {
                        sumX += row[x][0];
                        sumY += row[x][1];
                        ++n;
                    }
                }
                if (n == 0) continue;

                const double meanX = sumX / n;
                const double meanY = sumY / n;
                const double px = (x0 + x1) / 2.0 - centerX;
                const double py = (y0 + y1) / 2.0 - centerY;
                const double plen = std::sqrt(px * px + py * py);
                if (plen > 1e-6) {
                    // 投影到径向单位向量：正 = 向外扩散
                    radialSum += (meanX * px + meanY * py) / plen;
                    ++radialCount;
                }
            }
        }
        result.divergence = (radialCount > 0) ? (radialSum / radialCount * scaleBack) : 0.0;
        result.valid = 1;
    } catch (...) {
        // OpenCV 在某些极端尺寸/内部断言下会抛。感知链路必须活着。
        result.valid = 0;
        result.dx = 0.0;
        result.dy = 0.0;
        result.divergence = 0.0;
    }
    return result;
}

// ============================================================================
//  小地图视觉定位（2026-11-20 新增）—— 实现见 flow_bridge.h 声明处
// ============================================================================

namespace {

/// 自适应 CLAHE：低纹理(std<阈值)用大 clip 强化弱特征，否则用常规 clip。
/// 与 Python 验证脚本 /tmp/gmw_our_map.py 完全同口径。
cv::Mat adaptiveCLAHE(const cv::Mat &gray, double lowTextureThresh,
                      double clipNormal, double clipLow) {
    const double stddev = [&]() {
        cv::Scalar mean, sd;
        cv::meanStdDev(gray, mean, sd);
        return sd[0];
    }();
    const double clip = (stddev < lowTextureThresh) ? clipLow : clipNormal;
    cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(clip, cv::Size(8, 8));
    cv::Mat out;
    clahe->apply(gray, out);
    return out;
}

/// 定位器内部状态：持有预处理后的大图 + 圆形 mask + CLAHE 参数。
struct MapLocatorCtx {
    cv::Mat mapPrepared;   // 降采样 + CLAHE 后的大图（灰度）
    int downscale = 4;
};

/// 圆形 mask（半径 = side/2 - 11，与 MaaNTE / gmw 口径一致）。
cv::Mat circleMask(int side) {
    cv::Mat m = cv::Mat::zeros(side, side, CV_8UC1);
    const int radius = side / 2 - 11;
    cv::circle(m, cv::Point(side / 2, side / 2), radius, cv::Scalar(255), -1);
    return m;
}

}  // namespace

extern "C" {

void *ad_maploc_create(const uint8_t *mapGray, int mapStride,
                       int mapW, int mapH, int downscale) {
    try {
        if (!mapGray || mapW <= 0 || mapH <= 0 || mapStride < mapW) return nullptr;
        if (downscale < 1) downscale = 1;
        cv::Mat full(mapH, mapW, CV_8UC1, const_cast<uint8_t *>(mapGray), mapStride);
        cv::Mat small;
        const int sw = std::max(1, mapW / downscale);
        const int sh = std::max(1, mapH / downscale);
        cv::resize(full, small, cv::Size(sw, sh), 0, 0, cv::INTER_AREA);
        // 先完成可能抛异常的预处理再分配 ctx：若 CLAHE 抛出，此前 new 出的
        // ctx 会泄漏（审查 2026-11-20）。调换顺序后异常路径不持有任何资源。
        cv::Mat prepared = adaptiveCLAHE(small, 30.0, 3.0, 6.0);
        MapLocatorCtx *ctx = new MapLocatorCtx();
        ctx->downscale = downscale;
        ctx->mapPrepared = std::move(prepared);
        return ctx;
    } catch (...) {
        return nullptr;
    }
}

void ad_maploc_destroy(void *ctx) {
    delete static_cast<MapLocatorCtx *>(ctx);
}

static AD_MapLocResult maploc_match(const cv::Mat &searchImage,
                                    const uint8_t *miniGray, int miniStride, int miniSide,
                                    double offsetX, double offsetY) {
    AD_MapLocResult r{0, 0, 0, 0};
    try {
        if (!miniGray || miniSide < 16 || miniStride < miniSide) return r;
        cv::Mat mini(miniSide, miniSide, CV_8UC1, const_cast<uint8_t *>(miniGray), miniStride);
        cv::Mat tpl = adaptiveCLAHE(mini, 30.0, 3.0, 6.0);
        cv::Mat mask = circleMask(miniSide);
        // 无纹理模板拒绝：纯色模板的 CCORR 分数天然虚高（恒定值相关≈1），
        // 却不含任何位置信息——返回 valid=0，由调用方按「本帧无定位」处理。
        cv::Scalar tMean, tStd;
        cv::meanStdDev(tpl, tMean, tStd, mask);
        if (tStd[0] < 2.0) return r;
        if (searchImage.cols < miniSide || searchImage.rows < miniSide) return r;
        cv::Mat response;
        cv::matchTemplate(searchImage, tpl, response, cv::TM_CCORR_NORMED, mask);
        // 只需 clamp 后的首个正峰。按行扫描保留 minMaxLoc 的并列顺序，
        // 两侧比较同时排除非有限值和超过误差容限的值。
        float maxV = 0.0f;
        cv::Point maxP;
        for (int y = 0; y < response.rows && maxV < 1.0f; ++y) {
            const float *row = response.ptr<float>(y);
            for (int x = 0; x < response.cols; ++x) {
                const float value = row[x];
                if (value > maxV && value <= 1.0f + 1e-6f) {
                    maxV = std::min(value, 1.0f);
                    maxP = cv::Point(x, y);
                    if (maxV == 1.0f) break;
                }
            }
        }
        if (maxV == 0.0f) return r;
        r.x = offsetX + maxP.x + miniSide * 0.5;
        r.y = offsetY + maxP.y + miniSide * 0.5;
        r.score = maxV;
        r.valid = 1;
    } catch (...) {
        r.valid = 0;
    }
    return r;
}

AD_MapLocResult ad_maploc_global(void *ctx,
                                 const uint8_t *miniGray, int miniStride, int miniSide) {
    AD_MapLocResult r{0, 0, 0, 0};
    if (!ctx) return r;
    MapLocatorCtx *c = static_cast<MapLocatorCtx *>(ctx);
    return maploc_match(c->mapPrepared, miniGray, miniStride, miniSide, 0.0, 0.0);
}

AD_MapLocResult ad_maploc_track(void *ctx,
                                const uint8_t *miniGray, int miniStride, int miniSide,
                                double hintX, double hintY, int window) {
    AD_MapLocResult r{0, 0, 0, 0};
    if (!ctx) return r;
    try {
        MapLocatorCtx *c = static_cast<MapLocatorCtx *>(ctx);
        // hint 必须有限且落在图内，否则回退全局（头文件契约）。
        // 不能先 static_cast<int>：NaN/超范围 double 转 int 是 UB（审查 2026-11-20）。
        const double mapW = c->mapPrepared.cols, mapH = c->mapPrepared.rows;
        if (!std::isfinite(hintX) || !std::isfinite(hintY)
                || hintX < 0.0 || hintY < 0.0 || hintX >= mapW || hintY >= mapH) {
            return ad_maploc_global(ctx, miniGray, miniStride, miniSide);
        }
        if (window < miniSide + 8) window = miniSide + 8;
        const int half = window / 2;
        const int cx = static_cast<int>(hintX), cy = static_cast<int>(hintY);
        const int x0 = std::max(0, cx - half);
        const int y0 = std::max(0, cy - half);
        const int x1 = std::min(c->mapPrepared.cols, cx + half);
        const int y1 = std::min(c->mapPrepared.rows, cy + half);
        if (x1 - x0 < miniSide || y1 - y0 < miniSide) {
            return ad_maploc_global(ctx, miniGray, miniStride, miniSide);
        }
        cv::Mat win = c->mapPrepared(cv::Rect(x0, y0, x1 - x0, y1 - y0));
        return maploc_match(win, miniGray, miniStride, miniSide, x0, y0);
    } catch (...) {
        // ROI 构造/裁剪可能抛（cv::Rect 越界断言），必须兜住，不能崩进程。
        r.valid = 0;
        return r;
    }
}

AD_MapCircleResult ad_maploc_detect_circle(const uint8_t *gray, int stride,
                                            int w, int h,
                                            int regionPreCropped, int frameW) {
    AD_MapCircleResult out{0, 0, 0, 0};
    try {
        if (!gray || w < 64 || h < 64 || stride < w) return out;
        if (frameW <= 0) frameW = w;
        cv::Mat img(h, w, CV_8UC1, const_cast<uint8_t *>(gray), stride);
        // gmw 的做法：先裁固定区域再在区域内检测（全图找会命中道路大弧线，
        // 实测 2940 全图曾误中 r=416 的假圆）。云游戏小地图固定在左上：
        // 实测圆心 ≈(0.102w, 0.172h)、半径 ≈0.058w（2940/1280 两尺度一致）。
        // regionPreCropped=1 时输入已是该区域（CaptureEngine 标定态 ROI 1:1 裁出）。
        cv::Mat crop = img;
        if (!regionPreCropped) {
            const int cropW = w * 30 / 100;   // 左上 30% 宽
            const int cropH = h * 35 / 100;   // 左上 35% 高
            crop = img(cv::Rect(0, 0, cropW, cropH));
        }
        // 半径窗按**整帧宽**比例（0.035~0.07）：实测小地图 r≈0.047~0.058×帧宽
        //（2940 帧 137~170 / 1280 帧 ~74），道路弧线假圆 r≈0.10×帧宽被排除。
        // ⚠️ 必须用 frameW 而不是 w：区域输入时 w 只是裁剪宽，用 w 算窗会把
        //   真圆排在窗外（实测 882 宽区域 maxR=61，检不到 r=204 的真圆）。
        const int minR = std::max(8, frameW * 35 / 1000);
        const int maxR = std::max(minR + 8, frameW * 7 / 100);
        std::vector<cv::Vec3f> circles;
        cv::HoughCircles(crop, circles, cv::HOUGH_GRADIENT, 1.2,
                         (double)std::min(crop.cols, crop.rows) / 2.0,
                         80, 35, minR, maxR);
        if (circles.empty()) return out;
        // 取离预期位置（左上区域内偏中）最近的圆（gmw 同款：closest-to-center）。
        const double ex = crop.cols * 0.34, ey = crop.rows * 0.50;   // ≈(0.102w,0.172h)
        const cv::Vec3f *best = &circles[0];
        double bestD = 1e18;
        for (const auto &c : circles) {
            const double dx = c[0] - ex, dy = c[1] - ey;
            const double d = dx * dx + dy * dy;
            if (d < bestD) { bestD = d; best = &c; }
        }
        out.cx = (*best)[0];
        out.cy = (*best)[1];
        out.r = (*best)[2];
        out.valid = 1;
    } catch (...) {
        out.valid = 0;
    }
    return out;
}

double ad_maploc_measure_span(void *ctx, const uint8_t *miniGray, int side, double x, double y) {
    if (!ctx || !miniGray || side != 150 || !std::isfinite(x) || !std::isfinite(y)) return 0;
    try {
        const cv::Mat &map = static_cast<MapLocatorCtx *>(ctx)->mapPrepared;
        constexpr int window = 256;
        if (x < window / 2 || y < window / 2 ||
            x + window / 2 >= map.cols || y + window / 2 >= map.rows) return 0;
        const cv::Rect rect(static_cast<int>(x) - window / 2, static_cast<int>(y) - window / 2, window, window);
        cv::Mat search;
        cv::resize(map(rect), search, cv::Size(window / 2, window / 2), 0, 0, cv::INTER_AREA);
        const cv::Mat mini(side, side, CV_8UC1, const_cast<uint8_t *>(miniGray));
        const cv::Mat prepared = adaptiveCLAHE(mini, 30.0, 3.0, 6.0);
        const auto score = [&](int span) {
            cv::Mat scaled, response;
            cv::resize(prepared, scaled, cv::Size(span, span), 0, 0, cv::INTER_AREA);
            cv::Mat mask = cv::Mat::zeros(span, span, CV_8UC1);
            cv::circle(mask, cv::Point(span / 2, span / 2), cvRound(64.0 * span / side), cv::Scalar(255), -1);
            cv::Scalar mean, deviation;
            cv::meanStdDev(scaled, mean, deviation, mask);
            if (deviation[0] < 8.0) return 0.0;
            // Remove mean luminance so nearly flat terrain cannot produce a strong peak.
            cv::matchTemplate(search, scaled, response, cv::TM_CCOEFF_NORMED, mask);
            cv::patchNaNs(response, 0.0);
            double best;
            cv::Point peak;
            cv::minMaxLoc(response, nullptr, &best, nullptr, &peak);
            if (!std::isfinite(best) || best > 1.0 + 1e-6 ||
                std::hypot(peak.x + span * 0.5 - search.cols * 0.5,
                           peak.y + span * 0.5 - search.rows * 0.5) > 22.0) return 0.0;
            return best;
        };
        // Step in half-resolution map pixels. Refine around the strongest coarse candidate.
        constexpr int first = 40, last = 100, step = 5;
        double scores[last + 1]{};
        int bestSpan = first;
        for (int span = first; span <= last; span += step) {
            scores[span] = score(span);
            if (scores[span] > scores[bestSpan]) bestSpan = span;
        }
        const int coarse = bestSpan;
        for (int span = std::max(first, coarse - step + 1); span <= std::min(last, coarse + step - 1); ++span) {
            if (span == coarse) continue;
            scores[span] = score(span);
            if (scores[span] > scores[bestSpan]) bestSpan = span;
        }
        double competitor = 0;
        for (int span = first; span <= last; ++span) {
            if (std::abs(span - bestSpan) >= step) competitor = std::max(competitor, scores[span]);
        }
        // Require a clear peak inside the tested zoom interval.
        if (bestSpan == first || bestSpan == last ||
            scores[bestSpan] < 0.60 || scores[bestSpan] - competitor < 0.06) return 0;
        return 2.0 * bestSpan;
    } catch (...) {
        return 0;
    }
}

AD_GuideLineScan ad_guideline_scan(const uint8_t *bgra, int32_t width, int32_t height,
                                  int32_t stride, double ringSq, double radiusSq, uint32_t *hits) {
    AD_GuideLineScan out{};
    out.bestSq = INFINITY;
    if (!bgra || width <= 0 || height <= 0 || width > stride / 4 ||
        height > INT32_MAX / width) return out;
    const double cx = (width - 1) * 0.5;
    const double cy = (height - 1) * 0.5;
    // ⚠️ PCA 采样环（2026-11-21 评审 A 反例修复）：
    // 原实现只排除车心 2 倍 ring，一直采到地图边缘 → 弯道时**远处已偏转的线**
    // 与近端切线混进同一次平均，主轴变成整段圆弧的中点切线。实测反例：
    // 半径 17.9px 的 120° 圆弧，当前切线 0° 时 PCA 主轴偏到 70~82°（置信度还高达 0.94）
    // → 正常跟弯被判「方向不对」扣分。
    // 现在只采**紧邻车心的近段**（ring*2 ~ ring*3.5），该段走向≈车辆当前位置切线。
    // 近段像素少，但小地图引导线宽 2~3px × 约 1.5×ring 弧长仍足够拟合（实测 >30 点）。
    const double shapeRadiusInnerSq = ringSq * 4;
    const double shapeRadiusOuterSq = ringSq * 12.25;
    for (int y = 0; y < height; ++y) {
        const double dy = y - cy;
        const double dySq = dy * dy;
        if (dySq >= radiusSq) continue;
        const double reach = std::sqrt(radiusSq - dySq);
        // Round outwards, then keep the original strict radius checks below.
        const int firstX = static_cast<int>(std::max(0.0, std::floor(cx - reach)));
        const int lastX = static_cast<int>(std::min(width - 1.0, std::ceil(cx + reach)));
        const uint8_t *row = bgra + static_cast<size_t>(y) * stride;
        for (int x = firstX; x <= lastX; ++x) {
            const uint8_t *p = row + x * 4;
            const int b = p[0], g = p[1], r = p[2];
            const bool yellow = r > 140 && g > 100 && b < 110 && r - b > 60 && g - b > 40;
            const bool cream = r > 180 && g > 170 && b > 150 && r >= b - 10;
            if (!yellow && !cream) continue;
            const double dx = x - cx;
            const double dSq = dx * dx + dySq;
            if (!(dSq > ringSq && dSq < radiusSq)) continue;
            if (hits) hits[out.count] = static_cast<uint32_t>(y * width + x);
            ++out.count;
            if (dSq < out.bestSq) {
                out.bestSq = dSq;
                out.bestX = dx;
                out.bestY = dy;
            }
            // 远端方位统计（逆行判定用）：取拟合环之外的更远段。
            if (dSq > shapeRadiusOuterSq) {
                const double len = std::sqrt(dSq);
                if (len > 0) {
                    // 画面坐标 → 世界方位（东=+dx, 北=-dy），单位向量累加。
                    out.farSin += dx / len;
                    out.farCos += -dy / len;
                    ++out.farCount;
                }
            }
            if (dSq <= shapeRadiusInnerSq || dSq > shapeRadiusOuterSq) continue;
            out.sumX += dx;
            out.sumY += dy;
            out.sumXX += dx * dx;
            out.sumYY += dySq;
            out.sumXY += dx * dy;
            ++out.shapeCount;
        }
    }
    return out;
}

}  // extern "C"
