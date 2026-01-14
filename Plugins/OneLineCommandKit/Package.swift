// swift-tools-version: 6.0
// OneLineCommandKit - ETerm Plugin (main mode)

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

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
    targets: [
        .target(
            name: "OneLineCommandKit",
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
