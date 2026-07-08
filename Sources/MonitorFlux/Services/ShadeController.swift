// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import AppKit
import CoreGraphics

/// Software dimming for displays that ignore gamma — AirPlay / virtual displays — by laying a
/// black, click-through overlay window over the screen and varying its opacity. This is how
/// MonitorControl dims such displays (`DisplayManager.createShadeOnDisplay` / `setShadeAlpha`),
/// because `CGSetDisplayTransferByTable` has no effect on them.
///
/// The overlay sits at the shielding-window level (above normal windows and full-screen apps),
/// ignores mouse events, and joins all Spaces, so it dims everything without getting in the way.
@MainActor
final class ShadeController {
    private var shades: [CGDirectDisplayID: NSWindow] = [:]

    /// Never fully black out: cap the overlay so a slammed-to-zero slider still leaves the screen
    /// faintly visible and recoverable (matches MonitorControl's 0.15 floor on brightness).
    private static let maxDim: CGFloat = 0.85

    /// Dim `displayID` where `brightnessFraction` is 0...1 (1 = no shade, 0 = darkest). Creates
    /// the overlay on first use. No-op if the display has no matching `NSScreen` (e.g. it just
    /// disconnected).
    func setBrightness(_ brightnessFraction: Double, for displayID: CGDirectDisplayID) {
        let dim = Self.maxDim * (1 - CGFloat(brightnessFraction.clamped(to: 0...1)))
        guard let shade = shade(for: displayID) else {
            return
        }
        shade.contentView?.layer?.opacity = Float(dim)
    }

    /// Tear down overlays for displays not in `keep` — called on each display refresh so a shade
    /// for an unplugged AirPlay display doesn't linger.
    func retainOnly(_ keep: Set<CGDirectDisplayID>) {
        for displayID in shades.keys where !keep.contains(displayID) {
            remove(displayID)
        }
    }

    func remove(_ displayID: CGDirectDisplayID) {
        shades[displayID]?.orderOut(nil)
        shades.removeValue(forKey: displayID)
    }

    func removeAll() {
        for window in shades.values {
            window.orderOut(nil)
        }
        shades.removeAll()
    }

    private func shade(for displayID: CGDirectDisplayID) -> NSWindow? {
        guard let screen = Self.screen(for: displayID) else {
            // No screen for this ID (disconnected); drop any stale overlay we had.
            remove(displayID)
            return nil
        }
        if let existing = shades[displayID] {
            existing.setFrame(screen.frame, display: true)
            return existing
        }
        let window = Self.makeShadeWindow(frame: screen.frame)
        shades[displayID] = window
        return window
    }

    private static func makeShadeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.opacity = 0
        window.contentView = content
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return window
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}
