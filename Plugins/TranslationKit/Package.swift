// swift-tools-version: 6.0
// TranslationKit - ETerm Translation Plugin

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
        .package(path: "../../Packages/ETermKit")
    ],
    targets: [
        .target(
            name: "TranslationKit",
            dependencies: ["ETermKit"]
        ),
        .testTarget(
            name: "TranslationKitTests",
            dependencies: ["TranslationKit"]
        ),
    ]
)
