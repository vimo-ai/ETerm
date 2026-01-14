// swift-tools-version: 6.0
// MemexKit - ETerm Plugin for Claude Session Search

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "MemexKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MemexKit",
            type: .dynamic,
            targets: ["MemexKit"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "SharedDbFFI",
            path: "Libs/SharedDB"
        ),
        .target(
            name: "MemexKit",
            dependencies: [
                "SharedDbFFI"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", etermkitPath])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", etermkitPath, "-framework", "ETermKit",
                    "Libs/SharedDB/libclaude_session_db.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs"
                ])
            ]
        ),
    ]
)
