// swift-tools-version: 6.0
// WorkspaceKit - ETerm Plugin (main mode)

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
