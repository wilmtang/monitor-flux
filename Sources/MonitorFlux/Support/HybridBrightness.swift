// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// Pure mapping between the **unified brightness** position (0…1 — the single slider/keys
/// scale) and its two per-display components: the hardware backlight percent (DDC, or the
/// built-in backlight × 100) and the software (gamma) brightness percent.
///
/// In Automatic mode the track has two zones split by a fixed handoff notch:
///
///     0%                  25% (notch)                                  100%
///     ├── software zone ───┼───────────── hardware zone ────────────────┤
///     │ gamma floor…100%   │ hardware 0…100                             │
///
/// The handoff stays at 25% even when the software floor is lowered to 0 ("dim to black"):
/// keeping the everyday hardware zone's geometry stable across a power-user toggle beats
/// giving the deep-dim tail a few extra points of track.
enum HybridBrightness {
    /// The handoff notch's position, as a fraction of the whole track.
    static let handoffFraction = 0.25
    /// Default software floor: the unified control never darkens the image below this, so
    /// the screen stays readable and recoverable from the slider/keys alone.
    static let defaultFloorPercent = 15

    /// The two per-display components, as integer percents. `hardware` is DDC 0…100 (or the
    /// built-in backlight × 100); `gamma` is the software-brightness percent (100 = neutral).
    struct Components: Equatable {
        var hardware: Int
        var gamma: Int
    }

    /// The software floor for a display: 0 when the user opted into complete darkness
    /// ("dim to black" under Advanced), else the safety floor.
    static func floorPercent(dimToBlack: Bool) -> Int {
        dimToBlack ? 0 : defaultFloorPercent
    }

    // MARK: Unified scale ↔ components

    /// The canonical components for a unified position: hardware zone = (hardware 0…100,
    /// gamma 100), software zone = (hardware 0, gamma floor…100).
    static func split(unified: Double, floor: Int = defaultFloorPercent) -> Components {
        let position = unified.clamped(to: 0...1)
        guard position < handoffFraction else {
            let fraction = (position - handoffFraction) / (1 - handoffFraction)
            return Components(hardware: Int((fraction * 100).rounded()), gamma: 100)
        }
        return Components(hardware: 0, gamma: softwareZoneGamma(position, floor: floor))
    }

    /// The unified position for a component pair. A software component below neutral is the
    /// *darker truth* and wins (mixed states show the software position); at or above neutral
    /// (including the Advanced-only >100 boost) the position is the hardware one.
    static func unified(_ components: Components, floor: Int = defaultFloorPercent) -> Double {
        guard components.gamma >= 100 else {
            let span = Double(100 - floor)
            guard span > 0 else {
                return 0
            }
            let fraction = (Double(components.gamma - floor) / span).clamped(to: 0...1)
            return fraction * handoffFraction
        }
        let fraction = Double(components.hardware.clamped(to: 0...100)) / 100.0
        return handoffFraction + fraction * (1 - handoffFraction)
    }

    /// Move from `current` toward the unified `target`, maintaining the invariant that the
    /// unified path only dims in software once the hardware sits at its floor — with
    /// self-healing for mixed states (hardware > 0 while gamma < 100, created from Advanced
    /// or the schedule):
    ///
    /// - Target in the **hardware zone**: gamma renormalizes to neutral (an Advanced >100
    ///   boost is preserved), and from a mixed state the hardware only ever *lifts*
    ///   (`max(current, target)`) — an upward gesture never darkens the backlight.
    /// - Target in the **software zone**: gamma follows the zone mapping; the hardware drops
    ///   to 0 when coming from a neutral (canonical) state, but *holds* from a mixed state,
    ///   so easing gamma further down never visibly snaps the backlight.
    static func resolve(
        targetUnified: Double,
        current: Components,
        floor: Int = defaultFloorPercent
    ) -> Components {
        let target = split(unified: targetUnified, floor: floor)
        guard targetUnified.clamped(to: 0...1) < handoffFraction else {
            return Components(
                hardware: current.gamma < 100 ? max(current.hardware, target.hardware) : target.hardware,
                gamma: max(current.gamma, 100)
            )
        }
        return Components(
            hardware: current.gamma < 100 ? current.hardware : 0,
            gamma: target.gamma
        )
    }

    // MARK: Scheduled targets

    /// Route a scheduled brightness target (0…100, the day/night slider value) to its
    /// components on a wired display — the target is a *unified position*, so a 20% night
    /// target on a monitor whose DDC 0 is still bright lands in the software zone instead of
    /// clamping at DDC 0. `nil` means the schedule leaves that component alone: Monitor
    /// hardware clamps to the hardware zone, Software dimming (and panels with no hardware
    /// path) ride the software-only track. Virtual displays (shade) don't come through here.
    static func scheduledComponents(
        target: Int,
        mode: DimmingMode,
        hasHardwareControl: Bool,
        floor: Int = defaultFloorPercent
    ) -> (hardware: Int?, gamma: Int?) {
        let fraction = Double(target.clamped(to: 0...100)) / 100.0
        guard hasHardwareControl else {
            return (nil, softwareOnlyGamma(fraction: fraction, floor: floor))
        }
        switch mode {
        case .automatic:
            let components = split(unified: fraction, floor: floor)
            return (components.hardware, components.gamma)
        case .hardware:
            return (target.clamped(to: 0...100), nil)
        case .software:
            return (nil, softwareOnlyGamma(fraction: fraction, floor: floor))
        }
    }

    // MARK: Software-only track (non-DDC externals, Software mode)

    /// Track fraction → gamma percent when the whole track is the software component.
    static func softwareOnlyGamma(fraction: Double, floor: Int = defaultFloorPercent) -> Int {
        let clamped = fraction.clamped(to: 0...1)
        return Int((Double(floor) + clamped * Double(100 - floor)).rounded())
    }

    /// Gamma percent → track fraction when the whole track is the software component.
    static func softwareOnlyFraction(gamma: Int, floor: Int = defaultFloorPercent) -> Double {
        let span = Double(100 - floor)
        guard span > 0 else {
            return 1
        }
        return (Double(gamma - floor) / span).clamped(to: 0...1)
    }

    /// Gamma percent at a *unified* position inside the software zone.
    private static func softwareZoneGamma(_ unified: Double, floor: Int) -> Int {
        softwareOnlyGamma(fraction: unified / handoffFraction, floor: floor)
    }
}
