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
                if store.loginItemNeedsInstall {
                    Text("“Start at login” uses macOS's login-items service, which only registers an **installed** app. “Not available” means you're running a development build (launched from a build folder, not /Applications) — it works once the app is moved to Applications. Accessibility is different: it's granted to the running app by its signature, so it works either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Show Diagnostics", isOn: Binding {
                    store.preferences.showDiagnostics
                } set: { isOn in
                    store.updateGlobalPreferences { $0.showDiagnostics = isOn }
                })
                Text("Adds a developer-facing Diagnostics pane (color pipeline, DDC, displays) to the sidebar. Also reachable with ⌘⇧D.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Keyboard") {
                if !store.accessibilityTrusted {
                    accessibilityWarning
                }
                Toggle("Use brightness & volume keys", isOn: Binding {
                    store.preferences.keyboardControlEnabled
                } set: { isOn in
                    store.setKeyboardControl(isOn)
                })
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

            ForEach(Array(HotKeyGroup.allCases.enumerated()), id: \.element) { index, group in
                Section {
                    ForEach(HotKeyAction.allCases.filter { $0.group == group }) { action in
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
                    Text(group.footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if index == 0 {
                        Text("Global shortcuts — they work anywhere and need no Accessibility permission. Press a combo with at least one modifier (⌘⌥⌃⇧).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(index == 0 ? "Custom Shortcuts · \(group.label)" : group.label)
                }
            }

            Section {
                Toggle("Enable warmth", isOn: Binding {
                    store.preferences.gammaEnabled
                } set: { isOn in
                    store.updateGlobalPreferences { preferences in
                        preferences.gammaEnabled = isOn
                    }
                })
                Text("Master switch for warmth — warming the color and dimming the image via the display's color tables (\u{201C}gamma\u{201D}). Off means no warming or software dimming on **any** display (only the monitors' own controls and macOS color remain). On means each display follows its **own** Warmth and software-dimming settings on its Display screen. Same setting as \u{201C}Warmth\u{201D} on the Schedule screen; doesn't affect real backlight, the monitor's own DDC controls, or volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Warmth")
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

    private var accessibilityWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 5) {
                Text("Brightness & volume keys need Accessibility")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text("MonitorFlux doesn't have Accessibility permission, so it can't intercept the media keys. Click below, then enable MonitorFlux in the list. (The custom shortcuts below work without this.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings…") {
                    store.requestAccessibility()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.25)))
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
