import XCTest
@testable import MonitorFlux

final class GammaCompositorTests: XCTestCase {
    func testNeutralAdjustmentLeavesMidValueUntouched() {
        let value = GammaCompositor.adjustedValue(
            0.5,
            channelMultiplier: 1,
            brightnessPercent: 100,
            contrastPercent: 100
        )

        XCTAssertEqual(value, 0.5, accuracy: 0.0001)
    }

    func testBrightnessAndContrastAreComposedIntoOneValue() {
        let value = GammaCompositor.adjustedValue(
            0.7,
            channelMultiplier: 1,
            brightnessPercent: 80,
            contrastPercent: 125
        )

        XCTAssertEqual(value, 0.6, accuracy: 0.0001)
    }

    func testWarmTemperatureReducesBlueMoreThanRed() {
        let multipliers = GammaCompositor.multipliers(for: GammaAdjustment(
            temperature: 3400,
            brightnessPercent: 100,
            contrastPercent: 100
        ))

        XCTAssertEqual(multipliers.red, 1, accuracy: 0.0001)
        XCTAssertLessThan(multipliers.blue, multipliers.green)
        XCTAssertLessThan(multipliers.green, multipliers.red)
    }
}
