import Carbon.HIToolbox
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
                Text(buttonTitle)
                    .font(.callout.monospaced())
                    .foregroundStyle(shortcut == nil && !isRecording ? .secondary : .primary)
                    .frame(minWidth: 104)
            }
            .buttonStyle(.bordered)
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

    private var buttonTitle: String {
        if isRecording {
            return "Press keys…"
        }
        return shortcut?.displayString ?? "Not set — record"
    }

    private func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let modifiers = Self.carbonModifiers(from: event.modifierFlags)
            // Require a modifier so a bare key isn't registered (it would be swallowed
            // globally). Let unmodified keys pass through to the app unchanged.
            guard modifiers != 0 else {
                return event
            }
            shortcut = GlobalShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
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

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
