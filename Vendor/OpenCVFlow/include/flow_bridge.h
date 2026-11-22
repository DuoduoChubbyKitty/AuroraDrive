//
//  flow_bridge.h —— OpenCV DIS 稠密光流的纯 C 接口
//
//  为什么存在这一层：
//    Swift 不能直接 import C++。OpenCV 是 C++ API，所以用一层薄 C 桥把
//    `cv::DISOpticalFlow` 包成纯 C 函数，Swift 侧只依赖 `flow_bridge.h`，
//    不必让整个构建暴露在 C++ 头文件的复杂度下。
//
//  为什么选 DIS 而不是 Apple 官方：
//    本机实测（640×640，同批 ABBA）
//      · Apple VTOpticalFlow（VideoToolbox 硬件）      10.28 ms   ✗ 超 5ms 预算
//      · Vision VNGenerateOpticalFlow                   27.43 ms   ✗
//      · OpenCV DISOpticalFlow PRESET_ULTRAFAST          1.91 ms   ✓
//      · OpenCV DISOpticalFlow PRESET_ULTRAFAST（单核）  3.78 ms   ✓
//    用户红线是「光流 ≤5ms」，所以选 OpenCV。DIS 是 CVPR 2016 的正式算法
//    （Dense Inverse Search），OpenCV 官方 `video` 模块，非自研手搓。
//
//  精度：位移估计误差 0.07px（dx=1.930 对真值 2.000）。
//
//  线程安全：`ad_dis_compute` **不是**线程安全的。同一个 ctx 不能被并发调用。
//            调用方（Swift 侧 OpticalFlowBridge）负责串行化。
//

#ifndef AURORA_FLOW_BRIDGE_H
#define AURORA_FLOW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// DIS 预设档位。数值与 OpenCV `cv::DISOpticalFlow::PRESET_*` 对齐。
///
/// 实测 640×640 全核 p95：
///   - `AD_DIS_ULTRAFAST` (0) → 2.73 ms   ← 生产用这个
///   - `AD_DIS_FAST`      (1) → 7.61 ms   ✗ 超预算
///   - `AD_DIS_MEDIUM`    (2) → 27.9 ms   ✗ 超预算
typedef enum {
    AD_DIS_ULTRAFAST = 0,
    AD_DIS_FAST      = 1,
    AD_DIS_MEDIUM    = 2
} AD_DISPreset;

/// 一帧光流解算出的运动摘要。
///
/// 只回传「车辆运动」层面的几个标量，不回传整张稠密流场 —— 稠密流场是
/// 640×640×2×4B = 3.3MB，跨语言边界搬运的代价比光流本身还大。调用方
/// （MotionPredictor）需要的是全局位移与散度，这几个标量就够。
typedef struct {
    /// 全局中位水平流（像素）。正 = 画面内容向右移动 = 自车向左。
    double dx;

    /// 全局中位垂直流（像素）。正 = 画面内容向下移动。
    ///
    /// ⚠️ 自车前进时，地面纹理在画面里是**向下**扩散的（远小近大），
    ///    所以前进对应 `dy > 0` 且 `divergence > 0`。
    double dy;

    /// 径向外向散度（像素）。
    ///   > 0 → 画面内容从中心向外扩张 → **自车前进**
    ///   < 0 → 内容向中心收缩       → **自车后退**
    ///   ≈ 0 → 纯平移或静止
    ///
    /// 计算方式：把画面切成 3×3 块，每块算平均流，投影到「由画面中心指向
    /// 该块中心」的单位向量上，取符号平均。这比直接算流场散度对噪声鲁棒得多。
    double divergence;

    /// 有效标志。1 = 本次解算成功且结果可用；0 = 失败（ctx 空 / 尺寸非法 /
    /// OpenCV 抛异常），此时其余三个字段全为 0，调用方应视为「本帧无光流」。
    ///
    /// fail-open 语义：`valid == 0` 时调用方必须退化为「不做运动外推」，
    /// 而不是拿 0 值当成「静止」去用。
    int32_t valid;
} AD_FlowResult;

/// 创建 DIS 光流估计器。
///
/// - Parameter preset: 见 `AD_DISPreset`。生产用 `AD_DIS_ULTRAFAST`。
/// - Returns: 不透明句柄；失败返回 NULL。用完必须 `ad_dis_destroy`。
///
/// 内部会分配 OpenCV 的工作缓冲。建议长期持有（一个引擎一个 ctx），
/// 不要每帧创建 —— 创建成本约 1ms 量级，而单帧解算只要 1.9ms。
void *ad_dis_create(int preset);

/// 销毁估计器并释放内部缓冲。传 NULL 安全。
void ad_dis_destroy(void *ctx);

// ============================================================================
//  小地图视觉定位（2026-11-20 新增）
// ============================================================================
//  用途：云游戏只有视频流、拿不到网络坐标，用「游戏内圆形小地图」在
//  「游戏世界大地图」上做模板匹配，反推玩家在大地图的像素坐标。
//
//  算法（已在 Python 对真实云游戏截图验证：24 SIFT 内点、坐标交叉一致）：
//    · 大图/小图都做自适应 CLAHE（std<30 用 clip 6.0，否则 clip 3.0，8×8 网格）
//    · 小地图模板用**圆形 mask** + TM_CCORR_NORMED 匹配（实测只有带 mask 才准）
//    · 首次全局搜（~360ms 一次性），之后局部窗口跟踪（400² ~3.5ms/帧，<7ms 预算）
//
//  为什么放在 C 层：Swift 不能直接调 OpenCV；且 matchTemplate 是大矩阵运算，
//  跨语言搬运像素代价高。这里只回传坐标+分数几个标量。
//
//  线程安全：每个 ctx 只能被单线程调用（内部持有预处理后的大图）；调用方串行化。

/// 定位结果。
typedef struct {
    /// 大图上的匹配中心 x 坐标。⚠️ **降采样图像素**（如 downscale=4 时是
    /// 13056/4=3264 宽的图），需要原图坐标时由调用方乘 downscale。
    double x;
    /// 大图上的匹配中心 y 坐标（降采样图像素，同 x 的口径）。
    double y;
    /// 匹配分数 [0,1]，越高越可信。
    double score;
    /// 有效标志。1=成功；0=失败（ctx 空/输入非法/OpenCV 异常），此时其余字段为 0。
    int32_t valid;
} AD_MapLocResult;

/// 创建地图定位器：对大图做降采样 + 自适应 CLAHE 预处理，常驻持有。
///
/// - Parameters:
///   - mapGray:    大地图灰度图首地址（8-bit 单通道），如 bigworldmap-13056.jpg。
///   - mapStride:  大图行跨度（字节）。
///   - mapW/mapH:  大图像素宽高。
///   - downscale:  降采样倍数（生产用 4：13056→3264，兼顾精度与速度）。
/// - Returns: 不透明句柄；失败返回 NULL。用完必须 `ad_maploc_destroy`。
void *ad_maploc_create(const uint8_t *mapGray, int mapStride,
                       int mapW, int mapH, int downscale);

/// 销毁定位器。传 NULL 安全。
void ad_maploc_destroy(void *ctx);

/// 一次性**全局**定位（首次启动 / 跟丢后重定位）。
/// 在整个预处理大图上做带圆形 mask 的匹配，慢（~360ms），不要每帧调用。
///
/// - Parameters:
///   - ctx:        `ad_maploc_create` 句柄。
///   - miniGray:   小地图灰度图首地址（150×150，圆形，圆外可任意）。
///   - miniStride: 小地图行跨度。
///   - miniSide:   小地图边长（生产 150）。
/// - Returns: 大图坐标（**降采样后**坐标系，乘 downscale 得原图坐标）。
AD_MapLocResult ad_maploc_global(void *ctx,
                                 const uint8_t *miniGray, int miniStride, int miniSide);

/// 每帧**局部**跟踪（快，~3.5ms）。以 hint 为中心裁一块局部窗口匹配。
///
/// - Parameters:
///   - ctx:        `ad_maploc_create` 句柄。
///   - miniGray/miniStride/miniSide: 同上。
///   - hintX/hintY: 上一帧位置（降采样后坐标系）。
///   - window:     局部窗口边长（生产 400，越大越慢）。
/// - Returns: 大图坐标（降采样后坐标系）。hint 非法/越界时退化为全局搜索。
AD_MapLocResult ad_maploc_track(void *ctx,
                                const uint8_t *miniGray, int miniStride, int miniSide,
                                double hintX, double hintY, int window);

/// Overlay-only zoom calibration near a fixed-scale localization. Returns the span
/// of the source ROI in downsampled map pixels, or zero for a weak/ambiguous match.
/// May run alongside tracking while the caller retains the read-only map context.
double ad_maploc_measure_span(void *ctx, const uint8_t *miniGray, int side, double x, double y);

/// 圆形小地图检测结果（整帧像素坐标）。
typedef struct {
    double cx;   ///< 圆心 x
    double cy;   ///< 圆心 y
    double r;    ///< 半径
    int32_t valid;
} AD_MapCircleResult;

/// 在灰度图里检测圆形小地图（HoughCircles，取最靠预期位置的圆）。
/// 用途：视觉模式启动期的自动标定（免手工 ROI）。无状态、线程安全，
/// 不需要定位器实例。
/// - regionPreCropped=0：输入是**整帧** → 内部先裁左上 30%×35% 区域再检测；
/// - regionPreCropped=1：输入**已是**左上区域（由 CaptureEngine 的标定态 ROI
///   裁出）→ 全图直接检测，圆心/半径即整帧原生像素坐标（ROI 拷贝是 1:1）。
/// - frameW：**整帧**像素宽（半径窗按它缩放；区域输入时 w 只是裁剪宽，
///   用 w 算半径窗会把真圆排除在窗外——实测 882 宽区域 maxR=61 检不到 r=204）。
///   无效值(≤0)时回退用 w。
AD_MapCircleResult ad_maploc_detect_circle(const uint8_t *gray, int stride,
                                            int w, int h,
                                            int regionPreCropped, int frameW);

typedef struct {
    /// 远端方位统计：只累计「距车心 > shapeRadiusOuter 之外」的像素，
    /// 其单位向量按 sin/cos 累加 → atan2 得该路段延伸方向（带正反歧义）。
    double farSin, farCos;
    int32_t farCount;
    double bestSq, bestX, bestY;
    double sumX, sumY, sumXX, sumYY, sumXY;
    int32_t count, shapeCount;
} AD_GuideLineScan;

/// Scan BGRA in row order. Optional hits must have room for width * height row-major indices.
AD_GuideLineScan ad_guideline_scan(const uint8_t *bgra, int32_t width, int32_t height,
                                  int32_t stride, double ringSq, double radiusSq, uint32_t *hits);

/// 计算两帧灰度图之间的运动。
///
/// - Parameters:
///   - ctx:        `ad_dis_create` 返回的句柄。
///   - prev:       前一帧灰度图首地址（8-bit 单通道）。
///   - prevStride: 前一帧行跨度（字节）。**不是**宽度 —— 相机缓冲常有行对齐填充。
///   - next:       当前帧灰度图首地址。
///   - nextStride: 当前帧行跨度。
///   - width:      图像宽（像素）。
///   - height:     图像高（像素）。
/// - Returns: 运动摘要。`valid == 0` 表示失败。
///
/// 宽高必须一致且 > 0；两帧尺寸必须相同。任何非法输入返回 `valid = 0`，
/// 不抛异常、不崩溃 —— 这是感知链路的底线要求。
AD_FlowResult ad_dis_compute(void *ctx,
                             const uint8_t *prev, int prevStride,
                             const uint8_t *next, int nextStride,
                             int width, int height);

#ifdef __cplusplus
}
#endif

#endif // AURORA_FLOW_BRIDGE_H
