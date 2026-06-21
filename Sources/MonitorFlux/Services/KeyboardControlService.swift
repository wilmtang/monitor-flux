import AppKit
import ApplicationServices
import CoreGraphics

/// Intercepts the keyboard's brightness and volume media keys with a `CGEventTap` and
/// routes them to the display under the cursor (DDC), MonitorControl-style (MIT; see
/// ACKNOWLEDGEMENTS.md). Holding Control targets the built-in panel's backlight instead.
/// Requires Accessibility permission, since taps that swallow HID events are privileged.
///
/// VCP-style media-key codes carried in an `NSSystemDefined` event's `data1`.
private enum MediaKey {
    static let soundUp = 0
    static let soundDown = 1
    static let brightnessUp = 2
    static let brightnessDown = 3

    static let managed: Set<Int> = [soundUp, soundDown, brightnessUp, brightnessDown]
}

@MainActor
final class KeyboardControlService {
    weak var store: AppStore?
    private(set) var isActive = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let step = 6

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

    /// Returns true when MonitorFlux handled the key (so the tap swallows the event).
    func handle(keyCode: Int, controlHeld: Bool) -> Bool {
        guard let store else {
            return false
        }
        switch keyCode {
        case MediaKey.brightnessUp:
            return store.adjustBrightnessUnderCursor(by: step, controlBuiltIn: controlHeld)
        case MediaKey.brightnessDown:
            return store.adjustBrightnessUnderCursor(by: -step, controlBuiltIn: controlHeld)
        case MediaKey.soundUp:
            return store.adjustVolumeUnderCursor(by: step)
        case MediaKey.soundDown:
            return store.adjustVolumeUnderCursor(by: -step)
        default:
            return false
        }
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
    let controlHeld = event.flags.contains(.maskControl)

    // Act on key-down; swallow the matching key-up too so the system never sees keys we own.
    let handled = isKeyDown
        ? MainActor.assumeIsolated { service.handle(keyCode: keyCode, controlHeld: controlHeld) }
        : true

    return handled ? nil : Unmanaged.passUnretained(event)
}
