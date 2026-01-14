// swift-tools-version: 6.0
// ClaudeMonitorKit - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

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
    targets: [
        .target(
            name: "ClaudeMonitorKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", etermkitPath])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", etermkitPath, "-framework", "ETermKit"])
            ]
        ),
    ]
)
