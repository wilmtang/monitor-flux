// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

enum AppInfo {
    /// The bundle's marketing version — shown in General and the Diagnostics report. Falls back
    /// to a dev marker when running unbundled (e.g. straight from `swift build`).
    static var version: String {
        infoString("CFBundleShortVersionString") ?? "dev (unbundled)"
    }

    /// The git commit the bundle was built from (full SHA, with a `-dirty` suffix when the tree
    /// had uncommitted changes), stamped into Info.plist by `build_and_run.sh`. `nil` for an
    /// unbundled dev build, where there's no plist to read.
    static var commit: String? {
        infoString("MonitorFluxGitCommit")
    }

    /// UTC build timestamp (ISO-8601), stamped alongside the commit. Disambiguates two builds
    /// from the same commit. `nil` for an unbundled dev build.
    static var buildDate: String? {
        infoString("MonitorFluxBuildDate")
    }

    /// A short, human-facing commit label ("a1b2c3d" or "a1b2c3d-dirty") for compact rows.
    static var shortCommit: String? {
        guard let commit else {
            return nil
        }
        let dirty = commit.hasSuffix("-dirty")
        let sha = dirty ? String(commit.dropLast("-dirty".count)) : commit
        let short = String(sha.prefix(7))
        return dirty ? "\(short)-dirty" : short
    }

    /// A non-empty Info.plist string, or nil when absent/blank/`unknown` (unbundled or a build
    /// outside a git checkout).
    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              value != "unknown"
        else {
            return nil
        }
        return value
    }
}
