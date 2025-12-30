// swift-tools-version: 6.0
// MemexKit - ETerm Plugin for Claude Session Search

import PackageDescription

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
    dependencies: [
        .package(path: "../../Packages/ETermKit"),
    ],
    targets: [
        .systemLibrary(
            name: "SharedDbFFI",
            path: "Libs/SharedDB"
        ),
        .systemLibrary(
            name: "SessionReaderFFI",
            path: "Libs/SessionReader"
        ),
        .target(
            name: "MemexKit",
            dependencies: [
                "ETermKit",
                "SharedDbFFI",
                "SessionReaderFFI"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "Libs/SharedDB/libclaude_session_db.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs",
                    "Libs/SessionReader/session_reader_ffi",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs/SessionReader"
                ])
            ],
            plugins: [
                .plugin(name: "ValidateManifest", package: "ETermKit")
            ]
        ),
    ]
)
