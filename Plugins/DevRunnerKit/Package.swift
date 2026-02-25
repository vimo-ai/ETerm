// swift-tools-version: 6.0
// DevRunnerKit - ETerm Plugin

import PackageDescription

// ETermKit framework 路径（由 build.sh etermkit 产出）
let etermkitPath = "../../Build"

let package = Package(
    name: "DevRunnerKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DevRunnerKit",
            type: .dynamic,
            targets: ["DevRunnerKit"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "DevRunnerFFI",
            path: "Libs/DevRunnerFFI"
        ),
        .target(
            name: "DevRunnerKit",
            dependencies: ["DevRunnerFFI"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", etermkitPath])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", etermkitPath, "-framework", "ETermKit",
                    "Libs/DevRunnerFFI/libdev_runner_app.dylib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Libs/DevRunnerFFI"
                ])
            ]
        ),
    ]
)
