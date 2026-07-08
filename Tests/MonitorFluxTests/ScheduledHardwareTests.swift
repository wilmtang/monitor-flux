// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

final class ScheduledHardwareTests: XCTestCase {
    /// Anchors: wake 7:00, sunset 20:00, bedtime 21:00, 45-min fade (the defaults).
    private let schedule = ResolvedSchedule.setTimes(AppPreferences.defaults)

    private func context(
        id: CGDirectDisplayID = 1,
        isBuiltIn: Bool = false,
        hasControllableBacklight: Bool = false,
        hasControllableContrast: Bool = true,
        scheduleBrightness: Bool = true,
        scheduleContrast: Bool = false
    ) -> ScheduledHardware.DisplayContext {
        var preferences = DisplayPreferences()
        preferences.scheduleBrightness = scheduleBrightness
        preferences.scheduleContrast = scheduleContrast
        return ScheduledHardware.DisplayContext(
            id: id,
            isBuiltIn: isBuiltIn,
            hasControllableBacklight: hasControllableBacklight,
            hasControllableContrast: hasControllableContrast,
            preferences: preferences
        )
    }

    func testUnchangedTargetEmitsOnlyOnce() {
        let noon = 12 * 60
        let first = ScheduledHardware.plan(
            displays: [context()], schedule: schedule, minuteOfDay: noon,
            state: ScheduledHardware.State()
        )
        XCTAssertEqual(
            first.writes,
            [ScheduledHardware.Write(displayID: 1, control: .brightness, target: 90)]
        )

        // Same minute again — the target hasn't moved, so nothing is re-written and a manual
        // adjustment made in between would hold.
        let second = ScheduledHardware.plan(
            displays: [context()], schedule: schedule, minuteOfDay: noon, state: first.state
        )
        XCTAssertTrue(second.writes.isEmpty)
        XCTAssertEqual(second.state, first.state)
    }

    func testChangedTargetReEmits() {
        let noon = ScheduledHardware.plan(
            displays: [context()], schedule: schedule, minuteOfDay: 12 * 60,
            state: ScheduledHardware.State()
        )
        // 22:00 is past bedtime (21:00) + fade, so the night target (40) is due.
        let night = ScheduledHardware.plan(
            displays: [context()], schedule: schedule, minuteOfDay: 22 * 60, state: noon.state
        )
        XCTAssertEqual(
            night.writes,
            [ScheduledHardware.Write(displayID: 1, control: .brightness, target: 40)]
        )
    }

    func testBuiltInWithBacklightIsNeverScheduled() {
        // macOS owns the built-in backlight (auto-brightness); the schedule must not fight it.
        let builtIn = context(isBuiltIn: true, hasControllableBacklight: true, scheduleContrast: true)
        let result = ScheduledHardware.plan(
            displays: [builtIn], schedule: schedule, minuteOfDay: 12 * 60,
            state: ScheduledHardware.State()
        )
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertTrue(result.state.brightness.isEmpty)
        XCTAssertTrue(result.state.contrast.isEmpty)
    }

    func testBuiltInWithoutBacklightFallsThroughToBrightnessOnly() {
        // No backlight API: brightness rides the software fallback, but contrast stays
        // DDC-only and skips the built-in regardless.
        let builtIn = context(isBuiltIn: true, hasControllableBacklight: false, scheduleContrast: true)
        let result = ScheduledHardware.plan(
            displays: [builtIn], schedule: schedule, minuteOfDay: 12 * 60,
            state: ScheduledHardware.State()
        )
        XCTAssertEqual(
            result.writes,
            [ScheduledHardware.Write(displayID: 1, control: .brightness, target: 90)]
        )
    }

    func testDisablingScheduleClearsTrackingSoReEnablingReEmits() {
        let noon = 12 * 60
        let on = ScheduledHardware.plan(
            displays: [context()], schedule: schedule, minuteOfDay: noon,
            state: ScheduledHardware.State()
        )
        let off = ScheduledHardware.plan(
            displays: [context(scheduleBrightness: false)], schedule: schedule,
            minuteOfDay: noon, state: on.state
        )
        XCTAssertTrue(off.writes.isEmpty)
        XCTAssertTrue(off.state.brightness.isEmpty)

        // Re-enabling re-emits even though the target value never changed.
        let backOn = ScheduledHardware.plan(
            displays: [context()], schedule: schedule, minuteOfDay: noon, state: off.state
        )
        XCTAssertEqual(backOn.writes.count, 1)
    }

    func testContrastIsPlannedIndependentlyOfBrightness() {
        let both = context(scheduleBrightness: true, scheduleContrast: true)
        let result = ScheduledHardware.plan(
            displays: [both], schedule: schedule, minuteOfDay: 12 * 60,
            state: ScheduledHardware.State()
        )
        XCTAssertEqual(result.writes.count, 2)
        XCTAssertTrue(result.writes.contains(
            ScheduledHardware.Write(displayID: 1, control: .contrast, target: 75)
        ))
    }

    func testContrastSkipsDisplaysWithoutDDC() {
        // A non-DDC external can't take a contrast write, so the planner must not emit one
        // (nor track it) even with the schedule on.
        let nonDDC = context(hasControllableContrast: false, scheduleContrast: true)
        let result = ScheduledHardware.plan(
            displays: [nonDDC], schedule: schedule, minuteOfDay: 12 * 60,
            state: ScheduledHardware.State()
        )
        XCTAssertFalse(result.writes.contains { $0.control == .contrast })
        XCTAssertTrue(result.state.contrast.isEmpty)
    }

    func testRetainOnlyDropsDisconnectedDisplays() {
        var state = ScheduledHardware.State()
        state.brightness = [1: 90, 2: 80]
        state.contrast = [2: 70]
        state.retainOnly([1])
        XCTAssertEqual(state.brightness, [1: 90])
        XCTAssertTrue(state.contrast.isEmpty)
    }
}
