// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// Pure normalization of legacy built-in dimming state, extracted from
/// `AppStore.reconcileBuiltInDimming` so the rules are unit-testable.
///
/// Contract: call this only for a built-in panel whose Brightness slider drives the real
/// backlight (`BrightnessControlKind.hardwareOnly`) — the caller owns that check, since it
/// needs the live display's capabilities. For such a panel, a migrated `.automatic` mode
/// (from the retired `gammaControlsEnabled` gate, which couldn't see the display kind) is
/// folded into `.hardware`, and a stale sub-100 software dim (left by a build with no
/// backlight API) is cleared — residual gamma would keep the screen dim with no way to lift
/// it from the slider. An explicit `.software` choice never reaches here (it resolves to
/// `.softwareOnly`, which the caller skips).
enum BuiltInDimming {
    struct Normalization: Equatable {
        var preferences: DisplayPreferences
        /// True when a sub-100 software dim was cleared — a color-affecting change the
        /// caller's `preferences` didSet re-applies, letting it skip a redundant reconcile.
        var clearedGamma: Bool
    }

    /// The normalized preferences, or nil when nothing needed changing.
    static func normalized(_ preferences: DisplayPreferences) -> Normalization? {
        var copy = preferences
        var clearedGamma = false
        var changed = false

        // A built-in never stores `.automatic` as a real choice — normalize the legacy
        // artifact so the persisted mode is honest.
        if copy.dimmingMode == .automatic {
            copy.dimmingMode = .hardware
            changed = true
        }
        // Hardware mode means the image isn't darkened in software (see `setDimmingMode`).
        if copy.gammaBrightness < 100 {
            copy.gammaBrightness = 100
            changed = true
            clearedGamma = true
        }

        guard changed else {
            return nil
        }
        return Normalization(preferences: copy, clearedGamma: clearedGamma)
    }
}
