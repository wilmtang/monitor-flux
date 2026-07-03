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
            // Quantize the continuously-fading clock temperature so the gamma tables are
            // only rewritten when the color crosses a step boundary (~7 times across a
            // 45-min fade instead of every minute). Each gamma write flashes the screen, so
            // fewer writes = far less flicker. The curve preview uses the raw value, so it
            // stays smooth.
            return quantizedTemperature(scheduledTemperature(preferences: effective, minuteOfDay: minute))
        }
    }

    /// Round a temperature to the nearest `step` Kelvin (default 100). Pure + unit-tested.
    static func quantizedTemperature(_ temperature: Int, step: Int = 100) -> Int {
        guard step > 1 else {
            return temperature
        }
        return Int((Double(temperature) / Double(step)).rounded()) * step
    }

    /// When the schedule is location-driven, replace only the **sunset** anchor with the day's
    /// computed sunset — like f.lux, which warms the screen at real sunset while your **wake**
    /// and **bedtime** stay the times you set. (Tying "wake" to sunrise made the screen jump to
    /// daytime at ~5 AM in summer, which isn't when people wake.) Returns the preferences
    /// unchanged for manual schedules or when the latitude/longitude can't be parsed.
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
        if let sunset = times.sunsetMinutes {
            copy.sunsetStartMinutes = sunset
        }
        return copy
    }

    /// The schedule phase in effect right now — the same "most recently begun" anchor
    /// `scheduledValue` treats as active, after applying any solar adjustment. Used to
    /// pre-select the Schedule screen's phase tab so it opens on the live phase.
    static func currentPhase(
        preferences: AppPreferences,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> ColorPhase {
        let effective = solarAdjustedPreferences(preferences, date: date, calendar: calendar)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return activePhase(preferences: effective, minuteOfDay: minute)
    }

    /// Keep the three time anchors in cyclic order daytime → sunset → bedtime → (wraps). Returns
    /// `minute` clamped into the open arc between `phase`'s two cyclic neighbors, so e.g. sunset can
    /// never be set before wake or after bedtime. `minGap` stops adjacent phases from touching.
    /// Anything dragged into the forbidden arc snaps to the nearer end of the allowed one.
    static func clampedStartMinute(
        _ minute: Int,
        for phase: ColorPhase,
        wake: Int,
        sunset: Int,
        bedtime: Int,
        minGap: Int = 15
    ) -> Int {
        let (previous, next): (Int, Int)
        switch phase {
        case .daytime:
            previous = bedtime
            next = sunset
        case .sunset:
            previous = wake
            next = bedtime
        case .bedtime:
            previous = sunset
            next = wake
        }
        return clampIntoArc(minute, after: previous, before: next, minGap: minGap)
    }

    /// Convenience over the explicit-anchors form, reading the anchors from `preferences`.
    static func clampedStartMinute(
        _ minute: Int,
        for phase: ColorPhase,
        preferences: AppPreferences,
        minGap: Int = 15
    ) -> Int {
        clampedStartMinute(
            minute,
            for: phase,
            wake: preferences.coolStartMinutes,
            sunset: preferences.sunsetStartMinutes,
            bedtime: preferences.warmStartMinutes,
            minGap: minGap
        )
    }

    /// Clamp `minute` into the arc that runs forward from `lower` to `upper`, kept `minGap` clear of
    /// each end. A `minute` already inside the arc is returned unchanged (normalized); one outside
    /// snaps to whichever end of the arc is angularly closer.
    private static func clampIntoArc(_ minute: Int, after lower: Int, before upper: Int, minGap: Int) -> Int {
        let span = circularMinutes(from: lower, to: upper)
        guard span > 0 else {
            return ((lower % 1440) + 1440) % 1440
        }
        let lo = min(minGap, span / 2)
        let hi = span - lo
        var rel = circularMinutes(from: lower, to: minute)
        if rel < lo || rel > hi {
            rel = circularDistance(minute, lower) <= circularDistance(minute, upper) ? lo : hi
        }
        return (((lower + rel) % 1440) + 1440) % 1440
    }

    /// Shortest distance between two minutes on the 24h circle, in [0, 720].
    private static func circularDistance(_ a: Int, _ b: Int) -> Int {
        let diff = ((a - b) % 1440 + 1440) % 1440
        return min(diff, 1440 - diff)
    }

    /// The phase active at `minuteOfDay`: the one whose start anchor was passed most recently.
    static func activePhase(preferences: AppPreferences, minuteOfDay: Int) -> ColorPhase {
        let minute = ((minuteOfDay % 1440) + 1440) % 1440
        return ColorPhase.allCases
            .min { lhs, rhs in
                circularMinutes(from: preferences.startMinutes(for: lhs), to: minute)
                    < circularMinutes(from: preferences.startMinutes(for: rhs), to: minute)
            } ?? .daytime
    }

    static func scheduledTemperature(
        preferences: AppPreferences,
        minuteOfDay: Int
    ) -> Int {
        scheduledValue(preferences: preferences, minuteOfDay: minuteOfDay) { phase in
            preferences.temperature(for: phase).clamped(to: ControlRanges.kelvin)
        }
    }

    /// A per-display hardware level (brightness or contrast) on the same day/sunset/night
    /// timeline as the color schedule: holds `dayValue` through the day, eases to `sunsetValue`
    /// at sunset, eases again to `nightValue` at bedtime, and fades back to `dayValue` at wake.
    /// Three targets riding the existing wake/sunset/bedtime anchors and fade.
    static func scheduledHardwareLevel(
        dayValue: Int,
        sunsetValue: Int,
        nightValue: Int,
        preferences: AppPreferences,
        minuteOfDay: Int
    ) -> Int {
        scheduledValue(preferences: preferences, minuteOfDay: minuteOfDay) { phase in
            switch phase {
            case .daytime:
                dayValue
            case .sunset:
                sunsetValue
            case .bedtime:
                nightValue
            }
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
