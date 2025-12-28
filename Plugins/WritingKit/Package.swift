// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WritingKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WritingKit",
            type: .dynamic,
            targets: ["WritingKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "WritingKit",
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
