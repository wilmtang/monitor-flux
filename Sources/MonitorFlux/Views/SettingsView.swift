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

            Section("Gamma") {
                Toggle("Enable gamma", isOn: Binding {
                    store.preferences.gammaEnabled
                } set: { isOn in
                    store.updateGlobalPreferences { preferences in
                        preferences.gammaEnabled = isOn
                    }
                })
                LabeledContent("Pipeline owner", value: "MonitorFlux")
                LabeledContent("Status", value: store.colorMessage)
            }

            Section("Runtime") {
                LabeledContent("DDC backend", value: store.ddcStatus.message)
                LabeledContent("DDC fallback", value: store.ddcStatus.toolPath ?? "No external tool")
                LabeledContent("Login item", value: store.loginItemMessage)
            }

            Section("Actions") {
                Button {
                    store.refreshDisplays()
                } label: {
                    Label("Refresh Displays", systemImage: "arrow.clockwise")
                }

                Button {
                    store.disableColorAndRestore()
                } label: {
                    Label("Disable Gamma and Restore", systemImage: "arrow.uturn.backward.circle")
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
