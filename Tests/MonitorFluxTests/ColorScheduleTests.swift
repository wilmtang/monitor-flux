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

    func testClockScheduleInterpolatesAcrossWarmTransition() {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.dayTemperature = 6500
        preferences.nightTemperature = 3500
        preferences.warmStartMinutes = 21 * 60
        preferences.coolStartMinutes = 7 * 60
        preferences.transitionMinutes = 60

        XCTAssertEqual(
            ColorSchedule.scheduledTemperature(preferences: preferences, minuteOfDay: 21 * 60 + 30),
            5000
        )
    }
}
