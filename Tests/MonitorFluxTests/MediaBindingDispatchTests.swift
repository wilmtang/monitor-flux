// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

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

    func testStopClearsOwnedKeyState() {
        let service = KeyboardControlService()
        service.onAction = { _ in true }
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp): .brightnessUp,
        ]

        XCTAssertTrue(service.handleKeyDown(
            keyCode: MediaKey.brightnessUp,
            control: false,
            shift: false,
            command: false
        ))
        service.stop()

        XCTAssertFalse(service.consumeKeyUp(keyCode: MediaKey.brightnessUp))
    }

    func testOptionModifierRecordsInRecorderParser() {
        let data1 = (MediaKey.brightnessUp << 16) | (0x0A << 8)
        // ⌥ records like any other modifier — it's how custom fine-adjustment combos are
        // assigned. (Unbound ⌥ combos still pass through to macOS at runtime; that's the
        // tap's job, not the recorder's.)
        XCTAssertEqual(
            ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.option]),
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, option: true)
        )
        XCTAssertEqual(
            ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.option, .control]),
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true, option: true)
        )
        // Command is a real binding modifier for the built-in-display shortcut set.
        XCTAssertEqual(
            ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.command]),
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, command: true)
        )
        // No special modifiers → should parse normally.
        XCTAssertNotNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: []))
        XCTAssertNotNil(ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.control]))
    }

    func testOptionBindingDispatchesOnlyWhenOptionHeld() {
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp): .brightnessUp,
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, option: true): .brightnessUpFine,
        ]

        XCTAssertTrue(service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false, option: true))
        XCTAssertEqual(fired, .brightnessUpFine)

        fired = nil
        XCTAssertTrue(service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false))
        XCTAssertEqual(fired, .brightnessUp)
    }

    func testUnboundOptionComboPassesThrough() {
        // Fine adjustments off (no ⌥ bindings registered): ⌥ + brightness must reach macOS —
        // it opens Displays settings, and ⌥⇧ is the native built-in fine step.
        let service = KeyboardControlService()
        var fired: HotKeyAction?
        service.onAction = { fired = $0; return true }
        service.mediaBindings = [
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp): .brightnessUp,
        ]

        XCTAssertFalse(service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: false, option: true))
        XCTAssertFalse(service.handle(keyCode: MediaKey.brightnessUp, control: false, shift: true, option: true))
        XCTAssertNil(fired)
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
        // Option resolves to a media binding too (fine-adjustment combos) — never to a stray
        // Carbon key-code-144 keyboard shortcut.
        XCTAssertEqual(
            ShortcutRecorder.mediaShortcut(code: code, modifierFlags: [.option]),
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, option: true)
        )
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
