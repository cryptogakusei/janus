// swift-tools-version: 5.12

import PackageDescription

let package = Package(
    name: "Janus",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "JanusShared", targets: ["JanusShared"]),
        .executable(name: "janus-provider", targets: ["JanusProvider"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.30.6"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", from: "1.8.0"),
    ],
    targets: [
        // Shared library — no platform dependencies, used by all targets
        .target(
            name: "JanusShared",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            path: "Sources/JanusShared"
        ),

        // Mac provider — CLI executable for M1, becomes full app later
        .executableTarget(
            name: "JanusProvider",
            dependencies: [
                "JanusShared",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/JanusProvider"
        ),

        // Tests
        .testTarget(
            name: "JanusSharedTests",
            dependencies: ["JanusShared"],
            path: "Tests/JanusSharedTests"
        ),
    ]
)
