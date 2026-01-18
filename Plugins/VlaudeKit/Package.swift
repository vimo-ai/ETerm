// swift-tools-version: 6.0
// VlaudeKit - ETerm Plugin for Remote Control

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

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
    targets: [
        .systemLibrary(
            name: "SharedDbFFI",
            path: "Libs/SharedDB"
        ),
        .systemLibrary(
            name: "SocketClientFFI",
            path: "Libs/SocketClient"
        ),
        .systemLibrary(
            name: "VlaudeFFI",
            path: "Libs/VlaudeFfi"
        ),
        .target(
            name: "VlaudeKit",
            dependencies: [
                "SharedDbFFI",
                "SocketClientFFI",
                "VlaudeFFI"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", etermkitPath])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", etermkitPath, "-framework", "ETermKit",
                    "-L", "Libs/SharedDB", "-L", "Libs/SocketClient", "-L", "Libs/VlaudeFfi",
                    "Libs/SharedDB/libclaude_session_db.dylib",
                    "Libs/SocketClient/libsocket_client_ffi.dylib",
                    "Libs/VlaudeFfi/libvlaude_ffi.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs/SharedDB",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs/SocketClient",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs/VlaudeFfi"
                ])
            ]
        ),
    ]
)
