import CoreGraphics
import Foundation

/// Pure planning for the per-display scheduled brightness/contrast: which writes are due at a
/// given minute, with the "only write when the target changes" bookkeeping that lets a manual
/// adjustment between phase transitions stick (f.lux-style) instead of being snapped back on
/// the next tick. Extracted from `AppStore.applyScheduledHardware` so the routing rules are
/// unit-testable; the store still executes the writes (DDC, gamma, or shade).
enum ScheduledHardware {
    /// What the planner needs to know about a connected display.
    struct DisplayContext {
        var id: CGDirectDisplayID
        var isBuiltIn: Bool
        /// True when this panel's real backlight is controllable (DisplayServices). macOS
        /// manages that backlight (auto-brightness), so the schedule never drives it — only a
        /// built-in with *no* backlight API falls through to software dimming.
        var hasControllableBacklight: Bool
        var preferences: DisplayPreferences
    }

    enum Control: Equatable {
        case brightness
        case contrast
    }

    /// One due write: the display's scheduled `target` (a unified 0…100 position for
    /// brightness — the executor routes it per dimming mode; a DDC percent for contrast).
    struct Write: Equatable {
        var displayID: CGDirectDisplayID
        var control: Control
        var target: Int
    }

    /// The last-planned targets per display. Kept by the caller across ticks; clearing an
    /// entry forces the next plan to re-emit that display's write (used when the user edits
    /// a schedule target, or after a preview drove the hardware elsewhere).
    struct State: Equatable {
        var brightness: [CGDirectDisplayID: Int] = [:]
        var contrast: [CGDirectDisplayID: Int] = [:]

        mutating func clear(_ id: CGDirectDisplayID) {
            brightness[id] = nil
            contrast[id] = nil
        }

        mutating func retainOnly(_ live: Set<CGDirectDisplayID>) {
            brightness = brightness.filter { live.contains($0.key) }
            contrast = contrast.filter { live.contains($0.key) }
        }
    }

    /// The writes due at `minuteOfDay`, plus the updated tracking state.
    ///
    /// Rules (mirroring the store's long-standing behavior):
    /// - Brightness is planned only when its per-display schedule is on — and never for a
    ///   built-in whose real backlight is controllable, since macOS owns that backlight.
    /// - Contrast is DDC-only, so it always skips the built-in panel.
    /// - A control whose schedule is off has its tracking cleared, so re-enabling re-emits
    ///   even when the target happens to be unchanged.
    static func plan(
        displays: [DisplayContext],
        schedule: ResolvedSchedule,
        minuteOfDay: Int,
        state: State
    ) -> (writes: [Write], state: State) {
        var state = state
        var writes: [Write] = []

        for display in displays {
            let displayPreferences = display.preferences

            if displayPreferences.scheduleBrightness,
               !(display.isBuiltIn && display.hasControllableBacklight) {
                let target = ColorSchedule.scheduledHardwareLevel(
                    dayValue: displayPreferences.dayBrightness,
                    sunsetValue: displayPreferences.sunsetBrightness,
                    nightValue: displayPreferences.nightBrightness,
                    schedule: schedule,
                    minuteOfDay: minuteOfDay
                )
                if state.brightness[display.id] != target {
                    state.brightness[display.id] = target
                    writes.append(Write(displayID: display.id, control: .brightness, target: target))
                }
            } else {
                state.brightness[display.id] = nil
            }

            if displayPreferences.scheduleContrast, !display.isBuiltIn {
                let target = ColorSchedule.scheduledHardwareLevel(
                    dayValue: displayPreferences.dayContrast,
                    sunsetValue: displayPreferences.sunsetContrast,
                    nightValue: displayPreferences.nightContrast,
                    schedule: schedule,
                    minuteOfDay: minuteOfDay
                )
                if state.contrast[display.id] != target {
                    state.contrast[display.id] = target
                    writes.append(Write(displayID: display.id, control: .contrast, target: target))
                }
            } else {
                state.contrast[display.id] = nil
            }
        }

        return (writes, state)
    }
}
