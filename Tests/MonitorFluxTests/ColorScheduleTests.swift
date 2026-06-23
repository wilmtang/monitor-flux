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

    func testScheduledHardwareLevelHoldsDayThenNight() {
        var preferences = AppPreferences.defaults
        preferences.coolStartMinutes = 7 * 60     // wake / daytime begins
        preferences.sunsetStartMinutes = 20 * 60  // sunset begins
        preferences.warmStartMinutes = 21 * 60    // bedtime begins
        preferences.transitionMinutes = 0         // no fade -> hard hold

        // Midday holds the daytime target; deep night holds the night target.
        XCTAssertEqual(
            ColorSchedule.scheduledHardwareLevel(dayValue: 90, nightValue: 40, preferences: preferences, minuteOfDay: 12 * 60),
            90
        )
        XCTAssertEqual(
            ColorSchedule.scheduledHardwareLevel(dayValue: 90, nightValue: 40, preferences: preferences, minuteOfDay: 0),
            40
        )
    }

    func testScheduledHardwareLevelEasesAcrossSunset() {
        var preferences = AppPreferences.defaults
        preferences.coolStartMinutes = 7 * 60
        preferences.sunsetStartMinutes = 20 * 60
        preferences.warmStartMinutes = 21 * 60
        preferences.transitionMinutes = 45

        // Partway into the post-sunset fade, the level sits strictly between day and night.
        let level = ColorSchedule.scheduledHardwareLevel(
            dayValue: 90, nightValue: 40, preferences: preferences, minuteOfDay: 20 * 60 + 22
        )
        XCTAssertGreaterThan(level, 40)
        XCTAssertLessThan(level, 90)
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

    func testSolarScheduleReplacesSunriseAndSunsetAnchors() {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.scheduleSource = .solar
        preferences.latitude = "47.6"
        preferences.longitude = "-122.3"
        preferences.coolStartMinutes = 0   // placeholder manual values that solar replaces
        preferences.sunsetStartMinutes = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var components = DateComponents()
        components.year = 2023
        components.month = 6
        components.day = 21
        components.hour = 12
        let date = calendar.date(from: components)!

        let adjusted = ColorSchedule.solarAdjustedPreferences(preferences, date: date, calendar: calendar)

        XCTAssertEqual(Double(adjusted.coolStartMinutes), 5 * 60 + 11, accuracy: 25)
        XCTAssertEqual(Double(adjusted.sunsetStartMinutes), 21 * 60 + 11, accuracy: 25)
    }

    func testManualScheduleSourceLeavesAnchorsUnchanged() {
        var preferences = AppPreferences.defaults
        preferences.scheduleSource = .manualTimes
        preferences.coolStartMinutes = 400
        preferences.sunsetStartMinutes = 1100

        let adjusted = ColorSchedule.solarAdjustedPreferences(preferences)

        XCTAssertEqual(adjusted.coolStartMinutes, 400)
        XCTAssertEqual(adjusted.sunsetStartMinutes, 1100)
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
