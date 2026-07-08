// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Dev/screenshot hook (`MONITORFLUX_SNAPSHOT=<path>`): capture the settings window's *own* pixels
/// to a PNG, then quit. Unlike an offscreen `ImageRenderer` pass, this grabs the real composited
/// window through ScreenCaptureKit — so window materials, sidebar vibrancy, appearance, and the
/// grouped-Form's true metrics are faithful, exactly what the user sees. Pair it with
/// `SCROLL_TO` / `EXPAND_ADVANCED` / `SELECT` to frame a below-the-fold section and grab it in a
/// single headless command: no external capture script, no window-id lookup, no live-UI control.
///
/// Requires the app to hold **Screen Recording** permission (granted once; the first run may
/// prompt). Without it the target window won't appear in the shareable content and the shot is
/// skipped with a logged reason rather than hanging.
enum WindowSnapshot {
    /// Show the settings window (idempotent), let it render and any `SCROLL_TO` settle, then
    /// capture it to `path` and terminate. `delay` clears the scroll hook's 0.4/0.9 s nudges.
    @MainActor
    static func captureAndQuit(to path: String, store: AppStore, after delay: TimeInterval = 1.8) {
        store.showMainWindow(activating: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
        }
    }

    @MainActor
    private static func capture(to path: String) {
        guard let window = NSApp.windows.compactMap({ $0 as? MainWindow }).first else {
            AppLog.snapshot.error("snapshot: no settings window to capture")
            NSApp.terminate(nil)
            return
        }
        let windowID = CGWindowID(window.windowNumber)
        let scale = window.backingScaleFactor
        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            do {
                // The window vends into shareable content even when backgrounded/occluded; the
                // desktop-independent filter grabs just the window content (no shadow), matching
                // `script/_shot_sck.swift`.
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )
                guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                    AppLog.snapshot.error(
                        "snapshot: window \(windowID, privacy: .public) not in shareable content — is Screen Recording permission granted?"
                    )
                    return
                }
                let config = SCStreamConfiguration()
                config.width = Int(scWindow.frame.width * scale)
                config.height = Int(scWindow.frame.height * scale)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                    configuration: config
                )
                if writePNG(image, to: path) {
                    AppLog.snapshot.notice(
                        "snapshot: wrote \(path, privacy: .public) (\(image.width)×\(image.height))"
                    )
                } else {
                    AppLog.snapshot.error("snapshot: failed to encode PNG at \(path, privacy: .public)")
                }
            } catch {
                AppLog.snapshot.error("snapshot: capture failed — \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func writePNG(_ image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(
            url, UTType.png.identifier as CFString, 1, nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
