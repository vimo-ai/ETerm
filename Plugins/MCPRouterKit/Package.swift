// swift-tools-version: 6.0
// MCPRouterKit - MCP Router 插件

import PackageDescription

let package = Package(
    name: "MCPRouterKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MCPRouterKit",
            type: .dynamic,
            targets: ["MCPRouterKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "MCPRouterKit",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
