import XCTest
@testable import MonitorFlux

@MainActor
final class MediaBindingDispatchTests: XCTestCase {
    func testMediaBindingMatchesBeforeBuiltIn() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        // Remap bare brightness-up to volume-up.
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp): .volumeUp,
        ]

        let handled = service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .volumeUp)
    }

    func testNoMediaBindingPassesThrough() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        service.mediaBindings = [:]

        let handled = service.handle(keyCode: MediaKey.soundUp, control: false, shift: false)

        XCTAssertFalse(handled)
        XCTAssertNil(fired)
    }

    func testMediaBindingWithModifiers() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        // Remap Control+BrightnessDown (normally contrast-down) to color-warmer.
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown, control: true): .colorWarmer,
        ]

        let handled = service.handle(keyCode: MediaKey.brightnessDown, control: true, shift: false)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .colorWarmer)
    }

    func testMediaBindingWithCommandModifier() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true, command: true): .builtInContrastUp,
        ]

        let handled = service.handle(keyCode: MediaKey.brightnessUp, control: true, shift: false, command: true)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .builtInContrastUp)
    }

    func testBindingPassesThroughWhenActionReportsUnhandled() {
        let service = KeyboardControlService()
        service.onAction = { _ in false }
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp): .brightnessUp,
        ]

        let handled = service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false)

        XCTAssertFalse(handled)
    }

    func testOptionModifierPassesThroughInRecorderParser() {
        let data1 = (MediaKey.brightnessUp << 16) | (0x0A << 8)
        // Option held → parser should return nil (pass through to macOS).
        XCTAssertNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.option]))
        // Option + Control → still nil (Option takes precedence).
        XCTAssertNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.option, .control]))
        // Command is a real binding modifier for the built-in-display shortcut set.
        XCTAssertEqual(
            ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.command]),
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, command: true)
        )
        // No special modifiers → should parse normally.
        XCTAssertNotNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: []))
        XCTAssertNotNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.control]))
    }
}
