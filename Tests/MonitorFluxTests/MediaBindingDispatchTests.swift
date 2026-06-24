import XCTest
@testable import MonitorFlux

@MainActor
final class MediaBindingDispatchTests: XCTestCase {
    func testMediaBindingMatchesBeforeBuiltIn() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0 }
        // Remap bare brightness-up to volume-up.
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp): .volumeUp,
        ]

        let handled = service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .volumeUp)
    }

    func testNoMediaBindingFallsBackToBuiltIn() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0 }
        service.mediaBindings = [:]

        // Without a store, the built-in path returns false (no store to adjust), but the
        // key point is that onAction was NOT called — it fell through to the built-in mapping.
        _ = service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false)

        XCTAssertNil(fired)
    }

    func testMediaBindingWithModifiers() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0 }
        // Remap Control+BrightnessDown (normally contrast-down) to color-warmer.
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown, control: true): .colorWarmer,
        ]

        let handled = service.handle(keyCode: MediaKey.brightnessDown, control: true, shift: false)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .colorWarmer)
    }

    func testOptionModifierPassesThroughInRecorderParser() {
        let data1 = (MediaKey.brightnessUp << 16) | (0x0A << 8)
        // Option held → parser should return nil (pass through to macOS).
        XCTAssertNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.option]))
        // Command held → same.
        XCTAssertNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.command]))
        // Option + Control → still nil (Option takes precedence).
        XCTAssertNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.option, .control]))
        // No special modifiers → should parse normally.
        XCTAssertNotNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: []))
        XCTAssertNotNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.control]))
    }
}
