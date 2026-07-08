// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

/// `BuiltInDimming.normalized` is called only for a built-in whose slider drives the real
/// backlight (`.hardwareOnly`) — these tests cover that documented contract.
final class BuiltInDimmingTests: XCTestCase {
    func testLegacyAutomaticFoldsIntoHardware() {
        var preferences = DisplayPreferences()
        preferences.dimmingMode = .automatic

        let normalization = BuiltInDimming.normalized(preferences)

        XCTAssertEqual(normalization?.preferences.dimmingMode, .hardware)
        XCTAssertEqual(normalization?.clearedGamma, false)
    }

    func testStaleSoftwareDimIsClearedAndFlagged() {
        // A pre-backlight-API build left a sub-100 gamma; once the backlight is controllable
        // that residue would keep the screen dim with no slider recourse.
        var preferences = DisplayPreferences()
        preferences.gammaBrightness = 60

        let normalization = BuiltInDimming.normalized(preferences)

        XCTAssertEqual(normalization?.preferences.gammaBrightness, 100)
        XCTAssertEqual(normalization?.clearedGamma, true)
    }

    func testBothLegacyArtifactsNormalizeTogether() {
        var preferences = DisplayPreferences()
        preferences.dimmingMode = .automatic
        preferences.gammaBrightness = 40

        let normalization = BuiltInDimming.normalized(preferences)

        XCTAssertEqual(normalization?.preferences.dimmingMode, .hardware)
        XCTAssertEqual(normalization?.preferences.gammaBrightness, 100)
        XCTAssertEqual(normalization?.clearedGamma, true)
    }

    func testCleanStateNeedsNoNormalization() {
        var hardware = DisplayPreferences()
        hardware.dimmingMode = .hardware
        XCTAssertNil(BuiltInDimming.normalized(hardware))
        XCTAssertNil(BuiltInDimming.normalized(DisplayPreferences()))
    }

    func testAdvancedBoostAbove100IsPreserved() {
        // The >100 boost is deliberate (a dim panel), not a stale dim — leave it alone.
        var preferences = DisplayPreferences()
        preferences.gammaBrightness = 130
        XCTAssertNil(BuiltInDimming.normalized(preferences))
    }
}
