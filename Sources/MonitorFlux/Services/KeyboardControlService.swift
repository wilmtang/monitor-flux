// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import AppKit
import ApplicationServices
import CoreGraphics

/// Intercepts the keyboard's brightness and volume keys with a `CGEventTap` and routes bound
/// shortcuts to the app. Requires Accessibility permission, since taps that swallow HID events
/// are privileged.
///
/// Two delivery paths are normalized onto the same media-key codes — which one fires depends on
/// the keyboard, not just the Mac:
/// - Volume — and brightness from **external USB keyboards** — arrives in an `NSSystemDefined`
///   aux-button event, with the key code in `data1`.
/// - The **built-in keyboard** (modern Apple silicon) sends its dedicated brightness keys as
///   ordinary `keyDown`/`keyUp` events (virtual key codes 144/145, Fn flag set), *not* as
///   `NSSystemDefined` — so the tap has to watch the keyboard event types too, or built-in
///   brightness keys are never seen.
enum MediaKey {
    static let soundUp = 0
    static let soundDown = 1
    static let brightnessUp = 2
    static let brightnessDown = 3

    static let managed: Set<Int> = [soundUp, soundDown, brightnessUp, brightnessDown]

    /// Virtual key codes the **built-in keyboard's** dedicated brightness keys emit as plain
    /// `keyDown`/`keyUp` events (modern Apple silicon, Fn flag set); external USB keyboards send
    /// `NSSystemDefined` instead. Mapped onto the brightness media-key codes so the binding
    /// lookup, OSD, and DDC routing are identical regardless of how macOS delivered the key.
    static let brightnessUpVirtualKeyCode = 144
    static let brightnessDownVirtualKeyCode = 145

    /// The media-key code for a dedicated-brightness-key virtual key code, or nil if it's an
    /// ordinary key the tap should ignore.
    static func code(forVirtualKeyCode keyCode: Int) -> Int? {
        switch keyCode {
        case brightnessUpVirtualKeyCode: return brightnessUp
        case brightnessDownVirtualKeyCode: return brightnessDown
        default: return nil
        }
    }
}

@MainActor
final class KeyboardControlService {
    private(set) var isActive = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Media keys whose key-down we handled, so we swallow only their matching key-up.
    /// Without this, a key we let through (e.g. volume on a speakerless monitor) would have
    /// its key-up swallowed anyway, handing the system an unbalanced down-without-up.
    private var ownedKeys: Set<Int> = []

    /// Active media-key bindings. When a media key matches an entry here, the corresponding
    /// `HotKeyAction` fires via `onAction`; unbound keys pass through to macOS.
    /// Populated by `AppStore.refreshHotKeys()` whenever preferences change.
    var mediaBindings: [MediaKeyShortcut: HotKeyAction] = [:]

    /// Fired when an active media-key binding matches. Returns whether the key was handled.
    var onAction: ((HotKeyAction) -> Bool)?

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Opens the Accessibility prompt so the user can grant permission.
    func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        if isActive {
            return true
        }
        guard AXIsProcessTrusted() else {
            AppLog.keyboard.notice("Media-key tap not started: Accessibility not granted")
            return false
        }

        // keyDown/keyUp catch the modern brightness keys (virtual codes 144/145); NSSystemDefined
        // catches volume (and brightness on older Macs). Session tap, since the brightness keys
        // are synthesized above the HID layer and never reach a `.cghidEventTap`.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.nsSystemDefined)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        isActive = true
        AppLog.keyboard.notice("Media-key tap started")
        return true
    }

    func stop() {
        let wasActive = isActive
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
        if wasActive {
            AppLog.keyboard.notice("Media-key tap stopped")
        }
    }

    func reEnableAfterDisable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            // The system disables the tap if our callback is ever too slow — worth a persisted
            // breadcrumb, since it means media keys briefly stopped routing.
            AppLog.keyboard.notice("Media-key tap re-enabled after system disable")
        }
    }

    /// Handle a media-key press, remembering whether we owned it so the matching key-up is
    /// swallowed iff the key-down was. Returns true when handled (the tap swallows the down).
    func handleKeyDown(keyCode: Int, control: Bool, shift: Bool, command: Bool, option: Bool = false) -> Bool {
        let handled = handle(keyCode: keyCode, control: control, shift: shift, command: command, option: option)
        if handled {
            ownedKeys.insert(keyCode)
        } else {
            ownedKeys.remove(keyCode)
        }
        return handled
    }

    /// Swallow a key-up only if we handled its key-down.
    func consumeKeyUp(keyCode: Int) -> Bool {
        ownedKeys.remove(keyCode) != nil
    }

    /// Returns true when MonitorFlux handled the key (so the tap swallows the event).
    func handle(keyCode: Int, control: Bool, shift: Bool, command: Bool = false, option: Bool = false) -> Bool {
        let incoming = MediaKeyShortcut(keyCode: keyCode, control: control, shift: shift, command: command, option: option)
        guard let action = mediaBindings[incoming] else {
            return false
        }
        // Fail closed: with no handler wired we haven't actually acted on the key, so let it fall
        // through to macOS rather than swallowing it into the void.
        return onAction?(action) ?? false
    }
}

private extension CGEventType {
    /// `NSSystemDefined` events (media keys) have CGEventType raw value 14.
    static var nsSystemDefined: UInt32 { 14 }
}

/// A media key resolved from a tapped event: the `MediaKey` code and whether it's the press.
private struct ResolvedMediaKey {
    let code: Int
    let isKeyDown: Bool
}

/// Normalize a tapped event into a `MediaKey` press/release, from either delivery path, or nil if
/// it isn't a key we handle. Pulling both paths through one code keeps the binding lookup identical
/// whether brightness arrived as a `keyDown` (modern Apple silicon) or an `NSSystemDefined` aux key.
private func resolveMediaKey(type: CGEventType, event: CGEvent) -> ResolvedMediaKey? {
    switch type.rawValue {
    case CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue:
        // Modern brightness keys: dedicated keys reported as ordinary key events (codes 144/145).
        let virtualKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let code = MediaKey.code(forVirtualKeyCode: virtualKeyCode) else {
            return nil
        }
        return ResolvedMediaKey(code: code, isKeyDown: type.rawValue == CGEventType.keyDown.rawValue)
    case CGEventType.nsSystemDefined:
        // Classic aux-button media keys (volume, and brightness on older Macs): code + state in data1.
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return nil
        }
        let data1 = nsEvent.data1
        let code = Int((data1 & 0xFFFF_0000) >> 16)
        guard MediaKey.managed.contains(code) else {
            return nil
        }
        let isKeyDown = (((data1 & 0x0000_FFFF) & 0xFF00) >> 8) == 0x0A
        return ResolvedMediaKey(code: code, isKeyDown: isKeyDown)
    default:
        return nil
    }
}

private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let service = Unmanaged<KeyboardControlService>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables the tap if our callback is ever too slow; re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { service.reEnableAfterDisable() }
        return Unmanaged.passUnretained(event)
    }

    // Most events (ordinary typing) aren't ours — bail before reading modifiers.
    guard let media = resolveMediaKey(type: type, event: event) else {
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let controlHeld = flags.contains(.maskControl)
    let shiftHeld = flags.contains(.maskShift)
    let optionHeld = flags.contains(.maskAlternate)
    let commandHeld = flags.contains(.maskCommand)

    // ⌥ is part of the binding lookup (fine adjustments bind ⌥ variants). An ⌥ combo that
    // matches nothing still falls through to macOS below, because `handle` only swallows keys
    // with an active binding. With fine adjustments OFF that's every ⌥ combo — ⌥ + brightness
    // keeps opening Displays settings and ⌥⇧ + brightness stays the native built-in fine step.
    // With them ON, those combos are bound and swallowed: ⌥⇧ + brightness becomes the *warmth*
    // fine step, mirroring ⇧ + brightness = warmth.
    // Act on key-down; swallow the matching key-up only if we owned the down, so a key we
    // let through (e.g. volume on a speakerless monitor) reaches the system as a balanced pair.
    let handled = MainActor.assumeIsolated {
        media.isKeyDown
            ? service.handleKeyDown(
                keyCode: media.code,
                control: controlHeld,
                shift: shiftHeld,
                command: commandHeld,
                option: optionHeld
            )
            : service.consumeKeyUp(keyCode: media.code)
    }

    return handled ? nil : Unmanaged.passUnretained(event)
}
