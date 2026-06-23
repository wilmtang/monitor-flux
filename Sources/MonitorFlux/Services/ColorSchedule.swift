import Foundation

enum ColorSchedule {
    static func targetTemperature(
        preferences: AppPreferences,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        switch preferences.colorMode {
        case .off:
            return nil
        case .manual:
            return preferences.manualTemperature.clamped(to: ControlRanges.kelvin)
        case .clock:
            let effective = solarAdjustedPreferences(preferences, date: date, calendar: calendar)
            let minute = calendar.component(.hour, from: date) * 60
                + calendar.component(.minute, from: date)
            return scheduledTemperature(
                preferences: effective,
                minuteOfDay: minute
            )
        }
    }

    /// When the schedule is location-driven, replace the daytime (sunrise) and sunset
    /// anchors with the day's computed solar times; bedtime stays the user's set hour,
    /// matching f.lux. Returns the preferences unchanged for manual schedules or when
    /// the latitude/longitude can't be parsed.
    static func solarAdjustedPreferences(
        _ preferences: AppPreferences,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> AppPreferences {
        guard preferences.scheduleSource == .solar,
              let latitude = Double(preferences.latitude),
              let longitude = Double(preferences.longitude)
        else {
            return preferences
        }

        let times = SolarCalculator.times(
            latitude: latitude,
            longitude: longitude,
            date: date,
            timeZone: calendar.timeZone
        )
        var copy = preferences
        if let sunrise = times.sunriseMinutes {
            copy.coolStartMinutes = sunrise
        }
        if let sunset = times.sunsetMinutes {
            copy.sunsetStartMinutes = sunset
        }
        return copy
    }

    static func scheduledTemperature(
        preferences: AppPreferences,
        minuteOfDay: Int
    ) -> Int {
        scheduledValue(preferences: preferences, minuteOfDay: minuteOfDay) { phase in
            preferences.temperature(for: phase).clamped(to: ControlRanges.kelvin)
        }
    }

    /// A per-display hardware level (brightness or contrast) on the same day/night timeline
    /// as the color schedule: holds `dayValue` through the day, fades to `nightValue` at
    /// sunset, and holds it overnight (fading back at wake). Two targets, the existing
    /// wake/sunset/bedtime anchors and fade.
    static func scheduledHardwareLevel(
        dayValue: Int,
        nightValue: Int,
        preferences: AppPreferences,
        minuteOfDay: Int
    ) -> Int {
        scheduledValue(preferences: preferences, minuteOfDay: minuteOfDay) { phase in
            phase == .daytime ? dayValue : nightValue
        }
    }

    /// The scheduled value at `minuteOfDay`, given each phase's held value. Shared by the
    /// color and brightness/contrast schedules so they ride the identical anchor + fade
    /// logic. Holds the active phase's value, fading from the previous phase's value over
    /// the transition window right after each phase begins.
    static func scheduledValue(
        preferences: AppPreferences,
        minuteOfDay: Int,
        value: (ColorPhase) -> Int
    ) -> Int {
        let minute = ((minuteOfDay % 1440) + 1440) % 1440
        let transition = preferences.transitionMinutes.clamped(to: ControlRanges.transitionMinutes)

        // One anchor per phase: how long ago it began, and the value it holds.
        let anchors = ColorPhase.allCases
            .map { phase in
                (
                    since: circularMinutes(from: preferences.startMinutes(for: phase), to: minute),
                    value: value(phase)
                )
            }
            .sorted { $0.since < $1.since }

        // The most recently passed anchor is active; the next-most-recent is the
        // phase we are fading out of during the transition window after it begins.
        let active = anchors[0]
        let previous = anchors[1]

        // Cap the fade so it finishes before the next phase begins. Otherwise, with a
        // transition longer than the gap between two phases (e.g. the default 60-min
        // sunset→bedtime spacing and a fade > 60), the previous phase's own fade is still
        // mid-way when this phase starts, and fading from `previous.value` (its target, not
        // the on-screen value) would snap. `anchors` is sorted by "minutes since it began",
        // so the largest `since` is the next phase to restart; the gap from this phase's
        // start to that one is `active.since + 1440 - maxSince`.
        let maxSince = anchors[anchors.count - 1].since
        let gapToNextPhase = active.since + 1440 - maxSince
        let effectiveTransition = min(transition, gapToNextPhase)

        if effectiveTransition > 0, active.since < effectiveTransition {
            return interpolate(
                from: previous.value,
                to: active.value,
                progress: Double(active.since) / Double(effectiveTransition)
            )
        }

        return active.value
    }

    private static func circularMinutes(from start: Int, to end: Int) -> Int {
        let normalizedStart = ((start % 1440) + 1440) % 1440
        let normalizedEnd = ((end % 1440) + 1440) % 1440
        return (normalizedEnd - normalizedStart + 1440) % 1440
    }

    private static func interpolate(from start: Int, to end: Int, progress: Double) -> Int {
        let clampedProgress = progress.clamped(to: 0...1)
        return Int((Double(start) + (Double(end - start) * clampedProgress)).rounded())
    }
}
