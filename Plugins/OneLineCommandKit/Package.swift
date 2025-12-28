// swift-tools-version: 6.0
// OneLineCommandKit - ETerm Plugin (main mode)

import PackageDescription

let package = Package(
    name: "OneLineCommandKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // 动态库：SDK 插件格式
        .library(
            name: "OneLineCommandKit",
            type: .dynamic,
            targets: ["OneLineCommandKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "OneLineCommandKit",
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
