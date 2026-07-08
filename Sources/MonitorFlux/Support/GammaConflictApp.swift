// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import AppKit

/// Apps known to also drive the display's color/gamma tables.
///
/// macOS keeps no record of *which* process last wrote the gamma LUT — Core Graphics'
/// `CGSetDisplayTransferByTable` is anonymous and `CGGetDisplayTransferByTable` returns only the
/// values — so when MonitorFlux reads the table back and notices a foreign change, it cannot ask
/// the OS who did it. As a practical stand-in, it checks whether any *known* gamma app is running
/// and names it as the likely cause. This is the same heuristic other display tools use; it can
/// be wrong (an unknown app, or macOS Night Shift, which is a system feature with no app process),
/// so the banner phrases it as "likely", not certain.
enum GammaConflictApp {
    /// Lowercased bundle identifier → user-facing name. Matched case-insensitively. Night Shift
    /// and True Tone are CoreBrightness system features with no distinct process, so they can't
    /// appear here — the banner mentions them separately. Extend this list as needed.
    static let known: [(bundleID: String, name: String)] = [
        ("org.herf.flux", "f.lux"),
        ("fyi.lunar.lunar", "Lunar"),
        ("app.monitorcontrol.monitorcontrol", "MonitorControl"),
        ("me.guillaumeb.monitorcontrol", "MonitorControl"),
        ("pro.betterdisplay.betterdisplay", "BetterDisplay"),
    ]

    /// Names of known gamma apps among `bundleIDs`, de-duplicated and in `known` order. Pure, so
    /// the matching is unit-testable without a live `NSWorkspace`.
    static func names(forRunningBundleIDs bundleIDs: [String]) -> [String] {
        let running = Set(bundleIDs.map { $0.lowercased() })
        var names: [String] = []
        for entry in known where running.contains(entry.bundleID) && !names.contains(entry.name) {
            names.append(entry.name)
        }
        return names
    }

    /// Known gamma apps currently running, by friendly name — the likely cause of a detected
    /// gamma conflict.
    static func runningConflictingAppNames() -> [String] {
        let bundleIDs = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return names(forRunningBundleIDs: bundleIDs)
    }
}
