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
    var defaultShortcut: GlobalShortcut?
    var mediaShortcut: MediaKeyShortcut?
    var hasConflict = false
    @Binding var shortcut: GlobalShortcut?

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
                if let defaultShortcut {
                    Button("Reset to default (\(defaultShortcut.displayString))") {
                        stop()
                        shortcut = defaultShortcut
                    }
                }
                Button("Disable", role: .destructive) {
                    stop()
                    shortcut = nil
                }
                .disabled(shortcut == nil)
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
                .font(.callout)
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
            .font(.callout)
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
            .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                    shift: media.shift
                ) == true {
                    // This action already uses that media key path; leave the custom override
                    // empty so the built-in binding remains visible and active.
                    shortcut = nil
                    stop()
                }
                // Swallow managed media keys while recording so testing a binding doesn't
                // also change brightness or volume underneath the recorder.
                return nil
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
            shortcut = recorded
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
        guard event.type == .systemDefined,
              event.subtype.rawValue == 8 else {
            return nil
        }
        return mediaShortcut(data1: event.data1, modifierFlags: event.modifierFlags)
    }

    nonisolated static func mediaShortcut(data1: Int, modifierFlags: NSEvent.ModifierFlags) -> MediaKeyShortcut? {
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        guard MediaKey.managed.contains(keyCode) else {
            return nil
        }
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        guard isKeyDown else {
            return nil
        }
        return MediaKeyShortcut(
            keyCode: keyCode,
            control: modifierFlags.contains(.control),
            shift: modifierFlags.contains(.shift)
        )
    }
}
