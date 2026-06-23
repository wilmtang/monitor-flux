import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: AppSelection? = .color

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("General", systemImage: "gearshape")
                        .tag(AppSelection.general)
                }

                Section("Color") {
                    Label("Schedule", systemImage: "sun.max")
                        .tag(AppSelection.color)
                }

                Section("Displays") {
                    ForEach(store.displays) { display in
                        Label(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                            .tag(AppSelection.display(display.key))
                    }
                }

                Section {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                        .tag(AppSelection.diagnostics)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            detailView
                .toolbar {
                    ToolbarItem {
                        Button {
                            store.refreshDisplays()
                        } label: {
                            Label("Refresh Displays", systemImage: "arrow.clockwise")
                        }
                    }
                }
        }
        .onAppear {
            if selection == nil {
                selection = .color
            }
            // Test hook: jump straight to a pane so a smoke/screenshot run can verify it
            // without scripting the sidebar.
            switch ProcessInfo.processInfo.environment["MONITORFLUX_SELECT"] {
            case "general":
                selection = .general
            case "display":
                if let display = store.displays.first(where: { !$0.isBuiltIn }) ?? store.displays.first {
                    selection = .display(display.key)
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            SettingsView()
        case .color, .none:
            ColorScheduleView()
        case .diagnostics:
            DiagnosticsView()
        case .display(let key):
            if let display = store.displays.first(where: { $0.key == key }) {
                DisplayDetailView(display: display)
            } else {
                ContentUnavailableView("Display unavailable", systemImage: "display.trianglebadge.exclamationmark")
            }
        }
    }
}
