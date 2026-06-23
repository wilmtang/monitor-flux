import Carbon.HIToolbox
import SwiftUI

/// A control that records a global keyboard shortcut: click to arm, then press a combo (with
/// at least one modifier, so a bare key can't be globally swallowed). Escape cancels; the ✕
/// clears it. Captures via a local key monitor while the Settings window is focused.
struct ShortcutRecorder: View {
    let label: String
    var hasConflict = false
    @Binding var shortcut: GlobalShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            if hasConflict, !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This shortcut is already used by another app — pick a different combination.")
            }
            Button(action: toggle) {
                Text(buttonTitle)
                    .font(.callout.monospaced())
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "Press a shortcut, or Escape to cancel" : "Record a shortcut")

            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(shortcut != nil && !isRecording ? 1 : 0)
            .disabled(shortcut == nil || isRecording)
        }
        .onDisappear(perform: stop)
    }

    private var buttonTitle: String {
        if isRecording {
            return "Press keys…"
        }
        return shortcut?.displayString ?? "Record"
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let modifiers = Self.carbonModifiers(from: event.modifierFlags)
            // Require a modifier so we never register a bare key that would be swallowed
            // globally (which would break normal typing of that key).
            guard modifiers != 0 else {
                return nil
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

    private func clear() {
        shortcut = nil
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
