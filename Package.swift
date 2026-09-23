// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AuroraDrive",
    platforms: [.macOS(.v26)],
    dependencies: [],
    targets: [
        .target(
            name: "AuroraDriveShared",
            path: "Sources/AuroraDriveShared"
        ),
        .executableTarget(
            name: "AuroraDriveUserAgent",
            dependencies: ["AuroraDriveShared"],
            path: "Sources/AuroraDriveUserAgent"
        ),
        .executableTarget(
            name: "AuroraDrive",
            dependencies: ["AuroraDriveShared"],
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
                "Sources/AuroraDrive/App/GameHUDWindow.swift",
                "Sources/AuroraDrive/Agent/AIAgentPanel.swift",
                "Sources/AuroraDrive/Agent/AgentLoop.swift",
                "Sources/AuroraDrive/Agent/DegradeStateMachine.swift",
                "Sources/AuroraDrive/Agent/LoginAssistant.swift",
                "Sources/AuroraDrive/Agent/RuleController.swift",
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
                "Sources/AuroraDrive/Inference/SpeedOCRReader.swift",
                "Sources/AuroraDrive/Inference/YoloEngine.swift",
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
