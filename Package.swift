// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AuroraDrive",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "Plugins/PostBuildSign")
    ],
    targets: [
        .executableTarget(
            name: "AuroraDrive",
            path: ".",
            exclude: [
                ".build",
                "上一版的失败代码",
                "docs",
                "tools",
                ".workbuddy",
                ".venv-yolo26",
                "Plugins"
            ],
            sources: [
                "AuroraDriveApp.swift",
                "AutomationPanel.swift",
                "CaptureEngine.swift",
                "ConfidenceEstimator.swift",
                "ControlEngine.swift",
                "DegradeStateMachine.swift",
                "EscapeController.swift",
                "GameMapView.swift",
                "InferenceEngine.swift",
                "KeyboardMonitor.swift",
                "MinimapTileCache.swift",
                "NetworkPacketCapture.swift",
                "RecordEngine.swift",
                "RuleController.swift",
                "SpeedOCRReader.swift",
                "YoloEngine.swift",
                "Vendor/MetalGoose/Engine/GooseEngine.swift",
                "Vendor/MetalGoose/Engine/GooseUpscaler.swift",
                "Vendor/MetalGoose/Engine/Stubs.swift",
                "Vendor/MetalGoose/Engine/WindowCaptureManager.swift",
                "Vendor/MetalGoose/Engine/CaptureSettings.swift"
            ],
            linkerSettings: [
                .linkedFramework("NetworkExtension"),
                .linkedFramework("Network"),
                .linkedLibrary("pcap")
            ],
            plugins: [
                .plugin(name: "PostBuildSign", package: "PostBuildSign")
            ]
        )
    ]
)
