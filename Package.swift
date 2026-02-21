// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SimpleConfig",
    products: [
        .library(
            name: "SimpleConfig",
            targets: ["SimpleConfig"]
        ),
    ],
    targets: [
        .target(
            name: "SimpleConfig"
        ),
        .testTarget(
            name: "SimpleConfigTests",
            dependencies: ["SimpleConfig"]
        ),
    ]
)
