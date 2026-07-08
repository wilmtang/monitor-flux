// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// Pure resolution of a display's `BrightnessControlKind` from its capabilities and dimming
/// mode, extracted from `AppStore.brightnessControlKind(for:)` so the highest-traffic routing
/// in the app — which the everyday slider, the media keys, the OSD, and the scheduled
/// brightness all speak through — is unit-testable without a main-actor store.
///
/// The rules (see docs/DESIGN.md):
/// - AirPlay/virtual → `.shade` (overlay only; ignores gamma and DDC).
/// - Built-in → binary: `.hardwareOnly` (the real backlight) unless it has no backlight API or
///   the Advanced "Use software dimming" opt-in (`.software`) makes it `.softwareOnly`. Never
///   `.hybrid` — a low-backlight-sensitive user picks software dimming to keep the backlight
///   steady, so the slider must not drive both.
/// - External → per dimming mode: Automatic is `.hybrid` with DDC (else `.softwareOnly`),
///   Monitor hardware is `.hardwareOnly` with DDC (else `.unavailable`), Software is
///   `.softwareOnly`.
enum BrightnessRouting {
    static func controlKind(
        isVirtual: Bool,
        isBuiltIn: Bool,
        canUseNativeBrightness: Bool,
        canUseDDC: Bool,
        dimmingMode: DimmingMode
    ) -> BrightnessControlKind {
        if isVirtual {
            return .shade
        }
        if isBuiltIn {
            guard canUseNativeBrightness else {
                // No backlight API at all: software dimming is the only path.
                return .softwareOnly
            }
            return dimmingMode == .software ? .softwareOnly : .hardwareOnly
        }
        switch dimmingMode {
        case .automatic:
            return canUseDDC ? .hybrid : .softwareOnly
        case .hardware:
            return canUseDDC ? .hardwareOnly : .unavailable
        case .software:
            return .softwareOnly
        }
    }
}
