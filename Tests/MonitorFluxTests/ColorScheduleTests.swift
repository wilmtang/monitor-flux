import XCTest
@testable import MonitorFlux

final class ColorScheduleTests: XCTestCase {
    func testManualTemperatureWins() {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .manual
        preferences.manualTemperature = 4100

        XCTAssertEqual(ColorSchedule.targetTemperature(preferences: preferences), 4100)
    }

    func testOffTemperatureIsNil() {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .off

        XCTAssertNil(ColorSchedule.targetTemperature(preferences: preferences))
    }

    func testTemperatureQuantizationRoundsToStep() {
        // Reduces gamma rewrites (and screen flicker) during a fade by snapping to 100 K.
        XCTAssertEqual(ColorSchedule.quantizedTemperature(3247), 3200)
        XCTAssertEqual(ColorSchedule.quantizedTemperature(3250), 3300) // .5 rounds up
        XCTAssertEqual(ColorSchedule.quantizedTemperature(2780), 2800)
        XCTAssertEqual(ColorSchedule.quantizedTemperature(6500), 6500) // already on a boundary
    }

    func testClockTemperatureIsQuantized() {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.scheduleSource = .manualTimes
        // Mid-fade the raw schedule produces odd values; the applied target snaps to 100 K.
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 22
        components.hour = 20
        components.minute = 17 // 17 min into the 8 PM sunset fade
        let date = Calendar.current.date(from: components)!

        let temperature = ColorSchedule.targetTemperature(preferences: preferences, date: date)
        XCTAssertNotNil(temperature)
        XCTAssertEqual(temperature! % 100, 0)
    }

    func testScheduledHardwareLevelHoldsDayThenNight() {
        var preferences = AppPreferences.defaults
        preferences.coolStartMinutes = 7 * 60     // wake / daytime begins
        preferences.sunsetStartMinutes = 20 * 60  // sunset begins
        preferences.warmStartMinutes = 21 * 60    // bedtime begins
        preferences.transitionMinutes = 0         // no fade -> hard hold

        // Midday holds the daytime target; deep night holds the night target.
        XCTAssertEqual(
            ColorSchedule.scheduledHardwareLevel(dayValue: 90, sunsetValue: 65, nightValue: 40, preferences: preferences, minuteOfDay: 12 * 60),
            90
        )
        XCTAssertEqual(
            ColorSchedule.scheduledHardwareLevel(dayValue: 90, sunsetValue: 65, nightValue: 40, preferences: preferences, minuteOfDay: 0),
            40
        )
        // Between sunset (20:00) and bedtime (21:00) the sunset target holds.
        XCTAssertEqual(
            ColorSchedule.scheduledHardwareLevel(dayValue: 90, sunsetValue: 65, nightValue: 40, preferences: preferences, minuteOfDay: 20 * 60 + 30),
            65
        )
    }

    func testScheduledHardwareLevelEasesAcrossSunset() {
        var preferences = AppPreferences.defaults
        preferences.coolStartMinutes = 7 * 60
        preferences.sunsetStartMinutes = 20 * 60
        preferences.warmStartMinutes = 21 * 60
        preferences.transitionMinutes = 45

        // Partway into the post-sunset fade, the level sits strictly between day and sunset.
        let level = ColorSchedule.scheduledHardwareLevel(
            dayValue: 90, sunsetValue: 65, nightValue: 40, preferences: preferences, minuteOfDay: 20 * 60 + 22
        )
        XCTAssertGreaterThan(level, 65)
        XCTAssertLessThan(level, 90)
    }

    func testActivePhaseTracksTheClock() {
        var preferences = AppPreferences.defaults
        preferences.coolStartMinutes = 7 * 60     // daytime begins
        preferences.sunsetStartMinutes = 20 * 60  // sunset begins
        preferences.warmStartMinutes = 21 * 60    // bedtime begins

        XCTAssertEqual(ColorSchedule.activePhase(preferences: preferences, minuteOfDay: 12 * 60), .daytime)
        XCTAssertEqual(ColorSchedule.activePhase(preferences: preferences, minuteOfDay: 20 * 60 + 30), .sunset)
        XCTAssertEqual(ColorSchedule.activePhase(preferences: preferences, minuteOfDay: 23 * 60), .bedtime)
        // Before wake, the most recently begun phase is still bedtime from the night before.
        XCTAssertEqual(ColorSchedule.activePhase(preferences: preferences, minuteOfDay: 6 * 60), .bedtime)
    }

    func testClampKeepsSunsetBetweenWakeAndBedtime() {
        let wake = 7 * 60, sunset = 20 * 60, bedtime = 21 * 60

        // A valid sunset time is left alone.
        XCTAssertEqual(
            ColorSchedule.clampedStartMinute(18 * 60, for: .sunset, wake: wake, sunset: sunset, bedtime: bedtime),
            18 * 60
        )
        // Dragged before wake -> snaps to just after wake.
        XCTAssertEqual(
            ColorSchedule.clampedStartMinute(6 * 60, for: .sunset, wake: wake, sunset: sunset, bedtime: bedtime, minGap: 15),
            wake + 15
        )
        // Dragged past bedtime -> snaps to just before bedtime.
        XCTAssertEqual(
            ColorSchedule.clampedStartMinute(23 * 60, for: .sunset, wake: wake, sunset: sunset, bedtime: bedtime, minGap: 15),
            bedtime - 15
        )
    }

    func testClampAllowsBedtimeAfterMidnight() {
        // Wake 10:15, sunset 20:00: a 2:30 AM bedtime is in cyclic order and stays put.
        let wake = 10 * 60 + 15, sunset = 20 * 60, bedtime = 2 * 60 + 30
        XCTAssertEqual(
            ColorSchedule.clampedStartMinute(2 * 60 + 30, for: .bedtime, wake: wake, sunset: sunset, bedtime: bedtime),
            2 * 60 + 30
        )
        // Bedtime dragged before sunset -> snaps to just after sunset.
        XCTAssertEqual(
            ColorSchedule.clampedStartMinute(19 * 60, for: .bedtime, wake: wake, sunset: sunset, bedtime: bedtime, minGap: 15),
            sunset + 15
        )
    }

    func testClockScheduleChoosesDayAndNight() {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.dayTemperature = 6500
        preferences.nightTemperature = 3200
        preferences.coolStartMinutes = 7 * 60
        preferences.warmStartMinutes = 21 * 60
        preferences.transitionMinutes = 0

        XCTAssertEqual(
            ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 12 * 60),
            6500
        )
        XCTAssertEqual(
            ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 23 * 60),
            3200
        )
    }

    func testThreePhaseScheduleHoldsEachPhaseTemperature() {
        let preferences = threePhasePreferences()

        // Midday -> Daytime, mid-evening -> Sunset, deep night -> Bedtime.
        XCTAssertEqual(ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 12 * 60), 6500)
        XCTAssertEqual(ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 20 * 60 + 30), 4000)
        XCTAssertEqual(ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 2 * 60), 3000)
    }

    func testThreePhaseScheduleInterpolatesAcrossEachTransition() {
        let preferences = threePhasePreferences()

        // Daytime -> Sunset fade (begins 19:00, 60 min): halfway at 19:30.
        XCTAssertEqual(ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 19 * 60 + 30), 5250)
        // Sunset -> Bedtime fade (begins 22:00): halfway at 22:30.
        XCTAssertEqual(ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 22 * 60 + 30), 3500)
        // Bedtime -> Daytime fade (begins at wake 07:00): halfway at 07:30.
        XCTAssertEqual(ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 7 * 60 + 30), 4750)
    }

    func testLongTransitionDoesNotSnapAtPhaseBoundary() {
        // Default phases put sunset (20:00) and bedtime (21:00) only 60 min apart. A fade
        // longer than that gap used to leave the sunset fade mid-way at 20:59 and then snap
        // to the bedtime fade-from value at 21:00 (~2300 K jump). The fade is now capped to
        // the gap, so the schedule stays continuous: no minute-to-minute step is large.
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.transitionMinutes = 240

        var previous = ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: -1)
        var maxStep = 0
        for minute in 0..<1440 {
            let value = ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: minute)
            maxStep = max(maxStep, abs(value - previous))
            previous = value
        }

        // Smooth fades change by at most a few hundred K per minute; the old snap was >2000.
        XCTAssertLessThan(maxStep, 200, "schedule should fade smoothly, not snap (max step \(maxStep) K/min)")

        // Specifically across the tight sunset→bedtime boundary.
        let before = ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 20 * 60 + 59)
        let after = ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 21 * 60)
        XCTAssertLessThan(abs(after - before), 200)
    }

    func testResolvedSetTimesUsesStoredAnchors() {
        var preferences = AppPreferences.defaults
        preferences.scheduleSource = .manualTimes
        preferences.coolStartMinutes = 400
        preferences.sunsetStartMinutes = 1100
        preferences.warmStartMinutes = 1300

        let resolved = ColorSchedule.resolved(preferences: preferences)

        XCTAssertFalse(resolved.followsSun)
        XCTAssertEqual(resolved.dayStartMinutes, 400)
        XCTAssertEqual(resolved.wakeMinutes, 400)
        XCTAssertEqual(resolved.sunsetMinutes, 1100)
        XCTAssertEqual(resolved.bedtimeStartMinutes, 1300)
        XCTAssertEqual(resolved.events.count, 3)
    }

    func testResolvedSolarDerivesEverythingFromSunAndWake() {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.scheduleSource = .solar
        preferences.latitude = "47.6"
        preferences.longitude = "-122.3"
        preferences.coolStartMinutes = 7 * 60   // the wake input
        preferences.warmStartMinutes = 23 * 60  // stored Set-times bedtime — ignored while solar
        preferences.sunsetStartMinutes = 0      // stored Set-times sunset — ignored while solar
        preferences.bedtimeLeadMinutes = 9 * 60
        preferences.morningStart = .sunrise

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var components = DateComponents()
        components.year = 2023
        components.month = 6
        components.day = 21
        components.hour = 12
        let date = calendar.date(from: components)!

        let resolved = ColorSchedule.resolved(preferences: preferences, date: date, calendar: calendar)

        XCTAssertTrue(resolved.followsSun)
        // Sunset and day start come from the sun (June 21 in Seattle: ~5:11 / ~21:11)…
        XCTAssertEqual(Double(resolved.sunsetMinutes), 21 * 60 + 11, accuracy: 25)
        XCTAssertEqual(Double(resolved.dayStartMinutes), 5 * 60 + 11, accuracy: 25)
        // …and bedtime is derived from the wake input, ignoring the stored bedtime anchor.
        XCTAssertEqual(resolved.wakeMinutes, 7 * 60)
        XCTAssertEqual(resolved.bedtimeStartMinutes, 22 * 60)
    }

    func testResolvedFallsBackToStoredAnchorsWithoutCoordinates() {
        var preferences = AppPreferences.defaults
        preferences.scheduleSource = .solar
        preferences.latitude = "not a number"

        let resolved = ColorSchedule.resolved(preferences: preferences)

        XCTAssertFalse(resolved.followsSun)
        XCTAssertEqual(resolved.dayStartMinutes, preferences.coolStartMinutes)
        XCTAssertEqual(resolved.sunsetMinutes, preferences.sunsetStartMinutes)
        XCTAssertEqual(resolved.bedtimeStartMinutes, preferences.warmStartMinutes)
    }

    // MARK: Follow-sunset resolution (docs/DESIGN.md)

    /// Seattle-winter-shaped day: wake 7:00, 9 h lead (bedtime 22:00), sunrise 7:57, sunset 16:25.
    private func winterSolar(morningStart: MorningStart) -> ResolvedSchedule {
        ColorSchedule.solarResolved(
            wakeMinutes: 7 * 60,
            bedtimeLeadMinutes: 9 * 60,
            morningStart: morningStart,
            sunriseMinutes: 7 * 60 + 57,
            sunsetMinutes: 16 * 60 + 25,
            transitionMinutes: 0
        )!
    }

    func testWinterMorningBridgesWakeToSunrise() {
        let schedule = winterSolar(morningStart: .sunrise)

        // f.lux's morning: bedtime ends at wake, but the screen only steps up to the *sunset*
        // color; full daytime waits for the real sunrise.
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 6 * 60 + 50), .bedtime)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 7 * 60 + 20), .sunset)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 8 * 60), .daytime)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 17 * 60), .sunset)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 23 * 60), .bedtime)
    }

    func testWakeTimeMorningSkipsTheBridge() {
        let schedule = winterSolar(morningStart: .wakeTime)

        XCTAssertEqual(schedule.dayStartMinutes, 7 * 60)
        XCTAssertEqual(schedule.events.count, 3)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 7 * 60 + 20), .daytime)
    }

    func testSummerWakeAfterSunriseEndsBedtimeAtSunrise() {
        let schedule = ColorSchedule.solarResolved(
            wakeMinutes: 7 * 60,
            bedtimeLeadMinutes: 9 * 60,
            morningStart: .sunrise,
            sunriseMinutes: 5 * 60 + 12,
            sunsetMinutes: 21 * 60 + 11,
            transitionMinutes: 0
        )!

        // No pre-dawn bridge: the sun is already up at wake. Daytime begins at sunrise —
        // "daytime is whenever the sun is up".
        XCTAssertFalse(schedule.sunsetSqueezed)
        XCTAssertEqual(schedule.events.count, 3)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 4 * 60), .bedtime)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 5 * 60 + 30), .daytime)
    }

    func testEarlyWakeSqueezesOutTheSunset() {
        // Wake 5:30 puts bedtime at 20:30, before the 21:11 sunset: bedtime wins over the sun
        // (f.lux's circadian-first rule) and the evening sunset phase disappears rather than
        // restarting mid-bedtime.
        let schedule = ColorSchedule.solarResolved(
            wakeMinutes: 5 * 60 + 30,
            bedtimeLeadMinutes: 9 * 60,
            morningStart: .sunrise,
            sunriseMinutes: 5 * 60 + 12,
            sunsetMinutes: 21 * 60 + 11,
            transitionMinutes: 0
        )!

        XCTAssertTrue(schedule.sunsetSqueezed)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 20 * 60 + 45), .bedtime)
        // After the (dropped) sunset time the phase must stay bedtime, not flip back to sunset.
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 21 * 60 + 30), .bedtime)
        // The sunset anchor survives for the UI (handle placement) even though its event is gone.
        XCTAssertEqual(schedule.sunsetMinutes, 21 * 60 + 11)
    }

    func testNightShiftWakeStillResolves() {
        // f.lux's documented advice to night workers is "shift your wake time" — a 23:00 wake
        // puts bedtime at 14:00 and the resolver must still produce a coherent day.
        let schedule = ColorSchedule.solarResolved(
            wakeMinutes: 23 * 60,
            bedtimeLeadMinutes: 9 * 60,
            morningStart: .wakeTime,
            sunriseMinutes: 7 * 60 + 57,
            sunsetMinutes: 16 * 60 + 25,
            transitionMinutes: 0
        )!

        XCTAssertEqual(schedule.bedtimeStartMinutes, 14 * 60)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 15 * 60), .bedtime)
        XCTAssertEqual(ColorSchedule.activePhase(schedule: schedule, minuteOfDay: 23 * 60 + 30), .daytime)
    }

    func testPolarDayHasNoSolarResolution() {
        XCTAssertNil(ColorSchedule.solarResolved(
            wakeMinutes: 7 * 60,
            bedtimeLeadMinutes: 9 * 60,
            morningStart: .sunrise,
            sunriseMinutes: nil,
            sunsetMinutes: nil,
            transitionMinutes: 45
        ))
    }

    func testBridgedDayFadesSmoothly() {
        // The 4-event winter day must stay continuous even with a fade longer than the
        // wake→sunrise gap — the same guarantee `testLongTransitionDoesNotSnapAtPhaseBoundary`
        // pins for the 3-anchor Set-times day.
        let schedule = ColorSchedule.solarResolved(
            wakeMinutes: 7 * 60,
            bedtimeLeadMinutes: 9 * 60,
            morningStart: .sunrise,
            sunriseMinutes: 7 * 60 + 57,
            sunsetMinutes: 16 * 60 + 25,
            transitionMinutes: 240
        )!
        let temperature = { (phase: ColorPhase) -> Int in
            switch phase {
            case .daytime: 6500
            case .sunset: 3400
            case .bedtime: 2700
            }
        }

        var previous = ColorSchedule.scheduledValue(schedule: schedule, minuteOfDay: -1, value: temperature)
        var maxStep = 0
        for minute in 0..<1440 {
            let value = ColorSchedule.scheduledValue(schedule: schedule, minuteOfDay: minute, value: temperature)
            maxStep = max(maxStep, abs(value - previous))
            previous = value
        }
        XCTAssertLessThan(maxStep, 200, "bridged day should fade smoothly (max step \(maxStep) K/min)")
    }

    func testScheduledPhaseMixSettledPhaseHasNoFade() {
        let schedule = ResolvedSchedule.setTimes(threePhasePreferences())
        // Late morning — well past the wake fade, so it's a single, settled phase.
        let mix = ColorSchedule.scheduledPhaseMix(schedule: schedule, minuteOfDay: 10 * 60)
        XCTAssertEqual(mix.from, .daytime)
        XCTAssertEqual(mix.to, .daytime)
        XCTAssertEqual(mix.progress, 1, accuracy: 0.0001)
    }

    func testScheduledPhaseMixBlendsThroughFade() {
        let schedule = ResolvedSchedule.setTimes(threePhasePreferences()) // sunset @ 19:00, fade 60
        // Halfway into the sunset fade: easing from the daytime color to the sunset color.
        let mid = ColorSchedule.scheduledPhaseMix(schedule: schedule, minuteOfDay: 19 * 60 + 30)
        XCTAssertEqual(mid.from, .daytime)
        XCTAssertEqual(mid.to, .sunset)
        XCTAssertEqual(mid.progress, 0.5, accuracy: 0.0001)

        // At the exact event minute the fade hasn't started — still fully the previous phase.
        let start = ColorSchedule.scheduledPhaseMix(schedule: schedule, minuteOfDay: 19 * 60)
        XCTAssertEqual(start.from, .daytime)
        XCTAssertEqual(start.to, .sunset)
        XCTAssertEqual(start.progress, 0, accuracy: 0.0001)
    }

    func testScheduledPhaseMixRidesTheSameTimelineAsScheduledValue() {
        // The fill color blends `from`→`to` by `progress`; this proves that blend lands on the
        // identical curve as the numeric schedule at every minute, so the shading tracks the warmth.
        let schedule = ResolvedSchedule.setTimes(threePhasePreferences())
        let values: [ColorPhase: Int] = [.daytime: 6000, .sunset: 4000, .bedtime: 2000]

        for minute in stride(from: 0, to: 1440, by: 7) {
            let numeric = ColorSchedule.scheduledValue(schedule: schedule, minuteOfDay: minute) { values[$0]! }
            let mix = ColorSchedule.scheduledPhaseMix(schedule: schedule, minuteOfDay: minute)
            let from = Double(values[mix.from]!)
            let blended = from + (Double(values[mix.to]!) - from) * mix.progress
            XCTAssertEqual(Double(numeric), blended, accuracy: 1.0, "minute \(minute)")
        }
    }

    private func threePhasePreferences() -> AppPreferences {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.dayTemperature = 6500
        preferences.sunsetTemperature = 4000
        preferences.nightTemperature = 3000
        preferences.coolStartMinutes = 7 * 60
        preferences.sunsetStartMinutes = 19 * 60
        preferences.warmStartMinutes = 22 * 60
        preferences.transitionMinutes = 60
        return preferences
    }
}
