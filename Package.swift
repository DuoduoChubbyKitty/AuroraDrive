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
                "各类研究",
                "MaaNTE",
                "scripts",
                "docs",
                "tools",
                "backups",
                "checkpoints",
                "data",
                "diag_area",
                "diag_steps",
                "graphflow-out",
                "models",
                "recordings",
                "lane_batches.json",
                "untitled.txt",
                "yolo26s.pt",
                "train.log",
                "run.sh",
                "AuroraDriveUI",
                "AuroraDriveUI.app",
                ".workbuddy",
                ".venv-yolo26",
                ".trae",
                ".vscode",
                "Plugins",
                "src",
                "legacy"
            ],
            sources: [
                "Sources/AuroraDrive/AuroraDriveApp.swift",
                "Sources/AuroraDrive/AuroraPaths.swift",
                "Sources/AuroraDrive/AIAgentPanel.swift",
                "Sources/AuroraDrive/AutomationPanel.swift",
                "Sources/AuroraDrive/CaptureEngine.swift",
                "Sources/AuroraDrive/BPFSetup.swift",
                "Sources/AuroraDrive/ConfidenceEstimator.swift",
                "Sources/AuroraDrive/ControlEngine.swift",
                "Sources/AuroraDrive/CoordinateCapture.swift",
                "Sources/AuroraDrive/LoginAssistant.swift",
                "Sources/AuroraDrive/MouseController.swift",
                "Sources/AuroraDrive/DaemonSetup.swift",
                "Sources/AuroraDrive/DegradeStateMachine.swift",
                "Sources/AuroraDrive/EngineMain.swift",
                "Sources/AuroraDrive/EngineClient.swift",
                "Sources/AuroraDrive/EscapeController.swift",
                "Sources/AuroraDrive/GameHUDWindow.swift",
                "Sources/AuroraDrive/GameModeDefender.swift",
                "Sources/AuroraDrive/GameMapView.swift",
                "Sources/AuroraDrive/InferenceEngine.swift",
                "Sources/AuroraDrive/KeyboardMonitor.swift",
                "Sources/AuroraDrive/MinimapLocatorView.swift",
                "Sources/AuroraDrive/MinimapTileCache.swift",
                "Sources/AuroraDrive/NetworkLocator.swift",
                "Sources/AuroraDrive/PrioritySetup.swift",
                "Sources/AuroraDrive/RecordEngine.swift",
                "Sources/AuroraDrive/RuleController.swift",
                "Sources/AuroraDrive/SpeedOCRReader.swift",
                "Sources/AuroraDrive/VisualLocator.swift",
                "Sources/AuroraDrive/YoloEngine.swift",
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
