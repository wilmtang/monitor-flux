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
}
