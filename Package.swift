// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BatteryGlass",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "BatteryGlass",
            path: "Sources/BatteryGlass",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "BatteryGlassTests",
            dependencies: ["BatteryGlass"],
            path: "Tests/BatteryGlassTests"
        )
    ]
)
