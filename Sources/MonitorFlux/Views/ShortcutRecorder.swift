import Carbon.HIToolbox
import AppKit
import SwiftUI

/// Records a global keyboard shortcut: click to arm, then press a combo (with at least one
/// modifier, so a bare key can't be globally swallowed). Escape cancels; ✕ clears.
///
/// Capture uses an app-level local `NSEvent` monitor rather than an NSView in the responder
/// chain: SwiftUI doesn't reliably route key events to an embedded NSView, but a local
/// monitor sees every key the app receives — including ⌘ combos, which arrive as keyDown
/// events here before they're turned into menu key-equivalents.
struct ShortcutRecorder: View {
    let label: String
    var icon: String?
    var suggestedShortcut: GlobalShortcut?
    var mediaShortcut: MediaKeyShortcut?
    var hasConflict = false
    @Binding var shortcut: ShortcutBinding?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            Text(label)
            Spacer()
            if hasConflict, !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This shortcut is already used by another app — pick a different combination.")
            }
            Button {
                toggle()
            } label: {
                shortcutLabel
                    .frame(minWidth: 104, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press a shortcut, or Escape to cancel" : "Click to record a shortcut")

            Menu {
                if let mediaShortcut {
                    Button("Reset to default (\(mediaShortcut.displayString))") {
                        stop()
                        shortcut = nil
                    }
                    .disabled(shortcut == nil)
                }
                if let suggestedShortcut {
                    Button("Use suggested keyboard shortcut (\(suggestedShortcut.displayString))") {
                        stop()
                        shortcut = .keyboard(suggestedShortcut)
                    }
                }
                Button(mediaShortcut == nil ? "Clear" : "Disable", role: .destructive) {
                    stop()
                    shortcut = mediaShortcut == nil ? nil : .disabled
                }
                .disabled((mediaShortcut == nil && shortcut == nil) || shortcut?.isDisabled == true)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isRecording)
        }
        .onDisappear(perform: stop)
    }

    /// The recorder's trailing affordance: a pill while arming, the shortcut as individual
    /// key-caps once set, and a dashed "Record" slot when empty — cleaner and more native than
    /// the old monospace "⌘⌥B" / "Not set — record" run.
    @ViewBuilder
    private var shortcutLabel: some View {
        if isRecording {
            Text("Press keys…")
                .zoomFont(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor))
        } else if let tokens = displayedTokens {
            HStack(spacing: 3) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    keyCap(token)
                }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                Text("Record")
            }
            .zoomFont(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().strokeBorder(
                    Color.primary.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
            )
        }
    }

    private var displayedTokens: [String]? {
        if shortcut?.isDisabled == true {
            return nil
        }
        if let shortcut {
            return shortcut.displayTokens
        }
        if let mediaShortcut {
            return mediaShortcut.displayTokens
        }
        return nil
    }

    /// One keyboard key-cap: a rounded, slightly raised tile like the shortcut chips in
    /// System Settings.
    private func keyCap(_ token: String) -> some View {
        Text(token)
            .zoomFont(size: 12, weight: .semibold, design: .rounded)
            .frame(minWidth: 18)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.14)))
            )
    }

    private func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKey()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { event in
            if let media = Self.mediaShortcut(from: event) {
                if mediaShortcut?.matches(
                    keyCode: media.keyCode,
                    control: media.control,
                    shift: media.shift,
                    command: media.command
                ) == true {
                    // This action already uses that media key path; leave the custom override
                    // empty so the built-in binding remains visible and active.
                    shortcut = nil
                    stop()
                } else {
                    // User is assigning a different media key to this action.
                    shortcut = .media(media)
                    stop()
                }
                // Swallow managed media keys while recording so testing a binding doesn't
                // also change brightness or volume underneath the recorder.
                return nil
            }

            // A dedicated brightness key arriving as a plain keyDown (modern Apple silicon, codes
            // 144/145) is not an ordinary key — never record it as a Carbon keyboard shortcut. If it
            // didn't resolve to a media binding above, Option was held (which belongs to macOS), so
            // let it pass through to the system untouched.
            if event.type == .keyDown,
               MediaKey.code(forVirtualKeyCode: Int(event.keyCode)) != nil {
                return event
            }

            guard event.type == .keyDown else {
                return event
            }
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            guard let recorded = Self.recordedShortcut(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) else {
                return event
            }
            shortcut = .keyboard(recorded)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    nonisolated static func recordedShortcut(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> GlobalShortcut? {
        let modifiers = carbonModifiers(from: modifierFlags)
        // Require a modifier so a bare key isn't registered (it would be swallowed
        // globally). Let unmodified keys pass through to the app unchanged.
        guard modifiers != 0 else {
            return nil
        }
        return GlobalShortcut(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
    }

    static func mediaShortcut(from event: NSEvent) -> MediaKeyShortcut? {
        switch event.type {
        case .systemDefined:
            // Classic aux-button media keys (volume, and brightness on older Macs / external USB
            // keyboards): the key code and press/release state are packed into `data1`.
            guard event.subtype.rawValue == 8 else {
                return nil
            }
            return mediaShortcut(data1: event.data1, modifierFlags: event.modifierFlags)
        case .keyDown:
            // Modern Apple silicon delivers the dedicated brightness keys as ordinary keyDown
            // events (virtual key codes 144/145), not NSSystemDefined. Map them onto the same
            // media-key codes so recording a brightness key produces a media binding — mirroring
            // the live tap's `resolveMediaKey`, which already handles both delivery paths.
            guard let code = MediaKey.code(forVirtualKeyCode: Int(event.keyCode)) else {
                return nil
            }
            return mediaShortcut(code: code, modifierFlags: event.modifierFlags)
        default:
            return nil
        }
    }

    nonisolated static func mediaShortcut(data1: Int, modifierFlags: NSEvent.ModifierFlags) -> MediaKeyShortcut? {
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        guard isKeyDown else {
            return nil
        }
        return mediaShortcut(code: keyCode, modifierFlags: modifierFlags)
    }

    /// Build a media-key shortcut from an already-resolved `MediaKey` code, applying the rules
    /// shared by both delivery paths: Option belongs to macOS, and only managed keys (brightness /
    /// volume) are bindable.
    nonisolated static func mediaShortcut(code: Int, modifierFlags: NSEvent.ModifierFlags) -> MediaKeyShortcut? {
        // Option + media keys belongs to macOS (e.g. opens Display/Sound preferences).
        guard !modifierFlags.contains(.option) else {
            return nil
        }
        guard MediaKey.managed.contains(code) else {
            return nil
        }
        return MediaKeyShortcut(
            keyCode: code,
            control: modifierFlags.contains(.control),
            shift: modifierFlags.contains(.shift),
            command: modifierFlags.contains(.command)
        )
    }
}
