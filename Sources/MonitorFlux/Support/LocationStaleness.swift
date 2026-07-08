// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// Pure traveling detection for Follow-sunset: is the Mac's clock in a different UTC offset
/// than the place the schedule follows? Offsets are compared at a specific instant, never
/// zone ids — Madrid and Paris share an offset and must not warn, while Phoenix and Denver
/// differ only while DST is active. The result only ever drives a dismissible hint; nothing
/// changes the stored location without the user acting.
enum LocationStaleness {
    struct Mismatch: Equatable {
        var placeZoneID: String
        var systemZoneID: String

        /// Persisted on dismiss; the hint stays quiet for this exact pair and re-arms when
        /// either side changes (moving on, or coming home).
        var dismissalKey: String { "\(placeZoneID)|\(systemZoneID)" }

        /// "Los Angeles" from "America/Los_Angeles" — the friendliest name an IANA id offers.
        var systemClockLabel: String { Self.label(for: systemZoneID) }

        static func label(for zoneID: String) -> String {
            let city = zoneID.split(separator: "/").last.map(String.init) ?? zoneID
            return city.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Non-nil when the schedule's place and the system clock disagree by an hour or more at
    /// `now` and the user hasn't dismissed this exact pair. A nil/unknown place zone (bad
    /// coordinates, missing index) never warns — no data beats a wrong nag.
    static func check(
        placeZoneID: String?,
        systemZone: TimeZone,
        now: Date,
        dismissedKey: String = ""
    ) -> Mismatch? {
        guard let placeZoneID, let placeZone = TimeZone(identifier: placeZoneID) else {
            return nil
        }
        let offsetDelta = abs(placeZone.secondsFromGMT(for: now) - systemZone.secondsFromGMT(for: now))
        guard offsetDelta >= 3600 else {
            return nil
        }
        let mismatch = Mismatch(placeZoneID: placeZoneID, systemZoneID: systemZone.identifier)
        return mismatch.dismissalKey == dismissedKey ? nil : mismatch
    }
}
