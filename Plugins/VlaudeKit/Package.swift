// swift-tools-version: 6.0
// VlaudeKit - ETerm Plugin for Remote Control

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
    ],
    targets: [
        .systemLibrary(
            name: "SharedDbFFI",
            path: "Libs/SharedDB"
        ),
        .target(
            name: "VlaudeKit",
            dependencies: [
                "ETermKit",
                "SharedDbFFI"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "Libs/SharedDB/libclaude_session_db.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs/SharedDB"
                ])
            ],
            plugins: [
                .plugin(name: "ValidateManifest", package: "ETermKit")
            ]
        ),
    ]
)
