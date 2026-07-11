// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var settingsTransferMessage: String?

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
                LabeledContent("Popup background") {
                    HStack(spacing: 6) {
                        Text("\(Int((store.preferences.popupBackdropOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                        Slider(
                            value: Binding(
                                get: { store.preferences.popupBackdropOpacity },
                                set: { newValue in
                                    // Round to whole percent so most drag ticks are no-ops —
                                    // raw values republish the store at mouse-event rate and
                                    // stutter the drag (the warmth/DDC slider fix).
                                    store.updateGlobalPreferences {
                                        $0.popupBackdropOpacity = (newValue * 100).rounded() / 100
                                    }
                                }
                            ),
                            in: 0...1
                        )
                        .labelsHidden()
                        Button("Reset") {
                            store.updateGlobalPreferences {
                                $0.popupBackdropOpacity = AppPreferences.defaultPopupBackdropOpacity
                            }
                        }
                        .settingsPushButton()
                        .disabled(store.preferences.popupBackdropOpacity == AppPreferences.defaultPopupBackdropOpacity)
                    }
                }
                Text("How solid the menu-bar popup looks — 0% keeps the standard translucent panel, 100% is fully solid.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                Toggle("Follow built-in brightness", isOn: Binding {
                    store.preferences.followBuiltInBrightness
                } set: { isOn in
                    store.setFollowBuiltInBrightness(isOn)
                })
                .settingsSwitch()
                Text("External displays follow the built-in display's brightness changes, each keeping its own offset. Displays with a brightness schedule stay on it.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Sync contrast across displays", isOn: Binding {
                    store.preferences.syncContrastAcrossDisplays
                } set: { isOn in
                    store.setContrastSyncAcrossDisplays(isOn)
                })
                .settingsSwitch()
                Text("Adjusting one external display's contrast adjusts them all. Displays with a contrast schedule stay on it.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Enable warmth", isOn: Binding {
                    store.preferences.colorMode != .off
                } set: { isOn in
                    store.updateGlobalPreferences { preferences in
                        // The one warmth on/off state is the mode: off ⇒ Off, on ⇒ Automatic.
                        preferences.colorMode = isOn ? .clock : .off
                    }
                })
                .settingsSwitch()
                Text("Turns warmth — the screen's color temperature — on or off everywhere. It's the same state as **Off** vs **Fixed / Automatic** on the Schedule screen. Warmth tints the image via the display's color tables (\u{201C}gamma\u{201D}); it never touches the real backlight, the monitor's own DDC controls, or volume. Software dimming is separate and keeps working with warmth off.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                Text("The built-in display has no DDC, so its warmth goes through the color tables. With warmth off it simply isn't warmed; its real backlight brightness (the macOS brightness keys) works either way.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Warmth")
            }

            // No Refresh Displays button here: the toolbar button covers every pane, and a
            // second copy on the same screen read as two different actions.
            Section("Backup") {
                Button {
                    exportSettings()
                } label: {
                    Label("Export Settings…", systemImage: "square.and.arrow.up")
                }
                .settingsPushButton()

                Button {
                    importSettings()
                } label: {
                    Label("Import Settings…", systemImage: "square.and.arrow.down")
                }
                .settingsPushButton()

                Text(settingsTransferMessage ?? "Import replaces saved settings and applies current display settings immediately.")
                    .zoomFont(.caption)
                    .foregroundStyle(settingsTransferMessage == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Version was previously only visible in the hidden Diagnostics pane — bug reports
            // need it reachable without knowing about ⌘⇧D. The commit + build date live only in
            // Diagnostics (developer detail), not here.
            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    @MainActor
    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MonitorFlux-Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try store.exportedPreferencesData().write(to: url, options: .atomic)
            settingsTransferMessage = "Exported settings to \(url.lastPathComponent)."
        } catch {
            settingsTransferMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let importedCompletely = try store.importPreferences(from: Data(contentsOf: url))
            // Both caveats can hold at once (a dev build in safe mode is exactly where the
            // login-item service rejects), so append rather than pick one.
            var message = store.safeMode
                ? "Imported settings. Safe mode skipped hardware writes."
                : "Imported settings and applied current display settings."
            if !importedCompletely {
                message += " Start at login could not be changed: \(store.loginItemMessage)"
            }
            settingsTransferMessage = message
        } catch {
            settingsTransferMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
