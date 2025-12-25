// swift-tools-version: 6.0
// VlaudeKit - Vlaude 远程控制插件 (SDK 架构版本)

import PackageDescription

let package = Package(
    name: "VlaudeKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VlaudeKit",
            type: .dynamic,
            targets: ["VlaudeKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.0.0"),
    ],
    targets: [
        .target(
            name: "VlaudeKit",
            dependencies: [
                "ETermKit",
                .product(name: "SocketIO", package: "socket.io-client-swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
