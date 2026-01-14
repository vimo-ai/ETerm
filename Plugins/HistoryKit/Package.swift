// swift-tools-version: 6.0
// HistoryKit - ETerm Plugin (main mode)

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "HistoryKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "HistoryKit",
            type: .dynamic,
            targets: ["HistoryKit"]
        ),
    ],
    targets: [
        .target(
            name: "HistoryKit",
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
