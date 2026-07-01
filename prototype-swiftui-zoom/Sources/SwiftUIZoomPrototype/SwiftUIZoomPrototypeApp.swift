import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// Pure SwiftUI zoom prototype — tests whether .scaleEffect() correctly
// handles hit testing inside a NavigationSplitView (the real-world case).
//
// Run:  cd prototype-swiftui-zoom && swift run
// Keys: Cmd+  Cmd-  Cmd0
// ---------------------------------------------------------------------------

private let zoomSteps: [CGFloat] = [0.70, 0.80, 0.90, 1.00, 1.10, 1.25, 1.50, 1.75, 2.00]

// MARK: - Observable zoom state

@MainActor
private final class ZoomState: ObservableObject {
    @Published var index: Int = 3
    var scale: CGFloat { zoomSteps[index] }

    func zoomIn()  { index = min(index + 1, zoomSteps.count - 1); logZoom() }
    func zoomOut() { index = max(index - 1, 0); logZoom() }
    func reset()   { index = 3; logZoom() }

    private func logZoom() {
        print("[ZOOM] \(String(format: "%.2f", Double(scale)))")
        fflush(stdout)
    }
}

// MARK: - Root view: GeometryReader + scaleEffect

private struct ZoomedRootView: View {
    @ObservedObject var zoom: ZoomState

    var body: some View {
        GeometryReader { proxy in
            let s = zoom.scale
            DemoContentView(zoom: zoom)
                .frame(width: proxy.size.width / s, height: proxy.size.height / s)
                .scaleEffect(s, anchor: .topLeading)
        }
    }
}

// MARK: - Demo content: NavigationSplitView with interactive controls

private struct DemoContentView: View {
    @ObservedObject var zoom: ZoomState
    @State private var selection: String? = "Settings"
    @State private var toggleA = false
    @State private var toggleB = true
    @State private var sliderValue = 0.5
    @State private var stepperValue = 3
    @State private var textFieldValue = "type here"
    @State private var clickLog = "No clicks yet"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Settings", systemImage: "gearshape").tag("Settings")
                Label("Display", systemImage: "display").tag("Display")
                Label("Audio", systemImage: "speaker.wave.2").tag("Audio")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 220)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case "Settings":
            settingsDetail
        case "Display":
            Text("Display detail placeholder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            Text("Select an item")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var settingsDetail: some View {
        Form {
            Section("Zoom Info") {
                LabeledContent("Current zoom") {
                    Text("\(Int((zoom.scale * 100).rounded()))%")
                        .monospacedDigit()
                }
                LabeledContent("Shortcuts") {
                    Text("Cmd+  Cmd-  Cmd0")
                        .font(.caption.monospaced())
                }
            }

            Section("Interactive Controls — click these to test") {
                Toggle("Toggle A", isOn: $toggleA)
                Toggle("Toggle B", isOn: $toggleB)

                Button("Click Me") {
                    print("[ACTION] Click Me fired at zoom \(Self.format(zoom.scale))")
                    fflush(stdout)
                    clickLog = "Button clicked at \(Date().formatted(date: .omitted, time: .standard))"
                }

                LabeledContent("Stepper") {
                    Stepper("\(stepperValue)", value: $stepperValue, in: 0...10)
                }

                Slider(value: $sliderValue) {
                    Text("Slider")
                }

                TextField("Text field", text: $textFieldValue)
            }

            Section("Click Log") {
                Text(clickLog)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("Scroll Test — verify scrolling works") {
                ForEach(1...20, id: \.self) { i in
                    Button("Row \(i)") {
                        print("[ACTION] Row \(i) fired at zoom \(Self.format(zoom.scale))")
                        fflush(stdout)
                        clickLog = "Row \(i) clicked"
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: toggleA) { _, value in
            print("[ACTION] Toggle A -> \(value) at zoom \(Self.format(zoom.scale))")
            fflush(stdout)
        }
        .onChange(of: toggleB) { _, value in
            print("[ACTION] Toggle B -> \(value) at zoom \(Self.format(zoom.scale))")
            fflush(stdout)
        }
        .onChange(of: stepperValue) { _, value in
            print("[ACTION] Stepper -> \(value) at zoom \(Self.format(zoom.scale))")
            fflush(stdout)
        }
        .onChange(of: sliderValue) { _, value in
            print("[ACTION] Slider -> \(value) at zoom \(Self.format(zoom.scale))")
            fflush(stdout)
        }
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}

// MARK: - AppKit hit-test probe

private struct HitTestProbe: NSViewRepresentable {
    @ObservedObject var zoom: ZoomState

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: zoom)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.zoom = zoom
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var zoom: ZoomState
        private weak var probeView: NSView?
        private var mouseMonitor: Any?
        private var clickCount = 0

        init(zoom: ZoomState) {
            self.zoom = zoom
        }

        func attach(to view: NSView) {
            probeView = view
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.logMouseDown(event)
                return event
            }
        }

        func detach() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
            }
            mouseMonitor = nil
        }

        private func logMouseDown(_ event: NSEvent) {
            guard let window = probeView?.window,
                  event.window === window,
                  let contentView = window.contentView else { return }
            clickCount += 1

            let windowPoint = event.locationInWindow
            let contentPoint = contentView.convert(windowPoint, from: nil)
            let hit = contentView.hitTest(contentPoint)

            print("\n=== MOUSE \(clickCount) zoom=\(Self.format(zoom.scale)) ===")
            print("windowPoint=\(Self.format(windowPoint)) contentPoint=\(Self.format(contentPoint))")
            print("windowFrame=\(Self.format(window.frame)) content frame=\(Self.format(contentView.frame)) bounds=\(Self.format(contentView.bounds))")
            print("hit=\(hit.map(Self.describe) ?? "nil")")
            if let hit {
                print("ANCESTRY")
                dumpAncestry(from: hit, stopAt: contentView)
            }
            print("VIEW TREE")
            dumpView(contentView, depth: 0, maxDepth: 7)
            print("=== END MOUSE \(clickCount) ===\n")
            fflush(stdout)
        }

        private func dumpAncestry(from view: NSView, stopAt root: NSView) {
            var current: NSView? = view
            var depth = 0
            while let view = current {
                print("\(String(repeating: "  ", count: depth))\(Self.describe(view))")
                if view === root { break }
                current = view.superview
                depth += 1
            }
        }

        private func dumpView(_ view: NSView, depth: Int, maxDepth: Int) {
            guard depth <= maxDepth else { return }
            print("\(String(repeating: "  ", count: depth))\(Self.describe(view))")
            for subview in view.subviews {
                dumpView(subview, depth: depth + 1, maxDepth: maxDepth)
            }
        }

        private static func describe(_ view: NSView) -> String {
            "\(String(describing: type(of: view))) frame=\(format(view.frame)) bounds=\(format(view.bounds)) hidden=\(view.isHidden) subviews=\(view.subviews.count)"
        }

        private static func format(_ point: NSPoint) -> String {
            "(\(String(format: "%.1f", Double(point.x))), \(String(format: "%.1f", Double(point.y))))"
        }

        private static func format(_ rect: NSRect) -> String {
            "(x:\(String(format: "%.1f", Double(rect.origin.x))) y:\(String(format: "%.1f", Double(rect.origin.y))) w:\(String(format: "%.1f", Double(rect.width))) h:\(String(format: "%.1f", Double(rect.height))))"
        }

        private static func format(_ value: CGFloat) -> String {
            String(format: "%.2f", Double(value))
        }
    }
}

// MARK: - Entry point

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let zoom = ZoomState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
private struct SwiftUIZoomPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("SwiftUI Zoom Prototype") {
            ZoomedRootView(zoom: appDelegate.zoom)
                .background(HitTestProbe(zoom: appDelegate.zoom).frame(width: 0, height: 0))
            .frame(minWidth: 500, minHeight: 400)
        }
        .commands {
            CommandMenu("Zoom") {
                Button("Zoom In") { appDelegate.zoom.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { appDelegate.zoom.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { appDelegate.zoom.reset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
