// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// A stable, persistable identity for a physical display.
///
/// Preferences must not be keyed by `CGDirectDisplayID`: macOS reassigns that number across
/// reconnects, reboots, and even sleep/wake, so a monitor's saved brightness/contrast/color
/// would be lost — and two identical monitors could swap settings. Instead we key off the
/// EDID (vendor / model / serial), which the same physical panel reports every time, and only
/// fall back to the display ID when the EDID reports nothing usable (some virtual displays).
enum DisplayIdentity {
    struct Source: Equatable {
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32
        var displayID: UInt32
    }

    /// The base key for a single display. Identical panels (same vendor/model/serial) map to
    /// the same base key on purpose; `keys(for:)` disambiguates them when more than one is
    /// connected at once.
    static func key(vendor: UInt32, model: UInt32, serial: UInt32, displayID: UInt32) -> String {
        guard vendor != 0 || model != 0 || serial != 0 else {
            // No EDID identity at all — fall back to the (unstable) display ID so we at
            // least don't collide with other displays within a session.
            return "display-\(displayID)"
        }
        var parts = ["v\(vendor)", "m\(model)"]
        if serial != 0 {
            parts.append("s\(serial)")
        }
        return parts.joined(separator: "-")
    }

    /// Stable keys for a connected set of displays, in input order. Two displays that share
    /// an EDID identity (a matched pair of monitors that don't report distinct serials) get
    /// an occurrence suffix so each still has its own preferences while both are connected.
    ///
    /// Known limitation: for such a serial-less identical pair the suffix is assigned by
    /// input order (the system's online-display ordering), which isn't a stable physical
    /// property — so the two panels can swap their saved settings across a reconnect or
    /// reboot. There's no stable per-unit identifier to key off in that case; monitors that
    /// report a distinct serial (the common case) are unaffected.
    static func keys(for sources: [Source]) -> [String] {
        var seenCount: [String: Int] = [:]
        return sources.map { source in
            let base = key(
                vendor: source.vendor,
                model: source.model,
                serial: source.serial,
                displayID: source.displayID
            )
            let occurrence = seenCount[base, default: 0]
            seenCount[base] = occurrence + 1
            return occurrence == 0 ? base : "\(base)#\(occurrence + 1)"
        }
    }
}
