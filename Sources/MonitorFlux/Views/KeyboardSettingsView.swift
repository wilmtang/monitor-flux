import SwiftUI

struct KeyboardSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            // No header on the first section: the pane is already titled "Keyboard" in the
            // window's title bar, and repeating it directly underneath reads as a stutter.
            Section {
                if !store.accessibilityTrusted {
                    accessibilityWarning
                }
                Toggle("Use media-key shortcuts", isOn: Binding {
                    store.preferences.keyboardControlEnabled
                } set: { isOn in
                    store.setKeyboardControl(isOn)
                })
                .settingsSwitch()
                VStack(alignment: .leading, spacing: 3) {
                    keyHint("Brightness keys", "brightness of the display under your pointer (DDC)")
                    keyHint("⌃ Control + brightness", "contrast (external monitor)")
                    keyHint("⌘ Command + brightness", "built-in brightness")
                    keyHint("⇧ Shift + brightness down/up", "warmth warmer / cooler")
                    if store.preferences.fineAdjustmentsEnabled {
                        keyHint("⌥ Option + any combo above", "the same control, in small steps")
                    }
                    keyHint("Volume keys", "macOS system volume unless recorded below")
                }
                .padding(.vertical, 2)
                Text("Works when this toggle is on and Accessibility is granted. Brightness/contrast act on the external display under your pointer; Command + brightness targets the built-in display; warmth is global.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Fine adjustments", isOn: Binding {
                    store.preferences.fineAdjustmentsEnabled
                } set: { isOn in
                    store.setFineAdjustments(isOn)
                })
                .settingsSwitch()
                Text("Hold ⌥ Option with any MonitorFlux shortcut to adjust in small, precise steps — 1% instead of 6%, and subtler warmth. The fine shortcuts appear below, where each can be re-recorded. While this is on, ⌥ + brightness keys go to MonitorFlux instead of opening Displays settings.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(HotKeyGroup.allCases.enumerated()), id: \.element) { index, group in
                Section {
                    // Fine (⌥) variants surface only while "Fine adjustments" is on — no dead
                    // recorder rows for shortcuts that wouldn't fire.
                    ForEach(HotKeyAction.allCases.filter {
                        $0.group == group && (!$0.isFine || store.preferences.fineAdjustmentsEnabled)
                    }) { action in
                        ShortcutRecorder(
                            label: action.label,
                            icon: action.icon,
                            suggestedShortcut: action.suggestedKeyboardShortcut,
                            mediaShortcut: action.mediaShortcut,
                            hasConflict: store.hotkeyConflicts.contains(action),
                            shortcut: Binding {
                                store.hotkey(for: action)
                            } set: { newValue in
                                store.setHotkey(newValue, for: action)
                            }
                        )
                    }
                    Text(group.footnote)
                        .zoomFont(.caption)
                        .foregroundStyle(.secondary)
                    if index == 0 {
                        Text("Keyboard shortcuts (⌘⌥⌃⇧ combos) work anywhere and need no Accessibility permission. Media-key shortcuts (brightness/volume keys) require the keyboard control toggle and Accessibility.")
                            .zoomFont(.caption)
                            .foregroundStyle(.secondary)
                        if store.hasInactiveMediaBindings {
                            mediaBindingWarning
                        }
                    }
                } header: {
                    Text(index == 0 ? "Custom Shortcuts · \(group.label)" : group.label)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keyboard")
    }

    private var accessibilityWarning: some View {
        WarningCard(
            title: "Media-key shortcuts need Accessibility",
            message: store.preferences.keyboardControlEnabled
                ? "MonitorFlux doesn't have Accessibility permission, so it can't intercept media-key shortcuts. Grant it in System Settings; they will start when you return. (The normal-key shortcuts below work without this.)"
                : "Turn on media-key shortcuts, then grant Accessibility so MonitorFlux can intercept those keys. (The normal-key shortcuts below work without this.)"
        ) {
            Button(store.preferences.keyboardControlEnabled ? "Open Accessibility Settings…" : "Enable Keyboard Control…") {
                if store.preferences.keyboardControlEnabled {
                    store.requestAccessibility()
                } else {
                    store.setKeyboardControl(true)
                }
            }
        }
    }

    private var mediaBindingWarning: some View {
        WarningCard(
            title: "Media-key shortcuts won't fire",
            message: "You have shortcuts assigned to brightness or volume keys, but keyboard control is turned off. Enable it above so the media-key tap can intercept those keys."
        ) {
            Button("Enable Keyboard Control…") {
                store.setKeyboardControl(true)
            }
        }
    }

    private func keyHint(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .zoomFont(.caption, design: .monospaced)
                .foregroundStyle(.primary)
            Text("→ \(action)")
                .zoomFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
