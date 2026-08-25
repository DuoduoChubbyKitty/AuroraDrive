// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PostBuildSign",
    platforms: [.macOS(.v13)],
    products: [
        .plugin(name: "PostBuildSign", targets: ["PostBuildSignPlugin"])
    ],
    targets: [
        .plugin(
            name: "PostBuildSignPlugin",
            capability: .buildTool(),
            dependencies: []
        )
    ]
)