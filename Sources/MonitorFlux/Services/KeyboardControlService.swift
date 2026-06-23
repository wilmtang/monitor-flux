import AppKit
import ApplicationServices
import CoreGraphics

/// Intercepts the keyboard's brightness and volume media keys with a `CGEventTap` and
/// routes them to the display under the cursor (DDC), MonitorControl-style (MIT; see
/// ACKNOWLEDGEMENTS.md). Brightness keys change brightness; with Control they change
/// contrast; with Shift they nudge the global color temperature. Volume keys change volume.
/// Requires Accessibility permission, since taps that swallow HID events are privileged.
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
    weak var store: AppStore?
    private(set) var isActive = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let step = 6
    /// Media keys whose key-down we handled, so we swallow only their matching key-up.
    /// Without this, a key we let through (e.g. volume on a speakerless monitor) would have
    /// its key-up swallowed anyway, handing the system an unbalanced down-without-up.
    private var ownedKeys: Set<Int> = []

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
    func handleKeyDown(keyCode: Int, control: Bool, shift: Bool) -> Bool {
        let handled = handle(keyCode: keyCode, control: control, shift: shift)
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
    func handle(keyCode: Int, control: Bool, shift: Bool) -> Bool {
        guard let store,
              let command = Self.command(keyCode: keyCode, control: control, shift: shift, step: step)
        else {
            return false
        }
        switch command {
        case .brightness(let delta):
            return store.adjustBrightnessUnderCursor(by: delta)
        case .contrast(let delta):
            return store.adjustContrastUnderCursor(by: delta)
        case .color(let steps):
            return store.adjustColorTemperature(bySteps: steps)
        case .volume(let delta):
            return store.adjustVolumeUnderCursor(by: delta)
        }
    }

    /// The control a media key maps to, given its modifiers (pure, unit-tested):
    /// brightness keys alone change brightness; with Control they change contrast; with
    /// Shift they change the global color temperature. Volume keys change volume.
    nonisolated static func command(keyCode: Int, control: Bool, shift: Bool, step: Int) -> KeyCommand? {
        let direction: Int
        switch keyCode {
        case MediaKey.brightnessUp:
            direction = 1
        case MediaKey.brightnessDown:
            direction = -1
        case MediaKey.soundUp:
            return .volume(step)
        case MediaKey.soundDown:
            return .volume(-step)
        default:
            return nil
        }
        if control {
            return .contrast(direction * step)
        }
        if shift {
            return .color(direction)
        }
        return .brightness(direction * step)
    }
}

/// What a handled media key should do. Color is in ±1 steps (scaled to Kelvin by the store);
/// the rest carry a signed percentage delta.
enum KeyCommand: Equatable {
    case brightness(Int)
    case contrast(Int)
    case color(Int)
    case volume(Int)
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
    let shiftHeld = event.flags.contains(.maskShift)

    // Act on key-down; swallow the matching key-up only if we owned the down, so a key we
    // let through (e.g. volume on a speakerless monitor) reaches the system as a balanced pair.
    let handled = MainActor.assumeIsolated {
        isKeyDown
            ? service.handleKeyDown(keyCode: keyCode, control: controlHeld, shift: shiftHeld)
            : service.consumeKeyUp(keyCode: keyCode)
    }

    return handled ? nil : Unmanaged.passUnretained(event)
}
