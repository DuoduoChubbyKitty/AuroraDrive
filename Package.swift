// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AuroraDrive",
    platforms: [.macOS(.v26)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AuroraDrive",
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
                "src"
            ],
            sources: [
                "AuroraDriveApp.swift",
                "AutomationPanel.swift",
                "CaptureEngine.swift",
                "ConfidenceEstimator.swift",
                "ControlEngine.swift",
                "CoordinateCapture.swift",
                "DegradeStateMachine.swift",
                "EscapeController.swift",
                "GameMapView.swift",
                "InferenceEngine.swift",
                "KeyboardMonitor.swift",
                "MinimapLocatorView.swift",
                "MinimapTileCache.swift",
                "NetworkLocator.swift",
                "RecordEngine.swift",
                "RuleController.swift",
                "SpeedOCRReader.swift",
                "VisualLocator.swift",
                "YoloEngine.swift",
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
