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

    func testNewPreferencesDefaultsAreBackwardCompatible() throws {
        // Older payloads omit the volume / keyboard-control / dock fields entirely.
        let displayPreferences = try JSONDecoder().decode(DisplayPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(displayPreferences.hardwareVolume, 50)

        let appPreferences = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(appPreferences.keyboardControlEnabled)
        XCTAssertFalse(appPreferences.showInDock)
        XCTAssertFalse(appPreferences.fineAdjustmentsEnabled)
        XCTAssertEqual(appPreferences.scheduleSource, .manualTimes)
        XCTAssertEqual(appPreferences.fontSizeStep, AppPreferences.defaultFontSizeStep)
    }

    func testMediaBindingsSavedBeforeOptionExistedStillDecode() throws {
        // Media bindings persisted before the `option` field must decode with option = false.
        // A synthesized decoder would throw on the missing key — and because `decodeHotkeys`
        // falls back to the legacy format on any error, that would silently wipe every custom
        // shortcut the user recorded.
        let json = """
        {
          "hotkeys": {
            "contrastUp": {"media": {"_0": {"keyCode": 2, "control": true, "shift": false, "command": false}}}
          }
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(
            preferences.hotkeys["contrastUp"],
            .media(MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true))
        )
        XCTAssertEqual(preferences.hotkeys["contrastUp"]?.asMedia?.option, false)
    }

    func testOptionMediaBindingRoundTrips() throws {
        var prefs = AppPreferences()
        prefs.fineAdjustmentsEnabled = true
        prefs.hotkeys["brightnessUpFine"] = .media(
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, shift: true, option: true)
        )

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertTrue(decoded.fineAdjustmentsEnabled)
        XCTAssertEqual(
            decoded.hotkeys["brightnessUpFine"],
            .media(MediaKeyShortcut(keyCode: MediaKey.brightnessUp, shift: true, option: true))
        )
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
          "transitionMinutes": 999,
          "fontSizeStep": 99
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(preferences.manualTemperature, ControlRanges.kelvin.lowerBound)
        XCTAssertEqual(preferences.dayTemperature, ControlRanges.kelvin.upperBound)
        XCTAssertEqual(preferences.nightTemperature, ControlRanges.kelvin.lowerBound)
        XCTAssertEqual(preferences.warmStartMinutes, ControlRanges.minuteOfDay.upperBound)
        XCTAssertEqual(preferences.coolStartMinutes, ControlRanges.minuteOfDay.lowerBound)
        XCTAssertEqual(preferences.transitionMinutes, ControlRanges.transitionMinutes.upperBound)
        XCTAssertEqual(preferences.fontSizeStep, AppPreferences.fontSizeStepRange.upperBound)
    }

    func testLegacyGlobalShortcutHotkeysDecodeAsKeyboardBindings() throws {
        // Old format: hotkeys are bare GlobalShortcut values (keyCode + carbonModifiers).
        let json = """
        {
          "hotkeys": {
            "brightnessUp": {"keyCode": 30, "carbonModifiers": 4352}
          }
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        let binding = preferences.hotkeys["brightnessUp"]
        XCTAssertNotNil(binding)
        if case .keyboard(let shortcut) = binding {
            XCTAssertEqual(shortcut.keyCode, 30)
            XCTAssertEqual(shortcut.carbonModifiers, 4352)
        } else {
            XCTFail("Expected .keyboard binding, got \(String(describing: binding))")
        }
    }

    func testNewShortcutBindingHotkeysRoundTrip() throws {
        var prefs = AppPreferences()
        prefs.hotkeys["volumeUp"] = .media(MediaKeyShortcut(keyCode: MediaKey.soundUp))
        prefs.hotkeys["brightnessUp"] = .keyboard(GlobalShortcut(keyCode: 30, carbonModifiers: 4352))
        prefs.hotkeys["contrastUp"] = .disabled

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(decoded.hotkeys["volumeUp"], .media(MediaKeyShortcut(keyCode: MediaKey.soundUp)))
        XCTAssertEqual(decoded.hotkeys["brightnessUp"], .keyboard(GlobalShortcut(keyCode: 30, carbonModifiers: 4352)))
        XCTAssertEqual(decoded.hotkeys["contrastUp"], .disabled)
    }

    func testPreferencesStoreExportImportRoundTripsNormalizedJSON() throws {
        var prefs = AppPreferences()
        prefs.gammaEnabled = false
        prefs.displayPreferences["external"] = {
            var display = DisplayPreferences()
            display.hardwareBrightness = 42
            display.gammaBrightness = 999
            return display
        }()

        let data = try PreferencesStore.exportData(prefs)
        let imported = try PreferencesStore.importData(data)

        XCTAssertEqual(imported.gammaEnabled, false)
        XCTAssertEqual(imported.displayPreferences["external"]?.hardwareBrightness, 42)
        XCTAssertEqual(
            imported.displayPreferences["external"]?.gammaBrightness,
            ControlRanges.gammaBrightnessPercent.upperBound
        )
        XCTAssertThrowsError(try PreferencesStore.importData(Data("not json".utf8)))
    }
}
