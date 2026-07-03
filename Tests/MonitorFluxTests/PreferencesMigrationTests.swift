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
        // Show in Dock defaults ON — including for payloads saved before the field existed.
        XCTAssertTrue(appPreferences.showInDock)
        XCTAssertFalse(appPreferences.fineAdjustmentsEnabled)
        XCTAssertFalse(appPreferences.hideNoExternalsHint)
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

    func testLegacySoftwareDimmingOptInSeedsAutomaticMode() throws {
        // Pre-dimming-mode payloads gated software dimming behind `gammaControlsEnabled`.
        // An explicit true (non-DDC panels, or hand-enabled) becomes Automatic, keeping the
        // stored software-brightness value live.
        let json = """
        {
          "gammaControlsEnabled": true,
          "gammaBrightness": 80
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(DisplayPreferences.self, from: json)

        XCTAssertEqual(preferences.dimmingMode, .automatic)
        XCTAssertEqual(preferences.gammaBrightness, 80)
    }

    func testLegacyDisabledSoftwareDimmingResetsStaleGammaValue() throws {
        // With the gate gone the value is the state: a sub-100 gamma that sat inert behind
        // `gammaControlsEnabled: false` must not start dimming the screen on upgrade. The
        // mode stays unset so the per-display-kind default applies.
        let json = """
        {
          "gammaControlsEnabled": false,
          "gammaBrightness": 60
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(DisplayPreferences.self, from: json)

        XCTAssertNil(preferences.dimmingMode)
        XCTAssertEqual(preferences.gammaBrightness, 100)
    }

    func testExplicitDimmingModeWinsOverLegacyGate() throws {
        let json = """
        {
          "dimmingMode": "hardware",
          "gammaControlsEnabled": true,
          "gammaBrightness": 80
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(DisplayPreferences.self, from: json)

        XCTAssertEqual(preferences.dimmingMode, .hardware)
        XCTAssertEqual(preferences.gammaBrightness, 80)
    }

    func testDimmingModeDefaultsUnsetAndRoundTrips() throws {
        // Fresh payloads carry neither key: the mode stays unset (resolved per display kind)
        // and the floor stays at the safety default.
        let empty = try JSONDecoder().decode(DisplayPreferences.self, from: Data("{}".utf8))
        XCTAssertNil(empty.dimmingMode)
        XCTAssertFalse(empty.dimToBlack)

        var preferences = DisplayPreferences()
        preferences.dimmingMode = .software
        preferences.dimToBlack = true

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        XCTAssertEqual(decoded.dimmingMode, .software)
        XCTAssertTrue(decoded.dimToBlack)

        // The legacy gate is decode-only — new payloads must not re-encode it.
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(keys["gammaControlsEnabled"])
    }

    func testDimmingModeResolutionIsBinaryOnTheBuiltIn() {
        // Externals: unset defaults to Automatic (hybrid); explicit choices stick.
        XCTAssertEqual(DimmingMode.resolved(nil, isBuiltIn: false), .automatic)
        XCTAssertEqual(DimmingMode.resolved(.hardware, isBuiltIn: false), .hardware)
        XCTAssertEqual(DimmingMode.resolved(.software, isBuiltIn: false), .software)
        XCTAssertEqual(DimmingMode.resolved(.automatic, isBuiltIn: false), .automatic)

        // Built-in: defaults to its real backlight. Only an explicit .software choice (the
        // Advanced toggle) dims in software; unset, .hardware, and a legacy-migrated .automatic
        // (from the old gammaControlsEnabled gate, which couldn't see the display kind) all
        // resolve to hardware — the built-in never silently starts in software. Never hybrid.
        XCTAssertEqual(DimmingMode.resolved(nil, isBuiltIn: true), .hardware)
        XCTAssertEqual(DimmingMode.resolved(.hardware, isBuiltIn: true), .hardware)
        XCTAssertEqual(DimmingMode.resolved(.software, isBuiltIn: true), .software)
        XCTAssertEqual(DimmingMode.resolved(.automatic, isBuiltIn: true), .hardware)
    }

    func testLegacyGammaGateOnBuiltInResolvesToHardware() throws {
        // The bug this guards: an old build seeded `gammaControlsEnabled: true` on the built-in
        // (it has no DDC path), which the decoder migrates to `.automatic`. Resolved for the
        // built-in that must land on hardware — the backlight — not software dimming.
        let json = Data("""
        {
          "gammaControlsEnabled": true
        }
        """.utf8)

        let preferences = try JSONDecoder().decode(DisplayPreferences.self, from: json)
        XCTAssertEqual(preferences.dimmingMode, .automatic)
        XCTAssertEqual(DimmingMode.resolved(preferences.dimmingMode, isBuiltIn: true), .hardware)
        // An external with the same legacy gate still gets hybrid.
        XCTAssertEqual(DimmingMode.resolved(preferences.dimmingMode, isBuiltIn: false), .automatic)
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
