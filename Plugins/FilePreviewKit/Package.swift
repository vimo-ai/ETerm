// swift-tools-version: 6.0
// FilePreviewKit - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "FilePreviewKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FilePreviewKit",
            type: .dynamic,
            targets: ["FilePreviewKit"]
        ),
    ],
    targets: [
        .target(
            name: "FilePreviewKit",
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
