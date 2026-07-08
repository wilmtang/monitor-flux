#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

// Dev-only helper (not committed): screenshot one window by CGWindowID via ScreenCaptureKit.
// The legacy paths (screencapture -l/-R, CGDisplayCreateImage) are obsoleted/broken on
// macOS 26 and full-screen grabs miss windows on other Spaces. SCScreenshotManager captures
// a specific window directly, even if occluded or off the active Space.
// Usage: _shot_sck.swift <cgWindowID> <out.png>

import AppKit
import ScreenCaptureKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// A bare `swift` interpreter process has no WindowServer connection, so SCContentFilter
// asserts CGS_REQUIRE_INIT (SLSGetActiveDisplayList). Touching NSApplication establishes it.
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

let args = CommandLine.arguments
guard args.count >= 3, let targetID = UInt32(args[1]) else {
    FileHandle.standardError.write(Data("usage: _shot_sck.swift <cgWindowID> <out.png>\n".utf8)); exit(2)
}
let outPath = args[2]

let sema = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == targetID }) else {
            FileHandle.standardError.write(Data("window \(targetID) not in shareable content\n".utf8))
            sema.signal(); return
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        config.width = Int(win.frame.width * 2)
        config.height = Int(win.frame.height * 2)
        config.scalesToFit = true
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            sema.signal(); return
        }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            print("wrote \(outPath) \(image.width)x\(image.height)")
            exitCode = 0
        }
    } catch {
        FileHandle.standardError.write(Data("capture error: \(error)\n".utf8))
    }
    sema.signal()
}
sema.wait()
exit(exitCode)
