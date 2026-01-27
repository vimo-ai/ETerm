// swift-tools-version: 6.0

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "AICliKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AICliKit",
            type: .dynamic,
            targets: ["AICliKit"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "SharedDbFFI",
            path: "Libs/SharedDB"
        ),
        .target(
            name: "AICliKit",
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
                    "Libs/SharedDB/libai_cli_session_db.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Libs"
                ])
            ]
        ),
    ]
)
