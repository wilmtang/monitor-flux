// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

final class SchedulePreviewTests: XCTestCase {
    private let noon = 12 * 60
    private let lateNight = 23 * 60

    private func context(
        key: String = "ext",
        id: CGDirectDisplayID = 2,
        isBuiltIn: Bool = false,
        isVirtual: Bool = false,
        hasHardwareControl: Bool = true,
        dimmingMode: DimmingMode = .automatic,
        softwareFloor: Int = HybridBrightness.defaultFloorPercent
    ) -> SchedulePreview.DisplayContext {
        SchedulePreview.DisplayContext(
            key: key,
            id: id,
            isBuiltIn: isBuiltIn,
            isVirtual: isVirtual,
            hasHardwareControl: hasHardwareControl,
            dimmingMode: dimmingMode,
            softwareFloor: softwareFloor
        )
    }

    private func preferencesWithScheduledDisplay(
        key: String = "ext",
        scheduleBrightness: Bool = true,
        scheduleContrast: Bool = false
    ) -> AppPreferences {
        var preferences = AppPreferences.defaults
        var display = DisplayPreferences()
        display.scheduleBrightness = scheduleBrightness
        display.scheduleContrast = scheduleContrast
        preferences.displayPreferences[key] = display
        return preferences
    }

    func testPreviewOverlaysManualTargetWithoutTouchingScheduleShape() {
        let preferences = AppPreferences.defaults // colorMode == .clock (warmth is scheduled)
        let plan = SchedulePreview.plan(
            preferences: preferences, schedule: .setTimes(preferences), displays: [], minuteOfDay: noon
        )

        // With warmth scheduled, the preview copy fakes a manual target at the previewed (quantized)
        // temperature so the normal gamma path applies it — the schedule's own fields stay untouched.
        XCTAssertEqual(plan.previewPreferences.colorMode, .manual)
        XCTAssertEqual(plan.temperature, preferences.dayTemperature)
        XCTAssertEqual(plan.previewPreferences.manualTemperature, preferences.dayTemperature)
        XCTAssertEqual(plan.previewPreferences.dayTemperature, preferences.dayTemperature)
        XCTAssertEqual(plan.previewPreferences.warmStartMinutes, preferences.warmStartMinutes)
    }

    func testWarmthOffPreviewDoesNotWarmTheScreen() {
        // Scrubbing a hardware chart while Warmth is Off must not fake a warmth target — the
        // brightness preview still rides along (software dimming is independent of warmth), but
        // the gamma path stays in Off, so nothing warms the screen.
        var preferences = preferencesWithScheduledDisplay()
        preferences.colorMode = .off
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences), displays: [context()], minuteOfDay: lateNight
        )
        XCTAssertEqual(plan.previewPreferences.colorMode, .off)
        XCTAssertNil(plan.temperature)
        XCTAssertFalse(plan.hardwareWrites.isEmpty) // brightness still previews
    }

    func testFixedWarmthPreviewKeepsTheManualTemperature() {
        // In Fixed mode the scrub previews brightness/contrast, leaving warmth at the user's fixed
        // temperature — not jumping it to the schedule's value for the previewed minute.
        var preferences = preferencesWithScheduledDisplay(scheduleBrightness: false)
        preferences.colorMode = .manual
        preferences.manualTemperature = 3500
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences), displays: [context()], minuteOfDay: noon
        )
        XCTAssertEqual(plan.previewPreferences.colorMode, .manual)
        XCTAssertEqual(plan.previewPreferences.manualTemperature, 3500)
        XCTAssertEqual(plan.temperature, 3500)
    }

    func testHardwareZoneTargetPreviewsAsDDCWriteWithNeutralGamma() {
        // The default night target (40) sits above the 25% notch: DDC 20, gamma neutral.
        // The neutral gamma still lands in the preview copy (self-healing a mixed state) —
        // never in the stored preferences.
        let preferences = preferencesWithScheduledDisplay()
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences), displays: [context()], minuteOfDay: lateNight
        )
        XCTAssertEqual(
            plan.hardwareWrites,
            [SchedulePreview.HardwareWrite(displayID: 2, kind: .brightness, value: 20)]
        )
        XCTAssertEqual(plan.previewPreferences.displayPreferences["ext"]?.gammaBrightness, 100)
        XCTAssertEqual(preferences.displayPreferences["ext"]?.gammaBrightness, 100)
    }

    func testSoftwareZoneTargetPreviewsAsDDCZeroPlusGammaOverride() {
        // A 10% night target lands below the notch: DDC drops to 0 and the rest of the
        // dimming previews through the gamma override in the preferences copy.
        var preferences = preferencesWithScheduledDisplay()
        preferences.displayPreferences["ext"]?.nightBrightness = 10
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences), displays: [context()], minuteOfDay: lateNight
        )
        XCTAssertEqual(
            plan.hardwareWrites,
            [SchedulePreview.HardwareWrite(displayID: 2, kind: .brightness, value: 0)]
        )
        let expected = HybridBrightness.split(unified: 0.10).gamma
        XCTAssertEqual(plan.previewPreferences.displayPreferences["ext"]?.gammaBrightness, expected)
    }

    func testSoftwareModeTargetPreviewsThroughGammaOnly() {
        var preferences = preferencesWithScheduledDisplay()
        preferences.displayPreferences["ext"]?.nightBrightness = 40
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences),
            displays: [context(dimmingMode: .software)],
            minuteOfDay: lateNight
        )
        // Software dimming: no DDC write; the gamma override rides the floored track.
        XCTAssertTrue(plan.hardwareWrites.isEmpty)
        XCTAssertEqual(
            plan.previewPreferences.displayPreferences["ext"]?.gammaBrightness,
            HybridBrightness.softwareOnlyGamma(fraction: 0.4)
        )
    }

    func testVirtualDisplayGetsNoGammaOverrideAndNoHardwareWrite() {
        // AirPlay/virtual ignores gamma (the shade dims it live), and it has no DDC.
        let preferences = preferencesWithScheduledDisplay()
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences),
            displays: [context(isVirtual: true, hasHardwareControl: false)],
            minuteOfDay: lateNight
        )
        XCTAssertTrue(plan.hardwareWrites.isEmpty)
        XCTAssertEqual(plan.previewPreferences.displayPreferences["ext"]?.gammaBrightness, 100)
    }

    func testBuiltInIsLeftOutEntirely() {
        let preferences = preferencesWithScheduledDisplay(key: "builtin")
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences),
            displays: [context(key: "builtin", id: 1, isBuiltIn: true, hasHardwareControl: false)],
            minuteOfDay: lateNight
        )
        XCTAssertTrue(plan.hardwareWrites.isEmpty)
        XCTAssertEqual(plan.previewPreferences.displayPreferences["builtin"]?.gammaBrightness, 100)
    }

    func testScheduledContrastEmitsContrastWrite() {
        let preferences = preferencesWithScheduledDisplay(scheduleBrightness: false, scheduleContrast: true)
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences), displays: [context()], minuteOfDay: noon
        )
        XCTAssertEqual(
            plan.hardwareWrites,
            [SchedulePreview.HardwareWrite(displayID: 2, kind: .contrast, value: 75)]
        )
    }

    func testScheduledContrastSkippedWithoutDDC() {
        // Contrast is DDC-only, so a non-DDC monitor previews no contrast write.
        let preferences = preferencesWithScheduledDisplay(scheduleBrightness: false, scheduleContrast: true)
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences),
            displays: [context(hasHardwareControl: false)],
            minuteOfDay: noon
        )
        XCTAssertTrue(plan.hardwareWrites.isEmpty)
    }

    func testUnscheduledDisplayContributesNothing() {
        let preferences = preferencesWithScheduledDisplay(scheduleBrightness: false)
        let plan = SchedulePreview.plan(
            preferences: preferences,
            schedule: .setTimes(preferences), displays: [context()], minuteOfDay: lateNight
        )
        XCTAssertTrue(plan.hardwareWrites.isEmpty)
        XCTAssertEqual(plan.previewPreferences.displayPreferences["ext"]?.gammaBrightness, 100)
    }
}
