// swift-tools-version:6.2
import PackageDescription

/// OpenCV DIS 光流桥接（Vendor/OpenCVFlow）。
///
/// 为什么要有这个 C++ target：
///   Swift 不能直接 `import` C++。OpenCV 是 C++ API，所以用一层薄 C 桥
///   （flow_bridge.cpp）把 `cv::DISOpticalFlow` 包成纯 C 函数，
///   主 target 只依赖桥的头文件，不暴露 C++ 复杂度。
///
/// 为什么用 OpenCV 而不是 Apple 官方（见 Vendor/OpenCVFlow/README.md）：
///   用户红线「光流 ≤5ms」。本机 640×640 同批实测 ——
///     Apple VTOpticalFlow 10.28ms ✗ / Vision 27.43ms ✗ / OpenCV DIS 1.91ms ✓
///   官方硬件路径慢 5～14 倍，所以选 OpenCV。
///
/// ⚠️ 路径必须用绝对路径：`-L` 用相对路径时，SwiftPM 在 link 阶段
///    是按**构建产物目录**解析的，会找不到库（实测报 "library not found"）。
/// ⚠️ 静态库必须是实体文件，不能是符号链接嵌套（实测嵌套链接同样失败）。
///
/// 取包根的方式：SwiftPM 的 manifest 跑在受限沙盒里，**没有 Foundation**
/// （用 `replacingOccurrences` 会报 "value of type 'String' has no member"）。
/// `#filePath` 在 manifest 里展开成 Package.swift 的绝对路径，用纯标准库
/// 的字符串 API 切掉文件名即可。
let packageRoot: String = {
    let manifestPath = "\(#filePath)"
    guard let slash = manifestPath.lastIndex(of: "/") else { return "." }
    return String(manifestPath[manifestPath.startIndex..<slash])
}()
let openCVFlowRoot = "\(packageRoot)/Vendor/opencv"

/// 静态链接 OpenCV 需要补三组依赖，缺一个就一片 undefined symbol：
///   ① 第三方 HAL（tegra_hal/kleidicv/ittnotify/zlib）→ 否则 carotene_o4t::* 未定义
///   ② Accelerate 框架（LAPACK/BLAS）→ 否则 _cblas_sgemm$NEWLAPACK$ILP64 未定义
///   ③ libc++（由 SwiftPM 的 C++ target 自动带上）
let openCVStaticLibraries = [
    "opencv_core",      // 5.02 MB
    "opencv_imgproc",   // 8.05 MB
    "opencv_geometry",  // 2.65 MB
    "opencv_flann",     // 0.79 MB
    "opencv_video",     // 0.67 MB ← DIS 光流在这
    "tegra_hal",        // ARM SIMD HAL（必须链，否则 carotene 符号缺失）
    "kleidicv_hal",
    "kleidicv",
    "kleidicv_thread",
    "ittnotify",
    "zlib"
]

let package = Package(
    name: "AuroraDrive",
    platforms: [.macOS(.v26)],
    dependencies: [],
    targets: [
        .target(
            name: "AuroraDriveShared",
            path: "Sources/AuroraDriveShared"
        ),
        // ── OpenCV DIS 光流桥（纯 C++，暴露 C 接口）──
        .target(
            name: "OpenCVFlow",
            path: "Vendor/OpenCVFlow",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I", "\(openCVFlowRoot)/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "\(openCVFlowRoot)/lib",
                              "-L", "\(openCVFlowRoot)/lib/3rdparty"])
            ] + openCVStaticLibraries.map { .linkedLibrary($0) }
              + [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "AuroraDriveUserAgent",
            dependencies: ["AuroraDriveShared"],
            path: "Sources/AuroraDriveUserAgent"
        ),
        .executableTarget(
            name: "AuroraDrive",
            dependencies: ["AuroraDriveShared", "OpenCVFlow"],
            path: ".",
            exclude: [
                ".build",
                "build",
                "MaaNTE",
                "scripts",
                "docs",
                "tools",
                "checkpoints",
                "data",
                "diag_area",
                "diag_steps",
                "graphflow-out",
                "models",
                "recordings",
                "BidKing_PR434",
                "yolo26s.pt",
                "train.log",
                "photorec.log",
                "photorec.ses",
                // ── OpenCV 光流（2026-09-27 新增）──
                // 主 target 的 path="." 会扫到整个仓库根，这两个目录必须排除：
                //   Vendor/opencv       —— 纯头文件 + 静态库，不是 Swift 源码
                //   Vendor/OpenCVFlow   —— 已由独立的 OpenCVFlow target 编译，
                //                          不排除会被主 target 当源码再编一次（冲突）
                "Vendor/opencv",
                "Vendor/OpenCVFlow",
                "run.sh",
                "test-minimal-plugin.js",
                "README.md",
                "README.en.md",
                "NOTICE",
                "AuroraDriveUI",
                "AuroraDriveUI.app",
                ".workbuddy",
                ".venv-yolo26",
                ".trae",
                ".vscode",
                ".agent-teams",
                ".dsh-computer-use",
                ".dsh-vision-router",
                ".dsh-edit-review.json",
                ".dsh-edit-review-archive.json",
                ".last-build.log",
                ".run-deploy.log",
                ".ui-shot.log",
                ".llm-key-notebook.md",
                "Plugins",
                "src",
                "legacy",
                // ── 另两个 target 的源码（主 target path="." 会扫到，须排除；不影响各自 target 编译）──
                "Sources/AuroraDriveShared",
                "Sources/AuroraDriveUserAgent",
                // ── Vendor/MetalGoose 根层：刻意不编译（仅 Engine/ 下 5 文件进白名单）──
                "Vendor/MetalGoose/AutoUpdater.swift",
                "Vendor/MetalGoose/CaptureSettings.swift",
                "Vendor/MetalGoose/ContentView.swift",
                "Vendor/MetalGoose/GlobalHotkeyManager.swift",
                "Vendor/MetalGoose/GooseEngine.swift",
                "Vendor/MetalGoose/LICENSE",
                "Vendor/MetalGoose/Localizable.xcstrings",
                "Vendor/MetalGoose/MGHUD.swift",
                "Vendor/MetalGoose/MetalGoose.entitlements",
                "Vendor/MetalGoose/MetalGooseApp.swift",
                "Vendor/MetalGoose/NOTICE.md",
                "Vendor/MetalGoose/OverlayWindowManager.swift",
                "Vendor/MetalGoose/README.md",
                "Vendor/MetalGoose/Shaders.metal",
                "Vendor/MetalGoose/WindowCaptureManager.swift",
                // ⚠️ Engine/Shaders.metal 不参与编译，但运行时由 GooseEngine.swift:456 按路径加载，
                //    故仅 exclude（不进白名单），文件本体必须保留在原地。
                "Vendor/MetalGoose/Engine/Shaders.metal",
                // ── Python 字节码缓存 ──
                "__pycache__"
            ],
            sources: [
                "Sources/AuroraDrive/App/AuroraTheme.swift",
                "Sources/AuroraDrive/App/ControlWiring.swift",
                "Sources/AuroraDrive/App/LocateRuntime.swift",
                "Sources/AuroraDrive/App/MapWiring.swift",
                "Sources/AuroraDrive/App/MissionConsole.swift",
                "Sources/AuroraDrive/App/AuroraDriveApp.swift",
                "Sources/AuroraDrive/App/PerfSelfTest.swift",
                // 阶段2（2026-10-01）：真实截图红线自证（--realshot-selftest）。
                // 为什么必须单列：本 target 用**显式 sources 白名单**（不是目录 glob），
                // 新增文件不登记就会 `cannot find type in scope`（已踩过多次）。
                "Sources/AuroraDrive/App/RealShotSelfTest.swift",
                "Sources/AuroraDrive/App/GameHUDWindow.swift",
                "Sources/AuroraDrive/Agent/AIAgentPanel.swift",
                "Sources/AuroraDrive/Agent/AgentLoop.swift",
                "Sources/AuroraDrive/Agent/DegradeStateMachine.swift",
                "Sources/AuroraDrive/Agent/FallbackGuard.swift",
                "Sources/AuroraDrive/Agent/LoginAssistant.swift",
                "Sources/AuroraDrive/Agent/RuleController.swift",
                // 自车框屏蔽（2026-10-02 新增）：第三视角下模型会把玩家自己的车
                // 标成障碍框，这个框进决策层会造成实际危害（见 AuroraDriveApp §5.5）。
                // 按面积判、只作用于决策层；UI 画框走 displayDetections 不受影响。
                "Sources/AuroraDrive/Agent/EgoBoxFilter.swift",
                "Sources/AuroraDrive/Agent/DriveSegmentController.swift",
                "Sources/AuroraDrive/Capture/CaptureEngine.swift",
                "Sources/AuroraDrive/Capture/CoordinateCapture.swift",
                "Sources/AuroraDrive/Capture/RecordEngine.swift",
                "Sources/AuroraDrive/Core/AuroraPaths.swift",
                "Sources/AuroraDrive/Core/BPFSetup.swift",
                "Sources/AuroraDrive/Core/DaemonSetup.swift",
                "Sources/AuroraDrive/Core/EngineClient.swift",
                "Sources/AuroraDrive/Core/EngineMain.swift",
                "Sources/AuroraDrive/Core/GameModeDefender.swift",
                "Sources/AuroraDrive/Core/PrioritySetup.swift",
                "Sources/AuroraDrive/Core/PrivilegePill.swift",
                "Sources/AuroraDrive/Control/ControlEngine.swift",
                "Sources/AuroraDrive/Control/EscapeController.swift",
                "Sources/AuroraDrive/Control/KeyboardMonitor.swift",
                "Sources/AuroraDrive/Control/MouseController.swift",
                "Sources/AuroraDrive/Inference/ConfidenceEstimator.swift",
                "Sources/AuroraDrive/Inference/InferenceEngine.swift",
                "Sources/AuroraDrive/Inference/LaneFallback.swift",
                "Sources/AuroraDrive/Inference/RoadMapPrior.swift",
                "Sources/AuroraDrive/Inference/RoadCornerGuide.swift",
                // 光流接线·路线2（2026-10-01）：自车运动径向模型。
                // 把 `OpticalFlowBridge` 早已算出但零读取方的光流真正接进消费端。
                "Sources/AuroraDrive/Inference/EgoMotionModel.swift",
                "Sources/AuroraDrive/Inference/OpticalFlowBridge.swift",
                "Sources/AuroraDrive/Inference/MotionPredictor.swift",
                "Sources/AuroraDrive/Inference/SpeedOCRReader.swift",
                "Sources/AuroraDrive/Inference/YoloEngine.swift",
                "Sources/AuroraDrive/Inference/YolopxEngine.swift",
                "Sources/AuroraDrive/Locate/MinimapTileCache.swift",
                "Sources/AuroraDrive/Locate/NetworkLocator.swift",
                "Sources/AuroraDrive/Locate/VisualLocator.swift",
                "Vendor/MetalGoose/Engine/GooseEngine.swift",
                "Vendor/MetalGoose/Engine/GooseUpscaler.swift",
                "Vendor/MetalGoose/Engine/Stubs.swift",
                "Vendor/MetalGoose/Engine/WindowCaptureManager.swift",
                "Vendor/MetalGoose/Engine/CaptureSettings.swift"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("NetworkExtension"),
                .linkedFramework("Network"),
                .linkedLibrary("pcap")
            ]
        )
    ]
)
