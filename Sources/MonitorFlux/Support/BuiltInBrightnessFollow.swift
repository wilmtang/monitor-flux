// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics
import Foundation

/// Pure planning for the one-way "Follow built-in brightness" mode: eligible external
/// displays track the built-in backlight at a per-display *offset* (their brightness minus
/// the built-in's), so each keeps its own relationship instead of copying an absolute level.
/// The built-in is read-only to the feature — macOS keeps ownership of its backlight — and
/// mapping against the built-in's absolute level (not cumulative deltas) means a display
/// pinned at a clamp never ratchets: when the built-in comes back, so does the follower.
///
/// The store executes the writes; a follower without an offset yet (just enabled, just
/// connected, schedule just turned off) is *adopted* at its current level rather than moved,
/// so turning the mode on or plugging in a monitor never jolts anything by itself.
enum BuiltInBrightnessFollow {
    /// Ignore moves below half a percent of the unified track — sub-perceptual, and not
    /// worth a DDC write.
    static let writeThreshold = 0.005

    struct DisplayContext: Equatable {
        var id: CGDirectDisplayID
        var isBuiltIn: Bool
        var isBrightnessScheduled: Bool
        var canAdjustBrightness: Bool
        var currentBrightness: Double
    }

    struct Adjustment: Equatable {
        var displayID: CGDirectDisplayID
        var targetBrightness: Double
    }

    struct Plan: Equatable {
        /// The reconciled offsets to carry forward: newly eligible displays adopted at their
        /// current level, stale entries (disconnected, schedule turned on) dropped.
        var offsets: [CGDirectDisplayID: Double]
        var adjustments: [Adjustment]
    }

    static func plan(
        builtInBrightness: Double?,
        offsets: [CGDirectDisplayID: Double],
        displays: [DisplayContext]
    ) -> Plan {
        // No readable built-in (clamshell, no backlight API): drop the offsets so reopening
        // the lid re-adopts every follower where it currently sits instead of jumping it.
        guard let builtInBrightness else {
            return Plan(offsets: [:], adjustments: [])
        }
        var nextOffsets: [CGDirectDisplayID: Double] = [:]
        var adjustments: [Adjustment] = []
        for display in displays where isEligible(display) {
            guard let offset = offsets[display.id] else {
                nextOffsets[display.id] = display.currentBrightness - builtInBrightness
                continue
            }
            nextOffsets[display.id] = offset
            let target = (builtInBrightness + offset).clamped(to: 0...1)
            if abs(target - display.currentBrightness) >= writeThreshold {
                adjustments.append(Adjustment(displayID: display.id, targetBrightness: target))
            }
        }
        return Plan(offsets: nextOffsets, adjustments: adjustments)
    }

    /// A manual tweak while following re-anchors that display's offset — the new level *is*
    /// the relationship the user wants. Returns nil when the display shouldn't carry one.
    static func anchoredOffset(
        builtInBrightness: Double?,
        display: DisplayContext
    ) -> Double? {
        guard let builtInBrightness, isEligible(display) else {
            return nil
        }
        return display.currentBrightness - builtInBrightness
    }

    private static func isEligible(_ display: DisplayContext) -> Bool {
        !display.isBuiltIn && !display.isBrightnessScheduled && display.canAdjustBrightness
    }
}
