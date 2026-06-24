import AppKit
import ApplicationServices
import CoreGraphics

/// Intercepts the keyboard's brightness and volume media keys with a `CGEventTap` and
/// routes bound shortcuts to the app. Requires Accessibility permission, since taps that
/// swallow HID events are privileged.
///
/// VCP-style media-key codes carried in an `NSSystemDefined` event's `data1`.
enum MediaKey {
    static let soundUp = 0
    static let soundDown = 1
    static let brightnessUp = 2
    static let brightnessDown = 3

    static let managed: Set<Int> = [soundUp, soundDown, brightnessUp, brightnessDown]
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
            return false
        }

        let mask = CGEventMask(1 << CGEventType.nsSystemDefined)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
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
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    func reEnableAfterDisable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    /// Handle a media-key press, remembering whether we owned it so the matching key-up is
    /// swallowed iff the key-down was. Returns true when handled (the tap swallows the down).
    func handleKeyDown(keyCode: Int, control: Bool, shift: Bool, command: Bool) -> Bool {
        let handled = handle(keyCode: keyCode, control: control, shift: shift, command: command)
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
    func handle(keyCode: Int, control: Bool, shift: Bool, command: Bool = false) -> Bool {
        let incoming = MediaKeyShortcut(keyCode: keyCode, control: control, shift: shift, command: command)
        guard let action = mediaBindings[incoming] else {
            return false
        }
        return onAction?(action) ?? true
    }
}

private extension CGEventType {
    /// `NSSystemDefined` events (media keys) have CGEventType raw value 14.
    static var nsSystemDefined: UInt32 { 14 }
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

    guard type.rawValue == CGEventType.nsSystemDefined,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == 8
    else {
        return Unmanaged.passUnretained(event)
    }

    let data1 = nsEvent.data1
    let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
    guard MediaKey.managed.contains(keyCode) else {
        return Unmanaged.passUnretained(event)
    }

    let keyFlags = data1 & 0x0000_FFFF
    let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
    let modifierFlags = nsEvent.modifierFlags
    let controlHeld = event.flags.contains(.maskControl) || modifierFlags.contains(.control)
    let shiftHeld = event.flags.contains(.maskShift) || modifierFlags.contains(.shift)
    let optionHeld = event.flags.contains(.maskAlternate) || modifierFlags.contains(.option)
    let commandHeld = event.flags.contains(.maskCommand) || modifierFlags.contains(.command)

    // Pass through to macOS when Option is held. Option + Brightness opens Display settings.
    guard !optionHeld else {
        return Unmanaged.passUnretained(event)
    }

    // Act on key-down; swallow the matching key-up only if we owned the down, so a key we
    // let through (e.g. volume on a speakerless monitor) reaches the system as a balanced pair.
    let handled = MainActor.assumeIsolated {
        isKeyDown
            ? service.handleKeyDown(keyCode: keyCode, control: controlHeld, shift: shiftHeld, command: commandHeld)
            : service.consumeKeyUp(keyCode: keyCode)
    }

    return handled ? nil : Unmanaged.passUnretained(event)
}
