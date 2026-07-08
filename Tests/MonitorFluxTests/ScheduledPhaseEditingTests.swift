// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

/// The per-display phase getters/setters behind the popup's "re-level the active phase while
/// scheduled" behavior (the brightness/contrast analogue of `AppPreferences.temperature(for:)`).
final class ScheduledPhaseEditingTests: XCTestCase {
    func testScheduledBrightnessReadsPerPhaseTargets() {
        var preferences = DisplayPreferences()
        preferences.dayBrightness = 90
        preferences.sunsetBrightness = 60
        preferences.nightBrightness = 20

        XCTAssertEqual(preferences.scheduledBrightness(for: .daytime), 90)
        XCTAssertEqual(preferences.scheduledBrightness(for: .sunset), 60)
        XCTAssertEqual(preferences.scheduledBrightness(for: .bedtime), 20)
    }

    func testSetScheduledBrightnessWritesTheMatchingPhaseOnly() {
        var preferences = DisplayPreferences()
        preferences.setScheduledBrightness(33, for: .sunset)

        XCTAssertEqual(preferences.sunsetBrightness, 33)
        XCTAssertEqual(preferences.dayBrightness, DisplayPreferences().dayBrightness, "other phases untouched")
        XCTAssertEqual(preferences.nightBrightness, DisplayPreferences().nightBrightness)
    }

    func testScheduledContrastReadsPerPhaseTargets() {
        var preferences = DisplayPreferences()
        preferences.dayContrast = 80
        preferences.sunsetContrast = 55
        preferences.nightContrast = 40

        XCTAssertEqual(preferences.scheduledContrast(for: .daytime), 80)
        XCTAssertEqual(preferences.scheduledContrast(for: .sunset), 55)
        XCTAssertEqual(preferences.scheduledContrast(for: .bedtime), 40)
    }

    func testSetScheduledContrastWritesTheMatchingPhaseOnly() {
        var preferences = DisplayPreferences()
        preferences.setScheduledContrast(48, for: .bedtime)

        XCTAssertEqual(preferences.nightContrast, 48)
        XCTAssertEqual(preferences.dayContrast, DisplayPreferences().dayContrast)
    }

    func testSettersClampToHardwarePercent() {
        var preferences = DisplayPreferences()
        preferences.setScheduledBrightness(999, for: .daytime)
        preferences.setScheduledContrast(-10, for: .daytime)

        XCTAssertEqual(preferences.dayBrightness, ControlRanges.hardwarePercent.upperBound)
        XCTAssertEqual(preferences.dayContrast, ControlRanges.hardwarePercent.lowerBound)
    }

    /// The round-trip the popup relies on: read the active phase, write a dragged value back to
    /// it, read it again — so the thumb tracks 1:1 (no feedback through the applied value).
    func testPhaseRoundTrip() {
        var preferences = DisplayPreferences()
        for phase in ColorPhase.allCases {
            preferences.setScheduledBrightness(42, for: phase)
            XCTAssertEqual(preferences.scheduledBrightness(for: phase), 42)
        }
    }
}
