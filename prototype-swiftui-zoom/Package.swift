// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwiftUIZoomPrototype",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SwiftUIZoomPrototype", targets: ["SwiftUIZoomPrototype"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftUIZoomPrototype",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
