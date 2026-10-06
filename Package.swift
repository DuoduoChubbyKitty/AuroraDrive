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
            // ── 目录级白名单（2026-10-04 P5-A7）──
            // 原来这里是 62 条 exclude + 62 条逐文件 sources 的手工清单，
            // 每加一个文件都要改两处，漏一处就报 cannot find ... in scope
            // 或刷 "found N file(s) which are unhandled"。
            // 现在 sources 只列两个目录，exclude 只留「非源码但必须留在原地」的两个文件：
            //   ① Shaders.metal —— 运行时由 GooseEngine.swift:456 按路径加载，不参与编译
            //   ② CaptureEngine.swift.bak-* —— 历史备份，非源码（待人工清理）
            // ── 仓库根卫生清单（2026-10-04 P5-A7 机器生成）──
            // ⚠️ 本清单**不是**源码登记表 —— 源码登记在下面的 sources（目录级，自动纳入）。
            //    它只是告诉 SwiftPM「这些不是本 target 的输入」，避免 path="." 把整个仓库
            //    （含 .build/ 59 万个条目）当 unhandled 文件报出来。
            //    新增顶层目录/文件后请跑 `bash scripts/check-package-sources.sh` 校验完整性。
            exclude: [
                ".DS_Store",
                ".agent-teams",
                ".build",
                ".dsh-computer-use",
                ".dsh-edit-review-archive.json",
                ".dsh-edit-review.json",
                ".dsh-vision-router",
                ".dsh-workspace-notes",
                ".git",
                ".gitignore",
                ".last-build.log",
                ".llm-key-notebook.md",
                ".run-deploy.log",
                ".swiftpm",
                ".trae",
                ".ui-shot.log",
                ".venv-yolo26",
                ".vscode",
                ".workbuddy",
                "AuroraDrive-交接文案.md",
                "AuroraDrive-项目介绍",
                "AuroraDrive-项目介绍-2",
                "AuroraDriveUI",
                "AuroraDriveUI.app",
                "AuroraDriveUI.bak-20260929-2317",
                "AuroraDriveUI.bak-before-egoflow-1001-1503",
                "AuroraDriveUI.bak-before-flowtest-0148",
                "AuroraDriveUI.bak-before-norecover-1002-1755",
                "AuroraDriveUI.bak-before-stage5-1001-1415",
                "AuroraDriveUI.bak_20260927_125623",
                "AuroraDriveUI.bak_before_ayolom_20261002_215450",
                "AuroraDriveUI.bak_before_picker_20261002_221158",
                "AuroraDriveUI.bak_before_wirefix_20261002_224341",
                "AuroraDriveUI.bak_v2_20260927_140721",
                "AuroraDriveUI.bak_v3_20260927_235219",
                "BidKing_PR434",
                "MaaNTE",
                "NOTICE",
                "Plugins",
                "README.en.md",
                "README.md",
                "Resources",
                "YOLO家族三合一模型清单_2026-09-26.html",
                "__pycache__",
                "_bak_binaries",
                "attachments-import",
                "build",
                "checkpoints",
                "data",
                "default.metallib",
                "desktop-out",
                "diag_area",
                "diag_steps",
                "docs",
                "graphflow-out",
                "iwY1tpok53eCTKn5-grok-workspace",
                "legacy",
                "models",
                "photorec.log",
                "photorec.ses",
                "ppt",
                "print",
                "recordings",
                "run.sh",
                "scripts",
                "src",
                "test-minimal-plugin.js",
                "tools",
                "train.log",
                "yolo26s.pt",
                "交接文档-异环外置盘.md",
                "目标模式文档-自动驾驶修复.md",
                "Sources/AuroraDriveShared",
                "Sources/AuroraDriveUserAgent",
                "Vendor/OpenCVFlow",
                "Vendor/opencv",
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
                "Vendor/MetalGoose/Engine/Shaders.metal",
                "Sources/AuroraDrive/Capture/CaptureEngine.swift.bak-20260930",
            ],
            // 目录级白名单：新增 .swift 自动纳入，不必再登记。
            sources: [
                "Sources/AuroraDrive",
                "Vendor/MetalGoose/Engine",
            ],
            // ⚠️ 必须保留（2026-10-04 事故记录）：
            //    文件头是 swift-tools-version:6.2，**不显式指定语言模式时默认就是
            //    Swift 6 严格并发模式**。本仓尚未迁移到 Swift 6 并发模型，
            //    去掉这个块会让全仓 56 个文件的 `static let shared` 全部报
            //    #MutableGlobalVariable / "main actor-isolated default value"，
            //    一次构建 500+ error、全队构建红。
            //    我在 P5-A7 改目录白名单时曾用脚本替换 `sources:` 块，正则的
            //    收尾匹配误吞了本块 —— 恢复时请连注释一起保留。
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
