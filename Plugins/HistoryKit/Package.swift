// swift-tools-version: 6.0
// HistoryKit - ETerm Plugin (main mode)

import PackageDescription

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
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "HistoryKit",
            dependencies: ["ETermKit"],
            resources: [
                .copy("../../Resources/manifest.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
