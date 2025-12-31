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
        .systemLibrary(
            name: "SocketClientFFI",
            path: "Libs/SocketClient"
        ),
        .target(
            name: "VlaudeKit",
            dependencies: [
                "ETermKit",
                "SharedDbFFI",
                "SocketClientFFI"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "Libs/SharedDB/libclaude_session_db.dylib",
                    "Libs/SocketClient/libsocket_client_ffi.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs/SharedDB",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs/SocketClient"
                ])
            ],
            plugins: [
                .plugin(name: "ValidateManifest", package: "ETermKit")
            ]
        ),
    ]
)
