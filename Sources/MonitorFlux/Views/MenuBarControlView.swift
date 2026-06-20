import SwiftUI

struct MenuBarControlView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Text("MonitorFlux")
            .font(.headline)

        Text(store.currentTemperature.map { "\($0) K" } ?? "Gamma off")
            .foregroundStyle(.secondary)

        Divider()

        Toggle("Warm Color", isOn: Binding {
            store.preferences.colorMode != .off
        } set: { isOn in
            store.updateGlobalPreferences { preferences in
                if isOn {
                    preferences.gammaEnabled = true
                }
                preferences.colorMode = isOn ? .clock : .off
            }
        })

        Toggle("Gamma Controls", isOn: Binding {
            store.preferences.gammaEnabled
        } set: { isOn in
            store.updateGlobalPreferences { preferences in
                preferences.gammaEnabled = isOn
            }
        })

        Divider()

        ForEach(store.displays.filter { !$0.isBuiltIn }) { display in
            Menu(display.name) {
                Button("Brightness -5%") {
                    store.nudgeHardwareBrightness(for: display, by: -5)
                }

                Button("Brightness +5%") {
                    store.nudgeHardwareBrightness(for: display, by: 5)
                }

                Button("Apply Brightness") {
                    store.applyBrightness(for: display)
                }
            }
        }

        Divider()

        Button("Open MonitorFlux") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Refresh Displays") {
            store.refreshDisplays()
        }

        Divider()

        Button("Quit MonitorFlux") {
            NSApp.terminate(nil)
        }
    }
}
