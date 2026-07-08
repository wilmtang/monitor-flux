// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    /// Stable identity used to key preferences — survives reconnects/reboots, unlike `id`.
    /// See `DisplayIdentity`.
    let persistentID: String
    let frameDescription: String
    let isBuiltIn: Bool
    let isOnline: Bool
    /// AirPlay / virtual display: gamma writes don't take effect, so software dimming uses a
    /// shade overlay (see `ShadeController`) instead, and it's excluded from the gamma plan.
    let isVirtual: Bool
    /// When this display mirrors another, the master display's ID (else `nil`). Gamma and shade
    /// writes target `effectiveID` so a mirror set is driven through its master, not a child.
    let mirrorMaster: CGDirectDisplayID?

    init(
        id: CGDirectDisplayID,
        name: String,
        persistentID: String? = nil,
        frameDescription: String,
        isBuiltIn: Bool,
        isOnline: Bool,
        isVirtual: Bool = false,
        mirrorMaster: CGDirectDisplayID? = nil
    ) {
        self.id = id
        self.name = name
        // Default keeps older call sites/tests working: a display with no resolved EDID
        // identity falls back to the same `display-<id>` form `DisplayIdentity` uses.
        self.persistentID = persistentID ?? "display-\(id)"
        self.frameDescription = frameDescription
        self.isBuiltIn = isBuiltIn
        self.isOnline = isOnline
        self.isVirtual = isVirtual
        self.mirrorMaster = mirrorMaster
    }

    /// The preferences key for this display. Stable across reconnects (see `persistentID`).
    var key: String {
        persistentID
    }

    /// The display whose framebuffer actually backs this one: the mirror master when mirroring,
    /// otherwise itself. Gamma and shade writes target this so a mirror set isn't double-driven.
    var effectiveID: CGDirectDisplayID {
        mirrorMaster ?? id
    }

    var kindLabel: String {
        isBuiltIn ? "Built-in" : "External"
    }
}
