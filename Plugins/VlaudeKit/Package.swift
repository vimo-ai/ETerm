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
            name: "SessionReaderFFI",
            path: "Libs"
        ),
        .systemLibrary(
            name: "SharedDbFFI",
            path: "Libs/SharedDB"
        ),
        .target(
            name: "VlaudeKit",
            dependencies: [
                "ETermKit",
                "SessionReaderFFI",
                "SharedDbFFI"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "Libs/session_reader_ffi",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs",
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
