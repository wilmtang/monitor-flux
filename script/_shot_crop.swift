#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

// Dev-only helper (not committed): crop a full-display PNG down to one MonitorFlux window.
// `screencapture -l<id>` / `-R` and CGDisplayCreateImage are all obsoleted/broken for this
// accessory app's windows on macOS 26, but full-screen `screencapture -x` still works — so
// grab the whole display, then crop here (pure ImageIO, no screen-capture API).
// Usage: _shot_crop.swift <windowID> <fullPNG> <out.png>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

let args = CommandLine.arguments
guard args.count >= 4, let targetID = Int(args[1]) else {
    die("usage: _shot_crop.swift <windowID> <fullPNG> <out.png>")
}
let fullPath = args[2], outPath = args[3]

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { exit(2) }
var rect: CGRect?
for w in windows where (w[kCGWindowNumber as String] as? Int) == targetID {
    if let bd = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: bd as! CFDictionary) {
        rect = r
    }
}
guard let rect else { die("window \(targetID) not found") }

let disp = CGDisplayBounds(CGMainDisplayID())
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: fullPath) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("could not load \(fullPath)") }

let scale = CGFloat(img.width) / disp.width
let crop = CGRect(
    x: (rect.minX - disp.minX) * scale,
    y: (rect.minY - disp.minY) * scale,
    width: rect.width * scale,
    height: rect.height * scale
)
guard let cropped = img.cropping(to: crop) else { die("crop failed (rect \(crop) of \(img.width)x\(img.height))") }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    die("could not create destination")
}
CGImageDestinationAddImage(dest, cropped, nil)
guard CGImageDestinationFinalize(dest) else { die("write failed") }
print("wrote \(outPath) \(cropped.width)x\(cropped.height) (display scale \(scale))")
