// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

final class HotkeyBindingsTests: XCTestCase {
    func testNoCustomBindingsActivateEveryBaseMediaDefault() {
        let maps = HotkeyBindings.maps(bindings: [:], fineAdjustmentsEnabled: false)

        XCTAssertTrue(maps.carbon.isEmpty)
        // Every base action with a built-in media combo is routed; volume has none by default.
        XCTAssertEqual(maps.media[MediaKeyShortcut(keyCode: MediaKey.brightnessUp)], .brightnessUp)
        XCTAssertEqual(
            maps.media[MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true)],
            .contrastUp
        )
        XCTAssertNil(maps.media.values.first { $0 == .volumeUp })
        // Fine (⌥) variants stay with macOS while the master toggle is off.
        XCTAssertNil(maps.media.values.first { $0.isFine })
    }

    func testFineAdjustmentsTogglesTheOptionVariants() {
        let maps = HotkeyBindings.maps(bindings: [:], fineAdjustmentsEnabled: true)
        XCTAssertEqual(
            maps.media[MediaKeyShortcut(keyCode: MediaKey.brightnessUp, option: true)],
            .brightnessUpFine
        )
    }

    func testCustomKeyboardBindingRegistersCarbonAndDropsTheMediaDefault() {
        let combo = GlobalShortcut(keyCode: 11, carbonModifiers: 2048)
        let maps = HotkeyBindings.maps(
            bindings: [HotKeyAction.brightnessUp.rawValue: .keyboard(combo)],
            fineAdjustmentsEnabled: false
        )
        XCTAssertEqual(maps.carbon[.brightnessUp], combo)
        // The recorded custom replaces the default media route for that action.
        XCTAssertNil(maps.media[MediaKeyShortcut(keyCode: MediaKey.brightnessUp)])
    }

    func testDisabledBindingSuppressesTheActionEntirely() {
        let maps = HotkeyBindings.maps(
            bindings: [HotKeyAction.brightnessUp.rawValue: .disabled],
            fineAdjustmentsEnabled: false
        )
        XCTAssertNil(maps.carbon[.brightnessUp])
        XCTAssertNil(maps.media[MediaKeyShortcut(keyCode: MediaKey.brightnessUp)])
    }

    func testCustomMediaBindingReRoutesTheCombo() {
        // Recording ⌘-volume-up for warmth: the combo routes to the recorded action.
        let combo = MediaKeyShortcut(keyCode: MediaKey.soundUp, command: true)
        let maps = HotkeyBindings.maps(
            bindings: [HotKeyAction.colorWarmer.rawValue: .media(combo)],
            fineAdjustmentsEnabled: false
        )
        XCTAssertEqual(maps.media[combo], .colorWarmer)
        // The action's own default media combo is gone (the custom supersedes it).
        XCTAssertNil(maps.media[MediaKeyShortcut(keyCode: MediaKey.brightnessDown, shift: true)])
    }

    func testTwoActionsOnTheSameMediaComboAreFlaggedAsConflicts() {
        // Record brightness-up's own media combo onto contrast-up: both now claim it, so both
        // are flagged (only one can win the route) instead of one silently shadowing the other.
        let combo = MediaKeyShortcut(keyCode: MediaKey.brightnessUp)
        let maps = HotkeyBindings.maps(
            bindings: [HotKeyAction.contrastUp.rawValue: .media(combo)],
            fineAdjustmentsEnabled: false
        )
        XCTAssertTrue(maps.mediaConflicts.contains(.contrastUp))
        XCTAssertTrue(maps.mediaConflicts.contains(.brightnessUp))
    }

    func testDistinctMediaCombosReportNoConflict() {
        let maps = HotkeyBindings.maps(bindings: [:], fineAdjustmentsEnabled: true)
        XCTAssertTrue(maps.mediaConflicts.isEmpty)
    }

    func testFineCustomBindingIsInertWhileTheMasterIsOff() {
        let combo = GlobalShortcut(keyCode: 11, carbonModifiers: 2048)
        let off = HotkeyBindings.maps(
            bindings: [HotKeyAction.brightnessUpFine.rawValue: .keyboard(combo)],
            fineAdjustmentsEnabled: false
        )
        XCTAssertNil(off.carbon[.brightnessUpFine])

        let on = HotkeyBindings.maps(
            bindings: [HotKeyAction.brightnessUpFine.rawValue: .keyboard(combo)],
            fineAdjustmentsEnabled: true
        )
        XCTAssertEqual(on.carbon[.brightnessUpFine], combo)
    }
}
