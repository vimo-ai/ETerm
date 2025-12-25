// swift-tools-version: 6.0
// OneLineCommandKit - 一行命令插件 (SDK 架构版本)

import PackageDescription

let package = Package(
    name: "OneLineCommandKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
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
            ]
        ),
    ]
)
