import XCTest
@testable import MonitorFlux

final class KeyboardCommandTests: XCTestCase {
    private let step = 6

    func testBrightnessKeysWithoutModifiersAdjustBrightness() {
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.brightnessUp, control: false, shift: false, step: step),
            .brightness(step)
        )
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.brightnessDown, control: false, shift: false, step: step),
            .brightness(-step)
        )
    }

    func testControlMakesBrightnessKeysAdjustContrast() {
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.brightnessUp, control: true, shift: false, step: step),
            .contrast(step)
        )
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.brightnessDown, control: true, shift: false, step: step),
            .contrast(-step)
        )
    }

    func testShiftMakesBrightnessKeysAdjustColorTemperature() {
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.brightnessUp, control: false, shift: true, step: step),
            .color(1)
        )
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.brightnessDown, control: false, shift: true, step: step),
            .color(-1)
        )
    }

    func testControlTakesPrecedenceOverShift() {
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.brightnessUp, control: true, shift: true, step: step),
            .contrast(step)
        )
    }

    func testVolumeKeysAdjustVolumeRegardlessOfModifiers() {
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.soundUp, control: true, shift: true, step: step),
            .volume(step)
        )
        XCTAssertEqual(
            KeyboardControlService.command(keyCode: MediaKey.soundDown, control: false, shift: false, step: step),
            .volume(-step)
        )
    }

    func testUnknownKeyIsNotHandled() {
        XCTAssertNil(KeyboardControlService.command(keyCode: 99, control: false, shift: false, step: step))
    }
}
