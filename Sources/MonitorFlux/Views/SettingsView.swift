import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in Dock", isOn: Binding {
                    store.preferences.showInDock
                } set: { isOn in
                    store.setShowInDock(isOn)
                })
                Toggle("Start at login", isOn: Binding {
                    store.preferences.startAtLogin
                } set: { isOn in
                    store.setStartAtLogin(isOn)
                })
                LabeledContent("Login item", value: store.loginItemMessage)
            }

            Section("Keyboard") {
                Toggle("Use brightness & volume keys", isOn: Binding {
                    store.preferences.keyboardControlEnabled
                } set: { isOn in
                    store.setKeyboardControl(isOn)
                })
                LabeledContent("Status", value: store.keyboardStatus)
                VStack(alignment: .leading, spacing: 3) {
                    keyHint("Brightness keys", "brightness of the display under your pointer (DDC)")
                    keyHint("⌃ Control + brightness", "contrast")
                    keyHint("⇧ Shift + brightness", "color temperature (warmer / cooler)")
                    keyHint("Volume keys", "volume")
                }
                .padding(.vertical, 2)
                Text("Acts on the external display under your pointer; the built-in panel's brightness is left to macOS. Requires Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(HotKeyAction.allCases) { action in
                    ShortcutRecorder(
                        label: action.label,
                        icon: action.icon,
                        defaultShortcut: action.defaultShortcut,
                        hasConflict: store.hotkeyConflicts.contains(action),
                        shortcut: Binding {
                            store.hotkey(for: action)
                        } set: { newValue in
                            store.setHotkey(newValue, for: action)
                        }
                    )
                }
                Text("Optional global shortcuts for each control, in addition to the keys above. These work anywhere and don't need Accessibility permission. Use at least one modifier (⌘⌥⌃⇧).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Custom Shortcuts")
            }

            Section {
                Toggle("Warm colors & software dimming", isOn: Binding {
                    store.preferences.gammaEnabled
                } set: { isOn in
                    store.updateGlobalPreferences { preferences in
                        preferences.gammaEnabled = isOn
                    }
                })
                Text("Lets MonitorFlux warm the color and dim the image via the display's color tables (\u{201C}gamma\u{201D}). Turn off to use only the monitor's own brightness/contrast (DDC) and macOS color. Live status is on the Diagnostics screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Color")
            }

            Section("Actions") {
                Button {
                    store.refreshDisplays()
                } label: {
                    Label("Refresh Displays", systemImage: "arrow.clockwise")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func keyHint(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
            Text("→ \(action)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
