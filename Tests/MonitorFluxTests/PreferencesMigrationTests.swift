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
}
