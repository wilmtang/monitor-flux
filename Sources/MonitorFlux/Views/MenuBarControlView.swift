import SwiftUI

struct MenuBarControlView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MonitorFlux")
                    .font(.headline)
                Spacer()
                Text(store.currentTemperature.map { "\($0) K" } ?? "Off")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Toggle("Warm Color", isOn: Binding {
                store.preferences.gammaEnabled && store.preferences.colorMode != .off
            } set: { isOn in
                store.updateGlobalPreferences { preferences in
                    preferences.gammaEnabled = isOn
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(display.name)
                        .font(.caption)
                        .lineLimit(1)
                    HStack {
                        Slider(value: displaySliderBinding(display, \.hardwareBrightness), in: 0...100, step: 1)
                            .disabled(!store.canUseDDC(for: display))
                        Button {
                            store.applyBrightness(for: display)
                        } label: {
                            Label("Apply", systemImage: "sun.max")
                        }
                        .disabled(!store.canUseDDC(for: display))
                    }
                }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open MonitorFlux", systemImage: "macwindow")
            }

            Button {
                store.refreshDisplays()
            } label: {
                Label("Refresh Displays", systemImage: "arrow.clockwise")
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit MonitorFlux", systemImage: "power")
            }
        }
        .frame(width: 300)
        .padding()
    }

    private func displaySliderBinding(
        _ display: DisplayInfo,
        _ keyPath: WritableKeyPath<DisplayPreferences, Int>
    ) -> Binding<Double> {
        Binding {
            Double(store.displayPreferences(for: display)[keyPath: keyPath])
        } set: { newValue in
            store.updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences[keyPath: keyPath] = Int(newValue.rounded()).clamped(to: 0...100)
            }
        }
    }
}
