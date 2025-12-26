// swift-tools-version: 6.0
// MCPRouterKit - ETerm Plugin

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
        .systemLibrary(
            name: "MCPRouterCore",
            path: "Lib"
        ),
        .target(
            name: "MCPRouterKit",
            dependencies: [
                "ETermKit",
                "MCPRouterCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
