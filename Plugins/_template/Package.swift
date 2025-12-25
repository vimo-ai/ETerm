// swift-tools-version: 6.0
// __PLUGIN_NAME__ - ETerm Plugin

import PackageDescription

let package = Package(
    name: "__PLUGIN_NAME__",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "__PLUGIN_NAME__",
            type: .dynamic,
            targets: ["__PLUGIN_NAME__"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "__PLUGIN_NAME__",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
