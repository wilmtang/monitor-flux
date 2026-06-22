#!/usr/bin/env swift

// Smoke-test assertion: exactly one sizable MonitorFlux window should be on screen AND
// substantially within a connected display. Catches "detailed window doesn't open",
// "opens blank-framed", "opens duplicates", and — the reopen-after-close regression —
// "opens off-screen or oversized" (e.g. a window that re-fit its content to a giant
// height and ordered front mostly past the bottom of a display).
// Run by script/smoke_test.sh after launching with MONITORFLUX_OPEN_MAIN=1 or =reopen.

import CoreGraphics
import Foundation

func area(_ rect: CGRect) -> CGFloat {
    rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
}

// Bounds of every active display, in the same global top-left coordinate space that
// CGWindowList reports window bounds in — so the two are directly comparable.
func displayRects() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}

// Fraction of `rect` that lies within the union of the displays (approximated by summing
// per-display overlaps; displays don't overlap, so this is exact for normal layouts).
func visibleFraction(of rect: CGRect, displays: [CGRect]) -> CGFloat {
    let total = area(rect)
    guard total > 0 else { return 0 }
    let covered = displays.reduce(CGFloat(0)) { $0 + area($1.intersection(rect)) }
    return covered / total
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not read the window list\n".utf8))
    exit(2)
}

let displays = displayRects()
var sizableWindows = 0
var offscreenWindows = 0
for window in windows {
    let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.contains("MonitorFlux") else { continue }
    guard let boundsDict = window[kCGWindowBounds as String],
          let rect = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary)
    else { continue }
    // The menu-bar status item is tiny; the detailed window is large.
    guard rect.width > 400, rect.height > 300 else { continue }

    // A correctly placed window sits almost entirely on a display. A reopened window
    // restored off-screen, or ballooned to a giant height, spills mostly past the
    // display edges — that's the regression we want to fail on.
    if displays.isEmpty || visibleFraction(of: rect, displays: displays) >= 0.9 {
        sizableWindows += 1
    } else {
        offscreenWindows += 1
        let frac = Int(visibleFraction(of: rect, displays: displays) * 100)
        let message = "window at \(Int(rect.origin.x)),\(Int(rect.origin.y)) "
            + "\(Int(rect.width))x\(Int(rect.height)) is only \(frac)% on a display\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}

if sizableWindows == 1, offscreenWindows == 0 {
    print("PASS: exactly one detailed MonitorFlux window is open and on-screen")
    exit(0)
}
print("FAIL: expected 1 on-screen detailed window, found \(sizableWindows) on-screen + \(offscreenWindows) off-screen/oversized")
exit(1)
