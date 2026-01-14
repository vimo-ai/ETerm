// swift-tools-version: 6.0

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "ClaudeKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClaudeKit",
            type: .dynamic,
            targets: ["ClaudeKit"]
        ),
    ],
    targets: [
        .target(
            name: "ClaudeKit",
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
