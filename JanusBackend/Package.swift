// swift-tools-version: 5.12

import PackageDescription

let package = Package(
    name: "JanusBackend",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(path: ".."),  // JanusShared from parent package
    ],
    targets: [
        .executableTarget(
            name: "JanusBackend",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "JanusShared", package: "Janus"),
            ],
            path: "Sources/JanusBackend"
        ),
    ]
)
