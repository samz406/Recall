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
        .target(
            name: "RecallKit",
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
