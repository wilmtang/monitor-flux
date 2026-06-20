import XCTest
import CoreGraphics
@testable import MonitorFlux

final class GammaPlanTests: XCTestCase {
    func testDisabledGammaPlansNoDisplayWrites() {
        let displays = [makeDisplay(id: 1)]
        var preferences = AppPreferences.defaults
        preferences.gammaEnabled = false

        XCTAssertTrue(GammaPlan.adjustments(displays: displays, preferences: preferences).isEmpty)
    }

    func testNeutralGammaPlansNoDisplayWrites() {
        let display = makeDisplay(id: 1)
        var preferences = AppPreferences.defaults
        preferences.colorMode = .off
        preferences.displayPreferences[display.key] = DisplayPreferences()

        XCTAssertTrue(GammaPlan.adjustments(displays: [display], preferences: preferences).isEmpty)
    }

    func testGammaBrightnessAndWarmthAreComposedInOneAdjustment() {
        let display = makeDisplay(id: 1)
        var displayPreferences = DisplayPreferences()
        displayPreferences.gammaBrightness = 80
        displayPreferences.gammaContrast = 120

        var preferences = AppPreferences.defaults
        preferences.colorMode = .manual
        preferences.manualTemperature = 3400
        preferences.displayPreferences[display.key] = displayPreferences

        let adjustment = GammaPlan.adjustments(displays: [display], preferences: preferences)[display.id]

        XCTAssertEqual(adjustment?.temperature, 3400)
        XCTAssertEqual(adjustment?.brightnessPercent, 80)
        XCTAssertEqual(adjustment?.contrastPercent, 120)
    }

    private func makeDisplay(id: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(
            id: id,
            name: "Display \(id)",
            frameDescription: "100 x 100 @ (0, 0)",
            isBuiltIn: false,
            isOnline: true
        )
    }
}
