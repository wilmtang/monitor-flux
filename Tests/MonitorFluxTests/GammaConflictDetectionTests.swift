// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics
import XCTest
@testable import MonitorFlux

final class GammaConflictDetectionTests: XCTestCase {
    func testIdenticalChannelsDoNotDiffer() {
        let channel: [CGGammaValue] = [0, 0.25, 0.5, 0.75, 1.0]
        XCTAssertFalse(GammaTemperatureService.channelsDiffer(channel, channel))
    }

    func testTinyDifferenceWithinToleranceIsIgnored() {
        // The LUT quantizes a table we wrote; that small drift must not be flagged.
        let a: [CGGammaValue] = [0, 0.25, 0.5, 0.75, 1.0]
        let b: [CGGammaValue] = [0.004, 0.251, 0.5, 0.748, 0.996]
        XCTAssertFalse(GammaTemperatureService.channelsDiffer(a, b))
    }

    func testLargeForeignWarmIsDetected() {
        // Another app pulling the blue/high end down well past the tolerance is a conflict.
        let a: [CGGammaValue] = [0, 0.25, 0.5, 0.75, 1.0]
        let b: [CGGammaValue] = [0, 0.25, 0.5, 0.6, 0.7]
        XCTAssertTrue(GammaTemperatureService.channelsDiffer(a, b))
    }

    func testEmptyChannelsDoNotDiffer() {
        XCTAssertFalse(GammaTemperatureService.channelsDiffer([], []))
    }

    func testToleranceBoundaryIsExclusive() {
        let a: [CGGammaValue] = [0.5]
        XCTAssertFalse(GammaTemperatureService.channelsDiffer(a, [0.52], tolerance: 0.02)) // == tolerance, not >
        XCTAssertTrue(GammaTemperatureService.channelsDiffer(a, [0.531], tolerance: 0.02))  // > tolerance
    }

    func testNamesMatchesKnownGammaAppsCaseInsensitively() {
        let names = GammaConflictApp.names(forRunningBundleIDs: [
            "com.apple.finder", "ORG.HERF.Flux", "fyi.lunar.Lunar",
        ])
        XCTAssertEqual(names, ["f.lux", "Lunar"]) // de-duplicated, in known order
    }

    func testNamesDeduplicatesAppWithMultipleBundleIDs() {
        let names = GammaConflictApp.names(forRunningBundleIDs: [
            "me.guillaumeb.MonitorControl", "app.monitorcontrol.MonitorControl",
        ])
        XCTAssertEqual(names, ["MonitorControl"]) // both legacy + current id → one name
    }

    func testNamesEmptyWhenNoKnownGammaAppRunning() {
        XCTAssertTrue(GammaConflictApp.names(forRunningBundleIDs: ["com.apple.Safari"]).isEmpty)
    }
}
