// swift-tools-version: 6.0
// __PLUGIN_NAME__ - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "__PLUGIN_NAME__",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "__PLUGIN_NAME__",
            type: .dynamic,
            targets: ["__PLUGIN_NAME__"]
        ),
    ],
    targets: [
        .target(
            name: "__PLUGIN_NAME__",
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
