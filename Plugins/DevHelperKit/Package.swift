// swift-tools-version: 6.0
// DevHelperKit - ETerm Plugin

import PackageDescription

let package = Package(
    name: "DevHelperKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DevHelperKit",
            type: .dynamic,
            targets: ["DevHelperKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "DevHelperKit",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            plugins: [
                .plugin(name: "ValidateManifest", package: "ETermKit")
            ]
        ),
    ]
)
