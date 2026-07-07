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
    }

    func testAppPreferencesDecodeKeepsModeWhenNoLegacyGamma() throws {
        let json = """
        {
          "colorMode": "clock",
          "dayTemperature": 6400,
          "nightTemperature": 3300
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        // No legacy `gammaEnabled` key → mode is left exactly as stored.
        XCTAssertEqual(preferences.colorMode, .clock)
        XCTAssertEqual(preferences.dayTemperature, 6400)
        XCTAssertEqual(preferences.nightTemperature, 3300)
    }

    func testLegacyGammaDisabledMigratesToOff() throws {
        // The old warmth master (`gammaEnabled`) is gone; a stored `false` folds into Off so an
        // upgrading user who had warmth suppressed stays suppressed, whatever their mode was.
        let json = """
        {
          "gammaEnabled": false,
          "colorMode": "clock"
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(preferences.colorMode, .off)
    }

    func testLegacyGammaEnabledLeavesModeAlone() throws {
        let json = """
        {
          "gammaEnabled": true,
          "colorMode": "manual"
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(preferences.colorMode, .manual)
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

    func testAppPreferencesDecodeAddsFollowSunsetDefaults() throws {
        // Payloads from before the f.lux-style Follow-sunset model omit both new keys; they
        // must land on f.lux's values (9 h lead, sunrise mornings), and an out-of-range
        // stored lead must clamp instead of resolving a nonsense day.
        let legacy = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.bedtimeLeadMinutes, 9 * 60)
        XCTAssertEqual(legacy.morningStart, .sunrise)

        let clamped = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(#"{"bedtimeLeadMinutes": 8000, "morningStart": "wakeTime"}"#.utf8)
        )
        XCTAssertEqual(clamped.bedtimeLeadMinutes, ControlRanges.bedtimeLeadMinutes.upperBound)
        XCTAssertEqual(clamped.morningStart, .wakeTime)
    }

    func testNewPreferencesDefaultsAreBackwardCompatible() throws {
        // Older payloads omit the volume / keyboard-control / dock fields entirely.
        let displayPreferences = try JSONDecoder().decode(DisplayPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(displayPreferences.hardwareVolume, 50)

        let appPreferences = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(appPreferences.keyboardControlEnabled)
        XCTAssertFalse(appPreferences.syncBrightnessAcrossDisplays)
        XCTAssertFalse(appPreferences.syncContrastAcrossDisplays)
        XCTAssertTrue(appPreferences.brightnessSyncRestore.isEmpty)
        XCTAssertTrue(appPreferences.contrastSyncRestore.isEmpty)
        // Show in Dock defaults OFF — a menu-bar-first app is an accessory by default, and
        // payloads saved before the field existed keep their no-Dock-icon behavior on upgrade.
        XCTAssertFalse(appPreferences.showInDock)
        XCTAssertFalse(appPreferences.fineAdjustmentsEnabled)
        XCTAssertFalse(appPreferences.hideNoExternalsHint)
        XCTAssertEqual(appPreferences.scheduleSource, .manualTimes)
        XCTAssertEqual(appPreferences.fontSizeStep, AppPreferences.defaultFontSizeStep)
        XCTAssertEqual(appPreferences.popupBackdropOpacity, AppPreferences.defaultPopupBackdropOpacity)
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

    func testOptionMediaBindingAndSyncSettingsRoundTrip() throws {
        var prefs = AppPreferences()
        prefs.fineAdjustmentsEnabled = true
        prefs.syncBrightnessAcrossDisplays = true
        prefs.syncContrastAcrossDisplays = true
        var display = DisplayPreferences()
        display.hardwareBrightness = 24
        display.gammaBrightness = 86
        display.scheduleBrightness = true
        display.hardwareContrast = 43
        display.scheduleContrast = true
        prefs.brightnessSyncRestore["display"] = DisplayBrightnessSyncRestore(display)
        prefs.contrastSyncRestore["display"] = DisplayContrastSyncRestore(display)
        prefs.hotkeys["brightnessUpFine"] = .media(
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, shift: true, option: true)
        )

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertTrue(decoded.fineAdjustmentsEnabled)
        XCTAssertTrue(decoded.syncBrightnessAcrossDisplays)
        XCTAssertTrue(decoded.syncContrastAcrossDisplays)
        XCTAssertEqual(decoded.brightnessSyncRestore["display"], DisplayBrightnessSyncRestore(display))
        XCTAssertEqual(decoded.contrastSyncRestore["display"], DisplayContrastSyncRestore(display))
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
        // The stale `gammaContrast` key (software contrast was removed) must simply be ignored.
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
          "fontSizeStep": 99,
          "popupBackdropOpacity": 3.5
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
        XCTAssertEqual(preferences.popupBackdropOpacity, 1.0)
    }

    func testLocationFieldsDefaultForLegacyPayloads() throws {
        // Payloads from before the location search must keep today's behavior: coordinates
        // follow the device (Core Location refreshes them each launch), no name, no dismissal.
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: "{}".data(using: .utf8)!)

        XCTAssertEqual(preferences.locationName, "")
        XCTAssertTrue(preferences.locationFollowsDevice)
        XCTAssertEqual(preferences.dismissedLocationMismatchKey, "")
    }

    func testLocationFieldsRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.locationName = "Tokyo, Japan"
        preferences.locationFollowsDevice = false
        preferences.dismissedLocationMismatchKey = "Asia/Tokyo|America/Los_Angeles"

        let decoded = try JSONDecoder().decode(
            AppPreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertEqual(decoded.locationName, "Tokyo, Japan")
        XCTAssertFalse(decoded.locationFollowsDevice)
        XCTAssertEqual(decoded.dismissedLocationMismatchKey, "Asia/Tokyo|America/Los_Angeles")
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
        prefs.colorMode = .off
        prefs.displayPreferences["external"] = {
            var display = DisplayPreferences()
            display.hardwareBrightness = 42
            display.gammaBrightness = 999
            return display
        }()

        let data = try PreferencesStore.exportData(prefs)
        let imported = try PreferencesStore.importData(data)

        XCTAssertEqual(imported.colorMode, .off)
        XCTAssertEqual(imported.displayPreferences["external"]?.hardwareBrightness, 42)
        XCTAssertEqual(
            imported.displayPreferences["external"]?.gammaBrightness,
            ControlRanges.gammaBrightnessPercent.upperBound
        )
        XCTAssertThrowsError(try PreferencesStore.importData(Data("not json".utf8)))
    }
}
