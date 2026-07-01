// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ZoomMatrix",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ZoomMatrix",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
