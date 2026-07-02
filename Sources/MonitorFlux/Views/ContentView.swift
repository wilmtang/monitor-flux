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
            // The sidebar list style applies its own label/header fonts, ignoring both
            // the root environment font and a .font() on the Label itself — the zoom
            // font must sit directly on the Text/Image inside each label (deepest
            // modifier wins) and on each section header.
            List(selection: $selection) {
                Section {
                    sidebarRow("General", systemImage: "gearshape")
                        .tag(AppSelection.general)
                }

                Section {
                    sidebarRow("Schedule", systemImage: "sun.max")
                        .tag(AppSelection.color)
                } header: {
                    Text("Color").font(sidebarSectionFont)
                }

                Section {
                    ForEach(store.displays) { display in
                        sidebarRow(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                            .tag(AppSelection.display(display.key))
                    }
                } header: {
                    Text("Displays").font(sidebarSectionFont)
                }

                // Developer-facing; hidden unless turned on in General (or reached with ⌘⇧D).
                if store.preferences.showDiagnostics {
                    Section {
                        sidebarRow("Diagnostics", systemImage: "waveform.path.ecg")
                            .tag(AppSelection.diagnostics)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: (210 * store.preferences.settingsColumnScale).rounded(),
                ideal: (240 * store.preferences.settingsColumnScale).rounded()
            )
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
        .font(.system(size: store.preferences.settingsFontSize))
        .controlSize(store.preferences.settingsControlSize)
        .environment(\.settingsZoomScale, store.preferences.settingsZoomScale)
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

            Button("Increase zoom") { store.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
                .hidden()
            Button("Increase zoom") { store.increaseFontSize() }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
            Button("Decrease zoom") { store.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
                .hidden()
            Button("Reset zoom") { store.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
                .hidden()
        }
    }

    private func sidebarRow(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).font(sidebarRowFont)
        } icon: {
            Image(systemName: systemImage).font(sidebarRowFont)
        }
        .labelStyle(SidebarRowLabelStyle(fontSize: store.preferences.settingsFontSize))
    }

    private var sidebarRowFont: Font {
        .system(size: store.preferences.settingsFontSize)
    }

    private var sidebarSectionFont: Font {
        .system(size: (store.preferences.settingsFontSize * 11 / 13).rounded())
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

/// The system sidebar label style reserves a fixed-width icon column sized for
/// default text; a zoomed 26pt symbol overflows it and visually touches the title.
/// This style scales both the icon column and the icon–title gap with the zoom.
private struct SidebarRowLabelStyle: LabelStyle {
    let fontSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: (fontSize * 0.45).rounded()) {
            configuration.icon
                .frame(width: (fontSize * 1.35).rounded())
            configuration.title
        }
    }
}

// MARK: - Semantic window zoom
//
// The window zoom (⌘+/⌘-/⌘0, "Window zoom" in General) is implemented purely as
// SwiftUI sizing: scaled default font, explicit fonts where styles ignore the
// environment (sidebar rows/headers, `zoomFont` for fixed text styles — Dynamic
// Type is inert on macOS), and discrete control sizes. There is deliberately NO
// geometric transform anywhere: every transform mechanism (NSView bounds scaling,
// CALayer transforms, NSScrollView.magnification, .scaleEffect) breaks click
// routing for SwiftUI content hosted in a large NSHostingView. Measured in
// prototype-zoom-matrix/; analysis in docs/ZOOM_PLAN.md.
extension AppPreferences {
    /// Body-text size derived from the zoom scale (13pt at 100%), half-point rounded.
    var settingsFontSize: CGFloat {
        (13 * settingsZoomScale * 2).rounded() / 2
    }

    /// Controls (steppers, buttons, pickers) only come in discrete sizes; step them
    /// alongside the text so they don't stay miniature at high zoom.
    var settingsControlSize: ControlSize {
        switch fontSizeStep.clamped(to: Self.fontSizeStepRange) {
        case ...1: .small
        case 2...4: .regular
        case 5...6: .large
        default: .extraLarge
        }
    }

    /// Switches run one size below `settingsControlSize`: System Settings pairs 13 pt row
    /// labels with the compact 15 pt switch, and SwiftUI's regular switch (22 pt) floats its
    /// label ~1 pt above the pill's center — both measured against System Settings pixels.
    /// The mini switch reproduces the native pairing exactly; see `View.settingsSwitch()`.
    var settingsSwitchControlSize: ControlSize {
        switch fontSizeStep.clamped(to: Self.fontSizeStepRange) {
        case ...4: .mini
        case 5...6: .small
        default: .regular
        }
    }

    /// Sidebar column widths track the text size so labels don't truncate at high zoom.
    var settingsColumnScale: CGFloat {
        settingsFontSize / 13
    }
}
