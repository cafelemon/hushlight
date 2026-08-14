// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HushlightMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "HushlightMac", targets: ["HushlightMac"])
    ],
    targets: [
        .executableTarget(
            name: "HushlightMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HushlightMacTests",
            dependencies: ["HushlightMac"]
        )
    ]
)
