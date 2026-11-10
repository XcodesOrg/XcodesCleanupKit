// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XcodesCleanupKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "XcodesCleanupKit", targets: ["XcodesCleanupKit"]),
        .executable(name: "cleanup-benchmark", targets: ["CleanupBenchmark"])
    ],
    targets: [
        .target(name: "XcodesCleanupKit"),
        .executableTarget(name: "CleanupBenchmark", dependencies: ["XcodesCleanupKit"]),
        .testTarget(name: "XcodesCleanupKitTests", dependencies: ["XcodesCleanupKit"])
    ]
)
