import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Color Pipeline") {
                LabeledContent("Owner", value: "MonitorFlux")
                LabeledContent("Current", value: store.currentTemperature.map(KelvinFormatting.label(for:)) ?? "Off")
                LabeledContent("Gamma", value: store.colorMessage)
                LabeledContent("Gamma enabled", value: store.preferences.gammaEnabled ? "Yes" : "No")

                Button {
                    store.disableColorAndRestore()
                } label: {
                    Label("Disable Gamma and Restore", systemImage: "arrow.uturn.backward.circle")
                }
            }

            Section("DDC") {
                LabeledContent("Backend", value: store.ddcStatus.toolName)
                LabeledContent("Fallback path", value: store.ddcStatus.toolPath ?? "None")
                LabeledContent("Status", value: store.ddcMessage)
            }

            Section("Displays") {
                ForEach(store.displays) { display in
                    LabeledContent(display.name, value: display.kindLabel)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }
}
