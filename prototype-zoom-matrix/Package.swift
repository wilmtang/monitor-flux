// swift-tools-version: 6.1
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

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
