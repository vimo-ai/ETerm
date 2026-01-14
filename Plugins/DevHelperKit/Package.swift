// swift-tools-version: 6.0
// DevHelperKit - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "DevHelperKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DevHelperKit",
            type: .dynamic,
            targets: ["DevHelperKit"]
        ),
    ],
    targets: [
        .target(
            name: "DevHelperKit",
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
