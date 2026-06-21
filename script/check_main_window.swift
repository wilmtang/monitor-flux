#!/usr/bin/env swift

// Smoke-test assertion: exactly one sizable MonitorFlux window should be on screen.
// Catches "detailed window doesn't open", "opens blank-framed", and "opens duplicates".
// Run by script/smoke_test.sh after launching with MONITORFLUX_OPEN_MAIN=1.

import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not read the window list\n".utf8))
    exit(2)
}

var sizableWindows = 0
for window in windows {
    let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.contains("MonitorFlux") else { continue }
    guard let boundsDict = window[kCGWindowBounds as String],
          let rect = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary)
    else { continue }
    // The menu-bar status item is tiny; the detailed window is large.
    if rect.width > 400, rect.height > 300 {
        sizableWindows += 1
    }
}

if sizableWindows == 1 {
    print("PASS: exactly one detailed MonitorFlux window is open")
    exit(0)
}
print("FAIL: expected 1 detailed window, found \(sizableWindows)")
exit(1)
