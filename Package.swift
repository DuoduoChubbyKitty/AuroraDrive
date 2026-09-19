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
                "Sources/AuroraDrive/App/AuroraDriveApp.swift",
                "Sources/AuroraDrive/App/AutomationPanel.swift",
                "Sources/AuroraDrive/App/GameHUDWindow.swift",
                "Sources/AuroraDrive/App/GameMapView.swift",
                "Sources/AuroraDrive/App/MinimapLocatorView.swift",
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
