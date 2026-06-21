import XCTest
@testable import MonitorFlux

final class SolarCalculatorTests: XCTestCase {
    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)!
    }

    func testEquatorEquinoxIsRoughlySixToSix() {
        let utc = TimeZone(identifier: "UTC")!
        let times = SolarCalculator.times(latitude: 0, longitude: 0, date: utcDate(2023, 3, 20), timeZone: utc)

        XCTAssertEqual(Double(try XCTUnwrap(times.sunriseMinutes)), 6 * 60, accuracy: 20)
        XCTAssertEqual(Double(try XCTUnwrap(times.sunsetMinutes)), 18 * 60, accuracy: 20)
    }

    func testSeattleSummerSolsticeIsALongDay() throws {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let times = SolarCalculator.times(latitude: 47.6, longitude: -122.3, date: utcDate(2023, 6, 21), timeZone: tz)

        let sunrise = try XCTUnwrap(times.sunriseMinutes)
        let sunset = try XCTUnwrap(times.sunsetMinutes)
        XCTAssertLessThan(sunrise, sunset)
        // Almanac: ~05:11 sunrise, ~21:11 sunset PDT.
        XCTAssertEqual(Double(sunrise), 5 * 60 + 11, accuracy: 25)
        XCTAssertEqual(Double(sunset), 21 * 60 + 11, accuracy: 25)
    }

    func testPolarSummerHasNoSunset() {
        let utc = TimeZone(identifier: "UTC")!
        let times = SolarCalculator.times(latitude: 78, longitude: 15, date: utcDate(2023, 6, 21), timeZone: utc)

        XCTAssertNil(times.sunriseMinutes)
        XCTAssertNil(times.sunsetMinutes)
    }

    func testPolarWinterHasNoSunrise() {
        let utc = TimeZone(identifier: "UTC")!
        let times = SolarCalculator.times(latitude: 78, longitude: 15, date: utcDate(2023, 12, 21), timeZone: utc)

        XCTAssertNil(times.sunriseMinutes)
        XCTAssertNil(times.sunsetMinutes)
    }
}
