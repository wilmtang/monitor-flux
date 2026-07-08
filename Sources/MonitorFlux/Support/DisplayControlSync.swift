// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics

/// Manual linked-contrast fanout. The store applies the source display through the normal
/// slider/key path first; this planner only returns the peer displays that should receive
/// the same absolute target. Contrast is DDC-external-only and has no macOS owner, so an
/// absolute copy is safe — unlike brightness, which follows the built-in one-way instead
/// (see `BuiltInBrightnessFollow`).
enum DisplayControlSync {
    struct ContrastContext: Equatable {
        var id: CGDirectDisplayID
        var canAdjustContrast: Bool
    }

    struct ContrastAdjustment: Equatable {
        var displayID: CGDirectDisplayID
        var targetContrast: Int
    }

    static func contrastAdjustments(
        sourceID: CGDirectDisplayID,
        targetContrast: Int,
        enabled: Bool,
        displays: [ContrastContext]
    ) -> [ContrastAdjustment] {
        guard enabled else {
            return []
        }
        let target = targetContrast.clamped(to: ControlRanges.hardwarePercent)
        return displays.compactMap { display in
            guard display.id != sourceID,
                  display.canAdjustContrast
            else {
                return nil
            }
            return ContrastAdjustment(displayID: display.id, targetContrast: target)
        }
    }
}
