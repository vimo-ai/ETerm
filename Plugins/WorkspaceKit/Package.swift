// swift-tools-version: 6.0
// WorkspaceKit - 工作区插件 (SDK 架构版本)

import PackageDescription

let package = Package(
    name: "WorkspaceKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WorkspaceKit",
            type: .dynamic,
            targets: ["WorkspaceKit"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .target(
            name: "WorkspaceKit",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
