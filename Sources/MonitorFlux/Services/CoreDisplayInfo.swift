// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics
import Foundation

/// Reads the private `CoreDisplay_DisplayCreateInfoDictionary` to tell whether a display is an
/// AirPlay/virtual device. macOS exposes no public flag for this, and it matters because gamma
/// table writes (`CGSetDisplayTransferByTable`) are silently ignored on AirPlay/wireless
/// displays — so software dimming has to use a shade overlay there instead (see `ShadeController`).
/// This is the same key MonitorControl reads in `DisplayManager.isVirtual`.
///
/// Resolved with `dlopen`/`dlsym` (not link-time) so there's no hard dependency on a private
/// framework — consistent with how the built-in backlight (DisplayServices) is bound, and clean
/// under the hardened runtime (the framework is Apple-signed).
enum CoreDisplayInfo {
    private typealias CreateInfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static let createInfoDictionary: CreateInfoDictionary? = {
        let candidatePaths = [
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay",
        ]
        for path in candidatePaths {
            guard let handle = dlopen(path, RTLD_LAZY),
                  let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary")
            else {
                continue
            }
            return unsafeBitCast(symbol, to: CreateInfoDictionary.self)
        }
        return nil
    }()

    /// Whether `displayID` is an AirPlay or otherwise virtual display (no real gamma/DDC path).
    /// Conservatively returns false if the private API can't be resolved.
    static func isVirtual(_ displayID: CGDirectDisplayID) -> Bool {
        guard let createInfoDictionary,
              let info = createInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary?
        else {
            return false
        }
        let isVirtualDevice = info["kCGDisplayIsVirtualDevice"] as? Bool ?? false
        let isAirPlay = info["kCGDisplayIsAirPlay"] as? Bool ?? false
        return isVirtualDevice || isAirPlay
    }
}
