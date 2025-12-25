// swift-tools-version: 6.0
// DevHelperKit - 开发助手插件 (SDK 架构版本)

import PackageDescription

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
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "DevHelperKit",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
