// swift-tools-version: 6.0

import PackageDescription

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
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "TranslationKit",
            dependencies: ["ETermKit"],
            resources: [
                .copy("../../Resources/manifest.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            plugins: [
                .plugin(name: "ValidateManifest", package: "ETermKit")
            ]
        ),
    ]
)
