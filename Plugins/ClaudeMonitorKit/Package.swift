// swift-tools-version: 6.0
// ClaudeMonitorKit - ETerm Plugin

import PackageDescription

let package = Package(
    name: "ClaudeMonitorKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClaudeMonitorKit",
            type: .dynamic,
            targets: ["ClaudeMonitorKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "ClaudeMonitorKit",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            plugins: [
                .plugin(name: "ValidateManifest", package: "ETermKit")
            ]
        ),
    ]
)
