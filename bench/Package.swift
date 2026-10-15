// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RingBench",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../SI01")],
    targets: [
        .executableTarget(
            name: "ring-bench",
            dependencies: [.product(name: "SI01Core", package: "SI01")]
        ),
    ]
)
