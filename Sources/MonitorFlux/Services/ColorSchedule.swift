import Foundation

/// A day's schedule, resolved to concrete anchors: the phase-change events that drive the
/// engine, plus the effective per-phase display values the UI shows (chart handles, time
/// steppers). In Set-times mode the events are the three stored anchors verbatim; in
/// Follow-sunset mode they come from the sun and the wake time (see `ColorSchedule.resolved`
/// and docs/DESIGN.md), and a day can carry a fourth event — the pre-dawn bridge.
struct ResolvedSchedule: Equatable, Sendable {
    /// One phase-change moment: `phase` begins at `minute`-of-day.
    struct Event: Equatable, Sendable {
        var minute: Int
        var phase: ColorPhase
    }

    /// The phase-change events, at most one per minute (ties are collapsed on construction).
    var events: [Event]
    /// When the daytime color begins — sunrise in Follow-sunset's f.lux mornings, otherwise wake.
    var dayStartMinutes: Int
    /// Today's sunset anchor. Kept even on days the squeeze rule drops the sunset *event*,
    /// so the UI can still place (and let the user retune) the sunset warmth handle.
    var sunsetMinutes: Int
    /// When the bedtime color begins (wake − lead when following the sun).
    var bedtimeStartMinutes: Int
    /// The wake input. Equals `dayStartMinutes` except in Follow-sunset's sunrise mornings.
    var wakeMinutes: Int
    /// Fade length applied after each event, shared with the stored preferences.
    var transitionMinutes: Int
    /// True when the events actually came from the sun — false in Set-times mode and when
    /// Follow-sunset fell back to the stored anchors (bad coordinates, polar day/night).
    var followsSun: Bool
    /// True on days the computed sunset falls inside the bedtime window, so the evening
    /// sunset event was dropped (bedtime wins over the sun, f.lux's circadian-first rule).
    var sunsetSqueezed: Bool

    /// The stored anchors as a three-event day — Set-times mode, and the fallback shape.
    static func setTimes(_ preferences: AppPreferences) -> ResolvedSchedule {
        ResolvedSchedule(
            events: [
                Event(minute: preferences.coolStartMinutes, phase: .daytime),
                Event(minute: preferences.sunsetStartMinutes, phase: .sunset),
                Event(minute: preferences.warmStartMinutes, phase: .bedtime),
            ],
            dayStartMinutes: preferences.coolStartMinutes,
            sunsetMinutes: preferences.sunsetStartMinutes,
            bedtimeStartMinutes: preferences.warmStartMinutes,
            wakeMinutes: preferences.coolStartMinutes,
            transitionMinutes: preferences.transitionMinutes,
            followsSun: false,
            sunsetSqueezed: false
        )
    }
}

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
            let schedule = resolved(preferences: preferences, date: date, calendar: calendar)
            let minute = calendar.component(.hour, from: date) * 60
                + calendar.component(.minute, from: date)
            // Quantize the continuously-fading clock temperature so the gamma tables are
            // only rewritten when the color crosses a step boundary (~7 times across a
            // 45-min fade instead of every minute). Each gamma write flashes the screen, so
            // fewer writes = far less flicker. The curve preview uses the raw value, so it
            // stays smooth.
            return quantizedTemperature(
                scheduledValue(schedule: schedule, minuteOfDay: minute) { phase in
                    preferences.temperature(for: phase).clamped(to: ControlRanges.kelvin)
                }
            )
        }
    }

    /// Round a temperature to the nearest `step` Kelvin (default 100). Pure + unit-tested.
    static func quantizedTemperature(_ temperature: Int, step: Int = 100) -> Int {
        guard step > 1 else {
            return temperature
        }
        return Int((Double(temperature) / Double(step)).rounded()) * step
    }

    /// Today's schedule as the engine applies it. Set-times mode returns the stored anchors;
    /// Follow-sunset derives everything from the sun and the wake time (f.lux's model):
    ///
    /// - daytime begins at sunrise (or at wake, per `morningStart`),
    /// - sunset begins at the real sunset,
    /// - bedtime begins `bedtimeLeadMinutes` before wake,
    /// - waking before sunrise inserts a pre-dawn bridge — sunset color from wake to sunrise,
    /// - a sunset that lands inside the bedtime window is dropped (bedtime wins over the sun).
    ///
    /// Falls back to the stored anchors when the coordinates can't be parsed or the sun
    /// doesn't rise/set (polar day/night) — `followsSun` is false in that case.
    static func resolved(
        preferences: AppPreferences,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> ResolvedSchedule {
        guard preferences.scheduleSource == .solar,
              let latitude = Double(preferences.latitude),
              let longitude = Double(preferences.longitude)
        else {
            return .setTimes(preferences)
        }

        let times = SolarCalculator.times(
            latitude: latitude,
            longitude: longitude,
            date: date,
            timeZone: calendar.timeZone
        )
        let solar = solarResolved(
            wakeMinutes: preferences.coolStartMinutes,
            bedtimeLeadMinutes: preferences.bedtimeLeadMinutes,
            morningStart: preferences.morningStart,
            sunriseMinutes: times.sunriseMinutes,
            sunsetMinutes: times.sunsetMinutes,
            transitionMinutes: preferences.transitionMinutes
        )
        return solar ?? .setTimes(preferences)
    }

    /// The pure Follow-sunset resolution (docs/DESIGN.md), separated from
    /// date/coordinate plumbing so the seasonal cases are directly unit-testable. Returns nil
    /// without a sunset (polar day/night) — the caller falls back to the stored anchors.
    static func solarResolved(
        wakeMinutes: Int,
        bedtimeLeadMinutes: Int,
        morningStart: MorningStart,
        sunriseMinutes: Int?,
        sunsetMinutes: Int?,
        transitionMinutes: Int
    ) -> ResolvedSchedule? {
        guard let sunset = sunsetMinutes.map(normalizedMinute) else {
            return nil
        }
        let wake = normalizedMinute(wakeMinutes)
        let sunrise = sunriseMinutes.map(normalizedMinute)
        let bedtimeStart = normalizedMinute(wake - bedtimeLeadMinutes.clamped(to: ControlRanges.bedtimeLeadMinutes))
        let dayStart: Int = switch morningStart {
        case .sunrise:
            sunrise ?? wake
        case .wakeTime:
            wake
        }

        // Bedtime wins over the sun: a sunset inside the bedtime window (short summer nights
        // with an early wake) would otherwise "restart" the sunset phase mid-bedtime.
        let bedtimeArc = circularMinutes(from: bedtimeStart, to: dayStart)
        let sunsetSqueezed = circularMinutes(from: bedtimeStart, to: sunset) < bedtimeArc

        var events = [
            ResolvedSchedule.Event(minute: dayStart, phase: .daytime),
            ResolvedSchedule.Event(minute: bedtimeStart, phase: .bedtime),
        ]
        if !sunsetSqueezed {
            events.append(ResolvedSchedule.Event(minute: sunset, phase: .sunset))
        }
        // The pre-dawn bridge: waking strictly before sunrise ends bedtime at wake, but only
        // steps up to the *sunset* color — full daytime waits for the sun (f.lux's mornings).
        if morningStart == .sunrise, let sunrise {
            let wakeIntoNight = circularMinutes(from: bedtimeStart, to: wake)
            if wakeIntoNight > 0, wakeIntoNight < circularMinutes(from: bedtimeStart, to: sunrise) {
                events.append(ResolvedSchedule.Event(minute: wake, phase: .sunset))
            }
        }

        return ResolvedSchedule(
            events: collapsingTies(events),
            dayStartMinutes: dayStart,
            sunsetMinutes: sunset,
            bedtimeStartMinutes: bedtimeStart,
            wakeMinutes: wake,
            transitionMinutes: transitionMinutes,
            followsSun: true,
            sunsetSqueezed: sunsetSqueezed
        )
    }

    /// Degenerate inputs (a lead that lands bedtime exactly on sunrise, a wake equal to the
    /// sunset minute) can put two events on the same minute; the engine's "most recently
    /// begun" rule would then pick one arbitrarily. Keep a single event per minute with a
    /// deterministic winner: daytime over bedtime over sunset.
    private static func collapsingTies(_ events: [ResolvedSchedule.Event]) -> [ResolvedSchedule.Event] {
        let precedence: [ColorPhase: Int] = [.daytime: 0, .bedtime: 1, .sunset: 2]
        var byMinute: [Int: ResolvedSchedule.Event] = [:]
        for event in events {
            if let existing = byMinute[event.minute],
               precedence[existing.phase, default: .max] <= precedence[event.phase, default: .max] {
                continue
            }
            byMinute[event.minute] = event
        }
        return byMinute.values.sorted { $0.minute < $1.minute }
    }

    /// The schedule phase in effect right now — the same "most recently begun" event
    /// `scheduledValue` treats as active. Used to pre-select the Schedule screen's phase tab
    /// and to route the popup's warmth slider to the live phase.
    static func currentPhase(
        preferences: AppPreferences,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> ColorPhase {
        let schedule = resolved(preferences: preferences, date: date, calendar: calendar)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return activePhase(schedule: schedule, minuteOfDay: minute)
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
            return normalizedMinute(lower)
        }
        let lo = min(minGap, span / 2)
        let hi = span - lo
        var rel = circularMinutes(from: lower, to: minute)
        if rel < lo || rel > hi {
            rel = circularDistance(minute, lower) <= circularDistance(minute, upper) ? lo : hi
        }
        return normalizedMinute(lower + rel)
    }

    /// Shortest distance between two minutes on the 24h circle, in [0, 720].
    private static func circularDistance(_ a: Int, _ b: Int) -> Int {
        let diff = ((a - b) % 1440 + 1440) % 1440
        return min(diff, 1440 - diff)
    }

    /// The phase active at `minuteOfDay`: the one whose event was passed most recently.
    static func activePhase(schedule: ResolvedSchedule, minuteOfDay: Int) -> ColorPhase {
        let minute = normalizedMinute(minuteOfDay)
        return schedule.events
            .min { lhs, rhs in
                circularMinutes(from: lhs.minute, to: minute)
                    < circularMinutes(from: rhs.minute, to: minute)
            }?
            .phase ?? .daytime
    }

    /// `activePhase` over the stored anchors (no solar derivation) — Set-times semantics.
    static func activePhase(preferences: AppPreferences, minuteOfDay: Int) -> ColorPhase {
        activePhase(schedule: .setTimes(preferences), minuteOfDay: minuteOfDay)
    }

    /// The scheduled temperature over the stored anchors (no solar derivation). Live callers
    /// should resolve first and use `scheduledValue(schedule:)`.
    static func scheduledTemperature(
        preferences: AppPreferences,
        minuteOfDay: Int
    ) -> Int {
        scheduledValue(schedule: .setTimes(preferences), minuteOfDay: minuteOfDay) { phase in
            preferences.temperature(for: phase).clamped(to: ControlRanges.kelvin)
        }
    }

    /// A per-display hardware level (brightness or contrast) riding the same resolved
    /// timeline as the color schedule: holds `dayValue` through the day, eases to
    /// `sunsetValue` at sunset (and across a pre-dawn bridge), eases to `nightValue` at
    /// bedtime, and fades back to `dayValue` when the day begins.
    static func scheduledHardwareLevel(
        dayValue: Int,
        sunsetValue: Int,
        nightValue: Int,
        schedule: ResolvedSchedule,
        minuteOfDay: Int
    ) -> Int {
        scheduledValue(schedule: schedule, minuteOfDay: minuteOfDay) { phase in
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

    /// `scheduledHardwareLevel` over the stored anchors (no solar derivation).
    static func scheduledHardwareLevel(
        dayValue: Int,
        sunsetValue: Int,
        nightValue: Int,
        preferences: AppPreferences,
        minuteOfDay: Int
    ) -> Int {
        scheduledHardwareLevel(
            dayValue: dayValue,
            sunsetValue: sunsetValue,
            nightValue: nightValue,
            schedule: .setTimes(preferences),
            minuteOfDay: minuteOfDay
        )
    }

    /// The scheduled value at `minuteOfDay`, given each phase's held value. Shared by the
    /// color and brightness/contrast schedules so they ride the identical events + fade
    /// logic. Holds the active event's phase value, fading from the previous event's value
    /// over the transition window right after each event begins.
    static func scheduledValue(
        schedule: ResolvedSchedule,
        minuteOfDay: Int,
        value: (ColorPhase) -> Int
    ) -> Int {
        let minute = normalizedMinute(minuteOfDay)
        let transition = schedule.transitionMinutes.clamped(to: ControlRanges.transitionMinutes)

        // One anchor per event: how long ago it began, and the value it holds. Events sit on
        // distinct minutes (ties collapse on construction), so the order is deterministic.
        let anchors = schedule.events
            .map { event in
                (
                    since: circularMinutes(from: event.minute, to: minute),
                    value: value(event.phase)
                )
            }
            .sorted { $0.since < $1.since }

        guard let active = anchors.first else {
            return value(.daytime)
        }
        guard anchors.count > 1 else {
            return active.value
        }

        // The most recently passed anchor is active; the next-most-recent is the
        // phase we are fading out of during the transition window after it begins.
        let previous = anchors[1]

        // Cap the fade so it finishes before the next event begins. Otherwise, with a
        // transition longer than the gap between two events (e.g. the default 60-min
        // sunset→bedtime spacing and a fade > 60), the previous event's own fade is still
        // mid-way when this one starts, and fading from `previous.value` (its target, not
        // the on-screen value) would snap. `anchors` is sorted by "minutes since it began",
        // so the largest `since` is the next event to restart; the gap from this event's
        // start to that one is `active.since + 1440 - maxSince`.
        let maxSince = anchors[anchors.count - 1].since
        let gapToNextEvent = active.since + 1440 - maxSince
        let effectiveTransition = min(transition, gapToNextEvent)

        if effectiveTransition > 0, active.since < effectiveTransition {
            return interpolate(
                from: previous.value,
                to: active.value,
                progress: Double(active.since) / Double(effectiveTransition)
            )
        }

        return active.value
    }

    /// `scheduledValue` over the stored anchors (no solar derivation) — Set-times semantics.
    static func scheduledValue(
        preferences: AppPreferences,
        minuteOfDay: Int,
        value: (ColorPhase) -> Int
    ) -> Int {
        scheduledValue(schedule: .setTimes(preferences), minuteOfDay: minuteOfDay, value: value)
    }

    /// The phase mix in effect at `minuteOfDay`: the active phase, the phase it's fading out of,
    /// and how far (0…1) that fade has progressed. During a transition window right after an event
    /// the result runs `from` the previous phase `to` the active one; outside a window (and when
    /// there's only one anchor) `from == to` and `progress == 1` — a single, settled phase.
    ///
    /// Mirrors `scheduledValue`'s interpolation exactly, so a visual that can't be expressed as an
    /// Int (the curve's per-phase fill color) can blend on the identical timeline as the numeric
    /// schedule instead of hard-cutting at each phase boundary. Pure + unit-tested.
    static func scheduledPhaseMix(
        schedule: ResolvedSchedule,
        minuteOfDay: Int
    ) -> (from: ColorPhase, to: ColorPhase, progress: Double) {
        let minute = normalizedMinute(minuteOfDay)
        let transition = schedule.transitionMinutes.clamped(to: ControlRanges.transitionMinutes)

        let anchors = schedule.events
            .map { event in (since: circularMinutes(from: event.minute, to: minute), phase: event.phase) }
            .sorted { $0.since < $1.since }

        guard let active = anchors.first else {
            return (.daytime, .daytime, 1)
        }
        guard anchors.count > 1 else {
            return (active.phase, active.phase, 1)
        }

        let previous = anchors[1]
        // Same fade cap as `scheduledValue`: the transition can't outlast the gap to the next event.
        let maxSince = anchors[anchors.count - 1].since
        let gapToNextEvent = active.since + 1440 - maxSince
        let effectiveTransition = min(transition, gapToNextEvent)

        if effectiveTransition > 0, active.since < effectiveTransition {
            return (
                from: previous.phase,
                to: active.phase,
                progress: Double(active.since) / Double(effectiveTransition)
            )
        }
        return (active.phase, active.phase, 1)
    }

    private static func normalizedMinute(_ minute: Int) -> Int {
        ((minute % 1440) + 1440) % 1440
    }

    private static func circularMinutes(from start: Int, to end: Int) -> Int {
        (normalizedMinute(end) - normalizedMinute(start) + 1440) % 1440
    }

    private static func interpolate(from start: Int, to end: Int, progress: Double) -> Int {
        let clampedProgress = progress.clamped(to: 0...1)
        return Int((Double(start) + (Double(end - start) * clampedProgress)).rounded())
    }
}
