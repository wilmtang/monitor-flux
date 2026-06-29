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
                LabeledContent("Window zoom") {
                    HStack(spacing: 8) {
                        Button("−") { store.decreaseFontSize() }
                            .buttonStyle(.borderless)
                            .disabled(store.preferences.fontSizeStep <= AppPreferences.fontSizeStepRange.lowerBound)
                        Text("\(Int((store.preferences.settingsZoomScale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(minWidth: 36, alignment: .center)
                        Button("+") { store.increaseFontSize() }
                            .buttonStyle(.borderless)
                            .disabled(store.preferences.fontSizeStep >= AppPreferences.fontSizeStepRange.upperBound)
                        Divider().frame(height: 14)
                        Button("Reset") { store.resetFontSize() }
                            .buttonStyle(.borderless)
                            .disabled(store.preferences.fontSizeStep == AppPreferences.defaultFontSizeStep)
                    }
                }
                Text("Scales this settings window. Also ⌘+ / ⌘− / ⌘0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard") {
                if !store.accessibilityTrusted {
                    accessibilityWarning
                }
                Toggle("Use media-key shortcuts", isOn: Binding {
                    store.preferences.keyboardControlEnabled
                } set: { isOn in
                    store.setKeyboardControl(isOn)
                })
                VStack(alignment: .leading, spacing: 3) {
                    keyHint("Brightness keys", "brightness of the display under your pointer (DDC)")
                    keyHint("⌃ Control + brightness", "contrast (external monitor)")
                    keyHint("⌘ Command + brightness", "built-in brightness")
                    keyHint("⇧ Shift + brightness down/up", "warmth warmer / cooler")
                    keyHint("Volume keys", "macOS system volume unless recorded below")
                }
                .padding(.vertical, 2)
                Text("Works when this toggle is on and Accessibility is granted. Brightness/contrast act on the external display under your pointer; Command + brightness targets the built-in display; warmth is global.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(HotKeyGroup.allCases.enumerated()), id: \.element) { index, group in
                Section {
                    ForEach(HotKeyAction.allCases.filter { $0.group == group }) { action in
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if index == 0 {
                        Text("Keyboard shortcuts (⌘⌥⌃⇧ combos) work anywhere and need no Accessibility permission. Media-key shortcuts (brightness/volume keys) require the keyboard control toggle and Accessibility.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if store.hasInactiveMediaBindings {
                            mediaBindingWarning
                        }
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
                Text("The built-in display has no DDC, so everything MonitorFlux changes on it — warmth and software dimming — goes through the color tables. With this off, the built-in display can't be adjusted here; only its real backlight brightness (the macOS brightness keys) still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("Media-key shortcuts need Accessibility")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(store.preferences.keyboardControlEnabled
                    ? "MonitorFlux doesn't have Accessibility permission, so it can't intercept media-key shortcuts. Grant it in System Settings; they will start when you return. (The normal-key shortcuts below work without this.)"
                    : "Turn on media-key shortcuts, then grant Accessibility so MonitorFlux can intercept those keys. (The normal-key shortcuts below work without this.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(store.preferences.keyboardControlEnabled ? "Open Accessibility Settings…" : "Enable Keyboard Control…") {
                    if store.preferences.keyboardControlEnabled {
                        store.requestAccessibility()
                    } else {
                        store.setKeyboardControl(true)
                    }
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

    private var mediaBindingWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 5) {
                Text("Media-key shortcuts won't fire")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text("You have shortcuts assigned to brightness or volume keys, but keyboard control is turned off. Enable it above so the media-key tap can intercept those keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Enable Keyboard Control…") {
                    store.setKeyboardControl(true)
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
