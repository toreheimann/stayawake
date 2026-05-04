// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "StayAwake",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "StayAwakeLib"),
        .executableTarget(
            name: "StayAwake",
            dependencies: ["StayAwakeLib"]
        ),
        .testTarget(
            name: "StayAwakeTests",
            dependencies: ["StayAwakeLib"]
        ),
    ]
)
