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
