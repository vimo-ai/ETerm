// swift-tools-version: 6.0
// MemexKit - ETerm Plugin for Claude Session Search

import PackageDescription

let package = Package(
    name: "MemexKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MemexKit",
            type: .dynamic,
            targets: ["MemexKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "MemexKit",
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
