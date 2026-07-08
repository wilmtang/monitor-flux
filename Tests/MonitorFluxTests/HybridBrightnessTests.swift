// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

/// The unified-brightness mapping is pure math with a safety contract (never black unless
/// opted in) and drag semantics (self-healing mixed states) — pin all of it down.
final class HybridBrightnessTests: XCTestCase {
    private typealias Components = HybridBrightness.Components
    private let notch = HybridBrightness.handoffFraction
    private let floor = HybridBrightness.defaultFloorPercent

    // MARK: Canonical split

    func testSplitBoundaries() {
        XCTAssertEqual(HybridBrightness.split(unified: 1), Components(hardware: 100, gamma: 100))
        // At the notch the hardware sits exactly at its floor, gamma still neutral.
        XCTAssertEqual(HybridBrightness.split(unified: notch), Components(hardware: 0, gamma: 100))
        // Hard left stops at the safety floor, never black.
        XCTAssertEqual(HybridBrightness.split(unified: 0), Components(hardware: 0, gamma: floor))
    }

    func testSplitClampsOutOfRangePositions() {
        XCTAssertEqual(HybridBrightness.split(unified: 1.5), Components(hardware: 100, gamma: 100))
        XCTAssertEqual(HybridBrightness.split(unified: -0.5), Components(hardware: 0, gamma: floor))
    }

    func testSplitWithZeroFloorReachesBlack() {
        // "Dim to black" lowers the floor to 0 — complete darkness becomes reachable.
        XCTAssertEqual(HybridBrightness.split(unified: 0, floor: 0), Components(hardware: 0, gamma: 0))
        // The notch stays at 25% regardless of the floor (fixed-geometry decision).
        XCTAssertEqual(HybridBrightness.split(unified: notch, floor: 0), Components(hardware: 0, gamma: 100))
    }

    func testSplitIsMonotonic() {
        var previous = HybridBrightness.split(unified: 0)
        for step in 1...100 {
            let next = HybridBrightness.split(unified: Double(step) / 100.0)
            XCTAssertGreaterThanOrEqual(next.hardware, previous.hardware)
            XCTAssertGreaterThanOrEqual(next.gamma, previous.gamma)
            previous = next
        }
    }

    // MARK: Round trips

    func testHardwareZoneRoundTrips() {
        for hardware in [0, 1, 25, 50, 99, 100] {
            let components = Components(hardware: hardware, gamma: 100)
            let unified = HybridBrightness.unified(components)
            XCTAssertEqual(HybridBrightness.split(unified: unified), components, "hardware \(hardware)")
        }
    }

    func testSoftwareZoneRoundTrips() {
        for gamma in [floor, floor + 1, 40, 70, 99] {
            let components = Components(hardware: 0, gamma: gamma)
            let unified = HybridBrightness.unified(components)
            XCTAssertLessThan(unified, notch)
            XCTAssertEqual(HybridBrightness.split(unified: unified), components, "gamma \(gamma)")
        }
    }

    // MARK: Mixed states and boost

    func testUnifiedShowsSoftwareTruthForMixedStates() {
        // DDC 50 + gamma 80 (created from Advanced/schedule): the slider shows the darker truth.
        let mixed = HybridBrightness.unified(Components(hardware: 50, gamma: 80))
        let canonical = HybridBrightness.unified(Components(hardware: 0, gamma: 80))
        XCTAssertEqual(mixed, canonical)
        XCTAssertLessThan(mixed, notch)
    }

    func testUnifiedIgnoresAdvancedBoost() {
        // Gamma above neutral (the Advanced-only 100–150 boost) isn't darkness — the position
        // is the hardware one.
        XCTAssertEqual(
            HybridBrightness.unified(Components(hardware: 70, gamma: 120)),
            HybridBrightness.unified(Components(hardware: 70, gamma: 100))
        )
    }

    func testUnifiedClampsSubFloorGamma() {
        // A stored gamma below the floor (schedule/legacy) pins the position at the left end.
        XCTAssertEqual(HybridBrightness.unified(Components(hardware: 0, gamma: floor - 5)), 0)
    }

    // MARK: Drag/step resolution

    func testResolveLoweringThroughNotchZerosHardwareBeforeEasingGamma() {
        let start = Components(hardware: 70, gamma: 100)
        // Still in the hardware zone: only the hardware moves.
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.5, current: start),
            Components(hardware: 33, gamma: 100)
        )
        // Below the notch: hardware at floor, gamma eases down the zone mapping.
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.1, current: start),
            Components(hardware: 0, gamma: 49)
        )
    }

    func testResolveUpwardFromMixedRenormalizesGammaBeforeLiftingHardware() {
        let mixed = Components(hardware: 50, gamma: 80)
        // Within the software zone, gamma rises while the hardware holds — no backlight snap.
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.22, current: mixed),
            Components(hardware: 50, gamma: 90)
        )
        // Crossing the notch renormalizes gamma to neutral; the hardware never *drops* on an
        // upward gesture (canonical target would be 7).
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.3, current: mixed),
            Components(hardware: 50, gamma: 100)
        )
        // Once the target passes the held hardware level, it lifts normally.
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.7, current: mixed),
            Components(hardware: 60, gamma: 100)
        )
    }

    func testResolveDownwardFromMixedEasesGammaOnly() {
        // Dragging further down from a mixed state must not visibly snap the backlight to 0.
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.1, current: Components(hardware: 50, gamma: 80)),
            Components(hardware: 50, gamma: 49)
        )
    }

    func testResolvePreservesAdvancedBoostInHardwareZone() {
        // A >100 boost belongs to Advanced; moving the unified slider must not clear it.
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.5, current: Components(hardware: 70, gamma: 120)),
            Components(hardware: 33, gamma: 120)
        )
    }

    func testResolveFromBoostIntoSoftwareZoneGoesCanonical() {
        // Entering the software zone explicitly asks for dimming: boost gives way to the zone
        // mapping and the hardware drops to its floor (a click-jump snap is expected here).
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0.1, current: Components(hardware: 70, gamma: 120)),
            Components(hardware: 0, gamma: 49)
        )
    }

    func testResolveClampsTarget() {
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 2, current: Components(hardware: 40, gamma: 100)),
            Components(hardware: 100, gamma: 100)
        )
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: -1, current: Components(hardware: 40, gamma: 100)),
            Components(hardware: 0, gamma: floor)
        )
    }

    func testResolveHonorsZeroFloor() {
        XCTAssertEqual(
            HybridBrightness.resolve(targetUnified: 0, current: Components(hardware: 40, gamma: 100), floor: 0),
            Components(hardware: 0, gamma: 0)
        )
    }

    // MARK: Scheduled-target routing

    func testScheduledTargetInAutomaticSplitsAcrossTheNotch() {
        // Above the notch: hardware carries it, gamma stays neutral.
        let day = HybridBrightness.scheduledComponents(target: 90, mode: .automatic, hasHardwareControl: true)
        XCTAssertEqual(day.hardware, 87)
        XCTAssertEqual(day.gamma, 100)

        // A 20% night target lands in the software zone — hardware at its floor, the image
        // darkened in software — instead of clamping at DDC 0 (the old dead stop).
        let night = HybridBrightness.scheduledComponents(target: 20, mode: .automatic, hasHardwareControl: true)
        XCTAssertEqual(night.hardware, 0)
        XCTAssertEqual(night.gamma, 83)
    }

    func testScheduledTargetInHardwareModeClampsToHardwareZone() {
        let components = HybridBrightness.scheduledComponents(target: 20, mode: .hardware, hasHardwareControl: true)
        XCTAssertEqual(components.hardware, 20)
        XCTAssertNil(components.gamma)
    }

    func testScheduledTargetInSoftwareModeRidesTheFlooredTrack() {
        let components = HybridBrightness.scheduledComponents(target: 40, mode: .software, hasHardwareControl: true)
        XCTAssertNil(components.hardware)
        XCTAssertEqual(components.gamma, 49)

        // A 0% night target stops at the safety floor, never black…
        let floor = HybridBrightness.scheduledComponents(target: 0, mode: .software, hasHardwareControl: true)
        XCTAssertEqual(floor.gamma, self.floor)
        // …unless the display opted into dimming to black.
        let black = HybridBrightness.scheduledComponents(target: 0, mode: .software, hasHardwareControl: true, floor: 0)
        XCTAssertEqual(black.gamma, 0)
    }

    func testScheduledTargetWithoutHardwareControlIsSoftwareOnlyRegardlessOfMode() {
        // Non-DDC panels have no hardware path; every mode falls back to the software track.
        for mode in DimmingMode.allCases {
            let components = HybridBrightness.scheduledComponents(target: 40, mode: mode, hasHardwareControl: false)
            XCTAssertNil(components.hardware, "\(mode)")
            XCTAssertEqual(components.gamma, 49, "\(mode)")
        }
    }

    // MARK: Software-only track (non-DDC / Software mode)

    func testSoftwareOnlyTrackMapsFloorToFullRange() {
        XCTAssertEqual(HybridBrightness.softwareOnlyGamma(fraction: 0), floor)
        XCTAssertEqual(HybridBrightness.softwareOnlyGamma(fraction: 1), 100)
        XCTAssertEqual(HybridBrightness.softwareOnlyGamma(fraction: 0, floor: 0), 0)

        for gamma in [floor, 40, 70, 100] {
            let fraction = HybridBrightness.softwareOnlyFraction(gamma: gamma)
            XCTAssertEqual(HybridBrightness.softwareOnlyGamma(fraction: fraction), gamma, "gamma \(gamma)")
        }
    }

    func testFloorPercentReflectsDimToBlack() {
        XCTAssertEqual(HybridBrightness.floorPercent(dimToBlack: false), floor)
        XCTAssertEqual(HybridBrightness.floorPercent(dimToBlack: true), 0)
    }
}
