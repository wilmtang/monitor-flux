import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            // No header on the first section: the pane is already titled "General" in the
            // window's title bar, and repeating it directly underneath reads as a stutter.
            Section {
                Toggle("Show in Dock", isOn: Binding {
                    store.preferences.showInDock
                } set: { isOn in
                    store.setShowInDock(isOn)
                })
                .settingsSwitch()
                Toggle("Start at login", isOn: Binding {
                    store.preferences.startAtLogin
                } set: { isOn in
                    store.setStartAtLogin(isOn)
                })
                .settingsSwitch()
                LabeledContent("Login item", value: store.loginItemMessage)
                if store.loginItemNeedsInstall {
                    Text("“Start at login” uses macOS's login-items service, which only registers an **installed** app. “Not available” means you're running a development build (launched from a build folder, not /Applications) — it works once the app is moved to Applications. Accessibility is different: it's granted to the running app by its signature, so it works either way.")
                        .zoomFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Show Diagnostics", isOn: Binding {
                    store.preferences.showDiagnostics
                } set: { isOn in
                    store.updateGlobalPreferences { $0.showDiagnostics = isOn }
                })
                .settingsSwitch()
                Text("Adds a developer-facing Diagnostics pane (color pipeline, DDC, displays) to the sidebar. Also reachable with ⌘⇧D.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Window zoom") {
                    HStack(spacing: 6) {
                        Text("\(Int((store.preferences.settingsZoomScale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                        Stepper(
                            "",
                            value: Binding(
                                get: { store.preferences.fontSizeStep },
                                set: { newStep in
                                    if newStep > store.preferences.fontSizeStep {
                                        store.increaseFontSize()
                                    } else {
                                        store.decreaseFontSize()
                                    }
                                }
                            ),
                            in: AppPreferences.fontSizeStepRange
                        )
                        .labelsHidden()
                        Button("Reset") { store.resetFontSize() }
                            .settingsPushButton()
                            .disabled(store.preferences.fontSizeStep == AppPreferences.defaultFontSizeStep)
                    }
                }
                Text("Scales this window's text and controls. Also ⌘+ / ⌘− / ⌘0.")
                    .zoomFont(.caption)
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

            Section {
                Toggle("Enable warmth", isOn: Binding {
                    store.preferences.gammaEnabled
                } set: { isOn in
                    store.updateGlobalPreferences { preferences in
                        preferences.gammaEnabled = isOn
                    }
                })
                .settingsSwitch()
                Text("Master switch for warmth — warming the color and dimming the image via the display's color tables (\u{201C}gamma\u{201D}). Off means no warming or software dimming on **any** display (only the monitors' own controls and macOS color remain). On means each display follows its **own** Warmth and software-dimming settings on its Display screen. Same setting as \u{201C}Warmth\u{201D} on the Schedule screen; doesn't affect real backlight, the monitor's own DDC controls, or volume.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                Text("The built-in display has no DDC, so everything MonitorFlux changes on it — warmth and software dimming — goes through the color tables. With this off, the built-in display can't be adjusted here; only its real backlight brightness (the macOS brightness keys) still works.")
                    .zoomFont(.caption)
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
                .settingsPushButton()
            }

            // Version was previously only visible in the hidden Diagnostics pane — bug reports
            // need it reachable without knowing about ⌘⇧D. The commit + build date (VS Code
            // style) pin down exactly what shipped; both are stamped into Info.plist at build
            // time, so they only appear on a real bundle, not an unbundled `swift run`.
            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
                if let commit = AppInfo.commit {
                    LabeledContent("Commit") {
                        Text(commit)
                            .zoomFont(.body, design: .monospaced)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .trailing)
                    }
                }
                if let buildDate = AppInfo.buildDate {
                    LabeledContent("Built", value: buildDate)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
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
