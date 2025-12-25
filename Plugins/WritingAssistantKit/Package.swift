// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WritingAssistantKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WritingAssistantKit",
            type: .dynamic,
            targets: ["WritingAssistantKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "WritingAssistantKit",
            dependencies: ["ETermKit"]
        ),
        .testTarget(
            name: "WritingAssistantKitTests",
            dependencies: ["WritingAssistantKit"]
        ),
    ]
)
