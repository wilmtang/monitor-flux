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
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, command: true): .builtInBrightnessUp,
        ]

        let handled = service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false, command: true)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .builtInBrightnessUp)
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

    func testRecorderParsesModernBrightnessKeyByCode() {
        // The keyDown delivery path (modern Apple silicon) resolves the virtual key code to a
        // MediaKey code, then shares this parser — so it must apply the same Option / managed rules
        // as the NSSystemDefined path instead of falling through to a Carbon keyboard shortcut.
        let code = MediaKey.code(forVirtualKeyCode: MediaKey.brightnessUpVirtualKeyCode)!
        // Bare brightness key → a media binding (the key itself is the shortcut).
        XCTAssertEqual(
            ShortcutRecorder.mediaShortcut(code: code, modifierFlags: []),
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp)
        )
        // Command → a real binding modifier (built-in-display shortcut set).
        XCTAssertEqual(
            ShortcutRecorder.mediaShortcut(code: code, modifierFlags: [.command]),
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, command: true)
        )
        // Option belongs to macOS → nil, so the recorder passes it through instead of recording a
        // stray Carbon key-code-144 shortcut.
        XCTAssertNil(ShortcutRecorder.mediaShortcut(code: code, modifierFlags: [.option]))
        // A non-managed code is rejected.
        XCTAssertNil(ShortcutRecorder.mediaShortcut(code: 99, modifierFlags: [.command]))
    }

    func testModernBrightnessVirtualKeyCodesMapToMediaCodes() {
        // On Apple silicon the dedicated brightness keys come through as plain keyDown events with
        // these virtual key codes; they must normalize onto the brightness media-key codes.
        XCTAssertEqual(MediaKey.code(forVirtualKeyCode: MediaKey.brightnessUpVirtualKeyCode), MediaKey.brightnessUp)
        XCTAssertEqual(MediaKey.code(forVirtualKeyCode: MediaKey.brightnessDownVirtualKeyCode), MediaKey.brightnessDown)
        // Ordinary keys are ignored ('a' = 0, space = 49).
        XCTAssertNil(MediaKey.code(forVirtualKeyCode: 0))
        XCTAssertNil(MediaKey.code(forVirtualKeyCode: 49))
    }

    func testModernBrightnessKeyDispatchesThroughBrightnessBinding() {
        // A brightness key delivered as keyDown 144 normalizes to MediaKey.brightnessUp and fires
        // the bound action through the same path as the classic NSSystemDefined media key.
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        service.mediaBindings = [MediaKeyShortcut(keyCode: MediaKey.brightnessUp): .brightnessUp]

        let code = MediaKey.code(forVirtualKeyCode: MediaKey.brightnessUpVirtualKeyCode)!
        let handled = service.handle(keyCode: code, control: false, shift: false)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .brightnessUp)
    }

    func testModernBrightnessWithControlHitsContrastBinding() {
        // Control + brightness (the contrast combo) carries its modifier in the key event's flags,
        // so the normalized code plus control resolves to the contrast binding.
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        service.mediaBindings = [MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true): .contrastUp]

        let code = MediaKey.code(forVirtualKeyCode: MediaKey.brightnessUpVirtualKeyCode)!
        let handled = service.handle(keyCode: code, control: true, shift: false)

        XCTAssertTrue(handled)
        XCTAssertEqual(fired, .contrastUp)
    }
}
