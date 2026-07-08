// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics
import Foundation

/// Pure planning for the schedule scrub-preview: everything the screen should show at a
/// previewed minute — the quantized warmth, a preview copy of the preferences carrying the
/// *software* component of scheduled brightness, and the transient DDC writes for the
/// hardware component. Extracted from `AppStore.applySchedulePreview` so the preview's core
/// contract is unit-testable: the stored preferences are never mutated (the gamma override
/// lives only in the returned copy), and each component routes exactly like the live
/// schedule (`HybridBrightness.scheduledComponents`).
enum SchedulePreview {
    /// What the planner needs to know about a connected display.
    struct DisplayContext {
        var key: String
        var id: CGDirectDisplayID
        var isBuiltIn: Bool
        var isVirtual: Bool
        /// Whether the display's own brightness is reachable (DDC).
        var hasHardwareControl: Bool
        /// The display's resolved dimming mode (see `AppStore.dimmingMode(for:)`).
        var dimmingMode: DimmingMode
        /// The software floor for its unified track (15, or 0 with "dim to black").
        var softwareFloor: Int
    }

    /// A transient DDC write for the previewed time — sent straight to the monitor firmware,
    /// never persisted.
    struct HardwareWrite: Equatable {
        var displayID: CGDirectDisplayID
        var kind: DDCControlKind
        var value: Int
    }

    struct Plan: Equatable {
        /// The quantized scheduled temperature at the previewed minute.
        var temperature: Int
        /// The stored preferences with the preview overlaid: a manual target at `temperature`
        /// (so the normal gamma path applies it), plus each scheduled display's software
        /// brightness component. Only this copy carries the overrides.
        var previewPreferences: AppPreferences
        var hardwareWrites: [HardwareWrite]
    }

    static func plan(
        preferences: AppPreferences,
        schedule: ResolvedSchedule,
        displays: [DisplayContext],
        minuteOfDay minute: Int
    ) -> Plan {
        let temperature = ColorSchedule.quantizedTemperature(
            ColorSchedule.scheduledValue(schedule: schedule, minuteOfDay: minute) { phase in
                preferences.temperature(for: phase).clamped(to: ControlRanges.kelvin)
            }
        )

        // Apply through the normal gamma path by faking a manual target at the previewed
        // temperature; the gamma service skips unchanged writes, so a continuous scrub
        // doesn't flood the LUT (and AirPlay/virtual displays stay excluded, as live).
        var previewPreferences = preferences
        previewPreferences.colorMode = .manual
        previewPreferences.manualTemperature = temperature

        var hardwareWrites: [HardwareWrite] = []

        // The built-in is never scheduled, so the preview leaves it out entirely.
        for display in displays where !display.isBuiltIn {
            let displayPreferences = preferences.displayPreferences[display.key, default: DisplayPreferences()]

            if displayPreferences.scheduleBrightness {
                let target = ColorSchedule.scheduledHardwareLevel(
                    dayValue: displayPreferences.dayBrightness,
                    sunsetValue: displayPreferences.sunsetBrightness,
                    nightValue: displayPreferences.nightBrightness,
                    schedule: schedule,
                    minuteOfDay: minute
                )
                let (hardware, gamma) = HybridBrightness.scheduledComponents(
                    target: target,
                    mode: display.dimmingMode,
                    hasHardwareControl: display.hasHardwareControl,
                    floor: display.softwareFloor
                )
                // The software component previews through the preferences copy — but not for
                // AirPlay/virtual displays, which ignore gamma (their shade stays live).
                if let gamma, !display.isVirtual {
                    previewPreferences.displayPreferences[display.key, default: DisplayPreferences()]
                        .gammaBrightness = gamma
                }
                if let hardware {
                    hardwareWrites.append(
                        HardwareWrite(displayID: display.id, kind: .brightness, value: hardware)
                    )
                }
            }

            // Contrast is DDC-only, so a non-DDC monitor can't preview it either (the write
            // would be dropped) — mirror the live schedule's DDC gate.
            if displayPreferences.scheduleContrast, display.hasHardwareControl {
                let target = ColorSchedule.scheduledHardwareLevel(
                    dayValue: displayPreferences.dayContrast,
                    sunsetValue: displayPreferences.sunsetContrast,
                    nightValue: displayPreferences.nightContrast,
                    schedule: schedule,
                    minuteOfDay: minute
                )
                hardwareWrites.append(
                    HardwareWrite(displayID: display.id, kind: .contrast, value: target)
                )
            }
        }

        return Plan(
            temperature: temperature,
            previewPreferences: previewPreferences,
            hardwareWrites: hardwareWrites
        )
    }
}
