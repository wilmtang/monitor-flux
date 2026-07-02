import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MonitorFlux

final class GlobalShortcutTests: XCTestCase {
    func testTwoGroupsSplitTheActions() {
        let underPointer = HotKeyAction.allCases.filter { $0.group == .underPointer && !$0.isFine }
        let builtIn = HotKeyAction.allCases.filter { $0.group == .builtIn && !$0.isFine }

        XCTAssertEqual(underPointer.count, 8)
        // Built-in set is brightness only: the panel has no contrast control, color is global,
        // and the built-in has no volume.
        XCTAssertEqual(Set(builtIn.map(\.label)), ["Brightness up", "Brightness down"])
    }

    func testFineVariantsMirrorTheirBaseActions() {
        let fine = HotKeyAction.allCases.filter(\.isFine)
        // Every adjustable control except volume (macOS already does fine system volume
        // with ⌥⇧) has a small-step variant.
        XCTAssertEqual(fine.count, 8)
        for action in fine {
            XCTAssertFalse(action.baseAction.isFine)
            XCTAssertEqual(action.group, action.baseAction.group, "\(action) group must match its base")
            XCTAssertTrue(action.label.hasPrefix(action.baseAction.label), "\(action) label should extend the base label")
        }
        // Base actions are their own base.
        XCTAssertEqual(HotKeyAction.brightnessUp.baseAction, .brightnessUp)
        XCTAssertEqual(HotKeyAction.brightnessUpFine.baseAction, .brightnessUp)
        XCTAssertEqual(HotKeyAction.builtInBrightnessDownFine.baseAction, .builtInBrightnessDown)
    }

    func testFineMediaDefaultsAreBaseComboPlusOption() {
        // The fine default is the base media combo with ⌥ added — the discoverable rule the
        // Settings caption promises ("hold Option for small steps").
        XCTAssertEqual(
            HotKeyAction.brightnessUpFine.mediaShortcut,
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, option: true)
        )
        XCTAssertEqual(
            HotKeyAction.contrastDownFine.mediaShortcut,
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown, control: true, option: true)
        )
        XCTAssertEqual(
            HotKeyAction.colorWarmerFine.mediaShortcut,
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown, shift: true, option: true)
        )
        XCTAssertEqual(
            HotKeyAction.builtInBrightnessUpFine.mediaShortcut,
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, command: true, option: true)
        )
        XCTAssertEqual(
            HotKeyAction.builtInBrightnessUpFine.mediaShortcut?.displayTokens,
            ["⌥", "⌘", "Brightness ↑"]
        )
    }

    func testHotKeyIDsAreStableAndUnique() {
        // Built-in actions were appended, so the original eight keep their ids (and saved
        // shortcuts); the fine variants were appended after those. Ids must also be unique
        // so presses route correctly.
        XCTAssertEqual(HotKeyAction.brightnessUp.hotKeyID, 1)
        XCTAssertEqual(HotKeyAction.volumeDown.hotKeyID, 8)
        XCTAssertEqual(HotKeyAction.builtInBrightnessDown.hotKeyID, 10)
        XCTAssertEqual(HotKeyAction.brightnessUpFine.hotKeyID, 11)
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
