import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: AppSelection? = .general
    // Bound so a sidebar collapsed by dragging the divider can always be brought back via the
    // toolbar toggle below — without it, NavigationSplitView's drag-to-collapse strands the user
    // with no sidebar and no way to restore it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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

                // Developer-facing; hidden unless turned on in General (or reached with ⌘⇧D).
                if store.preferences.showDiagnostics {
                    Section {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
                            .tag(AppSelection.diagnostics)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            detailView
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                            }
                        } label: {
                            Label("Toggle Sidebar", systemImage: "sidebar.left")
                        }
                        .keyboardShortcut("s", modifiers: [.control, .command])
                        .help("Show or hide the sidebar")
                    }
                    ToolbarItem {
                        Button {
                            store.refreshDisplays()
                        } label: {
                            Label("Refresh Displays", systemImage: "arrow.clockwise")
                        }
                        // Show the title next to the icon — a bare circular arrow reads as
                        // "restart" and gives no hint that it re-scans monitors.
                        .labelStyle(.titleAndIcon)
                        .help("Re-scan connected monitors and re-apply their saved brightness & contrast. Use this if a display isn't detected or looks out of sync. (This does not restart the app.)")
                    }
                }
        }
        .onAppear {
            if selection == nil {
                selection = .general
            }
            // Test hook: jump straight to a pane so a smoke/screenshot run can verify it
            // without scripting the sidebar.
            switch ProcessInfo.processInfo.environment["MONITORFLUX_SELECT"] {
            case "general":
                selection = .general
            case "color":
                selection = .color
            case "diagnostics":
                selection = .diagnostics
            case "display":
                if let display = store.displays.first(where: { !$0.isBuiltIn }) ?? store.displays.first {
                    selection = .display(display.key)
                }
            case let value? where value.hasPrefix("display:"):
                // `display:<name substring>` targets a specific display pane for verification
                // (e.g. `display:AirPlay`), since the bare `display` hook only picks the first external.
                let needle = String(value.dropFirst("display:".count))
                if let display = store.displays.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) {
                    selection = .display(display.key)
                }
            default:
                break
            }
            applyRequestedSelection()
        }
        .onChange(of: store.requestedSelection) { _, _ in
            applyRequestedSelection()
        }
        .background {
            // Diagnostics is developer-facing, so it's no longer a sidebar item; reach it
            // with ⌘⇧D. The MONITORFLUX_SELECT=diagnostics hook also jumps here for tests.
            Button("Show Diagnostics") { selection = .diagnostics }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .hidden()
        }
    }

    /// Honor a pane requested from the menu-bar popup (which may be set before this window even
    /// exists), then clear it so it applies once.
    private func applyRequestedSelection() {
        if let requested = store.requestedSelection {
            selection = requested
            store.requestedSelection = nil
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
