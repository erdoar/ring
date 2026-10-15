// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SI01",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SI01Core", targets: ["SI01Core"]),
        .executable(name: "SI01", targets: ["SI01"]),
    ],
    targets: [
        .target(name: "KernelStore", publicHeadersPath: "include"),
        .target(name: "SI01Core", dependencies: ["KernelStore"]),
        .executableTarget(name: "SI01", dependencies: ["SI01Core"]),
        .testTarget(name: "SI01CoreTests", dependencies: ["SI01Core", "KernelStore"]),
    ]
)
