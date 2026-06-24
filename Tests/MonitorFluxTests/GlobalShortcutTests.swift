import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MonitorFlux

final class GlobalShortcutTests: XCTestCase {
    func testTwoGroupsSplitTheActions() {
        let underPointer = HotKeyAction.allCases.filter { $0.group == .underPointer }
        let builtIn = HotKeyAction.allCases.filter { $0.group == .builtIn }

        XCTAssertEqual(underPointer.count, 8)
        // Built-in set is brightness + contrast only (color is global; built-in has no volume).
        XCTAssertEqual(Set(builtIn.map(\.label)), ["Brightness up", "Brightness down", "Contrast up", "Contrast down"])
    }

    func testHotKeyIDsAreStableAndUnique() {
        // Built-in actions were appended, so the original eight keep their ids (and saved
        // shortcuts). Ids must also be unique so presses route correctly.
        XCTAssertEqual(HotKeyAction.brightnessUp.hotKeyID, 1)
        XCTAssertEqual(HotKeyAction.volumeDown.hotKeyID, 8)
        let ids = HotKeyAction.allCases.map(\.hotKeyID)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testSuggestedKeyboardShortcutsDoNotCollide() {
        let keys = HotKeyAction.allCases.map {
            "\($0.suggestedKeyboardShortcut.keyCode)-\($0.suggestedKeyboardShortcut.carbonModifiers)"
        }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testMediaShortcutsRepresentBuiltInKeyboardPath() {
        XCTAssertEqual(HotKeyAction.brightnessUp.mediaShortcut?.displayTokens, ["Brightness ↑"])
        XCTAssertEqual(HotKeyAction.contrastDown.mediaShortcut?.displayTokens, ["⌃", "Brightness ↓"])
        XCTAssertEqual(HotKeyAction.colorWarmer.mediaShortcut?.displayTokens, ["⇧", "Brightness ↓"])
        XCTAssertNil(HotKeyAction.volumeUp.mediaShortcut)
        XCTAssertNil(HotKeyAction.volumeDown.mediaShortcut)
        XCTAssertEqual(HotKeyAction.builtInBrightnessUp.mediaShortcut?.displayTokens, ["⌘", "Brightness ↑"])
        XCTAssertEqual(HotKeyAction.builtInContrastUp.mediaShortcut?.displayTokens, ["⌃", "⌘", "Brightness ↑"])
    }

    func testMediaShortcutParserReadsManagedKeyDownEvents() {
        let data1 = mediaKeyData1(keyCode: MediaKey.brightnessDown, keyState: 0x0A)
        let shortcut = ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.shift])

        XCTAssertEqual(shortcut, MediaKeyShortcut(keyCode: MediaKey.brightnessDown, shift: true))
    }

    func testMediaShortcutParserKeepsCommandModifier() {
        let data1 = mediaKeyData1(keyCode: MediaKey.brightnessUp, keyState: 0x0A)
        let shortcut = ShortcutRecorder.mediaShortcut(data1: data1, modifierFlags: [.control, .command])

        XCTAssertEqual(shortcut, MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true, command: true))
    }

    func testMediaShortcutParserIgnoresKeyUpAndUnknownKeys() {
        XCTAssertNil(ShortcutRecorder.mediaShortcut(
            data1: mediaKeyData1(keyCode: MediaKey.brightnessUp, keyState: 0x0B),
            modifierFlags: []
        ))
        XCTAssertNil(ShortcutRecorder.mediaShortcut(
            data1: mediaKeyData1(keyCode: 99, keyState: 0x0A),
            modifierFlags: []
        ))
    }

    func testRecorderBuildsCustomShortcutOnlyWhenModifierIsHeld() {
        let shortcut = ShortcutRecorder.recordedShortcut(
            keyCode: UInt16(kVK_ANSI_P),
            modifierFlags: [.control, .option]
        )

        XCTAssertEqual(shortcut?.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(shortcut?.carbonModifiers, UInt32(controlKey | optionKey))
        XCTAssertNil(ShortcutRecorder.recordedShortcut(keyCode: UInt16(kVK_ANSI_P), modifierFlags: []))
    }

    func testMediaShortcutCodableRoundTrip() throws {
        let original = MediaKeyShortcut(keyCode: MediaKey.brightnessDown, control: true, shift: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaKeyShortcut.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testShortcutBindingKeyboardCodableRoundTrip() throws {
        let binding = ShortcutBinding.keyboard(
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey | optionKey))
        )
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        XCTAssertEqual(decoded, binding)
    }

    func testShortcutBindingMediaCodableRoundTrip() throws {
        let binding = ShortcutBinding.media(
            MediaKeyShortcut(keyCode: MediaKey.soundUp, control: false, shift: true)
        )
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        XCTAssertEqual(decoded, binding)
    }

    func testShortcutBindingDisplayTokensDelegates() {
        let kb = ShortcutBinding.keyboard(
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey))
        )
        XCTAssertEqual(kb.displayTokens, ["⌘", "B"])

        let media = ShortcutBinding.media(
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true)
        )
        XCTAssertEqual(media.displayTokens, ["⌃", "Brightness ↑"])
        XCTAssertEqual(ShortcutBinding.disabled.displayTokens, [])
        XCTAssertTrue(ShortcutBinding.disabled.isDisabled)
    }

    private func mediaKeyData1(keyCode: Int, keyState: Int) -> Int {
        (keyCode << 16) | (keyState << 8)
    }
}
