// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PanelLayoutKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PanelLayoutKit",
            targets: ["PanelLayoutKit"]
        ),
        .library(
            name: "PanelLayoutUI",
            targets: ["PanelLayoutUI"]
        ),
    ],
    targets: [
        .target(
            name: "PanelLayoutKit"
        ),
        .target(
            name: "PanelLayoutUI",
            dependencies: ["PanelLayoutKit"]
        ),
        .testTarget(
            name: "PanelLayoutKitTests",
            dependencies: ["PanelLayoutKit"]
        ),
    ]
)
