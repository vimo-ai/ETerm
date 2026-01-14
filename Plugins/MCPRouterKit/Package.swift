// swift-tools-version: 6.0
// MCPRouterKit - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

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
    targets: [
        .systemLibrary(
            name: "MCPRouterCore",
            path: "Lib"
        ),
        .target(
            name: "MCPRouterKit",
            dependencies: [
                "MCPRouterCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", etermkitPath])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", etermkitPath, "-framework", "ETermKit",
                    "Lib/libmcp_router_core.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Lib"
                ])
            ]
        ),
    ]
)
