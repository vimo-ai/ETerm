// swift-tools-version: 6.0
// WritingKit - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "WritingKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WritingKit",
            type: .dynamic,
            targets: ["WritingKit"]
        ),
    ],
    targets: [
        .target(
            name: "WritingKit",
            resources: [
                .copy("../../Resources/manifest.json")
            ],
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
