// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics
import Darwin
import Foundation

// Real backlight control for the built-in panel (and Apple displays) goes through the
// private DisplayServices framework — the same approach MonitorControl (MIT) uses; see
// ACKNOWLEDGEMENTS.md. The framework isn't on the default linker search path, so we
// resolve the symbols at runtime with dlopen/dlsym rather than linking them.
private typealias DSSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias DSGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSCanChange = @convention(c) (CGDirectDisplayID) -> Bool

// The handle is opened once and only ever read (dlsym lookups), so it's safe to share.
private nonisolated(unsafe) let displayServices: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

private func displayServicesSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle = displayServices, let symbol = dlsym(handle, name) else {
        return nil
    }
    return unsafeBitCast(symbol, to: T.self)
}

private let dsSetBrightness = displayServicesSymbol("DisplayServicesSetBrightness", as: DSSetBrightness.self)
private let dsGetBrightness = displayServicesSymbol("DisplayServicesGetBrightness", as: DSGetBrightness.self)
private let dsCanChangeBrightness = displayServicesSymbol("DisplayServicesCanChangeBrightness", as: DSCanChange.self)

/// Reads and writes a display's real backlight (0...1) via DisplayServices. Returns
/// `false`/`nil` gracefully when the API is unavailable or the display has no
/// adjustable backlight (e.g. most external monitors, which use DDC instead).
struct NativeBrightnessBackend: Sendable {
    func canControl(_ display: CGDirectDisplayID) -> Bool {
        dsCanChangeBrightness?(display) ?? false
    }

    func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let getter = dsGetBrightness else {
            return nil
        }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }

    @discardableResult
    func setBrightness(_ value: Float, for display: CGDirectDisplayID) -> Bool {
        guard let setter = dsSetBrightness else {
            return false
        }
        return setter(display, value.clamped(to: 0...1)) == 0
    }
}
