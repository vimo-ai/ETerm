// swift-tools-version: 6.0
// ETermKit - ETerm Plugin SDK

import PackageDescription

let package = Package(
    name: "ETermKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ETermKit",
            type: .dynamic,  // 动态库，避免类重复
            targets: ["ETermKit"]
        ),
    ],
    targets: [
        .target(
            name: "ETermKit",
            path: "Sources/ETermKit"
        ),
        .testTarget(
            name: "ETermKitTests",
            dependencies: ["ETermKit"],
            path: "Tests/ETermKitTests"
        ),
    ]
)
