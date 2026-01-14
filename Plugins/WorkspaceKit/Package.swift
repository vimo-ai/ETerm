// swift-tools-version: 6.0
// WorkspaceKit - ETerm Plugin (main mode)

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "WorkspaceKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WorkspaceKit",
            type: .dynamic,
            targets: ["WorkspaceKit"]
        ),
    ],
    targets: [
        .target(
            name: "WorkspaceKit",
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
