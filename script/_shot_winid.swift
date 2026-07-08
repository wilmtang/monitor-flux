#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

// Dev-only helper (not committed): print every on-screen MonitorFlux window as
// `id<TAB>x<TAB>y<TAB>w<TAB>h<TAB>layer<TAB>title` so a screenshot run can pick the
// detail window (large) or the menu-bar popup (~312 wide) by id for `screencapture -l`.

import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(2)
}
for window in windows {
    let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.contains("MonitorFlux") else { continue }
    let id = (window[kCGWindowNumber as String] as? Int) ?? -1
    let layer = (window[kCGWindowLayer as String] as? Int) ?? -1
    let title = (window[kCGWindowName as String] as? String) ?? ""
    var x = 0, y = 0, w = 0, h = 0
    if let boundsDict = window[kCGWindowBounds as String],
       let rect = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary) {
        x = Int(rect.origin.x); y = Int(rect.origin.y)
        w = Int(rect.width); h = Int(rect.height)
    }
    print("\(id)\t\(x)\t\(y)\t\(w)\t\(h)\t\(layer)\t\(title)")
}
