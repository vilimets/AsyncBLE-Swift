// swift-tools-version: 5.9

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "AsyncBLE",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "AsyncBLE", targets: ["AsyncBLE"])
    ],
    targets: [
        .target(
            name: "AsyncBLE",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "AsyncBLETests",
            dependencies: ["AsyncBLE"],
            swiftSettings: strictConcurrency
        )
    ]
)
