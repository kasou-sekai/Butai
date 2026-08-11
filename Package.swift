// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Butai",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ButaiCore", targets: ["ButaiCore"]),
        .executable(name: "Butai", targets: ["ButaiApp"])
    ],
    targets: [
        .target(name: "ButaiCore"),
        .executableTarget(
            name: "ButaiApp",
            dependencies: ["ButaiCore"]
        ),
        .testTarget(
            name: "ButaiCoreTests",
            dependencies: ["ButaiCore"]
        )
    ]
)
