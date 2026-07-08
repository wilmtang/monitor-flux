// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
import CoreGraphics
@testable import MonitorFlux

final class GammaPlanTests: XCTestCase {
    func testDisabledGammaPlansNoDisplayWrites() {
        let displays = [makeDisplay(id: 1)]
        var preferences = AppPreferences.defaults
        preferences.colorMode = .off

        XCTAssertTrue(GammaPlan.adjustments(displays: displays, preferences: preferences).isEmpty)
    }

    func testSoftwareDimmingAppliesWithWarmthOff() {
        // Software dimming is plain dimming, not a color change — it must survive warmth's mode
        // being Off (the unified Brightness control relies on it), with no tint.
        let display = makeDisplay(id: 1)
        var displayPreferences = DisplayPreferences()
        displayPreferences.gammaBrightness = 60

        var preferences = AppPreferences.defaults
        preferences.colorMode = .off
        preferences.displayPreferences[display.key] = displayPreferences

        let adjustment = GammaPlan.adjustments(displays: [display], preferences: preferences)[display.id]

        XCTAssertNil(adjustment?.temperature)
        XCTAssertEqual(adjustment?.brightnessPercent, 60)
    }

    func testDimmingModeDoesNotGateSoftwareBrightness() {
        // The mode routes the unified control; the stored software-brightness value is the
        // state and always applies (picking Hardware clears the value at the store layer).
        let display = makeDisplay(id: 1)
        var displayPreferences = DisplayPreferences()
        displayPreferences.dimmingMode = .hardware
        displayPreferences.gammaBrightness = 70

        var preferences = AppPreferences.defaults
        preferences.colorMode = .off
        preferences.displayPreferences[display.key] = displayPreferences

        let adjustment = GammaPlan.adjustments(displays: [display], preferences: preferences)[display.id]

        XCTAssertEqual(adjustment?.brightnessPercent, 70)
    }

    func testNeutralGammaPlansNoDisplayWrites() {
        let display = makeDisplay(id: 1)
        var preferences = AppPreferences.defaults
        preferences.colorMode = .off
        preferences.displayPreferences[display.key] = DisplayPreferences()

        XCTAssertTrue(GammaPlan.adjustments(displays: [display], preferences: preferences).isEmpty)
    }

    func testGammaBrightnessAndWarmthAreComposedInOneAdjustment() {
        let display = makeDisplay(id: 1)
        var displayPreferences = DisplayPreferences()
        displayPreferences.gammaBrightness = 80

        var preferences = AppPreferences.defaults
        preferences.colorMode = .manual
        preferences.manualTemperature = 3400
        preferences.displayPreferences[display.key] = displayPreferences

        let adjustment = GammaPlan.adjustments(displays: [display], preferences: preferences)[display.id]

        XCTAssertEqual(adjustment?.temperature, 3400)
        XCTAssertEqual(adjustment?.brightnessPercent, 80)
        // Software contrast was removed — the plan always emits a neutral contrast.
        XCTAssertEqual(adjustment?.contrastPercent, 100)
    }

    func testVirtualDisplayExcludedFromGammaPlan() {
        // An AirPlay/virtual display ignores gamma, so it must never appear in the plan — even
        // with warmth on. A normal display alongside it still gets its adjustment.
        let virtual = makeDisplay(id: 5, isVirtual: true)
        let normal = makeDisplay(id: 1)
        var preferences = AppPreferences.defaults
        preferences.colorMode = .manual
        preferences.manualTemperature = 3400

        let plan = GammaPlan.adjustments(displays: [virtual, normal], preferences: preferences)

        XCTAssertNil(plan[virtual.id])
        XCTAssertNotNil(plan[normal.id])
        XCTAssertEqual(plan.count, 1)
    }

    func testMirroredChildIsWrittenThroughItsMaster() {
        // In a mirror set the child's adjustment folds into the master's effective ID, so gamma
        // is written once (to the master) rather than to a child with no framebuffer of its own.
        let master = makeDisplay(id: 1)
        let child = makeDisplay(id: 2, mirrorMaster: 1)
        var preferences = AppPreferences.defaults
        preferences.colorMode = .manual
        preferences.manualTemperature = 3400

        let plan = GammaPlan.adjustments(displays: [master, child], preferences: preferences)

        XCTAssertEqual(plan.count, 1)
        XCTAssertNotNil(plan[master.id])
        XCTAssertNil(plan[child.id])
    }

    func testMirrorMasterAdjustmentWinsOverChild() {
        // The master's own brightness drives the shared framebuffer; a mirrored child can't
        // overwrite it regardless of enumeration order.
        let master = makeDisplay(id: 1)
        let child = makeDisplay(id: 2, mirrorMaster: 1)
        var masterPreferences = DisplayPreferences()
        masterPreferences.gammaBrightness = 80
        var childPreferences = DisplayPreferences()
        childPreferences.gammaBrightness = 50

        var preferences = AppPreferences.defaults
        preferences.colorMode = .manual
        preferences.manualTemperature = 3400
        preferences.displayPreferences[master.key] = masterPreferences
        preferences.displayPreferences[child.key] = childPreferences

        // Child first in the list, to prove order doesn't matter.
        let plan = GammaPlan.adjustments(displays: [child, master], preferences: preferences)

        XCTAssertEqual(plan[master.id]?.brightnessPercent, 80)
        XCTAssertNil(plan[child.id])
    }

    func testEffectiveIDFollowsMirrorMaster() {
        XCTAssertEqual(makeDisplay(id: 7).effectiveID, 7)
        XCTAssertEqual(makeDisplay(id: 7, mirrorMaster: 3).effectiveID, 3)
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        isVirtual: Bool = false,
        mirrorMaster: CGDirectDisplayID? = nil
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            name: "Display \(id)",
            frameDescription: "100 x 100 @ (0, 0)",
            isBuiltIn: false,
            isOnline: true,
            isVirtual: isVirtual,
            mirrorMaster: mirrorMaster
        )
    }
}
