// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

@MainActor
final class HotKeyCenterTests: XCTestCase {
    /// A registrar that records calls and can simulate "this combo is already taken" by
    /// failing specific key codes — so the conflict bookkeeping is testable without Carbon.
    final class FakeRegistrar: HotKeyRegistering {
        var onPress: ((UInt32) -> Void)?
        var failingKeyCodes: Set<UInt32> = []
        private(set) var registeredActionIDs: Set<UInt32> = []
        private(set) var unregisterCount = 0

        func register(keyCode: UInt32, modifiers: UInt32, actionID: UInt32) -> HotKeyToken? {
            if failingKeyCodes.contains(keyCode) {
                return nil
            }
            registeredActionIDs.insert(actionID)
            return HotKeyToken(carbonRef: nil)
        }

        func unregister(_ token: HotKeyToken) {
            unregisterCount += 1
        }
    }

    private func shortcut(_ keyCode: UInt32) -> GlobalShortcut {
        GlobalShortcut(keyCode: keyCode, carbonModifiers: 256) // 256 == cmdKey
    }

    func testSuccessfulRegistrationsReportNoConflicts() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(registrar: fake)

        let conflicts = center.update([.brightnessUp: shortcut(10), .volumeDown: shortcut(11)])

        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertTrue(center.conflictedActions.isEmpty)
        XCTAssertEqual(fake.registeredActionIDs, [HotKeyAction.brightnessUp.hotKeyID, HotKeyAction.volumeDown.hotKeyID])
    }

    func testFailedRegistrationIsReportedAsConflict() {
        let fake = FakeRegistrar()
        fake.failingKeyCodes = [10] // brightnessUp's key is "already taken"
        let center = HotKeyCenter(registrar: fake)

        let conflicts = center.update([.brightnessUp: shortcut(10), .volumeDown: shortcut(11)])

        XCTAssertEqual(conflicts, [.brightnessUp])
        XCTAssertEqual(center.conflictedActions, [.brightnessUp])
        // The non-conflicting one still registers.
        XCTAssertEqual(fake.registeredActionIDs, [HotKeyAction.volumeDown.hotKeyID])
    }

    func testUpdateUnregistersPreviousRegistrations() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(registrar: fake)

        _ = center.update([.brightnessUp: shortcut(10)])
        _ = center.update([.volumeUp: shortcut(11)])

        XCTAssertEqual(fake.unregisterCount, 1) // the first update's single token
    }

    func testReregisteringClearsAStaleConflict() {
        let fake = FakeRegistrar()
        fake.failingKeyCodes = [10]
        let center = HotKeyCenter(registrar: fake)
        _ = center.update([.brightnessUp: shortcut(10)])
        XCTAssertEqual(center.conflictedActions, [.brightnessUp])

        // User picks a free combo; the conflict clears.
        fake.failingKeyCodes = []
        let conflicts = center.update([.brightnessUp: shortcut(12)])
        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertTrue(center.conflictedActions.isEmpty)
    }

    func testTrulyEmptyShortcutIsSkipped() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(registrar: fake)

        // The legacy-migration empty sentinel: no key, no modifiers. Nothing to register.
        let conflicts = center.update([.brightnessUp: GlobalShortcut(keyCode: 0, carbonModifiers: 0)])

        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertTrue(fake.registeredActionIDs.isEmpty)
    }

    func testCommandAShortcutRegisters() {
        // Carbon key code 0 is kVK_ANSI_A, so ⌘A (keyCode 0 + a modifier) is a real shortcut and
        // must register — it is not the empty sentinel.
        let fake = FakeRegistrar()
        let center = HotKeyCenter(registrar: fake)

        let conflicts = center.update([.brightnessUp: GlobalShortcut(keyCode: 0, carbonModifiers: 256)]) // ⌘A

        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertEqual(fake.registeredActionIDs, [HotKeyAction.brightnessUp.hotKeyID])
    }

    func testPressRoutesToMatchingAction() {
        let fake = FakeRegistrar()
        let center = HotKeyCenter(registrar: fake)
        var fired: HotKeyAction?
        center.onAction = { fired = $0 }

        _ = center.update([.contrastUp: shortcut(10)])
        fake.onPress?(HotKeyAction.contrastUp.hotKeyID)

        XCTAssertEqual(fired, .contrastUp)
    }
}
