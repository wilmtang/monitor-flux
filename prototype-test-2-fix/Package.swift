// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ZoomDesyncPrototype",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ZoomDesyncPrototype", targets: ["ZoomDesyncPrototype"])
    ],
    targets: [
        .executableTarget(
            name: "ZoomDesyncPrototype",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
