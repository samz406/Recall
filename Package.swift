// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Recall",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RecallKit", targets: ["RecallKit"]),
        .executable(name: "RecallApp", targets: ["RecallApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"])
            ]
        ),
        .target(
            name: "RecallKit",
            dependencies: ["CSQLite"],
            path: "Sources/RecallKit"
        ),
        .executableTarget(
            name: "RecallApp",
            dependencies: ["RecallKit"],
            path: "Sources/RecallApp"
        ),
        .executableTarget(
            name: "RecallVerifier",
            dependencies: ["RecallKit"],
            path: "Verification"
        )
    ]
)
