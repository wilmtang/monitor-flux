// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MonitorFlux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MonitorFlux", targets: ["MonitorFlux"])
    ],
    targets: [
        .executableTarget(
            name: "MonitorFlux",
            path: "Sources/MonitorFlux",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "MonitorFluxTests",
            dependencies: ["MonitorFlux"],
            path: "Tests/MonitorFluxTests"
        )
    ]
)
