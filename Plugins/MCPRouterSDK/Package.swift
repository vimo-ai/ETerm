// swift-tools-version: 6.0
// MCPRouterSDK - MCP Router 插件 (SDK 架构版本)

import PackageDescription

let package = Package(
    name: "MCPRouterSDK",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MCPRouterSDK",
            type: .dynamic,
            targets: ["MCPRouterSDK"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "MCPRouterSDK",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
