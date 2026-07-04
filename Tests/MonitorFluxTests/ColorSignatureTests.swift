import XCTest
@testable import MonitorFlux

/// `AppStore` skips the (main-thread) gamma recompute when a preference change doesn't
/// alter `colorSignature`. These tests pin down exactly which fields gate that recompute,
/// so a hardware-only drag stays smooth and a color change is never silently dropped.
final class ColorSignatureTests: XCTestCase {
    private let displayKey = "display-1"

    private func preferencesWithDisplay() -> AppPreferences {
        var preferences = AppPreferences()
        preferences.displayPreferences[displayKey] = DisplayPreferences()
        return preferences
    }

    func testHardwareValuesDoNotAffectColorSignature() {
        var before = preferencesWithDisplay()
        before.displayPreferences[displayKey]?.hardwareBrightness = 50
        before.displayPreferences[displayKey]?.hardwareContrast = 50
        before.displayPreferences[displayKey]?.hardwareVolume = 50
        before.displayPreferences[displayKey]?.ddcDisplayIndex = 1

        var after = before
        after.displayPreferences[displayKey]?.hardwareBrightness = 90
        after.displayPreferences[displayKey]?.hardwareContrast = 20
        after.displayPreferences[displayKey]?.hardwareVolume = 0
        after.displayPreferences[displayKey]?.ddcDisplayIndex = 2

        XCTAssertEqual(
            before.colorSignature,
            after.colorSignature,
            "A brightness/contrast/volume drag must not trigger a gamma recompute."
        )
    }

    func testFontSizeStepDoesNotAffectColorSignature() {
        let before = preferencesWithDisplay()
        var after = before
        after.fontSizeStep = AppPreferences.fontSizeStepRange.upperBound

        XCTAssertEqual(before.colorSignature, after.colorSignature)
    }

    func testPopupBackdropOpacityDoesNotAffectColorSignature() {
        // The General-pane slider drags this continuously; a gamma recompute per tick
        // would both stutter the drag and hammer the color pipeline.
        let before = preferencesWithDisplay()
        var after = before
        after.popupBackdropOpacity = 0.2

        XCTAssertEqual(before.colorSignature, after.colorSignature)
    }

    func testFollowSunsetInputsChangeColorSignature() {
        // Bedtime lead and the morning rule reshape the resolved solar day, so editing them
        // must trigger a gamma recompute like any other schedule-shape change.
        let before = preferencesWithDisplay()

        var lead = before
        lead.bedtimeLeadMinutes = 8 * 60
        XCTAssertNotEqual(before.colorSignature, lead.colorSignature)

        var morning = before
        morning.morningStart = .wakeTime
        XCTAssertNotEqual(before.colorSignature, morning.colorSignature)
    }

    func testManualTemperatureChangesColorSignature() {
        var before = preferencesWithDisplay()
        before.manualTemperature = 4000
        var after = before
        after.manualTemperature = 3500

        XCTAssertNotEqual(before.colorSignature, after.colorSignature)
    }

    func testTogglingGammaChangesColorSignature() {
        var before = preferencesWithDisplay()
        before.gammaEnabled = true
        var after = before
        after.gammaEnabled = false

        XCTAssertNotEqual(before.colorSignature, after.colorSignature)
    }

    func testPerDisplayGammaFieldsChangeColorSignature() {
        let before = preferencesWithDisplay()

        var gammaBrightness = before
        gammaBrightness.displayPreferences[displayKey]?.gammaBrightness = 60
        XCTAssertNotEqual(before.colorSignature, gammaBrightness.colorSignature)

        var colorEnabled = before
        colorEnabled.displayPreferences[displayKey]?.colorEnabled = false
        XCTAssertNotEqual(before.colorSignature, colorEnabled.colorSignature)
    }

    func testDimmingRoutingFieldsDoNotAffectColorSignature() {
        // The dimming mode and the dim-to-black floor only route the unified control — the
        // gamma output is the gammaBrightness *value*, so changing them must not trigger a
        // gamma recompute.
        let before = preferencesWithDisplay()

        var mode = before
        mode.displayPreferences[displayKey]?.dimmingMode = .software
        XCTAssertEqual(before.colorSignature, mode.colorSignature)

        var floor = before
        floor.displayPreferences[displayKey]?.dimToBlack = true
        XCTAssertEqual(before.colorSignature, floor.colorSignature)
    }

    func testScheduleAnchorsChangeColorSignature() {
        let before = preferencesWithDisplay()

        var temperatures = before
        temperatures.dayTemperature = before.dayTemperature - 200
        XCTAssertNotEqual(before.colorSignature, temperatures.colorSignature)

        var times = before
        times.sunsetStartMinutes = before.sunsetStartMinutes + 30
        XCTAssertNotEqual(before.colorSignature, times.colorSignature)

        var source = before
        source.scheduleSource = before.scheduleSource == .solar ? .manualTimes : .solar
        XCTAssertNotEqual(before.colorSignature, source.colorSignature)
    }
}
