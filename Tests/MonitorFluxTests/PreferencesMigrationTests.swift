import XCTest
@testable import MonitorFlux

final class PreferencesMigrationTests: XCTestCase {
    func testDisplayPreferencesDecodeLegacyHardwareKeys() throws {
        let json = """
        {
          "colorEnabled": true,
          "ddcDisplayIndex": 2,
          "brightness": 42,
          "contrast": 63
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(DisplayPreferences.self, from: json)

        XCTAssertEqual(preferences.hardwareBrightness, 42)
        XCTAssertEqual(preferences.hardwareContrast, 63)
        XCTAssertEqual(preferences.gammaBrightness, 100)
        XCTAssertEqual(preferences.gammaContrast, 100)
    }

    func testAppPreferencesDecodeAddsGammaDefaults() throws {
        let json = """
        {
          "colorMode": "clock",
          "dayTemperature": 6400,
          "nightTemperature": 3300
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertTrue(preferences.gammaEnabled)
        XCTAssertEqual(preferences.dayTemperature, 6400)
        XCTAssertEqual(preferences.nightTemperature, 3300)
    }

    func testAppPreferencesDecodeAddsSunsetDefaults() throws {
        // Legacy payloads predate the three-phase model and omit the sunset keys.
        let json = """
        {
          "colorMode": "clock",
          "dayTemperature": 6400,
          "nightTemperature": 3000
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(preferences.sunsetTemperature, 3400)
        XCTAssertEqual(preferences.sunsetStartMinutes, 20 * 60)
        XCTAssertEqual(preferences.nightTemperature, 3000)
    }

    func testDisplayPreferencesClampDecodedValues() throws {
        let json = """
        {
          "ddcDisplayIndex": 99,
          "hardwareBrightness": -10,
          "hardwareContrast": 250,
          "gammaBrightness": 999,
          "gammaContrast": -25
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(DisplayPreferences.self, from: json)

        XCTAssertEqual(preferences.ddcDisplayIndex, ControlRanges.ddcDisplayIndex.upperBound)
        XCTAssertEqual(preferences.hardwareBrightness, ControlRanges.hardwarePercent.lowerBound)
        XCTAssertEqual(preferences.hardwareContrast, ControlRanges.hardwarePercent.upperBound)
        XCTAssertEqual(preferences.gammaBrightness, ControlRanges.gammaBrightnessPercent.upperBound)
        XCTAssertEqual(preferences.gammaContrast, ControlRanges.gammaContrastPercent.lowerBound)
    }

    func testAppPreferencesClampDecodedScheduleValues() throws {
        let json = """
        {
          "manualTemperature": 100,
          "dayTemperature": 9000,
          "nightTemperature": 0,
          "warmStartMinutes": 9999,
          "coolStartMinutes": -30,
          "transitionMinutes": 999
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(preferences.manualTemperature, ControlRanges.kelvin.lowerBound)
        XCTAssertEqual(preferences.dayTemperature, ControlRanges.kelvin.upperBound)
        XCTAssertEqual(preferences.nightTemperature, ControlRanges.kelvin.lowerBound)
        XCTAssertEqual(preferences.warmStartMinutes, ControlRanges.minuteOfDay.upperBound)
        XCTAssertEqual(preferences.coolStartMinutes, ControlRanges.minuteOfDay.lowerBound)
        XCTAssertEqual(preferences.transitionMinutes, ControlRanges.transitionMinutes.upperBound)
    }
}
