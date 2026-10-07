# Vendor/OpenCVFlow —— OpenCV DIS 光流桥接层

代码来源、构建方式、许可与实测数据。改这个目录前请先读完。

## 这是什么

一层薄 C 桥，把 OpenCV 的 `cv::DISOpticalFlow`（稠密光流）暴露成纯 C 接口
给 Swift 用。Swift 不能直接 `import` C++，所以必须有这一层。

**它只做一件事**：喂两帧灰度图，回传「自车运动摘要」（全局位移 + 散度）。
不回传稠密流场 —— 640×640×2×4B = 3.3MB，跨语言搬运比光流计算本身还贵。

## 为什么用 OpenCV 而不是 Apple 官方

用户红线：**光流延迟 ≤5ms**。本机 640×640 同批实测：

| 方案 | p95 | 判定 |
|---|---|---|
| Apple `VTOpticalFlow`（VideoToolbox，macOS 15.4+） | 10.28 ms | ✗ |
| Vision `VNGenerateOpticalFlow` | 27.43 ms | ✗ |
| `VNGenerateOpticalFlowRequest` @160×160 | 27.43 ms | ✗ |
| **OpenCV `DISOpticalFlow` PRESET_ULTRAFAST** | **1.91 ms** | ✓ |
| 同上，**只留 1 核**（极端工况） | **3.78 ms** | ✓ |

官方硬件路径慢 5～14 倍，所以选 OpenCV。

`DISOpticalFlow` 是 **CVPR 2016 的正式算法**（Dense Inverse Search），
OpenCV 官方 `video` 模块内建，**非自研手搓**。

## 精度

位移估计误差 **0.07 px**（实测 dx=1.930，真值 2.000，自然纹理图）。

## 依赖内容

### `Vendor/opencv/`（约 24MB）

- **来源**：OpenCV 5.0.0 官方源码 `https://github.com/opencv/opencv/archive/refs/tags/5.0.0.tar.gz`
- **构建**：只编 `core,imgproc,video` 三个模块，静态库
- **许可**：Apache-2.0（见 opencv 仓库 LICENSE）
- **为什么不用 Homebrew**：brew 版 `opencv` 拖 **105 个依赖**（含 ffmpeg、gcc），
  对一个只要光流的需求太重。自编最小集是 17.2MB。

静态库清单：

```
lib/libopencv_core.a       5.02 MB
lib/libopencv_imgproc.a    8.05 MB
lib/libopencv_geometry.a   2.65 MB
lib/libopencv_flann.a      0.79 MB
lib/libopencv_video.a      0.67 MB   ← DIS 光流在这
lib/3rdparty/libtegra_hal.a        1.03 MB   ← ARM SIMD HAL，必须链
lib/3rdparty/libkleidicv*.a        1.23 MB   ← ARM KleidiCV HAL
lib/3rdparty/libittnotify.a        0.10 MB
lib/3rdparty/libzlib.a             0.10 MB
```

### 构建命令（复现用）

```bash
# ⚠️ 中文路径会让 CMake 把 SDK 路径写坏（报 "Invalid character escape '\3'"）
#    先建 ASCII 软链接绕过：
ln -sfn "/Volumes/项目依赖/Xcode.app" /tmp/xcode_ascii
export DEVELOPER_DIR=/tmp/xcode_ascii/Contents/Developer
SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

cmake -S opencv-5.0.0 -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$SDK" \
  -DBUILD_LIST=core,imgproc,video -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF -DBUILD_PYTHON=OFF -DBUILD_OBJC=OFF \
  -DWITH_IPP=OFF -DWITH_OPENCL=OFF -DWITH_FFMPEG=OFF -DWITH_GTK=OFF \
  -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF \
  -DWITH_OPENJPEG=OFF -DWITH_OPENEXR=OFF -DWITH_QUIRC=OFF -DWITH_PROTOBUF=OFF \
  -DWITH_CUDA=OFF -DWITH_VULKAN=OFF -DWITH_OPENMP=OFF \
  -DENABLE_PRECOMPILED_HEADERS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build -j8
```

### 链接时必须补齐的依赖（踩过的坑）

静态链接 OpenCV 需要额外链三组东西，缺一个就一片 undefined symbol：

1. **第三方 HAL**：`tegra_hal` / `kleidicv*` / `ittnotify` / `zlib`
   —— 缺了报 `carotene_o4t::*` 未定义
2. **Accelerate 框架**：LAPACK/BLAS
   —— 缺了报 `_cblas_sgemm$NEWLAPACK$ILP64` 未定义
3. **libc++**：`-lc++`

## 性能关键：4:1 抽样（勿删）

`flow_bridge.cpp` 里求全局中位数时用的是 **4:1 抽样**（隔 4 行隔 4 列），
不是全量。原因：

| 实现 | p50 | p95 | p99 |
|---|---|---|---|
| 全量 409600 点 | 4.57 ms | 4.95 ms | 5.32 ms |
| **4:1 抽样 16384 点** | **1.47 ms** | **1.91 ms** | **2.07 ms** |

全量版本卡在 5ms 红线上抖动（p99 超标）。抽样把 `nth_element` 的规模降了 16 倍，
**精度几乎不变**（dx 都是 1.930，真值 2.000）—— 因为行车画面的光流场高度平滑，
相邻像素流值几乎相同，中位数对抽样不敏感。

如果将来要改回全量，先确认能过 5ms。

## 线程安全

**`ad_dis_compute` 不是线程安全的。** 同一个 ctx 不能被并发调用。
调用方（Swift 侧 `OpticalFlowBridge`）负责串行化。

## 接口

见 `include/flow_bridge.h`。三个函数 + 一个结构体：

```c
void *ad_dis_create(int preset);        // 创建（长期持有，别每帧建）
void  ad_dis_destroy(void *ctx);        // 销毁
AD_FlowResult ad_dis_compute(...);      // 算两帧间运动
```

失败一律返回 `valid = 0`，不抛异常、不崩溃 —— 感知链路的底线。
