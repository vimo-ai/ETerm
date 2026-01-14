// swift-tools-version: 6.0
// TranslationKit - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "TranslationKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TranslationKit",
            type: .dynamic,
            targets: ["TranslationKit"]
        ),
    ],
    targets: [
        .target(
            name: "TranslationKit",
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
